local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local GameConfig = typeof(GameConfigModule.Get) == "function" and GameConfigModule.Get() or GameConfigModule
local ObstacleConfig = (GameConfig.Obstacles and GameConfig.Obstacles.MiniTurret) or {}

local MIN_INTERVAL = ObstacleConfig.FireIntervalMin or 2.5
local MAX_INTERVAL = ObstacleConfig.FireIntervalMax or 3.5
local DAMAGE = ObstacleConfig.Damage or 25
local PROJECTILE_SPEED = ObstacleConfig.ProjectileSpeed or 70
local DEFAULT_SEARCH_RADIUS = ObstacleConfig.SearchRadius or 200
local TRACER_THICKNESS = 0.25
local MIN_TRACER_TIME = 0.08
local MAX_TRACER_TIME = 0.35
local ARENA_FOLDER_NAME = "Arenas"

if MIN_INTERVAL > MAX_INTERVAL then
    MIN_INTERVAL, MAX_INTERVAL = MAX_INTERVAL, MIN_INTERVAL
end

local MiniTurretServer = {}
local activeArenas = {}

local function getArenaModel(arenaId)
    if not arenaId then
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

local function isMiniTurretInstance(instance)
    if not instance then
        return false
    end

    if instance:GetAttribute("ObstacleType") == "MiniTurret" then
        return true
    end

    local name = string.lower(instance.Name)
    if string.find(name, "miniturret") or string.find(name, "mini_turret") or string.find(name, "turret") then
        return true
    end

    return false
end

local function gatherCandidates(source)
    local results = {}

    if not source then
        return results
    end

    if typeof(source) == "Instance" then
        if isMiniTurretInstance(source) then
            table.insert(results, source)
        end

        for _, descendant in ipairs(source:GetDescendants()) do
            if isMiniTurretInstance(descendant) then
                table.insert(results, descendant)
            end
        end
    elseif typeof(source) == "table" then
        for _, entry in ipairs(source) do
            if typeof(entry) == "Instance" then
                if isMiniTurretInstance(entry) then
                    table.insert(results, entry)
                else
                    for _, descendant in ipairs(entry:GetDescendants()) do
                        if isMiniTurretInstance(descendant) then
                            table.insert(results, descendant)
                        end
                    end
                end
            end
        end
    end

    return results
end

local function getTurretOriginCFrame(components)
    if not components then
        return nil
    end

    if components.attachment and components.attachment:IsDescendantOf(game) then
        local attachment = components.attachment
        local cf = attachment.WorldCFrame
        return cf
    end

    if components.originPart and components.originPart:IsDescendantOf(game) then
        return components.originPart.CFrame
    end

    return nil
end

local function emitTracer(originPosition, targetPosition)
    local delta = targetPosition - originPosition
    local distance = delta.Magnitude
    if distance <= 0 then
        return
    end

    local tracer = Instance.new("Part")
    tracer.Anchored = true
    tracer.CanCollide = false
    tracer.CanQuery = false
    tracer.CanTouch = false
    tracer.Material = Enum.Material.Neon
    tracer.Color = Color3.fromRGB(255, 170, 0)
    tracer.Size = Vector3.new(TRACER_THICKNESS, TRACER_THICKNESS, distance)
    tracer.CFrame = CFrame.new(originPosition + delta * 0.5, targetPosition)
    tracer.Parent = Workspace

    local lifetime = math.clamp(distance / math.max(PROJECTILE_SPEED, 1), MIN_TRACER_TIME, MAX_TRACER_TIME)
    Debris:AddItem(tracer, lifetime)
end

local function characterBelongsToArena(state, character, position)
    if not character then
        return false
    end

    if not state then
        return true
    end

    local arenaModel = state.arenaModel
    if not arenaModel then
        return true
    end

    if character:IsDescendantOf(arenaModel) then
        return true
    end

    local player = Players:GetPlayerFromCharacter(character)
    if player and state.partyId and player:GetAttribute("PartyId") == state.partyId then
        return true
    end

    if not position then
        local root = character:FindFirstChild("HumanoidRootPart")
        position = root and root.Position or nil
    end

    if position then
        local okPivot, pivot = pcall(arenaModel.GetPivot, arenaModel)
        local okSize, size = pcall(arenaModel.GetExtentsSize, arenaModel)
        if okPivot and okSize then
            local half = size * 0.5
            local relative = pivot:PointToObjectSpace(position)
            local allowanceY = state.verticalAllowance or 25
            if math.abs(relative.X) <= half.X and math.abs(relative.Z) <= half.Z and math.abs(relative.Y) <= half.Y + allowanceY then
                return true
            end
        end
    end

    return false
end

local function findNearestTarget(state, originPosition)
    local searchRadius = state.searchRadius or DEFAULT_SEARCH_RADIUS
    local nearestHumanoid
    local nearestPosition
    local bestDistance = searchRadius

    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        if character then
            local humanoid = character:FindFirstChildOfClass("Humanoid")
            local root = character:FindFirstChild("HumanoidRootPart")
            if humanoid and root and humanoid.Health > 0 then
                local distance = (root.Position - originPosition).Magnitude
                if distance <= bestDistance then
                    if characterBelongsToArena(state, character, root.Position) then
                        bestDistance = distance
                        nearestHumanoid = humanoid
                        nearestPosition = root.Position
                    end
                end
            end
        end
    end

    return nearestHumanoid, nearestPosition, bestDistance
end

local function scheduleDamage(humanoid, delayTime)
    if not humanoid then
        return
    end

    if delayTime <= 0 then
        if humanoid.Parent and humanoid.Health > 0 then
            humanoid:TakeDamage(DAMAGE)
        end
        return
    end

    task.delay(delayTime, function()
        if humanoid.Parent and humanoid.Health > 0 then
            humanoid:TakeDamage(DAMAGE)
        end
    end)
end

local function fireTurret(state, turretData)
    local cf = getTurretOriginCFrame(turretData.components)
    if not cf then
        return
    end

    local originPosition = cf.Position
    local humanoid, targetPosition, distance = findNearestTarget(state, originPosition)
    if not humanoid or not targetPosition then
        return
    end

    emitTracer(originPosition, targetPosition)

    local travelTime = 0
    if PROJECTILE_SPEED and PROJECTILE_SPEED > 0 then
        travelTime = distance / PROJECTILE_SPEED
    end

    scheduleDamage(humanoid, travelTime)
end

local function stopTurret(state, turretData)
    if not turretData then
        return
    end

    turretData.running = false

    if turretData.loopThread then
        -- allow the thread to exit naturally after the next wait
    end

    if turretData.ancestryConn then
        turretData.ancestryConn:Disconnect()
        turretData.ancestryConn = nil
    end
end

local function runTurretLoop(state, turretData)
    turretData.loopThread = task.spawn(function()
        local rng = Random.new()
        while state.running and turretData.running do
            local interval = rng:NextNumber(MIN_INTERVAL, MAX_INTERVAL)
            task.wait(interval)

            if not state.running or not turretData.running then
                break
            end

            local handle = turretData.components.handle
            if not handle or not handle:IsDescendantOf(game) then
                break
            end

            fireTurret(state, turretData)
        end

        stopTurret(state, turretData)
        state.turrets[turretData.components.handle] = nil
    end)
end

local function trackTurret(state, instance)
    if not instance or state.turrets[instance] then
        return
    end

    local components = resolveTurretComponents(instance)
    if not components then
        return
    end

    local turretData = {
        components = components,
        running = true,
    }

    state.turrets[instance] = turretData

    turretData.ancestryConn = instance.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            stopTurret(state, turretData)
        end
    end)

    runTurretLoop(state, turretData)
end

local function processInitialTurrets(state, options)
    local sources = {}
    if options then
        if options.Turrets then
            table.insert(sources, options.Turrets)
        end
        if options.TurretFolder then
            table.insert(sources, options.TurretFolder)
        end
    end

    local arenaModel = state.arenaModel
    if arenaModel then
        local obstacleFolder
        if options and options.ObstacleFolder then
            obstacleFolder = options.ObstacleFolder
        else
            obstacleFolder = arenaModel:FindFirstChild("Obstacles")
        end

        if obstacleFolder then
            table.insert(sources, obstacleFolder)
        else
            table.insert(sources, arenaModel)
        end
    end

    for _, source in ipairs(sources) do
        for _, candidate in ipairs(gatherCandidates(source)) do
            trackTurret(state, candidate)
        end
    end
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
        local turretData = state.turrets[descendant]
        if turretData then
            stopTurret(state, turretData)
            state.turrets[descendant] = nil
        end
    end)

    table.insert(state.connections, addedConn)
    table.insert(state.connections, removingConn)
end

local function createState(arenaId, options)
    local arenaModel = options and options.ArenaModel or getArenaModel(arenaId)

    local state = {
        arenaId = arenaId,
        arenaModel = arenaModel,
        partyId = options and options.PartyId or (arenaModel and arenaModel:GetAttribute("PartyId")) or nil,
        searchRadius = options and options.SearchRadius or DEFAULT_SEARCH_RADIUS,
        verticalAllowance = options and options.VerticalAllowance or 25,
        turrets = {},
        connections = {},
        running = true,
    }

    return state
end

local function cleanupState(state)
    if not state then
        return
    end

    state.running = false

    for instance, turretData in pairs(state.turrets) do
        stopTurret(state, turretData)
    end

    state.turrets = {}

    for _, conn in ipairs(state.connections) do
        conn:Disconnect()
    end
    state.connections = {}
end

function MiniTurretServer.Enable(arenaId, options)
    if not arenaId then
        error("MiniTurretServer.Enable requires an arenaId")
    end

    local existing = activeArenas[arenaId]
    if existing then
        MiniTurretServer.Disable(arenaId)
    end

    local state = createState(arenaId, options)
    activeArenas[arenaId] = state

    processInitialTurrets(state, options)

    if options and options.TurretFolder then
        connectContainer(state, options.TurretFolder)
    end

    if state.arenaModel then
        local container = options and options.ObstacleFolder or state.arenaModel:FindFirstChild("Obstacles") or state.arenaModel
        connectContainer(state, container)
    end

    return state
end

function MiniTurretServer.Disable(arenaId)
    local state = activeArenas[arenaId]
    if not state then
        return
    end

    cleanupState(state)
    activeArenas[arenaId] = nil
end

function MiniTurretServer.SetEnabled(arenaId, enabled, options)
    if enabled then
        return MiniTurretServer.Enable(arenaId, options)
    else
        MiniTurretServer.Disable(arenaId)
    end
end

function MiniTurretServer.IsActive(arenaId)
    return activeArenas[arenaId] ~= nil
end

function MiniTurretServer.GetState(arenaId)
    return activeArenas[arenaId]
end

return MiniTurretServer

