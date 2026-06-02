-- =============================================
-- NL Diagnostica — 013: reprocessamento em LOTES (corrige statement timeout)
--
-- Problema: nl_rematch_all reprocessava ~350 editais numa única transação;
-- com o match v2 (mais pesado) isso estoura o statement_timeout do Supabase.
--
-- Solução:
--   1. Flag nl_edital.rematch_pending — marca o que falta reprocessar.
--   2. nl_match_edital otimizado: carrega os termos negativos UMA vez por
--      chamada (antes era um SELECT por item) e baixa a flag ao terminar.
--   3. nl_rematch_reset() — marca o conjunto-alvo como pendente.
--   4. nl_rematch_all(p_only_pending, p_limit) — processa só p_limit por
--      chamada e devolve {reprocessados, restantes}. O front chama em loop
--      até restantes = 0, mantendo cada chamada abaixo do timeout.
--
-- Rode APÓS 012_match_v2.sql.
-- =============================================

-- =======  UP  ========

-- ---------- flag de reprocessamento ----------
ALTER TABLE nl_edital
  ADD COLUMN IF NOT EXISTS rematch_pending BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS idx_nl_edital_rematch
  ON nl_edital(rematch_pending) WHERE rematch_pending;

-- ---------- nl_match_edital v2.1 (negativos carregados uma vez) ----------
CREATE OR REPLACE FUNCTION nl_match_edital(p_edital_id UUID)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  r_item       RECORD;
  r_cat        RECORD;
  v_prod       TEXT;
  v_objeto     TEXT;
  v_negs       TEXT[];
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

  -- carrega termos negativos UMA vez (antes: 1 query por item)
  SELECT array_agg(termo) INTO v_negs FROM nl_match_negativo WHERE ativo;
  v_negs := COALESCE(v_negs, '{}');

  FOR r_item IN SELECT * FROM nl_edital_item WHERE edital_id = p_edital_id LOOP
    v_total := v_total + 1;
    v_prod := lower(COALESCE(r_item.produto_licitado, ''));
    v_best_score := 0; v_best_id := NULL; v_best_terms := '';

    -- RF2: bloqueio por termo negativo
    v_blocked := NULL;
    FOREACH neg IN ARRAY v_negs LOOP
      IF nl_kw_match(v_prod, neg) THEN v_blocked := neg; EXIT; END IF;
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

    -- RF1: exige >= 1 termo FORTE
    FOR r_cat IN SELECT * FROM nl_catalogo WHERE ativo LOOP
      v_strong := 0; v_weak := 0; v_strong_hit := NULL;
      FOREACH kw IN ARRAY COALESCE(r_cat.termos_fortes,'{}') LOOP
        IF nl_kw_match(v_prod, kw) THEN
          v_strong := v_strong + 1;
          IF v_strong_hit IS NULL THEN v_strong_hit := kw; END IF;
        END IF;
      END LOOP;
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

  -- RF3: termo forte no objeto (fallback p/ editais sem itens)
  FOR r_cat IN SELECT termos_fortes FROM nl_catalogo WHERE ativo LOOP
    FOREACH kw IN ARRAY COALESCE(r_cat.termos_fortes,'{}') LOOP
      IF nl_kw_match(v_objeto, kw) THEN
        v_obj_strong := TRUE;
        IF position(kw IN v_strong_terms) = 0 THEN
          v_strong_terms := v_strong_terms || CASE WHEN v_strong_terms = '' THEN '' ELSE ', ' END || kw;
        END IF;
      END IF;
    END LOOP;
    EXIT WHEN v_obj_strong;
  END LOOP;

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
         rematch_pending = FALSE,
         updated_at = NOW()
   WHERE id = p_edital_id;

  RETURN jsonb_build_object(
    'edital_id', p_edital_id,
    'itens_total', v_total,
    'itens_participa', v_part,
    'score_match', v_smatch,
    'modo_participacao', v_modo,
    'sugestao', v_sugestao,
    'termos_fortes', NULLIF(v_strong_terms,''),
    'bloqueados', NULLIF(v_blocked_terms,'')
  );
END;
$$;

-- ---------- marca o conjunto-alvo como pendente de reprocesso ----------
CREATE OR REPLACE FUNCTION nl_rematch_reset(p_only_pending BOOLEAN DEFAULT TRUE)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE v_qtd INT;
BEGIN
  IF NOT (nl_is_admin() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  UPDATE nl_edital
     SET rematch_pending = TRUE
   WHERE (NOT p_only_pending) OR status NOT IN ('aceito','recusado');
  GET DIAGNOSTICS v_qtd = ROW_COUNT;
  RETURN jsonb_build_object('marcados', v_qtd);
END;
$$;

-- ---------- reprocessa em LOTES (chunked) ----------
-- p_limit = NULL processa tudo (compat antigo); com valor, processa por lote.
-- Se nada estiver pendente, semeia automaticamente o conjunto-alvo.
DROP FUNCTION IF EXISTS nl_rematch_all(BOOLEAN);
CREATE OR REPLACE FUNCTION nl_rematch_all(
  p_only_pending BOOLEAN DEFAULT TRUE,
  p_limit        INT     DEFAULT 40
)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  r_ed       RECORD;
  v_qtd      INT := 0;
  v_pend     INT;
  v_rest     INT;
BEGIN
  IF NOT (nl_is_admin() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;

  -- semeia na primeira chamada (nenhum pendente ainda)
  SELECT COUNT(*) INTO v_pend FROM nl_edital WHERE rematch_pending;
  IF v_pend = 0 THEN
    UPDATE nl_edital
       SET rematch_pending = TRUE
     WHERE (NOT p_only_pending) OR status NOT IN ('aceito','recusado');
  END IF;

  FOR r_ed IN
    SELECT id FROM nl_edital
     WHERE rematch_pending
     ORDER BY data_abertura NULLS LAST
     LIMIT CASE WHEN p_limit IS NULL OR p_limit <= 0 THEN 100000 ELSE p_limit END
  LOOP
    PERFORM nl_match_edital(r_ed.id);  -- já baixa rematch_pending
    v_qtd := v_qtd + 1;
  END LOOP;

  SELECT COUNT(*) INTO v_rest FROM nl_edital WHERE rematch_pending;

  RETURN jsonb_build_object(
    'reprocessados', v_qtd,
    'restantes', v_rest,
    'only_pending', p_only_pending
  );
END;
$$;

GRANT EXECUTE ON FUNCTION nl_match_edital(UUID)            TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_rematch_reset(BOOLEAN)        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_rematch_all(BOOLEAN,INT)      TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS nl_rematch_all(BOOLEAN,INT);
-- DROP FUNCTION IF EXISTS nl_rematch_reset(BOOLEAN);
-- ALTER TABLE nl_edital DROP COLUMN IF EXISTS rematch_pending;
