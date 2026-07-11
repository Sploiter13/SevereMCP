<div align="center">

<img src="assets/severemcp-header.png" width="620" alt="SevereMCP">

**Connect [Severe](https://rsware.store/products/severe-roblox-external-lifetime-win-10--11) to any AI/LLM model of your choice.** Run Luau, inspect the game, read memory, and build custom ESPs, aimbots & auto-farms — all from just prompting AI.

[![License: MIT](https://img.shields.io/badge/license-MIT-brightgreen.svg?style=flat-square)](LICENSE)
[![CI](https://github.com/RealSlimShady2000/SevereMCP/actions/workflows/ci.yml/badge.svg)](https://github.com/RealSlimShady2000/SevereMCP/actions/workflows/ci.yml)
[![Stars](https://img.shields.io/github/stars/RealSlimShady2000/SevereMCP?style=flat-square&color=yellow)](https://github.com/RealSlimShady2000/SevereMCP/stargazers)

[![Star this repo](https://img.shields.io/badge/⭐_Star_this_repo-2b3137?style=for-the-badge&logo=github)](https://github.com/RealSlimShady2000/SevereMCP/stargazers)
&nbsp;
[![Get Severe](https://img.shields.io/badge/Get_Severe-Buy_Now-e63946?style=for-the-badge)](https://rsware.store/products/severe-roblox-external-lifetime-win-10--11)

</div>

---

## What is this

**SevereMCP** is a [Model Context Protocol](https://modelcontextprotocol.io) server that hooks **Severe**'s Luau environment up to any AI you use — Claude, ChatGPT, Gemini, or any MCP client. Ask it to run Luau, walk the game tree, list players, read memory, or build an ESP, and it does it live in your session and reads the results back.

## How it works

```
AI client ──stdio (MCP)──> server.py ──ws://127.0.0.1:8790──> bridge.lua  (in Severe's Luau env)
```

- **`server.py`** — the MCP server (stdio, for the AI client) **and** an embedded WebSocket server, in one process.
- **`bridge.lua`** — runs inside Severe and uses Severe's native `WebsocketClient` to connect **out** to that server, execute the commands it receives, and send JSON results back.

The split (server = WS server, bridge = WS client) is required because Severe exposes a `WebsocketClient` but no HTTP request function, so the bridge can't poll an HTTP server.

## Setup

> Default setup: Severe and the AI client on the **same PC**. For two machines, see [Cross-machine](#cross-machine-optional).

**1. Install Python deps**

```sh
pip install -r requirements.txt
```

**2. Add the MCP server to your AI client** — pick yours below. Most use this JSON block; **replace the path** with your real path to `server.py`:

```json
{
  "mcpServers": {
    "severe-bridge": {
      "command": "python",
      "args": ["C:/path/to/SevereMCP/server.py"],
      "env": { "SEVERE_WS_HOST": "127.0.0.1", "SEVERE_WS_PORT": "8790" }
    }
  }
}
```

<details>
<summary><b>Claude Code (CLI)</b></summary>

One command — no file editing:

```sh
claude mcp add severe-bridge -e SEVERE_WS_HOST=127.0.0.1 -e SEVERE_WS_PORT=8790 -- python C:/path/to/SevereMCP/server.py
```

Restart Claude Code, then run `claude mcp list` — `severe-bridge` should show connected.
</details>

<details>
<summary><b>Claude Desktop</b></summary>

1. **Settings → Developer → Edit Config** (opens `claude_desktop_config.json`).
2. Paste the JSON block above (merge into `mcpServers` if the file already has some).
3. Save, then fully quit and reopen Claude Desktop.
</details>

<details>
<summary><b>Claude — VS Code / JetBrains extension</b></summary>

It runs on Claude Code, so either:
- Run the **Claude Code (CLI)** `claude mcp add` command above in a terminal, **or**
- Drop a `.mcp.json` file (the JSON block) in your project root.

Then reload the window.
</details>

<details>
<summary><b>ChatGPT / OpenAI Codex CLI</b></summary>

Edit `~/.codex/config.toml` and add (TOML, not JSON):

```toml
[mcp_servers.severe-bridge]
command = "python"
args = ["C:/path/to/SevereMCP/server.py"]
env = { SEVERE_WS_HOST = "127.0.0.1", SEVERE_WS_PORT = "8790" }
```

Restart Codex. (The ChatGPT app's own "connectors" only accept remote URLs — for this local server, use the Codex CLI.)
</details>

<details>
<summary><b>Gemini CLI</b></summary>

Add the JSON block to `~/.gemini/settings.json` (create the file if it doesn't exist), then restart `gemini`. Confirm with `/mcp`.
</details>

<details>
<summary><b>Antigravity</b></summary>

Open the MCP settings (Settings → **MCP servers → Edit config**, i.e. its `mcp_config.json`), paste the JSON block, save, and reload.
</details>

<details>
<summary><b>LM Studio</b></summary>

Right sidebar → **Program** → **Install → Edit `mcp.json`**, paste the JSON block, and save. Enable the server in the chat's integrations panel.
</details>

> Any other MCP-capable client works too — point it at `python C:/path/to/SevereMCP/server.py` over **stdio**. The server auto-starts and listens on `ws://127.0.0.1:8790` for the bridge.

**3. Load the bridge in Severe** — run Severe, open its **Script** tab, and **Execute** one of:

*Easy mode (recommended)* — one line, always up to date:
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/RealSlimShady2000/SevereMCP/main/bridge.lua"))()
```

*Or* paste the full contents of `bridge.lua`. Either way you should see:

```
[severe-bridge] starting, target ws://127.0.0.1:8790
[severe-bridge] connected to ws://127.0.0.1:8790
```

The bridge auto-reconnects every ~2s, so order doesn't matter.

**4. Confirm** — in your AI client, call **`severe_status`** → it should report `"connected": true`.

## Tools

| Tool | What it does |
|------|--------------|
| `severe_status` | Is the bridge connected? (local; always safe to call) |
| `severe_execute` | Run a Luau chunk; returns captured `print`/`warn` output + return values |
| `severe_eval` | Evaluate a single Luau expression and return its value |
| `severe_inspect` | Inspect an instance by path (props + children) — DEX-style |
| `severe_tree` | Descendants tree under a path, limited by `depth` |
| `severe_search_instances` | Find instances by name substring and/or ClassName |
| `severe_list_players` | Enumerate `game.Players` |
| `severe_file_read` / `severe_file_write` | Read/write files under Severe's workspace |
| `severe_memory_read` / `severe_memory_write` | MEM-style typed read/write at an address or instance+offset |
| `severe_memory_rtti` | RTTI class name (e.g. `RBX::Workspace`) at an address/instance |
| `severe_pointer` | Instance→pointer (0x..) via Severe's undocumented `Instance.Data` address |
| `severe_read_chain` | Follow a pointer chain (`base + offsets → type`) — generalizes memory ESP reads |
| `severe_memory_scan` | Bounded scan for a value in a memory range (RE) |
| `severe_fire_remote` | Fire a RemoteEvent/RemoteFunction by path — the core of auto-farms/bots |
| `severe_call` / `severe_get` / `severe_set` | Call a method / read / write a property by path |
| `severe_input` | Synthetic keyboard/mouse input (keys, clicks, move, scroll) |
| `severe_game_info` | PlaceId / GameId / JobId / HWID / ping / player count / local player |
| `severe_docs` | Search/browse Severe's **full bundled API docs** (`docs/severe-api-full.txt`) |

Anything without a dedicated tool is reachable via `severe_execute` — the full Severe API (Drawing/ESP, input, `add_model_data`, `game:HttpGet`, crypt, camera, …) is documented via `severe_docs`.

## Examples

- `severe_eval` → `1+1` ⇒ `2`
- `severe_execute` → `print("hi"); return game.Players.LocalPlayer.Name`
- `severe_inspect` → `game.Workspace`
- `severe_search_instances` → `{ "class_name": "Humanoid" }`
- `severe_memory_read` → `{ "path": "game.Workspace", "offset": 0, "type": "u64" }` ⇒ value + `rtti`
- `severe_docs` → `{ "query": "add_model_data" }`

**[`examples/esp.lua`](examples/esp.lua)** — a full **memory-read ESP + toggle GUI** an agent built through the MCP, tested live on **[RIOTFALL](https://www.roblox.com/games/7796842481/RIOTFALL)**: it reverse-engineers real player positions from memory (RIOTFALL hides them behind bone-driven rigs + decoy `HumanoidRootPart`s), draws team-colored boxes + names, and wires ESP / team-check toggles into a Severe UI library. Great "what you can build" reference.

<!-- Demo: drop a clip at assets/demo.gif, then:  <p align="center"><img src="assets/demo.gif" width="720" alt="SevereMCP demo"></p> -->

### Prompt recipes

Things you can just *ask* your AI (it explores the game and writes the Luau):

- *"Call `severe_game_info`, then build a box ESP with names for all enemies."*
- *"Search ReplicatedStorage for remotes, find the one that collects currency, and fire it every 0.5s — stop when my cash stops going up."*
- *"Walk `game.Workspace` and list every model that looks like an ore/resource node with its position."*
- *"Read my character's health from memory and auto-press the heal key when it drops below 50."*
- *"Reverse-engineer this game's real player positions like the RIOTFALL example and make an ESP."*
- *"Fire the `EquipTool` remote, then auto-click every 200ms to farm."* (`severe_fire_remote` + `severe_input`)

## Beyond ESP & aimbot — auto-farms and automation

The real power isn't the ESP — it's that the agent can **discover how a game works and write automation for it, live.** ESP and aimbot are just the obvious demos; the same read → understand → act loop builds **auto-farms, quest bots, collectors, and more** for games it has never seen before.

How an agent builds an auto-farm through the MCP:

1. **Map the game** — `severe_tree` / `severe_search_instances` to find currency values, collectibles, NPCs, spawners, quest objects, and the `RemoteEvent`/`RemoteFunction`s the game uses.
2. **Reverse the actions** — `severe_execute` to read a `RemoteEvent`'s arguments (or decompile/inspect the game's own scripts) and figure out what call collects a coin, sells loot, claims a reward, or hits a mob.
3. **Test one action** — fire the remote once and read the result (currency went up? item added?) — the agent verifies before looping.
4. **Loop it** — `severe_execute` installs a `task.spawn` / `RunService` loop that repeats the farm action, teleports between resource nodes (via memory-written CFrame or the game's own teleport remote), and **reads a stat to know when to stop** (inventory full, quest done).
5. **Iterate** — if the game patches or behaves oddly, the agent inspects again and adjusts — no waiting for someone to update a static script.

Because every step runs through Luau + memory access, an auto-farm can be as simple as *"fire the `CollectCoin` remote every 0.5s"* or as deep as *"read the nearest ore node from memory, walk to it, mine it, sell when full."* You describe the goal in chat; the agent explores the game and writes the farm — the same way it reverse-engineered RIOTFALL's positions above.

> The MCP is a **capability layer**, not a cheat pack: it gives an AI agent Severe's full Luau + memory reach. What it builds — ESP, aimbot, auto-farm, autoquest, or plain game inspection — is up to your prompt.

## Cross-machine (optional)

Running the AI client on one PC and Severe on another (same LAN):

1. Start `server.py` with `SEVERE_WS_HOST=0.0.0.0` (bind all interfaces).
2. In `bridge.lua`, set `WS_HOST` to the **server PC's LAN IP** (e.g. `192.168.1.50`).
3. Open the server PC's firewall for inbound TCP `8790`.
4. From the Severe PC, verify with `Test-NetConnection <server-ip> -Port 8790`.

## Severe WebsocketClient quirks (why the bridge is written the way it is)

Hard-won from live testing — don't "simplify" these away:

- **`WebsocketClient.new(url)` blocks until the server sends the first frame.** The handshake completing isn't enough — so `server.py` sends a `welcome` frame on connect. A silent server makes `new()` hang 15s → "Scheduler Exhausted".
- **Receive is a method, not a signal:** `s:DataReceived(function(payload, isBinary) end)` — *not* `s.DataReceived:Connect(...)`.
- **The `DataReceived` callback is a C-call boundary — you cannot yield in it.** `Send` and game API calls yield, so the bridge hands each message to `task.spawn(...)` ("attempt to yield across metamethod/C-call boundary" otherwise).
- **Don't use `crypt.json` in the bridge** — `crypt.json.decode` blocks/yields and trips the watchdog. A bundled pure-Lua JSON is used instead.
- **Positions come back as the native `vector` type** (`typeof` ≠ `"Vector3"`) — read `.X/.Y/.Z`.
- **`Players` has no `GetPlayers()`** in this build — the bridge falls back to `GetChildren()` filtered to `Player`.
- Long scans **yield every ~2000 nodes** to dodge the 15s watchdog (`YIELD_EVERY`).

## Configuration

Set in the MCP config `env` block (mirror host/port in `bridge.lua` if you change them):

| Var | Default | Meaning |
|-----|---------|---------|
| `SEVERE_WS_HOST` | `127.0.0.1` | WebSocket bind host (`0.0.0.0` for cross-machine) |
| `SEVERE_WS_PORT` | `8790` | WebSocket port (also edit `WS_PORT` in `bridge.lua`) |
| `SEVERE_WORKSPACE` | `C:\v2\workspace` | Sandbox root for file tools |
| `SEVERE_TIMEOUT` | `15` | Default per-command timeout (`severe_execute` can override per call) |
| `SEVERE_UNSAFE` | *(off)* | Set to `1` to allow **writes** (`memory_write`, `set`) — off by default (a bad write can crash the game) |
| `SEVERE_TOKEN` | *(off)* | Shared secret; if set, the bridge's `WS_TOKEN` must match (LAN safety) |
| `SEVERE_MAX_OUTPUT` | `60000` | Max chars returned to the AI (truncates huge results) |

## Troubleshooting

- **`severe_status` = `connected: false`** — make sure `bridge.lua` is Executed in Severe and the host/port match on both sides.
- **Tool returns "bridge not connected"** — re-run `bridge.lua`.
- **`compile error` / `load error`** — your Luau source didn't compile; check syntax.
- **`WebsocketClient` is nil** — your build may name it differently; adjust the `WebsocketClient.new(...)` call in `bridge.lua`.

## Files

- `server.py` — MCP server + WebSocket server + tool definitions
- `bridge.lua` — in-Severe Luau bridge (WS client, JSON, exec sandbox, dispatch, memory)
- `docs/severe-api-full.txt` — Severe's own API docs, bundled so `severe_docs` works offline
- `examples/esp.lua` — memory-read ESP + GUI demo
- `.mcp.json.example` — MCP client config template

---

<div align="center">

Created by **[robloxscripts.com](https://robloxscripts.com)** & **[rsware.store](https://rsware.store)** — vibe coded with love ❤️

Want the tool this drives? **[Get Severe →](https://rsware.store/products/severe-roblox-external-lifetime-win-10--11)**

⭐ **Star the repo if it helped!** ⭐

</div>
