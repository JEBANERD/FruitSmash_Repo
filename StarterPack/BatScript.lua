local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local PlayerSwing = RS:WaitForChild("Remotes"):WaitForChild("PlayerSwing")

local player = Players.LocalPlayer
local tool = script.Parent
local handle = tool:FindFirstChild("Handle")

local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local swoosh = handle and handle:FindFirstChild("Swoosh")
local trail = handle and handle:FindFirstChildOfClass("Trail")

local COOLDOWN = 0.35
local lastSwing = 0
local track: AnimationTrack?

-- Load and prepare the SwingAnim
local function loadAnim()
	if track then return end
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	local animObj = tool:FindFirstChild("SwingAnim")

	if animObj and animObj:IsA("Animation") and animObj.AnimationId ~= "" then
		track = animator:LoadAnimation(animObj)
		pcall(function()
			track.Priority = Enum.AnimationPriority.Action
		end)
	else
		warn("[Bat] No valid SwingAnim found or missing AnimationId")
	end
end

-- Triggered when the bat is swung
local function swing()
	local now = time()
	if now - lastSwing < COOLDOWN then return end
	lastSwing = now

	if swoosh then swoosh:Play() end
	if trail then
		trail.Enabled = true
		task.delay(0.25, function()
			if trail then trail.Enabled = false end
		end)
	end

	loadAnim()
	if track then
		track:Play(0.05, 1, 1.0)
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local hitPos = (handle and handle:IsA("BasePart")) and handle.Position or Vector3.zero
	if root then
		PlayerSwing:FireServer(root.CFrame, hitPos)
	end
end

tool.Activated:Connect(swing)
