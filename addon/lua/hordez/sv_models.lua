util.AddNetworkString("hz_models")
util.AddNetworkString("hz_models_set")

local SAVE_FILE = "hordez/models.json"
local MAX_MODELS = 64

HZ.CustomModels = HZ.CustomModels or {}

local function Send(ply)
    net.Start("hz_models")
    net.WriteUInt(#HZ.CustomModels, 8)
    for _, path in ipairs(HZ.CustomModels) do net.WriteString(path) end

    net.WriteFloat(HZ.CV.custom_share:GetFloat())
    if ply then
        net.Send(ply)
    else
        net.Broadcast()
    end
end

local function Apply(list)
    local clean, seen = {}, {}
    for _, path in ipairs(list) do
        path = string.lower(string.Trim(tostring(path)))
        if #clean < MAX_MODELS and not seen[path] and path:match("^models/[%w_%-%./]+%.mdl$")
            and util.IsValidModel(path) then
            seen[path] = true
            clean[#clean + 1] = path
            util.PrecacheModel(path)
        end
    end

    HZ.CustomModels = clean
end

function HZ.PickCustomModel()
    local list = HZ.CustomModels
    if #list == 0 or math.random() >= HZ.CV.custom_share:GetFloat() then return false end

    return list[math.random(#list)]
end

hook.Add("InitPostEntity", "hordez_models", function()
    local saved = util.JSONToTable(file.Read(SAVE_FILE, "DATA") or "")
    if istable(saved) then Apply(saved) end
end)

net.Receive("hz_models", function(_, ply)
    Send(ply)
end)

cvars.AddChangeCallback("hz_custom_share", function()
    Send()
end, "hordez_models")

net.Receive("hz_models_set", function(_, ply)
    if not IsValid(ply) or not ply:IsSuperAdmin() then return end

    local list = {}
    for i = 1, math.min(net.ReadUInt(8), MAX_MODELS) do list[i] = net.ReadString() end

    Apply(list)
    file.CreateDir("hordez")
    file.Write(SAVE_FILE, util.TableToJSON(HZ.CustomModels))
    Send()
end)
