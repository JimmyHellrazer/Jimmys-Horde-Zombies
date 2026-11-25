local CV = HZ.CV

local RUNNER = { BleedMultiplier = 4, PainMultiplier = 0.6, ImmobilizationMul = 1.5, Penetration = 4 }
local SHAMBLER = { BleedMultiplier = 2.5, PainMultiplier = 0.8, ImmobilizationMul = 2.5, Penetration = 4 }

local HIGH_BONES = { "ValveBiped.Bip01_Head1", "ValveBiped.Bip01_Neck1", "ValveBiped.Bip01_Spine2",
    "ValveBiped.Bip01_Spine4", "ValveBiped.Bip01_L_UpperArm", "ValveBiped.Bip01_R_UpperArm",
    "ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_R_Forearm" }
local HIGH_WEIGHTS = { 1, 1, 4, 4, 2, 2, 2, 2 }
local LOW_BONES = { "ValveBiped.Bip01_L_Thigh", "ValveBiped.Bip01_R_Thigh", "ValveBiped.Bip01_L_Calf",
    "ValveBiped.Bip01_R_Calf", "ValveBiped.Bip01_Pelvis" }
local LOW_WEIGHTS = { 2, 2, 2, 2, 1 }

local KNOCK_COOLDOWN = 6

local function Active(target)
    return CV.zcity:GetBool() and hg ~= nil and IsValid(target) and target:IsPlayer() and istable(target.organism)
end

local function PickBone(body, names, weights)
    local total = 0
    for i = 1, #weights do total = total + weights[i] end

    local roll = math.random() * total
    for i = 1, #names do
        roll = roll - weights[i]
        if roll <= 0 then
            local bone = body:LookupBone(names[i])
            if bone then return body:GetBonePosition(bone) end

            break
        end
    end
end

local function Attackers(target)
    local targetPos = target:GetPos()
    local count = 0
    HZ.Near(targetPos, 110, function(zombie)
        if not zombie.hz_dead and zombie.hz_target == target then
            count = count + 1
        end
    end)

    return count
end

local function TryKnockdown(zombie, ply, attackers)
    if not CV.zcity_knock:GetBool() or not hg.LightStunPlayer or IsValid(ply.FakeRagdoll) then return end

    local now = CurTime()
    if now < (ply.hz_knockAt or 0) then return end

    local mob = attackers or Attackers(ply)
    local chance = 0
    if mob >= math.max(2, CV.dmg_mob_n:GetInt()) then chance = 0.06 + (mob - CV.dmg_mob_n:GetInt()) * 0.02 end
    if zombie.hz_shambler then chance = chance + 0.04 end
    if chance <= 0 or math.random() >= math.min(chance, 0.2) then return end

    ply.hz_knockAt = now + KNOCK_COOLDOWN
    hg.LightStunPlayer(ply, math.Rand(1.5, 2.5))
end

function HZ.ZCityHit(zombie, target, dmg, attackers)
    if not Active(target) then return end

    local mults = zombie.hz_shambler and SHAMBLER or RUNNER
    for key, value in pairs(mults) do zombie[key] = value end

    dmg:ScaleDamage(math.max(CV.zcity_damage:GetFloat(), 0))

    local body = IsValid(target.FakeRagdoll) and target.FakeRagdoll or target
    local low = zombie.hz_attackLow
    local spot = PickBone(body, low and LOW_BONES or HIGH_BONES, low and LOW_WEIGHTS or HIGH_WEIGHTS)
    if spot then
        local dir = spot - zombie:EyePos()
        dir:Normalize()
        dmg:SetDamagePosition(spot - dir * 12)
        dmg:SetDamageForce(dir * 2000)
    end

    TryKnockdown(zombie, target, attackers)
end

hook.Add("HZ_KnockedOut", "hordez_zcity", function(ply)
    if hg == nil then return end

    local organism = ply.organism
    if not istable(organism) then return end
    if organism.otrub or organism.incapacitated then return true end
    if not IsValid(ply.FakeRagdoll) then return end

    local limits = hg.organism
    if organism.fake or (organism.blood or 5000) < 2900 or (organism.consciousness or 1) <= 0.4 then return true end
    if (organism.lleg == 1 and organism.rleg == 1) and (organism.berserk or 0) <= 0.3 then return true end
    if istable(limits) and limits.fake_spine1 and ((organism.spine1 or 0) >= limits.fake_spine1
        or (organism.spine2 or 0) >= limits.fake_spine2 or (organism.spine3 or 0) >= limits.fake_spine3) then
        return true
    end
end)

hook.Add("PostEntityTakeDamage", "hordez_zcity_blood", function(ent, dmg, took)
    if not took or not HZ.Zombies[ent] or not CV.zcity:GetBool() or hg == nil then return end
    if ent.bloodColorHitFix == nil or ent:GetBloodColor() ~= DONT_BLEED or not dmg:IsBulletDamage() then return end

    local effect = EffectData()
    effect:SetOrigin(dmg:GetDamagePosition())
    effect:SetNormal(-dmg:GetDamageForce():GetNormalized())
    effect:SetScale(1)
    util.Effect("BloodImpact", effect, true, true)
end)
