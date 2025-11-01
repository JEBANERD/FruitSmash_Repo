--!strict
local FruitSpawnerServer = {}

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("FruitConfig"))
local ArenaAdapter = require(script.Parent:WaitForChild("Libraries"):WaitForChild("ArenaAdapter"))
local ContentRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"):WaitForChild("ContentRegistry"))

local ProjectileServer: any = nil
do
	local primaryModule = script.Parent:FindFirstChild("ProjectileServer")
	if primaryModule and primaryModule:IsA("ModuleScript") then
		local ok, result = pcall(require, primaryModule)
		if ok then
			ProjectileServer = result
		else
			warn(string.format("[FruitSpawnerServer] Failed to require ProjectileServer: %s", tostring(result)))
		end
	end

	if not ProjectileServer then
		local combatFolder = ServerScriptService:FindFirstChild("Combat")
		local projectileServerModule = combatFolder and combatFolder:FindFirstChild("ProjectileServer")
		if projectileServerModule and projectileServerModule:IsA("ModuleScript") then
			local ok, result = pcall(require, projectileServerModule)
			if ok then
				ProjectileServer = result
			else
				warn(string.format("[FruitSpawnerServer] Failed to require ProjectileServer: %s", tostring(result)))
			end
		else
			warn("[FruitSpawnerServer] ProjectileServer module is missing")
		end
	end
end

local ProjectileMotionServer: any = nil
do
	local projectileModule = script.Parent:FindFirstChild("ProjectileMotionServer")
	if projectileModule and projectileModule:IsA("ModuleScript") then
		local ok, result = pcall(require, projectileModule)
		if ok then
			ProjectileMotionServer = result
		else
			warn(string.format("[FruitSpawnerServer] Failed to require ProjectileMotionServer: %s", tostring(result)))
		end
	end
end

local random = Random.new()

local FRUIT_ASSET_PREFIX = "Fruit."
local FALLBACK_FRUIT_ASSET_ID = "Fruit.Fallback"

local LANE_FRUIT_CONTAINER = "FruitProjectiles"
local DEFAULT_FRUIT_SIZE = Vector3.new(1, 1, 1)
local SIZE_BY_TAG = {
	XS = Vector3.new(0.6, 0.6, 0.6),
	S = Vector3.new(0.9, 0.9, 0.9),
	M = Vector3.new(1.2, 1.2, 1.2),
	L = Vector3.new(1.6, 1.6, 1.6),
	XL = Vector3.new(2, 2, 2),
}

do
	local roster = FruitConfig.All()
	local preloadIds = { FALLBACK_FRUIT_ASSET_ID }

	for fruitId in pairs(roster) do
		table.insert(preloadIds, FRUIT_ASSET_PREFIX .. fruitId)
	end

	ContentRegistry.Preload(preloadIds)
end

local arenaQueues = {}

local function ensureArenaQueue(arenaId)
	local state = arenaQueues[arenaId]
	if not state then
		state = {
			running = false,
			queue = {},
			processing = false,
		}
		arenaQueues[arenaId] = state
	end

	return state
end

local function discardArenaQueue(arenaId)
	arenaQueues[arenaId] = nil
end

local function getFruitSize(stats)
	if not stats then
		return DEFAULT_FRUIT_SIZE
	end

	local sizeTag = stats.Size
	if typeof(sizeTag) ~= "string" then
		return DEFAULT_FRUIT_SIZE
	end

	return SIZE_BY_TAG[sizeTag] or DEFAULT_FRUIT_SIZE
end

local function applyPhysicsDefaults(part)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Locked = false
end

local function setAttribute(target, attribute, value)
	if value == nil then
		return
	end

	local ok, err = pcall(function()
		target:SetAttribute(attribute, value)
	end)

	if not ok then
		warn(string.format("[FruitSpawnerServer] Failed to set attribute '%s' on %s: %s", tostring(attribute), target:GetFullName(), tostring(err)))
	end
end

local function describeInstance(instance)
	if not instance then
		return "<nil>"
	end

	local ok, fullName = pcall(function()
		return instance:GetFullName()
	end)

	if ok then
		return fullName
	end

	return tostring(instance)
end

local function setAttributeIfPresent(instance, name, value)
	if instance and value ~= nil then
		instance:SetAttribute(name, value)
	end
end

local function bindProjectile(instance, pathProfile)
	if not instance or not ProjectileMotionServer then
		return
	end

	local binder = ProjectileMotionServer :: any
	local bindFunction
	if typeof(binder.Bind) == "function" then
		bindFunction = binder.Bind
	elseif typeof(binder.BindProjectile) == "function" then
		bindFunction = binder.BindProjectile
	end

	if not bindFunction then
		return
	end

	local ok, err = pcall(bindFunction, binder, instance, pathProfile)
	if not ok then
		warn(string.format("[FruitSpawnerServer] Failed to bind projectile motion for %s: %s", describeInstance(instance), tostring(err)))
	end
end

local function configureProjectile(instance, stats, pathProfile)
	if not instance then
		return
	end

	if pathProfile then
		setAttributeIfPresent(instance, "ArenaId", pathProfile.ArenaId)
		setAttributeIfPresent(instance, "LaneId", pathProfile.LaneId)
		setAttributeIfPresent(instance, "FruitId", pathProfile.FruitId)
	end

	bindProjectile(instance, pathProfile)

	if ProjectileServer and type(ProjectileServer.Track) == "function" then
		local params = {
			ArenaId = pathProfile and pathProfile.ArenaId,
			LaneId = pathProfile and pathProfile.LaneId,
			FruitId = stats and stats.Id,
			Speed = instance:GetAttribute("Speed") or (stats and stats.Speed),
			Damage = instance:GetAttribute("Damage") or (stats and stats.Damage),
		}

		local ok, err = pcall(ProjectileServer.Track, instance, params)
		if not ok then
			warn(string.format("[FruitSpawnerServer] Failed to track projectile for %s: %s", describeInstance(instance), tostring(err)))
		end
	end
end

local function applyOwnershipAttributes(target, arenaId, laneIdentifier, laneIndex)
	setAttribute(target, "ArenaId", arenaId)
	setAttribute(target, "Lane", laneIdentifier)
	if laneIndex ~= nil then
		setAttribute(target, "LaneIndex", laneIndex)
	end
end

local function tagInstance(instance, arenaId, laneIdentifier, laneIndex)
	if not instance then
		return
	end

	local tags = { "Fruit", "ArenaId", "Lane" }
	for _, tag in ipairs(tags) do
		local ok, err = pcall(CollectionService.AddTag, CollectionService, instance, tag)
		if not ok then
			warn(string.format("[FruitSpawnerServer] Failed to apply tag '%s' to %s: %s", tag, instance:GetFullName(), tostring(err)))
		end
	end

	applyOwnershipAttributes(instance, arenaId, laneIdentifier, laneIndex)
end

local function applyFruitAttributes(target, stats, overrides, fruitId)
	overrides = overrides or {}

	if fruitId == nil and stats then
		fruitId = stats.Id
	end

	setAttribute(target, "FruitId", fruitId)
	if stats then
		setAttribute(target, "Speed", overrides.Speed or stats.Speed)
		setAttribute(target, "Damage", overrides.Damage or stats.Damage)
		setAttribute(target, "Wear", overrides.Wear or stats.Wear)
		setAttribute(target, "Coins", overrides.Coins or stats.Coins)
		setAttribute(target, "Points", overrides.Points or stats.Points)
		setAttribute(target, "Path", overrides.Path or stats.Path)
		setAttribute(target, "HPClass", overrides.HPClass or stats.HPClass)
		setAttribute(target, "Size", stats.Size)
	end
end

local function ensureLaneContainer(lane)
	if not lane then
		return nil
	end

	local container = lane:FindFirstChild(LANE_FRUIT_CONTAINER)
	if not container then
		container = Instance.new("Folder")
		container.Name = LANE_FRUIT_CONTAINER
		container.Parent = lane
	end

	return container
end

local function getLaneCFrame(lane)
	if not lane then
		return CFrame.new()
	end

	if lane:IsA("BasePart") then
		return lane.CFrame
	end

	if lane:IsA("Model") then
		local primary = lane.PrimaryPart or lane:FindFirstChildWhichIsA("BasePart")
		if primary then
			return primary.CFrame
		end
	end

	return CFrame.new()
end

local function createFruitPrimitive(name, size, originCFrame)
	local part = Instance.new("Part")
	part.Name = name or "Fruit"
	part.Shape = Enum.PartType.Ball
	part.Size = size or DEFAULT_FRUIT_SIZE
	part.CFrame = originCFrame or CFrame.new()
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.fromRGB(255, 255, 255)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CastShadow = false
	applyPhysicsDefaults(part)

	part:SetAttribute("AttachmentReferenceSize", part.Size)

	local halfSize = part.Size * 0.5
	local attachments = {
		{ Name = "RootAttachment", Offset = Vector3.new() },
		{ Name = "ImpactAttachment", Offset = Vector3.new(0, 0, -halfSize.Z) },
		{ Name = "TrailAttachment", Offset = Vector3.new(0, 0, halfSize.Z) },
		{ Name = "OverheadAttachment", Offset = Vector3.new(0, halfSize.Y, 0) },
	}

	for _, info in ipairs(attachments) do
		local attachment = Instance.new("Attachment")
		attachment.Name = info.Name
		attachment.Position = info.Offset
		attachment:SetAttribute("Offset", info.Offset)
		attachment.Parent = part
	end

	return part
end

local function normalizeFruitAssetId(assetId)
	if typeof(assetId) ~= "string" then
		return nil
	end

	if assetId == "" then
		return nil
	end

	if string.find(assetId, ".", 1, true) then
		return assetId
	end

	return FRUIT_ASSET_PREFIX .. assetId
end

local function rescaleAttachments(basePart, targetSize)
	if not basePart or typeof(targetSize) ~= "Vector3" then
		return
	end

	local referenceSize = basePart:GetAttribute("AttachmentReferenceSize")
	if typeof(referenceSize) ~= "Vector3" then
		return
	end

	local scaleX = referenceSize.X ~= 0 and (targetSize.X / referenceSize.X) or 1
	local scaleY = referenceSize.Y ~= 0 and (targetSize.Y / referenceSize.Y) or 1
	local scaleZ = referenceSize.Z ~= 0 and (targetSize.Z / referenceSize.Z) or 1

	for _, child in ipairs(basePart:GetChildren()) do
		if child:IsA("Attachment") then
			local offset = child:GetAttribute("Offset")
			if typeof(offset) == "Vector3" then
				child.Position = Vector3.new(
					offset.X * scaleX,
					offset.Y * scaleY,
					offset.Z * scaleZ
				)
			end
		end
	end
end

local function configureFruitInstance(instance, size, originCFrame)
	if not instance then
		return nil
	end

	if instance:IsA("Model") then
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("BasePart") then
				applyPhysicsDefaults(descendant)
			end
		end

		local root = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")
		if not instance.PrimaryPart and root then
			instance.PrimaryPart = root
		end

		if root and size then
			root.Size = size
			rescaleAttachments(root, size)
		end

		if originCFrame then
			local ok = pcall(instance.PivotTo, instance, originCFrame)
			if not ok and root then
				root.CFrame = originCFrame
			end
		end

		return root
	end

	local targetPart
	if instance:IsA("BasePart") then
		targetPart = instance
	else
		targetPart = instance:FindFirstChildWhichIsA("BasePart")
	end

	if targetPart then
		applyPhysicsDefaults(targetPart)
		if size then
			targetPart.Size = size
			rescaleAttachments(targetPart, size)
		end
		if originCFrame then
			targetPart.CFrame = originCFrame
		end
	end

	return targetPart
end

local function buildPathProfile(arenaId, laneIdentifier, laneIndex, stats, laneFrame)
	local profileName = "straight"
	if stats and typeof(stats.Path) == "string" and stats.Path ~= "" then
		profileName = stats.Path
	end

	local direction = laneFrame and laneFrame.LookVector or Vector3.new(0, 0, -1)
	local up = laneFrame and laneFrame.UpVector or Vector3.new(0, 1, 0)
	local position = laneFrame and laneFrame.Position or Vector3.new()

	return {
		ArenaId = arenaId,
		LaneId = laneIdentifier,
		LaneIndex = laneIndex,
		FruitId = stats and stats.Id or nil,
		Profile = profileName,
		Direction = direction,
		Up = up,
		Position = position,
		Speed = stats and stats.Speed or nil,
	}
end

local function distributeValue(total, count)
	if count <= 0 then
		return {}
	end

	local base = math.floor(total / count)
	local remainder = total % count
	local distribution = table.create(count, base)

	for index = 1, remainder do
		distribution[index] += 1
	end

	return distribution
end

local function spawnSingleFruit(arenaId, laneIdentifier, laneIndex, stats, container, laneFrame, pathProfile, fruitId)
	local fruitName = stats and stats.Id or fruitId or "Fruit"
	if not stats then
		local fallback = createFruitPrimitive(fruitName, DEFAULT_FRUIT_SIZE, laneFrame)
		fallback.Parent = container

		applyFruitAttributes(fallback, nil, nil, fruitId)
		applyOwnershipAttributes(fallback, arenaId, laneIdentifier, laneIndex)
		tagInstance(fallback, arenaId, laneIdentifier, laneIndex)

		configureProjectile(fallback, nil, pathProfile)

		return fallback
	end

	local assetKey = stats.AssetId or fruitName
	local preferredAssetId = normalizeFruitAssetId(assetKey)

	local fruitInstance
	if preferredAssetId then
		local candidate = ContentRegistry.GetAsset(preferredAssetId)
		if typeof(candidate) == "Instance" then
			fruitInstance = candidate
		end
	end

	if not fruitInstance then
		local fallbackCandidate = ContentRegistry.GetAsset(FALLBACK_FRUIT_ASSET_ID)
		if typeof(fallbackCandidate) == "Instance" then
			fruitInstance = fallbackCandidate
		end
	end

	local size = getFruitSize(stats)
	local root

	if not fruitInstance then
		fruitInstance = createFruitPrimitive(fruitName, size, laneFrame)
		fruitInstance.Parent = container
		root = fruitInstance
	else
		fruitInstance.Name = fruitName
		fruitInstance.Parent = container
		root = configureFruitInstance(fruitInstance, size, laneFrame)
		if not root then
			if fruitInstance:IsA("BasePart") then
				root = fruitInstance
			elseif fruitInstance:IsA("Model") then
				root = fruitInstance.PrimaryPart or fruitInstance:FindFirstChildWhichIsA("BasePart")
			end
		end
	end

	applyFruitAttributes(fruitInstance, stats, nil, stats and stats.Id)
	applyOwnershipAttributes(fruitInstance, arenaId, laneIdentifier, laneIndex)
	tagInstance(fruitInstance, arenaId, laneIdentifier, laneIndex)

	if root and root ~= fruitInstance then
		applyFruitAttributes(root, stats, nil, stats and stats.Id)
		applyOwnershipAttributes(root, arenaId, laneIdentifier, laneIndex)
	end

	configureProjectile(fruitInstance, stats, pathProfile)

	if root and root ~= fruitInstance then
		configureProjectile(root, stats, pathProfile)
	end

	return fruitInstance
end

local function spawnGrapeBundle(arenaId, laneIdentifier, laneIndex, stats, container, laneFrame, pathProfile)
	local minCount = stats and stats.BundleCount or 3
	local maxCount = stats and stats.BundleCountMax or minCount
	if maxCount < minCount then
		maxCount = minCount
	end

	local grapeCount = random:NextInteger(minCount, maxCount)
	local coinsDistribution = distributeValue(stats and stats.Coins or 0, grapeCount)
	local pointsDistribution = distributeValue(stats and stats.Points or 0, grapeCount)

	local bundleModel = Instance.new("Model")
	bundleModel.Name = stats and stats.Id or "GrapeBundle"
	bundleModel.Parent = container

	setAttributeIfPresent(bundleModel, "ArenaId", pathProfile and pathProfile.ArenaId)
	setAttributeIfPresent(bundleModel, "LaneId", pathProfile and pathProfile.LaneId)
	setAttributeIfPresent(bundleModel, "FruitId", stats and stats.Id)
	local grapeSize = getFruitSize(stats)
	local firstGrape

	for index = 1, grapeCount do
		local offset = Vector3.new(
			random:NextNumber(-0.5, 0.5),
			random:NextNumber(-0.5, 0.5),
			random:NextNumber(-0.5, 0.5)
		)

		local grapeCFrame = laneFrame * CFrame.new(offset)
		local grape = createFruitPrimitive(string.format("%s_%d", stats and stats.Id or "Grape", index), grapeSize, grapeCFrame)
		grape.Parent = bundleModel

		applyFruitAttributes(grape, stats, {
			Coins = coinsDistribution[index],
			Points = pointsDistribution[index],
		}, stats and stats.Id)
		applyOwnershipAttributes(grape, arenaId, laneIdentifier, laneIndex)
		setAttribute(grape, "BundleIndex", index)
		tagInstance(grape, arenaId, laneIdentifier, laneIndex)

		configureProjectile(grape, stats, pathProfile)

		if not firstGrape then
			firstGrape = grape
		end
	end

	if firstGrape then
		bundleModel.PrimaryPart = firstGrape
	end

	applyFruitAttributes(bundleModel, stats, nil, stats and stats.Id)
	applyOwnershipAttributes(bundleModel, arenaId, laneIdentifier, laneIndex)
	tagInstance(bundleModel, arenaId, laneIdentifier, laneIndex)

	configureProjectile(bundleModel, stats, pathProfile)

	return bundleModel
end

local function spawnFruitInternal(arenaId, laneIdentifier, fruitId)
	if arenaId == nil or laneIdentifier == nil then
		return nil
	end

	local stats = nil
	local okStats, resultStats = pcall(function()
		return FruitConfig.Get(fruitId)
	end)
	if okStats then
		stats = resultStats
	end

	if stats == nil then
		warn(string.format("[FruitSpawnerServer] Unknown fruit id '%s'", tostring(fruitId)))
	end

	local lane = ArenaAdapter.ResolveLane(arenaId, laneIdentifier)
	if not lane then
		warn(string.format("[FruitSpawnerServer] Unable to resolve lane '%s' for arena '%s'", tostring(laneIdentifier), tostring(arenaId)))
		return nil
	end

	local laneIndex
	if typeof(laneIdentifier) == "number" then
		laneIndex = laneIdentifier
	else
		laneIndex = ArenaAdapter.GetLaneIndex(arenaId, lane)
	end

	local container = ensureLaneContainer(lane)
	local laneFrame = getLaneCFrame(lane)
	local pathProfile = buildPathProfile(arenaId, laneIdentifier, laneIndex, stats, laneFrame)

	if stats and stats.Id == "GrapeBundle" then
		return spawnGrapeBundle(arenaId, laneIdentifier, laneIndex, stats, container, laneFrame, pathProfile)
	end

	return spawnSingleFruit(arenaId, laneIdentifier, laneIndex, stats, container, laneFrame, pathProfile, fruitId)
end

local function processQueue(arenaId, state)
	if not state.running or state.processing then
		return nil
	end

	state.processing = true
	local lastSpawn

	while state.running and #state.queue > 0 do
		local request = table.remove(state.queue, 1)
		local ok, result = pcall(spawnFruitInternal, arenaId, request.lane, request.fruitId)
		if not ok then
			warn(string.format("[FruitSpawnerServer] Spawn failed for arena '%s': %s", tostring(arenaId), tostring(result)))
		else
			lastSpawn = result or lastSpawn
		end
	end

	state.processing = false

	return lastSpawn
end

local function resolveFruitId(payload)
	if typeof(payload) == "table" then
		local container = payload :: any
		local fruitValue = container.FruitId or container.fruitId or container.Fruit or container.fruit
		if typeof(fruitValue) == "string" and fruitValue ~= "" then
			return fruitValue
		end
		return nil
	end

	if typeof(payload) == "string" and payload ~= "" then
		return payload
	end

	return nil
end

local function resolveDelay(payload)
	if typeof(payload) ~= "table" then
		return 0
	end

	local cast = payload :: any
	local value = cast.Delay or cast.delay
	if typeof(value) ~= "number" then
		return 0
	end

	if value < 0 then
		value = 0
	end

	return value
end

local function safeSpawn(arenaId, laneIdentifier, fruitId)
	local ok, result = pcall(spawnFruitInternal, arenaId, laneIdentifier, fruitId)
	if ok then
		return result
	end

	warn(string.format("[FruitSpawnerServer] Failed to spawn fruit: %s", tostring(result)))
	return nil
end

function FruitSpawnerServer.Queue(arenaId, laneIdentifier, payload)
	assert(arenaId ~= nil, "arenaId is required")
	assert(laneIdentifier ~= nil, "laneIdentifier is required")

	local fruitId = resolveFruitId(payload)
	if not fruitId then
		warn(string.format("[FruitSpawnerServer] Queue requires a fruit id for arena '%s' lane '%s'", tostring(arenaId), tostring(laneIdentifier)))
		return nil
	end

	local delay = resolveDelay(payload)
	if delay > 0 then
		task.delay(delay, function()
			safeSpawn(arenaId, laneIdentifier, fruitId)
		end)
		return true
	end

	local state = ensureArenaQueue(arenaId)
	table.insert(state.queue, {
		lane = laneIdentifier,
		fruitId = fruitId,
	})

	if state.running then
		return processQueue(arenaId, state)
	end

	return nil
end

function FruitSpawnerServer.Start(arenaId)
	assert(arenaId ~= nil, "arenaId is required")

	local state = ensureArenaQueue(arenaId)
	if state.running then
		return true
	end

	state.running = true
	processQueue(arenaId, state)

	return true
end

function FruitSpawnerServer.Stop(arenaId)
	assert(arenaId ~= nil, "arenaId is required")

	local state = arenaQueues[arenaId]
	if not state then
		return
	end

	state.running = false
	state.queue = {}
	state.processing = false

	discardArenaQueue(arenaId)
end

function FruitSpawnerServer.SpawnFruit(arenaId, laneIdentifier, payload)
	local fruitId = resolveFruitId(payload)
	if not fruitId then
		warn(string.format("[FruitSpawnerServer] SpawnFruit requires a fruit id for arena '%s' lane '%s'", tostring(arenaId), tostring(laneIdentifier)))
		return nil
	end

	local delay = resolveDelay(payload)
	if delay > 0 then
		task.delay(delay, function()
			safeSpawn(arenaId, laneIdentifier, fruitId)
		end)
		return true
	end

	return safeSpawn(arenaId, laneIdentifier, fruitId)
end

return FruitSpawnerServer
