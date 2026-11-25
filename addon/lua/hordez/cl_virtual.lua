HZ.VirtualCl = HZ.VirtualCl or {}
HZ.VirtualGroups = HZ.VirtualGroups or {}
local rows, groups = HZ.VirtualCl, HZ.VirtualGroups
local sqrt = math.sqrt

local function GroupPos(group, now)
    local t0, t1 = group.t0, group.t1
    if now >= t1 or t1 <= t0 then return group.wx, group.wy, group.wz end

    local frac = (now - t0) / (t1 - t0)

    return group.x + (group.wx - group.x) * frac, group.y + (group.wy - group.y) * frac,
        group.z + (group.wz - group.z) * frac
end

local function PosAt(row, now)
    local x, y, z = GroupPos(row.group, now)

    return x + row.ox, y + row.oy, z
end

HZ.VirtualAt = PosAt

local function ReadPos()
    return net.ReadInt(16), net.ReadInt(16), net.ReadInt(16)
end

net.Receive("hz_virt", function()
    local now = CurTime()
    for _ = 1, net.ReadUInt(16) do
        local id = net.ReadUInt(16)
        local killed = net.ReadBool()
        local row = rows[id]
        rows[id] = nil
        if row and killed then
            local x, y, z = PosAt(row, now)
            local effect = EffectData()
            effect:SetOrigin(Vector(x, y, z + 44))
            effect:SetNormal(vector_up)
            util.Effect("BloodImpact", effect, true, true)
        end
    end

    for _ = 1, net.ReadUInt(16) do
        groups[net.ReadUInt(16)] = nil
    end

    for _ = 1, net.ReadUInt(16) do
        local id = net.ReadUInt(16)
        local x, y, z = ReadPos()
        local speed = net.ReadUInt(10)
        groups[id] = { id = id, x = x, y = y, z = z, wx = x, wy = y, wz = z, t0 = now, t1 = now,
            speed = math.max(speed, 5), vx = 0, vy = 0, yaw = 0 }
    end

    for _ = 1, net.ReadUInt(16) do
        local id = net.ReadUInt(16)
        local group = groups[net.ReadUInt(16)]
        local ox, oy = net.ReadInt(9), net.ReadInt(9)
        local female, shambler = net.ReadBool(), net.ReadBool()
        if group then
            rows[id] = { id = id, group = group, ox = ox, oy = oy, female = female, shambler = shambler }
        end
    end

    for _ = 1, net.ReadUInt(16) do
        local group = groups[net.ReadUInt(16)]
        local wx, wy, wz = ReadPos()
        if group then
            local x, y, z = GroupPos(group, now)
            local dx, dy, dz = wx - x, wy - y, wz - z
            local dist = sqrt(dx * dx + dy * dy + dz * dz)
            group.x, group.y, group.z, group.wx, group.wy, group.wz = x, y, z, wx, wy, wz
            group.t0, group.t1 = now, now + dist / group.speed
            if dist > 1 then
                group.yaw = math.atan2(dy, dx)
                group.vx, group.vy = dx / dist * group.speed, dy / dist * group.speed
            end
        end
    end
end)

local function RequestSync()
    net.Start("hz_virt_sync")
    net.SendToServer()
end

hook.Add("InitPostEntity", "hordez_virtual", RequestSync)
if IsValid(LocalPlayer and LocalPlayer()) then RequestSync() end

hook.Add("PostCleanupMap", "hordez_virtual", function()
    for id in pairs(rows) do rows[id] = nil end
    for id in pairs(groups) do groups[id] = nil end
end)
