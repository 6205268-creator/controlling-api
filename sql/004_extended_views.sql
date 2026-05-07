-- =============================================================================
-- Migration 004: Extended views for frontend — reports and document journal
-- All views in api schema → visible via PostgREST GET requests
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. api.doc_journal — журнал документов с расшифровкой
--    GET /doc_journal?organization_id=eq.<uuid>&order=doc_date.desc
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
    -- Сумма: из платежа или из начисления (для отображения в списке)
    CASE d.doc_type
        WHEN 'payment'     THEN dp.amount
        WHEN 'meter_charge' THEN mc.amount
        ELSE NULL
    END AS amount,
    -- Контрагент (для платежей и распределений)
    CASE d.doc_type
        WHEN 'payment'      THEN c_pay.full_name
        WHEN 'distribution' THEN c_dist.full_name
        ELSE NULL
    END AS contractor_name,
    -- Период начисления
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

COMMENT ON VIEW api.doc_journal IS
    'GET /doc_journal — журнал всех документов с суммой и контрагентом';

-- ---------------------------------------------------------------------------
-- 2. api.debtors — должники (финобъекты с положительным остатком долга)
--    GET /debtors?organization_id=eq.<uuid>&order=total_debt.desc
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.debtors;

CREATE VIEW api.debtors AS
SELECT
    dm.organization_id,
    dm.object_type,
    dm.object_id,
    SUM(dm.amount) AS total_debt,
    -- Имя объекта
    CASE dm.object_type
        WHEN 'plot'   THEN p.number
        WHEN 'member' THEN c_m.full_name
        WHEN 'meter'  THEN COALESCE(m.serial_number, m.meter_type || ' (нет номера)')
    END AS object_name,
    -- Владелец объекта
    CASE dm.object_type
        WHEN 'plot'   THEN c_p.full_name
        WHEN 'member' THEN c_m.full_name
        WHEN 'meter'  THEN c_meter.full_name
    END AS owner_name
FROM private.debt_movements dm
LEFT JOIN private.plots       p      ON p.id = dm.object_id AND dm.object_type = 'plot'
LEFT JOIN private.contractors c_p    ON c_p.id = p.owner_id
LEFT JOIN private.members     mem    ON mem.id = dm.object_id AND dm.object_type = 'member'
LEFT JOIN private.contractors c_m    ON c_m.id = mem.contractor_id
LEFT JOIN private.meters      m      ON m.id = dm.object_id AND dm.object_type = 'meter'
LEFT JOIN private.contractors c_meter ON c_meter.id = m.owner_id
GROUP BY
    dm.organization_id, dm.object_type, dm.object_id,
    p.number, c_p.full_name, c_m.full_name, m.serial_number, m.meter_type, c_meter.full_name
HAVING SUM(dm.amount) > 0;

COMMENT ON VIEW api.debtors IS
    'GET /debtors — список должников (финобъекты с долгом > 0)';

-- ---------------------------------------------------------------------------
-- 3. api.account_statement — выписка по лицевым счетам
--    GET /account_statement?organization_id=eq.<uuid>&contractor_id=eq.<uuid>
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.account_statement;

CREATE VIEW api.account_statement AS
SELECT
    am.id,
    am.organization_id,
    am.contractor_id,
    c.full_name AS contractor_name,
    am.document_id,
    am.document_type,
    am.amount,
    am.period,
    am.is_reversal,
    am.created_at
FROM private.account_movements am
JOIN private.contractors c ON c.id = am.contractor_id;

COMMENT ON VIEW api.account_statement IS
    'GET /account_statement — движения по лицевым счетам с именем контрагента';

-- ---------------------------------------------------------------------------
-- 4. api.debt_movements_detail — движения задолженности с расшифровкой
--    GET /debt_movements_detail?organization_id=eq.<uuid>&object_id=eq.<uuid>
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.debt_movements_detail;

CREATE VIEW api.debt_movements_detail AS
SELECT
    dm.id,
    dm.organization_id,
    dm.document_id,
    dm.document_type,
    d.doc_date,
    dm.object_type,
    dm.object_id,
    dm.contribution_type_id,
    ct.name AS contribution_type_name,
    dm.amount,
    dm.period,
    dm.is_reversal,
    dm.created_at
FROM private.debt_movements dm
JOIN private.documents       d  ON d.id  = dm.document_id
JOIN private.contribution_types ct ON ct.id = dm.contribution_type_id;

COMMENT ON VIEW api.debt_movements_detail IS
    'GET /debt_movements_detail — история задолженностей с названием вида взноса';

-- ---------------------------------------------------------------------------
-- 5. api.meter_readings_view — показания счётчиков с метаинформацией
--    GET /meter_readings_view?organization_id=eq.<uuid>&meter_id=eq.<uuid>
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.meter_readings_view;

CREATE VIEW api.meter_readings_view AS
SELECT
    mr.id,
    mr.organization_id,
    mr.meter_id,
    m.meter_type,
    m.serial_number,
    mr.period,
    mr.reading,
    mr.document_id,
    mr.created_at
FROM private.meter_readings mr
JOIN private.meters m ON m.id = mr.meter_id;

COMMENT ON VIEW api.meter_readings_view IS
    'GET /meter_readings_view — показания счётчиков с типом и серийным номером';

-- ---------------------------------------------------------------------------
-- 6. api.tariffs — тарифы (обновляем существующий или создаём)
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.tariffs;

CREATE VIEW api.tariffs AS
SELECT
    t.id,
    t.organization_id,
    t.contribution_type_id,
    ct.name AS contribution_type_name,
    t.valid_from,
    t.rate,
    t.created_at
FROM private.tariffs t
JOIN private.contribution_types ct ON ct.id = t.contribution_type_id;

COMMENT ON VIEW api.tariffs IS
    'GET /tariffs — тарифы с названием вида взноса';

-- ---------------------------------------------------------------------------
-- 7. api.plot_summary — сводка по участкам: владелец + долг
--    Ключевой отчёт казначея
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.plot_summary;

CREATE VIEW api.plot_summary AS
SELECT
    p.id,
    p.organization_id,
    p.number,
    p.area,
    p.is_active,
    c.id    AS owner_id,
    c.full_name AS owner_name,
    c.phone AS owner_phone,
    COALESCE(d.total_debt, 0) AS total_debt
FROM private.plots p
LEFT JOIN private.contractors c ON c.id = p.owner_id
LEFT JOIN (
    SELECT object_id, SUM(amount) AS total_debt
    FROM private.debt_movements
    WHERE object_type = 'plot'
    GROUP BY object_id
) d ON d.object_id = p.id;

COMMENT ON VIEW api.plot_summary IS
    'GET /plot_summary — участки с именем владельца и суммой долга';

-- ---------------------------------------------------------------------------
-- Grants: authenticated читает все новые views
-- ---------------------------------------------------------------------------

GRANT SELECT ON api.doc_journal           TO authenticated;
GRANT SELECT ON api.debtors               TO authenticated;
GRANT SELECT ON api.account_statement     TO authenticated;
GRANT SELECT ON api.debt_movements_detail TO authenticated;
GRANT SELECT ON api.meter_readings_view   TO authenticated;
GRANT SELECT ON api.tariffs               TO authenticated;
GRANT SELECT ON api.plot_summary          TO authenticated;
