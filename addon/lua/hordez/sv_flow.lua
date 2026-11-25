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

local function BuildGraph()
    if not navmesh.IsLoaded() then navmesh.Load() end
    local all = navmesh.GetAllNavAreas()
    if not all or #all == 0 then
        Flow.graph = nil
        return
    end

    local graph = { area = {}, center = {}, inc = {}, cost = {}, ids = {} }
    for i, area in ipairs(all) do
        local id = area:GetID()
        graph.area[id] = area
        graph.center[id] = area:GetCenter()
        graph.inc[id] = {}
        graph.cost[id] = {}
        graph.ids[#graph.ids + 1] = id
        if i % 2000 == 0 then coroutine.yield() end
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
            end
        end

        if i % 1000 == 0 then coroutine.yield() end
    end

    local links = HZ.CV.climb:GetBool() and Flow.AddClimbLinks(graph, all) or 0
    Flow.graph = graph
    print(("[hordez] flow graph: %d nav areas, %d climb / vault links"):format(#graph.ids, links))
end

local CELL = 128
local CLIMB_MIN, CLIMB_MAX, GAP = 24, 168, 56
local VAULT_GAP, VAULT_LO, VAULT_HI = 110, 18, 62
local UP_MINS, UP_MAXS = Vector(-10, -10, 0), Vector(10, 10, 64)
local TOP_MINS, TOP_MAXS = Vector(-12, -12, 0), Vector(12, 12, 56)

local function ForEachCell(lo, hi, pad, callback)
    for x = math.floor((lo.x - pad) / CELL), math.floor((hi.x + pad) / CELL) do
        for y = math.floor((lo.y - pad) / CELL), math.floor((hi.y + pad) / CELL) do callback(x .. ":" .. y) end
    end
end

function Flow.AddClimbLinks(graph, all)
    local grid, ext = {}, {}
    for i, area in ipairs(all) do
        local extent = area:GetExtentInfo()
        ext[area] = extent
        ForEachCell(extent.lo, extent.hi, 0, function(key)
            local cell = grid[key]
            if not cell then
                cell = {}
                grid[key] = cell
            end

            cell[#cell + 1] = area
        end)

        if i % 1000 == 0 then coroutine.yield() end
    end

    graph.climb = {}
    local count = 0
    for i, area in ipairs(all) do
        local id = area:GetID()
        local extent = ext[area]
        local seen = {}
        ForEachCell(extent.lo, extent.hi, VAULT_GAP, function(key)
            for _, neighbor in ipairs(grid[key] or {}) do
                if neighbor ~= area and not seen[neighbor] then
                    seen[neighbor] = true
                    local otherExtent = ext[neighbor]
                    if not area:IsConnected(neighbor) and otherExtent.lo.z - extent.hi.z <= 20
                        and extent.lo.z - otherExtent.hi.z <= 80 then
                            local link = Flow.VaultLink(graph, area, neighbor)
                            if link then
                                local otherId = neighbor:GetID()
                                local incoming = graph.inc[otherId]
                                incoming[#incoming + 1] = id
                                graph.cost[otherId][#incoming] = link.len + 60
                                graph.climb[id] = graph.climb[id] or {}
                                graph.climb[id][otherId] = link
                                count = count + 1
                            end
                        end

                    if otherExtent.hi.z - extent.lo.z >= CLIMB_MIN and otherExtent.lo.z - extent.hi.z <= CLIMB_MAX
                        and not area:IsConnected(neighbor) then
                            local pointA = area:GetClosestPointOnArea(graph.center[neighbor:GetID()])
                            local pointB = pointA and neighbor:GetClosestPointOnArea(pointA)
                            if pointB then
                                local dz = pointB.z - pointA.z
                                local distSqr = Vector(pointB.x - pointA.x, pointB.y - pointA.y, 0)
                                if dz >= CLIMB_MIN and dz <= CLIMB_MAX and distSqr:Length() <= GAP then
                                    local dir = distSqr:Length() > 1 and distSqr:GetNormalized()
                                        or Vector(graph.center[neighbor:GetID()].x - pointA.x,
                                        graph.center[neighbor:GetID()].y - pointA.y, 0):GetNormalized()

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
                                        graph.cost[otherId][#incoming] = distSqr:Length() + dz * 2 + 80
                                        graph.climb[id] = graph.climb[id] or {}
                                        graph.climb[id][otherId] = { foot = foot, top = top }
                                        count = count + 1
                                    end
                                end
                            end
                        end
                end
            end
        end)

        if i % 150 == 0 then coroutine.yield() end
    end

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
            coroutine.yield()
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

hook.Add("Think", "hordez_flow", function()
    if not HZ.NeedFlow() then return end

    if not Flow.graph then
        if not co_graph then
            if Flow.noNav then return end

            co_graph = coroutine.create(BuildGraph)
        end

        local ok, err = coroutine.resume(co_graph)
        if not ok then ErrorNoHalt("[hordez] graph build failed: " .. tostring(err) .. "\n") end
        if coroutine.status(co_graph) == "dead" then
            co_graph = nil
            if not Flow.graph then
                Flow.noNav = true
                print("[hordez] no navmesh on this map - zombies only chase what they can see (nav_generate to fix)")
            end
        end

        return
    end

    if co_solve then
        local ok, err = coroutine.resume(co_solve)
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

concommand.Add("hz_flow_rebuild", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end

    Flow.graph, Flow.noNav, Flow.ready = nil, nil, false
    Flow.dist, Flow.nxt, Flow.tgt = {}, {}, {}
    co_graph, co_solve, solvedKey = nil, nil, nil
    print("[hordez] flow field reset; rebuilds on next use")
end)
