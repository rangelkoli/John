"""FastAPI router for WebSocket connections"""

import json
import asyncio
from datetime import datetime
from typing import Dict, Any, Optional

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, WebSocketException
from pydantic import BaseModel

from app.agent.graph import get_agent
from app.config import settings


router = APIRouter(tags=["websocket"])


class WSMessage(BaseModel):
    type: str
    message: Optional[str] = None
    thread_id: Optional[str] = "default"
    data: Optional[Dict[str, Any]] = None


class ConnectionManager:
    """Manages WebSocket connections"""

    def __init__(self):
        self.active_connections: Dict[str, WebSocket] = {}

    async def connect(self, websocket: WebSocket, thread_id: str):
        await websocket.accept()
        self.active_connections[thread_id] = websocket

    def disconnect(self, thread_id: str):
        self.active_connections.pop(thread_id, None)

    async def send_json(self, thread_id: str, data: Dict[str, Any]):
        if thread_id in self.active_connections:
            websocket = self.active_connections[thread_id]
            await websocket.send_json(data)

    async def send_text(self, thread_id: str, text: str):
        if thread_id in self.active_connections:
            websocket = self.active_connections[thread_id]
            await websocket.send_text(text)


manager = ConnectionManager()


@router.websocket("/ws/chat/{thread_id}")
async def websocket_chat(websocket: WebSocket, thread_id: str):
    """WebSocket endpoint for bidirectional chat"""
    await manager.connect(websocket, thread_id)
    print(f"[WS] Client connected thread_id={thread_id}")

    try:
        while True:
            try:
                raw_data = await websocket.receive_text()
                print(f"[WS] Received from {thread_id}: {raw_data[:200]}")

                msg = WSMessage.model_validate_json(raw_data)

                if msg.type == "chat":
                    await handle_chat_message(
                        websocket, thread_id, msg.message or "", msg.data or {}
                    )
                elif msg.type == "ping":
                    await websocket.send_json(
                        {"type": "pong", "timestamp": datetime.now().isoformat()}
                    )
                elif msg.type == "reset":
                    agent = get_agent()
                    agent.reset_conversation()
                    await websocket.send_json(
                        {"type": "reset_confirmed", "thread_id": thread_id}
                    )
                else:
                    await websocket.send_json(
                        {
                            "type": "error",
                            "message": f"Unknown message type: {msg.type}",
                        }
                    )

            except json.JSONDecodeError as e:
                await websocket.send_json(
                    {"type": "error", "message": f"Invalid JSON: {e}"}
                )

    except WebSocketDisconnect:
        print(f"[WS] Client disconnected thread_id={thread_id}")
    except Exception as e:
        print(f"[WS] Error with {thread_id}: {e}")
    finally:
        manager.disconnect(thread_id)


async def handle_chat_message(
    websocket: WebSocket, thread_id: str, message: str, data: Dict[str, Any]
):
    """Handle incoming chat message via WebSocket"""
    print(f"[WS] Chat thread_id={thread_id} message={message[:100]}")

    await websocket.send_json(
        {
            "type": "processing",
            "thread_id": thread_id,
            "timestamp": datetime.now().isoformat(),
        }
    )

    agent = get_agent()

    try:
        accumulated = ""
        async for event in agent.astream(message, thread_id):
            event_type = event.get("type")

            if event_type == "node":
                await websocket.send_json(
                    {
                        "type": "node",
                        "node": event.get("node"),
                        "output": event.get("output"),
                        "timestamp": datetime.now().isoformat(),
                    }
                )

            elif event_type == "token":
                accumulated = event.get("accumulated", "")
                await websocket.send_json(
                    {
                        "type": "token",
                        "content": event.get("content"),
                        "accumulated": accumulated,
                        "timestamp": datetime.now().isoformat(),
                    }
                )

        await websocket.send_json(
            {
                "type": "complete",
                "response": accumulated,
                "thread_id": thread_id,
                "timestamp": datetime.now().isoformat(),
            }
        )
        print(f"[WS] Complete thread_id={thread_id} response={len(accumulated)} chars")

    except Exception as e:
        print(f"[WS] Error in handle_chat: {e}")
        await websocket.send_json(
            {
                "type": "error",
                "message": str(e),
                "timestamp": datetime.now().isoformat(),
            }
        )
