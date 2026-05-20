# CONTROLLING — API Contract v1.0

**Backend**: PostgreSQL 16 + PostgREST 14  
**Base URL**: `http://103.35.190.117/pg`  
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
| `autotest_chair` | `autotest123` | admin | СТ «Авто-тест» (чистая, для автотестов) |
| `autotest_treasury` | `autotest123` | treasurer | СТ «Авто-тест» (чистая, для автотестов) |
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
| `ORG_MISMATCH` | Переданный `organization_id` / `p_org_id` не совпадает с организацией JWT (для пользователей с привязкой к оргу; у `superadmin` контекста орга нет — проверка не срабатывает) |
| `DOC_NOT_FOUND` | Указанный идентификатор документа или строки не найдены |
| `NOT_OWNERSHIP` | Переданный `document_id` указывает не на `ownership`-документ |
| `ALREADY_POSTED` | Документ уже проведён |
| `NOT_POSTED` | Операция допустима только для проведённого документа |
| `NOT_DRAFT` | Операция допустима только для черновика |
| `MISSING_POSTED_AT` | У документа отсутствует `posted_at` (несогласованное состояние) |
| `OWNERSHIP_EMPTY` | `post_ownership` — документ не содержит ни одной строки владельцев |
| `INVALID_SHARES` | Передано `shares <= 0` |
| `CONTRACTOR_ALREADY_OWNER` | Контрагент уже присутствует в этом документе владения |
| `MISSING_OBJECT` | У документа не заполнен `object_id` (шапка не содержит объекта) |
| `EMPTY_TYPES` | Передан пустой или NULL массив типов счётчиков в `set_meter_types` |
| `INVALID_METER_TYPE` | Недопустимый тип счётчика (допустимо: water, electricity, gas) |
| `METER_NOT_FOUND` | Счётчик с таким ID не найден в организации |
| `METER_CHARGE_DETAIL_MISSING` | Нет строки `doc_meter_charge` для этого документа |
| `CHARGE_LINE_NOT_FOUND` | Нет строки `doc_meter_charge` для документа |
| `NO_METER_CONTRIBUTION_TYPE` | Нет вида взноса `kind='meter'` для данного типа счётчика |
| `NO_PREVIOUS_READING` | В регистре менее двух показаний — невозможно рассчитать потребление |
| `NO_TARIFF_FOR_DATE` | Нет тарифа для данного вида взноса на указанную дату |
| `NOT_METER_KIND` | Тарифы можно устанавливать только для видов взноса с `kind='meter'` |

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

```
GET /pg/organizations
GET /pg/organizations?id=eq.<uuid>
Authorization: Bearer <token>
```

**Response:**
```json
[{
  "id": "uuid",
  "name": "СТ Дружное",
  "org_type": "gardening",
  "inn": "123456789",
  "is_active": true,
  "actuality_moment": "2026-05-17T13:00:04.232206-04:00",
  "actuality_document_id": "uuid",
  "actuality_doc_date": "2026-05-17"
}]
```

`org_type`: `gardening` | `garage`.  
`actuality_moment` — timestamp последнего проведённого документа владения; `null` если не проводилось.  
`actuality_document_id` — `documents.id` документа, установившего `actuality_moment`; используется для ссылки на документ в UI.  
`actuality_doc_date` — `doc_date` того же документа для отображения даты без дополнительного запроса.  
Все три поля `null` если ни один документ владения не проводился.

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

Для отображения текущего владельца в интерфейсах после миграции **012** ориентируйтесь на **`GET /plot_summary`**, а не на `plots.owner_id` (реестр владения живёт в проведённых документах типа **`ownership`**).

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
  "kind": "membership",   // membership | target | meter | additional
  "meter_type": null,     // water | electricity | gas — обязателен при kind=meter
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

Допустимые значения **`doc_type`** (в том числе для фильтра): `payment`, `distribution`, `meter_reading`, `meter_charge`, `period_close`, `meter_correction`, `accrual`, **`ownership`**.

**Filters useful:**
- `?doc_type=eq.payment`
- `?doc_type=eq.ownership`
- `?status=eq.posted`
- `?doc_date=gte.2025-01-01`

### GET /doc_journal?organization_id=eq.<uuid>&order=doc_date.desc
Журнал документов с суммой и контрагентом. **Рекомендуется для UI.**

**Response:**
```json
[{
  "id": "uuid",
  "organization_id": "uuid",
  "doc_type": "payment",        // payment | accrual | distribution | meter_reading | meter_charge | period_close | meter_correction | ownership
  "doc_date": "2025-03-15",
  "status": "posted",           // draft | posted | cancelled
  "amount": 100.00,             // null для некоторых типов
  "contractor_name": "Иванов Иван, Петров Пётр",  // для ownership — агрегация всех владельцев через ', '
  "period": null,               // для accrual и period_close
  "notes": null,
  "posted_at": "2025-03-15T10:30:00Z",
  "cancelled_at": null,
  "parent_id": null
}]
```

### GET /doc_ownership?document_id=eq.<uuid>
Строка документа владения. Удобно для отображения деталей ownership-документа в UI.

```
GET /pg/doc_ownership?document_id=eq.<uuid>
GET /pg/doc_ownership?id=eq.<own_id>
Authorization: Bearer <token>
```

**Response:**
```json
[{
  "id": "uuid",                          // doc_ownership.id = own_id
  "document_id": "uuid",                 // documents.id
  "organization_id": "uuid",
  "contractor_id": "uuid",
  "contractor_name": "Иванов Иван Иванович",
  "object_type": "plot",
  "object_id": "uuid",
  "doc_date": "2025-03-15",
  "notes": null,
  "status": "draft",                     // draft | posted
  "shares": 1,
  "created_at": "2025-03-15T10:00:00Z"
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

**Семантика владельца (миграция 012):** для каждого участка берётся **последний по времени проведения** документ из журнала `documents`, у которых `doc_type = 'ownership'`, со статусом **`posted`**; к нему джойнятся строки **`private.doc_ownership`** с тем же `document_id` и `object_type = 'plot'`.  
Если в этом документе **ровно один** собственник (одна строка на участок) — в ответ попадают `owner_id`, `owner_phone` и одиночное `owner_name`. Если **совладельцев несколько**, то **`owner_id` = null**, а **`owner_name`** — конкатенация ФИО (порядок по `contractor_id`).

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

### POST /rpc/set_tariff
Установить (или обновить) тариф для вида взноса с `kind = 'meter'`.

**Request:**
```json
{
  "p_org_id": "uuid",
  "p_contribution_type_id": "uuid",
  "p_valid_from": "2026-01-01",
  "p_rate": 4.50
}
```

**Response:**
```json
{"ok": true, "tariff_id": "uuid"}
```

**Ошибки:** `INVALID_CONTRIBUTION_TYPE`, `NOT_METER_KIND`, `INVALID_RATE`, `ORG_MISMATCH`, `INVALID_ORG`, `INVALID_VALID_FROM`

---

### POST /rpc/create_meter_charge
Создать **черновик** начисления по счётчику. Тариф, предыдущее и текущее показания подбираются автоматически из регистра `meter_readings` и таблицы `tariffs` (связь счётчик → вид взноса через `contribution_types.meter_type`).

**Request:**
```json
{
  "p_org_id": "uuid",
  "p_meter_id": "uuid",
  "p_doc_date": "2026-05-01",
  "p_notes": null
}
```

**Response:**
```json
{
  "ok": true,
  "document_id": "uuid",
  "status": "draft",
  "consumption": 15.5,
  "amount": 77.50,
  "reading_current": 115.500,
  "reading_previous": 100.000,
  "tariff_rate": 5.0000
}
```

**Ошибки:** `ORG_MISMATCH`, `NO_METER_CONTRIBUTION_TYPE`, `NO_PREVIOUS_READING`, `NO_TARIFF_FOR_DATE`, `INVALID_AMOUNT`

> Старая сигнатура с явными `p_reading_previous` / `p_tariff_rate` удалена (миграция 018).

---

### POST /rpc/unpost_meter_reading
Отменить проведение показания счётчика **с каскадом**: все проведённые документы организации с `posted_at >= posted_at` отменяемого документа переводятся в `draft`; для них удаляются записи из `meter_readings` и `debt_movements`; для `ownership` сбрасывается `doc_ownership.status`.

**Request:**
```json
{"p_doc_id": "uuid"}
```

**Response:**
```json
{
  "ok": true,
  "doc_id": "uuid",
  "boundary_posted_at": "2026-05-19T10:00:00-04:00",
  "cascade_documents": 2,
  "meter_readings_removed": 1,
  "debt_movements_removed": 1,
  "new_actuality_moment": "2026-05-18T09:00:00Z",       // null если нет оставшихся posted ownership-документов
  "new_actuality_document_id": "uuid"                    // null если нет оставшихся posted ownership-документов
}
```

**Ошибки:** `DOC_NOT_FOUND`, `WRONG_DOC_TYPE`, `NOT_POSTED`, `PERIOD_LOCKED`, `ORG_MISMATCH`, `MISSING_POSTED_AT`

---

### POST /rpc/unpost_meter_charge
Точечная отмена начисления: только этот документ → `draft`, удаляется его движение в `debt_movements`. Каскада нет.

**Request:**
```json
{"p_doc_id": "uuid"}
```

**Response:**
```json
{"ok": true, "doc_id": "uuid", "amount_reversed": 77.50}
```

**Ошибки:** `DOC_NOT_FOUND`, `WRONG_DOC_TYPE`, `NOT_POSTED`, `PERIOD_LOCKED`, `ORG_MISMATCH`, `CHARGE_LINE_NOT_FOUND`

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

### POST /rpc/create_ownership *(migration 021)*
Создать **шапку** черновика документа владения (`documents.doc_type = 'ownership'`). Владельцы добавляются отдельно через `add_ownership_owner`.

**Изоляция:** `p_org_id` должен совпадать с организацией из JWT (у `superadmin` не проверяется).

**Request:**
```json
{
  "p_org_id": "uuid",
  "p_object_id": "uuid",
  "p_object_type": "plot",    // optional, default 'plot'
  "p_doc_date": "2025-03-15", // optional, default CURRENT_DATE
  "p_notes": null,            // optional
  "p_created_by": null        // optional
}
```

**Response:**
```json
{
  "ok": true,
  "document_id": "uuid",
  "status": "draft"
}
```

---

### POST /rpc/add_ownership_owner *(migration 021)*
Добавить владельца в черновик документа владения.

**Request:**
```json
{
  "p_document_id": "uuid",
  "p_contractor_id": "uuid",
  "p_shares": 1               // optional, default 1, должно быть > 0
}
```

**Response:** `{"ok": true, "own_id": "uuid"}`

**Ошибки:** `DOC_NOT_FOUND`, `NOT_OWNERSHIP`, `NOT_DRAFT`, `ORG_MISMATCH`, `INVALID_SHARES`, `MISSING_OBJECT`, `CONTRACTOR_ALREADY_OWNER`

---

### POST /rpc/remove_ownership_owner *(migration 021)*
Удалить строку владельца из черновика. Разрешено оставить 0 строк (пост с 0 строками блокируется). `members.source_doc_id` обнуляется автоматически (ON DELETE SET NULL).

**Request:** `{"p_own_id": "uuid"}`

**Response:** `{"ok": true}`

**Ошибки:** `DOC_NOT_FOUND`, `NOT_DRAFT`, `ORG_MISMATCH`

---

### POST /rpc/update_ownership_owner *(migration 021)*
Изменить контрагента и/или доли строки черновика.

**Request:**
```json
{
  "p_own_id": "uuid",
  "p_contractor_id": "uuid",
  "p_shares": 2
}
```

**Response:** `{"ok": true, "own_id": "uuid"}`

**Ошибки:** `DOC_NOT_FOUND`, `NOT_DRAFT`, `ORG_MISMATCH`, `INVALID_SHARES`, `CONTRACTOR_ALREADY_OWNER`

---

### POST /rpc/post_ownership *(migration 021)*
Провести документ владения: все строки `doc_ownership` документа → `posted`; при необходимости создаёт членов кооператива; двигает `actuality_moment`.

**`p_document_id`** — это `documents.id` (шапка документа, а не `doc_ownership.id`).

**Request:** `{"p_document_id": "uuid"}`

**Response:**
```json
{
  "ok": true,
  "document_id": "uuid",
  "object_type": "plot",
  "object_id": "uuid",
  "owners_posted": 2
}
```

**Ошибки:** `DOC_NOT_FOUND`, `NOT_OWNERSHIP`, `DOCUMENT_NOT_DRAFT`, `OWNERSHIP_EMPTY`, `PERIOD_LOCKED`, `ORG_MISMATCH`

---

### POST /rpc/unpost_ownership *(migration 021)*
Отменить проведение документа владения по `p_document_id = documents.id`.

**Request:** `{"p_document_id": "uuid"}`

**Каскад по организации:** все документы со статусом `posted` и `posted_at >= posted_at` целевого → `draft`; связанные строки `doc_ownership` → `draft`; `actuality_moment` и `actuality_document_id` пересчитываются по последнему оставшемуся проведённому ownership-документу.

**⚠️ Важно:** движения в `account_movements` и `debt_movements` **не сторнируются** автоматически.

**Response:**
```json
{
  "ok": true,
  "document_id": "uuid",
  "boundary_posted_at": "2025-03-15T10:30:00.123456+00:00",
  "cascade_documents": 3,
  "doc_ownership_rows_reset": 4
}
```

**Ошибки:** `DOC_NOT_FOUND`, `NOT_OWNERSHIP`, `NOT_POSTED`, `MISSING_POSTED_AT`, `PERIOD_LOCKED`, `ORG_MISMATCH`

---

### POST /rpc/update_ownership *(migration 021)*
Редактировать **шапку** черновика: дата, примечания, объект. Строки владельцев управляются отдельными RPC (`add/remove/update_ownership_owner`). При изменении `p_doc_date` синхронизирует дату во всех строках `doc_ownership`.

**`p_document_id`** — это `documents.id`.

**Request:**
```json
{
  "p_document_id": "uuid",
  "p_doc_date": "2025-03-15",  // optional, null = не менять
  "p_notes": "комментарий",    // optional, null = не менять
  "p_object_id": "uuid",       // optional, null = не менять
  "p_object_type": "plot"      // optional, null = не менять
}
```

**Response:** `{"ok": true, "document_id": "uuid", "status": "draft"}`

**Ошибки:** `DOC_NOT_FOUND`, `NOT_OWNERSHIP`, `NOT_DRAFT`, `ORG_MISMATCH`

---

### Справочники: RPC-обновление (миграция 011)

Вспомогательные вызовы с именами параметров, совпадающими с SQL.

#### POST /rpc/update_plot
```json
{
  "p_org_id": "uuid",
  "p_plot_id": "uuid",
  "p_number": "42",
  "p_area": 6.00,
  "p_is_active": true
}
```
**Response:** `{"ok": true, "plot_id": "uuid"}`

#### POST /rpc/create_meter
```json
{
  "p_org_id": "uuid",
  "p_plot_id": "uuid",
  "p_meter_type": "water",
  "p_serial_number": "A123456"
}
```
`p_meter_type`: `water` | `electricity` | `gas`.  
**Response:** `{"ok": true, "meter_id": "uuid"}`

#### POST /rpc/update_meter
```json
{
  "p_org_id": "uuid",
  "p_meter_id": "uuid",
  "p_meter_type": "water",
  "p_serial_number": "A123456",
  "p_is_active": true
}
```
**Response:** `{"ok": true, "meter_id": "uuid"}`

#### POST /rpc/update_contractor
```json
{
  "p_org_id": "uuid",
  "p_contractor_id": "uuid",
  "p_full_name": "Иванов Иван Иванович",
  "p_contractor_type": "individual",
  "p_phone": "+375...",
  "p_email": null
}
```
`p_contractor_type`: `individual` | `legal_entity`. Телефон и email опциональны (`NULL` по умолчанию в сигнатуре).  
**Response:** `{"ok": true, "contractor_id": "uuid"}`

---

### POST /rpc/delete_draft
Удалить черновик документа любого типа.

**Request:** `{ "p_doc_id": "uuid" }`

**Response:**
- `{"ok": true}` — удалён
- `{"ok": false, "error": "NOT_FOUND"}` — документ не найден
- `{"ok": false, "error": "NOT_DRAFT"}` — документ не в статусе draft
- `{"ok": false, "error": "ORG_MISMATCH"}` — чужая организация

Для `doc_type = 'ownership'` автоматически удаляет связанные строки `doc_ownership` (FK NO ACTION).

---

---

## Настройки организации

Учётная политика — параметры ведения учёта для каждой организации.  
Хранятся в `private.org_settings` (lock_date, current_period) и `private.org_settings_history` (типы счётчиков и будущие настройки с историей).

### GET /org_settings
Текущие настройки организации.

```
GET /pg/org_settings?organization_id=eq.<uuid>
Authorization: Bearer <token>
```

**Response:**
```json
[{
  "organization_id": "uuid",
  "lock_date": "2025-12-31",
  "current_period": "2026-01-01",
  "enabled_meter_types": ["water", "electricity", "gas"]
}]
```

| Поле | Описание | Null? |
|------|----------|-------|
| `lock_date` | Дата запрета изменений — документы с `doc_date <= lock_date` нельзя провести | да |
| `current_period` | Рабочий период (UI-ориентир, не блокирует) | да |
| `enabled_meter_types` | Типы счётчиков, активных в учёте | нет (дефолт `["water","electricity","gas"]`) |

Допустимые значения `enabled_meter_types`: `water`, `electricity`, `gas`.

### POST /rpc/set_meter_types
Установить активные типы счётчиков для организации.

```
POST /pg/rpc/set_meter_types
Authorization: Bearer <token>
Content-Type: application/json
```

**Request:**
```json
{ "p_org_id": "uuid", "p_types": ["water", "electricity"] }
```

**Response:** `{"ok": true}`

**Ошибки:** `EMPTY_TYPES`, `INVALID_METER_TYPE: <значение>`, `ORG_MISMATCH`.

Изменение сохраняется в историю с датой `CURRENT_DATE`. Дефолт (все три типа) применяется до первого вызова.

### POST /rpc/set_lock_date
Установить дату запрета изменений.

```
POST /pg/rpc/set_lock_date
Authorization: Bearer <token>
Content-Type: application/json
```

**Request:**
```json
{ "p_org_id": "uuid", "p_lock_date": "2025-12-31" }
```
`p_lock_date: null` — снять блокировку.

**Response:** `{"ok": true}`

### POST /rpc/set_current_period
Установить рабочий период (UI-настройка, не блокирует документы).

```
POST /pg/rpc/set_current_period
Authorization: Bearer <token>
Content-Type: application/json
```

**Request:**
```json
{ "p_org_id": "uuid", "p_period": "2026-01-01" }
```

**Response:** `{"ok": true}`

---

## Владение объектами

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
1. POST /rpc/create_meter_reading {p_org_id, p_meter_id, p_reading_date, p_reading_value}
2. POST /rpc/post_meter_reading {p_doc_id}
3. GET /meter_readings_view  ← новое показание в регистре
```

### Сценарий 4б: Начислить по счётчику (отдельно от ввода показаний)
```
1. POST /rpc/set_tariff  ← при смене тарифа
2. POST /rpc/create_meter_charge {p_org_id, p_meter_id, p_doc_date}
3. POST /rpc/post_meter_charge {p_doc_id}
4. GET /debtors  ← долг владельца счётчика
```

Исправление ошибочного показания (открытый период): `POST /rpc/unpost_meter_reading` → каскад → ввести показание заново → при необходимости пересоздать начисление.

### Сценарий 5: Закрыть период
```
1. POST /documents + POST /doc_period_close (прямой INSERT)
2. POST /rpc/post_period_close
3. Теперь движения за закрытый период будут отклонены с ошибкой PERIOD_LOCKED
```

### Сценарий 6: Оформить владение участком (migration 021)
```
1. POST /rpc/create_ownership    {p_org_id, p_object_id, p_doc_date}
   → {"ok": true, "document_id": "D1"}

2. POST /rpc/add_ownership_owner {p_document_id: "D1", p_contractor_id: "Ivanov", p_shares: 1}
   → {"ok": true, "own_id": "O1"}

3. POST /rpc/add_ownership_owner {p_document_id: "D1", p_contractor_id: "Petrov", p_shares: 2}
   → {"ok": true, "own_id": "O2"}

4. POST /rpc/post_ownership      {p_document_id: "D1"}
   → {"ok": true, "owners_posted": 2}

5. GET /plot_summary ← owner_name: "Иванов Иван, Петров Пётр"
```

Отмена: `POST /rpc/unpost_ownership {"p_document_id": "D1"}` — каскад по времени, движения не сторнируются.

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
{"organization_id": "uuid", "number": "42", "area": 6.0}
```
При необходимости `owner_id` в справочнике — отдельная политика данных; **канонический текущий владелец после 012** задаётся документами **`ownership`** (`create_ownership` / `post_ownership`) и отражается в **`plot_summary`**.

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

*Версия: 1.0 | Дата: 2026-05-20 | Backend: PostgreSQL 16 + PostgREST 14.11. Миграции 001–020 применены. Документы владения и `actuality_moment`: миграции 012, 017. Показания счётчиков и тарифы: миграция 018. UI-журнал владения: миграция 019.*
