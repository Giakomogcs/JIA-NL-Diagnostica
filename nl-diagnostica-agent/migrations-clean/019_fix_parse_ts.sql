-- =============================================
-- NL Diagnostica — 019: corrige inversão de datas (nl_parse_ts) + backfill
--
-- PROBLEMA: nl_parse_ts (005) tenta `p_txt::timestamptz` ANTES do parser BR.
--   Com DateStyle padrão (MDY), "03/07/2026" (3 de julho) é aceito como
--   MM/DD => 7 de março, e a função retorna logo. Resultado: TODAS as datas
--   no formato brasileiro (Effecti: dataPublicacao, dataFinalProposta,
--   dataInicialProposta) ficaram com dia/mês trocados quando dia <= 12.
--   Ex.: edital 019/2026: dataFinalProposta "03/07/2026" virou 2026-03-07.
--
-- FIX: detectar o padrão BR (dd/mm/yyyy[ hh:mm:ss]) e parsear como
--   DD/MM/YYYY ANTES de tentar o cast ISO genérico. ISO (com '-') continua
--   tratado pelo cast direto.
--
-- BACKFILL: recomputa data_publicacao / data_abertura / data_final_proposta /
--   data_inicial_proposta a partir de nl_edital.raw (preservado na ingestão),
--   tratando Effecti e Licita Já. Editais 'manual' sem raw equivalente ficam
--   como estão.
--
-- Rode APÓS 018_match_precisao_super_itens.sql.
-- =============================================

-- =======  UP  ========

-- ---------- parser de timestamp robusto (BR primeiro) ----------
CREATE OR REPLACE FUNCTION nl_parse_ts(p_txt TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v   TIMESTAMPTZ;
  t   TEXT := btrim(COALESCE(p_txt, ''));
BEGIN
  IF t = '' THEN
    RETURN NULL;
  END IF;

  -- 1) formato BR explícito dd/mm/yyyy (com ou sem hora) — tratar ANTES do
  --    cast genérico, que interpretaria dd/mm como mm/dd (DateStyle MDY).
  IF t ~ '^\d{1,2}/\d{1,2}/\d{4}( \d{1,2}:\d{2}(:\d{2})?)?$' THEN
    BEGIN
      IF position(':' IN t) > 0 THEN
        RETURN to_timestamp(t, 'DD/MM/YYYY HH24:MI:SS');
      ELSE
        RETURN to_timestamp(t, 'DD/MM/YYYY');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      NULL;  -- cai para as tentativas seguintes
    END;
  END IF;

  -- 2) ISO / qualquer coisa que o Postgres aceite diretamente
  BEGIN
    v := t::timestamptz;
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- 3) último recurso: BR sem padrão estrito (datas tipo 1/2/2026)
  BEGIN
    RETURN to_timestamp(t, 'DD/MM/YYYY HH24:MI:SS');
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      RETURN to_timestamp(t, 'DD/MM/YYYY');
    EXCEPTION WHEN OTHERS THEN
      RETURN NULL;
    END;
  END;
END;
$$;

-- ---------- backfill: recomputa datas a partir do raw ----------
-- Effecti: usa dataPublicacao / dataFinalProposta / dataInicialProposta.
UPDATE nl_edital e
   SET data_publicacao       = nl_parse_ts(e.raw->>'dataPublicacao'),
       data_abertura         = nl_parse_ts(e.raw->>'dataFinalProposta'),
       data_final_proposta   = nl_parse_ts(e.raw->>'dataFinalProposta'),
       data_inicial_proposta = nl_parse_ts(e.raw->>'dataInicialProposta'),
       updated_at            = NOW()
 WHERE e.fonte = 'effecti'
   AND e.raw ? 'dataFinalProposta';

-- Licita Já: usa catalog_date / close_date.
UPDATE nl_edital e
   SET data_publicacao     = nl_parse_ts(e.raw->>'catalog_date'),
       data_abertura       = nl_parse_ts(e.raw->>'close_date'),
       data_final_proposta = nl_parse_ts(e.raw->>'close_date'),
       updated_at          = NOW()
 WHERE e.fonte = 'licitaja'
   AND e.raw ? 'close_date';

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- Restaurar nl_parse_ts da 005 (cast genérico primeiro). As datas backfilladas
-- permanecem corretas; só a função volta ao comportamento anterior:
--
-- CREATE OR REPLACE FUNCTION nl_parse_ts(p_txt TEXT) RETURNS TIMESTAMPTZ
-- LANGUAGE plpgsql IMMUTABLE AS $$
-- DECLARE v TIMESTAMPTZ;
-- BEGIN
--   IF p_txt IS NULL OR TRIM(p_txt) = '' THEN RETURN NULL; END IF;
--   BEGIN v := p_txt::timestamptz; RETURN v; EXCEPTION WHEN OTHERS THEN NULL; END;
--   BEGIN RETURN to_timestamp(p_txt, 'DD/MM/YYYY HH24:MI:SS'); EXCEPTION WHEN OTHERS THEN NULL; END;
--   BEGIN RETURN to_timestamp(p_txt, 'DD/MM/YYYY'); EXCEPTION WHEN OTHERS THEN RETURN NULL; END;
-- END; $$;
