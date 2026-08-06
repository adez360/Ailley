from app.models.npc_hexaco import NPCHexaco
from app.models.npc_identity import NPCIdentity
from app.models.npc_personality import NPCPersonality
from app.models.npc_social import NPCSocial
from app.models.npc_state import NPCState
from app.models.npc_values import NPCValues
from app.schemas.npc_identity import NPCIdentityCreate


class NPCFactory:

    @staticmethod
    def create(
        npc_id: str,
        data: NPCIdentityCreate,
    ) -> dict:

        identity = NPCIdentity(
            id=npc_id,
            **data.model_dump(),
        )

        hexaco = NPCHexaco(
            npc_id=npc_id,
        )

        personality = NPCPersonality(
            npc_id=npc_id,
        )

        values = NPCValues(
            npc_id=npc_id,
        )

        social = NPCSocial(
            npc_id=npc_id,
        )

        state = NPCState(
            npc_id=npc_id,
        )

        return {
            "identity": identity,
            "hexaco": hexaco,
            "personality": personality,
            "values": values,
            "social": social,
            "state": state,
        }