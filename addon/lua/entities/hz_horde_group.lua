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
    local shamblers = self.hz_shamblers or false
    local ply = self:GetCreator()
    local name = self.PrintName
    local spawned = {}
    local done = 0
    local timerId = "hordez_group_" .. self:EntIndex()

    local function Finish()
        timer.Remove(timerId)
        if IsValid(ply) and #spawned > 0 then
            undo.Create(name)
            for _, zombie in ipairs(spawned) do
                if IsValid(zombie) then undo.AddEntity(zombie) end
            end

            undo.SetPlayer(ply)
            undo.Finish()
            for _, zombie in ipairs(spawned) do
                if IsValid(zombie) then ply:AddCleanup("npcs", zombie) end
            end

            if #spawned < count then
                ply:ChatPrint(("[hordez] spawned %d/%d (hz_max_total reached)"):format(#spawned, count))
            end
        end

        if IsValid(self) then self:Remove() end
    end

    local function Step()
        for _ = 1, 2 do
            if done >= count then
                Finish()
                return
            end

            local spawnPos
            local area = HZ.Pick(areas)
            if area then
                local point = area:GetRandomPoint()
                if point:DistToSqr(pos) <= radius * radius then spawnPos = point + Vector(0, 0, 4) end
            end

            spawnPos = spawnPos or GroundPoint(pos, radius)
            local zombie = HZ.SpawnZombie(spawnPos, nil, { idle = "random", alerted = alerted, shambler = shamblers })
            if not IsValid(zombie) then
                Finish()
                return
            end

            spawned[#spawned + 1] = zombie
            done = done + 1
        end

        if done >= count then Finish() end
    end

    Step()
    if done < count then timer.Create(timerId, 0.03, 0, Step) end
end
