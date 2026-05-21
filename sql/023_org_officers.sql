-- =============================================================================
-- Migration 023: org_officers
-- Adds private.org_officers — periodic register of organization officers
-- (chairman, treasurer, audit_member). No effective_to — current officer is
-- determined by MAX(effective_from) <= query_date.
-- Adds api.org_officers view (current state) and api.get_officers_at RPC.
-- MVP: no appointment validation (see TECH_DEBT.md TD-002).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Таблица private.org_officers
-- ---------------------------------------------------------------------------
CREATE TABLE private.org_officers (
    organization_id UUID        NOT NULL
                                REFERENCES private.organizations(id),
    contractor_id   UUID        NOT NULL
                                REFERENCES private.contractors(id),
    officer_type    TEXT        NOT NULL
                                CHECK (officer_type IN ('chairman','treasurer','audit_member')),
    effective_from  DATE        NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, officer_type, contractor_id, effective_from)
);

ALTER TABLE private.org_officers ENABLE ROW LEVEL SECURITY;

CREATE POLICY org_isolation ON private.org_officers
    USING (organization_id = private.current_org_id());

COMMENT ON TABLE private.org_officers IS
    'Должностные лица организации. '
    'Без effective_to: текущий = MAX(effective_from) <= запрашиваемая_дата. '
    'Ревкомиссия назначается пачкой — несколько строк с одинаковым effective_from.';

-- ---------------------------------------------------------------------------
-- 2. View api.org_officers — текущий состав на сегодня
-- Возвращает только роли, по которым есть хотя бы одно назначение.
-- ---------------------------------------------------------------------------
CREATE VIEW api.org_officers AS

-- председатель (последнее назначение)
SELECT
    o.id            AS organization_id,
    oo.officer_type,
    oo.contractor_id,
    oo.effective_from
FROM private.organizations o
JOIN LATERAL (
    SELECT officer_type, contractor_id, effective_from
    FROM   private.org_officers
    WHERE  organization_id = o.id
      AND  officer_type    = 'chairman'
      AND  effective_from <= CURRENT_DATE
    ORDER BY effective_from DESC
    LIMIT 1
) oo ON true

UNION ALL

-- казначей (последнее назначение)
SELECT
    o.id,
    oo.officer_type,
    oo.contractor_id,
    oo.effective_from
FROM private.organizations o
JOIN LATERAL (
    SELECT officer_type, contractor_id, effective_from
    FROM   private.org_officers
    WHERE  organization_id = o.id
      AND  officer_type    = 'treasurer'
      AND  effective_from <= CURRENT_DATE
    ORDER BY effective_from DESC
    LIMIT 1
) oo ON true

UNION ALL

-- ревкомиссия (последняя пачка)
SELECT
    o.id,
    oo.officer_type,
    oo.contractor_id,
    oo.effective_from
FROM private.organizations o
JOIN LATERAL (
    SELECT officer_type, contractor_id, effective_from
    FROM   private.org_officers
    WHERE  organization_id = o.id
      AND  officer_type    = 'audit_member'
      AND  effective_from  = (
              SELECT MAX(effective_from)
              FROM   private.org_officers
              WHERE  organization_id = o.id
                AND  officer_type    = 'audit_member'
                AND  effective_from <= CURRENT_DATE
           )
) oo ON true;

GRANT SELECT ON api.org_officers TO authenticated;

COMMENT ON VIEW api.org_officers IS
    'Текущий состав должностных лиц организации на CURRENT_DATE. '
    'Строки есть только для ролей с хотя бы одним назначением.';

-- ---------------------------------------------------------------------------
-- 3. RPC api.set_org_officer — назначить должностных лиц
-- MVP: без валидации прав назначения (см. TECH_DEBT.md TD-002).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_org_officer(
    p_org_id         UUID,
    p_officer_type   TEXT,
    p_contractor_ids UUID[],
    p_effective_from DATE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org UUID;
    v_id      UUID;
BEGIN
    v_ctx_org := private.current_org_id();
    IF v_ctx_org IS NOT NULL AND p_org_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;

    IF p_contractor_ids IS NULL OR array_length(p_contractor_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'EMPTY_CONTRACTORS';
    END IF;

    IF p_officer_type NOT IN ('chairman', 'treasurer', 'audit_member') THEN
        RAISE EXCEPTION 'INVALID_OFFICER_TYPE';
    END IF;

    FOREACH v_id IN ARRAY p_contractor_ids LOOP
        INSERT INTO private.org_officers
            (organization_id, officer_type, contractor_id, effective_from)
        VALUES
            (p_org_id, p_officer_type, v_id, p_effective_from)
        ON CONFLICT DO NOTHING;
    END LOOP;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_org_officer(UUID, TEXT, UUID[], DATE) TO authenticated;

COMMENT ON FUNCTION api.set_org_officer IS
    'Назначить должностных лиц. p_contractor_ids — массив (для ревкомиссии — несколько). '
    'ON CONFLICT DO NOTHING — повторный вызов с теми же данными безопасен. '
    'Ошибки: ORG_MISMATCH, EMPTY_CONTRACTORS, INVALID_OFFICER_TYPE. '
    'Валидация прав не реализована (MVP, см. TECH_DEBT.md TD-002).';

-- ---------------------------------------------------------------------------
-- 4. RPC api.get_officers_at — состав на произвольную дату (для отчётов)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_officers_at(
    p_org_id UUID,
    p_date   DATE
)
RETURNS TABLE (
    officer_type   TEXT,
    contractor_id  UUID,
    effective_from DATE
) LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org UUID;
BEGIN
    v_ctx_org := private.current_org_id();
    IF v_ctx_org IS NOT NULL AND p_org_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;

    RETURN QUERY

    -- председатель
    (SELECT oo.officer_type, oo.contractor_id, oo.effective_from
     FROM   private.org_officers oo
     WHERE  oo.organization_id = p_org_id
       AND  oo.officer_type    = 'chairman'
       AND  oo.effective_from <= p_date
     ORDER BY oo.effective_from DESC
     LIMIT 1)

    UNION ALL

    -- казначей
    (SELECT oo.officer_type, oo.contractor_id, oo.effective_from
     FROM   private.org_officers oo
     WHERE  oo.organization_id = p_org_id
       AND  oo.officer_type    = 'treasurer'
       AND  oo.effective_from <= p_date
     ORDER BY oo.effective_from DESC
     LIMIT 1)

    UNION ALL

    -- ревкомиссия (последняя пачка)
    SELECT oo.officer_type, oo.contractor_id, oo.effective_from
    FROM   private.org_officers oo
    WHERE  oo.organization_id = p_org_id
      AND  oo.officer_type    = 'audit_member'
      AND  oo.effective_from  = (
              SELECT MAX(oo2.effective_from)
              FROM   private.org_officers oo2
              WHERE  oo2.organization_id = p_org_id
                AND  oo2.officer_type    = 'audit_member'
                AND  oo2.effective_from <= p_date
           );

END;
$$;

GRANT EXECUTE ON FUNCTION api.get_officers_at(UUID, DATE) TO authenticated;

COMMENT ON FUNCTION api.get_officers_at IS
    'Состав должностных лиц организации на заданную дату. '
    'Используется в отчётах. Возвращает строки только для назначенных ролей.';

-- ---------------------------------------------------------------------------
-- 5. PostgREST schema reload
-- ---------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
