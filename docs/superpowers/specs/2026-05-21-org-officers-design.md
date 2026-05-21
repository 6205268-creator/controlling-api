# Спека: Migration 023 — Org Officers (Должностные лица организации)

**Дата:** 2026-05-21  
**Статус:** Approved, ready for implementation

---

## Цель

Хранить историю должностных лиц организации (председатель, казначей, ревизионная комиссия) с привязкой к дате назначения. Использовать в отчётах и документах для определения кто занимал должность на заданную дату.

---

## Бизнес-контекст

Система обслуживает ГСК, СНТ и аналогичные кооперативные организации. У каждой организации есть:
- **Председатель** (`chairman`) — единственный, может быть наёмным лицом (не обязательно член)
- **Казначей** (`treasurer`) — единственный, аналогично
- **Ревизионная комиссия** (`audit_member`) — несколько человек, всегда назначаются одновременно одной операцией с одной датой

Должностные лица используются в отчётах (подписи, реквизиты) и потенциально в документах.

---

## Ключевые решения

### Только `effective_from`, без `effective_to`

**Почему:** `effective_to` создаёт проблему — при смене лица нужно вручную закрыть старую запись. Возможна ошибка: два активных председателя одновременно (две записи с `effective_to = NULL`).

**Как работает:** текущий председатель — запись с максимальным `effective_from <= запрашиваемая_дата`. Предыдущий председатель вычисляется из истории автоматически — следующая запись по хронологии закрывает предыдущую.

### Групповое назначение ревкомиссии

Все члены ревкомиссии всегда назначаются одновременно с одной датой. Смена комиссии — новая пачка записей с новым `effective_from`. Запрос состава на дату: все записи `audit_member` с максимальным `effective_from <= дата`.

---

## Таблица `private.org_officers`

```sql
CREATE TABLE private.org_officers (
    organization_id UUID    NOT NULL REFERENCES private.organizations(id),
    contractor_id   UUID    NOT NULL REFERENCES private.contractors(id),
    officer_type    TEXT    NOT NULL CHECK (officer_type IN ('chairman', 'treasurer', 'audit_member')),
    effective_from  DATE    NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, officer_type, contractor_id, effective_from)
);
```

**PK-смысл:** один человек не может быть назначен на одну роль в одной организации дважды в один день. Множество audit_member с одной датой — нормально (это и есть пачка).

---

## RPC `api.set_org_officer`

```
POST /pg/rpc/set_org_officer
```

**Параметры:**
- `p_org_id UUID`
- `p_officer_type TEXT` — `chairman` / `treasurer` / `audit_member`
- `p_contractor_ids UUID[]` — массив (для chairman/treasurer — один элемент)
- `p_effective_from DATE`

**Логика (MVP — без валидации):**
1. ORG_MISMATCH — проверить `p_org_id` через `private.current_org_id()`
2. Вставить все записи из `p_contractor_ids` с `(p_org_id, p_officer_type, contractor_id, p_effective_from)`
3. `ON CONFLICT DO NOTHING` — повторная вставка той же пачки безопасна
4. Вернуть `{"ok": true}`

**Ошибки:**
- `ORG_MISMATCH` — чужая организация
- `EMPTY_CONTRACTORS` — передан пустой массив

> **TODO (не MVP):** Валидация перед назначением. Правила зависят от `officer_type`:
> - `audit_member`: каждый `contractor_id` должен иметь активную запись в `private.members` данной организации (`is_active = true`). Проверка: `EXISTS (SELECT 1 FROM private.members WHERE organization_id = p_org_id AND contractor_id = c_id AND is_active = true)`. Код ошибки: `NOT_A_MEMBER: <contractor_id>`.
> - `chairman`, `treasurer`: ограничений нет — может быть наёмное лицо.

---

## View `api.org_officers`

Текущий состав на сегодня — для отображения в UI.

```sql
CREATE VIEW api.org_officers AS
-- председатель (последнее назначение)
SELECT o.id AS organization_id, oo.officer_type, oo.contractor_id, oo.effective_from
FROM private.organizations o
LEFT JOIN LATERAL (
    SELECT officer_type, contractor_id, effective_from
    FROM private.org_officers
    WHERE organization_id = o.id AND officer_type = 'chairman'
      AND effective_from <= CURRENT_DATE
    ORDER BY effective_from DESC LIMIT 1
) oo ON true

UNION ALL

-- казначей (последнее назначение)
SELECT o.id, oo.officer_type, oo.contractor_id, oo.effective_from
FROM private.organizations o
LEFT JOIN LATERAL (
    SELECT officer_type, contractor_id, effective_from
    FROM private.org_officers
    WHERE organization_id = o.id AND officer_type = 'treasurer'
      AND effective_from <= CURRENT_DATE
    ORDER BY effective_from DESC LIMIT 1
) oo ON true

UNION ALL

-- ревкомиссия (последняя пачка)
SELECT o.id, oo.officer_type, oo.contractor_id, oo.effective_from
FROM private.organizations o
LEFT JOIN LATERAL (
    SELECT officer_type, contractor_id, effective_from
    FROM private.org_officers
    WHERE organization_id = o.id AND officer_type = 'audit_member'
      AND effective_from = (
          SELECT MAX(effective_from) FROM private.org_officers
          WHERE organization_id = o.id AND officer_type = 'audit_member'
            AND effective_from <= CURRENT_DATE
      )
) oo ON true;
```

---

## RPC `api.get_officers_at`

Состав на произвольную дату — для отчётов и документов.

```
POST /pg/rpc/get_officers_at
```

**Параметры:**
- `p_org_id UUID`
- `p_date DATE`

**Возвращает:** таблицу `(officer_type, contractor_id, effective_from)` — та же логика что и view, но на `p_date`.

---

## Известные проблемы (не в scope 023)

**Мягкое удаление члена при отмене проведения документа владения.**  
`private.members.source_doc_id` имеет `ON DELETE SET NULL` — при удалении doc_ownership ссылка обнуляется, но запись члена остаётся активной. Если должностное лицо было назначено и затем его владение отменили — оно формально остаётся в таблице members как активный член. Требует отдельного решения.

---

## Карта файлов

| Файл | Действие |
|------|---------|
| `sql/023_org_officers.sql` | Создать |
| `migrations/versions/<id>_023_org_officers.py` | Создать |
| `API_CONTRACT.md` | Обновить — добавить секцию `## Должностные лица` |
