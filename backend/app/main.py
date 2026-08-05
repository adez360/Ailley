from fastapi import FastAPI

import app.models

from app.api.npc import router as npc_router
from app.database.base import Base
from app.database.database import engine

Base.metadata.create_all(bind=engine)

app = FastAPI(
    title="Ailley Backend",
    version="1.0.0",
)

app.include_router(npc_router)


@app.get("/")
def root():
    return {
        "message": "Ailley Backend Running"
    }