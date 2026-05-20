"""apply_sql_020_fix_unpost_meter_reading

Revision ID: 8c1c00574ec6
Revises: 06ccfdd0fdc5
Create Date: 2026-05-20 13:46:44.344313

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from migrations.sql_migration import apply_sql_file


# revision identifiers, used by Alembic.
revision: str = '8c1c00574ec6'
down_revision: Union[str, Sequence[str], None] = '06ccfdd0fdc5'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    apply_sql_file(op.get_bind(), "020_fix_unpost_meter_reading.sql")


def downgrade() -> None:
    raise NotImplementedError("Откат вручную: см. sql/020_fix_unpost_meter_reading.sql")
