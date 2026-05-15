-- =============================================================================
-- 007_plot_ownerships_admin_seed.sql
-- 1. Роль app_admin (обходит RLS) + JWT для суперадмина
-- 2. Seed без устаревшего plot_ownerships / api.plot_ownerships (см. 010)
-- 3. Две орган «СТ «Демо-А»», «СТ «Демо-Б»»: по 5 участков (owner_id NULL),
--    демо-пользователи; виды взносов
-- Контрагенты с contractor_type вносятся после wipe в 010 — хвост файла 012
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Роль app_admin + обновление login + current_org_id
-- ---------------------------------------------------------------------------

DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_admin') THEN
        CREATE ROLE app_admin NOLOGIN BYPASSRLS;
    END IF;
END $$;

GRANT authenticated TO app_admin;
GRANT USAGE ON SCHEMA api     TO app_admin;
GRANT USAGE ON SCHEMA private TO app_admin;
GRANT SELECT   ON ALL TABLES    IN SCHEMA api     TO app_admin;
GRANT SELECT   ON ALL TABLES    IN SCHEMA private TO app_admin;
GRANT EXECUTE  ON ALL FUNCTIONS IN SCHEMA api     TO app_admin;

-- До 008: расширяем CHECK, чтобы принять superadmin в seed (008 сузит до superadmin|admin|treasurer)
ALTER TABLE private.users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE private.users ADD CONSTRAINT users_role_check
    CHECK (role = ANY (ARRAY['superadmin','admin','treasurer','board','member','background']));

-- current_org_id: app_admin обходит RLS — возвращаем NULL без ошибки
CREATE OR REPLACE FUNCTION private.current_org_id()
RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
    v_claims JSONB := current_setting('request.jwt.claims', true)::jsonb;
    v_role   TEXT  := v_claims->>'role';
    v_org_id UUID;
BEGIN
    IF v_role = 'app_admin' THEN RETURN NULL; END IF;
    v_org_id := (v_claims->>'organization_id')::uuid;
    IF v_org_id IS NULL THEN
        RAISE EXCEPTION 'missing organization_id in token' USING ERRCODE = '28P01';
    END IF;
    RETURN v_org_id;
END;
$$;

-- login: superadmin получает role='app_admin' в JWT (см. API_CONTRACT.md)
CREATE OR REPLACE FUNCTION api.login(p_login TEXT, p_password TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_user private.users;
    v_exp  BIGINT;
    v_role TEXT;
BEGIN
    SELECT * INTO v_user
    FROM private.users
    WHERE login = p_login AND is_active = true;

    IF NOT FOUND OR v_user.password_hash <> crypt(p_password, v_user.password_hash) THEN
        RAISE EXCEPTION 'invalid credentials' USING ERRCODE = '28P01';
    END IF;

    v_exp  := extract(epoch FROM now() + interval '8 hours')::bigint;
    v_role := CASE WHEN v_user.role = 'superadmin' THEN 'app_admin' ELSE 'authenticated' END;

    RETURN jsonb_build_object(
        'token', private.generate_jwt(jsonb_build_object(
                     'role',            v_role,
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

-- ---------------------------------------------------------------------------
-- 2. Seed
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    v_org_a UUID;
    v_org_b UUID;
BEGIN
    -- Организации
    INSERT INTO private.organizations (name, org_type) VALUES ('СТ «Демо-А»', 'gardening') RETURNING id INTO v_org_a;
    INSERT INTO private.organizations (name, org_type) VALUES ('СТ «Демо-Б»', 'gardening') RETURNING id INTO v_org_b;

    -- Участки: owner_id остаётся NULL; без документов владения
    INSERT INTO private.plots (organization_id, number, area, owner_id)
    SELECT v_org_a, t.n::text, 6.00 + (t.n * 0.05), NULL
    FROM generate_series(1, 5) AS t(n);

    INSERT INTO private.plots (organization_id, number, area, owner_id)
    SELECT v_org_b, t.n::text, 6.00 + (t.n * 0.05), NULL
    FROM generate_series(1, 5) AS t(n);

    -- Виды взносов
    INSERT INTO private.contribution_types (organization_id, name, kind) VALUES
        (v_org_a, 'Членский взнос', 'membership'),
        (v_org_a, 'Целевой взнос',  'target'),
        (v_org_b, 'Членский взнос', 'membership'),
        (v_org_b, 'Целевой взнос',  'target');

    -- Пользователи (логины и пароли — API_CONTRACT.md / BACKEND_MASTER)
    INSERT INTO private.users (login, password_hash, full_name, role, organization_id) VALUES
        ('demo_a_chair',    crypt('chair123',    gen_salt('bf',10)), 'Председатель СТ Демо-А', 'admin',      v_org_a),
        ('demo_a_treasury', crypt('treasury123', gen_salt('bf',10)), 'Казначей СТ Демо-А',     'treasurer',  v_org_a),
        ('demo_b_chair',    crypt('chair123',    gen_salt('bf',10)), 'Председатель СТ Демо-Б', 'admin',      v_org_b),
        ('demo_b_treasury', crypt('treasury123', gen_salt('bf',10)), 'Казначей СТ Демо-Б',     'treasurer',  v_org_b),
        ('superadmin',      crypt('super123',    gen_salt('bf',10)), 'Суперадминистратор',      'superadmin', NULL)
    ON CONFLICT (login) DO NOTHING;

    RAISE NOTICE 'Seed OK. Org A: %, Org B: %', v_org_a, v_org_b;
END;
$$;
