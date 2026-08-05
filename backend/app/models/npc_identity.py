from sqlalchemy import CheckConstraint, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.common.base_model import BaseModel


class NPCIdentity(BaseModel):
    __tablename__ = "npc_identity"

    __table_args__ = (
        CheckConstraint("age >= 0", name="ck_npc_identity_age_positive"),
    )
    # 角色 ID 系統產生
    id: Mapped[str] = mapped_column(
        String(20),
        primary_key=True,
        index=True,
    )
    # 姓名
    name: Mapped[str] = mapped_column(
        String(30),
        unique=True,
        index=True,
        nullable=False,
    )
    # 年齡
    age: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=18,
    )
    # 性別
    gender: Mapped[str] = mapped_column(
        String(10),
        nullable=False,
    )
    # 外型描述
    appearance: Mapped[str] = mapped_column(
        String(100),
        default="",
        nullable=False,
    )
    # 角色特色
    character: Mapped[str] = mapped_column(
        String(255),
        default="",
        nullable=False,
    )

    # ---------- One-to-One ----------
#    hexaco = relationship(
#        "NPCHexaco",
#        back_populates="npc",
#        uselist=False,
#        cascade="all, delete-orphan",
#    )
#
#    personality = relationship(
#        "NPCPersonality",
#        back_populates="npc",
#        uselist=False,
#        cascade="all, delete-orphan",
#    )
#
#    values = relationship(
#        "NPCValues",
#        back_populates="npc",
#        uselist=False,
#        cascade="all, delete-orphan",
#    )
#
#    social = relationship(
#        "NPCSocial",
#        back_populates="npc",
#        uselist=False,
#        cascade="all, delete-orphan",
#    )
#
#    state = relationship(
#        "NPCState",
#        back_populates="npc",
#        uselist=False,
#        cascade="all, delete-orphan",
#    )
#
#    # ---------- One-to-Many ----------
#    relations = relationship(
#        "NPCRelation",
#        foreign_keys="NPCRelation.npc_id",
#        back_populates="npc",
#        cascade="all, delete-orphan",
#    )