"""
Запуск sql/*.sql из Alembic через psql.

Тела функций в plpgsql с $$…$$ нельзя надёжно разбить по «;» для op.execute,
поэтому используем тот же механизм, что и ручной деплой: psql -f … -v ON_ERROR_STOP=1.

На типичном сервере объекты в схеме api принадлежат суперпользователю postgres, а не
«пользователю приложения». Тогда CREATE OR REPLACE от имени приложения даст «must be
owner». Решение: перед `alembic upgrade head` задать

    export ALEMBIC_PSQL_AS_USER=postgres

и выполнить команду локально пользователем с правом sudo (см. DEPLOY.md).
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from sqlalchemy.engine import Connection

REPO_ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = REPO_ROOT / "sql"


def apply_sql_file(connection: Connection, sql_filename: str) -> None:
    path = SQL_DIR / sql_filename
    if not path.is_file():
        raise FileNotFoundError(f"SQL migration not found: {path}")

    database = connection.engine.url.database
    if not database:
        raise RuntimeError("Database URL must include a database name")

    sudo_user = os.environ.get("ALEMBIC_PSQL_AS_USER", "").strip()
    psql_bin = os.environ.get("ALEMBIC_PSQL_PATH", "psql")

    env = os.environ.copy()

    if sudo_user:
        sql_text = path.read_text(encoding="utf-8")
        # Файлы в домашнем каталоге недоступны postgres при -f из sudo — подаём SQL на stdin.
        subprocess.run(
            [
                "sudo",
                "-u",
                sudo_user,
                psql_bin,
                "-d",
                database,
                "-v",
                "ON_ERROR_STOP=1",
                "-f",
                "-",
            ],
            input=sql_text,
            text=True,
            check=True,
        )
        return

    url = connection.engine.url
    host = url.host or "localhost"
    port = url.port or 5432
    user = url.username
    if not user:
        raise RuntimeError(
            "Database URL must include a username for psql "
            "(или задайте ALEMBIC_PSQL_AS_USER=postgres)"
        )
    password = url.password
    if password is not None:
        env["PGPASSWORD"] = password

    cmd = [
        psql_bin,
        "-h",
        host,
        "-p",
        str(port),
        "-U",
        user,
        "-d",
        database,
        "-v",
        "ON_ERROR_STOP=1",
        "-f",
        str(path),
    ]
    subprocess.run(cmd, env=env, check=True)
