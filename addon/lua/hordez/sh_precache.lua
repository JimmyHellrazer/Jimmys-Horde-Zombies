local sounds, models = {}, {}
local seen = {}
local done = false
local MODEL_CACHE_MB = 256

local function GrowModelCache()
    local cache = GetConVar("datacachesize")
    if not cache or cache:GetInt() >= MODEL_CACHE_MB then return end

    pcall(RunConsoleCommand, "datacachesize", tostring(MODEL_CACHE_MB))
    timer.Simple(1, function()
        if cache:GetInt() >= MODEL_CACHE_MB then return end

        print(("[hordez] the engine's model cache is %d MB, which causes stutter with big hordes. "
            .. "Add +datacachesize %d to the launch options"):format(cache:GetInt(), MODEL_CACHE_MB))
    end)
end

function HZ.PrecacheSound(path)
    if not path or seen[path] then return end

    seen[path] = true
    if done then
        util.PrecacheSound(path)
        if CLIENT and HZ.WarmSound then HZ.WarmSound(path) end
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
        if CLIENT and HZ.WarmModel then HZ.WarmModel(path) end
    else
        models[#models + 1] = path
    end
end

if CLIENT then
    local warmQueue, warmSeen = {}, {}
    local warmSndQueue, warmSndSeen = {}, {}
    local warmRt
    local warmPos, warmCam, warmAng = Vector(0, 0, 0), Vector(-80, 0, 36), Angle(0, 0, 0)
    local warmHooked = false

    local function TouchAnimBlocks(ent)
        local pools = HZ.SeqPools
        if not pools then return end

        for _, names in pairs(pools) do
            if istable(names) and isstring(names[1]) then
                local seq = ent:LookupSequence(names[1])
                if seq and seq >= 0 then
                    ent:ResetSequence(seq)
                    ent:SetCycle(0.5)
                    ent:SetupBones()
                end
            end
        end
    end

    local function WarmSingleModel(path)
        util.PrecacheModel(path)
        local ent = ClientsideModel(path, RENDERGROUP_OPAQUE)
        if not IsValid(ent) then return end

        warmRt = warmRt or GetRenderTarget("hordez_warm_rt", 16, 16)
        ent:SetNoDraw(true)
        ent:SetPos(warmPos)
        ent:SetAngles(warmAng)
        if path == "models/hordez/inf_m.mdl" or path == "models/hordez/inf_f.mdl" then
            TouchAnimBlocks(ent)
        else
            ent:SetupBones()
        end

        local skins = math.max(ent:SkinCount() or 1, 1)
        local bgs = ent:GetBodyGroups() or {}

        render.PushRenderTarget(warmRt)
        render.Clear(0, 0, 0, 0, true, true)
        cam.Start3D(warmCam, warmAng, 60, 0, 0, 16, 16, 4, 256)
        for lod = 0, 3 do
            ent:SetLOD(lod)
            ent:DrawModel()
        end

        ent:SetLOD(0)
        for s = 1, skins - 1 do
            ent:SetSkin(s)
            ent:DrawModel()
        end

        ent:SetSkin(0)
        for i = 1, #bgs do
            local bg = bgs[i]
            if bg and bg.num and bg.num > 1 then
                for sub = 1, bg.num - 1 do
                    ent:SetBodygroup(bg.id, sub)
                    ent:DrawModel()
                end

                ent:SetBodygroup(bg.id, 0)
            end
        end

        cam.End3D()
        render.PopRenderTarget()
        ent:Remove()
    end

    local function StepWarm(depth, sky, sky3d)
        if depth or sky or sky3d then return end

        local mn = #warmQueue
        if mn > 0 then
            local path = warmQueue[mn]
            warmQueue[mn] = nil
            if path and path ~= "" then WarmSingleModel(path) end
            return
        end

        local sn = #warmSndQueue
        if sn > 0 then
            local ply = LocalPlayer()
            if IsValid(ply) then
                for _ = 1, math.min(4, sn) do
                    local snd = warmSndQueue[sn]
                    warmSndQueue[sn] = nil
                    sn = sn - 1
                    if snd and snd ~= "" then ply:EmitSound(snd, 0, 100, 0.001, CHAN_STATIC) end
                end
            end

            return
        end

        hook.Remove("PostDrawOpaqueRenderables", "hordez_warm_models")
        warmHooked = false
    end

    local function EnsureWarmHook()
        if warmHooked then return end

        warmHooked = true
        hook.Add("PostDrawOpaqueRenderables", "hordez_warm_models", StepWarm)
    end

    function HZ.WarmModel(path)
        if not path or path == "" or warmSeen[path] then return end

        warmSeen[path] = true
        warmQueue[#warmQueue + 1] = path
        EnsureWarmHook()
    end

    function HZ.WarmSound(path)
        if not path or path == "" or warmSndSeen[path] then return end

        warmSndSeen[path] = true
        warmSndQueue[#warmSndQueue + 1] = path
        EnsureWarmHook()
    end
end

function HZ.Precache()
    if done then return end

    done = true
    local t0 = SysTime()
    GrowModelCache()
    for i = 1, #models do
        util.PrecacheModel(models[i])
        if CLIENT and HZ.WarmModel then HZ.WarmModel(models[i]) end
    end

    for i = 1, #sounds do
        util.PrecacheSound(sounds[i])
        if CLIENT and HZ.WarmSound then HZ.WarmSound(sounds[i]) end
    end
    if HZ.CV.debug:GetBool() then
        print(("[hordez] precached %d models and %d sounds in %.0f ms"):format(#models, #sounds,
            (SysTime() - t0) * 1000))
    end

    sounds, models = {}, {}
end

HZ.PrecacheModel("models/hordez/inf_m.mdl")
HZ.PrecacheModel("models/hordez/inf_f.mdl")
HZ.PrecacheSound("hordez/mega_mob_incoming.ogg")
for _, model in ipairs(HZ.Models) do HZ.PrecacheModel(model) end

hook.Add("InitPostEntity", "hordez_precache", HZ.Precache)
if (SERVER and #ents.GetAll() > 0) or (CLIENT and IsValid(LocalPlayer and LocalPlayer())) then HZ.Precache() end
