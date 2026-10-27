
-- =====================================================================
-- Input: what the bot wants pressed this frame. BaritoneHelper.exe reads
-- it from Baritone/ipc.txt and presses the real keys / moves the mouse.
-- =====================================================================
local IN = {
    hold = {}, lmb = false, rmbHold = false, rmbPulse = 0, slotPulse = 0, slotReq = -1, slotTime = 0,
    tyaw = nil, tpitch = nil, accX = 0, accY = 0, seq = 0, lastWrite = 0, active = false,
    offWrites = 0, rawDx = 0, rawDy = 0, lastClick = 0,
}
local IPC_FILE = DIR .. "/ipc.txt"
local HELPER_FILE = DIR .. "/helper.txt"

local KEYSET = { forward = "keyForward", back = "keyBack", left = "keyLeft", right = "keyRight",
    jump = "keyJump", sneak = "keySneak", sprint = "keySprint" }

function IN.clear()
    IN.hold = {}
    IN.lmb = false
    IN.rmbHold = false
    IN.tyaw, IN.tpitch = nil, nil
end

function IN.press(k) IN.hold[k] = true end
function IN.release(k) IN.hold[k] = nil end

function IN.look(yaw, pitch)
    IN.tyaw = U.wrap180(yaw)
    IN.tpitch = U.clamp(pitch or P.pitch, -89.9, 89.9)
end

function IN.lookAt(x, y, z)
    local ex, ey, ez = P.eye()
    IN.tyaw = U.yawTo(ex, ez, x, z)
    IN.tpitch = U.clamp(U.pitchTo(ex, ey, ez, x, y, z), -89.9, 89.9)
end

function IN.aimError()
    if not IN.tyaw then return 0 end
    return max(abs(U.wrap180(IN.tyaw - P.yaw)), abs((IN.tpitch or P.pitch) - P.pitch))
end

function IN.click()
    IN.rmbPulse = IN.rmbPulse + 1
    IN.lastClick = U.now()
end

function IN.select(slot)
    if slot == nil then return end
    local now = U.now()
    if P.slot == slot then IN.slotReq = slot return end
    if IN.slotReq ~= slot or now - IN.slotTime > 500 then
        IN.slotReq = slot
        IN.slotPulse = IN.slotPulse + 1
        IN.slotTime = now
    end
end

-- raw mouse move (used by calibration), sent in small steps over several
-- frames so pointer acceleration treats it like normal bot movement
IN.rawQueue = {}
function IN.rawMove(dx, dy)
    local steps = max(1, ceil(max(abs(dx), abs(dy)) / 12))
    local sx, sy = dx / steps, dy / steps
    local accX, accY = 0, 0
    for i = 1, steps do
        local nx, ny = U.round(sx * i), U.round(sy * i)
        IN.rawQueue[#IN.rawQueue + 1] = { nx - accX, ny - accY }
        accX, accY = nx, ny
    end
end

function IN.rawPending() return #IN.rawQueue > 0 end

function IN.turnMode()
    return NATIVE and S.rotationMode == "turn"
end

function IN.calibrated()
    if NATIVE and not IN.turnMode() then return true end -- rotation is written directly
    return S.mouseYawPerPixel ~= 0 and S.mousePitchPerPixel ~= 0
end

-- ------------------------------------------------------------------
-- Helper connection
-- ------------------------------------------------------------------
local Helper = { beat = nil, beatT = -1e9, focus = NATIVE, panic = nil, version = "?", lastRead = 0, connected = NATIVE }

function Helper.poll(now)
    if NATIVE then
        Helper.connected = true
        Helper.version = tostring(native.version or "dll")
        local okF, f = pcall(native.focused)
        Helper.focus = (not okF) or f == true
        local okP, pc = pcall(native.panicCount)
        pc = okP and tostring(pc) or "0"
        if Helper.panic ~= nil and pc ~= Helper.panic and Helper.onPanic then
            Helper.panic = pc
            Helper.onPanic()
        end
        Helper.panic = pc
        return
    end
    if now - Helper.lastRead < 300 then return end
    Helper.lastRead = now
    local data = U.readFile(HELPER_FILE)
    if not data then
        Helper.connected = now - Helper.beatT < 2000
        return
    end
    local beat, focus, panic, ver = data:match("H1|(%d+)|(%d)|(%d+)|([^|]*)|E")
    if beat then
        if beat ~= Helper.beat then
            Helper.beat = beat
            Helper.beatT = now
        end
        Helper.focus = focus == "1"
        Helper.version = ver
        if Helper.panic ~= nil and panic ~= Helper.panic then
            Helper.panic = panic
            if Helper.onPanic then Helper.onPanic() end
        end
        Helper.panic = panic
    end
    Helper.connected = now - Helper.beatT < 2000
end

-- ------------------------------------------------------------------
-- Per-frame: turn the camera toward the target and write the IPC record
-- ------------------------------------------------------------------
-- ------------------------------------------------------------------
-- Native (DLL) output: movement through the game's input state, rotation
-- written directly (or through the game's mouse-look), clicks / hotbar keys
-- ------------------------------------------------------------------
IN.nat = { rmbSent = 0, slotSent = 0, lastActive = false, setFails = 0, lastSetYaw = nil, lastSetPrevYaw = nil }

function IN.nativeRotate(now, dt, active)
    local nat = IN.nat
    -- did last frame's direct write stick? (if not, fall back to mouse-look turning)
    if nat.lastSetYaw then
        local moved = abs(U.wrap180(P.yaw - nat.lastSetPrevYaw))
        local wanted = abs(U.wrap180(nat.lastSetYaw - nat.lastSetPrevYaw))
        if wanted > 0.5 and moved < 0.05 then
            nat.setFails = nat.setFails + 1
            if nat.setFails >= 20 and S.rotationMode == "set" then
                S.rotationMode = "turn"
                S.mouseYawPerPixel, S.mousePitchPerPixel = 0, 0
                Settings.save()
                U.chat("\194\167eDirect rotation doesn't work on this version - switching to mouse-look turning (calibrating).")
                if Bot.makeCalibrate then Bot.queuePre(Bot.makeCalibrate()) end
            end
        elseif moved >= 0.05 then
            nat.setFails = 0
        end
        nat.lastSetYaw = nil
    end
    if not active or not IN.tyaw then return end
    local ey = U.wrap180(IN.tyaw - P.yaw)
    local ep = (IN.tpitch or P.pitch) - P.pitch
    local k = 1 - math.exp(-dt / 0.06)
    local maxStep = S.rotationSpeed * dt
    local sy = U.clamp(ey * k, -maxStep, maxStep)
    local sp = U.clamp(ep * k, -maxStep, maxStep)
    if abs(ey) < 0.1 then sy = ey end
    if abs(ep) < 0.1 then sp = ep end
    if sy == 0 and sp == 0 then return end
    if IN.turnMode() then
        if not IN.calibrated() then return end
        pcall(native.turn, sy / S.mouseYawPerPixel, sp / S.mousePitchPerPixel)
    else
        local ny, np = U.wrap180(P.yaw + sy), U.clamp(P.pitch + sp, -89.9, 89.9)
        pcall(native.setRotation, np, ny)
        nat.lastSetYaw, nat.lastSetPrevYaw = ny, P.yaw
    end
end

function IN.nativeFrame(now, dt, active)
    local nat = IN.nat
    IN.nativeRotate(now, dt, active)
    -- calibration moves (turn mode only)
    if #IN.rawQueue > 0 then
        local st = tremove(IN.rawQueue, 1)
        pcall(native.turn, st[1], st[2])
    end
    if active then
        local h = IN.hold
        pcall(native.setInput, true, h.forward == true, h.back == true, h.left == true, h.right == true,
            h.jump == true, h.sneak == true, h.sprint == true)
        pcall(native.setButtons, IN.lmb == true, IN.rmbHold == true)
        if IN.rmbPulse ~= nat.rmbSent then
            nat.rmbSent = IN.rmbPulse
            pcall(native.click, 2)
        end
        if IN.slotPulse ~= nat.slotSent then
            nat.slotSent = IN.slotPulse
            if IN.slotReq and IN.slotReq >= 0 then pcall(native.selectSlot, IN.slotReq) end
        end
    else
        nat.rmbSent, nat.slotSent = IN.rmbPulse, IN.slotPulse
        if nat.lastActive or now - (nat.lastOff or 0) > 500 then
            nat.lastOff = now
            pcall(native.setInput, false)
            pcall(native.setButtons, false, false)
        end
    end
    nat.lastActive = active
    IN.active = active
end

function IN.frame(now, dt, active)
    if NATIVE then return IN.nativeFrame(now, dt, active) end
    local dx, dy = 0, 0
    if active and IN.tyaw and IN.calibrated() then
        local ey = U.wrap180(IN.tyaw - P.yaw)
        local ep = (IN.tpitch or P.pitch) - P.pitch
        local k = 1 - math.exp(-dt / 0.06)
        local maxStep = S.rotationSpeed * dt
        local sy = U.clamp(ey * k, -maxStep, maxStep)
        local sp = U.clamp(ep * k, -maxStep, maxStep)
        if abs(ey) < 0.15 then sy = 0 end
        if abs(ep) < 0.15 then sp = 0 end
        IN.accX = IN.accX + sy / S.mouseYawPerPixel
        IN.accY = IN.accY + sp / S.mousePitchPerPixel
    else
        IN.accX, IN.accY = 0, 0
    end
    if #IN.rawQueue > 0 and now - IN.lastWrite >= 8 then
        local st = tremove(IN.rawQueue, 1)
        IN.accX = IN.accX + st[1]
        IN.accY = IN.accY + st[2]
    end

    if not active then
        IN.accX, IN.accY = 0, 0
        if IN.active then IN.offWrites = 6 end
        IN.active = false
        if IN.offWrites > 0 and now - IN.lastWrite >= 30 then
            IN.offWrites = IN.offWrites - 1
            IN.write(now, false, 0, 0)
        end
        return
    end
    IN.active = true
    if now - IN.lastWrite < 8 then return end
    dx = IN.accX >= 0 and floor(IN.accX) or ceil(IN.accX)
    dy = IN.accY >= 0 and floor(IN.accY) or ceil(IN.accY)
    dx = U.clamp(dx, -400, 400)
    dy = U.clamp(dy, -400, 400)
    IN.accX = IN.accX - dx
    IN.accY = IN.accY - dy
    IN.write(now, true, dx, dy)
end

function IN.write(now, on, dx, dy)
    if NATIVE then
        if not on then
            pcall(native.setInput, false)
            pcall(native.setButtons, false, false)
        end
        return
    end
    IN.seq = IN.seq + 1
    IN.lastWrite = now
    local keys = {}
    if on then
        for k, settingName in pairs(KEYSET) do
            if IN.hold[k] then keys[#keys + 1] = tostring(S[settingName]):upper() end
        end
    end
    tsort(keys)
    local rec = fmt("B1|%d|%d|%s|%d|%d|%d|%d|%d|%d|%d|E\n",
        IN.seq, on and 1 or 0, (#keys > 0) and tconcat(keys, "+") or "-",
        (on and IN.lmb) and 1 or 0, (on and IN.rmbHold) and 1 or 0, IN.rmbPulse,
        IN.slotReq or -1, IN.slotPulse, dx, dy)
    U.writeFile(IPC_FILE, rec)
end

-- =====================================================================
-- Hotbar knowledge (Flarial only tells us the held item, so we learn the
-- hotbar by watching the selected slot, or by scanning slots 1-9)
-- =====================================================================
local HB = { items = {}, known = {} }

function HB.observe()
    if not P.valid then return end
    if NATIVE and type(player.hotbar) == "function" then
        local now = U.now()
        if HB.nextRead and now < HB.nextRead then return end
        HB.nextRead = now + 100
        local ok, t = pcall(player.hotbar)
        if ok and type(t) == "table" then
            for s = 0, 8 do
                local it = t[s]
                HB.items[s] = (type(it) == "string" and it ~= "" and it ~= "empty") and U.bare(it) or false
                HB.known[s] = true
            end
            return
        end
    end
    if IN.slotReq >= 0 and IN.slotReq ~= P.slot and U.now() - IN.slotTime < 300 then return end
    HB.items[P.slot] = P.mainhand or false
    HB.known[P.slot] = true
end

function HB.complete()
    for s = 0, 8 do if not HB.known[s] then return false end end
    return true
end

function HB.invalidate()
    if NATIVE and type(player.hotbar) == "function" then HB.nextRead = nil return end
    HB.known = {}
end

function HB.slotOf(name)
    for s = 0, 8 do if HB.items[s] == name then return s end end
    return nil
end

function HB.find(pred)
    for s = 0, 8 do
        local it = HB.items[s]
        if it and pred(it) then return s, it end
    end
    return nil
end

function HB.bestTool(cat)
    local bestS, bestR, bestN = nil, -1, nil
    for s = 0, 8 do
        local it = HB.items[s]
        if it and K.itemToolType(it) == cat then
            local r = K.toolRank(it)
            if r > bestR then bestS, bestR, bestN = s, r, it end
        end
    end
    return bestS, bestN
end

function HB.throwaway()
    local set = Settings.set("acceptableThrowawayItems")
    if P.mainhand and set[P.mainhand] then return P.slot, P.mainhand end
    return HB.find(function(it) return set[it] end)
end

function HB.has(name) return HB.slotOf(name) ~= nil end

function HB.list()
    local parts = {}
    for s = 0, 8 do
        local it = HB.items[s]
        local label = (not HB.known[s]) and "?" or (it or "-")
        parts[#parts + 1] = fmt("%d:%s", s + 1, label)
    end
    return tconcat(parts, "  ")
end
