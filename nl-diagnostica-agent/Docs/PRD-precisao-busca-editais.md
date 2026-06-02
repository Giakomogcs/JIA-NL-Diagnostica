# PRD — Precisão da Busca de Editais (NL Diagnóstica)

**file_id:** PRD-MATCH-EDITAIS-01
**Autor:** Engenharia
**Data:** 2026-06-02
**Status:** Proposto (aguardando aprovação para implementação)
**Relacionado:** `migrations-clean/006_licitacao_rpc.sql` (`nl_match_edital`), `007_seeds.sql` (catálogo), `NLDiag-Effecti-Ingest.json`

---

## 1. Contexto

A aba **Buscar editais** lista editais reais captados da API da Effecti e classificados
automaticamente pela função `nl_match_edital`, que cruza o **catálogo** da NL Diagnóstica
com o texto dos **itens** de cada edital. O resultado define o `status`
(`sugerido_aceitar` / `analisando` / `sugerido_recusar`).

O objetivo do produto é que a busca retorne **apenas editais existentes, corretos e
pertinentes** ao que a NL Diagnóstica fornece (Hemostasia laboratorial, Hemostasia Point of
Care, Eletroforese capilar, Parasitologia/Coproplus e Testes rápidos imunocromatográficos).

## 2. Problema

Auditoria de **2026-06-02** (via webhooks `nldiag-tool-stats`, `nldiag-tool-dashboard`,
`nldiag-tool-edital`) sobre **352 editais** reais:

| Status            | Qtd | %   |
| ----------------- | --- | --- |
| sugerido_recusar  | 276 | 78% |
| sugerido_aceitar  | 50  | 14% |
| analisando        | 24  | 7%  |
| aceito            | 2   | —   |

**Os editais existem** (não há alucinação na tabela — só o agente de chat redige texto).
O problema está na **precisão da classificação**:

### 2.1 Falsos positivos no "sugerido_aceitar" (~36%, +12% duvidosos)

Varredura item a item dos 50 "aceitar":

- **~26 relevantes (52%)** — reagentes/exames de hemostasia (TP/INR, TTPA, fibrinogênio),
  eletroforese de proteínas, parasitológico de fezes (inclusive item literal "COPROPLUS"),
  testes rápidos COVID.
- **~6 duvidosos (12%)** — painéis virais multiplex (Flu/VSR além do COVID), credenciamento
  de serviços laboratoriais.
- **~18 falsos positivos (36%)** — itens que **não** são da NL mas casaram por palavra-chave
  genérica:

| Edital (item que casou)                                  | Keyword indevida   | Catálogo errado atribuído          |
| -------------------------------------------------------- | ------------------ | ---------------------------------- |
| CONCENTRADO DE FATOR DE COAGULAÇÃO (fator VII, remédio)  | `coagulação`       | Analisador de coagulação           |
| Tiras reagentes para **glicemia** em comodato            | `comodato`+`reagentes` | Locação/comodato hemostasia    |
| ESPONJA ESTÉRIL HEMOSTÁTICA ABSORVÍVEL (cirúrgica)       | `coagulação`/`hemostasia` | Analisador de coagulação    |
| PINÇA CIRÚRGICA KELLY / Pinça hemostática Pean           | `hemostasia`       | Analisador de coagulação           |
| CATETER para hemostasia                                  | `hemostasia`       | Analisador de coagulação           |
| VITAMINA K injetável **uso veterinário**                 | `coagulação`       | Analisador de coagulação           |
| SACO impermeável para **óbito COVID-19** (body bag)      | `covid-19`         | Teste rápido COVID                 |
| FITA/TIRA HGT **glicemia**                               | `comodato`+`reagentes` | Locação/comodato hemostasia    |
| REAGENTE para **HEMOGASÔMETRO** (gasometria)             | `comodato`/`reagentes` | hemostasia                       |
| INDICADOR BIOLÓGICO de esterilização ("teste desafio")   | `teste`            | Teste rápido                       |
| Exodontia / anestésico odontológico / bisturi bipolar    | `coagulação`/`hemostasia` | Analisador de coagulação        |
| DESINFETANTE com peróxido                                | (ruído covid)      | Teste rápido                       |

### 2.2 Falsos positivos no "analisando" (~25%)

Esponja hemostática, pinça Kelly, Hemospon, caneta de bisturi elétrico, anestésico
odontológico e **primer/oligonucleotídeo de PCR** também escaparam para "analisando".

### 2.3 Causas-raiz (confirmadas)

1. **Keywords genéricas demais no catálogo:** `coagulação`, `comodato`, `reagentes`,
   `controle`, `teste`. Aparecem em **medicamentos**, **insumos cirúrgicos** e **qualquer
   comodato hospitalar** → casam itens fora de escopo.
2. **Ambiguidade clínico × cirúrgico:** "hemostasia" laboratorial (coagulação in vitro) vs.
   "hemostasia" cirúrgica (estancar sangramento: esponjas, pinças, cateteres). O catálogo não
   distingue, e o termo cirúrgico domina em volume.
3. **Match ignora o `objeto` do edital e o `palavraEncontrada` da Effecti.** Só olha
   `produto_licitado` dos itens. Editais **sem itens detalhados** (`itens_total = 0`) viram
   `sugerido_recusar` automático mesmo sendo pertinentes (ex.: "reagentes químicos de uso
   laboratorial" 0/0 itens).
4. **Veredito instável:** as mesmas tiras de glicemia caem ora em "aceitar" ora em "recusar"
   só por a palavra "comodato" estar presente.

## 3. Objetivos e métricas de sucesso

| Objetivo                                              | Métrica                                  | Alvo        |
| ----------------------------------------------------- | ---------------------------------------- | ----------- |
| Reduzir falsos positivos no "sugerido_aceitar"        | % de FP na amostra auditada              | ≤ 10%       |
| Não perder editais pertinentes (recall)               | % de relevantes que caem em "recusar"    | ≤ 5%        |
| Estabilidade do veredito                              | mesmo item → mesma decisão               | 100%        |
| Transparência                                         | toda decisão mostra a keyword/termo forte que casou | 100% |

## 4. Escopo

### 4.1 Dentro do escopo

- Reescrever `nl_match_edital` para usar **termos fortes vs. fracos** e **negativos**.
- Cruzar também o **`objeto`** do edital e considerar o **`palavraEncontrada`** da Effecti.
- Reclassificar o **catálogo** (seed 007) separando palavras fortes, fracas e termos de bloqueio.
- Tratar editais **sem itens** (fallback pelo objeto, com score reduzido → "analisando").
- Reprocessar a base atual via `nl_rematch_all`.

### 4.2 Fora do escopo (registrar como follow-up)

- Configuração do **perfil de monitoramento dentro da conta Effecti** (filtra a relevância na
  origem; é ajuste na plataforma deles, não no nosso código).
- Match semântico por embeddings/IA (evolução futura; manter heurística determinística agora).

## 5. Requisitos funcionais

- **RF1 — Termos fortes:** um item só "participa" se casar ao menos **1 termo forte**
  específico da NL (ex.: `tempo de protrombina`, `ttpa`, `fibrinogênio`, `dímero-d`,
  `eletroforese de proteínas`, `coproparasitológico`, `coproplus`, `imunofixação`). Termos
  fracos sozinhos (`coagulação`, `reagentes`, `comodato`, `controle`, `teste`) **não** bastam.
- **RF2 — Termos negativos (bloqueio):** se o item contém termo de outra área, é **descartado**
  mesmo que tenha casado: `esponja`, `pinça`, `cateter`, `bisturi`, `glicemia`, `glicose`,
  `hgt`, `vitamina k`, `fator vii`, `exodontia`, `anestésico`, `óbito`, `body bag`, `saco para
  óbito`, `hemogasômetro`, `gasometria`, `indicador biológico`, `esterilização`, `primer`,
  `oligonucleotídeo`, `desinfetante`, `uso veterinário`/`veterinário`.
- **RF3 — Sinal do objeto:** o `objeto` do edital também é cruzado com termos fortes; reforça o
  score, mas **não** decide sozinho.
- **RF4 — Sinal Effecti:** `palavraEncontrada` é considerado sinal auxiliar (peso baixo).
- **RF5 — Editais sem itens:** se `itens_total = 0`, decide pelo objeto: termo forte →
  `analisando`; nada → `sugerido_recusar` (nunca `sugerido_aceitar` automático).
- **RF6 — Limiar de aceite:** `sugerido_aceitar` exige modo `total`/`lote` **com termo forte**,
  ou `score_match ≥ 0.5` **com ao menos 1 item forte**; senão `analisando`; zero forte →
  `sugerido_recusar`.
- **RF7 — Transparência:** `justificativa_ia` registra qual(is) termo(s) forte(s) casou(aram)
  e quais negativos bloquearam.
- **RF8 — Idempotência:** reexecução de `nl_match_edital`/`nl_rematch_all` não altera editais já
  decididos (`aceito`/`recusado`).

## 6. Requisitos não-funcionais

- **RNF1:** determinístico e explicável (sem dependência de IA externa no caminho crítico).
- **RNF2:** `nl_rematch_all` sobre ~350 editais conclui em tempo de uma chamada de webhook.
- **RNF3:** sem mudança de assinatura pública de RPC que quebre o front (ou atualizar front junto).
- **RNF4:** alterações de catálogo via migration idempotente (re-rodar não duplica).

## 7. Riscos

| Risco                                                        | Mitigação                                                       |
| ----------------------------------------------------------- | -------------------------------------------------------------- |
| Lista de negativos remover um edital legítimo               | Negativo só bloqueia o **item**, não o edital; validar amostra |
| Termos fortes muito restritos → cair recall                 | Revisar contra os 26 relevantes da auditoria antes do deploy   |
| Reprocessar reverter decisões humanas                       | RF8: nunca altera `aceito`/`recusado`                          |
| Effecti continuar mandando muito ruído na origem            | Follow-up: ajustar perfil de monitoramento na conta Effecti    |

## 8. Critérios de aceite

1. Reauditoria pós-deploy (mesmos webhooks) mostra **FP ≤ 10%** no "sugerido_aceitar".
2. Os **18 falsos positivos** listados em §2.1 saem do "aceitar".
3. Os **26 relevantes** continuam em "aceitar"/"analisando" (recall preservado).
4. Editais sem itens deixam de virar "recusar" automático quando o objeto tem termo forte.
5. Cada edital sugerido mostra na `justificativa_ia` o termo forte que motivou a sugestão.
