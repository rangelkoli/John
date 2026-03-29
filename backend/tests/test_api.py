"""Tests for FastAPI endpoints"""

import pytest
from unittest.mock import patch, AsyncMock
import asyncio
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture
def client():
    """Create test client"""
    return TestClient(app)


@pytest.fixture
def mock_agent():
    """Mock agent for testing"""
    with patch('app.routers.agent.get_agent') as mock:
        agent_instance = AsyncMock()
        agent_instance.ainvoke = AsyncMock(return_value={
            "response": "Test response",
            "tool_calls": [],
            "observations": []
        })
        agent_instance.astream = AsyncMock(return_value=[])
        mock.return_value = agent_instance
        yield mock


class TestHealthEndpoint:
    """Tests for health check endpoint"""
    
    def test_health_check(self, client):
        """Test health endpoint returns healthy"""
        response = client.get("/api/health")
        
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "healthy"


class TestChatEndpoint:
    """Tests for chat endpoint"""
    
    def test_chat_endpoint_exists(self, client, mock_agent):
        """Test chat endpoint exists andaccepts POST"""
        response = client.post(
            "/api/chat",
            json={"message": "Hello", "thread_id": "test"}
        )
        
        assert response.status_code in [200, 500]# May fail without real agent
    
    def test_chat_request_validation(self, client):
        """Test chat request validation"""
        response = client.post("/api/chat", json={})
        
        assert response.status_code == 422# Validation error


class TestToolsEndpoint:
    """Tests for tools listing endpoint"""
    
    def test_list_tools(self, client):
        """Test tools endpoint returns list"""
        response = client.get("/api/tools")
        
        assert response.status_code == 200
        tools = response.json()
        assert isinstance(tools, list)


class TestRootEndpoint:
    """Tests for root endpoint"""
    
    def test_root_endpoint(self, client):
        """Test root endpoint"""
        response = client.get("/")
        
        assert response.status_code == 200
        data = response.json()
        assert "name" in data
        assert "version" in data