-- xflame_dump.lua : why do the X-Flame timers over the flames not show?  Records for DURATION seconds (default 90):
--   1) PlayerAbilityEvent "X-Flame" / "Scorching Star" counters (every change, with time) -> does the X-Flame counter still arrive / wrap?
--   2) every flame part: Workspace.PlayerFlames children AND any other Workspace descendant whose name contains "flame"
--      (where do flames live now, class, name, attributes, distance to you, life time until removed, birth bursts per second)
--   3) ServerBuffEvent for Flame Fuel (apply / remove, dur) and every other buff with "flame" / "fuel" in the name
--   4) LocalFX + ServerAbilityTokenEvent + CollectibleEvent payloads that mention flame
-- HOW: run it, collect a few X-Flame procs (battle tokens) + some normal flames, wait for "DONE" (or Copy any time).
--   getgenv().DUMP_SECONDS = 120  -- optional, before running
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer

if getgenv().__XFlameDump then pcall(getgenv().__XFlameDump.remove) end
local DURATION = tonumber(getgenv().DUMP_SECONDS) or 90
local t0 = os.clock()
local recording, removed = true, false
local conns = {}
local function T() return string.format("%6.2f", os.clock() - t0) end

local function ser(v, depth)
  depth = depth or 0
  local t = typeof(v)
  if t == "string" then return string.format("%q", #v > 60 and v:sub(1, 60) .. "..." or v)
  elseif t == "number" or t == "boolean" or t == "nil" then return tostring(v)
  elseif t == "Vector3" or t == "Color3" then return t .. "(" .. tostring(v) .. ")"
  elseif t == "Instance" then return "<" .. v.ClassName .. " " .. v:GetFullName() .. ">"
  elseif t == "table" then
    if depth >= 2 then return "{...}" end
    local parts, n = {}, 0
    for k, val in pairs(v) do
      n = n + 1
      if n > 10 then parts[#parts + 1] = "..." break end
      parts[#parts + 1] = "[" .. ser(k, depth + 1) .. "]=" .. ser(val, depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return "<" .. t .. ">"
end
local function mentions(v, word, depth)
  depth = depth or 0
  local t = typeof(v)
  if t == "string" then return v:lower():find(word, 1, true) ~= nil end
  if t == "table" and depth < 3 then
    for k, val in pairs(v) do
      if mentions(k, word, depth + 1) or mentions(val, word, depth + 1) then return true end
    end
  end
  return false
end

-- ---------------------------------------------------------------- recorded data
local counterLog = {}                 -- lines
local lastCounter = {}                -- name -> value
local flames = {}                     -- part -> {born, path, class, name, dist, attrs, size}
local flameDone = {}                  -- finished: {life, name, path, fuel}
local birthsPerSec = {}               -- floor(t) -> count
local flameWhere = {}                 -- parent path -> count
local buffLog = {}
local fxLog = {}
local fuelUntil = 0                   -- os.clock() until which Flame Fuel was applied (from the event itself)
local nFlameEvents = 0

local function rootPos()
  local ch = player.Character
  local r = ch and ch:FindFirstChild("HumanoidRootPart")
  return r and r.Position or nil
end

local function onFlame(part)
  if flames[part] or not part:IsA("BasePart") then return end
  local rp = rootPos()
  local attrs = {}
  pcall(function() for k, v in pairs(part:GetAttributes()) do attrs[#attrs + 1] = k .. "=" .. tostring(v) end end)
  local path = part.Parent and part.Parent:GetFullName() or "?"
  flames[part] = {
    born = os.clock(), name = part.Name, class = part.ClassName, path = path,
    dist = rp and (part.Position - rp).Magnitude or -1,
    attrs = table.concat(attrs, ","), size = tostring(part.Size), fuel = os.clock() < fuelUntil,
    color = tostring(part.Color), transp = part.Transparency,
  }
  flameWhere[path] = (flameWhere[path] or 0) + 1
  local s = math.floor(os.clock() - t0)
  birthsPerSec[s] = (birthsPerSec[s] or 0) + 1
  nFlameEvents = nFlameEvents + 1
  local conn
  conn = part.AncestryChanged:Connect(function(_, parent)
    if parent == nil then
      local f = flames[part]
      if f and not f.done then
        f.done = true
        flameDone[#flameDone + 1] = { life = os.clock() - f.born, f = f }
      end
      pcall(function() conn:Disconnect() end)
    end
  end)
end

local function watchFolder(folder)
  for _, c in ipairs(folder:GetChildren()) do onFlame(c) end
  table.insert(conns, folder.ChildAdded:Connect(function(c) if recording then pcall(onFlame, c) end end))
end

-- the folder the script uses + a search for flames anywhere else
local pf = Workspace:FindFirstChild("PlayerFlames")
local folderState = pf and ("Workspace.PlayerFlames present, " .. #pf:GetChildren() .. " children now") or "Workspace.PlayerFlames NOT FOUND at start"
if pf then watchFolder(pf) end
table.insert(conns, Workspace.ChildAdded:Connect(function(c)
  if c.Name == "PlayerFlames" then folderState = folderState .. " | (re)created at " .. T() .. "s" pcall(watchFolder, c) end
end))
table.insert(conns, Workspace.DescendantAdded:Connect(function(d)
  if not recording then return end
  if d:IsA("BasePart") and d.Name:lower():find("flame", 1, true) and not (pf and d:IsDescendantOf(pf)) then
    pcall(onFlame, d)
  end
end))

local function hook(name, fn)
  local r = RS:FindFirstChild("Events") and RS.Events:FindFirstChild(name)
  if r and r:IsA("RemoteEvent") then
    table.insert(conns, r.OnClientEvent:Connect(function(...) if recording then pcall(fn, ...) end end))
    return true
  end
  fxLog[#fxLog + 1] = "(!) remote not found: " .. name
  return false
end

hook("PlayerAbilityEvent", function(payload)
  if type(payload) ~= "table" then return end
  for _, nm in ipairs({ "X-Flame", "Scorching Star" }) do
    local e = rawget(payload, nm)
    if type(e) == "table" then
      local vals = rawget(e, "Values")
      local v = type(vals) == "table" and rawget(vals, 1) or nil
      if lastCounter[nm] ~= v then
        counterLog[#counterLog + 1] = string.format("  %ss  %-15s %s -> %s   (entry: %s)", T(), nm, tostring(lastCounter[nm]), tostring(v), ser(e, 1))
        lastCounter[nm] = v
      end
    end
  end
  if #counterLog == 0 then counterLog[1] = "  " .. T() .. "s  first PlayerAbilityEvent keys: " .. ser(payload, 1) end
end)
hook("ServerBuffEvent", function(action, src, start, dur, combo, ...)
  local s = tostring(src)
  local low = s:lower()
  if low:find("flame", 1, true) or low:find("fuel", 1, true) then
    buffLog[#buffLog + 1] = string.format("  %ss  %-8s %-18s start=%s dur=%s combo=%s", T(), tostring(action), s, tostring(start), tostring(dur), tostring(combo))
    if action == "Apply" or action == "Refresh" or action == "ChangeCombo" then
      if low:find("fuel", 1, true) and type(dur) == "number" then fuelUntil = os.clock() + dur end
    elseif action == "Remove" and low:find("fuel", 1, true) then
      fuelUntil = 0
    end
  end
end)
for _, nm in ipairs({ "LocalFX", "ServerAbilityTokenEvent", "CollectibleEvent", "ServerItemPackEvent", "ServerSystemEvent" }) do
  hook(nm, function(...)
    local args = { ... }
    if mentions(args, "flame") and #fxLog < 120 then
      fxLog[#fxLog + 1] = string.format("  %ss  %-24s %s", T(), nm, ser(args, 0):sub(1, 300))
    end
  end)
end

-- ---------------------------------------------------------------- static snapshot
local function staticScan()
  local out = {}
  local function L(s) out[#out + 1] = s end
  L("=== static scan ===")
  L("folder: " .. folderState)
  local found = {}
  for _, d in ipairs(Workspace:GetDescendants()) do
    if d.Name:lower():find("flame", 1, true) then
      local key = d.ClassName .. " @ " .. (d.Parent and d.Parent:GetFullName() or "?")
      found[key] = (found[key] or 0) + 1
    end
  end
  local ks = {}
  for k in pairs(found) do ks[#ks + 1] = k end
  table.sort(ks)
  L("instances named *flame* in Workspace (class @ parent): " .. #ks .. " kinds")
  for i = 1, math.min(#ks, 25) do L(string.format("  x%-4d %s", found[ks[i]], ks[i])) end
  local gcFlames, sample = 0, nil
  if type(getgc) == "function" then
    pcall(function()
      for _, o in ipairs(getgc(true)) do
        if type(o) == "table" and rawget(o, "flame") == true then
          gcFlames = gcFlames + 1
          if not sample then sample = ser(o, 0) end
        end
      end
    end)
    L("gc tables with flame==true (what the script's gcScan uses to find flame parts): " .. gcFlames)
    if sample then L("  sample: " .. sample:sub(1, 300)) end
    local xfTables = 0
    pcall(function()
      for _, o in ipairs(getgc(true)) do
        if type(o) == "table" and type(rawget(o, "X-Flame")) == "table" then
          xfTables = xfTables + 1
          if xfTables <= 3 then L("  gc table with X-Flame: " .. ser(rawget(o, "X-Flame"), 0):sub(1, 250)) end
        end
      end
    end)
    L("gc tables holding an 'X-Flame' entry: " .. xfTables)
  else
    L("getgc unavailable")
  end
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------- report
local staticText = ""
local function buildReport()
  local out = {}
  local function L(s) out[#out + 1] = s end
  local el = (recording and os.clock() or os.clock()) - t0
  L(string.format("=== xflame_dump: %ds recorded, recording=%s ===", math.floor(el), tostring(recording)))
  L(staticText)
  L("=== counters (PlayerAbilityEvent) ===")
  if #counterLog == 0 then L("  NOTHING received: the X-Flame / Scorching Star counters never arrive any more") end
  for _, s in ipairs(counterLog) do L(s) end
  L("=== Flame Fuel / flame buffs (ServerBuffEvent) ===")
  if #buffLog == 0 then L("  none") end
  for _, s in ipairs(buffLog) do L(s) end
  L("=== flame parts: " .. nFlameEvents .. " seen ===")
  local ks = {}
  for k in pairs(flameWhere) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return flameWhere[a] > flameWhere[b] end)
  for _, k in ipairs(ks) do L(string.format("  parent %-60s x%d", k, flameWhere[k])) end
  -- life times
  local n, sum, mn, mx = 0, 0, 1e9, 0
  local nF, sumF, nN, sumN = 0, 0, 0, 0
  for _, d in ipairs(flameDone) do
    n = n + 1 sum = sum + d.life mn = math.min(mn, d.life) mx = math.max(mx, d.life)
    if d.f.fuel then nF = nF + 1 sumF = sumF + d.life else nN = nN + 1 sumN = sumN + d.life end
  end
  if n > 0 then
    L(string.format("  life time (appear -> removed): n=%d avg=%.2fs min=%.2fs max=%.2fs", n, sum / n, mn, mx))
    if nF > 0 then L(string.format("    with Flame Fuel buff: n=%d avg=%.2fs", nF, sumF / nF)) end
    if nN > 0 then L(string.format("    without Flame Fuel:   n=%d avg=%.2fs", nN, sumN / nN)) end
  else
    L("  no flame was seen being removed yet")
  end
  L("  births per second (only seconds with >= 4 new flames = bursts):")
  local secs = {}
  for s, c in pairs(birthsPerSec) do if c >= 4 then secs[#secs + 1] = s end end
  table.sort(secs)
  for i = 1, math.min(#secs, 40) do L(string.format("    t=%3ds  +%d flames", secs[i], birthsPerSec[secs[i]])) end
  L("  first 25 flame parts (name / class / dist / size / fuel / attrs):")
  local list = {}
  for part, f in pairs(flames) do list[#list + 1] = f end
  table.sort(list, function(a, b) return a.born < b.born end)
  for i = 1, math.min(#list, 25) do
    local f = list[i]
    L(string.format("    %6.2fs %-18s %-8s dist=%5.1f size=%s fuel=%s tr=%.2f col=%s attrs=%s", f.born - t0, f.name, f.class, f.dist, f.size, tostring(f.fuel), f.transp or 0, f.color, f.attrs))
  end
  L("=== events that mention flame (LocalFX / tokens / collectibles / item packs) ===")
  if #fxLog == 0 then L("  none") end
  for _, s in ipairs(fxLog) do L(s) end
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------- GUI
local gui = Instance.new("ScreenGui")
gui.Name = "XFlameDumpGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.IgnoreGuiInset = true
local okParent = false
if type(gethui) == "function" then okParent = pcall(function() gui.Parent = gethui() end) end
if not okParent then okParent = pcall(function() gui.Parent = game:GetService("CoreGui") end) end
if not okParent or not gui.Parent then gui.Parent = player:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(300, 214)
frame.Position = UDim2.new(1, -320, 0, 90)
frame.BackgroundColor3 = Color3.fromRGB(18, 8, 11)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 6)
local fs = Instance.new("UIStroke", frame)
fs.Color = Color3.fromRGB(120, 38, 48)
fs.Thickness = 1

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 26)
title.BackgroundTransparency = 1
title.Text = "  xflame_dump"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 220, 220)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Active = true
title.Parent = frame

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(10, 30)
status.Size = UDim2.new(1, -20, 0, 74)
status.BackgroundTransparency = 1
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextColor3 = Color3.fromRGB(226, 214, 214)
status.Font = Enum.Font.Code
status.TextSize = 13
status.Text = ""
status.Parent = frame

local note = Instance.new("TextLabel")
note.Position = UDim2.fromOffset(10, 104)
note.Size = UDim2.new(1, -20, 0, 18)
note.BackgroundTransparency = 1
note.TextXAlignment = Enum.TextXAlignment.Left
note.TextColor3 = Color3.fromRGB(150, 220, 160)
note.Font = Enum.Font.Code
note.TextSize = 12
note.Text = ""
note.Parent = frame
local function flash(msg)
  note.Text = msg
  task.delay(3, function() if note.Text == msg then note.Text = "" end end)
end

local function button(text, x, y, w, color, fn)
  local b = Instance.new("TextButton")
  b.Position = UDim2.fromOffset(x, y)
  b.Size = UDim2.fromOffset(w, 32)
  b.BackgroundColor3 = color
  b.BorderSizePixel = 0
  b.Text = text
  b.TextColor3 = Color3.fromRGB(255, 240, 240)
  b.Font = Enum.Font.GothamBold
  b.TextSize = 13
  b.Parent = frame
  Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
  b.MouseButton1Click:Connect(function() pcall(fn) end)
  return b
end

local function stopRecording()
  if not recording then return end
  recording = false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  conns = {}
end
local function removeAll()
  if removed then return end
  removed = true
  stopRecording()
  pcall(function() gui:Destroy() end)
  getgenv().__XFlameDump = nil
  print("[xflame_dump] removed")
end

button("Copy", 10, 128, 66, Color3.fromRGB(60, 120, 70), function()
  local r = buildReport()
  if setclipboard then setclipboard(r) flash("copied " .. #r .. " chars") else flash("no setclipboard - use Save") end
end)
button("Save", 82, 128, 66, Color3.fromRGB(60, 90, 140), function()
  local r = buildReport()
  if writefile then flash(pcall(writefile, "BuffTools_xflame_dump.txt", r) and "saved BuffTools_xflame_dump.txt" or "save failed") else flash("no writefile") end
end)
button("Reset data", 154, 128, 136, Color3.fromRGB(100, 80, 140), function()
  counterLog, lastCounter, flames, flameDone, birthsPerSec, flameWhere, buffLog, fxLog = {}, {}, {}, {}, {}, {}, {}, {}
  nFlameEvents = 0
  t0 = os.clock()
  flash("counters reset")
end)
button("Stop", 10, 168, 66, Color3.fromRGB(140, 100, 40), function() stopRecording() flash("stopped - press Copy") end)
button("Remove", 82, 168, 208, Color3.fromRGB(150, 36, 46), removeAll)

do
  local dragging, start, origin
  title.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
      dragging, start, origin = true, i.Position, frame.Position
    end
  end)
  UIS.InputChanged:Connect(function(i)
    if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
      local d = i.Position - start
      frame.Position = UDim2.new(origin.X.Scale, origin.X.Offset + d.X, origin.Y.Scale, origin.Y.Offset + d.Y)
    end
  end)
  UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
  end)
end

getgenv().__XFlameDump = { remove = removeAll }
print("[xflame_dump] recording " .. DURATION .. "s - proc X-Flame a few times (battle tokens) and keep flames around you")

task.spawn(function()
  task.wait(0.3)
  local ok, r = pcall(staticScan)
  staticText = ok and r or ("static scan error: " .. tostring(r))
  flash("static scan done")
end)

task.spawn(function()
  while not removed do
    task.wait(0.5)
    if recording then
      local left = math.max(0, DURATION - (os.clock() - t0))
      status.Text = string.format("recording: %ds left\nflames seen: %d (done %d)\nX-Flame: %s   Scorch: %s",
        math.ceil(left), nFlameEvents, #flameDone, tostring(lastCounter["X-Flame"]), tostring(lastCounter["Scorching Star"]))
      if left <= 0 then
        stopRecording()
        local r = buildReport()
        if setclipboard then pcall(setclipboard, r) end
        if writefile then pcall(writefile, "BuffTools_xflame_dump.txt", r) end
        flash("DONE - copied + saved")
      end
    else
      status.Text = string.format("STOPPED\nflames seen: %d (done %d)", nFlameEvents, #flameDone)
    end
  end
end)
