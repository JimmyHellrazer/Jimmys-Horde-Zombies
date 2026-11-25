AddCSLuaFile()

ENT.Type = "point"
ENT.Base = "hz_horde_group"
ENT.PrintName = "Infected (Shambler)"
ENT.hz_shamblers = true
ENT.hz_count = 1

list.Set("NPC", "hz_shambler",
    { Name = "Infected (Shambler)", Class = "hz_shambler", Category = "Horde Zombies",
    IconOverride = "entities/hz_shambler.png" })
