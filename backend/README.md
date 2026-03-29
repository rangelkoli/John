# John Agent Backend

LangChain/LangGraph deep agent backend for the John macOS app.

## Features

- **Deep Reasoning**: Multi-step reasoning with LangGraph state machine
- **Tool Calling**: Execute tools for file operations, shell commands, memory
- **Long-term Memory**: FAISS-based vector store for persistent memory
- **Streaming**: Server-Sent Events for real-time responses
- **OpenRouter**: Compatible with multiple AI models via OpenRouter

## Setup

```bash
cd backend
python -m venv venv
source venv/bin/activate
pip install -e .
```

## Configuration

Copy `.env.example` to `.env` and set your OpenRouter API key:

```bash
cp . env.example .env
# Edit .env with your API key
```

## Running

```bash
# Development
uvicorn app.main:app --reload --port 8765

# Or using the main module
python -m app.main
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/chat` | POST | Send message, get response |
| `/api/chat/stream` | POST | Stream responses via SSE |
| `/api/tools` | GET | List available tools |
| `/api/health` | GET | Health check |
| `/api/memory/recall` | POST | Search long-term memory |
| `/api/memory` | DELETE | Clear memory |
| `/api/conversation/reset` | POST | Reset conversation |

## Architecture

```
app/
├── agent/
│   ├── graph.py      # LangGraph state machine
│   ├── tools.py      # Tool definitions
│   └── prompts.py    # System prompts
├── memory/
│   ├── conversation.py # Short-term buffer
│   └── vectorstore.py   # Long-term FAISS store
├── routers/
│   └── agent.py      # FastAPI endpoints
└── main.py          # Application entry
```