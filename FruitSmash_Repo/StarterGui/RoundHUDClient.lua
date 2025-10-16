-- RoundHUDClient
-- Minimal round HUD with progress bar and intermission timer.
-- Works with RoundDirector: listens to Remotes.RoundUpdate / IntermissionEvent,
-- and mirrors RoundState values for late joiners.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local LP = Players.LocalPlayer

-- === Shared state / remotes ===
local Remotes = RS:WaitForChild("Remotes")
local RoundUpdate: RemoteEvent = Remotes:WaitForChild("RoundUpdate")
local IntermissionEvent: RemoteEvent = Remotes:WaitForChild("IntermissionEvent")

local RoundState = RS:WaitForChild("RoundState")
local RoundNumber: IntValue       = RoundState:WaitForChild("RoundNumber")
local RoundGoal: IntValue         = RoundState:WaitForChild("RoundGoal")
local RoundPoints: IntValue       = RoundState:WaitForChild("RoundPoints")
local RoundIntensity: NumberValue = RoundState:WaitForChild("RoundIntensity")

-- === Build UI ===
local gui = script.Parent :: ScreenGui

-- Root bar
local frame = Instance.new("Frame")
frame.Name = "RoundBar"
frame.AnchorPoint = Vector2.new(0.5, 0)
frame.Position = UDim2.new(0.5, 0, 0.02, 0)
frame.Size = UDim2.fromOffset(520, 64)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
frame.BackgroundTransparency = 0.15
frame.Parent = gui
local corner = Instance.new("UICorner", frame)
corner.CornerRadius = UDim.new(0, 12)

-- Round label
local roundLabel = Instance.new("TextLabel")
roundLabel.Name = "RoundLabel"
roundLabel.BackgroundTransparency = 1
roundLabel.Position = UDim2.fromOffset(12, 6)
roundLabel.Size = UDim2.fromOffset(200, 24)
roundLabel.Font = Enum.Font.GothamBold
roundLabel.TextSize = 20
roundLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
roundLabel.TextXAlignment = Enum.TextXAlignment.Left
roundLabel.Parent = frame

-- Intensity label (right)
local intensityLabel = Instance.new("TextLabel")
intensityLabel.Name = "IntensityLabel"
intensityLabel.BackgroundTransparency = 1
intensityLabel.AnchorPoint = Vector2.new(1, 0)
intensityLabel.Position = UDim2.new(1, -12, 0, 6)
intensityLabel.Size = UDim2.fromOffset(180, 24)
intensityLabel.Font = Enum.Font.GothamBold
intensityLabel.TextSize = 18
intensityLabel.TextColor3 = Color3.fromRGB(170, 210, 255)
intensityLabel.TextXAlignment = Enum.TextXAlignment.Right
intensityLabel.Parent = frame

-- Progress bg
local progBg = Instance.new("Frame")
progBg.Name = "ProgressBg"
progBg.AnchorPoint = Vector2.new(0.5, 1)
progBg.Position = UDim2.new(0.5, 0, 1, -8)
progBg.Size = UDim2.new(1, -24, 0, 22)
progBg.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
progBg.Parent = frame
Instance.new("UICorner", progBg).CornerRadius = UDim.new(0, 10)

-- Progress fill
local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = Color3.fromRGB(110, 220, 140)
fill.Parent = progBg
Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 10)

-- Points label (centered on progress)
local pointsLabel = Instance.new("TextLabel")
pointsLabel.BackgroundTransparency = 1
pointsLabel.Size = UDim2.fromScale(1, 1)
pointsLabel.Font = Enum.Font.Gotham
pointsLabel.TextSize = 16
pointsLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
pointsLabel.Parent = progBg

-- Intermission banner
local intermission = Instance.new("Frame")
intermission.Name = "Intermission"
intermission.AnchorPoint = Vector2.new(0.5, 0)
intermission.Position = UDim2.new(0.5, 0, 0.12, 0)
intermission.Size = UDim2.fromOffset(480, 40)
intermission.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
intermission.BackgroundTransparency = 0.2
intermission.Visible = false
intermission.Parent = gui
Instance.new("UICorner", intermission).CornerRadius = UDim.new(0, 12)

local interText = Instance.new("TextLabel")
interText.BackgroundTransparency = 1
interText.Size = UDim2.fromScale(1, 1)
interText.Font = Enum.Font.GothamBlack
interText.TextSize = 22
interText.TextColor3 = Color3.fromRGB(255, 225, 140)
interText.Text = "SHOP INTERMISSION"
interText.Parent = intermission

local interTimer = Instance.new("TextLabel")
interTimer.BackgroundTransparency = 1
interTimer.AnchorPoint = Vector2.new(1, 0)
interTimer.Position = UDim2.new(1, -12, 0, 0)
interTimer.Size = UDim2.fromOffset(120, 40)
interTimer.Font = Enum.Font.GothamBold
interTimer.TextSize = 20
interTimer.TextColor3 = Color3.fromRGB(255, 255, 255)
interTimer.TextXAlignment = Enum.TextXAlignment.Right
interTimer.Text = "30"
interTimer.Parent = intermission

-- === Helpers ===
local function colorForRatio(r)
	-- green -> red
	return Color3.new(1 - r, r, 0)
end

local function setFillRatio(ratio: number)
	ratio = math.clamp(ratio, 0, 1)
	local tween = TweenService:Create(fill, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(ratio, 1), BackgroundColor3 = colorForRatio(ratio) })
	tween:Play()
end

local function prettyInt(n: number): string
	local s = tostring(math.floor(n + 0.5))
	return s:reverse():gsub("(%d%d%d)","%1,"):reverse():gsub("^,","")
end

local function refreshFromState()
	local round = RoundNumber.Value
	local goal = math.max(1, RoundGoal.Value)
	local pts = math.max(0, RoundPoints.Value)
	local intensity = RoundIntensity.Value

	roundLabel.Text = string.format("ROUND %d", round)
	intensityLabel.Text = string.format("Intensity: %.2f", intensity)
	pointsLabel.Text = string.format("%s / %s", prettyInt(pts), prettyInt(goal))
	setFillRatio(pts / goal)
end

-- === Wiring ===
-- Initial draw
refreshFromState()

-- Live updates from RoundState
RoundNumber:GetPropertyChangedSignal("Value"):Connect(refreshFromState)
RoundGoal:GetPropertyChangedSignal("Value"):Connect(refreshFromState)
RoundPoints:GetPropertyChangedSignal("Value"):Connect(refreshFromState)
RoundIntensity:GetPropertyChangedSignal("Value"):Connect(refreshFromState)

-- Updates from server remote (phase & totals)
RoundUpdate.OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then return end
	if payload.round then RoundNumber.Value = payload.round end
	if payload.goal then RoundGoal.Value = payload.goal end
	if payload.points then RoundPoints.Value = payload.points end
	if payload.intensity then RoundIntensity.Value = payload.intensity end

	-- Optionally react to phase (countdown/active/complete/intermission)
end)

-- Intermission start/end + countdown
local interConn -- to cancel old timers if a new intermission starts
IntermissionEvent.OnClientEvent:Connect(function(phase, seconds)
	if phase == "start" then
		intermission.Visible = true
		interText.Text = "SHOP INTERMISSION"
		interTimer.Text = tostring(seconds or 30)

		if interConn then interConn:Disconnect() end
		local remaining = tonumber(seconds) or 30
		interConn = game:GetService("RunService").RenderStepped:Connect(function(dt)
			-- Approx countdown on client; server keeps GameActive off anyway
			remaining -= dt
			if remaining < 0 then remaining = 0 end
			interTimer.Text = tostring(math.ceil(remaining))
		end)
	elseif phase == "end" then
		if interConn then interConn:Disconnect(); interConn = nil end
		intermission.Visible = false
	end
end)
