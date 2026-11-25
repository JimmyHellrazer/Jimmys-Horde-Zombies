AddCSLuaFile()

ENT.Type = "point"
ENT.Base = "base_point"
ENT.PrintName = "Infected Horde"

list.Set("NPC", "hz_horde_group",
    { Name = "Infected Horde", Class = "hz_horde_group", Category = "Horde Zombies",
    IconOverride = "entities/hz_horde_group.png" })

if CLIENT then return end

local function GroundPoint(center, radius)
    for _ = 1, 4 do
        local origin = center + Vector(math.Rand(-radius, radius), math.Rand(-radius, radius), 48)
        local tr = util.TraceLine({ start = origin, endpos = origin - Vector(0, 0, 200),
            mask = MASK_NPCSOLID_BRUSHONLY })

        if tr.Hit and not tr.StartSolid then return tr.HitPos + Vector(0, 0, 4) end
    end

    return center + Vector(0, 0, 4)
end

function ENT:Initialize()
    timer.Simple(0, function()
        if IsValid(self) then self:SpawnGroup() end
    end)
end

function ENT:SpawnGroup()
    local pos = self:GetPos()
    local count = self.hz_count or math.Clamp(HZ.CV.horde_count:GetInt(), 1, 100)
    local radius = math.Clamp(60 + count * 12, 80, 600)
    local alerted = HZ.CV.horde_alert:GetBool()
    local areas = navmesh.Find(pos, radius, 48, 48)
    local spawned = {}
    for _ = 1, count do
        local spawnPos
        local area = HZ.Pick(areas)
        if area then
            local point = area:GetRandomPoint()
            if point:DistToSqr(pos) <= radius * radius then spawnPos = point + Vector(0, 0, 4) end
        end

        spawnPos = spawnPos or GroundPoint(pos, radius)
        local zombie = HZ.SpawnZombie(spawnPos, nil, { idle = "random", alerted = alerted, shambler = self.hz_shamblers
            or false })

        if not IsValid(zombie) then break end

        spawned[#spawned + 1] = zombie
    end

    local ply = self:GetCreator()
    if IsValid(ply) and #spawned > 0 then
        undo.Create(self.PrintName)
        for _, zombie in ipairs(spawned) do undo.AddEntity(zombie) end
        undo.SetPlayer(ply)
        undo.Finish()
        for _, zombie in ipairs(spawned) do ply:AddCleanup("npcs", zombie) end
        if #spawned < count then
            ply:ChatPrint(("[hordez] spawned %d/%d (hz_max_total reached)"):format(#spawned, count))
        end
    end

    SafeRemoveEntityDelayed(self, 0)
end
