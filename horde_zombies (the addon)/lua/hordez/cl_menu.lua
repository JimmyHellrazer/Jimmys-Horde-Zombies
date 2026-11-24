-- Spawn menu > Utilities > Horde Zombies: server settings (admin), client effects, and quick actions.
-- Server sliders write replicated convars: they apply on a listen server / singleplayer host or for admins.

local function header(p, text)
	local l = p:Help(text)
	l:SetFont("DermaDefaultBold")
	return l
end

local function serverPanel(p)
	p:Help("Server settings. Only the host or an admin can change these.")

	header(p, "Actions")
	p:Button("Start a horde now (needs an active director)", "hz_horde")
	p:Button("Wake every idle zombie", "hz_alert_all")
	p:Button("Remove all zombies", "hz_clear")
	p:Button("Print status to console", "hz_status")
	p:Button("Rebuild routes / climb links", "hz_flow_rebuild")

	header(p, "Spawn at crosshair")
	local idle = p:ComboBox("Idle pose")
	for _, v in ipairs({ "random", "stand", "wander", "sit", "lie", "lean", "crouch" }) do idle:AddChoice(v, v, v == "random") end
	local count = p:NumSlider("How many", nil, 1, 30, 0)
	count:SetValue(5)
	local go = p:Button("Spawn")
	go.DoClick = function()
		local _, data = idle:GetSelected()
		RunConsoleCommand("hz_spawn", data or "random", tostring(math.Round(count:GetValue())))
	end

	header(p, "Infected Horde (spawn menu entry)")
	p:NumSlider("Zombies per drop", "hz_horde_count", 1, 100, 0)
	p:CheckBox("Drop them already chasing", "hz_horde_alerted")

	header(p, "Zombies")
	p:NumSlider("Health", "hz_health", 1, 500, 0)
	p:NumSlider("Solo damage (min)", "hz_damage_solo_min", 0, 50, 0)
	p:NumSlider("Solo damage (max)", "hz_damage_solo_max", 0, 50, 0)
	p:NumSlider("Mob damage (min)", "hz_damage_mob_min", 0, 20, 0)
	p:NumSlider("Mob damage (max)", "hz_damage_mob_max", 0, 20, 0)
	p:NumSlider("Mob starts at (attackers)", "hz_damage_mob_count", 2, 12, 0)
	p:ControlHelp("Like L4D2: one zombie alone hits hard; the more are on you, the less each hit does (blends up to the mob count).")
	p:NumSlider("Headshot multiplier", "hz_headshot_mult", 1, 10, 1)
	p:NumSlider("Chase speed", "hz_runner_speed", 50, 600, 0)
	p:NumSlider("Speed spread", "hz_chase_speed_var", 0, 0.5, 2)
	p:NumSlider("Fan out (runners)", "hz_chase_wide", 0, 400, 0)
	p:ControlHelp("Players sprint at 400.")
	p:NumSlider("Total cap, all sources (0 = none)", "hz_max_total", 0, 500, 0)
	p:ControlHelp("Off by default: each director (Max Alive, default 60), spawner (Count) and drop limits itself.")
	p:CheckBox("Climb ledges (up to 168 units)", "hz_climb")
	p:NumSlider("Burn time (seconds)", "hz_burn_time", 1, 30, 1)
	p:NumSlider("Accessory chance", "hz_accessory_chance", 0, 1, 2)
	p:ControlHelp("Chance of a beanie / gloves / glasses on each zombie.")

	header(p, "Romero shamblers")
	p:ControlHelp("Slow walkers from the 'George Romero Dead Mode' L4D2 mod: spawn them with 'Infected (Shambler)' / 'Shambler Horde', or set a director / spawner Variant (edit it with right click > Edit Properties).")
	p:NumSlider("Chance any zombie is a shambler", "hz_shambler_chance", 0, 1, 2)
	p:NumSlider("Shambler share in Mix", "hz_shambler_mix", 0, 1, 2)
	p:NumSlider("Slowest walk", "hz_shambler_walk_min", 10, 150, 0)
	p:NumSlider("Fastest walk", "hz_shambler_walk_max", 10, 150, 0)
	p:NumSlider("Wall width", "hz_shambler_wide", 0, 600, 0)
	p:ControlHelp("The shuffle's natural pace is about 18; faster than ~25 and the feet start to slide.")
	p:NumSlider("Attack speed", "hz_shambler_attack_rate", 0.3, 1.5, 2)
	p:NumSlider("Highest climb", "hz_shambler_climb", 0, 168, 0)
	p:NumSlider("Health", "hz_shambler_health", 1, 500, 0)
	p:NumSlider("Damage (x zombie damage)", "hz_shambler_damage", 0.5, 5, 1)
	p:NumSlider("Knockdown chance", "hz_shambler_knockdown", 0, 1, 2)
	p:CheckBox("Headshots only (body shots barely hurt)", "hz_shambler_headshots")

	header(p, "Melee / shove arc")
	p:CheckBox("Melee hits and shoves sweep an arc", "hz_melee_arc")
	p:ControlHelp("Like L4D2: hitting or shoving one infected also hits the others in front of you. Works with any weapon.")
	p:NumSlider("Arc reach", "hz_melee_arc_range", 40, 300, 0)
	p:NumSlider("Arc half-width (degrees)", "hz_melee_arc_angle", 10, 90, 0)
	p:NumSlider("Arc damage (x the real hit)", "hz_melee_arc_damage", 0, 2, 2)
	p:ControlHelp("0 = the others are only staggered.")

	header(p, "Pipe bombs & bile")
	p:CheckBox("Lures draw the infected", "hz_lures")
	p:NumSlider("Lure range", "hz_lure_radius", 200, 4000, 0)
	p:NumSlider("Bile lasts (s)", "hz_bile_time", 1, 60, 0)
	p:ControlHelp("Works with other addons' pipe bombs and bile jars: anything thrown whose class or model name contains "
		.. "one of the hz_lure_classes / hz_bile_classes words (console) counts.")

	header(p, "Doors")
	p:NumSlider("Door health", "hz_door_health", 1, 1000, 0)
	p:NumSlider("Damage per blow", "hz_door_bash", 1, 50, 0)
	p:ControlHelp("Each zombie pounding a door lands about a blow a second (shamblers 60% damage, slower) on the same shared health. Defaults: a lone runner ~30 s, a pile of 5 ~6 s. Model doors come off their hinges; map (brush) doors burst into debris. Linked area portals are opened first, so no void bug.")

	header(p, "Director")
	p:NumSlider("Spawn ahead of players", "hz_director_ahead", 0, 1, 2)
	p:ControlHelp("How often calm zombies are placed where players are heading (hordes use half of this).")

	header(p, "Senses")
	p:NumSlider("Sight range", "hz_sight", 100, 5000, 0)
	p:NumSlider("Gunshot hearing", "hz_hear_gun", 0, 8000, 0)
	p:NumSlider("Explosion hearing", "hz_hear_blast", 0, 10000, 0)
	p:NumSlider("Alert spread radius", "hz_alert_spread", 0, 2000, 0)

	header(p, "NPCs")
	p:CheckBox("Zombies hunt NPCs / NextBots", "hz_target_npcs")
	p:CheckBox("Stock NPCs fight the infected", "hz_npc_hostile")
	p:ControlHelp("HL2 zombies and headcrabs always side with the horde.")

	header(p, "Performance")
	p:NumSlider("Full-rate think range", "hz_hot_dist", 300, 6000, 0)
	p:NumSlider("Dormant beyond", "hz_dormant_dist", 1000, 15000, 0)
	p:NumSlider("Voices per second", "hz_voices", 0, 30, 0)
	p:NumSlider("Route solve budget", "hz_flow_budget", 100, 10000, 0)
	p:NumSlider("Route range", "hz_flow_range", 1000, 30000, 0)
	p:CheckBox("Debug prints", "hz_debug")
end

local function clientPanel(p)
	p:Help("Effects on your screen only.")

	header(p, "Death animations")
	p:CheckBox("Play death animations", "hz_death_anims")
	p:NumSlider("Animate within", "hz_death_anim_dist", 0, 6000, 0)
	p:NumSlider("Max playing at once", "hz_death_anim_max", 0, 40, 0)

	header(p, "Bodies")
	p:NumSlider("Max ragdolls", "hz_ragdoll_max", 0, 100, 0)
	p:NumSlider("Ragdoll lifetime (seconds)", "hz_ragdoll_time", 1, 300, 0)
	p:NumSlider("Max burning bodies", "hz_burn_max", 0, 40, 0)

	header(p, "Footsteps")
	p:CheckBox("Zombie footsteps", "hz_steps")
	p:NumSlider("How many zombies", "hz_steps_max", 0, 40, 0)
	p:NumSlider("Within distance", "hz_steps_dist", 200, 4000, 0)
	p:NumSlider("Volume", "hz_steps_volume", 0, 1, 2)
	p:ControlHelp("L4D2 infected footsteps per surface, for the nearest few (including ones behind you).")

	header(p, "Faces")
	p:CheckBox("Nearest chasers snarl and yell", "hz_faces")
	p:NumSlider("How many get faces", "hz_faces_max", 0, 12, 0)
	p:NumSlider("Within distance", "hz_faces_dist", 100, 2000, 0)
	p:ControlHelp("Only the closest few chasing zombies animate their faces; everyone else stays neutral.")

	header(p, "Markers")
	p:CheckBox("Always show director / spawner markers", "hz_show_markers")
	p:ControlHelp("Otherwise they only show while holding the physgun or toolgun.")
end

hook.Add("PopulateToolMenu", "hordez_menu", function()
	spawnmenu.AddToolMenuOption("Utilities", "Horde Zombies", "hordez_server", "Server", "", "", serverPanel)
	spawnmenu.AddToolMenuOption("Utilities", "Horde Zombies", "hordez_client", "Client", "", "", clientPanel)
end)
