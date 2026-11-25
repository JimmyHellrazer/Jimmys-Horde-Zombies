AddCSLuaFile()

-- Lightweight L4D-style common infected. Cheap by design:
--  * no per-zombie pathfinding: chasers read the shared flow field (sv_flow.lua)
--  * the "brain" (target pick, route, separation) runs 6-8x/s near players, 2-3x/s far away,
--    idle zombies sense 1x/s and dormant ones every 2-3 s; only Approach/FaceTowards run every update
--  * no zombie-vs-zombie collision (NPC_SCRIPTED); spacing comes from a spatial-hash separation push
--  * ragdolls are clientside only
ENT.Base = "base_nextbot"
ENT.Type = "nextbot"
ENT.PrintName = "Infected"
ENT.Category = "Horde Zombies"
ENT.Spawnable = false

list.Set("NPC", "hz_zombie", { Name = "Infected", Class = "hz_zombie", Category = "Horde Zombies", IconOverride = "entities/hz_zombie.png" })

if CLIENT then
	-- faces and footsteps pick from this list instead of searching every entity
	function ENT:Initialize()
		HZ.ClientRegister(self)
	end

	-- once dead the client draws the death animation / ragdoll instead. Client-side SetNoDraw alone is not
	-- enough: the next network update restores the server's draw flags and the live zombie flashes back.
	function ENT:Draw()
		-- hz_far: beyond hz_draw_dist (cl_util); hz_imp: drawn as an impostor quad instead (cl_impostor)
		if self.hz_ragdolled or self.hz_far or self.hz_imp then return end
		self:DrawModel()
	end
	return
end

local CV = HZ.CV
local vector_up = Vector(0, 0, 1)
local util_TraceHull, util_TraceLine = util.TraceHull, util.TraceLine

-- Other infected never block climbs, vaults or scripted motion (they pass through each other anyway).
-- A class list is matched inside the engine. The filter functions this replaces were called back into Lua
-- for every infected a sweep touched - which, in a packed horde, is most of the crowd, on every trace.
local NO_ZOMBIES = { "hz_zombie" }

-- The traces the brain runs several times a second for every chasing zombie reuse one input and one result
-- table (nothing allocated per trace but the two end points). The result is only good until the next
-- hullTrace / lineTrace, so read it at once; traces whose result is kept or returned still make their own.
local UP20 = Vector(0, 0, 20)
local trRes = {}
local trIn = { output = trRes }
local pairFilter = {}
local function hullTrace(a, b, mins, maxs, mask, filter)
	trIn.start, trIn.endpos, trIn.mins, trIn.maxs, trIn.mask, trIn.filter = a, b, mins, maxs, mask, filter
	util_TraceHull(trIn)
	return trRes
end
local function lineTrace(a, b, mask, filter)
	trIn.start, trIn.endpos, trIn.mins, trIn.maxs, trIn.mask, trIn.filter = a, b, nil, nil, mask, filter
	util_TraceLine(trIn)
	return trRes
end
local function pair(a, b)
	pairFilter[1], pairFilter[2] = a, b
	return pairFilter
end
local CLEAR_MINS, CLEAR_MAXS = Vector(-8, -8, 0), Vector(8, 8, 24)
local FLANK_MINS, FLANK_MAXS = Vector(-10, -10, 0), Vector(10, 10, 40)
local AHEAD_MINS, AHEAD_MAXS = Vector(-10, -10, 0), Vector(10, 10, 8)

local IDLE_WEIGHTS = { { "stand", 30 }, { "wander", 30 }, { "sit", 10 }, { "lie", 10 }, { "lean", 10 }, { "crouch", 10 } }
local function randomIdle()
	local total = 0
	for _, w in ipairs(IDLE_WEIGHTS) do total = total + w[2] end
	local r = math.random() * total
	for _, w in ipairs(IDLE_WEIGHTS) do
		r = r - w[2]
		if r <= 0 then return w[1] end
	end
	return "stand"
end

---------------------------------------------------------------- setup
function ENT:Initialize()
	self:SetModel(self.hz_model or HZ.RandomModel())
	self.hz_female = self:GetModel():find("female", 1, true) ~= nil
	local skins = self:SkinCount()
	if skins and skins > 1 then self:SetSkin(math.random(0, skins - 1)) end
	HZ.RandomBodygroups(self)

	local hp = self.hz_shambler and CV.sh_health:GetInt() or CV.health:GetInt()
	self:SetHealth(hp)
	self:SetMaxHealth(hp)
	self:SetCollisionBounds(Vector(-12, -12, 0), Vector(12, 12, 70))
	self:SetCollisionGroup(COLLISION_GROUP_NPC_SCRIPTED)  -- zombies pass through each other, not players/props
	-- HL2 NPC senses only look at players, real NPCs and FL_OBJECT entities; without this flag they never
	-- notice a NextBot at all, whatever their relationship to it says
	self:AddFlags(FL_OBJECT)

	local loco = self.loco
	loco:SetStepHeight(18)
	loco:SetJumpHeight(64)
	loco:SetDeathDropHeight(2000)
	loco:SetAcceleration(1100)
	loco:SetDeceleration(1600)
	loco:SetMaxYawRate(400)

	self.P = self.hz_shambler and HZ.ResolveShamblerPools(self) or HZ.ResolvePools(self)
	self.hz_runSeq = HZ.Pick(self.P.run)
	self.hz_walkSeq = HZ.Pick(self.P.walk)
	local var = math.Clamp(CV.speed_var:GetFloat(), 0, 0.9)
	self.hz_speedMul = math.Rand(1 - var, 1 + var)
	if self.hz_shambler then
		self.hz_shamSpeed = math.Rand(CV.sh_speed_lo:GetFloat(), math.max(CV.sh_speed_lo:GetFloat(), CV.sh_speed_hi:GetFloat()))
		self:SetNW2Bool("hz_shambler", true)
	end
	self.hz_nextBrain = 0
	-- sideways slot when chasing (-1..1, spread evenly-ish across a crowd by being random)
	self.hz_flankSlot = math.Rand(-1, 1)
	if not self.hz_idleType or self.hz_idleType == "random" then self.hz_idleType = randomIdle() end
	HZ.Register(self)
	-- placed straight from the spawn menu / by another addon (not through HZ.SpawnZombie): make sure it isn't
	-- inside a prop or wall, next tick once its position is final
	if not self.hz_placed then
		timer.Simple(0, function()
			if IsValid(self) and not self.hz_dead then
				self:SetPos(HZ.FreeSpot(self:GetPos()))
				self.hz_ownMove = engine.TickCount()
			end
		end)
	end
end

function ENT:OnRemove()
	HZ.Unregister(self)
	local owner = self.hz_owner
	if not self.hz_dead and not self.hz_virtualized and IsValid(owner) and owner.HZ_OnZombieDied then owner:HZ_OnZombieDied(self) end
end

---------------------------------------------------------------- animation helpers
function ENT:HZ_Loops(seq)
	local L = self.P.loops
	if not L then L = {} self.P.loops = L end
	local v = L[seq]
	if v == nil then
		local info = self:GetSequenceInfo(seq)
		v = info and bit.band(info.flags or 0, 1) ~= 0 or false
		L[seq] = v
	end
	return v
end

-- looping base pose (idles, attacks)
function ENT:HZ_SetSeq(seq, rate)
	if not seq then return end
	if isstring(seq) then   -- (the settle-down loops are passed by name)
		seq = self:LookupSequence(seq)
		if not seq or seq < 0 then return end
	end
	if self:GetSequence() ~= seq then
		self:ResetSequence(seq)
		self:SetCycle(0)
	end
	self:SetPlaybackRate(rate or 1)
	self.hz_moveAnim = nil
	self.hz_wantLoop = true
	self.hz_wrap = not self:HZ_Loops(seq)
end

-- locomotion: run/walk sequence, playback rate follows actual speed in BodyUpdate
function ENT:HZ_SetMove(kind)
	local seq
	if kind == "run" then
		if (self.hz_burnDie or self:IsOnFire()) and not self.hz_shambler then
			self.hz_fireSeq = self.hz_fireSeq or HZ.Pick(self.P.run_fire)
			seq = self.hz_fireSeq or self.hz_runSeq
		else
			seq = self.hz_runSeq
		end
	else
		seq = self.hz_walkSeq
	end
	if not seq then return end
	if self:GetSequence() ~= seq or not self.hz_moveAnim then
		self:ResetSequence(seq)
		self:SetPoseParameter("move_x", 1)
		self:SetPoseParameter("move_y", 0)
		local gs = self:GetSequenceGroundSpeed(seq)
		if not gs or gs < 10 then gs = (self.hz_shambler and kind == "run" and HZ.SHAMBLE_GS) or (kind == "run" and 220 or 40) end
		self.hz_moveGS = gs
		self.hz_wrap = not self:HZ_Loops(seq)
	end
	self.hz_moveAnim = true
	self.hz_wantLoop = true
	local runSpeed = self.hz_shambler and self.hz_shamSpeed or CV.runspeed:GetFloat() * self.hz_speedMul
	self.loco:SetDesiredSpeed(kind == "run" and runSpeed or self.hz_moveGS)
end

-- one-shot sequence; blocks the behaviour coroutine until done.
-- motion: apply the sequence's extracted root motion (climbs, shoves); zscale stretches its height;
-- hull: refuse motion steps that would go into solids; face: keep turning toward this position
-- stopOnWall (with hull): end early and return "wall" when the motion runs into a wall
function ENT:HZ_PlayOnce(seq, rate, motion, zscale, face, hull, stopOnWall)
	if not seq then return end
	self.hz_inOnce = true
	local res = self:HZ_PlayOnceInner(seq, rate, motion, zscale, face, hull, stopOnWall)
	self.hz_inOnce = nil
	self.hz_ownMove = engine.TickCount()
	return res
end

local HULL_MINS, HULL_MAXS = Vector(-12, -12, 0), Vector(12, 12, 64)
function ENT:HZ_PlayOnceInner(seq, rate, motion, zscale, face, hull, stopOnWall)
	-- other infected never block scripted motion: a row staggered by one melee arc used to catch on itself
	-- (each one hit the zombie behind it, stopped or played a wall bounce)
	local blk = NO_ZOMBIES
	rate = rate or 1
	self:ResetSequence(seq)
	self:SetCycle(0)
	self:SetPlaybackRate(rate)
	self.hz_moveAnim = nil
	self.hz_wantLoop = nil
	local dur = math.max(self:SequenceDuration(seq) / rate, 0.05)
	local t0 = CurTime()
	local last = 0
	local yaw = Angle(0, self:GetAngles().y, 0)
	while true do
		if self.hz_dead then return end
		if HZ.AIDisabled() then   -- frozen mid one-shot: wait, then resume where it was
			local p = CurTime()
			self.hz_frozen = true
			while HZ.AIDisabled() and not self.hz_dead do
				self.loco:SetVelocity(vector_origin)
				coroutine.yield()
			end
			self.hz_frozen = nil
			t0 = t0 + (CurTime() - p)
		end
		-- a shove landed mid one-shot (not a climb, not a stagger already): stop and let the stagger play now
		if self.hz_shove and not self.hz_inShove and not self.hz_climbing then return end
		local f = math.min((CurTime() - t0) / dur, 1)
		if motion and f > last then
			local ok, d = self:GetSequenceMovement(seq, last, f)
			if ok and d then
				d.z = d.z * (zscale or 1)
				d:Rotate(yaw)
				local from = self:GetPos()
				local to = from + d
				if hull then
					local tr = util.TraceHull({ start = from + Vector(0, 0, 4), endpos = to + Vector(0, 0, 4),
						mins = HULL_MINS, maxs = HULL_MAXS, mask = MASK_NPCSOLID, filter = blk })
					if not tr.Hit then
						self:SetPos(to)
					else
						-- a step or curb: go up it instead of calling it a wall
						local up = util.TraceHull({ start = from + Vector(0, 0, 20), endpos = to + Vector(0, 0, 20),
							mins = HULL_MINS, maxs = HULL_MAXS, mask = MASK_NPCSOLID, filter = blk })
						if not up.Hit then
							self:SetPos(to + Vector(0, 0, 16))
						elseif stopOnWall and math.abs(tr.HitNormal.z) < 0.5 then
							self.loco:SetVelocity(vector_origin)
							return "wall", tr
						end
					end
				else
					self:SetPos(to)
				end
			end
			self.loco:SetVelocity(vector_origin)
			last = f
		end
		if face then self.loco:FaceTowards(face) end
		if f >= 1 then break end
		coroutine.yield()
	end
end

-- Pushes from outside (SWEPs that shove by setting the zombie's velocity or by moving it directly):
-- our own code only ever zeroes the locomotion velocity, so a sudden speed-up, or a position jump the
-- current speed can't explain, came from someone else. Becomes a stagger in that direction.
local LOCO_ACCEL = 1100
function ENT:HZ_WatchPush(vel)
	local now = CurTime()
	local pos = self:GetPos()
	vel = vel or self.loco:GetVelocity()
	local vz = vel.z
	vel.z = 0
	local lp, lv, lt = self.hz_wpPos, self.hz_wpVel, self.hz_wpT
	-- launch guard: nothing we do lifts a zombie fast except climbing, yet now and then one shot into the
	-- sky on waking (2026-11-23, cause unknown - most likely the locomotor resolving an overlap upward).
	-- Put it back and stop it; hz_debug prints what it was doing so the cause can be found.
	local ownMove = self.hz_ownMove and engine.TickCount() - self.hz_ownMove < 4   -- our own warps/landings
	if lp and not ownMove and not self.hz_climbing and not self.hz_dead and (pos.z - lp.z > 40 or vz > 350) then
		if HZ.CV.debug:GetBool() then
			print(("[hordez] launch caught on %s: rose %.0f u, vz %.0f | pose %s, seq %s, inOnce %s, shove %s, alerted %s, onGround %s"):format(
				tostring(self), pos.z - lp.z, vz, tostring(self.hz_pose), self:GetSequenceName(self:GetSequence()),
				tostring(self.hz_inOnce), tostring(self.hz_inShove), tostring(self.hz_alerted), tostring(self.loco:IsOnGround())))
		end
		self:SetPos(lp)
		self.loco:SetVelocity(vector_origin)
		self.loco:ClearStuck()
		self.hz_ownMove = engine.TickCount()
		self.hz_wpT = now
		return
	end
	self.hz_wpPos, self.hz_wpVel, self.hz_wpT = pos, vel, now
	if not lp or ownMove or self.hz_inOnce or self.hz_climbing or self.hz_shove or self.hz_dead then return end
	local dt = now - lt
	if dt <= 0 or dt > 0.3 then return end
	local dv = vel - lv
	if vel:Length() > 180 and dv:Dot(vel) > 0 and dv:Length() > LOCO_ACCEL * dt + 200 then
		return self:HZ_ExternalPush(dv)
	end
	local moved = pos - lp
	moved.z = 0
	if moved:Length() > math.max(lv:Length(), vel:Length()) * dt + 24 then
		return self:HZ_ExternalPush(moved)
	end
end

function ENT:HZ_ExternalPush(push, fromArc)
	if self.hz_inShove or self.hz_climbing or self.hz_dead then return end
	self.hz_shove = true
	self.hz_shovePush = push
	-- a shove that came as a plain push (no damage): sweep the rest of the row in front of the shover
	if not fromArc and not HZ.ArcBusy then
		local ply = HZ.ShoverOf(self)
		if ply then HZ.MeleeArc(ply, self) end
	end
	if HZ.CV.debug:GetBool() then print(("[hordez] external push on %s: %.0f u"):format(tostring(self), push:Length())) end
end

-- Burning (L4D2 style): any fire damage sets the zombie alight; it runs with the on-fire animation,
-- chars darker as it burns and dies when hz_burn_time runs out (credited to whoever lit it).
-- Deep water puts it out.
local CHAR = 0.7
function ENT:HZ_Ignite(att)
	if self.hz_dead then return end
	if self:WaterLevel() >= 2 then return end
	local t = CV.burn_time:GetFloat() * math.Rand(0.85, 1.15)
	if not self:IsOnFire() then self:Ignite(t + 2) end
	if self.hz_burnDie then return end
	self.hz_burnStart, self.hz_burnDie, self.hz_burner = CurTime(), CurTime() + t, att
	self.hz_speedMul = self.hz_speedMul * 1.15
	self.hz_nextBrain = 0
	-- L4D2: a burning common forgets you and panics off the way it was facing until it drops (HZ_BurnRun)
	self.hz_alerted, self.hz_wakeAt = true, nil
	self.hz_attacking, self.hz_target, self.hz_goal = nil, nil, nil
	self.hz_pose = "stand"
	local f = self:GetForward()
	self.hz_burnDir = Vector(f.x, f.y, 0):GetNormalized()
	self.hz_burnTurnAt = 0
	HZ.Voice(self, "ignite", 80, true)
	self.hz_burnVoiced = true
end

local BURN_MINS, BURN_MAXS = Vector(-12, -12, 18), Vector(12, 12, 64)
function ENT:HZ_BurnRun(now)
	local pos = self:GetPos()
	local dir = self.hz_burnDir or self:GetForward()
	-- weave a little, and swerve off anything right in front
	if now >= self.hz_burnTurnAt then
		self.hz_burnTurnAt = now + math.Rand(0.4, 0.8)
		dir:Rotate(Angle(0, math.Rand(-18, 18), 0))
	end
	local tr = hullTrace(pos, pos + dir * 70, BURN_MINS, BURN_MAXS, MASK_NPCSOLID, NO_ZOMBIES)
	if tr.Hit then
		local side = math.random() < 0.5 and 1 or -1
		local n = tr.HitNormal
		local turned = Vector(-n.y * side, n.x * side, 0)   -- along the wall
		dir = (turned:LengthSqr() > 0.01 and turned or -dir):GetNormalized()
		self.hz_burnTurnAt = now + 0.5
	end
	self.hz_burnDir = dir
	-- every tick: a zombie already running when it caught fire must swap to the on-fire run
	-- (HZ_SetMove only restarts the sequence when it changes)
	self:HZ_SetMove("run")
	if self.loco:IsOnGround() then
		local goal = pos + dir * 200
		self.loco:Approach(goal, 1)
		self.loco:FaceTowards(goal)
	end
end

function ENT:HZ_BurnTick()
	if not self.hz_burnDie or self.hz_dead then return end
	local now = CurTime()
	if self:WaterLevel() >= 2 then
		self:Extinguish()
		self.hz_burnDie, self.hz_fireSeq = nil, nil
		self.hz_nextBrain = 0
		return
	end
	if now >= (self.hz_nextChar or 0) then
		self.hz_nextChar = now + 0.25
		local f = math.Clamp((now - self.hz_burnStart) / (self.hz_burnDie - self.hz_burnStart), 0, 1)
		local c = 255 * (1 - CHAR * f)
		self:SetColor(Color(c, c * 0.93, c * 0.86))
	end
	if now >= self.hz_burnDie then
		self.hz_burnDie = nil
		local att = IsValid(self.hz_burner) and self.hz_burner or game.GetWorld()
		local d = DamageInfo()
		d:SetDamage(self:Health() + 10)
		d:SetDamageType(DMG_BURN)
		d:SetAttacker(att)
		d:SetInflictor(att)
		d:SetDamagePosition(self:WorldSpaceCenter())
		self:TakeDamageInfo(d)
	end
end

function ENT:BodyUpdate()
	if self.hz_frozen then return end   -- ai_disabled: hold the current frame like stock NPCs
	self:HZ_BurnTick()
	-- the push watch samples about 16 times a second, not every update: it compares against its last sample
	-- with the real time between them, so it sees the same shoves at a fraction of the cost
	local moving = self.hz_moveAnim
	local watch = CurTime() - (self.hz_wpT or 0) >= 0.06
	local vel = (watch or moving) and self.loco:GetVelocity()
	if watch then self:HZ_WatchPush(vel) end
	if self.hz_nwAlert ~= self.hz_alerted then   -- (faces: only chasing zombies make rage faces)
		self.hz_nwAlert = self.hz_alerted
		self:SetNW2Bool("hz_alerted", self.hz_alerted == true)
	end
	if moving then
		local rate = math.Clamp(vel:Length2D() / (self.hz_moveGS or 200), 0.25, self.hz_shambler and HZ.SHAMBLE_MAX_RATE or 2)
		-- the rate is networked: only touch it when it really moved, not for every tick's speed jitter
		if math.abs(rate - self:GetPlaybackRate()) > 0.02 then self:SetPlaybackRate(rate) end
	end
	self:FrameAdvance()
	-- (hz_wrap: the current sequence doesn't loop by itself; set where the sequence is chosen, so the usual
	-- case - a looping run or idle - costs nothing here)
	if self.hz_wrap and self.hz_wantLoop and self:GetCycle() >= 0.995 then
		self:SetCycle(0)
	end
end

---------------------------------------------------------------- behaviour loop
function ENT:RunBehaviour()
	self:HZ_EnterIdle()
	while true do
		if HZ.AIDisabled() and not self.hz_dead then
			self.hz_frozen = true
			self.loco:SetVelocity(vector_origin)
		elseif not self.hz_dead then
			self.hz_frozen = nil
			local now = CurTime()
			if self.hz_shove then
				self.hz_shove = nil
				self:HZ_Shoved()
			elseif self.hz_burnDie then
				self:HZ_BurnRun(now)
			elseif not self.hz_alerted then
				if self.hz_wakeAt and now >= self.hz_wakeAt then
					self:HZ_Wake()
				else
					self:HZ_Idle(now)
				end
			else
				self:HZ_Chase(now)
			end
		end
		coroutine.yield()
	end
end

---------------------------------------------------------------- idle
function ENT:HZ_FindLeanSpot()
	local base = self:GetPos()
	local eye = base + Vector(0, 0, 40)
	local best
	for i = 0, 7 do
		local dir = Angle(0, i * 45, 0):Forward()
		local tr = util.TraceLine({ start = eye, endpos = eye + dir * 56, mask = MASK_SOLID_BRUSHONLY })
		if tr.Hit and not tr.StartSolid and math.abs(tr.HitNormal.z) < 0.3 and (not best or tr.Fraction < best.Fraction) then
			best = tr
		end
	end
	if not best then return false end
	local n = Vector(best.HitNormal.x, best.HitNormal.y, 0)
	n:Normalize()
	local p = best.HitPos + n * 11
	p.z = base.z
	self:SetPos(p)
	self.hz_ownMove = engine.TickCount()
	self:SetAngles(Angle(0, n:Angle().y, 0))   -- back to the wall
	return true
end

-- Root-motion player for L4D2 sequences that turn and move the body (walkframe LX LY LZR): applies the
-- extracted translation (hull-checked, other infected ignored) AND rotation, which HZ_PlayOnce doesn't.
-- opts: rate, abort = function() -> true to stop, want = stop once the body has turned this far (deg, signed),
-- maxTime, ground = follow the floor and stop at walls and drops (walking anims), look = keep scanning for
-- targets while it plays (idle anims), free = no collision checks and keep the vertical motion, scaled by
-- zscale, with xyscale on the horizontal (vaults). Returns the fraction played. Must run inside the
-- behaviour coroutine.
local function yawAt(self, seq, f)
	if f <= 0 then return 0 end
	local ok, _, a = self:GetSequenceMovement(seq, 0, f)
	return (ok and a) and a.y or 0
end
local yawAng = Angle()   -- scratch for SetAngles (yaw only)
local rad, cos, sin = math.rad, math.cos, math.sin

function ENT:HZ_RootPlay(seq, opts)
	opts = opts or {}
	local rate = opts.rate or 1
	self:ResetSequence(seq)
	self:SetCycle(0)
	self:SetPlaybackRate(rate)
	self.hz_moveAnim, self.hz_wantLoop = nil, nil
	self.loco:SetVelocity(vector_origin)
	local dur = math.max(self:SequenceDuration(seq) / rate, 0.05)
	local base = self:GetAngles().y
	local t0, last = CurTime(), 0
	local want = opts.want
	local blk = NO_ZOMBIES
	local nextLook = 0
	local lastYaw = 0   -- the sequence's own turn at `last` (what yawAt(self, seq, last) would return)
	self.hz_inOnce = true
	while true do
		if opts.look and CurTime() >= nextLook and not self.hz_alerted and not self.hz_wakeAt then
			nextLook = CurTime() + 1
			self:HZ_Look(self:GetPos())
		end
		if self.hz_dead or HZ.AIDisabled() or (opts.abort and opts.abort()) then break end
		if self.hz_shove and not self.hz_climbing then break end   -- shoved mid-turn / stroll: stagger now
		local f = math.min((CurTime() - t0) / dur, 1)
		if f > last then
			local ok, d = self:GetSequenceMovement(seq, last, f)
			if ok and d then
				if opts.free then
					d.x, d.y, d.z = d.x * (opts.xyscale or 1), d.y * (opts.xyscale or 1), d.z * (opts.zscale or 1)
				else
					d.z = 0
				end
				-- turn the step by the body's yaw at the start of it (plain yaw rotation, no Angle made)
				local a = rad(base + lastYaw)
				local c, s = cos(a), sin(a)
				d.x, d.y = d.x * c - d.y * s, d.x * s + d.y * c
				local from = self:GetPos()
				local to = from + d
				-- (vaults move freely: no collision check at all)
				local tr = not opts.free and util.TraceHull({ start = from + Vector(0, 0, opts.ground and 18 or 4),
					endpos = to + Vector(0, 0, opts.ground and 18 or 4),
					mins = HULL_MINS, maxs = HULL_MAXS, mask = MASK_NPCSOLID, filter = blk })
				if opts.free then
					self:SetPos(to)
				elseif opts.ground then
					local gr = not tr.Hit and util.TraceLine({ start = to + Vector(0, 0, 18), endpos = to - Vector(0, 0, 30),
						mask = MASK_NPCSOLID_BRUSHONLY })
					if not gr or not gr.Hit or gr.StartSolid then break end   -- wall or drop ahead: stop here
					to.z = gr.HitPos.z
					self:SetPos(to)
				elseif not tr.Hit then
					self:SetPos(to)
				end
			end
			local y = yawAt(self, seq, f)
			yawAng.y = base + y
			self:SetAngles(yawAng)
			self.loco:SetVelocity(vector_origin)
			last, lastYaw = f, y
			if want and ((want > 0 and y >= want - 10) or (want < 0 and y <= want + 10)) then break end
		end
		if f >= 1 or (opts.maxTime and CurTime() - t0 > opts.maxTime) then break end
		coroutine.yield()
	end
	self.hz_inOnce = nil
	self.hz_ownMove = engine.TickCount()
	return last
end

-- signed yaw from our facing to pos
function ENT:HZ_YawTo(pos)
	local to = pos - self:GetPos()
	to.z = 0
	if to:LengthSqr() < 1 then return 0 end
	return math.NormalizeAngle(to:Angle().y - self:GetAngles().y)
end

-- how far each turning sequence rotates the body: over the whole sequence (idle turns), or the biggest turn
-- inside its first `upto` (directional alerts, which turn early and then idle for 15 s). Cached per model.
local turnCache = {}
function ENT:HZ_TurnInfo(names, upto)
	local key = self:GetModel() .. "|" .. table.concat(names, ",")
	local c = turnCache[key]
	if c then return c end
	c = {}
	for _, n in ipairs(names) do
		local seq = self:LookupSequence(n)
		if seq and seq >= 0 then
			local yaw
			if upto then
				yaw = 0
				for k = 1, 10 do
					local y = yawAt(self, seq, upto * k / 10)
					if math.abs(y) > math.abs(yaw) then yaw = y end
				end
			else
				yaw = yawAt(self, seq, 1)
			end
			if math.abs(yaw) > 20 then c[#c + 1] = { seq = seq, yaw = yaw } end
		end
	end
	turnCache[key] = c
	return c
end

local function closestTurn(list, want, sameSign)
	local best, be
	for _, t in ipairs(list) do
		if not sameSign or (t.yaw > 0) == (want > 0) then
			local e = math.abs(math.NormalizeAngle(want - t.yaw))
			if not be or e < be then best, be = t, e end
		end
	end
	return best, be
end

-- L4D2's idle turns (Turn_Left / Right / Around_01a-c): turn on the spot to face pos before walking there.
-- Only when it's more than 45 deg off; FaceTowards finishes the rest while walking. Gives up the moment the
-- zombie is woken, shoved or killed.
local TURN_SEQS = { "Idle_Neutral_Turn_Left", "Idle_Neutral_Turn_Right", "Idle_Neutral_Turn_Around_01a",
	"Idle_Neutral_Turn_Around_01b", "Idle_Neutral_Turn_Around_01c" }
function ENT:HZ_IdleTurn(pos)
	local want = self:HZ_YawTo(pos)
	if math.abs(want) < 45 then return end
	local best, be = closestTurn(self:HZ_TurnInfo(TURN_SEQS), want)
	if not best or be > 70 then return end
	self:HZ_RootPlay(best.seq, { look = true,
		abort = function() return self.hz_alerted or self.hz_wakeAt or self.hz_inShove end })
end

-- Waking toward something to the side or behind: L4D2's directional alerts (Idle_Alert_Left / Right / Behind)
-- swing the body round toward it; cut as soon as it faces the threat. Returns true if it turned.
local ALERT_TURNS = { "Idle_Alert_Left_01", "Idle_Alert_Left_04", "Idle_Alert_Right_02a", "Idle_Alert_Right_02d",
	"Idle_Alert_Behind_02", "Idle_Alert_Behind_03" }
function ENT:HZ_AlertTurn(pos)
	local want = self:HZ_YawTo(pos)
	if math.abs(want) < 60 then return false end
	local best = closestTurn(self:HZ_TurnInfo(ALERT_TURNS, 0.35), want, true)
	if not best then return false end
	self:HZ_RootPlay(best.seq, { rate = 1.4, want = want, maxTime = 2.2,
		abort = function() return self.hz_inShove end })
	return true
end

function ENT:HZ_EnterIdle()
	local now = CurTime()
	if self.hz_startAlerted then
		self.hz_alerted = true
		self.hz_pose = "stand"
		self.hz_lastHasTarget = now
		HZ.Voice(self, "rage", 80)
		return
	end
	local t = self.hz_idleType
	if t == "lean" and not self:HZ_FindLeanSpot() then t = "stand" end
	self.hz_pose = t
	local pool = self.P[t]
	if t == "wander" or not pool or #pool == 0 then pool = self.P.stand end
	self:HZ_SetSeq(HZ.Pick(pool))
	if t == "sit" or t == "lie" or t == "lean" then self:SetCycle(math.random()) end
	self.hz_nextIdleSwap = now + math.Rand(6, 16)
	self.hz_nextWander = now + math.Rand(1, 8)
	self.hz_nextBrain = now + math.Rand(0, 1)
end

-- Calm idle strolls (L4D2 commons drifting about): a few slow steps in some direction, a long stand, now and then
-- just a look round. Legs are short and checked clear, so an idle zombie never wanders off or gets itself
-- stuck. Runners play L4D2's Walk_Neutral drifts with their own root motion (they amble ~12-18 u/s with
-- pauses and gentle curves - driving them with the locomotor at a fixed speed just walked them in place);
-- shamblers' shuffle is an in-place loop, so they still use the locomotor.
function ENT:HZ_StrollGoal(pos, maxLeg)
	local blk = NO_ZOMBIES
	for _ = 1, 4 do
		local dir = Angle(0, math.Rand(0, 360), 0):Forward()
		local want = pos + dir * math.Rand(40, maxLeg)
		local a = navmesh.GetNearestNavArea(want, false, 120, false, true)
		if a and IsValid(a) then
			local goal = a:GetClosestPointOnArea(want)
			if goal and math.abs(goal.z - pos.z) < 24 and goal:DistToSqr(pos) > 32 * 32 then
				local tr = util.TraceHull({ start = pos + Vector(0, 0, 18), endpos = goal + Vector(0, 0, 18),
					mins = Vector(-13, -13, 0), maxs = Vector(13, 13, 48), mask = MASK_NPCSOLID, filter = blk })
				if not tr.Hit then return goal end
			end
		end
	end
end

function ENT:HZ_StartStroll(now, pos, maxLeg)
	local goal = self:HZ_StrollGoal(pos, maxLeg)
	if not goal then return false end
	self:HZ_IdleTurn(goal)   -- turn toward it first (L4D2 idle turn) instead of swivelling while walking
	if self.hz_alerted or self.hz_wakeAt or self.hz_dead then return true end
	local leg = goal:Distance(pos)
	local name = not self.hz_shambler and HZ.Pick(self.P.stroll)
	local seq = name and self:LookupSequence(name) or -1
	if seq >= 0 then
		local start = self:GetPos()
		self:HZ_RootPlay(seq, { ground = true, look = true, maxTime = 3 + leg / 10,
			abort = function()
				return self.hz_alerted or self.hz_wakeAt or self.hz_inShove or self:GetPos():DistToSqr(start) >= leg * leg
			end })
		if self.hz_alerted or self.hz_wakeAt or self.hz_dead then return true end
		self:HZ_SetSeq(HZ.Pick(self.P.stand))
		self.hz_nextIdleSwap = CurTime() + math.Rand(6, 16)
		return true
	end
	self.hz_wanderGoal = goal
	self.hz_wanderGiveUp = CurTime() + 4 + leg / 15
	self:HZ_SetMove("walk")
	return true
end

function ENT:HZ_Idle(now)
	if now >= self.hz_nextBrain then self:HZ_IdleBrain(now) end
	local goal = self.hz_wanderGoal
	if goal then
		if self:GetPos():DistToSqr(goal) < 24 * 24 or now > self.hz_wanderGiveUp then
			self.hz_wanderGoal = nil
			self:HZ_SetSeq(HZ.Pick(self.P.stand))
			self.hz_nextIdleSwap = now + math.Rand(6, 16)
			self.hz_nextWander = now + math.Rand(6, 20)
		else
			self.loco:Approach(goal, 1)
			self.loco:FaceTowards(goal)
		end
	end
end

function ENT:HZ_IdleBrain(now)
	local pos = self:GetPos()
	local pd = HZ.NearestPlayerDist(pos)
	local dormant = pd > CV.dormant:GetFloat()
	self.hz_nextBrain = now + (dormant and math.Rand(2, 3) or math.Rand(0.8, 1.2))
	HZ.GridMove(self, pos)
	if dormant then return end

	self:HZ_Look(pos)
	if self.hz_wakeAt then return end

	local pose = self.hz_pose
	if pose == "wander" and not self.hz_wanderGoal and self.hz_settleAt and now > self.hz_settleAt then
		self:HZ_TrySettle(now, pos)
		pose = self.hz_pose
	end
	-- wanderers stroll every 6-20 s; standers now and then shift a few steps too, so a still crowd isn't frozen
	local strolls = (pose == "wander" or (pose == "stand" and math.random() < 0.08)) and not self.hz_wanderGoal
	if strolls and now > (self.hz_nextWander or 0) then
		self.hz_nextWander = now + math.Rand(6, 20)
		if math.random() < 0.25 then
			-- just a look round
			self:HZ_IdleTurn(pos + Angle(0, math.Rand(0, 360), 0):Forward() * 100)
			if self.hz_alerted or self.hz_wakeAt or self.hz_dead then return end
			self:HZ_SetSeq(HZ.Pick(self.P.stand))
		elseif self:HZ_StartStroll(now, pos, pose == "wander" and 200 or 90) then
			return
		end
	elseif (pose == "stand" or pose == "wander" or pose == "crouch") and not self.hz_wanderGoal
		and (now > self.hz_nextIdleSwap or self:GetCycle() > 0.97) then
		self:HZ_SetSeq(HZ.Pick(pose == "crouch" and self.P.crouch or self.P.stand))
		self.hz_nextIdleSwap = now + math.Rand(6, 16)
	end

	if pd < 1400 and math.random() < 0.1 then HZ.Voice(self, "idle", 65) end
end

function ENT:HZ_Look(pos)
	local sight = CV.sight:GetFloat()
	local pose = self.hz_pose
	if pose == "lie" or pose == "sit" then sight = sight * 0.7 end
	local fwd = self:GetForward()
	local eye = pos + Vector(0, 0, pose == "lie" and 16 or 60)
	for _, t in ipairs(HZ.GetTargets()) do
		local e = t.ent
		if IsValid(e) then
			local to = t.pos - pos
			local d = to:Length()
			local range = sight
			if t.ply then
				if e:Crouching() then range = range * 0.5 end
				if e:FlashlightIsOn() then range = range * 1.4 end
			end
			if d < 110 then
				self:HZ_QueueWake(0.1, e)
				return
			elseif d < range and (d < 300 or fwd:Dot(to / d) > 0.3) then
				if not lineTrace(eye, e:EyePos(), MASK_OPAQUE, pair(self, e)).Hit then
					self:HZ_QueueWake(math.Rand(0.2, 0.6) + d / sight * 0.6, e)
					return
				end
			end
		end
	end
end

function ENT:HZ_QueueWake(delay, src)
	if self.hz_alerted or self.hz_wakeAt then return end
	self.hz_wakeAt = CurTime() + delay
	self.hz_wakeSrc = src
end

-- called by HZ.Noise / HZ.Spread
function ENT:HZ_Hear(pos, d, src)
	if self.hz_alerted or self.hz_wakeAt then return end
	self.hz_noisePos = pos
	self:HZ_QueueWake(math.Rand(0.15, 0.5) + d / 2200, src)
end

function ENT:HZ_Wake()
	self.hz_wakeAt = nil
	self.hz_alerted = true
	self.hz_wanderGoal = nil
	self.hz_lastHasTarget = CurTime()
	HZ.Spread(self)

	local src = self.hz_wakeSrc
	local look = IsValid(src) and src:GetPos() or self.hz_noisePos
	local pose = self.hz_pose
	local pool
	if pose == "sit" then pool = self.P.sit_wake
	elseif pose == "lie" then pool = self.P.lie_wake
	elseif self.hz_wakeStartled then pool = self.P.startled
	else pool = self.P.wake end
	self.hz_pose = "stand"
	self.hz_wakeStartled = nil
	HZ.Voice(self, math.random() < 0.5 and "becomealert" or "alert", 80)
	-- settled with a transition: get up the matching way (Sitting03 / Lying03 have their own stand-ups)
	local up = self.hz_upSeq
	self.hz_upSeq = nil
	if up and (pose == "sit" or pose == "lie") then pool = { up } end
	local face = (pose ~= "sit" and pose ~= "lie") and look or nil
	-- threat off to the side or behind: swing round with a directional alert instead of swivelling
	if face and pool ~= self.P.startled and self:HZ_AlertTurn(face) then
		self.hz_nextBrain = 0
		return
	end
	self:HZ_PlayOnce(HZ.Pick(pool), math.Rand(1.15, 1.45), false, nil, face)
	self.hz_nextBrain = 0
end

function ENT:HZ_Calm()
	self.hz_alerted = false
	self.hz_target, self.hz_goal, self.hz_attacking, self.hz_unreach = nil, nil, nil, nil
	self.hz_pose = "wander"
	self:HZ_SetSeq(HZ.Pick(self.P.stand))
	self.hz_nextWander = CurTime() + math.Rand(2, 6)
	self.hz_nextIdleSwap = CurTime() + math.Rand(6, 16)
	-- after a while of milling about it settles back into a random idle (may sit, lie, lean, crouch again)
	self.hz_settleAt = CurTime() + math.Rand(15, 45)
end

-- Settle a calmed wanderer into a fresh random idle. Sitting and lying down are animated (L4D2's
-- Standing_to_Sitting03 / Standing_to_Lying03, then the matching Sitting03 / Lying03 loop and stand-up), so
-- they happen in plain view; leaning and crouching have no transition and wait until nobody's looking.
local SETTLE = { sit = { "sit_down", "Sitting03", "Sitting03_to_Standing" },
	lie = { "lie_down", "Lying03", "Lying03_to_Standing" } }
function ENT:HZ_TrySettle(now, pos)
	local t = self.hz_settlePick or randomIdle()
	local tr = SETTLE[t]
	local down = tr and HZ.Pick(self.P[tr[1]])
	if down and self:LookupSequence(tr[2]) >= 0 then
		self.hz_settleAt, self.hz_settlePick = nil, nil
		local f = self:HZ_RootPlay(self:LookupSequence(down),
			{ abort = function() return self.hz_alerted or self.hz_wakeAt or self.hz_inShove end })
		if f < 0.5 then   -- interrupted early: still on its feet
			self.hz_pose = "stand"
			self:HZ_SetSeq(HZ.Pick(self.P.stand))
			return
		end
		self.hz_idleType, self.hz_pose = t, t
		self.hz_upSeq = tr[3]
		self:HZ_SetSeq(tr[2])
		self.hz_nextIdleSwap = now + math.Rand(6, 16)
		return
	end
	if (t == "lean" or t == "crouch") and HZ.SeenByPlayers(pos, 500) then
		self.hz_settlePick = t
		self.hz_settleAt = now + math.Rand(3, 6)
		return
	end
	self.hz_settleAt, self.hz_settlePick = nil, nil
	if t == "lean" and not self:HZ_FindLeanSpot() then t = "stand" end
	self.hz_idleType = t
	self.hz_pose = t
	local pool = self.P[t]
	if t == "wander" or not pool or #pool == 0 then pool = self.P.stand end
	self:HZ_SetSeq(HZ.Pick(pool))
	if t == "sit" or t == "lie" or t == "lean" then self:SetCycle(math.random()) end
	self.hz_nextIdleSwap = now + math.Rand(6, 16)
	self.hz_nextWander = now + math.Rand(3, 10)
end

---------------------------------------------------------------- chase
function ENT:HZ_NearestTarget(pos)
	local best, bd = nil, 1200 * 1200
	for _, t in ipairs(HZ.GetTargets()) do
		if IsValid(t.ent) and math.abs(t.pos.z - pos.z) < 200 then
			local d = t.pos:DistToSqr(pos)
			if d < bd then best, bd = t.ent, d end
		end
	end
	return best, math.sqrt(bd)
end

function ENT:HZ_Clear(pos, tgt)
	return not hullTrace(pos + UP20, tgt:GetPos() + UP20, CLEAR_MINS, CLEAR_MAXS, MASK_NPCSOLID_BRUSHONLY, pair(self, tgt)).Hit
end

function ENT:HZ_Chase(now)
	if now >= self.hz_nextBrain then self:HZ_Brain(now) end
	if self.hz_dead or not self.hz_alerted then return end
	if self.hz_attacking then
		self:HZ_AttackStep(now, self.hz_target)
		return
	end
	if self.hz_hitAt and now >= self.hz_hitAt then
		self.hz_hitAt = nil
		self:HZ_TryHit(self.hz_target, 80)
	end
	local goal = self.hz_goal
	if not goal then return end
	if not self.loco:IsOnGround() then
		self.hz_airSince = self.hz_airSince or now
		if not self.hz_falling and now - self.hz_airSince > 0.35 then
			self.hz_falling = true
			self:HZ_SetSeq(HZ.Pick(self.P.fall))
		end
		return
	end
	local air = self.hz_airSince and now - self.hz_airSince or 0
	self.hz_airSince = nil
	if self.hz_falling then
		self.hz_falling = nil
		-- L4D2 landing: a stumble-and-go, or a hard landing after a long drop
		local seq = HZ.Pick(air > 0.9 and self.P.land_hard or self.P.land)
		if seq then
			self:HZ_PlayOnce(seq, self.hz_shambler and 0.9 or 1.15, true, 1, goal, true)
			if self.hz_dead then return end
		end
		self:HZ_SetMove("run")
	end
	self.loco:Approach(goal, 1)
	self.loco:FaceTowards(goal)
	self:HZ_StuckCheck(now)
end

function ENT:HZ_Brain(now)
	local pos = self:GetPos()
	self.hz_atWall = nil
	HZ.GridMove(self, pos)
	local pd = HZ.NearestPlayerDist(pos)
	local think = (pd < CV.hot_dist:GetFloat() and math.Rand(0.12, 0.18) or math.Rand(0.35, 0.5))
		* (self.hz_shambler and 2 or 1)   -- nothing a shambler does is fast
	-- a big horde: only the ones right on top of a player keep the full rate, the rest think less often the
	-- more of them there are (their legs keep running toward the last goal in between)
	if pd > 350 then
		local load = HZ.Count / math.max(CV.think_full:GetFloat(), 1)
		if load > 1 then think = think * math.min(load, 4) end
	end
	self.hz_nextBrain = now + think
	if self.hz_attacking then return end
	if self:HZ_LureStep(now, pos) then return end

	-- target: whoever the flow field leads to; the closest one when near; whoever hurt us lately
	local area = HZ.Flow.AreaOf(self)
	local nxt, fdist, ftgt
	if area then nxt, fdist, ftgt = HZ.Flow.Step(area:GetID()) end
	self.hz_flowDist = fdist
	local tgt = (ftgt and HZ.IsHostile(ftgt)) and ftgt or nil
	local near, nd = self:HZ_NearestTarget(pos)
	if near and (not tgt or nd < 300) then tgt = near end
	local ag = self.hz_aggro
	if ag and now < (self.hz_aggroUntil or 0) and HZ.IsHostile(ag) and ag:GetPos():DistToSqr(pos) < 600 * 600 then tgt = ag end

	if not tgt then
		self.hz_target, self.hz_goal = nil, nil
		if not self.hz_lost then
			self.hz_lost = true
			-- lost them mid-sprint: skid to a stop (L4D2 Running_to_Standing) rather than snapping to idle
			local stop = HZ.Pick(self.P.run_stop)
			if stop and not self.hz_shambler and self.loco:IsOnGround() and self.loco:GetVelocity():Length2D() > 150 then
				self:HZ_PlayOnce(stop, 1.1, true, 1, nil, true, true)
				if self.hz_dead or not self.hz_alerted then return end
			end
			self:HZ_SetSeq(HZ.Pick(self.P.alert_idle))
		end
		if now - (self.hz_lastHasTarget or now) > 25 then self:HZ_Calm() end
		return
	end
	self.hz_lost = nil
	self.hz_lastHasTarget = now
	self.hz_target = tgt

	local tpos = tgt:GetPos()
	local tdist = pos:Distance(tpos)
	local dz = math.abs(tpos.z - pos.z)
	if tdist < 52 and dz < 48 then
		self:HZ_StartAttack(tgt)
		return
	end

	-- target up on something the navmesh doesn't cover (container top, low roof): go to the nearest spot
	-- below one of its edges and climb up there
	if tpos.z - pos.z > 40 and tdist < 900 and not HZ.Flow.OnMesh(tgt) then
		local spot = self:HZ_ClimbSpot(tgt)
		if spot then
			local climbed, run = self:HZ_WallClimb(spot.pos, spot.top)
			if climbed then return end
			if (spot.pos - pos):Length2DSqr() < 40 * 40 then
				self.hz_spotFails = (self.hz_spotFails or 0) + 1
				if self.hz_spotFails > 6 then self.hz_badSpot, self.hz_spot = spot, nil end
			end
			self.hz_unreach = nil
			self.hz_goal = run
			if not self.hz_falling then self:HZ_SetMove("run") end
			return
		end
	end

	-- route: flow field area-to-area, straight at the target when it is close and the way is clear
	local goal
	local direct = tdist < 420 and dz < 56 and self:HZ_Clear(pos, tgt)
	-- the route goes up a wall here: walk to its foot, then climb
	local link = nxt and area and not direct and HZ.Flow.ClimbLink(area:GetID(), nxt)
	if link and self.hz_shambler and (link.h or (link.top.z - link.foot.z)) > CV.sh_climb:GetFloat() then
		link, nxt = nil, nil   -- too high to shamble up: no way through here
	end
	if link then
		local climbed, run = self:HZ_WallClimb(link.foot, link.top, link.vault)
		if climbed then return end
		goal = run
	elseif nxt == false or direct then
		goal = tpos
	elseif nxt then
		local na = HZ.Flow.Area(nxt)
		if na and IsValid(na) then
			goal = na:GetClosestPointOnArea(pos)
			local c = na:GetCenter()
			local dir = c - goal
			local l = dir:Length()
			if l > 1 then goal = goal + dir * (math.min(20, l) / l) end
			-- nearly there: aim for the area after it (from further out when this zombie thinks less often,
			-- so it doesn't reach its goal and stand waiting for the next thought)
			local n2 = HZ.Flow.nxt[nxt]
			local reach = math.Clamp(think * 240, 48, 150)
			if n2 and pos:DistToSqr(goal) < reach * reach then
				local a2 = HZ.Flow.Area(n2)
				if a2 and IsValid(a2) then goal = a2:GetClosestPointOnArea(goal) end
			end
		end
	elseif self:HZ_Clear(pos, tgt) then
		goal = tpos
	end

	if not goal then
		self.hz_goal = nil
		if not self.hz_unreach then
			self.hz_unreach = true
			self:HZ_SetSeq(HZ.Pick(self.P.unreach))
		end
		self.loco:FaceTowards(tpos)
		return
	end
	self.hz_unreach = nil

	-- fan out: each zombie keeps its own sideways slot relative to the target, wide while far, closing to
	-- nothing as it arrives. Runners just come in a little spread so a dodge either way meets one; shamblers
	-- spread wide and hold it until close, a slow wall closing in. Only where there's room for it.
	if not self.hz_atWall and not link then
		local w, near, ramp
		if self.hz_shambler then w, near, ramp = CV.spread_sh:GetFloat(), 70, 260
		else w, near, ramp = CV.spread_run:GetFloat(), 110, 420 end
		local lat = self.hz_flankSlot * w * math.Clamp((tdist - near) / ramp, 0, 1)
		if math.abs(lat) > 4 then
			local to = Vector(tpos.x - pos.x, tpos.y - pos.y, 0)
			to:Normalize()
			local g2 = goal + Vector(-to.y, to.x, 0) * lat
			if not hullTrace(pos + UP20, g2 + UP20, FLANK_MINS, FLANK_MAXS, MASK_NPCSOLID_BRUSHONLY).Hit then goal = g2 end
		end
	end

	local sep = not self.hz_atWall and HZ.Separation(self, pos)
	if sep then goal = goal + sep end
	if self.hz_sideUntil and now < self.hz_sideUntil then goal = goal + self.hz_sideOff end
	self.hz_goal = goal
	if not self.hz_falling then self:HZ_SetMove("run") end
	-- running into low cover: vault it in stride instead of bumping to a stop first
	if tdist > 70 and CV.climb:GetBool() and self.loco:GetVelocity():Length2DSqr() > 60 * 60 then
		local from = pos + UP20
		local t = hullTrace(from, from + self:GetForward() * 30, AHEAD_MINS, AHEAD_MAXS, MASK_NPCSOLID, NO_ZOMBIES)
		if t.Hit and not t.StartSolid and self:HZ_TryVault(goal) then return end
	end

	-- swing while closing in (upper-body layer, legs keep running)
	if tdist < 120 and now > (self.hz_nextSwing or 0) then
		local sw = HZ.Pick(self.P.swing)
		local rate = self.hz_shambler and CV.sh_rate:GetFloat() or 1
		if sw then
			local layer = self:AddGestureSequence(sw, true)
			if layer and rate ~= 1 then self:SetLayerPlaybackRate(layer, rate) end
		end
		self.hz_nextSwing = now + math.Rand(1.0, 1.5) / rate
		self.hz_hitAt = now + 0.4 / rate
	end
	if math.random() < 0.04 then HZ.Voice(self, "rage", 80) end
end

-- A pipe bomb or bile splash in range beats everyone (L4D2): run to it along the navmesh, crowd round it and
-- claw at it until it's gone, then go back to whoever we were after.
local function clearTo(self, a, b)
	return not hullTrace(a + UP20, b + UP20, CLEAR_MINS, CLEAR_MAXS, MASK_NPCSOLID_BRUSHONLY, self).Hit
end

function ENT:HZ_LureStep(now, pos)
	local lure = HZ.LureFor(pos)
	if not lure then
		self.hz_lurePath, self.hz_lureFor = nil, nil
		return false
	end
	local lp = lure.pos
	self.hz_target, self.hz_lost, self.hz_unreach = nil, nil, nil
	self.hz_lastHasTarget = now
	local d = pos:Distance(lp)
	-- arrived: right at it, or in the crowd round it (3+ infected already closer in) - the back rows mill
	-- and swipe instead of shoving forever
	local ahead = 0
	if d < 220 then
		local d2 = d * d
		HZ.Near(lp, d, function(_, od2) if od2 < d2 then ahead = ahead + 1 end end, self)
	end
	if d < 60 or ahead >= 3 then
		-- there: face it and swipe at it now and then
		self.hz_goal = nil
		self.loco:FaceTowards(lp)
		if now > (self.hz_nextLureHit or 0) then
			self.hz_nextLureHit = now + math.Rand(0.8, 2.0)
			local rate = self.hz_shambler and CV.sh_rate:GetFloat() or math.Rand(0.9, 1.15)
			self:HZ_PlayOnce(HZ.Pick(self.P.melee), rate, false, nil, lp)
		elseif self.hz_moveAnim then
			self:HZ_SetSeq(HZ.Pick(self.P.alert_idle))
		end
		return true
	end
	local goal
	if d < 400 and math.abs(lp.z - pos.z) < 56 and clearTo(self, pos, lp) then
		goal = lp
	else
		local path = self.hz_lurePath
		if not path or self.hz_lureFor ~= lure or now > (self.hz_lurePathT or 0) then
			path = path or Path("Follow")
			path:SetGoalTolerance(40)
			path:Compute(self, lp)
			self.hz_lurePath, self.hz_lureFor = path, lure
			self.hz_lurePathT = now + math.Rand(0.8, 1.4)
		end
		if path:IsValid() then
			path:MoveCursorToClosestPosition(pos)
			path:MoveCursor(80)
			goal = path:GetPositionOnPath(path:GetCursorPosition())
		else
			goal = lp
		end
	end
	local sep = HZ.Separation(self, pos)
	if sep then goal = goal + sep end
	self.hz_goal = goal
	if not self.hz_falling then self:HZ_SetMove("run") end
	return true
end

-- Climb spots around an elevated target: walk outward from its feet in 12 directions until the floor
-- ends, then look down; an edge 24-168 units above solid ground with standing room is a spot.
-- Shared by every zombie chasing that target, refreshed when it moves or every 3 s.
local function solidOnly(e) return not (e:IsPlayer() or e:IsNPC() or e:IsNextBot()) end
local SPOT_DIRS = 12
local SPOT_MINS, SPOT_MAXS = Vector(-12, -12, 0), Vector(12, 12, 64)
local function climbSpots(tgt)
	local now = CurTime()
	local feet = tgt:GetPos()
	local c = tgt.hz_climbSpots
	if c and now - c.t < 3 and c.pos:DistToSqr(feet) < 48 * 48 then return c.spots end
	local spots = {}
	for i = 0, SPOT_DIRS - 1 do
		local a = math.rad(i * 360 / SPOT_DIRS)
		local dir = Vector(math.cos(a), math.sin(a), 0)
		local edge
		for step = 24, 360, 24 do
			local p = feet + dir * step
			local wall = util.TraceLine({ start = feet + dir * (step - 24) + Vector(0, 0, 24), endpos = p + Vector(0, 0, 24),
				mask = MASK_NPCSOLID, filter = solidOnly })
			if wall.Hit then break end
			local fl = util.TraceLine({ start = p + Vector(0, 0, 16), endpos = p - Vector(0, 0, 24), mask = MASK_NPCSOLID,
				filter = solidOnly })
			if not fl.Hit then
				edge = p
				break
			end
		end
		if edge then
			local out = edge + dir * 16
			local gr = util.TraceLine({ start = out + Vector(0, 0, 8), endpos = out - Vector(0, 0, 400), mask = MASK_NPCSOLID,
				filter = solidOnly })
			local h = gr.Hit and not gr.StartSolid and (feet.z - gr.HitPos.z)
			if h and h >= 24 and h <= 168 and gr.HitNormal.z > 0.7 then
				local stand = gr.HitPos + dir * 8
				local room = util.TraceHull({ start = stand + Vector(0, 0, 4), endpos = stand + Vector(0, 0, 5),
					mins = SPOT_MINS, maxs = SPOT_MAXS, mask = MASK_NPCSOLID, filter = solidOnly })
				if not room.Hit and not room.StartSolid then
					spots[#spots + 1] = { pos = stand, top = edge - dir * 12 }
				end
			end
		end
	end
	tgt.hz_climbSpots = { t = now, pos = feet, spots = spots }
	return spots
end

-- this zombie's spot: one of the two nearest (spreads a crowd over two edges), kept while still offered
function ENT:HZ_ClimbSpot(tgt)
	local spots = climbSpots(tgt)
	if #spots == 0 then return nil end
	local cur = self.hz_spot
	if cur then
		for _, s in ipairs(spots) do if s == cur then return cur end end
	end
	local pos = self:GetPos()
	local best, second, bd, sd
	local cap = self.hz_shambler and CV.sh_climb:GetFloat()
	for _, s in ipairs(spots) do
		if s ~= self.hz_badSpot and not (cap and s.top.z - s.pos.z > cap) then
			local d = s.pos:DistToSqr(pos)
			if not bd or d < bd then
				best, second, sd, bd = s, best, bd, d
			elseif not sd or d < sd then
				second, sd = s, d
			end
		end
	end
	self.hz_spot = (second and math.random() < 0.35) and second or best
	self.hz_spotFails = 0
	return self.hz_spot
end

---------------------------------------------------------------- melee
-- Is the target down low? Judged by where its eyes are, not a crouch flag, so it also covers players
-- downed by revive / incap addons (they lower the view) and small NPCs.
function ENT:HZ_TargetLow(tgt)
	if not IsValid(tgt) then return false end
	if tgt:IsPlayer() and tgt:Crouching() then return true end
	local eye = tgt.EyePos and tgt:EyePos() or tgt:WorldSpaceCenter()
	return eye.z - tgt:GetPos().z < 48 or eye.z - self:GetPos().z < 40
end

function ENT:HZ_AttackSeq(tgt)
	local low = self:HZ_TargetLow(tgt)
	self.hz_attackLow = low
	local pool = (low and #self.P.attack_low > 0) and self.P.attack_low or self.P.melee
	self:HZ_SetSeq(HZ.Pick(pool), self.hz_shambler and CV.sh_rate:GetFloat() or 1)
end

function ENT:HZ_StartAttack(tgt)
	self.hz_attacking = true
	self.hz_goal = nil
	self.hz_target = tgt
	local rate = self.hz_shambler and CV.sh_rate:GetFloat() or 1
	self:HZ_AttackSeq(tgt)
	self.hz_nextLowCheck = CurTime() + 0.4
	self.hz_nextHit = CurTime() + 0.35 / rate
	HZ.Voice(self, "rageat", 80)
end

function ENT:HZ_AttackStep(now, tgt)
	if not HZ.IsHostile(tgt) then
		self.hz_attacking = nil
		self.hz_nextBrain = 0
		return
	end
	local pos, tpos = self:GetPos(), tgt:GetPos()
	self.loco:FaceTowards(tpos)
	if pos:DistToSqr(tpos) > 75 * 75 or math.abs(tpos.z - pos.z) > 60 then
		self.hz_attacking = nil
		self.hz_nextBrain = 0
		return
	end
	-- target got up / went down mid-attack: switch between standing and ground attacks
	if now >= (self.hz_nextLowCheck or 0) then
		self.hz_nextLowCheck = now + 0.4
		if self:HZ_TargetLow(tgt) ~= self.hz_attackLow then self:HZ_AttackSeq(tgt) end
	end
	if now >= self.hz_nextHit then
		self.hz_nextHit = now + math.Rand(0.8, 1.1) / (self.hz_shambler and CV.sh_rate:GetFloat() or 1)
		self:HZ_TryHit(tgt, 72)
		if math.random() < 0.3 then HZ.Voice(self, "rageat", 78) end
	end
end

-- L4D2-style: how hard one hit lands depends on how many infected are on the same target. Alone: solo range
-- (7-10). From hz_damage_mob_count attackers up: mob range (1-2). In between it blends.
function ENT:HZ_HitDamage(tgt)
	local tpos = tgt:GetPos()
	local n = 1
	for z in pairs(HZ.Zombies) do
		if z ~= self and IsValid(z) and not z.hz_dead and z.hz_target == tgt and z:GetPos():DistToSqr(tpos) < 110 * 110 then
			n = n + 1
		end
	end
	local full = math.max(2, CV.dmg_mob_n:GetInt())
	local f = math.Clamp((n - 1) / (full - 1), 0, 1)
	local solo = math.Rand(CV.dmg_solo_lo:GetFloat(), math.max(CV.dmg_solo_lo:GetFloat(), CV.dmg_solo_hi:GetFloat()))
	local mob = math.Rand(CV.dmg_mob_lo:GetFloat(), math.max(CV.dmg_mob_lo:GetFloat(), CV.dmg_mob_hi:GetFloat()))
	return math.max(1, math.Round(Lerp(f, solo, mob)))
end

function ENT:HZ_TryHit(tgt, reach)
	if not HZ.IsHostile(tgt) then return end
	local c = self:WorldSpaceCenter()
	local to = tgt:WorldSpaceCenter() - c
	local d = to:Length()
	if d > reach or (d > 1 and self:GetForward():Dot(to / d) < 0.2) then
		HZ.Sound(self, "miss", 65)
		return
	end
	local dmg = DamageInfo()
	dmg:SetDamage(self:HZ_HitDamage(tgt) * (self.hz_shambler and CV.sh_damage:GetFloat() or 1))
	dmg:SetAttacker(self)
	dmg:SetInflictor(self)
	dmg:SetDamageType(DMG_SLASH)
	dmg:SetDamagePosition(tgt:WorldSpaceCenter())
	dmg:SetDamageForce(self:GetForward() * 2000)
	tgt:TakeDamageInfo(dmg)
	HZ.Sound(self, "hit", 72)
	if tgt:IsPlayer() then tgt:ViewPunch(Angle(math.Rand(-3, 3), math.Rand(-4, 4), math.Rand(-2, 2))) end
end

---------------------------------------------------------------- stuck: climb, bash, sidestep, warp
function ENT:HZ_StuckCheck(now)
	if now < (self.hz_nextStuck or 0) then return end
	self.hz_nextStuck = now + 0.4
	local pos = self:GetPos()
	local last = self.hz_lastPos
	self.hz_lastPos = pos
	local goal = self.hz_goal
	if not last or not goal then self.hz_stuckSince = nil return end
	local dx, dy = pos.x - last.x, pos.y - last.y
	if dx * dx + dy * dy > 64 or pos:DistToSqr(goal) < 1600 then
		self.hz_stuckSince = nil
		return
	end
	self.hz_stuckSince = self.hz_stuckSince or now
	local st = now - self.hz_stuckSince
	if st > 0.4 then
		if CV.climb:GetBool() and (self:HZ_TryVault() or self:HZ_TryClimb()) then self.hz_stuckSince = nil return end
		if self:HZ_TryObstacle() then self.hz_stuckSince = nil return end
	end
	if st > 1.5 and not self.hz_sideUntil then
		self.hz_sideOff = self:GetRight() * (math.random() < 0.5 and -70 or 70)
		self.hz_sideUntil = now + 0.8
	elseif self.hz_sideUntil and now > self.hz_sideUntil + 1 then
		self.hz_sideUntil = nil
	end
	if st > 6 then
		self.hz_stuckSince = nil
		if HZ.SeenByPlayers(pos, 400) then return end
		local area = HZ.Flow.AreaOf(self)
		local n = area and HZ.Flow.nxt[area:GetID()]
		local na = n and HZ.Flow.Area(n)
		if na and IsValid(na) then
			self:SetPos(na:GetCenter() + Vector(0, 0, 4))
			self.hz_ownMove = engine.TickCount()
			self.loco:ClearStuck()
		end
	end
end

-- Climbing a wall as a crowd: each zombie aims for its own point along the wall (hz_climbLat, a sideways
-- offset from the climb point), and anyone already close to the wall just climbs straight in from where
-- it stands. Returns true if it climbed, else the point to run to.
function ENT:HZ_WallClimb(foot, top, vault)
	local pos = self:GetPos()
	local d = Vector(top.x - foot.x, top.y - foot.y, 0)
	if d:LengthSqr() < 1 then d = self:GetForward() d.z = 0 end
	d:Normalize()
	local side = Vector(-d.y, d.x, 0)
	local rel = pos - foot
	local along, lateral = rel:Dot(d), rel:Dot(side)
	self.hz_climbLat = self.hz_climbLat or math.Rand(-70, 70)
	if along > -70 and math.abs(lateral) < 150 then
		self.hz_atWall = true
		local at = pos + d * 100
		self.loco:FaceTowards(at)
		if (vault and self:HZ_TryVault(top)) or (not vault and self:HZ_TryClimb(at)) then
			self.hz_climbLat = nil
			return true
		end
		self.hz_climbLat = self.hz_climbLat * 0.6   -- no ledge here: drift toward the checked climb point
	end
	return false, foot + side * self.hz_climbLat
end

local PROBES = { 30, 45, 60, 75, 90 }
-- other infected never block a climb: they pass through each other anyway, and with a crowd at a wall
-- every check hit a neighbour so nobody climbed and they milled about (2026-11-23)
function ENT:HZ_TryClimb(toward)
	local blk = NO_ZOMBIES
	local pos = self:GetPos()
	local goal = toward or self.hz_goal
	if not goal then return false end
	local dir = goal - pos
	dir.z = 0
	if dir:LengthSqr() < 1 then return false end
	dir:Normalize()
	local tr, h
	for _, d in ipairs(PROBES) do
		local probe = pos + dir * d
		local t = util.TraceHull({ start = probe + Vector(0, 0, 184), endpos = probe + Vector(0, 0, 16),
			mins = Vector(-8, -8, 0), maxs = Vector(8, 8, 4), mask = MASK_NPCSOLID, filter = blk })
		if t.Hit and not t.StartSolid then
			local th = t.HitPos.z - pos.z
			if th >= 20 and th <= 172 then tr, h = t, th break end
		end
	end
	if not tr then return false end
	if self.hz_shambler and h > CV.sh_climb:GetFloat() then return false end
	local up = util.TraceHull({ start = pos + Vector(0, 0, 8), endpos = pos + Vector(0, 0, h + 8),
		mins = Vector(-10, -10, 0), maxs = Vector(10, 10, 64), mask = MASK_NPCSOLID, filter = blk })
	if up.Hit then return false end
	local land = tr.HitPos
	local room = util.TraceHull({ start = land + Vector(0, 0, 2), endpos = land + Vector(0, 0, 3),
		mins = Vector(-12, -12, 0), maxs = Vector(12, 12, 68), mask = MASK_NPCSOLID, filter = blk })
	if room.StartSolid or room.Hit then return false end

	local best, bd
	for h2 in pairs(self.P.climb) do
		local d = math.abs(h2 - h)
		if not bd or d < bd then best, bd = h2, d end
	end
	if not best then return false end
	self:SetAngles(Angle(0, dir:Angle().y, 0))
	-- While the locomotor thinks it is on the ground it snaps the bot back down every tick (anything within
	-- step height below counts as floor), so the climb's root motion never lifted it and it popped onto the
	-- ledge at the end. Put it in the air first (a jump whose velocity we zero), no gravity, no step snap.
	local grav, stepH = self.loco:GetGravity(), self.loco:GetStepHeight()
	self.loco:SetGravity(0)
	self.loco:SetStepHeight(0)
	self.loco:Jump()
	self.loco:SetVelocity(vector_origin)
	self:SetPos(self:GetPos() + Vector(0, 0, 1))
	self.hz_climbing = true
	self:HZ_PlayOnce(HZ.Pick(self.P.climb[best]), 1.25, true, h / best)
	self.hz_climbing = nil
	self.loco:SetStepHeight(stepH)
	self.loco:SetGravity(grav)
	if self.hz_dead then return true end
	if self:GetPos():DistToSqr(land) > 18 * 18 then self:SetPos(land + Vector(0, 0, 2)) end
	self.hz_ownMove = engine.TickCount()
	self.loco:ClearStuck()
	self.hz_nextBrain = 0
	self.hz_moveAnim = nil
	return true
end

-- Vaulting (L4D2's Climb36_Hurdle): over waist-high cover, railings, car bonnets and through windows, landing
-- on the far side instead of climbing on top. Needs: something 18-62 units high right in front, room to pass
-- over it at that height (a window's opening counts), and floor beyond it no higher than here (drops down to
-- 80 units are fine). The one hurdle anim is stretched to the obstacle's height and the landing distance.
local VAULT_MIN, VAULT_MAX = 18, 62
function ENT:HZ_TryVault(toward)
	if not CV.climb:GetBool() then return false end
	local blk = NO_ZOMBIES
	local pos = self:GetPos()
	local goal = toward or self.hz_goal
	if not goal or goal.z > pos.z + 40 then return false end   -- the way goes up: that's a climb
	local dir = goal - pos
	dir.z = 0
	if dir:LengthSqr() < 1 then return false end
	dir:Normalize()
	-- something in front at shin height?
	local front = util.TraceHull({ start = pos + Vector(0, 0, 20), endpos = pos + Vector(0, 0, 20) + dir * 40,
		mins = Vector(-10, -10, 0), maxs = Vector(10, 10, 8), mask = MASK_NPCSOLID, filter = blk })
	if not front.Hit or front.StartSolid then return false end
	local fd = front.Fraction * 40
	-- its height: the highest point just past where it starts
	local h
	for d = fd + 14, fd + 50, 9 do
		local p = pos + dir * d
		local t = util.TraceLine({ start = p + Vector(0, 0, VAULT_MAX + 8), endpos = p + Vector(0, 0, 4),
			mask = MASK_NPCSOLID, filter = blk })
		if t.StartSolid then return false end   -- wall (or a window too low to fit through)
		if t.Hit then
			local th = t.HitPos.z - pos.z
			if not h or th > h then h = th end
		end
	end
	if not h or h < VAULT_MIN or h > VAULT_MAX then return false end
	if self.hz_shambler and h > CV.sh_climb:GetFloat() then return false end
	-- somewhere to land beyond it, reachable over the top
	local land
	for d = fd + 34, fd + 120, 12 do
		local p = pos + dir * d
		local g = util.TraceLine({ start = Vector(p.x, p.y, pos.z + h + 8), endpos = Vector(p.x, p.y, pos.z - 80),
			mask = MASK_NPCSOLID, filter = blk })
		if g.Hit and not g.StartSolid and g.HitPos.z <= pos.z + 20 and g.HitNormal.z > 0.7 then
			local room = util.TraceHull({ start = g.HitPos + Vector(0, 0, 2), endpos = g.HitPos + Vector(0, 0, 3),
				mins = Vector(-12, -12, 0), maxs = Vector(12, 12, 60), mask = MASK_NPCSOLID, filter = blk })
			local over = util.TraceHull({ start = pos + Vector(0, 0, h + 6), endpos = Vector(p.x, p.y, pos.z + h + 6),
				mins = Vector(-10, -10, 0), maxs = Vector(10, 10, 30), mask = MASK_NPCSOLID, filter = blk })
			if not room.Hit and not room.StartSolid and not over.Hit and not over.StartSolid then
				land = g.HitPos
				break
			end
		end
	end
	if not land then return false end
	local seq = HZ.Pick(self.P.vault)
	if not seq then return false end
	local ok, total = self:GetSequenceMovement(seq, 0, 1)
	local fwd = (ok and total and total.x > 10) and total.x or 100

	self:SetAngles(Angle(0, dir:Angle().y, 0))
	-- airborne for the vault, same as a climb (else the locomotor snaps it back to the floor every tick)
	local grav, stepH = self.loco:GetGravity(), self.loco:GetStepHeight()
	self.loco:SetGravity(0)
	self.loco:SetStepHeight(0)
	self.loco:Jump()
	self.loco:SetVelocity(vector_origin)
	self:SetPos(self:GetPos() + Vector(0, 0, 1))
	self.hz_climbing = true
	self:HZ_RootPlay(seq, { rate = self.hz_shambler and 0.85 or 1.15, free = true,
		zscale = (h + 6) / 36, xyscale = math.Clamp((land - pos):Length2D() / fwd, 0.6, 1.6) })
	self.hz_climbing = nil
	self.loco:SetStepHeight(stepH)
	self.loco:SetGravity(grav)
	if self.hz_dead then return true end
	-- land on the far side (a lower floor: gravity takes it down from here)
	local now = self:GetPos()
	if Vector(now.x - land.x, now.y - land.y, 0):LengthSqr() > 18 * 18 then
		self:SetPos(Vector(land.x, land.y, math.max(now.z, land.z + 2)))
	elseif now.z < land.z then
		self:SetPos(Vector(now.x, now.y, land.z + 2))
	end
	self.hz_ownMove = engine.TickCount()
	self.loco:ClearStuck()
	self.hz_nextBrain = 0
	self.hz_moveAnim = nil
	return true
end

-- doors get bashed open, props/breakables get hit and shoved
-- Pound on a door: L4D2's AttackDoor loop (a 20 s pounding cycle) with a blow every ~1.1 s (shamblers
-- ~1.6 s). Runs in chunks of up to 6 s, then the brain re-checks (still blocked -> straight back to it).
-- The door's health is shared by everyone on it (HZ.BashDoor), so a pile gets through far sooner.
function ENT:HZ_PoundDoor(door, at, dir, mat)
	local seq = HZ.Pick(self.P.door)
	if seq then self:HZ_SetSeq(seq, self.hz_shambler and 0.8 or 1) end
	self.hz_moveAnim = nil
	local every = self.hz_shambler and 1.6 or 1.1
	local nextBlow = CurTime() + math.Rand(0.3, every)
	local stop = CurTime() + 6
	self.hz_inOnce = true
	while IsValid(door) and not self.hz_dead and not self.hz_shove and CurTime() < stop do
		self.loco:SetVelocity(vector_origin)
		self.loco:FaceTowards(at)
		if not HZ.AIDisabled() and CurTime() >= nextBlow then
			nextBlow = CurTime() + every * math.Rand(0.85, 1.15)
			if HZ.BashDoor(door, self, dir, mat) then break end
			if math.random() < 0.25 then HZ.Voice(self, "rageat", 78) end
		end
		coroutine.yield()
	end
	self.hz_inOnce = nil
	self.hz_ownMove = engine.TickCount()
	self.hz_nextBrain = 0
end

function ENT:HZ_TryObstacle()
	local pos = self:GetPos() + Vector(0, 0, 40)
	local dir = self:GetForward()
	-- (other infected don't count: a crowd piled against a door all bash it)
	local tr = util.TraceLine({ start = pos, endpos = pos + dir * 48, mask = MASK_NPCSOLID, filter = NO_ZOMBIES })
	local e = tr.Entity
	if not IsValid(e) or e:IsPlayer() or e:IsNPC() or e:IsNextBot() then return false end
	local c = e:GetClass()
	if c:find("door", 1, true) then
		self:HZ_PoundDoor(e, tr.HitPos, dir, tr.MatType)
		return true
	end
	if e:GetMoveType() == MOVETYPE_VPHYSICS or c:find("breakable", 1, true) then
		self:HZ_PlayOnce(HZ.Pick(self.P.melee), 1.3, false, nil, tr.HitPos)
		if not IsValid(e) then return true end
		local d = DamageInfo()
		d:SetDamage(25)
		d:SetAttacker(self)
		d:SetInflictor(self)
		d:SetDamageType(DMG_CLUB)
		d:SetDamagePosition(tr.HitPos)
		e:TakeDamageInfo(d)
		local ph = e:GetPhysicsObject()
		if IsValid(ph) then ph:ApplyForceOffset(dir * ph:GetMass() * 150, tr.HitPos) end
		self.hz_nextBrain = 0
		return true
	end
	return false
end

-- Stagger in the direction of the push (self.hz_shovePush, world vector). With a wall close behind in
-- that direction the short "into wall" bounce plays instead of a long stumble.
local SHOVE_DIRS = { [0] = "back", "fwd", "right", "left" }
function ENT:HZ_Shoved()
	local push = self.hz_shovePush or -self:GetForward()
	self.hz_shovePush = nil
	-- a shove cancels whatever it was doing with its arms: the attack, a swing or flinch still playing on a
	-- gesture layer over the stagger (looked like it kept clawing mid-stumble), and a swing hit still pending
	self:RemoveAllGestures()
	self.hz_attacking, self.hz_hitAt = nil, nil
	self.hz_nextSwing = CurTime() + 0.8
	self.hz_nextHit = CurTime() + 0.8
	local dir = SHOVE_DIRS[self:HZ_LocalDir(push)]
	local p = self.P
	local seq
	if not self.hz_alerted and self.hz_pose == "lie" then
		-- nothing in the set shoves a lying body: it just wakes (and gets up the proper way)
		if not self.hz_wakeAt then self.hz_wakeAt = CurTime() end
		return
	end
	if not self.hz_alerted and self.hz_pose == "sit" then
		-- L4D2's sitting shoves knock it sideways and up onto its feet
		local sp = (dir == "left" or dir == "right") and p["shove_sit_" .. dir]
			or p[math.random() < 0.5 and "shove_sit_left" or "shove_sit_right"]
		local sseq = HZ.Pick(sp)
		if sseq then
			HZ.Voice(self, "shoved", 75)
			self.hz_inShove = true
			self:HZ_PlayOnce(sseq, 1.1, true, 1, nil, true)
			self.hz_inShove = nil
			self.hz_pose, self.hz_upSeq = "stand", nil
			self.hz_nextBrain = 0
			if not self.hz_wakeAt then self.hz_wakeAt = CurTime() end
			return
		end
	end
	local wv = Vector(push.x, push.y, 0)
	wv:Normalize()
	local pos = self:GetPos()
	local wall = util.TraceHull({ start = pos + Vector(0, 0, 8), endpos = pos + Vector(0, 0, 8) + wv * 64,
		mins = Vector(-12, -12, 0), maxs = Vector(12, 12, 56), mask = MASK_NPCSOLID_BRUSHONLY, filter = self })
	if wall.Hit then seq = HZ.Pick(p["shove_" .. dir .. "_wall"]) end
	if not seq and self.hz_shambler and dir == "back" and math.random() < CV.sh_knock:GetFloat() then
		seq = HZ.Pick(p.knockdown)   -- down it goes, then slowly back up
	end
	seq = seq or HZ.Pick(p["shove_" .. dir]) or HZ.Pick(p.shove_back)
	if not seq then return end
	HZ.Voice(self, "shoved", 75)
	self.hz_inShove = true
	local res, tr = self:HZ_PlayOnce(seq, 1.1, true, 1, nil, true, not wall.Hit)
	if res == "wall" then
		-- stumbled into a wall: L4D2's impact bounce for that direction
		local imp = HZ.Pick(p["shove_" .. dir .. "_wall"]) or HZ.Pick(p.shove_back_wall)
		self:EmitSound("physics/body/body_medium_impact_hard" .. math.random(1, 6) .. ".wav", 70, math.random(90, 105))
		if tr and tr.Entity and IsValid(tr.Entity) and tr.Entity:GetClass():find("door", 1, true) == nil then
			local ph = tr.Entity:GetPhysicsObject()
			if IsValid(ph) then ph:ApplyForceOffset(wv * 4000, tr.HitPos) end
		end
		if imp then self:HZ_PlayOnce(imp, 1.1, true, 1, nil, true) end
	end
	self.hz_inShove = nil
	self.hz_nextBrain = 0
	if not self.hz_alerted and not self.hz_wakeAt then self.hz_wakeAt = CurTime() end
end

-- Is this hit a shove/melee/impact that should stagger? Works off what any weapon base sends:
-- club/slash damage, or any non-bullet hit from someone standing within melee reach (bashes and
-- kicks from ARC9/TFA/TacRP/MW-style bases), plus hard prop and vehicle impacts.
function ENT:HZ_StaggerPush(dmg)
	local pos = self:GetPos()
	if dmg:IsExplosionDamage() then
		local d = pos - dmg:GetDamagePosition()
		return d:LengthSqr() > 1 and d or dmg:GetDamageForce()
	end
	if dmg:IsDamageType(bit.bor(DMG_CRUSH, DMG_VEHICLE)) then
		if dmg:GetDamage() < 10 then return end
		local f = dmg:GetDamageForce()
		if f:LengthSqr() > 1 then return f end
		local inf = dmg:GetInflictor()
		return IsValid(inf) and (pos - inf:GetPos()) or nil
	end
	-- melee swings, bashes and kicks from any weapon base (same test the melee arc uses)
	local att = HZ.MeleeAttacker(self, dmg)
	if att then return pos - att:GetPos() end
end

---------------------------------------------------------------- damage / death
function ENT:OnTraceAttack(dmg, dir, tr)
	if tr.HitGroup == HITGROUP_HEAD and self.hz_hsTick ~= engine.TickCount() then
		self.hz_hsTick = engine.TickCount()
		dmg:ScaleDamage(CV.headshot:GetFloat())
	elseif self.hz_shambler and tr.HitGroup ~= HITGROUP_HEAD and CV.sh_head:GetBool() then
		dmg:ScaleDamage(0.1)
	end
	-- pellets landing on the same tick = shotgun blast (for the death animation pick)
	local tick = engine.TickCount()
	if self.hz_pelletTick == tick then
		self.hz_pellets = self.hz_pellets + 1
	else
		self.hz_pelletTick, self.hz_pellets = tick, 1
	end
end

-- Death context for the client's death animation pick (HZ.DEATH_* in sh_config).
function ENT:HZ_DeathKind(dmg)
	local tick = engine.TickCount()
	if dmg:IsExplosionDamage() or dmg:IsDamageType(bit.bor(DMG_CRUSH, DMG_VEHICLE, DMG_FALL, DMG_BLAST, DMG_SONIC, DMG_DISSOLVE))
		or dmg:GetDamageForce():Length() > 60000 or self.hz_climbing or not self.loco:IsOnGround()
		or (self.hz_pose and self.hz_pose ~= "stand" and self.hz_pose ~= "wander") then
		return HZ.DEATH_RAGDOLL
	end
	-- a shotgun blast still knocks even a charging zombie back
	if dmg:IsDamageType(DMG_BUCKSHOT) or (self.hz_pelletTick == tick and (self.hz_pellets or 0) >= 3) then
		return HZ.DEATH_SHOTGUN
	end
	-- otherwise moving at all = a moving death, whatever hit it (a headshot mid-run must not stop it dead)
	local spd = math.max(self.loco:GetVelocity():Length2D(), self.hz_wpVel and self.hz_wpVel:Length() or 0)
	if spd > 150 then return HZ.DEATH_RUN end
	if spd > 20 then return HZ.DEATH_WALK end
	if self.hz_hsTick == tick then return HZ.DEATH_HEAD end
	if dmg:IsDamageType(DMG_SLASH) then return HZ.DEATH_SLASH end
	if dmg:IsDamageType(DMG_CLUB) then return HZ.DEATH_CLUB end
	return HZ.DEATH_STAND
end

-- Which way the hit pushes the body, relative to the zombie: 0 back, 1 forward, 2 right, 3 left.
function ENT:HZ_PushDir(dmg)
	local push = dmg:GetDamageForce()
	if push:LengthSqr() < 1 then
		local att = dmg:GetAttacker()
		push = IsValid(att) and (self:GetPos() - att:GetPos()) or -self:GetForward()
	end
	return self:HZ_LocalDir(push)
end

-- world push vector -> 0 back, 1 forward, 2 right, 3 left (relative to where the zombie faces)
function ENT:HZ_LocalDir(push)
	local f, r = push:Dot(self:GetForward()), push:Dot(self:GetRight())
	if math.abs(f) >= math.abs(r) then return f >= 0 and 1 or 0 end
	return r >= 0 and 2 or 3
end

function ENT:OnInjured(dmg)
	local now = CurTime()
	local att = dmg:GetAttacker()
	if HZ.IsHostile(att) then
		self.hz_aggro = att
		self.hz_aggroUntil = now + 6
	end
	if not self.hz_alerted then
		self.hz_wakeStartled = true
		self.hz_wakeAt = now
		self.hz_wakeSrc = att
	end
	local push = not self.hz_inShove and not self.hz_climbing and self:HZ_StaggerPush(dmg)
	if push then
		self.hz_shove = true
		self.hz_shovePush = push
	elseif dmg:GetDamage() >= 8 and now > (self.hz_nextFlinch or 0) then
		local fl = HZ.Pick(self.P.flinch)
		if fl then self:AddGestureSequence(fl, true) end
		self.hz_nextFlinch = now + 1.5
	end
	if dmg:IsDamageType(bit.bor(DMG_BURN, DMG_SLOWBURN)) then
		self:HZ_Ignite(att)
		if not self.hz_burnVoiced then self.hz_burnVoiced = true HZ.Voice(self, "ignite", 80, true) end
	elseif math.random() < 0.35 then
		HZ.Voice(self, "shot", 75)
	end
end

function ENT:OnKilled(dmg)
	if self.hz_dead then return end
	self.hz_dead = true
	HZ.LastDeath = CurTime()
	hook.Run("OnNPCKilled", self, dmg:GetAttacker(), dmg:GetInflictor())
	HZ.Voice(self, "die", 75)
	net.Start("hz_rag")
	net.WriteEntity(self)
	net.WriteVector(dmg:GetDamageForce())
	net.WriteVector(self.loco:GetVelocity())
	net.WriteUInt(self:HZ_DeathKind(dmg), 3)
	net.WriteUInt(self:HZ_PushDir(dmg), 2)
	net.WriteBool(self:IsOnFire() or self.hz_burnDie ~= nil)
	net.SendPVS(self:GetPos())
	self:Extinguish()
	self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
	HZ.Unregister(self)
	local owner = self.hz_owner
	if IsValid(owner) and owner.HZ_OnZombieDied then owner:HZ_OnZombieDied(self) end
	timer.Simple(0.3, function() if IsValid(self) then self:Remove() end end)
end

function ENT:OnStuck() end
function ENT:OnUnStuck() end
