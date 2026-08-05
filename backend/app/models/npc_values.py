from sqlalchemy import CheckConstraint, ForeignKey, Integer
from sqlalchemy.orm import Mapped, mapped_column

from app.common.base_model import BaseModel


class NPCValues(BaseModel):
    __tablename__ = "npc_values"

    __table_args__ = (
        CheckConstraint(
            "wealth BETWEEN 0 AND 100",
            name="ck_values_wealth",
        ),
        CheckConstraint(
            "reputation BETWEEN 0 AND 100",
            name="ck_values_reputation",
        ),
        CheckConstraint(
            "safety BETWEEN 0 AND 100",
            name="ck_values_safety",
        ),
        CheckConstraint(
            "intimacy BETWEEN 0 AND 100",
            name="ck_values_intimacy",
        ),
        CheckConstraint(
            "justice BETWEEN 0 AND 100",
            name="ck_values_justice",
        ),
        CheckConstraint(
            "freedom BETWEEN 0 AND 100",
            name="ck_values_freedom",
        ),
        CheckConstraint(
            "order_tradition BETWEEN 0 AND 100",
            name="ck_values_order_tradition",
        ),
        CheckConstraint(
            "pleasure BETWEEN 0 AND 100",
            name="ck_values_pleasure",
        ),
    )

    npc_id: Mapped[str] = mapped_column(
        ForeignKey(
            "npc_identity.id",
            ondelete="CASCADE",
        ),
        primary_key=True,
        index=True,
    )

    # 財富
    wealth: Mapped[int] = mapped_column(
        Integer,
        default=25,
    )

    # 名譽
    reputation: Mapped[int] = mapped_column(
        Integer,
        default=25,
    )

    # 人身安全
    safety: Mapped[int] = mapped_column(
        Integer,
        default=25,
    )

    # 親密關係
    intimacy: Mapped[int] = mapped_column(
        Integer,
        default=25,
    )

    # 公平正義
    justice: Mapped[int] = mapped_column(
        Integer,
        default=25,
    )

    # 自由
    freedom: Mapped[int] = mapped_column(
        Integer,
        default=25,
    )

    # 秩序／傳統
    order_tradition: Mapped[int] = mapped_column(
        Integer,
        default=25,
    )

    # 享樂
    pleasure: Mapped[int] = mapped_column(
        Integer,
        default=25,
    )