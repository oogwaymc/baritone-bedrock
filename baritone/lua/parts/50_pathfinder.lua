
-- =====================================================================
-- Goals
-- =====================================================================
local G = {}
local SQRT2 = math.sqrt(2)

local function hXZ(dx, dz)
    dx, dz = abs(dx), abs(dz)
    local diag = min(dx, dz)
    local straight = max(dx, dz) - diag
    return (straight + diag * SQRT2) * S.costHeuristic
end

local function hY(dy) return abs(dy) * 4 end

function G.block(gx, gy, gz)
    return {
        kind = "block", x = gx, y = gy, z = gz,
        desc = fmt("GoalBlock{%s}", U.fmtPos(gx, gy, gz)),
        isGoal = function(x, y, z) return x == gx and y == gy and z == gz end,
        h = function(x, y, z) return hXZ(gx - x, gz - z) + hY(gy - y) end,
    }
end

function G.xz(gx, gz)
    return {
        kind = "xz", x = gx, z = gz,
        desc = fmt("GoalXZ{%s}", U.fmtPos(gx, gz)),
        isGoal = function(x, y, z) return x == gx and z == gz end,
        h = function(x, y, z) return hXZ(gx - x, gz - z) end,
    }
end

function G.y(gy)
    return {
        kind = "y", y = gy,
        desc = fmt("GoalYLevel{%d}", gy),
        isGoal = function(x, y, z) return y == gy end,
        h = function(x, y, z) return hY(gy - y) end,
    }
end

function G.near(gx, gy, gz, r)
    local r2 = r * r
    return {
        kind = "near", x = gx, y = gy, z = gz, r = r,
        desc = fmt("GoalNear{%s, r=%s}", U.fmtPos(gx, gy, gz), tostring(r)),
        isGoal = function(x, y, z)
            local dx, dy, dz = x - gx, y - gy, z - gz
            return dx * dx + dy * dy + dz * dz <= r2
        end,
        h = function(x, y, z)
            local d = U.dist3(x, y, z, gx, gy, gz)
            return max(0, d - r) * S.costHeuristic
        end,
    }
end

-- within r blocks horizontally of (gx,gz) and within ytol of gy
function G.nearXZ(gx, gy, gz, r, ytol)
    local r2 = r * r
    return {
        kind = "near", x = gx, y = gy, z = gz, r = r,
        desc = fmt("GoalNear{%s, r=%s}", U.fmtPos(gx, gy, gz), tostring(r)),
        isGoal = function(x, y, z)
            local dx, dz = x - gx, z - gz
            return dx * dx + dz * dz <= r2 and abs(y - gy) <= ytol
        end,
        h = function(x, y, z)
            local d = U.dist2(x, z, gx, gz)
            return max(0, d - r) * S.costHeuristic + max(0, abs(y - gy) - ytol) * 4
        end,
    }
end

-- stand next to a block (feet or head face-adjacent), e.g. to mine it
function G.getToBlock(bx, by, bz)
    local function adj(x, y, z)
        local m = abs(x - bx) + abs(y - by) + abs(z - bz)
        return m == 1
    end
    return {
        kind = "block", x = bx, y = by, z = bz,
        desc = fmt("GoalGetToBlock{%s}", U.fmtPos(bx, by, bz)),
        isGoal = function(x, y, z) return adj(x, y, z) or adj(x, y + 1, z) end,
        h = function(x, y, z) return max(0, hXZ(bx - x, bz - z) + hY(by - y) - S.costHeuristic) end,
    }
end

-- be within `reach` of a block centre, without standing inside it
function G.reach(tx, ty, tz, reach)
    local cx, cy, cz = tx + 0.5, ty + 0.5, tz + 0.5
    local r2 = reach * reach
    return {
        kind = "block", x = tx, y = ty, z = tz,
        desc = fmt("GoalReach{%s}", U.fmtPos(tx, ty, tz)),
        isGoal = function(x, y, z)
            if x == tx and z == tz and (y == ty or y + 1 == ty) then return false end
            local dx, dy, dz = x + 0.5 - cx, y + 1.62 - cy, z + 0.5 - cz
            return dx * dx + dy * dy + dz * dz <= r2
        end,
        h = function(x, y, z)
            local d = U.dist3(x + 0.5, y + 1.62, z + 0.5, cx, cy, cz)
            return max(0, d - reach) * S.costHeuristic
        end,
    }
end

function G.composite(list)
    if #list == 1 then return list[1] end
    return {
        kind = "composite", list = list,
        desc = fmt("GoalComposite{%d goals}", #list),
        isGoal = function(x, y, z)
            for i = 1, #list do if list[i].isGoal(x, y, z) then return true end end
            return false
        end,
        h = function(x, y, z)
            local best = INF
            for i = 1, #list do
                local v = list[i].h(x, y, z)
                if v < best then best = v end
            end
            return best
        end,
    }
end

-- =====================================================================
-- A* pathfinder (incremental, time-sliced across frames)
-- =====================================================================
local PF = {}
local COST = { WALK = 4.633, SPRINT = 3.564, SNEAK = 15.385, WATER = 9.091, JUMP = 2.5, PILLAR = 11 }
PF.COST = COST

local FALLT = { [0] = 0 }
do
    local vy, d, t = 0, 0, 0
    for n = 1, 400 do
        while d < n do
            vy = (vy - 0.08) * 0.98
            d = d - vy
            t = t + 1
        end
        FALLT[n] = t
    end
end
PF.FALLT = FALLT

-- move kinds
local M_TRAVERSE, M_DIAGONAL, M_ASCEND, M_DESCEND, M_FALL, M_PILLAR, M_DOWNWARD, M_SWIM_UP, M_SWIM_DOWN =
    1, 2, 3, 4, 5, 6, 7, 8, 9
PF.M = {
    TRAVERSE = M_TRAVERSE, DIAGONAL = M_DIAGONAL, ASCEND = M_ASCEND, DESCEND = M_DESCEND,
    FALL = M_FALL, PILLAR = M_PILLAR, DOWNWARD = M_DOWNWARD, SWIM_UP = M_SWIM_UP, SWIM_DOWN = M_SWIM_DOWN,
}
PF.MNAME = { "traverse", "diagonal", "ascend", "descend", "fall", "pillar", "downward", "swim-up", "swim-down" }

local ADJ5 = { { 0, 1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
local ADJ6 = { { 0, -1, 0 }, { 0, 1, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
PF.ADJ6 = ADJ6
local DIRS4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local DIAG4 = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

-- cost of making a body cell passable: 0 = already, INF = impossible
local C_AIR_, C_PASS_, C_WATER_, C_AVOID_ = K.C_AIR, K.C_PASS, K.C_WATER, K.C_AVOID
local cellCostSlow
local function cellCost(ctx, x, y, z)
    local n = W.get(x, y, z)
    local c = K.class(n)
    if c == C_AIR_ or c == C_PASS_ then return 0 end
    if c == C_WATER_ then return ctx.allowSwim and 0 or INF end
    if c == C_AVOID_ then return INF end
    if not ctx.allowBreak then return INF end
    local k = ((x + 16777216) * 2048 + (y + 1024)) * 33554432 + (z + 16777216)
    local cc = ctx.cc
    if not cc then cc = {} ctx.cc = cc end
    local v = cc[k]
    if v == nil then
        v = cellCostSlow(ctx, x, y, z, n)
        cc[k] = v
    end
    return v
end
cellCostSlow = function(ctx, x, y, z, n)
    if K.unbreakable(n) then return INF end
    if ctx.noBreak and ctx.noBreak(U.key(x, y, z), n) then return INF end
    for i = 1, 5 do
        local d = ADJ5[i]
        local an = W.get(x + d[1], y + d[2], z + d[3])
        if K.isWater(an) or K.isLava(an) then return INF end
    end
    local t = ctx.breakTicks(n)
    local above = W.get(x, y + 1, z)
    if K.isFalling(above) then t = t + ctx.breakTicks(above) + 20 end
    return t + ctx.breakPenalty
end
PF.cellCost = cellCost

-- virtKey: a block the path has already planned to place (counts as solid)
local function hasSupport(x, y, z, virtKey)
    for i = 1, 6 do
        local d = ADJ6[i]
        local sx, sy, sz = x + d[1], y + d[2], z + d[3]
        if K.solid(W.get(sx, sy, sz)) then return true end
        if virtKey and U.key(sx, sy, sz) == virtKey then return true end
    end
    return false
end
PF.hasSupport = hasSupport

local function canPlaceAt(ctx, x, y, z, virtKey)
    if not ctx.canPlace then return false end
    if not K.passable(W.get(x, y, z)) then return false end
    if ctx.noPlace and ctx.noPlace(U.key(x, y, z)) then return false end
    return hasSupport(x, y, z, virtKey)
end

-- emit(nx, ny, nz, cost, kind, placeFlag)
function PF.expand(ctx, node, emit)
    local x, y, z = node.x, node.y, node.z
    local feetHere = W.get(x, y, z)
    local inWater = K.isWater(feetHere)
    local floorHere = W.get(x, y - 1, z)
    local walk = ctx.walkCost
    -- if we got here by placing our own floor, that block will exist
    local virt = nil
    if node.place and (node.kind == M_TRAVERSE or node.kind == M_ASCEND or node.kind == M_PILLAR) then
        virt = U.key(x, y - 1, z)
    end
    local floorSolid = K.solid(floorHere) or virt ~= nil

    for i = 1, 4 do
        local d = DIRS4[i]
        local nx, nz = x + d[1], z + d[2]
        if ctx.loaded(nx, nz, y) then
            local cF = cellCost(ctx, nx, y, nz)
            local cH = (cF < INF) and cellCost(ctx, nx, y + 1, nz) or INF
            if cF < INF and cH < INF then
                local destFeet = W.get(nx, y, nz)
                local fN = W.get(nx, y - 1, nz)
                local destWater = K.isWater(destFeet)
                -- TRAVERSE
                if destWater then
                    local extra = K.isWater(W.get(nx, y + 1, nz)) and 6 or 0
                    emit(nx, y, nz, COST.WATER + cF + cH + extra, M_TRAVERSE, false)
                elseif K.standable(fN) then
                    emit(nx, y, nz, (inWater and COST.WATER or walk) + cF + cH, M_TRAVERSE, false)
                elseif not inWater and floorSolid and canPlaceAt(ctx, nx, y - 1, nz, virt) then
                    emit(nx, y, nz, COST.SNEAK + ctx.placePenalty + cF + cH, M_TRAVERSE, true)
                end
                -- DESCEND / FALL (walk off the edge)
                if not destWater and (K.passable(fN) or K.isWater(fN)) and (not inWater or floorSolid) then
                    local scanMax = 64
                    for dd = 1, scanMax do
                        local cy = y - dd
                        local n = W.get(nx, cy, nz)
                        local c = K.class(n)
                        if c == K.C_WATER then
                            if ctx.allowSwim then
                                emit(nx, cy, nz, walk + FALLT[dd] + cF + cH, dd == 1 and M_DESCEND or M_FALL, false)
                            end
                            break
                        elseif c == K.C_AIR or c == K.C_PASS then
                            -- keep falling
                        elseif c == K.C_AVOID then
                            break
                        else
                            if K.standable(n) then
                                local h = dd - 1
                                if h >= 1 then
                                    if h <= ctx.maxFall then
                                        emit(nx, cy + 1, nz, walk + FALLT[h] + cF + cH, h == 1 and M_DESCEND or M_FALL, false)
                                    elseif h <= ctx.maxFallBucket and ctx.hasBucket then
                                        emit(nx, cy + 1, nz, walk + FALLT[h] + cF + cH + ctx.placePenalty * 2, M_FALL, false)
                                    end
                                end
                            end
                            break
                        end
                        if cy < -64 then break end
                    end
                end
            end
            -- ASCEND
            local cUp = cellCost(ctx, x, y + 2, z)
            if cUp < INF then
                local fN = W.get(nx, y, nz)
                local cDF = cellCost(ctx, nx, y + 1, nz)
                local cDH = (cDF < INF) and cellCost(ctx, nx, y + 2, nz) or INF
                if cDF < INF and cDH < INF and not K.isWater(W.get(nx, y + 1, nz)) then
                    local base = walk + COST.JUMP + cUp + cDF + cDH
                    if K.standable(fN) then
                        emit(nx, y + 1, nz, base, M_ASCEND, false)
                    elseif not inWater and floorSolid and canPlaceAt(ctx, nx, y, nz, virt) then
                        emit(nx, y + 1, nz, base + ctx.placePenalty, M_ASCEND, true)
                    end
                end
            end
        end
    end

    -- DIAGONAL
    if ctx.allowDiagonal then
        for i = 1, 4 do
            local d = DIAG4[i]
            local nx, nz = x + d[1], z + d[2]
            if ctx.loaded(nx, nz, y) then
                local df, dh = W.get(nx, y, nz), W.get(nx, y + 1, nz)
                if K.passable(df) and K.passable(dh) and K.standable(W.get(nx, y - 1, nz)) and not inWater then
                    local a1, a2 = W.get(x + d[1], y, z), W.get(x + d[1], y + 1, z)
                    local b1, b2 = W.get(x, y, z + d[2]), W.get(x, y + 1, z + d[2])
                    local aOk = K.passable(a1) and K.passable(a2)
                    local bOk = K.passable(b1) and K.passable(b2)
                    local danger = K.isAvoid(a1) or K.isAvoid(b1) or K.isAvoid(a2) or K.isAvoid(b2)
                        or K.isAvoid(W.get(x + d[1], y - 1, z)) or K.isAvoid(W.get(x, y - 1, z + d[2]))
                    if (aOk or bOk) and not danger then
                        local c = walk * SQRT2
                        if not (aOk and bOk) then c = c * 1.5 end
                        emit(nx, y, nz, c, M_DIAGONAL, false)
                    end
                end
            end
        end
    end

    -- PILLAR (jump + place under yourself)
    if ctx.canPlace and not inWater and floorSolid and K.passable(feetHere) then
        local cUp = cellCost(ctx, x, y + 2, z)
        if cUp < INF and not (ctx.noPlace and ctx.noPlace(U.key(x, y, z))) then
            emit(x, y + 1, z, COST.PILLAR + ctx.placePenalty + cUp, M_PILLAR, true)
        end
    end

    -- DOWNWARD (mine the block you stand on)
    if ctx.allowDownward and not inWater then
        local cB = cellCost(ctx, x, y - 1, z)
        if cB > 0 and cB < INF then
            local below = W.get(x, y - 2, z)
            if K.standable(below) then
                emit(x, y - 1, z, cB + FALLT[1], M_DOWNWARD, false)
            end
        end
    end

    -- swimming
    if inWater and ctx.allowSwim then
        local up = W.get(x, y + 1, z)
        if K.isWater(up) then
            emit(x, y + 1, z, COST.WATER * 1.2, M_SWIM_UP, false)
        end
        local dn = W.get(x, y - 1, z)
        if K.isWater(dn) then
            emit(x, y - 1, z, COST.WATER * 1.2, M_SWIM_DOWN, false)
        end
    end
end

-- cells a move must clear, and cells it must fill
function PF.describe(from, to)
    local kind = to.kind
    local x, y, z = from.x, from.y, from.z
    local nx, nz = to.x, to.z
    local clear, place = {}, {}
    if kind == M_TRAVERSE then
        clear = { { nx, y + 1, nz }, { nx, y, nz } }
        if to.place then place = { { nx, y - 1, nz } } end
    elseif kind == M_ASCEND then
        clear = { { x, y + 2, z }, { nx, y + 2, nz }, { nx, y + 1, nz } }
        if to.place then place = { { nx, y, nz } } end
    elseif kind == M_DESCEND or kind == M_FALL then
        clear = { { nx, y + 1, nz }, { nx, y, nz } }
    elseif kind == M_PILLAR then
        clear = { { x, y + 2, z } }
        place = { { x, y, z } }
    elseif kind == M_DOWNWARD then
        clear = { { x, y - 1, z } }
    end
    return clear, place
end

-- ------------------------------------------------------------------
-- Search object
-- ------------------------------------------------------------------
function PF.new(sx, sy, sz, goal, ctx)
    local s = {
        goal = goal, ctx = ctx, open = Heap.new(), nodes = {}, cpu = 0, expanded = 0,
        status = "running", bestH = INF, best = nil, sx = sx, sy = sy, sz = sz,
    }
    local h = goal.h(sx, sy, sz)
    local start = { x = sx, y = sy, z = sz, g = 0, h = h, f = h, hi = 0 }
    s.start = start
    s.nodes[U.key(sx, sy, sz)] = start
    s.open:push(start)
    return s
end

local function buildPath(s, node)
    local list = {}
    while node do
        list[#list + 1] = node
        node = node.parent
    end
    local path = {}
    for i = #list, 1, -1 do
        local n = list[i]
        path[#path + 1] = { x = n.x, y = n.y, z = n.z, kind = n.kind, place = n.place, g = n.g }
    end
    return path
end

function PF.step(s, budgetMs)
    if s.status ~= "running" then return s.status end
    local t0 = U.now()
    local goal, ctx, open, nodes = s.goal, s.ctx, s.open, s.nodes
    local cur
    local maxNodes = ctx.maxNodes or S.maxPathNodes
    local function emit(nx, ny, nz, cost, kind, place)
        if cost >= INF then return end
        local k = U.key(nx, ny, nz)
        if ctx.avoid and ctx.avoid[k] then return end
        local g = cur.g + cost
        local nd = nodes[k]
        if nd == nil then
            local h = goal.h(nx, ny, nz)
            nd = { x = nx, y = ny, z = nz, g = g, h = h, f = g + h, parent = cur, kind = kind, place = place, hi = 0 }
            nodes[k] = nd
            open:push(nd)
        elseif not nd.closed and g < nd.g - 1e-6 then
            nd.g = g
            nd.f = g + nd.h
            nd.parent = cur
            nd.kind = kind
            nd.place = place
            if nd.hi and nd.hi > 0 then open:up(nd.hi) else open:push(nd) end
        end
    end
    local iter = 0
    while true do
        cur = open:pop()
        if cur == nil then
            s.status = "exhausted"
            break
        end
        if goal.isGoal(cur.x, cur.y, cur.z) then
            s.path = buildPath(s, cur)
            s.status = "found"
            break
        end
        cur.closed = true
        s.expanded = s.expanded + 1
        if cur ~= s.start and cur.h < s.bestH then
            s.bestH = cur.h
            s.best = cur
        end
        PF.expand(ctx, cur, emit)
        iter = iter + 1
        if s.expanded >= maxNodes then
            s.status = "limit"
            break
        end
        -- time budget, plus an iteration cap in case the clock is coarse
        if iter >= 300 or (iter % 24 == 0 and U.now() - t0 >= budgetMs) then break end
    end
    s.cpu = s.cpu + (U.now() - t0)
    if s.status == "running" then
        if s.cpu >= S.failureTimeoutMS then
            s.status = "limit"
        elseif s.cpu >= S.primaryTimeoutMS and s.best and s.start.h - s.bestH > S.costHeuristic * 4 then
            s.status = "limit"
        end
    end
    if s.status == "exhausted" or s.status == "limit" then
        if s.best and s.start.h - s.bestH > 0.5 then
            s.path = buildPath(s, s.best)
            s.status = "partial"
        else
            s.status = "failed"
        end
    end
    return s.status
end
