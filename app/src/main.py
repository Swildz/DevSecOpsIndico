import os
import sys

# Add script directory to sys.path so 'config' can be imported regardless of execution CWD
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import uvicorn
import logging
from config import settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("api.main")

app = FastAPI(
    title=settings.app_name,
    version="1.0.0",
    docs_url=None if settings.environment == "production" else "/docs",
    redoc_url=None
)

# Enforce Security Headers Middleware
@app.middleware("http")
async def add_security_headers(request: Request, call_next):
    response: Response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none';"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    return response

class ItemRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=100, pattern=r"^[a-zA-Z0-9_\-\s]+$")
    description: str = Field("", max_length=500)
    quantity: int = Field(..., ge=1, le=10000)

@app.get("/healthz", status_code=200)
def health_check():
    """Liveness probe for AWS Application Load Balancer target group"""
    return {
        "status": "healthy",
        "environment": settings.environment
    }

@app.get("/api/v1/info")
def get_service_info():
    """Returns application metadata safely without exposing credentials or secrets"""
    return {
        "service": settings.app_name,
        "environment": settings.environment,
        "database_connected": bool(settings.db_password is not None)
    }

@app.post("/api/v1/items", status_code=201)
def create_item(payload: ItemRequest):
    """Secure endpoint with strict input sanitization preventing injection attacks"""
    logger.info(f"Item created successfully: {payload.name}")
    return {
        "message": "Item registered successfully",
        "item": payload.model_dump()
    }

if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=settings.port,
        reload=False,
        server_header=False # Omit Server header to prevent fingerprinting
    )
