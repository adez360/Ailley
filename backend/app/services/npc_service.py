from sqlalchemy.orm import Session

from app.models.npc_hexaco import NPCHexaco
from app.models.npc_identity import NPCIdentity
from app.models.npc_personality import NPCPersonality
from app.models.npc_social import NPCSocial
from app.models.npc_state import NPCState
from app.models.npc_values import NPCValues
from app.repositories.counter_repository import CounterRepository
from app.schemas.npc_identity import NPCIdentityCreate
from app.factories.npc_factory import NPCFactory


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

            npc_bundle = NPCFactory.create(
                npc_id=npc_id,
                data=data,
            )

            self.db.add_all(
                [
                    npc_bundle["identity"],
                    npc_bundle["hexaco"],
                    npc_bundle["personality"],
                    npc_bundle["values"],
                    npc_bundle["social"],
                    npc_bundle["state"],
                ]
            )

            self.db.commit()

            self.db.refresh(
                npc_bundle["identity"]
            )

            return npc_bundle["identity"]

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