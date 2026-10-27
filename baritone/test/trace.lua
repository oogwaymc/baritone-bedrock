-- trace one scenario: SCEN=pillar NATIVE=1 luahost test/trace.lua
package.path = "test/?.lua;" .. package.path
local SIM = require("sim")
BARITONE_EXPOSE = true
local scen = os.getenv("SCEN") or "pillar"
SIM.verbose = true
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
p.hotbar[1] = { name = "cobblestone", count = 64 }
SIM.files["Baritone/settings.txt"] = "mouseYawPerPixel=0.12\nmousePitchPerPixel=0.12\nchatDebug=true\n"
SIM.load("dist/Baritone.lua")
SIM.run(600)
SIM.command(os.getenv("CMD") or "#goto 0 68 0")
local nextT = 0
SIM.run(tonumber(os.getenv("MS") or "8000"), function()
    if SIM.t >= nextT then
        nextT = SIM.t + (tonumber(os.getenv("EVERY") or "150"))
        local E = BARITONE_EXPOSE
        local N = E.NAV
        local mv = ""
        if N.path and N.path[N.idx + 1] then
            local c, n = N.path[N.idx], N.path[N.idx + 1]
            mv = string.format("%s (%d,%d,%d)->(%d,%d,%d)", E.PF.MNAME[n.kind] or "?", c.x, c.y, c.z, n.x, n.y, n.z)
        end
        local keys = {}
        for k in pairs(SIM.keys) do keys[#keys + 1] = k end
        table.sort(keys)
        print(string.format("t=%5d pos=(%.2f,%.2f,%.2f) vy=%.2f simG=%s botG=%s pitch=%.0f keys=%s nav=%s %s act=%s",
            math.floor(SIM.t), p.x, p.y, p.z, p.vy, tostring(p.grounded), tostring(E.P.grounded), p.pitch,
            table.concat(keys, "+"), N.state, mv, N.act and N.act.key or "-"))
    end
end)
