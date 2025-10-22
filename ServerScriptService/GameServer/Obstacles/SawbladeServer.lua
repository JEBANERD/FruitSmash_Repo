local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local GameConfig = typeof(GameConfigModule.Get) == "function" and GameConfigModule.Get() or GameConfigModule

local ObstacleConfig = (GameConfig.Obstacles and GameConfig.Obstacles.Sawblade) or {}
local PlayerConfig = GameConfig.Player or {}

local ENABLE_LEVEL = (GameConfig.Obstacles and GameConfig.Obstacles.EnableAtLevel) or math.huge
local INTERVAL_MIN = tonumber(ObstacleConfig.PopUpIntervalMin) or 6
local INTERVAL_MAX = tonumber(ObstacleConfig.PopUpIntervalMax) or INTERVAL_MIN
local UP_TIME = tonumber(ObstacleConfig.UpTimeSeconds) or 2
local DAMAGE = tonumber(PlayerConfig.MiniTurretHitDamage) or 25

local RISE_HEIGHT = 4
local BLADE_RADIUS = 2.5
local BLADE_THICKNESS = 0.6
local HIT_COOLDOWN = 1.0
local MONITOR_STEP = 0.5
local LOOP_WAIT = 0.1
local TWEEN_TIME = 0.25

if INTERVAL_MIN > INTERVAL_MAX then
    INTERVAL_MIN, INTERVAL_MAX = INTERVAL_MAX, INTERVAL_MIN
end

local GameServerFolder = ServerScriptService:WaitForChild("GameServer")
local LibrariesFolder = GameServerFolder:WaitForChild("Libraries")
local ArenaAdapter = require(LibrariesFolder:WaitForChild("ArenaAdapter"))

local SawbladeServer = {}
local activeStates = {}
local RoundDirectorServer

local tweenInfoUp = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local tweenInfoDown = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function warnOnce(state, key, message)
    state.warnings = state.warnings or {}
    if state.warnings[key] then
        return
    end

    state.warnings[key] = true
    warn(message)
end

local function getRoundDirector()
    if RoundDirectorServer == false then
        return nil
    end

    if RoundDirectorServer then
        return RoundDirectorServer
    end

    local module = GameServerFolder:FindFirstChild("RoundDirectorServer")
    if not module then
        RoundDirectorServer = false
        return nil
    end

    local ok, result = pcall(require, module)
    if not ok then
        warn(string.format("[SawbladeServer] Failed to require RoundDirectorServer: %s", tostring(result)))
        RoundDirectorServer = false
        return nil
    end

    RoundDirectorServer = result
    return RoundDirectorServer
end

local function fetchArenaInstance(arenaId)
    local method = ArenaAdapter and ArenaAdapter.GetArenaInstance
    if typeof(method) ~= "function" then
        return nil
    end

    local ok, arena = pcall(method, arenaId)
    if not ok then
        warn(string.format("[SawbladeServer] ArenaAdapter.GetArenaInstance failed: %s", tostring(arena)))
        return nil
    end

    if typeof(arena) == "Instance" then
        return arena
    end

    return nil
end

local function fetchArenaState(arenaId)
    local method = ArenaAdapter and ArenaAdapter.GetArenaState
    if typeof(method) ~= "function" then
        return nil
    end

    local ok, state = pcall(method, arenaId)
    if not ok then
        warn(string.format("[SawbladeServer] ArenaAdapter.GetArenaState failed: %s", tostring(state)))
        return nil
    end

    if typeof(state) == "table" then
        return state
    end

    return nil
end

local function resolveContainer(state)
    local arena = state.arena
    if not arena then
        return nil
    end

    if state.container and state.container.Parent == arena then
        return state.container
    end

    local gutters = arena:FindFirstChild("Gutters")
    if gutters then
        state.container = gutters
        state.createdContainer = false
        return gutters
    end

    local obstacles = arena:FindFirstChild("Obstacles")
    if obstacles then
        local existing = obstacles:FindFirstChild("Sawblades")
        if not existing then
            existing = Instance.new("Folder")
            existing.Name = "Sawblades"
            existing.Parent = obstacles
            state.createdContainer = true
        else
            state.createdContainer = false
        end
        state.container = existing
        return existing
    end

    local folder = arena:FindFirstChild("Sawblades")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "Sawblades"
        folder.Parent = arena
        state.createdContainer = true
    else
        state.createdContainer = false
    end

    state.container = folder
    return folder
end

local function findLanePart(lane)
    if typeof(lane) ~= "Instance" then
        return nil
    end

    if lane:IsA("BasePart") then
        return lane
    end

    if lane:IsA("Model") then
        local primary = lane.PrimaryPart
        if primary and primary:IsA("BasePart") then
            return primary
        end

        local candidate = lane:FindFirstChildWhichIsA("BasePart")
        if candidate then
            return candidate
        end
    end

    for _, descendant in ipairs(lane:GetDescendants()) do
        if descendant:IsA("BasePart") then
            return descendant
        end
    end

    return nil
end

local function cancelTween(blade)
    local tween = blade.tween
    if tween and tween:IsA("Tween") then
        tween:Cancel()
    end
    blade.tween = nil
end

local function setBladeActive(state, blade, active)
    if blade.active == active then
        return
    end

    blade.active = active

    local part = blade.part
    if not part or not part.Parent then
        return
    end

    cancelTween(blade)

    if active then
        part.CanTouch = true
        part.Transparency = 0.2
        local tween
        if blade.upCFrame then
            tween = TweenService:Create(part, tweenInfoUp, { CFrame = blade.upCFrame })
            blade.tween = tween
            tween:Play()
        end
    else
        part.CanTouch = false
        part.Transparency = 1
        blade.hitTimestamps = {}
        if blade.downCFrame then
            local tween = TweenService:Create(part, tweenInfoDown, { CFrame = blade.downCFrame })
            blade.tween = tween
            tween:Play()
        end
    end
end

local function destroyBlade(state, blade)
    if not blade then
        return
    end

    blade.running = false
    cancelTween(blade)
    setBladeActive(state, blade, false)

    if blade.touchConnection then
        blade.touchConnection:Disconnect()
        blade.touchConnection = nil
    end

    local part = blade.part
    if part then
        part:Destroy()
        blade.part = nil
    end

    if blade.lane and state.bladeByLane then
        state.bladeByLane[blade.lane] = nil
    end
end

local function onBladeTouched(state, blade, otherPart)
    if not state.enabled or not blade.active then
        return
    end

    if not otherPart or otherPart.Parent == nil then
        return
    end

    local part = blade.part
    if otherPart == part then
        return
    end

    local character = otherPart.Parent
    if character and not character:IsA("Model") then
        character = character.Parent
    end

    if not character or not character:IsA("Model") then
        return
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
        return
    end

    blade.hitTimestamps = blade.hitTimestamps or {}
    local now = os.clock()
    local last = blade.hitTimestamps[humanoid]
    if last and now - last < HIT_COOLDOWN then
        return
    end

    blade.hitTimestamps[humanoid] = now

    humanoid:TakeDamage(DAMAGE)

    local player = Players:GetPlayerFromCharacter(character)
    local name = player and player.Name or character.Name or "Unknown"
    print(string.format("[SawbladeServer] arena=%s lane=%d dealt %d damage to %s", tostring(state.arenaId), blade.laneIndex or 0, DAMAGE, name))
end

local function createBlade(state, lane, laneIndex)
    local container = resolveContainer(state)
    if not container then
        warnOnce(state, "NoContainer", string.format("[SawbladeServer] Arena %s has no container for sawblades", tostring(state.arenaId)))
        return nil
    end

    local lanePart = findLanePart(lane)
    if not lanePart then
        warnOnce(state, tostring(lane), string.format("[SawbladeServer] Lane %s missing BasePart", tostring(lane and lane.Name)))
        return nil
    end

    local riseHeight = lane:GetAttribute("SawbladeRiseHeight") or lanePart:GetAttribute("SawbladeRiseHeight") or RISE_HEIGHT

    local upOffset = lanePart.Size.Y * 0.5 + BLADE_THICKNESS * 0.5
    local upCFrame = lanePart.CFrame * CFrame.new(0, upOffset, 0)
    local downCFrame = upCFrame * CFrame.new(0, -riseHeight, 0)

    local part = Instance.new("Part")
    part.Name = string.format("Sawblade_Lane%d", laneIndex or 0)
    part.Shape = Enum.PartType.Cylinder
    part.Material = Enum.Material.Metal
    part.Color = Color3.fromRGB(210, 210, 210)
    part.Size = Vector3.new(BLADE_RADIUS * 2, BLADE_THICKNESS, BLADE_RADIUS * 2)
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.Transparency = 1
    part.CFrame = downCFrame
    part.Parent = container

    local blade = {
        lane = lane,
        laneIndex = laneIndex,
        part = part,
        upCFrame = upCFrame,
        downCFrame = downCFrame,
        active = false,
        running = true,
        hitTimestamps = {},
    }

    blade.touchConnection = part.Touched:Connect(function(otherPart)
        onBladeTouched(state, blade, otherPart)
    end)

    state.bladeByLane[lane] = blade
    table.insert(state.blades, blade)

    task.spawn(function()
        local rng = state.rng
        local initialDelay = rng and rng:NextNumber(0, INTERVAL_MIN) or 0
        if initialDelay > 0 then
            task.wait(initialDelay)
        end

        while state.running and blade.running do
            if not state.enabled then
                setBladeActive(state, blade, false)
                task.wait(LOOP_WAIT)
                continue
            end

            local interval = math.clamp((rng and rng:NextNumber(INTERVAL_MIN, INTERVAL_MAX)) or INTERVAL_MIN, INTERVAL_MIN, INTERVAL_MAX)
            local wakeTime = os.clock() + interval
            while state.running and blade.running and state.enabled and os.clock() < wakeTime do
                task.wait(LOOP_WAIT)
            end

            if not state.running or not blade.running or not state.enabled then
                task.wait(LOOP_WAIT)
                continue
            end

            setBladeActive(state, blade, true)

            local activeUntil = os.clock() + UP_TIME
            while state.running and blade.running and state.enabled and os.clock() < activeUntil do
                task.wait(LOOP_WAIT)
            end

            setBladeActive(state, blade, false)
            task.wait(LOOP_WAIT)
        end

        setBladeActive(state, blade, false)
    end)

    return blade
end

local function refreshLanes(state)
    if not state.running then
        return
    end

    local arenaState = fetchArenaState(state.arenaId)
    local lanes = arenaState and arenaState.lanes

    if typeof(lanes) ~= "table" then
        return
    end

    local seen = {}

    for index, lane in ipairs(lanes) do
        if lane and lane:IsDescendantOf(state.arena) then
            seen[lane] = true
            local blade = state.bladeByLane[lane]
            if not blade then
                blade = createBlade(state, lane, index)
            elseif blade then
                blade.laneIndex = index
            end
        end
    end

    for lane, blade in pairs(state.bladeByLane) do
        if not seen[lane] then
            destroyBlade(state, blade)
        end
    end
end

local function updateActivation(state)
    if not state.running then
        return
    end

    local level = tonumber(state.level) or 0
    local phase = state.phase
    local shouldEnable = level >= ENABLE_LEVEL and phase == "Wave"

    if shouldEnable == state.enabled then
        return
    end

    state.enabled = shouldEnable

    if not shouldEnable then
        for _, blade in ipairs(state.blades) do
            setBladeActive(state, blade, false)
        end
    end
end

local function monitorState(state)
    while state.running do
        if not state.arena or state.arena.Parent == nil then
            break
        end

        local roundDirector = getRoundDirector()
        if roundDirector and typeof(roundDirector.GetState) == "function" then
            local ok, rdState = pcall(roundDirector.GetState, roundDirector, state.arenaId)
            if not ok then
                ok, rdState = pcall(roundDirector.GetState, state.arenaId)
            end

            if ok and typeof(rdState) == "table" then
                if typeof(rdState.level) == "number" then
                    state.level = rdState.level
                end
                if typeof(rdState.phase) == "string" then
                    state.phase = rdState.phase
                end
                if typeof(rdState.wave) == "number" then
                    state.wave = rdState.wave
                end
            end
        end

        refreshLanes(state)
        updateActivation(state)

        task.wait(MONITOR_STEP)
    end

    if state.running then
        SawbladeServer:Stop(state.arenaId)
    end
end

function SawbladeServer.Start(selfOrArenaId, arenaIdOrContext, maybeContext)
    local arenaId = selfOrArenaId
    local context = arenaIdOrContext

    if selfOrArenaId == SawbladeServer then
        arenaId = arenaIdOrContext
        context = maybeContext
    end

    if arenaId == nil then
        error("SawbladeServer.Start requires an arenaId")
    end

    SawbladeServer:Stop(arenaId)

    local arena = fetchArenaInstance(arenaId)
    if not arena then
        warn(string.format("[SawbladeServer] Could not resolve arena '%s'", tostring(arenaId)))
        return nil
    end

    local state = {
        arenaId = arenaId,
        arena = arena,
        running = true,
        enabled = false,
        blades = {},
        bladeByLane = {},
        rng = Random.new(os.clock()),
        level = 1,
        phase = "Prep",
        wave = 0,
        warnings = {},
        connections = {},
    }

    if typeof(context) == "table" then
        if typeof(context.level) == "number" then
            state.level = context.level
        elseif typeof(context.Level) == "number" then
            state.level = context.Level
        end

        if typeof(context.phase) == "string" then
            state.phase = context.phase
        elseif typeof(context.Phase) == "string" then
            state.phase = context.Phase
        end

        if typeof(context.wave) == "number" then
            state.wave = context.wave
        elseif typeof(context.Wave) == "number" then
            state.wave = context.Wave
        end
    end

    local ancestryConn = arena.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            SawbladeServer:Stop(arenaId)
        end
    end)
    state.connections[#state.connections + 1] = ancestryConn

    activeStates[arenaId] = state

    refreshLanes(state)
    updateActivation(state)

    task.spawn(monitorState, state)

    return state
end

function SawbladeServer.Stop(selfOrArenaId, maybeArenaId)
    local arenaId = selfOrArenaId
    if selfOrArenaId == SawbladeServer then
        arenaId = maybeArenaId
    end

    if arenaId == nil then
        return
    end

    local state = activeStates[arenaId]
    if not state then
        return
    end

    state.running = false

    for _, connection in ipairs(state.connections or {}) do
        if typeof(connection) == "RBXScriptConnection" then
            connection:Disconnect()
        end
    end
    state.connections = nil

    for _, blade in ipairs(state.blades) do
        destroyBlade(state, blade)
    end

    state.blades = {}
    state.bladeByLane = {}

    if state.createdContainer and state.container and #state.container:GetChildren() == 0 then
        state.container:Destroy()
    end

    activeStates[arenaId] = nil
end

function SawbladeServer.UpdateRoundState(selfOrArenaId, arenaIdOrContext, maybeContext)
    local arenaId = selfOrArenaId
    local context = arenaIdOrContext

    if selfOrArenaId == SawbladeServer then
        arenaId = arenaIdOrContext
        context = maybeContext
    end

    if arenaId == nil then
        return
    end

    local state = activeStates[arenaId]
    if not state then
        return
    end

    if typeof(context) == "table" then
        if typeof(context.level) == "number" then
            state.level = context.level
        elseif typeof(context.Level) == "number" then
            state.level = context.Level
        end

        if typeof(context.phase) == "string" then
            state.phase = context.phase
        elseif typeof(context.Phase) == "string" then
            state.phase = context.Phase
        end

        if typeof(context.wave) == "number" then
            state.wave = context.wave
        elseif typeof(context.Wave) == "number" then
            state.wave = context.Wave
        end
    end

    refreshLanes(state)
    updateActivation(state)
end

return SawbladeServer
