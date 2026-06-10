-- =============================================
-- NL Diagnostica — 017: Motor de bulas
--
-- O webhook /nldiag-catalogo-seed agora varre TODAS as bulas do RAG
-- em lotes (não mais 5 chunks por documento) e, além de termos fortes /
-- sinônimos / palavras-chave, gera um CONTEXTO por linha de catálogo
-- (resumo do que a linha cobre segundo as bulas: exames, metodologias,
-- equipamentos, marcas). Esse contexto fica em nl_catalogo.contexto_bulas
-- e é injetado nas análises (Super Triagem).
--
-- 1. nl_catalogo.contexto_bulas (TEXT): conhecimento acumulado das bulas.
-- 2. nl_catalogo_merge_termos: passa a aceitar tambem a chave "contexto"
--    no payload — concatena parágrafos novos (não repete, cap 4000 chars).
--
-- Rode APÓS 016_super_triagem.sql.
-- =============================================

-- =======  UP  ========

ALTER TABLE nl_catalogo
  ADD COLUMN IF NOT EXISTS contexto_bulas TEXT;

-- ---------- merge incremental de termos + contexto ----------
-- p_payload: {"linha":"...","termos_fortes":[...],"sinonimos":[...],
--             "palavras_chave":[...],"contexto":"..."}
CREATE OR REPLACE FUNCTION nl_catalogo_merge_termos(p_payload JSONB)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  v_linha     TEXT := trim(COALESCE(p_payload->>'linha',''));
  v_contexto  TEXT := trim(COALESCE(p_payload->>'contexto',''));
  v_fortes    TEXT[];
  v_sin       TEXT[];
  v_chave     TEXT[];
  v_add_f     TEXT[] := '{}';
  v_add_s     TEXT[] := '{}';
  v_add_k     TEXT[] := '{}';
  v_ctx_add   BOOLEAN := FALSE;
  v_rows      INT := 0;
  v_novo_ctx  TEXT;
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

    -- contexto: acrescenta apenas se trouxer informação nova; cap 4000 chars
    v_novo_ctx := r.contexto_bulas;
    IF v_contexto <> '' AND length(v_contexto) >= 20
       AND position(lower(left(v_contexto, 120)) IN lower(COALESCE(r.contexto_bulas,''))) = 0 THEN
      v_novo_ctx := left(
        COALESCE(NULLIF(r.contexto_bulas,'') || E'\n', '') || v_contexto,
        4000);
      v_ctx_add := TRUE;
    END IF;

    UPDATE nl_catalogo
       SET termos_fortes  = termos_fortes  || v_add_f,
           sinonimos      = sinonimos      || v_add_s,
           palavras_chave = palavras_chave || v_add_k,
           contexto_bulas = v_novo_ctx,
           updated_at     = NOW()
     WHERE id = r.id;
  END LOOP;

  RETURN jsonb_build_object(
    'linha', v_linha,
    'encontrado', v_rows > 0,
    'adicionados_fortes',  to_jsonb(v_add_f),
    'adicionados_sinonimos', to_jsonb(v_add_s),
    'adicionados_chave',   to_jsonb(v_add_k),
    'contexto_adicionado', v_ctx_add
  );
END;
$$;

GRANT EXECUTE ON FUNCTION nl_catalogo_merge_termos(JSONB) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- ALTER TABLE nl_catalogo DROP COLUMN IF EXISTS contexto_bulas;
-- (a versão anterior de nl_catalogo_merge_termos está na 016)
