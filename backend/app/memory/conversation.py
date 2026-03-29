"""Memory module - Conversation and Long-term memory management"""

from typing import List, Optional
from langchain_core.messages import BaseMessage, HumanMessage, AIMessage, SystemMessage
from langchain_core.chat_history import BaseChatMessageHistory
from app.config import settings


class ConversationBuffer(BaseChatMessageHistory):
    """In-memory conversation buffer with window management"""
    
    messages: List[BaseMessage] = []
    max_messages: int = settings.conversation_window
    
    def add_message(self, message: BaseMessage) -> None:
        self.messages.append(message)
        self._trim_if_needed()
    
    def _trim_if_needed(self) -> None:
        if len(self.messages) > self.max_messages * 2:
            self.messages = self.messages[-self.max_messages:]
    
    def clear(self) -> None:
        self.messages = []
    
    def get_messages(self) -> List[BaseMessage]:
        return self.messages.copy()
    
    def get_context_string(self) -> str:
        """Format messages as a context string for the model"""
        lines = []
        for msg in self.messages[-self.max_messages:]:
            role = msg.type.upper()
            lines.append(f"{role}: {msg.content}")
        return "\n\n".join(lines)