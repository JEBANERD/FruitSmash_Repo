local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ArenaAdapter = require(ServerScriptService:WaitForChild("Combat"):WaitForChild("ArenaAdapter"))
local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local HUDServer = require(ServerScriptService:WaitForChild("GameServer"):WaitForChild("HUDServer"))

local GameConfig = typeof(GameConfigModule.Get) == "function" and GameConfigModule.Get() or GameConfigModule
local TargetConfig = GameConfig.Targets or {}

local START_HP = TargetConfig.StartHP or 200
local BAND_SCALE = TargetConfig.TenLevelBandScalePct or 0
local DEFAULT_SPEED = 12
local DEFAULT_DAMAGE = 5
local DEFAULT_HIT_RADIUS = 2.5
local HIT_RADIUS_PADDING = 0.75
local TIME_BUFFER = 0.5
local MIN_TIMEOUT = 2.5

local ProjectileServer = {}

local active = {}
local perArena = {}
local laneHealth = {}
local heartbeatConnection = nil

local function currentTime()
    return os.clock()
end

local function resolveRoot(instance)
    if not instance then
        return nil
    end

    if instance:IsA("BasePart") then
        return instance
    end

    if instance:IsA("Model") then
        local primary = instance.PrimaryPart
        if primary then
            return primary
        end
        return instance:FindFirstChildWhichIsA("BasePart")
    end

    return nil
end

local function getWorldPosition(instance)
    if not instance then
        return nil
    end

    if instance:IsA("Attachment") then
        return instance.WorldPosition
    end

    if instance:IsA("BasePart") then
        return instance.Position
    end

    if instance:IsA("Model") then
        local cf = instance:GetPivot()
        return cf.Position
    end

    local basePart = instance:FindFirstChildWhichIsA("BasePart")
    if basePart then
        return basePart.Position
    end

    return nil
end

local function resolveNumericAttribute(instance, name)
    if not instance then
        return nil
    end

    local value = instance:GetAttribute(name)
    if typeof(value) == "number" then
        return value
    end

    return nil
end

local function resolveSpeed(model, params)
    local speed = params and params.Speed
    if typeof(speed) ~= "number" then
        speed = resolveNumericAttribute(model, "Speed")
    end

    if typeof(speed) ~= "number" and model:IsA("Model") then
        local root = resolveRoot(model)
        if root then
            speed = resolveNumericAttribute(root, "Speed")
        end
    end

    if typeof(speed) ~= "number" then
        speed = DEFAULT_SPEED
    end

    return math.max(speed, 1e-3)
end

local function resolveDamage(model, params)
    local damage = params and params.Damage
    if typeof(damage) ~= "number" then
        damage = resolveNumericAttribute(model, "Damage")
    end

    if typeof(damage) ~= "number" and model:IsA("Model") then
        local root = resolveRoot(model)
        if root then
            damage = resolveNumericAttribute(root, "Damage")
        end
    end

    if typeof(damage) ~= "number" then
        damage = DEFAULT_DAMAGE
    end

    return math.max(damage, 0)
end

local function computeBandLevel(level)
    if not level then
        return 0
    end

    local numeric = tonumber(level) or 1
    if numeric <= 1 then
        return 0
    end

    return math.floor((numeric - 1) / 10)
end

local function computeMaxHP(arenaId)
    local level = ArenaAdapter.GetArenaLevel(arenaId) or 1
    local band = computeBandLevel(level)
    local scaled = START_HP * (1 + band * BAND_SCALE)
    return math.max(1, math.floor(scaled + 0.5))
end

local function ensureLaneHealth(arenaId, laneId)
    if arenaId == nil or laneId == nil then
        return nil
    end

    local arenaState = laneHealth[arenaId]
    if not arenaState then
        arenaState = {}
        laneHealth[arenaId] = arenaState
    end

    local laneState = arenaState[laneId]
    if not laneState then
        local maxHP = computeMaxHP(arenaId)
        laneState = { current = maxHP, max = maxHP }
        arenaState[laneId] = laneState
    end

    return laneState
end

local function fireTargetUpdate(arenaId, laneId, laneState)
    if not laneState or not HUDServer or typeof(HUDServer.TargetHp) ~= "function" then
        return
    end

    local percent = laneState.max > 0 and laneState.current / laneState.max or 0
    percent = math.clamp(percent, 0, 1)

    HUDServer.TargetHp(arenaId, laneId, percent, {
        currentHp = laneState.current,
        CurrentHP = laneState.current,
        maxHp = laneState.max,
        MaxHP = laneState.max,
    })
end

local function applyDamage(arenaId, laneId, damage)
    if not damage or damage <= 0 then
        return
    end

    local laneState = ensureLaneHealth(arenaId, laneId)
    if not laneState then
        return
    end

    laneState.current = math.max(laneState.current - damage, 0)
    fireTargetUpdate(arenaId, laneId, laneState)
end

local function computeHitRadius(laneInfo)
    if not laneInfo then
        return DEFAULT_HIT_RADIUS
    end

    local target = laneInfo.target
    if target and target:IsA("BasePart") then
        local size = target.Size
        local largest = math.max(size.X, size.Y, size.Z)
        return math.max(DEFAULT_HIT_RADIUS, largest * 0.5 + HIT_RADIUS_PADDING)
    end

    if target and target:IsA("Model") then
        local primary = target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart")
        if primary then
            local size = primary.Size
            local largest = math.max(size.X, size.Y, size.Z)
            return math.max(DEFAULT_HIT_RADIUS, largest * 0.5 + HIT_RADIUS_PADDING)
        end
    end

    return DEFAULT_HIT_RADIUS
end

local function addArenaMapping(state)
    if not state.arenaId then
        return
    end

    local mapping = perArena[state.arenaId]
    if not mapping then
        mapping = {}
        perArena[state.arenaId] = mapping
    end

    mapping[state.model] = true
end

local function removeArenaMapping(state)
    local arenaId = state and state.arenaId
    if not arenaId then
        return
    end

    local mapping = perArena[arenaId]
    if not mapping then
        return
    end

    mapping[state.model] = nil
    if not next(mapping) then
        perArena[arenaId] = nil
    end
end

local function cleanupState(state)
    if state and state.ancestryConnection then
        state.ancestryConnection:Disconnect()
        state.ancestryConnection = nil
    end
end

local function stopHeartbeatIfIdle()
    if heartbeatConnection and not next(active) then
        heartbeatConnection:Disconnect()
        heartbeatConnection = nil
    end
end

local function handleHit(state)
    if state.hitHandled then
        return
    end

    state.hitHandled = true
    applyDamage(state.arenaId, state.laneId, state.damage)
end

local function updateProjectile(state)
    if not state.root or not state.root.Parent then
        ProjectileServer.Despawn(state.model, "lost_root")
        return
    end

    local now = currentTime()
    state.elapsed = now - state.startTime

    if state.elapsed >= state.timeout then
        ProjectileServer.Despawn(state.model, "timeout")
        return
    end

    local laneInfo = ArenaAdapter.GetLaneInfo(state.arenaId, state.laneId)
    if not laneInfo or not laneInfo.targetPosition then
        return
    end

    local rootPosition = getWorldPosition(state.root)
    if not rootPosition then
        ProjectileServer.Despawn(state.model, "no_position")
        return
    end

    state.hitRadius = state.hitRadius or computeHitRadius(laneInfo)
    local targetPosition = laneInfo.targetPosition
    local distanceToTarget = (targetPosition - rootPosition).Magnitude

    if not state.hitHandled and (distanceToTarget <= state.hitRadius or state.elapsed >= state.timeToTarget) then
        handleHit(state)
        ProjectileServer.Despawn(state.model, "hit")
        return
    end
end

local function onHeartbeat()
    for model, state in pairs(active) do
        updateProjectile(state)
    end
end

function ProjectileServer.Despawn(model, reason)
    local state = active[model]
    if not state then
        return
    end

    if state.despawning then
        return
    end

    state.despawning = true
    active[model] = nil
    removeArenaMapping(state)
    cleanupState(state)

    local destroyInstance = state.destroyOnDespawn
    if destroyInstance == nil then
        destroyInstance = true
    end

    if destroyInstance and model and model:IsDescendantOf(game) then
        pcall(function()
            model:Destroy()
        end)
    end

    stopHeartbeatIfIdle()
end

function ProjectileServer.ClearArena(arenaId)
    if not arenaId then
        return
    end

    laneHealth[arenaId] = nil

    local mapping = perArena[arenaId]
    if mapping then
        for projectile in pairs(mapping) do
            ProjectileServer.Despawn(projectile, "arena_clear")
        end
    end
end

local function ensureHeartbeat()
    if not heartbeatConnection then
        heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)
    end
end

local function trackAncestry(state)
    if not state.model then
        return
    end

    state.ancestryConnection = state.model.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            ProjectileServer.Despawn(state.model, "ancestry")
        end
    end)
end

function ProjectileServer.Track(model, params)
    assert(model ~= nil, "model is required")

    ProjectileServer.Despawn(model, "retrack")

    local root = resolveRoot(model)
    if not root then
        warn(string.format("[ProjectileServer] Unable to resolve root for %s", model:GetFullName()))
        return nil
    end

    params = params or {}

    local arenaId = params.ArenaId or model:GetAttribute("ArenaId")
    local laneId = params.LaneId or model:GetAttribute("LaneId")

    if arenaId == nil or laneId == nil then
        warn(string.format("[ProjectileServer] Missing arena or lane id for %s", model:GetFullName()))
        return nil
    end

    local laneInfo = ArenaAdapter.GetLaneInfo(arenaId, laneId)
    if not laneInfo or not laneInfo.targetPosition then
        warn(string.format("[ProjectileServer] Lane %s missing target for arena %s", tostring(laneId), tostring(arenaId)))
        return nil
    end

    local rootPosition = getWorldPosition(root)
    local startPosition = rootPosition or (laneInfo.originCFrame and laneInfo.originCFrame.Position)
    if not startPosition then
        warn(string.format("[ProjectileServer] Unable to determine start position for %s", model:GetFullName()))
        return nil
    end

    local distance = (laneInfo.targetPosition - startPosition).Magnitude
    local speed = resolveSpeed(model, params)
    local damage = resolveDamage(model, params)

    local timeToTarget = speed > 0 and (distance / speed) or MIN_TIMEOUT
    if timeToTarget == math.huge or timeToTarget ~= timeToTarget then
        timeToTarget = MIN_TIMEOUT
    end

    local timeout = math.max(timeToTarget + TIME_BUFFER, MIN_TIMEOUT)
    if typeof(params.Timeout) == "number" and params.Timeout > 0 then
        timeout = params.Timeout
    end

    local state = {
        model = model,
        root = root,
        arenaId = arenaId,
        laneId = laneId,
        speed = speed,
        damage = damage,
        distance = distance,
        startTime = currentTime(),
        timeToTarget = timeToTarget,
        timeout = timeout,
        hitRadius = params.HitRadius,
        destroyOnDespawn = params.DestroyOnDespawn,
    }

    active[model] = state
    addArenaMapping(state)
    trackAncestry(state)
    ensureHeartbeat()

    return state
end

ArenaAdapter.ArenaRemoved:Connect(function(arenaId)
    ProjectileServer.ClearArena(arenaId)
end)

return ProjectileServer
