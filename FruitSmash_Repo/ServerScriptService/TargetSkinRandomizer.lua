-- TargetSkinRandomizer (Lane-aware)
local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local SKINS_FOLDER_PATH = {"Assets","TargetSkins"}
local MAX_BOUNDS = Vector3.new(16, 16, 16)
local SCALE_PADDING = 0.92
local SKIN_OFFSET = Vector3.new(0, 0, 0)
local RANDOM_YAW, ROLL_IN_ANIM = true, true
local SKIN_FOLDER_NAME = "Skin"

local function getSkinsFolder(): Instance?
	local node: Instance = RS
	for _, name in ipairs(SKINS_FOLDER_PATH) do
		local n = node:FindFirstChild(name)
		if not n then return nil end
		node = n
	end
	return node
end

local function ensurePrimaryPart(m: Model)
	if m.PrimaryPart then return end
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then m.PrimaryPart = d; return end
	end
end

local function setNoCollide(m: Model)
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.Massless = true
		end
	end
end

local function scaleModelToBounds(m: Model, maxBounds: Vector3)
	local _, size = m:GetBoundingBox()
	local sx = maxBounds.X / math.max(size.X, 1e-3)
	local sy = maxBounds.Y / math.max(size.Y, 1e-3)
	local sz = maxBounds.Z / math.max(size.Z, 1e-3)
	local scale = math.min(sx, sy, sz) * SCALE_PADDING
	m:ScaleTo(math.max(scale, 0.01))
end

local function getPivotCF(hitbox: BasePart): CFrame
	return hitbox.CFrame
end

local function randomizeSkinFor(target: Model, hitbox: BasePart)
	local folder = getSkinsFolder(); if not folder then return end
	local list = {}
	for _, c in ipairs(folder:GetChildren()) do
		if c:IsA("Model") then table.insert(list, c) end
	end
	if #list == 0 then return end

	-- clear old
	local old = target:FindFirstChild(SKIN_FOLDER_NAME)
	if old then old:Destroy() end

	local pick = list[math.random(1, #list)]:Clone()
	pick.Name = SKIN_FOLDER_NAME
	ensurePrimaryPart(pick)
	setNoCollide(pick)

	-- sizing and placement
	scaleModelToBounds(pick, MAX_BOUNDS)
	local cf = getPivotCF(hitbox) * CFrame.new(SKIN_OFFSET)
	if RANDOM_YAW then
		cf *= CFrame.Angles(0, math.rad(math.random(0,359)), 0)
	end
	pick:PivotTo(cf)
	pick.Parent = target

	if ROLL_IN_ANIM and pick.PrimaryPart then
		local pp = pick.PrimaryPart
		local startCF = pp.CFrame * CFrame.Angles(math.rad(50),0,0)
		pp.CFrame = startCF
		TweenService:Create(pp, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = cf
		}):Play()
	end
end

local function enumerateTargets()
	local result = {}
	local lanes = Workspace:FindFirstChild("Lanes")
	if lanes and lanes:IsA("Folder") then
		for _, lane in ipairs(lanes:GetChildren()) do
			if lane:IsA("Folder") then
				local t = lane:FindFirstChild("Target")
				if t and t:IsA("Model") then
					local hb = t:FindFirstChild("Hitbox")
					if hb and hb:IsA("BasePart") then table.insert(result, {t, hb}) end
				end
			end
		end
	end
	if #result == 0 then
		local t = Workspace:FindFirstChild("Target")
		if t and t:IsA("Model") then
			local hb = t:FindFirstChild("Hitbox")
			if hb and hb:IsA("BasePart") then table.insert(result, {t, hb}) end
		end
	end
	return result
end

for _, pair in ipairs(enumerateTargets()) do
	local target, hitbox = pair[1], pair[2]
	randomizeSkinFor(target, hitbox)
end
