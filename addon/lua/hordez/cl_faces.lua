local cvOn = CreateClientConVar("hz_faces", "1", true, false, "Facial expressions")

local FACE_DIST = 900
local JAW_SPEED = 6

local LOOKS = {
    rage = {
        left_lowerer = 1, right_lowerer = 1, wrinkler = 0.85, dilator = 0.7,
        left_upper_raiser = 0.9, right_upper_raiser = 0.9, left_lid_tightener = 0.8, right_lid_tightener = 0.8,
        left_stretcher = 0.6, right_stretcher = 0.6, left_corner_depressor = 0.4, right_corner_depressor = 0.4,
        left_part = 0.6, right_part = 0.6, jaw_drop = 0.08,
    },
    dead = {
        left_inner_raiser = 0.25, right_inner_raiser = 0.25, left_lid_droop = 0.45, right_lid_droop = 0.45,
        left_corner_depressor = 0.6, right_corner_depressor = 0.6, left_part = 0.8, right_part = 0.8,
        lower_lip = 0.4, jaw_drop = 0.25,
    },
}

local flexIds = {}
local yelling = {}

local function FlexIds(ent)
    local model = ent:GetModel()
    local ids = flexIds[model]
    if ids then return ids end

    ids = {}
    for i = 0, ent:GetFlexNum() - 1 do ids[ent:GetFlexName(i)] = i end
    flexIds[model] = ids

    return ids
end

function HZ.SetFace(ent, look)
    if ent.hz_look == look then return end

    local ids = FlexIds(ent)
    local old = LOOKS[ent.hz_look]
    if old then
        for name in pairs(old) do
            if ids[name] then ent:SetFlexWeight(ids[name], 0) end
        end
    end

    local new = LOOKS[look]
    if new then
        for name, weight in pairs(new) do
            if ids[name] then ent:SetFlexWeight(ids[name], weight) end
        end
    end

    ent.hz_look = look
    ent.hz_jaw = new and new.jaw_drop or 0
end

local FACE_DIST_SQR = FACE_DIST * FACE_DIST

local function WantedLook(ent)
    if ent.hz_ragdolled or ent.hz_imp or ent.hz_far or ent:IsDormant() or (ent.hz_lod or 0) >= 2 then return nil end
    if not ent.hz_d2 or ent.hz_d2 > FACE_DIST_SQR then return nil end
    if not ent:GetNW2Bool("hz_alerted") then return nil end

    return ent:GetNW2Bool("hz_shambler") and "dead" or "rage"
end

timer.Create("hordez_faces", 0.25, 0, function()
    local on = cvOn:GetBool()
    local now = CurTime()
    local list = HZ.ClientZombies
    for i = 1, #list do
        local ent = list[i]
        if IsValid(ent) then
            local look = on and WantedLook(ent) or nil
            HZ.SetFace(ent, look)
            if look and ent:GetNW2Float("hz_yell", 0) > now then
                ent.hz_jawId = FlexIds(ent).jaw_drop
                yelling[ent] = true
            end
        end
    end
end)

hook.Add("Think", "hordez_jaw", function()
    if not next(yelling) then return end

    local now = CurTime()
    local step = FrameTime() * JAW_SPEED
    for ent in pairs(yelling) do
        local look = IsValid(ent) and LOOKS[ent.hz_look]
        local jaw = look and ent.hz_jawId
        if not jaw then
            yelling[ent] = nil
        else
            local open = ent:GetNW2Float("hz_yell", 0) > now
            local target = look.jaw_drop
            if open then
                local shambler = ent.hz_look == "dead"
                local wobble = math.sin(now * (shambler and 7 or 13) + ent:EntIndex()) * 0.15
                target = (shambler and 0.55 or 0.85) + wobble
            end

            ent.hz_jaw = math.Approach(ent.hz_jaw or look.jaw_drop, target, step)
            ent:SetFlexWeight(jaw, ent.hz_jaw)
            if not open and ent.hz_jaw == look.jaw_drop then yelling[ent] = nil end
        end
    end
end)
