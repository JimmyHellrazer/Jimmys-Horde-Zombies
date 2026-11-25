local function AddHeader(pos, text)
    local label = pos:Help(text)
    label:SetFont("DermaDefaultBold")

    return label
end

local function ServerPanel(pos)
    pos:Help("Server settings. Only the host or an admin can change these.")

    AddHeader(pos, "Actions")
    pos:Button("Start a horde now (needs an active director)", "hz_horde")
    pos:Button("Wake every idle zombie", "hz_alert_all")
    pos:Button("Remove all zombies", "hz_clear")
    pos:Button("Print status to console", "hz_status")
    pos:Button("Rebuild routes / climb links", "hz_flow_rebuild")

    AddHeader(pos, "Spawn at crosshair")
    local idle = pos:ComboBox("Idle pose")
    for _, choice in ipairs({ "random", "stand", "wander", "sit", "lie", "lean", "crouch", "chair" }) do
        idle:AddChoice(choice, choice, choice == "random")
    end

    local count = pos:NumSlider("How many", nil, 1, 30, 0)
    count:SetValue(5)
    local spawnButton = pos:Button("Spawn")
    spawnButton.DoClick = function()
        local _, data = idle:GetSelected()
        RunConsoleCommand("hz_spawn", data or "random", tostring(math.Round(count:GetValue())))
    end

    AddHeader(pos, "Infected Horde (spawn menu entry)")
    pos:NumSlider("Zombies per drop", "hz_horde_count", 1, 100, 0)
    pos:CheckBox("Drop them already chasing", "hz_horde_alerted")

    AddHeader(pos, "Zombies")
    pos:NumSlider("Health", "hz_health", 1, 500, 0)
    pos:NumSlider("Solo damage (min)", "hz_damage_solo_min", 0, 50, 0)
    pos:NumSlider("Solo damage (max)", "hz_damage_solo_max", 0, 50, 0)
    pos:NumSlider("Mob damage (min)", "hz_damage_mob_min", 0, 20, 0)
    pos:NumSlider("Mob damage (max)", "hz_damage_mob_max", 0, 20, 0)
    pos:NumSlider("Mob starts at (attackers)", "hz_damage_mob_count", 2, 12, 0)
    pos:ControlHelp("Like L4D2: one zombie alone hits hard; the more are on you, the less each hit does (blends up to the mob count).")
    pos:NumSlider("Headshot multiplier", "hz_headshot_mult", 1, 10, 1)
    pos:NumSlider("Chase speed", "hz_runner_speed", 50, 600, 0)
    pos:NumSlider("Speed spread", "hz_chase_speed_var", 0, 0.5, 2)
    pos:NumSlider("Fan out (runners)", "hz_chase_wide", 0, 400, 0)
    pos:ControlHelp("Players sprint at 400.")
    pos:NumSlider("Total cap, all sources (0 = none)", "hz_max_total", 0, 500, 0)
    pos:ControlHelp("Off by default: each director (Max Alive, default 60), spawner (Count) and drop limits itself.")
    pos:CheckBox("Climb ledges (up to 168 units)", "hz_climb")
    pos:NumSlider("Burn time (seconds)", "hz_burn_time", 1, 30, 1)
    pos:NumSlider("Accessory chance", "hz_accessory_chance", 0, 1, 2)
    pos:ControlHelp("Chance of a beanie / gloves / glasses on each zombie.")

    AddHeader(pos, "Romero shamblers")
    pos:ControlHelp("Slow walkers from the 'George Romero Dead Mode' L4D2 mod: spawn them with 'Infected (Shambler)' / 'Shambler Horde', or set a director / spawner Variant (edit it with right click > Edit Properties).")
    pos:NumSlider("Chance any zombie is a shambler", "hz_shambler_chance", 0, 1, 2)
    pos:NumSlider("Shambler share in Mix", "hz_shambler_mix", 0, 1, 2)
    pos:NumSlider("Slowest walk", "hz_shambler_walk_min", 10, 150, 0)
    pos:NumSlider("Fastest walk", "hz_shambler_walk_max", 10, 150, 0)
    pos:NumSlider("Wall width", "hz_shambler_wide", 0, 600, 0)
    pos:ControlHelp("The shuffle's natural pace is about 18; faster than ~25 and the feet start to slide.")
    pos:NumSlider("Attack speed", "hz_shambler_attack_rate", 0.3, 1.5, 2)
    pos:NumSlider("Highest climb", "hz_shambler_climb", 0, 168, 0)
    pos:NumSlider("Health", "hz_shambler_health", 1, 500, 0)
    pos:NumSlider("Damage (x zombie damage)", "hz_shambler_damage", 0.5, 5, 1)
    pos:NumSlider("Knockdown chance", "hz_shambler_knockdown", 0, 1, 2)
    pos:CheckBox("Headshots only (body shots barely hurt)", "hz_shambler_headshots")

    AddHeader(pos, "Melee / shove arc")
    pos:CheckBox("Melee hits and shoves sweep an arc", "hz_melee_arc")
    pos:ControlHelp("Like L4D2: hitting or shoving one infected also hits the others in front of you. Works with any weapon.")
    pos:NumSlider("Arc reach", "hz_melee_arc_range", 40, 300, 0)
    pos:NumSlider("Arc half-width (degrees)", "hz_melee_arc_angle", 10, 90, 0)
    pos:NumSlider("Arc damage (x the real hit)", "hz_melee_arc_damage", 0, 2, 2)
    pos:ControlHelp("0 = the others are only staggered.")

    AddHeader(pos, "Pipe bombs & bile")
    pos:CheckBox("Lures draw the infected", "hz_lures")
    pos:NumSlider("Lure range", "hz_lure_radius", 200, 4000, 0)
    pos:NumSlider("Bile lasts (s)", "hz_bile_time", 1, 60, 0)
    pos:ControlHelp("Works with other addons' pipe bombs and bile jars: anything thrown whose class or model name contains "
        .. "one of the hz_lure_classes / hz_bile_classes words (console) counts.")

    AddHeader(pos, "Doors")
    pos:NumSlider("Door health", "hz_door_health", 1, 1000, 0)
    pos:NumSlider("Damage per blow", "hz_door_bash", 1, 50, 0)
    pos:ControlHelp("Each zombie pounding a door lands about a blow a second (shamblers 60% damage, slower) on the same shared health. Defaults: a lone runner ~30 s, a pile of 5 ~6 s. Model doors come off their hinges; map (brush) doors burst into debris. Linked area portals are opened first, so no void bug.")

    AddHeader(pos, "Director")
    pos:NumSlider("Spawn ahead of players", "hz_director_ahead", 0, 1, 2)
    pos:ControlHelp("How often calm zombies are placed where players are heading (hordes use half of this).")

    AddHeader(pos, "Senses")
    pos:NumSlider("Sight range", "hz_sight", 100, 5000, 0)
    pos:NumSlider("Gunshot hearing", "hz_hear_gun", 0, 8000, 0)
    pos:NumSlider("Explosion hearing", "hz_hear_blast", 0, 10000, 0)
    pos:NumSlider("Alert spread radius", "hz_alert_spread", 0, 2000, 0)

    AddHeader(pos, "NPCs")
    pos:CheckBox("Zombies hunt NPCs / NextBots", "hz_target_npcs")
    pos:CheckBox("Stock NPCs fight the infected", "hz_npc_hostile")
    pos:ControlHelp("HL2 zombies and headcrabs always side with the horde.")

    AddHeader(pos, "Performance")
    pos:NumSlider("Full-rate think range", "hz_hot_dist", 300, 6000, 0)
    pos:NumSlider("Dormant beyond", "hz_dormant_dist", 1000, 15000, 0)
    pos:NumSlider("Voices per second", "hz_voices", 0, 30, 0)
    pos:NumSlider("Route solve budget", "hz_flow_budget", 100, 10000, 0)
    pos:NumSlider("Route range", "hz_flow_range", 1000, 30000, 0)
    pos:CheckBox("Debug prints", "hz_debug")
end

local function ClientPanel(pos)
    pos:Help("Effects on your screen only.")

    AddHeader(pos, "Death animations")
    pos:CheckBox("Play death animations", "hz_death_anims")
    pos:NumSlider("Animate within", "hz_death_anim_dist", 0, 6000, 0)
    pos:NumSlider("Max playing at once", "hz_death_anim_max", 0, 40, 0)

    AddHeader(pos, "Bodies")
    pos:NumSlider("Max ragdolls", "hz_ragdoll_max", 0, 100, 0)
    pos:NumSlider("Ragdoll lifetime (seconds)", "hz_ragdoll_time", 1, 300, 0)
    pos:NumSlider("Max burning bodies", "hz_burn_max", 0, 40, 0)

    AddHeader(pos, "Footsteps")
    pos:CheckBox("Zombie footsteps", "hz_steps")
    pos:NumSlider("How many zombies", "hz_steps_max", 0, 40, 0)
    pos:NumSlider("Within distance", "hz_steps_dist", 200, 4000, 0)
    pos:NumSlider("Volume", "hz_steps_volume", 0, 1, 2)
    pos:ControlHelp("L4D2 infected footsteps per surface, for the nearest few (including ones behind you).")

    AddHeader(pos, "Faces")
    pos:CheckBox("Nearest chasers snarl and yell", "hz_faces")
    pos:NumSlider("How many get faces", "hz_faces_max", 0, 12, 0)
    pos:NumSlider("Within distance", "hz_faces_dist", 100, 2000, 0)
    pos:ControlHelp("Only the closest few chasing zombies animate their faces; everyone else stays neutral.")

    AddHeader(pos, "Markers")
    pos:CheckBox("Always show director / spawner markers", "hz_show_markers")
    pos:ControlHelp("Otherwise they only show while holding the physgun or toolgun.")
end

hook.Add("PopulateToolMenu", "hordez_menu", function()
    spawnmenu.AddToolMenuOption("Utilities", "Horde Zombies", "hordez_server", "Server", "", "", ServerPanel)
    spawnmenu.AddToolMenuOption("Utilities", "Horde Zombies", "hordez_client", "Client", "", "", ClientPanel)
end)
