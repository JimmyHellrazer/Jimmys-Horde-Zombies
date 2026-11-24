-- Horde brain: zombie registry, spatial grid, target list, hearing, voice budget, spawn helpers.
util.AddNetworkString("hz_rag")
util.AddNetworkString("hz_cue")
util.AddNetworkString("hz_shot")

HZ.Zombies = HZ.Zombies or {}   -- ent -> true
HZ.Count = 0
HZ.Stress = 0                   -- damage players took from zombies recently (director pacing)

function HZ.Register(z)
	if HZ.Zombies[z] then return end
	HZ.Zombies[z] = true
	HZ.Count = HZ.Count + 1
	z:SetNW2String("tif_faction", "hl2_monster")   -- TIF's side marker (TIF only reads it on NPCs so far)
	HZ.RelateZombie(z)
end

function HZ.Unregister(z)
	if not HZ.Zombies[z] then return end
	HZ.Zombies[z] = nil
	HZ.Count = HZ.Count - 1
	HZ.GridRemove(z)
end

-- global cap is optional (each system limits itself: director MaxAlive, spawner Count, drop size)
function HZ.CanSpawn()
	local m = HZ.CV.max:GetInt()
	return m <= 0 or HZ.Count < m
end

-- flow runs while anything chases or a director is active
function HZ.NeedFlow()
	if HZ.DirectorActive then return true end
	for z in pairs(HZ.Zombies) do
		if z.hz_alerted then return true end
	end
	return false
end

---------------------------------------------------------------- spatial grid (separation + alert spread)
local CELL = 128
local grid = {}
local function key(x, y) return math.floor(x / CELL) * 4096 + math.floor(y / CELL) end

function HZ.GridMove(z, pos)
	local k = key(pos.x, pos.y)
	if z.hz_cell == k then return end
	HZ.GridRemove(z)
	local c = grid[k]
	if not c then c = {} grid[k] = c end
	c[z] = true
	z.hz_cell = k
end

function HZ.GridRemove(z)
	local k = z.hz_cell
	if not k then return end
	local c = grid[k]
	if c then
		c[z] = nil
		if next(c) == nil then grid[k] = nil end
	end
	z.hz_cell = nil
end

-- calls fn(other, distSqr) for zombies within r of pos (r <= a few cells)
function HZ.Near(pos, r, fn, skip)
	local cx, cy = math.floor(pos.x / CELL), math.floor(pos.y / CELL)
	local n = math.ceil(r / CELL)
	local r2 = r * r
	for x = cx - n, cx + n do
		for y = cy - n, cy + n do
			local c = grid[x * 4096 + y]
			if c then
				for o in pairs(c) do
					if o ~= skip and IsValid(o) then
						local d2 = o:GetPos():DistToSqr(pos)
						if d2 <= r2 then fn(o, d2) end
					end
				end
			end
		end
	end
end

-- push away from crowding neighbours (returns offset vector to add to a goal)
function HZ.Separation(z, pos)
	local px, py, n = 0, 0, 0
	HZ.Near(pos, 40, function(o, d2)
		if d2 < 1 then
			px, py = px + math.Rand(-1, 1), py + math.Rand(-1, 1)
		else
			local op = o:GetPos()
			local d = math.sqrt(d2)
			local w = (40 - d) / 40
			px, py = px + (pos.x - op.x) / d * w, py + (pos.y - op.y) / d * w
		end
		n = n + 1
	end, z)
	if n == 0 then return nil end
	return Vector(px * 40, py * 40, 0)
end

---------------------------------------------------------------- targets
local targets, nextTargets = {}, 0
HZ.NPCTargets = HZ.NPCTargets or {}

-- HL2's own undead side with the horde: never targeted by it, and they like each other
HZ.FriendlyNPC = {
	npc_zombie = true, npc_zombie_torso = true, npc_fastzombie = true, npc_fastzombie_torso = true,
	npc_poisonzombie = true, npc_zombine = true, npc_headcrab = true, npc_headcrab_fast = true,
	npc_headcrab_black = true, npc_headcrab_poison = true,
}

-- Stock NPCs only fight what their relationship table says; NextBots are neutral to them by default,
-- so tell every NPC to hate each infected (equal priority to their other enemies: nearest wins).
local function relate(npc, z)
	if not (IsValid(npc) and IsValid(z) and npc:IsNPC()) then return end
	if HZ.FriendlyNPC[npc:GetClass()] then
		npc:AddEntityRelationship(z, D_LI, 0)
	elseif HZ.CV.npc_hostile:GetBool() then
		npc:AddEntityRelationship(z, D_HT, 0)
	end
end

function HZ.RelateZombie(z)
	for e in pairs(HZ.NPCTargets) do relate(e, z) end
	for e in pairs(HZ.FriendlyAllies or {}) do relate(e, z) end
end

HZ.FriendlyAllies = HZ.FriendlyAllies or {}   -- HL2 undead NPCs (not targets, but still need the D_LI)
hook.Add("OnEntityCreated", "hordez_targets", function(e)
	timer.Simple(0, function()
		if not IsValid(e) or e:GetClass() == "hz_zombie" then return end
		if not (e:IsNPC() or e:IsNextBot()) then return end
		if HZ.FriendlyNPC[e:GetClass()] then
			HZ.FriendlyAllies[e] = true
		else
			HZ.NPCTargets[e] = true
		end
		if e:IsNPC() then
			for z in pairs(HZ.Zombies) do relate(e, z) end
		end
	end)
end)

-- Backup for NPCs whose own senses still don't pick a zombie up: once a second, a hostile NPC with no
-- enemy gets the nearest infected it can actually see (within 2000) as its enemy.
local ENGAGE_R = 2000
timer.Create("hordez_npc_engage", 1, 0, function()
	if not HZ.CV.npc_hostile:GetBool() or HZ.Count == 0 or HZ.AIDisabled() then return end
	for e in pairs(HZ.NPCTargets) do
		if IsValid(e) and e:IsNPC() and e:Health() > 0 and not HZ.FriendlyNPC[e:GetClass()] then
			local cur = e:GetEnemy()
			if not (IsValid(cur) and cur:Health() > 0) then
				local eye = e:EyePos()
				local best, bd
				for z in pairs(HZ.Zombies) do
					if IsValid(z) and not z.hz_dead then
						local d = z:GetPos():DistToSqr(eye)
						if d < ENGAGE_R * ENGAGE_R and (not bd or d < bd) and e:Disposition(z) == D_HT then
							local tr = util.TraceLine({ start = eye, endpos = z:WorldSpaceCenter(), mask = MASK_BLOCKLOS,
								filter = { e, z } })
							if not tr.Hit then best, bd = z, d end
						end
					end
				end
				if best then
					e:UpdateEnemyMemory(best, best:GetPos())
					e:SetEnemy(best)
				end
			end
		end
	end
end)

-- toggling hz_npc_hostile re-applies to everything alive
cvars.AddChangeCallback("hz_npc_hostile", function(_, _, new)
	local hostile = tobool(new)
	for e in pairs(HZ.NPCTargets) do
		if IsValid(e) and e:IsNPC() then
			for z in pairs(HZ.Zombies) do
				if IsValid(z) then e:AddEntityRelationship(z, hostile and D_HT or D_NU, 0) end
			end
		end
	end
end, "hordez")
hook.Add("EntityRemoved", "hordez_targets", function(e)
	HZ.NPCTargets[e] = nil
	HZ.FriendlyAllies[e] = nil
end)

---------------------------------------------------------------- lures (pipe bombs, bile)
-- Works with any addon's pipe bomb / bile jar without knowing it: a thrown entity whose class or model
-- matches hz_lure_classes is a pipe bomb (draws every infected in hz_lure_radius for as long as it exists,
-- i.e. until it blows), one matching hz_bile_classes leaves a bile lure where it lands for hz_bile_time.
-- Other addons can register their own: HZ.AddLure(entOrPos, radius, seconds), or answer the
-- "HZ_LureKind" hook (ent) with "pipe", "bile" or false.
HZ.Lures = {}

local function patterns(cv)
	local t = {}
	for p in cv:GetString():lower():gmatch("[^,%s]+") do t[#t + 1] = p end
	return t
end

local NOT_LURES = { prop_physics = true, prop_physics_multiplayer = true, prop_dynamic = true, prop_ragdoll = true }
local function lureKind(e)
	if not IsValid(e) or e:IsWeapon() or e:IsPlayer() or e:IsNPC() or e:IsNextBot() then return nil end
	local h = hook.Run("HZ_LureKind", e)
	if h ~= nil then return h or nil end
	local c = e:GetClass():lower()
	if NOT_LURES[c] or c:sub(1, 7) == "weapon_" then return nil end
	local m = (e:GetModel() or ""):lower()
	for _, p in ipairs(patterns(HZ.CV.lure_cls)) do
		if c:find(p, 1, true) or m:find(p, 1, true) then return "pipe" end
	end
	for _, p in ipairs(patterns(HZ.CV.bile_cls)) do
		if c:find(p, 1, true) or m:find(p, 1, true) then return "bile" end
	end
end

-- ent (follows it while it exists) or a fixed position; seconds = nil lasts as long as the entity
function HZ.AddLure(src, radius, seconds)
	local l = { radius = radius or HZ.CV.lure_radius:GetFloat(), untilT = seconds and CurTime() + seconds or nil }
	if isvector(src) then l.pos = src else l.ent, l.pos = src, src:GetPos() end
	HZ.Lures[#HZ.Lures + 1] = l
	return l
end

hook.Add("OnEntityCreated", "hordez_lures", function(e)
	timer.Simple(0, function()   -- class and model are set by the time the next tick runs
		local k = IsValid(e) and lureKind(e)
		if k == "pipe" then HZ.AddLure(e)
		elseif k == "bile" then e.hz_bile = true end
	end)
end)

hook.Add("EntityRemoved", "hordez_lures", function(e)
	if e.hz_bile and HZ.CV.lures:GetBool() then
		HZ.AddLure(e:GetPos(), nil, HZ.CV.bile_time:GetFloat())
	end
end)

-- the strongest lure drawing pos (the nearest one in range)
function HZ.LureFor(pos)
	if #HZ.Lures == 0 or not HZ.CV.lures:GetBool() then return nil end
	local best, bd
	for _, l in ipairs(HZ.Lures) do
		local d = l.pos:DistToSqr(pos)
		if d < l.radius * l.radius and (not bd or d < bd) then best, bd = l, d end
	end
	return best
end

-- keep lure positions current, drop spent ones, and make them heard (wakes idle infected in range)
timer.Create("hordez_lures", 0.25, 0, function()
	local now = CurTime()
	for i = #HZ.Lures, 1, -1 do
		local l = HZ.Lures[i]
		local alive
		if l.ent then
			alive = IsValid(l.ent)
			if alive then l.pos = l.ent:GetPos() end
		else
			alive = now < (l.untilT or 0)
		end
		if alive and l.untilT and now >= l.untilT then alive = false end
		if not alive then
			table.remove(HZ.Lures, i)
		elseif HZ.CV.lures:GetBool() and now >= (l.nextNoise or 0) then
			l.nextNoise = now + 1
			HZ.Noise(l.pos, l.radius, IsValid(l.ent) and l.ent or nil)
		end
	end
end)
hook.Add("PostCleanupMap", "hordez_lures", function() HZ.Lures = {} end)

local ignorePlayers = GetConVar("ai_ignoreplayers")
local aiDisabled = GetConVar("ai_disabled")

-- Sandbox "Disable Thinking" (ai_disabled): zombies freeze in place, the director and spawners pause.
function HZ.AIDisabled() return aiDisabled ~= nil and aiDisabled:GetBool() end
-- Sandbox "Ignore Players" (ai_ignoreplayers): players are not targets, can't aggro and aren't heard.
function HZ.IgnoringPlayers() return ignorePlayers ~= nil and ignorePlayers:GetBool() end

-- cached list { {ent=, pos=, ply=bool} } refreshed 4x a second
function HZ.GetTargets()
	if CurTime() < nextTargets then return targets end
	nextTargets = CurTime() + 0.25
	targets = {}
	if not HZ.IgnoringPlayers() then
		for _, p in ipairs(player.GetAll()) do
			if p:Alive() and not p:IsFlagSet(FL_NOTARGET) and p:GetMoveType() ~= MOVETYPE_NOCLIP then
				targets[#targets + 1] = { ent = p, pos = p:GetPos(), ply = true }
			end
		end
	end
	if HZ.CV.target_npcs:GetBool() then
		for e in pairs(HZ.NPCTargets) do
			if IsValid(e) and e:Health() > 0 and not e:IsFlagSet(FL_NOTARGET) then
				targets[#targets + 1] = { ent = e, pos = e:GetPos() }
			end
		end
	end
	return targets
end

function HZ.NearestPlayerDist(pos)
	local best = math.huge
	for _, t in ipairs(HZ.GetTargets()) do
		if t.ply then
			local d = t.pos:DistToSqr(pos)
			if d < best then best = d end
		end
	end
	return math.sqrt(best)
end

function HZ.IsHostile(e)
	if not IsValid(e) or e:GetClass() == "hz_zombie" then return false end
	if e:IsPlayer() then return e:Alive() and not HZ.IgnoringPlayers() and not e:IsFlagSet(FL_NOTARGET) end
	return (e:IsNPC() or e:IsNextBot()) and e:Health() > 0
end

---------------------------------------------------------------- hearing
-- wake idle zombies in radius; farther ones react later (wave of heads turning)
function HZ.Noise(pos, radius, source)
	if HZ.AIDisabled() then return end
	if IsValid(source) and source:IsPlayer() and HZ.IgnoringPlayers() then return end
	local r2 = radius * radius
	for z in pairs(HZ.Zombies) do
		if not z.hz_alerted and not z.hz_wakeAt then
			local d2 = z:GetPos():DistToSqr(pos)
			if d2 < r2 then z:HZ_Hear(pos, math.sqrt(d2), source) end
		end
	end
end

function HZ.Spread(z)
	local pos = z:GetPos()
	HZ.Near(pos, HZ.CV.spread:GetFloat(), function(o)
		if not o.hz_alerted and not o.hz_wakeAt then o:HZ_Hear(pos, pos:Distance(o:GetPos()), z) end
	end, z)
end

hook.Add("EntityFireBullets", "hordez_hear", function(e)
	if not IsValid(e) or e:GetClass() == "hz_zombie" then return end
	local t = CurTime()
	if (e.hz_lastNoise or 0) > t then return end
	e.hz_lastNoise = t + 0.3
	HZ.Noise(e:GetPos(), HZ.CV.hear_gun:GetFloat(), e)
end)

-- Bullets don't hit the clientside death animations / ragdolls, so shots near recent kills are relayed and
-- the clients test them against the bodies themselves (flinches, early ragdoll, ragdoll pushes).
HZ.LastDeath = HZ.LastDeath or -1000
hook.Add("EntityFireBullets", "hordez_corpses", function(e, data)
	if CurTime() - HZ.LastDeath > 30 or not IsValid(e) or e:GetClass() == "hz_zombie" then return end
	local num = math.Clamp(data.Num or 1, 1, 32)
	local spread = data.Spread or vector_origin
	net.Start("hz_shot", true)
	net.WriteVector(data.Src)
	net.WriteNormal(data.Dir:GetNormalized())
	net.WriteUInt(num, 5)
	net.WriteFloat(math.max(spread.x, spread.y))
	net.WriteUInt(math.Clamp(math.floor(data.Damage or 10), 0, 1023), 10)
	net.SendPVS(data.Src)
end)

hook.Add("EntityTakeDamage", "hordez_hear", function(target, dmg)
	if dmg:IsExplosionDamage() then
		local t = CurTime()
		if (HZ.lastBlast or 0) < t then
			HZ.lastBlast = t + 0.2
			HZ.Noise(dmg:GetDamagePosition(), HZ.CV.hear_blast:GetFloat(), dmg:GetAttacker())
		end
	end
	if target:IsPlayer() then
		local a = dmg:GetAttacker()
		if IsValid(a) and a:GetClass() == "hz_zombie" then HZ.Stress = HZ.Stress + dmg:GetDamage() end
	end
end)

---------------------------------------------------------------- melee / shove arc
-- L4D2 swings and shoves sweep a line in front of you; GMod SWEPs hit one thing. When a SWEP's melee hit
-- or shove lands on one infected (seen from its damage, or from the push it gives), every other infected
-- in an arc in front of the attacker is staggered too, and for real melee hits takes the same damage.
-- No SWEP is touched; this only reads what the hit looked like.
local BULLETISH = bit.bor(DMG_BULLET, DMG_BUCKSHOT, DMG_BURN, DMG_SLOWBURN, DMG_POISON, DMG_NERVEGAS,
	DMG_RADIATION, DMG_DROWN, DMG_SHOCK, DMG_ENERGYBEAM, DMG_DISSOLVE)
HZ.MELEE_REACH = 130

-- the attacker, if this hit looks like a melee swing / bash / kick from up close
function HZ.MeleeAttacker(victim, dmg)
	local att = dmg:GetAttacker()
	if not IsValid(att) or att == victim or att:GetClass() == "hz_zombie" then return end
	if dmg:IsExplosionDamage() or dmg:IsDamageType(bit.bor(DMG_CRUSH, DMG_VEHICLE)) then return end
	if (victim:GetPos() - att:GetPos()):Length2DSqr() >= HZ.MELEE_REACH * HZ.MELEE_REACH then return end
	if dmg:IsDamageType(bit.bor(DMG_CLUB, DMG_SLASH)) then return att end
	local t = dmg:GetDamageType()
	if t ~= DMG_GENERIC and not dmg:IsDamageType(BULLETISH) then return att end
	local inf = dmg:GetInflictor()
	if t == DMG_GENERIC and IsValid(inf) and inf:IsWeapon() and dmg:GetDamageForce():LengthSqr() > 1 then return att end
end

-- the player who most likely shoved this zombie (a push with no damage carries no attacker)
function HZ.ShoverOf(z)
	local pos = z:GetPos()
	local best, bd
	for _, p in ipairs(player.GetAll()) do
		if p:Alive() then
			local rel = pos - p:GetPos()
			local d = rel:Length2DSqr()
			if d < 150 * 150 then
				rel.z = 0
				local aim = p:GetAimVector()
				aim.z = 0
				if rel:LengthSqr() > 1 and aim:LengthSqr() > 0.01 and rel:GetNormalized():Dot(aim:GetNormalized()) > 0.4
					and (not bd or d < bd) then
					best, bd = p, d
				end
			end
		end
	end
	return best
end

HZ.ArcBusy = false
function HZ.MeleeArc(att, first, dmg)
	if not HZ.CV.arc:GetBool() or not IsValid(att) then return end
	local now = CurTime()
	if (att.hz_arcUntil or 0) > now then return end   -- one sweep per swing
	att.hz_arcUntil = now + 0.25
	local aim = att:IsPlayer() and att:GetAimVector() or att:GetForward()
	aim = Vector(aim.x, aim.y, 0)
	if aim:LengthSqr() < 0.01 then return end
	aim:Normalize()
	local base = att:GetPos()
	local eye = att.GetShootPos and att:GetShootPos() or att:WorldSpaceCenter()
	local range = HZ.CV.arc_range:GetFloat()
	local cosA = math.cos(math.rad(HZ.CV.arc_angle:GetFloat()))
	local scale = dmg and HZ.CV.arc_damage:GetFloat() or 0
	local amount, dtype, inf, force = 0, DMG_CLUB, att, 0
	if dmg then
		amount, dtype, force = dmg:GetDamage() * scale, dmg:GetDamageType(), dmg:GetDamageForce():Length()
		if IsValid(dmg:GetInflictor()) then inf = dmg:GetInflictor() end
	end
	local hit = {}
	for z in pairs(HZ.Zombies) do
		if z ~= first and IsValid(z) and not z.hz_dead then
			local zp = z:GetPos()
			local rel = Vector(zp.x - base.x, zp.y - base.y, 0)
			local l = rel:Length()
			if l > 1 and l <= range and math.abs(zp.z - base.z) < 64 and rel:Dot(aim) / l >= cosA then
				local tr = util.TraceLine({ start = eye, endpos = z:WorldSpaceCenter(), mask = MASK_SOLID_BRUSHONLY })
				if not tr.Hit then hit[#hit + 1] = { z, rel } end
			end
		end
	end
	if #hit == 0 then return end
	HZ.ArcBusy = true
	for _, h in ipairs(hit) do
		local z, rel = h[1], h[2]
		if amount > 0 then
			local d = DamageInfo()
			d:SetDamage(amount)
			d:SetDamageType(dtype)
			d:SetAttacker(att)
			d:SetInflictor(inf)
			d:SetDamagePosition(z:WorldSpaceCenter())
			d:SetDamageForce(rel:GetNormalized() * force)
			z:TakeDamageInfo(d)
		end
		if IsValid(z) and not z.hz_dead then z:HZ_ExternalPush(rel, true) end
	end
	HZ.ArcBusy = false
	if HZ.CV.debug:GetBool() then print(("[hordez] melee arc from %s: %d more infected"):format(tostring(att), #hit)) end
end

hook.Add("EntityTakeDamage", "hordez_arc", function(target, dmg)
	if HZ.ArcBusy or not HZ.Zombies[target] then return end
	local att = HZ.MeleeAttacker(target, dmg)
	if att then HZ.MeleeArc(att, target, dmg) end
end)

timer.Create("hordez_stress", 1, 0, function() HZ.Stress = math.max(0, HZ.Stress * 0.93 - 1) end)

---------------------------------------------------------------- voices (global budget keeps 60 zombies from screaming at once)
HZ.Snd = {}
local function listSnd(dir, sexed)
	local function grab(d)
		local out = {}
		for _, f in ipairs(file.Find("sound/" .. d .. "/*.wav", "GAME")) do
			-- L4D2's CEDA hazmat suit deflating hiss is for that one uncommon infected, not our citizens
			if not f:lower():find("ceda", 1, true) then out[#out + 1] = d .. "/" .. f end
		end
		return out
	end
	if not sexed then return grab(dir) end
	local root = grab(dir)
	local m, f = grab(dir .. "/male"), grab(dir .. "/female")
	for _, s in ipairs(root) do m[#m + 1] = s f[#f + 1] = s end
	return { male = m, female = f }
end
local base = "hordez/infected/"
HZ.Snd.rage = listSnd(base .. "action/rage", true)
HZ.Snd.rageat = listSnd(base .. "action/rageat", true)
HZ.Snd.alert = listSnd(base .. "alert/alert", true)
HZ.Snd.becomealert = listSnd(base .. "alert/becomealert", true)
HZ.Snd.enraged = listSnd(base .. "alert/becomeenraged", true)
HZ.Snd.shot = listSnd(base .. "action/been_shot", true)
HZ.Snd.die = listSnd(base .. "action/die", true)
HZ.Snd.ignite = listSnd(base .. "action/ignite", true)
HZ.Snd.shoved = listSnd(base .. "action/shoved/mp")
HZ.Snd.hit = listSnd(base .. "hit")
HZ.Snd.miss = listSnd(base .. "miss")
HZ.Snd.idle = table.Add(table.Add(listSnd(base .. "idle/moaning"), listSnd(base .. "idle/mumbling")), listSnd(base .. "idle/breathing"))

local tokens, lastTok = 0, 0
function HZ.Voice(z, kind, level, force)
	local now = CurTime()
	local rate = HZ.CV.voices:GetFloat()
	tokens = math.min(rate, tokens + (now - lastTok) * rate)
	lastTok = now
	if not force and tokens < 1 then return end
	if (z.hz_voiceUntil or 0) > now and not force then return end
	if z.hz_shambler then
		kind = HZ.ShamblerVoice[kind]
		if not kind then return end
	end
	local s = HZ.Snd[kind]
	if not s then return end
	if s.male then s = z.hz_female and s.female or s.male end
	local path = HZ.Pick(s)
	if not path then return end
	tokens = tokens - 1
	z.hz_voiceUntil = now + (z.hz_shambler and 2.5 or 1.5)
	local pitch = z.hz_shambler and math.random(84, 94) or math.random(94, 106)
	z:EmitSound(path, level or 75, pitch, 1, CHAN_VOICE)
	-- faces (cl_faces.lua): the nearest zombies open their mouths while this plays
	local dur = SoundDuration(path)
	z:SetNW2Float("hz_yell", now + math.Clamp((dur and dur > 0 and dur or 1) * 100 / pitch, 0.3, 4))
end

-- shamblers: no screams, low moans (nil = stay quiet)
HZ.ShamblerVoice = { rage = "idle", rageat = "idle", alert = "idle", becomealert = "idle", enraged = nil,
	shot = "shot", die = "die", ignite = "ignite", shoved = "shoved", idle = "idle" }

function HZ.Sound(z, kind, level)
	local path = HZ.Pick(HZ.Snd[kind])
	if path then z:EmitSound(path, level or 70, math.random(95, 105), 1, CHAN_AUTO) end
end

---------------------------------------------------------------- spawning
function HZ.RandomModel()
	local female = math.random() < HZ.FemaleChance
	-- the female "_b" models have the beanie baked in, so they share the accessory chance
	local beanie = female and math.random() < HZ.CV.accessory:GetFloat()
	local pool = {}
	for _, m in ipairs(HZ.Models) do
		if (m:find("female", 1, true) ~= nil) == female and (not female or (m:find("_b.mdl", 1, true) ~= nil) == beanie) then
			pool[#pool + 1] = m
		end
	end
	return HZ.Pick(pool) or HZ.Models[1]
end

-- torso/legs fully random; accessories (beanie, gloves, glasses) only at hz_accessory_chance.
-- "None" for an accessory group is its empty submodel, or index 0 (bare hands) when it has none.
local ACCESSORY = { beanie = true, beanies = true, glasses = true, hands = true }
function HZ.RandomBodygroups(ent)
	local chance = HZ.CV.accessory:GetFloat()
	for _, bg in ipairs(ent:GetBodyGroups() or {}) do
		if bg.id ~= 0 and bg.num > 1 then
			if ACCESSORY[string.lower(bg.name)] then
				local none = 0
				for i = 0, bg.num - 1 do
					if (bg.submodels and bg.submodels[i] or "") == "" then none = i break end
				end
				local pick = none
				if math.random() < chance then
					local opts = {}
					for i = 0, bg.num - 1 do if i ~= none then opts[#opts + 1] = i end end
					pick = HZ.Pick(opts) or none
				end
				ent:SetBodygroup(bg.id, pick)
			else
				ent:SetBodygroup(bg.id, math.random(0, bg.num - 1))
			end
		end
	end
end

-- opts: idle ("random"/"stand"/"wander"/"sit"/"lie"/"lean"/"crouch"), alerted (bool), owner (director/spawner)
-- Spawn spot sanity: a zombie placed inside a prop, a wall or a vehicle is stuck for good, so check the
-- body fits (other infected don't count, they pass through each other) and if not, take the nearest spot
-- around it that does - same floor, in sight of the original point, with ground under it. Also settles the
-- spot onto the floor so slopes and spawn markers floating a little don't leave it hanging or buried.
local FIT_MINS, FIT_MAXS = Vector(-13, -13, 0), Vector(13, 13, 72)
local function notZombie(e) return e:GetClass() ~= "hz_zombie" end
local function floorAt(p)
	local tr = util.TraceLine({ start = p + Vector(0, 0, 24), endpos = p - Vector(0, 0, 64), mask = MASK_NPCSOLID, filter = notZombie })
	if tr.Hit and not tr.StartSolid and tr.HitNormal.z > 0.6 then return tr.HitPos + Vector(0, 0, 1) end
end
local function fits(p)
	local tr = util.TraceHull({ start = p + Vector(0, 0, 2), endpos = p + Vector(0, 0, 3), mins = FIT_MINS, maxs = FIT_MAXS,
		mask = MASK_NPCSOLID, filter = notZombie })
	return not tr.Hit and not tr.StartSolid
end
function HZ.FreeSpot(pos)
	local base = floorAt(pos) or pos
	if fits(base) then return base end
	for _, r in ipairs({ 24, 40, 60, 84, 112 }) do
		local off = math.Rand(0, 360)
		for k = 0, 7 do
			local p = base + Angle(0, off + k * 45, 0):Forward() * r
			local f = floorAt(p)
			if f and math.abs(f.z - base.z) < 40 and fits(f) then
				local los = util.TraceLine({ start = base + Vector(0, 0, 36), endpos = f + Vector(0, 0, 36),
					mask = MASK_NPCSOLID_BRUSHONLY })
				if not los.Hit then return f end
			end
		end
	end
	return base   -- nothing better nearby: the stuck check sorts it out once it moves
end

function HZ.SpawnZombie(pos, yaw, opts)
	if not HZ.CanSpawn() then return nil end
	pos = HZ.FreeSpot(pos)
	opts = opts or {}
	local z = ents.Create("hz_zombie")
	if not IsValid(z) then return nil end
	z.hz_idleType = opts.idle or "random"
	z.hz_startAlerted = opts.alerted
	z.hz_owner = opts.owner
	z.hz_placed = true   -- spot already checked (HZ.FreeSpot)
	if opts.shambler == nil then
		z.hz_shambler = math.random() < HZ.CV.sh_chance:GetFloat()
	else
		z.hz_shambler = opts.shambler and true or false
	end
	z:SetPos(pos)
	z:SetAngles(Angle(0, yaw or math.Rand(0, 360), 0))
	z:Spawn()
	z:Activate()
	return z
end

-- true when some player can plausibly see the point (in front of them with clear line of sight)
function HZ.SeenByPlayers(pos, near)
	near = near or 600
	local head = pos + Vector(0, 0, 56)
	for _, t in ipairs(HZ.GetTargets()) do
		if t.ply then
			local p = t.ent
			local eye = p:EyePos()
			local to = head - eye
			local d = to:Length()
			if d < near then return true end
			if to:GetNormalized():Dot(p:GetAimVector()) > 0.25 then
				local tr = util.TraceLine({ start = eye, endpos = head, mask = MASK_OPAQUE, filter = p })
				if not tr.Hit then return true end
			end
		end
	end
	return false
end

-- random hidden, reachable nav area whose path distance to the nearest target is in [minD, maxD]
-- Where each player is heading: their movement over the last few seconds, smoothed (standing still keeps
-- the last heading, so a player who stops to fight still gets zombies "ahead" of their route).
timer.Create("hordez_heading", 0.5, 0, function()
	for _, p in ipairs(player.GetAll()) do
		local pos = p:GetPos()
		local last = p.hz_hdLast
		p.hz_hdLast = pos
		if last then
			local mv = Vector(pos.x - last.x, pos.y - last.y, 0)
			if mv:LengthSqr() > 20 * 20 then
				mv:Normalize()
				local h = p.hz_heading
				h = h and (h * 0.6 + mv * 0.4) or mv
				if h:LengthSqr() > 0.01 then h:Normalize() end
				p.hz_heading = h
			end
		end
	end
end)

local function headingOf(p)
	if p.hz_heading then return p.hz_heading end
	local a = p:GetAimVector()
	a.z = 0
	return a:LengthSqr() > 0.01 and a:GetNormalized() or nil
end

-- how far "ahead" of the nearest player this spot is (-1 behind .. 1 straight ahead)
local function aheadScore(pos)
	local best, bd
	for _, t in ipairs(HZ.GetTargets()) do
		if t.ply then
			local d = t.pos:DistToSqr(pos)
			if not bd or d < bd then best, bd = t, d end
		end
	end
	if not best then return 0 end
	local h = headingOf(best.ent)
	if not h then return 0 end
	local to = Vector(pos.x - best.pos.x, pos.y - best.pos.y, 0)
	if to:LengthSqr() < 1 then return 0 end
	return to:GetNormalized():Dot(h)
end

-- A hidden spawn spot minD..maxD path-units from players. With ahead > 0 it gathers several candidates and,
-- that often, takes the one most in front of where players are heading (else a random one).
function HZ.FindSpawnArea(minD, maxD, tries, ahead)
	local g = HZ.Flow.graph
	if not g then return nil end
	local ids = g.ids
	tries = tries or 16
	local want = (ahead and ahead > 0) and 4 or 1
	local found = {}
	for _ = 1, tries * want do
		local id = ids[math.random(#ids)]
		local d = HZ.Flow.dist[id]
		local a = g.area[id]
		if d and d >= minD and d <= maxD and IsValid(a) and not a:IsUnderwater()
			and a:GetSizeX() >= 24 and a:GetSizeY() >= 24 then
			local p = a:GetRandomPoint()
			if not HZ.SeenByPlayers(p, minD * 0.6) then
				found[#found + 1] = { a, p }
				if #found >= want then break end
			end
		end
	end
	if #found == 0 then return nil end
	local pick = found[math.random(#found)]
	if want > 1 and math.random() < ahead then
		local bs
		for _, f in ipairs(found) do
			local s = aheadScore(f[2])
			if not bs or s > bs then pick, bs = f, s end
		end
	end
	return pick[1], pick[2]
end

---------------------------------------------------------------- doors
-- A door has health (hz_door_health) that every pounding zombie chips at, so a crowd gets through fast and a
-- lone shambler slowly. Then it breaks: model doors come off their hinges as a loose prop; brush doors
-- (custom map func_door / func_door_rotating, which can't become props) burst into wood or metal debris.
-- Before any door goes, every func_areaportal linked to it is opened for good - a portal left closed with
-- its door gone shows the void behind it (the "areaportal bug" some door-breaking addons cause).
local WOOD = {
	hit = { "physics/wood/wood_box_impact_hard1.wav", "physics/wood/wood_box_impact_hard2.wav", "physics/wood/wood_box_impact_hard3.wav" },
	brk = { "physics/wood/wood_crate_break1.wav", "physics/wood/wood_crate_break2.wav", "physics/wood/wood_crate_break3.wav",
		"physics/wood/wood_furniture_break1.wav", "physics/wood/wood_furniture_break2.wav", "physics/wood/wood_plank_break1.wav",
		"physics/wood/wood_plank_break3.wav" },
	gibs = { "models/gibs/wood_gib01a.mdl", "models/gibs/wood_gib01b.mdl", "models/gibs/wood_gib01c.mdl",
		"models/gibs/wood_gib01d.mdl", "models/gibs/wood_gib01e.mdl" },
}
local METAL = {
	hit = { "physics/metal/metal_box_impact_hard1.wav", "physics/metal/metal_box_impact_hard2.wav", "physics/metal/metal_box_impact_hard3.wav" },
	brk = { "physics/metal/metal_box_break1.wav", "physics/metal/metal_box_break2.wav" },
	gibs = { "models/gibs/metal_gib1.mdl", "models/gibs/metal_gib2.mdl", "models/gibs/metal_gib3.mdl",
		"models/gibs/metal_gib4.mdl", "models/gibs/metal_gib5.mdl" },
}
local function kindOf(mat) return (mat == MAT_METAL or mat == MAT_GRATE or mat == MAT_VENT) and METAL or WOOD end

function HZ.OpenDoorPortals(door)
	local name = door:GetName()
	if not name or name == "" then return end
	for _, ap in ipairs(ents.FindByClass("func_areaportal")) do
		local kv = ap:GetKeyValues()
		if kv and kv.target == name then
			ap:Fire("Open")
			ap:SetKeyValue("target", "")   -- nothing may close it again
		end
	end
end

local function debris(door, kind, dir)
	local mins, maxs = door:OBBMins(), door:OBBMaxs()
	for _ = 1, math.random(5, 8) do
		local g = ents.Create("prop_physics")
		if not IsValid(g) then break end
		g:SetModel(HZ.Pick(kind.gibs))
		g:SetPos(door:LocalToWorld(Vector(math.Rand(mins.x, maxs.x), math.Rand(mins.y, maxs.y), math.Rand(mins.z, maxs.z))))
		g:SetAngles(AngleRand())
		g:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
		g:Spawn()
		local ph = g:GetPhysicsObject()
		if IsValid(ph) then
			ph:Wake()
			ph:SetVelocity(dir * math.Rand(150, 320) + VectorRand() * 90 + Vector(0, 0, math.Rand(40, 140)))
			ph:AddAngleVelocity(VectorRand() * 400)
		end
		SafeRemoveEntityDelayed(g, math.Rand(15, 25))
	end
end

function HZ.BashDoor(door, z, dir, mat)
	local kind = kindOf(mat)
	local hit = HZ.CV.door_hit:GetFloat() * (z.hz_shambler and 0.6 or 1)
	door.hz_doorHP = (door.hz_doorHP or HZ.CV.door_hp:GetFloat()) - hit
	door:EmitSound(HZ.Pick(kind.hit), 80, math.random(90, 110))
	util.ScreenShake(door:WorldSpaceCenter(), 1.5, 8, 0.3, 300)
	if door.hz_doorHP > 0 then return false end
	door.hz_doorHP = nil
	local pos = door:WorldSpaceCenter()
	HZ.OpenDoorPortals(door)
	local mdl = door:GetModel()
	if door:GetClass() == "prop_door_rotating" and mdl and util.IsValidProp(mdl) then
		local dpos, ang, skin = door:GetPos(), door:GetAngles(), door:GetSkin()
		local groups = {}
		for i = 0, door:GetNumBodyGroups() - 1 do groups[i] = door:GetBodygroup(i) end
		door:Remove()
		local p = ents.Create("prop_physics")
		if IsValid(p) then
			p:SetModel(mdl)
			p:SetPos(dpos)
			p:SetAngles(ang)
			p:SetSkin(skin)
			for i, v in pairs(groups) do p:SetBodygroup(i, v) end
			-- a broken-off door is debris: it still falls and lands, but players and zombies walk over and
			-- through it instead of tripping on it or getting it wedged in a doorway
			p:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
			p:Spawn()
			local ph = p:GetPhysicsObject()
			if IsValid(ph) then
				ph:Wake()
				ph:ApplyForceCenter((dir * 350 + Vector(0, 0, 60)) * ph:GetMass())
				ph:AddAngleVelocity(VectorRand() * 120)
			end
		end
	else
		-- brush door (or a model door without physics): it bursts apart
		debris(door, kind, dir)
		door:Remove()
	end
	sound.Play(HZ.Pick(kind.brk), pos, 85, math.random(90, 105))
	util.ScreenShake(pos, 4, 12, 0.6, 500)
	return true
end

-- a few points around an area (it and its neighbours) for clustered horde spawns
function HZ.PointsAround(area, n)
	local pool = { area }
	for _, b in ipairs(area:GetAdjacentAreas()) do pool[#pool + 1] = b end
	local out = {}
	for i = 1, n do out[i] = HZ.Pick(pool):GetRandomPoint() + Vector(0, 0, 4) end
	return out
end

---------------------------------------------------------------- commands
local function admin(ply) return not IsValid(ply) or ply:IsAdmin() end

concommand.Add("hz_clear", function(ply)
	if not admin(ply) then return end
	for z in pairs(HZ.Zombies) do if IsValid(z) then z:Remove() end end
end)

concommand.Add("hz_horde", function(ply)
	if not admin(ply) then return end
	local d = HZ.ActiveDirector
	if IsValid(d) then d:StartHorde() else print("[hordez] no active hz_director") end
end)

concommand.Add("hz_alert_all", function(ply)
	if not admin(ply) then return end
	for z in pairs(HZ.Zombies) do if IsValid(z) and not z.hz_alerted then z.hz_wakeAt = CurTime() + math.Rand(0, 1) end end
end)

concommand.Add("hz_spawn", function(ply, _, args)
	if not IsValid(ply) or not ply:IsAdmin() then return end
	local tr = ply:GetEyeTrace()
	for _ = 1, math.Clamp(tonumber(args[2]) or 1, 1, 30) do
		HZ.SpawnZombie(tr.HitPos + Vector(math.Rand(-60, 60), math.Rand(-60, 60), 8), nil, { idle = args[1] or "random" })
	end
end)

concommand.Add("hz_status", function(ply)
	if not admin(ply) then return end
	local alerted = 0
	for z in pairs(HZ.Zombies) do if z.hz_alerted then alerted = alerted + 1 end end
	print(("[hordez] zombies %d (%d alerted) / total cap %d (0 = none) | flow %s areas=%d | stress %.0f"):format(HZ.Count, alerted,
		HZ.CV.max:GetInt(), HZ.Flow.ready and "ready" or "not ready", HZ.Flow.graph and #HZ.Flow.graph.ids or 0, HZ.Stress))
end)
