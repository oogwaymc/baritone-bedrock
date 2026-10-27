
-- =====================================================================
-- #farm [range] [now]
-- Harvests and replants crops around where you start it.
-- Flarial only exposes block *names*, not growth stage, so wheat/carrots/
-- potatoes/beetroot/nether wart are treated as grown once
-- `farmGrowMinutes` have passed since the bot first saw or planted them
-- (#farm now harvests everything immediately). Pumpkins, melons, sugar
-- cane and bamboo are always detectable.
-- =====================================================================
local CROPS = {
    wheat = "wheat_seeds", carrots = "carrot", potatoes = "potato", beetroot = "beetroot_seeds",
    nether_wart = "nether_wart",
}
local SEED_TO_CROP = { wheat_seeds = "wheat", carrot = "carrots", potato = "potatoes", beetroot_seeds = "beetroot", nether_wart = "nether_wart" }
local ALWAYS = { pumpkin = true, melon_block = true, melon = true }
local STACKED = { reeds = true, sugar_cane = true, bamboo = true }

local Farm = { times = {}, lastCrop = {}, loadedFor = nil }

function Farm.file()
    local okn, wn = pcall(world.getWorldName)
    wn = (okn and wn and wn ~= "") and tostring(wn) or "world"
    wn = wn:gsub("[^%w_%-]", "_")
    return DIR .. "/farm_" .. wn .. "_" .. W.dim .. ".txt"
end

function Farm.load()
    local f = Farm.file()
    if Farm.loadedFor == f then return end
    Farm.loadedFor = f
    Farm.times, Farm.lastCrop = {}, {}
    local data = U.readFile(f)
    if not data then return end
    local now = U.now()
    for line in data:gmatch("[^\r\n]+") do
        local x, y, z, age, crop = line:match("^(%-?%d+),(%-?%d+),(%-?%d+)=(%d+),?(%w*)")
        if x then
            local k = U.key(tonumber(x), tonumber(y), tonumber(z))
            Farm.times[k] = now - tonumber(age)
            if crop and crop ~= "" then Farm.lastCrop[k] = crop end
        end
    end
end

function Farm.save()
    if not Farm.loadedFor then return end
    local now = U.now()
    local lines = {}
    for k, t in pairs(Farm.times) do
        local x, y, z = U.unkey(k)
        lines[#lines + 1] = fmt("%d,%d,%d=%d,%s", x, y, z, max(0, floor(now - t)), Farm.lastCrop[k] or "")
    end
    U.writeFile(Farm.loadedFor, tconcat(lines, "\n") .. "\n")
end

function Proc.farm(range, harvestNow)
    local f = { name = "farm", range = range or S.farmRange, phase = "scan", tasks = {}, harvested = 0, planted = 0,
        drops = {}, skip = {}, saveT = 0 }
    local function match(n)
        return CROPS[n] ~= nil or ALWAYS[n] or STACKED[n] or n == "farmland" or n == "soul_sand"
    end
    function f:start()
        local fx, fy, fz = NAV.feet()
        self.cx, self.cy, self.cz = fx, fy, fz
        Farm.load()
        if harvestNow then self.harvestNow = true end
        self:rescan()
    end
    function f:rescan()
        self.scan = Scanner.new(match, self.cx, self.cy, self.cz, self.range, 4)
        self.phase = "scan"
    end
    function f:status()
        local s = fmt("Farming r=%d (%d harvested, %d planted)", self.range, self.harvested, self.planted)
        if self.waitUntil then s = s .. fmt(" - next crop in %ds", max(0, floor((self.waitUntil - U.now()) / 1000))) end
        return s
    end
    function f:grown(k, n, now)
        if ALWAYS[n] then return true end
        if not CROPS[n] then return false end
        local t = Farm.times[k]
        if not t then
            if self.harvestNow then return true end
            Farm.times[k] = now
            Farm.lastCrop[k] = n
            return false
        end
        return now - t >= S.farmGrowMinutes * 60000
    end
    function f:seedFor(k)
        local crop = Farm.lastCrop[k]
        if crop and CROPS[crop] and HB.has(CROPS[crop]) then return CROPS[crop], crop end
        for seed, c in pairs(SEED_TO_CROP) do
            if HB.has(seed) and c ~= "nether_wart" then return seed, c end
        end
        return nil
    end
    function f:buildTasks(now)
        local tasks = {}
        local soonest
        for k, v in pairs(self.scan.found) do
            local x, y, z, n = v[1], v[2], v[3], W.fresh(v[1], v[2], v[3])
            if self.skip[k] and self.skip[k] > now then
                -- skip
            elseif CROPS[n] or ALWAYS[n] then
                if self:grown(k, n, now) then
                    tasks[#tasks + 1] = { x, y, z, "harvest", n, k }
                elseif Farm.times[k] then
                    local due = Farm.times[k] + S.farmGrowMinutes * 60000
                    if not soonest or due < soonest then soonest = due end
                end
            elseif STACKED[n] then
                -- harvest the 2nd block of a stack, keep the bottom one
                local below = W.fresh(x, y - 1, z)
                local below2 = W.fresh(x, y - 2, z)
                if below == n and below2 ~= n then tasks[#tasks + 1] = { x, y, z, "harvest", n, k } end
            elseif n == "farmland" or n == "soul_sand" then
                local above = W.fresh(x, y + 1, z)
                if K.isAir(above) then
                    local ak = U.key(x, y + 1, z)
                    if n == "soul_sand" then
                        if Farm.lastCrop[ak] == "nether_wart" and HB.has("nether_wart") then
                            tasks[#tasks + 1] = { x, y + 1, z, "plant", "nether_wart", ak }
                        end
                    elseif self:seedFor(ak) then
                        tasks[#tasks + 1] = { x, y + 1, z, "plant", nil, ak }
                    end
                end
            end
        end
        self.tasks = tasks
        self.waitUntil = (#tasks == 0) and soonest or nil
    end
    function f:tick(now)
        if now - self.saveT > 30000 then Farm.save() self.saveT = now end
        if self.phase == "scan" then
            IN.clear()
            if self.scan:step(S.mineScanBlocksPerFrame * 2) then
                self:buildTasks(now)
                self.harvestNow = false
                self.phase = "choose"
            end
            return true
        end
        if self.phase == "act" then
            local c = self.cur
            local r
            if c[4] == "harvest" then
                self.st.breakPlants = true
                r = ACT.mine(self.st, c[1], c[2], c[3])
            else
                local seed, crop = self:seedFor(c[6])
                if c[5] == "nether_wart" then seed, crop = "nether_wart", "nether_wart" end
                if not seed then r = "noitem" else
                    r = ACT.place(self.st, c[1], c[2], c[3], seed)
                    self.plantCrop = crop
                end
            end
            if r == "running" then return true end
            IN.clear()
            local k = c[6]
            if r == "done" then
                if c[4] == "harvest" then
                    self.harvested = self.harvested + 1
                    if CROPS[c[5]] then
                        Farm.lastCrop[k] = c[5]
                        Farm.times[k] = nil
                        -- replant straight away
                        if self:seedFor(k) then
                            self.cur = { c[1], c[2], c[3], "plant", c[5] == "nether_wart" and "nether_wart" or nil, k }
                            self.st = {}
                            return true
                        end
                    end
                    self.drops[#self.drops + 1] = { c[1], c[2], c[3] }
                else
                    self.planted = self.planted + 1
                    Farm.times[k] = now
                    if self.plantCrop then Farm.lastCrop[k] = self.plantCrop end
                    self.drops[#self.drops + 1] = { c[1], c[2], c[3] }
                end
            else
                self.skip[k] = now + 60000
            end
            self.phase = "choose"
            return true
        end
        if self.phase == "travel" or self.phase == "collect" then
            if NAV.state == "arrived" or NAV.state == "failed" or NAV.state == "idle" then
                if NAV.state == "failed" and self.phase == "travel" and self.cur then self.skip[self.cur[6]] = now + 60000 end
                NAV.stop()
                self.phase = "choose"
            else
                return false
            end
        end
        if self.phase == "choose" then
            -- drop task list entries that are done
            local fx, fy, fz = NAV.feet()
            local ex, ey, ez = P.eye()
            local best, bestD
            for _, t in ipairs(self.tasks) do
                if not (self.skip[t[6]] and self.skip[t[6]] > now) then
                    local n = W.fresh(t[1], t[2], t[3])
                    local valid = (t[4] == "harvest" and n == t[5]) or (t[4] == "plant" and K.isAir(n))
                    if valid then
                        local d = U.dist3(ex, ey, ez, t[1] + 0.5, t[2] + 0.5, t[3] + 0.5)
                        if not best or d < bestD then best, bestD = t, d end
                    end
                end
            end
            if best then
                self.cur = best
                self.st = {}
                local reach = S.buildReach
                if bestD <= reach - 0.3 and (best[4] == "harvest" or ACT.findPlaceFace(best[1], best[2], best[3], reach)) then
                    self.phase = "act"
                    return true
                end
                NAV.set(G.reach(best[1], best[2], best[3], reach - 1))
                self.phase = "travel"
                return false
            end
            -- pick up drops
            if #self.drops > 0 then
                local d = tremove(self.drops)
                if not (fx == d[1] and fz == d[3]) then
                    NAV.set(G.near(d[1], d[2], d[3], 0.6))
                    self.phase = "collect"
                    return false
                end
                return true
            end
            -- nothing to do: wait, then rescan
            IN.clear()
            if not self.idleT then self.idleT = now end
            if now - self.idleT > 8000 then
                self.idleT = nil
                self:rescan()
            end
            return true
        end
        return false
    end
    function f:stop() Farm.save() NAV.stop() end
    return f
end
