# Спека: Тест-контур + api.current_ownership

**Дата:** 2026-05-18  
**Статус:** утверждена  

---

## Цель

Две независимые задачи:
1. Поднять тестовый контур рядом с боевым — для безопасного тестирования миграций
2. Добавить `api.current_ownership` — чтобы фронт мог узнать текущего владельца любого объекта

---

## Задача 1: Тест-контур

### Архитектура

```
Nginx :80
  ├── /pg/        → PostgREST :3100 → БД "controlling"      ← БОЙ
  └── /pg-test/   → PostgREST :3101 → БД "controlling_test" ← ТЕСТ
                           ↑                    ↑
                    оба смотрят на один PostgreSQL контейнер
```

### Принятые решения

- Один PostgreSQL (существующий Docker-контейнер), две базы в нём
- Второй PostgREST — новый сервис `postgrest-test` в `docker-compose.yml`, порт 3101
- Nginx — добавить location `/pg-test/` → `127.0.0.1:3101`
- Тест-база называется `controlling_test` (не staging, не dev — именно "test")

### Данные в тест-контуре

| Режим | Команда | Результат |
|-------|---------|-----------|
| Чистый старт | `test-reset.sh` | Сносит тест-базу, накатывает все миграции заново (seed) |
| Копия из боевой | `test-refresh.sh` | pg_dump из `controlling` → restore в `controlling_test` |

### Скрипты (все в `/home/roman/bin/`)

#### `migrate-test.sh <файл.sql>`
Применяет одну миграцию на тест-базу. Без снимка (тест-база не жалко).

```
Использование: migrate-test.sh sql/014_something.sql
```

#### `migrate-prod.sh <файл.sql>`
**Обязательный снимок** → применяет миграцию на боевую базу.

```
Использование: migrate-prod.sh sql/014_something.sql
Снимок сохраняется в: /home/roman/backups/pre-migrate_<дата>.sql.gz
```

#### `test-reset.sh`
Сносит `controlling_test` и накатывает все миграции 001–N с нуля.

#### `test-refresh.sh`
Копирует данные из боевой базы в тест. Используется когда нужно тестировать на реальных данных.

### Рабочий процесс при новой миграции

```
1. Написал sql/014_something.sql
2. migrate-test.sh sql/014_something.sql   ← применить на тест
3. Проверил: curl, pgAdmin, фронтенд на /pg-test/
4. Доволен → migrate-prod.sh sql/014_something.sql  ← снимок + бой
```

### Переключение фронтенда на тест

Менять только base URL:
- Бой:  `http://103.35.190.117/pg`
- Тест: `http://103.35.190.117/pg-test`

Никаких изменений в коде фронтенда не нужно.

---

## Задача 2: api.current_ownership

### Зачем

Фронт хочет знать: «кто сейчас владеет объектом типа X с ID Y?»  
Например: «кто владеет счётчиком с id = <uuid>?»

### Endpoint

```
GET /pg/current_ownership?object_type=eq.meter&object_id=eq.<uuid>
Authorization: Bearer <token>

→ [{ "organization_id": "...", "object_type": "meter", "object_id": "...", "owner_id": "...", "owner_name": "..." }]
```

### Реализация

Вьюшка `api.current_ownership` — берёт самого последнего проведённого владельца для каждого объекта:

```sql
CREATE VIEW api.current_ownership AS
SELECT DISTINCT ON (deo.organization_id, deo.object_type, deo.object_id)
    deo.organization_id,
    deo.object_type,
    deo.object_id,
    deo.contractor_id AS owner_id,
    c.full_name       AS owner_name
FROM private.doc_ownership deo
JOIN private.documents d ON d.id = deo.document_id
JOIN private.contractors c ON c.id = deo.contractor_id
WHERE deo.status = 'posted'
  AND d.status   = 'posted'
ORDER BY deo.organization_id, deo.object_type, deo.object_id, d.posted_at DESC;
```

RLS: вьюшка видит только данные организации текущего пользователя (через `private.documents` → `organization_id` + существующий RLS на `doc_ownership`).

### Права

```sql
GRANT SELECT ON api.current_ownership TO authenticated;
```

---

## Что НЕ входит в эту задачу

- WAL-архивация / непрерывные инкрементальные бэкапы — отдельная задача, позже
- change_password, logout — в BACKLOG.md
- Staging-ветка в git — не нужна, тест-контур работает на той же кодовой базе

---

## Затрагиваемые файлы

| Файл | Действие |
|------|---------|
| `docker-compose.yml` | Добавить сервис `postgrest-test` |
| `docker/nginx/nginx.conf` | Добавить location `/pg-test/` |
| `/home/roman/bin/migrate-test.sh` | Создать |
| `/home/roman/bin/migrate-prod.sh` | Создать |
| `/home/roman/bin/test-reset.sh` | Создать |
| `/home/roman/bin/test-refresh.sh` | Создать |
| `sql/014_current_ownership.sql` | Создать (вьюшка + права) |
| `docker/postgres/init.sh` | Добавить 014 |
| `API_CONTRACT.md` | Документировать `current_ownership` endpoint |
| `SCRIPTS.md` | Добавить 4 новых скрипта |
