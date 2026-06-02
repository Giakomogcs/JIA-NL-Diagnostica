# Plano de Implementação — Precisão da Busca de Editais

**file_id:** PLAN-MATCH-EDITAIS-01
**Referência:** `Docs/PRD-precisao-busca-editais.md`
**Data:** 2026-06-02
**Status:** Proposto

---

## Visão geral

Implementação em **4 fases**, cada uma verificável de forma isolada. Toda a lógica fica no
Postgres (Supabase), reaplicável via `nl_rematch_all`. O front praticamente não muda — apenas
passa a exibir a `justificativa_ia` mais rica (já suportada).

```
Fase 1  Catálogo: termos fortes/fracos + negativos      (migration 011)
Fase 2  nl_match_edital v2: regra forte/fraco/negativo   (migration 012)
Fase 3  Reprocessar base + reauditar                     (rematch + webhooks)
Fase 4  Ajustes finos + follow-up Effecti                (iteração)
```

---

## Fase 1 — Reclassificar o catálogo

**Arquivo novo:** `migrations-clean/011_catalogo_termos.sql`

1. Adicionar colunas em `nl_catalogo` (idempotente):
   - `termos_fortes TEXT[]` — específicos da NL (decidem participação).
   - `termos_negativos TEXT[]` — bloqueiam o item se presentes (escopo global, ver passo 3).
   - Manter `palavras_chave`/`sinonimos` como **termos fracos** (apoio, não decidem sozinhos).
2. Popular `termos_fortes` por linha:
   - **Hemostasia:** `tempo de protrombina`, `protrombina`, `tap`, `inr`, `ttpa`, `aptt`,
     `tromboplastina parcial`, `fibrinogênio`, `dímero-d`, `coagulograma`, `coagulômetro`.
   - **Hemostasia POC:** `coaguchek`, `cascade`, `abrazo`, `tca`, `tempo de coagulação ativada`,
     `point of care coagulação`.
   - **Eletroforese:** `eletroforese de proteínas`, `proteinograma`, `imunofixação`,
     `hemoglobinopatia`, `isoeletrofocalização`, `eletroforese capilar`.
   - **Parasitologia:** `parasitológico de fezes`, `coproparasitológico`, `protoparasitológico`,
     `coproplus`, `epf`, `coletor de fezes`.
   - **Testes rápidos:** `sars-cov-2`, `covid-19 igg`, `covid-19 igm`, `imunocromatográfico
covid`, `antígeno sars`.
3. Definir lista **global** de `termos_negativos` (numa função/constante, ou tabela
   `nl_match_negativos`): `esponja`, `pinça`, `cateter`, `bisturi`, `glicemia`, `glicose`,
   `hgt`, `vitamina k`, `fator vii`, `fator de coagulação`, `exodontia`, `anestésico`, `óbito`,
   `saco para óbito`, `body bag`, `hemogasômetro`, `gasometria`, `indicador biológico`,
   `esterilização`, `primer`, `oligonucleotídeo`, `desinfetante`, `veterinário`.
4. Idempotência por `WHERE NOT EXISTS` / `ADD COLUMN IF NOT EXISTS` (re-rodar não duplica).

**Verificação:** `SELECT linha, termos_fortes FROM nl_catalogo;` retorna os termos populados.

---

## Fase 2 — `nl_match_edital` v2

**Arquivo novo:** `migrations-clean/012_match_v2.sql` (substitui a função; mantém assinatura).

Nova lógica por item (`produto_licitado`, com fallback no `objeto` do edital):

```
para cada item:
  texto = lower(produto_licitado)
  se algum termo_negativo casa em texto:
      participa = false; motivo = 'bloqueado: <termo>'; continua
  forte  = nº de termos_fortes (catálogo) que casam (com fronteira de palavra)
  fraco  = nº de termos fracos que casam
  se forte >= 1:
      participa = true
      score = min(1.0, 0.6 + 0.2*forte + 0.05*fraco)
  senão:
      participa = false   # fraco sozinho NÃO basta (RF1)
```

Decisão do edital:

- `itens_total = 0` → olhar `objeto`: termo forte → `analisando`; senão → `sugerido_recusar`.
- `v_part = 0` → `sugerido_recusar`.
- modo `total`/`lote` **com** item forte, ou `score_match ≥ 0.5` com ≥1 forte → `sugerido_aceitar`.
- caso intermediário → `analisando`.
- Reaproveitar `nl_kw_match` (fronteira de palavra) — já existe e trata acentos/siglas.
- Preencher `justificativa_ia` com os termos fortes que casaram e os negativos que bloquearam (RF7).
- Manter `status` inalterado quando já `aceito`/`recusado` (RF8).

**Verificação (antes de reprocessar tudo):** rodar `nl_match_edital(<id>)` nos casos-controle:

- FP que devem sair: fator de coagulação (RJ), tiras de glicemia (SP), esponja hemostática (MS),
  pinça Kelly (RS), vitamina K veterinária (MG), body bag óbito (BA/SP), hemogasômetro (MG).
- TP que devem ficar: TP/INR (PE), COPROPLUS (GO), eletroforese (TO), TTPA (PB), COVID Cellex (SP).

---

## Fase 3 — Reprocessar e reauditar

1. `SELECT nl_rematch_all(true);` (só pendentes; não toca aceito/recusado — RF8).
2. Reauditar com os mesmos webhooks usados no diagnóstico:
   ```powershell
   $base="https://longflatworm-n8n.cloudfy.live/webhook"
   Invoke-WebRequest "$base/nldiag-tool-stats" -Method Post -ContentType application/json -Body '{}'
   Invoke-WebRequest "$base/nldiag-tool-dashboard" -Method Post -ContentType application/json -Body '{"status":"sugerido_aceitar","limit":100}'
   ```
3. Recalcular FP% sobre o "sugerido_aceitar". **Meta: ≤ 10%** (PRD §8).
4. Conferir que os 18 FP saíram e os 26 relevantes permaneceram.

**Critério de avanço:** metas batidas. Senão → Fase 4.

---

## Fase 4 — Ajuste fino e follow-up

1. Ajustar `termos_fortes`/`termos_negativos` conforme o que sobrar (loop curto: editar 011 →
   `nl_rematch_all` → reauditar).
2. Reavaliar os ~6 "duvidosos" (painéis virais multiplex, credenciamento de serviços) — decidir
   regra de negócio com a NL (entram ou não?).
3. **Follow-up Effecti (fora do código):** revisar o **perfil de monitoramento** na conta Effecti
   para reduzir ruído na origem (medicamentos, materiais cirúrgicos, limpeza). Documentar em
   `rag-docs/05-integracao-effecti.md`.
4. (Opcional/futuro) match semântico por embeddings como segunda camada.

---

## Itens de trabalho (checklist)

- [ ] **F1.1** Criar `011_catalogo_termos.sql` (colunas + termos fortes por linha + negativos globais).
- [ ] **F1.2** Rodar no Supabase e validar `SELECT termos_fortes`.
- [ ] **F2.1** Criar `012_match_v2.sql` com a regra forte/fraco/negativo + fallback objeto + justificativa.
- [ ] **F2.2** Validar nos casos-controle (7 FP e 5 TP) antes do rematch global.
- [ ] **F3.1** `nl_rematch_all(true)` e reauditoria por webhook.
- [ ] **F3.2** Calcular FP% e comparar com a meta (≤10%).
- [ ] **F4.1** Iterar termos se necessário.
- [ ] **F4.2** Abrir follow-up do perfil Effecti.
- [ ] **Docs** Atualizar `migrations-clean/README.md` com as migrations 011 e 012.

## Rollback

- Migrations 011/012 trazem bloco `DOWN` comentado restaurando a função/colunas anteriores.
- Como `nl_rematch_all` nunca toca `aceito`/`recusado`, reverter a função + novo rematch
  recompõe o estado anterior sem perda de decisões humanas.

## Dependências e ordem

```
011_catalogo_termos.sql  →  012_match_v2.sql  →  nl_rematch_all(true)  →  reauditoria
```

Nenhuma alteração obrigatória no front para esta entrega (a `justificativa_ia` já é exibida).
A migration **010** (ações em lote + ordenação por data) é independente e segue seu próprio fluxo.
