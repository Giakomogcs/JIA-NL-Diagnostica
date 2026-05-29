-- =============================================
-- NL Diagnostica — 005: Editais de Licitação (schema)
--
-- Modela o domínio de "Editais de Licitação Integrada":
--   * nl_portal       — portais de origem (Effecti, Licita Já, ComprasNet...)
--   * nl_catalogo     — catálogo de produtos/serviços que a NL Diagnostica
--                       realmente oferece (linha Hemostasia etc.) + palavras-chave
--   * nl_edital       — cabeçalho do edital (espelho da Licitacao da Effecti)
--   * nl_edital_item  — itens/lotes do edital
--   * nl_batch        — processamento em LOTES (não sobrecarregar análise)
--   * nl_decision_log — histórico de decisões (base do APRENDIZADO)
--
-- Dedupe: nl_edital.id_licitacao é UNIQUE (id da Effecti) — reprocessar o
-- mesmo edital faz UPDATE, nunca duplica.
-- Rode APÓS 004_chat_messages.sql
-- =============================================

-- =======  UP  ========

-- helper: parse de data BR ('DD/MM/YYYY HH24:MI:SS' ou ISO) -> timestamptz
CREATE OR REPLACE FUNCTION nl_parse_ts(p_txt TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v TIMESTAMPTZ;
BEGIN
  IF p_txt IS NULL OR TRIM(p_txt) = '' THEN
    RETURN NULL;
  END IF;
  -- tenta ISO primeiro
  BEGIN
    v := p_txt::timestamptz;
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  -- tenta formato BR com hora
  BEGIN
    RETURN to_timestamp(p_txt, 'DD/MM/YYYY HH24:MI:SS');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  -- tenta formato BR só data
  BEGIN
    RETURN to_timestamp(p_txt, 'DD/MM/YYYY');
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
END;
$$;

-- ---------- portais ----------
CREATE TABLE IF NOT EXISTS nl_portal (
  code       TEXT PRIMARY KEY,            -- EFFECTI, LICITAJA, COMPRASNET
  name       TEXT NOT NULL,
  base_url   TEXT,                        -- URL do portal
  api_kind   TEXT,                        -- effecti | licitaja | comprasnet | manual
  active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------- catálogo de produtos/serviços ----------
CREATE TABLE IF NOT EXISTS nl_catalogo (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo          TEXT NOT NULL DEFAULT 'produto'  CHECK (tipo IN ('produto','servico')),
  linha         TEXT,                              -- ex.: Hemostasia
  descricao     TEXT NOT NULL,                     -- nome do produto/serviço
  finalidade    TEXT,                              -- finalidade de uso
  palavras_chave TEXT[] NOT NULL DEFAULT '{}',     -- termos para casar com o edital
  sinonimos     TEXT[] NOT NULL DEFAULT '{}',
  marca         TEXT,
  ncm           TEXT,
  registro_anvisa TEXT,
  ativo         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_nl_catalogo_ativo ON nl_catalogo(ativo);
CREATE INDEX IF NOT EXISTS idx_nl_catalogo_kw    ON nl_catalogo USING gin (palavras_chave);

DROP TRIGGER IF EXISTS trg_nl_catalogo_updated_at ON nl_catalogo;
CREATE TRIGGER trg_nl_catalogo_updated_at
  BEFORE UPDATE ON nl_catalogo
  FOR EACH ROW EXECUTE FUNCTION nl_set_updated_at();

-- ---------- lotes de processamento ----------
CREATE TABLE IF NOT EXISTS nl_batch (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  label       TEXT,
  status      TEXT NOT NULL DEFAULT 'pendente'
              CHECK (status IN ('pendente','processando','concluido','erro')),
  total       INT NOT NULL DEFAULT 0,
  processados INT NOT NULL DEFAULT 0,
  aceitos     INT NOT NULL DEFAULT 0,
  recusados   INT NOT NULL DEFAULT 0,
  params      JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at  TIMESTAMPTZ,
  finished_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_nl_batch_status ON nl_batch(status);

-- ---------- editais (cabeçalho) ----------
CREATE TABLE IF NOT EXISTS nl_edital (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  id_licitacao          BIGINT UNIQUE,             -- id Effecti (dedupe)
  dedupe_hash           TEXT,                       -- fallback p/ origem sem id
  portal_code           TEXT REFERENCES nl_portal(code) ON DELETE SET NULL,
  portal_nome           TEXT,                       -- nome livre do portal (raw)
  numero_edital         TEXT,                       -- processo
  orgao                 TEXT,
  uf                    TEXT,
  modalidade            TEXT,
  cnpj_orgao            TEXT,
  uasg                  TEXT,
  objeto                TEXT,
  data_publicacao       TIMESTAMPTZ,
  data_abertura         TIMESTAMPTZ,                -- data da licitação (dataFinalProposta)
  data_inicial_proposta TIMESTAMPTZ,
  data_final_proposta   TIMESTAMPTZ,
  valor_total_estimado  NUMERIC,
  url_edital            TEXT,                       -- link do edital no portal
  url_portal            TEXT,                       -- link do portal (Effecti/origem)
  palavras_encontradas  JSONB,
  modo_participacao     TEXT NOT NULL DEFAULT 'indefinido'
                        CHECK (modo_participacao IN ('produto','lote','total','indefinido','nenhum')),
  score_match           NUMERIC NOT NULL DEFAULT 0,  -- 0..1
  status                TEXT NOT NULL DEFAULT 'novo'
                        CHECK (status IN ('novo','analisando','sugerido_aceitar','sugerido_recusar','aceito','recusado')),
  sugestao_ia           TEXT,                        -- aceitar | recusar | revisar
  justificativa_ia      TEXT,
  decisao_final         TEXT,                        -- aceito | recusado
  decisao_motivo        TEXT,
  decisao_motivo_effecti TEXT,                       -- enum da Effecti, se recusa
  decidido_por          UUID,
  decidido_em           TIMESTAMPTZ,
  sincronizado_effecti  BOOLEAN NOT NULL DEFAULT FALSE,
  batch_id              UUID REFERENCES nl_batch(id) ON DELETE SET NULL,
  raw                   JSONB,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_nl_edital_status   ON nl_edital(status);
CREATE INDEX IF NOT EXISTS idx_nl_edital_uf       ON nl_edital(uf);
CREATE INDEX IF NOT EXISTS idx_nl_edital_abertura ON nl_edital(data_abertura);
CREATE INDEX IF NOT EXISTS idx_nl_edital_batch    ON nl_edital(batch_id);
CREATE INDEX IF NOT EXISTS idx_nl_edital_dedupe   ON nl_edital(dedupe_hash);

DROP TRIGGER IF EXISTS trg_nl_edital_updated_at ON nl_edital;
CREATE TRIGGER trg_nl_edital_updated_at
  BEFORE UPDATE ON nl_edital
  FOR EACH ROW EXECUTE FUNCTION nl_set_updated_at();

-- ---------- itens / lotes do edital ----------
CREATE TABLE IF NOT EXISTS nl_edital_item (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  edital_id       UUID NOT NULL REFERENCES nl_edital(id) ON DELETE CASCADE,
  lote            TEXT,
  item_num        INT,
  produto_licitado TEXT,
  quantidade      NUMERIC,
  unidade         TEXT,
  valor_unitario  NUMERIC,
  valor_total     NUMERIC,
  catalogo_id     UUID REFERENCES nl_catalogo(id) ON DELETE SET NULL,
  match_score     NUMERIC NOT NULL DEFAULT 0,
  participa       BOOLEAN NOT NULL DEFAULT FALSE,
  motivo          TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_nl_item_edital ON nl_edital_item(edital_id);
CREATE INDEX IF NOT EXISTS idx_nl_item_lote   ON nl_edital_item(edital_id, lote);

-- ---------- log de decisões (base do aprendizado) ----------
CREATE TABLE IF NOT EXISTS nl_decision_log (
  id              BIGSERIAL PRIMARY KEY,
  edital_id       UUID REFERENCES nl_edital(id) ON DELETE SET NULL,
  id_licitacao    BIGINT,
  acao            TEXT NOT NULL CHECK (acao IN ('aceitar','recusar')),
  motivo          TEXT,
  motivo_effecti  TEXT,
  origem          TEXT NOT NULL DEFAULT 'humano' CHECK (origem IN ('humano','ia')),
  score_match     NUMERIC,
  palavras        JSONB,         -- palavras_encontradas no momento da decisão
  objeto          TEXT,          -- objeto do edital (sinal de aprendizado)
  uf              TEXT,
  snapshot        JSONB,
  user_id         UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_nl_declog_edital ON nl_decision_log(edital_id);
CREATE INDEX IF NOT EXISTS idx_nl_declog_acao   ON nl_decision_log(acao);

-- ---------- RLS: leitura para membros, escrita via RPC/service_role ----------
ALTER TABLE nl_portal       ENABLE ROW LEVEL SECURITY;
ALTER TABLE nl_catalogo     ENABLE ROW LEVEL SECURITY;
ALTER TABLE nl_batch        ENABLE ROW LEVEL SECURITY;
ALTER TABLE nl_edital       ENABLE ROW LEVEL SECURITY;
ALTER TABLE nl_edital_item  ENABLE ROW LEVEL SECURITY;
ALTER TABLE nl_decision_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS nl_portal_sel    ON nl_portal;
DROP POLICY IF EXISTS nl_catalogo_sel  ON nl_catalogo;
DROP POLICY IF EXISTS nl_batch_sel     ON nl_batch;
DROP POLICY IF EXISTS nl_edital_sel    ON nl_edital;
DROP POLICY IF EXISTS nl_item_sel      ON nl_edital_item;
DROP POLICY IF EXISTS nl_declog_sel    ON nl_decision_log;

CREATE POLICY nl_portal_sel   ON nl_portal       FOR SELECT TO authenticated USING (nl_is_member());
CREATE POLICY nl_catalogo_sel ON nl_catalogo     FOR SELECT TO authenticated USING (nl_is_member());
CREATE POLICY nl_batch_sel    ON nl_batch        FOR SELECT TO authenticated USING (nl_is_member());
CREATE POLICY nl_edital_sel   ON nl_edital       FOR SELECT TO authenticated USING (nl_is_member());
CREATE POLICY nl_item_sel     ON nl_edital_item  FOR SELECT TO authenticated USING (nl_is_member());
CREATE POLICY nl_declog_sel   ON nl_decision_log FOR SELECT TO authenticated USING (nl_is_member());

GRANT SELECT ON nl_portal, nl_catalogo, nl_batch, nl_edital, nl_edital_item, nl_decision_log TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP TABLE IF EXISTS nl_decision_log;
-- DROP TABLE IF EXISTS nl_edital_item;
-- DROP TABLE IF EXISTS nl_edital;
-- DROP TABLE IF EXISTS nl_batch;
-- DROP TABLE IF EXISTS nl_catalogo;
-- DROP TABLE IF EXISTS nl_portal;
-- DROP FUNCTION IF EXISTS nl_parse_ts(TEXT);
-- NOTIFY pgrst, 'reload schema';
