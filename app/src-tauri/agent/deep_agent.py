#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import os
import shlex
import shutil
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from langchain_core.tools import tool
from langchain_core.messages import BaseMessage
from langchain_openai import ChatOpenAI
from perplexity import Perplexity

DEFAULT_OPENAI_MODEL = "gpt-5-nano-2025-08-07"
DEFAULT_OPENROUTER_MODEL = "x-ai/grok-4.1-fast"
DEFAULT_OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"
MAX_TOOL_EVENT_STRING_LENGTH = 400
MAX_TOOL_EVENT_COLLECTION_ITEMS = 8
MAX_TOOL_EVENT_DEPTH = 2
DEFAULT_TOOL_OUTPUT_CHAR_LIMIT = 12000
DEFAULT_LIST_FILES_MAX_ENTRIES = 200
DEFAULT_READ_SCOPE = "full"
DEFAULT_BLOCK_DESTRUCTIVE_COMMANDS = True
DEFAULT_BROWSER_COMMAND = "agent-browser"
DEFAULT_BROWSER_TIMEOUT = 120
DEFAULT_WRITE_ROOTS = [Path.cwd().resolve(strict=False), Path(tempfile.gettempdir()).resolve(strict=False)]
APPLICATION_SEARCH_ROOTS = (
    Path("/Applications"),
    Path("/Applications/Utilities"),
    Path("/System/Applications"),
    Path("/System/Applications/Utilities"),
    Path.home() / "Applications",
)
BLOCKED_SHELL_HEADS = {
    "bash",
    "chmod",
    "chown",
    "chgrp",
    "dd",
    "diskutil",
    "fdisk",
    "halt",
    "killall",
    "ksh",
    "launchctl",
    "ln",
    "mkfs",
    "mv",
    "node",
    "osascript",
    "perl",
    "php",
    "pkill",
    "poweroff",
    "python",
    "python3",
    "reboot",
    "rm",
    "rmdir",
    "ruby",
    "sh",
    "shutdown",
    "sudo",
    "su",
    "tee",
    "truncate",
    "zsh",
}
BLOCKED_GIT_SUBCOMMANDS = {"checkout", "clean", "reset", "restore"}
BLOCKED_SHELL_PATTERNS = [
    (re.compile(r"(^|[\s;&|])git\s+branch\s+-D(\s|$)", re.IGNORECASE), "Deleting git branches is blocked."),
    (re.compile(r"(^|[\s;&|])git\s+stash\s+(drop|clear|pop)(\s|$)", re.IGNORECASE), "Dropping git stash entries is blocked."),
    (re.compile(r"(^|[\s;&|])find\b[^\n]*\s-delete(\s|$)", re.IGNORECASE), "Destructive find invocations are blocked."),
    (re.compile(r"(^|[\s;&|])sed\b[^\n]*\s-i(\s|$)", re.IGNORECASE), "In-place shell edits are blocked; use write_file instead."),
    (re.compile(r"(^|[\s;&|])perl\b[^\n]*\s-i(\s|$)", re.IGNORECASE), "In-place shell edits are blocked."),
    (re.compile(r"(^|[^<])>>?(\s|$)"), "Shell output redirection is blocked."),
    (re.compile(r"(^|[\s;&|])(&>|2>|1>|<<)(\s|$)"), "Shell redirection is blocked."),
]
BLOCKED_APPLESCRIPT_PATTERNS = [
    (
        re.compile(r"\bdo\s+shell\s+script\b", re.IGNORECASE),
        "AppleScript 'do shell script' is blocked. Use the dedicated shell tool instead.",
    ),
]


def _strip_optional_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def _load_env_files() -> None:
    app_dir = Path(__file__).resolve().parents[2]
    candidates = [
        app_dir / ".env.local",
        app_dir / ".env",
        app_dir / "src-tauri" / ".env.local",
        app_dir / "src-tauri" / ".env",
    ]

    for path in candidates:
        if not path.is_file():
            continue

        for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export ") :].strip()

            if "=" not in line:
                continue

            key, value = line.split("=", 1)
            key = key.strip()
            if not key or os.getenv(key):
                continue

            os.environ[key] = _strip_optional_quotes(value.strip())


def _env_first(*keys: str) -> str:
    for key in keys:
        value = os.getenv(key, "").strip()
        if value:
            return value
    return ""


def _env_flag(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _split_env_list(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def _resolve_path(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    return path.resolve(strict=False)


def _path_is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _read_scope() -> str:
    return os.getenv("DEEP_AGENT_READ_SCOPE", DEFAULT_READ_SCOPE).strip().lower() or DEFAULT_READ_SCOPE


def _allowed_read_roots() -> list[Path]:
    return [_resolve_path(root) for root in _split_env_list(os.getenv("DEEP_AGENT_ALLOWED_READ_ROOTS", ""))]


def _allowed_write_roots() -> list[Path]:
    roots = _split_env_list(os.getenv("DEEP_AGENT_ALLOWED_WRITE_ROOTS", ""))
    if not roots:
        return DEFAULT_WRITE_ROOTS
    return [_resolve_path(root) for root in roots]


def _assert_read_allowed(path_str: str) -> Path:
    resolved = _resolve_path(path_str)
    if _read_scope() == "full":
        return resolved

    roots = _allowed_read_roots() or _allowed_write_roots()
    if any(_path_is_within(resolved, root) for root in roots):
        return resolved

    roots_str = ", ".join(str(root) for root in roots)
    raise PermissionError(
        "Read access denied outside allowed roots. "
        f"Set DEEP_AGENT_READ_SCOPE=full or update DEEP_AGENT_ALLOWED_READ_ROOTS. Current roots: {roots_str}"
    )


def _assert_write_allowed(path_str: str) -> Path:
    resolved = _resolve_path(path_str)
    candidate = resolved if resolved.exists() else resolved.parent
    roots = _allowed_write_roots()
    if any(_path_is_within(candidate, root) for root in roots):
        return resolved

    roots_str = ", ".join(str(root) for root in roots)
    raise PermissionError(
        "Write access denied outside allowed roots. "
        f"Update DEEP_AGENT_ALLOWED_WRITE_ROOTS to permit this path. Current roots: {roots_str}"
    )


def _split_shell_segments(command: str) -> list[list[str]]:
    import shlex

    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    segments: list[list[str]] = []
    current: list[str] = []

    for token in lexer:
        if token in {";", "&&", "||", "|", "&", "\n"}:
            if current:
                segments.append(current)
                current = []
            continue
        current.append(token)

    if current:
        segments.append(current)
    return segments


def _segment_head(tokens: list[str]) -> str:
    for token in tokens:
        if "=" in token and not token.startswith(("/", "./", "../")) and token.split("=", 1)[0].isidentifier():
            continue
        return token
    return ""


def _blocked_shell_reason(command: str) -> str | None:
    if not _env_flag("DEEP_AGENT_BLOCK_DESTRUCTIVE_COMMANDS", DEFAULT_BLOCK_DESTRUCTIVE_COMMANDS):
        return None

    for pattern, message in BLOCKED_SHELL_PATTERNS:
        if pattern.search(command):
            return message

    for segment in _split_shell_segments(command):
        head = _segment_head(segment)
        if not head:
            continue

        if head in BLOCKED_SHELL_HEADS:
            return f"Shell command '{head}' is blocked as destructive or too easy to misuse."

        if head == "git":
            subcommand = next((token for token in segment[1:] if not token.startswith("-")), "")
            if subcommand in BLOCKED_GIT_SUBCOMMANDS:
                return f"Git subcommand '{subcommand}' is blocked because it can discard data."
            if "--source" in segment or "--staged" in segment:
                return "Potentially destructive 'git restore' usage is blocked."

    return None


def _resolve_provider() -> str:
    provider = _env_first("DEEP_AGENT_PROVIDER", "DEEP_AGENT_LLM_PROVIDER").lower()
    if not provider:
        return "openrouter"
    if provider in {"openrouter", "open-router", "open_router"}:
        return "openrouter"
    if provider == "openai":
        return "openai"
    raise RuntimeError(
        f"Unsupported DEEP_AGENT_PROVIDER: {provider}. Use 'openrouter' or 'openai'."
    )


def _resolve_llm_kwargs(*, streaming: bool = False) -> dict[str, Any]:
    provider = _resolve_provider()
    kwargs: dict[str, Any] = {
        "temperature": float(os.getenv("OPENAI_TEMPERATURE", "0")),
        "max_tokens": int(os.getenv("OPENAI_MAX_TOKENS", "1200")),
        "streaming": streaming,
    }

    if provider == "openrouter":
        api_key = _env_first("DEEP_AGENT_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY")
        if not api_key:
            raise RuntimeError(
                "OpenRouter is selected for the deep agent, but no API key was found. "
                "Set OPENROUTER_API_KEY (or DEEP_AGENT_API_KEY)."
            )

        kwargs["model"] = _env_first("DEEP_AGENT_MODEL", "OPENROUTER_MODEL") or DEFAULT_OPENROUTER_MODEL
        kwargs["api_key"] = api_key
        kwargs["base_url"] = _env_first("DEEP_AGENT_BASE_URL", "OPENROUTER_BASE_URL") or DEFAULT_OPENROUTER_BASE_URL

        headers: dict[str, str] = {}
        http_referer = _env_first("OPENROUTER_HTTP_REFERER")
        app_title = _env_first("OPENROUTER_APP_TITLE")
        if http_referer:
            headers["HTTP-Referer"] = http_referer
        if app_title:
            headers["X-Title"] = app_title
        if headers:
            kwargs["default_headers"] = headers

        return kwargs

    api_key = _env_first("DEEP_AGENT_API_KEY", "OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError(
            "OpenAI is selected for the deep agent, but OPENAI_API_KEY is missing."
        )

    kwargs["model"] = _env_first("DEEP_AGENT_MODEL", "OPENAI_MODEL") or DEFAULT_OPENAI_MODEL
    kwargs["api_key"] = api_key
    base_url = _env_first("DEEP_AGENT_BASE_URL", "OPENAI_BASE_URL")
    if base_url:
        kwargs["base_url"] = base_url
    return kwargs


def _build_llm(*, streaming: bool = False) -> ChatOpenAI:
    return ChatOpenAI(**_resolve_llm_kwargs(streaming=streaming))


_load_env_files()


def _fetch_tauri_bridge(question: str) -> str:
    """Best-effort call to an optional Tauri bridge endpoint."""
    endpoint = os.getenv("TAURI_BRIDGE_URL", "").strip()
    if not endpoint:
        return (
            "No TAURI_BRIDGE_URL is configured. Set it to a local endpoint to let the agent"
            " read live app context."
        )

    req = urllib.request.Request(endpoint, data=question.encode("utf-8"), method="POST")
    req.add_header("Content-Type", "text/plain; charset=utf-8")
    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            payload = response.read().decode("utf-8")
            if not payload.strip():
                return "Bridge endpoint returned an empty payload."
            return payload
    except urllib.error.HTTPError as exc:
        return f"Bridge returned HTTP {exc.code}: {exc.reason}"
    except Exception as exc:
        return f"Could not reach Tauri bridge at {endpoint}: {exc}"


def _extract_message_text(messages: list[BaseMessage] | list[dict[str, Any]]) -> str:
    for msg in reversed(messages):
        if isinstance(msg, BaseMessage):
            data = msg.model_dump()
        else:
            data = msg
        if data.get("type") == "ai" and data.get("content"):
            content = data["content"]
            if isinstance(content, list):
                content = " ".join(str(part) for part in content)
            return str(content).strip()

    return "Agent returned an empty response."


def _truncate_text(value: str, limit: int = MAX_TOOL_EVENT_STRING_LENGTH) -> str:
    if len(value) <= limit:
        return value
    return f"{value[: limit - 1]}…"


def _summarize_for_event(value: Any, *, depth: int = 0) -> Any:
    if value is None or isinstance(value, (bool, int, float)):
        return value

    if isinstance(value, str):
        return _truncate_text(value)

    if depth >= MAX_TOOL_EVENT_DEPTH:
        return _truncate_text(repr(value))

    if isinstance(value, dict):
        items = list(value.items())
        summarized = {
            str(key): _summarize_for_event(item, depth=depth + 1)
            for key, item in items[:MAX_TOOL_EVENT_COLLECTION_ITEMS]
        }
        if len(items) > MAX_TOOL_EVENT_COLLECTION_ITEMS:
            summarized["..."] = f"{len(items) - MAX_TOOL_EVENT_COLLECTION_ITEMS} more field(s)"
        return summarized

    if isinstance(value, (list, tuple, set)):
        items = list(value)
        summarized = [
            _summarize_for_event(item, depth=depth + 1)
            for item in items[:MAX_TOOL_EVENT_COLLECTION_ITEMS]
        ]
        if len(items) > MAX_TOOL_EVENT_COLLECTION_ITEMS:
            summarized.append(f"... {len(items) - MAX_TOOL_EVENT_COLLECTION_ITEMS} more item(s)")
        return summarized

    return _truncate_text(repr(value))


def _stringify_for_event(value: Any) -> str:
    summarized = _summarize_for_event(value)
    if isinstance(summarized, str):
        return summarized

    try:
        rendered = json.dumps(summarized, ensure_ascii=False)
    except TypeError:
        rendered = repr(summarized)
    return _truncate_text(rendered)


def _positive_env_int(name: str, default: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value > 0 else default


def _tool_output_char_limit() -> int:
    return _positive_env_int("DEEP_AGENT_TOOL_OUTPUT_CHAR_LIMIT", DEFAULT_TOOL_OUTPUT_CHAR_LIMIT)


def _list_files_max_entries() -> int:
    return _positive_env_int("DEEP_AGENT_LIST_FILES_MAX_ENTRIES", DEFAULT_LIST_FILES_MAX_ENTRIES)


def _limit_tool_output(value: str, *, label: str) -> str:
    limit = _tool_output_char_limit()
    if len(value) <= limit:
        return value
    omitted = len(value) - limit
    return f"{value[:limit]}\n... [{label} truncated by {omitted} characters]"


def _resolve_executable(command: str) -> str | None:
    candidate = Path(command).expanduser()
    if candidate.is_absolute() or "/" in command:
        resolved = candidate if candidate.is_absolute() else (Path.cwd() / candidate)
        return str(resolved.resolve(strict=False)) if resolved.exists() else None
    return shutil.which(command)


def _format_process_output(result: subprocess.CompletedProcess[str], *, label: str) -> str:
    output = ""
    if result.stdout:
        output += result.stdout
    if result.stderr:
        if output:
            output += "\n"
        output += result.stderr
    if result.returncode != 0:
        output += f"\n[exit code: {result.returncode}]"
    return _limit_tool_output(output.strip() or "(no output)", label=label)


def _run_command(
    args: list[str],
    *,
    timeout: int,
    label: str,
    env: dict[str, str] | None = None,
) -> str:
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return f"Command timed out after {timeout} seconds."
    except FileNotFoundError:
        return f"Command not found: {args[0]}"
    except Exception as exc:
        return f"Failed to execute command: {exc}"

    return _format_process_output(result, label=label)


def _resolve_browser_command() -> str | None:
    command = _env_first("DEEP_AGENT_BROWSER_COMMAND") or DEFAULT_BROWSER_COMMAND
    return _resolve_executable(command)


def _blocked_applescript_reason(script: str) -> str | None:
    for pattern, message in BLOCKED_APPLESCRIPT_PATTERNS:
        if pattern.search(script):
            return message
    return None


def _normalize_app_name(name: str) -> str:
    normalized = name.strip().lower()
    if normalized.endswith(".app"):
        normalized = normalized[:-4]
    return normalized


def _iter_application_paths() -> list[Path]:
    found: dict[str, Path] = {}
    for root in APPLICATION_SEARCH_ROOTS:
        if not root.is_dir():
            continue
        try:
            children = sorted(root.iterdir(), key=lambda path: path.name.lower())
        except OSError:
            continue

        for child in children:
            if child.suffix != ".app":
                continue
            found.setdefault(child.name.lower(), child)
    return list(found.values())


def _find_matching_applications(query: str) -> list[Path]:
    query = query.strip()
    if not query:
        return _iter_application_paths()

    direct_path = Path(query).expanduser()
    if direct_path.exists() and direct_path.suffix == ".app":
        return [direct_path.resolve(strict=False)]

    normalized_query = _normalize_app_name(query)
    exact_matches: list[Path] = []
    partial_matches: list[Path] = []
    for path in _iter_application_paths():
        normalized_name = _normalize_app_name(path.name)
        if normalized_name == normalized_query:
            exact_matches.append(path)
        elif normalized_query in normalized_name:
            partial_matches.append(path)

    return exact_matches or partial_matches


async def _stream_agent_response(question: str) -> None:
    """Stream the agent response as JSON events to stdout."""
    try:
        agent = build_agent()
        
        if create_agent is not None and not _HAS_LEGACY_AGENT:
            # New API - use astream_events for better streaming
            try:
                async for event in agent.astream_events({"messages": [{"type": "human", "content": question}]}, version="v2"):
                    event_type = event.get("event")
                    
                    if event_type == "on_chat_model_stream":
                        data = event.get("data", {})
                        chunk = data.get("chunk")
                        if chunk and hasattr(chunk, "content"):
                            content = chunk.content
                            if content:
                                event_data = json.dumps({"type": "chunk", "content": str(content)})
                                print(event_data, flush=True)
                    
                    elif event_type == "on_tool_start":
                        data = event.get("data", {})
                        tool_name = event.get("name") or data.get("name", "unknown")
                        tool_input = _summarize_for_event(data.get("input", {}))
                        run_id = event.get("run_id", "")
                        event_data = json.dumps({
                            "type": "tool_call",
                            "run_id": run_id,
                            "tool": tool_name,
                            "input": tool_input,
                        })
                        print(event_data, flush=True)
                    
                    elif event_type == "on_tool_end":
                        data = event.get("data", {})
                        tool_name = event.get("name") or data.get("name", "unknown")
                        output = data.get("output")
                        run_id = event.get("run_id", "")
                        output_str = ""
                        if hasattr(output, "content"):
                            output_str = _stringify_for_event(output.content)
                        elif output is not None:
                            output_str = _stringify_for_event(output)
                        event_data = json.dumps({
                            "type": "tool_result",
                            "run_id": run_id,
                            "tool": tool_name,
                            "output": output_str,
                        })
                        print(event_data, flush=True)
                
                print(json.dumps({"type": "done"}), flush=True)
            except (AttributeError, TypeError):
                # Fallback: try direct LLM streaming
                llm = _build_llm(streaming=True)
                
                from langchain_core.messages import HumanMessage
                async for chunk in llm.astream([HumanMessage(content=question)]):
                    if chunk.content:
                        event_data = json.dumps({"type": "chunk", "content": str(chunk.content)})
                        print(event_data, flush=True)
                
                print(json.dumps({"type": "done"}), flush=True)
        else:
            # Fallback: run non-streaming and emit as single chunk
            answer = _run_legacy_api(agent, question)
            print(json.dumps({"type": "chunk", "content": answer}), flush=True)
            print(json.dumps({"type": "done"}), flush=True)
    except Exception as e:
        print(json.dumps({"type": "error", "content": str(e)}), flush=True)
        return


def _search_perplexity(query: str, max_results: int, max_tokens: int, max_tokens_per_page: int) -> str:
    """Run a web search with Perplexity and return compact hit summaries."""
    api_key = os.getenv("PERPLEXITY_API_KEY", "").strip()
    if not api_key:
        return "PERPLEXITY_API_KEY is missing. Set it in your environment to enable web search."

    try:
        client = Perplexity(api_key=api_key)
        search = client.search.create(
            query=query,
            max_results=max_results,
            max_tokens=max_tokens,
            max_tokens_per_page=max_tokens_per_page,
        )
    except Exception as exc:
        return f"Perplexity search failed: {exc}"

    hits = getattr(search, "results", None)
    if not hits:
        return "No web results returned."

    lines = []
    for idx, result in enumerate(hits, start=1):
        title = getattr(result, "title", "Untitled").strip() if getattr(result, "title", None) else "Untitled"
        url = getattr(result, "url", "").strip() if getattr(result, "url", None) else ""
        snippet = (
            getattr(result, "snippet", "").strip()
            if getattr(result, "snippet", None)
            else ""
        )
        line = f"{idx}. {title}: {url}" if url else f"{idx}. {title}"
        if snippet:
            line = f"{line}\n   {snippet}"
        lines.append(line)

    return "\n".join(lines)


def _run_new_api(agent, question: str) -> str:
    result = agent.invoke({"messages": [{"type": "human", "content": question}]})
    if not isinstance(result, dict):
        return str(result)

    if result.get("structured_response") is not None:
        return str(result["structured_response"])

    messages = result.get("messages", [])
    if isinstance(messages, list):
        return _extract_message_text(messages)
    return str(result)


def _run_legacy_api(agent, question: str) -> str:
    if hasattr(agent, "invoke"):
        result = agent.invoke({"input": question})
    else:
        result = agent.run(question)
    if isinstance(result, dict):
        return str(result.get("output", "No output returned by agent."))
    return str(result)


try:
    from langchain.agents import create_agent
except Exception:  # pragma: no cover - fallback for legacy layouts
    create_agent = None

    from langchain.agents import initialize_agent, AgentType

    _HAS_LEGACY_AGENT = True
else:
    _HAS_LEGACY_AGENT = False


@tool
def get_tauri_context(question: str = "") -> str:
    """Fetches current app context from an optional Tauri bridge endpoint."""
    return _fetch_tauri_bridge(question)


@tool
def search_web(
    query: str,
    max_results: int = 10,
    max_tokens: int = 25000,
    max_tokens_per_page: int = 2048,
) -> str:
    """Searches the web via Perplexity and returns result titles, URLs, and snippets."""
    if not query.strip():
        return "Query cannot be empty."
    return _search_perplexity(
        query=query,
        max_results=max_results,
        max_tokens=max_tokens,
        max_tokens_per_page=max_tokens_per_page,
    )


@tool
def browser(command: str, timeout: int = DEFAULT_BROWSER_TIMEOUT) -> str:
    """Controls a real browser through the local agent-browser CLI.

    Pass the raw agent-browser subcommand string, for example:
    - open https://example.com
    - snapshot -i
    - click @e3
    - fill @e4 "hello"
    - press Enter
    - get title
    - wait --url "**/dashboard"
    - screenshot /tmp/page.png
    - close

    Always run snapshot -i before using @e refs, and re-snapshot after navigation or large UI changes.
    """
    if not command.strip():
        return "Browser command cannot be empty."

    executable = _resolve_browser_command()
    if not executable:
        configured = _env_first("DEEP_AGENT_BROWSER_COMMAND") or DEFAULT_BROWSER_COMMAND
        return (
            "Browser automation is unavailable because the command could not be found: "
            f"{configured}. Install agent-browser or set DEEP_AGENT_BROWSER_COMMAND."
        )

    try:
        parts = shlex.split(command)
    except ValueError as exc:
        return f"Invalid browser command: {exc}"

    env = os.environ.copy()
    if _env_first("DEEP_AGENT_BROWSER_SESSION") and "AGENT_BROWSER_SESSION" not in env:
        env["AGENT_BROWSER_SESSION"] = _env_first("DEEP_AGENT_BROWSER_SESSION")

    return _run_command([executable, *parts], timeout=timeout, label="Browser output", env=env)


@tool
def list_applications(query: str = "", max_results: int = 50) -> str:
    """Lists macOS applications that can be opened or automated.

    Use query to filter by name, for example "chrome", "safari", or "code".
    """
    if sys.platform != "darwin":
        return "Application listing is currently only implemented for macOS."

    matches = _find_matching_applications(query)
    if not matches:
        if query.strip():
            return f'No applications matched "{query.strip()}".'
        return "No applications found."

    selected = matches[: max(1, max_results)]
    lines = [f"{path.stem}: {path}" for path in selected]
    if len(matches) > len(selected):
        lines.append(f"... truncated after {len(selected)} applications")
    return _limit_tool_output("\n".join(lines), label="Application list")


@tool
def open_application(application: str, arguments: str = "", timeout: int = 30) -> str:
    """Opens a macOS application by name or .app path.

    Example application values: "Safari", "Google Chrome", "/Applications/Visual Studio Code.app"
    Optional arguments are passed after --args to the application.
    """
    if sys.platform != "darwin":
        return "Opening applications is currently only implemented for macOS."
    if not application.strip():
        return "Application name cannot be empty."

    matches = _find_matching_applications(application)
    if not matches:
        return f'No application matched "{application.strip()}".'
    if len(matches) > 1:
        options = "\n".join(f"- {path.stem}: {path}" for path in matches[:10])
        return (
            f'Multiple applications matched "{application.strip()}". Please be more specific:\n{options}'
        )

    target = matches[0]
    command = ["open", "-a", str(target)]
    if arguments.strip():
        try:
            command.extend(["--args", *shlex.split(arguments)])
        except ValueError as exc:
            return f"Invalid application arguments: {exc}"

    output = _run_command(command, timeout=timeout, label="Application output")
    if output == "(no output)":
        if arguments.strip():
            return f"Opened {target.stem} with arguments: {arguments}"
        return f"Opened {target.stem}."
    return output


@tool
def run_applescript(script: str, timeout: int = 30) -> str:
    """Runs AppleScript on macOS for GUI automation and app control.

    Use this for actions like activating apps, clicking menu items, sending shortcuts,
    or scripting System Events. Accessibility permissions may be required.
    """
    if sys.platform != "darwin":
        return "AppleScript automation is only available on macOS."
    if not script.strip():
        return "AppleScript cannot be empty."

    reason = _blocked_applescript_reason(script)
    if reason:
        return f"Blocked by safety policy: {reason}"

    args = ["/usr/bin/osascript"]
    for line in script.splitlines():
        stripped = line.rstrip()
        if stripped:
            args.extend(["-e", stripped])

    return _run_command(args, timeout=timeout, label="AppleScript output")


@tool
def shell(command: str, workdir: str = "", timeout: int = 30) -> str:
    """Executes a shell command and returns stdout/stderr output.

    Use this to run any shell command like git, npm, cargo, python, etc.
    Set workdir to run the command in a specific directory.
    The command times out after `timeout` seconds (default 30).
    """
    import subprocess

    if not command.strip():
        return "Command cannot be empty."

    reason = _blocked_shell_reason(command)
    if reason:
        return f"Blocked by safety policy: {reason}"

    cwd = None
    if workdir.strip():
        try:
            cwd = str(_assert_read_allowed(workdir))
        except PermissionError as exc:
            return str(exc)
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=timeout,
        )
        output = ""
        if result.stdout:
            output += result.stdout
        if result.stderr:
            if output:
                output += "\n"
            output += result.stderr
        if result.returncode != 0:
            output += f"\n[exit code: {result.returncode}]"
        return _limit_tool_output(output.strip() or "(no output)", label="Shell output")
    except subprocess.TimeoutExpired:
        return f"Command timed out after {timeout} seconds."
    except Exception as exc:
        return f"Failed to execute command: {exc}"


@tool
def read_file(filepath: str, start_line: int = 1, end_line: int = -1) -> str:
    """Reads the contents of a file.

    Optionally specify start_line and end_line to read a specific range.
    Use end_line=-1 (default) to read to the end of the file.
    Returns the file contents with line numbers prefixed.
    """
    if not filepath.strip():
        return "Filepath cannot be empty."

    try:
        resolved = _assert_read_allowed(filepath)
        with open(resolved, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return f"File not found: {filepath}"
    except PermissionError as exc:
        return str(exc)
    except IsADirectoryError:
        return f"Path is a directory, not a file: {filepath}"
    except Exception as exc:
        return f"Failed to read file: {exc}"

    total = len(lines)
    if total == 0:
        return f"(empty file: {filepath})"

    start = max(0, start_line - 1)
    end = total if end_line == -1 else min(total, end_line)

    if start >= total:
        return f"start_line {start_line} exceeds file length ({total} lines)."

    selected = lines[start:end]
    numbered = []
    for i, line in enumerate(selected, start=start + 1):
        numbered.append(f"{i:6d}\t{line.rstrip()}")

    header = f"--- {resolved} (lines {start + 1}-{start + len(selected)} of {total}) ---"
    return _limit_tool_output(header + "\n" + "\n".join(numbered), label="File contents")


@tool
def write_file(filepath: str, content: str, append: bool = False) -> str:
    """Writes content to a file, creating it and parent directories if needed.

    Set append=True to append to an existing file instead of overwriting.
    Returns a confirmation message with the number of lines written.
    """
    if not filepath.strip():
        return "Filepath cannot be empty."

    try:
        resolved = _assert_write_allowed(filepath)
        parent = os.path.dirname(str(resolved))
        if parent:
            os.makedirs(parent, exist_ok=True)

        mode = "a" if append else "w"
        with open(resolved, mode, encoding="utf-8") as f:
            f.write(content)

        line_count = content.count("\n") + (0 if content.endswith("\n") else 1) if content else 0
        action = "Appended to" if append else "Wrote"
        return f"{action} {resolved} ({line_count} lines)"
    except PermissionError:
        return (
            "Permission denied: write access is blocked for this path. "
            "Update DEEP_AGENT_ALLOWED_WRITE_ROOTS if you want to allow it."
        )
    except Exception as exc:
        return f"Failed to write file: {exc}"


@tool
def list_files(directory: str = ".", pattern: str = "", recursive: bool = True) -> str:
    """Lists files and directories in a given path.

    Use pattern to filter by glob pattern (e.g., '*.py', '**/*.ts').
    Set recursive=False to only list immediate children.
    Returns a formatted listing with file sizes.
    """
    if not directory.strip():
        directory = "."

    try:
        resolved_directory = _assert_read_allowed(directory)
        if not os.path.exists(resolved_directory):
            return f"Directory not found: {directory}"
        if not os.path.isdir(resolved_directory):
            return f"Path is not a directory: {directory}"

        entries = []
        max_entries = _list_files_max_entries()
        truncated = False
        if pattern:
            import glob as glob_mod

            search = os.path.join(str(resolved_directory), pattern)
            paths = glob_mod.glob(search, recursive=recursive)
        elif recursive:
            for root, dirs, files in os.walk(resolved_directory):
                rel_root = os.path.relpath(root, resolved_directory)
                for d in sorted(dirs):
                    path = os.path.join(rel_root, d) if rel_root != "." else d
                    entries.append(f"  {path}/")
                    if len(entries) >= max_entries:
                        truncated = True
                        break
                if truncated:
                    break
                for f in sorted(files):
                    path = os.path.join(rel_root, f) if rel_root != "." else f
                    full = os.path.join(root, f)
                    size = os.path.getsize(full)
                    entries.append(f"  {path}  ({_format_size(size)})")
                    if len(entries) >= max_entries:
                        truncated = True
                        break
                if truncated:
                    break
            if truncated:
                entries.append(f"  ... truncated after {max_entries} entries")
            return _limit_tool_output("\n".join(entries) if entries else "(empty directory)", label="File listing")
        else:
            paths = [
                os.path.join(str(resolved_directory), name)
                for name in sorted(os.listdir(resolved_directory))
            ]

        sorted_paths = sorted(paths)
        for p in sorted_paths[:max_entries]:
            rel = os.path.relpath(p, resolved_directory)
            if os.path.isdir(p):
                entries.append(f"  {rel}/")
            else:
                size = os.path.getsize(p)
                entries.append(f"  {rel}  ({_format_size(size)})")
        if len(sorted_paths) > max_entries:
            entries.append(f"  ... truncated after {max_entries} entries")

        return _limit_tool_output("\n".join(entries) if entries else "(empty directory)", label="File listing")
    except PermissionError as exc:
        return str(exc)
    except Exception as exc:
        return f"Failed to list files: {exc}"


def _format_size(size: int) -> str:
    s = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if abs(s) < 1024:
            return f"{s:.0f} {unit}" if unit == "B" else f"{s:.1f} {unit}"
        s /= 1024
    return f"{s:.1f} TB"


@tool
def search_files(
    pattern: str,
    directory: str = ".",
    file_glob: str = "",
    case_sensitive: bool = False,
    max_results: int = 100,
) -> str:
    """Searches for a regex pattern in files under a directory.

    Returns matching lines with filenames and line numbers.
    Use file_glob to filter which files to search (e.g., '*.py', '*.rs').
    Set case_sensitive=True for case-sensitive matching.
    Results are limited to max_results (default 100).
    """
    import re
    import glob as glob_mod

    if not pattern.strip():
        return "Search pattern cannot be empty."

    try:
        resolved_directory = _assert_read_allowed(directory)
    except PermissionError as exc:
        return str(exc)

    if not os.path.isdir(resolved_directory):
        return f"Directory not found: {directory}"

    flags = 0 if case_sensitive else re.IGNORECASE
    try:
        regex = re.compile(pattern, flags)
    except re.error as exc:
        return f"Invalid regex pattern: {exc}"

    if file_glob:
        search_pattern = os.path.join(str(resolved_directory), "**", file_glob)
    else:
        search_pattern = os.path.join(str(resolved_directory), "**", "*")

    results = []
    count = 0
    try:
        for filepath in glob_mod.glob(search_pattern, recursive=True):
            if count >= max_results:
                break
            if os.path.isdir(filepath):
                continue
            try:
                with open(filepath, "r", encoding="utf-8", errors="replace") as f:
                    for line_num, line in enumerate(f, start=1):
                        if count >= max_results:
                            break
                        if regex.search(line):
                            rel = os.path.relpath(filepath, resolved_directory)
                            results.append(f"{rel}:{line_num}: {line.rstrip()}")
                            count += 1
            except (PermissionError, OSError):
                continue
    except Exception as exc:
        return f"Search failed: {exc}"

    if not results:
        return f"No matches found for pattern: {pattern}"

    summary = f"Found {count} match{'es' if count != 1 else ''} (showing {len(results)})"
    return _limit_tool_output(summary + "\n" + "\n".join(results), label="Search results")


def build_agent():
    llm = _build_llm()
    tools = [
        get_tauri_context,
        search_web,
        browser,
        list_applications,
        open_application,
        run_applescript,
        shell,
        read_file,
        write_file,
        list_files,
        search_files,
    ]

    if create_agent is not None:
        return create_agent(
            model=llm,
            tools=tools,
            system_prompt=(
                "You are a versatile coding assistant with access to the local filesystem and shell."
                " You can read files, write files, run commands, search code, browse the web,"
                " automate a browser, and control macOS applications."
                " Respect the active filesystem and shell safety policies."
                " Prefer the dedicated browser and application tools over generic shell commands"
                " when interacting with websites or apps."
                " Always prefer reading existing code before making changes."
                " When editing files, make minimal, focused changes."
                " Show relevant file contents with line numbers when discussing code."
            ),
        )

    if not create_agent and AgentType is None:  # type: ignore[name-defined]
        raise RuntimeError("LangChain agent API is unavailable.")

    agent_type = (
        AgentType.OPENAI_TOOLS
        if hasattr(AgentType, "OPENAI_TOOLS")
        else AgentType.OPENAI_FUNCTIONS
    )
    return initialize_agent(tools=tools, llm=llm, agent=agent_type, verbose=False)


def run(question: str) -> str:
    agent = build_agent()
    if create_agent is not None and not _HAS_LEGACY_AGENT:
        return _run_new_api(agent, question)

    return _run_legacy_api(agent, question)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the Tauri deep agent.")
    parser.add_argument("--question", required=True, help="Question for the agent.")
    parser.add_argument("--stream", action="store_true", help="Stream the response as JSON events.")
    args = parser.parse_args()

    try:
        if args.stream:
            asyncio.run(_stream_agent_response(args.question))
            return 0
        else:
            answer = run(args.question)
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        return 2
    except Exception as error:
        print(f"Agent failed: {error}", file=sys.stderr)
        return 1

    print(answer)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
