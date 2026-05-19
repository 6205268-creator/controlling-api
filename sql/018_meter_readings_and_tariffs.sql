-- =============================================================================
-- Migration 018: Meter readings & tariffs (2026-05-19)
-- 1. contribution_types: add meter_type + CHECK
-- 2. api.set_tariff
-- 3. api.create_meter_charge — rewrite with auto-lookup
-- 4. api.unpost_meter_charge — point unpost
-- 5. api.unpost_meter_reading — cascade unpost
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 1: contribution_types — meter_type link
-- ---------------------------------------------------------------------------
ALTER TABLE private.contribution_types
    ADD COLUMN meter_type private.meter_type_enum;

COMMENT ON COLUMN private.contribution_types.meter_type IS
    'Тип счётчика (water/electricity/gas). Обязателен при kind=''meter'', NULL для остальных.';

ALTER TABLE private.contribution_types
    ADD CONSTRAINT ct_meter_type_required
        CHECK (kind <> 'meter' OR meter_type IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Step 2: api.set_tariff — UPSERT тарифа для вида взноса kind='meter'
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_tariff(
    p_org_id               UUID,
    p_contribution_type_id UUID,
    p_valid_from           DATE,
    p_rate                 NUMERIC
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org UUID;
    v_ct      private.contribution_types%ROWTYPE;
    v_id      UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_ct
    FROM private.contribution_types
    WHERE id = p_contribution_type_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_CONTRIBUTION_TYPE: вид взноса % не найден', p_contribution_type_id;
    END IF;

    IF v_ct.organization_id <> p_org_id THEN
        RAISE EXCEPTION 'ORG_MISMATCH: вид взноса принадлежит другой организации';
    END IF;

    IF v_ctx_org IS NOT NULL AND v_ct.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_ct.kind <> 'meter' THEN
        RAISE EXCEPTION 'NOT_METER_KIND: тарифы только для видов взноса kind=''meter''';
    END IF;

    IF p_rate <= 0 THEN
        RAISE EXCEPTION 'INVALID_RATE: тариф должен быть > 0, получено %', p_rate;
    END IF;

    INSERT INTO private.tariffs (organization_id, contribution_type_id, valid_from, rate)
    VALUES (p_org_id, p_contribution_type_id, p_valid_from, p_rate)
    ON CONFLICT (organization_id, contribution_type_id, valid_from)
    DO UPDATE SET rate = EXCLUDED.rate
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'tariff_id', v_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_tariff(UUID, UUID, DATE, NUMERIC) TO authenticated;
