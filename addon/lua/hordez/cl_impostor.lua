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
        quads = {}, count = 0 }
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

hook.Add("OnScreenSizeChanged", "hordez_impostors", function()
    if ready or bakeAt then StartBake() end
end)

concommand.Add("hz_impostor_rebake", StartBake)

local count = 0
local builtAt, nextBuild = 0, 0
local STRIDE = 15

local atan2, floor, cos, sin, min, max = math.atan2, math.floor, math.cos, math.sin, math.min, math.max
local PI = math.pi
local lightAt = Vector()

local ex, ey, bright = 0, 0, 127.5

local function EmitQuad(cache, now, x, y, z, vx, vy, moving, facing, idx, female, shambler, dist)
    local layer = dist < NEAR_DIST and nearLayer or farLayer
    local quads = layer.quads
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
    local view = floor((bearing - facing) / (PI / 4) + 0.5) % 8
    if not cache.hz_ilt or now > cache.hz_ilt then
        cache.hz_ilt = now + 2 + (idx % 16) / 16
        lightAt:SetUnpacked(x, y, z + 40)
        local light = render.GetLightColor(lightAt)
        local lr, lg, lb = light.x, light.y, light.z
        if lr + lg + lb < 0.03 then lr, lg, lb = 0.35, 0.35, 0.35 end
        cache.hz_ilr, cache.hz_ilg, cache.hz_ilb = lr, lg, lb
    end

    local base = layer.count * STRIDE
    layer.count = layer.count + 1
    quads[base + 1], quads[base + 2], quads[base + 3] = x, y, z
    quads[base + 4], quads[base + 5] = -sin(bearing) * HALF_W, cos(bearing) * HALF_W
    quads[base + 6] = ((view % 4) * 8) * DU
    quads[base + 7] = (variant * 2 + (view >= 4 and 1 or 0)) * DV
    quads[base + 8], quads[base + 9] = vx, vy
    quads[base + 10] = (idx * 0.618034) % 1
    quads[base + 11] = rates[variant] or 1
    quads[base + 12] = min(cache.hz_ilr * bright, 255)
    quads[base + 13] = min(cache.hz_ilg * bright, 255)
    quads[base + 14] = min(cache.hz_ilb * bright, 255)
    quads[base + 15] = 255
end

local function GatherQuads(now)
    local list = HZ.ClientZombies
    local count = 0
    local want = cvOn:GetBool() and ready
    local dist = cvDist:GetFloat()
    local nearSqr, farSqr = (dist * 0.92) ^ 2, dist * dist
    local eye = EyePos()
    ex, ey = eye.x, eye.y
    local ez = eye.z
    bright = cvLight:GetFloat() * 127.5

    farLayer.count, nearLayer.count = 0, 0

    for i = 1, #list do
        local ent = list[i]
        if IsValid(ent) then
            local distSqr = ent.hz_d2
            local impostor = want and distSqr and not ent.hz_ragdolled and not ent:IsDormant()
                and distSqr > (ent.hz_imp and nearSqr or farSqr) and count < MAX_QUADS

            if not impostor then
                if ent.hz_imp then ent.hz_imp, ent.hz_ipt = nil, nil end
            else
                ent.hz_imp = true
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

                EmitQuad(ent, now, x, y, z, vx, vy, moving, moving and atan2(vy, vx)
                    or ent:GetAngles().y * (PI / 180),
                    ent:EntIndex(), female, ent:GetNW2Bool("hz_shambler"), distSqr ^ 0.5)

                count = count + 1
            end
        end
    end

    if ready then
        local posAt = HZ.VirtualAt
        for id, row in pairs(HZ.VirtualCl) do
            if count >= MAX_QUADS then break end

            local group = row.group
            local x, y, z = posAt(row, now)
            local moving = now < group.t1
            local dx, dy, dz = x - ex, y - ey, z - ez
            EmitQuad(row, now, x, y, z, moving and group.vx or 0, moving and group.vy or 0, moving, group.yaw, id,
                row.female, row.shambler, (dx * dx + dy * dy + dz * dz) ^ 0.5)

            count = count + 1
        end
    end

    return count
end

local Position, TexCoord, Color, AdvanceVertex = mesh.Position, mesh.TexCoord, mesh.Color, mesh.AdvanceVertex

local function FillMesh(layer)
    local quads, inset = layer.quads, layer.inset
    for i = 0, layer.count - 1 do
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

local function RebuildMesh(now)
    local ok, quadCount = pcall(GatherQuads, now)
    if not ok then
        ErrorNoHalt("[hordez] impostor rebuild failed: " .. tostring(quadCount) .. "\n")
        quadCount = 0
        farLayer.count, nearLayer.count = 0, 0
    end

    count = quadCount
    for _, layer in ipairs(LAYERS) do
        if layer.imesh then
            layer.imesh:Destroy()
            layer.imesh = nil
        end

        if layer.count > 0 then
            layer.imesh = Mesh(layer.mat)
            mesh.Begin(layer.imesh, MATERIAL_QUADS, layer.count)
            local filled, err = pcall(FillMesh, layer)
            mesh.End()
            if not filled then
                ErrorNoHalt("[hordez] impostor mesh failed: " .. tostring(err) .. "\n")
                layer.imesh:Destroy()
                layer.imesh = nil
            end
        end
    end

    builtAt = now
end

local carrier

local function ShaderClock(since, clock)
    local fog, fogEnd, fogRange = 0, 1, 1
    local mode = render.GetFogMode()
    local fogStart, fogStop = render.GetFogDistances()
    if cvFog:GetBool() and mode ~= MATERIAL_FOG_NONE and mode ~= MATERIAL_FOG_LINEAR_BELOW_FOG_Z and fogStart
        and fogStop and fogStop > fogStart then
        fog, fogEnd, fogRange = 1, fogStop, fogStop - fogStart
        local r, g, b = render.GetFogColor()
        for _, layer in ipairs(LAYERS) do
            layer.mat:SetFloat("$c0_x", (r / 255) ^ 2.2)
            layer.mat:SetFloat("$c0_y", (g / 255) ^ 2.2)
            layer.mat:SetFloat("$c0_z", (b / 255) ^ 2.2)
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
    if now >= nextBuild then
        nextBuild = now + REBUILD
        if not ready and not bakeAt and ((cvOn:GetBool() and #HZ.ClientZombies > 0) or next(HZ.VirtualCl)) then
            StartBake()
        end

        RebuildMesh(now)
    end

    if not farLayer.imesh and not nearLayer.imesh then return end

    ShaderClock(now - builtAt, now % 4096)
    render.OverrideDepthEnable(true, true)
    for _, layer in ipairs(LAYERS) do
        if layer.imesh then
            render.SetMaterial(layer.mat)
            layer.imesh:Draw()
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
        if layer.imesh then layer.imesh:Destroy() end
        layer.imesh, layer.count = nil, 0
    end

    count = 0
end)
