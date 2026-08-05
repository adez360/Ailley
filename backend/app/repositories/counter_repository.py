from sqlalchemy.orm import Session

from app.models.system_counter import SystemCounter


class CounterRepository:

    def __init__(self, db: Session):
        self.db = db

    def generate_id(
        self,
        key: str,
        digits: int = 6,
    ) -> str:

        counter = (
            self.db.query(SystemCounter)
            .filter(SystemCounter.counter_key == key)
            .first()
        )

        if counter is None:

            counter = SystemCounter(
                counter_key=key,
                next_value=1,
            )

            self.db.add(counter)
            self.db.flush()

        value = counter.next_value

        counter.next_value += 1

        self.db.commit()

        return f"{key}_{value:0{digits}d}"