from sqlalchemy.orm import Session

from app.models.npc_hexaco import NPCHexaco
from app.models.npc_identity import NPCIdentity
from app.models.npc_personality import NPCPersonality
from app.models.npc_social import NPCSocial
from app.models.npc_state import NPCState
from app.models.npc_values import NPCValues
from app.repositories.counter_repository import CounterRepository
from app.schemas.npc_identity import NPCIdentityCreate


class NPCService:

    def __init__(self, db: Session):
        self.db = db
        self.counter = CounterRepository(db)

    def list_npc(self):
        return self.db.query(NPCIdentity).all()

    def get_npc(self, npc_id: str):
        return (
            self.db.query(NPCIdentity)
            .filter(NPCIdentity.id == npc_id)
            .first()
        )

    def create_npc(
        self,
        data: NPCIdentityCreate,
    ) -> NPCIdentity:

        npc_id = self.counter.generate_id("npc")

        try:

            npc = NPCIdentity(
                id=npc_id,
                **data.model_dump(),
            )

            self.db.add(npc)

            self.db.add(
                NPCHexaco(
                    npc_id=npc_id,
                )
            )

            self.db.add(
                NPCPersonality(
                    npc_id=npc_id,
                )
            )

            self.db.add(
                NPCValues(
                    npc_id=npc_id,
                )
            )

            self.db.add(
                NPCSocial(
                    npc_id=npc_id,
                )
            )

            self.db.add(
                NPCState(
                    npc_id=npc_id,
                )
            )

            self.db.commit()

            self.db.refresh(npc)

            return npc

        except Exception:

            self.db.rollback()

            raise

    def delete_npc(
        self,
        npc_id: str,
    ):

        npc = self.get_npc(npc_id)

        if npc is None:
            return None

        self.db.delete(npc)

        self.db.commit()

        return True