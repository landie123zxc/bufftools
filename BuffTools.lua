--[[ BuffTools entry — inject this URL only, no ?v ]]
local u = "https://raw.githubusercontent.com/landie123zxc/bufftools/main/BuffToolsBody.lua"
local src
local ok, err = pcall(function()
  src = game:HttpGet(u .. "?t=" .. tostring(os.time()))
end)
if not ok or type(src) ~= "string" or #src < 50 then
  error("BuffTools body download failed: " .. tostring(err))
end
local fn, e = loadstring(src)
if not fn and type(load) == "function" then
  fn, e = load(src)
end
if not fn then
  error(tostring(e))
end
fn()
