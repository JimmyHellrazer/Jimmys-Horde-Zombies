local cvOn = CreateClientConVar("hz_steps", "1", true, false, "Footsteps")
local cvMax = CreateClientConVar("hz_steps_max", "12", true, false, "Max zombies with footsteps")
local cvDist = CreateClientConVar("hz_steps_dist", "1400", true, false, "Footstep range")
local cvVol = CreateClientConVar("hz_steps_volume", "0.8", true, false, "Footstep volume")

local stepsOn, stepsMax, stepsDistSqr, stepsVol = true, 12, 1400 * 1400, 0.8
local function ReadStepConVars()
    stepsOn = cvOn:GetBool()
    stepsMax = cvMax:GetInt()
    local d = cvDist:GetFloat()
    stepsDistSqr = d * d
    stepsVol = cvVol:GetFloat()
end
ReadStepConVars()
for _, cv in ipairs({ cvOn, cvMax, cvDist, cvVol }) do
    cvars.AddChangeCallback(cv:GetName(), ReadStepConVars, "hordez_steps")
end

local SURF = {
    [MAT_CONCRETE] = "concrete", [MAT_DIRT] = "dirt", [MAT_GRASS] = "grass", [MAT_FOLIAGE] = "grass",
    [MAT_SAND] = "sand", [MAT_SNOW] = "sand", [MAT_METAL] = "metal", [MAT_COMPUTER] = "metal",
    [MAT_GRATE] = "metalgrate", [MAT_VENT] = "duct", [MAT_WOOD] = "wood", [MAT_TILE] = "tile",
    [MAT_GLASS] = "glass", [MAT_PLASTIC] = "cardboard", [MAT_FLESH] = "flesh", [MAT_BLOODYFLESH] = "flesh",
    [MAT_ALIENFLESH] = "flesh", [MAT_ANTLION] = "flesh", [MAT_SLOSH] = "mud",
}

local SND = { run = {}, walk = {} }
for gait, sets in pairs(SND) do
    for _, fileName in ipairs(file.Find("sound/hordez/footsteps/" .. gait .. "/*.ogg", "GAME")) do
        local surf = fileName:gsub("%d*%.ogg$", "")
        sets[surf] = sets[surf] or {}
        table.insert(sets[surf], "hordez/footsteps/" .. gait .. "/" .. fileName)
    end
end

for _, sets in pairs(SND) do
    for _, set in pairs(sets) do HZ.PrecacheSounds(set) end
end

local LIFT, PLANT = 3, 1.2
local tracked = {}
local boneCache = {}
local nextPick = 0
local list, listDist = {}, {}
local pickId = 0
local nextSample, lastSample = 0, 0

local CopyBone = HZ.Math.CopyBone
local MATRIX = FindMetaTable("VMatrix")
local getField = MATRIX.GetField
local footMat = Matrix()
local sqrt = math.sqrt

local function FeetOf(ent)
    local mdl = ent:GetModel()
    local cache = boneCache[mdl]
    if cache == nil then
        local left, right = ent:LookupBone("ValveBiped.Bip01_L_Foot"), ent:LookupBone("ValveBiped.Bip01_R_Foot")
        cache = (left and right) and { left, right } or false
        boneCache[mdl] = cache
    end

    return cache
end

local surfStart, surfEnd = Vector(), Vector()
local surfTr = {}
local surfIn = { start = surfStart, endpos = surfEnd, mask = MASK_PLAYERSOLID_BRUSHONLY, output = surfTr }

local function SurfaceUnder(ent, state, now, pos)
    if state.surfAt and now < state.surfAt then return state.surf end

    state.surfAt = now + 0.5
    if ent:WaterLevel() >= 1 then
        state.surf = "wade"
        return state.surf
    end

    surfStart:SetUnpacked(pos.x, pos.y, pos.z + 8)
    surfEnd:SetUnpacked(pos.x, pos.y, pos.z - 24)
    util.TraceLine(surfIn)
    state.surf = (surfTr.Hit and SURF[surfTr.MatType]) or "concrete"

    return state.surf
end

local function PlayStep(ent, state, now, speed, pos)
    local gait = (speed > 120 and not ent:GetNW2Bool("hz_shambler")) and "run" or "walk"
    local set = SND[gait][SurfaceUnder(ent, state, now, pos)] or SND[gait].concrete
    local sound = set and set[math.random(#set)]
    if not sound then return end

    local vol = stepsVol * (gait == "run" and 1 or 0.7)
    ent:EmitSound(sound, gait == "run" and 70 or 62, math.random(94, 106), vol, CHAN_BODY)
end

hook.Add("Think", "hordez_steps", function()
    if not stepsOn then return end

    local t0 = HZ.ProfOn and SysTime()
    local now = CurTime()
    if now >= nextPick then
        nextPick = now + 0.3
        pickId = pickId + 1
        local count = HZ.NearestZombies(EyePos(), stepsDistSqr, stepsMax, list, listDist)
        for i = 1, count do
            local ent = list[i]
            local state = tracked[ent]
            if not state then
                state = { lifted = { false, false }, low = { 99, 99 }, feet = FeetOf(ent) }
                tracked[ent] = state
            end

            state.pick = pickId
        end

        for ent, state in pairs(tracked) do
            if state.pick ~= pickId then tracked[ent] = nil end
        end
    end

    if now < nextSample then return end

    local dt = now - lastSample
    nextSample, lastSample = now + 0.025, now
    if dt > 0.25 then dt = 0 end
    for i = 1, #list do
        local ent = list[i]
        local state = tracked[ent]
        if state and IsValid(ent) and not ent.hz_ragdolled then
            local feet = state.feet
            local pos = ent:GetPos()
            local x, y, z = pos.x, pos.y, pos.z
            local lx = state.lx
            local speed = 0
            if lx and dt > 0 then
                local dx, dy = x - lx, y - state.ly
                speed = sqrt(dx * dx + dy * dy) / dt
            end

            state.lx, state.ly = x, y
            if feet and speed > 12 then
                ent:SetupBones()
                local low, lifted = state.low, state.lifted
                for foot = 1, 2 do
                    if CopyBone(ent, feet[foot], footMat) then
                        local height = getField(footMat, 3, 4) - z
                        local lowest = low[foot] + dt * 2
                        if height < lowest then lowest = height end
                        low[foot] = lowest
                        if height > lowest + LIFT then
                            lifted[foot] = true
                        elseif height < lowest + PLANT and lifted[foot] then
                            lifted[foot] = false
                            PlayStep(ent, state, now, speed, pos)
                        end
                    end
                end
            end
        end
    end

    if t0 then HZ.ProfAdd("cl_steps", SysTime() - t0) end
end)
