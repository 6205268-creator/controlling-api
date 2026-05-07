-- =============================================================================
-- 007_plot_ownerships_admin_seed.sql
-- 1. Таблица plot_ownerships (доли владения участком)
-- 2. Роль app_admin (обходит RLS — видит все организации)
-- 3. Seed-данные: СТ «Демо-А» и СТ «Демо-Б»
-- 4. Пользователи: председатель + казначей × 2 org + 1 суперадмин
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Таблица plot_ownerships
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.plot_ownerships (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    plot_id         UUID NOT NULL REFERENCES private.plots(id) ON DELETE CASCADE,
    contractor_id   UUID NOT NULL REFERENCES private.contractors(id),
    share_weight    NUMERIC(10,4) NOT NULL DEFAULT 1 CHECK (share_weight > 0),
    is_primary      BOOLEAN NOT NULL DEFAULT false,
    valid_from      DATE NOT NULL,
    valid_to        DATE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT plot_ownerships_dates_check CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE INDEX IF NOT EXISTS idx_plot_ownerships_plot     ON private.plot_ownerships(plot_id);
CREATE INDEX IF NOT EXISTS idx_plot_ownerships_contr    ON private.plot_ownerships(organization_id, contractor_id);
CREATE INDEX IF NOT EXISTS idx_plot_ownerships_active   ON private.plot_ownerships(organization_id, plot_id) WHERE valid_to IS NULL;

ALTER TABLE private.plot_ownerships ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS org_isolation ON private.plot_ownerships;
CREATE POLICY org_isolation ON private.plot_ownerships
    USING (organization_id = private.current_org_id());

-- View для API
CREATE OR REPLACE VIEW api.plot_ownerships AS
SELECT
    po.id,
    po.organization_id,
    po.plot_id,
    p.number  AS plot_number,
    po.contractor_id,
    c.full_name AS contractor_name,
    po.share_weight,
    po.is_primary,
    po.valid_from,
    po.valid_to,
    po.created_at
FROM private.plot_ownerships po
JOIN private.plots p     ON p.id = po.plot_id
JOIN private.contractors c ON c.id = po.contractor_id;

GRANT SELECT ON api.plot_ownerships TO authenticated;
REVOKE SELECT ON api.plot_ownerships FROM anon;

-- ---------------------------------------------------------------------------
-- 2. Роль app_admin + обновление login + current_org_id
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

-- Новый constraint с superadmin
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

-- login: superadmin получает role='app_admin' в JWT
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
-- 3. Seed-данные через временные таблицы
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    v_org_a UUID;
    v_org_b UUID;
BEGIN
    -- === ОРГАНИЗАЦИИ ===
    INSERT INTO private.organizations (name, org_type) VALUES ('СТ «Демо-А»', 'gardening') RETURNING id INTO v_org_a;
    INSERT INTO private.organizations (name, org_type) VALUES ('СТ «Демо-Б»', 'gardening') RETURNING id INTO v_org_b;

    -- === CONTRACTORS + PLOTS через временные таблицы ===
    -- Используем TEMP TABLE чтобы хранить ref→id маппинг

    CREATE TEMP TABLE _c_a (ref TEXT PRIMARY KEY, id UUID);
    CREATE TEMP TABLE _c_b (ref TEXT PRIMARY KEY, id UUID);
    CREATE TEMP TABLE _p_a (ref TEXT PRIMARY KEY, id UUID);
    CREATE TEMP TABLE _p_b (ref TEXT PRIMARY KEY, id UUID);

    -- Contractors Демо-А
    WITH ins AS (
        INSERT INTO private.contractors (organization_id, full_name, email, phone)
        VALUES
            (v_org_a, 'УП "СТ «Демо-А»" (исполком)',  'ispolkom-a@demo.controlling.local', NULL),
            (v_org_a, 'ООО «Земледел»',                'zemledel-a@demo.controlling.local',  NULL),
            (v_org_a, 'Захарченко Николай Петрович',   NULL, '+375291000001'),
            (v_org_a, 'Мороз Анна Степановна',         NULL, '+375291000002'),
            (v_org_a, 'Ковалёв Дмитрий Иванович',      NULL, '+375291000003'),
            (v_org_a, 'Соколова Ирина Владимировна',   NULL, '+375291000004'),
            (v_org_a, 'Литвиненко Пётр Семёнович',     NULL, '+375291000005'),
            (v_org_a, 'Орлова Светлана Николаевна',    NULL, '+375291000006'),
            (v_org_a, 'Кузнецов Андрей Борисович',     NULL, '+375291000007'),
            (v_org_a, 'Попова Галина Фёдоровна',       NULL, '+375291000008'),
            (v_org_a, 'Тимофеев Олег Александрович',   NULL, '+375291000009'),
            (v_org_a, 'Белова Надежда Сергеевна',      NULL, '+375291000010'),
            (v_org_a, 'Гриценко Василий Михайлович',   NULL, '+375291000011'),
            (v_org_a, 'Романенко Татьяна Юрьевна',     NULL, '+375291000012')
        RETURNING id, full_name
    )
    INSERT INTO _c_a (ref, id)
    SELECT
        CASE full_name
            WHEN 'УП "СТ «Демо-А»" (исполком)' THEN 'ispolkom'
            WHEN 'ООО «Земледел»'               THEN 'legal2'
            WHEN 'Захарченко Николай Петрович'  THEN 'ph01'
            WHEN 'Мороз Анна Степановна'        THEN 'ph02'
            WHEN 'Ковалёв Дмитрий Иванович'     THEN 'ph03'
            WHEN 'Соколова Ирина Владимировна'  THEN 'ph04'
            WHEN 'Литвиненко Пётр Семёнович'    THEN 'ph05'
            WHEN 'Орлова Светлана Николаевна'   THEN 'ph06'
            WHEN 'Кузнецов Андрей Борисович'    THEN 'ph07'
            WHEN 'Попова Галина Фёдоровна'      THEN 'ph08'
            WHEN 'Тимофеев Олег Александрович'  THEN 'ph09'
            WHEN 'Белова Надежда Сергеевна'     THEN 'ph10'
            WHEN 'Гриценко Василий Михайлович'  THEN 'ph11'
            WHEN 'Романенко Татьяна Юрьевна'    THEN 'ph12'
        END,
        id
    FROM ins;

    -- Contractors Демо-Б
    WITH ins AS (
        INSERT INTO private.contractors (organization_id, full_name, email, phone)
        VALUES
            (v_org_b, 'УП "СТ «Демо-Б»" (исполком)',  'ispolkom-b@demo.controlling.local', NULL),
            (v_org_b, 'ООО «АгроПром»',                'agroprom-b@demo.controlling.local',  NULL),
            (v_org_b, 'Петренко Сергей Васильевич',    NULL, '+375291000101'),
            (v_org_b, 'Иванова Людмила Петровна',      NULL, '+375291000102'),
            (v_org_b, 'Сидоров Геннадий Павлович',     NULL, '+375291000103'),
            (v_org_b, 'Козлова Марина Ивановна',       NULL, '+375291000104'),
            (v_org_b, 'Фёдоров Виктор Николаевич',     NULL, '+375291000105'),
            (v_org_b, 'Андреева Ольга Степановна',     NULL, '+375291000106'),
            (v_org_b, 'Михайлов Евгений Борисович',    NULL, '+375291000107'),
            (v_org_b, 'Семёнова Вера Александровна',   NULL, '+375291000108'),
            (v_org_b, 'Николаев Константин Юрьевич',   NULL, '+375291000109'),
            (v_org_b, 'Алексеева Зинаида Фёдоровна',   NULL, '+375291000110'),
            (v_org_b, 'Дмитриев Павел Семёнович',      NULL, '+375291000111'),
            (v_org_b, 'Карпова Наталья Ивановна',      NULL, '+375291000112')
        RETURNING id, full_name
    )
    INSERT INTO _c_b (ref, id)
    SELECT
        CASE full_name
            WHEN 'УП "СТ «Демо-Б»" (исполком)' THEN 'ispolkom'
            WHEN 'ООО «АгроПром»'               THEN 'legal2'
            WHEN 'Петренко Сергей Васильевич'   THEN 'ph01'
            WHEN 'Иванова Людмила Петровна'     THEN 'ph02'
            WHEN 'Сидоров Геннадий Павлович'    THEN 'ph03'
            WHEN 'Козлова Марина Ивановна'      THEN 'ph04'
            WHEN 'Фёдоров Виктор Николаевич'    THEN 'ph05'
            WHEN 'Андреева Ольга Степановна'    THEN 'ph06'
            WHEN 'Михайлов Евгений Борисович'   THEN 'ph07'
            WHEN 'Семёнова Вера Александровна'  THEN 'ph08'
            WHEN 'Николаев Константин Юрьевич'  THEN 'ph09'
            WHEN 'Алексеева Зинаида Фёдоровна'  THEN 'ph10'
            WHEN 'Дмитриев Павел Семёнович'     THEN 'ph11'
            WHEN 'Карпова Наталья Ивановна'     THEN 'ph12'
        END,
        id
    FROM ins;

    -- Plots Демо-А (18 участков)
    WITH ins AS (
        INSERT INTO private.plots (organization_id, number, area, owner_id)
        SELECT v_org_a, num::text, area,
            (SELECT id FROM _c_a WHERE ref = owner_ref)
        FROM (VALUES
            ('1',  6.05, 'ispolkom'), ('2',  6.10, 'ispolkom'), ('3',  6.15, 'legal2'),
            ('4',  6.20, 'ph01'),     ('5',  6.05, 'ph02'),     ('6',  6.30, 'ph03'),
            ('7',  6.10, 'ph04'),     ('8',  6.25, 'ph05'),     ('9',  6.05, 'ph06'),
            ('10', 6.15, 'ph07'),     ('11', 6.20, 'ph08'),     ('12', 6.10, 'ph09'),
            ('13', 6.05, 'ph10'),     ('14', 6.30, 'ph11'),     ('15', 6.15, 'ph12'),
            ('16', 6.10, 'ph01'),     ('17', 6.20, 'ph04'),     ('18', 6.05, 'ph07')
        ) AS t(num, area, owner_ref)
        RETURNING id, number
    )
    INSERT INTO _p_a (ref, id) SELECT 'p'||number, id FROM ins;

    -- Plots Демо-Б (18 участков)
    WITH ins AS (
        INSERT INTO private.plots (organization_id, number, area, owner_id)
        SELECT v_org_b, num::text, area,
            (SELECT id FROM _c_b WHERE ref = owner_ref)
        FROM (VALUES
            ('1',  6.05, 'ispolkom'), ('2',  6.10, 'ispolkom'), ('3',  6.15, 'legal2'),
            ('4',  6.20, 'ph01'),     ('5',  6.05, 'ph02'),     ('6',  6.30, 'ph03'),
            ('7',  6.10, 'ph04'),     ('8',  6.25, 'ph05'),     ('9',  6.05, 'ph06'),
            ('10', 6.15, 'ph07'),     ('11', 6.20, 'ph08'),     ('12', 6.10, 'ph09'),
            ('13', 6.05, 'ph10'),     ('14', 6.30, 'ph11'),     ('15', 6.15, 'ph12'),
            ('16', 6.10, 'ph01'),     ('17', 6.20, 'ph04'),     ('18', 6.05, 'ph07')
        ) AS t(num, area, owner_ref)
        RETURNING id, number
    )
    INSERT INTO _p_b (ref, id) SELECT 'p'||number, id FROM ins;

    -- Plot ownerships Демо-А
    INSERT INTO private.plot_ownerships (organization_id, plot_id, contractor_id, share_weight, is_primary, valid_from)
    SELECT v_org_a,
           (SELECT id FROM _p_a WHERE ref = plot_ref),
           (SELECT id FROM _c_a WHERE ref = contr_ref),
           share, primary_flag, '2020-01-01'
    FROM (VALUES
        ('p1',  'ispolkom', 1.0,   true),  ('p2',  'ispolkom', 1.0,   true),
        ('p3',  'legal2',   1.0,   true),  ('p4',  'ph01',     1.0,   true),
        ('p5',  'ph02',     1.0,   true),  ('p6',  'ph03',     1.0,   true),
        ('p7',  'ph04',     1.0,   true),  ('p8',  'ph05',     1.0,   true),
        ('p9',  'ph06',     1.0,   true),  ('p10', 'ph07',     1.0,   true),
        ('p11', 'ph08',     1.0,   true),  ('p12', 'ph09',     1.0,   true),
        ('p13', 'ph10',     1.0,   true),  ('p14', 'ph11',     1.0,   true),
        -- участок 15: два совладельца 50/50
        ('p15', 'ph12',     0.5,   true),  ('p15', 'ph01',     0.5,   false),
        -- участок 16: два совладельца 2/3 + 1/3
        ('p16', 'ph01',     0.667, true),  ('p16', 'ph03',     0.333, false),
        ('p17', 'ph04',     1.0,   true),  ('p18', 'ph07',     1.0,   true)
    ) AS t(plot_ref, contr_ref, share, primary_flag);

    -- Plot ownerships Демо-Б
    INSERT INTO private.plot_ownerships (organization_id, plot_id, contractor_id, share_weight, is_primary, valid_from)
    SELECT v_org_b,
           (SELECT id FROM _p_b WHERE ref = plot_ref),
           (SELECT id FROM _c_b WHERE ref = contr_ref),
           share, primary_flag, '2020-01-01'
    FROM (VALUES
        ('p1',  'ispolkom', 1.0,   true),  ('p2',  'ispolkom', 1.0,   true),
        ('p3',  'legal2',   1.0,   true),  ('p4',  'ph01',     1.0,   true),
        ('p5',  'ph02',     1.0,   true),  ('p6',  'ph03',     1.0,   true),
        ('p7',  'ph04',     1.0,   true),  ('p8',  'ph05',     1.0,   true),
        ('p9',  'ph06',     1.0,   true),  ('p10', 'ph07',     1.0,   true),
        ('p11', 'ph08',     1.0,   true),  ('p12', 'ph09',     1.0,   true),
        ('p13', 'ph10',     1.0,   true),  ('p14', 'ph11',     1.0,   true),
        ('p15', 'ph12',     0.5,   true),  ('p15', 'ph01',     0.5,   false),
        ('p16', 'ph01',     0.667, true),  ('p16', 'ph03',     0.333, false),
        ('p17', 'ph04',     1.0,   true),  ('p18', 'ph07',     1.0,   true)
    ) AS t(plot_ref, contr_ref, share, primary_flag);

    -- Виды взносов
    INSERT INTO private.contribution_types (organization_id, name, kind) VALUES
        (v_org_a, 'Членский взнос', 'membership'),
        (v_org_a, 'Целевой взнос',  'target'),
        (v_org_b, 'Членский взнос', 'membership'),
        (v_org_b, 'Целевой взнос',  'target');

    -- Пользователи
    INSERT INTO private.users (login, password_hash, full_name, role, organization_id) VALUES
        ('demo_a_chair',    crypt('chair123',    gen_salt('bf',10)), 'Председатель СТ Демо-А', 'admin',      v_org_a),
        ('demo_a_treasury', crypt('treasury123', gen_salt('bf',10)), 'Казначей СТ Демо-А',     'treasurer',  v_org_a),
        ('demo_b_chair',    crypt('chair123',    gen_salt('bf',10)), 'Председатель СТ Демо-Б', 'admin',      v_org_b),
        ('demo_b_treasury', crypt('treasury123', gen_salt('bf',10)), 'Казначей СТ Демо-Б',     'treasurer',  v_org_b),
        ('superadmin',      crypt('super123',    gen_salt('bf',10)), 'Суперадминистратор',      'superadmin', NULL)
    ON CONFLICT (login) DO NOTHING;

    DROP TABLE _c_a; DROP TABLE _c_b; DROP TABLE _p_a; DROP TABLE _p_b;

    RAISE NOTICE 'Seed OK. Org A: %, Org B: %', v_org_a, v_org_b;
END;
$$;
