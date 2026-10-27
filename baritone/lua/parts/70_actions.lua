
-- =====================================================================
-- Actions: break a block, place a block, pillar up. Each is a small state
-- machine called once per tick with a persistent state table `st`.
-- Return values: "running", "done", "failed", "noitem", "noface"
-- =====================================================================
local ACT = {}

-- Walk the voxel grid from the eye to (tx,ty,tz). Returns true when the first
-- solid block the ray enters is (bx,by,bz) (or nothing solid is in the way).
function ACT.lineClear(ex, ey, ez, tx, ty, tz, bx, by, bz, ix, iy, iz)
    local dx, dy, dz = tx - ex, ty - ey, tz - ez
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-6 then return true end
    dx, dy, dz = dx / len, dy / len, dz / len
    local x, y, z = floor(ex), floor(ey), floor(ez)
    local sx, sy, sz = dx > 0 and 1 or -1, dy > 0 and 1 or -1, dz > 0 and 1 or -1
    local function tmax(e, c, d)
        if d == 0 then return INF end
        if d > 0 then return (c + 1 - e) / d end
        return (e - c) / -d
    end
    local tx_, ty_, tz_ = tmax(ex, x, dx), tmax(ey, y, dy), tmax(ez, z, dz)
    local ddx = dx ~= 0 and 1 / abs(dx) or INF
    local ddy = dy ~= 0 and 1 / abs(dy) or INF
    local ddz = dz ~= 0 and 1 / abs(dz) or INF
    for _ = 1, 64 do
        local t
        if tx_ < ty_ and tx_ < tz_ then t = tx_ tx_ = tx_ + ddx x = x + sx
        elseif ty_ < tz_ then t = ty_ ty_ = ty_ + ddy y = y + sy
        else t = tz_ tz_ = tz_ + ddz z = z + sz end
        if t > len + 0.01 then return true end
        if x == bx and y == by and z == bz then return true end
        if not (x == ix and y == iy and z == iz) then
            local n = W.get(x, y, z)
            -- anything but air/water stops the crosshair (plants are selectable in Bedrock)
            if not (K.isAir(n) or K.isWater(n)) then return false end
        end
    end
    return true
end

-- points to try on a face: centre first, then inset corners
local FACE_OFFS = { { 0, 0 }, { 0.3, 0.3 }, { -0.3, 0.3 }, { 0.3, -0.3 }, { -0.3, -0.3 } }
local function facePoints(cx, cy, cz, d)
    local pts = {}
    for _, o in ipairs(FACE_OFFS) do
        if d[1] ~= 0 then pts[#pts + 1] = { cx, cy + o[1], cz + o[2] }
        elseif d[2] ~= 0 then pts[#pts + 1] = { cx + o[1], cy, cz + o[2] }
        else pts[#pts + 1] = { cx + o[1], cy + o[2], cz } end
    end
    return pts
end

-- a visible point on block (x,y,z) to aim at (for mining)
function ACT.aimPoint(x, y, z, ex, ey, ez)
    if not ex then ex, ey, ez = P.eye() end
    local best, bx, by, bz = INF, x + 0.5, y + 0.5, z + 0.5
    for i = 1, 6 do
        local d = PF.ADJ6[i]
        local fx, fy, fz = x + 0.5 + d[1] * 0.5, y + 0.5 + d[2] * 0.5, z + 0.5 + d[3] * 0.5
        local facing = (ex - fx) * d[1] + (ey - fy) * d[2] + (ez - fz) * d[3]
        if facing > 0 then
            local nb = W.get(x + d[1], y + d[2], z + d[3])
            if K.passable(nb) or K.isWater(nb) then
                local dist = U.dist3(ex, ey, ez, fx, fy, fz)
                if dist < best then
                    for _, pt in ipairs(facePoints(fx - d[1] * 0.02, fy - d[2] * 0.02, fz - d[3] * 0.02, d)) do
                        if ACT.lineClear(ex, ey, ez, pt[1], pt[2], pt[3], x, y, z) then
                            best, bx, by, bz = dist, pt[1], pt[2], pt[3]
                            break
                        end
                    end
                end
            end
        end
    end
    return bx, by, bz, best
end

function ACT.equipToolFor(n)
    if not S.autoTool then return end
    local cat = K.toolFor(n)
    local slot = HB.bestTool(cat)
    if slot then IN.select(slot) return end
    -- no right tool: avoid wasting a good tool's durability by switching to an empty hand / block
    local cur = P.mainhand
    if cur and K.itemToolType(cur) and K.itemToolType(cur) ~= cat then
        local empty = HB.find(function(it) return not K.itemToolType(it) end)
        if empty then IN.select(empty) end
    end
end

function ACT.mine(st, x, y, z)
    local n = W.fresh(x, y, z)
    -- done once the block is gone (crops/plants are passable, so compare names)
    if K.isAir(n) or K.isWater(n) then
        IN.lmb = false
        return "done"
    end
    if K.passable(n) then
        if (st.name and n ~= st.name) or (not st.name and not st.breakPlants) then
            IN.lmb = false
            return "done"
        end
    end
    local now = U.now()
    if not st.t0 then
        st.t0 = now
        st.miss = 0
        local ticks = K.breakTicks(n, P.mainhand)
        if P.creative() then ticks = 2 end
        st.budget = ticks * 50 * 3 + 4000
        st.name = n
    end
    if n ~= st.name then -- block changed (e.g. gravel fell): restart timer
        st.t0, st.name = now, n
    end
    if now - st.t0 > st.budget then
        IN.lmb = false
        return "failed"
    end
    ACT.equipToolFor(n)
    IN.clear()
    local ax, ay, az, dist = ACT.aimPoint(x, y, z)
    if dist == INF or dist > S.buildReach + 1 then
        IN.lookAt(x + 0.5, y + 0.5, z + 0.5)
    else
        IN.lookAt(ax, ay, az)
    end
    if P.creative() and st.clickedAt and now - st.clickedAt < 250 then
        return "running"
    end
    local hit = W.raycast(S.buildReach + 1)
    if hit and hit.bx == x and hit.by == y and hit.bz == z then
        IN.lmb = true
        st.miss = 0
        if P.creative() then st.clickedAt = now end
    else
        IN.lmb = false
        if IN.aimError() < 2 then
            st.miss = st.miss + 1
            -- something else is in the way: break it if allowed
            if hit and st.miss > 10 then
                local hn = W.fresh(hit.bx, hit.by, hit.bz)
                if K.solid(hn) and not K.unbreakable(hn) and S.allowBreak
                    and not (st.protect and st.protect(U.key(hit.bx, hit.by, hit.bz))) then
                    IN.lmb = true
                end
            end
            if st.miss > 80 then return "failed" end
        end
    end
    return "running"
end

-- Choose the face to click to place a block at (x,y,z).
-- Returns support block coords, face id, aim point; or nil.
function ACT.findPlaceFace(x, y, z, reach, ex, ey, ez, cached, exclude)
    if not ex then ex, ey, ez = P.eye() end
    local best
    for i = 1, 6 do
        local d = PF.ADJ6[i]
        local sx, sy, sz = x + d[1], y + d[2], z + d[3]
        local sn = cached and W.get(sx, sy, sz) or W.fresh(sx, sy, sz)
        if K.solid(sn) then
            -- face of the support block that points back at (x,y,z)
            local fx, fy, fz = x + 0.5 + d[1] * 0.5, y + 0.5 + d[2] * 0.5, z + 0.5 + d[3] * 0.5
            local facing = (ex - fx) * (-d[1]) + (ey - fy) * (-d[2]) + (ez - fz) * (-d[3])
            if facing > 0.05 then
                local dist = U.dist3(ex, ey, ez, fx, fy, fz)
                local score = dist + (d[2] == -1 and -0.5 or 0)
                if dist <= reach and (not best or score < best.score) then
                    for pi, pt in ipairs(facePoints(fx + d[1] * 0.02, fy + d[2] * 0.02, fz + d[3] * 0.02, d)) do
                        if not (exclude and exclude[i * 10 + pi])
                            and ACT.lineClear(ex, ey, ez, pt[1], pt[2], pt[3], sx, sy, sz, x, y, z) then
                            best = { sx = sx, sy = sy, sz = sz, face = W.faceFromDir(-d[1], -d[2], -d[3]),
                                ax = pt[1], ay = pt[2], az = pt[3], score = score, id = i * 10 + pi }
                            break
                        end
                    end
                end
            end
        end
    end
    return best
end

-- Goals: stand somewhere we can actually see a face to place against / mine
function G.placeAt(tx, ty, tz, reach)
    local base = G.reach(tx, ty, tz, reach)
    return {
        kind = "block", x = tx, y = ty, z = tz, desc = fmt("GoalPlace{%s}", U.fmtPos(tx, ty, tz)),
        h = base.h,
        isGoal = function(x, y, z)
            if not base.isGoal(x, y, z) then return false end
            return ACT.findPlaceFace(tx, ty, tz, reach, x + 0.5, y + 1.62, z + 0.5, true) ~= nil
        end,
    }
end

function G.breakAt(tx, ty, tz, reach)
    local base = G.reach(tx, ty, tz, reach)
    return {
        kind = "block", x = tx, y = ty, z = tz, desc = fmt("GoalBreak{%s}", U.fmtPos(tx, ty, tz)),
        h = base.h,
        isGoal = function(x, y, z)
            if not base.isGoal(x, y, z) then return false end
            local _, _, _, d = ACT.aimPoint(tx, ty, tz, x + 0.5, y + 1.62, z + 0.5)
            return d <= reach
        end,
    }
end

-- itemSel: item name (string) or predicate(itemName) -> bool
function ACT.place(st, x, y, z, itemSel, wantName)
    local n = W.fresh(x, y, z)
    if st.orig == nil then st.orig = n end
    -- placed: something solid appeared, or a different (passable) block such as a crop
    if not (K.passable(n) or K.isWater(n)) or (n ~= st.orig and not K.isAir(n) and not K.isWater(n)) then
        IN.rmbHold = false
        if wantName and K.canon(n) ~= K.canon(wantName) then return "wrong" end
        return "done"
    end
    local now = U.now()
    if not st.t0 then st.t0 = now st.clicks = 0 end
    if now - st.t0 > 9000 then return "failed" end
    local slot
    if type(itemSel) == "function" then slot = HB.find(itemSel) else slot = HB.slotOf(itemSel) end
    if not slot then return "noitem" end
    IN.select(slot)
    st.exclude = st.exclude or {}
    local f = ACT.findPlaceFace(x, y, z, S.buildReach, nil, nil, nil, false, st.exclude)
    if not f then
        if st.bridge then return ACT.bridgeCreep(st, x, y, z) end
        return "noface"
    end
    IN.clear()
    IN.press("sneak")
    IN.lookAt(f.ax, f.ay, f.az)
    if P.slot ~= slot then return "running" end
    local hit = W.raycast(S.buildReach + 0.5)
    local onSupport = hit and hit.bx == f.sx and hit.by == f.sy and hit.bz == f.sz and (hit.fid == nil or hit.fid == f.face)
    local onPlant = hit and hit.bx == x and hit.by == y and hit.bz == z and K.class(n) == K.C_PASS
    if onSupport or onPlant then
        st.missT = nil
        if not st.lastClick or now - st.lastClick > 350 then
            IN.click()
            st.lastClick = now
            st.clicks = st.clicks + 1
        end
    elseif IN.aimError() < 1.5 then
        -- aimed, but the crosshair lands on something else: try another point
        st.missT = st.missT or now
        if now - st.missT > 500 then
            st.exclude[f.id] = true
            st.missT = nil
        end
    end
    if st.clicks > 6 then return "failed" end
    return "running"
end

-- Sneak backwards toward the edge so the side face of the block we stand
-- on becomes visible, then place against it (classic bridging).
function ACT.bridgeCreep(st, x, y, z)
    if not st.sfx then st.sfx, st.sfz = P.fx, P.fz end
    local fx, fz = st.sfx, st.sfz
    local dirX, dirZ = x - fx, z - fz
    if abs(dirX) + abs(dirZ) ~= 1 then return "noface" end
    IN.clear()
    IN.press("sneak")
    local backYaw = U.yawTo(x + 0.5, z + 0.5, fx + 0.5, fz + 0.5)
    local faceX, faceY, faceZ = fx + 0.5 + dirX * 0.5, y + 0.5, fz + 0.5 + dirZ * 0.5
    local ex, ey, ez = P.eye()
    local pitch = U.pitchTo(ex, ey, ez, faceX, faceY, faceZ)
    IN.look(backYaw, max(pitch, 70))
    local over = (P.x - (fx + 0.5)) * dirX + (P.z - (fz + 0.5)) * dirZ
    if over < 0.78 and abs(U.wrap180(backYaw - P.yaw)) < 20 then
        IN.press("back")
    end
    return "running"
end

function ACT.pillar(st, x, y, z)
    local now = U.now()
    if not st.t0 then st.t0 = now st.phase = "aim" end
    if now - st.t0 > 6000 then return "failed" end
    if K.solid(W.fresh(x, y, z)) and P.fy >= y + 1 and P.grounded then return "done" end
    local slot = HB.throwaway()
    if not slot then return "noitem" end
    IN.select(slot)
    IN.clear()
    IN.look(P.yaw, 89.9)
    if st.phase == "aim" then
        if P.pitch > 84 and P.slot == slot and P.grounded then
            st.phase = "jump"
            st.jumpT = now
        end
    elseif st.phase == "jump" then
        IN.press("jump")
        if now - st.jumpT > 120 then st.phase = "air" end
    elseif st.phase == "air" then
        if P.y >= y + 1.02 then
            local hit = W.raycast(3)
            if hit and hit.by == y - 1 and hit.bx == x and hit.bz == z and (hit.fid == nil or hit.fid == 1) then
                if not st.lastClick or now - st.lastClick > 250 then
                    IN.click()
                    st.lastClick = now
                end
            end
        end
        if P.grounded and now - st.jumpT > 600 then
            if K.solid(W.fresh(x, y, z)) then return "done" end
            st.phase = "aim"
        end
    end
    return "running"
end

-- =====================================================================
-- Fall guard: water-bucket clutch when a fall would hurt
-- =====================================================================
local FG = { active = false }

function FG.dangerous()
    if P.creative() or P.gamemode == 3 then return false end
    if P.grounded or P.vy > -0.45 then return false end
    if W.dim == "nether" then return false end
    if Bot and Bot.proc and Bot.proc.name == "elytra" then return false end
    if P.chest == "elytra" and P.horizSpeed() > 0.6 then return false end
    local gy, gn = W.groundBelow(P.fx, P.fy, P.fz, 80)
    if not gy then return false end
    if K.isWater(gn) then return false end
    local start = P.fallStartY or P.y
    local total = start - (gy + 1)
    return total > S.maxFallHeightNoWater + 0.6, gy
end

function FG.tick()
    local now = U.now()
    if not FG.active then
        if not S.fallGuard and not (Bot and Bot.proc) then return false end
        if not Helper.connected or not IN.calibrated() then return false end
        local danger = FG.dangerous()
        if not danger then return false end
        local slot = HB.slotOf("water_bucket")
        if not slot then return false end
        FG.active = true
        FG.phase = "fall"
        FG.prevSlot = P.slot
        FG.t0 = now
        FG.slot = slot
        if S.chatDebug then U.chat("Fall guard: water bucket") end
    end
    IN.clear()
    if now - FG.t0 > 12000 then FG.active = false return false end
    if FG.phase == "fall" then
        IN.select(FG.slot)
        IN.look(P.yaw, 89.9)
        local feet = W.fresh(P.fx, P.fy, P.fz)
        if P.grounded or K.isWater(feet) then
            FG.phase = "landed"
            FG.landT = now
        elseif P.mainhand == "water_bucket" and P.pitch > 70 then
            local hit = W.raycast(5.5)
            if hit and (hit.fid == nil or hit.fid == 1) and now - IN.lastClick > 60 then
                IN.click()
            end
        elseif P.mainhand == "bucket" then
            FG.phase = "placed"
        end
    elseif FG.phase == "placed" then
        IN.look(P.yaw, 89.9)
        local feet = W.fresh(P.fx, P.fy, P.fz)
        if P.grounded or K.isWater(feet) then
            FG.phase = "landed"
            FG.landT = now
        end
    elseif FG.phase == "landed" then
        IN.look(P.yaw, 89.9)
        if now - FG.landT > 250 then
            if P.mainhand == "bucket" then
                if now - IN.lastClick > 400 then IN.click() end
                if now - FG.landT > 3000 then FG.phase = "done" end
            else
                FG.phase = "done"
            end
        end
    elseif FG.phase == "done" then
        if FG.prevSlot then IN.select(FG.prevSlot) end
        FG.active = false
        IN.clear()
        return false
    end
    return true
end
