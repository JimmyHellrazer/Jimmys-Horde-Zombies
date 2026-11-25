-- Impostors: zombies beyond hz_impostor_dist are not drawn as models at all. Each one is a camera-facing quad
-- showing a pre-rendered picture of a zombie, and all of them are one mesh and one draw call - no skeleton,
-- no skinning, no shadow, however many there are.
--
--  * The atlas (1024 x 1024 render target, 32 x 64 pixel cells) is baked once: 8 stand-in zombies ("variants":
--    running men, running women, a shambler, standing idlers), each seen from 8 directions at 8 moments of
--    its animation loop. A variant's 8 x 8 pictures are two rows of four 8-frame strips.
--  * Four times a second the quads are rebuilt: where each far zombie is, which way it is seen from (that
--    picks the strip), how lit and how fogged it is, and how fast it is moving.
--  * In between, the vertex shader (shaders/hz_impostor_vs2x.hlsl, through screenspace_general) moves each
--    quad along its velocity and steps it through its strip's frames, each zombie on its own phase. So a
--    rebuild is the only Lua cost, and far zombies don't march in step.
-- hz_impostor_debug 1 shows the atlas and the count on screen.

local cvOn = CreateClientConVar("hz_impostors", "1", true, false, "Draw far zombies as flat impostors instead of models")
local cvDist = CreateClientConVar("hz_impostor_dist", "2500", true, false, "Zombies beyond this distance are drawn as impostors")
local cvLight = CreateClientConVar("hz_impostor_light", "1", true, false, "Brightness of impostors against the real models")
local cvFog = CreateClientConVar("hz_impostor_fog", "1", true, false, "Fade impostors into the map's fog")
local cvDebug = CreateClientConVar("hz_impostor_debug", "0", false, false, "Show the impostor atlas and count on screen")

local ATLAS = 1024
local CELL_W, CELL_H = 32, 64
local DU, DV = CELL_W / ATLAS, CELL_H / ATLAS
local INSET = 0.5 / ATLAS                     -- half a texel in from the cell edge: no bleed from the neighbour
-- the slice of world one cell shows, relative to the zombie's feet
local HALF_W, Z_LO, Z_HI = 24, -8, 88
local MAX_QUADS = 6000
local REBUILD = 0.25

-- which variant rows are which
local V_RUN_M, V_RUN_F, V_SHAMBLE, V_IDLE_M, V_IDLE_F = { 0, 1, 2 }, { 3, 4 }, 5, 6, 7
local VARIANTS = {
	{ female = false, seqs = { "Run_01", "Run_02" }, move = true },
	{ female = false, seqs = { "Run_03", "Run_01" }, move = true },
	{ female = false, seqs = { "Run_05", "Run_02" }, move = true },
	{ female = true, seqs = { "Run_01", "Run_02" }, move = true },
	{ female = true, seqs = { "Run_03", "Run_01" }, move = true },
	{ female = false, seqs = { "Romero_Run_02", "Shamble_01", "Walk_Neutral_01" }, move = true },
	{ female = false, seqs = { "Idle_Neutral_01", "Idle_Neutral_02" } },
	{ female = true, seqs = { "Idle_Neutral_01", "Idle_Neutral_02" } },
}
local rates = {}               -- variant index (0 based) -> flipbook cycles per second

local rt = GetRenderTargetEx("hz_impostor_atlas", ATLAS, ATLAS, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, 0, 0,
	IMAGE_FORMAT_RGBA8888)
local mat = Material("hordez/impostor")
local dbgMat = CreateMaterial("hz_impostor_dbg", "UnlitGeneric", { ["$basetexture"] = rt:GetName(), ["$translucent"] = 1 })

local ready = false
local bakeAt                   -- next variant to bake (1 based), nil = not baking
local bakeModels

---------------------------------------------------------------- baking the atlas
local ACCESSORY = { beanie = true, beanies = true, glasses = true }
local function standIn(v)
	local pool = {}
	for _, m in ipairs(HZ.Models) do
		local f = m:find("female", 1, true) ~= nil
		if f == v.female and not m:find("_b.mdl", 1, true) then pool[#pool + 1] = m end
	end
	local csm = ClientsideModel(HZ.Pick(pool) or HZ.Models[1], RENDERGROUP_OPAQUE)
	if not IsValid(csm) then return end
	csm:SetNoDraw(true)
	local skins = csm:SkinCount()
	if skins and skins > 1 then csm:SetSkin(math.random(0, skins - 1)) end
	for i = 1, csm:GetNumBodyGroups() - 1 do
		local n = csm:GetBodygroupCount(i)
		if n > 1 then
			-- (hats and glasses stay rare, as on the real ones)
			local rare = ACCESSORY[string.lower(csm:GetBodygroupName(i) or "")]
			csm:SetBodygroup(i, (rare and math.random() > 0.2) and 0 or math.random(0, n - 1))
		end
	end
	local seq = -1
	for _, name in ipairs(v.seqs) do
		seq = csm:LookupSequence(name)
		if seq and seq >= 0 then break end
	end
	if not seq or seq < 0 then seq = 0 end
	csm:ResetSequence(seq)
	csm:SetPlaybackRate(0)
	if v.move then
		csm:SetPoseParameter("move_x", 1)
		csm:SetPoseParameter("move_y", 0)
	end
	csm:SetLOD(1)
	local dur = csm:SequenceDuration(seq)
	return csm, 1 / math.max(dur and dur > 0 and dur or 1, 0.2)
end

local function startBake()
	ready, bakeAt = false, 1
	for _, m in ipairs(bakeModels or {}) do if IsValid(m) then m:Remove() end end
	bakeModels = {}
end

-- one variant: 8 poses, each drawn from 8 sides into its cells
local camView = { type = "3D", ortho = { left = -HALF_W, right = HALF_W, top = -(Z_HI - Z_LO) / 2, bottom = (Z_HI - Z_LO) / 2 },
	znear = 1, zfar = 600, w = CELL_W, h = CELL_H }
local function bakeVariant(i)
	local v = VARIANTS[i]
	local csm, rate = standIn(v)
	if not csm then return end
	bakeModels[#bakeModels + 1] = csm
	rates[i - 1] = rate
	-- stand it where a zombie is (a spot inside the world), not at the camera - which can be anywhere in noclip
	local at = EyePos()
	for _, e in ipairs(HZ.ClientZombies) do
		if IsValid(e) and not e:IsDormant() then at = e:GetPos() break end
	end
	local _, row = next(HZ.VirtualCl)
	if row and at == EyePos() then at = Vector(HZ.VirtualAt(row, CurTime())) end
	local center = at + Vector(0, 0, (Z_LO + Z_HI) / 2)
	csm:SetPos(at)
	csm:SetAngles(angle_zero)

	render.PushRenderTarget(rt)
	if i == 1 then render.Clear(0, 0, 0, 0, true, true) end
	render.SuppressEngineLighting(true)
	render.SetLocalModelLights({})
	-- even light with a little shape to it; the real light at each zombie is multiplied in when it is drawn
	render.ResetModelLighting(0.78, 0.78, 0.78)
	render.SetModelLighting(BOX_TOP, 1, 1, 1)
	render.SetModelLighting(BOX_BOTTOM, 0.45, 0.45, 0.45)
	render.SetColorModulation(1, 1, 1)
	render.SetBlend(1)
	render.OverrideAlphaWriteEnable(true, true)
	render.SetWriteDepthToDestAlpha(false)
	for frame = 0, 7 do
		csm:SetCycle(frame / 8)
		csm:InvalidateBoneCache()
		csm:SetupBones()
		for k = 0, 7 do
			local a = math.rad(k * 45)
			camView.origin = center + Vector(math.cos(a), math.sin(a), 0) * 300
			camView.angles = Angle(0, k * 45 + 180, 0)
			camView.x = ((k % 4) * 8 + frame) * CELL_W
			camView.y = ((i - 1) * 2 + (k >= 4 and 1 or 0)) * CELL_H
			cam.Start(camView)
			render.FogMode(MATERIAL_FOG_NONE)
			csm:DrawModel()
			cam.End3D()
		end
	end
	render.OverrideAlphaWriteEnable(false)
	render.SuppressEngineLighting(false)
	render.PopRenderTarget()
end

hook.Add("PostRender", "hordez_impostor_bake", function()
	if not bakeAt then return end
	local ok, err = pcall(bakeVariant, bakeAt)
	if not ok then
		ErrorNoHalt("[hordez] impostor bake failed, impostors are off: " .. tostring(err) .. "\n")
		bakeAt = nil
		return
	end
	bakeAt = bakeAt + 1
	if bakeAt > #VARIANTS then
		bakeAt = nil
		for _, m in ipairs(bakeModels) do if IsValid(m) then m:Remove() end end
		bakeModels = {}
		mat:SetTexture("$basetexture", rt)
		ready = true
	end
end)

-- a changed resolution (or a lost device) empties render targets
hook.Add("OnScreenSizeChanged", "hordez_impostors", function() if ready or bakeAt then startBake() end end)
concommand.Add("hz_impostor_rebake", startBake)

---------------------------------------------------------------- the quads
local imesh
local count = 0
local builtAt, nextBuild = 0, 0
-- one far zombie = 15 numbers, gathered first so that nothing but plain mesh calls happens inside mesh.Begin
local q = {}
local STRIDE = 15

local atan2, floor, cos, sin, min, max = math.atan2, math.floor, math.cos, math.sin, math.min, math.max
local PI = math.pi
local lightAt = Vector()

-- per-rebuild state shared by the two kinds of far zombie (set at the top of gather)
local ex, ey, bright, fogOn, fs, fe = 0, 0, 127.5, false, 0, 1

-- one quad. c: where this zombie's light is remembered (the entity, or the virtual row)
local function emit(n, c, now, x, y, z, vx, vy, moving, facing, idx, female, shambler, dist)
	-- its stand-in: by sex and by what it is doing, the same one every time for this zombie
	local variant
	if not moving then
		variant = female and V_IDLE_F or V_IDLE_M
	elseif shambler then
		variant = V_SHAMBLE
	elseif female then
		variant = V_RUN_F[idx % 2 + 1]
	else
		variant = V_RUN_M[idx % 3 + 1]
	end
	-- seen from which of the 8 sides: the direction to the camera against the way it faces
	local bearing = atan2(ey - y, ex - x)
	local k = floor((bearing - facing) / (PI / 4) + 0.5) % 8
	-- light where it stands, looked up again every couple of seconds
	if not c.hz_ilt or now > c.hz_ilt then
		c.hz_ilt = now + 2 + (idx % 16) / 16
		lightAt:SetUnpacked(x, y, z + 40)
		local l = render.GetLightColor(lightAt)
		local lr, lg, lb = l.x, l.y, l.z
		-- (no light at all = the sample point is inside something: don't draw a black cut-out for that)
		if lr + lg + lb < 0.03 then lr, lg, lb = 0.35, 0.35, 0.35 end
		c.hz_ilr, c.hz_ilg, c.hz_ilb = lr, lg, lb
	end
	local fog = 0
	if fogOn and fe > fs then fog = min(max((dist - fs) / (fe - fs), 0), 1) end

	local o = n * STRIDE
	q[o + 1], q[o + 2], q[o + 3] = x, y, z
	q[o + 4], q[o + 5] = -sin(bearing) * HALF_W, cos(bearing) * HALF_W          -- the quad's "right"
	q[o + 6] = ((k % 4) * 8) * DU                                               -- strip u, v
	q[o + 7] = (variant * 2 + (k >= 4 and 1 or 0)) * DV
	q[o + 8], q[o + 9] = vx, vy
	q[o + 10] = (idx * 0.618034) % 1                                            -- animation phase
	q[o + 11] = rates[variant] or 1
	q[o + 12] = min(c.hz_ilr * bright, 255)
	q[o + 13] = min(c.hz_ilg * bright, 255)
	q[o + 14] = min(c.hz_ilb * bright, 255)
	q[o + 15] = fog * 255
end

local function gather(now)
	local list = HZ.ClientZombies
	local n = 0
	local want = cvOn:GetBool() and ready
	local dist = cvDist:GetFloat()
	local near2, far2 = (dist * 0.92) ^ 2, dist * dist      -- (a zombie on the line doesn't flicker between the two)
	local eye = EyePos()
	ex, ey = eye.x, eye.y
	local ez = eye.z
	bright = cvLight:GetFloat() * 127.5
	-- fog: linear fog is baked into each quad (how much) and the material (which colour)
	fogOn = cvFog:GetBool() and render.GetFogMode() == MATERIAL_FOG_LINEAR
	if fogOn then
		fs, fe = render.GetFogDistances()
		-- (a map without real fog can still report linear fog with no usable range)
		if not fs or not fe or fs < 0 or fe - fs < 64 then fogOn = false end
	end
	if fogOn then
		local r, g, b = render.GetFogColor()
		mat:SetFloat("$c0_x", (r / 255) ^ 2.2)
		mat:SetFloat("$c0_y", (g / 255) ^ 2.2)
		mat:SetFloat("$c0_z", (b / 255) ^ 2.2)
	end
	-- real zombies far enough away
	for i = 1, #list do
		local e = list[i]
		if IsValid(e) then
			local d2 = e.hz_d2
			local imp = want and d2 and not e.hz_ragdolled and not e:IsDormant() and d2 > (e.hz_imp and near2 or far2) and n < MAX_QUADS
			if not imp then
				if e.hz_imp then e.hz_imp, e.hz_ipt = nil, nil end
			else
				e.hz_imp = true
				local p = e:GetPos()
				local x, y, z = p.x, p.y, p.z
				-- velocity from where it was at the last rebuild
				local vx, vy = 0, 0
				local lt = e.hz_ipt
				if lt and now > lt and now - lt < 1 then
					local k = 1 / (now - lt)
					vx, vy = (x - e.hz_ipx) * k, (y - e.hz_ipy) * k
				end
				e.hz_ipx, e.hz_ipy, e.hz_ipt = x, y, now
				local moving = vx * vx + vy * vy > 400
				local female = e.hz_ifem
				if female == nil then
					female = (e:GetModel() or ""):find("female", 1, true) ~= nil
					e.hz_ifem = female
				end
				emit(n, e, now, x, y, z, vx, vy, moving, moving and atan2(vy, vx) or e:GetAngles().y * (PI / 180),
					e:EntIndex(), female, e:GetNW2Bool("hz_shambler"), d2 ^ 0.5)
				n = n + 1
			end
		end
	end
	-- virtual zombies: always impostors, there is no model to draw instead
	if ready then
		local at = HZ.VirtualAt
		for id, r in pairs(HZ.VirtualCl) do
			if n >= MAX_QUADS then break end
			local x, y, z = at(r, now)
			local moving = now < r.t1
			local dx, dy, dz = x - ex, y - ey, z - ez
			emit(n, r, now, x, y, z, moving and r.vx or 0, moving and r.vy or 0, moving, r.yaw, id, r.female, r.shambler,
				(dx * dx + dy * dy + dz * dz) ^ 0.5)
			n = n + 1
		end
	end
	return n
end

local Position, TexCoord, Color, AdvanceVertex = mesh.Position, mesh.TexCoord, mesh.Color, mesh.AdvanceVertex
local function fill(n)
	for i = 0, n - 1 do
		local o = i * STRIDE
		local x, y, z, rx, ry = q[o + 1], q[o + 2], q[o + 3], q[o + 4], q[o + 5]
		local u0, v0 = q[o + 6] + INSET, q[o + 7] + INSET
		local u1, v1 = q[o + 6] + DU - INSET, q[o + 7] + DV - INSET
		local vx, vy, ph, rate = q[o + 8], q[o + 9], q[o + 10], q[o + 11]
		local r, g, b, a = q[o + 12], q[o + 13], q[o + 14], q[o + 15]
		-- top left, top right, bottom right, bottom left
		Position(x - rx, y - ry, z + Z_HI) TexCoord(0, u0, v0) TexCoord(1, vx, vy) TexCoord(2, ph, rate) Color(r, g, b, a) AdvanceVertex()
		Position(x + rx, y + ry, z + Z_HI) TexCoord(0, u1, v0) TexCoord(1, vx, vy) TexCoord(2, ph, rate) Color(r, g, b, a) AdvanceVertex()
		Position(x + rx, y + ry, z + Z_LO) TexCoord(0, u1, v1) TexCoord(1, vx, vy) TexCoord(2, ph, rate) Color(r, g, b, a) AdvanceVertex()
		Position(x - rx, y - ry, z + Z_LO) TexCoord(0, u0, v1) TexCoord(1, vx, vy) TexCoord(2, ph, rate) Color(r, g, b, a) AdvanceVertex()
	end
end

local function rebuild(now)
	local ok, n = pcall(gather, now)
	if not ok then
		ErrorNoHalt("[hordez] impostor rebuild failed: " .. tostring(n) .. "\n")
		n = 0
	end
	if imesh then
		imesh:Destroy()
		imesh = nil
	end
	count = n
	if n == 0 then return end
	imesh = Mesh(mat)
	mesh.Begin(imesh, MATERIAL_QUADS, n)
	local ok2, err = pcall(fill, n)      -- (an error left inside mesh.Begin takes the game down)
	mesh.End()
	if not ok2 then
		ErrorNoHalt("[hordez] impostor mesh failed: " .. tostring(err) .. "\n")
		imesh:Destroy()
		imesh, count = nil, 0
	end
	builtAt = now
end

-- screenspace_general has no vertex shader constants of its own: the two numbers the shader needs ride in on
-- the ambient light cube, which the engine only uploads when a model is drawn - hence the invisible one.
local carrier
local function shaderClock(since, clock)
	if not IsValid(carrier) then
		carrier = ClientsideModel("models/props_junk/popcan01a.mdl")
		if not IsValid(carrier) then return end
		carrier:SetNoDraw(true)
		carrier:SetModelScale(0)
	end
	render.SuppressEngineLighting(true)
	render.SetModelLighting(0, since, clock, 0)
	carrier:DrawModel()
	render.SuppressEngineLighting(false)
end

hook.Add("PostDrawOpaqueRenderables", "hordez_impostors", function(depth, sky, sky3d)
	if depth or sky or sky3d then return end
	local now = CurTime()
	if now >= nextBuild then
		nextBuild = now + REBUILD
		-- first use: bake the atlas (it needs zombies to exist, so the models are loaded)
		if not ready and not bakeAt and ((cvOn:GetBool() and #HZ.ClientZombies > 0) or next(HZ.VirtualCl)) then startBake() end
		rebuild(now)
	end
	if not imesh then return end
	shaderClock(now - builtAt, now % 4096)
	render.SetMaterial(mat)
	render.OverrideDepthEnable(true, true)       -- (screenspace_general otherwise ignores the depth buffer)
	imesh:Draw()
	render.OverrideDepthEnable(false, false)
end)

hook.Add("HUDPaint", "hordez_impostor_debug", function()
	if not cvDebug:GetBool() then return end
	surface.SetDrawColor(40, 40, 40, 255)
	surface.DrawRect(16, 16, 512, 512)
	surface.SetDrawColor(255, 255, 255, 255)
	surface.SetMaterial(dbgMat)
	surface.DrawTexturedRect(16, 16, 512, 512)
	draw.SimpleText(("impostors: %d (%d virtual)   atlas: %s"):format(count, table.Count(HZ.VirtualCl), ready and "ready" or (bakeAt and "baking" or "not baked")),
		"DermaDefault", 20, 532, color_white)
end)

hook.Add("PostCleanupMap", "hordez_impostors", function()
	if imesh then imesh:Destroy() end
	imesh, count = nil, 0
end)
