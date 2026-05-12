-- =============================================================================
-- Migration 010: Ownership document flow (rewrite 2026-05-12)
-- 1.  Wipe test data
-- 2.  contractors: add contractor_type
-- 3.  financial_object_registry: reshape to periodic register (valid_from/valid_to)
-- 4.  Drop plot_ownerships
-- 5.  Create standalone private.doc_ownership
-- 6.  members: add source_doc_id + UNIQUE(organization_id, contractor_id)
-- 7.  Rebuild api.plot_summary using financial_object_registry
-- 8.  Create api.contractors view
-- 9.  RPC: search_contractors
-- 10. RPC: create_contractor (with contractor_type)
-- 11. RPC: create_ownership
-- 12. RPC: post_ownership
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Wipe test data (FK order)
-- ---------------------------------------------------------------------------
DELETE FROM private.meter_readings;
DELETE FROM private.doc_accrual_lines;
DELETE FROM private.doc_distribution_lines;
DELETE FROM private.doc_accrual;
DELETE FROM private.doc_distribution;
DELETE FROM private.doc_payment;
DELETE FROM private.doc_meter_reading;
DELETE FROM private.doc_meter_charge;
DELETE FROM private.doc_period_close;
DELETE FROM private.doc_meter_correction;
DELETE FROM private.debt_movements;
DELETE FROM private.account_movements;
DELETE FROM private.documents;
DELETE FROM private.members;
DELETE FROM private.financial_object_registry;
DELETE FROM private.meters;
UPDATE private.plots SET owner_id = NULL;
DELETE FROM private.contractors;
DELETE FROM private.period_locks;

-- ---------------------------------------------------------------------------
-- 2. contractors: add contractor_type
-- ---------------------------------------------------------------------------
ALTER TABLE private.contractors
    ADD COLUMN IF NOT EXISTS contractor_type VARCHAR(20) NOT NULL DEFAULT 'individual'
        CHECK (contractor_type IN ('individual', 'legal_entity'));

-- ---------------------------------------------------------------------------
-- 3. financial_object_registry: reshape to periodic register
--    owner_id → contractor_id, registered_at → valid_from, drop is_active, add valid_to
-- ---------------------------------------------------------------------------
ALTER TABLE private.financial_object_registry
    DROP CONSTRAINT IF EXISTS financial_object_registry_organization_id_object_type_objec_key;

ALTER TABLE private.financial_object_registry
    DROP CONSTRAINT IF EXISTS financial_object_registry_owner_id_fkey;

ALTER TABLE private.financial_object_registry
    RENAME COLUMN owner_id TO contractor_id;

ALTER TABLE private.financial_object_registry
    RENAME COLUMN registered_at TO valid_from;

ALTER TABLE private.financial_object_registry
    DROP COLUMN IF EXISTS is_active;

ALTER TABLE private.financial_object_registry
    ADD COLUMN IF NOT EXISTS valid_to DATE;

ALTER TABLE private.financial_object_registry
    ADD CONSTRAINT financial_object_registry_contractor_id_fkey
        FOREIGN KEY (contractor_id) REFERENCES private.contractors(id);

-- Prevent two open records for the same object (valid_to IS NULL = current owner)
CREATE UNIQUE INDEX IF NOT EXISTS fin_obj_reg_active_unique
    ON private.financial_object_registry (organization_id, object_type, object_id)
    WHERE valid_to IS NULL;

-- ---------------------------------------------------------------------------
-- 4. Drop plot_ownerships (replaced by financial_object_registry)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS private.plot_ownerships CASCADE;

-- ---------------------------------------------------------------------------
-- 5. Create standalone doc_ownership table
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS private.doc_ownership;

CREATE TABLE private.doc_ownership (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID        NOT NULL REFERENCES private.organizations(id),
    contractor_id   UUID        NOT NULL REFERENCES private.contractors(id),
    object_type     VARCHAR(50) NOT NULL DEFAULT 'plot',
    object_id       UUID        NOT NULL,
    doc_date        DATE        NOT NULL DEFAULT CURRENT_DATE,
    notes           TEXT,
    status          VARCHAR(20) NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft', 'posted')),
    created_by      UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE private.doc_ownership ENABLE ROW LEVEL SECURITY;

CREATE POLICY org_isolation ON private.doc_ownership
    USING (organization_id = private.current_org_id());

-- ---------------------------------------------------------------------------
-- 6. members: source_doc_id + UNIQUE(organization_id, contractor_id)
-- ---------------------------------------------------------------------------
ALTER TABLE private.members
    ADD COLUMN IF NOT EXISTS source_doc_id UUID REFERENCES private.doc_ownership(id);

ALTER TABLE private.members
    DROP CONSTRAINT IF EXISTS members_organization_id_contractor_id_key;

ALTER TABLE private.members
    ADD CONSTRAINT members_organization_id_contractor_id_key
        UNIQUE (organization_id, contractor_id);

-- ---------------------------------------------------------------------------
-- 7. Rebuild api.plot_summary — owner from financial_object_registry
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.plot_summary;

CREATE VIEW api.plot_summary AS
SELECT
    p.id,
    p.organization_id,
    p.number,
    p.area,
    p.is_active,
    r.contractor_id AS owner_id,
    c.full_name     AS owner_name,
    c.phone         AS owner_phone,
    COALESCE(d.total_debt, 0) AS total_debt
FROM private.plots p
LEFT JOIN private.financial_object_registry r
    ON  r.organization_id = p.organization_id
    AND r.object_type     = 'plot'
    AND r.object_id       = p.id
    AND r.valid_to IS NULL
LEFT JOIN private.contractors c ON c.id = r.contractor_id
LEFT JOIN (
    SELECT object_id, SUM(amount) AS total_debt
    FROM private.debt_movements
    WHERE object_type = 'plot'
    GROUP BY object_id
) d ON d.object_id = p.id;

GRANT SELECT ON api.plot_summary TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. api.contractors view
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.contractors;

CREATE VIEW api.contractors AS
SELECT id, organization_id, full_name, contractor_type, phone, email, address, is_active, created_at
FROM private.contractors;

GRANT SELECT ON api.contractors TO authenticated;
REVOKE SELECT ON api.contractors FROM anon;

-- ---------------------------------------------------------------------------
-- 9. RPC: search_contractors
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.search_contractors(p_org_id UUID, p_query TEXT DEFAULT '')
RETURNS TABLE(id UUID, full_name TEXT, contractor_type VARCHAR, phone TEXT)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
    SELECT c.id, c.full_name, c.contractor_type, c.phone
    FROM private.contractors c
    WHERE c.organization_id = p_org_id
      AND c.is_active = true
      AND (
          trim(p_query) = '' OR
          c.full_name ILIKE '%' || trim(p_query) || '%' OR
          c.phone     ILIKE '%' || trim(p_query) || '%'
      )
    ORDER BY c.full_name
    LIMIT 20;
$$;

GRANT EXECUTE ON FUNCTION api.search_contractors(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 10. RPC: create_contractor (with contractor_type)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.create_contractor(UUID, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION api.create_contractor(
    p_org_id          UUID,
    p_full_name       TEXT,
    p_contractor_type VARCHAR DEFAULT 'individual',
    p_phone           TEXT    DEFAULT NULL,
    p_email           TEXT    DEFAULT NULL,
    p_address         TEXT    DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id UUID;
BEGIN
    IF p_full_name IS NULL OR trim(p_full_name) = '' THEN
        RAISE EXCEPTION 'INVALID_NAME: ФИО не может быть пустым';
    END IF;
    IF p_contractor_type NOT IN ('individual', 'legal_entity') THEN
        RAISE EXCEPTION 'INVALID_TYPE: contractor_type must be individual or legal_entity';
    END IF;

    INSERT INTO private.contractors (
        organization_id, full_name, contractor_type, phone, email, address
    ) VALUES (
        p_org_id, trim(p_full_name), p_contractor_type,
        nullif(trim(p_phone),   ''),
        nullif(trim(p_email),   ''),
        nullif(trim(p_address), '')
    )
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'contractor_id', v_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_contractor(UUID, TEXT, VARCHAR, TEXT, TEXT, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 11. RPC: create_ownership — creates draft document
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_ownership(
    p_org_id        UUID,
    p_contractor_id UUID,
    p_object_type   VARCHAR DEFAULT 'plot',
    p_object_id     UUID,
    p_doc_date      DATE    DEFAULT CURRENT_DATE,
    p_notes         TEXT    DEFAULT NULL,
    p_created_by    UUID    DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_doc_id UUID;
BEGIN
    INSERT INTO private.doc_ownership (
        organization_id, contractor_id, object_type, object_id,
        doc_date, notes, status, created_by
    ) VALUES (
        p_org_id, p_contractor_id, p_object_type, p_object_id,
        p_doc_date, p_notes, 'draft', p_created_by
    )
    RETURNING id INTO v_doc_id;

    RETURN jsonb_build_object('ok', true, 'doc_id', v_doc_id, 'status', 'draft');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_ownership(UUID, UUID, VARCHAR, UUID, DATE, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 12. RPC: post_ownership — posts document in transaction with row lock
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.post_ownership(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc             private.doc_ownership%ROWTYPE;
    v_contractor_type VARCHAR(20);
    v_max_num         INT;
BEGIN
    -- Row lock prevents two concurrent posts on same document
    SELECT * INTO v_doc
    FROM private.doc_ownership
    WHERE id = p_doc_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: документ % не найден', p_doc_id;
    END IF;
    IF v_doc.status = 'posted' THEN
        RAISE EXCEPTION 'ALREADY_POSTED: документ уже проведён';
    END IF;

    SELECT contractor_type INTO v_contractor_type
    FROM private.contractors
    WHERE id = v_doc.contractor_id;

    -- Close current registry record for this object (if any)
    UPDATE private.financial_object_registry
    SET valid_to = v_doc.doc_date - 1
    WHERE organization_id = v_doc.organization_id
      AND object_type     = v_doc.object_type::private.fin_object_type
      AND object_id       = v_doc.object_id
      AND valid_to IS NULL;

    -- Insert new registry record (current owner)
    INSERT INTO private.financial_object_registry (
        organization_id, object_type, object_id, contractor_id, valid_from
    ) VALUES (
        v_doc.organization_id,
        v_doc.object_type::private.fin_object_type,
        v_doc.object_id,
        v_doc.contractor_id,
        v_doc.doc_date
    );

    -- Auto-create ST member for individuals without existing membership
    IF v_contractor_type = 'individual' AND NOT EXISTS (
        SELECT 1 FROM private.members
        WHERE organization_id = v_doc.organization_id
          AND contractor_id   = v_doc.contractor_id
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
            v_doc.contractor_id,
            (v_max_num + 1)::text,
            v_doc.doc_date,
            p_doc_id
        );
    END IF;

    UPDATE private.doc_ownership SET status = 'posted' WHERE id = p_doc_id;

    RETURN jsonb_build_object(
        'ok',            true,
        'doc_id',        p_doc_id,
        'object_type',   v_doc.object_type,
        'object_id',     v_doc.object_id,
        'contractor_id', v_doc.contractor_id
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.post_ownership(UUID) TO authenticated;
