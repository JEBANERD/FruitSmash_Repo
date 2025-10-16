-- PowerupDropService (SERVER, no SFX)
-- Random weighted drops with ground-snapped hover (no sounds).
-- API: MaybeDrop(position: Vector3, fruitName: string?, fruitPools?: {[string]: {{Name:string,Weight:number}}}?) -> Instance?

local RS         = game:GetService("ReplicatedStorage")
local Workspace  = game:GetService("Workspace")
local Debris     = game:GetService("Debris")
local RunService = game:GetService("RunService")

local M = {}

-- ===== CONFIG =====
local TEMPLATE_FOLDER = RS:WaitForChild("PowerupTemplates")

local DROP_CHANCE = 0.20
local LIFETIME    = 15

local TOSS = { Enabled = true, ImpulseMin = 10, ImpulseMax = 30, VerticalMin = 18, Lifetime = 0.40 }

local HOVER = {
	StartDelay   = 0.25,
	SpinSpeedRad = math.rad(60),
	BobAmplitude = 0.6,
	BobSpeedHz   = 1.6,
	GroundSnap   = true,
	BaseHeight   = 2.0,
	ProbeUp      = 20,
	ProbeDown    = 60,
	FallbackY    = 1.6,
}

local DEFAULT_POWERUPS = {
	{ Name = "CoinBoost",  Weight = 5 },
	{ Name = "HealthPack", Weight = 3 },
	{ Name = "Shield",     Weight = 2 },
}

-- ===== Helpers =====
local function pickWeighted(list)
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
	if inst:IsA("BasePart") then return inst end
	if inst:IsA("Model") then
		local pp = inst.PrimaryPart
		if pp and pp:IsA("BasePart") then return pp end
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
	if inst:IsA("Model") then inst:PivotTo(cf)
	else
		local bp = inst :: any
		if bp.CFrame then bp.CFrame = cf end
	end
end

local function computeBaseline(pos: Vector3, ignore: {Instance}): CFrame
	if HOVER.GroundSnap then
		local start = pos + Vector3.new(0, HOVER.ProbeUp, 0)
		local dir   = Vector3.new(0, -(HOVER.ProbeUp + HOVER.ProbeDown), 0)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = ignore
		local hit = Workspace:Raycast(start, dir, params)
		if hit then
			return CFrame.new(pos.X, hit.Position.Y + HOVER.BaseHeight, pos.Z)
		end
	end
	return CFrame.new(pos.X, pos.Y + HOVER.FallbackY, pos.Z)
end

local function startHover(inst: Instance, baseCF: CFrame)
	local root = getRoot(inst)
	if not (inst.Parent and root and root.Parent) then return end

	task.delay(HOVER.StartDelay, function()
		if not (inst.Parent and root.Parent) then return end
		root.Anchored = true
		local t0 = os.clock()

		local conn
		conn = RunService.Heartbeat:Connect(function()
			if not (inst.Parent and root.Parent) then if conn then conn:Disconnect() end return end
			local t = os.clock() - t0
			local yaw = CFrame.Angles(0, HOVER.SpinSpeedRad * t, 0)
			local bob = math.sin(t * math.pi * 2 * HOVER.BobSpeedHz) * HOVER.BobAmplitude
			setCFrame(inst, baseCF * yaw * CFrame.new(0, bob, 0))
		end)
		inst.Destroying:Connect(function() if conn then conn:Disconnect() end end)
	end)
end

-- ===== Public API =====
function M.MaybeDrop(position: Vector3, fruitName: string?, fruitPools: {[string]: {{Name:string,Weight:number}}}?)
	if math.random() > DROP_CHANCE then return nil end

	local pool = (fruitPools and fruitPools[fruitName or ""]) or DEFAULT_POWERUPS
	local chosen = pickWeighted(pool)
	if not chosen then return nil end

	local template = TEMPLATE_FOLDER:FindFirstChild(chosen)
	if not template then warn("[PowerupDropService] Missing template:", chosen); return nil end

	local inst = template:Clone()
	inst.Parent = Workspace

	local root = getRoot(inst)
	if inst:IsA("Model") then inst:PivotTo(CFrame.new(position)) else if root then root.CFrame = CFrame.new(position) end end

	if root then
		root.CanCollide = true
		root.Anchored = false
		if TOSS.Enabled then
			local lv = Instance.new("LinearVelocity")
			lv.Attachment0 = Instance.new("Attachment", root)
			lv.MaxForce = math.huge
			lv.VectorVelocity = Vector3.new(
				math.random(-TOSS.ImpulseMin, TOSS.ImpulseMax),
				math.random(TOSS.VerticalMin, TOSS.ImpulseMax),
				math.random(-TOSS.ImpulseMin, TOSS.ImpulseMax)
			)
			lv.Parent = root
			Debris:AddItem(lv, TOSS.Lifetime)
		end
	end

	local baselineCF = computeBaseline(position, { inst })
	startHover(inst, baselineCF)

	Debris:AddItem(inst, LIFETIME)
	return inst
end

return M
