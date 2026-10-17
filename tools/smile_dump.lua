-- smile_dump.lua : how does the game report Digital Bee's Smile (☺) token and the pollen it gives?
-- Wiki: ☺ only appears as a DUPED token inside a field corrupted by Digital Bee's Glitch, hangs ~3-4s; collecting it
-- activates all duped tokens and collects pollen from a "☺ & * ~ ?" arrangement of flowers (stamped x2 for 10s).
-- HOW TO RUN: be on a field with Digital Bee, wait for Glitch (corrupted field), stand under duped tokens / the ☺.
-- Press MARK in the panel every time you see a ☺ token spawn or collect it. Run ~5 minutes.
-- Report: clipboard (Copy / auto at the end) and file BuffTools_smile_dump.txt.
--   getgenv().DUMP_SECONDS = 400   -- optional, before running (default 300)
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer

if getgenv().__SmileDump then pcall(getgenv().__SmileDump.remove) end
local DURATION = tonumber(getgenv().DUMP_SECONDS) or 300
local out = {}
local function log(s) out[#out + 1] = s end
local function say(s) print("[smile_dump] " .. s) end

local KW = { "smile", "smiley", "☺", "stamp", "corrupt", "glitch" }
local function kwOf(s)
  if type(s) ~= "string" then return nil end
  local l = s:lower()
  for i = 1, #KW do
    if l:find(KW[i], 1, true) then return KW[i] end
  end
  return nil
end

-- ---------------------------------------------------------------- serializer / keyword search
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

-- pollen source key, same rule as the BuffTools Stats tab
local function srcKey(g)
  if type(g) ~= "table" then return "Other" end
  local n = #g
  local last = g[n]
  if type(last) ~= "string" then return "Other" end
  if (last == "Tool" or last == "Bomb") and n >= 2 and type(g[1]) == "string" then return last .. " = " .. g[1] end
  return last
end
local function giveHasSmile(g)
  if type(g) ~= "table" then return false end
  for _, v in pairs(g) do
    if type(v) == "string" and kwOf(v) then return true end
  end
  return false
end

-- ---------------------------------------------------------------- state
local NOISE = {
  FlyingEntityMoveToPart = true, FlyingEntitySetMovespeed = true, FlyingEntityMove = true,
  FlyingEntitySetFacingDir = true, FlyingEntityCreate = true, FlyingEntityDestroy = true,
  BeeAnimPlay = true, BeeEmote = true, PlanterModelGrow = true, PlayerAbilityEvent = true,
  BeeConversionLink = true, PoppablePlant_Remove = true, PoppablePlant_Spawn = true, PoppablePlant_Update = true,
  CollectibleEvent = true, ServerItemPackEvent = true, CharacterGuiEvent = true, StationEvent = true,
  ServerSystemEvent = true, BeeLevelUp = true, EpochIntervalBackupUpdate = true, PetalCollected = true,
}
local counts = {}            -- remote name -> count
local ring = {}              -- {t, line} of recent non-noise events
local captures = {}          -- {t, reason, lines, src, endAt}
local openCap = nil
local dupIcons = {}          -- Icon -> {n, first payload}
local fxNames = {}           -- LocalFX action -> count
local fxKw = {}              -- LocalFX payloads that mention keywords (first ones)
local smileGives, smileSum, smileN = {}, 0, 0
local allSrc, allTotal = {}, 0     -- pollen by source over the whole run
local wsAdds = {}            -- workspace instances with keyword names
local marks = 0
local triggers = 0
local recording = true
local conns = {}
local t0 = os.clock()
local stoppedAt = nil

local function newCapture(reason, now)
  local c = { t = now, reason = reason, lines = {}, src = {}, srcTotal = 0, endAt = now + 8 }
  for i = 1, #ring do
    if now - ring[i][1] <= 3 then c.lines[#c.lines + 1] = "  (before) " .. ring[i][2] end
  end
  captures[#captures + 1] = c
  return c
end

local function trigger(reason, line, now)
  triggers = triggers + 1
  if openCap and now < openCap.endAt then
    openCap.endAt = math.min(now + 8, openCap.t + 25)
    if #openCap.lines < 320 then openCap.lines[#openCap.lines + 1] = "  >>> trigger (" .. reason .. ") " .. line end
    return
  end
  if #captures >= 12 then return end
  openCap = newCapture(reason, now)
  openCap.lines[#openCap.lines + 1] = "  >>> trigger (" .. reason .. ") " .. line
end

local function onRemote(name, args)
  if not recording then return end
  local now = os.clock()
  counts[name] = (counts[name] or 0) + 1

  if name == "ServerItemPackEvent" then
    local d = args[2]
    if args[1] == "Give" and type(d) == "table" and d.C == "Pollen" then
      local amt = tonumber(d.R) or ((tonumber(d.A) or 0) + (tonumber(d.c) or 0))
      local k = srcKey(d.g)
      allSrc[k] = (allSrc[k] or 0) + amt
      allTotal = allTotal + amt
      if openCap and now < openCap.endAt then
        openCap.src[k] = (openCap.src[k] or 0) + amt
        openCap.srcTotal = openCap.srcTotal + amt
      end
      if giveHasSmile(d.g) then
        smileN = smileN + 1
        smileSum = smileSum + amt
        if #smileGives < 25 then smileGives[#smileGives + 1] = string.format("[%.1fs] %s", now - t0, ser(d, 0)) end
        trigger("Give with smile tag", k .. " R=" .. tostring(d.R), now)
      end
    end
    return
  end

  if name == "DupedTokenCreate" then
    local d = args[1]
    if type(d) == "table" then
      local ic = tostring(d.Icon)
      local e = dupIcons[ic]
      if not e then e = { n = 0, first = ser(d, 0) } dupIcons[ic] = e end
      e.n = e.n + 1
    end
  elseif name == "LocalFX" then
    local act = args[1]
    if type(act) == "string" then
      fxNames[act] = (fxNames[act] or 0) + 1
      if (kwOf(act) or mentions(args[2], 0)) and #fxKw < 30 then
        fxKw[#fxKw + 1] = string.format("[%.1fs] %s", now - t0, payloadStr(args))
      end
    end
  end

  local kw
  for i = 1, math.min(args.n, 8) do kw = kw or mentions(args[i], 0) end

  if not NOISE[name] then
    local line = string.format("[%.2f] %s: %s", now - t0, name, payloadStr(args))
    if #line > 420 then line = line:sub(1, 420) .. "..." end
    ring[#ring + 1] = { now, line }
    if #ring > 160 then table.remove(ring, 1) end
    if openCap and now < openCap.endAt and #openCap.lines < 320 then
      openCap.lines[#openCap.lines + 1] = "  " .. line
    end
    if kw then trigger("keyword '" .. kw .. "' in " .. name, line, now) end
  elseif kw and name ~= "BeeLevelUp" and name ~= "EpochIntervalBackupUpdate" then
    local line = string.format("[%.2f] %s: %s", now - t0, name, payloadStr(args))
    trigger("keyword '" .. kw .. "' in " .. name, line:sub(1, 420), now)
  end
end

-- ---------------------------------------------------------------- hooks
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

-- new Workspace instances whose name smells like the smile token / stamped flowers
table.insert(conns, workspace.DescendantAdded:Connect(function(inst)
  if not recording then return end
  local k = kwOf(inst.Name)
  if k and #wsAdds < 60 then
    local p = ""
    pcall(function()
      if inst:IsA("BasePart") then p = " pos=" .. tostring(inst.Position) end
    end)
    wsAdds[#wsAdds + 1] = string.format("[%.1fs] %s <%s>%s", os.clock() - t0, inst:GetFullName(), inst.ClassName, p)
    trigger("workspace instance '" .. inst.Name .. "'", inst.ClassName, os.clock())
  end
end))

-- ---------------------------------------------------------------- static scan (modules mentioning smile / glitch / digital)
local function staticScan()
  log("=== ReplicatedStorage instances named like smile / digital / glitch / corrupt / stamp / dupe ===")
  local n = 0
  for _, d in ipairs(RS:GetDescendants()) do
    local l = d.Name:lower()
    if kwOf(d.Name) or l:find("digital") or l:find("dupe") or l:find("duped") then
      n = n + 1
      if n <= 80 then log("  " .. d:GetFullName() .. " <" .. d.ClassName .. ">") end
    end
  end
  log("  [" .. n .. " hits]")

  log("=== BeeAbilityDefs / AbilityUtils entries mentioning smile / glitch (require) ===")
  local function dumpModule(inst)
    local ok, mod = pcall(require, inst)
    if not ok then log("  require " .. inst.Name .. " failed: " .. tostring(mod):sub(1, 100)) return end
    if type(mod) ~= "table" then log("  " .. inst.Name .. " returned " .. typeof(mod)) return end
    local hit = 0
    for k, v in pairs(mod) do
      if kwOf(tostring(k)) or mentions(v, 0) then
        hit = hit + 1
        if hit <= 12 then log("  " .. inst.Name .. "[" .. tostring(k) .. "] = " .. ser(v, 0):sub(1, 700)) end
      end
    end
    log("  [" .. inst.Name .. ": " .. hit .. " entries]")
  end
  for _, nm in ipairs({ "BeeAbilityDefs" }) do
    local m = RS:FindFirstChild(nm)
    if m and m:IsA("ModuleScript") then dumpModule(m) end
  end
  local au = RS:FindFirstChild("AbilityUtils")
  if au then
    for _, m in ipairs(au:GetDescendants()) do
      if m:IsA("ModuleScript") and (kwOf(m.Name) or m.Name:lower():find("digital")) then dumpModule(m) end
    end
  end
  -- game effect / local fx modules named after the token
  for _, m in ipairs(RS:GetDescendants()) do
    if m:IsA("ModuleScript") and (kwOf(m.Name) or m.Name:lower():find("digital")) and #out < 4000 then
      if m.Parent and (m.Parent.Name == "GameEffects" or m.Parent.Name == "LocalFX" or m.Parent.Name == "Collectibles") then
        dumpModule(m)
      end
    end
  end
end

-- ---------------------------------------------------------------- report
local function buildReport()
  local live = {}
  local function L(s) live[#live + 1] = s end
  if recording then L("(!) recording still running - partial report") end
  L("=== recorded " .. math.floor((stoppedAt or os.clock()) - t0) .. "s, marks pressed: " .. marks .. ", triggers: " .. triggers .. " ===")

  L("=== Give events whose source tag mentions smile: " .. smileN .. " events, pollen R total " .. tostring(smileSum) .. " ===")
  if #smileGives == 0 then L("  none (the smile burst is NOT tagged 'Smile' in g - look at captures below)") end
  for _, s in ipairs(smileGives) do L("  " .. s) end

  L("=== pollen by source over the whole run (R) ===")
  local keys = {}
  for k in pairs(allSrc) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return allSrc[a] > allSrc[b] end)
  for i = 1, math.min(#keys, 30) do
    L(string.format("  %-34s %.4g  (%.1f%%)", keys[i], allSrc[keys[i]], allTotal > 0 and allSrc[keys[i]] / allTotal * 100 or 0))
  end

  L("=== DupedTokenCreate icons (the smile token should be a rare unusual icon) ===")
  local ik = {}
  for k in pairs(dupIcons) do ik[#ik + 1] = k end
  table.sort(ik, function(a, b) return dupIcons[a].n < dupIcons[b].n end)
  for _, k in ipairs(ik) do L(string.format("  x%-4d %s   first: %s", dupIcons[k].n, k, dupIcons[k].first:sub(1, 300))) end

  L("=== LocalFX actions seen ===")
  local fk = {}
  for k in pairs(fxNames) do fk[#fk + 1] = k end
  table.sort(fk, function(a, b) return fxNames[a] > fxNames[b] end)
  for _, k in ipairs(fk) do L(string.format("  %-34s x%d", k, fxNames[k])) end
  L("=== LocalFX payloads mentioning keywords ===")
  if #fxKw == 0 then L("  none") end
  for _, s in ipairs(fxKw) do L("  " .. s:sub(1, 500)) end

  L("=== workspace instances with keyword names ===")
  if #wsAdds == 0 then L("  none") end
  for _, s in ipairs(wsAdds) do L("  " .. s) end

  L("=== remotes seen (count) ===")
  local rk = {}
  for k in pairs(counts) do rk[#rk + 1] = k end
  table.sort(rk, function(a, b) return counts[a] > counts[b] end)
  for _, k in ipairs(rk) do L(string.format("  %-34s x%d", k, counts[k])) end

  L("=== CAPTURES: events 3s before .. 8s after each trigger, plus pollen by source inside the window ===")
  for i, c in ipairs(captures) do
    L(string.format("--- capture #%d at %.1fs, reason: %s ---", i, c.t - t0, c.reason))
    local ck = {}
    for k in pairs(c.src) do ck[#ck + 1] = k end
    table.sort(ck, function(a, b) return c.src[a] > c.src[b] end)
    L("  pollen inside window: " .. string.format("%.4g", c.srcTotal))
    for j = 1, math.min(#ck, 12) do
      L(string.format("    %-32s %.4g (%.1f%%)", ck[j], c.src[ck[j]], c.srcTotal > 0 and c.src[ck[j]] / c.srcTotal * 100 or 0))
    end
    for _, ln in ipairs(c.lines) do L(ln) end
  end
  return table.concat(out, "\n") .. "\n" .. table.concat(live, "\n")
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
gui.Name = "SmileDumpGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.IgnoreGuiInset = true
local okParent = false
if type(gethui) == "function" then okParent = pcall(function() gui.Parent = gethui() end) end
if not okParent then okParent = pcall(function() gui.Parent = game:GetService("CoreGui") end) end
if not okParent or not gui.Parent then gui.Parent = player:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(300, 252)
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
title.Text = "  smile_dump"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 220, 220)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Active = true
title.Parent = frame

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(10, 30)
status.Size = UDim2.new(1, -20, 0, 92)
status.BackgroundTransparency = 1
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextColor3 = Color3.fromRGB(226, 214, 214)
status.Font = Enum.Font.Code
status.TextSize = 13
status.Text = ""
status.Parent = frame

local note = Instance.new("TextLabel")
note.Position = UDim2.fromOffset(10, 124)
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
    local ok = pcall(writefile, "BuffTools_smile_dump.txt", r)
    flash(ok and "saved BuffTools_smile_dump.txt" or "save failed")
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
  getgenv().__SmileDump = nil
  print("[smile_dump] removed")
end

-- big MARK button: press when you SEE the ☺ token spawn / when you collect it
button("MARK  (saw / collected ☺)", 10, 148, 280, Color3.fromRGB(170, 120, 30), function()
  marks = marks + 1
  local now = os.clock()
  ring[#ring + 1] = { now, string.format("[%.2f] >>>>>> MARK #%d pressed by user", now - t0, marks) }
  trigger("user MARK #" .. marks, "pressed", now)
  flash("mark #" .. marks .. " saved")
end)
button("Copy", 10, 186, 66, Color3.fromRGB(60, 120, 70), copyReport)
button("Save", 82, 186, 66, Color3.fromRGB(60, 90, 140), saveReport)
button("Stop", 154, 186, 66, Color3.fromRGB(140, 100, 40), function() stopRecording() flash("stopped - press Copy") end)
button("Remove", 226, 186, 64, Color3.fromRGB(150, 36, 46), removeAll)

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

getgenv().__SmileDump = { remove = removeAll }
say("hooked " .. hooked .. " RemoteEvents, recording " .. DURATION .. "s. Press MARK whenever a smile token spawns / is collected.")

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
      status.Text = string.format("recording: %ds left\nmarks: %d   captures: %d\nsmile gives: %d (R %.3g)\nduped icons: %d kinds",
        math.ceil(left), marks, #captures, smileN, smileSum, (function() local n = 0 for _ in pairs(dupIcons) do n = n + 1 end return n end)())
      if os.clock() - lastRescan > 10 then lastRescan = os.clock() hookAll() end
      if left <= 0 then
        stopRecording()
        local r = buildReport()
        if setclipboard then pcall(setclipboard, r) end
        if writefile then pcall(writefile, "BuffTools_smile_dump.txt", r) end
        flash("DONE - copied + saved")
        say("DONE: " .. #r .. " chars, " .. #captures .. " captures. Copied + saved as BuffTools_smile_dump.txt")
      end
    else
      status.Text = string.format("STOPPED\nmarks: %d   captures: %d\nsmile gives: %d (R %.3g)", marks, #captures, smileN, smileSum)
    end
  end
end)
