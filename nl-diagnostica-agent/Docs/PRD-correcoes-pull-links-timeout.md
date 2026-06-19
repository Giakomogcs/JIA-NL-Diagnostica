# PRD — Correções de Captação, Links de Edital e Timeout em PDFs Grandes

> NL Diagnóstica — Agente de Licitações
> Criado em: 2026-06-19 · **Revisado com diagnóstico real em 2026-06-19**
> Complementa: `PRD-precisao-busca-editais.md`, `PLANO-implementacao-match.md` e `LIMITACOES-integracoes.md`

Este PRD endereça **três problemas reportados** e **dois bugs descobertos durante o diagnóstico**.

> ⚠️ **O diagnóstico mudou o entendimento do Problema 1.** As hipóteses iniciais (falta de paginação, cadastro manual) **não** explicam o caso reportado. Ver §1.

---

## 0. Resumo executivo (pós-diagnóstico)

| #   | Problema reportado                  | Causa-raiz **real** (verificada no banco/código)                                                                                                                               | Correção                                                                                   | Prioridade |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ | ---------- |
| 1   | "Edital não puxou"                  | **Foi puxado.** Está no banco como `sugerido_recusar`, score 0, porque veio **com 0 itens** e o objeto não casou nenhum termo forte. Ficou **enterrado na pilha de recusados** | Melhorar match de editais sem itens (usar objeto/palavra-chave Effecti) + dar visibilidade | **Alta**   |
| 2   | Links errados (`.../sessao/188384`) | `url_edital` = página de sessão do portal (campo `url` da Effecti). **Mas o `raw.anexos[]` traz os PDFs diretos** (EDITAL.PDF etc.), que hoje são **ignorados**                | Mapear `raw.anexos` → link direto do edital; renomear rótulos                              | **Alta**   |
| 3   | Timeout/fetch em PDF grande         | Super Triagem (a) baixa a **URL errada** (HTML da sessão, não PDF) e (b) responde **só no fim** → estoura o proxy (~100s)                                                      | Baixar o PDF de `anexos` + tornar a Super Triagem **assíncrona** com polling               | **Alta**   |
| 4   | _(bug achado)_ Datas invertidas     | `nl_parse_ts` faz `::timestamptz` **antes** do parser BR → `03/07/2026` (3 jul) vira `2026-03-07` (7 mar). DD/MM lido como MM/DD                                               | Tentar `DD/MM/YYYY` **antes** do cast genérico + backfill                                  | **Alta**   |
| 5   | _(achado)_ Edital vinha da lixeira  | `raw.naLixeira = true`: o aviso estava **descartado na Effecti** e ainda assim foi ingerido                                                                                    | Ingerir `naLixeira`/`favorito` e refletir/filtrar no painel                                | Média      |

> **Nada é "inventado".** O link vem literalmente do campo `url` da Effecti, e o edital faltante existe no banco — apenas escondido no recusar. O sistema não fabrica dados.

---

## 1. Problema 1 — "O edital não foi puxado" (na verdade, FOI)

### 1.1 Evidência (consulta ao banco em 2026-06-19)

O edital existe:

```
id            = c76cf8c0-4127-4114-b1c7-4af31189caf6
id_licitacao  = 7747471          numero_edital = 019/2026
orgao         = EMSERH / (1) EMSERH -SÃO LUIS MA      uf = MA
status        = sugerido_recusar  score_match = 0
itens_total   = 0
justificativa = "Sem itens detalhados e sem termo forte no objeto."
created_at    = 2026-06-16  (entrou no pull do dia 16)
```

E no `raw` da Effecti:

```
itensEdital       = []                        ← 0 itens detalhados
palavraEncontrada = ["hemocentro"]            ← único gatilho do aviso
naLixeira         = true                       ← estava DESCARTADO na Effecti
favorito          = false
```

### 1.2 Causa-raiz real

1. **Veio sem itens** (`itensEdital: []`). O `nl_match_edital` cruza **itens × catálogo**; sem itens, depende do _fallback_ pelo `objeto`, que exige **termo forte**.
2. **O objeto não casou termo forte.** O texto tem "Reagentes", "Comodato", "Laboratório de Hematologia", "pesquisa de Hemoglobina" — mas nenhum bateu um termo forte do catálogo (Hematologia/hemograma pode estar **fora do escopo** da NL; "hemoglobina/hemoglobinopatias" seria da linha **Eletroforese**, mas o termo não casou).
3. **Resultado:** caiu em `sugerido_recusar` (comportamento conhecido — `LIMITACOES` §3.3: "edital sem itens → análise limitada"). Ficou **invisível** na fila de aceitar/analisar, dando a impressão de que "não foi puxado".
4. **Bônus:** o aviso veio com `naLixeira: true` — ou seja, **já descartado na Effecti**. Mesmo assim foi ingerido.

> ✅ **Conclusão:** paginação do pull e cadastro manual **não eram o problema** deste caso. O problema é **precisão do match para editais sem itens** + **visibilidade**.

### 1.3 O que será feito

**T1.1 — Match por objeto/palavra-chave quando não há itens.**
Ajustar `nl_match_edital` para, quando `itens_total = 0`:

- cruzar o `objeto` **e** o `palavraEncontrada` da Effecti com `palavras_chave`/`sinonimos` (não só `termos_fortes`);
- nesse caso, classificar como **`analisando`** (revisão humana) em vez de `recusar` automático — evita enterrar editais relevantes sem itens.

**T1.2 — Refletir o estado da Effecti.**
Ingerir `naLixeira` e `favorito` do `raw` em colunas (`effecti_lixeira BOOLEAN`, `effecti_favorito BOOLEAN`) e:

- mostrar um aviso no painel ("⚠️ descartado na Effecti") quando `effecti_lixeira`;
- opcionalmente permitir filtrar/ocultar os que vieram da lixeira.

**T1.3 — Visibilidade de borderline.**
No painel, garantir que editais com `objeto` relevante mas sem itens apareçam em "Analisar" (não só em "Recusar"), e sugerir **Super Triagem** (que lê o PDF real — ver §3) para resolver o mérito.

### 1.4 Critérios de aceite (P1)

- [ ] O edital 019/2026 deixa de ser `recusar` automático e vai para `analisando` (ou aceita, se a Super Triagem confirmar).
- [ ] Editais sem itens com objeto relevante não são mais silenciosamente recusados.
- [ ] O painel sinaliza quando um aviso veio `naLixeira` da Effecti.

---

## 2. Problema 2 — Links de edital incorretos

### 2.1 Causa-raiz real (com achado importante)

`nl_upsert_edital` grava `url_edital = url_portal = payload->>'url'`. Esse `url` é a **página de sessão do portal**:

```
url = https://www.licitacoes-e.com.br/aop/consultar-detalhes-licitacao.aop?...
```

**Mas o payload da Effecti traz `anexos[]` com os PDFs diretos — e isso é hoje 100% ignorado:**

```json
"anexos": [
  {"nome":"EDITAL.PDF",             "url":".../documentos/L-1087367/EDITAL.PDF"},
  {"nome":"AVISO_DE_LICITACAO.PDF", "url":".../documentos/L-1087367/AVISO_DE_LICITACAO.PDF"}
]
```

O exemplo do usuário (`licitanet.com.br/sessao/188384`) é o mesmo padrão: o `url` é a sessão; o documento real está (quando existe) em `anexos`.

### 2.2 O que será feito

**T2.1 — Persistir os anexos e eleger o PDF do edital.**

- Adicionar coluna `nl_edital.anexos JSONB` e `nl_edital.url_documento TEXT`.
- No `nl_upsert_edital`: gravar `raw.anexos`; eleger `url_documento` = o anexo cujo nome casa `EDITAL` (preferência), senão `AVISO_DE_LICITACAO`, senão o primeiro `.PDF`.

**T2.2 — Rótulos corretos no front.**

- "Abrir no portal ↗" → `url_portal` (página de sessão).
- "Edital (PDF) ↗" → `url_documento` quando existir.
- Aplicar nos 3 pontos do front (linha da tabela + 2 blocos de detalhe).

**T2.3 — Backfill.**
Migração que repreenche `anexos`/`url_documento` a partir de `raw` para os editais já ingeridos.

### 2.3 Critérios de aceite (P2)

- [ ] Editais com `anexos` exibem link direto do PDF do edital.
- [ ] O rótulo distingue "portal" de "PDF do edital".
- [ ] Backfill aplicado aos editais existentes.

---

## 3. Problema 3 — Timeout em PDFs grandes (Super Triagem)

### 3.1 Causa-raiz real (dupla)

1. **Baixa a URL errada.** A Super Triagem baixa `url_edital` (a página de sessão **HTML**, não PDF). O nó "Checar PDF" não acha `%PDF` → degrada para "objeto+itens". Para portais que entregam HTML pesado, isso ainda consome tempo.
2. **Responde só no fim.** O webhook `nldiag-super-triagem` usa `responseNode` e só responde após download → OCR → LLM. Em editais grandes isso passa do limite do proxy (~100s) → **524/erro de fetch** no front (mesmo padrão que o Motor de Bulas já resolveu respondendo imediato).

### 3.2 O que será feito

**T3.1 — Baixar o PDF certo.** Usar `url_documento` (de §2) em vez de `url_edital` no nó "Baixar PDF". Cai direto no `EDITAL.PDF`.

**T3.2 — Super Triagem assíncrona.** Espelhar o Motor de Bulas: responder `{status:"processando", edital_id}` **logo após validar** o `edital_id`; rodar download→OCR→LLM→`nl_set_analise_profunda` em background.

**T3.3 — Polling no front.** Ao receber `processando`, manter "Analisando…" e fazer polling de `nl_get_edital` (a cada ~5s, teto ~3min) checando `analise_profunda_at`; ao mudar, renderizar o resultado. Se estourar o teto: "ainda processando" (não erro).

**T3.4 — Endurecer download.** `timeout` 45s; manter corte de 20 MB no OCR com degradação graciosa (analisa objeto+itens e declara nos "riscos").

### 3.3 Critérios de aceite (P3)

- [ ] Super Triagem em PDF grande **não** retorna erro de fetch.
- [ ] Baixa o `EDITAL.PDF` direto (quando há anexo) em vez do HTML da sessão.
- [ ] Front mostra progresso e exibe resultado via polling; acima do limite, degrada graciosamente.

---

## 4. Bug 4 — Inversão de datas (`nl_parse_ts`)

### 4.1 Causa-raiz

Em `005_licitacao_schema.sql`, `nl_parse_ts` tenta `p_txt::timestamptz` **antes** do parser BR. Com `DateStyle` padrão (MDY), `"03/07/2026"` é aceito como **MM/DD** (7 de março) e a função **retorna logo**, sem chegar ao `to_timestamp(..., 'DD/MM/YYYY')`.

Evidência no edital 019/2026:

- `dataFinalProposta "03/07/2026"` (3 jul) → `data_abertura 2026-03-07` (7 mar) ❌
- `dataPublicacao "06/02/2026"` (6 fev) → `data_publicacao 2026-06-02` (2 jun) ❌

Afeta **ordenação e filtros por data** de praticamente todos os editais Effecti.

### 4.2 O que será feito

**T4.1 — Corrigir ordem de parsing.** Reescrever `nl_parse_ts`: detectar o padrão BR (`\d{2}/\d{2}/\d{4}`) e parsear como `DD/MM/YYYY [HH24:MI:SS]` **antes** de tentar o cast ISO genérico.

**T4.2 — Backfill das datas.** Reprocessar `data_*` dos editais a partir do `raw` (usar a função corrigida). Como `raw` está preservado, dá para recomputar com segurança.

### 4.3 Critérios de aceite (P4)

- [ ] `03/07/2026` é armazenado como 3 de julho.
- [ ] Datas dos editais existentes corrigidas via backfill.

---

## 5. Escopo e não-escopo

**No escopo:** match de editais sem itens, refletir lixeira/favorito da Effecti, links diretos via `anexos`, Super Triagem assíncrona baixando o PDF certo, correção do parser de datas + backfills.

**Fora do escopo (limitações conhecidas — `LIMITACOES`):** perfil de monitoramento da Effecti (§1.2), push em tempo real (§1.6), login/captcha em portais (§4.1), dedupe entre fontes (§2.5). **Paginação do ingest e cadastro manual saíram do escopo imediato** — não eram a causa do caso reportado (podem voltar como melhoria futura se surgir caso real de página perdida).

---

## 6. Plano de implementação (ordem sugerida)

1. **T4.1 + T4.2 — Datas** (migração `019`, isolada e de baixo risco; corrige ordenação para todos).
2. **T2.1 + T2.3 — `anexos`/`url_documento`** (migração `020` + backfill): destrava links **e** a Super Triagem.
3. **T2.2 — Rótulos no front**.
4. **T3.1–T3.4 — Super Triagem assíncrona + PDF certo** (n8n + front).
5. **T1.1 — Match sem itens** (migração `021` no `nl_match_edital`) + "↻ Reprocessar".
6. **T1.2 + T1.3 — Lixeira/favorito + visibilidade** (migração + front).

Cada passo: migração no Supabase → reimportar workflow no n8n → rebuild do front (`build-front-workflow.ps1`) → reimportar `NLDiag-Front.json` → validar.

## 7. Artefatos a tocar

| Tarefa    | Arquivos                                                           |
| --------- | ------------------------------------------------------------------ |
| T4        | nova `019_fix_parse_ts.sql`                                        |
| T2.1/T2.3 | nova `020_edital_anexos.sql` + `006`/`015` upsert                  |
| T2.2      | `front-nldiagnostica.html`                                         |
| T3        | `workspaces/NLDiag-Inteligencia.json` + `front-nldiagnostica.html` |
| T1.1      | nova `021_match_sem_itens.sql` (`nl_match_edital`)                 |
| T1.2/T1.3 | migração colunas Effecti + `front-nldiagnostica.html`              |

## 8. Riscos / a confirmar com o usuário

- **Escopo da NL para Hematologia:** confirmar se "Laboratório de Hematologia/hemograma" é fornecível. Se não for, o 019/2026 deve ir para **analisar** (objeto 02 = hemoglobina/Eletroforese) e não aceitar automático.
- **Backfill de datas:** recomputar a partir do `raw` — validar amostra antes de aplicar em massa.
- **n8n background:** garantir que a execução não morre ao responder cedo (padrão já validado no Motor de Bulas).
