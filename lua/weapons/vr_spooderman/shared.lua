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
                self:StartSwing(ply, hand)
            else
                self:ApplyPull(ply, hand)
            end
        elseif state.isSwinging then
            self:EndSwing(hand)
        end

        if not fire and pull and not isHoldingRight then
            if not state.isPullingProp then
                self:StartPullProp(ply, hand)
            else
                self:ApplyPropPull(ply, hand)
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
                self:StartSwing(ply, hand)
            else
                self:ApplyPull(ply, hand)
            end
        elseif state.isSwinging then
            self:EndSwing(hand)
        end

        if not fire and pull and not isHoldingLeft then
            if not state.isPullingProp then
                self:StartPullProp(ply, hand)
            else
                self:ApplyPropPull(ply, hand)
            end
        elseif state.isPullingProp then
            self:EndPullProp(hand)
        end
    end
end

function SWEP:DoTrace(ply, hand)
    return vrmod.utils.TraceHand(ply, hand)
end

function SWEP:StartSwing(ply, hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    if state.isSwinging then return end
    local tr = self:DoTrace(ply, hand)
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

function SWEP:ApplyPull(ply, hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    if not state or not state.isSwinging or not state.ropeEndPos then return end
    local isLeft = hand == "left"
    local handPos = isLeft and vrmod.GetLeftHandPos(ply) or vrmod.GetRightHandPos(ply)
    local handVel = isLeft and vrmod.GetLeftHandVelocityRelative(ply) or vrmod.GetRightHandVelocityRelative(ply)
    local ang = isLeft and vrmod.GetLeftHandAng(ply) or vrmod.GetRightHandAng(ply)
    if isLeft then
        ang = Angle(ang.p, ang.y, ang.r + 180) -- compensate left hand angle
    end

    local handFwd = ang:Forward()
    local ropePos = state.ropeEndPos
    -- Step 1: Wait for valid pull gesture
    if not state.hasStartedPull then
        local pullDir = (handPos - ropePos):GetNormalized()
        local projected = handVel:Dot(pullDir)
        if projected > 5 then
            state.hasStartedPull = true
            state.initialPullForce = projected
            state.swingStartTime = CurTime()
        else
            return
        end
    end

    -- Step 2: Calculate pull force vector blending rope direction & hand forward
    local playerPos = ply:GetPos() + Vector(0, 0, 36) -- approximate eye height
    local toRopeDir = (ropePos - playerPos):GetNormalized()
    local blendWeight = 0.6
    local pullDir = (toRopeDir * (1 - blendWeight) + handFwd * blendWeight):GetNormalized()
    local baseSpeed = GetConVar("spiderman_web_speed_vr"):GetFloat()
    local elapsed = CurTime() - (state.swingStartTime or 0)
    local ramp = math.min(elapsed / 0.5, 1.0)
    local forceMag = baseSpeed * state.initialPullForce / 50 * ramp
    local force = pullDir * forceMag
    -- Step 3: Apply jump impulse only if on ground and vertical force is insufficient
    local minLiftHeight = 50
    local velocity = ply:GetVelocity()
    if ply:OnGround() and ply:GetPos().z < minLiftHeight and force.z < 20 then
        ply:DoAnimationEvent(ACT_HL2MP_JUMP)
        ply:SetGroundEntity(NULL)
        velocity.z = 250 -- forced jump velocity
        -- Add horizontal pull force components without overwriting vertical jump
        velocity.x = velocity.x + force.x
        velocity.y = velocity.y + force.y
        ply:SetVelocity(velocity)
    else
        -- Airborne or sufficient vertical force, just add full force normally
        ply:SetVelocity(force)
    end
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

function SWEP:StartPullProp(ply, hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    if state.isPullingProp then return end
    local tr = self:DoTrace(ply, hand)
    local ent = tr.Entity
    if not tr.Hit or not IsValid(ent) then return end
    if ent:IsNPC() then ent = vrmod.utils.SpawnPickupRagdoll(ent) end
    if ent:GetClass() == "prop_ragdoll" then vrmod.utils.SetBoneMass(ent, 15, 0.5) end
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

function SWEP:ApplyPropPull(ply, hand)
    if not SERVER then return end
    local state = self.HandStates[hand]
    local ent = state.pullTarget
    if not state.isPullingProp or not IsValid(ent) then return end
    local phys = ent:GetPhysicsObject()
    if not IsValid(phys) then
        self:EndPullProp(hand)
        return
    end

    local isLeft = hand == "left"
    local handPos = isLeft and vrmod.GetLeftHandPos(ply) or vrmod.GetRightHandPos(ply)
    local handVel = isLeft and vrmod.GetLeftHandVelocity(ply) or vrmod.GetRightHandVelocity(ply)
    local handAng = isLeft and vrmod.GetLeftHandAng(ply) or vrmod.GetRightHandAng(ply)
    local entPos = ent:GetPos()
    local dist = entPos:Distance(handPos)
    -- Close enough: snap it to hand
    if dist < 50 then
        if isLeft then handAng = Angle(handAng.p, handAng.y, handAng.r + 180) end
        local offset = handAng:Forward() * 25
        local adjustedPos = handPos + offset
        ent:SetPos(adjustedPos)
        phys:SetVelocityInstantaneous(Vector(0, 0, 0))
        local sid = ply:SteamID()
        if g_VR[sid] and g_VR[sid].heldItems and not g_VR[sid].heldItems[isLeft and 1 or 2] then
            ent:SetCollisionGroup(ent.collision_group or COLLISION_GROUP_NONE)
            vrmod.Pickup(ply, isLeft, ent)
        end

        self:EndPullProp(hand)
        return
    end

    -- Step 1: Gesture detection
    if not state.hasStartedPull then
        local pullDir = (handPos - entPos):GetNormalized()
        local projected = handVel:Dot(pullDir)
        if projected > 10 then
            state.hasStartedPull = true
            state.initialPullForce = projected
            state.pullStartTime = CurTime()
        else
            return
        end
    end

    -- Step 2: Compute force with hand angle influence
    if isLeft then handAng = Angle(handAng.p, handAng.y, handAng.r + 180) end
    local handFwd = handAng:Forward()
    local dirToHand = (handPos - entPos):GetNormalized()
    local blendWeight = 0.6
    local aimInfluence = math.Clamp(dirToHand:Dot(handFwd), 0, 1)
    local pullDir = (dirToHand * (1 - blendWeight) + handFwd * blendWeight * aimInfluence):GetNormalized()
    local baseSpeed = GetConVar("spiderman_web_speed_vr"):GetFloat()
    local timeSinceStart = CurTime() - (state.pullStartTime or 0)
    local ramp = math.min(timeSinceStart / 0.5, 1.0)
    local forceMag = baseSpeed * state.initialPullForce / 5 * ramp
    local dynamicForce = pullDir * forceMag
    phys:ApplyForceCenter(dynamicForce)
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
    if IsValid(ent) and not ent.picked then
        if ent.original_npc then
            local npc = ent.original_npc
            if IsValid(npc) and not vrmod.utils.IsRagdollDead(ent) then
                ent.dropped_manually = true
                vrmod.utils.SetBoneMass(ent, 100, 5)
                timer.Simple(2.0, function() if IsValid(ent) then ent:Remove() end end)
            else
                ent.dropped_manually = false
            end
        end

        if ent:GetClass() == "prop_ragdoll" then vrmod.utils.SetBoneMass(ent, 50, 2.5) end
        timer.Simple(0.2, function() ent:SetCollisionGroup(ent.collision_group or COLLISION_GROUP_NONE) end)
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