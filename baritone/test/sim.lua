-- Mock of Flarial's Lua API + a simple Minecraft-like physics simulation,
-- used to run Baritone.lua end-to-end outside the game.
local SIM = {}
_G.SIM = SIM
local floor, ceil, abs, sqrt, min, max = math.floor, math.ceil, math.abs, math.sqrt, math.min, math.max

local PASS = {
    air = true, short_grass = true, wheat = true, carrots = true, potatoes = true, beetroot = true,
    torch = true, water = true, lava = true, flowing_water = true, reeds = true, fern = true,
}
local LIQ = { water = true, lava = true, flowing_water = true }
SIM.PASS, SIM.LIQ = PASS, LIQ

local HARD = {
    stone = 1.5, cobblestone = 2, dirt = 0.5, grass_block = 0.6, diamond_ore = 3, deepslate_diamond_ore = 4.5,
    iron_ore = 3, oak_log = 2, oak_planks = 2, sand = 0.5, gravel = 0.6, glass = 0.3, farmland = 0.6,
    deepslate = 3, bedrock = -1, pumpkin = 1, coal_ore = 3, netherrack = 0.4, obsidian = 50,
}
local TOOLSPEED = { wooden = 2, stone = 4, iron = 6, diamond = 8, netherite = 9 }

function SIM.reset()
    SIM.t = 0
    SIM.nextTick = 0
    SIM.world = {}
    SIM.gen = function(x, y, z) return "air" end
    SIM.chat = {}
    SIM.events = {}
    SIM.commands = {}
    SIM.entities = {}
    SIM.keys = {}
    SIM.lmb = false
    SIM.lastSeq = -1
    SIM.lastRmb = nil
    SIM.lastSlotPulse = nil
    SIM.breaking = nil
    SIM.helperBeat = 0
    SIM.helperPanic = 0
    SIM.lastHelperWrite = -1e9
    SIM.degPerPx = 0.12
    SIM.pitchPerPx = 0.12
    SIM.appendMode = true
    SIM.helperRunning = true
    SIM.ipcReads = 0
    SIM.placed = 0
    SIM.broken = 0
    SIM.player = {
        x = 0.5, y = 64, z = 0.5, vx = 0, vy = 0, vz = 0, yaw = 0, pitch = 0, grounded = false,
        health = 20, hunger = 20, gamemode = 0, hotbar = {}, sel = 0, chest = nil, fallDist = 0, damage = 0,
    }
    SIM.files = SIM.files or {}
    SIM.dirs = SIM.dirs or {}
end

function SIM.k(x, y, z) return x .. "," .. y .. "," .. z end
function SIM.get(x, y, z)
    local v = SIM.world[SIM.k(x, y, z)]
    if v == nil then v = SIM.gen(x, y, z) end
    return v
end
function SIM.set(x, y, z, n) SIM.world[SIM.k(x, y, z)] = n end
function SIM.solid(n) return not PASS[n] end

-- ------------------------------------------------------------------
-- Flarial API mocks
-- ------------------------------------------------------------------
local function P() return SIM.player end

util = {
    time = function() return SIM.t end,
}
log = function(m) if SIM.verbose then print("[log] " .. tostring(m)) end end
client = {
    displayLocalMessage = function(m)
        SIM.chat[#SIM.chat + 1] = m
        if SIM.verbose then print("[chat] " .. (tostring(m):gsub("\194\167.", ""))) end
    end,
    notify = function(m) end,
    getScreenName = function() return SIM.screen or "hud_screen" end,
    isInGame = function() return true end,
}
player = {
    position = function() local p = P() return p.x, p.y, p.z end,
    rotation = function() local p = P() return { x = p.fakePitch or p.pitch, y = p.fakeYaw or p.yaw } end,
    velocity = function() local p = P() return p.vx, p.vy, p.vz end,
    grounded = function() return P().grounded end,
    health = function() return P().health end,
    hunger = function() return P().hunger end,
    gamemode = function() return P().gamemode end,
    selectedSlot = function() return P().sel end,
    mainhand = function()
        local it = P().hotbar[P().sel]
        if it then return { name = "minecraft:" .. it.name, maxDurability = 0, damage = 0, isEnchanted = false } end
        return { name = "empty", maxDurability = -1, damage = -1, isEnchanted = -1 }
    end,
    armor = function()
        local c = P().chest
        return { chestplate = c and { name = "minecraft:" .. c } or { name = "empty" }, helmet = { name = "empty" },
            leggings = { name = "empty" }, boots = { name = "empty" } }
    end,
    dimension = function() return "Overworld" end,
    name = function() return "Tester" end,
}

local Entity = {}
Entity.__index = Entity
function Entity:isValid() return true end
function Entity:getName() return self.name end
function Entity:getTypeId() return self.type end
function Entity:distanceToPlayer()
    local p = P()
    local ey = self.type == "minecraft:player" and 1.62 or 0
    local dx, dy, dz = self.x - p.x, (self.y + ey) - (p.y + 1.62), self.z - p.z
    return sqrt(dx * dx + dy * dy + dz * dz)
end
function SIM.addEntity(e) setmetatable(e, Entity) SIM.entities[#SIM.entities + 1] = e return e end

world = {
    getBlock = function(x, y, z) return "minecraft:" .. SIM.get(floor(x), floor(y), floor(z)) end,
    raycast = function(d) return SIM.raycast(d or 6, false) end,
    worldToScreen = function(x, y, z) return true, 100, 100 end,
    getWorldName = function() return "Test World" end,
    getDimension = function() return "Overworld" end,
    getEntities = function(r) return SIM.entities end,
    getLightLevel = function() return 15 end,
}

local function dirOf(p) return p:match("^(.*)/[^/]+$") or "" end
fs = {
    exists = function(p) return SIM.files[p] ~= nil or SIM.dirs[p] == true end,
    isDirectory = function(p) return SIM.dirs[p] == true end,
    create = function(p) SIM.dirs[p] = true return true end,
    remove = function(p) SIM.files[p] = nil return true end,
    readFile = function(p) return SIM.files[p] or "" end,
    writeFile = function(p, c)
        if SIM.appendMode then SIM.files[p] = (SIM.files[p] or "") .. c else SIM.files[p] = c end
        return true
    end,
    listDirectory = function(p)
        local out = {}
        for f in pairs(SIM.files) do if dirOf(f) == p then out[#out + 1] = f end end
        table.sort(out)
        return out
    end,
}

local DL = {}
function DL:AddLine() SIM.lines = (SIM.lines or 0) + 1 end
function DL:AddText() end
function DL:AddRect() end
ImGui = {
    GetBackgroundDrawList = function() return DL end,
    GetForegroundDrawList = function() return DL end,
}
settings = {
    addToggle = function(_, _, d) return { value = d } end,
    addSlider = function(_, _, d) return { value = d } end,
    addTextBox = function(_, _, d) return { value = d } end,
    addKeybind = function() return { value = false } end,
    addHeader = function() end,
}
onEvent = function(name, fn) SIM.events[name] = fn end
registerCommand = function(name, desc, fn) SIM.commands[name] = fn or desc end

-- ------------------------------------------------------------------
-- Raycast (voxel DDA from the eye along the look vector)
-- Face ids (Bedrock): 0 down, 1 up, 2 north(-z), 3 south(+z), 4 west(-x), 5 east(+x)
-- ------------------------------------------------------------------
function SIM.lookVec()
    local p = P()
    local yaw, pitch = math.rad(p.yaw), math.rad(p.pitch)
    return -math.sin(yaw) * math.cos(pitch), -math.sin(pitch), math.cos(yaw) * math.cos(pitch)
end

function SIM.raycast(maxDist, liquids)
    local p = P()
    local ex, ey, ez = p.x, p.y + 1.62, p.z
    local dx, dy, dz = SIM.lookVec()
    local x, y, z = floor(ex), floor(ey), floor(ez)
    local sx = dx > 0 and 1 or -1
    local sy = dy > 0 and 1 or -1
    local sz = dz > 0 and 1 or -1
    local function tmax(e, c, d) if d == 0 then return math.huge end if d > 0 then return (c + 1 - e) / d else return (e - c) / -d end end
    local tx, ty, tz = tmax(ex, x, dx), tmax(ey, y, dy), tmax(ez, z, dz)
    local ddx = dx ~= 0 and 1 / abs(dx) or math.huge
    local ddy = dy ~= 0 and 1 / abs(dy) or math.huge
    local ddz = dz ~= 0 and 1 / abs(dz) or math.huge
    local t, face = 0, nil
    for _ = 1, 200 do
        if tx < ty and tx < tz then
            t = tx; tx = tx + ddx; x = x + sx; face = (sx > 0) and 4 or 5
        elseif ty < tz then
            t = ty; ty = ty + ddy; y = y + sy; face = (sy > 0) and 0 or 1
        else
            t = tz; tz = tz + ddz; z = z + sz; face = (sz > 0) and 2 or 3
        end
        if t > maxDist then return nil end
        local n = SIM.get(x, y, z)
        local hitIt = (n ~= "air" and not LIQ[n]) or (liquids and LIQ[n])
        if hitIt then
            return { blockX = x, blockY = y, blockZ = z, faceId = face, x = ex + dx * t, y = ey + dy * t, z = ez + dz * t, distance = t }
        end
    end
    return nil
end

local FACEV = { [0] = { 0, -1, 0 }, [1] = { 0, 1, 0 }, [2] = { 0, 0, -1 }, [3] = { 0, 0, 1 }, [4] = { -1, 0, 0 }, [5] = { 1, 0, 0 } }

local function intersectsPlayer(bx, by, bz)
    local p = P()
    return p.x + 0.3 > bx and p.x - 0.3 < bx + 1 and p.y + 1.8 > by and p.y < by + 1 and p.z + 0.3 > bz and p.z - 0.3 < bz + 1
end

local SEEDS = { wheat_seeds = "wheat", carrot = "carrots", potato = "potatoes", beetroot_seeds = "beetroot" }

function SIM.giveItem(name, count)
    local p = P()
    for s = 0, 8 do
        local it = p.hotbar[s]
        if it and it.name == name then it.count = it.count + (count or 1) return end
    end
    for s = 0, 8 do
        if not p.hotbar[s] then p.hotbar[s] = { name = name, count = count or 1 } return end
    end
end

function SIM.rightClick()
    local p = P()
    local it = p.hotbar[p.sel]
    if not it then return end
    if it.name == "water_bucket" then
        local hit = SIM.raycast(5.5, false)
        if hit then
            local f = FACEV[hit.faceId]
            local nx, ny, nz = hit.blockX + f[1], hit.blockY + f[2], hit.blockZ + f[3]
            local t = SIM.get(nx, ny, nz)
            if PASS[t] then SIM.set(nx, ny, nz, "water") it.name = "bucket" SIM.waterPlaced = (SIM.waterPlaced or 0) + 1 end
        end
        return
    end
    if it.name == "bucket" then
        local hit = SIM.raycast(5.5, true)
        if hit and SIM.get(hit.blockX, hit.blockY, hit.blockZ) == "water" then
            SIM.set(hit.blockX, hit.blockY, hit.blockZ, "air")
            it.name = "water_bucket"
            SIM.waterPicked = (SIM.waterPicked or 0) + 1
        end
        return
    end
    if it.name == "firework_rocket" then
        SIM.boost = 30
        it.count = it.count - 1
        if it.count <= 0 then p.hotbar[p.sel] = nil end
        return
    end
    local hit = SIM.raycast(5.5, false)
    if not hit then return end
    local f = FACEV[hit.faceId]
    local nx, ny, nz = hit.blockX + f[1], hit.blockY + f[2], hit.blockZ + f[3]
    local target = SIM.get(nx, ny, nz)
    local placeName
    if SEEDS[it.name] then
        if SIM.get(hit.blockX, hit.blockY, hit.blockZ) == "farmland" and hit.faceId == 1 and target == "air" then
            placeName = SEEDS[it.name]
        end
    elseif PASS[target] and not (target == "wheat" or target == "carrots") then
        if not intersectsPlayer(nx, ny, nz) then placeName = it.name end
    end
    if placeName then
        SIM.set(nx, ny, nz, placeName)
        SIM.placed = SIM.placed + 1
        it.count = it.count - 1
        if it.count <= 0 then p.hotbar[p.sel] = nil end
    end
end

local function toolInfo(itemName)
    if not itemName then return nil, 1 end
    local mat, kind = itemName:match("^(%a+)_(%a+)$")
    if mat and TOOLSPEED[mat] and (kind == "pickaxe" or kind == "shovel" or kind == "axe" or kind == "hoe" or kind == "sword") then
        return kind, TOOLSPEED[mat]
    end
    return nil, 1
end

local function breakTicksFor(n, itemName)
    local h = HARD[n] or 1.5
    if h < 0 then return math.huge end
    if h == 0 or PASS[n] then return 1 end
    local cat = "pickaxe"
    if n == "dirt" or n == "grass_block" or n == "sand" or n == "gravel" or n == "farmland" then cat = "shovel" end
    if n == "oak_log" or n == "oak_planks" or n == "pumpkin" then cat = "axe" end
    local kind, speed = toolInfo(itemName)
    if P().gamemode == 1 then return 1 end
    if kind == cat then return ceil(h * 30 / speed) end
    if cat == "pickaxe" then return ceil(h * 100) end
    return ceil(h * 30)
end

local DROPS = { diamond_ore = "diamond", deepslate_diamond_ore = "diamond", stone = "cobblestone", grass_block = "dirt",
    wheat = "wheat_seeds", coal_ore = "coal", iron_ore = "raw_iron", deepslate = "cobbled_deepslate" }

function SIM.blockActions()
    local p = P()
    if SIM.lmb then
        local hit = SIM.raycast(5.5, false)
        if hit then
            local key = SIM.k(hit.blockX, hit.blockY, hit.blockZ)
            local n = SIM.get(hit.blockX, hit.blockY, hit.blockZ)
            local it = p.hotbar[p.sel]
            if not SIM.breaking or SIM.breaking.key ~= key then
                SIM.breaking = { key = key, progress = 0, need = breakTicksFor(n, it and it.name) }
            end
            SIM.breaking.progress = SIM.breaking.progress + 1
            if SIM.breaking.progress >= SIM.breaking.need then
                SIM.set(hit.blockX, hit.blockY, hit.blockZ, "air")
                SIM.broken = SIM.broken + 1
                SIM.brokenNames = SIM.brokenNames or {}
                SIM.brokenNames[n] = (SIM.brokenNames[n] or 0) + 1
                local drop = DROPS[n] or n
                if n == "wheat" then SIM.giveItem("wheat", 1) end
                SIM.giveItem(drop, 1)
                SIM.breaking = nil
            end
        else
            SIM.breaking = nil
        end
    else
        SIM.breaking = nil
    end
end

-- ------------------------------------------------------------------
-- Physics (very simplified Minecraft movement)
-- ------------------------------------------------------------------
local function collides(x, y, z)
    for bx = floor(x - 0.3 + 1e-4), floor(x + 0.3 - 1e-4) do
        for by = floor(y + 1e-4), floor(y + 1.8 - 1e-4) do
            for bz = floor(z - 0.3 + 1e-4), floor(z + 0.3 - 1e-4) do
                if SIM.solid(SIM.get(bx, by, bz)) then return true end
            end
        end
    end
    return false
end
SIM.collides = collides

function SIM.physics()
    local p = P()
    local K = SIM.keys
    local feet = SIM.get(floor(p.x), floor(p.y + 0.01), floor(p.z))
    local inWater = (feet == "water")
    if feet == "lava" then p.health = p.health - 4 SIM.lava = true end
    local fwd = (K.W and 1 or 0) - (K.S and 1 or 0)
    local str = (K.A and 1 or 0) - (K.D and 1 or 0)
    local yaw = math.rad(p.yaw)
    local f, g = math.sin(yaw), math.cos(yaw)
    local mx, mz = str * g - fwd * f, fwd * g + str * f
    local len = sqrt(mx * mx + mz * mz)
    if len > 1 then mx, mz = mx / len, mz / len end
    local sneak, sprint = K.LSHIFT, K.LCONTROL
    -- elytra deploy: press jump while falling
    if not p.grounded and p.chest == "elytra" and K.SPACE and not SIM.prevSpace and p.vy < 0 and not SIM.gliding then
        SIM.gliding = true
    end
    SIM.prevSpace = K.SPACE
    if SIM.gliding then
        -- crude elytra: fly along look vector
        local lx, ly, lz = SIM.lookVec()
        local sp = sqrt(p.vx * p.vx + p.vy * p.vy + p.vz * p.vz)
        if SIM.boost and SIM.boost > 0 then sp = math.min(sp + 0.15, 1.7) SIM.boost = SIM.boost - 1 end
        sp = math.max(sp * 0.99, 0.5)
        p.vx, p.vy, p.vz = lx * sp, ly * sp - 0.04, lz * sp
        p.fallDist = 0
    elseif p.grounded then
        local speed = sneak and 0.065 or ((sprint and fwd > 0) and 0.28 or 0.216)
        if inWater then speed = 0.1 end
        p.vx, p.vz = mx * speed, mz * speed
        if K.SPACE and not inWater then p.vy = 0.42 p.grounded = false end
    else
        if inWater then p.vx, p.vz = mx * 0.1, mz * 0.1
        else p.vx = p.vx * 0.91 + mx * 0.02; p.vz = p.vz * 0.91 + mz * 0.02 end
    end
    if not SIM.gliding and inWater then
        if K.SPACE then p.vy = math.min(p.vy + 0.08, 0.15)
        elseif sneak then p.vy = math.max(p.vy - 0.05, -0.15)
        else p.vy = math.max(p.vy - 0.02, -0.1) end
        p.fallDist = 0
    end
    if not SIM.gliding and not inWater and p.grounded and p.vy <= 0 then p.vy = -0.0784 end
    -- Y
    local ny = p.y + p.vy
    local wasGrounded = p.grounded
    if collides(p.x, ny, p.z) then
        if p.vy < 0 then
            local snap = floor(ny) + 1
            if not collides(p.x, snap, p.z) then p.y = snap end
            if not wasGrounded then
                if p.fallDist > 3 and not inWater then
                    local dmg = ceil(p.fallDist - 3)
                    p.health = p.health - dmg
                    p.damage = p.damage + dmg
                end
                if SIM.gliding then SIM.gliding = false end
            end
            p.fallDist = 0
            p.grounded = true
        end
        p.vy = 0
    else
        p.y = ny
        if p.vy < 0 then p.fallDist = p.fallDist - p.vy end
        p.grounded = false
    end
    if not p.grounded then
        p.grounded = (p.vy <= 0) and collides(p.x, p.y - 0.02, p.z)
        if p.grounded then p.y = floor(p.y + 0.02) + (collides(p.x, floor(p.y), p.z) and 1 or 0) end
    end
    local newFeet = SIM.get(floor(p.x), floor(p.y + 0.01), floor(p.z))
    if newFeet == "water" then p.fallDist = 0 end
    -- X / Z
    local function moveH(axis, v)
        if v == 0 then return end
        local nx, nz = p.x, p.z
        if axis == "x" then nx = p.x + v else nz = p.z + v end
        if sneak and p.grounded and not collides(nx, p.y - 0.05, nz) then return end
        if collides(nx, p.y, nz) then
            if axis == "x" then p.vx = 0 else p.vz = 0 end
            return
        end
        p.x, p.z = nx, nz
    end
    moveH("x", p.vx)
    moveH("z", p.vz)
    if p.grounded and not collides(p.x, p.y - 0.02, p.z) then p.grounded = false end
    if p.y < -200 then p.health = 0 end
    -- gravity is applied after the move (Minecraft order), so a jump rises ~1.25 blocks
    if not SIM.gliding and not inWater and not p.grounded then
        p.vy = (p.vy - 0.08) * 0.98
    end
end

-- ------------------------------------------------------------------
-- The "helper": parse Baritone/ipc.txt like BaritoneHelper.exe does
-- ------------------------------------------------------------------
local KEYMAP = { W = "W", A = "A", S = "S", D = "D", SPACE = "SPACE", LSHIFT = "LSHIFT", LCONTROL = "LCONTROL" }

function SIM.helperRead()
    if not SIM.helperRunning then return end
    local data = SIM.files["Baritone/ipc.txt"]
    if not data then return end
    if #data > 65536 then SIM.files["Baritone/ipc.txt"] = nil end
    local last
    for rec in data:gmatch("B1|[^\n]*|E") do last = rec end
    if not last then return end
    local f = {}
    for v in last:gmatch("[^|]+") do f[#f + 1] = v end
    -- B1 seq on keys lmb rmbHold rmbPulse slot slotPulse dx dy E
    local seq, on, keys, lmb, rmbHold, rmbPulse, slot, slotPulse, dx, dy =
        tonumber(f[2]), f[3] == "1", f[4], f[5] == "1", f[6] == "1", tonumber(f[7]), tonumber(f[8]), tonumber(f[9]), tonumber(f[10]), tonumber(f[11])
    if seq == SIM.lastSeq then return end
    SIM.lastSeq = seq
    SIM.ipcReads = SIM.ipcReads + 1
    SIM.keys = {}
    SIM.lmb = false
    if not on then return end
    if keys ~= "-" then for k in keys:gmatch("[^+]+") do SIM.keys[KEYMAP[k] or k] = true end end
    SIM.lmb = lmb
    local p = P()
    p.yaw = p.yaw + dx * SIM.degPerPx
    p.yaw = (p.yaw + 180) % 360 - 180
    p.pitch = math.max(-90, math.min(90, p.pitch + dy * SIM.pitchPerPx))
    if SIM.lastRmb == nil then SIM.lastRmb = rmbPulse end
    if rmbPulse ~= SIM.lastRmb then SIM.lastRmb = rmbPulse SIM.rightClick() end
    if SIM.lastSlotPulse == nil then SIM.lastSlotPulse = slotPulse end
    if slotPulse ~= SIM.lastSlotPulse then
        SIM.lastSlotPulse = slotPulse
        if slot >= 0 and slot <= 8 then p.sel = slot end
    end
end

function SIM.helperWrite()
    if not SIM.helperRunning then return end
    if SIM.t - SIM.lastHelperWrite < 250 then return end
    SIM.lastHelperWrite = SIM.t
    SIM.helperBeat = SIM.helperBeat + 1
    SIM.files["Baritone/helper.txt"] = string.format("H1|%d|1|%d|sim|E\r\n", SIM.helperBeat, SIM.helperPanic)
end

-- ------------------------------------------------------------------
-- Main loop
-- ------------------------------------------------------------------
-- ------------------------------------------------------------------
-- DLL mode: the `native` API from BaritoneModule.cpp
-- ------------------------------------------------------------------
SIM.nativeMode = os.getenv("NATIVE") == "1"

function SIM.installNative()
    local p = SIM.player
    SIM.status = nil
    SIM.lines3d = 0
    SIM.nativeRotationWorks = (SIM.nativeRotationWorks ~= false)
    -- what works on the simulated game version (tests switch these off)
    SIM.tickHookWorks = (SIM.tickHookWorks ~= false)   -- TickEvent fires
    SIM.moveHookFires = (SIM.moveHookFires ~= false)   -- AfterMoveEvent fires
    SIM.moveHookWorks = (SIM.moveHookWorks ~= false)   -- ... and the game uses what we write
    SIM.inputMode = "hook"
    SIM.boxes3d, SIM.boxData = 0, {}
    native = {
        version = "sim",
        setInput = function(active, f, b, l, r, j, s, sp)
            if not active then SIM.keys = {} SIM.lmb = false return end
            local works = (SIM.inputMode == "keys") or (SIM.moveHookFires and SIM.moveHookWorks)
            if not works then SIM.keys = {} return end
            SIM.keys = { W = f or nil, S = b or nil, A = l or nil, D = r or nil, SPACE = j or nil, LSHIFT = s or nil,
                LCONTROL = sp or nil }
        end,
        setInputMode = function(m) SIM.inputMode = m end,
        setMoveKeys = function(...) SIM.moveKeys = { ... } end,
        mouseMove = function(dx, dy)
            local pl = SIM.player
            pl.fakeYaw, pl.fakePitch = nil, nil
            SIM.mouseMoves = (SIM.mouseMoves or 0) + 1
            pl.yaw = (pl.yaw + dx * SIM.degPerPx + 180) % 360 - 180
            pl.pitch = math.max(-90, math.min(90, pl.pitch + dy * SIM.pitchPerPx))
            return true
        end,
        setBoxes = function(t) SIM.boxes3d = #t // 11 SIM.boxData = t end,
        stats = function()
            return { tickAge = SIM.tickHookWorks and 10 or -1, moveAge = SIM.moveHookFires and 10 or -1, focused = true,
                inHud = true, cursorGrabbed = true, latiteMenu = false, deadTick = not SIM.tickHookWorks,
                deadMove = not SIM.moveHookFires, deadTurn = false, deadMouse = false, inputMode = SIM.inputMode,
                lines = SIM.lines3d, boxes = SIM.boxes3d, moveActive = true, rotationComponent = true }
        end,
        setButtons = function(lmb, rmb) SIM.lmb = lmb == true end,
        click = function(b) if b == 2 then SIM.rightClick() end end,
        selectSlot = function(s) SIM.player.sel = s end,
        setRotation = function(pitch, yaw)
            if not SIM.nativeRotationWorks then return end
            if SIM.rotationCosmetic then
                -- the write is read back, but the camera / movement don't use it
                SIM.player.fakePitch = math.max(-89.9, math.min(89.9, pitch))
                SIM.player.fakeYaw = (yaw + 180) % 360 - 180
                return
            end
            SIM.player.pitch = math.max(-89.9, math.min(89.9, pitch))
            SIM.player.yaw = (yaw + 180) % 360 - 180
        end,
        turn = function(dx, dy)
            local pl = SIM.player
            pl.fakeYaw, pl.fakePitch = nil, nil
            pl.yaw = (pl.yaw + dx * SIM.degPerPx + 180) % 360 - 180
            pl.pitch = math.max(-90, math.min(90, pl.pitch + dy * SIM.pitchPerPx))
            return true
        end,
        focused = function() return true end,
        panicCount = function() return SIM.helperPanic end,
        setLines = function(t) SIM.lines3d = #t // 10 end,
        setStatus = function(text, vis) SIM.status = vis and text or nil end,
    }
    player.grounded = nil -- the DLL doesn't report it; the script computes it
    player.hotbar = function()
        local t = {}
        for i = 0, 8 do
            local it = SIM.player.hotbar[i]
            t[i] = it and it.name or false
        end
        return t
    end
    world.getEntities = function(r)
        local out = {}
        local pl = SIM.player
        for _, e in ipairs(SIM.entities) do
            local ey = e.type == "minecraft:player" and 1.62 or 0
            local d = math.sqrt((e.x - pl.x) ^ 2 + (e.y + ey - pl.y - 1.62) ^ 2 + (e.z - pl.z) ^ 2)
            out[#out + 1] = { name = e.name, type = e.type, x = e.x, y = e.y, z = e.z, dist = d,
                player = e.type == "minecraft:player" }
        end
        return out
    end
    fs.readBinary = function(path)
        local d = SIM.files[path]
        if not d then return nil, "can't read file" end
        return d
    end
end

function SIM.load(path)
    if SIM.nativeMode then SIM.installNative() end
    local fh = assert(io.open(path))
    local src = fh:read("a")
    fh:close()
    local fn = assert(load(src, "=Baritone.lua"))
    fn()
    if onEnable then onEnable() end
end

function SIM.command(text)
    local r = SIM.events.ChatSendEvent(text, "Tester", 0)
    return r
end

function SIM.run(ms, untilFn)
    local stop = SIM.t + ms
    local frame = 1000 / 60
    while SIM.t < stop do
        SIM.t = SIM.t + frame
        if not SIM.nativeMode then SIM.helperWrite() end
        while SIM.t >= SIM.nextTick do
            SIM.physics()
            SIM.blockActions()
            if SIM.entityTick then SIM.entityTick() end
            if SIM.events.TickEvent and (not SIM.nativeMode or SIM.tickHookWorks) then SIM.events.TickEvent() end
            SIM.nextTick = SIM.nextTick + 50
        end
        if SIM.events.SetupAndRenderEvent then SIM.events.SetupAndRenderEvent() end
        if SIM.events.RenderEvent then SIM.events.RenderEvent() end
        if not SIM.nativeMode then SIM.helperRead() end
        if untilFn and untilFn() then return true end
    end
    return false
end

function SIM.lastChat(n)
    n = n or 1
    local out = {}
    for i = max(1, #SIM.chat - n + 1), #SIM.chat do out[#out + 1] = (SIM.chat[i]:gsub("\194\167.", "")) end
    return table.concat(out, " | ")
end

function SIM.chatContains(s)
    for _, m in ipairs(SIM.chat) do if m:find(s, 1, true) then return true end end
    return false
end

return SIM
