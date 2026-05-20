# Дизайн: Долевое владение участком

**Дата:** 2026-05-20  
**Статус:** Approved  
**Миграция:** 021

---

## Цель

Добавить поддержку нескольких владельцев с долями на один документ владения. Один документ = один участок + N владельцев, у каждого — целое число долей.

**Пример:** Иванов (1 доля) + Петров (2 доли) = участок поделён на 3 части.

---

## Архитектурный подход

Схема уже поддерживает несколько строк `doc_ownership` на один `documents.id` и поле `shares`. Реализуем **Document-first** модель (Вариант B): шапка создаётся отдельно, строки владельцев управляются отдельными RPC. `post_ownership` / `unpost_ownership` переводятся на `documents.id` как первичный ключ операции.

Фронтенд новый → обратная совместимость не требуется → сигнатуры всех затронутых RPC переписываются чисто.

---

## Стек

- PostgreSQL 16 + PostgREST 14
- Alembic (миграции)
- Схема `private` (данные) + `api` (PostgREST-exposed)

---

## Карта изменений

| Файл | Тип | Что меняется |
|------|-----|-------------|
| `sql/021_ownership_shares.sql` | новый | вся миграция |
| `migrations/versions/<hash>_021.py` | новый | Alembic revision |
| `API_CONTRACT.md` | обновить | ownership секция |
| `BACKEND_MASTER.md` | обновить | список миграций |

---

## Схема данных

### Существующая структура (без изменений)

```
private.documents       — шапка (id, doc_type='ownership', doc_date, status, posted_at)
private.doc_ownership   — строки (id, document_id FK, contractor_id, shares INTEGER > 0, status)
```

Один документ → несколько строк `doc_ownership` (по одной на каждого владельца).

### Единственное изменение схемы

```sql
-- FK members.source_doc_id: NO ACTION → ON DELETE SET NULL
-- Позволяет удалять строки doc_ownership из черновика
ALTER TABLE private.members
  DROP CONSTRAINT members_source_doc_id_fkey,
  ADD CONSTRAINT members_source_doc_id_fkey
    FOREIGN KEY (source_doc_id)
    REFERENCES private.doc_ownership(id)
    ON DELETE SET NULL;
```

Уникальный индекс `(organization_id, object_id, contractor_id, doc_date)` — **остаётся**. Один контрагент не может фигурировать дважды в одном документе на ту же дату.

### Пример данных

```
documents:     id=D1, doc_type='ownership', doc_date=2026-01-01, status='draft'
doc_ownership: id=O1, document_id=D1, contractor_id=Ivanov, shares=1
doc_ownership: id=O2, document_id=D1, contractor_id=Petrov, shares=2
-- итого 3 доли; Иванов владеет 1/3, Петров 2/3
```

---

## RPC API

### Новые функции

#### `add_ownership_owner(p_document_id, p_contractor_id, p_shares DEFAULT 1)`
Добавляет строку владельца в черновик документа.

**Валидация:**
- Документ существует, `status = 'draft'`, принадлежит организации из JWT
- `p_shares > 0` → иначе `INVALID_SHARES`
- Контрагент не присутствует в документе → иначе `CONTRACTOR_ALREADY_OWNER`

**Response:** `{"ok": true, "own_id": "uuid"}`

---

#### `remove_ownership_owner(p_own_id)`
Удаляет строку владельца из черновика.

**Валидация:**
- Строка существует, `status = 'draft'`, принадлежит организации из JWT
- `members.source_doc_id` → обнуляется автоматически через `ON DELETE SET NULL`
- Разрешено оставить 0 строк в черновике (пост с 0 строками блокируется позже)

**Response:** `{"ok": true}`

---

#### `update_ownership_owner(p_own_id, p_contractor_id, p_shares)`
Обновляет контрагента и/или доли одной строки черновика.

**Валидация:** строка существует, `status = 'draft'`, `p_shares > 0`, новый `p_contractor_id` не присутствует в других строках того же документа → иначе `CONTRACTOR_ALREADY_OWNER`

**Response:** `{"ok": true, "own_id": "uuid"}`

---

### Изменённые функции

#### `create_ownership(p_org_id, p_object_id, p_object_type DEFAULT 'plot', p_doc_date DEFAULT CURRENT_DATE, p_notes DEFAULT NULL, p_created_by DEFAULT NULL)`

Создаёт только **шапку** документа (строк владельцев нет).  
**Убрано:** `p_contractor_id` (больше не принимается).

**Response:** `{"ok": true, "document_id": "uuid", "status": "draft"}`

---

#### `update_ownership(p_document_id, p_doc_date DEFAULT NULL, p_notes DEFAULT NULL, p_object_id DEFAULT NULL, p_object_type DEFAULT NULL)`

Обновляет только поля **шапки** документа. Принимает `documents.id`.  
Если передан `p_doc_date` — синхронизирует `doc_date` во всех связанных строках `doc_ownership`.  
**Убрано:** `p_own_id`, `p_contractor_id` (строки управляются отдельными RPC).

**Response:** `{"ok": true, "document_id": "uuid", "status": "draft"}`

---

#### `post_ownership(p_document_id)` — принимает `documents.id`

**Было:** принимал `doc_ownership.id`, проводил одну строку.  
**Стало:** принимает `documents.id`, проводит **все** строки документа.

**Валидация:**
- Документ существует, `status = 'draft'`
- Хотя бы одна строка `doc_ownership` → иначе `OWNERSHIP_EMPTY`
- Период не закрыт

**Действия:**
1. `documents.status = 'posted'`, `posted_at = clock_timestamp()`
2. Все `doc_ownership` строки → `status = 'posted'`
3. Для каждого `contractor_type = 'individual'` без членства → создать запись в `members`
4. Обновить `organizations.actuality_moment`

**Response:**
```json
{
  "ok": true,
  "document_id": "uuid",
  "object_type": "plot",
  "object_id": "uuid",
  "owners_posted": 2
}
```

---

#### `unpost_ownership(p_document_id)` — принимает `documents.id`

**Было:** принимал `doc_ownership.id`.  
**Стало:** принимает `documents.id`.

Логика каскада остаётся без изменений: все документы организации с `posted_at >= posted_at` целевого → в `draft`; связанные строки `doc_ownership` → в `draft`; `actuality_moment` откатывается.

**Response:**
```json
{
  "ok": true,
  "document_id": "uuid",
  "boundary_posted_at": "...",
  "cascade_documents": 3,
  "doc_ownership_rows_reset": 4
}
```

---

### Без изменений

- `delete_draft` — удаляет документ (каскадно удаляет строки `doc_ownership` через FK)
- `GET /doc_ownership?document_id=eq.<uuid>` — возвращает все строки; поле `shares` уже есть

---

## Views

### `doc_journal` — исправить дублирование

**Проблема:** LEFT JOIN на `doc_ownership` дублирует строку журнала если владельцев > 1.

**Решение:**
- Убрать `own_id` (больше не нужен: post/unpost принимают `documents.id = d.id`)
- `contractor_name` для ownership → агрегировать через LATERAL subquery: `"Иванов Иван, Петров Пётр"`

```sql
LEFT JOIN LATERAL (
    SELECT STRING_AGG(c.full_name, ', ' ORDER BY deo.created_at) AS contractor_name
    FROM private.doc_ownership deo
    JOIN private.contractors c ON c.id = deo.contractor_id
    WHERE deo.document_id = d.id
) own_agg ON d.doc_type = 'ownership'
```

### `plot_summary` — без изменений

Уже агрегирует нескольких владельцев: `owner_id = NULL` при нескольких, `owner_name` = конкатенация ФИО.

### `current_ownership` — без изменений

При нескольких владельцах возвращает несколько строк — фронт это поддерживает.

---

## Коды ошибок (новые)

| Код | Когда |
|-----|-------|
| `OWNERSHIP_EMPTY` | `post_ownership` — документ без строк владельцев |
| `INVALID_SHARES` | `add/update_ownership_owner` — `shares <= 0` |
| `CONTRACTOR_ALREADY_OWNER` | `add_ownership_owner` — контрагент уже есть в документе |
| `NOT_DRAFT` | `add/remove/update_ownership_owner` — документ не черновик |

---

## Типичный сценарий

```
1. POST /rpc/create_ownership       {p_org_id, p_object_id, p_doc_date}
   → {"ok": true, "document_id": "D1"}

2. POST /rpc/add_ownership_owner    {p_document_id: "D1", p_contractor_id: "Ivanov", p_shares: 1}
   → {"ok": true, "own_id": "O1"}

3. POST /rpc/add_ownership_owner    {p_document_id: "D1", p_contractor_id: "Petrov", p_shares: 2}
   → {"ok": true, "own_id": "O2"}

4. GET  /doc_ownership?document_id=eq.D1
   → [{contractor_name: "Иванов", shares: 1}, {contractor_name: "Петров", shares: 2}]

5. POST /rpc/post_ownership         {p_document_id: "D1"}
   → {"ok": true, "owners_posted": 2}

6. GET  /plot_summary
   → {owner_name: "Иванов Иван, Петров Пётр", owner_id: null}
```

**Отмена:**
```
POST /rpc/unpost_ownership  {p_document_id: "D1"}
→ оба O1, O2 возвращаются в draft; каскад по времени
```

---

## Порядок реализации (migration 021)

1. FK `members.source_doc_id` → `ON DELETE SET NULL`
2. Переписать `api.create_ownership` (только шапка)
3. Переписать `api.update_ownership` (только шапка, принимает `p_document_id`)
4. Новая `api.add_ownership_owner`
5. Новая `api.remove_ownership_owner`
6. Новая `api.update_ownership_owner`
7. Переписать `api.post_ownership` (принимает `documents.id`, проводит все строки)
8. Переписать `api.unpost_ownership` (принимает `documents.id`)
9. Исправить `api.doc_journal` (убрать `own_id`, агрегировать contractor_name)
10. `NOTIFY pgrst, 'reload schema'`
