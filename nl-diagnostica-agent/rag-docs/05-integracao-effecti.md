# Integração Effecti — Campos, status e sincronização

**file_id:** EFFECTI-INTEGRACAO-01
**Finalidade:** ajudar o agente a interpretar os dados vindos da Effecti e o efeito de aceitar/recusar.

## Origem dos editais

Os editais chegam pela **API da Effecti** (base `https://mdw.minha.effecti.com.br/api-integracao/v1`). O workflow de ingestão busca por período, faz **dedupe** (pelo `idLicitacao` da Effecti e por hash) e roda o **match** com o catálogo. Também há suporte planejado para **Licita Já** e **ComprasNet**.

## Campos principais de uma licitação (Effecti → nosso modelo)

| Effecti                    | Nosso campo                 | Significado                                                         |
| -------------------------- | --------------------------- | ------------------------------------------------------------------- |
| `idLicitacao`              | `id_licitacao`              | ID único na Effecti (usado para favoritar/descartar e dedupe)       |
| `processo`                 | `numero_edital`             | Número/processo do edital                                           |
| `orgao`                    | `orgao`                     | Órgão comprador                                                     |
| `uf`                       | `uf`                        | Estado (logística)                                                  |
| `portal`                   | `portal_nome`               | Portal de origem (ComprasNet, BLL, etc.)                            |
| `modalidade`               | `modalidade`                | Pregão, dispensa, etc.                                              |
| `objeto` / `objetoSemTags` | `objeto`                    | Descrição do objeto (preferir `objetoSemTags`, já sem HTML)         |
| `dataPublicacao`           | `data_publicacao`           | Quando foi publicado                                                |
| `dataFinalProposta`        | `data_abertura`             | Data/limite da licitação                                            |
| `valorTotalEstimado`       | `valor_total_estimado`      | Valor de referência                                                 |
| `url`                      | `url_edital` / `url_portal` | Link do edital/portal                                               |
| `palavraEncontrada`        | `palavras_encontradas`      | Palavras que dispararam o aviso                                     |
| `itensEdital[]`            | `nl_edital_item`            | Itens (lote, item, `produtoLicitadoSemTags`, qtd, unidade, valores) |

## Status no painel

- `novo` — recém-ingerido, ainda não decidido.
- `analisando` — match parcial, requer revisão.
- `sugerido_aceitar` / `sugerido_recusar` — sugestão automática do match.
- `aceito` / `recusado` — decisão registrada.

## Efeito de aceitar/recusar (sincronização)

- **Aceitar** → favoritar na Effecti (`PUT /aviso/favoritar-licitacao`, body `{idLicitacao:[id]}`).
- **Recusar** → descartar com motivo na Effecti (`PUT /aviso/descartar-licitacao-motivo`), informando um **motivo** padronizado e uma descrição.
- Após a sincronização, o edital é marcado como `sincronizado_effecti = true`.

## Motivos de descarte aceitos pela Effecti

`FALTA_CAPACIDADE_TECNICA`, `LOCALIDADE_ENTREGA`, `VALOR_ESTIMADO_BAIXO`, `DOCUMENTACAO_INSUFICIENTE`, `PRAZO_ENTREGA_CURTO`, `OUTROS`.

## O que o agente deve lembrar

- O `id_licitacao` é a chave para refletir a decisão na Effecti — sempre presente em editais vindos de lá.
- "Favoritar" = manifestar interesse/aceite; "descartar" = recusar. As duas ações são registradas no histórico de aprendizado.
