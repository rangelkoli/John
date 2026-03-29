"""Tests for agent graph"""

import pytest
import asyncio
from unittest.mock import Mock, patch, AsyncMock

from app.agent.graph import DeepAgent, AgentState
from app.agent.tools import ALL_TOOLS


class TestDeepAgent:
    """Tests for DeepAgent class"""
    
    @pytest.mark.asyncio
    async def test_agent_initialization(self, mock_settings):
        """Test agent initializes correctly"""
        with patch('app.agent.graph.ChatOpenAI'):
            agent = DeepAgent(
                model="test-model",
                max_iterations=5
            )
            
            assert agent.model_name == "test-model"
            assert agent.max_iterations == 5
            assert agent.llm is not None
            assert len(ALL_TOOLS) > 0
    
    @pytest.mark.asyncio
    async def test_agent_state_structure(self):
        """Test agent state has required fields"""
        state: AgentState = {
            "messages": [],
            "current_plan": "",
            "current_step": 0,
            "observations": [],
            "tool_results": [],
            "should_continue": True,
            "final_response": None
        }
        
        assert "messages" in state
        assert "current_plan" in state
        assert "observations" in state
        assert "tool_results" in state
        assert "should_continue" in state
    
    @pytest.mark.asyncio
    async def test_reset_conversation(self, mock_settings):
        """Test conversation reset"""
        with patch('app.agent.graph.ChatOpenAI'):
            agent = DeepAgent()
            
            agent.conversation_buffer.add_message(Mock(type="human", content="test"))
            assert len(agent.conversation_buffer.messages) > 0
            
            agent.reset_conversation()
            assert len(agent.conversation_buffer.messages) == 0


class TestTools:
    """Tests for agent tools"""
    
    def test_all_tools_defined(self):
        """Test all expected tools are defined"""
        tool_names = [t.name for t in ALL_TOOLS]
        
        expected_tools = [
            "file_read",
            "file_write",
            "shell_execute",
            "web_search",
            "memory_store",
            "memory_recall",
            "code_execute",
            "get_current_time",
            "list_directory"
        ]
        
        for expected in expected_tools:
            assert expected in tool_names, f"Missing tool: {expected}"
    
    def test_file_read_tool(self):
        """Test file read tool"""
        from app.agent.tools import file_read
        
        result = file_read.invoke("/nonexistent/path")
        assert "Error" in result
    
    def test_get_current_time_tool(self):
        """Test get current time tool"""
        from app.agent.tools import get_current_time
        
        result = get_current_time.invoke({})
        assert result is not None
        assert len(result) > 0
    
    def test_list_directory_tool(self):
        """Test list directory tool"""
        from app.agent.tools import list_directory
        
        result = list_directory.invoke("~")
        assert "DIR" in result or "FILE" in result or "Directory is empty" in result