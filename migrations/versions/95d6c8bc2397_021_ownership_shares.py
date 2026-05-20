"""021_ownership_shares

Revision ID: 95d6c8bc2397
Revises: 8c1c00574ec6
Create Date: 2026-05-20 14:25:02.367534

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '95d6c8bc2397'
down_revision: Union[str, Sequence[str], None] = '8c1c00574ec6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("SELECT 1")  # applied manually via sql/021_ownership_shares.sql


def downgrade() -> None:
    pass
