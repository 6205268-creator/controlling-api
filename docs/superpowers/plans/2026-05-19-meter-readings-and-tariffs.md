# Migration 018: Meter Readings & Tariffs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `meter_type` link to contribution types, rewrite `create_meter_charge` with auto-lookup, and implement `unpost_meter_reading` (cascade) + `unpost_meter_charge` (point).

**Architecture:** Single SQL migration file `sql/018_meter_readings_and_tariffs.sql`. Built incrementally task-by-task — each task appends SQL to the file and applies it directly to the dev DB via psql. Two layers stay independent: meter readings and charges do not auto-trigger each other. Cascade unpost mirrors the `unpost_ownership` pattern from migration 017.

**Tech Stack:** PostgreSQL 16, plpgsql, SECURITY DEFINER, RLS via `private.current_org_id()`, PostgREST 14 at `:3100`.

**Test org:** `СТ «Авто-тест»` — `70b5b02a-f78d-4d6c-bb07-835d62d5a6b8` (login: `autotest_chair` / `autotest123`)

**Key existing functions (unchanged):**
- `api.create_meter_reading(org_id, meter_id, reading_date, reading_value, notes)` — creates draft reading doc
- `api.post_meter_reading(doc_id)` — posts reading, inserts into `private.meter_readings`
- `api.post_meter_charge(doc_id)` — posts charge, inserts into `private.debt_movements`
- `private._assert_draft(doc_id, type)` — locks and validates draft doc

**Existing schema facts:**
- `private.meter_type_enum` — `{water, electricity, gas}`
- `private.contribution_types` — columns: `id, organization_id, name, kind, is_active, created_at` (no `meter_type` yet)
- `private.tariffs` — `(id, organization_id, contribution_type_id, valid_from, rate)` — UNIQUE on `(organization_id, contribution_type_id, valid_from)`
- `private.meter_readings` — `(id, meter_id, organization_id, period, reading, document_id, created_at)`
- `private.documents` — has `doc_type CHECK (... 'meter_reading', 'meter_charge', 'ownership', ...)`
- `private.doc_ownership` — has `document_id UUID` FK to `private.documents`
- `private.period_locks` — `(organization_id, locked_until)` UNIQUE per org
- Old `api.create_meter_charge` signature: `(uuid, uuid, uuid, numeric, numeric, numeric, date, text)` — must be dropped

---

### Task 1: Schema — add meter_type to contribution_types

**Files:**
- Create: `sql/018_meter_readings_and_tariffs.sql`

- [ ] **Step 1: Write failing test — column does not exist yet**

```bash
sudo -u postgres psql -d controlling -c "
SELECT meter_type FROM private.contribution_types LIMIT 1;
"
```
Expected: `ERROR: column "meter_type" does not exist`

- [ ] **Step 2: Create migration file with schema step**

Create `sql/018_meter_readings_and_tariffs.sql`:

```sql
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
```

- [ ] **Step 3: Apply step 1 to DB**

```bash
cat /home/roman/controlling-backend/sql/018_meter_readings_and_tariffs.sql | sudo -u postgres psql -d controlling
```
Expected output:
```
ALTER TABLE
ALTER TABLE
```

- [ ] **Step 4: Verify constraint enforced (must fail)**

```bash
sudo -u postgres psql -d controlling -c "
INSERT INTO private.contribution_types (organization_id, name, kind, meter_type)
VALUES ('70b5b02a-f78d-4d6c-bb07-835d62d5a6b8', 'Тест', 'meter', NULL);
"
```
Expected: `ERROR: new row for relation "contribution_types" violates check constraint "ct_meter_type_required"`

- [ ] **Step 5: Verify valid insert passes**

```bash
sudo -u postgres psql -d controlling -c "
INSERT INTO private.contribution_types (organization_id, name, kind, meter_type)
VALUES ('70b5b02a-f78d-4d6c-bb07-835d62d5a6b8', 'Водоснабжение', 'meter', 'water')
RETURNING id, name, kind, meter_type;
"
```
Expected: `1 row` with `meter_type | water`

```bash
# Cleanup test data
sudo -u postgres psql -d controlling -c "
DELETE FROM private.contribution_types WHERE organization_id='70b5b02a-f78d-4d6c-bb07-835d62d5a6b8';
"
```

- [ ] **Step 6: Commit**

```bash
cd /home/roman/controlling-backend
git add sql/018_meter_readings_and_tariffs.sql
git commit -m "feat(db): migration 018 step 1 — contribution_types.meter_type + CHECK"
```

---

### Task 2: api.set_tariff

**Files:**
- Modify: `sql/018_meter_readings_and_tariffs.sql`

- [ ] **Step 1: Write failing test**

```bash
TOKEN=$(curl -s -X POST http://localhost:3100/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"autotest_chair","p_password":"autotest123"}' | jq -r '.token')

curl -s -X POST http://localhost:3100/rpc/set_tariff \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_org_id":"70b5b02a-f78d-4d6c-bb07-835d62d5a6b8","p_contribution_type_id":"00000000-0000-0000-0000-000000000000","p_valid_from":"2026-01-01","p_rate":4.50}'
```
Expected: `{"code":"PGRST202"...}` (function not found in schema cache)

- [ ] **Step 2: Append api.set_tariff to migration file**

Append to `sql/018_meter_readings_and_tariffs.sql`:

```sql

-- ---------------------------------------------------------------------------
-- Step 2: api.set_tariff — UPSERT тарифа для вида взноса kind='meter'
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_tariff(
    p_org_id               UUID,
    p_contribution_type_id UUID,
    p_valid_from           DATE,
    p_rate                 NUMERIC
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org UUID;
    v_ct      private.contribution_types%ROWTYPE;
    v_id      UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_ct
    FROM private.contribution_types
    WHERE id = p_contribution_type_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_CONTRIBUTION_TYPE: вид взноса % не найден', p_contribution_type_id;
    END IF;

    IF v_ct.organization_id <> p_org_id THEN
        RAISE EXCEPTION 'ORG_MISMATCH: вид взноса принадлежит другой организации';
    END IF;

    IF v_ctx_org IS NOT NULL AND v_ct.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_ct.kind <> 'meter' THEN
        RAISE EXCEPTION 'NOT_METER_KIND: тарифы только для видов взноса kind=''meter''';
    END IF;

    IF p_rate <= 0 THEN
        RAISE EXCEPTION 'INVALID_RATE: тариф должен быть > 0, получено %', p_rate;
    END IF;

    INSERT INTO private.tariffs (organization_id, contribution_type_id, valid_from, rate)
    VALUES (p_org_id, p_contribution_type_id, p_valid_from, p_rate)
    ON CONFLICT (organization_id, contribution_type_id, valid_from)
    DO UPDATE SET rate = EXCLUDED.rate
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'tariff_id', v_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_tariff(UUID, UUID, DATE, NUMERIC) TO authenticated;
```

- [ ] **Step 3: Apply only the new function to DB**

```bash
sudo -u postgres psql -d controlling << 'ENDSQL'
CREATE OR REPLACE FUNCTION api.set_tariff(
    p_org_id               UUID,
    p_contribution_type_id UUID,
    p_valid_from           DATE,
    p_rate                 NUMERIC
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_ctx_org UUID;
    v_ct      private.contribution_types%ROWTYPE;
    v_id      UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_ct
    FROM private.contribution_types
    WHERE id = p_contribution_type_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_CONTRIBUTION_TYPE: вид взноса % не найден', p_contribution_type_id;
    END IF;

    IF v_ct.organization_id <> p_org_id THEN
        RAISE EXCEPTION 'ORG_MISMATCH: вид взноса принадлежит другой организации';
    END IF;

    IF v_ctx_org IS NOT NULL AND v_ct.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_ct.kind <> 'meter' THEN
        RAISE EXCEPTION 'NOT_METER_KIND: тарифы только для видов взноса kind=''meter''';
    END IF;

    IF p_rate <= 0 THEN
        RAISE EXCEPTION 'INVALID_RATE: тариф должен быть > 0, получено %', p_rate;
    END IF;

    INSERT INTO private.tariffs (organization_id, contribution_type_id, valid_from, rate)
    VALUES (p_org_id, p_contribution_type_id, p_valid_from, p_rate)
    ON CONFLICT (organization_id, contribution_type_id, valid_from)
    DO UPDATE SET rate = EXCLUDED.rate
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'tariff_id', v_id);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;

GRANT EXECUTE ON FUNCTION api.set_tariff(UUID, UUID, DATE, NUMERIC) TO authenticated;
ENDSQL
sudo systemctl reload postgrest-controlling
sleep 2
```

- [ ] **Step 4: Setup test contribution_type and test set_tariff**

```bash
# Create contribution_type with kind=meter, meter_type=water
CT_ID=$(sudo -u postgres psql -d controlling -t -A -c "
INSERT INTO private.contribution_types (organization_id, name, kind, meter_type)
VALUES ('70b5b02a-f78d-4d6c-bb07-835d62d5a6b8', 'Водоснабжение', 'meter', 'water')
RETURNING id;")
echo "CT_ID=$CT_ID"

TOKEN=$(curl -s -X POST http://localhost:3100/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"autotest_chair","p_password":"autotest123"}' | jq -r '.token')

# Test: set tariff — should succeed
curl -s -X POST http://localhost:3100/rpc/set_tariff \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\":\"70b5b02a-f78d-4d6c-bb07-835d62d5a6b8\",\"p_contribution_type_id\":\"$CT_ID\",\"p_valid_from\":\"2026-01-01\",\"p_rate\":4.50}"
```
Expected: `[{"ok":true,"tariff_id":"..."}]`

```bash
# Test: update tariff — same date, new rate (ON CONFLICT path)
curl -s -X POST http://localhost:3100/rpc/set_tariff \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\":\"70b5b02a-f78d-4d6c-bb07-835d62d5a6b8\",\"p_contribution_type_id\":\"$CT_ID\",\"p_valid_from\":\"2026-01-01\",\"p_rate\":5.00}"
```
Expected: `[{"ok":true,"tariff_id":"..."}]` — same ID, rate updated

```bash
# Verify rate updated to 5.00
sudo -u postgres psql -d controlling -c "
SELECT rate FROM private.tariffs WHERE contribution_type_id='$CT_ID' AND valid_from='2026-01-01';
"
```
Expected: `5.0000`

```bash
# Test: NOT_METER_KIND error
CT_WRONG=$(sudo -u postgres psql -d controlling -t -A -c "
INSERT INTO private.contribution_types (organization_id, name, kind)
VALUES ('70b5b02a-f78d-4d6c-bb07-835d62d5a6b8', 'Членский', 'membership')
RETURNING id;")
curl -s -X POST http://localhost:3100/rpc/set_tariff \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\":\"70b5b02a-f78d-4d6c-bb07-835d62d5a6b8\",\"p_contribution_type_id\":\"$CT_WRONG\",\"p_valid_from\":\"2026-01-01\",\"p_rate\":1.00}"
```
Expected: `[{"ok":false,"error":"NOT_METER_KIND: ..."}]`

- [ ] **Step 5: Commit**

```bash
git add sql/018_meter_readings_and_tariffs.sql
git commit -m "feat(db): migration 018 step 2 — api.set_tariff"
```

---

### Task 3: api.create_meter_charge rewrite

**Files:**
- Modify: `sql/018_meter_readings_and_tariffs.sql`

- [ ] **Step 1: Write failing test — new signature must not yet exist**

```bash
TOKEN=$(curl -s -X POST http://localhost:3100/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"autotest_chair","p_password":"autotest123"}' | jq -r '.token')

# New 4-param signature should NOT exist yet
curl -s -X POST http://localhost:3100/rpc/create_meter_charge \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_org_id":"70b5b02a-f78d-4d6c-bb07-835d62d5a6b8","p_meter_id":"00000000-0000-0000-0000-000000000000","p_doc_date":"2026-05-01"}'
```
Expected: `{"code":"PGRST202"...}` or wrong-overload error confirming old signature still active

- [ ] **Step 2: Setup test data (meter + 2 readings)**

```bash
# Create water meter in autotest org
METER_ID=$(sudo -u postgres psql -d controlling -t -A -c "
INSERT INTO private.meters (organization_id, meter_type, serial_number)
VALUES ('70b5b02a-f78d-4d6c-bb07-835d62d5a6b8', 'water', 'AUTO-001')
RETURNING id;")
echo "METER_ID=$METER_ID"

TOKEN=$(curl -s -X POST http://localhost:3100/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"autotest_chair","p_password":"autotest123"}' | jq -r '.token')

# Post first reading: 100.000 on 2026-04-01
DOC1=$(curl -s -X POST http://localhost:3100/rpc/create_meter_reading \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\":\"70b5b02a-f78d-4d6c-bb07-835d62d5a6b8\",\"p_meter_id\":\"$METER_ID\",\"p_reading_date\":\"2026-04-01\",\"p_reading_value\":100.000}" | jq -r '.[0].document_id')
echo "DOC1=$DOC1"

curl -s -X POST http://localhost:3100/rpc/post_meter_reading \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_doc_id\":\"$DOC1\"}"

# Post second reading: 115.500 on 2026-05-01
DOC2=$(curl -s -X POST http://localhost:3100/rpc/create_meter_reading \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\":\"70b5b02a-f78d-4d6c-bb07-835d62d5a6b8\",\"p_meter_id\":\"$METER_ID\",\"p_reading_date\":\"2026-05-01\",\"p_reading_value\":115.500}" | jq -r '.[0].document_id')
echo "DOC2=$DOC2"

curl -s -X POST http://localhost:3100/rpc/post_meter_reading \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_doc_id\":\"$DOC2\"}"

# Confirm 2 readings in register
sudo -u postgres psql -d controlling -c "
SELECT period, reading FROM private.meter_readings WHERE meter_id='$METER_ID' ORDER BY period;
"
```
Expected: 2 rows — `2026-04-01 | 100.000` and `2026-05-01 | 115.500`

(The `CT_ID` from Task 2 and tariff rate 5.00 from 2026-01-01 are already in DB. Consumption=15.5, amount=77.50)

- [ ] **Step 3: Append rewritten create_meter_charge to migration file**

Append to `sql/018_meter_readings_and_tariffs.sql`:

```sql

-- ---------------------------------------------------------------------------
-- Step 3: api.create_meter_charge — rewrite с авто-поиском тарифа и показаний
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.create_meter_charge(uuid, uuid, uuid, numeric, numeric, numeric, date, text);

CREATE OR REPLACE FUNCTION api.create_meter_charge(
    p_org_id   UUID,
    p_meter_id UUID,
    p_doc_date DATE DEFAULT CURRENT_DATE,
    p_notes    TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org    UUID;
    v_meter_type private.meter_type_enum;
    v_ct_id      UUID;
    v_rate       NUMERIC(15,4);
    v_curr       NUMERIC(15,3);
    v_prev       NUMERIC(15,3);
    v_amount     NUMERIC(15,2);
    v_doc_id     UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    IF v_ctx_org IS NOT NULL AND v_ctx_org <> p_org_id THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    -- 1. meter_type из meters
    SELECT meter_type::private.meter_type_enum INTO v_meter_type
    FROM private.meters
    WHERE id = p_meter_id AND organization_id = p_org_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ORG_MISMATCH: счётчик % не найден в организации %', p_meter_id, p_org_id;
    END IF;

    -- 2. contribution_type по (org, kind=meter, meter_type)
    SELECT id INTO v_ct_id
    FROM private.contribution_types
    WHERE organization_id = p_org_id
      AND kind            = 'meter'
      AND meter_type      = v_meter_type
      AND is_active       = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_METER_CONTRIBUTION_TYPE: нет вида взноса kind=''meter'' для типа счётчика %', v_meter_type;
    END IF;

    -- 3. Два последних показания (newest = current, second = previous)
    WITH last_two AS (
        SELECT reading,
               ROW_NUMBER() OVER (ORDER BY period DESC) AS rn
        FROM private.meter_readings
        WHERE meter_id = p_meter_id
        ORDER BY period DESC
        LIMIT 2
    )
    SELECT
        MAX(reading) FILTER (WHERE rn = 1),
        MAX(reading) FILTER (WHERE rn = 2)
    INTO v_curr, v_prev
    FROM last_two;

    IF v_prev IS NULL THEN
        RAISE EXCEPTION 'NO_PREVIOUS_READING: недостаточно показаний (нужно минимум 2, есть 1 или 0)';
    END IF;

    -- 4. Тариф на p_doc_date (СрезПоследних)
    SELECT rate INTO v_rate
    FROM private.tariffs
    WHERE contribution_type_id = v_ct_id
      AND valid_from           <= p_doc_date
    ORDER BY valid_from DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_TARIFF_FOR_DATE: нет тарифа для вида взноса % на дату %', v_ct_id, p_doc_date;
    END IF;

    -- 5. Сумма начисления
    v_amount := ROUND((v_curr - v_prev) * v_rate, 2);

    IF v_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: сумма %.2f должна быть > 0 (current=%, previous=%, rate=%)',
            v_amount, v_curr, v_prev, v_rate;
    END IF;

    -- 6. Документ
    INSERT INTO private.documents (organization_id, doc_type, doc_date, status, notes)
    VALUES (p_org_id, 'meter_charge', p_doc_date, 'draft', p_notes)
    RETURNING id INTO v_doc_id;

    INSERT INTO private.doc_meter_charge (
        document_id, meter_id, contribution_type_id,
        reading_current, reading_previous, tariff_rate, amount
    ) VALUES (
        v_doc_id, p_meter_id, v_ct_id,
        v_curr, v_prev, v_rate, v_amount
    );

    RETURN jsonb_build_object(
        'ok',               true,
        'document_id',      v_doc_id,
        'status',           'draft',
        'consumption',      v_curr - v_prev,
        'amount',           v_amount,
        'reading_current',  v_curr,
        'reading_previous', v_prev,
        'tariff_rate',      v_rate
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_meter_charge(UUID, UUID, DATE, TEXT) TO authenticated;
```

- [ ] **Step 4: Apply to DB (drop old + create new)**

```bash
sudo -u postgres psql -d controlling << 'ENDSQL'
DROP FUNCTION IF EXISTS api.create_meter_charge(uuid, uuid, uuid, numeric, numeric, numeric, date, text);

CREATE OR REPLACE FUNCTION api.create_meter_charge(
    p_org_id   UUID,
    p_meter_id UUID,
    p_doc_date DATE DEFAULT CURRENT_DATE,
    p_notes    TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_ctx_org    UUID;
    v_meter_type private.meter_type_enum;
    v_ct_id      UUID;
    v_rate       NUMERIC(15,4);
    v_curr       NUMERIC(15,3);
    v_prev       NUMERIC(15,3);
    v_amount     NUMERIC(15,2);
    v_doc_id     UUID;
BEGIN
    v_ctx_org := private.current_org_id();

    IF v_ctx_org IS NOT NULL AND v_ctx_org <> p_org_id THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    SELECT meter_type::private.meter_type_enum INTO v_meter_type
    FROM private.meters
    WHERE id = p_meter_id AND organization_id = p_org_id AND is_active = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ORG_MISMATCH: счётчик % не найден в организации %', p_meter_id, p_org_id;
    END IF;

    SELECT id INTO v_ct_id
    FROM private.contribution_types
    WHERE organization_id = p_org_id
      AND kind            = 'meter'
      AND meter_type      = v_meter_type
      AND is_active       = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_METER_CONTRIBUTION_TYPE: нет вида взноса kind=''meter'' для типа счётчика %', v_meter_type;
    END IF;

    WITH last_two AS (
        SELECT reading,
               ROW_NUMBER() OVER (ORDER BY period DESC) AS rn
        FROM private.meter_readings
        WHERE meter_id = p_meter_id
        ORDER BY period DESC
        LIMIT 2
    )
    SELECT
        MAX(reading) FILTER (WHERE rn = 1),
        MAX(reading) FILTER (WHERE rn = 2)
    INTO v_curr, v_prev
    FROM last_two;

    IF v_prev IS NULL THEN
        RAISE EXCEPTION 'NO_PREVIOUS_READING: недостаточно показаний (нужно минимум 2, есть 1 или 0)';
    END IF;

    SELECT rate INTO v_rate
    FROM private.tariffs
    WHERE contribution_type_id = v_ct_id
      AND valid_from           <= p_doc_date
    ORDER BY valid_from DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_TARIFF_FOR_DATE: нет тарифа для вида взноса % на дату %', v_ct_id, p_doc_date;
    END IF;

    v_amount := ROUND((v_curr - v_prev) * v_rate, 2);

    IF v_amount <= 0 THEN
        RAISE EXCEPTION 'INVALID_AMOUNT: сумма %.2f должна быть > 0 (current=%, previous=%, rate=%)',
            v_amount, v_curr, v_prev, v_rate;
    END IF;

    INSERT INTO private.documents (organization_id, doc_type, doc_date, status, notes)
    VALUES (p_org_id, 'meter_charge', p_doc_date, 'draft', p_notes)
    RETURNING id INTO v_doc_id;

    INSERT INTO private.doc_meter_charge (
        document_id, meter_id, contribution_type_id,
        reading_current, reading_previous, tariff_rate, amount
    ) VALUES (
        v_doc_id, p_meter_id, v_ct_id,
        v_curr, v_prev, v_rate, v_amount
    );

    RETURN jsonb_build_object(
        'ok',               true,
        'document_id',      v_doc_id,
        'status',           'draft',
        'consumption',      v_curr - v_prev,
        'amount',           v_amount,
        'reading_current',  v_curr,
        'reading_previous', v_prev,
        'tariff_rate',      v_rate
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;

GRANT EXECUTE ON FUNCTION api.create_meter_charge(UUID, UUID, DATE, TEXT) TO authenticated;
ENDSQL
sudo systemctl reload postgrest-controlling
sleep 2
```

- [ ] **Step 5: Test create_meter_charge**

```bash
METER_ID=$(sudo -u postgres psql -d controlling -t -A -c "
SELECT id FROM private.meters WHERE organization_id='70b5b02a-f78d-4d6c-bb07-835d62d5a6b8' AND serial_number='AUTO-001';")

TOKEN=$(curl -s -X POST http://localhost:3100/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"autotest_chair","p_password":"autotest123"}' | jq -r '.token')

# Happy path: should auto-find contribution_type, tariff, and 2 readings
curl -s -X POST http://localhost:3100/rpc/create_meter_charge \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\":\"70b5b02a-f78d-4d6c-bb07-835d62d5a6b8\",\"p_meter_id\":\"$METER_ID\",\"p_doc_date\":\"2026-05-19\"}"
```
Expected:
```json
[{"ok":true,"document_id":"...","status":"draft","consumption":15.5,"amount":77.50,"reading_current":115.500,"reading_previous":100.000,"tariff_rate":5.0000}]
```

```bash
# Test error: NO_PREVIOUS_READING (meter with only 1 reading)
METER2=$(sudo -u postgres psql -d controlling -t -A -c "
INSERT INTO private.meters (organization_id, meter_type, serial_number)
VALUES ('70b5b02a-f78d-4d6c-bb07-835d62d5a6b8', 'water', 'AUTO-002')
RETURNING id;")
sudo -u postgres psql -d controlling -c "
INSERT INTO private.meter_readings (meter_id, organization_id, period, reading)
VALUES ('$METER2', '70b5b02a-f78d-4d6c-bb07-835d62d5a6b8', '2026-05-01', 50.000);"

curl -s -X POST http://localhost:3100/rpc/create_meter_charge \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\":\"70b5b02a-f78d-4d6c-bb07-835d62d5a6b8\",\"p_meter_id\":\"$METER2\",\"p_doc_date\":\"2026-05-19\"}"
```
Expected: `[{"ok":false,"error":"NO_PREVIOUS_READING: ..."}]`

```bash
# Test error: NO_TARIFF_FOR_DATE (date before any tariff)
curl -s -X POST http://localhost:3100/rpc/create_meter_charge \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\":\"70b5b02a-f78d-4d6c-bb07-835d62d5a6b8\",\"p_meter_id\":\"$METER_ID\",\"p_doc_date\":\"2025-01-01\"}"
```
Expected: `[{"ok":false,"error":"NO_TARIFF_FOR_DATE: ..."}]`

- [ ] **Step 6: Commit**

```bash
git add sql/018_meter_readings_and_tariffs.sql
git commit -m "feat(db): migration 018 step 3 — rewrite create_meter_charge with auto-lookup"
```

---

### Task 4: api.unpost_meter_charge

**Files:**
- Modify: `sql/018_meter_readings_and_tariffs.sql`

- [ ] **Step 1: Write failing test**

```bash
curl -s -X POST http://localhost:3100/rpc/unpost_meter_charge \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_doc_id":"00000000-0000-0000-0000-000000000000"}'
```
Expected: `{"code":"PGRST202"...}` (function not found)

- [ ] **Step 2: Post the charge created in Task 3**

```bash
TOKEN=$(curl -s -X POST http://localhost:3100/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"autotest_chair","p_password":"autotest123"}' | jq -r '.token')

CHARGE_ID=$(sudo -u postgres psql -d controlling -t -A -c "
SELECT d.id
FROM private.documents d
JOIN private.doc_meter_charge dmc ON dmc.document_id = d.id
JOIN private.meters m ON m.id = dmc.meter_id
WHERE m.serial_number='AUTO-001'
  AND d.organization_id='70b5b02a-f78d-4d6c-bb07-835d62d5a6b8'
  AND d.status='draft'
LIMIT 1;")
echo "CHARGE_ID=$CHARGE_ID"

# Post the charge
curl -s -X POST http://localhost:3100/rpc/post_meter_charge \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_doc_id\":\"$CHARGE_ID\"}"
```
Expected: `[{"ok":true,"document_id":"...","amount":77.50}]`

```bash
# Confirm debt_movements created
sudo -u postgres psql -d controlling -c "
SELECT amount FROM private.debt_movements WHERE document_id='$CHARGE_ID';
"
```
Expected: `77.50`

- [ ] **Step 3: Append unpost_meter_charge to migration file**

Append to `sql/018_meter_readings_and_tariffs.sql`:

```sql

-- ---------------------------------------------------------------------------
-- Step 4: api.unpost_meter_charge — точечная отмена начисления
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.unpost_meter_charge(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org      UUID;
    v_doc          private.documents%ROWTYPE;
    v_locked_until DATE;
    v_amount       NUMERIC(15,2);
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_doc
    FROM private.documents
    WHERE id = p_doc_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: документ % не найден', p_doc_id;
    END IF;

    IF v_ctx_org IS NOT NULL AND v_doc.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_doc.doc_type <> 'meter_charge' THEN
        RAISE EXCEPTION 'WRONG_DOC_TYPE: ожидается meter_charge, получено %', v_doc.doc_type;
    END IF;

    IF v_doc.status <> 'posted' THEN
        RAISE EXCEPTION 'NOT_POSTED: можно отменить только проведённый документ, текущий статус: %', v_doc.status;
    END IF;

    SELECT pl.locked_until INTO v_locked_until
    FROM private.period_locks pl
    WHERE pl.organization_id = v_doc.organization_id;

    IF v_locked_until IS NOT NULL AND v_doc.doc_date <= v_locked_until THEN
        RAISE EXCEPTION 'PERIOD_LOCKED: дата документа в закрытом периоде (locked_until=%)', v_locked_until;
    END IF;

    SELECT amount INTO v_amount
    FROM private.doc_meter_charge
    WHERE document_id = p_doc_id;

    DELETE FROM private.debt_movements WHERE document_id = p_doc_id;

    UPDATE private.documents
    SET status    = 'draft',
        posted_at = NULL
    WHERE id = p_doc_id;

    RETURN jsonb_build_object(
        'ok',              true,
        'doc_id',          p_doc_id,
        'amount_reversed', v_amount
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.unpost_meter_charge(UUID) TO authenticated;
```

- [ ] **Step 4: Apply to DB and reload**

```bash
sudo -u postgres psql -d controlling << 'ENDSQL'
CREATE OR REPLACE FUNCTION api.unpost_meter_charge(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_ctx_org      UUID;
    v_doc          private.documents%ROWTYPE;
    v_locked_until DATE;
    v_amount       NUMERIC(15,2);
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_doc
    FROM private.documents
    WHERE id = p_doc_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: документ % не найден', p_doc_id;
    END IF;

    IF v_ctx_org IS NOT NULL AND v_doc.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_doc.doc_type <> 'meter_charge' THEN
        RAISE EXCEPTION 'WRONG_DOC_TYPE: ожидается meter_charge, получено %', v_doc.doc_type;
    END IF;

    IF v_doc.status <> 'posted' THEN
        RAISE EXCEPTION 'NOT_POSTED: можно отменить только проведённый документ, текущий статус: %', v_doc.status;
    END IF;

    SELECT pl.locked_until INTO v_locked_until
    FROM private.period_locks pl
    WHERE pl.organization_id = v_doc.organization_id;

    IF v_locked_until IS NOT NULL AND v_doc.doc_date <= v_locked_until THEN
        RAISE EXCEPTION 'PERIOD_LOCKED: дата документа в закрытом периоде (locked_until=%)', v_locked_until;
    END IF;

    SELECT amount INTO v_amount
    FROM private.doc_meter_charge
    WHERE document_id = p_doc_id;

    DELETE FROM private.debt_movements WHERE document_id = p_doc_id;

    UPDATE private.documents
    SET status    = 'draft',
        posted_at = NULL
    WHERE id = p_doc_id;

    RETURN jsonb_build_object(
        'ok',              true,
        'doc_id',          p_doc_id,
        'amount_reversed', v_amount
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;

GRANT EXECUTE ON FUNCTION api.unpost_meter_charge(UUID) TO authenticated;
ENDSQL
sudo systemctl reload postgrest-controlling
sleep 2
```

- [ ] **Step 5: Test unpost_meter_charge**

```bash
TOKEN=$(curl -s -X POST http://localhost:3100/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"autotest_chair","p_password":"autotest123"}' | jq -r '.token')

CHARGE_ID=$(sudo -u postgres psql -d controlling -t -A -c "
SELECT d.id
FROM private.documents d
JOIN private.doc_meter_charge dmc ON dmc.document_id = d.id
JOIN private.meters m ON m.id = dmc.meter_id
WHERE m.serial_number='AUTO-001'
  AND d.organization_id='70b5b02a-f78d-4d6c-bb07-835d62d5a6b8'
  AND d.status='posted'
LIMIT 1;")
echo "CHARGE_ID=$CHARGE_ID"

# Happy path: unpost charge
curl -s -X POST http://localhost:3100/rpc/unpost_meter_charge \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_doc_id\":\"$CHARGE_ID\"}"
```
Expected: `[{"ok":true,"doc_id":"...","amount_reversed":77.50}]`

```bash
# Verify: debt_movements deleted, document back to draft
sudo -u postgres psql -d controlling -c "
SELECT COUNT(*) AS dm_count FROM private.debt_movements WHERE document_id='$CHARGE_ID';
SELECT status FROM private.documents WHERE id='$CHARGE_ID';
"
```
Expected: `dm_count=0`, `status=draft`

```bash
# Test error: NOT_POSTED (already draft)
curl -s -X POST http://localhost:3100/rpc/unpost_meter_charge \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_doc_id\":\"$CHARGE_ID\"}"
```
Expected: `[{"ok":false,"error":"NOT_POSTED: ..."}]`

- [ ] **Step 6: Commit**

```bash
git add sql/018_meter_readings_and_tariffs.sql
git commit -m "feat(db): migration 018 step 4 — api.unpost_meter_charge"
```

---

### Task 5: api.unpost_meter_reading (cascade)

**Files:**
- Modify: `sql/018_meter_readings_and_tariffs.sql`

- [ ] **Step 1: Write failing test**

```bash
curl -s -X POST http://localhost:3100/rpc/unpost_meter_reading \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_doc_id":"00000000-0000-0000-0000-000000000000"}'
```
Expected: `{"code":"PGRST202"...}` (function not found)

- [ ] **Step 2: Re-post charge for cascade test**

```bash
TOKEN=$(curl -s -X POST http://localhost:3100/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"autotest_chair","p_password":"autotest123"}' | jq -r '.token')

# Re-post the charge (it was unposted in Task 4)
CHARGE_ID=$(sudo -u postgres psql -d controlling -t -A -c "
SELECT d.id
FROM private.documents d
JOIN private.doc_meter_charge dmc ON dmc.document_id = d.id
JOIN private.meters m ON m.id = dmc.meter_id
WHERE m.serial_number='AUTO-001'
  AND d.organization_id='70b5b02a-f78d-4d6c-bb07-835d62d5a6b8'
  AND d.status='draft'
LIMIT 1;")
echo "CHARGE_ID=$CHARGE_ID"

curl -s -X POST http://localhost:3100/rpc/post_meter_charge \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_doc_id\":\"$CHARGE_ID\"}"

# Get the SECOND reading doc ID (the one we will unpost, triggering cascade)
# The second reading was posted AFTER the first, so its posted_at is newer
# Cascade will catch: reading2 + charge (both posted_at >= reading2.posted_at)
READING2_ID=$(sudo -u postgres psql -d controlling -t -A -c "
SELECT d.id
FROM private.documents d
JOIN private.doc_meter_reading dmr ON dmr.document_id = d.id
WHERE dmr.reading_value = 115.500
  AND d.organization_id = '70b5b02a-f78d-4d6c-bb07-835d62d5a6b8'
  AND d.status = 'posted';")
echo "READING2_ID=$READING2_ID"

# Confirm state before unpost: should show 2 docs affected (reading2 + charge)
sudo -u postgres psql -d controlling -c "
SELECT d.id, d.doc_type, d.status, d.posted_at
FROM private.documents d
WHERE d.organization_id='70b5b02a-f78d-4d6c-bb07-835d62d5a6b8'
  AND d.status='posted'
ORDER BY d.posted_at;
"
```

- [ ] **Step 3: Append unpost_meter_reading to migration file**

Append to `sql/018_meter_readings_and_tariffs.sql`:

```sql

-- ---------------------------------------------------------------------------
-- Step 5: api.unpost_meter_reading — каскадная отмена
-- Отменяет проведённое показание счётчика.
-- Каскад: все posted документы организации с posted_at >= posted_at цели.
-- Для meter_reading: удаляет из meter_readings.
-- Для meter_charge: удаляет из debt_movements.
-- Для ownership: сбрасывает doc_ownership.status = 'draft'.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.unpost_meter_reading(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org           UUID;
    v_doc               private.documents%ROWTYPE;
    v_org               UUID;
    v_boundary          TIMESTAMPTZ;
    v_locked_until      DATE;
    v_cascade_ids       UUID[];
    v_cascade_n         INT;
    v_readings_removed  INT;
    v_movements_removed INT;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_doc
    FROM private.documents
    WHERE id = p_doc_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: документ % не найден', p_doc_id;
    END IF;

    IF v_ctx_org IS NOT NULL AND v_doc.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_doc.doc_type <> 'meter_reading' THEN
        RAISE EXCEPTION 'WRONG_DOC_TYPE: ожидается meter_reading, получено %', v_doc.doc_type;
    END IF;

    IF v_doc.status <> 'posted' THEN
        RAISE EXCEPTION 'NOT_POSTED: можно отменить только проведённый документ, текущий статус: %', v_doc.status;
    END IF;

    v_org      := v_doc.organization_id;
    v_boundary := v_doc.posted_at;

    IF v_boundary IS NULL THEN
        RAISE EXCEPTION 'MISSING_POSTED_AT: у документа нет posted_at';
    END IF;

    SELECT pl.locked_until INTO v_locked_until
    FROM private.period_locks pl
    WHERE pl.organization_id = v_org;

    IF v_locked_until IS NOT NULL AND v_doc.doc_date <= v_locked_until THEN
        RAISE EXCEPTION 'PERIOD_LOCKED: дата документа в закрытом периоде (locked_until=%)', v_locked_until;
    END IF;

    -- Cascade: all posted docs in org with posted_at >= boundary → draft
    WITH upd AS (
        UPDATE private.documents d
        SET status    = 'draft',
            posted_at = NULL
        WHERE d.organization_id = v_org
          AND d.status          = 'posted'
          AND d.posted_at       >= v_boundary
        RETURNING d.id
    )
    SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_cascade_ids
    FROM upd;

    v_cascade_n := cardinality(v_cascade_ids);

    -- Delete meter_readings for meter_reading docs in cascade
    DELETE FROM private.meter_readings
    WHERE document_id = ANY(v_cascade_ids);
    GET DIAGNOSTICS v_readings_removed = ROW_COUNT;

    -- Delete debt_movements for meter_charge docs in cascade
    DELETE FROM private.debt_movements
    WHERE document_id = ANY(v_cascade_ids);
    GET DIAGNOSTICS v_movements_removed = ROW_COUNT;

    -- Reset doc_ownership.status for any ownership docs in cascade
    UPDATE private.doc_ownership
    SET status = 'draft'
    WHERE document_id = ANY(v_cascade_ids);

    RETURN jsonb_build_object(
        'ok',                     true,
        'doc_id',                 p_doc_id,
        'boundary_posted_at',     v_boundary,
        'cascade_documents',      v_cascade_n,
        'meter_readings_removed', v_readings_removed,
        'debt_movements_removed', v_movements_removed
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.unpost_meter_reading(UUID) TO authenticated;

COMMENT ON FUNCTION api.unpost_meter_reading(UUID) IS
    'Отмена проведения показания счётчика; каскад по documents.posted_at внутри организации.';
```

- [ ] **Step 4: Apply to DB and reload**

```bash
sudo -u postgres psql -d controlling << 'ENDSQL'
CREATE OR REPLACE FUNCTION api.unpost_meter_reading(p_doc_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_ctx_org           UUID;
    v_doc               private.documents%ROWTYPE;
    v_org               UUID;
    v_boundary          TIMESTAMPTZ;
    v_locked_until      DATE;
    v_cascade_ids       UUID[];
    v_cascade_n         INT;
    v_readings_removed  INT;
    v_movements_removed INT;
BEGIN
    v_ctx_org := private.current_org_id();

    SELECT * INTO v_doc
    FROM private.documents
    WHERE id = p_doc_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DOC_NOT_FOUND: документ % не найден', p_doc_id;
    END IF;

    IF v_ctx_org IS NOT NULL AND v_doc.organization_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH: organization_id не совпадает с токеном';
    END IF;

    IF v_doc.doc_type <> 'meter_reading' THEN
        RAISE EXCEPTION 'WRONG_DOC_TYPE: ожидается meter_reading, получено %', v_doc.doc_type;
    END IF;

    IF v_doc.status <> 'posted' THEN
        RAISE EXCEPTION 'NOT_POSTED: можно отменить только проведённый документ, текущий статус: %', v_doc.status;
    END IF;

    v_org      := v_doc.organization_id;
    v_boundary := v_doc.posted_at;

    IF v_boundary IS NULL THEN
        RAISE EXCEPTION 'MISSING_POSTED_AT: у документа нет posted_at';
    END IF;

    SELECT pl.locked_until INTO v_locked_until
    FROM private.period_locks pl
    WHERE pl.organization_id = v_org;

    IF v_locked_until IS NOT NULL AND v_doc.doc_date <= v_locked_until THEN
        RAISE EXCEPTION 'PERIOD_LOCKED: дата документа в закрытом периоде (locked_until=%)', v_locked_until;
    END IF;

    WITH upd AS (
        UPDATE private.documents d
        SET status    = 'draft',
            posted_at = NULL
        WHERE d.organization_id = v_org
          AND d.status          = 'posted'
          AND d.posted_at       >= v_boundary
        RETURNING d.id
    )
    SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_cascade_ids
    FROM upd;

    v_cascade_n := cardinality(v_cascade_ids);

    DELETE FROM private.meter_readings
    WHERE document_id = ANY(v_cascade_ids);
    GET DIAGNOSTICS v_readings_removed = ROW_COUNT;

    DELETE FROM private.debt_movements
    WHERE document_id = ANY(v_cascade_ids);
    GET DIAGNOSTICS v_movements_removed = ROW_COUNT;

    UPDATE private.doc_ownership
    SET status = 'draft'
    WHERE document_id = ANY(v_cascade_ids);

    RETURN jsonb_build_object(
        'ok',                     true,
        'doc_id',                 p_doc_id,
        'boundary_posted_at',     v_boundary,
        'cascade_documents',      v_cascade_n,
        'meter_readings_removed', v_readings_removed,
        'debt_movements_removed', v_movements_removed
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;

GRANT EXECUTE ON FUNCTION api.unpost_meter_reading(UUID) TO authenticated;

COMMENT ON FUNCTION api.unpost_meter_reading(UUID) IS
    'Отмена проведения показания счётчика; каскад по documents.posted_at внутри организации.';
ENDSQL
sudo systemctl reload postgrest-controlling
sleep 2
```

- [ ] **Step 5: Test cascade unpost**

```bash
TOKEN=$(curl -s -X POST http://localhost:3100/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"autotest_chair","p_password":"autotest123"}' | jq -r '.token')

READING2_ID=$(sudo -u postgres psql -d controlling -t -A -c "
SELECT d.id
FROM private.documents d
JOIN private.doc_meter_reading dmr ON dmr.document_id = d.id
WHERE dmr.reading_value = 115.500
  AND d.organization_id = '70b5b02a-f78d-4d6c-bb07-835d62d5a6b8'
  AND d.status = 'posted';")
echo "READING2_ID=$READING2_ID"

# Cascade unpost: reading2 + charge both get reset
curl -s -X POST http://localhost:3100/rpc/unpost_meter_reading \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_doc_id\":\"$READING2_ID\"}"
```
Expected:
```json
[{"ok":true,"doc_id":"...","boundary_posted_at":"...","cascade_documents":2,"meter_readings_removed":1,"debt_movements_removed":1}]
```

```bash
# Verify: reading2 removed from meter_readings register
sudo -u postgres psql -d controlling -c "
SELECT period, reading FROM private.meter_readings
WHERE organization_id='70b5b02a-f78d-4d6c-bb07-835d62d5a6b8'
ORDER BY period;
"
```
Expected: only `2026-04-01 | 100.000` (reading2 deleted from register)

```bash
# Verify: all meter docs now draft
sudo -u postgres psql -d controlling -c "
SELECT doc_type, status, posted_at FROM private.documents
WHERE organization_id='70b5b02a-f78d-4d6c-bb07-835d62d5a6b8'
  AND doc_type IN ('meter_reading','meter_charge')
ORDER BY created_at;
"
```
Expected: all rows show `status=draft`, `posted_at=NULL`

```bash
# Test error: NOT_POSTED (target is now draft)
curl -s -X POST http://localhost:3100/rpc/unpost_meter_reading \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_doc_id\":\"$READING2_ID\"}"
```
Expected: `[{"ok":false,"error":"NOT_POSTED: ..."}]`

```bash
# Test error: WRONG_DOC_TYPE (pass a meter_charge ID)
CHARGE_ID=$(sudo -u postgres psql -d controlling -t -A -c "
SELECT d.id FROM private.documents d
WHERE d.doc_type='meter_charge' AND d.organization_id='70b5b02a-f78d-4d6c-bb07-835d62d5a6b8' LIMIT 1;")
curl -s -X POST http://localhost:3100/rpc/unpost_meter_reading \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_doc_id\":\"$CHARGE_ID\"}"
```
Expected: `[{"ok":false,"error":"WRONG_DOC_TYPE: ожидается meter_reading, получено meter_charge"}]`

- [ ] **Step 6: Commit**

```bash
git add sql/018_meter_readings_and_tariffs.sql
git commit -m "feat(db): migration 018 step 5 — api.unpost_meter_reading (cascade)"
```

---

### Task 6: Update API_CONTRACT.md + BACKEND_MASTER.md + push

**Files:**
- Modify: `API_CONTRACT.md`
- Modify: `BACKEND_MASTER.md`

- [ ] **Step 1: Update API_CONTRACT.md — tariffs section**

In `API_CONTRACT.md`, find the tariffs section (or add it). Add/update:

```markdown
### POST /rpc/set_tariff
Sets (inserts or updates) a tariff for a meter-type contribution type.
```json
{
  "p_org_id": "UUID",
  "p_contribution_type_id": "UUID",
  "p_valid_from": "2026-01-01",
  "p_rate": 4.50
}
```
Response: `{"ok": true, "tariff_id": "UUID"}`
Errors: `INVALID_CONTRIBUTION_TYPE`, `NOT_METER_KIND`, `INVALID_RATE`, `ORG_MISMATCH`
```

- [ ] **Step 2: Update API_CONTRACT.md — create_meter_charge**

Find the `create_meter_charge` section and replace with new signature:

```markdown
### POST /rpc/create_meter_charge
Creates a draft meter charge document with auto-lookup of contribution type, tariff, and readings.
```json
{
  "p_org_id": "UUID",
  "p_meter_id": "UUID",
  "p_doc_date": "2026-05-01",
  "p_notes": null
}
```
Response:
```json
{
  "ok": true,
  "document_id": "UUID",
  "status": "draft",
  "consumption": 15.5,
  "amount": 77.50,
  "reading_current": 115.500,
  "reading_previous": 100.000,
  "tariff_rate": 5.0000
}
```
Errors: `ORG_MISMATCH`, `NO_METER_CONTRIBUTION_TYPE`, `NO_PREVIOUS_READING`, `NO_TARIFF_FOR_DATE`, `INVALID_AMOUNT`
```

- [ ] **Step 3: Update API_CONTRACT.md — unpost functions**

Add after existing meter_reading/meter_charge sections:

```markdown
### POST /rpc/unpost_meter_reading
Cascades: resets all posted docs in org with posted_at >= target posted_at to draft.
Removes entries from meter_readings and debt_movements for affected docs.
```json
{"p_doc_id": "UUID"}
```
Response:
```json
{
  "ok": true,
  "doc_id": "UUID",
  "boundary_posted_at": "2026-05-19T10:00:00Z",
  "cascade_documents": 2,
  "meter_readings_removed": 1,
  "debt_movements_removed": 1
}
```
Errors: `DOC_NOT_FOUND`, `WRONG_DOC_TYPE`, `NOT_POSTED`, `PERIOD_LOCKED`, `ORG_MISMATCH`

### POST /rpc/unpost_meter_charge
Point unpost: removes only this charge's debt_movements, resets doc to draft.
```json
{"p_doc_id": "UUID"}
```
Response: `{"ok": true, "doc_id": "UUID", "amount_reversed": 77.50}`
Errors: `DOC_NOT_FOUND`, `WRONG_DOC_TYPE`, `NOT_POSTED`, `PERIOD_LOCKED`, `ORG_MISMATCH`
```

- [ ] **Step 4: Update contribution_types in API_CONTRACT.md**

Note that `contribution_types` now has a `meter_type` field (returned in GET responses and required for POST when `kind='meter'`).

- [ ] **Step 5: Update BACKEND_MASTER.md migrations table**

In the migrations table, add row:
```
| 018 | Тарифы + unpost для счётчиков: set_tariff, rewrite create_meter_charge, unpost_meter_reading (каскад), unpost_meter_charge |
```

- [ ] **Step 6: Final commit + push**

```bash
cd /home/roman/controlling-backend
git add API_CONTRACT.md BACKEND_MASTER.md
git commit -m "docs: update API_CONTRACT and BACKEND_MASTER for migration 018"
git push github main
```

---

## Tech Debt (not in this plan)

1. `doc_meter_correction` — function `post_meter_correction` with reversal logic, for corrections in closed periods
2. `FK doc_meter_charge.reading_document_id` — direct reference to reading doc for point cascade without timestamp dependency
3. Different tariffs for different meters of same type — requires `contribution_type_id` on `meters` table
4. `unpost_meter_reading` does NOT restore `financial_object_registry` if ownership docs are in cascade — ownership may be inconsistent in that edge case
