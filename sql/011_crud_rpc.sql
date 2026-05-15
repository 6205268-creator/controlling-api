-- =============================================================================
-- Migration 011: CRUD RPC helpers for frontend
-- 1. api.update_plot
-- 2. api.create_meter
-- 3. api.update_meter
-- 4. api.update_contractor
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. api.update_plot
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_plot(
    p_org_id    UUID,
    p_plot_id   UUID,
    p_number    TEXT,
    p_area      NUMERIC(10,2),
    p_is_active BOOLEAN
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF p_number IS NULL OR trim(p_number) = '' THEN
        RAISE EXCEPTION 'INVALID_NUMBER: номер участка не может быть пустым';
    END IF;

    UPDATE private.plots
    SET number    = trim(p_number),
        area      = p_area,
        is_active = p_is_active
    WHERE id              = p_plot_id
      AND organization_id = p_org_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NOT_FOUND: участок не найден';
    END IF;

    RETURN jsonb_build_object('ok', true, 'plot_id', p_plot_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_plot(UUID, UUID, TEXT, NUMERIC, BOOLEAN) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. api.create_meter
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_meter(
    p_org_id        UUID,
    p_plot_id       UUID,
    p_meter_type    TEXT,
    p_serial_number TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id UUID;
BEGIN
    IF p_meter_type NOT IN ('water', 'electricity', 'gas') THEN
        RAISE EXCEPTION 'INVALID_TYPE: meter_type must be water, electricity or gas';
    END IF;

    INSERT INTO private.meters (organization_id, plot_id, meter_type, serial_number, is_active)
    VALUES (p_org_id, p_plot_id, p_meter_type::private.meter_type_enum,
            nullif(trim(p_serial_number), ''), true)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'meter_id', v_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_meter(UUID, UUID, TEXT, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. api.update_meter
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_meter(
    p_org_id        UUID,
    p_meter_id      UUID,
    p_meter_type    TEXT,
    p_serial_number TEXT,
    p_is_active     BOOLEAN
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF p_meter_type NOT IN ('water', 'electricity', 'gas') THEN
        RAISE EXCEPTION 'INVALID_TYPE: meter_type must be water, electricity or gas';
    END IF;

    UPDATE private.meters
    SET meter_type    = p_meter_type::private.meter_type_enum,
        serial_number = nullif(trim(p_serial_number), ''),
        is_active     = p_is_active
    WHERE id              = p_meter_id
      AND organization_id = p_org_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NOT_FOUND: счётчик не найден';
    END IF;

    RETURN jsonb_build_object('ok', true, 'meter_id', p_meter_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_meter(UUID, UUID, TEXT, TEXT, BOOLEAN) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. api.update_contractor
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.update_contractor(
    p_org_id          UUID,
    p_contractor_id   UUID,
    p_full_name       TEXT,
    p_contractor_type TEXT,
    p_phone           TEXT DEFAULT NULL,
    p_email           TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF p_full_name IS NULL OR trim(p_full_name) = '' THEN
        RAISE EXCEPTION 'INVALID_NAME: ФИО не может быть пустым';
    END IF;
    IF p_contractor_type NOT IN ('individual', 'legal_entity') THEN
        RAISE EXCEPTION 'INVALID_TYPE: contractor_type must be individual or legal_entity';
    END IF;

    UPDATE private.contractors
    SET full_name       = trim(p_full_name),
        contractor_type = p_contractor_type,
        phone           = nullif(trim(p_phone), ''),
        email           = nullif(trim(p_email), '')
    WHERE id              = p_contractor_id
      AND organization_id = p_org_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NOT_FOUND: контрагент не найден';
    END IF;

    RETURN jsonb_build_object('ok', true, 'contractor_id', p_contractor_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_contractor(UUID, UUID, TEXT, TEXT, TEXT, TEXT) TO authenticated;
