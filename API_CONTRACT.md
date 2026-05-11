# CONTROLLING — API Contract v1.0

**Backend**: PostgreSQL 16 + PostgREST 14  
**Base URL**: `http://103.35.190.117/pg` (через Nginx)  
> ⚠️ Домен `brachiumartur.com` не в публичном DNS. Использовать только IP.  
**Content-Type**: `application/json`  
**Auth**: `Authorization: Bearer <JWT>` — обязателен для всех endpoints кроме `/rpc/login` и enum-справочников  
**Валюта**: только BYN (Decimal с 2 знаками)

---

## Авторизация

### Получить токен
```
POST /pg/rpc/login
```
**Тело:**
```json
{"p_login": "admin", "p_password": "admin123"}
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

**Использование токена** — во всех последующих запросах:
```
Authorization: Bearer eyJhbGci...
```

**Токен живёт 8 часов.** После истечения повторить логин.

### Кто я
```
POST /pg/rpc/me
Authorization: Bearer <token>
```
Возвращает: `user_id`, `login`, `full_name`, `role`, `organization_id`.

### Создать пользователя (только admin)
```
POST /pg/rpc/create_user
Authorization: Bearer <token>
```
```json
{
  "p_login": "treasurer1",
  "p_password": "pass123",
  "p_full_name": "Петров Иван",
  "p_role": "treasurer"
}
```
Допустимые значения `p_role`: `admin`, `treasurer`.  
При других значениях — ошибка `INVALID_ROLE`.  
Пользователь создаётся в организации того, кто создаёт (другую организацию задать нельзя).

### Изоляция данных

Каждый пользователь привязан к одной организации. PostgreSQL RLS (Row Level Security) гарантирует: **любой запрос автоматически фильтруется по `organization_id` из токена**. Увидеть данные другой организации невозможно даже при ошибке фронтенда.

Без токена все защищённые endpoints возвращают `42501 permission denied`.

### Роли пользователей

Канонический набор `user_role` — три значения:

| Роль | `user_role` в токене | Что может |
|------|---------------------|-----------|
| Суперадминистратор | `superadmin` | Видит все организации; фильтрует через `?organization_id=eq.<uuid>`; создаётся только вручную в БД |
| Председатель | `admin` | Полный доступ к своей организации; может создавать пользователей |
| Казначей | `treasurer` | Финансовые операции своей организации |

> Роли `board`, `member`, `background` **удалены** (миграция 008). Если фронт получает такое значение — это устаревшие данные.

### Тестовые пользователи (демо-данные)

| Логин | Пароль | Роль | Организация |
|-------|--------|------|-------------|
| `demo_a_chair` | `chair123` | admin | СТ «Демо-А» |
| `demo_a_treasury` | `treasury123` | treasurer | СТ «Демо-А» |
| `demo_b_chair` | `chair123` | admin | СТ «Демо-Б» |
| `demo_b_treasury` | `treasury123` | treasurer | СТ «Демо-Б» |
| `superadmin` | `super123` | superadmin | все организации |

> `admin` / `admin123` (организация-заглушка UUID 1111...) — удалить перед продакшном.

### Суперадмин: работа с конкретной организацией

Суперадмин видит все данные. Для фильтрации по организации фронтенд добавляет параметр:
```
GET /pg/plots?organization_id=eq.<uuid>
Authorization: Bearer <superadmin_token>
```
Список организаций для выбора:
```
GET /pg/organizations
Authorization: Bearer <superadmin_token>
```

---

## Формат ответов

### Успех (GET — массив объектов)
```json
[{"id": "uuid", ...}, ...]
```

### Успех (RPC — бизнес-операция)
```json
{"ok": true, "document_id": "uuid", ...}
```

### Ошибка (RPC)
```json
{"ok": false, "error": "ERROR_CODE: описание"}
```

### PostgREST фильтры (GET запросы)
```
?organization_id=eq.<uuid>          — точное совпадение
?total_debt=gt.0                    — больше нуля
?order=doc_date.desc                — сортировка
?limit=50&offset=0                  — пагинация
?select=id,name,owner_name          — выбор полей
```

---

## Коды ошибок RPC

| Код | Описание |
|-----|----------|
| `DOCUMENT_NOT_FOUND` | Документ с таким ID не найден |
| `DOCUMENT_NOT_DRAFT` | Документ не в статусе draft (уже проведён/отменён) |
| `DOCUMENT_NOT_POSTED` | Нельзя отменить — документ не проведён |
| `WRONG_DOC_TYPE` | Функция вызвана для документа неправильного типа |
| `PAYMENT_DETAIL_MISSING` | Нет строки в doc_payment для этого документа |
| `ACCRUAL_HEADER_MISSING` | Нет строки в doc_accrual |
| `ACCRUAL_NO_LINES` | Документ начисления без строк |
| `DISTRIBUTION_HEADER_MISSING` | Нет строки в doc_distribution |
| `DISTRIBUTION_NO_LINES` | Документ распределения без строк |
| `DISTRIBUTION_EMPTY` | Сумма строк = 0 |
| `INSUFFICIENT_BALANCE` | Недостаточно средств на лицевом счёте |
| `NO_ACTIVE_OBJECTS` | Нет активных объектов (участков/членов) для пакетного начисления |
| `INVALID_AMOUNT` | Сумма должна быть > 0 |
| `INVALID_LINE_AMOUNT` | Сумма строки должна быть > 0 |
| `READING_LESS_THAN_PREVIOUS` | Показание меньше предыдущего |
| `READING_GREATER_THAN_FUTURE` | Показание больше последующего |
| `READING_ALREADY_POSTED` | На этот период уже есть проведённое показание |
| `PERIOD_LOCKED` | Период закрыт — движения задним числом запрещены |
| `INVALID_CLOSING_PERIOD` | Дата закрытия вне допустимого диапазона |
| `CONTRACTOR_NOT_FOUND` | Контрагент не принадлежит организации |
| `INVALID_OBJECT_TYPE` | Неверный тип объекта (допустимо: plot/member/meter) |
| `INVALID_ROLE` | Недопустимая роль пользователя (допустимо: admin, treasurer) |

---

## Health check

### GET /rpc/health
Проверка живости бэкенда.

```json
{"ok": true, "ts": "2026-05-07T12:29:38Z", "version": "1.0"}
```

---

## Справочники (CRUD через PostgREST)

### GET /organizations
Список организаций (тенантов).

**Response:**
```json
[{
  "id": "uuid",
  "name": "СТ Дружное",
  "org_type": "gardening",   // gardening | garage
  "inn": "123456789",
  "is_active": true
}]
```

### GET /contractors?organization_id=eq.<uuid>
Список контрагентов (физлица-плательщики).

**Response:**
```json
[{
  "id": "uuid",
  "organization_id": "uuid",
  "full_name": "Иванов Иван Иванович",
  "phone": "+375291234567",
  "email": "ivanov@example.com",
  "is_active": true
}]
```

### GET /members?organization_id=eq.<uuid>
Члены кооператива.

**Response:**
```json
[{
  "id": "uuid",
  "organization_id": "uuid",
  "contractor_id": "uuid",
  "member_number": "42",
  "joined_at": "2020-01-01",
  "is_active": true
}]
```

### GET /plots?organization_id=eq.<uuid>
Участки / гаражные боксы.

**Response:**
```json
[{
  "id": "uuid",
  "organization_id": "uuid",
  "number": "42",
  "area": 6.00,
  "owner_id": "uuid",
  "is_active": true
}]
```

### GET /meters?organization_id=eq.<uuid>
Счётчики (вода, электричество).

**Response:**
```json
[{
  "id": "uuid",
  "organization_id": "uuid",
  "plot_id": "uuid",
  "meter_type": "water",
  "serial_number": "A123456",
  "is_active": true
}]
```

### GET /contribution_types?organization_id=eq.<uuid>
Виды взносов.

**Response:**
```json
[{
  "id": "uuid",
  "organization_id": "uuid",
  "name": "Членский взнос",
  "kind": "membership",   // membership | target | meter
  "is_active": true
}]
```

### GET /tariffs?organization_id=eq.<uuid>
Тарифы (с историей).

**Response:**
```json
[{
  "id": "uuid",
  "organization_id": "uuid",
  "contribution_type_id": "uuid",
  "contribution_type_name": "По счётчику воды",
  "valid_from": "2025-01-01",
  "rate": 2.5000
}]
```

---

## Документы

### GET /documents?organization_id=eq.<uuid>
Журнал документов (сырой, без деталей).

**Filters useful:**
- `?doc_type=eq.payment`
- `?status=eq.posted`
- `?doc_date=gte.2025-01-01`

### GET /doc_journal?organization_id=eq.<uuid>&order=doc_date.desc
Журнал документов с суммой и контрагентом. **Рекомендуется для UI.**

**Response:**
```json
[{
  "id": "uuid",
  "organization_id": "uuid",
  "doc_type": "payment",        // payment | accrual | distribution | meter_reading | meter_charge | period_close | meter_correction
  "doc_date": "2025-03-15",
  "status": "posted",           // draft | posted | cancelled
  "amount": 100.00,             // null для некоторых типов
  "contractor_name": "Иванов Иван Иванович",
  "period": null,               // для accrual и period_close
  "notes": null,
  "posted_at": "2025-03-15T10:30:00Z",
  "cancelled_at": null
}]
```

---

## Финансовые отчёты

### GET /account_balances?organization_id=eq.<uuid>
Остатки лицевых счетов по контрагентам.

```json
[{
  "organization_id": "uuid",
  "contractor_id": "uuid",
  "balance": 50.00    // положительный = деньги есть, отрицательный = долг
}]
```

### GET /object_debts?organization_id=eq.<uuid>
Долги по финансовым объектам (только ненулевые).

```json
[{
  "organization_id": "uuid",
  "object_type": "plot",       // plot | member | meter
  "object_id": "uuid",
  "total_debt": 50.00          // положительный = долг
}]
```

### GET /debtors?organization_id=eq.<uuid>&order=total_debt.desc
Список должников с именем объекта и владельца.

```json
[{
  "organization_id": "uuid",
  "object_type": "plot",
  "object_id": "uuid",
  "total_debt": 150.00,
  "object_name": "42",                      // номер участка
  "owner_name": "Иванов Иван Иванович"
}]
```

### GET /plot_summary?organization_id=eq.<uuid>
Сводка по участкам: владелец + долг. **Основной отчёт казначея.**

```json
[{
  "id": "uuid",
  "organization_id": "uuid",
  "number": "42",
  "area": 6.00,
  "is_active": true,
  "owner_id": "uuid",
  "owner_name": "Иванов Иван Иванович",
  "owner_phone": "+375291234567",
  "total_debt": 150.00
}]
```

### GET /account_statement?organization_id=eq.<uuid>&contractor_id=eq.<uuid>
Выписка по лицевому счёту контрагента.

```json
[{
  "id": "uuid",
  "contractor_id": "uuid",
  "contractor_name": "Иванов Иван Иванович",
  "document_id": "uuid",
  "document_type": "payment",
  "amount": 100.00,           // + = поступление, - = списание
  "period": "2025-03-15",
  "is_reversal": false,
  "created_at": "2025-03-15T10:30:00Z"
}]
```

### GET /debt_movements_detail?organization_id=eq.<uuid>&object_id=eq.<uuid>
История задолженностей по объекту.

```json
[{
  "id": "uuid",
  "document_type": "accrual",
  "doc_date": "2025-01-01",
  "object_type": "plot",
  "object_id": "uuid",
  "contribution_type_name": "Членский взнос",
  "amount": 50.00,           // + = начислен долг, - = погашен
  "period": "2025-01-01",
  "is_reversal": false
}]
```

### GET /meter_readings_view?organization_id=eq.<uuid>&meter_id=eq.<uuid>
История показаний счётчика.

```json
[{
  "meter_id": "uuid",
  "meter_type": "water",
  "serial_number": "A123456",
  "period": "2025-03-01",
  "reading": 1234.567
}]
```

---

## Бизнес-операции (RPC)

> Все RPC — POST запросы. Тело — JSON объект с именованными параметрами.

### POST /rpc/create_payment
Создать черновик платежа.

**Request:**
```json
{
  "p_org_id": "uuid",
  "p_contractor_id": "uuid",
  "p_amount": 100.00,
  "p_doc_date": "2025-03-15",   // optional, default CURRENT_DATE
  "p_payment_ref": "ЕРИП 12345", // optional
  "p_notes": "комментарий"       // optional
}
```

**Response:**
```json
{"ok": true, "document_id": "uuid", "status": "draft"}
```

---

### POST /rpc/post_payment
Провести платёж → зачислить на лицевой счёт.

**Request:**
```json
{"p_doc_id": "uuid"}
```

**Response:**
```json
{"ok": true, "document_id": "uuid"}
```

---

### POST /rpc/create_accrual_batch
Создать пакетное начисление для всех активных объектов.

**Request:**
```json
{
  "p_org_id": "uuid",
  "p_contribution_type": "uuid",
  "p_period": "2025-01-01",
  "p_object_type": "plot",       // plot | member | meter
  "p_amount_per_object": 50.00
}
```

**Response:**
```json
{"ok": true, "document_id": "uuid", "lines_created": 12, "status": "draft"}
```

---

### POST /rpc/post_accrual
Провести начисление взносов → создать долги.

**Request:**
```json
{"p_doc_id": "uuid"}
```

**Response:**
```json
{"ok": true, "document_id": "uuid", "lines_posted": 12}
```

---

### POST /rpc/create_distribution
Создать распределение платежа по долгам.

**Request:**
```json
{
  "p_org_id": "uuid",
  "p_contractor_id": "uuid",
  "p_doc_date": "2025-03-15",   // optional
  "p_lines": [
    {
      "object_type": "plot",
      "object_id": "uuid",
      "contribution_type_id": "uuid",
      "amount": 50.00
    }
  ]
}
```

**Response:**
```json
{
  "ok": true,
  "document_id": "uuid",
  "lines_created": 1,
  "total_to_distribute": 50.00,
  "account_balance_before": 100.00,
  "status": "draft"
}
```

---

### POST /rpc/post_distribution
Провести распределение → погасить долги, списать с лицевого счёта.

**Request:**
```json
{"p_doc_id": "uuid"}
```

**Response:**
```json
{"ok": true, "document_id": "uuid", "lines_posted": 1, "total_distributed": 50.00}
```

---

### POST /rpc/post_meter_reading
Провести показание счётчика.

**Предварительно**: создать документ `meter_reading` с `doc_meter_reading` строкой через прямой INSERT в `documents` + `doc_meter_reading`.

**Request:**
```json
{"p_doc_id": "uuid"}
```

**Response:**
```json
{"ok": true, "document_id": "uuid"}
```

---

### POST /rpc/post_meter_charge
Провести начисление по счётчику → создать долг.

**Request:**
```json
{"p_doc_id": "uuid"}
```

**Response:**
```json
{"ok": true, "document_id": "uuid", "amount": 75.50}
```

---

### POST /rpc/post_period_close
Закрыть период (запретить изменения задним числом).

**Request:**
```json
{"p_doc_id": "uuid"}
```

**Response:**
```json
{"ok": true, "document_id": "uuid", "locked_until": "2025-12-31"}
```

---

### POST /rpc/cancel_document
Отменить проведённый документ (создаёт сторно-записи).

**Request:**
```json
{"p_doc_id": "uuid"}
```

**Response:**
```json
{"ok": true, "document_id": "uuid", "cancelled_doc_type": "payment"}
```

---

## Типовые сценарии

### Сценарий 1: Принять платёж
```
1. POST /rpc/create_payment
2. POST /rpc/post_payment
3. GET /account_balances?contractor_id=eq.<uuid>  ← проверить баланс
```

### Сценарий 2: Начислить членские взносы
```
1. POST /rpc/create_accrual_batch (p_object_type="member")
2. Показать черновик фронтенду → GET /doc_journal?id=eq.<uuid>
3. POST /rpc/post_accrual
4. GET /debtors  ← список должников обновился
```

### Сценарий 3: Разнести платёж по долгам
```
1. POST /rpc/create_distribution (с p_lines по долгам контрагента)
2. POST /rpc/post_distribution
3. GET /plot_summary  ← долги уменьшились
```

### Сценарий 4: Ввести показания счётчика
```
1. POST /documents + POST /doc_meter_reading (прямой INSERT)
2. POST /rpc/post_meter_reading
3. GET /meter_readings_view  ← новое показание
```

### Сценарий 5: Закрыть период
```
1. POST /documents + POST /doc_period_close (прямой INSERT)
2. POST /rpc/post_period_close
3. Теперь движения за закрытый период будут отклонены с ошибкой PERIOD_LOCKED
```

---

## Прямые INSERT через PostgREST

Для создания записей справочников и некоторых документов используйте прямые запросы.

### Создать организацию
```
POST /organizations
{"name": "СТ Дружное", "org_type": "gardening"}
```

### Создать контрагента
```
POST /contractors
{"organization_id": "uuid", "full_name": "Иванов И.И.", "phone": "+375..."}
```

### Создать участок
```
POST /plots
{"organization_id": "uuid", "number": "42", "area": 6.0, "owner_id": "uuid"}
```

### Создать документ ПоказаниеСчётчика + детали
```
POST /documents
{"organization_id":"uuid","doc_type":"meter_reading","doc_date":"2025-03-15","status":"draft"}
→ Получить id документа из ответа (заголовок Location или тело)

POST /doc_meter_reading
{"document_id":"<id>","meter_id":"uuid","reading_date":"2025-03-15","reading_value":1234.567}
```

---

## Технические примечания

1. **UUID**: везде используется UUID v4. При INSERT генерируется автоматически (`gen_random_uuid()`).
2. **Даты**: формат `YYYY-MM-DD` (ISO 8601).
3. **Суммы**: Decimal с 2 знаками (`100.00`), тарифы — с 4 знаками (`2.5000`).
4. **Мультитенантность**: каждый запрос фильтруется по `organization_id` — фронтенд ВСЕГДА передаёт его.
5. **Предпочитаемые GET для списков**: `?limit=100&offset=0&order=created_at.desc`
6. **Заголовок предпочтения** для подсчёта: `Prefer: count=exact` → ответ содержит `Content-Range: 0-99/245`.

---

*Версия: 1.0 | Дата: 2026-05-07 | Backend: PostgreSQL 16 + PostgREST 14.11*
