AddCSLuaFile()

-- Spawnmenu "Infected (Shambler)": one slow Romero-style shambler where you aim (alerted only if
-- hz_horde_alerted is on, like the horde drops). The zombie itself is a normal hz_zombie with hz_shambler set.
ENT.Type = "point"
ENT.Base = "hz_horde_group"
ENT.PrintName = "Infected (Shambler)"
ENT.hz_shamblers = true
ENT.hz_count = 1

list.Set("NPC", "hz_shambler", { Name = "Infected (Shambler)", Class = "hz_shambler", Category = "Horde Zombies", IconOverride = "entities/hz_shambler.png" })
