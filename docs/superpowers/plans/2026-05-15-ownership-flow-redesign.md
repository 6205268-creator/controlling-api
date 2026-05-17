# Ownership Flow Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Привести документы владения к единому журналу `documents`, ввести дату актуальности по организации, каскадную отмену проведения по `posted_at`, убрать зависимость отображения владельца участка от `financial_object_registry`, обновить seed и контракт API.

**Architecture:** Расширяем `private.documents` типом `'ownership'`, связываем `doc_ownership.document_id → documents.id`. Проведение/отмена обновляют шапку журнала и `organizations.actuality_moment`. Текущий владелец участка берётся из последнего проведённого `doc_ownership` по участку. Отдельная миграция SQL (не перезаписывать существующий `011_crud_rpc.sql`).

**Tech Stack:** PostgreSQL 16, PostgREST, существующие RPC-паттерны (`SECURITY DEFINER`, RLS, JSONB `{ok, error}`).

---

## Важные соглашения перед стартом

1. **Номер миграции:** В спеке указано «011», но в репозитории уже есть `sql/011_crud_rpc.sql`. Вся новая логика из спеки — файл **`sql/012_ownership_journal_actuality.sql`** (имя можно уточнить, но номер **012** обязателен). Опционально обновить строку в `docs/superpowers/specs/2026-05-15-ownership-flow-redesign.md`: «011» → «012».
2. **Docker `init.sh`:** Сейчас применяются только `001`–`007`. Для чистого контейнера добавить по порядку применение **`008`–`012`** (иначе свежий деплой расходится с боем). Путь: `docker/postgres/init.sh`.
3. **Риск по каскаду (все типы документов):** Спека требует переводить в `draft` **все** `documents` организации с `posted_at >= отменяемого`. Для платежей/начислений уже существуют движения в регистрах. Пока автоматического сторно движений в плане нет (вне спеки) — после каскада данные могут быть **временно неконсистентны**, пока пользователь не перепроведёт документы. Зафиксировать это в релизных заметках / `API_CONTRACT.md`.
4. **Проверки «тестами»:** Отдельного pytest в бэкенде нет. Шаги верификации — **`psql`** с ожидаемыми строками (можно позже вынести в `scripts/verify-ownership-flow.sh`).

---

## Файловая карта

| Файл | Роль |
|------|------|
| `docs/superpowers/specs/2026-05-15-ownership-flow-redesign.md` | Источник требований (уже есть) |
| `sql/001_schema.sql` | Базовый CHECK `doc_type` — для **новых** установок; правка на `'ownership'` (или только в 012 через `ALTER`) |
| `sql/010_ownership_flow.sql` | Текущее состояние `doc_ownership`, `post_ownership` пишет в `financial_object_registry` — поведение заменяется в 012 |
| `sql/011_crud_rpc.sql` | CRUD RPC — **не трогать** номером |
| `sql/012_ownership_journal_actuality.sql` | **Создать:** колонки, RPC, view |
| `sql/007_plot_ownerships_admin_seed.sql` | Переписать seed: 5 участков, 5 физлиц, 2 юрлица на организацию; без документов владения; не полагаться на удалённые в 010 таблицы |
| `docker/postgres/init.sh` | Добавить 008–012 |
| `API_CONTRACT.md` | Описать `ownership`, `actuality_moment`, `unpost_ownership`, изменения `plot_summary` |

---

### Task 1: Синхронизация спеки и нумерации

**Files:**
- Modify: `docs/superpowers/specs/2026-05-15-ownership-flow-redesign.md` (переименовать раздел «Миграция 011» → «Миграция 012», поправить упоминание `init.sh`)

- [ ] **Step 1:** В спеке заменить все вхождения миграции **011** на **012** для блока ownership (CRUD остаётся 011).
- [ ] **Step 2:** В разделе `init.sh` указать полный список: после 007 — **008, 009, 010, 011, 012** (проверить, что файлы `008`–`010` существуют в `sql/`).

```bash
ls -1 /home/roman/controlling-backend/sql/0*.sql
```

- [ ] **Step 3:** Коммит только документации (если политика репозитория позволяет; иначе объединить с Task 2).

```bash
cd /home/roman/controlling-backend && git add docs/superpowers/specs/2026-05-15-ownership-flow-redesign.md && git commit -m "docs: align ownership redesign spec with migration 012"
```

---

### Task 2: Черновик `sql/012_ownership_journal_actuality.sql` — схема

**Files:**
- Create: `sql/012_ownership_journal_actuality.sql`

- [ ] **Step 1:** Добавить в `private.organizations`:

```sql
ALTER TABLE private.organizations
  ADD COLUMN IF NOT EXISTS actuality_moment TIMESTAMPTZ;
COMMENT ON COLUMN private.organizations.actuality_moment IS 'Оперативная актуальность проведения по организации';
```

- [ ] **Step 2:** Расширить CHECK на `private.documents.doc_type` значением `'ownership'`  
  (через `ALTER TABLE ... DROP CONSTRAINT ... ADD CONSTRAINT`, имя constraint найти: `\d private.documents` в psql).

- [ ] **Step 3:** В `private.doc_ownership` добавить:

```sql
ALTER TABLE private.doc_ownership
  ADD COLUMN IF NOT EXISTS document_id UUID REFERENCES private.documents(id),
  ADD COLUMN IF NOT EXISTS shares INTEGER NOT NULL DEFAULT 1 CHECK (shares > 0);
```

- [ ] **Step 4:** Уникальность по спеке: `(organization_id, object_id, contractor_id, doc_date)` — добавить **уникальный индекс** (или `CONSTRAINT`), учитывая, что в одной строке сейчас один `contractor`; при появлении нескольких строк на один документ модель может потребовать уточнения (строки табличной части) — для текущей формы «одна строка doc_ownership на черновик» оставить как в спеке и отметить комментарием.

- [ ] **Step 5:** RLS: если появятся новые политики на `documents`, убедиться, что `SECURITY DEFINER` функции сохраняют проверку `organization_id` из JWT/`current_org_id()` (как в `006_auth_and_rls.sql`).

---

### Task 3: `api.create_ownership` — создание шапки журнала

**Files:**
- Modify: `sql/012_ownership_journal_actuality.sql` (переопределить функцию)

- [ ] **Step 1:** В одной транзакции INSERT в `private.documents` (`doc_type = 'ownership'`, `status = 'draft'`, `doc_date = p_doc_date`, `organization_id`) → получить `document_id`.
- [ ] **Step 2:** INSERT в `private.doc_ownership` с заполнением `document_id`, остальные параметры как сейчас в `010`.
- [ ] **Step 3:** Возвращать JSONB: `ok`, `doc_id` (ownership id), `document_id` (журнал), `status`.

**Проверка (падающий сценарий до фикса не нужен — ручной):**

```bash
sudo -u postgres psql -d controlling -c "SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='api' AND proname='create_ownership';"
```

---

### Task 4: `api.post_ownership` — без `financial_object_registry` для участка

**Files:**
- Modify: `sql/012_ownership_journal_actuality.sql`

- [ ] **Step 1:** Загрузить `doc_ownership` по `p_doc_id`, взять связанный `document_id` (если NULL — миграционный путь: запретить пост или одноразово создать документ; для новых данных только NOT NULL после backfill).
- [ ] **Step 2:** Заблокировать строку `doc_ownership` `FOR UPDATE`; проверить статусы и период (`period_locks` / закрытие периода — переиспользовать существующую логику других `post_*`, если есть).
- [ ] **Step 3:** Удалить блок `UPDATE/INSERT` в `financial_object_registry` для сценария владения участком (`object_type = 'plot'`).  
  Опционально одноразово: `DELETE FROM private.financial_object_registry WHERE object_type = 'plot'` после бэкапа — **только** если нет других потребителей этого регистра для участков (проверить кодовую базу grep по `financial_object_registry` и `'plot'`).
- [ ] **Step 4:** Обновить `private.documents`: `status = 'posted'`, `posted_at = clock_timestamp()` (или `NOW()`), согласованно с остальными RPC.
- [ ] **Step 5:** Обновить `doc_ownership.status = 'posted'`.
- [ ] **Step 6:** Обновить `organizations.actuality_moment = GREATEST(COALESCE(actuality_moment, '-infinity'::timestamptz), NEW.posted_at)` для соответствующей организации.

---

### Task 5: `api.unpost_ownership` и каскад

**Files:**
- Modify: `sql/012_ownership_journal_actuality.sql`

- [ ] **Step 1:** По `p_doc_id` (id из `doc_ownership` **или** UUID документа журнала — **выбрать одно** и зафиксировать в контракте; рекомендация: параметр = `document_id` журнала для единообразия с другими отменами, либо переименовать RPC в `unpost_document`) найти организацию и `posted_at` целевого проведённого документа.
- [ ] **Step 2:** Если `doc_date` в закрытом периоде — `RAISE` / JSON `{ok:false}`.
- [ ] **Step 3:** `UPDATE private.documents SET status = 'draft', posted_at = NULL WHERE organization_id = org AND posted_at >= target_posted_at` (и `status` был `posted`; уточнить взаимодействие с `cancelled`).
- [ ] **Step 4:** Для всех затронутых ownership: `UPDATE private.doc_ownership SET status = 'draft'` где `document_id` в множестве затронутых документов **или** связать по `posted_at` через join — предпочтительно по `document_id`.
- [ ] **Step 5:** `UPDATE private.organizations SET actuality_moment = target_posted_at - interval '1 millisecond'` где `id = org`.
- [ ] **Step 6:** `GRANT EXECUTE ... TO authenticated`.

**Проверка:**

```sql
-- после сценария: нет documents со status posted у org с posted_at > unposted boundary
-- actuality_moment уменьшилась
```

---

### Task 6: `api.plot_summary` — владелец из `doc_ownership`

**Files:**
- Modify: `sql/012_ownership_journal_actuality.sql`

- [ ] **Step 1:** Пересоздать `VIEW api.plot_summary` без join к `financial_object_registry` для участка.  
  Логика: для каждого `plot` найти «последний» проведённый `doc_ownership` с `object_type` приводимым к участку и взять `contractor_id`.  
  Если в одной дате несколько совладельцев в **будущем** — view должен поддерживать несколько строк на участок или агрегировать; на текущей модели «одна строка на документ» достаточно одного владельца до появления табличной части.

---

### Task 7: Обновить seed `007`

**Files:**
- Modify: `sql/007_plot_ownerships_admin_seed.sql`

- [ ] **Step 1:** Удалить создание `plot_ownerships` / view `api.plot_ownerships` из **этого** файла **или** вынести устаревшее в отдельный архивный файл, чтобы `010` не противоречил порядку применения на чистой БД.  
  Целевое состояние: после полной цепочки `001`–`010` seed не ломает `DROP plot_ownerships` из 010.  
  Практический вариант: seed только вставляет организации, пользователей, контрагентов, участки (5+5+2 на орг), без `plot_ownerships`.
- [ ] **Step 2:** Не выставлять `plots.owner_id` (оставить NULL).
- [ ] **Step 3:** Прогнать на пустой БД в Docker (см. Task 9).

---

### Task 8: `API_CONTRACT.md`

**Files:**
- Modify: `API_CONTRACT.md`

- [ ] **Step 1:** Описать тип документа `ownership`, поля `document_id` в ответах создания.
- [ ] **Step 2:** Задокументировать `POST /pg/rpc/unpost_ownership` (или финальное имя), тело, ошибки, эффект каскада и `actuality_moment`.
- [ ] **Step 3:** Упомянуть уже существующие `update_plot`, `create_meter`, `update_meter`, `update_contractor` из `011` (если ещё не описаны).

---

### Task 9: `docker/postgres/init.sh` и полный прогон

**Files:**
- Modify: `docker/postgres/init.sh`

- [ ] **Step 1:** После строки с `007_plot_ownerships_admin_seed.sql` добавить по аналогии вызовы **008, 009, 010, 011, 012** (пути `/docker-entrypoint-initdb.d/sql/...`).

- [ ] **Step 2:** Сборка и подъём (пример):

```bash
cd /home/roman/controlling-backend && docker compose down -v && docker compose up -d --build
sleep 5
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\df api.unpost_ownership"
docker compose exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT COUNT(*) FROM private.plots;"
```

Ожидается: функция существует после 012; участки наполнены согласно seed.

---

### Task 10: Продуктовая верификация перед «готово»

**Files:**
- None (ручной чеклист)

- [ ] **Step 1:** Под демо-пользователем: `create_ownership` → `post_ownership` → проверка `GET plot_summary` — владелец отображается.
- [ ] **Step 2:** Второй документ на тот же участок позже — смена владельца.
- [ ] **Step 3:** `unpost_ownership` первого — владелец откатился, все документы после в `draft` (по спеке).
- [ ] **Step 4:** Убедиться под другой организацией данные не затронуты (две демо-организации в seed).

Использовать **verification-before-completion**: не заявлять о готовности без вывода команд из Task 9–10.

---

## Self-review (покрытие спеки)

| Требование спеки | Task |
|-------------------|------|
| `actuality_moment` | Task 2, 4, 5 |
| `'ownership'` в журнале | Task 2, 3 |
| `doc_ownership.document_id`, `shares` | Task 2, 3 |
| Убрать реестр для владения, переписать `plot_summary` | Task 4, 6 |
| `unpost` + каскад по `documents` | Task 5 |
| Изоляция org (RLS + фильтры) | Task 3–5 (явные WHERE по org из документа) |
| Seed 5/5/2, без документов владения | Task 7 |
| init.sh порядок миграций | Task 1, 9 |
| Вне объёма: автоперепроведение | Не в плане |
| Вне объёма: совладельцы в одном документе | Механизм `shares`; UI/несколько строк — позже |

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-15-ownership-flow-redesign.md`.

**Two execution options:**

**1. Subagent-Driven (recommended)** — отдельный агент на задачу, ревью между задачами.

**2. Inline Execution** — выполнять чекбоксы подряд в этой сессии с чекпоинтами после Task 4 и Task 6.

**Which approach do you want?**
