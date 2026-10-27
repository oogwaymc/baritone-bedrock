
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
