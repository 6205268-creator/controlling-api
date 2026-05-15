# Развёртывание и переезд на новый сервер

## Быстрый старт (новый сервер)

```bash
# 1. Установить Docker
curl -fsSL https://get.docker.com | sh

# 2. Клонировать репозиторий
git clone https://github.com/6205268-creator/controlling-api.git
cd controlling-api

# 3. Создать файл с секретами
cp .env.example .env
nano .env   # заполнить POSTGRES_PASSWORD и JWT_SECRET

# 4. Запустить
docker compose up -d

# 5. Проверить что работает
curl http://localhost/pg/rpc/health
```

Готово. PostgreSQL создаётся, миграции применяются автоматически, PostgREST и Nginx стартуют.

---

## Перенос данных со старого сервера

Если нужно перенести живые данные (не demo-seed):

```bash
# --- На СТАРОМ сервере ---
pg_dump -U postgres controlling > backup.sql
# Скопировать backup.sql на новый сервер (scp, rsync и т.д.)

# --- На НОВОМ сервере (после docker compose up -d) ---
# Дождаться старта PostgreSQL (5-10 секунд)
docker compose exec postgres psql -U controlling_user controlling < backup.sql
```

---

## Управление

```bash
# Статус контейнеров
docker compose ps

# Логи
docker compose logs postgrest
docker compose logs postgres

# Перезапустить PostgREST (после изменений в БД)
docker compose restart postgrest

# Остановить всё (данные НЕ удаляются)
docker compose down

# Остановить и удалить данные (ОСТОРОЖНО — необратимо)
docker compose down -v
```

---

## Обновление (новая миграция)

### Alembic (рекомендуется для уже поднятой БД)

Схема хранится в `sql/*.sql`, а **Alembic** последовательно применяет новые файлы через `psql` (см. `migrations/versions/*.py` и `migrations/sql_migration.py`).

На сервере, где объекты `api.*` принадлежат роли **`postgres`**, а не `controlling_user`, перед `upgrade` задайте выполнение `psql` от суперпользователя и передайте SQL на stdin (см. `ALEMBIC_PSQL_AS_USER` в `sql_migration.py`):

```bash
cd /path/to/controlling-api   # или controlling-backend
export ALEMBIC_PSQL_AS_USER=postgres
.venv/bin/alembic upgrade head
unset ALEMBIC_PSQL_AS_USER
```

Нужен `sudo` без пароля на `-u postgres` **или** запуск из-под учётки с правом вызывать `sudo -u postgres`.

После миграций **перезапустите PostgREST**, чтобы обновился кэш схемы:

```bash
docker compose restart postgrest
# или: sudo systemctl restart postgrest-controlling
```

### Вручную через SQL (как раньше)

```bash
# 1. Добавить новый SQL-файл в sql/
# 2. Добавить его вызов в docker/postgres/init.sh (для новых установок)
# 3. Добавить ревизию Alembic, вызывающую этот файл (см. migrations/)
# 4. На работающем сервере при необходимости:
sudo -u postgres psql -d controlling -v ON_ERROR_STOP=1 -f sql/NNN_....sql
```

---

## Файл .env (обязательные параметры)

| Параметр | Описание |
|----------|----------|
| `POSTGRES_PASSWORD` | Пароль PostgreSQL — любая длинная строка |
| `JWT_SECRET` | Секрет для JWT — минимум 32 символа |

Сгенерировать JWT_SECRET:
```bash
openssl rand -base64 48 | tr -d '/+=\n' | head -c 48
```

---

## HTTPS (домен + сертификат)

1. Получить сертификат (Let's Encrypt):
```bash
apt install certbot
certbot certonly --standalone -d your-domain.com
```

2. Скопировать сертификаты:
```bash
cp /etc/letsencrypt/live/your-domain.com/fullchain.pem docker/nginx/ssl/
cp /etc/letsencrypt/live/your-domain.com/privkey.pem   docker/nginx/ssl/
```

3. Раскомментировать HTTPS-блок в `docker/nginx/nginx.conf`.

4. `docker compose restart nginx`
