# Список скриптов и автоматизации

**Проект:** Controlling API  
**Обновлено:** 2026-05-09

> Правило: при создании нового скрипта — добавить в эту таблицу и отправить файл в Telegram.

---

## Скрипты (`/home/roman/bin/`)

| Скрипт | Расположение | Назначение | Автозапуск |
|--------|-------------|-----------|-----------|
| `tg-send` | `/home/roman/bin/tg-send` | Отправить файл в Telegram-бот | ❌ Вручную |
| `tg-msg` | `/home/roman/bin/tg-msg` | Отправить текстовое сообщение в Telegram | ❌ Вручную |
| `pg-backup.sh` | `/home/roman/bin/pg-backup.sh` | Резервная копия БД controlling → `/home/roman/backups/` | ✅ Cron 02:00 ежедневно |
| `pg-morning-report.sh` | `/home/roman/bin/pg-morning-report.sh` | Утренний отчёт в Telegram: статус бэкапа, БД, API | ✅ Cron 08:00 ежедневно |

---

## Хуки Claude Code (`/home/roman/.claude/hooks/`)

| Хук | Файл | Когда срабатывает | Что делает |
|-----|------|------------------|-----------|
| `sql-migration-guard.js` | `/home/roman/.claude/hooks/sql-migration-guard.js` | Перед каждой Bash-командой | Блокирует `psql -f *.sql` — требует одобрения пользователя |
| `caveman-activate.js` | `/home/roman/.claude/hooks/caveman-activate.js` | Старт сессии | Активирует режим «пещерного человека» |
| `caveman-mode-tracker.js` | `/home/roman/.claude/hooks/caveman-mode-tracker.js` | Каждый промпт пользователя | Отслеживает статус caveman-режима |
| `memory-reminder.js` | `/home/roman/.claude/hooks/memory-reminder.js` | Каждый промпт пользователя | Напоминает обновить память сессии |
| `memory-precompact.js` | `/home/roman/.claude/hooks/memory-precompact.js` | Перед компактификацией контекста | Сохраняет важное в память |
| `bash-session-log.js` | `/home/roman/.claude/hooks/bash-session-log.js` | После каждой Bash-команды | Логирует команды сессии |

---

## Расписание cron

```
0 2 * * *   pg-backup.sh          — бэкап базы каждую ночь в 02:00
0 8 * * *   pg-morning-report.sh  — утренний отчёт в Telegram в 08:00
```

---

## Восстановление из бэкапа

```bash
# Найти нужный бэкап
ls -lh /home/roman/backups/

# Восстановить
zcat /home/roman/backups/controlling_ДАТА.sql.gz | sudo -u postgres psql controlling
```

---

## Telegram бот

- **Token:** `8316098940:AAHvzdupJkXTY6rm9LSc6RsjqMGXdg4XDmI`
- **Chat ID:** `286045752`
- Отправить файл: `tg-send /путь/к/файлу "подпись"`
- Отправить текст: `tg-msg "текст сообщения"`
