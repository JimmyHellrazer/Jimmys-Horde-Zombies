-- Horde Zombies: lightweight L4D-style infected NextBots (hz_zombie), director (hz_director), spawner (hz_spawner).
-- Models: infected_citizens by bloocobalt (workshop 129669178, used with permission; models + materials are
-- bundled here, so that addon is no longer needed) patched to use
-- retargeted L4D2 common-infected animations (models/hordez/inf_m.mdl / inf_f.mdl).
-- Build scripts: K:\jimmyproject\hordez (retarget_l4d2.py, patch_citizens.py).

HZ = HZ or {}

AddCSLuaFile("hordez/sh_config.lua")
AddCSLuaFile("hordez/sh_precache.lua")
AddCSLuaFile("hordez/cl_util.lua")
AddCSLuaFile("hordez/cl_virtual.lua")
AddCSLuaFile("hordez/cl_impostor.lua")
AddCSLuaFile("hordez/cl_horde.lua")
AddCSLuaFile("hordez/cl_menu.lua")
AddCSLuaFile("hordez/cl_faces.lua")
AddCSLuaFile("hordez/cl_steps.lua")
include("hordez/sh_config.lua")
include("hordez/sh_precache.lua")

if SERVER then
	include("hordez/sv_flow.lua")
	include("hordez/sv_horde.lua")
	include("hordez/sv_virtual.lua")
else
	include("hordez/cl_util.lua")
	include("hordez/cl_virtual.lua")
	include("hordez/cl_impostor.lua")
	include("hordez/cl_horde.lua")
	include("hordez/cl_menu.lua")
	include("hordez/cl_faces.lua")
	include("hordez/cl_steps.lua")
end
