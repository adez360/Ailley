from typing import Any

from pydantic import BaseModel


class ErrorResponse(BaseModel):
    code: str
    message: str


class ApiResponse(BaseModel):
    success: bool
    data: Any | None = None
    error: ErrorResponse | None = None

    @classmethod
    def ok(cls, data: Any = None):
        return cls(
            success=True,
            data=data,
        )

    @classmethod
    def fail(
        cls,
        code: str,
        message: str,
    ):
        return cls(
            success=False,
            error=ErrorResponse(
                code=code,
                message=message,
            ),
        )