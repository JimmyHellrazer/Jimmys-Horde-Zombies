AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Horde Director"
ENT.Category = "Horde Zombies"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.Editable = true
ENT.RenderGroup = RENDERGROUP_BOTH
ENT.HZ_VirtualOK = true

function ENT:SetupDataTables()
    self:NetworkVar("Bool", 0, "Active", { KeyName = "active", Edit = { type = "Boolean", order = 1 } })
    self:NetworkVar("Int", 0, "Ambient", { KeyName = "ambient", Edit = { type = "Int", min = 0, max = 60, order = 2 } })
    self:NetworkVar("Int", 1, "HordeSize",
        { KeyName = "hordesize", Edit = { type = "Int", min = 0, max = 100, order = 3 } })

    self:NetworkVar("Int", 2, "HordeMin",
        { KeyName = "hordemin", Edit = { type = "Int", min = 15, max = 900, order = 4 } })

    self:NetworkVar("Int", 3, "HordeMax",
        { KeyName = "hordemax", Edit = { type = "Int", min = 15, max = 900, order = 5 } })

    self:NetworkVar("Int", 4, "SpawnMin",
        { KeyName = "spawnmin", Edit = { type = "Int", min = 300, max = 4000, order = 6 } })

    self:NetworkVar("Int", 5, "SpawnMax",
        { KeyName = "spawnmax", Edit = { type = "Int", min = 600, max = 8000, order = 7 } })

    self:NetworkVar("Int", 6, "RelaxTime",
        { KeyName = "relaxtime", Edit = { type = "Int", min = 0, max = 300, order = 8 } })

    self:NetworkVar("String", 0, "Phase")
    self:NetworkVar("Float", 0, "NextHorde")
    self:NetworkVar("String", 1, "Variant",
        { KeyName = "variant", Edit = { type = "Combo", values = HZ.VARIANTS, order = 9 } })

    self:NetworkVar("Int", 7, "MaxAlive",
        { KeyName = "maxalive", Edit = { type = "Int", min = 1, max = 500, order = 10 } })

    if SERVER then
        self:SetActive(true)
        self:SetVariant("runners")
        self:SetMaxAlive(60)
        self:SetAmbient(20)
        self:SetHordeSize(30)
        self:SetHordeMin(90)
        self:SetHordeMax(180)
        self:SetSpawnMin(900)
        self:SetSpawnMax(2600)
        self:SetRelaxTime(35)
        self:SetPhase("starting")
    end
end

if CLIENT then
    function ENT:Draw()
        if self:GetNW2Bool("hz_hidden") or not HZ.MarkersVisible() then return end

        self:DrawModel()
    end

    function ENT:DrawTranslucent()
        if self:GetNW2Bool("hz_hidden") or not HZ.MarkersVisible() then return end

        local pos = self:GetPos() + Vector(0, 0, 34)
        local ang = Angle(0, LocalPlayer():EyeAngles().y - 90, 90)
        local text = self:GetActive() and "active" or "off"
        cam.Start3D2D(pos, ang, 0.12)
        draw.SimpleTextOutlined("HORDE DIRECTOR", "DermaLarge", 0, 0, Color(255, 80, 60), TEXT_ALIGN_CENTER,
            TEXT_ALIGN_BOTTOM, 2, color_black)

        draw.SimpleTextOutlined(text, "DermaLarge", 0, 4, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 2,
            color_black)

        cam.End3D2D()
    end

    return
end

function ENT:Initialize()
    self:SetModel("models/props_c17/consolebox01a.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    self.owned = {}
    self.phase = "buildup"
    self.nextDespawn = 0
end

function ENT:OnRemove()
    if HZ.ActiveDirector == self then
        HZ.ActiveDirector = nil
        HZ.DirectorActive = false
    end

    for zombie in pairs(self.owned or {}) do
        if IsValid(zombie) then zombie:Remove() end
    end

    if HZ.DropVirtualOwned then HZ.DropVirtualOwned(self) end
end

function ENT:HZ_OnZombieDied(zombie)
    self.owned[zombie] = nil
end

function ENT:HZ_OnZombieReal(zombie, row)
    self:Own(zombie, row.horde)
    if row.horde and self.hordeSpawned then self.hordeSpawned[zombie] = true end
end

local function RandRange(lo, hi)
    if hi < lo then lo, hi = hi, lo end
    return math.Rand(lo, hi)
end

function ENT:Own(zombie, horde)
    if not IsValid(zombie) then return end

    self.owned[zombie] = true
    zombie.hz_horde = horde
end

function ENT:CanOwnMore()
    if not HZ.CanSpawn() then return false end

    local count = 0
    for zombie in pairs(self.owned) do
        if IsValid(zombie) then count = count + 1 end
    end

    return count + HZ.VirtualOwned(self) < self:GetMaxAlive()
end

function ENT:MaintainAmbient()
    local count = 0
    for zombie in pairs(self.owned) do
        if IsValid(zombie) and not zombie.hz_horde then count = count + 1 end
    end

    local want = self:GetAmbient()
    for _ = 1, 2 do
        if count >= want or not self:CanOwnMore() then return end

        local _, pos = HZ.FindSpawnArea(self:GetSpawnMin(), self:GetSpawnMax(), 12, HZ.CV.ahead:GetFloat())
        if not pos then return end

        self:Own(HZ.SpawnZombie(pos + Vector(0, 0, 4), nil, { idle = "random", owner = self,
            shambler = HZ.VariantShambler(self:GetVariant()) }), false)

        count = count + 1
    end
end

function ENT:StartHorde(size)
    local now = CurTime()
    self.phase = "peak"
    self.hordeLeft = size or self:GetHordeSize()
    self.hordeTotal = self.hordeLeft
    self.hordeSpawned = {}
    self.peakEnd = now + 60
    self.sources = {}
    net.Start("hz_cue")
    net.WriteString("hordez/mega_mob_incoming.wav")
    net.Broadcast()
    for zombie in pairs(self.owned) do
        if IsValid(zombie) and not zombie.hz_alerted and not zombie.hz_wakeAt then
            zombie.hz_wakeAt = now + math.Rand(0.2, 2.5)
        end
    end
end

function ENT:SpawnHordeBatch()
    if self.hordeLeft <= 0 then return end

    for i = #self.sources, 1, -1 do
        if HZ.SeenByPlayers(self.sources[i]:GetCenter(), self:GetSpawnMin() * 0.6) then
            table.remove(self.sources, i)
        end
    end

    local want = math.min(3, math.max(1, math.ceil(self.hordeTotal / 12)))
    local tries = 0
    while #self.sources < want and tries < 3 do
        local area = HZ.FindSpawnArea(self:GetSpawnMin(), self:GetSpawnMax(), 16, HZ.CV.ahead:GetFloat() * 0.5)
        if area then self.sources[#self.sources + 1] = area end
        tries = tries + 1
    end

    if #self.sources == 0 then return end

    local realSpawned = 0
    for _ = 1, math.min(4, self.hordeLeft) do
        if not self:CanOwnMore() then return end

        local src = HZ.Pick(self.sources)
        local pos = HZ.PointsAround(src, 1)[1]
        local zombie, row = HZ.SpawnChaser(pos, { owner = self, horde = true,
            shambler = HZ.VariantShambler(self:GetVariant()) })

        if not IsValid(zombie) and not row then return end

        if zombie then
            self:Own(zombie, true)
            self.hordeSpawned[zombie] = true
            realSpawned = realSpawned + 1
        end

        self.hordeLeft = self.hordeLeft - 1
        if realSpawned >= 2 then return end
    end
end

function ENT:RespawnStragglers()
    local queue = self.respawnQueue
    if not queue or #queue == 0 then return end

    for _ = 1, 2 do
        if #queue == 0 or not self:CanOwnMore() then return end

        local _, pos = HZ.FindSpawnArea(self:GetSpawnMin(), self:GetSpawnMax(), 12, HZ.CV.ahead:GetFloat() * 0.5)
        if not pos then return end

        local zombie, row = HZ.SpawnChaser(pos + Vector(0, 0, 4), { owner = self, horde = true,
            shambler = queue[#queue] })

        if not zombie and not row then return end

        queue[#queue] = nil
        if zombie then
            self:Own(zombie, true)
            if self.hordeSpawned then self.hordeSpawned[zombie] = true end
        end
    end
end

function ENT:Despawn(now)
    if now < self.nextDespawn then return end

    self.nextDespawn = now + 2
    local far = self:GetSpawnMax() * 1.6
    for zombie in pairs(self.owned) do
        if not IsValid(zombie) then
            self.owned[zombie] = nil
        else
            local pos = zombie:GetPos()
            local dist
            local area = HZ.Flow.AreaOf(zombie)
            if area then dist = HZ.Flow.dist[area:GetID()] end
            dist = dist or HZ.NearestPlayerDist(pos)
            local limit = zombie.hz_alerted and far * 1.3 or far
            if dist > limit and not HZ.SeenByPlayers(pos, 800) then
                self.owned[zombie] = nil
                zombie:Remove()
            elseif zombie.hz_horde and HZ.IsStraggler(zombie, now) then
                self.owned[zombie] = nil
                self.respawnQueue = self.respawnQueue or {}
                self.respawnQueue[#self.respawnQueue + 1] = zombie.hz_shambler and true or false
                zombie:Remove()
            end
        end
    end
end

function ENT:Think()
    local now = CurTime()
    self:NextThink(now + 0.5)
    if not self:GetActive() then
        if HZ.ActiveDirector == self then HZ.ActiveDirector, HZ.DirectorActive = nil, false end
        self:SetPhase("off")
        return true
    end

    local other = HZ.ActiveDirector
    if IsValid(other) and other ~= self and other:GetActive() then
        self:SetPhase("standby (another director runs)")
        return true
    end

    HZ.ActiveDirector, HZ.DirectorActive = self, true
    if HZ.AIDisabled() then
        if self:GetNextHorde() > 0 then self:SetNextHorde(self:GetNextHorde() + 0.5) end
        if self.peakEnd then self.peakEnd = self.peakEnd + 0.5 end
        if self.relaxEnd then self.relaxEnd = self.relaxEnd + 0.5 end
        self:SetPhase("paused (ai_disabled)")
        return true
    end

    if not HZ.Flow.ready then
        self:SetPhase(HZ.Flow.noNav and "no navmesh - run nav_generate" or "building flow field")
        return true
    end

    if self.phase == "buildup" then
        if self.onslaught then
            self:StartHorde()
        else
            if self:GetNextHorde() <= 0 then self:SetNextHorde(now + RandRange(self:GetHordeMin(), self:GetHordeMax())) end
            if HZ.Stress > 40 then self:SetNextHorde(self:GetNextHorde() + 0.5) end
            self:MaintainAmbient()
            if now >= self:GetNextHorde() and self:GetHordeSize() > 0 then self:StartHorde() end
        end
    elseif self.phase == "peak" then
        self:SpawnHordeBatch()
        local alive = HZ.VirtualOwnedHorde(self)
        for zombie in pairs(self.hordeSpawned) do
            if IsValid(zombie) and HZ.Zombies[zombie] then
                alive = alive + 1
            else
                self.hordeSpawned[zombie] = nil
            end
        end

        local finished = (self.hordeLeft <= 0 and (alive <= math.ceil(self.hordeTotal * 0.25) or now > self.peakEnd))
            or now > self.peakEnd + 30
        if finished then
            self.phase = "relax"
            self.relaxEnd = now + (self.onslaught and 6 or self:GetRelaxTime())
            if self.onPanicFinished then
                local cb = self.onPanicFinished
                self.onPanicFinished = nil
                cb()
            end
        end
    elseif self.phase == "relax" then
        if now >= (self.relaxEnd or 0) then
            self.phase = "buildup"
            self:SetNextHorde(now + RandRange(self:GetHordeMin(), self:GetHordeMax()))
        end
    end

    self:RespawnStragglers()
    self:Despawn(now)
    self:SetPhase(self.phase)

    return true
end
