HZ.CustomModels = HZ.CustomModels or {}
HZ.CustomModelSet = HZ.CustomModelSet or {}

local MAX_MODELS = 64

net.Receive("hz_models", function()
    local list, set = {}, {}
    for i = 1, net.ReadUInt(8) do
        list[i] = net.ReadString()
        set[list[i]] = true
    end

    HZ.CustomModels, HZ.CustomModelSet = list, set
    HZ.CustomShare = net.ReadFloat()
    if HZ.WarmModel then
        for i = 1, #list do HZ.WarmModel(list[i]) end
    end

    HZ.RebakeImpostors()
end)

local function RequestModels()
    net.Start("hz_models")
    net.SendToServer()
end

hook.Add("InitPostEntity", "hordez_models", RequestModels)
if IsValid(LocalPlayer and LocalPlayer()) then RequestModels() end

function HZ.SendCustomModels(set)
    local list = {}
    for path in pairs(set) do list[#list + 1] = path end

    table.sort(list)
    local count = math.min(#list, MAX_MODELS)
    net.Start("hz_models_set")
    net.WriteUInt(count, 8)
    for i = 1, count do net.WriteString(list[i]) end

    net.SendToServer()
end

function HZ.ToggleCustomModel(path)
    local set = table.Copy(HZ.CustomModelSet)
    set[path] = not set[path] or nil
    HZ.SendCustomModels(set)
end

local OVERLAY_EFFECTS = bit.bor(EF_BONEMERGE, EF_BONEMERGE_FASTCULL)
local OVERLAY_POOL_MAX = 64
local overlayPool, overlayPoolCount = {}, 0

local function ReleaseOverlayEnt(overlay)
    if not IsValid(overlay) then return end

    local path = overlay.hz_path
    if path and overlayPoolCount < OVERLAY_POOL_MAX then
        overlay:SetParent(nil)
        overlay:SetNoDraw(true)
        overlay:DrawShadow(false)
        local bucket = overlayPool[path]
        if not bucket then
            bucket = {}
            overlayPool[path] = bucket
        end

        bucket[#bucket + 1] = overlay
        overlayPoolCount = overlayPoolCount + 1
    else
        overlay:Remove()
    end
end

function HZ.ReleaseOverlay(ent)
    if not IsValid(ent) then return end

    local overlay = ent.hz_overlay
    ent.hz_overlay = nil
    ReleaseOverlayEnt(overlay)
end

local function AcquireOverlay(path)
    local bucket = overlayPool[path]
    if bucket then
        while #bucket > 0 do
            local overlay = bucket[#bucket]
            bucket[#bucket] = nil
            overlayPoolCount = overlayPoolCount - 1
            if IsValid(overlay) then return overlay end
        end
    end

    local overlay = ClientsideModel(path, RENDERGROUP_OPAQUE)
    if not IsValid(overlay) then return nil end

    overlay.hz_path = path
    overlay:SetNoDraw(true)
    overlay:DrawShadow(false)
    overlay:SetIK(false)

    return overlay
end

local function Overlay(ent, path)
    local overlay = ent.hz_overlay
    if IsValid(overlay) and overlay.hz_path == path then return overlay end

    if IsValid(overlay) then ReleaseOverlayEnt(overlay) end

    overlay = AcquireOverlay(path)
    if not overlay then return nil end

    overlay:SetPos(ent:GetPos())
    overlay:SetAngles(ent:GetAngles())
    overlay:SetParent(ent)
    overlay:AddEffects(OVERLAY_EFFECTS)
    overlay:SetLOD(ent.hz_lod or -1)
    overlay:InvalidateBoneCache()
    ent.hz_overlay = overlay
    ent:CallOnRemove("hordez_overlay", function()
        HZ.ReleaseOverlay(ent)
    end)

    return overlay
end

hook.Add("PostCleanupMap", "hordez_overlay_pool", function()
    for path, bucket in pairs(overlayPool) do
        for i = 1, #bucket do
            if IsValid(bucket[i]) then bucket[i]:Remove() end
        end

        overlayPool[path] = nil
    end

    overlayPoolCount = 0
end)

function HZ.DrawCustom(ent, path, flags)
    local overlay = Overlay(ent, path)
    if not overlay then
        ent:DrawModel(flags)

        return
    end

    if ent.hz_dormant or overlay:GetParent() ~= ent or not overlay:IsEffectActive(EF_BONEMERGE) then
        ent.hz_dormant = nil
        overlay:SetParent(nil)
        overlay:SetPos(ent:GetPos())
        overlay:SetAngles(ent:GetAngles())
        overlay:SetParent(ent)
        overlay:AddEffects(OVERLAY_EFFECTS)
        overlay:InvalidateBoneCache()
    end

    overlay:DrawModel(flags)
end
