-- =============================================================================
-- Migration 022: org_settings_registry
-- Adds private.org_setting_definitions; rebuilds api.org_settings view
-- (one row per org × setting); adds api.set_org_setting RPC;
-- rewrites set_meter_types as a thin wrapper.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Таблица private.org_setting_definitions
-- ---------------------------------------------------------------------------
CREATE TABLE private.org_setting_definitions (
    setting_name   TEXT    PRIMARY KEY,
    value_type     TEXT    NOT NULL
                           CHECK (value_type IN ('boolean','integer','text','enum','enum[]')),
    allowed_values JSONB,
    default_value  JSONB   NOT NULL,
    description    TEXT    NOT NULL,
    is_active      BOOLEAN NOT NULL DEFAULT true,
    CONSTRAINT check_allowed_values_for_enum
        CHECK (value_type NOT IN ('enum','enum[]') OR allowed_values IS NOT NULL)
);

COMMENT ON TABLE private.org_setting_definitions IS
    'Реестр допустимых настроек организации. '
    'Каждая строка — одна настройка с типом, допустимыми значениями и дефолтом.';

-- ---------------------------------------------------------------------------
-- 2. Seed — 4 настройки
-- ---------------------------------------------------------------------------
INSERT INTO private.org_setting_definitions
    (setting_name, value_type, allowed_values, default_value, description)
VALUES
    ('use_meters',
     'boolean',
     NULL,
     'false'::jsonb,
     'Использовать счётчики'),

    ('enabled_meter_types',
     'enum[]',
     '["water","electricity","gas"]'::jsonb,
     '[]'::jsonb,
     'Виды счётчиков'),

    ('legal_address',
     'text',
     NULL,
     'null'::jsonb,
     'Юридический адрес'),

    ('postal_address',
     'text',
     NULL,
     'null'::jsonb,
     'Почтовый адрес');

-- ---------------------------------------------------------------------------
-- 3. FK org_settings_history.setting_name → org_setting_definitions
-- Выполняем ПОСЛЕ seed, т.к. в history уже есть строки с 'enabled_meter_types'.
-- ---------------------------------------------------------------------------
ALTER TABLE private.org_settings_history
    ADD CONSTRAINT fk_org_settings_history_setting_name
    FOREIGN KEY (setting_name)
    REFERENCES private.org_setting_definitions(setting_name);

-- ---------------------------------------------------------------------------
-- 4. Пересоздать api.org_settings
-- Схема меняется кардинально — DROP + CREATE (не CREATE OR REPLACE).
-- Старые колонки: organization_id, lock_date, current_period, enabled_meter_types.
-- Новые: organization_id, setting_name, value_type, description,
--         allowed_values, default_value, current_value.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.org_settings;

CREATE VIEW api.org_settings AS
SELECT
    o.id                                                     AS organization_id,
    d.setting_name,
    d.value_type,
    d.description,
    d.allowed_values,
    d.default_value,
    COALESCE(h_latest.setting_value, d.default_value)        AS current_value
FROM private.organizations         o
CROSS JOIN private.org_setting_definitions d
LEFT JOIN LATERAL (
    SELECT h.setting_value
    FROM private.org_settings_history h
    WHERE h.organization_id = o.id
      AND h.setting_name    = d.setting_name
      AND h.effective_from  <= CURRENT_DATE
    ORDER BY h.effective_from DESC
    LIMIT 1
) h_latest ON true
WHERE d.is_active = true;

GRANT SELECT ON api.org_settings TO authenticated;

COMMENT ON VIEW api.org_settings IS
    'Текущие настройки организаций: одна строка на (org, setting). '
    'current_value = последнее значение из истории или default_value из реестра.';

-- ---------------------------------------------------------------------------
-- 5. RPC api.set_org_setting
-- Валидирует тип, enum-значения, кросс-правило use_meters / enabled_meter_types.
-- UPSERT в org_settings_history на CURRENT_DATE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_org_setting(
    p_org_id       UUID,
    p_setting_name TEXT,
    p_value        JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_def         private.org_setting_definitions%ROWTYPE;
    v_ctx_org     UUID;
    v_elem        JSONB;
    v_elem_text   TEXT;
    v_meter_types JSONB;
BEGIN
    v_ctx_org := private.current_org_id();
    IF v_ctx_org IS NOT NULL AND p_org_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;

    -- 1. Найти настройку в реестре
    SELECT * INTO v_def
    FROM private.org_setting_definitions
    WHERE setting_name = p_setting_name;

    IF NOT FOUND OR NOT v_def.is_active THEN
        RAISE EXCEPTION 'UNKNOWN_SETTING: %', p_setting_name;
    END IF;

    -- 2. Валидация типа
    IF v_def.value_type = 'boolean' THEN
        IF jsonb_typeof(p_value) <> 'boolean' THEN
            RAISE EXCEPTION 'INVALID_SETTING_VALUE: expected boolean, got %', jsonb_typeof(p_value);
        END IF;

    ELSIF v_def.value_type = 'integer' THEN
        IF jsonb_typeof(p_value) <> 'number' THEN
            RAISE EXCEPTION 'INVALID_SETTING_VALUE: expected integer, got %', jsonb_typeof(p_value);
        END IF;

    ELSIF v_def.value_type = 'text' THEN
        IF jsonb_typeof(p_value) NOT IN ('string', 'null') THEN
            RAISE EXCEPTION 'INVALID_SETTING_VALUE: expected text or null, got %', jsonb_typeof(p_value);
        END IF;

    ELSIF v_def.value_type = 'enum' THEN
        IF jsonb_typeof(p_value) <> 'string' THEN
            RAISE EXCEPTION 'INVALID_SETTING_VALUE: expected string, got %', jsonb_typeof(p_value);
        END IF;
        IF v_def.allowed_values IS NOT NULL AND NOT (v_def.allowed_values @> p_value) THEN
            RAISE EXCEPTION 'INVALID_ENUM_VALUE: % not in allowed values', p_value #>> '{}';
        END IF;

    ELSIF v_def.value_type = 'enum[]' THEN
        IF jsonb_typeof(p_value) <> 'array' THEN
            RAISE EXCEPTION 'INVALID_SETTING_VALUE: expected array, got %', jsonb_typeof(p_value);
        END IF;
        IF v_def.allowed_values IS NOT NULL THEN
            FOR v_elem IN SELECT * FROM jsonb_array_elements(p_value) LOOP
                IF NOT (v_def.allowed_values @> v_elem) THEN
                    v_elem_text := v_elem #>> '{}';
                    RAISE EXCEPTION 'INVALID_ENUM_VALUE: % not in allowed values', v_elem_text;
                END IF;
            END LOOP;
        END IF;
    END IF;

    -- 3. Кросс-валидация: use_meters=true требует непустого enabled_meter_types
    IF p_setting_name = 'use_meters' AND p_value = 'true'::jsonb THEN
        SELECT h.setting_value INTO v_meter_types
        FROM private.org_settings_history h
        WHERE h.organization_id = p_org_id
          AND h.setting_name    = 'enabled_meter_types'
          AND h.effective_from  <= CURRENT_DATE
        ORDER BY h.effective_from DESC
        LIMIT 1;

        -- Нет истории — берём дефолт из реестра (=[])
        IF v_meter_types IS NULL THEN
            SELECT d2.default_value INTO v_meter_types
            FROM private.org_setting_definitions d2
            WHERE d2.setting_name = 'enabled_meter_types';
        END IF;

        IF v_meter_types IS NULL OR jsonb_array_length(v_meter_types) = 0 THEN
            RAISE EXCEPTION 'METER_TYPES_REQUIRED: set enabled_meter_types before enabling use_meters';
        END IF;
    END IF;

    -- 4. UPSERT
    INSERT INTO private.org_settings_history
        (organization_id, effective_from, setting_name, setting_value)
    VALUES
        (p_org_id, CURRENT_DATE, p_setting_name, p_value)
    ON CONFLICT (organization_id, effective_from, setting_name) DO UPDATE
        SET setting_value = EXCLUDED.setting_value,
            created_at    = now();

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_org_setting(UUID, TEXT, JSONB) TO authenticated;

COMMENT ON FUNCTION api.set_org_setting IS
    'Установить настройку организации. Валидирует value_type, enum-значения, '
    'кросс-правило use_meters/enabled_meter_types. UPSERT на CURRENT_DATE.';

-- ---------------------------------------------------------------------------
-- 6. set_meter_types → враппер поверх set_org_setting
-- Сохраняет обратную совместимость. EMPTY_TYPES проверяется здесь же.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_meter_types(p_org_id UUID, p_types TEXT[])
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF p_types IS NULL OR array_length(p_types, 1) IS NULL THEN
        RAISE EXCEPTION 'EMPTY_TYPES';
    END IF;
    RETURN api.set_org_setting(p_org_id, 'enabled_meter_types', to_jsonb(p_types));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_meter_types(UUID, TEXT[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. PostgREST schema reload
-- ---------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
