package.path = "test/?.lua;" .. package.path
local SIM = require("sim")
BARITONE_EXPOSE = true
SIM.files, SIM.dirs = {}, {}
SIM.reset()
SIM.gen = function(x, y, z)
    if y == -64 then return "bedrock" end
    if y <= 63 then return (y == 63) and "grass_block" or "stone" end
    return "air"
end
local p = SIM.player
p.x, p.y, p.z, p.grounded = 0.5, 64, 0.5, true
p.hotbar[0] = { name = "iron_pickaxe", count = 1 }
SIM.files["Baritone/settings.txt"] = "mouseYawPerPixel=0.12\nmousePitchPerPixel=0.12\n"
SIM.load((os.getenv("BARITONE_MODULE") or "dist/Baritone.lua"))
SIM.run(600)
local E = BARITONE_EXPOSE
local searches, expanded = 0, 0
local origNew = E.PF.new
E.PF.new = function(...) searches = searches + 1 return origNew(...) end
local origStep = E.PF.step
E.PF.step = function(s, b) local r = origStep(s, b) if r ~= "running" then expanded = expanded + s.expanded end return r end
local friend = SIM.addEntity({ name = "Friend", type = "minecraft:player", x = 12.5, y = 64, z = 6.5 })
local t = 0
SIM.entityTick = function() t = t + 1 if t > 100 and t < 300 then friend.x = friend.x + 0.08 end end
SIM.command("#follow Friend")
local c0 = os.clock()
SIM.run(30000)
print("cpu", os.clock() - c0, "searches", searches, "expanded", expanded)
local pp = SIM.player
print(string.format("player %.1f %.1f friend %.1f %.1f", pp.x, pp.z, friend.x, friend.z))
