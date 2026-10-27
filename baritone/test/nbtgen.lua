-- NBT writers for generating test schematics
local NB = {}
local function nbtLE()
    local out = {}
    local W = {}
    function W.byte(v) out[#out + 1] = string.pack("<i1", v) end
    function W.int(v) out[#out + 1] = string.pack("<i4", v) end
    function W.str(s) out[#out + 1] = string.pack("<I2", #s) .. s end
    function W.tag(t, name) W.byte(t) W.str(name) end
    function W.done() return table.concat(out) end
    return W
end

local function hexOf(bin) return (bin:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

local function makeMcstructure(sx, sy, sz, fn, palette)
    local W = nbtLE()
    W.tag(10, "")
    W.tag(3, "format_version") W.int(1)
    W.tag(9, "size") W.byte(3) W.int(3) W.int(sx) W.int(sy) W.int(sz)
    W.tag(10, "structure")
    W.tag(9, "block_indices") W.byte(9) W.int(2)
    -- layer 0
    W.byte(3) W.int(sx * sy * sz)
    for x = 0, sx - 1 do for y = 0, sy - 1 do for z = 0, sz - 1 do W.int(fn(x, y, z)) end end end
    -- layer 1 (all -1)
    W.byte(3) W.int(sx * sy * sz)
    for i = 1, sx * sy * sz do W.int(-1) end
    W.tag(9, "entities") W.byte(10) W.int(0)
    W.tag(10, "palette")
    W.tag(10, "default")
    W.tag(9, "block_palette") W.byte(10) W.int(#palette)
    for _, n in ipairs(palette) do
        W.tag(8, "name") W.str("minecraft:" .. n)
        W.tag(10, "states") W.byte(0)
        W.tag(3, "version") W.int(18090528)
        W.byte(0)
    end
    W.tag(10, "block_position_data") W.byte(0)
    W.byte(0) -- default
    W.byte(0) -- palette
    W.byte(0) -- structure
    W.tag(9, "structure_world_origin") W.byte(3) W.int(3) W.int(0) W.int(0) W.int(0)
    W.byte(0)
    return W.done()
end


-- generic writer: tree of {type=,value=} -> NBT bytes (big or little endian)
local T = { byte = 1, short = 2, int = 3, long = 4, float = 5, double = 6, bytes = 7, string = 8, list = 9, compound = 10, ints = 11, longs = 12 }
NB.T = T
function NB.write(root, little)
    local E = little and "<" or ">"
    local out = {}
    local function put(fmt, v) out[#out + 1] = string.pack(E .. fmt, v) end
    local function str(s) put("I2", #s) out[#out + 1] = s end
    local payload
    payload = function(t, v)
        if t == 1 then put("i1", v)
        elseif t == 2 then put("i2", v)
        elseif t == 3 then put("i4", v)
        elseif t == 4 then put("i8", v)
        elseif t == 5 then put("f", v)
        elseif t == 6 then put("d", v)
        elseif t == 7 then put("i4", #v) out[#out + 1] = v
        elseif t == 8 then str(v)
        elseif t == 9 then
            put("i1", v.et) put("i4", #v.items)
            for _, it in ipairs(v.items) do payload(v.et, it) end
        elseif t == 10 then
            for _, kv in ipairs(v) do put("i1", kv[2]) str(kv[1]) payload(kv[2], kv[3]) end
            put("i1", 0)
        elseif t == 11 then put("i4", #v) for _, x in ipairs(v) do put("i4", x) end
        elseif t == 12 then put("i4", #v) for _, x in ipairs(v) do put("i8", x) end
        end
    end
    put("i1", 10) str(root.name or "")
    payload(10, root.value)
    return table.concat(out)
end

local function packLitematica(values, bits)
    local longs = {}
    local n = #values
    local total = math.ceil(n * bits / 64)
    for i = 1, total do longs[i] = 0 end
    for i = 0, n - 1 do
        local v = values[i + 1]
        local bi = i * bits
        local sl = bi // 64
        local off = bi % 64
        longs[sl + 1] = longs[sl + 1] | (v << off)
        if off + bits > 64 then
            longs[sl + 2] = longs[sl + 2] | (v >> (64 - off))
        end
    end
    return longs
end

-- regions: { {name=, pos={x,y,z}, size={x,y,z}, palette={"minecraft:air",...}, fn=function(x,y,z) return idx end} }
function NB.makeLitematic(regions)
    local regs = {}
    for _, r in ipairs(regions) do
        local ax, ay, az = math.abs(r.size[1]), math.abs(r.size[2]), math.abs(r.size[3])
        local bits = 2
        while (1 << bits) < #r.palette do bits = bits + 1 end
        local values = {}
        for y = 0, ay - 1 do for z = 0, az - 1 do for x = 0, ax - 1 do values[#values + 1] = r.fn(x, y, z) end end end
        local pal = {}
        for _, nm in ipairs(r.palette) do pal[#pal + 1] = { { "Name", T.string, nm } } end
        regs[#regs + 1] = { r.name, T.compound, {
            { "Position", T.compound, { { "x", T.int, r.pos[1] }, { "y", T.int, r.pos[2] }, { "z", T.int, r.pos[3] } } },
            { "Size", T.compound, { { "x", T.int, r.size[1] }, { "y", T.int, r.size[2] }, { "z", T.int, r.size[3] } } },
            { "BlockStatePalette", T.list, { et = T.compound, items = pal } },
            { "BlockStates", T.longs, packLitematica(values, bits) },
        } }
    end
    return NB.write({ name = "", value = {
        { "MinecraftDataVersion", T.int, 3953 },
        { "Version", T.int, 6 },
        { "Regions", T.compound, regs },
    } }, false)
end

local function varints(values)
    local out = {}
    for _, v in ipairs(values) do
        repeat
            local b = v & 0x7F
            v = v >> 7
            if v ~= 0 then b = b | 0x80 end
            out[#out + 1] = string.char(b)
        until v == 0
    end
    return table.concat(out)
end

-- Sponge schematic; palette = { "minecraft:air", ... } ; v = 2 or 3
function NB.makeSponge(w, h, l, palette, fn, v)
    local vals = {}
    for y = 0, h - 1 do for z = 0, l - 1 do for x = 0, w - 1 do vals[#vals + 1] = fn(x, y, z) end end end
    local pal = {}
    for i, nm in ipairs(palette) do pal[#pal + 1] = { nm, T.int, i - 1 } end
    if v == 3 then
        return NB.write({ name = "", value = { { "Schematic", T.compound, {
            { "Version", T.int, 3 }, { "Width", T.short, w }, { "Height", T.short, h }, { "Length", T.short, l },
            { "Blocks", T.compound, { { "Palette", T.compound, pal }, { "Data", T.bytes, varints(vals) } } },
        } } } }, false)
    end
    return NB.write({ name = "Schematic", value = {
        { "Version", T.int, 2 }, { "Width", T.short, w }, { "Height", T.short, h }, { "Length", T.short, l },
        { "PaletteMax", T.int, #palette }, { "Palette", T.compound, pal }, { "BlockData", T.bytes, varints(vals) },
    } }, false)
end

function NB.makeJavaStructure(sx, sy, sz, palette, fn)
    local blocks = {}
    for x = 0, sx - 1 do for y = 0, sy - 1 do for z = 0, sz - 1 do
        local st = fn(x, y, z)
        if st then
            blocks[#blocks + 1] = { { "pos", T.list, { et = T.int, items = { x, y, z } } }, { "state", T.int, st } }
        end
    end end end
    local pal = {}
    for _, nm in ipairs(palette) do pal[#pal + 1] = { { "Name", T.string, nm } } end
    return NB.write({ name = "", value = {
        { "size", T.list, { et = T.int, items = { sx, sy, sz } } },
        { "palette", T.list, { et = T.compound, items = pal } },
        { "blocks", T.list, { et = T.compound, items = blocks } },
        { "DataVersion", T.int, 3953 },
    } }, false)
end

NB.makeMcstructure = makeMcstructure
NB.hexOf = hexOf
NB.nbtLE = nbtLE
return NB
