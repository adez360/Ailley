from sqlalchemy import CheckConstraint, ForeignKey, Integer
from sqlalchemy.orm import Mapped, mapped_column

from app.common.base_model import BaseModel


class NPCPersonality(BaseModel):
    __tablename__ = "npc_personality"

    __table_args__ = (
        CheckConstraint(
            "diligence BETWEEN 0 AND 100",
            name="ck_personality_diligence",
        ),
        CheckConstraint(
            "courage BETWEEN 0 AND 100",
            name="ck_personality_courage",
        ),
        CheckConstraint(
            "sociability BETWEEN 0 AND 100",
            name="ck_personality_sociability",
        ),
        CheckConstraint(
            "morality BETWEEN 0 AND 100",
            name="ck_personality_morality",
        ),
        CheckConstraint(
            "stability BETWEEN 0 AND 100",
            name="ck_personality_stability",
        ),
        CheckConstraint(
            "romanticism BETWEEN 0 AND 100",
            name="ck_personality_romanticism",
        ),
        CheckConstraint(
            "curiosity BETWEEN 0 AND 100",
            name="ck_personality_curiosity",
        ),
        CheckConstraint(
            "grudge BETWEEN 0 AND 100",
            name="ck_personality_grudge",
        ),
        CheckConstraint(
            "greed BETWEEN 0 AND 100",
            name="ck_personality_greed",
        ),
        CheckConstraint(
            "honesty BETWEEN 0 AND 100",
            name="ck_personality_honesty",
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

    # 勤勉
    diligence: Mapped[int] = mapped_column(Integer, default=50)

    # 膽識
    courage: Mapped[int] = mapped_column(Integer, default=50)

    # 社交
    sociability: Mapped[int] = mapped_column(Integer, default=50)

    # 道德
    morality: Mapped[int] = mapped_column(Integer, default=50)

    # 情緒穩定
    stability: Mapped[int] = mapped_column(Integer, default=50)

    # 浪漫藝術
    romanticism: Mapped[int] = mapped_column(Integer, default=50)

    # 好奇心
    curiosity: Mapped[int] = mapped_column(Integer, default=50)

    # 記仇度
    grudge: Mapped[int] = mapped_column(Integer, default=50)

    # 貪婪
    greed: Mapped[int] = mapped_column(Integer, default=50)

    # 誠實度
    honesty: Mapped[int] = mapped_column(Integer, default=50)