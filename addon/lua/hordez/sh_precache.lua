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

function HZ.Precache()
    if done then return end

    done = true
    local t0 = SysTime()
    GrowModelCache()
    for i = 1, #models do util.PrecacheModel(models[i]) end
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
