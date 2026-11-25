-- Client side of virtual zombies (sv_virtual.lua): the far part of a big horde arrives as rows, not entities.
-- A row is "it is here, walking to there at this speed"; the server sends a new "there" each time one
-- arrives. cl_impostor.lua draws them (HZ.VirtualAt gives where a row is right now).
HZ.VirtualCl = HZ.VirtualCl or {}     -- id -> row
local rows = HZ.VirtualCl
local sqrt = math.sqrt

local function posAt(r, now)
	local t0, t1 = r.t0, r.t1
	if now >= t1 or t1 <= t0 then return r.wx, r.wy, r.wz end
	local f = (now - t0) / (t1 - t0)
	return r.x + (r.wx - r.x) * f, r.y + (r.wy - r.y) * f, r.z + (r.wz - r.z) * f
end
HZ.VirtualAt = posAt

net.Receive("hz_virt", function()
	local now = CurTime()
	-- gone: promoted to a real zombie (it appears as an entity) or killed
	for _ = 1, net.ReadUInt(16) do
		local id = net.ReadUInt(16)
		local killed = net.ReadBool()
		local r = rows[id]
		rows[id] = nil
		if r and killed then
			local x, y, z = posAt(r, now)
			local ed = EffectData()
			ed:SetOrigin(Vector(x, y, z + 44))
			ed:SetNormal(vector_up)
			util.Effect("BloodImpact", ed, true, true)
		end
	end
	-- new
	for _ = 1, net.ReadUInt(16) do
		local id = net.ReadUInt(16)
		local x, y, z = net.ReadInt(16), net.ReadInt(16), net.ReadInt(16)
		local speed = net.ReadUInt(10)
		local female, shambler = net.ReadBool(), net.ReadBool()
		rows[id] = { id = id, x = x, y = y, z = z, wx = x, wy = y, wz = z, t0 = now, t1 = now, speed = math.max(speed, 5),
			female = female, shambler = shambler, yaw = 0 }
	end
	-- a new waypoint: from wherever it is now
	for _ = 1, net.ReadUInt(16) do
		local id = net.ReadUInt(16)
		local wx, wy, wz = net.ReadInt(16), net.ReadInt(16), net.ReadInt(16)
		local r = rows[id]
		if r then
			local x, y, z = posAt(r, now)
			local dx, dy, dz = wx - x, wy - y, wz - z
			local d = sqrt(dx * dx + dy * dy + dz * dz)
			r.x, r.y, r.z, r.wx, r.wy, r.wz = x, y, z, wx, wy, wz
			r.t0, r.t1 = now, now + d / r.speed
			if d > 1 then
				r.yaw = math.atan2(dy, dx)
				r.vx, r.vy = dx / d * r.speed, dy / d * r.speed
			end
		end
	end
end)

-- (re)joining, or a Lua refresh: ask for everything
local function sync()
	net.Start("hz_virt_sync")
	net.SendToServer()
end
hook.Add("InitPostEntity", "hordez_virtual", sync)
if IsValid(LocalPlayer and LocalPlayer()) then sync() end

hook.Add("PostCleanupMap", "hordez_virtual", function()
	for id in pairs(rows) do rows[id] = nil end
end)
