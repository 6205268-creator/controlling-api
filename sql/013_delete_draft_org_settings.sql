-- =============================================================================
-- Migration 013: delete_draft + org_settings + create_ownership atomicity fix
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. create_ownership — пересоздать с явным комментарием об атомарности
--    EXCEPTION-блок PL/pgSQL создаёт savepoint: оба INSERT откатываются при ошибке.
--    Явный ROLLBACK внутри функции запрещён PostgreSQL — savepoint эквивалентен.
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
    v_ctx_org    UUID;
    v_journal_id UUID;
    v_own_id     UUID;
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
        doc_date, notes, status, created_by, document_id, shares
    ) VALUES (
        p_org_id, p_contractor_id, p_object_type, p_object_id,
        p_doc_date, p_notes, 'draft', p_created_by, v_journal_id, 1
    )
    RETURNING id INTO v_own_id;

    RETURN jsonb_build_object(
        'ok', true,
        'doc_id', v_own_id,
        'document_id', v_journal_id,
        'status', 'draft'
    );
EXCEPTION WHEN OTHERS THEN
    -- Savepoint at block entry rolls back both INSERTs — no orphan document.
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_ownership(UUID, UUID, UUID, VARCHAR, DATE, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. delete_draft — удалить черновик любого типа документа
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.delete_draft(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_doc private.documents%ROWTYPE;
    v_org UUID;
BEGIN
    SELECT * INTO v_doc FROM private.documents WHERE id = p_doc_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'NOT_FOUND');
    END IF;

    v_org := private.current_org_id();
    IF v_org IS NOT NULL AND v_doc.organization_id <> v_org THEN
        RETURN jsonb_build_object('ok', false, 'error', 'ORG_MISMATCH');
    END IF;

    IF v_doc.status <> 'draft' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'NOT_DRAFT');
    END IF;

    -- doc_ownership.document_id FK = NO ACTION: нужно удалить строки вручную
    IF v_doc.doc_type = 'ownership' THEN
        DELETE FROM private.doc_ownership WHERE document_id = p_doc_id;
    END IF;

    -- Остальные doc_* таблицы имеют ON DELETE CASCADE
    DELETE FROM private.documents WHERE id = p_doc_id;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_draft(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. current_period в organizations
-- ---------------------------------------------------------------------------
ALTER TABLE private.organizations
    ADD COLUMN IF NOT EXISTS current_period DATE;

COMMENT ON COLUMN private.organizations.current_period IS
    'Рабочая дата периода (UI): текущий период для интерфейса, не блокирует документы';

-- ---------------------------------------------------------------------------
-- 4. api.org_settings
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.org_settings AS
SELECT
    o.id            AS organization_id,
    pl.locked_until AS lock_date,
    o.current_period
FROM private.organizations o
LEFT JOIN private.period_locks pl ON pl.organization_id = o.id;

GRANT SELECT ON api.org_settings TO authenticated;

COMMENT ON VIEW api.org_settings IS
    'Настройки организации: lock_date (дата запрета изменений) и current_period (рабочая дата периода)';

-- ---------------------------------------------------------------------------
-- 5. set_lock_date (NULL = снять блокировку, удаляет строку из period_locks)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_lock_date(p_org_id UUID, p_lock_date DATE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF private.current_org_id() IS NOT NULL AND p_org_id <> private.current_org_id() THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;

    IF p_lock_date IS NULL THEN
        DELETE FROM private.period_locks WHERE organization_id = p_org_id;
    ELSE
        INSERT INTO private.period_locks (organization_id, locked_until, locked_at)
        VALUES (p_org_id, p_lock_date, now())
        ON CONFLICT (organization_id) DO UPDATE
            SET locked_until = p_lock_date,
                locked_at    = now();
    END IF;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_lock_date(UUID, DATE) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. set_current_period
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_current_period(p_org_id UUID, p_period DATE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF private.current_org_id() IS NOT NULL AND p_org_id <> private.current_org_id() THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;

    UPDATE private.organizations SET current_period = p_period WHERE id = p_org_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ORG_NOT_FOUND';
    END IF;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_current_period(UUID, DATE) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Удалить мусорный тестовый документ (создан при ручном тестировании)
--    Порядок: members (source_doc_id FK) → doc_ownership (document_id FK) → documents
-- ---------------------------------------------------------------------------
DELETE FROM private.members
WHERE source_doc_id = '7f61dd38-f155-4f78-afef-e62aed56d6c1';

DELETE FROM private.doc_ownership
WHERE document_id = 'bea492fa-b538-4605-95a4-78cd87fa076d';

DELETE FROM private.documents
WHERE id = 'bea492fa-b538-4605-95a4-78cd87fa076d' AND status = 'draft';
