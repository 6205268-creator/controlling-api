-- =============================================================================
-- Migration 019: Ownership UI — doc_ownership view, doc_journal fix, update RPC
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. View api.doc_ownership — чтение строки владения по document_id / own id
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW api.doc_ownership AS
SELECT
    deo.id,
    deo.document_id,
    deo.organization_id,
    deo.contractor_id,
    c.full_name  AS contractor_name,
    deo.object_type,
    deo.object_id,
    deo.doc_date,
    deo.notes,
    deo.status,
    deo.shares,
    deo.created_at
FROM private.doc_ownership deo
JOIN private.contractors c ON c.id = deo.contractor_id;

COMMENT ON VIEW api.doc_ownership IS
    'Строка документа владения; document_id = documents.id, id = own_id для post/unpost.';

GRANT SELECT ON api.doc_ownership TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. doc_journal — contractor_name и own_id для ownership
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
        WHEN 'ownership'    THEN c_own.full_name
        ELSE NULL
    END AS contractor_name,
    CASE d.doc_type
        WHEN 'ownership'    THEN deo.id
        ELSE NULL
    END AS own_id,
    CASE d.doc_type
        WHEN 'accrual'      THEN da.period
        WHEN 'period_close' THEN dpc.closing_period
        ELSE NULL
    END AS period
FROM private.documents d
LEFT JOIN private.doc_ownership      deo    ON deo.document_id = d.id AND d.doc_type = 'ownership'
LEFT JOIN private.doc_payment        dp     ON dp.document_id = d.id
LEFT JOIN private.doc_distribution   ddi    ON ddi.document_id = d.id
LEFT JOIN private.doc_meter_charge   mc     ON mc.document_id = d.id
LEFT JOIN private.doc_accrual        da     ON da.document_id = d.id
LEFT JOIN private.doc_period_close   dpc    ON dpc.document_id = d.id
LEFT JOIN private.contractors        c_pay  ON c_pay.id = dp.contractor_id
LEFT JOIN private.contractors        c_dist ON c_dist.id = ddi.contractor_id
LEFT JOIN private.contractors        c_own  ON c_own.id = deo.contractor_id;

GRANT SELECT ON api.doc_journal TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. update_ownership — редактирование черновика (как в 1С: сохранить без проведения)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.update_ownership(
    p_own_id        UUID,
    p_contractor_id UUID,
    p_object_id     UUID,
    p_object_type   VARCHAR DEFAULT 'plot',
    p_doc_date      DATE    DEFAULT NULL,
    p_notes         TEXT    DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_own     private.doc_ownership%ROWTYPE;
    v_journal private.documents%ROWTYPE;
    v_ctx_org UUID;
    v_date    DATE;
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

    IF v_own.document_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'MISSING_DOCUMENT_LINK');
    END IF;

    SELECT * INTO v_journal
    FROM private.documents
    WHERE id = v_own.document_id
    FOR UPDATE;

    IF v_journal.status <> 'draft' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'DOCUMENT_NOT_DRAFT');
    END IF;

    v_date := COALESCE(p_doc_date, v_own.doc_date);

    UPDATE private.doc_ownership
    SET contractor_id = p_contractor_id,
        object_id     = p_object_id,
        object_type   = p_object_type,
        doc_date      = v_date,
        notes         = p_notes
    WHERE id = p_own_id;

    UPDATE private.documents
    SET doc_date = v_date,
        notes    = p_notes
    WHERE id = v_own.document_id;

    RETURN jsonb_build_object(
        'ok', true,
        'doc_id', p_own_id,
        'document_id', v_own.document_id,
        'status', 'draft'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_ownership(UUID, UUID, UUID, VARCHAR, DATE, TEXT) TO authenticated;

COMMENT ON FUNCTION api.update_ownership IS
    'Обновить черновик документа владения (doc_ownership.id).';

-- PostgREST: перечитать схему
NOTIFY pgrst, 'reload schema';
