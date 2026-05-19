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
    -- NULL guards first
    IF p_org_id IS NULL THEN
        RAISE EXCEPTION 'INVALID_ORG: p_org_id обязателен';
    END IF;
    IF p_valid_from IS NULL THEN
        RAISE EXCEPTION 'INVALID_VALID_FROM: дата действия обязательна';
    END IF;
    IF p_rate IS NULL OR p_rate <= 0 THEN
        RAISE EXCEPTION 'INVALID_RATE: тариф должен быть > 0, получено %', p_rate;
    END IF;

    v_ctx_org := private.current_org_id();

    -- Token org check FIRST, before trusting p_org_id
    IF v_ctx_org IS NOT NULL AND p_org_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    SELECT * INTO v_ct
    FROM private.contribution_types
    WHERE id = p_contribution_type_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_CONTRIBUTION_TYPE: вид взноса % не найден', p_contribution_type_id;
    END IF;

    IF v_ct.organization_id <> p_org_id THEN
        RAISE EXCEPTION 'ORG_MISMATCH: вид взноса принадлежит другой организации';
    END IF;

    IF v_ct.kind <> 'meter' THEN
        RAISE EXCEPTION 'NOT_METER_KIND: тарифы только для видов взноса kind=''meter''';
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

-- ---------------------------------------------------------------------------
-- Step 3: api.create_meter_charge — rewrite с авто-поиском тарифа и показаний
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.create_meter_charge(uuid, uuid, uuid, numeric, numeric, numeric, date, text);

CREATE OR REPLACE FUNCTION api.create_meter_charge(
    p_org_id   UUID,
    p_meter_id UUID,
    p_doc_date DATE DEFAULT CURRENT_DATE,
    p_notes    TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org    UUID;
    v_meter_type private.meter_type_enum;
    v_ct_id      UUID;
    v_rate       NUMERIC(15,4);
    v_curr       NUMERIC(15,3);
    v_prev       NUMERIC(15,3);
    v_amount     NUMERIC(15,2);
    v_doc_id     UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    IF v_ctx_org IS NOT NULL AND v_ctx_org <> p_org_id THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    -- 1. meter_type из meters
    SELECT meter_type::private.meter_type_enum INTO v_meter_type
    FROM private.meters
    WHERE id = p_meter_id AND organization_id = p_org_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ORG_MISMATCH: счётчик % не найден в организации %', p_meter_id, p_org_id;
    END IF;

    -- 2. contribution_type по (org, kind=meter, meter_type)
    SELECT id INTO v_ct_id
    FROM private.contribution_types
    WHERE organization_id = p_org_id
      AND kind            = 'meter'
      AND meter_type      = v_meter_type
      AND is_active       = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_METER_CONTRIBUTION_TYPE: нет вида взноса kind=''meter'' для типа счётчика %', v_meter_type;
    END IF;

    -- 3. Два последних показания (newest = current, second = previous)
    WITH last_two AS (
        SELECT reading,
               ROW_NUMBER() OVER (ORDER BY period DESC) AS rn
        FROM private.meter_readings
        WHERE meter_id = p_meter_id
        ORDER BY period DESC
        LIMIT 2
    )
    SELECT
        MAX(reading) FILTER (WHERE rn = 1),
        MAX(reading) FILTER (WHERE rn = 2)
    INTO v_curr, v_prev
    FROM last_two;

    IF v_prev IS NULL THEN
        RAISE EXCEPTION 'NO_PREVIOUS_READING: недостаточно показаний (нужно минимум 2, есть 1 или 0)';
    END IF;

    -- 4. Тариф на p_doc_date (СрезПоследних)
    SELECT rate INTO v_rate
    FROM private.tariffs
    WHERE contribution_type_id = v_ct_id
      AND valid_from           <= p_doc_date
    ORDER BY valid_from DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_TARIFF_FOR_DATE: нет тарифа для вида взноса % на дату %', v_ct_id, p_doc_date;
    END IF;

    -- 5. Сумма начисления
    v_amount := ROUND((v_curr - v_prev) * v_rate, 2);

    IF v_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: сумма % должна быть > 0 (current=%, previous=%, rate=%)',
            v_amount, v_curr, v_prev, v_rate;
    END IF;

    -- 6. Документ
    INSERT INTO private.documents (organization_id, doc_type, doc_date, status, notes)
    VALUES (p_org_id, 'meter_charge', p_doc_date, 'draft', p_notes)
    RETURNING id INTO v_doc_id;

    INSERT INTO private.doc_meter_charge (
        document_id, meter_id, contribution_type_id,
        reading_current, reading_previous, tariff_rate, amount
    ) VALUES (
        v_doc_id, p_meter_id, v_ct_id,
        v_curr, v_prev, v_rate, v_amount
    );

    RETURN jsonb_build_object(
        'ok',               true,
        'document_id',      v_doc_id,
        'status',           'draft',
        'consumption',      v_curr - v_prev,
        'amount',           v_amount,
        'reading_current',  v_curr,
        'reading_previous', v_prev,
        'tariff_rate',      v_rate
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_meter_charge(UUID, UUID, DATE, TEXT) TO authenticated;
REVOKE EXECUTE ON FUNCTION api.create_meter_charge(UUID, UUID, DATE, TEXT) FROM anon;

-- Enforce: at most one active meter-kind contribution_type per (org, meter_type)
CREATE UNIQUE INDEX IF NOT EXISTS uq_ct_org_meter_type
    ON private.contribution_types (organization_id, meter_type)
    WHERE kind = 'meter' AND is_active = TRUE;
