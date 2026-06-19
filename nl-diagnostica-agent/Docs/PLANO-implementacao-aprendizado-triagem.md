# Plano de Implementação — Aprendizado por Feedback na Triagem

**file_id:** PLAN-APRENDIZADO-TRIAGEM-01
**Referência:** `Docs/PRD-aprendizado-triagem-feedback.md`
**Data:** 2026-06-19
**Status:** Proposto

---

## Visão geral

Implementação em **6 fases**, cada uma verificável de forma isolada. A lógica de dedup e
persistência fica no Postgres (Supabase); o cálculo de embeddings e a orquestração ficam num
workflow novo do n8n (`NLDiag-Aprendizado`), porque o Postgres não embeda texto. O front ganha
um painel no modal de decisão e gestão de regras na aba Catálogo.

```
Fase 1  Schema: regras + cache de embeddings + RPCs de dedup/persistência   (migration 023)
Fase 2  RPCs de leitura/gestão de regras + injeção no prompt                  (migration 023)
Fase 3  Workflow NLDiag-Aprendizado (embeda, dedup, grava, reprocessa)        (n8n)
Fase 4  Super triagem lê regras ativas                                        (NLDiag-Inteligencia)
Fase 5  Front: painel de feedback no aceite/recusa + reprocesso automático    (HTML + build)
Fase 6  Front: gestão de regras na aba Catálogo + reauditoria                 (HTML + webhooks)
```

Princípio anti-inchaço (preocupação central): **nada é gravado sem passar por dedup exata +
semântica**, e **toda família de termos/regras tem teto**. O operador sempre vê o que foi
descartado e por quê.

---

## Fase 1 — Schema e dedup

**Arquivo novo:** `migrations-clean/023_aprendizado_triagem.sql` (idempotente; rodar após 022).

1. **Tabela de regras/aprendizados:**

   ```sql
   CREATE TABLE IF NOT EXISTS nl_triagem_regra (
     id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
     linha            TEXT NOT NULL,
     texto            TEXT NOT NULL CHECK (length(texto) <= 280),
     embedding        vector(1536),
     peso             SMALLINT NOT NULL DEFAULT 1,
     ativo            BOOLEAN NOT NULL DEFAULT TRUE,
     origem_edital_id UUID,
     created_by       UUID DEFAULT auth.uid(),
     created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
   );
   ```

   RLS: SELECT para `nl_is_member()/nl_is_backend()`; escrita só via RPC `SECURITY DEFINER`.
   Índice ivfflat/hnsw em `embedding` (igual ao RAG de 002) para a busca por similaridade.

2. **Cache de embeddings de termos** (evita re-embedar o catálogo a cada decisão — RNF2):

   ```sql
   CREATE TABLE IF NOT EXISTS nl_termo_embedding (
     termo     TEXT PRIMARY KEY,        -- normalizado (lower/trim/unaccent)
     escopo    TEXT NOT NULL,           -- 'forte' | 'fraco' | 'negativo'
     embedding vector(1536) NOT NULL,
     created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
   );
   ```

3. **RPC de dedup semântica de termo** — recebe candidato + embedding, devolve o vizinho mais
   próximo e a similaridade dentro do escopo/linha:

   ```sql
   -- nl_termo_vizinho(p_linha text, p_escopo text, p_embedding vector)
   --   RETURNS {termo, similaridade}  (maior cosseno no escopo)
   ```

   Usa `1 - (embedding <=> p_embedding)` (padrão do `nl_match_documents`, 003).

4. **RPC de persistência de aprendizado** (transação única, idempotente):
   ```sql
   -- nl_aprendizado_aplicar(p_payload jsonb)
   --   p_payload: { linha, origem_edital_id,
   --                boas:[{termo,embedding}], ruins:[{termo,motivo,embedding}],
   --                regra:{texto,embedding} | null,
   --                limiar_termo, limiar_regra }
   --   Faz: dedup exata + chama nl_termo_vizinho p/ semântica;
   --        grava só o novo (merge_termos p/ boas, upsert_negativo p/ ruins,
   --        insert nl_triagem_regra p/ regra); atualiza nl_termo_embedding;
   --        valida caps (regra <=280, <=20 ativas/linha) → erro explícito se estourar.
   --   RETURNS {gravados, descartados_exato, descartados_semantico[]}
   ```
   Reutiliza `nl_catalogo_merge_termos` (016, já roteia <4 chars p/ sinônimo via 018) e
   `nl_admin_upsert_negativo` (011).

**Verificação:** inserir candidato existente → `descartado_exato`; candidato com cosseno alto →
`descartado_semantico`; candidato novo → gravado e visível em `nl_catalogo`/`nl_match_negativo`/
`nl_triagem_regra`.

---

## Fase 2 — Leitura/gestão de regras

Ainda em `023_aprendizado_triagem.sql`:

- `nl_list_regras_ativas(p_linha text DEFAULT NULL)` → texto das regras ativas (para o prompt),
  com **cap total de caracteres** (ex.: 4000, igual ao `contexto_bulas` de 017).
- `nl_list_regras()` → lista completa para a UI (id, linha, texto, peso, ativo, origem, data).
- `nl_admin_set_regra_ativo(p_id uuid, p_ativo bool)` e `nl_admin_delete_regra(p_id uuid)` —
  gating `nl_is_admin()`.

**Verificação:** `SELECT nl_list_regras_ativas('Hemostasia');` retorna só as ativas, truncado no
teto.

---

## Fase 3 — Workflow `NLDiag-Aprendizado`

**Arquivo novo:** `workspaces/NLDiag-Aprendizado.json` (importar no n8n).

Webhook `POST nldiag-aprendizado`, payload:

```json
{
  "edital_id": "<uuid>",
  "linha": "Hemostasia",
  "acao": "aceitar|recusar",
  "palavras_boas": ["..."],
  "palavras_ruins": ["..."],
  "regra": "texto livre"
}
```

Nós:

1. **Normalizar** candidatos (lower/trim/unaccent; descartar vazios; cap quantidade).
2. **Embeddings** (OpenAI, dim. 1536 — mesma do RAG): embeda boas + ruins + regra.
   - Se o nó de embeddings falhar → seguir com `dedup_semantica=false` (degradação graciosa,
     RNF/Risco do PRD), só dedup exata.
3. **`nl_aprendizado_aplicar`** com os candidatos + embeddings + limiares
   (`LIMIAR_TERMO≈0.90`, `LIMIAR_REGRA≈0.86`, configuráveis no nó Set).
4. **Reprocesso:** `nl_rematch_reset()` → loop `nl_rematch_all(true,40)` até `restantes=0`
   (replicar o padrão do `btnRematch`/013).
5. **(Opcional) re-super-triagem** do `edital_id` (chamar `nldiag-super-triagem`).
6. **Respond** imediato com `{gravados, descartados_exato, descartados_semantico, reprocessados,
restantes}`. Logar resumo (como o "Resumo Motor" de 016).

> Atenção (memória do repo): nas queries Postgres usar `{{ $json.body.X || '' }}` para opcionais
> e checar corpo não-vazio na resposta (falha silenciosa = execução morreu no meio).

**Verificação:** `Invoke-WebRequest .../webhook/nldiag-aprendizado` com um termo novo, um
existente e um quase-duplicado → resposta discrimina os três; stats mudam após o reprocesso.

---

## Fase 4 — Super triagem usa as regras

**Arquivo:** `workspaces/NLDiag-Inteligencia.json` (nó da Super Triagem).

1. Antes do LLM, buscar `nl_list_regras_ativas(linha)` (ou todas) e injetar no prompt como
   bloco **"Regras de negócio aprendidas"**, abaixo do catálogo/negativos, com teto de chars.
2. Manter a **REGRA DE OURO** de 018 (veículos/obras/medicamentos nunca compatíveis) acima das
   regras aprendidas (precedência de segurança).

**Verificação:** log do workflow mostra as regras ativas no prompt; uma regra nova muda o
veredito de um edital de teste após reprocesso.

---

## Fase 5 — Front: painel de feedback + reprocesso automático

**Arquivo:** `front-nldiagnostica.html` (depois rodar o build do README do repo).

1. No modal do edital (e no `openRejectModal`), adicionar bloco **"Refinar triagem (opcional)"**:
   - inputs de _palavras boas_ e _palavras ruins_ (chips/textarea, separadas por vírgula);
   - textarea _regra/aprendizado_ (maxlength 280, contador visível);
   - select de _linha_ (default = linha da análise do edital).
2. `decide()` passa a, **após** `nl_record_decision` + sync Effecti, chamar
   `POST nldiag-aprendizado` **se** houver algo preenchido; senão, segue o fluxo atual.
3. Exibir o resumo honesto retornado (toast/box): "3 adicionados · 2 já existiam · 1 parecido
   com 'fibrinogênio' (0.93)".
4. Após sucesso: `loadStats()` + `loadEditais()` (e `openEdital()` se reanalisou o atual) —
   reaproveitando o que `decide()` já faz no fim.

**Verificação:** aceitar um edital com uma palavra boa nova + uma regra → toast com resumo, lista
e stats atualizam sem clicar em "Reprocessar".

---

## Fase 6 — Gestão de regras + reauditoria

1. Aba **Catálogo**: tabela **"Regras aprendidas"** (`nl_list_regras`) com desativar/excluir,
   espelhando a UI de "Palavras indesejadas" (negativos). Container com `overflow-x:auto` +
   `min-width` (padrão responsivo do repo).
2. Reauditar com os webhooks de leitura (`nldiag-tool-stats`, `nldiag-tool-dashboard`,
   `nldiag-tool-edital`) e comparar FP do `sugerido_aceitar` com o baseline.
3. Atualizar `migrations-clean/README.md`, `workspaces/README.md` e a memória do repo
   (`/memories/repo/nl-diagnostica.md`) com a 023 + o workflow novo.

---

## Ordem de aplicação

```
1. Aplicar migration 023 no Supabase (após 022).
2. Importar NLDiag-Aprendizado.json no n8n; colar credencial de embeddings (mesma do RAG).
3. Atualizar/reimportar NLDiag-Inteligencia.json (regras no prompt).
4. Editar front-nldiagnostica.html → rodar build → reimportar NLDiag-Front.json.
5. Testar o trio (novo / existente / quase-duplicado) e o reprocesso automático.
6. Reauditar e calibrar LIMIAR_TERMO / LIMIAR_REGRA.
```

## Decisões a confirmar com o time antes de codar

- **Limiares iniciais** de similaridade (sugestão: termo 0.90, regra 0.86).
- **Caps**: regra 280 chars / 20 ativas por linha / 4000 chars totais no prompt — ok?
- **Re-super-triagem automática** do edital decidido: sempre, ou só sob botão? (custo de LLM/PDF).
- **Quem pode** registrar aprendizado: qualquer membro ou só admin? (gating das RPCs).
- **Provedor/modelo de embeddings**: confirmar reuso da mesma credencial/modelo do RAG (1536).
