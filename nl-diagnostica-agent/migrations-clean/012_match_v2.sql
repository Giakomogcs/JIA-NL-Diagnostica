-- =============================================
-- NL Diagnostica — 012: nl_match_edital v2 (termos fortes/fracos/negativos)
--
-- Regras (ver Docs/PRD-precisao-busca-editais.md §5):
--   RF1  Item só "participa" se casar >= 1 termo FORTE (catálogo.termos_fortes).
--        Termos fracos (palavras_chave/sinonimos) sozinhos NÃO bastam.
--   RF2  Termos NEGATIVOS (nl_match_negativo) bloqueiam o item, mesmo com forte.
--   RF3  O objeto do edital é cruzado com termos fortes (reforça/decide fallback).
--   RF5  Edital sem itens: objeto com forte -> 'analisando'; senão 'sugerido_recusar'.
--   RF6  Aceite: modo total/lote com forte, ou score >= 0.5 com >=1 forte.
--   RF7  justificativa_ia registra termos fortes que casaram e negativos que bloquearam.
--   RF8  Não altera editais já 'aceito'/'recusado'.
--
-- Mantém a assinatura nl_match_edital(UUID) — nenhuma mudança no front/n8n.
-- Reaproveita nl_kw_match (fronteira de palavra, trata acentos/siglas).
-- Rode APÓS 011_catalogo_termos.sql.
-- =============================================

-- =======  UP  ========

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

    -- procura melhor catálogo: exige >= 1 termo FORTE (RF1)
    FOR r_cat IN SELECT * FROM nl_catalogo WHERE ativo LOOP
      v_strong := 0; v_weak := 0; v_strong_hit := NULL;
      -- termos fortes
      FOREACH kw IN ARRAY COALESCE(r_cat.termos_fortes,'{}') LOOP
        IF nl_kw_match(v_prod, kw) THEN
          v_strong := v_strong + 1;
          IF v_strong_hit IS NULL THEN v_strong_hit := kw; END IF;
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

  -- RF3: sinal do objeto (termo forte de qualquer linha) — usado no fallback
  FOR r_cat IN SELECT termos_fortes FROM nl_catalogo WHERE ativo LOOP
    FOREACH kw IN ARRAY COALESCE(r_cat.termos_fortes,'{}') LOOP
      IF nl_kw_match(v_objeto, kw) THEN
        v_obj_strong := TRUE;
        IF position(kw IN v_strong_terms) = 0 THEN
          v_strong_terms := v_strong_terms || CASE WHEN v_strong_terms = '' THEN '' ELSE ', ' END || kw;
        END IF;
      END IF;
    END LOOP;
    EXIT WHEN v_obj_strong;  -- basta detectar 1 p/ o fallback
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

  -- sugestão / status
  IF v_total = 0 THEN
    -- RF5: edital sem itens decide pelo objeto
    IF v_obj_strong THEN
      v_sugestao := 'revisar'; v_status := 'analisando';
    ELSE
      v_sugestao := 'recusar'; v_status := 'sugerido_recusar';
    END IF;
  ELSIF v_part = 0 THEN
    v_sugestao := 'recusar'; v_status := 'sugerido_recusar';
  ELSIF v_modo IN ('total','lote') OR v_smatch >= 0.5 THEN
    -- RF6: aceite exige item forte (garantido: v_part>0 só com termo forte)
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

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- Restaurar a versão de 006_licitacao_rpc.sql (match por substring/palavras_chave).
