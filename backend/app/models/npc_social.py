from sqlalchemy import Boolean, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.common.base_model import BaseModel


class NPCSocial(BaseModel):
    __tablename__ = "npc_social"

    npc_id: Mapped[str] = mapped_column(
        ForeignKey(
            "npc_identity.id",
            ondelete="CASCADE",
        ),
        primary_key=True,
        index=True,
    )

    # 名聲
    reputation: Mapped[int] = mapped_column(
        Integer,
        default=0,
    )

    # 婚姻狀態
    marital_status: Mapped[str] = mapped_column(
        String(20),
        default="single",
    )

    # 配偶
    spouse_id: Mapped[str | None] = mapped_column(
        String(20),
        nullable=True,
    )

    # 檢舉累計
    report_count: Mapped[int] = mapped_column(
        Integer,
        default=0,
    )

    # 服刑到期 Tick
    jail_until_tick: Mapped[int | None] = mapped_column(
        Integer,
        nullable=True,
    )

    # 是否存活
    alive: Mapped[bool] = mapped_column(
        Boolean,
        default=True,
    )
    
#    npc = relationship(
#    "NPCIdentity",
#    back_populates="social",
#)