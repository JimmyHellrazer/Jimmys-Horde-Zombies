-- Load every model and sound up front. Without this the first zombie using a given body, and the first time
-- each voice line / footstep plays, makes the engine read the file from disk synchronously - a hitch right
-- when a horde spawns. Files queue what they use (HZ.PrecacheSound / HZ.PrecacheModel) while they load; it is
-- all flushed once the map is up (or at once on a Lua refresh / late load).
local sounds, models = {}, {}
local seen = {}
local done = false

function HZ.PrecacheSound(path)
	if not path or seen[path] then return end
	seen[path] = true
	if done then util.PrecacheSound(path) else sounds[#sounds + 1] = path end
end

function HZ.PrecacheSounds(list)
	for i = 1, #list do HZ.PrecacheSound(list[i]) end
end

function HZ.PrecacheModel(path)
	if not path or seen[path] then return end
	seen[path] = true
	if done then util.PrecacheModel(path) else models[#models + 1] = path end
end

function HZ.Precache()
	if done then return end
	done = true
	local t0 = SysTime()
	for i = 1, #models do util.PrecacheModel(models[i]) end
	for i = 1, #sounds do util.PrecacheSound(sounds[i]) end
	if HZ.CV.debug:GetBool() then
		print(("[hordez] precached %d models and %d sounds in %.0f ms"):format(#models, #sounds, (SysTime() - t0) * 1000))
	end
	sounds, models = {}, {}
end

-- the shared animation libraries first, then every body
HZ.PrecacheModel("models/hordez/inf_m.mdl")
HZ.PrecacheModel("models/hordez/inf_f.mdl")
for _, m in ipairs(HZ.Models) do HZ.PrecacheModel(m) end

hook.Add("InitPostEntity", "hordez_precache", HZ.Precache)
-- lua refresh / late load
if (SERVER and #ents.GetAll() > 0) or (CLIENT and IsValid(LocalPlayer and LocalPlayer())) then HZ.Precache() end
