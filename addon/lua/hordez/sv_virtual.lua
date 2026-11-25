util.AddNetworkString("hz_virt")
util.AddNetworkString("hz_virt_sync")

local CV = HZ.CV
local Flow = HZ.Flow
HZ.Virtual = HZ.Virtual or {}
HZ.VCount = HZ.VCount or 0
local rows = HZ.Virtual

local sqrt, huge, random, floor, min, max = math.sqrt, math.huge, math.random, math.floor, math.min, math.max

function HZ.VirtualOn()
    return CV.virt:GetBool()
end

local GROUP_MAX, GROUP_RADIUS = 24, 90
local groups, openGroups = {}, {}
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

        if self.nextId > 65000 then return nil end

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
    net.WriteUInt(entry[1], 16)
    net.WriteBool(entry[2])
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
    openGroups[id] = group
    pendGroupAdd[#pendGroupAdd + 1] = group

    return group
end

local function JoinGroup(row, pos, speed, area)
    local now = CurTime()
    local best, bestDist
    for _, group in pairs(openGroups) do
        if group.shambler == row.shambler and group.count < GROUP_MAX then
            local x, y, z = PosAt(group, now)
            local dx, dy = pos.x - x, pos.y - y
            local distSqr = dx * dx + dy * dy
            if distSqr < GROUP_RADIUS * GROUP_RADIUS and math.abs(pos.z - z) < 60
                and (not bestDist or distSqr < bestDist) then
                best, bestDist = group, distSqr
            end
        end
    end

    best = best or NewGroup(pos, speed, row.shambler, area)
    if not best then return false end

    local x, y = PosAt(best, now)
    row.group, row.ox, row.oy = best, pos.x - x, pos.y - y
    best.rows[row.id] = row
    best.count = best.count + 1
    if best.count >= GROUP_MAX then openGroups[best.id] = nil end

    return true
end

function HZ.AddVirtual(pos, opts)
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
        owner = IsValid(opts.owner) and opts.owner or nil, horde = opts.horde and true or nil, omni = opts.omni,
        maxHp = opts.maxHp }

    if not JoinGroup(row, pos, speed, opts.area) then
        rowIds:Release(id)
        return nil
    end

    rows[id] = row
    HZ.VCount = HZ.VCount + 1
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

    rows[row.id] = nil
    HZ.VCount = HZ.VCount - 1
    CountOwned(row, -1)
    rowIds:Release(row.id)
    if row._pendAdd then
        row._pendAdd = nil
        Forget(pendAdd, row)
    else
        pendDel[#pendDel + 1] = { row.id, killed and true or false }
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
local probe = Vector()

local function NextLeg(group, now, x, y, z)
    local graph = Flow.graph
    if not graph or not Flow.ready then
        group.t1 = now + 1
        return
    end

    local area = group.area
    if not area or not graph.area[area] then
        local navArea = navmesh.GetNearestNavArea(Vector(x, y, z), false, 400, false, true)
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

            local pos = nextArea:GetClosestPointOnArea(Vector(x, y, z))
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
    local STEP = max(40, min(STEP, group.speed * LEG_TIME))
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

local function HaltGroup(group, now, x, y, z)
    group.hold = true
    group.x, group.y, group.z, group.wx, group.wy, group.wz, group.t0, group.t1 = x, y, z, x, y, z, now, now
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
        { alerted = true, shambler = row.shambler, model = row.model, force = true, owner = owner })

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
    ent.hz_cover = row.hz_cover
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
        owner = zombie.hz_owner, horde = zombie.hz_horde, omni = zombie.hz_omni, maxHp = zombie:GetMaxHealth() })

    if not row then return false end

    zombie.hz_virtualized = true
    zombie:Remove()

    return true
end

local viewers, viewerSeen = {}, {}

local function ViewerList()
    local count = 0
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
    end

    for ent in pairs(viewerSeen) do viewerSeen[ent] = nil end
    for i = #viewers, count + 1, -1 do viewers[i] = nil end

    return viewers, count
end

local function NearestTarget2(targets, targetCount, pos)
    local best = huge
    for i = 1, targetCount do
        local distSqr = targets[i]:DistToSqr(pos)
        if distSqr < best then best = distSqr end
    end

    return best
end

local COVER_CELLS, COVER_RANGE = 360, 2500
local COVER_RAD = 2 * math.pi / COVER_CELLS
local coverCells = {}
local coverRefs, coverX, coverY, coverZ, coverDist, coverOrder = {}, {}, {}, {}, {}, {}

local function CoverNearer(a, b)
    return coverDist[a] < coverDist[b]
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
        coverDist[count], coverOrder[count] = sqrt(distSqr), count
    end

    for zombie in pairs(HZ.Zombies) do
        if IsValid(zombie) and not zombie.hz_dead then
            local pos = zombie:GetPos()
            Add(zombie, pos.x, pos.y, pos.z)
        end
    end

    local groupRangeSqr = (COVER_RANGE + GROUP_RADIUS) * (COVER_RANGE + GROUP_RADIUS)
    for _, group in pairs(groups) do
        local gx, gy, gz = PosAt(group, now)
        local gdx, gdy = gx - ex, gy - ey
        if gdx * gdx + gdy * gdy <= groupRangeSqr then
            for _, row in pairs(group.rows) do
                Add(row, gx + row.ox, gy + row.oy, gz)
            end
        end
    end

    for i = #coverOrder, count + 1, -1 do coverOrder[i] = nil end
    table.sort(coverOrder, CoverNearer)
    for i = 0, COVER_CELLS - 1 do coverCells[i] = 0 end

    for k = 1, count do
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
        if not ref.hz_coverNow or cover < ref.hz_coverNow then ref.hz_coverNow = cover end
        coverRefs[i] = nil
    end
end

local function CoverPass()
    local now = CurTime()
    for zombie in pairs(HZ.Zombies) do zombie.hz_coverNow = nil end
    for _, row in pairs(rows) do row.hz_coverNow = nil end

    for _, ply in ipairs(player.GetAll()) do CoverFor(ply:EyePos(), now) end

    for zombie in pairs(HZ.Zombies) do
        zombie.hz_cover = ((zombie.hz_cover or 0) + (zombie.hz_coverNow or 0)) * 0.5
    end

    for _, row in pairs(rows) do
        row.hz_cover = ((row.hz_cover or 0) + (row.hz_coverNow or 0)) * 0.5
    end
end

local function CoverScale(ref)
    local factor = 1 + 0.75 * min(ref.hz_cover or 0, 8)

    return factor * factor
end

timer.Create("hordez_virtual_cover", 1, 0, function()
    if not HZ.VirtualOn() or HZ.AIDisabled() then return end
    if HZ.VCount == 0 and HZ.Count <= CV.real_max:GetInt() then return end

    local t0 = HZ.ProfOn and SysTime()
    CoverPass()
    if t0 then HZ.ProfAdd("sv_vcover", SysTime() - t0) end
end)

local PROMOTE_PER_PASS = 2
local SWAP_PER_PASS = 2
local waiting = {}

local function ByDist(a, b)
    return a.d2 < b.d2
end

local function ByDistDesc(a, b)
    return a.d2 > b.d2
end

local function TradePlaces(count, targets, targetCount, cap)
    table.sort(waiting, ByDist)
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
                            d2 = NearestTarget2(targets, targetCount, pos) * CoverScale(zombie) }
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

timer.Create("hordez_virtual", 0.25, 0, function()
    if HZ.VCount == 0 then
        if #pendDel > 0 or #pendGroupDel > 0 then FlushNet() end
        return
    end

    if HZ.AIDisabled() then return end

    local t0 = HZ.ProfOn and SysTime()
    local now = CurTime()
    local targets, targetCount = ViewerList()
    local near = CV.virt_near:GetFloat()
    local nearSqr = near * near
    local groupNearSqr = (near + GROUP_RADIUS) * (near + GROUP_RADIUS)
    local cap = CV.real_max:GetInt()
    local real, promoted = HZ.Count, 0
    local waitCount = 0

    for _, group in pairs(groups) do
        if group.count > 0 then
            local gx, gy, gz = PosAt(group, now)
            group._x, group._y, group._z = gx, gy, gz
            local groupBest = huge
            for i = 1, targetCount do
                local viewer = targets[i]
                local dx, dy, dz = viewer.x - gx, viewer.y - gy, viewer.z - gz
                local distSqr = dx * dx + dy * dy + dz * dz
                if distSqr < groupBest then groupBest = distSqr end
            end

            if groupBest <= groupNearSqr then
                group.nearest, group.cover = huge, huge
                for _, row in pairs(group.rows) do
                    local x, y, z = gx + row.ox, gy + row.oy, gz
                    local best = huge
                    for i = 1, targetCount do
                        local viewer = targets[i]
                        local dx, dy, dz = viewer.x - x, viewer.y - y, viewer.z - z
                        local distSqr = dx * dx + dy * dy + dz * dz
                        if distSqr < best then best = distSqr end
                    end

                    if best < nearSqr and real < cap and promoted < PROMOTE_PER_PASS and PromoteRow(row, x, y, z) then
                        real, promoted = real + 1, promoted + 1
                    else
                        if best < group.nearest then group.nearest = best end
                        if (row.hz_cover or 0) < group.cover then group.cover = row.hz_cover or 0 end
                        if best < nearSqr then
                            waitCount = waitCount + 1
                            local wait = waiting[waitCount]
                            if not wait then
                                wait = {}
                                waiting[waitCount] = wait
                            end

                            wait.r, wait.d2, wait.x, wait.y, wait.z = row, best * CoverScale(row), x, y, z
                        end
                    end
                end
            else
                group.nearest, group.cover = groupBest, 0
            end
        end
    end

    for i = #waiting, waitCount + 1, -1 do waiting[i] = nil end
    if waitCount > 0 and targetCount > 0 then TradePlaces(waitCount, targets, targetCount, cap) end

    for _, group in pairs(groups) do
        if group.count > 0 then
            local x, y, z
            if group._x then
                x, y, z = group._x, group._y, group._z
                group._x = nil
            else
                x, y, z = PosAt(group, now)
            end
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
    if t0 then HZ.ProfAdd("sv_virtual", SysTime() - t0) end
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
            local best = raw * CoverScale(zombie)
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

local function KillAsReal(row, x, y, z, attacker, inflictor, dmg, dmgType, force)
    local ent = PromoteRow(row, x, y, z)
    if not ent then
        DropRow(row, true)
        return
    end

    timer.Simple(0.15, function()
        if not IsValid(ent) or ent.hz_dead then return end

        local dmgInfo = DamageInfo()
        dmgInfo:SetDamage(max(dmg, ent:Health() + 10))
        dmgInfo:SetDamageType(dmgType)
        dmgInfo:SetAttacker(IsValid(attacker) and attacker or game.GetWorld())
        dmgInfo:SetInflictor(IsValid(inflictor) and inflictor or (IsValid(attacker) and attacker or game.GetWorld()))
        dmgInfo:SetDamagePosition(ent:WorldSpaceCenter())
        dmgInfo:SetDamageForce(force)
        ent:TakeDamageInfo(dmgInfo)
    end)
end

hook.Add("EntityFireBullets", "hordez_virtual", function(ent, data)
    if HZ.VCount == 0 or not IsValid(ent) or ent:GetClass() == "hz_zombie" then return end

    local src, dir = data.Src, data.Dir
    if not isvector(src) or not isvector(dir) then return end

    dir = dir:GetNormalized()
    shotIn.start, shotIn.endpos, shotIn.filter = src, src + dir * (data.Distance and data.Distance > 0 and data.Distance
        or 8192), ent

    util.TraceLine(shotIn)
    local len = shotTr.HitPos:Distance(src)
    local sx, sy, sz, dx, dy, dz = src.x, src.y, src.z, dir.x, dir.y, dir.z
    local spread = HZ.BulletSpread(data.Spread)
    local count = max(data.Num or 1, 1)
    local dmg = (data.Damage and data.Damage > 0 and data.Damage or 30) * (count > 1 and count * 0.5 or 1)
    local now = CurTime()
    local hit, hitT, hitX, hitY, hitZ
    for _, group in pairs(groups) do
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

    if not hit then return end

    local hpMax = hit.shambler and CV.sh_health:GetFloat() or CV.health:GetFloat()
    hit.hp = hit.hp - dmg / max(hpMax, 1)
    if hit.hp <= 0 then
        local attacker = IsValid(data.Attacker) and data.Attacker or ent
        local weapon = attacker.GetActiveWeapon and attacker:GetActiveWeapon() or nil
        KillAsReal(hit, hitX, hitY, hitZ, attacker, weapon, dmg, DMG_BULLET, dir * 3000)
        FlushNet()
    end
end)

local BLAST_REAL_MAX = 12
local nextBlast = 0
hook.Add("EntityTakeDamage", "hordez_virtual", function(_, dmg)
    if HZ.VCount == 0 or not dmg:IsExplosionDamage() then return end

    local now = CurTime()
    if now < nextBlast then return end

    nextBlast = now + 0.1
    local inflictor, attacker = dmg:GetInflictor(), dmg:GetAttacker()
    local center = IsValid(inflictor) and inflictor:GetPos() or dmg:GetDamagePosition()
    local rad = math.Clamp(dmg:GetDamage() * 2.5, 150, 450)
    local radiusSqr = rad * rad
    local amount = dmg:GetDamage()
    local groupRadSqr = (rad + GROUP_RADIUS) * (rad + GROUP_RADIUS)
    local shown = 0
    for _, group in pairs(groups) do
        local gx, gy, gz = PosAt(group, now)
        local gdx, gdy, gdz = gx - center.x, gy - center.y, gz - center.z
        if gdx * gdx + gdy * gdy + gdz * gdz < groupRadSqr then
            for _, row in pairs(group.rows) do
                local x, y, z = gx + row.ox, gy + row.oy, gz
                local dx, dy, dz = x - center.x, y - center.y, z - center.z
                if dx * dx + dy * dy + dz * dz < radiusSqr then
                    if shown < BLAST_REAL_MAX then
                        shown = shown + 1
                        KillAsReal(row, x, y, z, attacker, inflictor, amount, DMG_BLAST, Vector(dx, dy, 60) * 400)
                    else
                        DropRow(row, true)
                    end
                end
            end
        end
    end

    FlushNet()
end)

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

hook.Add("PostCleanupMap", "hordez_virtual", HZ.ClearVirtual)
cvars.AddChangeCallback("hz_virtual", function(_, _, new)
    if not tobool(new) then HZ.ClearVirtual() end
end, "hordez_virtual")
