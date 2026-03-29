"""Test configuration for John Agent Backend"""

import pytest
import asyncio
from unittest.mock import Mock, patch, AsyncMock
import sys
import os

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))


class TestConfig:
    """Test configuration settings"""
    OPENROUTER_API_KEY = "test-key-12345"
    BACKEND_PORT = 8765
    DEFAULT_MODEL = "test-model"


@pytest.fixture
def mock_settings():
    """Mock settings for testing"""
    with patch('app.config.settings') as mock:
        mock.openrouter_api_key = TestConfig.OPENROUTER_API_KEY
        mock.backend_port = TestConfig.BACKEND_PORT
        mock.default_model = TestConfig.DEFAULT_MODEL
        mock.max_iterations = 5
        yield mock


@pytest.fixture
def mock_llm():
    """Mock LLM for testing"""
    with patch('langchain_openai.ChatOpenAI') as mock:
        mock_instance = Mock()
        mock_instance.invoke = AsyncMock(return_value=Mock(content="Test response"))
        mock.return_value = mock_instance
        yield mock


@pytest.fixture
def event_loop():
    """Create event loop for async tests"""
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()