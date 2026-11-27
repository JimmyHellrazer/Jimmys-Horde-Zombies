local maxRags = CreateClientConVar("hz_ragdoll_max", "24", true, false, "Max ragdolls")
local ragTime = CreateClientConVar("hz_ragdoll_time", "25", true, false, "Ragdoll lifetime (s)")
CreateClientConVar("hz_show_markers", "0", true, false, "Always show director and spawner markers")

local rags = {}
local ragPool, ragPoolCount = {}, 0
local RAG_POOL_MAX = 48
local csmPool, csmPoolCount = {}, 0
local CSM_POOL_MAX = 24
local physBones = {}

local M = HZ.Math
local CopyBoneSafe, CopyBone, MatrixPos = M.CopyBoneSafe, M.CopyBone, M.MatrixPos
local sqrt = math.sqrt
local cvDebug = GetConVar("hz_debug")
local boneMat, boneMatB = Matrix(), Matrix()

local function CachePhysBones(rag, mdl)
    local ragBones = physBones[mdl]
    if ragBones then return ragBones end

    ragBones = {}
    for i = 0, rag:GetPhysicsObjectCount() - 1 do ragBones[i + 1] = rag:TranslatePhysBoneToBone(i) or -1 end
    physBones[mdl] = ragBones

    return ragBones
end

local burning = {}

local function StopBurn(ent)
    for i = #burning, 1, -1 do
        local burn = burning[i]
        if burn.ent == ent then
            if burn.snd then burn.snd:FadeOut(0.4) end
            table.remove(burning, i)
        end
    end
end

local function ParkRagdoll(rag)
    StopBurn(rag)
    rag:SetNoDraw(true)
    rag:DrawShadow(false)
    rag:DestroyShadow()
    HZ.SetFace(rag, nil)
    for i = 0, rag:GetPhysicsObjectCount() - 1 do
        local phys = rag:GetPhysicsObjectNum(i)
        if IsValid(phys) then
            phys:EnableMotion(false)
            phys:EnableCollisions(false)
            phys:SetVelocity(vector_origin)
            if phys.SetAngleVelocityInstantaneous then phys:SetAngleVelocityInstantaneous(vector_origin) end
            phys:Sleep()
        end
    end
end

local function ReleaseRagdoll(rag, mdl)
    if not IsValid(rag) then return end

    mdl = mdl or rag:GetModel()
    if mdl and ragPoolCount < RAG_POOL_MAX then
        ParkRagdoll(rag)
        local bucket = ragPool[mdl]
        if not bucket then
            bucket = {}
            ragPool[mdl] = bucket
        end

        bucket[#bucket + 1] = rag
        ragPoolCount = ragPoolCount + 1
    else
        rag:Remove()
    end
end

function HZ.SeedRagdollPool(mdl, rag)
    if not IsValid(rag) then return end

    CachePhysBones(rag, mdl)
    ReleaseRagdoll(rag, mdl)
end

local function AcquireRagdoll(mdl)
    local bucket = ragPool[mdl]
    if bucket then
        while #bucket > 0 do
            local rag = bucket[#bucket]
            bucket[#bucket] = nil
            ragPoolCount = ragPoolCount - 1
            if IsValid(rag) then return rag, true end
        end
    end

    return ClientsideRagdoll(mdl), false
end

local function PruneRagdolls()
    local now = CurTime()
    local gone = 0
    for i = #rags, 1, -1 do
        local rag = rags[i]
        if not IsValid(rag.ent) then gone = gone + 1 end
        if not IsValid(rag.ent) or now > rag.die then
            ReleaseRagdoll(rag.ent, rag.mdl)
            table.remove(rags, i)
        end
    end

    if gone > 0 and cvDebug:GetBool() then
        print(("[hordez] %d zombie bodies were removed by something else (not the timer or the cap)"):format(gone))
    end

    while #rags > maxRags:GetInt() do
        local rag = table.remove(rags, 1)
        ReleaseRagdoll(rag.ent, rag.mdl)
    end
end

timer.Create("hordez_rags", 1, 0, PruneRagdolls)

local deathAnims = CreateClientConVar("hz_death_anims", "1", true, false, "Death animations")

local deathDist = CreateClientConVar("hz_death_anim_dist", "1500", true, false, "Death animations within")

local deathMax = CreateClientConVar("hz_death_anim_max", "10", true, false, "Max death animations at once")

local sourceBones = {}

local function SourceBones(rag, mdl, src, ragBones)
    local srcModel = src:GetModel()
    if srcModel == mdl then return ragBones end

    local key = mdl .. "|" .. srcModel
    local list = sourceBones[key]
    if list then return list end

    list = {}
    for i, bone in ipairs(ragBones) do
        local name = bone >= 0 and rag:GetBoneName(bone)
        list[i] = name and src:LookupBone(name) or -1
    end

    sourceBones[key] = list

    return list
end

local function MakeRagdoll(src, mdl, skin, groups, baseVel, push, vels)
    local t0 = HZ.ProfOn and SysTime()
    local rag, pooled = AcquireRagdoll(mdl)
    if not IsValid(rag) then return end

    local ragBones = SourceBones(rag, mdl, src, CachePhysBones(rag, mdl))

    rag:SetSkin(skin)
    rag:SetColor(src:GetColor())
    HZ.SetFace(rag, src.hz_look)
    for i, value in pairs(groups) do rag:SetBodygroup(i, value) end
    rag:SetPos(src:GetPos())
    rag:SetAngles(src:GetAngles())
    src:SetupBones()
    for i = 0, rag:GetPhysicsObjectCount() - 1 do
        local phys = rag:GetPhysicsObjectNum(i)
        local bone = ragBones[i + 1]
        local mat = CopyBoneSafe(src, bone, boneMat)
        if IsValid(phys) then
            if pooled then
                phys:EnableCollisions(true)
                phys:EnableMotion(true)
            end

            if mat then
                phys:SetPos(mat:GetTranslation())
                phys:SetAngles(mat:GetAngles())
            else
                phys:SetPos(src:GetPos() + Vector(0, 0, 36))
            end

            local vel = (vels and bone and vels[bone] or baseVel) + push
            if phys.SetVelocityInstantaneous then
                phys:SetVelocityInstantaneous(vel)
            else
                phys:SetVelocity(vel)
            end

            if phys.SetAngleVelocityInstantaneous then phys:SetAngleVelocityInstantaneous(vector_origin) end
            phys:Wake()
        end
    end

    rag:SetNoDraw(false)
    rag:DrawShadow(true)
    rags[#rags + 1] = { ent = rag, mdl = mdl, die = CurTime() + ragTime:GetFloat() }
    PruneRagdolls()
    if t0 then HZ.ProfAdd("cl_ragdoll", SysTime() - t0) end

    return rag
end

local dying = {}
local poolCache = {}
local DIRS = { [0] = "back", "fwd", "right", "left" }

local function ResolveSequences(modelEnt, names)
    local ids = {}
    for _, name in ipairs(names or {}) do
        local id = modelEnt:LookupSequence(name)
        if id and id >= 0 then ids[#ids + 1] = { id = id, name = name } end
    end

    return ids
end

local function DeathPools(modelEnt)
    local mdl = modelEnt:GetModel()
    local cache = poolCache[mdl]
    if cache then return cache end

    cache = {}
    for kind, value in pairs(HZ.DeathPools) do
        if value[1] then
            cache[kind] = ResolveSequences(modelEnt, value)
        else
            cache[kind] = {}
            for dir, names in pairs(value) do cache[kind][dir] = ResolveSequences(modelEnt, names) end
        end
    end

    poolCache[mdl] = cache

    return cache
end

local function PickDeath(pools, kind, dir)
    local side = DIRS[dir] or "back"

    local function By(set)
        return set and set[side]
    end

    local cands
    if kind == HZ.DEATH_WALK then
        cands = #pools.walk > 0 and pools.walk or pools.stand.fwd
    elseif kind == HZ.DEATH_RUN then
        cands = pools.run
    elseif kind == HZ.DEATH_HEAD then
        cands = pools.head[side == "fwd" and "fwd" or "back"]
    elseif kind == HZ.DEATH_SHOTGUN then
        cands = By(pools.shotgun)
    elseif kind == HZ.DEATH_CLUB then
        cands = By(pools.club)
    elseif kind == HZ.DEATH_SLASH then
        cands = By(pools.slash)
    end

    if not cands or #cands == 0 then
        local secondDist = (side == "fwd" and "fwd") or (side == "back" and math.random() < 0.6 and "back") or "drop"
        cands = pools.stand[secondDist]
        if #cands == 0 then cands = pools.stand.drop end
    end

    return HZ.Pick(cands)
end

local FilterChars = function(ent)
    return not (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:IsRagdoll())
end

local PELVIS_MINS, PELVIS_MAXS = Vector(-5, -5, -5), Vector(5, 5, 5)

local function ReleaseDeathModel(csm, mdl, kicks)
    if not IsValid(csm) then return end

    StopBurn(csm)
    csm.hz_death = nil
    csm.RenderOverride = nil
    if HZ.ReleaseOverlay then
        HZ.ReleaseOverlay(csm)
    elseif IsValid(csm.hz_overlay) then
        csm.hz_overlay:Remove()
        csm.hz_overlay = nil
    end

    if kicks then
        for bone in pairs(kicks) do csm:ManipulateBoneAngles(bone, angle_zero) end
    end

    mdl = mdl or csm:GetModel()
    if mdl and csmPoolCount < CSM_POOL_MAX then
        csm:SetNoDraw(true)
        csm:DrawShadow(false)
        csm:DestroyShadow()
        HZ.SetFace(csm, nil)
        local bucket = csmPool[mdl]
        if not bucket then
            bucket = {}
            csmPool[mdl] = bucket
        end

        bucket[#bucket + 1] = csm
        csmPoolCount = csmPoolCount + 1
    else
        csm:Remove()
    end
end

function HZ.SeedDeathModelPool(mdl, csm)
    if not IsValid(csm) then return end

    ReleaseDeathModel(csm, mdl)
end

local function FinishDeath(death)
    local vels
    if death.hasPrev and death.dt > 0 then
        vels = {}
        local model, bones, px, py, pz, inv = death.csm, death.bones, death.px, death.py, death.pz, 1 / death.dt
        for i = 1, #bones do
            local x0 = px[i]
            if x0 and CopyBoneSafe(model, bones[i], boneMat) then
                local x, y, z = MatrixPos(boneMat)
                local vx, vy, vz = (x - x0) * inv, (y - py[i]) * inv, (z - pz[i]) * inv
                local speedSqr = vx * vx + vy * vy + vz * vz
                if speedSqr > 640000 then
                    local scale = 800 / sqrt(speedSqr)
                    vx, vy, vz = vx * scale, vy * scale, vz * scale
                end

                vels[bones[i]] = Vector(vx, vy, vz)
            end
        end
    end

    local rag = MakeRagdoll(death.csm, death.custom or death.mdl, death.custom and 0 or death.skin,
        death.custom and {} or death.groups, vector_origin, vector_origin, vels)
    if IsValid(rag) then HZ.MoveBurn(death.csm, rag) end
    ReleaseDeathModel(death.csm, death.mdl, death.kicks)
    death.csm = nil

    return rag
end

local BLEND = 0.2

local function BlendBones(ent, boneCount)
    local death = ent.hz_death
    local from = death and death.from
    if not from then return end

    local weight = (CurTime() - death.t0) / BLEND
    if weight >= 1 then
        death.from = nil
        return
    end

    weight = weight * weight * (3 - 2 * weight)
    local blend, setBone = M.BlendFrom, ent.SetBoneMatrix
    for i = 0, boneCount - 1 do
        local base = i * 7
        local px = from[base + 1]
        if px and CopyBone(ent, i, boneMat) then
            blend(boneMat, px, from[base + 2], from[base + 3], from[base + 4], from[base + 5], from[base + 6],
                from[base + 7], weight)

            setBone(ent, i, boneMat)
        end
    end
end

local trackCache = {}

local function TrackedBones(ent, mdl)
    local cache = trackCache[mdl]
    if cache then return cache.bones, cache.pelvis end

    local pelvis = ent:LookupBone("ValveBiped.Bip01_Pelvis")
    local ragBones = physBones[mdl]
    local bones, seen, pelvisAt = {}, {}, nil
    if ragBones then
        for i = 1, #ragBones do
            local bone = ragBones[i]
            if bone >= 0 and not seen[bone] then
                seen[bone] = true
                bones[#bones + 1] = bone
            end
        end

        if pelvis and not seen[pelvis] then bones[#bones + 1] = pelvis end
    else
        for bone = 0, ent:GetBoneCount() - 1 do bones[#bones + 1] = bone end
    end

    for i = 1, #bones do
        if bones[i] == pelvis then
            pelvisAt = i
            break
        end
    end

    if ragBones then trackCache[mdl] = { bones = bones, pelvis = pelvisAt } end

    return bones, pelvisAt
end

local function AcquireDeathModel(mdl)
    local bucket = csmPool[mdl]
    if bucket then
        while #bucket > 0 do
            local csm = bucket[#bucket]
            bucket[#bucket] = nil
            csmPoolCount = csmPoolCount - 1
            if IsValid(csm) then
                csm:SetNoDraw(false)
                return csm
            end
        end
    end

    local csm = ClientsideModel(mdl, RENDERGROUP_OPAQUE)
    if IsValid(csm) then csm:SetIK(false) end

    return csm
end

local function StartDeath(ent, kind, dir, groups, vel, custom)
    if not deathAnims:GetBool() or kind == HZ.DEATH_RAGDOLL or #dying >= deathMax:GetInt() then return false end
    if ent:GetPos():DistToSqr(EyePos()) > deathDist:GetFloat() ^ 2 then return false end

    local pools = DeathPools(ent)
    local pick = PickDeath(pools, kind, dir)
    if not pick then return false end

    local mdl = ent:GetModel()
    local t0 = HZ.ProfOn and SysTime()
    local deathModel = AcquireDeathModel(mdl)
    if not IsValid(deathModel) then return false end

    if custom then
        deathModel.RenderOverride = function(self, flags)
            HZ.DrawCustom(self, custom, flags)
        end
    else
        deathModel.RenderOverride = nil
    end

    deathModel:SetSkin(ent:GetSkin())
    deathModel:SetColor(ent:GetColor())
    HZ.SetFace(deathModel, ent.hz_look)
    for i, value in pairs(groups) do deathModel:SetBodygroup(i, value) end
    deathModel:SetPos(ent:GetPos())
    deathModel:SetAngles(Angle(0, ent:GetAngles().y, 0))
    deathModel:ResetSequence(pick.id)
    deathModel:SetCycle(0)
    deathModel:SetPlaybackRate(0)
    deathModel:SetRenderBounds(Vector(-80, -80, -8), Vector(80, 80, 80))
    deathModel:DrawShadow(true)

    local from = {}
    ent:SetupBones()
    local posQuat = M.MatrixPosQuat
    for i = 0, ent:GetBoneCount() - 1 do
        local base = i * 7
        from[base + 1] = false
        if CopyBoneSafe(ent, i, boneMat) then
            local px, py, pz, qx, qy, qz, qw = posQuat(boneMat)
            if px then
                from[base + 1], from[base + 2], from[base + 3], from[base + 4], from[base + 5], from[base + 6],
                    from[base + 7] = px, py, pz, qx, qy, qz, qw
            end
        end
    end

    local dur = math.max(deathModel:SequenceDuration(pick.id), 0.1)
    local stop = dur
    local ends = HZ.DeathEnds[pick.name]
    if ends and math.random() < 0.75 then stop = math.min(HZ.Pick(ends) / 30, dur) end
    stop = math.min(stop, 2.5)

    local bones, pelvisAt = TrackedBones(deathModel, mdl)
    dying[#dying + 1] = {
        csm = deathModel, mdl = mdl, custom = custom, skin = ent:GetSkin(), groups = groups,
        t0 = CurTime(), dur = dur, stop = stop, dt = 0, nextStep = 0, lastSample = CurTime(),
        seq = pick.id, lastCyc = 0, yaw = Angle(0, ent:GetAngles().y, 0),
        carry = Vector(vel.x, vel.y, 0) * ((kind == HZ.DEATH_SHOTGUN and 0.15)
            or ((kind == HZ.DEATH_RUN or kind == HZ.DEATH_WALK) and 0.5) or 1),
        bones = bones, pelvisAt = pelvisAt, px = {}, py = {}, pz = {},
        hits = 0, blast = 0, from = from,
    }

    deathModel.hz_death = dying[#dying]
    if not deathModel.hz_blendHook then
        deathModel.hz_blendHook = true
        deathModel:AddCallback("BuildBonePositions", BlendBones)
    end

    deathModel:SetupBones()
    if t0 then HZ.ProfAdd("cl_death_start", SysTime() - t0) end

    return true
end

local groundStart, groundEnd, moveVec, newPosVec = Vector(), Vector(), Vector(), Vector()
local groundTr, pelvisTr = {}, {}
local groundIn = { start = groundStart, endpos = groundEnd, mask = MASK_NPCSOLID_BRUSHONLY, output = groundTr }
local pelvisIn = { start = Vector(), endpos = Vector(), mins = PELVIS_MINS, maxs = PELVIS_MAXS, mask = MASK_SOLID,
    filter = FilterChars, output = pelvisTr }

local kickAng = Angle()
local DEATH_STEP = 1 / 45

local function StepDying(death, now)
    local model = death.csm
    local elapsed = now - death.t0
    local finishing = elapsed >= death.stop
    local sample = finishing or now >= death.nextStep

    local mx, my = 0, 0
    local carry = death.carry
    if carry then
        local decay = math.exp(-4 * elapsed)
        local cx, cy = carry.x * decay, carry.y * decay
        if cx * cx + cy * cy < 4 then
            death.carry = nil
        else
            local dt = FrameTime()
            mx, my = cx * dt, cy * dt
        end
    end

    local cycle = math.min(elapsed, death.stop) / death.dur
    if cycle > death.lastCyc then
        local ok, rootMove = model:GetSequenceMovement(death.seq, death.lastCyc, cycle)
        if ok and rootMove then
            rootMove.z = 0
            rootMove:Rotate(death.yaw)
            mx, my = mx + rootMove.x, my + rootMove.y
        end

        death.lastCyc = cycle
    end

    if mx * mx + my * my > 0.0001 then
        local cur = model:GetPos()
        local nx, ny, nz = cur.x + mx, cur.y + my, cur.z
        if sample then
            groundStart:SetUnpacked(nx, ny, nz + 18)
            groundEnd:SetUnpacked(nx, ny, nz - 30)
            util.TraceLine(groundIn)
            if groundTr.Hit and not groundTr.StartSolid then
                nz = groundTr.HitPos.z
            else
                death.offLedge = true
            end
        end

        newPosVec:SetUnpacked(nx, ny, nz)
        model:SetPos(newPosVec)
    end

    if death.kicks then
        for bone, kick in pairs(death.kicks) do
            local frac = 1 - (now - kick.t0) / kick.len
            if frac <= 0 then
                model:ManipulateBoneAngles(bone, angle_zero)
                death.kicks[bone] = nil
            else
                kickAng:Zero()
                kickAng:RotateAroundAxis(kick.axis, kick.amp * frac * frac)
                model:ManipulateBoneAngles(bone, kickAng)
            end
        end
    end

    if not sample then
        model:SetCycle(cycle)
        return false
    end

    death.nextStep = now + DEATH_STEP
    model:MarkShadowAsDirty()

    local bones, px, py, pz = death.bones, death.px, death.py, death.pz
    for i = 1, #bones do
        if CopyBoneSafe(model, bones[i], boneMat) then
            px[i], py[i], pz[i] = MatrixPos(boneMat)
        else
            px[i] = false
        end
    end

    local pelvisAt = death.pelvisAt
    local lastPelvis = pelvisAt and px[pelvisAt]

    model:SetCycle(cycle)
    model:InvalidateBoneCache()
    model:SetupBones()
    local hit = false
    if lastPelvis and CopyBone(model, bones[pelvisAt], boneMat) then
        pelvisIn.start:SetUnpacked(lastPelvis, py[pelvisAt], pz[pelvisAt])
        pelvisIn.endpos:SetUnpacked(MatrixPos(boneMat))
        util.TraceHull(pelvisIn)
        hit = pelvisTr.Hit and not pelvisTr.StartSolid
    end

    death.hasPrev, death.dt, death.lastSample = true, now - death.lastSample, now

    return finishing or hit or death.offLedge
end

local reported = {}

local function ReportOnce(where, err)
    if reported[where] then return end

    reported[where] = true
    ErrorNoHalt("[hordez] death animation error in " .. where .. " (body handed off): " .. tostring(err) .. "\n")
end

local function SafeFinish(death)
    local ok, result = pcall(FinishDeath, death)
    if not ok then ReportOnce("hand-off", result) end
    if IsValid(death.csm) then ReleaseDeathModel(death.csm, death.mdl, death.kicks) end

    return ok and result or nil
end

hook.Add("Think", "hordez_dying", function()
    if #dying == 0 then return end

    local t0 = HZ.ProfOn and SysTime()
    local now = CurTime()
    for i = #dying, 1, -1 do
        local death = dying[i]
        if not IsValid(death.csm) then
            table.remove(dying, i)
        else
            local ok, done = pcall(StepDying, death, now)
            if not ok then ReportOnce("update", done) end
            if not ok or done or now - death.t0 > death.stop + 2 then
                table.remove(dying, i)
                SafeFinish(death)
            end
        end
    end

    if t0 then HZ.ProfAdd("cl_death_step", SysTime() - t0) end
end)

function HZ.ProfClientStats()
    return { rags = #rags, ragPool = ragPoolCount, dying = #dying, csmPool = csmPoolCount }
end

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
    local custom = ent.hz_custom
    if StartDeath(ent, kind, dir, groups, vel, custom) then
        body = dying[#dying].csm
    else
        local push = force * 0.012
        if push:Length() > 600 then push = push:GetNormalized() * 600 end
        body = MakeRagdoll(ent, custom or ent:GetModel(), custom and 0 or ent:GetSkin(), custom and {} or groups, vel,
            push)
    end

    if onFire and IsValid(body) then HZ.StartBurn(body) end
    ent.hz_nodraw = true
    ent:SetNoDraw(true)
    ent:DrawShadow(false)
end)

local burnMax = CreateClientConVar("hz_burn_max", "10", true, false, "Max burning bodies")
local FLAME_BONES = { "Bip01_Pelvis", "Bip01_Spine2", "Bip01_Head1", "Bip01_L_Forearm", "Bip01_R_Forearm",
    "Bip01_L_UpperArm", "Bip01_R_UpperArm", "Bip01_L_Thigh", "Bip01_R_Thigh", "Bip01_L_Calf", "Bip01_R_Calf" }

local flameBoneCache = {}
local emitter
local BODY_BURN = 7
HZ.PrecacheSound("ambient/fire/fire_small_loop1.wav")
HZ.PrecacheSound("ambient/fire/fire_small_loop2.wav")

local function FlameBones(ent)
    local mdl = ent:GetModel()
    local cache = flameBoneCache[mdl]
    if cache then return cache end

    cache = {}
    for _, name in ipairs(FLAME_BONES) do
        local bone = ent:LookupBone("ValveBiped." .. name)
        if bone then cache[#cache + 1] = bone end
    end

    flameBoneCache[mdl] = cache

    return cache
end

local function BurnSound(burn)
    if burn.snd then burn.snd:Stop() end
    burn.snd = CreateSound(burn.ent, "ambient/fire/fire_small_loop" .. math.random(1, 2) .. ".wav")
    burn.snd:PlayEx(0.5, math.random(95, 105))
end

function HZ.StartBurn(ent)
    if #burning >= burnMax:GetInt() then
        local col = ent:GetColor()
        ent:SetColor(Color(col.r * 0.45, col.g * 0.42, col.b * 0.4))
        return
    end

    local now = CurTime()
    local burn = { ent = ent, t0 = now, untilT = now + BODY_BURN * math.Rand(0.8, 1.2), base = ent:GetColor(),
        next = 0 }

    BurnSound(burn)
    burning[#burning + 1] = burn
end

function HZ.MoveBurn(from, to)
    for _, burn in ipairs(burning) do
        if burn.ent == from then
            burn.ent, burn.step = to, nil
            BurnSound(burn)
            return
        end
    end
end

local burnCol, partVel = Color(255, 255, 255), Vector()

hook.Add("Think", "hordez_burning", function()
    if #burning == 0 then return end

    local now = CurTime()
    local eye = EyePos()
    for i = #burning, 1, -1 do
        local burn = burning[i]
        local ent = burn.ent
        if not IsValid(ent) or now > burn.untilT + 1.5 then
            if burn.snd then burn.snd:FadeOut(0.8) end
            table.remove(burning, i)
        else
            local frac = math.Clamp((now - burn.t0) / (burn.untilT - burn.t0), 0, 1)
            local fade = 1 - 0.55 * frac
            local step = math.floor(fade * 255)
            if step ~= burn.step then
                burn.step = step
                burnCol.r, burnCol.g, burnCol.b = burn.base.r * fade, burn.base.g * fade * 0.95, burn.base.b * fade * 0.9
                ent:SetColor(burnCol)
            end

            if now > burn.untilT and burn.snd then
                burn.snd:FadeOut(1.2)
                burn.snd = nil
            end

            if now < burn.untilT and now >= burn.next and ent:GetPos():DistToSqr(eye) < 2500 * 2500 then
                burn.next = now + 0.05
                emitter = emitter or ParticleEmitter(vector_origin)
                emitter:SetPos(ent:GetPos())
                local bones = FlameBones(ent)
                local strength = 1 - frac * 0.7
                for _ = 1, 2 do
                    local mat = CopyBoneSafe(ent, HZ.Pick(bones) or 0, boneMat)
                    if mat then
                        local particle = emitter:Add("particles/flamelet" .. math.random(1, 5),
                            mat:GetTranslation() + VectorRand() * 4)

                        if particle then
                            partVel:SetUnpacked(math.Rand(-8, 8), math.Rand(-8, 8), math.Rand(30, 60))
                            particle:SetVelocity(partVel)
                            particle:SetDieTime(math.Rand(0.35, 0.6))
                            particle:SetStartAlpha(230)
                            particle:SetEndAlpha(0)
                            particle:SetStartSize(math.Rand(7, 12) * strength)
                            particle:SetEndSize(1)
                            particle:SetRoll(math.Rand(0, 360))
                            particle:SetRollDelta(math.Rand(-2, 2))
                        end
                    end
                end

                if math.random() < 0.15 then
                    local mat = CopyBoneSafe(ent, HZ.Pick(bones) or 0, boneMat)
                    local particle = mat
                        and emitter:Add("particle/smokesprites_000" .. math.random(1, 9), mat:GetTranslation())

                    if particle then
                        partVel:SetUnpacked(0, 0, math.Rand(25, 45))
                        particle:SetVelocity(partVel)
                        particle:SetDieTime(math.Rand(1.2, 2))
                        particle:SetStartAlpha(70)
                        particle:SetEndAlpha(0)
                        particle:SetStartSize(8)
                        particle:SetEndSize(26)
                        particle:SetColor(40, 38, 36)
                        particle:SetRoll(math.Rand(0, 360))
                    end
                end
            end
        end
    end
end)

local CAPS = {
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

local function CapBones(model)
    local mdl = model:GetModel()
    local cache = boneCache[mdl]
    if cache then return cache end

    cache = {}

    local function BoneId(name)
        return model:LookupBone("ValveBiped." .. name)
    end

    for _, cap in ipairs(CAPS) do
        local boneA, boneB = BoneId(cap[1]), BoneId(cap[2])
        if boneA and boneB then
            local kick = {}
            for _, name in ipairs(cap[4]) do kick[#kick + 1] = BoneId(name) end
            cache[#cache + 1] = { a = boneA, b = boneB, r = cap[3], kick = kick, head = cap.head }
        end
    end

    boneCache[mdl] = cache

    return cache
end

local function SegPoint(ax, ay, az, dx, dy, dz, a, px, py, pz)
    local rx, ry, rz = px - ax, py - ay, pz - az
    local s = 0
    if a >= 1e-6 then
        s = (rx * dx + ry * dy + rz * dz) / a
        s = s < 0 and 0 or (s > 1 and 1 or s)
    end

    local ex, ey, ez = rx - dx * s, ry - dy * s, rz - dz * s

    return ex * ex + ey * ey + ez * ez, s
end

local function SegSeg(ax, ay, az, dx, dy, dz, a, px, py, pz, qx, qy, qz)
    local ex, ey, ez = qx - px, qy - py, qz - pz
    local e = ex * ex + ey * ey + ez * ez
    if a < 1e-6 or e < 1e-6 then return SegPoint(ax, ay, az, dx, dy, dz, a, px, py, pz) end

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
for _, fileName in ipairs(file.Find("sound/hordez/infected/gore/bullets/*.ogg", "GAME")) do
    impactSnds[#impactSnds + 1] = "hordez/infected/gore/bullets/" .. fileName
end

HZ.PrecacheSounds(impactSnds)

local function Bleed(pos, dir)
    local effect = EffectData()
    effect:SetOrigin(pos)
    effect:SetNormal(-dir)
    effect:SetColor(BLOOD_COLOR_RED)
    effect:SetScale(1)
    effect:SetFlags(3)
    util.Effect("BloodImpact", effect, true, true)
    local path = HZ.Pick(impactSnds)
    if path then sound.Play(path, pos, 70, math.random(95, 105), 0.6) end
end

local KICK_LEN = 0.3
local UP = Vector(0, 0, 1)

local function KickDying(death, cap, dir)
    local model = death.csm
    death.kicks = death.kicks or {}
    local axis = UP:Cross(dir)
    if axis:LengthSqr() < 0.01 then axis = model:GetRight() end
    axis:Normalize()
    local ax, ay, az = axis.x, axis.y, axis.z
    for i, bone in ipairs(cap.kick) do
        if CopyBoneSafe(model, bone, boneMat) then
            local m11, m12, m13, _, m21, m22, m23, _, m31, m32, m33 = boneMat:Unpack()
            local localAxis = Vector(m11 * ax + m21 * ay + m31 * az, m12 * ax + m22 * ay + m32 * az,
                m13 * ax + m23 * ay + m33 * az)

            localAxis:Normalize()
            death.kicks[bone] = { axis = localAxis, amp = (cap.head and 26 or 18) / i, t0 = CurTime(), len = KICK_LEN }
        end
    end
end

local function PushRag(rag, pos, dir, dmg)
    local best, bestDist
    for i = 0, rag:GetPhysicsObjectCount() - 1 do
        local phys = rag:GetPhysicsObjectNum(i)
        if IsValid(phys) then
            local distSqr = phys:GetPos():DistToSqr(pos)
            if not bestDist or distSqr < bestDist then best, bestDist = phys, distSqr end
        end
    end

    if best then best:ApplyForceOffset(dir * math.min(dmg * 60, 3000), pos) end
end

local function SkipDead(ent)
    return not (ent == LocalPlayer() or ent.hz_ragdolled)
end

local shotId = 0

local function CapPoints(death, caps)
    local points = death.capPts
    if points and death.capShot == shotId then return points end

    if not points then
        points = {}
        death.capPts = points
    end

    death.capShot = shotId
    local model = death.csm
    for i = 1, #caps do
        local cap = caps[i]
        local base = i * 6 - 6
        points[base + 1] = false
        if CopyBoneSafe(model, cap.a, boneMat) then
            local fx, _, _, x, fy, _, _, y, fz, _, _, z = boneMat:Unpack()
            if cap.a == cap.b then
                x, y, z = x + fx * 3, y + fy * 3, z + fz * 3
                points[base + 1], points[base + 2], points[base + 3], points[base + 4], points[base + 5],
                    points[base + 6] = x, y, z, x, y, z
            elseif CopyBoneSafe(model, cap.b, boneMatB) then
                points[base + 1], points[base + 2], points[base + 3] = x, y, z
                points[base + 4], points[base + 5], points[base + 6] = MatrixPos(boneMatB)
            end
        end
    end

    return points
end

local function RagPoints(row, rag)
    local points = row.pts
    if points and row.shot == shotId then return points, row.npts end

    if not points then
        points = {}
        row.pts = points
    end

    local count = rag:GetPhysicsObjectCount()
    row.shot, row.npts = shotId, count
    for i = 0, count - 1 do
        local phys = rag:GetPhysicsObjectNum(i)
        local base = i * 3
        if IsValid(phys) then
            local pos = phys:GetPos()
            points[base + 1], points[base + 2], points[base + 3] = pos.x, pos.y, pos.z
        else
            points[base + 1] = false
        end
    end

    return points, count
end

local pelletTr = {}
local pelletEnd = Vector()
local pelletIn = { mask = MASK_SHOT, filter = SkipDead, output = pelletTr, endpos = pelletEnd }

local function OnPellet(src, dir, dmg, pellets)
    pelletIn.start = src
    pelletEnd:SetUnpacked(src.x + dir.x * 8192, src.y + dir.y * 8192, src.z + dir.z * 8192)
    util.TraceLine(pelletIn)
    local stop = pelletTr.HitPos
    local ax, ay, az = src.x, src.y, src.z
    local dx, dy, dz = stop.x - ax, stop.y - ay, stop.z - az
    local lenSqr = dx * dx + dy * dy + dz * dz
    local len = sqrt(lenSqr)
    local hitS, hitD, hitCap, hitRag
    for d = 1, #dying do
        local death = dying[d]
        local model = death.csm
        if IsValid(model) then
            local center = model:GetPos()
            if SegPoint(ax, ay, az, dx, dy, dz, lenSqr, center.x, center.y, center.z + 36) < 8100 then
                local caps = CapBones(model)
                local points = CapPoints(death, caps)
                for i = 1, #caps do
                    local other = i * 6 - 6
                    local px = points[other + 1]
                    if px then
                        local cap = caps[i]
                        local dist,
                            along = SegSeg(ax, ay, az, dx, dy, dz, lenSqr, px, points[other + 2], points[other + 3],
                            points[other + 4], points[other + 5], points[other + 6])

                        if dist < cap.r * cap.r and (not hitS or along < hitS) then
                            hitS, hitD, hitCap, hitRag = along, death, cap, nil
                        end
                    end
                end
            end
        end
    end

    for r = 1, #rags do
        local ragEntry = rags[r]
        local rag = ragEntry.ent
        if IsValid(rag) then
            local center = rag:GetPos()
            if SegPoint(ax, ay, az, dx, dy, dz, lenSqr, center.x, center.y, center.z) < 8100 then
                local points, count = RagPoints(ragEntry, rag)
                for other = 0, count * 3 - 3, 3 do
                    local px = points[other + 1]
                    if px then
                        local dist,
                            along = SegPoint(ax, ay, az, dx, dy, dz, lenSqr, px, points[other + 2], points[other + 3])

                        if dist < 81
                            and (not hitS or along < hitS) then
                            hitS, hitD, hitCap, hitRag = along, nil, nil, rag
                        end
                    end
                end
            end
        end
    end

    if not hitS then return end

    local hitPos = src + dir * (len * hitS)
    Bleed(hitPos, dir)
    if hitRag then
        PushRag(hitRag, hitPos, dir, dmg)
        return
    end

    local death = hitD
    local now = CurTime()
    death.hits = death.hits + 1
    death.blast = (death.blastAt == now) and (death.blast + 1) or 1
    death.blastAt = now
    if death.hits >= 4 or death.blast >= 3 or (pellets == 1 and dmg >= 60) then
        for i, other in ipairs(dying) do
            if other == death then
                table.remove(dying, i)
                break
            end
        end

        local rag = SafeFinish(death)
        if IsValid(rag) then PushRag(rag, hitPos, dir, dmg * math.min(death.blast, 4)) end
    else
        KickDying(death, hitCap, dir)
    end
end

net.Receive("hz_shot", function()
    local src = net.ReadVector()
    local dir = net.ReadNormal()
    local count = net.ReadUInt(5)
    local spread = net.ReadFloat()
    local dmg = net.ReadUInt(10)
    if #dying == 0 and #rags == 0 then return end
    if src:DistToSqr(EyePos()) > 4000 * 4000 then return end

    shotId = shotId + 1
    if spread <= 0 then
        for _ = 1, count do OnPellet(src, dir, dmg, count) end
        return
    end

    local fx, fy, fz = dir.x, dir.y, dir.z
    local rx, ry = fy, -fx
    local rightLen = sqrt(rx * rx + ry * ry)
    if rightLen < 1e-4 then
        rx, ry = 0, -1
    else
        rx, ry = rx / rightLen, ry / rightLen
    end

    local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
    local pelletDir = Vector()
    for _ = 1, count do
        local spreadX, spreadY = math.Rand(-1, 1) * spread, math.Rand(-1, 1) * spread
        pelletDir:SetUnpacked(fx + rx * spreadX + ux * spreadY, fy + ry * spreadX + uy * spreadY, fz + uz * spreadY)
        pelletDir:Normalize()
        OnPellet(src, pelletDir, dmg, count)
    end
end)

hook.Add("PostCleanupMap", "hordez_rags", function()
    for _, death in ipairs(dying) do
        if IsValid(death.csm) then death.csm:Remove() end
    end

    dying = {}
    for _, rag in ipairs(rags) do
        if IsValid(rag.ent) then rag.ent:Remove() end
    end

    rags = {}
    for _, bucket in pairs(ragPool) do
        for _, rag in ipairs(bucket) do
            if IsValid(rag) then rag:Remove() end
        end
    end

    ragPool, ragPoolCount = {}, 0
    for _, bucket in pairs(csmPool) do
        for _, csm in ipairs(bucket) do
            if IsValid(csm) then csm:Remove() end
        end
    end

    csmPool, csmPoolCount = {}, 0
    for _, burn in ipairs(burning) do
        if burn.snd then burn.snd:Stop() end
    end

    burning = {}
end)

net.Receive("hz_cue", function()
    surface.PlaySound(net.ReadString())
end)

local cvMarkers = GetConVar("hz_show_markers")

function HZ.MarkersVisible()
    if cvMarkers:GetBool() then return true end

    local wep = LocalPlayer():GetActiveWeapon()
    if not IsValid(wep) then return false end

    local class = wep:GetClass()

    return class == "weapon_physgun" or class == "gmod_tool"
end
