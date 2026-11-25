local cvOn = CreateClientConVar("hz_impostors", "1", true, false,
    "Draw far zombies as flat impostors instead of models")

local cvDist = CreateClientConVar("hz_impostor_dist", "2500", true, false,
    "Zombies beyond this distance are drawn as impostors")

local cvLight = CreateClientConVar("hz_impostor_light", "1", true, false,
    "Brightness of impostors against the real models")

local cvFog = CreateClientConVar("hz_impostor_fog", "1", true, false, "Fade impostors into the map's fog")
local cvDebug = CreateClientConVar("hz_impostor_debug", "0", false, false,
    "Show the impostor atlas and count on screen")

local DU, DV = 1 / 32, 1 / 16
local NEAR_DIST = 1200
local HALF_W, Z_LO, Z_HI = 24, -8, 88
local MAX_QUADS = 6000
local REBUILD = 0.25

local V_RUN_M, V_RUN_F, V_SHAMBLE, V_IDLE_M, V_IDLE_F = { 0, 1, 2 }, { 3, 4 }, 5, 6, 7
local VARIANTS = {
    { female = false, seqs = { "Run_01", "Run_02" }, move = true },
    { female = false, seqs = { "Run_03", "Run_01" }, move = true },
    { female = false, seqs = { "Run_05", "Run_02" }, move = true },
    { female = true, seqs = { "Run_01", "Run_02" }, move = true },
    { female = true, seqs = { "Run_03", "Run_01" }, move = true },
    { female = false, seqs = { "Romero_Run_02", "Shamble_01", "Walk_Neutral_01" }, move = true },
    { female = false, seqs = { "Idle_Neutral_01", "Idle_Neutral_02" } },
    { female = true, seqs = { "Idle_Neutral_01", "Idle_Neutral_02" } },
}

local rates = {}

local function Layer(size, name, material)
    return { size = size, cellW = size / 32, cellH = size / 16, inset = 0.5 / size, mat = Material(material),
        rt = GetRenderTargetEx(name, size, size, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, 0, 0,
        IMAGE_FORMAT_RGBA8888),
        buckets = {}, count = 0 }
end

local farLayer = Layer(1024, "hz_impostor_atlas", "hordez/impostor")
local nearLayer = Layer(2048, "hz_impostor_atlas_near", "hordez/impostor_near")
local LAYERS = { farLayer, nearLayer }
local atlasRT = nearLayer.rt
local dbgMat = CreateMaterial("hz_impostor_dbg", "UnlitGeneric",
    { ["$basetexture"] = atlasRT:GetName(), ["$translucent"] = 1 })

local ready = false
local bakeAt
local bakeModels

local ACCESSORY = { beanie = true, beanies = true, glasses = true }

local function StandIn(variant)
    local pool = {}
    for _, model in ipairs(HZ.Models) do
        local female = model:find("female", 1, true) ~= nil
        if female == variant.female and not model:find("_b.mdl", 1, true) then pool[#pool + 1] = model end
    end

    local ent = ClientsideModel(HZ.Pick(pool) or HZ.Models[1], RENDERGROUP_OPAQUE)
    if not IsValid(ent) then return end

    ent:SetNoDraw(true)
    local skins = ent:SkinCount()
    if skins and skins > 1 then ent:SetSkin(math.random(0, skins - 1)) end
    for i = 1, ent:GetNumBodyGroups() - 1 do
        local count = ent:GetBodygroupCount(i)
        if count > 1 then
            local rare = ACCESSORY[string.lower(ent:GetBodygroupName(i) or "")]
            ent:SetBodygroup(i, (rare and math.random() > 0.2) and 0 or math.random(0, count - 1))
        end
    end

    local seq = -1
    for _, name in ipairs(variant.seqs) do
        seq = ent:LookupSequence(name)
        if seq and seq >= 0 then break end
    end

    if not seq or seq < 0 then seq = 0 end
    ent:ResetSequence(seq)
    ent:SetPlaybackRate(0)
    if variant.move then
        ent:SetPoseParameter("move_x", 1)
        ent:SetPoseParameter("move_y", 0)
    end

    ent:SetLOD(1)
    local dur = ent:SequenceDuration(seq)

    return ent, 1 / math.max(dur and dur > 0 and dur or 1, 0.2)
end

local function StartBake()
    ready, bakeAt = false, 1
    for _, model in ipairs(bakeModels or {}) do
        if IsValid(model) then model:Remove() end
    end

    bakeModels = {}
end

local camView = { type = "3D",
    ortho = { left = -HALF_W, right = HALF_W, top = -(Z_HI - Z_LO) / 2, bottom = (Z_HI - Z_LO) / 2 },
    znear = 1, zfar = 600 }

local function BakeVariant(i)
    local variant = VARIANTS[i]
    local standIn, rate = StandIn(variant)
    if not standIn then return end

    bakeModels[#bakeModels + 1] = standIn
    rates[i - 1] = rate
    local at = EyePos()
    for _, ent in ipairs(HZ.ClientZombies) do
        if IsValid(ent) and not ent:IsDormant() then
            at = ent:GetPos()
            break
        end
    end

    local _, row = next(HZ.VirtualCl)
    if row and at == EyePos() then at = Vector(HZ.VirtualAt(row, CurTime())) end
    local center = at + Vector(0, 0, (Z_LO + Z_HI) / 2)
    standIn:SetPos(at)
    standIn:SetAngles(angle_zero)

    for _, layer in ipairs(LAYERS) do
        camView.w, camView.h = layer.cellW, layer.cellH
        render.PushRenderTarget(layer.rt)
        if i == 1 then render.Clear(0, 0, 0, 0, true, true) end
        render.SuppressEngineLighting(true)
        render.SetLocalModelLights({})
        render.ResetModelLighting(0.78, 0.78, 0.78)
        render.SetModelLighting(BOX_TOP, 1, 1, 1)
        render.SetModelLighting(BOX_BOTTOM, 0.45, 0.45, 0.45)
        render.SetColorModulation(1, 1, 1)
        render.SetBlend(1)
        render.OverrideAlphaWriteEnable(true, true)
        render.SetWriteDepthToDestAlpha(false)
        for frame = 0, 7 do
            standIn:SetCycle(frame / 8)
            standIn:InvalidateBoneCache()
            standIn:SetupBones()
            for view = 0, 7 do
                local ang = math.rad(view * 45)
                camView.origin = center + Vector(math.cos(ang), math.sin(ang), 0) * 300
                camView.angles = Angle(0, view * 45 + 180, 0)
                camView.x = ((view % 4) * 8 + frame) * layer.cellW
                camView.y = ((i - 1) * 2 + (view >= 4 and 1 or 0)) * layer.cellH
                cam.Start(camView)
                render.FogMode(MATERIAL_FOG_NONE)
                standIn:DrawModel()
                cam.End3D()
            end
        end

        render.OverrideAlphaWriteEnable(false)
        render.SuppressEngineLighting(false)
        render.PopRenderTarget()
    end
end

hook.Add("PostRender", "hordez_impostor_bake", function()
    if not bakeAt then return end

    local ok, err = pcall(BakeVariant, bakeAt)
    if not ok then
        ErrorNoHalt("[hordez] impostor bake failed, impostors are off: " .. tostring(err) .. "\n")
        bakeAt = nil
        return
    end

    bakeAt = bakeAt + 1
    if bakeAt > #VARIANTS then
        bakeAt = nil
        for _, model in ipairs(bakeModels) do
            if IsValid(model) then model:Remove() end
        end

        bakeModels = {}
        for _, layer in ipairs(LAYERS) do layer.mat:SetTexture("$basetexture", layer.rt) end
        ready = true
    end
end)

function HZ.BakeImpostors()
    if not ready and not bakeAt and cvOn:GetBool() then StartBake() end
end

hook.Add("OnScreenSizeChanged", "hordez_impostors", function()
    if ready or bakeAt then StartBake() end
end)

concommand.Add("hz_impostor_rebake", StartBake)

local count = 0
local STRIDE = 15
local BUCKETS = 8
local BUCKET_QUADS = MAX_QUADS / BUCKETS
local EPOCH_SPAN = 300
local FADE_BAND = 0.85
local FADE_PULL = 20
local epoch = 0
local nextBucket, nextBucketAt = 0, 0
local bucketCounts = {}

for _, layer in ipairs(LAYERS) do
    for b = 0, BUCKETS - 1 do layer.buckets[b] = { quads = {}, count = 0 } end
end

for b = 0, BUCKETS - 1 do bucketCounts[b] = 0 end

local atan2, floor, cos, sin, min, max, sqrt = math.atan2, math.floor, math.cos, math.sin, math.min, math.max, math.sqrt
local PI = math.pi
local lightAt = Vector()

local ex, ey, bright = 0, 0, 127.5

local function EmitQuad(bucket, cache, now, x, y, z, vx, vy, moving, facing, idx, female, shambler, dist, fade)
    local target = (dist < NEAR_DIST and nearLayer or farLayer).buckets[bucket]
    local quads = target.quads
    local variant
    if not moving then
        variant = female and V_IDLE_F or V_IDLE_M
    elseif shambler then
        variant = V_SHAMBLE
    elseif female then
        variant = V_RUN_F[idx % 2 + 1]
    else
        variant = V_RUN_M[idx % 3 + 1]
    end

    local bearing = atan2(ey - y, ex - x)
    local cb, sb = cos(bearing), sin(bearing)
    local view = floor((bearing - facing) / (PI / 4) + 0.5) % 8
    if not cache.hz_ilt or now > cache.hz_ilt then
        cache.hz_ilt = now + 2 + (idx % 16) / 16
        lightAt:SetUnpacked(x, y, z + 40)
        local light = render.GetLightColor(lightAt)
        local lr, lg, lb = light.x, light.y, light.z
        if lr + lg + lb < 0.03 then lr, lg, lb = 0.35, 0.35, 0.35 end
        cache.hz_ilr, cache.hz_ilg, cache.hz_ilb = lr, lg, lb
    end

    if fade < 1 then
        x, y = x + cb * FADE_PULL, y + sb * FADE_PULL
    end

    local age = now - epoch
    local base = target.count * STRIDE
    target.count = target.count + 1
    quads[base + 1], quads[base + 2], quads[base + 3] = x - vx * age, y - vy * age, z
    quads[base + 4], quads[base + 5] = -sb * HALF_W, cb * HALF_W
    quads[base + 6] = ((view % 4) * 8) * DU
    quads[base + 7] = (variant * 2 + (view >= 4 and 1 or 0)) * DV
    quads[base + 8], quads[base + 9] = vx, vy
    quads[base + 10] = (idx * 0.618034) % 1
    quads[base + 11] = rates[variant] or 1
    quads[base + 12] = min(cache.hz_ilr * bright, 255)
    quads[base + 13] = min(cache.hz_ilg * bright, 255)
    quads[base + 14] = min(cache.hz_ilb * bright, 255)
    quads[base + 15] = fade * 255
end

local function GatherBucket(bucket, now)
    local list = HZ.ClientZombies
    local count = 0
    local want = cvOn:GetBool() and ready
    local fadeEnd = cvDist:GetFloat()
    local fadeStart = fadeEnd * FADE_BAND
    local fadeStartSqr = fadeStart * fadeStart
    local eye = EyePos()
    ex, ey = eye.x, eye.y
    local ez = eye.z
    bright = cvLight:GetFloat() * 127.5
    local syncNoDraw = HZ.SyncNoDraw

    farLayer.buckets[bucket].count, nearLayer.buckets[bucket].count = 0, 0

    for i = 1, #list do
        local ent = list[i]
        if IsValid(ent) and ent:EntIndex() % BUCKETS == bucket then
            local distSqr = ent.hz_d2
            local impostor = want and distSqr and not ent.hz_ragdolled and not ent:IsDormant()
                and distSqr > fadeStartSqr and count < BUCKET_QUADS

            if not impostor then
                if ent.hz_imp then
                    ent.hz_imp, ent.hz_ipt, ent.hz_fade = nil, nil, nil
                    syncNoDraw(ent)
                end
            else
                local dist = sqrt(distSqr)
                local fade = min((dist - fadeStart) / max(fadeEnd - fadeStart, 1), 1)
                ent.hz_imp, ent.hz_fade = true, fade
                syncNoDraw(ent)
                local pos = ent:GetPos()
                local x, y, z = pos.x, pos.y, pos.z
                local vx, vy = 0, 0
                local lastTime = ent.hz_ipt
                if lastTime and now > lastTime and now - lastTime < 1 then
                    local invDt = 1 / (now - lastTime)
                    vx, vy = (x - ent.hz_ipx) * invDt, (y - ent.hz_ipy) * invDt
                end

                ent.hz_ipx, ent.hz_ipy, ent.hz_ipt = x, y, now
                local moving = vx * vx + vy * vy > 400
                local female = ent.hz_ifem
                if female == nil then
                    female = (ent:GetModel() or ""):find("female", 1, true) ~= nil
                    ent.hz_ifem = female
                end

                local shambler = ent.hz_isham
                if shambler == nil then
                    shambler = ent:GetNW2Bool("hz_shambler")
                    ent.hz_isham = shambler
                end

                EmitQuad(bucket, ent, now, x, y, z, vx, vy, moving, moving and atan2(vy, vx)
                    or ent:GetAngles().y * (PI / 180),
                    ent:EntIndex(), female, shambler, dist, fade)

                count = count + 1
            end
        end
    end

    if ready then
        local posAt = HZ.VirtualAt
        local vBucket = HZ.VirtualBuckets[bucket]
        for id, row in pairs(vBucket) do
            if count >= BUCKET_QUADS then break end

            local group = row.group
            local x, y, z = posAt(row, now)
            local moving = now < group.t1
            local dx, dy, dz = x - ex, y - ey, z - ez
            EmitQuad(bucket, row, now, x, y, z, moving and group.vx or 0, moving and group.vy or 0, moving,
                group.yaw, id, row.female, row.shambler, sqrt(dx * dx + dy * dy + dz * dz), 1)

            count = count + 1
        end
    end

    return count
end

local Position, TexCoord, Color, AdvanceVertex = mesh.Position, mesh.TexCoord, mesh.Color, mesh.AdvanceVertex

local function FillMesh(bucket, inset)
    local quads = bucket.quads
    for i = 0, bucket.count - 1 do
        local base = i * STRIDE
        local x, y, z, rx, ry = quads[base + 1], quads[base + 2], quads[base + 3], quads[base + 4], quads[base + 5]
        local u0, v0 = quads[base + 6] + inset, quads[base + 7] + inset
        local u1, v1 = quads[base + 6] + DU - inset, quads[base + 7] + DV - inset
        local vx, vy, phase, rate = quads[base + 8], quads[base + 9], quads[base + 10], quads[base + 11]
        local r, g, b, a = quads[base + 12], quads[base + 13], quads[base + 14], quads[base + 15]
        Position(x - rx, y - ry, z + Z_HI)
        TexCoord(0, u0, v0)
        TexCoord(1, vx, vy)
        TexCoord(2, phase, rate)
        Color(r, g, b, a)
        AdvanceVertex()
        Position(x + rx, y + ry, z + Z_HI)
        TexCoord(0, u1, v0)
        TexCoord(1, vx, vy)
        TexCoord(2, phase, rate)
        Color(r, g, b, a)
        AdvanceVertex()
        Position(x + rx, y + ry, z + Z_LO)
        TexCoord(0, u1, v1)
        TexCoord(1, vx, vy)
        TexCoord(2, phase, rate)
        Color(r, g, b, a)
        AdvanceVertex()
        Position(x - rx, y - ry, z + Z_LO)
        TexCoord(0, u0, v1)
        TexCoord(1, vx, vy)
        TexCoord(2, phase, rate)
        Color(r, g, b, a)
        AdvanceVertex()
    end
end

local function RebuildBucket(b, now)
    local ok, quadCount = pcall(GatherBucket, b, now)
    if not ok then
        ErrorNoHalt("[hordez] impostor rebuild failed: " .. tostring(quadCount) .. "\n")
        quadCount = 0
        farLayer.buckets[b].count, nearLayer.buckets[b].count = 0, 0
    end

    count = count - bucketCounts[b] + quadCount
    bucketCounts[b] = quadCount
    for _, layer in ipairs(LAYERS) do
        local bucket = layer.buckets[b]
        if bucket.imesh then
            bucket.imesh:Destroy()
            bucket.imesh = nil
        end

        if bucket.count > 0 then
            bucket.imesh = Mesh(layer.mat)
            mesh.Begin(bucket.imesh, MATERIAL_QUADS, bucket.count)
            local filled, err = pcall(FillMesh, bucket, layer.inset)
            mesh.End()
            if not filled then
                ErrorNoHalt("[hordez] impostor mesh failed: " .. tostring(err) .. "\n")
                bucket.imesh:Destroy()
                bucket.imesh = nil
            end
        end
    end
end

local function Rebuild(now)
    if now - epoch > EPOCH_SPAN then
        epoch = now
        for b = 0, BUCKETS - 1 do RebuildBucket(b, now) end

        nextBucketAt = now + REBUILD / BUCKETS

        return
    end

    if now < nextBucketAt then return end

    nextBucketAt = now + REBUILD / BUCKETS
    RebuildBucket(nextBucket, now)
    nextBucket = (nextBucket + 1) % BUCKETS
end

local carrier
local lastScrW, lastScrH, lastFogR, lastFogG, lastFogB

local function ShaderClock(since, clock)
    local fog, fogEnd, fogRange = 0, 1, 1
    local mode = render.GetFogMode()
    local fogStart, fogStop = render.GetFogDistances()
    if cvFog:GetBool() and mode ~= MATERIAL_FOG_NONE and mode ~= MATERIAL_FOG_LINEAR_BELOW_FOG_Z and fogStart
        and fogStop and fogStop > fogStart then
        fog, fogEnd, fogRange = 1, fogStop, fogStop - fogStart
        local r, g, b = render.GetFogColor()
        if r ~= lastFogR or g ~= lastFogG or b ~= lastFogB then
            lastFogR, lastFogG, lastFogB = r, g, b
            local lr, lg, lb = (r / 255) ^ 2.2, (g / 255) ^ 2.2, (b / 255) ^ 2.2
            for _, layer in ipairs(LAYERS) do
                layer.mat:SetFloat("$c0_x", lr)
                layer.mat:SetFloat("$c0_y", lg)
                layer.mat:SetFloat("$c0_z", lb)
            end
        end
    end

    local w, h = ScrW(), ScrH()
    if w ~= lastScrW or h ~= lastScrH then
        lastScrW, lastScrH = w, h
        for _, layer in ipairs(LAYERS) do
            layer.mat:SetFloat("$c1_x", w)
            layer.mat:SetFloat("$c1_y", h)
        end
    end

    if not IsValid(carrier) then
        carrier = ClientsideModel("models/props_junk/popcan01a.mdl")
        if not IsValid(carrier) then return end

        carrier:SetNoDraw(true)
        carrier:SetModelScale(0)
    end

    render.SuppressEngineLighting(true)
    render.SetModelLighting(0, since, clock, fog)
    render.SetModelLighting(1, fogEnd, fogRange, math.Clamp(GetGlobalFloat("hz_fog_density", 1), 0, 1))
    carrier:DrawModel()
    render.SuppressEngineLighting(false)
end

hook.Add("PostDrawOpaqueRenderables", "hordez_impostors", function(depth, sky, sky3d)
    if depth or sky or sky3d then return end

    local now = CurTime()
    if not ready and not bakeAt and ((cvOn:GetBool() and #HZ.ClientZombies > 0) or next(HZ.VirtualCl)) then
        StartBake()
    end

    Rebuild(now)
    if count == 0 then return end

    ShaderClock(now - epoch, now % 4096)
    render.OverrideDepthEnable(true, true)
    for _, layer in ipairs(LAYERS) do
        render.SetMaterial(layer.mat)
        for b = 0, BUCKETS - 1 do
            local imesh = layer.buckets[b].imesh
            if imesh then imesh:Draw() end
        end
    end

    render.OverrideDepthEnable(false, false)
end)

hook.Add("HUDPaint", "hordez_impostor_debug", function()
    if not cvDebug:GetBool() then return end

    surface.SetDrawColor(40, 40, 40, 255)
    surface.DrawRect(16, 16, 512, 512)
    surface.SetDrawColor(255, 255, 255, 255)
    surface.SetMaterial(dbgMat)
    surface.DrawTexturedRect(16, 16, 512, 512)
    draw.SimpleText(("impostors: %d (%d virtual)   atlas: %s"):format(count, table.Count(HZ.VirtualCl), ready
        and "ready" or (bakeAt and "baking" or "not baked")),
        "DermaDefault", 20, 532, color_white)
end)

hook.Add("PostCleanupMap", "hordez_impostors", function()
    for _, layer in ipairs(LAYERS) do
        for b = 0, BUCKETS - 1 do
            local bucket = layer.buckets[b]
            if bucket.imesh then bucket.imesh:Destroy() end
            bucket.imesh, bucket.count = nil, 0
        end
    end

    for b = 0, BUCKETS - 1 do bucketCounts[b] = 0 end

    count = 0
end)
