-- TargetAliasBridge: temporary compatibility for scripts expecting Workspace.Target
-- Mirrors Workspace/Lanes/*/Target (first valid lane) into a proxy model at Workspace.Target.

local Workspace = game:GetService("Workspace")

local function findFirstLaneTarget()
	local lanes = Workspace:FindFirstChild("Lanes")
	if not (lanes and lanes:IsA("Folder")) then return nil end
	for _, lane in ipairs(lanes:GetChildren()) do
		if lane:IsA("Folder") then
			local t = lane:FindFirstChild("Target")
			if t and t:IsA("Model") then
				local hitbox = t:FindFirstChild("Hitbox")
				local health = t:FindFirstChild("Health")
				local max = t:FindFirstChild("MaxHealth")
				if hitbox and hitbox:IsA("BasePart") and health and health:IsA("NumberValue") and max and max:IsA("NumberValue") then
					return t, hitbox, health, max
				end
			end
		end
	end
	return nil
end

local function ensureProxy()
	local proxy = Workspace:FindFirstChild("Target")
	if proxy and proxy:IsA("Model") then return proxy end
	proxy = Instance.new("Model")
	proxy.Name = "Target"
	proxy.Parent = Workspace

	local hb = Instance.new("Part")
	hb.Name = "Hitbox"
	hb.Anchored = true
	hb.Size = Vector3.new(6,6,6)
	hb.Transparency = 1
	hb.CanCollide = false
	hb.CanTouch = false
	hb.CanQuery = true
	hb.Parent = proxy

	local health = Instance.new("NumberValue")
	health.Name = "Health"
	health.Value = 100
	health.Parent = proxy

	local max = Instance.new("NumberValue")
	max.Name = "MaxHealth"
	max.Value = 100
	max.Parent = proxy

	local skin = Instance.new("Folder")
	skin.Name = "Skin"
	skin.Parent = proxy

	return proxy
end

local function syncLoop()
	local proxy = ensureProxy()
	while task.wait(0.1) do
		local laneTarget, laneHitbox, laneHealth, laneMax = findFirstLaneTarget()
		if not (laneTarget and proxy and proxy.Parent) then
			-- If no lanes, just idle; proxy stays as-is for legacy scripts that check existence.
		else
			-- Mirror values
			local pHB = proxy:FindFirstChild("Hitbox")
			local pH  = proxy:FindFirstChild("Health")
			local pM  = proxy:FindFirstChild("MaxHealth")
			if pHB and pHB:IsA("BasePart") then
				pHB.CFrame = laneHitbox.CFrame
			end
			if pH and pH:IsA("NumberValue") then pH.Value = laneHealth.Value end
			if pM and pM:IsA("NumberValue") then pM.Value = laneMax.Value end
		end
	end
end

task.defer(syncLoop)
