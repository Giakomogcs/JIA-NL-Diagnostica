-- =============================================
-- NL Diagnostica — 015: múltiplas fontes (Effecti + Licita Já) e
--                       administração de termos do match
--
-- 1. nl_edital.fonte ('effecti' | 'licitaja' | 'manual') + id_licitaja
--    (dedupe do Licita Já) — fica claro de onde veio cada edital.
-- 2. nl_upsert_edital_licitaja(): ingestão do schema "Tender" da API
--    Licita Já (https://www.licitaja.com.br/api/v1/tender/search).
--    Lotes (lots[]) viram nl_edital_item p/ o match v2 funcionar igual.
-- 3. nl_dashboard_editais ganha coluna `fonte` no retorno e filtro p_fonte.
-- 4. RPCs de administração de palavras indesejadas (nl_match_negativo):
--    nl_list_negativos / nl_admin_upsert_negativo / nl_admin_delete_negativo.
-- 5. nl_admin_upsert_catalogo ganha p_termos_fortes (UI passa a editar).
-- 6. nl_stats: pendentes_sync só conta editais Effecti (id_licitacao);
--    adiciona contadores por fonte.
--
-- Rode APÓS 014_pending_sync_rpc.sql.
-- =============================================

-- =======  UP  ========

-- ---------------------------------------------------------
-- 1. Colunas de fonte
-- ---------------------------------------------------------
ALTER TABLE nl_edital ADD COLUMN IF NOT EXISTS fonte TEXT NOT NULL DEFAULT 'effecti';
ALTER TABLE nl_edital ADD COLUMN IF NOT EXISTS id_licitaja TEXT;

ALTER TABLE nl_edital DROP CONSTRAINT IF EXISTS nl_edital_fonte_check;
ALTER TABLE nl_edital ADD CONSTRAINT nl_edital_fonte_check
  CHECK (fonte IN ('effecti','licitaja','manual'));

CREATE UNIQUE INDEX IF NOT EXISTS idx_nl_edital_id_licitaja
  ON nl_edital(id_licitaja) WHERE id_licitaja IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_nl_edital_fonte ON nl_edital(fonte);

-- portal "Licita Já" (para o badge/links)
INSERT INTO nl_portal(code, name, api_kind)
VALUES ('LICITAJA', 'Licita Já', 'manual')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------
-- 2. Ingestão Licita Já — recebe o objeto "Tender" (JSONB)
--    Campos: tenderId, catalog_date, close_date, tender_object, lots[],
--    tender_summary, smart_search, city, state, agency, procurement,
--    number, number2 (PNCP), process, type, nature, url, url2, value,
--    biddingPlatform, biddingCriteria, ...
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION nl_upsert_edital_licitaja(
  p_payload JSONB,
  p_batch   UUID DEFAULT NULL
)
RETURNS TABLE(edital_id UUID, is_new BOOLEAN)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  v_tid     TEXT;
  v_id      UUID;
  v_new     BOOLEAN := FALSE;
  v_hash    TEXT;
  v_lot     JSONB;
  v_objeto  TEXT;
  v_portal  TEXT;
BEGIN
  v_tid := NULLIF(p_payload->>'tenderId','');
  -- objeto: tender_object, com fallback no resumo do edital
  v_objeto := regexp_replace(
                COALESCE(NULLIF(p_payload->>'tender_object',''),
                         NULLIF(p_payload->>'tender_summary',''), ''),
                '<[^>]+>', ' ', 'g');
  v_hash := md5('licitaja|' ||
                COALESCE(v_tid,
                         COALESCE(p_payload->>'procurement','') || '|' ||
                         COALESCE(p_payload->>'agency','')      || '|' ||
                         v_objeto));
  v_portal := NULLIF(btrim(COALESCE(p_payload->>'biddingPlatform','')), '');

  -- dedupe: por tenderId (Licita Já) ou hash
  IF v_tid IS NOT NULL THEN
    SELECT id INTO v_id FROM nl_edital WHERE id_licitaja = v_tid;
  END IF;
  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM nl_edital WHERE dedupe_hash = v_hash;
  END IF;

  IF v_id IS NULL THEN
    v_new := TRUE;
    INSERT INTO nl_edital(
      fonte, id_licitaja, dedupe_hash, portal_code, portal_nome,
      numero_edital, orgao, uf, modalidade, objeto,
      data_publicacao, data_abertura, data_final_proposta,
      valor_total_estimado, url_edital, url_portal,
      palavras_encontradas, raw, batch_id, status
    ) VALUES (
      'licitaja', v_tid, v_hash, 'LICITAJA', COALESCE(v_portal, 'Licita Já'),
      COALESCE(NULLIF(p_payload->>'procurement',''), NULLIF(p_payload->>'number',''), p_payload->>'process'),
      NULLIF(btrim(COALESCE(p_payload->>'agency','') ||
                   CASE WHEN COALESCE(p_payload->>'city','') <> ''
                        THEN ' — ' || (p_payload->>'city') ELSE '' END), ''),
      NULLIF(p_payload->>'state',''),
      NULLIF(p_payload->>'type',''),
      NULLIF(v_objeto,''),
      nl_parse_ts(p_payload->>'catalog_date'),
      nl_parse_ts(p_payload->>'close_date'),
      nl_parse_ts(p_payload->>'close_date'),
      NULLIF(p_payload->>'value','')::NUMERIC,
      NULLIF(p_payload->>'url',''),
      COALESCE(NULLIF(p_payload->>'url2',''), NULLIF(p_payload->>'url','')),
      CASE WHEN COALESCE(p_payload->>'smart_search','') <> ''
           THEN jsonb_build_array(p_payload->>'smart_search') END,
      p_payload, p_batch, 'novo'
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE nl_edital SET
      id_licitaja = COALESCE(v_tid, id_licitaja),
      portal_nome = COALESCE(v_portal, portal_nome),
      numero_edital = COALESCE(NULLIF(p_payload->>'procurement',''), NULLIF(p_payload->>'number',''), numero_edital),
      orgao = COALESCE(NULLIF(p_payload->>'agency',''), orgao),
      uf = COALESCE(NULLIF(p_payload->>'state',''), uf),
      modalidade = COALESCE(NULLIF(p_payload->>'type',''), modalidade),
      objeto = COALESCE(NULLIF(v_objeto,''), objeto),
      data_publicacao = COALESCE(nl_parse_ts(p_payload->>'catalog_date'), data_publicacao),
      data_abertura = COALESCE(nl_parse_ts(p_payload->>'close_date'), data_abertura),
      data_final_proposta = COALESCE(nl_parse_ts(p_payload->>'close_date'), data_final_proposta),
      valor_total_estimado = COALESCE(NULLIF(p_payload->>'value','')::NUMERIC, valor_total_estimado),
      url_edital = COALESCE(NULLIF(p_payload->>'url',''), url_edital),
      url_portal = COALESCE(NULLIF(p_payload->>'url2',''), NULLIF(p_payload->>'url',''), url_portal),
      raw = p_payload,
      batch_id = COALESCE(p_batch, batch_id),
      updated_at = NOW()
    WHERE id = v_id;
  END IF;

  -- lotes -> itens (lot_object vira produto_licitado p/ o match v2)
  DELETE FROM nl_edital_item WHERE nl_edital_item.edital_id = v_id;
  IF jsonb_typeof(p_payload->'lots') = 'array' THEN
    FOR v_lot IN SELECT * FROM jsonb_array_elements(p_payload->'lots')
    LOOP
      INSERT INTO nl_edital_item(edital_id, lote, produto_licitado)
      VALUES (
        v_id,
        NULLIF(v_lot->>'lot_number',''),
        NULLIF(regexp_replace(COALESCE(v_lot->>'lot_object',''), '<[^>]+>', ' ', 'g'), '')
      );
    END LOOP;
  END IF;

  edital_id := v_id;
  is_new := v_new;
  RETURN NEXT;
END;
$$;
GRANT EXECUTE ON FUNCTION nl_upsert_edital_licitaja(JSONB, UUID) TO service_role;

-- ---------------------------------------------------------
-- 3. Dashboard — coluna fonte + filtro p_fonte
-- ---------------------------------------------------------
DROP FUNCTION IF EXISTS nl_dashboard_editais(TEXT,TEXT,TEXT,UUID,INT,INT,DATE,DATE,TEXT,BOOLEAN);
CREATE OR REPLACE FUNCTION nl_dashboard_editais(
  p_status           TEXT    DEFAULT NULL,
  p_uf               TEXT    DEFAULT NULL,
  p_search           TEXT    DEFAULT NULL,
  p_batch            UUID    DEFAULT NULL,
  p_limit            INT     DEFAULT 50,
  p_offset           INT     DEFAULT 0,
  p_data_de          DATE    DEFAULT NULL,
  p_data_ate         DATE    DEFAULT NULL,
  p_sort             TEXT    DEFAULT NULL,
  p_ocultar_vencidos BOOLEAN DEFAULT FALSE,
  p_fonte            TEXT    DEFAULT NULL
)
RETURNS TABLE(
  id UUID, id_licitacao BIGINT, numero_edital TEXT, orgao TEXT, uf TEXT,
  portal_nome TEXT, modalidade TEXT, objeto TEXT,
  data_abertura TIMESTAMPTZ, valor_total_estimado NUMERIC,
  url_edital TEXT, url_portal TEXT,
  modo_participacao TEXT, score_match NUMERIC, status TEXT,
  sugestao_ia TEXT, justificativa_ia TEXT,
  itens_total BIGINT, itens_participa BIGINT,
  fonte TEXT,
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
       AND (p_fonte IS NULL OR e.fonte = lower(p_fonte))
       AND (p_batch IS NULL OR e.batch_id = p_batch)
       AND (p_data_de  IS NULL OR e.data_abertura >= p_data_de::timestamptz)
       AND (p_data_ate IS NULL OR e.data_abertura <  (p_data_ate::timestamptz + INTERVAL '1 day'))
       AND (NOT p_ocultar_vencidos OR e.data_abertura IS NULL OR e.data_abertura >= NOW())
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
    b.fonte,
    (SELECT c FROM counted)
  FROM base b
  ORDER BY
    CASE WHEN COALESCE(p_sort,'relevancia') = 'relevancia'
         AND b.status IN ('novo','sugerido_aceitar','analisando') THEN 0 ELSE 1 END,
    (CASE WHEN p_sort = 'data_asc'  THEN b.data_abertura END) ASC  NULLS LAST,
    (CASE WHEN p_sort = 'data_desc' THEN b.data_abertura END) DESC NULLS LAST,
    (CASE WHEN COALESCE(p_sort,'relevancia') = 'relevancia' THEN b.data_abertura END) ASC NULLS LAST,
    b.score_match DESC
  LIMIT GREATEST(p_limit,1) OFFSET GREATEST(p_offset,0);
END;
$$;
GRANT EXECUTE ON FUNCTION nl_dashboard_editais(TEXT,TEXT,TEXT,UUID,INT,INT,DATE,DATE,TEXT,BOOLEAN,TEXT)
  TO authenticated, service_role;

-- ---------------------------------------------------------
-- 4. Palavras indesejadas (nl_match_negativo) — administração
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION nl_list_negativos()
RETURNS SETOF nl_match_negativo
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM nl_match_negativo ORDER BY termo;
END;
$$;
GRANT EXECUTE ON FUNCTION nl_list_negativos() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION nl_admin_upsert_negativo(
  p_termo  TEXT,
  p_motivo TEXT    DEFAULT NULL,
  p_ativo  BOOLEAN DEFAULT TRUE
)
RETURNS TEXT
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  v_termo TEXT := lower(btrim(COALESCE(p_termo,'')));
BEGIN
  IF NOT (nl_is_admin() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  IF v_termo = '' THEN
    RAISE EXCEPTION 'Termo vazio.';
  END IF;
  INSERT INTO nl_match_negativo(termo, motivo, ativo)
  VALUES (v_termo, NULLIF(btrim(COALESCE(p_motivo,'')),''), COALESCE(p_ativo,TRUE))
  ON CONFLICT (termo) DO UPDATE
    SET motivo = COALESCE(EXCLUDED.motivo, nl_match_negativo.motivo),
        ativo  = EXCLUDED.ativo;
  RETURN v_termo;
END;
$$;
GRANT EXECUTE ON FUNCTION nl_admin_upsert_negativo(TEXT,TEXT,BOOLEAN) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION nl_admin_delete_negativo(p_termo TEXT)
RETURNS VOID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  IF NOT (nl_is_admin() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM nl_match_negativo WHERE termo = lower(btrim(COALESCE(p_termo,'')));
END;
$$;
GRANT EXECUTE ON FUNCTION nl_admin_delete_negativo(TEXT) TO authenticated, service_role;

-- ---------------------------------------------------------
-- 5. Catálogo — UI passa a editar termos_fortes
-- ---------------------------------------------------------
DROP FUNCTION IF EXISTS nl_admin_upsert_catalogo(UUID,TEXT,TEXT,TEXT,TEXT,TEXT[],TEXT[],TEXT,TEXT,TEXT,BOOLEAN);
CREATE OR REPLACE FUNCTION nl_admin_upsert_catalogo(
  p_id              UUID,
  p_tipo            TEXT,
  p_linha           TEXT,
  p_descricao       TEXT,
  p_finalidade      TEXT,
  p_palavras_chave  TEXT[],
  p_sinonimos       TEXT[],
  p_marca           TEXT    DEFAULT NULL,
  p_ncm             TEXT    DEFAULT NULL,
  p_registro_anvisa TEXT    DEFAULT NULL,
  p_ativo           BOOLEAN DEFAULT TRUE,
  p_termos_fortes   TEXT[]  DEFAULT NULL
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
    INSERT INTO nl_catalogo(tipo, linha, descricao, finalidade, palavras_chave, sinonimos,
                            termos_fortes, marca, ncm, registro_anvisa, ativo)
    VALUES (COALESCE(p_tipo,'produto'), p_linha, p_descricao, p_finalidade,
            COALESCE(p_palavras_chave,'{}'), COALESCE(p_sinonimos,'{}'),
            COALESCE(p_termos_fortes,'{}'), p_marca, p_ncm, p_registro_anvisa, COALESCE(p_ativo,TRUE))
    RETURNING id INTO v_id;
  ELSE
    UPDATE nl_catalogo
       SET tipo = COALESCE(p_tipo,tipo),
           linha = p_linha,
           descricao = p_descricao,
           finalidade = p_finalidade,
           palavras_chave = COALESCE(p_palavras_chave,'{}'),
           sinonimos = COALESCE(p_sinonimos,'{}'),
           termos_fortes = COALESCE(p_termos_fortes, termos_fortes),
           marca = p_marca, ncm = p_ncm, registro_anvisa = p_registro_anvisa,
           ativo = COALESCE(p_ativo,TRUE),
           updated_at = NOW()
     WHERE id = v_id;
  END IF;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION nl_admin_upsert_catalogo(UUID,TEXT,TEXT,TEXT,TEXT,TEXT[],TEXT[],TEXT,TEXT,TEXT,BOOLEAN,TEXT[])
  TO authenticated, service_role;

-- ---------------------------------------------------------
-- 6. nl_stats — pendentes_sync só Effecti + contadores por fonte
-- ---------------------------------------------------------
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
    'pendentes_sync',   (SELECT COUNT(*) FROM nl_edital
                          WHERE decisao_final IS NOT NULL
                            AND NOT sincronizado_effecti
                            AND id_licitacao IS NOT NULL),
    'fonte_effecti',    (SELECT COUNT(*) FROM nl_edital WHERE fonte='effecti'),
    'fonte_licitaja',   (SELECT COUNT(*) FROM nl_edital WHERE fonte='licitaja')
  );
END;
$$;
GRANT EXECUTE ON FUNCTION nl_stats() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS nl_upsert_edital_licitaja(JSONB, UUID);
-- DROP FUNCTION IF EXISTS nl_list_negativos();
-- DROP FUNCTION IF EXISTS nl_admin_upsert_negativo(TEXT,TEXT,BOOLEAN);
-- DROP FUNCTION IF EXISTS nl_admin_delete_negativo(TEXT);
-- ALTER TABLE nl_edital DROP COLUMN IF EXISTS fonte;
-- ALTER TABLE nl_edital DROP COLUMN IF EXISTS id_licitaja;
-- (restaurar nl_dashboard_editais/nl_admin_upsert_catalogo/nl_stats das migrations 010/006)
