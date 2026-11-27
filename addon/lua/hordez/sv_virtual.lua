util.AddNetworkString("hz_virt")
util.AddNetworkString("hz_virt_sync")
util.AddNetworkString("hz_zoom")
util.AddNetworkString("hz_clusters")

local CV = HZ.CV
local Flow = HZ.Flow
HZ.Virtual = HZ.Virtual or {}
HZ.VCount = HZ.VCount or 0
local rows = HZ.Virtual

local sqrt, huge, random, floor, min, max = math.sqrt, math.huge, math.random, math.floor, math.min, math.max
local band, rshift = bit.band, bit.rshift
local SysTime, yield = SysTime, coroutine.yield

local SLICE_BUDGET = 0.002
local sliceEnd = 0
local passes = {}

local function Breathe()
    if SysTime() < sliceEnd then return false end

    yield()

    return true
end

local function SlicedPass(name, interval, profile, run)
    passes[name] = { interval = interval, profile = profile, run = run, nextAt = 0 }
end

hook.Add("Tick", "hordez_virtual_passes", function()
    local now = CurTime()
    for name, pass in pairs(passes) do
        if not pass.co and now >= pass.nextAt then
            pass.co = coroutine.create(pass.run)
            pass.nextAt = now + pass.interval
        end

        if pass.co then
            local t0 = SysTime()
            sliceEnd = t0 + SLICE_BUDGET
            local ok, err = coroutine.resume(pass.co)
            if HZ.ProfOn then HZ.ProfAdd(pass.profile, SysTime() - t0) end
            if not ok then
                ErrorNoHalt("[hordez] " .. name .. " pass failed: " .. tostring(err) .. "\n")
                pass.co = nil
            elseif coroutine.status(pass.co) == "dead" then
                pass.co = nil
            end
        end
    end
end)

function HZ.VirtualOn()
    return CV.virt:GetBool()
end

local GROUP_MAX, GROUP_RADIUS = 24, 90
local groups, groupArr, openGroups = {}, {}, {}
local ID_MAX = 65000
local crowd

local function RowCover(row)
    if crowd then return HZ.NativeLib.CrowdRowCover(crowd, row.id) end

    return row.hz_cover or 0
end

local function SyncMotion(group)
    if not crowd then return end

    HZ.NativeLib.CrowdSetMotion(crowd, group.id, group.x, group.y, group.z, group.wx, group.wy, group.wz, group.t0,
        group.t1)
end

local function AddCrowdGroup(group, now)
    local lib = HZ.NativeLib
    SyncMotion(group)
    lib.CrowdSetShambler(crowd, group.id, group.shambler)
    if lib.CrowdSetGroupSim then lib.CrowdSetGroupSim(crowd, group.id, group.speed, group.area or 0) end
    lib.CrowdNoteGroup(crowd, group.id, now)
end
local ownedCount, ownedHorde = {}, {}

function HZ.VirtualOwned(owner)
    return ownedCount[owner] or 0
end

function HZ.VirtualOwnedHorde(owner)
    return ownedHorde[owner] or 0
end

local function CountOwned(row, delta)
    local owner = row.owner
    if not owner then return end

    ownedCount[owner] = (ownedCount[owner] or 0) + delta
    if row.horde then ownedHorde[owner] = (ownedHorde[owner] or 0) + delta end
    if ownedCount[owner] <= 0 then ownedCount[owner], ownedHorde[owner] = nil, nil end
end

local function IdPool()
    local pool = { nextId = 1, free = {}, cooling = {} }

    function pool:Take()
        local count = #self.free
        if count > 0 then
            local id = self.free[count]
            self.free[count] = nil
            return id
        end

        if self.nextId > ID_MAX then return nil end

        self.nextId = self.nextId + 1

        return self.nextId - 1
    end

    function pool:Release(id)
        self.cooling[#self.cooling + 1] = id
    end

    function pool:Settle()
        for i = 1, #self.cooling do self.free[#self.free + 1] = self.cooling[i] end
        self.cooling = {}
    end

    return pool
end

local rowIds, groupIds = IdPool(), IdPool()
local pendDel, pendGroupDel, pendGroupAdd, pendAdd, pendMove = {}, {}, {}, {}, {}

local function Slice(list, from)
    local out = {}
    for i = from, #list do out[#out + 1] = list[i] end

    return out
end

local function ClampCoord(value)
    return max(-32767, min(32767, floor(value + 0.5)))
end

local function WritePos(x, y, z)
    net.WriteInt(ClampCoord(x), 16)
    net.WriteInt(ClampCoord(y), 16)
    net.WriteInt(ClampCoord(z), 16)
end

local function WriteRowDel(entry)
    net.WriteUInt(rshift(entry, 1), 16)
    net.WriteBool(band(entry, 1) ~= 0)
end

local function WriteGroupDel(id)
    net.WriteUInt(id, 16)
end

local function WriteGroupAdd(group)
    group._pendAdd = nil
    net.WriteUInt(group.id, 16)
    WritePos(group.x, group.y, group.z)
    net.WriteUInt(min(floor(group.speed), 1023), 10)
end

local function WriteRowAdd(row)
    row._pendAdd = nil
    net.WriteUInt(row.id, 16)
    net.WriteUInt(row.group.id, 16)
    net.WriteInt(max(-255, min(255, floor(row.ox + 0.5))), 9)
    net.WriteInt(max(-255, min(255, floor(row.oy + 0.5))), 9)
    net.WriteBool(row.female)
    net.WriteBool(row.shambler)
end

local function WriteGroupMove(group)
    group._pendMove = nil
    net.WriteUInt(group.id, 16)
    WritePos(group.wx, group.wy, group.wz)
end

local CHUNK = 2000

local function WriteList(list, write, blocked)
    local total = #list
    if blocked or total == 0 then
        net.WriteUInt(0, 16)
        return list
    end

    local count = min(total, CHUNK)
    net.WriteUInt(count, 16)
    for i = 1, count do write(list[i]) end
    if count >= total then
        for i = 1, total do list[i] = nil end
        return list
    end

    return Slice(list, count + 1)
end

local function FlushNet()
    while #pendDel > 0 or #pendGroupDel > 0 or #pendGroupAdd > 0 or #pendAdd > 0 or #pendMove > 0 do
        net.Start("hz_virt")
        pendDel = WriteList(pendDel, WriteRowDel, false)
        pendGroupDel = WriteList(pendGroupDel, WriteGroupDel, #pendDel > 0)
        pendGroupAdd = WriteList(pendGroupAdd, WriteGroupAdd, #pendDel > 0 or #pendGroupDel > 0)
        pendAdd = WriteList(pendAdd, WriteRowAdd, #pendDel > 0 or #pendGroupDel > 0 or #pendGroupAdd > 0)
        pendMove = WriteList(pendMove, WriteGroupMove,
            #pendDel > 0 or #pendGroupDel > 0 or #pendGroupAdd > 0 or #pendAdd > 0)

        net.Broadcast()
    end

    rowIds:Settle()
    groupIds:Settle()
end

local function PosAt(group, now)
    local t0, t1 = group.t0, group.t1
    if now >= t1 or t1 <= t0 then return group.wx, group.wy, group.wz end

    local frac = (now - t0) / (t1 - t0)

    return group.x + (group.wx - group.x) * frac, group.y + (group.wy - group.y) * frac,
        group.z + (group.wz - group.z) * frac
end

local function RowPos(row, now)
    local x, y, z = PosAt(row.group, now)

    return x + row.ox, y + row.oy, z
end

local function NewGroup(pos, speed, shambler, area)
    local id = groupIds:Take()
    if not id then return nil end

    local now = CurTime()
    local group = { id = id, x = pos.x, y = pos.y, z = pos.z, wx = pos.x, wy = pos.y, wz = pos.z, t0 = now, t1 = now,
        speed = max(speed, 5), shambler = shambler, area = area, count = 0, rows = {}, _pendAdd = true }

    groups[id] = group
    local gi = #groupArr + 1
    groupArr[gi] = group
    group._gi = gi
    openGroups[id] = group
    pendGroupAdd[#pendGroupAdd + 1] = group
    if crowd then AddCrowdGroup(group, now) end

    return group
end

local function OpenGroupNear(pos, shambler, now)
    if crowd then
        local id = HZ.NativeLib.CrowdJoin(crowd, now, pos.x, pos.y, pos.z, shambler, GROUP_RADIUS, GROUP_MAX, 60)

        return id and groups[id]
    end

    local best, bestDist
    for _, group in pairs(openGroups) do
        if group.shambler == shambler and group.count < GROUP_MAX then
            local x, y, z = PosAt(group, now)
            local dx, dy = pos.x - x, pos.y - y
            local distSqr = dx * dx + dy * dy
            if distSqr < GROUP_RADIUS * GROUP_RADIUS and math.abs(pos.z - z) < 60
                and (not bestDist or distSqr < bestDist) then
                best, bestDist = group, distSqr
            end
        end
    end

    return best
end

local function JoinGroup(row, pos, speed, area)
    local now = CurTime()
    local best = OpenGroupNear(pos, row.shambler, now) or NewGroup(pos, speed, row.shambler, area)
    if not best then return false end

    local x, y = PosAt(best, now)
    row.group, row.ox, row.oy = best, pos.x - x, pos.y - y
    best.rows[row.id] = row
    best.count = best.count + 1
    if best.count >= GROUP_MAX then openGroups[best.id] = nil end

    return true
end

local SyncCrowd

function HZ.AddVirtual(pos, opts)
    SyncCrowd()
    local id = rowIds:Take()
    if not id then return nil end

    opts = opts or {}
    local shambler = opts.shambler
    if shambler == nil then shambler = random() < CV.sh_chance:GetFloat() end
    local model = opts.model or HZ.RandomModel()
    local speed = opts.speed
    if not speed then
        if shambler then
            speed = math.Rand(CV.sh_speed_lo:GetFloat(), max(CV.sh_speed_lo:GetFloat(), CV.sh_speed_hi:GetFloat()))
        else
            local variance = math.Clamp(CV.speed_var:GetFloat(), 0, 0.9)
            speed = CV.runspeed:GetFloat() * math.Rand(1 - variance, 1 + variance)
        end
    end

    local row = { id = id, shambler = shambler and true or false, model = model, speed = speed,
        female = model:find("female", 1, true) ~= nil, hp = opts.hp or 1, born = CurTime(), hz_cover = opts.cover,
        custom = opts.custom,
        owner = IsValid(opts.owner) and opts.owner or nil, horde = opts.horde and true or nil, omni = opts.omni,
        maxHp = opts.maxHp }

    if not JoinGroup(row, pos, speed, opts.area) then
        rowIds:Release(id)
        return nil
    end

    rows[id] = row
    HZ.VCount = HZ.VCount + 1
    if crowd then HZ.NativeLib.CrowdSetRow(crowd, id, row.group.id, row.ox, row.oy, row.hz_cover or 0) end
    CountOwned(row, 1)
    row._pendAdd = true
    pendAdd[#pendAdd + 1] = row

    return row
end

local function Forget(list, item)
    for i = #list, 1, -1 do
        if list[i] == item then
            table.remove(list, i)
            return true
        end
    end

    return false
end

local function DropGroup(group)
    if groups[group.id] ~= group then return end

    groups[group.id] = nil
    if crowd then HZ.NativeLib.CrowdDropGroup(crowd, group.id) end
    local gi = group._gi
    if gi then
        local last = #groupArr
        if gi ~= last then
            local moved = groupArr[last]
            groupArr[gi] = moved
            moved._gi = gi
        end
        groupArr[last] = nil
        group._gi = nil
    end
    openGroups[group.id] = nil
    groupIds:Release(group.id)
    if group._pendMove then
        group._pendMove = nil
        Forget(pendMove, group)
    end

    if group._pendAdd then
        group._pendAdd = nil
        Forget(pendGroupAdd, group)
    else
        pendGroupDel[#pendGroupDel + 1] = group.id
    end
end

local function DropRow(row, killed)
    if rows[row.id] ~= row then return end

    if crowd then HZ.NativeLib.CrowdRemoveRow(crowd, row.id) end
    rows[row.id] = nil
    HZ.VCount = HZ.VCount - 1
    CountOwned(row, -1)
    rowIds:Release(row.id)
    if row._pendAdd then
        row._pendAdd = nil
        Forget(pendAdd, row)
    else
        pendDel[#pendDel + 1] = row.id * 2 + (killed and 1 or 0)
    end

    local group = row.group
    group.rows[row.id] = nil
    group.count = group.count - 1
    if group.count <= 0 then
        DropGroup(group)
    elseif group.count < GROUP_MAX then
        openGroups[group.id] = group
    end
end

function HZ.DropVirtualOwned(owner)
    if not ownedCount[owner] then return end

    for _, row in pairs(rows) do
        if row.owner == owner then DropRow(row, false) end
    end

    FlushNet()
end

function HZ.ClearVirtual()
    for _, row in pairs(rows) do DropRow(row, false) end
    for _, group in pairs(groups) do DropGroup(group) end
    FlushNet()
end

local STEP, LEG_TIME = 260, 1.2
local FAR_LEG_DIST, FAR_LEG_SCALE = 3000, 4
local probe = Vector()

local function PlanLeg(group, now, x, y, z)
    local graph = Flow.graph
    if not graph or not Flow.ready then
        group.t1 = now + 1
        return
    end

    local area = group.area
    if not area or not graph.area[area] then
        probe:SetUnpacked(x, y, z)
        local navArea = navmesh.GetNearestNavArea(probe, false, 400, false, true)
        area = navArea and navArea:GetID()
        if not area or not graph.area[area] then
            group.t1 = now + 2
            return
        end

        group.area = area
    end

    if not group.gx then
        local nextId = Flow.nxt[area]
        if nextId == false then
            local target = Flow.tgt[area]
            if not IsValid(target) then
                group.t1 = now + 0.5
                return
            end

            local pos = target:GetPos()
            local cur = graph.area[area]
            if IsValid(cur) then
                pos = cur:GetClosestPointOnArea(pos) or pos
                pos.z = cur:GetZ(pos)
            end

            group.gx, group.gy, group.gz, group.garea, group.gextra = pos.x, pos.y, pos.z, nil, 0
        elseif nextId then
            local nextArea = graph.area[nextId]
            if not IsValid(nextArea) then
                group.t1 = now + 1
                return
            end

            probe:SetUnpacked(x, y, z)
            local pos = nextArea:GetClosestPointOnArea(probe)
            local center = graph.center[nextId]
            local frac = 0.2 + random() * 0.7
            group.gx, group.gy, group.gz = pos.x + (center.x - pos.x) * frac, pos.y + (center.y - pos.y) * frac,
                pos.z + (center.z - pos.z) * frac

            group.garea = nextId
            group.fv = Flow.version
            group.gextra = Flow.ClimbLink(area, nextId) and (0.6 + math.abs(pos.z - z) / 80) or 0
        else
            group.t1 = now + 1
            return
        end
    end

    local dx, dy = group.gx - x, group.gy - y
    local dist = sqrt(dx * dx + dy * dy)
    local tx, ty, tz, extra = nil, nil, nil, 0
    local reach = min(max(sqrt(group.nearest or 0) / FAR_LEG_DIST, 1), FAR_LEG_SCALE)
    local STEP = max(40, min(STEP, group.speed * LEG_TIME) * reach)
    if dist <= STEP then
        tx, ty, tz, extra = group.gx, group.gy, group.gz, group.gextra or 0
        if group.garea then group.area = group.garea end
        group.gx = nil
    else
        tx, ty = x + dx / dist * STEP, y + dy / dist * STEP
        probe:SetUnpacked(tx, ty, z)
        local nextArea, cur = group.garea and graph.area[group.garea], graph.area[area]
        if nextArea and IsValid(nextArea) and nextArea:IsOverlapping(probe, 2) then
            tz = nextArea:GetZ(probe)
        elseif IsValid(cur) and cur:IsOverlapping(probe, 2) then
            tz = cur:GetZ(probe)
        else
            tz = z + (group.gz - z) * (STEP / dist)
        end

        if not group.garea then group.gx = nil end
    end

    local ex, ey, ez = tx - x, ty - y, tz - z
    local len = sqrt(ex * ex + ey * ey + ez * ez)
    group.x, group.y, group.z, group.t0 = x, y, z, now
    group.wx, group.wy, group.wz = tx, ty, tz
    group.t1 = now + max(len / group.speed, 0.05) + extra
    if not group._pendMove then
        group._pendMove = true
        pendMove[#pendMove + 1] = group
    end
end

local function NextLeg(group, now, x, y, z)
    PlanLeg(group, now, x, y, z)
    SyncMotion(group)
end

local function HaltGroup(group, now, x, y, z)
    group.hold = true
    group.x, group.y, group.z, group.wx, group.wy, group.wz, group.t0, group.t1 = x, y, z, x, y, z, now, now
    SyncMotion(group)
    if not group._pendMove then
        group._pendMove = true
        pendMove[#pendMove + 1] = group
    end
end

local function PromoteRow(row, x, y, z)
    local group = row.group
    local yaw = math.deg(math.atan2(group.wy - group.y, group.wx - group.x))
    local owner = IsValid(row.owner) and row.owner or nil
    local ent = HZ.SpawnZombie(Vector(x, y, z + 4), yaw,
        { alerted = true, shambler = row.shambler, model = row.model, custom = row.custom, force = true,
            owner = owner })

    if not IsValid(ent) then return nil end

    if row.maxHp then ent:SetMaxHealth(row.maxHp) end
    if row.maxHp or row.hp < 1 then ent:SetHealth(max(1, floor(ent:GetMaxHealth() * row.hp))) end
    if row.shambler then
        ent.hz_shamSpeed = row.speed
    else
        ent.hz_speedMul = row.speed / max(CV.runspeed:GetFloat(), 1)
    end

    ent.hz_omni = row.omni
    if owner and owner.HZ_OnZombieReal then owner:HZ_OnZombieReal(ent, row) end
    ent.hz_wasVirtual = true
    ent.hz_promotedAt = CurTime()
    ent.hz_cover = RowCover(row)
    DropRow(row, false)

    return ent
end

local function Demotable(zombie)
    return IsValid(zombie)
        and (zombie.hz_alerted
        or (zombie.hz_wasVirtual and not zombie.hz_wakeAt
        and (zombie.hz_pose == "wander" or zombie.hz_pose == "stand")))
        and CurTime() - (zombie.hz_promotedAt or 0) > 4
        and not zombie.hz_dead and (not IsValid(zombie.hz_owner) or zombie.hz_owner.HZ_VirtualOK)
        and not zombie.hz_inOnce and not zombie.hz_climbing
        and not zombie.hz_attacking and not zombie.hz_burnDie and not zombie.hz_shove and not zombie:IsOnFire()
        and zombie.loco:IsOnGround()
end

local function DemoteZombie(zombie, pos)
    local navArea = Flow.AreaOf(zombie)
    local id = navArea and navArea:GetID()
    if not id or not Flow.graph or not Flow.graph.area[id] then return false end

    local row = HZ.AddVirtual(pos, { area = id, model = zombie:GetModel(), shambler = zombie.hz_shambler and true
        or false,
        speed = zombie.hz_shambler and zombie.hz_shamSpeed or CV.runspeed:GetFloat() * (zombie.hz_speedMul or 1),
        hp = math.Clamp(zombie:Health() / max(zombie:GetMaxHealth(), 1), 0.05, 1), cover = zombie.hz_cover,
        owner = zombie.hz_owner, horde = zombie.hz_horde, omni = zombie.hz_omni, maxHp = zombie:GetMaxHealth(),
        custom = zombie.hz_custom })

    if not row then return false end

    zombie.hz_virtualized = true
    zombie:Remove()

    return true
end

net.Receive("hz_zoom", function(_, ply)
    local now = CurTime()
    if (ply.hz_zoomNext or 0) > now then return end

    ply.hz_zoomNext = now + 0.1
    local fov = net.ReadUInt(8) / 3
    if fov > 1 and fov < 65 then
        ply.hz_zoomFov = math.Clamp(fov, 2, 65)
        ply.hz_zoomPos = net.ReadVector()
        ply.hz_zoomDir = net.ReadNormal()
        ply.hz_zoomUntil = now + 1
    else
        ply.hz_zoomFov = nil
        ply.hz_zoomUntil = nil
    end
end)

local REF_TAN = math.tan(math.rad(75 / 2))
local viewers, viewerSeen = {}, {}
local zooms, zoomCount = {}, 0

local function ViewerList()
    local now = CurTime()
    local count = 0
    zoomCount = 0
    for _, target in ipairs(HZ.GetTargets()) do
        count = count + 1
        viewers[count] = target.pos
        viewerSeen[target.ent] = true
    end

    for _, ply in ipairs(player.GetAll()) do
        if not viewerSeen[ply] then
            count = count + 1
            viewers[count] = ply:GetPos()
        end

        local viewEnt = ply:GetViewEntity()
        local usingCam = IsValid(viewEnt) and viewEnt ~= ply
        if usingCam then
            count = count + 1
            viewers[count] = viewEnt:GetPos()
        end

        local fov = ply:GetFOV()
        local eye, aim
        if ply.hz_zoomFov and (ply.hz_zoomUntil or 0) > now and (not fov or fov <= 0 or ply.hz_zoomFov < fov) then
            fov = ply.hz_zoomFov
            eye = ply.hz_zoomPos
            aim = ply.hz_zoomDir
        end

        if fov and fov > 0 and fov < 65 then
            local zScale = math.tan(math.rad(math.Clamp(fov, 5, 75) / 2)) / REF_TAN
            local halfCone = math.rad(math.min(fov * 0.75, 45))
            eye = eye or (usingCam and viewEnt:GetPos() or ply:EyePos())
            aim = aim or (usingCam and viewEnt:GetForward() or ply:GetAimVector())
            zoomCount = zoomCount + 1
            local entry = zooms[zoomCount]
            if not entry then
                entry = {}
                zooms[zoomCount] = entry
            end

            entry.ex, entry.ey, entry.ez = eye.x, eye.y, eye.z
            entry.ax, entry.ay, entry.az = aim.x, aim.y, aim.z
            local c = math.cos(halfCone)
            entry.cosSqr = c * c
            entry.tanCone = math.tan(halfCone)
            entry.zoomSqr = zScale * zScale
        end
    end

    for ent in pairs(viewerSeen) do viewerSeen[ent] = nil end
    for i = #viewers, count + 1, -1 do viewers[i] = nil end

    return viewers, count
end

local function ZoomDistSqr(x, y, z, best, pad)
    if zoomCount == 0 then return best end

    for i = 1, zoomCount do
        local zv = zooms[i]
        local dx, dy, dz = x - zv.ex, y - zv.ey, z - zv.ez
        local along = dx * zv.ax + dy * zv.ay + dz * zv.az
        if along > -pad then
            local d2 = dx * dx + dy * dy + dz * dz
            local inCone
            if pad == 0 then
                inCone = along > 0 and along * along >= d2 * zv.cosSqr
            else
                local lim = max(along, 0) * zv.tanCone + pad
                inCone = (d2 - along * along) <= lim * lim
            end

            if inCone then
                local scaled = d2 * zv.zoomSqr
                if scaled < best then best = scaled end
            end
        end
    end

    return best
end

local function NearestViewer2(targets, targetCount, x, y, z)
    local best = huge
    for i = 1, targetCount do
        local viewer = targets[i]
        local dx, dy, dz = viewer.x - x, viewer.y - y, viewer.z - z
        local distSqr = dx * dx + dy * dy + dz * dz
        if distSqr < best then best = distSqr end
    end

    return best
end

local viewerFlat, zoomFlat = {}, {}
local nearPass = 0

local function FlattenViewers(targets, targetCount)
    for i = 1, targetCount do
        local viewer, at = targets[i], i * 3
        viewerFlat[at - 2], viewerFlat[at - 1], viewerFlat[at] = viewer.x, viewer.y, viewer.z
    end

    for i = #viewerFlat, targetCount * 3 + 1, -1 do viewerFlat[i] = nil end

    for i = 1, zoomCount do
        local zv, at = zooms[i], (i - 1) * 9
        zoomFlat[at + 1], zoomFlat[at + 2], zoomFlat[at + 3] = zv.ex, zv.ey, zv.ez
        zoomFlat[at + 4], zoomFlat[at + 5], zoomFlat[at + 6] = zv.ax, zv.ay, zv.az
        zoomFlat[at + 7], zoomFlat[at + 8], zoomFlat[at + 9] = zv.cosSqr, zv.tanCone, zv.zoomSqr
    end

    for i = #zoomFlat, zoomCount * 9 + 1, -1 do zoomFlat[i] = nil end
end

local function NativeNear(now, targets, targetCount, near, consider)
    FlattenViewers(targets, targetCount)
    local groupList, rowList = HZ.NativeLib.CrowdNear(crowd, now, viewerFlat, zoomFlat, near, GROUP_RADIUS)
    nearPass = nearPass + 1
    for i = 1, #groupList, 2 do
        local group = groups[groupList[i]]
        if group then group.nearest, group.cover = groupList[i + 1], 0 end
    end

    for i = 1, #rowList, 2 do
        if i % 128 == 1 and Breathe() then now = CurTime() end

        local row = rows[rowList[i]]
        if row then
            local group = row.group
            if group._nearPass ~= nearPass then
                group._nearPass = nearPass
                group.nearest, group.cover = huge, huge
            end

            local x, y, z = RowPos(row, now)
            consider(row, group, x, y, z, rowList[i + 1])
        end
    end
end

local function NearestTarget2(targets, targetCount, pos)
    local best = huge
    for i = 1, targetCount do
        local distSqr = targets[i]:DistToSqr(pos)
        if distSqr < best then best = distSqr end
    end

    return ZoomDistSqr(pos.x, pos.y, pos.z, best, 0)
end

local COVER_CELLS, COVER_RANGE = 360, 2500
local COVER_RAD = 2 * math.pi / COVER_CELLS
local coverCells = {}
local coverRefs, coverX, coverY, coverZ, coverDist, coverOrder = {}, {}, {}, {}, {}, {}
local coverActive, coverPassId = {}, 0

local COVER_BIN = 16
local COVER_BINS = math.ceil(COVER_RANGE / COVER_BIN)
local coverBin, binFill = {}, {}

local function OrderByDistance(count)
    for bin = 0, COVER_BINS do binFill[bin] = 0 end

    for i = 1, count do
        local bin = floor(coverDist[i] / COVER_BIN)
        coverBin[i] = bin
        binFill[bin] = binFill[bin] + 1
    end

    local at = 1
    for bin = 0, COVER_BINS do
        local size = binFill[bin]
        binFill[bin] = at
        at = at + size
    end

    for i = 1, count do
        local bin = coverBin[i]
        coverOrder[binFill[bin]] = i
        binFill[bin] = binFill[bin] + 1
    end

    for i = #coverOrder, count + 1, -1 do coverOrder[i] = nil end
end

local function CoverFor(eye, now)
    local count = 0
    local ex, ey, ez = eye.x, eye.y, eye.z
    local rangeSqr = COVER_RANGE * COVER_RANGE

    local function Add(ref, x, y, z)
        local dx, dy = x - ex, y - ey
        local distSqr = dx * dx + dy * dy
        if distSqr > rangeSqr then return end

        count = count + 1
        coverRefs[count], coverX[count], coverY[count], coverZ[count] = ref, dx, dy, z + 36 - ez
        coverDist[count] = sqrt(distSqr)
    end

    for zombie in pairs(HZ.Zombies) do
        if IsValid(zombie) and not zombie.hz_dead then
            local pos = zombie:GetPos()
            Add(zombie, pos.x, pos.y, pos.z)
        end
    end

    local groupRangeSqr = (COVER_RANGE + GROUP_RADIUS) * (COVER_RANGE + GROUP_RADIUS)
    for g = 1, #groupArr do
        if g % 32 == 0 and Breathe() then now = CurTime() end

        local group = groupArr[g]
        if not group then break end

        local gx, gy, gz = PosAt(group, now)
        local gdx, gdy = gx - ex, gy - ey
        if gdx * gdx + gdy * gdy <= groupRangeSqr then
            for _, row in pairs(group.rows) do
                Add(row, gx + row.ox, gy + row.oy, gz)
            end
        end
    end

    OrderByDistance(count)
    Breathe()
    for i = 0, COVER_CELLS - 1 do coverCells[i] = 0 end

    for k = 1, count do
        if k % 64 == 0 then Breathe() end

        local i = coverOrder[k]
        local dist = coverDist[i]
        local cover = 0
        if dist > 1 then
            local mid = floor((math.atan2(coverY[i], coverX[i]) + math.pi) / COVER_RAD)
            local half = min(math.ceil(math.atan(14 / dist) / COVER_RAD), 30)
            local steep = coverZ[i] > dist * 0.4 or coverZ[i] < -dist * 0.4
            if not steep then
                local sum = 0
                for cell = mid - half, mid + half do sum = sum + coverCells[cell % COVER_CELLS] end
                cover = sum / (half * 2 + 1)
            end

            for cell = mid - half, mid + half do
                local index = cell % COVER_CELLS
                coverCells[index] = coverCells[index] + 1
            end
        end

        local ref = coverRefs[i]
        if ref.hz_cp ~= coverPassId then
            ref.hz_cp = coverPassId
            ref.hz_coverNow = cover
            if not ref.hz_inCover then
                ref.hz_inCover = true
                coverActive[#coverActive + 1] = ref
            end
        elseif cover < ref.hz_coverNow then
            ref.hz_coverNow = cover
        end
        coverRefs[i] = nil
    end
end

local function CoverPass()
    local now = CurTime()
    coverPassId = coverPassId + 1
    local plys = player.GetAll()
    for i = 1, #plys do
        if IsValid(plys[i]) then CoverFor(plys[i]:EyePos(), CurTime()) end
    end

    local n = #coverActive
    for i = n, 1, -1 do
        local ref = coverActive[i]
        local cur = ref.hz_cp == coverPassId and ref.hz_coverNow or 0
        local val = ((ref.hz_cover or 0) + cur) * 0.5
        if cur == 0 and val < 0.01 then
            ref.hz_cover, ref.hz_inCover = 0, nil
            coverActive[i] = coverActive[n]
            coverActive[n] = nil
            n = n - 1
        else
            ref.hz_cover = val
        end
    end
end

local function CoverScale(cover)
    local factor = 1 + 0.75 * min(cover or 0, 8)

    return factor * factor
end

function SyncCrowd()
    local lib = HZ.NativeLib
    if HZ.NativeOn() then
        if crowd then return crowd end

        crowd = lib.Crowd(ID_MAX, ID_MAX)
        local now = CurTime()
        for _, group in pairs(groups) do AddCrowdGroup(group, now) end
        for id, row in pairs(rows) do lib.CrowdSetRow(crowd, id, row.group.id, row.ox, row.oy, row.hz_cover or 0) end

        return crowd
    end

    if crowd then
        for id, row in pairs(rows) do row.hz_cover = lib.CrowdRowCover(crowd, id) end
        lib.CrowdFree(crowd)
        crowd = nil
    end

    return nil
end

local eyes, extras, extraRefs = {}, {}, {}

local function NativeCoverPass()
    local lib = HZ.NativeLib
    local eyeCount = 0
    for _, ply in ipairs(player.GetAll()) do
        local eye = ply:EyePos()
        eyes[eyeCount + 1], eyes[eyeCount + 2], eyes[eyeCount + 3] = eye.x, eye.y, eye.z
        eyeCount = eyeCount + 3
    end

    for i = #eyes, eyeCount + 1, -1 do eyes[i] = nil end

    local extraCount = 0
    for zombie in pairs(HZ.Zombies) do
        if IsValid(zombie) and not zombie.hz_dead then
            local pos = zombie:GetPos()
            extraCount = extraCount + 1
            extraRefs[extraCount] = zombie
            local at = extraCount * 3
            extras[at - 2], extras[at - 1], extras[at] = pos.x, pos.y, pos.z
        end
    end

    for i = #extras, extraCount * 3 + 1, -1 do extras[i] = nil end
    for i = #extraRefs, extraCount + 1, -1 do extraRefs[i] = nil end

    lib.CrowdSetViewers(crowd, eyes)
    lib.CrowdSetExtras(crowd, extras)
    if not lib.CrowdCoverStart(crowd, COVER_RANGE, CurTime()) then return end

    while not lib.CrowdCoverPoll(crowd) do yield() end

    for i = 1, extraCount do
        local zombie = extraRefs[i]
        if IsValid(zombie) then
            local cur = lib.CrowdExtraCover(crowd, i)
            local val = ((zombie.hz_cover or 0) + cur) * 0.5
            zombie.hz_cover = (cur == 0 and val < 0.01) and 0 or val
        end

        extraRefs[i] = nil
    end
end

SlicedPass("cover", 1, "sv_vcover", function()
    if not HZ.VirtualOn() or HZ.AIDisabled() then return end
    if HZ.VCount == 0 and HZ.Count <= CV.real_max:GetInt() then return end

    if SyncCrowd() then
        NativeCoverPass()
    else
        CoverPass()
    end
end)

local PROMOTE_PER_PASS = 2
local SWAP_PER_PASS = 2
local waiting = {}

local function ByDistDesc(a, b)
    return a.d2 > b.d2
end

local function NearestFirst(list, count, keep)
    for i = 1, min(keep, count) do
        local best = i
        for j = i + 1, count do
            if list[j].d2 < list[best].d2 then best = j end
        end

        list[i], list[best] = list[best], list[i]
    end
end

local function TradePlaces(count, targets, targetCount, cap)
    NearestFirst(waiting, count, SWAP_PER_PASS)
    local reals
    for i = 1, min(count, SWAP_PER_PASS) do
        local wait = waiting[i]
        local row = wait.r
        if rows[row.id] ~= row then break end

        local done = false
        if wait.d2 < 1500 * 1500 and CurTime() - row.born > 3 then
            if not reals then
                reals = {}
                for zombie in pairs(HZ.Zombies) do
                    if Demotable(zombie) then
                        local pos = zombie:GetPos()
                        reals[#reals + 1] = { z = zombie, pos = pos,
                            d2 = NearestTarget2(targets, targetCount, pos) * CoverScale(zombie.hz_cover) }
                    end
                end

                table.sort(reals, ByDistDesc)
            end

            local far = reals[1]
            if far and far.d2 > wait.d2 * 1.7 and far.d2 > 1100 * 1100 and PromoteRow(row, wait.x, wait.y, wait.z) then
                table.remove(reals, 1)
                DemoteZombie(far.z, far.pos)
                done = true
            end
        end

        if not done and wait.d2 < 650 * 650 and HZ.Count < cap * 2 then PromoteRow(row, wait.x, wait.y, wait.z) end
    end
end

local targetPosFlat = {}

local function FlattenFlowTargets()
    local ents = Flow.nativeTargets
    local n = ents and #ents or 0
    for i = 1, n do
        local ent = ents[i]
        local at = i * 3
        if IsValid(ent) then
            local pos = ent:GetPos()
            targetPosFlat[at - 2], targetPosFlat[at - 1], targetPosFlat[at] = pos.x, pos.y, pos.z
        else
            targetPosFlat[at - 2], targetPosFlat[at - 1], targetPosFlat[at] = 0, 0, 0
        end
    end

    for i = #targetPosFlat, n * 3 + 1, -1 do targetPosFlat[i] = nil end
end

SlicedPass("walk", 0.25, "sv_virtual", function()
    if HZ.VCount == 0 then
        if #pendDel > 0 or #pendGroupDel > 0 then FlushNet() end
        return
    end

    if HZ.AIDisabled() then return end

    local now = CurTime()
    local targets, targetCount = ViewerList()
    local near = CV.virt_near:GetFloat()
    local nearSqr = near * near
    local groupNearSqr = (near + GROUP_RADIUS) * (near + GROUP_RADIUS)
    local cap = CV.real_max:GetInt()
    local real, promoted = HZ.Count, 0
    local waitCount = 0

    if SyncCrowd() and HZ.NativeLib.CrowdStep and Flow.native and Flow.ready then
        FlattenViewers(targets, targetCount)
        FlattenFlowTargets()
        local promotes, waits, moves = HZ.NativeLib.CrowdStep(
            crowd, Flow.native, now, viewerFlat, zoomFlat, targetPosFlat,
            near, GROUP_RADIUS, real, cap, PROMOTE_PER_PASS, SWAP_PER_PASS * 4
        )

        for i = 1, #promotes, 5 do
            local row = rows[promotes[i]]
            if row then PromoteRow(row, promotes[i + 1], promotes[i + 2], promotes[i + 3]) end
        end

        for i = 1, #waits, 5 do
            local row = rows[waits[i]]
            if row then
                waitCount = waitCount + 1
                local wait = waiting[waitCount]
                if not wait then
                    wait = {}
                    waiting[waitCount] = wait
                end

                wait.r = row
                wait.d2 = waits[i + 1]
                wait.x = waits[i + 2]
                wait.y = waits[i + 3]
                wait.z = waits[i + 4]
            end
        end

        for i = #waiting, waitCount + 1, -1 do waiting[i] = nil end
        if waitCount > 0 and targetCount > 0 then TradePlaces(waitCount, targets, targetCount, cap) end

        for i = 1, #moves, 9 do
            local group = groups[moves[i]]
            if group then
                group.x, group.y, group.z = moves[i + 1], moves[i + 2], moves[i + 3]
                group.wx, group.wy, group.wz = moves[i + 4], moves[i + 5], moves[i + 6]
                group.t0, group.t1 = moves[i + 7], moves[i + 8]
                if not group._pendMove then
                    group._pendMove = true
                    pendMove[#pendMove + 1] = group
                end
            end
        end

        FlushNet()
        return
    end

    local function Consider(row, group, x, y, z, best)
        if best < nearSqr and real < cap and promoted < PROMOTE_PER_PASS and PromoteRow(row, x, y, z) then
            real, promoted = real + 1, promoted + 1
            return
        end

        if best < group.nearest then group.nearest = best end
        local cover = RowCover(row)
        if cover < group.cover then group.cover = cover end
        if best >= nearSqr then return end

        waitCount = waitCount + 1
        local wait = waiting[waitCount]
        if not wait then
            wait = {}
            waiting[waitCount] = wait
        end

        wait.r, wait.d2, wait.x, wait.y, wait.z = row, best * CoverScale(cover), x, y, z
    end

    if crowd then
        NativeNear(now, targets, targetCount, near, Consider)
    else
        for g = #groupArr, 1, -1 do
            if g % 32 == 0 and Breathe() then now, real = CurTime(), HZ.Count end

            local group = groupArr[g]
            if group and group.count > 0 then
                local gx, gy, gz = PosAt(group, now)
                group._x, group._y, group._z, group._at = gx, gy, gz, now
                local groupBest = ZoomDistSqr(gx, gy, gz, NearestViewer2(targets, targetCount, gx, gy, gz),
                    GROUP_RADIUS)

                if groupBest <= groupNearSqr then
                    group.nearest, group.cover = huge, huge
                    for _, row in pairs(group.rows) do
                        local x, y, z = gx + row.ox, gy + row.oy, gz
                        Consider(row, group, x, y, z,
                            ZoomDistSqr(x, y, z, NearestViewer2(targets, targetCount, x, y, z), 0))
                    end
                else
                    group.nearest, group.cover = groupBest, 0
                end
            end
        end
    end

    for i = #waiting, waitCount + 1, -1 do waiting[i] = nil end
    if waitCount > 0 and targetCount > 0 then TradePlaces(waitCount, targets, targetCount, cap) end

    for g = #groupArr, 1, -1 do
        if g % 32 == 0 and Breathe() then
            now = CurTime()
            FlushNet()
        end

        local group = groupArr[g]
        if group and group.count > 0 then
            local x, y, z
            if group._x and group._at == now then
                x, y, z = group._x, group._y, group._z
            else
                x, y, z = PosAt(group, now)
            end

            group._x = nil
            local cover, nearest = group.cover, group.nearest or huge
            if not cover or cover == huge then cover = 0 end
            local stop = max((300 + (group.id % 16) * 25) / (1 + cover), 90)
            if nearest < nearSqr and nearest < stop * stop then
                if not group.hold then HaltGroup(group, now, x, y, z) end
            elseif now >= group.t1 then
                group.hold = nil
                NextLeg(group, now, x, y, z)
            elseif group.gx and group.garea and group.fv ~= Flow.version then
                if Flow.nxt[group.area] ~= group.garea then
                    group.gx = nil
                    NextLeg(group, now, x, y, z)
                else
                    group.fv = Flow.version
                end
            end
        end
    end

    FlushNet()
end)

local DEMOTE_PER_PASS = 30
timer.Create("hordez_virtual_demote", 1, 0, function()
    if not HZ.VirtualOn() or HZ.Count == 0 or HZ.AIDisabled() or not Flow.graph then return end

    local cap = CV.real_max:GetInt()
    local real = HZ.Count
    local far = max(CV.virt_far:GetFloat(), CV.virt_near:GetFloat() + 200)
    local farSqr, always2 = far * far, far * far * 2.56
    local targets, targetCount = ViewerList()
    if targetCount == 0 then return end

    local done = 0
    for zombie in pairs(HZ.Zombies) do
        if done >= DEMOTE_PER_PASS then break end

        if Demotable(zombie) then
            local pos = zombie:GetPos()
            local raw = NearestTarget2(targets, targetCount, pos)
            local best = raw * CoverScale(zombie.hz_cover)
            if (raw > always2 or (best > farSqr and real > cap)) and DemoteZombie(zombie, pos) then
                real, done = real - 1, done + 1
            end
        end
    end

    if done > 0 then FlushNet() end
end)

local shotTr = {}
local shotIn = { mask = MASK_SHOT, output = shotTr }

function HZ.SpawnChaser(pos, opts)
    opts = opts or {}
    local shambler = opts.shambler
    if shambler == nil then shambler = random() < CV.sh_chance:GetFloat() end
    local speedScale, healthScale = opts.speedScale or 1, opts.healthScale or 1
    if not HZ.VirtualOn() or HZ.Count < CV.real_max:GetInt() then
        local zombie = HZ.SpawnZombie(pos, nil, { alerted = true, owner = opts.owner, shambler = shambler })
        if not IsValid(zombie) then return nil end

        zombie.hz_omni = opts.omni
        zombie.hz_speedMul = (zombie.hz_speedMul or 1) * speedScale
        if zombie.hz_shamSpeed then zombie.hz_shamSpeed = zombie.hz_shamSpeed * speedScale end
        if healthScale > 1 then
            local health = math.Round(zombie:GetMaxHealth() * healthScale)
            zombie:SetMaxHealth(health)
            zombie:SetHealth(health)
        end

        return zombie
    end

    if not HZ.CanSpawn() then return nil end

    local speed
    if shambler then
        speed = math.Rand(CV.sh_speed_lo:GetFloat(), max(CV.sh_speed_lo:GetFloat(), CV.sh_speed_hi:GetFloat()))
    else
        local variance = math.Clamp(CV.speed_var:GetFloat(), 0, 0.9)
        speed = CV.runspeed:GetFloat() * math.Rand(1 - variance, 1 + variance)
    end

    local baseHealth = shambler and CV.sh_health:GetInt() or CV.health:GetInt()
    local row = HZ.AddVirtual(pos, { shambler = shambler, speed = speed * speedScale, owner = opts.owner,
        horde = opts.horde, omni = opts.omni,
        maxHp = healthScale > 1 and math.Round(baseHealth * healthScale) or nil })

    return nil, row
end

local killingAsReal = false

local function DeathNotice(attacker, inflictor)
    local gamemode = gmod.GetGamemode()
    if not gamemode or not gamemode.SendDeathNotice or not IsValid(attacker) then return end

    local source = IsValid(inflictor) and inflictor or attacker
    if source == attacker and attacker:IsPlayer() and IsValid(attacker:GetActiveWeapon()) then
        source = attacker:GetActiveWeapon()
    end

    gamemode:SendDeathNotice(attacker, source:GetClass(), "#hz_zombie", 0)
end

local function HitAsReal(row, x, y, z, attacker, inflictor, dmg, dmgType, force, lethal)
    local ent = PromoteRow(row, x, y, z)
    if not ent then
        if lethal then
            DropRow(row, true)
            DeathNotice(attacker, inflictor)
        end

        return
    end

    timer.Simple(0.15, function()
        if not IsValid(ent) or ent.hz_dead then return end

        local dmgInfo = DamageInfo()
        dmgInfo:SetDamage(lethal and max(dmg, ent:Health() + 10) or dmg)
        dmgInfo:SetDamageType(dmgType)
        dmgInfo:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
        dmgInfo:SetInflictor(IsValid(inflictor) and inflictor or (IsValid(attacker) and attacker or game.GetWorld()))
        dmgInfo:SetDamagePosition(ent:WorldSpaceCenter())
        dmgInfo:SetDamageForce(force)
        killingAsReal = true
        ent:TakeDamageInfo(dmgInfo)
        killingAsReal = false
    end)
end

local shotEnd = Vector()

local function RayHit(now, sx, sy, sz, dx, dy, dz, len, spread)
    if crowd then
        local id, _, x, y, z = HZ.NativeLib.CrowdRay(crowd, now, sx, sy, sz, dx, dy, dz, len, spread, GROUP_RADIUS)

        return id and rows[id], x, y, z
    end

    local hit, hitT, hitX, hitY, hitZ
    for g = 1, #groupArr do
        local group = groupArr[g]
        local gx, gy, gz = PosAt(group, now)
        local gcx, gcy, gcz = gx - sx, gy - sy, gz + 40 - sz
        local gAlong = gcx * dx + gcy * dy + gcz * dz
        if gAlong > -GROUP_RADIUS and gAlong < len + GROUP_RADIUS then
            local gRad = GROUP_RADIUS + 22 + min(spread * max(gAlong, 0), 60)
            if gcx * gcx + gcy * gcy + gcz * gcz - gAlong * gAlong < gRad * gRad then
                for _, row in pairs(group.rows) do
                    local x, y, z = gx + row.ox, gy + row.oy, gz
                    local cx, cy, cz = x - sx, y - sy, z + 40 - sz
                    local along = cx * dx + cy * dy + cz * dz
                    if along > 0 and along < len and (not hitT or along < hitT) then
                        local rad = 22 + min(spread * along, 60)
                        if cx * cx + cy * cy + cz * cz - along * along < rad * rad then
                            hit, hitT, hitX, hitY, hitZ = row, along, x, y, z
                        end
                    end
                end
            end
        end
    end

    return hit, hitX, hitY, hitZ
end

hook.Add("EntityFireBullets", "hordez_virtual", function(ent, data)
    if HZ.VCount == 0 or not IsValid(ent) or ent:GetClass() == "hz_zombie" then return end

    local src, dir = data.Src, data.Dir
    if not isvector(src) or not isvector(dir) then return end

    dir = dir:GetNormalized()
    local dist = data.Distance and data.Distance > 0 and data.Distance or 56756
    local sx, sy, sz, dx, dy, dz = src.x, src.y, src.z, dir.x, dir.y, dir.z
    shotEnd:SetUnpacked(sx + dx * dist, sy + dy * dist, sz + dz * dist)
    shotIn.start, shotIn.endpos, shotIn.filter = src, shotEnd, ent
    util.TraceLine(shotIn)
    local len = shotTr.HitPos:Distance(src)
    local spread = HZ.BulletSpread(data.Spread)
    local count = max(data.Num or 1, 1)
    local dmg = (data.Damage and data.Damage > 0 and data.Damage or 30) * (count > 1 and count * 0.5 or 1)
    local hit, hitX, hitY, hitZ = RayHit(CurTime(), sx, sy, sz, dx, dy, dz, len, spread)
    if not hit then return end

    local attacker = IsValid(data.Attacker) and data.Attacker or ent
    local weapon = attacker.GetActiveWeapon and attacker:GetActiveWeapon() or nil
    HitAsReal(hit, hitX, hitY, hitZ, attacker, weapon, dmg, DMG_BULLET, dir * 3000, false)
    FlushNet()
end)

local BLAST_REAL_MAX = 12
local BLAST_NOTICE_MAX = 12
local BLAST_MERGE_TIME, BLAST_MERGE_DIST = 0.3, 150
local BLAST_ON_REMOVE = { grenade_ar2 = 100, rpg_missile = 100, npc_grenade_frag = 125, grenade_helicopter = 100,
    npc_satchel = 150, npc_tripmine = 150 }

local recentBlasts = {}

local function AlreadyBlasted(center, now)
    for i = #recentBlasts, 1, -1 do
        local blast = recentBlasts[i]
        if now - blast.at > BLAST_MERGE_TIME then
            table.remove(recentBlasts, i)
        elseif blast.pos:DistToSqr(center) < BLAST_MERGE_DIST * BLAST_MERGE_DIST then
            return true
        end
    end

    recentBlasts[#recentBlasts + 1] = { pos = Vector(center.x, center.y, center.z), at = now }

    return false
end

local function Blast(center, amount, attacker, inflictor)
    if killingAsReal or HZ.VCount == 0 or not isvector(center) then return end

    local now = CurTime()
    if AlreadyBlasted(center, now) then return end

    amount = tonumber(amount) or 100
    local rad = math.Clamp(amount * 2.5, 150, 450)
    local radiusSqr = rad * rad
    local groupRadSqr = (rad + GROUP_RADIUS) * (rad + GROUP_RADIUS)
    local shown, noted = 0, 0
    local function Catch(row, x, y, z)
        local dx, dy = x - center.x, y - center.y
        if shown < BLAST_REAL_MAX then
            shown = shown + 1
            HitAsReal(row, x, y, z, attacker, inflictor, amount, DMG_BLAST, Vector(dx, dy, 60) * 400, true)
            return
        end

        DropRow(row, true)
        if noted < BLAST_NOTICE_MAX then
            noted = noted + 1
            DeathNotice(attacker, inflictor)
        end
    end

    if crowd then
        local caught = HZ.NativeLib.CrowdSphere(crowd, now, center.x, center.y, center.z, rad, GROUP_RADIUS)
        for i = 1, #caught do
            local row = rows[caught[i]]
            if row then Catch(row, RowPos(row, now)) end
        end
    else
        for _, group in pairs(groups) do
            local gx, gy, gz = PosAt(group, now)
            local gdx, gdy, gdz = gx - center.x, gy - center.y, gz - center.z
            if gdx * gdx + gdy * gdy + gdz * gdz < groupRadSqr then
                for _, row in pairs(group.rows) do
                    local x, y, z = gx + row.ox, gy + row.oy, gz
                    local dx, dy, dz = x - center.x, y - center.y, z - center.z
                    if dx * dx + dy * dy + dz * dz < radiusSqr then Catch(row, x, y, z) end
                end
            end
        end
    end

    FlushNet()
end

hook.Add("EntityTakeDamage", "hordez_virtual", function(_, dmg)
    if not dmg:IsExplosionDamage() then return end

    local inflictor = dmg:GetInflictor()
    Blast(IsValid(inflictor) and inflictor:GetPos() or dmg:GetDamagePosition(), dmg:GetDamage(), dmg:GetAttacker(),
        inflictor)
end)

hook.Add("EntityRemoved", "hordez_virtual_blast", function(ent)
    local amount = BLAST_ON_REMOVE[ent:GetClass()]
    if not amount then return end

    local owner = ent:GetOwner()
    Blast(ent:GetPos(), amount, IsValid(owner) and owner or ent:GetInternalVariable("m_hThrower"), ent)
end)

HZ.EngineBlastDamage = HZ.EngineBlastDamage or util.BlastDamage
HZ.EngineBlastDamageInfo = HZ.EngineBlastDamageInfo or util.BlastDamageInfo

function util.BlastDamage(inflictor, attacker, pos, radius, damage, ...)
    pcall(Blast, pos, damage, attacker, inflictor)

    return HZ.EngineBlastDamage(inflictor, attacker, pos, radius, damage, ...)
end

function util.BlastDamageInfo(dmg, pos, radius, ...)
    pcall(Blast, pos, dmg:GetDamage(), dmg:GetAttacker(), dmg:GetInflictor())

    return HZ.EngineBlastDamageInfo(dmg, pos, radius, ...)
end

net.Receive("hz_virt_sync", function(_, ply)
    local now = CurTime()
    if (ply.hz_virtSync or 0) > now then return end

    ply.hz_virtSync = now + 5
    local groupList, rowList = {}, {}
    for _, group in pairs(groups) do
        if not group._pendAdd then groupList[#groupList + 1] = group end
    end

    for _, row in pairs(rows) do
        if not row._pendAdd and not row.group._pendAdd then
            rowList[#rowList + 1] = row
        end
    end

    local rowAt, sent = 1, false
    while not sent or rowAt <= #rowList do
        sent = true
        net.Start("hz_virt")
        net.WriteUInt(0, 16)
        net.WriteUInt(0, 16)
        local first = rowAt == 1
        net.WriteUInt(first and #groupList or 0, 16)
        if first then
            for _, group in ipairs(groupList) do
                local x, y, z = PosAt(group, now)
                net.WriteUInt(group.id, 16)
                WritePos(x, y, z)
                net.WriteUInt(min(floor(group.speed), 1023), 10)
            end
        end

        local count = min(CHUNK, #rowList - rowAt + 1)
        net.WriteUInt(count, 16)
        for i = rowAt, rowAt + count - 1 do WriteRowAdd(rowList[i]) end
        rowAt = rowAt + count
        local last = rowAt > #rowList
        net.WriteUInt(last and #groupList or 0, 16)
        if last then
            for _, group in ipairs(groupList) do WriteGroupMove(group) end
        end

        net.Send(ply)
    end
end)

HZ.SwarmCount = HZ.SwarmCount or 0

local function SendClusters(clusters)
    local count = clusters and math.floor(#clusters / 6) or 0
    net.Start("hz_clusters", true)
    net.WriteUInt(count, 10)
    for i = 1, count * 6, 6 do
        local pop = clusters[i + 1]
        local density = math.Clamp(math.floor(math.log(pop + 1) / math.log(2)), 1, 15)
        WritePos(clusters[i + 2], clusters[i + 3], clusters[i + 4])
        net.WriteUInt(math.Clamp(math.floor(clusters[i + 5]), 16, 511), 9)
        net.WriteUInt(density, 4)
    end

    net.Broadcast()
end

function HZ.AddSwarm(total, avoidPos, minDist)
    if not (HZ.NativeOn() and HZ.NativeLib.FlowAddPopAll and Flow.native) then return 0 end

    local areas = HZ.NativeLib.FlowAddPopAll(Flow.native, total, avoidPos.x, avoidPos.y, avoidPos.z, minDist or 1200)
    HZ.SwarmCount = math.floor(HZ.NativeLib.FlowTotalPop(Flow.native) + 0.5)
    HZ.FlowWantedUntil = CurTime() + 60

    return areas
end

function HZ.ClearSwarm()
    if Flow.native and HZ.NativeLib and HZ.NativeLib.FlowClearPop then
        HZ.NativeLib.FlowClearPop(Flow.native)
    end

    HZ.SwarmCount = 0
    SendClusters(nil)
end

local SWARM_STEP = 0.5
local SWARM_SPAWN_BUDGET = 250
local SWARM_V_SOFT_CAP = 55000

timer.Create("hordez_swarm_step", SWARM_STEP, 0, function()
    if HZ.SwarmCount <= 0 or HZ.AIDisabled() or not HZ.VirtualOn() then return end
    if not (HZ.NativeOn() and HZ.NativeLib.FlowStepPop and Flow.native and Flow.ready) then return end

    local targets, targetCount = ViewerList()
    if targetCount == 0 then return end

    FlattenViewers(targets, targetCount)
    local room = max(0, min(SWARM_SPAWN_BUDGET, SWARM_V_SOFT_CAP - HZ.VCount))
    local spawnDist = max(CV.virt_far:GetFloat(), 3200)
    local spawns, clusters = HZ.NativeLib.FlowStepPop(
        Flow.native, SWARM_STEP, CV.runspeed:GetFloat(), viewerFlat, spawnDist, room, 128
    )

    local added = 0
    local omni = HZ.GlobalAggro ~= nil
    for i = 1, #spawns, 5 do
        local areaId = spawns[i]
        local count = spawns[i + 1]
        local cx, cy, cz = spawns[i + 2], spawns[i + 3], spawns[i + 4]
        local navArea = Flow.Area(areaId)
        for _ = 1, count do
            local pos = IsValid(navArea) and navArea:GetRandomPoint() or Vector(cx + math.Rand(-40, 40), cy + math.Rand(-40, 40), cz)
            if HZ.AddVirtual(pos + Vector(0, 0, 4), { area = areaId, omni = omni }) then
                added = added + 1
            end
        end
    end

    if added > 0 then FlushNet() end
    SendClusters(clusters)
    HZ.SwarmCount = math.floor(HZ.NativeLib.FlowTotalPop(Flow.native) + 0.5)
end)

local VEH_MIN_SPEED_SQR = 200 * 200
local VEH_HIT_RAD = 110
local VEH_REAL_MAX = 4
local drivers, driverCount = {}, 0

local function SweepVehicle(ply, veh, now)
    local mover = veh
    local parent = veh:GetParent()
    if IsValid(parent) then mover = parent end

    local vel = mover:GetVelocity()
    local speedSqr = vel:LengthSqr()
    if speedSqr < 1 then
        local phys = mover:GetPhysicsObject()
        if IsValid(phys) then
            vel = phys:GetVelocity()
            speedSqr = vel:LengthSqr()
        end
    end

    if speedSqr < VEH_MIN_SPEED_SQR then return false end

    local center = mover:GetPos()
    local rad = max(VEH_HIT_RAD, mover:BoundingRadius() * 0.55)
    local radSqr = rad * rad
    local groupRadSqr = (rad + GROUP_RADIUS) * (rad + GROUP_RADIUS)
    local speed = sqrt(speedSqr)
    local force = Vector(vel.x * 120, vel.y * 120, vel.z * 120 + speed * 30)
    local shown, hitAny = 0, false

    local function Catch(row, x, y, z)
        hitAny = true
        if shown < VEH_REAL_MAX then
            shown = shown + 1
            HitAsReal(row, x, y, z, ply, mover, 500, DMG_VEHICLE, force, true)
        else
            DropRow(row, true)
            DeathNotice(ply, mover)
        end
    end

    if crowd then
        local caught = HZ.NativeLib.CrowdSphere(crowd, now, center.x, center.y, center.z, rad, GROUP_RADIUS)
        for i = 1, #caught do
            local row = rows[caught[i]]
            if row then Catch(row, RowPos(row, now)) end
        end
    else
        for g = #groupArr, 1, -1 do
            local group = groupArr[g]
            if group and group.count > 0 then
                local gx, gy, gz = PosAt(group, now)
                local gdx, gdy, gdz = gx - center.x, gy - center.y, gz - center.z
                if gdx * gdx + gdy * gdy + gdz * gdz < groupRadSqr then
                    for _, row in pairs(group.rows) do
                        local x, y, z = gx + row.ox, gy + row.oy, gz
                        local dx, dy, dz = x - center.x, y - center.y, z - center.z
                        if dx * dx + dy * dy + dz * dz < radSqr then Catch(row, x, y, z) end
                    end
                end
            end
        end
    end

    return hitAny
end

local function StepVehicleSweep()
    if driverCount == 0 or HZ.VCount == 0 then return end

    local now = CurTime()
    local dirty = false
    for ply, veh in pairs(drivers) do
        if not IsValid(ply) or not ply:InVehicle() or not IsValid(veh) then
            drivers[ply] = nil
            driverCount = driverCount - 1
        elseif SweepVehicle(ply, veh, now) then
            dirty = true
        end
    end

    if dirty then FlushNet() end
    if driverCount <= 0 then
        driverCount = 0
        timer.Remove("hordez_virtual_veh")
    end
end

hook.Add("PlayerEnteredVehicle", "hordez_virtual_veh", function(ply, veh)
    if not IsValid(ply) or not IsValid(veh) then return end

    if not drivers[ply] then driverCount = driverCount + 1 end
    drivers[ply] = veh
    if driverCount == 1 then timer.Create("hordez_virtual_veh", 0.1, 0, StepVehicleSweep) end
end)

local function DropDriver(ply)
    if not drivers[ply] then return end

    drivers[ply] = nil
    driverCount = max(driverCount - 1, 0)
    if driverCount == 0 then timer.Remove("hordez_virtual_veh") end
end

hook.Add("PlayerLeaveVehicle", "hordez_virtual_veh", DropDriver)
hook.Add("PlayerDisconnected", "hordez_virtual_veh", DropDriver)

hook.Add("PostCleanupMap", "hordez_virtual", function()
    HZ.ClearVirtual()
    HZ.ClearSwarm()
end)
cvars.AddChangeCallback("hz_virtual", function(_, _, new)
    if not tobool(new) then HZ.ClearVirtual() end
end, "hordez_virtual")
