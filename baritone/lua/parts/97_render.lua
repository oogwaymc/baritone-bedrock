
-- =====================================================================
-- Rendering: path, goal, targets and schematic ghost blocks.
-- Runs in RenderEvent (no player API calls there, only cached data and
-- world.worldToScreen).
-- =====================================================================
local REN = { frame = 0 }

local function w2s(x, y, z)
    local ok, vis, sx, sy = pcall(world.worldToScreen, x, y, z)
    if ok and vis and sx then return sx, sy end
    return nil
end

local function line(dl, a, b, color, th)
    local ax, ay = w2s(a[1], a[2], a[3])
    if not ax then return end
    local bx, by = w2s(b[1], b[2], b[3])
    if not bx then return end
    dl:AddLine({ ax, ay }, { bx, by }, color, th)
end

local BOX_EDGES = {
    { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 1 }, { 5, 6 }, { 6, 7 }, { 7, 8 }, { 8, 5 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
}

local function box(dl, x1, y1, z1, x2, y2, z2, color, th)
    local c = {
        { x1, y1, z1 }, { x2, y1, z1 }, { x2, y1, z2 }, { x1, y1, z2 },
        { x1, y2, z1 }, { x2, y2, z1 }, { x2, y2, z2 }, { x1, y2, z2 },
    }
    local s = {}
    for i = 1, 8 do
        local sx, sy = w2s(c[i][1], c[i][2], c[i][3])
        if sx then s[i] = { sx, sy } end
    end
    for _, e in ipairs(BOX_EDGES) do
        local a, b = s[e[1]], s[e[2]]
        if a and b then dl:AddLine(a, b, color, th) end
    end
end

function REN.draw()
    local okDl, dl = pcall(ImGui.GetBackgroundDrawList)
    if not okDl or not dl then return end
    REN.frame = REN.frame + 1

    -- path
    if S.renderPath and NAV.path and (NAV.state == "exec" or NAV.state == "plan") then
        local col = Settings.color("colorCurrentPath", 230)
        local done = Settings.color("colorCurrentPath", 70)
        local th = S.pathThickness
        local path = NAV.path
        local from = max(1, NAV.idx - 1)
        local to = min(#path, NAV.idx + 120)
        for i = from, to - 1 do
            local a, b = path[i], path[i + 1]
            line(dl, { a.x + 0.5, a.y + 0.08, a.z + 0.5 }, { b.x + 0.5, b.y + 0.08, b.z + 0.5 }, (i < NAV.idx) and done or col, th)
        end
    end

    -- goal
    local goal = NAV.goal
    if S.renderGoal and goal and NAV.state ~= "idle" then
        local col = Settings.color("colorGoalBox", 230)
        local list = goal.list or { goal }
        for i = 1, min(#list, 16) do
            local g = list[i]
            if g.kind == "block" or g.kind == "near" then
                box(dl, g.x, g.y, g.z, g.x + 1, g.y + (g.kind == "near" and 1 or 2), g.z + 1, col, 2)
            elseif g.kind == "xz" then
                line(dl, { g.x + 0.5, REN.py - 30, g.z + 0.5 }, { g.x + 0.5, REN.py + 60, g.z + 0.5 }, col, 3)
            elseif g.kind == "y" then
                local r = 2
                box(dl, REN.px - r, g.y, REN.pz - r, REN.px + r, g.y + 0.02, REN.pz + r, col, 2)
            end
        end
    end

    -- mining / farming targets
    if S.renderSelectionBoxes and Bot.proc and Bot.proc.known then
        local col = Settings.color("colorMineTarget", 200)
        local n = 0
        for _, v in pairs(Bot.proc.known) do
            if abs(v[1] - REN.px) < 32 and abs(v[3] - REN.pz) < 32 then
                box(dl, v[1], v[2], v[3], v[1] + 1, v[2] + 1, v[3] + 1, col, 1.5)
                n = n + 1
                if n > 64 then break end
            end
        end
    end

    -- litematica ghost blocks
    if S.litematicaRender and LM.schem then
        local cMissing = { 90, 170, 255, 170 }
        local cWrong = { 255, 60, 60, 200 }
        for _, gb in ipairs(LM.ghosts) do
            local col = (gb[4] == "missing") and cMissing or cWrong
            local inset = 0.03
            box(dl, gb[1] + inset, gb[2] + inset, gb[3] + inset, gb[1] + 1 - inset, gb[2] + 1 - inset, gb[3] + 1 - inset, col, 1.2)
        end
        -- placement outline
        local sx, sy, sz = LM.size()
        box(dl, LM.ox, LM.oy, LM.oz, LM.ox + sx, LM.oy + sy, LM.oz + sz, { 255, 255, 255, 90 }, 1)
    end

    -- status line
    if S.renderHud and (Bot.isActive() or Bot.paused) then
        local okF, fg = pcall(ImGui.GetForegroundDrawList)
        if okF and fg then
            local text = "Baritone: " .. (REN.status or "")
            if not Helper.connected then text = text .. "  [helper not running]" end
            fg:AddText({ 12, 12 }, { 0, 0, 0, 170 }, 18, text)
            fg:AddText({ 11, 11 }, { 230, 120, 255, 255 }, 18, text)
        end
    end
end

-- ---------------------------------------------------------------------
-- DLL: world-space line list drawn by the game's renderer
-- ---------------------------------------------------------------------
REN.next3d = 0
REN.lastStatus = nil

local function pushLine(t, x1, y1, z1, x2, y2, z2, c)
    local n = #t
    t[n + 1], t[n + 2], t[n + 3], t[n + 4], t[n + 5], t[n + 6] = x1, y1, z1, x2, y2, z2
    t[n + 7], t[n + 8], t[n + 9], t[n + 10] = c[1], c[2], c[3], c[4]
end

local function pushBox(t, x1, y1, z1, x2, y2, z2, c)
    pushLine(t, x1, y1, z1, x2, y1, z1, c) pushLine(t, x2, y1, z1, x2, y1, z2, c)
    pushLine(t, x2, y1, z2, x1, y1, z2, c) pushLine(t, x1, y1, z2, x1, y1, z1, c)
    pushLine(t, x1, y2, z1, x2, y2, z1, c) pushLine(t, x2, y2, z1, x2, y2, z2, c)
    pushLine(t, x2, y2, z2, x1, y2, z2, c) pushLine(t, x1, y2, z2, x1, y2, z1, c)
    pushLine(t, x1, y1, z1, x1, y2, z1, c) pushLine(t, x2, y1, z1, x2, y2, z1, c)
    pushLine(t, x2, y1, z2, x2, y2, z2, c) pushLine(t, x1, y1, z2, x1, y2, z2, c)
end

-- box with outline colour c (r,g,b,a) and fill alpha (0 = outline only)
local function pushFilled(bx, x1, y1, z1, x2, y2, z2, c, fill)
    local n = #bx
    bx[n + 1], bx[n + 2], bx[n + 3], bx[n + 4], bx[n + 5], bx[n + 6] = x1, y1, z1, x2, y2, z2
    bx[n + 7], bx[n + 8], bx[n + 9], bx[n + 10], bx[n + 11] = c[1], c[2], c[3], c[4] or 255, fill or 0
end

-- DLL renderer: lines (path) + boxes (goal, targets, ghost blocks)
function REN.build3d()
    local t, bx = {}, {}
    if S.renderPath and NAV.path and (NAV.state == "exec" or NAV.state == "plan") then
        local col = Settings.color("colorCurrentPath", 255)
        local done = Settings.color("colorCurrentPath", 90)
        local path = NAV.path
        local from = max(1, NAV.idx - 1)
        local to = min(#path, NAV.idx + 150)
        for i = from, to - 1 do
            local a, b = path[i], path[i + 1]
            pushLine(t, a.x + 0.5, a.y + 0.08, a.z + 0.5, b.x + 0.5, b.y + 0.08, b.z + 0.5, (i < NAV.idx) and done or col)
        end
    end
    local goal = NAV.goal
    if S.renderGoal and goal and NAV.state ~= "idle" then
        local col = Settings.color("colorGoalBox", 255)
        local list = goal.list or { goal }
        for i = 1, min(#list, 16) do
            local g = list[i]
            if g.kind == "block" or g.kind == "near" then
                pushFilled(bx, g.x, g.y, g.z, g.x + 1, g.y + (g.kind == "near" and 1 or 2), g.z + 1, col, 0)
            elseif g.kind == "xz" then
                pushLine(t, g.x + 0.5, P.y - 30, g.z + 0.5, g.x + 0.5, P.y + 60, g.z + 0.5, col)
            elseif g.kind == "y" then
                pushFilled(bx, P.x - 2, g.y, P.z - 2, P.x + 2, g.y + 0.02, P.z + 2, col, 0)
            end
        end
    end
    if S.renderSelectionBoxes and Bot.proc and Bot.proc.known then
        local col = Settings.color("colorMineTarget", 230)
        local n = 0
        for _, v in pairs(Bot.proc.known) do
            if abs(v[1] - P.x) < 32 and abs(v[3] - P.z) < 32 then
                pushFilled(bx, v[1], v[2], v[3], v[1] + 1, v[2] + 1, v[3] + 1, col, 0)
                n = n + 1
                if n > 64 then break end
            end
        end
    end
    if S.litematicaRender and LM.schem then
        -- ghost blocks: tinted with the colour of the block that goes there;
        -- red outline = the wrong block is there
        local inset = 0.03
        local fill = S.litematicaFill and 95 or 0
        local wrongOutline = { 255, 40, 40, 255 }
        local cur = Bot.proc and Bot.proc.name == "build" and Bot.proc.cur and Bot.proc.cur.t
        for _, gb in ipairs(LM.ghosts) do
            local c = K.blockColor(gb[6] or "stone")
            local outline = (gb[4] == "wrong") and wrongOutline or { c[1], c[2], c[3], 235 }
            pushFilled(bx, gb[1] + inset, gb[2] + inset, gb[3] + inset, gb[1] + 1 - inset, gb[2] + 1 - inset, gb[3] + 1 - inset,
                outline, fill)
        end
        -- what the HUD is describing, and what the builder is working on
        local look = LM.look and LM.look.t
        if look then
            pushFilled(bx, look[1] - 0.01, look[2] - 0.01, look[3] - 0.01, look[1] + 1.01, look[2] + 1.01, look[3] + 1.01,
                { 255, 255, 255, 255 }, 0)
        end
        if cur then
            pushFilled(bx, cur[1] - 0.02, cur[2] - 0.02, cur[3] - 0.02, cur[1] + 1.02, cur[2] + 1.02, cur[3] + 1.02,
                { 255, 230, 60, 255 }, 0)
        end
        local sx, sy, sz = LM.size()
        pushFilled(bx, LM.ox, LM.oy, LM.oz, LM.ox + sx, LM.oy + sy, LM.oz + sz, { 255, 255, 255, 120 }, 0)
    end
    return t, bx
end

function REN.update3d(now)
    local lookText = LM.lookText(now)
    if now >= REN.next3d then
        REN.next3d = now + 100
        local lines, boxes = REN.build3d()
        pcall(native.setLines, lines)
        pcall(native.setBoxes, boxes)
    end
    local active = Bot.isActive() or Bot.paused
    local visible = S.renderHud and (active or lookText ~= nil)
    local text = active and (REN.status or "") or ""
    if lookText then
        text = (text ~= "" and (text .. "  |  ") or "") .. "Schematic: " .. lookText
    end
    if text ~= REN.lastStatus or visible ~= REN.lastVisible then
        REN.lastStatus, REN.lastVisible = text, visible
        pcall(native.setStatus, text, visible)
    end
end
