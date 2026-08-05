from sqlalchemy import CheckConstraint, ForeignKey, Integer
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.common.base_model import BaseModel


class NPCHexaco(BaseModel):
    __tablename__ = "npc_hexaco"

    __table_args__ = (
        CheckConstraint(
            "hex_honesty BETWEEN 0 AND 100",
            name="ck_hexaco_honesty",
        ),
        CheckConstraint(
            "hex_emotionality BETWEEN 0 AND 100",
            name="ck_hexaco_emotionality",
        ),
        CheckConstraint(
            "hex_extraversion BETWEEN 0 AND 100",
            name="ck_hexaco_extraversion",
        ),
        CheckConstraint(
            "hex_agreeableness BETWEEN 0 AND 100",
            name="ck_hexaco_agreeableness",
        ),
        CheckConstraint(
            "hex_conscientiousness BETWEEN 0 AND 100",
            name="ck_hexaco_conscientiousness",
        ),
        CheckConstraint(
            "hex_openness BETWEEN 0 AND 100",
            name="ck_hexaco_openness",
        ),
    )

    # ondelete="CASCADE" = 如果這個角色被刪除，該角色的HEXACO一起刪除
    npc_id: Mapped[str] = mapped_column(
        ForeignKey("npc_identity.id", ondelete="CASCADE"),
        primary_key=True,
        index=True,
    )
    
    # 誠實謙遜
    hex_honesty: Mapped[int] = mapped_column(Integer, default=50)
    # 情緒起伏
    hex_emotionality: Mapped[int] = mapped_column(Integer, default=50)
    # 外向性
    hex_extraversion: Mapped[int] = mapped_column(Integer, default=50)
    # 友善性
    hex_agreeableness: Mapped[int] = mapped_column(Integer, default=50)
    # 嚴謹性
    hex_conscientiousness: Mapped[int] = mapped_column(Integer, default=50)
    # 開放性
    hex_openness: Mapped[int] = mapped_column(Integer, default=50)

#    npc = relationship(
#        "NPCIdentity",
#        back_populates="hexaco",
#    )