from sqlalchemy import Boolean, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.database.base import Base


class Event(Base):
    __tablename__ = "event"

    # evt_###
    id: Mapped[str] = mapped_column(
        "event_id",
        String(30),
        primary_key=True
    )
    # 28種
    type: Mapped[str] = mapped_column(
        String(30),
        nullable=False
    )
    # 發生時間
    tick: Mapped[int] = mapped_column(
        Integer,
        nullable=False
    )
    # 誰主動做的
    actor_id: Mapped[str] = mapped_column(
        ForeignKey("npc_identity.id"),
        nullable=False
    )
    # 對誰做
    target_id: Mapped[str | None] = mapped_column(
        ForeignKey("npc_identity.id"),
        nullable=True
    )
    # 地點
    location_id: Mapped[str] = mapped_column(
        String(30),
        nullable=False
    )
    # 涉及金額
    value: Mapped[int | None] = mapped_column(
        Integer,
        nullable=True
    )
    # 是否被看到
    witnessed: Mapped[bool] = mapped_column(
        Boolean,
        default=False
    )