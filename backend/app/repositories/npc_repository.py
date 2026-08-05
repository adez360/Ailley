from app.models.npc_identity import NPCIdentity
from app.repositories.base_repository import BaseRepository
from app.repositories.counter_repository import CounterRepository
from app.schemas.npc_identity import NPCIdentityCreate


class NPCRepository(BaseRepository[NPCIdentity]):

    def get(self, npc_id: str) -> NPCIdentity | None:
        return (
            self.db.query(NPCIdentity)
            .filter(NPCIdentity.id == npc_id)
            .first()
        )

    def list(self) -> list[NPCIdentity]:
        return (
            self.db.query(NPCIdentity)
            .all()
        )

    def create(
        self,
        data: NPCIdentityCreate,
    ) -> NPCIdentity:

        counter = CounterRepository(self.db)

        npc = NPCIdentity(
            id=counter.generate_id("npc"),
            **data.model_dump(),
        )

        self.db.add(npc)
        self.db.commit()
        self.db.refresh(npc)

        return npc

    def delete(
        self,
        npc: NPCIdentity,
    ) -> None:

        self.db.delete(npc)
        self.db.commit()