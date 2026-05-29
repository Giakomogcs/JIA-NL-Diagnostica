# Documentos de conhecimento (RAG) — NL Diagnostica

Documentos para alimentar a base RAG do agente. São conhecimento de domínio (empresa, linha Hemostasia, licitações, regras de decisão, integração Effecti e exemplos resolvidos) que o assistente consulta via `search_knowledge_base`.

> O RAG é **global**: todos os usuários autenticados consultam tudo via agente (sem ACL por equipe/categoria).

## Arquivos

| file_id | Arquivo | Conteúdo |
|---|---|---|
| `EMPRESA-NLDIAG-01` | `01-empresa-nl-diagnostica.md` | Perfil da empresa, linhas e regra de ouro de escopo |
| `LINHA-HEMOSTASIA-01` | `02-linha-hemostasia.md` | Produtos/serviços, finalidade de uso e termos técnicos |
| `GLOSSARIO-LICITACOES-01` | `03-glossario-licitacoes.md` | Modalidades, estrutura de edital, por produto/lote/total |
| `REGRAS-PARTICIPACAO-01` | `04-regras-participacao.md` | Critérios de aceitar/recusar e uso do aprendizado |
| `EFFECTI-INTEGRACAO-01` | `05-integracao-effecti.md` | Campos da Effecti, status e sincronização |
| `EXEMPLOS-ANALISE-01` | `06-exemplos-analise.md` | Casos resolvidos (few-shot) para calibrar o raciocínio |

## Como ingerir
1. Suba os workflows `NLDiag-RAG.json` no n8n e configure as credenciais (`NLDiag-DB`, `Azure OpenAI`, `Supabase account`).
2. Edite `N8N_BASE` no script e rode:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\.scripts\ingest-rag-docs.ps1
   ```
   O script envia cada `.md` para `POST /webhook/nldiag-rag-upsert` (faz chunk + embeddings + insert em `nl_documents`).
3. Confira no painel **Documentos** (admin) do front.

## Manutenção
- Reenviar um arquivo com o **mesmo `file_id`** substitui os chunks antigos (idempotente).
- Atualize/expanda estes documentos conforme a empresa adicionar linhas/produtos ao catálogo.
