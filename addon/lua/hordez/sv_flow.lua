HZ.Flow = HZ.Flow or {}
local Flow = HZ.Flow

Flow.graph = Flow.graph or nil
Flow.dist = Flow.dist or {}
Flow.nxt = Flow.nxt or {}
Flow.tgt = Flow.tgt or {}
Flow.ready = false
Flow.building = false

local co_graph, co_solve
local nextSolve = 0
local solvedKey
local rshift = bit.rshift
local SysTime = SysTime
local sliceEnd = 0

local function Breathe()
    if SysTime() < sliceEnd then return end

    coroutine.yield()
end

local function Resume(co)
    sliceEnd = SysTime() + math.Clamp(HZ.CV.flow_build:GetFloat(), 1, 50) / 1000

    return coroutine.resume(co)
end

local TIGHT_SIDE, NARROW_SIDE = 110, 60

local function BuildGraph()
    if not navmesh.IsLoaded() then navmesh.Load() end
    local all = navmesh.GetAllNavAreas()
    if not all or #all == 0 then
        Flow.graph = nil
        return
    end

    local started = SysTime()
    local graph = { area = {}, center = {}, inc = {}, cost = {}, ids = {}, tight = {} }
    local narrow = {}
    local signature = #all
    for i, area in ipairs(all) do
        local id = area:GetID()
        local center = area:GetCenter()
        signature = (signature * 33 + id + math.floor(center.x) * 3 + math.floor(center.y) * 5
            + math.floor(center.z) * 7) % 2147483647

        graph.area[id] = area
        graph.center[id] = center
        graph.inc[id] = {}
        graph.cost[id] = {}
        graph.ids[#graph.ids + 1] = id
        local side = math.min(area:GetSizeX(), area:GetSizeY())
        if side <= TIGHT_SIDE then graph.tight[id] = true end
        if side <= NARROW_SIDE then narrow[id] = true end
        if i % 64 == 0 then Breathe() end
    end

    for i, area in ipairs(all) do
        local id = area:GetID()
        local center = graph.center[id]
        for _, neighbor in ipairs(area:GetAdjacentAreas()) do
            local otherId = neighbor:GetID()
            local incoming = graph.inc[otherId]
            if incoming then
                local otherCenter = graph.center[otherId]
                local cost = center:Distance(otherCenter)
                local dz = otherCenter.z - center.z
                if dz > 20 then cost = cost + dz * 1.5 end
                local index = #incoming + 1
                incoming[index] = id
                graph.cost[otherId][index] = cost
                if narrow[id] then graph.tight[otherId] = true end
                if narrow[otherId] then graph.tight[id] = true end
            end
        end

        if i % 32 == 0 then Breathe() end
    end

    local links, source = 0, "found"
    if HZ.CV.climb:GetBool() then
        links = Flow.LoadLinks(graph, signature)
        if links then
            source = "from cache"
        else
            local saved
            links, saved = Flow.AddClimbLinks(graph, all)
            Flow.SaveLinks(saved, signature)
        end

        links = links + Flow.AddLadderLinks(graph, all)
    end

    Flow.graph = graph
    print(("[hordez] flow graph: %d nav areas (%d tight), %d climb / vault links (%s), built in %.1f s"):format(
        #graph.ids, table.Count(graph.tight), links, source, SysTime() - started))
end

local CELL = 128
local CLIMB_MIN, CLIMB_MAX, GAP = 24, 168, 56
local VAULT_GAP, VAULT_LO, VAULT_HI = 110, 18, 62
local UP_MINS, UP_MAXS = Vector(-10, -10, 0), Vector(10, 10, 64)
local TOP_MINS, TOP_MAXS = Vector(-12, -12, 0), Vector(12, 12, 56)

function Flow.AddClimbLinks(graph, all)
    local floor, max = math.floor, math.max
    local grid = {}
    local loX, loY, loZ, hiX, hiY, hiZ = {}, {}, {}, {}, {}, {}
    for i, area in ipairs(all) do
        local extent = area:GetExtentInfo()
        local lo, hi = extent.lo, extent.hi
        loX[i], loY[i], loZ[i], hiX[i], hiY[i], hiZ[i] = lo.x, lo.y, lo.z, hi.x, hi.y, hi.z
        for x = floor(loX[i] / CELL), floor(hiX[i] / CELL) do
            for y = floor(loY[i] / CELL), floor(hiY[i] / CELL) do
                local key = x * 65536 + y
                local cell = grid[key]
                if not cell then
                    cell = {}
                    grid[key] = cell
                end

                cell[#cell + 1] = i
            end
        end

        if i % 32 == 0 then Breathe() end
    end

    graph.climb = {}
    local count = 0
    local saved = {}
    local seen = {}
    local vaultGapSqr, climbGapSqr = VAULT_GAP * VAULT_GAP, GAP * GAP
    for i, area in ipairs(all) do
        local id = area:GetID()
        local ax0, ay0, az0, ax1, ay1, az1 = loX[i], loY[i], loZ[i], hiX[i], hiY[i], hiZ[i]
        for x = floor((ax0 - VAULT_GAP) / CELL), floor((ax1 + VAULT_GAP) / CELL) do
            for y = floor((ay0 - VAULT_GAP) / CELL), floor((ay1 + VAULT_GAP) / CELL) do
                local cell = grid[x * 65536 + y]
                for k = 1, cell and #cell or 0 do
                    local j = cell[k]
                    if j ~= i and seen[j] ~= i then
                        seen[j] = i
                        local gapX = max(loX[j] - ax1, ax0 - hiX[j], 0)
                        local gapY = max(loY[j] - ay1, ay0 - hiY[j], 0)
                        local gapSqr = gapX * gapX + gapY * gapY
                        local bz0, bz1 = loZ[j], hiZ[j]
                        local vault = gapSqr <= vaultGapSqr and bz0 - az1 <= 20 and az0 - bz1 <= 80
                        local climb = gapSqr <= climbGapSqr and bz1 - az0 >= CLIMB_MIN and bz0 - az1 <= CLIMB_MAX
                        local neighbor = (vault or climb) and all[j]
                        if neighbor and not area:IsConnected(neighbor) then
                            if vault then
                                local link = Flow.VaultLink(graph, area, neighbor)
                                if link then
                                    local otherId = neighbor:GetID()
                                    local incoming = graph.inc[otherId]
                                    incoming[#incoming + 1] = id
                                    graph.cost[otherId][#incoming] = link.len + 60
                                    graph.climb[id] = graph.climb[id] or {}
                                    graph.climb[id][otherId] = link
                                    saved[#saved + 1] = { id, otherId, link.len + 60, link }
                                    count = count + 1
                                end
                            end

                            if climb then
                                local otherCenter = graph.center[neighbor:GetID()]
                                local pointA = area:GetClosestPointOnArea(otherCenter)
                                local pointB = pointA and neighbor:GetClosestPointOnArea(pointA)
                                if pointB then
                                    local dz = pointB.z - pointA.z
                                    local flat = Vector(pointB.x - pointA.x, pointB.y - pointA.y, 0)
                                    local len = flat:Length()
                                    if dz >= CLIMB_MIN and dz <= CLIMB_MAX and len <= GAP then
                                        local dir = len > 1 and flat:GetNormalized()
                                            or Vector(otherCenter.x - pointA.x, otherCenter.y - pointA.y,
                                            0):GetNormalized()

                                        local foot = pointA - dir * 14
                                        local tr = util.TraceHull({ start = foot + Vector(0, 0, 8),
                                            endpos = foot + Vector(0, 0, dz + 8),
                                            mins = UP_MINS, maxs = UP_MAXS, mask = MASK_NPCSOLID_BRUSHONLY })

                                        local top = pointB + dir * 16
                                        local over = not tr.Hit
                                            and util.TraceHull({ start = Vector(foot.x, foot.y, pointB.z + 6),
                                            endpos = top + Vector(0, 0, 6), mins = TOP_MINS, maxs = TOP_MAXS,
                                            mask = MASK_NPCSOLID_BRUSHONLY })

                                        if over and not over.Hit then
                                            local otherId = neighbor:GetID()
                                            local incoming = graph.inc[otherId]
                                            incoming[#incoming + 1] = id
                                            local link = { foot = foot, top = top }
                                            graph.cost[otherId][#incoming] = len + dz * 2 + 80
                                            graph.climb[id] = graph.climb[id] or {}
                                            graph.climb[id][otherId] = link
                                            saved[#saved + 1] = { id, otherId, len + dz * 2 + 80, link }
                                            count = count + 1
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if i % 4 == 0 then Breathe() end
    end

    return count, saved
end

local LADDER_TOPS = { "GetTopForwardArea", "GetTopLeftArea", "GetTopRightArea", "GetTopBehindArea" }

local function LinkEdge(graph, fromId, toId, cost, link)
    if graph.climb[fromId] and graph.climb[fromId][toId] then return 0 end

    local incoming = graph.inc[toId]
    if not incoming then return 0 end

    incoming[#incoming + 1] = fromId
    graph.cost[toId][#incoming] = cost
    graph.climb[fromId] = graph.climb[fromId] or {}
    graph.climb[fromId][toId] = link

    return 1
end

local function AddLadder(graph, ladder)
    local bottomArea = ladder:GetBottomArea()
    if not IsValid(bottomArea) or not graph.area[bottomArea:GetID()] then return 0 end

    local normal = ladder:GetNormal()
    normal.z = 0
    if normal:LengthSqr() < 0.01 then return 0 end

    normal:Normalize()
    local column = ladder:GetBottom() + normal * 16
    local bottomZ = bottomArea:GetZ(column)
    local bottomLand = bottomArea:GetClosestPointOnArea(column)
    local top = ladder:GetTop()
    local count = 0
    for _, getter in ipairs(LADDER_TOPS) do
        local topArea = ladder[getter](ladder)
        if IsValid(topArea) and topArea ~= bottomArea and graph.area[topArea:GetID()] then
            local land = topArea:GetClosestPointOnArea(top - normal * 40)
            local height = land and land.z - bottomZ
            if height and height > CLIMB_MAX and not bottomArea:IsConnected(topArea) then
                local shared = { ladder = true, id = ladder:GetID(), normal = normal, colX = column.x,
                    colY = column.y, bottomZ = bottomZ, topZ = land.z, land = land, bottomLand = bottomLand,
                    h = height }

                local upLink = setmetatable({ up = true, foot = Vector(column.x, column.y, bottomZ), top = land },
                    { __index = shared })
                local downLink = setmetatable({ up = false, foot = land, top = bottomLand }, { __index = shared })
                local bottomId, topId = bottomArea:GetID(), topArea:GetID()
                count = count + LinkEdge(graph, bottomId, topId, height * 1.5 + 120, upLink)
                count = count + LinkEdge(graph, topId, bottomId, height + 80, downLink)
            end
        end
    end

    return count
end

function Flow.AddLadderLinks(graph, all)
    graph.climb = graph.climb or {}
    local done, count = {}, 0
    for i, area in ipairs(all) do
        for _, ladder in ipairs(area:GetLadders() or {}) do
            if IsValid(ladder) and not done[ladder:GetID()] then
                done[ladder:GetID()] = true
                count = count + AddLadder(graph, ladder)
            end
        end

        if i % 64 == 0 then Breathe() end
    end

    return count
end

local LINK_MAGIC, LINK_VERSION = 0x485A4C4B, 1

local function LinkFile()
    return "hordez/links_" .. game.GetMap() .. ".dat"
end

local function MapStamp()
    local map = game.GetMap()

    return file.Time("maps/" .. map .. ".bsp", "GAME") or 0, file.Time("maps/" .. map .. ".nav", "GAME") or 0
end

function Flow.SaveLinks(saved, signature)
    if not HZ.CV.flow_cache:GetBool() then return end

    file.CreateDir("hordez")
    local out = file.Open(LinkFile(), "wb", "DATA")
    if not out then return end

    local bspTime, navTime = MapStamp()
    out:WriteULong(LINK_MAGIC)
    out:WriteULong(LINK_VERSION)
    out:WriteULong(signature)
    out:WriteULong(bspTime)
    out:WriteULong(navTime)
    out:WriteULong(#saved)
    for i, entry in ipairs(saved) do
        local link = entry[4]
        out:WriteULong(entry[1])
        out:WriteULong(entry[2])
        out:WriteFloat(entry[3])
        out:WriteFloat(link.foot.x)
        out:WriteFloat(link.foot.y)
        out:WriteFloat(link.foot.z)
        out:WriteFloat(link.top.x)
        out:WriteFloat(link.top.y)
        out:WriteFloat(link.top.z)
        out:WriteBool(link.vault == true)
        out:WriteFloat(link.h or 0)
        out:WriteFloat(link.len or 0)
        if i % 256 == 0 then Breathe() end
    end

    out:Close()
end

function Flow.LoadLinks(graph, signature)
    if not HZ.CV.flow_cache:GetBool() then return nil end

    local input = file.Open(LinkFile(), "rb", "DATA")
    if not input then return nil end

    local bspTime, navTime = MapStamp()
    local fresh = input:ReadULong() == LINK_MAGIC and input:ReadULong() == LINK_VERSION
        and input:ReadULong() == signature and input:ReadULong() == bspTime and input:ReadULong() == navTime

    if not fresh then
        input:Close()
        return nil
    end

    local count = input:ReadULong()
    local climb, added = {}, {}
    for i = 1, count do
        local id, otherId, cost = input:ReadULong(), input:ReadULong(), input:ReadFloat()
        local foot = Vector(input:ReadFloat(), input:ReadFloat(), input:ReadFloat())
        local top = Vector(input:ReadFloat(), input:ReadFloat(), input:ReadFloat())
        local vault, height, len = input:ReadBool(), input:ReadFloat(), input:ReadFloat()
        if not id or not len or not graph.inc[id] or not graph.inc[otherId] then
            input:Close()
            return nil
        end

        added[i] = { id, otherId, cost }
        climb[id] = climb[id] or {}
        climb[id][otherId] = vault and { foot = foot, top = top, vault = true, h = height, len = len }
            or { foot = foot, top = top }

        if i % 256 == 0 then Breathe() end
    end

    input:Close()
    for i = 1, count do
        local entry = added[i]
        local incoming = graph.inc[entry[2]]
        incoming[#incoming + 1] = entry[1]
        graph.cost[entry[2]][#incoming] = entry[3]
    end

    graph.climb = climb

    return count
end

local V_MINS, V_MAXS = Vector(-10, -10, 0), Vector(10, 10, 30)

function Flow.VaultLink(graph, areaA, areaB)
    local pointA = areaA:GetClosestPointOnArea(graph.center[areaB:GetID()])
    local pointB = pointA and areaB:GetClosestPointOnArea(pointA)
    if not pointB then return nil end

    local dz = pointB.z - pointA.z
    local distSqr = Vector(pointB.x - pointA.x, pointB.y - pointA.y, 0)
    local len = distSqr:Length()
    if dz > 20 or dz < -80 or len < 16 or len > VAULT_GAP then return nil end

    local dir = distSqr / len
    local low = util.TraceHull({ start = pointA + Vector(0, 0, 20), endpos = pointB + Vector(0, 0, 20),
        mins = Vector(-8, -8, 0), maxs = Vector(8, 8, 8), mask = MASK_NPCSOLID_BRUSHONLY })

    if not low.Hit or low.StartSolid then return nil end

    local mid = low.HitPos + dir * 10
    local tr = util.TraceLine({ start = Vector(mid.x, mid.y, pointA.z + VAULT_HI + 8),
        endpos = Vector(mid.x, mid.y, pointA.z),
        mask = MASK_NPCSOLID_BRUSHONLY })

    if tr.StartSolid or not tr.Hit then return nil end

    local height = tr.HitPos.z - pointA.z
    if height < VAULT_LO or height > VAULT_HI then return nil end

    local top = pointB + dir * 16
    local over = util.TraceHull({ start = pointA + Vector(0, 0, height + 6),
        endpos = Vector(top.x, top.y, pointA.z + height + 6),
        mins = V_MINS, maxs = V_MAXS, mask = MASK_NPCSOLID_BRUSHONLY })

    if over.Hit or over.StartSolid then return nil end

    return { foot = pointA - dir * 10, top = top, vault = true, h = height, len = len }
end

local PORTAL_OVERLAP = 8
local portalGraph, rects, portals

local function AreaRect(graph, id)
    local rect = rects[id]
    if rect ~= nil then return rect end

    rect = false
    local area = graph.area[id]
    if area and IsValid(area) then
        local a, b = area:GetCorner(0), area:GetCorner(2)
        rect = { math.min(a.x, b.x), math.min(a.y, b.y), math.max(a.x, b.x), math.max(a.y, b.y) }
    end

    rects[id] = rect

    return rect
end

local function EdgePortal(a, b, lo, hi, alongX)
    local near, far = alongX and 2 or 1, alongX and 4 or 3
    local sign = (b[near] + b[far]) > (a[near] + a[far]) and 1 or -1

    return { alongX = alongX, lo = lo, hi = hi, sign = sign, aEdge = sign > 0 and a[far] or a[near],
        bEdge = sign > 0 and b[near] or b[far], aDepth = a[far] - a[near], bDepth = b[far] - b[near] }
end

function Flow.Portal(fromId, toId)
    local graph = Flow.graph
    if not graph then return false end

    if graph ~= portalGraph then portalGraph, rects, portals = graph, {}, {} end
    local row = portals[fromId]
    if not row then
        row = {}
        portals[fromId] = row
    end

    local portal = row[toId]
    if portal ~= nil then return portal end

    portal = false
    local a, b = AreaRect(graph, fromId), AreaRect(graph, toId)
    if a and b then
        local xLo, xHi = math.max(a[1], b[1]), math.min(a[3], b[3])
        local yLo, yHi = math.max(a[2], b[2]), math.min(a[4], b[4])
        local alongX = xHi - xLo > 1 and yHi - yLo < PORTAL_OVERLAP
        local alongY = yHi - yLo > 1 and xHi - xLo < PORTAL_OVERLAP
        if alongX ~= alongY then
            portal = alongX and EdgePortal(a, b, xLo, xHi, true) or EdgePortal(a, b, yLo, yHi, false)
        end
    end

    row[toId] = portal

    return portal
end

function Flow.ClimbLink(fromId, toId)
    local graph = Flow.graph
    local links = graph and graph.climb and graph.climb[fromId]

    return links and links[toId]
end

function Flow.OnMesh(ent)
    local now = CurTime()
    if ent.hz_onMeshT and now - ent.hz_onMeshT < 0.5 then return ent.hz_onMesh end

    local pos = ent:GetPos()
    local area = navmesh.GetNavArea(pos, 40)
    ent.hz_onMesh = area ~= nil and math.abs(area:GetZ(pos) - pos.z) < 40
    ent.hz_onMeshT = now

    return ent.hz_onMesh
end

local heapKeys, heapVals, heapSize = {}, {}, 0

local function HeapPush(key, value)
    heapSize = heapSize + 1
    local i = heapSize
    while i > 1 do
        local parent = rshift(i, 1)
        if heapKeys[parent] <= key then break end

        heapKeys[i], heapVals[i] = heapKeys[parent], heapVals[parent]
        i = parent
    end

    heapKeys[i], heapVals[i] = key, value
end

local function HeapPop()
    local key, value = heapKeys[1], heapVals[1]
    local lastKey, lastVel = heapKeys[heapSize], heapVals[heapSize]
    heapKeys[heapSize], heapVals[heapSize] = nil, nil
    heapSize = heapSize - 1
    if heapSize > 0 then
        local i = 1
        while true do
            local left = i * 2
            if left > heapSize then break end

            local right = left + 1
            local child = (right <= heapSize and heapKeys[right] < heapKeys[left]) and right or left
            if heapKeys[child] >= lastKey then break end

            heapKeys[i], heapVals[i] = heapKeys[child], heapVals[child]
            i = child
        end

        heapKeys[i], heapVals[i] = lastKey, lastVel
    end

    return key, value
end

function Flow.AreaOf(ent)
    local pos = ent:GetPos()
    local area = ent.hz_navArea
    if area and IsValid(area) and area:IsOverlapping(pos, 8) and math.abs(area:GetZ(pos) - pos.z) < 60 then
        return area
    end

    area = navmesh.GetNavArea(pos, 120) or navmesh.GetNearestNavArea(pos, false, 300, false, true)
    ent.hz_navArea = area

    return area
end

local function SolveFlow(sources)
    local graph = Flow.graph
    local dist, nextId, targets = {}, {}, {}
    heapKeys, heapVals, heapSize = {}, {}, 0
    for _, source in ipairs(sources) do
        local id = source[1]
        if graph.inc[id] and not dist[id] then
            dist[id] = 0
            nextId[id] = false
            targets[id] = source[2]
            HeapPush(0, id)
        end
    end

    local budget = math.max(100, HZ.CV.flow_budget:GetInt())
    local maxd = HZ.CV.flow_range:GetFloat()
    local pops = 0
    local incoming, cost = graph.inc, graph.cost
    while heapSize > 0 do
        local curDist, id = HeapPop()
        if curDist <= dist[id] then
            if curDist > maxd then break end

            local from, costs = incoming[id], cost[id]
            local target = targets[id]
            for i = 1, #from do
                local fromId = from[i]
                local nearDist = curDist + costs[i]
                local oldDist = dist[fromId]
                if not oldDist or nearDist < oldDist then
                    dist[fromId] = nearDist
                    nextId[fromId] = id
                    targets[fromId] = target
                    HeapPush(nearDist, fromId)
                end
            end
        end

        pops = pops + 1
        if pops >= budget then
            pops = 0
            if Flow.ready then
                coroutine.yield()
            else
                Breathe()
            end
        end
    end

    Flow.dist, Flow.nxt, Flow.tgt = dist, nextId, targets
    Flow.version = (Flow.version or 0) + 1
    Flow.ready = true
    Flow.stamp = CurTime()
end

local function SourceKey(src)
    local parts = { HZ.CV.flow_range:GetString() }
    for i = 1, #src do
        local source = src[i]
        parts[#parts + 1] = source[1] .. ":" .. source[2]:GetCreationID()
    end

    return table.concat(parts, ",")
end

local function GatherSources()
    local src = {}
    for _, target in ipairs(HZ.GetTargets()) do
        if IsValid(target.ent) then
            local area = Flow.AreaOf(target.ent)
            if area then src[#src + 1] = { area:GetID(), target.ent } end
        end
    end

    return src
end

local warnedNoNav = false

hook.Add("Think", "hordez_flow", function()
    local needed = HZ.NeedFlow()
    if not needed and not (Flow.prebuild and not Flow.graph and not Flow.noNav) then return end

    if not Flow.graph then
        if not co_graph then
            if Flow.noNav then
                if needed and not warnedNoNav then
                    warnedNoNav = true
                    print("[hordez] no navmesh on this map - zombies only chase what they can see (nav_generate to fix)")
                end

                return
            end

            co_graph = coroutine.create(BuildGraph)
        end

        local ok, err = Resume(co_graph)
        if not ok then ErrorNoHalt("[hordez] graph build failed: " .. tostring(err) .. "\n") end
        if coroutine.status(co_graph) == "dead" then
            co_graph = nil
            if not Flow.graph then Flow.noNav = true end
        end

        return
    end

    if not needed then return end

    if co_solve then
        local t0 = HZ.ProfOn and SysTime()
        local ok, err = Resume(co_solve)
        if t0 then HZ.ProfAdd("sv_flow", SysTime() - t0) end
        if not ok then
            ErrorNoHalt("[hordez] flow solve failed: " .. tostring(err) .. "\n")
            co_solve = nil
            return
        end

        if coroutine.status(co_solve) == "dead" then
            co_solve = nil
            nextSolve = CurTime() + 0.5
        end

        return
    end

    if CurTime() < nextSolve then return end

    local src = GatherSources()
    if #src == 0 then
        nextSolve = CurTime() + 1
        return
    end

    local key = SourceKey(src)
    if Flow.ready and key == solvedKey then
        nextSolve = CurTime() + 0.25
        Flow.stamp = CurTime()
        return
    end

    co_solve = coroutine.create(function()
        SolveFlow(src)
        solvedKey = key
    end)
end)

function Flow.Step(areaId)
    return Flow.nxt[areaId], Flow.dist[areaId], Flow.tgt[areaId]
end

function Flow.Area(id)
    local graph = Flow.graph
    return graph and graph.area[id]
end

concommand.Add("hz_flow_rebuild", function(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then return end

    if args[1] == "fresh" then file.Delete(LinkFile()) end
    Flow.graph, Flow.noNav, Flow.ready = nil, nil, false
    Flow.dist, Flow.nxt, Flow.tgt = {}, {}, {}
    co_graph, co_solve, solvedKey = nil, nil, nil
    print("[hordez] flow field reset; rebuilding" .. (args[1] == "fresh" and " without the link cache" or ""))
end)

hook.Add("InitPostEntity", "hordez_flow_prebuild", function()
    timer.Simple(3, function()
        if HZ.CV.flow_prebuild:GetBool() then Flow.prebuild = true end
    end)
end)
