# Limitações da Plataforma — O que NÃO é possível (e por quê)

> NL Diagnóstica — Agente de Licitações
> Atualizado em: 2026-06-10
> Complementa: `PRD-precisao-busca-editais.md` e `PLANO-implementacao-match.md`

Este documento consolida tudo o que foi **verificado como não possível** (ou possível apenas com ressalvas) nas integrações Effecti, Licita Já e no nosso próprio sistema — com a explicação técnica de cada limite e, quando existe, o caminho alternativo.

---

## 1. Effecti — limitações da API de integração

A API que temos acesso (`https://mdw.minha.effecti.com.br/api-integracao/v1/`) expõe **apenas 3 endpoints**:

| Endpoint                                | O que faz                                                     |
| --------------------------------------- | ------------------------------------------------------------- |
| `POST aviso/licitacao?page=N`           | Puxa avisos de licitação por janela de datas (`{begin, end}`) |
| `POST aviso/favoritar-licitacao`        | Marca uma licitação como favorita (nosso "aceitar")           |
| `POST aviso/descartar-licitacao-motivo` | Descarta uma licitação com motivo (nosso "recusar")           |

### 1.1 ❌ Cadastrar licitações manualmente via API

**Não é possível.** Não existe endpoint de criação/inserção de licitação na API de integração. A Effecti só nos **envia** avisos que o robô deles capturou; não aceita que a gente **insira** uma licitação encontrada por fora.
**Por quê:** a API é só de _leitura + decisão_ (pull, favoritar, descartar). Qualquer cadastro manual teria que ser feito dentro do painel web da Effecti.
**Alternativa no nosso sistema:** a coluna `nl_edital.fonte` aceita o valor `'manual'` — podemos criar uma tela/RPC de cadastro manual **no nosso painel** se necessário (hoje não implementado).

### 1.2 ❌ Configurar monitoramento (perfil de captura) via API

**Não é possível.** O perfil de monitoramento — quais portais, órgãos, regiões e segmentos o robô da Effecti vasculha — é configurado **dentro do painel da conta Effecti**, não há endpoint para ler nem alterar.
**Por quê:** o monitoramento é um serviço interno da Effecti; a API de integração só entrega o resultado dele.
**Consequência prática:** o pull diário traz _tudo_ que o perfil da conta captura nas últimas 24h. Se vier muito lixo (ou faltar coisa), o ajuste é no painel da Effecti — não no nosso código.

### 1.3 ❌ Configurar palavras-chave / palavras indesejadas via API da Effecti

**Não é possível.** Igual ao item anterior: as palavras-chave e exclusões do robô de captura ficam no perfil da conta, sem endpoint de configuração.
**Alternativa implementada (nosso lado):** o filtro fino é feito **no nosso sistema**:

- **Termos fortes** por linha do catálogo (decidem se o item participa);
- **Palavras indesejadas** (`nl_match_negativo`) — bloqueio global, gerenciável na aba Catálogo (ex.: "maçã", "vinagre", "glicemia", "veterinário").
  Ou seja: a Effecti faz a captura grossa; a precisão é nossa.

### 1.4 ❌ Saber/controlar os horários de captura da Effecti

**Não é possível via API.** Não há endpoint que informe quando o robô da Effecti roda nem como alterar a frequência.
**O que controlamos:** apenas o **nosso pull** (cron 07h, janela de 24h, + botão manual). Se um edital for capturado pela Effecti às 18h, só entra no nosso painel no pull seguinte (ou num pull manual).

### 1.5 ❌ Receber o conteúdo completo do edital pela Effecti

**Não é possível.** O payload entrega metadados, `objeto`, `itensEdital[]` (produto, quantidade, unidade, valores) e **links** (`url_edital`, portal). O **documento do edital (PDF)** em si não vem no corpo da resposta.
**Por quê:** a Effecti repassa o aviso estruturado, não o arquivo.
**Alternativa implementada:** a **Super Triagem** (`nldiag-super-triagem`) baixa o PDF pelo `url_edital`, extrai o texto (com OCR) e analisa com IA — ver seção 4.

### 1.6 ❌ Push/webhook da Effecti para nós

**Não disponível.** A integração é _pull_ (nós perguntamos); a Effecti não nos notifica quando chega edital novo. Por isso existe o cron + botão manual.

---

## 2. Licita Já — limitações da API

API: `https://www.licitaja.com.br/api/v1` (header `X-API-KEY`, gerada em `licitaja.com.br/api_integration.php`).

### 2.1 ⚠️ Limites de uso rígidos

- **10 requisições por minuto** — por isso nosso workflow pagina com no máximo 6 páginas por execução;
- **Limite diário dinâmico** (a API pode recusar com base no plano/uso);
- **Máximo 25 resultados por página**;
- **Mesmo IP**: a chave fica vinculada ao IP que a usa — se o n8n mudar de IP (troca de servidor/proxy), a chave pode parar de funcionar e precisa ser regenerada.

### 2.2 ❌ Itens detalhados com quantidade e valores

**Não é possível.** O Licita Já entrega `lots[]` com apenas `lot_number` e `lot_object` (texto do lote). **Não há quantidade, unidade, valor unitário nem valor total por item** — diferente da Effecti.
**Consequência:** para editais do Licita Já, o match roda só sobre o **texto** do lote/objeto, e o painel mostra qtd/valores vazios nos itens. A Super Triagem (PDF) compensa parcialmente, pois o PDF contém os itens completos.

### 2.3 ⚠️ Filtros condicionados à data de catálogo

O parâmetro `date` (YYYYmmdd) define o "dia de catálogo" e **condiciona os demais filtros** — buscas históricas amplas não são práticas. A API foi desenhada para consumo diário do catálogo do dia.

### 2.4 ⚠️ Configuração de palavras-chave: na conta, não na API

Se `keyword`/`state` forem enviados vazios, a API usa o **perfil salvo na conta Licita Já**. Dá para passar keywords na chamada (vírgula-separadas), mas a manutenção "oficial" do perfil é no painel deles — análogo à Effecti.

### 2.5 ❌ Deduplicação perfeita entre fontes

**Não garantido.** A mesma licitação pode chegar pela Effecti **e** pelo Licita Já com identificadores e grafias diferentes (número do edital formatado diferente, órgão abreviado etc.). Nosso dedupe usa `id_licitaja`/`dedupe_hash` por fonte — **não cruza fontes**.
**Por quê:** não existe chave universal confiável entre os dois provedores (o número PNCP até existe no Licita Já em `number2`, mas a Effecti nem sempre traz equivalente).
**Consequência:** pode aparecer o mesmo edital duplicado (um badge azul, um roxo). Aceito na v1; mitigável no futuro cruzando PNCP/CNPJ+número quando ambos existirem.

---

## 3. Nosso match automático — limitações por desenho

### 3.1 ❌ O match NÃO usa as bulas/RAG diretamente

O `nl_match_edital` cruza os itens do edital **somente com o catálogo** (termos fortes, palavras de apoio, negativos). As bulas no RAG alimentam o **assistente de chat** e a **Super Triagem**, não o score automático.
**Por quê:** busca vetorial em todos os itens de todos os editais a cada ingestão seria lenta e cara, e geraria falsos positivos difíceis de explicar. O caminho escolhido foi destilar as bulas em **termos fortes** (botão "✨ Termos das bulas"), que o match usa de forma rápida, barata e auditável.

### 3.2 ⚠️ Match é textual, não semântico

"Coagulômetro" só casa se o termo (ou sinônimo cadastrado) existir no texto do item. Erros de digitação graves no edital ("coagulometro" sem acento está coberto; "coagulmetro" não) escapam.
**Mitigação:** cadastrar variações como sinônimos; a Super Triagem com IA cobre o caso semântico.

### 3.3 ⚠️ Edital sem itens → análise limitada

Quando a fonte não manda itens (acontece em ambas), o match cai no _fallback_ pelo `objeto` — menos preciso. A Super Triagem é o complemento indicado nesses casos.

---

## 4. Super Triagem — limitações conhecidas

### 4.1 ⚠️ Depende do `url_edital` ser um link direto e público

**Nem sempre funciona.** Muitos portais (ComprasNet, BLL, portais municipais):

- exigem **login/captcha** para baixar o edital;
- entregam uma **página HTML** em vez do PDF;
- usam links que **expiram**.

Nesses casos o download falha ou não retorna PDF. O workflow detecta isso (checa assinatura `%PDF`) e **degrada graciosamente**: analisa só com objeto+itens e declara a limitação no campo "riscos".
**Por quê não contornamos:** automatizar login/captcha em portais de terceiros é frágil e juridicamente questionável.

### 4.2 ⚠️ Limites de tamanho

- PDF acima de **20 MB** não vai para OCR (custo/timeout do modelo);
- Texto extraído é truncado em **60.000 caracteres** antes da análise (janela de contexto do LLM). Editais gigantes podem ter anexos finais fora da análise.

### 4.3 ⚠️ É análise por IA — não parecer jurídico

A recomendação, exigências e riscos vêm de um LLM (gpt-4o-mini) lendo o texto. Pode errar ou omitir. O resultado guarda a `confianca` e a fonte (`pdf` vs `itens`) justamente para o humano calibrar a revisão. **A decisão final é sempre humana.**

### 4.4 ✅ (Por desenho) O texto do PDF não é persistido

O conteúdo do edital é usado **somente em memória durante a análise** e descartado — só o resultado estruturado (`analise_profunda` JSONB) é salvo. Isso é intencional (pedido do usuário): evita inflar o RAG com milhares de editais transitórios.

### 4.5 ⚠️ Execução manual, edital por edital

A Super Triagem roda sob demanda (botão no modal do edital), não em lote automático.
**Por quê:** cada análise custa download + OCR eventual + chamada de LLM (~1-2 min e custo de tokens). Rodar em todos os ~350 editais a cada pull seria caro e lento. Se quiser, dá para automatizar **só para os `sugerido_aceitar`** (fila com rate limit) — não implementado.

---

## 5. Semeadura do catálogo via bulas — limitações

### 5.1 ⚠️ Depende das bulas estarem no RAG

O botão "✨ Termos das bulas" lê os documentos **já enviados** na aba Documentos. Bula que não foi enviada não contribui.

### 5.2 ⚠️ Usa amostra de cada documento, não o texto integral

Para caber na janela do LLM, são usados os **primeiros ~5 chunks** de cada documento (≈2.600 caracteres por bula). Para bulas, isso cobre nome do produto, finalidade e metodologia (onde estão os termos úteis) — mas seções finais muito longas não são lidas.

### 5.3 ✅ (Por desenho) Nunca remove termos

O merge é só aditivo: termos existentes nunca são apagados nem sobrescritos. Limpeza de termo ruim é manual (editar a linha do catálogo).
**Por quê:** evita que uma execução ruim do LLM destrua a curadoria humana já feita.

### 5.4 ⚠️ O LLM pode sugerir termos imperfeitos

Apesar das regras anti-genéricos no prompt (proíbe "reagente", "kit", "teste", nomes de doenças isolados...), pode escapar termo amplo demais. Como termo forte **decide** participação, um termo ruim gera falsos positivos.
**Mitigação:** revisar a coluna "Termos fortes" após semear e remover o que for genérico; depois "↻ Reprocessar análises".

---

## 6. Infraestrutura — limites operacionais

| Limite                        | Detalhe                                                                                   | Por quê                                                                                  |
| ----------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Reprocesso em lotes de 40     | `nl_rematch_all(p_limit=40)` em loop                                                      | _Statement timeout_ do Supabase em transações longas (~350 editais de uma vez estourava) |
| Front servido por webhook     | Sessão Supabase exige polyfill de `navigator.locks`                                       | Origin `null` no iframe/webhook do n8n quebra o lock da lib de auth                      |
| Sem push em tempo real        | Painel atualiza ao navegar/clicar                                                         | n8n + Supabase REST; não há canal realtime configurado                                   |
| X-API-KEY do Licita Já manual | Placeholder no workflow precisa ser substituído ao importar                               | A chave é secreta e vinculada à conta/IP — não versionamos credencial no JSON            |
| OCR com placeholders          | `REPLACE_ME_AZURE_OCR_URL` / `REPLACE_ME_OCR_DEPLOYMENT` nos workflows RAG e Inteligência | Mesma razão: deployment/URL do Azure são da conta, não do repositório                    |

---

## 7. Resumo executivo

| Desejo                                        | Possível?           | Caminho                                                         |
| --------------------------------------------- | ------------------- | --------------------------------------------------------------- |
| Cadastrar licitação na Effecti via API        | ❌                  | Painel Effecti; ou cadastro `manual` no nosso sistema (futuro)  |
| Configurar monitoramento da Effecti via API   | ❌                  | Painel da conta Effecti                                         |
| Palavras-chave/indesejadas na Effecti via API | ❌                  | Painel Effecti (captura) + **nosso Catálogo** (precisão) ✅     |
| Receber PDF do edital pelas APIs              | ❌                  | **Super Triagem** baixa pelo link ✅ (quando o link é público)  |
| Itens com qtd/valor no Licita Já              | ❌                  | Só texto do lote; PDF via Super Triagem compensa                |
| Dedupe entre Effecti × Licita Já              | ⚠️                  | Badge de fonte deixa visível; cruzamento PNCP é melhoria futura |
| Match automático usando bulas                 | ⚠️ indireto         | Bulas → "✨ Termos das bulas" → termos fortes → match ✅        |
| Super triagem automática em massa             | ⚠️ não implementado | Sob demanda por edital; automatizável p/ sugeridos se desejado  |
