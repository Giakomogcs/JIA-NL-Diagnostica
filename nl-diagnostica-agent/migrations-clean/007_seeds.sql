-- =============================================
-- NL Diagnostica — 007: Seeds (admin + portais + catálogo completo)
--
-- - Cria/atualiza o admin (admin@nldiagnostica.com.br / @Admin123)
--     * a senha NÃO é sobrescrita em re-execuções (preserva rotações em prod)
-- - Seeds dos portais (Effecti, Licita Já, ComprasNet)
-- - Catálogo das linhas reais da NL Diagnóstica (fonte: nldiagnostica.com.br):
--     * Hemostasia (laboratorial)
--     * Hemostasia Point of Care (Cascade Abrazo)
--     * Eletroforese capilar (V8 / SPIFE)
--     * Parasitologia (Coproplus / Coproplus Ultra)
--     * Testes rápidos (imunocromatográficos)
--   Cada linha tem guarda própria de idempotência (WHERE NOT EXISTS por linha),
--   então re-rodar não duplica e adiciona linhas novas em bases já populadas.
-- ALERTA: troque a senha logo após o primeiro login.
-- Rode APÓS 006_licitacao_rpc.sql
-- =============================================

-- =======  UP  ========

-- ---------- portais ----------
INSERT INTO nl_portal(code, name, base_url, api_kind) VALUES
  ('EFFECTI',   'Effecti',    'https://mdw.minha.effecti.com.br/api-integracao/v1', 'effecti'),
  ('LICITAJA',  'Licita Já',  'https://www.licitaja.com.br',                        'licitaja'),
  ('COMPRASNET','ComprasNet', 'https://www.gov.br/compras',                         'comprasnet')
ON CONFLICT (code) DO UPDATE
   SET name = EXCLUDED.name, base_url = EXCLUDED.base_url, api_kind = EXCLUDED.api_kind;

-- ---------- catálogo Hemostasia laboratorial ----------
-- Idempotência por linha: só insere se a linha ainda não existir no catálogo.
INSERT INTO nl_catalogo(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca)
SELECT * FROM (VALUES
  ('produto','Hemostasia','Analisador de coagulação automatizado',
     'Diagnóstico in vitro — testes de coagulação/hemostasia em laboratório clínico',
     ARRAY['coagulação','coagulometro','coagulômetro','hemostasia','analisador de coagulação','coagulograma'],
     ARRAY['coagulometer','analyzer hemostasis'],
     'Helena Laboratories'),
  ('produto','Hemostasia','Reagente para Tempo de Protrombina (TP/PT)',
     'Determinação do tempo de protrombina (TAP/INR); monitoramento de anticoagulação oral',
     ARRAY['tempo de protrombina','protrombina','tap','inr','tromboplastina'],
     ARRAY['pt reagent','tp/inr','razao normalizada internacional'],
     'Helena Laboratories'),
  ('produto','Hemostasia','Reagente para Tempo de Tromboplastina Parcial Ativada (TTPA/APTT)',
     'Determinação do TTPA/APTT; avaliação da via intrínseca; monitoramento de heparina',
     ARRAY['ttpa','aptt','tromboplastina parcial','cefalina'],
     ARRAY['tempo de tromboplastina parcial ativada'],
     'Helena Laboratories'),
  ('produto','Hemostasia','Reagente de Fibrinogênio',
     'Dosagem de fibrinogênio plasmático (método de Clauss)',
     ARRAY['fibrinogênio','fibrinogenio','fibrinogen'],
     ARRAY['clauss'],
     'Helena Laboratories'),
  ('produto','Hemostasia','Reagente de Dímero-D',
     'Dosagem de dímero-D; auxílio diagnóstico de eventos tromboembólicos',
     ARRAY['dímero-d','dimero d','d-dimer','ddimero','d-dímero'],
     ARRAY['d dimer'],
     'Helena Laboratories'),
  ('produto','Hemostasia','Controles e calibradores de coagulação',
     'Controle de qualidade e calibração de ensaios de coagulação',
     ARRAY['controle de coagulação','calibrador de coagulação','controle normal','controle patológico','plasma controle'],
     ARRAY['quality control coagulation'],
     'Helena Laboratories'),
  ('servico','Hemostasia','Locação/comodato de equipamento de hemostasia com fornecimento de reagentes',
     'Comodato de coagulômetro com fornecimento de insumos/reagentes',
     ARRAY['comodato','locação de equipamento','locacao','cessão de equipamento','equipamento em comodato'],
     ARRAY['locação coagulômetro','sistema analitico'],
     'Helena Laboratories')
) AS v(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca)
WHERE NOT EXISTS (SELECT 1 FROM nl_catalogo WHERE linha = 'Hemostasia');

-- ---------- catálogo Hemostasia Point of Care (Cascade Abrazo) ----------
INSERT INTO nl_catalogo(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca)
SELECT * FROM (VALUES
  ('produto','Hemostasia POC','Sistema de hemostasia Point of Care (Cascade Abrazo)',
     'Coagulação à beira-leito (TLR) por química seca — realiza TP/INR, TTPa e TCA com sangue total ou citratado',
     ARRAY['point of care','poct','teste laboratorial remoto','beira leito','beira-leito','química seca','tca','tempo de coagulação ativada','coagulação portátil'],
     ARRAY['cascade','abrazo','cartão reagente','tlr','poc coagulação'],
     'Helena Laboratories'),
  ('produto','Hemostasia POC','Cartões e controles para hemostasia Point of Care',
     'Cartões reagentes (TP, TTPa, TCA) e controles normais/anormais para o sistema Point of Care',
     ARRAY['cartão reagente','cartao reagente','controle point of care','controle poct','controle eletronico'],
     ARRAY['ensaio cascade','controle abrazo'],
     'Helena Laboratories')
) AS v(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca)
WHERE NOT EXISTS (SELECT 1 FROM nl_catalogo WHERE linha = 'Hemostasia POC');

-- ---------- catálogo Eletroforese capilar (V8 / SPIFE) ----------
INSERT INTO nl_catalogo(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca)
SELECT * FROM (VALUES
  ('produto','Eletroforese','Sistema de eletroforese capilar automatizado (V8)',
     'Eletroforese capilar automatizada de soro, urina e líquor; também pipetador para gel de agarose (SPIFE)',
     ARRAY['eletroforese','eletroforese capilar','eletroforese de proteínas','eletroforese de proteinas','spife','gel de agarose'],
     ARRAY['v8','capillary electrophoresis','spe'],
     'Helena Laboratories'),
  ('produto','Eletroforese','Kit eletroforese de proteínas séricas (V8 SPE)',
     'Fracionamento de proteínas séricas (proteinograma)',
     ARRAY['proteínas séricas','proteinas sericas','proteinograma','fracionamento de proteínas','eletroforese de proteínas séricas'],
     ARRAY['serum protein electrophoresis','spe'],
     'Helena Laboratories'),
  ('produto','Eletroforese','Kit eletroforese de hemoglobinas (V8 Hemoglobin IEF)',
     'Triagem de hemoglobinopatias por isoeletrofocalização',
     ARRAY['eletroforese de hemoglobina','hemoglobinopatia','hemoglobinopatias','isoeletrofocalização','hemoglobina ief','hemoglobina fetal'],
     ARRAY['hemoglobin ief','triagem de hemoglobinopatias'],
     'Helena Laboratories'),
  ('produto','Eletroforese','Kit imunofixação/imunodeslocamento (V8 ID)',
     'Imunofixação/imunodeslocamento (IgG, IgA, IgM, Kappa e Lambda) para investigação de gamopatias',
     ARRAY['imunofixação','imunofixacao','imunodeslocamento','imunossubtração','gamopatia','proteína monoclonal','componente monoclonal'],
     ARRAY['immunofixation','immunosubtraction','cadeias leves kappa lambda'],
     'Helena Laboratories')
) AS v(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca)
WHERE NOT EXISTS (SELECT 1 FROM nl_catalogo WHERE linha = 'Eletroforese');

-- ---------- catálogo Parasitologia (Coproplus / Coproplus Ultra) ----------
INSERT INTO nl_catalogo(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca)
SELECT * FROM (VALUES
  ('produto','Parasitologia','Sistema coletor e analisador parasitológico de fezes (Coproplus / Coproplus Ultra)',
     'Coleta, conservação e exame parasitológico de fezes (EPF) por sedimentação — fabricação exclusiva NL Diagnóstica',
     ARRAY['parasitológico de fezes','parasitologico de fezes','exame parasitológico','protoparasitológico','protoparasitologico','coproparasitológico','coproparasitologico','coletor de fezes','frasco coletor de fezes'],
     ARRAY['coproplus','epf','pesquisa de parasitas','ovos e cistos','parasitas intestinais','método de sedimentação','hoffman'],
     'NL Diagnóstica')
) AS v(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca)
WHERE NOT EXISTS (SELECT 1 FROM nl_catalogo WHERE linha = 'Parasitologia');

-- ---------- catálogo Testes rápidos (imunocromatográficos) ----------
INSERT INTO nl_catalogo(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca)
SELECT * FROM (VALUES
  ('produto','Testes rápidos','Teste rápido sorológico COVID-19 (Cellex qSARS-CoV-2 IgG/IgM)',
     'Teste rápido imunocromatográfico para detecção qualitativa de anticorpos IgG/IgM anti-SARS-CoV-2',
     ARRAY['sars-cov-2','sars cov 2','covid-19','covid 19','anticorpo igg/igm','teste rápido covid'],
     ARRAY['cellex','qsars-cov-2','teste rapido coronavirus'],
     'Cellex')
) AS v(tipo, linha, descricao, finalidade, palavras_chave, sinonimos, marca)
WHERE NOT EXISTS (SELECT 1 FROM nl_catalogo WHERE linha = 'Testes rápidos');

-- ---------- admin bootstrap ----------
DO $$
DECLARE
  v_email     TEXT := 'admin@nldiagnostica.com.br';
  v_password  TEXT := '@Admin123';
  v_user_id   UUID;
  v_meta      JSONB := '{"role":"admin","company_name":"nldiagnostica","full_name":"Administrador NL Diagnostica"}'::jsonb;
BEGIN
  SELECT id INTO v_user_id FROM auth.users WHERE email = v_email LIMIT 1;

  IF v_user_id IS NULL THEN
    v_user_id := gen_random_uuid();
    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token
    ) VALUES (
      '00000000-0000-0000-0000-000000000000',
      v_user_id, 'authenticated', 'authenticated', v_email,
      crypt(v_password, gen_salt('bf')),
      NOW(),
      jsonb_build_object('provider','email','providers',ARRAY['email']),
      v_meta, NOW(), NOW(), '', '', '', ''
    );
    INSERT INTO auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    ) VALUES (
      gen_random_uuid(), v_user_id, v_user_id::text,
      jsonb_build_object('sub', v_user_id::text, 'email', v_email, 'email_verified', true),
      'email', NOW(), NOW(), NOW()
    );
    RAISE NOTICE 'NL Diagnostica bootstrap admin criado: %', v_email;
  ELSE
    UPDATE auth.users
       SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || v_meta,
           updated_at = NOW()
     WHERE id = v_user_id;
    RAISE NOTICE 'NL Diagnostica bootstrap admin já existe, metadata atualizada: %', v_email;
  END IF;
END
$$;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DELETE FROM auth.identities WHERE user_id IN (SELECT id FROM auth.users WHERE email='admin@nldiagnostica.com.br');
-- DELETE FROM auth.users WHERE email='admin@nldiagnostica.com.br';
-- DELETE FROM nl_catalogo WHERE linha IN ('Hemostasia','Hemostasia POC','Eletroforese','Parasitologia','Testes rápidos');
-- DELETE FROM nl_portal WHERE code IN ('EFFECTI','LICITAJA','COMPRASNET');
-- NOTIFY pgrst, 'reload schema';
