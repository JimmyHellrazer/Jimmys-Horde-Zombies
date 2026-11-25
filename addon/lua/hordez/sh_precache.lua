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

local function WarmNext()
    local model = table.remove(warmQueue, 1)
    if not model then
        hook.Remove("PostRender", "hordez_warm")

        return
    end

    local ent = ClientsideModel(model, RENDERGROUP_OPAQUE)
    if IsValid(ent) then
        ent:SetNoDraw(true)
        ent:SetPos(vector_origin)
        warmTarget = warmTarget or GetRenderTarget("hordez_warm", 64, 64)
        render.PushRenderTarget(warmTarget)
        cam.Start3D(Vector(-120, 0, 40), angle_zero, 60, 0, 0, 64, 64)
        for lod = 0, 3 do
            ent:SetLOD(lod)
            ent:SetupBones()
            ent:DrawModel()
        end

        cam.End3D()
        render.PopRenderTarget()
        ent:Remove()
    end

    local ragdoll = ClientsideRagdoll(model)
    if IsValid(ragdoll) then
        ragdoll:SetNoDraw(true)
        ragdoll:Remove()
    end
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
