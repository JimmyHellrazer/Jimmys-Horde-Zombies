-- Client: death ragdolls are clientside only (no server physics cost), capped and timed out.
local maxRags = CreateClientConVar("hz_ragdoll_max", "24", true, false, "Max zombie ragdolls kept on screen")
local ragTime = CreateClientConVar("hz_ragdoll_time", "25", true, false, "Seconds before a zombie ragdoll is removed")
CreateClientConVar("hz_show_markers", "0", true, false, "Always draw director/spawner markers (otherwise only with physgun/toolgun)")

local rags = {}

local M = HZ.Math
local CopyBoneSafe, CopyBone, MatrixPos = M.CopyBoneSafe, M.CopyBone, M.MatrixPos
local sqrt = math.sqrt
local cvDebug = GetConVar("hz_debug")
-- scratch matrices: every bone read below copies into one of these instead of making a new VMatrix
local boneMat, boneMatB = Matrix(), Matrix()

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
	if gone > 0 and cvDebug:GetBool() then
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

-- model -> { bone id of each ragdoll physics object } (index = physics object + 1), learned from the first
-- ragdoll of that model. The death animation then only tracks these bones for its hand-off velocities.
local physBones = {}

-- Ragdoll from a posed source (the dying zombie, or the death-animation model).
-- vels: optional per-bone velocities measured from the animation's last frames.
local function makeRagdoll(src, mdl, skin, groups, baseVel, push, vels)
	local rag = ClientsideRagdoll(mdl)
	if not IsValid(rag) then return end
	local pb = physBones[mdl]
	if not pb then
		pb = {}
		for i = 0, rag:GetPhysicsObjectCount() - 1 do pb[i + 1] = rag:TranslatePhysBoneToBone(i) or -1 end
		physBones[mdl] = pb
	end
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
		local bone = pb[i + 1]
		local m = CopyBoneSafe(src, bone, boneMat)
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
	if d.hasPrev and d.dt > 0 then
		vels = {}
		local m, bones, px, py, pz, inv = d.csm, d.bones, d.px, d.py, d.pz, 1 / d.dt
		for i = 1, #bones do
			local x0 = px[i]
			if x0 and CopyBoneSafe(m, bones[i], boneMat) then
				local x, y, z = MatrixPos(boneMat)
				local vx, vy, vz = (x - x0) * inv, (y - py[i]) * inv, (z - pz[i]) * inv
				local l2 = vx * vx + vy * vy + vz * vz
				if l2 > 640000 then
					local k = 800 / sqrt(l2)
					vx, vy, vz = vx * k, vy * k, vz * k
				end
				vels[bones[i]] = Vector(vx, vy, vz)
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
	-- from: seven numbers per bone (position + rotation quaternion of the live pose). Each bone is copied
	-- into the scratch matrix, blended there (lerp + slerp on plain numbers) and written back.
	local blend, setBone = M.BlendFrom, e.SetBoneMatrix
	for i = 0, n - 1 do
		local o = i * 7
		local px = from[o + 1]
		if px and CopyBone(e, i, boneMat) then
			blend(boneMat, px, from[o + 2], from[o + 3], from[o + 4], from[o + 5], from[o + 6], from[o + 7], w)
			setBone(e, i, boneMat)
		end
	end
end

-- which bones a death animation remembers each frame (for the ragdoll hand-off velocities and the pelvis
-- wall check): the ragdoll's physics bones once a ragdoll of this model has been made, every bone until then
local trackCache = {}
local function trackedBones(csm, mdl)
	local c = trackCache[mdl]
	if c then return c.bones, c.pelvis end
	local pelvis = csm:LookupBone("ValveBiped.Bip01_Pelvis")
	local pb = physBones[mdl]
	local bones, seen, at = {}, {}, nil
	if pb then
		for i = 1, #pb do
			local b = pb[i]
			if b >= 0 and not seen[b] then
				seen[b] = true
				bones[#bones + 1] = b
			end
		end
		if pelvis and not seen[pelvis] then bones[#bones + 1] = pelvis end
	else
		for b = 0, csm:GetBoneCount() - 1 do bones[#bones + 1] = b end
	end
	for i = 1, #bones do if bones[i] == pelvis then at = i break end end
	if pb then trackCache[mdl] = { bones = bones, pelvis = at } end
	return bones, at
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
	local posQuat = M.MatrixPosQuat
	for i = 0, ent:GetBoneCount() - 1 do
		local o = i * 7
		from[o + 1] = false
		if CopyBoneSafe(ent, i, boneMat) then
			local px, py, pz, qx, qy, qz, qw = posQuat(boneMat)
			if px then
				from[o + 1], from[o + 2], from[o + 3], from[o + 4], from[o + 5], from[o + 6], from[o + 7] = px, py, pz, qx, qy, qz, qw
			end
		end
	end

	local dur = math.max(csm:SequenceDuration(pick.id), 0.1)
	local stop = dur
	local ends = HZ.DeathEnds[pick.name]
	if ends and math.random() < 0.75 then stop = math.min(HZ.Pick(ends) / 30, dur) end
	stop = math.min(stop, 2.5)

	local mdl = ent:GetModel()
	local bones, pelvisAt = trackedBones(csm, mdl)
	dying[#dying + 1] = {
		csm = csm, mdl = mdl, skin = ent:GetSkin(), groups = groups,
		t0 = CurTime(), dur = dur, stop = stop, dt = 0,
		seq = pick.id, lastCyc = 0, yaw = Angle(0, ent:GetAngles().y, 0),
		-- the zombie's own movement keeps going and dies off over ~0.5 s, so it steps/slides into the fall
		-- (running deaths already travel on their own, so they only get half)
		-- (a shotgun blast kills most of the charge so the knock-back reads)
		carry = Vector(vel.x, vel.y, 0) * ((kind == HZ.DEATH_SHOTGUN and 0.15)
			or ((kind == HZ.DEATH_RUN or kind == HZ.DEATH_WALK) and 0.5) or 1),
		bones = bones, pelvisAt = pelvisAt, px = {}, py = {}, pz = {},
		hits = 0, blast = 0, from = from,
	}
	csm.hz_death = dying[#dying]
	csm:AddCallback("BuildBonePositions", blendBones)
	csm:SetupBones()
	return true
end

local UP18, DOWN30 = Vector(0, 0, 18), Vector(0, 0, 30)
local groundTr, pelvisTr = {}, {}
local groundIn = { mask = MASK_NPCSOLID_BRUSHONLY, output = groundTr }
local pelvisIn = { start = Vector(), endpos = Vector(), mins = PELVIS_MINS, maxs = PELVIS_MAXS, mask = MASK_SOLID,
	filter = filterChars, output = pelvisTr }
local kickAng = Angle()

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
		groundIn.start, groundIn.endpos = np + UP18, np - DOWN30
		util.TraceLine(groundIn)
		local g = groundTr
		if g.Hit and not g.StartSolid then
			np.z = g.HitPos.z
		else
			d.offLedge = true
		end
		m:SetPos(np)
	end
	-- remember this frame's bone positions for the hand-off velocity
	local bones, px, py, pz = d.bones, d.px, d.py, d.pz
	for i = 1, #bones do
		if CopyBoneSafe(m, bones[i], boneMat) then
			px[i], py[i], pz[i] = MatrixPos(boneMat)
		else
			px[i] = false
		end
	end
	local pelvisAt = d.pelvisAt
	local lastPelvis = pelvisAt and px[pelvisAt]
	if d.kicks then
		for b, k in pairs(d.kicks) do
			local f = 1 - (now - k.t0) / k.len
			if f <= 0 then
				m:ManipulateBoneAngles(b, angle_zero)
				d.kicks[b] = nil
			else
				kickAng:Zero()
				kickAng:RotateAroundAxis(k.axis, k.amp * f * f)
				m:ManipulateBoneAngles(b, kickAng)
			end
		end
	end
	m:SetCycle(math.min(t, d.stop) / d.dur)
	m:InvalidateBoneCache()
	m:SetupBones()
	local hit = false
	if lastPelvis and CopyBone(m, bones[pelvisAt], boneMat) then
		pelvisIn.start:SetUnpacked(lastPelvis, py[pelvisAt], pz[pelvisAt])
		pelvisIn.endpos:SetUnpacked(MatrixPos(boneMat))
		util.TraceHull(pelvisIn)
		hit = pelvisTr.Hit and not pelvisTr.StartSolid
	end
	d.hasPrev, d.dt = true, FrameTime()
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
HZ.PrecacheSound("ambient/fire/fire_small_loop1.wav")
HZ.PrecacheSound("ambient/fire/fire_small_loop2.wav")

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
			b.ent, b.step = to, nil
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
			local step = math.floor(k * 255)   -- (only when it would actually change an 8-bit colour)
			if step ~= b.step then
				b.step = step
				e:SetColor(Color(b.base.r * k, b.base.g * k * 0.95, b.base.b * k * 0.9))
			end
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
					local m = CopyBoneSafe(e, HZ.Pick(bones) or 0, boneMat)
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
					local m = CopyBoneSafe(e, HZ.Pick(bones) or 0, boneMat)
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

-- The bullet tests below run for every pellet against every body, so they work on plain numbers.
-- The bullet is the segment A + D * s (s in 0..1), a = D . D.
-- squared distance from point P to the bullet; returns distSqr, s
local function segPoint(ax, ay, az, dx, dy, dz, a, px, py, pz)
	local rx, ry, rz = px - ax, py - ay, pz - az
	local s = 0
	if a >= 1e-6 then
		s = (rx * dx + ry * dy + rz * dz) / a
		s = s < 0 and 0 or (s > 1 and 1 or s)
	end
	local ex, ey, ez = rx - dx * s, ry - dy * s, rz - dz * s
	return ex * ex + ey * ey + ez * ez, s
end

-- squared closest distance between the bullet and the segment P-Q (a bone); returns distSqr, s
local function segSeg(ax, ay, az, dx, dy, dz, a, px, py, pz, qx, qy, qz)
	local ex, ey, ez = qx - px, qy - py, qz - pz
	local e = ex * ex + ey * ey + ez * ez
	if a < 1e-6 or e < 1e-6 then return segPoint(ax, ay, az, dx, dy, dz, a, px, py, pz) end
	local rx, ry, rz = ax - px, ay - py, az - pz
	local f = ex * rx + ey * ry + ez * rz
	local c, b = dx * rx + dy * ry + dz * rz, dx * ex + dy * ey + dz * ez
	local den = a * e - b * b
	local s = 0
	if den > 1e-6 then
		s = (b * f - c * e) / den
		s = s < 0 and 0 or (s > 1 and 1 or s)
	end
	local t = (b * s + f) / e
	if t < 0 then
		t, s = 0, -c / a
		s = s < 0 and 0 or (s > 1 and 1 or s)
	elseif t > 1 then
		t, s = 1, (b - c) / a
		s = s < 0 and 0 or (s > 1 and 1 or s)
	end
	local x, y, z = rx + dx * s - ex * t, ry + dy * s - ey * t, rz + dz * s - ez * t
	return x * x + y * y + z * z, s
end

local impactSnds = {}
for _, f in ipairs(file.Find("sound/hordez/infected/gore/bullets/*.wav", "GAME")) do
	impactSnds[#impactSnds + 1] = "hordez/infected/gore/bullets/" .. f
end
HZ.PrecacheSounds(impactSnds)
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
	local ax, ay, az = axis.x, axis.y, axis.z
	for i, b in ipairs(cap.kick) do
		if CopyBoneSafe(m, b, boneMat) then
			-- the axis in the bone's own space: the transpose of its rotation applied to the world axis
			local m11, m12, m13, _, m21, m22, m23, _, m31, m32, m33 = boneMat:Unpack()
			local la = Vector(m11 * ax + m21 * ay + m31 * az, m12 * ax + m22 * ay + m32 * az, m13 * ax + m23 * ay + m33 * az)
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

-- Bone positions are read once per shot (hz_shot message), not once per pellet: a body keeps the capsule
-- end points / physics bone positions it had when the first pellet of that shot was tested.
local shotId = 0

-- capsule end points of a dying body: six numbers per capsule (false in the first when a bone is missing)
local function capPoints(d, caps)
	local pts = d.capPts
	if pts and d.capShot == shotId then return pts end
	if not pts then pts = {} d.capPts = pts end
	d.capShot = shotId
	local m = d.csm
	for i = 1, #caps do
		local cap = caps[i]
		local o = i * 6 - 6
		pts[o + 1] = false
		if CopyBoneSafe(m, cap.a, boneMat) then
			local fx, _, _, x, fy, _, _, y, fz, _, _, z = boneMat:Unpack()
			if cap.a == cap.b then   -- head sphere: a little up the skull from the bone origin
				x, y, z = x + fx * 3, y + fy * 3, z + fz * 3
				pts[o + 1], pts[o + 2], pts[o + 3], pts[o + 4], pts[o + 5], pts[o + 6] = x, y, z, x, y, z
			elseif CopyBoneSafe(m, cap.b, boneMatB) then
				pts[o + 1], pts[o + 2], pts[o + 3] = x, y, z
				pts[o + 4], pts[o + 5], pts[o + 6] = MatrixPos(boneMatB)
			end
		end
	end
	return pts
end

-- physics bone positions of a ragdoll: three numbers each; returns the array and how many bones
local function ragPoints(r, rag)
	local pts = r.pts
	if pts and r.shot == shotId then return pts, r.npts end
	if not pts then pts = {} r.pts = pts end
	local n = rag:GetPhysicsObjectCount()
	r.shot, r.npts = shotId, n
	for i = 0, n - 1 do
		local ph = rag:GetPhysicsObjectNum(i)
		local o = i * 3
		if IsValid(ph) then
			local p = ph:GetPos()
			pts[o + 1], pts[o + 2], pts[o + 3] = p.x, p.y, p.z
		else
			pts[o + 1] = false
		end
	end
	return pts, n
end

local pelletTr = {}
local pelletIn = { mask = MASK_SHOT, filter = skipDead, output = pelletTr }

local function onPellet(src, dir, dmg, pellets)
	pelletIn.start, pelletIn.endpos = src, src + dir * 8192
	util.TraceLine(pelletIn)
	local stop = pelletTr.HitPos
	local ax, ay, az = src.x, src.y, src.z
	local dx, dy, dz = stop.x - ax, stop.y - ay, stop.z - az
	local a = dx * dx + dy * dy + dz * dz
	local len = sqrt(a)
	-- nearest body along the bullet
	local hitS, hitD, hitCap, hitRag
	for _, d in ipairs(dying) do
		local m = d.csm
		if IsValid(m) then
			local c = m:GetPos()
			if segPoint(ax, ay, az, dx, dy, dz, a, c.x, c.y, c.z + 36) < 8100 then
				local caps = capBones(m)
				local pts = capPoints(d, caps)
				for i = 1, #caps do
					local o = i * 6 - 6
					local px = pts[o + 1]
					if px then
						local cap = caps[i]
						local dist, s = segSeg(ax, ay, az, dx, dy, dz, a, px, pts[o + 2], pts[o + 3], pts[o + 4], pts[o + 5], pts[o + 6])
						if dist < cap.r * cap.r and (not hitS or s < hitS) then hitS, hitD, hitCap, hitRag = s, d, cap, nil end
					end
				end
			end
		end
	end
	for _, r in ipairs(rags) do
		local rag = r.ent
		if IsValid(rag) then
			local c = rag:GetPos()
			if segPoint(ax, ay, az, dx, dy, dz, a, c.x, c.y, c.z) < 8100 then
				local pts, n = ragPoints(r, rag)
				for o = 0, n * 3 - 3, 3 do
					local px = pts[o + 1]
					if px then
						local dist, s = segPoint(ax, ay, az, dx, dy, dz, a, px, pts[o + 2], pts[o + 3])
						if dist < 81 and (not hitS or s < hitS) then hitS, hitD, hitCap, hitRag = s, nil, nil, rag end
					end
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
	shotId = shotId + 1
	if spread <= 0 then
		for _ = 1, num do onPellet(src, dir, dmg, num) end
		return
	end
	-- spread basis straight from the direction (right = dir x up, up = right x dir): no Angle round trip
	local fx, fy, fz = dir.x, dir.y, dir.z
	local rx, ry = fy, -fx
	local rl = sqrt(rx * rx + ry * ry)
	if rl < 1e-4 then rx, ry = 0, -1 else rx, ry = rx / rl, ry / rl end   -- (straight up / down)
	local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
	local pd = Vector()
	for _ = 1, num do
		local a, b = math.Rand(-1, 1) * spread, math.Rand(-1, 1) * spread
		pd:SetUnpacked(fx + rx * a + ux * b, fy + ry * a + uy * b, fz + uz * b)
		pd:Normalize()
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

local cvMarkers = GetConVar("hz_show_markers")
function HZ.MarkersVisible()
	if cvMarkers:GetBool() then return true end
	local w = LocalPlayer():GetActiveWeapon()
	if not IsValid(w) then return false end
	local c = w:GetClass()
	return c == "weapon_physgun" or c == "gmod_tool"
end
