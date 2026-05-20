"""apply_sql_017_actuality_document

Revision ID: 69f1a25f3e33
Revises: c593c50f2f33
Create Date: 2026-05-20 13:46:37.385719

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from migrations.sql_migration import apply_sql_file


# revision identifiers, used by Alembic.
revision: str = '69f1a25f3e33'
down_revision: Union[str, Sequence[str], None] = 'c593c50f2f33'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    apply_sql_file(op.get_bind(), "017_actuality_document.sql")


def downgrade() -> None:
    raise NotImplementedError("Откат вручную: см. sql/017_actuality_document.sql")
