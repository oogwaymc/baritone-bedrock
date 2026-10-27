
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
