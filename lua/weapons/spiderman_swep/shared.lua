if SERVER then AddCSLuaFile() end
SWEP.Author = "Doom Slayer"
SWEP.Purpose = "Swing like Spider-Man!"
SWEP.Instructions = "Left-click to swing. Right-click to pull props/NPCs."
SWEP.Category = "Spider-Man"
SWEP.PrintName = "Spiderman Web Gun"
SWEP.Spawnable = true
SWEP.AdminOnly = false
SWEP.UseHands = true
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = true
SWEP.ViewModel = "models/weapons/c_pistol.mdl"
SWEP.WorldModel = "models/weapons/w_pistol.mdl"
SWEP.Primary = {
    ClipSize = -1,
    DefaultClip = -1,
    Automatic = true,
    Ammo = "none"
}

SWEP.Secondary = {
    ClipSize = -1,
    DefaultClip = -1,
    Automatic = false,
    Ammo = "none"
}

local function ForwardRagdollDamage(ent, dmginfo)
    if not (ent:IsRagdoll() and IsValid(ent.original_npc)) then return end
    local npc = ent.original_npc
    local dmg = dmginfo:GetDamage()
    npc:SetHealth(math.max(0, npc:Health() - dmg))
    local force = dmginfo:GetDamageForce() or Vector(0, 0, 0)
    if not force:IsZero() then
        local physCount = ent:GetPhysicsObjectCount()
        for i = 0, physCount - 1 do
            local phys = ent:GetPhysicsObjectNum(i)
            if IsValid(phys) then phys:ApplyForceCenter(force) end
        end
    end
end

local function SpawnPickupRagdoll(npc)
    if not IsValid(npc) then return end
    -- 1) Create the ragdoll immediately
    local rag = ents.Create("prop_ragdoll")
    if not IsValid(rag) then return end
    rag:SetModel(npc:GetModel())
    rag:SetPos(npc:GetPos())
    rag:SetAngles(npc:GetAngles())
    rag:Spawn()
    rag:Activate()
    -- 2) Copy bones in a next-tick timer
    timer.Simple(0, function()
        if not (IsValid(npc) and IsValid(rag)) then return end
        if npc.SetupBones then npc:SetupBones() end
        for i = 0, (npc.GetBoneCount and npc:GetBoneCount() or 0) - 1 do
            local pos, ang = npc:GetBonePosition(i)
            if pos and ang and rag.SetBonePosition then rag:SetBonePosition(i, pos, ang) end
        end

        for i = 0, (rag.GetPhysicsObjectCount and rag:GetPhysicsObjectCount() or 0) - 1 do
            local phys = rag:GetPhysicsObjectNum(i)
            if IsValid(phys) then
                phys:EnableMotion(true)
                phys:Wake()
            end
        end
    end)

    -- 3) Fully disable & hide the original NPC
    rag.original_npc = npc
    rag.dropped_manually = false
    hook.Add("EntityTakeDamage", "ForwardRagdollDamage", ForwardRagdollDamage)
    npc:SetNoDraw(true)
    npc:SetNotSolid(true)
    npc:SetMoveType(MOVETYPE_NONE)
    npc:SetCollisionGroup(COLLISION_GROUP_VEHICLE)
    npc:ClearSchedule()
    if npc.StopMoving then npc:StopMoving() end
    -- **Silence AI & thinking completely**
    npc:AddEFlags(EFL_NO_THINK_FUNCTION) -- stops Think() calls
    if npc.SetNPCState then npc:SetNPCState(NPC_STATE_NONE) end
    npc:SetSaveValue("m_bInSchedule", false) -- stop any running schedule
    if npc.GetActiveWeapon and IsValid(npc:GetActiveWeapon()) then npc:GetActiveWeapon():Remove() end
    -- 4) On rag removal, restore or remove the NPC
    rag:CallOnRemove("cleanup_npc_" .. rag:EntIndex(), function()
        if not IsValid(npc) then return end
        -- re-enable thinking
        npc:RemoveEFlags(EFL_NO_THINK_FUNCTION)
        if rag.dropped_manually then
            -- Restore NPC at rag’s last pose
            local p, a = rag:GetPos(), rag:GetAngles()
            npc:SetPos(p)
            npc:SetAngles(a)
            npc:SetNoDraw(false)
            npc:SetNotSolid(false)
            npc:SetMoveType(MOVETYPE_STEP)
            npc:SetCollisionGroup(COLLISION_GROUP_NONE)
            npc:ClearSchedule()
            npc:SetSaveValue("m_bInSchedule", false)
            if npc.SetNPCState then npc:SetNPCState(NPC_STATE_ALERT) end
            npc:DropToFloor()
            -- Restart thinking/AI
            if npc.BehaveStart then pcall(npc.BehaveStart, npc) end
            npc:SetSchedule(SCHED_IDLE_STAND)
            npc:NextThink(CurTime())
        else
            -- Rag was gibbed: kill the NPC too
            npc:Remove()
        end

        hook.Remove("EntityTakeDamage", "ForwardRagdollDamage")
    end)
    return rag
end

local function IsRagdollGibbed(ent)
    -- 0) Missing or invalid entity → treat as gibbed
    if not IsValid(ent) then return true end
    -- 0) Zero HP is gibbed too
    local npc = ent.original_npc
    if IsValid(npc) and npc:Health() <= 0 then return true end
    -- 2) Look for Zippy’s health table, only if it exists
    local hpTable = ent.ZippyGoreMod3_PhysBoneHPs
    if type(hpTable) == "table" then
        for boneIndex, hp in pairs(hpTable) do
            if hp == -1 then return true end
        end
    end

    -- 3) Look for Zippy’s gib‑flag table, only if it exists
    local gibTable = ent.ZippyGoreMod3_GibbedPhysBones
    if type(gibTable) == "table" then
        for boneIndex, wasGibbed in pairs(gibTable) do
            if wasGibbed then return true end
        end
    end

    -- 4) If neither table is there, Zippy is disabled or not applied—assume “not gibbed”
    if hpTable == nil and gibTable == nil then return false end
    -- 5) Physics‐object count heuristic (only if we have a hpTable)
    if type(hpTable) == "table" then
        local expectedBones = table.Count(hpTable)
        if ent:GetPhysicsObjectCount() < expectedBones then return true end
    end
    -- No evidence of gibbing
    return false
end

function SWEP:Initialize()
    self:SetHoldType("pistol")
    self.IsSwinging = false
    self.IsPullingProp = false
    self.SwingStartTime = 0
    self.RopeEndPos = nil
end

function SWEP:Holster()
    self:EndSwing()
    self:EndPullProp()
    return true
end

function SWEP:OnRemove()
    self:EndSwing()
    self:EndPullProp()
end

function SWEP:Think()
    local ply = self:GetOwner()
    if not IsValid(ply) then return end
    if ply:KeyPressed(IN_ATTACK) then
        self:StartSwing()
    elseif ply:KeyDown(IN_ATTACK) and self.IsSwinging then
        self:ApplyPull()
    elseif ply:KeyReleased(IN_ATTACK) and self.IsSwinging then
        self:EndSwing()
    end

    if ply:KeyPressed(IN_ATTACK2) then
        self:StartPullProp()
    elseif ply:KeyDown(IN_ATTACK2) and self.IsPullingProp then
        self:ApplyPropPull()
    elseif ply:KeyReleased(IN_ATTACK2) and self.IsPullingProp then
        self:EndPullProp()
    end
end

function SWEP:DoTrace()
    local ply = self:GetOwner()
    return util.TraceLine({
        start = ply:GetShootPos(),
        endpos = ply:GetShootPos() + ply:GetAimVector() * 32768,
        filter = ply
    })
end

function SWEP:StartSwing()
    if not SERVER or self.IsSwinging then return end
    local tr = self:DoTrace()
    if not tr.Hit then return end
    self.IsSwinging = true
    self.IsPullingProp = false
    self.RopeEndPos = tr.HitPos
    self.SwingStartTime = CurTime()
    self:EmitSound("physics/plastic/plastic_box_impact_soft" .. math.random(1, 4) .. ".wav")
    net.Start("SpiderRope_HitPos")
    net.WriteBool(true) -- swing
    net.WriteVector(tr.HitPos)
    net.WriteEntity(NULL)
    net.Broadcast()
end

function SWEP:ApplyPull()
    if not SERVER or not self.IsSwinging then return end
    local ply = self:GetOwner()
    local pos = ply:GetPos() + Vector(0, 0, 36)
    local dir = (self.RopeEndPos - pos):GetNormalized()
    local dist = pos:Distance(self.RopeEndPos)
    local speed = GetConVar("spiderman_web_speed"):GetFloat()
    local strength = math.Clamp(dist / 1500, 0.8, 1.5)
    local timeSinceStart = math.max(0, CurTime() - (self.SwingStartTime or 0))
    local timeMultiplier = math.Clamp(timeSinceStart / 1.5, 0.2, 1.0) -- ramp up over 1.5s
    local force = dir * speed * strength * timeMultiplier
    force.z = force.z + math.abs(GetConVar("sv_gravity"):GetFloat()) * 0.2
    ply:SetVelocity(force - ply:GetVelocity() * 0.8)
end

function SWEP:EndSwing()
    if SERVER and self.IsSwinging then
        self.IsSwinging = false
        self.RopeEndPos = nil
        self:EmitSound("physics/plastic/plastic_box_impact_soft" .. math.random(1, 4) .. ".wav")
        net.Start("SpiderRope_Clear")
        net.Broadcast()
    end
end

function SWEP:StartPullProp()
    if not SERVER or self.IsPullingProp then return end
    local tr = self:DoTrace()
    local ent = tr.Entity
    if ent:IsNPC() then ent = SpawnPickupRagdoll(ent) end
    local phys = IsValid(ent) and ent:GetPhysicsObject()
    if not tr.Hit or not IsValid(ent) or not IsValid(phys) or not phys:IsMoveable() then return end
    self.IsPullingProp = true
    self.IsSwinging = false
    self.RopeEndPos = tr.HitPos
    ent.collision_group = ent:GetCollisionGroup()
    ent:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR)
    self.PullTarget = ent
    self:EmitSound("physics/flesh/flesh_impact_bullet" .. math.random(1, 5) .. ".wav")
    net.Start("SpiderRope_HitPos")
    net.WriteBool(false)
    net.WriteVector(tr.HitPos)
    net.WriteEntity(ent)
    net.Broadcast()
end

function SWEP:ApplyPropPull()
    if not SERVER or not self.IsPullingProp or not IsValid(self.PullTarget) then return end
    local ent = self.PullTarget
    local phys = ent:GetPhysicsObject()
    if not IsValid(phys) then
        self:EndPullProp()
        return
    end

    local ply = self:GetOwner()
    local target = ply:GetPos() + Vector(0, 0, 36)
    local pos = ent:GetPos()
    local dir = (target - pos):GetNormalized()
    local dist = pos:Distance(target)
    local speed = GetConVar("spiderman_web_speed"):GetFloat()
    local strength = math.Clamp(dist / 1500, 0.8, 1.5)
    local force = dir * speed * strength
    local upwardLift = Vector(0, 0, math.Clamp(dist * 0.1, 64, 256))
    phys:ApplyForceCenter(force + upwardLift)
end

function SWEP:EndPullProp()
    if SERVER and self.IsPullingProp then
        self.IsPullingProp = false
        local ent = self.PullTarget
        if IsValid(ent) and ent.original_npc then
            local npc = ent.original_npc
            if IsValid(npc) and not IsRagdollGibbed(ent) then
                ent.dropped_manually = true
                timer.Simple(2.0, function() if IsValid(ent) then ent:Remove() end end)
            else
                ent.dropped_manually = false
            end

            hook.Remove("EntityTakeDamage", "ForwardRagdollDamage")
        end

        timer.Simple(1.0, function() if IsValid(ent) then ent:SetCollisionGroup(ent.collision_group) end end)
        self.PullTarget = nil
        self:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(1, 4) .. ".wav")
        net.Start("SpiderRope_Clear")
        net.Broadcast()
    end
end

function SWEP:PrimaryAttack()
end

function SWEP:SecondaryAttack()
end

if CLIENT then
    net.Receive("SpiderRope_HitPos", function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then return end
        local isSwing = net.ReadBool()
        local vec = net.ReadVector()
        local ent = net.ReadEntity()
        wep.IsSwinging = isSwing
        wep.IsPullingProp = not isSwing
        wep.RopeEndPos = isSwing and vec or nil
        wep.PullTarget = IsValid(ent) and ent or nil
    end)

    net.Receive("SpiderRope_Clear", function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) then return end
        wep.RopeEndPos = nil
        wep.IsSwinging = false
        wep.IsPullingProp = false
        wep.PullTarget = nil
    end)
    -- hook.Add("PostDrawOpaqueRenderables", "DrawSpiderRopeBeam", function()
    --     local ply = LocalPlayer()
    --     local wep = ply:GetActiveWeapon()
    --     if not IsValid(wep) then return end
    --     local endPos
    --     if wep.IsSwinging and wep.RopeEndPos then
    --         endPos = wep.RopeEndPos
    --     elseif wep.IsPullingProp and IsValid(wep.PullTarget) then
    --         endPos = wep.PullTarget:GetPos()
    --     else
    --         return
    --     end
    --     local vm = ply:GetViewModel()
    --     local att = vm:GetAttachment(vm:LookupAttachment("muzzle") or 1)
    --     if not att then return end
    --     render.SetMaterial(Material("cable/rope"))
    --     render.DrawBeam(att.Pos, endPos, 1, 0, 1, Color(255, 255, 255, 255))
    -- end)
end