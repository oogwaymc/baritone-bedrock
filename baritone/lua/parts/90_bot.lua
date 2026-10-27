
-- =====================================================================
-- Bot controller: one active "process" (goto, mine, follow, build ...)
-- plus pre-steps (mouse calibration, hotbar scan) and the fall guard.
-- =====================================================================
Bot.proc = nil
Bot.pre = nil
Bot.paused = false
Bot.preQueue = {}

local Proc = {}

function Bot.isActive()
    return (Bot.proc ~= nil or Bot.pre ~= nil or #Bot.preQueue > 0 or FG.active)
end

function Bot.sendInput()
    if not Helper.connected or not P.valid or not P.inHud() then return false end
    if FG.active then return true end
    if Bot.paused then return false end
    return Bot.pre ~= nil or Bot.proc ~= nil
end

function Bot.queuePre(step)
    Bot.preQueue[#Bot.preQueue + 1] = step
end

function Bot.start(proc, quiet)
    Bot.stopAll(true)
    Bot.paused = false
    Bot.proc = proc
    if not Helper.connected then
        U.chat("\194\167eBaritoneHelper.exe isn't running, so I can plan and draw the path but can't move you. Start it and type #resume.")
        Bot.paused = true
    elseif NATIVE then
        if not IN.calibrated() then Bot.queuePre(Proc.calibrate()) end
    else
        if not IN.calibrated() then Bot.queuePre(Proc.calibrate()) end
        if not HB.complete() then Bot.queuePre(Proc.hotbarScan()) end
    end
    if proc.start then proc:start() end
    if not quiet and proc.status then U.chat(proc:status()) end
end

function Bot.finish(msg)
    if msg then U.chat(msg) end
    local p = Bot.proc
    Bot.proc = nil
    if p and p.stop then p:stop() end
    NAV.stop()
    IN.clear()
end

function Bot.stopAll(silent)
    local p = Bot.proc
    Bot.proc = nil
    Bot.pre = nil
    Bot.preQueue = {}
    if p and p.stop then p:stop() end
    NAV.stop()
    IN.clear()
    if not silent then U.chat("Stopped") end
end

function Bot.tick(now)
    HB.observe()
    -- learn the hotbar once, shortly after the helper connects (needed for the fall guard)
    if not Bot.autoScanned and not NATIVE and Helper.connected and Helper.focus and P.inHud() and P.grounded
        and not Bot.isActive() and not Bot.paused and IN.calibrated() then
        Bot.readySince = Bot.readySince or now
        if now - Bot.readySince > 2500 then
            Bot.autoScanned = true
            if not HB.complete() then Bot.queuePre(Proc.hotbarScan()) end
        end
    end
    if S.stopOnLowHealth > 0 and P.health > 0 and P.health < S.stopOnLowHealth and Bot.proc and not P.creative() then
        Bot.stopAll(true)
        U.chat(fmt("\194\167cLow health (%d) - stopped. #set stopOnLowHealth 0 to disable.", floor(P.health)))
        return
    end
    if FG.tick() then return end
    if Bot.paused then
        IN.clear()
        return
    end
    if not Bot.pre and #Bot.preQueue > 0 then
        Bot.pre = tremove(Bot.preQueue, 1)
        if Bot.pre.start then Bot.pre:start() end
    end
    if Bot.pre then
        local r = Bot.pre:tick(now)
        if r == "running" then return end
        Bot.pre = nil
        IN.clear()
        if r == "failed" then
            Bot.stopAll(true)
            return
        end
        if #Bot.preQueue > 0 then return end
    end
    if Bot.proc then
        local manual = Bot.proc:tick(now)
        if not Bot.proc then return end
        if manual then return end
    end
    NAV.tick(now)
end

function Bot.status()
    if Bot.paused then return "Paused" end
    if FG.active then return "Water bucket clutch" end
    if Bot.pre and Bot.pre.status then return Bot.pre:status() end
    if Bot.proc and Bot.proc.status then return Bot.proc:status() end
    return "Idle"
end

-- ------------------------------------------------------------------
-- Pre-step: mouse calibration (measures degrees per mouse pixel)
-- ------------------------------------------------------------------
function Proc.calibrate(announce)
    local c = { name = "calibrate", phase = "wait", t = 0, tries = 0, warned = false }
    function c:start()
        self.t = U.now()
        if announce ~= false then U.chat("Calibrating mouse... keep the Minecraft window focused and don't touch the mouse.") end
    end
    function c:status() return "Calibrating mouse" end
    function c:tick(now)
        IN.clear()
        if not Helper.connected then
            U.chat("\194\167cCalibration needs BaritoneHelper.exe running.")
            return "failed"
        end
        if NATIVE and not IN.turnMode() then return "done" end
        if not Helper.focus or not P.inHud() then
            if not self.warned and now - self.t > 3000 then
                U.chat("Waiting for the Minecraft window to be focused (close chat/menus)...")
                self.warned = true
            end
            self.t = now
            return "running"
        end
        if self.phase == "wait" then
            if now - self.t > 600 then
                self.yaw0 = P.yaw
                self.px = (self.tries == 0) and 160 or 400
                IN.rawMove(self.px, 0)
                self.phase = "yaw"
                self.t = now
            end
        elseif self.phase == "yaw" then
            if IN.rawPending() then self.t = now end
            if now - self.t > 450 then
                local d = U.wrap180(P.yaw - self.yaw0)
                if abs(d) < 0.5 then
                    self.tries = self.tries + 1
                    if self.tries >= 2 then
                        if NATIVE then
                            U.chat("\194\167cThe camera didn't move. Set #set rotationMode set and try again.")
                        else
                            U.chat("\194\167cThe camera didn't move. Check that BaritoneHelper.exe is running (as admin if Minecraft runs as admin) and the game window is focused.")
                        end
                        return "failed"
                    end
                    self.phase = "wait"
                    self.t = now
                else
                    S.mouseYawPerPixel = d / self.px
                    IN.rawMove(-self.px, 0)
                    self.phase = "pwait"
                    self.t = now
                end
            end
        elseif self.phase == "pwait" then
            if IN.rawPending() then self.t = now end
            if now - self.t > 450 then
                self.pitch0 = P.pitch
                self.pdir = (P.pitch > 40) and -1 or 1
                IN.rawMove(0, 90 * self.pdir)
                self.phase = "pitch"
                self.t = now
            end
        elseif self.phase == "pitch" then
            if IN.rawPending() then self.t = now end
            if now - self.t > 450 then
                local d = P.pitch - self.pitch0
                if abs(d) < 0.3 then
                    S.mousePitchPerPixel = S.mouseYawPerPixel
                else
                    S.mousePitchPerPixel = d / (90 * self.pdir)
                end
                IN.rawMove(0, -90 * self.pdir)
                Settings.save()
                U.chat(fmt("Mouse calibrated (%.4f deg/px yaw, %.4f deg/px pitch)", S.mouseYawPerPixel, S.mousePitchPerPixel))
                self.phase = "done"
                self.t = now
            end
        elseif self.phase == "done" then
            if IN.rawPending() then self.t = now end
            if now - self.t > 300 then return "done" end
        end
        return "running"
    end
    return c
end

Bot.makeCalibrate = function() return Proc.calibrate() end

-- ------------------------------------------------------------------
-- Pre-step: learn the hotbar by selecting slots 1..9
-- ------------------------------------------------------------------
function Proc.hotbarScan(announce)
    local h = { name = "hotbar", i = 0, t = 0, orig = 0 }
    function h:start()
        self.orig = P.slot
        self.t = U.now()
        if announce then U.chat("Scanning hotbar...") end
    end
    function h:status() return "Scanning hotbar" end
    function h:tick(now)
        IN.clear()
        if not Helper.focus or not P.inHud() then self.t = now return "running" end
        if self.i > 8 then
            IN.select(self.orig)
            if P.slot == self.orig or now - self.t > 800 then
                if announce then U.chat("Hotbar: " .. HB.list()) end
                return "done"
            end
            return "running"
        end
        IN.select(self.i)
        if P.slot == self.i and now - self.t > 110 then
            HB.items[self.i] = P.mainhand or false
            HB.known[self.i] = true
            self.i = self.i + 1
            self.t = now
        elseif now - self.t > 1500 then
            U.chat("\194\167cCouldn't switch hotbar slots. Check your hotbar keys are 1-9.")
            for s = 0, 8 do HB.known[s] = true end
            return "done"
        end
        return "running"
    end
    return h
end

-- ------------------------------------------------------------------
-- #goto / #path / #thisway / #wp goto
-- ------------------------------------------------------------------
function Proc.go(goal, label)
    local g = { name = "goto", goal = goal }
    function g:start() NAV.set(goal) end
    function g:status()
        local s = "Going to " .. (label or goal.desc)
        if NAV.state == "search" then s = s .. " (planning)" end
        return s
    end
    function g:tick(now)
        if NAV.state == "arrived" then
            Bot.finish("Reached " .. (label or goal.desc))
        elseif NAV.state == "failed" then
            Bot.finish("\194\167cNo path to " .. (label or goal.desc) .. " (" .. NAV.info .. ")")
        end
    end
    return g
end

-- ------------------------------------------------------------------
-- Block scanner (time-sliced), used by #mine, #goto <block>, #farm
-- ------------------------------------------------------------------
local Scanner = {}
Scanner.__index = Scanner

function Scanner.new(match, cx, cy, cz, r, h)
    local s = setmetatable({ match = match, cx = cx, cy = cy, cz = cz, r = r, h = h, found = {}, done = false }, Scanner)
    s.ix, s.iy, s.iz = -r, -h, -r
    s.ymin = (W.dim == "nether") and 0 or -64
    s.ymax = (W.dim == "nether") and 127 or 320
    return s
end

function Scanner:step(budget)
    if self.done then return true end
    local gb = world.getBlock
    local bare = U.bare
    local match = self.match
    local r, h = self.r, self.h
    local cx, cy, cz = self.cx, self.cy, self.cz
    local ix, iy, iz = self.ix, self.iy, self.iz
    local n = 0
    while n < budget do
        local y = cy + iy
        if y >= self.ymin and y <= self.ymax then
            local x, z = cx + ix, cz + iz
            local ok, raw = pcall(gb, x, y, z)
            if ok and raw then
                local nm = bare(raw)
                if match(nm) then self.found[U.key(x, y, z)] = { x, y, z, nm } end
            end
        end
        n = n + 1
        iz = iz + 1
        if iz > r then
            iz = -r
            ix = ix + 1
            if ix > r then
                ix = -r
                iy = iy + 1
                if iy > h then
                    self.done = true
                    break
                end
            end
        end
    end
    self.ix, self.iy, self.iz = ix, iy, iz
    return self.done
end

-- ------------------------------------------------------------------
-- #mine <block...> [count]
-- ------------------------------------------------------------------
local ORE_Y = {
    diamond_ore = -58, deepslate_diamond_ore = -58, redstone_ore = -58, deepslate_redstone_ore = -58,
    lapis_ore = 0, deepslate_lapis_ore = 0, gold_ore = -16, deepslate_gold_ore = -16, iron_ore = 16,
    deepslate_iron_ore = 16, copper_ore = 48, deepslate_copper_ore = 48, coal_ore = 44, emerald_ore = 100,
    ancient_debris = 15, nether_gold_ore = 15, quartz_ore = 15,
}

function Proc.mine(names, count, quiet)
    local targets = {}
    for _, n in ipairs(names) do
        n = U.bare(n)
        if not n:find("_ore", 1, true) and not targets[n] and (n == "diamond" or n == "iron" or n == "gold" or n == "coal"
            or n == "copper" or n == "lapis" or n == "redstone" or n == "emerald") then
            n = n .. "_ore"
        end
        targets[n] = true
        if S.mineDeepslateVariants and n:sub(-4) == "_ore" and n:sub(1, 10) ~= "deepslate_" then
            targets["deepslate_" .. n] = true
        end
        if n == "redstone_ore" or n == "deepslate_redstone_ore" then
            targets["lit_" .. n] = true
            targets["lit_deepslate_redstone_ore"] = true
        end
        if n == "quartz_ore" or n == "nether_quartz_ore" then targets["quartz_ore"] = true end
    end
    local list = {}
    for n in pairs(targets) do list[#list + 1] = n end
    tsort(list)
    local m = {
        name = "mine", targets = targets, label = tconcat(list, ", "), count = count, mined = 0,
        known = {}, bad = {}, phase = "choose", scan = nil, scanT = 0, drops = {},
    }
    local function match(n) return targets[n] == true end

    function m:startScan()
        local fx, fy, fz = NAV.feet()
        self.scan = Scanner.new(match, fx, fy, fz, S.mineScanRadius, S.mineScanHeight)
        self.scanT = U.now()
    end
    function m:start() self:startScan() end
    function m:status()
        local s = fmt("Mining %s (%d", self.label, self.mined)
        if self.count then s = s .. "/" .. self.count end
        s = s .. ")"
        if self.phase == "explore" then s = s .. " - exploring" end
        return s
    end
    function m:prefY()
        local y
        for n in pairs(targets) do if ORE_Y[n] then y = ORE_Y[n] break end end
        return y
    end
    function m:tick(now)
        -- keep scanning in the background
        if self.scan and not self.scan.done then
            self.scan:step(S.mineScanBlocksPerFrame * 2)
            if self.scan.done then
                for k, v in pairs(self.scan.found) do
                    if not self.bad[k] or self.bad[k] < now then self.known[k] = v end
                end
            end
        end
        local fx, fy, fz = NAV.feet()
        if self.scan and self.scan.done and (now - self.scanT > 20000
            or U.dist3(fx, fy, fz, self.scan.cx, self.scan.cy, self.scan.cz) > 14) then
            self:startScan()
        end

        if self.phase == "break" then
            local t = self.target
            local r = ACT.mine(self.breakSt, t[1], t[2], t[3])
            if r == "running" then return true end
            local k = U.key(t[1], t[2], t[3])
            self.known[k] = nil
            IN.clear()
            if r == "done" then
                self.mined = self.mined + 1
                W.set(t[1], t[2], t[3], "air")
                -- veins: check neighbours of the mined block
                for i = 1, 6 do
                    local d = PF.ADJ6[i]
                    local ax, ay, az = t[1] + d[1], t[2] + d[2], t[3] + d[3]
                    local an = W.fresh(ax, ay, az)
                    if targets[an] then self.known[U.key(ax, ay, az)] = { ax, ay, az, an } end
                end
                if S.mineCollectDrops then self.drops[#self.drops + 1] = { t[1], t[2], t[3], now } end
                if self.count and self.mined >= self.count then
                    Bot.finish(fmt("Mined %d %s", self.mined, self.label))
                    return true
                end
            else
                self.bad[k] = now + 120000
            end
            self.phase = "choose"
            return true
        end

        if self.phase == "travel" or self.phase == "collect" or self.phase == "explore" then
            if NAV.state == "arrived" or NAV.state == "failed" or NAV.state == "idle" then
                local failed = NAV.state == "failed"
                local wasPhase = self.phase
                self.phase = "choose"
                if failed and wasPhase == "travel" and self.goalKeys then
                    for _, k in ipairs(self.goalKeys) do
                        self.known[k] = nil
                        self.bad[k] = now + 120000
                    end
                end
                if failed and wasPhase == "explore" then
                    self.exploreDir = (self.exploreDir or 0) + 1
                end
                NAV.stop()
            else
                -- re-target if something better shows up
                return false
            end
        end

        if self.phase == "choose" then
            -- count targets that vanished near us (mined while pathing)
            for k, v in pairs(self.known) do
                if U.dist3(fx, fy, fz, v[1], v[2], v[3]) < 7 then
                    local n = W.fresh(v[1], v[2], v[3])
                    if not targets[n] then
                        self.known[k] = nil
                        if K.passable(n) then self.mined = self.mined + 1 end
                    end
                end
            end
            if self.count and self.mined >= self.count then
                Bot.finish(fmt("Mined %d %s", self.mined, self.label))
                return true
            end
            -- adjacent target? break it now
            for k, v in pairs(self.known) do
                if G.getToBlock(v[1], v[2], v[3]).isGoal(fx, fy, fz) then
                    self.target = v
                    self.breakSt = {}
                    self.phase = "break"
                    return true
                end
            end
            -- collect recent drops first
            if #self.drops > 0 then
                local d = tremove(self.drops, 1)
                if now - d[4] < 30000 then
                    local gy = d[2]
                    for yy = d[2], d[2] - 4, -1 do
                        if K.standable(W.fresh(d[1], yy - 1, d[3])) then gy = yy break end
                    end
                    if not (fx == d[1] and fz == d[3]) then
                        NAV.set(G.near(d[1], gy, d[3], 0.5))
                        self.phase = "collect"
                        return false
                    end
                end
            end
            -- nearest known targets
            local cands = {}
            for k, v in pairs(self.known) do
                cands[#cands + 1] = { k = k, v = v, d = U.dist3(fx, fy, fz, v[1], v[2], v[3]) }
            end
            if #cands > 0 then
                tsort(cands, function(a, b) return a.d < b.d end)
                local goals, keys = {}, {}
                for i = 1, min(12, #cands) do
                    local v = cands[i].v
                    goals[#goals + 1] = G.getToBlock(v[1], v[2], v[3])
                    keys[#keys + 1] = cands[i].k
                end
                self.goalKeys = keys
                NAV.set(G.composite(goals))
                self.phase = "travel"
                return false
            end
            if self.scan and not self.scan.done then
                IN.clear()
                return true
            end
            if not S.exploreForBlocks then
                Bot.finish("No " .. self.label .. " found nearby")
                return true
            end
            -- explore: head to a good Y level, then tunnel
            local py = self:prefY()
            local ex, ez
            local dirs = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
            if not self.exploreDir then
                local dx, dz = U.dirFromYaw(P.yaw)
                if abs(dx) > abs(dz) then self.exploreDir = (dx > 0) and 0 or 2 else self.exploreDir = (dz > 0) and 1 or 3 end
            end
            local dd = dirs[(self.exploreDir % 4) + 1]
            ex, ez = fx + dd[1] * 32, fz + dd[2] * 32
            local ty = fy
            if py and abs(fy - py) > 4 and W.dim ~= "end" then ty = py end
            NAV.set(G.block(ex, ty, ez))
            self.phase = "explore"
            return false
        end
        return false
    end
    function m:stop() IN.clear() end
    return m
end

-- ------------------------------------------------------------------
-- #goto <block>  (walk next to the nearest block of that type)
-- ------------------------------------------------------------------
function Proc.gotoBlock(name)
    name = U.bare(name)
    local p = { name = "gotoblock", block = name, phase = "scan" }
    function p:start()
        local fx, fy, fz = NAV.feet()
        self.scan = Scanner.new(function(n) return n == name end, fx, fy, fz, 48, 24)
    end
    function p:status() return "Looking for " .. name end
    function p:tick(now)
        if self.phase == "scan" then
            IN.clear()
            if self.scan:step(S.mineScanBlocksPerFrame * 3) then
                local fx, fy, fz = NAV.feet()
                local list = {}
                for _, v in pairs(self.scan.found) do
                    list[#list + 1] = { v = v, d = U.dist3(fx, fy, fz, v[1], v[2], v[3]) }
                end
                if #list == 0 then
                    Bot.finish("No " .. name .. " found within 48 blocks")
                    return true
                end
                tsort(list, function(a, b) return a.d < b.d end)
                local goals = {}
                for i = 1, min(8, #list) do goals[i] = G.getToBlock(list[i].v[1], list[i].v[2], list[i].v[3]) end
                NAV.set(G.composite(goals))
                self.phase = "go"
            end
            return true
        end
        if NAV.state == "arrived" then Bot.finish("Reached " .. name)
        elseif NAV.state == "failed" then Bot.finish("\194\167cCouldn't reach " .. name) end
        return false
    end
    return p
end

-- ------------------------------------------------------------------
-- #tunnel : dig a 1x2 tunnel in the direction you face
-- ------------------------------------------------------------------
function Proc.tunnel(length)
    local t = { name = "tunnel" }
    function t:start()
        local dx, dz = U.dirFromYaw(P.yaw)
        if abs(dx) > abs(dz) then self.dx, self.dz = (dx > 0) and 1 or -1, 0 else self.dx, self.dz = 0, (dz > 0) and 1 or -1 end
        local fx, fy, fz = NAV.feet()
        self.y = fy
        self.endX, self.endZ = fx + self.dx * (length or 64), fz + self.dz * (length or 64)
        self:next()
    end
    function t:next()
        local fx, fy, fz = NAV.feet()
        local step = 12
        local tx, tz = fx + self.dx * step, fz + self.dz * step
        if (self.dx ~= 0 and (tx - self.endX) * self.dx > 0) or (self.dz ~= 0 and (tz - self.endZ) * self.dz > 0) then
            tx, tz = self.endX, self.endZ
        end
        self.tx, self.tz = tx, tz
        -- keep strictly in line: forbid leaving the tunnel line
        NAV.set(G.block(tx, self.y, tz), { allowPlace = true })
    end
    function t:status() return fmt("Tunnelling to %s", U.fmtPos(self.endX or 0, self.y or 0, self.endZ or 0)) end
    function t:tick(now)
        if NAV.state == "arrived" then
            if self.tx == self.endX and self.tz == self.endZ then Bot.finish("Tunnel finished") return true end
            self:next()
        elseif NAV.state == "failed" then
            Bot.finish("\194\167cTunnel blocked")
            return true
        end
        return false
    end
    return t
end
