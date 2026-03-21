# Tauri + React + Typescript

This template should help get you started developing with Tauri, React and Typescript in Vite.

## Recommended IDE Setup

- [VS Code](https://code.visualstudio.com/) + [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)

## Python Deep Agent Integration

- The Tauri command `ask_deep_agent` runs a Python LangChain agent in `src-tauri/agent/deep_agent.py`.
- Install agent dependencies:
  - `python -m pip install -r src-tauri/agent/requirements.txt`
- The app and deep agent now auto-load `app/.env`, `app/.env.local`, `app/src-tauri/.env`, and `app/src-tauri/.env.local` if present.
- Default deep-agent provider: `openrouter`
- Default deep-agent model: `x-ai/grok-4.1-fast` (OpenRouter's model id for Grok 4.1 Fast)
- Required env var for the default setup: `OPENROUTER_API_KEY`
- Optional env var: `PERPLEXITY_API_KEY` (for web search)
- Optional env vars:
  - `DEEP_AGENT_PYTHON` to choose the python executable (defaults to `python3`)
  - `DEEP_AGENT_PROVIDER` (`openrouter` or `openai`; defaults to `openrouter`)
  - `DEEP_AGENT_MODEL` to override the selected provider's default model
  - `OPENROUTER_MODEL` (defaults to `x-ai/grok-4.1-fast`)
  - `OPENROUTER_BASE_URL` (defaults to `https://openrouter.ai/api/v1`)
  - `OPENROUTER_HTTP_REFERER` and `OPENROUTER_APP_TITLE` for optional OpenRouter headers
  - `OPENAI_MODEL` and `OPENAI_API_KEY` if you switch `DEEP_AGENT_PROVIDER=openai`
  - `OPENAI_TEMPERATURE` and `OPENAI_MAX_TOKENS`
  - `TAURI_BRIDGE_URL` to connect a local endpoint for app-context lookup
  - `DEEP_AGENT_BROWSER_COMMAND` to override the browser automation command (defaults to `agent-browser`)
  - `DEEP_AGENT_BROWSER_SESSION` to pin browser actions to a named `agent-browser` session
- Optional safety-policy env vars:
  - `DEEP_AGENT_READ_SCOPE` (`full` or `roots`; defaults to `full`)
  - `DEEP_AGENT_ALLOWED_READ_ROOTS` comma-separated list used when `DEEP_AGENT_READ_SCOPE=roots`
  - `DEEP_AGENT_ALLOWED_WRITE_ROOTS` comma-separated list of writable roots; defaults to the current working directory and `/tmp`
  - `DEEP_AGENT_BLOCK_DESTRUCTIVE_COMMANDS` (`true`/`false`; defaults to `true`)
- The agent exposes `search_web` as a tool with inputs (`query`, `max_results`, `max_tokens`, and `max_tokens_per_page`).
- The agent also exposes browser automation through `agent-browser` plus macOS app tools:
  - `browser(command, timeout)` for actions like `open`, `snapshot -i`, `click @e3`, `fill @e4 "text"`, and `close`
  - `list_applications(query, max_results)` and `open_application(application, arguments)` for app launching
  - `run_applescript(script, timeout)` for deeper macOS UI automation

Browser and app automation notes:

- Install browser support with `agent-browser install` if the browser CLI has not been initialized yet.
- `run_applescript` is macOS-only and may require Accessibility permissions in System Settings for GUI scripting.
- `run_applescript` blocks AppleScript `do shell script`; use the dedicated shell tool instead when you need shell access.

Example `app/.env`:

```env
DEEP_AGENT_PROVIDER=openrouter
OPENROUTER_API_KEY=your_openrouter_key_here
OPENROUTER_MODEL=x-ai/grok-4.1-fast
OPENAI_TEMPERATURE=0
OPENAI_MAX_TOKENS=1200
```

Example for full-system visibility without destructive shell commands:

```env
DEEP_AGENT_READ_SCOPE=full
DEEP_AGENT_ALLOWED_WRITE_ROOTS=/Volumes/RANGEL/john,/tmp
DEEP_AGENT_BLOCK_DESTRUCTIVE_COMMANDS=true
```

With that setup, the agent can inspect files anywhere on the system, but shell commands like `rm`, `mv`, `git reset`, shell redirection, in-place `sed -i`, and interpreter-launch commands such as `python`/`bash` are blocked by policy. Writes are limited to the configured roots.

At runtime, type a question in the overlay and press **Ask** to see the agent output.

## Wake Phrase

- The app now runs a hidden background wake listener for `Hey John`.
- Hearing `Hey John` opens the assistant window and starts the existing voice-input flow.
- There is no always-visible floating trigger now. The assistant stays hidden until the wake phrase is spoken.
- macOS may still show its own microphone privacy indicator while the app is listening in the background.
