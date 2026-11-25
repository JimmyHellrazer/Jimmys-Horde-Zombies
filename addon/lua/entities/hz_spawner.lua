AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Infected Spawner"
ENT.Category = "Horde Zombies"
ENT.Spawnable = true
ENT.AdminOnly = true
ENT.Editable = true
ENT.RenderGroup = RENDERGROUP_BOTH

local IDLE_TYPES = { Random = "random", Standing = "stand", Wandering = "wander", Sitting = "sit",
    Lying = "lie", ["Leaning on wall"] = "lean", Crouching = "crouch" }

function ENT:SetupDataTables()
    self:NetworkVar("Bool", 0, "Active", { KeyName = "active", Edit = { type = "Boolean", order = 1 } })
    self:NetworkVar("String", 0, "IdleType",
        { KeyName = "idletype", Edit = { type = "Combo", values = IDLE_TYPES, order = 2 } })

    self:NetworkVar("Int", 0, "Count", { KeyName = "count", Edit = { type = "Int", min = 1, max = 30, order = 3 } })
    self:NetworkVar("Int", 1, "Radius", { KeyName = "radius", Edit = { type = "Int", min = 0, max = 1500, order = 4 } })
    self:NetworkVar("Int", 2, "Respawn",
        { KeyName = "respawn", Edit = { type = "Int", min = 0, max = 600, order = 5 } })

    self:NetworkVar("Bool", 1, "StartAlerted", { KeyName = "startalerted", Edit = { type = "Boolean", order = 6 } })
    self:NetworkVar("Bool", 2, "HiddenRespawn", { KeyName = "hiddenrespawn", Edit = { type = "Boolean", order = 7 } })
    self:NetworkVar("Int", 3, "Alive")
    self:NetworkVar("String", 1, "Variant",
        { KeyName = "variant", Edit = { type = "Combo", values = HZ.VARIANTS, order = 8 } })

    if SERVER then
        self:SetVariant("runners")
        self:SetActive(true)
        self:SetIdleType("random")
        self:SetCount(5)
        self:SetRadius(300)
        self:SetRespawn(30)
        self:SetStartAlerted(false)
        self:SetHiddenRespawn(true)
    end
end

if CLIENT then
    function ENT:Draw()
        if not HZ.MarkersVisible() then return end

        self:DrawModel()
    end

    function ENT:DrawTranslucent()
        if not HZ.MarkersVisible() then return end

        local pos = self:GetPos()
        render.SetColorMaterial()
        local radius = self:GetRadius()
        if radius > 0 then render.DrawWireframeSphere(pos, radius, 16, 8, Color(255, 120, 60, 60), true) end
        local ang = Angle(0, LocalPlayer():EyeAngles().y - 90, 90)
        cam.Start3D2D(pos + Vector(0, 0, 40), ang, 0.12)
        draw.SimpleTextOutlined("INFECTED SPAWNER", "DermaLarge", 0, 0, Color(255, 160, 60), TEXT_ALIGN_CENTER,
            TEXT_ALIGN_BOTTOM, 2, color_black)

        draw.SimpleTextOutlined(("%s  %d/%d"):format(self:GetIdleType(), self:GetAlive(), self:GetCount()),
            "DermaLarge", 0, 4,
            self:GetActive() and color_white or Color(150, 150, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 2, color_black)

        cam.End3D2D()
    end

    return
end

function ENT:Initialize()
    self:SetModel("models/props_junk/TrafficCone001a.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    self.zs = {}
    self.deaths = {}
    self.spawned = 0
end

function ENT:OnRemove()
    for zombie in pairs(self.zs or {}) do
        if IsValid(zombie) then zombie:Remove() end
    end
end

function ENT:HZ_OnZombieDied(zombie)
    self.zs[zombie] = nil
    self.deaths[#self.deaths + 1] = CurTime()
end

function ENT:SpawnPoint()
    local pos = self:GetPos()
    local radius = self:GetRadius()
    if radius < 24 then return pos + Vector(0, 0, 4) end

    local areas = navmesh.Find(pos, radius, 64, 64)
    for _ = 1, 6 do
        local area = HZ.Pick(areas)
        if not area then break end

        local point = area:GetRandomPoint()
        if point:DistToSqr(pos) <= radius * radius then return point + Vector(0, 0, 4) end
    end

    local origin = pos + Vector(math.Rand(-radius, radius), math.Rand(-radius, radius), 64)
    local tr = util.TraceLine({ start = origin, endpos = origin - Vector(0, 0, 256), mask = MASK_NPCSOLID_BRUSHONLY })
    if tr.Hit and not tr.StartSolid then return tr.HitPos + Vector(0, 0, 4) end

    return pos + Vector(0, 0, 4)
end

function ENT:Think()
    local now = CurTime()
    self:NextThink(now + 1)
    local alive = 0
    for zombie in pairs(self.zs) do
        if IsValid(zombie) and HZ.Zombies[zombie] then
            alive = alive + 1
        else
            self.zs[zombie] = nil
        end
    end

    self:SetAlive(alive)
    if not self:GetActive() or HZ.AIDisabled() then return true end

    local count = self:GetCount()
    for _ = 1, 3 do
        if alive >= count or not HZ.CanSpawn() then break end

        local fresh = self.spawned < count
        if not fresh then
            local respawn = self:GetRespawn()
            if respawn <= 0 or not self.deaths[1] or now < self.deaths[1] + respawn then break end
        end

        local spawnPos = self:SpawnPoint()
        if not fresh and self:GetHiddenRespawn() and HZ.SeenByPlayers(spawnPos, 500) then break end

        local zombie = HZ.SpawnZombie(spawnPos, nil,
            { idle = self:GetIdleType(), alerted = self:GetStartAlerted(), owner = self,
            shambler = HZ.VariantShambler(self:GetVariant()) })

        if not IsValid(zombie) then break end

        self.zs[zombie] = true
        alive = alive + 1
        if fresh then
            self.spawned = self.spawned + 1
        else
            table.remove(self.deaths, 1)
        end
    end

    return true
end
