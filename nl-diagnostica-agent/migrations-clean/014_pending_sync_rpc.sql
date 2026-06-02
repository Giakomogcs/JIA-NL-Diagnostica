-- =============================================
-- NL Diagnostica — 011: re-sincronização com a Effecti
--
-- Adiciona o RPC nl_pending_sync(), que lista os editais já decididos
-- (aceito/recusado) mas ainda NÃO sincronizados com a Effecti
-- (sincronizado_effecti = FALSE). O front usa esse retorno para reenviar
-- cada decisão ao webhook nldiag-effecti-sync (botão "Re-sincronizar").
--
-- O marca-como-sincronizado continua sendo feito pelo n8n via
-- nl_mark_synced(), só após a chamada à Effecti retornar com sucesso.
--
-- Rode APÓS 006_licitacao_rpc.sql.
-- =============================================

-- =======  UP  ========

CREATE OR REPLACE FUNCTION nl_pending_sync(p_uf TEXT DEFAULT NULL)
RETURNS TABLE(
  id_licitacao   BIGINT,
  acao           TEXT,
  motivo         TEXT,
  motivo_effecti TEXT,
  numero_edital  TEXT,
  orgao          TEXT,
  uf             TEXT
)
SECURITY DEFINER SET search_path = public LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT (nl_is_member() OR nl_is_backend()) THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT e.id_licitacao,
           CASE WHEN e.decisao_final = 'aceito' THEN 'aceitar' ELSE 'recusar' END,
           e.decisao_motivo,
           COALESCE(e.decisao_motivo_effecti, 'OUTROS'),
           e.numero_edital,
           e.orgao,
           e.uf
      FROM nl_edital e
     WHERE e.decisao_final IS NOT NULL
       AND NOT e.sincronizado_effecti
       AND e.id_licitacao IS NOT NULL
       AND (p_uf IS NULL OR e.uf = p_uf)
     ORDER BY e.decidido_em NULLS LAST, e.created_at;
END;
$$;

GRANT EXECUTE ON FUNCTION nl_pending_sync(TEXT) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS nl_pending_sync(TEXT);
