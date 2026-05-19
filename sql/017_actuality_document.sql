-- =============================================================================
-- Migration 017: actuality_document_id
-- Добавляет ссылку на документ, установивший actuality_moment.
-- Обновляет api.organizations: экспортирует actuality_moment, actuality_document_id,
-- actuality_doc_date. Перезаписывает post_ownership и unpost_ownership.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 1: Колонка actuality_document_id в private.organizations
-- ---------------------------------------------------------------------------

ALTER TABLE private.organizations
    ADD COLUMN IF NOT EXISTS actuality_document_id UUID
        REFERENCES private.documents(id) ON DELETE SET NULL;

COMMENT ON COLUMN private.organizations.actuality_document_id IS
    'Документ (documents.id), который последним сдвинул actuality_moment';

-- ---------------------------------------------------------------------------
-- Step 2: Бэкфилл — для орг с actuality_moment находим последний posted ownership-документ
-- ---------------------------------------------------------------------------

UPDATE private.organizations o
SET actuality_document_id = sub.id
FROM (
    SELECT DISTINCT ON (d.organization_id)
        d.organization_id,
        d.id
    FROM private.documents d
    WHERE d.doc_type = 'ownership'
      AND d.status   = 'posted'
    ORDER BY d.organization_id, d.posted_at DESC NULLS LAST
) sub
WHERE sub.organization_id = o.id
  AND o.actuality_moment IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Step 3: Пересоздать api.organizations — добавить три поля актуальности
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW api.organizations AS
SELECT
    o.id,
    o.name,
    o.org_type,
    o.inn,
    o.is_active,
    o.actuality_moment,
    o.actuality_document_id,
    d.doc_date AS actuality_doc_date
FROM private.organizations o
LEFT JOIN private.documents d ON d.id = o.actuality_document_id
WHERE o.is_active = TRUE;

-- ---------------------------------------------------------------------------
-- Step 4: post_ownership — дополнительно обновляет actuality_document_id
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

    -- Сдвигаем actuality_moment вперёд, если текущий документ свежее;
    -- actuality_document_id обновляется синхронно.
    UPDATE private.organizations o
    SET
        actuality_moment = GREATEST(
            COALESCE(o.actuality_moment, '-infinity'::timestamptz),
            v_posted_ts
        ),
        actuality_document_id = CASE
            WHEN v_posted_ts > COALESCE(o.actuality_moment, '-infinity'::timestamptz)
            THEN v_journal.id
            ELSE o.actuality_document_id
        END
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
-- Step 5: unpost_ownership — после каскада пересчитывает actuality_moment
--         и actuality_document_id по последнему оставшемуся posted ownership-документу
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
    v_new_moment  TIMESTAMPTZ;
    v_new_doc_id  UUID;
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
            status       = 'draft',
            posted_at    = NULL,
            cancelled_at = NULL
        WHERE d.organization_id = v_org
          AND d.status          = 'posted'
          AND d.posted_at       >= v_tgt
        RETURNING d.id
    )
    SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_ids FROM upd;

    v_cascade_docs_n := cardinality(v_ids);

    UPDATE private.doc_ownership deo
    SET status = 'draft'
    WHERE deo.document_id = ANY(v_ids);

    GET DIAGNOSTICS v_own_reset_n = ROW_COUNT;

    -- Пересчитываем actuality по последнему оставшемуся проведённому ownership-документу
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
        'ok',                    true,
        'own_id',                p_own_id,
        'document_id',           v_journal.id,
        'boundary_posted_at',    v_tgt,
        'cascade_documents',     v_cascade_docs_n,
        'doc_ownership_rows_reset', v_own_reset_n,
        'new_actuality_moment',  v_new_moment,
        'new_actuality_document_id', v_new_doc_id
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.unpost_ownership(UUID) TO authenticated;

COMMENT ON FUNCTION api.unpost_ownership(UUID) IS
    'Отмена проведения документа владения (по doc_ownership.id); каскад по documents.posted_at внутри организации; actuality_moment и actuality_document_id пересчитываются по последнему оставшемуся posted ownership-документу.';
