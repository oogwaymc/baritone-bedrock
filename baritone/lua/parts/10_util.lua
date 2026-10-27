
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

-- diagnostics shared by the main loop and #debug
local DBG = { tickSource = "game", realTickT = nil, frames = 0 }

-- "minecraft:Stone[foo=bar]" -> "stone"  (memoized: block names repeat constantly)
local BARE, BARE_N = {}, 0
function U.bare(n)
    if n == nil then return "air" end
    local hit = BARE[n]
    if hit then return hit end
    local orig = n
    n = U.bareRaw(n)
    if BARE_N < 50000 then
        BARE[orig] = n
        BARE_N = BARE_N + 1
    end
    return n
end

function U.bareRaw(n)
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
