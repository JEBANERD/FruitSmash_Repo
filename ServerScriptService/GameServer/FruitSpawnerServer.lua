local FruitSpawnerServer = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("FruitConfig"))
local ArenaServer = require(script.Parent:WaitForChild("ArenaServer"))

local ProjectileServer
do
    local combatFolder = ServerScriptService:FindFirstChild("Combat")
    local projectileServerModule = combatFolder and combatFolder:FindFirstChild("ProjectileServer")
    if projectileServerModule then
        local ok, result = pcall(require, projectileServerModule)
        if ok then
            ProjectileServer = result
        else
            warn(string.format("[FruitSpawnerServer] Failed to require ProjectileServer: %s", result))
        end
    else
        warn("[FruitSpawnerServer] ProjectileServer module is missing")
    end
end

local ProjectileMotionServer
local projectileModule = script.Parent:FindFirstChild("ProjectileMotionServer")
if projectileModule then
    local ok, result = pcall(require, projectileModule)
    if ok then
        ProjectileMotionServer = result
    else
        warn(string.format("[FruitSpawnerServer] Failed to require ProjectileMotionServer: %s", result))
    end
else
    warn("[FruitSpawnerServer] ProjectileMotionServer module is missing")
end

local random = Random.new()

local LANE_FRUIT_CONTAINER = "FruitProjectiles"

local function bindProjectile(instance, pathProfile)
    if not ProjectileMotionServer or type(ProjectileMotionServer.Bind) ~= "function" then
        return
    end

    local ok, err = pcall(ProjectileMotionServer.Bind, instance, pathProfile)
    if not ok then
        warn(string.format("[FruitSpawnerServer] Failed to bind projectile for %s: %s", instance:GetFullName(), err))
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

local function resolveLane(arenaState, laneId)
    local lanes = arenaState and arenaState.lanes
    if not lanes then
        return nil
    end

    if type(laneId) == "number" then
        return lanes[laneId]
    end

    for _, lane in ipairs(lanes) do
        if lane == laneId then
            return lane
        end

        local laneIdentifier = lane:GetAttribute("LaneId")
        if laneIdentifier == laneId then
            return lane
        end

        if typeof(laneId) == "string" and lane.Name == laneId then
            return lane
        end
    end

    return nil
end

local function ensureLaneContainer(lane)
    local container = lane:FindFirstChild(LANE_FRUIT_CONTAINER)

    if not container then
        container = Instance.new("Folder")
        container.Name = LANE_FRUIT_CONTAINER
        container.Parent = lane
    end

    return container
end

local function getLaneOrigin(lane)
    if lane:IsA("BasePart") then
        return lane.CFrame
    end

    if lane:IsA("Model") then
        local primaryPart = lane.PrimaryPart or lane:FindFirstChildWhichIsA("BasePart")
        if primaryPart then
            return primaryPart.CFrame
        end
    end

    return CFrame.new()
end

local function applyFruitAttributes(instance, stats, overrides)
    overrides = overrides or {}

    local function setAttribute(name, value)
        if value ~= nil then
            instance:SetAttribute(name, value)
        end
    end

    setAttribute("Speed", overrides.Speed or stats.Speed)
    setAttribute("Damage", overrides.Damage or stats.Damage)
    setAttribute("Wear", overrides.Wear or stats.Wear)
    setAttribute("Coins", overrides.Coins or stats.Coins)
    setAttribute("Points", overrides.Points or stats.Points)
    setAttribute("Path", overrides.Path or stats.Path)
    setAttribute("HPClass", overrides.HPClass or stats.HPClass)
end

local function createFruitPart(stats, originCFrame)
    local part = Instance.new("Part")
    part.Name = stats.Id or "Fruit"
    part.Size = Vector3.new(1, 1, 1)
    part.Shape = Enum.PartType.Ball
    part.Anchored = false
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CFrame = originCFrame

    applyFruitAttributes(part, stats)

    return part
end

local function buildPathProfile(arenaId, laneId, stats)
    return {
        ArenaId = arenaId,
        LaneId = laneId,
        Path = stats.Path,
        FruitId = stats.Id,
    }
end

local function spawnSingleFruit(container, stats, originCFrame, pathProfile)
    local fruit = createFruitPart(stats, originCFrame)
    fruit.Parent = container

    configureProjectile(fruit, stats, pathProfile)

    return fruit
end

local function distributeValue(total, count)
    local base = math.floor(total / count)
    local remainder = total % count
    local values = table.create(count, base)

    for index = 1, remainder do
        values[index] += 1
    end

    return values
end

local function spawnGrapeBundle(container, stats, originCFrame, pathProfile)
    local minCount = stats.BundleCount or 3
    local maxCount = stats.BundleCountMax or minCount
    if maxCount < minCount then
        maxCount = minCount
    end

    local grapeCount = random:NextInteger(minCount, maxCount)
    local coinsDistribution = distributeValue(stats.Coins or 0, grapeCount)
    local pointsDistribution = distributeValue(stats.Points or 0, grapeCount)

    local bundleModel = Instance.new("Model")
    bundleModel.Name = stats.Id or "GrapeBundle"
    bundleModel.Parent = container

    setAttributeIfPresent(bundleModel, "ArenaId", pathProfile and pathProfile.ArenaId)
    setAttributeIfPresent(bundleModel, "LaneId", pathProfile and pathProfile.LaneId)
    setAttributeIfPresent(bundleModel, "FruitId", stats and stats.Id)

    for index = 1, grapeCount do
        local offsets = Vector3.new(
            random:NextNumber(-0.5, 0.5),
            random:NextNumber(-0.5, 0.5),
            random:NextNumber(-0.5, 0.5)
        )

        local grapeCFrame = originCFrame * CFrame.new(offsets)
        local grape = createFruitPart(stats, grapeCFrame)
        grape.Name = string.format("%s_%d", stats.Id or "Grape", index)

        applyFruitAttributes(grape, stats, {
            Coins = coinsDistribution[index],
            Points = pointsDistribution[index],
        })

        grape.Parent = bundleModel
        bundleModel.PrimaryPart = bundleModel.PrimaryPart or grape

        configureProjectile(grape, stats, pathProfile)
    end

    return bundleModel
end

function FruitSpawnerServer.SpawnFruit(arenaId, laneId, fruitId)
    local arenaState = ArenaServer.GetArenaState(arenaId)
    if not arenaState then
        warn(string.format("[FruitSpawnerServer] Unknown arena '%s'", tostring(arenaId)))
        return nil
    end

    local lane = resolveLane(arenaState, laneId)
    if not lane then
        warn(string.format("[FruitSpawnerServer] Lane '%s' missing for arena '%s'", tostring(laneId), tostring(arenaId)))
        return nil
    end

    local stats = FruitConfig.Get(fruitId)
    if not stats then
        warn(string.format("[FruitSpawnerServer] Unknown fruit id '%s'", tostring(fruitId)))
        return nil
    end

    local container = ensureLaneContainer(lane)
    local origin = getLaneOrigin(lane)
    local pathProfile = buildPathProfile(arenaId, laneId, stats)

    if stats.Id == "GrapeBundle" then
        return spawnGrapeBundle(container, stats, origin, pathProfile)
    end

    return spawnSingleFruit(container, stats, origin, pathProfile)
end

return FruitSpawnerServer
