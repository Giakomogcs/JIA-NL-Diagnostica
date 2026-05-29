# NL Diagnostica — Agente de Editais de Licitação Integrada

Copiloto interno que **recebe editais de licitação** (via API da Effecti, e preparado para Licita Já / ComprasNet), **cruza cada item com o catálogo** de produtos/serviços da NL Diagnostica (linha principal **Hemostasia**), sugere **aceitar/recusar** e **como participar** (por produto, por lote ou pelo edital inteiro), e **aprende** com as decisões para não repetir erros.

Stack: **n8n** (orquestração + IA) + **Supabase** (Postgres 15 + pgvector + Auth) + **Effecti API** + **Azure OpenAI**.

---

## O que o sistema faz

- **Ingestão automática** (cron diário) e manual: busca editais na Effecti por período, processa em **lotes** (para não sobrecarregar), faz **dedupe** e grava progressivamente.
- **Match com catálogo**: cada item do edital é comparado às palavras‑chave/sinônimos do catálogo. Calcula `score`, define o **modo de participação** (`produto` / `lote` / `total` / `nenhum`) e uma **sugestão** (aceitar / recusar / revisar).
- **Painel (dashboard)**: filtros por status/UF/busca, paginação por lotes, e para cada edital mostra **número, órgão, estado, data da licitação, link do edital e link do portal**.
- **Aceitar / Recusar**: registra a decisão no banco e **sincroniza com a Effecti** (favoritar = aceitar; descartar com motivo = recusar).
- **Aprendizado**: toda decisão vira sinal (`nl_decision_log`); o agente consulta os agregados (`nl_learning_signals`) antes de recomendar.
- **Assistente de IA** (chat): analisa a fila, explica match item a item e pode registrar decisões quando solicitado.
- **RAG global**: base de conhecimento (manuais, especificações, finalidade de uso) consultável por **todos** os usuários autenticados — sem ACL por equipe/categoria.
- **2 perfis**: `admin` (gerencia catálogo, documentos e usuários) e `visualizacao`.

---

## Estrutura

```
nl-diagnostica-agent/
  front-nldiagnostica.html         # SPA (login + dashboard + chat + admin)
  .scripts/
    build-front-workflow.ps1       # injeta o HTML no workflow NLDiag-Front.json
  migrations-clean/                # SQL Supabase (rode na ordem 001 → 007)
  workspaces/                      # workflows n8n (importar)
```

---

## Setup

### 1. Banco (Supabase)
Rode os SQLs do diretório `migrations-clean/` **na ordem**, no SQL Editor do Supabase:

| Ordem | Arquivo | Conteúdo |
|---|---|---|
| 1 | `001_users_and_admin.sql` | Helpers de papel (`nl_is_admin`, `nl_is_member`) + RPCs de usuários |
| 2 | `002_rag_schema.sql` | Tabelas e RPCs do RAG (global, sem ACL) |
| 3 | `003_match_documents.sql` | `nl_match_documents` (busca vetorial) |
| 4 | `004_chat_messages.sql` | Memória de chat + trigger de `user_id` |
| 5 | `005_licitacao_schema.sql` | Portais, catálogo, lotes, **editais** e itens, log de decisões |
| 6 | `006_licitacao_rpc.sql` | RPCs: ingestão, match, dashboard, decisão, aprendizado, stats |
| 7 | `007_seeds.sql` | Portais, exemplos de catálogo Hemostasia e **admin inicial** |

> Habilite a extensão `vector` no Supabase antes (Database → Extensions → `vector`).

**Admin inicial** (criado em `007`): `admin@nldiagnostica.com.br` / `@Admin123` — **troque a senha após o primeiro login**.

### 2. n8n — credenciais
Crie no n8n e substitua os placeholders `REPLACE_ME_*` nos workflows:

| Credencial | Tipo | Onde |
|---|---|---|
| **NLDiag-DB** | Postgres | host/porta/usuário do Supabase (use o role de serviço/`postgres`) |
| **Effecti-API** | Header Auth | header `Authorization` = **token da Effecti** (NUNCA versionado) |
| **Azure OpenAI** | Azure OpenAI | chat (`gpt-4o-mini`) + embeddings (`text-embedding-3-small`) |
| **Supabase account** | Supabase API | URL + service key (vector store) |

> ⚠️ **Segurança**: o token da Effecti e a senha do portal vão **somente** na credencial `Effecti-API` do n8n. Não existem segredos hardcoded nos arquivos deste repositório.

### 3. n8n — importar workflows
Importe os JSON de `workspaces/` (veja `workspaces/README.md`). Ative os que precisam ficar online.

### 4. Front
Edite os placeholders no topo de `front-nldiagnostica.html`:
```js
const CONFIG = {
  SUPABASE_URL:      "https://SEU-PROJ.supabase.co",
  SUPABASE_ANON_KEY: "sua-anon-key",
  N8N_BASE:          "https://seu-n8n/webhook"
};
```
Rode o build para publicar o front via n8n (servido em `GET /webhook/nldiag-app`):
```powershell
powershell -ExecutionPolicy Bypass -File .\.scripts\build-front-workflow.ps1
```
Depois importe/atualize `workspaces/NLDiag-Front.json` no n8n. (Também pode abrir o HTML direto no navegador para testes.)

---

## Fluxo Effecti (resumo)

```
Cron/Manual ─▶ NLDiag-Effecti-Ingest
   └ cria lote ▶ POST /aviso/licitacao (período) ▶ upsert+dedupe ▶ match c/ catálogo

Usuário aceita/recusa no painel
   └ Supabase nl_record_decision ▶ POST /webhook/nldiag-effecti-sync
        └ favoritar-licitacao (aceitar) | descartar-licitacao-motivo (recusar) ▶ nl_mark_synced
```

Effecti base: `https://mdw.minha.effecti.com.br/api-integracao/v1` (Swagger: `/api-integracao/swagger`).

---

## Segurança
- RLS + RPCs `SECURITY DEFINER`; o front chama RPCs com o **JWT do usuário**.
- O n8n chama as RPCs como role de banco; o helper `nl_is_backend()` libera as chamadas de backend sem burlar as regras de papel do front.
- Catálogo, documentos e usuários: somente `admin`.
- Nenhum segredo no repositório — apenas placeholders `REPLACE_ME_*`.
