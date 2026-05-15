"""apply sql 011_crud_rpc

Revision ID: 729e2f5b58b0
Revises: 51549866f9f4
Create Date: 2026-05-15 14:29:58.218307

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

from migrations.sql_migration import apply_sql_file


# revision identifiers, used by Alembic.
revision: str = '729e2f5b58b0'
down_revision: Union[str, Sequence[str], None] = '51549866f9f4'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    apply_sql_file(op.get_bind(), "011_crud_rpc.sql")


def downgrade() -> None:
    raise NotImplementedError(
        "Откат 011 вручную: см. функции api.update_* / create_meter в sql/011_crud_rpc.sql"
    )
