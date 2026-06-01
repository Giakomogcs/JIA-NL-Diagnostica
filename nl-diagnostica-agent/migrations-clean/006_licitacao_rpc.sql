-- =============================================
-- NL Diagnostica — 006: RPCs de Editais (ingestão, match, dashboard,
--                        decisão, aprendizado, lotes, estatísticas)
--
-- Consumidas pelos workflows n8n (service_role) e pelo front (authenticated).
-- Rode APÓS 005_licitacao_schema.sql
-- =============================================

-- =======  UP  ========

-- =========================================================
-- HELPER — detecta chamada vinda do backend (n8n via service_role/postgres)
-- Necessário porque o nó Postgres do n8n conecta como role de banco
-- (sem auth.uid()), então nl_is_member()/nl_is_admin() retornariam false.
-- =========================================================
CREATE OR REPLACE FUNCTION nl_is_backend()
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT current_user IN ('postgres','supabase_admin','service_role')
      OR COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role'
      OR COALESCE(auth.role(), '') = 'service_role';
$$;

-- =========================================================
-- CATÁLOGO — CRUD (admin)
-- =========================================================
CREATE OR REPLACE FUNCTION nl_list_catalogo(p_only_active BOOLEAN DEFAULT FALSE)
RETURNS SETOF nl_catalogo
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT * FROM nl_catalogo
     WHERE (NOT p_only_active) OR ativo
     ORDER BY linha NULLS LAST, descricao;
END;
$$;

CREATE OR REPLACE FUNCTION nl_admin_upsert_catalogo(
  p_id            UUID,
  p_tipo          TEXT,
  p_linha         TEXT,
  p_descricao     TEXT,
  p_finalidade    TEXT,
  p_palavras_chave TEXT[],
  p_sinonimos     TEXT[],
  p_marca         TEXT DEFAULT NULL,
  p_ncm           TEXT DEFAULT NULL,
  p_registro_anvisa TEXT DEFAULT NULL,
  p_ativo         BOOLEAN DEFAULT TRUE
)
RETURNS UUID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  v_id UUID := p_id;
BEGIN
  IF NOT nl_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO nl_catalogo(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca, ncm, registro_anvisa, ativo)
    VALUES (COALESCE(p_tipo,'produto'), p_linha, p_descricao, p_finalidade,
            COALESCE(p_palavras_chave,'{}'), COALESCE(p_sinonimos,'{}'), p_marca, p_ncm, p_registro_anvisa, COALESCE(p_ativo,TRUE))
    RETURNING id INTO v_id;
  ELSE
    UPDATE nl_catalogo
       SET tipo = COALESCE(p_tipo,tipo),
           linha = p_linha,
           descricao = p_descricao,
           finalidade = p_finalidade,
           palavras_chave = COALESCE(p_palavras_chave,'{}'),
           sinonimos = COALESCE(p_sinonimos,'{}'),
           marca = p_marca, ncm = p_ncm, registro_anvisa = p_registro_anvisa,
           ativo = COALESCE(p_ativo,TRUE),
           updated_at = NOW()
     WHERE id = v_id;
  END IF;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION nl_admin_delete_catalogo(p_id UUID)
RETURNS VOID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  IF NOT nl_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM nl_catalogo WHERE id = p_id;
END;
$$;

-- =========================================================
-- INGESTÃO — upsert de edital com dedupe + substituição de itens
-- Recebe o objeto bruto da Effecti (schema Licitacao) como JSONB.
-- =========================================================
CREATE OR REPLACE FUNCTION nl_upsert_edital(
  p_payload JSONB,
  p_batch   UUID DEFAULT NULL
)
RETURNS TABLE(edital_id UUID, is_new BOOLEAN)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  v_idlic   BIGINT;
  v_id      UUID;
  v_new     BOOLEAN := FALSE;
  v_hash    TEXT;
  v_item    JSONB;
  v_portal  TEXT;
BEGIN
  v_idlic := NULLIF(p_payload->>'idLicitacao','')::BIGINT;
  v_hash  := md5(COALESCE(p_payload->>'processo','') || '|' ||
                 COALESCE(p_payload->>'orgao','')   || '|' ||
                 COALESCE(p_payload->>'objeto', p_payload->>'objetoSemHtml',''));

  -- resolve portal pelo nome (cria registro mínimo se não existir)
  v_portal := UPPER(REGEXP_REPLACE(COALESCE(p_payload->>'portal',''), '[^a-zA-Z0-9]', '', 'g'));
  IF v_portal <> '' THEN
    INSERT INTO nl_portal(code, name, api_kind)
    VALUES (v_portal, COALESCE(p_payload->>'portal', v_portal), 'manual')
    ON CONFLICT (code) DO NOTHING;
  ELSE
    v_portal := NULL;
  END IF;

  -- dedupe: por id_licitacao (Effecti) ou hash
  IF v_idlic IS NOT NULL THEN
    SELECT id INTO v_id FROM nl_edital WHERE id_licitacao = v_idlic;
  END IF;
  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM nl_edital WHERE dedupe_hash = v_hash;
  END IF;

  IF v_id IS NULL THEN
    v_new := TRUE;
    INSERT INTO nl_edital(
      id_licitacao, dedupe_hash, portal_code, portal_nome, numero_edital, orgao, uf,
      modalidade, cnpj_orgao, uasg, objeto, data_publicacao, data_abertura,
      data_inicial_proposta, data_final_proposta, valor_total_estimado,
      url_edital, url_portal, palavras_encontradas, raw, batch_id, status
    ) VALUES (
      v_idlic, v_hash, v_portal, p_payload->>'portal',
      p_payload->>'processo', p_payload->>'orgao', p_payload->>'uf',
      p_payload->>'modalidade', p_payload->>'cnpj', NULLIF(p_payload->>'uasg','')::TEXT,
      COALESCE(p_payload->>'objetoSemTags', p_payload->>'objetoSemHtml', p_payload->>'objeto'),
      nl_parse_ts(p_payload->>'dataPublicacao'),
      nl_parse_ts(p_payload->>'dataFinalProposta'),
      nl_parse_ts(p_payload->>'dataInicialProposta'),
      nl_parse_ts(p_payload->>'dataFinalProposta'),
      NULLIF(p_payload->>'valorTotalEstimado','')::NUMERIC,
      p_payload->>'url', p_payload->>'url',
      p_payload->'palavraEncontrada', p_payload, p_batch, 'novo'
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE nl_edital SET
      portal_code = COALESCE(v_portal, portal_code),
      portal_nome = COALESCE(p_payload->>'portal', portal_nome),
      numero_edital = COALESCE(p_payload->>'processo', numero_edital),
      orgao = COALESCE(p_payload->>'orgao', orgao),
      uf = COALESCE(p_payload->>'uf', uf),
      modalidade = COALESCE(p_payload->>'modalidade', modalidade),
      cnpj_orgao = COALESCE(p_payload->>'cnpj', cnpj_orgao),
      uasg = COALESCE(NULLIF(p_payload->>'uasg','')::TEXT, uasg),
      objeto = COALESCE(p_payload->>'objetoSemTags', p_payload->>'objetoSemHtml', p_payload->>'objeto', objeto),
      data_publicacao = COALESCE(nl_parse_ts(p_payload->>'dataPublicacao'), data_publicacao),
      data_abertura = COALESCE(nl_parse_ts(p_payload->>'dataFinalProposta'), data_abertura),
      data_inicial_proposta = COALESCE(nl_parse_ts(p_payload->>'dataInicialProposta'), data_inicial_proposta),
      data_final_proposta = COALESCE(nl_parse_ts(p_payload->>'dataFinalProposta'), data_final_proposta),
      valor_total_estimado = COALESCE(NULLIF(p_payload->>'valorTotalEstimado','')::NUMERIC, valor_total_estimado),
      url_edital = COALESCE(p_payload->>'url', url_edital),
      url_portal = COALESCE(p_payload->>'url', url_portal),
      palavras_encontradas = COALESCE(p_payload->'palavraEncontrada', palavras_encontradas),
      raw = p_payload,
      batch_id = COALESCE(p_batch, batch_id),
      updated_at = NOW()
    WHERE id = v_id;
  END IF;

  -- substitui itens (idempotente)
  DELETE FROM nl_edital_item WHERE nl_edital_item.edital_id = v_id;
  IF jsonb_typeof(p_payload->'itensEdital') = 'array' THEN
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_payload->'itensEdital')
    LOOP
      INSERT INTO nl_edital_item(
        edital_id, lote, item_num, produto_licitado, quantidade, unidade,
        valor_unitario, valor_total
      ) VALUES (
        v_id,
        NULLIF(v_item->>'lote',''),
        NULLIF(v_item->>'item','')::INT,
        COALESCE(v_item->>'produtoLicitadoSemTags', v_item->>'produtoLicitadoSemHtml', v_item->>'produtoLicitado'),
        NULLIF(v_item->>'quantidade','')::NUMERIC,
        v_item->>'unidade',
        NULLIF(v_item->>'valorUnitarioEstimado','')::NUMERIC,
        NULLIF(v_item->>'valorTotalEstimado','')::NUMERIC
      );
    END LOOP;
  END IF;

  edital_id := v_id;
  is_new := v_new;
  RETURN NEXT;
END;
$$;

-- =========================================================
-- HELPER — match de palavra-chave com FRONTEIRA DE PALAVRA
-- Evita falsos positivos de termos curtos (ex.: 'tp','inr','tca','spe','epf',
-- 'id') que casariam por substring dentro de outras palavras. Usa regex com
-- bordas de não-alfanumérico e escapa metacaracteres do termo.
-- =========================================================
CREATE OR REPLACE FUNCTION nl_kw_match(p_text TEXT, p_kw TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_kw  TEXT;
  v_re  TEXT;
BEGIN
  IF p_text IS NULL OR p_kw IS NULL THEN RETURN FALSE; END IF;
  v_kw := lower(btrim(p_kw));
  IF v_kw = '' THEN RETURN FALSE; END IF;
  -- escapa metacaracteres de regex no termo
  v_kw := regexp_replace(v_kw, '([.^$*+?()\[\]{}|\\-])', '\\\1', 'g');
  -- borda de palavra usando classe de não-alfanumérico (compatível com acentos)
  v_re := '(^|[^[:alnum:]])' || v_kw || '([^[:alnum:]]|$)';
  RETURN lower(p_text) ~ v_re;
END;
$$;

-- =========================================================
-- MATCH — cruza itens com o catálogo e decide modo de participação
-- =========================================================
CREATE OR REPLACE FUNCTION nl_match_edital(p_edital_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  r_item       RECORD;
  r_cat        RECORD;
  v_prod       TEXT;
  v_hits       INT;
  v_strong     INT;
  v_score      NUMERIC;
  v_best_score NUMERIC;
  v_best_id    UUID;
  v_total      INT := 0;
  v_part       INT := 0;
  v_has_lote   BOOLEAN := FALSE;
  v_lotes_ok   INT := 0;
  v_lotes_tot  INT := 0;
  v_modo       TEXT;
  v_sugestao   TEXT;
  v_status     TEXT;
  v_smatch     NUMERIC;
  kw           TEXT;
BEGIN
  FOR r_item IN SELECT * FROM nl_edital_item WHERE edital_id = p_edital_id LOOP
    v_total := v_total + 1;
    v_prod := lower(COALESCE(r_item.produto_licitado, ''));
    v_best_score := 0; v_best_id := NULL;

    FOR r_cat IN SELECT * FROM nl_catalogo WHERE ativo LOOP
      v_hits := 0;
      v_strong := 0;
      FOREACH kw IN ARRAY (COALESCE(r_cat.palavras_chave,'{}') || COALESCE(r_cat.sinonimos,'{}')) LOOP
        IF nl_kw_match(v_prod, kw) THEN
          v_hits := v_hits + 1;
          -- termo multi-palavra ou longo = sinal mais específico/forte
          IF position(' ' IN btrim(kw)) > 0 OR length(btrim(kw)) >= 8 THEN
            v_strong := v_strong + 1;
          END IF;
        END IF;
      END LOOP;
      IF v_hits > 0 THEN
        -- base por nº de termos + bônus por termos fortes (mais específicos)
        v_score := LEAST(1.0, 0.4 + 0.15 * v_hits + 0.15 * v_strong);
        IF v_score > v_best_score THEN
          v_best_score := v_score; v_best_id := r_cat.id;
        END IF;
      END IF;
    END LOOP;

    UPDATE nl_edital_item
       SET catalogo_id = v_best_id,
           match_score = v_best_score,
           participa   = (v_best_score > 0),
           motivo      = CASE WHEN v_best_score > 0 THEN 'casou com catálogo'
                              ELSE 'sem correspondência no catálogo' END
     WHERE id = r_item.id;

    IF v_best_score > 0 THEN v_part := v_part + 1; END IF;
    IF COALESCE(r_item.lote,'') <> '' THEN v_has_lote := TRUE; END IF;
  END LOOP;

  -- cobertura por lote (um lote é fornecível se TODOS os seus itens participam)
  IF v_has_lote THEN
    SELECT
      COUNT(*) FILTER (WHERE total_itens = itens_part),
      COUNT(*)
    INTO v_lotes_ok, v_lotes_tot
    FROM (
      SELECT lote,
             COUNT(*) AS total_itens,
             COUNT(*) FILTER (WHERE participa) AS itens_part
        FROM nl_edital_item
       WHERE edital_id = p_edital_id AND COALESCE(lote,'') <> ''
       GROUP BY lote
    ) g;
  END IF;

  v_smatch := CASE WHEN v_total = 0 THEN 0 ELSE ROUND(v_part::numeric / v_total, 3) END;

  -- modo de participação
  IF v_part = 0 THEN
    v_modo := 'nenhum';
  ELSIF v_part = v_total THEN
    v_modo := 'total';
  ELSIF v_has_lote AND v_lotes_ok > 0 THEN
    v_modo := 'lote';
  ELSE
    v_modo := 'produto';
  END IF;

  -- sugestão (heurística determinística; o agente de IA refina com aprendizado)
  IF v_part = 0 THEN
    v_sugestao := 'recusar'; v_status := 'sugerido_recusar';
  ELSIF v_modo IN ('total','lote') OR v_smatch >= 0.5 THEN
    v_sugestao := 'aceitar'; v_status := 'sugerido_aceitar';
  ELSE
    v_sugestao := 'revisar'; v_status := 'analisando';
  END IF;

  UPDATE nl_edital
     SET score_match = v_smatch,
         modo_participacao = v_modo,
         sugestao_ia = v_sugestao,
         justificativa_ia = format(
            '%s de %s itens casaram com o catálogo (score %s). Modo sugerido: %s.',
            v_part, v_total, v_smatch, v_modo),
         status = CASE WHEN status IN ('aceito','recusado') THEN status ELSE v_status END,
         updated_at = NOW()
   WHERE id = p_edital_id;

  RETURN jsonb_build_object(
    'edital_id', p_edital_id,
    'itens_total', v_total,
    'itens_participa', v_part,
    'lotes_fornelceis', v_lotes_ok,
    'lotes_total', v_lotes_tot,
    'score_match', v_smatch,
    'modo_participacao', v_modo,
    'sugestao', v_sugestao
  );
END;
$$;

-- =========================================================
-- DASHBOARD — listagem com filtros e paginação
-- =========================================================
CREATE OR REPLACE FUNCTION nl_dashboard_editais(
  p_status   TEXT  DEFAULT NULL,   -- novo | analisando | sugerido_aceitar | sugerido_recusar | aceito | recusado
  p_uf       TEXT  DEFAULT NULL,
  p_search   TEXT  DEFAULT NULL,   -- busca em objeto/orgao/numero
  p_batch    UUID  DEFAULT NULL,
  p_limit    INT   DEFAULT 50,
  p_offset   INT   DEFAULT 0
)
RETURNS TABLE(
  id UUID, id_licitacao BIGINT, numero_edital TEXT, orgao TEXT, uf TEXT,
  portal_nome TEXT, modalidade TEXT, objeto TEXT,
  data_abertura TIMESTAMPTZ, valor_total_estimado NUMERIC,
  url_edital TEXT, url_portal TEXT,
  modo_participacao TEXT, score_match NUMERIC, status TEXT,
  sugestao_ia TEXT, justificativa_ia TEXT,
  itens_total BIGINT, itens_participa BIGINT,
  total_count BIGINT
)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  WITH base AS (
    SELECT e.*
      FROM nl_edital e
     WHERE (p_status IS NULL OR e.status = p_status)
       AND (p_uf IS NULL OR e.uf = UPPER(p_uf))
       AND (p_batch IS NULL OR e.batch_id = p_batch)
       AND (p_search IS NULL OR (
              e.objeto ILIKE '%'||p_search||'%'
           OR e.orgao  ILIKE '%'||p_search||'%'
           OR e.numero_edital ILIKE '%'||p_search||'%'))
  ), counted AS (
    SELECT COUNT(*) AS c FROM base
  )
  SELECT
    b.id, b.id_licitacao, b.numero_edital, b.orgao, b.uf,
    b.portal_nome, b.modalidade, b.objeto,
    b.data_abertura, b.valor_total_estimado,
    b.url_edital, b.url_portal,
    b.modo_participacao, b.score_match, b.status,
    b.sugestao_ia, b.justificativa_ia,
    (SELECT COUNT(*) FROM nl_edital_item i WHERE i.edital_id = b.id),
    (SELECT COUNT(*) FROM nl_edital_item i WHERE i.edital_id = b.id AND i.participa),
    (SELECT c FROM counted)
  FROM base b
  ORDER BY
    CASE WHEN b.status IN ('novo','sugerido_aceitar','analisando') THEN 0 ELSE 1 END,
    b.data_abertura NULLS LAST,
    b.score_match DESC
  LIMIT GREATEST(p_limit,1) OFFSET GREATEST(p_offset,0);
END;
$$;

-- =========================================================
-- DETALHE — cabeçalho + itens
-- =========================================================
CREATE OR REPLACE FUNCTION nl_get_edital(p_edital_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_head JSONB;
  v_items JSONB;
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  SELECT to_jsonb(e) INTO v_head FROM nl_edital e WHERE e.id = p_edital_id;
  IF v_head IS NULL THEN
    RETURN jsonb_build_object('error','edital não encontrado');
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.lote NULLS FIRST, i.item_num), '[]'::jsonb)
    INTO v_items
    FROM (
      SELECT it.*, c.descricao AS catalogo_descricao, c.linha AS catalogo_linha
        FROM nl_edital_item it
        LEFT JOIN nl_catalogo c ON c.id = it.catalogo_id
       WHERE it.edital_id = p_edital_id
    ) i;
  RETURN jsonb_build_object('edital', v_head, 'itens', v_items);
END;
$$;

-- =========================================================
-- DECISÃO — registra aceitar/recusar + log (base do aprendizado)
-- Retorna id_licitacao para o n8n sincronizar com a Effecti.
-- =========================================================
CREATE OR REPLACE FUNCTION nl_record_decision(
  p_edital_id      UUID,
  p_acao           TEXT,            -- aceitar | recusar
  p_motivo         TEXT DEFAULT NULL,
  p_motivo_effecti TEXT DEFAULT NULL,
  p_origem         TEXT DEFAULT 'humano',  -- humano | ia
  p_user_id        UUID DEFAULT NULL       -- usado pelo n8n (service_role)
)
RETURNS JSONB
SECURITY DEFINER SET search_path = auth, public LANGUAGE plpgsql AS $$
DECLARE
  v_e     nl_edital;
  v_uid   UUID := COALESCE(auth.uid(), p_user_id);
  v_new   TEXT;
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  IF p_acao NOT IN ('aceitar','recusar') THEN
    RAISE EXCEPTION 'Ação inválida: % (use aceitar ou recusar).', p_acao USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_e FROM nl_edital WHERE id = p_edital_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edital não encontrado.' USING ERRCODE = 'P0002';
  END IF;

  v_new := CASE WHEN p_acao = 'aceitar' THEN 'aceito' ELSE 'recusado' END;

  UPDATE nl_edital
     SET status = v_new,
         decisao_final = v_new,
         decisao_motivo = p_motivo,
         decisao_motivo_effecti = p_motivo_effecti,
         decidido_por = v_uid,
         decidido_em = NOW(),
         sincronizado_effecti = FALSE,
         updated_at = NOW()
   WHERE id = p_edital_id;

  INSERT INTO nl_decision_log(
    edital_id, id_licitacao, acao, motivo, motivo_effecti, origem,
    score_match, palavras, objeto, uf, snapshot, user_id
  ) VALUES (
    p_edital_id, v_e.id_licitacao, p_acao, p_motivo, p_motivo_effecti, COALESCE(p_origem,'humano'),
    v_e.score_match, v_e.palavras_encontradas, v_e.objeto, v_e.uf,
    jsonb_build_object('numero_edital', v_e.numero_edital, 'orgao', v_e.orgao,
                       'modo_participacao', v_e.modo_participacao), v_uid
  );

  RETURN jsonb_build_object(
    'edital_id', p_edital_id,
    'id_licitacao', v_e.id_licitacao,
    'status', v_new,
    'acao', p_acao,
    'motivo_effecti', p_motivo_effecti
  );
END;
$$;

-- override manual de participação por item
CREATE OR REPLACE FUNCTION nl_set_item_participation(p_item_id UUID, p_participa BOOLEAN)
RETURNS VOID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  UPDATE nl_edital_item
     SET participa = p_participa,
         motivo = CASE WHEN p_participa THEN 'marcado manualmente' ELSE 'descartado manualmente' END
   WHERE id = p_item_id;
END;
$$;

-- marca edital(is) como sincronizado(s) com a Effecti (chamado pelo n8n)
CREATE OR REPLACE FUNCTION nl_mark_synced(p_id_licitacao BIGINT)
RETURNS VOID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  UPDATE nl_edital SET sincronizado_effecti = TRUE, updated_at = NOW()
   WHERE id_licitacao = p_id_licitacao;
END;
$$;

-- =========================================================
-- APRENDIZADO — sinais agregados das decisões passadas (para o agente)
-- =========================================================
CREATE OR REPLACE FUNCTION nl_learning_signals(p_sample INT DEFAULT 20)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'aceitos_total',  (SELECT COUNT(*) FROM nl_decision_log WHERE acao='aceitar'),
    'recusados_total',(SELECT COUNT(*) FROM nl_decision_log WHERE acao='recusar'),
    'motivos_recusa', (
       SELECT COALESCE(jsonb_object_agg(motivo_effecti, c), '{}'::jsonb)
         FROM (SELECT COALESCE(motivo_effecti,'OUTROS') AS motivo_effecti, COUNT(*) c
                 FROM nl_decision_log WHERE acao='recusar'
                GROUP BY 1 ORDER BY 2 DESC LIMIT 10) m
    ),
    'uf_aceitas', (
       SELECT COALESCE(jsonb_object_agg(uf, c), '{}'::jsonb)
         FROM (SELECT COALESCE(uf,'?') uf, COUNT(*) c FROM nl_decision_log
                WHERE acao='aceitar' GROUP BY 1 ORDER BY 2 DESC LIMIT 10) a
    ),
    'uf_recusadas', (
       SELECT COALESCE(jsonb_object_agg(uf, c), '{}'::jsonb)
         FROM (SELECT COALESCE(uf,'?') uf, COUNT(*) c FROM nl_decision_log
                WHERE acao='recusar' GROUP BY 1 ORDER BY 2 DESC LIMIT 10) r
    ),
    'exemplos_recentes', (
       SELECT COALESCE(jsonb_agg(jsonb_build_object(
                 'acao', acao, 'motivo', motivo, 'motivo_effecti', motivo_effecti,
                 'objeto', LEFT(objeto, 240), 'uf', uf, 'score_match', score_match,
                 'origem', origem, 'em', created_at)), '[]'::jsonb)
         FROM (SELECT * FROM nl_decision_log ORDER BY created_at DESC LIMIT GREATEST(p_sample,1)) s
    )
  ) INTO v_out;
  RETURN v_out;
END;
$$;

-- =========================================================
-- LOTES — criar / claim próximos editais / encerrar
-- =========================================================
CREATE OR REPLACE FUNCTION nl_batch_create(p_label TEXT, p_params JSONB DEFAULT NULL)
RETURNS UUID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  INSERT INTO nl_batch(label, params) VALUES (p_label, p_params) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Reserva os próximos N editais 'novo'/'analisando' sem decisão, para análise em lote
CREATE OR REPLACE FUNCTION nl_batch_next(p_limit INT DEFAULT 10)
RETURNS SETOF nl_edital
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT * FROM nl_edital
     WHERE status IN ('novo','analisando')
       AND decisao_final IS NULL
     ORDER BY data_abertura NULLS LAST, created_at
     LIMIT GREATEST(p_limit,1);
END;
$$;

-- =========================================================
-- ESTATÍSTICAS — contadores do dashboard
-- =========================================================
CREATE OR REPLACE FUNCTION nl_stats()
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'total',            (SELECT COUNT(*) FROM nl_edital),
    'novos',            (SELECT COUNT(*) FROM nl_edital WHERE status='novo'),
    'analisando',       (SELECT COUNT(*) FROM nl_edital WHERE status='analisando'),
    'sugerido_aceitar', (SELECT COUNT(*) FROM nl_edital WHERE status='sugerido_aceitar'),
    'sugerido_recusar', (SELECT COUNT(*) FROM nl_edital WHERE status='sugerido_recusar'),
    'aceitos',          (SELECT COUNT(*) FROM nl_edital WHERE status='aceito'),
    'recusados',        (SELECT COUNT(*) FROM nl_edital WHERE status='recusado'),
    'pendentes_sync',   (SELECT COUNT(*) FROM nl_edital WHERE decisao_final IS NOT NULL AND NOT sincronizado_effecti)
  );
END;
$$;

-- =========================================================
-- REMATCH EM LOTE — reaplica o match (catálogo atual) nos editais.
-- Use após alterar o catálogo/palavras-chave ou a lógica de match.
-- Por padrão NÃO mexe em editais já decididos (aceito/recusado).
-- Admin-only (ou backend/n8n).
-- =========================================================
CREATE OR REPLACE FUNCTION nl_rematch_all(p_only_pending BOOLEAN DEFAULT TRUE)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  r_ed   RECORD;
  v_qtd  INT := 0;
BEGIN
  IF NOT (nl_is_admin() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;

  FOR r_ed IN
    SELECT id FROM nl_edital
     WHERE (NOT p_only_pending) OR status NOT IN ('aceito','recusado')
  LOOP
    PERFORM nl_match_edital(r_ed.id);
    v_qtd := v_qtd + 1;
  END LOOP;

  RETURN jsonb_build_object('reprocessados', v_qtd, 'only_pending', p_only_pending);
END;
$$;

-- ---------- grants ----------
GRANT EXECUTE ON FUNCTION nl_is_backend()                                                TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_list_catalogo(BOOLEAN)                                      TO authenticated;
GRANT EXECUTE ON FUNCTION nl_admin_upsert_catalogo(UUID,TEXT,TEXT,TEXT,TEXT,TEXT[],TEXT[],TEXT,TEXT,TEXT,BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION nl_admin_delete_catalogo(UUID)                                 TO authenticated;
GRANT EXECUTE ON FUNCTION nl_upsert_edital(JSONB, UUID)                                  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_match_edital(UUID)                                          TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_dashboard_editais(TEXT,TEXT,TEXT,UUID,INT,INT)              TO authenticated;
GRANT EXECUTE ON FUNCTION nl_get_edital(UUID)                                            TO authenticated;
GRANT EXECUTE ON FUNCTION nl_record_decision(UUID,TEXT,TEXT,TEXT,TEXT,UUID)              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_set_item_participation(UUID,BOOLEAN)                        TO authenticated;
GRANT EXECUTE ON FUNCTION nl_mark_synced(BIGINT)                                         TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_learning_signals(INT)                                       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_batch_create(TEXT,JSONB)                                    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_batch_next(INT)                                             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_stats()                                                     TO authenticated;
GRANT EXECUTE ON FUNCTION nl_rematch_all(BOOLEAN)                                        TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS nl_rematch_all(BOOLEAN);
-- DROP FUNCTION IF EXISTS nl_stats();
-- DROP FUNCTION IF EXISTS nl_batch_next(INT);
-- DROP FUNCTION IF EXISTS nl_batch_create(TEXT,JSONB);
-- DROP FUNCTION IF EXISTS nl_learning_signals(INT);
-- DROP FUNCTION IF EXISTS nl_mark_synced(BIGINT);
-- DROP FUNCTION IF EXISTS nl_set_item_participation(UUID,BOOLEAN);
-- DROP FUNCTION IF EXISTS nl_record_decision(UUID,TEXT,TEXT,TEXT,TEXT,UUID);
-- DROP FUNCTION IF EXISTS nl_get_edital(UUID);
-- DROP FUNCTION IF EXISTS nl_dashboard_editais(TEXT,TEXT,TEXT,UUID,INT,INT);
-- DROP FUNCTION IF EXISTS nl_match_edital(UUID);
-- DROP FUNCTION IF EXISTS nl_kw_match(TEXT,TEXT);
-- DROP FUNCTION IF EXISTS nl_upsert_edital(JSONB, UUID);
-- DROP FUNCTION IF EXISTS nl_admin_delete_catalogo(UUID);
-- DROP FUNCTION IF EXISTS nl_admin_upsert_catalogo(UUID,TEXT,TEXT,TEXT,TEXT,TEXT[],TEXT[],TEXT,TEXT,TEXT,BOOLEAN);
-- DROP FUNCTION IF EXISTS nl_list_catalogo(BOOLEAN);
-- NOTIFY pgrst, 'reload schema';
