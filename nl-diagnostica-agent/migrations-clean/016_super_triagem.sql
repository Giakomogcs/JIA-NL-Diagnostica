-- =============================================
-- NL Diagnostica — 016: Super triagem + semeadura do catálogo via bulas
--
-- 1. nl_edital.analise_profunda (JSONB): resultado da "super triagem" —
--    o n8n baixa o PDF do edital (url_edital), extrai o texto (com OCR
--    fallback), cruza com catálogo/negativos via LLM e grava aqui.
--    O texto do PDF NÃO vai para o RAG — é usado só temporariamente
--    durante a análise; apenas o resultado estruturado é persistido.
-- 2. nl_set_analise_profunda: RPC usada pelo workflow para gravar.
-- 3. nl_catalogo_merge_termos: merge incremental de termos fortes /
--    sinônimos / palavras-chave extraídos das bulas pelo LLM
--    (nunca remove termos existentes — só adiciona novos).
--
-- Rode APÓS 015_fontes_licitaja.sql.
-- =============================================

-- =======  UP  ========

-- ---------- colunas de análise profunda ----------
ALTER TABLE nl_edital
  ADD COLUMN IF NOT EXISTS analise_profunda    JSONB,
  ADD COLUMN IF NOT EXISTS analise_profunda_at TIMESTAMPTZ;

-- nl_get_edital já devolve to_jsonb(e) → as novas colunas aparecem
-- automaticamente no detalhe do edital no front.

-- ---------- gravar análise profunda ----------
CREATE OR REPLACE FUNCTION nl_set_analise_profunda(
  p_edital_id UUID,
  p_analise   JSONB
)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  UPDATE nl_edital
     SET analise_profunda    = p_analise,
         analise_profunda_at = NOW(),
         updated_at          = NOW()
   WHERE id = p_edital_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edital não encontrado.' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object('edital_id', p_edital_id, 'salvo', TRUE);
END;
$$;

GRANT EXECUTE ON FUNCTION nl_set_analise_profunda(UUID, JSONB) TO authenticated, service_role;

-- ---------- merge incremental de termos no catálogo ----------
-- p_payload: {"linha":"Hemostasia","termos_fortes":[...],"sinonimos":[...],"palavras_chave":[...]}
-- Casa a linha de forma case-insensitive; adiciona apenas termos novos
-- (lower/trim, dedup). Retorna o que foi de fato adicionado.
CREATE OR REPLACE FUNCTION nl_catalogo_merge_termos(p_payload JSONB)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  v_linha     TEXT := trim(COALESCE(p_payload->>'linha',''));
  v_fortes    TEXT[];
  v_sin       TEXT[];
  v_chave     TEXT[];
  v_add_f     TEXT[] := '{}';
  v_add_s     TEXT[] := '{}';
  v_add_k     TEXT[] := '{}';
  v_rows      INT := 0;
  r           nl_catalogo;
BEGIN
  IF NOT (nl_is_admin() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado (admin).' USING ERRCODE = '42501';
  END IF;
  IF v_linha = '' THEN
    RETURN jsonb_build_object('linha', NULL, 'encontrado', FALSE, 'erro', 'linha vazia');
  END IF;

  -- normaliza arrays de entrada (lower/trim, remove vazios e duplicados)
  SELECT COALESCE(array_agg(DISTINCT t), '{}') INTO v_fortes
    FROM (SELECT lower(trim(x)) AS t
            FROM jsonb_array_elements_text(COALESCE(p_payload->'termos_fortes','[]'::jsonb)) x) s
   WHERE t <> '' AND length(t) >= 3;
  SELECT COALESCE(array_agg(DISTINCT t), '{}') INTO v_sin
    FROM (SELECT lower(trim(x)) AS t
            FROM jsonb_array_elements_text(COALESCE(p_payload->'sinonimos','[]'::jsonb)) x) s
   WHERE t <> '' AND length(t) >= 3;
  SELECT COALESCE(array_agg(DISTINCT t), '{}') INTO v_chave
    FROM (SELECT lower(trim(x)) AS t
            FROM jsonb_array_elements_text(COALESCE(p_payload->'palavras_chave','[]'::jsonb)) x) s
   WHERE t <> '' AND length(t) >= 3;

  FOR r IN SELECT * FROM nl_catalogo WHERE lower(linha) = lower(v_linha) LOOP
    v_rows := v_rows + 1;

    SELECT COALESCE(array_agg(t), '{}') INTO v_add_f
      FROM unnest(v_fortes) t
     WHERE NOT (lower(t) IN (SELECT lower(x) FROM unnest(r.termos_fortes) x));
    SELECT COALESCE(array_agg(t), '{}') INTO v_add_s
      FROM unnest(v_sin) t
     WHERE NOT (lower(t) IN (SELECT lower(x) FROM unnest(r.sinonimos) x))
       AND NOT (lower(t) IN (SELECT lower(x) FROM unnest(r.termos_fortes || v_add_f) x));
    SELECT COALESCE(array_agg(t), '{}') INTO v_add_k
      FROM unnest(v_chave) t
     WHERE NOT (lower(t) IN (SELECT lower(x) FROM unnest(r.palavras_chave) x))
       AND NOT (lower(t) IN (SELECT lower(x) FROM unnest(r.sinonimos || v_add_s) x))
       AND NOT (lower(t) IN (SELECT lower(x) FROM unnest(r.termos_fortes || v_add_f) x));

    UPDATE nl_catalogo
       SET termos_fortes  = termos_fortes  || v_add_f,
           sinonimos      = sinonimos      || v_add_s,
           palavras_chave = palavras_chave || v_add_k,
           updated_at     = NOW()
     WHERE id = r.id;
  END LOOP;

  RETURN jsonb_build_object(
    'linha', v_linha,
    'encontrado', v_rows > 0,
    'adicionados_fortes',  to_jsonb(v_add_f),
    'adicionados_sinonimos', to_jsonb(v_add_s),
    'adicionados_chave',   to_jsonb(v_add_k)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION nl_catalogo_merge_termos(JSONB) TO authenticated, service_role;

-- ---------- nl_board_editais: expor a fonte (Effecti / Licita Já) ----------
-- O retorno muda (nova coluna), então a assinatura antiga precisa ser dropada.
DROP FUNCTION IF EXISTS nl_board_editais(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION nl_board_editais(
  p_stage    TEXT  DEFAULT NULL,
  p_search   TEXT  DEFAULT NULL,
  p_uf       TEXT  DEFAULT NULL
)
RETURNS TABLE(
  id UUID, id_licitacao BIGINT, numero_edital TEXT, orgao TEXT, uf TEXT,
  portal_nome TEXT, modalidade TEXT, objeto TEXT,
  data_abertura TIMESTAMPTZ, valor_total_estimado NUMERIC,
  url_edital TEXT, url_portal TEXT,
  modo_participacao TEXT, score_match NUMERIC, status TEXT,
  kanban_stage TEXT, gestao_responsavel TEXT, gestao_prazo DATE,
  gestao_prioridade TEXT, gestao_valor_proposta NUMERIC,
  gestao_observacoes TEXT, gestao_atualizado_em TIMESTAMPTZ,
  decidido_em TIMESTAMPTZ,
  itens_total BIGINT, itens_participa BIGINT,
  fonte TEXT
)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT
    e.id, e.id_licitacao, e.numero_edital, e.orgao, e.uf,
    e.portal_nome, e.modalidade, e.objeto,
    e.data_abertura, e.valor_total_estimado,
    e.url_edital, e.url_portal,
    e.modo_participacao, e.score_match, e.status,
    COALESCE(e.kanban_stage,'qualificado'), e.gestao_responsavel, e.gestao_prazo,
    e.gestao_prioridade, e.gestao_valor_proposta,
    e.gestao_observacoes, e.gestao_atualizado_em,
    e.decidido_em,
    (SELECT COUNT(*) FROM nl_edital_item i WHERE i.edital_id = e.id),
    (SELECT COUNT(*) FROM nl_edital_item i WHERE i.edital_id = e.id AND i.participa),
    e.fonte
  FROM nl_edital e
  WHERE e.status = 'aceito'
    AND (p_stage  IS NULL OR COALESCE(e.kanban_stage,'qualificado') = p_stage)
    AND (p_uf     IS NULL OR e.uf = UPPER(p_uf))
    AND (p_search IS NULL OR (
           e.objeto ILIKE '%'||p_search||'%'
        OR e.orgao  ILIKE '%'||p_search||'%'
        OR e.numero_edital ILIKE '%'||p_search||'%'))
  ORDER BY
    CASE e.gestao_prioridade WHEN 'alta' THEN 0 WHEN 'media' THEN 1 ELSE 2 END,
    e.gestao_prazo NULLS LAST,
    e.data_abertura NULLS LAST;
END;
$$;

GRANT EXECUTE ON FUNCTION nl_board_editais(TEXT, TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS nl_catalogo_merge_termos(JSONB);
-- DROP FUNCTION IF EXISTS nl_set_analise_profunda(UUID, JSONB);
-- ALTER TABLE nl_edital DROP COLUMN IF EXISTS analise_profunda, DROP COLUMN IF EXISTS analise_profunda_at;
-- NOTIFY pgrst, 'reload schema';
