#!/bin/bash
# Запускается один раз при первом старте контейнера
# PostgreSQL уже инициализирован, но база пустая

set -e

echo "=== Applying CONTROLLING migrations ==="

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
    -- Расширения
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    CREATE EXTENSION IF NOT EXISTS pg_cron;

    -- Роли (могут уже существовать)
    DO \$\$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
            CREATE ROLE anon NOLOGIN;
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
            CREATE ROLE authenticated NOLOGIN;
        END IF;
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_admin') THEN
            CREATE ROLE app_admin NOLOGIN BYPASSRLS;
        END IF;
    END \$\$;

    GRANT anon TO authenticated;
    GRANT authenticated TO app_admin;
    GRANT authenticated TO "$POSTGRES_USER";
    GRANT app_admin TO "$POSTGRES_USER";
SQL

echo "Applying 001_schema.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/001_schema.sql

echo "Applying 002_doc_accrual.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/002_doc_accrual.sql

echo "Applying 003_rpc_functions.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/003_rpc_functions.sql

echo "Applying 004_extended_views.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/004_extended_views.sql

echo "Applying 005_fixes_and_create_distribution.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/005_fixes_and_create_distribution.sql

echo "Applying 006_auth_and_rls.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/006_auth_and_rls.sql

echo "Applying 007_plot_ownerships_admin_seed.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/007_plot_ownerships_admin_seed.sql

echo "Applying 008_cleanup_roles.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/008_cleanup_roles.sql

echo "Applying 009_create_meter_helpers.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/009_create_meter_helpers.sql

echo "Applying 010_ownership_flow.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/010_ownership_flow.sql

echo "Applying 011_crud_rpc.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/011_crud_rpc.sql

echo "Applying 012_ownership_journal_actuality.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/012_ownership_journal_actuality.sql

echo "Applying 013_delete_draft_org_settings.sql..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f /docker-entrypoint-initdb.d/sql/013_delete_draft_org_settings.sql

echo "=== All migrations applied successfully ==="
