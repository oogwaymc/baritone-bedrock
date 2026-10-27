
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
