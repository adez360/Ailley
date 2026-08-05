from app.database.database import SessionLocal
from app.repositories.npc_repository import NPCRepository


db = SessionLocal()

repo = NPCRepository(db)

print(repo.list())