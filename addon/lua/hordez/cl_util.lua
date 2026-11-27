HZ.Math = HZ.Math or {}
local M = HZ.Math

local sqrt, sin, acos = math.sqrt, math.sin, math.acos
local IsValid = IsValid

local ENTITY = FindMetaTable("Entity")
local copyBoneMatrix, getBoneMatrix = ENTITY.CopyBoneMatrix, ENTITY.GetBoneMatrix
local MATRIX = FindMetaTable("VMatrix")
local unpack, setUnpacked, getField, setField = MATRIX.Unpack, MATRIX.SetUnpacked, MATRIX.GetField, MATRIX.SetField

local CopyBone
if copyBoneMatrix then
    function CopyBone(ent, bone, out)
        if copyBoneMatrix(ent, bone, out) == false then return end

        return out
    end
else
    function CopyBone(ent, bone, out)
        local mat = getBoneMatrix(ent, bone)
        if not mat then return end

        out:Set(mat)

        return out
    end
end

M.CopyBone = CopyBone

function M.CopyBoneSafe(ent, bone, out)
    if not bone or bone < 0 or bone >= ent:GetBoneCount() then return end

    setField(out, 4, 4, 0)
    if not CopyBone(ent, bone, out) or getField(out, 4, 4) ~= 1 then return end

    return out
end

function M.MatrixPos(mat)
    local _, _, _, x, _, _, _, y, _, _, _, z = unpack(mat)
    return x, y, z
end

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

function M.MatrixPosQuat(mat)
    local a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12 = unpack(mat)
    local sx, sy, sz = sqrt(a1 * a1 + a5 * a5 + a9 * a9), sqrt(a2 * a2 + a6 * a6 + a10 * a10),
        sqrt(a3 * a3 + a7 * a7 + a11 * a11)

    if sx < 1e-6 or sy < 1e-6 or sz < 1e-6 then return end

    local ix, iy, iz = 1 / sx, 1 / sy, 1 / sz

    return a4, a8, a12, QuatFromBasis(a1 * ix, a2 * iy, a3 * iz, a5 * ix, a6 * iy, a7 * iz, a9 * ix, a10 * iy, a11 * iz)
end

function M.BlendFrom(mat, px, py, pz, qx, qy, qz, qw, w)
    local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12 = unpack(mat)
    local x, y, z = px + (b4 - px) * w, py + (b8 - py) * w, pz + (b12 - pz) * w
    local sx, sy, sz = sqrt(b1 * b1 + b5 * b5 + b9 * b9), sqrt(b2 * b2 + b6 * b6 + b10 * b10),
        sqrt(b3 * b3 + b7 * b7 + b11 * b11)

    if sx < 1e-6 or sy < 1e-6 or sz < 1e-6 then
        setUnpacked(mat, b1, b2, b3, x, b5, b6, b7, y, b9, b10, b11, z, 0, 0, 0, 1)
        return
    end

    local ix, iy, iz = 1 / sx, 1 / sy, 1 / sz
    local bx, by, bz,
        bw = QuatFromBasis(b1 * ix, b2 * iy, b3 * iz, b5 * ix, b6 * iy, b7 * iz, b9 * ix, b10 * iy, b11 * iz)

    local m00, m01, m02, m10, m11, m12, m20, m21, m22 = QuatToRotation(QuatSlerp(qx, qy, qz, qw, bx, by, bz, bw, w))
    setUnpacked(mat,
        m00 * sx, m01 * sy, m02 * sz, x,
        m10 * sx, m11 * sy, m12 * sz, y,
        m20 * sx, m21 * sy, m22 * sz, z,
        0, 0, 0, 1)
end

local list = HZ.ClientZombies or {}
HZ.ClientZombies = list

function HZ.ClientRegister(ent)
    if ent.hz_reg then return end

    ent.hz_reg = true
    list[#list + 1] = ent
end

timer.Create("hordez_client_list", 2, 0, function()
    local count = #list
    for i = count, 1, -1 do
        if not IsValid(list[i]) then
            list[i] = list[count]
            list[count] = nil
            count = count - 1
        end
    end

    for _, ent in ipairs(ents.FindByClass("hz_zombie")) do HZ.ClientRegister(ent) end
end)

function HZ.NearestZombies(eye, maxDistSqr, limit, out, outDist, alertedOnly)
    local span = 0
    if limit >= 1 then
        for i = 1, #list do
            local ent = list[i]
            if IsValid(ent) and not ent.hz_ragdolled and not ent:IsDormant() then
                local distSqr = ent:GetPos():DistToSqr(eye)
                if distSqr < maxDistSqr and (span < limit or distSqr < outDist[span])
                    and (not alertedOnly or ent:GetNW2Bool("hz_alerted")) then
                    if span < limit then span = span + 1 end
                    local j = span
                    while j > 1 and outDist[j - 1] > distSqr do
                        out[j], outDist[j] = out[j - 1], outDist[j - 1]
                        j = j - 1
                    end

                    out[j], outDist[j] = ent, distSqr
                end
            end
        end
    end

    for i = #out, span + 1, -1 do out[i], outDist[i] = nil, nil end

    return span
end

local cvLod = CreateClientConVar("hz_lod_dist", "500", true, false, "Simplified models from (0: engine decides)")

local cvShadow = CreateClientConVar("hz_shadow_dist", "1000", true, false, "Shadows within (-1: always, 0: never)")

local cvDraw = CreateClientConVar("hz_draw_dist", "0", true, false, "Draw distance (0: no limit)")

local cvCrowd = CreateClientConVar("hz_crowd_lod", "1", true, false, "Simplify buried zombies in crowds")

local cvCrowdHide = CreateClientConVar("hz_crowd_hide", "0", true, false, "Hide zombies behind this many rows (0: never)")

local cvOcclude = CreateClientConVar("hz_occlusion", "1", true, false, "Skip zombies behind walls")

function HZ.SyncNoDraw(ent)
    local hide = ent.hz_ragdolled or ent.hz_far or (ent.hz_imp and (ent.hz_fade or 1) >= 1) or false
    if ent.hz_nodraw ~= hide then
        ent.hz_nodraw = hide
        ent:SetNoDraw(hide)
    end
end

local REF_TAN = math.tan(math.rad(75 / 2))
local OCCLUDE_FROM = 300 * 300
local OCCLUDE_PASSES = 2
local LOOK_AHEAD = 0.3
local occludeOut = {}
local occludeEnd = Vector()
local occludeIn = { mask = CONTENTS_SOLID, output = occludeOut, endpos = occludeEnd }
local band = bit.band
local TRANS_SURF = bit.bor(SURF_TRANS or 0, SURF_NODRAW or 0, SURF_SKY or 0)
local TRANS_CONT = bit.bor(CONTENTS_WINDOW or 0, CONTENTS_GRATE or 0)

local function Blocked(from, tx, ty, tz)
    occludeIn.start = from
    occludeEnd:SetUnpacked(tx, ty, tz)
    util.TraceLine(occludeIn)

    return occludeOut.Hit and occludeOut.HitWorld and not occludeOut.HitSky
        and band(occludeOut.SurfaceFlags or 0, TRANS_SURF) == 0
        and band(occludeOut.Contents or 0, TRANS_CONT) == 0
end

local function Hidden(ent, px, py, pz, eye, eyeAhead)
    if not Blocked(eye, px, py, pz + 64) or not Blocked(eye, px, py, pz + 36)
        or not Blocked(eye, px, py, pz + 8) then return false end

    local vel = ent:GetVelocity()
    local ax, ay, az = px + vel.x * LOOK_AHEAD, py + vel.y * LOOK_AHEAD, pz + vel.z * LOOK_AHEAD

    return Blocked(eyeAhead, ax, ay, az + 64) and Blocked(eyeAhead, ax, ay, az + 36)
        and Blocked(eyeAhead, ax, ay, az + 8)
end

local pass = 0

local CELLS = 720
local CELL_RAD = 2 * math.pi / CELLS
local cover = {}
for i = 0, CELLS - 1 do cover[i] = 0 end
local order, orderDist = {}, {}
local atan2, atan, floor, ceil, sqrt, min = math.atan2, math.atan, math.floor, math.ceil, math.sqrt, math.min

local function IsNearer(a, b)
    return orderDist[a] < orderDist[b]
end

local ccEnts, ccPts = {}, {}

local function CrowdCover(ex, ey, ez, aimX, aimY)
    if HZ.NativeOn and HZ.NativeOn() and HZ.NativeLib and HZ.NativeLib.ClientCover then
        local count = 0
        for i = 1, #list do
            local ent = list[i]
            if IsValid(ent) and not ent.hz_ragdolled and not ent.hz_imp and not ent:IsDormant() then
                local pos = ent:GetPos()
                count = count + 1
                ccEnts[count] = ent
                local at = count * 3
                ccPts[at - 2], ccPts[at - 1], ccPts[at] = pos.x, pos.y, pos.z
            end
        end

        for i = #ccEnts, count + 1, -1 do ccEnts[i] = nil end
        for i = #ccPts, count * 3 + 1, -1 do ccPts[i] = nil end
        if count == 0 then return end

        local covers = HZ.NativeLib.ClientCover(ccPts, ex, ey, ez, aimX, aimY)
        for i = 1, count do
            local ent = ccEnts[i]
            local covered = covers[i]
            if not covered or covered < 0 then
                ent.hz_cover = 0
            else
                ent.hz_cover = (ent.hz_cover or covered) * 0.5 + covered * 0.5
            end
        end

        return
    end

    for i = 0, CELLS - 1 do cover[i] = 0 end
    local count = 0
    for i = 1, #list do
        local ent = list[i]
        if IsValid(ent) and not ent.hz_ragdolled and not ent.hz_imp and not ent:IsDormant() then
            local pos = ent:GetPos()
            local dx, dy = pos.x - ex, pos.y - ey
            local distSqr = dx * dx + dy * dy
            if distSqr < 64 * 64 or dx * aimX + dy * aimY >= -32 then
                count = count + 1
                order[count] = ent
                ent.hz_cx, ent.hz_cy, ent.hz_cz = dx, dy, pos.z + 36 - ez
                orderDist[ent] = distSqr
            else
                ent.hz_cover = 0
            end
        end
    end

    for i = #order, count + 1, -1 do order[i] = nil end
    table.sort(order, IsNearer)
    for i = 1, count do
        local ent = order[i]
        local dx, dy = ent.hz_cx, ent.hz_cy
        local dist = sqrt(orderDist[ent])
        local covered = 0
        if dist > 1 then
            local mid = floor((atan2(dy, dx) + math.pi) / CELL_RAD)
            local half = min(ceil(atan(14 / dist) / CELL_RAD), 60)
            local steep = ent.hz_cz > dist * 0.4 or ent.hz_cz < -dist * 0.4
            if not steep then
                local sum = 0
                for cell = mid - half, mid + half do sum = sum + cover[cell % CELLS] end
                covered = sum / (half * 2 + 1)
            end

            for cell = mid - half, mid + half do
                local j = cell % CELLS
                cover[j] = cover[j] + 1
            end
        end

        ent.hz_cover = (ent.hz_cover or covered) * 0.5 + covered * 0.5
        orderDist[ent] = nil
    end
end

local nextZoomSample, sampleFrame = 0, -1
local bestFov, bestOrigin, bestDir = 180, nil, nil
local sentZoom, lastZoomAt, lastZoomQFov = false, 0, 0
local lastZoomPos, lastZoomDir = Vector(), Vector()

hook.Add("PreDrawOpaqueRenderables", "hordez_scope_zoom", function(depth, sky, sky3d)
    if depth or sky or sky3d then return end

    local frame = FrameNumber()
    if frame ~= sampleFrame then
        local now = CurTime()
        if now < nextZoomSample then return end

        nextZoomSample = now + 0.2
        sampleFrame = frame
        bestFov, bestOrigin, bestDir = 180, nil, nil
    end

    local view = render.GetViewSetup()
    local fov = view and view.fov
    if fov and fov > 1 and fov < bestFov then
        bestFov = fov
        bestOrigin = view.origin
        bestDir = view.angles:Forward()
    end
end)

timer.Create("hordez_scope_zoom", 0.2, 0, function()
    if bestFov < 65 and bestOrigin and bestDir then
        HZ.ScopeFov = bestFov
        local now = CurTime()
        local qFov = math.Clamp(floor(bestFov * 3 + 0.5), 1, 255)
        local changed = not sentZoom or qFov ~= lastZoomQFov
            or bestOrigin:DistToSqr(lastZoomPos) > 16
            or bestDir:Dot(lastZoomDir) < 0.9995
        if changed or now - lastZoomAt >= 0.6 then
            sentZoom, lastZoomAt, lastZoomQFov = true, now, qFov
            lastZoomPos:Set(bestOrigin)
            lastZoomDir:Set(bestDir)
            net.Start("hz_zoom", true)
            net.WriteUInt(qFov, 8)
            net.WriteVector(bestOrigin)
            net.WriteNormal(bestDir)
            net.SendToServer()
        end
    elseif sentZoom then
        HZ.ScopeFov = nil
        sentZoom = false
        net.Start("hz_zoom", true)
        net.WriteUInt(0, 8)
        net.SendToServer()
    else
        HZ.ScopeFov = nil
    end
end)

local occEnts, occPts = {}, {}
local SHADOW_SKIP = bit.bor(EF_NOSHADOW, EF_NORECEIVESHADOW)
local camPos, camAim, camFrame = Vector(), Vector(1, 0, 0), -10
hook.Add("PreDrawOpaqueRenderables", "hordez_cam", function(depth, sky, sky3d)
    if depth or sky or sky3d then return end

    local view = render.GetViewSetup()
    if not view or view.w ~= ScrW() or view.h ~= ScrH() then return end

    camPos:Set(view.origin)
    camAim:Set(view.angles:Forward())
    camFrame = FrameNumber()
end)

timer.Create("hordez_detail", 0.25, 0, function()
    local count = #list
    if count == 0 then return end

    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local t0 = HZ.ProfOn and SysTime()
    local freshCam = FrameNumber() - camFrame <= 5
    local eye = freshCam and camPos or ply:EyePos()
    local ex, ey, ez = eye.x, eye.y, eye.z
    local aim = freshCam and camAim or ply:GetAimVector()
    local aimX, aimY, aimZ = aim.x, aim.y, aim.z
    local occlude = cvOcclude:GetBool()
    local eyeAhead = eye + ply:GetVelocity() * LOOK_AHEAD
    local fov = math.min(ply:GetFOV(), HZ.ScopeFov or 180)
    local zoom = math.tan(math.rad(math.Clamp(fov, 5, 150) / 2)) / REF_TAN
    zoom = zoom * zoom
    local lod = cvLod:GetFloat()
    local lodSqr1, lodSqr2, lodSqr3 = lod * lod, lod * lod * 4, lod * lod * 16
    local secondDist, drawDist = cvShadow:GetFloat(), cvDraw:GetFloat()
    local shadowDistSqr, drawDistSqr = secondDist * secondDist, drawDist * drawDist
    local crowd = cvCrowd:GetBool()
    local hide = cvCrowdHide:GetFloat()
    if crowd or hide > 0 then CrowdCover(ex, ey, ez, aimX, aimY) end
    local bsp = occlude and HZ.GetMapBsp and HZ.GetMapBsp() or nil
    local occCount = 0
    pass = pass + 1
    for i = 1, count do
        local ent = list[i]
        if IsValid(ent) and not ent.hz_ragdolled then
            if ent:IsDormant() then
                ent.hz_lod, ent.hz_shadow, ent.hz_d2, ent.hz_cover, ent.hz_ik = nil, nil, nil, nil, nil
                ent.hz_dormant = true
            else
                local pos = ent:GetPos()
                local px, py, pz = pos.x, pos.y, pos.z
                local dx, dy, dz = px - ex, py - ey, pz - ez
                local rawDistSqr = dx * dx + dy * dy + dz * dz
                local distSqr = rawDistSqr * zoom
                ent.hz_d2 = distSqr
                local refresh = (i + pass) % 8 == 0
                local covered = (crowd or hide > 0) and distSqr > 150 * 150 and ent.hz_cover or 0
                local want = -1
                if lod > 0 then
                    want = distSqr < lodSqr1 and 0 or (distSqr < lodSqr2 and 1 or (distSqr < lodSqr3 and 2 or 3))
                    if crowd then
                        want = min(3, want + (covered >= 5 and 3
                            or (covered >= 3 and 2 or (covered >= 1.5 and 1 or 0))))
                    end
                end

                if refresh or ent.hz_lod ~= want then
                    ent.hz_lod = want
                    ent:SetLOD(want)
                    if IsValid(ent.hz_overlay) then ent.hz_overlay:SetLOD(want) end
                end

                local wantIk = want <= 0 and covered < 1.5 and not ent.hz_imp
                if refresh or ent.hz_ik ~= wantIk then
                    ent.hz_ik = wantIk
                    ent:SetIK(wantIk)
                end

                local shadow = (secondDist < 0 or distSqr < shadowDistSqr) and not ent.hz_imp
                    and not (crowd and covered >= 2)

                if refresh or ent.hz_shadow ~= shadow then
                    ent.hz_shadow = shadow
                    ent:DrawShadow(shadow)
                    if shadow then
                        ent:RemoveEffects(SHADOW_SKIP)
                        ent:CreateShadow()
                    else
                        ent:AddEffects(SHADOW_SKIP)
                        ent:DestroyShadow()
                    end
                end

                local hidden = false
                if occlude and not ent.hz_imp and rawDistSqr > OCCLUDE_FROM
                    and dx * aimX + dy * aimY + (dz + 36) * aimZ > -64 then
                    if bsp then
                        occCount = occCount + 1
                        occEnts[occCount] = ent
                        local vel = ent:GetVelocity()
                        local at = (occCount - 1) * 6
                        occPts[at + 1], occPts[at + 2], occPts[at + 3] = px, py, pz
                        occPts[at + 4], occPts[at + 5], occPts[at + 6] = vel.x, vel.y, vel.z
                        hidden = (ent.hz_occ or 0) >= OCCLUDE_PASSES
                    else
                        ent.hz_occ = Hidden(ent, px, py, pz, eye, eyeAhead) and (ent.hz_occ or 0) + 1 or 0
                        hidden = ent.hz_occ >= OCCLUDE_PASSES
                    end
                else
                    ent.hz_occ = 0
                end

                local baseFar = (drawDist > 0 and distSqr > drawDistSqr) or (hide > 0 and covered >= hide)
                ent.hz_baseFar = baseFar or nil
                ent.hz_far = (baseFar or hidden) or nil

                HZ.SyncNoDraw(ent)
            end
        end
    end

    if bsp and occCount > 0 then
        for i = #occEnts, occCount + 1, -1 do occEnts[i] = nil end
        for i = #occPts, occCount * 6 + 1, -1 do occPts[i] = nil end
        local res = HZ.NativeLib.BspOccludedBatch(bsp, ex, ey, ez, eyeAhead.x, eyeAhead.y, eyeAhead.z, occPts)
        for i = 1, occCount do
            local ent = occEnts[i]
            ent.hz_occ = res[i] and (ent.hz_occ or 0) + 1 or 0
            local hidden = ent.hz_occ >= OCCLUDE_PASSES
            local far = (ent.hz_baseFar or hidden) or nil
            if ent.hz_far ~= far then
                ent.hz_far = far
                HZ.SyncNoDraw(ent)
            end
        end
    end

    if t0 then HZ.ProfAdd("cl_detail", SysTime() - t0) end
end)
