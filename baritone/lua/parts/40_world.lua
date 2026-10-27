
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
