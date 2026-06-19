-- =============================================
-- NL Diagnostica — 020: anexos do edital + link direto do documento (PDF)
--
-- PROBLEMA: url_edital/url_portal recebiam o campo `url` da Effecti, que é a
--   PÁGINA DE SESSÃO do portal (ex.: .../consultar-detalhes-licitacao.aop?...),
--   não o PDF. Mas o payload da Effecti traz `anexos[]` com os documentos
--   DIRETOS (EDITAL.PDF, AVISO_DE_LICITACAO.PDF, ...) — hoje IGNORADOS.
--
-- FIX:
--   1. nl_edital.anexos JSONB        — lista de {nome,url} vinda do raw.
--   2. nl_edital.url_documento TEXT  — melhor PDF eleito (EDITAL > AVISO > 1º PDF).
--   3. nl_pick_documento(jsonb)      — helper de eleição do documento.
--   4. nl_upsert_edital()            — passa a gravar anexos + url_documento.
--      (mantém url_edital = página de sessão p/ "abrir no portal".)
--   5. nl_get_edital já devolve to_jsonb(e) => novas colunas aparecem no front.
--   6. BACKFILL via raw para os editais já ingeridos.
--
-- Rode APÓS 019_fix_parse_ts.sql.
-- =============================================

-- =======  UP  ========

-- ---------- colunas ----------
ALTER TABLE nl_edital
  ADD COLUMN IF NOT EXISTS anexos          JSONB,
  ADD COLUMN IF NOT EXISTS url_documento   TEXT,
  ADD COLUMN IF NOT EXISTS effecti_lixeira  BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS effecti_favorito BOOLEAN NOT NULL DEFAULT FALSE;

-- ---------- helper: elege o melhor documento de um array de anexos ----------
-- Entrada: jsonb array [{"nome":"EDITAL.PDF","url":"https://..."}, ...]
-- Preferência: nome com 'EDITAL' > 'AVISO' > primeiro '.PDF' > primeiro com url.
CREATE OR REPLACE FUNCTION nl_pick_documento(p_anexos JSONB)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_url TEXT;
BEGIN
  IF p_anexos IS NULL OR jsonb_typeof(p_anexos) <> 'array' THEN
    RETURN NULL;
  END IF;

  -- 1) nome contém EDITAL (e não é "AVISO DE ..."), com url http
  SELECT a->>'url' INTO v_url
    FROM jsonb_array_elements(p_anexos) a
   WHERE a->>'url' ~* '^https?://'
     AND upper(COALESCE(a->>'nome','')) LIKE '%EDITAL%'
   ORDER BY (upper(a->>'nome') = 'EDITAL.PDF') DESC, length(a->>'nome')
   LIMIT 1;
  IF v_url IS NOT NULL THEN RETURN v_url; END IF;

  -- 2) aviso de licitação
  SELECT a->>'url' INTO v_url
    FROM jsonb_array_elements(p_anexos) a
   WHERE a->>'url' ~* '^https?://'
     AND upper(COALESCE(a->>'nome','')) LIKE '%AVISO%'
   ORDER BY length(a->>'nome')
   LIMIT 1;
  IF v_url IS NOT NULL THEN RETURN v_url; END IF;

  -- 3) qualquer .PDF
  SELECT a->>'url' INTO v_url
    FROM jsonb_array_elements(p_anexos) a
   WHERE a->>'url' ~* '\.pdf($|\?)'
   LIMIT 1;
  IF v_url IS NOT NULL THEN RETURN v_url; END IF;

  -- 4) primeiro com url http
  SELECT a->>'url' INTO v_url
    FROM jsonb_array_elements(p_anexos) a
   WHERE a->>'url' ~* '^https?://'
   LIMIT 1;
  RETURN v_url;
END;
$$;

GRANT EXECUTE ON FUNCTION nl_pick_documento(JSONB) TO authenticated, service_role;

-- ---------- nl_upsert_edital: grava anexos + url_documento ----------
-- Base: versão de 006_licitacao_rpc.sql, acrescentando anexos/url_documento.
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
  v_anexos  JSONB;
  v_doc     TEXT;
BEGIN
  v_idlic := NULLIF(p_payload->>'idLicitacao','')::BIGINT;
  v_hash  := md5(COALESCE(p_payload->>'processo','') || '|' ||
                 COALESCE(p_payload->>'orgao','')   || '|' ||
                 COALESCE(p_payload->>'objeto', p_payload->>'objetoSemHtml',''));

  -- anexos + documento eleito (Effecti envia em 'anexos')
  v_anexos := CASE WHEN jsonb_typeof(p_payload->'anexos') = 'array'
                   THEN p_payload->'anexos' ELSE NULL END;
  v_doc    := nl_pick_documento(v_anexos);

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
      url_edital, url_portal, url_documento, anexos,
      effecti_lixeira, effecti_favorito,
      palavras_encontradas, raw, batch_id, status
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
      p_payload->>'url', p_payload->>'url', v_doc, v_anexos,
      COALESCE((p_payload->>'naLixeira')::boolean, FALSE),
      COALESCE((p_payload->>'favorito')::boolean, FALSE),
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
      url_documento = COALESCE(v_doc, url_documento),
      anexos = COALESCE(v_anexos, anexos),
      effecti_lixeira = COALESCE((p_payload->>'naLixeira')::boolean, effecti_lixeira),
      effecti_favorito = COALESCE((p_payload->>'favorito')::boolean, effecti_favorito),
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

GRANT EXECUTE ON FUNCTION nl_upsert_edital(JSONB, UUID) TO authenticated, service_role;

-- ---------- backfill: anexos + url_documento dos editais já ingeridos ----------
UPDATE nl_edital e
   SET anexos = e.raw->'anexos',
       url_documento = nl_pick_documento(e.raw->'anexos'),
       updated_at = NOW()
 WHERE jsonb_typeof(e.raw->'anexos') = 'array';

-- backfill do estado da Effecti (lixeira/favorito) a partir do raw
UPDATE nl_edital e
   SET effecti_lixeira  = COALESCE((e.raw->>'naLixeira')::boolean, FALSE),
       effecti_favorito = COALESCE((e.raw->>'favorito')::boolean, FALSE)
 WHERE e.fonte = 'effecti'
   AND (e.raw ? 'naLixeira' OR e.raw ? 'favorito');

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- ALTER TABLE nl_edital
--   DROP COLUMN IF EXISTS anexos, DROP COLUMN IF EXISTS url_documento,
--   DROP COLUMN IF EXISTS effecti_lixeira, DROP COLUMN IF EXISTS effecti_favorito;
-- DROP FUNCTION IF EXISTS nl_pick_documento(JSONB);
-- (restaurar nl_upsert_edital da 006_licitacao_rpc.sql)
