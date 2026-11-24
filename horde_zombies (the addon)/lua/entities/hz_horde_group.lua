AddCSLuaFile()

-- Spawnmenu "Infected Horde": drops hz_horde_count infected around where it was spawned, then removes
-- itself. The group goes into one undo entry for the player who spawned it.
ENT.Type = "point"
ENT.Base = "base_point"
ENT.PrintName = "Infected Horde"

list.Set("NPC", "hz_horde_group", { Name = "Infected Horde", Class = "hz_horde_group", Category = "Horde Zombies", IconOverride = "entities/hz_horde_group.png" })

if CLIENT then return end

local function groundPoint(center, r)
	for _ = 1, 4 do
		local o = center + Vector(math.Rand(-r, r), math.Rand(-r, r), 48)
		local tr = util.TraceLine({ start = o, endpos = o - Vector(0, 0, 200), mask = MASK_NPCSOLID_BRUSHONLY })
		if tr.Hit and not tr.StartSolid then return tr.HitPos + Vector(0, 0, 4) end
	end
	return center + Vector(0, 0, 4)
end

function ENT:Initialize()
	-- sandbox sets the creator after Spawn(); wait a tick so the undo goes to the right player
	timer.Simple(0, function() if IsValid(self) then self:SpawnGroup() end end)
end

function ENT:SpawnGroup()
	local pos = self:GetPos()
	local n = self.hz_count or math.Clamp(HZ.CV.horde_count:GetInt(), 1, 100)
	local radius = math.Clamp(60 + n * 12, 80, 600)
	local alerted = HZ.CV.horde_alert:GetBool()
	local areas = navmesh.Find(pos, radius, 48, 48)
	local spawned = {}
	for _ = 1, n do
		local p
		local a = HZ.Pick(areas)
		if a then
			local q = a:GetRandomPoint()
			if q:DistToSqr(pos) <= radius * radius then p = q + Vector(0, 0, 4) end
		end
		p = p or groundPoint(pos, radius)
		local z = HZ.SpawnZombie(p, nil, { idle = "random", alerted = alerted, shambler = self.hz_shamblers or false })
		if not IsValid(z) then break end   -- hz_max_total reached
		spawned[#spawned + 1] = z
	end

	local ply = self:GetCreator()
	if IsValid(ply) and #spawned > 0 then
		undo.Create(self.PrintName)
		for _, z in ipairs(spawned) do undo.AddEntity(z) end
		undo.SetPlayer(ply)
		undo.Finish()
		for _, z in ipairs(spawned) do ply:AddCleanup("npcs", z) end
		if #spawned < n then ply:ChatPrint(("[hordez] spawned %d/%d (hz_max_total reached)"):format(#spawned, n)) end
	end
	SafeRemoveEntityDelayed(self, 0)
end
