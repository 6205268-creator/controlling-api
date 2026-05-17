# ⚙️ BACKEND SESSION — controlling-api

**Ты работаешь ТОЛЬКО с бэкендом.** Фронтенд — другой проект, другой агент.

---

## Запрещено

- Трогать `/home/roman/controlling-frontend/` — любые файлы
- Коммитить в репо фронтенда
- Делать `npm`, `vite`, `React` изменения

---

## Скоуп этой сессии

| Что | Где |
|-----|-----|
| SQL миграции | `sql/` |
| Alembic ревизии | `migrations/versions/` |
| API контракт | `API_CONTRACT.md` |
| Скрипты | `/home/roman/bin/` |
| БД | PostgreSQL :5432, база `controlling` |
| Git | `git push github main` |

---

## Старт каждой сессии

1. Прочитай `BACKEND_MASTER.md` — архитектура, сервисы, миграции
2. Прочитай `TODO.md` — текущие задачи
3. `curl http://localhost:3100/rpc/health` — проверь что PostgREST жив
4. Спроси пользователя: что делаем?

---

## Ключевые правила

- SQL миграции: сначала показать пользователю, дождаться «применяй», потом выполнять
- Новые миграции через Alembic: `.venv/bin/alembic revision -m "описание"`
- Применить: `.venv/bin/alembic upgrade head`
- Push: `git push github main`

---

> Фронтенд: `/home/roman/controlling-frontend/CLAUDE.md`
> BACKEND_MASTER.md — полный справочник
