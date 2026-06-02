-- =============================================
-- NL Diagnostica — 010: ações em lote + ordenação/filtro por data
--
-- Adiciona à aba "Buscar editais":
--   1. Ordenação por data de submissão (mais perto / mais longe) e opção de
--      OCULTAR editais cuja data de submissão já passou (vencidos).
--   2. "Recusar todos os sugeridos p/ recusar" em um clique
--      (nl_reject_sugeridos) — retorna os id_licitacao p/ o n8n sincronizar
--      com a Effecti.
--   3. "Apagar recusados" — remove definitivamente os editais já recusados
--      (nl_delete_recusados). O histórico de aprendizado (nl_decision_log)
--      é preservado: o FK usa ON DELETE SET NULL.
--
-- Rode APÓS 006_licitacao_rpc.sql.
-- =============================================

-- =======  UP  ========

-- ---------------------------------------------------------
-- DASHBOARD — agora com ordenação (p_sort) e ocultar vencidos
-- p_sort: NULL/'relevancia' (padrão), 'data_asc' (mais perto da submissão
--         primeiro), 'data_desc' (mais longe primeiro)
-- p_ocultar_vencidos: TRUE remove editais com data_abertura < agora
--         (datas nulas/desconhecidas são mantidas)
-- ---------------------------------------------------------
DROP FUNCTION IF EXISTS nl_dashboard_editais(TEXT,TEXT,TEXT,UUID,INT,INT,DATE,DATE);
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
  p_ocultar_vencidos BOOLEAN DEFAULT FALSE
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
    (SELECT c FROM counted)
  FROM base b
  ORDER BY
    -- agrupamento por relevância só no modo padrão
    CASE WHEN COALESCE(p_sort,'relevancia') = 'relevancia'
         AND b.status IN ('novo','sugerido_aceitar','analisando') THEN 0 ELSE 1 END,
    -- mais perto da submissão primeiro
    (CASE WHEN p_sort = 'data_asc'  THEN b.data_abertura END) ASC  NULLS LAST,
    -- mais longe da submissão primeiro
    (CASE WHEN p_sort = 'data_desc' THEN b.data_abertura END) DESC NULLS LAST,
    -- padrão: data crescente + score
    (CASE WHEN COALESCE(p_sort,'relevancia') = 'relevancia' THEN b.data_abertura END) ASC NULLS LAST,
    b.score_match DESC
  LIMIT GREATEST(p_limit,1) OFFSET GREATEST(p_offset,0);
END;
$$;

-- ---------------------------------------------------------
-- RECUSAR EM LOTE — recusa todos os editais 'sugerido_recusar'
-- (ou os de uma UF, se informada). Registra a decisão e o log,
-- e devolve os id_licitacao p/ o n8n sincronizar com a Effecti.
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION nl_reject_sugeridos(
  p_motivo_effecti TEXT DEFAULT 'OUTROS',
  p_motivo         TEXT DEFAULT 'Recusa em lote (sugeridos p/ recusar)',
  p_uf             TEXT DEFAULT NULL
)
RETURNS JSONB
SECURITY DEFINER SET search_path = auth, public LANGUAGE plpgsql AS $$
DECLARE
  v_uid   UUID := auth.uid();
  r_ed    nl_edital;
  v_itens JSONB := '[]'::jsonb;
  v_qtd   INT := 0;
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  FOR r_ed IN
    SELECT * FROM nl_edital
     WHERE status = 'sugerido_recusar'
       AND (p_uf IS NULL OR uf = UPPER(p_uf))
     ORDER BY data_abertura NULLS LAST
  LOOP
    UPDATE nl_edital
       SET status = 'recusado',
           decisao_final = 'recusado',
           decisao_motivo = p_motivo,
           decisao_motivo_effecti = p_motivo_effecti,
           decidido_por = v_uid,
           decidido_em = NOW(),
           sincronizado_effecti = FALSE,
           updated_at = NOW()
     WHERE id = r_ed.id;

    INSERT INTO nl_decision_log(
      edital_id, id_licitacao, acao, motivo, motivo_effecti, origem,
      score_match, palavras, objeto, uf, snapshot, user_id
    ) VALUES (
      r_ed.id, r_ed.id_licitacao, 'recusar', p_motivo, p_motivo_effecti, 'humano',
      r_ed.score_match, r_ed.palavras_encontradas, r_ed.objeto, r_ed.uf,
      jsonb_build_object('numero_edital', r_ed.numero_edital, 'orgao', r_ed.orgao,
                         'modo_participacao', r_ed.modo_participacao, 'lote', TRUE), v_uid
    );

    IF r_ed.id_licitacao IS NOT NULL THEN
      v_itens := v_itens || jsonb_build_object(
        'edital_id', r_ed.id,
        'id_licitacao', r_ed.id_licitacao
      );
    END IF;
    v_qtd := v_qtd + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'total', v_qtd,
    'motivo_effecti', p_motivo_effecti,
    'motivo', p_motivo,
    'itens', v_itens
  );
END;
$$;

-- ---------------------------------------------------------
-- APAGAR RECUSADOS — remove definitivamente os editais recusados.
-- Admin-only. O histórico (nl_decision_log) é preservado pelo FK
-- ON DELETE SET NULL; os itens (nl_edital_item) caem por CASCADE.
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION nl_delete_recusados(p_uf TEXT DEFAULT NULL)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  v_qtd INT := 0;
BEGIN
  IF NOT (nl_is_admin() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;

  WITH del AS (
    DELETE FROM nl_edital
     WHERE status = 'recusado'
       AND (p_uf IS NULL OR uf = UPPER(p_uf))
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_qtd FROM del;

  RETURN jsonb_build_object('removidos', v_qtd);
END;
$$;

-- ---------- grants ----------
GRANT EXECUTE ON FUNCTION nl_dashboard_editais(TEXT,TEXT,TEXT,UUID,INT,INT,DATE,DATE,TEXT,BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION nl_reject_sugeridos(TEXT,TEXT,TEXT)                                      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_delete_recusados(TEXT)                                                TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS nl_delete_recusados(TEXT);
-- DROP FUNCTION IF EXISTS nl_reject_sugeridos(TEXT,TEXT,TEXT);
-- DROP FUNCTION IF EXISTS nl_dashboard_editais(TEXT,TEXT,TEXT,UUID,INT,INT,DATE,DATE,TEXT,BOOLEAN);
-- -- restaurar a versão de 006_licitacao_rpc.sql (8 args) se necessário.
