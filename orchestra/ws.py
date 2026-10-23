import logging
from typing import Dict, List
from fastapi import WebSocket

logger = logging.getLogger(__name__)

class ConnectionManager:
    def __init__(self):
        self.active: Dict[str, List[WebSocket]] = {}

    async def connect(self, ws: WebSocket, project_id: str):
        await ws.accept()
        self.active.setdefault(project_id, [])
        self.active[project_id].append(ws)

    def disconnect(self, ws: WebSocket, project_id: str):
        if project_id in self.active:
            try:
                self.active[project_id].remove(ws)
            except ValueError:
                pass

    async def broadcast_json(self, project_id: str, data: dict):
        dead = []
        for ws in self.active.get(project_id, []):
            try:
                await ws.send_json(data)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.disconnect(ws, project_id)

manager = ConnectionManager()
