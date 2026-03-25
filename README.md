# John Assistant

A Siri-like desktop voice assistant powered by local AI (via Ollama) and LangChain's DeepAgents harness. John provides intelligent, context-aware responses with a polished conversational interface, voice input, and spoken replies - all running locally on your machine.

## Features

- **Local AI-Powered Responses**: Runs completely offline using Ollama models (llama3.2 by default)
- **LangChain DeepAgents**: Sophisticated agent workflows using LangGraph
- **Voice Input**: Speak to the assistant using `SpeechRecognition` API when available
- **Text-to-Speech**: Hear responses spoken back through browser speech synthesis
- **Agent Tools**: Time, date, focus plans, and agenda suggestions via LangChain tools
- **Conversational UI**: Polished desktop interface with suggested prompts
- **Privacy First**: All processing happens locally - no data sent to external APIs

## Setup

### Prerequisites

1. **Install Ollama**: Download and install from [ollama.com](https://ollama.com)

2. **Pull a model**: The default model is `llama3.2`. Pull it with:
   ```bash
   ollama pull llama3.2
   ```

   You can also use other models like `llama3.1`, `mistral`, `gemma2`, etc.

### Installation

1. Install dependencies:
   ```bash
   bun install
   ```

2. (Optional) Configure Ollama settings:
   ```bash
   cp .env.example .env
   ```
   Then edit `.env` to customize the model or Ollama URL:
   ```
   OLLAMA_MODEL=llama3.2
   OLLAMA_BASE_URL=http://localhost:11434
   ```

3. Make sure Ollama is running:
   ```bash
   ollama serve
   ```

4. Start the desktop app:
   ```bash
   bun run start
   ```

5. Build the app:
   ```bash
   bun run build:dev
   ```

## Project Structure

```
src/
├── bun/
│   ├── index.ts        # Desktop window bootstrapping & RPC handlers
│   └── agent.ts        # LangChain agent with Claude AI integration
└── mainview/
    ├── index.html      # Assistant layout
    ├── index.css       # Assistant styling
    └── index.ts        # Chat logic, voice input, speech output
```

## How It Works

The assistant uses a sophisticated agent architecture running entirely on your local machine:

```
User speaks → Speech Recognition → Text → LangChain Agent → Ollama (Local LLM) → Response → Text-to-Speech → User hears
```

The LangGraph agent:
1. Receives user input via RPC from the frontend
2. Determines which tools to use based on the query
3. Calls your local Ollama model for natural language understanding
4. Executes tools as needed (time, date, focus plans, etc.)
5. Returns a natural language response
6. Frontend speaks the response using text-to-speech

All processing happens locally - no internet connection required once set up!

## Tech Stack

- **Runtime**: Bun
- **Framework**: Electrobun (desktop app framework)
- **Local AI**: Ollama (llama3.2 by default)
- **Agent Framework**: LangChain + LangGraph
- **Voice**: Web Speech API (built into the webview)

## Notes

- Voice output works through the system speech synthesis voices exposed to the webview
- Voice input depends on platform support in the embedded webview and microphone permissions
- Agent responses are powered by your local Ollama model - completely private and offline
- Falls back to local pattern matching if Ollama is unavailable
- Conversation history is maintained per thread using LangGraph's MemorySaver
- All processing happens locally - no data sent to external APIs

## Recommended Models

- **llama3.2** (default): Balanced performance and quality, good for most tasks
- **llama3.1**: More capable, larger model
- **mistral**: Fast and efficient
- **gemma2**: Good quality, optimized for performance
- **qwen2.5**: Excellent reasoning capabilities

Change the model by setting `OLLAMA_MODEL` in your `.env` file.
