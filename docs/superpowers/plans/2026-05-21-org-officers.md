# Migration 023 — Org Officers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить `private.org_officers` — периодический регистр должностных лиц организации (председатель, казначей, ревизионная комиссия) без effective_to; добавить view и два RPC для чтения.

**Architecture:** Таблица хранит назначения с датой вступления в должность. «Текущий» определяется запросом MAX(effective_from) ≤ дата. Ревкомиссия назначается пачкой (несколько контрагентов одной датой). Валидация прав назначения — не в MVP (TD-002 в TECH_DEBT.md). Alembic используется только как закладка (SELECT 1), SQL применяется вручную через psql stdin.

**Tech Stack:** PostgreSQL 16, PostgREST v14 (systemd), Alembic (bookmark only).

**Spec:** `docs/superpowers/specs/2026-05-21-org-officers-design.md`

---

## Карта файлов

| Файл | Действие | Что |
|------|---------|-----|
| `sql/023_org_officers.sql` | Создать | Полная миграция |
| `migrations/versions/<auto_id>_023_org_officers.py` | Создать | Alembic bookmark |
| `API_CONTRACT.md` | Изменить | Новая секция `## Должностные лица` |

---

## Task 1: SQL-файл миграции

**Files:**
- Create: `sql/023_org_officers.sql`

- [ ] **Step 1: Создать файл**

Создать `/home/roman/controlling-backend/sql/023_org_officers.sql` со следующим содержимым:

```sql
-- =============================================================================
-- Migration 023: org_officers
-- Adds private.org_officers — periodic register of organization officers
-- (chairman, treasurer, audit_member). No effective_to — current officer is
-- determined by MAX(effective_from) <= query_date.
-- Adds api.org_officers view (current state) and api.get_officers_at RPC.
-- MVP: no appointment validation (see TECH_DEBT.md TD-002).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Таблица private.org_officers
-- ---------------------------------------------------------------------------
CREATE TABLE private.org_officers (
    organization_id UUID        NOT NULL
                                REFERENCES private.organizations(id),
    contractor_id   UUID        NOT NULL
                                REFERENCES private.contractors(id),
    officer_type    TEXT        NOT NULL
                                CHECK (officer_type IN ('chairman','treasurer','audit_member')),
    effective_from  DATE        NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, officer_type, contractor_id, effective_from)
);

ALTER TABLE private.org_officers ENABLE ROW LEVEL SECURITY;

CREATE POLICY org_isolation ON private.org_officers
    USING (organization_id = private.current_org_id());

COMMENT ON TABLE private.org_officers IS
    'Должностные лица организации. '
    'Без effective_to: текущий = MAX(effective_from) <= запрашиваемая_дата. '
    'Ревкомиссия назначается пачкой — несколько строк с одинаковым effective_from.';

-- ---------------------------------------------------------------------------
-- 2. View api.org_officers — текущий состав на сегодня
-- Возвращает только роли, по которым есть хотя бы одно назначение.
-- ---------------------------------------------------------------------------
CREATE VIEW api.org_officers AS

-- председатель (последнее назначение)
SELECT
    o.id            AS organization_id,
    oo.officer_type,
    oo.contractor_id,
    oo.effective_from
FROM private.organizations o
JOIN LATERAL (
    SELECT officer_type, contractor_id, effective_from
    FROM   private.org_officers
    WHERE  organization_id = o.id
      AND  officer_type    = 'chairman'
      AND  effective_from <= CURRENT_DATE
    ORDER BY effective_from DESC
    LIMIT 1
) oo ON true

UNION ALL

-- казначей (последнее назначение)
SELECT
    o.id,
    oo.officer_type,
    oo.contractor_id,
    oo.effective_from
FROM private.organizations o
JOIN LATERAL (
    SELECT officer_type, contractor_id, effective_from
    FROM   private.org_officers
    WHERE  organization_id = o.id
      AND  officer_type    = 'treasurer'
      AND  effective_from <= CURRENT_DATE
    ORDER BY effective_from DESC
    LIMIT 1
) oo ON true

UNION ALL

-- ревкомиссия (последняя пачка)
SELECT
    o.id,
    oo.officer_type,
    oo.contractor_id,
    oo.effective_from
FROM private.organizations o
JOIN LATERAL (
    SELECT officer_type, contractor_id, effective_from
    FROM   private.org_officers
    WHERE  organization_id = o.id
      AND  officer_type    = 'audit_member'
      AND  effective_from  = (
              SELECT MAX(effective_from)
              FROM   private.org_officers
              WHERE  organization_id = o.id
                AND  officer_type    = 'audit_member'
                AND  effective_from <= CURRENT_DATE
           )
) oo ON true;

GRANT SELECT ON api.org_officers TO authenticated;

COMMENT ON VIEW api.org_officers IS
    'Текущий состав должностных лиц организации на CURRENT_DATE. '
    'Строки есть только для ролей с хотя бы одним назначением.';

-- ---------------------------------------------------------------------------
-- 3. RPC api.set_org_officer — назначить должностных лиц
-- MVP: без валидации прав назначения (см. TECH_DEBT.md TD-002).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_org_officer(
    p_org_id         UUID,
    p_officer_type   TEXT,
    p_contractor_ids UUID[],
    p_effective_from DATE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org UUID;
    v_id      UUID;
BEGIN
    v_ctx_org := private.current_org_id();
    IF v_ctx_org IS NOT NULL AND p_org_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;

    IF p_contractor_ids IS NULL OR array_length(p_contractor_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'EMPTY_CONTRACTORS';
    END IF;

    FOREACH v_id IN ARRAY p_contractor_ids LOOP
        INSERT INTO private.org_officers
            (organization_id, officer_type, contractor_id, effective_from)
        VALUES
            (p_org_id, p_officer_type, v_id, p_effective_from)
        ON CONFLICT DO NOTHING;
    END LOOP;

    RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_org_officer(UUID, TEXT, UUID[], DATE) TO authenticated;

COMMENT ON FUNCTION api.set_org_officer IS
    'Назначить должностных лиц. p_contractor_ids — массив (для ревкомиссии — несколько). '
    'ON CONFLICT DO NOTHING — повторный вызов с теми же данными безопасен. '
    'Валидация не реализована (MVP, см. TECH_DEBT.md TD-002).';

-- ---------------------------------------------------------------------------
-- 4. RPC api.get_officers_at — состав на произвольную дату (для отчётов)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_officers_at(
    p_org_id UUID,
    p_date   DATE
)
RETURNS TABLE (
    officer_type   TEXT,
    contractor_id  UUID,
    effective_from DATE
) LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_ctx_org UUID;
BEGIN
    v_ctx_org := private.current_org_id();
    IF v_ctx_org IS NOT NULL AND p_org_id <> v_ctx_org THEN
        RAISE EXCEPTION 'ORG_MISMATCH';
    END IF;

    RETURN QUERY

    -- председатель
    (SELECT oo.officer_type, oo.contractor_id, oo.effective_from
     FROM   private.org_officers oo
     WHERE  oo.organization_id = p_org_id
       AND  oo.officer_type    = 'chairman'
       AND  oo.effective_from <= p_date
     ORDER BY oo.effective_from DESC
     LIMIT 1)

    UNION ALL

    -- казначей
    (SELECT oo.officer_type, oo.contractor_id, oo.effective_from
     FROM   private.org_officers oo
     WHERE  oo.organization_id = p_org_id
       AND  oo.officer_type    = 'treasurer'
       AND  oo.effective_from <= p_date
     ORDER BY oo.effective_from DESC
     LIMIT 1)

    UNION ALL

    -- ревкомиссия (последняя пачка)
    SELECT oo.officer_type, oo.contractor_id, oo.effective_from
    FROM   private.org_officers oo
    WHERE  oo.organization_id = p_org_id
      AND  oo.officer_type    = 'audit_member'
      AND  oo.effective_from  = (
              SELECT MAX(oo2.effective_from)
              FROM   private.org_officers oo2
              WHERE  oo2.organization_id = p_org_id
                AND  oo2.officer_type    = 'audit_member'
                AND  oo2.effective_from <= p_date
           );

EXCEPTION WHEN OTHERS THEN
    RAISE;
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_officers_at(UUID, DATE) TO authenticated;

COMMENT ON FUNCTION api.get_officers_at IS
    'Состав должностных лиц организации на заданную дату. '
    'Используется в отчётах. Возвращает строки только для назначенных ролей.';

-- ---------------------------------------------------------------------------
-- 5. PostgREST schema reload
-- ---------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';
```

- [ ] **Step 2: Проверить что файл создан**

```bash
wc -l /home/roman/controlling-backend/sql/023_org_officers.sql
```

Ожидаемый результат: `~160 строк`.

---

## Task 2: Применить миграцию к БД

> **ВАЖНО:** Согласно правилу `sql-migration-approval.md` — сначала показать SQL пользователю, дождаться явного «применяй», затем выполнять через stdin-пайп.

- [ ] **Step 1: Показать содержимое файла пользователю**

```bash
cat /home/roman/controlling-backend/sql/023_org_officers.sql
```

**Подождать явного ответа пользователя: «применяй» или «apply».**

- [ ] **Step 2: Применить через stdin**

```bash
cat /home/roman/controlling-backend/sql/023_org_officers.sql | sudo -u postgres psql -d controlling
```

Ожидаемый результат: вывод без `ERROR`, завершается строкой `NOTIFY`.

- [ ] **Step 3: Проверить таблицу**

```bash
sudo -u postgres psql -d controlling -c "\d private.org_officers"
```

Ожидаемый вывод: таблица с колонками `organization_id, contractor_id, officer_type, effective_from, created_at`, PK на (organization_id, officer_type, contractor_id, effective_from), RLS enabled.

- [ ] **Step 4: Проверить view через psql**

```bash
sudo -u postgres psql -d controlling -c "SELECT * FROM api.org_officers LIMIT 5;"
```

Ожидаемый вывод: пустая таблица (0 строк) — назначений ещё нет. Ошибок нет.

- [ ] **Step 5: Проверить set_org_officer — назначить председателя**

```bash
ORG_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.organizations LIMIT 1;")
CTR_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.contractors WHERE organization_id = '$ORG_ID' LIMIT 1;")
echo "org=$ORG_ID  contractor=$CTR_ID"

sudo -u postgres psql -d controlling -c "
SET LOCAL request.jwt.claims = '{\"role\": \"app_admin\"}';
SELECT api.set_org_officer('$ORG_ID'::uuid, 'chairman', ARRAY['$CTR_ID'::uuid], '2024-01-01'::date);
"
```

Ожидаемый вывод: `{"ok": true}`.

- [ ] **Step 6: Проверить view после назначения**

```bash
sudo -u postgres psql -d controlling -c "
SET LOCAL request.jwt.claims = '{\"role\": \"app_admin\"}';
SELECT officer_type, contractor_id, effective_from FROM api.org_officers;
"
```

Ожидаемый вывод: 1 строка — `chairman`, contractor_id, `2024-01-01`.

- [ ] **Step 7: Проверить get_officers_at**

```bash
ORG_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.organizations LIMIT 1;")

sudo -u postgres psql -d controlling -c "
SET LOCAL request.jwt.claims = '{\"role\": \"app_admin\"}';
SELECT * FROM api.get_officers_at('$ORG_ID'::uuid, CURRENT_DATE);
"
```

Ожидаемый вывод: та же строка с chairman.

- [ ] **Step 8: Проверить назначение ревкомиссии (пачка)**

```bash
ORG_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.organizations LIMIT 1;")
CTR1=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.contractors WHERE organization_id = '$ORG_ID' LIMIT 1 OFFSET 0;")
CTR2=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.contractors WHERE organization_id = '$ORG_ID' LIMIT 1 OFFSET 1;")
echo "org=$ORG_ID  ctr1=$CTR1  ctr2=$CTR2"

sudo -u postgres psql -d controlling -c "
SET LOCAL request.jwt.claims = '{\"role\": \"app_admin\"}';
SELECT api.set_org_officer('$ORG_ID'::uuid, 'audit_member', ARRAY['$CTR1','$CTR2']::uuid[], '2024-01-01'::date);
"
```

Ожидаемый вывод: `{"ok": true}`.

- [ ] **Step 9: Проверить EMPTY_CONTRACTORS**

```bash
ORG_ID=$(sudo -u postgres psql -d controlling -tAc "SELECT id FROM private.organizations LIMIT 1;")
sudo -u postgres psql -d controlling -c "
SET LOCAL request.jwt.claims = '{\"role\": \"app_admin\"}';
SELECT api.set_org_officer('$ORG_ID'::uuid, 'chairman', NULL::uuid[], '2024-01-01'::date);
"
```

Ожидаемый вывод: `{"ok": false, "error": "EMPTY_CONTRACTORS"}`.

---

## Task 3: Alembic revision

**Files:**
- Create: `migrations/versions/<auto_id>_023_org_officers.py`

- [ ] **Step 1: Сгенерировать ревизию**

```bash
cd /home/roman/controlling-backend && .venv/bin/alembic revision -m "023_org_officers"
```

Запомнить путь к созданному файлу из строки `Generating ...`.

- [ ] **Step 2: Отредактировать ревизию**

Открыть созданный файл. Установить:
- `down_revision = 'e07acc280b6d'` (текущий head — revision 022)
- Тело функций:

```python
def upgrade() -> None:
    op.execute("SELECT 1")  # applied manually via sql/023_org_officers.sql


def downgrade() -> None:
    pass
```

- [ ] **Step 3: Применить ревизию**

```bash
cd /home/roman/controlling-backend && .venv/bin/alembic upgrade head
```

Ожидаемый вывод: `Running upgrade e07acc280b6d -> <new_id>, 023_org_officers`.

- [ ] **Step 4: Проверить head**

```bash
cd /home/roman/controlling-backend && .venv/bin/alembic current
```

Ожидаемый вывод: `<new_revision_id> (head)`.

---

## Task 4: Обновить API_CONTRACT.md

**Files:**
- Modify: `API_CONTRACT.md`

- [ ] **Step 1: Найти секцию `## Владение объектами`**

```bash
grep -n "## Владение объектами" /home/roman/controlling-backend/API_CONTRACT.md
```

Запомнить номер строки (примерно 1067 после правок 022).

- [ ] **Step 2: Вставить новую секцию перед `## Владение объектами`**

Добавить перед строкой `## Владение объектами` следующий блок:

```markdown
## Должностные лица организации

Хранятся в `private.org_officers`. Без даты окончания полномочий — текущий определяется как запись с максимальным `effective_from ≤ запрашиваемая_дата`.

### GET /org_officers
Текущий состав должностных лиц организации.

```
GET /pg/org_officers?organization_id=eq.<uuid>
Authorization: Bearer <token>
```

**Response:**
```json
[
  { "organization_id": "uuid", "officer_type": "chairman",     "contractor_id": "uuid", "effective_from": "2024-01-01" },
  { "organization_id": "uuid", "officer_type": "treasurer",    "contractor_id": "uuid", "effective_from": "2024-01-01" },
  { "organization_id": "uuid", "officer_type": "audit_member", "contractor_id": "uuid", "effective_from": "2024-01-01" },
  { "organization_id": "uuid", "officer_type": "audit_member", "contractor_id": "uuid", "effective_from": "2024-01-01" }
]
```

Роли, по которым никто не назначен, в ответе отсутствуют.

| `officer_type` | Количество | Ограничения на назначение |
|----------------|-----------|--------------------------|
| `chairman` | 1 | нет (может быть наёмным лицом) |
| `treasurer` | 1 | нет |
| `audit_member` | N | TODO: должен быть членом организации (TD-002) |

### POST /rpc/set_org_officer
Назначить должностных лиц. Для ревкомиссии передать всех членов одновременно — они запишутся одной датой.

```
POST /pg/rpc/set_org_officer
Authorization: Bearer <token>
Content-Type: application/json
```

**Request:**
```json
{ "p_org_id": "uuid", "p_officer_type": "chairman", "p_contractor_ids": ["uuid"], "p_effective_from": "2024-01-01" }
```

**Response:** `{"ok": true}`

**Ошибки:** `ORG_MISMATCH`, `EMPTY_CONTRACTORS`.

### POST /rpc/get_officers_at
Состав должностных лиц на произвольную дату. Используется в отчётах.

```
POST /pg/rpc/get_officers_at
Authorization: Bearer <token>
Content-Type: application/json
```

**Request:**
```json
{ "p_org_id": "uuid", "p_date": "2025-06-15" }
```

**Response:** массив `(officer_type, contractor_id, effective_from)` — те же поля, что и в `/org_officers`.

**Ошибки:** `ORG_MISMATCH`.

---

```

- [ ] **Step 3: Добавить 2 кода ошибок в таблицу `## Коды ошибок RPC`**

В секции `## Коды ошибок RPC` после последней строки таблицы добавить:

```markdown
| `EMPTY_CONTRACTORS` | Передан пустой или NULL массив `p_contractor_ids` в `set_org_officer` |
```

- [ ] **Step 4: Проверить**

```bash
grep -n "set_org_officer\|get_officers_at\|EMPTY_CONTRACTORS\|Должностные лица" /home/roman/controlling-backend/API_CONTRACT.md | head -15
```

Ожидаемый вывод: строки с новой секцией и кодом ошибки.

---

## Task 5: Commit и push

- [ ] **Step 1: Проверить статус**

```bash
cd /home/roman/controlling-backend && git status
```

Ожидаемый вывод: новые/изменённые файлы `sql/023_org_officers.sql`, `migrations/versions/<id>_023_org_officers.py`, `API_CONTRACT.md`.

- [ ] **Step 2: Проверить что PostgREST жив**

```bash
curl -s http://localhost:3100/rpc/health | jq .
```

Ожидаемый вывод: `{"ok": true, ...}` без ошибок.

- [ ] **Step 3: Закоммитить**

```bash
cd /home/roman/controlling-backend
git add sql/023_org_officers.sql API_CONTRACT.md
git add migrations/versions/
git commit -m "$(cat <<'EOF'
feat(db): migration 023 — org officers registry

Add private.org_officers (chairman/treasurer/audit_member, no effective_to),
api.org_officers view (current state), api.set_org_officer RPC,
api.get_officers_at RPC for reports. MVP: no appointment validation.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 4: Push**

```bash
git push github master:main
```

Ожидаемый вывод: `master -> main` без ошибок.
