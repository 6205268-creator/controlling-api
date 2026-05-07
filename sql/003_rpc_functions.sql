-- =============================================================================
-- Migration 003: RPC functions for document posting (business operations)
-- All functions are in api schema → exposed by PostgREST as POST /rpc/<name>
-- SECURITY DEFINER → runs as postgres, bypasses RLS
-- Return format: {"ok": true, "document_id": "..."} or {"ok": false, "error": "CODE"}
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Helper: _assert_draft — validates doc exists, correct type, is draft
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private._assert_draft(
    p_doc_id  UUID,
    p_type    TEXT
) RETURNS private.documents LANGUAGE plpgsql AS $$
DECLARE v_doc private.documents%ROWTYPE;
BEGIN
    SELECT * INTO v_doc FROM private.documents WHERE id = p_doc_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOCUMENT_NOT_FOUND: %', p_doc_id;
    END IF;
    IF v_doc.doc_type <> p_type THEN
        RAISE EXCEPTION 'WRONG_DOC_TYPE: expected % got %', p_type, v_doc.doc_type;
    END IF;
    IF v_doc.status <> 'draft' THEN
        RAISE EXCEPTION 'DOCUMENT_NOT_DRAFT: current status is %', v_doc.status;
    END IF;
    RETURN v_doc;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. post_payment — Проведение Платежа
--    Деньги контрагента → лицевой счёт (account_movements +)
--    Аналог ОбработкаПроведения Документ.Платёж → РН.СчетКонтрагента
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.post_payment(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc    private.documents%ROWTYPE;
    v_detail private.doc_payment%ROWTYPE;
BEGIN
    v_doc := private._assert_draft(p_doc_id, 'payment');

    SELECT * INTO v_detail FROM private.doc_payment WHERE document_id = p_doc_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_DETAIL_MISSING: no doc_payment row for %', p_doc_id;
    END IF;

    -- Зачислить на лицевой счёт (положительная сумма = деньги пришли)
    INSERT INTO private.account_movements (
        organization_id, document_id, document_type,
        contractor_id, amount, period
    ) VALUES (
        v_doc.organization_id, v_doc.id, 'payment',
        v_detail.contractor_id, v_detail.amount, v_doc.doc_date
    );

    UPDATE private.documents SET status = 'posted', posted_at = NOW() WHERE id = p_doc_id;

    RETURN jsonb_build_object('ok', true, 'document_id', p_doc_id);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION api.post_payment IS
    'POST /rpc/post_payment {"p_doc_id":"UUID"} — проводит платёж → account_movements';

-- ---------------------------------------------------------------------------
-- 2. post_accrual — Проведение Начисления взносов
--    Долги финобъектов → debt_movements (+ для каждой строки)
--    Аналог ОбработкаПроведения Документ.НачислениеВзносов → РН.ЗадолженностиПлательщиков
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.post_accrual(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc    private.documents%ROWTYPE;
    v_hdr    private.doc_accrual%ROWTYPE;
    v_line   private.doc_accrual_lines%ROWTYPE;
    v_count  INT := 0;
BEGIN
    v_doc := private._assert_draft(p_doc_id, 'accrual');

    SELECT * INTO v_hdr FROM private.doc_accrual WHERE document_id = p_doc_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACCRUAL_HEADER_MISSING: no doc_accrual row for %', p_doc_id;
    END IF;

    -- Вставить движения по задолженностям для каждой строки
    FOR v_line IN SELECT * FROM private.doc_accrual_lines WHERE document_id = p_doc_id LOOP
        INSERT INTO private.debt_movements (
            organization_id, document_id, document_type,
            object_type, object_id, contribution_type_id,
            amount, period
        ) VALUES (
            v_doc.organization_id, v_doc.id, 'accrual',
            v_line.object_type, v_line.object_id, v_hdr.contribution_type_id,
            v_line.amount, v_hdr.period
        );
        v_count := v_count + 1;
    END LOOP;

    IF v_count = 0 THEN
        RAISE EXCEPTION 'ACCRUAL_NO_LINES: document % has no accrual lines', p_doc_id;
    END IF;

    UPDATE private.documents SET status = 'posted', posted_at = NOW() WHERE id = p_doc_id;

    RETURN jsonb_build_object('ok', true, 'document_id', p_doc_id, 'lines_posted', v_count);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION api.post_accrual IS
    'POST /rpc/post_accrual {"p_doc_id":"UUID"} — проводит начисление взносов → debt_movements';

-- ---------------------------------------------------------------------------
-- 3. post_distribution — Проведение Распределения платежей
--    Гасим долги финобъектов за счёт лицевого счёта контрагента
--    debt_movements (- по каждой строке) + account_movements (- суммарно)
--    Аналог ОбработкаПроведения Документ.РаспределениеПлатежей
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

    -- Считаем сумму строк
    SELECT COALESCE(SUM(amount), 0) INTO v_total
    FROM private.doc_distribution_lines WHERE document_id = p_doc_id;

    IF v_total = 0 THEN
        RAISE EXCEPTION 'DISTRIBUTION_NO_LINES: document % has no distribution lines', p_doc_id;
    END IF;

    -- Проверяем достаточность лицевого счёта
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

    -- Списываем с лицевого счёта: account_movements с отрицательной суммой
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

COMMENT ON FUNCTION api.post_distribution IS
    'POST /rpc/post_distribution {"p_doc_id":"UUID"} — распределяет платёж по долгам';

-- ---------------------------------------------------------------------------
-- 4. post_meter_reading — Проведение ПоказанийСчётчика
--    Записывает показание в meter_readings
--    Аналог ОбработкаПроведения Документ.ПоказанияСчётчиков → РС.ПоказанияСчётчиков
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.post_meter_reading(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc    private.documents%ROWTYPE;
    v_detail private.doc_meter_reading%ROWTYPE;
BEGIN
    v_doc := private._assert_draft(p_doc_id, 'meter_reading');

    SELECT * INTO v_detail FROM private.doc_meter_reading WHERE document_id = p_doc_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'METER_READING_DETAIL_MISSING: no doc_meter_reading for %', p_doc_id;
    END IF;

    -- Проверка: показание не меньше предыдущего
    IF EXISTS (
        SELECT 1 FROM private.meter_readings
        WHERE meter_id = v_detail.meter_id
          AND period <= v_detail.reading_date
          AND reading > v_detail.reading_value
        LIMIT 1
    ) THEN
        RAISE EXCEPTION 'READING_LESS_THAN_PREVIOUS: new reading %.3f is less than a prior reading',
            v_detail.reading_value;
    END IF;

    INSERT INTO private.meter_readings (
        meter_id, organization_id, period, reading, document_id
    ) VALUES (
        v_detail.meter_id, v_doc.organization_id,
        v_detail.reading_date, v_detail.reading_value, v_doc.id
    )
    ON CONFLICT (meter_id, period) DO UPDATE
        SET reading = EXCLUDED.reading,
            document_id = EXCLUDED.document_id;

    UPDATE private.documents SET status = 'posted', posted_at = NOW() WHERE id = p_doc_id;

    RETURN jsonb_build_object('ok', true, 'document_id', p_doc_id);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION api.post_meter_reading IS
    'POST /rpc/post_meter_reading {"p_doc_id":"UUID"} — записывает показание счётчика';

-- ---------------------------------------------------------------------------
-- 5. post_meter_charge — Проведение НачисленияПоСчётчику
--    Создаёт долг по счётчику: debt_movements для meter-объекта
--    Аналог ОбработкаПроведения Документ.НачислениеПоСчётчику
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.post_meter_charge(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc    private.documents%ROWTYPE;
    v_detail private.doc_meter_charge%ROWTYPE;
BEGIN
    v_doc := private._assert_draft(p_doc_id, 'meter_charge');

    SELECT * INTO v_detail FROM private.doc_meter_charge WHERE document_id = p_doc_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'METER_CHARGE_DETAIL_MISSING: no doc_meter_charge for %', p_doc_id;
    END IF;

    -- Создать долг по счётчику (meter = тип финансового объекта)
    INSERT INTO private.debt_movements (
        organization_id, document_id, document_type,
        object_type, object_id, contribution_type_id,
        amount, period
    ) VALUES (
        v_doc.organization_id, v_doc.id, 'meter_charge',
        'meter', v_detail.meter_id, v_detail.contribution_type_id,
        v_detail.amount, v_doc.doc_date
    );

    UPDATE private.documents SET status = 'posted', posted_at = NOW() WHERE id = p_doc_id;

    RETURN jsonb_build_object('ok', true, 'document_id', p_doc_id,
        'amount', v_detail.amount);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION api.post_meter_charge IS
    'POST /rpc/post_meter_charge {"p_doc_id":"UUID"} — начисляет долг по счётчику';

-- ---------------------------------------------------------------------------
-- 6. post_period_close — Закрытие периода
--    UPSERT в period_locks — блокирует изменения задним числом
--    Аналог ОбработкаПроведения Документ.ЗакрытиеПериода → РС.ДатыЗапретаИзменения
-- ---------------------------------------------------------------------------

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

    -- Блокируем период: UPSERT — если уже есть, расширяем до большей даты
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

COMMENT ON FUNCTION api.post_period_close IS
    'POST /rpc/post_period_close {"p_doc_id":"UUID"} — закрывает период (запрет задним числом)';

-- ---------------------------------------------------------------------------
-- 7. cancel_document — Сторно / отмена проведённого документа
--    Создаёт обратные движения (is_reversal=true) и переводит в статус cancelled
--    Аналог Отмена проведения + ОбработкаУдаленияПроведения
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.cancel_document(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc    private.documents%ROWTYPE;
    v_am     RECORD;  -- account_movements
    v_dm     RECORD;  -- debt_movements
    v_mr_doc UUID;
BEGIN
    SELECT * INTO v_doc FROM private.documents WHERE id = p_doc_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOCUMENT_NOT_FOUND: %', p_doc_id;
    END IF;
    IF v_doc.status <> 'posted' THEN
        RAISE EXCEPTION 'DOCUMENT_NOT_POSTED: can only cancel posted documents, status=%', v_doc.status;
    END IF;

    -- Сторно account_movements (зеркальные записи с is_reversal=true)
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

    -- Сторно debt_movements (зеркальные записи с is_reversal=true)
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

    -- Для meter_reading: удаляем запись из meter_readings (показания пересчитаются)
    IF v_doc.doc_type = 'meter_reading' THEN
        UPDATE private.meter_readings
        SET document_id = NULL
        WHERE document_id = p_doc_id;
    END IF;

    -- Для period_close: удаляем блокировку (разблокируем период)
    IF v_doc.doc_type = 'period_close' THEN
        DELETE FROM private.period_locks
        WHERE organization_id = v_doc.organization_id;
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

COMMENT ON FUNCTION api.cancel_document IS
    'POST /rpc/cancel_document {"p_doc_id":"UUID"} — сторно документа, обратные движения';

-- ---------------------------------------------------------------------------
-- 8. create_accrual_batch — Создать начисление взносов пакетом по всем участкам
--    Хелпер: создаёт документ + строки для всех активных объектов заданного типа
--    Аналог Заполнить ТЧ по списку финобъектов
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_accrual_batch(
    p_org_id             UUID,
    p_contribution_type  UUID,
    p_period             DATE,
    p_object_type        private.fin_object_type,  -- 'plot', 'member', 'meter'
    p_amount_per_object  NUMERIC(15,2),
    p_created_by         UUID DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc_id  UUID;
    v_count   INT := 0;
    v_obj     RECORD;
BEGIN
    -- Создаём документ
    INSERT INTO private.documents (organization_id, doc_type, doc_date, status, created_by)
    VALUES (p_org_id, 'accrual', p_period, 'draft', p_created_by)
    RETURNING id INTO v_doc_id;

    -- Шапка начисления
    INSERT INTO private.doc_accrual (document_id, period, contribution_type_id)
    VALUES (v_doc_id, p_period, p_contribution_type);

    -- Строки: берём все активные финобъекты заданного типа
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

COMMENT ON FUNCTION api.create_accrual_batch IS
    'POST /rpc/create_accrual_batch — создаёт черновик начисления по всем объектам';

-- ---------------------------------------------------------------------------
-- 9. create_payment — Создать документ Платёж (черновик)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_payment(
    p_org_id        UUID,
    p_contractor_id UUID,
    p_amount        NUMERIC(15,2),
    p_doc_date      DATE DEFAULT CURRENT_DATE,
    p_payment_ref   TEXT DEFAULT NULL,
    p_notes         TEXT DEFAULT NULL,
    p_created_by    UUID DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_doc_id UUID;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: amount must be > 0, got %', p_amount;
    END IF;

    INSERT INTO private.documents (organization_id, doc_type, doc_date, status, notes, created_by)
    VALUES (p_org_id, 'payment', p_doc_date, 'draft', p_notes, p_created_by)
    RETURNING id INTO v_doc_id;

    INSERT INTO private.doc_payment (document_id, contractor_id, amount, payment_ref)
    VALUES (v_doc_id, p_contractor_id, p_amount, p_payment_ref);

    RETURN jsonb_build_object('ok', true, 'document_id', v_doc_id, 'status', 'draft');

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

COMMENT ON FUNCTION api.create_payment IS
    'POST /rpc/create_payment — создаёт черновик платежа (потом post_payment)';

-- ---------------------------------------------------------------------------
-- Grants: authenticated role может вызывать RPC через PostgREST
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION api.post_payment(UUID)            TO authenticated;
GRANT EXECUTE ON FUNCTION api.post_accrual(UUID)            TO authenticated;
GRANT EXECUTE ON FUNCTION api.post_distribution(UUID)       TO authenticated;
GRANT EXECUTE ON FUNCTION api.post_meter_reading(UUID)      TO authenticated;
GRANT EXECUTE ON FUNCTION api.post_meter_charge(UUID)       TO authenticated;
GRANT EXECUTE ON FUNCTION api.post_period_close(UUID)       TO authenticated;
GRANT EXECUTE ON FUNCTION api.cancel_document(UUID)         TO authenticated;
GRANT EXECUTE ON FUNCTION api.create_accrual_batch(UUID, UUID, DATE, private.fin_object_type, NUMERIC, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION api.create_payment(UUID, UUID, NUMERIC, DATE, TEXT, TEXT, UUID) TO authenticated;
