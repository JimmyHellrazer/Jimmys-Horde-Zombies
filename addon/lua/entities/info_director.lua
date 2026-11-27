AddCSLuaFile()

ENT.Type = "point"
ENT.Base = "base_point"

if CLIENT then return end

local START_LEAVE_DIST_SQR = 550 * 550
local END_SAFE_DIST_SQR = 320 * 320

function ENT:Initialize()
    self.started = false
    self.startPos = nil
    self.endPos = nil
    self.director = nil
    HZ.L4DDirector = self
    timer.Simple(1, function()
        if IsValid(self) then self:SetupDirector() end
    end)
end

function ENT:KeyValue(key, value)
    if key:sub(1, 2) == "On" then self:StoreOutput(key, value) end
end

function ENT:FindAnchors()
    local starts = ents.FindByClass("info_survivor_position")
    if #starts == 0 then starts = ents.FindByClass("info_player_start") end
    if IsValid(starts[1]) then self.startPos = starts[1]:GetPos() end

    local exits = ents.FindByClass("info_changelevel")
    if IsValid(exits[1]) then self.endPos = exits[1]:WorldSpaceCenter() end
end

function ENT:EnsureDirector()
    if IsValid(self.director) then return self.director end
    if not (HZ.CV and HZ.CV.l4d_director and HZ.CV.l4d_director:GetBool()) then return nil end

    local dir = ents.Create("hz_director")
    if not IsValid(dir) then return nil end

    dir:SetPos(self:GetPos())
    dir:Spawn()
    dir:SetNoDraw(true)
    dir:SetNW2Bool("hz_hidden", true)
    dir:SetActive(false)
    self.director = dir

    return dir
end

function ENT:SetupDirector()
    self:FindAnchors()
    if not (HZ.CV and HZ.CV.l4d_director and HZ.CV.l4d_director:GetBool()) then return end

    self:EnsureDirector()
    HZ.FlowWantedUntil = CurTime() + 30
    print("[hordez] L4D2 info_director detected - director ready")
end

function ENT:BeginGameplay(activator)
    if not (HZ.CV and HZ.CV.l4d_director and HZ.CV.l4d_director:GetBool()) then return end

    local dir = self:EnsureDirector()
    if not IsValid(dir) then return end

    dir:SetActive(true)
    if not self.started then
        self.started = true
        self:TriggerOutput("OnGameplayStart", activator or self)
    end
end

function ENT:TriggerPanic(activator, size)
    if not (HZ.CV and HZ.CV.l4d_director and HZ.CV.l4d_director:GetBool()) then return end

    self:BeginGameplay(activator)
    local dir = self.director
    if not IsValid(dir) then return end

    dir.onPanicFinished = function()
        if IsValid(self) then self:TriggerOutput("OnPanicEventFinished", activator or self) end
    end

    dir:StartHorde(math.max(size or dir:GetHordeSize(), 40))
end

function ENT:AcceptInput(name, activator, caller, data)
    local cmd = string.lower(name or "")
    if cmd == "panicevent" or cmd == "forcepanicevent" then
        self:TriggerPanic(activator)
        return true
    end

    if cmd == "beginscript" then
        self:BeginGameplay(activator)
        if IsValid(self.director) then
            self.director.onslaught = true
            if self.director.phase ~= "peak" then self.director:StartHorde() end
        end

        return true
    end

    if cmd == "endscript" then
        if IsValid(self.director) then self.director.onslaught = false end
        return true
    end

    if cmd == "forcesurvivorpositions" or cmd == "disable" then
        if IsValid(self.director) then self.director:SetActive(false) end
        return true
    end

    if cmd == "releasesurvivorpositions" or cmd == "finishintro" or cmd == "enable" then
        self:BeginGameplay(activator)
        return true
    end

    return false
end

function ENT:Think()
    self:NextThink(CurTime() + 1)
    if not (HZ.CV and HZ.CV.l4d_director and HZ.CV.l4d_director:GetBool()) then
        if IsValid(self.director) and self.director:GetActive() then self.director:SetActive(false) end
        return true
    end

    local plys = player.GetAll()
    if #plys == 0 then return true end

    if not self.started then
        if not self.startPos then
            self:BeginGameplay(plys[1])
            return true
        end

        for i = 1, #plys do
            local ply = plys[i]
            if IsValid(ply) and ply:Alive() and ply:GetPos():DistToSqr(self.startPos) > START_LEAVE_DIST_SQR then
                self:BeginGameplay(ply)
                break
            end
        end

        return true
    end

    if self.endPos and IsValid(self.director) then
        local allSafe, aliveCount = true, 0
        for i = 1, #plys do
            local ply = plys[i]
            if IsValid(ply) and ply:Alive() then
                aliveCount = aliveCount + 1
                if ply:GetPos():DistToSqr(self.endPos) > END_SAFE_DIST_SQR then
                    allSafe = false
                    break
                end
            end
        end

        local wantActive = not (aliveCount > 0 and allSafe)
        if self.director:GetActive() ~= wantActive then self.director:SetActive(wantActive) end
    end

    return true
end

function ENT:OnRemove()
    if HZ.L4DDirector == self then HZ.L4DDirector = nil end
    if IsValid(self.director) then self.director:Remove() end
end

hook.Add("AcceptInput", "hordez_l4d_doors", function(ent, input, activator)
    local l4d = HZ.L4DDirector
    if not IsValid(l4d) or l4d.started then return end

    if IsValid(ent) and ent:GetClass() == "prop_door_rotating_checkpoint" then
        local cmd = string.lower(input or "")
        if cmd == "open" or cmd == "toggle" or cmd == "use" then l4d:BeginGameplay(activator) end
    end
end)

hook.Add("EntityTakeDamage", "hordez_l4d_car_alarm", function(ent, dmg)
    local l4d = HZ.L4DDirector
    if not IsValid(l4d) or not IsValid(ent) or ent.hz_alarmTripped then return end
    if ent:GetClass() ~= "prop_car_alarm" then return end

    local attacker = dmg:GetAttacker()
    if not (IsValid(attacker) and attacker:IsPlayer()) then return end

    ent.hz_alarmTripped = true
    l4d:TriggerPanic(attacker)
end)

cvars.AddChangeCallback("hz_l4d_director", function(_, _, new)
    local l4d = HZ.L4DDirector
    if not IsValid(l4d) then return end

    if not tobool(new) then
        if IsValid(l4d.director) then l4d.director:SetActive(false) end
    elseif l4d.started then
        l4d:BeginGameplay()
    else
        l4d:EnsureDirector()
    end
end, "hordez_l4d_director")
