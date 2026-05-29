# Migrations — NL Diagnostica

SQL para o Supabase (Postgres 15 + pgvector). Rode **na ordem** no SQL Editor.
Cada arquivo tem seções `UP` (aplicar) e comentários `DOWN` (reverter).

| Ordem | Arquivo | Objetos principais |
|---|---|---|
| 1 | `001_users_and_admin.sql` | `nl_is_admin()`, `nl_is_member()`, `nl_admin_list_users()`, `nl_admin_confirm_user()`, `nl_admin_update_user()`, `nl_admin_delete_user()` |
| 2 | `002_rag_schema.sql` | `nl_document_metadata`, `nl_document_rows`, `nl_documents` (vector 1536, HNSW); `nl_rag_upsert_metadata()`, `nl_rag_purge_file()`, `nl_admin_list_rag_documents()`, `nl_list_rag_documents()` |
| 3 | `003_match_documents.sql` | `nl_match_documents(vector, int, jsonb)` — busca vetorial **sem ACL** (RAG global) |
| 4 | `004_chat_messages.sql` | `nl_chat_message` + trigger que extrai `user_id` do bloco `[CONTEXTO ... ID="<uuid>"]` |
| 5 | `005_licitacao_schema.sql` | `nl_portal`, `nl_catalogo`, `nl_batch`, `nl_edital`, `nl_edital_item`, `nl_decision_log` + RLS + `nl_parse_ts()` |
| 6 | `006_licitacao_rpc.sql` | `nl_is_backend()`, CRUD catálogo, `nl_upsert_edital()`, `nl_match_edital()`, `nl_dashboard_editais()`, `nl_get_edital()`, `nl_record_decision()`, `nl_set_item_participation()`, `nl_mark_synced()`, `nl_learning_signals()`, `nl_batch_*()`, `nl_stats()` |
| 7 | `007_seeds.sql` | Portais (EFFECTI/LICITAJA/COMPRASNET), catálogo Hemostasia (exemplos) e **admin inicial** |

## Pré‑requisitos
- Extensão `vector` habilitada (Database → Extensions).
- Supabase Auth ativo. O papel do usuário fica em `raw_user_meta_data` (`role` ∈ `admin` | `visualizacao`, `company_name = 'nldiagnostica'`).

## Decisões de modelagem
- **Sem ACL por equipe/categoria.** O RAG é global: qualquer usuário autenticado consulta tudo via agente de IA.
- **Dedupe de editais**: `nl_edital.id_licitacao` (id da Effecti) é único; fallback por `dedupe_hash` (`md5(processo|orgao|objeto)`).
- **Match**: posição (`position`/`ILIKE`) das palavras‑chave do catálogo no produto licitado. `score = LEAST(1.0, 0.4 + 0.2 × hits)`.
- **Modo de participação**: `total` (todos os itens casam), `lote` (algum lote 100% fornecível), `produto` (parcial), `nenhum`.
- **Backend vs front**: `nl_is_backend()` libera chamadas do n8n (role de banco/`service_role`); o front usa o JWT do usuário e passa pelas regras de papel.

## Admin inicial
`007` cria `admin@nldiagnostica.com.br` / `@Admin123`. **Troque a senha** após o primeiro login.
