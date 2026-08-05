from pydantic import BaseModel, ConfigDict


class NPCIdentityCreate(BaseModel):
    name: str
    age: int
    gender: str
    appearance: str
    character: str


class NPCIdentityResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    name: str
    age: int
    gender: str
    appearance: str
    character: str