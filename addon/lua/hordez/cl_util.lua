-- Client helpers shared by the death animations, faces and footsteps:
--  * HZ.Math: bone reads into a caller-owned matrix (Entity:CopyBoneMatrix, no VMatrix / Vector / Angle made
--    per read) and a quaternion bone blend, all on plain numbers
--  * the client zombie list (no ents.FindByClass sweeps) and a nearest-k pick that makes no garbage
HZ.Math = HZ.Math or {}
local M = HZ.Math

local sqrt, sin, acos = math.sqrt, math.sin, math.acos
local IsValid = IsValid

---------------------------------------------------------------- bones
local ENTITY = FindMetaTable("Entity")
local copyBoneMatrix, getBoneMatrix = ENTITY.CopyBoneMatrix, ENTITY.GetBoneMatrix
local MATRIX = FindMetaTable("VMatrix")
local unpack, setUnpacked, getField, setField = MATRIX.Unpack, MATRIX.SetUnpacked, MATRIX.GetField, MATRIX.SetField

-- Bone matrix of `bone` written into `out` (a Matrix() the caller keeps around). Returns out, or nil when
-- there is none. For bones known to be in range on an entity whose bones were just set up (SetupBones, or
-- inside a BuildBonePositions callback). Game builds without CopyBoneMatrix (before 2025.12) fall back to
-- GetBoneMatrix.
local CopyBone
if copyBoneMatrix then
	function CopyBone(ent, bone, out)
		if copyBoneMatrix(ent, bone, out) == false then return end
		return out
	end
else
	function CopyBone(ent, bone, out)
		local m = getBoneMatrix(ent, bone)
		if not m then return end
		out:Set(m)
		return out
	end
end
M.CopyBone = CopyBone

-- Same, for callers that can't vouch for the bone or the bone cache (an id that may be nil / out of range, a
-- body that may never have been drawn): nil unless the engine really wrote a bone into `out`.
function M.CopyBoneSafe(ent, bone, out)
	if not bone or bone < 0 or bone >= ent:GetBoneCount() then return end
	setField(out, 4, 4, 0)
	if not CopyBone(ent, bone, out) or getField(out, 4, 4) ~= 1 then return end
	return out
end

-- translation of a matrix as three numbers
function M.MatrixPos(mat)
	local _, _, _, x, _, _, _, y, _, _, _, z = unpack(mat)
	return x, y, z
end

---------------------------------------------------------------- quaternions
--[[
    The quaternion routines below (from-basis, slerp, to-rotation) come from SandSwep's math library, which
    carries this notice:

    Copyright © 2026 Stephen Leitnick
    Copyright (c) 2023 tukars

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
    documentation files (the "Software"), to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of
    the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
    THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
]]
local QUAT_EPSILON = 1e-5

-- unit quaternion of a pure rotation given row by row
local function QuatFromBasis(m00, m01, m02, m10, m11, m12, m20, m21, m22)
	local trace = m00 + m11 + m22
	if trace > 0 then
		local s = sqrt(trace + 1) * 2
		local inv = 1 / s
		return (m21 - m12) * inv, (m02 - m20) * inv, (m10 - m01) * inv, 0.25 * s
	elseif m00 > m11 and m00 > m22 then
		local s = sqrt(1 + m00 - m11 - m22) * 2
		local inv = 1 / s
		return 0.25 * s, (m01 + m10) * inv, (m02 + m20) * inv, (m21 - m12) * inv
	elseif m11 > m22 then
		local s = sqrt(1 + m11 - m00 - m22) * 2
		local inv = 1 / s
		return (m01 + m10) * inv, 0.25 * s, (m12 + m21) * inv, (m02 - m20) * inv
	end
	local s = sqrt(1 + m22 - m00 - m11) * 2
	local inv = 1 / s
	return (m02 + m20) * inv, (m12 + m21) * inv, 0.25 * s, (m10 - m01) * inv
end

local function QuatSlerp(ax, ay, az, aw, bx, by, bz, bw, t)
	local cosOmega = ax * bx + ay * by + az * bz + aw * bw
	local flip = cosOmega < 0
	if flip then cosOmega = -cosOmega end
	local s1, s2
	if cosOmega > 1 - QUAT_EPSILON then
		s1, s2 = 1 - t, t
	else
		local omega = acos(cosOmega)
		local invSin = 1 / sin(omega)
		s1, s2 = sin((1 - t) * omega) * invSin, sin(t * omega) * invSin
	end
	if flip then s2 = -s2 end
	return s1 * ax + s2 * bx, s1 * ay + s2 * by, s1 * az + s2 * bz, s1 * aw + s2 * bw
end

local function QuatToRotation(x, y, z, w)
	local x2, y2, z2 = x * 2, y * 2, z * 2
	local xx, yy, zz = x * x2, y * y2, z * z2
	local xy, xz, yz = x * y2, x * z2, y * z2
	local wx, wy, wz = w * x2, w * y2, w * z2
	return 1 - (yy + zz), xy - wz, xz + wy,
		xy + wz, 1 - (xx + zz), yz - wx,
		xz - wy, yz + wx, 1 - (xx + yy)
end
M.QuatFromBasis, M.QuatSlerp, M.QuatToRotation = QuatFromBasis, QuatSlerp, QuatToRotation

-- A bone matrix as position + rotation quaternion (seven numbers; scale is dropped). nil for a collapsed
-- (zero-scale) bone.
function M.MatrixPosQuat(mat)
	local a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12 = unpack(mat)
	local sx, sy, sz = sqrt(a1 * a1 + a5 * a5 + a9 * a9), sqrt(a2 * a2 + a6 * a6 + a10 * a10), sqrt(a3 * a3 + a7 * a7 + a11 * a11)
	if sx < 1e-6 or sy < 1e-6 or sz < 1e-6 then return end
	local ix, iy, iz = 1 / sx, 1 / sy, 1 / sz
	return a4, a8, a12, QuatFromBasis(a1 * ix, a2 * iy, a3 * iz, a5 * ix, a6 * iy, a7 * iz, a9 * ix, a10 * iy, a11 * iz)
end

-- Blend a bone matrix in place: w = 0 gives the stored pose (position px,py,pz + quaternion), w = 1 leaves
-- `mat` as it is. Position is lerped, rotation slerped (shortest way round, no gimbal trouble - an Euler
-- LerpAngle swings bones the long way when pitch passes +-90), the matrix keeps its own scale.
function M.BlendFrom(mat, px, py, pz, qx, qy, qz, qw, w)
	local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12 = unpack(mat)
	local x, y, z = px + (b4 - px) * w, py + (b8 - py) * w, pz + (b12 - pz) * w
	local sx, sy, sz = sqrt(b1 * b1 + b5 * b5 + b9 * b9), sqrt(b2 * b2 + b6 * b6 + b10 * b10), sqrt(b3 * b3 + b7 * b7 + b11 * b11)
	if sx < 1e-6 or sy < 1e-6 or sz < 1e-6 then   -- collapsed bone: nothing to rotate
		setUnpacked(mat, b1, b2, b3, x, b5, b6, b7, y, b9, b10, b11, z, 0, 0, 0, 1)
		return
	end
	local ix, iy, iz = 1 / sx, 1 / sy, 1 / sz
	local bx, by, bz, bw = QuatFromBasis(b1 * ix, b2 * iy, b3 * iz, b5 * ix, b6 * iy, b7 * iz, b9 * ix, b10 * iy, b11 * iz)
	local m00, m01, m02, m10, m11, m12, m20, m21, m22 = QuatToRotation(QuatSlerp(qx, qy, qz, qw, bx, by, bz, bw, w))
	setUnpacked(mat,
		m00 * sx, m01 * sy, m02 * sz, x,
		m10 * sx, m11 * sy, m12 * sz, y,
		m20 * sx, m21 * sy, m22 * sz, z,
		0, 0, 0, 1)
end

---------------------------------------------------------------- client zombie list
-- Every live hz_zombie this client knows (ENT:Initialize adds them). Faces and footsteps pick from it a few
-- times a second instead of sweeping every entity with ents.FindByClass.
local list = HZ.ClientZombies or {}
HZ.ClientZombies = list

function HZ.ClientRegister(ent)
	if ent.hz_reg then return end
	ent.hz_reg = true
	list[#list + 1] = ent
end

-- drops the removed ones, and catches anything ENT:Initialize did not (a Lua refresh, a full update)
timer.Create("hordez_client_list", 2, 0, function()
	local n = #list
	for i = n, 1, -1 do
		if not IsValid(list[i]) then
			list[i] = list[n]
			list[n] = nil
			n = n - 1
		end
	end
	for _, e in ipairs(ents.FindByClass("hz_zombie")) do HZ.ClientRegister(e) end
end)

-- The k live zombies nearest to eye within sqrt(maxD2), nearest first, written into out[1..n] (their squared
-- distances into outD); returns n. alertedOnly: only the ones the server marked as chasing.
function HZ.NearestZombies(eye, maxD2, k, out, outD, alertedOnly)
	local n = 0
	if k >= 1 then
		for i = 1, #list do
			local e = list[i]
			if IsValid(e) and not e.hz_ragdolled and not e:IsDormant() then
				local d = e:GetPos():DistToSqr(eye)
				if d < maxD2 and (n < k or d < outD[n]) and (not alertedOnly or e:GetNW2Bool("hz_alerted")) then
					if n < k then n = n + 1 end
					local j = n
					while j > 1 and outD[j - 1] > d do
						out[j], outD[j] = out[j - 1], outD[j - 1]
						j = j - 1
					end
					out[j], outD[j] = e, d
				end
			end
		end
	end
	for i = #out, n + 1, -1 do out[i], outD[i] = nil, nil end
	return n
end

---------------------------------------------------------------- distance detail
-- Four times a second every live zombie gets its level of detail for where the camera is now:
--  * model LOD (the bodies carry three reduced meshes: about 1/2, 1/4 and 1/10 of the triangles, no facial
--    flexes, finger and helper bones folded away), forced by plain distance so it can be tuned from a convar
--  * a shadow only when near (every shadow is another render of the body)
--  * optionally not drawn at all beyond a distance
-- Distances are corrected for zoom: looking down a scope brings the detail back.
local cvLod = CreateClientConVar("hz_lod_dist", "500", true, false,
	"Zombies switch to the first reduced model at this distance, the next at 2x and the last at 4x. 0 = let the engine choose")
local cvShadow = CreateClientConVar("hz_shadow_dist", "1000", true, false,
	"Zombies closer than this cast a shadow. 0 = none, -1 = all of them")
local cvDraw = CreateClientConVar("hz_draw_dist", "0", true, false, "Zombies beyond this distance are not drawn. 0 = no limit")

local cvCrowd = CreateClientConVar("hz_crowd_lod", "1", true, false,
	"Zombies buried behind others in a dense crowd drop to reduced models and lose their shadow")
local cvCrowdHide = CreateClientConVar("hz_crowd_hide", "0", true, false,
	"Zombies with at least this many rows of others in front of them are not drawn at all. 0 = always draw")

local REF_TAN = math.tan(math.rad(75 / 2))
local pass = 0

-- Crowd cover: how many zombies stand between the camera and each one. A dense group is mostly its front
-- rows; the ones behind show a head over a shoulder at best, so they can run on far less detail than their
-- distance alone would give them.
-- The measure is a one-dimensional occlusion buffer: the horizon around the camera cut into half-degree
-- cells. Zombies are taken nearest first; each reads how many nearer bodies already cover the cells its own
-- width spans (its cover), then adds itself to them. Seen from well above or below a crowd hides nothing, so
-- those get no cover.
local CELLS = 720
local CELL_RAD = 2 * math.pi / CELLS
local cover = {}
for i = 0, CELLS - 1 do cover[i] = 0 end
local order, ordD = {}, {}
local atan2, atan, floor, ceil, sqrt, min = math.atan2, math.atan, math.floor, math.ceil, math.sqrt, math.min
local function nearer(a, b) return ordD[a] < ordD[b] end

local function crowdCover(eye)
	for i = 0, CELLS - 1 do cover[i] = 0 end
	local m = 0
	for i = 1, #list do
		local e = list[i]
		if IsValid(e) and not e.hz_ragdolled and not e:IsDormant() then
			m = m + 1
			order[m] = e
			local p = e:GetPos()
			e.hz_cx, e.hz_cy, e.hz_cz = p.x - eye.x, p.y - eye.y, p.z + 36 - eye.z
			ordD[e] = e.hz_cx * e.hz_cx + e.hz_cy * e.hz_cy
		end
	end
	for i = #order, m + 1, -1 do order[i] = nil end
	table.sort(order, nearer)
	for i = 1, m do
		local e = order[i]
		local dx, dy = e.hz_cx, e.hz_cy
		local d = sqrt(ordD[e])
		local c = 0
		if d > 1 then
			local mid = floor((atan2(dy, dx) + math.pi) / CELL_RAD)
			local half = min(ceil(atan(14 / d) / CELL_RAD), 60)
			local steep = e.hz_cz > d * 0.4 or e.hz_cz < -d * 0.4
			if not steep then
				local sum = 0
				for k = mid - half, mid + half do sum = sum + cover[k % CELLS] end
				c = sum / (half * 2 + 1)
			end
			for k = mid - half, mid + half do
				local j = k % CELLS
				cover[j] = cover[j] + 1
			end
		end
		-- eased, so one body stepping aside doesn't flip a zombie between models
		e.hz_cover = (e.hz_cover or c) * 0.5 + c * 0.5
		ordD[e] = nil
	end
end

timer.Create("hordez_detail", 0.25, 0, function()
	local n = #list
	if n == 0 then return end
	local ply = LocalPlayer()
	if not IsValid(ply) then return end
	local eye = EyePos()
	-- squared distance scale for the current field of view (1 at fov 75)
	local zoom = math.tan(math.rad(math.Clamp(ply:GetFOV(), 5, 150) / 2)) / REF_TAN
	zoom = zoom * zoom
	local lod = cvLod:GetFloat()
	local l1, l2, l3 = lod * lod, lod * lod * 4, lod * lod * 16
	local sd, dd = cvShadow:GetFloat(), cvDraw:GetFloat()
	local sd2, dd2 = sd * sd, dd * dd
	local crowd = cvCrowd:GetBool()
	local hide = cvCrowdHide:GetFloat()
	if crowd or hide > 0 then crowdCover(eye) end
	-- every couple of seconds everything is applied again whether it changed or not: a zombie coming back into
	-- view (or a full update) resets what the client had set on it
	pass = pass + 1
	local refresh = pass % 8 == 0
	for i = 1, n do
		local e = list[i]
		if IsValid(e) and not e.hz_ragdolled then
			if e:IsDormant() then
				e.hz_lod, e.hz_shadow, e.hz_d2, e.hz_cover = nil, nil, nil, nil
			else
				local d = e:GetPos():DistToSqr(eye) * zoom
				e.hz_d2 = d   -- (cl_impostor decides from this who is drawn as an impostor)
				-- rows of bodies in front of it (never counted for the ones right at the camera)
				local c = (crowd or hide > 0) and d > 150 * 150 and e.hz_cover or 0
				local want = -1
				if lod > 0 then
					want = d < l1 and 0 or (d < l2 and 1 or (d < l3 and 2 or 3))
					if crowd then
						-- behind 1-2 others: one model down; behind 3-4: two; deeper: the lowest
						want = min(3, want + (c >= 5 and 3 or (c >= 3 and 2 or (c >= 1.5 and 1 or 0))))
					end
				end
				if refresh or e.hz_lod ~= want then
					e.hz_lod = want
					e:SetLOD(want)
				end
				local shadow = (sd < 0 or d < sd2) and not e.hz_imp and not (crowd and c >= 2)
				if refresh or e.hz_shadow ~= shadow then
					e.hz_shadow = shadow
					e:DrawShadow(shadow)
					if shadow then e:CreateShadow() else e:DestroyShadow() end
				end
				e.hz_far = ((dd > 0 and d > dd2) or (hide > 0 and c >= hide)) or nil
			end
		end
	end
end)
