-- =============================================================================
-- Migration 020: Fix api.unpost_meter_reading + api.create_meter_charge
-- Bugs fixed:
--   1. unpost_meter_reading: cascade to ownership docs did not recalculate
--      actuality_moment / actuality_document_id on organizations (critical).
--   2. create_meter_charge: meter-not-found raised 'ORG_MISMATCH' instead of
--      'METER_NOT_FOUND' (minor).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Fix 1: api.unpost_meter_reading — add actuality recalculation after cascade
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.unpost_meter_reading(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org           UUID;
    v_doc               private.documents%ROWTYPE;
    v_org               UUID;
    v_boundary          TIMESTAMPTZ;
    v_locked_until      DATE;
    v_cascade_ids       UUID[];
    v_cascade_n         INT;
    v_readings_removed  INT;
    v_movements_removed INT;
    v_new_moment        TIMESTAMPTZ;
    v_new_doc_id        UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_doc
    FROM private.documents
    WHERE id = p_doc_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: документ % не найден', p_doc_id;
    END IF;

    IF v_ctx_org IS NOT NULL AND v_doc.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_doc.doc_type <> 'meter_reading' THEN
        RAISE EXCEPTION 'WRONG_DOC_TYPE: ожидается meter_reading, получено %', v_doc.doc_type;
    END IF;

    IF v_doc.status <> 'posted' THEN
        RAISE EXCEPTION 'NOT_POSTED: можно отменить только проведённый документ, текущий статус: %', v_doc.status;
    END IF;

    v_org      := v_doc.organization_id;
    v_boundary := v_doc.posted_at;

    IF v_boundary IS NULL THEN
        RAISE EXCEPTION 'MISSING_POSTED_AT: у документа нет posted_at';
    END IF;

    SELECT pl.locked_until INTO v_locked_until
    FROM private.period_locks pl
    WHERE pl.organization_id = v_org;

    IF v_locked_until IS NOT NULL AND v_doc.doc_date <= v_locked_until THEN
        RAISE EXCEPTION 'PERIOD_LOCKED: дата документа в закрытом периоде (locked_until=%)', v_locked_until;
    END IF;

    WITH upd AS (
        UPDATE private.documents d
        SET status    = 'draft',
            posted_at = NULL
        WHERE d.organization_id = v_org
          AND d.status          = 'posted'
          AND d.posted_at       >= v_boundary
        RETURNING d.id
    )
    SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_cascade_ids
    FROM upd;

    v_cascade_n := cardinality(v_cascade_ids);

    DELETE FROM private.meter_readings
    WHERE document_id = ANY(v_cascade_ids);
    GET DIAGNOSTICS v_readings_removed = ROW_COUNT;

    DELETE FROM private.debt_movements
    WHERE document_id = ANY(v_cascade_ids);
    GET DIAGNOSTICS v_movements_removed = ROW_COUNT;

    UPDATE private.doc_ownership
    SET status = 'draft'
    WHERE document_id = ANY(v_cascade_ids);

    -- Пересчитываем actuality по последнему оставшемуся posted ownership-документу
    SELECT d.id, d.posted_at
    INTO v_new_doc_id, v_new_moment
    FROM private.documents d
    WHERE d.organization_id = v_org
      AND d.doc_type        = 'ownership'
      AND d.status          = 'posted'
    ORDER BY d.posted_at DESC NULLS LAST
    LIMIT 1;

    UPDATE private.organizations o
    SET actuality_moment      = v_new_moment,
        actuality_document_id = v_new_doc_id
    WHERE o.id = v_org;

    RETURN jsonb_build_object(
        'ok',                        true,
        'doc_id',                    p_doc_id,
        'boundary_posted_at',        v_boundary,
        'cascade_documents',         v_cascade_n,
        'meter_readings_removed',    v_readings_removed,
        'debt_movements_removed',    v_movements_removed,
        'new_actuality_moment',      v_new_moment,
        'new_actuality_document_id', v_new_doc_id
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.unpost_meter_reading(UUID) TO authenticated;
REVOKE EXECUTE ON FUNCTION api.unpost_meter_reading(UUID) FROM anon;

COMMENT ON FUNCTION api.unpost_meter_reading(UUID) IS
    'Отмена проведения показания счётчика; каскад по documents.posted_at внутри организации; actuality_moment и actuality_document_id пересчитываются по последнему оставшемуся posted ownership-документу.';

-- ---------------------------------------------------------------------------
-- Fix 2: api.create_meter_charge — неверный код ошибки при METER_NOT_FOUND
-- ---------------------------------------------------------------------------
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

    SELECT meter_type::private.meter_type_enum INTO v_meter_type
    FROM private.meters
    WHERE id = p_meter_id AND organization_id = p_org_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'METER_NOT_FOUND: счётчик % не найден в организации %', p_meter_id, p_org_id;
    END IF;

    SELECT id INTO v_ct_id
    FROM private.contribution_types
    WHERE organization_id = p_org_id
      AND kind            = 'meter'
      AND meter_type      = v_meter_type
      AND is_active       = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_METER_CONTRIBUTION_TYPE: нет вида взноса kind=''meter'' для типа счётчика %', v_meter_type;
    END IF;

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

    SELECT rate INTO v_rate
    FROM private.tariffs
    WHERE contribution_type_id = v_ct_id
      AND valid_from           <= p_doc_date
    ORDER BY valid_from DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_TARIFF_FOR_DATE: нет тарифа для вида взноса % на дату %', v_ct_id, p_doc_date;
    END IF;

    v_amount := ROUND((v_curr - v_prev) * v_rate, 2);

    IF v_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: сумма % должна быть > 0 (current=%, previous=%, rate=%)',
            v_amount, v_curr, v_prev, v_rate;
    END IF;

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

NOTIFY pgrst, 'reload schema';
