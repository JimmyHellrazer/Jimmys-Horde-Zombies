-- Faces: only the few chasing zombies nearest to you snarl and scream (HL2 FACS flexes on the citizen heads).
-- Everything else keeps a neutral face, so the cost is a handful of SetFlexWeight calls per frame no matter how
-- big the horde is. The server marks who is chasing (NW2 "hz_alerted") and when each one is vocalising
-- ("hz_yell", from HZ.Voice); runners make a rage snarl and yell, shamblers a slack, moaning dead face.

local cvOn = CreateClientConVar("hz_faces", "1", true, false, "Nearest chasing zombies make rage faces and yell")
local cvMax = CreateClientConVar("hz_faces_max", "4", true, false, "How many zombies get faces at once")
local cvDist = CreateClientConVar("hz_faces_dist", "700", true, false, "Faces only within this distance")

-- target weights per look; "jaw" is driven separately (yelling)
local RAGE = {
	left_lowerer = 1, right_lowerer = 1,               -- brows down and in
	wrinkler = 0.85, dilator = 0.7,                    -- nose wrinkle, flared nostrils
	left_upper_raiser = 0.9, right_upper_raiser = 0.9, -- snarling upper lip
	left_lid_tightener = 0.8, right_lid_tightener = 0.8,
	left_stretcher = 0.6, right_stretcher = 0.6,       -- mouth pulled wide
	left_corner_depressor = 0.4, right_corner_depressor = 0.4,
	left_part = 0.6, right_part = 0.6,                 -- teeth showing even with the mouth shut
}
local DEAD = {
	left_inner_raiser = 0.25, right_inner_raiser = 0.25,
	left_lid_droop = 0.45, right_lid_droop = 0.45,     -- heavy, half-dead eyes
	left_corner_depressor = 0.6, right_corner_depressor = 0.6,
	left_part = 0.8, right_part = 0.8,
	lower_lip = 0.4,
}

-- model -> the looks compiled to flex ids: { rage = { ids, weights }, dead = { ids, weights }, jaw = id }
-- (resolved once per model; the per-frame work is then plain array walks, no name lookups)
local lookCache = {}
local function compile(e, ids, look)
	local fi, fw = {}, {}
	for name, w in pairs(look) do
		local id = ids[name]
		if id then fi[#fi + 1], fw[#fw + 1] = id, w end
	end
	return { fi, fw }
end
local function looksOf(e)
	local mdl = e:GetModel()
	local c = lookCache[mdl]
	if c then return c end
	local ids = {}
	for i = 0, e:GetFlexNum() - 1 do ids[e:GetFlexName(i)] = i end
	c = { rage = compile(e, ids, RAGE), dead = compile(e, ids, DEAD), jaw = ids.jaw_drop }
	lookCache[mdl] = c
	return c
end

local active = {}      -- ent -> { w = blend 0..1, jaw = current jaw, L = its model's looks, sham = shambler }
local nextPick = 0
local pickId = 0
local near, nearD = {}, {}

local ENTITY = FindMetaTable("Entity")
local setFlexWeight = ENTITY.SetFlexWeight
local sin = math.sin

local function setLook(e, look, amount)
	local fi, fw = look[1], look[2]
	for i = 1, #fi do setFlexWeight(e, fi[i], fw[i] * amount) end
end

local function clear(e, st)
	if not IsValid(e) then return end
	local L = st.L
	setLook(e, L.rage, 0)
	setLook(e, L.dead, 0)
	if L.jaw then setFlexWeight(e, L.jaw, 0) end
	st.w = 0
end

hook.Add("Think", "hordez_faces", function()
	if not cvOn:GetBool() then
		if next(active) then
			for e, st in pairs(active) do clear(e, st) end
			active = {}
		end
		return
	end
	local now = CurTime()
	local dt = FrameTime()

	-- pick the nearest chasing zombies a few times a second
	if now >= nextPick then
		nextPick = now + 0.25
		pickId = pickId + 1
		local n = HZ.NearestZombies(EyePos(), cvDist:GetFloat() ^ 2, cvMax:GetInt(), near, nearD, true)
		for i = 1, n do
			local e = near[i]
			local st = active[e]
			if not st then
				st = { w = 0, jaw = 0, L = looksOf(e) }
				active[e] = st
			end
			st.leaving, st.pick = nil, pickId
			st.sham = e:GetNW2Bool("hz_shambler")
		end
		for _, st in pairs(active) do
			if st.pick ~= pickId then st.leaving = true end
		end
	end

	for e, st in pairs(active) do
		if not IsValid(e) or e.hz_ragdolled then
			active[e] = nil
		else
			-- ease the face in and out instead of snapping
			local w = math.Approach(st.w, st.leaving and 0 or 1, dt * 3)
			st.w = w
			local L = st.L
			local shambler = st.sham
			setLook(e, shambler and L.dead or L.rage, w)
			-- jaw: wide while it screams (rough syllable flutter), a little open otherwise
			local yelling = e:GetNW2Float("hz_yell", 0) > now
			local target
			if yelling then
				target = (shambler and 0.55 or 0.85) + sin(now * (shambler and 7 or 13) + e:EntIndex()) * 0.15
			else
				target = shambler and 0.25 or 0.08
			end
			st.jaw = math.Approach(st.jaw, target * w, dt * 6)
			if L.jaw then setFlexWeight(e, L.jaw, st.jaw) end
			if st.leaving and w <= 0 then
				clear(e, st)
				active[e] = nil
			end
		end
	end
end)
