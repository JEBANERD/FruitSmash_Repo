-- MeleeServer (Mega Juice + Points Payload + Safe Destroy + Powerup Drops)
-- Drop-in replacement that preserves public APIs and behavior, adds a safe powerup drop hook
-- and rock-solid projectile cleanup.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

-- === Remotes & assets ===
local Remotes = RS:WaitForChild("Remotes")
local PlayerSwing: RemoteEvent = Remotes:WaitForChild("PlayerSwing")

local FruitSmashed: RemoteEvent = Remotes:FindFirstChild("FruitSmashed") or Instance.new("RemoteEvent")
FruitSmashed.Name = "FruitSmashed"
FruitSmashed.Parent = Remotes

-- Round points sink (server-only). Create if missing for robustness.
local RoundPointsAdd: BindableEvent = Remotes:FindFirstChild("RoundPointsAdd") :: BindableEvent
if not RoundPointsAdd then
	RoundPointsAdd = Instance.new("BindableEvent")
	RoundPointsAdd.Name = "RoundPointsAdd"
	RoundPointsAdd.Parent = Remotes
end

local Assets = RS:WaitForChild("Assets")
local Sounds = Assets:WaitForChild("Sounds")
local SFX_FruitSplat: Sound = Sounds:WaitForChild("SFX_FruitSplat")

-- Scoring (server authoritative)
local ScoreService = require(game.ServerScriptService:WaitForChild("ScoreService"))
local POINTS = { Apple = 10, Banana = 12, Orange = 16 }

-- Powerup service
local PowerupDropService = require(game.ServerScriptService:WaitForChild("PowerupDropService"))

-- Live projectiles container
local ActiveProjectiles: Folder = Workspace:WaitForChild("ActiveProjectiles")

-- === Drop tuning ===
-- Adjust per-fruit drop pools to match ReplicatedStorage/PowerupTemplates names
local POWERUP_POOLS: {[string]: {{Name:string, Weight:number}}} = {
	Apple  = { {Name="CoinBoost",Weight=6}, {Name="HealthPack",Weight=3}, {Name="Shield",Weight=1} },
	Banana = { {Name="CoinBoost",Weight=4}, {Name="HealthPack",Weight=4}, {Name="Shield",Weight=2} },
	Orange = { {Name="CoinBoost",Weight=3}, {Name="HealthPack",Weight=3}, {Name="Shield",Weight=4} },
}

-- === MEGA JUICE TUNABLES ===
local MEGA = {
	SWING_COOLDOWN = 0.25,
	BOX = Vector3.new(6, 6, 8),
	BOX_FORWARD_OFFSET = 4,
	MAX_HIT_COUNT = 10,

	-- Particles
	BURST_TEXTURE = "rbxassetid://258128463",
	BURST = { EMIT = 120, SIZE0 = 6.0, SIZE1 = 3.0, SIZE2 = 0.4, SPD0 = 28, SPD1 = 52, LIFE0 = 1.0, LIFE1 = 1.6, DRAG = 2.0, OPAC0 = 0.04, OPAC1 = 0.85 },
	MIST  = { EMIT = 90, SIZE0 = 9.0, SPD0 = 12, SPD1 = 20, LIFE0 = 1.2, LIFE1 = 1.8, DRAG = 1.8, OPAC0 = 0.12, OPAC1 = 0.96 },

	RING_START = 20, RING_END = 100, RING_TIME = 0.4, RING_FADE = 0.12,

	-- Billboard splat
	SPLAT_IMAGE_ID = "rbxassetid://1095708",
	SPLAT_START_STUDS = 18, SPLAT_MAX_STUDS = 55, SPLAT_FADE_TIME = 1.6, SPLAT_OFFSET_Y = 0.6, SPLAT_CLEANUP = 2.6,

	-- Audio / cleanup
	SOUND_VOL = 0.35, SOUND_MIN = 5, SOUND_MAX = 90,
	EMITTER_CLEANUP = 3.0,
}

local lastSwing : {[Player]: number} = {}

-- === Cleanup helper (idempotent) ===
local function SafeDestroy(inst: Instance?)
	if not inst or inst.Parent == nil then return end
	Debris:AddItem(inst, 0) -- queued immediate removal (safer than :Destroy() in hot paths)
end

-- === Helpers ===
local function isFruit(inst: Instance): boolean
	-- walk up a few ancestors looking for FruitName attribute
	local o: Instance? = inst
	for _ = 1, 4 do
		if not o then break end
		if o:GetAttribute("FruitName") ~= nil then return true end
		o = o.Parent
	end
	return false
end

-- Returns (container, rootPart). Never returns the ActiveProjectiles folder itself.
local function getFruitContainer(inst: Instance): (Instance?, BasePart?)
	local part: BasePart? = inst:IsA("BasePart") and inst or inst:FindFirstAncestorWhichIsA("BasePart")
	if not part then return nil, nil end

	-- If it's inside a Model under ActiveProjectiles, return the model + its root
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:IsDescendantOf(ActiveProjectiles) then
		local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
		return model, root
	end

	-- If it's a naked part directly under ActiveProjectiles, return the part as both
	if part:IsDescendantOf(ActiveProjectiles) then
		return part, part
	end

	return nil, nil
end

local function playSplatAt(position: Vector3)
	local emitter = Instance.new("Part")
	emitter.Name = "SFX_Emitter"
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.Transparency = 1
	emitter.Size = Vector3.new(0.2, 0.2, 0.2)
	emitter.CFrame = CFrame.new(position)
	emitter.Parent = Workspace

	local s = Instance.new("Sound")
	s.Name = "SFX_FruitSplatRuntime"
	s.SoundId = SFX_FruitSplat.SoundId
	s.Volume = math.max(MEGA.SOUND_VOL, SFX_FruitSplat.Volume)
	s.PlaybackSpeed = SFX_FruitSplat.PlaybackSpeed > 0 and SFX_FruitSplat.PlaybackSpeed or 1
	s.RollOffMode = Enum.RollOffMode.Inverse
	s.RollOffMinDistance = MEGA.SOUND_MIN
	s.RollOffMaxDistance = MEGA.SOUND_MAX
	s.EmitterSize = 6
	s.Parent = emitter
	s:Play()

	Debris:AddItem(emitter, 2)
end

local function makeBurstParticles(position: Vector3, color: Color3)
	local p = Instance.new("Part")
	p.Name = "FX_Emitter"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.CFrame = CFrame.new(position)
	p.Parent = Workspace

	local a = Instance.new("Attachment")
	a.Parent = p
	local tex = MEGA.BURST_TEXTURE

	-- Burst
	local burst = Instance.new("ParticleEmitter")
	burst.Name = "FruitBurst"
	burst.Parent = a
	burst.Texture = tex
	burst.Color = ColorSequence.new(color)
	burst.Lifetime = NumberRange.new(MEGA.BURST.LIFE0, MEGA.BURST.LIFE1)
	burst.Speed = NumberRange.new(MEGA.BURST.SPD0, MEGA.BURST.SPD1)
	burst.SpreadAngle = Vector2.new(360, 360)
	burst.Rotation = NumberRange.new(0, 360)
	burst.RotSpeed = NumberRange.new(-180, 180)
	burst.Drag = MEGA.BURST.DRAG
	burst.LightInfluence = 0
	burst.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0.0, MEGA.BURST.SIZE0),
		NumberSequenceKeypoint.new(0.3, MEGA.BURST.SIZE1),
		NumberSequenceKeypoint.new(1.0, MEGA.BURST.SIZE2),
	})
	burst.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0.0, MEGA.BURST.OPAC0),
		NumberSequenceKeypoint.new(1.0, MEGA.BURST.OPAC1),
	})
	burst.Rate = 0
	burst:Emit(MEGA.BURST.EMIT)

	-- Mist
	local mist = Instance.new("ParticleEmitter")
	mist.Name = "FruitMist"
	mist.Parent = a
	mist.Texture = tex
	mist.Color = ColorSequence.new(Color3.new(1,1,1), color)
	mist.Lifetime = NumberRange.new(MEGA.MIST.LIFE0, MEGA.MIST.LIFE1)
	mist.Speed = NumberRange.new(MEGA.MIST.SPD0, MEGA.MIST.SPD1)
	mist.SpreadAngle = Vector2.new(360, 360)
	mist.Drag = MEGA.MIST.DRAG
	mist.LightInfluence = 0
	mist.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0.0, MEGA.MIST.SIZE0),
		NumberSequenceKeypoint.new(1.0, 0.0),
	})
	mist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0.0, MEGA.MIST.OPAC0),
		NumberSequenceKeypoint.new(1.0, MEGA.MIST.OPAC1),
	})
	mist.Rate = 0
	mist:Emit(MEGA.MIST.EMIT)

	-- Shockwave ring
	local ring = Instance.new("BillboardGui")
	ring.Name = "PopRing"
	ring.AlwaysOnTop = true
	ring.LightInfluence = 0
	ring.Size = UDim2.fromOffset(MEGA.RING_START, MEGA.RING_START)
	ring.Adornee = a
	ring.Parent = p

	local ringImg = Instance.new("ImageLabel")
	ringImg.BackgroundTransparency = 1
	ringImg.Image = tex
	ringImg.ImageColor3 = color
	ringImg.Size = UDim2.fromScale(1, 1)
	ringImg.ImageTransparency = MEGA.RING_FADE
	ringImg.Parent = ring

	local ti = TweenInfo.new(MEGA.RING_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ring, ti, { Size = UDim2.fromOffset(MEGA.RING_END, MEGA.RING_END) }):Play()
	TweenService:Create(ringImg, ti, { ImageTransparency = 0.95 }):Play()

	Debris:AddItem(p, MEGA.EMITTER_CLEANUP)
end

local function makeSplatBillboard(position: Vector3, color: Color3)
	local anchor = Instance.new("Attachment")
	anchor.WorldPosition = position + Vector3.new(0, MEGA.SPLAT_OFFSET_Y, 0)
	anchor.Parent = Workspace.Terrain

	local gui = Instance.new("BillboardGui")
	gui.Name = "FruitSplatBillboard"
	gui.Adornee = anchor
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 500
	gui.Size = UDim2.fromOffset(1, 1)
	gui.Parent = anchor

	local img = Instance.new("ImageLabel")
	img.Name = "SplatImage"
	img.BackgroundTransparency = 1
	img.Image = MEGA.SPLAT_IMAGE_ID
	img.ImageColor3 = color
	img.ImageTransparency = 0.08
	img.Size = UDim2.fromScale(1, 1)
	img.ScaleType = Enum.ScaleType.Fit
	img.Parent = gui

	gui.Size = UDim2.fromOffset(MEGA.SPLAT_START_STUDS * 10, MEGA.SPLAT_START_STUDS * 10)
	task.spawn(function()
		local grow = TweenService:Create(gui, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = UDim2.fromOffset(MEGA.SPLAT_MAX_STUDS * 10, MEGA.SPLAT_MAX_STUDS * 10) })
		local fade = TweenService:Create(img, TweenInfo.new(MEGA.SPLAT_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ ImageTransparency = 1 })
		grow:Play(); fade:Play()
	end)

	Debris:AddItem(anchor, MEGA.SPLAT_CLEANUP)
end

-- === Main handler ===
PlayerSwing.OnServerEvent:Connect(function(player: Player, rootCF: CFrame)
	local now = os.clock()
	if lastSwing[player] and (now - lastSwing[player]) < MEGA.SWING_COOLDOWN then return end
	lastSwing[player] = now

	local char = player.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	-- Box in front of player
	local forward = rootCF.LookVector
	local center = hrp.Position + forward * (MEGA.BOX_FORWARD_OFFSET + MEGA.BOX.Z * 0.5)
	local size = MEGA.BOX
	local boxCFrame = CFrame.new(center, center + forward)

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }

	local parts = Workspace:GetPartBoundsInBox(boxCFrame, size, params)
	local destroyed = 0

	for _, part in ipairs(parts) do
		if isFruit(part) then
			local container, rootPart = getFruitContainer(part)
			if container and rootPart and not rootPart:GetAttribute("Batted") then
				rootPart:SetAttribute("Batted", true)

				local fruitName = rootPart:GetAttribute("FruitName") or container:GetAttribute("FruitName") or "Fruit"
				local color = (fruitName == "Apple" and Color3.fromRGB(255, 70, 70))
					or (fruitName == "Orange" and Color3.fromRGB(255,150, 30))
					or (fruitName == "Banana" and Color3.fromRGB(255,220, 40))
					or Color3.fromRGB(255,180, 0)

				local hitPos = rootPart.Position

				-- FX
				playSplatAt(hitPos)
				makeBurstParticles(hitPos, color)
				makeSplatBillboard(hitPos, color)

				-- Scoring
				local pts = POINTS[fruitName] or 10
				ScoreService.AddPoints(player, pts, fruitName)

				-- Round points -> RoundDirector
				if RoundPointsAdd then
					RoundPointsAdd:Fire(pts)
				end

				-- Client feedback (local +points/UI)
				FruitSmashed:FireClient(player, {
					Position = hitPos,
					Fruit = fruitName,
					Points = pts,
				})

				-- Powerup drop (random chance, server-side)
				PowerupDropService.MaybeDrop(hitPos, fruitName, POWERUP_POOLS)

				-- === Robust projectile cleanup ===
				-- If the fruit was a lone part under ActiveProjectiles, clean that part; if a Model, clean the model.
				if container:IsA("Model") then
					SafeDestroy(container)
				else
					SafeDestroy(rootPart or container)
				end

				-- Reaper fallback: if anything still lingers, clean again shortly.
				task.delay(0.1, function()
					if container and container.Parent then SafeDestroy(container) end
					if rootPart and rootPart.Parent then SafeDestroy(rootPart) end
				end)

				destroyed += 1
				if destroyed >= MEGA.MAX_HIT_COUNT then break end
			end
		end
	end
end)
