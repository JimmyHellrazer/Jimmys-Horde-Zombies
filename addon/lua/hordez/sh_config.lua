HZ = HZ or {}
HZ.Version = "0.19.4"

local FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED)

local function MakeConVar(name, def, help)
    return CreateConVar(name, def, FLAGS, help)
end

HZ.CV = {
    health      = MakeConVar("hz_health", "50", "Zombie health"),
    dmg_solo_lo = MakeConVar("hz_damage_solo_min", "7", "Damage per hit when a zombie attacks alone (low end)"),
    dmg_solo_hi = MakeConVar("hz_damage_solo_max", "10", "Damage per hit when a zombie attacks alone (high end)"),
    dmg_mob_lo  = MakeConVar("hz_damage_mob_min", "1", "Damage per hit inside a mob (low end)"),
    dmg_mob_hi  = MakeConVar("hz_damage_mob_max", "2", "Damage per hit inside a mob (high end)"),
    dmg_mob_n   = MakeConVar("hz_damage_mob_count", "4",
        "Attackers on one target at which mob damage applies (between 1 and this it blends)"),
    headshot    = MakeConVar("hz_headshot_mult", "4", "Head hit damage multiplier"),
    runspeed    = MakeConVar("hz_runner_speed", "225", "Runner chase speed (players sprint at 400)"),
    speed_var   = MakeConVar("hz_chase_speed_var", "0.1",
        "Per-zombie speed spread (0.1 = each runs 90-110% of chase speed)"),
    max         = MakeConVar("hz_max_total", "0",
        "Optional cap on live zombies from every source together (0 = no cap)"),
    sight       = MakeConVar("hz_sight", "1100", "How far idle zombies can spot a target"),
    hear_gun    = MakeConVar("hz_hear_gun", "1600", "Gunshot alert radius"),
    hear_blast  = MakeConVar("hz_hear_blast", "2600", "Explosion alert radius"),
    spread      = MakeConVar("hz_alert_spread", "420", "Radius an alerted zombie wakes its neighbours in"),
    hot_dist    = MakeConVar("hz_hot_dist", "1500", "Within this range of a player zombies think at full rate"),
    dormant     = MakeConVar("hz_dormant_dist", "4500", "Idle zombies beyond this range barely think"),
    virt        = MakeConVar("hz_virtual", "1",
        "Big hordes: chasing zombies far from everyone stop being entities (drawn as impostors) until they get close"),
    real_max    = MakeConVar("hz_real_max", "150",
        "Above this many real zombies, far ones turn virtual and virtual ones wait for a free slot"),
    virt_near   = MakeConVar("hz_virtual_near", "2000",
        "A virtual zombie becomes a real one within this distance of a target"),
    virt_far    = MakeConVar("hz_virtual_far", "2800", "A real chasing zombie beyond this distance can turn virtual"),
    sit         = MakeConVar("hz_sit", "1", "Idle zombies sit down on seat-height props and ledges"),
    barricade   = MakeConVar("hz_barricade", "1", "Zombies beat on props in their way until they give"),
    barricade_hp = MakeConVar("hz_barricade_health", "1",
        "How much beating a prop takes (x its mass, frozen or welded props take 2.5x more)"),
    think_full  = MakeConVar("hz_think_full", "150",
        "Up to this many live zombies all think at the full rate; above it the ones not right next to a player think proportionally less often (at most 4x)"),
    target_npcs = MakeConVar("hz_target_npcs", "1", "Zombies also hunt NPCs / other NextBots (TIF soldiers etc.)"),
    flow_budget = MakeConVar("hz_flow_budget", "1500", "Nav areas the flow field solves per tick"),
    flow_range  = MakeConVar("hz_flow_range", "9000", "Max path distance the flow field reaches"),
    voices      = MakeConVar("hz_voices", "6", "Zombie vocalisations allowed per second (all zombies)"),
    climb       = MakeConVar("hz_climb", "1", "Zombies climb ledges up to 168 units"),
    debug       = MakeConVar("hz_debug", "0", "Debug overlays/prints"),
    horde_count = MakeConVar("hz_horde_count", "12", "How many zombies the 'Infected Horde' spawnmenu entry drops"),
    horde_alert = MakeConVar("hz_horde_alerted", "0", "1 = 'Infected Horde' spawns already chasing, 0 = idle"),
    accessory   = MakeConVar("hz_accessory_chance", "0.2", "Chance of a beanie / gloves / glasses (each)"),
    burn_time   = MakeConVar("hz_burn_time", "5", "Seconds a burning zombie lasts before it burns out and dies"),
    npc_hostile = MakeConVar("hz_npc_hostile", "1", "Stock NPCs (rebels, Combine...) treat the infected as enemies"),
    arc         = MakeConVar("hz_melee_arc", "1",
        "A melee hit / shove on one infected also hits the others in an arc (L4D2 style)"),
    arc_range   = MakeConVar("hz_melee_arc_range", "110", "Reach of the melee / shove arc"),
    arc_angle   = MakeConVar("hz_melee_arc_angle", "50", "Half-width of the arc in degrees (50 = a 100 degree sweep)"),
    arc_damage  = MakeConVar("hz_melee_arc_damage", "1",
        "Damage the arc deals to the others, x the real hit (0 = stagger only)"),
    door_hp     = MakeConVar("hz_door_health", "120", "Bash damage a door takes before it comes off its hinges"),
    door_hit    = MakeConVar("hz_door_bash", "4",
        "Damage of one runner blow on a door, ~1 per second each (shamblers 60%, slower)"),
    ahead       = MakeConVar("hz_director_ahead", "0.8",
        "How often the director spawns ahead of where players are heading (0-1)"),
    sh_chance   = MakeConVar("hz_shambler_chance", "0",
        "Chance a zombie spawned without a set variant is a Romero shambler"),
    sh_mix      = MakeConVar("hz_shambler_mix", "0.5", "Shambler share when a director / spawner is set to Mix"),
    sh_speed_lo = MakeConVar("hz_shambler_walk_min", "18",
        "Slowest shambler walking speed (the shuffle's natural pace is ~18)"),
    sh_speed_hi = MakeConVar("hz_shambler_walk_max", "26", "Fastest shambler walking speed"),
    sh_rate     = MakeConVar("hz_shambler_attack_rate", "0.8", "Playback speed of shambler attacks and swings"),
    sh_climb    = MakeConVar("hz_shambler_climb", "48", "Highest ledge a shambler can climb"),
    sh_damage   = MakeConVar("hz_shambler_damage", "1.5",
        "Shambler hit damage multiplier (on top of the solo / mob damage)"),
    sh_health   = MakeConVar("hz_shambler_health", "90", "Shambler health (runners use hz_health)"),
    sh_head     = MakeConVar("hz_shambler_headshots", "0", "1 = shamblers barely feel body shots: aim for the head"),
    sh_knock    = MakeConVar("hz_shambler_knockdown", "0.6",
        "Chance a shove from the front knocks a shambler to the ground"),
    spread_run  = MakeConVar("hz_chase_wide", "90",
        "How far apart chasing runners fan out sideways (closes up as they reach you)"),
    spread_sh   = MakeConVar("hz_shambler_wide", "220", "How wide shamblers spread into a closing wall"),
    lures       = MakeConVar("hz_lures", "1", "Pipe bombs and bile jars from other addons draw the infected"),
    lure_radius = MakeConVar("hz_lure_radius", "1200", "How far a pipe bomb / bile splash draws the infected from"),
    bile_time   = MakeConVar("hz_bile_time", "15", "How long a bile splash keeps drawing them (seconds)"),
    lure_cls    = MakeConVar("hz_lure_classes", "pipebomb,pipe_bomb",
        "Comma list: entity class or model names containing any of these are pipe-bomb lures"),
    bile_cls    = MakeConVar("hz_bile_classes",
        "vomitjar,vomit_jar,bilejar,bile_jar,boomerbile,boomer_bile,bilebomb,bile_bomb",
        "Comma list: thrown entities whose class or model contains any of these leave a bile lure where they land"),
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
