# Бриф для фронтенд-агента — Controlling

## Что нужно исправить

### 1. Base URL API

Везде где используется старый домен — заменить:

| Было | Стало |
|------|-------|
| `http://brachiumartur.com/pg` | `http://103.35.190.117/pg` |
| `http://brachiumartur.com/pg/...` | `http://103.35.190.117/pg/...` |

**Env-файл:**
```
VITE_API_BASE_URL=http://103.35.190.117/pg
```

Домен `brachiumartur.com` не в публичном DNS — фронт его не разрезолвит. Только IP.

---

## Текущий бэкенд

**Сервер:** `103.35.190.117`  
**API base URL:** `http://103.35.190.117/pg`  
**Tech:** PostgreSQL 16 + PostgREST 14 + Nginx  
**Content-Type:** `application/json`  
**Auth:** `Authorization: Bearer <JWT>`  
**Валюта:** только BYN (Decimal, 2 знака)  
**CORS:** настроен, принимает запросы с любого origin

---

## Авторизация

### Логин
```
POST /pg/rpc/login
Content-Type: application/json

{"p_login": "demo_a_chair", "p_password": "chair123"}
```
**Ответ:**
```json
{
  "token": "eyJhbGci...",
  "expires_at": "2026-05-07T21:00:00Z",
  "user_id": "uuid",
  "organization_id": "uuid",
  "user_role": "admin"
}
```
Токен живёт **8 часов**. Хранить в localStorage/sessionStorage.

### Все защищённые запросы
```
Authorization: Bearer <token>
```

### Кто я (проверка токена)
```
POST /pg/rpc/me
Authorization: Bearer <token>
```
Ответ: `user_id`, `login`, `full_name`, `role`, `organization_id`

### Создать пользователя (только admin)
```
POST /pg/rpc/create_user
Authorization: Bearer <token>

{
  "p_login": "treasurer1",
  "p_password": "pass123",
  "p_full_name": "Петров Иван",
  "p_role": "treasurer"
}
```
Допустимые `p_role`: `admin`, `treasurer`. Пользователь создаётся в организации того, кто создаёт.

---

## Роли пользователей

| Роль | `user_role` в токене | Что может |
|------|---------------------|-----------|
| Суперадминистратор | `superadmin` | Видит все организации; фильтрует через `?organization_id=eq.<uuid>` |
| Председатель | `admin` | Полный доступ к своей организации; создаёт пользователей |
| Казначей | `treasurer` | Финансовые операции своей организации |

> Роли `board`, `member`, `background` **удалены**. Если фронт их встречает — устаревшие данные.

### Мультитенантность
Каждый запрос автоматически фильтруется по `organization_id` из токена (PostgreSQL RLS).  
Фронтенд **всегда** передаёт `organization_id` в GET-запросах.

---

## Тестовые пользователи

| Логин | Пароль | Роль | Организация |
|-------|--------|------|-------------|
| `demo_a_chair` | `chair123` | admin | СТ «Демо-А» |
| `demo_a_treasury` | `treasury123` | treasurer | СТ «Демо-А» |
| `demo_b_chair` | `chair123` | admin | СТ «Демо-Б» |
| `demo_b_treasury` | `treasury123` | treasurer | СТ «Демо-Б» |
| `superadmin` | `super123` | superadmin | все организации |

---

## Формат ответов

### GET (списки)
```json
[{"id": "uuid", ...}, ...]
```

### RPC (бизнес-операции)
```json
{"ok": true, "document_id": "uuid", ...}
```

### Ошибка RPC
```json
{"ok": false, "error": "ERROR_CODE: описание"}
```

### PostgREST фильтры
```
?organization_id=eq.<uuid>     — точное совпадение
?total_debt=gt.0               — больше нуля
?order=doc_date.desc           — сортировка
?limit=50&offset=0             — пагинация
?select=id,name,owner_name     — выбор полей
```

---

## Справочники

```
GET /pg/organizations                                      — список организаций
GET /pg/contractors?organization_id=eq.<uuid>             — контрагенты (плательщики)
GET /pg/members?organization_id=eq.<uuid>                 — члены кооператива
GET /pg/plots?organization_id=eq.<uuid>                   — участки
GET /pg/meters?organization_id=eq.<uuid>                  — счётчики
GET /pg/contribution_types?organization_id=eq.<uuid>      — виды взносов
GET /pg/tariffs?organization_id=eq.<uuid>                 — тарифы
```

---

## Документы

```
GET /pg/doc_journal?organization_id=eq.<uuid>&order=doc_date.desc
```
Журнал с суммой и контрагентом. Поля: `id`, `doc_type`, `doc_date`, `status`, `amount`, `contractor_name`, `period`.

**Типы документов** (`doc_type`): `payment`, `accrual`, `distribution`, `meter_reading`, `meter_charge`, `period_close`, `meter_correction`

**Статусы** (`status`): `draft`, `posted`, `cancelled`

---

## Финансовые отчёты

```
GET /pg/account_balances?organization_id=eq.<uuid>                          — остатки лицевых счетов
GET /pg/debtors?organization_id=eq.<uuid>&order=total_debt.desc             — должники
GET /pg/plot_summary?organization_id=eq.<uuid>                              — сводка по участкам (главный отчёт)
GET /pg/account_statement?organization_id=eq.<uuid>&contractor_id=eq.<uuid> — выписка по контрагенту
GET /pg/object_debts?organization_id=eq.<uuid>                              — долги по объектам
```

`plot_summary` — основной экран казначея: участок + владелец + долг.

---

## Бизнес-операции (RPC)

Все RPC — `POST`, тело — JSON.

### Платежи
```
POST /pg/rpc/create_payment    — создать черновик платежа
POST /pg/rpc/post_payment      — провести платёж
```
`create_payment` принимает: `p_org_id`, `p_contractor_id`, `p_amount`, `p_doc_date` (опц.), `p_payment_ref` (опц.), `p_notes` (опц.)

### Начисления
```
POST /pg/rpc/create_accrual_batch  — пакетное начисление для всех объектов
POST /pg/rpc/post_accrual          — провести начисление
```
`create_accrual_batch` принимает: `p_org_id`, `p_contribution_type`, `p_period`, `p_object_type` (`plot`/`member`/`meter`), `p_amount_per_object`

### Распределение
```
POST /pg/rpc/create_distribution   — разнести платёж по долгам
POST /pg/rpc/post_distribution     — провести распределение
```

### Счётчики
```
POST /pg/rpc/post_meter_reading    — провести показание счётчика
POST /pg/rpc/post_meter_charge     — провести начисление по счётчику
```

### Прочее
```
POST /pg/rpc/post_period_close     — закрыть период
POST /pg/rpc/cancel_document       — отменить документ ({"p_doc_id": "uuid"})
```

---

## Коды ошибок

| Код | Описание |
|-----|----------|
| `DOCUMENT_NOT_FOUND` | Документ не найден |
| `DOCUMENT_NOT_DRAFT` | Документ не в статусе draft |
| `DOCUMENT_NOT_POSTED` | Документ не проведён |
| `INSUFFICIENT_BALANCE` | Недостаточно средств |
| `INVALID_AMOUNT` | Сумма должна быть > 0 |
| `READING_LESS_THAN_PREVIOUS` | Показание меньше предыдущего |
| `PERIOD_LOCKED` | Период закрыт |
| `CONTRACTOR_NOT_FOUND` | Контрагент не принадлежит организации |
| `INVALID_ROLE` | Недопустимая роль (допустимо: admin, treasurer) |
| `NO_ACTIVE_OBJECTS` | Нет активных объектов для начисления |

Полный список — в `API_CONTRACT.md`.

---

## Health check

```
GET /pg/rpc/health
→ {"ok": true, "ts": "2026-05-11T...", "version": "1.0"}
```

---

## Типовые сценарии

### Принять платёж
```
POST /pg/rpc/create_payment  → получить document_id
POST /pg/rpc/post_payment    → {"p_doc_id": "<id>"}
```

### Начислить взносы всем членам
```
POST /pg/rpc/create_accrual_batch  (p_object_type="member")
POST /pg/rpc/post_accrual
```

### Разнести платёж по долгам
```
POST /pg/rpc/create_distribution  (с массивом p_lines)
POST /pg/rpc/post_distribution
```
