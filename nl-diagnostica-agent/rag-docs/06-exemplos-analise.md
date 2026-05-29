# Exemplos de Análise de Editais (casos de referência)

**file_id:** EXEMPLOS-ANALISE-01
**Finalidade:** exemplos resolvidos para o agente calibrar o raciocínio de match e decisão.

## Exemplo 1 — Aceitar por produto (match parcial)
**Objeto:** "Aquisição de reagentes para laboratório de análises clínicas."
**Itens:**
1. Reagente para Tempo de Protrombina (TP/INR) — 5.000 testes
2. Reagente de glicose hexoquinase — 10.000 testes
3. Reagente de Fibrinogênio (Clauss) — 2.000 testes

**Análise:** Itens 1 e 3 casam com a linha Hemostasia (TP e Fibrinogênio). Item 2 é bioquímica → fora de escopo.
**Modo:** produto. **Recomendação:** **Aceitar**, cotando apenas os itens 1 e 3.

## Exemplo 2 — Aceitar lote completo (comodato)
**Objeto:** "Contratação de empresa para fornecimento de reagentes de coagulação com cessão de equipamento (coagulômetro) em regime de comodato."
**Itens (Lote 1):** TP, TTPA, Fibrinogênio, Dímero-D, controles + 1 coagulômetro em comodato.

**Análise:** Todos os itens casam com a linha Hemostasia, e o comodato é serviço do catálogo. Lote 100% fornecível.
**Modo:** lote (total se for o único lote). **Recomendação:** **Aceitar** o lote inteiro.

## Exemplo 3 — Recusar por falta de capacidade técnica
**Objeto:** "Aquisição de analisador hematológico (hemograma) com reagentes."
**Itens:** Contador hematológico, diluentes, lise, controles de hematologia.

**Análise:** Hematologia celular (hemograma) não pertence à linha Hemostasia e não há item correspondente no catálogo.
**Modo:** nenhum. **Recomendação:** **Recusar** — `FALTA_CAPACIDADE_TECNICA`.

## Exemplo 4 — Recusar por localidade
**Objeto:** "Reagentes de coagulação para Secretaria de Saúde do Amazonas — entrega em Tabatinga/AM."
**Análise:** Itens casam com o catálogo (TP, TTPA), mas a logística para Tabatinga/AM é inviável; o histórico mostra recusas recorrentes em AM por logística.
**Recomendação:** **Recusar** — `LOCALIDADE_ENTREGA` (confirme com o comercial se houver mudança de cobertura).

## Exemplo 5 — Lote parcial → participar por item, não por lote
**Objeto:** "Lote único: TP, TTPA e reagente de urinálise (tiras)."
**Análise:** TP e TTPA casam; urinálise não. Como o lote exige **todos** os itens, o lote **não** é fornecível integralmente.
**Recomendação:** Se o edital permitir item isolado, participar por **produto** (TP, TTPA). Se for lote fechado, **recusar** o lote (`OUTROS` — não atendemos um dos itens do lote fechado).

## Exemplo 6 — Valor inviável
**Objeto:** "Reagente de Dímero-D — 1.000 testes. Valor de referência R$ 1,20/teste."
**Análise:** Item casa, mas o valor de referência está abaixo do custo viável.
**Recomendação:** **Recusar** — `VALOR_ESTIMADO_BAIXO` (ou revisar com o comercial).

## Padrão de resposta esperado
Para cada edital citar: **nº, órgão, UF, data da licitação, link**; explicar o match item a item; dizer o **modo** e a **recomendação** com o **motivo** quando recusar.
