# PRD — Aprendizado por Feedback na Triagem (NL Diagnóstica)

**file_id:** PRD-APRENDIZADO-TRIAGEM-01
**Autor:** Engenharia
**Data:** 2026-06-19
**Status:** Proposto (aguardando aprovação para implementação)
**Relacionado:** `migrations-clean/011_catalogo_termos.sql` (negativos / termos fortes),
`016_super_triagem.sql` (`nl_catalogo_merge_termos`, `analise_profunda`),
`018_match_precisao_super_itens.sql` (recálculo de status), `nl_record_decision`,
`NLDiag-Inteligencia.json`, `front-nldiagnostica.html` (`decide()`).

---

## 1. Contexto

Hoje a triagem dos editais é **estática entre deploys**: o catálogo (`termos_fortes`,
`sinonimos`, `palavras_chave`), os negativos (`nl_match_negativo`) e o prompt da super
triagem só mudam quando alguém edita um seed/migration ou roda o Motor de Bulas. Quando o
operador **aceita** ou **recusa** um edital na aba **Buscar editais** (`decide()` →
`nl_record_decision` + sync Effecti), esse julgamento humano **não retroalimenta** o motor de
match. O conhecimento ("isso aqui é falso positivo por causa da palavra X", "essa linha
deveria pegar o termo Y") se perde.

O objetivo desta feature é fechar o **loop de aprendizado**: no momento do aceite/recusa, o
operador pode registrar **palavras boas** (reforçam o match), **palavras ruins** (bloqueiam) e
**regras/aprendizados** em texto livre, e o sistema **reprocessa a base** logo em seguida —
melhorando a triagem incrementalmente, com curadoria humana.

## 2. Problema

1. **Conhecimento volátil:** o operador percebe o padrão do erro na hora da decisão, mas não
   tem onde registrá-lo de forma que afete as próximas análises.
2. **Catálogo/negativos só mudam via migration ou Motor de Bulas:** ajuste fino exige editar
   SQL e reimportar — fora do alcance do operador de negócio.
3. **Risco de poluir o DB (preocupação central do pedido):** se cada decisão despejar termos e
   regras sem controle, o catálogo incha com **sinônimos redundantes, quase-duplicados e
   regras conflitantes**. Isso:
   - degrada a precisão (termos genéricos demais voltam a casar falso positivo — exatamente o
     que 011/012/018 corrigiram);
   - infla o prompt da super triagem (custo/tokens, ruído, alucinação);
   - cria contradições ("aceitar quando X" vs. "recusar quando X").
4. **Sem reanálise imediata:** mesmo hoje, mexer no catálogo exige clicar manualmente em
   "↻ Reprocessar análises". O fluxo desejado é: registrar aprendizado → reprocessar/reanalisar
   **automaticamente** → ver o resultado atualizado.

## 3. Objetivos e métricas de sucesso

| Objetivo                                 | Métrica                                                                         | Alvo                                                    |
| ---------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Operador refina a triagem sem editar SQL | Tempo p/ aplicar um aprendizado                                                 | ≤ 1 clique no fluxo de decisão                          |
| Evitar inchaço do DB por redundância     | % de termos/regras candidatos descartados por já existirem (exato ou semântico) | reportado e ≥ 0; **0 duplicados gravados**              |
| Não degradar a precisão                  | FP no `sugerido_aceitar` após N aprendizados                                    | não piora vs. baseline (PRD-MATCH-EDITAIS-01 §8: ≤ 10%) |
| Reanálise efetiva                        | base reprocessada após cada aprendizado aceito                                  | 100% dos pendentes                                      |
| Rastreabilidade                          | todo termo/regra gravado guarda origem (edital, usuário, ação)                  | 100%                                                    |
| Reversibilidade                          | todo aprendizado pode ser desativado/removido                                   | 100%                                                    |

## 4. Escopo

### 4.1 Dentro do escopo

- **Painel de feedback** no fluxo de aceite/recusa (modal do edital): campos para _palavras
  boas_, _palavras ruins_ e _regra/aprendizado_ (texto livre), com **linha do catálogo** alvo.
- **Guarda anti-duplicação em duas camadas** antes de gravar qualquer termo/regra:
  1. **Exata/normalizada** (lower+trim+sem acento), reaproveitando a lógica do
     `nl_catalogo_merge_termos` (016) e do `ON CONFLICT` do `nl_match_negativo` (011).
  2. **Semântica** (embeddings): candidato é comparado por similaridade de cosseno aos termos
     existentes da mesma família e às regras já cadastradas; acima do limiar → **descartado e
     reportado**, não gravado.
- **Tabela de regras/aprendizados** (`nl_triagem_regra`) com embedding, peso, escopo (linha),
  ativo/inativo, origem e teto de tamanho/quantidade.
- **Cache de embeddings de termos** (`nl_termo_embedding`) para a dedup semântica não re-embedar
  o catálogo inteiro a cada decisão.
- **Reprocessamento automático** após gravar o aprendizado: rodar `nl_rematch_all` em loop
  (como o `btnRematch` já faz) e, opcionalmente, re-disparar a **super triagem** do edital atual.
- **Injeção das regras ativas** no prompt da super triagem (`NLDiag-Inteligencia.json`).
- **UI de gestão** das regras na aba Catálogo (listar, desativar, excluir) — espelhando o que
  já existe para "Palavras indesejadas".

### 4.2 Fora do escopo (follow-up)

- Reescrever o motor de match determinístico (`nl_match_edital`) — só **alimentamos** suas
  entradas (termos_fortes / negativos) e o prompt da super triagem.
- Aprendizado totalmente automático sem curadoria (todo aprendizado nasce de uma ação humana
  de aceite/recusa).
- Ajuste do perfil de monitoramento na conta Effecti (fora do nosso código — ver
  `LIMITACOES-integracoes.md`).

## 5. Conceito de solução

```
[Operador aceita/recusa edital]
        │
        ▼
[Painel de feedback no modal]  palavras_boas[] | palavras_ruins[] | regra(texto) | linha
        │  (POST nldiag-aprendizado)
        ▼
[NLDiag-Aprendizado (n8n)]
   1. embeda candidatos (OpenAI embeddings, mesma dim. do RAG = 1536)
   2. dedup EXATA   → descarta já existentes (lower/trim/sem acento)
   3. dedup SEMÂNTICA via RPC (cosseno ≥ limiar) → descarta quase-duplicados
   4. grava só o que é NOVO:
        • palavras boas  → nl_catalogo_merge_termos (016, roteia <4 chars p/ sinônimo — 018)
        • palavras ruins → nl_admin_upsert_negativo (011)
        • regra          → nl_triagem_regra (+ embedding)
   5. dispara reprocesso: nl_rematch_reset() + loop nl_rematch_all(true,40)
   6. (opcional) re-dispara super triagem do edital atual
        │  resposta: {gravados, descartados_exato, descartados_semantico, reprocessados}
        ▼
[Front] toast com o resumo + loadStats() + loadEditais() + openEdital()
```

## 6. Requisitos funcionais

- **RF1 — Captura no momento da decisão:** ao aceitar/recusar, o operador pode (opcionalmente)
  informar `palavras_boas[]`, `palavras_ruins[]` e uma `regra` em texto livre, com a `linha` do
  catálogo alvo (default: linha sugerida pela análise do edital).
- **RF2 — Dedup exata:** antes de gravar, normalizar (lower, trim, remover acento) e descartar
  termos que já existem em `termos_fortes`/`sinonimos`/`palavras_chave` da linha ou em
  `nl_match_negativo`. Reaproveitar `nl_catalogo_merge_termos` (já faz isso) e `ON CONFLICT`.
- **RF3 — Dedup semântica:** para cada candidato (termo ou regra), calcular embedding e comparar
  por cosseno com os embeddings existentes do **mesmo escopo** (termos da linha; regras da
  linha). Se `similaridade ≥ LIMIAR_TERMO` (termos) ou `≥ LIMIAR_REGRA` (regras), **não grava** e
  reporta como `descartado_semantico` com o item mais próximo.
- **RF4 — Persistência seletiva:** só grava o que passou nas duas dedups. Palavras boas curtas
  (<4 chars) vão para `sinonimos` (regra de 018 contra siglas como termo forte). Palavras ruins
  vão para `nl_match_negativo` com `motivo` e `origem`.
- **RF5 — Regras/aprendizados:** `nl_triagem_regra(id, linha, texto, embedding, peso, ativo,
origem_edital_id, created_by, created_at)`. Texto com **cap de tamanho** (ex.: 280 chars) e
  **cap de quantidade ativa por linha** (ex.: 20). Ao exceder o teto, bloquear com mensagem
  pedindo curadoria (não silenciar).
- **RF6 — Injeção no prompt:** a super triagem (`NLDiag-Inteligencia.json`) lê as regras ativas
  (via RPC `nl_list_regras_ativas`) e as injeta no prompt como "Regras de negócio aprendidas",
  com teto total de caracteres (ex.: 4000, igual ao `contexto_bulas` de 017) para não estourar.
- **RF7 — Reprocesso automático:** após gravar, disparar `nl_rematch_reset()` + loop
  `nl_rematch_all(true, 40)` até `restantes = 0` (idempotente; nunca toca `aceito`/`recusado` —
  RF8 do PRD de match). Opcionalmente re-disparar a super triagem do edital decidido.
- **RF8 — Resposta transparente:** o webhook responde `{gravados:{boas,ruins,regras},
descartados_exato, descartados_semantico:[{termo, parecido_com, similaridade}], reprocessados,
restantes}` para o front exibir um resumo honesto ("3 adicionados, 2 já existiam, 1 parecido
  demais com 'fibrinogênio'").
- **RF9 — Gestão/rollback:** aba Catálogo lista as regras (`nl_list_regras`), permite desativar
  (`nl_admin_set_regra_ativo`) e excluir (`nl_admin_delete_regra`). Palavras boas/ruins já têm
  gestão (catálogo / negativos) — reaproveitar.
- **RF10 — Idempotência total:** reenviar o mesmo feedback não cria duplicados nem reprocessa em
  loop infinito; o resultado converge para "nada novo a gravar".

## 7. Requisitos não-funcionais

- **RNF1 — Anti-inchaço:** nenhuma gravação que não passe nas duas dedups; toda família de
  termos e regras tem **teto explícito**; o reporte de descarte é sempre visível ao operador.
- **RNF2 — Custo de embeddings controlado:** embedar apenas os **candidatos** (poucos por
  decisão) e usar `nl_termo_embedding` como cache; nunca re-embedar o catálogo inteiro online.
- **RNF3 — Limiares calibráveis:** `LIMIAR_TERMO` e `LIMIAR_REGRA` configuráveis (constante na
  RPC / variável no workflow); começar conservador (termo ≈ 0.90, regra ≈ 0.86) e ajustar.
- **RNF4 — Determinismo do match preservado:** o caminho crítico (`nl_match_edital`) continua
  determinístico; embeddings só atuam na **curadoria de entrada**, não na classificação.
- **RNF5 — Segurança:** todas as RPCs novas `SECURITY DEFINER` com gating `nl_is_admin()`/
  `nl_is_member()`/`nl_is_backend()` conforme o padrão das migrations. Sem segredo no front.
- **RNF6 — Reprocesso dentro do orçamento de webhook:** loop em lotes de 40 (padrão 013) para
  não estourar o statement timeout do Supabase.

## 8. Riscos

| Risco                                            | Mitigação                                                                                                 |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| Dedup semântica frouxa → entra quase-duplicado   | Limiar calibrável + reporte visível + cap por família; auditar após N decisões                            |
| Dedup semântica rígida → bloqueia termo legítimo | Operador vê "descartado por parecer com X" e pode forçar via aba Catálogo (gravação manual)               |
| Regras conflitantes no prompt                    | Cap de quantidade + curadoria na aba Catálogo + peso/ativo; regra é _sinal_, não decide sozinha           |
| Embeddings indisponíveis (OpenAI fora)           | Fluxo degrada para **dedup exata apenas** + aviso "dedup semântica indisponível" (não bloqueia a decisão) |
| Reprocesso pesado a cada decisão                 | Loop em lotes + só pendentes; super triagem opcional (só do edital atual, sob demanda)                    |
| Aprendizado reverter precisão dos 018/021        | RF7 não mexe em `aceito`/`recusado`; reauditar com os webhooks de stats/dashboard                         |
| Operador despeja texto enorme na regra           | Cap 280 chars + cap por linha + validação no boundary (front e RPC)                                       |

## 9. Critérios de aceite

1. No modal de aceite/recusa há campos de palavras boas/ruins/regra e tudo é enviado junto da
   decisão.
2. Enviar um termo que já existe (ex.: `inr` em Hemostasia) → **não grava**, retorna
   `descartado_exato`.
3. Enviar um quase-duplicado (ex.: `dosagem de fibrinogênio` quando já há `fibrinogênio`) →
   **não grava**, retorna `descartado_semantico` com o parecido e a similaridade.
4. Enviar um termo/regra realmente novo → grava e aparece na aba Catálogo (termos/negativos/
   regras).
5. Após gravar, a base é reprocessada automaticamente (stats mudam sem clicar em "Reprocessar")
   e o edital atual reabre com a análise atualizada.
6. As regras ativas aparecem no prompt da super triagem (verificável no log do workflow).
7. Exceder o cap de regras por linha bloqueia com mensagem de curadoria (não grava silenciosamente).
8. Toda regra/termo gravado guarda `origem_edital_id` e `created_by`; é possível desativar/excluir.
9. Reauditoria (webhooks `nldiag-tool-stats` / `nldiag-tool-dashboard`) mostra FP no
   `sugerido_aceitar` **não pior** que o baseline.

## 10. Telemetria / auditoria

- Log no workspace (n8n) com o resumo por decisão: candidatos, gravados, descartados (exato e
  semântico com o parecido), reprocessados, restantes.
- Webhooks de leitura já existentes para reauditar (`nldiag-tool-stats`, `nldiag-tool-dashboard`,
  `nldiag-tool-edital`).
- Atualizar `migrations-clean/README.md` e a memória do repo após aplicar.
