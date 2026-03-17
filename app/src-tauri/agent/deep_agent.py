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
    tools = [get_tauri_context, search_web]

    if create_agent is not None:
        return create_agent(
            model=llm,
            tools=tools,
            system_prompt=(
                "You are a deep assistant for the local Tauri app."
                " Provide a clear and concise answer to user questions."
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
