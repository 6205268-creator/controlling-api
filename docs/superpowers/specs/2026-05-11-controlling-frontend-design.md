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
| Дашборд | `/` | `/doc_journal`, счётчики участков/плательщиков |
| Участки | `/plots` | `GET /plot_summary` |
| Члены СТ | `/members` | `GET /members` + `GET /contractors` (ФИО) |
| Счётчики | `/meters` | `GET /meters` + `GET /plots` (номер участка) |
| Плательщики | `/contractors` | `GET /contractors` + `GET /account_balances` |

---

## Архитектура

```
controlling-frontend/
├── docker-compose.yml
├── Dockerfile
├── nginx.conf
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
│   │   ├── MembersPage.tsx
│   │   ├── MetersPage.tsx
│   │   └── ContractorsPage.tsx   # «Плательщики» в UI
│   └── components/
│       ├── Layout.tsx        # Sidebar + Topbar + <Outlet>
│       └── Sidebar.tsx       # сворачиваемый, иконки + подписи
└── README.md
```

---

## Навигация (сайдбар)

```
≡  CONTROLLING

📊  Дашборд
🏡  Участки
👥  Члены СТ
⚡  Счётчики
💳  Плательщики

—————————
↩  Выйти
    Петрова А.В.
    Казначей · СТ «Демо-А»
```

---

## Визуальный стиль

- **Сайдбар:** `#18181b` (антрацит), активный пункт `#2563eb` (синий)
- **Фон контента:** `#f4f4f5`
- **Карточки/таблицы:** белый фон, бордер `#e4e4e7`
- **Таблицы:** зебра (нечётные `#fff`, чётные `#f9f9fb`), hover `#eff6ff`
- **Красный долг:** `#dc2626`, зелёный баланс: `#16a34a`
- **Сайдбар сворачивается** до иконок кнопкой `≡`, при наведении — tooltip

---

## Авторизация

- JWT хранится в `localStorage` (`controlling_token`)
- При старте — проверка токена, редирект на `/login` если нет
- Все API-запросы: `Authorization: Bearer <token>`
- Токен живёт 8 часов. При 401 — редирект на `/login`
- Logout: удалить токен + редирект на `/login`

---

## Экраны — детали

### /login
- Поля: логин, пароль
- При успехе: сохранить токен, `organization_id`, `user_role` → редирект на `/`
- При ошибке: показать сообщение

### / (Дашборд)
- 3 карточки: кол-во участков, кол-во плательщиков, общий долг
- Таблица: последние 20 операций (`GET /doc_journal?order=doc_date.desc&limit=20`)
- Колонки: дата, тип, плательщик, сумма, статус (badge)

### /plots (Участки)
- Вкладки: Все / Активные / Неактивные
- Таблица из `GET /plot_summary`: №, площадь, владелец, телефон, статус
- Поиск по ФИО владельца (клиентский фильтр)

### /members (Члены СТ)
- Таблица: номер члена, ФИО (из contractors), телефон, дата вступления, статус
- Данные: `GET /members` join по `contractor_id` → `GET /contractors`
- Поиск по ФИО (клиентский фильтр)

### /meters (Счётчики)
- Таблица: тип счётчика (вода/электро), серийный номер, участок (номер из `/plots`), статус
- Данные: `GET /meters` + номер участка из `GET /plots`
- Фильтр по типу счётчика (вода / электричество / все)

### /contractors (Плательщики)
- Таблица: ФИО, телефон, email, баланс, статус
- Баланс из `GET /account_balances` по `contractor_id`: зелёный (+), красный (−), серый (0)
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
ARG VITE_API_BASE_URL
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
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

> **Важно:** `VITE_API_BASE_URL` вшивается при сборке. При смене IP — `docker compose build` заново.  
> **Переезд:** `git clone` → `cp .env.example .env` → заполнить IP → `docker compose up -d`

---

## Что НЕ входит в MVP

- Принять платёж (форма)
- Должники
- Журнал документов (отдельная страница)
- Показания счётчиков
- Управление пользователями

---

## Критерии готовности MVP

- [ ] `docker compose up` — приложение открывается на порту 3000
- [ ] Логин через `demo_a_treasury / treasury123` работает
- [ ] Дашборд показывает реальные данные из API
- [ ] Участки: список загружается, поиск фильтрует
- [ ] Члены СТ: список с ФИО плательщика загружается
- [ ] Счётчики: список с типом и номером участка загружается
- [ ] Плательщики: список с балансами загружается
- [ ] Сайдбар сворачивается/разворачивается
- [ ] При 401 — редирект на логин
