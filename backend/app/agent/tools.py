"""Tool definitions for the deep agent"""

import json
import subprocess
import os
from pathlib import Path
from typing import Optional, Type, Dict, Any
from datetime import datetime

from langchain_core.tools import BaseTool, tool
from pydantic import BaseModel, Field

from app.memory.vectorstore import LongTermMemory
from app.config import settings


class FileReadInput(BaseModel):
    filepath: str = Field(description="Path to the file to read")
    

class FileWriteInput(BaseModel):
    filepath: str = Field(description="Path to the file to write")
    content: str = Field(description="Content to write to the file")


class ShellExecuteInput(BaseModel):
    command: str = Field(description="Shell command to execute")
    timeout: int = Field(default=30, description="Timeout in seconds")


class WebSearchInput(BaseModel):
    query: str = Field(description="Search query")


class MemoryStoreInput(BaseModel):
    content: str = Field(description="Information to store in long-term memory")
    memory_type: str = Field(default="fact", description="Type: fact, preference, or context")


class MemoryRecallInput(BaseModel):
    query: str = Field(description="Query to search memories")
    k: int = Field(default=5, description="Number of memories to retrieve")


class CodeExecuteInput(BaseModel):
    code: str = Field(description="Python code to execute")
    timeout: int = Field(default=30, description="Timeout in seconds")


# Memory singleton
_memory: Optional[LongTermMemory] = None


def get_memory() -> LongTermMemory:
    global _memory
    if _memory is None:
        _memory = LongTermMemory()
    return _memory


@tool
def file_read(filepath: str) -> str:
    """Read contents of a file from the filesystem.
    
    Args:
        filepath: Path to the file to read
        
    Returns:
        File contents as string
    """
    try:
        path = Path(filepath).expanduser().resolve()
        if not path.exists():
            return f"Error: File not found: {filepath}"
        if not path.is_file():
            return f"Error: Not a file: {filepath}"
        
        with open(path, 'r', encoding='utf-8') as f:
            content = f.read()
        return content
    except Exception as e:
        return f"Error reading file: {str(e)}"


@tool
def file_write(filepath: str, content: str) -> str:
    """Write content to a file on the filesystem.
    
    Args:
        filepath: Path to the file to write
        content: Content to write
        
    Returns:
        Success or error message
    """
    try:
        path = Path(filepath).expanduser().resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return f"Successfully wrote {len(content)} characters to {filepath}"
    except Exception as e:
        return f"Error writing file: {str(e)}"


@tool
def shell_execute(command: str, timeout: int = 30) -> str:
    """Execute a shell command safely.
    
    Args:
        command: Shell command to execute
        timeout: Timeout in seconds (default 30)
        
    Returns:
        Command output or error
    """
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(Path.home())
        )
        
        output = []
        if result.stdout:
            output.append(f"STDOUT:\n{result.stdout}")
        if result.stderr:
            output.append(f"STDERR:\n{result.stderr}")
        
        return "\n".join(output) if output else "Command completed with no output"
    except subprocess.TimeoutExpired:
        return f"Error: Command timed out after {timeout} seconds"
    except Exception as e:
        return f"Error executing command: {str(e)}"


@tool
def web_search(query: str) -> str:
    """Search the web for information (simulated - requires SerperAPI key for real search).
    
    Args:
        query: Search query
        
    Returns:
        Search results or instructions
    """
    return f"Web search for '{query}' - Note: To enable real web search, configure SerperAPI key in environment. This is a placeholder response."


@tool
def memory_store(content: str, memory_type: str = "fact") -> str:
    """Store information in long-term memory for future recall.
    
    Args:
        content: Information to store
        memory_type: Type of memory (fact, preference, context)
        
    Returns:
        Confirmation message
    """
    try:
        memory = get_memory()
        memory.store(content, {"type": memory_type})
        return f"Stored in long-term memory: {content[:100]}..."
    except Exception as e:
        return f"Error storing memory: {str(e)}"


@tool
def memory_recall(query: str, k: int = 5) -> str:
    """Recall relevant information from long-term memory.
    
    Args:
        query: Query to search memories
        k: Number of memories to retrieve
        
    Returns:
        Retrieved memories formatted as string
    """
    try:
        memory = get_memory()
        results = memory.recall(query, k=k)
        
        if not results:
            return "No relevant memories found."
        
        formatted = []
        for i, mem in enumerate(results, 1):
            formatted.append(f"{i}. {mem['content']}")
        
        return "\n".join(formatted)
    except Exception as e:
        return f"Error recalling memory: {str(e)}"


@tool
def code_execute(code: str, timeout: int = 30) -> str:
    """Execute Python code and return the result.
    
    Args:
        code: Python code to execute
        timeout: Timeout in seconds
        
    Returns:
        Execution result or error
    """
    try:
        result = subprocess.run(
            ["python3", "-c", code],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        
        output = []
        if result.stdout:
            output.append(f"Output:\n{result.stdout}")
        if result.stderr:
            output.append(f"Error:\n{result.stderr}")
        
        return "\n".join(output) if output else "Code executed successfully with no output"
    except subprocess.TimeoutExpired:
        return f"Error: Code execution timed out after {timeout} seconds"
    except Exception as e:
        return f"Error executing code: {str(e)}"


@tool
def get_current_time() -> str:
    """Get the current date and time.
    
    Returns:
        Current datetime as ISO format string
    """
    return datetime.now().isoformat()


@tool
def list_directory(path: str = "~") -> str:
    """List contents of a directory.
    
    Args:
        path: Directory path (default: home directory)
        
    Returns:
        Directory listing
    """
    try:
        dir_path = Path(path).expanduser().resolve()
        if not dir_path.exists():
            return f"Error: Directory not found: {path}"
        if not dir_path.is_dir():
            return f"Error: Not a directory: {path}"
        
        items = []
        for item in sorted(dir_path.iterdir()):
            item_type = "DIR" if item.is_dir() else "FILE"
            items.append(f"{item_type:5} {item.name}")
        
        return "\n".join(items) if items else "Directory is empty"
    except Exception as e:
        return f"Error listing directory: {str(e)}"


# All available tools for the agent
ALL_TOOLS = [
    file_read,
    file_write,
    shell_execute,
    web_search,
    memory_store,
    memory_recall,
    code_execute,
    get_current_time,
    list_directory,
]