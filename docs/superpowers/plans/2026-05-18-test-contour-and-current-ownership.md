# Test Contour + api.current_ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Поднять тест-контур (вторая БД + второй PostgREST + nginx /pg-test/) и добавить вьюшку `api.current_ownership` для запроса текущего владельца объекта.

**Architecture:** Нативный стек (не Docker): PostgreSQL на localhost:5432, PostgREST как systemd-сервис, nginx через vhosts-includes. Для теста: новая БД `controlling_test` + второй PostgREST `postgrest-test.service` на порту 3101 + nginx location `/pg-test/`.

**Tech Stack:** PostgreSQL 16 (native), PostgREST v14 (native systemd), nginx (native systemd), bash-скрипты.

---

## Карта файлов

| Файл | Действие |
|------|---------|
| `/etc/postgrest/controlling-test.conf` | Создать — конфиг PostgREST для test-контура |
| `/etc/systemd/system/postgrest-test.service` | Создать — systemd unit для второго PostgREST |
| `/etc/nginx/vhosts-includes/postgrest-test.conf` | Создать — nginx location /pg-test/ |
| `/home/roman/bin/migrate-test.sh` | Создать — применить миграцию на controlling_test |
| `/home/roman/bin/migrate-prod.sh` | Создать — снимок + применить миграцию на controlling |
| `/home/roman/bin/test-reset.sh` | Создать — снести и пересоздать controlling_test с нуля |
| `/home/roman/bin/test-refresh.sh` | Создать — скопировать данные из прод в тест |
| `sql/014_current_ownership.sql` | Создать — вьюшка api.current_ownership |
| `docker/postgres/init.sh` | Изменить — добавить миграцию 014 |
| `API_CONTRACT.md` | Изменить — документировать current_ownership |
| `SCRIPTS.md` | Изменить — добавить 4 новых скрипта |

---

## Task 1: Создать базу данных controlling_test

**Files:**
- No files — только SQL команды через psql

- [ ] **Step 1: Создать базу данных**

```bash
sudo -u postgres psql -c "CREATE DATABASE controlling_test OWNER controlling_user ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;"
```

Ожидаемый вывод: `CREATE DATABASE`

- [ ] **Step 2: Установить расширения в новой БД**

```bash
sudo -u postgres psql -d controlling_test -c "
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
CREATE EXTENSION IF NOT EXISTS pg_cron;
"
```

Ожидаемый вывод: `CREATE EXTENSION` (3 раза)

- [ ] **Step 3: Настроить роли (они уже есть на уровне кластера, нужны только GRANT)**

```bash
sudo -u postgres psql -d controlling_test -c "
GRANT anon TO authenticated;
GRANT authenticated TO app_admin;
GRANT authenticated TO controlling_user;
GRANT app_admin TO controlling_user;
"
```

Ожидаемый вывод: `GRANT ROLE` (4 раза)

- [ ] **Step 4: Применить все 13 миграций**

```bash
cd /home/roman/controlling-backend

for f in sql/001_schema.sql sql/002_doc_accrual.sql sql/003_rpc_functions.sql \
          sql/004_extended_views.sql sql/005_fixes_and_create_distribution.sql \
          sql/006_auth_and_rls.sql sql/007_plot_ownerships_admin_seed.sql \
          sql/008_cleanup_roles.sql sql/009_create_meter_helpers.sql \
          sql/010_ownership_flow.sql sql/011_crud_rpc.sql \
          sql/012_ownership_journal_actuality.sql sql/013_delete_draft_org_settings.sql; do
    echo "Applying $f..."
    cat "$f" | sudo -u postgres psql -v ON_ERROR_STOP=1 -d controlling_test
done
echo "Done."
```

Ожидаемый вывод: `Applying sql/001...` ... `Done.` — без ошибок.

- [ ] **Step 5: Проверить что таблицы появились**

```bash
sudo -u postgres psql -d controlling_test -c "\dt private.*" | head -20
```

Ожидаемый вывод: список таблиц (organizations, users, plots, meters, contractors и т.д.)

---

## Task 2: Создать PostgREST конфиг и systemd-сервис для теста

**Files:**
- Create: `/etc/postgrest/controlling-test.conf`
- Create: `/etc/systemd/system/postgrest-test.service`

- [ ] **Step 1: Создать конфиг PostgREST для test**

> **IMPORTANT:** JWT secret должен совпадать с прод-конфигом (`/etc/postgrest/controlling.conf`), чтобы те же токены работали на обоих контурах.

```bash
# Прочитать пароль и JWT из прод-конфига
PROD_URI=$(sudo grep "^db-uri" /etc/postgrest/controlling.conf | cut -d'"' -f2)
JWT=$(sudo grep "^jwt-secret" /etc/postgrest/controlling.conf | cut -d'"' -f2)

# Заменить имя БД на controlling_test, порт на 3101
TEST_URI="${PROD_URI/\/controlling/\/controlling_test}"

sudo tee /etc/postgrest/controlling-test.conf > /dev/null <<EOF
db-uri = "$TEST_URI"
db-schemas = "api"
db-anon-role = "anon"
server-port = 3101
server-host = "127.0.0.1"
jwt-secret = "$JWT"
jwt-secret-is-base64 = false
log-level = "info"
EOF

echo "Config written."
sudo cat /etc/postgrest/controlling-test.conf
```

Ожидаемый вывод: конфиг с `controlling_test` в URI и `server-port = 3101`.

- [ ] **Step 2: Создать systemd unit**

```bash
sudo tee /etc/systemd/system/postgrest-test.service > /dev/null <<'EOF'
[Unit]
Description=PostgREST API server for CONTROLLING TEST
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/postgrest /etc/postgrest/controlling-test.conf
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=postgrest-test

[Install]
WantedBy=multi-user.target
EOF

echo "Service unit written."
```

- [ ] **Step 3: Включить и запустить сервис**

```bash
sudo systemctl daemon-reload
sudo systemctl enable postgrest-test
sudo systemctl start postgrest-test
sudo systemctl status postgrest-test
```

Ожидаемый вывод: `Active: active (running)`.

- [ ] **Step 4: Проверить что PostgREST слушает на 3101**

```bash
curl -s http://127.0.0.1:3101/
```

Ожидаемый вывод: JSON с описанием API (список таблиц/функций).

---

## Task 3: Добавить nginx location /pg-test/

**Files:**
- Create: `/etc/nginx/vhosts-includes/postgrest-test.conf`

- [ ] **Step 1: Создать nginx include-файл для test**

```bash
sudo tee /etc/nginx/vhosts-includes/postgrest-test.conf > /dev/null <<'EOF'
location /pg-test/ {
    proxy_pass http://127.0.0.1:3101/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

    add_header Access-Control-Allow-Origin  * always;
    add_header Access-Control-Allow-Headers "Authorization, Content-Type, Prefer" always;
    add_header Access-Control-Allow-Methods "GET, POST, PATCH, DELETE, OPTIONS" always;

    if ($request_method = OPTIONS) {
        return 204;
    }
}
EOF

echo "Nginx config written."
```

- [ ] **Step 2: Проверить синтаксис nginx и перезагрузить**

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Ожидаемый вывод: `nginx: configuration file ... syntax is ok` + `nginx: configuration file ... test is successful`.

- [ ] **Step 3: Проверить доступность через nginx**

```bash
curl -s http://localhost/pg-test/
```

Ожидаемый вывод: JSON с описанием API (тот же что был через :3101 напрямую).

- [ ] **Step 4: Проверить что prod не сломался**

```bash
curl -s http://localhost/pg/
```

Ожидаемый вывод: JSON с описанием API прод-контура.

- [ ] **Step 5: Сохранить конфиг-пример в репо (без секретов — только структура)**

Системные файлы `/etc/` не версионируются. Сохраним пример конфига без пароля и JWT:

```bash
cat > /home/roman/controlling-backend/docker/postgres/controlling-test.conf.example << 'EOF'
db-uri = "postgresql://controlling_user:<PASSWORD>@localhost:5432/controlling_test"
db-schemas = "api"
db-anon-role = "anon"
server-port = 3101
server-host = "127.0.0.1"
jwt-secret = "<JWT_SECRET>"
jwt-secret-is-base64 = false
log-level = "info"
EOF
echo "Example config saved."
```

---

## Task 4: Создать 4 bash-скрипта

**Files:**
- Create: `/home/roman/bin/migrate-test.sh`
- Create: `/home/roman/bin/migrate-prod.sh`
- Create: `/home/roman/bin/test-reset.sh`
- Create: `/home/roman/bin/test-refresh.sh`

- [ ] **Step 1: migrate-test.sh**

```bash
cat > /home/roman/bin/migrate-test.sh << 'EOF'
#!/bin/bash
# Применить SQL-миграцию на тест-базу controlling_test
# Использование: migrate-test.sh sql/014_something.sql

set -e

if [ -z "$1" ]; then
    echo "Использование: $0 <файл.sql>"
    exit 1
fi

FILE="$1"
if [ ! -f "$FILE" ]; then
    echo "Файл не найден: $FILE"
    exit 1
fi

echo "=== Применяю $FILE на controlling_test ==="
cat "$FILE" | sudo -u postgres psql -v ON_ERROR_STOP=1 -d controlling_test

echo "=== Обновляю schema cache PostgREST test ==="
sudo systemctl restart postgrest-test

echo "=== Готово ==="
EOF
chmod +x /home/roman/bin/migrate-test.sh
echo "migrate-test.sh создан"
```

- [ ] **Step 2: migrate-prod.sh**

```bash
cat > /home/roman/bin/migrate-prod.sh << 'EOF'
#!/bin/bash
# Применить SQL-миграцию на боевую базу controlling
# СНАЧАЛА делает pg_dump (снимок), потом применяет
# Использование: migrate-prod.sh sql/014_something.sql

set -e

if [ -z "$1" ]; then
    echo "Использование: $0 <файл.sql>"
    exit 1
fi

FILE="$1"
if [ ! -f "$FILE" ]; then
    echo "Файл не найден: $FILE"
    exit 1
fi

BACKUP_DIR="/home/roman/backups"
SNAP="$BACKUP_DIR/pre-migrate_$(date +%Y-%m-%d_%H-%M-%S).sql.gz"

echo "=== Снимок базы перед миграцией ==="
sudo -u postgres pg_dump controlling | gzip > "$SNAP"
echo "Снимок сохранён: $SNAP ($(du -h "$SNAP" | cut -f1))"

echo "=== Применяю $FILE на controlling ==="
cat "$FILE" | sudo -u postgres psql -v ON_ERROR_STOP=1 -d controlling

echo "=== Обновляю schema cache PostgREST prod ==="
sudo systemctl restart postgrest-controlling

echo "=== Готово. Откат если нужно: ==="
echo "  zcat $SNAP | sudo -u postgres psql -d controlling"
EOF
chmod +x /home/roman/bin/migrate-prod.sh
echo "migrate-prod.sh создан"
```

- [ ] **Step 3: test-reset.sh**

```bash
cat > /home/roman/bin/test-reset.sh << 'EOF'
#!/bin/bash
# Снести controlling_test и пересоздать с нуля (seed из миграций)
# После: чистые тестовые данные, без реальных

set -e

REPO="/home/roman/controlling-backend"

echo "=== Пересоздаю controlling_test с нуля ==="

sudo -u postgres psql -c "DROP DATABASE IF EXISTS controlling_test;"
sudo -u postgres psql -c "CREATE DATABASE controlling_test OWNER controlling_user ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;"

sudo -u postgres psql -d controlling_test -c "
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
CREATE EXTENSION IF NOT EXISTS pg_cron;
GRANT anon TO authenticated;
GRANT authenticated TO app_admin;
GRANT authenticated TO controlling_user;
GRANT app_admin TO controlling_user;
"

for f in $(ls "$REPO/sql/"*.sql | sort); do
    echo "Applying $(basename $f)..."
    cat "$f" | sudo -u postgres psql -v ON_ERROR_STOP=1 -d controlling_test
done

echo "=== Обновляю schema cache PostgREST test ==="
sudo systemctl restart postgrest-test

echo "=== Готово. controlling_test пересоздана с seed-данными ==="
EOF
chmod +x /home/roman/bin/test-reset.sh
echo "test-reset.sh создан"
```

- [ ] **Step 4: test-refresh.sh**

```bash
cat > /home/roman/bin/test-refresh.sh << 'EOF'
#!/bin/bash
# Скопировать реальные данные из controlling в controlling_test
# После: тест-база = зеркало прод на момент запуска

set -e

TMP="/tmp/controlling_refresh_$(date +%s).sql"

echo "=== Дамп из controlling ==="
sudo -u postgres pg_dump --no-owner --no-acl -d controlling > "$TMP"
echo "Дамп готов: $(du -h "$TMP" | cut -f1)"

echo "=== Пересоздаю controlling_test ==="
sudo -u postgres psql -c "DROP DATABASE IF EXISTS controlling_test;"
sudo -u postgres psql -c "CREATE DATABASE controlling_test OWNER controlling_user ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;"

sudo -u postgres psql -d controlling_test -c "
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\";
CREATE EXTENSION IF NOT EXISTS pg_cron;
GRANT anon TO authenticated;
GRANT authenticated TO app_admin;
GRANT authenticated TO controlling_user;
GRANT app_admin TO controlling_user;
"

echo "=== Восстанавливаю данные в controlling_test ==="
cat "$TMP" | sudo -u postgres psql -d controlling_test
rm "$TMP"

echo "=== Обновляю schema cache PostgREST test ==="
sudo systemctl restart postgrest-test

echo "=== Готово. controlling_test = копия прод ==="
EOF
chmod +x /home/roman/bin/test-refresh.sh
echo "test-refresh.sh создан"
```

- [ ] **Step 5: Проверить скрипты**

```bash
ls -la /home/roman/bin/migrate-test.sh /home/roman/bin/migrate-prod.sh \
        /home/roman/bin/test-reset.sh /home/roman/bin/test-refresh.sh
```

Ожидаемый вывод: все 4 файла с правами `-rwxr-xr-x`.

- [ ] **Step 6: Проверить что все 4 скрипта работают без аргументов (показывают help)**

```bash
/home/roman/bin/migrate-test.sh
/home/roman/bin/migrate-prod.sh
```

Ожидаемый вывод: `Использование: /home/roman/bin/migrate-test.sh <файл.sql>` (не падает с ошибкой).

---

## Task 5: Написать миграцию 014 — api.current_ownership

**Files:**
- Create: `sql/014_current_ownership.sql`

- [ ] **Step 1: Создать файл миграции**

```bash
cat > /home/roman/controlling-backend/sql/014_current_ownership.sql << 'EOF'
-- 014_current_ownership.sql
-- Вьюшка: текущий владелец объекта (plot, meter и т.д.)
-- Возвращает владельца на основе последнего проведённого документа владения.

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

GRANT SELECT ON api.current_ownership TO authenticated;

COMMENT ON VIEW api.current_ownership IS
    'Текущий владелец объекта (plot, meter и т.д.) — по последнему проведённому документу владения. RLS через doc_ownership.organization_id.';
EOF
echo "014 создана"
```

- [ ] **Step 2: Применить 014 на тест**

```bash
/home/roman/bin/migrate-test.sh /home/roman/controlling-backend/sql/014_current_ownership.sql
```

Ожидаемый вывод: `CREATE VIEW`, `GRANT`, `COMMENT`, затем `Готово`.

- [ ] **Step 3: Проверить вьюшку на тест-контуре**

```bash
# Анонимный запрос без токена — должен вернуть 401 (не 404)
curl -s -o /dev/null -w "%{http_code}" http://localhost/pg-test/current_ownership
```

Ожидаемый вывод: `401` (вьюшка существует, но требует авторизацию)

- [ ] **Step 4: Проверить с токеном**

```bash
# Получить токен
TOKEN=$(curl -s -X POST http://localhost/pg/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"demo_a_chair","p_password":"chair123"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# Запросить current_ownership
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost/pg-test/current_ownership?limit=5" | python3 -m json.tool
```

Ожидаемый вывод: JSON-массив (может быть пустым `[]` если нет posted-документов в seed, это нормально).

- [ ] **Step 5: Применить 014 на прод**

```bash
/home/roman/bin/migrate-prod.sh /home/roman/controlling-backend/sql/014_current_ownership.sql
```

Ожидаемый вывод: `Снимок сохранён`, `CREATE VIEW`, `GRANT`, `COMMENT`, `Готово`.

- [ ] **Step 6: Проверить на проде**

```bash
TOKEN=$(curl -s -X POST http://localhost/pg/rpc/login \
  -H "Content-Type: application/json" \
  -d '{"p_login":"demo_a_chair","p_password":"chair123"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost/pg/current_ownership?limit=5" | python3 -m json.tool
```

Ожидаемый вывод: JSON-массив с реальными данными (объекты у которых есть проведённые документы владения).

---

## Task 6: Обновить документацию и добавить 014 в init.sh

**Files:**
- Modify: `docker/postgres/init.sh`
- Modify: `API_CONTRACT.md`
- Modify: `SCRIPTS.md`

- [ ] **Step 1: Добавить 014 в init.sh**

```bash
cat >> /home/roman/controlling-backend/docker/postgres/init.sh << 'EOF'

echo "Applying 014_current_ownership.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/014_current_ownership.sql
EOF
echo "init.sh updated."
tail -5 /home/roman/controlling-backend/docker/postgres/init.sh
```

Ожидаемый вывод последних строк: блок `echo "Applying 014..."` + `psql ...`.

- [ ] **Step 2: Обновить API_CONTRACT.md — добавить current_ownership**

В `API_CONTRACT.md` в секцию с вьюшками добавить:

```markdown
### GET /current_ownership

Возвращает текущего владельца объекта (участка, счётчика и т.д.).

**Фильтры (PostgREST query params):**
- `object_type=eq.plot` — тип объекта: `plot`, `meter`, и др.
- `object_id=eq.<uuid>` — ID объекта

**Пример запроса:**
```
GET /pg/current_ownership?object_type=eq.meter&object_id=eq.<uuid>
Authorization: Bearer <token>
```

**Ответ:**
```json
[{
  "organization_id": "uuid",
  "object_type": "meter",
  "object_id": "uuid",
  "owner_id": "uuid",
  "owner_name": "Иванов Иван Иванович"
}]
```

**Примечание:** возвращает пустой массив если объект не имеет проведённого документа владения.
```

- [ ] **Step 3: Обновить SCRIPTS.md — добавить 4 скрипта**

В таблицу `SCRIPTS.md` добавить строки:

```markdown
| migrate-test.sh | /home/roman/bin/migrate-test.sh | Применить SQL-миграцию на controlling_test | ❌ |
| migrate-prod.sh | /home/roman/bin/migrate-prod.sh | Снимок + применить SQL-миграцию на controlling | ❌ |
| test-reset.sh | /home/roman/bin/test-reset.sh | Снести и пересоздать controlling_test с seed | ❌ |
| test-refresh.sh | /home/roman/bin/test-refresh.sh | Скопировать прод-данные в controlling_test | ❌ |
```

- [ ] **Step 4: Commit всего**

```bash
cd /home/roman/controlling-backend
git add sql/014_current_ownership.sql docker/postgres/init.sh \
        API_CONTRACT.md SCRIPTS.md \
        docker/postgres/controlling-test.conf.example
git commit -m "feat: test-contour (postgrest-test :3101 + /pg-test/) + api.current_ownership view"
```

- [ ] **Step 5: Push**

```bash
git push github main
```

Ожидаемый вывод: `master -> main`.

---

## Итоговая проверка

- [ ] `curl http://localhost/pg-test/` → JSON API  
- [ ] `curl http://localhost/pg/` → JSON API (прод не сломан)  
- [ ] `sudo systemctl status postgrest-test` → active (running)  
- [ ] `sudo systemctl status postgrest-controlling` → active (running)  
- [ ] `/home/roman/bin/migrate-test.sh --help` (без аргументов) → сообщение об использовании  
- [ ] `sudo -u postgres psql -d controlling_test -c "\dv api.*"` → видна `current_ownership`  
- [ ] `sudo -u postgres psql -d controlling -c "\dv api.*"` → видна `current_ownership`  
