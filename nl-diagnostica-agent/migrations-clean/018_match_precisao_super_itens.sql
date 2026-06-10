-- =============================================
-- NL Diagnostica — 018: precisão do match (siglas curtas) +
--                       super triagem reprocessa itens/lotes
--
-- PROBLEMA 1 (falso positivo): o Motor de Bulas gerou SIGLAS CURTAS como
--   termos fortes (ex.: "tca" = tempo de coagulação ativada). Um item
--   "Veiculo: M. BENZ / SPRINTER TCA MIC CHASSI..." casou "tca" (forte)
--   + "mic" (fraco) => 85% Sistema de hemostasia POC. Correções:
--   a) data fix: termos_fortes com <= 3 chars migram para sinonimos;
--   b) nl_match_edital: termo forte curto (<=3) passa a contar só como APOIO;
--   c) nl_catalogo_merge_termos: novas siglas curtas vão direto p/ sinonimos;
--   d) negativos de veículos/transporte.
--
-- PROBLEMA 2: a Super Triagem só gravava analise_profunda; agora o LLM
--   devolve "itens_avaliacao" (um veredito por item: participa + match 0-100
--   + linha) e nl_set_analise_profunda APLICA isso nos itens (sim/não, %,
--   catálogo, motivo) e recalcula score/modo/status/justificativa do edital.
--
-- Rode APÓS 017_motor_bulas.sql. Depois clique "↻ Reprocessar análises".
-- =============================================

-- =======  UP  ========

-- ---------- (1a) data fix: siglas curtas saem de termos_fortes ----------
UPDATE nl_catalogo
   SET sinonimos = (
         SELECT COALESCE(array_agg(DISTINCT s), '{}')
           FROM unnest(sinonimos ||
                       ARRAY(SELECT t FROM unnest(termos_fortes) t
                              WHERE char_length(btrim(t)) <= 3)) s
          WHERE btrim(s) <> ''),
       termos_fortes = ARRAY(SELECT t FROM unnest(termos_fortes) t
                              WHERE char_length(btrim(t)) > 3),
       updated_at = NOW()
 WHERE EXISTS (SELECT 1 FROM unnest(termos_fortes) t
                WHERE char_length(btrim(t)) <= 3);

-- ---------- (1d) negativos: veículos / transporte ----------
INSERT INTO nl_match_negativo(termo, motivo) VALUES
  ('veículo',     'veículo/transporte — fora do escopo NL'),
  ('veiculo',     'veículo/transporte — fora do escopo NL'),
  ('chassi',      'veículo/transporte — fora do escopo NL'),
  ('caminhonete', 'veículo/transporte — fora do escopo NL'),
  ('caminhão',    'veículo/transporte — fora do escopo NL'),
  ('caminhao',    'veículo/transporte — fora do escopo NL'),
  ('automóvel',   'veículo/transporte — fora do escopo NL'),
  ('automovel',   'veículo/transporte — fora do escopo NL'),
  ('motocicleta', 'veículo/transporte — fora do escopo NL'),
  ('ambulância',  'veículo/transporte — fora do escopo NL'),
  ('ambulancia',  'veículo/transporte — fora do escopo NL'),
  ('pneu',        'peça de veículo — fora do escopo NL')
ON CONFLICT (termo) DO NOTHING;

-- ---------- (1b) nl_match_edital v3: sigla curta só apoia ----------
CREATE OR REPLACE FUNCTION nl_match_edital(p_edital_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  r_item       RECORD;
  r_cat        RECORD;
  v_prod       TEXT;
  v_objeto     TEXT;
  v_blocked    TEXT;
  v_strong_hit TEXT;
  v_weak       INT;
  v_strong     INT;
  v_score      NUMERIC;
  v_best_score NUMERIC;
  v_best_id    UUID;
  v_best_terms TEXT;
  v_total      INT := 0;
  v_part       INT := 0;
  v_has_lote   BOOLEAN := FALSE;
  v_lotes_ok   INT := 0;
  v_lotes_tot  INT := 0;
  v_modo       TEXT;
  v_sugestao   TEXT;
  v_status     TEXT;
  v_smatch     NUMERIC;
  v_obj_strong BOOLEAN := FALSE;
  v_strong_terms TEXT := '';
  v_blocked_terms TEXT := '';
  kw           TEXT;
  neg          TEXT;
BEGIN
  SELECT lower(COALESCE(objeto,'')) INTO v_objeto FROM nl_edital WHERE id = p_edital_id;

  FOR r_item IN SELECT * FROM nl_edital_item WHERE edital_id = p_edital_id LOOP
    v_total := v_total + 1;
    v_prod := lower(COALESCE(r_item.produto_licitado, ''));
    v_best_score := 0; v_best_id := NULL; v_best_terms := '';

    -- RF2: bloqueio por termo negativo (item sai de escopo de imediato)
    v_blocked := NULL;
    FOR neg IN SELECT termo FROM nl_match_negativo WHERE ativo LOOP
      IF nl_kw_match(v_prod, neg) THEN
        v_blocked := neg;
        EXIT;
      END IF;
    END LOOP;

    IF v_blocked IS NOT NULL THEN
      UPDATE nl_edital_item
         SET catalogo_id = NULL, match_score = 0, participa = FALSE,
             motivo = 'bloqueado (fora de escopo): ' || v_blocked
       WHERE id = r_item.id;
      IF position(v_blocked IN v_blocked_terms) = 0 THEN
        v_blocked_terms := v_blocked_terms || CASE WHEN v_blocked_terms = '' THEN '' ELSE ', ' END || v_blocked;
      END IF;
      IF COALESCE(r_item.lote,'') <> '' THEN v_has_lote := TRUE; END IF;
      CONTINUE;
    END IF;

    -- procura melhor catálogo: exige >= 1 termo FORTE com 4+ chars (RF1)
    FOR r_cat IN SELECT * FROM nl_catalogo WHERE ativo LOOP
      v_strong := 0; v_weak := 0; v_strong_hit := NULL;
      -- termos fortes (siglas curtas <=3 chars contam só como apoio)
      FOREACH kw IN ARRAY COALESCE(r_cat.termos_fortes,'{}') LOOP
        IF nl_kw_match(v_prod, kw) THEN
          IF char_length(btrim(kw)) >= 4 THEN
            v_strong := v_strong + 1;
            IF v_strong_hit IS NULL THEN v_strong_hit := kw; END IF;
          ELSE
            v_weak := v_weak + 1;
          END IF;
        END IF;
      END LOOP;
      -- termos fracos (apoio)
      FOREACH kw IN ARRAY (COALESCE(r_cat.palavras_chave,'{}') || COALESCE(r_cat.sinonimos,'{}')) LOOP
        IF nl_kw_match(v_prod, kw) THEN v_weak := v_weak + 1; END IF;
      END LOOP;

      IF v_strong >= 1 THEN
        v_score := LEAST(1.0, 0.6 + 0.2 * v_strong + 0.05 * v_weak);
        IF v_score > v_best_score THEN
          v_best_score := v_score; v_best_id := r_cat.id; v_best_terms := v_strong_hit;
        END IF;
      END IF;
    END LOOP;

    UPDATE nl_edital_item
       SET catalogo_id = v_best_id,
           match_score = v_best_score,
           participa   = (v_best_score > 0),
           motivo      = CASE WHEN v_best_score > 0
                              THEN 'casou termo forte: ' || COALESCE(v_best_terms,'?')
                              ELSE 'sem termo forte do catálogo' END
     WHERE id = r_item.id;

    IF v_best_score > 0 THEN
      v_part := v_part + 1;
      IF v_best_terms IS NOT NULL AND position(v_best_terms IN v_strong_terms) = 0 THEN
        v_strong_terms := v_strong_terms || CASE WHEN v_strong_terms = '' THEN '' ELSE ', ' END || v_best_terms;
      END IF;
    END IF;
    IF COALESCE(r_item.lote,'') <> '' THEN v_has_lote := TRUE; END IF;
  END LOOP;

  -- RF3: sinal do objeto (termo forte 4+ chars de qualquer linha) — fallback
  FOR r_cat IN SELECT termos_fortes FROM nl_catalogo WHERE ativo LOOP
    FOREACH kw IN ARRAY COALESCE(r_cat.termos_fortes,'{}') LOOP
      IF char_length(btrim(kw)) >= 4 AND nl_kw_match(v_objeto, kw) THEN
        v_obj_strong := TRUE;
        IF position(kw IN v_strong_terms) = 0 THEN
          v_strong_terms := v_strong_terms || CASE WHEN v_strong_terms = '' THEN '' ELSE ', ' END || kw;
        END IF;
      END IF;
    END LOOP;
    EXIT WHEN v_obj_strong;
  END LOOP;

  -- cobertura por lote (lote fornecível = todos os itens participam)
  IF v_has_lote THEN
    SELECT
      COUNT(*) FILTER (WHERE total_itens = itens_part),
      COUNT(*)
    INTO v_lotes_ok, v_lotes_tot
    FROM (
      SELECT lote, COUNT(*) AS total_itens, COUNT(*) FILTER (WHERE participa) AS itens_part
        FROM nl_edital_item
       WHERE edital_id = p_edital_id AND COALESCE(lote,'') <> ''
       GROUP BY lote
    ) g;
  END IF;

  v_smatch := CASE WHEN v_total = 0 THEN 0 ELSE ROUND(v_part::numeric / v_total, 3) END;

  IF v_part = 0 THEN
    v_modo := 'nenhum';
  ELSIF v_part = v_total THEN
    v_modo := 'total';
  ELSIF v_has_lote AND v_lotes_ok > 0 THEN
    v_modo := 'lote';
  ELSE
    v_modo := 'produto';
  END IF;

  IF v_total = 0 THEN
    IF v_obj_strong THEN
      v_sugestao := 'revisar'; v_status := 'analisando';
    ELSE
      v_sugestao := 'recusar'; v_status := 'sugerido_recusar';
    END IF;
  ELSIF v_part = 0 THEN
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
         justificativa_ia = CASE
            WHEN v_total = 0 AND v_obj_strong THEN
              format('Sem itens detalhados; objeto casou termo forte (%s). Revisar.', v_strong_terms)
            WHEN v_total = 0 THEN
              'Sem itens detalhados e sem termo forte no objeto.'
            WHEN v_part = 0 THEN
              format('%s de %s itens; nenhum termo forte do catálogo.%s', v_part, v_total,
                     CASE WHEN v_blocked_terms <> '' THEN ' Bloqueados: '||v_blocked_terms||'.' ELSE '' END)
            ELSE
              format('%s de %s itens casaram (score %s, modo %s). Termos fortes: %s.%s',
                     v_part, v_total, v_smatch, v_modo, NULLIF(v_strong_terms,''),
                     CASE WHEN v_blocked_terms <> '' THEN ' Bloqueados: '||v_blocked_terms||'.' ELSE '' END)
         END,
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
    'sugestao', v_sugestao,
    'termos_fortes', NULLIF(v_strong_terms,''),
    'bloqueados', NULLIF(v_blocked_terms,'')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION nl_match_edital(UUID) TO authenticated, service_role;

-- ---------- (1c) merge de termos: siglas curtas viram sinônimos ----------
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

  -- siglas curtas (<=3 chars) nunca entram como termo forte: vão p/ sinônimos
  v_sin    := v_sin || ARRAY(SELECT t FROM unnest(v_fortes) t WHERE char_length(t) <= 3);
  v_fortes := ARRAY(SELECT t FROM unnest(v_fortes) t WHERE char_length(t) > 3);

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

-- ---------- (2) super triagem aplica veredito nos itens ----------
-- p_analise pode trazer "itens_avaliacao":
--   [{"id":"<uuid do nl_edital_item>","participa":true,"match":85,
--     "linha_catalogo":"Hemostasia","motivo":"..."}]
-- Para cada entrada: atualiza participa / match_score (0-1) / catalogo_id /
-- motivo do item. Depois recalcula score_match, modo_participacao,
-- sugestao_ia, justificativa_ia e status do edital (preserva aceito/recusado).
CREATE OR REPLACE FUNCTION nl_set_analise_profunda(
  p_edital_id UUID,
  p_analise   JSONB
)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  a            JSONB;
  v_itens      INT := 0;
  v_part_flag  BOOLEAN;
  v_match      NUMERIC;
  v_cat        UUID;
  v_total      INT;
  v_part       INT;
  v_lotes_ok   INT := 0;
  v_lotes_tot  INT := 0;
  v_has_lote   BOOLEAN;
  v_smatch     NUMERIC;
  v_modo       TEXT;
  v_rec        TEXT;
  v_sugestao   TEXT;
  v_status     TEXT;
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

  -- aplica avaliação item a item (quando o LLM devolveu)
  FOR a IN SELECT * FROM jsonb_array_elements(COALESCE(p_analise->'itens_avaliacao','[]'::jsonb)) LOOP
    CONTINUE WHEN COALESCE(a->>'id','') = '';
    v_part_flag := COALESCE((a->>'participa')::boolean, FALSE);
    v_match := ROUND(LEAST(100, GREATEST(0, COALESCE(NULLIF(a->>'match','')::numeric, 0))) / 100.0, 2);
    v_cat := NULL;
    IF v_part_flag AND COALESCE(a->>'linha_catalogo','') <> '' THEN
      SELECT id INTO v_cat FROM nl_catalogo
       WHERE ativo AND lower(linha) = lower(a->>'linha_catalogo')
       LIMIT 1;
    END IF;

    UPDATE nl_edital_item
       SET participa   = v_part_flag,
           match_score = v_match,
           catalogo_id = CASE WHEN v_part_flag THEN COALESCE(v_cat, catalogo_id) ELSE NULL END,
           motivo      = 'super triagem: ' ||
                         COALESCE(NULLIF(a->>'motivo',''),
                                  CASE WHEN v_part_flag THEN 'compatível' ELSE 'incompatível' END)
     WHERE edital_id = p_edital_id AND id::text = (a->>'id');
    IF FOUND THEN v_itens := v_itens + 1; END IF;
  END LOOP;

  -- recalcula agregados do edital quando itens foram reavaliados
  IF v_itens > 0 THEN
    SELECT COUNT(*), COUNT(*) FILTER (WHERE participa),
           bool_or(COALESCE(lote,'') <> '')
      INTO v_total, v_part, v_has_lote
      FROM nl_edital_item WHERE edital_id = p_edital_id;

    IF v_has_lote THEN
      SELECT COUNT(*) FILTER (WHERE total_itens = itens_part), COUNT(*)
        INTO v_lotes_ok, v_lotes_tot
        FROM (SELECT lote, COUNT(*) AS total_itens,
                     COUNT(*) FILTER (WHERE participa) AS itens_part
                FROM nl_edital_item
               WHERE edital_id = p_edital_id AND COALESCE(lote,'') <> ''
               GROUP BY lote) g;
    END IF;

    v_smatch := CASE WHEN v_total = 0 THEN 0 ELSE ROUND(v_part::numeric / v_total, 3) END;
    IF v_part = 0 THEN v_modo := 'nenhum';
    ELSIF v_part = v_total THEN v_modo := 'total';
    ELSIF v_has_lote AND v_lotes_ok > 0 THEN v_modo := 'lote';
    ELSE v_modo := 'produto';
    END IF;

    v_rec := lower(COALESCE(p_analise->>'recomendacao',''));
    IF v_rec = 'aceitar' AND v_part > 0 THEN
      v_sugestao := 'aceitar'; v_status := 'sugerido_aceitar';
    ELSIF v_rec = 'recusar' OR v_part = 0 THEN
      v_sugestao := 'recusar'; v_status := 'sugerido_recusar';
    ELSE
      v_sugestao := 'revisar'; v_status := 'analisando';
    END IF;

    UPDATE nl_edital
       SET score_match = v_smatch,
           modo_participacao = v_modo,
           sugestao_ia = v_sugestao,
           justificativa_ia = 'Super triagem (IA): ' ||
             COALESCE(NULLIF(p_analise->>'resumo',''),
                      format('%s de %s itens compatíveis', v_part, v_total)),
           status = CASE WHEN status IN ('aceito','recusado') THEN status ELSE v_status END,
           updated_at = NOW()
     WHERE id = p_edital_id;
  END IF;

  RETURN jsonb_build_object(
    'edital_id', p_edital_id, 'salvo', TRUE,
    'itens_atualizados', v_itens);
END;
$$;

GRANT EXECUTE ON FUNCTION nl_set_analise_profunda(UUID, JSONB) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- nl_match_edital / nl_catalogo_merge_termos: versões anteriores em 012 e 017.
-- nl_set_analise_profunda: versão anterior em 016.
-- DELETE FROM nl_match_negativo WHERE motivo LIKE '%veículo/transporte%' OR termo='pneu';
