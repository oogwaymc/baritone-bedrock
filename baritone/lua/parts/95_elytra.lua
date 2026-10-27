
-- =====================================================================
-- #elytra [x z]  - fly to a destination with an elytra and fireworks
-- =====================================================================
function Proc.elytra(gx, gz)
    local e = { name = "elytra", gx = gx, gz = gz, phase = "check", lastFirework = 0, t = 0, deployTries = 0 }
    function e:status()
        local d = floor(U.dist2(P.x, P.z, self.gx, self.gz))
        local fw = HB.slotOf("firework_rocket") and "" or ", no fireworks"
        return fmt("Elytra to %s (%d blocks, %s%s)", U.fmtPos(self.gx, self.gz), d, self.phase, fw)
    end

    -- highest solid block near (x,z) between y-48 and y+24 (only loaded chunks)
    function e:terrainTop(x, z, y)
        x, z = floor(x), floor(z)
        if not W.loaded(x, z, floor(y)) then return nil end
        for yy = floor(y) + 24, floor(y) - 48, -2 do
            local n = W.get(x, yy, z)
            if not K.passable(n) then
                if not K.passable(W.get(x, yy + 1, z)) then return yy + 1 end
                return yy
            end
        end
        return nil
    end

    function e:useFirework(now)
        local slot = HB.slotOf("firework_rocket")
        if not slot then return false end
        if now - self.lastFirework < S.elytraFireworkDelayMS then return false end
        IN.select(slot)
        if P.slot == slot then
            IN.click()
            self.lastFirework = now
            return true
        end
        return false
    end

    function e:tick(now)
        IN.clear()
        local yawToGoal = U.yawTo(P.x, P.z, self.gx, self.gz)
        local dist = U.dist2(P.x, P.z, self.gx, self.gz)
        if self.phase == "check" then
            if P.chest ~= "elytra" then
                Bot.finish("\194\167cWear an elytra first")
                return true
            end
            if not HB.slotOf("firework_rocket") then
                U.chat("\194\167eNo fireworks in hotbar - gliding only")
            end
            self.startY = P.y
            self.phase = P.grounded and "takeoff" or "deploy"
            self.t = now
            return true
        end
        if self.phase == "takeoff" then
            IN.look(yawToGoal, -15)
            if P.grounded then
                if now - self.t > 250 then IN.press("jump") end
            elseif P.vy < -0.05 then
                self.phase = "deploy"
                self.t = now
            end
            return true
        end
        if self.phase == "deploy" then
            IN.look(yawToGoal, -15)
            if P.grounded then
                self.deployTries = self.deployTries + 1
                if self.deployTries > 3 then Bot.finish("\194\167cCouldn't take off - need more height or space") return true end
                self.phase = "takeoff"
                self.t = now
                return true
            end
            if now - self.t < 120 then
                IN.press("jump")
            elseif now - self.t > 450 then
                -- assume we're gliding once falling slowly / moving fast
                self.phase = "boost"
                self.t = now
            end
            return true
        end
        if self.phase == "boost" then
            IN.look(yawToGoal, -40)
            if P.pitch < -30 then self:useFirework(now) end
            if now - self.t > 1200 or not HB.slotOf("firework_rocket") then
                self.phase = "cruise"
            end
            return true
        end
        if self.phase == "cruise" or self.phase == "land" then
            if P.grounded and now - self.t > 1500 then
                if dist < 12 then
                    Bot.finish("Landed at destination")
                else
                    -- landed early: take off again
                    self.phase = "takeoff"
                    self.t = now
                end
                return true
            end
            local hx, hz = U.dirFromYaw(yawToGoal)
            local ground = self:terrainTop(P.x, P.z, P.y) or (P.y - 30)
            local ahead = ground
            for _, d in ipairs({ 8, 16, 32, 48 }) do
                local tt = self:terrainTop(P.x + hx * d, P.z + hz * d, P.y)
                if tt and tt > ahead then ahead = tt end
            end
            local cruiseY = max((self.startY or P.y) + S.elytraCruiseHeight, ahead + 16)
            if W.dim == "nether" then cruiseY = min(cruiseY, 118) end
            if dist < S.elytraLandDistance and S.elytraAutoLand then self.phase = "land" end

            local pitch
            if self.phase == "land" then
                local gy = self:terrainTop(self.gx, self.gz, P.y) or ground
                local above = P.y - (ground + 1)
                if dist > 6 then
                    pitch = U.clamp(U.pitchTo(P.x, P.y, P.z, self.gx + 0.5, gy + 1, self.gz + 0.5), 5, 35)
                else
                    pitch = 25
                end
                if above < 4 then pitch = 0 end
            else
                local err = cruiseY - P.y
                if err > 3 then pitch = -25
                elseif err < -6 then pitch = 18
                else pitch = 3 end
                -- obstacle directly ahead?
                for _, d in ipairs({ 3, 6, 10 }) do
                    local n = W.get(floor(P.x + hx * d), floor(P.y + 0.5), floor(P.z + hz * d))
                    if not K.passable(n) then pitch = -45 break end
                end
                local speed = P.horizSpeed()
                if (speed < S.elytraMinSpeed or err > 6 or pitch <= -40) and P.pitch < -15 then
                    self:useFirework(now)
                end
            end
            IN.look(yawToGoal, pitch)
            return true
        end
        return true
    end
    function e:stop() IN.clear() end
    return e
end
