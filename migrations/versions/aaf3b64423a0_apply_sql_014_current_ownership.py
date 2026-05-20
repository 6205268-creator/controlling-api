"""apply_sql_014_current_ownership

Revision ID: aaf3b64423a0
Revises: 2dd013c6b839
Create Date: 2026-05-20 13:46:31.590454

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from migrations.sql_migration import apply_sql_file


# revision identifiers, used by Alembic.
revision: str = 'aaf3b64423a0'
down_revision: Union[str, Sequence[str], None] = '2dd013c6b839'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    apply_sql_file(op.get_bind(), "014_current_ownership.sql")


def downgrade() -> None:
    raise NotImplementedError("Откат 014 вручную: см. sql/014_current_ownership.sql")
