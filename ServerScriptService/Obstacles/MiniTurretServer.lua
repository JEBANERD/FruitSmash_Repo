local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local ProjectileServer = require(ServerScriptService:WaitForChild("GameServer"):WaitForChild("ProjectileServer"))
local ArenaAdapter = require(ServerScriptService:WaitForChild("Combat"):WaitForChild("ArenaAdapter"))
local ArenaServer = require(ServerScriptService:WaitForChild("GameServer"):WaitForChild("ArenaServer"))

local GameConfig = typeof(GameConfigModule.Get) == "function" and GameConfigModule.Get() or GameConfigModule
local ObstacleConfig = (GameConfig.Obstacles and GameConfig.Obstacles.MiniTurret) or {}
local ObstaclesConfig = GameConfig.Obstacles or {}

local MIN_INTERVAL = ObstacleConfig.FireIntervalMin or 2.5
local MAX_INTERVAL = ObstacleConfig.FireIntervalMax or 3.5
local DAMAGE = ObstacleConfig.Damage or 25
local PROJECTILE_SPEED = ObstacleConfig.ProjectileSpeed or 70
local SEARCH_RADIUS = ObstacleConfig.SearchRadius or 200
local ENABLE_LEVEL = ObstaclesConfig.EnableAtLevel or math.huge

if MIN_INTERVAL > MAX_INTERVAL then
    MIN_INTERVAL, MAX_INTERVAL = MAX_INTERVAL, MIN_INTERVAL
end

local SHOP_PHASE = "Shop"
local ARENA_FOLDER_NAME = "Arenas"
local PROJECTILE_SIZE = Vector3.new(0.35, 0.35, 0.9)
local PROJECTILE_COLOR = Color3.fromRGB(255, 170, 0)
local PROJECTILE_MATERIAL = Enum.Material.Neon
local PROJECTILE_LIFETIME_BUFFER = 0.6
local PROJECTILE_MIN_LIFETIME = 0.75
local WAIT_STEP = 0.25
local UP_VECTOR = Vector3.new(0, 1, 0)

local MiniTurretServer = {}

local activeStates = {}

local function getArenaModel(arenaId)
    if arenaId == nil then
        return nil
    end

    local arenasFolder = Workspace:FindFirstChild(ARENA_FOLDER_NAME)
    if not arenasFolder then
        return nil
    end

    for _, arena in ipairs(arenasFolder:GetChildren()) do
        if arena:GetAttribute("ArenaId") == arenaId then
            return arena
        end
    end

    return nil
end

local function resolveTurretComponents(instance)
    if not instance or not instance:IsDescendantOf(game) then
        return nil
    end

    if instance:IsA("Attachment") then
        local parent = instance.Parent
        if parent and parent:IsA("BasePart") then
            return {
                handle = instance,
                originPart = parent,
                attachment = instance,
            }
        end

        return {
            handle = instance,
            attachment = instance,
        }
    end

    if instance:IsA("BasePart") then
        return {
            handle = instance,
            originPart = instance,
        }
    end

    if instance:IsA("Model") then
        local primary = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")
        if primary then
            return {
                handle = instance,
                originPart = primary,
                model = instance,
            }
        end
    end

    return nil
end

local function getTurretKey(components)
    if not components then
        return nil
    end

    return components.attachment or components.originPart or components.model or components.handle
end

local function getTurretOriginCFrame(components)
    if not components then
        return nil
    end

    local attachment = components.attachment
    if attachment and attachment:IsDescendantOf(game) then
        return attachment.WorldCFrame
    end

    local part = components.originPart
    if part and part:IsDescendantOf(game) then
        return part.CFrame
    end

    return nil
end

local function isMiniTurretInstance(instance)
    if not instance then
        return false
    end

    if instance:GetAttribute("ObstacleType") == "MiniTurret" then
        return true
    end

    local name = string.lower(instance.Name)
    if string.find(name, "miniturret") or string.find(name, "mini_turret") then
        return true
    end

    if string.find(name, "turret") and not instance:IsA("Folder") then
        return true
    end

    return false
end

local function gatherTurretInstances(container)
    local results = {}

    if not container then
        return results
    end

    local function consider(instance)
        if isMiniTurretInstance(instance) then
            table.insert(results, instance)
        end
    end

    consider(container)
    for _, descendant in ipairs(container:GetDescendants()) do
        consider(descendant)
    end

    return results
end

local function updateArenaState(state)
    if not state then
        return false
    end

    local arenaState = ArenaServer.GetArenaState and ArenaServer.GetArenaState(state.arenaId)
    if arenaState then
        state.phase = arenaState.phase or state.phase
        state.partyId = arenaState.partyId or state.partyId
        state.arenaModel = arenaState.instance or state.arenaModel
        if typeof(arenaState.level) == "number" then
            state.level = arenaState.level
        end
    end

    if typeof(ArenaAdapter.GetArenaLevel) == "function" then
        local ok, level = pcall(ArenaAdapter.GetArenaLevel, state.arenaId)
        if ok and typeof(level) == "number" then
            state.level = level
        end
    end

    if not state.arenaModel or not state.arenaModel.Parent then
        state.arenaModel = getArenaModel(state.arenaId)
    end

    if typeof(state.level) ~= "number" then
        state.level = 1
    end

    return state.arenaModel ~= nil
end

local function isPlayerInArena(state, player)
    if not player then
        return false
    end

    local playerArena = player:GetAttribute("ArenaId")
    if playerArena ~= nil and tostring(playerArena) == tostring(state.arenaId) then
        return true
    end

    if state.partyId then
        local playerParty = player:GetAttribute("PartyId")
        if playerParty ~= nil and playerParty == state.partyId then
            return true
        end
    end

    if state.arenaModel then
        local character = player.Character
        if character and character:IsDescendantOf(state.arenaModel) then
            return true
        end
    end

    return false
end

local function selectTarget(state, originPosition)
    local bestHumanoid
    local bestPosition
    local maxDistance = state.searchRadius or SEARCH_RADIUS
    if maxDistance <= 0 then
        return nil, nil, 0
    end

    local bestDistance = maxDistance

    for _, player in ipairs(Players:GetPlayers()) do
        if isPlayerInArena(state, player) then
            local character = player.Character
            if character then
                local humanoid = character:FindFirstChildOfClass("Humanoid")
                local root = character:FindFirstChild("HumanoidRootPart")
                if humanoid and root and humanoid.Health > 0 then
                    local distance = (root.Position - originPosition).Magnitude
                    if distance <= bestDistance then
                        bestDistance = distance
                        bestHumanoid = humanoid
                        bestPosition = root.Position
                    end
                end
            end
        end
    end

    return bestHumanoid, bestPosition, bestDistance
end

local function ensureProjectileFolder(state)
    if state.projectileFolder and state.projectileFolder.Parent then
        return state.projectileFolder
    end

    local folder = Instance.new("Folder")
    folder.Name = string.format("MiniTurretProjectiles_%s", tostring(state.arenaId))
    folder.Parent = Workspace
    state.projectileFolder = folder
    return folder
end

local function findHumanoidFromPart(part)
    if not part then
        return nil
    end

    local parent = part.Parent
    if parent then
        local humanoid = parent:FindFirstChildOfClass("Humanoid")
        if humanoid then
            return humanoid
        end

        local grandparent = parent.Parent
        if grandparent then
            humanoid = grandparent:FindFirstChildOfClass("Humanoid")
            if humanoid then
                return humanoid
            end
        end
    end

    return nil
end

local function scheduleCleanup(state, projectile, lifetime)
    if lifetime <= 0 then
        lifetime = PROJECTILE_MIN_LIFETIME
    end

    task.delay(lifetime, function()
        if projectile and projectile.Parent then
            ProjectileServer.Untrack(projectile)
            projectile:Destroy()
        end
    end)
end

local function fireTurret(state, turret)
    local components = turret.components
    local originCFrame = getTurretOriginCFrame(components)
    if not originCFrame then
        return
    end

    updateArenaState(state)

    local originPosition = originCFrame.Position
    local humanoid, targetPosition, distance = selectTarget(state, originPosition)
    if not humanoid or not targetPosition or distance <= 0 then
        return
    end

    local direction = targetPosition - originPosition
    if direction.Magnitude <= 1e-3 then
        return
    end
    direction = direction.Unit

    local projectile = Instance.new("Part")
    projectile.Name = "MiniTurretProjectile"
    projectile.Size = PROJECTILE_SIZE
    projectile.Material = PROJECTILE_MATERIAL
    projectile.Color = PROJECTILE_COLOR
    projectile.Anchored = true
    projectile.CanCollide = false
    projectile.CanQuery = false
    projectile.CanTouch = true
    projectile.Massless = true
    projectile.CFrame = CFrame.new(originPosition, originPosition + direction)
    projectile:SetAttribute("ArenaId", state.arenaId)
    projectile:SetAttribute("Damage", state.damage)
    projectile.Parent = ensureProjectileFolder(state)

    local profile = {
        Profile = "straight",
        Direction = direction,
        Up = UP_VECTOR,
        Speed = state.projectileSpeed,
    }

    local motionState = ProjectileServer.Track(projectile, profile)
    if not motionState then
        projectile:Destroy()
        return
    end

    local hit = false
    local connection
    connection = projectile.Touched:Connect(function(otherPart)
        if hit or not projectile.Parent then
            return
        end

        local humanoidHit = findHumanoidFromPart(otherPart)
        if not humanoidHit or humanoidHit.Health <= 0 then
            return
        end

        local character = humanoidHit.Parent
        local player = character and Players:GetPlayerFromCharacter(character)
        if not player or not isPlayerInArena(state, player) then
            return
        end

        hit = true
        if connection then
            connection:Disconnect()
        end

        humanoidHit:TakeDamage(state.damage)
        ProjectileServer.Untrack(projectile)
        projectile:Destroy()
    end)

    local travelTime = distance / math.max(state.projectileSpeed, 1)
    local lifetime = math.max(PROJECTILE_MIN_LIFETIME, travelTime + PROJECTILE_LIFETIME_BUFFER)
    scheduleCleanup(state, projectile, lifetime)
end

local function isFiringEnabled(state)
    if not state or not state.running then
        return false
    end

    updateArenaState(state)

    if state.level and state.level < ENABLE_LEVEL then
        return false
    end

    if state.phase == SHOP_PHASE then
        return false
    end

    return true
end

local function runTurretLoop(state, turret)
    turret.loopThread = task.spawn(function()
        while state.running and turret.active do
            local interval = state.rng:NextNumber(state.intervalMin, state.intervalMax)
            local waited = 0
            while state.running and turret.active and waited < interval do
                local step = math.min(WAIT_STEP, interval - waited)
                task.wait(step)
                waited += step
            end

            if not state.running or not turret.active then
                break
            end

            while state.running and turret.active and not isFiringEnabled(state) do
                task.wait(0.5)
            end

            if not state.running or not turret.active then
                break
            end

            fireTurret(state, turret)
        end

        if turret.ancestryConn then
            turret.ancestryConn:Disconnect()
            turret.ancestryConn = nil
        end

        if state.turrets[turret.components.handle] == turret then
            state.turrets[turret.components.handle] = nil
        end

        if turret.key and state.trackedSources[turret.key] == turret then
            state.trackedSources[turret.key] = nil
        end
    end)
end

local function stopTurret(state, turret)
    if not turret or not turret.active then
        return
    end

    turret.active = false

    if turret.ancestryConn then
        turret.ancestryConn:Disconnect()
        turret.ancestryConn = nil
    end

    if state.turrets[turret.components.handle] == turret then
        state.turrets[turret.components.handle] = nil
    end

    if turret.key and state.trackedSources[turret.key] == turret then
        state.trackedSources[turret.key] = nil
    end
end

local function trackTurret(state, instance)
    if not state or not instance then
        return
    end

    if state.turrets[instance] then
        return
    end

    local components = resolveTurretComponents(instance)
    if not components then
        return
    end

    local handle = components.handle
    if state.turrets[handle] then
        return
    end

    local key = getTurretKey(components)
    if key and state.trackedSources[key] then
        return
    end

    local turret = {
        components = components,
        active = true,
        state = state,
        key = key,
    }

    state.turrets[handle] = turret
    if key then
        state.trackedSources[key] = turret
    end

    turret.ancestryConn = handle.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            stopTurret(state, turret)
        end
    end)

    runTurretLoop(state, turret)
end

local function connectContainer(state, container)
    if not container then
        return
    end

    local addedConn = container.DescendantAdded:Connect(function(descendant)
        if isMiniTurretInstance(descendant) then
            trackTurret(state, descendant)
        end
    end)

    local removingConn = container.DescendantRemoving:Connect(function(descendant)
        local turret = state.turrets[descendant]
        if turret then
            stopTurret(state, turret)
        end
    end)

    table.insert(state.connections, addedConn)
    table.insert(state.connections, removingConn)
end

local function processInitialTurrets(state)
    local arenaModel = state.arenaModel
    if not arenaModel then
        return
    end

    local container = arenaModel:FindFirstChild("Obstacles") or arenaModel
    for _, instance in ipairs(gatherTurretInstances(container)) do
        trackTurret(state, instance)
    end

    connectContainer(state, container)
end

local function cleanupProjectiles(state)
    if not state.projectileFolder then
        return
    end

    local folder = state.projectileFolder
    state.projectileFolder = nil

    for _, projectile in ipairs(folder:GetChildren()) do
        ProjectileServer.Untrack(projectile)
        projectile:Destroy()
    end

    folder:Destroy()
end

local function cleanupState(state)
    if not state then
        return
    end

    state.running = false

    for _, turret in pairs(state.turrets) do
        stopTurret(state, turret)
    end

    state.turrets = {}
    state.trackedSources = {}

    for _, connection in ipairs(state.connections) do
        if typeof(connection) == "RBXScriptConnection" then
            connection:Disconnect()
        end
    end
    state.connections = {}

    cleanupProjectiles(state)
end

function MiniTurretServer.Start(arenaId)
    assert(arenaId ~= nil, "arenaId is required")

    MiniTurretServer.Stop(arenaId)

    local state = {
        arenaId = arenaId,
        running = true,
        turrets = {},
        trackedSources = {},
        connections = {},
        rng = Random.new(os.clock()),
        intervalMin = MIN_INTERVAL,
        intervalMax = MAX_INTERVAL,
        damage = DAMAGE,
        projectileSpeed = PROJECTILE_SPEED,
        searchRadius = math.max(SEARCH_RADIUS, 0),
        level = 1,
    }

    updateArenaState(state)

    processInitialTurrets(state)

    activeStates[arenaId] = state

    return state
end

function MiniTurretServer.Stop(arenaId)
    local state = activeStates[arenaId]
    if not state then
        return
    end

    cleanupState(state)
    activeStates[arenaId] = nil
end

function MiniTurretServer.GetState(arenaId)
    return activeStates[arenaId]
end

function MiniTurretServer.IsActive(arenaId)
    return activeStates[arenaId] ~= nil
end

if typeof(ArenaAdapter.ArenaRemoved) == "RBXScriptSignal" then
    ArenaAdapter.ArenaRemoved:Connect(function(arenaId)
        MiniTurretServer.Stop(arenaId)
    end)
end

return MiniTurretServer
