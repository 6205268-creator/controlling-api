# Migration 022 — Org Settings Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить `private.org_setting_definitions` — реестр допустимых настроек; пересоздать `api.org_settings` как view в формате (org × setting); добавить `api.set_org_setting` с валидацией; сделать `set_meter_types` враппером.

**Architecture:** Новая таблица-справочник `private.org_setting_definitions` содержит все допустимые имена настроек, их типы, допустимые значения и дефолты. FK из `org_settings_history.setting_name → org_setting_definitions.setting_name` предотвращает произвольные имена. View `api.org_settings` перестраивается: вместо одной строки на орг возвращает `N_settings × N_orgs` строк — одна на (org, setting). Новый RPC `set_org_setting(org, name, value jsonb)` валидирует тип, enum-значения и кросс-правило use_meters↔enabled_meter_types, затем делает UPSERT. `set_meter_types` остаётся как backward-compat враппер.

**⚠️ Breaking change:** `api.org_settings` меняет схему. Старые колонки `lock_date`, `current_period`, `enabled_meter_types` исчезают. Новые: `setting_name`, `value_type`, `description`, `allowed_values`, `default_value`, `current_value`. Фронтенд должен адаптировать запрос.

**Tech Stack:** PostgreSQL 16, PostgREST v14 (systemd), Alembic (migration bookmark only — SQL применяется вручную через psql stdin).

**Spec:** `docs/superpowers/specs/2026-05-20-org-settings-registry-brainstorm.md`

---

## Карта файлов

| Файл | Действие | Что |
|------|---------|-----|
| `sql/022_org_settings_registry.sql` | Создать | Полная миграция |
| `migrations/versions/<auto_id>_022_org_settings_registry.py` | Создать | Alembic bookmark |
| `API_CONTRACT.md` | Изменить | GET /org_settings, новый POST /rpc/set_org_setting, коды ошибок |

---

## Task 1: SQL-файл миграции

**Files:**
- Create: `sql/022_org_settings_registry.sql`

- [ ] **Step 1: Создать файл**

Содержимое `sql/022_org_settings_registry.sql`:

```sql
-- =============================================================================
-- Migration 022: org_settings_registry
-- Adds private.org_setting_definitions; rebuilds api.org_settings view
-- (one row per org × setting); adds api.set_org_setting RPC;
-- rewrites set_meter_types as a thin wrapper.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Таблица private.org_setting_definitions
-- ---------------------------------------------------------------------------
CREATE TABLE private.org_setting_definitions (
    setting_name   TEXT    PRIMARY KEY,
    value_type     TEXT    NOT NULL
                           CHECK (value_type IN ('boolean','integer','text','enum','enum[]')),
    allowed_values JSONB,
    default_value  JSONB   NOT NULL,
    description    TEXT    NOT NULL,
    is_active      BOOLEAN NOT NULL DEFAULT true
);

COMMENT ON TABLE private.org_setting_definitions IS
    'Реестр допустимых настроек организации. '
    'Каждая строка — одна настройка с типом, допустимыми значениями и дефолтом.';

-- ---------------------------------------------------------------------------
-- 2. Seed — 4 настройки
-- ---------------------------------------------------------------------------
INSERT INTO private.org_setting_definitions
    (setting_name, value_type, allowed_values, default_value, description)
VALUES
    ('use_meters',
     'boolean',
     NULL,
     'false'::jsonb,
     'Использовать счётчики'),

    ('enabled_meter_types',
     'enum[]',
     '["water","electricity","gas"]'::jsonb,
     '[]'::jsonb,
     'Виды счётчиков'),

    ('legal_address',
     'text',
     NULL,
     'null'::jsonb,
     'Юридический адрес'),

    ('postal_address',
     'text',
     NULL,
     'null'::jsonb,
     'Почтовый адрес');

-- ---------------------------------------------------------------------------
-- 3. FK org_settings_history.setting_name → org_setting_definitions
-- Выполняем ПОСЛЕ seed, т.к. в history уже есть строки с 'enabled_meter_types'.
-- ---------------------------------------------------------------------------
ALTER TABLE private.org_settings_history
    ADD CONSTRAINT fk_org_settings_history_setting_name
    FOREIGN KEY (setting_name)
    REFERENCES private.org_setting_definitions(setting_name);

-- ---------------------------------------------------------------------------
-- 4. Пересоздать api.org_settings
-- Схема меняется кардинально — DROP + CREATE (не CREATE OR REPLACE).
-- Старые колонки: organization_id, lock_date, current_period, enabled_meter_types.
-- Новые: organization_id, setting_name, value_type, description,
--         allowed_values, default_value, current_value.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS api.org_settings;

CREATE VIEW api.org_settings AS
SELECT
    o.id                                                     AS organization_id,
    d.setting_name,
    d.value_type,
    d.description,
    d.allowed_values,
    d.default_value,
    COALESCE(h_latest.setting_value, d.default_value)        AS current_value
FROM private.organizations         o
CROSS JOIN private.org_setting_definitions d
LEFT JOIN LATERAL (
    SELECT h.setting_value
    FROM private.org_settings_history h
    WHERE h.organization_id = o.id
      AND h.setting_name    = d.setting_name
      AND h.effective_from  <= CURRENT_DATE
    ORDER BY h.effective_from DESC
    LIMIT 1
) h_latest ON true
WHERE d.is_active = true;

GRANT SELECT ON api.org_settings TO authenticated;

COMMENT ON VIEW api.org_settings IS
    'Текущие настройки организаций: одна строка на (org, setting). '
    'current_value = последнее значение из истории или default_value из реестра.';

-- ---------------------------------------------------------------------------
-- 5. RPC api.set_org_setting
-- Валидирует тип, enum-значения, кросс-правило use_meters / enabled_meter_types.
-- UPSERT в org_settings_history на CURRENT_DATE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_org_setting(
    p_org_id       UUID,
    p_setting_name TEXT,
    p_value        JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_def         private.org_setting_definitions%ROWTYPE;
    v_ctx_org     UUID;
    v_elem        JSONB;
    v_elem_text   TEXT;
    v_meter_types JSONB;
BEGIN
    v_ctx_org := private.current_org_id();
    IF v_ctx_org IS NOT NULL AND p_org_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;

    -- 1. Найти настройку в реестре
    SELECT * INTO v_def
    FROM private.org_setting_definitions
    WHERE setting_name = p_setting_name;

    IF NOT FOUND OR NOT v_def.is_active THEN
        RAISE EXCEPTION 'UNKNOWN_SETTING: %', p_setting_name;
    END IF;

    -- 2. Валидация типа
    IF v_def.value_type = 'boolean' THEN
        IF jsonb_typeof(p_value) <> 'boolean' THEN
            RAISE EXCEPTION 'INVALID_SETTING_VALUE: expected boolean, got %', jsonb_typeof(p_value);
        END IF;

    ELSIF v_def.value_type = 'integer' THEN
        IF jsonb_typeof(p_value) <> 'number' THEN
            RAISE EXCEPTION 'INVALID_SETTING_VALUE: expected integer, got %', jsonb_typeof(p_value);
        END IF;

    ELSIF v_def.value_type = 'text' THEN
        IF jsonb_typeof(p_value) NOT IN ('string', 'null') THEN
            RAISE EXCEPTION 'INVALID_SETTING_VALUE: expected text or null, got %', jsonb_typeof(p_value);
        END IF;

    ELSIF v_def.value_type = 'enum' THEN
        IF jsonb_typeof(p_value) <> 'string' THEN
            RAISE EXCEPTION 'INVALID_SETTING_VALUE: expected string, got %', jsonb_typeof(p_value);
        END IF;
        IF v_def.allowed_values IS NOT NULL AND NOT (v_def.allowed_values @> p_value) THEN
            RAISE EXCEPTION 'INVALID_ENUM_VALUE: % not in allowed values', p_value #>> '{}';
        END IF;

    ELSIF v_def.value_type = 'enum[]' THEN
        IF jsonb_typeof(p_value) <> 'array' THEN
            RAISE EXCEPTION 'INVALID_SETTING_VALUE: expected array, got %', jsonb_typeof(p_value);
        END IF;
        IF v_def.allowed_values IS NOT NULL THEN
            FOR v_elem IN SELECT * FROM jsonb_array_elements(p_value) LOOP
                IF NOT (v_def.allowed_values @> v_elem) THEN
                    v_elem_text := v_elem #>> '{}';
                    RAISE EXCEPTION 'INVALID_ENUM_VALUE: % not in allowed values', v_elem_text;
                END IF;
            END LOOP;
        END IF;
    END IF;

    -- 3. Кросс-валидация: use_meters=true требует непустого enabled_meter_types
    IF p_setting_name = 'use_meters' AND p_value = 'true'::jsonb THEN
        SELECT h.setting_value INTO v_meter_types
        FROM private.org_settings_history h
        WHERE h.organization_id = p_org_id
          AND h.setting_name    = 'enabled_meter_types'
          AND h.effective_from  <= CURRENT_DATE
        ORDER BY h.effective_from DESC
        LIMIT 1;

        -- Нет истории — берём дефолт из реестра (=[])
        IF v_meter_types IS NULL THEN
            SELECT d2.default_value INTO v_meter_types
            FROM private.org_setting_definitions d2
            WHERE d2.setting_name = 'enabled_meter_types';
        END IF;

        IF v_meter_types IS NULL OR jsonb_array_length(v_meter_types) = 0 THEN
            RAISE EXCEPTION 'METER_TYPES_REQUIRED: set enabled_meter_types before enabling use_meters';
        END IF;
    END IF;

    -- 4. UPSERT
    INSERT INTO private.org_settings_history
        (organization_id, effective_from, setting_name, setting_value)
    VALUES
        (p_org_id, CURRENT_DATE, p_setting_name, p_value)
    ON CONFLICT (organization_id, effective_from, setting_name) DO UPDATE
        SET setting_value = EXCLUDED.setting_value,
            created_at    = now();

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_org_setting(UUID, TEXT, JSONB) TO authenticated;

COMMENT ON FUNCTION api.set_org_setting IS
    'Установить настройку организации. Валидирует value_type, enum-значения, '
    'кросс-правило use_meters/enabled_meter_types. UPSERT на CURRENT_DATE.';

-- ---------------------------------------------------------------------------
-- 6. set_meter_types → враппер поверх set_org_setting
-- Сохраняет обратную совместимость. EMPTY_TYPES проверяется здесь же.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_meter_types(p_org_id UUID, p_types TEXT[])
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF p_types IS NULL OR array_length(p_types, 1) IS NULL THEN
        RAISE EXCEPTION 'EMPTY_TYPES';
    END IF;
    RETURN api.set_org_setting(p_org_id, 'enabled_meter_types', to_jsonb(p_types));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_meter_types(UUID, TEXT[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. PostgREST schema reload
-- ---------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
```

- [ ] **Step 2: Убедиться что файл создан**

```bash
wc -l /home/roman/controlling-backend/sql/022_org_settings_registry.sql
```

Ожидаемый результат: `~160 строк`.

---

## Task 2: Применить миграцию к БД

**Files:** (только БД)

> **ВАЖНО:** Согласно правилу `sql-migration-approval.md` — сначала показать SQL пользователю, дождаться явного «применяй», затем выполнять через stdin-пайп.

- [ ] **Step 1: Показать содержимое файла пользователю**

```bash
cat /home/roman/controlling-backend/sql/022_org_settings_registry.sql
```

**Подождать явного ответа пользователя: «применяй» или «apply».**

- [ ] **Step 2: Применить через stdin**

```bash
cat /home/roman/controlling-backend/sql/022_org_settings_registry.sql | sudo -u postgres psql -d controlling
```

Ожидаемый результат: вывод без `ERROR`, завершается строкой `NOTIFY`.

- [ ] **Step 3: Проверить что таблица создана**

```bash
sudo -u postgres psql -d controlling -c "\d private.org_setting_definitions"
```

Ожидаемый вывод: таблица с колонками `setting_name, value_type, allowed_values, default_value, description, is_active`.

- [ ] **Step 4: Проверить seed**

```bash
sudo -u postgres psql -d controlling -c "SELECT setting_name, value_type, default_value FROM private.org_setting_definitions ORDER BY setting_name;"
```

Ожидаемый вывод: 4 строки — `enabled_meter_types`, `legal_address`, `postal_address`, `use_meters`.

- [ ] **Step 5: Проверить FK**

```bash
sudo -u postgres psql -d controlling -c "\d private.org_settings_history"
```

Ожидаемый вывод: FK `fk_org_settings_history_setting_name` присутствует.

- [ ] **Step 6: Проверить view через PostgREST**

```bash
# Получить UUID первой орги из БД
ORG_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.organizations LIMIT 1;")
echo "org_id: $ORG_ID"

# Запрос без токена через суперпользователя напрямую
sudo -u postgres psql -d controlling -c \
  "SELECT setting_name, value_type, current_value FROM api.org_settings WHERE organization_id = '$ORG_ID';"
```

Ожидаемый вывод: 4 строки — `enabled_meter_types` (current_value=`[]`), `legal_address` (null), `postal_address` (null), `use_meters` (false).

- [ ] **Step 7: Проверить set_org_setting через psql**

```bash
ORG_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.organizations LIMIT 1;")

# Установить legal_address
sudo -u postgres psql -d controlling -c \
  "SELECT api.set_org_setting('$ORG_ID'::uuid, 'legal_address', '\"ул. Ленина, 1\"'::jsonb);"
```

Ожидаемый вывод: `{"ok": true}`.

- [ ] **Step 8: Проверить UNKNOWN_SETTING**

```bash
ORG_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.organizations LIMIT 1;")
sudo -u postgres psql -d controlling -c \
  "SELECT api.set_org_setting('$ORG_ID'::uuid, 'nonexistent', '\"val\"'::jsonb);"
```

Ожидаемый вывод: `{"ok": false, "error": "UNKNOWN_SETTING: nonexistent"}`.

- [ ] **Step 9: Проверить METER_TYPES_REQUIRED**

```bash
ORG_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.organizations LIMIT 1;")
# enabled_meter_types дефолт = [], поэтому use_meters=true должен вернуть ошибку
sudo -u postgres psql -d controlling -c \
  "SELECT api.set_org_setting('$ORG_ID'::uuid, 'use_meters', 'true'::jsonb);"
```

Ожидаемый вывод: `{"ok": false, "error": "METER_TYPES_REQUIRED: set enabled_meter_types before enabling use_meters"}`.

- [ ] **Step 10: Проверить успешный use_meters=true после установки типов**

```bash
ORG_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.organizations LIMIT 1;")

# Сначала установить типы
sudo -u postgres psql -d controlling -c \
  "SELECT api.set_org_setting('$ORG_ID'::uuid, 'enabled_meter_types', '[\"water\"]'::jsonb);"

# Теперь включить use_meters
sudo -u postgres psql -d controlling -c \
  "SELECT api.set_org_setting('$ORG_ID'::uuid, 'use_meters', 'true'::jsonb);"
```

Ожидаемый вывод обоих: `{"ok": true}`.

- [ ] **Step 11: Проверить set_meter_types (враппер)**

```bash
ORG_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.organizations LIMIT 1;")
sudo -u postgres psql -d controlling -c \
  "SELECT api.set_meter_types('$ORG_ID'::uuid, ARRAY['water','gas']);"
```

Ожидаемый вывод: `{"ok": true}`.

---

## Task 3: Alembic revision

**Files:**
- Create: `migrations/versions/<auto_id>_022_org_settings_registry.py`

- [ ] **Step 1: Сгенерировать ревизию**

```bash
cd /home/roman/controlling-backend && .venv/bin/alembic revision -m "022_org_settings_registry"
```

Запомнить путь к созданному файлу из вывода (строка `Generating ...`).

- [ ] **Step 2: Отредактировать ревизию**

Открыть созданный файл. Установить:
- `down_revision = '95d6c8bc2397'` (текущий head — revision 021)
- Тело `upgrade()` и `downgrade()`:

```python
def upgrade() -> None:
    op.execute("SELECT 1")  # applied manually via sql/022_org_settings_registry.sql


def downgrade() -> None:
    pass
```

- [ ] **Step 3: Применить ревизию (no-op SELECT 1)**

```bash
cd /home/roman/controlling-backend && .venv/bin/alembic upgrade head
```

Ожидаемый вывод: `Running upgrade 95d6c8bc2397 -> <new_id>, 022_org_settings_registry`.

- [ ] **Step 4: Проверить head**

```bash
cd /home/roman/controlling-backend && .venv/bin/alembic current
```

Ожидаемый вывод: `<new_revision_id> (head)`.

---

## Task 4: Обновить API_CONTRACT.md

**Files:**
- Modify: `API_CONTRACT.md`

- [ ] **Step 1: Обновить секцию `## Настройки организации`**

Найти строку 981 (`## Настройки организации`) и заменить весь блок до следующей `##` (строка `## Владение объектами`, ~строка 1067):

```markdown
## Настройки организации

Учётная политика — параметры ведения учёта для каждой организации.  
Хранятся в `private.org_settings_history` (история по датам) и `private.org_setting_definitions` (реестр допустимых настроек, migration 022).

### GET /org_settings
Текущие настройки организации. Возвращает по одной строке на каждую активную настройку.

```
GET /pg/org_settings?organization_id=eq.<uuid>
Authorization: Bearer <token>
```

**Response:**
```json
[
  {
    "organization_id": "uuid",
    "setting_name":    "use_meters",
    "value_type":      "boolean",
    "description":     "Использовать счётчики",
    "allowed_values":  null,
    "default_value":   false,
    "current_value":   false
  },
  {
    "organization_id": "uuid",
    "setting_name":    "enabled_meter_types",
    "value_type":      "enum[]",
    "description":     "Виды счётчиков",
    "allowed_values":  ["water", "electricity", "gas"],
    "default_value":   [],
    "current_value":   ["water"]
  },
  {
    "organization_id": "uuid",
    "setting_name":    "legal_address",
    "value_type":      "text",
    "description":     "Юридический адрес",
    "allowed_values":  null,
    "default_value":   null,
    "current_value":   "ул. Ленина, 1"
  },
  {
    "organization_id": "uuid",
    "setting_name":    "postal_address",
    "value_type":      "text",
    "description":     "Почтовый адрес",
    "allowed_values":  null,
    "default_value":   null,
    "current_value":   null
  }
]
```

| Поле | Описание |
|------|----------|
| `setting_name` | Имя настройки — ключ |
| `value_type` | Тип значения: `boolean`, `integer`, `text`, `enum`, `enum[]` |
| `description` | Человекочитаемое описание |
| `allowed_values` | JSON-массив допустимых значений (для `enum`/`enum[]`), иначе null |
| `default_value` | Значение по умолчанию (JSONB) |
| `current_value` | Актуальное значение: из `org_settings_history` или `default_value` если не установлено |

> **Migration note:** до migration 022 view возвращал одну строку с колонками `lock_date`, `current_period`, `enabled_meter_types`. Схема изменена.

### POST /rpc/set_org_setting
Установить значение любой настройки организации.

```
POST /pg/rpc/set_org_setting
Authorization: Bearer <token>
Content-Type: application/json
```

**Request:**
```json
{ "p_org_id": "uuid", "p_setting_name": "legal_address", "p_value": "ул. Ленина, 1" }
```

`p_value` передаётся как JSONB: строки в кавычках (`"text"`), числа без (`42`), булевы (`true`/`false`), массивы (`["water","gas"]`).

**Response:** `{"ok": true}`

**Ошибки:**
- `UNKNOWN_SETTING: <name>` — имя не найдено в реестре или настройка деактивирована
- `INVALID_SETTING_VALUE: expected <type>` — тип значения не совпадает
- `INVALID_ENUM_VALUE: <value> not in allowed values` — значение вне допустимых
- `METER_TYPES_REQUIRED` — попытка установить `use_meters=true` при пустом `enabled_meter_types`
- `ORG_MISMATCH` — чужая организация

### POST /rpc/set_meter_types
Установить активные типы счётчиков. Враппер поверх `set_org_setting` для обратной совместимости.

```
POST /pg/rpc/set_meter_types
Authorization: Bearer <token>
Content-Type: application/json
```

**Request:**
```json
{ "p_org_id": "uuid", "p_types": ["water", "electricity"] }
```

**Response:** `{"ok": true}`

**Ошибки:** `EMPTY_TYPES`, `INVALID_ENUM_VALUE: <значение>`, `ORG_MISMATCH`.

Изменение сохраняется в историю с датой `CURRENT_DATE`.

### POST /rpc/set_lock_date
```

- [ ] **Step 2: Добавить 4 новых кода ошибок в таблицу `## Коды ошибок RPC`**

В секции `## Коды ошибок RPC` (строка ~138) добавить 4 строки после `| \`INVALID_METER_TYPE\` | ... |`:

```markdown
| `UNKNOWN_SETTING` | Имя настройки не найдено в `org_setting_definitions` или настройка деактивирована |
| `INVALID_SETTING_VALUE` | Тип значения не соответствует `value_type` настройки |
| `INVALID_ENUM_VALUE` | Значение не входит в `allowed_values` настройки |
| `METER_TYPES_REQUIRED` | `use_meters=true` при пустом `enabled_meter_types` |
```

---

## Task 5: Commit и push

**Files:** (все изменённые выше)

- [ ] **Step 1: Проверить статус**

```bash
cd /home/roman/controlling-backend && git status
```

Ожидаемый вывод: новые/изменённые файлы `sql/022_org_settings_registry.sql`, `migrations/versions/<id>_022_org_settings_registry.py`, `API_CONTRACT.md`.

- [ ] **Step 2: Проверить что PostgREST жив**

```bash
curl -s http://localhost:3100/rpc/health | jq .
```

Ожидаемый вывод: `{"status": "ok"}` (или аналогичный ответ без ошибок).

- [ ] **Step 3: Закоммитить**

```bash
cd /home/roman/controlling-backend
git add sql/022_org_settings_registry.sql API_CONTRACT.md
git add migrations/versions/
git commit -m "$(cat <<'EOF'
feat(db): migration 022 — org settings registry

Add private.org_setting_definitions (setting registry), FK from
org_settings_history.setting_name, rebuild api.org_settings as
org×setting view, add api.set_org_setting RPC with type/enum/cross
validation, rewrite set_meter_types as wrapper.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Push**

```bash
git push github main
```

Ожидаемый вывод: `Branch 'main' set up to track remote branch 'main' from 'github'` (или `Everything up-to-date`).
