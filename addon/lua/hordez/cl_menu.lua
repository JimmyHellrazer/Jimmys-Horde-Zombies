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
    end)

    Section(panel, "Infected", false, function(ui)
        ui.Slider("Health", "hz_health", 1, 500, 0)
        ui.Slider("Headshot multiplier", "hz_headshot_mult", 1, 10, 1)
        ui.Slider("Run speed", "hz_runner_speed", 50, 600, 0)
        ui.Note("Players sprint at 400")
        ui.Check("Climb ledges", "hz_climb")
        ui.Check("Sit on chairs and ledges when idle", "hz_sit")
    end)

    Section(panel, "Damage", false, function(ui)
        ui.Slider("Alone, min", "hz_damage_solo_min", 0, 50, 0)
        ui.Slider("Alone, max", "hz_damage_solo_max", 0, 50, 0)
        ui.Slider("In a mob, min", "hz_damage_mob_min", 0, 20, 0)
        ui.Slider("In a mob, max", "hz_damage_mob_max", 0, 20, 0)
        ui.Note("Hits get weaker the more zombies are on you")
    end)

    Section(panel, "Shamblers", false, function(ui)
        ui.Slider("Chance per zombie", "hz_shambler_chance", 0, 1, 2)
        ui.Slider("Share in mixed spawns", "hz_shambler_mix", 0, 1, 2)
        ui.Slider("Health", "hz_shambler_health", 1, 500, 0)
        ui.Slider("Damage multiplier", "hz_shambler_damage", 0.5, 5, 1)
        ui.Check("Headshots only", "hz_shambler_headshots")
    end)

    Section(panel, "Combat", false, function(ui)
        ui.Check("Hits and shoves sweep an arc", "hz_melee_arc")
        ui.Check("Pipe bombs and bile attract zombies", "hz_lures")
        ui.Slider("Door health", "hz_door_health", 1, 1000, 0)
        ui.Check("Bash player props", "hz_barricade")
        ui.Slider("Prop toughness", "hz_barricade_health", 0.1, 5, 2)
    end)

    Section(panel, "Senses", false, function(ui)
        ui.Slider("Sight range", "hz_sight", 100, 5000, 0)
        ui.Slider("Gunshot hearing", "hz_hear_gun", 0, 8000, 0)
        ui.Check("Hunt NPCs and NextBots", "hz_target_npcs")
        ui.Check("NPCs fight back", "hz_npc_hostile")
        ui.Check("Ignore knocked out players", "hz_ignore_knocked_out")
    end)

    Section(panel, "Z-City", false, function(ui)
        ui.Check("Z-City damage model support", "hz_zcity")
        ui.Slider("Damage vs Z-City players", "hz_zcity_damage", 0, 2, 2)
        ui.Check("Mobs and shamblers knock players over", "hz_zcity_knockdown")
        ui.Note("Only does anything when Z-City is running")
    end)

    Section(panel, "Director", false, function(ui)
        ui.Slider("Infected Horde size", "hz_horde_count", 1, 100, 0)
        ui.Check("Infected Horde spawns chasing", "hz_horde_alerted")
        ui.Slider("Total limit", "hz_max_total", 0, 500, 0)
        ui.Note("0: no limit, each director and spawner limits itself")
        ui.Check("Virtual zombies for large hordes", "hz_virtual")
        ui.Slider("Real zombie limit", "hz_real_max", 20, 500, 0)
    end)
end

local function ClientPanel(panel)
    panel:ClearControls()

    Section(panel, "Detail", true, function(ui)
        ui.Slider("Simplified models from", "hz_lod_dist", 0, 3000, 0)
        ui.Slider("Shadows within", "hz_shadow_dist", -1, 6000, 0)
        ui.Note("-1: always")
        ui.Slider("Draw distance", "hz_draw_dist", 0, 20000, 0)
        ui.Note("0: no limit")
        ui.Check("Facial expressions", "hz_faces")
        ui.Check("Distant zombies as impostors", "hz_impostors")
        ui.Slider("Impostor distance", "hz_impostor_dist", 500, 10000, 0)
    end)

    Section(panel, "Deaths", false, function(ui)
        ui.Check("Death animations", "hz_death_anims")
        ui.Slider("Max ragdolls", "hz_ragdoll_max", 0, 100, 0)
        ui.Slider("Ragdoll lifetime (s)", "hz_ragdoll_time", 1, 300, 0)
    end)

    Section(panel, "Sound", false, function(ui)
        ui.Check("Footsteps", "hz_steps")
        ui.Slider("Footstep volume", "hz_steps_volume", 0, 1, 2)
    end)

    Section(panel, "Markers", false, function(ui)
        ui.Check("Always show director and spawner markers", "hz_show_markers")
        ui.Note("Otherwise only with the physgun or toolgun out")
    end)
end

local ICON_SIZE = 64

local function ModelIcon(grid, path, name)
    local icon = grid:Add("SpawnIcon")
    icon:SetModel(path)
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetTooltip(name or path)
    icon.DoClick = function()
        HZ.ToggleCustomModel(path)
    end

    icon.PaintOver = function(_, w, h)
        if not HZ.CustomModelSet[path] then return end

        surface.SetDrawColor(90, 210, 90, 255)
        surface.DrawOutlinedRect(0, 0, w, h, 3)
    end
end

local function ModelsPanel(panel)
    panel:ClearControls()
    panel:Help("Zombies wear the selected models. Only the host or a superadmin can change them")
    panel:NumSlider("Share of zombies", "hz_custom_share", 0, 1, 2)

    local entry = panel:TextEntry("Model path")
    panel:Button("Add path").DoClick = function()
        local path = string.lower(string.Trim(entry:GetValue()))
        if path ~= "" and not HZ.CustomModelSet[path] then HZ.ToggleCustomModel(path) end
    end

    panel:Button("Clear selection").DoClick = function()
        HZ.SendCustomModels({})
    end

    local scroll = vgui.Create("DScrollPanel", panel)
    scroll:SetTall(480)
    local grid = vgui.Create("DIconLayout", scroll)
    grid:Dock(FILL)
    grid:SetSpaceX(2)
    grid:SetSpaceY(2)

    local listed = {}
    for name, path in SortedPairs(player_manager.AllValidModels()) do
        path = string.lower(path)
        listed[path] = true
        ModelIcon(grid, path, name)
    end

    for _, path in ipairs(HZ.CustomModels) do
        if not listed[path] then ModelIcon(grid, path) end
    end

    panel:AddItem(scroll)
end

hook.Add("PopulateToolMenu", "hordez_menu", function()
    spawnmenu.AddToolMenuOption("Options", CATEGORY, "hordez_models", "Models", "", "", ModelsPanel)
    spawnmenu.AddToolMenuOption("Options", CATEGORY, "hordez_server", "Server", "", "", ServerPanel)
    spawnmenu.AddToolMenuOption("Options", CATEGORY, "hordez_client", "Client", "", "", ClientPanel)
end)
