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

-- planted / lifted relative to each foot's own lowest height (tracked, slowly forgotten): the Romero shuffle
-- only lifts the ankle ~4 units, a sprint ~15, so fixed heights would miss the shamblers
local LIFT, PLANT = 3, 1.2
local tracked = {}             -- ent -> { lastPos, feet = {bone, lifted}, surf, surfAt }
local boneCache = {}
local nextPick = 0
local list = {}

local function feetOf(e)
	local mdl = e:GetModel()
	local c = boneCache[mdl]
	if c == nil then
		local l, r = e:LookupBone("ValveBiped.Bip01_L_Foot"), e:LookupBone("ValveBiped.Bip01_R_Foot")
		c = (l and r) and { l, r } or false
		boneCache[mdl] = c
	end
	return c or nil
end

local function surfaceUnder(e, st, now)
	if st.surfAt and now < st.surfAt then return st.surf end
	st.surfAt = now + 0.5
	if e:WaterLevel() >= 1 then st.surf = "wade" return st.surf end
	local p = e:GetPos()
	local tr = util.TraceLine({ start = p + Vector(0, 0, 8), endpos = p - Vector(0, 0, 24), mask = MASK_PLAYERSOLID_BRUSHONLY })
	st.surf = (tr.Hit and SURF[tr.MatType]) or "concrete"
	return st.surf
end

local function step(e, st, now, speed)
	local gait = (speed > 120 and not e:GetNW2Bool("hz_shambler")) and "run" or "walk"
	local set = SND[gait][surfaceUnder(e, st, now)] or SND[gait].concrete
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
		local eye, maxD = EyePos(), cvDist:GetFloat() ^ 2
		local cand = {}
		for _, e in ipairs(ents.FindByClass("hz_zombie")) do
			if not e:IsDormant() and not e.hz_ragdolled then
				local d = e:GetPos():DistToSqr(eye)
				if d < maxD then cand[#cand + 1] = { e, d } end
			end
		end
		table.sort(cand, function(a, b) return a[2] < b[2] end)
		list = {}
		local keep = {}
		for i = 1, math.min(#cand, cvMax:GetInt()) do
			local e = cand[i][1]
			list[#list + 1] = e
			keep[e] = true
		end
		for e in pairs(tracked) do if not keep[e] then tracked[e] = nil end end
	end

	local dt = FrameTime()
	for _, e in ipairs(list) do
		if IsValid(e) and not e.hz_ragdolled then
			local feet = feetOf(e)
			local st = tracked[e]
			if not st then
				st = { lifted = { false, false }, low = { 99, 99 } }
				tracked[e] = st
			end
			local pos = e:GetPos()
			local speed = st.lastPos and dt > 0 and (pos - st.lastPos):Length2D() / dt or 0
			st.lastPos = pos
			if feet and speed > 12 then
				e:SetupBones()   -- (also for zombies behind you, which aren't being drawn)
				for k = 1, 2 do
					local m = e:GetBoneMatrix(feet[k])
					if m then
						local h = m:GetTranslation().z - pos.z
						st.low[k] = math.min(st.low[k] + dt * 2, h)   -- lowest point, drifting up so slopes don't stick
						local low = st.low[k]
						if h > low + LIFT then
							st.lifted[k] = true
						elseif h < low + PLANT and st.lifted[k] then
							st.lifted[k] = false
							step(e, st, now, speed)
						end
					end
				end
			end
		end
	end
end)
