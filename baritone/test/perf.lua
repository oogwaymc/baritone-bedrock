package.path = "test/?.lua;" .. package.path
local SIM = require("sim")
BARITONE_EXPOSE = true
SIM.files, SIM.dirs = {}, {}
SIM.reset()
-- hilly terrain with trees and caves
local function h(x, z)
    return 64 + math.floor(4 * math.sin(x / 9) + 3 * math.cos(z / 7) + 2 * math.sin((x + z) / 5))
end
SIM.gen = function(x, y, z)
    if y == -64 then return "bedrock" end
    local hh = h(x, z)
    if y <= hh then
        if y == hh then return "grass_block" end
        if y > hh - 3 then return "dirt" end
        return "stone"
    end
    if (x * 7 + z * 13) % 23 == 0 and y <= hh + 4 then return "oak_log" end
    return "air"
end
local p = SIM.player
p.x, p.y, p.z, p.grounded = 0.5, h(0, 0) + 1, 0.5, true
p.hotbar[0] = { name = "iron_pickaxe", count = 1 }
p.hotbar[1] = { name = "cobblestone", count = 64 }
SIM.files["Baritone/settings.txt"] = "mouseYawPerPixel=0.12\nmousePitchPerPixel=0.12\n"
SIM.load((os.getenv("BARITONE_MODULE") or "dist/Baritone.lua"))
SIM.run(3000)
local E = BARITONE_EXPOSE
E.P.refresh()
E.S.costHeuristic = tonumber(os.getenv("CH") or "3.563")
for _, target in ipairs({ { 150, -40 }, { 150, -40 }, { 300, 120 }, { 300, 120 } }) do
    if not os.getenv("KEEP") then E.W.clear() end
    local goal = E.G.block(target[1], h(target[1], target[2]) + 1, target[2])
    local ctx = E.NAV.ctx()
    local s = E.PF.new(0, h(0, 0) + 1, 0, goal, ctx)
    local t0 = os.clock()
    local st
    repeat st = E.PF.step(s, 1e9) until st ~= "running"
    local dt = os.clock() - t0
    print(string.format("goal %s: %s, %d nodes in path, %d expanded, %.0f ms CPU, %.1f us/node",
        goal.desc, st, s.path and #s.path or 0, s.expanded, dt * 1000, dt * 1e6 / math.max(1, s.expanded)))
end
