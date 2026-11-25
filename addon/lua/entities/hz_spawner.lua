AddCSLuaFile()

-- Sandbox spawner: keeps up to Count infected of an idle type inside Radius, respawning dead ones after
-- Respawn seconds (0 = never) - optionally only where no player is looking. Right-click -> Edit Properties.
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
	self:NetworkVar("String", 0, "IdleType", { KeyName = "idletype", Edit = { type = "Combo", values = IDLE_TYPES, order = 2 } })
	self:NetworkVar("Int", 0, "Count", { KeyName = "count", Edit = { type = "Int", min = 1, max = 30, order = 3 } })
	self:NetworkVar("Int", 1, "Radius", { KeyName = "radius", Edit = { type = "Int", min = 0, max = 1500, order = 4 } })
	self:NetworkVar("Int", 2, "Respawn", { KeyName = "respawn", Edit = { type = "Int", min = 0, max = 600, order = 5 } })
	self:NetworkVar("Bool", 1, "StartAlerted", { KeyName = "startalerted", Edit = { type = "Boolean", order = 6 } })
	self:NetworkVar("Bool", 2, "HiddenRespawn", { KeyName = "hiddenrespawn", Edit = { type = "Boolean", order = 7 } })
	self:NetworkVar("Int", 3, "Alive")
	self:NetworkVar("String", 1, "Variant", { KeyName = "variant", Edit = { type = "Combo", values = HZ.VARIANTS, order = 8 } })
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
		local r = self:GetRadius()
		if r > 0 then render.DrawWireframeSphere(pos, r, 16, 8, Color(255, 120, 60, 60), true) end
		local ang = Angle(0, LocalPlayer():EyeAngles().y - 90, 90)
		cam.Start3D2D(pos + Vector(0, 0, 40), ang, 0.12)
			draw.SimpleTextOutlined("INFECTED SPAWNER", "DermaLarge", 0, 0, Color(255, 160, 60), TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM, 2, color_black)
			draw.SimpleTextOutlined(("%s  %d/%d"):format(self:GetIdleType(), self:GetAlive(), self:GetCount()), "DermaLarge", 0, 4,
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
	local ph = self:GetPhysicsObject()
	if IsValid(ph) then ph:EnableMotion(false) end
	self.zs = {}
	self.deaths = {}
	self.spawned = 0
end

function ENT:OnRemove()
	for z in pairs(self.zs or {}) do if IsValid(z) then z:Remove() end end
end

function ENT:HZ_OnZombieDied(z)
	self.zs[z] = nil
	self.deaths[#self.deaths + 1] = CurTime()
end

function ENT:SpawnPoint()
	local pos = self:GetPos()
	local r = self:GetRadius()
	if r < 24 then return pos + Vector(0, 0, 4) end
	local areas = navmesh.Find(pos, r, 64, 64)
	for _ = 1, 6 do
		local a = HZ.Pick(areas)
		if not a then break end
		local p = a:GetRandomPoint()
		if p:DistToSqr(pos) <= r * r then return p + Vector(0, 0, 4) end
	end
	-- no navmesh here: random spot on the ground
	local o = pos + Vector(math.Rand(-r, r), math.Rand(-r, r), 64)
	local tr = util.TraceLine({ start = o, endpos = o - Vector(0, 0, 256), mask = MASK_NPCSOLID_BRUSHONLY })
	if tr.Hit and not tr.StartSolid then return tr.HitPos + Vector(0, 0, 4) end
	return pos + Vector(0, 0, 4)
end

function ENT:Think()
	local now = CurTime()
	self:NextThink(now + 1)
	local alive = 0
	for z in pairs(self.zs) do
		if IsValid(z) and HZ.Zombies[z] then alive = alive + 1 else self.zs[z] = nil end
	end
	self:SetAlive(alive)
	if not self:GetActive() or HZ.AIDisabled() then return true end

	local count = self:GetCount()
	for _ = 1, 3 do
		if alive >= count or not HZ.CanSpawn() then break end
		local fresh = self.spawned < count       -- initial fill (or Count was raised)
		if not fresh then
			local rs = self:GetRespawn()
			if rs <= 0 or not self.deaths[1] or now < self.deaths[1] + rs then break end
		end
		local p = self:SpawnPoint()
		if not fresh and self:GetHiddenRespawn() and HZ.SeenByPlayers(p, 500) then break end
		local z = HZ.SpawnZombie(p, nil, { idle = self:GetIdleType(), alerted = self:GetStartAlerted(), owner = self,
			shambler = HZ.VariantShambler(self:GetVariant()) })
		if not IsValid(z) then break end
		self.zs[z] = true
		alive = alive + 1
		if fresh then self.spawned = self.spawned + 1 else table.remove(self.deaths, 1) end
	end
	return true
end
