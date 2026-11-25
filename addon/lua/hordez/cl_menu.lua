local CATEGORY = "HordeZombies"

hook.Add("AddToolMenuCategories", "hordez_menu_category", function()
    spawnmenu.AddToolCategory("Options", CATEGORY, "Horde Zombies")
end)

local function ResetButton(form, convars)
    local button = form:Button("Reset")
    button.DoClick = function()
        for _, name in ipairs(convars) do
            local cv = GetConVar(name)
            if cv then RunConsoleCommand(name, cv:GetDefault()) end
        end
    end
end

local function Section(panel, title, expanded, build)
    local form = vgui.Create("DForm", panel)
    form:SetName(title)
    form:SetExpanded(expanded)
    panel:AddItem(form)

    local convars = {}
    local builder = { form = form }

    function builder.Check(label, convar)
        convars[#convars + 1] = convar
        return form:CheckBox(label, convar)
    end

    function builder.Slider(label, convar, lo, hi, decimals)
        convars[#convars + 1] = convar
        return form:NumSlider(label, convar, lo, hi, decimals)
    end

    function builder.Text(label, convar)
        convars[#convars + 1] = convar
        return form:TextEntry(label, convar)
    end

    function builder.Note(text)
        return form:ControlHelp(text)
    end

    function builder.Button(label, command, ...)
        return form:Button(label, command, ...)
    end

    build(builder)
    if #convars > 0 then ResetButton(form, convars) end

    return form
end

local IDLE_POSES = { { "Random", "random" }, { "Stand", "stand" }, { "Wander", "wander" }, { "Sit", "sit" },
    { "Lie down", "lie" }, { "Lean", "lean" }, { "Crouch", "crouch" }, { "Chair", "chair" } }

local function ServerPanel(panel)
    panel:ClearControls()
    panel:Help("Only the host or an admin can change these")

    Section(panel, "Spawning", true, function(ui)
        local idle = ui.form:ComboBox("Idle pose")
        for _, pose in ipairs(IDLE_POSES) do idle:AddChoice(pose[1], pose[2], pose[2] == "random") end

        local count = ui.form:NumSlider("Count", nil, 1, 30, 0)
        count:SetValue(5)
        ui.Button("Spawn at crosshair").DoClick = function()
            local _, data = idle:GetSelected()
            RunConsoleCommand("hz_spawn", data or "random", tostring(math.Round(count:GetValue())))
        end

        ui.Button("Start a horde", "hz_horde")
        ui.Note("Needs an active director")
        ui.Button("Wake all zombies", "hz_alert_all")
        ui.Button("Remove all zombies", "hz_clear")
        ui.Button("Print status", "hz_status")
    end)

    Section(panel, "Infected", false, function(ui)
        ui.Slider("Health", "hz_health", 1, 500, 0)
        ui.Slider("Headshot multiplier", "hz_headshot_mult", 1, 10, 1)
        ui.Slider("Run speed", "hz_runner_speed", 50, 600, 0)
        ui.Note("Players sprint at 400")
        ui.Slider("Speed variation", "hz_chase_speed_var", 0, 0.5, 2)
        ui.Slider("Spread while chasing", "hz_chase_wide", 0, 400, 0)
        ui.Check("Climb ledges", "hz_climb")
        ui.Slider("Burn time (s)", "hz_burn_time", 1, 30, 1)
        ui.Slider("Accessory chance", "hz_accessory_chance", 0, 1, 2)
        ui.Check("Sit on chairs and ledges when idle", "hz_sit")
    end)

    Section(panel, "Damage", false, function(ui)
        ui.Slider("Alone, min", "hz_damage_solo_min", 0, 50, 0)
        ui.Slider("Alone, max", "hz_damage_solo_max", 0, 50, 0)
        ui.Slider("In a mob, min", "hz_damage_mob_min", 0, 20, 0)
        ui.Slider("In a mob, max", "hz_damage_mob_max", 0, 20, 0)
        ui.Slider("Mob size", "hz_damage_mob_count", 2, 12, 0)
        ui.Note("Hits get weaker the more zombies are on you, down to the mob damage at this many")
    end)

    Section(panel, "Shamblers", false, function(ui)
        ui.Slider("Chance per zombie", "hz_shambler_chance", 0, 1, 2)
        ui.Slider("Share in mixed spawns", "hz_shambler_mix", 0, 1, 2)
        ui.Slider("Health", "hz_shambler_health", 1, 500, 0)
        ui.Slider("Damage multiplier", "hz_shambler_damage", 0.5, 5, 1)
        ui.Slider("Slowest walk", "hz_shambler_walk_min", 10, 150, 0)
        ui.Slider("Fastest walk", "hz_shambler_walk_max", 10, 150, 0)
        ui.Note("Feet start sliding above 25")
        ui.Slider("Spread while chasing", "hz_shambler_wide", 0, 600, 0)
        ui.Slider("Attack speed", "hz_shambler_attack_rate", 0.3, 1.5, 2)
        ui.Slider("Highest climb", "hz_shambler_climb", 0, 168, 0)
        ui.Slider("Knockdown chance", "hz_shambler_knockdown", 0, 1, 2)
        ui.Check("Headshots only", "hz_shambler_headshots")
        ui.Note("Body shots do a tenth of the damage")
    end)

    Section(panel, "Melee", false, function(ui)
        ui.Check("Hits and shoves sweep an arc", "hz_melee_arc")
        ui.Slider("Reach", "hz_melee_arc_range", 40, 300, 0)
        ui.Slider("Half angle", "hz_melee_arc_angle", 10, 90, 0)
        ui.Slider("Damage multiplier", "hz_melee_arc_damage", 0, 2, 2)
        ui.Note("0: the rest of the arc is only staggered")
    end)

    Section(panel, "Lures", false, function(ui)
        ui.Check("Pipe bombs and bile attract zombies", "hz_lures")
        ui.Slider("Range", "hz_lure_radius", 200, 4000, 0)
        ui.Slider("Bile duration (s)", "hz_bile_time", 1, 60, 0)
        ui.Text("Pipe bomb names", "hz_lure_classes")
        ui.Text("Bile names", "hz_bile_classes")
        ui.Note("Comma separated words matched against the class or model of anything thrown")
    end)

    Section(panel, "Doors and barricades", false, function(ui)
        ui.Slider("Door health", "hz_door_health", 1, 1000, 0)
        ui.Slider("Damage per blow", "hz_door_bash", 1, 50, 0)
        ui.Check("Bash player props", "hz_barricade")
        ui.Slider("Prop toughness", "hz_barricade_health", 0.1, 5, 2)
        ui.Note("Heavier props take longer, frozen or welded ones 2.5x longer")
    end)

    Section(panel, "Senses", false, function(ui)
        ui.Slider("Sight range", "hz_sight", 100, 5000, 0)
        ui.Slider("Gunshot hearing", "hz_hear_gun", 0, 8000, 0)
        ui.Slider("Explosion hearing", "hz_hear_blast", 0, 10000, 0)
        ui.Slider("Alert spread", "hz_alert_spread", 0, 2000, 0)
        ui.Check("Hunt NPCs and NextBots", "hz_target_npcs")
        ui.Check("NPCs fight back", "hz_npc_hostile")
        ui.Check("Ignore knocked out players", "hz_ignore_knocked_out")
        ui.Note("Z-City players who are unconscious or down and unable to get up, or any addon using the HZ_KnockedOut hook")
    end)

    Section(panel, "Z-City", false, function(ui)
        ui.Check("Z-City damage model support", "hz_zcity")
        ui.Slider("Damage vs Z-City players", "hz_zcity_damage", 0, 2, 2)
        ui.Check("Mobs and shamblers knock players over", "hz_zcity_knockdown")
        ui.Note("Hits land on real body parts and cause bleeding like Z-City's own zombies, and shot infected bleed again. Only does anything when Z-City is running")
    end)

    Section(panel, "Director", false, function(ui)
        ui.Slider("Infected Horde size", "hz_horde_count", 1, 100, 0)
        ui.Check("Infected Horde spawns chasing", "hz_horde_alerted")
        ui.Slider("Spawn ahead of players", "hz_director_ahead", 0, 1, 2)
        ui.Slider("Respawn stragglers after (s)", "hz_straggler_time", 0, 120, 0)
        ui.Note("0: never")
        ui.Slider("Total limit", "hz_max_total", 0, 500, 0)
        ui.Note("0: no limit, each director and spawner limits itself")
    end)

    Section(panel, "Large hordes", false, function(ui)
        ui.Check("Virtual zombies", "hz_virtual")
        ui.Note("Distant zombies stop being entities and come back as they get close")
        ui.Slider("Real zombie limit", "hz_real_max", 20, 500, 0)
        ui.Slider("Turn real within", "hz_virtual_near", 500, 6000, 0)
        ui.Slider("Turn virtual beyond", "hz_virtual_far", 800, 8000, 0)
    end)

    Section(panel, "Performance", false, function(ui)
        ui.Slider("Full think rate within", "hz_hot_dist", 300, 6000, 0)
        ui.Slider("Full think rate up to", "hz_think_full", 10, 1000, 0)
        ui.Note("Above this many zombies, the ones away from players think less often")
        ui.Slider("Idle beyond", "hz_dormant_dist", 1000, 15000, 0)
        ui.Slider("Voices per second", "hz_voices", 0, 30, 0)
    end)

    Section(panel, "Pathing", false, function(ui)
        ui.Slider("Range", "hz_flow_range", 1000, 30000, 0)
        ui.Slider("Areas solved per tick", "hz_flow_budget", 100, 10000, 0)
        ui.Slider("Build time per tick (ms)", "hz_flow_build_ms", 1, 50, 0)
        ui.Check("Build when the map loads", "hz_flow_prebuild")
        ui.Check("Cache climb links", "hz_flow_cache")
        ui.Button("Rebuild", "hz_flow_rebuild")
        ui.Button("Rebuild without cache", "hz_flow_rebuild", "fresh")
    end)

    Section(panel, "Developer", false, function(ui)
        ui.Check("Debug prints", "hz_debug")
        ui.Note("Stress test: hz_stress <count> [chasing] [radius]")
    end)
end

local function ClientPanel(panel)
    panel:ClearControls()

    Section(panel, "Detail", true, function(ui)
        ui.Slider("Simplified models from", "hz_lod_dist", 0, 3000, 0)
        ui.Note("0: let the engine decide")
        ui.Slider("Shadows within", "hz_shadow_dist", -1, 6000, 0)
        ui.Note("-1: always")
        ui.Slider("Draw distance", "hz_draw_dist", 0, 20000, 0)
        ui.Note("0: no limit")
        ui.Check("Simplify buried zombies in crowds", "hz_crowd_lod")
        ui.Slider("Hide zombies behind rows", "hz_crowd_hide", 0, 10, 0)
        ui.Note("0: never")
        ui.Check("Skip zombies behind walls", "hz_occlusion")
        ui.Slider("Flashlight shadows within", "hz_depth_dist", 0, 6000, 0)
        ui.Note("0: always")
    end)

    Section(panel, "Impostors", false, function(ui)
        ui.Check("Enabled", "hz_impostors")
        ui.Slider("Distance", "hz_impostor_dist", 500, 10000, 0)
        ui.Slider("Brightness", "hz_impostor_light", 0, 3, 2)
        ui.Check("Fog", "hz_impostor_fog")
        ui.Check("Debug overlay", "hz_impostor_debug")
        ui.Button("Rebake", "hz_impostor_rebake")
    end)

    Section(panel, "Deaths", false, function(ui)
        ui.Check("Death animations", "hz_death_anims")
        ui.Slider("Animate within", "hz_death_anim_dist", 0, 6000, 0)
        ui.Slider("Max animating", "hz_death_anim_max", 0, 40, 0)
        ui.Slider("Max ragdolls", "hz_ragdoll_max", 0, 100, 0)
        ui.Slider("Ragdoll lifetime (s)", "hz_ragdoll_time", 1, 300, 0)
        ui.Slider("Max burning bodies", "hz_burn_max", 0, 40, 0)
    end)

    Section(panel, "Sound", false, function(ui)
        ui.Check("Footsteps", "hz_steps")
        ui.Slider("Footstep zombies", "hz_steps_max", 0, 40, 0)
        ui.Slider("Footstep range", "hz_steps_dist", 200, 4000, 0)
        ui.Slider("Footstep volume", "hz_steps_volume", 0, 1, 2)
    end)

    Section(panel, "Faces", false, function(ui)
        ui.Check("Facial animation", "hz_faces")
        ui.Slider("Max animated", "hz_faces_max", 0, 12, 0)
        ui.Slider("Range", "hz_faces_dist", 100, 2000, 0)
    end)

    Section(panel, "Markers", false, function(ui)
        ui.Check("Always show director and spawner markers", "hz_show_markers")
        ui.Note("Otherwise only with the physgun or toolgun out")
    end)
end

hook.Add("PopulateToolMenu", "hordez_menu", function()
    spawnmenu.AddToolMenuOption("Options", CATEGORY, "hordez_server", "Server", "", "", ServerPanel)
    spawnmenu.AddToolMenuOption("Options", CATEGORY, "hordez_client", "Client", "", "", ClientPanel)
end)
