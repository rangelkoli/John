"""Configuration management for John Agent Backend"""

import os
from pathlib import Path
from typing import Optional

from pydantic_settings import BaseSettings
from functools import lru_cache


class Settings(BaseSettings):
    openrouter_api_key: str = ""
    openrouter_base_url: str = "https://openrouter.ai/api/v1"
    backend_port: int = 8765
    host: str = "127.0.0.1"
    log_level: str = "INFO"
    max_iterations: int = 10
    memory_persist_path: str = "~/.john/memory"
    default_model: str = "deepseek/deepseek-chat"
    embedding_model: str = "openai/text-embedding-3-small"
    max_memory_tokens: int = 4000
    conversation_window: int = 10
    
    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        case_sensitive = False

    @property
    def memory_path(self) -> Path:
        return Path(self.memory_persist_path).expanduser().resolve()

    def ensure_memory_dir(self) -> Path:
        path = self.memory_path
        path.mkdir(parents=True, exist_ok=True)
        return path


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()