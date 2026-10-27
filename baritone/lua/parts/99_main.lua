
-- =====================================================================
-- Main loop & Flarial events
-- =====================================================================
local Main = { lastFrame = nil, inited = false, lastTick = 0, warnedHelper = false, enabled = false }

Helper.onPanic = function()
    if Bot.isActive() then
        Bot.stopAll(true)
        U.chat(NATIVE and "Stopped (stop key)" or "Stopped (End key)")
    end
end

function Main.init()
    if Main.inited then return end
    Main.inited = true
    U.ensureDir(DIR)
    U.ensureDir(SCHEM_DIR)
    Settings.load()
    WP.load()
end

function Main.frame()
    local now = U.now()
    W.nowMs = now
    local dt = Main.lastFrame and (now - Main.lastFrame) / 1000 or 0.016
    if dt > 0.25 then dt = 0.25 end
    if dt < 0 then dt = 0 end
    Main.lastFrame = now
    Main.init()
    Helper.poll(now)
    P.refresh()
    REN.px, REN.py, REN.pz = P.x, P.y, P.z
    if not P.valid then
        IN.frame(now, dt, false)
        if NATIVE then pcall(native.setLines, {}) pcall(native.setStatus, "", false) end
        return
    end
    W.updateDimension()
    NAV.frame(now)
    CMD.pollLoad(now, 6)
    LM.updateGhosts(now)
    IN.frame(now, dt, Bot.sendInput())
    REN.status = Bot.status()
    if NATIVE then REN.update3d(now) end
end

function Main.tick()
    local now = U.now()
    if not P.valid then return end
    Bot.tick(now)
end

function Main.handleChat(message)
    if not S.chatControl then return false end
    local msg = tostring(message or "")
    local prefix = S.prefix
    if prefix == "" or msg:sub(1, #prefix) ~= prefix then return false end
    local line = msg:sub(#prefix + 1)
    if S.echoCommands then U.chat("\194\1677> " .. prefix .. line) end
    CMD.run(line)
    return true
end

local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local now = U.now()
        if not Main.lastErrT or now - Main.lastErrT > 3000 then
            Main.lastErrT = now
            U.chat("\194\167cInternal error: " .. tostring(err))
        end
        U.log(tostring(err))
        IN.clear()
    end
    return ok, err
end

onEvent("SetupAndRenderEvent", function()
    safe(Main.frame)
end)

onEvent("TickEvent", function()
    safe(Main.tick)
end)

onEvent("RenderEvent", function()
    pcall(REN.draw)
end)

onEvent("ChatSendEvent", function(message, name, type)
    local handled = false
    safe(function() handled = Main.handleChat(message) end)
    if handled then return true end
end)

-- If a Flarial build doesn't pass outgoing chat to scripts, a "#command" gets
-- sent to the server instead. Spot our own message coming back and warn.
onEvent("ChatReceiveEvent", function(message, name, type)
    safe(function()
        if Main.warnedLeak then return end
        local msg = tostring(message or "")
        local who = tostring(name or ""):lower()
        if S.prefix ~= "" and msg:find(S.prefix, 1, true) == 1 and P.name ~= "" and who:find(P.name:lower(), 1, true) then
            Main.warnedLeak = true
            U.chat("\194\167cYour Flarial version sent that command to chat. Use \194\167f.b " .. msg:sub(#S.prefix + 1)
                .. "\194\167c instead (e.g. .b goto 100 64 100).")
        end
    end)
end)

onEvent("ChangeDimensionEvent", function()
    safe(function()
        W.clear()
        W.chunkLoaded = {}
        if Bot.proc and Bot.proc.name ~= "build" then
            Bot.stopAll(true)
            U.chat("Dimension changed - stopped")
        end
    end)
end)

onEvent("DisconnectEvent", function()
    safe(function()
        Bot.stopAll(true)
        IN.clear()
        IN.write(U.now(), false, 0, 0)
        Farm.save()
    end)
end)

onEvent("RespawnEvent", function()
    safe(function()
        if Bot.proc then
            Bot.stopAll(true)
            U.chat("You died - stopped")
        end
        HB.invalidate()
    end)
end)

-- `.b <command>` / `.baritone <command>` work through Flarial's own command
-- system, even if a Flarial build doesn't pass chat messages to scripts.
local function dotCommand(args)
    local parts = {}
    if type(args) == "table" then
        for _, a in ipairs(args) do parts[#parts + 1] = tostring(a) end
    elseif args ~= nil then
        parts[1] = tostring(args)
    end
    safe(CMD.run, tconcat(parts, " "))
end
pcall(registerCommand, "b", "Baritone commands, e.g. .b goto 100 64 100", dotCommand)
pcall(registerCommand, "baritone", "Baritone commands, e.g. .baritone help", dotCommand)

function onEnable()
    Main.enabled = true
    safe(function()
        Main.init()
        if NATIVE then
            U.chat("Baritone " .. VERSION .. " ready. Type " .. S.prefix .. "help")
        else
            U.chat("Baritone " .. VERSION .. " ready. Type " .. S.prefix .. "help (or .b help).")
        end
    end)
end

function onDisable()
    Main.enabled = false
    safe(function()
        Bot.stopAll(true)
        IN.clear()
        IN.write(U.now(), false, 0, 0)
        Farm.save()
    end)
end

-- test hook (only used by the offline simulator)
if rawget(_G, "BARITONE_EXPOSE") then
    BARITONE_EXPOSE = { NAV = NAV, Bot = Bot, P = P, W = W, LM = LM, HB = HB, IN = IN, S = S, PF = PF, K = K, G = G, ACT = ACT, U = U }
end
