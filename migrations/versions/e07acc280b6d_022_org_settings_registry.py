"""022_org_settings_registry

Revision ID: e07acc280b6d
Revises: 95d6c8bc2397
Create Date: 2026-05-21 13:37:21.395928

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'e07acc280b6d'
down_revision: Union[str, Sequence[str], None] = '95d6c8bc2397'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.execute("SELECT 1")  # applied manually via sql/022_org_settings_registry.sql


def downgrade() -> None:
    """Downgrade schema."""
    pass
