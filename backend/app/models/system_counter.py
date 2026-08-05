from sqlalchemy import Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.common.base_model import BaseModel


class SystemCounter(BaseModel):
    __tablename__ = "system_counter"

    counter_key: Mapped[str] = mapped_column(
        String(50),
        primary_key=True,
    )

    next_value: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=1,
    )