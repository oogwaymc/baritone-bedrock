
-- =====================================================================
-- Block colours for ghost blocks (roughly the block's texture colour)
-- =====================================================================
K.COLOR_EXACT = {
    stone = { 125, 125, 125 }, cobblestone = { 110, 110, 110 }, mossy_cobblestone = { 100, 120, 90 },
    smooth_stone = { 160, 160, 160 }, stone_bricks = { 120, 120, 120 }, granite = { 150, 100, 80 },
    diorite = { 200, 200, 200 }, andesite = { 135, 135, 135 }, calcite = { 225, 225, 220 }, tuff = { 110, 110, 100 },
    deepslate = { 75, 75, 80 }, cobbled_deepslate = { 75, 75, 80 }, dirt = { 135, 95, 65 }, grass_block = { 95, 160, 60 },
    grass = { 95, 160, 60 }, coarse_dirt = { 120, 85, 60 }, podzol = { 95, 65, 30 }, mycelium = { 115, 95, 115 },
    mud = { 60, 55, 60 }, packed_mud = { 140, 105, 80 }, mud_bricks = { 140, 105, 80 }, clay = { 160, 165, 180 },
    gravel = { 130, 125, 120 }, sand = { 220, 210, 160 }, red_sand = { 190, 100, 35 }, sandstone = { 215, 205, 155 },
    red_sandstone = { 185, 100, 35 }, glass = { 200, 230, 240 }, ice = { 145, 185, 250 }, packed_ice = { 140, 180, 250 },
    blue_ice = { 115, 165, 250 }, snow = { 245, 250, 250 }, snow_layer = { 245, 250, 250 }, obsidian = { 25, 15, 40 },
    crying_obsidian = { 45, 10, 80 }, bedrock = { 60, 60, 60 }, netherrack = { 110, 50, 50 }, soul_sand = { 80, 60, 50 },
    soul_soil = { 75, 57, 45 }, glowstone = { 250, 205, 120 }, sea_lantern = { 200, 225, 220 }, end_stone = { 220, 220, 160 },
    purpur_block = { 170, 125, 170 }, prismarine = { 100, 160, 145 }, dark_prismarine = { 50, 90, 75 },
    prismarine_bricks = { 100, 170, 160 }, quartz_block = { 235, 230, 225 }, smooth_quartz = { 235, 230, 225 },
    brick_block = { 150, 95, 80 }, bricks = { 150, 95, 80 }, nether_brick = { 45, 22, 27 }, red_nether_brick = { 70, 10, 10 },
    blackstone = { 40, 35, 40 }, basalt = { 80, 80, 85 }, polished_basalt = { 90, 90, 95 }, hay_block = { 200, 170, 40 },
    bookshelf = { 140, 110, 70 }, crafting_table = { 140, 100, 60 }, furnace = { 110, 110, 110 }, chest = { 160, 115, 50 },
    barrel = { 130, 95, 55 }, torch = { 255, 210, 90 }, lantern = { 90, 85, 80 }, ladder = { 150, 115, 65 },
    scaffolding = { 200, 170, 90 }, slime = { 110, 190, 90 }, slime_block = { 110, 190, 90 }, honey_block = { 240, 170, 40 },
    sponge = { 200, 190, 75 }, tnt = { 200, 60, 40 }, pumpkin = { 200, 120, 30 }, melon_block = { 115, 145, 35 },
    iron_block = { 220, 220, 220 }, gold_block = { 245, 210, 60 }, diamond_block = { 100, 235, 225 },
    emerald_block = { 45, 200, 90 }, lapis_block = { 30, 65, 140 }, redstone_block = { 175, 25, 15 },
    coal_block = { 20, 20, 20 }, copper_block = { 190, 105, 80 }, netherite_block = { 65, 60, 65 },
    amethyst_block = { 135, 95, 190 }, dripstone_block = { 135, 105, 90 }, moss_block = { 90, 110, 45 },
    water = { 60, 100, 230 }, lava = { 230, 100, 20 }, redstone_wire = { 200, 20, 10 }, redstone_lamp = { 180, 110, 60 },
    piston = { 150, 130, 100 }, sticky_piston = { 120, 160, 100 }, observer = { 100, 100, 100 }, hopper = { 70, 70, 75 },
    dispenser = { 115, 115, 115 }, dropper = { 115, 115, 115 }, beacon = { 130, 220, 215 }, anvil = { 70, 70, 70 },
    white_wool = { 235, 235, 235 }, target = { 225, 175, 160 }, note_block = { 115, 75, 55 }, jukebox = { 115, 75, 55 },
}

-- colour words used by wool, concrete, terracotta, glass, carpet, beds, candles ...
K.COLOR_WORDS = {
    { "light_blue", { 60, 175, 220 } }, { "light_gray", { 155, 155, 150 } }, { "silver", { 155, 155, 150 } },
    { "white", { 235, 235, 235 } }, { "orange", { 240, 120, 20 } }, { "magenta", { 190, 70, 180 } },
    { "yellow", { 250, 200, 40 } }, { "lime", { 115, 185, 25 } }, { "pink", { 240, 140, 170 } },
    { "gray", { 65, 70, 75 } }, { "cyan", { 20, 140, 145 } }, { "purple", { 120, 40, 170 } },
    { "blue", { 50, 55, 160 } }, { "brown", { 115, 70, 40 } }, { "green", { 85, 110, 25 } },
    { "red", { 160, 40, 35 } }, { "black", { 25, 25, 30 } },
}

-- material words (checked after colour words)
K.COLOR_MATERIALS = {
    { "pale_oak", { 230, 220, 215 } }, { "dark_oak", { 70, 45, 20 } }, { "oak", { 165, 130, 80 } },
    { "spruce", { 115, 85, 50 } }, { "birch", { 195, 180, 120 } }, { "jungle", { 160, 115, 80 } },
    { "acacia", { 170, 90, 50 } }, { "mangrove", { 120, 55, 50 } }, { "cherry", { 225, 175, 170 } },
    { "bamboo", { 195, 175, 80 } }, { "crimson", { 100, 50, 70 } }, { "warped", { 45, 105, 100 } },
    { "deepslate", { 75, 75, 80 } }, { "blackstone", { 40, 35, 40 } }, { "cobblestone", { 110, 110, 110 } },
    { "stone_brick", { 120, 120, 120 } }, { "mossy", { 100, 120, 90 } }, { "end_stone", { 220, 220, 160 } },
    { "sandstone", { 215, 205, 155 } }, { "prismarine", { 100, 160, 145 } }, { "purpur", { 170, 125, 170 } },
    { "quartz", { 235, 230, 225 } }, { "nether_brick", { 45, 22, 27 } }, { "brick", { 150, 95, 80 } },
    { "copper", { 190, 105, 80 } }, { "oxidized", { 80, 160, 130 } }, { "weathered", { 105, 150, 110 } },
    { "exposed", { 160, 125, 100 } }, { "tuff", { 110, 110, 100 } }, { "granite", { 150, 100, 80 } },
    { "diorite", { 200, 200, 200 } }, { "andesite", { 135, 135, 135 } }, { "mud", { 140, 105, 80 } },
    { "terracotta", { 150, 90, 65 } }, { "glass", { 200, 230, 240 } }, { "concrete", { 130, 130, 130 } },
    { "wool", { 235, 235, 235 } }, { "leaves", { 60, 130, 40 } }, { "log", { 110, 85, 50 } }, { "wood", { 110, 85, 50 } },
    { "planks", { 165, 130, 80 } }, { "ore", { 125, 125, 125 } }, { "stone", { 125, 125, 125 } },
    { "iron", { 220, 220, 220 } }, { "gold", { 245, 210, 60 } }, { "door", { 150, 115, 70 } },
    { "fence", { 150, 115, 70 } }, { "rail", { 150, 140, 120 } }, { "carpet", { 235, 235, 235 } },
}

K.colorCache = {}

function K.blockColor(name)
    local c = K.colorCache[name]
    if c then return c end
    local n = K.canon and K.canon(name) or name
    c = K.COLOR_EXACT[name] or K.COLOR_EXACT[n]
    if not c then
        for _, e in ipairs(K.COLOR_WORDS) do
            if n:find(e[1], 1, true) then c = e[2] break end
        end
    end
    if not c then
        for _, e in ipairs(K.COLOR_MATERIALS) do
            if n:find(e[1], 1, true) then c = e[2] break end
        end
    end
    if not c then
        -- anything else: a stable colour from the name, so the same block always looks the same
        local h = 0
        for i = 1, #n do h = (h * 31 + n:byte(i)) % 16777216 end
        c = { 80 + h % 160, 80 + (h // 160) % 160, 80 + (h // 25600) % 160 }
    end
    K.colorCache[name] = c
    return c
end
