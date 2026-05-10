# CONTROLLING — MASTER DOCUMENT

> **Это главный документ проекта.** Любая новая сессия (Claude или человек) начинает отсюда.  
> Последнее обновление: 2026-05-10

---

## Что это

Система финансового учёта для садоводческих товариществ (СТ).  
Ведёт: взносы, начисления, платежи, долги, показания счётчиков, лицевые счета.  
Мультитенантная — каждое СТ изолировано на уровне БД (PostgreSQL RLS).

---

## Архитектура

```
Браузер (фронтенд, другой сервер)
        │
        ▼
103.35.190.117 (этот сервер, США)
        │
    Nginx :80
    ├── /pg/      → PostgREST :3100  (API данных)
    └── /pgadmin/ → pgAdmin4  :5050  (GUI БД)
        │
    FastAPI :8000  (дашборд разработки — прямой доступ по IP)
        │
    PostgreSQL :5432
    БД: controlling
```

> Cloudflare Tunnel не используется. Доступ прямой по IP.

---

## API для фронтенда

**Base URL:** `http://brachiumartur.com/pg`

```
# Авторизация
POST /pg/rpc/login
{"p_login": "demo_a_chair", "p_password": "chair123"}
→ {"token": "eyJ...", "user_id": "...", "organization_id": "...", "user_role": "admin"}

# Все защищённые запросы
Authorization: Bearer <token>
```

**Frontend .env:**
```
VITE_API_BASE_URL=http://brachiumartur.com/pg
```

Полный API: см. `API_CONTRACT.md` в этой же папке.

---

## Расположение файлов

| Что | Где |
|-----|-----|
| **Git-репо (источник правды)** | `/home/roman/dev-context/` |
| API контракт | `/home/roman/dev-context/API_CONTRACT.md` |
| SQL миграции | `/home/roman/dev-context/sql/` |
| Docker setup | `/home/roman/dev-context/docker-compose.yml` |
| Deploy-инструкция | `/home/roman/dev-context/DEPLOY.md` |
| Список задач | `/home/roman/dev-context/TODO.md` |
| Реестр скриптов | `/home/roman/dev-context/SCRIPTS.md` |
| **Скрипты** | `/home/roman/bin/` |
| Telegram-бот | `/home/roman/bin/controlling-bot.py` |
| Бэкап-скрипт | `/home/roman/bin/pg-backup.sh` |
| **Бэкапы БД** | `/home/roman/backups/` |
| Состояние последнего бэкапа | `/home/roman/backups/last-backup.json` |
| **Дашборд разработки** | `/home/roman/dashboard/` |
| Шаблоны HTML | `/home/roman/dashboard/templates/` |
| Креденшлы | `/home/roman/dev-context/pg-credentials.txt` |

> `dashboard/` — только инструмент разработки, не часть продукта.

---

## Сервисы на сервере

| Сервис | Порт | Управление |
|--------|------|-----------|
| PostgreSQL | 5432 | `sudo systemctl restart postgresql` |
| PostgREST | 3100 | `sudo systemctl restart postgrest-controlling` |
| Nginx | 80 | `sudo systemctl restart nginx` |
| FastAPI дашборд | 8000 | `ps aux \| grep uvicorn` → kill + перезапустить |
| Telegram-бот | — | `sudo systemctl restart controlling-bot` |

**Быстрая проверка:**
```bash
curl http://localhost:3100/rpc/health
```
→ `{"ok": true, "ts": "...", "version": "1.0"}`

---

## GitHub

**Репо:** https://github.com/6205268-creator/controlling-api  
**Remote:** `github` (с токеном в URL, см. `git remote -v`)

```bash
cd /home/roman/dev-context
git status
git push github main
```

---

## Telegram-бот

**Сервис:** `controlling-bot.service` (автозапуск)  
**Команды:**
- `/status` — состояние PostgreSQL, PostgREST, бэкапов
- `/backup` — отчёт о последнем бэкапе и список файлов
- `/help` — справка

**Бот-токен / Chat ID:** в `/home/roman/bin/controlling-bot.py` (строки 13-14)

---

## Резервные копии

- **Расписание:** каждый день в 02:00 (cron)
- **Хранение:** 7 дней, `/home/roman/backups/`
- **Формат файлов:** `controlling_YYYY-MM-DD_HH-MM.sql.gz`
- **Статус:** `cat /home/roman/backups/last-backup.json`
- **Восстановление:**
  ```bash
  zcat /home/roman/backups/controlling_ДАТА.sql.gz | sudo -u postgres psql controlling
  ```

---

## Миграции БД

Все применены: **001–008**

| № | Что |
|---|-----|
| 001 | Базовые таблицы: организации, контрагенты, участки |
| 002 | Пользователи и JWT-авторизация |
| 003 | Документы и типы взносов |
| 004 | Начисления, платежи, распределения |
| 005 | Счётчики и показания |
| 006 | Отчётные представления (views) |
| 007 | Тестовые данные (демо-организации) |
| 008 | Роли: удалены board/member/background, оставлены admin/treasurer/superadmin |

**Применить новую миграцию:**
```bash
cat /home/roman/dev-context/sql/00N-name.sql | sudo -u postgres psql -d controlling
```
*(Сначала показать пользователю, дождаться «применяй»)*

---

## Тестовые пользователи

| Логин | Пароль | Роль | Организация |
|-------|--------|------|-------------|
| `demo_a_chair` | `chair123` | admin | СТ «Демо-А» |
| `demo_a_treasury` | `treasury123` | treasurer | СТ «Демо-А» |
| `demo_b_chair` | `chair123` | admin | СТ «Демо-Б» |
| `demo_b_treasury` | `treasury123` | treasurer | СТ «Демо-Б» |
| `superadmin` | `super123` | superadmin | все орг. |

> `admin / admin123` (UUID 1111...) — тест, удалить перед продакшном.

---

## Следующие задачи (TODO)

Приоритетный порядок:

- [ ] `create_meter_reading` — RPC хелпер (фронтенд делает 2 сырых INSERT, нужен 1 вызов)
- [ ] `create_meter_charge` — то же для начисления по счётчику
- [ ] `change_password` — endpoint смены пароля
- [ ] Logout / инвалидация токена
- [ ] Удалить тест-пользователя `admin/admin123` перед продакшном

---

## Перенос на новый сервер

```bash
# На старом сервере
pg_dump -U postgres controlling > backup.sql

# На новом сервере
git clone https://github.com/6205268-creator/controlling-api.git
cd controlling-api
cp .env.example .env      # заполнить секреты
docker compose up -d
docker exec -i controlling-postgres-1 psql -U controlling_user controlling < backup.sql
```

Подробнее: `DEPLOY.md`

---

## Процесс разработки

Каждая задача:
1. `/brainstorming` — прояснить требование
2. `/writing-plans` — план реализации
3. Реализация (код + SQL)
4. `/verification-before-completion` — проверка перед закрытием

SQL миграции — сначала показать, дождаться «применяй», потом выполнять.

---

## Для следующей сессии Claude

1. Прочитай этот файл
2. Прочитай `TODO.md` — текущие задачи
3. Проверь бэкап: `cat /home/roman/backups/last-backup.json`
4. Проверь сервисы: `curl http://localhost:3100/rpc/health`
5. Спроси пользователя: что делаем сегодня?
