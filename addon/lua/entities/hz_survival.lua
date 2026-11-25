AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Survival Director"
ENT.Category = "Horde Zombies"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.Editable = true
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.HZ_VirtualOK = true

function ENT:SetupDataTables()
    self:NetworkVar("Bool", 0, "Active", { KeyName = "active", Edit = { type = "Boolean", order = 1 } })
    self:NetworkVar("Bool", 1, "Hell", { KeyName = "hell", Edit = { type = "Boolean", order = 2 } })
    self:NetworkVar("Int", 0, "StartSize",
        { KeyName = "startsize", Edit = { type = "Int", min = 1, max = 200, order = 3 } })

    self:NetworkVar("Int", 1, "Growth",
        { KeyName = "growth", Edit = { type = "Int", min = 0, max = 200, order = 4 } })

    self:NetworkVar("Int", 2, "BreakTime",
        { KeyName = "breaktime", Edit = { type = "Int", min = 0, max = 300, order = 5 } })

    self:NetworkVar("Int", 3, "MaxAlive",
        { KeyName = "maxalive", Edit = { type = "Int", min = 1, max = 500, order = 6 } })

    self:NetworkVar("String", 0, "Variant",
        { KeyName = "variant", Edit = { type = "Combo", values = HZ.VARIANTS, order = 7 } })

    self:NetworkVar("Int", 4, "SpawnMin",
        { KeyName = "spawnmin", Edit = { type = "Int", min = 200, max = 4000, order = 8 } })

    self:NetworkVar("Int", 5, "SpawnMax",
        { KeyName = "spawnmax", Edit = { type = "Int", min = 600, max = 8000, order = 9 } })

    self:NetworkVar("Bool", 2, "ShowHUD", { KeyName = "showhud", Edit = { type = "Boolean", order = 10 } })

    self:NetworkVar("Int", 6, "Wave")
    self:NetworkVar("Int", 7, "Heat")
    self:NetworkVar("Float", 0, "RunStart")
    self:NetworkVar("Float", 1, "BreakEnd")

    if SERVER then
        self:SetActive(true)
        self:SetHell(false)
        self:SetStartSize(15)
        self:SetGrowth(25)
        self:SetBreakTime(20)
        self:SetMaxAlive(60)
        self:SetVariant("runners")
        self:SetSpawnMin(800)
        self:SetSpawnMax(2500)
        self:SetShowHUD(true)
    end
end

if CLIENT then
    function ENT:Draw()
        if not HZ.MarkersVisible() then return end

        self:DrawModel()
    end

    function ENT:DrawTranslucent()
        if not HZ.MarkersVisible() then return end

        local pos = self:GetPos() + Vector(0, 0, 34)
        local ang = Angle(0, LocalPlayer():EyeAngles().y - 90, 90)
        local text = not self:GetActive() and "off" or (self:GetHell() and "hell" or "waves")
        cam.Start3D2D(pos, ang, 0.12)
        draw.SimpleTextOutlined("SURVIVAL DIRECTOR", "DermaLarge", 0, 0, Color(255, 40, 40), TEXT_ALIGN_CENTER,
            TEXT_ALIGN_BOTTOM, 2, color_black)

        draw.SimpleTextOutlined(text, "DermaLarge", 0, 4, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 2,
            color_black)

        cam.End3D2D()
    end

    surface.CreateFont("hz_surv_big", { font = "Roboto", size = 34, weight = 800 })
    surface.CreateFont("hz_surv_small", { font = "Roboto", size = 20, weight = 600 })

    local function Clock(t)
        t = math.max(0, math.floor(t))
        local h, m, s = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
        if h > 0 then return ("%d:%02d:%02d"):format(h, m, s) end

        return ("%d:%02d"):format(m, s)
    end

    local current, nextFind = nil, 0
    hook.Add("HUDPaint", "hordez_survival", function()
        local now = CurTime()
        if now >= nextFind then
            nextFind = now + 1
            current = nil
            for _, ent in ipairs(ents.FindByClass("hz_survival")) do
                if ent:GetActive() and ent:GetRunStart() > 0 then
                    current = ent
                    break
                end
            end
        end

        local dir = current
        if not IsValid(dir) or not dir:GetShowHUD() or dir:GetRunStart() <= 0 then return end

        local x, y = ScrW() - 24, 20
        local red, white = Color(230, 40, 40), Color(235, 235, 235)
        if dir:GetHell() then
            draw.SimpleTextOutlined("HELL " .. math.max(dir:GetHeat(), 1), "hz_surv_big", x, y, red, TEXT_ALIGN_RIGHT,
                TEXT_ALIGN_TOP, 2, color_black)
        else
            draw.SimpleTextOutlined("WAVE " .. math.max(dir:GetWave(), 1), "hz_surv_big", x, y, red, TEXT_ALIGN_RIGHT,
                TEXT_ALIGN_TOP, 2, color_black)
        end

        draw.SimpleTextOutlined(Clock(now - dir:GetRunStart()), "hz_surv_small", x, y + 38, white, TEXT_ALIGN_RIGHT,
            TEXT_ALIGN_TOP, 2, color_black)

        if not dir:GetHell() and dir:GetBreakEnd() > now then
            draw.SimpleTextOutlined("break " .. Clock(dir:GetBreakEnd() - now + 0.99), "hz_surv_small", x, y + 62,
                Color(170, 170, 170), TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP, 2, color_black)
        end
    end)

    return
end

local RESET_DELAY = 6
local WAVE_SPEEDUP = 0.03
local HELL_RATE0, HELL_RAMP, HELL_RATE_MAX = 0.6, 0.35, 5
local HEAT_STEP = 90
local HEAT_FULL_CROWD = 8
local HEAT_START_CROWD = 0.25
local HEAT_CROWD_GROWTH, HEAT_CROWD_MAX = 0.1, 2.5
local HEAT_HEALTH, HEAT_HEALTH_MAX = 0.02, 0.5
local SURGE_EVERY, SURGE_EVERY_MIN = 75, 40

function ENT:Initialize()
    self:SetModel("models/props_c17/consolebox01a.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    self:SetColor(Color(255, 90, 90))
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    self.owned = {}
    self.sources = {}
    self.waveLeft = 0
    self.hellBank = 0
end

function ENT:OnRemove()
    self:ClearZombies()
end

function ENT:ClearZombies()
    for zombie in pairs(self.owned or {}) do
        if IsValid(zombie) then zombie:Remove() end
    end

    self.owned = {}
    if HZ.DropVirtualOwned then HZ.DropVirtualOwned(self) end
end

function ENT:HZ_OnZombieDied(zombie)
    self.owned[zombie] = nil
end

function ENT:HZ_OnZombieReal(zombie)
    self.owned[zombie] = true
end

function ENT:HeatMinutes()
    if not self.hellMode or self:GetRunStart() <= 0 then return 0 end

    return math.max(CurTime() - self:GetRunStart(), 0) / 60
end

function ENT:AliveCap()
    local cap = self:GetMaxAlive()
    if not self.hellMode then return cap end

    local minutes = self:HeatMinutes()
    local grown = HEAT_START_CROWD + (1 - HEAT_START_CROWD) * math.min(minutes / HEAT_FULL_CROWD, 1)
    grown = math.min(grown + math.max(minutes - HEAT_FULL_CROWD, 0) * HEAT_CROWD_GROWTH, HEAT_CROWD_MAX)

    return math.max(math.floor(cap * grown), math.min(cap, 6))
end

function ENT:AliveCount()
    local count = 0
    for zombie in pairs(self.owned) do
        if IsValid(zombie) and not zombie.hz_dead then
            count = count + 1
        else
            self.owned[zombie] = nil
        end
    end

    return count + HZ.VirtualOwned(self)
end

local function AnyPlayerAlive()
    for _, ply in ipairs(player.GetAll()) do
        if ply:Alive() then return true end
    end

    return false
end

function ENT:ResetRun()
    self:ClearZombies()
    self:SetWave(0)
    self:SetRunStart(0)
    self:SetBreakEnd(0)
    self:SetHeat(0)
    self.waveLeft, self.hellBank, self.deadSince, self.hellMode, self.nextSurge = 0, 0, nil, nil, nil
end

function ENT:StartRun(now)
    self:ResetRun()
    self.hellMode = self:GetHell()
    self:SetRunStart(now)
    if self.hellMode then
        self.hellBank = 2
        self.nextSurge = now + SURGE_EVERY
        self:SetHeat(1)
        self:Cue()
    else
        self:SetBreakEnd(now + math.min(self:GetBreakTime(), 10))
    end
end

function ENT:Cue()
    net.Start("hz_cue")
    net.WriteString("hordez/mega_mob_incoming.wav")
    net.Broadcast()
end

function ENT:StartWave()
    local wave = self:GetWave() + 1
    self:SetWave(wave)
    self:SetBreakEnd(0)
    local size = self:GetStartSize() * (1 + self:GetGrowth() / 100) ^ (wave - 1)
    self.waveLeft = math.max(1, math.Round(size))
    self.sources = {}
    self:Cue()
end

function ENT:SpawnSome(count)
    for i = #self.sources, 1, -1 do
        local area = self.sources[i]
        if not IsValid(area) or HZ.SeenByPlayers(area:GetCenter(), self:GetSpawnMin() * 0.6) then
            table.remove(self.sources, i)
        end
    end

    local tries = 0
    while #self.sources < 3 and tries < 3 do
        local area = HZ.FindSpawnArea(self:GetSpawnMin(), self:GetSpawnMax(), 16, 0)
        if area then self.sources[#self.sources + 1] = area end
        tries = tries + 1
    end

    if #self.sources == 0 then return 0 end

    local done = 0
    local speed = 1 + math.min(WAVE_SPEEDUP * math.max(self:GetWave() - 1, 0), 0.3)
    local health = 1
    if self.hellMode then
        local heat = self:HeatMinutes()
        speed = 1 + math.min(heat * 0.02, 0.3)
        health = 1 + math.min(heat * HEAT_HEALTH, HEAT_HEALTH_MAX)
    end

    local cap = self:AliveCap()
    for _ = 1, count do
        if self:AliveCount() >= cap or not HZ.CanSpawn() then break end

        local pos = HZ.PointsAround(HZ.Pick(self.sources), 1)[1]
        if not pos then break end

        local zombie, row = HZ.SpawnChaser(pos, { owner = self, shambler = HZ.VariantShambler(self:GetVariant()),
            omni = true, speedScale = speed, healthScale = health })

        if not IsValid(zombie) and not row then break end

        if zombie then self.owned[zombie] = true end
        done = done + 1
    end

    return done
end

function ENT:Recycle(now)
    if now < (self.nextRecycle or 0) then return end

    self.nextRecycle = now + 3
    local far = self:GetSpawnMax() * 1.6
    for zombie in pairs(self.owned) do
        if IsValid(zombie) and not zombie.hz_dead then
            local pos = zombie:GetPos()
            local area = HZ.Flow.AreaOf(zombie)
            local dist = area and HZ.Flow.dist[area:GetID()] or HZ.NearestPlayerDist(pos)
            if (dist > far and not HZ.SeenByPlayers(pos, 800)) or HZ.IsStraggler(zombie, now) then
                self.owned[zombie] = nil
                zombie:Remove()
                if not self.hellMode then self.waveLeft = self.waveLeft + 1 end
            end
        end
    end
end

function ENT:Think()
    local now = CurTime()
    self:NextThink(now + 0.25)

    if not self:GetActive() then
        if self:GetRunStart() > 0 then self:ResetRun() end
        return true
    end

    HZ.FlowWantedUntil = now + 2
    if HZ.AIDisabled() or not HZ.Flow.ready then
        local dt = 0.25
        if self:GetRunStart() > 0 then self:SetRunStart(self:GetRunStart() + dt) end
        if self:GetBreakEnd() > 0 then self:SetBreakEnd(self:GetBreakEnd() + dt) end
        return true
    end

    if self:GetRunStart() <= 0 then
        if AnyPlayerAlive() then self:StartRun(now) end
        return true
    end

    if self.hellMode ~= self:GetHell() then
        self:StartRun(now)
        return true
    end

    if not AnyPlayerAlive() then
        self.deadSince = self.deadSince or now
        if now - self.deadSince > RESET_DELAY then self:ResetRun() end
        return true
    end

    self.deadSince = nil
    self:Recycle(now)

    if self.hellMode then
        local minutes = self:HeatMinutes()
        local level = 1 + math.floor(minutes * 60 / HEAT_STEP)
        if level ~= self:GetHeat() then self:SetHeat(level) end

        local bankMax = 8
        if now >= (self.nextSurge or 0) then
            self.nextSurge = now + math.max(SURGE_EVERY - minutes * 2, SURGE_EVERY_MIN)
            self.surge = 6 + level * 2
            self:Cue()
        end

        if (self.surge or 0) > 0 then
            bankMax = 8 + self.surge
            self.hellBank = self.hellBank + self.surge
            self.surge = 0
        end

        local rate = math.min(HELL_RATE0 + HELL_RAMP * minutes, HELL_RATE_MAX)
        self.hellBank = math.min(self.hellBank + rate * 0.25, math.max(bankMax, self.hellBank))
        if self.hellBank >= 1 then
            self.hellBank = self.hellBank - self:SpawnSome(math.min(4, math.floor(self.hellBank)))
        end

        return true
    end

    if self:GetBreakEnd() > 0 then
        if now >= self:GetBreakEnd() then self:StartWave() end
        return true
    end

    if self.waveLeft > 0 then
        self.waveLeft = self.waveLeft - self:SpawnSome(math.min(4, self.waveLeft))
    elseif self:AliveCount() == 0 then
        self:SetBreakEnd(now + math.max(self:GetBreakTime(), 0.25))
    end

    return true
end
