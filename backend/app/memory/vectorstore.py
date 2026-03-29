"""Long-term memory using FAISS vector store"""

import json
from pathlib import Path
from typing import List, Optional, Dict, Any
from datetime import datetime

from langchain_community.vectorstores import FAISS
from langchain_openai import OpenAIEmbeddings
from langchain_core.documents import Document
from app.config import settings


class LongTermMemory:
    """Persistent vector-based memory for long-term recall"""
    
    def __init__(self):
        self.persist_path = settings.ensure_memory_dir()
        self.index_path = self.persist_path / "faiss_index"
        self.metadata_path =self.persist_path / "memory_metadata.json"
        
        self.embeddings = OpenAIEmbeddings(
            base_url=settings.openrouter_base_url,
            api_key=settings.openrouter_api_key,
            model=settings.embedding_model,
            check_embedding_ctx_length=False
        )
        
        self.vectorstore: Optional[FAISS] = None
        self._load_or_create()
    
    def _load_or_create(self) -> None:
        """Load existing index or create new one"""
        try:
            if self.index_path.exists():
                self.vectorstore = FAISS.load_local(
                    str(self.index_path),
                    self.embeddings,
                    allow_dangerous_deserialization=True
                )
            else:
                self.vectorstore = FAISS.from_texts(
                    ["Initial memory initialization"],
                    self.embeddings
                )
        except Exception as e:
            print(f"Memory init error: {e}")
            self.vectorstore = FAISS.from_texts(
                ["Initial memory initialization"],
                self.embeddings
            )    
    def store(self, content: str, metadata: Optional[Dict[str, Any]] = None) -> None:
        """Store information in long-term memory"""
        if metadata is None:
            metadata = {}
        
        metadata["timestamp"] = datetime.now().isoformat()
        metadata["type"] = metadata.get("type", "fact")
        
        doc = Document(page_content=content, metadata=metadata)
        self.vectorstore.add_documents([doc])
        self._save()
    
    def recall(self, query: str, k: int = 5) -> List[Dict[str, Any]]:
        """Retrieve relevant memories"""
        if not self.vectorstore:
            return []
        
        results = self.vectorstore.similarity_search_with_score(query, k=k)
        
        memories = []
        for doc, score in results:
            memories.append({
                "content": doc.page_content,
                "relevance": 1.0 - score,
                "metadata": doc.metadata
            })
        
        return memories
    
    def get_all_memories(self) -> List[Dict[str, Any]]:
        """Get all stored memories"""
        if not self.vectorstore:
            return []
        
        return [
            {"content": doc.page_content, "metadata": doc.metadata}
            for doc in self.vectorstore.docstore._dict.values()
        ]
    
    def clear(self) -> None:
        """Clear all memories"""
        self.vectorstore = FAISS.from_texts(
            ["Memory cleared"],
            self.embeddings
        )
        self._save()
    
    def _save(self) -> None:
        """Persist the vector store to disk"""
        if self.vectorstore:
            self.vectorstore.save_local(str(self.index_path))