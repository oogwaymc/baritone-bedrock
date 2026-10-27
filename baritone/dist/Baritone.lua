--[[
  Baritone for Bedrock
  ------------------------------------------------------------------
  Runs inside Baritone.dll (embedded Lua, native game access) or, as a
  fallback, as a Flarial Lua module driven by BaritoneHelper.exe.

  Original Flarial module notes:
  ------------------------------------------------------------------
  Pathfinding bot for Minecraft: Bedrock Edition (Windows), modelled on
  Baritone for Java. Runs inside Flarial's injected client as a Lua
  module and drives the game with real keyboard/mouse input through the
  companion app BaritoneHelper.exe (Flarial scripts cannot press keys).

  Chat:   #help   #goto x y z   #mine diamond_ore   #follow Steve
          #build house   #farm   #elytra x z   #stop
  Backup: .b <command>  (works even if your Flarial build does not pass
          chat messages to scripts)

  Files (in %LOCALAPPDATA%\Flarial\Client\Baritone\):
    settings.txt, waypoints.txt, farm_*.txt, schematics\, ipc.txt, helper.txt
]]

name = "Baritone"
description = "Baritone-style pathfinding bot. Type #help in chat. Needs BaritoneHelper.exe running."
author = "Bedrock Baritone"
debug = false

local VERSION = "1.1.0"
local DIR = "Baritone"
-- true inside Baritone.dll: input, rotation, inventory and rendering are native
local NATIVE = type(rawget(_G, "native")) == "table" and type(native.setInput) == "function"
local Bot = {}          -- filled in later (forward declaration)

-- =====================================================================
-- Utilities
-- =====================================================================
local floor, ceil, abs, sqrt, min, max = math.floor, math.ceil, math.abs, math.sqrt, math.min, math.max
local sin, cos, atan, PI = math.sin, math.cos, math.atan, math.pi
local DEG, RAD = 180 / math.pi, math.pi / 180
local tinsert, tremove, tconcat, tsort = table.insert, table.remove, table.concat, table.sort
local fmt = string.format
local INF = math.huge

local U = {}

function U.now()
    local ok, t = pcall(util.time)
    if ok and type(t) == "number" then return t end
    return os.clock() * 1000
end

-- "minecraft:Stone[foo=bar]" -> "stone"
function U.bare(n)
    if n == nil then return "air" end
    n = tostring(n)
    local b = n:find("[", 1, true)
    if b then n = n:sub(1, b - 1) end
    local c = n:find(":", 1, true)
    if c then n = n:sub(c + 1) end
    n = n:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", "_")
    if n == "" then return "air" end
    return n
end

function U.wrap180(a)
    a = (a + 180) % 360
    return a - 180
end

function U.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function U.round(v, d)
    local m = 10 ^ (d or 0)
    return floor(v * m + 0.5) / m
end

function U.words(s)
    local t = {}
    for w in tostring(s):gmatch("%S+") do t[#t + 1] = w end
    return t
end

function U.splitList(s)
    local t = {}
    for w in tostring(s or ""):gmatch("[^,%s]+") do t[#t + 1] = U.bare(w) end
    return t
end

function U.toSet(list)
    local s = {}
    for _, v in ipairs(list) do s[v] = true end
    return s
end

function U.trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

-- Integer block key. x,z in [-2^24, 2^24), y in [-1024, 1023].
function U.key(x, y, z)
    return ((x + 16777216) * 2048 + (y + 1024)) * 33554432 + (z + 16777216)
end

function U.unkey(k)
    local z = k % 33554432 - 16777216
    local t = k // 33554432
    local y = t % 2048 - 1024
    local x = t // 2048 - 16777216
    return x, y, z
end

function U.ffloor(v) return floor(v) end

function U.dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return sqrt(dx * dx + dy * dy + dz * dz)
end

function U.dist2(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return sqrt(dx * dx + dz * dz)
end

-- Java/Bedrock yaw convention: yaw 0 = +Z (south), 90 = -X (west), -90 = +X (east), 180 = -Z
function U.yawTo(fx, fz, tx, tz)
    return U.wrap180(-atan(tx - fx, tz - fz) * DEG)
end

function U.pitchTo(fx, fy, fz, tx, ty, tz)
    local h = U.dist2(fx, fz, tx, tz)
    return -atan(ty - fy, h) * DEG
end

function U.dirFromYaw(yaw)
    local r = yaw * RAD
    return -sin(r), cos(r)
end

function U.fmtPos(x, y, z)
    if z == nil then return fmt("%d, %d", x, y) end
    return fmt("%d, %d, %d", x, y, z)
end

local CHAT_PREFIX = "\194\167d[Baritone]\194\167r "
function U.chat(msg)
    local text = CHAT_PREFIX .. tostring(msg)
    local ok = pcall(client.displayLocalMessage, text)
    if not ok then pcall(print, text) end
end

function U.notify(msg)
    pcall(client.notify, "Baritone: " .. tostring(msg))
end

function U.log(msg)
    pcall(log, "[Baritone] " .. tostring(msg))
end

-- Safe file helpers. Flarial's fs.writeFile appends on some builds, so we
-- always remove the file first: the result is correct either way.
function U.writeFile(path, content)
    pcall(fs.remove, path)
    local ok, res = pcall(fs.writeFile, path, content)
    return ok and res ~= false
end

function U.readFile(path)
    local okE, ex = pcall(fs.exists, path)
    if not okE or not ex then return nil end
    local ok, data = pcall(fs.readFile, path)
    if ok and type(data) == "string" then return data end
    return nil
end

function U.ensureDir(path)
    local okE, ex = pcall(fs.exists, path)
    if okE and ex then return true end
    local ok = pcall(fs.create, path)
    return ok
end

function U.listDir(path)
    local ok, t = pcall(fs.listDirectory, path)
    if ok and type(t) == "table" then return t end
    return {}
end

function U.basename(p)
    p = tostring(p):gsub("\\", "/")
    return p:match("([^/]+)$") or p
end

-- Lightweight binary heap keyed on node.f
local Heap = {}
Heap.__index = Heap
function Heap.new() return setmetatable({ n = 0 }, Heap) end
function Heap:push(node)
    local n = self.n + 1
    self.n = n
    self[n] = node
    node.hi = n
    self:up(n)
end
function Heap:up(i)
    local node = self[i]
    local f = node.f
    while i > 1 do
        local p = i // 2
        local pn = self[p]
        if pn.f <= f then break end
        self[i] = pn
        pn.hi = i
        i = p
    end
    self[i] = node
    node.hi = i
end
function Heap:pop()
    local n = self.n
    if n == 0 then return nil end
    local top = self[1]
    local last = self[n]
    self[n] = nil
    n = n - 1
    self.n = n
    top.hi = 0
    if n > 0 then
        local i = 1
        local f = last.f
        while true do
            local l = i * 2
            if l > n then break end
            local r = l + 1
            local c = l
            if r <= n and self[r].f < self[l].f then c = r end
            local cn = self[c]
            if cn.f >= f then break end
            self[i] = cn
            cn.hi = i
            i = c
        end
        self[i] = last
        last.hi = i
    end
    return top
end

-- =====================================================================
-- Settings (Baritone-style names; saved to Baritone/settings.txt)
-- =====================================================================
local S = {}
local SDEF = {}      -- ordered list of definitions
local SBYLOW = {}    -- lowercase name -> definition

local function defSetting(name, typ, default, desc)
    local d = { name = name, type = typ, default = default, desc = desc }
    SDEF[#SDEF + 1] = d
    SBYLOW[name:lower()] = d
    S[name] = default
end

-- Chat / control
defSetting("prefix", "string", "#", "Chat command prefix")
defSetting("chatControl", "bool", true, "Handle prefixed chat messages as commands (never sent to the server)")
defSetting("chatDebug", "bool", false, "Print extra debug messages in chat")
defSetting("echoCommands", "bool", true, "Echo the command you typed back to you")

-- Pathing behaviour
defSetting("allowBreak", "bool", true, "Allow breaking blocks while pathing")
defSetting("allowPlace", "bool", true, "Allow placing blocks (bridging / pillaring) while pathing")
defSetting("allowSprint", "bool", true, "Allow sprinting")
defSetting("allowDownward", "bool", true, "Allow mining straight down")
defSetting("allowDiagonal", "bool", true, "Allow diagonal walking")
defSetting("allowWaterBucketFall", "bool", true, "Allow long falls when a water bucket is in the hotbar")
defSetting("allowSwimming", "bool", true, "Allow paths through water")
defSetting("maxFallHeightNoWater", "int", 3, "Max fall without a water bucket")
defSetting("maxFallHeightBucket", "int", 20, "Max fall with a water bucket")
defSetting("acceptableThrowawayItems", "list",
    "dirt,cobblestone,netherrack,stone,cobbled_deepslate,andesite,diorite,granite,tuff,blackstone,end_stone,deepslate",
    "Blocks the bot may use for bridging / pillaring")
defSetting("blocksToAvoid", "list", "", "Blocks the bot must never walk through")
defSetting("blocksToAvoidBreaking", "list",
    "crafting_table,furnace,lit_furnace,chest,trapped_chest,ender_chest,barrel,beacon,bed,enchanting_table,anvil,brewing_stand",
    "Blocks the bot must never break")
defSetting("blockBreakAdditionalPenalty", "float", 2, "Extra path cost (ticks) per block broken")
defSetting("blockPlacementPenalty", "float", 20, "Extra path cost (ticks) per block placed")
defSetting("costHeuristic", "float", 5, "A* heuristic weight (Baritone uses 3.563; higher = faster search, slightly longer paths)")
defSetting("primaryTimeoutMS", "int", 1500, "CPU time before accepting a partial path")
defSetting("failureTimeoutMS", "int", 5000, "CPU time before giving up on a path")
defSetting("pathTimeBudgetMS", "int", 10, "Max path-search time per frame (ms)")
defSetting("maxPathNodes", "int", 30000, "Max nodes explored per path search")
defSetting("autoTool", "bool", true, "Switch to the best tool in the hotbar when breaking")
defSetting("sprintMinHunger", "int", 7, "Do not sprint below this hunger")
defSetting("rotationSpeed", "float", 540, "Max camera turn speed (degrees per second)")
defSetting("rotationMode", "string", "set", "DLL only: 'set' writes the rotation directly, 'turn' uses the game's mouse-look (needs #calibrate)")
defSetting("walkPitch", "float", 12, "Camera pitch while walking")

-- Rendering
defSetting("renderPath", "bool", true, "Draw the current path")
defSetting("renderGoal", "bool", true, "Draw the goal")
defSetting("renderSelectionBoxes", "bool", true, "Draw mining / building targets")
defSetting("renderHud", "bool", true, "Show the status line")
defSetting("colorCurrentPath", "color", "255,40,40", "Path colour")
defSetting("colorGoalBox", "color", "40,255,40", "Goal colour")
defSetting("colorMineTarget", "color", "0,200,255", "Mining target colour")
defSetting("pathThickness", "float", 2.5, "Path line thickness")

-- Mining
defSetting("mineScanRadius", "int", 24, "Horizontal scan radius for #mine")
defSetting("mineScanHeight", "int", 20, "Vertical scan range for #mine (each direction)")
defSetting("mineScanBlocksPerFrame", "int", 4000, "Scan speed (blocks checked per frame)")
defSetting("mineCollectDrops", "bool", true, "Walk over mined blocks to pick up drops")
defSetting("exploreForBlocks", "bool", true, "Tunnel to explore when no target blocks are known")
defSetting("mineDeepslateVariants", "bool", true, "#mine x_ore also mines deepslate_x_ore")

-- Follow
defSetting("followRadius", "float", 3, "How close #follow stays")

-- Farm
defSetting("farmRange", "int", 24, "Radius #farm works in")
defSetting("farmGrowMinutes", "float", 20, "Minutes after planting before a crop counts as grown")

-- Build / Litematica
defSetting("buildInLayers", "bool", true, "Build one layer at a time, bottom up")
defSetting("buildBreakWrong", "bool", true, "Break blocks that do not match the schematic")
defSetting("buildClearAir", "bool", false, "Also clear blocks where the schematic has air")
defSetting("buildIgnoreMissingItems", "bool", false, "Skip blocks you have no item for instead of pausing")
defSetting("buildReach", "float", 4.5, "Reach used for placing and breaking")
defSetting("litematicaRender", "bool", true, "Draw the loaded schematic as ghost blocks")
defSetting("litematicaRenderRadius", "int", 10, "Ghost block render radius")
defSetting("litematicaMaxBoxes", "int", 250, "Max ghost boxes drawn per frame")

-- Elytra
defSetting("elytraCruiseHeight", "int", 40, "Cruise altitude above takeoff point / terrain")
defSetting("elytraMinSpeed", "float", 0.9, "Use a firework below this speed (blocks/tick)")
defSetting("elytraFireworkDelayMS", "int", 1800, "Minimum time between fireworks")
defSetting("elytraLandDistance", "int", 40, "Start descending this far from the goal")
defSetting("elytraAutoLand", "bool", true, "Land automatically at the goal")

-- Safety
defSetting("fallGuard", "bool", true, "Auto water-bucket when falling too far (even when idle)")
defSetting("stopOnLowHealth", "int", 6, "Stop all processes below this health (0 = off)")

-- Keys (must match your Minecraft key bindings)
defSetting("keyForward", "string", "W", "Forward key")
defSetting("keyBack", "string", "S", "Back key")
defSetting("keyLeft", "string", "A", "Strafe-left key")
defSetting("keyRight", "string", "D", "Strafe-right key")
defSetting("keyJump", "string", "SPACE", "Jump key")
defSetting("keySneak", "string", "LSHIFT", "Sneak key")
defSetting("keySprint", "string", "LCONTROL", "Sprint key")

-- Calibration (filled in by #calibrate)
defSetting("mouseYawPerPixel", "float", 0, "Degrees of yaw per mouse pixel (0 = not calibrated)")
defSetting("mousePitchPerPixel", "float", 0, "Degrees of pitch per mouse pixel (0 = not calibrated)")

local SETTINGS_FILE = DIR .. "/settings.txt"
local Settings = {}

function Settings.parseValue(d, raw)
    raw = U.trim(raw)
    if d.type == "bool" then
        local r = raw:lower()
        if r == "true" or r == "1" or r == "on" or r == "yes" then return true end
        if r == "false" or r == "0" or r == "off" or r == "no" then return false end
        return nil, "expected true/false"
    elseif d.type == "int" then
        local n = tonumber(raw)
        if not n then return nil, "expected a whole number" end
        return floor(n)
    elseif d.type == "float" then
        local n = tonumber(raw)
        if not n then return nil, "expected a number" end
        return n
    elseif d.type == "color" then
        local r, g, b = raw:match("^(%d+)%s*,%s*(%d+)%s*,%s*(%d+)$")
        if not r then return nil, "expected r,g,b (0-255)" end
        return fmt("%d,%d,%d", U.clamp(tonumber(r), 0, 255), U.clamp(tonumber(g), 0, 255), U.clamp(tonumber(b), 0, 255))
    elseif d.type == "list" then
        local items = U.splitList(raw)
        return tconcat(items, ",")
    else
        return raw
    end
end

function Settings.toString(d, v)
    if v == nil then v = S[d.name] end
    if d.type == "float" then
        if v == floor(v) then return tostring(floor(v)) end
        return tostring(U.round(v, 4))
    end
    return tostring(v)
end

function Settings.isModified(d)
    return S[d.name] ~= d.default
end

function Settings.save()
    local lines = { "# Baritone for Bedrock settings (" .. VERSION .. ")" }
    for _, d in ipairs(SDEF) do
        if Settings.isModified(d) then
            lines[#lines + 1] = d.name .. "=" .. Settings.toString(d)
        end
    end
    U.ensureDir(DIR)
    U.writeFile(SETTINGS_FILE, tconcat(lines, "\n") .. "\n")
end

function Settings.load()
    local data = U.readFile(SETTINGS_FILE)
    if not data then return end
    for line in data:gmatch("[^\r\n]+") do
        if not line:match("^%s*#") then
            local k, v = line:match("^%s*([%w_]+)%s*=(.*)$")
            if k then
                local d = SBYLOW[k:lower()]
                if d then
                    local val = Settings.parseValue(d, v)
                    if val ~= nil then S[d.name] = val end
                end
            end
        end
    end
end

function Settings.find(nameLow)
    return SBYLOW[(nameLow or ""):lower()]
end

function Settings.color(name, alpha)
    local r, g, b = tostring(S[name]):match("(%d+),(%d+),(%d+)")
    return { tonumber(r) or 255, tonumber(g) or 255, tonumber(b) or 255, alpha or 255 }
end

-- cached list-type settings as sets
local SetCache = {}
function Settings.set(name)
    local raw = S[name]
    local c = SetCache[name]
    if c and c.raw == raw then return c.set end
    c = { raw = raw, set = U.toSet(U.splitList(raw)) }
    SetCache[name] = c
    return c.set
end

-- =====================================================================
-- Block knowledge (Bedrock block ids, without the "minecraft:" prefix)
-- =====================================================================
local K = {}

local AIR = U.toSet({ "air", "cave_air", "void_air", "structure_void" })
local WATER = U.toSet({ "water", "flowing_water", "bubble_column" })
local LAVA = U.toSet({ "lava", "flowing_lava" })

-- Never walk into / stand on these
local AVOID = U.toSet({
    "lava", "flowing_lava", "fire", "soul_fire", "magma", "cactus", "sweet_berry_bush",
    "powder_snow", "wither_rose", "campfire", "soul_campfire", "web", "cobweb",
    "pointed_dripstone", "end_portal", "portal", "end_gateway", "sculk_shrieker",
})

-- Blocks you can walk through
local PASSABLE = U.toSet({
    "short_grass", "tall_grass", "tallgrass", "fern", "large_fern", "deadbush", "dead_bush",
    "seagrass", "tall_seagrass", "kelp", "kelp_plant", "reeds", "sugar_cane", "snow_layer",
    "torch", "soul_torch", "redstone_torch", "unlit_redstone_torch", "copper_torch", "lever",
    "tripwire", "trip_wire", "tripwire_hook", "redstone_wire", "rail", "golden_rail",
    "detector_rail", "activator_rail", "dandelion", "poppy", "blue_orchid", "allium",
    "azure_bluet", "oxeye_daisy", "cornflower", "lily_of_the_valley", "torchflower",
    "sunflower", "lilac", "rose_bush", "peony", "pink_petals", "wildflowers", "leaf_litter",
    "cactus_flower", "short_dry_grass", "tall_dry_grass", "firefly_bush", "bush", "glow_lichen",
    "sculk_vein", "hanging_roots", "spore_blossom", "crimson_roots", "warped_roots",
    "nether_sprouts", "crimson_fungus", "warped_fungus", "brown_mushroom", "red_mushroom",
    "wheat", "carrots", "potatoes", "beetroot", "melon_stem", "pumpkin_stem", "nether_wart",
    "torchflower_crop", "pitcher_crop", "pitcher_plant", "vine", "weeping_vines",
    "twisting_vines", "cave_vines", "cave_vines_body_with_berries", "cave_vines_head_with_berries",
    "ladder", "scaffolding", "unpowered_repeater", "powered_repeater", "unpowered_comparator",
    "powered_comparator", "standing_sign", "wall_sign", "standing_banner", "wall_banner",
    "frog_spawn", "waterlily", "small_dripleaf_block", "light_block", "moss_carpet",
    "pale_moss_carpet", "pale_hanging_moss", "resin_clump", "string", "button",
})

-- 1.5 block tall or "door-like" blocks: obstacles that cannot be stepped onto
local function isTallName(n)
    if n:sub(-6) == "_fence" or n:sub(-11) == "_fence_gate" or n == "fence" then return true end
    if n:sub(-5) == "_wall" then return true end
    if n:sub(-5) == "_door" or n:sub(-9) == "_trapdoor" or n == "border_block" then return true end
    if n == "iron_bars" or n:sub(-5) == "_pane" or n == "glass_pane" then return true end
    return false
end

local FALLING = U.toSet({
    "sand", "red_sand", "gravel", "suspicious_sand", "suspicious_gravel", "anvil",
    "chipped_anvil", "damaged_anvil", "dragon_egg",
})

local UNBREAKABLE = U.toSet({
    "bedrock", "barrier", "end_portal_frame", "end_portal", "portal", "command_block",
    "repeating_command_block", "chain_command_block", "structure_block", "jigsaw", "deny",
    "allow", "border_block", "light_block", "end_gateway", "reinforced_deepslate",
})

local classCache = {}
-- class: 0 air, 1 passable, 2 water, 3 lava/avoid, 4 solid, 5 tall solid
local C_AIR, C_PASS, C_WATER, C_AVOID, C_SOLID, C_TALL = 0, 1, 2, 3, 4, 5
K.C_AIR, K.C_PASS, K.C_WATER, K.C_AVOID, K.C_SOLID, K.C_TALL = C_AIR, C_PASS, C_WATER, C_AVOID, C_SOLID, C_TALL

local function endsWith(s, suf) return s:sub(-#suf) == suf end

local function classify(n)
    if AIR[n] or n:sub(1, 12) == "light_block_" then return C_AIR end
    if WATER[n] then return C_WATER end
    if AVOID[n] then return C_AVOID end
    if PASSABLE[n] then return C_PASS end
    if endsWith(n, "_sapling") or endsWith(n, "_tulip") or endsWith(n, "_button")
        or endsWith(n, "_pressure_plate") or endsWith(n, "_carpet") or endsWith(n, "_sign")
        or endsWith(n, "_banner") or endsWith(n, "rail") or endsWith(n, "_torch")
        or endsWith(n, "_coral") or endsWith(n, "_coral_fan") or endsWith(n, "_coral_wall_fan")
        or endsWith(n, "_vines") or endsWith(n, "_propagule") or endsWith(n, "_petals")
        or endsWith(n, "_hanging_sign") or endsWith(n, "_wall_banner") or endsWith(n, "_candle")
        or n == "candle" or endsWith(n, "_mushroom") then
        if n ~= "mushroom_stem" then return C_PASS end
    end
    if endsWith(n, "_roots") and n ~= "mangrove_roots" and n ~= "muddy_mangrove_roots" then return C_PASS end
    if isTallName(n) then return C_TALL end
    return C_SOLID
end

local classAvoidRaw = nil
function K.class(n)
    local c = classCache[n]
    if c ~= nil then return c end
    -- (re)build when the blocksToAvoid setting changes
    if classAvoidRaw ~= S.blocksToAvoid then
        classAvoidRaw = S.blocksToAvoid
        classCache = {}
    end
    c = classify(n)
    if Settings.set("blocksToAvoid")[n] then c = C_AVOID end
    classCache[n] = c
    return c
end

-- call after settings change
function K.reset()
    classCache = {}
    classAvoidRaw = nil
end

function K.isAir(n) return K.class(n) == C_AIR end
function K.isWater(n) return K.class(n) == C_WATER end
function K.isLava(n) return LAVA[n] == true end
function K.isAvoid(n) return K.class(n) == C_AVOID end
-- can a player body occupy this cell?
function K.passable(n) local c = K.class(n) return c == C_AIR or c == C_PASS end
-- solid (has collision)
function K.solid(n) local c = K.class(n) return c == C_SOLID or c == C_TALL end
-- can stand on top of it?
function K.standable(n)
    if K.class(n) ~= C_SOLID then return false end
    if n == "magma" or n == "campfire" or n == "soul_campfire" then return false end
    return true
end
function K.isFalling(n) return FALLING[n] or endsWith(n, "_concrete_powder") end
function K.unbreakable(n)
    if UNBREAKABLE[n] then return true end
    local prot = Settings.set("blocksToAvoidBreaking")
    if prot[n] then return true end
    if endsWith(n, "shulker_box") or endsWith(n, "_bed") then return true end
    return false
end

-- ------------------------------------------------------------------
-- Hardness & tools (used for path costs and tool selection)
-- ------------------------------------------------------------------
local HARD = {
    stone = 1.5, cobblestone = 2, mossy_cobblestone = 2, deepslate = 3, cobbled_deepslate = 3.5,
    tuff = 1.5, calcite = 0.75, granite = 1.5, diorite = 1.5, andesite = 1.5, netherrack = 0.4,
    end_stone = 3, blackstone = 1.5, basalt = 1.25, smooth_basalt = 1.25, obsidian = 50,
    crying_obsidian = 50, ancient_debris = 30, dirt = 0.5, grass_block = 0.6, grass = 0.6,
    coarse_dirt = 0.5, podzol = 0.5, mycelium = 0.6, rooted_dirt = 0.5, mud = 0.5, sand = 0.5,
    red_sand = 0.5, gravel = 0.6, clay = 0.6, farmland = 0.6, grass_path = 0.65, dirt_path = 0.65,
    soul_sand = 0.5, soul_soil = 0.5, magma = 0.5, glowstone = 0.3, glass = 0.3, ice = 0.5,
    packed_ice = 0.5, blue_ice = 2.8, snow = 0.2, snow_layer = 0.1, sandstone = 0.8,
    red_sandstone = 0.8, terracotta = 1.25, hardened_clay = 1.25, iron_block = 5, gold_block = 3,
    diamond_block = 5, emerald_block = 5, bookshelf = 1.5, crafting_table = 2.5, pumpkin = 1,
    melon_block = 1, hay_block = 0.5, sponge = 0.6, bone_block = 2, prismarine = 1.5,
    amethyst_block = 1.5, dripstone_block = 1.5, moss_block = 0.1, sculk = 0.2, cactus = 0.4,
    bamboo = 1, reeds = 0, web = 4, chest = 2.5, barrel = 2.5,
}

local TOOL_SPEED = { wooden = 2, stone = 4, iron = 6, diamond = 8, netherite = 9, golden = 12, copper = 5 }
local TOOL_RANK = { wooden = 1, golden = 2, stone = 3, copper = 4, iron = 5, diamond = 6, netherite = 7 }

function K.hardness(n)
    local h = HARD[n]
    if h then return h end
    local c = K.class(n)
    if c == C_PASS or c == C_AIR then return 0 end
    if endsWith(n, "_ore") then
        if n:sub(1, 10) == "deepslate_" or n:sub(1, 14) == "lit_deepslate_" then return 4.5 end
        return 3
    end
    if endsWith(n, "_log") or endsWith(n, "_wood") or endsWith(n, "_stem") or endsWith(n, "_hyphae") then return 2 end
    if endsWith(n, "_planks") or endsWith(n, "_slab") or endsWith(n, "_stairs") then return 2 end
    if endsWith(n, "_leaves") then return 0.2 end
    if endsWith(n, "_wool") then return 0.8 end
    if endsWith(n, "_concrete") then return 1.8 end
    if endsWith(n, "_concrete_powder") then return 0.5 end
    if endsWith(n, "_terracotta") then return 1.4 end
    if endsWith(n, "_glass") then return 0.3 end
    if n:find("brick", 1, true) then return 2 end
    if n:find("copper", 1, true) then return 3 end
    if n:find("deepslate", 1, true) then return 3.5 end
    return 1.5
end

-- which tool category breaks this block fastest
function K.toolFor(n)
    if n:find("log", 1, true) or n:find("wood", 1, true) or n:find("planks", 1, true)
        or endsWith(n, "_stem") or n:find("hyphae", 1, true) or n == "crafting_table"
        or n == "bookshelf" or n == "chest" or n == "barrel" or n:find("fence", 1, true)
        or n == "pumpkin" or n == "melon_block" or n == "bamboo" or n:find("mushroom_block", 1, true)
        or n == "ladder" or n:find("_sign", 1, true) then
        return "axe"
    end
    if n:find("dirt", 1, true) or n == "grass_block" or n == "grass" or n:find("sand", 1, true) and not n:find("sandstone", 1, true)
        or n == "gravel" or n == "clay" or n:find("snow", 1, true) or n == "mud" or n == "soul_soil"
        or n == "farmland" or n == "grass_path" or n == "podzol" or n == "mycelium"
        or n:find("concrete_powder", 1, true) or n:find("suspicious", 1, true) then
        return "shovel"
    end
    if n:find("leaves", 1, true) or n == "hay_block" or n == "sculk" or n:find("moss", 1, true)
        or n == "sponge" or n == "wet_sponge" or n == "target" then
        return "hoe"
    end
    if n == "web" or n == "cobweb" then return "sword" end
    return "pickaxe"
end

-- blocks that drop nothing / break painfully slowly without the right tool
function K.needsTool(n)
    if K.toolFor(n) ~= "pickaxe" then return false end
    local h = K.hardness(n)
    return h >= 1
end

function K.toolMaterial(itemName)
    for mat in pairs(TOOL_SPEED) do
        if itemName:sub(1, #mat + 1) == mat .. "_" then return mat end
    end
    return nil
end

function K.itemToolType(itemName)
    if not itemName then return nil end
    if endsWith(itemName, "_pickaxe") then return "pickaxe" end
    if endsWith(itemName, "_axe") then return "axe" end
    if endsWith(itemName, "_shovel") then return "shovel" end
    if endsWith(itemName, "_hoe") then return "hoe" end
    if endsWith(itemName, "_sword") then return "sword" end
    if itemName == "shears" then return "shears" end
    return nil
end

function K.toolRank(itemName)
    local m = K.toolMaterial(itemName or "")
    return m and TOOL_RANK[m] or 0
end

function K.toolSpeed(itemName)
    local m = K.toolMaterial(itemName or "")
    return m and TOOL_SPEED[m] or 1
end

-- estimated ticks to break with a given held item
function K.breakTicks(n, itemName)
    local h = K.hardness(n)
    if h <= 0 then return 1 end
    local tool = K.toolFor(n)
    local held = K.itemToolType(itemName)
    if held == tool then
        return ceil(h * 30 / K.toolSpeed(itemName))
    end
    if K.needsTool(n) then return ceil(h * 100) end
    return ceil(h * 30)
end

-- ------------------------------------------------------------------
-- Block -> item needed to place it
-- ------------------------------------------------------------------
local BLOCK_TO_ITEM = {
    reeds = "sugar_cane", redstone_wire = "redstone", standing_sign = "oak_sign",
    wall_sign = "oak_sign", wheat = "wheat_seeds", carrots = "carrot", potatoes = "potato",
    beetroot = "beetroot_seeds", melon_stem = "melon_seeds", pumpkin_stem = "pumpkin_seeds",
    unpowered_repeater = "repeater", powered_repeater = "repeater",
    unpowered_comparator = "comparator", powered_comparator = "comparator",
    lit_furnace = "furnace", lit_smoker = "smoker", lit_blast_furnace = "blast_furnace",
    lit_redstone_lamp = "redstone_lamp", lit_redstone_ore = "redstone_ore",
    tripwire = "string", trip_wire = "string", cocoa = "cocoa_beans", standing_banner = "white_banner",
    wall_banner = "white_banner", unlit_redstone_torch = "redstone_torch", cave_vines = "glow_berries",
    torchflower_crop = "torchflower_seeds", pitcher_crop = "pitcher_pod", kelp_plant = "kelp",
    bubble_column = "water_bucket", flowing_water = "water_bucket", water = "water_bucket",
    lava = "lava_bucket", flowing_lava = "lava_bucket", powder_snow = "powder_snow_bucket",
    grass_block = "grass_block", farmland = "dirt", grass_path = "dirt", dirt_path = "dirt",
}

function K.itemForBlock(n)
    local m = BLOCK_TO_ITEM[n]
    if m then return m end
    if endsWith(n, "_double_slab") then return n:sub(1, -13) .. "_slab" end
    if endsWith(n, "_wall_sign") then return n:sub(1, -11) .. "_sign" end
    if endsWith(n, "_wall_hanging_sign") then return n:sub(1, -19) .. "_hanging_sign" end
    if endsWith(n, "_standing_sign") then return n:sub(1, -15) .. "_sign" end
    if endsWith(n, "_wall_banner") then return n:sub(1, -13) .. "_banner" end
    if endsWith(n, "_wall_fan") then return n:sub(1, -10) .. "_fan" end
    return n
end

-- Names that should count as "the same block" when checking a build
local EQUIV = {
    lit_furnace = "furnace", lit_smoker = "smoker", lit_blast_furnace = "blast_furnace",
    lit_redstone_lamp = "redstone_lamp", lit_redstone_ore = "redstone_ore",
    lit_deepslate_redstone_ore = "deepslate_redstone_ore", powered_repeater = "unpowered_repeater",
    powered_comparator = "unpowered_comparator", unlit_redstone_torch = "redstone_torch",
    flowing_water = "water", flowing_lava = "lava", grass = "grass_block", dirt_path = "grass_path",
    tallgrass = "short_grass", cobweb = "web", sugar_cane = "reeds", wall_sign = "standing_sign",
    wall_banner = "standing_banner", kelp_plant = "kelp",
}
function K.canon(n)
    n = EQUIV[n] or n
    if endsWith(n, "_double_slab") then n = n:sub(1, -13) .. "_slab" end
    return n
end

-- ------------------------------------------------------------------
-- Java -> Bedrock block names (for .litematic / .schem / .nbt files)
-- ------------------------------------------------------------------
local JAVA_TO_BEDROCK = {
    cave_air = "air", void_air = "air", structure_void = "structure_void",
    note_block = "noteblock", cobweb = "web", sugar_cane = "reeds", jack_o_lantern = "lit_pumpkin",
    magma_block = "magma", red_nether_bricks = "red_nether_brick", nether_bricks = "nether_brick",
    end_stone_bricks = "end_bricks", terracotta = "hardened_clay", snow_block = "snow",
    snow = "snow_layer", slime_block = "slime", spawner = "mob_spawner", wall_torch = "torch",
    soul_wall_torch = "soul_torch", redstone_wall_torch = "redstone_torch", repeater = "unpowered_repeater",
    comparator = "unpowered_comparator", oak_sign = "standing_sign", oak_wall_sign = "wall_sign",
    melon = "melon_block", bricks = "brick_block", dirt_path = "grass_path", grass = "short_grass",
    tall_seagrass = "tall_seagrass", lily_pad = "waterlily", nether_portal = "portal",
    moving_piston = "moving_block", piston_head = "piston_arm_collision", sticky_piston_head = "sticky_piston_arm_collision",
    tripwire = "trip_wire", powered_rail = "golden_rail", dead_bush = "deadbush",
    rose_bush = "rose_bush", sunflower = "sunflower", stone_stairs = "normal_stone_stairs",
    cobblestone_stairs = "stone_stairs", stone_slab = "normal_stone_slab", chipped_anvil = "chipped_anvil",
    quartz_pillar = "quartz_pillar", smooth_quartz = "smooth_quartz", light = "light_block",
    attached_melon_stem = "melon_stem", attached_pumpkin_stem = "pumpkin_stem",
    water = "water", lava = "lava", bubble_column = "bubble_column",
}

function K.javaToBedrock(jn)
    local n = U.bare(jn)
    local m = JAVA_TO_BEDROCK[n]
    if m then return m end
    if endsWith(n, "_wall_sign") and n ~= "wall_sign" then return n:sub(1, -11) .. "_wall_sign" end
    if endsWith(n, "_wall_banner") then return "wall_banner" end
    if endsWith(n, "_banner") then return "standing_banner" end
    if endsWith(n, "_bed") then return "bed" end
    if endsWith(n, "_wall_head") or endsWith(n, "_head") or endsWith(n, "_skull") then return "skull" end
    if n:sub(1, 7) == "potted_" then return "flower_pot" end
    return n
end

-- =====================================================================
-- World access (cached) & player state
-- =====================================================================
local W = { cache = {}, count = 0, chunkLoaded = {}, chunkTime = 0, dim = "overworld" }
local getBlockRaw = function(x, y, z) return world.getBlock(x, y, z) end

function W.fresh(x, y, z)
    local ok, n = pcall(getBlockRaw, x, y, z)
    if not ok then return "air" end
    n = U.bare(n)
    local k = U.key(x, y, z)
    if W.cache[k] == nil then W.count = W.count + 1 end
    W.cache[k] = n
    return n
end

function W.get(x, y, z)
    local k = ((x + 16777216) * 2048 + (y + 1024)) * 33554432 + (z + 16777216)
    local n = W.cache[k]
    if n then return n end
    local ok, raw = pcall(getBlockRaw, x, y, z)
    n = ok and U.bare(raw) or "air"
    W.cache[k] = n
    W.count = W.count + 1
    if W.count > 400000 then W.clear() end
    return n
end

function W.set(x, y, z, n)
    W.cache[U.key(x, y, z)] = n
end

function W.clear()
    W.cache = {}
    W.count = 0
end

function W.updateDimension()
    local ok, d = pcall(player.dimension)
    d = ok and tostring(d):lower() or "overworld"
    local nd = "overworld"
    if d:find("nether", 1, true) then nd = "nether"
    elseif d:find("end", 1, true) then nd = "end" end
    if nd ~= W.dim then
        W.dim = nd
        W.clear()
        W.chunkLoaded = {}
    end
end

-- Unloaded chunks read as air. A column with nothing solid at any of a few
-- probe heights is treated as not loaded (or void, which we avoid anyway).
function W.loaded(x, z, nearY)
    if W.dim == "end" then return true end
    local ck = U.key(x // 16, 0, z // 16)
    local now = W.nowMs or U.now()
    local e = W.chunkLoaded[ck]
    if e and now - e.t < 4000 then return e.v end
    local cx, cz = (x // 16) * 16 + 8, (z // 16) * 16 + 8
    local v = false
    local probes
    if W.dim == "nether" then probes = { 0, 127, 32 } else probes = { -64, 0, 62 } end
    for _, py in ipairs(probes) do
        if not K.isAir(W.fresh(cx, py, cz)) then v = true break end
    end
    if not v and nearY then
        for dy = -3, 1 do
            if not K.isAir(W.fresh(cx, nearY + dy, cz)) then v = true break end
        end
    end
    W.chunkLoaded[ck] = { t = now, v = v }
    return v
end

-- ------------------------------------------------------------------
-- Player snapshot (refreshed every frame from SetupAndRenderEvent)
-- ------------------------------------------------------------------
local P = {
    x = 0, y = 0, z = 0, fx = 0, fy = 0, fz = 0, yaw = 0, pitch = 0,
    vx = 0, vy = 0, vz = 0, grounded = true, health = 20, hunger = 20, gamemode = 0,
    slot = 0, mainhand = nil, offhand = nil, chest = nil, valid = false, screen = "hud_screen",
    inGame = false, fallStartY = nil, name = "",
}

local function callOr(fn, default, ...)
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    return default
end

function P.refresh()
    local inGame = callOr(client.isInGame, true)
    P.inGame = inGame ~= false
    local x, y, z = callOr(player.position, 0)
    if type(x) ~= "number" then x, y, z = 0, 0, 0 end
    P.valid = P.inGame and not (x == 0 and y == 0 and z == 0)
    P.x, P.y, P.z = x, y or 0, z or 0
    P.fx, P.fy, P.fz = floor(P.x), floor(P.y + 0.001), floor(P.z)
    local rot = callOr(player.rotation, nil)
    if type(rot) == "table" then
        P.pitch = tonumber(rot.x) or 0
        P.yaw = U.wrap180(tonumber(rot.y) or 0)
    end
    local vx, vy, vz = callOr(player.velocity, 0)
    P.vx, P.vy, P.vz = tonumber(vx) or 0, tonumber(vy) or 0, tonumber(vz) or 0
    if type(player.grounded) == "function" then
        P.grounded = callOr(player.grounded, true) == true
    else
        P.grounded = P.computeGrounded()
    end
    P.health = tonumber(callOr(player.health, 20)) or 20
    P.hunger = tonumber(callOr(player.hunger, 20)) or 20
    P.gamemode = tonumber(callOr(player.gamemode, 0)) or 0
    P.slot = tonumber(callOr(player.selectedSlot, 0)) or 0
    local mh = callOr(player.mainhand, nil)
    if type(mh) == "table" and mh.name and mh.name ~= "empty" then P.mainhand = U.bare(mh.name) else P.mainhand = nil end
    local ar = callOr(player.armor, nil)
    if type(ar) == "table" and type(ar.chestplate) == "table" and ar.chestplate.name ~= "empty" then
        P.chest = U.bare(ar.chestplate.name)
    else
        P.chest = nil
    end
    P.screen = tostring(callOr(client.getScreenName, "hud_screen") or "hud_screen")
    if P.name == "" then P.name = tostring(callOr(player.name, "") or "") end
    -- fall tracking
    if P.grounded or K.isWater(W.fresh(P.fx, P.fy, P.fz)) then
        P.fallStartY = nil
    elseif P.fallStartY == nil or P.y > P.fallStartY then
        P.fallStartY = P.y
    end
end

-- Standing on something? (used when the host doesn't report it)
function P.computeGrounded()
    if P.vy > 0.08 or P.vy < -0.12 then return false end -- rising or still falling
    local by = floor(P.y - 0.03)
    if P.y - by > 1.06 then return false end
    for _, o in ipairs({ { 0.299, 0.299 }, { -0.299, 0.299 }, { 0.299, -0.299 }, { -0.299, -0.299 } }) do
        local n = W.fresh(floor(P.x + o[1]), by, floor(P.z + o[2]))
        if K.solid(n) then return true end
    end
    return false
end

function P.eye() return P.x, P.y + 1.62, P.z end
function P.horizSpeed() return sqrt(P.vx * P.vx + P.vz * P.vz) end
function P.inHud()
    local s = P.screen:lower()
    return s == "hud_screen" or s == "" or s:find("hud", 1, true) ~= nil
end
function P.creative() return P.gamemode == 1 end

-- Raycast from the crosshair (Flarial API). Returns hit table or nil.
function W.raycast(dist)
    local ok, hit = pcall(world.raycast, dist or 5)
    if ok and type(hit) == "table" then
        hit.bx = tonumber(hit.blockX)
        hit.by = tonumber(hit.blockY)
        hit.bz = tonumber(hit.blockZ)
        hit.fid = tonumber(hit.faceId)
        if hit.fid == nil and hit.face ~= nil then
            local fm = { down = 0, up = 1, north = 2, south = 3, west = 4, east = 5 }
            hit.fid = tonumber(hit.face) or fm[tostring(hit.face):lower()]
        end
        if hit.bx then return hit end
    end
    return nil
end

-- Bedrock FacingID: 0 down, 1 up, 2 north(-z), 3 south(+z), 4 west(-x), 5 east(+x)
local FACE_DIR = {
    [0] = { 0, -1, 0 }, [1] = { 0, 1, 0 }, [2] = { 0, 0, -1 }, [3] = { 0, 0, 1 }, [4] = { -1, 0, 0 }, [5] = { 1, 0, 0 },
}
function W.faceFromDir(dx, dy, dz)
    if dy == -1 then return 0 end
    if dy == 1 then return 1 end
    if dz == -1 then return 2 end
    if dz == 1 then return 3 end
    if dx == -1 then return 4 end
    return 5
end
W.FACE_DIR = FACE_DIR

-- first solid block below (x,y,z) scanning down `range` blocks; returns y of that block
function W.groundBelow(x, y, z, range)
    for dy = 0, range do
        local n = W.fresh(x, y - dy, z)
        if K.isWater(n) then return y - dy, n end
        if not K.passable(n) then return y - dy, n end
    end
    return nil
end

-- =====================================================================
-- Goals
-- =====================================================================
local G = {}
local SQRT2 = math.sqrt(2)

local function hXZ(dx, dz)
    dx, dz = abs(dx), abs(dz)
    local diag = min(dx, dz)
    local straight = max(dx, dz) - diag
    return (straight + diag * SQRT2) * S.costHeuristic
end

local function hY(dy) return abs(dy) * 4 end

function G.block(gx, gy, gz)
    return {
        kind = "block", x = gx, y = gy, z = gz,
        desc = fmt("GoalBlock{%s}", U.fmtPos(gx, gy, gz)),
        isGoal = function(x, y, z) return x == gx and y == gy and z == gz end,
        h = function(x, y, z) return hXZ(gx - x, gz - z) + hY(gy - y) end,
    }
end

function G.xz(gx, gz)
    return {
        kind = "xz", x = gx, z = gz,
        desc = fmt("GoalXZ{%s}", U.fmtPos(gx, gz)),
        isGoal = function(x, y, z) return x == gx and z == gz end,
        h = function(x, y, z) return hXZ(gx - x, gz - z) end,
    }
end

function G.y(gy)
    return {
        kind = "y", y = gy,
        desc = fmt("GoalYLevel{%d}", gy),
        isGoal = function(x, y, z) return y == gy end,
        h = function(x, y, z) return hY(gy - y) end,
    }
end

function G.near(gx, gy, gz, r)
    local r2 = r * r
    return {
        kind = "near", x = gx, y = gy, z = gz, r = r,
        desc = fmt("GoalNear{%s, r=%s}", U.fmtPos(gx, gy, gz), tostring(r)),
        isGoal = function(x, y, z)
            local dx, dy, dz = x - gx, y - gy, z - gz
            return dx * dx + dy * dy + dz * dz <= r2
        end,
        h = function(x, y, z)
            local d = U.dist3(x, y, z, gx, gy, gz)
            return max(0, d - r) * S.costHeuristic
        end,
    }
end

-- within r blocks horizontally of (gx,gz) and within ytol of gy
function G.nearXZ(gx, gy, gz, r, ytol)
    local r2 = r * r
    return {
        kind = "near", x = gx, y = gy, z = gz, r = r,
        desc = fmt("GoalNear{%s, r=%s}", U.fmtPos(gx, gy, gz), tostring(r)),
        isGoal = function(x, y, z)
            local dx, dz = x - gx, z - gz
            return dx * dx + dz * dz <= r2 and abs(y - gy) <= ytol
        end,
        h = function(x, y, z)
            local d = U.dist2(x, z, gx, gz)
            return max(0, d - r) * S.costHeuristic + max(0, abs(y - gy) - ytol) * 4
        end,
    }
end

-- stand next to a block (feet or head face-adjacent), e.g. to mine it
function G.getToBlock(bx, by, bz)
    local function adj(x, y, z)
        local m = abs(x - bx) + abs(y - by) + abs(z - bz)
        return m == 1
    end
    return {
        kind = "block", x = bx, y = by, z = bz,
        desc = fmt("GoalGetToBlock{%s}", U.fmtPos(bx, by, bz)),
        isGoal = function(x, y, z) return adj(x, y, z) or adj(x, y + 1, z) end,
        h = function(x, y, z) return max(0, hXZ(bx - x, bz - z) + hY(by - y) - S.costHeuristic) end,
    }
end

-- be within `reach` of a block centre, without standing inside it
function G.reach(tx, ty, tz, reach)
    local cx, cy, cz = tx + 0.5, ty + 0.5, tz + 0.5
    local r2 = reach * reach
    return {
        kind = "block", x = tx, y = ty, z = tz,
        desc = fmt("GoalReach{%s}", U.fmtPos(tx, ty, tz)),
        isGoal = function(x, y, z)
            if x == tx and z == tz and (y == ty or y + 1 == ty) then return false end
            local dx, dy, dz = x + 0.5 - cx, y + 1.62 - cy, z + 0.5 - cz
            return dx * dx + dy * dy + dz * dz <= r2
        end,
        h = function(x, y, z)
            local d = U.dist3(x + 0.5, y + 1.62, z + 0.5, cx, cy, cz)
            return max(0, d - reach) * S.costHeuristic
        end,
    }
end

function G.composite(list)
    if #list == 1 then return list[1] end
    return {
        kind = "composite", list = list,
        desc = fmt("GoalComposite{%d goals}", #list),
        isGoal = function(x, y, z)
            for i = 1, #list do if list[i].isGoal(x, y, z) then return true end end
            return false
        end,
        h = function(x, y, z)
            local best = INF
            for i = 1, #list do
                local v = list[i].h(x, y, z)
                if v < best then best = v end
            end
            return best
        end,
    }
end

-- =====================================================================
-- A* pathfinder (incremental, time-sliced across frames)
-- =====================================================================
local PF = {}
local COST = { WALK = 4.633, SPRINT = 3.564, SNEAK = 15.385, WATER = 9.091, JUMP = 2.5, PILLAR = 11 }
PF.COST = COST

local FALLT = { [0] = 0 }
do
    local vy, d, t = 0, 0, 0
    for n = 1, 400 do
        while d < n do
            vy = (vy - 0.08) * 0.98
            d = d - vy
            t = t + 1
        end
        FALLT[n] = t
    end
end
PF.FALLT = FALLT

-- move kinds
local M_TRAVERSE, M_DIAGONAL, M_ASCEND, M_DESCEND, M_FALL, M_PILLAR, M_DOWNWARD, M_SWIM_UP, M_SWIM_DOWN =
    1, 2, 3, 4, 5, 6, 7, 8, 9
PF.M = {
    TRAVERSE = M_TRAVERSE, DIAGONAL = M_DIAGONAL, ASCEND = M_ASCEND, DESCEND = M_DESCEND,
    FALL = M_FALL, PILLAR = M_PILLAR, DOWNWARD = M_DOWNWARD, SWIM_UP = M_SWIM_UP, SWIM_DOWN = M_SWIM_DOWN,
}
PF.MNAME = { "traverse", "diagonal", "ascend", "descend", "fall", "pillar", "downward", "swim-up", "swim-down" }

local ADJ5 = { { 0, 1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
local ADJ6 = { { 0, -1, 0 }, { 0, 1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
PF.ADJ6 = ADJ6
local DIRS4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local DIAG4 = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

-- cost of making a body cell passable: 0 = already, INF = impossible
local C_AIR_, C_PASS_, C_WATER_, C_AVOID_ = K.C_AIR, K.C_PASS, K.C_WATER, K.C_AVOID
local cellCostSlow
local function cellCost(ctx, x, y, z)
    local n = W.get(x, y, z)
    local c = K.class(n)
    if c == C_AIR_ or c == C_PASS_ then return 0 end
    if c == C_WATER_ then return ctx.allowSwim and 0 or INF end
    if c == C_AVOID_ then return INF end
    if not ctx.allowBreak then return INF end
    local k = ((x + 16777216) * 2048 + (y + 1024)) * 33554432 + (z + 16777216)
    local cc = ctx.cc
    if not cc then cc = {} ctx.cc = cc end
    local v = cc[k]
    if v == nil then
        v = cellCostSlow(ctx, x, y, z, n)
        cc[k] = v
    end
    return v
end
cellCostSlow = function(ctx, x, y, z, n)
    if K.unbreakable(n) then return INF end
    if ctx.noBreak and ctx.noBreak(U.key(x, y, z), n) then return INF end
    for i = 1, 5 do
        local d = ADJ5[i]
        local an = W.get(x + d[1], y + d[2], z + d[3])
        if K.isWater(an) or K.isLava(an) then return INF end
    end
    local t = ctx.breakTicks(n)
    local above = W.get(x, y + 1, z)
    if K.isFalling(above) then t = t + ctx.breakTicks(above) + 20 end
    return t + ctx.breakPenalty
end
PF.cellCost = cellCost

-- virtKey: a block the path has already planned to place (counts as solid)
local function hasSupport(x, y, z, virtKey)
    for i = 1, 6 do
        local d = ADJ6[i]
        local sx, sy, sz = x + d[1], y + d[2], z + d[3]
        if K.solid(W.get(sx, sy, sz)) then return true end
        if virtKey and U.key(sx, sy, sz) == virtKey then return true end
    end
    return false
end
PF.hasSupport = hasSupport

local function canPlaceAt(ctx, x, y, z, virtKey)
    if not ctx.canPlace then return false end
    if not K.passable(W.get(x, y, z)) then return false end
    if ctx.noPlace and ctx.noPlace(U.key(x, y, z)) then return false end
    return hasSupport(x, y, z, virtKey)
end

-- emit(nx, ny, nz, cost, kind, placeFlag)
function PF.expand(ctx, node, emit)
    local x, y, z = node.x, node.y, node.z
    local feetHere = W.get(x, y, z)
    local inWater = K.isWater(feetHere)
    local floorHere = W.get(x, y - 1, z)
    local walk = ctx.walkCost
    -- if we got here by placing our own floor, that block will exist
    local virt = nil
    if node.place and (node.kind == M_TRAVERSE or node.kind == M_ASCEND or node.kind == M_PILLAR) then
        virt = U.key(x, y - 1, z)
    end
    local floorSolid = K.solid(floorHere) or virt ~= nil

    for i = 1, 4 do
        local d = DIRS4[i]
        local nx, nz = x + d[1], z + d[2]
        if ctx.loaded(nx, nz, y) then
            local cF = cellCost(ctx, nx, y, nz)
            local cH = (cF < INF) and cellCost(ctx, nx, y + 1, nz) or INF
            if cF < INF and cH < INF then
                local destFeet = W.get(nx, y, nz)
                local fN = W.get(nx, y - 1, nz)
                local destWater = K.isWater(destFeet)
                -- TRAVERSE
                if destWater then
                    local extra = K.isWater(W.get(nx, y + 1, nz)) and 6 or 0
                    emit(nx, y, nz, COST.WATER + cF + cH + extra, M_TRAVERSE, false)
                elseif K.standable(fN) then
                    emit(nx, y, nz, (inWater and COST.WATER or walk) + cF + cH, M_TRAVERSE, false)
                elseif not inWater and floorSolid and canPlaceAt(ctx, nx, y - 1, nz, virt) then
                    emit(nx, y, nz, COST.SNEAK + ctx.placePenalty + cF + cH, M_TRAVERSE, true)
                end
                -- DESCEND / FALL (walk off the edge)
                if not destWater and (K.passable(fN) or K.isWater(fN)) and (not inWater or floorSolid) then
                    local scanMax = 64
                    for dd = 1, scanMax do
                        local cy = y - dd
                        local n = W.get(nx, cy, nz)
                        local c = K.class(n)
                        if c == K.C_WATER then
                            if ctx.allowSwim then
                                emit(nx, cy, nz, walk + FALLT[dd] + cF + cH, dd == 1 and M_DESCEND or M_FALL, false)
                            end
                            break
                        elseif c == K.C_AIR or c == K.C_PASS then
                            -- keep falling
                        elseif c == K.C_AVOID then
                            break
                        else
                            if K.standable(n) then
                                local h = dd - 1
                                if h >= 1 then
                                    if h <= ctx.maxFall then
                                        emit(nx, cy + 1, nz, walk + FALLT[h] + cF + cH, h == 1 and M_DESCEND or M_FALL, false)
                                    elseif h <= ctx.maxFallBucket and ctx.hasBucket then
                                        emit(nx, cy + 1, nz, walk + FALLT[h] + cF + cH + ctx.placePenalty * 2, M_FALL, false)
                                    end
                                end
                            end
                            break
                        end
                        if cy < -64 then break end
                    end
                end
            end
            -- ASCEND
            local cUp = cellCost(ctx, x, y + 2, z)
            if cUp < INF then
                local fN = W.get(nx, y, nz)
                local cDF = cellCost(ctx, nx, y + 1, nz)
                local cDH = (cDF < INF) and cellCost(ctx, nx, y + 2, nz) or INF
                if cDF < INF and cDH < INF and not K.isWater(W.get(nx, y + 1, nz)) then
                    local base = walk + COST.JUMP + cUp + cDF + cDH
                    if K.standable(fN) then
                        emit(nx, y + 1, nz, base, M_ASCEND, false)
                    elseif not inWater and floorSolid and canPlaceAt(ctx, nx, y, nz, virt) then
                        emit(nx, y + 1, nz, base + ctx.placePenalty, M_ASCEND, true)
                    end
                end
            end
        end
    end

    -- DIAGONAL
    if ctx.allowDiagonal then
        for i = 1, 4 do
            local d = DIAG4[i]
            local nx, nz = x + d[1], z + d[2]
            if ctx.loaded(nx, nz, y) then
                local df, dh = W.get(nx, y, nz), W.get(nx, y + 1, nz)
                if K.passable(df) and K.passable(dh) and K.standable(W.get(nx, y - 1, nz)) and not inWater then
                    local a1, a2 = W.get(x + d[1], y, z), W.get(x + d[1], y + 1, z)
                    local b1, b2 = W.get(x, y, z + d[2]), W.get(x, y + 1, z + d[2])
                    local aOk = K.passable(a1) and K.passable(a2)
                    local bOk = K.passable(b1) and K.passable(b2)
                    local danger = K.isAvoid(a1) or K.isAvoid(b1) or K.isAvoid(a2) or K.isAvoid(b2)
                        or K.isAvoid(W.get(x + d[1], y - 1, z)) or K.isAvoid(W.get(x, y - 1, z + d[2]))
                    if (aOk or bOk) and not danger then
                        local c = walk * SQRT2
                        if not (aOk and bOk) then c = c * 1.5 end
                        emit(nx, y, nz, c, M_DIAGONAL, false)
                    end
                end
            end
        end
    end

    -- PILLAR (jump + place under yourself)
    if ctx.canPlace and not inWater and floorSolid and K.passable(feetHere) then
        local cUp = cellCost(ctx, x, y + 2, z)
        if cUp < INF and not (ctx.noPlace and ctx.noPlace(U.key(x, y, z))) then
            emit(x, y + 1, z, COST.PILLAR + ctx.placePenalty + cUp, M_PILLAR, true)
        end
    end

    -- DOWNWARD (mine the block you stand on)
    if ctx.allowDownward and not inWater then
        local cB = cellCost(ctx, x, y - 1, z)
        if cB > 0 and cB < INF then
            local below = W.get(x, y - 2, z)
            if K.standable(below) then
                emit(x, y - 1, z, cB + FALLT[1], M_DOWNWARD, false)
            end
        end
    end

    -- swimming
    if inWater and ctx.allowSwim then
        local up = W.get(x, y + 1, z)
        if K.isWater(up) then
            emit(x, y + 1, z, COST.WATER * 1.2, M_SWIM_UP, false)
        end
        local dn = W.get(x, y - 1, z)
        if K.isWater(dn) then
            emit(x, y - 1, z, COST.WATER * 1.2, M_SWIM_DOWN, false)
        end
    end
end

-- cells a move must clear, and cells it must fill
function PF.describe(from, to)
    local kind = to.kind
    local x, y, z = from.x, from.y, from.z
    local nx, nz = to.x, to.z
    local clear, place = {}, {}
    if kind == M_TRAVERSE then
        clear = { { nx, y + 1, nz }, { nx, y, nz } }
        if to.place then place = { { nx, y - 1, nz } } end
    elseif kind == M_ASCEND then
        clear = { { x, y + 2, z }, { nx, y + 2, nz }, { nx, y + 1, nz } }
        if to.place then place = { { nx, y, nz } } end
    elseif kind == M_DESCEND or kind == M_FALL then
        clear = { { nx, y + 1, nz }, { nx, y, nz } }
    elseif kind == M_PILLAR then
        clear = { { x, y + 2, z } }
        place = { { x, y, z } }
    elseif kind == M_DOWNWARD then
        clear = { { x, y - 1, z } }
    end
    return clear, place
end

-- ------------------------------------------------------------------
-- Search object
-- ------------------------------------------------------------------
function PF.new(sx, sy, sz, goal, ctx)
    local s = {
        goal = goal, ctx = ctx, open = Heap.new(), nodes = {}, cpu = 0, expanded = 0,
        status = "running", bestH = INF, best = nil, sx = sx, sy = sy, sz = sz,
    }
    local h = goal.h(sx, sy, sz)
    local start = { x = sx, y = sy, z = sz, g = 0, h = h, f = h, hi = 0 }
    s.start = start
    s.nodes[U.key(sx, sy, sz)] = start
    s.open:push(start)
    return s
end

local function buildPath(s, node)
    local list = {}
    while node do
        list[#list + 1] = node
        node = node.parent
    end
    local path = {}
    for i = #list, 1, -1 do
        local n = list[i]
        path[#path + 1] = { x = n.x, y = n.y, z = n.z, kind = n.kind, place = n.place, g = n.g }
    end
    return path
end

function PF.step(s, budgetMs)
    if s.status ~= "running" then return s.status end
    local t0 = U.now()
    local goal, ctx, open, nodes = s.goal, s.ctx, s.open, s.nodes
    local cur
    local maxNodes = ctx.maxNodes or S.maxPathNodes
    local function emit(nx, ny, nz, cost, kind, place)
        if cost >= INF then return end
        local k = U.key(nx, ny, nz)
        if ctx.avoid and ctx.avoid[k] then return end
        local g = cur.g + cost
        local nd = nodes[k]
        if nd == nil then
            local h = goal.h(nx, ny, nz)
            nd = { x = nx, y = ny, z = nz, g = g, h = h, f = g + h, parent = cur, kind = kind, place = place, hi = 0 }
            nodes[k] = nd
            open:push(nd)
        elseif not nd.closed and g < nd.g - 1e-6 then
            nd.g = g
            nd.f = g + nd.h
            nd.parent = cur
            nd.kind = kind
            nd.place = place
            if nd.hi and nd.hi > 0 then open:up(nd.hi) else open:push(nd) end
        end
    end
    local iter = 0
    while true do
        cur = open:pop()
        if cur == nil then
            s.status = "exhausted"
            break
        end
        if goal.isGoal(cur.x, cur.y, cur.z) then
            s.path = buildPath(s, cur)
            s.status = "found"
            break
        end
        cur.closed = true
        s.expanded = s.expanded + 1
        if cur ~= s.start and cur.h < s.bestH then
            s.bestH = cur.h
            s.best = cur
        end
        PF.expand(ctx, cur, emit)
        iter = iter + 1
        if s.expanded >= maxNodes then
            s.status = "limit"
            break
        end
        -- time budget, plus an iteration cap in case the clock is coarse
        if iter >= 300 or (iter % 24 == 0 and U.now() - t0 >= budgetMs) then break end
    end
    s.cpu = s.cpu + (U.now() - t0)
    if s.status == "running" then
        if s.cpu >= S.failureTimeoutMS then
            s.status = "limit"
        elseif s.cpu >= S.primaryTimeoutMS and s.best and s.start.h - s.bestH > S.costHeuristic * 4 then
            s.status = "limit"
        end
    end
    if s.status == "exhausted" or s.status == "limit" then
        if s.best and s.start.h - s.bestH > 0.5 then
            s.path = buildPath(s, s.best)
            s.status = "partial"
        else
            s.status = "failed"
        end
    end
    return s.status
end

-- =====================================================================
-- Input: what the bot wants pressed this frame. BaritoneHelper.exe reads
-- it from Baritone/ipc.txt and presses the real keys / moves the mouse.
-- =====================================================================
local IN = {
    hold = {}, lmb = false, rmbHold = false, rmbPulse = 0, slotPulse = 0, slotReq = -1, slotTime = 0,
    tyaw = nil, tpitch = nil, accX = 0, accY = 0, seq = 0, lastWrite = 0, active = false,
    offWrites = 0, rawDx = 0, rawDy = 0, lastClick = 0,
}
local IPC_FILE = DIR .. "/ipc.txt"
local HELPER_FILE = DIR .. "/helper.txt"

local KEYSET = { forward = "keyForward", back = "keyBack", left = "keyLeft", right = "keyRight",
    jump = "keyJump", sneak = "keySneak", sprint = "keySprint" }

function IN.clear()
    IN.hold = {}
    IN.lmb = false
    IN.rmbHold = false
    IN.tyaw, IN.tpitch = nil, nil
end

function IN.press(k) IN.hold[k] = true end
function IN.release(k) IN.hold[k] = nil end

function IN.look(yaw, pitch)
    IN.tyaw = U.wrap180(yaw)
    IN.tpitch = U.clamp(pitch or P.pitch, -89.9, 89.9)
end

function IN.lookAt(x, y, z)
    local ex, ey, ez = P.eye()
    IN.tyaw = U.yawTo(ex, ez, x, z)
    IN.tpitch = U.clamp(U.pitchTo(ex, ey, ez, x, y, z), -89.9, 89.9)
end

function IN.aimError()
    if not IN.tyaw then return 0 end
    return max(abs(U.wrap180(IN.tyaw - P.yaw)), abs((IN.tpitch or P.pitch) - P.pitch))
end

function IN.click()
    IN.rmbPulse = IN.rmbPulse + 1
    IN.lastClick = U.now()
end

function IN.select(slot)
    if slot == nil then return end
    local now = U.now()
    if P.slot == slot then IN.slotReq = slot return end
    if IN.slotReq ~= slot or now - IN.slotTime > 500 then
        IN.slotReq = slot
        IN.slotPulse = IN.slotPulse + 1
        IN.slotTime = now
    end
end

-- raw mouse move (used by calibration), sent in small steps over several
-- frames so pointer acceleration treats it like normal bot movement
IN.rawQueue = {}
function IN.rawMove(dx, dy)
    local steps = max(1, ceil(max(abs(dx), abs(dy)) / 12))
    local sx, sy = dx / steps, dy / steps
    local accX, accY = 0, 0
    for i = 1, steps do
        local nx, ny = U.round(sx * i), U.round(sy * i)
        IN.rawQueue[#IN.rawQueue + 1] = { nx - accX, ny - accY }
        accX, accY = nx, ny
    end
end

function IN.rawPending() return #IN.rawQueue > 0 end

function IN.turnMode()
    return NATIVE and S.rotationMode == "turn"
end

function IN.calibrated()
    if NATIVE and not IN.turnMode() then return true end -- rotation is written directly
    return S.mouseYawPerPixel ~= 0 and S.mousePitchPerPixel ~= 0
end

-- ------------------------------------------------------------------
-- Helper connection
-- ------------------------------------------------------------------
local Helper = { beat = nil, beatT = -1e9, focus = NATIVE, panic = nil, version = "?", lastRead = 0, connected = NATIVE }

function Helper.poll(now)
    if NATIVE then
        Helper.connected = true
        Helper.version = tostring(native.version or "dll")
        local okF, f = pcall(native.focused)
        Helper.focus = (not okF) or f == true
        local okP, pc = pcall(native.panicCount)
        pc = okP and tostring(pc) or "0"
        if Helper.panic ~= nil and pc ~= Helper.panic and Helper.onPanic then
            Helper.panic = pc
            Helper.onPanic()
        end
        Helper.panic = pc
        return
    end
    if now - Helper.lastRead < 300 then return end
    Helper.lastRead = now
    local data = U.readFile(HELPER_FILE)
    if not data then
        Helper.connected = now - Helper.beatT < 2000
        return
    end
    local beat, focus, panic, ver = data:match("H1|(%d+)|(%d)|(%d+)|([^|]*)|E")
    if beat then
        if beat ~= Helper.beat then
            Helper.beat = beat
            Helper.beatT = now
        end
        Helper.focus = focus == "1"
        Helper.version = ver
        if Helper.panic ~= nil and panic ~= Helper.panic then
            Helper.panic = panic
            if Helper.onPanic then Helper.onPanic() end
        end
        Helper.panic = panic
    end
    Helper.connected = now - Helper.beatT < 2000
end

-- ------------------------------------------------------------------
-- Per-frame: turn the camera toward the target and write the IPC record
-- ------------------------------------------------------------------
-- ------------------------------------------------------------------
-- Native (DLL) output: movement through the game's input state, rotation
-- written directly (or through the game's mouse-look), clicks / hotbar keys
-- ------------------------------------------------------------------
IN.nat = { rmbSent = 0, slotSent = 0, lastActive = false, setFails = 0, lastSetYaw = nil, lastSetPrevYaw = nil }

function IN.nativeRotate(now, dt, active)
    local nat = IN.nat
    -- did last frame's direct write stick? (if not, fall back to mouse-look turning)
    if nat.lastSetYaw then
        local moved = abs(U.wrap180(P.yaw - nat.lastSetPrevYaw))
        local wanted = abs(U.wrap180(nat.lastSetYaw - nat.lastSetPrevYaw))
        if wanted > 0.5 and moved < 0.05 then
            nat.setFails = nat.setFails + 1
            if nat.setFails >= 20 and S.rotationMode == "set" then
                S.rotationMode = "turn"
                S.mouseYawPerPixel, S.mousePitchPerPixel = 0, 0
                Settings.save()
                U.chat("\194\167eDirect rotation doesn't work on this version - switching to mouse-look turning (calibrating).")
                if Bot.makeCalibrate then Bot.queuePre(Bot.makeCalibrate()) end
            end
        elseif moved >= 0.05 then
            nat.setFails = 0
        end
        nat.lastSetYaw = nil
    end
    if not active or not IN.tyaw then return end
    local ey = U.wrap180(IN.tyaw - P.yaw)
    local ep = (IN.tpitch or P.pitch) - P.pitch
    local k = 1 - math.exp(-dt / 0.06)
    local maxStep = S.rotationSpeed * dt
    local sy = U.clamp(ey * k, -maxStep, maxStep)
    local sp = U.clamp(ep * k, -maxStep, maxStep)
    if abs(ey) < 0.1 then sy = ey end
    if abs(ep) < 0.1 then sp = ep end
    if sy == 0 and sp == 0 then return end
    if IN.turnMode() then
        if not IN.calibrated() then return end
        pcall(native.turn, sy / S.mouseYawPerPixel, sp / S.mousePitchPerPixel)
    else
        local ny, np = U.wrap180(P.yaw + sy), U.clamp(P.pitch + sp, -89.9, 89.9)
        pcall(native.setRotation, np, ny)
        nat.lastSetYaw, nat.lastSetPrevYaw = ny, P.yaw
    end
end

function IN.nativeFrame(now, dt, active)
    local nat = IN.nat
    IN.nativeRotate(now, dt, active)
    -- calibration moves (turn mode only)
    if #IN.rawQueue > 0 then
        local st = tremove(IN.rawQueue, 1)
        pcall(native.turn, st[1], st[2])
    end
    if active then
        local h = IN.hold
        pcall(native.setInput, true, h.forward == true, h.back == true, h.left == true, h.right == true,
            h.jump == true, h.sneak == true, h.sprint == true)
        pcall(native.setButtons, IN.lmb == true, IN.rmbHold == true)
        if IN.rmbPulse ~= nat.rmbSent then
            nat.rmbSent = IN.rmbPulse
            pcall(native.click, 2)
        end
        if IN.slotPulse ~= nat.slotSent then
            nat.slotSent = IN.slotPulse
            if IN.slotReq and IN.slotReq >= 0 then pcall(native.selectSlot, IN.slotReq) end
        end
    else
        nat.rmbSent, nat.slotSent = IN.rmbPulse, IN.slotPulse
        if nat.lastActive or now - (nat.lastOff or 0) > 500 then
            nat.lastOff = now
            pcall(native.setInput, false)
            pcall(native.setButtons, false, false)
        end
    end
    nat.lastActive = active
    IN.active = active
end

function IN.frame(now, dt, active)
    if NATIVE then return IN.nativeFrame(now, dt, active) end
    local dx, dy = 0, 0
    if active and IN.tyaw and IN.calibrated() then
        local ey = U.wrap180(IN.tyaw - P.yaw)
        local ep = (IN.tpitch or P.pitch) - P.pitch
        local k = 1 - math.exp(-dt / 0.06)
        local maxStep = S.rotationSpeed * dt
        local sy = U.clamp(ey * k, -maxStep, maxStep)
        local sp = U.clamp(ep * k, -maxStep, maxStep)
        if abs(ey) < 0.15 then sy = 0 end
        if abs(ep) < 0.15 then sp = 0 end
        IN.accX = IN.accX + sy / S.mouseYawPerPixel
        IN.accY = IN.accY + sp / S.mousePitchPerPixel
    else
        IN.accX, IN.accY = 0, 0
    end
    if #IN.rawQueue > 0 and now - IN.lastWrite >= 8 then
        local st = tremove(IN.rawQueue, 1)
        IN.accX = IN.accX + st[1]
        IN.accY = IN.accY + st[2]
    end

    if not active then
        IN.accX, IN.accY = 0, 0
        if IN.active then IN.offWrites = 6 end
        IN.active = false
        if IN.offWrites > 0 and now - IN.lastWrite >= 30 then
            IN.offWrites = IN.offWrites - 1
            IN.write(now, false, 0, 0)
        end
        return
    end
    IN.active = true
    if now - IN.lastWrite < 8 then return end
    dx = IN.accX >= 0 and floor(IN.accX) or ceil(IN.accX)
    dy = IN.accY >= 0 and floor(IN.accY) or ceil(IN.accY)
    dx = U.clamp(dx, -400, 400)
    dy = U.clamp(dy, -400, 400)
    IN.accX = IN.accX - dx
    IN.accY = IN.accY - dy
    IN.write(now, true, dx, dy)
end

function IN.write(now, on, dx, dy)
    if NATIVE then
        if not on then
            pcall(native.setInput, false)
            pcall(native.setButtons, false, false)
        end
        return
    end
    IN.seq = IN.seq + 1
    IN.lastWrite = now
    local keys = {}
    if on then
        for k, settingName in pairs(KEYSET) do
            if IN.hold[k] then keys[#keys + 1] = tostring(S[settingName]):upper() end
        end
    end
    tsort(keys)
    local rec = fmt("B1|%d|%d|%s|%d|%d|%d|%d|%d|%d|%d|E\n",
        IN.seq, on and 1 or 0, (#keys > 0) and tconcat(keys, "+") or "-",
        (on and IN.lmb) and 1 or 0, (on and IN.rmbHold) and 1 or 0, IN.rmbPulse,
        IN.slotReq or -1, IN.slotPulse, dx, dy)
    U.writeFile(IPC_FILE, rec)
end

-- =====================================================================
-- Hotbar knowledge (Flarial only tells us the held item, so we learn the
-- hotbar by watching the selected slot, or by scanning slots 1-9)
-- =====================================================================
local HB = { items = {}, known = {} }

function HB.observe()
    if not P.valid then return end
    if NATIVE and type(player.hotbar) == "function" then
        local now = U.now()
        if HB.nextRead and now < HB.nextRead then return end
        HB.nextRead = now + 100
        local ok, t = pcall(player.hotbar)
        if ok and type(t) == "table" then
            for s = 0, 8 do
                local it = t[s]
                HB.items[s] = (type(it) == "string" and it ~= "" and it ~= "empty") and U.bare(it) or false
                HB.known[s] = true
            end
            return
        end
    end
    if IN.slotReq >= 0 and IN.slotReq ~= P.slot and U.now() - IN.slotTime < 300 then return end
    HB.items[P.slot] = P.mainhand or false
    HB.known[P.slot] = true
end

function HB.complete()
    for s = 0, 8 do if not HB.known[s] then return false end end
    return true
end

function HB.invalidate()
    if NATIVE and type(player.hotbar) == "function" then HB.nextRead = nil return end
    HB.known = {}
end

function HB.slotOf(name)
    for s = 0, 8 do if HB.items[s] == name then return s end end
    return nil
end

function HB.find(pred)
    for s = 0, 8 do
        local it = HB.items[s]
        if it and pred(it) then return s, it end
    end
    return nil
end

function HB.bestTool(cat)
    local bestS, bestR, bestN = nil, -1, nil
    for s = 0, 8 do
        local it = HB.items[s]
        if it and K.itemToolType(it) == cat then
            local r = K.toolRank(it)
            if r > bestR then bestS, bestR, bestN = s, r, it end
        end
    end
    return bestS, bestN
end

function HB.throwaway()
    local set = Settings.set("acceptableThrowawayItems")
    if P.mainhand and set[P.mainhand] then return P.slot, P.mainhand end
    return HB.find(function(it) return set[it] end)
end

function HB.has(name) return HB.slotOf(name) ~= nil end

function HB.list()
    local parts = {}
    for s = 0, 8 do
        local it = HB.items[s]
        local label = (not HB.known[s]) and "?" or (it or "-")
        parts[#parts + 1] = fmt("%d:%s", s + 1, label)
    end
    return tconcat(parts, "  ")
end

-- =====================================================================
-- Actions: break a block, place a block, pillar up. Each is a small state
-- machine called once per tick with a persistent state table `st`.
-- Return values: "running", "done", "failed", "noitem", "noface"
-- =====================================================================
local ACT = {}

-- Walk the voxel grid from the eye to (tx,ty,tz). Returns true when the first
-- solid block the ray enters is (bx,by,bz) (or nothing solid is in the way).
function ACT.lineClear(ex, ey, ez, tx, ty, tz, bx, by, bz, ix, iy, iz)
    local dx, dy, dz = tx - ex, ty - ey, tz - ez
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-6 then return true end
    dx, dy, dz = dx / len, dy / len, dz / len
    local x, y, z = floor(ex), floor(ey), floor(ez)
    local sx, sy, sz = dx > 0 and 1 or -1, dy > 0 and 1 or -1, dz > 0 and 1 or -1
    local function tmax(e, c, d)
        if d == 0 then return INF end
        if d > 0 then return (c + 1 - e) / d end
        return (e - c) / -d
    end
    local tx_, ty_, tz_ = tmax(ex, x, dx), tmax(ey, y, dy), tmax(ez, z, dz)
    local ddx = dx ~= 0 and 1 / abs(dx) or INF
    local ddy = dy ~= 0 and 1 / abs(dy) or INF
    local ddz = dz ~= 0 and 1 / abs(dz) or INF
    for _ = 1, 64 do
        local t
        if tx_ < ty_ and tx_ < tz_ then t = tx_ tx_ = tx_ + ddx x = x + sx
        elseif ty_ < tz_ then t = ty_ ty_ = ty_ + ddy y = y + sy
        else t = tz_ tz_ = tz_ + ddz z = z + sz end
        if t > len + 0.01 then return true end
        if x == bx and y == by and z == bz then return true end
        if not (x == ix and y == iy and z == iz) then
            local n = W.get(x, y, z)
            -- anything but air/water stops the crosshair (plants are selectable in Bedrock)
            if not (K.isAir(n) or K.isWater(n)) then return false end
        end
    end
    return true
end

-- points to try on a face: centre first, then inset corners
local FACE_OFFS = { { 0, 0 }, { 0.3, 0.3 }, { -0.3, 0.3 }, { 0.3, -0.3 }, { -0.3, -0.3 } }
local function facePoints(cx, cy, cz, d)
    local pts = {}
    for _, o in ipairs(FACE_OFFS) do
        if d[1] ~= 0 then pts[#pts + 1] = { cx, cy + o[1], cz + o[2] }
        elseif d[2] ~= 0 then pts[#pts + 1] = { cx + o[1], cy, cz + o[2] }
        else pts[#pts + 1] = { cx + o[1], cy + o[2], cz } end
    end
    return pts
end

-- a visible point on block (x,y,z) to aim at (for mining)
function ACT.aimPoint(x, y, z, ex, ey, ez)
    if not ex then ex, ey, ez = P.eye() end
    local best, bx, by, bz = INF, x + 0.5, y + 0.5, z + 0.5
    for i = 1, 6 do
        local d = PF.ADJ6[i]
        local fx, fy, fz = x + 0.5 + d[1] * 0.5, y + 0.5 + d[2] * 0.5, z + 0.5 + d[3] * 0.5
        local facing = (ex - fx) * d[1] + (ey - fy) * d[2] + (ez - fz) * d[3]
        if facing > 0 then
            local nb = W.get(x + d[1], y + d[2], z + d[3])
            if K.passable(nb) or K.isWater(nb) then
                local dist = U.dist3(ex, ey, ez, fx, fy, fz)
                if dist < best then
                    for _, pt in ipairs(facePoints(fx - d[1] * 0.02, fy - d[2] * 0.02, fz - d[3] * 0.02, d)) do
                        if ACT.lineClear(ex, ey, ez, pt[1], pt[2], pt[3], x, y, z) then
                            best, bx, by, bz = dist, pt[1], pt[2], pt[3]
                            break
                        end
                    end
                end
            end
        end
    end
    return bx, by, bz, best
end

function ACT.equipToolFor(n)
    if not S.autoTool then return end
    local cat = K.toolFor(n)
    local slot = HB.bestTool(cat)
    if slot then IN.select(slot) return end
    -- no right tool: avoid wasting a good tool's durability by switching to an empty hand / block
    local cur = P.mainhand
    if cur and K.itemToolType(cur) and K.itemToolType(cur) ~= cat then
        local empty = HB.find(function(it) return not K.itemToolType(it) end)
        if empty then IN.select(empty) end
    end
end

function ACT.mine(st, x, y, z)
    local n = W.fresh(x, y, z)
    -- done once the block is gone (crops/plants are passable, so compare names)
    if K.isAir(n) or K.isWater(n) then
        IN.lmb = false
        return "done"
    end
    if K.passable(n) then
        if (st.name and n ~= st.name) or (not st.name and not st.breakPlants) then
            IN.lmb = false
            return "done"
        end
    end
    local now = U.now()
    if not st.t0 then
        st.t0 = now
        st.miss = 0
        local ticks = K.breakTicks(n, P.mainhand)
        if P.creative() then ticks = 2 end
        st.budget = ticks * 50 * 3 + 4000
        st.name = n
    end
    if n ~= st.name then -- block changed (e.g. gravel fell): restart timer
        st.t0, st.name = now, n
    end
    if now - st.t0 > st.budget then
        IN.lmb = false
        return "failed"
    end
    ACT.equipToolFor(n)
    IN.clear()
    local ax, ay, az, dist = ACT.aimPoint(x, y, z)
    if dist == INF or dist > S.buildReach + 1 then
        IN.lookAt(x + 0.5, y + 0.5, z + 0.5)
    else
        IN.lookAt(ax, ay, az)
    end
    if P.creative() and st.clickedAt and now - st.clickedAt < 250 then
        return "running"
    end
    local hit = W.raycast(S.buildReach + 1)
    if hit and hit.bx == x and hit.by == y and hit.bz == z then
        IN.lmb = true
        st.miss = 0
        if P.creative() then st.clickedAt = now end
    else
        IN.lmb = false
        if IN.aimError() < 2 then
            st.miss = st.miss + 1
            -- something else is in the way: break it if allowed
            if hit and st.miss > 10 then
                local hn = W.fresh(hit.bx, hit.by, hit.bz)
                if K.solid(hn) and not K.unbreakable(hn) and S.allowBreak
                    and not (st.protect and st.protect(U.key(hit.bx, hit.by, hit.bz))) then
                    IN.lmb = true
                end
            end
            if st.miss > 80 then return "failed" end
        end
    end
    return "running"
end

-- Choose the face to click to place a block at (x,y,z).
-- Returns support block coords, face id, aim point; or nil.
function ACT.findPlaceFace(x, y, z, reach, ex, ey, ez, cached, exclude)
    if not ex then ex, ey, ez = P.eye() end
    local best
    for i = 1, 6 do
        local d = PF.ADJ6[i]
        local sx, sy, sz = x + d[1], y + d[2], z + d[3]
        local sn = cached and W.get(sx, sy, sz) or W.fresh(sx, sy, sz)
        if K.solid(sn) then
            -- face of the support block that points back at (x,y,z)
            local fx, fy, fz = x + 0.5 + d[1] * 0.5, y + 0.5 + d[2] * 0.5, z + 0.5 + d[3] * 0.5
            local facing = (ex - fx) * (-d[1]) + (ey - fy) * (-d[2]) + (ez - fz) * (-d[3])
            if facing > 0.05 then
                local dist = U.dist3(ex, ey, ez, fx, fy, fz)
                local score = dist + (d[2] == -1 and -0.5 or 0)
                if dist <= reach and (not best or score < best.score) then
                    for pi, pt in ipairs(facePoints(fx + d[1] * 0.02, fy + d[2] * 0.02, fz + d[3] * 0.02, d)) do
                        if not (exclude and exclude[i * 10 + pi])
                            and ACT.lineClear(ex, ey, ez, pt[1], pt[2], pt[3], sx, sy, sz, x, y, z) then
                            best = { sx = sx, sy = sy, sz = sz, face = W.faceFromDir(-d[1], -d[2], -d[3]),
                                ax = pt[1], ay = pt[2], az = pt[3], score = score, id = i * 10 + pi }
                            break
                        end
                    end
                end
            end
        end
    end
    return best
end

-- Goals: stand somewhere we can actually see a face to place against / mine
function G.placeAt(tx, ty, tz, reach)
    local base = G.reach(tx, ty, tz, reach)
    return {
        kind = "block", x = tx, y = ty, z = tz, desc = fmt("GoalPlace{%s}", U.fmtPos(tx, ty, tz)),
        h = base.h,
        isGoal = function(x, y, z)
            if not base.isGoal(x, y, z) then return false end
            return ACT.findPlaceFace(tx, ty, tz, reach, x + 0.5, y + 1.62, z + 0.5, true) ~= nil
        end,
    }
end

function G.breakAt(tx, ty, tz, reach)
    local base = G.reach(tx, ty, tz, reach)
    return {
        kind = "block", x = tx, y = ty, z = tz, desc = fmt("GoalBreak{%s}", U.fmtPos(tx, ty, tz)),
        h = base.h,
        isGoal = function(x, y, z)
            if not base.isGoal(x, y, z) then return false end
            local _, _, _, d = ACT.aimPoint(tx, ty, tz, x + 0.5, y + 1.62, z + 0.5)
            return d <= reach
        end,
    }
end

-- itemSel: item name (string) or predicate(itemName) -> bool
function ACT.place(st, x, y, z, itemSel, wantName)
    local n = W.fresh(x, y, z)
    if st.orig == nil then st.orig = n end
    -- placed: something solid appeared, or a different (passable) block such as a crop
    if not (K.passable(n) or K.isWater(n)) or (n ~= st.orig and not K.isAir(n) and not K.isWater(n)) then
        IN.rmbHold = false
        if wantName and K.canon(n) ~= K.canon(wantName) then return "wrong" end
        return "done"
    end
    local now = U.now()
    if not st.t0 then st.t0 = now st.clicks = 0 end
    if now - st.t0 > 9000 then return "failed" end
    local slot
    if type(itemSel) == "function" then slot = HB.find(itemSel) else slot = HB.slotOf(itemSel) end
    if not slot then return "noitem" end
    IN.select(slot)
    st.exclude = st.exclude or {}
    local f = ACT.findPlaceFace(x, y, z, S.buildReach, nil, nil, nil, false, st.exclude)
    if not f then
        if st.bridge then return ACT.bridgeCreep(st, x, y, z) end
        return "noface"
    end
    IN.clear()
    IN.press("sneak")
    IN.lookAt(f.ax, f.ay, f.az)
    if P.slot ~= slot then return "running" end
    local hit = W.raycast(S.buildReach + 0.5)
    local onSupport = hit and hit.bx == f.sx and hit.by == f.sy and hit.bz == f.sz and (hit.fid == nil or hit.fid == f.face)
    local onPlant = hit and hit.bx == x and hit.by == y and hit.bz == z and K.class(n) == K.C_PASS
    if onSupport or onPlant then
        st.missT = nil
        if not st.lastClick or now - st.lastClick > 350 then
            IN.click()
            st.lastClick = now
            st.clicks = st.clicks + 1
        end
    elseif IN.aimError() < 1.5 then
        -- aimed, but the crosshair lands on something else: try another point
        st.missT = st.missT or now
        if now - st.missT > 500 then
            st.exclude[f.id] = true
            st.missT = nil
        end
    end
    if st.clicks > 6 then return "failed" end
    return "running"
end

-- Sneak backwards toward the edge so the side face of the block we stand
-- on becomes visible, then place against it (classic bridging).
function ACT.bridgeCreep(st, x, y, z)
    if not st.sfx then st.sfx, st.sfz = P.fx, P.fz end
    local fx, fz = st.sfx, st.sfz
    local dirX, dirZ = x - fx, z - fz
    if abs(dirX) + abs(dirZ) ~= 1 then return "noface" end
    IN.clear()
    IN.press("sneak")
    local backYaw = U.yawTo(x + 0.5, z + 0.5, fx + 0.5, fz + 0.5)
    local faceX, faceY, faceZ = fx + 0.5 + dirX * 0.5, y + 0.5, fz + 0.5 + dirZ * 0.5
    local ex, ey, ez = P.eye()
    local pitch = U.pitchTo(ex, ey, ez, faceX, faceY, faceZ)
    IN.look(backYaw, max(pitch, 70))
    local over = (P.x - (fx + 0.5)) * dirX + (P.z - (fz + 0.5)) * dirZ
    if over < 0.78 and abs(U.wrap180(backYaw - P.yaw)) < 20 then
        IN.press("back")
    end
    return "running"
end

function ACT.pillar(st, x, y, z)
    local now = U.now()
    if not st.t0 then st.t0 = now st.phase = "aim" end
    if now - st.t0 > 6000 then return "failed" end
    if K.solid(W.fresh(x, y, z)) and P.fy >= y + 1 and P.grounded then return "done" end
    local slot = HB.throwaway()
    if not slot then return "noitem" end
    IN.select(slot)
    IN.clear()
    IN.look(P.yaw, 89.9)
    if st.phase == "aim" then
        if P.pitch > 84 and P.slot == slot and P.grounded then
            st.phase = "jump"
            st.jumpT = now
        end
    elseif st.phase == "jump" then
        IN.press("jump")
        if now - st.jumpT > 120 then st.phase = "air" end
    elseif st.phase == "air" then
        if P.y >= y + 1.02 then
            local hit = W.raycast(3)
            if hit and hit.by == y - 1 and hit.bx == x and hit.bz == z and (hit.fid == nil or hit.fid == 1) then
                if not st.lastClick or now - st.lastClick > 250 then
                    IN.click()
                    st.lastClick = now
                end
            end
        end
        if P.grounded and now - st.jumpT > 600 then
            if K.solid(W.fresh(x, y, z)) then return "done" end
            st.phase = "aim"
        end
    end
    return "running"
end

-- =====================================================================
-- Fall guard: water-bucket clutch when a fall would hurt
-- =====================================================================
local FG = { active = false }

function FG.dangerous()
    if P.creative() or P.gamemode == 3 then return false end
    if P.grounded or P.vy > -0.45 then return false end
    if W.dim == "nether" then return false end
    if Bot and Bot.proc and Bot.proc.name == "elytra" then return false end
    if P.chest == "elytra" and P.horizSpeed() > 0.6 then return false end
    local gy, gn = W.groundBelow(P.fx, P.fy, P.fz, 80)
    if not gy then return false end
    if K.isWater(gn) then return false end
    local start = P.fallStartY or P.y
    local total = start - (gy + 1)
    return total > S.maxFallHeightNoWater + 0.6, gy
end

function FG.tick()
    local now = U.now()
    if not FG.active then
        if not S.fallGuard and not (Bot and Bot.proc) then return false end
        if not Helper.connected or not IN.calibrated() then return false end
        local danger = FG.dangerous()
        if not danger then return false end
        local slot = HB.slotOf("water_bucket")
        if not slot then return false end
        FG.active = true
        FG.phase = "fall"
        FG.prevSlot = P.slot
        FG.t0 = now
        FG.slot = slot
        if S.chatDebug then U.chat("Fall guard: water bucket") end
    end
    IN.clear()
    if now - FG.t0 > 12000 then FG.active = false return false end
    if FG.phase == "fall" then
        IN.select(FG.slot)
        IN.look(P.yaw, 89.9)
        local feet = W.fresh(P.fx, P.fy, P.fz)
        if P.grounded or K.isWater(feet) then
            FG.phase = "landed"
            FG.landT = now
        elseif P.mainhand == "water_bucket" and P.pitch > 70 then
            local hit = W.raycast(5.5)
            if hit and (hit.fid == nil or hit.fid == 1) and now - IN.lastClick > 60 then
                IN.click()
            end
        elseif P.mainhand == "bucket" then
            FG.phase = "placed"
        end
    elseif FG.phase == "placed" then
        IN.look(P.yaw, 89.9)
        local feet = W.fresh(P.fx, P.fy, P.fz)
        if P.grounded or K.isWater(feet) then
            FG.phase = "landed"
            FG.landT = now
        end
    elseif FG.phase == "landed" then
        IN.look(P.yaw, 89.9)
        if now - FG.landT > 250 then
            if P.mainhand == "bucket" then
                if now - IN.lastClick > 400 then IN.click() end
                if now - FG.landT > 3000 then FG.phase = "done" end
            else
                FG.phase = "done"
            end
        end
    elseif FG.phase == "done" then
        if FG.prevSlot then IN.select(FG.prevSlot) end
        FG.active = false
        IN.clear()
        return false
    end
    return true
end

-- =====================================================================
-- Navigation: plan with A*, then walk the path with real inputs
-- =====================================================================
local NAV = {
    state = "idle", goal = nil, search = nil, path = nil, idx = 1, act = nil, avoid = {},
    fails = 0, waitUntil = 0, lastProgress = 0, lastPos = nil, opts = {}, partial = false,
    jumpUntil = 0, info = "",
}
local M = PF.M

function NAV.feet()
    return P.fx, floor(P.y + 0.2), P.fz
end

function NAV.inWater()
    local fx, fy, fz = NAV.feet()
    return K.isWater(W.fresh(fx, fy, fz))
end

function NAV.addAvoid(x, y, z, ms)
    NAV.avoid[U.key(x, y, z)] = U.now() + (ms or 60000)
end

function NAV.ctx()
    local opts = NAV.opts or {}
    local now = U.now()
    local avoid = {}
    for k, exp in pairs(NAV.avoid) do
        if exp > now then avoid[k] = true else NAV.avoid[k] = nil end
    end
    if opts.avoid then for k in pairs(opts.avoid) do avoid[k] = true end end
    local btCache = {}
    local creative = P.creative()
    return {
        allowBreak = S.allowBreak and opts.allowBreak ~= false,
        canPlace = S.allowPlace and opts.allowPlace ~= false and HB.throwaway() ~= nil,
        allowSwim = S.allowSwimming,
        allowDownward = S.allowDownward and S.allowBreak,
        allowDiagonal = S.allowDiagonal,
        maxFall = S.maxFallHeightNoWater,
        maxFallBucket = S.maxFallHeightBucket,
        hasBucket = S.allowWaterBucketFall and HB.has("water_bucket") and W.dim ~= "nether",
        walkCost = (S.allowSprint and P.hunger >= S.sprintMinHunger) and PF.COST.SPRINT or PF.COST.WALK,
        placePenalty = S.blockPlacementPenalty,
        breakPenalty = S.blockBreakAdditionalPenalty,
        breakTicks = function(n)
            local t = btCache[n]
            if t then return t end
            if creative then t = 1
            else
                local _, tool = HB.bestTool(K.toolFor(n))
                t = K.breakTicks(n, tool)
            end
            btCache[n] = t
            return t
        end,
        noBreak = opts.noBreak,
        noPlace = opts.noPlace,
        avoid = avoid,
        loaded = W.loaded,
        maxNodes = opts.maxNodes,
    }
end

function NAV.set(goal, opts)
    NAV.goal = goal
    NAV.opts = opts or {}
    NAV.state = "plan"
    NAV.path = nil
    NAV.search = nil
    NAV.act = nil
    NAV.fails = 0
    NAV.waitUntil = 0
end

function NAV.stop()
    NAV.state = "idle"
    NAV.goal = nil
    NAV.path = nil
    NAV.search = nil
    NAV.act = nil
    IN.clear()
end

function NAV.replan(delay)
    NAV.state = "plan"
    NAV.path = nil
    NAV.act = nil
    NAV.search = nil
    NAV.waitUntil = U.now() + (delay or 0)
    IN.clear()
end

function NAV.busy()
    return NAV.state == "plan" or NAV.state == "search" or NAV.state == "exec"
end

-- runs every frame: spend a slice of CPU on the A* search
function NAV.frame(now)
    if NAV.state ~= "search" or not NAV.search then return end
    local s = NAV.search
    local st = PF.step(s, S.pathTimeBudgetMS)
    if st == "running" then return end
    if st == "found" or st == "partial" then
        NAV.path = s.path
        NAV.partial = (st == "partial")
        NAV.idx = 1
        NAV.act = nil
        NAV.state = "exec"
        NAV.lastProgress = now
        NAV.lastPos = nil
        if st == "found" then NAV.fails = 0 end
        NAV.info = fmt("%d nodes, %s, %d explored, %dms", #s.path, NAV.partial and "partial" or "complete", s.expanded, floor(s.cpu))
        if S.chatDebug then U.chat("Path: " .. NAV.info) end
        if #s.path <= 1 then
            if NAV.goal.isGoal(s.sx, s.sy, s.sz) then NAV.state = "arrived" else NAV.replan(800) end
        end
    else
        NAV.fails = NAV.fails + 1
        NAV.info = fmt("no path (%d explored, %dms)", s.expanded, floor(s.cpu))
        if S.chatDebug then U.chat("Path search failed: " .. NAV.info) end
        if NAV.fails >= 3 then
            NAV.state = "failed"
        else
            NAV.replan(600)
        end
    end
    NAV.search = nil
end

function NAV.tick(now)
    local st = NAV.state
    if st == "idle" or st == "arrived" or st == "failed" then return end
    if st == "plan" then
        IN.clear()
        if now < NAV.waitUntil then return end
        if not (P.grounded or NAV.inWater()) then return end
        local fx, fy, fz = NAV.feet()
        -- about to fall (e.g. we just mined the block under us)? wait until we land
        if not NAV.inWater() and K.passable(W.fresh(fx, fy - 1, fz)) and not K.solid(W.fresh(fx, fy, fz)) then
            local supported = false
            for _, o in ipairs({ { 0.3, 0.3 }, { -0.3, 0.3 }, { 0.3, -0.3 }, { -0.3, -0.3 } }) do
                if K.solid(W.fresh(floor(P.x + o[1]), fy - 1, floor(P.z + o[2]))) then supported = true end
            end
            if not supported then return end
        end
        if NAV.goal.isGoal(fx, fy, fz) then
            NAV.state = "arrived"
            return
        end
        W.clear()
        NAV.search = PF.new(fx, fy, fz, NAV.goal, NAV.ctx())
        NAV.state = "search"
        return
    end
    if st == "search" then
        IN.clear()
        return
    end
    if st == "exec" then NAV.exec(now) end
end

local function sameDir(a, b, c)
    return c and b and a and (c.x - b.x) == (b.x - a.x) and (c.z - b.z) == (b.z - a.z) and c.y == b.y and b.y == a.y
end

function NAV.straightAhead()
    local path, i = NAV.path, NAV.idx
    local n = 0
    while path[i + 2] and sameDir(path[i], path[i + 1], path[i + 2]) and path[i + 2].kind == M.TRAVERSE do
        n = n + 1
        i = i + 1
        if n >= 6 then break end
    end
    return n + 1
end

local function arrivedAt(j)
    local path = NAV.path
    local n = path[j]
    local dist = U.dist2(P.x, P.z, n.x + 0.5, n.z + 0.5)
    local inW = NAV.inWater()
    if not (P.grounded or inW) then return false end
    if j >= #path then return dist < 0.45 end
    local nn = path[j + 1]
    if sameDir(path[j - 1], n, nn) and (nn.kind == M.TRAVERSE or nn.kind == M.DIAGONAL) then
        return dist < 0.95
    end
    if nn.kind == M.ASCEND or nn.kind == M.DESCEND or nn.kind == M.FALL then
        return dist < 0.6
    end
    return dist < 0.4
end

function NAV.advance(j)
    NAV.idx = j
    NAV.act = nil
    NAV.lastProgress = U.now()
end

function NAV.doAct(kind, pos, fn)
    local key = kind .. ":" .. tostring(U.key(pos[1], pos[2], pos[3]))
    if not NAV.act or NAV.act.key ~= key then
        NAV.act = { key = key, st = { protect = NAV.opts.noBreak } }
    end
    local r = fn(NAV.act.st)
    if r == "done" then
        NAV.act = nil
        NAV.lastProgress = U.now()
        return true
    elseif r ~= "running" then
        if S.chatDebug then U.chat(fmt("%s at %s: %s", kind, U.fmtPos(pos[1], pos[2], pos[3]), r)) end
        if r == "noitem" and kind == "place" then
            NAV.opts.allowPlace = false
        end
        local nxt = NAV.path[NAV.idx + 1]
        if nxt then NAV.addAvoid(nxt.x, nxt.y, nxt.z, 45000) end
        NAV.addAvoid(pos[1], pos[2], pos[3], 45000)
        NAV.replan(300)
    end
    return false
end

local function throwawayPred(it) return Settings.set("acceptableThrowawayItems")[it] end

function NAV.exec(now)
    local path = NAV.path
    local fx, fy, fz = NAV.feet()

    -- advance along the path (also skips ahead if we got further than expected),
    -- but never past a move whose blocks haven't actually been placed yet
    for j = min(#path, NAV.idx + 6), NAV.idx + 1, -1 do
        local n = path[j]
        if n.x == fx and n.y == fy and n.z == fz then
            local placedOk = true
            for k = NAV.idx + 1, j do
                if path[k].place then
                    local _, pl = PF.describe(path[k - 1], path[k])
                    for _, c in ipairs(pl) do
                        if not K.solid(W.fresh(c[1], c[2], c[3])) then placedOk = false end
                    end
                end
            end
            if placedOk and (j > NAV.idx + 1 or arrivedAt(j)) then
                NAV.advance(j)
            end
            break
        end
    end

    if NAV.idx >= #path then
        IN.clear()
        if NAV.goal.isGoal(fx, fy, fz) then
            NAV.state = "arrived"
        else
            NAV.replan(0)
        end
        return
    end

    local cur, nxt = path[NAV.idx], path[NAV.idx + 1]

    -- off the path?
    local onCur = fx == cur.x and fy == cur.y and fz == cur.z
    local onNxt = fx == nxt.x and fy == nxt.y and fz == nxt.z
    if not onCur and not onNxt and (P.grounded or NAV.inWater()) then
        local dC = U.dist3(P.x, P.y, P.z, cur.x + 0.5, cur.y, cur.z + 0.5)
        local dN = U.dist3(P.x, P.y, P.z, nxt.x + 0.5, nxt.y, nxt.z + 0.5)
        local wrongLevel = fy ~= cur.y and fy ~= nxt.y and P.grounded
        if min(dC, dN) > 1.6 or wrongLevel then
            if S.chatDebug then U.chat("Off path, replanning") end
            NAV.replan(0)
            return
        end
    end

    -- obstacles: clear cells, then place cells
    local clear, place = PF.describe(cur, nxt)
    for i = 1, #clear do
        local c = clear[i]
        local n = W.fresh(c[1], c[2], c[3])
        if not (K.passable(n) or K.isWater(n)) then
            NAV.doAct("mine", c, function(st) return ACT.mine(st, c[1], c[2], c[3]) end)
            return
        end
    end
    for i = 1, #place do
        local p = place[i]
        local n = W.fresh(p[1], p[2], p[3])
        if K.passable(n) or K.isWater(n) then
            if nxt.kind == M.PILLAR then
                NAV.doAct("pillar", p, function(st) return ACT.pillar(st, p[1], p[2], p[3]) end)
            else
                NAV.doAct("place", p, function(st)
                    if nxt.kind == M.TRAVERSE and not st.bridge then
                        st.bridge = true
                        st.sfx, st.sfz = cur.x, cur.z
                    end
                    return ACT.place(st, p[1], p[2], p[3], throwawayPred)
                end)
            end
            return
        end
    end
    NAV.act = nil

    -- stuck detection
    if not NAV.lastPos or U.dist3(P.x, P.y, P.z, NAV.lastPos[1], NAV.lastPos[2], NAV.lastPos[3]) > 0.15 then
        NAV.lastPos = { P.x, P.y, P.z }
        NAV.lastProgress = now
    end
    local stuckFor = now - NAV.lastProgress
    if stuckFor > 6000 then
        if S.chatDebug then U.chat("Stuck, replanning") end
        NAV.addAvoid(nxt.x, nxt.y, nxt.z, 30000)
        NAV.replan(0)
        return
    elseif stuckFor > 2500 and now > NAV.jumpUntil + 1500 then
        NAV.jumpUntil = now + 300
    end

    NAV.move(cur, nxt, now)
    if now < NAV.jumpUntil then IN.press("jump") end
end

function NAV.move(cur, nxt, now)
    local kind = nxt.kind
    local tx, tz = nxt.x + 0.5, nxt.z + 0.5
    local dist = U.dist2(P.x, P.z, tx, tz)
    local inW = NAV.inWater()
    IN.clear()

    if kind == M.DOWNWARD then
        if dist > 0.2 then
            IN.look(U.yawTo(P.x, P.z, tx, tz), S.walkPitch)
            IN.press("sneak")
            IN.press("forward")
        end
        return
    elseif kind == M.SWIM_UP then
        IN.press("jump")
        if dist > 0.3 then
            IN.look(U.yawTo(P.x, P.z, tx, tz), S.walkPitch)
            IN.press("forward")
        end
        return
    elseif kind == M.SWIM_DOWN then
        IN.press("sneak")
        return
    elseif kind == M.PILLAR then
        IN.press("jump")
        return
    end

    -- walking moves
    local aimX, aimZ = tx, tz
    local nn = NAV.path[NAV.idx + 2]
    if (kind == M.TRAVERSE or kind == M.DIAGONAL) and sameDir(cur, nxt, nn) then
        aimX, aimZ = nn.x + 0.5, nn.z + 0.5
    end
    if dist < 0.15 then aimX, aimZ = tx + (nxt.x - cur.x), tz + (nxt.z - cur.z) end
    local yaw = U.yawTo(P.x, P.z, aimX, aimZ)
    IN.look(yaw, S.walkPitch)
    local yawErr = abs(U.wrap180(yaw - P.yaw))
    if yawErr < 35 then IN.press("forward") end

    if kind == M.ASCEND and (P.grounded or inW) and dist < 1.3 then
        IN.press("jump")
    end
    if inW and (kind == M.TRAVERSE or kind == M.ASCEND or kind == M.DIAGONAL) then
        IN.press("jump")
    end
    if S.allowSprint and P.hunger >= S.sprintMinHunger and (kind == M.TRAVERSE or kind == M.DIAGONAL)
        and not inW and yawErr < 12 and NAV.straightAhead() >= 3 then
        IN.press("sprint")
    end
    if (kind == M.DESCEND or kind == M.FALL) and not P.grounded and dist < 0.3 then
        IN.release("forward")
    end
    -- coast into the last node of the path / before a sharp turn
    if NAV.idx + 1 >= #NAV.path and dist < 0.5 then
        IN.release("forward")
        if dist > 0.2 then IN.press("sneak") IN.press("forward") end
    end
end

-- =====================================================================
-- Bot controller: one active "process" (goto, mine, follow, build ...)
-- plus pre-steps (mouse calibration, hotbar scan) and the fall guard.
-- =====================================================================
Bot.proc = nil
Bot.pre = nil
Bot.paused = false
Bot.preQueue = {}

local Proc = {}

function Bot.isActive()
    return (Bot.proc ~= nil or Bot.pre ~= nil or #Bot.preQueue > 0 or FG.active)
end

function Bot.sendInput()
    if not Helper.connected or not P.valid or not P.inHud() then return false end
    if FG.active then return true end
    if Bot.paused then return false end
    return Bot.pre ~= nil or Bot.proc ~= nil
end

function Bot.queuePre(step)
    Bot.preQueue[#Bot.preQueue + 1] = step
end

function Bot.start(proc, quiet)
    Bot.stopAll(true)
    Bot.paused = false
    Bot.proc = proc
    if not Helper.connected then
        U.chat("\194\167eBaritoneHelper.exe isn't running, so I can plan and draw the path but can't move you. Start it and type #resume.")
        Bot.paused = true
    elseif NATIVE then
        if not IN.calibrated() then Bot.queuePre(Proc.calibrate()) end
    else
        if not IN.calibrated() then Bot.queuePre(Proc.calibrate()) end
        if not HB.complete() then Bot.queuePre(Proc.hotbarScan()) end
    end
    if proc.start then proc:start() end
    if not quiet and proc.status then U.chat(proc:status()) end
end

function Bot.finish(msg)
    if msg then U.chat(msg) end
    local p = Bot.proc
    Bot.proc = nil
    if p and p.stop then p:stop() end
    NAV.stop()
    IN.clear()
end

function Bot.stopAll(silent)
    local p = Bot.proc
    Bot.proc = nil
    Bot.pre = nil
    Bot.preQueue = {}
    if p and p.stop then p:stop() end
    NAV.stop()
    IN.clear()
    if not silent then U.chat("Stopped") end
end

function Bot.tick(now)
    HB.observe()
    -- learn the hotbar once, shortly after the helper connects (needed for the fall guard)
    if not Bot.autoScanned and not NATIVE and Helper.connected and Helper.focus and P.inHud() and P.grounded
        and not Bot.isActive() and not Bot.paused and IN.calibrated() then
        Bot.readySince = Bot.readySince or now
        if now - Bot.readySince > 2500 then
            Bot.autoScanned = true
            if not HB.complete() then Bot.queuePre(Proc.hotbarScan()) end
        end
    end
    if S.stopOnLowHealth > 0 and P.health > 0 and P.health < S.stopOnLowHealth and Bot.proc and not P.creative() then
        Bot.stopAll(true)
        U.chat(fmt("\194\167cLow health (%d) - stopped. #set stopOnLowHealth 0 to disable.", floor(P.health)))
        return
    end
    if FG.tick() then return end
    if Bot.paused then
        IN.clear()
        return
    end
    if not Bot.pre and #Bot.preQueue > 0 then
        Bot.pre = tremove(Bot.preQueue, 1)
        if Bot.pre.start then Bot.pre:start() end
    end
    if Bot.pre then
        local r = Bot.pre:tick(now)
        if r == "running" then return end
        Bot.pre = nil
        IN.clear()
        if r == "failed" then
            Bot.stopAll(true)
            return
        end
        if #Bot.preQueue > 0 then return end
    end
    if Bot.proc then
        local manual = Bot.proc:tick(now)
        if not Bot.proc then return end
        if manual then return end
    end
    NAV.tick(now)
end

function Bot.status()
    if Bot.paused then return "Paused" end
    if FG.active then return "Water bucket clutch" end
    if Bot.pre and Bot.pre.status then return Bot.pre:status() end
    if Bot.proc and Bot.proc.status then return Bot.proc:status() end
    return "Idle"
end

-- ------------------------------------------------------------------
-- Pre-step: mouse calibration (measures degrees per mouse pixel)
-- ------------------------------------------------------------------
function Proc.calibrate(announce)
    local c = { name = "calibrate", phase = "wait", t = 0, tries = 0, warned = false }
    function c:start()
        self.t = U.now()
        if announce ~= false then U.chat("Calibrating mouse... keep the Minecraft window focused and don't touch the mouse.") end
    end
    function c:status() return "Calibrating mouse" end
    function c:tick(now)
        IN.clear()
        if not Helper.connected then
            U.chat("\194\167cCalibration needs BaritoneHelper.exe running.")
            return "failed"
        end
        if NATIVE and not IN.turnMode() then return "done" end
        if not Helper.focus or not P.inHud() then
            if not self.warned and now - self.t > 3000 then
                U.chat("Waiting for the Minecraft window to be focused (close chat/menus)...")
                self.warned = true
            end
            self.t = now
            return "running"
        end
        if self.phase == "wait" then
            if now - self.t > 600 then
                self.yaw0 = P.yaw
                self.px = (self.tries == 0) and 160 or 400
                IN.rawMove(self.px, 0)
                self.phase = "yaw"
                self.t = now
            end
        elseif self.phase == "yaw" then
            if IN.rawPending() then self.t = now end
            if now - self.t > 450 then
                local d = U.wrap180(P.yaw - self.yaw0)
                if abs(d) < 0.5 then
                    self.tries = self.tries + 1
                    if self.tries >= 2 then
                        if NATIVE then
                            U.chat("\194\167cThe camera didn't move. Set #set rotationMode set and try again.")
                        else
                            U.chat("\194\167cThe camera didn't move. Check that BaritoneHelper.exe is running (as admin if Minecraft runs as admin) and the game window is focused.")
                        end
                        return "failed"
                    end
                    self.phase = "wait"
                    self.t = now
                else
                    S.mouseYawPerPixel = d / self.px
                    IN.rawMove(-self.px, 0)
                    self.phase = "pwait"
                    self.t = now
                end
            end
        elseif self.phase == "pwait" then
            if IN.rawPending() then self.t = now end
            if now - self.t > 450 then
                self.pitch0 = P.pitch
                self.pdir = (P.pitch > 40) and -1 or 1
                IN.rawMove(0, 90 * self.pdir)
                self.phase = "pitch"
                self.t = now
            end
        elseif self.phase == "pitch" then
            if IN.rawPending() then self.t = now end
            if now - self.t > 450 then
                local d = P.pitch - self.pitch0
                if abs(d) < 0.3 then
                    S.mousePitchPerPixel = S.mouseYawPerPixel
                else
                    S.mousePitchPerPixel = d / (90 * self.pdir)
                end
                IN.rawMove(0, -90 * self.pdir)
                Settings.save()
                U.chat(fmt("Mouse calibrated (%.4f deg/px yaw, %.4f deg/px pitch)", S.mouseYawPerPixel, S.mousePitchPerPixel))
                self.phase = "done"
                self.t = now
            end
        elseif self.phase == "done" then
            if IN.rawPending() then self.t = now end
            if now - self.t > 300 then return "done" end
        end
        return "running"
    end
    return c
end

Bot.makeCalibrate = function() return Proc.calibrate() end

-- ------------------------------------------------------------------
-- Pre-step: learn the hotbar by selecting slots 1..9
-- ------------------------------------------------------------------
function Proc.hotbarScan(announce)
    local h = { name = "hotbar", i = 0, t = 0, orig = 0 }
    function h:start()
        self.orig = P.slot
        self.t = U.now()
        if announce then U.chat("Scanning hotbar...") end
    end
    function h:status() return "Scanning hotbar" end
    function h:tick(now)
        IN.clear()
        if not Helper.focus or not P.inHud() then self.t = now return "running" end
        if self.i > 8 then
            IN.select(self.orig)
            if P.slot == self.orig or now - self.t > 800 then
                if announce then U.chat("Hotbar: " .. HB.list()) end
                return "done"
            end
            return "running"
        end
        IN.select(self.i)
        if P.slot == self.i and now - self.t > 110 then
            HB.items[self.i] = P.mainhand or false
            HB.known[self.i] = true
            self.i = self.i + 1
            self.t = now
        elseif now - self.t > 1500 then
            U.chat("\194\167cCouldn't switch hotbar slots. Check your hotbar keys are 1-9.")
            for s = 0, 8 do HB.known[s] = true end
            return "done"
        end
        return "running"
    end
    return h
end

-- ------------------------------------------------------------------
-- #goto / #path / #thisway / #wp goto
-- ------------------------------------------------------------------
function Proc.go(goal, label)
    local g = { name = "goto", goal = goal }
    function g:start() NAV.set(goal) end
    function g:status()
        local s = "Going to " .. (label or goal.desc)
        if NAV.state == "search" then s = s .. " (planning)" end
        return s
    end
    function g:tick(now)
        if NAV.state == "arrived" then
            Bot.finish("Reached " .. (label or goal.desc))
        elseif NAV.state == "failed" then
            Bot.finish("\194\167cNo path to " .. (label or goal.desc) .. " (" .. NAV.info .. ")")
        end
    end
    return g
end

-- ------------------------------------------------------------------
-- Block scanner (time-sliced), used by #mine, #goto <block>, #farm
-- ------------------------------------------------------------------
local Scanner = {}
Scanner.__index = Scanner

function Scanner.new(match, cx, cy, cz, r, h)
    local s = setmetatable({ match = match, cx = cx, cy = cy, cz = cz, r = r, h = h, found = {}, done = false }, Scanner)
    s.ix, s.iy, s.iz = -r, -h, -r
    s.ymin = (W.dim == "nether") and 0 or -64
    s.ymax = (W.dim == "nether") and 127 or 320
    return s
end

function Scanner:step(budget)
    if self.done then return true end
    local gb = world.getBlock
    local bare = U.bare
    local match = self.match
    local r, h = self.r, self.h
    local cx, cy, cz = self.cx, self.cy, self.cz
    local ix, iy, iz = self.ix, self.iy, self.iz
    local n = 0
    while n < budget do
        local y = cy + iy
        if y >= self.ymin and y <= self.ymax then
            local x, z = cx + ix, cz + iz
            local ok, raw = pcall(gb, x, y, z)
            if ok and raw then
                local nm = bare(raw)
                if match(nm) then self.found[U.key(x, y, z)] = { x, y, z, nm } end
            end
        end
        n = n + 1
        iz = iz + 1
        if iz > r then
            iz = -r
            ix = ix + 1
            if ix > r then
                ix = -r
                iy = iy + 1
                if iy > h then
                    self.done = true
                    break
                end
            end
        end
    end
    self.ix, self.iy, self.iz = ix, iy, iz
    return self.done
end

-- ------------------------------------------------------------------
-- #mine <block...> [count]
-- ------------------------------------------------------------------
local ORE_Y = {
    diamond_ore = -58, deepslate_diamond_ore = -58, redstone_ore = -58, deepslate_redstone_ore = -58,
    lapis_ore = 0, deepslate_lapis_ore = 0, gold_ore = -16, deepslate_gold_ore = -16, iron_ore = 16,
    deepslate_iron_ore = 16, copper_ore = 48, deepslate_copper_ore = 48, coal_ore = 44, emerald_ore = 100,
    ancient_debris = 15, nether_gold_ore = 15, quartz_ore = 15,
}

function Proc.mine(names, count, quiet)
    local targets = {}
    for _, n in ipairs(names) do
        n = U.bare(n)
        if not n:find("_ore", 1, true) and not targets[n] and (n == "diamond" or n == "iron" or n == "gold" or n == "coal"
            or n == "copper" or n == "lapis" or n == "redstone" or n == "emerald") then
            n = n .. "_ore"
        end
        targets[n] = true
        if S.mineDeepslateVariants and n:sub(-4) == "_ore" and n:sub(1, 10) ~= "deepslate_" then
            targets["deepslate_" .. n] = true
        end
        if n == "redstone_ore" or n == "deepslate_redstone_ore" then
            targets["lit_" .. n] = true
            targets["lit_deepslate_redstone_ore"] = true
        end
        if n == "quartz_ore" or n == "nether_quartz_ore" then targets["quartz_ore"] = true end
    end
    local list = {}
    for n in pairs(targets) do list[#list + 1] = n end
    tsort(list)
    local m = {
        name = "mine", targets = targets, label = tconcat(list, ", "), count = count, mined = 0,
        known = {}, bad = {}, phase = "choose", scan = nil, scanT = 0, drops = {},
    }
    local function match(n) return targets[n] == true end

    function m:startScan()
        local fx, fy, fz = NAV.feet()
        self.scan = Scanner.new(match, fx, fy, fz, S.mineScanRadius, S.mineScanHeight)
        self.scanT = U.now()
    end
    function m:start() self:startScan() end
    function m:status()
        local s = fmt("Mining %s (%d", self.label, self.mined)
        if self.count then s = s .. "/" .. self.count end
        s = s .. ")"
        if self.phase == "explore" then s = s .. " - exploring" end
        return s
    end
    function m:prefY()
        local y
        for n in pairs(targets) do if ORE_Y[n] then y = ORE_Y[n] break end end
        return y
    end
    function m:tick(now)
        -- keep scanning in the background
        if self.scan and not self.scan.done then
            self.scan:step(S.mineScanBlocksPerFrame * 2)
            if self.scan.done then
                for k, v in pairs(self.scan.found) do
                    if not self.bad[k] or self.bad[k] < now then self.known[k] = v end
                end
            end
        end
        local fx, fy, fz = NAV.feet()
        if self.scan and self.scan.done and (now - self.scanT > 20000
            or U.dist3(fx, fy, fz, self.scan.cx, self.scan.cy, self.scan.cz) > 14) then
            self:startScan()
        end

        if self.phase == "break" then
            local t = self.target
            local r = ACT.mine(self.breakSt, t[1], t[2], t[3])
            if r == "running" then return true end
            local k = U.key(t[1], t[2], t[3])
            self.known[k] = nil
            IN.clear()
            if r == "done" then
                self.mined = self.mined + 1
                W.set(t[1], t[2], t[3], "air")
                -- veins: check neighbours of the mined block
                for i = 1, 6 do
                    local d = PF.ADJ6[i]
                    local ax, ay, az = t[1] + d[1], t[2] + d[2], t[3] + d[3]
                    local an = W.fresh(ax, ay, az)
                    if targets[an] then self.known[U.key(ax, ay, az)] = { ax, ay, az, an } end
                end
                if S.mineCollectDrops then self.drops[#self.drops + 1] = { t[1], t[2], t[3], now } end
                if self.count and self.mined >= self.count then
                    Bot.finish(fmt("Mined %d %s", self.mined, self.label))
                    return true
                end
            else
                self.bad[k] = now + 120000
            end
            self.phase = "choose"
            return true
        end

        if self.phase == "travel" or self.phase == "collect" or self.phase == "explore" then
            if NAV.state == "arrived" or NAV.state == "failed" or NAV.state == "idle" then
                local failed = NAV.state == "failed"
                local wasPhase = self.phase
                self.phase = "choose"
                if failed and wasPhase == "travel" and self.goalKeys then
                    for _, k in ipairs(self.goalKeys) do
                        self.known[k] = nil
                        self.bad[k] = now + 120000
                    end
                end
                if failed and wasPhase == "explore" then
                    self.exploreDir = (self.exploreDir or 0) + 1
                end
                NAV.stop()
            else
                -- re-target if something better shows up
                return false
            end
        end

        if self.phase == "choose" then
            -- count targets that vanished near us (mined while pathing)
            for k, v in pairs(self.known) do
                if U.dist3(fx, fy, fz, v[1], v[2], v[3]) < 7 then
                    local n = W.fresh(v[1], v[2], v[3])
                    if not targets[n] then
                        self.known[k] = nil
                        if K.passable(n) then self.mined = self.mined + 1 end
                    end
                end
            end
            if self.count and self.mined >= self.count then
                Bot.finish(fmt("Mined %d %s", self.mined, self.label))
                return true
            end
            -- adjacent target? break it now
            for k, v in pairs(self.known) do
                if G.getToBlock(v[1], v[2], v[3]).isGoal(fx, fy, fz) then
                    self.target = v
                    self.breakSt = {}
                    self.phase = "break"
                    return true
                end
            end
            -- collect recent drops first
            if #self.drops > 0 then
                local d = tremove(self.drops, 1)
                if now - d[4] < 30000 then
                    local gy = d[2]
                    for yy = d[2], d[2] - 4, -1 do
                        if K.standable(W.fresh(d[1], yy - 1, d[3])) then gy = yy break end
                    end
                    if not (fx == d[1] and fz == d[3]) then
                        NAV.set(G.near(d[1], gy, d[3], 0.5))
                        self.phase = "collect"
                        return false
                    end
                end
            end
            -- nearest known targets
            local cands = {}
            for k, v in pairs(self.known) do
                cands[#cands + 1] = { k = k, v = v, d = U.dist3(fx, fy, fz, v[1], v[2], v[3]) }
            end
            if #cands > 0 then
                tsort(cands, function(a, b) return a.d < b.d end)
                local goals, keys = {}, {}
                for i = 1, min(12, #cands) do
                    local v = cands[i].v
                    goals[#goals + 1] = G.getToBlock(v[1], v[2], v[3])
                    keys[#keys + 1] = cands[i].k
                end
                self.goalKeys = keys
                NAV.set(G.composite(goals))
                self.phase = "travel"
                return false
            end
            if self.scan and not self.scan.done then
                IN.clear()
                return true
            end
            if not S.exploreForBlocks then
                Bot.finish("No " .. self.label .. " found nearby")
                return true
            end
            -- explore: head to a good Y level, then tunnel
            local py = self:prefY()
            local ex, ez
            local dirs = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
            if not self.exploreDir then
                local dx, dz = U.dirFromYaw(P.yaw)
                if abs(dx) > abs(dz) then self.exploreDir = (dx > 0) and 0 or 2 else self.exploreDir = (dz > 0) and 1 or 3 end
            end
            local dd = dirs[(self.exploreDir % 4) + 1]
            ex, ez = fx + dd[1] * 32, fz + dd[2] * 32
            local ty = fy
            if py and abs(fy - py) > 4 and W.dim ~= "end" then ty = py end
            NAV.set(G.block(ex, ty, ez))
            self.phase = "explore"
            return false
        end
        return false
    end
    function m:stop() IN.clear() end
    return m
end

-- ------------------------------------------------------------------
-- #goto <block>  (walk next to the nearest block of that type)
-- ------------------------------------------------------------------
function Proc.gotoBlock(name)
    name = U.bare(name)
    local p = { name = "gotoblock", block = name, phase = "scan" }
    function p:start()
        local fx, fy, fz = NAV.feet()
        self.scan = Scanner.new(function(n) return n == name end, fx, fy, fz, 48, 24)
    end
    function p:status() return "Looking for " .. name end
    function p:tick(now)
        if self.phase == "scan" then
            IN.clear()
            if self.scan:step(S.mineScanBlocksPerFrame * 3) then
                local fx, fy, fz = NAV.feet()
                local list = {}
                for _, v in pairs(self.scan.found) do
                    list[#list + 1] = { v = v, d = U.dist3(fx, fy, fz, v[1], v[2], v[3]) }
                end
                if #list == 0 then
                    Bot.finish("No " .. name .. " found within 48 blocks")
                    return true
                end
                tsort(list, function(a, b) return a.d < b.d end)
                local goals = {}
                for i = 1, min(8, #list) do goals[i] = G.getToBlock(list[i].v[1], list[i].v[2], list[i].v[3]) end
                NAV.set(G.composite(goals))
                self.phase = "go"
            end
            return true
        end
        if NAV.state == "arrived" then Bot.finish("Reached " .. name)
        elseif NAV.state == "failed" then Bot.finish("\194\167cCouldn't reach " .. name) end
        return false
    end
    return p
end

-- ------------------------------------------------------------------
-- #tunnel : dig a 1x2 tunnel in the direction you face
-- ------------------------------------------------------------------
function Proc.tunnel(length)
    local t = { name = "tunnel" }
    function t:start()
        local dx, dz = U.dirFromYaw(P.yaw)
        if abs(dx) > abs(dz) then self.dx, self.dz = (dx > 0) and 1 or -1, 0 else self.dx, self.dz = 0, (dz > 0) and 1 or -1 end
        local fx, fy, fz = NAV.feet()
        self.y = fy
        self.endX, self.endZ = fx + self.dx * (length or 64), fz + self.dz * (length or 64)
        self:next()
    end
    function t:next()
        local fx, fy, fz = NAV.feet()
        local step = 12
        local tx, tz = fx + self.dx * step, fz + self.dz * step
        if (self.dx ~= 0 and (tx - self.endX) * self.dx > 0) or (self.dz ~= 0 and (tz - self.endZ) * self.dz > 0) then
            tx, tz = self.endX, self.endZ
        end
        self.tx, self.tz = tx, tz
        -- keep strictly in line: forbid leaving the tunnel line
        NAV.set(G.block(tx, self.y, tz), { allowPlace = true })
    end
    function t:status() return fmt("Tunnelling to %s", U.fmtPos(self.endX or 0, self.y or 0, self.endZ or 0)) end
    function t:tick(now)
        if NAV.state == "arrived" then
            if self.tx == self.endX and self.tz == self.endZ then Bot.finish("Tunnel finished") return true end
            self:next()
        elseif NAV.state == "failed" then
            Bot.finish("\194\167cTunnel blocked")
            return true
        end
        return false
    end
    return t
end

-- =====================================================================
-- #follow  (experimental)
-- Flarial's script API gives each entity's *distance* to us but not its
-- position, so we locate the target by trilateration: distance samples
-- taken from several of our own positions pin down where it is.
-- =====================================================================
local function solve3(m, v)
    -- Cramer's rule for a 3x3 system m * t = v
    local a, b, c = m[1], m[2], m[3]
    local det = a[1] * (b[2] * c[3] - b[3] * c[2]) - a[2] * (b[1] * c[3] - b[3] * c[1]) + a[3] * (b[1] * c[2] - b[2] * c[1])
    if abs(det) < 1e-6 then return nil end
    local function d(col)
        local r = {}
        for i = 1, 3 do
            local row = { m[i][1], m[i][2], m[i][3] }
            row[col] = v[i]
            r[i] = row
        end
        local A, B, C = r[1], r[2], r[3]
        return A[1] * (B[2] * C[3] - B[3] * C[2]) - A[2] * (B[1] * C[3] - B[3] * C[1]) + A[3] * (B[1] * C[2] - B[2] * C[1])
    end
    return d(1) / det, d(2) / det, d(3) / det
end

local function trilaterate(samples)
    local n = #samples
    if n < 5 then return nil end
    local mx, my, mz, md2, mp2 = 0, 0, 0, 0, 0
    for i = 1, n do
        local s = samples[i]
        mx, my, mz = mx + s[1], my + s[2], mz + s[3]
        md2 = md2 + s[4] * s[4]
        mp2 = mp2 + s[1] * s[1] + s[2] * s[2] + s[3] * s[3]
    end
    mx, my, mz, md2, mp2 = mx / n, my / n, mz / n, md2 / n, mp2 / n
    local vx, vy, vz = 0, 0, 0
    for i = 1, n do
        local s = samples[i]
        vx = vx + (s[1] - mx) ^ 2
        vy = vy + (s[2] - my) ^ 2
        vz = vz + (s[3] - mz) ^ 2
    end
    vx, vy, vz = vx / n, vy / n, vz / n
    if vx + vz < 0.25 or vx < 0.02 or vz < 0.02 then return nil, "spread" end
    -- rows: -2 (P_i - Pm) . T = (d_i^2 - md2) - (|P_i|^2 - mp2)
    local use3 = vy > 0.08
    local M = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    local V = { 0, 0, 0 }
    for i = 1, n do
        local s = samples[i]
        local a = { -2 * (s[1] - mx), -2 * (s[2] - my), -2 * (s[3] - mz) }
        local b = (s[4] * s[4] - md2) - ((s[1] * s[1] + s[2] * s[2] + s[3] * s[3]) - mp2)
        for r = 1, 3 do
            for c = 1, 3 do M[r][c] = M[r][c] + a[r] * a[c] end
            V[r] = V[r] + a[r] * b
        end
    end
    local tx, ty, tz
    if use3 then
        tx, ty, tz = solve3(M, V)
        if not tx then use3 = false end
    end
    if not use3 then
        -- 2D solve in x/z, then recover y from the distances
        local a11, a12, a22 = M[1][1], M[1][3], M[3][3]
        local b1, b2 = V[1], V[3]
        local det = a11 * a22 - a12 * a12
        if abs(det) < 1e-6 then return nil, "spread" end
        tx = (b1 * a22 - a12 * b2) / det
        tz = (a11 * b2 - a12 * b1) / det
        local sum, cnt = 0, 0
        for i = 1, n do
            local s = samples[i]
            local h2 = (tx - s[1]) ^ 2 + (tz - s[3]) ^ 2
            local r = s[4] * s[4] - h2
            if r > 0 then sum = sum + sqrt(r) cnt = cnt + 1 else cnt = cnt + 1 end
        end
        local dyAbs = (cnt > 0) and (sum / cnt) or 0
        local up, dn = my + dyAbs, my - dyAbs
        -- pick the candidate standing on something
        local function score(eyeY)
            local fy = floor(eyeY - 1.62 + 0.2)
            local ok = K.passable(W.get(floor(tx), fy, floor(tz))) and K.solid(W.get(floor(tx), fy - 1, floor(tz)))
            return ok and 1 or 0
        end
        local su, sd = score(up), score(dn)
        if su > sd then ty = up elseif sd > su then ty = dn else ty = (abs(up - my) <= abs(dn - my)) and up or dn end
        if dyAbs < 0.6 then ty = my end
    end
    local err = 0
    for i = 1, n do
        local s = samples[i]
        local d = U.dist3(tx, ty, tz, s[1], s[2], s[3])
        err = err + (d - s[4]) ^ 2
    end
    err = sqrt(err / n)
    return { x = tx, y = ty, z = tz, err = err }
end

function Proc.follow(mode, who)
    local f = {
        name = "follow", mode = mode, who = who and who:lower() or nil, samples = {}, est = nil,
        lastSeen = 0, probeStep = 0, probeT = 0, lastGoal = nil, lost = false,
    }
    function f:status()
        local s = "Following " .. (self.who or self.mode)
        if self.est then s = s .. fmt(" (~%d, %d, %d)", floor(self.est.x), floor(self.est.y), floor(self.est.z)) end
        return s .. (NATIVE and "" or " [experimental]")
    end
    function f:findTarget()
        local ok, ents = pcall(world.getEntities, 160)
        if not ok or type(ents) ~= "table" then return nil end
        local best, bestD
        local myName = P.name:lower()
        local function call(e, m)
            local okc, v = pcall(function() return e[m](e) end)
            if okc then return v end
            return nil
        end
        for _, e in ipairs(ents) do
            local isTable = type(e) == "table" and type(e.x) == "number" and type(e.isValid) ~= "function"
            if isTable or call(e, "isValid") then
                local nm, tid, d
                if isTable then
                    -- DLL: real positions are available
                    nm = tostring(e.name or ""):gsub("\194\167.", ""):lower()
                    tid = U.bare(e.type or "")
                    if e.player then tid = "player" end
                    d = tonumber(e.dist) or 0
                else
                    nm = tostring(call(e, "getName") or ""):lower()
                    tid = U.bare(call(e, "getTypeId") or "")
                    d = tonumber(call(e, "distanceToPlayer")) or 0
                end
                local match = false
                if self.mode == "player" then
                    match = (tid == "player") and (nm == self.who or nm:find(self.who, 1, true) ~= nil)
                elseif self.mode == "players" then
                    match = tid == "player" and nm ~= myName
                elseif self.mode == "entity" then
                    match = (self.who == nil) or tid == self.who or tid:find(self.who, 1, true) ~= nil
                end
                if match and d > 0 and (not bestD or d < bestD) then best, bestD = e, d end
                if match and tid == "player" then self.isPlayer = true end
            end
        end
        return best, bestD
    end
    function f:tick(now)
        local e, d = self:findTarget()
        if not e then
            IN.clear()
            if now - self.lastSeen > 5000 and not self.lost then
                U.chat("Can't see " .. (self.who or self.mode) .. " - waiting")
                self.lost = true
            end
            return true
        end
        self.lastSeen = now
        self.lost = false
        if type(e) == "table" and type(e.x) == "number" and type(e.isValid) ~= "function" then
            -- exact position from the game: no need to estimate
            self.est = { x = e.x, y = e.y, z = e.z, err = 0, t = now }
            if d <= S.followRadius + 0.6 then
                NAV.stop()
                IN.clear()
                return true
            end
            return self:pathTo(now)
        end
        local ex, ey, ez = P.eye()
        local samples = self.samples
        local last = samples[#samples]
        if not last or U.dist3(last[1], last[2], last[3], ex, ey, ez) > 0.05 or now - last[5] > 250 then
            samples[#samples + 1] = { ex, ey, ez, d, now }
        end
        while #samples > 0 and (now - samples[1][5] > 2500 or #samples > 50) do tremove(samples, 1) end
        local est, why = trilaterate(samples)
        if est and est.err < 1.5 then
            if self.isPlayer then est.y = est.y - 1.62 end
            est.t = now
            self.est = est
        end

        if d <= S.followRadius + 0.6 then
            NAV.stop()
            IN.clear()
            return true
        end
        if self.est and now - self.est.t < 2500 then
            return self:pathTo(now)
        end
        -- not enough geometry: walk a small square to collect samples
        NAV.stop()
        IN.clear()
        if now - self.probeT > 450 then
            self.probeStep = (self.probeStep + 1) % 4
            self.probeT = now
        end
        local keys = { "forward", "left", "back", "right" }
        IN.press(keys[self.probeStep + 1])
        return true
    end
    function f:pathTo(now)
        do
            local gx, gy, gz = floor(self.est.x), floor(self.est.y + 0.2), floor(self.est.z)
            -- snap the estimate onto the ground nearby
            for dy = 0, 4 do
                local found = false
                for _, yy in ipairs({ gy - dy, gy + dy }) do
                    if K.passable(W.get(gx, yy, gz)) and K.passable(W.get(gx, yy + 1, gz)) and K.solid(W.get(gx, yy - 1, gz)) then
                        gy = yy
                        found = true
                        break
                    end
                end
                if found then break end
            end
            local lg = self.lastGoal
            local moved = not lg or U.dist3(lg[1], lg[2], lg[3], gx, gy, gz) > 2.5
            local navDone = NAV.state == "failed" or NAV.state == "arrived" or NAV.state == "idle"
            if (moved and now - (self.lastSetT or 0) > 1200) or (navDone and now - (self.lastSetT or 0) > 600) then
                self.lastGoal = { gx, gy, gz }
                self.lastSetT = now
                NAV.set(G.nearXZ(gx, gy, gz, S.followRadius, 3), { maxNodes = 6000 })
            end
            return false
        end
    end
    function f:stop() NAV.stop() end
    return f
end

-- =====================================================================
-- Schematics: .mcstructure (Bedrock), .litematic, .schem (Sponge v2/v3)
-- and .nbt (Java structure). BaritoneHelper converts each file in
-- Baritone/schematics/ to hex text (Flarial can only read text files);
-- this module decodes the hex, parses NBT and builds a block grid.
-- =====================================================================
local SCH = {}
local SCHEM_DIR = DIR .. "/schematics"
local CACHE_DIR = SCHEM_DIR .. "/.cache"
local SCHEM_FOLDER_SHOWN = NATIVE and "%LOCALAPPDATA%\\Latite\\Baritone\\schematics"
    or "%LOCALAPPDATA%\\Flarial\\Client\\Baritone\\schematics"
local SCHEM_EXTS = { mcstructure = true, litematic = true, schem = true, schematic = true, nbt = true }

local HEXMAP = {}
for i = 0, 255 do
    local c = string.char(i)
    HEXMAP[fmt("%02x", i)] = c
    HEXMAP[fmt("%02X", i)] = c
    HEXMAP[fmt("%02x", i):upper():sub(1, 1) .. fmt("%02x", i):sub(2, 2)] = c
    HEXMAP[fmt("%02x", i):sub(1, 1) .. fmt("%02x", i):upper():sub(2, 2)] = c
end

local function maybeYield(counter, every)
    if counter % every == 0 and coroutine and coroutine.isyieldable and coroutine.isyieldable() then
        coroutine.yield()
    end
end

function SCH.hexToBin(hex)
    hex = hex:gsub("[^0-9a-fA-F]", "")
    local parts = {}
    local step = 65536
    local n = 0
    for i = 1, #hex, step do
        parts[#parts + 1] = (hex:sub(i, i + step - 1):gsub("%x%x", HEXMAP))
        n = n + 1
        maybeYield(n, 4)
    end
    return tconcat(parts)
end

-- ------------------------------------------------------------------
-- NBT reader (big endian for Java formats, little endian for Bedrock)
-- ------------------------------------------------------------------
function SCH.readNBT(data, little)
    local E = little and "<" or ">"
    local pos = 1
    local unpack = string.unpack
    local fI1, fI2, fU2, fI4, fI8, fF, fD = "i1", E .. "i2", E .. "I2", E .. "i4", E .. "i8", E .. "f", E .. "d"
    local work = 0
    local function u8()
        local v = data:byte(pos)
        if not v then error("truncated NBT") end
        pos = pos + 1
        return v
    end
    local function str()
        local len
        len, pos = unpack(fU2, data, pos)
        local s = data:sub(pos, pos + len - 1)
        pos = pos + len
        return s
    end
    local payload
    payload = function(t)
        if t == 1 then local v; v, pos = unpack(fI1, data, pos); return v
        elseif t == 2 then local v; v, pos = unpack(fI2, data, pos); return v
        elseif t == 3 then local v; v, pos = unpack(fI4, data, pos); return v
        elseif t == 4 then local v; v, pos = unpack(fI8, data, pos); return v
        elseif t == 5 then local v; v, pos = unpack(fF, data, pos); return v
        elseif t == 6 then local v; v, pos = unpack(fD, data, pos); return v
        elseif t == 7 then
            local n; n, pos = unpack(fI4, data, pos)
            local s = data:sub(pos, pos + n - 1)
            pos = pos + n
            return { _bytes = s, n = n }
        elseif t == 8 then return str()
        elseif t == 9 then
            local et = u8()
            local n; n, pos = unpack(fI4, data, pos)
            local list = {}
            if et == 3 then
                for i = 1, n do
                    list[i], pos = unpack(fI4, data, pos)
                    work = work + 1
                    maybeYield(work, 50000)
                end
            elseif et == 0 then
                -- empty list
            else
                for i = 1, n do
                    list[i] = payload(et)
                    work = work + 1
                    maybeYield(work, 20000)
                end
            end
            return list
        elseif t == 10 then
            local c = {}
            while true do
                local tt = u8()
                if tt == 0 then break end
                local nm = str()
                c[nm] = payload(tt)
            end
            return c
        elseif t == 11 then
            local n; n, pos = unpack(fI4, data, pos)
            local a = {}
            for i = 1, n do a[i], pos = unpack(fI4, data, pos) work = work + 1 maybeYield(work, 50000) end
            return a
        elseif t == 12 then
            local n; n, pos = unpack(fI4, data, pos)
            local a = {}
            for i = 1, n do a[i], pos = unpack(fI8, data, pos) work = work + 1 maybeYield(work, 50000) end
            return a
        end
        error("bad NBT tag " .. tostring(t) .. " at byte " .. tostring(pos))
    end
    local t = u8()
    if t ~= 10 then error("not an NBT compound (tag " .. t .. ")") end
    local rootName = str()
    return payload(10), rootName
end

-- ------------------------------------------------------------------
-- Grid helpers
-- ------------------------------------------------------------------
local function newSchem(name, sx, sy, sz)
    return { name = name, sx = sx, sy = sy, sz = sz, pal = {}, palIdx = {}, data = {} }
end

local function palId(s, blockName)
    local id = s.palIdx[blockName]
    if id then return id end
    id = #s.pal + 1
    s.pal[id] = blockName
    s.palIdx[blockName] = id
    return id
end

function SCH.index(s, x, y, z)
    return (y * s.sz + z) * s.sx + x + 1
end

-- ------------------------------------------------------------------
-- Format parsers
-- ------------------------------------------------------------------
local function parseMcstructure(name, data)
    local root = SCH.readNBT(data, true)
    local size = root.size
    if not size or not root.structure then error("not a .mcstructure file") end
    local sx, sy, sz = size[1], size[2], size[3]
    local s = newSchem(name, sx, sy, sz)
    local layer = root.structure.block_indices[1]
    local pal = root.structure.palette and root.structure.palette.default and root.structure.palette.default.block_palette or {}
    local map = {}
    for i, e in ipairs(pal) do
        local bn = U.bare(e.name)
        if bn == "structure_void" then map[i - 1] = 0
        else map[i - 1] = palId(s, (bn == "air" or bn == "cave_air") and "air" or bn) end
    end
    local fi = 1
    for x = 0, sx - 1 do
        for y = 0, sy - 1 do
            for z = 0, sz - 1 do
                local v = layer[fi]
                if v and v >= 0 then
                    local id = map[v] or 0
                    if id > 0 then s.data[SCH.index(s, x, y, z)] = id end
                end
                fi = fi + 1
            end
        end
        maybeYield(x + 1, 8)
    end
    return s
end

local function parseLitematic(name, data)
    local root = SCH.readNBT(data, false)
    if not root.Regions then error("not a .litematic file") end
    local regions = {}
    local minX, minY, minZ, maxX, maxY, maxZ = INF, INF, INF, -INF, -INF, -INF
    for rname, r in pairs(root.Regions) do
        local p, sz = r.Position, r.Size
        local ax, ay, az = abs(sz.x), abs(sz.y), abs(sz.z)
        local ox = p.x + ((sz.x < 0) and (sz.x + 1) or 0)
        local oy = p.y + ((sz.y < 0) and (sz.y + 1) or 0)
        local oz = p.z + ((sz.z < 0) and (sz.z + 1) or 0)
        regions[#regions + 1] = { r = r, ox = ox, oy = oy, oz = oz, ax = ax, ay = ay, az = az }
        minX, minY, minZ = min(minX, ox), min(minY, oy), min(minZ, oz)
        maxX, maxY, maxZ = max(maxX, ox + ax - 1), max(maxY, oy + ay - 1), max(maxZ, oz + az - 1)
    end
    if #regions == 0 then error("litematic has no regions") end
    local s = newSchem(name, maxX - minX + 1, maxY - minY + 1, maxZ - minZ + 1)
    for _, rg in ipairs(regions) do
        local pal = rg.r.BlockStatePalette or {}
        local longs = rg.r.BlockStates or {}
        local ids = {}
        for i, e in ipairs(pal) do
            local bn = K.javaToBedrock(e.Name or "air")
            if bn == "structure_void" then ids[i - 1] = 0 else ids[i - 1] = palId(s, bn) end
        end
        local bits = 2
        while (1 << bits) < #pal do bits = bits + 1 end
        local mask = (1 << bits) - 1
        local ax, ay, az = rg.ax, rg.ay, rg.az
        local vol = ax * ay * az
        local dx, dy, dz = rg.ox - minX, rg.oy - minY, rg.oz - minZ
        for i = 0, vol - 1 do
            local startBit = i * bits
            local sl = startBit >> 6
            local off = startBit & 63
            local el = ((i + 1) * bits - 1) >> 6
            local v = ((longs[sl + 1] or 0) >> off) & mask
            if sl ~= el then
                v = (v | ((longs[el + 1] or 0) << (64 - off))) & mask
            end
            local id = ids[v] or 0
            if id > 0 and s.pal[id] ~= "air" then
                local x = i % ax
                local z = (i // ax) % az
                local y = i // (ax * az)
                s.data[SCH.index(s, x + dx, y + dy, z + dz)] = id
            elseif id > 0 then
                local x = i % ax
                local z = (i // ax) % az
                local y = i // (ax * az)
                local idx = SCH.index(s, x + dx, y + dy, z + dz)
                if not s.data[idx] then s.data[idx] = id end
            end
            maybeYield(i + 1, 40000)
        end
    end
    return s
end

local function parseSponge(name, data)
    local root = SCH.readNBT(data, false)
    if root.Schematic then root = root.Schematic end
    local w, h, l = root.Width, root.Height, root.Length
    if not w then error("not a Sponge .schem file") end
    if w < 0 then w = w + 65536 end
    if h < 0 then h = h + 65536 end
    if l < 0 then l = l + 65536 end
    local palette, bytes
    if root.Blocks then
        palette, bytes = root.Blocks.Palette, root.Blocks.Data
    else
        palette, bytes = root.Palette, root.BlockData
    end
    if not palette or not bytes then error("schem has no block data") end
    local s = newSchem(name, w, h, l)
    local ids = {}
    for bname, idx in pairs(palette) do
        local bn = K.javaToBedrock(bname)
        ids[idx] = (bn == "structure_void") and 0 or palId(s, bn)
    end
    local raw = bytes._bytes or ""
    local i, n, count = 1, #raw, 0
    while i <= n do
        local value, shift = 0, 0
        while true do
            local b = raw:byte(i)
            i = i + 1
            value = value | ((b & 0x7F) << shift)
            shift = shift + 7
            if b < 128 or i > n then break end
        end
        local id = ids[value] or 0
        if id > 0 then s.data[count + 1] = id end
        count = count + 1
        maybeYield(count, 40000)
    end
    return s
end

local function parseJavaStructure(name, data)
    local root = SCH.readNBT(data, false)
    local size = root.size
    if not size or not root.blocks then error("not a Java structure .nbt file") end
    local s = newSchem(name, size[1], size[2], size[3])
    local pal = root.palette or (root.palettes and root.palettes[1]) or {}
    local ids = {}
    for i, e in ipairs(pal) do
        local bn = K.javaToBedrock(e.Name or "air")
        ids[i - 1] = (bn == "structure_void") and 0 or palId(s, bn)
    end
    for i, b in ipairs(root.blocks) do
        local p = b.pos
        local id = ids[b.state] or 0
        if id > 0 and p then s.data[SCH.index(s, p[1], p[2], p[3])] = id end
        maybeYield(i, 20000)
    end
    return s
end

-- ------------------------------------------------------------------
-- Files
-- ------------------------------------------------------------------
function SCH.listFiles()
    U.ensureDir(SCHEM_DIR)
    local out = {}
    for _, f in ipairs(U.listDir(SCHEM_DIR)) do
        local base = U.basename(f)
        local stem, ext = base:match("^(.+)%.([%w]+)$")
        if stem and SCHEM_EXTS[ext:lower()] then
            out[#out + 1] = { file = base, stem = stem, ext = ext:lower() }
        end
    end
    tsort(out, function(a, b) return a.file:lower() < b.file:lower() end)
    return out
end

function SCH.find(nameArg)
    local want = nameArg:lower()
    local files = SCH.listFiles()
    for _, f in ipairs(files) do if f.file:lower() == want then return f end end
    for _, f in ipairs(files) do if f.stem:lower() == want then return f end end
    for _, f in ipairs(files) do if f.stem:lower():find(want, 1, true) then return f end end
    return nil
end

-- returns schem or nil, err ; err == "pending" when the helper hasn't converted it yet
-- the DLL reads (and un-gzips) files directly
function SCH.nativeRead()
    return NATIVE and type(fs.readBinary) == "function"
end

function SCH.load(f)
    if SCH.nativeRead() then
        local ok, data, err = pcall(fs.readBinary, SCHEM_DIR .. "/" .. f.file)
        if not ok then return nil, tostring(data) end
        if not data then return nil, tostring(err or "can't read file") end
        return SCH.parse(f, data)
    end
    local hexPath = CACHE_DIR .. "/" .. f.file .. ".hex"
    local txt = U.readFile(hexPath)
    if not txt or not txt:find("END", -16, true) then return nil, "pending" end
    local header, body = txt:match("^(BHEX1[^\r\n]*)[\r\n]+(.*)$")
    if not header then return nil, "bad cache file " .. hexPath end
    if header:find("error", 1, true) then return nil, "BaritoneHelper couldn't read this file (see the helper window)" end
    body = body:gsub("END%s*$", "")
    local data = SCH.hexToBin(body)
    return SCH.parse(f, data)
end

function SCH.parse(f, data)
    local parser
    if f.ext == "mcstructure" then parser = parseMcstructure
    elseif f.ext == "litematic" then parser = parseLitematic
    elseif f.ext == "schem" or f.ext == "schematic" then parser = parseSponge
    elseif f.ext == "nbt" then parser = parseJavaStructure end
    local ok, s = pcall(parser, f.stem, data)
    if not ok then return nil, tostring(s) end
    return s
end

function SCH.materials(s)
    local counts = {}
    for _, id in pairs(s.data) do
        local n = s.pal[id]
        if n and n ~= "air" then counts[n] = (counts[n] or 0) + 1 end
    end
    return counts
end

-- =====================================================================
-- Litematica-style placement of the loaded schematic
-- =====================================================================
local LM = { schem = nil, ox = 0, oy = 0, oz = 0, rot = 0, mirror = nil, targets = {}, byKey = {},
    buckets = {}, minY = 0, maxY = -1, layer = nil, ghosts = {}, ghostT = 0, loading = nil }

function LM.transform(x, y, z)
    local s = LM.schem
    if LM.mirror == "x" then x = s.sx - 1 - x elseif LM.mirror == "z" then z = s.sz - 1 - z end
    local r = LM.rot
    local wx, wz
    if r == 90 then wx, wz = s.sz - 1 - z, x
    elseif r == 180 then wx, wz = s.sx - 1 - x, s.sz - 1 - z
    elseif r == 270 then wx, wz = z, s.sx - 1 - x
    else wx, wz = x, z end
    return LM.ox + wx, LM.oy + y, LM.oz + wz
end

function LM.size()
    local s = LM.schem
    if LM.rot == 90 or LM.rot == 270 then return s.sz, s.sy, s.sx end
    return s.sx, s.sy, s.sz
end

function LM.rebuild()
    local s = LM.schem
    LM.targets, LM.byKey, LM.buckets = {}, {}, {}
    if not s then return end
    local includeAir = S.buildClearAir
    local sx, sz = s.sx, s.sz
    for idx, id in pairs(s.data) do
        local name = s.pal[id]
        if name and (name ~= "air" or includeAir) then
            local i = idx - 1
            local x = i % sx
            local z = (i // sx) % sz
            local y = i // (sx * sz)
            local wx, wy, wz = LM.transform(x, y, z)
            local k = U.key(wx, wy, wz)
            local t = { wx, wy, wz, name, k }
            LM.targets[#LM.targets + 1] = t
            LM.byKey[k] = name
        end
    end
    tsort(LM.targets, function(a, b)
        if a[2] ~= b[2] then return a[2] < b[2] end
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[3] < b[3]
    end)
    LM.minY, LM.maxY = INF, -INF
    LM.layerStart = {}
    for i, t in ipairs(LM.targets) do
        if t[2] < LM.minY then LM.minY = t[2] end
        if t[2] > LM.maxY then LM.maxY = t[2] end
        if not LM.layerStart[t[2]] then LM.layerStart[t[2]] = i end
        local bk = U.key(t[1] // 16, 0, t[3] // 16)
        local b = LM.buckets[bk]
        if not b then b = {} LM.buckets[bk] = b end
        b[#b + 1] = t
    end
    LM.ghosts = {}
    LM.ghostT = 0
end

function LM.set(schem, ox, oy, oz)
    LM.schem = schem
    LM.ox, LM.oy, LM.oz = ox, oy, oz
    LM.rot, LM.mirror, LM.layer = 0, nil, nil
    LM.rebuild()
end

function LM.unload()
    LM.schem = nil
    LM.targets, LM.byKey, LM.buckets, LM.ghosts = {}, {}, {}, {}
end

function LM.state(t)
    local n = W.fresh(t[1], t[2], t[3])
    local want = t[4]
    if want == "air" then
        if K.passable(n) or K.isWater(n) then return "ok", n end
        return "wrong", n
    end
    if K.canon(n) == K.canon(want) then return "ok", n end
    if K.passable(n) or K.isWater(n) then return "missing", n end
    return "wrong", n
end

-- refresh the list of ghost boxes near the player (called a few times a second)
function LM.updateGhosts(now)
    if not LM.schem or now - LM.ghostT < 400 then return end
    LM.ghostT = now
    local r = S.litematicaRenderRadius
    local cx, cy, cz = P.fx, P.fy, P.fz
    local out = {}
    local maxBoxes = S.litematicaMaxBoxes
    local cr = r // 16 + 1
    for bx = cx // 16 - cr, cx // 16 + cr do
        for bz = cz // 16 - cr, cz // 16 + cr do
            local b = LM.buckets[U.key(bx, 0, bz)]
            if b then
                for _, t in ipairs(b) do
                    if (LM.layer == nil or t[2] == LM.layer) and abs(t[1] - cx) <= r and abs(t[3] - cz) <= r and abs(t[2] - cy) <= r then
                        local st = LM.state(t)
                        if st ~= "ok" then
                            out[#out + 1] = { t[1], t[2], t[3], st, U.dist3(t[1], t[2], t[3], cx, cy, cz) }
                        end
                    end
                end
            end
        end
    end
    tsort(out, function(a, b) return a[5] < b[5] end)
    while #out > maxBoxes do out[#out] = nil end
    LM.ghosts = out
end

function LM.verify()
    local ok, missing, wrong = 0, 0, 0
    for _, t in ipairs(LM.targets) do
        local st = LM.state(t)
        if st == "ok" then ok = ok + 1 elseif st == "missing" then missing = missing + 1 else wrong = wrong + 1 end
    end
    return ok, missing, wrong
end

-- =====================================================================
-- #build / #litematica : build the loaded placement
-- =====================================================================
function Proc.build()
    local b = { name = "build", phase = "choose", skip = {}, fails = {}, placed = 0, broken = 0, layer = nil }
    local function failTarget(t, now)
        local k = t[5]
        b.fails[k] = (b.fails[k] or 0) + 1
        b.skip[k] = now + ((b.fails[k] >= 4) and 600000 or 6000)
    end
    local opts = {
        noBreak = function(k, n)
            local want = LM.byKey[k]
            return want ~= nil and K.canon(n) == K.canon(want)
        end,
        noPlace = function(k) return LM.byKey[k] ~= nil end,
    }
    b.opts = opts
    function b:start()
        self.layer = LM.minY
    end
    function b:status()
        return fmt("Building %s - layer %d of %d (%d placed, %d broken)", LM.schem and LM.schem.name or "?",
            (self.layer or LM.minY) - LM.minY + 1, LM.maxY - LM.minY + 1, self.placed, self.broken)
    end

    local function standingIn(t)
        local fx, fy, fz = NAV.feet()
        return fx == t[1] and fz == t[3] and (fy == t[2] or fy + 1 == t[2])
    end

    function b:pick(now)
        local ex, ey, ez = P.eye()
        local missingItems = {}
        local anyIncomplete = false
        local startLayer = S.buildInLayers and (self.layer or LM.minY) or LM.minY
        for layer = startLayer, LM.maxY do
            local i0 = LM.layerStart[layer]
            if i0 then
                local cands = {}
                local layerIncomplete = false
                local blocked = false
                local i = i0
                while LM.targets[i] and LM.targets[i][2] == layer do
                    local t = LM.targets[i]
                    local st, n = LM.state(t)
                    if st ~= "ok" then
                        layerIncomplete = true
                        local sk = self.skip[t[5]]
                        if sk and sk >= now and (self.fails[t[5]] or 0) < 4 then blocked = true end
                        if not sk or sk < now then
                            local act
                            if st == "missing" then
                                local item = K.itemForBlock(t[4])
                                if not HB.has(item) then
                                    missingItems[item] = true
                                elseif PF.hasSupport(t[1], t[2], t[3]) then
                                    act = "place"
                                end
                            elseif st == "wrong" and (S.buildBreakWrong or t[4] == "air") and not K.unbreakable(n) then
                                act = "break"
                            end
                            if act then
                                cands[#cands + 1] = { t = t, act = act, d = U.dist3(ex, ey, ez, t[1] + 0.5, t[2] + 0.5, t[3] + 0.5) }
                            end
                        end
                    end
                    i = i + 1
                end
                if #cands > 0 then
                    tsort(cands, function(a, b) return a.d < b.d end)
                    -- prefer something we can do without moving
                    for j = 1, min(#cands, 24) do
                        if cands[j].d <= S.buildReach + 0.5 and self:canActFromHere(cands[j].t, cands[j].act) then
                            return cands[j].t, cands[j].act, true
                        end
                    end
                    return cands[1].t, cands[1].act, false
                end
                if layerIncomplete then
                    anyIncomplete = true
                    if next(missingItems) and not S.buildIgnoreMissingItems then return "missing", missingItems end
                    -- don't build on top of a layer we are still working on
                    if blocked and S.buildInLayers then return nil end
                elseif S.buildInLayers and layer == self.layer then
                    self.layer = layer + 1
                end
            elseif S.buildInLayers and layer == self.layer then
                self.layer = layer + 1
            end
        end
        if next(missingItems) and not S.buildIgnoreMissingItems then return "missing", missingItems end
        if anyIncomplete then return nil end
        return "done"
    end

    function b:canActFromHere(t, act)
        if standingIn(t) then return false end
        if act == "place" then
            return ACT.findPlaceFace(t[1], t[2], t[3], S.buildReach) ~= nil
        end
        local _, _, _, dist = ACT.aimPoint(t[1], t[2], t[3])
        return dist <= S.buildReach
    end

    function b:tick(now)
        if not LM.schem then Bot.finish("No schematic loaded") return true end
        if self.phase == "act" then
            local c = self.cur
            local t = c.t
            local r
            if c.act == "place" then
                r = ACT.place(c.st, t[1], t[2], t[3], K.itemForBlock(t[4]), t[4])
            else
                c.st.protect = function(k) return opts.noBreak(k, W.fresh(U.unkey(k))) end
                r = ACT.mine(c.st, t[1], t[2], t[3])
            end
            if r == "running" then return true end
            IN.clear()
            if r == "done" then
                if c.act == "place" then self.placed = self.placed + 1 else self.broken = self.broken + 1 end
            elseif r == "wrong" then
                self.placed = self.placed + 1
                self.skip[t[5]] = now + 600000
                self.fails[t[5]] = 99
            else
                failTarget(t, now)
            end
            LM.ghostT = 0
            self.phase = "choose"
            return true
        end
        if self.phase == "travel" then
            if NAV.state == "arrived" or NAV.state == "idle" then
                NAV.stop()
                -- got there but still can't reach it (e.g. line of sight): try others first
                if self.cur and not self:canActFromHere(self.cur.t, self.cur.act) then
                    failTarget(self.cur.t, now)
                end
                self.phase = "choose"
            elseif NAV.state == "failed" then
                NAV.stop()
                failTarget(self.cur.t, now)
                self.phase = "choose"
            else
                -- arrived early? act as soon as the target is reachable
                if P.grounded and self.cur and self:canActFromHere(self.cur.t, self.cur.act) then
                    NAV.stop()
                    self.phase = "choose"
                else
                    return false
                end
            end
        end
        if self.phase == "choose" then
            local t, act, here = self:pick(now)
            if t == "done" then
                Bot.finish(fmt("Build complete (%d placed, %d broken)", self.placed, self.broken))
                return true
            elseif t == "missing" then
                local names = {}
                for it in pairs(act) do names[#names + 1] = it end
                tsort(names)
                U.chat("\194\167eMissing items in hotbar: " .. tconcat(names, ", ") .. ". Put them in your hotbar, then #resume.")
                Bot.paused = true
                HB.invalidate()
                Bot.queuePre(Proc.hotbarScan())
                return true
            elseif t == nil then
                if not self.waitMsgT or now - self.waitMsgT > 20000 then
                    if self.waitMsgT then U.chat("Some blocks are hard to reach - retrying") end
                    self.waitMsgT = now
                end
                IN.clear()
                return true
            end
            self.cur = { t = t, act = act, st = {} }
            if here then
                self.phase = "act"
                return true
            end
            if act == "place" then
                NAV.set(G.placeAt(t[1], t[2], t[3], S.buildReach - 0.5), opts)
            else
                NAV.set(G.breakAt(t[1], t[2], t[3], S.buildReach - 0.5), opts)
            end
            self.phase = "travel"
            return false
        end
        return false
    end
    function b:stop() NAV.stop() end
    return b
end

-- =====================================================================
-- #farm [range] [now]
-- Harvests and replants crops around where you start it.
-- Flarial only exposes block *names*, not growth stage, so wheat/carrots/
-- potatoes/beetroot/nether wart are treated as grown once
-- `farmGrowMinutes` have passed since the bot first saw or planted them
-- (#farm now harvests everything immediately). Pumpkins, melons, sugar
-- cane and bamboo are always detectable.
-- =====================================================================
local CROPS = {
    wheat = "wheat_seeds", carrots = "carrot", potatoes = "potato", beetroot = "beetroot_seeds",
    nether_wart = "nether_wart",
}
local SEED_TO_CROP = { wheat_seeds = "wheat", carrot = "carrots", potato = "potatoes", beetroot_seeds = "beetroot", nether_wart = "nether_wart" }
local ALWAYS = { pumpkin = true, melon_block = true, melon = true }
local STACKED = { reeds = true, sugar_cane = true, bamboo = true }

local Farm = { times = {}, lastCrop = {}, loadedFor = nil }

function Farm.file()
    local okn, wn = pcall(world.getWorldName)
    wn = (okn and wn and wn ~= "") and tostring(wn) or "world"
    wn = wn:gsub("[^%w_%-]", "_")
    return DIR .. "/farm_" .. wn .. "_" .. W.dim .. ".txt"
end

function Farm.load()
    local f = Farm.file()
    if Farm.loadedFor == f then return end
    Farm.loadedFor = f
    Farm.times, Farm.lastCrop = {}, {}
    local data = U.readFile(f)
    if not data then return end
    local now = U.now()
    for line in data:gmatch("[^\r\n]+") do
        local x, y, z, age, crop = line:match("^(%-?%d+),(%-?%d+),(%-?%d+)=(%d+),?(%w*)")
        if x then
            local k = U.key(tonumber(x), tonumber(y), tonumber(z))
            Farm.times[k] = now - tonumber(age)
            if crop and crop ~= "" then Farm.lastCrop[k] = crop end
        end
    end
end

function Farm.save()
    if not Farm.loadedFor then return end
    local now = U.now()
    local lines = {}
    for k, t in pairs(Farm.times) do
        local x, y, z = U.unkey(k)
        lines[#lines + 1] = fmt("%d,%d,%d=%d,%s", x, y, z, max(0, floor(now - t)), Farm.lastCrop[k] or "")
    end
    U.writeFile(Farm.loadedFor, tconcat(lines, "\n") .. "\n")
end

function Proc.farm(range, harvestNow)
    local f = { name = "farm", range = range or S.farmRange, phase = "scan", tasks = {}, harvested = 0, planted = 0,
        drops = {}, skip = {}, saveT = 0 }
    local function match(n)
        return CROPS[n] ~= nil or ALWAYS[n] or STACKED[n] or n == "farmland" or n == "soul_sand"
    end
    function f:start()
        local fx, fy, fz = NAV.feet()
        self.cx, self.cy, self.cz = fx, fy, fz
        Farm.load()
        if harvestNow then self.harvestNow = true end
        self:rescan()
    end
    function f:rescan()
        self.scan = Scanner.new(match, self.cx, self.cy, self.cz, self.range, 4)
        self.phase = "scan"
    end
    function f:status()
        local s = fmt("Farming r=%d (%d harvested, %d planted)", self.range, self.harvested, self.planted)
        if self.waitUntil then s = s .. fmt(" - next crop in %ds", max(0, floor((self.waitUntil - U.now()) / 1000))) end
        return s
    end
    function f:grown(k, n, now)
        if ALWAYS[n] then return true end
        if not CROPS[n] then return false end
        local t = Farm.times[k]
        if not t then
            if self.harvestNow then return true end
            Farm.times[k] = now
            Farm.lastCrop[k] = n
            return false
        end
        return now - t >= S.farmGrowMinutes * 60000
    end
    function f:seedFor(k)
        local crop = Farm.lastCrop[k]
        if crop and CROPS[crop] and HB.has(CROPS[crop]) then return CROPS[crop], crop end
        for seed, c in pairs(SEED_TO_CROP) do
            if HB.has(seed) and c ~= "nether_wart" then return seed, c end
        end
        return nil
    end
    function f:buildTasks(now)
        local tasks = {}
        local soonest
        for k, v in pairs(self.scan.found) do
            local x, y, z, n = v[1], v[2], v[3], W.fresh(v[1], v[2], v[3])
            if self.skip[k] and self.skip[k] > now then
                -- skip
            elseif CROPS[n] or ALWAYS[n] then
                if self:grown(k, n, now) then
                    tasks[#tasks + 1] = { x, y, z, "harvest", n, k }
                elseif Farm.times[k] then
                    local due = Farm.times[k] + S.farmGrowMinutes * 60000
                    if not soonest or due < soonest then soonest = due end
                end
            elseif STACKED[n] then
                -- harvest the 2nd block of a stack, keep the bottom one
                local below = W.fresh(x, y - 1, z)
                local below2 = W.fresh(x, y - 2, z)
                if below == n and below2 ~= n then tasks[#tasks + 1] = { x, y, z, "harvest", n, k } end
            elseif n == "farmland" or n == "soul_sand" then
                local above = W.fresh(x, y + 1, z)
                if K.isAir(above) then
                    local ak = U.key(x, y + 1, z)
                    if n == "soul_sand" then
                        if Farm.lastCrop[ak] == "nether_wart" and HB.has("nether_wart") then
                            tasks[#tasks + 1] = { x, y + 1, z, "plant", "nether_wart", ak }
                        end
                    elseif self:seedFor(ak) then
                        tasks[#tasks + 1] = { x, y + 1, z, "plant", nil, ak }
                    end
                end
            end
        end
        self.tasks = tasks
        self.waitUntil = (#tasks == 0) and soonest or nil
    end
    function f:tick(now)
        if now - self.saveT > 30000 then Farm.save() self.saveT = now end
        if self.phase == "scan" then
            IN.clear()
            if self.scan:step(S.mineScanBlocksPerFrame * 2) then
                self:buildTasks(now)
                self.harvestNow = false
                self.phase = "choose"
            end
            return true
        end
        if self.phase == "act" then
            local c = self.cur
            local r
            if c[4] == "harvest" then
                self.st.breakPlants = true
                r = ACT.mine(self.st, c[1], c[2], c[3])
            else
                local seed, crop = self:seedFor(c[6])
                if c[5] == "nether_wart" then seed, crop = "nether_wart", "nether_wart" end
                if not seed then r = "noitem" else
                    r = ACT.place(self.st, c[1], c[2], c[3], seed)
                    self.plantCrop = crop
                end
            end
            if r == "running" then return true end
            IN.clear()
            local k = c[6]
            if r == "done" then
                if c[4] == "harvest" then
                    self.harvested = self.harvested + 1
                    if CROPS[c[5]] then
                        Farm.lastCrop[k] = c[5]
                        Farm.times[k] = nil
                        -- replant straight away
                        if self:seedFor(k) then
                            self.cur = { c[1], c[2], c[3], "plant", c[5] == "nether_wart" and "nether_wart" or nil, k }
                            self.st = {}
                            return true
                        end
                    end
                    self.drops[#self.drops + 1] = { c[1], c[2], c[3] }
                else
                    self.planted = self.planted + 1
                    Farm.times[k] = now
                    if self.plantCrop then Farm.lastCrop[k] = self.plantCrop end
                    self.drops[#self.drops + 1] = { c[1], c[2], c[3] }
                end
            else
                self.skip[k] = now + 60000
            end
            self.phase = "choose"
            return true
        end
        if self.phase == "travel" or self.phase == "collect" then
            if NAV.state == "arrived" or NAV.state == "failed" or NAV.state == "idle" then
                if NAV.state == "failed" and self.phase == "travel" and self.cur then self.skip[self.cur[6]] = now + 60000 end
                NAV.stop()
                self.phase = "choose"
            else
                return false
            end
        end
        if self.phase == "choose" then
            -- drop task list entries that are done
            local fx, fy, fz = NAV.feet()
            local ex, ey, ez = P.eye()
            local best, bestD
            for _, t in ipairs(self.tasks) do
                if not (self.skip[t[6]] and self.skip[t[6]] > now) then
                    local n = W.fresh(t[1], t[2], t[3])
                    local valid = (t[4] == "harvest" and n == t[5]) or (t[4] == "plant" and K.isAir(n))
                    if valid then
                        local d = U.dist3(ex, ey, ez, t[1] + 0.5, t[2] + 0.5, t[3] + 0.5)
                        if not best or d < bestD then best, bestD = t, d end
                    end
                end
            end
            if best then
                self.cur = best
                self.st = {}
                local reach = S.buildReach
                if bestD <= reach - 0.3 and (best[4] == "harvest" or ACT.findPlaceFace(best[1], best[2], best[3], reach)) then
                    self.phase = "act"
                    return true
                end
                NAV.set(G.reach(best[1], best[2], best[3], reach - 1))
                self.phase = "travel"
                return false
            end
            -- pick up drops
            if #self.drops > 0 then
                local d = tremove(self.drops)
                if not (fx == d[1] and fz == d[3]) then
                    NAV.set(G.near(d[1], d[2], d[3], 0.6))
                    self.phase = "collect"
                    return false
                end
                return true
            end
            -- nothing to do: wait, then rescan
            IN.clear()
            if not self.idleT then self.idleT = now end
            if now - self.idleT > 8000 then
                self.idleT = nil
                self:rescan()
            end
            return true
        end
        return false
    end
    function f:stop() Farm.save() NAV.stop() end
    return f
end

-- =====================================================================
-- #elytra [x z]  - fly to a destination with an elytra and fireworks
-- =====================================================================
function Proc.elytra(gx, gz)
    local e = { name = "elytra", gx = gx, gz = gz, phase = "check", lastFirework = 0, t = 0, deployTries = 0 }
    function e:status()
        local d = floor(U.dist2(P.x, P.z, self.gx, self.gz))
        local fw = HB.slotOf("firework_rocket") and "" or ", no fireworks"
        return fmt("Elytra to %s (%d blocks, %s%s)", U.fmtPos(self.gx, self.gz), d, self.phase, fw)
    end

    -- highest solid block near (x,z) between y-48 and y+24 (only loaded chunks)
    function e:terrainTop(x, z, y)
        x, z = floor(x), floor(z)
        if not W.loaded(x, z, floor(y)) then return nil end
        for yy = floor(y) + 24, floor(y) - 48, -2 do
            local n = W.get(x, yy, z)
            if not K.passable(n) then
                if not K.passable(W.get(x, yy + 1, z)) then return yy + 1 end
                return yy
            end
        end
        return nil
    end

    function e:useFirework(now)
        local slot = HB.slotOf("firework_rocket")
        if not slot then return false end
        if now - self.lastFirework < S.elytraFireworkDelayMS then return false end
        IN.select(slot)
        if P.slot == slot then
            IN.click()
            self.lastFirework = now
            return true
        end
        return false
    end

    function e:tick(now)
        IN.clear()
        local yawToGoal = U.yawTo(P.x, P.z, self.gx, self.gz)
        local dist = U.dist2(P.x, P.z, self.gx, self.gz)
        if self.phase == "check" then
            if P.chest ~= "elytra" then
                Bot.finish("\194\167cWear an elytra first")
                return true
            end
            if not HB.slotOf("firework_rocket") then
                U.chat("\194\167eNo fireworks in hotbar - gliding only")
            end
            self.startY = P.y
            self.phase = P.grounded and "takeoff" or "deploy"
            self.t = now
            return true
        end
        if self.phase == "takeoff" then
            IN.look(yawToGoal, -15)
            if P.grounded then
                if now - self.t > 250 then IN.press("jump") end
            elseif P.vy < -0.05 then
                self.phase = "deploy"
                self.t = now
            end
            return true
        end
        if self.phase == "deploy" then
            IN.look(yawToGoal, -15)
            if P.grounded then
                self.deployTries = self.deployTries + 1
                if self.deployTries > 3 then Bot.finish("\194\167cCouldn't take off - need more height or space") return true end
                self.phase = "takeoff"
                self.t = now
                return true
            end
            if now - self.t < 120 then
                IN.press("jump")
            elseif now - self.t > 450 then
                -- assume we're gliding once falling slowly / moving fast
                self.phase = "boost"
                self.t = now
            end
            return true
        end
        if self.phase == "boost" then
            IN.look(yawToGoal, -40)
            if P.pitch < -30 then self:useFirework(now) end
            if now - self.t > 1200 or not HB.slotOf("firework_rocket") then
                self.phase = "cruise"
            end
            return true
        end
        if self.phase == "cruise" or self.phase == "land" then
            if P.grounded and now - self.t > 1500 then
                if dist < 12 then
                    Bot.finish("Landed at destination")
                else
                    -- landed early: take off again
                    self.phase = "takeoff"
                    self.t = now
                end
                return true
            end
            local hx, hz = U.dirFromYaw(yawToGoal)
            local ground = self:terrainTop(P.x, P.z, P.y) or (P.y - 30)
            local ahead = ground
            for _, d in ipairs({ 8, 16, 32, 48 }) do
                local tt = self:terrainTop(P.x + hx * d, P.z + hz * d, P.y)
                if tt and tt > ahead then ahead = tt end
            end
            local cruiseY = max((self.startY or P.y) + S.elytraCruiseHeight, ahead + 16)
            if W.dim == "nether" then cruiseY = min(cruiseY, 118) end
            if dist < S.elytraLandDistance and S.elytraAutoLand then self.phase = "land" end

            local pitch
            if self.phase == "land" then
                local gy = self:terrainTop(self.gx, self.gz, P.y) or ground
                local above = P.y - (ground + 1)
                if dist > 6 then
                    pitch = U.clamp(U.pitchTo(P.x, P.y, P.z, self.gx + 0.5, gy + 1, self.gz + 0.5), 5, 35)
                else
                    pitch = 25
                end
                if above < 4 then pitch = 0 end
            else
                local err = cruiseY - P.y
                if err > 3 then pitch = -25
                elseif err < -6 then pitch = 18
                else pitch = 3 end
                -- obstacle directly ahead?
                for _, d in ipairs({ 3, 6, 10 }) do
                    local n = W.get(floor(P.x + hx * d), floor(P.y + 0.5), floor(P.z + hz * d))
                    if not K.passable(n) then pitch = -45 break end
                end
                local speed = P.horizSpeed()
                if (speed < S.elytraMinSpeed or err > 6 or pitch <= -40) and P.pitch < -15 then
                    self:useFirework(now)
                end
            end
            IN.look(yawToGoal, pitch)
            return true
        end
        return true
    end
    function e:stop() IN.clear() end
    return e
end

-- =====================================================================
-- Rendering: path, goal, targets and schematic ghost blocks.
-- Runs in RenderEvent (no player API calls there, only cached data and
-- world.worldToScreen).
-- =====================================================================
local REN = { frame = 0 }

local function w2s(x, y, z)
    local ok, vis, sx, sy = pcall(world.worldToScreen, x, y, z)
    if ok and vis and sx then return sx, sy end
    return nil
end

local function line(dl, a, b, color, th)
    local ax, ay = w2s(a[1], a[2], a[3])
    if not ax then return end
    local bx, by = w2s(b[1], b[2], b[3])
    if not bx then return end
    dl:AddLine({ ax, ay }, { bx, by }, color, th)
end

local BOX_EDGES = {
    { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 }, { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
}

local function box(dl, x1, y1, z1, x2, y2, z2, color, th)
    local c = {
        { x1, y1, z1 }, { x2, y1, z1 }, { x2, y1, z2 }, { x1, y1, z2 },
        { x1, y2, z1 }, { x2, y2, z1 }, { x2, y2, z2 }, { x1, y2, z2 },
    }
    local s = {}
    for i = 1, 8 do
        local sx, sy = w2s(c[i][1], c[i][2], c[i][3])
        if sx then s[i] = { sx, sy } end
    end
    for _, e in ipairs(BOX_EDGES) do
        local a, b = s[e[1]], s[e[2]]
        if a and b then dl:AddLine(a, b, color, th) end
    end
end

function REN.draw()
    local okDl, dl = pcall(ImGui.GetBackgroundDrawList)
    if not okDl or not dl then return end
    REN.frame = REN.frame + 1

    -- path
    if S.renderPath and NAV.path and (NAV.state == "exec" or NAV.state == "plan") then
        local col = Settings.color("colorCurrentPath", 230)
        local done = Settings.color("colorCurrentPath", 70)
        local th = S.pathThickness
        local path = NAV.path
        local from = max(1, NAV.idx - 1)
        local to = min(#path, NAV.idx + 120)
        for i = from, to - 1 do
            local a, b = path[i], path[i + 1]
            line(dl, { a.x + 0.5, a.y + 0.08, a.z + 0.5 }, { b.x + 0.5, b.y + 0.08, b.z + 0.5 }, (i < NAV.idx) and done or col, th)
        end
    end

    -- goal
    local goal = NAV.goal
    if S.renderGoal and goal and NAV.state ~= "idle" then
        local col = Settings.color("colorGoalBox", 230)
        local list = goal.list or { goal }
        for i = 1, min(#list, 16) do
            local g = list[i]
            if g.kind == "block" or g.kind == "near" then
                box(dl, g.x, g.y, g.z, g.x + 1, g.y + (g.kind == "near" and 1 or 2), g.z + 1, col, 2)
            elseif g.kind == "xz" then
                line(dl, { g.x + 0.5, REN.py - 30, g.z + 0.5 }, { g.x + 0.5, REN.py + 60, g.z + 0.5 }, col, 3)
            elseif g.kind == "y" then
                local r = 2
                box(dl, REN.px - r, g.y, REN.pz - r, REN.px + r, g.y + 0.02, REN.pz + r, col, 2)
            end
        end
    end

    -- mining / farming targets
    if S.renderSelectionBoxes and Bot.proc and Bot.proc.known then
        local col = Settings.color("colorMineTarget", 200)
        local n = 0
        for _, v in pairs(Bot.proc.known) do
            if abs(v[1] - REN.px) < 32 and abs(v[3] - REN.pz) < 32 then
                box(dl, v[1], v[2], v[3], v[1] + 1, v[2] + 1, v[3] + 1, col, 1.5)
                n = n + 1
                if n > 64 then break end
            end
        end
    end

    -- litematica ghost blocks
    if S.litematicaRender and LM.schem then
        local cMissing = { 90, 170, 255, 170 }
        local cWrong = { 255, 60, 60, 200 }
        for _, gb in ipairs(LM.ghosts) do
            local col = (gb[4] == "missing") and cMissing or cWrong
            local inset = 0.03
            box(dl, gb[1] + inset, gb[2] + inset, gb[3] + inset, gb[1] + 1 - inset, gb[2] + 1 - inset, gb[3] + 1 - inset, col, 1.2)
        end
        -- placement outline
        local sx, sy, sz = LM.size()
        box(dl, LM.ox, LM.oy, LM.oz, LM.ox + sx, LM.oy + sy, LM.oz + sz, { 255, 255, 255, 90 }, 1)
    end

    -- status line
    if S.renderHud and (Bot.isActive() or Bot.paused) then
        local okF, fg = pcall(ImGui.GetForegroundDrawList)
        if okF and fg then
            local text = "Baritone: " .. (REN.status or "")
            if not Helper.connected then text = text .. "  [helper not running]" end
            fg:AddText({ 12, 12 }, { 0, 0, 0, 170 }, 18, text)
            fg:AddText({ 11, 11 }, { 230, 120, 255, 255 }, 18, text)
        end
    end
end

-- ---------------------------------------------------------------------
-- DLL: world-space line list drawn by the game's renderer
-- ---------------------------------------------------------------------
REN.next3d = 0
REN.lastStatus = nil

local function pushLine(t, x1, y1, z1, x2, y2, z2, c)
    local n = #t
    t[n + 1], t[n + 2], t[n + 3], t[n + 4], t[n + 5], t[n + 6] = x1, y1, z1, x2, y2, z2
    t[n + 7], t[n + 8], t[n + 9], t[n + 10] = c[1], c[2], c[3], c[4]
end

local function pushBox(t, x1, y1, z1, x2, y2, z2, c)
    pushLine(t, x1, y1, z1, x2, y1, z1, c) pushLine(t, x2, y1, z1, x2, y1, z2, c)
    pushLine(t, x2, y1, z2, x1, y1, z2, c) pushLine(t, x1, y1, z2, x1, y1, z1, c)
    pushLine(t, x1, y2, z1, x2, y2, z1, c) pushLine(t, x2, y2, z1, x2, y2, z2, c)
    pushLine(t, x2, y2, z2, x1, y2, z2, c) pushLine(t, x1, y2, z2, x1, y2, z1, c)
    pushLine(t, x1, y1, z1, x1, y2, z1, c) pushLine(t, x2, y1, z1, x2, y2, z1, c)
    pushLine(t, x2, y1, z2, x2, y2, z2, c) pushLine(t, x1, y1, z2, x1, y2, z2, c)
end

function REN.build3d()
    local t = {}
    if S.renderPath and NAV.path and (NAV.state == "exec" or NAV.state == "plan") then
        local col = Settings.color("colorCurrentPath", 255)
        local done = Settings.color("colorCurrentPath", 90)
        local path = NAV.path
        local from = max(1, NAV.idx - 1)
        local to = min(#path, NAV.idx + 150)
        for i = from, to - 1 do
            local a, b = path[i], path[i + 1]
            pushLine(t, a.x + 0.5, a.y + 0.08, a.z + 0.5, b.x + 0.5, b.y + 0.08, b.z + 0.5, (i < NAV.idx) and done or col)
        end
    end
    local goal = NAV.goal
    if S.renderGoal and goal and NAV.state ~= "idle" then
        local col = Settings.color("colorGoalBox", 255)
        local list = goal.list or { goal }
        for i = 1, min(#list, 16) do
            local g = list[i]
            if g.kind == "block" or g.kind == "near" then
                pushBox(t, g.x, g.y, g.z, g.x + 1, g.y + (g.kind == "near" and 1 or 2), g.z + 1, col)
            elseif g.kind == "xz" then
                pushLine(t, g.x + 0.5, P.y - 30, g.z + 0.5, g.x + 0.5, P.y + 60, g.z + 0.5, col)
            elseif g.kind == "y" then
                pushBox(t, P.x - 2, g.y, P.z - 2, P.x + 2, g.y + 0.02, P.z + 2, col)
            end
        end
    end
    if S.renderSelectionBoxes and Bot.proc and Bot.proc.known then
        local col = Settings.color("colorMineTarget", 230)
        local n = 0
        for _, v in pairs(Bot.proc.known) do
            if abs(v[1] - P.x) < 32 and abs(v[3] - P.z) < 32 then
                pushBox(t, v[1], v[2], v[3], v[1] + 1, v[2] + 1, v[3] + 1, col)
                n = n + 1
                if n > 64 then break end
            end
        end
    end
    if S.litematicaRender and LM.schem then
        local cMissing = { 90, 170, 255, 200 }
        local cWrong = { 255, 60, 60, 230 }
        local inset = 0.03
        for _, gb in ipairs(LM.ghosts) do
            pushBox(t, gb[1] + inset, gb[2] + inset, gb[3] + inset, gb[1] + 1 - inset, gb[2] + 1 - inset, gb[3] + 1 - inset,
                (gb[4] == "missing") and cMissing or cWrong)
        end
        local sx, sy, sz = LM.size()
        pushBox(t, LM.ox, LM.oy, LM.oz, LM.ox + sx, LM.oy + sy, LM.oz + sz, { 255, 255, 255, 120 })
    end
    return t
end

function REN.update3d(now)
    if now >= REN.next3d then
        REN.next3d = now + 100
        pcall(native.setLines, REN.build3d())
    end
    local visible = S.renderHud and (Bot.isActive() or Bot.paused)
    local text = REN.status or ""
    if text ~= REN.lastStatus or visible ~= REN.lastVisible then
        REN.lastStatus, REN.lastVisible = text, visible
        pcall(native.setStatus, text, visible)
    end
end

-- =====================================================================
-- Waypoints
-- =====================================================================
local WP = { list = {}, loaded = false }
local WP_FILE = DIR .. "/waypoints.txt"

function WP.load()
    WP.list = {}
    WP.loaded = true
    local data = U.readFile(WP_FILE)
    if not data then return end
    for line in data:gmatch("[^\r\n]+") do
        local n, x, y, z, d = line:match("^([^=]+)=(%-?%d+),(%-?%d+),(%-?%d+),?(%w*)")
        if n then WP.list[n:lower()] = { name = n, x = tonumber(x), y = tonumber(y), z = tonumber(z), dim = (d ~= "" and d or "overworld") } end
    end
end

function WP.save()
    local lines = {}
    for _, w in pairs(WP.list) do lines[#lines + 1] = fmt("%s=%d,%d,%d,%s", w.name, w.x, w.y, w.z, w.dim) end
    tsort(lines)
    U.writeFile(WP_FILE, tconcat(lines, "\n") .. "\n")
end

-- =====================================================================
-- Commands
-- =====================================================================
local CMD = { list = {}, byName = {} }

local function def(names, usage, desc, fn)
    local c = { names = names, usage = usage, desc = desc, fn = fn }
    CMD.list[#CMD.list + 1] = c
    for _, n in ipairs(names) do CMD.byName[n] = c end
end

-- parse a coordinate, supporting ~ relative values
local function coord(s, base)
    if s == nil then return nil end
    if s:sub(1, 1) == "~" then
        local rest = s:sub(2)
        if rest == "" then return floor(base) end
        local v = tonumber(rest)
        if not v then return nil end
        return floor(base + v)
    end
    local v = tonumber(s)
    if not v then return nil end
    return floor(v)
end

local function parseGoal(args, i)
    i = i or 1
    local fx, fy, fz = NAV.feet()
    local a, b, c = args[i], args[i + 1], args[i + 2]
    if a and b and c then
        local x, y, z = coord(a, fx), coord(b, fy), coord(c, fz)
        if x and y and z then return G.block(x, y, z) end
    end
    if a and b then
        local x, z = coord(a, fx), coord(b, fz)
        if x and z then return G.xz(x, z) end
    end
    if a then
        local y = coord(a, fy)
        if y then return G.y(y) end
    end
    return nil
end

local savedGoal = nil

def({ "help", "?" }, "help [command]", "List commands or show help for one", function(args)
    if args[1] then
        local c = CMD.byName[args[1]:lower()]
        if not c then U.chat("Unknown command: " .. args[1]) return end
        U.chat(S.prefix .. c.usage .. " \194\1677- " .. c.desc)
        if #c.names > 1 then U.chat("Aliases: " .. tconcat(c.names, ", ")) end
        return
    end
    local names = {}
    for _, c in ipairs(CMD.list) do names[#names + 1] = c.names[1] end
    U.chat("Baritone for Bedrock " .. VERSION .. " (prefix " .. S.prefix .. ", or .b <command>)")
    U.chat("\194\167b" .. tconcat(names, ", "))
    U.chat("\194\1677" .. S.prefix .. "help <command> for details, e.g. " .. S.prefix .. "help mine")
end)

def({ "goto" }, "goto <x y z | x z | y | block>", "Walk somewhere (supports ~ relative coords)", function(args)
    if #args == 0 then U.chat("Usage: " .. S.prefix .. "goto x y z") return end
    local goal = parseGoal(args)
    if goal then
        Bot.start(Proc.go(goal))
        return
    end
    Bot.start(Proc.gotoBlock(args[1]))
end)

def({ "goal" }, "goal [x y z | x z | y | clear]", "Set a goal for #path (no args = your position)", function(args)
    if args[1] == "clear" or args[1] == "none" then savedGoal = nil U.chat("Goal cleared") return end
    local goal
    if #args == 0 then
        local fx, fy, fz = NAV.feet()
        goal = G.block(fx, fy, fz)
    else
        goal = parseGoal(args)
    end
    if not goal then U.chat("Couldn't parse that goal") return end
    savedGoal = goal
    U.chat("Goal: " .. goal.desc)
end)

def({ "path" }, "path", "Path to the goal set with #goal", function(args)
    if not savedGoal then U.chat("No goal set - use " .. S.prefix .. "goal first") return end
    Bot.start(Proc.go(savedGoal))
end)

def({ "thisway", "forward" }, "thisway <distance>", "Go that many blocks in the direction you face", function(args)
    local d = tonumber(args[1] or "") or 100
    local dx, dz = U.dirFromYaw(P.yaw)
    local fx, _, fz = NAV.feet()
    Bot.start(Proc.go(G.xz(floor(fx + dx * d + 0.5), floor(fz + dz * d + 0.5))))
end)

def({ "mine" }, "mine <block> [block...] [count]", "Mine blocks, e.g. #mine diamond_ore 10", function(args)
    if #args == 0 then U.chat("Usage: " .. S.prefix .. "mine diamond_ore [count]") return end
    local names, count = {}, nil
    for _, a in ipairs(args) do
        local n = tonumber(a)
        if n then count = floor(n) else names[#names + 1] = a end
    end
    if #names == 0 then U.chat("Which block?") return end
    Bot.start(Proc.mine(names, count))
end)

def({ "follow" }, "follow <player> | player <name> | players | entity <type>", "Follow a player or mob (experimental)", function(args)
    local a = (args[1] or ""):lower()
    if a == "" then U.chat("Usage: " .. S.prefix .. "follow <player name>") return end
    if a == "players" then Bot.start(Proc.follow("players"))
    elseif a == "player" and args[2] then Bot.start(Proc.follow("player", args[2]))
    elseif (a == "entity" or a == "entities") then Bot.start(Proc.follow("entity", args[2] and U.bare(args[2]) or nil))
    else Bot.start(Proc.follow("player", args[1])) end
end)

def({ "farm" }, "farm [range] [now]", "Harvest and replant crops around you", function(args)
    local range, now = nil, false
    for _, a in ipairs(args) do
        if tonumber(a) then range = floor(tonumber(a)) elseif a:lower() == "now" then now = true end
    end
    Bot.start(Proc.farm(range, now))
end)

def({ "elytra" }, "elytra [x z]", "Fly to x z (or the #goal) with an elytra + fireworks", function(args)
    local x, z
    local fx, _, fz = NAV.feet()
    if args[1] and args[2] then
        x, z = coord(args[1], fx), coord(args[2], fz)
    elseif savedGoal and savedGoal.x and savedGoal.z then
        x, z = savedGoal.x, savedGoal.z
    end
    if not x or not z then U.chat("Usage: " .. S.prefix .. "elytra x z") return end
    Bot.start(Proc.elytra(x, z))
end)

def({ "tunnel" }, "tunnel [length]", "Dig a 1x2 tunnel the way you face", function(args)
    Bot.start(Proc.tunnel(tonumber(args[1] or "") or 64))
end)

-- ---------------------------- schematics ---------------------------
local pendingLoad = nil

local function loadSchematic(nameArg, ox, oy, oz, thenBuild)
    local f = SCH.find(nameArg)
    if not f then
        U.chat("No schematic called '" .. nameArg .. "'. Put .litematic / .mcstructure / .schem / .nbt files in "
            .. SCHEM_FOLDER_SHOWN)
        return
    end
    local fx, fy, fz = NAV.feet()
    pendingLoad = { f = f, ox = ox or fx, oy = oy or fy, oz = oz or fz, build = thenBuild, t = U.now(), co = nil }
    U.chat("Loading " .. f.file .. "...")
end

function CMD.pollLoad(now, budgetMs)
    local pl = pendingLoad
    if not pl then return end
    if not pl.co then
        if now - (pl.lastTry or 0) < 700 then return end
        pl.lastTry = now
        local hexPath = CACHE_DIR .. "/" .. pl.f.file .. ".hex"
        local txt = SCH.nativeRead() and "END" or U.readFile(hexPath)
        if not txt or not txt:find("END", -16, true) then
            if now - pl.t > 12000 then
                U.chat("\194\167cBaritoneHelper hasn't converted " .. pl.f.file .. " yet - is it running?")
                pendingLoad = nil
            end
            return
        end
        if coroutine and coroutine.create then
            pl.co = coroutine.create(function() return SCH.load(pl.f) end)
        else
            local s, err = SCH.load(pl.f)
            pl.result, pl.err = s, err
        end
    end
    if pl.co then
        local t0 = U.now()
        while coroutine.status(pl.co) ~= "dead" and U.now() - t0 < budgetMs do
            local ok, s, err = coroutine.resume(pl.co)
            if not ok then pl.result, pl.err = nil, tostring(s) break end
            if coroutine.status(pl.co) == "dead" then pl.result, pl.err = s, err end
        end
        if coroutine.status(pl.co) ~= "dead" and not pl.err then return end
    end
    pendingLoad = nil
    if not pl.result then
        U.chat("\194\167cCouldn't load " .. pl.f.file .. ": " .. tostring(pl.err))
        return
    end
    local s = pl.result
    LM.set(s, pl.ox, pl.oy, pl.oz)
    U.chat(fmt("Loaded %s (%dx%dx%d, %d blocks) at %s", s.name, s.sx, s.sy, s.sz, #LM.targets, U.fmtPos(LM.ox, LM.oy, LM.oz)))
    if pl.build then Bot.start(Proc.build()) end
end

def({ "build" }, "build <file> [x y z]", "Load a schematic and build it (origin = your feet)", function(args)
    if not args[1] then U.chat("Usage: " .. S.prefix .. "build <file> [x y z]") return end
    local fx, fy, fz = NAV.feet()
    local x, y, z = coord(args[2], fx), coord(args[3], fy), coord(args[4], fz)
    loadSchematic(args[1], x, y, z, true)
end)

local function lmCmd(args)
    local sub = (args[1] or ""):lower()
    local fx, fy, fz = NAV.feet()
    if sub == "" or sub == "build" then
        if not LM.schem then U.chat("No schematic loaded - " .. S.prefix .. "lm load <file>") return end
        Bot.start(Proc.build())
    elseif sub == "list" then
        local files = SCH.listFiles()
        if #files == 0 then U.chat("No schematics. Put files in " .. SCHEM_FOLDER_SHOWN) return end
        for _, f in ipairs(files) do U.chat(" - " .. f.file) end
    elseif sub == "load" then
        if not args[2] then U.chat("Usage: " .. S.prefix .. "lm load <file> [x y z]") return end
        loadSchematic(args[2], coord(args[3], fx), coord(args[4], fy), coord(args[5], fz), false)
    elseif not LM.schem then
        U.chat("No schematic loaded - " .. S.prefix .. "lm load <file>")
    elseif sub == "here" then
        LM.ox, LM.oy, LM.oz = fx, fy, fz
        LM.rebuild()
        U.chat("Moved placement to " .. U.fmtPos(fx, fy, fz))
    elseif sub == "origin" or sub == "pos" then
        local x, y, z = coord(args[2], fx), coord(args[3], fy), coord(args[4], fz)
        if not (x and y and z) then U.chat("Usage: " .. S.prefix .. "lm origin x y z") return end
        LM.ox, LM.oy, LM.oz = x, y, z
        LM.rebuild()
        U.chat("Placement origin " .. U.fmtPos(x, y, z))
    elseif sub == "move" or sub == "nudge" then
        LM.ox = LM.ox + (tonumber(args[2] or "0") or 0)
        LM.oy = LM.oy + (tonumber(args[3] or "0") or 0)
        LM.oz = LM.oz + (tonumber(args[4] or "0") or 0)
        LM.rebuild()
        U.chat("Placement origin " .. U.fmtPos(LM.ox, LM.oy, LM.oz))
    elseif sub == "rotate" then
        local deg = tonumber(args[2] or "90") or 90
        LM.rot = (LM.rot + floor(deg / 90) * 90) % 360
        LM.rebuild()
        U.chat("Rotation " .. LM.rot .. " (block facing is not rotated)")
    elseif sub == "mirror" then
        local axis = (args[2] or "x"):lower()
        if axis ~= "x" and axis ~= "z" and axis ~= "none" then U.chat("Usage: " .. S.prefix .. "lm mirror x|z|none") return end
        LM.mirror = (axis ~= "none") and axis or nil
        LM.rebuild()
        U.chat("Mirror " .. axis)
    elseif sub == "layer" then
        local a = args[2]
        if not a or a == "all" then LM.layer = nil U.chat("Showing all layers")
        else
            local y = coord(a, fy)
            if a:sub(1, 1) ~= "~" and tonumber(a) and tonumber(a) < LM.schem.sy and tonumber(a) >= 0 then y = LM.oy + floor(tonumber(a)) end
            LM.layer = y
            U.chat("Showing layer y=" .. y)
        end
        LM.ghostT = 0
    elseif sub == "render" then
        S.litematicaRender = not S.litematicaRender
        Settings.save()
        U.chat("Ghost blocks " .. (S.litematicaRender and "on" or "off"))
    elseif sub == "materials" or sub == "mats" then
        local counts = {}
        for _, t in ipairs(LM.targets) do
            if t[4] ~= "air" and LM.state(t) ~= "ok" then
                local it = K.itemForBlock(t[4])
                counts[it] = (counts[it] or 0) + 1
            end
        end
        local list = {}
        for it, c in pairs(counts) do list[#list + 1] = { it, c } end
        tsort(list, function(a, b) return a[2] > b[2] end)
        if #list == 0 then U.chat("Nothing left to place") return end
        U.chat("Still needed (" .. #list .. " types):")
        for i = 1, min(#list, 20) do
            local it, c = list[i][1], list[i][2]
            local mark = HB.has(it) and "\194\167a[hotbar]" or "\194\167c[missing]"
            U.chat(fmt(" %s x%d (%.1f stacks) %s", it, c, c / 64, mark))
        end
    elseif sub == "verify" then
        local ok, missing, wrong = LM.verify()
        U.chat(fmt("%s: %d correct, %d missing, %d wrong", LM.schem.name, ok, missing, wrong))
    elseif sub == "info" then
        local sx, sy, sz = LM.size()
        U.chat(fmt("%s %dx%dx%d at %s rot %d mirror %s", LM.schem.name, sx, sy, sz, U.fmtPos(LM.ox, LM.oy, LM.oz), LM.rot, LM.mirror or "none"))
    elseif sub == "unload" then
        LM.unload()
        U.chat("Schematic unloaded")
    else
        U.chat("lm subcommands: list, load, here, origin, move, rotate, mirror, layer, render, materials, verify, info, build, unload")
    end
end

def({ "litematica", "lm", "schematica" }, "lm <list|load|here|origin|move|rotate|mirror|layer|materials|verify|build|unload>",
    "Litematica-style schematic preview & placement (no args = build it)", lmCmd)

-- ---------------------------- control --------------------------------
def({ "stop", "cancel", "forcecancel" }, "stop", "Stop everything", function(args)
    Bot.stopAll(false)
    Bot.paused = false
end)

def({ "pause" }, "pause", "Pause the current process", function(args)
    Bot.paused = true
    IN.clear()
    U.chat("Paused")
end)

def({ "resume" }, "resume", "Resume a paused process", function(args)
    if not Helper.connected then U.chat("\194\167eBaritoneHelper.exe still isn't running") end
    Bot.paused = false
    if Bot.proc then
        if Helper.connected and not IN.calibrated() then Bot.queuePre(Proc.calibrate()) end
        if Helper.connected and not HB.complete() then Bot.queuePre(Proc.hotbarScan()) end
        if NAV.state == "failed" then NAV.replan(0) end
    end
    U.chat("Resumed")
end)

def({ "calibrate" }, "calibrate", "Re-measure mouse sensitivity", function(args)
    if NATIVE and not IN.turnMode() then
        U.chat("No calibration needed: the DLL sets your rotation directly (rotationMode = set).")
        return
    end
    S.mouseYawPerPixel, S.mousePitchPerPixel = 0, 0
    if not Helper.connected then U.chat("\194\167cStart BaritoneHelper.exe first") return end
    Bot.stopAll(true)
    Bot.paused = false
    Bot.queuePre(Proc.calibrate())
end)

def({ "hotbar" }, "hotbar", "Rescan and list your hotbar", function(args)
    if NATIVE then
        HB.invalidate()
        HB.observe()
        U.chat("Hotbar: " .. HB.list())
        return
    end
    if not Helper.connected then U.chat("Hotbar (known so far): " .. HB.list()) return end
    HB.invalidate()
    Bot.paused = false
    Bot.queuePre(Proc.hotbarScan(true))
end)

def({ "status", "version" }, "status", "Show what Baritone is doing", function(args)
    if NATIVE then
        U.chat(fmt("v%s (%s) | %s | rotation %s | focused %s | nav %s %s", VERSION, Helper.version, Bot.status(),
            S.rotationMode, tostring(Helper.focus), NAV.state, NAV.info))
        return
    end
    U.chat(fmt("v%s | %s | helper %s | mouse %s | nav %s %s", VERSION, Bot.status(),
        Helper.connected and ("connected " .. Helper.version) or "\194\167cnot running\194\167r",
        IN.calibrated() and "calibrated" or "not calibrated", NAV.state, NAV.info))
end)

-- ---------------------------- settings -------------------------------
def({ "set", "setting" }, "set [name] [value] | set reset [name]", "Change settings (saved automatically)", function(args)
    if #args == 0 then
        local mods = {}
        for _, d in ipairs(SDEF) do if Settings.isModified(d) then mods[#mods + 1] = d.name .. "=" .. Settings.toString(d) end end
        if #mods == 0 then U.chat("All settings are default. " .. S.prefix .. "settings to list them") return end
        U.chat("Modified: " .. tconcat(mods, ", "))
        return
    end
    if args[1]:lower() == "reset" then
        if args[2] then
            local d = Settings.find(args[2])
            if not d then U.chat("Unknown setting " .. args[2]) return end
            S[d.name] = d.default
            U.chat(d.name .. " reset to " .. Settings.toString(d))
        else
            for _, d in ipairs(SDEF) do
                if d.name ~= "mouseYawPerPixel" and d.name ~= "mousePitchPerPixel" then S[d.name] = d.default end
            end
            U.chat("All settings reset")
        end
        Settings.save()
        return
    end
    local d = Settings.find(args[1])
    if not d then U.chat("Unknown setting " .. args[1] .. ". " .. S.prefix .. "settings lists them") return end
    if not args[2] then
        if d.type == "bool" then
            S[d.name] = not S[d.name]
            Settings.save()
            U.chat(d.name .. " = " .. tostring(S[d.name]))
        else
            U.chat(d.name .. " = " .. Settings.toString(d) .. " \194\1677(" .. d.type .. ") " .. d.desc)
        end
        return
    end
    local raw = tconcat(args, " ", 2)
    local v, err = Settings.parseValue(d, raw)
    if v == nil then U.chat("Bad value for " .. d.name .. ": " .. err) return end
    S[d.name] = v
    Settings.save()
    K.reset()
    U.chat(d.name .. " = " .. Settings.toString(d))
end)

def({ "modified" }, "modified", "List settings you have changed", function(args)
    CMD.byName.set.fn({})
end)

def({ "settings" }, "settings [page|search]", "List settings", function(args)
    local a = args[1]
    local page = tonumber(a or "1")
    local list = {}
    for _, d in ipairs(SDEF) do
        if page or d.name:lower():find(a:lower(), 1, true) then list[#list + 1] = d end
    end
    local per = 10
    page = page or 1
    local pages = max(1, ceil(#list / per))
    page = U.clamp(page, 1, pages)
    U.chat(fmt("Settings page %d/%d (%s<page> or %ssettings <search>):", page, pages, S.prefix .. "settings ", S.prefix))
    for i = (page - 1) * per + 1, min(#list, page * per) do
        local d = list[i]
        local mark = Settings.isModified(d) and "\194\167e" or "\194\167b"
        U.chat(fmt("%s%s\194\167r = %s \194\1677%s", mark, d.name, Settings.toString(d), d.desc))
    end
end)

-- ---------------------------- waypoints ------------------------------
local function wpCmd(args)
    if not WP.loaded then WP.load() end
    local sub = (args[1] or "list"):lower()
    local fx, fy, fz = NAV.feet()
    if sub == "save" or sub == "add" then
        local n = args[2]
        if not n then U.chat("Usage: " .. S.prefix .. "wp save <name> [x y z]") return end
        local x, y, z = coord(args[3], fx) or fx, coord(args[4], fy) or fy, coord(args[5], fz) or fz
        WP.list[n:lower()] = { name = n, x = x, y = y, z = z, dim = W.dim }
        WP.save()
        U.chat("Saved waypoint " .. n .. " at " .. U.fmtPos(x, y, z))
    elseif sub == "goto" or sub == "go" then
        if not args[2] then U.chat("Usage: " .. S.prefix .. "wp goto <name>") return end
        local w = WP.list[args[2]:lower()]
        if not w then U.chat("No waypoint " .. args[2]) return end
        if w.dim ~= W.dim then U.chat("\194\167eThat waypoint is in the " .. w.dim) end
        Bot.start(Proc.go(G.block(w.x, w.y, w.z), "waypoint " .. w.name))
    elseif sub == "delete" or sub == "remove" or sub == "del" then
        if not args[2] then U.chat("Usage: " .. S.prefix .. "wp delete <name>") return end
        local key = args[2]:lower()
        if not WP.list[key] then U.chat("No waypoint " .. args[2]) return end
        WP.list[key] = nil
        WP.save()
        U.chat("Deleted " .. args[2])
    else
        local names = {}
        for _, w in pairs(WP.list) do names[#names + 1] = fmt("%s (%s, %s)", w.name, U.fmtPos(w.x, w.y, w.z), w.dim) end
        tsort(names)
        if #names == 0 then U.chat("No waypoints. " .. S.prefix .. "wp save <name>") return end
        U.chat("Waypoints: " .. tconcat(names, "; "))
    end
end
def({ "waypoints", "wp", "waypoint" }, "wp <save|goto|list|delete> [name]", "Save and travel to waypoints", wpCmd)
def({ "sethome" }, "sethome", "Save a 'home' waypoint here", function(args) wpCmd({ "save", "home" }) end)
def({ "home" }, "home", "Go to your 'home' waypoint", function(args) wpCmd({ "goto", "home" }) end)

-- ---------------------------- dispatch -------------------------------
function CMD.run(line)
    local args = U.words(line)
    if #args == 0 then CMD.byName.help.fn({}) return end
    local name = tremove(args, 1):lower()
    local c = CMD.byName[name]
    if not c then
        U.chat("Unknown command '" .. name .. "'. " .. S.prefix .. "help for a list")
        return
    end
    local ok, err = pcall(c.fn, args)
    if not ok then
        U.chat("\194\167cError in " .. name .. ": " .. tostring(err))
        U.log(tostring(err))
    end
end

-- =====================================================================
-- Main loop & Flarial events
-- =====================================================================
local Main = { lastFrame = nil, inited = false, lastTick = 0, warnedHelper = false, enabled = false }

Helper.onPanic = function()
    if Bot.isActive() then
        Bot.stopAll(true)
        U.chat(NATIVE and "Stopped (stop key)" or "Stopped (End key)")
    end
end

function Main.init()
    if Main.inited then return end
    Main.inited = true
    U.ensureDir(DIR)
    U.ensureDir(SCHEM_DIR)
    Settings.load()
    WP.load()
end

function Main.frame()
    local now = U.now()
    W.nowMs = now
    local dt = Main.lastFrame and (now - Main.lastFrame) / 1000 or 0.016
    if dt > 0.25 then dt = 0.25 end
    if dt < 0 then dt = 0 end
    Main.lastFrame = now
    Main.init()
    Helper.poll(now)
    P.refresh()
    REN.px, REN.py, REN.pz = P.x, P.y, P.z
    if not P.valid then
        IN.frame(now, dt, false)
        if NATIVE then pcall(native.setLines, {}) pcall(native.setStatus, "", false) end
        return
    end
    W.updateDimension()
    NAV.frame(now)
    CMD.pollLoad(now, 6)
    LM.updateGhosts(now)
    IN.frame(now, dt, Bot.sendInput())
    REN.status = Bot.status()
    if NATIVE then REN.update3d(now) end
end

function Main.tick()
    local now = U.now()
    if not P.valid then return end
    Bot.tick(now)
end

function Main.handleChat(message)
    if not S.chatControl then return false end
    local msg = tostring(message or "")
    local prefix = S.prefix
    if prefix == "" or msg:sub(1, #prefix) ~= prefix then return false end
    local line = msg:sub(#prefix + 1)
    if S.echoCommands then U.chat("\194\1677> " .. prefix .. line) end
    CMD.run(line)
    return true
end

local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local now = U.now()
        if not Main.lastErrT or now - Main.lastErrT > 3000 then
            Main.lastErrT = now
            U.chat("\194\167cInternal error: " .. tostring(err))
        end
        U.log(tostring(err))
        IN.clear()
    end
    return ok, err
end

onEvent("SetupAndRenderEvent", function()
    safe(Main.frame)
end)

onEvent("TickEvent", function()
    safe(Main.tick)
end)

onEvent("RenderEvent", function()
    pcall(REN.draw)
end)

onEvent("ChatSendEvent", function(message, name, type)
    local handled = false
    safe(function() handled = Main.handleChat(message) end)
    if handled then return true end
end)

-- If a Flarial build doesn't pass outgoing chat to scripts, a "#command" gets
-- sent to the server instead. Spot our own message coming back and warn.
onEvent("ChatReceiveEvent", function(message, name, type)
    safe(function()
        if Main.warnedLeak then return end
        local msg = tostring(message or "")
        local who = tostring(name or ""):lower()
        if S.prefix ~= "" and msg:find(S.prefix, 1, true) == 1 and P.name ~= "" and who:find(P.name:lower(), 1, true) then
            Main.warnedLeak = true
            U.chat("\194\167cYour Flarial version sent that command to chat. Use \194\167f.b " .. msg:sub(#S.prefix + 1)
                .. "\194\167c instead (e.g. .b goto 100 64 100).")
        end
    end)
end)

onEvent("ChangeDimensionEvent", function()
    safe(function()
        W.clear()
        W.chunkLoaded = {}
        if Bot.proc and Bot.proc.name ~= "build" then
            Bot.stopAll(true)
            U.chat("Dimension changed - stopped")
        end
    end)
end)

onEvent("DisconnectEvent", function()
    safe(function()
        Bot.stopAll(true)
        IN.clear()
        IN.write(U.now(), false, 0, 0)
        Farm.save()
    end)
end)

onEvent("RespawnEvent", function()
    safe(function()
        if Bot.proc then
            Bot.stopAll(true)
            U.chat("You died - stopped")
        end
        HB.invalidate()
    end)
end)

-- `.b <command>` / `.baritone <command>` work through Flarial's own command
-- system, even if a Flarial build doesn't pass chat messages to scripts.
local function dotCommand(args)
    local parts = {}
    if type(args) == "table" then
        for _, a in ipairs(args) do parts[#parts + 1] = tostring(a) end
    elseif args ~= nil then
        parts[1] = tostring(args)
    end
    safe(CMD.run, tconcat(parts, " "))
end
pcall(registerCommand, "b", "Baritone commands, e.g. .b goto 100 64 100", dotCommand)
pcall(registerCommand, "baritone", "Baritone commands, e.g. .baritone help", dotCommand)

function onEnable()
    Main.enabled = true
    safe(function()
        Main.init()
        if NATIVE then
            U.chat("Baritone " .. VERSION .. " ready. Type " .. S.prefix .. "help")
        else
            U.chat("Baritone " .. VERSION .. " ready. Type " .. S.prefix .. "help (or .b help).")
        end
    end)
end

function onDisable()
    Main.enabled = false
    safe(function()
        Bot.stopAll(true)
        IN.clear()
        IN.write(U.now(), false, 0, 0)
        Farm.save()
    end)
end

-- test hook (only used by the offline simulator)
if rawget(_G, "BARITONE_EXPOSE") then
    BARITONE_EXPOSE = { NAV = NAV, Bot = Bot, P = P, W = W, LM = LM, HB = HB, IN = IN, S = S, PF = PF, K = K, G = G, ACT = ACT, U = U }
end
