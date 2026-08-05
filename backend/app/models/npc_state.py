from sqlalchemy import CheckConstraint, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.common.base_model import BaseModel


class NPCState(BaseModel):
    __tablename__ = "npc_state"

    __table_args__ = (
        CheckConstraint("hunger BETWEEN 0 AND 100", name="ck_state_hunger"),
        CheckConstraint("thirst BETWEEN 0 AND 100", name="ck_state_thirst"),
        CheckConstraint("stamina BETWEEN 0 AND 100", name="ck_state_stamina"),
        CheckConstraint("sleepiness BETWEEN 0 AND 100", name="ck_state_sleepiness"),
        CheckConstraint("hygiene BETWEEN 0 AND 100", name="ck_state_hygiene"),
        CheckConstraint("alcohol BETWEEN 0 AND 100", name="ck_state_alcohol"),
        CheckConstraint("health BETWEEN 0 AND 100", name="ck_state_health"),
        CheckConstraint("injury BETWEEN 0 AND 100", name="ck_state_injury"),
        CheckConstraint("stress BETWEEN 0 AND 100", name="ck_state_stress"),
        CheckConstraint("loneliness BETWEEN 0 AND 100", name="ck_state_loneliness"),
        CheckConstraint("satisfaction BETWEEN 0 AND 100", name="ck_state_satisfaction"),
        CheckConstraint("emotion_intensity BETWEEN 0 AND 100", name="ck_state_emotion_intensity"),
    )

    npc_id: Mapped[str] = mapped_column(
        ForeignKey(
            "npc_identity.id",
            ondelete="CASCADE",
        ),
        primary_key=True,
        index=True,
    )

    # 6-1 Physical 生理
    hunger: Mapped[int] = mapped_column(Integer, default=20)
    thirst: Mapped[int] = mapped_column(Integer, default=20)
    stamina: Mapped[int] = mapped_column(Integer, default=80)
    sleepiness: Mapped[int] = mapped_column(Integer, default=10)
    hygiene: Mapped[int] = mapped_column(Integer, default=70)
    alcohol: Mapped[int] = mapped_column(Integer, default=0)
    health: Mapped[int] = mapped_column(Integer, default=100)
    injury: Mapped[int] = mapped_column(Integer, default=0)

    # 6-2 Mental 心理
    stress: Mapped[int] = mapped_column(Integer, default=20)
    loneliness: Mapped[int] = mapped_column(Integer, default=30)
    satisfaction: Mapped[int] = mapped_column(Integer, default=50)

    # 6-3 Emotion 情緒
    # 情緒種類
    emotion_type: Mapped[str] = mapped_column(
        String(20),
        default="calm"
    )
    # 強度
    emotion_intensity: Mapped[int] = mapped_column(
        Integer,
        default=0
    )
    # 起因事件
    emotion_cause_event_id: Mapped[str | None] = mapped_column(
        String(30),
        nullable=True
    )

    # 6-5 Goal 其他狀態
    # 當前目標
    current_goal: Mapped[str] = mapped_column(
        String(40),
        default=""
    )
    # 所在位置
    location_id: Mapped[str] = mapped_column(
        String(30),
        default=""
    )
    # 網格座標 x
    grid_x: Mapped[int] = mapped_column(
        Integer,
        default=0
    )
    # 網格座標 y
    grid_y: Mapped[int] = mapped_column(
        Integer,
        default=0
    )
    
#    npc = relationship(
#    "NPCIdentity",
#    back_populates="state",
#)