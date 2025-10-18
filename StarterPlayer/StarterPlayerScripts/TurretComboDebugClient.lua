-- TurretComboDebugClient (LOCAL)
-- Shows a tiny floating label "step • slot" above the turret that just fired.

local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Remotes = RS:WaitForChild("Remotes")
local TurretFireDebug = Remotes:WaitForChild("TurretFireDebug") :: RemoteEvent

local function getAnchorFromModel(model: Instance): Instance?
	if not model or not model:IsA("Model") then return nil end
	local bp = model:FindFirstChildWhichIsA("BasePart")
	if not bp then return nil end

	local att = Instance.new("Attachment")
	att.Name = "ComboDebugAnchor"
	att.WorldPosition = bp.Position + Vector3.new(0, 4, 0)
	att.Parent = bp
	return att
end

local function showPopup(stepNum: number, slotNum: number, model: Instance)
	local anchor = getAnchorFromModel(model)
	if not anchor then return end

	local gui = Instance.new("BillboardGui")
	gui.Name = "ComboDebugBillboard"
	gui.AlwaysOnTop = true
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(100, 28)
	gui.StudsOffset = Vector3.new(0, 0.5, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = 200
	gui.Parent = anchor

	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.TextScaled = true
	text.Font = Enum.Font.GothamBold
	text.Text = string.format("%d • %d", stepNum, slotNum)
	text.TextColor3 = Color3.fromRGB(255, 240, 120)
	text.TextStrokeTransparency = 0.35
	text.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Transparency = 0.2
	stroke.Parent = text

	-- little rise + fade
	local tween1 = TweenService:Create(gui, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{Size = UDim2.fromOffset(120, 34)})
	local tween2 = TweenService:Create(text, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{TextTransparency = 1, TextStrokeTransparency = 1})

	tween1:Play()
	task.delay(0.15, function() tween2:Play() end)

	game:GetService("Debris"):AddItem(anchor, 0.65)
end

TurretFireDebug.OnClientEvent:Connect(showPopup)
