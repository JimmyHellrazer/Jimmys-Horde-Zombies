-- Footsteps: L4D2 infected footstep sounds (run / walk sets per surface), played on your client for the
-- zombies nearest to you. A step is a foot coming down: each foot bone's height above the zombie's origin is
-- watched and a sound plays when it drops onto the ground (works for every run, walk and shamble anim
-- without per-animation timing). Behind-you zombies count too - their bones are set up even off screen.

local cvOn = CreateClientConVar("hz_steps", "1", true, false, "Zombie footstep sounds")
local cvMax = CreateClientConVar("hz_steps_max", "12", true, false, "How many of the nearest zombies make footsteps")
local cvDist = CreateClientConVar("hz_steps_dist", "1400", true, false, "Footsteps only within this distance")
local cvVol = CreateClientConVar("hz_steps_volume", "0.8", true, false, "Footstep volume")

local SURF = {
	[MAT_CONCRETE] = "concrete", [MAT_DIRT] = "dirt", [MAT_GRASS] = "grass", [MAT_FOLIAGE] = "grass",
	[MAT_SAND] = "sand", [MAT_SNOW] = "sand", [MAT_METAL] = "metal", [MAT_COMPUTER] = "metal",
	[MAT_GRATE] = "metalgrate", [MAT_VENT] = "duct", [MAT_WOOD] = "wood", [MAT_TILE] = "tile",
	[MAT_GLASS] = "glass", [MAT_PLASTIC] = "cardboard", [MAT_FLESH] = "flesh", [MAT_BLOODYFLESH] = "flesh",
	[MAT_ALIENFLESH] = "flesh", [MAT_ANTLION] = "flesh", [MAT_SLOSH] = "mud",
}
-- gait -> surface -> list of sound paths (only the files that exist)
local SND = { run = {}, walk = {} }
for gait, t in pairs(SND) do
	for _, f in ipairs(file.Find("sound/hordez/footsteps/" .. gait .. "/*.wav", "GAME")) do
		local surf = f:gsub("%d*%.wav$", "")
		t[surf] = t[surf] or {}
		table.insert(t[surf], "hordez/footsteps/" .. gait .. "/" .. f)
	end
end

for _, t in pairs(SND) do
	for _, set in pairs(t) do HZ.PrecacheSounds(set) end
end

-- planted / lifted relative to each foot's own lowest height (tracked, slowly forgotten): the Romero shuffle
-- only lifts the ankle ~4 units, a sprint ~15, so fixed heights would miss the shamblers
local LIFT, PLANT = 3, 1.2
local tracked = {}             -- ent -> { lx, ly, feet = {bone, bone}, lifted, low, surf, surfAt }
local boneCache = {}
local nextPick = 0
local list, listD = {}, {}
local pickId = 0
local nextSample, lastSample = 0, 0

local CopyBone = HZ.Math.CopyBone
local MATRIX = FindMetaTable("VMatrix")
local getField = MATRIX.GetField
local footMat = Matrix()       -- scratch: foot bones are copied into this, no matrix / vector made per read
local sqrt = math.sqrt

local function feetOf(e)
	local mdl = e:GetModel()
	local c = boneCache[mdl]
	if c == nil then
		local l, r = e:LookupBone("ValveBiped.Bip01_L_Foot"), e:LookupBone("ValveBiped.Bip01_R_Foot")
		c = (l and r) and { l, r } or false
		boneCache[mdl] = c
	end
	return c
end

local UP8, DOWN24 = Vector(0, 0, 8), Vector(0, 0, 24)
local surfTr = {}
local surfIn = { mask = MASK_PLAYERSOLID_BRUSHONLY, output = surfTr }
local function surfaceUnder(e, st, now, p)
	if st.surfAt and now < st.surfAt then return st.surf end
	st.surfAt = now + 0.5
	if e:WaterLevel() >= 1 then st.surf = "wade" return st.surf end
	surfIn.start, surfIn.endpos = p + UP8, p - DOWN24
	util.TraceLine(surfIn)
	st.surf = (surfTr.Hit and SURF[surfTr.MatType]) or "concrete"
	return st.surf
end

local function step(e, st, now, speed, pos)
	local gait = (speed > 120 and not e:GetNW2Bool("hz_shambler")) and "run" or "walk"
	local set = SND[gait][surfaceUnder(e, st, now, pos)] or SND[gait].concrete
	local snd = set and set[math.random(#set)]
	if not snd then return end
	local vol = cvVol:GetFloat() * (gait == "run" and 1 or 0.7)
	e:EmitSound(snd, gait == "run" and 70 or 62, math.random(94, 106), vol, CHAN_BODY)
end

hook.Add("Think", "hordez_steps", function()
	if not cvOn:GetBool() then return end
	local now = CurTime()
	if now >= nextPick then
		nextPick = now + 0.3
		pickId = pickId + 1
		local n = HZ.NearestZombies(EyePos(), cvDist:GetFloat() ^ 2, cvMax:GetInt(), list, listD)
		for i = 1, n do
			local e = list[i]
			local st = tracked[e]
			if not st then
				st = { lifted = { false, false }, low = { 99, 99 }, feet = feetOf(e) }
				tracked[e] = st
			end
			st.pick = pickId
		end
		for e, st in pairs(tracked) do if st.pick ~= pickId then tracked[e] = nil end end
	end

	-- Feet are sampled 40 times a second, not every frame: each sample sets up the skeleton of every tracked
	-- zombie (the one real cost here), and a foot coming down is caught just as well at 40 Hz as at 240 fps.
	if now < nextSample then return end
	local dt = now - lastSample
	nextSample, lastSample = now + 0.025, now
	if dt > 0.25 then dt = 0 end   -- first sample / after a pause: no speed from a stale position
	for i = 1, #list do
		local e = list[i]
		local st = tracked[e]
		if st and IsValid(e) and not e.hz_ragdolled then
			local feet = st.feet
			local pos = e:GetPos()
			local x, y, z = pos.x, pos.y, pos.z
			local lx = st.lx
			local speed = 0
			if lx and dt > 0 then
				local dx, dy = x - lx, y - st.ly
				speed = sqrt(dx * dx + dy * dy) / dt
			end
			st.lx, st.ly = x, y
			if feet and speed > 12 then
				e:SetupBones()   -- (also for zombies behind you, which aren't being drawn)
				local low, lifted = st.low, st.lifted
				for k = 1, 2 do
					if CopyBone(e, feet[k], footMat) then
						local h = getField(footMat, 3, 4) - z
						local l = low[k] + dt * 2   -- lowest point, drifting up so slopes don't stick
						if h < l then l = h end
						low[k] = l
						if h > l + LIFT then
							lifted[k] = true
						elseif h < l + PLANT and lifted[k] then
							lifted[k] = false
							step(e, st, now, speed, pos)
						end
					end
				end
			end
		end
	end
end)
