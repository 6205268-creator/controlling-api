"""apply_sql_018_meter_readings_and_tariffs

Revision ID: 387bca466b3e
Revises: 69f1a25f3e33
Create Date: 2026-05-20 13:46:39.948101

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from migrations.sql_migration import apply_sql_file


# revision identifiers, used by Alembic.
revision: str = '387bca466b3e'
down_revision: Union[str, Sequence[str], None] = '69f1a25f3e33'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    apply_sql_file(op.get_bind(), "018_meter_readings_and_tariffs.sql")


def downgrade() -> None:
    raise NotImplementedError("Откат вручную: см. sql/018_meter_readings_and_tariffs.sql")
