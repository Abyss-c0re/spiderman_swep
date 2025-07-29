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
SWEP.Instructions = "Trigger to swing. Grab to pull props/NPCs."
SWEP.Category = "Spooderman"
SWEP.PrintName = "VR Spooderman"
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
            hasStartedPull = false,
            initialPullForce = nil,
            pullStartTime = nil,
            ropeEndPos = nil,
            swingStartTime = 0,
            pullTarget = nil
        },
        right = {
            isSwinging = false,
            isPullingProp = false,
            hasStartedPull = false,
            initialPullForce = nil,
            pullStartTime = nil,
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
    local sid = ply:SteamID()
    if not IsValid(ply) then return end
    local inputs = vr_input_states[ply] or {}
    -- Right hand logic
    do
        local hand = "right"
        local isHoldingRight = g_VR[sid] and g_VR[sid].heldItems and g_VR[sid].heldItems[2] ~= nil
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

        if not fire and pull and not isHoldingRight then
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
        local isHoldingLeft = g_VR[sid] and g_VR[sid].heldItems and g_VR[sid].heldItems[1] ~= nil
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

        if not fire and pull and not isHoldingLeft then
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
    self:EmitSound("physics/flesh/flesh_impact_bullet" .. math.random(1, 5) .. ".wav")
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
    local isLeft = hand == "left"
    local handPos = isLeft and vrmod.GetLeftHandPos(ply) or vrmod.GetRightHandPos(ply)
    local handVel = isLeft and vrmod.GetLeftHandVelocityRelative(ply) or vrmod.GetRightHandVelocityRelative(ply)
    local ropePos = state.ropeEndPos
    -- Step 1: Wait for pull gesture
    if not state.hasStartedPull then
        local pullDir = (handPos - ropePos):GetNormalized()
        local projected = handVel:Dot(pullDir)
        --print(hand .. " hand swing projected: " .. projected) -- debug
        if projected > 5 then -- pulled hand fast enough away from wall
            state.hasStartedPull = true
            state.initialPullForce = projected
            state.swingStartTime = CurTime()
        else
            return -- wait for valid gesture
        end
    end

    -- Step 2: Pull has started, apply force
    local playerPos = ply:GetPos() + Vector(0, 0, 36) -- eye-level
    local dir = (ropePos - playerPos):GetNormalized()
    local baseSpeed = GetConVar("spiderman_web_speed"):GetFloat()
    local timeSinceStart = CurTime() - (state.swingStartTime or 0)
    local rampFactor = math.min(timeSinceStart / 0.5, 1.0)
    local dynamicForce = dir * baseSpeed * state.initialPullForce / 50 * rampFactor
    -- Add lift to counter gravity, slight boost
    dynamicForce.z = dynamicForce.z + math.abs(GetConVar("sv_gravity"):GetFloat()) * 0.05
    -- Apply: velocity corrected to avoid stacking
    ply:SetVelocity(dynamicForce)
end

function SWEP:EndSwing(hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    if not state or not state.isSwinging then return end
    state.isSwinging = false
    state.ropeEndPos = nil
    state.swingStartTime = nil
    state.hasStartedPull = false
    state.initialPullForce = projected
    self:EmitSound("physics/flesh/flesh_squishy_impact_hard" .. math.random(1, 4) .. ".wav")
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
    self:EmitSound("physics/plastic/plastic_box_impact_soft" .. math.random(1, 4) .. ".wav")
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
    local isLeft = hand == "left"
    local handPos = isLeft and vrmod.GetLeftHandPos(ply) or vrmod.GetRightHandPos(ply)
    local handVel = isLeft and vrmod.GetLeftHandVelocity(ply) or vrmod.GetRightHandVelocity(ply)
    local entPos = ent:GetPos()
    local dist = entPos:Distance(handPos)
    -- Close enough? Snap to hand
    if dist < 50 then
        local handAng = isLeft and vrmod.GetLeftHandAng(ply) or vrmod.GetRightHandAng(ply)
        local offset = handAng:Forward() * 20
        local adjustedPos = handPos + offset
        ent:SetPos(adjustedPos)
        phys:SetVelocityInstantaneous(Vector(0, 0, 0))
        local sid = ply:SteamID()
        if g_VR[sid] and g_VR[sid].heldItems and not g_VR[sid].heldItems[isLeft and 1 or 2] then
            ent:SetCollisionGroup(ent.collision_group or COLLISION_GROUP_NONE)
            ent.picked = true
            vrmod.Pickup(ply, isLeft, ent)
        end

        self:EndPullProp(hand)
        return
    end

    -- If not started, wait for pull gesture
    if not state.hasStartedPull then
        local pullDir = (handPos - entPos):GetNormalized()
        local projected = handVel:Dot(pullDir)
        --print(hand .. " hand projected: " .. projected) -- positive = pulling away from prop
        if projected > 10 then -- Player pulled hand away fast enough
            state.hasStartedPull = true
            state.initialPullForce = projected
            state.pullStartTime = CurTime()
        else
            return -- not pulling yet
        end
    end

    -- Pull has started, compute force
    local timeSinceStart = CurTime() - (state.pullStartTime or 0)
    local rampFactor = math.min(timeSinceStart / 0.5, 1) -- ramp up over 0.5s
    local dir = (handPos - entPos):GetNormalized()
    local baseSpeed = GetConVar("spiderman_web_speed"):GetFloat()
    local dynamicForce = dir * baseSpeed * state.initialPullForce / 10 * rampFactor
    local upwardLift = Vector(0, 0, math.Clamp(dist * 0.1, 64, 256))
    phys:ApplyForceCenter(dynamicForce + upwardLift)
end

function SWEP:EndPullProp(hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    if not state.isPullingProp then return end
    state.isPullingProp = false
    state.hasStartedPull = false
    state.initialPullForce = nil
    state.pullStartTime = nil
    local ent = state.pullTarget
    if not ent.picked then
        if IsValid(ent) and ent.original_npc then
            local npc = ent.original_npc
            if IsValid(npc) and not vrmod.utils.IsRagdollGibbed(ent) then
                ent.dropped_manually = true
                timer.Simple(2.0, function() if IsValid(ent) then ent:Remove() end end)
            else
                ent.dropped_manually = false
            end
        end

        if IsValid(ent) then timer.Simple(0.2, function() if IsValid(ent) then ent:SetCollisionGroup(ent.collision_group or COLLISION_GROUP_NONE) end end) end
    end

    state.pullTarget = nil
    self:EmitSound("physics/plastic/plastic_box_impact_soft" .. math.random(1, 4) .. ".wav")
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
        if not IsValid(wep) or wep:GetClass() ~= "vr_spooderman" then return end
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
        if not IsValid(wep) or wep:GetClass() ~= "vr_spooderman" then return end
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
        if not IsValid(wep) or wep:GetClass() ~= "vr_spooderman" then return end
        if not table.HasValue(inputsToSend, action) then return end
        net.Start("SpiderRope_VRInput")
        net.WriteString(action)
        net.WriteBool(pressed)
        net.SendToServer()
    end)
end