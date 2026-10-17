-- stats_dump.lua : where does the game keep the "pollen by ability" table (Target Practice / Flame / Bee Gather ...)?
-- Run it, then play ~90s normally (throw targets, let flames burn, collect). If the game has a stats / profile
-- window with that table, OPEN IT during the run and keep it open a few seconds.
-- Report goes to the clipboard AND to the file BuffTools_stats_dump.txt in the executor workspace.
--   getgenv().DUMP_SECONDS = 120   -- optional, before running, to change the length (default 90)
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

-- a second run replaces the first one
if getgenv().__StatsDump then pcall(getgenv().__StatsDump.remove) end
local DURATION = tonumber(getgenv and getgenv().DUMP_SECONDS) or 90
local out = {}
local sink = out
local function log(s) sink[#sink + 1] = s end
local function say(s) print("[stats_dump] " .. s) end

-- names of the ability rows from the screenshot (lowercase); a remote arg / gui text / table containing one is a lead
local ABILITIES = {
  "target practice", "bee gather", "mark surge", "triangulate", "red pulse", "blue pulse", "star saw",
  "falling coconut", "movement collection", "dark scythe", "gold bubble", "bomb", "smile", "scratch",
}
local function hasAbility(s)
  if type(s) ~= "string" then return nil end
  local l = s:lower()
  for i = 1, #ABILITIES do
    if l:find(ABILITIES[i], 1, true) then return ABILITIES[i] end
  end
  return nil
end

-- ---------------------------------------------------------------- serializer (cycle safe, size capped)
local function ser(v, depth, seen)
  depth = depth or 0
  local t = typeof(v)
  if t == "string" then
    if #v > 120 then return string.format("%q", v:sub(1, 120)) .. "..." end
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
    if depth >= 4 then return "{...}" end
    seen[v] = true
    local parts, n = {}, 0
    for k, val in pairs(v) do
      n = n + 1
      if n > 24 then parts[#parts + 1] = "..." break end
      parts[#parts + 1] = "[" .. ser(k, depth + 1, seen) .. "]=" .. ser(val, depth + 1, seen)
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return "<" .. t .. ">"
end

-- does any key / value inside the table mention an ability name? (depth limited)
local function tableMentions(v, depth, seen)
  if type(v) == "string" then return hasAbility(v) end
  if type(v) ~= "table" or depth > 4 then return nil end
  seen = seen or {}
  if seen[v] then return nil end
  seen[v] = true
  local n = 0
  for k, val in pairs(v) do
    n = n + 1
    if n > 60 then break end
    local a = hasAbility(type(k) == "string" and k or nil) or tableMentions(val, depth + 1, seen)
    if a then return a end
  end
  return nil
end

-- ---------------------------------------------------------------- 4) gui text with ability names (stats window if it is open)
local function scanGuiText(tag)
  log("=== PlayerGui text mentioning ability names (" .. tag .. ") ===")
  local n = 0
  for _, d in ipairs(player.PlayerGui:GetDescendants()) do
    if (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox")) and d.Text ~= "" and hasAbility(d.Text) then
      n = n + 1
      if n <= 80 then
        log("  " .. d:GetFullName() .. " Visible=" .. tostring(d.Visible) .. " Text=" .. string.format("%q", d.Text:sub(1, 100)))
      end
    end
  end
  log("  [" .. n .. " hits]")
end


local function staticScan()
  -- ---------------------------------------------------------------- 1) static scan: values / attributes on the player
  log("=== player: values & attributes whose name smells like stats ===")
  local function smellsLikeStat(name)
    local l = name:lower()
    return l:find("stat") or l:find("pollen") or l:find("ability") or l:find("honey") or l:find("source")
      or l:find("breakdown") or l:find("contrib") or l:find("total")
  end
  local function scanInstance(root, label)
    local n = 0
    for _, d in ipairs(root:GetDescendants()) do
      if n > 160 then log("  (cut)") break end
      local line
      if d:IsA("ValueBase") and smellsLikeStat(d.Name .. " " .. d.Parent.Name) then
        line = d:GetFullName() .. " <" .. d.ClassName .. "> = " .. ser(d.Value)
      end
      if not line then
        for k, v in pairs(d:GetAttributes()) do
          if smellsLikeStat(tostring(k)) or hasAbility(tostring(k)) then
            line = (line and (line .. " ") or (d:GetFullName() .. " ")) .. "@" .. tostring(k) .. "=" .. ser(v)
          end
        end
      end
      if line then n = n + 1 log("  " .. line) end
    end
    log("  [" .. label .. ": " .. n .. " hits]")
  end
  scanInstance(player, "player")
  for k, v in pairs(player:GetAttributes()) do log("  player@" .. tostring(k) .. "=" .. ser(v)) end
  
  -- ---------------------------------------------------------------- 2) ReplicatedStorage modules / remotes that smell like stats
  log("=== ReplicatedStorage: instances named like stats / pollen / ability ===")
  do
    local n = 0
    for _, d in ipairs(RS:GetDescendants()) do
      local l = d.Name:lower()
      if l:find("stat") or l:find("pollen") or l:find("ability") or l:find("breakdown") or l:find("profile")
        or l:find("source") or l:find("leaderboard") or l:find("record") then
        n = n + 1
        if n <= 120 then log("  " .. d:GetFullName() .. " <" .. d.ClassName .. ">") end
      end
    end
    log("  [" .. n .. " hits]")
  end
  
  -- ---------------------------------------------------------------- 3) getgc: tables keyed by ability names
  log("=== getgc tables mentioning ability names (live client data tables) ===")
  do
    if type(getgc) ~= "function" then
      log("  getgc unavailable in this executor")
    else
      local ok, err = pcall(function()
        local found, seenSig = 0, {}
        for _, t in ipairs(getgc(true)) do
          if type(t) == "table" and found < 14 then
            local hit
            pcall(function()
              if rawget(t, "Target Practice") ~= nil or rawget(t, "Bee Gather") ~= nil or rawget(t, "Mark Surge") ~= nil
                or rawget(t, "Star Saw") ~= nil or rawget(t, "Triangulate") ~= nil or rawget(t, "Falling Coconut") ~= nil then
                hit = true
              end
            end)
            if hit then
              local s = ser(t, 1)
              if not seenSig[s] then
                seenSig[s] = true
                found = found + 1
                log("  table #" .. found .. ": " .. s)
              end
            end
          end
        end
        log("  [" .. found .. " tables]")
      end)
      if not ok then log("  getgc error: " .. tostring(err)) end
    end
  end
  scanGuiText("at start")
end

-- ---------------------------------------------------------------- 5) live: every RemoteEvent the server fires at us
local counts, order, samples, hits, hitN = {}, {}, {}, {}, 0
local recent = {}      -- {name, t} of the last events, to correlate with honey jumps
local corr, corrN = {}, 0
local conns = {}
local hooked = 0
local recording = true
local endGui = nil     -- gui-text scan taken when recording stops

local function hookRemote(r)
  if not r:IsA("RemoteEvent") then return end
  hooked = hooked + 1
  local name = r.Name
  table.insert(conns, r.OnClientEvent:Connect(function(...)
    if not recording then return end
    local args = table.pack(...)
    local now = os.clock()
    if not counts[name] then counts[name] = 0 order[#order + 1] = name samples[name] = {} end
    counts[name] = counts[name] + 1
    if #samples[name] < 3 then
      local p = {}
      for i = 1, math.min(args.n, 6) do p[i] = ser(args[i], 1) end
      samples[name][#samples[name] + 1] = table.concat(p, " | ")
    end
    -- a lead: any arg mentioning an ability name
    local mention
    for i = 1, math.min(args.n, 8) do
      mention = mention or tableMentions(args[i], 0)
    end
    if mention and hitN < 40 then
      hitN = hitN + 1
      local p = {}
      for i = 1, math.min(args.n, 6) do p[i] = ser(args[i], 0) end
      hits[#hits + 1] = string.format("[%.1fs] %s  (%s): %s", now, name, mention, table.concat(p, " | "))
    end
    recent[#recent + 1] = { name, now }
    if #recent > 80 then table.remove(recent, 1) end
  end))
end

local seenR = {}
local function hookAll()
  for _, d in ipairs(RS:GetDescendants()) do
    if d:IsA("RemoteEvent") and not seenR[d] then seenR[d] = true hookRemote(d) end
  end
end
hookAll()

-- honey jumps -> which remotes fired right before (the one that carries the pollen amount shows up here)
local function getHoney()
  local cs = player:FindFirstChild("CoreStats")
  local h = cs and cs:FindFirstChild("Honey")
  return h and h.Value
end
local lastH = getHoney()
local t0 = os.clock()
local hbConn = RunService.Heartbeat:Connect(function()
  if not recording then return end
  local h = getHoney()
  if type(h) == "number" and type(lastH) == "number" and h > lastH then
    local now = os.clock()
    local seen = {}
    for i = #recent, 1, -1 do
      local e = recent[i]
      if now - e[2] > 0.5 then break end
      if not seen[e[1]] then
        seen[e[1]] = true
        corr[e[1]] = (corr[e[1]] or 0) + 1
      end
    end
    corrN = corrN + 1
  end
  lastH = h or lastH
end)

-- ---------------------------------------------------------------- report (built on demand: Copy works any time)
local function buildReport()
  local live = {}
  local mainSink = sink
  sink = live
  if recording then
    log("(!) recording is still running - this is a partial report")
  end
  local elapsed = math.floor((recording and os.clock() or (t0 + (getgenv().__StatsDumpStopped or 0))) - t0)
  log("=== recorded " .. tostring(elapsed) .. "s ===")
  if endGui then
    for _, l in ipairs(endGui) do log(l) end
  else
    scanGuiText("now")
  end

  log("=== remotes seen (count, up to 3 sample payloads) ===")
  local ord = {}
  for i, n in ipairs(order) do ord[i] = n end
  table.sort(ord, function(a, b) return counts[a] > counts[b] end)
  for _, name in ipairs(ord) do
    log(string.format("  %-34s x%d", name, counts[name]))
    for _, s in ipairs(samples[name]) do log("      " .. s:sub(1, 380)) end
  end

  log("=== remote events that MENTION an ability name (strongest leads) ===")
  if #hits == 0 then log("  none") end
  for _, h in ipairs(hits) do log("  " .. h:sub(1, 900)) end

  log("=== remotes that fired within 0.5s before honey went up (" .. corrN .. " honey jumps) ===")
  local keys = {}
  for k in pairs(corr) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return corr[a] > corr[b] end)
  for i = 1, math.min(#keys, 25) do log(string.format("  %-34s %d/%d", keys[i], corr[keys[i]], corrN)) end

  sink = mainSink
  return table.concat(out, "\n") .. "\n" .. table.concat(live, "\n")
end

local function stopRecording()
  if not recording then return end
  -- gui text scan while the stats window may still be open
  local tmp, mainSink = {}, sink
  sink = tmp
  scanGuiText("at end")
  sink = mainSink
  endGui = tmp
  recording = false
  getgenv().__StatsDumpStopped = os.clock() - t0
  hbConn:Disconnect()
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  conns = {}
end

-- ---------------------------------------------------------------- GUI: Copy / Save / Rescan / Stop / Remove
local gui = Instance.new("ScreenGui")
gui.Name = "StatsDumpGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.IgnoreGuiInset = true
local okParent = false
if type(gethui) == "function" then okParent = pcall(function() gui.Parent = gethui() end) end
if not okParent then
  okParent = pcall(function() gui.Parent = game:GetService("CoreGui") end)
end
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
title.Text = "  stats_dump"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 220, 220)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
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

local function button(text, x, y, w, color, fn)
  local b = Instance.new("TextButton")
  b.Position = UDim2.fromOffset(x, y)
  b.Size = UDim2.fromOffset(w, 32)
  b.BackgroundColor3 = color
  b.BorderSizePixel = 0
  b.AutoButtonColor = true
  b.Text = text
  b.TextColor3 = Color3.fromRGB(255, 240, 240)
  b.Font = Enum.Font.GothamBold
  b.TextSize = 13
  b.Parent = frame
  Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
  b.MouseButton1Click:Connect(function() pcall(fn) end)
  return b
end

local function flash(msg)
  note.Text = msg
  local mine = msg
  task.delay(3, function() if note.Text == mine then note.Text = "" end end)
end

local function copyReport()
  local report = buildReport()
  if setclipboard then
    setclipboard(report)
    flash("copied " .. #report .. " chars")
  else
    flash("no setclipboard - use Save")
  end
  return report
end

local function saveReport()
  local report = buildReport()
  if writefile then
    local ok = pcall(writefile, "BuffTools_stats_dump.txt", report)
    flash(ok and "saved BuffTools_stats_dump.txt" or "save failed")
  else
    flash("no writefile")
  end
end

local removed = false
local function removeAll()
  if removed then return end
  removed = true
  recording = false
  pcall(function() hbConn:Disconnect() end)
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  conns = {}
  pcall(function() gui:Destroy() end)
  getgenv().__StatsDump = nil
  getgenv().__StatsDumpStopped = nil
  print("[stats_dump] removed")
end

button("Copy", 10, 128, 66, Color3.fromRGB(60, 120, 70), copyReport)
button("Save", 82, 128, 66, Color3.fromRGB(60, 90, 140), saveReport)
button("Rescan GUI", 154, 128, 136, Color3.fromRGB(100, 80, 140), function()
  local tmp, mainSink = {}, sink
  sink = tmp
  scanGuiText("manual rescan")
  sink = mainSink
  for _, l in ipairs(tmp) do out[#out + 1] = l end
  flash("gui rescan added (" .. #tmp .. " lines)")
end)
button("Stop", 10, 168, 66, Color3.fromRGB(140, 100, 40), function()
  stopRecording()
  flash("stopped - press Copy")
end)
button("Remove", 82, 168, 208, Color3.fromRGB(150, 36, 46), removeAll)

-- drag by the title
do
  local UIS = game:GetService("UserInputService")
  local dragging, start, origin
  title.Active = true
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

getgenv().__StatsDump = { remove = removeAll }
task.spawn(function()
  task.wait(0.3)
  local okS, errS = pcall(staticScan)
  if not okS then
    out[#out + 1] = "static scan error: " .. tostring(errS)
    flash("static scan error, see report")
  end
end)
say("hooked " .. hooked .. " RemoteEvents, recording " .. DURATION .. "s. Use the panel on the right: Copy / Save / Stop / Remove.")

task.spawn(function()
  local lastRescan = os.clock()
  while not removed do
    task.wait(0.5)
    if recording then
      local left = math.max(0, DURATION - (os.clock() - t0))
      local n = 0
      for _, c in pairs(counts) do n = n + c end
      status.Text = string.format("recording: %ds left\nremotes: %d kinds, %d events\nhoney jumps: %d\nability leads: %d",
        math.ceil(left), #order, n, corrN, hitN)
      if os.clock() - lastRescan > 10 then lastRescan = os.clock() hookAll() end
      if left <= 0 then
        stopRecording()
        local report = buildReport()
        if setclipboard then pcall(setclipboard, report) end
        if writefile then pcall(writefile, "BuffTools_stats_dump.txt", report) end
        flash("DONE - copied + saved")
        say("DONE: " .. #report .. " chars, " .. hitN .. " ability leads. Copied to clipboard and saved as BuffTools_stats_dump.txt")
      end
    else
      local n = 0
      for _, c in pairs(counts) do n = n + c end
      status.Text = string.format("STOPPED\nremotes: %d kinds, %d events\nhoney jumps: %d\nability leads: %d", #order, n, corrN, hitN)
    end
  end
end)
