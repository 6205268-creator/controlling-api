-- =============================================================================
-- Migration 021: ownership shares — multi-owner document support
-- =============================================================================
-- Design: Document-first model. Each documents row is one ownership event;
-- multiple doc_ownership rows on it represent co-owners with shares.
-- post_ownership / unpost_ownership now accept documents.id.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 1: Add object_id / object_type to private.documents (ownership metadata)
-- Needed so add_ownership_owner can read the target object from the header.
-- ---------------------------------------------------------------------------

ALTER TABLE private.documents
    ADD COLUMN IF NOT EXISTS object_id   UUID,
    ADD COLUMN IF NOT EXISTS object_type VARCHAR(50);

COMMENT ON COLUMN private.documents.object_id IS
    'Объект документа — заполняется только для doc_type = ''ownership''';
COMMENT ON COLUMN private.documents.object_type IS
    'Тип объекта — заполняется только для doc_type = ''ownership''';

-- Backfill from existing doc_ownership rows
UPDATE private.documents d
SET object_id   = deo.object_id,
    object_type = deo.object_type
FROM private.doc_ownership deo
WHERE deo.document_id = d.id
  AND d.doc_type = 'ownership';

-- ---------------------------------------------------------------------------
-- Step 2: FK members.source_doc_id → ON DELETE SET NULL
-- Allows removing a doc_ownership draft row without deleting the member record.
-- ---------------------------------------------------------------------------

ALTER TABLE private.members
    DROP CONSTRAINT members_source_doc_id_fkey,
    ADD CONSTRAINT members_source_doc_id_fkey
        FOREIGN KEY (source_doc_id)
        REFERENCES private.doc_ownership(id)
        ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- Step 3: create_ownership — header only, no p_contractor_id
-- Old signature: (org, contractor, object, object_type, doc_date, notes, created_by)
-- New signature: (org, object, object_type, doc_date, notes, created_by)
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.create_ownership(UUID, UUID, UUID, VARCHAR, DATE, TEXT, UUID);

CREATE OR REPLACE FUNCTION api.create_ownership(
    p_org_id      UUID,
    p_object_id   UUID,
    p_object_type VARCHAR DEFAULT 'plot',
    p_doc_date    DATE    DEFAULT CURRENT_DATE,
    p_notes       TEXT    DEFAULT NULL,
    p_created_by  UUID    DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org     UUID;
    v_document_id UUID;
BEGIN
    v_ctx_org := private.current_org_id();
    IF v_ctx_org IS NOT NULL AND p_org_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    INSERT INTO private.documents (
        organization_id, doc_type, doc_date, status,
        notes, created_by, object_id, object_type
    ) VALUES (
        p_org_id, 'ownership', p_doc_date, 'draft',
        p_notes, p_created_by, p_object_id, p_object_type
    )
    RETURNING id INTO v_document_id;

    RETURN jsonb_build_object(
        'ok',          true,
        'document_id', v_document_id,
        'status',      'draft'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_ownership(UUID, UUID, VARCHAR, DATE, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Step 4: update_ownership — header only, accepts documents.id
-- Old signature: (own_id, contractor_id, object_id, object_type, doc_date, notes)
-- New signature: (document_id, doc_date, notes, object_id, object_type)
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.update_ownership(UUID, UUID, UUID, VARCHAR, DATE, TEXT);

CREATE OR REPLACE FUNCTION api.update_ownership(
    p_document_id UUID,
    p_doc_date    DATE    DEFAULT NULL,
    p_notes       TEXT    DEFAULT NULL,
    p_object_id   UUID    DEFAULT NULL,
    p_object_type VARCHAR DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc     private.documents%ROWTYPE;
    v_ctx_org UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_doc
    FROM private.documents
    WHERE id = p_document_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'DOC_NOT_FOUND');
    END IF;

    IF v_doc.doc_type <> 'ownership' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'NOT_OWNERSHIP');
    END IF;

    IF v_ctx_org IS NOT NULL AND v_doc.organization_id <> v_ctx_org THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ORG_MISMATCH');
    END IF;

    IF v_doc.status <> 'draft' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'NOT_DRAFT');
    END IF;

    UPDATE private.documents
    SET doc_date    = COALESCE(p_doc_date,    doc_date),
        notes       = COALESCE(p_notes,       notes),
        object_id   = COALESCE(p_object_id,   object_id),
        object_type = COALESCE(p_object_type, object_type)
    WHERE id = p_document_id;

    -- Sync doc_date to all ownership rows
    IF p_doc_date IS NOT NULL THEN
        UPDATE private.doc_ownership
        SET doc_date = p_doc_date
        WHERE document_id = p_document_id;
    END IF;

    -- Sync object to all ownership rows
    IF p_object_id IS NOT NULL OR p_object_type IS NOT NULL THEN
        UPDATE private.doc_ownership
        SET object_id   = COALESCE(p_object_id,   object_id),
            object_type = COALESCE(p_object_type, object_type)
        WHERE document_id = p_document_id;
    END IF;

    RETURN jsonb_build_object(
        'ok',          true,
        'document_id', p_document_id,
        'status',      'draft'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_ownership(UUID, DATE, TEXT, UUID, VARCHAR) TO authenticated;

-- ---------------------------------------------------------------------------
-- Step 5: add_ownership_owner — добавить владельца в черновик документа
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.add_ownership_owner(
    p_document_id   UUID,
    p_contractor_id UUID,
    p_shares        INTEGER DEFAULT 1
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc     private.documents%ROWTYPE;
    v_ctx_org UUID;
    v_own_id  UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_doc
    FROM private.documents
    WHERE id = p_document_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'DOC_NOT_FOUND');
    END IF;

    IF v_doc.doc_type <> 'ownership' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'NOT_OWNERSHIP');
    END IF;

    IF v_ctx_org IS NOT NULL AND v_doc.organization_id <> v_ctx_org THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ORG_MISMATCH');
    END IF;

    IF v_doc.status <> 'draft' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'NOT_DRAFT');
    END IF;

    IF p_shares <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'INVALID_SHARES');
    END IF;

    IF v_doc.object_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'MISSING_OBJECT');
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.doc_ownership
        WHERE document_id   = p_document_id
          AND contractor_id = p_contractor_id
    ) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'CONTRACTOR_ALREADY_OWNER');
    END IF;

    INSERT INTO private.doc_ownership (
        organization_id, contractor_id, object_type, object_id,
        doc_date, status, document_id, shares
    ) VALUES (
        v_doc.organization_id,
        p_contractor_id,
        v_doc.object_type,
        v_doc.object_id,
        v_doc.doc_date,
        'draft',
        p_document_id,
        p_shares
    )
    RETURNING id INTO v_own_id;

    RETURN jsonb_build_object('ok', true, 'own_id', v_own_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.add_ownership_owner(UUID, UUID, INTEGER) TO authenticated;

-- ---------------------------------------------------------------------------
-- Step 6: remove_ownership_owner — удалить владельца из черновика
-- ON DELETE SET NULL на members.source_doc_id обнуляется автоматически.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.remove_ownership_owner(p_own_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_own     private.doc_ownership%ROWTYPE;
    v_ctx_org UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_own
    FROM private.doc_ownership
    WHERE id = p_own_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'DOC_NOT_FOUND');
    END IF;

    IF v_ctx_org IS NOT NULL AND v_own.organization_id <> v_ctx_org THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ORG_MISMATCH');
    END IF;

    IF v_own.status <> 'draft' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'NOT_DRAFT');
    END IF;

    DELETE FROM private.doc_ownership WHERE id = p_own_id;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.remove_ownership_owner(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Step 7: update_ownership_owner — изменить контрагента и/или доли строки черновика
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.update_ownership_owner(
    p_own_id        UUID,
    p_contractor_id UUID,
    p_shares        INTEGER
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_own     private.doc_ownership%ROWTYPE;
    v_ctx_org UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_own
    FROM private.doc_ownership
    WHERE id = p_own_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'DOC_NOT_FOUND');
    END IF;

    IF v_ctx_org IS NOT NULL AND v_own.organization_id <> v_ctx_org THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ORG_MISMATCH');
    END IF;

    IF v_own.status <> 'draft' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'NOT_DRAFT');
    END IF;

    IF p_shares <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'INVALID_SHARES');
    END IF;

    -- Check new contractor not already in another row of the same document
    IF p_contractor_id <> v_own.contractor_id AND EXISTS (
        SELECT 1 FROM private.doc_ownership
        WHERE document_id   = v_own.document_id
          AND contractor_id = p_contractor_id
          AND id            <> p_own_id
    ) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'CONTRACTOR_ALREADY_OWNER');
    END IF;

    UPDATE private.doc_ownership
    SET contractor_id = p_contractor_id,
        shares        = p_shares
    WHERE id = p_own_id;

    RETURN jsonb_build_object('ok', true, 'own_id', p_own_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_ownership_owner(UUID, UUID, INTEGER) TO authenticated;

-- ---------------------------------------------------------------------------
-- Step 8: post_ownership — принимает documents.id, проводит все строки документа
-- Old: p_doc_id = doc_ownership.id, posted one row.
-- New: p_document_id = documents.id, posts all rows.
-- DROP required: parameter renamed (p_doc_id → p_document_id).
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.post_ownership(UUID);

CREATE OR REPLACE FUNCTION api.post_ownership(p_document_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc          private.documents%ROWTYPE;
    v_ctx_org      UUID;
    v_posted_ts    TIMESTAMPTZ;
    v_locked_until DATE;
    v_owners_n     INT;
    v_max_num      INT;
    v_own          private.doc_ownership%ROWTYPE;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_doc
    FROM private.documents
    WHERE id = p_document_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: документ % не найден', p_document_id;
    END IF;

    IF v_doc.doc_type <> 'ownership' THEN
        RAISE EXCEPTION 'NOT_OWNERSHIP: документ не является документом владения';
    END IF;

    IF v_ctx_org IS NOT NULL AND v_doc.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_doc.status <> 'draft' THEN
        RAISE EXCEPTION 'DOCUMENT_NOT_DRAFT: статус документа %', v_doc.status;
    END IF;

    SELECT COUNT(*) INTO v_owners_n
    FROM private.doc_ownership
    WHERE document_id = p_document_id;

    IF v_owners_n = 0 THEN
        RAISE EXCEPTION 'OWNERSHIP_EMPTY: документ не содержит строк владельцев';
    END IF;

    SELECT pl.locked_until INTO v_locked_until
    FROM private.period_locks pl
    WHERE pl.organization_id = v_doc.organization_id;

    IF v_locked_until IS NOT NULL AND v_doc.doc_date <= v_locked_until THEN
        RAISE EXCEPTION 'PERIOD_LOCKED: дата документа в закрытом периоде (locked_until=%)', v_locked_until;
    END IF;

    v_posted_ts := clock_timestamp();

    UPDATE private.documents
    SET status    = 'posted',
        posted_at = v_posted_ts
    WHERE id = p_document_id;

    UPDATE private.doc_ownership
    SET status = 'posted'
    WHERE document_id = p_document_id;

    -- Create membership records for individual contractors without existing membership
    FOR v_own IN
        SELECT deo.*
        FROM private.doc_ownership deo
        JOIN private.contractors c ON c.id = deo.contractor_id
        WHERE deo.document_id      = p_document_id
          AND c.contractor_type    = 'individual'
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM private.members
            WHERE organization_id = v_doc.organization_id
              AND contractor_id   = v_own.contractor_id
        ) THEN
            SELECT COALESCE(
                MAX(member_number::int) FILTER (WHERE member_number ~ '^\d+$'), 0
            ) INTO v_max_num
            FROM private.members
            WHERE organization_id = v_doc.organization_id;

            INSERT INTO private.members (
                organization_id, contractor_id, member_number, joined_at, source_doc_id
            ) VALUES (
                v_doc.organization_id,
                v_own.contractor_id,
                (v_max_num + 1)::text,
                v_own.doc_date,
                v_own.id
            );
        END IF;
    END LOOP;

    UPDATE private.organizations o
    SET
        actuality_moment = GREATEST(
            COALESCE(o.actuality_moment, '-infinity'::timestamptz),
            v_posted_ts
        ),
        actuality_document_id = CASE
            WHEN v_posted_ts > COALESCE(o.actuality_moment, '-infinity'::timestamptz)
            THEN p_document_id
            ELSE o.actuality_document_id
        END
    WHERE o.id = v_doc.organization_id;

    RETURN jsonb_build_object(
        'ok',            true,
        'document_id',   p_document_id,
        'object_type',   v_doc.object_type,
        'object_id',     v_doc.object_id,
        'owners_posted', v_owners_n
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.post_ownership(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Step 9: unpost_ownership — принимает documents.id
-- Old: p_own_id = doc_ownership.id
-- New: p_document_id = documents.id
-- DROP required: parameter renamed (p_own_id → p_document_id).
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.unpost_ownership(UUID);

CREATE OR REPLACE FUNCTION api.unpost_ownership(p_document_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc          private.documents%ROWTYPE;
    v_ctx_org      UUID;
    v_tgt          TIMESTAMPTZ;
    v_org          UUID;
    v_locked_until DATE;
    v_cascade_n    INT := 0;
    v_own_reset_n  INT := 0;
    v_ids          UUID[];
    v_new_moment   TIMESTAMPTZ;
    v_new_doc_id   UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_doc
    FROM private.documents
    WHERE id = p_document_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: документ % не найден', p_document_id;
    END IF;

    IF v_doc.doc_type <> 'ownership' THEN
        RAISE EXCEPTION 'NOT_OWNERSHIP: документ не является документом владения';
    END IF;

    IF v_ctx_org IS NOT NULL AND v_doc.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_doc.status <> 'posted' THEN
        RAISE EXCEPTION 'NOT_POSTED: можно отменить только проведённый документ';
    END IF;

    v_org := v_doc.organization_id;
    v_tgt := v_doc.posted_at;

    IF v_tgt IS NULL THEN
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
        SET
            status       = 'draft',
            posted_at    = NULL,
            cancelled_at = NULL
        WHERE d.organization_id = v_org
          AND d.status          = 'posted'
          AND d.posted_at       >= v_tgt
        RETURNING d.id
    )
    SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_ids FROM upd;

    v_cascade_n := cardinality(v_ids);

    UPDATE private.doc_ownership deo
    SET status = 'draft'
    WHERE deo.document_id = ANY(v_ids);

    GET DIAGNOSTICS v_own_reset_n = ROW_COUNT;

    -- Recalculate actuality from remaining posted ownership docs
    SELECT d.id, d.posted_at
    INTO v_new_doc_id, v_new_moment
    FROM private.documents d
    WHERE d.organization_id = v_org
      AND d.doc_type        = 'ownership'
      AND d.status          = 'posted'
    ORDER BY d.posted_at DESC NULLS LAST
    LIMIT 1;

    UPDATE private.organizations o
    SET
        actuality_moment      = v_new_moment,
        actuality_document_id = v_new_doc_id
    WHERE o.id = v_org;

    RETURN jsonb_build_object(
        'ok',                       true,
        'document_id',              p_document_id,
        'boundary_posted_at',       v_tgt,
        'cascade_documents',        v_cascade_n,
        'doc_ownership_rows_reset', v_own_reset_n
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.unpost_ownership(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Step 10: doc_journal — убрать own_id, агрегировать contractor_name через LATERAL
-- Исправляет дублирование строк при нескольких владельцах.
-- ---------------------------------------------------------------------------

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
        WHEN 'ownership'    THEN own_agg.contractor_name
        ELSE NULL
    END AS contractor_name,
    CASE d.doc_type
        WHEN 'accrual'      THEN da.period
        WHEN 'period_close' THEN dpc.closing_period
        ELSE NULL
    END AS period
FROM private.documents d
LEFT JOIN private.doc_payment        dp     ON dp.document_id  = d.id
LEFT JOIN private.doc_distribution   ddi    ON ddi.document_id = d.id
LEFT JOIN private.doc_meter_charge   mc     ON mc.document_id  = d.id
LEFT JOIN private.doc_accrual        da     ON da.document_id  = d.id
LEFT JOIN private.doc_period_close   dpc    ON dpc.document_id = d.id
LEFT JOIN private.contractors        c_pay  ON c_pay.id        = dp.contractor_id
LEFT JOIN private.contractors        c_dist ON c_dist.id       = ddi.contractor_id
LEFT JOIN LATERAL (
    SELECT STRING_AGG(c.full_name, ', ' ORDER BY deo.created_at) AS contractor_name
    FROM private.doc_ownership deo
    JOIN private.contractors   c   ON c.id = deo.contractor_id
    WHERE deo.document_id = d.id
) own_agg ON d.doc_type = 'ownership';

GRANT SELECT ON api.doc_journal TO authenticated;

-- ---------------------------------------------------------------------------
-- Step 11: PostgREST schema reload
-- ---------------------------------------------------------------------------

NOTIFY pgrst, 'reload schema';
