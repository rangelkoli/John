"""Main FastAPI application entry point"""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.routers import agent


logging.basicConfig(
    level=getattr(logging, settings.log_level.upper()),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting John Agent Backend...")
    logger.info(f"Model: {settings.default_model}")
    logger.info(f"Max iterations: {settings.max_iterations}")
    
    from app.agent.graph import get_agent
    agent_instance = get_agent()
    logger.info("Agent initialized successfully")
    
    yield
    
    logger.info("Shutting down John Agent Backend...")


app = FastAPI(
    title="John Agent Backend",
    description="LangChain/LangGraph deep agent backend for John macOS app",
    version="0.1.0",
    lifespan=lifespan
)


app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


app.include_router(agent.router)


@app.get("/")
async def root():
    return {
        "name": "John Agent Backend",
        "version": "0.1.0",
        "status": "running",
        "model": settings.default_model
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host=settings.host,
        port=settings.backend_port,
        reload=True,
        log_level=settings.log_level.lower()
    )