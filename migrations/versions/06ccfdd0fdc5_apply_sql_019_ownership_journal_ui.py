"""apply_sql_019_ownership_journal_ui

Revision ID: 06ccfdd0fdc5
Revises: 387bca466b3e
Create Date: 2026-05-20 13:46:41.748299

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from migrations.sql_migration import apply_sql_file


# revision identifiers, used by Alembic.
revision: str = '06ccfdd0fdc5'
down_revision: Union[str, Sequence[str], None] = '387bca466b3e'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    apply_sql_file(op.get_bind(), "019_ownership_journal_ui.sql")


def downgrade() -> None:
    raise NotImplementedError("Откат вручную: см. sql/019_ownership_journal_ui.sql")
