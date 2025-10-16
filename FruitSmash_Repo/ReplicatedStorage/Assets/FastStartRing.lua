-- FastStartRing (Server) — RoundDirector-compatible
-- Touch the ring while GameActive == false to trigger a fast 3s countdown.
-- Uses RS.FastStartRequested BoolValue toggle (primary), with optional legacy Remote fallback.

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

-- === Remotes / State (idempotent) ===
local Remotes = RS:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = RS
end

local GameActive = RS:FindFirstChild("GameActive")
if not GameActive then
	GameActive = Instance.new("BoolValue")
	GameActive.Name = "GameActive"
	GameActive.Value = false
	GameActive.Parent = RS
end

-- Primary fast-start signal for RoundDirector: toggle this BoolValue
local FastStartFlag = RS:FindFirstChild("FastStartRequested")
if not FastStartFlag then
	FastStartFlag = Instance.new("BoolValue")
	FastStartFlag.Name = "FastStartRequested"
	FastStartFlag.Parent = RS
end

-- Optional legacy Remote (we won't rely on it, but we won't break it either)
local RequestFastStartRemote = Remotes:FindFirstChild("RequestFastStart")
-- (If you had a BindableEvent here before, RemoteEvents are more common; we just ignore if missing.)

-- === Ring part lookup ===
local container = script.Parent
local ringPart = nil

if container:IsA("BasePart") then
	ringPart = container
else
	ringPart = container:FindFirstChild("RingPart")
	if not ringPart then
		for _, d in ipairs(container:GetDescendants()) do
			if d:IsA("BasePart") then ringPart = d; break end
		end
	end
end

assert(ringPart, "[FastStartRing] No ring BasePart found (use a Part or a Model with 'RingPart').")

ringPart.Anchored = true
ringPart.CanCollide = false
ringPart.CanTouch = true

-- === Build overhead label ===
local function buildBillboard(parentPart)
	local attach = Instance.new("Attachment")
	attach.Name = "SkipAnchor"
	attach.Position = Vector3.new(0, 0, 0)
	attach.Parent = parentPart

	local bb = Instance.new("BillboardGui")
	bb.Name = "SkipText"
	bb.Adornee = attach
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(220, 60)
	bb.MaxDistance = 160
	bb.StudsOffset = Vector3.new(0, 3.2, 0)
	bb.LightInfluence = 0
	bb.Parent = parentPart

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Text"
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Text = "⚡ Skip Countdown"
	lbl.TextScaled = true
	lbl.Font = Enum.Font.GothamBold
	lbl.TextColor3 = Color3.fromRGB(255, 240, 100)
	lbl.TextStrokeTransparency = 0.3
	lbl.Parent = bb

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(0, 0, 0)
	stroke.Transparency = 0.2
	stroke.Parent = lbl

	local scale = Instance.new("UIScale")
	scale.Scale = 0.95
	scale.Parent = bb

	task.spawn(function()
		while bb.Parent do
			TweenService:Create(scale, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Scale = 1.05}):Play()
			task.wait(0.6)
			if not bb.Parent then break end
			TweenService:Create(scale, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Scale = 0.95}):Play()
			task.wait(0.6)
		end
	end)

	return bb
end

local billboard = buildBillboard(ringPart)

-- === Helpers ===
local function getPlayerFromHit(hit)
	local character = hit and hit:FindFirstAncestorOfClass("Model")
	if not character then return nil end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then return nil end
	return Players:GetPlayerFromCharacter(character)
end

local function shrinkAndDestroy()
	local ringTween = TweenService:Create(ringPart, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = ringPart.Size * 0.1,
		Transparency = 1,
	})
	ringTween:Play()

	if billboard and billboard.Parent then
		local lbl = billboard:FindFirstChild("Text")
		if lbl then
			TweenService:Create(lbl, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				TextTransparency = 1, TextStrokeTransparency = 1
			}):Play()
		end
		TweenService:Create(billboard, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = UDim2.fromOffset(160, 40)
		}):Play()
	end

	ringTween.Completed:Connect(function()
		if billboard then billboard:Destroy() end
		if container and container.Parent then container:Destroy() end
	end)
end

local function flashRing()
	local origColor = ringPart.Color
	local origTrans = ringPart.Transparency
	ringPart.Color = Color3.fromRGB(255, 255, 255)
	ringPart.Transparency = 0.15
	task.delay(0.2, function()
		if ringPart and ringPart.Parent then
			ringPart.Color = origColor
			ringPart.Transparency = origTrans
		end
	end)
end

-- === Activation ===
local DEBOUNCED = false
local FAST_SECONDS = 3 -- visual reference; RoundDirector uses a fixed 3s fast start

local function triggerFastStart(plr)
	-- Primary: toggle the FastStartRequested BoolValue (RoundDirector listener)
	FastStartFlag.Value = not FastStartFlag.Value

	-- Optional: Compatibility ping for older setups (harmless if unused)
	if RequestFastStartRemote and RequestFastStartRemote:IsA("RemoteEvent") then
		-- We’re on the server; this mirrors the old API without relying on it.
		RequestFastStartRemote:FireAllClients(FAST_SECONDS, container)
	end

	print("[FastStartRing] Activated by", plr and plr.Name or "unknown", "→ fast 3s countdown")
end

local function tryActivate(plr)
	if DEBOUNCED then return end
	if GameActive.Value then return end -- only while paused/pre-round
	DEBOUNCED = true

	flashRing()
	triggerFastStart(plr)
	shrinkAndDestroy()
end

-- Touch listener
ringPart.Touched:Connect(function(hit)
	if DEBOUNCED then return end
	local plr = getPlayerFromHit(hit)
	if not plr then return end
	if not GameActive.Value then
		tryActivate(plr)
	end
end)

-- Safety: if the round starts while the ring is still around, auto-clean it
GameActive:GetPropertyChangedSignal("Value"):Connect(function()
	if GameActive.Value and container and container.Parent then
		if billboard and billboard.Parent then
			local lbl = billboard:FindFirstChild("Text")
			if lbl then
				TweenService:Create(lbl, TweenInfo.new(0.18), {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
			end
		end
		task.delay(0.2, function()
			if container and container.Parent then container:Destroy() end
		end)
	end
end)
