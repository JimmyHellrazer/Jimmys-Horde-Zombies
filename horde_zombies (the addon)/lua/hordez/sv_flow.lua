-- Shared flow field over the navmesh: one multi-source Dijkstra from every target's nav area outward
-- (over reversed nav connections), solved incrementally inside a coroutine (hz_flow_budget pops per tick).
-- A chasing zombie just reads Flow.nxt[its area] - O(1) per zombie no matter how many there are.
HZ.Flow = HZ.Flow or {}
local Flow = HZ.Flow

Flow.graph = Flow.graph or nil   -- { area = {id=area}, center = {id=vec}, inc = {id={from ids}}, cost = {id={costs}}, ids = {} }
Flow.dist = Flow.dist or {}      -- area id -> path distance to nearest target
Flow.nxt = Flow.nxt or {}        -- area id -> next area id toward that target (false = target is in this area)
Flow.tgt = Flow.tgt or {}        -- area id -> target entity the path leads to
Flow.ready = false
Flow.building = false

local co_graph, co_solve
local nextSolve = 0

---------------------------------------------------------------- graph
local function buildGraph()
	if not navmesh.IsLoaded() then navmesh.Load() end
	local all = navmesh.GetAllNavAreas()
	if not all or #all == 0 then
		Flow.graph = nil
		return
	end
	local g = { area = {}, center = {}, inc = {}, cost = {}, ids = {} }
	for i, a in ipairs(all) do
		local id = a:GetID()
		g.area[id] = a
		g.center[id] = a:GetCenter()
		g.inc[id] = {}
		g.cost[id] = {}
		g.ids[#g.ids + 1] = id
		if i % 2000 == 0 then coroutine.yield() end
	end
	for i, a in ipairs(all) do
		local id = a:GetID()
		local c = g.center[id]
		for _, b in ipairs(a:GetAdjacentAreas()) do       -- a -> b is walkable
			local bid = b:GetID()
			local inc = g.inc[bid]
			if inc then
				local bc = g.center[bid]
				local cost = c:Distance(bc)
				local dz = bc.z - c.z
				if dz > 20 then cost = cost + dz * 1.5 end  -- climbing up is slow, prefer ramps
				local n = #inc + 1
				inc[n] = id
				g.cost[bid][n] = cost
			end
		end
		if i % 1000 == 0 then coroutine.yield() end
	end
	local links = HZ.CV.climb:GetBool() and Flow.AddClimbLinks(g, all) or 0
	Flow.graph = g
	print(("[hordez] flow graph: %d nav areas, %d climb / vault links"):format(#g.ids, links))
end

---------------------------------------------------------------- climb links
-- nav_generate only links areas you can walk/jump between, so ledges, walls and low roofs a zombie could
-- climb (24-168 units, the L4D2 climb set) are dead ends for routing. Add one-way "climb up" edges between
-- nearby areas that are that much higher and not connected, checked with hull traces so a zombie really
-- fits: standing room at the foot of the wall, a clear way straight up, and room at the top.
-- g.climb[from][to] = { foot = where to stand, top = where it lands }
local CELL = 128
local CLIMB_MIN, CLIMB_MAX, GAP = 24, 168, 56
-- vault links: two areas at about the same height (or a drop) with waist-high cover between them
local VAULT_GAP, VAULT_LO, VAULT_HI = 110, 18, 62
local UP_MINS, UP_MAXS = Vector(-10, -10, 0), Vector(10, 10, 64)
local TOP_MINS, TOP_MAXS = Vector(-12, -12, 0), Vector(12, 12, 56)

local function cells(lo, hi, pad, fn)
	for x = math.floor((lo.x - pad) / CELL), math.floor((hi.x + pad) / CELL) do
		for y = math.floor((lo.y - pad) / CELL), math.floor((hi.y + pad) / CELL) do fn(x .. ":" .. y) end
	end
end

function Flow.AddClimbLinks(g, all)
	local grid, ext = {}, {}
	for i, a in ipairs(all) do
		local e = a:GetExtentInfo()
		ext[a] = e
		cells(e.lo, e.hi, 0, function(k)
			local c = grid[k]
			if not c then c = {} grid[k] = c end
			c[#c + 1] = a
		end)
		if i % 1000 == 0 then coroutine.yield() end
	end
	g.climb = {}
	local n = 0
	for i, a in ipairs(all) do
		local id = a:GetID()
		local e = ext[a]
		local seen = {}
		cells(e.lo, e.hi, VAULT_GAP, function(k)
			for _, b in ipairs(grid[k] or {}) do
				if b ~= a and not seen[b] then
					seen[b] = true
					local eb = ext[b]
					if not a:IsConnected(b) and eb.lo.z - e.hi.z <= 20 and e.lo.z - eb.hi.z <= 80 then
						local l = Flow.VaultLink(g, a, b)
						if l then
							local bid = b:GetID()
							local inc = g.inc[bid]
							inc[#inc + 1] = id
							g.cost[bid][#inc] = l.len + 60
							g.climb[id] = g.climb[id] or {}
							g.climb[id][bid] = l
							n = n + 1
						end
					end
					-- cheap rejects before any trace: b must be higher, but not out of reach
					if eb.hi.z - e.lo.z >= CLIMB_MIN and eb.lo.z - e.hi.z <= CLIMB_MAX and not a:IsConnected(b) then
						local pa = a:GetClosestPointOnArea(g.center[b:GetID()])
						local pb = pa and b:GetClosestPointOnArea(pa)
						if pb then
							local dz = pb.z - pa.z
							local d2 = Vector(pb.x - pa.x, pb.y - pa.y, 0)
							if dz >= CLIMB_MIN and dz <= CLIMB_MAX and d2:Length() <= GAP then
								local dir = d2:Length() > 1 and d2:GetNormalized()
									or Vector(g.center[b:GetID()].x - pa.x, g.center[b:GetID()].y - pa.y, 0):GetNormalized()
								local foot = pa - dir * 14
								local up = util.TraceHull({ start = foot + Vector(0, 0, 8), endpos = foot + Vector(0, 0, dz + 8),
									mins = UP_MINS, maxs = UP_MAXS, mask = MASK_NPCSOLID_BRUSHONLY })
								local top = pb + dir * 16
								local over = not up.Hit and util.TraceHull({ start = Vector(foot.x, foot.y, pb.z + 6),
									endpos = top + Vector(0, 0, 6), mins = TOP_MINS, maxs = TOP_MAXS, mask = MASK_NPCSOLID_BRUSHONLY })
								if over and not over.Hit then
									local bid = b:GetID()
									local inc = g.inc[bid]
									inc[#inc + 1] = id
									g.cost[bid][#inc] = d2:Length() + dz * 2 + 80   -- climbing is slow: prefer stairs if close
									g.climb[id] = g.climb[id] or {}
									g.climb[id][bid] = { foot = foot, top = top }
									n = n + 1
								end
							end
						end
					end
				end
			end
		end)
		if i % 150 == 0 then coroutine.yield() end
	end
	return n
end

-- a -> b over waist-high cover? { foot, top, vault = true, h, len } or nil
local V_MINS, V_MAXS = Vector(-10, -10, 0), Vector(10, 10, 30)
function Flow.VaultLink(g, a, b)
	local pa = a:GetClosestPointOnArea(g.center[b:GetID()])
	local pb = pa and b:GetClosestPointOnArea(pa)
	if not pb then return nil end
	local dz = pb.z - pa.z
	local d2 = Vector(pb.x - pa.x, pb.y - pa.y, 0)
	local len = d2:Length()
	if dz > 20 or dz < -80 or len < 16 or len > VAULT_GAP then return nil end
	local dir = d2 / len
	-- blocked at shin height (else it's a plain gap or a missed nav connection, not cover)
	local low = util.TraceHull({ start = pa + Vector(0, 0, 20), endpos = pb + Vector(0, 0, 20),
		mins = Vector(-8, -8, 0), maxs = Vector(8, 8, 8), mask = MASK_NPCSOLID_BRUSHONLY })
	if not low.Hit or low.StartSolid then return nil end
	-- the cover's height, a little past where it starts
	local mid = low.HitPos + dir * 10
	local t = util.TraceLine({ start = Vector(mid.x, mid.y, pa.z + VAULT_HI + 8), endpos = Vector(mid.x, mid.y, pa.z),
		mask = MASK_NPCSOLID_BRUSHONLY })
	if t.StartSolid or not t.Hit then return nil end
	local h = t.HitPos.z - pa.z
	if h < VAULT_LO or h > VAULT_HI then return nil end
	local top = pb + dir * 16
	local over = util.TraceHull({ start = pa + Vector(0, 0, h + 6), endpos = Vector(top.x, top.y, pa.z + h + 6),
		mins = V_MINS, maxs = V_MAXS, mask = MASK_NPCSOLID_BRUSHONLY })
	if over.Hit or over.StartSolid then return nil end
	return { foot = pa - dir * 10, top = top, vault = true, h = h, len = len }
end

-- the climb link from area id a to area id b, if the route goes over a wall there
function Flow.ClimbLink(a, b)
	local g = Flow.graph
	local c = g and g.climb and g.climb[a]
	return c and c[b]
end

-- is this target standing on the navmesh? (cached 0.5 s per target)
function Flow.OnMesh(ent)
	local now = CurTime()
	if ent.hz_onMeshT and now - ent.hz_onMeshT < 0.5 then return ent.hz_onMesh end
	local pos = ent:GetPos()
	local a = navmesh.GetNavArea(pos, 40)
	ent.hz_onMesh = a ~= nil and math.abs(a:GetZ(pos) - pos.z) < 40
	ent.hz_onMeshT = now
	return ent.hz_onMesh
end

---------------------------------------------------------------- binary heap (parallel arrays)
local hk, hv, hn = {}, {}, 0
local function hpush(k, v)
	hn = hn + 1
	local i = hn
	while i > 1 do
		local p = math.floor(i / 2)
		if hk[p] <= k then break end
		hk[i], hv[i] = hk[p], hv[p]
		i = p
	end
	hk[i], hv[i] = k, v
end
local function hpop()
	local k, v = hk[1], hv[1]
	local lk, lv = hk[hn], hv[hn]
	hk[hn], hv[hn] = nil, nil
	hn = hn - 1
	if hn > 0 then
		local i = 1
		while true do
			local l = i * 2
			if l > hn then break end
			local r = l + 1
			local c = (r <= hn and hk[r] < hk[l]) and r or l
			if hk[c] >= lk then break end
			hk[i], hv[i] = hk[c], hv[c]
			i = c
		end
		hk[i], hv[i] = lk, lv
	end
	return k, v
end

---------------------------------------------------------------- solve
function Flow.AreaOf(ent)
	-- cached nearest nav area of a target, refreshed when the target leaves it
	local pos = ent:GetPos()
	local a = ent.hz_navArea
	if a and IsValid(a) and a:IsOverlapping(pos, 8) and math.abs(a:GetZ(pos) - pos.z) < 60 then return a end
	a = navmesh.GetNavArea(pos, 120) or navmesh.GetNearestNavArea(pos, false, 300, false, true)
	ent.hz_navArea = a
	return a
end

local function solve(sources)
	local g = Flow.graph
	local dist, nxt, tgt = {}, {}, {}
	hk, hv, hn = {}, {}, 0
	for _, s in ipairs(sources) do
		local id = s[1]
		if g.inc[id] and not dist[id] then
			dist[id] = 0
			nxt[id] = false
			tgt[id] = s[2]
			hpush(0, id)
		end
	end
	local budget = math.max(100, HZ.CV.flow_budget:GetInt())
	local maxd = HZ.CV.flow_range:GetFloat()
	local pops = 0
	local inc, cost = g.inc, g.cost
	while hn > 0 do
		local d, id = hpop()
		if d <= dist[id] then
			if d > maxd then break end
			local from, c = inc[id], cost[id]
			local t = tgt[id]
			for i = 1, #from do
				local a = from[i]
				local nd = d + c[i]
				local od = dist[a]
				if not od or nd < od then
					dist[a] = nd
					nxt[a] = id
					tgt[a] = t
					hpush(nd, a)
				end
			end
		end
		pops = pops + 1
		if pops >= budget then
			pops = 0
			coroutine.yield()
		end
	end
	Flow.dist, Flow.nxt, Flow.tgt = dist, nxt, tgt
	Flow.ready = true
	Flow.stamp = CurTime()
end

local function gatherSources()
	local src = {}
	for _, t in ipairs(HZ.GetTargets()) do
		if IsValid(t.ent) then
			local a = Flow.AreaOf(t.ent)
			if a then src[#src + 1] = { a:GetID(), t.ent } end
		end
	end
	return src
end

---------------------------------------------------------------- driver
hook.Add("Think", "hordez_flow", function()
	if not HZ.NeedFlow() then return end
	if not Flow.graph then
		if not co_graph then
			if Flow.noNav then return end
			co_graph = coroutine.create(buildGraph)
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
		if not ok then ErrorNoHalt("[hordez] flow solve failed: " .. tostring(err) .. "\n") co_solve = nil return end
		if coroutine.status(co_solve) == "dead" then
			co_solve = nil
			nextSolve = CurTime() + 0.5
		end
		return
	end
	if CurTime() < nextSolve then return end
	local src = gatherSources()
	if #src == 0 then nextSolve = CurTime() + 1 return end
	co_solve = coroutine.create(function() solve(src) end)
end)

-- next area id (false = already in the target's area, nil = no route), path distance, target entity
function Flow.Step(areaId)
	return Flow.nxt[areaId], Flow.dist[areaId], Flow.tgt[areaId]
end

function Flow.Area(id)
	local g = Flow.graph
	return g and g.area[id]
end

concommand.Add("hz_flow_rebuild", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	Flow.graph, Flow.noNav, Flow.ready = nil, nil, false
	Flow.dist, Flow.nxt, Flow.tgt = {}, {}, {}
	co_graph, co_solve = nil, nil
	print("[hordez] flow field reset; rebuilds on next use")
end)
