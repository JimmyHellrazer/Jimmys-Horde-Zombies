HZ.VirtualCl = HZ.VirtualCl or {}
local rows = HZ.VirtualCl
local sqrt = math.sqrt

local function PosAt(row, now)
    local t0, t1 = row.t0, row.t1
    if now >= t1 or t1 <= t0 then return row.wx, row.wy, row.wz end

    local frac = (now - t0) / (t1 - t0)

    return row.x + (row.wx - row.x) * frac, row.y + (row.wy - row.y) * frac, row.z + (row.wz - row.z) * frac
end

HZ.VirtualAt = PosAt

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
        local id = net.ReadUInt(16)
        local x, y, z = net.ReadInt(16), net.ReadInt(16), net.ReadInt(16)
        local speed = net.ReadUInt(10)
        local female, shambler = net.ReadBool(), net.ReadBool()
        rows[id] = { id = id, x = x, y = y, z = z, wx = x, wy = y, wz = z, t0 = now, t1 = now,
            speed = math.max(speed, 5),
            female = female, shambler = shambler, yaw = 0 }
    end

    for _ = 1, net.ReadUInt(16) do
        local id = net.ReadUInt(16)
        local wx, wy, wz = net.ReadInt(16), net.ReadInt(16), net.ReadInt(16)
        local row = rows[id]
        if row then
            local x, y, z = PosAt(row, now)
            local dx, dy, dz = wx - x, wy - y, wz - z
            local dist = sqrt(dx * dx + dy * dy + dz * dz)
            row.x, row.y, row.z, row.wx, row.wy, row.wz = x, y, z, wx, wy, wz
            row.t0, row.t1 = now, now + dist / row.speed
            if dist > 1 then
                row.yaw = math.atan2(dy, dx)
                row.vx, row.vy = dx / dist * row.speed, dy / dist * row.speed
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
end)
