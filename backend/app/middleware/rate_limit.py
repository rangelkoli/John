"""Rate limiting middleware"""

import time
from typing import Dict, Optional
from collections import defaultdict
from datetime import datetime, timedelta

from fastapi import HTTPException, Request, status


class RateLimiter:
    """Simple in-memory rate limiter"""

    def __init__(self, requests_per_minute: int = 30):
        self.requests_per_minute = requests_per_minute
        self.requests: Dict[str, list] = defaultdict(list)

    def _get_client_id(self, request: Request) -> str:
        """Get client identifier from request"""
        forwarded = request.headers.get("X-Forwarded-For")
        if forwarded:
            return forwarded.split(",")[0].strip()
        return request.client.host if request.client else "unknown"

    def check(self, request: Request) -> bool:
        """Check if request is allowed, returns True if allowed"""
        client_id = self._get_client_id(request)
        now = time.time()
        cutoff = now - 60

        self.requests[client_id] = [
            ts for ts in self.requests[client_id] if ts > cutoff
        ]

        if len(self.requests[client_id]) >= self.requests_per_minute:
            return False

        self.requests[client_id].append(now)
        return True

    def get_remaining(self, request: Request) -> int:
        """Get remaining requests for client"""
        client_id = self._get_client_id(request)
        now = time.time()
        cutoff = now - 60

        self.requests[client_id] = [
            ts for ts in self.requests[client_id] if ts > cutoff
        ]

        return max(0, self.requests_per_minute - len(self.requests[client_id]))


rate_limiter = RateLimiter()


def require_rate_limit(request: Request):
    """Dependency to enforce rate limiting"""
    if not rate_limiter.check(request):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Rate limit exceeded. Please try again later.",
        )
