"""apply sql 012 ownership_journal

Revision ID: 170ab3a20987
Revises: 729e2f5b58b0
Create Date: 2026-05-15 14:29:58.833459

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from migrations.sql_migration import apply_sql_file


# revision identifiers, used by Alembic.
revision: str = '170ab3a20987'
down_revision: Union[str, Sequence[str], None] = '729e2f5b58b0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    apply_sql_file(op.get_bind(), "012_ownership_journal_actuality.sql")


def downgrade() -> None:
    raise NotImplementedError(
        "Откат 012 только из бэкапа или вручную; см. sql/012_ownership_journal_actuality.sql"
    )
