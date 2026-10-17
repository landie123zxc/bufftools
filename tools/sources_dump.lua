-- sources_dump.lua : GENERAL dump of every pollen / honey source the game reports, with shares in percent.
-- Goal: build the "pollen by ability" table (Target Practice 34%, Flame 21%, Bee Gather, Smile, Bomb = Red Bomb,
-- Tool = Dark Scythe, Mark Surge ...) in the BuffTools style. Collects:
--   1) every ServerItemPackEvent "Give" grouped by item class (Pollen / Honey / ...), by source tag list and by
--      the key BuffTools uses, with counts, sums and shares in %, field meanings (A / c / R / G / I / O / L / Z)
--   2) lifetime numbers: the player's own "Totals" table (getgc) - sub tables that hold ability names, with shares
--   3) ServerSystemEvent "CacheResetStat" paths (where the game stores each total)
-- RUN ~3-5 minutes of NORMAL play: all bees, targets, flames, bombs, tools, bubbles, tokens. Include a Digital Bee
-- Glitch / Smile token if you have one. Report: clipboard (Copy / auto at the end) + BuffTools_sources_dump.txt.
--   getgenv().DUMP_SECONDS = 300   -- optional, before running (default 240)
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer

if getgenv().__SourcesDump then pcall(getgenv().__SourcesDump.remove) end
local DURATION = tonumber(getgenv().DUMP_SECONDS) or 240
local out = {}
local function log(s) out[#out + 1] = s end
local function say(s) print("[sources_dump] " .. s) end

-- ---------------------------------------------------------------- helpers
local function ser(v, depth, seen)
  depth = depth or 0
  local t = typeof(v)
  if t == "string" then
    if #v > 80 then return string.format("%q", v:sub(1, 80)) .. "..." end
    return string.format("%q", v)
  elseif t == "number" or t == "boolean" or t == "nil" then
    return tostring(v)
  elseif t == "Vector3" or t == "Color3" or t == "CFrame" then
    return t .. "(" .. tostring(v) .. ")"
  elseif t == "Instance" then
    return "<" .. v.ClassName .. " " .. v.Name .. ">"
  elseif t == "table" then
    seen = seen or {}
    if seen[v] then return "<cycle>" end
    if depth >= 2 then return "{...}" end
    seen[v] = true
    local parts, n = {}, 0
    for k, val in pairs(v) do
      n = n + 1
      if n > 12 then parts[#parts + 1] = "..." break end
      parts[#parts + 1] = "[" .. ser(k, depth + 1, seen) .. "]=" .. ser(val, depth + 1, seen)
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return "<" .. t .. ">"
end

local function fmtN(n)
  n = tonumber(n) or 0
  local units = { { 1e33, "Dc" }, { 1e30, "No" }, { 1e27, "Oc" }, { 1e24, "Sp" }, { 1e21, "Sx" }, { 1e18, "Qn" },
    { 1e15, "Qd" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
  for _, u in ipairs(units) do
    if n >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
  end
  return string.format("%.0f", n)
end

-- same naming rule as the BuffTools Stats tab
local function srcKey(g)
  if type(g) ~= "table" then return "(no tag)" end
  local n = #g
  local last = g[n]
  if type(last) ~= "string" then return "(no tag)" end
  if (last == "Tool" or last == "Bomb") and n >= 2 and type(g[1]) == "string" then return last .. " = " .. g[1] end
  return last
end
local function sigOf(g)
  if type(g) ~= "table" then return "(no tag)" end
  local p = {}
  for i = 1, #g do p[i] = tostring(g[i]) end
  return #p > 0 and table.concat(p, " / ") or "(empty)"
end

-- ---------------------------------------------------------------- live state
local recording = true
local stoppedAt = nil
local t0 = os.clock()
local conns = {}
local classes = {}       -- C -> {n, sumR}
local polBySrc, polTotal = {}, 0          -- key -> {n, R, A, c, crit}
local polBySig = {}      -- full tag signature -> {n, R, sample}
local honBySrc, honTotal = {}, 0
local fields = {}        -- field name -> {n, sample}
local byColor, byZone = {}, {}
local critR, critN, allN = 0, 0, 0
local pathSeen = {}      -- CacheResetStat path -> {n, sample}
local smileN, smileR = 0, 0
local otherSamples = {}  -- Give payloads of classes other than Pollen / Honey

local function bump(tbl, k, amt)
  local e = tbl[k]
  if not e then e = { n = 0, R = 0 } tbl[k] = e end
  e.n = e.n + 1
  e.R = e.R + (amt or 0)
  return e
end

local function onGive(d)
  local c = tostring(d.C)
  local ce = classes[c]
  if not ce then ce = { n = 0, R = 0 } classes[c] = ce end
  ce.n = ce.n + 1
  for k, v in pairs(d) do
    if type(k) == "string" then
      local f = fields[k]
      if not f then f = { n = 0, sample = ser(v, 1) } fields[k] = f end
      f.n = f.n + 1
    end
  end
  if c == "Pollen" then
    local R = tonumber(d.R)
    local A, cc = tonumber(d.A) or 0, tonumber(d.c) or 0
    if not R then R = A + cc end
    ce.R = ce.R + R
    polTotal = polTotal + R
    allN = allN + 1
    local key = srcKey(d.g)
    local e = bump(polBySrc, key, R)
    e.A = (e.A or 0) + A
    e.c = (e.c or 0) + cc
    if d.I == true then e.crit = (e.crit or 0) + 1 critN = critN + 1 critR = critR + R end
    local s = bump(polBySig, sigOf(d.g), R)
    if not s.sample then s.sample = ser(d, 0) end
    byColor[tostring(d.L)] = (byColor[tostring(d.L)] or 0) + R
    byZone[tostring(d.Z)] = (byZone[tostring(d.Z)] or 0) + R
    if type(d.g) == "table" then
      for _, v in pairs(d.g) do
        if type(v) == "string" and (v:lower():find("smile", 1, true) or v:find("☺", 1, true)) then
          smileN = smileN + 1
          smileR = smileR + R
          break
        end
      end
    end
  elseif c == "Honey" then
    local R = tonumber(d.R) or tonumber(d.A) or 0
    honTotal = honTotal + R
    local e = bump(honBySrc, srcKey(d.g), tonumber(d.A) or R)
    if not e.sample then e.sample = ser(d, 0) end
    ce.R = ce.R + (tonumber(d.A) or 0)
  else
    if #otherSamples < 40 then otherSamples[#otherSamples + 1] = ser(d, 0) end
  end
end

local function onSystem(act, d)
  if act ~= "CacheResetStat" or type(d) ~= "table" then return end
  local p = d.Path
  local ps
  if type(p) == "table" then
    local parts = {}
    for i = 1, #p do parts[i] = tostring(p[i]) end
    ps = table.concat(parts, " > ")
  else
    ps = tostring(p)
  end
  local e = pathSeen[ps]
  if not e then e = { n = 0, sample = ser(d.Value, 1) } pathSeen[ps] = e end
  e.n = e.n + 1
end

local hooked = 0
local function hook(name, fn)
  local r = RS:FindFirstChild("Events") and RS.Events:FindFirstChild(name)
  if r and r:IsA("RemoteEvent") then
    hooked = hooked + 1
    table.insert(conns, r.OnClientEvent:Connect(function(...)
      if not recording then return end
      pcall(fn, ...)
    end))
  else
    log("(!) remote not found: " .. name)
  end
end
hook("ServerItemPackEvent", function(act, d)
  if act == "Give" and type(d) == "table" then onGive(d) end
end)
hook("ServerSystemEvent", onSystem)

-- ---------------------------------------------------------------- lifetime scan (player data "Totals")
local ABIL = { "Target Practice", "Bee Gather", "Bomb", "Dark Scythe", "Star Saw", "Movement Collection", "Scratch", "Bubble" }
local function hasAbilKey(t)
  for i = 1, #ABIL do
    local ok, v = pcall(rawget, t, ABIL[i])
    if ok and v ~= nil then return true end
  end
  return false
end

local function lifetimeScan()
  log("=== lifetime stats (getgc: this player's data table with Totals) ===")
  if type(getgc) ~= "function" then log("  getgc unavailable") return end
  local seenSig, shown = {}, 0
  local ok, err = pcall(function()
    for _, t in ipairs(getgc(true)) do
      if shown >= 2 then break end
      if type(t) == "table" then
        local tot, uid
        pcall(function() tot = rawget(t, "Totals") uid = rawget(t, "UserId") end)
        if type(tot) == "table" and (uid == player.UserId or uid == nil) then
          local nk = 0
          for _ in pairs(tot) do nk = nk + 1 end
          local sig = tostring(nk) .. ":" .. tostring(rawget(t, "Honey") or "")
          if nk > 20 and not seenSig[sig] then
            seenSig[sig] = true
            shown = shown + 1
            log(string.format("--- Totals candidate #%d: %d keys, UserId=%s, Honey=%s ---", shown, nk, tostring(uid), tostring(rawget(t, "Honey"))))
            -- scalar totals that smell like pollen / honey
            local sc = {}
            for k, v in pairs(tot) do
              if type(v) == "number" and type(k) == "string" and (k:lower():find("pollen") or k:lower():find("honey")) then
                sc[#sc + 1] = string.format("  %s = %s", k, fmtN(v))
              end
            end
            table.sort(sc)
            for i = 1, math.min(#sc, 40) do log(sc[i]) end
            -- table-valued totals: list names; expand the ones that hold ability names
            local names = {}
            for k, v in pairs(tot) do
              if type(v) == "table" then
                local cnt = 0
                for _ in pairs(v) do cnt = cnt + 1 end
                names[#names + 1] = { k = tostring(k), cnt = cnt, abil = hasAbilKey(v), v = v }
              end
            end
            table.sort(names, function(a, b) return a.k < b.k end)
            log("  table-valued Totals: " .. #names)
            for _, e in ipairs(names) do
              log(string.format("    %-40s entries=%d%s", e.k, e.cnt, e.abil and "  <== has ability names" or ""))
            end
            for _, e in ipairs(names) do
              if e.abil then
                local rows, sum = {}, 0
                for k, v in pairs(e.v) do
                  if type(v) == "number" then rows[#rows + 1] = { tostring(k), v } sum = sum + v end
                end
                table.sort(rows, function(a, b) return a[2] > b[2] end)
                log(string.format("  >>> Totals[%q]  sum=%s", e.k, fmtN(sum)))
                for i = 1, math.min(#rows, 40) do
                  log(string.format("      %-34s %12s  %5.1f%%", rows[i][1], fmtN(rows[i][2]), sum > 0 and rows[i][2] / sum * 100 or 0))
                end
              end
            end
          end
        end
      end
    end
  end)
  if not ok then log("  lifetime scan error: " .. tostring(err)) end
  if shown == 0 then log("  no player data table with Totals found in getgc") end
end

-- ---------------------------------------------------------------- report
local function sortedKeys(tbl, field)
  local ks = {}
  for k in pairs(tbl) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b)
    local x, y = tbl[a], tbl[b]
    if type(x) == "table" then x, y = x[field or "R"], y[field or "R"] end
    return x > y
  end)
  return ks
end

local function buildReport()
  local live = {}
  local function L(s) live[#live + 1] = s end
  local el = math.max(1, (stoppedAt or os.clock()) - t0)
  if recording then L("(!) recording still running - partial report") end
  L(string.format("=== recorded %ds, %d Give events with Pollen ===", math.floor(el), allN))

  L("=== Give events by item class (C) ===")
  for _, k in ipairs(sortedKeys(classes, "n")) do
    L(string.format("  %-14s x%-6d sum=%s", k, classes[k].n, fmtN(classes[k].R)))
  end

  L(string.format("=== POLLEN BY SOURCE (BuffTools key), total %s, %s/s ===", fmtN(polTotal), fmtN(polTotal / el)))
  L(string.format("  %-34s %10s %7s %6s %10s %10s %s", "SOURCE", "POLLEN", "SHARE", "hits", "avg A", "avg c", "crit%"))
  for _, k in ipairs(sortedKeys(polBySrc)) do
    local e = polBySrc[k]
    L(string.format("  %-34s %10s %6.1f%% %6d %10s %10s %s", k, fmtN(e.R), polTotal > 0 and e.R / polTotal * 100 or 0,
      e.n, fmtN((e.A or 0) / e.n), fmtN((e.c or 0) / e.n), string.format("%.0f%%", (e.crit or 0) / e.n * 100)))
  end
  L(string.format("  crits overall: %d/%d hits, %.1f%% of pollen", critN, allN, polTotal > 0 and critR / polTotal * 100 or 0))
  L(string.format("  smile-tagged: %d hits, %s pollen", smileN, fmtN(smileR)))

  L("=== POLLEN BY FULL TAG LIST (g) - shows what the tags mean / how to split 'Bee Gather (other)' etc. ===")
  local sg = sortedKeys(polBySig)
  for i = 1, math.min(#sg, 60) do
    local e = polBySig[sg[i]]
    L(string.format("  %6.1f%% %-8s x%-5d %s", polTotal > 0 and e.R / polTotal * 100 or 0, fmtN(e.R), e.n, sg[i]))
  end

  L("=== by flower colour (L) ===")
  for _, k in ipairs(sortedKeys(byColor, nil)) do
    L(string.format("  %-10s %8s %5.1f%%", k, fmtN(byColor[k]), polTotal > 0 and byColor[k] / polTotal * 100 or 0))
  end
  L("=== by zone (Z) ===")
  for _, k in ipairs(sortedKeys(byZone, nil)) do
    L(string.format("  %-24s %8s %5.1f%%", k, fmtN(byZone[k]), polTotal > 0 and byZone[k] / polTotal * 100 or 0))
  end

  L("=== HONEY gives by source, total " .. fmtN(honTotal) .. " ===")
  for _, k in ipairs(sortedKeys(honBySrc)) do
    local e = honBySrc[k]
    L(string.format("  %-34s %10s %5.1f%% x%d   e.g. %s", k, fmtN(e.R), honTotal > 0 and e.R / honTotal * 100 or 0, e.n, (e.sample or ""):sub(1, 160)))
  end

  L("=== Give payload fields (meaning of the letters: compare with samples) ===")
  for _, k in ipairs(sortedKeys(fields, "n")) do
    L(string.format("  %-4s x%-6d e.g. %s", k, fields[k].n, fields[k].sample))
  end

  L("=== Give payloads of other classes (items, eggs...) ===")
  for _, s in ipairs(otherSamples) do L("  " .. s:sub(1, 300)) end

  L("=== sample payload per tag list (first 25) ===")
  for i = 1, math.min(#sg, 25) do L("  " .. sg[i] .. "  =>  " .. (polBySig[sg[i]].sample or ""):sub(1, 420)) end

  L("=== CacheResetStat paths (where the game keeps each total) ===")
  for _, k in ipairs(sortedKeys(pathSeen, "n")) do
    L(string.format("  x%-4d %s   e.g. %s", pathSeen[k].n, k, pathSeen[k].sample:sub(1, 120)))
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

-- ---------------------------------------------------------------- GUI (same as the other dumps)
local gui = Instance.new("ScreenGui")
gui.Name = "SourcesDumpGui"
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
title.Text = "  sources_dump"
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

local removed = false
local function copyReport()
  local r = buildReport()
  if setclipboard then setclipboard(r) flash("copied " .. #r .. " chars") else flash("no setclipboard - use Save") end
end
local function saveReport()
  local r = buildReport()
  if writefile then
    local ok = pcall(writefile, "BuffTools_sources_dump.txt", r)
    flash(ok and "saved BuffTools_sources_dump.txt" or "save failed")
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
  getgenv().__SourcesDump = nil
  print("[sources_dump] removed")
end

button("Copy", 10, 128, 66, Color3.fromRGB(60, 120, 70), copyReport)
button("Save", 82, 128, 66, Color3.fromRGB(60, 90, 140), saveReport)
button("Reset data", 154, 128, 136, Color3.fromRGB(100, 80, 140), function()
  classes, polBySrc, polBySig, honBySrc, fields, byColor, byZone, pathSeen, otherSamples = {}, {}, {}, {}, {}, {}, {}, {}, {}
  polTotal, honTotal, critR, critN, allN, smileN, smileR = 0, 0, 0, 0, 0, 0, 0
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

getgenv().__SourcesDump = { remove = removeAll }
say("hooked " .. hooked .. " remotes, recording " .. DURATION .. "s. Play normally; use every bee ability / tool / bomb you have.")

task.spawn(function()
  task.wait(0.3)
  local ok, err = pcall(lifetimeScan)
  if not ok then log("lifetime scan error: " .. tostring(err)) end
  flash("lifetime scan done")
end)

task.spawn(function()
  while not removed do
    task.wait(0.5)
    if recording then
      local left = math.max(0, DURATION - (os.clock() - t0))
      local kinds = 0
      for _ in pairs(polBySrc) do kinds = kinds + 1 end
      status.Text = string.format("recording: %ds left\npollen hits: %d\nsources: %d kinds\ntotal: %s   smile: %d",
        math.ceil(left), allN, kinds, fmtN(polTotal), smileN)
      if left <= 0 then
        stopRecording()
        local r = buildReport()
        if setclipboard then pcall(setclipboard, r) end
        if writefile then pcall(writefile, "BuffTools_sources_dump.txt", r) end
        flash("DONE - copied + saved")
        say("DONE: " .. #r .. " chars. Copied to clipboard and saved as BuffTools_sources_dump.txt")
      end
    else
      status.Text = string.format("STOPPED\npollen hits: %d\ntotal: %s", allN, fmtN(polTotal))
    end
  end
end)
