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

local nextId, freeIds, cooling = 1, {}, {}
local pendAdd, pendMove, pendDel = {}, {}, {}

local function NewId()
    local count = #freeIds
    if count > 0 then
        local id = freeIds[count]
        freeIds[count] = nil
        return id
    end

    if nextId > 65000 then return nil end

    nextId = nextId + 1

    return nextId - 1
end

local function Slice(list, from)
    local out = {}
    for i = from, #list do out[#out + 1] = list[i] end

    return out
end

local function ClampCoord(value)
    return max(-32767, min(32767, floor(value + 0.5)))
end

local function WriteAdd(row, x, y, z)
    net.WriteUInt(row.id, 16)
    net.WriteInt(ClampCoord(x), 16)
    net.WriteInt(ClampCoord(y), 16)
    net.WriteInt(ClampCoord(z), 16)
    net.WriteUInt(min(floor(row.speed), 1023), 10)
    net.WriteBool(row.female)
    net.WriteBool(row.shambler)
end

local CHUNK = 2000

local function FlushNet()
    while #pendDel > 0 or #pendAdd > 0 or #pendMove > 0 do
        net.Start("hz_virt")
        local count = min(#pendDel, CHUNK)
        net.WriteUInt(count, 16)
        for i = 1, count do
            local entry = pendDel[i]
            net.WriteUInt(entry[1], 16)
            net.WriteBool(entry[2])
        end

        pendDel = Slice(pendDel, count + 1)
        local delsLeft = #pendDel > 0
        count = delsLeft and 0 or min(#pendAdd, CHUNK)
        net.WriteUInt(count, 16)
        for i = 1, count do
            local row = pendAdd[i]
            WriteAdd(row, row.x, row.y, row.z)
        end

        pendAdd = Slice(pendAdd, count + 1)
        local addsLeft = delsLeft or #pendAdd > 0
        count = addsLeft and 0 or min(#pendMove, CHUNK)
        net.WriteUInt(count, 16)
        for i = 1, count do
            local row = pendMove[i]
            net.WriteUInt(row.id, 16)
            net.WriteInt(ClampCoord(row.wx), 16)
            net.WriteInt(ClampCoord(row.wy), 16)
            net.WriteInt(ClampCoord(row.wz), 16)
        end

        pendMove = Slice(pendMove, count + 1)
        net.Broadcast()
    end

    for i = 1, #cooling do freeIds[#freeIds + 1] = cooling[i] end
    cooling = {}
end

local function PosAt(row, now)
    local t0, t1 = row.t0, row.t1
    if now >= t1 or t1 <= t0 then return row.wx, row.wy, row.wz end

    local frac = (now - t0) / (t1 - t0)

    return row.x + (row.wx - row.x) * frac, row.y + (row.wy - row.y) * frac, row.z + (row.wz - row.z) * frac
end

function HZ.AddVirtual(pos, opts)
    local id = NewId()
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

    local now = CurTime()
    local row = { id = id, x = pos.x, y = pos.y, z = pos.z, wx = pos.x, wy = pos.y, wz = pos.z, t0 = now, t1 = now,
        speed = max(speed, 5), shambler = shambler and true or false, model = model,
        female = model:find("female", 1, true) ~= nil, hp = opts.hp or 1, area = opts.area, born = now,
        hz_cover = opts.cover }

    rows[id] = row
    HZ.VCount = HZ.VCount + 1
    pendAdd[#pendAdd + 1] = row

    return row
end

local function DropRow(row, killed)
    if rows[row.id] ~= row then return end

    rows[row.id] = nil
    HZ.VCount = HZ.VCount - 1
    pendDel[#pendDel + 1] = { row.id, killed and true or false }
    cooling[#cooling + 1] = row.id
    for i = #pendAdd, 1, -1 do
        if pendAdd[i] == row then
            table.remove(pendAdd, i)
            pendDel[#pendDel] = nil
            break
        end
    end

    for i = #pendMove, 1, -1 do
        if pendMove[i] == row then table.remove(pendMove, i) end
    end
end

function HZ.ClearVirtual()
    for _, row in pairs(rows) do DropRow(row, false) end
    FlushNet()
end

local STEP, LEG_TIME = 260, 1.2
local probe = Vector()

local function NextLeg(row, now, x, y, z)
    local graph = Flow.graph
    if not graph or not Flow.ready then
        row.t1 = now + 1
        return
    end

    local area = row.area
    if not area or not graph.area[area] then
        local navArea = navmesh.GetNearestNavArea(Vector(x, y, z), false, 400, false, true)
        area = navArea and navArea:GetID()
        if not area or not graph.area[area] then
            row.t1 = now + 2
            return
        end

        row.area = area
    end

    if not row.gx then
        local nextId = Flow.nxt[area]
        if nextId == false then
            local target = Flow.tgt[area]
            if not IsValid(target) then
                row.t1 = now + 0.5
                return
            end

            local pos = target:GetPos()
            row.gx, row.gy, row.gz, row.garea, row.gextra = pos.x, pos.y, pos.z, nil, 0
        elseif nextId then
            local nextArea = graph.area[nextId]
            if not IsValid(nextArea) then
                row.t1 = now + 1
                return
            end

            local pos = nextArea:GetClosestPointOnArea(Vector(x, y, z))
            local center = graph.center[nextId]
            local frac = 0.2 + random() * 0.7
            row.gx, row.gy, row.gz = pos.x + (center.x - pos.x) * frac, pos.y + (center.y - pos.y) * frac,
                pos.z + (center.z - pos.z) * frac

            row.garea = nextId
            row.fv = Flow.version
            row.gextra = Flow.ClimbLink(area, nextId) and (0.6 + math.abs(pos.z - z) / 80) or 0
        else
            row.t1 = now + 1
            return
        end
    end

    local dx, dy = row.gx - x, row.gy - y
    local dist = sqrt(dx * dx + dy * dy)
    local tx, ty, tz, extra = nil, nil, nil, 0
    local STEP = max(40, min(STEP, row.speed * LEG_TIME))
    if dist <= STEP then
        tx, ty, tz, extra = row.gx, row.gy, row.gz, row.gextra or 0
        if row.garea then row.area = row.garea end
        row.gx = nil
    else
        tx, ty = x + dx / dist * STEP, y + dy / dist * STEP
        probe:SetUnpacked(tx, ty, z)
        local nextArea, cur = row.garea and graph.area[row.garea], graph.area[area]
        if nextArea and IsValid(nextArea) and nextArea:IsOverlapping(probe, 2) then
            tz = nextArea:GetZ(probe)
        elseif IsValid(cur) and cur:IsOverlapping(probe, 2) then
            tz = cur:GetZ(probe)
        else
            tz = z + (row.gz - z) * (STEP / dist)
        end

        if not row.garea then row.gx = nil end
    end

    local ex, ey, ez = tx - x, ty - y, tz - z
    local len = sqrt(ex * ex + ey * ey + ez * ez)
    row.x, row.y, row.z, row.t0 = x, y, z, now
    row.wx, row.wy, row.wz = tx, ty, tz
    row.t1 = now + max(len / row.speed, 0.05) + extra
    pendMove[#pendMove + 1] = row
end

local function HaltRow(row, now, x, y, z)
    row.hold = true
    row.x, row.y, row.z, row.wx, row.wy, row.wz, row.t0, row.t1 = x, y, z, x, y, z, now, now
    pendMove[#pendMove + 1] = row
end

local function PromoteRow(row, x, y, z)
    local yaw = math.deg(math.atan2(row.wy - row.y, row.wx - row.x))
    local ent = HZ.SpawnZombie(Vector(x, y, z + 4), yaw,
        { alerted = true, shambler = row.shambler, model = row.model, force = true })

    if not IsValid(ent) then return false end

    if row.hp < 1 then ent:SetHealth(max(1, floor(ent:GetMaxHealth() * row.hp))) end
    ent.hz_wasVirtual = true
    ent.hz_promotedAt = CurTime()
    ent.hz_cover = row.hz_cover
    DropRow(row, false)

    return true
end

local function Demotable(zombie)
    return IsValid(zombie)
        and (zombie.hz_alerted
        or (zombie.hz_wasVirtual and not zombie.hz_wakeAt
        and (zombie.hz_pose == "wander" or zombie.hz_pose == "stand")))
        and CurTime() - (zombie.hz_promotedAt or 0) > 4
        and not zombie.hz_dead and not IsValid(zombie.hz_owner) and not zombie.hz_inOnce and not zombie.hz_climbing
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
        hp = math.Clamp(zombie:Health() / max(zombie:GetMaxHealth(), 1), 0.05, 1), cover = zombie.hz_cover })

    if not row then return false end

    zombie.hz_virtualized = true
    zombie:Remove()

    return true
end

local viewers = {}

local function ViewerList()
    local count = 0
    for _, target in ipairs(HZ.GetTargets()) do
        count = count + 1
        viewers[count] = target.pos
    end

    for _, ply in ipairs(player.GetAll()) do
        count = count + 1
        viewers[count] = ply:GetPos()
    end

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

    for _, row in pairs(rows) do
        Add(row, PosAt(row, now))
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

    CoverPass()
end)

local PROMOTE_PER_PASS = 5
local SWAP_PER_PASS = 6
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
        if #pendDel > 0 then FlushNet() end
        return
    end

    if HZ.AIDisabled() then return end

    local now = CurTime()
    local targets, targetCount = ViewerList()
    local near = CV.virt_near:GetFloat()
    local nearSqr = near * near
    local cap = CV.real_max:GetInt()
    local real, promoted = HZ.Count, 0
    local waitCount = 0
    for _, row in pairs(rows) do
        local x, y, z = PosAt(row, now)
        local best = huge
        for i = 1, targetCount do
            local viewer = targets[i]
            local dx, dy, dz = viewer.x - x, viewer.y - y, viewer.z - z
            local distSqr = dx * dx + dy * dy + dz * dz
            if distSqr < best then best = distSqr end
        end

        local walks = true
        if best < nearSqr then
            if real < cap and promoted < PROMOTE_PER_PASS and PromoteRow(row, x, y, z) then
                real, promoted = real + 1, promoted + 1
                walks = false
            else
                waitCount = waitCount + 1
                local wait = waiting[waitCount]
                if not wait then
                    wait = {}
                    waiting[waitCount] = wait
                end

                wait.r, wait.d2, wait.x, wait.y, wait.z = row, best * CoverScale(row), x, y, z
                local stop = max((300 + (row.id % 16) * 25) / (1 + (row.hz_cover or 0)), 90)
                if best < stop * stop then
                    if not row.hold then HaltRow(row, now, x, y, z) end
                    walks = false
                end
            end
        end

        if walks then
            if now >= row.t1 then
                row.hold = nil
                NextLeg(row, now, x, y, z)
            elseif row.gx and row.garea and row.fv ~= Flow.version then
                if Flow.nxt[row.area] ~= row.garea then
                    row.gx = nil
                    NextLeg(row, now, x, y, z)
                else
                    row.fv = Flow.version
                end
            end
        end
    end

    for i = #waiting, waitCount + 1, -1 do waiting[i] = nil end
    if waitCount > 0 and targetCount > 0 then TradePlaces(waitCount, targets, targetCount, cap) end
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
hook.Add("EntityFireBullets", "hordez_virtual", function(ent, data)
    if HZ.VCount == 0 or not IsValid(ent) or ent:GetClass() == "hz_zombie" then return end

    local src, dir = data.Src, data.Dir
    if not src or not dir then return end

    dir = dir:GetNormalized()
    shotIn.start, shotIn.endpos, shotIn.filter = src, src + dir * (data.Distance and data.Distance > 0 and data.Distance
        or 8192), ent

    util.TraceLine(shotIn)
    local len = shotTr.HitPos:Distance(src)
    local sx, sy, sz, dx, dy, dz = src.x, src.y, src.z, dir.x, dir.y, dir.z
    local spread = data.Spread and max(data.Spread.x, data.Spread.y) or 0
    local count = max(data.Num or 1, 1)
    local dmg = (data.Damage and data.Damage > 0 and data.Damage or 30) * (count > 1 and count * 0.5 or 1)
    local now = CurTime()
    local hit, hitT
    for _, row in pairs(rows) do
        local x, y, z = PosAt(row, now)
        local cx, cy, cz = x - sx, y - sy, z + 40 - sz
        local along = cx * dx + cy * dy + cz * dz
        if along > 0 and along < len and (not hitT or along < hitT) then
            local rad = 22 + min(spread * along, 60)
            if cx * cx + cy * cy + cz * cz - along * along < rad * rad then hit, hitT = row, along end
        end
    end

    if not hit then return end

    local hpMax = hit.shambler and CV.sh_health:GetFloat() or CV.health:GetFloat()
    hit.hp = hit.hp - dmg / max(hpMax, 1)
    if hit.hp <= 0 then
        DropRow(hit, true)
        FlushNet()
    end
end)

local nextBlast = 0
hook.Add("EntityTakeDamage", "hordez_virtual", function(_, dmg)
    if HZ.VCount == 0 or not dmg:IsExplosionDamage() then return end

    local now = CurTime()
    if now < nextBlast then return end

    nextBlast = now + 0.1
    local inflictor = dmg:GetInflictor()
    local center = IsValid(inflictor) and inflictor:GetPos() or dmg:GetDamagePosition()
    local rad = math.Clamp(dmg:GetDamage() * 2.5, 150, 450)
    local radiusSqr = rad * rad
    local any
    for _, row in pairs(rows) do
        local x, y, z = PosAt(row, now)
        local dx, dy, dz = x - center.x, y - center.y, z - center.z
        if dx * dx + dy * dy + dz * dz < radiusSqr then
            DropRow(row, true)
            any = true
        end
    end

    if any then FlushNet() end
end)

net.Receive("hz_virt_sync", function(_, ply)
    local now = CurTime()
    if (ply.hz_virtSync or 0) > now then return end

    ply.hz_virtSync = now + 5
    local list = {}
    for _, row in pairs(rows) do list[#list + 1] = row end
    for i = 1, max(#list, 1), CHUNK do
        local count = min(CHUNK, #list - i + 1)
        net.Start("hz_virt")
        net.WriteUInt(0, 16)
        net.WriteUInt(count, 16)
        for index = i, i + count - 1 do
            local row = list[index]
            local x, y, z = PosAt(row, now)
            WriteAdd(row, x, y, z)
        end

        net.WriteUInt(count, 16)
        for index = i, i + count - 1 do
            local row = list[index]
            net.WriteUInt(row.id, 16)
            net.WriteInt(ClampCoord(row.wx), 16)
            net.WriteInt(ClampCoord(row.wy), 16)
            net.WriteInt(ClampCoord(row.wz), 16)
        end

        net.Send(ply)
    end
end)

hook.Add("PostCleanupMap", "hordez_virtual", HZ.ClearVirtual)
cvars.AddChangeCallback("hz_virtual", function(_, _, new)
    if not tobool(new) then HZ.ClearVirtual() end
end, "hordez_virtual")
