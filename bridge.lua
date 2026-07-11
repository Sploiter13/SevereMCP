--[[
  Severe MCP bridge  (load this in Severe.exe's Luau script editor)

  Connects out to the Python MCP server's WebSocket server and executes the
  commands it sends, returning JSON results. Pair with server.py.

      Claude --stdio(MCP)--> server.py --ws--> THIS SCRIPT (in Severe's Luau env)

  Protocol (JSON text frames):
    server -> bridge : {"id": "...", "op": "...", "args": {...}}
    bridge -> server : {"id": "...", "ok": true|false, "result": <any>, "error": "..."}
    bridge -> server : {"hello": "severe-bridge", "version": "..."}  (on connect)

  Severe API used: WebsocketClient, luau.compile/luau.load, task.*, game,
  readfile/writefile. File ops are sandboxed by Severe to C:\v2\workspace.
]]

local VERSION = "1.1.1"
-- Host where server.py runs. Default localhost = Severe and the MCP server on the
-- SAME PC. Cross-machine: set this to the server PC's LAN IP (and run server.py with
-- SEVERE_WS_HOST=0.0.0.0 + open the firewall port). See README "Cross-machine".
local WS_HOST = "127.0.0.1"
local WS_PORT = 8790
local WS_URL = "ws://" .. WS_HOST .. ":" .. WS_PORT
-- Optional shared secret for cross-machine use. Leave "" for same-machine.
-- If set, must match the server's SEVERE_TOKEN env var.
local WS_TOKEN = ""

local MAX_DEPTH = 4        -- serialization depth cap
local OP_BUDGET = 500000   -- max nodes touched per command (anti-freeze)
local MAX_RESULTS = 200    -- hard cap on search/tree node counts
local YIELD_EVERY = 2000   -- yield every N nodes to dodge the 15s watchdog

local typeof = typeof or type

-- Best-effort handle on the real global table so executed chunks can see
-- `game`, `task`, string, etc. through the sandbox environment's __index.
local GLOBALS = (function()
  local ok, g = pcall(function() return getgenv() end)
  if ok and type(g) == "table" then return g end
  ok, g = pcall(function() return getfenv(0) end)
  if ok and type(g) == "table" then return g end
  return _G
end)()

--==========================================================================--
-- Minimal JSON (encode/decode) -- do not assume HttpService exists.
--==========================================================================--
local json = {}
do
  local ESC = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
               ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f'}
  local function esc(c) return ESC[c] or string.format("\\u%04x", string.byte(c)) end
  local function enc_str(s) return '"' .. s:gsub('[%c"\\]', esc) .. '"' end

  local function enc(v)
    local t = type(v)
    if t == "nil" then
      return "null"
    elseif t == "boolean" then
      return v and "true" or "false"
    elseif t == "number" then
      if v ~= v or v == math.huge or v == -math.huge then return "null" end
      return tostring(v)
    elseif t == "string" then
      return enc_str(v)
    elseif t == "table" then
      local n = 0
      for _ in pairs(v) do n = n + 1 end
      local isarr = n > 0
      for i = 1, n do if v[i] == nil then isarr = false break end end
      if isarr then
        local parts = {}
        for i = 1, n do parts[i] = enc(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
      elseif n == 0 then
        return "{}"
      else
        local parts = {}
        for k, val in pairs(v) do
          parts[#parts + 1] = enc_str(tostring(k)) .. ":" .. enc(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
    else
      return enc_str(tostring(v))
    end
  end
  json.encode = function(v) return enc(v) end

  function json.decode(str)
    local pos = 1
    local parse_value

    local function ws() pos = str:find("[^ \t\r\n]", pos) or (#str + 1) end

    local function parse_string()
      pos = pos + 1
      local out = {}
      local MAP = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', n = '\n',
                   t = '\t', r = '\r', b = '\b', f = '\f'}
      while pos <= #str do
        local c = str:sub(pos, pos)
        if c == '"' then pos = pos + 1; return table.concat(out)
        elseif c == '\\' then
          local nx = str:sub(pos + 1, pos + 1)
          if nx == 'u' then
            local code = tonumber(str:sub(pos + 2, pos + 5), 16) or 0
            out[#out + 1] = (utf8 and utf8.char(code)) or string.char(code % 256)
            pos = pos + 6
          else
            out[#out + 1] = MAP[nx] or nx
            pos = pos + 2
          end
        else
          out[#out + 1] = c; pos = pos + 1
        end
      end
      error("unterminated string")
    end

    local function parse_object()
      pos = pos + 1; ws()
      local obj = {}
      if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
      while true do
        ws()
        local key = parse_string()
        ws()
        pos = pos + 1 -- skip ':'
        obj[key] = parse_value()
        ws()
        local c = str:sub(pos, pos)
        pos = pos + 1
        if c == '}' then break elseif c ~= ',' then error("bad object") end
      end
      return obj
    end

    local function parse_array()
      pos = pos + 1; ws()
      local arr = {}
      if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parse_value()
        ws()
        local c = str:sub(pos, pos)
        pos = pos + 1
        if c == ']' then break elseif c ~= ',' then error("bad array") end
      end
      return arr
    end

    parse_value = function()
      ws()
      local c = str:sub(pos, pos)
      if c == '"' then return parse_string()
      elseif c == '{' then return parse_object()
      elseif c == '[' then return parse_array()
      elseif c == 't' then pos = pos + 4; return true
      elseif c == 'f' then pos = pos + 5; return false
      elseif c == 'n' then pos = pos + 4; return nil
      else
        local s, e = str:find("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        if not s then error("unexpected char at " .. pos) end
        local num = tonumber(str:sub(s, e))
        pos = e + 1
        return num
      end
    end

    return parse_value()
  end
end

-- NOTE: do NOT use crypt.json here. In this Severe build crypt.json.decode
-- blocks/yields and trips the 15s "Scheduler Exhausted" watchdog when called
-- from the WebSocket DataReceived callback, hanging every incoming command.
-- The pure-Lua encoder/decoder above never yields, so we keep using it.

--==========================================================================--
-- Instance helpers
--==========================================================================--
local function get_path(inst)
  local ok, parts = pcall(function()
    local segs, cur, guard = {}, inst, 0
    while cur ~= nil and guard < 64 do
      table.insert(segs, 1, cur.Name)
      if cur == game then break end
      cur = cur.Parent
      guard = guard + 1
    end
    return segs
  end)
  if ok and parts then return table.concat(parts, ".") end
  local ok2, name = pcall(function() return inst.Name end)
  return ok2 and name or "<instance>"
end

-- Resolve "game.Workspace.Foo" -> Instance (or error).
local function resolve_path(path)
  if not path or path == "" or path == "game" then return game end
  local cur = game
  for seg in string.gmatch(path, "[^%.]+") do
    if seg == "game" then
      cur = game
    else
      local nxt
      local ok = pcall(function() nxt = cur[seg] end)
      if not ok or nxt == nil then
        local ok2 = pcall(function() nxt = cur:FindFirstChild(seg) end)
        if not ok2 then nxt = nil end
      end
      if nxt == nil then
        local ok3, svc = pcall(function() return game:GetService(seg) end)
        if ok3 then nxt = svc end
      end
      if nxt == nil then error("path segment not found: " .. seg) end
      cur = nxt
    end
  end
  return cur
end

-- Best-effort numeric pointer for an instance (DEX "Pointer:"). No documented
-- accessor exists, so probe for an undocumented one. Returns address|nil, method.
local function try_pointer(inst)
  -- Instance.Data exposes the raw address on this build (thanks @Sploiter13, #1).
  local ok, addr = pcall(function() return tonumber(inst.Data) end)
  if ok and type(addr) == "number" then return addr, ".Data" end
  -- Fallback: probe for an undocumented address getter, in case a build differs.
  for _, nm in ipairs({"getaddress", "getpointer", "get_address",
                       "get_pointer", "addressof", "pointer_of"}) do
    local f = GLOBALS[nm] or _G[nm]
    if type(f) == "function" then
      local ok2, a = pcall(f, inst)
      if ok2 and type(a) == "number" then return a, nm end
    end
  end
  return nil, nil
end
-- i blame mafia for alot of things undocumented bruh
--==========================================================================--
-- Serialization (Roblox/Severe userdata -> plain JSON-able tables)
--==========================================================================--
local _budget = 0
local function tick_budget()
  _budget = _budget + 1
  -- Yield periodically so long scans don't trip the 15s "Scheduler Exhausted"
  -- watchdog. Safe: dispatch runs on a task.spawn thread where yielding is legal.
  if _budget % YIELD_EVERY == 0 then task.wait() end
  if _budget > OP_BUDGET then error("operation budget exceeded (" .. OP_BUDGET .. ")") end
end

local function serialize(value, depth)
  tick_budget()
  local t = typeof(value)
  if t == "number" or t == "boolean" or t == "string" or t == "nil" then
    return value
  elseif t == "Vector3" or t == "vector" then
    -- Severe hands back positions as the native Luau `vector` type (typeof
    -- "vector"), not a Roblox Vector3 userdata -- handle both.
    return {__type = t, x = value.X, y = value.Y, z = value.Z}
  elseif t == "Vector2" then
    return {__type = "Vector2", x = value.X, y = value.Y}
  elseif t == "Color3" then
    return {__type = "Color3", r = value.R, g = value.G, b = value.B}
  elseif t == "CFrame" then
    return {__type = "CFrame", components = {value:GetComponents()}}
  elseif t == "Instance" then
    return {__type = "Instance", Name = value.Name, ClassName = value.ClassName,
            path = get_path(value)}
  elseif t == "EnumItem" or t == "Enum" or t == "Enums" then
    return {__type = "Enum", value = tostring(value)}
  elseif t == "table" then
    if depth >= MAX_DEPTH then return "<table:max-depth>" end
    local out = {}
    for k, v in pairs(value) do
      if type(k) == "string" or type(k) == "number" then
        out[k] = serialize(v, depth + 1)
      end
    end
    return out
  else
    return tostring(value)
  end
end

-- A handful of commonly-useful properties to probe on an instance.
local COMMON_PROPS = {
  "Name", "ClassName", "Parent", "Position", "CFrame", "Size", "Anchored",
  "Transparency", "Value", "Health", "MaxHealth", "WalkSpeed", "DisplayName",
  "UserId", "Team", "Character", "Enabled", "Visible", "Text", "Color",
}

--==========================================================================--
-- Code execution sandbox (print/warn capture)
--==========================================================================--
local function run_chunk(src)
  local buffer = {}
  local function capture(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    buffer[#buffer + 1] = table.concat(parts, "\t")
  end

  local ok_c, bytecode = pcall(luau.compile, src)
  if not ok_c then return false, "compile error: " .. tostring(bytecode), buffer end

  -- Preferred: sandboxed environment for isolated print/warn capture. Globals
  -- (game, task, ...) reach the chunk via the metatable __index -> GLOBALS.
  local env = setmetatable({print = capture, warn = capture}, {__index = GLOBALS})
  local fn = luau.load(bytecode, {environment = env, injectGlobals = true})

  -- Fallback: some builds return nil for a custom environment. Load plainly in
  -- the shared global env and capture print/warn by temporarily overriding them.
  local override = false
  if type(fn) ~= "function" then
    fn = luau.load(bytecode)
    override = true
  end
  if type(fn) ~= "function" then
    return false, "load failed (luau.load returned non-function)", buffer
  end

  local old_print, old_warn
  if override then
    old_print, old_warn = GLOBALS.print, GLOBALS.warn
    GLOBALS.print, GLOBALS.warn = capture, capture
  end
  local results = table.pack(pcall(fn))
  if override then
    GLOBALS.print, GLOBALS.warn = old_print, old_warn
  end

  local ok_r = results[1]
  if not ok_r then
    return false, tostring(results[2]), buffer
  end

  local returns = {}
  for i = 2, results.n do
    returns[#returns + 1] = serialize(results[i], 0)
  end
  return true, returns, buffer
end

--==========================================================================--
-- Dispatch table (one function per op)
--==========================================================================--
local dispatch = {}

function dispatch.ping()
  return {pong = true, version = VERSION}
end

function dispatch.execute(args)
  local ok, ret, buffer = run_chunk(args.code or "")
  if not ok then error(ret) end
  return {output = table.concat(buffer, "\n"), returns = ret}
end

function dispatch.eval(args)
  local expr = args.expression or "nil"
  local ok, ret, buffer = run_chunk("return (" .. expr .. ")")
  if not ok then error(ret) end
  local value = ret[1]
  if value == nil and #ret == 0 then value = nil end
  return {value = value, output = table.concat(buffer, "\n")}
end

function dispatch.inspect(args)
  local inst = resolve_path(args.path)
  local ptr = try_pointer(inst)
  local info = {
    path = get_path(inst),
    pointer = ptr and string.format("0x%x", ptr) or nil,
    properties = {},
    children = {},
  }
  for _, prop in ipairs(COMMON_PROPS) do
    local ok, val = pcall(function() return inst[prop] end)
    if ok and val ~= nil then
      info.properties[prop] = serialize(val, 1)
    end
  end
  local ok, kids = pcall(function() return inst:GetChildren() end)
  if ok and kids then
    info.child_count = #kids
    for i = 1, math.min(#kids, MAX_RESULTS) do
      local c = kids[i]
      info.children[i] = {Name = c.Name, ClassName = c.ClassName}
    end
  end
  return info
end

local function build_tree(inst, depth, max_depth)
  tick_budget()
  local node = {Name = inst.Name, ClassName = inst.ClassName}
  if depth < max_depth then
    local ok, kids = pcall(function() return inst:GetChildren() end)
    if ok and kids and #kids > 0 then
      node.children = {}
      for i = 1, math.min(#kids, MAX_RESULTS) do
        node.children[i] = build_tree(kids[i], depth + 1, max_depth)
      end
    end
  end
  return node
end

function dispatch.tree(args)
  local inst = resolve_path(args.path)
  local depth = math.max(1, math.min(tonumber(args.depth) or 2, 8))
  return build_tree(inst, 0, depth)
end

function dispatch.search(args)
  local root = resolve_path(args.root or "game")
  local name = args.name
  local class_name = args.class_name
  local limit = math.min(tonumber(args.limit) or 50, MAX_RESULTS)
  local matches = {}

  local ok, descendants = pcall(function() return root:GetDescendants() end)
  if not ok or not descendants then error("could not enumerate descendants") end

  for _, d in ipairs(descendants) do
    tick_budget()
    local hit = true
    if name and name ~= "" then
      hit = string.find(string.lower(d.Name), string.lower(name), 1, true) ~= nil
    end
    if hit and class_name and class_name ~= "" then
      hit = (d.ClassName == class_name)
    end
    if hit then
      matches[#matches + 1] = {Name = d.Name, ClassName = d.ClassName, path = get_path(d)}
      if #matches >= limit then break end
    end
  end
  return {count = #matches, matches = matches}
end

function dispatch.players()
  local svc = game:GetService("Players")
  local list = {}
  local local_player
  pcall(function() local_player = svc.LocalPlayer end)
  -- This Severe build's Players has no GetPlayers(); use GetChildren() filtered
  -- to Player instances (fall back to GetPlayers() if a build does expose it).
  local roster
  local ok = pcall(function() roster = svc:GetPlayers() end)
  if not ok or type(roster) ~= "table" then
    roster = {}
    for _, c in ipairs(svc:GetChildren()) do
      if c.ClassName == "Player" then roster[#roster + 1] = c end
    end
  end
  for _, p in ipairs(roster) do
    tick_budget()
    local entry = {Name = p.Name}
    pcall(function() entry.DisplayName = p.DisplayName end)
    pcall(function() entry.UserId = p.UserId end)
    pcall(function() entry.Team = p.Team and p.Team.Name or nil end)
    pcall(function() entry.is_local = (p == local_player) end)
    list[#list + 1] = entry
  end
  return {count = #list, local_player = local_player and local_player.Name or nil, players = list}
end

function dispatch.file_read(args)
  local content = readfile(args.path)
  return {path = args.path, content = content}
end

function dispatch.file_write(args)
  writefile(args.path, args.content or "")
  return {path = args.path, bytes = #(args.content or "")}
end

--==========================================================================--
-- Memory (MEM explorer) -- memory.read*/write* accept either a raw address
-- or (userdata, offset). args: {address="0x..."} OR {path="game.Workspace",
-- offset=0x50}, plus type and (for writes) value.
--==========================================================================--
local MEM_TYPES = {
  i8 = true, u8 = true, i16 = true, u16 = true, i32 = true, u32 = true,
  i64 = true, u64 = true, f32 = true, f64 = true, string = true, vector = true,
}

-- Returns target, offset, is_userdata for a memory op.
local function mem_target(args)
  if args.path and args.path ~= "" then
    return resolve_path(args.path), tonumber(args.offset) or 0, true
  end
  local addr = args.address
  if type(addr) == "string" then addr = tonumber(addr) end  -- handles "0x..."
  if type(addr) ~= "number" then error("provide address (hex string/number) or path") end
  return addr, nil, false
end

function dispatch.memory_read(args)
  local ty = tostring(args.type or "u32")
  if not MEM_TYPES[ty] then error("bad memory type: " .. ty) end
  local fn = memory["read" .. ty]
  if type(fn) ~= "function" then error("memory.read" .. ty .. " unavailable") end
  local target, offset, is_ud = mem_target(args)
  local val = is_ud and fn(target, offset) or fn(target)
  local rtti
  pcall(function()
    rtti = is_ud and memory.rtti(target, offset) or memory.rtti(target)
  end)
  return {type = ty, value = serialize(val, 0), rtti = rtti}
end

function dispatch.memory_write(args)
  local ty = tostring(args.type or "u32")
  if not MEM_TYPES[ty] then error("bad memory type: " .. ty) end
  local fn = memory["write" .. ty]
  if type(fn) ~= "function" then error("memory.write" .. ty .. " unavailable") end
  local target, offset, is_ud = mem_target(args)
  local value = args.value
  if ty ~= "string" and ty ~= "vector" and type(value) == "string" then
    value = tonumber(value)
  end
  if is_ud then fn(target, offset, value) else fn(target, value) end
  return {ok = true, type = ty, wrote = value}
end

function dispatch.memory_rtti(args)
  local target, offset, is_ud = mem_target(args)
  local name = is_ud and memory.rtti(target, offset) or memory.rtti(target)
  return {rtti = name}
end

-- Best-effort instance -> numeric pointer (the value DEX shows as "Pointer:").
-- No documented accessor exists, so probe for undocumented globals at runtime.
function dispatch.pointer(args)
  local inst = resolve_path(args.path)
  local addr, method = try_pointer(inst)
  if addr then
    return {path = get_path(inst), pointer = string.format("0x%x", addr),
            address = addr, method = method}
  end
  return {path = get_path(inst), pointer = nil,
          note = "no instance->pointer accessor available in this build"}
end

--==========================================================================--
-- Automation: remotes, structured get/set/call, synthetic input, game info
--==========================================================================--

-- Convert a JSON arg to a Lua value. {__instance="path"} -> resolved instance,
-- {__vector3={x,y,z}} -> Vector3, else the primitive as-is.
local function to_lua_arg(a)
  if type(a) == "table" then
    if a.__instance then return resolve_path(a.__instance) end
    if a.__vector3 then return Vector3.new(a.__vector3.x, a.__vector3.y, a.__vector3.z) end
  end
  return a
end

local function pack_args(raw)
  local out = {}
  raw = raw or {}
  for i = 1, #raw do out[i] = to_lua_arg(raw[i]) end
  return out, #raw
end

local function pack_returns(results)
  local ret = {}
  for i = 1, results.n do ret[i] = serialize(results[i], 0) end
  return ret
end

function dispatch.fire_remote(args)
  local remote = resolve_path(args.path)
  local method = args.method or "auto"
  if method == "auto" then
    method = (remote.ClassName == "RemoteFunction") and "InvokeServer" or "FireServer"
  end
  local fn = remote[method]
  if type(fn) ~= "function" then
    error("method '" .. tostring(method) .. "' not available on " .. tostring(remote.ClassName))
  end
  local a, n = pack_args(args.args)
  local results = table.pack(fn(remote, table.unpack(a, 1, n)))
  return {ok = true, method = method, returns = pack_returns(results)}
end

function dispatch.get(args)
  local inst = resolve_path(args.path)
  return {path = get_path(inst), property = args.property,
          value = serialize(inst[args.property], 0)}
end

function dispatch.set(args)
  local inst = resolve_path(args.path)
  inst[args.property] = to_lua_arg(args.value)
  return {ok = true, path = get_path(inst), property = args.property}
end

function dispatch.call(args)
  local inst = resolve_path(args.path)
  local fn = inst[args.method]
  if type(fn) ~= "function" then
    error("method '" .. tostring(args.method) .. "' not available on " .. tostring(inst.ClassName))
  end
  local a, n = pack_args(args.args)
  local results = table.pack(fn(inst, table.unpack(a, 1, n)))
  return {ok = true, method = args.method, returns = pack_returns(results)}
end

-- key name -> Windows virtual-key code
local VK = {space = 0x20, enter = 0x0D, ["return"] = 0x0D, tab = 0x09, shift = 0x10,
            ctrl = 0x11, control = 0x11, alt = 0x12, esc = 0x1B, escape = 0x1B,
            backspace = 0x08, delete = 0x2E, left = 0x25, up = 0x26, right = 0x27,
            down = 0x28, home = 0x24, ["end"] = 0x23}
for i = 0, 25 do VK[string.char(97 + i)] = 0x41 + i end   -- a-z
for i = 0, 9 do VK[tostring(i)] = 0x30 + i end            -- 0-9
for i = 1, 12 do VK["f" .. i] = 0x6F + i end              -- f1-f12

local function keycode(k)
  if type(k) == "number" then return k end
  local c = VK[string.lower(tostring(k))]
  if not c then error("unknown key: " .. tostring(k)) end
  return c
end

function dispatch.input(args)
  local a = args.action
  if a == "keytap" then
    local kc = keycode(args.key); keypress(kc); task.wait(); keyrelease(kc)
  elseif a == "keydown" then keypress(keycode(args.key))
  elseif a == "keyup" then keyrelease(keycode(args.key))
  elseif a == "mouse1click" then mouse1click()
  elseif a == "mouse2click" then mouse2click()
  elseif a == "mousemove" then mousemoveabs(tonumber(args.x) or 0, tonumber(args.y) or 0)
  elseif a == "mousescroll" then mousescroll(tonumber(args.amount) or 0)
  else error("unknown input action: " .. tostring(a)) end
  return {ok = true, action = a}
end

function dispatch.game_info()
  local info = {}
  pcall(function() info.PlaceId = game.PlaceId end)
  pcall(function() info.GameId = game.GameId end)
  pcall(function() info.JobId = game.JobId end)
  pcall(function() info.Hwid = game:GetHwid() end)
  pcall(function() info.Ping = game:GetPing() end)
  local ok, svc = pcall(function() return game:GetService("Players") end)
  if ok and svc then
    pcall(function()
      local lp = svc.LocalPlayer
      if lp then info.local_player = {Name = lp.Name, DisplayName = lp.DisplayName, UserId = lp.UserId} end
    end)
    pcall(function()
      local n = 0
      for _, c in ipairs(svc:GetChildren()) do if c.ClassName == "Player" then n = n + 1 end end
      info.player_count = n
    end)
  end
  return info
end

-- Follow a pointer chain: deref every offset but the last (readu64), then read
-- the final offset as `type`. `base` is an instance path OR a numeric address.
function dispatch.read_chain(args)
  local ty = tostring(args.type or "u64")
  if not MEM_TYPES[ty] then error("bad type: " .. ty) end
  local offsets = args.offsets or {}
  if #offsets == 0 then error("provide at least one offset") end

  local base = args.base
  local addr = (type(base) == "number") and base or (type(base) == "string" and tonumber(base) or nil)
  local cur, is_ud
  if addr then cur, is_ud = addr, false
  else cur, is_ud = resolve_path(tostring(base)), true end

  for i = 1, #offsets - 1 do
    local off = tonumber(offsets[i]) or 0
    cur = is_ud and memory.readu64(cur, off) or memory.readu64(cur + off)
    is_ud = false
    if type(cur) ~= "number" then error("null pointer at offset index " .. i) end
  end

  local lastOff = tonumber(offsets[#offsets]) or 0
  local readfn = memory["read" .. ty]
  local val = is_ud and readfn(cur, lastOff) or readfn(cur + lastOff)
  return {type = ty, value = serialize(val, 0)}
end

-- Bounded numeric scan in [address, address+size). ADVANCED: reading unmapped
-- memory can be unsafe; size is capped and the loop yields.
function dispatch.memory_scan(args)
  local ty = tostring(args.type or "f32")-- ty is type this got me when i first read this line lol, thank you sirmeme :)
  if not MEM_TYPES[ty] then error("bad type: " .. ty) end
  local base = args.address
  if type(base) == "string" then base = tonumber(base) end
  if type(base) ~= "number" then error("provide a numeric start address") end
  local size = math.min(tonumber(args.size) or 0x1000, 0x40000)  -- cap 256KB
  local target = tonumber(args.value)
  if not target then error("provide a numeric value to scan for") end
  local tol = tonumber(args.tolerance) or 0
  local step = (ty == "f64" or ty == "i64" or ty == "u64") and 8 or 4
  local readfn = memory["read" .. ty]
  local hits, n = {}, 0
  for off = 0, size - step, step do
    n = n + 1
    if n % YIELD_EVERY == 0 then task.wait() end
    local ok, v = pcall(function() return readfn(base + off) end)
    if ok and type(v) == "number" and math.abs(v - target) <= tol then
      hits[#hits + 1] = {address = string.format("0x%x", base + off), offset = off, value = v}
      if #hits >= 100 then break end
    end
  end
  return {scanned = n, count = #hits, hits = hits}
end

 -- okay so i decided to ditch this for later since this will just get more complicated for not a very good reason, also uh i forgot.
 -- local decodebuff = { u8 = buffer.readu8, i8 = buffer.readi8, u16 = buffer.readu16, i16 = buffer.readi16, u32 = buffer.readu32, i32 = buffer.readi32, f32 = buffer.readf32, f64 = buffer.readf64} --buffer is much better for scanning areas like this ik that it might not be that big of improvement but still yeah good practice.
  --local decodefunction = decodebuff[ty] 
  --if not decodefunction then error("types supprted are only u8,u16,u32,f32,f64 and ofc the integer ones aswell not " .. ty) end
 -- if #hits >= 100 then break end
   -- end
  --end
  --  local how_much_to_read = 0x2000
   -- local start = 0
   -- while start < size do
    --  local want = math.min(how_much_to_read, size - start) -- how much it wants to read like the size of the read/
    --  local good, buff = pcall(memory.readbuffer, base+ start, want)
     -- if good and buff ~= nil then
     --   local bufferlength = buffer.len(buff)
     --   for offset = 0, bufferlength - step, step do
        --  n= n+1
       --   local value1 = decodefunction(buff, offset)
         -- if math.abs(value1 - target) <= tol then 
           -- hits[#hits +1] = {address = string.format("0x%x", base +start + offset), offset = start+ offset, value = value1}
           -- if #hits >=100 then return {scanned = n , count = #hits, hits = hits} end

--==========================================================================--
-- WebSocket client + reconnect loop
--==========================================================================--
local socket = nil

local DEBUG = false  -- set true to print stage markers to Severe console

local function handle_message(payload)
  if DEBUG then print("[bridge] RX " .. string.sub(tostring(payload), 1, 100)) end
  local ok, msg = pcall(json.decode, payload)
  if DEBUG then print("[bridge] decoded ok=" .. tostring(ok) ..
      " id=" .. tostring(ok and type(msg) == "table" and msg.id)) end
  if not ok or type(msg) ~= "table" or not msg.id then return end

  local reply
  local fn = dispatch[msg.op]
  if not fn then
    reply = {id = msg.id, ok = false, error = "unknown op: " .. tostring(msg.op)}
  else
    if DEBUG then print("[bridge] dispatch " .. tostring(msg.op)) end
    _budget = 0
    local ok2, res = pcall(fn, msg.args or {})
    if DEBUG then print("[bridge] dispatched ok=" .. tostring(ok2)) end
    if ok2 then
      reply = {id = msg.id, ok = true, result = res}
    else
      reply = {id = msg.id, ok = false, error = tostring(res)}
    end
  end

  local enc_ok, enc = pcall(json.encode, reply)
  if DEBUG then print("[bridge] encoded ok=" .. tostring(enc_ok) ..
      " len=" .. tostring(enc_ok and #enc)) end
  if enc_ok and socket then
    pcall(function() socket:Send(enc) end)
    if DEBUG then print("[bridge] sent reply") end
  end
end

local function connect()
  -- NOTE: WebsocketClient.new() BLOCKS until it receives the first frame from
  -- the server; server.py sends a welcome frame on connect to unblock it.
  local ok, client = pcall(function() return WebsocketClient.new(WS_URL) end)
  if not ok or not client then return false end
  socket = client
  -- DataReceived is a METHOD on this build (not a :Connect signal):
  --   s:DataReceived(function(payload, isBinary) ... end)
  -- The callback is a C-call boundary; handling a command yields (Send, game
  -- API calls), which is ILLEGAL to do directly here ("attempt to yield across
  -- metamethod/C-call boundary"). So hand the work to a fresh scheduler thread
  -- via task.spawn, where yielding is allowed.
  client:DataReceived(function(payload, _isBinary)
    task.spawn(function() pcall(handle_message, payload) end)
  end)
  pcall(function()
    socket:Send(json.encode({hello = "severe-bridge", version = VERSION, token = WS_TOKEN}))
  end)
  return true
end

task.spawn(function()
  print("[severe-bridge] starting, target " .. WS_URL)
  while true do
    if socket == nil then
      if connect() then
        print("[severe-bridge] connected to " .. WS_URL)
      end
    else
      -- Liveness probe: a frame with no id/hello is ignored by the server.
      local ok = pcall(function() socket:Send(json.encode({keepalive = true})) end)
      if not ok then
        print("[severe-bridge] connection lost, reconnecting...")
        socket = nil
      end
    end
    task.wait(2)
  end
end)
