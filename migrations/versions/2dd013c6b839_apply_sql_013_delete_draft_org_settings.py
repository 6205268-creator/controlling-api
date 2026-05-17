"""apply_sql_013_delete_draft_org_settings

Revision ID: 2dd013c6b839
Revises: 170ab3a20987
Create Date: 2026-05-17 14:18:02.575029

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from migrations.sql_migration import apply_sql_file


# revision identifiers, used by Alembic.
revision: str = '2dd013c6b839'
down_revision: Union[str, Sequence[str], None] = '170ab3a20987'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    apply_sql_file(op.get_bind(), "013_delete_draft_org_settings.sql")


def downgrade() -> None:
    raise NotImplementedError(
        "Откат 013 вручную: см. sql/013_delete_draft_org_settings.sql"
    )
