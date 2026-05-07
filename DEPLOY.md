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

```bash
# 1. Добавить новый SQL-файл в sql/
# 2. Добавить его вызов в docker/postgres/init.sh (для новых установок)
# 3. На работающем сервере применить вручную:
docker compose exec postgres psql -U controlling_user controlling -f /docker-entrypoint-initdb.d/sql/008_новый_файл.sql
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
