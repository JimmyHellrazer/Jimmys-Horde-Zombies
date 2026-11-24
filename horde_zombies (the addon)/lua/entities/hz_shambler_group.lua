AddCSLuaFile()

-- Spawnmenu "Shambler Horde": the "Infected Horde" drop (hz_horde_count of them), all Romero shamblers.
ENT.Type = "point"
ENT.Base = "hz_horde_group"
ENT.PrintName = "Shambler Horde"
ENT.hz_shamblers = true

list.Set("NPC", "hz_shambler_group", { Name = "Shambler Horde", Class = "hz_shambler_group", Category = "Horde Zombies", IconOverride = "entities/hz_shambler_group.png" })
