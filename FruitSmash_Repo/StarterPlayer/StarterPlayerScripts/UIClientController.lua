-- UIClientController (Classic UI + token-aware cancelable countdown + +points popup)
-- Countdown: top-center, no blur or input lock.
-- Game Over: clickable buttons, optional blur toggle.
-- Also shows a floating +points popup at smash location (color-matched to splatter).

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local CAS = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local HapticService = game:GetService("HapticService")

local Remotes = RS:WaitForChild("Remotes")
local StartCountdown: RemoteEvent = Remotes:WaitForChild("StartCountdown")
local GameOverEvent: RemoteEvent = Remotes:WaitForChild("GameOverEvent")
local RestartRequested: RemoteEvent = Remotes:WaitForChild("RestartRequested")
local QuitRequested: RemoteEvent? = Remotes:FindFirstChild("QuitRequested")
local FruitSmashed: RemoteEvent? = Remotes:FindFirstChild("FruitSmashed")

local player = Players.LocalPlayer
local pg = player:WaitForChild("PlayerGui")

-- ====== CONFIG ======
local USE_GAMEOVER_BLUR = false -- set true to blur during Game Over

-- ====== UTIL ======
local function ensureGui(name: string, order: number): ScreenGui
	local g = pg:FindFirstChild(name) :: ScreenGui?
	if not g then
		g = Instance.new("ScreenGui")
		g.Name = name
		g.Parent = pg
	end
	g.IgnoreGuiInset = true
	g.DisplayOrder = order
	g.ResetOnSpawn = true
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	return g
end

local function releaseAllUIBlocks()
	for _, n in ipairs({ "UIBlock", "CountdownBlock", "GameOverBlock" }) do
		pcall(function() CAS:UnbindAction(n) end)
	end
end

local function clearAllBlur()
	for _, inst in ipairs(Lighting:GetChildren()) do
		if inst:IsA("BlurEffect") then inst:Destroy() end
	end
end

-- ================== COUNTDOWN (token-aware, single cancelable thread) ==================
local CD = {
	gui = nil :: ScreenGui?,
	overlay = nil :: Frame?,
	label = nil :: TextLabel?,
	scale = nil :: UIScale?,
	currentThread = nil :: thread?,
	currentToken = 0,
}

function CD:build()
	self.gui = ensureGui("CountdownGui", 1000)

	-- overlay
	if self.gui:FindFirstChild("Overlay") then self.gui.Overlay:Destroy() end
	self.overlay = Instance.new("Frame")
	self.overlay.Name = "Overlay"
	self.overlay.Size = UDim2.fromScale(1,1)
	self.overlay.BackgroundTransparency = 1
	self.overlay.Active = false
	self.overlay.Visible = false
	self.overlay.ZIndex = 20
	self.overlay.Parent = self.gui

	-- label
	self.label = Instance.new("TextLabel")
	self.label.Name = "Label"
	self.label.AnchorPoint = Vector2.new(0.5, 0)
	self.label.Position = UDim2.fromScale(0.5, 0.05)
	self.label.Size = UDim2.fromOffset(520, 86)
	self.label.BackgroundTransparency = 1
	self.label.Text = ""
	self.label.TextColor3 = Color3.new(1,1,1)
	self.label.TextTransparency = 0
	self.label.TextScaled = true
	self.label.Font = Enum.Font.GothamBlack
	self.label.ZIndex = 21
	self.label.Parent = self.overlay

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(255,255,255)
	stroke.Transparency = 0.2
	stroke.Parent = self.label

	self.scale = Instance.new("UIScale")
	self.scale.Parent = self.label
end

function CD:hide()
	if self.overlay then self.overlay.Visible = false end
end

function CD:cancel()
	if self.currentThread then
		task.cancel(self.currentThread)
		self.currentThread = nil
	end
end

function CD:start(seconds: number, token: number?)
	if not self.gui then self:build() end
	releaseAllUIBlocks()
	clearAllBlur()

	-- Update token and cancel any older countdown
	self.currentToken = token or (self.currentToken + 1)
	self:cancel()

	self.overlay.Visible = true

	self.currentThread = task.spawn(function(myToken: number)
		local steps = {}
		for n = math.max(1, math.floor(seconds)), 1, -1 do table.insert(steps, tostring(n)) end
		table.insert(steps, "GO!")

		for i, text in ipairs(steps) do
			-- if a newer token starts, CD:cancel() will kill this thread automatically
			self.label.Text = text
			self.label.TextColor3 = (text == "GO!") and Color3.fromRGB(80,255,140) or Color3.new(1,1,1)
			self.label.TextTransparency = 0
			self.scale.Scale = 0.85
			TweenService:Create(self.scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()

			task.wait((text == "GO!" and 0.6 or 1.0))

			if i < #steps then
				TweenService:Create(self.label, TweenInfo.new(0.08), {TextTransparency = 0.9}):Play()
				task.wait(0.08)
			end
		end

		-- finished normally
		if self.currentToken == myToken then
			self:hide()
		end
	end, self.currentToken)
end

-- Single, token-gated handler (ensure this is the ONLY StartCountdown connection)
local latestToken = 0
StartCountdown.OnClientEvent:Connect(function(seconds: number, token: number?)
	-- guard against stale countdowns
	if token and token <= latestToken then return end
	latestToken = token or (latestToken + 1)
	CD:start(seconds or 10, latestToken)
end)

-- ================== GAME OVER (clickable buttons, optional blur) ==================
local GO = {
	gui=nil :: ScreenGui?,
	overlay=nil :: Frame?,
	card=nil :: Frame?,
	title=nil :: TextLabel?,
	subtitle=nil :: TextLabel?,
	restartBtn=nil :: TextButton?,
	quitBtn=nil :: TextButton?,
	scale=nil :: UIScale?,
	wired=false,
}

local function makeBtn(text: string, color: Color3): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(220, 60)
	b.Text = text
	b.Font = Enum.Font.GothamBold
	b.TextScaled = true
	b.TextColor3 = Color3.fromRGB(255,255,255)
	b.BackgroundColor3 = color
	b.AutoButtonColor = true
	b.ZIndex = 21
	b.Active = true
	b.Selectable = true
	Instance.new("UICorner", b).CornerRadius = UDim.new(0,14)
	local s = Instance.new("UIStroke", b); s.Thickness = 1.5; s.Color = Color3.fromRGB(255,255,255); s.Transparency = 0.6
	return b
end

function GO:build()
	self.gui = ensureGui("GameOverGui", 1200)
	if self.gui:FindFirstChild("Overlay") then self.gui.Overlay:Destroy() end

	self.overlay = Instance.new("Frame")
	self.overlay.Name = "Overlay"
	self.overlay.Size = UDim2.fromScale(1,1)
	self.overlay.BackgroundColor3 = Color3.fromRGB(0,0,0)
	self.overlay.BackgroundTransparency = 0.35
	self.overlay.Visible = false
	self.overlay.ZIndex = 10
	self.overlay.Active = false
	self.overlay.Parent = self.gui

	self.card = Instance.new("Frame")
	self.card.Name = "Card"
	self.card.Size = UDim2.fromOffset(560, 340)
	self.card.AnchorPoint = Vector2.new(0.5,0.5)
	self.card.Position = UDim2.fromScale(0.5,0.5)
	self.card.BackgroundColor3 = Color3.fromRGB(26,26,28)
	self.card.BackgroundTransparency = 0.05
	self.card.ZIndex = 11
	self.card.Active = true
	self.card.Parent = self.overlay
	Instance.new("UICorner", self.card).CornerRadius = UDim.new(0,22)
	local stroke = Instance.new("UIStroke", self.card); stroke.Thickness = 2; stroke.Color = Color3.fromRGB(255,80,80)

	local grad = Instance.new("UIGradient", self.card)
	grad.Color = ColorSequence.new{
		ColorSequenceKeypoint.new(0, Color3.fromRGB(40,40,44)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(20,20,22)),
	}
	grad.Rotation = 90

	local layout = Instance.new("UIListLayout", self.card)
	layout.Padding = UDim.new(0,12)
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center

	local pad = Instance.new("UIPadding", self.card)
	pad.PaddingTop = UDim.new(0,24)
	pad.PaddingBottom = UDim.new(0,24)
	pad.PaddingLeft = UDim.new(0,24)
	pad.PaddingRight = UDim.new(0,24)

	self.title = Instance.new("TextLabel")
	self.title.Name = "Title"
	self.title.Text = "GAME OVER"
	self.title.Font = Enum.Font.GothamBlack
	self.title.TextScaled = true
	self.title.Size = UDim2.fromOffset(480, 76)
	self.title.TextColor3 = Color3.fromRGB(255,255,255)
	self.title.BackgroundTransparency = 1
	self.title.ZIndex = 19
	self.title.Parent = self.card

	self.subtitle = Instance.new("TextLabel")
	self.subtitle.Name = "Subtitle"
	self.subtitle.Text = "Your health reached zero."
	self.subtitle.Font = Enum.Font.Gotham
	self.subtitle.TextScaled = true
	self.subtitle.Size = UDim2.fromOffset(480, 40)
	self.subtitle.TextColor3 = Color3.fromRGB(230,230,230)
	self.subtitle.BackgroundTransparency = 1
	self.subtitle.ZIndex = 19
	self.subtitle.Parent = self.card

	local row = Instance.new("Frame")
	row.Name = "Buttons"
	row.Size = UDim2.fromOffset(480, 80)
	row.BackgroundTransparency = 1
	row.ZIndex = 20
	row.Parent = self.card
	local h = Instance.new("UIListLayout", row)
	h.FillDirection = Enum.FillDirection.Horizontal
	h.HorizontalAlignment = Enum.HorizontalAlignment.Center
	h.VerticalAlignment = Enum.VerticalAlignment.Center
	h.Padding = UDim.new(0, 16)

	self.restartBtn = makeBtn("Restart", Color3.fromRGB(64,160,112)); self.restartBtn.Parent = row
	self.quitBtn    = makeBtn("Quit",    Color3.fromRGB(200,70,70));  self.quitBtn.Parent = row

	self.scale = Instance.new("UIScale", self.card)
	self.scale.Scale = 0.85
end

function GO:show(titleText: string?, subText: string?)
	releaseAllUIBlocks()
	clearAllBlur()
	CD:hide()

	if not self.gui then self:build() end
	self.title.Text = titleText or "GAME OVER"
	if subText then self.subtitle.Text = subText end
	self.overlay.Visible = true

	if USE_GAMEOVER_BLUR then
		local blur = Instance.new("BlurEffect")
		blur.Name = "GameOverBlur"
		blur.Size = 18
		blur.Parent = Lighting
	end

	self.scale.Scale = 0.85
	TweenService:Create(self.scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()

	if not self.wired then
		self.restartBtn.Activated:Connect(function()
			self:hide()
			RestartRequested:FireServer()
		end)
		if QuitRequested then
			self.quitBtn.Activated:Connect(function()
				QuitRequested:FireServer()
			end)
		else
			self.quitBtn.Visible = false
		end
		self.wired = true
	end
end

function GO:hide()
	self.overlay.Visible = false
	clearAllBlur()
	releaseAllUIBlocks()
end

-- ==== Remote wiring ====
GameOverEvent.OnClientEvent:Connect(function(msg, sub) GO:show(msg, sub) end)

-- ================== FRUIT FEEDBACK: Floating +points popup ==================
local function fruitColor(name: string?): Color3
	name = tostring(name or "")
	if name == "Apple"  then return Color3.fromRGB(255, 70,  70) end
	if name == "Orange" then return Color3.fromRGB(255,150, 30) end
	if name == "Banana" then return Color3.fromRGB(255,220, 40) end
	return Color3.fromRGB(255,180,  0)
end

local function spawnPointsPopup(worldPos: Vector3, color: Color3, text: string)
	local anchor = Instance.new("Attachment")
	anchor.WorldPosition = worldPos + Vector3.new(0, 0.6, 0)
	anchor.Parent = workspace.Terrain

	local gui = Instance.new("BillboardGui")
	gui.Name = "PointsPopup"
	gui.Adornee = anchor
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 500
	gui.Size = UDim2.fromOffset(1, 1)
	gui.Parent = anchor

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Text = text
	lbl.Font = Enum.Font.GothamBlack
	lbl.TextScaled = true
	lbl.TextColor3 = color
	lbl.TextTransparency = 1 -- start invisible
	lbl.Size = UDim2.fromOffset(200, 70)
	lbl.AnchorPoint = Vector2.new(0.5, 0.5)
	lbl.Position = UDim2.fromScale(0.5, 0.5)
	lbl.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(20,20,20)
	stroke.Thickness = 2
	stroke.Transparency = 0.25
	stroke.Parent = lbl

	local scale = Instance.new("UIScale"); scale.Scale = 0.7; scale.Parent = lbl

	local jitter = (math.random() - 0.5) * 0.8
	gui.StudsOffset = Vector3.new(jitter, 0, 0)

	local fadeIn  = TweenService:Create(lbl,  TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { TextTransparency = 0 })
	local grow    = TweenService:Create(scale,TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.25 })
	local drift   = TweenService:Create(gui,  TweenInfo.new(0.7,  Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { StudsOffset = Vector3.new(jitter, 2.6, 0) })
	local fadeOut = TweenService:Create(lbl,  TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In),  { TextTransparency = 1 })
	local strokeFade = TweenService:Create(stroke, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 })

	fadeIn:Play(); grow:Play(); drift:Play()
	task.delay(0.18, function() if stroke then strokeFade:Play() end end)
	task.delay(0.42, function() fadeOut:Play() end)
	task.delay(1.1, function() if anchor then anchor:Destroy() end end)
end

local function cameraShake(duration, magnitude)
	local cam = workspace.CurrentCamera; if not cam then return end
	local start = tick(); local base = cam.CFrame
	local conn; conn = RunService.RenderStepped:Connect(function()
		local t = tick() - start
		if t >= duration then if conn then conn:Disconnect() end cam.CFrame = base; return end
		local alpha = 1 - (t/duration)
		local dx = (math.noise(t*30, 0, 0)-0.5)*2 * magnitude * alpha
		local dy = (math.noise(0, t*30, 0)-0.5)*2 * magnitude * alpha
		cam.CFrame = base * CFrame.new(dx, dy, 0)
	end)
end

local function rumble(duration, strength)
	for _, t in ipairs(Enum.UserInputType:GetEnumItems()) do
		if t.Name:find("Gamepad") then
			local slot = Enum.UserInputType[t.Name]
			if HapticService:IsMotorSupported(slot, Enum.VibrationMotor.Large) then
				HapticService:SetMotor(slot, Enum.VibrationMotor.Large, strength)
				task.delay(duration, function()
					HapticService:SetMotor(slot, Enum.VibrationMotor.Large, 0)
				end)
			end
		end
	end
end

if FruitSmashed then
	FruitSmashed.OnClientEvent:Connect(function(payload)
		local pts = tonumber(payload.Points) or 0
		if payload.Position and pts > 0 then
			spawnPointsPopup(payload.Position, fruitColor(payload.Fruit), ("+%d"):format(pts))
		end
		-- subtle feel
		cameraShake(0.12, 0.08)
		rumble(0.10, 0.25)
	end)
end
