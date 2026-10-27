
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
