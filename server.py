"""
Severe MCP server.

Bridges an MCP client (e.g. Claude) to the Severe Roblox external's Luau
environment. Architecture:

    Claude --stdio(MCP)--> server.py --ws://127.0.0.1:8790--> bridge.lua (in Severe)

This process runs two things in one asyncio event loop:
  1. An MCP server over stdio (the interface Claude talks to).
  2. A WebSocket *server* that `bridge.lua` (a WebsocketClient) connects out to.

Each MCP tool call builds a command {id, op, args}, sends it to the connected
bridge, and awaits the matching {id, ok, result, error} reply correlated by id.

Severe exposes no HTTP request function but ships a native WebsocketClient, so
the bridge is the WS client and this is the WS server.
"""

import asyncio
import json
import os
import uuid

import websockets
from mcp.server import Server
from mcp.server.stdio import stdio_server
import mcp.types as types

WS_HOST = os.environ.get("SEVERE_WS_HOST", "127.0.0.1")
WS_PORT = int(os.environ.get("SEVERE_WS_PORT", "8790"))
# Sandbox root Severe restricts file ops to. Keep in sync with bridge.lua.
WORKSPACE_ROOT = os.environ.get("SEVERE_WORKSPACE", r"C:\v2\workspace")
COMMAND_TIMEOUT = float(os.environ.get("SEVERE_TIMEOUT", "15"))

# Bundled full Severe API docs, served by the severe_docs tool.
DOCS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "docs", "severe-api-full.txt")
try:
    with open(DOCS_PATH, encoding="utf-8") as _f:
        SEVERE_DOCS = _f.read()
except OSError:
    SEVERE_DOCS = ""


class BridgeManager:
    """Tracks the single connected bridge and correlates request/response by id."""

    def __init__(self) -> None:
        self.connection = None  # the active websocket, or None
        self.hello: dict | None = None  # last {"hello": ..., "version": ...}
        self._pending: dict[str, asyncio.Future] = {}

    @property
    def connected(self) -> bool:
        return self.connection is not None

    async def handler(self, websocket):
        """websockets server handler: one connection == one Severe bridge."""
        # Only one bridge is expected. If another connects, the newest wins.
        self.connection = websocket
        try:
            # Severe's WebsocketClient.new() blocks until it receives the FIRST
            # frame from the server (handshake completion alone is not enough),
            # so send a welcome frame immediately to unblock the bridge's new().
            await websocket.send(json.dumps({"type": "welcome", "server": "severe-bridge"}))
            async for raw in websocket:
                self._on_message(raw)
        except websockets.ConnectionClosed:
            pass
        finally:
            if self.connection is websocket:
                self.connection = None
                self.hello = None
            # Fail any in-flight requests tied to this socket.
            for fut in list(self._pending.values()):
                if not fut.done():
                    fut.set_exception(RuntimeError("bridge disconnected"))
            self._pending.clear()

    def _on_message(self, raw) -> None:
        try:
            msg = json.loads(raw)
        except (ValueError, TypeError):
            return
        if not isinstance(msg, dict):
            return
        if "hello" in msg:
            self.hello = msg
            return
        msg_id = msg.get("id")
        fut = self._pending.pop(msg_id, None)
        if fut is not None and not fut.done():
            fut.set_result(msg)

    async def send_command(self, op: str, args: dict | None = None,
                           timeout: float = COMMAND_TIMEOUT) -> dict:
        if not self.connected:
            raise RuntimeError(
                "Severe bridge not connected. Run Severe.exe and load bridge.lua "
                "in its Luau script editor."
            )
        msg_id = uuid.uuid4().hex
        loop = asyncio.get_running_loop()
        fut: asyncio.Future = loop.create_future()
        self._pending[msg_id] = fut
        payload = json.dumps({"id": msg_id, "op": op, "args": args or {}})
        try:
            await self.connection.send(payload)
            reply = await asyncio.wait_for(fut, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending.pop(msg_id, None)
            raise RuntimeError(f"timed out after {timeout}s waiting for bridge (op={op})")
        finally:
            self._pending.pop(msg_id, None)

        if not reply.get("ok", False):
            raise RuntimeError(reply.get("error") or "bridge reported an error")
        return reply.get("result")


bridge = BridgeManager()
server = Server("severe-bridge")


def _is_inside_workspace(path: str) -> bool:
    root = os.path.normcase(os.path.abspath(WORKSPACE_ROOT))
    target = os.path.normcase(os.path.abspath(os.path.join(WORKSPACE_ROOT, path)))
    return target == root or target.startswith(root + os.sep)


def _docs_response(query: str | None, max_chars: int = 8000) -> str:
    """Serve the bundled Severe docs: a table of contents when no query, or the
    doc sections matching the query (so responses stay small)."""
    if not SEVERE_DOCS:
        return "Severe docs not bundled (docs/severe-api-full.txt missing)."
    lines = SEVERE_DOCS.splitlines()
    if not query:
        toc = [ln for ln in lines if ln.startswith("#")]
        return "Severe API - table of contents (call severe_docs with a query " \
               "for details, or use severe_execute to run any Luau):\n\n" + "\n".join(toc)

    # Find sections (delimited by markdown headers) that mention the query.
    q = query.lower()
    sections, cur = [], []
    for ln in lines:
        if ln.startswith("#") and cur:
            sections.append(cur)
            cur = []
        cur.append(ln)
    if cur:
        sections.append(cur)

    out, total = [], 0
    for sec in sections:
        text = "\n".join(sec)
        if q in text.lower():
            if total + len(text) > max_chars:
                out.append("\n...(truncated; refine your query)...")
                break
            out.append(text)
            total += len(text)
    if not out:
        return f"No docs sections matched {query!r}. Try severe_docs with no query " \
               "for the table of contents."
    return "\n\n".join(out)


# --- Tool definitions -------------------------------------------------------

TOOLS: list[types.Tool] = [
    types.Tool(
        name="severe_status",
        description="Report whether the Severe Luau bridge is connected, plus its hello "
                    "info. Use this first to confirm the bridge is loaded.",
        inputSchema={"type": "object", "properties": {}},
    ),
    types.Tool(
        name="severe_execute",
        description="Run a Luau code chunk inside Severe. Captures print/warn output and "
                    "returns any values the chunk returns. Use for multi-statement code.",
        inputSchema={
            "type": "object",
            "properties": {
                "code": {"type": "string", "description": "Luau source to execute."}
            },
            "required": ["code"],
        },
    ),
    types.Tool(
        name="severe_eval",
        description="Evaluate a single Luau expression inside Severe and return its value "
                    "(e.g. '1+1', 'game.Players.LocalPlayer.Name').",
        inputSchema={
            "type": "object",
            "properties": {
                "expression": {"type": "string", "description": "Luau expression."}
            },
            "required": ["expression"],
        },
    ),
    types.Tool(
        name="severe_inspect",
        description="Inspect an instance by path (e.g. 'game.Workspace'): Name, ClassName, "
                    "parent, safe properties, and a child summary.",
        inputSchema={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Instance path, e.g. game.Workspace.Foo"}
            },
            "required": ["path"],
        },
    ),
    types.Tool(
        name="severe_tree",
        description="Return the descendants tree under an instance path, limited by depth.",
        inputSchema={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Root instance path. Default: game."},
                "depth": {"type": "integer", "description": "Max depth (default 2).", "default": 2},
            },
        },
    ),
    types.Tool(
        name="severe_search_instances",
        description="Search for instances under a root by name substring and/or class name.",
        inputSchema={
            "type": "object",
            "properties": {
                "root": {"type": "string", "description": "Root path. Default: game."},
                "name": {"type": "string", "description": "Name substring to match (optional)."},
                "class_name": {"type": "string", "description": "ClassName to match (optional)."},
                "limit": {"type": "integer", "description": "Max results (default 50).", "default": 50},
            },
        },
    ),
    types.Tool(
        name="severe_list_players",
        description="Enumerate game.Players with key fields (Name, DisplayName, UserId, etc.).",
        inputSchema={"type": "object", "properties": {}},
    ),
    types.Tool(
        name="severe_file_read",
        description=f"Read a file from Severe's workspace ({WORKSPACE_ROOT}). Path is "
                    "relative to that root.",
        inputSchema={
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Path relative to workspace root."}},
            "required": ["path"],
        },
    ),
    types.Tool(
        name="severe_file_write",
        description=f"Write a file into Severe's workspace ({WORKSPACE_ROOT}). Path is "
                    "relative to that root.",
        inputSchema={
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Path relative to workspace root."},
                "content": {"type": "string", "description": "File content."},
            },
            "required": ["path", "content"],
        },
    ),
    types.Tool(
        name="severe_memory_read",
        description="MEM explorer: read a typed value from memory. Target is either a raw "
                    "'address' (hex string like '0x1f59...' or number), OR an instance "
                    "'path' plus 'offset' (e.g. memory.readu64(game.Workspace, 0x50)). "
                    "Also returns RTTI type name when available.",
        inputSchema={
            "type": "object",
            "properties": {
                "address": {"type": "string", "description": "Raw address, hex (0x..) or decimal. Omit if using path."},
                "path": {"type": "string", "description": "Instance path; read at this object + offset."},
                "offset": {"type": "integer", "description": "Byte offset from the instance (with path). Default 0."},
                "type": {"type": "string", "description": "i8/u8/i16/u16/i32/u32/i64/u64/f32/f64/string/vector. Default u32.",
                         "default": "u32"},
            },
        },
    ),
    types.Tool(
        name="severe_memory_write",
        description="MEM explorer: write a typed value to memory. Same target options as "
                    "severe_memory_read (address OR path+offset). Use with care.",
        inputSchema={
            "type": "object",
            "properties": {
                "address": {"type": "string", "description": "Raw address, hex (0x..) or decimal."},
                "path": {"type": "string", "description": "Instance path; write at this object + offset."},
                "offset": {"type": "integer", "description": "Byte offset (with path). Default 0."},
                "type": {"type": "string", "description": "i8..f64/string/vector. Default u32.", "default": "u32"},
                "value": {"description": "Value to write (number, or string for type=string)."},
            },
            "required": ["value"],
        },
    ),
    types.Tool(
        name="severe_memory_rtti",
        description="Return the Run-Time Type Information (RTTI) class name at an address "
                    "or instance+offset (e.g. 'RBX::DataModel'). Target like severe_memory_read.",
        inputSchema={
            "type": "object",
            "properties": {
                "address": {"type": "string", "description": "Raw address, hex (0x..) or decimal."},
                "path": {"type": "string", "description": "Instance path."},
                "offset": {"type": "integer", "description": "Byte offset (with path). Default 0."},
            },
        },
    ),
    types.Tool(
        name="severe_pointer",
        description="DEX explorer: best-effort numeric pointer (0x..) for an instance path. "
                    "Severe has no documented Instance->address accessor, so this probes for "
                    "an undocumented one; returns null pointer if unavailable.",
        inputSchema={
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Instance path, e.g. game.Workspace.Foo"}},
            "required": ["path"],
        },
    ),
    types.Tool(
        name="severe_docs",
        description="Search/browse Severe's FULL bundled API docs (every library, class, "
                    "global, Drawing/ESP, input, memory, etc.). Call with no query for the "
                    "table of contents, or a query (e.g. 'Drawing', 'keypress', 'CFrame', "
                    "'add_model_data') for the relevant sections. Use this to learn the exact "
                    "API, then run it via severe_execute.",
        inputSchema={
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Term to find (function/class/library name). Omit for the TOC."}
            },
        },
    ),
]


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return TOOLS


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    arguments = arguments or {}

    if name == "severe_status":
        result = {"connected": bridge.connected, "hello": bridge.hello,
                  "ws": f"ws://{WS_HOST}:{WS_PORT}", "workspace": WORKSPACE_ROOT,
                  "docs_loaded": bool(SEVERE_DOCS)}
        return [types.TextContent(type="text", text=json.dumps(result, indent=2))]

    if name == "severe_docs":
        return [types.TextContent(type="text", text=_docs_response(arguments.get("query")))]

    try:
        if name == "severe_execute":
            result = await bridge.send_command("execute", {"code": arguments["code"]})
        elif name == "severe_eval":
            result = await bridge.send_command("eval", {"expression": arguments["expression"]})
        elif name == "severe_inspect":
            result = await bridge.send_command("inspect", {"path": arguments["path"]})
        elif name == "severe_tree":
            result = await bridge.send_command(
                "tree", {"path": arguments.get("path", "game"),
                         "depth": int(arguments.get("depth", 2))})
        elif name == "severe_search_instances":
            result = await bridge.send_command("search", {
                "root": arguments.get("root", "game"),
                "name": arguments.get("name"),
                "class_name": arguments.get("class_name"),
                "limit": int(arguments.get("limit", 50)),
            })
        elif name == "severe_list_players":
            result = await bridge.send_command("players", {})
        elif name == "severe_file_read":
            path = arguments["path"]
            if not _is_inside_workspace(path):
                raise RuntimeError(f"path escapes workspace root {WORKSPACE_ROOT}")
            result = await bridge.send_command("file_read", {"path": path})
        elif name == "severe_file_write":
            path = arguments["path"]
            if not _is_inside_workspace(path):
                raise RuntimeError(f"path escapes workspace root {WORKSPACE_ROOT}")
            result = await bridge.send_command(
                "file_write", {"path": path, "content": arguments["content"]})
        elif name == "severe_memory_read":
            result = await bridge.send_command("memory_read", {
                "address": arguments.get("address"), "path": arguments.get("path"),
                "offset": arguments.get("offset", 0), "type": arguments.get("type", "u32")})
        elif name == "severe_memory_write":
            result = await bridge.send_command("memory_write", {
                "address": arguments.get("address"), "path": arguments.get("path"),
                "offset": arguments.get("offset", 0), "type": arguments.get("type", "u32"),
                "value": arguments["value"]})
        elif name == "severe_memory_rtti":
            result = await bridge.send_command("memory_rtti", {
                "address": arguments.get("address"), "path": arguments.get("path"),
                "offset": arguments.get("offset", 0)})
        elif name == "severe_pointer":
            result = await bridge.send_command("pointer", {"path": arguments["path"]})
        else:
            raise RuntimeError(f"unknown tool: {name}")
    except Exception as exc:  # surface as a readable tool error
        return [types.TextContent(type="text", text=f"ERROR: {exc}")]

    if isinstance(result, str):
        text = result
    else:
        text = json.dumps(result, indent=2, ensure_ascii=False)
    return [types.TextContent(type="text", text=text)]


async def main() -> None:
    async with websockets.serve(bridge.handler, WS_HOST, WS_PORT):
        async with stdio_server() as (read_stream, write_stream):
            await server.run(
                read_stream, write_stream, server.create_initialization_options()
            )


if __name__ == "__main__":
    asyncio.run(main())
