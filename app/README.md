# Tauri + React + Typescript

This template should help get you started developing with Tauri, React and Typescript in Vite.

## Recommended IDE Setup

- [VS Code](https://code.visualstudio.com/) + [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)

## Python Deep Agent Integration

- The Tauri command `ask_deep_agent` runs a Python LangChain agent in `src-tauri/agent/deep_agent.py`.
- Install agent dependencies:
  - `python -m pip install -r src-tauri/agent/requirements.txt`
- Required env var: `OPENAI_API_KEY`
- Optional env var: `PERPLEXITY_API_KEY` (for web search)
- Optional env vars:
  - `DEEP_AGENT_PYTHON` to choose the python executable (defaults to `python3`)
  - `OPENAI_MODEL` (defaults to `gpt-4o-mini`)
  - `OPENAI_TEMPERATURE` and `OPENAI_MAX_TOKENS`
  - `TAURI_BRIDGE_URL` to connect a local endpoint for app-context lookup
- The agent exposes `search_web` as a tool with inputs (`query`, `max_results`, `max_tokens`, and `max_tokens_per_page`).

At runtime, type a question in the overlay and press **Ask** to see the agent output.

## Wake Phrase

- The app now runs a hidden background wake listener for `Hey John`.
- Hearing `Hey John` opens the assistant window and starts the existing voice-input flow.
- There is no always-visible floating trigger now. The assistant stays hidden until the wake phrase is spoken.
- macOS may still show its own microphone privacy indicator while the app is listening in the background.
