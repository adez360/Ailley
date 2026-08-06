from fastapi import APIRouter

from app.api.health import router as health_router
from app.api.npc import router as npc_router

api_router = APIRouter(
    prefix="/api/v1"
)

api_router.include_router(health_router)
api_router.include_router(npc_router)