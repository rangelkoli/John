"""FastAPI router for agent endpoints"""

import json
import httpx
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
    k: int = 5


class MemoryResponse(BaseModel):
    memories: List[Dict[str, Any]]


@router.post("/chat", response_model=ChatResponse)
async def chat(chat_request: ChatRequest):
    """Send a message to the agent and get a response"""
    print(
        f"[POST /chat] thread_id={chat_request.thread_id} message={chat_request.message[:200]}"
    )
    try:
        agent = get_agent()
        result = await agent.ainvoke(chat_request.message, chat_request.thread_id)
        print(f"[POST /chat] done, tool_calls={len(result.get('tool_calls', []))}")

        return ChatResponse(
            response=result["response"],
            thread_id=chat_request.thread_id,
            tool_calls=result.get("tool_calls", []),
            observations=result.get("observations", []),
            timestamp=datetime.now().isoformat(),
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/chat/stream")
async def chat_stream(request: ChatRequest):
    """Stream agent responses via Server-Sent Events"""

    async def event_generator():
        print(
            f"[POST /chat/stream] thread_id={request.thread_id} message={request.message[:200]}"
        )
        try:
            agent = get_agent()
            async for event in agent.astream(request.message, request.thread_id):
                print(
                    f"[POST /chat/stream] event node={event.get('node')} type={event.get('type')}"
                )
                event_data = json.dumps(event)
                yield {"event": "message", "data": event_data}
            print(f"[POST /chat/stream] stream complete")
        except Exception as e:
            print(f"[POST /chat/stream] ERROR: {e}")
            error_data = json.dumps({"type": "error", "message": str(e)})
            yield {"event": "error", "data": error_data}

    return EventSourceResponse(event_generator())


@router.get("/tools", response_model=List[ToolInfo])
async def list_tools():
    """List all available tools"""
    from app.agent.tools import ALL_TOOLS

    tools_info = []
    for tool in ALL_TOOLS:
        params = {}
        if tool.args_schema:
            try:
                params = tool.args_schema.model_json_schema()
            except Exception:
                pass
        tools_info.append(
            ToolInfo(
                name=tool.name,
                description=tool.description,
                parameters=params,
            )
        )

    return tools_info


@router.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint"""
    return HealthResponse(
        status="healthy",
        model=settings.default_model,
        timestamp=datetime.now().isoformat(),
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


class TTSRequest(BaseModel):
    text: str
    voice: Optional[str] = None
    speed: Optional[float] = None
    instructions: Optional[str] = None


@router.post("/tts")
async def text_to_speech(request: TTSRequest):
    """Stream OpenAI TTS audio in realtime"""
    if not settings.openai_api_key:
        raise HTTPException(status_code=500, detail="OPENAI_API_KEY not configured")

    voice = request.voice or settings.tts_voice
    speed = request.speed or settings.tts_speed
    instructions = request.instructions or settings.tts_instructions

    request_payload = {
        "model": settings.tts_model,
        "input": request.text,
        "voice": voice,
        "speed": speed,
        "response_format": "mp3",
    }

    if instructions:
        request_payload["instructions"] = instructions

    print(
        "[POST /tts] "
        f"chars={len(request.text)} "
        f"model={settings.tts_model} "
        f"voice={voice} "
        f"speed={speed} "
        f"instructions={'yes' if bool(instructions) else 'no'}"
    )

    async def audio_stream():
        async with httpx.AsyncClient() as client:
            async with client.stream(
                "POST",
                "https://api.openai.com/v1/audio/speech",
                headers={
                    "Authorization": f"Bearer {settings.openai_api_key}",
                    "Content-Type": "application/json",
                },
                json=request_payload,
                timeout=30.0,
            ) as response:
                if response.status_code != 200:
                    error = await response.aread()
                    print(
                        f"[POST /tts] OpenAI error status={response.status_code} body={error.decode()[:400]}"
                    )
                    raise HTTPException(
                        status_code=response.status_code, detail=error.decode()
                    )
                print("[POST /tts] OpenAI audio stream started")
                async for chunk in response.aiter_bytes(1024):
                    yield chunk

    return StreamingResponse(
        audio_stream(),
        media_type="audio/mpeg",
        headers={"Transfer-Encoding": "chunked"},
    )
