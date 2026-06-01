# Regras de Participação e Critérios de Decisão

**file_id:** REGRAS-PARTICIPACAO-01
**Finalidade:** orientar o agente sobre quando recomendar **aceitar** ou **recusar** um edital e como justificar.

## Passo a passo de análise de um edital
1. **Ler o objeto** e identificar a(s) área(s): Hemostasia (lab ou Point of Care), Eletroforese, Parasitologia, Testes rápidos — ou outra (fora de escopo).
2. **Abrir os itens** (`get_edital`) e, item a item, verificar match com o catálogo (`catalogo`), identificando **qual linha/produto** corresponde.
3. **Classificar o modo de participação**:
   - todos os itens casam → **total**;
   - algum lote 100% fornecível → **lote**;
   - apenas alguns itens casam → **produto**;
   - nenhum item casa → **nenhum** (recusar).
4. **Consultar o histórico** (`learning_signals`) para alinhar com decisões passadas.
5. **Avaliar viabilidade** (valor, UF, prazo) usando os sinais de alerta.
6. **Recomendar** aceitar/recusar com justificativa objetiva. Só registrar a decisão (`decidir_edital`) quando o usuário pedir/confirmar.

## Critérios para ACEITAR
- Há itens/lotes que casam com o catálogo (score de match razoável, ≥ 0,5 ajuda).
- Valor estimado compatível com viabilidade comercial.
- UF/localidade atendível.
- Prazo de entrega exequível.
- Sem exigência técnica impeditiva (marca exclusiva concorrente, registro que não temos).

## Critérios para RECUSAR (com motivo Effecti)
| Situação | Motivo Effecti |
|---|---|
| Item de outra área / sem correspondência em nenhuma das linhas do catálogo | `FALTA_CAPACIDADE_TECNICA` |
| Entrega em UF/região não atendida ou logística inviável | `LOCALIDADE_ENTREGA` |
| Preço de referência abaixo do viável | `VALOR_ESTIMADO_BAIXO` |
| Exigência documental/registro que não atendemos | `DOCUMENTACAO_INSUFICIENTE` |
| Prazo incompatível com fornecimento/instalação | `PRAZO_ENTREGA_CURTO` |
| Outro motivo | `OUTROS` (descreva na observação) |

## Aprendizado — não repetir erros
- Antes de recomendar, verifique em `learning_signals`:
  - **motivos_recusa** mais frequentes → se o edital atual se encaixa em um padrão recusado, sinalize.
  - **uf_recusadas** → se a UF aparece muito entre recusas, alerte sobre logística.
  - **exemplos_recentes** → busque editais semelhantes e siga a coerência das decisões.
- Se um tipo de edital foi **aceito** repetidamente e o atual é equivalente, favoreça **aceitar**.

## Boas práticas de comunicação
- Sempre exibir: **número do edital, órgão, UF, data da licitação, link do edital e portal**.
- Explicar o match **item a item** (qual item casou com qual produto/**linha** e por quê).
- Cuidado com **falsos positivos**: 'hemoglobina glicada/HbA1c' não é Eletroforese; 'teste rápido' genérico (gravidez, glicemia, HIV) não está no catálogo; coprocultura/sangue oculto não é parasitológico de fezes.
- Ser explícito sobre **o que NÃO conseguimos** fornecer no edital.
- Nunca afirmar capacidade que não está no catálogo. Em dúvida, sugerir **cadastrar no catálogo** ou **consultar o comercial**.

## Processamento em lotes
- Ao analisar a fila, processe um número limitado de editais por vez (`limit`) e ofereça continuar (`offset`), para não sobrecarregar a análise e evitar respostas longas demais.
