from fastapi import APIRouter
from sqlalchemy import text

from app.database.database import SessionLocal

router = APIRouter(
    prefix="/health",
    tags=["Health"],
)


@router.get("")
def health():

    db = SessionLocal()

    try:

        db.execute(text("SELECT 1"))

        return {
            "success": True,
            "status": "online",
            "database": "connected",
        }

    except Exception:

        return {
            "success": False,
            "status": "offline",
            "database": "disconnected",
        }

    finally:

        db.close()