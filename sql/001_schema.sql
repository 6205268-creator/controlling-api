-- =============================================================================
-- CONTROLLING — Schema v1
-- PostgreSQL 16, schemas: private (tables), api (PostgREST views)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extensions (уже установлены агентом, дублируем для идемпотентности)
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_cron";

-- ---------------------------------------------------------------------------
-- Enums (аналог Перечислений в 1С)
-- ---------------------------------------------------------------------------

CREATE TYPE private.org_type AS ENUM (
    'gardening',   -- Садоводческое товарищество
    'garage'       -- Гаражный кооператив
);

CREATE TYPE private.contribution_kind AS ENUM (
    'membership',  -- Членский взнос
    'target',      -- Целевой взнос
    'meter'        -- По счётчику
);

CREATE TYPE private.fin_object_type AS ENUM (
    'plot',        -- Участок / гараж
    'meter',       -- Счётчик
    'member'       -- Член кооператива
);

CREATE TYPE private.doc_status AS ENUM (
    'draft',       -- Черновик (не проведён)
    'posted',      -- Проведён
    'cancelled'    -- Отменён
);

-- ---------------------------------------------------------------------------
-- БЛОК 1: Справочники (аналог Справочников 1С)
-- ---------------------------------------------------------------------------

-- Организации — тенанты системы (аналог Справочник.Организации)
CREATE TABLE private.organizations (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL CHECK (name <> ''),
    org_type    private.org_type NOT NULL,
    inn         TEXT,
    address     TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Контрагенты — физлица-плательщики (аналог Справочник.Контрагенты)
CREATE TABLE private.contractors (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    full_name       TEXT NOT NULL CHECK (full_name <> ''),
    phone           TEXT,
    email           TEXT,
    address         TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Члены кооператива (аналог Справочник.ЧленыКооператива)
CREATE TABLE private.members (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    contractor_id   UUID NOT NULL REFERENCES private.contractors(id),
    member_number   TEXT NOT NULL CHECK (member_number <> ''),
    joined_at       DATE NOT NULL DEFAULT CURRENT_DATE,
    left_at         DATE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (organization_id, member_number)
);

-- Участки / гаражи — Финансовый объект тип A (аналог Справочник.Участки)
CREATE TABLE private.plots (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    number          TEXT NOT NULL CHECK (number <> ''),
    area            NUMERIC(10, 2),
    owner_id        UUID REFERENCES private.contractors(id),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (organization_id, number)
);

-- Счётчики — Финансовый объект тип B (аналог Справочник.Счётчики)
CREATE TABLE private.meters (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    plot_id         UUID REFERENCES private.plots(id),
    meter_type      TEXT NOT NULL DEFAULT 'water',
    serial_number   TEXT,
    owner_id        UUID REFERENCES private.contractors(id),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Виды взносов (аналог Справочник.ВидыВзносов)
CREATE TABLE private.contribution_types (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    name            TEXT NOT NULL CHECK (name <> ''),
    kind            private.contribution_kind NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Тарифы периодические (аналог РС.Тарифы с СрезПоследних)
-- СрезПоследних = WHERE valid_from <= $date ORDER BY valid_from DESC LIMIT 1
CREATE TABLE private.tariffs (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      UUID NOT NULL REFERENCES private.organizations(id),
    contribution_type_id UUID NOT NULL REFERENCES private.contribution_types(id),
    valid_from           DATE NOT NULL,
    rate                 NUMERIC(15, 4) NOT NULL CHECK (rate >= 0),
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (organization_id, contribution_type_id, valid_from)
);

-- ---------------------------------------------------------------------------
-- БЛОК 2: Контроль (аналог РС.ДатыЗапретаИзменения и РС.ТокеныАвторизации)
-- ---------------------------------------------------------------------------

-- Закрытые периоды (аналог РС.ДатыЗапретаИзменения)
-- locked_until = всё ДО этой даты включительно — закрыто
CREATE TABLE private.period_locks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    locked_until    DATE NOT NULL,
    locked_by       UUID,
    locked_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (organization_id)  -- одна запись на организацию, UPSERT при закрытии
);

-- Токены авторизации (аналог РС.ТокеныАвторизации)
-- token_hash = SHA-256 от реального токена (сам токен не хранится)
CREATE TABLE private.auth_tokens (
    token_hash      TEXT PRIMARY KEY,
    user_id         UUID NOT NULL,
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    expires_at      TIMESTAMPTZ NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Пользователи API (для авторизации)
CREATE TABLE private.users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID REFERENCES private.organizations(id),
    login           TEXT NOT NULL UNIQUE CHECK (login <> ''),
    password_hash   TEXT NOT NULL,
    full_name       TEXT,
    role            TEXT NOT NULL DEFAULT 'member'
                    CHECK (role IN ('admin','treasurer','board','member','background')),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Добавляем FK на users после создания таблицы
ALTER TABLE private.auth_tokens
    ADD CONSTRAINT auth_tokens_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES private.users(id);

ALTER TABLE private.period_locks
    ADD CONSTRAINT period_locks_locked_by_fkey
    FOREIGN KEY (locked_by) REFERENCES private.users(id);

-- ---------------------------------------------------------------------------
-- БЛОК 3: Реестр финансовых объектов
-- (аналог РС.РеестрФинансовыхОбъектов + ОпределяемыйТип.ФинансовыйОбъект)
-- В 1С был полиморфный тип. Здесь: object_type + object_id (UUID)
-- ---------------------------------------------------------------------------

CREATE TABLE private.financial_object_registry (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    object_type     private.fin_object_type NOT NULL,
    object_id       UUID NOT NULL,
    owner_id        UUID REFERENCES private.contractors(id),
    registered_at   DATE NOT NULL DEFAULT CURRENT_DATE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (organization_id, object_type, object_id)
);

-- ---------------------------------------------------------------------------
-- БЛОК 4: Показания счётчиков (аналог РС.ПоказанияСчётчиков)
-- ---------------------------------------------------------------------------

CREATE TABLE private.meter_readings (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meter_id        UUID NOT NULL REFERENCES private.meters(id),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    period          DATE NOT NULL,
    reading         NUMERIC(15, 3) NOT NULL CHECK (reading >= 0),
    document_id     UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (meter_id, period)  -- одно показание на период — запрет двойного ввода
);

-- ---------------------------------------------------------------------------
-- БЛОК 5: Иммутабельный журнал — Задолженности
-- (аналог РН.ЗадолженностиПлательщиков — Остатки)
--
-- Главный принцип: записи НИКОГДА не удаляются и не правятся.
-- Отмена проведения = новая запись с amount * -1 (сторно).
-- Баланс = SUM(amount) GROUP BY object_id.
-- ---------------------------------------------------------------------------

CREATE TABLE private.debt_movements (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      UUID NOT NULL REFERENCES private.organizations(id),
    document_id          UUID NOT NULL,
    document_type        TEXT NOT NULL,
    object_type          private.fin_object_type NOT NULL,
    object_id            UUID NOT NULL,
    contribution_type_id UUID NOT NULL REFERENCES private.contribution_types(id),
    amount               NUMERIC(15, 2) NOT NULL,
    period               DATE NOT NULL,
    is_reversal          BOOLEAN NOT NULL DEFAULT FALSE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT debt_amount_not_zero CHECK (amount <> 0)
);

-- Индексы для быстрых запросов остатков
CREATE INDEX idx_debt_movements_object   ON private.debt_movements (organization_id, object_type, object_id);
CREATE INDEX idx_debt_movements_period   ON private.debt_movements (organization_id, period);
CREATE INDEX idx_debt_movements_document ON private.debt_movements (document_id);

-- ---------------------------------------------------------------------------
-- БЛОК 6: Иммутабельный журнал — Лицевые счета
-- (аналог РН.СчетКонтрагента — Остатки)
-- ---------------------------------------------------------------------------

CREATE TABLE private.account_movements (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    document_id     UUID NOT NULL,
    document_type   TEXT NOT NULL,
    contractor_id   UUID NOT NULL REFERENCES private.contractors(id),
    amount          NUMERIC(15, 2) NOT NULL,
    period          DATE NOT NULL,
    is_reversal     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT account_amount_not_zero CHECK (amount <> 0)
);

CREATE INDEX idx_account_movements_contractor ON private.account_movements (organization_id, contractor_id);
CREATE INDEX idx_account_movements_document   ON private.account_movements (document_id);

-- ---------------------------------------------------------------------------
-- БЛОК 7: Документы — мастер-таблица + детали по типу
-- (аналог Журнала документов 1С)
-- ---------------------------------------------------------------------------

-- Шапка всех документов (аналог общих реквизитов всех документов)
CREATE TABLE private.documents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES private.organizations(id),
    doc_type        TEXT NOT NULL
                    CHECK (doc_type IN (
                        'payment',           -- Документ.Платёж
                        'distribution',      -- Документ.РаспределениеПлатежей
                        'meter_reading',     -- Документ.ПоказанияСчётчиков
                        'meter_charge',      -- Документ.НачислениеПоСчётчику
                        'period_close',      -- Документ.ЗакрытиеПериода
                        'meter_correction'   -- Документ.КорректировкаПоказаний
                    )),
    doc_date        DATE NOT NULL,
    status          private.doc_status NOT NULL DEFAULT 'draft',
    parent_id       UUID REFERENCES private.documents(id),
    created_by      UUID REFERENCES private.users(id),
    posted_at       TIMESTAMPTZ,
    cancelled_at    TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_documents_org_date ON private.documents (organization_id, doc_date DESC);
CREATE INDEX idx_documents_type     ON private.documents (organization_id, doc_type, status);
CREATE INDEX idx_documents_parent   ON private.documents (parent_id) WHERE parent_id IS NOT NULL;

-- Детали Платежа (аналог реквизитов шапки Документ.Платёж)
CREATE TABLE private.doc_payment (
    document_id   UUID PRIMARY KEY REFERENCES private.documents(id) ON DELETE CASCADE,
    contractor_id UUID NOT NULL REFERENCES private.contractors(id),
    amount        NUMERIC(15, 2) NOT NULL CHECK (amount > 0),
    payment_ref   TEXT
);

-- Детали Распределения платежей (аналог реквизитов Документ.РаспределениеПлатежей)
CREATE TABLE private.doc_distribution (
    document_id   UUID PRIMARY KEY REFERENCES private.documents(id) ON DELETE CASCADE,
    contractor_id UUID NOT NULL REFERENCES private.contractors(id)
);

-- Табличная часть распределения (аналог ТЧ Документа)
CREATE TABLE private.doc_distribution_lines (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id          UUID NOT NULL REFERENCES private.doc_distribution(document_id) ON DELETE CASCADE,
    object_type          private.fin_object_type NOT NULL,
    object_id            UUID NOT NULL,
    contribution_type_id UUID NOT NULL REFERENCES private.contribution_types(id),
    amount               NUMERIC(15, 2) NOT NULL CHECK (amount > 0)
);

-- Детали ПоказанийСчётчика
CREATE TABLE private.doc_meter_reading (
    document_id   UUID PRIMARY KEY REFERENCES private.documents(id) ON DELETE CASCADE,
    meter_id      UUID NOT NULL REFERENCES private.meters(id),
    reading_date  DATE NOT NULL,
    reading_value NUMERIC(15, 3) NOT NULL CHECK (reading_value >= 0)
);

-- Детали НачисленияПоСчётчику
CREATE TABLE private.doc_meter_charge (
    document_id          UUID PRIMARY KEY REFERENCES private.documents(id) ON DELETE CASCADE,
    meter_id             UUID NOT NULL REFERENCES private.meters(id),
    contribution_type_id UUID NOT NULL REFERENCES private.contribution_types(id),
    reading_current      NUMERIC(15, 3) NOT NULL,
    reading_previous     NUMERIC(15, 3) NOT NULL,
    consumption          NUMERIC(15, 3) GENERATED ALWAYS AS (reading_current - reading_previous) STORED,
    tariff_rate          NUMERIC(15, 4) NOT NULL CHECK (tariff_rate >= 0),
    amount               NUMERIC(15, 2) NOT NULL CHECK (amount > 0)
);

-- Детали ЗакрытияПериода
CREATE TABLE private.doc_period_close (
    document_id     UUID PRIMARY KEY REFERENCES private.documents(id) ON DELETE CASCADE,
    closing_period  DATE NOT NULL
);

-- Детали КорректировкиПоказаний (только для закрытых периодов — сторно)
CREATE TABLE private.doc_meter_correction (
    document_id       UUID PRIMARY KEY REFERENCES private.documents(id) ON DELETE CASCADE,
    meter_id          UUID NOT NULL REFERENCES private.meters(id),
    correction_period DATE NOT NULL,
    old_reading       NUMERIC(15, 3) NOT NULL,
    new_reading       NUMERIC(15, 3) NOT NULL,
    reason            TEXT NOT NULL CHECK (reason <> '')
);

-- ---------------------------------------------------------------------------
-- БЛОК 8: Триггер запрета изменений в закрытом периоде
-- (аналог ПередЗаписью → КооперативКонтроль.ПроверитьДатуЗапрета)
--
-- Срабатывает при любом INSERT в debt_movements и account_movements.
-- Пропускает сторно-записи (is_reversal = TRUE) — они нужны для корректировок.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.check_period_lock()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    -- Корректировки закрытого периода разрешены (это и есть их смысл)
    IF NEW.is_reversal THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.period_locks
        WHERE organization_id = NEW.organization_id
          AND locked_until >= NEW.period
    ) THEN
        RAISE EXCEPTION 'PERIOD_LOCKED: Период % закрыт для организации %. Используйте документ корректировки.',
            NEW.period, NEW.organization_id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_debt_period_lock
    BEFORE INSERT ON private.debt_movements
    FOR EACH ROW EXECUTE FUNCTION private.check_period_lock();

CREATE TRIGGER trg_account_period_lock
    BEFORE INSERT ON private.account_movements
    FOR EACH ROW EXECUTE FUNCTION private.check_period_lock();

-- ---------------------------------------------------------------------------
-- БЛОК 9: Функции-агрегаторы (аналог ОстатокОстатки в запросах 1С)
-- ---------------------------------------------------------------------------

-- Долг финансового объекта (аналог РН.ЗадолженностиПлательщиков.ОстатокОстатки)
CREATE OR REPLACE FUNCTION private.object_debt(
    p_org_id    UUID,
    p_obj_type  private.fin_object_type,
    p_obj_id    UUID,
    p_on_date   DATE DEFAULT NULL
)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(amount), 0)
    FROM private.debt_movements
    WHERE organization_id = p_org_id
      AND object_type     = p_obj_type
      AND object_id       = p_obj_id
      AND (p_on_date IS NULL OR period <= p_on_date);
$$;

-- Остаток лицевого счёта (аналог РН.СчетКонтрагента.ОстатокОстатки)
CREATE OR REPLACE FUNCTION private.account_balance(
    p_org_id        UUID,
    p_contractor_id UUID
)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(amount), 0)
    FROM private.account_movements
    WHERE organization_id = p_org_id
      AND contractor_id   = p_contractor_id;
$$;

-- Текущий тариф (аналог РС.Тарифы.СрезПоследних)
CREATE OR REPLACE FUNCTION private.get_tariff(
    p_org_id             UUID,
    p_contribution_type  UUID,
    p_on_date            DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT rate
    FROM private.tariffs
    WHERE organization_id      = p_org_id
      AND contribution_type_id = p_contribution_type
      AND valid_from           <= p_on_date
    ORDER BY valid_from DESC
    LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- БЛОК 10: PostgREST — минимальные view в схеме api
-- (то, что видно снаружи через REST API)
-- ---------------------------------------------------------------------------

-- Организации
CREATE VIEW api.organizations AS
    SELECT id, name, org_type, inn, is_active
    FROM private.organizations
    WHERE is_active = TRUE;

-- Контрагенты
CREATE VIEW api.contractors AS
    SELECT id, organization_id, full_name, phone, email, is_active
    FROM private.contractors;

-- Участки
CREATE VIEW api.plots AS
    SELECT id, organization_id, number, area, owner_id, is_active
    FROM private.plots;

-- Счётчики
CREATE VIEW api.meters AS
    SELECT id, organization_id, plot_id, meter_type, serial_number, is_active
    FROM private.meters;

-- Документы (журнал)
CREATE VIEW api.documents AS
    SELECT id, organization_id, doc_type, doc_date, status, parent_id, created_at
    FROM private.documents
    ORDER BY doc_date DESC;

-- Задолженности (только итоги по объектам)
CREATE VIEW api.object_debts AS
    SELECT
        organization_id,
        object_type,
        object_id,
        SUM(amount) AS total_debt
    FROM private.debt_movements
    GROUP BY organization_id, object_type, object_id
    HAVING SUM(amount) <> 0;

-- Остатки лицевых счетов
CREATE VIEW api.account_balances AS
    SELECT
        organization_id,
        contractor_id,
        SUM(amount) AS balance
    FROM private.account_movements
    GROUP BY organization_id, contractor_id;

-- ---------------------------------------------------------------------------
-- БЛОК 11: Права доступа для PostgREST
-- ---------------------------------------------------------------------------

-- anon — только авторизация (никаких данных без токена)
GRANT USAGE ON SCHEMA api TO anon;

-- authenticated — читает api.* views
GRANT USAGE ON SCHEMA api TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA api TO authenticated;

-- service_role — полный доступ к private (для SECURITY DEFINER функций)
GRANT USAGE ON SCHEMA private TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA private TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA private TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA private TO service_role;

-- controlling_user — владелец для миграций
GRANT ALL ON SCHEMA private TO controlling_user;
GRANT ALL ON SCHEMA api     TO controlling_user;
