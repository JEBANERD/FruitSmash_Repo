-- PowerupDropService (SERVER)
-- Random weighted drops with ground-snapped hover, gentle bob/spin, and optional toss.
-- Public API (unchanged):
--   MaybeDrop(position: Vector3, fruitName: string?, fruitSpecific: {[string]: {{Name:string,Weight:number}}}?) -> Instance?

local RS          = game:GetService("ReplicatedStorage")
local Workspace   = game:GetService("Workspace")
local Debris      = game:GetService("Debris")
local RunService  = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")

local M = {}

-- ========= CONFIG =========
local TEMPLATE_FOLDER = RS:WaitForChild("PowerupTemplates")

-- Chance & lifetime
local DROP_CHANCE   = 0.9-- 20% chance per smashed fruit
local LIFETIME      = 10        -- seconds before auto-despawn (Debris)

-- Toss on spawn (fun pop before hovering)
local TOSS = {
	Enabled    = true,
	ImpulseMin = 10,
	ImpulseMax = 30,
	VerticalMin= 18,
	Lifetime   = 0.40,           -- seconds to keep LinearVelocity
}

-- Hover/Spin
local HOVER = {
	StartDelay     = 0.25,       -- wait after toss before anchoring & hovering
	SpinSpeedRad   = math.rad(60), -- ≈ 60°/s
	BobAmplitude   = 0.6,        -- studs
	BobSpeedHz     = 1.6,        -- cycles/sec
	GroundSnap     = true,
	BaseHeight     = .2,        -- studs above ground
	ProbeUp        = 20,         -- raycast start above spawn
	ProbeDown      = 60,         -- raycast distance downward
	FallbackOffset = 1.6,        -- if ray misses, baseline = spawnY + this
}

-- Default weighted pool (used if fruit-specific table not supplied)
local DEFAULT_POWERUPS = {
	{ Name = "CoinBoost",  Weight = 5 },
	{ Name = "HealthPack", Weight = 3 },
	{ Name = "Shield",     Weight = 2 },
}

-- ========= Helpers =========
local function pickWeighted(list: {{Name: string, Weight: number}}): string?
	local total = 0
	for _, p in ipairs(list) do total += p.Weight end
	if total <= 0 then return nil end
	local r, acc = math.random() * total, 0
	for _, p in ipairs(list) do
		acc += p.Weight
		if r <= acc then return p.Name end
	end
end

local function getRoot(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	elseif inst:IsA("Model") then
		if inst.PrimaryPart then return inst.PrimaryPart end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				inst.PrimaryPart = d
				return d
			end
		end
	end
	return nil
end

local function setCFrame(inst: Instance, cf: CFrame)
	if inst:IsA("Model") then
		inst:PivotTo(cf)
	else
		local root = inst :: any
		if root and root.CFrame then root.CFrame = cf end
	end
end

local function tagPickup(inst: Instance, powerName: string)
	-- Attribute on model/root for scripts using Attributes
	inst:SetAttribute("PowerupType", powerName)

	-- Redundant StringValue for scripts that search children
	local existing = inst:FindFirstChild("PowerupType")
	if not existing then
		local sv = Instance.new("StringValue")
		sv.Name = "PowerupType"
		sv.Value = powerName
		sv.Parent = inst
	end
end

local function ensureDetectableParts(inst: Instance, opts: {canCollide: boolean})
	-- Make all parts query/touchable so pickup detectors work.
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanQuery = true
			d.CanTouch = true
			d.CanCollide = opts.canCollide
			-- Force Default group to avoid “no collision” matrices
			pcall(function() d.CollisionGroup = "Default" end)
		end
	end
	local root = getRoot(inst)
	if root then
		root.CanQuery = true
		root.CanTouch = true
		root.CanCollide = opts.canCollide
		pcall(function() root.CollisionGroup = "Default" end)
	end
end

local function startHover(inst: Instance, baseCF: CFrame)
	local root = getRoot(inst)
	if not (inst.Parent and root and root.Parent) then return end

	-- After a short delay, freeze to a clean hover baseline
	task.delay(HOVER.StartDelay, function()
		if not (inst.Parent and root and root.Parent) then return end

		-- Anchor for stable hover and disable collisions for easy collection
		root.Anchored = true
		ensureDetectableParts(inst, { canCollide = false })

		local t0 = os.clock()

		-- Heartbeat loop (disconnects automatically on destroy)
		local conn
		conn = RunService.Heartbeat:Connect(function()
			if not (inst.Parent and root.Parent) then
				if conn then conn:Disconnect() end
				return
			end
			local t = os.clock() - t0
			local yaw = CFrame.Angles(0, HOVER.SpinSpeedRad * t, 0)
			local bob = math.sin(t * math.pi * 2 * HOVER.BobSpeedHz) * HOVER.BobAmplitude
			local cf  = baseCF * yaw * CFrame.new(0, bob, 0)
			setCFrame(inst, cf)
		end)

		inst.Destroying:Connect(function()
			if conn then conn:Disconnect() end
		end)
	end)
end

local function computeBaseline(position: Vector3, ignore: {Instance}): CFrame
	if HOVER.GroundSnap then
		local start = position + Vector3.new(0, HOVER.ProbeUp, 0)
		local dir   = Vector3.new(0, -(HOVER.ProbeUp + HOVER.ProbeDown), 0)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = ignore
		local hit = Workspace:Raycast(start, dir, params)
		if hit then
			return CFrame.new(position.X, hit.Position.Y + HOVER.BaseHeight, position.Z)
		end
	end
	return CFrame.new(position.X, position.Y + HOVER.FallbackOffset, position.Z)
end

-- ========= Public API =========
function M.MaybeDrop(position: Vector3, fruitName: string?, fruitSpecific: {[string]: {{Name:string,Weight:number}}}?)
	if math.random() > DROP_CHANCE then return nil end

	local pool = (fruitSpecific and fruitSpecific[fruitName or ""]) or DEFAULT_POWERUPS
	local chosen = pickWeighted(pool)
	if not chosen then return nil end

	local template = TEMPLATE_FOLDER:FindFirstChild(chosen)
	if not template then
		warn(("[PowerupDropService] Missing template: %s"):format(chosen))
		return nil
	end

	local inst = template:Clone()
	tagPickup(inst, chosen)       -- <-- metadata for pickup scripts
	inst.Parent = Workspace

	-- Place at spawn
	local root = getRoot(inst)
	if inst:IsA("Model") then
		inst:PivotTo(CFrame.new(position))
	else
		if root then root.CFrame = CFrame.new(position) end
	end

	-- During the toss window, allow collisions so the item pops naturally.
	if root then
		ensureDetectableParts(inst, { canCollide = true })
		root.Anchored = false

		if TOSS.Enabled then
			local attach = Instance.new("Attachment")
			attach.Parent = root

			local lv = Instance.new("LinearVelocity")
			lv.Attachment0 = attach
			lv.MaxForce = math.huge
			lv.VectorVelocity = Vector3.new(
				math.random(-TOSS.ImpulseMin, TOSS.ImpulseMax),
				math.random(TOSS.VerticalMin,   TOSS.ImpulseMax),
				math.random(-TOSS.ImpulseMin, TOSS.ImpulseMax)
			)
			lv.Parent = root
			Debris:AddItem(lv, TOSS.Lifetime)
		end
	end

	-- Compute ground-snapped hover baseline (ignore the new instance so we hit the floor)
	local baselineCF = computeBaseline(position, { inst })

	-- Begin hover: after StartDelay we anchor + disable collisions for easy collection
	startHover(inst, baselineCF)

	-- Cleanup after lifetime
	Debris:AddItem(inst, LIFETIME)
	return inst
end

return M
