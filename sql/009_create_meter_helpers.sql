-- Migration 009: RPC helpers create_meter_reading, create_meter_charge
-- Replaces double raw INSERT from frontend with single RPC call.

-- ─────────────────────────────────────────────
-- create_meter_reading
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION api.create_meter_reading(
    p_org_id        uuid,
    p_meter_id      uuid,
    p_reading_date  date,
    p_reading_value numeric,
    p_notes         text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_doc_id uuid;
BEGIN
    IF p_reading_value < 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: reading_value must be >= 0, got %', p_reading_value;
    END IF;

    -- Проверить: счётчик принадлежит организации
    IF NOT EXISTS (
        SELECT 1 FROM private.meters
        WHERE id = p_meter_id AND organization_id = p_org_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'INVALID_OBJECT_TYPE: meter % not found in org %', p_meter_id, p_org_id;
    END IF;

    INSERT INTO private.documents (organization_id, doc_type, doc_date, status, notes)
    VALUES (p_org_id, 'meter_reading', p_reading_date, 'draft', p_notes)
    RETURNING id INTO v_doc_id;

    INSERT INTO private.doc_meter_reading (document_id, meter_id, reading_date, reading_value)
    VALUES (v_doc_id, p_meter_id, p_reading_date, p_reading_value);

    RETURN jsonb_build_object('ok', true, 'document_id', v_doc_id, 'status', 'draft');

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_meter_reading(uuid, uuid, date, numeric, text) TO app_admin, authenticated;

-- ─────────────────────────────────────────────
-- create_meter_charge
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION api.create_meter_charge(
    p_org_id                uuid,
    p_meter_id              uuid,
    p_contribution_type_id  uuid,
    p_reading_current       numeric,
    p_reading_previous      numeric,
    p_tariff_rate           numeric,
    p_doc_date              date    DEFAULT CURRENT_DATE,
    p_notes                 text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_doc_id    uuid;
    v_amount    numeric(15,2);
BEGIN
    IF p_reading_current <= p_reading_previous THEN
        RAISE EXCEPTION 'READING_LESS_THAN_PREVIOUS: current reading %.3f must be > previous %.3f',
            p_reading_current, p_reading_previous;
    END IF;

    IF p_tariff_rate <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: tariff_rate must be > 0, got %', p_tariff_rate;
    END IF;

    -- Проверить: счётчик принадлежит организации
    IF NOT EXISTS (
        SELECT 1 FROM private.meters
        WHERE id = p_meter_id AND organization_id = p_org_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'INVALID_OBJECT_TYPE: meter % not found in org %', p_meter_id, p_org_id;
    END IF;

    -- Проверить: тип взноса принадлежит организации
    IF NOT EXISTS (
        SELECT 1 FROM private.contribution_types
        WHERE id = p_contribution_type_id AND organization_id = p_org_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'CONTRACTOR_NOT_FOUND: contribution_type % not found in org %',
            p_contribution_type_id, p_org_id;
    END IF;

    v_amount := round((p_reading_current - p_reading_previous) * p_tariff_rate, 2);

    IF v_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: calculated amount %.2f must be > 0', v_amount;
    END IF;

    INSERT INTO private.documents (organization_id, doc_type, doc_date, status, notes)
    VALUES (p_org_id, 'meter_charge', p_doc_date, 'draft', p_notes)
    RETURNING id INTO v_doc_id;

    INSERT INTO private.doc_meter_charge (
        document_id, meter_id, contribution_type_id,
        reading_current, reading_previous, tariff_rate, amount
    ) VALUES (
        v_doc_id, p_meter_id, p_contribution_type_id,
        p_reading_current, p_reading_previous, p_tariff_rate, v_amount
    );

    RETURN jsonb_build_object(
        'ok', true,
        'document_id', v_doc_id,
        'status', 'draft',
        'consumption', p_reading_current - p_reading_previous,
        'amount', v_amount
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_meter_charge(uuid, uuid, uuid, numeric, numeric, numeric, date, text) TO app_admin, authenticated;
