local sounds, models = {}, {}
local seen = {}
local done = false

function HZ.PrecacheSound(path)
    if not path or seen[path] then return end

    seen[path] = true
    if done then
        util.PrecacheSound(path)
    else
        sounds[#sounds + 1] = path
    end
end

function HZ.PrecacheSounds(list)
    for i = 1, #list do HZ.PrecacheSound(list[i]) end
end

function HZ.PrecacheModel(path)
    if not path or seen[path] then return end

    seen[path] = true
    if done then
        util.PrecacheModel(path)
    else
        models[#models + 1] = path
    end
end

local warmQueue = {}
local warmTarget

local ANIMS_PER_FRAME = 12
local CYCLES = { 0, 0.25, 0.5, 0.75 }
local animModels = { "models/hordez/citizens/male_01.mdl", "models/hordez/citizens/female_01.mdl" }
local animEnt, animSeq

local function Evaluate(ent, cycle)
    ent:SetCycle(cycle)
    ent:InvalidateBoneCache()
    ent:SetupBones()
end

local function WarmSequence(ent, seq)
    ent:ResetSequence(seq)
    ent:SetPlaybackRate(0)

    local params = ent:GetNumPoseParameters()
    for i = 0, params - 1 do
        local lo, hi = ent:GetPoseParameterRange(i)
        ent:SetPoseParameter(ent:GetPoseParameterName(i), (lo + hi) * 0.5)
    end

    for _, cycle in ipairs(CYCLES) do Evaluate(ent, cycle) end

    for i = 0, params - 1 do
        local name = ent:GetPoseParameterName(i)
        local lo, hi = ent:GetPoseParameterRange(i)
        ent:SetPoseParameter(name, lo)
        Evaluate(ent, 0.5)
        ent:SetPoseParameter(name, hi)
        Evaluate(ent, 0.5)
        ent:SetPoseParameter(name, (lo + hi) * 0.5)
    end
end

local function WarmAnims()
    if not IsValid(animEnt) then
        local model = table.remove(animModels, 1)
        if not model then return false end

        animEnt = ClientsideModel(model, RENDERGROUP_OPAQUE)
        if not IsValid(animEnt) then return true end

        animEnt:SetNoDraw(true)
        animSeq = 0
    end

    local last = animEnt:GetSequenceCount() - 1
    for _ = 1, ANIMS_PER_FRAME do
        if animSeq > last then
            animEnt:Remove()
            animEnt = nil

            return true
        end

        WarmSequence(animEnt, animSeq)
        animSeq = animSeq + 1
    end

    return true
end

local warmParticles = false

local function WarmParticles()
    if warmParticles then return end
    warmParticles = true

    warmTarget = warmTarget or GetRenderTarget("hordez_warm", 64, 64)
    render.PushRenderTarget(warmTarget)
    cam.Start2D()
    for i = 1, 5 do
        surface.SetMaterial(Material("particles/flamelet" .. i))
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawTexturedRect(0, 0, 16, 16)
    end

    for i = 1, 9 do
        surface.SetMaterial(Material("particle/smokesprites_000" .. i))
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawTexturedRect(0, 0, 16, 16)
    end

    cam.End2D()
    render.PopRenderTarget()
end

local function WarmNext()
    local model = table.remove(warmQueue, 1)
    if not model then
        if WarmAnims() then return end

        WarmParticles()
        hook.Remove("PostRender", "hordez_warm")
        if HZ.BakeImpostors then HZ.BakeImpostors() end

        return
    end

    local ent = ClientsideModel(model, RENDERGROUP_OPAQUE)
    if IsValid(ent) then
        ent:SetNoDraw(true)
        ent:SetPos(vector_origin)
        warmTarget = warmTarget or GetRenderTarget("hordez_warm", 64, 64)
        render.PushRenderTarget(warmTarget)
        cam.Start3D(Vector(-120, 0, 40), angle_zero, 60, 0, 0, 64, 64)
        local skins = math.max(ent:SkinCount() or 1, 1)
        for skin = 0, skins - 1 do
            ent:SetSkin(skin)
            ent:SetLOD(0)
            ent:SetupBones()
            ent:DrawModel()
        end

        ent:SetSkin(0)
        for bg = 0, ent:GetNumBodyGroups() - 1 do
            local bgCount = ent:GetBodygroupCount(bg)
            if bgCount > 1 then
                for val = 1, bgCount - 1 do
                    ent:SetBodygroup(bg, val)
                    ent:DrawModel()
                end

                ent:SetBodygroup(bg, 0)
            end
        end

        for lod = 1, 3 do
            ent:SetLOD(lod)
            ent:SetupBones()
            ent:DrawModel()
        end

        ent:SetLOD(-1)
        cam.End3D()
        render.PopRenderTarget()
        if HZ.SeedDeathModelPool then
            HZ.SeedDeathModelPool(model, ent)
        else
            ent:Remove()
        end
    end

    local ragdoll = ClientsideRagdoll(model)
    if IsValid(ragdoll) then
        if HZ.SeedRagdollPool then
            HZ.SeedRagdollPool(model, ragdoll)
        else
            ragdoll:SetNoDraw(true)
            ragdoll:Remove()
        end
    end
end

local svWarmQueue = {}
local svWarmEnt
local svAnimModels = { "models/hordez/citizens/male_01.mdl", "models/hordez/citizens/female_01.mdl" }
local svAnimSeq
local SV_ANIMS_PER_TICK = 24

local function EnsureSvWarmEnt(model)
    if not IsValid(svWarmEnt) then
        svWarmEnt = ents.Create("prop_dynamic")
        if not IsValid(svWarmEnt) then return nil end

        svWarmEnt:SetModel(model)
        svWarmEnt:SetPos(vector_origin)
        svWarmEnt:SetNoDraw(true)
        svWarmEnt:SetSolid(SOLID_NONE)
        svWarmEnt:SetMoveType(MOVETYPE_NONE)
        svWarmEnt:Spawn()
    else
        svWarmEnt:SetModel(model)
    end

    return svWarmEnt
end

local function ServerWarmAnims()
    if not svAnimSeq then
        local model = table.remove(svAnimModels, 1)
        if not model then return false end

        local ent = EnsureSvWarmEnt(model)
        if not ent then return false end

        svAnimSeq = 0
    end

    local ent = svWarmEnt
    if not IsValid(ent) then
        svAnimSeq = nil
        return false
    end

    local last = ent:GetSequenceCount() - 1
    for _ = 1, SV_ANIMS_PER_TICK do
        if svAnimSeq > last then
            svAnimSeq = nil
            return true
        end

        ent:ResetSequence(svAnimSeq)
        ent:GetSequenceInfo(svAnimSeq)
        ent:GetSequenceGroundSpeed(svAnimSeq)
        ent:GetSequenceMovement(svAnimSeq, 0, 1)
        svAnimSeq = svAnimSeq + 1
    end

    return true
end

local function ServerWarmNext()
    local model = table.remove(svWarmQueue, 1)
    if not model then
        if ServerWarmAnims() then return end

        if IsValid(svWarmEnt) then svWarmEnt:Remove() end
        svWarmEnt = nil
        hook.Remove("Think", "hordez_sv_warm")
        return
    end

    local ent = EnsureSvWarmEnt(model)
    if not ent then
        hook.Remove("Think", "hordez_sv_warm")
        return
    end

    HZ.ResolvePools(ent)
    HZ.ResolveShamblerPools(ent)
    if HZ.WarmBodygroups then HZ.WarmBodygroups(ent) end
end

function HZ.Precache()
    if done then return end

    done = true
    local t0 = SysTime()
    for i = 1, #models do util.PrecacheModel(models[i]) end
    if CLIENT then
        for i = 1, #models do
            if models[i]:find("/citizens/", 1, true) then warmQueue[#warmQueue + 1] = models[i] end
        end

        hook.Add("PostRender", "hordez_warm", WarmNext)
    else
        for i = 1, #models do
            if models[i]:find("/citizens/", 1, true) then svWarmQueue[#svWarmQueue + 1] = models[i] end
        end

        hook.Add("Think", "hordez_sv_warm", ServerWarmNext)
    end

    for i = 1, #sounds do util.PrecacheSound(sounds[i]) end
    if HZ.CV.debug:GetBool() then
        print(("[hordez] precached %d models and %d sounds in %.0f ms"):format(#models, #sounds,
            (SysTime() - t0) * 1000))
    end

    sounds, models = {}, {}
end

HZ.PrecacheModel("models/hordez/inf_m.mdl")
HZ.PrecacheModel("models/hordez/inf_f.mdl")
for _, model in ipairs(HZ.Models) do HZ.PrecacheModel(model) end

hook.Add("InitPostEntity", "hordez_precache", HZ.Precache)
if (SERVER and #ents.GetAll() > 0) or (CLIENT and IsValid(LocalPlayer and LocalPlayer())) then HZ.Precache() end
