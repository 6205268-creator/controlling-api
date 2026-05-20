# Брейнсторм: реестр настроек организации (migration 022)

**Дата:** 2026-05-20  
**Статус:** ЗАВЕРШЁН — готово к написанию спеки и плана  
**Следующий шаг:** invokewriting-plans для migration 022

---

## Контекст

Уже есть (migration 015):
- `private.org_settings_history` — EAV: `(organization_id, effective_from DATE, setting_name TEXT, setting_value JSONB)`
- `api.org_settings` — view, агрегирует текущие настройки
- `api.set_meter_types` — единственный RPC для записи настроек

Проблема: нет реестра — не известно какие `setting_name` допустимы, какой тип, какие значения.

---

## Все решённые вопросы

### ✅ Q1: нужна ли история?
**ДА.** Периодичность = 1 день (`effective_from = DATE`).

### ✅ Q2: формат ответа `api.org_settings`?
**Одним запросом — все настройки** как массив объектов, каждый с текущим значением + метаданными из реестра. Фронт читает один раз, рендерит динамически по `value_type`.

```json
GET /org_settings?organization_id=eq.<uuid>
[
  {
    "setting_name":   "use_meters",
    "value_type":     "boolean",
    "description":    "Использовать счётчики",
    "allowed_values": null,
    "default_value":  false,
    "current_value":  false
  },
  {
    "setting_name":   "enabled_meter_types",
    "value_type":     "enum[]",
    "description":    "Виды счётчиков",
    "allowed_values": ["water","electricity","gas"],
    "default_value":  [],
    "current_value":  ["water"]
  }
]
```

### ✅ Q3: начальные настройки в реестре
Только скалярные — без ссылок на контрагентов (те идут в migration 023):

| setting_name | value_type | default_value | allowed_values | description |
|---|---|---|---|---|
| `use_meters` | boolean | false | null | Использовать счётчики |
| `enabled_meter_types` | enum[] | [] | ["water","electricity","gas"] | Виды счётчиков |
| `legal_address` | text | null | null | Юридический адрес |
| `postal_address` | text | null | null | Почтовый адрес |

### ✅ Q4: председатель, казначей, ревкомиссия → НЕ в реестр
Это ссылки на контрагентов — требуют FK + историчность. Идут в **migration 023** как отдельная таблица `private.org_officers`.

### ✅ Q5: валидация use_meters + enabled_meter_types
Бэкенд. В RPC `set_org_setting`: если `use_meters = true` и `enabled_meter_types` в истории пустой → ошибка `METER_TYPES_REQUIRED`. Фронт тоже может проверять, но бэкенд страхует.

---

## Архитектура migration 022

### 1. Новая таблица `private.org_setting_definitions`

```sql
CREATE TABLE private.org_setting_definitions (
    setting_name    TEXT PRIMARY KEY,
    value_type      TEXT    NOT NULL, -- 'boolean','integer','text','enum','enum[]'
    allowed_values  JSONB,            -- для enum/enum[]: ["water","electricity","gas"]
    default_value   JSONB   NOT NULL,
    description     TEXT    NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT true
);
```

### 2. Добавить FK в `org_settings_history`

```sql
ALTER TABLE private.org_settings_history
  ADD CONSTRAINT fk_setting_name
  FOREIGN KEY (setting_name)
  REFERENCES private.org_setting_definitions(setting_name);
```

### 3. Seed реестра
INSERT 4 строки (use_meters, enabled_meter_types, legal_address, postal_address).

### 4. Пересоздать `api.org_settings` view
JOIN `org_setting_definitions` (все активные) × `organizations` + LEFT JOIN `org_settings_history` (актуальное значение). Возвращает одну строку на (org, setting) с `current_value` или `default_value` если не установлено.

### 5. Новый RPC `api.set_org_setting(p_org_id, p_setting_name, p_value JSONB)`
Логика:
1. Найти в реестре → ошибка `UNKNOWN_SETTING` если нет / is_active=false
2. Провалидировать p_value под value_type и allowed_values
3. Кросс-валидация: `use_meters=true` → проверить что `enabled_meter_types` не пустой
4. UPSERT в `org_settings_history` (org_id, CURRENT_DATE, setting_name)

### 6. `set_meter_types` → заменить на wrapper или удалить
Заменить реализацию: внутри вызывать `set_org_setting`.

---

## Migration 023 (следующая): `org_officers`

```sql
private.org_officers (
  organization_id  UUID FK → organizations
  contractor_id    UUID FK → contractors   -- нельзя удалить контрагента пока есть строка
  officer_type     TEXT   -- 'chairman', 'treasurer', 'audit_member'
  effective_from   DATE
  effective_to     DATE   -- NULL = актуально сейчас
  PRIMARY KEY (organization_id, contractor_id, officer_type, effective_from)
)
```

Исторический запрос: `WHERE effective_from <= doc_date AND (effective_to IS NULL OR effective_to >= doc_date)`.
Контрагент не удаляется → `is_active = false` (soft delete).

---

## Новые коды ошибок

| Код | Когда |
|-----|-------|
| `UNKNOWN_SETTING` | setting_name не найден в реестре или is_active=false |
| `INVALID_SETTING_VALUE` | значение не соответствует value_type |
| `INVALID_ENUM_VALUE` | значение не входит в allowed_values |
| `METER_TYPES_REQUIRED` | use_meters=true, но enabled_meter_types пустой |
