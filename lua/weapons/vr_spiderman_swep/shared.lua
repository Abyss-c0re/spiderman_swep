g_VR = g_VR or {}
local inputsToSend = {"boolean_primaryfire", "boolean_secondaryfire", "boolean_left_pickup", "boolean_right_pickup"}
local vr_input_states = {}
if SERVER then
    AddCSLuaFile()
    net.Receive("SpiderRope_VRInput", function(_, ply)
        if not IsValid(ply) then return end
        local action = net.ReadString()
        local pressed = net.ReadBool()
        vr_input_states[ply] = vr_input_states[ply] or {}
        vr_input_states[ply][action] = pressed
    end)
end

SWEP.Author = "Doom Slayer"
SWEP.Purpose = "Swing like Spider-Man!"
SWEP.Instructions = "Left-click to swing. Right-click to pull props/NPCs."
SWEP.Category = "Spider-Man"
SWEP.PrintName = "VR:Spiderman Web Gun"
SWEP.Spawnable = true
SWEP.AdminOnly = false
SWEP.UseHands = true
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = false
SWEP.ViewModel = "models/weapons/c_arms.mdl"
SWEP.WorldModel = ""
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

function SWEP:Initialize()
    self.undroppable = true
    self.HandStates = {
        left = {
            isSwinging = false,
            isPullingProp = false,
            ropeEndPos = nil,
            swingStartTime = 0,
            pullTarget = nil
        },
        right = {
            isSwinging = false,
            isPullingProp = false,
            ropeEndPos = nil,
            swingStartTime = 0,
            pullTarget = nil
        }
    }
end

function SWEP:CleanupAllWebStates()
    for _, hand in ipairs({"left", "right"}) do
        self:EndSwing(hand)
        self:EndPullProp(hand)
    end
end

function SWEP:Holster()
    self:CleanupAllWebStates()
    return true
end

function SWEP:OnRemove()
    self:CleanupAllWebStates()
end

function SWEP:Think()
    if CLIENT then return end
    local ply = self:GetOwner()
    if not IsValid(ply) then return end
    local inputs = vr_input_states[ply] or {}
    -- Right hand logic
    do
        local hand = "right"
        local state = self.HandStates[hand]
        local fire = inputs["boolean_primaryfire"]
        local pull = inputs["boolean_right_pickup"]
        if fire and not pull then
            if not state.isSwinging then
                self:StartSwing(hand)
            else
                self:ApplyPull(hand)
            end
        elseif state.isSwinging then
            self:EndSwing(hand)
        end

        if fire and pull then
            if not state.isPullingProp then
                self:StartPullProp(hand)
            else
                self:ApplyPropPull(hand)
            end
        elseif state.isPullingProp then
            self:EndPullProp(hand)
        end
    end

    -- Left hand logic
    do
        local hand = "left"
        local state = self.HandStates[hand]
        local fire = inputs["boolean_secondaryfire"]
        local pull = inputs["boolean_left_pickup"]
        if fire and not pull then
            if not state.isSwinging then
                self:StartSwing(hand)
            else
                self:ApplyPull(hand)
            end
        elseif state.isSwinging then
            self:EndSwing(hand)
        end

        if fire and pull then
            if not state.isPullingProp then
                self:StartPullProp(hand)
            else
                self:ApplyPropPull(hand)
            end
        elseif state.isPullingProp then
            self:EndPullProp(hand)
        end
    end
end

local function HitFilter(ent, ply, hand)
    if not IsValid(ent) then return true end
    if ent == ply then return false end
    if ent:GetNWBool("isVRHand", false) then return false end
    if IsValid(ply) and (hand == "left" or hand == "right") then
        local held = vrmod.GetHeldEntity(ply, hand)
        if IsValid(held) and held == ent then return false end
    end
    return true
end

function SWEP:DoTrace(hand)
    if CLIENT then return end
    local ply = self:GetOwner()
    local startPos, ang, dir
    if hand == "left" then
        startPos = vrmod.GetLeftHandPos(ply)
        ang = vrmod.GetLeftHandAng(ply)
        local ang2 = Angle(ang.p, ang.y, ang.r + 180)
        dir = ang2:Forward()
    else
        startPos = vrmod.GetRightHandPos(ply)
        ang = vrmod.GetRightHandAng(ply)
        dir = ang:Forward()
    end

    local ignore = {}
    local maxDepth = 10
    for i = 1, maxDepth do
        local tr = util.TraceLine({
            start = startPos,
            endpos = startPos + dir * 32768,
            filter = ignore
        })

        if not tr.Entity or not IsValid(tr.Entity) then return tr end
        if HitFilter(tr.Entity, ply, hand) then
            return tr
        else
            table.insert(ignore, tr.Entity)
            startPos = tr.HitPos + dir * 1 -- Avoid infinite loops on same surface
        end
    end
    return nil -- Nothing valid hit after maxDepth
end

function SWEP:StartSwing(hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    if state.isSwinging then return end
    local tr = self:DoTrace(hand)
    if not tr.Hit then return end
    -- local targetName = IsValid(tr.Entity) and (tr.Entity:GetName() ~= "" and tr.Entity:GetName() or tr.Entity:GetClass()) or "World"
    -- print(hand .. " hit " .. targetName)
    state.isSwinging = true
    state.isPullingProp = false
    state.ropeEndPos = tr.HitPos
    state.swingStartTime = CurTime()
    state.pullTarget = nil
    self:EmitSound("physics/plastic/plastic_box_impact_soft" .. math.random(1, 4) .. ".wav")
    net.Start("VR_SpiderRope_HitPos")
    net.WriteString(hand)
    net.WriteBool(true)
    net.WriteVector(tr.HitPos)
    net.WriteEntity(NULL)
    net.Broadcast()
end

function SWEP:ApplyPull(hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    if not state or not state.isSwinging or not state.ropeEndPos then return end
    local ply = self:GetOwner()
    local pos = ply:GetPos() + Vector(0, 0, 36)
    local dir = (state.ropeEndPos - pos):GetNormalized()
    local dist = pos:Distance(state.ropeEndPos)
    local speed = GetConVar("spiderman_web_speed"):GetFloat()
    local strength = math.Clamp(dist / 1500, 0.8, 1.5)
    local timeSinceStart = math.max(0, CurTime() - (state.swingStartTime or 0))
    local timeMultiplier = math.Clamp(timeSinceStart / 1.5, 0.2, 1.0)
    local force = dir * speed * strength * timeMultiplier
    force.z = force.z + math.abs(GetConVar("sv_gravity"):GetFloat()) * 0.2
    ply:SetVelocity(force - ply:GetVelocity() * 0.8)
end

function SWEP:EndSwing(hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    if not state or not state.isSwinging then return end
    state.isSwinging = false
    state.ropeEndPos = nil
    state.swingStartTime = nil
    self:EmitSound("physics/plastic/plastic_box_impact_soft" .. math.random(1, 4) .. ".wav")
    net.Start("VR_SpiderRope_Clear")
    net.WriteString(hand)
    net.Broadcast()
end

function SWEP:StartPullProp(hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    if state.isPullingProp then return end
    local tr = self:DoTrace(hand)
    local ent = tr.Entity
    if not tr.Hit or not IsValid(ent) then return end
    if ent:IsNPC() then ent = vrmod.utils.SpawnPickupRagdoll(ent) end
    local phys = ent:GetPhysicsObject()
    if not IsValid(phys) or not phys:IsMoveable() then return end
    state.isPullingProp = true
    state.isSwinging = false
    state.ropeEndPos = tr.HitPos
    state.swingStartTime = CurTime()
    state.pullTarget = ent
    ent.collision_group = ent:GetCollisionGroup()
    ent:SetCollisionGroup(COLLISION_GROUP_PASSABLE_DOOR)
    self:EmitSound("physics/flesh/flesh_impact_bullet" .. math.random(1, 5) .. ".wav")
    net.Start("VR_SpiderRope_HitPos")
    net.WriteString(hand)
    net.WriteBool(false)
    net.WriteVector(ent:GetPos())
    net.WriteEntity(ent)
    net.Broadcast()
end

function SWEP:ApplyPropPull(hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    local ent = state.pullTarget
    if not state.isPullingProp or not IsValid(ent) then return end
    local phys = ent:GetPhysicsObject()
    if not IsValid(phys) then
        self:EndPullProp(hand)
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

function SWEP:EndPullProp(hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    if not state.isPullingProp then return end
    state.isPullingProp = false
    local ent = state.pullTarget
    if IsValid(ent) and ent.original_npc then
        local npc = ent.original_npc
        if IsValid(npc) and not vrmod.utils.IsRagdollGibbed(ent) then
            ent.dropped_manually = true
            timer.Simple(2.0, function() if IsValid(ent) then ent:Remove() end end)
        else
            ent.dropped_manually = false
        end
    end

    if IsValid(ent) then timer.Simple(1.0, function() if IsValid(ent) then ent:SetCollisionGroup(ent.collision_group or COLLISION_GROUP_NONE) end end) end
    state.pullTarget = nil
    self:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(1, 4) .. ".wav")
    net.Start("VR_SpiderRope_Clear")
    net.WriteString(hand)
    net.Broadcast()
end

function SWEP:PrimaryAttack()
end

function SWEP:SecondaryAttack()
end

if CLIENT then
    net.Receive("VR_SpiderRope_HitPos", function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) or wep:GetClass() ~= "vr_spiderman_swep" then return end
        local hand = net.ReadString()
        local isSwing = net.ReadBool()
        local vec = net.ReadVector()
        local ent = net.ReadEntity()
        wep.HandStates = wep.HandStates or {}
        local state = wep.HandStates[hand] or {}
        state.isSwinging = isSwing
        state.isPullingProp = not isSwing
        state.ropeEndPos = isSwing and vec or nil
        state.pullTarget = IsValid(ent) and ent or nil
        wep.HandStates[hand] = state
    end)

    net.Receive("VR_SpiderRope_Clear", function()
        local wep = LocalPlayer():GetActiveWeapon()
        if not IsValid(wep) or wep:GetClass() ~= "vr_spiderman_swep" then return end
        local hand = net.ReadString()
        if not hand then return end
        wep.HandStates = wep.HandStates or {}
        local state = wep.HandStates[hand] or {}
        state.isSwinging = false
        state.isPullingProp = false
        state.ropeEndPos = nil
        state.pullTarget = nil
        wep.HandStates[hand] = state
    end)

    hook.Add("VRMod_Input", "SpiderRope_VRInput", function(action, pressed)
        local wep = LocalPlayer():GetActiveWeapon()
        if not g_VR or not g_VR.active or g_VR.menuFocus then return end
        if not IsValid(wep) or wep:GetClass() ~= "vr_spiderman_swep" then return end
        if not table.HasValue(inputsToSend, action) then return end
        net.Start("SpiderRope_VRInput")
        net.WriteString(action)
        net.WriteBool(pressed)
        net.SendToServer()
    end)
end