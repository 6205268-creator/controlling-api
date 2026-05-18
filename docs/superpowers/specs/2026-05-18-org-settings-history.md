# Спека: Исторические настройки организации (org_settings_history)

**Дата:** 2026-05-18  
**Статус:** утверждена  
**Миграция:** 015

---

## Цель

Добавить периодический регистр настроек организации — чтобы каждая настройка хранила историю изменений по дате. Первая настройка: `enabled_meter_types` — какие типы счётчиков использует организация.

---

## Архитектура: Sequential EAV

Одна таблица-история, где каждая строка — это значение одной настройки на одну дату. Паттерн аналогичен периодическому регистру сведений 1С.

```sql
CREATE TABLE private.org_settings_history (
    organization_id  UUID NOT NULL REFERENCES private.organizations(id),
    effective_from   DATE NOT NULL,
    setting_name     TEXT NOT NULL,   -- 'enabled_meter_types', 'chairman', 'min_wage'...
    setting_value    JSONB NOT NULL,  -- ["water","gas"] или "Иванов" или 125.50
    created_at       TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (organization_id, effective_from, setting_name)
);
```

**Почему sequential, а не одна строка на дату:**
- Нет пустых колонок для старых записей
- Новая настройка = новое `setting_name`, без `ALTER TABLE`
- Каждая настройка меняется независимо

**Запрос «настройка на дату D»:**
```sql
SELECT setting_value FROM private.org_settings_history
WHERE organization_id = $1 AND setting_name = 'enabled_meter_types'
  AND effective_from <= $2
ORDER BY effective_from DESC LIMIT 1
```

---

## Что реализуется в migration 015

### 1. Таблица `private.org_settings_history`

Как описана выше. PRIMARY KEY: `(organization_id, effective_from, setting_name)`.

### 2. Обновлённая view `api.org_settings`

Добавить колонку `enabled_meter_types` — текущее значение (на `CURRENT_DATE`).  
Дефолт если записи нет: `["water","electricity","gas"]`.

**До (из migration 013):**
```sql
CREATE OR REPLACE VIEW api.org_settings AS
SELECT
    o.id AS organization_id,
    pl.locked_until AS lock_date,
    o.current_period
FROM private.organizations o
LEFT JOIN private.period_locks pl ON pl.organization_id = o.id;
```

**После:**
```sql
CREATE OR REPLACE VIEW api.org_settings AS
SELECT
    o.id AS organization_id,
    pl.locked_until AS lock_date,
    o.current_period,
    COALESCE(
        (SELECT (h.setting_value)::TEXT[]
         FROM private.org_settings_history h
         WHERE h.organization_id = o.id
           AND h.setting_name = 'enabled_meter_types'
           AND h.effective_from <= CURRENT_DATE
         ORDER BY h.effective_from DESC LIMIT 1),
        ARRAY['water','electricity','gas']
    ) AS enabled_meter_types
FROM private.organizations o
LEFT JOIN private.period_locks pl ON pl.organization_id = o.id;
```

**Endpoint после изменения:**
```
GET /pg/org_settings?organization_id=eq.<id>
Authorization: Bearer <token>

→ [{
    "organization_id": "uuid",
    "lock_date": "2024-01-01" | null,
    "current_period": "2024-01-01" | null,
    "enabled_meter_types": ["water","electricity","gas"]
}]
```

### 3. RPC `api.set_meter_types(p_org_id UUID, p_types TEXT[])`

**Валидация:**
- Только допустимые типы: `water`, `electricity`, `gas` (из `api.enum_meter_types`)
- Минимум 1 тип
- Пустой массив и NULL — ошибка

**Логика:**
```sql
INSERT INTO private.org_settings_history (organization_id, effective_from, setting_name, setting_value)
VALUES (p_org_id, CURRENT_DATE, 'enabled_meter_types', to_jsonb(p_types))
ON CONFLICT (organization_id, effective_from, setting_name) DO UPDATE
    SET setting_value = EXCLUDED.setting_value,
        created_at    = now();
```

**Возврат:** `{"ok": true}` или `{"ok": false, "error": "..."}`.

**Паттерн — точно как `set_lock_date`:**
- `IF private.current_org_id() IS NOT NULL AND p_org_id <> private.current_org_id()` → `RAISE EXCEPTION 'ORG_MISMATCH'`
- `SECURITY DEFINER`
- `GRANT EXECUTE ON FUNCTION ... TO authenticated`

**Пример вызова:**
```
POST /pg/rpc/set_meter_types
Authorization: Bearer <token>
Content-Type: application/json

{"p_org_id": "uuid", "p_types": ["water", "gas"]}

→ {"ok": true}
```

---

## Что НЕ входит в эту задачу

- Переносить `current_period` / `lock_date` в `org_settings_history`
- Исторический endpoint «настройки на произвольную дату»
- Seed дефолтных значений при создании организации (дефолт через COALESCE в view)
- Миграция существующих данных (история пуста, view даёт дефолт автоматически)

---

## Затрагиваемые файлы

| Файл | Действие |
|------|---------|
| `sql/015_org_settings_history.sql` | Создать — таблица + view + RPC |
| `API_CONTRACT.md` | Обновить — новая колонка в org_settings, новый endpoint set_meter_types |

---

## Связанные объекты

- `private.organizations` — FK для `org_settings_history.organization_id`
- `api.enum_meter_types` — для валидации допустимых типов
- `api.org_settings` — view, которую обновляем
- `api.set_lock_date` — образец паттерна для `set_meter_types`
