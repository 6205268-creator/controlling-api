-- =============================================================================
-- Migration 018: Meter readings & tariffs (2026-05-19)
-- 1. contribution_types: add meter_type + CHECK
-- 2. api.set_tariff
-- 3. api.create_meter_charge — rewrite with auto-lookup
-- 4. api.unpost_meter_charge — point unpost
-- 5. api.unpost_meter_reading — cascade unpost
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 1: contribution_types — meter_type link
-- ---------------------------------------------------------------------------
ALTER TABLE private.contribution_types
    ADD COLUMN meter_type private.meter_type_enum;

COMMENT ON COLUMN private.contribution_types.meter_type IS
    'Тип счётчика (water/electricity/gas). Обязателен при kind=''meter'', NULL для остальных.';

ALTER TABLE private.contribution_types
    ADD CONSTRAINT ct_meter_type_required
        CHECK (kind <> 'meter' OR meter_type IS NOT NULL);
