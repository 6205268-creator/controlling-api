# Context Handoff — controlling-backend

## Стек (ВАЖНО: всё нативное, не Docker)
- PostgreSQL 16: `sudo -u postgres psql -d controlling`
- PostgREST v14: systemd `postgrest-controlling.service`, конфиг `/etc/postgrest/controlling.conf`, порт 3100
- PostgREST TEST: systemd `postgrest-test.service`, конфиг `/etc/postgrest/controlling-test.conf`, порт 3101
- Nginx: `/etc/nginx/vhosts-includes/postgrest-controlling.conf` (`/pg/`) и `postgrest-test.conf` (`/pg-test/`)
- Репо: `/home/roman/controlling-backend`, remote `github`, ветка `master`

## Два контура
- Прод: `http://103.35.190.117/pg`
- Тест: `http://103.35.190.117/pg-test` (БД `controlling_test`)

## Скрипты для миграций
- `migrate-test.sh <file>` — применить на тест
- `migrate-prod.sh <file>` — снимок + применить на прод
- `test-reset.sh` — снести тест и накатить seed заново
- `test-refresh.sh` — скопировать прод в тест

## Текущие миграции
001–014 применены на оба контура. Последняя: `014_current_ownership.sql` (вьюшка `api.current_ownership`).

## Тестовые пользователи
- `demo_a_chair` / `chair123`
- `demo_a_treasury` / `treasury123`
- `superadmin` / `super123`

---

## ТЕКУЩАЯ ЗАДАЧА (в процессе — только брейнсторм, код не писан)

### Цель
Добавить в систему **исторические настройки организации** с периодическим регистром.
Первая настройка: `enabled_meter_types TEXT[]` — какие типы счётчиков использует организация.

### Принятые решения

**Архитектура: sequential EAV** (как "последовательный" паттерн из 1С-регистра сведений)

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

Почему sequential, а не параллельный (одна строка = все настройки):
- Нет пустых колонок для исторических записей
- Новая настройка = новое `setting_name`, без ALTER TABLE
- Каждая настройка меняется независимо

Запрос «настройка на дату D»:
```sql
SELECT setting_value FROM private.org_settings_history
WHERE organization_id = $1 AND setting_name = 'enabled_meter_types'
  AND effective_from <= $2
ORDER BY effective_from DESC LIMIT 1
```

### Что нужно реализовать (migration 015)

1. **Таблица** `private.org_settings_history` — sequential EAV, как выше

2. **Обновить** `api.org_settings` — добавить `enabled_meter_types` (текущее значение):
   ```
   GET /pg/org_settings?organization_id=eq.<id>
   → { organization_id, lock_date, current_period, enabled_meter_types }
   ```
   Дефолт если нет записи: `["water","electricity","gas"]`

3. **Новая RPC** `api.set_meter_types(p_org_id UUID, p_types TEXT[])`:
   - Валидация: только water/electricity/gas, минимум 1 тип
   - Вставить запись в `org_settings_history` с `effective_from = CURRENT_DATE`
   - ON CONFLICT (org, date, name) DO UPDATE
   - Возврат: `{"ok": true}` или `{"ok": false, "error": "..."}`
   - GRANT EXECUTE TO authenticated
   - Паттерн такой же как `set_lock_date` / `set_current_period`

4. **Seed**: при создании организации не нужно вставлять дефолт в `org_settings_history` — дефолт читается в view через COALESCE

### Существующий паттерн (set_lock_date — образец для set_meter_types)
```sql
CREATE OR REPLACE FUNCTION api.set_lock_date(p_org_id UUID, p_lock_date DATE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF private.current_org_id() IS NOT NULL AND p_org_id <> private.current_org_id() THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;
    -- ... логика ...
    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;
GRANT EXECUTE ON FUNCTION api.set_lock_date(UUID, DATE) TO authenticated;
```

### Существующая org_settings view (из migration 013)
```sql
CREATE OR REPLACE VIEW api.org_settings AS
SELECT
    o.id AS organization_id,
    pl.locked_until AS lock_date,
    o.current_period
FROM private.organizations o
LEFT JOIN private.period_locks pl ON pl.organization_id = o.id;
GRANT SELECT ON api.org_settings TO authenticated;
```

### enum_meter_types view (уже есть)
```sql
SELECT * FROM api.enum_meter_types;
-- water | Вода
-- electricity | Электричество  
-- gas | Газ
```

### Что НЕ нужно сейчас
- Переносить `current_period` или `lock_date` в `org_settings_history` (оставить как есть)
- Исторический запрос «настройки на произвольную дату» через API (только текущие)
- Миграция существующих данных (org_settings_history пуста, view даёт дефолт)

### Следующие шаги
1. Написать спеку: `docs/superpowers/specs/2026-05-18-org-settings-history.md`
2. Написать план: `docs/superpowers/plans/2026-05-18-org-settings-history.md`
3. Реализовать: migration 015, применить через migrate-test.sh → migrate-prod.sh
