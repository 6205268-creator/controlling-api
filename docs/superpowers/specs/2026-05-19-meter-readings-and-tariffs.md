# Спека: Показания счётчиков + Тарифы

**Дата:** 2026-05-19  
**Статус:** Утверждена  
**Миграция:** 018

---

## Цель

Обеспечить полный цикл: ввод показаний счётчиков → начисление долга по тарифу → отмена при ошибке. Два независимых слоя — показания и начисления — не смешиваются и могут запускаться раздельно (в т.ч. автоматически по регламенту).

---

## Архитектурные решения

### Два слоя, жёсткое разделение

**Слой показаний** — ввод данных (вручную, мобильное приложение, автоматика):
- Не создаёт финансовых движений
- Пишет в регистр `meter_readings` при проведении

**Слой начислений** — бизнес-логика (запускается отдельно, может быть по расписанию):
- Читает регистр `meter_readings` как источник данных
- Создаёт долг в `debt_movements` при проведении
- Не трогает показания

Никакого автоматического создания начисления при проведении показания. Эти слои не знают друг о друге.

### Статусы документов (модель 1С)

`draft` — сохранён, движений нет. `posted` — проведён, движения сделаны. Существует с миграции 001.

### Каскад отмены

Паттерн: тот же что у `unpost_ownership`. При отмене проведения показания — все документы организации с `posted_at >= posted_at отменяемого документа` переходят в `draft`. Дополнительно:
- Для `meter_reading`-документов в каскаде: удаляются записи из регистра `meter_readings`
- Для `meter_charge`-документов в каскаде: удаляются записи из `debt_movements`

Отмена начисления (`unpost_meter_charge`) — точечная: только этот документ + его `debt_movements`. Каскада нет.

### Закрытый период

Если `doc_date <= lock_date` — отмена запрещена (`PERIOD_LOCKED`). Администратор снимает lock_date вручную, исправляет, блокирует снова. Документ `meter_correction` (схема уже есть) — технический долг на будущее.

### Первое показание счётчика

Начислить по одному показанию нельзя — нужно предыдущее. Первое показание вводится как обычный `meter_reading` документ (начальные показания при установке счётчика). Начисление доступно начиная со второго показания.

### Связь счётчик → вид взноса (один источник истины)

Добавляется `meter_type private.meter_type_enum NULL` в `contribution_types`. Для `kind = 'meter'` поле обязательно. Цепочка авто-поиска:

```
meters.meter_type = 'water'
  → contribution_types WHERE org=? AND kind='meter' AND meter_type='water'
  → tariffs WHERE contribution_type_id=? AND valid_from <= charge_date ORDER BY valid_from DESC LIMIT 1
```

Один вид взноса на тип счётчика в организации (MVP). Разные тарифы для разных счётчиков одного типа — технический долг.

---

## Стек

PostgreSQL 16 + PostgREST 14. Язык функций: plpgsql, SECURITY DEFINER. RLS через `private.current_org_id()`.

---

## Карта файлов

| Файл | Действие |
|------|---------|
| `sql/018_meter_readings_and_tariffs.sql` | Новая миграция |
| `API_CONTRACT.md` | Обновить секции meter_reading, meter_charge, tariffs |

---

## Изменения схемы

```sql
-- contribution_types: связь с типом счётчика
ALTER TABLE private.contribution_types
    ADD COLUMN meter_type private.meter_type_enum;

COMMENT ON COLUMN private.contribution_types.meter_type IS
    'Тип счётчика (water/electricity/gas). Обязателен при kind=''meter'', NULL для остальных.';
```

Ограничение целостности: если `kind = 'meter'` то `meter_type IS NOT NULL` — CHECK constraint.

---

## RPC-функции

### Существующие (не меняются)

- `api.create_meter_reading(org_id, meter_id, reading_date, reading_value, notes)` — черновик показания
- `api.post_meter_reading(doc_id)` — проводит показание, пишет в `meter_readings`
- `api.post_meter_charge(doc_id)` — проводит начисление, пишет в `debt_movements`

### Изменённые

**`api.create_meter_charge(p_org_id, p_meter_id, p_doc_date, p_notes DEFAULT NULL)`**

Убираем явные `p_reading_previous`, `p_reading_current`, `p_tariff_rate`, `p_contribution_type_id`. Авто-поиск:

1. `meter_type` ← `meters WHERE id = p_meter_id`
2. `contribution_type_id` ← `contribution_types WHERE organization_id=p_org_id AND kind='meter' AND meter_type=meter_type`
3. Два последних показания из `meter_readings WHERE meter_id=p_meter_id ORDER BY period DESC LIMIT 2`
   - current = первое, previous = второе
   - Если второго нет → ошибка `NO_PREVIOUS_READING`
4. `rate` ← `tariffs WHERE contribution_type_id=? AND valid_from <= p_doc_date ORDER BY valid_from DESC LIMIT 1`
   - Если нет → ошибка `NO_TARIFF_FOR_DATE`
5. `amount = ROUND((current - previous) × rate, 2)`
6. INSERT в `documents` + `doc_meter_charge`

Возврат: `{ok, document_id, status, consumption, amount, reading_current, reading_previous, tariff_rate}`

Ошибки: `NO_METER_CONTRIBUTION_TYPE`, `NO_PREVIOUS_READING`, `NO_TARIFF_FOR_DATE`, `ORG_MISMATCH`, `INVALID_AMOUNT`

### Новые

**`api.unpost_meter_reading(p_doc_id UUID)`**

1. Проверить: документ `meter_reading`, статус `posted`, не в закрытом периоде
2. `v_boundary = documents.posted_at` отменяемого документа
3. Каскад: все `documents WHERE organization_id=org AND status='posted' AND posted_at >= v_boundary` → `draft, posted_at=NULL`
4. Для попавших meter_reading-документов: `DELETE FROM meter_readings WHERE document_id = ANY(cascade_ids)`
5. Для попавших meter_charge-документов: `DELETE FROM debt_movements WHERE document_id = ANY(cascade_ids)`
6. Обновить `doc_ownership` строки если попали ownership-документы (как в `unpost_ownership`)

Возврат: `{ok, doc_id, boundary_posted_at, cascade_documents, meter_readings_removed, debt_movements_removed}`

Ошибки: `DOC_NOT_FOUND`, `NOT_POSTED`, `PERIOD_LOCKED`, `ORG_MISMATCH`

---

**`api.unpost_meter_charge(p_doc_id UUID)`**

1. Проверить: документ `meter_charge`, статус `posted`, не в закрытом периоде
2. `DELETE FROM debt_movements WHERE document_id = p_doc_id`
3. `UPDATE documents SET status='draft', posted_at=NULL WHERE id=p_doc_id`

Возврат: `{ok, doc_id, amount_reversed}`

Ошибки: `DOC_NOT_FOUND`, `NOT_POSTED`, `PERIOD_LOCKED`, `ORG_MISMATCH`

---

**`api.set_tariff(p_org_id UUID, p_contribution_type_id UUID, p_valid_from DATE, p_rate NUMERIC)`**

1. Проверить: `contribution_type` принадлежит org, `kind = 'meter'`
2. Проверить: `p_rate > 0`
3. `INSERT INTO tariffs ... ON CONFLICT (organization_id, contribution_type_id, valid_from) DO UPDATE SET rate = p_rate`

Возврат: `{ok, tariff_id}`

Ошибки: `INVALID_CONTRIBUTION_TYPE`, `NOT_METER_KIND`, `INVALID_RATE`, `ORG_MISMATCH`

---

## Технический долг

1. **Коррекция в закрытом периоде** — `doc_meter_correction` (схема в БД уже есть: old_reading, new_reading, reason). Нужна функция `post_meter_correction` со сторно-логикой. Не в MVP.

2. **FK `doc_meter_charge.reading_document_id`** — прямая ссылка на документ-показание. Нужна для точечного каскада без привязки ко времени. Не в MVP.

3. **Разные тарифы для разных счётчиков одного типа** — сейчас один вид взноса на meter_type в организации. Потребует `contribution_type_id` на уровне `meters`. Не в MVP.

---

## Типовые сценарии

### Ввод показания
```
POST /rpc/create_meter_reading {org_id, meter_id, reading_date, reading_value}
→ {ok, document_id, status:"draft"}

POST /rpc/post_meter_reading {p_doc_id}
→ {ok, document_id}
```

### Начисление по показаниям (отдельная операция / регламент)
```
POST /rpc/create_meter_charge {p_org_id, p_meter_id, p_doc_date}
→ {ok, document_id, consumption, amount, reading_current, reading_previous, tariff_rate}

POST /rpc/post_meter_charge {p_doc_id}
→ {ok, document_id, amount}
```

### Исправление ошибочного показания (открытый период)
```
POST /rpc/unpost_meter_reading {p_doc_id}
→ {ok, cascade_documents:3, meter_readings_removed:1, debt_movements_removed:2}

POST /rpc/create_meter_reading {исправленные данные}
POST /rpc/post_meter_reading
POST /rpc/create_meter_charge  ← если нужно переначислить
POST /rpc/post_meter_charge
```

### Установка тарифа
```
POST /rpc/set_tariff {p_org_id, p_contribution_type_id, p_valid_from:"2026-01-01", p_rate:4.50}
→ {ok, tariff_id}
```
