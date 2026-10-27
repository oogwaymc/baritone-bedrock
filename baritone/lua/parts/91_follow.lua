
-- =====================================================================
-- #follow  (experimental)
-- Flarial's script API gives each entity's *distance* to us but not its
-- position, so we locate the target by trilateration: distance samples
-- taken from several of our own positions pin down where it is.
-- =====================================================================
local function solve3(m, v)
    -- Cramer's rule for a 3x3 system m * t = v
    local a, b, c = m[1], m[2], m[3]
    local det = a[1] * (b[2] * c[3] - b[3] * c[2]) - a[2] * (b[1] * c[3] - b[3] * c[1]) + a[3] * (b[1] * c[2] - b[2] * c[1])
    if abs(det) < 1e-6 then return nil end
    local function d(col)
        local r = {}
        for i = 1, 3 do
            local row = { m[i][1], m[i][2], m[i][3] }
            row[col] = v[i]
            r[i] = row
        end
        local A, B, C = r[1], r[2], r[3]
        return A[1] * (B[2] * C[3] - B[3] * C[2]) - A[2] * (B[1] * C[3] - B[3] * C[1]) + A[3] * (B[1] * C[2] - B[2] * C[1])
    end
    return d(1) / det, d(2) / det, d(3) / det
end

local function trilaterate(samples)
    local n = #samples
    if n < 5 then return nil end
    local mx, my, mz, md2, mp2 = 0, 0, 0, 0, 0
    for i = 1, n do
        local s = samples[i]
        mx, my, mz = mx + s[1], my + s[2], mz + s[3]
        md2 = md2 + s[4] * s[4]
        mp2 = mp2 + s[1] * s[1] + s[2] * s[2] + s[3] * s[3]
    end
    mx, my, mz, md2, mp2 = mx / n, my / n, mz / n, md2 / n, mp2 / n
    local vx, vy, vz = 0, 0, 0
    for i = 1, n do
        local s = samples[i]
        vx = vx + (s[1] - mx) ^ 2
        vy = vy + (s[2] - my) ^ 2
        vz = vz + (s[3] - mz) ^ 2
    end
    vx, vy, vz = vx / n, vy / n, vz / n
    if vx + vz < 0.25 or vx < 0.02 or vz < 0.02 then return nil, "spread" end
    -- rows: -2 (P_i - Pm) . T = (d_i^2 - md2) - (|P_i|^2 - mp2)
    local use3 = vy > 0.08
    local M = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    local V = { 0, 0, 0 }
    for i = 1, n do
        local s = samples[i]
        local a = { -2 * (s[1] - mx), -2 * (s[2] - my), -2 * (s[3] - mz) }
        local b = (s[4] * s[4] - md2) - ((s[1] * s[1] + s[2] * s[2] + s[3] * s[3]) - mp2)
        for r = 1, 3 do
            for c = 1, 3 do M[r][c] = M[r][c] + a[r] * a[c] end
            V[r] = V[r] + a[r] * b
        end
    end
    local tx, ty, tz
    if use3 then
        tx, ty, tz = solve3(M, V)
        if not tx then use3 = false end
    end
    if not use3 then
        -- 2D solve in x/z, then recover y from the distances
        local a11, a12, a22 = M[1][1], M[1][3], M[3][3]
        local b1, b2 = V[1], V[3]
        local det = a11 * a22 - a12 * a12
        if abs(det) < 1e-6 then return nil, "spread" end
        tx = (b1 * a22 - a12 * b2) / det
        tz = (a11 * b2 - a12 * b1) / det
        local sum, cnt = 0, 0
        for i = 1, n do
            local s = samples[i]
            local h2 = (tx - s[1]) ^ 2 + (tz - s[3]) ^ 2
            local r = s[4] * s[4] - h2
            if r > 0 then sum = sum + sqrt(r) cnt = cnt + 1 else cnt = cnt + 1 end
        end
        local dyAbs = (cnt > 0) and (sum / cnt) or 0
        local up, dn = my + dyAbs, my - dyAbs
        -- pick the candidate standing on something
        local function score(eyeY)
            local fy = floor(eyeY - 1.62 + 0.2)
            local ok = K.passable(W.get(floor(tx), fy, floor(tz))) and K.solid(W.get(floor(tx), fy - 1, floor(tz)))
            return ok and 1 or 0
        end
        local su, sd = score(up), score(dn)
        if su > sd then ty = up elseif sd > su then ty = dn else ty = (abs(up - my) <= abs(dn - my)) and up or dn end
        if dyAbs < 0.6 then ty = my end
    end
    local err = 0
    for i = 1, n do
        local s = samples[i]
        local d = U.dist3(tx, ty, tz, s[1], s[2], s[3])
        err = err + (d - s[4]) ^ 2
    end
    err = sqrt(err / n)
    return { x = tx, y = ty, z = tz, err = err }
end

function Proc.follow(mode, who)
    local f = {
        name = "follow", mode = mode, who = who and who:lower() or nil, samples = {}, est = nil,
        lastSeen = 0, probeStep = 0, probeT = 0, lastGoal = nil, lost = false,
    }
    function f:status()
        local s = "Following " .. (self.who or self.mode)
        if self.est then s = s .. fmt(" (~%d, %d, %d)", floor(self.est.x), floor(self.est.y), floor(self.est.z)) end
        return s .. (NATIVE and "" or " [experimental]")
    end
    function f:findTarget()
        local ok, ents = pcall(world.getEntities, 160)
        if not ok or type(ents) ~= "table" then return nil end
        local best, bestD
        local myName = P.name:lower()
        local function call(e, m)
            local okc, v = pcall(function() return e[m](e) end)
            if okc then return v end
            return nil
        end
        for _, e in ipairs(ents) do
            local isTable = type(e) == "table" and type(e.x) == "number" and type(e.isValid) ~= "function"
            if isTable or call(e, "isValid") then
                local nm, tid, d
                if isTable then
                    -- DLL: real positions are available
                    nm = tostring(e.name or ""):gsub("\194\167.", ""):lower()
                    tid = U.bare(e.type or "")
                    if e.player then tid = "player" end
                    d = tonumber(e.dist) or 0
                else
                    nm = tostring(call(e, "getName") or ""):lower()
                    tid = U.bare(call(e, "getTypeId") or "")
                    d = tonumber(call(e, "distanceToPlayer")) or 0
                end
                local match = false
                if self.mode == "player" then
                    match = (tid == "player") and (nm == self.who or nm:find(self.who, 1, true) ~= nil)
                elseif self.mode == "players" then
                    match = tid == "player" and nm ~= myName
                elseif self.mode == "entity" then
                    match = (self.who == nil) or tid == self.who or tid:find(self.who, 1, true) ~= nil
                end
                if match and d > 0 and (not bestD or d < bestD) then best, bestD = e, d end
                if match and tid == "player" then self.isPlayer = true end
            end
        end
        return best, bestD
    end
    function f:tick(now)
        local e, d = self:findTarget()
        if not e then
            IN.clear()
            if now - self.lastSeen > 5000 and not self.lost then
                U.chat("Can't see " .. (self.who or self.mode) .. " - waiting")
                self.lost = true
            end
            return true
        end
        self.lastSeen = now
        self.lost = false
        if type(e) == "table" and type(e.x) == "number" and type(e.isValid) ~= "function" then
            -- exact position from the game: no need to estimate
            self.est = { x = e.x, y = e.y, z = e.z, err = 0, t = now }
            if d <= S.followRadius + 0.6 then
                NAV.stop()
                IN.clear()
                return true
            end
            return self:pathTo(now)
        end
        local ex, ey, ez = P.eye()
        local samples = self.samples
        local last = samples[#samples]
        if not last or U.dist3(last[1], last[2], last[3], ex, ey, ez) > 0.05 or now - last[5] > 250 then
            samples[#samples + 1] = { ex, ey, ez, d, now }
        end
        while #samples > 0 and (now - samples[1][5] > 2500 or #samples > 50) do tremove(samples, 1) end
        local est, why = trilaterate(samples)
        if est and est.err < 1.5 then
            if self.isPlayer then est.y = est.y - 1.62 end
            est.t = now
            self.est = est
        end

        if d <= S.followRadius + 0.6 then
            NAV.stop()
            IN.clear()
            return true
        end
        if self.est and now - self.est.t < 2500 then
            return self:pathTo(now)
        end
        -- not enough geometry: walk a small square to collect samples
        NAV.stop()
        IN.clear()
        if now - self.probeT > 450 then
            self.probeStep = (self.probeStep + 1) % 4
            self.probeT = now
        end
        local keys = { "forward", "left", "back", "right" }
        IN.press(keys[self.probeStep + 1])
        return true
    end
    function f:pathTo(now)
        do
            local gx, gy, gz = floor(self.est.x), floor(self.est.y + 0.2), floor(self.est.z)
            -- snap the estimate onto the ground nearby
            for dy = 0, 4 do
                local found = false
                for _, yy in ipairs({ gy - dy, gy + dy }) do
                    if K.passable(W.get(gx, yy, gz)) and K.passable(W.get(gx, yy + 1, gz)) and K.solid(W.get(gx, yy - 1, gz)) then
                        gy = yy
                        found = true
                        break
                    end
                end
                if found then break end
            end
            local lg = self.lastGoal
            local moved = not lg or U.dist3(lg[1], lg[2], lg[3], gx, gy, gz) > 2.5
            local navDone = NAV.state == "failed" or NAV.state == "arrived" or NAV.state == "idle"
            if (moved and now - (self.lastSetT or 0) > 1200) or (navDone and now - (self.lastSetT or 0) > 600) then
                self.lastGoal = { gx, gy, gz }
                self.lastSetT = now
                NAV.set(G.nearXZ(gx, gy, gz, S.followRadius, 3), { maxNodes = 6000 })
            end
            return false
        end
    end
    function f:stop() NAV.stop() end
    return f
end
