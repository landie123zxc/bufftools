-- ability_dump.lua : LIFETIME-only dump to finish the "pollen by ability" table (session + all-time).
-- No waiting, no recording: reads the player's own data table (Totals) once and prints
--   1) EVERY tag of Totals.Pollen.ByTag (all of them, not the top 40) with the BuffTools KEEP / DROP decision
--      and the share of Totals.Pollen.All, so we can see exactly which names are abilities and which are not
--   2) the same for Totals.ChallengePollen.ByTag (only tags that are not in the main list)
--   3) token pick counters: Totals.Collectibles (every entry; the Smile / ability token pick counts live here)
--   4) every numeric Totals key (counters like FlamesSpawned, MarksInTriangulates ...) and small tables in full
--      (DamageDealtBySource, Happenings, BoostBalls, RBC, ClassicEvent, Petals, Stickers, ToyUses)
-- Panel: Copy / Save / Rescan / Remove.   Report: clipboard + BuffTools_ability_dump.txt
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer

if getgenv().__AbilityDump then pcall(getgenv().__AbilityDump.remove) end

local function fmtN(n)
  n = tonumber(n) or 0
  local units = { { 1e33, "Dc" }, { 1e30, "No" }, { 1e27, "Oc" }, { 1e24, "Sp" }, { 1e21, "Sx" }, { 1e18, "Qn" },
    { 1e15, "Qd" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
  for _, u in ipairs(units) do
    if n >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
  end
  if n ~= math.floor(n) then return string.format("%.2f", n) end
  return string.format("%.0f", n)
end

-- same rule the BuffTools Stats tab uses in lifetime mode (FieldFx.PStats.lifeRows)
local TOOL_WORDS = { "Scythe", "Dipper", "Rake", "Staff", "Wand", "Scoop", "Magnet", "Vacuum", "Ballooner" }
local function classify(k)
  for _, w in ipairs(TOOL_WORDS) do
    if k:find(w, 1, true) then return "TOOL" end
  end
  if k == "Bee" or k == "Tool" then return "drop (generic)" end
  if k:find(" Bee$") then return "drop (bee type)" end
  if k:find(" Ability$") then return "drop (colour/class ability tag)" end
  if k:find(" Bomb$") or k:find(" Bomb%+$") then return "drop (bomb variant)" end
  return "KEEP"
end

local function findTotals()
  if type(getgc) ~= "function" then return nil, nil, "getgc unavailable" end
  local best, bestAll, count = nil, -1, 0
  local ok, err = pcall(function()
    for _, t in ipairs(getgc(true)) do
      if type(t) == "table" then
        local tot, uid
        pcall(function() tot = rawget(t, "Totals") uid = rawget(t, "UserId") end)
        if type(tot) == "table" and (uid == nil or uid == player.UserId) then
          local p = rawget(tot, "Pollen")
          if type(p) == "table" and type(rawget(p, "All")) == "number" then
            count = count + 1
            if p.All > bestAll then bestAll, best = p.All, tot end
          end
        end
      end
    end
  end)
  if not ok then return nil, nil, tostring(err) end
  return best, count, nil
end

local function numRows(tb)
  local rows, sum = {}, 0
  for k, v in pairs(tb) do
    if type(v) == "number" then rows[#rows + 1] = { tostring(k), v } sum = sum + v end
  end
  table.sort(rows, function(a, b) return a[2] > b[2] end)
  return rows, sum
end

local function buildReport()
  local out = {}
  local function L(s) out[#out + 1] = s end
  local tot, copies, err = findTotals()
  if not tot then L("no player data table found: " .. tostring(err)) return table.concat(out, "\n") end
  L(string.format("=== ability_dump: %d Totals copies in memory, using the newest ===", copies))

  local pol = tot.Pollen
  local all = tonumber(pol.All) or 0
  L(string.format("Totals.Pollen.All = %s   Converted = %s   ConvertedAtHive = %s", fmtN(all), fmtN(pol.Converted), fmtN(pol.ConvertedAtHive)))

  local function tagTable(label, p, mainSet)
    local bt = p and p.ByTag
    if type(bt) ~= "table" then L("(no ByTag in " .. label .. ")") return end
    local rows = numRows(bt)
    local pall = tonumber(p.All) or 0
    local kept, keptN = 0, 0
    L(string.format("=== %s.ByTag: ALL %d tags (share is of %s.All = %s) ===", label, #rows, label, fmtN(pall)))
    L(string.format("  %-42s %10s %7s  %s", "TAG", "POLLEN", "SHARE", "BuffTools"))
    for _, r in ipairs(rows) do
      if not mainSet or not mainSet[r[1]] then
        local c = classify(r[1])
        if c == "KEEP" or c == "TOOL" then kept = kept + r[2] keptN = keptN + 1 end
        L(string.format("  %-42s %10s %6.2f%%  %s", string.format("%q", r[1]), fmtN(r[2]), pall > 0 and r[2] / pall * 100 or 0, c))
      end
    end
    L(string.format("  KEEP+TOOL tags: %d, sum %s = %.1f%% of All (rest would show as \"Other\")", keptN, fmtN(kept), pall > 0 and kept / pall * 100 or 0))
  end

  tagTable("Totals.Pollen", pol, nil)
  local mainSet = {}
  if type(pol.ByTag) == "table" then for k in pairs(pol.ByTag) do mainSet[k] = true end end
  if type(tot.ChallengePollen) == "table" then tagTable("Totals.ChallengePollen (tags missing in the main list)", tot.ChallengePollen, mainSet) end

  -- Collectibles: token counts per name
  if type(tot.Collectibles) == "table" then
    local rows, sum = numRows(tot.Collectibles)
    L(string.format("=== Totals.Collectibles: %d entries (token pick counters; look for Smile / ability tokens) ===", #rows))
    for _, r in ipairs(rows) do
      L(string.format("  %-44s %10s", string.format("%q", r[1]), fmtN(r[2])))
    end
  end

  -- numeric Totals keys
  local nums, tabs = {}, {}
  for k, v in pairs(tot) do
    if type(v) == "number" then nums[#nums + 1] = { tostring(k), v }
    elseif type(v) == "table" then tabs[#tabs + 1] = tostring(k) end
  end
  table.sort(nums, function(a, b) return a[1] < b[1] end)
  table.sort(tabs)
  L(string.format("=== Totals numeric keys: %d ===", #nums))
  for _, r in ipairs(nums) do L(string.format("  %-44s %s", r[1], fmtN(r[2]))) end
  L("=== Totals table keys: " .. table.concat(tabs, ", ") .. " ===")

  for _, nm in ipairs({ "DamageDealtBySource", "Happenings", "BoostBalls", "RBC", "ClassicEvent", "Petals", "Stickers", "ToyUses", "Kills" }) do
    local tb = tot[nm]
    if type(tb) == "table" then
      local rows, sum = numRows(tb)
      L(string.format("=== Totals.%s: %d numbers, sum=%s ===", nm, #rows, fmtN(sum)))
      for i = 1, math.min(#rows, 60) do L(string.format("  %-40s %10s", string.format("%q", rows[i][1]), fmtN(rows[i][2]))) end
      for k, v in pairs(tb) do
        if type(v) == "table" then
          local parts, n = {}, 0
          for k2, v2 in pairs(v) do
            n = n + 1
            if n > 10 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(k2) .. "=" .. tostring(v2)
          end
          L(string.format("  [table] %s = {%s}", tostring(k), table.concat(parts, ", ")))
        end
      end
    end
  end
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------- GUI (same as the other dumps)
local gui = Instance.new("ScreenGui")
gui.Name = "AbilityDumpGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.IgnoreGuiInset = true
local okParent = false
if type(gethui) == "function" then okParent = pcall(function() gui.Parent = gethui() end) end
if not okParent then okParent = pcall(function() gui.Parent = game:GetService("CoreGui") end) end
if not okParent or not gui.Parent then gui.Parent = player:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(300, 170)
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
title.Text = "  ability_dump (lifetime)"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 220, 220)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Active = true
title.Parent = frame

local status = Instance.new("TextLabel")
status.Position = UDim2.fromOffset(10, 30)
status.Size = UDim2.new(1, -20, 0, 50)
status.BackgroundTransparency = 1
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextColor3 = Color3.fromRGB(226, 214, 214)
status.Font = Enum.Font.Code
status.TextSize = 13
status.TextWrapped = true
status.Text = "scanning..."
status.Parent = frame

local report = ""
local removed = false
local function rescan()
  status.Text = "scanning player data..."
  task.spawn(function()
    task.wait(0.1)
    local ok, r = pcall(buildReport)
    report = ok and r or ("scan error: " .. tostring(r))
    if setclipboard then pcall(setclipboard, report) end
    if writefile then pcall(writefile, "BuffTools_ability_dump.txt", report) end
    if not removed then status.Text = string.format("DONE: %d chars\ncopied + saved\n(BuffTools_ability_dump.txt)", #report) end
    print("[ability_dump] done, " .. #report .. " chars; copied to clipboard and saved")
  end)
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

button("Copy", 10, 88, 66, Color3.fromRGB(60, 120, 70), function()
  if setclipboard then setclipboard(report) status.Text = "copied " .. #report .. " chars" else status.Text = "no setclipboard - use Save" end
end)
button("Save", 82, 88, 66, Color3.fromRGB(60, 90, 140), function()
  if writefile then
    local ok = pcall(writefile, "BuffTools_ability_dump.txt", report)
    status.Text = ok and "saved BuffTools_ability_dump.txt" or "save failed"
  else
    status.Text = "no writefile"
  end
end)
button("Rescan", 154, 88, 136, Color3.fromRGB(100, 80, 140), rescan)
button("Remove", 10, 126, 280, Color3.fromRGB(150, 36, 46), function()
  if removed then return end
  removed = true
  pcall(function() gui:Destroy() end)
  getgenv().__AbilityDump = nil
  print("[ability_dump] removed")
end)

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

getgenv().__AbilityDump = { remove = function()
  removed = true
  pcall(function() gui:Destroy() end)
end }
rescan()
