# Controlling API — Список следующих задач

**Дата брейнсторма:** 2026-05-09  
**Текущий стек:** PostgreSQL 16 + PostgREST 14 + Nginx + Docker  
**Репо:** https://github.com/6205268-creator/controlling-api

---

## Статус MVP

Бэкенд работает. Миграции 001–007 применены. Фронтенд активно разрабатывается.

---

## Что нужно доделать (приоритет по порядку)

### 1. Хелперы для счётчиков (высокий приоритет)
- [ ] `create_meter_reading` — RPC для создания черновика показания счётчика (сейчас фронт делает 2 сырых запроса)
- [ ] `create_meter_charge` — RPC для создания черновика начисления по счётчику

### 2. Управление пользователями
- [ ] `change_password` — endpoint смены пароля
- [ ] Logout / инвалидация токена (сейчас токен живёт 8 часов и не отзывается)

### 3. Документация (не блокирует фронтенд)
- [ ] Перенести `API_CONTRACT.md`, `DEPLOY.md`, `README.md` в репо (сейчас они в /home/roman/dev-context/)
- [ ] Актуализировать README.md репо

---

## Процесс разработки (договорились на сессии 2026-05-09)

Подход **B** — API + процесс параллельно:
- Каждая новая задача идёт через superpowers-скиллы
- Порядок: `/brainstorming` → `/writing-plans` → реализация → `/verification-before-completion`

---

## Архив

Устаревшие документы перемещены в `/home/roman/dev-context/archive/`:
- `project-design.md` — старый дизайн на FastAPI + Vue 3
- `CONTROLLING_1C_BACKEND_FULL.md` — документация 1С-бэкенда (не реализован)
- `controlling-plan.md` — план реализации на 1С
- `brainstorm-controlling.md` — старый брейнсторм
- `controlling-rollback-mechanics.md` — механика откатов (1С)
- `kontrolling/` — вся папка с 1С-контекстом
