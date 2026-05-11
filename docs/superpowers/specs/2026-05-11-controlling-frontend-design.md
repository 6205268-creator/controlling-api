# Controlling Frontend MVP — Design Spec

**Дата:** 2026-05-11  
**Статус:** Approved  
**Стек:** React 18 + Vite + Tailwind CSS + shadcn/ui  

---

## Что строим

Веб-приложение для казначея садоводческого товарищества. Работает с существующим бэкендом (PostgREST + PostgreSQL на `103.35.190.117`). Упаковано в Docker — `docker compose up` на любом сервере.

---

## Экраны (MVP)

| Экран | Маршрут | Данные |
|-------|---------|--------|
| Логин | `/login` | `POST /rpc/login` |
| Дашборд | `/` | `/doc_journal`, счётчики участков/контрагентов |
| Участки | `/plots` | `GET /plot_summary` |
| Контрагенты | `/contractors` | `GET /contractors` + `GET /account_balances` |

---

## Архитектура

```
controlling-frontend/
├── docker-compose.yml        # docker compose up — и готово
├── Dockerfile                # node:20 build → nginx:alpine serve
├── nginx.conf                # SPA fallback + gzip
├── .env.example              # VITE_API_BASE_URL=http://103.35.190.117/pg
├── src/
│   ├── main.tsx
│   ├── App.tsx               # Router + AuthGuard
│   ├── lib/
│   │   ├── api.ts            # fetch-обёртка, JWT из localStorage
│   │   └── auth.ts           # login(), logout(), getToken(), isAuthenticated()
│   ├── pages/
│   │   ├── LoginPage.tsx
│   │   ├── DashboardPage.tsx
│   │   ├── PlotsPage.tsx
│   │   └── ContractorsPage.tsx
│   └── components/
│       ├── Layout.tsx        # Sidebar + Topbar + <Outlet>
│       └── Sidebar.tsx       # сворачиваемый, иконки + подписи
└── README.md                 # как запустить, как переехать на другой сервер
```

---

## Визуальный стиль

- **Сайдбар:** `#18181b` (антрацит), активный пункт `#2563eb` (синий)
- **Фон контента:** `#f4f4f5`
- **Карточки/таблицы:** белый фон, бордер `#e4e4e7`
- **Таблицы:** зебра (нечётные `#fff`, чётные `#f9f9fb`), hover `#eff6ff`
- **Красный долг:** `#dc2626`, зелёный баланс: `#16a34a`
- **Сайдбар сворачивается** до иконок кнопкой `≡`, при наведении на иконку — tooltip с названием

---

## Авторизация

- JWT хранится в `localStorage` (`controlling_token`)
- При старте приложения — проверка наличия токена, редирект на `/login` если нет
- Все API-запросы: `Authorization: Bearer <token>`
- Токен живёт 8 часов. При 401 от API — редирект на `/login`
- Logout: удалить токен из localStorage + редирект на `/login`

---

## Экраны — детали

### /login
- Поля: логин, пароль
- Кнопка «Войти»
- При успехе: сохранить токен, `organization_id`, `user_role` → редирект на `/`
- При ошибке: показать сообщение

### / (Дашборд)
- 3 карточки: кол-во участков, кол-во контрагентов, общий долг (`GET /object_debts` сумма)
- Таблица: последние 20 операций (`GET /doc_journal?order=doc_date.desc&limit=20`)
- Колонки: дата, тип, контрагент, сумма, статус (badge)

### /plots (Участки)
- Вкладки: Все / Активные / Неактивные
- Таблица из `GET /plot_summary`: №, площадь, владелец, телефон, статус
- Поиск по ФИО владельца (клиентский фильтр)

### /contractors (Контрагенты)
- Таблица: ФИО, телефон, email, баланс (из `account_balances`), статус
- Баланс: положительный зелёный (переплата), отрицательный красный (долг), ноль серый
- Поиск по ФИО (клиентский фильтр)

---

## Docker

```dockerfile
# Dockerfile
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json .
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

```yaml
# docker-compose.yml
services:
  frontend:
    build:
      context: .
      args:
        VITE_API_BASE_URL: ${VITE_API_BASE_URL}
    ports:
      - "3000:80"
```

```dockerfile
# В Dockerfile добавить перед npm run build:
ARG VITE_API_BASE_URL
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
```

> **Важно:** `VITE_API_BASE_URL` вшивается на этапе сборки. При смене IP нужен `docker compose build` заново.

> **Переезд на новый сервер:** `git clone` → `cp .env.example .env` → заполнить IP → `docker compose up -d`

---

## Что НЕ входит в MVP

- Принять платёж (форма) — следующий этап
- Должники — следующий этап
- Журнал документов (отдельная страница) — следующий этап
- Счётчики / показания — следующий этап
- Управление пользователями — следующий этап

---

## Критерии готовности MVP

- [ ] `docker compose up` — приложение открывается по порту 3000
- [ ] Логин через `demo_a_treasury / treasury123` работает
- [ ] Дашборд показывает реальные данные из API
- [ ] Участки: список загружается, поиск фильтрует
- [ ] Контрагенты: список с балансами загружается
- [ ] Сайдбар сворачивается/разворачивается
- [ ] При 401 — редирект на логин
- [ ] `.env.example` задокументирован
