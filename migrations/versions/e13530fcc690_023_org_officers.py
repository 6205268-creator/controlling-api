"""023_org_officers

Revision ID: e13530fcc690
Revises: e07acc280b6d
Create Date: 2026-05-21 14:29:21.190101

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'e13530fcc690'
down_revision: Union[str, Sequence[str], None] = 'e07acc280b6d'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("SELECT 1")  # applied manually via sql/023_org_officers.sql


def downgrade() -> None:
    """Downgrade schema."""
    pass
