
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
-- targets: every block of the placement { x, y, z, name, key }
-- layers[y]: the targets in that layer; buckets: targets per 16x16x16 section
-- stat[key]: cached "ok" / "missing" / "wrong", kept fresh by a scanner that
-- checks a few hundred blocks per frame (so big schematics don't lag the game)
local LM = { schem = nil, ox = 0, oy = 0, oz = 0, rot = 0, mirror = nil, targets = {}, byKey = {},
    buckets = {}, layers = {}, minY = 0, maxY = -1, layer = nil, ghosts = {}, ghostT = 0, loading = nil,
    stat = {}, cur = {}, known = 0, scanI = 1, near = {}, nearI = 1, nearT = 0, nearCell = nil, look = nil, lookT = 0 }

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
    LM.targets, LM.byKey, LM.buckets, LM.layers = {}, {}, {}, {}
    LM.stat, LM.cur, LM.known, LM.scanI = {}, {}, 0, 1
    LM.near, LM.nearI, LM.nearT, LM.nearCell = {}, 1, 0, nil
    LM.ghosts, LM.ghostT, LM.look = {}, 0, nil
    if not s then return end
    local includeAir = S.buildClearAir
    local sx, sz = s.sx, s.sz
    local minY, maxY = INF, -INF
    local targets, byKey, layers, buckets = LM.targets, LM.byKey, LM.layers, LM.buckets
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
            targets[#targets + 1] = t
            byKey[k] = name
            local layer = layers[wy]
            if not layer then layer = {} layers[wy] = layer end
            layer[#layer + 1] = t
            local bk = U.key(wx // 16, wy // 16, wz // 16)
            local b = buckets[bk]
            if not b then b = {} buckets[bk] = b end
            b[#b + 1] = t
            if wy < minY then minY = wy end
            if wy > maxY then maxY = wy end
        end
    end
    LM.minY, LM.maxY = minY, maxY
end

-- fresh check of one target (updates the cache)
function LM.check(t)
    local st, n = LM.state(t)
    local k = t[5]
    if LM.stat[k] == nil then LM.known = LM.known + 1 end
    LM.stat[k] = st
    LM.cur[k] = n
    return st, n
end

-- cached state, checking it now if it's never been checked
function LM.cached(t)
    local st = LM.stat[t[5]]
    if st then return st, LM.cur[t[5]] end
    return LM.check(t)
end

-- targets near the player (rebuilt when the player moves a few blocks)
function LM.refreshNear(now)
    local r = S.litematicaRenderRadius
    local cx, cy, cz = P.fx, P.fy, P.fz
    local cell = U.key(cx // 3, cy // 3, cz // 3)
    if cell == LM.nearCell and now - LM.nearT < 3000 then return end
    LM.nearCell, LM.nearT = cell, now
    local out = {}
    for bx = (cx - r) // 16, (cx + r) // 16 do
        for by = (cy - r) // 16, (cy + r) // 16 do
            for bz = (cz - r) // 16, (cz + r) // 16 do
                local b = LM.buckets[U.key(bx, by, bz)]
                if b then
                    for _, t in ipairs(b) do
                        if abs(t[1] - cx) <= r and abs(t[3] - cz) <= r and abs(t[2] - cy) <= r then
                            out[#out + 1] = t
                        end
                    end
                end
            end
        end
    end
    LM.near = out
    if LM.nearI > #out then LM.nearI = 1 end
end

-- re-check a slice of the schematic every frame: mostly what's near the
-- player (what you can see), plus a slow sweep over the rest (for #build)
function LM.scanStep(now)
    if not LM.schem then return end
    LM.refreshNear(now)
    -- the budget is per 60 FPS frame, so a high frame rate doesn't scan more per second
    local elapsed = min(50, max(0, now - (LM.scanT or now - 16.7)))
    LM.scanT = now
    LM.scanCarry = (LM.scanCarry or 0) + max(20, S.litematicaScanPerFrame) * elapsed / 16.7
    local budget = floor(LM.scanCarry)
    LM.scanCarry = LM.scanCarry - budget
    if budget <= 0 then return end
    local near = LM.near
    local nn = #near
    local nearBudget = min(nn, floor(budget * 0.7))
    for _ = 1, nearBudget do
        if LM.nearI > nn then LM.nearI = 1 end
        LM.check(near[LM.nearI])
        LM.nearI = LM.nearI + 1
    end
    local all = LM.targets
    local na = #all
    for _ = 1, min(na, budget - nearBudget) do
        if LM.scanI > na then LM.scanI = 1 end
        LM.check(all[LM.scanI])
        LM.scanI = LM.scanI + 1
    end
end

-- block the player's crosshair is on, if it's part of the schematic
function LM.lookAt()
    if not LM.schem then return nil end
    local ex, ey, ez = P.eye()
    local yaw, pitch = P.yaw * RAD, P.pitch * RAD
    local dx, dy, dz = -sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch)
    local x, y, z = floor(ex), floor(ey), floor(ez)
    local stepX, stepY, stepZ = dx >= 0 and 1 or -1, dy >= 0 and 1 or -1, dz >= 0 and 1 or -1
    local function first(p, d)
        if d == 0 then return INF end
        local edge = (d > 0) and (floor(p) + 1) or floor(p)
        return (edge - p) / d
    end
    local tMaxX, tMaxY, tMaxZ = first(ex, dx), first(ey, dy), first(ez, dz)
    local tDX = dx ~= 0 and abs(1 / dx) or INF
    local tDY = dy ~= 0 and abs(1 / dy) or INF
    local tDZ = dz ~= 0 and abs(1 / dz) or INF
    for _ = 1, 80 do
        local k = U.key(x, y, z)
        local want = LM.byKey[k]
        if want and (LM.layer == nil or y == LM.layer) then
            local t = { x, y, z, want, k }
            local st, n = LM.cached(t)
            if st ~= "ok" or not K.passable(n) then return t, st, n end
        elseif not K.passable(W.get(x, y, z)) then
            return nil
        end
        if tMaxX < tMaxY and tMaxX < tMaxZ then
            if tMaxX > 24 then break end
            x = x + stepX tMaxX = tMaxX + tDX
        elseif tMaxY < tMaxZ then
            if tMaxY > 24 then break end
            y = y + stepY tMaxY = tMaxY + tDY
        else
            if tMaxZ > 24 then break end
            z = z + stepZ tMaxZ = tMaxZ + tDZ
        end
    end
    return nil
end

function LM.lookText(now)
    if not LM.schem or not S.litematicaShowLooking then LM.look = nil return nil end
    if now - LM.lookT >= 100 then
        LM.lookT = now
        local t, st, n = LM.lookAt()
        if not t then
            LM.look = nil
        else
            local txt
            if st == "ok" then
                txt = t[4] .. " (done)"
            elseif st == "missing" then
                txt = t[4] .. " (missing)"
            else
                txt = t[4] .. " (wrong: " .. tostring(n) .. " is there)"
            end
            LM.look = { t = t, text = txt }
        end
    end
    return LM.look and LM.look.text or nil
end

function LM.set(schem, ox, oy, oz)
    LM.schem = schem
    LM.ox, LM.oy, LM.oz = ox, oy, oz
    LM.rot, LM.mirror, LM.layer = 0, nil, nil
    LM.rebuild()
end

function LM.unload()
    LM.schem = nil
    LM.rebuild() -- clears everything
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
-- ghost boxes near the player, from the cached states (no world reads here)
-- each: { x, y, z, state, distance, blockName }
function LM.updateGhosts(now)
    if not LM.schem then return end
    LM.scanStep(now)
    if now - LM.ghostT < 250 then return end
    LM.ghostT = now
    local cx, cy, cz = P.fx + 0.5, P.fy + 1.5, P.fz + 0.5
    local out = {}
    local layer = LM.layer
    local stat = LM.stat
    for _, t in ipairs(LM.near) do
        if layer == nil or t[2] == layer then
            local st = stat[t[5]]
            if st and st ~= "ok" and t[4] ~= "air" or st == "wrong" then
                local dx, dy, dz = t[1] + 0.5 - cx, t[2] + 0.5 - cy, t[3] + 0.5 - cz
                out[#out + 1] = { t[1], t[2], t[3], st, dx * dx + dy * dy + dz * dz, t[4] }
            end
        end
    end
    local maxBoxes = max(1, S.litematicaMaxBoxes)
    if #out > maxBoxes then
        -- keep the nearest: bucket by squared distance (a counting sort, no table.sort)
        local rings, top = {}, 0
        for _, g in ipairs(out) do
            local ring = floor(g[5])
            local list = rings[ring]
            if not list then list = {} rings[ring] = list end
            list[#list + 1] = g
            if ring > top then top = ring end
        end
        local kept = {}
        for ring = 0, top do
            local list = rings[ring]
            if list then
                for _, g in ipairs(list) do
                    kept[#kept + 1] = g
                    if #kept >= maxBoxes then break end
                end
                if #kept >= maxBoxes then break end
            end
        end
        out = kept
    end
    LM.ghosts = out
end

-- counts from the cache; anything never checked is checked now (up to a budget)
function LM.verify(budget)
    local ok, missing, wrong, unknown = 0, 0, 0, 0
    budget = budget or 20000
    for _, t in ipairs(LM.targets) do
        local st = LM.stat[t[5]]
        if not st and budget > 0 then
            budget = budget - 1
            st = LM.check(t)
        end
        if st == "ok" then ok = ok + 1
        elseif st == "missing" then missing = missing + 1
        elseif st == "wrong" then wrong = wrong + 1
        else unknown = unknown + 1 end
    end
    return ok, missing, wrong, unknown
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
        local fresh = 400 -- blocks we may read from the world this pick (the rest comes from the cache)
        local itemFor = {} -- block name -> item, or false if it's not in the hotbar
        local KEEP = 24    -- only the nearest few candidates matter
        for layer = startLayer, LM.maxY do
            local list = LM.layers[layer]
            if list then
                local cands = {} -- sorted by distance, at most KEEP long
                local layerIncomplete = false
                local blocked = false
                for _, t in ipairs(list) do
                    local st, n = LM.stat[t[5]], LM.cur[t[5]]
                    if not st then
                        if fresh <= 0 then return nil end -- still scanning; carry on next pick
                        fresh = fresh - 1
                        st, n = LM.check(t)
                    end
                    if st ~= "ok" then
                        layerIncomplete = true
                        local sk = self.skip[t[5]]
                        if sk and sk >= now and (self.fails[t[5]] or 0) < 4 then blocked = true end
                        if not sk or sk < now then
                            local act
                            if st == "missing" then
                                local item = itemFor[t[4]]
                                if item == nil then
                                    local it = K.itemForBlock(t[4])
                                    item = HB.has(it) and it or false
                                    itemFor[t[4]] = item
                                    if not item then missingItems[it] = true end
                                end
                                if item then act = "place" end
                            elseif st == "wrong" and (S.buildBreakWrong or t[4] == "air") and not K.unbreakable(n) then
                                act = "break"
                            end
                            if act then
                                local dx, dy, dz = t[1] + 0.5 - ex, t[2] + 0.5 - ey, t[3] + 0.5 - ez
                                local d = dx * dx + dy * dy + dz * dz
                                local nc = #cands
                                if (nc < KEEP or d < cands[nc].d2)
                                    and (act ~= "place" or PF.hasSupport(t[1], t[2], t[3])) then
                                    local pos = nc + 1
                                    while pos > 1 and cands[pos - 1].d2 > d do
                                        cands[pos] = cands[pos - 1]
                                        pos = pos - 1
                                    end
                                    cands[pos] = { t = t, act = act, d2 = d, d = sqrt(d) }
                                    if #cands > KEEP then cands[#cands] = nil end
                                end
                            end
                        end
                    end
                end
                if #cands > 0 then
                    -- the cache can be a moment old: confirm with a fresh read before committing
                    local j = 1
                    local checked = 0
                    while cands[j] and checked < 32 do
                        local c = cands[j]
                        local st = LM.check(c.t)
                        checked = checked + 1
                        if (c.act == "place" and st ~= "missing") or (c.act == "break" and st ~= "wrong") then
                            table.remove(cands, j)
                        else
                            j = j + 1
                        end
                    end
                    if #cands == 0 then return nil end
                    -- prefer something we can do without moving
                    for k = 1, min(#cands, 24) do
                        if cands[k].d <= S.buildReach + 0.5 and self:canActFromHere(cands[k].t, cands[k].act) then
                            return cands[k].t, cands[k].act, true
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
            LM.check(t)
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
            if self.nextPick and now < self.nextPick then
                IN.clear()
                return true
            end
            local t, act, here = self:pick(now)
            self.nextPick = (t == nil) and (now + 300) or nil
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
