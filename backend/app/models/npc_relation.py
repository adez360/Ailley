from sqlalchemy import ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.common.base_model import BaseModel


class NPCRelation(BaseModel):
    __tablename__ = "npc_relation"

    # 對應限制一筆( A > B 不會有多筆同時存在於資料庫中)
    __table_args__ = (
        UniqueConstraint(
            "npc_id",
            "target_npc_id",
            name="uq_npc_relation"
        ),
    )

    id: Mapped[int] = mapped_column(
        Integer,
        primary_key=True,
        autoincrement=True
    )
    # NPC
    npc_id: Mapped[str] = mapped_column(
        ForeignKey("npc_identity.id"),
        nullable=False
    )
    # 對應NPC
    target_npc_id: Mapped[str] = mapped_column(
        ForeignKey("npc_identity.id"),
        nullable=False
    )
    # 好感
    affinity: Mapped[int] = mapped_column(
        Integer,
        default=0
    )
    # 信任
    trust: Mapped[int] = mapped_column(
        Integer,
        default=20
    )
    # 熟悉
    familiarity: Mapped[int] = mapped_column(
        Integer,
        default=0
    )
    # 虧欠
    debt: Mapped[int] = mapped_column(
        Integer,
        default=0
    )
    
#    npc = relationship(
#    "NPCIdentity",
#    foreign_keys=[npc_id],
#    back_populates="relations",
#)