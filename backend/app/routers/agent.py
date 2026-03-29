"""FastAPI router for agent endpoints"""

import json
from typing import Optional, List, Dict, Any
from datetime import datetime

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from sse_starlette.sse import EventSourceResponse

from app.agent.graph import get_agent, DeepAgent
from app.config import settings


router = APIRouter(prefix="/api", tags=["agent"])


class ChatRequest(BaseModel):
    message: str
    thread_id: str = "default"
    stream: bool = True


class ChatResponse(BaseModel):
    response: str
    thread_id: str
    tool_calls: List[Dict[str, Any]] = []
    observations: List[str] = []
    timestamp: str


class ToolInfo(BaseModel):
    name: str
    description: str
    parameters: Dict[str, Any]


class HealthResponse(BaseModel):
    status: str
    model: str
    timestamp: str


class MemoryRequest(BaseModel):
    query: str
    k: int =5


class MemoryResponse(BaseModel):
    memories: List[Dict[str, Any]]


@router.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    """Send a message to the agent and get a response"""
    try:
        agent = get_agent()
        result = await agent.ainvoke(request.message, request.thread_id)
        
        return ChatResponse(
            response=result["response"],
            thread_id=request.thread_id,
            tool_calls=result.get("tool_calls", []),
            observations=result.get("observations", []),
            timestamp=datetime.now().isoformat()
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/chat/stream")
async def chat_stream(request: ChatRequest):
    """Stream agent responses via Server-Sent Events"""
    async def event_generator():
        try:
            agent = get_agent()
            async for event in agent.astream(request.message, request.thread_id):
                event_data = json.dumps(event)
                yield {"event": "message", "data": event_data}
        except Exception as e:
            error_data = json.dumps({"type": "error", "message": str(e)})
            yield {"event": "error", "data": error_data}
    
    return EventSourceResponse(event_generator())


@router.get("/tools", response_model=List[ToolInfo])
async def list_tools():
    """List all available tools"""
    from app.agent.tools import ALL_TOOLS
    
    tools_info = []
    for tool in ALL_TOOLS:
        tools_info.append(ToolInfo(
            name=tool.name,
            description=tool.description,
            parameters=tool.args_schema.schema() if tool.args_schema else {}
        ))
    
    return tools_info


@router.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint"""
    return HealthResponse(
        status="healthy",
        model=settings.default_model,
        timestamp=datetime.now().isoformat()
    )


@router.post("/memory/recall", response_model=MemoryResponse)
async def recall_memory(request: MemoryRequest):
    """Recall memories from long-term storage"""
    try:
        from app.agent.tools import get_memory
        memory = get_memory()
        memories = memory.recall(request.query, request.k)
        return MemoryResponse(memories=memories)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/memory")
async def clear_memory():
    """Clear all long-term memories"""
    try:
        from app.agent.tools import get_memory
        memory = get_memory()
        memory.clear()
        return {"status": "success", "message": "Memory cleared"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/conversation/reset")
async def reset_conversation(thread_id: str = "default"):
    """Reset conversation history"""
    try:
        agent = get_agent()
        agent.reset_conversation()
        return {"status": "success", "thread_id": thread_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))