-- HealthController (SERVER)
-- Blocks and reverts damage while ShieldActive = true.
-- Syncs with global TargetShieldActive flag. Cleans up shield bubbles when off.
-- Updates health bar UI and triggers GameOver when HP <= 0.

local target: Instance = script.Parent
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Required children
local hitbox: BasePart = target:WaitForChild("Hitbox")
local maxHealth: NumberValue = target:WaitForChild("MaxHealth")
local health: NumberValue = target:WaitForChild("Health")

-- Optional global pause
local Remotes = RS:FindFirstChild("Remotes")
local GameOverEvent = Remotes and Remotes:FindFirstChild("GameOverEvent")
local GameActive: BoolValue? = RS:FindFirstChild("GameActive") :: BoolValue?

-- ========= GLOBAL SHIELD FLAG =========
-- This is the master toggle shared across all lanes and turrets.
local TargetShieldFlag: BoolValue = RS:FindFirstChild("TargetShieldActive") :: BoolValue
if not TargetShieldFlag then
	TargetShieldFlag = Instance.new("BoolValue")
	TargetShieldFlag.Name = "TargetShieldActive"
	TargetShieldFlag.Value = false
	TargetShieldFlag.Parent = RS
end

-- ========= LOCAL SHIELD FLAG DYNAMIC BINDING =========
-- Auto-reconnects if ShieldActive BoolValue is replaced or re-added.
local shieldFlag: BoolValue? = target:FindFirstChild("ShieldActive")
local shieldConn: RBXScriptConnection?

local function connectShieldFlag(flag: BoolValue)
	if shieldConn then
		shieldConn:Disconnect()
	end
	shieldFlag = flag
	if flag then
		print("[HealthController] Connected ShieldActive for", target.Name)
		shieldConn = flag:GetPropertyChangedSignal("Value"):Connect(function()
			print(string.format("[HealthController] ShieldActive changed for %s → %s", target.Name, tostring(flag.Value)))
		end)
	end
end

-- Watch for ShieldActive being dynamically created or removed
target.ChildAdded:Connect(function(child)
	if child.Name == "ShieldActive" and child:IsA("BoolValue") then
		connectShieldFlag(child)
	end
end)
target.ChildRemoved:Connect(function(child)
	if child == shieldFlag then
		shieldFlag = nil
		print("[HealthController] ShieldActive removed for", target.Name)
	end
end)

-- Ensure ShieldActive exists on startup
if shieldFlag then
	connectShieldFlag(shieldFlag)
else
	local flag = Instance.new("BoolValue")
	flag.Name = "ShieldActive"
	flag.Value = false
	flag.Parent = target
	connectShieldFlag(flag)
end

-- ========= OPTIONAL UI =========
local gui = hitbox:FindFirstChild("HealthGui")
local barBg = gui and gui:FindFirstChild("BarBg")
local barFill = barBg and barBg:FindFirstChild("BarFill")
local label = barBg and barBg:FindFirstChild("HPLabel")

-- ========= HELPERS =========
local function updateBar()
	if barFill and barFill:IsA("Frame") then
		local ratio = math.clamp(health.Value / math.max(1e-6, maxHealth.Value), 0, 1)
		barFill.Size = UDim2.fromScale(ratio, 1)
		barFill.BackgroundColor3 = Color3.new(1 - ratio, ratio, 0)
	end
	if label and label:IsA("TextLabel") then
		label.Text = string.format("%d / %d", math.floor(health.Value + 0.5), maxHealth.Value)
	end
end

local function flash(color: Color3, dur: number)
	local original = hitbox.Color
	hitbox.Color = color
	TweenService:Create(hitbox, TweenInfo.new(math.max(0.05, dur or 0.15)), {Color = original}):Play()
end

-- Removes any existing shield bubbles for this target
local function destroyShieldBubbles()
	for _, d in ipairs(target:GetChildren()) do
		if d:IsA("BasePart") and d.Name == "TargetShieldBubble" then
			d:Destroy()
		end
	end
end

-- ========= INIT =========
if health.Value <= 0 then
	health.Value = maxHealth.Value
end
hitbox.Transparency = 0.99
updateBar()

-- Track last valid health
local lastSafe = health.Value
local reverting = false

-- ========= GLOBAL → LOCAL MIRROR =========
-- When TargetShieldActive flips, mirror it to local ShieldActive
TargetShieldFlag.Changed:Connect(function()
	if TargetShieldFlag.Value then
		-- Mirror ON
		if shieldFlag then
			shieldFlag.Value = true
		end
		print("[HealthController] 🛡️ Global shield ON →", target.Name)
	else
		-- Mirror OFF + cleanup
		if shieldFlag then
			shieldFlag.Value = false
		end
		destroyShieldBubbles()
		print("[HealthController] 🔓 Global shield OFF →", target.Name)
	end
end)

-- ========= CORE DAMAGE LOGIC =========
health:GetPropertyChangedSignal("Value"):Connect(function()
	if reverting then return end

	-- Clamp upper bound
	if health.Value > maxHealth.Value then
		reverting = true
		health.Value = maxHealth.Value
		reverting = false
	end

	-- Recheck current shield state
	local currentShield = target:FindFirstChild("ShieldActive")
	local shieldUp = currentShield and currentShield.Value
	if shieldUp and health.Value < lastSafe then
		flash(Color3.fromRGB(0, 180, 255), 0.20)
		reverting = true
		health.Value = lastSafe
		reverting = false
		updateBar()
		return
	end

	lastSafe = health.Value
	updateBar()

	-- Game Over condition
	if health.Value <= 0 then
		TweenService:Create(hitbox, TweenInfo.new(0.25), {Transparency = 1}):Play()
		if GameOverEvent and GameOverEvent:IsA("RemoteEvent") then
			GameOverEvent:FireAllClients()
		end
		if GameActive then
			GameActive.Value = false
		end
	end
end)

-- ========= SAFETY MONITOR =========
task.spawn(function()
	while target.Parent do
		-- If global is off but shield still on locally, fix it
		if not TargetShieldFlag.Value and shieldFlag and shieldFlag.Value then
			shieldFlag.Value = false
			destroyShieldBubbles()
			print("[HealthController] 🔧 Auto-corrected lingering shield for", target.Name)
		end

		-- Recreate missing ShieldActive if deleted
		if not target:FindFirstChild("ShieldActive") then
			local f = Instance.new("BoolValue")
			f.Name = "ShieldActive"
			f.Value = false
			f.Parent = target
			connectShieldFlag(f)
			print("[HealthController] 🩹 Recreated missing ShieldActive for", target.Name)
		end

		task.wait(5)
	end
end)
