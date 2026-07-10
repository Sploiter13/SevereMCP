--[[
  Example: memory-read ESP + toggle GUI, built entirely through SevereMCP.

  This is the script an AI agent produced (via `severe_execute`) while reverse-
  engineering a custom-character Roblox FPS live through the MCP. It demonstrates
  what the MCP can drive: memory reads, Drawing, HttpGet, a UI library, and a
  RunService.Render loop.

  === IMPORTANT: the memory offsets below are GAME- and ROBLOX-BUILD-specific ===
  In this particular game the visible characters are bone-driven skinned meshes, so
  the usual .Position/.CFrame return a static bind pose and the networked
  HumanoidRootPart is a frozen decoy. The REAL world position was found in memory:

      Part + 0x128  -> Primitive pointer
      Primitive + 0xec -> position vector

  Re-derive these if the game or Roblox updates: read a part whose .Position you
  know, scan `memory.readu64(part, off)` for the Primitive pointer, then scan
  `memory.readvector(prim + off2)` for the offset whose value matches .Position.
  (SevereMCP's `severe_execute` makes this scanning loop trivial.)

  Requires: an active Roblox game + Severe's Luau env. Toggle the menu with RightShift.
--]]

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local WS          = game:GetService("Workspace")
local LP          = Players.LocalPlayer

-- clean up a previous run's render loop
if _G.__esp_conn then pcall(function() _G.__esp_conn:Disconnect() end) _G.__esp_conn = nil end

-- persistent toggles (Severe exposes _G, not getgenv)
_G.SevereESP = _G.SevereESP or {}
local S = _G.SevereESP
if S.enabled   == nil then S.enabled = true end
if S.teamcheck == nil then S.teamcheck = true end

-- real world position via the reverse-engineered chain
local function chainPos(part)
  local okp, prim = pcall(function() return memory.readu64(part, 0x128) end)
  if not okp or type(prim) ~= "number" then return nil end
  local okv, v = pcall(function() return memory.readvector(prim + 0xec) end)
  if okv and v and (pcall(function() return v.X end)) and v.X then return v end
end

local function teamColor(team)
  if team then
    local ok, c = pcall(function() return team.TeamColor.Color end)
    if ok and c then return c end
  end
  return Color3.fromRGB(255, 80, 80)
end

if S.conn then pcall(function() S.conn:Disconnect() end) end
S.conn = RunService.Render:Connect(function()
  if not S.enabled then return end
  local cam = WS.CurrentCamera
  local cm  = WS:FindFirstChild("CharacterMeshes")     -- visible rigs, named by player
  if not cam or not cm then return end
  local myTeam = LP.Team
  for _, model in ipairs(cm:GetChildren()) do
    local name = model.Name
    if name ~= LP.Name then
      local plr  = Players:FindFirstChild(name)
      local team = plr and plr.Team
      local sameTeam = myTeam and team and (team == myTeam)
      if not (S.teamcheck and sameTeam) then
        local root = model:FindFirstChild("RootPart")
        local mp = root and chainPos(root)
        if mp then
          local feet = Vector3.new(mp.X, mp.Y, mp.Z)
          local sB, vB = cam:WorldToScreenPoint(feet)
          local sT, vT = cam:WorldToScreenPoint(feet + Vector3.new(0, 6, 0))
          if vB or vT then
            local h  = math.abs(sB.Y - sT.Y)
            local w  = h * 0.55
            local cx = (sT.X + sB.X) * 0.5
            local yT = math.min(sT.Y, sB.Y)
            local col = teamColor(team)
            DrawingImmediate.Rectangle(Vector2.new(cx - w/2, yT), Vector2.new(w, h), col, 1, 1)
            DrawingImmediate.OutlinedText(Vector2.new(cx, yT - 15), 13, col, 1, name, true)
          end
        end
      end
    end
  end
end)

-- GUI (any Severe UI library works; this uses one loaded via HttpGet)
local gui_ok, gui_err = pcall(function()
  if S.gui then return end
  local severeui = loadstring(game:HttpGet("https://raw.githubusercontent.com/okdude42/ui-lib/refs/heads/main/SevereLib.lua"))()
  local window = severeui:createwindow({
    Title = "SevereMCP ESP",
    Version = "v1",
    Keybind = "RightShift",
    ConfigFolder = "SevereMCP_ESP",
    CustomResolution = Vector2.new(520, 300),
    DefaultTab = "Visuals",
    TabAlignment = "Center",
    DefaultSnowfall = false,
  })
  local tab = window:createtab("Visuals")
  window:createlabel(tab, "PLAYER ESP", 1)
  window:createtoggle(tab, { Name = "ESP Enabled", Col = 1, Default = S.enabled,
    Callback = function(state) S.enabled = state end })
  window:createtoggle(tab, { Name = "Team Check (enemies only)", Col = 1, Default = S.teamcheck,
    Callback = function(state) S.teamcheck = state end })
  S.gui = window
end)

print("[SevereMCP ESP] loaded — enabled=" .. tostring(S.enabled) ..
      " teamcheck=" .. tostring(S.teamcheck) .. " gui_ok=" .. tostring(gui_ok) ..
      (gui_err and (" err=" .. tostring(gui_err)) or ""))
