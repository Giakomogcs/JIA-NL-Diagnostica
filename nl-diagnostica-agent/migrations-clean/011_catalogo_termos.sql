-- =============================================
-- NL Diagnostica — 011: Termos fortes/fracos + negativos (precisão do match)
--
-- Contexto: auditoria 2026-06 mostrou ~36% de falsos positivos no
-- "sugerido_aceitar" por palavras-chave genéricas (coagulação, comodato,
-- reagentes, controle, teste) casando medicamentos, insumos cirúrgicos e
-- comodatos de glicemia. Ver Docs/PRD-precisao-busca-editais.md.
--
-- Esta migration:
--   1. Adiciona nl_catalogo.termos_fortes (decidem participação).
--      As colunas palavras_chave/sinonimos passam a ser "termos fracos"
--      (apoio — não bastam sozinhos no match v2).
--   2. Cria nl_match_negativo (termos de bloqueio globais — outras áreas).
--   3. Popula termos_fortes por linha e os negativos.
--
-- Rode APÓS 007_seeds.sql e ANTES de 012_match_v2.sql.
-- =============================================

-- =======  UP  ========

-- ---------- coluna de termos fortes ----------
ALTER TABLE nl_catalogo
  ADD COLUMN IF NOT EXISTS termos_fortes TEXT[] NOT NULL DEFAULT '{}';

-- ---------- termos de bloqueio (negativos) globais ----------
CREATE TABLE IF NOT EXISTS nl_match_negativo (
  termo      TEXT PRIMARY KEY,
  motivo     TEXT,
  ativo      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE nl_match_negativo ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS nl_match_negativo_sel ON nl_match_negativo;
CREATE POLICY nl_match_negativo_sel ON nl_match_negativo
  FOR SELECT USING (nl_is_member() OR nl_is_backend());

INSERT INTO nl_match_negativo(termo, motivo) VALUES
  ('esponja',            'insumo cirúrgico (hemostasia cirúrgica), não laboratorial'),
  ('pinça',              'instrumental cirúrgico'),
  ('pinca',              'instrumental cirúrgico'),
  ('cateter',            'material cirúrgico/intervencionista'),
  ('bisturi',            'instrumental cirúrgico'),
  ('glicemia',           'tira/monitor de glicemia — fora do escopo NL'),
  ('glicose',            'dosagem de glicose — fora do escopo NL'),
  ('hgt',                'teste de glicemia capilar (HGT)'),
  ('vitamina k',         'medicamento'),
  ('fator vii',          'medicamento (concentrado de fator)'),
  ('fator de coagulação','medicamento (concentrado de fator)'),
  ('exodontia',          'procedimento odontológico'),
  ('anestésico',         'medicamento'),
  ('anestesico',         'medicamento'),
  ('óbito',              'saco para óbito / body bag'),
  ('obito',              'saco para óbito / body bag'),
  ('body bag',           'saco para óbito'),
  ('hemogasômetro',      'gasometria — fora do escopo NL'),
  ('hemogasometro',      'gasometria — fora do escopo NL'),
  ('gasometria',         'gasometria — fora do escopo NL'),
  ('gases sanguíneos',   'gasometria — fora do escopo NL'),
  ('gases sanguineos',   'gasometria — fora do escopo NL'),
  ('indicador biológico','controle de esterilização'),
  ('indicador biologico','controle de esterilização'),
  ('esterilização',      'controle de esterilização'),
  ('esterilizacao',      'controle de esterilização'),
  ('primer',             'insumo de biologia molecular (PCR)'),
  ('oligonucleotídeo',   'insumo de biologia molecular (PCR)'),
  ('oligonucleotideo',   'insumo de biologia molecular (PCR)'),
  ('desinfetante',       'saneante/limpeza'),
  ('veterinário',        'uso veterinário'),
  ('veterinario',        'uso veterinário')
ON CONFLICT (termo) DO NOTHING;

-- ---------- popular termos_fortes por linha ----------
-- Hemostasia laboratorial
UPDATE nl_catalogo SET termos_fortes = ARRAY[
  'tempo de protrombina','protrombina','tap','inr','ttpa','aptt',
  'tromboplastina parcial','tromboplastina','fibrinogênio','fibrinogenio',
  'dímero-d','dimero-d','d-dímero','coagulograma','coagulômetro','coagulometro'
] WHERE linha = 'Hemostasia';

-- Hemostasia Point of Care
UPDATE nl_catalogo SET termos_fortes = ARRAY[
  'coaguchek','cascade','abrazo','tca','tempo de coagulação ativada',
  'tempo de coagulacao ativada','point of care','poct'
] WHERE linha = 'Hemostasia POC';

-- Eletroforese
UPDATE nl_catalogo SET termos_fortes = ARRAY[
  'eletroforese de proteínas','eletroforese de proteinas','eletroforese capilar',
  'proteinograma','imunofixação','imunofixacao','hemoglobinopatia','hemoglobinopatias',
  'isoeletrofocalização','isoeletrofocalizacao','eletroforese de hemoglobina'
] WHERE linha = 'Eletroforese';

-- Parasitologia
UPDATE nl_catalogo SET termos_fortes = ARRAY[
  'parasitológico de fezes','parasitologico de fezes','coproparasitológico',
  'coproparasitologico','protoparasitológico','protoparasitologico','coproplus',
  'epf','exame parasitológico','exame parasitologico','coletor de fezes'
] WHERE linha = 'Parasitologia';

-- Testes rápidos
UPDATE nl_catalogo SET termos_fortes = ARRAY[
  'sars-cov-2','sars cov 2','covid-19','covid 19','imunocromatográfico',
  'imunocromatografico','antígeno sars','antigeno sars','igg/igm'
] WHERE linha = 'Testes rápidos';

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP TABLE IF EXISTS nl_match_negativo;
-- ALTER TABLE nl_catalogo DROP COLUMN IF EXISTS termos_fortes;
-- NOTIFY pgrst, 'reload schema';
