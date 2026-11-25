AddCSLuaFile()

ENT.Base = "base_nextbot"
ENT.Type = "nextbot"
ENT.PrintName = "Infected"
ENT.Category = "Horde Zombies"
ENT.Spawnable = false

list.Set("NPC", "hz_zombie",
    { Name = "Infected", Class = "hz_zombie", Category = "Horde Zombies", IconOverride = "entities/hz_zombie.png" })

if CLIENT then
    language.Add("hz_zombie", "Infected")

    function ENT:Initialize()
        HZ.ClientRegister(self)
    end

    local band = bit.band
    local SHADOW_DEPTH = STUDIO_SHADOWDEPTHTEXTURE or 0x40000000
    local cvDepthDist = CreateClientConVar("hz_depth_dist", "1200", true, false,
        "Zombies beyond this range are left out of flashlight and projected texture shadows (0 = never)")

    local depthDistSqr = cvDepthDist:GetFloat()
    depthDistSqr = depthDistSqr > 0 and depthDistSqr * depthDistSqr or 0
    cvars.AddChangeCallback("hz_depth_dist", function(_, _, new)
        local val = tonumber(new) or 0
        depthDistSqr = val > 0 and val * val or 0
    end, "hordez_depth")

    function ENT:Draw(flags)
        if self.hz_ragdolled or self.hz_far or (self.hz_imp and (self.hz_fade or 1) >= 1) then return end

        if flags and depthDistSqr > 0 and band(flags, SHADOW_DEPTH) ~= 0 and (self.hz_d2 or 0) > depthDistSqr then
            return
        end

        local t0 = HZ.ProfOn and SysTime()
        self:DrawModel(flags)
        if t0 then HZ.ProfAdd("cl_draw", SysTime() - t0) end
    end

    return
end

local CV = HZ.CV
local vector_up = Vector(0, 0, 1)
local util_TraceHull, util_TraceLine = util.TraceHull, util.TraceLine

local NO_ZOMBIES = { "hz_zombie" }
local NO_BODIES = { "hz_zombie", "player", "prop_ragdoll" }

local UP20 = Vector(0, 0, 20)
local traceResult = {}
local traceInput = { output = traceResult }
local pairFilter = {}

local function HullTrace(from, to, mins, maxs, mask, filter)
    traceInput.start, traceInput.endpos, traceInput.mins, traceInput.maxs, traceInput.mask, traceInput.filter = from,
        to, mins, maxs, mask, filter

    util_TraceHull(traceInput)

    return traceResult
end

local function LineTrace(from, to, mask, filter)
    traceInput.start, traceInput.endpos, traceInput.mins, traceInput.maxs, traceInput.mask, traceInput.filter = from,
        to, nil, nil, mask, filter

    util_TraceLine(traceInput)

    return traceResult
end

local function FilterPair(a, b)
    pairFilter[1], pairFilter[2] = a, b
    return pairFilter
end

local CLEAR_MINS, CLEAR_MAXS = Vector(-8, -8, 0), Vector(8, 8, 24)
local FEEL_UP, FEEL_REACH, FEEL_STEER = Vector(0, 0, 24), 50, 80
local FEEL_COS, FEEL_SIN = math.cos(math.rad(35)), math.sin(math.rad(35))
local FLANK_MINS, FLANK_MAXS = Vector(-10, -10, 0), Vector(10, 10, 40)
local AHEAD_MINS, AHEAD_MAXS = Vector(-10, -10, 0), Vector(10, 10, 8)

local IDLE_WEIGHTS = { { "stand", 30 }, { "wander", 30 }, { "sit", 10 }, { "lie", 10 }, { "lean", 10 },
    { "crouch", 10 }, { "chair", 10 } }

local function RandomIdle()
    local total = 0
    for _, entry in ipairs(IDLE_WEIGHTS) do total = total + entry[2] end
    local roll = math.random() * total
    for _, entry in ipairs(IDLE_WEIGHTS) do
        roll = roll - entry[2]
        if roll <= 0 then return entry[1] end
    end

    return "stand"
end

function ENT:Initialize()
    self:SetModel(self.hz_model or HZ.RandomModel())
    self.hz_female = self:GetModel():find("female", 1, true) ~= nil
    local skins = self:SkinCount()
    if skins and skins > 1 then self:SetSkin(math.random(0, skins - 1)) end
    HZ.RandomBodygroups(self)

    local health = self.hz_shambler and CV.sh_health:GetInt() or CV.health:GetInt()
    self:SetHealth(health)
    self:SetMaxHealth(health)
    self:SetCollisionBounds(Vector(-12, -12, 0), Vector(12, 12, 70))
    self:SetCollisionGroup(COLLISION_GROUP_NPC_SCRIPTED)
    self:AddFlags(FL_OBJECT)
    self:SetBloodColor(BLOOD_COLOR_RED)

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
    local variance = math.Clamp(CV.speed_var:GetFloat(), 0, 0.9)
    self.hz_speedMul = math.Rand(1 - variance, 1 + variance)
    if self.hz_shambler then
        self.hz_shamSpeed = math.Rand(CV.sh_speed_lo:GetFloat(),
            math.max(CV.sh_speed_lo:GetFloat(), CV.sh_speed_hi:GetFloat()))

        self:SetNW2Bool("hz_shambler", true)
    end

    self.hz_nextBrain = 0
    self.hz_flankSlot = math.Rand(-1, 1)
    if not self.hz_idleType or self.hz_idleType == "random" then self.hz_idleType = RandomIdle() end
    HZ.Register(self)
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
    self:HZ_ReleaseSeatProp()
    local owner = self.hz_owner
    if not self.hz_dead and not self.hz_virtualized and IsValid(owner) and owner.HZ_OnZombieDied then
        owner:HZ_OnZombieDied(self)
    end
end

function ENT:HZ_Loops(seq)
    local loops = self.P.loops
    if not loops then
        loops = {}
        self.P.loops = loops
    end

    local looping = loops[seq]
    if looping == nil then
        local info = self:GetSequenceInfo(seq)
        looping = info and bit.band(info.flags or 0, 1) ~= 0 or false
        loops[seq] = looping
    end

    return looping
end

function ENT:HZ_SetSeq(seq, rate)
    if not seq then return end

    if isstring(seq) then
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
        local groundSpeed = self:GetSequenceGroundSpeed(seq)
        if not groundSpeed or groundSpeed < 10 then
            groundSpeed = (self.hz_shambler and kind == "run" and HZ.SHAMBLE_GS) or (kind == "run" and 220 or 40)
        end

        self.hz_moveGS = groundSpeed
        self.hz_wrap = not self:HZ_Loops(seq)
    end

    self.hz_moveAnim = true
    self.hz_wantLoop = true
    local runSpeed = self.hz_shambler and self.hz_shamSpeed or CV.runspeed:GetFloat() * self.hz_speedMul
    self.loco:SetDesiredSpeed(kind == "run" and runSpeed or self.hz_moveGS)
end

function ENT:HZ_PlayOnce(seq, rate, motion, zscale, face, hull, stopOnWall)
    if not seq then return end

    self.hz_inOnce = true
    local result = self:HZ_PlayOnceInner(seq, rate, motion, zscale, face, hull, stopOnWall)
    self.hz_inOnce = nil
    self.hz_ownMove = engine.TickCount()

    return result
end

local HULL_MINS, HULL_MAXS = Vector(-12, -12, 0), Vector(12, 12, 64)

function ENT:HZ_PlayOnceInner(seq, rate, motion, zscale, face, hull, stopOnWall)
    local filter = NO_ZOMBIES
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

        if HZ.AIDisabled() then
            local pausedAt = CurTime()
            self.hz_frozen = true
            while HZ.AIDisabled() and not self.hz_dead do
                self.loco:SetVelocity(vector_origin)
                coroutine.yield()
            end

            self.hz_frozen = nil
            t0 = t0 + (CurTime() - pausedAt)
        end

        if self.hz_shove and not self.hz_inShove and not self.hz_climbing then return end

        local frac = math.min((CurTime() - t0) / dur, 1)
        if motion and frac > last then
            local ok, move = self:GetSequenceMovement(seq, last, frac)
            if ok and move then
                move.z = move.z * (zscale or 1)
                move:Rotate(yaw)
                local from = self:GetPos()
                local to = from + move
                if hull then
                    local tr = util.TraceHull({ start = from + Vector(0, 0, 4), endpos = to + Vector(0, 0, 4),
                        mins = HULL_MINS, maxs = HULL_MAXS, mask = MASK_NPCSOLID, filter = filter })

                    if not tr.Hit then
                        self:SetPos(to)
                    else
                        local stepTr = util.TraceHull({ start = from + Vector(0, 0, 20), endpos = to + Vector(0, 0, 20),
                            mins = HULL_MINS, maxs = HULL_MAXS, mask = MASK_NPCSOLID, filter = filter })

                        if not stepTr.Hit then
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
            last = frac
        end

        if face then self.loco:FaceTowards(face) end
        if frac >= 1 then break end

        coroutine.yield()
    end
end

local LOCO_ACCEL = 1100

function ENT:HZ_WatchPush(vel)
    local now = CurTime()
    local pos = self:GetPos()
    vel = vel or self.loco:GetVelocity()
    local vz = vel.z
    vel.z = 0
    local lastPos, lastVel, lastTime = self.hz_wpPos, self.hz_wpVel, self.hz_wpT
    local ownMove = self.hz_ownMove and engine.TickCount() - self.hz_ownMove < 4
    if lastPos and not ownMove and not self.hz_climbing and not self.hz_dead
        and (pos.z - lastPos.z > 40 or vz > 350) then
        if HZ.CV.debug:GetBool() then
            print(("[hordez] launch caught on %s: rose %.0f u, vz %.0f | pose %s, seq %s, inOnce %s, shove %s, alerted %s, onGround %s"):format(
                tostring(self), pos.z - lastPos.z, vz, tostring(self.hz_pose),
                self:GetSequenceName(self:GetSequence()),
                tostring(self.hz_inOnce), tostring(self.hz_inShove), tostring(self.hz_alerted),
                tostring(self.loco:IsOnGround())))
        end

        self:SetPos(lastPos)
        self.loco:SetVelocity(vector_origin)
        self.loco:ClearStuck()
        self.hz_ownMove = engine.TickCount()
        self.hz_wpT = now
        return
    end

    self.hz_wpPos, self.hz_wpVel, self.hz_wpT = pos, vel, now
    if not lastPos or ownMove or self.hz_inOnce or self.hz_climbing or self.hz_shove or self.hz_dead then return end

    local dt = now - lastTime
    if dt <= 0 or dt > 0.3 then return end

    local deltaVel = vel - lastVel
    if vel:Length() > 180 and deltaVel:Dot(vel) > 0 and deltaVel:Length() > LOCO_ACCEL * dt + 200 then
        return self:HZ_ExternalPush(deltaVel)
    end

    local moved = pos - lastPos
    moved.z = 0
    if moved:Length() > math.max(lastVel:Length(), vel:Length()) * dt + 24 then
        return self:HZ_ExternalPush(moved)
    end
end

function ENT:HZ_ExternalPush(push, fromArc)
    if self.hz_inShove or self.hz_climbing or self.hz_dead then return end

    self.hz_shove = true
    self.hz_shovePush = push
    if not fromArc and not HZ.ArcBusy then
        local ply = HZ.ShoverOf(self)
        if ply then HZ.MeleeArc(ply, self) end
    end

    if HZ.CV.debug:GetBool() then
        print(("[hordez] external push on %s: %.0f u"):format(tostring(self), push:Length()))
    end
end

local CHAR = 0.7

function ENT:HZ_Ignite(attacker)
    if self.hz_dead then return end
    if self:WaterLevel() >= 2 then return end

    local burnTime = CV.burn_time:GetFloat() * math.Rand(0.85, 1.15)
    if not self:IsOnFire() then self:Ignite(burnTime + 2) end
    if self.hz_burnDie then return end

    self.hz_burnStart, self.hz_burnDie, self.hz_burner = CurTime(), CurTime() + burnTime, attacker
    self.hz_speedMul = self.hz_speedMul * 1.15
    self.hz_nextBrain = 0
    self.hz_alerted, self.hz_wakeAt = true, nil
    self.hz_attacking, self.hz_target, self.hz_goal = nil, nil, nil
    self.hz_pose = "stand"
    local forward = self:GetForward()
    self.hz_burnDir = Vector(forward.x, forward.y, 0):GetNormalized()
    self.hz_burnTurnAt = 0
    HZ.Voice(self, "ignite", 80, true)
    self.hz_burnVoiced = true
end

local BURN_MINS, BURN_MAXS = Vector(-12, -12, 18), Vector(12, 12, 64)

function ENT:HZ_BurnRun(now)
    local pos = self:GetPos()
    local dir = self.hz_burnDir or self:GetForward()
    if now >= self.hz_burnTurnAt then
        self.hz_burnTurnAt = now + math.Rand(0.4, 0.8)
        dir:Rotate(Angle(0, math.Rand(-18, 18), 0))
    end

    local tr = HullTrace(pos, pos + dir * 70, BURN_MINS, BURN_MAXS, MASK_NPCSOLID, NO_ZOMBIES)
    if tr.Hit then
        local side = math.random() < 0.5 and 1 or -1
        local normal = tr.HitNormal
        local turned = Vector(-normal.y * side, normal.x * side, 0)
        dir = (turned:LengthSqr() > 0.01 and turned or -dir):GetNormalized()
        self.hz_burnTurnAt = now + 0.5
    end

    self.hz_burnDir = dir
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
        local frac = math.Clamp((now - self.hz_burnStart) / (self.hz_burnDie - self.hz_burnStart), 0, 1)
        local col = 255 * (1 - CHAR * frac)
        self:SetColor(Color(col, col * 0.93, col * 0.86))
    end

    if now >= self.hz_burnDie then
        self.hz_burnDie = nil
        local attacker = IsValid(self.hz_burner) and self.hz_burner or game.GetWorld()
        local dmgInfo = DamageInfo()
        dmgInfo:SetDamage(self:Health() + 10)
        dmgInfo:SetDamageType(DMG_BURN)
        dmgInfo:SetAttacker(attacker)
        dmgInfo:SetInflictor(attacker)
        dmgInfo:SetDamagePosition(self:WorldSpaceCenter())
        self:TakeDamageInfo(dmgInfo)
    end
end

function ENT:BodyUpdate()
    if self.hz_frozen then return end

    local t0 = HZ.ProfOn and SysTime()
    if not self.hz_dead and self:Health() <= 0 then
        self:OnKilled(DamageInfo())
        if t0 then HZ.ProfAdd("sv_body", SysTime() - t0) end
        return
    end

    self:HZ_BurnTick()
    local moving = self.hz_moveAnim
    local watch = CurTime() - (self.hz_wpT or 0) >= 0.06
    local vel = (watch or moving) and self.loco:GetVelocity()
    if watch then self:HZ_WatchPush(vel) end
    if self.hz_nwAlert ~= self.hz_alerted then
        self.hz_nwAlert = self.hz_alerted
        self:SetNW2Bool("hz_alerted", self.hz_alerted == true)
    end

    if moving then
        local rate = math.Clamp(vel:Length2D() / (self.hz_moveGS or 200), 0.25, self.hz_shambler and HZ.SHAMBLE_MAX_RATE
            or 2)

        if math.abs(rate - self:GetPlaybackRate()) > 0.02 then self:SetPlaybackRate(rate) end
    end

    self:FrameAdvance()
    if self.hz_wrap and self.hz_wantLoop and self:GetCycle() >= 0.995 then
        self:SetCycle(0)
    end

    if t0 then HZ.ProfAdd("sv_body", SysTime() - t0) end
end

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

function ENT:HZ_FindLeanSpot()
    local base = self:GetPos()
    local eye = base + Vector(0, 0, 40)
    local best
    for i = 0, 7 do
        local dir = Angle(0, i * 45, 0):Forward()
        local tr = util.TraceLine({ start = eye, endpos = eye + dir * 56, mask = MASK_SOLID_BRUSHONLY })
        if tr.Hit and not tr.StartSolid and math.abs(tr.HitNormal.z) < 0.3
            and (not best or tr.Fraction < best.Fraction) then
            best = tr
        end
    end

    if not best then return false end

    local normal = Vector(best.HitNormal.x, best.HitNormal.y, 0)
    normal:Normalize()
    local pos = best.HitPos + normal * 11
    pos.z = base.z
    self:SetPos(pos)
    self.hz_ownMove = engine.TickCount()
    self:SetAngles(Angle(0, normal:Angle().y, 0))

    return true
end

local function YawAt(self, seq, frac)
    if frac <= 0 then return 0 end

    local ok, _, ang = self:GetSequenceMovement(seq, 0, frac)

    return (ok and ang) and ang.y or 0
end

local yawAng = Angle()
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
    local filter = NO_ZOMBIES
    local nextLook = 0
    local lastYaw = 0
    self.hz_inOnce = true
    while true do
        if opts.look and CurTime() >= nextLook and not self.hz_alerted and not self.hz_wakeAt then
            nextLook = CurTime() + 1
            self:HZ_Look(self:GetPos())
        end

        if self.hz_dead or HZ.AIDisabled() or (opts.abort and opts.abort()) then break end
        if self.hz_shove and not self.hz_climbing then break end

        local frac = math.min((CurTime() - t0) / dur, 1)
        if frac > last then
            local ok, move = self:GetSequenceMovement(seq, last, frac)
            if ok and move then
                if opts.free then
                    move.x, move.y, move.z = move.x * (opts.xyscale or 1), move.y * (opts.xyscale
                        or 1), move.z * (opts.zscale or 1)
                else
                    move.z = 0
                end

                local yaw = rad(base + lastYaw)
                local cosYaw, sinYaw = cos(yaw), sin(yaw)
                move.x, move.y = move.x * cosYaw - move.y * sinYaw, move.x * sinYaw + move.y * cosYaw
                local from = self:GetPos()
                local to = from + move
                local tr = not opts.free and util.TraceHull({ start = from + Vector(0, 0, opts.ground and 18 or 4),
                    endpos = to + Vector(0, 0, opts.ground and 18 or 4),
                    mins = HULL_MINS, maxs = HULL_MAXS, mask = MASK_NPCSOLID, filter = filter })

                if opts.free then
                    self:SetPos(to)
                elseif opts.ground then
                    local groundTr = not tr.Hit
                        and util.TraceLine({ start = to + Vector(0, 0, 18), endpos = to - Vector(0, 0, 30),
                        mask = MASK_NPCSOLID_BRUSHONLY })

                    if not groundTr or not groundTr.Hit or groundTr.StartSolid then break end

                    to.z = groundTr.HitPos.z
                    self:SetPos(to)
                elseif not tr.Hit then
                    self:SetPos(to)
                end
            end

            local y = YawAt(self, seq, frac)
            yawAng.y = base + y
            self:SetAngles(yawAng)
            self.loco:SetVelocity(vector_origin)
            last, lastYaw = frac, y
            if want and ((want > 0 and y >= want - 10) or (want < 0 and y <= want + 10)) then break end
        end

        if frac >= 1 or (opts.maxTime and CurTime() - t0 > opts.maxTime) then break end

        coroutine.yield()
    end

    self.hz_inOnce = nil
    self.hz_ownMove = engine.TickCount()

    return last
end

function ENT:HZ_YawTo(pos)
    local to = pos - self:GetPos()
    to.z = 0
    if to:LengthSqr() < 1 then return 0 end

    return math.NormalizeAngle(to:Angle().y - self:GetAngles().y)
end

local turnCache = {}

function ENT:HZ_TurnInfo(names, upto)
    local key = self:GetModel() .. "|" .. table.concat(names, ",")
    local cache = turnCache[key]
    if cache then return cache end

    cache = {}
    for _, name in ipairs(names) do
        local seq = self:LookupSequence(name)
        if seq and seq >= 0 then
            local yaw
            if upto then
                yaw = 0
                for step = 1, 10 do
                    local y = YawAt(self, seq, upto * step / 10)
                    if math.abs(y) > math.abs(yaw) then yaw = y end
                end
            else
                yaw = YawAt(self, seq, 1)
            end

            if math.abs(yaw) > 20 then cache[#cache + 1] = { seq = seq, yaw = yaw } end
        end
    end

    turnCache[key] = cache

    return cache
end

local function ClosestTurn(list, want, sameSign)
    local best, bestErr
    for _, turn in ipairs(list) do
        if not sameSign or (turn.yaw > 0) == (want > 0) then
            local err = math.abs(math.NormalizeAngle(want - turn.yaw))
            if not bestErr or err < bestErr then best, bestErr = turn, err end
        end
    end

    return best, bestErr
end

local TURN_SEQS = { "Idle_Neutral_Turn_Left", "Idle_Neutral_Turn_Right", "Idle_Neutral_Turn_Around_01a",
    "Idle_Neutral_Turn_Around_01b", "Idle_Neutral_Turn_Around_01c" }

function ENT:HZ_IdleTurn(pos)
    local want = self:HZ_YawTo(pos)
    if math.abs(want) < 45 then return end

    local best, bestErr = ClosestTurn(self:HZ_TurnInfo(TURN_SEQS), want)
    if not best or bestErr > 70 then return end

    self:HZ_RootPlay(best.seq, { look = true,
        abort = function()
            return self.hz_alerted or self.hz_wakeAt or self.hz_inShove
        end })
end

local ALERT_TURNS = { "Idle_Alert_Left_01", "Idle_Alert_Left_04", "Idle_Alert_Right_02a", "Idle_Alert_Right_02d",
    "Idle_Alert_Behind_02", "Idle_Alert_Behind_03" }

function ENT:HZ_AlertTurn(pos)
    local want = self:HZ_YawTo(pos)
    if math.abs(want) < 60 then return false end

    local best = ClosestTurn(self:HZ_TurnInfo(ALERT_TURNS, 0.35), want, true)
    if not best then return false end

    self:HZ_RootPlay(best.seq, { rate = 1.4, want = want, maxTime = 2.2,
        abort = function()
            return self.hz_inShove
        end })

    return true
end

local SEAT_REACH, SEAT_LOW, SEAT_HIGH = 36, 14, 22
local takenSeats = {}

local function SeatTaken(pos)
    for i = #takenSeats, 1, -1 do
        local taken = takenSeats[i]
        if not IsValid(taken.zombie) or taken.zombie.hz_seat ~= taken.seat then
            table.remove(takenSeats, i)
        elseif taken.seat.pos:DistToSqr(pos) < 26 * 26 then
            return true
        end
    end

    return false
end

local function SeatBlocked(ent)
    if not IsValid(ent) then return false end
    if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:GetClass():find("door", 1, true) then return true end

    local phys = ent:GetPhysicsObject()

    return IsValid(phys) and phys:IsMotionEnabled() and not phys:IsAsleep()
end

function ENT:HZ_FindSeat()
    if not CV.sit:GetBool() or #self.P.chair == 0 or #self.P.chair_down == 0 then return nil end

    local base = self:GetPos()
    local yaw = self:GetAngles().y
    local low, high = base + Vector(0, 0, 12), base + Vector(0, 0, SEAT_HIGH + 4)
    for i = 0, 7 do
        local dir = Angle(0, yaw + i * 45, 0):Forward()
        local front = util.TraceLine({ start = low, endpos = low + dir * SEAT_REACH, mask = MASK_NPCSOLID,
            filter = NO_ZOMBIES })

        if front.Hit and not front.StartSolid and math.abs(front.HitNormal.z) < 0.3
            and not SeatBlocked(front.Entity) then
            local dist = front.Fraction * SEAT_REACH
            local over = util.TraceLine({ start = high, endpos = high + dir * (dist + 24), mask = MASK_NPCSOLID,
                filter = NO_ZOMBIES })

            local spot = front.HitPos + dir * 9
            local top = util.TraceLine({ start = Vector(spot.x, spot.y, high.z),
                endpos = Vector(spot.x, spot.y, base.z + 6),
                mask = MASK_NPCSOLID, filter = NO_ZOMBIES })

            local height = top.HitPos.z - base.z
            if dist >= 13 and not over.Hit and top.Hit and not top.StartSolid and top.HitNormal.z > 0.8
                and height >= SEAT_LOW and height <= SEAT_HIGH then
                local body = util.TraceHull({ start = top.HitPos + Vector(0, 0, 2),
                    endpos = top.HitPos + Vector(0, 0, 3),
                    mins = Vector(-8, -8, 0), maxs = Vector(8, 8, 34), mask = MASK_NPCSOLID, filter = NO_ZOMBIES })

                if not body.Hit and not body.StartSolid and not SeatTaken(top.HitPos) then
                    local toward = Vector(-front.HitNormal.x, -front.HitNormal.y, 0)
                    toward:Normalize()
                    local ent = front.Entity

                    return { dir = toward, shift = toward * (dist + 9), pos = top.HitPos,
                        ent = IsValid(ent) and ent or nil, entPos = IsValid(ent) and ent:GetPos() or nil }
                end
            end
        end
    end
end

function ENT:HZ_SeatOffset(bone, world)
    self:ManipulateBonePosition(bone, Vector(world:Dot(self:GetForward()), -world:Dot(self:GetRight()), 0))
end

function ENT:HZ_TakeSeat(seat, instant)
    local bone = self:LookupBone("ValveBiped.Bip01_Pelvis")
    local down = HZ.Pick(self.P.chair_down)
    if not seat or not bone or not down then return false end

    local function Interrupted()
        return self.hz_alerted or self.hz_wakeAt or self.hz_inShove or self.hz_dead
    end

    if instant then
        self:SetAngles(Angle(0, (-seat.dir):Angle().y, 0))
    else
        self:HZ_IdleTurn(self:GetPos() + seat.dir * 100)
        if Interrupted() then return false end

        self:SetAngles(Angle(0, seat.dir:Angle().y, 0))
        local start = CurTime()
        local dur = math.max(self:SequenceDuration(down), 0.1)
        local played = self:HZ_RootPlay(down, { free = true, xyscale = 0, abort = function()
            local frac = math.Clamp((CurTime() - start) / dur, 0, 1)
            self:HZ_SeatOffset(bone, seat.shift * (frac * frac * (3 - 2 * frac)))

            return Interrupted()
        end })

        if played < 0.9 then
            self:ManipulateBonePosition(bone, vector_origin)
            if not Interrupted() then self:HZ_SetSeq(HZ.Pick(self.P.stand)) end

            return false
        end
    end

    self:HZ_SeatOffset(bone, seat.shift)
    self.hz_seat, self.hz_seatBone = seat, bone
    self:HZ_HoldSeatProp(seat.ent)
    takenSeats[#takenSeats + 1] = { zombie = self, seat = seat }
    self.hz_seatUntil = CurTime() + math.Rand(25, 70)
    self.hz_idleType, self.hz_pose = "chair", "chair"
    self:HZ_SetSeq(HZ.Pick(self.P.chair))
    if instant then self:SetCycle(math.random()) end

    return true
end

function ENT:HZ_HoldSeatProp(prop)
    if not IsValid(prop) or prop:GetMoveType() ~= MOVETYPE_VPHYSICS then return end

    local phys = prop:GetPhysicsObject()
    if not IsValid(phys) then return end

    if (prop.hz_seatHolds or 0) == 0 and phys:IsMotionEnabled() then
        phys:EnableMotion(false)
        prop.hz_seatFroze = true
    end

    prop.hz_seatHolds = (prop.hz_seatHolds or 0) + 1
    self.hz_seatProp = prop
end

function ENT:HZ_ReleaseSeatProp()
    local prop = self.hz_seatProp
    self.hz_seatProp = nil
    if not IsValid(prop) then return end

    prop.hz_seatHolds = (prop.hz_seatHolds or 1) - 1
    if prop.hz_seatHolds > 0 then return end

    prop.hz_seatHolds = nil
    if not prop.hz_seatFroze then return end

    prop.hz_seatFroze = nil
    local phys = prop:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableMotion(true)
        phys:Wake()
    end
end

function ENT:HZ_LeaveSeat(alert)
    local seat, bone = self.hz_seat, self.hz_seatBone
    self.hz_seat, self.hz_seatBone, self.hz_seatUntil = nil, nil, nil
    self:HZ_ReleaseSeatProp()
    if not seat or not bone then return end

    local up = HZ.Pick(alert and self.P.chair_wake or self.P.chair_up) or HZ.Pick(self.P.chair_up)
    if up then
        local start = CurTime()
        local rate = alert and math.Rand(1.15, 1.4) or 1
        local dur = math.max(self:SequenceDuration(up) / rate, 0.1)
        self:HZ_RootPlay(up, { free = true, xyscale = 0, rate = rate, abort = function()
            local frac = math.Clamp((CurTime() - start) / dur, 0, 1)
            self:HZ_SeatOffset(bone, seat.shift * (1 - frac * frac * (3 - 2 * frac)))

            return self.hz_dead or (not alert and (self.hz_alerted or self.hz_wakeAt))
        end })
    end

    if not self.hz_dead then self:ManipulateBonePosition(bone, vector_origin) end
end

function ENT:HZ_SeatGone()
    local seat = self.hz_seat
    if not seat or not seat.entPos then return false end

    return not IsValid(seat.ent) or seat.ent:GetPos():DistToSqr(seat.entPos) > 36
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

    local idleType = self.hz_idleType
    if idleType == "lean" and not self:HZ_FindLeanSpot() then idleType = "stand" end
    if idleType == "chair" and not self:HZ_TakeSeat(self:HZ_FindSeat(), true) then idleType = "wander" end
    self.hz_nextIdleSwap = now + math.Rand(6, 16)
    self.hz_nextWander = now + math.Rand(1, 8)
    self.hz_nextBrain = now + math.Rand(0, 1)
    if idleType == "chair" then return end

    self.hz_pose = idleType
    local pool = self.P[idleType]
    if idleType == "wander" or not pool or #pool == 0 then pool = self.P.stand end
    self:HZ_SetSeq(HZ.Pick(pool))
    if idleType == "sit" or idleType == "lie" or idleType == "lean" then self:SetCycle(math.random()) end
end

function ENT:HZ_StrollGoal(pos, maxLeg)
    local filter = NO_ZOMBIES
    for _ = 1, 4 do
        local dir = Angle(0, math.Rand(0, 360), 0):Forward()
        local want = pos + dir * math.Rand(40, maxLeg)
        local area = navmesh.GetNearestNavArea(want, false, 120, false, true)
        if area and IsValid(area) then
            local goal = area:GetClosestPointOnArea(want)
            if goal and math.abs(goal.z - pos.z) < 24 and goal:DistToSqr(pos) > 32 * 32 then
                local tr = util.TraceHull({ start = pos + Vector(0, 0, 18), endpos = goal + Vector(0, 0, 18),
                    mins = Vector(-13, -13, 0), maxs = Vector(13, 13, 48), mask = MASK_NPCSOLID, filter = filter })

                if not tr.Hit then return goal end
            end
        end
    end
end

function ENT:HZ_StartStroll(now, pos, maxLeg)
    local goal = self:HZ_StrollGoal(pos, maxLeg)
    if not goal then return false end

    self:HZ_IdleTurn(goal)
    if self.hz_alerted or self.hz_wakeAt or self.hz_dead then return true end

    local leg = goal:Distance(pos)
    local name = not self.hz_shambler and HZ.Pick(self.P.stroll)
    local seq = name and self:LookupSequence(name) or -1
    if seq >= 0 then
        local start = self:GetPos()
        self:HZ_RootPlay(seq, { ground = true, look = true, maxTime = 3 + leg / 10,
            abort = function()
                return self.hz_alerted or self.hz_wakeAt or self.hz_inShove
                    or self:GetPos():DistToSqr(start) >= leg * leg
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
    local playerDist = HZ.NearestPlayerDist(pos)
    local dormant = playerDist > CV.dormant:GetFloat()
    self.hz_nextBrain = now + (dormant and math.Rand(2, 3) or math.Rand(0.8, 1.2))
    HZ.GridMove(self, pos)
    if dormant then return end

    self:HZ_Look(pos)
    if self.hz_wakeAt then return end

    local pose = self.hz_pose
    if pose == "chair" then
        if self:HZ_SeatGone() or now > (self.hz_seatUntil or 0) then
            self:HZ_LeaveSeat(false)
            if self.hz_alerted or self.hz_wakeAt or self.hz_dead then return end

            self.hz_idleType, self.hz_pose = "wander", "wander"
            self:HZ_SetSeq(HZ.Pick(self.P.stand))
            self.hz_nextWander = now + math.Rand(2, 6)
            self.hz_nextSeatLook = now + math.Rand(20, 40)
        end

        return
    end

    if pose == "wander" and not self.hz_wanderGoal and self.hz_settleAt and now > self.hz_settleAt then
        self:HZ_TrySettle(now, pos)
        pose = self.hz_pose
    end

    if (pose == "wander" or pose == "stand") and not self.hz_wanderGoal and now > (self.hz_nextSeatLook or 0) then
        self.hz_nextSeatLook = now + math.Rand(4, 10)
        if playerDist < 3000 and self:HZ_TakeSeat(self:HZ_FindSeat(), false) then return end
        if self.hz_alerted or self.hz_wakeAt or self.hz_dead then return end
    end

    local strolls = (pose == "wander" or (pose == "stand" and math.random() < 0.08)) and not self.hz_wanderGoal
    if strolls and now > (self.hz_nextWander or 0) then
        self.hz_nextWander = now + math.Rand(6, 20)
        if math.random() < 0.25 then
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

    if playerDist < 1400 and math.random() < 0.1 then HZ.Voice(self, "idle", 65) end
end

function ENT:HZ_Look(pos)
    local sight = CV.sight:GetFloat()
    local pose = self.hz_pose
    if pose == "lie" or pose == "sit" or pose == "chair" then sight = sight * 0.7 end
    local forward = self:GetForward()
    local eye = pos + Vector(0, 0, (pose == "lie" and 16) or (pose == "chair" and 44) or 60)
    for _, target in ipairs(HZ.GetTargets()) do
        local ent = target.ent
        if IsValid(ent) then
            local to = target.pos - pos
            local dist = to:Length()
            local range = sight
            if target.ply then
                if ent:Crouching() then range = range * 0.5 end
                if ent:FlashlightIsOn() then range = range * 1.4 end
            end

            if dist < 110 then
                self:HZ_QueueWake(0.1, ent)
                return
            elseif dist < range and (dist < 300 or forward:Dot(to / dist) > 0.3) then
                if not LineTrace(eye, ent:EyePos(), MASK_OPAQUE, FilterPair(self, ent)).Hit then
                    self:HZ_QueueWake(math.Rand(0.2, 0.6) + dist / sight * 0.6, ent)
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

function ENT:HZ_Hear(pos, dist, src)
    if self.hz_alerted or self.hz_wakeAt then return end

    self.hz_noisePos = pos
    self:HZ_QueueWake(math.Rand(0.15, 0.5) + dist / 2200, src)
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
    if pose == "sit" then
        pool = self.P.sit_wake
    elseif pose == "lie" then
        pool = self.P.lie_wake
    elseif self.hz_wakeStartled then
        pool = self.P.startled
    else
        pool = self.P.wake
    end

    self.hz_pose = "stand"
    self.hz_wakeStartled = nil
    HZ.Voice(self, math.random() < 0.5 and "becomealert" or "alert", 80)
    if pose == "chair" then
        self:HZ_LeaveSeat(true)
        self.hz_nextBrain = 0
        return
    end

    local upSeq = self.hz_upSeq
    self.hz_upSeq = nil
    if upSeq and (pose == "sit" or pose == "lie") then pool = { upSeq } end
    local face = (pose ~= "sit" and pose ~= "lie") and look or nil
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
    self.hz_settleAt = CurTime() + math.Rand(15, 45)
end

local SETTLE = { sit = { "sit_down", "Sitting03", "Sitting03_to_Standing" },
    lie = { "lie_down", "Lying03", "Lying03_to_Standing" } }

function ENT:HZ_TrySettle(now, pos)
    local idleType = self.hz_settlePick or RandomIdle()
    if idleType == "chair" then
        self.hz_settleAt, self.hz_settlePick = nil, nil
        if self:HZ_TakeSeat(self:HZ_FindSeat(), false) then return end
        if self.hz_alerted or self.hz_wakeAt or self.hz_dead then return end

        idleType = "stand"
    end

    local tr = SETTLE[idleType]
    local down = tr and HZ.Pick(self.P[tr[1]])
    if down and self:LookupSequence(tr[2]) >= 0 then
        self.hz_settleAt, self.hz_settlePick = nil, nil
        local played = self:HZ_RootPlay(self:LookupSequence(down),
            { abort = function()
                return self.hz_alerted or self.hz_wakeAt or self.hz_inShove
            end })

        if played < 0.5 then
            self.hz_pose = "stand"
            self:HZ_SetSeq(HZ.Pick(self.P.stand))
            return
        end

        self.hz_idleType, self.hz_pose = idleType, idleType
        self.hz_upSeq = tr[3]
        self:HZ_SetSeq(tr[2])
        self.hz_nextIdleSwap = now + math.Rand(6, 16)
        return
    end

    if (idleType == "lean" or idleType == "crouch") and HZ.SeenByPlayers(pos, 500) then
        self.hz_settlePick = idleType
        self.hz_settleAt = now + math.Rand(3, 6)
        return
    end

    self.hz_settleAt, self.hz_settlePick = nil, nil
    if idleType == "lean" and not self:HZ_FindLeanSpot() then idleType = "stand" end
    self.hz_idleType = idleType
    self.hz_pose = idleType
    local pool = self.P[idleType]
    if idleType == "wander" or not pool or #pool == 0 then pool = self.P.stand end
    self:HZ_SetSeq(HZ.Pick(pool))
    if idleType == "sit" or idleType == "lie" or idleType == "lean" then self:SetCycle(math.random()) end
    self.hz_nextIdleSwap = now + math.Rand(6, 16)
    self.hz_nextWander = now + math.Rand(3, 10)
end

function ENT:HZ_NearestTarget(pos)
    local best, bestDist = nil, 1200 * 1200
    for _, list in ipairs(HZ.GetTargets()) do
        if IsValid(list.ent) and math.abs(list.pos.z - pos.z) < 200 then
            local distSqr = list.pos:DistToSqr(pos)
            if distSqr < bestDist then best, bestDist = list.ent, distSqr end
        end
    end

    return best, math.sqrt(bestDist)
end

function ENT:HZ_Clear(pos, target)
    local tr = HullTrace(pos + UP20, target:GetPos() + UP20, CLEAR_MINS, CLEAR_MAXS, MASK_NPCSOLID_BRUSHONLY,
        FilterPair(self, target))

    if not tr.Hit then return true end

    local ent = tr.Entity

    return IsValid(ent) and ent:GetClass() == "func_breakable_surf"
end

function ENT:HZ_Chase(now)
    if now >= self.hz_nextBrain then
        local t0 = HZ.ProfOn and SysTime()
        self:HZ_Brain(now)
        if t0 then HZ.ProfAdd("sv_brain", SysTime() - t0) end
    end
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
    local playerDist = HZ.NearestPlayerDist(pos)
    local hotDist = CV.hot_dist:GetFloat()
    local think = (playerDist < hotDist and math.Rand(0.12, 0.18) or math.Rand(0.35, 0.5))
        * (self.hz_shambler and 2 or 1)

    if playerDist > 500 and not (self.hz_tight and playerDist < hotDist) then
        local load = HZ.Count / math.max(CV.think_full:GetFloat(), 1)
        if load > 1 then think = think * math.min(load, 4) end
    end

    self.hz_nextBrain = now + think
    if self.hz_attacking or self:HZ_LureStep(now, pos) then
        self.hz_progressAt = now
        return
    end

    local area = HZ.Flow.AreaOf(self)
    local nextId, flowDist, flowTarget
    local graph = HZ.Flow.graph
    if area then nextId, flowDist, flowTarget = HZ.Flow.Step(area:GetID()) end
    self.hz_tight = (area and graph and graph.tight[area:GetID()]) or self.hz_stuckSince ~= nil
    self.hz_flowDist = flowDist
    local best = self.hz_bestFlow
    if not self.hz_progressAt or (flowDist and (flowDist < 300 or not best or flowDist < best - 48
        or flowDist > best + 600)) then
        self.hz_bestFlow, self.hz_progressAt = flowDist, now
    end

    local target = (flowTarget and HZ.IsHostile(flowTarget)) and flowTarget or nil
    local near, nearDist = self:HZ_NearestTarget(pos)
    if near and (not target or nearDist < 300) then target = near end
    local aggro = self.hz_aggro
    if aggro and now < (self.hz_aggroUntil or 0) and HZ.IsHostile(aggro)
        and aggro:GetPos():DistToSqr(pos) < 600 * 600 then
        target = aggro
    end

    if not target and self.hz_omni then
        local bestDist = math.huge
        for _, entry in ipairs(HZ.GetTargets()) do
            local distSqr = entry.pos:DistToSqr(pos)
            if distSqr < bestDist and HZ.IsHostile(entry.ent) then target, bestDist = entry.ent, distSqr end
        end
    end

    if not target then
        self.hz_target, self.hz_goal = nil, nil
        if not self.hz_lost then
            self.hz_lost = true
            local stop = HZ.Pick(self.P.run_stop)
            if stop and not self.hz_shambler and self.loco:IsOnGround()
                and self.loco:GetVelocity():Length2D() > 150 then
                self:HZ_PlayOnce(stop, 1.1, true, 1, nil, true, true)
                if self.hz_dead or not self.hz_alerted then return end
            end

            self:HZ_SetSeq(HZ.Pick(self.P.alert_idle))
        end

        if not self.hz_omni and now - (self.hz_lastHasTarget or now) > 25 then self:HZ_Calm() end
        return
    end

    self.hz_lost = nil
    self.hz_lastHasTarget = now
    self.hz_target = target

    local targetPos = target:GetPos()
    local targetDist = pos:Distance(targetPos)
    local dz = math.abs(targetPos.z - pos.z)
    if targetDist < (self.hz_shambler and 62 or 52) and dz < 48 then
        self:HZ_StartAttack(target)
        return
    end

    if targetPos.z - pos.z > 40 and targetDist < 900 and not HZ.Flow.OnMesh(target) then
        local spot = self:HZ_ClimbSpot(target)
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

    local goal
    local direct = targetDist < 420 and dz < 56 and self:HZ_Clear(pos, target)
    local link = nextId and area and not direct and HZ.Flow.ClimbLink(area:GetID(), nextId)
    if link and self.hz_shambler and (link.h or (link.top.z - link.foot.z)) > CV.sh_climb:GetFloat() then
        link, nextId = nil, nil
    end

    if link then
        local climbed, run = self:HZ_WallClimb(link.foot, link.top, link.vault)
        if climbed then return end

        goal = run
    elseif nextId == false or direct then
        goal = targetPos
    elseif nextId then
        local nextArea = HZ.Flow.Area(nextId)
        if nextArea and IsValid(nextArea) then
            goal = nextArea:GetClosestPointOnArea(pos)
            local center = nextArea:GetCenter()
            local dir = center - goal
            local len = dir:Length()
            if len > 1 then goal = goal + dir * (math.min(20, len) / len) end
            local afterNext = HZ.Flow.nxt[nextId]
            local reach = math.Clamp(think * 240, 48, 150)
            if afterNext and pos:DistToSqr(goal) < reach * reach then
                local afterArea = HZ.Flow.Area(afterNext)
                if afterArea and IsValid(afterArea) then goal = afterArea:GetClosestPointOnArea(goal) end
            end
        end
    elseif self:HZ_Clear(pos, target) then
        goal = targetPos
    end

    if not goal then
        self.hz_goal = nil
        if not self.hz_unreach then
            self.hz_unreach = true
            self:HZ_SetSeq(HZ.Pick(self.P.unreach))
        end

        self.loco:FaceTowards(targetPos)
        return
    end

    self.hz_unreach = nil

    if not self.hz_atWall and not link and playerDist < hotDist then
        local width, closeDist, ramp
        if self.hz_shambler then
            width, closeDist, ramp = CV.spread_sh:GetFloat(), 70, 260
        else
            width, closeDist, ramp = CV.spread_run:GetFloat(), 110, 420
        end

        local lateral = self.hz_flankSlot * width * math.Clamp((targetDist - closeDist) / ramp, 0, 1)
        local to = Vector(goal.x - pos.x, goal.y - pos.y, 0)
        if math.abs(lateral) > 4 and to:LengthSqr() > 1 then
            to:Normalize()
            local flankGoal = goal + Vector(-to.y, to.x, 0) * lateral
            if not HullTrace(pos + UP20, flankGoal + UP20, FLANK_MINS, FLANK_MAXS, MASK_NPCSOLID_BRUSHONLY).Hit
                and (not direct or not HullTrace(flankGoal + UP20, targetPos + UP20, FLANK_MINS, FLANK_MAXS,
                MASK_NPCSOLID_BRUSHONLY).Hit) then
                goal = flankGoal
            end
        end
    end

    local feelBlocked
    if not link and targetDist > 90 and playerDist < hotDist then
        goal, feelBlocked = self:HZ_Feel(pos, goal)
    end

    local separation = not self.hz_atWall and HZ.Separation(self, pos)
    if separation then goal = goal + separation end
    if self.hz_sideUntil and now < self.hz_sideUntil then goal = goal + self.hz_sideOff end
    self.hz_goal = goal
    if not self.hz_falling then self:HZ_SetMove("run") end
    if targetDist > 70 and playerDist < hotDist and feelBlocked ~= false and CV.climb:GetBool()
        and now >= (self.hz_nextVaultTry or 0) then
        local from = pos + UP20
        local aheadTr = HullTrace(from, from + self:GetForward() * 30, AHEAD_MINS, AHEAD_MAXS, MASK_NPCSOLID,
            NO_ZOMBIES)

        if aheadTr.Hit and not aheadTr.StartSolid then
            if self:HZ_TryVault(goal) then return end

            self.hz_nextVaultTry = now + 0.6
        end
    end

    if targetDist < 120 and not self.hz_shambler and now > (self.hz_nextSwing or 0) then
        local swing = HZ.Pick(self.P.swing)
        local rate = self.hz_shambler and CV.sh_rate:GetFloat() or 1
        if swing then
            local layer = self:AddGestureSequence(swing, true)
            if layer and rate ~= 1 then self:SetLayerPlaybackRate(layer, rate) end
        end

        self.hz_nextSwing = now + math.Rand(1.0, 1.5) / rate
        self.hz_hitAt = now + 0.4 / rate
    end

    if math.random() < 0.04 then HZ.Voice(self, "rage", 80) end
end

local function ClearTo(self, from, to)
    return not HullTrace(from + UP20, to + UP20, CLEAR_MINS, CLEAR_MAXS, MASK_NPCSOLID_BRUSHONLY, self).Hit
end

function ENT:HZ_LureStep(now, pos)
    local lure = HZ.LureFor(pos)
    if not lure then
        self.hz_lurePath, self.hz_lureFor = nil, nil
        return false
    end

    local lurePos = lure.pos
    self.hz_target, self.hz_lost, self.hz_unreach = nil, nil, nil
    self.hz_lastHasTarget = now
    local dist = pos:Distance(lurePos)
    local ahead = 0
    if dist < 220 then
        local distSqr = dist * dist
        HZ.Near(lurePos, dist, function(_, od2)
            if od2 < distSqr then ahead = ahead + 1 end
        end, self)
    end

    if dist < 60 or ahead >= 3 then
        self.hz_goal = nil
        self.loco:FaceTowards(lurePos)
        if now > (self.hz_nextLureHit or 0) then
            self.hz_nextLureHit = now + math.Rand(0.8, 2.0)
            local rate = self.hz_shambler and CV.sh_rate:GetFloat() or math.Rand(0.9, 1.15)
            self:HZ_PlayOnce(HZ.Pick(self.P.melee), rate, false, nil, lurePos)
        elseif self.hz_moveAnim then
            self:HZ_SetSeq(HZ.Pick(self.P.alert_idle))
        end

        return true
    end

    local goal
    if dist < 400 and math.abs(lurePos.z - pos.z) < 56 and ClearTo(self, pos, lurePos) then
        goal = lurePos
    else
        local path = self.hz_lurePath
        if not path or self.hz_lureFor ~= lure or now > (self.hz_lurePathT or 0) then
            path = path or Path("Follow")
            path:SetGoalTolerance(40)
            path:Compute(self, lurePos)
            self.hz_lurePath, self.hz_lureFor = path, lure
            self.hz_lurePathT = now + math.Rand(0.8, 1.4)
        end

        if path:IsValid() then
            path:MoveCursorToClosestPosition(pos)
            path:MoveCursor(80)
            goal = path:GetPositionOnPath(path:GetCursorPosition())
        else
            goal = lurePos
        end
    end

    local separation = HZ.Separation(self, pos)
    if separation then goal = goal + separation end
    self.hz_goal = goal
    if not self.hz_falling then self:HZ_SetMove("run") end

    return true
end

local function SolidOnly(ent)
    return not (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot())
end

local SPOT_DIRS = 12
local SPOT_MINS, SPOT_MAXS = Vector(-12, -12, 0), Vector(12, 12, 64)

local function ClimbSpots(target)
    local now = CurTime()
    local feet = target:GetPos()
    local cache = target.hz_climbSpots
    if cache and now - cache.t < 3 and cache.pos:DistToSqr(feet) < 48 * 48 then return cache.spots end

    local spots = {}
    for i = 0, SPOT_DIRS - 1 do
        local ang = math.rad(i * 360 / SPOT_DIRS)
        local dir = Vector(math.cos(ang), math.sin(ang), 0)
        local edge
        for step = 24, 360, 24 do
            local probe = feet + dir * step
            local wall = util.TraceLine({ start = feet + dir * (step - 24) + Vector(0, 0, 24),
                endpos = probe + Vector(0, 0, 24),
                mask = MASK_NPCSOLID, filter = SolidOnly })

            if wall.Hit then break end

            local tr = util.TraceLine({ start = probe + Vector(0, 0, 16), endpos = probe - Vector(0, 0, 24),
                mask = MASK_NPCSOLID,
                filter = SolidOnly })

            if not tr.Hit then
                edge = probe
                break
            end
        end

        if edge then
            local out = edge + dir * 16
            local tr = util.TraceLine({ start = out + Vector(0, 0, 8), endpos = out - Vector(0, 0, 400),
                mask = MASK_NPCSOLID,
                filter = SolidOnly })

            local height = tr.Hit and not tr.StartSolid and (feet.z - tr.HitPos.z)
            if height and height >= 24 and height <= 168 and tr.HitNormal.z > 0.7 then
                local stand = tr.HitPos + dir * 8
                local room = util.TraceHull({ start = stand + Vector(0, 0, 4), endpos = stand + Vector(0, 0, 5),
                    mins = SPOT_MINS, maxs = SPOT_MAXS, mask = MASK_NPCSOLID, filter = SolidOnly })

                if not room.Hit and not room.StartSolid then
                    spots[#spots + 1] = { pos = stand, top = edge - dir * 12 }
                end
            end
        end
    end

    target.hz_climbSpots = { t = now, pos = feet, spots = spots }

    return spots
end

function ENT:HZ_ClimbSpot(target)
    local spots = ClimbSpots(target)
    if #spots == 0 then return nil end

    local cur = self.hz_spot
    if cur then
        for _, spot in ipairs(spots) do
            if spot == cur then return cur end
        end
    end

    local pos = self:GetPos()
    local best, second, bestDist, secondDist
    local cap = self.hz_shambler and CV.sh_climb:GetFloat()
    for _, spot in ipairs(spots) do
        if spot ~= self.hz_badSpot and not (cap and spot.top.z - spot.pos.z > cap) then
            local distSqr = spot.pos:DistToSqr(pos)
            if not bestDist or distSqr < bestDist then
                best, second, secondDist, bestDist = spot, best, bestDist, distSqr
            elseif not secondDist or distSqr < secondDist then
                second, secondDist = spot, distSqr
            end
        end
    end

    self.hz_spot = (second and math.random() < 0.35) and second or best
    self.hz_spotFails = 0

    return self.hz_spot
end

function ENT:HZ_TargetLow(target)
    if not IsValid(target) then return false end
    if target:IsPlayer() and target:Crouching() then return true end

    local eye = target.EyePos and target:EyePos() or target:WorldSpaceCenter()

    return eye.z - target:GetPos().z < 48 or eye.z - self:GetPos().z < 40
end

function ENT:HZ_AttackSeq(target)
    local low = self:HZ_TargetLow(target)
    self.hz_attackLow = low
    local pool = (low and #self.P.attack_low > 0) and self.P.attack_low or self.P.melee
    self:HZ_SetSeq(HZ.Pick(pool), self.hz_shambler and CV.sh_rate:GetFloat() or 1)
end

function ENT:HZ_StartAttack(target)
    self.hz_attacking = true
    self.hz_goal = nil
    self.hz_target = target
    local rate = self.hz_shambler and CV.sh_rate:GetFloat() or 1
    self:HZ_AttackSeq(target)
    self.hz_nextLowCheck = CurTime() + 0.4
    self.hz_nextHit = CurTime() + 0.35 / rate
    HZ.Voice(self, "rageat", 80)
end

function ENT:HZ_AttackStep(now, target)
    if not HZ.IsHostile(target) then
        self.hz_attacking = nil
        self.hz_nextBrain = 0
        return
    end

    local pos, targetPos = self:GetPos(), target:GetPos()
    self.loco:FaceTowards(targetPos)
    if pos:DistToSqr(targetPos) > 75 * 75 or math.abs(targetPos.z - pos.z) > 60 then
        self.hz_attacking = nil
        self.hz_nextBrain = 0
        return
    end

    if now >= (self.hz_nextLowCheck or 0) then
        self.hz_nextLowCheck = now + 0.4
        if self:HZ_TargetLow(target) ~= self.hz_attackLow then self:HZ_AttackSeq(target) end
    end

    if now >= self.hz_nextHit then
        self.hz_nextHit = now + math.Rand(0.8, 1.1) / (self.hz_shambler and CV.sh_rate:GetFloat() or 1)
        self:HZ_TryHit(target, 72)
        if math.random() < 0.3 then HZ.Voice(self, "rageat", 78) end
    end
end

function ENT:HZ_HitDamage(target)
    local targetPos = target:GetPos()
    local attackers = 1
    HZ.Near(targetPos, 110, function(zombie)
        if not zombie.hz_dead and zombie.hz_target == target then
            attackers = attackers + 1
        end
    end, self)

    local full = math.max(2, CV.dmg_mob_n:GetInt())
    local frac = math.Clamp((attackers - 1) / (full - 1), 0, 1)
    local solo = math.Rand(CV.dmg_solo_lo:GetFloat(), math.max(CV.dmg_solo_lo:GetFloat(), CV.dmg_solo_hi:GetFloat()))
    local mob = math.Rand(CV.dmg_mob_lo:GetFloat(), math.max(CV.dmg_mob_lo:GetFloat(), CV.dmg_mob_hi:GetFloat()))

    return math.max(1, math.Round(Lerp(frac, solo, mob))), attackers
end

function ENT:HZ_TryHit(target, reach)
    if not HZ.IsHostile(target) then return end

    local center = self:WorldSpaceCenter()
    local to = target:WorldSpaceCenter() - center
    local dist = to:Length()
    if dist > reach or (dist > 1 and self:GetForward():Dot(to / dist) < 0.2) then
        HZ.Sound(self, "miss", 65)
        return
    end

    local hitDmg, attackers = self:HZ_HitDamage(target)
    local dmg = DamageInfo()
    dmg:SetDamage(hitDmg * (self.hz_shambler and CV.sh_damage:GetFloat() or 1))
    dmg:SetAttacker(self)
    dmg:SetInflictor(self)
    dmg:SetDamageType(DMG_SLASH)
    dmg:SetDamagePosition(target:WorldSpaceCenter())
    dmg:SetDamageForce(self:GetForward() * 2000)
    if HZ.ZCityHit then HZ.ZCityHit(self, target, dmg, attackers) end
    target:TakeDamageInfo(dmg)
    HZ.Sound(self, "hit", 72)
    if target:IsPlayer() then target:ViewPunch(Angle(math.Rand(-3, 3), math.Rand(-4, 4), math.Rand(-2, 2))) end
end

function ENT:HZ_Feel(pos, goal)
    local dx, dy = goal.x - pos.x, goal.y - pos.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 24 then return goal, false end

    dx, dy = dx / len, dy / len
    local from = pos + FEEL_UP
    local reach = math.min(FEEL_REACH, len)
    local ahead = LineTrace(from, from + Vector(dx * reach, dy * reach, 0), MASK_NPCSOLID, NO_ZOMBIES)
    if not ahead.Hit or ahead.StartSolid then return goal, false end

    local normal = ahead.HitNormal
    local cross = dx * normal.y - dy * normal.x
    local first = cross > 0.05 and 1 or (cross < -0.05 and -1 or (self.hz_flankSlot >= 0 and 1 or -1))
    for pass = 1, 2 do
        local side = pass == 1 and first or -first
        local sx = dx * FEEL_COS - dy * FEEL_SIN * side
        local sy = dy * FEEL_COS + dx * FEEL_SIN * side
        if not LineTrace(from, from + Vector(sx * FEEL_REACH, sy * FEEL_REACH, 0), MASK_NPCSOLID, NO_ZOMBIES).Hit then
            return Vector(pos.x + sx * FEEL_STEER, pos.y + sy * FEEL_STEER, goal.z), true
        end
    end

    return goal, true
end

function ENT:HZ_StuckCheck(now)
    if now < (self.hz_nextStuck or 0) then return end

    self.hz_nextStuck = now + 0.4
    local pos = self:GetPos()
    local last = self.hz_lastPos
    self.hz_lastPos = pos
    local goal = self.hz_goal
    if not last or not goal then
        self.hz_stuckSince = nil
        return
    end

    local need = math.max(self.loco:GetDesiredSpeed() * 0.16, 3)
    if last:Distance(goal) - pos:Distance(goal) > need or pos:DistToSqr(goal) < 1600 then
        self.hz_stuckSince = nil
        return
    end

    self.hz_stuckSince = self.hz_stuckSince or now
    local stuckTime = now - self.hz_stuckSince
    if stuckTime > 0.4 then
        if CV.climb:GetBool() and (self:HZ_TryVault() or self:HZ_TryClimb()) then
            self.hz_stuckSince = nil
            return
        end

        if self:HZ_TryObstacle() then
            self.hz_stuckSince = nil
            return
        end
    end

    if stuckTime > 1.5 and not self.hz_sideUntil then
        self.hz_sideOff = self:GetRight() * (math.random() < 0.5 and -70 or 70)
        self.hz_sideUntil = now + 0.8
    elseif self.hz_sideUntil and now > self.hz_sideUntil + 1 then
        self.hz_sideUntil = nil
    end

    if stuckTime > 6 then
        self.hz_stuckSince = nil
        if HZ.SeenByPlayers(pos, 400) then return end

        local area = HZ.Flow.AreaOf(self)
        local nextId = area and HZ.Flow.nxt[area:GetID()]
        local nextArea = nextId and HZ.Flow.Area(nextId)
        if nextArea and IsValid(nextArea) then
            local dest = nextArea:GetCenter() + Vector(0, 0, 4)
            local block = util.TraceHull({ start = pos + UP20, endpos = dest + UP20, mins = Vector(-12, -12, 0),
                maxs = Vector(12, 12, 40), mask = MASK_NPCSOLID, filter = NO_ZOMBIES }).Entity

            if IsValid(block) and (HZ.IsBarricade(block) or block:GetClass():find("door", 1, true)) then return end

            self:SetPos(dest)
            self.hz_ownMove = engine.TickCount()
            self.loco:ClearStuck()
        end
    end
end

function ENT:HZ_WallClimb(foot, top, vault)
    local pos = self:GetPos()
    local dir = Vector(top.x - foot.x, top.y - foot.y, 0)
    if dir:LengthSqr() < 1 then
        dir = self:GetForward()
        dir.z = 0
    end

    dir:Normalize()
    local side = Vector(-dir.y, dir.x, 0)
    local offset = pos - foot
    local along, lateral = offset:Dot(dir), offset:Dot(side)
    self.hz_climbLat = self.hz_climbLat or math.Rand(-70, 70)
    if along > -70 and math.abs(lateral) < 150 then
        self.hz_atWall = true
        local at = pos + dir * 100
        self.loco:FaceTowards(at)
        if (vault and self:HZ_TryVault(top)) or (not vault and self:HZ_TryClimb(at)) then
            self.hz_climbLat = nil
            return true
        end

        self.hz_climbLat = self.hz_climbLat * 0.6
    end

    return false, foot + side * self.hz_climbLat
end

local PROBES = { 30, 45, 60, 75, 90 }

function ENT:HZ_TryClimb(toward)
    local filter = NO_BODIES
    local pos = self:GetPos()
    local goal = toward or self.hz_goal
    if not goal then return false end

    local dir = goal - pos
    dir.z = 0
    if dir:LengthSqr() < 1 then return false end

    dir:Normalize()
    local tr, height
    for _, probeDist in ipairs(PROBES) do
        local probe = pos + dir * probeDist
        local ledgeTr = util.TraceHull({ start = probe + Vector(0, 0, 184), endpos = probe + Vector(0, 0, 16),
            mins = Vector(-8, -8, 0), maxs = Vector(8, 8, 4), mask = MASK_NPCSOLID, filter = filter })

        if ledgeTr.Hit and not ledgeTr.StartSolid then
            local topHeight = ledgeTr.HitPos.z - pos.z
            if topHeight >= 20 and topHeight <= 172 then
                tr, height = ledgeTr, topHeight
                break
            end
        end
    end

    if not tr then return false end
    if self.hz_shambler and height > CV.sh_climb:GetFloat() then return false end

    local upTr = util.TraceHull({ start = pos + Vector(0, 0, 8), endpos = pos + Vector(0, 0, height + 8),
        mins = Vector(-10, -10, 0), maxs = Vector(10, 10, 64), mask = MASK_NPCSOLID, filter = filter })

    if upTr.Hit then return false end

    local land = tr.HitPos
    local room = util.TraceHull({ start = land + Vector(0, 0, 2), endpos = land + Vector(0, 0, 3),
        mins = Vector(-12, -12, 0), maxs = Vector(12, 12, 68), mask = MASK_NPCSOLID, filter = filter })

    if room.StartSolid or room.Hit then return false end

    local best, bestDist
    for animHeight in pairs(self.P.climb) do
        local diff = math.abs(animHeight - height)
        if not bestDist or diff < bestDist then best, bestDist = animHeight, diff end
    end

    if not best then return false end

    self:SetAngles(Angle(0, dir:Angle().y, 0))
    local gravity, stepHeight = self.loco:GetGravity(), self.loco:GetStepHeight()
    self.loco:SetGravity(0)
    self.loco:SetStepHeight(0)
    self.loco:Jump()
    self.loco:SetVelocity(vector_origin)
    self:SetPos(self:GetPos() + Vector(0, 0, 1))
    self.hz_climbing = true
    self:HZ_PlayOnce(HZ.Pick(self.P.climb[best]), 1.25, true, height / best)
    self.hz_climbing = nil
    self.loco:SetStepHeight(stepHeight)
    self.loco:SetGravity(gravity)
    if self.hz_dead then return true end

    if self:GetPos():DistToSqr(land) > 18 * 18 then self:SetPos(land + Vector(0, 0, 2)) end
    self.hz_ownMove = engine.TickCount()
    self.loco:ClearStuck()
    self.hz_nextBrain = 0
    self.hz_moveAnim = nil

    return true
end

local VAULT_MIN, VAULT_MAX = 18, 62

function ENT:HZ_TryVault(toward)
    if not CV.climb:GetBool() then return false end

    local filter = NO_BODIES
    local pos = self:GetPos()
    local goal = toward or self.hz_goal
    if not goal or goal.z > pos.z + 40 then return false end

    local dir = goal - pos
    dir.z = 0
    if dir:LengthSqr() < 1 then return false end

    dir:Normalize()
    local front = util.TraceHull({ start = pos + Vector(0, 0, 20), endpos = pos + Vector(0, 0, 20) + dir * 40,
        mins = Vector(-10, -10, 0), maxs = Vector(10, 10, 8), mask = MASK_NPCSOLID, filter = filter })

    if not front.Hit or front.StartSolid then return false end

    local frontDist = front.Fraction * 40
    local height
    for ahead = frontDist + 14, frontDist + 50, 9 do
        local probe = pos + dir * ahead
        local topTr = util.TraceLine({ start = probe + Vector(0, 0, VAULT_MAX + 8), endpos = probe + Vector(0, 0, 4),
            mask = MASK_NPCSOLID, filter = filter })

        if topTr.StartSolid then return false end

        if topTr.Hit then
            local topHeight = topTr.HitPos.z - pos.z
            if not height or topHeight > height then height = topHeight end
        end
    end

    if not height or height < VAULT_MIN or height > VAULT_MAX then return false end
    if self.hz_shambler and height > CV.sh_climb:GetFloat() then return false end

    local land
    for ahead = frontDist + 34, frontDist + 120, 12 do
        local probe = pos + dir * ahead
        local landTr = util.TraceLine({ start = Vector(probe.x, probe.y, pos.z + height + 8),
            endpos = Vector(probe.x, probe.y, pos.z - 80),
            mask = MASK_NPCSOLID, filter = filter })

        if landTr.Hit and not landTr.StartSolid and landTr.HitPos.z <= pos.z + 20 and landTr.HitNormal.z > 0.7 then
            local room = util.TraceHull({ start = landTr.HitPos + Vector(0, 0, 2),
                endpos = landTr.HitPos + Vector(0, 0, 3),
                mins = Vector(-12, -12, 0), maxs = Vector(12, 12, 60), mask = MASK_NPCSOLID, filter = filter })

            local over = util.TraceHull({ start = pos + Vector(0, 0, height + 6),
                endpos = Vector(probe.x, probe.y, pos.z + height + 6),
                mins = Vector(-10, -10, 0), maxs = Vector(10, 10, 30), mask = MASK_NPCSOLID, filter = filter })

            if not room.Hit and not room.StartSolid and not over.Hit and not over.StartSolid then
                land = landTr.HitPos
                break
            end
        end
    end

    if not land then return false end

    local seq = HZ.Pick(self.P.vault)
    if not seq then return false end

    local ok, total = self:GetSequenceMovement(seq, 0, 1)
    local forward = (ok and total and total.x > 10) and total.x or 100

    self:SetAngles(Angle(0, dir:Angle().y, 0))
    local gravity, stepHeight = self.loco:GetGravity(), self.loco:GetStepHeight()
    self.loco:SetGravity(0)
    self.loco:SetStepHeight(0)
    self.loco:Jump()
    self.loco:SetVelocity(vector_origin)
    self:SetPos(self:GetPos() + Vector(0, 0, 1))
    self.hz_climbing = true
    self:HZ_RootPlay(seq, { rate = self.hz_shambler and 0.85 or 1.15, free = true,
        zscale = (height + 6) / 36, xyscale = math.Clamp((land - pos):Length2D() / forward, 0.6, 1.6) })

    self.hz_climbing = nil
    self.loco:SetStepHeight(stepHeight)
    self.loco:SetGravity(gravity)
    if self.hz_dead then return true end

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

function ENT:HZ_PoundDoor(door, at, dir, mat, bash)
    bash = bash or HZ.BashDoor
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
            if bash(door, self, dir, mat, at) then break end

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
    local tr = util.TraceLine({ start = pos, endpos = pos + dir * 48, mask = MASK_NPCSOLID, filter = NO_BODIES })
    local ent = tr.Entity
    if not IsValid(ent) or ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then return false end

    local class = ent:GetClass()
    if class:find("door", 1, true) then
        self:HZ_PoundDoor(ent, tr.HitPos, dir, tr.MatType)
        return true
    end

    if class == "func_breakable_surf" then
        self:HZ_PlayOnce(HZ.Pick(self.P.melee), 1.3, false, nil, tr.HitPos)
        if IsValid(ent) then
            ent:Fire("Shatter", "0.5 0.5 128")
            ent:EmitSound("physics/glass/glass_sheet_break" .. math.random(1, 3) .. ".wav", 80, math.random(95, 105))
        end

        self.hz_nextBrain = 0
        return true
    end

    if ent:GetMoveType() == MOVETYPE_VPHYSICS and HZ.IsBarricade(ent) then
        self:HZ_PoundDoor(ent, tr.HitPos, dir, tr.MatType, HZ.BashProp)
        return true
    end

    if ent:GetMoveType() == MOVETYPE_VPHYSICS or class:find("breakable", 1, true) then
        self:HZ_PlayOnce(HZ.Pick(self.P.melee), 1.3, false, nil, tr.HitPos)
        if not IsValid(ent) then return true end

        local dmgInfo = DamageInfo()
        dmgInfo:SetDamage(25)
        dmgInfo:SetAttacker(self)
        dmgInfo:SetInflictor(self)
        dmgInfo:SetDamageType(DMG_CLUB)
        dmgInfo:SetDamagePosition(tr.HitPos)
        ent:TakeDamageInfo(dmgInfo)
        local phys = ent:GetPhysicsObject()
        if IsValid(phys) then phys:ApplyForceOffset(dir * phys:GetMass() * 150, tr.HitPos) end
        self.hz_nextBrain = 0
        return true
    end

    return false
end

local SHOVE_DIRS = { [0] = "back", "fwd", "right", "left" }

function ENT:HZ_Shoved()
    local push = self.hz_shovePush or -self:GetForward()
    self.hz_shovePush = nil
    self:RemoveAllGestures()
    self.hz_attacking, self.hz_hitAt = nil, nil
    self.hz_nextSwing = CurTime() + 0.8
    self.hz_nextHit = CurTime() + 0.8
    local dir = SHOVE_DIRS[self:HZ_LocalDir(push)]
    local pools = self.P
    local seq
    if not self.hz_alerted and (self.hz_pose == "lie" or self.hz_pose == "chair") then
        if not self.hz_wakeAt then self.hz_wakeAt = CurTime() end
        return
    end

    if not self.hz_alerted and self.hz_pose == "sit" then
        local sitPool = (dir == "left" or dir == "right") and pools["shove_sit_" .. dir]
            or pools[math.random() < 0.5 and "shove_sit_left" or "shove_sit_right"]

        local sseq = HZ.Pick(sitPool)
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

    local pushDir = Vector(push.x, push.y, 0)
    pushDir:Normalize()
    local pos = self:GetPos()
    local wall = util.TraceHull({ start = pos + Vector(0, 0, 8), endpos = pos + Vector(0, 0, 8) + pushDir * 64,
        mins = Vector(-12, -12, 0), maxs = Vector(12, 12, 56), mask = MASK_NPCSOLID_BRUSHONLY, filter = self })

    if wall.Hit then seq = HZ.Pick(pools["shove_" .. dir .. "_wall"]) end
    if not seq and self.hz_shambler and dir == "back" and math.random() < CV.sh_knock:GetFloat() then
        seq = HZ.Pick(pools.knockdown)
    end

    seq = seq or HZ.Pick(pools["shove_" .. dir]) or HZ.Pick(pools.shove_back)
    if not seq then return end

    HZ.Voice(self, "shoved", 75)
    self.hz_inShove = true
    local result, tr = self:HZ_PlayOnce(seq, 1.1, true, 1, nil, true, not wall.Hit)
    if result == "wall" then
        local impostor = HZ.Pick(pools["shove_" .. dir .. "_wall"]) or HZ.Pick(pools.shove_back_wall)
        self:EmitSound("physics/body/body_medium_impact_hard" .. math.random(1, 6) .. ".wav", 70, math.random(90, 105))
        if tr and tr.Entity and IsValid(tr.Entity) and tr.Entity:GetClass():find("door", 1, true) == nil then
            local phys = tr.Entity:GetPhysicsObject()
            if IsValid(phys) then phys:ApplyForceOffset(pushDir * 4000, tr.HitPos) end
        end

        if impostor then self:HZ_PlayOnce(impostor, 1.1, true, 1, nil, true) end
    end

    self.hz_inShove = nil
    self.hz_nextBrain = 0
    if not self.hz_alerted and not self.hz_wakeAt then self.hz_wakeAt = CurTime() end
end

function ENT:HZ_StaggerPush(dmg)
    local pos = self:GetPos()
    if dmg:IsExplosionDamage() then
        local away = pos - dmg:GetDamagePosition()
        return away:LengthSqr() > 1 and away or dmg:GetDamageForce()
    end

    if dmg:IsDamageType(bit.bor(DMG_CRUSH, DMG_VEHICLE)) then
        if dmg:GetDamage() < 10 then return end

        local force = dmg:GetDamageForce()
        if force:LengthSqr() > 1 then return force end

        local inflictor = dmg:GetInflictor()
        return IsValid(inflictor) and (pos - inflictor:GetPos()) or nil
    end

    local attacker = HZ.MeleeAttacker(self, dmg)
    if attacker then return pos - attacker:GetPos() end
end

function ENT:OnTraceAttack(dmg, dir, tr)
    if tr.HitGroup == HITGROUP_HEAD and self.hz_hsTick ~= engine.TickCount() then
        self.hz_hsTick = engine.TickCount()
        dmg:ScaleDamage(CV.headshot:GetFloat())
    elseif self.hz_shambler and tr.HitGroup ~= HITGROUP_HEAD and CV.sh_head:GetBool() then
        dmg:ScaleDamage(0.1)
    end

    local tick = engine.TickCount()
    if self.hz_pelletTick == tick then
        self.hz_pellets = self.hz_pellets + 1
    else
        self.hz_pelletTick, self.hz_pellets = tick, 1
    end
end

function ENT:HZ_DeathKind(dmg)
    local tick = engine.TickCount()
    if dmg:IsExplosionDamage()
        or dmg:IsDamageType(bit.bor(DMG_CRUSH, DMG_VEHICLE, DMG_FALL, DMG_BLAST, DMG_SONIC, DMG_DISSOLVE))
        or dmg:GetDamageForce():Length() > 60000 or self.hz_climbing or not self.loco:IsOnGround()
        or (self.hz_pose and self.hz_pose ~= "stand" and self.hz_pose ~= "wander") then
        return HZ.DEATH_RAGDOLL
    end

    if dmg:IsDamageType(DMG_BUCKSHOT) or (self.hz_pelletTick == tick and (self.hz_pellets or 0) >= 3) then
        return HZ.DEATH_SHOTGUN
    end

    local spd = math.max(self.loco:GetVelocity():Length2D(), self.hz_wpVel and self.hz_wpVel:Length() or 0)
    if spd > 150 then return HZ.DEATH_RUN end
    if spd > 20 then return HZ.DEATH_WALK end
    if self.hz_hsTick == tick then return HZ.DEATH_HEAD end
    if dmg:IsDamageType(DMG_SLASH) then return HZ.DEATH_SLASH end
    if dmg:IsDamageType(DMG_CLUB) then return HZ.DEATH_CLUB end

    return HZ.DEATH_STAND
end

function ENT:HZ_PushDir(dmg)
    local push = dmg:GetDamageForce()
    if push:LengthSqr() < 1 then
        local attacker = dmg:GetAttacker()
        push = IsValid(attacker) and (self:GetPos() - attacker:GetPos()) or -self:GetForward()
    end

    return self:HZ_LocalDir(push)
end

function ENT:HZ_LocalDir(push)
    local forward, side = push:Dot(self:GetForward()), push:Dot(self:GetRight())
    if math.abs(forward) >= math.abs(side) then return forward >= 0 and 1 or 0 end

    return side >= 0 and 2 or 3
end

function ENT:OnInjured(dmg)
    if self:Health() <= 0 then
        if not self.hz_dead then self:OnKilled(dmg) end
        return
    end

    local now = CurTime()
    local attacker = dmg:GetAttacker()
    if HZ.IsHostile(attacker) then
        self.hz_aggro = attacker
        self.hz_aggroUntil = now + 6
    end

    if not self.hz_alerted then
        self.hz_wakeStartled = true
        self.hz_wakeAt = now
        self.hz_wakeSrc = attacker
    end

    local push = not self.hz_inShove and not self.hz_climbing and self:HZ_StaggerPush(dmg)
    if push then
        self.hz_shove = true
        self.hz_shovePush = push
    elseif dmg:GetDamage() >= 8 and now > (self.hz_nextFlinch or 0) then
        local flinch = HZ.Pick(self.P.flinch)
        if flinch then self:AddGestureSequence(flinch, true) end
        self.hz_nextFlinch = now + 1.5
    end

    if dmg:IsDamageType(bit.bor(DMG_BURN, DMG_SLOWBURN)) then
        self:HZ_Ignite(attacker)
        if not self.hz_burnVoiced then
            self.hz_burnVoiced = true
            HZ.Voice(self, "ignite", 80, true)
        end
    elseif math.random() < 0.35 then
        HZ.Voice(self, "shot", 75)
    end
end

function ENT:OnKilled(dmg)
    if self.hz_dead then return end

    self.hz_dead = true
    HZ.LastDeath = CurTime()
    timer.Simple(0.3, function()
        if IsValid(self) then self:Remove() end
    end)

    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    HZ.Unregister(self)
    local owner = self.hz_owner
    if IsValid(owner) and owner.HZ_OnZombieDied then owner:HZ_OnZombieDied(self) end
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
    hook.Run("OnNPCKilled", self, dmg:GetAttacker(), dmg:GetInflictor())
end

function ENT:OnStuck()
end

function ENT:OnUnStuck()
end
