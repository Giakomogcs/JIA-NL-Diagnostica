# Workflows n8n — NL Diagnostica

Importe os JSON abaixo no n8n e configure as credenciais (substitua os `REPLACE_ME_*`).

| Arquivo                           | Tipo      | Endpoint(s)                                                                         | Função                                                                                                                                                                                                                                                                                                                                                                                                                   |
| --------------------------------- | --------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `NLDiag-Front.json`               | HTTP      | `GET /nldiag-app`                                                                   | Serve a SPA (gerado por `.scripts/build-front-workflow.ps1`)                                                                                                                                                                                                                                                                                                                                                             |
| `NLDiag-Agent.json`               | IA        | `POST /nldiag-AgentRag`                                                             | Assistente (Azure GPT‑4o‑mini) com memória, RAG global, **RAG da conversa** (`search_session_files`) e 6 ferramentas                                                                                                                                                                                                                                                                                                     |
| `NLDiag-Bridge.json`              | Tools     | `POST /nldiag-tool-*`                                                               | Ferramentas do agente: stats, dashboard, edital, learning, catalogo, decision                                                                                                                                                                                                                                                                                                                                            |
| `NLDiag-Effecti-Ingest.json`      | Cron/HTTP | `POST /nldiag-effecti-pull`                                                         | Busca editais na Effecti, dedupe e match (lotes)                                                                                                                                                                                                                                                                                                                                                                         |
| `NLDiag-Effecti-Sync.json`        | HTTP      | `POST /nldiag-effecti-sync`                                                         | Favoritar (aceitar) / descartar c/ motivo (recusar) na Effecti                                                                                                                                                                                                                                                                                                                                                           |
| `NLDiag-RAG.json`                 | IA        | `POST /nldiag-rag-upload`, `POST /nldiag-rag-reindex`, `POST /nldiag-rag-upsert`    | Ingestão da **pasta do Google Drive** (`1keYkwI18niYMSlrEjMKcvVYtYRCqMgKS`). **Upload unitário** (`/nldiag-rag-upload`, multipart `data`): substitui se mesmo nome, indexa só esse arquivo; com `session_id` → anexa só àquela conversa. **Reprocessar** (`/nldiag-rag-reindex`): `{file_id}`/`{file_ids:[…]}` reprocessa só esse(s), sem corpo reprocessa a pasta inteira. **Upsert por texto** (`/nldiag-rag-upsert`). |
| `NLDiag-RAG-Admin.json`           | HTTP      | `GET /nldiag-rag-docs`, `POST /nldiag-rag-doc-delete`, `POST /nldiag-rag-purge-all` | Admin do RAG (anexos de chat ficam ocultos da lista)                                                                                                                                                                                                                                                                                                                                                                     |
| `NLDiag-Chat-GET-Sessions.json`   | HTTP      | `GET /nldiag-sessions`                                                              | Lista conversas do usuário                                                                                                                                                                                                                                                                                                                                                                                               |
| `NLDiag-Chat-GET-History.json`    | HTTP      | `GET /nldiag-history`                                                               | Histórico de uma conversa                                                                                                                                                                                                                                                                                                                                                                                                |
| `NLDiag-Chat-DELETE-Session.json` | HTTP      | `DELETE /nldiag-session`                                                            | Apaga uma conversa                                                                                                                                                                                                                                                                                                                                                                                                       |
| `NLDiag-Aprendizado.json`         | HTTP      | `POST /nldiag-aprendizado`                                                          | **Aprendizado por feedback da triagem**: recebe `{edital_id, linha, acao, palavras_boas, palavras_ruins, regra}`, gera embeddings (Azure, URL `REPLACE_ME_AZURE_EMBEDDINGS_URL`) e chama `nl_aprendizado_aplicar()` (dedup exato + semântico, caps). Responde resumo `{gravados, descartados_exato, descartados_semantico}`. O **reprocesso** é disparado pelo front. Requer migration `023`.                                |

## Credenciais

- **NLDiag-DB** (Postgres) → `REPLACE_ME_NLDIAG_DB`
- **Effecti-API** (Header Auth, `Authorization` = token Effecti) → `REPLACE_ME_EFFECTI_CRED`
- **Azure OpenAI** → `REPLACE_ME_AZURE_OPENAI_CRED`
- **Supabase account** (Supabase API) → `REPLACE_ME_SUPABASE_CRED`
- **Google Drive account** (Google Drive OAuth2) → `REPLACE_ME_GDRIVE_CRED` — necessário para o RAG ler a pasta
- (OCR PDF digitalizado) `REPLACE_ME_AZURE_OCR_URL` + `REPLACE_ME_OCR_DEPLOYMENT` no nó _OCR via Azure_ / _Prepare PDF Base64_
- (Aprendizado) `REPLACE_ME_AZURE_EMBEDDINGS_URL` no nó _Embeddings (Azure)_ do `NLDiag-Aprendizado.json` — endpoint de embeddings (mesmo deployment usado no RAG). Sem ele, o aprendizado degrada para dedup **só exato**.

> O token da Effecti vai **apenas** na credencial `Effecti-API`. Nunca commitar.

## Ordem de ativação sugerida

1. `NLDiag-Bridge` (ferramentas) e `NLDiag-Agent` (chat).
2. `NLDiag-Chat-*` (sessões/histórico).
3. `NLDiag-Effecti-Sync` (necessário para aceitar/recusar refletirem na Effecti).
4. `NLDiag-Effecti-Ingest` (cron diário — ative quando o catálogo já tiver dados).
5. `NLDiag-RAG` / `NLDiag-RAG-Admin` — configure a credencial **Google Drive** e dispare `POST /nldiag-rag-reindex` (ou o gatilho manual) para indexar a pasta `1keYkwI18niYMSlrEjMKcvVYtYRCqMgKS`. Para **anexos no chat** (`search_session_files`), rode a migration `008_session_rag.sql`.
6. `NLDiag-Front` (servir a SPA — regere com `.scripts/build-front-workflow.ps1` após editar `front-nldiagnostica.html`).

## Effecti API (referência)

- Base: `https://mdw.minha.effecti.com.br/api-integracao/v1` · Swagger: `/api-integracao/swagger`
- `POST /aviso/licitacao?page=0` body `{begin,end}` → lista de licitações
- `PUT /aviso/favoritar-licitacao` `{idLicitacao:[int]}` → **aceitar**
- `PUT /aviso/descartar-licitacao-motivo` `{licitacoesDescarte:[{idLicitacao,motivos:[{motivo,descricao}]}]}` → **recusar**

Motivos válidos: `FALTA_CAPACIDADE_TECNICA`, `LOCALIDADE_ENTREGA`, `VALOR_ESTIMADO_BAIXO`, `DOCUMENTACAO_INSUFICIENTE`, `PRAZO_ENTREGA_CURTO`, `OUTROS`.
