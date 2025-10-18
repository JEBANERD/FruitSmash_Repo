--[[
NoOverlapNudge.lua  (More-Spacing Edition)
Prevents projectiles from spawning on top of each other by nudging sideways at spawn.
Works for both Models and single Parts.

Defaults are intentionally generous for clear separation:
  • STEP (LateralSpacing)  = 1.2 studs  -- per-try sideways move
  • MIN_ALONG_GAP (AlongGap)= 4.0 studs -- forward window near muzzle to check
  • MIN_LATERAL (MinLateral)= STEP * 2.5 (~3.0 studs by default)
  • MAX_STEPS              = 10
  • WAIT_UNTIL             = 0.35s

Optional Attributes on the projectile (Model or Part) to override:
  • LateralSpacing (number)
  • AlongGap (number)
  • MinLateral (number)
  • MaxSteps (integer)
--]]

local RunService = game:GetService("RunService")

-- Root discovery (handles Model or Part)
local host = script.Parent
local model = host:IsA("Model") and host or host:FindFirstAncestorWhichIsA("Model")
local root: BasePart
if model then
	root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
else
	root = host:IsA("BasePart") and host or host:FindFirstChildWhichIsA("BasePart")
end
if not root then
	warn("[NoOverlapNudge] No BasePart found for", host:GetFullName())
	return
end

-- Attribute helper
local function getAttr(name: string)
	if model and model:GetAttribute(name) ~= nil then
		return model:GetAttribute(name)
	end
	return host:GetAttribute(name)
end

-- Tunables (with Attribute overrides)
local STEP: number = tonumber(getAttr("LateralSpacing")) or 1.2
local MIN_ALONG_GAP: number = tonumber(getAttr("AlongGap")) or 4.0
local MIN_LATERAL: number = tonumber(getAttr("MinLateral")) or (STEP * 2.5)
local MAX_STEPS: number = tonumber(getAttr("MaxSteps")) or 10
local WAIT_UNTIL: number = 0.35

-- Basis from current forward
local function basis(forward: Vector3)
	forward = (forward.Magnitude > 0) and forward.Unit or Vector3.zAxis
	local right = forward:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then
		right = forward:Cross(Vector3.xAxis)
	end
	right = right.Unit
	return forward, right
end

-- Scan nearby projectiles in a short forward slice
local function needsSeparation(originPos: Vector3, forward: Vector3, selfObj: Instance): boolean
	local active = workspace:FindFirstChild("ActiveProjectiles")
	if not active then return false end
	for _, child in ipairs(active:GetChildren()) do
		if child ~= selfObj then
			local otherRoot: BasePart =
				(child:IsA("Model") and (child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")))
				or (child:IsA("BasePart") and child)
			if otherRoot and otherRoot.Parent then
				local delta = otherRoot.Position - originPos
				local along = delta:Dot(forward)
				if along > 0 and along < MIN_ALONG_GAP then
					local lateral = (delta - forward * along).Magnitude
					if lateral < MIN_LATERAL then
						return true
					end
				end
			end
		end
	end
	return false
end

-- Main correction (runs once after spawn)
local function tryNudge()
	local t0 = os.clock()
	local forward, right = basis(root.CFrame.LookVector)
	local origin = root.Position

	-- Early out if already clear
	if not needsSeparation(origin, forward, model or host) then return end

	-- Slight randomness for visual variety
	local dir = (math.random() < 0.5) and 1 or -1

	local stepCount = 0
	while (os.clock() - t0) < WAIT_UNTIL and stepCount < (MAX_STEPS * 2) do
		stepCount += 1
		local stride = math.ceil(stepCount / 2) * STEP
		local sign = ((stepCount % 2) == 1) and dir or -dir
		local offset = right * (sign * stride)

		if model then
			model:PivotTo(CFrame.new(origin + offset, origin + offset + forward))
		else
			root.CFrame = CFrame.new(origin + offset, origin + offset + forward)
		end

		if not needsSeparation(root.Position, forward, model or host) then
			break
		end

		RunService.Heartbeat:Wait()
	end
end

task.defer(tryNudge)
