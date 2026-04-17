"""LangGraph agent implementation with deep reasoning capabilities"""

import json
from typing import TypedDict, Annotated, List, Optional, Dict, Any, Sequence
from datetime import datetime
import operator

from langchain_core.messages import BaseMessage, HumanMessage, AIMessage, SystemMessage, ToolMessage
from langchain_core.prompts import ChatPromptTemplate
from langchain_openai import ChatOpenAI
from langgraph.graph import StateGraph, END
from langgraph.prebuilt import ToolNode
from langgraph.checkpoint.memory import MemorySaver

from app.config import settings
from app.agent.tools import ALL_TOOLS
from app.agent.prompts import SYSTEM_PROMPT
from app.memory.conversation import ConversationBuffer
from app.memory.vectorstore import LongTermMemory


class AgentState(TypedDict):
    """State for the agent graph"""
    messages: Annotated[List[BaseMessage], operator.add]
    current_plan: str
    current_step: int
    observations: List[str]
    tool_results: List[Dict[str, Any]]
    should_continue: bool
    final_response: Optional[str]


class DeepAgent:
    """LangGraph-based deep agent with reasoning, tool use, and memory"""
    
    def __init__(
        self,
        model: str = None,
        conversation_buffer: Optional[ConversationBuffer] = None,
        long_term_memory: Optional[LongTermMemory] = None,
        max_iterations: int = None
    ):
        self.model_name = model or settings.default_model
        self.max_iterations = max_iterations or settings.max_iterations
        self.conversation_buffer = conversation_buffer or ConversationBuffer()
        self.long_term_memory = long_term_memory
        
        self.llm = ChatOpenAI(
            model=self.model_name,
            openai_api_base=settings.openrouter_base_url,
            openai_api_key=settings.openrouter_api_key,
            temperature=0.7
        )
        
        self.llm_with_tools = self.llm.bind_tools(ALL_TOOLS)
        
        self.tool_executor = ToolNode(ALL_TOOLS)
        
        self.graph = self._build_graph()
        self.memory_saver = MemorySaver()
        self.compiled_graph = self.graph.compile(checkpointer=self.memory_saver)
    
    def _build_graph(self) -> StateGraph:
        """Build the agent reasoning graph"""
        workflow = StateGraph(AgentState)
        
        workflow.add_node("agent", self._agent_node)
        workflow.add_node("tools", self._tools_node)
        workflow.add_node("reason", self._reason_node)
        workflow.add_node("respond", self._respond_node)
        
        workflow.set_entry_point("agent")
        
        workflow.add_conditional_edges(
            "agent",
            self._should_use_tools,
            {
                "tools": "tools",
                "respond": "respond",
                "reason": "reason"
            }
        )
        
        workflow.add_edge("tools", "reason")
        
        workflow.add_conditional_edges(
            "reason",
            self._should_continue,
            {
                "continue": "agent",
                "respond": "respond",
                "end": END
            }
        )
        
        workflow.add_edge("respond", END)
        
        return workflow
    
    def _agent_node(self, state: AgentState) -> Dict[str, Any]:
        """Main agent reasoning node"""
        messages = state["messages"]
        iteration_count = sum(1 for m in messages if isinstance(m, AIMessage))
        print(f"[agent_node] iteration={iteration_count}, messages={len(messages)}")

        if iteration_count > self.max_iterations:
            print(f"[agent_node] max iterations ({self.max_iterations}) reached, stopping")
            return {
                "should_continue": False,
                "final_response": "Maximum iterations reached. Please clarify your request."
            }

        if self.conversation_buffer.messages:
            context_messages = self.conversation_buffer.get_messages()
            messages = context_messages + list(messages)

        system_message = SystemMessage(content=SYSTEM_PROMPT)
        full_messages = [system_message] + list(messages)
        print(f"[agent_node] sending {len(full_messages)} messages to {self.model_name}")

        response = self.llm_with_tools.invoke(full_messages)
        print(f"[agent_node] response type={type(response).__name__}, tool_calls={getattr(response, 'tool_calls', [])}")

        return {"messages": [response]}
    
    def _tools_node(self, state: AgentState) -> Dict[str, Any]:
        """Execute tools called by the agent"""
        messages = state["messages"]
        last_message = messages[-1]
        
        if not hasattr(last_message, "tool_calls") or not last_message.tool_calls:
            return {}
        
        tool_messages = []
        tool_results = []
        
        for tool_call in last_message.tool_calls:
            tool_name = tool_call["name"]
            tool_args = tool_call["args"]
            print(f"[tools_node] calling tool={tool_name}, args={tool_args}")

            tool_result = self._execute_tool(tool_name, tool_args)
            print(f"[tools_node] tool={tool_name} result={str(tool_result)[:300]}")

            tool_messages.append(
                ToolMessage(
                    content=json.dumps(tool_result) if isinstance(tool_result, dict) else str(tool_result),
                    tool_call_id=tool_call["id"]
                )
            )
            
            tool_results.append({
                "tool": tool_name,
                "args": tool_args,
                "result": tool_result,
                "timestamp": datetime.now().isoformat()
            })
        
        return {
            "messages": tool_messages,
            "tool_results": tool_results
        }
    
    def _execute_tool(self, tool_name: str, args: Dict[str, Any]) -> Any:
        """Execute a single tool"""
        for tool in ALL_TOOLS:
            if tool.name == tool_name:
                try:
                    return tool.invoke(args)
                except Exception as e:
                    return {"error": str(e)}
        return {"error": f"Unknown tool: {tool_name}"}
    
    def _reason_node(self, state: AgentState) -> Dict[str, Any]:
        """Analyze tool results and decide next action"""
        observations = state.get("observations", [])
        tool_results = state.get("tool_results", [])
        current_step = state.get("current_step", 0) + 1
        print(f"[reason_node] step={current_step}, total_observations={len(observations)}")

        if tool_results:
            last_result = tool_results[-1]
            observation = f"Tool: {last_result['tool']}, Result: {last_result['result'][:200]}..."
            observations.append(observation)
            print(f"[reason_node] new observation: {observation[:200]}")

        return {
            "observations": observations,
            "current_step": current_step
        }
    
    def _respond_node(self, state: AgentState) -> Dict[str, Any]:
        """Generate final response"""
        messages = state["messages"]
        print(f"[respond_node] building final response from {len(messages)} messages")

        last_ai_message = None
        for msg in reversed(messages):
            if isinstance(msg, AIMessage):
                last_ai_message = msg
                break

        if last_ai_message and last_ai_message.content:
            self.conversation_buffer.add_message(last_ai_message)
            final_response = last_ai_message.content
            print(f"[respond_node] final response ({len(final_response)} chars): {final_response[:200]}")
            return {
                "final_response": final_response,
                "should_continue": False
            }

        print("[respond_node] no AI message found, returning fallback")
        return {
            "final_response": "I apologize, but I couldn't generate a response. Please try again.",
            "should_continue": False
        }
    
    def _should_use_tools(self, state: AgentState) -> str:
        """Determine if tools should be used"""
        messages = state["messages"]
        last_message = messages[-1]
        
        if hasattr(last_message, "tool_calls") and last_message.tool_calls:
            return "tools"
        
        if hasattr(last_message, "content") and last_message.content:
            return "respond"
        
        return "reason"
    
    def _should_continue(self, state: AgentState) -> str:
        """Determine if agent should continue or end"""
        messages = state["messages"]
        last_message = messages[-1]
        
        if state.get("should_continue") is False:
            return "end"
        
        if hasattr(last_message, "tool_calls") and last_message.tool_calls:
            return "continue"
        
        return "respond"
    
    async def astream(self, user_input: str, thread_id: str = "default"):
        """Stream agent responses with token-level streaming"""
        config = {"configurable": {"thread_id": thread_id}}
        
        human_message = HumanMessage(content=user_input)
        self.conversation_buffer.add_message(human_message)
        
        initial_state = {
            "messages": [human_message],
            "current_plan": "",
            "current_step": 0,
            "observations": [],
            "tool_results": [],
            "should_continue": True,
            "final_response": None
        }
        
        accumulated = ""
        async for event in self.compiled_graph.astream(initial_state, config, stream_mode="updates"):
            for node_name, node_output in event.items():
                # Yield node-level event
                yield {
                    "type": "node",
                    "node": node_name,
                    "output": self._serialize_output(node_output)
                }
                
                # If this is the respond node, stream the final_response text token-by-token
                if node_name == "respond":
                    final_response = node_output.get("final_response")
                    if final_response:
                        chunk_size = 4
                        for i in range(0, len(final_response), chunk_size):
                            chunk = final_response[i:i + chunk_size]
                            accumulated = final_response[:i + chunk_size]
                            yield {
                                "type": "token",
                                "node": node_name,
                                "content": chunk,
                                "accumulated": accumulated
                            }
    
    async def ainvoke(self, user_input: str, thread_id: str = "default") -> Dict[str, Any]:
        """Invoke agent and returnfinal response"""
        config = {"configurable": {"thread_id": thread_id}}
        
        human_message = HumanMessage(content=user_input)
        self.conversation_buffer.add_message(human_message)
        
        initial_state = {
            "messages": [human_message],
            "current_plan": "",
            "current_step": 0,
            "observations": [],
            "tool_results": [],
            "should_continue": True,
            "final_response": None
        }
        
        result = await self.compiled_graph.ainvoke(initial_state, config)
        
        ai_message = None
        for msg in reversed(result["messages"]):
            if isinstance(msg, AIMessage):
                ai_message = msg
                break
        
        return {
            "response": ai_message.content if ai_message else None,
            "tool_calls": result.get("tool_results", []),
            "observations": result.get("observations", [])
        }
    
    def _serialize_output(self, output: Dict[str, Any]) -> Dict[str, Any]:
        """Serialize output for JSON response"""
        serialized = {}
        for key, value in output.items():
            if isinstance(value, list):
                serialized[key] = [
                    {"type": msg.type, "content": str(msg.content)[:500]}
                    if hasattr(msg, "type") else str(msg)[:500]
                    for msg in value
                ]
            elif isinstance(value, str):
                serialized[key] = value[:500]
            else:
                serialized[key] = str(value)[:500]
        return serialized
    
    def reset_conversation(self):
        """Reset conversation history"""
        self.conversation_buffer.clear()
        self.memory_saver = MemorySaver()
        self.compiled_graph = self.graph.compile(checkpointer=self.memory_saver)


agent: Optional[DeepAgent] = None


def get_agent() -> DeepAgent:
    """Get or create the agent singleton"""
    global agent
    if agent is None:
        agent = DeepAgent()
    return agent