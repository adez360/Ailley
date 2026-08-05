from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.models.npc_identity import NPCIdentity
from app.repositories.npc_repository import NPCRepository
from app.schemas.npc_identity import (
    NPCIdentityCreate,
    NPCIdentityResponse,
)
from app.services.npc_service import NPCService

router = APIRouter(
    prefix="/npc",
    tags=["NPC"],
)


@router.get(
    "",
    response_model=list[NPCIdentityResponse],
)
def get_all_npc(
    db: Session = Depends(get_db),
):

    service = NPCService(db)

    return service.list_npc()


@router.post(
    "",
    response_model=NPCIdentityResponse,
    status_code=201,
)
def create_npc(
    data: NPCIdentityCreate,
    db: Session = Depends(get_db),
):

    service = NPCService(db)

    return service.create_npc(data)