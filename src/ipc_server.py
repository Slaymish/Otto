"""
ipc_server.py — asyncio TCP server for SwiftUI ↔ Python IPC.

Protocol: newline-delimited JSON on localhost TCP (127.0.0.1, random port).

Python → Swift messages:
  {"type": "ready"}
  {"type": "waveform", "level": 0.82, "active": true}
  {"type": "transcript", "text": "open spotify"}
  {"type": "spoken", "text": "Opening Spotify"}
  {"type": "tool_call", "name": "run_applescript", "ok": true}
  {"type": "error", "message": "..."}

Swift → Python messages:
  {"type": "voice_start"}
  {"type": "voice_stop"}
  {"type": "text_input", "text": "open spotify"}
  {"type": "request_journal"}
  {"type": "undo_learning", "id": "<capability-id>"}
  {"type": "edit_capability", "id": "<capability-id>", "description": "...", "examples": [...]}
  {"type": "delete_capability", "id": "<capability-id>"}
  {"type": "ping"}

On startup the port is printed to stdout as:  IPC_PORT=<n>
"""
from __future__ import annotations

import asyncio
import json
from typing import Callable


class IPCServer:
    def __init__(self) -> None:
        self._clients: set[asyncio.StreamWriter] = set()
        self._server: asyncio.AbstractServer | None = None
        # Register async or sync callables before calling start().
        self.on_voice_start: Callable | None = None
        self.on_voice_stop: Callable | None = None
        self.on_text_input: Callable[[str], None] | None = None
        self.on_request_journal: Callable | None = None
        self.on_undo_learning: Callable[[str], None] | None = None
        self.on_edit_capability: Callable[[str, "str | None", "list | None"], None] | None = None
        self.on_delete_capability: Callable[[str], None] | None = None

    async def start(self) -> int:
        """Bind to a random localhost port, announce it, return the port number."""
        self._server = await asyncio.start_server(
            self._handle_client, "127.0.0.1", 0
        )
        port: int = self._server.sockets[0].getsockname()[1]
        print(f"IPC_PORT={port}", flush=True)
        asyncio.ensure_future(self._server.serve_forever())
        return port

    def broadcast(self, msg: dict) -> None:
        """Fire-and-forget: write a JSON line to every connected Swift client."""
        if not self._clients:
            return
        line = (json.dumps(msg) + "\n").encode()
        dead: set[asyncio.StreamWriter] = set()
        for writer in self._clients:
            try:
                writer.write(line)
            except Exception:  # noqa: BLE001
                dead.add(writer)
        self._clients -= dead

    async def _handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        self._clients.add(writer)
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    msg = json.loads(line.decode().strip())
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
                self._dispatch(msg)
        finally:
            self._clients.discard(writer)
            try:
                writer.close()
            except Exception:  # noqa: BLE001
                pass

    def _dispatch(self, msg: dict) -> None:
        """Route an inbound message from Swift; callbacks may schedule tasks."""
        t = msg.get("type")
        if t == "voice_start" and self.on_voice_start:
            self.on_voice_start()
        elif t == "voice_stop" and self.on_voice_stop:
            self.on_voice_stop()
        elif t == "text_input" and self.on_text_input:
            text = msg.get("text", "").strip()
            if text:
                self.on_text_input(text)
        elif t == "request_journal" and self.on_request_journal:
            self.on_request_journal()
        elif t == "undo_learning" and self.on_undo_learning:
            cid = (msg.get("id") or "").strip()
            if cid:
                self.on_undo_learning(cid)
        elif t == "edit_capability" and self.on_edit_capability:
            cid = (msg.get("id") or "").strip()
            if cid:
                self.on_edit_capability(cid, msg.get("description"), msg.get("examples"))
        elif t == "delete_capability" and self.on_delete_capability:
            cid = (msg.get("id") or "").strip()
            if cid:
                self.on_delete_capability(cid)
        # "ping" → no-op (keepalive only)
