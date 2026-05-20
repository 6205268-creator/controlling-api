"""apply_sql_016_autotest_org_seed

Revision ID: c593c50f2f33
Revises: 94dd566012a7
Create Date: 2026-05-20 13:46:35.948542

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from migrations.sql_migration import apply_sql_file


# revision identifiers, used by Alembic.
revision: str = 'c593c50f2f33'
down_revision: Union[str, Sequence[str], None] = '94dd566012a7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    apply_sql_file(op.get_bind(), "016_autotest_org_seed.sql")


def downgrade() -> None:
    raise NotImplementedError("Откат вручную: см. sql/016_autotest_org_seed.sql")
