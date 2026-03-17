#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

from langchain_core.tools import tool
from langchain_core.messages import BaseMessage
from langchain_openai import ChatOpenAI
from perplexity import Perplexity


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


async def _stream_agent_response(question: str) -> None:
    """Stream the agent response as JSON events to stdout."""
    try:
        agent = build_agent()
        
        if create_agent is not None and not _HAS_LEGACY_AGENT:
            # New API - use astream_events for better streaming
            try:
                async for event in agent.astream_events({"messages": [{"type": "human", "content": question}]}, version="v2"):
                    if event.get("event") == "on_chat_model_stream":
                        data = event.get("data", {})
                        chunk = data.get("chunk")
                        if chunk and hasattr(chunk, "content"):
                            content = chunk.content
                            if content:
                                event_data = json.dumps({"type": "chunk", "content": str(content)})
                                print(event_data, flush=True)
                
                print(json.dumps({"type": "done"}), flush=True)
            except (AttributeError, TypeError):
                # Fallback: try direct LLM streaming
                llm = ChatOpenAI(
                    model=os.getenv("OPENAI_MODEL", "gpt-5-nano-2025-08-07"),
                    temperature=float(os.getenv("OPENAI_TEMPERATURE", "0")),
                    max_tokens=int(os.getenv("OPENAI_MAX_TOKENS", "1200")),
                    api_key=os.getenv("OPENAI_API_KEY", "").strip(),
                    streaming=True,
                )
                
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
        sys.exit(1)


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
def shell(command: str, workdir: str = "", timeout: int = 30) -> str:
    """Executes a shell command and returns stdout/stderr output.

    Use this to run any shell command like git, npm, cargo, python, etc.
    Set workdir to run the command in a specific directory.
    The command times out after `timeout` seconds (default 30).
    """
    import subprocess

    if not command.strip():
        return "Command cannot be empty."

    cwd = workdir if workdir.strip() else None
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
        return output.strip() or "(no output)"
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
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return f"File not found: {filepath}"
    except PermissionError:
        return f"Permission denied: {filepath}"
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

    header = f"--- {filepath} (lines {start + 1}-{start + len(selected)} of {total}) ---"
    return header + "\n" + "\n".join(numbered)


@tool
def write_file(filepath: str, content: str, append: bool = False) -> str:
    """Writes content to a file, creating it and parent directories if needed.

    Set append=True to append to an existing file instead of overwriting.
    Returns a confirmation message with the number of lines written.
    """
    if not filepath.strip():
        return "Filepath cannot be empty."

    try:
        parent = os.path.dirname(filepath)
        if parent:
            os.makedirs(parent, exist_ok=True)

        mode = "a" if append else "w"
        with open(filepath, mode, encoding="utf-8") as f:
            f.write(content)

        line_count = content.count("\n") + (0 if content.endswith("\n") else 1) if content else 0
        action = "Appended to" if append else "Wrote"
        return f"{action} {filepath} ({line_count} lines)"
    except PermissionError:
        return f"Permission denied: {filepath}"
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
        if not os.path.exists(directory):
            return f"Directory not found: {directory}"
        if not os.path.isdir(directory):
            return f"Path is not a directory: {directory}"

        entries = []
        if pattern:
            import glob as glob_mod

            search = os.path.join(directory, pattern)
            paths = glob_mod.glob(search, recursive=recursive)
        elif recursive:
            for root, dirs, files in os.walk(directory):
                rel_root = os.path.relpath(root, directory)
                for d in sorted(dirs):
                    path = os.path.join(rel_root, d) if rel_root != "." else d
                    entries.append(f"  {path}/")
                for f in sorted(files):
                    path = os.path.join(rel_root, f) if rel_root != "." else f
                    full = os.path.join(root, f)
                    size = os.path.getsize(full)
                    entries.append(f"  {path}  ({_format_size(size)})")
            return "\n".join(entries) if entries else "(empty directory)"
        else:
            paths = [
                os.path.join(directory, name) for name in sorted(os.listdir(directory))
            ]

        for p in sorted(paths):
            rel = os.path.relpath(p, directory)
            if os.path.isdir(p):
                entries.append(f"  {rel}/")
            else:
                size = os.path.getsize(p)
                entries.append(f"  {rel}  ({_format_size(size)})")

        return "\n".join(entries) if entries else "(empty directory)"
    except PermissionError:
        return f"Permission denied: {directory}"
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

    if not os.path.isdir(directory):
        return f"Directory not found: {directory}"

    flags = 0 if case_sensitive else re.IGNORECASE
    try:
        regex = re.compile(pattern, flags)
    except re.error as exc:
        return f"Invalid regex pattern: {exc}"

    if file_glob:
        search_pattern = os.path.join(directory, "**", file_glob)
    else:
        search_pattern = os.path.join(directory, "**", "*")

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
                            rel = os.path.relpath(filepath, directory)
                            results.append(f"{rel}:{line_num}: {line.rstrip()}")
                            count += 1
            except (PermissionError, OSError):
                continue
    except Exception as exc:
        return f"Search failed: {exc}"

    if not results:
        return f"No matches found for pattern: {pattern}"

    summary = f"Found {count} match{'es' if count != 1 else ''} (showing {len(results)})"
    return summary + "\n" + "\n".join(results)


def build_agent():
    api_key = os.getenv("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError(
            "OPENAI_API_KEY is missing. Set it in your environment before running the agent."
        )

    llm = ChatOpenAI(
        model=os.getenv("OPENAI_MODEL", "gpt-5-nano-2025-08-07"),
        temperature=float(os.getenv("OPENAI_TEMPERATURE", "0")),
        max_tokens=int(os.getenv("OPENAI_MAX_TOKENS", "1200")),
        api_key=api_key,
    )
    tools = [
        get_tauri_context,
        search_web,
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
                " You can read files, write files, run commands, search code, and browse the web."
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
