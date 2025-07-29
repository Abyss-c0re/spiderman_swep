if SERVER then
    AddCSLuaFile()
    CreateConVar("spiderman_web_speed", "100", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Web pull speed", 100, 3000)
    util.AddNetworkString("SpiderRope_HitPos")
    util.AddNetworkString("SpiderRope_Clear")
    util.AddNetworkString("VR_SpiderRope_HitPos")
    util.AddNetworkString("VR_SpiderRope_Clear")
    util.AddNetworkString("SpiderRope_VRInput")
end

if CLIENT then
    hook.Add("InitPostEntity", "SetupUnifiedSpiderRopeHook", function()
        hook.Add("PostDrawOpaqueRenderables", "UnifiedDrawSpiderRopeBeam", function()
            local ply = LocalPlayer()
            local wep = ply:GetActiveWeapon()
            if not IsValid(wep) then return end
            local class = wep:GetClass()
            if class ~= "spooderman_swep" and class ~= "vr_spooderman" then return end
            --print("[SpiderRope] Unified hook active for", class, g_VR and g_VR.active)
            if g_VR and g_VR.active then
                for _, hand in ipairs({"left", "right"}) do
                    local state = wep.HandStates and wep.HandStates[hand]
                    if not state then continue end
                    local startPos = hand == "right" and vrmod.GetRightHandPos() or vrmod.GetLeftHandPos()
                    local endPos = state.isSwinging and state.ropeEndPos or IsValid(state.pullTarget) and state.pullTarget:GetPos()
                    if endPos then
                        render.SetMaterial(Material("sprites/xbeam2"))
                        render.DrawBeam(startPos, endPos, 1, 0, 1, Color(255, 255, 255, 255))
                    end
                end
            else
                local endPos
                if wep.IsSwinging and wep.RopeEndPos then
                    endPos = wep.RopeEndPos
                elseif wep.IsPullingProp and IsValid(wep.PullTarget) then
                    endPos = wep.PullTarget:GetPos()
                else
                    return
                end

                local vm = ply:GetViewModel()
                if not IsValid(vm) then return end
                local att = vm:GetAttachment(vm:LookupAttachment("muzzle") or 1)
                if not att then return end
                render.SetMaterial(Material("sprites/xbeam2"))
                render.DrawBeam(att.Pos, endPos, 1, 0, 1, Color(255, 255, 255, 255))
            end
        end)
    end)
end