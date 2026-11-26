local sounds = {}
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

function HZ.PrecacheModel()
end

function HZ.Precache()
    if done then return end

    done = true
    local t0 = SysTime()
    for i = 1, #sounds do util.PrecacheSound(sounds[i]) end
    if HZ.CV.debug:GetBool() then
        print(("[hordez] precached %d sounds in %.0f ms"):format(#sounds, (SysTime() - t0) * 1000))
    end

    sounds = {}
end

hook.Add("InitPostEntity", "hordez_precache", HZ.Precache)
if (SERVER and #ents.GetAll() > 0) or (CLIENT and IsValid(LocalPlayer and LocalPlayer())) then HZ.Precache() end
