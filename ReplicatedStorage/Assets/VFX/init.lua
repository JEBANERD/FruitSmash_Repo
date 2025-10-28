local VFXAssets = {}

local function createBasePart(name)
	local part = Instance.new("Part")
	part.Name = name .. "Root"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)

	return part
end

VFXAssets.FruitPop = {
	Type = "World",
	Lifetime = 0.6,
	Emitters = {
		{ Name = "Burst", Count = NumberRange.new(18, 24) },
	},
	Factory = function()
		local root = createBasePart("FruitPop")

		local attachment = Instance.new("Attachment")
		attachment.Name = "BurstAttachment"
		attachment.Parent = root

		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Burst"
		emitter.LightEmission = 0.5
		emitter.Lifetime = NumberRange.new(0.35, 0.55)
		emitter.Speed = NumberRange.new(16, 22)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-180, 180)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.9, 0),
			NumberSequenceKeypoint.new(0.4, 0.45, 0.1),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.6, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Color = ColorSequence.new(
			Color3.fromRGB(255, 138, 46),
			Color3.fromRGB(255, 234, 142)
		)
		emitter.Drag = 3
		emitter.Parent = attachment

		return root
	end,
}

VFXAssets.CoinBurst = {
	Type = "World",
	Lifetime = 0.75,
	Emitters = {
		{ Name = "Coins", Count = NumberRange.new(10, 14) },
	},
	Factory = function()
		local root = createBasePart("CoinBurst")

		local attachment = Instance.new("Attachment")
		attachment.Name = "CoinAttachment"
		attachment.Parent = root

		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Coins"
		emitter.LightEmission = 0.3
		emitter.Lifetime = NumberRange.new(0.45, 0.65)
		emitter.Speed = NumberRange.new(14, 20)
		emitter.SpreadAngle = Vector2.new(120, 120)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-90, 90)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.7),
			NumberSequenceKeypoint.new(0.3, 0.5),
			NumberSequenceKeypoint.new(1, 0.1),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.6, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Color = ColorSequence.new(
			Color3.fromRGB(255, 223, 96),
			Color3.fromRGB(255, 162, 43)
		)
		emitter.Drag = 2
		emitter.Parent = attachment

		return root
	end,
}

VFXAssets.ShieldBubble = {
	Type = "World",
	Lifetime = 1.4,
	Emitters = {
		{ Name = "Shell", Count = NumberRange.new(32, 40) },
		{ Name = "Sparkle", Count = NumberRange.new(10, 16) },
	},
	Factory = function()
		local root = createBasePart("ShieldBubble")

		local attachment = Instance.new("Attachment")
		attachment.Name = "ShellAttachment"
		attachment.Parent = root

		local shell = Instance.new("ParticleEmitter")
		shell.Name = "Shell"
		shell.Shape = Enum.ParticleEmitterShape.Sphere
		shell.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		shell.Lifetime = NumberRange.new(0.9, 1.1)
		shell.Speed = NumberRange.new(0, 0)
		shell.SpreadAngle = Vector2.new(0, 0)
		shell.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 4),
			NumberSequenceKeypoint.new(1, 0),
		})
		shell.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		})
		shell.Color = ColorSequence.new(
			Color3.fromRGB(133, 226, 255),
			Color3.fromRGB(48, 153, 255)
		)
		shell.LightEmission = 0.6
		shell.Parent = attachment

		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Name = "Sparkle"
		sparkle.Shape = Enum.ParticleEmitterShape.Sphere
		sparkle.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
		sparkle.Lifetime = NumberRange.new(0.5, 0.7)
		sparkle.Speed = NumberRange.new(1, 3)
		sparkle.SpreadAngle = Vector2.new(360, 360)
		sparkle.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 0),
		})
		sparkle.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		sparkle.Color = ColorSequence.new(
			Color3.fromRGB(255, 255, 255),
			Color3.fromRGB(148, 209, 255)
		)
		sparkle.LightEmission = 0.6
		sparkle.Parent = attachment

		return root
	end,
}

VFXAssets.CritSparkle = {
	Type = "UI",
	Lifetime = 0.45,
	InitialSize = UDim2.fromOffset(26, 26),
	EndSize = UDim2.fromOffset(44, 44),
	FadeFrom = 0.05,
	FadeTo = 1,
	TweenInfo = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	ZIndexOffset = 5,
	AllowRandomRotation = true,
	Factory = function()
		local image = Instance.new("ImageLabel")
		image.Name = "CritSparkle"
		image.BackgroundTransparency = 1
		image.AnchorPoint = Vector2.new(0.5, 0.5)
		image.Size = UDim2.fromOffset(26, 26)
		image.Image = "rbxassetid://3926305904"
		image.ImageRectOffset = Vector2.new(364, 324)
		image.ImageRectSize = Vector2.new(68, 68)
		image.ImageColor3 = Color3.fromRGB(255, 242, 143)
		image.ImageTransparency = 1
		image.ResampleMode = Enum.ResamplerMode.Pixelated
		image.Visible = false

		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new(
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 214, 94))
		)
		gradient.Rotation = -35
		gradient.Parent = image

		return image
	end,
}

return VFXAssets
