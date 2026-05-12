# CONTROLLING — Бэкенд

Система учёта садоводческих товариществ и гаражных кооперативов Республики Беларусь.

## Что это

PostgreSQL + PostgREST. Никакого Python, никакого Node. Только база данных и REST API поверх неё.

**Сервер:** `103.35.190.117`  
**API:** `http://103.35.190.117/pg/`  
**Health check:** `http://103.35.190.117/pg/rpc/health`

## Что умеет

- Учёт организаций (СТ и гаражные кооперативы)
- Учёт участков/боксов, контрагентов, членов, счётчиков
- Платежи: принять деньги → зачислить на лицевой счёт
- Начисления: создать долг по участкам или членам пакетом
- Распределение: разнести деньги с лицевого счёта в погашение долгов
- Показания счётчиков
- Закрытие периода (запрет изменений задним числом)
- Отмена любого документа (сторно — данные не удаляются)
- Отчёты: должники, сводка по участкам, выписка лицевого счёта

## Файлы в этом репозитории

| Файл | Что это |
|------|---------|
| `API_CONTRACT.md` | **Главный документ.** Все endpoints, форматы запросов и ответов, сценарии. Читать фронтенду. |
| `sql/001_schema.sql` | Исходная схема БД: таблицы, триггеры, базовые функции |
| `sql/002_doc_accrual.sql` | Документ начисления взносов |
| `sql/003_rpc_functions.sql` | RPC функции проведения документов |
| `sql/004_extended_views.sql` | Расширенные views для отчётов |
| `sql/005_fixes_and_create_distribution.sql` | Исправления + функция создания распределения |

## Как применить схему на новом сервере

```bash
sudo -u postgres psql -d controlling -f sql/001_schema.sql
sudo -u postgres psql -d controlling -f sql/002_doc_accrual.sql
sudo -u postgres psql -d controlling -f sql/003_rpc_functions.sql
sudo -u postgres psql -d controlling -f sql/004_extended_views.sql
sudo -u postgres psql -d controlling -f sql/005_fixes_and_create_distribution.sql
```

## Финансовая модель (кратко)

Как в 1С, только SQL:

- `debt_movements` — регистр накопления задолженностей. `+` = долг начислен, `−` = долг погашен.
- `account_movements` — регистр лицевых счетов. `+` = деньги поступили, `−` = деньги разнесены.
- Записи **никогда не удаляются и не правятся**. Отмена = новая запись со знаком минус (`is_reversal = true`).
- Триггер автоматически блокирует движения в закрытый период.

## Перечисления (зашитые значения, как в 1С)

| Endpoint | Значения |
|----------|----------|
| `GET /pg/enum_org_types` | gardening, garage |
| `GET /pg/enum_contribution_kinds` | membership, target, meter, additional |
| `GET /pg/enum_meter_types` | water, electricity, gas |
| `GET /pg/enum_genders` | male, female |

## Стек

| Компонент | Версия | Порт |
|-----------|--------|------|
| PostgreSQL | 16 | 5432 |
| PostgREST | 14 | 3100 |
| Nginx | — | 80 |

## Credentials

Лежат на сервере: `/home/roman/controlling-backend/pg-credentials.txt`
