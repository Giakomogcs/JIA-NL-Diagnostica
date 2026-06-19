# Arquitetura — NL Diagnóstica Agent

> Arquitetura interna do serviço e como ele se encaixa nos sistemas externos.
> Setup e uso: [`README.md`](./README.md)

## Padrão Arquitetural

O NL Diagnóstica Agent **não é uma aplicação monolítica tradicional**: é um sistema
**orquestrado por workflows n8n** sobre um **banco Supabase (Postgres 15 + pgvector)**,
com uma **SPA single-file** (`front-nldiagnostica.html`) como camada de apresentação.

A regra de design central é **toda a lógica de negócio vive no banco**, exposta como
funções `RPC` (`SECURITY DEFINER`) em Postgres. O n8n e o front são clientes "burros"
dessas RPCs:

- **Front (SPA)** chama as RPCs com o **JWT do usuário** (passa pelas regras de papel/RLS).
- **n8n** chama as mesmas RPCs como role de banco/`service_role`; o helper `nl_is_backend()`
  libera as chamadas de backend sem burlar as regras de papel aplicadas ao front.

Esse padrão (lógica concentrada em RPCs versionadas por migrations) mantém o
comportamento consistente independentemente de quem chama, evita duplicar regras entre
n8n e front, e torna o reprocessamento (match, aprendizado) determinístico.

| Dimensão          | Escolha                                                      |
| ----------------- | ------------------------------------------------------------ |
| Orquestração / IA | n8n (workflows HTTP + cron + AI Agent)                       |
| Persistência      | Supabase — Postgres 15 + pgvector (HNSW)                     |
| Autenticação      | Supabase Auth (JWT) + RLS + papéis em `raw_user_meta_data`   |
| Apresentação      | SPA single-file servida por webhook n8n (`GET /nldiag-app`)  |
| IA / Embeddings   | Azure OpenAI (`gpt-*` chat + `text-embedding-3-small` 1536d) |
| Integrações       | Effecti API, Licita Já API, Google Drive (RAG)               |

## Diagrama de Contexto (C4 — Nível 1)

```mermaid
C4Context
  title NL Diagnóstica Agent — Contexto

  Person(equipe, "Equipe NL Diagnóstica", "Admin e Visualização: triagem de editais")

  System(nldiag, "NL Diagnóstica Agent", "Recebe editais, cruza com catálogo, sugere participação e aprende com decisões")

  System_Ext(effecti, "Effecti API", "Fonte de editais + favoritar/descartar")
  System_Ext(licitaja, "Licita Já API", "Fonte alternativa de editais")
  System_Ext(azure, "Azure OpenAI", "Chat, triagem e embeddings")
  System_Ext(gdrive, "Google Drive", "Pasta com bulas/manuais (RAG)")

  Rel(equipe, nldiag, "Usa", "HTTPS / SPA")
  Rel(nldiag, effecti, "Puxa editais e sincroniza decisão", "REST")
  Rel(nldiag, licitaja, "Puxa editais", "REST (X-API-KEY)")
  Rel(nldiag, azure, "Gera análise e embeddings", "REST")
  Rel(nldiag, gdrive, "Indexa documentos", "OAuth2")
```

## Diagrama de Containers (C4 — Nível 2)

```mermaid
C4Container
  title Containers — NL Diagnóstica Agent

  Person(equipe, "Equipe NL Diagnóstica")

  Container_Boundary(sistema, "NL Diagnóstica Agent") {
    Container(spa, "SPA", "HTML/JS single-file", "Dashboard, chat, kanban e admin")
    Container(n8n, "n8n Workflows", "n8n", "Ingestão, match, sync, RAG, chat, aprendizado")
    ContainerDb(db, "Supabase", "Postgres 15 + pgvector", "Editais, catálogo, RAG, regras, auth")
  }

  System_Ext(effecti, "Effecti API")
  System_Ext(licitaja, "Licita Já API")
  System_Ext(azure, "Azure OpenAI")
  System_Ext(gdrive, "Google Drive")

  Rel(equipe, spa, "Acessa", "HTTPS")
  Rel(spa, n8n, "Webhooks", "POST/GET /webhook/*")
  Rel(spa, db, "RPCs com JWT do usuário", "PostgREST")
  Rel(n8n, db, "RPCs como backend", "Postgres / PostgREST")
  Rel(n8n, effecti, "Pull + sync", "REST")
  Rel(n8n, licitaja, "Pull", "REST")
  Rel(n8n, azure, "LLM + embeddings", "REST")
  Rel(n8n, gdrive, "Lê pasta", "OAuth2")
```

## Componentes Internos (workflows n8n)

```mermaid
graph TD
  subgraph Apresentacao["Apresentação"]
    FRONT["NLDiag-Front<br/>GET /nldiag-app"]
  end

  subgraph Ingestao["Ingestão & Sync"]
    INGEST["NLDiag-Effecti-Ingest<br/>cron + /nldiag-effecti-pull"]
    LICITA["NLDiag-LicitaJa-Ingest<br/>cron + /nldiag-licitaja-pull"]
    SYNC["NLDiag-Effecti-Sync<br/>/nldiag-effecti-sync"]
  end

  subgraph Inteligencia["Inteligência & Aprendizado"]
    INTEL["NLDiag-Inteligencia<br/>motor de bulas + super-triagem"]
    APREND["NLDiag-Aprendizado<br/>/nldiag-aprendizado"]
  end

  subgraph Assistente["Assistente"]
    AGENT["NLDiag-Agent<br/>/nldiag-AgentRag"]
    BRIDGE["NLDiag-Bridge<br/>/nldiag-tool-*"]
    CHAT["NLDiag-Chat-*<br/>sessions/history/delete"]
  end

  subgraph RAG["Base de conhecimento"]
    RAGW["NLDiag-RAG<br/>upload/reindex/upsert"]
    RAGADM["NLDiag-RAG-Admin<br/>docs/delete/purge"]
  end

  DB[("Supabase<br/>Postgres + pgvector")]
  GDRIVE["Google Drive"]
  AZURE["Azure OpenAI"]
  EFFECTI["Effecti API"]
  LICITAJA["Licita Já API"]

  FRONT --> DB
  FRONT --> AGENT
  FRONT --> INGEST
  FRONT --> SYNC
  FRONT --> APREND

  INGEST --> EFFECTI
  INGEST --> DB
  LICITA --> LICITAJA
  LICITA --> DB
  SYNC --> EFFECTI
  SYNC --> DB

  INTEL --> AZURE
  INTEL --> DB
  APREND --> AZURE
  APREND --> DB

  AGENT --> BRIDGE
  AGENT --> AZURE
  BRIDGE --> DB
  CHAT --> DB

  RAGW --> GDRIVE
  RAGW --> AZURE
  RAGW --> DB
  RAGADM --> DB
```

## Fluxo de Ingestão e Match

```mermaid
sequenceDiagram
  actor Cron as Cron / Manual
  participant ING as NLDiag-Effecti-Ingest
  participant EFF as Effecti API
  participant DB as Supabase RPCs

  Cron->>ING: dispara (diário ou /nldiag-effecti-pull)
  ING->>DB: nl_batch_start()
  ING->>EFF: POST /aviso/licitacao {begin,end} (paginado)
  EFF-->>ING: lista de licitações (janela 24h)
  loop por lote
    ING->>DB: nl_upsert_edital() (dedupe id_licitacao / dedupe_hash)
    DB->>DB: nl_match_edital() cruza itens x catálogo
    DB-->>ING: status (sugerido_aceitar / recusar / analisando)
  end
  ING->>DB: nl_batch_finish()
```

`nl_match_edital` é o coração da triagem: cada item do edital é comparado às
palavras-chave/sinônimos/**termos fortes** do catálogo (posição via `ILIKE`),
bloqueado por **negativos globais** (`nl_match_negativo`), e recebe `score`,
`modo` de participação e `sugestao`. Editais sem itens cruzam o `objeto` com
termos fracos e caem em `analisando` (em vez de recusa silenciosa).

## Fluxo de Decisão e Sincronização

```mermaid
sequenceDiagram
  actor U as Usuário (SPA)
  participant DB as Supabase
  participant SYNC as NLDiag-Effecti-Sync
  participant EFF as Effecti API

  U->>DB: nl_record_decision(aceitar | recusar, feedback?)
  DB->>DB: grava decisão + nl_decision_log
  U->>SYNC: POST /nldiag-effecti-sync {idLicitacao, acao, motivoEffecti}
  alt aceitar
    SYNC->>EFF: PUT /aviso/favoritar-licitacao
  else recusar
    SYNC->>EFF: PUT /aviso/descartar-licitacao-motivo
  end
  SYNC->>SYNC: Checar Sync (corpo NÃO-vazio = sucesso)
  SYNC->>DB: nl_mark_synced()
  SYNC-->>U: {status:ok} ou 502
```

> **Gotcha:** corpo de resposta vazio = a execução n8n morreu no meio (falha
> silenciosa). O front valida corpo não-vazio antes de considerar sucesso.

## Fluxo de Aprendizado por Feedback (migration 023)

```mermaid
sequenceDiagram
  actor U as Usuário
  participant APR as NLDiag-Aprendizado
  participant AZ as Azure (embeddings)
  participant DB as Supabase
  participant FRONT as SPA

  U->>APR: POST /nldiag-aprendizado {linha, acao, boas, ruins, regra}
  APR->>AZ: gera embeddings (opcional, degrada para só-exato)
  APR->>DB: nl_aprendizado_aplicar(jsonb)
  DB->>DB: dedup EXATO (nl_norm) + dedup SEMÂNTICO (cosine acima do limiar)
  DB->>DB: persiste sobreviventes (termos, negativos, regra)
  DB-->>APR: {gravados, descartados_exato, descartados_semantico}
  APR-->>U: resumo honesto
  U->>FRONT: reprocessarTudo() se gravou algo
  FRONT->>DB: nl_rematch_all() em loop até restantes=0
```

Dedup em 2 camadas evita inchar a base: **exato** (`nl_norm` = lower+unaccent+trim)
e **semântico** (embeddings + similaridade cosseno). Regras aprendidas entram no
prompt da super-triagem como "REGRAS DE NEGÓCIO APRENDIDAS" (a `REGRA DE OURO`
tem precedência).

## Fluxo do Assistente (RAG + ferramentas)

```mermaid
sequenceDiagram
  actor U as Usuário
  participant AG as NLDiag-Agent (AI Agent)
  participant AZ as Azure GPT
  participant BR as NLDiag-Bridge (tools)
  participant DB as Supabase (pgvector)

  U->>AG: POST /nldiag-AgentRag {mensagem, session_id}
  AG->>DB: nl_match_documents (RAG global + anexos da sessão)
  AG->>AZ: prompt + contexto + histórico
  AZ-->>AG: precisa de dados?
  AG->>BR: tool stats/dashboard/edital/learning/catalogo/decision
  BR->>DB: RPC correspondente
  BR-->>AG: resultado
  AG-->>U: resposta + addCopyButtons
```

## Diagrama de Entidades (núcleo)

```mermaid
erDiagram
  nl_portal ||--o{ nl_edital : "origem"
  nl_edital ||--o{ nl_edital_item : "tem itens"
  nl_edital ||--o{ nl_decision_log : "registra decisões"
  nl_catalogo ||--o{ nl_edital_item : "casa via match"
  nl_batch ||--o{ nl_edital : "lote de ingestão"
  nl_triagem_regra }o--|| nl_catalogo : "por linha"

  nl_edital {
    uuid id PK
    text id_licitacao
    text fonte
    text processo
    text orgao
    text estado
    text status
    text modo
    numeric score
    jsonb anexos
    jsonb analise_profunda
    timestamptz data_licitacao
  }
  nl_edital_item {
    uuid id PK
    uuid edital_id FK
    uuid catalogo_id FK
    text produto_licitado
    numeric match_score
    bool participa
  }
  nl_catalogo {
    uuid id PK
    text linha
    text[] termos_fortes
    text[] sinonimos
    text[] palavras_chave
    text contexto_bulas
  }
  nl_decision_log {
    uuid id PK
    uuid edital_id FK
    text acao
    uuid user_id
    timestamptz created_at
  }
  nl_triagem_regra {
    uuid id PK
    text texto
    vector embedding
    text linha
    bool ativo
  }
```

A camada RAG (`nl_document_metadata`, `nl_document_rows`, `nl_documents` com
`vector(1536)` + índice HNSW) é independente do domínio de editais e consultada
globalmente — sem ACL por equipe/categoria.

## Fluxo de Autenticação

```mermaid
sequenceDiagram
  actor U as Usuário
  participant SPA as SPA
  participant AUTH as Supabase Auth
  participant RPC as RPC (SECURITY DEFINER)

  U->>SPA: login (email/senha)
  SPA->>AUTH: signInWithPassword
  AUTH-->>SPA: { access_token (JWT), refresh_token }
  Note over SPA: papel em raw_user_meta_data<br/>(admin | visualizacao)
  SPA->>RPC: chamada RPC + Bearer JWT
  RPC->>RPC: nl_is_admin() / nl_is_member() / RLS
  RPC-->>SPA: dados conforme papel
```

> **Gotcha sandbox/origin null:** servindo o front pelo webhook `nldiag-app`,
> `navigator.locks` lança `SecurityError` e quebra o refresh do token. Fix:
> polyfill sempre sobrescreve `navigator.locks` e passar
> `lock: async (_n,_t,fn)=>fn()` em todos os `createClient`.

## Decisões de Arquitetura

### ADR-001: Lógica de negócio em RPCs do Postgres

- **Status:** Aceito
- **Contexto:** Front e n8n precisam do mesmo comportamento de match/decisão.
- **Decisão:** Concentrar regras em funções `SECURITY DEFINER`, versionadas por migrations.
- **Consequências:** Consistência e reprocessamento determinístico; porém a lógica
  fica em PL/pgSQL (menos testável que código de aplicação) e exige cuidado com RLS.

### ADR-002: Reprocesso em lotes (não em transação única)

- **Status:** Aceito
- **Contexto:** `nl_rematch_all` reprocessava ~350 editais numa transação → statement
  timeout do Supabase.
- **Decisão:** Flag `rematch_pending` + `nl_rematch_all(p_only_pending, p_limit)` que
  retorna `{reprocessados, restantes}`; o front chama em loop até `restantes=0`.
- **Consequências:** Sem timeout; custo de orquestração no cliente.

### ADR-003: Super-triagem assíncrona

- **Status:** Aceito
- **Contexto:** OCR/LLM de PDFs estourava o timeout (~100s) do proxy.
- **Decisão:** Responder `{status:processando}` imediatamente; o front faz polling de
  `analise_profunda_at` (5s, ~4min).
- **Consequências:** UX responsiva; complexidade de polling no front.

### ADR-004: Dedup em 2 camadas no aprendizado

- **Status:** Aceito
- **Contexto:** Feedback livre da equipe poderia inchar a base de termos/regras.
- **Decisão:** Dedup exato (`nl_norm`) + semântico (embeddings/cosine) com caps
  (texto ≤280, ≤20 regras ativas/linha); embeddings opcionais (degrada p/ só-exato).
- **Consequências:** Base enxuta e honesta; dependência opcional do Azure embeddings.

### ADR-005: RAG global sem ACL

- **Status:** Aceito
- **Contexto:** Equipe pequena; conhecimento (bulas/manuais) é compartilhado.
- **Decisão:** `nl_match_documents` sem filtro por equipe/categoria; anexos de chat
  isolados por `session_id` (migration 008).
- **Consequências:** Simplicidade; não atende multi-tenant.

## Segurança

- **Autenticação:** Supabase Auth (JWT). Papel em `raw_user_meta_data`
  (`role ∈ admin | visualizacao`, `company_name = 'nldiagnostica'`).
- **Autorização:** RLS + RPCs `SECURITY DEFINER`; helpers `nl_is_admin()`,
  `nl_is_member()`, `nl_is_backend()`. Catálogo, documentos e usuários: só `admin`.
- **Backend vs front:** o n8n usa role de banco/`service_role` (liberado por
  `nl_is_backend()`); o front usa o JWT do usuário e passa pelas regras de papel.
- **Segredos:** nenhum hardcoded no repositório — apenas placeholders `REPLACE_ME_*`.
  Token Effecti e senha de portal vivem **só** na credencial `Effecti-API` do n8n.
- **Interpolação SQL no n8n (gotcha):** usar `{{ $json.body.X || '' }}` para params
  de texto opcionais — chave ausente vira `undefined` literal e quebra o filtro.

## Performance

- **pgvector HNSW** nos embeddings (RAG e cache de termos) para busca aproximada rápida.
- **Ingestão e rematch em lotes** (`p_limit`) para evitar statement timeout.
- **Cache de embeddings de termos** (`nl_termo_embedding`) evita re-embeddar o catálogo.
- **Motor de bulas em lotes de 2 docs** (cap ~28k/doc) com resposta imediata p/ não
  estourar o timeout do proxy.
- **Super-triagem assíncrona + polling** em vez de request longo síncrono.
