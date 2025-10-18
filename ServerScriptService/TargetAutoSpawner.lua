-- TargetAutoSpawner: ensures each lane has a Target by cloning RS/Assets/TargetTemplate

local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local function getTemplate(): Model?
	local assets = RS:FindFirstChild("Assets")
	if not (assets and assets:IsA("Folder")) then
		warn("[TargetAutoSpawner] Missing ReplicatedStorage/Assets folder")
		return nil
	end
	local tmpl = assets:FindFirstChild("TargetTemplate")
	if not (tmpl and tmpl:IsA("Model")) then
		warn("[TargetAutoSpawner] Missing Assets/TargetTemplate (Model)")
		return nil
	end
	return tmpl
end

local function ensurePrimaryPart(m: Model)
	if m.PrimaryPart then return end
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then m.PrimaryPart = d; return end
	end
end

local function ensureTarget(lane: Folder, template: Model)
	local target = lane:FindFirstChild("Target")
	if target and target:IsA("Model") then return target end

	local clone = template:Clone()
	clone.Name = "Target"
	ensurePrimaryPart(clone)
	clone.Parent = lane

	-- Safety defaults
	local hitbox = clone:FindFirstChild("Hitbox")
	local health = clone:FindFirstChild("Health")
	local max    = clone:FindFirstChild("MaxHealth")

	if hitbox and hitbox:IsA("BasePart") then
		hitbox.Transparency = 0.99
		hitbox.CanCollide = false
		hitbox.CanTouch = false
		hitbox.CanQuery = true
	end
	if health and max and health:IsA("NumberValue") and max:IsA("NumberValue") then
		health.Value = max.Value
	end

	print(("[TargetAutoSpawner] Spawned Target in %s"):format(lane.Name))
	return clone
end

local function run()
	local lanes = Workspace:FindFirstChild("Lanes")
	if not (lanes and lanes:IsA("Folder")) then return end

	local tmpl = getTemplate()
	if not tmpl then return end

	for _, lane in ipairs(lanes:GetChildren()) do
		if lane:IsA("Folder") then
			ensureTarget(lane, tmpl)
		end
	end
end

run()
