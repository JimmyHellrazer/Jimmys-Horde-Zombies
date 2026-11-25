util.AddNetworkString("hz_rag")
util.AddNetworkString("hz_cue")
util.AddNetworkString("hz_shot")

HZ.Zombies = HZ.Zombies or {}
HZ.Count = 0
HZ.Stress = 0

function HZ.Register(zombie)
    if HZ.Zombies[zombie] then return end

    HZ.Zombies[zombie] = true
    HZ.Count = HZ.Count + 1
    zombie:SetNW2String("tif_faction", "hl2_monster")
    HZ.RelateZombie(zombie)
end

function HZ.Unregister(zombie)
    if not HZ.Zombies[zombie] then return end

    HZ.Zombies[zombie] = nil
    HZ.Count = HZ.Count - 1
    HZ.GridRemove(zombie)
end

function HZ.CanSpawn()
    local cap = HZ.CV.max:GetInt()
    return cap <= 0 or HZ.Count + (HZ.VCount or 0) < cap
end

local needFlow, needFlowAt = false, 0

function HZ.NeedFlow()
    if HZ.DirectorActive or (HZ.VCount or 0) > 0 then return true end

    local now = CurTime()
    if now < (HZ.FlowWantedUntil or 0) then return true end

    if now < needFlowAt then return needFlow end

    needFlowAt = now + 0.25
    needFlow = false
    for zombie in pairs(HZ.Zombies) do
        if zombie.hz_alerted then
            needFlow = true
            break
        end
    end

    return needFlow
end

local CELL = 64
local grid = {}
local floor, sqrt, random = math.floor, math.sqrt, math.random
local IsValid = IsValid

local function CellKey(x, y)
    return floor(x / CELL) * 4096 + floor(y / CELL)
end

function HZ.GridMove(zombie, pos)
    local px, py, pz = pos.x, pos.y, pos.z
    zombie.hz_gx, zombie.hz_gy, zombie.hz_gz = px, py, pz
    local cellKey = CellKey(px, py)
    if zombie.hz_cell == cellKey then return end

    HZ.GridRemove(zombie)
    local cell = grid[cellKey]
    if not cell then
        cell = {}
        grid[cellKey] = cell
    end

    cell[zombie] = true
    zombie.hz_cell = cellKey
end

function HZ.GridRemove(zombie)
    local cellKey = zombie.hz_cell
    if not cellKey then return end

    local cell = grid[cellKey]
    if cell then
        cell[zombie] = nil
        if next(cell) == nil then grid[cellKey] = nil end
    end

    zombie.hz_cell = nil
end

function HZ.Near(pos, radius, callback, skip)
    local px, py, pz = pos.x, pos.y, pos.z
    local cx, cy = floor(px / CELL), floor(py / CELL)
    local span = math.ceil(radius / CELL)
    local radiusSqr = radius * radius
    for x = cx - span, cx + span do
        for y = cy - span, cy + span do
            local cell = grid[x * 4096 + y]
            if cell then
                for other in pairs(cell) do
                    if other ~= skip and IsValid(other) then
                        local ox, oy, oz = other.hz_gx, other.hz_gy, other.hz_gz
                        if not ox then
                            local otherPos = other:GetPos()
                            ox, oy, oz = otherPos.x, otherPos.y, otherPos.z
                        end

                        local dx, dy, dz = ox - px, oy - py, oz - pz
                        local distSqr = dx * dx + dy * dy + dz * dz
                        if distSqr <= radiusSqr then callback(other, distSqr) end
                    end
                end
            end
        end
    end
end

local SEP_NEAR, SEP_LOOK = 12, 40
local SEP_DX = { 0, -1, 1, 0, 0, -1, -1, 1, 1 }
local SEP_DY = { 0, 0, 0, -1, 1, -1, 1, -1, 1 }

function HZ.Separation(zombie, pos)
    local x, y, posZ = pos.x, pos.y, pos.z
    local cx, cy = floor(x / CELL), floor(y / CELL)
    local px, py, count = 0, 0, 0
    local looked = 0
    for slot = 1, 9 do
        if count >= SEP_NEAR or looked >= SEP_LOOK then break end

        local gx, gy = cx + SEP_DX[slot], cy + SEP_DY[slot]
        do
            local cell = grid[gx * 4096 + gy]
            if cell then
                for other in pairs(cell) do
                    if count >= SEP_NEAR or looked >= SEP_LOOK then break end

                    if other ~= zombie and IsValid(other) then
                        looked = looked + 1
                        local ox, oy, oz = other.hz_gx, other.hz_gy, other.hz_gz
                        if not ox then
                            local otherPos = other:GetPos()
                            ox, oy, oz = otherPos.x, otherPos.y, otherPos.z
                        end

                        local dx, dy, dz = x - ox, y - oy, posZ - oz
                        local distSqr = dx * dx + dy * dy + dz * dz
                        if distSqr <= 1600 then
                            if distSqr < 1 then
                                px, py = px + random() * 2 - 1, py + random() * 2 - 1
                            else
                                local dist = sqrt(distSqr)
                                local push = (40 - dist) / (40 * dist)
                                px, py = px + dx * push, py + dy * push
                            end

                            count = count + 1
                        end
                    end
                end
            end
        end
    end

    if count == 0 then return nil end

    return Vector(px * 40, py * 40, 0)
end

local targets, nextTargets = {}, 0
HZ.NPCTargets = HZ.NPCTargets or {}

HZ.FriendlyNPC = {
    npc_zombie = true, npc_zombie_torso = true, npc_fastzombie = true, npc_fastzombie_torso = true,
    npc_poisonzombie = true, npc_zombine = true, npc_headcrab = true, npc_headcrab_fast = true,
    npc_headcrab_black = true, npc_headcrab_poison = true,
}

local function RelateNPC(npc, zombie)
    if not (IsValid(npc) and IsValid(zombie) and npc:IsNPC()) then return end

    if HZ.FriendlyNPC[npc:GetClass()] then
        npc:AddEntityRelationship(zombie, D_LI, 0)
    elseif HZ.CV.npc_hostile:GetBool() then
        npc:AddEntityRelationship(zombie, D_HT, 0)
    end
end

function HZ.RelateZombie(zombie)
    for ent in pairs(HZ.NPCTargets) do RelateNPC(ent, zombie) end
    for ent in pairs(HZ.FriendlyAllies or {}) do RelateNPC(ent, zombie) end
end

HZ.FriendlyAllies = HZ.FriendlyAllies or {}
hook.Add("OnEntityCreated", "hordez_targets", function(ent)
    timer.Simple(0, function()
        if not IsValid(ent) or ent:GetClass() == "hz_zombie" or ent:GetClass() == "npc_bullseye" then return end
        if not (ent:IsNPC() or ent:IsNextBot()) then return end

        if HZ.FriendlyNPC[ent:GetClass()] then
            HZ.FriendlyAllies[ent] = true
        else
            HZ.NPCTargets[ent] = true
        end

        if ent:IsNPC() then
            for zombie in pairs(HZ.Zombies) do RelateNPC(ent, zombie) end
        end
    end)
end)

local ENGAGE_R = 2000
timer.Create("hordez_npc_engage", 1, 0, function()
    if not HZ.CV.npc_hostile:GetBool() or HZ.Count == 0 or HZ.AIDisabled() then return end

    for ent in pairs(HZ.NPCTargets) do
        if IsValid(ent) and ent:IsNPC() and ent:Health() > 0 and not HZ.FriendlyNPC[ent:GetClass()] then
            local cur = ent:GetEnemy()
            if not (IsValid(cur) and cur:Health() > 0) then
                local eye = ent:EyePos()
                local best, bestDist
                for zombie in pairs(HZ.Zombies) do
                    if IsValid(zombie) and not zombie.hz_dead then
                        local distSqr = zombie:GetPos():DistToSqr(eye)
                        if distSqr < ENGAGE_R * ENGAGE_R and (not bestDist or distSqr < bestDist)
                            and ent:Disposition(zombie) == D_HT then
                            local tr = util.TraceLine({ start = eye, endpos = zombie:WorldSpaceCenter(),
                                mask = MASK_BLOCKLOS,
                                filter = { ent, zombie } })

                            if not tr.Hit then best, bestDist = zombie, distSqr end
                        end
                    end
                end

                if best then
                    ent:UpdateEnemyMemory(best, best:GetPos())
                    ent:SetEnemy(best)
                end
            end
        end
    end
end)

cvars.AddChangeCallback("hz_npc_hostile", function(_, _, new)
    local hostile = tobool(new)
    for ent in pairs(HZ.NPCTargets) do
        if IsValid(ent) and ent:IsNPC() then
            for zombie in pairs(HZ.Zombies) do
                if IsValid(zombie) then ent:AddEntityRelationship(zombie, hostile and D_HT or D_NU, 0) end
            end
        end
    end
end, "hordez")

hook.Add("EntityRemoved", "hordez_targets", function(ent)
    HZ.NPCTargets[ent] = nil
    HZ.FriendlyAllies[ent] = nil
end)

HZ.Lures = {}

local patCache = {}

local function Patterns(convar)
    local str = convar:GetString()
    local cache = patCache[convar]
    if cache and cache.str == str then return cache.list end

    local list = {}
    for pattern in str:lower():gmatch("[^,%s]+") do list[#list + 1] = pattern end
    patCache[convar] = { str = str, list = list }

    return list
end

local NOT_LURES = { prop_physics = true, prop_physics_multiplayer = true, prop_dynamic = true, prop_ragdoll = true }

local function LureKind(ent)
    if not IsValid(ent) or ent:IsWeapon() or ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then return nil end

    local hooked = hook.Run("HZ_LureKind", ent)
    if hooked ~= nil then return hooked or nil end

    local class = ent:GetClass():lower()
    if NOT_LURES[class] or class:sub(1, 7) == "weapon_" then return nil end

    local model = (ent:GetModel() or ""):lower()
    for _, pattern in ipairs(Patterns(HZ.CV.lure_cls)) do
        if class:find(pattern, 1, true) or model:find(pattern, 1, true) then return "pipe" end
    end

    for _, pattern in ipairs(Patterns(HZ.CV.bile_cls)) do
        if class:find(pattern, 1, true) or model:find(pattern, 1, true) then return "bile" end
    end
end

function HZ.AddLure(src, radius, seconds)
    local lure = { radius = radius or HZ.CV.lure_radius:GetFloat(), untilT = seconds and CurTime() + seconds or nil }
    if isvector(src) then
        lure.pos = src
    else
        lure.ent, lure.pos = src, src:GetPos()
    end

    HZ.Lures[#HZ.Lures + 1] = lure

    return lure
end

hook.Add("OnEntityCreated", "hordez_lures", function(ent)
    timer.Simple(0, function()
        local kind = IsValid(ent) and LureKind(ent)
        if kind == "pipe" then
            HZ.AddLure(ent)
        elseif kind == "bile" then
            ent.hz_bile = true
        end
    end)
end)

hook.Add("EntityRemoved", "hordez_lures", function(ent)
    if ent.hz_bile and HZ.CV.lures:GetBool() then
        HZ.AddLure(ent:GetPos(), nil, HZ.CV.bile_time:GetFloat())
    end
end)

function HZ.LureFor(pos)
    if #HZ.Lures == 0 or not HZ.CV.lures:GetBool() then return nil end

    local best, bestDist
    for _, lure in ipairs(HZ.Lures) do
        local distSqr = lure.pos:DistToSqr(pos)
        if distSqr < lure.radius * lure.radius and (not bestDist or distSqr < bestDist) then
            best, bestDist = lure, distSqr
        end
    end

    return best
end

timer.Create("hordez_lures", 0.25, 0, function()
    local now = CurTime()
    for i = #HZ.Lures, 1, -1 do
        local lure = HZ.Lures[i]
        local alive
        if lure.ent then
            alive = IsValid(lure.ent)
            if alive then lure.pos = lure.ent:GetPos() end
        else
            alive = now < (lure.untilT or 0)
        end

        if alive and lure.untilT and now >= lure.untilT then alive = false end
        if not alive then
            table.remove(HZ.Lures, i)
        elseif HZ.CV.lures:GetBool() and now >= (lure.nextNoise or 0) then
            lure.nextNoise = now + 1
            HZ.Noise(lure.pos, lure.radius, IsValid(lure.ent) and lure.ent or nil)
        end
    end
end)

hook.Add("PostCleanupMap", "hordez_lures", function() HZ.Lures = {} end)

local ignorePlayers = GetConVar("ai_ignoreplayers")
local aiDisabled = GetConVar("ai_disabled")

function HZ.AIDisabled()
    return aiDisabled ~= nil and aiDisabled:GetBool()
end

function HZ.IgnoringPlayers()
    return ignorePlayers ~= nil and ignorePlayers:GetBool()
end

function HZ.GetTargets()
    if CurTime() < nextTargets then return targets end

    nextTargets = CurTime() + 0.25
    targets = {}
    if not HZ.IgnoringPlayers() then
        for _, ply in ipairs(player.GetAll()) do
            if ply:Alive() and not ply:IsFlagSet(FL_NOTARGET) and ply:GetMoveType() ~= MOVETYPE_NOCLIP
                and not HZ.KnockedOut(ply) then
                targets[#targets + 1] = { ent = ply, pos = ply:GetPos(), ply = true }
            end
        end
    end

    if HZ.CV.target_npcs:GetBool() then
        for ent in pairs(HZ.NPCTargets) do
            if IsValid(ent) and ent:Health() > 0 and not ent:IsFlagSet(FL_NOTARGET) then
                targets[#targets + 1] = { ent = ent, pos = ent:GetPos() }
            end
        end
    end

    return targets
end

function HZ.NearestPlayerDist(pos)
    local best = math.huge
    for _, list in ipairs(HZ.GetTargets()) do
        if list.ply then
            local distSqr = list.pos:DistToSqr(pos)
            if distSqr < best then best = distSqr end
        end
    end

    return math.sqrt(best)
end

function HZ.KnockedOut(ply)
    if not HZ.CV.ignore_out:GetBool() then return false end

    return hook.Run("HZ_KnockedOut", ply) == true
end

function HZ.IsHostile(ent)
    if not IsValid(ent) or ent:GetClass() == "hz_zombie" then return false end
    if ent:IsPlayer() then
        return ent:Alive() and not HZ.IgnoringPlayers() and not ent:IsFlagSet(FL_NOTARGET) and not HZ.KnockedOut(ent)
    end

    return (ent:IsNPC() or ent:IsNextBot()) and ent:Health() > 0 and ent:GetClass() ~= "npc_bullseye"
end

function HZ.Noise(pos, radius, source)
    if HZ.AIDisabled() then return end
    if IsValid(source) and source:IsPlayer() and HZ.IgnoringPlayers() then return end

    local radiusSqr = radius * radius
    for zombie in pairs(HZ.Zombies) do
        if not zombie.hz_alerted and not zombie.hz_wakeAt then
            local distSqr = zombie:GetPos():DistToSqr(pos)
            if distSqr < radiusSqr then zombie:HZ_Hear(pos, math.sqrt(distSqr), source) end
        end
    end
end

function HZ.Spread(zombie)
    local pos = zombie:GetPos()
    HZ.Near(pos, HZ.CV.spread:GetFloat(), function(other)
        if not other.hz_alerted and not other.hz_wakeAt then
            other:HZ_Hear(pos, pos:Distance(other:GetPos()), zombie)
        end
    end, zombie)
end

hook.Add("EntityFireBullets", "hordez_hear", function(ent)
    if not IsValid(ent) or ent:GetClass() == "hz_zombie" then return end

    local now = CurTime()
    if (ent.hz_lastNoise or 0) > now then return end

    ent.hz_lastNoise = now + 0.3
    HZ.Noise(ent:GetPos(), HZ.CV.hear_gun:GetFloat(), ent)
end)

function HZ.BulletSpread(spread)
    if isnumber(spread) then return spread end
    if isvector(spread) then return math.max(spread.x, spread.y) end

    return 0
end

HZ.LastDeath = HZ.LastDeath or -1000
hook.Add("EntityFireBullets", "hordez_corpses", function(ent, data)
    if CurTime() - HZ.LastDeath > 30 or not IsValid(ent) or ent:GetClass() == "hz_zombie" then return end
    if not isvector(data.Src) or not isvector(data.Dir) then return end

    local count = math.Clamp(tonumber(data.Num) or 1, 1, 32)
    net.Start("hz_shot", true)
    net.WriteVector(data.Src)
    net.WriteNormal(data.Dir:GetNormalized())
    net.WriteUInt(count, 5)
    net.WriteFloat(HZ.BulletSpread(data.Spread))
    net.WriteUInt(math.Clamp(math.floor(tonumber(data.Damage) or 10), 0, 1023), 10)
    net.SendPVS(data.Src)
end)

hook.Add("EntityTakeDamage", "hordez_hear", function(target, dmg)
    if dmg:IsExplosionDamage() then
        local now = CurTime()
        if (HZ.lastBlast or 0) < now then
            HZ.lastBlast = now + 0.2
            HZ.Noise(dmg:GetDamagePosition(), HZ.CV.hear_blast:GetFloat(), dmg:GetAttacker())
        end
    end

    if target:IsPlayer() then
        local attacker = dmg:GetAttacker()
        if IsValid(attacker) and attacker:GetClass() == "hz_zombie" then HZ.Stress = HZ.Stress + dmg:GetDamage() end
    end
end)

local BULLETISH = bit.bor(DMG_BULLET, DMG_BUCKSHOT, DMG_BURN, DMG_SLOWBURN, DMG_POISON, DMG_NERVEGAS,
    DMG_RADIATION, DMG_DROWN, DMG_SHOCK, DMG_ENERGYBEAM, DMG_DISSOLVE)

HZ.MELEE_REACH = 130

function HZ.MeleeAttacker(victim, dmg)
    local attacker = dmg:GetAttacker()
    if not IsValid(attacker) or attacker == victim or attacker:GetClass() == "hz_zombie" then return end
    if dmg:IsExplosionDamage() or dmg:IsDamageType(bit.bor(DMG_CRUSH, DMG_VEHICLE)) then return end
    if (victim:GetPos() - attacker:GetPos()):Length2DSqr() >= HZ.MELEE_REACH * HZ.MELEE_REACH then return end
    if dmg:IsDamageType(bit.bor(DMG_CLUB, DMG_SLASH)) then return attacker end

    local dmgType = dmg:GetDamageType()
    if dmgType ~= DMG_GENERIC and not dmg:IsDamageType(BULLETISH) then return attacker end

    local inflictor = dmg:GetInflictor()
    if dmgType == DMG_GENERIC and IsValid(inflictor) and inflictor:IsWeapon()
        and dmg:GetDamageForce():LengthSqr() > 1 then
        return attacker
    end
end

function HZ.ShoverOf(zombie)
    local pos = zombie:GetPos()
    local best, bestDist
    for _, ply in ipairs(player.GetAll()) do
        if ply:Alive() then
            local offset = pos - ply:GetPos()
            local distSqr = offset:Length2DSqr()
            if distSqr < 150 * 150 then
                offset.z = 0
                local aim = ply:GetAimVector()
                aim.z = 0
                if offset:LengthSqr() > 1 and aim:LengthSqr() > 0.01
                    and offset:GetNormalized():Dot(aim:GetNormalized()) > 0.4
                    and (not bestDist or distSqr < bestDist) then
                    best, bestDist = ply, distSqr
                end
            end
        end
    end

    return best
end

HZ.ArcBusy = false

function HZ.MeleeArc(attacker, first, dmg)
    if not HZ.CV.arc:GetBool() or not IsValid(attacker) then return end

    local now = CurTime()
    if (attacker.hz_arcUntil or 0) > now then return end

    attacker.hz_arcUntil = now + 0.25
    local aim = attacker:IsPlayer() and attacker:GetAimVector() or attacker:GetForward()
    aim = Vector(aim.x, aim.y, 0)
    if aim:LengthSqr() < 0.01 then return end

    aim:Normalize()
    local base = attacker:GetPos()
    local eye = attacker.GetShootPos and attacker:GetShootPos() or attacker:WorldSpaceCenter()
    local range = HZ.CV.arc_range:GetFloat()
    local cosA = math.cos(math.rad(HZ.CV.arc_angle:GetFloat()))
    local scale = dmg and HZ.CV.arc_damage:GetFloat() or 0
    local amount, dtype, inflictor, force = 0, DMG_CLUB, attacker, 0
    if dmg then
        amount, dtype, force = dmg:GetDamage() * scale, dmg:GetDamageType(), dmg:GetDamageForce():Length()
        if IsValid(dmg:GetInflictor()) then inflictor = dmg:GetInflictor() end
    end

    local hit = {}
    HZ.Near(base, range + 64, function(zombie)
        if not zombie.hz_dead then
            local zombiePos = zombie:GetPos()
            local offset = Vector(zombiePos.x - base.x, zombiePos.y - base.y, 0)
            local len = offset:Length()
            if len > 1 and len <= range and math.abs(zombiePos.z - base.z) < 64 and offset:Dot(aim) / len >= cosA then
                local tr = util.TraceLine({ start = eye, endpos = zombie:WorldSpaceCenter(),
                    mask = MASK_SOLID_BRUSHONLY })

                if not tr.Hit then hit[#hit + 1] = { zombie, offset } end
            end
        end
    end, first)

    if #hit == 0 then return end

    timer.Simple(0, function()
        if not IsValid(attacker) then return end

        HZ.ArcBusy = true
        local ok, err = pcall(function()
            local inf = IsValid(inflictor) and inflictor or attacker
            for _, entry in ipairs(hit) do
                local zombie, offset = entry[1], entry[2]
                if IsValid(zombie) and not zombie.hz_dead then
                    if amount > 0 then
                        local dmgInfo = DamageInfo()
                        dmgInfo:SetDamage(amount)
                        dmgInfo:SetDamageType(dtype)
                        dmgInfo:SetAttacker(attacker)
                        dmgInfo:SetInflictor(inf)
                        dmgInfo:SetDamagePosition(zombie:WorldSpaceCenter())
                        dmgInfo:SetDamageForce(offset:GetNormalized() * force)
                        zombie:TakeDamageInfo(dmgInfo)
                    end

                    if IsValid(zombie) and not zombie.hz_dead then zombie:HZ_ExternalPush(offset, true) end
                end
            end
        end)

        HZ.ArcBusy = false
        if not ok then ErrorNoHalt("[hordez] melee arc error: " .. tostring(err) .. "\n") end
    end)

    if HZ.CV.debug:GetBool() then
        print(("[hordez] melee arc from %s: %d more infected"):format(tostring(attacker), #hit))
    end
end

hook.Add("EntityTakeDamage", "hordez_arc", function(target, dmg)
    if HZ.ArcBusy or not HZ.Zombies[target] then return end

    local attacker = HZ.MeleeAttacker(target, dmg)
    if attacker then HZ.MeleeArc(attacker, target, dmg) end
end)

timer.Create("hordez_stress", 1, 0, function() HZ.Stress = math.max(0, HZ.Stress * 0.93 - 1) end)

HZ.Snd = {}

local function ListSnd(dir, sexed)
    local function ListSounds(death)
        local out = {}
        for _, fileName in ipairs(file.Find("sound/" .. death .. "/*.wav", "GAME")) do
            if not fileName:lower():find("ceda", 1, true) then out[#out + 1] = death .. "/" .. fileName end
        end

        return out
    end

    if not sexed then return ListSounds(dir) end

    local root = ListSounds(dir)
    local male, female = ListSounds(dir .. "/male"), ListSounds(dir .. "/female")
    for _, path in ipairs(root) do
        male[#male + 1] = path
        female[#female + 1] = path
    end

    return { male = male, female = female }
end

local base = "hordez/infected/"
HZ.Snd.rage = ListSnd(base .. "action/rage", true)
HZ.Snd.rageat = ListSnd(base .. "action/rageat", true)
HZ.Snd.alert = ListSnd(base .. "alert/alert", true)
HZ.Snd.becomealert = ListSnd(base .. "alert/becomealert", true)
HZ.Snd.enraged = ListSnd(base .. "alert/becomeenraged", true)
HZ.Snd.shot = ListSnd(base .. "action/been_shot", true)
HZ.Snd.die = ListSnd(base .. "action/die", true)
HZ.Snd.ignite = ListSnd(base .. "action/ignite", true)
HZ.Snd.shoved = ListSnd(base .. "action/shoved/mp")
HZ.Snd.hit = ListSnd(base .. "hit")
HZ.Snd.miss = ListSnd(base .. "miss")
HZ.Snd.idle = table.Add(table.Add(ListSnd(base .. "idle/moaning"), ListSnd(base .. "idle/mumbling")),
    ListSnd(base .. "idle/breathing"))

for _, sounds in pairs(HZ.Snd) do
    if sounds.male then
        HZ.PrecacheSounds(sounds.male)
        HZ.PrecacheSounds(sounds.female)
    else
        HZ.PrecacheSounds(sounds)
    end
end

local durCache = {}

local function SoundLen(path)
    local dur = durCache[path]
    if not dur then
        dur = SoundDuration(path)
        dur = (dur and dur > 0) and dur or 1
        durCache[path] = dur
    end

    return dur
end

local tokens, lastTok = 0, 0

function HZ.Voice(zombie, kind, level, force)
    local now = CurTime()
    local rate = HZ.CV.voices:GetFloat()
    tokens = math.min(rate, tokens + (now - lastTok) * rate)
    lastTok = now
    if not force and tokens < 1 then return end
    if (zombie.hz_voiceUntil or 0) > now and not force then return end

    if zombie.hz_shambler then
        kind = HZ.ShamblerVoice[kind]
        if not kind then return end
    end

    local sounds = HZ.Snd[kind]
    if not sounds then return end

    if sounds.male then sounds = zombie.hz_female and sounds.female or sounds.male end
    local path = HZ.Pick(sounds)
    if not path then return end

    tokens = tokens - 1
    zombie.hz_voiceUntil = now + (zombie.hz_shambler and 2.5 or 1.5)
    local pitch = zombie.hz_shambler and math.random(84, 94) or math.random(94, 106)
    zombie:EmitSound(path, level or 75, pitch, 1, CHAN_VOICE)
    zombie:SetNW2Float("hz_yell", now + math.Clamp(SoundLen(path) * 100 / pitch, 0.3, 4))
end

HZ.ShamblerVoice = { rage = "idle", rageat = "idle", alert = "idle", becomealert = "idle", enraged = nil,
    shot = "shot", die = "die", ignite = "ignite", shoved = "shoved", idle = "idle" }

function HZ.Sound(zombie, kind, level)
    local path = HZ.Pick(HZ.Snd[kind])
    if path then zombie:EmitSound(path, level or 70, math.random(95, 105), 1, CHAN_AUTO) end
end

local MODELS_M, MODELS_F, MODELS_FB = {}, {}, {}
for _, model in ipairs(HZ.Models) do
    local pool = MODELS_M
    if model:find("female", 1, true) then pool = model:find("_b.mdl", 1, true) and MODELS_FB or MODELS_F end
    pool[#pool + 1] = model
end

function HZ.RandomModel()
    local female = math.random() < HZ.FemaleChance
    local beanie = female and math.random() < HZ.CV.accessory:GetFloat()

    return HZ.Pick(female and (beanie and MODELS_FB or MODELS_F) or MODELS_M) or HZ.Models[1]
end

local ACCESSORY = { beanie = true, beanies = true, glasses = true, hands = true }
local bgCache = {}

local function BodygroupPlan(ent)
    local mdl = ent:GetModel()
    local plan = bgCache[mdl]
    if plan then return plan end

    plan = {}
    for _, group in ipairs(ent:GetBodyGroups() or {}) do
        if group.id ~= 0 and group.num > 1 then
            local entry = { id = group.id, num = group.num }
            if ACCESSORY[string.lower(group.name)] then
                local none = 0
                for i = 0, group.num - 1 do
                    if (group.submodels and group.submodels[i] or "") == "" then
                        none = i
                        break
                    end
                end

                local opts = {}
                for i = 0, group.num - 1 do
                    if i ~= none then opts[#opts + 1] = i end
                end

                entry.none, entry.opts = none, opts
            end

            plan[#plan + 1] = entry
        end
    end

    bgCache[mdl] = plan

    return plan
end

HZ.WarmBodygroups = BodygroupPlan

function HZ.RandomBodygroups(ent)
    local chance = HZ.CV.accessory:GetFloat()
    local plan = BodygroupPlan(ent)
    for i = 1, #plan do
        local group = plan[i]
        if group.opts then
            local pick = group.none
            if math.random() < chance then pick = HZ.Pick(group.opts) or pick end
            ent:SetBodygroup(group.id, pick)
        else
            ent:SetBodygroup(group.id, math.random(0, group.num - 1))
        end
    end
end

local FIT_MINS, FIT_MAXS = Vector(-13, -13, 0), Vector(13, 13, 72)
local notZombie = { "hz_zombie" }
local spotTr = {}
local floorStart, floorEnd = Vector(), Vector()
local floorIn = { start = floorStart, endpos = floorEnd, mask = MASK_NPCSOLID, filter = notZombie, output = spotTr }
local fitStart, fitEnd = Vector(), Vector()
local fitIn = { start = fitStart, endpos = fitEnd, mins = FIT_MINS, maxs = FIT_MAXS, mask = MASK_NPCSOLID,
    filter = notZombie, output = spotTr }
local losStart, losEnd = Vector(), Vector()
local losIn = { start = losStart, endpos = losEnd, mask = MASK_NPCSOLID_BRUSHONLY, output = spotTr }
local SPOT_RADII = { 24, 40, 60, 84, 112 }

local function FloorAt(px, py, pz)
    floorStart:SetUnpacked(px, py, pz + 24)
    floorEnd:SetUnpacked(px, py, pz - 64)
    util.TraceLine(floorIn)

    if spotTr.Hit and not spotTr.StartSolid and spotTr.HitNormal.z > 0.6 then
        local hp = spotTr.HitPos
        return hp.x, hp.y, hp.z + 1
    end
end

local function BodyFits(px, py, pz)
    fitStart:SetUnpacked(px, py, pz + 2)
    fitEnd:SetUnpacked(px, py, pz + 3)
    util.TraceHull(fitIn)

    return not spotTr.Hit and not spotTr.StartSolid
end

function HZ.FreeSpot(pos)
    local bx, by, bz = FloorAt(pos.x, pos.y, pos.z)
    if not bx then bx, by, bz = pos.x, pos.y, pos.z end
    if BodyFits(bx, by, bz) then return Vector(bx, by, bz) end

    for _, radius in ipairs(SPOT_RADII) do
        local off = math.Rand(0, math.pi * 2)
        for step = 0, 7 do
            local ang = off + step * (math.pi / 4)
            local fx, fy, fz = FloorAt(bx + math.cos(ang) * radius, by + math.sin(ang) * radius, bz)
            if fx and math.abs(fz - bz) < 40 and BodyFits(fx, fy, fz) then
                losStart:SetUnpacked(bx, by, bz + 36)
                losEnd:SetUnpacked(fx, fy, fz + 36)
                util.TraceLine(losIn)
                if not spotTr.Hit then return Vector(fx, fy, fz) end
            end
        end
    end

    return Vector(bx, by, bz)
end

function HZ.SpawnZombie(pos, yaw, opts)
    opts = opts or {}
    if not opts.force and not HZ.CanSpawn() then return nil end

    local t0 = HZ.ProfOn and SysTime()
    pos = HZ.FreeSpot(pos)
    local zombie = ents.Create("hz_zombie")
    if not IsValid(zombie) then return nil end

    zombie.hz_model = opts.model
    zombie.hz_idleType = opts.idle or "random"
    zombie.hz_startAlerted = opts.alerted
    zombie.hz_owner = opts.owner
    zombie.hz_placed = true
    if opts.shambler == nil then
        zombie.hz_shambler = math.random() < HZ.CV.sh_chance:GetFloat()
    else
        zombie.hz_shambler = opts.shambler and true or false
    end

    zombie:SetPos(pos)
    zombie:SetAngles(Angle(0, yaw or math.Rand(0, 360), 0))
    zombie:Spawn()
    zombie:Activate()
    if t0 then HZ.ProfAdd("sv_spawn", SysTime() - t0) end

    return zombie
end

function HZ.IsStraggler(zombie, now)
    local wait = HZ.CV.straggle:GetFloat()
    if wait <= 0 or not IsValid(zombie) or not zombie.hz_alerted or zombie.hz_dead or zombie.hz_climbing
        or zombie.hz_inOnce or not zombie.hz_progressAt or now - zombie.hz_progressAt < wait then
        return false
    end

    return not HZ.SeenByPlayers(zombie:GetPos(), 1000)
end

function HZ.SeenByPlayers(pos, near)
    near = near or 600
    local head = pos + Vector(0, 0, 56)
    for _, target in ipairs(HZ.GetTargets()) do
        if target.ply then
            local ply = target.ent
            local eye = ply:EyePos()
            local to = head - eye
            local dist = to:Length()
            if dist < near then return true end

            if to:GetNormalized():Dot(ply:GetAimVector()) > 0.25 then
                local tr = util.TraceLine({ start = eye, endpos = head, mask = MASK_OPAQUE, filter = ply })
                if not tr.Hit then return true end
            end
        end
    end

    return false
end

timer.Create("hordez_heading", 0.5, 0, function()
    for _, ply in ipairs(player.GetAll()) do
        local pos = ply:GetPos()
        local last = ply.hz_hdLast
        ply.hz_hdLast = pos
        if last then
            local moved = Vector(pos.x - last.x, pos.y - last.y, 0)
            if moved:LengthSqr() > 20 * 20 then
                moved:Normalize()
                local heading = ply.hz_heading
                heading = heading and (heading * 0.6 + moved * 0.4) or moved
                if heading:LengthSqr() > 0.01 then heading:Normalize() end
                ply.hz_heading = heading
            end
        end
    end
end)

local function HeadingOf(pos)
    if pos.hz_heading then return pos.hz_heading end

    local aim = pos:GetAimVector()
    aim.z = 0

    return aim:LengthSqr() > 0.01 and aim:GetNormalized() or nil
end

local function AheadScore(pos)
    local best, bestDist
    for _, target in ipairs(HZ.GetTargets()) do
        if target.ply then
            local distSqr = target.pos:DistToSqr(pos)
            if not bestDist or distSqr < bestDist then best, bestDist = target, distSqr end
        end
    end

    if not best then return 0 end

    local heading = HeadingOf(best.ent)
    if not heading then return 0 end

    local to = Vector(pos.x - best.pos.x, pos.y - best.pos.y, 0)
    if to:LengthSqr() < 1 then return 0 end

    return to:GetNormalized():Dot(heading)
end

function HZ.FindSpawnArea(minD, maxDistSqr, tries, ahead)
    local graph = HZ.Flow.graph
    if not graph then return nil end

    local ids = graph.ids
    tries = tries or 16
    local want = (ahead and ahead > 0) and 4 or 1
    local found = {}
    for _ = 1, tries * want do
        local id = ids[math.random(#ids)]
        local dist = HZ.Flow.dist[id]
        local area = graph.area[id]
        if dist and dist >= minD and dist <= maxDistSqr and IsValid(area) and not area:IsUnderwater()
            and area:GetSizeX() >= 24 and area:GetSizeY() >= 24 then
            local pos = area:GetRandomPoint()
            if not HZ.SeenByPlayers(pos, minD * 0.6) then
                found[#found + 1] = { area, pos }
                if #found >= want then break end
            end
        end
    end

    if #found == 0 then return nil end

    local pick = found[math.random(#found)]
    if want > 1 and math.random() < ahead then
        local bestScore
        for _, entry in ipairs(found) do
            local score = AheadScore(entry[2])
            if not bestScore or score > bestScore then pick, bestScore = entry, score end
        end
    end

    return pick[1], pick[2]
end

local WOOD = {
    hit = { "physics/wood/wood_box_impact_hard1.wav", "physics/wood/wood_box_impact_hard2.wav",
        "physics/wood/wood_box_impact_hard3.wav" },
    brk = { "physics/wood/wood_crate_break1.wav", "physics/wood/wood_crate_break2.wav",
        "physics/wood/wood_crate_break3.wav",
        "physics/wood/wood_furniture_break1.wav", "physics/wood/wood_furniture_break2.wav",
        "physics/wood/wood_plank_break1.wav",
        "physics/wood/wood_plank_break3.wav" },
    gibs = { "models/gibs/wood_gib01a.mdl", "models/gibs/wood_gib01b.mdl", "models/gibs/wood_gib01c.mdl",
        "models/gibs/wood_gib01d.mdl", "models/gibs/wood_gib01e.mdl" },
}

local METAL = {
    hit = { "physics/metal/metal_box_impact_hard1.wav", "physics/metal/metal_box_impact_hard2.wav",
        "physics/metal/metal_box_impact_hard3.wav" },
    brk = { "physics/metal/metal_box_break1.wav", "physics/metal/metal_box_break2.wav" },
    gibs = { "models/gibs/metal_gib1.mdl", "models/gibs/metal_gib2.mdl", "models/gibs/metal_gib3.mdl",
        "models/gibs/metal_gib4.mdl", "models/gibs/metal_gib5.mdl" },
}

for _, kind in ipairs({ WOOD, METAL }) do
    for _, model in ipairs(kind.gibs) do HZ.PrecacheModel(model) end
    HZ.PrecacheSounds(kind.hit)
    HZ.PrecacheSounds(kind.brk)
end

local function KindOf(mat)
    return (mat == MAT_METAL or mat == MAT_GRATE or mat == MAT_VENT) and METAL or WOOD
end

function HZ.OpenDoorPortals(door)
    local name = door:GetName()
    if not name or name == "" then return end

    for _, portal in ipairs(ents.FindByClass("func_areaportal")) do
        local keyValues = portal:GetKeyValues()
        if keyValues and keyValues.target == name then
            portal:Fire("Open")
            portal:SetKeyValue("target", "")
        end
    end
end

local function SpawnDebris(door, kind, dir)
    local mins, maxs = door:OBBMins(), door:OBBMaxs()
    for _ = 1, math.random(5, 8) do
        local gib = ents.Create("prop_physics")
        if not IsValid(gib) then break end

        gib:SetModel(HZ.Pick(kind.gibs))
        gib:SetPos(door:LocalToWorld(Vector(math.Rand(mins.x, maxs.x), math.Rand(mins.y, maxs.y),
            math.Rand(mins.z, maxs.z))))

        gib:SetAngles(AngleRand())
        gib:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
        gib:Spawn()
        local phys = gib:GetPhysicsObject()
        if IsValid(phys) then
            phys:Wake()
            phys:SetVelocity(dir * math.Rand(150, 320) + VectorRand() * 90 + Vector(0, 0, math.Rand(40, 140)))
            phys:AddAngleVelocity(VectorRand() * 400)
        end

        SafeRemoveEntityDelayed(gib, math.Rand(15, 25))
    end
end

function HZ.BashDoor(door, zombie, dir, mat)
    local kind = KindOf(mat)
    local hit = HZ.CV.door_hit:GetFloat() * (zombie.hz_shambler and 0.6 or 1)
    door.hz_doorHP = (door.hz_doorHP or HZ.CV.door_hp:GetFloat()) - hit
    door:EmitSound(HZ.Pick(kind.hit), 80, math.random(90, 110))
    util.ScreenShake(door:WorldSpaceCenter(), 1.5, 8, 0.3, 300)
    if door.hz_doorHP > 0 then return false end

    door.hz_doorHP = nil
    local pos = door:WorldSpaceCenter()
    HZ.OpenDoorPortals(door)
    local mdl = door:GetModel()
    if door:GetClass() == "prop_door_rotating" and mdl and util.IsValidProp(mdl) then
        local dpos, ang, skin = door:GetPos(), door:GetAngles(), door:GetSkin()
        local groups = {}
        for i = 0, door:GetNumBodyGroups() - 1 do groups[i] = door:GetBodygroup(i) end
        door:Remove()
        local prop = ents.Create("prop_physics")
        if IsValid(prop) then
            prop:SetModel(mdl)
            prop:SetPos(dpos)
            prop:SetAngles(ang)
            prop:SetSkin(skin)
            for i, value in pairs(groups) do prop:SetBodygroup(i, value) end
            prop:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
            prop:Spawn()
            local phys = prop:GetPhysicsObject()
            if IsValid(phys) then
                phys:Wake()
                phys:ApplyForceCenter((dir * 350 + Vector(0, 0, 60)) * phys:GetMass())
                phys:AddAngleVelocity(VectorRand() * 120)
            end
        end
    else
        SpawnDebris(door, kind, dir)
        door:Remove()
    end

    sound.Play(HZ.Pick(kind.brk), pos, 85, math.random(90, 105))
    util.ScreenShake(pos, 4, 12, 0.6, 500)

    return true
end

local BARRICADE_CLASSES = {
    prop_physics = true,
    prop_physics_multiplayer = true,
    prop_physics_override = true,
    func_physbox = true,
    func_physbox_multiplayer = true,
}

function HZ.IsBarricade(ent)
    return HZ.CV.barricade:GetBool() and BARRICADE_CLASSES[ent:GetClass()] == true and not ent:CreatedByMap()
end

local function PropHealth(ent, phys)
    local health = math.Clamp(IsValid(phys) and phys:GetMass() or 50, 20, 400)
    local held = (IsValid(phys) and not phys:IsMotionEnabled()) or constraint.HasConstraints(ent)
    if held then health = health * 2.5 end

    return health * math.max(HZ.CV.barricade_hp:GetFloat(), 0.05)
end

function HZ.BashProp(ent, zombie, dir, mat, hitPos)
    local kind = KindOf(mat)
    local phys = ent:GetPhysicsObject()
    local blow = HZ.CV.door_hit:GetFloat() * (zombie.hz_shambler and 0.6 or 1)
    ent.hz_propHP = (ent.hz_propHP or PropHealth(ent, phys)) - blow
    ent:EmitSound(HZ.Pick(kind.hit), 78, math.random(90, 110))

    local dmgInfo = DamageInfo()
    dmgInfo:SetDamage(25)
    dmgInfo:SetAttacker(zombie)
    dmgInfo:SetInflictor(zombie)
    dmgInfo:SetDamageType(DMG_CLUB)
    dmgInfo:SetDamagePosition(hitPos)
    ent:TakeDamageInfo(dmgInfo)
    if not IsValid(ent) then return true end

    if IsValid(phys) and phys:IsMotionEnabled() then
        phys:ApplyForceOffset(dir * phys:GetMass() * 150, hitPos)
    end

    if ent.hz_propHP > 0 then return false end

    ent.hz_propHP = nil
    constraint.RemoveAll(ent)
    if IsValid(phys) then
        phys:EnableMotion(true)
        phys:Wake()
        phys:ApplyForceCenter((dir * 300 + Vector(0, 0, 80)) * phys:GetMass())
    end

    local group = ent:GetCollisionGroup()
    ent:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    timer.Simple(15, function()
        if IsValid(ent) and ent:GetCollisionGroup() == COLLISION_GROUP_DEBRIS then ent:SetCollisionGroup(group) end
    end)

    sound.Play(HZ.Pick(kind.brk), ent:WorldSpaceCenter(), 85, math.random(90, 105))
    util.ScreenShake(ent:WorldSpaceCenter(), 3, 10, 0.5, 400)

    return true
end

function HZ.PointsAround(area, count)
    local pool = { area }
    for _, neighbor in ipairs(area:GetAdjacentAreas()) do pool[#pool + 1] = neighbor end
    local out = {}
    for i = 1, count do out[i] = HZ.Pick(pool):GetRandomPoint() + Vector(0, 0, 4) end

    return out
end

local function IsAdmin(ply)
    return not IsValid(ply) or ply:IsAdmin()
end

concommand.Add("hz_clear", function(ply)
    if not IsAdmin(ply) then return end

    timer.Remove("hordez_stress_spawn")
    for zombie in pairs(HZ.Zombies) do
        if IsValid(zombie) then zombie:Remove() end
    end

    if HZ.ClearVirtual then HZ.ClearVirtual() end
end)

concommand.Add("hz_horde", function(ply)
    if not IsAdmin(ply) then return end

    local director = HZ.ActiveDirector
    if IsValid(director) then
        director:StartHorde()
    else
        print("[hordez] no active hz_director")
    end
end)

concommand.Add("hz_alert_all", function(ply)
    if not IsAdmin(ply) then return end

    for zombie in pairs(HZ.Zombies) do
        if IsValid(zombie) and not zombie.hz_alerted then zombie.hz_wakeAt = CurTime() + math.Rand(0, 1) end
    end
end)

local spawnSeq = 0
concommand.Add("hz_spawn", function(ply, _, args)
    if not IsValid(ply) or not ply:IsAdmin() then return end

    local hitPos = ply:GetEyeTrace().HitPos
    local want = math.Clamp(tonumber(args[2]) or 1, 1, 30)
    local idle = args[1] or "random"
    local done = 0
    spawnSeq = spawnSeq + 1
    local timerId = "hordez_cmd_spawn_" .. spawnSeq

    local function Step()
        for _ = 1, 2 do
            if done >= want then
                timer.Remove(timerId)
                return
            end

            HZ.SpawnZombie(hitPos + Vector(math.Rand(-60, 60), math.Rand(-60, 60), 8), nil, { idle = idle })
            done = done + 1
        end

        if done >= want then timer.Remove(timerId) end
    end

    Step()
    if done < want then timer.Create(timerId, 0.03, 0, Step) end
end)

local STRESS_BATCH = 20
local STRESS_REAL_BATCH = 2
concommand.Add("hz_stress", function(ply, _, args)
    if not IsValid(ply) or not ply:IsAdmin() then return end

    timer.Remove("hordez_stress_spawn")
    local want = math.Clamp(math.floor(tonumber(args[1]) or 1000), 0, 4000)
    if want == 0 then
        print("[hordez] stress spawn stopped")
        return
    end

    local alerted = (tonumber(args[2]) or 1) ~= 0
    local myPos = ply:GetPos()
    local center = ply:GetEyeTrace().HitPos
    local virtual = alerted and HZ.VirtualOn and HZ.VirtualOn()
    local radius = math.Clamp(tonumber(args[3]) or math.sqrt(want) * 60, 300, 12000)
    if not navmesh.GetNearestNavArea(center, false, radius + 400, false, false) then
        print("[hordez] hz_stress: no navmesh within " .. math.floor(radius) .. " units of where you are looking (nav_generate, or pass a bigger radius)")
        return
    end

    local function RandomSpot()
        local ang, dist = math.Rand(0, math.pi * 2), radius * math.sqrt(math.random())
        local pos = Vector(center.x + math.cos(ang) * dist, center.y + math.sin(ang) * dist, center.z)
        local tr = util.TraceLine({ start = pos + Vector(0, 0, 400), endpos = pos - Vector(0, 0, 3000),
            mask = MASK_NPCSOLID_BRUSHONLY })

        if tr.Hit and not tr.StartSolid then pos = tr.HitPos end
        local area = navmesh.GetNearestNavArea(pos, false, 250, false, false)
        if not area or area:IsUnderwater() then return nil end

        local point = area:GetClosestPointOnArea(pos)
        if not point or (point.x - pos.x) ^ 2 + (point.y - pos.y) ^ 2 > 48 * 48 then return nil end

        return point
    end

    local done, misses, tries, nVirtual = 0, 0, 0, 0
    local t0 = SysTime()
    print(("[hordez] stress: spawning %d infected (%s) in a circle of radius %d"):format(want, alerted and "chasing"
        or "idle", radius))

    timer.Create("hordez_stress_spawn", 0, 0, function()
        local realThisTick = 0
        for _ = 1, STRESS_BATCH do
            if done >= want then break end

            local pos = RandomSpot()
            tries = tries + 1
            if tries > want * 30 then
                timer.Remove("hordez_stress_spawn")
                print(("[hordez] stress: stopped at %d / %d (hz_max_total reached, or no room in that circle)"):format(done, want))
                return
            end

            if not pos then
            elseif pos:DistToSqr(myPos) < 200 * 200 and misses < 200 then
                misses = misses + 1
            elseif virtual and HZ.Count >= HZ.CV.real_max:GetInt() then
                if HZ.CanSpawn() and HZ.AddVirtual(pos + Vector(0, 0, 4)) then
                    done, nVirtual = done + 1, nVirtual + 1
                end
            else
                local zombie = HZ.SpawnZombie(pos + Vector(0, 0, 4), nil, { idle = "random", alerted = alerted })
                if not IsValid(zombie) then
                    timer.Remove("hordez_stress_spawn")
                    print(("[hordez] stress: stopped at %d / %d (hz_max_total or the entity limit reached)"):format(done, want))
                    return
                end

                done = done + 1
                realThisTick = realThisTick + 1
                if realThisTick >= STRESS_REAL_BATCH then break end
            end
        end

        if done >= want then
            timer.Remove("hordez_stress_spawn")
            print(("[hordez] stress: %d spawned in %.1f s (%d of them virtual), %d real + %d virtual infected alive"):format(done,
                SysTime() - t0, nVirtual, HZ.Count, HZ.VCount or 0))
        end
    end)
end)

concommand.Add("hz_status", function(ply)
    if not IsAdmin(ply) then return end

    local alerted = 0
    for zombie in pairs(HZ.Zombies) do
        if zombie.hz_alerted then alerted = alerted + 1 end
    end

    print(("[hordez] zombies %d real + %d virtual (%d alerted) / total cap %d (0 = none) | flow %s areas=%d | stress %.0f"):format(HZ.Count, HZ.VCount or 0, alerted,
        HZ.CV.max:GetInt(), HZ.Flow.ready and "ready" or "not ready", HZ.Flow.graph and #HZ.Flow.graph.ids
        or 0, HZ.Stress))
end)

local function FogDensity()
    local density
    for _, fog in ipairs(ents.FindByClass("env_fog_controller")) do
        local value = tonumber(fog:GetKeyValues().fogmaxdensity) or tonumber(fog:GetInternalVariable("fogmaxdensity"))
        if value and value > 0 and (not density or value > density) then density = value end
    end

    SetGlobalFloat("hz_fog_density", density or 1)
end

hook.Add("InitPostEntity", "hordez_fog_density", FogDensity)
timer.Create("hordez_fog_density", 10, 0, FogDensity)
