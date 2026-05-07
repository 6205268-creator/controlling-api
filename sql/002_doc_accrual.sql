-- =============================================================================
-- Migration 002: Add 'accrual' document type + tables
-- PostgreSQL 16, controlling DB
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Extend doc_type check to include 'accrual'
-- ---------------------------------------------------------------------------

ALTER TABLE private.documents
    DROP CONSTRAINT documents_doc_type_check;

ALTER TABLE private.documents
    ADD CONSTRAINT documents_doc_type_check
    CHECK (doc_type IN (
        'payment',          -- Документ.Платёж
        'distribution',     -- Документ.РаспределениеПлатежей
        'meter_reading',    -- Документ.ПоказанияСчётчиков
        'meter_charge',     -- Документ.НачислениеПоСчётчику
        'period_close',     -- Документ.ЗакрытиеПериода
        'meter_correction', -- Документ.КорректировкаПоказаний
        'accrual'           -- Документ.НачислениеВзносов (новый)
    ));

-- ---------------------------------------------------------------------------
-- 2. doc_accrual — шапка начисления взносов
--    Аналог шапки Документ.НачислениеВзносов в 1С
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.doc_accrual (
    document_id          UUID PRIMARY KEY REFERENCES private.documents(id) ON DELETE CASCADE,
    period               DATE NOT NULL,      -- За какой период начисляем
    contribution_type_id UUID NOT NULL REFERENCES private.contribution_types(id)
);

COMMENT ON TABLE private.doc_accrual IS
    'Шапка начисления взносов — период + вид взноса';

-- ---------------------------------------------------------------------------
-- 3. doc_accrual_lines — строки начисления (по каждому финансовому объекту)
--    Аналог ТЧ Документа.НачислениеВзносов
--    object_type: plot=участок, member=член, meter=счётчик
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS private.doc_accrual_lines (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id  UUID NOT NULL REFERENCES private.doc_accrual(document_id) ON DELETE CASCADE,
    object_type  private.fin_object_type NOT NULL,
    object_id    UUID NOT NULL,
    amount       NUMERIC(15, 2) NOT NULL CHECK (amount > 0)
);

CREATE INDEX IF NOT EXISTS idx_doc_accrual_lines_doc
    ON private.doc_accrual_lines (document_id);

COMMENT ON TABLE private.doc_accrual_lines IS
    'Строки начисления — один ряд на каждый участок/член/счётчик';
