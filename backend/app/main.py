from fastapi import FastAPI
from app.database.database import engine

app = FastAPI(
    title="AI Town Backend",
    version="0.1.0"
)

@app.get("/")
async def root():
    return {
        "message": "Backend Running"
    }
    
@app.get("/database")
async def database():
    return {
        "database": str(engine.url)
    }