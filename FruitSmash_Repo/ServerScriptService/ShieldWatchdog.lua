-- ShieldWatchdog (SERVER) - Enforces global->local shield consistency
local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local TargetShieldFlag: BoolValue = RS:FindFirstChild("TargetShieldActive") :: BoolValue
if not TargetShieldFlag then
	TargetShieldFlag = Instance.new("BoolValue")
	TargetShieldFlag.Name = "TargetShieldActive"
	TargetShieldFlag.Value = false
	TargetShieldFlag.Parent = RS
end

local function getAllTargets()
	local out = {}
	local lanes = Workspace:FindFirstChild("Lanes")
	if lanes then
		for _, lane in ipairs(lanes:GetChildren()) do
			local t = lane:FindFirstChild("Target")
			if t then table.insert(out, t) end
		end
	end
	local single = Workspace:FindFirstChild("Target")
	if single then table.insert(out, single) end
	return out
end

local function hardClean()
	if TargetShieldFlag.Value then return end -- only enforce when global is OFF
	for _, t in ipairs(getAllTargets()) do
		local flag = t:FindFirstChild("ShieldActive")
		if flag and flag.Value then
			flag.Value = false
		end
		for _, d in ipairs(t:GetChildren()) do
			if d:IsA("BasePart") and d.Name == "TargetShieldBubble" then
				d:Destroy()
			end
		end
	end
end

-- Light heartbeat (twice a second)
task.spawn(function()
	while true do
		task.wait(0.5)
		hardClean()
	end
end)
