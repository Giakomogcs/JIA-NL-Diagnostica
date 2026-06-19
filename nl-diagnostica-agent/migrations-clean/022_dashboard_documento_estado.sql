-- =============================================
-- NL Diagnostica — 022: expor documento + estado Effecti na listagem
--
-- nl_dashboard_editais (aba "Buscar editais") passa a devolver:
--   - url_documento   (PDF direto eleito em 020) -> link "Edital (PDF)" na lista
--   - effecti_lixeira  / effecti_favorito (020)  -> badges de estado na Effecti
--
-- Base: versão de 015_fontes_licitaja.sql, acrescentando 3 colunas no retorno.
-- Rode APÓS 021_match_sem_itens.sql.
-- =============================================

-- =======  UP  ========

DROP FUNCTION IF EXISTS nl_dashboard_editais(TEXT,TEXT,TEXT,UUID,INT,INT,DATE,DATE,TEXT,BOOLEAN,TEXT);
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
  url_edital TEXT, url_portal TEXT, url_documento TEXT,
  effecti_lixeira BOOLEAN, effecti_favorito BOOLEAN,
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
    b.url_edital, b.url_portal, b.url_documento,
    b.effecti_lixeira, b.effecti_favorito,
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

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- (restaurar nl_dashboard_editais de 015_fontes_licitaja.sql)
