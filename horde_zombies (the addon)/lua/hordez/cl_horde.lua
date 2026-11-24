-- Client: death ragdolls are clientside only (no server physics cost), capped and timed out.
local maxRags = CreateClientConVar("hz_ragdoll_max", "24", true, false, "Max zombie ragdolls kept on screen")
local ragTime = CreateClientConVar("hz_ragdoll_time", "25", true, false, "Seconds before a zombie ragdoll is removed")
CreateClientConVar("hz_show_markers", "0", true, false, "Always draw director/spawner markers (otherwise only with physgun/toolgun)")

local rags = {}

local function prune()
	local now = CurTime()
	local gone = 0
	for i = #rags, 1, -1 do
		local r = rags[i]
		if not IsValid(r.ent) then gone = gone + 1 end
		if not IsValid(r.ent) or now > r.die then
			if IsValid(r.ent) then r.ent:Remove() end
			table.remove(rags, i)
		end
	end
	-- (hz_debug 1) bodies that vanished without this code removing them: another addon wiped ragdolls
	if gone > 0 and GetConVar("hz_debug"):GetBool() then
		print(("[hordez] %d zombie bodies were removed by something else (not the timer or the cap)"):format(gone))
	end
	while #rags > maxRags:GetInt() do
		local r = table.remove(rags, 1)
		if IsValid(r.ent) then r.ent:Remove() end
	end
end
timer.Create("hordez_rags", 1, 0, prune)

local deathAnims = CreateClientConVar("hz_death_anims", "1", true, false, "Play L4D2 death animations before the ragdoll")
local deathDist = CreateClientConVar("hz_death_anim_dist", "1500", true, false, "Beyond this distance zombies ragdoll at once")
local deathMax = CreateClientConVar("hz_death_anim_max", "10", true, false, "Max death animations playing at once")

-- keep the face a zombie died with (cl_faces sets it on the nearest few) on its death anim / ragdoll
local function copyFlex(from, to)
	if not (IsValid(from) and IsValid(to)) then return end
	local n = from:GetFlexNum()
	for i = 0, n - 1 do
		local w = from:GetFlexWeight(i)
		if w > 0.01 then to:SetFlexWeight(i, w) end
	end
end

-- Ragdoll from a posed source (the dying zombie, or the death-animation model).
-- vels: optional per-bone velocities measured from the animation's last frames.
local function makeRagdoll(src, mdl, skin, groups, baseVel, push, vels)
	local rag = ClientsideRagdoll(mdl)
	if not IsValid(rag) then return end
	rag:SetNoDraw(false)          -- clientside ragdolls start hidden (bodies "vanished" on death without this)
	rag:DrawShadow(true)
	rag:SetSkin(skin)
	rag:SetColor(src:GetColor())
	copyFlex(src, rag)
	for i, v in pairs(groups) do rag:SetBodygroup(i, v) end
	rag:SetPos(src:GetPos())
	rag:SetAngles(src:GetAngles())
	src:SetupBones()
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		local bone = rag:TranslatePhysBoneToBone(i)
		local m = bone and bone >= 0 and src:GetBoneMatrix(bone)
		if IsValid(phys) then
			if m then
				phys:SetPos(m:GetTranslation())
				phys:SetAngles(m:GetAngles())
			else
				phys:SetPos(src:GetPos() + Vector(0, 0, 36))   -- no pose for this bone: at least keep it with the body
			end
			phys:SetVelocity((vels and bone and vels[bone] or baseVel) + push)
			phys:Wake()
		end
	end
	rags[#rags + 1] = { ent = rag, die = CurTime() + ragTime:GetFloat() }
	prune()
	return rag
end

---------------------------------------------------------------- death animations
-- The zombie entity is gone on the server right away; a clientside copy plays the L4D2 death sequence,
-- then turns into the ragdoll at an L4D2 hand-off frame, at the end, or the moment the pelvis hits a wall.
local dying = {}
local poolCache = {}
local DIRS = { [0] = "back", "fwd", "right", "left" }

local function resolve(mdlEnt, names)
	local ids = {}
	for _, n in ipairs(names or {}) do
		local id = mdlEnt:LookupSequence(n)
		if id and id >= 0 then ids[#ids + 1] = { id = id, name = n } end
	end
	return ids
end

local function pools(mdlEnt)
	local mdl = mdlEnt:GetModel()
	local c = poolCache[mdl]
	if c then return c end
	c = {}
	for kind, v in pairs(HZ.DeathPools) do
		if v[1] then
			c[kind] = resolve(mdlEnt, v)
		else
			c[kind] = {}
			for dir, names in pairs(v) do c[kind][dir] = resolve(mdlEnt, names) end
		end
	end
	poolCache[mdl] = c
	return c
end

local function pickDeath(c, kind, dir)
	local d = DIRS[dir] or "back"
	local function by(set) return set and set[d] end   -- no pool for this direction: fall back to standing deaths
	local cands
	if kind == HZ.DEATH_WALK then
		-- walking into it: a short stumbling death; standing forward-falls if this model lacks them
		cands = #c.walk > 0 and c.walk or c.stand.fwd
	elseif kind == HZ.DEATH_RUN then cands = c.run
	elseif kind == HZ.DEATH_HEAD then cands = c.head[d == "fwd" and "fwd" or "back"]
	elseif kind == HZ.DEATH_SHOTGUN then cands = by(c.shotgun)
	elseif kind == HZ.DEATH_CLUB then cands = by(c.club)
	elseif kind == HZ.DEATH_SLASH then cands = by(c.slash) end
	-- standing (and the fallback for anything this model lacks): side hits mostly just drop
	if not cands or #cands == 0 then
		local sd = (d == "fwd" and "fwd") or (d == "back" and math.random() < 0.6 and "back") or "drop"
		cands = c.stand[sd]
		if #cands == 0 then cands = c.stand.drop end
	end
	return HZ.Pick(cands)
end

local filterChars = function(e) return not (e:IsPlayer() or e:IsNPC() or e:IsNextBot() or e:IsRagdoll()) end
local PELVIS_MINS, PELVIS_MAXS = Vector(-5, -5, -5), Vector(5, 5, 5)

local function finishDeath(d)
	-- per-bone velocity from the last two animated frames keeps the motion going into the ragdoll
	local vels
	if d.prev and d.dt > 0 then
		vels = {}
		local m = d.csm
		for b, p in pairs(d.prev) do
			local bm = m:GetBoneMatrix(b)
			if bm then
				local v = (bm:GetTranslation() - p) / d.dt
				if v:LengthSqr() > 640000 then v = v:GetNormalized() * 800 end
				vels[b] = v
			end
		end
	end
	local rag = makeRagdoll(d.csm, d.mdl, d.skin, d.groups, vector_origin, vector_origin, vels)
	if IsValid(rag) then HZ.MoveBurn(d.csm, rag) end
	d.csm:Remove()
	return rag
end

-- L4D2 fades into its death sequences (fadein 0.2); blend each bone from the live pose to the animation
local BLEND = 0.2
local function blendBones(e, n)
	local d = e.hz_death
	local from = d and d.from
	if not from then return end
	local w = (CurTime() - d.t0) / BLEND
	if w >= 1 then
		d.from = nil
		return
	end
	w = w * w * (3 - 2 * w)
	for i = 0, n - 1 do
		local f = from[i]
		local m = f and e:GetBoneMatrix(i)
		if m then
			m:SetTranslation(LerpVector(w, f.p, m:GetTranslation()))
			m:SetAngles(LerpAngle(w, f.a, m:GetAngles()))
			e:SetBoneMatrix(i, m)
		end
	end
end

local function startDeath(ent, kind, dir, groups, vel)
	if not deathAnims:GetBool() or kind == HZ.DEATH_RAGDOLL or #dying >= deathMax:GetInt() then return false end
	if ent:GetPos():DistToSqr(EyePos()) > deathDist:GetFloat() ^ 2 then return false end
	local c = pools(ent)
	local pick = pickDeath(c, kind, dir)
	if not pick then return false end

	local csm = ClientsideModel(ent:GetModel(), RENDERGROUP_OPAQUE)
	if not IsValid(csm) then return false end
	csm:SetSkin(ent:GetSkin())
	csm:SetColor(ent:GetColor())
	copyFlex(ent, csm)
	for i, v in pairs(groups) do csm:SetBodygroup(i, v) end
	csm:SetPos(ent:GetPos())
	csm:SetAngles(Angle(0, ent:GetAngles().y, 0))
	csm:ResetSequence(pick.id)
	csm:SetCycle(0)
	csm:SetPlaybackRate(0)
	-- clientside models get no shadow unless asked; bounds cover the body as it falls (its own bounds are the
	-- standing pose), and the shadow is re-rendered every frame in stepDying since the pose keeps changing
	csm:SetRenderBounds(Vector(-80, -80, -8), Vector(80, 80, 80))
	csm:DrawShadow(true)

	-- live pose to blend from
	local from = {}
	ent:SetupBones()
	for i = 0, ent:GetBoneCount() - 1 do
		local m = ent:GetBoneMatrix(i)
		if m then from[i] = { p = m:GetTranslation(), a = m:GetAngles() } end
	end

	local dur = math.max(csm:SequenceDuration(pick.id), 0.1)
	local stop = dur
	local ends = HZ.DeathEnds[pick.name]
	if ends and math.random() < 0.75 then stop = math.min(HZ.Pick(ends) / 30, dur) end
	stop = math.min(stop, 2.5)

	dying[#dying + 1] = {
		csm = csm, mdl = ent:GetModel(), skin = ent:GetSkin(), groups = groups,
		t0 = CurTime(), dur = dur, stop = stop, dt = 0,
		seq = pick.id, lastCyc = 0, yaw = Angle(0, ent:GetAngles().y, 0),
		-- the zombie's own movement keeps going and dies off over ~0.5 s, so it steps/slides into the fall
		-- (running deaths already travel on their own, so they only get half)
		-- (a shotgun blast kills most of the charge so the knock-back reads)
		carry = Vector(vel.x, vel.y, 0) * ((kind == HZ.DEATH_SHOTGUN and 0.15)
			or ((kind == HZ.DEATH_RUN or kind == HZ.DEATH_WALK) and 0.5) or 1),
		pelvis = csm:LookupBone("ValveBiped.Bip01_Pelvis"),
		hits = 0, blast = 0, from = from,
	}
	csm.hz_death = dying[#dying]
	csm:AddCallback("BuildBonePositions", blendBones)
	csm:SetupBones()
	return true
end

-- one dying body for one frame; true = hand it to the ragdoll now
local function stepDying(d, now)
	local m = d.csm
	m:MarkShadowAsDirty()
	local t = now - d.t0
	-- body travel: the sequence's own root motion (L4D2 extracts it from every death anim, so a
	-- clientside model plays them in place unless we apply it) plus the zombie's leftover momentum
	local move = Vector(0, 0, 0)
	if d.carry then
		local v = d.carry * math.exp(-4 * t)
		if v:LengthSqr() < 4 then
			d.carry = nil
		else
			move = move + v * FrameTime()
		end
	end
	local cyc = math.min(t, d.stop) / d.dur
	if cyc > d.lastCyc then
		local ok, dm = m:GetSequenceMovement(d.seq, d.lastCyc, cyc)
		if ok and dm then
			dm.z = 0
			dm:Rotate(d.yaw)
			move = move + dm
		end
		d.lastCyc = cyc
	end
	if move:LengthSqr() > 0.0001 then
		local np = m:GetPos() + move
		-- follow the ground (slopes, stairs); none under it = slid off a ledge, the ragdoll takes the fall
		local g = util.TraceLine({ start = np + Vector(0, 0, 18), endpos = np - Vector(0, 0, 30),
			mask = MASK_NPCSOLID_BRUSHONLY })
		if g.Hit and not g.StartSolid then
			np.z = g.HitPos.z
		else
			d.offLedge = true
		end
		m:SetPos(np)
	end
	-- remember this frame's bone positions for the hand-off velocity
	local prev = {}
	for b = 0, m:GetBoneCount() - 1 do
		local bm = m:GetBoneMatrix(b)
		if bm then prev[b] = bm:GetTranslation() end
	end
	local lastPelvis = d.pelvis and prev[d.pelvis]
	if d.kicks then
		for b, k in pairs(d.kicks) do
			local f = 1 - (now - k.t0) / k.len
			if f <= 0 then
				m:ManipulateBoneAngles(b, angle_zero)
				d.kicks[b] = nil
			else
				local a = Angle()
				a:RotateAroundAxis(k.axis, k.amp * f * f)
				m:ManipulateBoneAngles(b, a)
			end
		end
	end
	m:SetCycle(math.min(t, d.stop) / d.dur)
	m:InvalidateBoneCache()
	m:SetupBones()
	local hit = false
	if lastPelvis then
		local pm = m:GetBoneMatrix(d.pelvis)
		if pm then
			local tr = util.TraceHull({ start = lastPelvis, endpos = pm:GetTranslation(), mins = PELVIS_MINS,
				maxs = PELVIS_MAXS, mask = MASK_SOLID, filter = filterChars })
			hit = tr.Hit and not tr.StartSolid
		end
	end
	d.prev, d.dt = prev, FrameTime()
	return t >= d.stop or hit or d.offLedge
end

-- Hand-off that can't leave a body behind: a Lua error anywhere in it used to leave the death model frozen
-- in its last pose with no collision (2026-11-23 report). Falls back to just removing the model.
local reported = {}
local function report(where, err)
	if reported[where] then return end
	reported[where] = true
	ErrorNoHalt("[hordez] death animation error in " .. where .. " (body handed off): " .. tostring(err) .. "\n")
end

local function safeFinish(d)
	local ok, res = pcall(finishDeath, d)
	if not ok then report("hand-off", res) end
	if IsValid(d.csm) then d.csm:Remove() end
	return ok and res or nil
end

hook.Add("Think", "hordez_dying", function()
	if #dying == 0 then return end
	local now = CurTime()
	for i = #dying, 1, -1 do
		local d = dying[i]
		if not IsValid(d.csm) then
			table.remove(dying, i)
		else
			local ok, done = pcall(stepDying, d, now)
			if not ok then report("update", done) end
			-- error, finished, or somehow still going well past its end: ragdoll it
			if not ok or done or now - d.t0 > d.stop + 2 then
				table.remove(dying, i)
				safeFinish(d)
			end
		end
	end
end)

net.Receive("hz_rag", function()
	local ent = net.ReadEntity()
	local force = net.ReadVector()
	local vel = net.ReadVector()
	local kind = net.ReadUInt(3)
	local dir = net.ReadUInt(2)
	local onFire = net.ReadBool()
	if not IsValid(ent) or ent.hz_ragdolled then return end
	ent.hz_ragdolled = true
	if ent:IsDormant() then return end

	local groups = {}
	for i = 0, ent:GetNumBodyGroups() - 1 do groups[i] = ent:GetBodygroup(i) end
	local body
	if startDeath(ent, kind, dir, groups, vel) then
		body = dying[#dying].csm
	else
		local push = force * 0.012
		if push:Length() > 600 then push = push:GetNormalized() * 600 end
		body = makeRagdoll(ent, ent:GetModel(), ent:GetSkin(), groups, vel, push)
	end
	if onFire and IsValid(body) then HZ.StartBurn(body) end
	ent:SetNoDraw(true)
	ent:DrawShadow(false)
end)

---------------------------------------------------------------- burning bodies
-- Zombies that die on fire keep burning for a while: flame sprites at a few bones, a fire loop, and the
-- body chars toward black. Client only; capped and skipped when far away.
local burnMax = CreateClientConVar("hz_burn_max", "10", true, false, "Max burning zombie bodies at once")
local burning = {}
local FLAME_BONES = { "Bip01_Pelvis", "Bip01_Spine2", "Bip01_Head1", "Bip01_L_Forearm", "Bip01_R_Forearm",
	"Bip01_L_UpperArm", "Bip01_R_UpperArm", "Bip01_L_Thigh", "Bip01_R_Thigh", "Bip01_L_Calf", "Bip01_R_Calf" }
local flameBoneCache = {}
local emitter
local BODY_BURN = 7

local function flameBones(e)
	local mdl = e:GetModel()
	local c = flameBoneCache[mdl]
	if c then return c end
	c = {}
	for _, n in ipairs(FLAME_BONES) do
		local b = e:LookupBone("ValveBiped." .. n)
		if b then c[#c + 1] = b end
	end
	flameBoneCache[mdl] = c
	return c
end

local function burnSound(b)
	if b.snd then b.snd:Stop() end
	b.snd = CreateSound(b.ent, "ambient/fire/fire_small_loop" .. math.random(1, 2) .. ".wav")
	b.snd:PlayEx(0.5, math.random(95, 105))
end

function HZ.StartBurn(ent)
	if #burning >= burnMax:GetInt() then
		local c = ent:GetColor()   -- no flames left: at least char it
		ent:SetColor(Color(c.r * 0.45, c.g * 0.42, c.b * 0.4))
		return
	end
	local now = CurTime()
	local b = { ent = ent, t0 = now, untilT = now + BODY_BURN * math.Rand(0.8, 1.2), base = ent:GetColor(), next = 0 }
	burnSound(b)
	burning[#burning + 1] = b
end

function HZ.MoveBurn(from, to)
	for _, b in ipairs(burning) do
		if b.ent == from then
			b.ent = to
			burnSound(b)
			return
		end
	end
end

hook.Add("Think", "hordez_burning", function()
	if #burning == 0 then return end
	local now = CurTime()
	local eye = EyePos()
	for i = #burning, 1, -1 do
		local b = burning[i]
		local e = b.ent
		if not IsValid(e) or now > b.untilT + 1.5 then
			if b.snd then b.snd:FadeOut(0.8) end
			table.remove(burning, i)
		else
			local f = math.Clamp((now - b.t0) / (b.untilT - b.t0), 0, 1)
			local k = 1 - 0.55 * f
			e:SetColor(Color(b.base.r * k, b.base.g * k * 0.95, b.base.b * k * 0.9))
			if now > b.untilT and b.snd then
				b.snd:FadeOut(1.2)
				b.snd = nil
			end
			if now < b.untilT and now >= b.next and e:GetPos():DistToSqr(eye) < 2500 * 2500 then
				b.next = now + 0.05
				emitter = emitter or ParticleEmitter(vector_origin)
				emitter:SetPos(e:GetPos())
				local bones = flameBones(e)
				local strength = 1 - f * 0.7
				for _ = 1, 2 do
					local m = e:GetBoneMatrix(HZ.Pick(bones) or 0)
					if m then
						local p = emitter:Add("particles/flamelet" .. math.random(1, 5), m:GetTranslation() + VectorRand() * 4)
						if p then
							p:SetVelocity(Vector(math.Rand(-8, 8), math.Rand(-8, 8), math.Rand(30, 60)))
							p:SetDieTime(math.Rand(0.35, 0.6))
							p:SetStartAlpha(230)
							p:SetEndAlpha(0)
							p:SetStartSize(math.Rand(7, 12) * strength)
							p:SetEndSize(1)
							p:SetRoll(math.Rand(0, 360))
							p:SetRollDelta(math.Rand(-2, 2))
						end
					end
				end
				if math.random() < 0.15 then
					local m = e:GetBoneMatrix(HZ.Pick(bones) or 0)
					local p = m and emitter:Add("particle/smokesprites_000" .. math.random(1, 9), m:GetTranslation())
					if p then
						p:SetVelocity(Vector(0, 0, math.Rand(25, 45)))
						p:SetDieTime(math.Rand(1.2, 2))
						p:SetStartAlpha(70)
						p:SetEndAlpha(0)
						p:SetStartSize(8)
						p:SetEndSize(26)
						p:SetColor(40, 38, 36)
						p:SetRoll(math.Rand(0, 360))
					end
				end
			end
		end
	end
end)

---------------------------------------------------------------- shooting the dying and the dead
-- The server relays shots fired near recent kills (hz_shot). Each pellet is tested against the
-- death-animation bodies (bone capsules) and the ragdolls (physics bones). A dying zombie flinches
-- (a decaying kick on the hit bone chain) and gives up and ragdolls after a few hits or a blast;
-- ragdolls get pushed. Blood + L4D2 bullet-impact sounds either way.
local CAPS = {   -- { boneA, boneB, radius, kick bones }
	{ "Bip01_Head1", "Bip01_Head1", 7, { "Bip01_Head1", "Bip01_Neck1" }, head = true },
	{ "Bip01_Neck1", "Bip01_Head1", 5, { "Bip01_Head1", "Bip01_Neck1" }, head = true },
	{ "Bip01_Spine2", "Bip01_Neck1", 9, { "Bip01_Spine2", "Bip01_Spine4" } },
	{ "Bip01_Pelvis", "Bip01_Spine2", 9, { "Bip01_Spine", "Bip01_Spine1" } },
	{ "Bip01_L_UpperArm", "Bip01_L_Forearm", 4, { "Bip01_L_UpperArm", "Bip01_L_Clavicle" } },
	{ "Bip01_L_Forearm", "Bip01_L_Hand", 3.5, { "Bip01_L_Forearm", "Bip01_L_UpperArm" } },
	{ "Bip01_R_UpperArm", "Bip01_R_Forearm", 4, { "Bip01_R_UpperArm", "Bip01_R_Clavicle" } },
	{ "Bip01_R_Forearm", "Bip01_R_Hand", 3.5, { "Bip01_R_Forearm", "Bip01_R_UpperArm" } },
	{ "Bip01_L_Thigh", "Bip01_L_Calf", 6, { "Bip01_L_Thigh", "Bip01_Pelvis" } },
	{ "Bip01_L_Calf", "Bip01_L_Foot", 4.5, { "Bip01_L_Calf", "Bip01_L_Thigh" } },
	{ "Bip01_R_Thigh", "Bip01_R_Calf", 6, { "Bip01_R_Thigh", "Bip01_Pelvis" } },
	{ "Bip01_R_Calf", "Bip01_R_Foot", 4.5, { "Bip01_R_Calf", "Bip01_R_Thigh" } },
}
local boneCache = {}
local function capBones(m)
	local mdl = m:GetModel()
	local c = boneCache[mdl]
	if c then return c end
	c = {}
	local function id(n) return m:LookupBone("ValveBiped." .. n) end
	for _, cap in ipairs(CAPS) do
		local a, b = id(cap[1]), id(cap[2])
		if a and b then
			local kick = {}
			for _, n in ipairs(cap[4]) do kick[#kick + 1] = id(n) end
			c[#c + 1] = { a = a, b = b, r = cap[3], kick = kick, head = cap.head }
		end
	end
	boneCache[mdl] = c
	return c
end

-- closest distance between segments p1-q1 (the bullet) and p2-q2 (a bone); returns dist, s (0..1 along the bullet)
local function segSeg(p1, q1, p2, q2)
	local d1, d2, r = q1 - p1, q2 - p2, p1 - p2
	local a, e, f = d1:Dot(d1), d2:Dot(d2), d2:Dot(r)
	if a < 1e-6 then return r:Length(), 0 end
	local s, t
	if e < 1e-6 then
		s = math.Clamp(-d1:Dot(r) / a, 0, 1)
		t = 0
	else
		local c, b = d1:Dot(r), d1:Dot(d2)
		local den = a * e - b * b
		s = den > 1e-6 and math.Clamp((b * f - c * e) / den, 0, 1) or 0
		t = (b * s + f) / e
		if t < 0 then
			t, s = 0, math.Clamp(-c / a, 0, 1)
		elseif t > 1 then
			t, s = 1, math.Clamp((b - c) / a, 0, 1)
		end
	end
	return ((p1 + d1 * s) - (p2 + d2 * t)):Length(), s
end

local impactSnds = {}
for _, f in ipairs(file.Find("sound/hordez/infected/gore/bullets/*.wav", "GAME")) do
	impactSnds[#impactSnds + 1] = "hordez/infected/gore/bullets/" .. f
end
local function bleed(pos, dir)
	local ed = EffectData()
	ed:SetOrigin(pos)
	ed:SetNormal(-dir)
	util.Effect("BloodImpact", ed, true, true)
	local snd = HZ.Pick(impactSnds)
	if snd then sound.Play(snd, pos, 70, math.random(95, 105), 0.6) end
end

local KICK_LEN = 0.3
local UP = Vector(0, 0, 1)
local function kickDying(d, cap, dir)
	local m = d.csm
	d.kicks = d.kicks or {}
	local axis = UP:Cross(dir)
	if axis:LengthSqr() < 0.01 then axis = m:GetRight() end
	axis:Normalize()
	for i, b in ipairs(cap.kick) do
		local bm = m:GetBoneMatrix(b)
		if bm then
			local la = WorldToLocal(axis, angle_zero, vector_origin, bm:GetAngles())
			la:Normalize()
			d.kicks[b] = { axis = la, amp = (cap.head and 26 or 18) / i, t0 = CurTime(), len = KICK_LEN }
		end
	end
end

local function pushRag(rag, pos, dir, dmg)
	local best, bd
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local ph = rag:GetPhysicsObjectNum(i)
		if IsValid(ph) then
			local dd = ph:GetPos():DistToSqr(pos)
			if not bd or dd < bd then best, bd = ph, dd end
		end
	end
	if best then best:ApplyForceOffset(dir * math.min(dmg * 60, 3000), pos) end
end

-- the hidden server corpse (removed 0.3 s after death) must not eat the bullets
local function skipDead(e) return not (e == LocalPlayer() or e.hz_ragdolled) end

local function onPellet(src, dir, dmg, pellets)
	local tr = util.TraceLine({ start = src, endpos = src + dir * 8192, mask = MASK_SHOT, filter = skipDead })
	local stop = tr.HitPos
	local len = (stop - src):Length()
	-- nearest body along the bullet
	local hitS, hitD, hitCap, hitRag
	for _, d in ipairs(dying) do
		local m = d.csm
		local c = IsValid(m) and m:GetPos() + Vector(0, 0, 36)
		if c and segSeg(src, stop, c, c) < 90 then
			for _, cap in ipairs(capBones(m)) do
				local ma, mb = m:GetBoneMatrix(cap.a), m:GetBoneMatrix(cap.b)
				if ma and mb then
					local pa, pb = ma:GetTranslation(), mb:GetTranslation()
					if cap.a == cap.b then   -- head sphere: a little up the skull from the bone origin
						pa = pa + ma:GetForward() * 3
						pb = pa
					end
					local dist, s = segSeg(src, stop, pa, pb)
					if dist < cap.r and (not hitS or s < hitS) then hitS, hitD, hitCap, hitRag = s, d, cap, nil end
				end
			end
		end
	end
	for _, r in ipairs(rags) do
		local rag = r.ent
		local c = IsValid(rag) and rag:GetPos()
		if c and segSeg(src, stop, c, c) < 90 then
			for i = 0, rag:GetPhysicsObjectCount() - 1 do
				local ph = rag:GetPhysicsObjectNum(i)
				if IsValid(ph) then
					local p = ph:GetPos()
					local dist, s = segSeg(src, stop, p, p)
					if dist < 9 and (not hitS or s < hitS) then hitS, hitD, hitCap, hitRag = s, nil, nil, rag end
				end
			end
		end
	end
	if not hitS then return end
	local hitPos = src + dir * (len * hitS)
	bleed(hitPos, dir)
	if hitRag then
		pushRag(hitRag, hitPos, dir, dmg)
		return
	end
	local d = hitD
	local now = CurTime()
	d.hits = d.hits + 1
	d.blast = (d.blastAt == now) and (d.blast + 1) or 1
	d.blastAt = now
	if d.hits >= 4 or d.blast >= 3 or (pellets == 1 and dmg >= 60) then
		-- keep shooting and the body gives up the animation and drops
		for i, o in ipairs(dying) do
			if o == d then table.remove(dying, i) break end
		end
		local rag = safeFinish(d)
		if IsValid(rag) then pushRag(rag, hitPos, dir, dmg * math.min(d.blast, 4)) end
	else
		kickDying(d, hitCap, dir)
	end
end

net.Receive("hz_shot", function()
	local src = net.ReadVector()
	local dir = net.ReadNormal()
	local num = net.ReadUInt(5)
	local spread = net.ReadFloat()
	local dmg = net.ReadUInt(10)
	if #dying == 0 and #rags == 0 then return end
	if src:DistToSqr(EyePos()) > 4000 * 4000 then return end
	local ang = dir:Angle()
	local right, up = ang:Right(), ang:Up()
	for _ = 1, num do
		local pd = dir
		if spread > 0 then
			pd = (dir + right * (math.Rand(-1, 1) * spread) + up * (math.Rand(-1, 1) * spread)):GetNormalized()
		end
		onPellet(src, pd, dmg, num)
	end
end)

hook.Add("PostCleanupMap", "hordez_rags", function()
	for _, d in ipairs(dying) do if IsValid(d.csm) then d.csm:Remove() end end
	dying = {}
	for _, r in ipairs(rags) do if IsValid(r.ent) then r.ent:Remove() end end
	rags = {}
	for _, b in ipairs(burning) do if b.snd then b.snd:Stop() end end
	burning = {}
end)

net.Receive("hz_cue", function()
	surface.PlaySound(net.ReadString())
end)

function HZ.MarkersVisible()
	if GetConVar("hz_show_markers"):GetBool() then return true end
	local w = LocalPlayer():GetActiveWeapon()
	if not IsValid(w) then return false end
	local c = w:GetClass()
	return c == "weapon_physgun" or c == "gmod_tool"
end
