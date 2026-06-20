from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from ipc_server import IPCServer  # noqa: E402


def test_dispatch_request_journal_calls_callback():
    srv = IPCServer()
    called = {"n": 0}
    srv.on_request_journal = lambda: called.__setitem__("n", called["n"] + 1)
    srv._dispatch({"type": "request_journal"})
    assert called["n"] == 1


def test_dispatch_undo_passes_id():
    srv = IPCServer()
    got = {}
    srv.on_undo_learning = lambda cid: got.__setitem__("id", cid)
    srv._dispatch({"type": "undo_learning", "id": "edit-setup"})
    assert got["id"] == "edit-setup"


def test_dispatch_edit_passes_fields():
    srv = IPCServer()
    got = {}
    srv.on_edit_capability = lambda cid, desc, ex: got.update(id=cid, desc=desc, ex=ex)
    srv._dispatch({"type": "edit_capability", "id": "x", "description": "d", "examples": ["a"]})
    assert got == {"id": "x", "desc": "d", "ex": ["a"]}


def test_dispatch_delete_passes_id():
    srv = IPCServer()
    got = {}
    srv.on_delete_capability = lambda cid: got.__setitem__("id", cid)
    srv._dispatch({"type": "delete_capability", "id": "x"})
    assert got["id"] == "x"


def test_dispatch_ignores_undo_without_id():
    srv = IPCServer()
    got = {"n": 0}
    srv.on_undo_learning = lambda cid: got.__setitem__("n", got["n"] + 1)
    srv._dispatch({"type": "undo_learning"})  # no id
    assert got["n"] == 0
