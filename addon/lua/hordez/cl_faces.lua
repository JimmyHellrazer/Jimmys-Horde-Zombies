local cvOn = CreateClientConVar("hz_faces", "1", true, false, "Nearest chasing zombies make rage faces and yell")
local cvMax = CreateClientConVar("hz_faces_max", "4", true, false, "How many zombies get faces at once")
local cvDist = CreateClientConVar("hz_faces_dist", "700", true, false, "Faces only within this distance")

local RAGE = {
    left_lowerer = 1, right_lowerer = 1,
    wrinkler = 0.85, dilator = 0.7,
    left_upper_raiser = 0.9, right_upper_raiser = 0.9,
    left_lid_tightener = 0.8, right_lid_tightener = 0.8,
    left_stretcher = 0.6, right_stretcher = 0.6,
    left_corner_depressor = 0.4, right_corner_depressor = 0.4,
    left_part = 0.6, right_part = 0.6,
}

local DEAD = {
    left_inner_raiser = 0.25, right_inner_raiser = 0.25,
    left_lid_droop = 0.45, right_lid_droop = 0.45,
    left_corner_depressor = 0.6, right_corner_depressor = 0.6,
    left_part = 0.8, right_part = 0.8,
    lower_lip = 0.4,
}

local lookCache = {}

local function Compile(ent, ids, look)
    local flexIds, weights = {}, {}
    for name, weight in pairs(look) do
        local id = ids[name]
        if id then flexIds[#flexIds + 1], weights[#weights + 1] = id, weight end
    end

    return { flexIds, weights }
end

local function LooksOf(ent)
    local mdl = ent:GetModel()
    local cache = lookCache[mdl]
    if cache then return cache end

    local ids = {}
    for i = 0, ent:GetFlexNum() - 1 do ids[ent:GetFlexName(i)] = i end
    cache = { rage = Compile(ent, ids, RAGE), dead = Compile(ent, ids, DEAD), jaw = ids.jaw_drop }
    lookCache[mdl] = cache

    return cache
end

local active = {}
local nextPick = 0
local pickId = 0
local near, nearDist = {}, {}

local ENTITY = FindMetaTable("Entity")
local setFlexWeight = ENTITY.SetFlexWeight
local sin = math.sin

local function SetLook(ent, look, amount)
    local flexIds, weights = look[1], look[2]
    for i = 1, #flexIds do setFlexWeight(ent, flexIds[i], weights[i] * amount) end
end

local function ClearFace(ent, state)
    if not IsValid(ent) then return end

    local looks = state.L
    SetLook(ent, looks.rage, 0)
    SetLook(ent, looks.dead, 0)
    if looks.jaw then setFlexWeight(ent, looks.jaw, 0) end
    state.w = 0
end

hook.Add("Think", "hordez_faces", function()
    if not cvOn:GetBool() then
        if next(active) then
            for ent, state in pairs(active) do ClearFace(ent, state) end
            active = {}
        end

        return
    end

    local t0 = HZ.ProfOn and SysTime()
    local now = CurTime()
    local dt = FrameTime()

    if now >= nextPick then
        nextPick = now + 0.25
        pickId = pickId + 1
        local count = HZ.NearestZombies(EyePos(), cvDist:GetFloat() ^ 2, cvMax:GetInt(), near, nearDist, true)
        for i = 1, count do
            local ent = near[i]
            local state = active[ent]
            if not state then
                state = { w = 0, jaw = 0, L = LooksOf(ent) }
                active[ent] = state
            end

            state.leaving, state.pick = nil, pickId
            state.sham = ent:GetNW2Bool("hz_shambler")
        end

        for _, state in pairs(active) do
            if state.pick ~= pickId then state.leaving = true end
        end
    end

    for ent, state in pairs(active) do
        if not IsValid(ent) or ent.hz_ragdolled then
            active[ent] = nil
        else
            local blend = math.Approach(state.w, state.leaving and 0 or 1, dt * 3)
            state.w = blend
            local looks = state.L
            local shambler = state.sham
            SetLook(ent, shambler and looks.dead or looks.rage, blend)
            local yelling = ent:GetNW2Float("hz_yell", 0) > now
            local target
            if yelling then
                target = (shambler and 0.55 or 0.85) + sin(now * (shambler and 7 or 13) + ent:EntIndex()) * 0.15
            else
                target = shambler and 0.25 or 0.08
            end

            state.jaw = math.Approach(state.jaw, target * blend, dt * 6)
            if looks.jaw then setFlexWeight(ent, looks.jaw, state.jaw) end
            if state.leaving and blend <= 0 then
                ClearFace(ent, state)
                active[ent] = nil
            end
        end
    end

    if t0 then HZ.ProfAdd("cl_faces", SysTime() - t0) end
end)
