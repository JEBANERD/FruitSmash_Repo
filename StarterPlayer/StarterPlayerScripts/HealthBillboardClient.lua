-- HealthBillboardClient (lane-aware + StreamingEnabled tolerant)
-- Builds a bar for each Target as soon as any BasePart (prefer "Hitbox") streams in.

local Players = game:GetService("Players")
local LP = Players.LocalPlayer
local PG = LP:WaitForChild("PlayerGui")

local ALWAYS_ON_TOP = true
local MAX_DISTANCE  = 30000
local BASE_SIZE     = Vector2.new(280, 36)
local Y_OFFSET      = 5
local SHOW_NUMBERS  = true

local function log(...) print("[HealthBillboardClient]", ...) end
local function warnf(...) warn("[HealthBillboardClient]", ...) end
local function colorForRatio(r: number) return Color3.new(1 - r, r, 0) end

-- Prefer the "Hitbox" BasePart; otherwise the first BasePart we can find.
local function resolveBasePart(target: Model): BasePart?
	local hb = target:FindFirstChild("Hitbox")
	if hb and hb:IsA("BasePart") then return hb end
	for _, d in ipairs(target:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Hitbox" then return d end
	end
	for _, d in ipairs(target:GetDescendants()) do
		if d:IsA("BasePart") then return d end
	end
	return nil
end

local function buildBillboard(target: Model, part: BasePart, health: NumberValue, max: NumberValue)
	-- ensure .99 so billboards render even if almost invisible
	if part.Transparency == 1 then
		part.Transparency = 0.99
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "TargetHealthBillboard"
	gui.Adornee = part
	gui.AlwaysOnTop = ALWAYS_ON_TOP
	gui.MaxDistance = MAX_DISTANCE
	gui.Size = UDim2.fromOffset(BASE_SIZE.X, BASE_SIZE.Y)
	gui.LightInfluence = 0
	gui.StudsOffset = Vector3.new(0, Y_OFFSET, 0)
	gui.ResetOnSpawn = false
	gui.Parent = PG

	local card = Instance.new("Frame")
	card.Size = UDim2.fromScale(1,1)
	card.BackgroundColor3 = Color3.fromRGB(15,15,18)
	card.BackgroundTransparency = 0.1
	card.Parent = gui
	Instance.new("UICorner", card).CornerRadius = UDim.new(0,10)

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Size = UDim2.fromScale(1,0.55)
	barBg.AnchorPoint = Vector2.new(0.5,0.5)
	barBg.Position = UDim2.fromScale(0.5,0.55)
	barBg.BackgroundColor3 = Color3.fromRGB(36,36,40)
	barBg.Parent = card
	Instance.new("UICorner", barBg).CornerRadius = UDim.new(0,8)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1,1)
	fill.BackgroundColor3 = Color3.fromRGB(88,200,120)
	fill.Parent = barBg
	Instance.new("UICorner", fill).CornerRadius = UDim.new(0,8)

	local label: TextLabel? = nil
	if SHOW_NUMBERS then
		label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1,0.35)
		label.AnchorPoint = Vector2.new(0.5,0)
		label.Position = UDim2.fromScale(0.5,0.05)
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(240,240,240)
		label.Parent = card
	end

	local function refresh()
		if not target.Parent or not part.Parent then gui:Destroy(); return end
		local maxV = math.max(1, max.Value)
		local ratio = math.clamp((health.Value or 0) / maxV, 0, 1)
		fill.Size = UDim2.fromScale(ratio, 1)
		fill.BackgroundColor3 = colorForRatio(ratio)
		if label then label.Text = string.format("%d / %d", math.floor(health.Value + 0.5), maxV) end
	end
	health:GetPropertyChangedSignal("Value"):Connect(refresh)
	max:GetPropertyChangedSignal("Value"):Connect(refresh)
	refresh()

	-- Clean up if target despawns
	target.AncestryChanged:Connect(function(_, parent)
		if not parent then gui:Destroy() end
	end)
end

-- Build or wait until a BasePart streams in
local function attachWhenReady(target: Model)
	local health = target:FindFirstChild("Health")
	local max    = target:FindFirstChild("MaxHealth")
	if not (health and health:IsA("NumberValue") and max and max:IsA("NumberValue")) then
		warnf(("Skip %s: missing Health/MaxHealth"):format(target:GetFullName()))
		return
	end

	local part = resolveBasePart(target)
	if part then
		buildBillboard(target, part, health, max)
		return
	end

	-- Streaming: wait until the first BasePart shows up
	log(("Waiting for BasePart to stream for %s"):format(target:GetFullName()))
	local conn; conn = target.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			if conn then conn:Disconnect() end
			buildBillboard(target, d, health, max)
		end
	end)

	-- Also re-check in case parts appear between calls
	task.defer(function()
		task.wait(0.1)
		if conn then
			local p2 = resolveBasePart(target)
			if p2 then conn:Disconnect(); buildBillboard(target, p2, health, max) end
		end
	end)
end

local function initialScan()
	local count = 0
	local lanes = workspace:FindFirstChild("Lanes")
	if lanes and lanes:IsA("Folder") then
		for _, lane in ipairs(lanes:GetChildren()) do
			if lane:IsA("Folder") then
				local t = lane:FindFirstChild("Target")
				if t and t:IsA("Model") then
					attachWhenReady(t); count += 1
				end
			end
		end
	end
	-- Fallback single target
	local solo = workspace:FindFirstChild("Target")
	if solo and solo:IsA("Model") then
		attachWhenReady(solo); count += 1
	end
	print(("[HealthBillboardClient] Queued %d targets").format and "" or "")
	log(("Queued %d targets"):format(count))
end

-- Watch for new lanes/targets later
workspace.ChildAdded:Connect(function(child)
	if child:IsA("Model") and child.Name == "Target" then
		attachWhenReady(child)
	elseif child:IsA("Folder") and child.Name == "Lanes" then
		child.ChildAdded:Connect(function(lane)
			if lane:IsA("Folder") then
				lane.ChildAdded:Connect(function(c2)
					if c2:IsA("Model") and c2.Name == "Target" then
						attachWhenReady(c2)
					end
				end)
				local t = lane:FindFirstChild("Target")
				if t and t:IsA("Model") then attachWhenReady(t) end
			end
		end)
	end
end)

initialScan()
