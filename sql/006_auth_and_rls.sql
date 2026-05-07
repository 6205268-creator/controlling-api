-- =============================================================================
-- 006_auth_and_rls.sql
-- JWT авторизация + Row Level Security (изоляция организаций)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. JWT-инфраструктура: хелперы + секрет в БД
-- ---------------------------------------------------------------------------

-- Секрет хранится в конфиге БД (одинаков с postgrest.conf jwt-secret)
ALTER DATABASE controlling SET app.jwt_secret = '8AVgwi3NZhi84JVzckydqxD4EOvbl4nZm8Tbij01vCxvECMc';

-- base64url без паддинга (RFC 4648 §5)
CREATE OR REPLACE FUNCTION private.base64url_encode(p_data BYTEA)
RETURNS TEXT LANGUAGE SQL IMMUTABLE STRICT AS $$
    SELECT replace(replace(replace(
        translate(encode(p_data, 'base64'), E'\n', ''),
        '+', '-'), '/', '_'), '=', '');
$$;

-- HS256 JWT
CREATE OR REPLACE FUNCTION private.generate_jwt(p_payload JSONB)
RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
    v_secret  TEXT := current_setting('app.jwt_secret');
    v_header  TEXT := private.base64url_encode(convert_to('{"alg":"HS256","typ":"JWT"}', 'UTF8'));
    v_payload TEXT := private.base64url_encode(convert_to(p_payload::text, 'UTF8'));
    v_input   TEXT := v_header || '.' || v_payload;
BEGIN
    RETURN v_input || '.' || private.base64url_encode(hmac(v_input, v_secret, 'sha256'));
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. api.login — единственный публичный endpoint (доступен anon)
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.login(text, text);

CREATE OR REPLACE FUNCTION api.login(p_login TEXT, p_password TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_user  private.users;
    v_exp   BIGINT;
BEGIN
    SELECT * INTO v_user
    FROM private.users
    WHERE login = p_login AND is_active = true;

    IF NOT FOUND OR v_user.password_hash <> crypt(p_password, v_user.password_hash) THEN
        RAISE EXCEPTION 'invalid credentials' USING ERRCODE = '28P01';
    END IF;

    -- Токен живёт 8 часов
    v_exp := extract(epoch FROM now() + interval '8 hours')::bigint;

    RETURN jsonb_build_object(
        'token',           private.generate_jwt(jsonb_build_object(
                               'role',            'authenticated',
                               'organization_id', v_user.organization_id,
                               'user_id',         v_user.id,
                               'user_role',       v_user.role,
                               'exp',             v_exp
                           )),
        'expires_at',      to_timestamp(v_exp),
        'user_id',         v_user.id,
        'organization_id', v_user.organization_id,
        'user_role',       v_user.role
    );
END;
$$;

-- Функция текущего пользователя (нужен токен)
DROP FUNCTION IF EXISTS api.me();

CREATE OR REPLACE FUNCTION api.me()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
    v_claims JSONB := current_setting('request.jwt.claims', true)::jsonb;
    v_user   private.users;
BEGIN
    SELECT * INTO v_user
    FROM private.users
    WHERE id = (v_claims->>'user_id')::uuid AND is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'user not found' USING ERRCODE = '28P01';
    END IF;

    RETURN jsonb_build_object(
        'user_id',         v_user.id,
        'login',           v_user.login,
        'full_name',       v_user.full_name,
        'role',            v_user.role,
        'organization_id', v_user.organization_id
    );
END;
$$;

-- Создание пользователя (только для admin)
DROP FUNCTION IF EXISTS api.create_user(text, text, text, text, uuid);

CREATE OR REPLACE FUNCTION api.create_user(
    p_login     TEXT,
    p_password  TEXT,
    p_full_name TEXT,
    p_role      TEXT DEFAULT 'member',
    p_org_id    UUID DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_claims   JSONB := current_setting('request.jwt.claims', true)::jsonb;
    v_caller_role TEXT := v_claims->>'user_role';
    v_org_id   UUID;
    v_new_id   UUID;
BEGIN
    IF v_caller_role <> 'admin' THEN
        RAISE EXCEPTION 'only admin can create users' USING ERRCODE = '42501';
    END IF;

    -- Пользователь создаётся в своей организации (нельзя создать в чужой)
    v_org_id := (v_claims->>'organization_id')::uuid;

    INSERT INTO private.users (login, password_hash, full_name, role, organization_id)
    VALUES (p_login, crypt(p_password, gen_salt('bf', 10)), p_full_name, p_role, v_org_id)
    RETURNING id INTO v_new_id;

    RETURN jsonb_build_object('user_id', v_new_id, 'login', p_login, 'role', p_role);
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Вспомогательная функция: извлечь organization_id из JWT (или ошибка)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.current_org_id()
RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
    v_claims JSONB;
    v_org_id UUID;
BEGIN
    v_claims := current_setting('request.jwt.claims', true)::jsonb;
    v_org_id := (v_claims->>'organization_id')::uuid;
    IF v_org_id IS NULL THEN
        RAISE EXCEPTION 'missing organization_id in token' USING ERRCODE = '28P01';
    END IF;
    RETURN v_org_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Row Level Security — таблицы с прямым organization_id
-- ---------------------------------------------------------------------------

-- Организации: видишь только свою
ALTER TABLE private.organizations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.organizations;
CREATE POLICY org_isolation ON private.organizations
    USING (id = private.current_org_id());

-- Справочники
ALTER TABLE private.contractors ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.contractors;
CREATE POLICY org_isolation ON private.contractors
    USING (organization_id = private.current_org_id());

ALTER TABLE private.members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.members;
CREATE POLICY org_isolation ON private.members
    USING (organization_id = private.current_org_id());

ALTER TABLE private.plots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.plots;
CREATE POLICY org_isolation ON private.plots
    USING (organization_id = private.current_org_id());

ALTER TABLE private.meters ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.meters;
CREATE POLICY org_isolation ON private.meters
    USING (organization_id = private.current_org_id());

ALTER TABLE private.contribution_types ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.contribution_types;
CREATE POLICY org_isolation ON private.contribution_types
    USING (organization_id = private.current_org_id());

ALTER TABLE private.tariffs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.tariffs;
CREATE POLICY org_isolation ON private.tariffs
    USING (organization_id = private.current_org_id());

ALTER TABLE private.period_locks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.period_locks;
CREATE POLICY org_isolation ON private.period_locks
    USING (organization_id = private.current_org_id());

ALTER TABLE private.financial_object_registry ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.financial_object_registry;
CREATE POLICY org_isolation ON private.financial_object_registry
    USING (organization_id = private.current_org_id());

-- Пользователи: видишь только свою организацию
ALTER TABLE private.users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.users;
CREATE POLICY org_isolation ON private.users
    USING (organization_id = private.current_org_id());

-- Токены: только свои
ALTER TABLE private.auth_tokens ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.auth_tokens;
CREATE POLICY org_isolation ON private.auth_tokens
    USING (organization_id = private.current_org_id());

-- Документы
ALTER TABLE private.documents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.documents;
CREATE POLICY org_isolation ON private.documents
    USING (organization_id = private.current_org_id());

-- Регистры (ledger)
ALTER TABLE private.account_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.account_movements;
CREATE POLICY org_isolation ON private.account_movements
    USING (organization_id = private.current_org_id());

ALTER TABLE private.debt_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.debt_movements;
CREATE POLICY org_isolation ON private.debt_movements
    USING (organization_id = private.current_org_id());

ALTER TABLE private.meter_readings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.meter_readings;
CREATE POLICY org_isolation ON private.meter_readings
    USING (organization_id = private.current_org_id());

-- ---------------------------------------------------------------------------
-- 5. RLS — детали документов (через JOIN к documents)
-- ---------------------------------------------------------------------------

ALTER TABLE private.doc_payment ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.doc_payment;
CREATE POLICY org_isolation ON private.doc_payment
    USING (EXISTS (
        SELECT 1 FROM private.documents d
        WHERE d.id = doc_payment.document_id
          AND d.organization_id = private.current_org_id()
    ));

ALTER TABLE private.doc_distribution ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.doc_distribution;
CREATE POLICY org_isolation ON private.doc_distribution
    USING (EXISTS (
        SELECT 1 FROM private.documents d
        WHERE d.id = doc_distribution.document_id
          AND d.organization_id = private.current_org_id()
    ));

ALTER TABLE private.doc_distribution_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.doc_distribution_lines;
CREATE POLICY org_isolation ON private.doc_distribution_lines
    USING (EXISTS (
        SELECT 1 FROM private.documents d
        JOIN private.doc_distribution dd ON dd.document_id = d.id
        WHERE dd.document_id = doc_distribution_lines.document_id
          AND d.organization_id = private.current_org_id()
    ));

ALTER TABLE private.doc_accrual ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.doc_accrual;
CREATE POLICY org_isolation ON private.doc_accrual
    USING (EXISTS (
        SELECT 1 FROM private.documents d
        WHERE d.id = doc_accrual.document_id
          AND d.organization_id = private.current_org_id()
    ));

ALTER TABLE private.doc_accrual_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.doc_accrual_lines;
CREATE POLICY org_isolation ON private.doc_accrual_lines
    USING (EXISTS (
        SELECT 1 FROM private.documents d
        JOIN private.doc_accrual da ON da.document_id = d.id
        WHERE da.document_id = doc_accrual_lines.document_id
          AND d.organization_id = private.current_org_id()
    ));

ALTER TABLE private.doc_meter_reading ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.doc_meter_reading;
CREATE POLICY org_isolation ON private.doc_meter_reading
    USING (EXISTS (
        SELECT 1 FROM private.documents d
        WHERE d.id = doc_meter_reading.document_id
          AND d.organization_id = private.current_org_id()
    ));

ALTER TABLE private.doc_meter_charge ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.doc_meter_charge;
CREATE POLICY org_isolation ON private.doc_meter_charge
    USING (EXISTS (
        SELECT 1 FROM private.documents d
        WHERE d.id = doc_meter_charge.document_id
          AND d.organization_id = private.current_org_id()
    ));

ALTER TABLE private.doc_meter_correction ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.doc_meter_correction;
CREATE POLICY org_isolation ON private.doc_meter_correction
    USING (EXISTS (
        SELECT 1 FROM private.documents d
        WHERE d.id = doc_meter_correction.document_id
          AND d.organization_id = private.current_org_id()
    ));

ALTER TABLE private.doc_period_close ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.doc_period_close;
CREATE POLICY org_isolation ON private.doc_period_close
    USING (EXISTS (
        SELECT 1 FROM private.documents d
        WHERE d.id = doc_period_close.document_id
          AND d.organization_id = private.current_org_id()
    ));

-- ---------------------------------------------------------------------------
-- 6. Роль authenticated: разрешения
-- ---------------------------------------------------------------------------

DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated NOLOGIN;
    END IF;
END $$;

-- Authenticated наследует anon
GRANT anon TO authenticated;

-- Доступ к схемам
GRANT USAGE ON SCHEMA api TO authenticated;
GRANT USAGE ON SCHEMA private TO authenticated;

-- Все views в api
GRANT SELECT ON ALL TABLES IN SCHEMA api TO authenticated;

-- Все RPC-функции в api
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO authenticated;

-- Чтение private-таблиц (через RLS будут отфильтрованы)
GRANT SELECT ON ALL TABLES IN SCHEMA private TO authenticated;

-- Запись в private-таблицы нужна SECURITY DEFINER функциям,
-- которые работают от имени postgres — не нужна для authenticated напрямую.

-- ---------------------------------------------------------------------------
-- 7. anon: только login и health — всё остальное запрещено
-- ---------------------------------------------------------------------------

-- Отозвать SELECT у anon со всех view (кроме enum-ов)
REVOKE SELECT ON api.contractors FROM anon;
REVOKE SELECT ON api.members FROM anon;
REVOKE SELECT ON api.plots FROM anon;
REVOKE SELECT ON api.meters FROM anon;
REVOKE SELECT ON api.documents FROM anon;
REVOKE SELECT ON api.doc_journal FROM anon;
REVOKE SELECT ON api.debtors FROM anon;
REVOKE SELECT ON api.account_statement FROM anon;
REVOKE SELECT ON api.account_balances FROM anon;
REVOKE SELECT ON api.debt_movements_detail FROM anon;
REVOKE SELECT ON api.object_debts FROM anon;
REVOKE SELECT ON api.plot_summary FROM anon;
REVOKE SELECT ON api.tariffs FROM anon;
REVOKE SELECT ON api.meter_readings_view FROM anon;
REVOKE SELECT ON api.contribution_types FROM anon;
REVOKE SELECT ON api.organizations FROM anon;

-- Отозвать RPC у anon (кроме login и health)
REVOKE EXECUTE ON FUNCTION api.post_payment(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION api.post_accrual(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION api.post_distribution(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION api.post_meter_reading(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION api.post_meter_charge(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION api.post_period_close(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION api.cancel_document(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION api.create_accrual_batch(uuid, uuid, date, text, numeric, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION api.create_payment(uuid, uuid, numeric, date, text, text, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION api.create_distribution(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION api.me() FROM anon;
REVOKE EXECUTE ON FUNCTION api.create_user(text, text, text, text, uuid) FROM anon;

-- login и health — открыты для всех
GRANT EXECUTE ON FUNCTION api.login(text, text) TO anon;

-- Enum-справочники остаются открытыми
GRANT SELECT ON api.enum_org_types TO anon;
GRANT SELECT ON api.enum_contribution_kinds TO anon;
GRANT SELECT ON api.enum_meter_types TO anon;
GRANT SELECT ON api.enum_genders TO anon;

-- ---------------------------------------------------------------------------
-- 8. Обновить postgrest.conf: добавить jwt-secret
-- ---------------------------------------------------------------------------
-- Выполнить вручную (или через скрипт ниже):
-- sudo sed -i '/^db-anon-role/a jwt-secret = '"'"'8AVgwi3NZhi84JVzckydqxD4EOvbl4nZm8Tbij01vCxvECMc'"'"'' /etc/postgrest/controlling.conf
-- sudo systemctl restart postgrest-controlling

-- ---------------------------------------------------------------------------
-- 9. Создать первого admin-пользователя для тест-организации
--    (удалить перед продакшном или сменить пароль)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_org_id UUID := '11111111-1111-1111-1111-111111111111';
BEGIN
    IF EXISTS (SELECT 1 FROM private.organizations WHERE id = v_org_id) THEN
        INSERT INTO private.users (login, password_hash, full_name, role, organization_id)
        VALUES (
            'admin',
            crypt('admin123', gen_salt('bf', 10)),
            'Администратор',
            'admin',
            v_org_id
        )
        ON CONFLICT (login) DO NOTHING;
    END IF;
END;
$$;
