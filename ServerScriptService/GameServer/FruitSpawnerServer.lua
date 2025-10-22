local FruitSpawnerServer = {}

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("FruitConfig"))
local ProjectileServer = require(script.Parent:WaitForChild("ProjectileServer"))
local ArenaAdapter = require(script.Parent:WaitForChild("Libraries"):WaitForChild("ArenaAdapter"))

local random = Random.new()

local LANE_FRUIT_CONTAINER = "FruitProjectiles"
local DEFAULT_FRUIT_SIZE = Vector3.new(1, 1, 1)
local SIZE_BY_TAG = {
    XS = Vector3.new(0.6, 0.6, 0.6),
    S = Vector3.new(0.9, 0.9, 0.9),
    M = Vector3.new(1.2, 1.2, 1.2),
    L = Vector3.new(1.6, 1.6, 1.6),
    XL = Vector3.new(2, 2, 2),
}

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

local function buildMotionParams(arenaId, laneIdentifier, laneIndex, stats, laneFrame)
    local profile
    if stats and typeof(stats.Path) == "string" then
        profile = stats.Path
    else
        profile = "straight"
    end

    local params = {
        ArenaId = arenaId,
        Lane = laneIdentifier,
        LaneIndex = laneIndex,
        FruitId = stats and stats.Id or nil,
        Profile = profile,
        Speed = stats and stats.Speed or nil,
    }

    params.Direction = laneFrame.LookVector
    params.Up = laneFrame.UpVector

    return params
end

local function createFruitPart(name, size, originCFrame)
    local part = Instance.new("Part")
    part.Name = name or "Fruit"
    part.Shape = Enum.PartType.Ball
    part.Size = size or DEFAULT_FRUIT_SIZE
    part.CFrame = originCFrame
    part.Material = Enum.Material.SmoothPlastic
    part.Color = Color3.fromRGB(255, 255, 255)
    applyPhysicsDefaults(part)
    return part
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

local function spawnSingleFruit(arenaId, laneIdentifier, laneIndex, stats, container, laneFrame, motionParams)
    local size = getFruitSize(stats)
    local fruitPart = createFruitPart(stats and stats.Id or "Fruit", size, laneFrame)
    fruitPart.Parent = container

    applyFruitAttributes(fruitPart, stats, nil, stats and stats.Id)
    applyOwnershipAttributes(fruitPart, arenaId, laneIdentifier, laneIndex)
    tagInstance(fruitPart, arenaId, laneIdentifier, laneIndex)

    ProjectileServer.Track(fruitPart, motionParams)

    return fruitPart
end

local function spawnGrapeBundle(arenaId, laneIdentifier, laneIndex, stats, container, laneFrame, motionParams)
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

    local grapeSize = getFruitSize(stats)
    local firstGrape

    for index = 1, grapeCount do
        local offset = Vector3.new(
            random:NextNumber(-0.5, 0.5),
            random:NextNumber(-0.5, 0.5),
            random:NextNumber(-0.5, 0.5)
        )

        local grapeCFrame = laneFrame * CFrame.new(offset)
        local grape = createFruitPart(string.format("%s_%d", stats and stats.Id or "Grape", index), grapeSize, grapeCFrame)
        grape.Parent = bundleModel

        applyFruitAttributes(grape, stats, {
            Coins = coinsDistribution[index],
            Points = pointsDistribution[index],
        }, stats and stats.Id)
        applyOwnershipAttributes(grape, arenaId, laneIdentifier, laneIndex)
        setAttribute(grape, "BundleIndex", index)
        tagInstance(grape, arenaId, laneIdentifier, laneIndex)

        ProjectileServer.Track(grape, motionParams)

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

    return bundleModel
end

local function spawnFruitNow(arenaId, laneIdentifier, fruitId)
    local stats = FruitConfig.Get(fruitId)
    if not stats then
        warn(string.format("[FruitSpawnerServer] Unknown fruit id '%s'", tostring(fruitId)))
local function spawnFruitInternal(arenaId, laneId, fruitId)
    local arenaState = ArenaServer.GetArenaState(arenaId)
    if not arenaState then
        warn(string.format("[FruitSpawnerServer] Unknown arena '%s'", tostring(arenaId)))
        return nil
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
    local motionParams = buildMotionParams(arenaId, laneIdentifier, laneIndex, stats, laneFrame)

    if stats.Id == "GrapeBundle" then
        return spawnGrapeBundle(arenaId, laneIdentifier, laneIndex, stats, container, laneFrame, motionParams)
    end

    return spawnSingleFruit(arenaId, laneIdentifier, laneIndex, stats, container, laneFrame, motionParams)
end

local function processQueue(arenaId, state)
    if not state.running or state.processing then
        return nil
    end

    state.processing = true
    local lastSpawn

    while state.running and #state.queue > 0 do
        local request = table.remove(state.queue, 1)
        local ok, result = pcall(spawnFruitNow, arenaId, request.lane, request.fruitId)
        if not ok then
            warn(string.format("[FruitSpawnerServer] Spawn failed for arena '%s': %s", tostring(arenaId), tostring(result)))
        else
            lastSpawn = result or lastSpawn
        end
    end

    state.processing = false

    return lastSpawn
end

function FruitSpawnerServer.Queue(arenaId, laneIdentifier, fruitId)
    assert(arenaId ~= nil, "arenaId is required")
    assert(laneIdentifier ~= nil, "laneIdentifier is required")
    assert(fruitId ~= nil, "fruitId is required")

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

function FruitSpawnerServer.SpawnFruit(arenaId, laneIdentifier, fruitId)
    FruitSpawnerServer.Start(arenaId)
    return FruitSpawnerServer.Queue(arenaId, laneIdentifier, fruitId)
end

local function safeSpawn(arenaId, laneId, fruitId)
    local ok, result = pcall(spawnFruitInternal, arenaId, laneId, fruitId)
    if ok then
        return result
    end

    warn(string.format("[FruitSpawnerServer] Failed to spawn fruit: %s", result))
    return nil
end

function FruitSpawnerServer.SpawnFruit(arenaId, laneId, fruitId)
    return safeSpawn(arenaId, laneId, fruitId)
end

local function resolveFruitId(payload)
    if typeof(payload) ~= "table" then
        return payload
    end

    return payload.FruitId or payload.fruitId or payload.Fruit or payload.fruit
end

local function resolveDelay(payload)
    if typeof(payload) ~= "table" then
        return 0
    end

    return payload.Delay or payload.delay or 0
end

function FruitSpawnerServer.Queue(arenaId, laneId, payload)
    local fruitId = resolveFruitId(payload)
    if not fruitId then
        warn(string.format("[FruitSpawnerServer] Queue requires a fruit id for arena '%s' lane '%s'", tostring(arenaId), tostring(laneId)))
        return nil
    end

    local delay = resolveDelay(payload)
    if delay and delay > 0 then
        task.delay(delay, function()
            safeSpawn(arenaId, laneId, fruitId)
        end)
        return true
    end

    safeSpawn(arenaId, laneId, fruitId)
    return true
end

return FruitSpawnerServer
