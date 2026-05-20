# Брейнсторм: реестр настроек организации (migration 022)

**Дата:** 2026-05-20  
**Статус:** В процессе — продолжить со следующего вопроса  
**Следующий шаг:** Задать вопрос 2 (см. ниже)

---

## Контекст

Уже есть (migration 015):
- `private.org_settings_history` — EAV-таблица: `(organization_id, effective_from DATE, setting_name TEXT, setting_value JSONB)`
- `api.org_settings` — view, агрегирует текущие настройки
- `api.set_meter_types` — единственный RPC для записи настроек

Проблема: нет реестра — не известно какие `setting_name` допустимы, какой тип у каждого, какие значения разрешены.

---

## Решённые вопросы

### ✅ Вопрос 1: нужна ли история?
**Ответ: ДА.** Нужно знать что было на конкретную дату (например, 1 января). Периодичность — 1 день (effective_from = DATE).

---

## Архитектурные решения (предварительные)

### Новая таблица: `private.org_setting_definitions`
Реестр — словарь всех допустимых настроек:

```sql
CREATE TABLE private.org_setting_definitions (
    setting_name    TEXT PRIMARY KEY,
    value_type      TEXT NOT NULL,         -- 'boolean', 'integer', 'text', 'enum', 'enum[]'
    allowed_values  JSONB,                 -- для enum/enum[]: ["water","electricity","gas"], иначе NULL
    default_value   JSONB NOT NULL,        -- значение если у орга нет своей записи
    description     TEXT NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT true
);
```

### Связь с `org_settings_history`
Добавить FK: `org_settings_history.setting_name → org_setting_definitions.setting_name`
→ нельзя записать несуществующую настройку.

### Типы значений (`value_type`):
| Тип | Пример setting_value | Аналог в 1С |
|-----|---------------------|-------------|
| `boolean` | `true` | Булево |
| `integer` | `3` | Число (целое) |
| `text` | `"monthly"` | Строка |
| `enum` | `"water"` | Ссылка на перечисление |
| `enum[]` | `["water","gas"]` | Множественный выбор из перечисления |

### Начальные настройки для seed:

| setting_name | value_type | default_value | allowed_values | description |
|---|---|---|---|---|
| `use_meters` | boolean | false | null | Использовать счётчики |
| `enabled_meter_types` | enum[] | [] | ["water","electricity","gas"] | Виды счётчиков |

(остальные — по ходу разработки)

### Новый RPC: `api.set_org_setting(p_org_id, p_setting_name, p_value)`
Универсальный. Логика:
1. Найти `setting_name` в реестре → ошибка `UNKNOWN_SETTING` если нет
2. Провалидировать `p_value` под `value_type` и `allowed_values`
3. UPSERT в `org_settings_history` по `(org_id, CURRENT_DATE, setting_name)`

### Обновить `api.org_settings` view
Динамически читать все активные настройки из реестра + текущие значения из истории.
Вернуть как JSONB-объект: `{"use_meters": false, "enabled_meter_types": ["water"]}`.

### Судьба `set_meter_types`
Оставить как wrapper поверх `set_org_setting` (или удалить).

---

## Вопросы которые ещё НЕ заданы

### ❓ Вопрос 2 (следующий):
**Как `api.org_settings` должен выдавать настройки?**
- Вариант A: отдельная строка на каждую настройку (EAV-стиль): `{setting_name, setting_value}`
- Вариант B: одна строка на организацию, колонка на каждую настройку (текущий стиль) 
- Вариант C: одна строка на организацию, одна JSONB-колонка `settings: {...все настройки...}`

### ❓ Вопрос 3:
Какие ещё настройки (кроме `use_meters` и `enabled_meter_types`) нужны в seed реестра прямо сейчас?

### ❓ Вопрос 4:
`set_meter_types` — оставить как есть (backward compat) или заменить на `set_org_setting`?

---

## Следующие шаги

1. Задать вопрос 2 (формат ответа `api.org_settings`)
2. Задать вопрос 3 (начальные настройки)
3. Предложить 2-3 варианта архитектуры
4. Написать спеку
5. Создать migration 022
