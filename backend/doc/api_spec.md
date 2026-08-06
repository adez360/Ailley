# Ailley Backend API Specification v1

Base URL

http://127.0.0.1:8000/api/v1

---

## NPC

### 建立 NPC

POST /npc

Request

{
    "name": "Alice",
    "age": 18,
    "gender": "Female",
    "appearance": "Long silver hair",
    "character": "Gentle"
}

Response

{
    "id": "npc_000001",
    "name": "Alice",
    "age": 18,
    "gender": "Female",
    "appearance": "Long silver hair",
    "character": "Gentle"
}

---

### 查詢全部 NPC

GET /npc

Response

[
    {
        "id": "npc_000001",
        "name": "Alice"
    }
]

---

### 查詢單一 NPC

GET /npc/{npc_id}

Response

{
    "id": "npc_000001",
    "name": "Alice",
    "age": 18,
    "gender": "Female",
    "appearance": "...",
    "character": "..."
}

---

### 刪除 NPC

DELETE /npc/{npc_id}

Response

{
    "success": true
}

---

## Health

GET /health

Response

{
    "success": true,
    "status": "online"
}