-- 015_org_settings_history.sql
-- Периодический регистр настроек организации (sequential EAV).
-- Строка = значение одной настройки на одну дату.
-- Первая настройка: enabled_meter_types TEXT[].

-- ---------------------------------------------------------------------------
-- 1. Таблица private.org_settings_history
-- ---------------------------------------------------------------------------
CREATE TABLE private.org_settings_history (
    organization_id  UUID        NOT NULL REFERENCES private.organizations(id),
    effective_from   DATE        NOT NULL,
    setting_name     TEXT        NOT NULL,
    setting_value    JSONB       NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, effective_from, setting_name)
);

COMMENT ON TABLE private.org_settings_history IS
    'Периодический регистр настроек организации. '
    'Строка = значение одной настройки на одну дату. '
    'Актуальное: WHERE effective_from <= DATE ORDER BY effective_from DESC LIMIT 1.';

-- ---------------------------------------------------------------------------
-- 2. Обновить api.org_settings — добавить enabled_meter_types
-- ---------------------------------------------------------------------------
-- LATERAL даёт NULL если нет строк (в отличие от ARRAY(...) который даёт {}).
-- Это позволяет COALESCE корректно подставить дефолт.
CREATE OR REPLACE VIEW api.org_settings AS
SELECT
    o.id AS organization_id,
    pl.locked_until AS lock_date,
    o.current_period,
    CASE
        WHEN emt.setting_value IS NOT NULL
        THEN ARRAY(SELECT jsonb_array_elements_text(emt.setting_value))
        ELSE ARRAY['water', 'electricity', 'gas']
    END AS enabled_meter_types
FROM private.organizations o
LEFT JOIN private.period_locks pl ON pl.organization_id = o.id
LEFT JOIN LATERAL (
    SELECT h.setting_value
    FROM private.org_settings_history h
    WHERE h.organization_id = o.id
      AND h.setting_name    = 'enabled_meter_types'
      AND h.effective_from  <= CURRENT_DATE
    ORDER BY h.effective_from DESC
    LIMIT 1
) emt ON true;

GRANT SELECT ON api.org_settings TO authenticated;

COMMENT ON VIEW api.org_settings IS
    'Настройки организации: lock_date, current_period, enabled_meter_types '
    '(текущее; дефолт [water, electricity, gas] если запись не установлена).';

-- ---------------------------------------------------------------------------
-- 3. RPC api.set_meter_types
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_meter_types(p_org_id UUID, p_types TEXT[])
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_allowed TEXT[] := ARRAY['water', 'electricity', 'gas'];
    v_type    TEXT;
BEGIN
    IF private.current_org_id() IS NOT NULL AND p_org_id <> private.current_org_id() THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;

    IF p_types IS NULL OR array_length(p_types, 1) IS NULL THEN
        RAISE EXCEPTION 'EMPTY_TYPES';
    END IF;

    FOREACH v_type IN ARRAY p_types LOOP
        IF NOT (v_type = ANY(v_allowed)) THEN
            RAISE EXCEPTION 'INVALID_METER_TYPE: %', v_type;
        END IF;
    END LOOP;

    INSERT INTO private.org_settings_history
        (organization_id, effective_from, setting_name, setting_value)
    VALUES
        (p_org_id, CURRENT_DATE, 'enabled_meter_types', to_jsonb(p_types))
    ON CONFLICT (organization_id, effective_from, setting_name) DO UPDATE
        SET setting_value = EXCLUDED.setting_value,
            created_at    = now();

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_meter_types(UUID, TEXT[]) TO authenticated;

COMMENT ON FUNCTION api.set_meter_types IS
    'Установить типы счётчиков для организации на текущую дату. '
    'Допустимые типы: water, electricity, gas. Минимум 1 тип.';
