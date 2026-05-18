# Plan: Migration 015 — org_settings_history

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Добавить периодический регистр настроек организации (`private.org_settings_history`) и обновить `api.org_settings` + новая RPC `api.set_meter_types`.

**Architecture:** Sequential EAV — одна таблица, строка = (org, дата, имя_настройки, значение_jsonb). Текущее значение читается через COALESCE-подзапрос в view, дефолт `["water","electricity","gas"]` если записей нет. RPC-паттерн идентичен `set_lock_date`.

**Tech Stack:** PostgreSQL 16 (native), PostgREST v14 (native systemd).

**Spec:** `docs/superpowers/specs/2026-05-18-org-settings-history.md`

---

## Карта файлов

| Файл | Действие |
|------|---------|
| `sql/015_org_settings_history.sql` | Создать — таблица + view + RPC + grant |
| `API_CONTRACT.md` | Изменить — org_settings колонка + set_meter_types endpoint |

---

## Task 1: Написать миграцию 015

**Files:**
- Create: `sql/015_org_settings_history.sql`

- [ ] **Step 1: Создать файл миграции**

Файл `sql/015_org_settings_history.sql`:

```sql
-- 015_org_settings_history.sql
-- Периодический регистр настроек организации (sequential EAV).
-- Первая настройка: enabled_meter_types TEXT[].

-- ---------------------------------------------------------------------------
-- 1. Таблица private.org_settings_history
-- ---------------------------------------------------------------------------
CREATE TABLE private.org_settings_history (
    organization_id  UUID NOT NULL REFERENCES private.organizations(id),
    effective_from   DATE NOT NULL,
    setting_name     TEXT NOT NULL,
    setting_value    JSONB NOT NULL,
    created_at       TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (organization_id, effective_from, setting_name)
);

COMMENT ON TABLE private.org_settings_history IS
    'Периодический регистр настроек организации. Строка = значение одной настройки на одну дату. '
    'Запрос актуального значения: WHERE effective_from <= DATE ORDER BY effective_from DESC LIMIT 1.';

-- ---------------------------------------------------------------------------
-- 2. Обновить api.org_settings — добавить enabled_meter_types
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.org_settings AS
SELECT
    o.id AS organization_id,
    pl.locked_until AS lock_date,
    o.current_period,
    COALESCE(
        (SELECT (h.setting_value #>> '{}')::TEXT[]
         FROM private.org_settings_history h
         WHERE h.organization_id = o.id
           AND h.setting_name    = 'enabled_meter_types'
           AND h.effective_from  <= CURRENT_DATE
         ORDER BY h.effective_from DESC LIMIT 1),
        ARRAY['water','electricity','gas']
    ) AS enabled_meter_types
FROM private.organizations o
LEFT JOIN private.period_locks pl ON pl.organization_id = o.id;

GRANT SELECT ON api.org_settings TO authenticated;

COMMENT ON VIEW api.org_settings IS
    'Настройки организации: lock_date, current_period, enabled_meter_types (текущее, дефолт: все три типа).';

-- ---------------------------------------------------------------------------
-- 3. RPC api.set_meter_types
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_meter_types(p_org_id UUID, p_types TEXT[])
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_allowed TEXT[] := ARRAY['water','electricity','gas'];
    v_type    TEXT;
BEGIN
    -- Проверка: только для своей организации
    IF private.current_org_id() IS NOT NULL AND p_org_id <> private.current_org_id() THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;

    -- Проверка: минимум 1 тип
    IF p_types IS NULL OR array_length(p_types, 1) IS NULL THEN
        RAISE EXCEPTION 'EMPTY_TYPES';
    END IF;

    -- Проверка: только допустимые типы
    FOREACH v_type IN ARRAY p_types LOOP
        IF NOT (v_type = ANY(v_allowed)) THEN
            RAISE EXCEPTION 'INVALID_METER_TYPE: %', v_type;
        END IF;
    END LOOP;

    INSERT INTO private.org_settings_history
        (organization_id, effective_from, setting_name, setting_value)
    VALUES
        (p_org_id, CURRENT_DATE, 'enabled_meter_types', to_jsonb(p_types))
    ON CONFLICT (organization_id, effective_from, setting_name) DO UPDATE
        SET setting_value = EXCLUDED.setting_value,
            created_at    = now();

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_meter_types(UUID, TEXT[]) TO authenticated;

COMMENT ON FUNCTION api.set_meter_types IS
    'Установить типы счётчиков для организации на текущую дату. '
    'Допустимые типы: water, electricity, gas. Минимум 1 тип.';
```

> **IMPORTANT:** Для `enabled_meter_types` в view JSONB-массив читается через `setting_value #>> '{}'` нельзя — это скалярный оператор. Правильно: подзапрос возвращает `JSONB`, затем кастуем через `ARRAY(SELECT jsonb_array_elements_text(h.setting_value))` или хранить как `TEXT[]` в JSONB и доставать через `ARRAY(SELECT jsonb_array_elements_text(...))`. Уточнение ниже в Step 2.

- [ ] **Step 2: Уточнить приведение JSONB → TEXT[] в view**

Проблема: `(h.setting_value #>> '{}')::TEXT[]` не работает для JSONB-массива.  
Правильный вариант для подзапроса:

```sql
COALESCE(
    ARRAY(
        SELECT jsonb_array_elements_text(h.setting_value)
        FROM private.org_settings_history h
        WHERE h.organization_id = o.id
          AND h.setting_name    = 'enabled_meter_types'
          AND h.effective_from  <= CURRENT_DATE
        ORDER BY h.effective_from DESC LIMIT 1
    ),
    ARRAY['water','electricity','gas']
) AS enabled_meter_types
```

Использовать именно этот вариант в финальном SQL.

- [ ] **Step 3: Написать финальный файл миграции**

Записать в `sql/015_org_settings_history.sql` с правильным JSONB-кастом из Step 2.

---

## Task 2: Применить на тест-контур и проверить

- [ ] **Step 1: Применить миграцию на тест**

```bash
migrate-test.sh /home/roman/controlling-backend/sql/015_org_settings_history.sql
```

Ожидаемый вывод: `CREATE TABLE`, `CREATE VIEW`, `GRANT`, `CREATE FUNCTION`, `GRANT`, `COMMENT` — без ошибок.

- [ ] **Step 2: Проверить таблицу в БД**

```bash
sudo -u postgres psql -d controlling_test -c "\d private.org_settings_history"
```

Ожидаемый вывод: таблица с колонками `organization_id`, `effective_from`, `setting_name`, `setting_value`, `created_at`.

- [ ] **Step 3: Проверить view — дефолт без записей**

```bash
TOKEN=$(curl -s -X POST http://localhost/pg-test/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"demo_a_chair","p_password":"chair123"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost/pg-test/org_settings" | python3 -m json.tool
```

Ожидаемый вывод: `"enabled_meter_types": ["water","electricity","gas"]` (дефолт, т.к. история пуста).

- [ ] **Step 4: Проверить set_meter_types — успешный вызов**

```bash
# Получить organization_id
ORG_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost/pg-test/org_settings" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['organization_id'])")

# Установить только water и gas
curl -s -X POST http://localhost/pg-test/rpc/set_meter_types \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\": \"$ORG_ID\", \"p_types\": [\"water\",\"gas\"]}"
```

Ожидаемый вывод: `{"ok": true}`.

- [ ] **Step 5: Проверить что view обновилась**

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost/pg-test/org_settings" | python3 -m json.tool
```

Ожидаемый вывод: `"enabled_meter_types": ["water","gas"]`.

- [ ] **Step 6: Проверить валидацию — недопустимый тип**

```bash
curl -s -X POST http://localhost/pg-test/rpc/set_meter_types \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\": \"$ORG_ID\", \"p_types\": [\"water\",\"heat\"]}"
```

Ожидаемый вывод: `{"ok": false, "error": "INVALID_METER_TYPE: heat"}`.

- [ ] **Step 7: Проверить валидацию — пустой массив**

```bash
curl -s -X POST http://localhost/pg-test/rpc/set_meter_types \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"p_org_id\": \"$ORG_ID\", \"p_types\": []}"
```

Ожидаемый вывод: `{"ok": false, "error": "EMPTY_TYPES"}`.

---

## Task 3: Применить на прод

- [ ] **Step 1: Применить миграцию на прод**

```bash
migrate-prod.sh /home/roman/controlling-backend/sql/015_org_settings_history.sql
```

Ожидаемый вывод: `Снимок сохранён`, `CREATE TABLE`, `CREATE VIEW`, `GRANT`, `CREATE FUNCTION`, `GRANT`, `COMMENT`, `Готово`.

- [ ] **Step 2: Проверить на проде**

```bash
TOKEN=$(curl -s -X POST http://localhost/pg/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"demo_a_chair","p_password":"chair123"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost/pg/org_settings" | python3 -m json.tool
```

Ожидаемый вывод: `"enabled_meter_types": ["water","electricity","gas"]` (дефолт).

---

## Task 4: Обновить API_CONTRACT.md и закоммитить

**Files:**
- Modify: `API_CONTRACT.md`

- [ ] **Step 1: Обновить API_CONTRACT.md**

В секцию `org_settings` добавить описание новой колонки:

```markdown
**Поля:**
- `organization_id` — UUID организации
- `lock_date` — дата запрета изменений (null если не установлена)
- `current_period` — рабочая дата периода (null если не установлена)
- `enabled_meter_types` — типы счётчиков: `["water","electricity","gas"]` (дефолт если не задано)
```

Добавить новый endpoint:

```markdown
### POST /rpc/set_meter_types

Установить типы счётчиков для организации.

**Параметры:**
- `p_org_id` UUID — ID организации
- `p_types` TEXT[] — массив типов: `["water","electricity","gas"]`

**Допустимые типы:** `water`, `electricity`, `gas`. Минимум 1.

**Пример запроса:**
```
POST /pg/rpc/set_meter_types
Authorization: Bearer <token>
Content-Type: application/json

{"p_org_id": "uuid", "p_types": ["water","gas"]}
```

**Ответ:**
```json
{"ok": true}
```

**Ошибки:**
- `{"ok": false, "error": "EMPTY_TYPES"}` — пустой массив
- `{"ok": false, "error": "INVALID_METER_TYPE: heat"}` — недопустимый тип
- `{"ok": false, "error": "ORG_MISMATCH"}` — нет доступа к организации
```

- [ ] **Step 2: Commit**

```bash
cd /home/roman/controlling-backend
git add sql/015_org_settings_history.sql API_CONTRACT.md \
        docs/superpowers/specs/2026-05-18-org-settings-history.md \
        docs/superpowers/plans/2026-05-18-org-settings-history.md
git commit -m "feat(db): org_settings_history + enabled_meter_types + set_meter_types RPC (migration 015)"
```

- [ ] **Step 3: Push**

```bash
git push github main
```

---

## Итоговая проверка

- [ ] `sudo -u postgres psql -d controlling -c "\d private.org_settings_history"` → таблица существует
- [ ] `sudo -u postgres psql -d controlling_test -c "\d private.org_settings_history"` → таблица существует
- [ ] `GET /pg/org_settings` → `enabled_meter_types: ["water","electricity","gas"]` (дефолт)
- [ ] `POST /pg/rpc/set_meter_types {"p_types": ["water"]}` → `{"ok": true}`
- [ ] `GET /pg/org_settings` после set → `enabled_meter_types: ["water"]`
- [ ] `POST /pg/rpc/set_meter_types {"p_types": ["heat"]}` → `{"ok": false, "error": "INVALID_METER_TYPE: heat"}`
- [ ] `POST /pg/rpc/set_meter_types {"p_types": []}` → `{"ok": false, "error": "EMPTY_TYPES"}`
