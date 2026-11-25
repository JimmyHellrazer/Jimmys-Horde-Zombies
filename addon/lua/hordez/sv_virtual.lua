-- Virtual zombies: the far part of a big horde is not entities at all.
--
-- A NextBot costs engine time every tick whatever its Lua does (thinking, locomotion, collision, networking),
-- and a thousand of them is more than a server tick has. So once more than hz_real_max infected are alive,
-- chasing zombies far from every target stop being entities and become "virtual": a table row that walks the
-- same flow field (sv_flow.lua) one straight leg at a time - a waypoint and an arrival time, nothing per tick.
-- Clients get each new waypoint and draw them as impostors (cl_virtual.lua, cl_impostor.lua). When one comes
-- within hz_virtual_near of a target and a real slot is free, it is spawned as a real hz_zombie where it
-- stands (same body, same health); with no slot free it keeps coming and stands at the back of the horde,
-- turning real as the ones in front are killed.
--
-- What a virtual zombie can't do: be meleed or burnt, bash doors (it walks the nav route as if they were
-- open), climb with an animation. Bullets and explosions do reach it (tested against the rows below).
-- Zombies owned by a director or spawner are never made virtual: those count their own entities.
util.AddNetworkString("hz_virt")
util.AddNetworkString("hz_virt_sync")

local CV = HZ.CV
local Flow = HZ.Flow
HZ.Virtual = HZ.Virtual or {}    -- id -> row
HZ.VCount = HZ.VCount or 0
local rows = HZ.Virtual

local sqrt, huge, random, floor, min, max = math.sqrt, math.huge, math.random, math.floor, math.min, math.max

function HZ.VirtualOn() return CV.virt:GetBool() end

---------------------------------------------------------------- ids and the outgoing batch
local nextId, freeIds, cooling = 1, {}, {}
local pendAdd, pendMove, pendDel = {}, {}, {}

local function newId()
	local n = #freeIds
	if n > 0 then
		local id = freeIds[n]
		freeIds[n] = nil
		return id
	end
	if nextId > 65000 then return nil end
	nextId = nextId + 1
	return nextId - 1
end

local function rest(t, from)      -- t[from..]
	local out = {}
	for i = from, #t do out[#out + 1] = t[i] end
	return out
end

local function clampCoord(v) return max(-32767, min(32767, floor(v + 0.5))) end

local function writeAdd(r, x, y, z)
	net.WriteUInt(r.id, 16)
	net.WriteInt(clampCoord(x), 16)
	net.WriteInt(clampCoord(y), 16)
	net.WriteInt(clampCoord(z), 16)
	net.WriteUInt(min(floor(r.speed), 1023), 10)
	net.WriteBool(r.female)
	net.WriteBool(r.shambler)
end

-- removals first, then new rows, then waypoints (a freed id is only handed out again after this went out)
local CHUNK = 2000
local function flush()
	while #pendDel > 0 or #pendAdd > 0 or #pendMove > 0 do
		net.Start("hz_virt")
		local n = min(#pendDel, CHUNK)
		net.WriteUInt(n, 16)
		for i = 1, n do
			local d = pendDel[i]
			net.WriteUInt(d[1], 16)
			net.WriteBool(d[2])
		end
		pendDel = rest(pendDel, n + 1)
		local delsLeft = #pendDel > 0
		n = delsLeft and 0 or min(#pendAdd, CHUNK)
		net.WriteUInt(n, 16)
		for i = 1, n do
			local r = pendAdd[i]
			writeAdd(r, r.x, r.y, r.z)
		end
		pendAdd = rest(pendAdd, n + 1)
		local addsLeft = delsLeft or #pendAdd > 0
		n = addsLeft and 0 or min(#pendMove, CHUNK)
		net.WriteUInt(n, 16)
		for i = 1, n do
			local r = pendMove[i]
			net.WriteUInt(r.id, 16)
			net.WriteInt(clampCoord(r.wx), 16)
			net.WriteInt(clampCoord(r.wy), 16)
			net.WriteInt(clampCoord(r.wz), 16)
		end
		pendMove = rest(pendMove, n + 1)
		net.Broadcast()
	end
	for i = 1, #cooling do freeIds[#freeIds + 1] = cooling[i] end
	cooling = {}
end

---------------------------------------------------------------- rows
local function posAt(r, now)
	local t0, t1 = r.t0, r.t1
	if now >= t1 or t1 <= t0 then return r.wx, r.wy, r.wz end
	local f = (now - t0) / (t1 - t0)
	return r.x + (r.wx - r.x) * f, r.y + (r.wy - r.y) * f, r.z + (r.wz - r.z) * f
end

-- opts: speed, shambler, model, hp (0..1), area (nav area id)
function HZ.AddVirtual(pos, opts)
	local id = newId()
	if not id then return nil end
	opts = opts or {}
	local shambler = opts.shambler
	if shambler == nil then shambler = random() < CV.sh_chance:GetFloat() end
	local model = opts.model or HZ.RandomModel()
	local speed = opts.speed
	if not speed then
		if shambler then
			speed = math.Rand(CV.sh_speed_lo:GetFloat(), max(CV.sh_speed_lo:GetFloat(), CV.sh_speed_hi:GetFloat()))
		else
			local var = math.Clamp(CV.speed_var:GetFloat(), 0, 0.9)
			speed = CV.runspeed:GetFloat() * math.Rand(1 - var, 1 + var)
		end
	end
	local now = CurTime()
	local r = { id = id, x = pos.x, y = pos.y, z = pos.z, wx = pos.x, wy = pos.y, wz = pos.z, t0 = now, t1 = now,
		speed = max(speed, 5), shambler = shambler and true or false, model = model,
		female = model:find("female", 1, true) ~= nil, hp = opts.hp or 1, area = opts.area }
	rows[id] = r
	HZ.VCount = HZ.VCount + 1
	pendAdd[#pendAdd + 1] = r
	return r
end

local function drop(r, killed)
	if rows[r.id] ~= r then return end
	rows[r.id] = nil
	HZ.VCount = HZ.VCount - 1
	pendDel[#pendDel + 1] = { r.id, killed and true or false }
	cooling[#cooling + 1] = r.id
	-- a row added and dropped before it was ever sent: nothing to tell anyone
	for i = #pendAdd, 1, -1 do
		if pendAdd[i] == r then
			table.remove(pendAdd, i)
			pendDel[#pendDel] = nil
			break
		end
	end
	for i = #pendMove, 1, -1 do if pendMove[i] == r then table.remove(pendMove, i) end end
end

function HZ.ClearVirtual()
	for _, r in pairs(rows) do drop(r, false) end
	flush()
end

-- The next straight leg along the flow field, from where the row stands (x, y, z).
-- A row heads for a point in the next nav area, but never in one stride: legs are at most STEP long and each
-- ends on the ground of whichever area it is over (CNavArea:GetZ). One long leg from a rooftop to the middle
-- of a big area below drew a line of zombies running through the sky; in short legs they follow slopes and
-- come down at the edge they stepped off. A leg also never lasts much over a second (slow shamblers take
-- short ones), so every row looks at the flow field again about that often.
local STEP, LEG_TIME = 260, 1.2
local probe = Vector()
local function nextLeg(r, now, x, y, z)
	local g = Flow.graph
	if not g or not Flow.ready then r.t1 = now + 1 return end
	local area = r.area
	if not area or not g.area[area] then
		local a = navmesh.GetNearestNavArea(Vector(x, y, z), false, 400, false, true)
		area = a and a:GetID()
		if not area or not g.area[area] then r.t1 = now + 2 return end
		r.area = area
	end
	-- where to: kept until reached (r.garea = the area it is in; nil while chasing the target itself)
	if not r.gx then
		local nxt = Flow.nxt[area]
		if nxt == false then
			-- in the target's own area: straight at it (it gets promoted or held long before arriving)
			local tgt = Flow.tgt[area]
			if not IsValid(tgt) then r.t1 = now + 0.5 return end
			local p = tgt:GetPos()
			r.gx, r.gy, r.gz, r.garea, r.gextra = p.x, p.y, p.z, nil, 0
		elseif nxt then
			local na = g.area[nxt]
			if not IsValid(na) then r.t1 = now + 1 return end
			local p = na:GetClosestPointOnArea(Vector(x, y, z))
			local c = g.center[nxt]
			local f = 0.2 + random() * 0.7      -- each takes its own line through the area: a crowd, not a queue
			r.gx, r.gy, r.gz = p.x + (c.x - p.x) * f, p.y + (c.y - p.y) * f, p.z + (c.z - p.z) * f
			r.garea = nxt
			r.fv = Flow.version
			r.gextra = Flow.ClimbLink(area, nxt) and (0.6 + math.abs(p.z - z) / 80) or 0   -- (a climb takes a moment)
		else
			r.t1 = now + 1                      -- no route from here (yet)
			return
		end
	end
	local dx, dy = r.gx - x, r.gy - y
	local d = sqrt(dx * dx + dy * dy)
	local tx, ty, tz, extra = nil, nil, nil, 0
	local STEP = max(40, min(STEP, r.speed * LEG_TIME))
	if d <= STEP then
		tx, ty, tz, extra = r.gx, r.gy, r.gz, r.gextra or 0
		if r.garea then r.area = r.garea end
		r.gx = nil
	else
		tx, ty = x + dx / d * STEP, y + dy / d * STEP
		probe:SetUnpacked(tx, ty, z)
		local na, cur = r.garea and g.area[r.garea], g.area[area]
		if na and IsValid(na) and na:IsOverlapping(probe, 2) then
			tz = na:GetZ(probe)
		elseif IsValid(cur) and cur:IsOverlapping(probe, 2) then
			tz = cur:GetZ(probe)
		else
			tz = z + (r.gz - z) * (STEP / d)    -- between the two (a gap, a ledge): along the straight line
		end
		if not r.garea then r.gx = nil end      -- (chasing the target itself: aim again from the next stop)
	end
	local ex, ey, ez = tx - x, ty - y, tz - z
	local len = sqrt(ex * ex + ey * ey + ez * ez)
	r.x, r.y, r.z, r.t0 = x, y, z, now
	r.wx, r.wy, r.wz = tx, ty, tz
	r.t1 = now + max(len / r.speed, 0.05) + extra
	pendMove[#pendMove + 1] = r
end

local function halt(r, now, x, y, z)
	r.hold = true
	r.x, r.y, r.z, r.wx, r.wy, r.wz, r.t0, r.t1 = x, y, z, x, y, z, now, now
	pendMove[#pendMove + 1] = r
end

local function promote(r, x, y, z)
	local yaw = math.deg(math.atan2(r.wy - r.y, r.wx - r.x))
	local ent = HZ.SpawnZombie(Vector(x, y, z + 4), yaw, { alerted = true, shambler = r.shambler, model = r.model, force = true })
	if not IsValid(ent) then return false end
	if r.hp < 1 then ent:SetHealth(max(1, floor(ent:GetMaxHealth() * r.hp))) end
	ent.hz_wasVirtual = true
	drop(r, false)
	return true
end

---------------------------------------------------------------- real <-> virtual
-- can this real zombie be turned into a row right now? (chasing, on its feet, nobody's, not mid-anything)
-- (one that came from a row and has since calmed down, with nobody left to chase, may go back too - else
-- flying past the horde in noclip would leave a trail of real zombies standing around for good)
local function demotable(z)
	return IsValid(z) and (z.hz_alerted or (z.hz_wasVirtual and not z.hz_wakeAt and (z.hz_pose == "wander" or z.hz_pose == "stand")))
		and not z.hz_dead and not IsValid(z.hz_owner) and not z.hz_inOnce and not z.hz_climbing
		and not z.hz_attacking and not z.hz_burnDie and not z.hz_shove and not z:IsOnFire() and z.loco:IsOnGround()
end

local function demote(z, pos)
	local a = Flow.AreaOf(z)
	local id = a and a:GetID()
	if not id or not Flow.graph or not Flow.graph.area[id] then return false end
	local r = HZ.AddVirtual(pos, { area = id, model = z:GetModel(), shambler = z.hz_shambler and true or false,
		speed = z.hz_shambler and z.hz_shamSpeed or CV.runspeed:GetFloat() * (z.hz_speedMul or 1),
		hp = math.Clamp(z:Health() / max(z:GetMaxHealth(), 1), 0.05, 1) })
	if not r then return false end
	z.hz_virtualized = true
	z:Remove()
	return true
end

-- Who decides what is real: everyone who can be chased AND everyone who can look. A noclipping, dead or
-- no-target player is not a target (HZ.GetTargets leaves them out, nothing chases them), but flying up to the
-- far horde must still turn it into real zombies - so distances here are to the nearest of both.
local viewers = {}
local function viewerList()
	local n = 0
	for _, t in ipairs(HZ.GetTargets()) do
		n = n + 1
		viewers[n] = t.pos
	end
	for _, p in ipairs(player.GetAll()) do
		n = n + 1
		viewers[n] = p:GetPos()
	end
	for i = #viewers, n + 1, -1 do viewers[i] = nil end
	return viewers, n
end

local function nearestTarget2(targets, nT, pos)
	local best = huge
	for i = 1, nT do
		local d2 = targets[i]:DistToSqr(pos)
		if d2 < best then best = d2 end
	end
	return best
end

---------------------------------------------------------------- the walk (4x a second)
local PROMOTE_PER_PASS = 5
local SWAP_PER_PASS = 6
local waiting = {}
local function byDist(a, b) return a.d2 < b.d2 end
local function byDistDesc(a, b) return a.d2 > b.d2 end

-- The real ones should be the nearest ones. Rows left waiting inside the promotion distance trade places with
-- real zombies that are further out than they are (the far one turns virtual, the near row turns real); a
-- row with a target right on top of it and nobody to trade with turns real anyway, up to twice the cap.
-- Without this, walking into the waiting crowd (or it reaching a player the real ones had left behind) meant
-- standing among impostors.
local function trade(n, targets, nT, cap)
	table.sort(waiting, byDist)
	local reals
	for i = 1, min(n, SWAP_PER_PASS) do
		local w = waiting[i]
		local r = w.r
		if rows[r.id] ~= r then break end
		local done = false
		if w.d2 < 1500 * 1500 then
			if not reals then
				reals = {}
				for z in pairs(HZ.Zombies) do
					if demotable(z) then
						local pos = z:GetPos()
						reals[#reals + 1] = { z = z, pos = pos, d2 = nearestTarget2(targets, nT, pos) }
					end
				end
				table.sort(reals, byDistDesc)
			end
			local c = reals[1]
			-- (the far one has to be clearly further, and far enough that turning into an impostor isn't seen up close)
			if c and c.d2 > w.d2 * 1.7 and c.d2 > 1100 * 1100 and promote(r, w.x, w.y, w.z) then
				table.remove(reals, 1)
				demote(c.z, c.pos)
				done = true
			end
		end
		if not done and w.d2 < 650 * 650 and HZ.Count < cap * 2 then promote(r, w.x, w.y, w.z) end
	end
end

timer.Create("hordez_virtual", 0.25, 0, function()
	if HZ.VCount == 0 then
		if #pendDel > 0 then flush() end
		return
	end
	if HZ.AIDisabled() then return end
	local now = CurTime()
	local targets, nT = viewerList()
	local near = CV.virt_near:GetFloat()
	local near2 = near * near
	local cap = CV.real_max:GetInt()
	local real, promoted = HZ.Count, 0
	local nWait = 0
	for _, r in pairs(rows) do
		local x, y, z = posAt(r, now)
		local best = huge
		for i = 1, nT do
			local p = targets[i]
			local dx, dy, dz = p.x - x, p.y - y, p.z - z
			local d2 = dx * dx + dy * dy + dz * dz
			if d2 < best then best = d2 end
		end
		-- Rows never stop to wait at a distance: with no real slot free they keep coming with the rest of the
		-- horde, and only stand once they are at its back (each at its own depth, 300-675 units out, so they
		-- fill in behind the real ones instead of lining up). They move on again when the target does.
		local walks = true
		if best < near2 then
			if real < cap and promoted < PROMOTE_PER_PASS and promote(r, x, y, z) then
				real, promoted = real + 1, promoted + 1
				walks = false
			else
				nWait = nWait + 1
				local w = waiting[nWait]
				if not w then w = {} waiting[nWait] = w end
				w.r, w.d2, w.x, w.y, w.z = r, best, x, y, z
				if best < (300 + (r.id % 16) * 25) ^ 2 then
					if not r.hold then halt(r, now, x, y, z) end
					walks = false
				end
			end
		end
		if walks then
			if now >= r.t1 then
				r.hold = nil
				nextLeg(r, now, x, y, z)
			elseif r.gx and r.garea and r.fv ~= Flow.version then
				-- the flow field was solved again while this one is mid-stride: if its way on now leads
				-- somewhere else (the target moved), turn at once instead of finishing the walk to the old goal
				if Flow.nxt[r.area] ~= r.garea then
					r.gx = nil
					nextLeg(r, now, x, y, z)
				else
					r.fv = Flow.version
				end
			end
		end
	end
	for i = #waiting, nWait + 1, -1 do waiting[i] = nil end
	if nWait > 0 and nT > 0 then trade(nWait, targets, nT, cap) end
	flush()
end)

---------------------------------------------------------------- real -> virtual by distance (1x a second)
local DEMOTE_PER_PASS = 30
timer.Create("hordez_virtual_demote", 1, 0, function()
	if not HZ.VirtualOn() or HZ.Count == 0 or HZ.AIDisabled() or not Flow.graph then return end
	local cap = CV.real_max:GetInt()
	local real = HZ.Count
	local far = max(CV.virt_far:GetFloat(), CV.virt_near:GetFloat() + 200)
	local far2, always2 = far * far, far * far * 2.56     -- (beyond 1.6x that distance: whatever the count)
	local targets, nT = viewerList()
	if nT == 0 then return end
	local done = 0
	for z in pairs(HZ.Zombies) do
		if done >= DEMOTE_PER_PASS then break end
		if demotable(z) then
			local pos = z:GetPos()
			local best = nearestTarget2(targets, nT, pos)
			if (best > always2 or (best > far2 and real > cap)) and demote(z, pos) then
				real, done = real - 1, done + 1
			end
		end
	end
	if done > 0 then flush() end
end)

---------------------------------------------------------------- shooting them
-- No entity for a bullet to hit, so shots are tested against the rows: the nearest one within a body's width
-- of the bullet's line (wider for a spread) takes the damage.
local shotTr = {}
local shotIn = { mask = MASK_SHOT, output = shotTr }
hook.Add("EntityFireBullets", "hordez_virtual", function(e, data)
	if HZ.VCount == 0 or not IsValid(e) or e:GetClass() == "hz_zombie" then return end
	local src, dir = data.Src, data.Dir
	if not src or not dir then return end
	dir = dir:GetNormalized()
	shotIn.start, shotIn.endpos, shotIn.filter = src, src + dir * (data.Distance and data.Distance > 0 and data.Distance or 8192), e
	util.TraceLine(shotIn)
	local len = shotTr.HitPos:Distance(src)
	local sx, sy, sz, dx, dy, dz = src.x, src.y, src.z, dir.x, dir.y, dir.z
	local spread = data.Spread and max(data.Spread.x, data.Spread.y) or 0
	local num = max(data.Num or 1, 1)
	local dmg = (data.Damage and data.Damage > 0 and data.Damage or 30) * (num > 1 and num * 0.5 or 1)
	local now = CurTime()
	local hit, hitT
	for _, r in pairs(rows) do
		local x, y, z = posAt(r, now)
		local cx, cy, cz = x - sx, y - sy, z + 40 - sz
		local t = cx * dx + cy * dy + cz * dz
		if t > 0 and t < len and (not hitT or t < hitT) then
			local rad = 22 + min(spread * t, 60)
			if cx * cx + cy * cy + cz * cz - t * t < rad * rad then hit, hitT = r, t end
		end
	end
	if not hit then return end
	local hpMax = hit.shambler and CV.sh_health:GetFloat() or CV.health:GetFloat()
	hit.hp = hit.hp - dmg / max(hpMax, 1)
	if hit.hp <= 0 then
		drop(hit, true)
		flush()
	end
end)

-- explosions (seen through whatever entity they damaged): rows near the blast die
local nextBlast = 0
hook.Add("EntityTakeDamage", "hordez_virtual", function(_, dmg)
	if HZ.VCount == 0 or not dmg:IsExplosionDamage() then return end
	local now = CurTime()
	if now < nextBlast then return end
	nextBlast = now + 0.1
	local inf = dmg:GetInflictor()
	local c = IsValid(inf) and inf:GetPos() or dmg:GetDamagePosition()
	local rad = math.Clamp(dmg:GetDamage() * 2.5, 150, 450)
	local r2 = rad * rad
	local any
	for _, r in pairs(rows) do
		local x, y, z = posAt(r, now)
		local dx, dy, dz = x - c.x, y - c.y, z - c.z
		if dx * dx + dy * dy + dz * dz < r2 then
			drop(r, true)
			any = true
		end
	end
	if any then flush() end
end)

---------------------------------------------------------------- joining players, cleanup
net.Receive("hz_virt_sync", function(_, ply)
	local now = CurTime()
	if (ply.hz_virtSync or 0) > now then return end
	ply.hz_virtSync = now + 5
	local list = {}
	for _, r in pairs(rows) do list[#list + 1] = r end
	for i = 1, max(#list, 1), CHUNK do
		local n = min(CHUNK, #list - i + 1)
		net.Start("hz_virt")
		net.WriteUInt(0, 16)
		net.WriteUInt(n, 16)
		for k = i, i + n - 1 do
			local r = list[k]
			local x, y, z = posAt(r, now)
			writeAdd(r, x, y, z)
		end
		net.WriteUInt(n, 16)
		for k = i, i + n - 1 do
			local r = list[k]
			net.WriteUInt(r.id, 16)
			net.WriteInt(clampCoord(r.wx), 16)
			net.WriteInt(clampCoord(r.wy), 16)
			net.WriteInt(clampCoord(r.wz), 16)
		end
		net.Send(ply)
	end
end)

hook.Add("PostCleanupMap", "hordez_virtual", HZ.ClearVirtual)
cvars.AddChangeCallback("hz_virtual", function(_, _, new)
	if not tobool(new) then HZ.ClearVirtual() end
end, "hordez_virtual")
