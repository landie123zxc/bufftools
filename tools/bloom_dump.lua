-- bloom_dump.lua : how does the game build / report a Bloom (and its petals), and how do we tell a PINK one?
-- Goal: draw a nice outline (Highlight) around the Pink Bloom model + flash "PINK BLOOM" on the screen for 1s.
-- For that we need: the bloom model (name / parent / parts), where its colour lives, the event when it spawns,
-- the explosion (petals) and the Pink Petal buff name.
--
-- HOW TO RUN: go to a field that has blooms (Strawberry Field is best for Pink), wait until you see one.
--   * stand next to a PINK bloom and press  "MARK nearest bloom (PINK)"  - a full model dump of the closest thing is taken
--   * press "MARK: other colour bloom" next to a different colour bloom (so we can compare the colours)
--   * collect its petals (the explosion) - the dump records every event around it
--   * press "MARK nearest petal" when a petal is next to you
-- Run ~4-5 minutes. Report: clipboard (Copy / auto at the end) + file BuffTools_bloom_dump.txt.
--   getgenv().DUMP_SECONDS = 400   -- optional, before running (default 300)
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer

if getgenv().__BloomDump then pcall(getgenv().__BloomDump.remove) end
local DURATION = tonumber(getgenv().DUMP_SECONDS) or 300
local out = {}
local function log(s) out[#out + 1] = s end
local function say(s) print("[bloom_dump] " .. s) end

local KW = { "bloom", "petal", "shaker" }
local function kwOf(s)
  if type(s) ~= "string" then return nil end
  local l = s:lower()
  for i = 1, #KW do
    if l:find(KW[i], 1, true) then return KW[i] end
  end
  return nil
end

-- ---------------------------------------------------------------- serializer
local function ser(v, depth, seen)
  depth = depth or 0
  local t = typeof(v)
  if t == "string" then
    if #v > 100 then return string.format("%q", v:sub(1, 100)) .. "..." end
    return string.format("%q", v)
  elseif t == "number" or t == "boolean" or t == "nil" then
    return tostring(v)
  elseif t == "Vector3" or t == "Vector2" or t == "CFrame" or t == "Color3" or t == "UDim2" then
    return t .. "(" .. tostring(v) .. ")"
  elseif t == "Instance" then
    return "<" .. v.ClassName .. " " .. v:GetFullName() .. ">"
  elseif t == "table" then
    seen = seen or {}
    if seen[v] then return "<cycle>" end
    if depth >= 3 then return "{...}" end
    seen[v] = true
    local parts, n = {}, 0
    for k, val in pairs(v) do
      n = n + 1
      if n > 16 then parts[#parts + 1] = "..." break end
      parts[#parts + 1] = "[" .. ser(k, depth + 1, seen) .. "]=" .. ser(val, depth + 1, seen)
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return "<" .. t .. ">"
end

local function mentions(v, depth, seen)
  if type(v) == "string" then return kwOf(v) end
  if type(v) ~= "table" or depth > 3 then return nil end
  seen = seen or {}
  if seen[v] then return nil end
  seen[v] = true
  local n = 0
  for k, val in pairs(v) do
    n = n + 1
    if n > 40 then break end
    local a = kwOf(type(k) == "string" and k or nil) or mentions(val, depth + 1, seen)
    if a then return a end
  end
  return nil
end

local function payloadStr(args)
  local p = {}
  for i = 1, math.min(args.n, 6) do p[i] = ser(args[i], 1) end
  return table.concat(p, " | ")
end

local function fmtV(v) return string.format("(%.2f,%.2f,%.2f)", v.X, v.Y, v.Z) end
local function fmtC(c) return string.format("rgb(%d,%d,%d)", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)) end

-- ---------------------------------------------------------------- full description of an instance tree
-- one line per instance: class, geometry, colour, textures, texts, values, attributes. This is where the colour of a bloom lives.
local function lineOf(d, indent)
  local s = indent .. d.Name .. " <" .. d.ClassName .. ">"
  pcall(function()
    if d:IsA("BasePart") then
      s = s .. string.format(" pos=%s size=%s col=%s mat=%s tr=%.2f", fmtV(d.Position), fmtV(d.Size), fmtC(d.Color), tostring(d.Material), d.Transparency)
      if d:IsA("MeshPart") then s = s .. " mesh=" .. tostring(d.MeshId) .. " tex=" .. tostring(d.TextureID) end
    elseif d:IsA("SpecialMesh") then
      s = s .. " mesh=" .. tostring(d.MeshId) .. " tex=" .. tostring(d.TextureId) .. " vc=" .. fmtV(d.VertexColor)
    elseif d:IsA("Decal") or d:IsA("Texture") then
      s = s .. " tex=" .. tostring(d.Texture) .. " col=" .. fmtC(d.Color3)
    elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
      s = s .. " img=" .. tostring(d.Image) .. " col=" .. fmtC(d.ImageColor3)
    elseif d:IsA("TextLabel") or d:IsA("TextButton") then
      s = s .. " text=" .. string.format("%q", d.Text:sub(1, 60)) .. " col=" .. fmtC(d.TextColor3)
    elseif d:IsA("ValueBase") then
      s = s .. " value=" .. tostring(d.Value)
    elseif d:IsA("ParticleEmitter") then
      s = s .. " tex=" .. tostring(d.Texture) .. " col0=" .. fmtC(d.Color.Keypoints[1].Value) .. " enabled=" .. tostring(d.Enabled)
    elseif d:IsA("Highlight") then
      s = s .. " fill=" .. fmtC(d.FillColor) .. " outline=" .. fmtC(d.OutlineColor)
    elseif d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
      s = s .. " light=" .. fmtC(d.Color)
    elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
      s = s .. " adornee=" .. tostring(d.Adornee and d.Adornee.Name or nil)
    elseif d:IsA("Model") then
      local cf = d:GetPivot()
      s = s .. " pivot=" .. fmtV(cf.Position)
    end
  end)
  local ok, attrs = pcall(function() return d:GetAttributes() end)
  if ok and type(attrs) == "table" then
    local a, n = {}, 0
    for k, v in pairs(attrs) do
      n = n + 1
      if n > 10 then a[#a + 1] = "..." break end
      a[#a + 1] = k .. "=" .. ser(v, 1)
    end
    if #a > 0 then s = s .. " attrs{" .. table.concat(a, ", ") .. "}" end
  end
  return s
end

local function describeTree(root, L, maxLines, maxDepth)
  local lines = 0
  local function walk(d, depth)
    if lines >= maxLines then return end
    lines = lines + 1
    L(lineOf(d, string.rep("  ", depth + 1)))
    if depth >= maxDepth then return end
    local kids = d:GetChildren()
    for i = 1, math.min(#kids, 14) do walk(kids[i], depth + 1) end
    if #kids > 14 then
      lines = lines + 1
      L(string.rep("  ", depth + 2) .. "... +" .. (#kids - 14) .. " more children (" .. kids[15].Name .. ", ...)")
    end
  end
  walk(root, 0)
end

local function posOf(inst)
  if inst:IsA("BasePart") then return inst.Position end
  local ok, cf = pcall(function() return inst:GetPivot() end)
  if ok and cf then return cf.Position end
  return nil
end

local function charPos()
  local ch = player.Character
  local r = ch and ch:FindFirstChild("HumanoidRootPart")
  return r and r.Position or nil
end

-- ---------------------------------------------------------------- state
local NOISE = {
  FlyingEntityMoveToPart = true, FlyingEntitySetMovespeed = true, FlyingEntityMove = true,
  FlyingEntitySetFacingDir = true, FlyingEntityCreate = true, FlyingEntityDestroy = true,
  BeeAnimPlay = true, BeeEmote = true, PlanterModelGrow = true, PlayerAbilityEvent = true,
  BeeConversionLink = true, PoppablePlant_Remove = true, PoppablePlant_Spawn = true, PoppablePlant_Update = true,
  CollectibleEvent = true, ServerItemPackEvent = true, CharacterGuiEvent = true, StationEvent = true,
  ServerSystemEvent = true, BeeLevelUp = true, EpochIntervalBackupUpdate = true,
}
local counts = {}            -- remote name -> count
local ring = {}              -- recent non-noise events {t, line}
local evLines = {}           -- keyword events (with context)
local petalEvents = {}       -- every PetalCollected payload
local burstLines = {}        -- CollectibleEvent / ServerItemPackEvent right around a bloom burst
local buffLines = {}         -- ServerBuffEvent mentioning petal
local tracked = {}           -- bloom roots: inst -> {born, snap}
local trackedList = {}
local changes = {}           -- attribute / text / value changes of tracked blooms
local nearDumps = {}         -- MARK results
local wsFound = {}           -- bloom-like instances found in Workspace
local marks = 0
local recording = true
local conns = {}
local t0 = os.clock()
local stoppedAt = nil
local burstUntil = 0

-- ---------------------------------------------------------------- remotes
local function onRemote(name, args)
  if not recording then return end
  local now = os.clock()
  counts[name] = (counts[name] or 0) + 1

  if name == "PetalCollected" then
    burstUntil = now + 4
    if #petalEvents < 40 then petalEvents[#petalEvents + 1] = string.format("[%.2f] %s", now - t0, payloadStr(args):sub(1, 600)) end
  end

  if now < burstUntil and (name == "CollectibleEvent" or name == "ServerItemPackEvent") and #burstLines < 90 then
    burstLines[#burstLines + 1] = string.format("[%.2f] %s: %s", now - t0, name, payloadStr(args):sub(1, 500))
  end

  local kw
  for i = 1, math.min(args.n, 8) do kw = kw or mentions(args[i], 0) end

  if name == "ServerBuffEvent" and kw and #buffLines < 60 then
    buffLines[#buffLines + 1] = string.format("[%.2f] %s", now - t0, payloadStr(args):sub(1, 400))
  end

  if not NOISE[name] then
    local line = string.format("[%.2f] %s: %s", now - t0, name, payloadStr(args))
    if #line > 420 then line = line:sub(1, 420) .. "..." end
    ring[#ring + 1] = { now, line }
    if #ring > 120 then table.remove(ring, 1) end
    if kw and #evLines < 260 then
      burstUntil = math.max(burstUntil, now + 3)
      for i = 1, #ring do
        if now - ring[i][1] <= 2 and ring[i][2] ~= line then evLines[#evLines + 1] = "  (before) " .. ring[i][2] end
      end
      evLines[#evLines + 1] = ">>> [" .. kw .. "] " .. line
    end
  elseif kw and #evLines < 260 then
    local line = string.format("[%.2f] %s: %s", now - t0, name, payloadStr(args))
    burstUntil = math.max(burstUntil, now + 3)
    evLines[#evLines + 1] = ">>> [" .. kw .. "] " .. line:sub(1, 420)
  end
end

local hooked, seenR = 0, {}
local function hookAll()
  for _, d in ipairs(RS:GetDescendants()) do
    if d:IsA("RemoteEvent") and not seenR[d] then
      seenR[d] = true
      hooked = hooked + 1
      local name = d.Name
      table.insert(conns, d.OnClientEvent:Connect(function(...)
        onRemote(name, table.pack(...))
      end))
    end
  end
end
hookAll()

-- ---------------------------------------------------------------- workspace: bloom instances
local function rootOf(inst)
  -- the outermost ancestor (below Workspace) whose name still smells like bloom/petal
  local best = inst
  local p = inst.Parent
  while p and p ~= workspace do
    if kwOf(p.Name) then best = p end
    p = p.Parent
  end
  return best
end

local function snapshotOf(root)
  local parts = {}
  local n = 0
  local function add(d)
    n = n + 1
    if n > 80 then return end
    local ok, attrs = pcall(function() return d:GetAttributes() end)
    if ok then
      for k, v in pairs(attrs) do parts[#parts + 1] = d.Name .. "@" .. k .. "=" .. ser(v, 1) end
    end
    pcall(function()
      if d:IsA("ValueBase") then parts[#parts + 1] = d.Name .. "=" .. tostring(d.Value)
      elseif d:IsA("TextLabel") or d:IsA("TextButton") then parts[#parts + 1] = d.Name .. "#" .. d.Text
      elseif d:IsA("BasePart") and (d.Name:lower():find("bloom") or d == root) then parts[#parts + 1] = d.Name .. "~" .. fmtC(d.Color) .. string.format(" sz=%s", fmtV(d.Size))
      end
    end)
  end
  add(root)
  for _, d in ipairs(root:GetDescendants()) do add(d) end
  table.sort(parts)
  return table.concat(parts, "; ")
end

local function trackRoot(root, why)
  if tracked[root] or not root.Parent then return end
  local now = os.clock()
  tracked[root] = { born = now, snap = nil }
  trackedList[#trackedList + 1] = root
  local p = posOf(root)
  wsFound[#wsFound + 1] = string.format("[%.1fs] %s <%s> %s%s", now - t0, root:GetFullName(), root.ClassName, p and ("pos=" .. fmtV(p)) or "", why and (" (" .. why .. ")") or "")
  burstUntil = math.max(burstUntil, now + 2)
  task.delay(0.6, function()
    if not recording or not root.Parent then return end
    log("")
    log(string.format("=== NEW workspace instance at %.1fs: %s <%s> ===", now - t0, root:GetFullName(), root.ClassName))
    describeTree(root, log, 70, 4)
  end)
end

table.insert(conns, workspace.DescendantAdded:Connect(function(inst)
  if not recording then return end
  if kwOf(inst.Name) then
    local root = rootOf(inst)
    trackRoot(root, "added")
  end
end))
table.insert(conns, workspace.DescendantRemoving:Connect(function(inst)
  if not recording then return end
  if tracked[inst] then
    local now = os.clock()
    burstUntil = math.max(burstUntil, now + 4)
    local p = posOf(inst)
    wsFound[#wsFound + 1] = string.format("[%.1fs] REMOVED %s %s (lived %.1fs)", now - t0, inst:GetFullName(), p and fmtV(p) or "", now - tracked[inst].born)
    tracked[inst] = nil
  end
end))

-- ---------------------------------------------------------------- static scan
local function staticScan()
  log("=== Workspace direct children (look for a Blooms folder) ===")
  local kids = workspace:GetChildren()
  local names = {}
  for _, k in ipairs(kids) do names[#names + 1] = k.Name .. "<" .. k.ClassName .. ">" end
  log("  " .. table.concat(names, ", "))

  log("=== ReplicatedStorage instances named like bloom / petal / shaker ===")
  local n = 0
  for _, d in ipairs(RS:GetDescendants()) do
    if kwOf(d.Name) then
      n = n + 1
      if n <= 100 then log("  " .. d:GetFullName() .. " <" .. d.ClassName .. ">") end
    end
  end
  log("  [" .. n .. " hits]")

  log("=== modules named like bloom / petal (require, top-level entries) ===")
  local mods = 0
  for _, m in ipairs(RS:GetDescendants()) do
    if m:IsA("ModuleScript") and kwOf(m.Name) and mods < 8 then
      mods = mods + 1
      local ok, mod = pcall(require, m)
      if not ok then
        log("  require " .. m:GetFullName() .. " failed: " .. tostring(mod):sub(1, 120))
      elseif type(mod) ~= "table" then
        log("  " .. m:GetFullName() .. " returned " .. typeof(mod))
      else
        local keys = {}
        for k, v in pairs(mod) do keys[#keys + 1] = tostring(k) .. ":" .. typeof(v) end
        table.sort(keys)
        log("  " .. m:GetFullName() .. " keys: " .. table.concat(keys, ", "):sub(1, 900))
        for k, v in pairs(mod) do
          if type(v) == "table" and (kwOf(tostring(k)) or mentions(v, 0)) then
            log("    [" .. tostring(k) .. "] = " .. ser(v, 0):sub(1, 900))
          end
        end
      end
    end
  end

  -- bloom-like things already in Workspace (blooms standing on the field right now)
  log("=== Workspace instances named like bloom / petal / shaker (existing at start) ===")
  local found, scanned = 0, 0
  for _, d in ipairs(workspace:GetDescendants()) do
    scanned = scanned + 1
    if scanned % 4000 == 0 then task.wait() end
    if kwOf(d.Name) then
      found = found + 1
      if found <= 40 then
        local root = rootOf(d)
        local p = posOf(d)
        log("  " .. d:GetFullName() .. " <" .. d.ClassName .. ">" .. (p and (" pos=" .. fmtV(p)) or ""))
        if found <= 12 then trackRoot(root, "existing") end
      end
    end
  end
  log("  [" .. found .. " hits in " .. scanned .. " instances]")
end

-- ---------------------------------------------------------------- MARK: dump whatever is nearest
-- groups everything within `radius` studs by name (so the bloom model is found even if its name has no keyword)
local function nearScan(radius)
  local cp = charPos()
  if not cp then return {}, nil end
  local ch = player.Character
  local groups = {}
  local function consider(inst)
    if ch and inst:IsDescendantOf(ch) then return end
    local p = posOf(inst)
    if not p then return end
    local d = (p - cp).Magnitude
    if d > radius then return end
    -- group by the first ancestor below Workspace / its direct parent folder, to see the structure
    local key = inst.Name .. " <" .. inst.ClassName .. "> in " .. (inst.Parent and inst.Parent.Name or "?")
    local g = groups[key]
    if not g then g = { n = 0, best = inst, bd = d, key = key } groups[key] = g end
    g.n = g.n + 1
    if d < g.bd then g.best, g.bd = inst, d end
  end
  local scanned = 0
  for _, d in ipairs(workspace:GetDescendants()) do
    scanned = scanned + 1
    if scanned % 5000 == 0 then task.wait() end
    if d:IsA("Model") or (d:IsA("BasePart") and d.Name ~= "Baseplate") then consider(d) end
  end
  local list = {}
  for _, g in pairs(groups) do list[#list + 1] = g end
  table.sort(list, function(a, b) return a.bd < b.bd end)
  return list, cp
end

local function doMark(label, wantKw)
  marks = marks + 1
  local now = os.clock()
  local id = marks
  burstUntil = math.max(burstUntil, now + 2)
  task.spawn(function()
    local list, cp = nearScan(48)
    local L = function(s) nearDumps[#nearDumps + 1] = s end
    L("")
    L(string.format("=== MARK #%d (%s) at %.1fs, player at %s ===", id, label, now - t0, cp and fmtV(cp) or "?"))
    L("  nearby groups (name <class> in parent : count, nearest distance) - the bloom is in here:")
    for i = 1, math.min(#list, 45) do
      local g = list[i]
      L(string.format("    %-52s x%-3d nearest %.1f studs  %s", g.key:sub(1, 52), g.n, g.bd, g.best:GetFullName():sub(1, 90)))
    end
    -- full dump of: the nearest keyword-named instance, and the 3 nearest Models that are not part of the map (no Part groups)
    local shown = {}
    local function full(inst, why)
      if shown[inst] then return end
      shown[inst] = true
      L("  --- " .. why .. ": " .. inst:GetFullName() .. " <" .. inst.ClassName .. "> ---")
      describeTree(inst, L, 60, 4)
    end
    if cp then
      local bestKw, bd = nil, 1e9
      for _, d in ipairs(workspace:GetDescendants()) do
        if kwOf(d.Name) then
          local p = posOf(d)
          if p then
            local dist = (p - cp).Magnitude
            if dist < bd then bestKw, bd = d, dist end
          end
        end
      end
      if bestKw then full(rootOf(bestKw), string.format("nearest keyword-named (%.1f studs)", bd)) else L("  (no instance with bloom/petal in its name anywhere in Workspace)") end
      local nModels = 0
      for i = 1, #list do
        local g = list[i]
        if g.best:IsA("Model") and nModels < 3 and g.bd < 30 then
          nModels = nModels + 1
          full(g.best, string.format("nearby Model %.1f studs", g.bd))
        end
      end
    end
    say("mark #" .. id .. " saved (" .. label .. ")")
  end)
end

-- ---------------------------------------------------------------- polling: changes of tracked blooms
task.spawn(function()
  while recording do
    task.wait(1)
    for i = #trackedList, 1, -1 do
      local root = trackedList[i]
      local st = tracked[root]
      if not st or not root.Parent then
        table.remove(trackedList, i)
      else
        local ok, snap = pcall(snapshotOf, root)
        if ok and snap ~= st.snap then
          if st.snap ~= nil and #changes < 120 then
            changes[#changes + 1] = string.format("[%.1fs] %s CHANGED: %s", os.clock() - t0, root.Name, snap:sub(1, 900))
          elseif st.snap == nil and #changes < 120 then
            changes[#changes + 1] = string.format("[%.1fs] %s INITIAL: %s", os.clock() - t0, root.Name, snap:sub(1, 900))
          end
          st.snap = snap
        end
      end
    end
  end
end)

-- ---------------------------------------------------------------- report
local function buildReport()
  local live = {}
  local function L(s) live[#live + 1] = s end
  if recording then L("(!) recording still running - partial report") end
  L("=== bloom_dump: recorded " .. math.floor((stoppedAt or os.clock()) - t0) .. "s, marks: " .. marks .. ", tracked roots: " .. #wsFound .. " ===")

  L("=== bloom-like instances (added / removed in Workspace) ===")
  if #wsFound == 0 then L("  none") end
  for _, s in ipairs(wsFound) do L("  " .. s) end

  L("=== PetalCollected payloads ===")
  if #petalEvents == 0 then L("  none (no petal collected during the run)") end
  for _, s in ipairs(petalEvents) do L("  " .. s) end

  L("=== buff events mentioning petal / bloom ===")
  if #buffLines == 0 then L("  none") end
  for _, s in ipairs(buffLines) do L("  " .. s) end

  L("=== remote events whose payload mentions bloom / petal / shaker (with 2s of context) ===")
  if #evLines == 0 then L("  none") end
  for _, s in ipairs(evLines) do L("  " .. s) end

  L("=== CollectibleEvent / ServerItemPackEvent right around a bloom burst (explosion / petal pickups) ===")
  if #burstLines == 0 then L("  none") end
  for _, s in ipairs(burstLines) do L("  " .. s) end

  L("=== changes of tracked blooms (attributes / texts / values / colours) ===")
  if #changes == 0 then L("  none") end
  for _, s in ipairs(changes) do L("  " .. s) end

  L("=== remotes seen (count) ===")
  local rk = {}
  for k in pairs(counts) do rk[#rk + 1] = k end
  table.sort(rk, function(a, b) return counts[a] > counts[b] end)
  for _, k in ipairs(rk) do L(string.format("  %-34s x%d", k, counts[k])) end

  return table.concat(out, "\n") .. "\n" .. table.concat(nearDumps, "\n") .. "\n" .. table.concat(live, "\n")
end

local function stopRecording()
  if not recording then return end
  recording = false
  stoppedAt = os.clock()
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  conns = {}
end

-- ---------------------------------------------------------------- GUI
local gui = Instance.new("ScreenGui")
gui.Name = "BloomDumpGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.IgnoreGuiInset = true
local okParent = false
if type(gethui) == "function" then okParent = pcall(function() gui.Parent = gethui() end) end
if not okParent then okParent = pcall(function() gui.Parent = game:GetService("CoreGui") end) end
if not okParent or not gui.Parent then gui.Parent = player:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(300, 306)
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
title.Text = "  bloom_dump"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 220, 220)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Active = true
title.Parent = frame

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(10, 30)
status.Size = UDim2.new(1, -20, 0, 76)
status.BackgroundTransparency = 1
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextColor3 = Color3.fromRGB(226, 214, 214)
status.Font = Enum.Font.Code
status.TextSize = 13
status.Text = ""
status.Parent = frame

local note = Instance.new("TextLabel")
note.Position = UDim2.fromOffset(10, 108)
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

local removed = false
local function copyReport()
  local r = buildReport()
  if setclipboard then setclipboard(r) flash("copied " .. #r .. " chars") else flash("no setclipboard - use Save") end
end
local function saveReport()
  local r = buildReport()
  if writefile then
    local ok = pcall(writefile, "BuffTools_bloom_dump.txt", r)
    flash(ok and "saved BuffTools_bloom_dump.txt" or "save failed")
  else
    flash("no writefile")
  end
end
local function removeAll()
  if removed then return end
  removed = true
  recording = false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  conns = {}
  pcall(function() gui:Destroy() end)
  getgenv().__BloomDump = nil
  print("[bloom_dump] removed")
end

button("MARK nearest bloom (PINK)", 10, 132, 280, Color3.fromRGB(190, 70, 130), function()
  doMark("PINK bloom", true)
  flash("mark #" .. (marks) .. " (pink) - dumping...")
end)
button("MARK: other colour bloom", 10, 168, 280, Color3.fromRGB(110, 90, 150), function()
  doMark("OTHER colour bloom", true)
  flash("mark #" .. (marks) .. " (other) - dumping...")
end)
button("MARK nearest petal", 10, 204, 280, Color3.fromRGB(170, 120, 30), function()
  doMark("petal", true)
  flash("mark #" .. (marks) .. " (petal) - dumping...")
end)
button("Copy", 10, 244, 66, Color3.fromRGB(60, 120, 70), copyReport)
button("Save", 82, 244, 66, Color3.fromRGB(60, 90, 140), saveReport)
button("Stop", 154, 244, 66, Color3.fromRGB(140, 100, 40), function() stopRecording() flash("stopped - press Copy") end)
button("Remove", 226, 244, 64, Color3.fromRGB(150, 36, 46), removeAll)

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

getgenv().__BloomDump = { remove = removeAll }
say("hooked " .. hooked .. " RemoteEvents, recording " .. DURATION .. "s. Stand next to a PINK bloom and press MARK.")

task.spawn(function()
  task.wait(0.3)
  local ok, err = pcall(staticScan)
  if not ok then log("static scan error: " .. tostring(err)) end
end)

task.spawn(function()
  local lastRescan = os.clock()
  while not removed do
    task.wait(0.5)
    if recording then
      local left = math.max(0, DURATION - (os.clock() - t0))
      status.Text = string.format("recording: %ds left\nmarks: %d   blooms tracked: %d\npetal events: %d   keyword events: %d",
        math.ceil(left), marks, #trackedList, #petalEvents, #evLines)
      if os.clock() - lastRescan > 10 then lastRescan = os.clock() hookAll() end
      if left <= 0 then
        stopRecording()
        local r = buildReport()
        if setclipboard then pcall(setclipboard, r) end
        if writefile then pcall(writefile, "BuffTools_bloom_dump.txt", r) end
        flash("DONE - copied + saved")
        say("DONE: " .. #r .. " chars. Copied + saved as BuffTools_bloom_dump.txt")
      end
    else
      status.Text = string.format("STOPPED\nmarks: %d\npetal events: %d   keyword events: %d", marks, #petalEvents, #evLines)
    end
  end
end)
