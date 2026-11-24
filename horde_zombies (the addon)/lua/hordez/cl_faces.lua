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

local flexCache = {}   -- model -> { name -> flex id }
local function flexIds(e)
	local mdl = e:GetModel()
	local c = flexCache[mdl]
	if c then return c end
	c = {}
	for i = 0, e:GetFlexNum() - 1 do c[e:GetFlexName(i)] = i end
	flexCache[mdl] = c
	return c
end

local active = {}      -- ent -> { w = blend 0..1, jaw = current jaw }
local nextPick = 0

local function setLook(e, ids, look, amount)
	for name, w in pairs(look) do
		local id = ids[name]
		if id then e:SetFlexWeight(id, w * amount) end
	end
end

local function clear(e, st)
	if not IsValid(e) then return end
	local ids = flexIds(e)
	setLook(e, ids, RAGE, 0)
	setLook(e, ids, DEAD, 0)
	if ids.jaw_drop then e:SetFlexWeight(ids.jaw_drop, 0) end
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
		local eye = EyePos()
		local maxD = cvDist:GetFloat() ^ 2
		local list = {}
		for _, e in ipairs(ents.FindByClass("hz_zombie")) do
			if not e:IsDormant() and not e.hz_ragdolled and e:GetNW2Bool("hz_alerted") then
				local d = e:GetPos():DistToSqr(eye)
				if d < maxD then list[#list + 1] = { e, d } end
			end
		end
		table.sort(list, function(a, b) return a[2] < b[2] end)
		local keep = {}
		for i = 1, math.min(#list, cvMax:GetInt()) do keep[list[i][1]] = true end
		for e, st in pairs(active) do
			if not keep[e] then st.leaving = true end
		end
		for e in pairs(keep) do
			local st = active[e]
			if st then st.leaving = nil else active[e] = { w = 0, jaw = 0 } end
		end
	end

	for e, st in pairs(active) do
		if not IsValid(e) or e.hz_ragdolled then
			active[e] = nil
		else
			-- ease the face in and out instead of snapping
			st.w = math.Approach(st.w, st.leaving and 0 or 1, dt * 3)
			local ids = flexIds(e)
			local shambler = e:GetNW2Bool("hz_shambler")
			setLook(e, ids, shambler and DEAD or RAGE, st.w)
			-- jaw: wide while it screams (rough syllable flutter), a little open otherwise
			local yelling = e:GetNW2Float("hz_yell", 0) > now
			local target
			if yelling then
				target = (shambler and 0.55 or 0.85) + math.sin(now * (shambler and 7 or 13) + e:EntIndex()) * 0.15
			else
				target = shambler and 0.25 or 0.08
			end
			st.jaw = math.Approach(st.jaw, target * st.w, dt * 6)
			if ids.jaw_drop then e:SetFlexWeight(ids.jaw_drop, st.jaw) end
			if st.leaving and st.w <= 0 then
				clear(e, st)
				active[e] = nil
			end
		end
	end
end)
