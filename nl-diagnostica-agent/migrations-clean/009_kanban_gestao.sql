-- =============================================
-- NL Diagnostica — 009: Gestão de editais aceitos (board estilo kanban)
--
-- Os editais aceitos (status='aceito') passam a ser acompanhados em um
-- funil/board (estilo Monday.com). Cada edital aceito ganha uma ETAPA
-- (kanban_stage) e campos de gestão (responsável, prazo, prioridade,
-- valor da proposta, observações).
--
-- A aba "Buscar editais" continua usando nl_dashboard_editais (inalterado).
-- A nova aba "Gerenciar editais" usa nl_board_editais + nl_update_gestao.
--
-- Rode APÓS 005_licitacao_schema.sql e 006_licitacao_rpc.sql.
-- =============================================

-- =======  UP  ========

-- ---------- colunas de gestão em nl_edital ----------
ALTER TABLE nl_edital
  ADD COLUMN IF NOT EXISTS kanban_stage          TEXT
    CHECK (kanban_stage IN ('qualificado','documentacao','proposta_elaboracao',
                            'proposta_enviada','em_disputa','ganhou','perdeu')),
  ADD COLUMN IF NOT EXISTS gestao_responsavel    TEXT,
  ADD COLUMN IF NOT EXISTS gestao_prazo          DATE,
  ADD COLUMN IF NOT EXISTS gestao_prioridade     TEXT NOT NULL DEFAULT 'media'
    CHECK (gestao_prioridade IN ('baixa','media','alta')),
  ADD COLUMN IF NOT EXISTS gestao_valor_proposta NUMERIC,
  ADD COLUMN IF NOT EXISTS gestao_observacoes    TEXT,
  ADD COLUMN IF NOT EXISTS gestao_atualizado_em  TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_nl_edital_kanban ON nl_edital(kanban_stage);

-- backfill: editais já aceitos sem etapa entram na primeira coluna do funil
UPDATE nl_edital
   SET kanban_stage = 'qualificado'
 WHERE status = 'aceito' AND kanban_stage IS NULL;

-- =========================================================
-- BOARD — lista os editais aceitos com os campos de gestão.
-- Agrupamento por etapa é feito no frontend.
-- =========================================================
CREATE OR REPLACE FUNCTION nl_board_editais(
  p_stage    TEXT  DEFAULT NULL,   -- filtra por etapa (opcional)
  p_search   TEXT  DEFAULT NULL,   -- busca em objeto/orgao/numero (opcional)
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
  itens_total BIGINT, itens_participa BIGINT
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
    (SELECT COUNT(*) FROM nl_edital_item i WHERE i.edital_id = e.id AND i.participa)
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

-- =========================================================
-- ATUALIZA GESTÃO — etapa do funil / responsável / prazo / etc.
-- Parâmetros NULL são IGNORADOS (mantém o valor atual).
-- Usado ao arrastar o card (só p_stage) ou ao editar o card.
-- =========================================================
CREATE OR REPLACE FUNCTION nl_update_gestao(
  p_edital_id      UUID,
  p_stage          TEXT    DEFAULT NULL,
  p_responsavel    TEXT    DEFAULT NULL,
  p_prazo          DATE    DEFAULT NULL,
  p_prioridade     TEXT    DEFAULT NULL,
  p_valor_proposta NUMERIC DEFAULT NULL,
  p_observacoes    TEXT    DEFAULT NULL
)
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql AS $$
DECLARE
  v_e nl_edital;
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_e FROM nl_edital WHERE id = p_edital_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edital não encontrado.' USING ERRCODE = 'P0002';
  END IF;
  IF v_e.status <> 'aceito' THEN
    RAISE EXCEPTION 'Apenas editais aceitos podem ser geridos no board.' USING ERRCODE = '22023';
  END IF;

  IF p_stage IS NOT NULL AND p_stage NOT IN
     ('qualificado','documentacao','proposta_elaboracao','proposta_enviada','em_disputa','ganhou','perdeu') THEN
    RAISE EXCEPTION 'Etapa inválida: %.', p_stage USING ERRCODE = '22023';
  END IF;
  IF p_prioridade IS NOT NULL AND p_prioridade NOT IN ('baixa','media','alta') THEN
    RAISE EXCEPTION 'Prioridade inválida: %.', p_prioridade USING ERRCODE = '22023';
  END IF;

  UPDATE nl_edital
     SET kanban_stage          = COALESCE(p_stage,          kanban_stage, 'qualificado'),
         gestao_responsavel    = COALESCE(p_responsavel,    gestao_responsavel),
         gestao_prazo          = COALESCE(p_prazo,          gestao_prazo),
         gestao_prioridade     = COALESCE(p_prioridade,     gestao_prioridade),
         gestao_valor_proposta = COALESCE(p_valor_proposta, gestao_valor_proposta),
         gestao_observacoes    = COALESCE(p_observacoes,    gestao_observacoes),
         gestao_atualizado_em  = NOW(),
         updated_at            = NOW()
   WHERE id = p_edital_id;

  RETURN jsonb_build_object('edital_id', p_edital_id, 'kanban_stage',
                            COALESCE(p_stage, v_e.kanban_stage, 'qualificado'));
END;
$$;

-- =========================================================
-- ESTATÍSTICAS DO BOARD — contagem por etapa do funil.
-- =========================================================
CREATE OR REPLACE FUNCTION nl_board_stats()
RETURNS JSONB
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'total',               (SELECT COUNT(*) FROM nl_edital WHERE status='aceito'),
    'qualificado',         (SELECT COUNT(*) FROM nl_edital WHERE status='aceito' AND COALESCE(kanban_stage,'qualificado')='qualificado'),
    'documentacao',        (SELECT COUNT(*) FROM nl_edital WHERE status='aceito' AND kanban_stage='documentacao'),
    'proposta_elaboracao', (SELECT COUNT(*) FROM nl_edital WHERE status='aceito' AND kanban_stage='proposta_elaboracao'),
    'proposta_enviada',    (SELECT COUNT(*) FROM nl_edital WHERE status='aceito' AND kanban_stage='proposta_enviada'),
    'em_disputa',          (SELECT COUNT(*) FROM nl_edital WHERE status='aceito' AND kanban_stage='em_disputa'),
    'ganhou',              (SELECT COUNT(*) FROM nl_edital WHERE status='aceito' AND kanban_stage='ganhou'),
    'perdeu',              (SELECT COUNT(*) FROM nl_edital WHERE status='aceito' AND kanban_stage='perdeu')
  );
END;
$$;

-- ---------- grants ----------
GRANT EXECUTE ON FUNCTION nl_board_editais(TEXT,TEXT,TEXT)                       TO authenticated;
GRANT EXECUTE ON FUNCTION nl_update_gestao(UUID,TEXT,TEXT,DATE,TEXT,NUMERIC,TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_board_stats()                                       TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS nl_board_stats();
-- DROP FUNCTION IF EXISTS nl_update_gestao(UUID,TEXT,TEXT,DATE,TEXT,NUMERIC,TEXT);
-- DROP FUNCTION IF EXISTS nl_board_editais(TEXT,TEXT,TEXT);
-- ALTER TABLE nl_edital
--   DROP COLUMN IF EXISTS kanban_stage,
--   DROP COLUMN IF EXISTS gestao_responsavel,
--   DROP COLUMN IF EXISTS gestao_prazo,
--   DROP COLUMN IF EXISTS gestao_prioridade,
--   DROP COLUMN IF EXISTS gestao_valor_proposta,
--   DROP COLUMN IF EXISTS gestao_observacoes,
--   DROP COLUMN IF EXISTS gestao_atualizado_em;
