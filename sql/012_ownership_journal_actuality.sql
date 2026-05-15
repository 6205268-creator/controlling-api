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
-- --- RPC below added in subsequent tasks ---
-- -----------------------------------------------------------------------------
