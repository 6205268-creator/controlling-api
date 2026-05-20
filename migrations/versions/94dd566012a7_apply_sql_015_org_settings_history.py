"""apply_sql_015_org_settings_history

Revision ID: 94dd566012a7
Revises: aaf3b64423a0
Create Date: 2026-05-20 13:46:33.571845

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from migrations.sql_migration import apply_sql_file


# revision identifiers, used by Alembic.
revision: str = '94dd566012a7'
down_revision: Union[str, Sequence[str], None] = 'aaf3b64423a0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    apply_sql_file(op.get_bind(), "015_org_settings_history.sql")


def downgrade() -> None:
    raise NotImplementedError("Откат вручную: см. sql/015_org_settings_history.sql")
