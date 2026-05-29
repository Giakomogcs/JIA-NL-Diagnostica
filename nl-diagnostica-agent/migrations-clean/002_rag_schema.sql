-- =============================================
-- NL Diagnostica — 002: RAG schema (sem ACL por categoria/equipe)
-- O RAG é GLOBAL: todo usuário autenticado da empresa acessa todos os
-- documentos através do agente de IA. Não há gating por equipe/categoria.
--
-- - Extensões pgvector / pgcrypto
-- - Tabelas: nl_document_metadata, nl_document_rows, nl_documents
-- - Índice HNSW (fallback ivfflat) em embedding
-- - RPCs: rag_upsert_metadata, rag_purge_file, admin_rag_delete_file,
--          admin_list_rag_documents, list_rag_documents
-- Rode APÓS 001_users_and_admin.sql
-- =============================================

-- =======  UP  ========

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- metadata por arquivo ----------
CREATE TABLE IF NOT EXISTS nl_document_metadata (
  file_id      TEXT PRIMARY KEY,
  title        TEXT,
  code         TEXT,
  url          TEXT,
  source       TEXT,
  mime_type    TEXT,
  schema       JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_nl_meta_code ON nl_document_metadata(code);

CREATE OR REPLACE FUNCTION nl_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_nl_meta_updated_at ON nl_document_metadata;
CREATE TRIGGER trg_nl_meta_updated_at
  BEFORE UPDATE ON nl_document_metadata
  FOR EACH ROW EXECUTE FUNCTION nl_set_updated_at();

-- ---------- linhas tabulares (csv/xlsx) ----------
CREATE TABLE IF NOT EXISTS nl_document_rows (
  id          BIGSERIAL PRIMARY KEY,
  dataset_id  TEXT NOT NULL REFERENCES nl_document_metadata(file_id) ON DELETE CASCADE,
  row_data    JSONB NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_nl_rows_dataset ON nl_document_rows(dataset_id);

-- ---------- chunks vetoriais (LangChain Supabase vector store) ----------
CREATE TABLE IF NOT EXISTS nl_documents (
  id        BIGSERIAL PRIMARY KEY,
  content   TEXT,
  metadata  JSONB,
  embedding vector(1536)
);
CREATE INDEX IF NOT EXISTS idx_nl_docs_file_id
  ON nl_documents ( (metadata->>'file_id') );

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'nl_documents_embedding_hnsw'
  ) THEN
    EXECUTE 'CREATE INDEX nl_documents_embedding_hnsw
             ON nl_documents USING hnsw (embedding vector_cosine_ops)';
  END IF;
EXCEPTION WHEN OTHERS THEN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'nl_documents_embedding_ivfflat'
  ) THEN
    EXECUTE 'CREATE INDEX nl_documents_embedding_ivfflat
             ON nl_documents USING ivfflat (embedding vector_cosine_ops)
             WITH (lists = 100)';
  END IF;
END $$;

-- ---------- upsert atômico de metadata ----------
CREATE OR REPLACE FUNCTION nl_rag_upsert_metadata(
  p_file_id   TEXT,
  p_title     TEXT,
  p_code      TEXT  DEFAULT NULL,
  p_url       TEXT  DEFAULT NULL,
  p_source    TEXT  DEFAULT 'webhook',
  p_mime_type TEXT  DEFAULT NULL,
  p_schema    JSONB DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO nl_document_metadata(
    file_id, title, code, url, source, mime_type, schema, updated_at
  )
  VALUES (p_file_id, p_title, p_code, p_url, p_source, p_mime_type, p_schema, NOW())
  ON CONFLICT (file_id) DO UPDATE
    SET title      = COALESCE(EXCLUDED.title,     nl_document_metadata.title),
        code       = COALESCE(EXCLUDED.code,      nl_document_metadata.code),
        url        = COALESCE(EXCLUDED.url,       nl_document_metadata.url),
        source     = COALESCE(EXCLUDED.source,    nl_document_metadata.source),
        mime_type  = COALESCE(EXCLUDED.mime_type, nl_document_metadata.mime_type),
        schema     = COALESCE(EXCLUDED.schema,    nl_document_metadata.schema),
        updated_at = NOW();
END;
$$;

CREATE OR REPLACE FUNCTION nl_rag_purge_file(p_file_id TEXT)
RETURNS TABLE(deleted_chunks bigint, deleted_rows bigint)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  c1 bigint := 0;
  c2 bigint := 0;
BEGIN
  DELETE FROM nl_documents       WHERE metadata->>'file_id' = p_file_id;
  GET DIAGNOSTICS c1 = ROW_COUNT;
  DELETE FROM nl_document_rows   WHERE dataset_id = p_file_id;
  GET DIAGNOSTICS c2 = ROW_COUNT;
  deleted_chunks := c1;
  deleted_rows   := c2;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION nl_admin_rag_delete_file(p_file_id TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT nl_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  PERFORM nl_rag_purge_file(p_file_id);
  DELETE FROM nl_document_metadata WHERE file_id = p_file_id;
END;
$$;

CREATE OR REPLACE FUNCTION nl_admin_list_rag_documents()
RETURNS TABLE(
  file_id     TEXT,
  title       TEXT,
  code        TEXT,
  url         TEXT,
  source      TEXT,
  mime_type   TEXT,
  chunk_count BIGINT,
  created_at  TIMESTAMPTZ,
  updated_at  TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT nl_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      m.file_id, m.title, m.code, m.url, m.source, m.mime_type,
      COALESCE((SELECT COUNT(*) FROM nl_documents d WHERE d.metadata->>'file_id' = m.file_id), 0),
      m.created_at, m.updated_at
    FROM nl_document_metadata m
    ORDER BY COALESCE(m.code, m.title, m.file_id);
END;
$$;

-- Lista para membros (sem ACL — todo membro vê todos os documentos)
CREATE OR REPLACE FUNCTION nl_list_rag_documents()
RETURNS TABLE(
  file_id TEXT,
  title   TEXT,
  code    TEXT,
  url     TEXT
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT nl_is_member() THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT m.file_id, m.title, m.code, m.url
      FROM nl_document_metadata m
     ORDER BY COALESCE(m.code, m.title);
END;
$$;

GRANT SELECT  ON nl_document_metadata TO authenticated;
GRANT SELECT  ON nl_document_rows     TO authenticated;
GRANT SELECT  ON nl_documents         TO authenticated;
GRANT EXECUTE ON FUNCTION nl_rag_upsert_metadata(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_rag_purge_file(TEXT)            TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION nl_admin_rag_delete_file(TEXT)     TO authenticated;
GRANT EXECUTE ON FUNCTION nl_admin_list_rag_documents()      TO authenticated;
GRANT EXECUTE ON FUNCTION nl_list_rag_documents()            TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS nl_list_rag_documents();
-- DROP FUNCTION IF EXISTS nl_admin_list_rag_documents();
-- DROP FUNCTION IF EXISTS nl_admin_rag_delete_file(TEXT);
-- DROP FUNCTION IF EXISTS nl_rag_purge_file(TEXT);
-- DROP FUNCTION IF EXISTS nl_rag_upsert_metadata(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB);
-- DROP INDEX    IF EXISTS nl_documents_embedding_hnsw;
-- DROP INDEX    IF EXISTS nl_documents_embedding_ivfflat;
-- DROP TABLE    IF EXISTS nl_documents;
-- DROP TABLE    IF EXISTS nl_document_rows;
-- DROP TRIGGER  IF EXISTS trg_nl_meta_updated_at ON nl_document_metadata;
-- DROP FUNCTION IF EXISTS nl_set_updated_at();
-- DROP TABLE    IF EXISTS nl_document_metadata;
-- NOTIFY pgrst, 'reload schema';
