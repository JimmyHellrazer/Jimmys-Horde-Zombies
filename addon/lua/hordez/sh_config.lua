HZ = HZ or {}
HZ.Version = "0.22.0"

local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED)

local function MakeConVar(name, def, help)
    return CreateConVar(name, def, FLAGS, help)
end

HZ.CV = {
    health      = MakeConVar("hz_health", "50", "Health"),
    dmg_solo_lo = MakeConVar("hz_damage_solo_min", "7", "Damage alone, min"),
    dmg_solo_hi = MakeConVar("hz_damage_solo_max", "10", "Damage alone, max"),
    dmg_mob_lo  = MakeConVar("hz_damage_mob_min", "1", "Damage in a mob, min"),
    dmg_mob_hi  = MakeConVar("hz_damage_mob_max", "2", "Damage in a mob, max"),
    dmg_mob_n   = MakeConVar("hz_damage_mob_count", "4", "Mob size"),
    headshot    = MakeConVar("hz_headshot_mult", "4", "Headshot multiplier"),
    runspeed    = MakeConVar("hz_runner_speed", "225", "Run speed (players sprint at 400)"),
    speed_var   = MakeConVar("hz_chase_speed_var", "0.1", "Speed variation"),
    max         = MakeConVar("hz_max_total", "0", "Total limit (0: none)"),
    sight       = MakeConVar("hz_sight", "1100", "Sight range"),
    hear_gun    = MakeConVar("hz_hear_gun", "1600", "Gunshot hearing"),
    hear_blast  = MakeConVar("hz_hear_blast", "2600", "Explosion hearing"),
    spread      = MakeConVar("hz_alert_spread", "420", "Alert spread"),
    hot_dist    = MakeConVar("hz_hot_dist", "1500", "Full think rate within"),
    dormant     = MakeConVar("hz_dormant_dist", "4500", "Idle beyond"),
    virt        = MakeConVar("hz_virtual", "1", "Virtual zombies for large hordes"),
    real_max    = MakeConVar("hz_real_max", "150", "Real zombie limit"),
    virt_near   = MakeConVar("hz_virtual_near", "2000", "Turn real within"),
    virt_far    = MakeConVar("hz_virtual_far", "2800", "Turn virtual beyond"),
    native      = MakeConVar("hz_native", "1", "Native module"),
    sit         = MakeConVar("hz_sit", "1", "Sit on chairs and ledges when idle"),
    barricade   = MakeConVar("hz_barricade", "1", "Bash player props"),
    barricade_hp = MakeConVar("hz_barricade_health", "1", "Prop toughness"),
    think_full  = MakeConVar("hz_think_full", "150", "Full think rate up to this many zombies"),
    ignore_out  = MakeConVar("hz_ignore_knocked_out", "1", "Ignore knocked out players"),
    zcity       = MakeConVar("hz_zcity", "1", "Z-City damage model support"),
    zcity_damage = MakeConVar("hz_zcity_damage", "0.7", "Damage vs Z-City players"),
    zcity_knock = MakeConVar("hz_zcity_knockdown", "1", "Mobs and shamblers knock Z-City players over"),
    target_npcs = MakeConVar("hz_target_npcs", "1", "Hunt NPCs and NextBots"),
    flow_budget = MakeConVar("hz_flow_budget", "1500", "Pathing areas solved per tick"),
    flow_range  = MakeConVar("hz_flow_range", "9000", "Pathing range"),
    flow_build  = MakeConVar("hz_flow_build_ms", "8", "Pathing build time per tick (ms)"),
    flow_cache  = MakeConVar("hz_flow_cache", "1", "Cache climb links"),
    flow_prebuild = MakeConVar("hz_flow_prebuild", "1", "Build pathing when the map loads"),
    voices      = MakeConVar("hz_voices", "6", "Voices per second"),
    climb       = MakeConVar("hz_climb", "1", "Climb ledges"),
    l4d_director = MakeConVar("hz_l4d_director", "1", "Emulate L4D2 info_director on L4D2 maps"),
    debug       = MakeConVar("hz_debug", "0", "Debug prints"),
    profile     = CreateConVar("hz_profile", "0", FCVAR_REPLICATED, "Profiler overlay"),
    horde_count = MakeConVar("hz_horde_count", "12", "Infected Horde size"),
    horde_alert = MakeConVar("hz_horde_alerted", "0", "Infected Horde spawns chasing"),
    accessory   = MakeConVar("hz_accessory_chance", "0.2", "Accessory chance"),
    custom_share = MakeConVar("hz_custom_share", "1", "Share of zombies wearing custom models"),
    burn_time   = MakeConVar("hz_burn_time", "5", "Burn time (s)"),
    npc_hostile = MakeConVar("hz_npc_hostile", "1", "NPCs fight back"),
    arc         = MakeConVar("hz_melee_arc", "1", "Hits and shoves sweep an arc"),
    arc_range   = MakeConVar("hz_melee_arc_range", "110", "Arc reach"),
    arc_angle   = MakeConVar("hz_melee_arc_angle", "50", "Arc half angle"),
    arc_damage  = MakeConVar("hz_melee_arc_damage", "1", "Arc damage multiplier (0: stagger only)"),
    door_hp     = MakeConVar("hz_door_health", "120", "Door health"),
    door_hit    = MakeConVar("hz_door_bash", "4", "Door damage per blow"),
    ahead       = MakeConVar("hz_director_ahead", "0.8", "Spawn ahead of players"),
    straggle    = MakeConVar("hz_straggler_time", "20", "Respawn stragglers after (s, 0: never)"),
    sh_chance   = MakeConVar("hz_shambler_chance", "0", "Shambler chance per zombie"),
    sh_mix      = MakeConVar("hz_shambler_mix", "0.5", "Shambler share in mixed spawns"),
    sh_speed_lo = MakeConVar("hz_shambler_walk_min", "18", "Shambler slowest walk"),
    sh_speed_hi = MakeConVar("hz_shambler_walk_max", "26", "Shambler fastest walk"),
    sh_rate     = MakeConVar("hz_shambler_attack_rate", "0.8", "Shambler attack speed"),
    sh_climb    = MakeConVar("hz_shambler_climb", "48", "Shambler highest climb"),
    sh_damage   = MakeConVar("hz_shambler_damage", "1.5", "Shambler damage multiplier"),
    sh_health   = MakeConVar("hz_shambler_health", "90", "Shambler health"),
    sh_head     = MakeConVar("hz_shambler_headshots", "0", "Shamblers headshots only"),
    sh_knock    = MakeConVar("hz_shambler_knockdown", "0.6", "Shambler knockdown chance"),
    spread_run  = MakeConVar("hz_chase_wide", "90", "Spread while chasing"),
    spread_sh   = MakeConVar("hz_shambler_wide", "220", "Shambler spread while chasing"),
    lures       = MakeConVar("hz_lures", "1", "Pipe bombs and bile attract zombies"),
    lure_radius = MakeConVar("hz_lure_radius", "1200", "Lure range"),
    bile_time   = MakeConVar("hz_bile_time", "15", "Bile duration (s)"),
    lure_cls    = MakeConVar("hz_lure_classes", "pipebomb,pipe_bomb", "Pipe bomb names (comma separated)"),
    bile_cls    = MakeConVar("hz_bile_classes",
        "vomitjar,vomit_jar,bilejar,bile_jar,boomerbile,boomer_bile,bilebomb,bile_bomb", "Bile names (comma separated)"),
}

HZ.Models = {}
for _,
    name in ipairs({ "male_01", "male_02", "male_03", "male_04", "male_05", "male_06", "male_07", "male_08", "male_09",
    "male_10", "female_01", "female_01_b", "female_02", "female_02_b", "female_03", "female_03_b", "female_04",
    "female_04_b", "female_06", "female_06_b", "female_07", "female_07_b" }) do
    HZ.Models[#HZ.Models + 1] = "models/hordez/citizens/" .. name .. ".mdl"
end

HZ.FemaleChance = 0.35

local function Range(prefix, first, last, fmt)
    local out = {}
    for i = first, last do out[#out + 1] = prefix .. string.format(fmt or "%02d", i) end

    return out
end

local function Concat(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, value in ipairs(list) do out[#out + 1] = value end
    end

    return out
end

HZ.SeqPools = {
    stand      = Range("Idle_Neutral_", 1, 17),
    crouch     = { "Idle_Crouching_Neutral_01", "Idle_Crouching_Neutral_02" },
    sit        = Range("Sitting", 1, 9),
    lie        = Range("Lying", 1, 8),
    lean       = Range("LeaningBackward", 1, 4),
    sit_wake   = { "Sitting_to_Standing_Alert", "Sitting03_to_Standing" },
    lie_wake   = { "Lying_to_Standing_Alert", "Lying_to_Standing_Alert03c", "Lying_to_Standing_Alert03d" },
    wake       = { "Idle_Neutral_to_Alert_01", "Idle_Acquire_05", "Idle_Acquire_06", "Idle_Acquire_11",
        "violent_alert01_Common_a", "violent_alert01_Common_B", "violent_alert01_Common_C",
        "violent_alert01_Common_D", "violent_alert01_Common_E" },
    startled   = { "Startled_01" },
    alert_idle = { "Idle_Alert_01a", "Idle_Alert_01b", "Idle_Alert_02a", "Idle_Alert_03", "Idle_Alert_Straight_05",
        "Idle_Alert_Straight_08" },
    unreach    = { "Idle_UnableToReachTarget_01a", "Idle_UnableToReachTarget_01b", "Idle_UnableToReachTarget_01c",
        "Idle_UnableToReachTarget_01d" },
    walk       = { "Walk_Neutral_01", "Walk_Neutral_02", "Walk_Neutral_03", "Shamble_01", "Shamble_02", "Shamble_03" },
    run        = { "Run_01", "Run_02", "Run_03", "Run_04", "Run_05", "Run_01b", "Run_02b", "Run_03b" },
    run_fire   = { "Run_OnFire", "Run_OnFire_01" },
    melee      = { "Melee_01", "Melee_02", "Melee_03", "Melee_04" },
    attack_low = { "AttackIncap_01", "AttackIncap_03", "AttackIncap_05" },
    swing      = Range("Melee_Moving", 1, 6, "%02d_Layer"),
    door       = { "AttackDoor_01" },
    flinch     = { "Flinch_01", "Flinch_02" },
    shove_back  = { "Shoved_Backward_01", "Shoved_Backward_02", "Shoved_Backward_03", "Shoved_Backward_03a",
        "Shoved_Backward_04e", "Shoved_Backward_04g", "Shoved_Backward_04i", "Shoved_Backward_04j",
        "Shoved_Backward_04m", "Shoved_Backward_04o" },
    shove_fwd   = { "Shoved_Forward_01" },
    shove_left  = { "Shoved_Leftward_01" },
    shove_right = { "Shoved_Rightward_01" },
    shove_back_wall  = { "Shoved_Backward_IntoWall_01", "Shoved_Backward_IntoWall_02", "Shoved_Backward_IntoWall_03",
        "Shoved_Backward_IntoWall_04" },
    shove_fwd_wall   = { "Shoved_Forward_IntoWall_02" },
    shove_left_wall  = { "Shoved_Leftward_IntoWall_02" },
    shove_right_wall = { "Shoved_Rightward_IntoWall_01" },
    fall       = { "Fall_01", "Fall_02", "Fall_03" },
    land       = { "Landing01", "Landing02", "Landing03", "Landing04" },
    land_hard  = Range("Landing_Hard", 1, 6),
    stroll     = { "Walk_Neutral_01", "Walk_Neutral_02", "Walk_Neutral_03", "Walk_Neutral_02b", "Walk_Neutral_04a",
        "Walk_Neutral_04b" },
    vault      = { "Climb36_Hurdle_04_InPlace" },
    ladder_up  = { "Ladder_Ascend" },
    ladder_down = { "Ladder_Descend" },
    ladder_off = { "Ladder_Dismount_01", "Ladder_Dismount_02", "Ladder_Dismount_03", "Ladder_Dismount" },
    run_stop   = { "Running_to_Standing", "Running_to_Standing_02" },
    chair      = { "Sitting_in_Chair01" },
    chair_down = { "Standing_to_Sitting_in_Chair" },
    chair_up   = { "Sitting_in_Chair_to_Standing" },
    chair_wake = { "Sitting_in_Chair_to_Standing_Alert" },
    sit_down   = { "Standing_to_Sitting03" },
    lie_down   = { "Standing_to_Lying03" },
    shove_sit_left  = { "Shoved_Sitting_Leftward" },
    shove_sit_right = { "Shoved_Sitting_Rightward" },
}

HZ.DEATH_RAGDOLL, HZ.DEATH_STAND, HZ.DEATH_RUN, HZ.DEATH_HEAD, HZ.DEATH_SHOTGUN, HZ.DEATH_CLUB, HZ.DEATH_SLASH = 0, 1,
    2, 3, 4, 5, 6

HZ.DEATH_WALK = 7
HZ.DeathPools = {
    stand = {
        back  = { "Death_06", "Death_08", "Death_08b", "Death_11_03b", "Death_11_03c", "Death_11_01a" },
        fwd   = { "Death_01", "Death_02a", "Death_02c", "Death_03", "Death_09", "Death_10ab", "Death_11_02c",
            "Death_11_03a" },
        drop  = { "Death_05", "Death_07", "Death_10b", "Death_10c", "Death_11_01b", "Death_11_02a", "Death_11_02b",
            "Death_11_02d" },
    },
    run = { "DeathRunning_01", "DeathRunning_03", "DeathRunning_04", "DeathRunning_05", "DeathRunning_06",
        "DeathRunning_07",
        "DeathRunning_08", "DeathRunning_10", "DeathRunning_11a", "DeathRunning_11b", "DeathRunning_11c",
        "DeathRunning_11d",
        "DeathRunning_11f", "DeathRunning_11g",
        "DeathRunning_02", "DeathRunning_m04", "DeathRunning_m09", "DeathRunning_m10", "DeathRunning_m11a",
        "DeathRunning_m11b", "DeathRunning_m11c" },
    walk = { "DeathRunning_05", "DeathRunning_09", "DeathRunning_10", "DeathRunning_11b", "DeathRunning_11c",
        "DeathRunning_11d", "DeathRunning_11e" },
    head = { back = { "HeadshotFront" }, fwd = { "HeadshotBack" } },
    shotgun = {
        back  = { "Death_Shotgun_Backward_03", "Death_Shotgun_Backward_04", "Death_Shotgun_Backward_05",
            "Death_Shotgun_Backward_06",
            "Death_Shotgun_Backward_07", "Death_Shotgun_Backward_08", "Death_Shotgun_Backward_09",
            "Death_Shotgun_Backward_collapse" },
        fwd   = { "Death_shotgun_Forward" },
        right = { "Death_Shotgun_Rightward", "Death_Shotgun_Rightward01", "Death_Shotgun_Rightward02" },
        left  = { "Death_Shotgun_Leftward" },
    },
    club = {
        back  = Range("melee_death_back_", 1, 5),
        right = { "melee_death_right_01", "melee_death_right_02" },
        left  = { "melee_death_left_01", "melee_death_left_02" },
    },
    slash = {
        back  = Range("melee_death_back_", 1, 5, "%02d_SLASH"),
        right = { "melee_death_right_01_SLASH", "melee_death_right_02_SLASH" },
        left  = { "melee_death_left_01_SLASH", "melee_death_left_02_SLASH" },
    },
}

HZ.DeathEnds = {
    Death_01 = { 15, 37 }, Death_02c = { 37 }, Death_03 = { 15, 30, 50 }, Death_06 = { 17, 30, 70 },
    Death_07 = { 17, 54 },
    Death_08 = { 12, 42 }, Death_08b = { 12, 42 }, Death_09 = { 10, 35, 45, 65 }, Death_10b = { 14 },
    Death_10c = { 25 },
}

HZ.ShamblerPools = {
    run       = { "Romero_Run_01b", "Romero_Run_02", "Romero_Run_02b", "Romero_Run_03", "Romero_Run_03b",
        "Romero_Run_04",
        "Romero_Run_05" },
    melee     = { "Romero_Melee_01", "Romero_Melee_02", "Romero_Melee_03", "Romero_Melee_04",
        "Romero_female_melee_noel02" },
    attack_low = { "Romero_AttackIncap_01", "Romero_AttackIncap_03", "Romero_AttackIncap_05" },
    swing     = { "Romero_Melee_Moving01_Layer", "Romero_Melee_Moving02_Layer", "Romero_Melee_Moving03_Layer",
        "Romero_Melee_Moving05_Layer", "Romero_Melee_Moving06_Layer" },
    wake      = { "Idle_Neutral_to_Alert_01", "Idle_Acquire_05", "Idle_Acquire_06", "Idle_Acquire_11" },
    startled  = { "Idle_Neutral_to_Alert_01", "Idle_Acquire_05", "Idle_Acquire_06" },
    knockdown = { "Shoved_Backward_04i", "Shoved_Backward_04j", "Shoved_Backward_04m", "Shoved_Backward_04o",
        "Shoved_Backward_IntoWall_04" },
}

HZ.SHAMBLE_GS = 18
HZ.SHAMBLE_MAX_RATE = 1.4

HZ.ShamblerCache = HZ.ShamblerCache or {}

function HZ.ResolveShamblerPools(ent)
    local mdl = ent:GetModel()
    local costs = HZ.ShamblerCache[mdl]
    if costs then return costs end

    costs = setmetatable({}, { __index = HZ.ResolvePools(ent) })
    for key, names in pairs(HZ.ShamblerPools) do
        local ids = {}
        for _, name in ipairs(names) do
            local id = ent:LookupSequence(name)
            if id and id >= 0 then ids[#ids + 1] = id end
        end

        if #ids > 0 then costs[key] = ids end
    end

    HZ.ShamblerCache[mdl] = costs

    return costs
end

HZ.VARIANTS = { Runners = "runners", Shamblers = "shamblers", Mix = "mix" }

function HZ.VariantShambler(variant)
    if variant == "shamblers" then return true end
    if variant == "mix" then return math.random() < HZ.CV.sh_mix:GetFloat() end

    return false
end

HZ.ClimbHeights = { 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 168 }
HZ.ClimbNames = {}
for _, height in ipairs(HZ.ClimbHeights) do
    local names = {}
    for _, suffix in ipairs({ "00", "00a", "01", "02", "03", "03a", "04", "04a", "05", "06", "07" }) do
        names[#names + 1] = "Climb" .. height .. "_" .. suffix .. "_InPlace"
    end

    HZ.ClimbNames[height] = names
end

HZ.SeqCache = HZ.SeqCache or {}

function HZ.ResolvePools(ent)
    local mdl = ent:GetModel()
    local costs = HZ.SeqCache[mdl]
    if costs then return costs end

    costs = {}
    for key, names in pairs(HZ.SeqPools) do
        local ids = {}
        for _, name in ipairs(names) do
            local id = ent:LookupSequence(name)
            if id and id >= 0 then ids[#ids + 1] = id end
        end

        costs[key] = ids
    end

    costs.climb = {}
    for height, names in pairs(HZ.ClimbNames) do
        local ids = {}
        for _, name in ipairs(names) do
            local id = ent:LookupSequence(name)
            if id and id >= 0 then ids[#ids + 1] = id end
        end

        if #ids > 0 then costs.climb[height] = ids end
    end

    HZ.SeqCache[mdl] = costs
    if HZ.CV.debug:GetBool() then
        local miss = {}
        for key, ids in pairs(costs) do
            if key ~= "climb" and #ids == 0 then miss[#miss + 1] = key end
        end

        print("[hordez] resolved sequences for " .. mdl .. (#miss > 0
            and (" - empty pools: " .. table.concat(miss, ", ")) or ""))
    end

    return costs
end

function HZ.Pick(list)
    local count = list and #list or 0
    if count == 0 then return nil end

    return list[math.random(count)]
end
