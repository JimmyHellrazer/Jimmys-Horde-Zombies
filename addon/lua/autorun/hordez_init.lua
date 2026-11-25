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
