-- =============================================
-- NL Diagnostica — 008: RAG por sessão de chat (anexos de conversa)
--
-- Permite anexar arquivos DENTRO de uma conversa do chat: os chunks são
-- gravados em nl_documents com `session_id` na metadata e ficam restritos
-- àquela conversa.
--
-- nl_match_documents passa a:
--   * EXCLUIR chunks com session_id quando o filtro NÃO pede uma sessão
--     (busca global/`search_knowledge_base` não vaza anexos de outras conversas);
--   * quando o filtro traz `session_id`, retorna SÓ os chunks daquela sessão
--     (ferramenta `search_session_files` do agente).
--
-- Rode APÓS 003_match_documents.sql (pode rodar a qualquer momento depois).
-- =============================================

-- =======  UP  ========

DROP FUNCTION IF EXISTS nl_match_documents(vector, int, jsonb);
CREATE OR REPLACE FUNCTION nl_match_documents(
  query_embedding vector(1536),
  match_count     int   DEFAULT 6,
  filter          jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(
  id         bigint,
  content    text,
  metadata   jsonb,
  similarity float
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  is_member_caller BOOLEAN := nl_is_member();
  is_service_role  BOOLEAN := (
    COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role'
    OR COALESCE(auth.role(), '') = 'service_role'
  );
  wants_session BOOLEAN := (filter ? 'session_id')
    AND COALESCE(filter->>'session_id', '') <> '';
BEGIN
  -- Permite membros autenticados e o service_role do n8n.
  IF NOT is_member_caller AND NOT is_service_role THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT
      d.id,
      d.content,
      (
        jsonb_strip_nulls(jsonb_build_object(
          'url',       m.url,
          'title',     m.title,
          'code',      m.code,
          'source',    m.source,
          'mime_type', m.mime_type
        )) || COALESCE(d.metadata, '{}'::jsonb)
      ) AS metadata,
      1 - (d.embedding <=> query_embedding) AS similarity
    FROM nl_documents d
    LEFT JOIN nl_document_metadata m
           ON m.file_id = d.metadata->>'file_id'
    WHERE d.metadata @> COALESCE(filter, '{}'::jsonb)
      AND (
        -- O chamador pediu explicitamente uma sessão → o @> acima já restringe.
        wants_session
        -- Busca global: ignora anexos de conversa (qualquer session_id preenchido).
        OR d.metadata->>'session_id' IS NULL
        OR d.metadata->>'session_id' = ''
      )
    ORDER BY d.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

GRANT EXECUTE ON FUNCTION nl_match_documents(vector, int, jsonb)
  TO authenticated, service_role;

-- Limpeza opcional: remover anexos de conversas (chunks + linhas + metadata)
-- de uma sessão específica. Útil ao apagar uma conversa.
CREATE OR REPLACE FUNCTION nl_rag_purge_session(p_session_id TEXT)
RETURNS TABLE(deleted_chunks bigint)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  c1 bigint := 0;
BEGIN
  IF p_session_id IS NULL OR p_session_id = '' THEN
    deleted_chunks := 0;
    RETURN NEXT;
    RETURN;
  END IF;

  -- Remove os chunks da sessão.
  DELETE FROM nl_documents
   WHERE metadata->>'session_id' = p_session_id;
  GET DIAGNOSTICS c1 = ROW_COUNT;

  -- Remove a metadata órfã de anexos de chat (sem mais nenhum chunk).
  DELETE FROM nl_document_metadata mm
   WHERE mm.source = 'chat'
     AND NOT EXISTS (
       SELECT 1 FROM nl_documents d
        WHERE d.metadata->>'file_id' = mm.file_id
     );

  deleted_chunks := c1;
  RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION nl_rag_purge_session(TEXT) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS nl_rag_purge_session(TEXT);
-- -- Reaplique 003_match_documents.sql para restaurar a versão sem sessão.
-- NOTIFY pgrst, 'reload schema';
