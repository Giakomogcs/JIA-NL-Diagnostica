-- =============================================
-- NL Diagnostica — 007: Seeds (admin + portais + catálogo Hemostasia)
--
-- - Cria/atualiza o admin (admin@nldiagnostica.com.br / @Admin123)
--     * a senha NÃO é sobrescrita em re-execuções (preserva rotações em prod)
-- - Seeds dos portais (Effecti, Licita Já, ComprasNet)
-- - Catálogo inicial da linha Hemostasia (ajuste/expanda conforme a empresa)
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

-- ---------- catálogo Hemostasia (exemplos — refine com o catálogo real) ----------
-- Idempotência simples: só insere se a tabela ainda não tiver itens da linha.
INSERT INTO nl_catalogo(tipo, linha, descricao, finalidade, palavras_chave, sinonimos)
SELECT * FROM (VALUES
  ('produto','Hemostasia','Analisador de coagulação automatizado',
     'Diagnóstico in vitro — testes de coagulação/hemostasia em laboratório clínico',
     ARRAY['coagulação','coagulometro','coagulômetro','hemostasia','analisador de coagulação'],
     ARRAY['coagulometer','analyzer hemostasis']),
  ('produto','Hemostasia','Reagente para Tempo de Protrombina (TP/PT)',
     'Determinação do tempo de protrombina (TAP/INR)',
     ARRAY['tempo de protrombina','protrombina','tap','inr','pt reagent'],
     ARRAY['tromboplastina']),
  ('produto','Hemostasia','Reagente para Tempo de Tromboplastina Parcial Ativada (TTPA/APTT)',
     'Determinação do TTPA/APTT',
     ARRAY['ttpa','aptt','tromboplastina parcial','cefalina'],
     ARRAY['tempo de tromboplastina']),
  ('produto','Hemostasia','Reagente de Fibrinogênio',
     'Dosagem de fibrinogênio plasmático',
     ARRAY['fibrinogênio','fibrinogenio','fibrinogen'],
     ARRAY['clauss']),
  ('produto','Hemostasia','Reagente de Dímero-D',
     'Dosagem de dímero-D',
     ARRAY['dímero-d','dimero d','d-dimer','ddimero'],
     ARRAY['d dimer']),
  ('produto','Hemostasia','Controles e calibradores de coagulação',
     'Controle de qualidade e calibração de ensaios de coagulação',
     ARRAY['controle de coagulação','calibrador de coagulação','controle normal','controle patológico'],
     ARRAY['quality control coagulation']),
  ('servico','Hemostasia','Locação/comodato de equipamento de hemostasia com fornecimento de reagentes',
     'Comodato de coagulômetro com fornecimento de insumos/reagentes',
     ARRAY['comodato','locação de equipamento','locacao','cessão de equipamento','equipamento em comodato'],
     ARRAY['locação coagulômetro'])
) AS v(tipo, linha, descricao, finalidade, palavras_chave, sinonimos)
WHERE NOT EXISTS (SELECT 1 FROM nl_catalogo WHERE linha = 'Hemostasia');

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
-- DELETE FROM nl_catalogo WHERE linha='Hemostasia';
-- DELETE FROM nl_portal WHERE code IN ('EFFECTI','LICITAJA','COMPRASNET');
-- NOTIFY pgrst, 'reload schema';
