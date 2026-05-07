-- =============================================================================
-- Migration 005: Critical & High bug fixes + create_distribution
-- Fixes found by cross-review of migrations 003-004
-- =============================================================================

-- ---------------------------------------------------------------------------
-- FIX CRITICAL-3: post_distribution — race condition
-- Advisory lock per contractor before balance check
-- FIX HIGH-1: check v_count after loop
-- FIX HIGH-4: doc_journal — add sum for accrual + distribution
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.post_distribution(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc         private.documents%ROWTYPE;
    v_hdr         private.doc_distribution%ROWTYPE;
    v_line        private.doc_distribution_lines%ROWTYPE;
    v_total       NUMERIC(15,2) := 0;
    v_balance     NUMERIC(15,2);
    v_count       INT := 0;
BEGIN
    v_doc := private._assert_draft(p_doc_id, 'distribution');

    SELECT * INTO v_hdr FROM private.doc_distribution WHERE document_id = p_doc_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DISTRIBUTION_HEADER_MISSING: no doc_distribution row for %', p_doc_id;
    END IF;

    -- Advisory lock per contractor: исключаем race condition при параллельных вызовах
    PERFORM pg_advisory_xact_lock(hashtext(v_hdr.contractor_id::text));

    -- Считаем сумму строк
    SELECT COALESCE(SUM(amount), 0) INTO v_total
    FROM private.doc_distribution_lines WHERE document_id = p_doc_id;

    IF v_total = 0 THEN
        RAISE EXCEPTION 'DISTRIBUTION_NO_LINES: document % has no distribution lines', p_doc_id;
    END IF;

    -- Проверяем достаточность лицевого счёта (после блокировки — безопасно)
    v_balance := private.account_balance(v_doc.organization_id, v_hdr.contractor_id);
    IF v_balance < v_total THEN
        RAISE EXCEPTION 'INSUFFICIENT_BALANCE: account balance %.2f < distribution total %.2f',
            v_balance, v_total;
    END IF;

    -- Гасим долги: debt_movements с отрицательной суммой (долг уменьшается)
    FOR v_line IN SELECT * FROM private.doc_distribution_lines WHERE document_id = p_doc_id LOOP
        INSERT INTO private.debt_movements (
            organization_id, document_id, document_type,
            object_type, object_id, contribution_type_id,
            amount, period
        ) VALUES (
            v_doc.organization_id, v_doc.id, 'distribution',
            v_line.object_type, v_line.object_id, v_line.contribution_type_id,
            -v_line.amount, v_doc.doc_date
        );
        v_count := v_count + 1;
    END LOOP;

    IF v_count = 0 THEN
        RAISE EXCEPTION 'DISTRIBUTION_ZERO_LINES: no lines were processed for %', p_doc_id;
    END IF;

    -- Списываем с лицевого счёта суммарно
    INSERT INTO private.account_movements (
        organization_id, document_id, document_type,
        contractor_id, amount, period
    ) VALUES (
        v_doc.organization_id, v_doc.id, 'distribution',
        v_hdr.contractor_id, -v_total, v_doc.doc_date
    );

    UPDATE private.documents SET status = 'posted', posted_at = NOW() WHERE id = p_doc_id;

    RETURN jsonb_build_object('ok', true, 'document_id', p_doc_id,
        'lines_posted', v_count, 'total_distributed', v_total);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- FIX CRITICAL-2: cancel meter_reading — DELETE, not NULL document_id
-- FIX CRITICAL-1: cancel period_close — recalculate locked_until from remaining posted docs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.cancel_document(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc          private.documents%ROWTYPE;
    v_am           RECORD;
    v_dm           RECORD;
    v_new_lock     DATE;
BEGIN
    SELECT * INTO v_doc FROM private.documents WHERE id = p_doc_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOCUMENT_NOT_FOUND: %', p_doc_id;
    END IF;
    IF v_doc.status <> 'posted' THEN
        RAISE EXCEPTION 'DOCUMENT_NOT_POSTED: can only cancel posted documents, status=%', v_doc.status;
    END IF;

    -- Сторно account_movements
    FOR v_am IN
        SELECT * FROM private.account_movements WHERE document_id = p_doc_id AND NOT is_reversal
    LOOP
        INSERT INTO private.account_movements (
            organization_id, document_id, document_type,
            contractor_id, amount, period, is_reversal
        ) VALUES (
            v_am.organization_id, v_doc.id, v_doc.doc_type,
            v_am.contractor_id, -v_am.amount, v_am.period, TRUE
        );
    END LOOP;

    -- Сторно debt_movements
    FOR v_dm IN
        SELECT * FROM private.debt_movements WHERE document_id = p_doc_id AND NOT is_reversal
    LOOP
        INSERT INTO private.debt_movements (
            organization_id, document_id, document_type,
            object_type, object_id, contribution_type_id,
            amount, period, is_reversal
        ) VALUES (
            v_dm.organization_id, v_doc.id, v_doc.doc_type,
            v_dm.object_type, v_dm.object_id, v_dm.contribution_type_id,
            -v_dm.amount, v_dm.period, TRUE
        );
    END LOOP;

    -- FIX CRITICAL-2: meter_reading — DELETE показание (регистр сведений, не накопления)
    IF v_doc.doc_type = 'meter_reading' THEN
        DELETE FROM private.meter_readings WHERE document_id = p_doc_id;
    END IF;

    -- FIX CRITICAL-1: period_close — пересчитываем замок из оставшихся posted документов
    IF v_doc.doc_type = 'period_close' THEN
        SELECT MAX(dpc.closing_period) INTO v_new_lock
        FROM private.doc_period_close dpc
        JOIN private.documents d ON d.id = dpc.document_id
        WHERE d.organization_id = v_doc.organization_id
          AND d.status = 'posted'
          AND d.id <> p_doc_id;

        IF v_new_lock IS NULL THEN
            -- Нет других posted period_close — снимаем замок полностью
            DELETE FROM private.period_locks WHERE organization_id = v_doc.organization_id;
        ELSE
            -- Обновляем замок до максимального оставшегося периода
            UPDATE private.period_locks
            SET locked_until = v_new_lock, locked_at = NOW()
            WHERE organization_id = v_doc.organization_id;
        END IF;
    END IF;

    UPDATE private.documents
    SET status = 'cancelled', cancelled_at = NOW()
    WHERE id = p_doc_id;

    RETURN jsonb_build_object('ok', true, 'document_id', p_doc_id,
        'cancelled_doc_type', v_doc.doc_type);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- FIX HIGH-2: post_meter_reading — монотонность в обе стороны
-- FIX LOW-1: не перезаписываем posted показание
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.post_meter_reading(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc       private.documents%ROWTYPE;
    v_detail    private.doc_meter_reading%ROWTYPE;
    v_existing  private.meter_readings%ROWTYPE;
BEGIN
    v_doc := private._assert_draft(p_doc_id, 'meter_reading');

    SELECT * INTO v_detail FROM private.doc_meter_reading WHERE document_id = p_doc_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'METER_READING_DETAIL_MISSING: no doc_meter_reading for %', p_doc_id;
    END IF;

    -- Проверка: нет ли более ранней записи с бОльшим показанием (счётчик не может убывать)
    IF EXISTS (
        SELECT 1 FROM private.meter_readings
        WHERE meter_id = v_detail.meter_id
          AND period < v_detail.reading_date
          AND reading > v_detail.reading_value
    ) THEN
        RAISE EXCEPTION 'READING_LESS_THAN_PREVIOUS: new reading %.3f is less than a prior reading',
            v_detail.reading_value;
    END IF;

    -- Проверка: нет ли более поздней записи с меньшим показанием
    IF EXISTS (
        SELECT 1 FROM private.meter_readings
        WHERE meter_id = v_detail.meter_id
          AND period > v_detail.reading_date
          AND reading < v_detail.reading_value
    ) THEN
        RAISE EXCEPTION 'READING_GREATER_THAN_FUTURE: new reading %.3f exceeds a later reading',
            v_detail.reading_value;
    END IF;

    -- Проверка: если запись уже есть — она не должна быть от posted документа
    SELECT mr.* INTO v_existing
    FROM private.meter_readings mr
    WHERE mr.meter_id = v_detail.meter_id AND mr.period = v_detail.reading_date;

    IF FOUND AND v_existing.document_id IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM private.documents
            WHERE id = v_existing.document_id AND status = 'posted'
        ) THEN
            RAISE EXCEPTION
                'READING_ALREADY_POSTED: period % already has a posted reading from document %',
                v_detail.reading_date, v_existing.document_id;
        END IF;
    END IF;

    INSERT INTO private.meter_readings (
        meter_id, organization_id, period, reading, document_id
    ) VALUES (
        v_detail.meter_id, v_doc.organization_id,
        v_detail.reading_date, v_detail.reading_value, v_doc.id
    )
    ON CONFLICT (meter_id, period) DO UPDATE
        SET reading     = EXCLUDED.reading,
            document_id = EXCLUDED.document_id;

    UPDATE private.documents SET status = 'posted', posted_at = NOW() WHERE id = p_doc_id;

    RETURN jsonb_build_object('ok', true, 'document_id', p_doc_id);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- FIX MEDIUM-1: create_accrual_batch — RAISE если нет объектов
-- FIX MEDIUM-2: post_period_close — валидация диапазона даты
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_accrual_batch(
    p_org_id             UUID,
    p_contribution_type  UUID,
    p_period             DATE,
    p_object_type        private.fin_object_type,
    p_amount_per_object  NUMERIC(15,2),
    p_created_by         UUID DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc_id  UUID;
    v_count   INT := 0;
    v_obj     RECORD;
BEGIN
    INSERT INTO private.documents (organization_id, doc_type, doc_date, status, created_by)
    VALUES (p_org_id, 'accrual', p_period, 'draft', p_created_by)
    RETURNING id INTO v_doc_id;

    INSERT INTO private.doc_accrual (document_id, period, contribution_type_id)
    VALUES (v_doc_id, p_period, p_contribution_type);

    IF p_object_type = 'plot' THEN
        FOR v_obj IN SELECT id FROM private.plots
                     WHERE organization_id = p_org_id AND is_active LOOP
            INSERT INTO private.doc_accrual_lines (document_id, object_type, object_id, amount)
            VALUES (v_doc_id, 'plot', v_obj.id, p_amount_per_object);
            v_count := v_count + 1;
        END LOOP;
    ELSIF p_object_type = 'member' THEN
        FOR v_obj IN SELECT id FROM private.members
                     WHERE organization_id = p_org_id AND is_active LOOP
            INSERT INTO private.doc_accrual_lines (document_id, object_type, object_id, amount)
            VALUES (v_doc_id, 'member', v_obj.id, p_amount_per_object);
            v_count := v_count + 1;
        END LOOP;
    ELSIF p_object_type = 'meter' THEN
        FOR v_obj IN SELECT id FROM private.meters
                     WHERE organization_id = p_org_id AND is_active LOOP
            INSERT INTO private.doc_accrual_lines (document_id, object_type, object_id, amount)
            VALUES (v_doc_id, 'meter', v_obj.id, p_amount_per_object);
            v_count := v_count + 1;
        END LOOP;
    END IF;

    -- FIX MEDIUM-1: если нет объектов — откатить и сообщить
    IF v_count = 0 THEN
        RAISE EXCEPTION 'NO_ACTIVE_OBJECTS: no active % found for organization %',
            p_object_type, p_org_id;
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'document_id', v_doc_id,
        'lines_created', v_count,
        'status', 'draft'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION api.post_period_close(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc    private.documents%ROWTYPE;
    v_detail private.doc_period_close%ROWTYPE;
BEGIN
    v_doc := private._assert_draft(p_doc_id, 'period_close');

    SELECT * INTO v_detail FROM private.doc_period_close WHERE document_id = p_doc_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PERIOD_CLOSE_DETAIL_MISSING: no doc_period_close for %', p_doc_id;
    END IF;

    -- FIX MEDIUM-2: валидация диапазона — не закрывать дату далеко в будущем
    IF v_detail.closing_period > CURRENT_DATE + INTERVAL '1 year' THEN
        RAISE EXCEPTION 'INVALID_CLOSING_PERIOD: closing_period % is too far in the future',
            v_detail.closing_period;
    END IF;
    IF v_detail.closing_period < '2000-01-01'::DATE THEN
        RAISE EXCEPTION 'INVALID_CLOSING_PERIOD: closing_period % is too far in the past',
            v_detail.closing_period;
    END IF;

    INSERT INTO private.period_locks (organization_id, locked_until, locked_by)
    VALUES (v_doc.organization_id, v_detail.closing_period, v_doc.created_by)
    ON CONFLICT (organization_id) DO UPDATE
        SET locked_until = GREATEST(period_locks.locked_until, EXCLUDED.locked_until),
            locked_at    = NOW(),
            locked_by    = EXCLUDED.locked_by;

    UPDATE private.documents SET status = 'posted', posted_at = NOW() WHERE id = p_doc_id;

    RETURN jsonb_build_object('ok', true, 'document_id', p_doc_id,
        'locked_until', v_detail.closing_period);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- FIX MEDIUM-3: plot_summary — фильтрация долгов по organization_id
-- FIX HIGH-4: doc_journal — суммы для accrual и distribution
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.plot_summary;
CREATE VIEW api.plot_summary AS
SELECT
    p.id,
    p.organization_id,
    p.number,
    p.area,
    p.is_active,
    c.id         AS owner_id,
    c.full_name  AS owner_name,
    c.phone      AS owner_phone,
    COALESCE(d.total_debt, 0) AS total_debt
FROM private.plots p
LEFT JOIN private.contractors c ON c.id = p.owner_id
LEFT JOIN (
    SELECT object_id, organization_id, SUM(amount) AS total_debt
    FROM private.debt_movements
    WHERE object_type = 'plot'
    GROUP BY object_id, organization_id
) d ON d.object_id = p.id AND d.organization_id = p.organization_id;  -- FIX: фильтр по орг

GRANT SELECT ON api.plot_summary TO anon, authenticated;

DROP VIEW IF EXISTS api.doc_journal;
CREATE VIEW api.doc_journal AS
SELECT
    d.id,
    d.organization_id,
    d.doc_type,
    d.doc_date,
    d.status,
    d.notes,
    d.created_at,
    d.posted_at,
    d.cancelled_at,
    d.parent_id,
    CASE d.doc_type
        WHEN 'payment'      THEN dp.amount
        WHEN 'meter_charge' THEN mc.amount
        WHEN 'distribution' THEN (
            SELECT SUM(l.amount) FROM private.doc_distribution_lines l
            WHERE l.document_id = d.id
        )
        WHEN 'accrual'      THEN (
            SELECT SUM(l.amount) FROM private.doc_accrual_lines l
            WHERE l.document_id = d.id
        )
        ELSE NULL
    END AS amount,
    CASE d.doc_type
        WHEN 'payment'      THEN c_pay.full_name
        WHEN 'distribution' THEN c_dist.full_name
        ELSE NULL
    END AS contractor_name,
    CASE d.doc_type
        WHEN 'accrual'      THEN da.period
        WHEN 'period_close' THEN dpc.closing_period
        ELSE NULL
    END AS period
FROM private.documents d
LEFT JOIN private.doc_payment       dp   ON dp.document_id = d.id
LEFT JOIN private.doc_distribution  ddi  ON ddi.document_id = d.id
LEFT JOIN private.doc_meter_charge  mc   ON mc.document_id = d.id
LEFT JOIN private.doc_accrual       da   ON da.document_id = d.id
LEFT JOIN private.doc_period_close  dpc  ON dpc.document_id = d.id
LEFT JOIN private.contractors       c_pay  ON c_pay.id = dp.contractor_id
LEFT JOIN private.contractors       c_dist ON c_dist.id = ddi.contractor_id;

GRANT SELECT ON api.doc_journal TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- NEW: create_distribution — создать черновик распределения платежей
-- Аналог создания документа РаспределениеПлатежей в 1С
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_distribution(
    p_org_id        UUID,
    p_contractor_id UUID,
    p_doc_date      DATE DEFAULT CURRENT_DATE,
    p_notes         TEXT DEFAULT NULL,
    p_created_by    UUID DEFAULT NULL,
    -- Строки распределения: [{object_type, object_id, contribution_type_id, amount}]
    p_lines         JSONB DEFAULT '[]'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc_id   UUID;
    v_line     JSONB;
    v_count    INT := 0;
    v_total    NUMERIC(15,2) := 0;
    v_balance  NUMERIC(15,2);
BEGIN
    -- Проверить что контрагент принадлежит организации
    IF NOT EXISTS (
        SELECT 1 FROM private.contractors
        WHERE id = p_contractor_id AND organization_id = p_org_id
    ) THEN
        RAISE EXCEPTION 'CONTRACTOR_NOT_FOUND: contractor % not in org %',
            p_contractor_id, p_org_id;
    END IF;

    -- Проверить достаточность баланса
    v_balance := private.account_balance(p_org_id, p_contractor_id);

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        v_total := v_total + (v_line->>'amount')::NUMERIC;
    END LOOP;

    IF v_total <= 0 THEN
        RAISE EXCEPTION 'DISTRIBUTION_EMPTY: total amount must be > 0';
    END IF;

    IF v_balance < v_total THEN
        RAISE EXCEPTION 'INSUFFICIENT_BALANCE: account balance %.2f < distribution total %.2f',
            v_balance, v_total;
    END IF;

    -- Создать документ
    INSERT INTO private.documents (organization_id, doc_type, doc_date, status, notes, created_by)
    VALUES (p_org_id, 'distribution', p_doc_date, 'draft', p_notes, p_created_by)
    RETURNING id INTO v_doc_id;

    INSERT INTO private.doc_distribution (document_id, contractor_id)
    VALUES (v_doc_id, p_contractor_id);

    -- Вставить строки
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        INSERT INTO private.doc_distribution_lines (
            document_id, object_type, object_id, contribution_type_id, amount
        ) VALUES (
            v_doc_id,
            (v_line->>'object_type')::private.fin_object_type,
            (v_line->>'object_id')::UUID,
            (v_line->>'contribution_type_id')::UUID,
            (v_line->>'amount')::NUMERIC
        );
        v_count := v_count + 1;
    END LOOP;

    IF v_count = 0 THEN
        RAISE EXCEPTION 'DISTRIBUTION_NO_LINES: p_lines is empty or invalid JSON';
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'document_id', v_doc_id,
        'lines_created', v_count,
        'total_to_distribute', v_total,
        'account_balance_before', v_balance,
        'status', 'draft'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_distribution(UUID, UUID, DATE, TEXT, UUID, JSONB)
    TO anon, authenticated;

GRANT EXECUTE ON FUNCTION api.post_distribution(UUID)         TO anon;
GRANT EXECUTE ON FUNCTION api.cancel_document(UUID)           TO anon;
GRANT EXECUTE ON FUNCTION api.post_meter_reading(UUID)        TO anon;
GRANT EXECUTE ON FUNCTION api.post_period_close(UUID)         TO anon;
GRANT EXECUTE ON FUNCTION api.create_accrual_batch(UUID, UUID, DATE, private.fin_object_type, NUMERIC, UUID) TO anon;
