
-- =====================================================================
-- Navigation: plan with A*, then walk the path with real inputs
-- =====================================================================
local NAV = {
    state = "idle", goal = nil, search = nil, path = nil, idx = 1, act = nil, avoid = {},
    fails = 0, waitUntil = 0, lastProgress = 0, lastPos = nil, opts = {}, partial = false,
    jumpUntil = 0, info = "",
}
local M = PF.M

function NAV.feet()
    return P.fx, floor(P.y + 0.2), P.fz
end

function NAV.inWater()
    local fx, fy, fz = NAV.feet()
    return K.isWater(W.fresh(fx, fy, fz))
end

function NAV.addAvoid(x, y, z, ms)
    NAV.avoid[U.key(x, y, z)] = U.now() + (ms or 60000)
end

function NAV.ctx()
    local opts = NAV.opts or {}
    local now = U.now()
    local avoid = {}
    for k, exp in pairs(NAV.avoid) do
        if exp > now then avoid[k] = true else NAV.avoid[k] = nil end
    end
    if opts.avoid then for k in pairs(opts.avoid) do avoid[k] = true end end
    local btCache = {}
    local creative = P.creative()
    return {
        allowBreak = S.allowBreak and opts.allowBreak ~= false,
        canPlace = S.allowPlace and opts.allowPlace ~= false and HB.throwaway() ~= nil,
        allowSwim = S.allowSwimming,
        allowDownward = S.allowDownward and S.allowBreak,
        allowDiagonal = S.allowDiagonal,
        maxFall = S.maxFallHeightNoWater,
        maxFallBucket = S.maxFallHeightBucket,
        hasBucket = S.allowWaterBucketFall and HB.has("water_bucket") and W.dim ~= "nether",
        walkCost = (S.allowSprint and P.hunger >= S.sprintMinHunger) and PF.COST.SPRINT or PF.COST.WALK,
        placePenalty = S.blockPlacementPenalty,
        breakPenalty = S.blockBreakAdditionalPenalty,
        breakTicks = function(n)
            local t = btCache[n]
            if t then return t end
            if creative then t = 1
            else
                local _, tool = HB.bestTool(K.toolFor(n))
                t = K.breakTicks(n, tool)
            end
            btCache[n] = t
            return t
        end,
        noBreak = opts.noBreak,
        noPlace = opts.noPlace,
        avoid = avoid,
        loaded = W.loaded,
        maxNodes = opts.maxNodes,
    }
end

function NAV.set(goal, opts)
    NAV.goal = goal
    NAV.opts = opts or {}
    NAV.state = "plan"
    NAV.path = nil
    NAV.search = nil
    NAV.act = nil
    NAV.fails = 0
    NAV.waitUntil = 0
end

function NAV.stop()
    NAV.state = "idle"
    NAV.goal = nil
    NAV.path = nil
    NAV.search = nil
    NAV.act = nil
    IN.clear()
end

function NAV.replan(delay)
    NAV.state = "plan"
    NAV.path = nil
    NAV.act = nil
    NAV.search = nil
    NAV.waitUntil = U.now() + (delay or 0)
    IN.clear()
end

function NAV.busy()
    return NAV.state == "plan" or NAV.state == "search" or NAV.state == "exec"
end

-- runs every frame: spend a slice of CPU on the A* search
function NAV.frame(now)
    if NAV.state ~= "search" or not NAV.search then return end
    local s = NAV.search
    local st = PF.step(s, S.pathTimeBudgetMS)
    if st == "running" then return end
    if st == "found" or st == "partial" then
        NAV.path = s.path
        NAV.partial = (st == "partial")
        NAV.idx = 1
        NAV.act = nil
        NAV.state = "exec"
        NAV.lastProgress = now
        NAV.lastPos = nil
        if st == "found" then NAV.fails = 0 end
        NAV.info = fmt("%d nodes, %s, %d explored, %dms", #s.path, NAV.partial and "partial" or "complete", s.expanded, floor(s.cpu))
        if S.chatDebug then U.chat("Path: " .. NAV.info) end
        if #s.path <= 1 then
            if NAV.goal.isGoal(s.sx, s.sy, s.sz) then NAV.state = "arrived" else NAV.replan(800) end
        end
    else
        NAV.fails = NAV.fails + 1
        NAV.info = fmt("no path (%d explored, %dms)", s.expanded, floor(s.cpu))
        if S.chatDebug then U.chat("Path search failed: " .. NAV.info) end
        if NAV.fails >= 3 then
            NAV.state = "failed"
        else
            NAV.replan(600)
        end
    end
    NAV.search = nil
end

function NAV.tick(now)
    local st = NAV.state
    if st == "idle" or st == "arrived" or st == "failed" then return end
    if st == "plan" then
        IN.clear()
        if now < NAV.waitUntil then return end
        if not (P.grounded or NAV.inWater()) then return end
        local fx, fy, fz = NAV.feet()
        -- about to fall (e.g. we just mined the block under us)? wait until we land
        if not NAV.inWater() and K.passable(W.fresh(fx, fy - 1, fz)) and not K.solid(W.fresh(fx, fy, fz)) then
            local supported = false
            for _, o in ipairs({ { 0.3, 0.3 }, { -0.3, 0.3 }, { 0.3, -0.3 }, { -0.3, -0.3 } }) do
                if K.solid(W.fresh(floor(P.x + o[1]), fy - 1, floor(P.z + o[2]))) then supported = true end
            end
            if not supported then return end
        end
        if NAV.goal.isGoal(fx, fy, fz) then
            NAV.state = "arrived"
            return
        end
        W.clear()
        NAV.search = PF.new(fx, fy, fz, NAV.goal, NAV.ctx())
        NAV.state = "search"
        return
    end
    if st == "search" then
        IN.clear()
        return
    end
    if st == "exec" then NAV.exec(now) end
end

local function sameDir(a, b, c)
    return c and b and a and (c.x - b.x) == (b.x - a.x) and (c.z - b.z) == (b.z - a.z) and c.y == b.y and b.y == a.y
end

function NAV.straightAhead()
    local path, i = NAV.path, NAV.idx
    local n = 0
    while path[i + 2] and sameDir(path[i], path[i + 1], path[i + 2]) and path[i + 2].kind == M.TRAVERSE do
        n = n + 1
        i = i + 1
        if n >= 6 then break end
    end
    return n + 1
end

local function arrivedAt(j)
    local path = NAV.path
    local n = path[j]
    local dist = U.dist2(P.x, P.z, n.x + 0.5, n.z + 0.5)
    local inW = NAV.inWater()
    if not (P.grounded or inW) then return false end
    if j >= #path then return dist < 0.45 end
    local nn = path[j + 1]
    if sameDir(path[j - 1], n, nn) and (nn.kind == M.TRAVERSE or nn.kind == M.DIAGONAL) then
        return dist < 0.95
    end
    if nn.kind == M.ASCEND or nn.kind == M.DESCEND or nn.kind == M.FALL then
        return dist < 0.6
    end
    return dist < 0.4
end

function NAV.advance(j)
    NAV.idx = j
    NAV.act = nil
    NAV.lastProgress = U.now()
end

function NAV.doAct(kind, pos, fn)
    local key = kind .. ":" .. tostring(U.key(pos[1], pos[2], pos[3]))
    if not NAV.act or NAV.act.key ~= key then
        NAV.act = { key = key, st = { protect = NAV.opts.noBreak } }
    end
    local r = fn(NAV.act.st)
    if r == "done" then
        NAV.act = nil
        NAV.lastProgress = U.now()
        return true
    elseif r ~= "running" then
        if S.chatDebug then U.chat(fmt("%s at %s: %s", kind, U.fmtPos(pos[1], pos[2], pos[3]), r)) end
        if r == "noitem" and kind == "place" then
            NAV.opts.allowPlace = false
        end
        local nxt = NAV.path[NAV.idx + 1]
        if nxt then NAV.addAvoid(nxt.x, nxt.y, nxt.z, 45000) end
        NAV.addAvoid(pos[1], pos[2], pos[3], 45000)
        NAV.replan(300)
    end
    return false
end

local function throwawayPred(it) return Settings.set("acceptableThrowawayItems")[it] end

function NAV.exec(now)
    local path = NAV.path
    local fx, fy, fz = NAV.feet()

    -- advance along the path (also skips ahead if we got further than expected),
    -- but never past a move whose blocks haven't actually been placed yet
    for j = min(#path, NAV.idx + 6), NAV.idx + 1, -1 do
        local n = path[j]
        if n.x == fx and n.y == fy and n.z == fz then
            local placedOk = true
            for k = NAV.idx + 1, j do
                if path[k].place then
                    local _, pl = PF.describe(path[k - 1], path[k])
                    for _, c in ipairs(pl) do
                        if not K.solid(W.fresh(c[1], c[2], c[3])) then placedOk = false end
                    end
                end
            end
            if placedOk and (j > NAV.idx + 1 or arrivedAt(j)) then
                NAV.advance(j)
            end
            break
        end
    end

    if NAV.idx >= #path then
        IN.clear()
        if NAV.goal.isGoal(fx, fy, fz) then
            NAV.state = "arrived"
        else
            NAV.replan(0)
        end
        return
    end

    local cur, nxt = path[NAV.idx], path[NAV.idx + 1]

    -- off the path?
    local onCur = fx == cur.x and fy == cur.y and fz == cur.z
    local onNxt = fx == nxt.x and fy == nxt.y and fz == nxt.z
    if not onCur and not onNxt and (P.grounded or NAV.inWater()) then
        local dC = U.dist3(P.x, P.y, P.z, cur.x + 0.5, cur.y, cur.z + 0.5)
        local dN = U.dist3(P.x, P.y, P.z, nxt.x + 0.5, nxt.y, nxt.z + 0.5)
        local wrongLevel = fy ~= cur.y and fy ~= nxt.y and P.grounded
        if min(dC, dN) > 1.6 or wrongLevel then
            if S.chatDebug then U.chat("Off path, replanning") end
            NAV.replan(0)
            return
        end
    end

    -- obstacles: clear cells, then place cells
    local clear, place = PF.describe(cur, nxt)
    for i = 1, #clear do
        local c = clear[i]
        local n = W.fresh(c[1], c[2], c[3])
        if not (K.passable(n) or K.isWater(n)) then
            NAV.doAct("mine", c, function(st) return ACT.mine(st, c[1], c[2], c[3]) end)
            return
        end
    end
    for i = 1, #place do
        local p = place[i]
        local n = W.fresh(p[1], p[2], p[3])
        if K.passable(n) or K.isWater(n) then
            if nxt.kind == M.PILLAR then
                NAV.doAct("pillar", p, function(st) return ACT.pillar(st, p[1], p[2], p[3]) end)
            else
                NAV.doAct("place", p, function(st)
                    if nxt.kind == M.TRAVERSE and not st.bridge then
                        st.bridge = true
                        st.sfx, st.sfz = cur.x, cur.z
                    end
                    return ACT.place(st, p[1], p[2], p[3], throwawayPred)
                end)
            end
            return
        end
    end
    NAV.act = nil

    -- stuck detection
    if not NAV.lastPos or U.dist3(P.x, P.y, P.z, NAV.lastPos[1], NAV.lastPos[2], NAV.lastPos[3]) > 0.15 then
        NAV.lastPos = { P.x, P.y, P.z }
        NAV.lastProgress = now
    end
    local stuckFor = now - NAV.lastProgress
    if stuckFor > 6000 then
        if S.chatDebug then U.chat("Stuck, replanning") end
        NAV.addAvoid(nxt.x, nxt.y, nxt.z, 30000)
        NAV.replan(0)
        return
    elseif stuckFor > 2500 and now > NAV.jumpUntil + 1500 then
        NAV.jumpUntil = now + 300
    end

    NAV.move(cur, nxt, now)
    if now < NAV.jumpUntil then IN.press("jump") end
end

function NAV.move(cur, nxt, now)
    local kind = nxt.kind
    local tx, tz = nxt.x + 0.5, nxt.z + 0.5
    local dist = U.dist2(P.x, P.z, tx, tz)
    local inW = NAV.inWater()
    IN.clear()

    if kind == M.DOWNWARD then
        if dist > 0.2 then
            IN.look(U.yawTo(P.x, P.z, tx, tz), S.walkPitch)
            IN.press("sneak")
            IN.press("forward")
        end
        return
    elseif kind == M.SWIM_UP then
        IN.press("jump")
        if dist > 0.3 then
            IN.look(U.yawTo(P.x, P.z, tx, tz), S.walkPitch)
            IN.press("forward")
        end
        return
    elseif kind == M.SWIM_DOWN then
        IN.press("sneak")
        return
    elseif kind == M.PILLAR then
        IN.press("jump")
        return
    end

    -- walking moves
    local aimX, aimZ = tx, tz
    local nn = NAV.path[NAV.idx + 2]
    if (kind == M.TRAVERSE or kind == M.DIAGONAL) and sameDir(cur, nxt, nn) then
        aimX, aimZ = nn.x + 0.5, nn.z + 0.5
    end
    if dist < 0.15 then aimX, aimZ = tx + (nxt.x - cur.x), tz + (nxt.z - cur.z) end
    local yaw = U.yawTo(P.x, P.z, aimX, aimZ)
    IN.look(yaw, S.walkPitch)
    local yawErr = abs(U.wrap180(yaw - P.yaw))
    if yawErr < 35 then IN.press("forward") end

    if kind == M.ASCEND and (P.grounded or inW) and dist < 1.3 then
        IN.press("jump")
    end
    if inW and (kind == M.TRAVERSE or kind == M.ASCEND or kind == M.DIAGONAL) then
        IN.press("jump")
    end
    if S.allowSprint and P.hunger >= S.sprintMinHunger and (kind == M.TRAVERSE or kind == M.DIAGONAL)
        and not inW and yawErr < 12 and NAV.straightAhead() >= 3 then
        IN.press("sprint")
    end
    if (kind == M.DESCEND or kind == M.FALL) and not P.grounded and dist < 0.3 then
        IN.release("forward")
    end
    -- coast into the last node of the path / before a sharp turn
    if NAV.idx + 1 >= #NAV.path and dist < 0.5 then
        IN.release("forward")
        if dist > 0.2 then IN.press("sneak") IN.press("forward") end
    end
end
