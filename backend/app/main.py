from fastapi import FastAPI

import app.models

from app.api.npc import router as npc_router
from app.database.base import Base
from app.database.database import engine
from app.api.health import router as health_router

Base.metadata.create_all(bind=engine)

app = FastAPI(
    title="Ailley Backend",
    version="1.0.0",
)

from app.core.error_handlers import register_exception_handlers
register_exception_handlers(app)

from app.api.router import api_router

app.include_router(api_router)


@app.get("/")
def root():
    return {
        "message": "Ailley Backend Running"
    }