-- =============================================================================
-- Migration 012: Ownership journal + organizational actuality (schema draft)
-- Связывание doc_ownership с журналом documents, дата актуальности по организации.
-- Задачи 3–6 плана: RPC и доработки будут добавлены в этот же файл последующими шагами.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 1: Оперативная актуальность проведения по организации
-- ---------------------------------------------------------------------------

ALTER TABLE private.organizations
    ADD COLUMN IF NOT EXISTS actuality_moment TIMESTAMPTZ;

COMMENT ON COLUMN private.organizations.actuality_moment IS
    'Оперативная актуальность проведения по организации';

-- ---------------------------------------------------------------------------
-- Step 2: Расширить допустимые значения doc_type — 'ownership'
-- Имя ограничения: documents_doc_type_check (см. 002_doc_accrual.sql).
-- ---------------------------------------------------------------------------

ALTER TABLE private.documents
    DROP CONSTRAINT IF EXISTS documents_doc_type_check;

ALTER TABLE private.documents
    ADD CONSTRAINT documents_doc_type_check
    CHECK (doc_type IN (
        'payment',
        'distribution',
        'meter_reading',
        'meter_charge',
        'period_close',
        'meter_correction',
        'accrual',
        'ownership'
    ));

-- ---------------------------------------------------------------------------
-- Step 3: Связь строки владения с шапкой журнала + доли
-- ---------------------------------------------------------------------------

ALTER TABLE private.doc_ownership
    ADD COLUMN IF NOT EXISTS document_id UUID REFERENCES private.documents(id),
    ADD COLUMN IF NOT EXISTS shares INTEGER NOT NULL DEFAULT 1 CHECK (shares > 0);

-- ---------------------------------------------------------------------------
-- Step 4: Уникальность одной записи на (орг, объект, контрагент, дата документа).
-- Модель «одна строка doc_ownership на черновик»; при появлении табличной части
-- с несколькими строками на один document_id спецификацию уникальности может
-- потребоваться уточнить.
-- ---------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS doc_ownership_org_object_contractor_docdate_uq
    ON private.doc_ownership (
        organization_id,
        object_id,
        contractor_id,
        doc_date
    );

-- -----------------------------------------------------------------------------
-- Task 3: api.create_ownership — журнал documents + строка doc_ownership
-- Task 4: api.post_ownership — без financial_object_registry, period lock, actuality
-- Task 5: api.unpost_ownership — каскад по posted_at, actuality
-- Task 6: api.plot_summary — владелец из последнего проведённого ownership-документа
-- -----------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Task 3: create_ownership (REPLACE)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_ownership(
    p_org_id        UUID,
    p_contractor_id UUID,
    p_object_id     UUID,
    p_object_type   VARCHAR DEFAULT 'plot',
    p_doc_date      DATE    DEFAULT CURRENT_DATE,
    p_notes         TEXT    DEFAULT NULL,
    p_created_by    UUID    DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org UUID;
    v_journal_id UUID;
    v_own_id   UUID;
BEGIN
    v_ctx_org := private.current_org_id();
    IF v_ctx_org IS NOT NULL AND p_org_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    INSERT INTO private.documents (
        organization_id, doc_type, doc_date, status, notes, created_by
    ) VALUES (
        p_org_id, 'ownership', p_doc_date, 'draft', p_notes, p_created_by
    )
    RETURNING id INTO v_journal_id;

    INSERT INTO private.doc_ownership (
        organization_id, contractor_id, object_type, object_id,
        doc_date, notes, status, created_by,
        document_id, shares
    ) VALUES (
        p_org_id, p_contractor_id, p_object_type, p_object_id,
        p_doc_date, p_notes, 'draft', p_created_by,
        v_journal_id, 1
    )
    RETURNING id INTO v_own_id;

    RETURN jsonb_build_object(
        'ok', true,
        'doc_id', v_own_id,
        'document_id', v_journal_id,
        'status', 'draft'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_ownership(UUID, UUID, UUID, VARCHAR, DATE, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Task 4: post_ownership — p_doc_id = doc_ownership.id (совместимость)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.post_ownership(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_own        private.doc_ownership%ROWTYPE;
    v_journal    private.documents%ROWTYPE;
    v_ctx_org    UUID;
    v_contractor_type VARCHAR(20);
    v_max_num    INT;
    v_posted_ts  TIMESTAMPTZ;
    v_locked_until DATE;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_own
    FROM private.doc_ownership
    WHERE id = p_doc_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: документ % не найден', p_doc_id;
    END IF;

    IF v_ctx_org IS NOT NULL AND v_own.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_own.document_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'MISSING_DOCUMENT_LINK');
    END IF;

    IF v_own.status = 'posted' THEN
        RAISE EXCEPTION 'ALREADY_POSTED: документ уже проведён';
    END IF;

    SELECT * INTO v_journal
    FROM private.documents
    WHERE id = v_own.document_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOURNAL_NOT_FOUND: журнал для строки владения не найден';
    END IF;

    IF v_journal.doc_type <> 'ownership' OR v_journal.organization_id <> v_own.organization_id THEN
        RAISE EXCEPTION 'JOURNAL_MISMATCH: связанная шапка не ownership или другая организация';
    END IF;

    IF v_journal.status <> 'draft' THEN
        RAISE EXCEPTION 'DOCUMENT_NOT_DRAFT: статус журнала %', v_journal.status;
    END IF;

    SELECT pl.locked_until INTO v_locked_until
    FROM private.period_locks pl
    WHERE pl.organization_id = v_own.organization_id;

    IF v_locked_until IS NOT NULL AND v_journal.doc_date <= v_locked_until THEN
        RAISE EXCEPTION 'PERIOD_LOCKED: дата документа в закрытом периоде (locked_until=%)', v_locked_until;
    END IF;

    v_posted_ts := clock_timestamp();

    UPDATE private.documents
    SET status = 'posted', posted_at = v_posted_ts
    WHERE id = v_journal.id;

    UPDATE private.doc_ownership SET status = 'posted' WHERE id = p_doc_id;

    SELECT contractor_type INTO v_contractor_type
    FROM private.contractors
    WHERE id = v_own.contractor_id;

    IF v_contractor_type = 'individual' AND NOT EXISTS (
        SELECT 1 FROM private.members
        WHERE organization_id = v_own.organization_id
          AND contractor_id   = v_own.contractor_id
    ) THEN
        SELECT COALESCE(
            MAX(member_number::int) FILTER (WHERE member_number ~ '^\d+$'), 0
        ) INTO v_max_num
        FROM private.members
        WHERE organization_id = v_own.organization_id;

        INSERT INTO private.members (
            organization_id, contractor_id, member_number, joined_at, source_doc_id
        ) VALUES (
            v_own.organization_id,
            v_own.contractor_id,
            (v_max_num + 1)::text,
            v_own.doc_date,
            p_doc_id
        );
    END IF;

    UPDATE private.organizations o
    SET actuality_moment = GREATEST(
        COALESCE(o.actuality_moment, '-infinity'::timestamptz),
        v_posted_ts
    )
    WHERE o.id = v_own.organization_id;

    RETURN jsonb_build_object(
        'ok',            true,
        'doc_id',        p_doc_id,
        'document_id',   v_journal.id,
        'object_type',   v_own.object_type,
        'object_id',     v_own.object_id,
        'contractor_id', v_own.contractor_id
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.post_ownership(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Task 5: unpost_ownership — p_own_id = doc_ownership.id (как post_ownership)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.unpost_ownership(p_own_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_own         private.doc_ownership%ROWTYPE;
    v_journal     private.documents%ROWTYPE;
    v_ctx_org     UUID;
    v_tgt         TIMESTAMPTZ;
    v_org         UUID;
    v_locked_until DATE;
    v_cascade_docs_n INT := 0;
    v_own_reset_n INT := 0;
    v_ids         UUID[];
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT o.* INTO v_own
    FROM private.doc_ownership o
    WHERE o.id = p_own_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: строка владения % не найдена', p_own_id;
    END IF;

    IF v_ctx_org IS NOT NULL AND v_own.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_own.document_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'MISSING_DOCUMENT_LINK');
    END IF;

    SELECT d.* INTO v_journal
    FROM private.documents d
    WHERE d.id = v_own.document_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOURNAL_NOT_FOUND: журнал для строки владения не найден';
    END IF;

    IF v_journal.doc_type <> 'ownership' OR v_journal.organization_id <> v_own.organization_id THEN
        RAISE EXCEPTION 'JOURNAL_MISMATCH: связанная шапка не ownership или другая организация';
    END IF;

    IF v_journal.status <> 'posted' OR v_own.status <> 'posted' THEN
        RAISE EXCEPTION 'NOT_POSTED: можно отменить только проведённый документ владения';
    END IF;

    v_org := v_journal.organization_id;
    v_tgt := v_journal.posted_at;
    IF v_tgt IS NULL THEN
        RAISE EXCEPTION 'MISSING_POSTED_AT: у документа нет posted_at';
    END IF;

    SELECT pl.locked_until INTO v_locked_until
    FROM private.period_locks pl
    WHERE pl.organization_id = v_org;

    IF v_locked_until IS NOT NULL AND v_journal.doc_date <= v_locked_until THEN
        RAISE EXCEPTION 'PERIOD_LOCKED: дата документа в закрытом периоде (locked_until=%)', v_locked_until;
    END IF;

    WITH upd AS (
        UPDATE private.documents d
        SET
            status = 'draft',
            posted_at = NULL,
            cancelled_at = NULL
        WHERE d.organization_id = v_org
          AND d.status = 'posted'
          AND d.posted_at >= v_tgt
        RETURNING d.id
    )
    SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_ids FROM upd;

    v_cascade_docs_n := cardinality(v_ids);

    UPDATE private.doc_ownership deo
    SET status = 'draft'
    WHERE deo.document_id = ANY(v_ids);

    GET DIAGNOSTICS v_own_reset_n = ROW_COUNT;

    UPDATE private.organizations o
    SET actuality_moment = v_tgt - interval '1 millisecond'
    WHERE o.id = v_org;

    RETURN jsonb_build_object(
        'ok', true,
        'own_id', p_own_id,
        'document_id', v_journal.id,
        'boundary_posted_at', v_tgt,
        'cascade_documents', v_cascade_docs_n,
        'doc_ownership_rows_reset', v_own_reset_n
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.unpost_ownership(UUID) TO authenticated;

COMMENT ON FUNCTION api.unpost_ownership(UUID) IS
    'Отмена проведения документа владения (по doc_ownership.id); каскад по documents.posted_at внутри организации; движения/долг не сторнируются.';

-- ---------------------------------------------------------------------------
-- Task 6: plot_summary — владелец из последнего ownership (без реестра)
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.plot_summary;

CREATE VIEW api.plot_summary AS
WITH doc_candidates AS (
    SELECT
        deo.object_id AS plot_id,
        d.organization_id,
        d.id AS document_id,
        d.posted_at
    FROM private.doc_ownership deo
    JOIN private.documents d ON d.id = deo.document_id
    WHERE deo.object_type = 'plot'
      AND d.doc_type = 'ownership'
      AND d.status = 'posted'
      AND deo.status = 'posted'
      AND deo.organization_id = d.organization_id
),
ranked_docs AS (
    SELECT DISTINCT plot_id, organization_id, document_id, posted_at
    FROM doc_candidates
),
ranked AS (
    SELECT
        plot_id,
        organization_id,
        document_id,
        posted_at,
        ROW_NUMBER() OVER (
            PARTITION BY organization_id, plot_id
            ORDER BY posted_at DESC NULLS LAST, document_id DESC
        ) AS rn
    FROM ranked_docs
),
latest_per_plot AS (
    SELECT organization_id, plot_id, document_id
    FROM ranked
    WHERE rn = 1
),
owner_agg AS (
    SELECT
        lp.organization_id,
        lp.plot_id,
        CASE WHEN COUNT(*) = 1
             THEN (ARRAY_AGG(deo.contractor_id ORDER BY deo.contractor_id))[1]
        END AS owner_id,
        CASE WHEN COUNT(*) = 1 THEN MAX(c.full_name)
             ELSE STRING_AGG(c.full_name, ', ' ORDER BY deo.contractor_id)
        END AS owner_name,
        CASE WHEN COUNT(*) = 1 THEN MAX(c.phone) END AS owner_phone
    FROM latest_per_plot lp
    JOIN private.doc_ownership deo
        ON deo.document_id = lp.document_id
       AND deo.object_id = lp.plot_id
       AND deo.object_type = 'plot'
       AND deo.organization_id = lp.organization_id
    JOIN private.contractors c ON c.id = deo.contractor_id
    GROUP BY lp.organization_id, lp.plot_id
)
SELECT
    p.id,
    p.organization_id,
    p.number,
    p.area,
    p.is_active,
    oa.owner_id,
    oa.owner_name,
    oa.owner_phone,
    COALESCE(dbt.total_debt, 0) AS total_debt
FROM private.plots p
LEFT JOIN owner_agg oa
    ON oa.plot_id = p.id AND oa.organization_id = p.organization_id
LEFT JOIN (
    SELECT object_id, SUM(amount) AS total_debt
    FROM private.debt_movements
    WHERE object_type = 'plot'
    GROUP BY object_id
) dbt ON dbt.object_id = p.id;

COMMENT ON VIEW api.plot_summary IS
    'Участки: задолженность и владельцы из последнего проведённого документа ownership; owner_id только при ровно одном совладельце в документе, иначе NULL.';

GRANT SELECT ON api.plot_summary TO authenticated;

-- ---------------------------------------------------------------------------
-- Одноразовая гигиена: реестр участков больше не используется для владения
-- ---------------------------------------------------------------------------

DELETE FROM private.financial_object_registry
WHERE object_type = 'plot'::private.fin_object_type;

-- ---------------------------------------------------------------------------
-- Демо-контрагенты после wipe в 010 (DELETE FROM private.contractors)
-- По 5 физлиц + 2 юрлица на организацию; contractor_type доступен с шага 010.
-- Идемпотентно: пара (organization_id, full_name).
-- ---------------------------------------------------------------------------

INSERT INTO private.contractors (organization_id, full_name, contractor_type, phone, email)
SELECT o.id, v.full_name, v.contractor_type, v.phone, v.email
FROM private.organizations o
CROSS JOIN (VALUES
    -- Демо-А: юрлица + физлица
    ('СТ «Демо-А»', 'ООО «Земледел»',               'legal_entity'::varchar(20), NULL::text, 'zemledel-a@demo.controlling.local'),
    ('СТ «Демо-А»', 'УП "СТ «Демо-А»" (исполком)', 'legal_entity'::varchar(20), NULL::text, 'ispolkom-a@demo.controlling.local'),
    ('СТ «Демо-А»', 'Иванов Иван Иванович',        'individual'::varchar(20), '+375291000001', NULL::text),
    ('СТ «Демо-А»', 'Петрова Мария Сергеевна',     'individual'::varchar(20), '+375291000002', NULL::text),
    ('СТ «Демо-А»', 'Сидоров Пётр Алексеевич',    'individual'::varchar(20), '+375291000003', NULL::text),
    ('СТ «Демо-А»', 'Козлова Елена Викторовна',    'individual'::varchar(20), '+375291000004', NULL::text),
    ('СТ «Демо-А»', 'Морозов Дмитрий Николаевич', 'individual'::varchar(20), '+375291000005', NULL::text),
    -- Демо-Б
    ('СТ «Демо-Б»', 'ООО «АгроПром»',               'legal_entity'::varchar(20), NULL::text, 'agroprom-b@demo.controlling.local'),
    ('СТ «Демо-Б»', 'УП "СТ «Демо-Б»" (исполком)', 'legal_entity'::varchar(20), NULL::text, 'ispolkom-b@demo.controlling.local'),
    ('СТ «Демо-Б»', 'Николаев Сергей Петрович',    'individual'::varchar(20), '+375291000101', NULL::text),
    ('СТ «Демо-Б»', 'Орлова Анна Дмитриевна',      'individual'::varchar(20), '+375291000102', NULL::text),
    ('СТ «Демо-Б»', 'Волков Андрей Игоревич',      'individual'::varchar(20), '+375291000103', NULL::text),
    ('СТ «Демо-Б»', 'Соколова Ольга Павловна',     'individual'::varchar(20), '+375291000104', NULL::text),
    ('СТ «Демо-Б»', 'Лебедев Игорь Максимович',    'individual'::varchar(20), '+375291000105', NULL::text)
) AS v(org_name, full_name, contractor_type, phone, email)
WHERE o.name = v.org_name
  AND NOT EXISTS (
      SELECT 1
      FROM private.contractors c
      WHERE c.organization_id = o.id AND c.full_name = v.full_name
  );
