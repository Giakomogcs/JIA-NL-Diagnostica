-- =============================================
-- NL Diagnostica — 023: Aprendizado por feedback na triagem
--
-- Contexto: ao aceitar/recusar um edital, o operador registra palavras
-- BOAS (reforço → catálogo), palavras RUINS (bloqueio → negativos) e
-- REGRAS/aprendizados em texto livre (injetadas no prompt da super triagem).
-- Ver Docs/PRD-aprendizado-triagem-feedback.md.
--
-- Preocupação central: NÃO lotar o DB. Toda gravação passa por dedup em
-- duas camadas — EXATA (normalizada) e SEMÂNTICA (embeddings/cosseno) —
-- e cada família de termos/regras tem teto explícito.
--
-- Objetos:
--   1. unaccent + nl_norm()        — normalização (lower/trim/sem acento).
--   2. nl_triagem_regra            — regras aprendidas (texto + embedding).
--   3. nl_termo_embedding          — cache de embeddings de termos.
--   4. nl_termo_vizinho()          — vizinho mais próximo (dedup semântica).
--   5. nl_aprendizado_aplicar()    — dedup + persistência seletiva.
--   6. nl_list_regras_ativas()     — regras p/ o prompt (cap de chars).
--   7. nl_list_regras() / nl_admin_set_regra_ativo() / nl_admin_delete_regra().
--
-- Rode APÓS 022_dashboard_documento_estado.sql.
-- Reutiliza: nl_catalogo_merge_termos (016), nl_admin_upsert_negativo (015),
--            nl_rematch_reset / nl_rematch_all (013).
-- =============================================

-- =======  UP  ========

CREATE EXTENSION IF NOT EXISTS unaccent;

-- ---------- normalização canônica de termos ----------
CREATE OR REPLACE FUNCTION nl_norm(p_txt TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT lower(btrim(unaccent(COALESCE(p_txt, ''))))
$$;

GRANT EXECUTE ON FUNCTION nl_norm(TEXT) TO authenticated, service_role;

-- ---------- regras / aprendizados ----------
CREATE TABLE IF NOT EXISTS nl_triagem_regra (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  linha            TEXT NOT NULL,
  texto            TEXT NOT NULL CHECK (length(texto) <= 280),
  embedding        vector(1536),
  peso             SMALLINT NOT NULL DEFAULT 1,
  ativo            BOOLEAN NOT NULL DEFAULT TRUE,
  origem_edital_id UUID,
  origem_acao      TEXT,
  created_by       UUID DEFAULT auth.uid(),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE nl_triagem_regra ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS nl_triagem_regra_sel ON nl_triagem_regra;
CREATE POLICY nl_triagem_regra_sel ON nl_triagem_regra
  FOR SELECT USING (nl_is_member() OR nl_is_backend());

CREATE INDEX IF NOT EXISTS idx_nl_triagem_regra_linha
  ON nl_triagem_regra ( lower(linha) ) WHERE ativo;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'nl_triagem_regra_embedding_hnsw'
  ) THEN
    EXECUTE 'CREATE INDEX nl_triagem_regra_embedding_hnsw
             ON nl_triagem_regra USING hnsw (embedding vector_cosine_ops)';
  END IF;
EXCEPTION WHEN OTHERS THEN
  NULL; -- índice é otimização; ausência não quebra a feature
END $$;

-- ---------- cache de embeddings de termos ----------
-- Evita re-embedar o catálogo a cada decisão (RNF2). 'termo' já normalizado.
CREATE TABLE IF NOT EXISTS nl_termo_embedding (
  termo      TEXT PRIMARY KEY,
  escopo     TEXT NOT NULL CHECK (escopo IN ('forte','fraco','negativo')),
  linha      TEXT,
  embedding  vector(1536) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE nl_termo_embedding ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS nl_termo_embedding_sel ON nl_termo_embedding;
CREATE POLICY nl_termo_embedding_sel ON nl_termo_embedding
  FOR SELECT USING (nl_is_member() OR nl_is_backend());

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'nl_termo_embedding_hnsw'
  ) THEN
    EXECUTE 'CREATE INDEX nl_termo_embedding_hnsw
             ON nl_termo_embedding USING hnsw (embedding vector_cosine_ops)';
  END IF;
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

-- ---------- vizinho mais próximo (dedup semântica) ----------
-- Retorna o termo já cadastrado com maior cosseno dentro do escopo/linha.
-- p_linha NULL = ignora a linha (ex.: negativos são globais).
CREATE OR REPLACE FUNCTION nl_termo_vizinho(
  p_embedding vector(1536),
  p_escopos   TEXT[],
  p_linha     TEXT DEFAULT NULL
)
RETURNS TABLE(termo TEXT, similaridade NUMERIC)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT t.termo,
           round((1 - (t.embedding <=> p_embedding))::numeric, 4) AS similaridade
      FROM nl_termo_embedding t
     WHERE t.escopo = ANY(p_escopos)
       AND (p_linha IS NULL OR t.linha IS NULL OR lower(t.linha) = lower(p_linha))
     ORDER BY t.embedding <=> p_embedding
     LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION nl_termo_vizinho(vector, TEXT[], TEXT) TO authenticated, service_role;

-- ---------- aplicar aprendizado (dedup + persistência seletiva) ----------
-- p_payload:
--   { "linha":"Hemostasia", "origem_edital_id":"<uuid>", "origem_acao":"aceitar|recusar",
--     "limiar_termo":0.90, "limiar_regra":0.86,
--     "boas":  [{"termo":"...","embedding":[...]}],
--     "ruins": [{"termo":"...","motivo":"...","embedding":[...]}],
--     "regra": {"texto":"...","embedding":[...]} | null }
-- Embeddings são opcionais por item: ausentes ⇒ só dedup EXATA (degradação graciosa).
CREATE OR REPLACE FUNCTION nl_aprendizado_aplicar(p_payload JSONB)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  v_linha      TEXT := btrim(COALESCE(p_payload->>'linha',''));
  v_origem     UUID := NULLIF(p_payload->>'origem_edital_id','')::UUID;
  v_acao       TEXT := NULLIF(p_payload->>'origem_acao','');
  v_lim_termo  NUMERIC := COALESCE((p_payload->>'limiar_termo')::numeric, 0.90);
  v_lim_regra  NUMERIC := COALESCE((p_payload->>'limiar_regra')::numeric, 0.86);
  c_cap_regras CONSTANT INT := 20;
  c_cap_texto  CONSTANT INT := 280;

  v_grav_boas  TEXT[] := '{}';
  v_grav_ruins TEXT[] := '{}';
  v_grav_regra INT := 0;
  v_desc_exato TEXT[] := '{}';
  v_desc_sem   JSONB := '[]'::jsonb;

  el           JSONB;
  v_termo      TEXT;
  v_norm       TEXT;
  v_motivo     TEXT;
  v_texto      TEXT;
  v_emb        vector(1536);
  v_has_emb    BOOLEAN;
  v_viz_termo  TEXT;
  v_viz_sim    NUMERIC;
  v_count      INT;
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  IF v_linha = '' THEN
    RAISE EXCEPTION 'Linha do catálogo é obrigatória.';
  END IF;

  -- ======== PALAVRAS BOAS → catálogo (reforço) ========
  FOR el IN SELECT * FROM jsonb_array_elements(COALESCE(p_payload->'boas','[]'::jsonb)) LOOP
    v_termo := btrim(COALESCE(el->>'termo',''));
    v_norm  := nl_norm(v_termo);
    IF length(v_norm) < 2 THEN CONTINUE; END IF;

    -- dedup EXATA (catálogo da linha, qualquer campo)
    IF EXISTS (
      SELECT 1 FROM nl_catalogo c,
             unnest(c.termos_fortes || c.sinonimos || c.palavras_chave) x
       WHERE lower(c.linha) = lower(v_linha) AND nl_norm(x) = v_norm
    ) THEN
      v_desc_exato := v_desc_exato || v_norm; CONTINUE;
    END IF;

    -- dedup SEMÂNTICA (quando há embedding)
    v_has_emb := jsonb_typeof(el->'embedding') = 'array';
    IF v_has_emb THEN
      v_emb := (el->>'embedding')::vector;
      SELECT termo, similaridade INTO v_viz_termo, v_viz_sim
        FROM nl_termo_vizinho(v_emb, ARRAY['forte','fraco'], v_linha);
      IF v_viz_sim IS NOT NULL AND v_viz_sim >= v_lim_termo THEN
        v_desc_sem := v_desc_sem || jsonb_build_object(
          'termo', v_norm, 'tipo', 'boa',
          'parecido_com', v_viz_termo, 'similaridade', v_viz_sim);
        CONTINUE;
      END IF;
    END IF;

    -- grava (merge roteia <4 chars p/ sinônimo — 018)
    PERFORM nl_catalogo_merge_termos(jsonb_build_object(
      'linha', v_linha, 'termos_fortes', jsonb_build_array(v_norm)));
    IF v_has_emb THEN
      INSERT INTO nl_termo_embedding(termo, escopo, linha, embedding)
      VALUES (v_norm, 'forte', v_linha, v_emb)
      ON CONFLICT (termo) DO UPDATE SET embedding = EXCLUDED.embedding;
    END IF;
    v_grav_boas := v_grav_boas || v_norm;
  END LOOP;

  -- ======== PALAVRAS RUINS → negativos (bloqueio global) ========
  FOR el IN SELECT * FROM jsonb_array_elements(COALESCE(p_payload->'ruins','[]'::jsonb)) LOOP
    v_termo  := btrim(COALESCE(el->>'termo',''));
    v_motivo := NULLIF(btrim(COALESCE(el->>'motivo','')),'');
    v_norm   := nl_norm(v_termo);
    IF length(v_norm) < 2 THEN CONTINUE; END IF;

    IF EXISTS (SELECT 1 FROM nl_match_negativo WHERE nl_norm(termo) = v_norm) THEN
      v_desc_exato := v_desc_exato || v_norm; CONTINUE;
    END IF;

    v_has_emb := jsonb_typeof(el->'embedding') = 'array';
    IF v_has_emb THEN
      v_emb := (el->>'embedding')::vector;
      SELECT termo, similaridade INTO v_viz_termo, v_viz_sim
        FROM nl_termo_vizinho(v_emb, ARRAY['negativo'], NULL);
      IF v_viz_sim IS NOT NULL AND v_viz_sim >= v_lim_termo THEN
        v_desc_sem := v_desc_sem || jsonb_build_object(
          'termo', v_norm, 'tipo', 'ruim',
          'parecido_com', v_viz_termo, 'similaridade', v_viz_sim);
        CONTINUE;
      END IF;
    END IF;

    PERFORM nl_admin_upsert_negativo(
      v_norm, COALESCE(v_motivo, 'aprendizado: feedback de triagem'), TRUE);
    IF v_has_emb THEN
      INSERT INTO nl_termo_embedding(termo, escopo, linha, embedding)
      VALUES (v_norm, 'negativo', NULL, v_emb)
      ON CONFLICT (termo) DO UPDATE SET embedding = EXCLUDED.embedding;
    END IF;
    v_grav_ruins := v_grav_ruins || v_norm;
  END LOOP;

  -- ======== REGRA / APRENDIZADO ========
  IF jsonb_typeof(p_payload->'regra') = 'object' THEN
    v_texto := btrim(COALESCE(p_payload->'regra'->>'texto',''));
    IF length(v_texto) >= 4 THEN
      IF length(v_texto) > c_cap_texto THEN
        RAISE EXCEPTION 'Regra excede % caracteres. Resuma o aprendizado.', c_cap_texto;
      END IF;

      SELECT COUNT(*) INTO v_count FROM nl_triagem_regra
       WHERE lower(linha) = lower(v_linha) AND ativo;
      IF v_count >= c_cap_regras THEN
        RAISE EXCEPTION
          'Limite de % regras ativas para a linha "%" atingido. Faça curadoria (desative regras) antes de adicionar.',
          c_cap_regras, v_linha;
      END IF;

      v_has_emb := jsonb_typeof(p_payload->'regra'->'embedding') = 'array';
      IF v_has_emb THEN
        v_emb := (p_payload->'regra'->>'embedding')::vector;
        SELECT texto, round((1-(embedding <=> v_emb))::numeric,4)
          INTO v_viz_termo, v_viz_sim
          FROM nl_triagem_regra
         WHERE lower(linha) = lower(v_linha) AND ativo AND embedding IS NOT NULL
         ORDER BY embedding <=> v_emb LIMIT 1;
      END IF;

      IF v_has_emb AND v_viz_sim IS NOT NULL AND v_viz_sim >= v_lim_regra THEN
        v_desc_sem := v_desc_sem || jsonb_build_object(
          'termo', v_texto, 'tipo', 'regra',
          'parecido_com', v_viz_termo, 'similaridade', v_viz_sim);
      ELSE
        INSERT INTO nl_triagem_regra(linha, texto, embedding, origem_edital_id, origem_acao)
        VALUES (v_linha, v_texto, CASE WHEN v_has_emb THEN v_emb ELSE NULL END,
                v_origem, v_acao);
        v_grav_regra := 1;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'linha', v_linha,
    'gravados', jsonb_build_object(
      'boas',  to_jsonb(v_grav_boas),
      'ruins', to_jsonb(v_grav_ruins),
      'regras', v_grav_regra),
    'descartados_exato', to_jsonb(v_desc_exato),
    'descartados_semantico', v_desc_sem
  );
END;
$$;

GRANT EXECUTE ON FUNCTION nl_aprendizado_aplicar(JSONB) TO authenticated, service_role;

-- ---------- regras ativas para o prompt (cap de chars) ----------
CREATE OR REPLACE FUNCTION nl_list_regras_ativas(
  p_linha TEXT DEFAULT NULL,
  p_cap   INT  DEFAULT 4000
)
RETURNS TEXT
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_out TEXT := '';
  r     RECORD;
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  FOR r IN
    SELECT linha, texto FROM nl_triagem_regra
     WHERE ativo AND (p_linha IS NULL OR lower(linha) = lower(p_linha))
     ORDER BY peso DESC, created_at
  LOOP
    EXIT WHEN length(v_out) + length(r.texto) + 4 > p_cap;
    v_out := v_out || '- [' || r.linha || '] ' || r.texto || E'\n';
  END LOOP;
  RETURN v_out;
END;
$$;

GRANT EXECUTE ON FUNCTION nl_list_regras_ativas(TEXT, INT) TO authenticated, service_role;

-- ---------- gestão das regras (UI) ----------
CREATE OR REPLACE FUNCTION nl_list_regras()
RETURNS TABLE(
  id UUID, linha TEXT, texto TEXT, peso SMALLINT, ativo BOOLEAN,
  origem_edital_id UUID, origem_acao TEXT, created_at TIMESTAMPTZ
)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT r.id, r.linha, r.texto, r.peso, r.ativo,
           r.origem_edital_id, r.origem_acao, r.created_at
      FROM nl_triagem_regra r
     ORDER BY r.ativo DESC, lower(r.linha), r.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION nl_list_regras() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION nl_admin_set_regra_ativo(p_id UUID, p_ativo BOOLEAN)
RETURNS VOID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  IF NOT (nl_is_admin() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  UPDATE nl_triagem_regra SET ativo = COALESCE(p_ativo, TRUE) WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION nl_admin_set_regra_ativo(UUID, BOOLEAN) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION nl_admin_delete_regra(p_id UUID)
RETURNS VOID
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
BEGIN
  IF NOT (nl_is_admin() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM nl_triagem_regra WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION nl_admin_delete_regra(UUID) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS nl_admin_delete_regra(UUID);
-- DROP FUNCTION IF EXISTS nl_admin_set_regra_ativo(UUID, BOOLEAN);
-- DROP FUNCTION IF EXISTS nl_list_regras();
-- DROP FUNCTION IF EXISTS nl_list_regras_ativas(TEXT, INT);
-- DROP FUNCTION IF EXISTS nl_aprendizado_aplicar(JSONB);
-- DROP FUNCTION IF EXISTS nl_termo_vizinho(vector, TEXT[], TEXT);
-- DROP TABLE IF EXISTS nl_termo_embedding;
-- DROP TABLE IF EXISTS nl_triagem_regra;
-- DROP FUNCTION IF EXISTS nl_norm(TEXT);
-- NOTIFY pgrst, 'reload schema';
