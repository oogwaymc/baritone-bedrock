-- End-to-end tests for Baritone.lua using the mock in sim.lua
package.path = "test/?.lua;" .. package.path
local SIM = require("sim")
BARITONE_EXPOSE = true
local MODULE = (os.getenv("BARITONE_MODULE") or "dist/Baritone.lua")
local only = os.getenv("ONLY")
SIM.verbose = os.getenv("VERBOSE") == "1"

local results = {}
local floor = math.floor

local function flatWorld(groundY)
    groundY = groundY or 63
    return function(x, y, z)
        if y == -64 then return "bedrock" end
        if y < groundY - 3 then return "stone" end
        if y < groundY then return "dirt" end
        if y == groundY then return "grass_block" end
        return "air"
    end
end

local function setup(opts)
    opts = opts or {}
    SIM.files = opts.keepFiles and SIM.files or {}
    SIM.dirs = opts.keepFiles and SIM.dirs or {}
    SIM.reset()
    SIM.gen = opts.gen or flatWorld(63)
    local p = SIM.player
    p.x, p.y, p.z = opts.x or 0.5, opts.y or 64, opts.z or 0.5
    p.grounded = true
    p.yaw = opts.yaw or 0
    p.gamemode = opts.gamemode or 0
    for s, it in pairs(opts.hotbar or { [0] = { name = "iron_pickaxe", count = 1 }, [1] = { name = "cobblestone", count = 64 } }) do
        p.hotbar[s] = { name = it.name, count = it.count or 1 }
    end
    if opts.calibrated ~= false and not opts.keepFiles then
        SIM.files["Baritone/settings.txt"] = "mouseYawPerPixel=0.12\nmousePitchPerPixel=0.12\n"
    end
    if opts.settings then
        SIM.files["Baritone/settings.txt"] = (SIM.files["Baritone/settings.txt"] or "") .. opts.settings
    end
    if opts.files then for k, v in pairs(opts.files) do SIM.files[k] = v end end
    SIM.load(MODULE)
    SIM.run(600)
end

local function test(name, fn)
    if only and not name:find(only, 1, true) then return end
    local t0 = os.clock()
    local ok, err = pcall(fn)
    local dt = os.clock() - t0
    results[#results + 1] = { name = name, ok = ok, err = err }
    print(string.format("%s %-42s %6.2fs  %s", ok and "PASS" or "FAIL", name, dt, ok and "" or tostring(err)))
    if not ok then print("   last chat: " .. SIM.lastChat(6)) end
end

local function assertTrue(c, msg) if not c then error(msg or "assertion failed", 2) end end
local function feet() local p = SIM.player return floor(p.x), floor(p.y + 0.2), floor(p.z) end
local function near(x, y, z, r)
    local p = SIM.player
    local dx, dy, dz = p.x - (x + 0.5), p.y - y, p.z - (z + 0.5)
    return math.sqrt(dx * dx + dy * dy + dz * dz) <= (r or 1)
end
local function idleAfter() return SIM.chatContains("Reached") or SIM.chatContains("No path") end

-- ------------------------------------------------------------------
test("module loads + help", function()
    setup()
    assertTrue(SIM.events.SetupAndRenderEvent and SIM.events.TickEvent and SIM.events.ChatSendEvent, "events not registered")
    assertTrue(SIM.commands.b, ".b command not registered")
    local r = SIM.command("#help")
    assertTrue(r == true, "chat command was not cancelled")
    assertTrue(SIM.chatContains("goto"), "help text missing")
    local n = #SIM.chat
    SIM.command("hello everyone")
    assertTrue(#SIM.chat == n, "normal chat should pass through")
    SIM.commands.b({ "status" })
    if SIM.nativeMode then
        assertTrue(SIM.chatContains("rotation set"), "status via .b failed: " .. SIM.lastChat(1))
    else
        assertTrue(SIM.chatContains("helper connected"), "status via .b failed: " .. SIM.lastChat(1))
    end
end)

test("calibration + hotbar scan", function()
    setup({ calibrated = false, settings = SIM.nativeMode and "rotationMode=turn\n" or nil })
    SIM.command("#calibrate")
    SIM.run(6000, function() return SIM.chatContains("Mouse calibrated") end)
    assertTrue(SIM.chatContains("Mouse calibrated"), "no calibration message")
    local s = SIM.files["Baritone/settings.txt"] or ""
    local v = tonumber(s:match("mouseYawPerPixel=([%d%.%-]+)"))
    assertTrue(v and math.abs(v - 0.12) < 0.01, "bad yaw calibration " .. tostring(v))
    SIM.command("#hotbar")
    SIM.run(4000, function() return SIM.chatContains("Hotbar:") end)
    assertTrue(SIM.chatContains("1:iron_pickaxe"), "hotbar list wrong: " .. SIM.lastChat(1))
end)

test("goto flat 20 blocks", function()
    setup()
    SIM.command("#goto 20 64 12")
    SIM.run(30000, idleAfter)
    assertTrue(SIM.chatContains("Reached"), "did not arrive")
    local x, y, z = feet()
    assertTrue(x == 20 and y == 64 and z == 12, string.format("ended at %d %d %d", x, y, z))
end)

test("goto xz + relative", function()
    setup()
    SIM.command("#goto ~-15 ~10")
    SIM.run(30000, idleAfter)
    local x, y, z = feet()
    assertTrue(x == -15 and z == 10, string.format("ended at %d %d %d", x, y, z))
end)

test("goto up and down steps", function()
    setup({ gen = function(x, y, z)
        local h = 63
        if x >= 4 and x <= 6 then h = 63 + (x - 3) end   -- staircase up to 66
        if x >= 7 and x <= 9 then h = 66 end
        if x >= 10 and x <= 12 then h = 66 - (x - 9) end
        if y == -64 then return "bedrock" end
        if y <= h then return (y == h) and "grass_block" or "stone" end
        return "air"
    end })
    SIM.command("#goto 16 64 0")
    SIM.run(40000, idleAfter)
    local x, y, z = feet()
    assertTrue(x == 16 and y == 64 and z == 0, string.format("ended at %d %d %d (%s)", x, y, z, SIM.lastChat(2)))
end)

test("goto through a wall (breaks blocks)", function()
    setup({ gen = function(x, y, z)
        if y == -64 then return "bedrock" end
        if y <= 63 then return (y == 63) and "grass_block" or "stone" end
        if x == 5 and y <= 70 and z >= -30 and z <= 30 then return "stone" end
        return "air"
    end })
    SIM.command("#goto 10 64 0")
    SIM.run(60000, idleAfter)
    local x, y, z = feet()
    assertTrue(x == 10 and y == 64 and z == 0, string.format("ended at %d %d %d (%s)", x, y, z, SIM.lastChat(2)))
    assertTrue(SIM.broken >= 2, "expected to break the wall, broke " .. SIM.broken)
end)

test("goto across a gap (bridges)", function()
    setup({ gen = function(x, y, z)
        if y == -64 then return "bedrock" end
        if x >= 3 and x <= 6 and z >= -40 and z <= 40 then
            if y < 30 then return "stone" end
            return "air"
        end
        if y <= 63 then return (y == 63) and "grass_block" or "stone" end
        return "air"
    end })
    SIM.command("#goto 10 64 0")
    SIM.run(90000, idleAfter)
    local x, y, z = feet()
    assertTrue(x == 10 and y == 64 and z == 0, string.format("ended at %d %d %d (%s)", x, y, z, SIM.lastChat(3)))
    assertTrue(SIM.placed >= 4, "expected to place bridge blocks, placed " .. SIM.placed)
    assertTrue(SIM.player.damage == 0, "took damage " .. SIM.player.damage)
end)

test("goto up a cliff (pillar)", function()
    setup({ gen = function(x, y, z)
        if y == -64 then return "bedrock" end
        if y <= 63 then return (y == 63) and "grass_block" or "stone" end
        return "air"
    end })
    SIM.command("#goto 0 68 0")
    SIM.run(60000, idleAfter)
    local x, y, z = feet()
    assertTrue(y == 68, string.format("ended at %d %d %d (%s)", x, y, z, SIM.lastChat(3)))
end)

test("fall guard water bucket", function()
    setup({ hotbar = { [0] = { name = "iron_pickaxe" }, [3] = { name = "water_bucket" } } })
    SIM.run(5000) -- the bot learns the hotbar shortly after the helper connects
    SIM.player.y = 100
    SIM.player.grounded = false
    SIM.run(9000, function() return SIM.player.grounded and SIM.player.y < 70 end)
    SIM.run(4000)
    assertTrue(SIM.player.damage == 0, "took fall damage " .. SIM.player.damage)
    assertTrue((SIM.waterPlaced or 0) >= 1, "no water placed")
    assertTrue((SIM.waterPicked or 0) >= 1, "water not picked back up")
end)

test("mine diamonds", function()
    local ores = { ["8,60,3"] = true, ["9,60,3"] = true, ["-6,58,-5"] = true }
    setup({ gen = function(x, y, z)
        if y == -64 then return "bedrock" end
        if ores[x .. "," .. y .. "," .. z] then return "diamond_ore" end
        if y <= 63 then return (y == 63) and "grass_block" or "stone" end
        return "air"
    end, settings = "exploreForBlocks=false\n" })
    SIM.command("#mine diamond_ore 3")
    SIM.run(120000, function() return SIM.chatContains("Mined 3") or SIM.chatContains("No diamond") end)
    local n = SIM.brokenNames and SIM.brokenNames.diamond_ore or 0
    assertTrue(n == 3, "mined " .. n .. " diamonds")
    assertTrue(SIM.chatContains("Mined 3"), "no completion message")
end)

test("settings persist", function()
    setup()
    SIM.command("#set allowSprint false")
    SIM.command("#set maxFallHeightNoWater 5")
    SIM.command("#set acceptableThrowawayItems dirt, netherrack")
    local s = SIM.files["Baritone/settings.txt"]
    assertTrue(s:find("allowSprint=false", 1, true), "allowSprint not saved")
    assertTrue(s:find("maxFallHeightNoWater=5", 1, true), "maxFall not saved")
    assertTrue(s:find("acceptableThrowawayItems=dirt,netherrack", 1, true), "list not saved: " .. s)
    setup({ keepFiles = true })
    SIM.command("#set")
    assertTrue(SIM.chatContains("allowSprint=false"), "not reloaded: " .. SIM.lastChat(1))
    SIM.command("#set reset")
    assertTrue(not (SIM.files["Baritone/settings.txt"] or ""):find("allowSprint", 1, true), "reset didn't save")
end)

test("waypoints", function()
    setup()
    SIM.command("#wp save base 12 64 -7")
    SIM.command("#wp goto base")
    SIM.run(30000, idleAfter)
    local x, y, z = feet()
    assertTrue(x == 12 and z == -7, string.format("ended at %d %d %d", x, y, z))
    assertTrue((SIM.files["Baritone/waypoints.txt"] or ""):find("base=12,64,-7", 1, true), "waypoint not saved")
end)

local NB = require("nbtgen")
local makeMcstructure, hexOf = NB.makeMcstructure, NB.hexOf

test("build mcstructure (3x2x3 hut)", function()
    -- palette 0 = cobblestone, 1 = air ; floor 3x3 cobble, ring of cobble on y=1 except centre
    local bin = makeMcstructure(3, 2, 3, function(x, y, z)
        if y == 0 then return 0 end
        if x == 1 and z == 1 then return 1 end
        return 0
    end, { "cobblestone", "air" })
    setup({ files = {
        ["Baritone/schematics/hut.mcstructure"] = bin,
        ["Baritone/schematics/.cache/hut.mcstructure.hex"] = "BHEX1 mcstructure 0 " .. #bin .. "\n" .. hexOf(bin) .. "\nEND\n",
    }, hotbar = { [0] = { name = "iron_pickaxe" }, [1] = { name = "cobblestone", count = 64 }, [2] = { name = "dirt", count = 64 } } })
    SIM.command("#build hut 5 64 5")
    SIM.run(120000, function() return SIM.chatContains("Build complete") end)
    assertTrue(SIM.chatContains("Loaded hut"), "schematic not loaded: " .. SIM.lastChat(3))
    local bad = {}
    for x = 0, 2 do for y = 0, 1 do for z = 0, 2 do
        local want = (y == 1 and x == 1 and z == 1) and "air" or "cobblestone"
        local got = SIM.get(5 + x, 64 + y, 5 + z)
        if want == "cobblestone" and got ~= want then bad[#bad + 1] = (5 + x) .. "," .. (64 + y) .. "," .. (5 + z) .. "=" .. got end
    end end end
    assertTrue(#bad == 0, "wrong blocks: " .. table.concat(bad, " "))
    assertTrue(SIM.chatContains("Build complete"), "no completion: " .. SIM.lastChat(2))
end)

test("farm wheat (#farm now)", function()
    setup({ gen = function(x, y, z)
        if y == -64 then return "bedrock" end
        if y < 63 then return "dirt" end
        if y == 63 then
            if x >= 2 and x <= 5 and z >= 2 and z <= 4 then return "farmland" end
            return "grass_block"
        end
        if y == 64 and x >= 2 and x <= 5 and z >= 2 and z <= 4 then return "wheat" end
        return "air"
    end, hotbar = { [0] = { name = "iron_hoe" }, [1] = { name = "wheat_seeds", count = 4 } } })
    SIM.command("#farm 8 now")
    SIM.run(120000, function()
        local wheatLeft = 0
        for x = 2, 5 do for z = 2, 4 do if SIM.get(x, 64, z) == "air" then wheatLeft = wheatLeft + 1 end end end
        return (SIM.brokenNames and (SIM.brokenNames.wheat or 0) >= 12) and wheatLeft == 0
    end)
    local harvested = SIM.brokenNames and SIM.brokenNames.wheat or 0
    assertTrue(harvested == 12, "harvested " .. harvested)
    local planted = 0
    for x = 2, 5 do for z = 2, 4 do if SIM.get(x, 64, z) == "wheat" then planted = planted + 1 end end end
    assertTrue(planted == 12, "replanted " .. planted .. " (" .. SIM.lastChat(2) .. ")")
end)

test("follow a walking player", function()
    setup()
    local friend = SIM.addEntity({ name = "Friend", type = "minecraft:player", x = 12.5, y = 64, z = 6.5 })
    local t = 0
    SIM.entityTick = function()
        t = t + 1
        if t > 100 and t < 300 then friend.x = friend.x + 0.08 end
    end
    SIM.command("#follow Friend")
    SIM.run(30000)
    local p = SIM.player
    local d = math.sqrt((p.x - friend.x) ^ 2 + (p.z - friend.z) ^ 2)
    SIM.entityTick = nil
    assertTrue(d < 5, string.format("ended %.1f blocks from friend (%s)", d, SIM.lastChat(2)))
end)

test("goto with append-mode files + stop", function()
    setup()
    SIM.command("#goto 200 64 0")
    SIM.run(3000)
    SIM.command("#stop")
    SIM.run(500)
    local x1 = SIM.player.x
    SIM.run(1500)
    assertTrue(math.abs(SIM.player.x - x1) < 0.3, "kept moving after #stop")
    assertTrue(SIM.chatContains("Stopped"), "no stop message")
end)

test("End key panic stops", function()
    setup()
    SIM.command("#goto 200 64 0")
    SIM.run(2000)
    SIM.helperPanic = SIM.helperPanic + 1
    SIM.run(1500)
    assertTrue(SIM.chatContains("Stopped (End key)") or SIM.chatContains("Stopped (stop key)"), "panic not handled: " .. SIM.lastChat(2))
end)

test("long goto through unloaded chunks", function()
    setup({ gen = function(x, y, z)
        if math.abs(x) > 100 then return "air" end   -- 'unloaded' beyond x=100
        if y == -64 then return "bedrock" end
        if y <= 63 then return (y == 63) and "grass_block" or "stone" end
        return "air"
    end })
    SIM.command("#goto 400 64 0")
    SIM.run(60000)
    local x = feet()
    assertTrue(x >= 90 and x <= 100, "should stop at edge of loaded area, x=" .. x)
    assertTrue(SIM.player.damage == 0 and SIM.player.y > 60, "fell into the void")
end)

-- ---------------- schematic format parsing ----------------
local function loadSchemFile(fname, bin)
    setup({ files = {
        ["Baritone/schematics/" .. fname] = bin,
        ["Baritone/schematics/.cache/" .. fname .. ".hex"] = "BHEX1 x 0 " .. #bin .. "\n" .. hexOf(bin) .. "\nEND\n",
    } })
    SIM.command("#lm load " .. fname .. " 100 70 200")
    SIM.run(20000, function() return SIM.chatContains("Loaded ") or SIM.chatContains("Couldn't load") end)
    assertTrue(SIM.chatContains("Loaded "), "not loaded: " .. SIM.lastChat(2))
    local E = BARITONE_EXPOSE
    local got = {}
    for _, t in ipairs(E.LM.targets) do got[t[1] .. "," .. t[2] .. "," .. t[3]] = t[4] end
    return got, E
end

local function checkGrid(got, sx, sy, sz, ox, oy, oz, expectFn)
    local bad, count = {}, 0
    for x = 0, sx - 1 do for y = 0, sy - 1 do for z = 0, sz - 1 do
        local want = expectFn(x, y, z)
        local k = (ox + x) .. "," .. (oy + y) .. "," .. (oz + z)
        if want then count = count + 1 end
        if got[k] ~= want and #bad < 6 then bad[#bad + 1] = k .. " want " .. tostring(want) .. " got " .. tostring(got[k]) end
    end end end
    local n = 0
    for _ in pairs(got) do n = n + 1 end
    assertTrue(#bad == 0, table.concat(bad, "; "))
    assertTrue(n == count, "extra targets: " .. n .. " vs " .. count)
end

test("parse .litematic (bit-packed, spanning longs)", function()
    local pal = { "minecraft:air" }
    for i = 1, 20 do pal[#pal + 1] = "minecraft:" .. ({ "stone", "magma_block", "oak_planks", "white_wool", "glass" })[(i - 1) % 5 + 1] .. (i > 5 and ("_" .. i) or "") end
    local function fn(x, y, z) return (x * 7 + y * 3 + z * 5) % #pal end
    local bin = NB.makeLitematic({ { name = "Main", pos = { 0, 0, 0 }, size = { 6, 3, 5 }, palette = pal, fn = fn } })
    local got = loadSchemFile("castle.litematic", bin)
    checkGrid(got, 6, 3, 5, 100, 70, 200, function(x, y, z)
        local v = fn(x, y, z)
        if v == 0 then return nil end
        local jn = pal[v + 1]:gsub("minecraft:", "")
        if jn == "magma_block" then return "magma" end
        return jn
    end)
end)

test("parse .litematic (two regions, negative size)", function()
    local pal = { "minecraft:air", "minecraft:cobblestone", "minecraft:bricks" }
    local bin = NB.makeLitematic({
        { name = "A", pos = { 0, 0, 0 }, size = { 3, 1, 2 }, palette = pal, fn = function() return 1 end },
        { name = "B", pos = { 5, 2, 1 }, size = { -2, -1, 1 }, palette = pal, fn = function() return 2 end },
    })
    local got = loadSchemFile("two.litematic", bin)
    -- region B covers x 4..5, y 2, z 1 ; overall min = (0,0,0)
    checkGrid(got, 6, 3, 2, 100, 70, 200, function(x, y, z)
        if y == 0 and x <= 2 and z <= 1 then return "cobblestone" end
        if y == 2 and (x == 4 or x == 5) and z == 1 then return "brick_block" end
        return nil
    end)
end)

test("parse Sponge .schem v2 + v3 (varints)", function()
    local pal = { "minecraft:air" }
    for i = 1, 200 do pal[#pal + 1] = "minecraft:stone_" .. i end
    local function fn(x, y, z) return (x + y * 4 + z * 16) % #pal end
    for _, v in ipairs({ 2, 3 }) do
        local bin = NB.makeSponge(4, 5, 13, pal, fn, v)
        local got = loadSchemFile("s" .. v .. ".schem", bin)
        checkGrid(got, 4, 5, 13, 100, 70, 200, function(x, y, z)
            local i = fn(x, y, z)
            if i == 0 then return nil end
            return (pal[i + 1]:gsub("minecraft:", ""))
        end)
    end
end)

test("parse Java structure .nbt", function()
    local pal = { "minecraft:air", "minecraft:oak_log[axis=y]", "minecraft:note_block" }
    local function fn(x, y, z) if (x + z) % 2 == 0 then return 1 elseif y == 1 then return 2 else return nil end end
    local bin = NB.makeJavaStructure(3, 2, 3, pal, fn)
    local got = loadSchemFile("tower.nbt", bin)
    checkGrid(got, 3, 2, 3, 100, 70, 200, function(x, y, z)
        local i = fn(x, y, z)
        if i == 1 then return "oak_log" elseif i == 2 then return "noteblock" end
        return nil
    end)
end)

test("litematica rotate / mirror / materials", function()
    local pal = { "minecraft:air", "minecraft:stone", "minecraft:glass" }
    local bin = NB.makeLitematic({ { name = "L", pos = { 0, 0, 0 }, size = { 3, 1, 2 }, palette = pal,
        fn = function(x, y, z) if x == 0 and z == 0 then return 2 end return 1 end } })
    local got, E = loadSchemFile("ell.litematic", bin)
    assertTrue(got["100,70,200"] == "glass", "glass corner wrong before rotate")
    SIM.command("#lm rotate 90")
    local g2 = {}
    for _, t in ipairs(E.LM.targets) do g2[t[1] .. "," .. t[2] .. "," .. t[3]] = t[4] end
    -- rot 90: wx = sz-1-z, wz = x  -> (0,0,0) maps to (1,0,0)
    assertTrue(g2["101,70,200"] == "glass", "rotation wrong")
    SIM.command("#lm rotate 270")
    SIM.command("#lm mirror x")
    local g3 = {}
    for _, t in ipairs(E.LM.targets) do g3[t[1] .. "," .. t[2] .. "," .. t[3]] = t[4] end
    assertTrue(g3["102,70,200"] == "glass", "mirror wrong")
    SIM.command("#lm materials")
    assertTrue(SIM.chatContains("stone x5"), "materials list wrong: " .. SIM.lastChat(3))
    SIM.command("#lm verify")
    assertTrue(SIM.chatContains("0 correct, 6 missing"), "verify wrong: " .. SIM.lastChat(1))
end)

test("elytra flight", function()
    setup({ hotbar = { [0] = { name = "iron_pickaxe" }, [2] = { name = "firework_rocket", count = 32 } } })
    SIM.player.chest = "elytra"
    SIM.run(4000)
    SIM.command("#elytra 300 40")
    SIM.run(90000, function() return SIM.chatContains("Landed at destination") or SIM.chatContains("Couldn't take off") end)
    local p = SIM.player
    local d = math.sqrt((p.x - 300) ^ 2 + (p.z - 40) ^ 2)
    assertTrue(SIM.chatContains("Landed at destination"), "did not land: " .. SIM.lastChat(2) .. string.format(" at %.0f %.0f %.0f", p.x, p.y, p.z))
    assertTrue(d < 15, "landed " .. math.floor(d) .. " blocks away")
    assertTrue(p.damage <= 4, "took " .. p.damage .. " damage")
end)

test("swim across a lake", function()
    setup({ gen = function(x, y, z)
        if y == -64 then return "bedrock" end
        if x >= 4 and x <= 14 and z >= -30 and z <= 30 then
            if y <= 58 then return "dirt" end
            if y <= 63 then return "water" end
            return "air"
        end
        if y <= 63 then return (y == 63) and "grass_block" or "stone" end
        return "air"
    end, settings = "allowPlace=false\n" })
    SIM.command("#goto 20 64 0")
    SIM.run(90000, idleAfter)
    local x, y, z = feet()
    assertTrue(x == 20 and y == 64 and z == 0, string.format("ended at %d %d %d (%s)", x, y, z, SIM.lastChat(2)))
end)

test("goto nearest block by name", function()
    setup({ gen = function(x, y, z)
        if y == -64 then return "bedrock" end
        if x == 9 and y == 64 and z == -4 then return "crafting_table" end
        if y <= 63 then return (y == 63) and "grass_block" or "stone" end
        return "air"
    end })
    SIM.command("#goto crafting_table")
    SIM.run(30000, function() return SIM.chatContains("Reached crafting_table") end)
    assertTrue(SIM.chatContains("Reached crafting_table"), SIM.lastChat(2))
    local p = SIM.player
    assertTrue(math.abs(p.x - 9.5) + math.abs(p.z + 3.5) < 2.5, "not next to the table")
end)

test("mine with exploration (tunnels to find ore)", function()
    setup({ gen = function(x, y, z)
        if y == -64 then return "bedrock" end
        if x == 40 and y == 64 and z == 0 then return "iron_ore" end
        if y <= 63 then return (y == 63) and "grass_block" or "stone" end
        if y <= 66 and x > 4 then return "stone" end -- a hill to tunnel through
        return "air"
    end, yaw = -90, settings = "mineScanRadius=12\nmineScanHeight=4\n" })
    SIM.command("#mine iron_ore 1")
    SIM.run(240000, function() return SIM.chatContains("Mined 1") end)
    assertTrue(SIM.chatContains("Mined 1"), "did not find the ore: " .. SIM.lastChat(3))
end)

test("tunnel", function()
    setup({ gen = function(x, y, z)
        if y == -64 then return "bedrock" end
        if y <= 70 and x >= 2 then return "stone" end
        if y <= 63 then return "stone" end
        return "air"
    end, yaw = -90 })
    SIM.command("#tunnel 20")
    SIM.run(240000, function() return SIM.chatContains("Tunnel finished") or SIM.chatContains("blocked") end)
    assertTrue(SIM.chatContains("Tunnel finished"), SIM.lastChat(2))
    local x, y = feet()
    assertTrue(x == 20 and y == 64, "ended at x=" .. x .. " y=" .. y)
end)

test("inverted mouse + different sensitivity calibrate", function()
    setup({ calibrated = false, settings = SIM.nativeMode and "rotationMode=turn\n" or nil })
    SIM.degPerPx = 0.31
    SIM.pitchPerPx = -0.27
    SIM.command("#calibrate")
    SIM.run(6000, function() return SIM.chatContains("Mouse calibrated") end)
    SIM.command("#goto 15 64 -12")
    SIM.run(30000, idleAfter)
    local x, y, z = feet()
    assertTrue(x == 15 and z == -12, string.format("ended at %d %d %d", x, y, z))
end)

test("long fall path uses water bucket", function()
    setup({ gen = function(x, y, z)
        if y == -64 then return "bedrock" end
        if x >= 3 then return (y <= 48) and ((y == 48) and "grass_block" or "stone") or "air" end
        if y <= 63 then return (y == 63) and "grass_block" or "stone" end
        return "air"
    end, hotbar = { [0] = { name = "iron_pickaxe" }, [4] = { name = "water_bucket" } },
        settings = "allowPlace=false\nallowBreak=false\n" })
    SIM.run(4000)
    SIM.command("#goto 8 49 0")
    SIM.run(40000, idleAfter)
    local x, y, z = feet()
    assertTrue(x == 8 and y == 49, string.format("ended at %d %d %d (%s)", x, y, z, SIM.lastChat(2)))
    assertTrue(SIM.player.damage == 0, "took damage " .. SIM.player.damage)
end)

test("every command runs without errors", function()
    local pal = { "minecraft:air", "minecraft:stone" }
    local bin = NB.makeLitematic({ { name = "L", pos = { 0, 0, 0 }, size = { 2, 2, 2 }, palette = pal, fn = function() return 1 end } })
    setup({ files = {
        ["Baritone/schematics/cube.litematic"] = bin,
        ["Baritone/schematics/.cache/cube.litematic.hex"] = "BHEX1 x 1 " .. #bin .. "\n" .. hexOf(bin) .. "\nEND\n",
    } })
    local cmds = {
        "#help", "#help goto", "#help nosuch", "#nosuchcommand", "#", "#goal", "#goal 5 64 5", "#goal 70", "#goal 3 4",
        "#path", "#stop", "#goal clear", "#path", "#thisway 10", "#stop", "#goto", "#goto abc def",
        "#mine", "#mine 5", "#mine coal 3", "#stop", "#follow", "#follow players", "#stop", "#follow entity zombie", "#stop",
        "#follow player Steve", "#stop", "#farm", "#stop", "#farm 5", "#stop", "#elytra", "#elytra 10 10", "#stop",
        "#tunnel", "#stop", "#lm", "#lm list", "#lm load", "#lm load nosuch", "#lm rotate", "#lm info",
        "#build", "#build nosuch", "#pause", "#resume", "#calibrate", "#stop", "#hotbar", "#status", "#version",
        "#set", "#set nosuch", "#set allowBreak", "#set allowBreak", "#set maxFallHeightNoWater abc",
        "#set colorCurrentPath 1,2,3", "#set colorCurrentPath red", "#set reset allowBreak", "#set reset",
        "#settings", "#settings 2", "#settings 99", "#settings fall", "#modified",
        "#wp", "#wp save", "#wp save a", "#wp save b 1 2 3", "#wp list", "#wp goto", "#wp goto zz", "#wp delete b",
        "#wp delete zz", "#sethome", "#home", "#stop", "#forcecancel", "#cancel",
    }
    for _, c in ipairs(cmds) do
        SIM.command(c)
        SIM.run(300)
    end
    SIM.command("#lm load cube 0 64 10")
    SIM.run(3000)
    local more = { "#lm info", "#lm here", "#lm origin 1 64 12", "#lm move 1 0 0", "#lm rotate 90", "#lm mirror z",
        "#lm mirror none", "#lm mirror q", "#lm layer 0", "#lm layer all", "#lm render", "#lm render", "#lm materials",
        "#lm verify", "#lm build", "#stop", "#lm unload", "#lm info" }
    for _, c in ipairs(more) do
        SIM.command(c)
        SIM.run(300)
    end
    for _, m in ipairs(SIM.chat) do
        assertTrue(not m:find("Error in", 1, true) and not m:find("Internal error", 1, true), "error: " .. m)
    end
end)

if SIM.nativeMode then
    test("DLL: falls back to mouse-look if direct rotation is ignored", function()
        SIM.nativeRotationWorks = false
        local ok, err = pcall(function()
            setup({ calibrated = false })
            SIM.command("#goto 15 64 9")
            SIM.run(40000, idleAfter)
        end)
        SIM.nativeRotationWorks = true
        assert(ok, err)
        assertTrue(SIM.chatContains("mouse-look for turning"), "no fallback message: " .. SIM.lastChat(3))
        assertTrue(SIM.chatContains("Mouse calibrated"), "did not calibrate: " .. SIM.lastChat(3))
        local x, y, z = feet()
        assertTrue(x == 15 and z == 9, string.format("ended at %d %d %d", x, y, z))
    end)

    test("DLL: renders path lines and HUD status", function()
        setup()
        SIM.command("#goto 30 64 0")
        SIM.run(1500)
        assertTrue((SIM.lines3d or 0) > 5, "no 3D lines: " .. tostring(SIM.lines3d))
        assertTrue(SIM.status and SIM.status:find("Going to", 1, true), "no status: " .. tostring(SIM.status))
        SIM.command("#stop")
        SIM.run(500)
        assertTrue(SIM.status == nil, "status still shown after stop")
    end)

    test("DLL: hotbar comes straight from the inventory", function()
        setup({ hotbar = { [0] = { name = "iron_pickaxe" }, [5] = { name = "water_bucket" } } })
        SIM.command("#hotbar")
        assertTrue(SIM.chatContains("6:water_bucket"), SIM.lastChat(1))
    end)

    -- runs fn with some SIM flags changed, restoring them afterwards
    local function withFlags(flags, fn)
        local old = {}
        for k, v in pairs(flags) do old[k] = SIM[k] SIM[k] = v end
        local ok, err = pcall(fn)
        for k in pairs(flags) do SIM[k] = old[k] end
        assert(ok, err)
    end

    test("DLL: works when the game tick hook is dead", function()
        withFlags({ tickHookWorks = false }, function()
            setup()
            SIM.command("#goto 20 64 5")
            SIM.run(30000, idleAfter)
            local x, y, z = feet()
            assertTrue(x == 20 and z == 5, string.format("ended at %d %d %d", x, y, z))
            SIM.command("#debug")
            assertTrue(SIM.chatContains("bot ticks from: frame"), "debug output: " .. SIM.lastChat(6))
        end)
    end)

    test("DLL: switches to keys when the movement hook is dead", function()
        withFlags({ moveHookFires = false }, function()
            setup()
            SIM.command("#goto 20 64 5")
            SIM.run(30000, idleAfter)
            assertTrue(SIM.chatContains("switching to pressing your movement keys"), "no switch: " .. SIM.lastChat(3))
            assertTrue(SIM.inputMode == "keys", "input mode " .. tostring(SIM.inputMode))
            local x, y, z = feet()
            assertTrue(x == 20 and z == 5, string.format("ended at %d %d %d", x, y, z))
            assertTrue(SIM.moveKeys and SIM.moveKeys[1] == 87 and SIM.moveKeys[5] == 0x20 and SIM.moveKeys[7] == 0xA2,
                "move keys not sent")
        end)
    end)

    test("DLL: switches to keys when the game ignores the hook", function()
        withFlags({ moveHookWorks = false }, function()
            setup()
            SIM.command("#goto 20 64 5")
            SIM.run(30000, idleAfter)
            assertTrue(SIM.chatContains("switching to pressing your movement keys"), "no switch: " .. SIM.lastChat(3))
            local x, y, z = feet()
            assertTrue(x == 20 and z == 5, string.format("ended at %d %d %d", x, y, z))
        end)
    end)

    test("DLL: hook that works is kept (no false switch)", function()
        setup()
        -- walk into a wall-free path, then get blocked briefly: must stay on the hook
        SIM.command("#goto 25 64 0")
        SIM.run(30000, idleAfter)
        assertTrue(not SIM.chatContains("switching to pressing"), "switched for no reason")
        assertTrue(SIM.inputMode == "hook", "mode " .. tostring(SIM.inputMode))
    end)

    test("DLL: notices rotation that doesn't reach the camera", function()
        withFlags({ rotationCosmetic = true }, function()
            setup({ calibrated = false })
            SIM.command("#goto 30 64 12")
            SIM.run(60000, idleAfter)
            assertTrue(SIM.chatContains("not walking the way"), "no rotation switch: " .. SIM.lastChat(4))
            assertTrue(SIM.chatContains("Mouse calibrated"), "did not calibrate: " .. SIM.lastChat(3))
            local x, y, z = feet()
            assertTrue(x == 30 and z == 12, string.format("ended at %d %d %d", x, y, z))
        end)
    end)

    test("DLL: ghost blocks are tinted with their block colour + HUD look-at", function()
        local pal = { "minecraft:air", "minecraft:oak_planks", "minecraft:red_wool" }
        local bin = NB.makeLitematic({ { name = "L", pos = { 0, 0, 0 }, size = { 3, 2, 3 }, palette = pal,
            fn = function(x, y, z) if y == 1 then return 2 end return 1 end } })
        setup({ files = { ["Baritone/schematics/g.litematic"] = bin } })
        SIM.command("#lm load g 2 64 0")
        SIM.run(1500)
        assertTrue(SIM.boxes3d >= 18, "ghost boxes: " .. tostring(SIM.boxes3d))
        local E = BARITONE_EXPOSE
        local plank = E.K.blockColor("oak_planks")
        local wool = E.K.blockColor("red_wool")
        assertTrue(plank[1] ~= wool[1] or plank[2] ~= wool[2], "colours should differ")
        local sawPlank, sawWool, filled = false, false, false
        local d = SIM.boxData
        for i = 1, #d, 11 do
            if d[i + 6] == plank[1] and d[i + 7] == plank[2] and d[i + 8] == plank[3] then sawPlank = true end
            if d[i + 6] == wool[1] and d[i + 7] == wool[2] and d[i + 8] == wool[3] then sawWool = true end
            if d[i + 10] > 0 then filled = true end
        end
        assertTrue(sawPlank and sawWool and filled, "ghost colours not sent")
        -- look at the ghost block in front: (2,64,0) is oak_planks, missing
        SIM.player.x, SIM.player.y, SIM.player.z = 0.5, 64, 0.5
        SIM.player.yaw, SIM.player.pitch = -90, 30
        SIM.run(500)
        assertTrue(SIM.status and SIM.status:find("Schematic: oak_planks (missing)", 1, true), "HUD: " .. tostring(SIM.status))
    end)

    test("DLL: big schematic stays fast", function()
        local pal = { "minecraft:air", "minecraft:stone", "minecraft:glass", "minecraft:oak_planks" }
        local bin = NB.makeLitematic({ { name = "L", pos = { 0, 0, 0 }, size = { 48, 24, 48 }, palette = pal,
            fn = function(x, y, z) return 1 + (x + y + z) % 3 end } })
        setup({ files = { ["Baritone/schematics/big.litematic"] = bin }, hotbar = { [0] = { name = "iron_pickaxe" },
            [1] = { name = "stone", count = 64 }, [2] = { name = "glass", count = 64 }, [3] = { name = "oak_planks", count = 64 } } })
        SIM.command("#lm load big 3 64 3")
        SIM.run(8000, function() return SIM.chatContains("Loaded big") end)
        assertTrue(SIM.chatContains("Loaded big"), "not loaded: " .. SIM.lastChat(2))
        SIM.command("#lm build")
        -- worst frame while building (CPU time spent in the script per frame)
        local worst, total, frames = 0, 0, 0
        local frameFn = SIM.events.SetupAndRenderEvent
        local tickFn = SIM.events.TickEvent
        SIM.events.SetupAndRenderEvent = function()
            local t0 = os.clock()
            frameFn()
            local dt = os.clock() - t0
            worst = math.max(worst, dt)
            total, frames = total + dt, frames + 1
        end
        SIM.events.TickEvent = function()
            local t0 = os.clock()
            tickFn()
            local dt = os.clock() - t0
            worst = math.max(worst, dt)
            total = total + dt
        end
        SIM.run(20000)
        SIM.events.SetupAndRenderEvent, SIM.events.TickEvent = frameFn, tickFn
        local avg = total / math.max(1, frames)
        print(string.format("      big schematic: %d blocks, worst %.1f ms, avg %.2f ms per frame, placed %d",
            #BARITONE_EXPOSE.LM.targets, worst * 1000, avg * 1000, SIM.placed))
        assertTrue(SIM.placed > 10, "didn't build: placed " .. SIM.placed .. " " .. SIM.lastChat(3))
        assertTrue(worst < 0.060, string.format("a frame took %.1f ms", worst * 1000))
        assertTrue(avg < 0.004, string.format("average %.2f ms per frame", avg * 1000))
    end)
end

local pass, fail = 0, 0
for _, r in ipairs(results) do if r.ok then pass = pass + 1 else fail = fail + 1 end end
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
