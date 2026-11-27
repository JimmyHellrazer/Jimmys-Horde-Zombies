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

local function Overlay(ent, path)
    local overlay = ent.hz_overlay
    if IsValid(overlay) and overlay.hz_path == path then return overlay end

    if IsValid(overlay) then overlay:Remove() end

    overlay = ClientsideModel(path, RENDERGROUP_OPAQUE)
    if not IsValid(overlay) then return nil end

    overlay.hz_path = path
    overlay:SetNoDraw(true)
    overlay:SetParent(ent)
    overlay:AddEffects(OVERLAY_EFFECTS)
    ent.hz_overlay = overlay
    ent:CallOnRemove("hordez_overlay", function()
        if IsValid(ent.hz_overlay) then ent.hz_overlay:Remove() end
    end)

    return overlay
end

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
