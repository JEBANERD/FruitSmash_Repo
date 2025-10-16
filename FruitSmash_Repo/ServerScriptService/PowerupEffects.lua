-- PowerupEffects (SERVER)
-- Handles: HealthPack, CoinBoost, Shield (self-contained, timed, lane-aware)

local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Modules = RS:WaitForChild("Modules")
local ShieldState = require(Modules:WaitForChild("ShieldState"))

local DEBUG_SHIELD = false

local function debugShield(...)
    if DEBUG_SHIELD then
        print("[PowerupEffects]", ...)
    end
end

type ShieldSession = {
    shield: BasePart?,
    touchedConn: RBXScriptConnection?,
    parentConn: RBXScriptConnection?,
    attrConn: RBXScriptConnection?,
    targetConn: RBXScriptConnection?,
    pulse: Tween?,
}

local activeShields: { [Instance]: ShieldSession } = {}

local M = {}

-- === CONFIG ===
local HEAL_AMOUNT        = 25
local COINBOOST_DURATION = 20
local SHIELD_DURATION    = 15

-- === Ensure Global Shield Flag ===
local TargetShieldFlag = RS:FindFirstChild("TargetShieldActive") :: BoolValue
if not TargetShieldFlag then
	TargetShieldFlag = Instance.new("BoolValue")
	TargetShieldFlag.Name = "TargetShieldActive"
	TargetShieldFlag.Value = false
	TargetShieldFlag.Parent = RS
end

-- === Target Helpers ===
local function getAllTargets(): { Model }
	local found = {}
	local lanes = Workspace:FindFirstChild("Lanes")
	if lanes then
		for _, lane in ipairs(lanes:GetChildren()) do
			local t = lane:FindFirstChild("Target")
			if t and t:IsA("Model") then
				table.insert(found, t)
			end
		end
	end
	local single = Workspace:FindFirstChild("Target")
	if single and single:IsA("Model") then
		table.insert(found, single)
	end
	return found
end

local function getHealthObjects(t: Model): (NumberValue?, NumberValue?)
	local health = t:FindFirstChild("Health")
	local max = t:FindFirstChild("MaxHealth")
	if health and max and health:IsA("NumberValue") and max:IsA("NumberValue") then
		return health, max
	end
	return nil, nil
end

-- === Global Helper: Clear Shields ===
local function teardownShield(target: Instance, session: ShieldSession?)
        local current = activeShields[target]
        if not current then
                ShieldState.Set(target, false)
                return
        end
        if session and current ~= session then
                return
        end

        activeShields[target] = nil

        if current.attrConn then
                current.attrConn:Disconnect()
                current.attrConn = nil
        end
        if current.parentConn then
                current.parentConn:Disconnect()
                current.parentConn = nil
        end
        if current.touchedConn then
                current.touchedConn:Disconnect()
                current.touchedConn = nil
        end
        if current.targetConn then
                current.targetConn:Disconnect()
                current.targetConn = nil
        end
        if current.pulse then
                current.pulse:Cancel()
                current.pulse = nil
        end
        if current.shield and current.shield.Parent then
                current.shield:Destroy()
        end
        current.shield = nil

        ShieldState.Set(target, false)
        debugShield("Shield cleared for", target.Name)

        if not next(activeShields) then
                TargetShieldFlag.Value = false
        end
end

local function clearAllShields()
        for target, session in pairs(activeShields) do
                teardownShield(target, session)
        end
        TargetShieldFlag.Value = false
        print("[PowerupEffects] 🛡️ All shields cleared (global + local).")
end

-- === Powerups ===
function M.ApplyHealthPack()
	local any = false
	for _, t in ipairs(getAllTargets()) do
		local h, max = getHealthObjects(t)
		if h and max then
			h.Value = math.clamp(h.Value + HEAL_AMOUNT, 0, max.Value)
			any = true
		end
	end
	return any
end

function M.ApplyCoinBoost(plr: Player?)
	if not (plr and plr.Parent) then return false end
	local mult = plr:GetAttribute("CoinsMultiplier") or 1
	if mult < 2 then
		plr:SetAttribute("CoinsMultiplier", 2)
	end
	task.delay(COINBOOST_DURATION, function()
		if plr and plr.Parent then
			if (plr:GetAttribute("CoinsMultiplier") or 1) <= 2 then
				plr:SetAttribute("CoinsMultiplier", 1)
			end
		end
	end)
	return true
end

-- === Shield Powerup (Self-contained) ===
function M.ApplyShield()
        local targets = getAllTargets()
        if #targets == 0 then
                warn("[PowerupEffects] No targets found for Shield.")
                return false
        end

        -- 🔛 Activate global flag
        TargetShieldFlag.Value = true
        print("[PowerupEffects] 🛡️ Shield activated for all targets (" .. tostring(SHIELD_DURATION) .. "s).")

        for _, target in ipairs(targets) do
                local primary = target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart")
                if not primary then continue end

                teardownShield(target)

                local session: ShieldSession = {}
                activeShields[target] = session

                ShieldState.Set(target, true)
                debugShield("Shield enabled for", target.Name)

                session.attrConn = target:GetAttributeChangedSignal("ShieldActive"):Connect(function()
                        if not ShieldState.Get(target) then
                                teardownShield(target, session)
                        end
                end)

                session.targetConn = target.AncestryChanged:Connect(function(_, parent)
                        if not parent then
                                teardownShield(target, session)
                        end
                end)

                -- Get bounds for bubble sizing
                local _, size = target:GetBoundingBox()
                local maxDimension = math.max(size.X, size.Y, size.Z)
                local radius = maxDimension * 2.2
		
		-- Create bubble
local shield = Instance.new("Part")
                shield.Name = "TargetShieldBubble"
                shield.Shape = Enum.PartType.Ball
                shield.Material = Enum.Material.ForceField
                shield.Color = Color3.fromRGB(0, 200, 255)
                shield.Transparency = 0.3
                shield.Anchored = true
                shield.CanCollide = true
                shield.CanTouch = true
                shield.CanQuery = true
                shield.Size = Vector3.new(radius, radius, radius)
                local cf, _ = target:GetBoundingBox()
                shield.CFrame = cf
                shield.Parent = target

                local weld = Instance.new("WeldConstraint")
                weld.Part0 = primary
                weld.Part1 = shield
                weld.Parent = shield

                session.parentConn = shield:GetPropertyChangedSignal("Parent"):Connect(function()
                        if not shield.Parent then
                                teardownShield(target, session)
                        end
                end)

                -- Destroy fruits that hit the bubble
                session.touchedConn = shield.Touched:Connect(function(hit)
                        local projFolder = Workspace:FindFirstChild("ActiveProjectiles")
                        if projFolder and hit:IsDescendantOf(projFolder) then
                                local container = hit:FindFirstAncestorOfClass("Model") or hit
                                if container and container:IsDescendantOf(projFolder) then
                                        container:Destroy()
                                end
                        end
                end)

                -- Pulse animation
                local tweenInfo = TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
                local pulse = TweenService:Create(shield, tweenInfo, { Transparency = 0.55 })
                pulse:Play()
                session.pulse = pulse
                session.shield = shield

                task.delay(SHIELD_DURATION, function()
                        if activeShields[target] == session then
                                teardownShield(target, session)
                        end
                end)

                Debris:AddItem(shield, SHIELD_DURATION + 1)
        end

        return true
end

function M.ClearAllShields()
        clearAllShields()
end

-- === Router ===
function M.ApplyPowerup(powerupType: string?, plr: Player?)
	local t = (powerupType or ""):lower()
	if t == "healthpack" or t == "health" then
		return M.ApplyHealthPack()
	elseif t == "coinboost" or t == "coinx2" or t == "doublecoins" then
		return M.ApplyCoinBoost(plr)
	elseif t == "shield" then
		return M.ApplyShield()
	else
		warn("[PowerupEffects] Unknown powerup:", powerupType)
		return false
	end
end

return M

