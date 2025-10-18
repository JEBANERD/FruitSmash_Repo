local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local GameConfig = GameConfigModule.Get()
local ArenaServer = require(ServerScriptService:WaitForChild("GameServer"):WaitForChild("ArenaServer"))

local SawbladeServer = {}

local activeArenas = {}
local bindingCount = 0
local originalRespawnTime = Players.RespawnTime
local DEFAULT_RISE_HEIGHT = 4
local TWEEN_TIME = 0.25
local HEARTBEAT_WAIT = 0.25

local tweenInfoUp = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local tweenInfoDown = TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function isModuleSelf(arg)
    return type(arg) == "table" and arg == SawbladeServer
end

local function resolveArguments(selfOrArenaId, maybeArenaIdOrContext, maybeContext)
    if isModuleSelf(selfOrArenaId) then
        return maybeArenaIdOrContext, maybeContext
    end

    return selfOrArenaId, maybeArenaIdOrContext
end

local function warnOnce(state, key, message)
    if state.warnings[key] then
        return
    end

    state.warnings[key] = true
    warn(message)
end

local function findDamagePart(model)
    if not model then
        return nil
    end

    local preferredNames = {
        "DamagePart",
        "Damage",
        "Blade",
        "Sawblade",
        "Hurtbox",
    }

    for _, name in ipairs(preferredNames) do
        local child = model:FindFirstChild(name)
        if child and child:IsA("BasePart") then
            return child
        end
    end

    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            return descendant
        end
    end

    return nil
end

local function findPrimaryPart(model)
    if not model then
        return nil
    end

    if typeof(model.GetPivot) == "function" then
        local pivotPart = model.PrimaryPart
        if pivotPart and pivotPart:IsA("BasePart") then
            return pivotPart
        end

        local descendants = model:GetDescendants()
        for _, descendant in ipairs(descendants) do
            if descendant:IsA("BasePart") then
                model.PrimaryPart = descendant
                return descendant
            end
        end
    end

    return model.PrimaryPart
end

local function modelPivot(model)
    if not model then
        return nil
    end

    if typeof(model.GetPivot) == "function" then
        return model:GetPivot()
    end

    local primary = findPrimaryPart(model)
    if primary then
        return primary.CFrame
    end

    return nil
end

local function setModelCFrame(model, cframe)
    if not model or not cframe then
        return
    end

    if typeof(model.PivotTo) == "function" then
        model:PivotTo(cframe)
    elseif model.PrimaryPart then
        model:SetPrimaryPartCFrame(cframe)
    end
end

local function tweenToCFrame(target, goalCFrame, info)
    if not target or not goalCFrame then
        return nil
    end

    if target:IsA("BasePart") then
        local tween = TweenService:Create(target, info, { CFrame = goalCFrame })
        tween:Play()
        return tween
    elseif target:IsA("Model") then
        -- Tween models by iterating their base parts
        local tweens = {}
        for _, part in ipairs(target:GetDescendants()) do
            if part:IsA("BasePart") then
                local offset = target:GetPivot():ToObjectSpace(part.CFrame)
                local tween = TweenService:Create(part, info, { CFrame = goalCFrame * offset })
                tween:Play()
                table.insert(tweens, tween)
            end
        end
        return tweens
    end

    return nil
end

local function cancelTween(tween)
    if not tween then
        return
    end

    if typeof(tween) == "table" then
        for _, entry in ipairs(tween) do
            if typeof(entry) == "Instance" and entry:IsA("Tween") then
                entry:Cancel()
            end
        end
        return
    end

    if typeof(tween) == "Instance" and tween:IsA("Tween") then
        tween:Cancel()
    end
end

local function gatherSawblades(arena, state)
    local gutterFolder = arena and arena:FindFirstChild("Gutters")
    if not gutterFolder then
        warnOnce(state, "MissingGutters", string.format("[SawbladeObstacle] Arena %s has no Gutters folder", tostring(arena and arena.Name)))
        return {}
    end

    local sawblades = {}
    local seen = {}

    local function isSawbladeName(name)
        if type(name) ~= "string" then
            return false
        end

        local lower = string.lower(name)
        return string.find(lower, "saw") ~= nil or string.find(lower, "blade") ~= nil
    end

    local function registerModel(model)
        if not model or seen[model] then
            return
        end

        seen[model] = true
        local damagePart = findDamagePart(model)
        if not damagePart then
            warnOnce(state, "MissingDamagePart" .. model:GetFullName(), string.format("[SawbladeObstacle] Model %s is missing a damage part", model:GetFullName()))
            return
        end

        local pivot = modelPivot(model)
        if not pivot then
            warnOnce(state, "MissingPivot" .. model:GetFullName(), string.format("[SawbladeObstacle] Model %s cannot determine pivot", model:GetFullName()))
            return
        end

        local riseHeight = model:GetAttribute("SawbladeRiseHeight") or damagePart:GetAttribute("SawbladeRiseHeight") or DEFAULT_RISE_HEIGHT
        local downCFrame = pivot
        local upCFrame = pivot * CFrame.new(0, riseHeight, 0)

        table.insert(sawblades, {
            model = model,
            damagePart = damagePart,
            downCFrame = downCFrame,
            upCFrame = upCFrame,
            active = false,
            lastTween = nil,
            originalTransparency = damagePart.Transparency,
            originalCanTouch = damagePart.CanTouch,
            originalCanCollide = damagePart.CanCollide,
        })
    end

    local function registerPart(part)
        if seen[part] then
            return
        end

        seen[part] = true
        local riseHeight = part:GetAttribute("SawbladeRiseHeight") or DEFAULT_RISE_HEIGHT
        local downCFrame = part.CFrame
        local upCFrame = downCFrame * CFrame.new(0, riseHeight, 0)

        table.insert(sawblades, {
            part = part,
            damagePart = part,
            downCFrame = downCFrame,
            upCFrame = upCFrame,
            active = false,
            lastTween = nil,
            originalTransparency = part.Transparency,
            originalCanTouch = part.CanTouch,
            originalCanCollide = part.CanCollide,
        })
    end

    for _, descendant in ipairs(gutterFolder:GetDescendants()) do
        if descendant:IsA("Model") and isSawbladeName(descendant.Name) then
            registerModel(descendant)
        elseif descendant:IsA("BasePart") and isSawbladeName(descendant.Name) then
            registerPart(descendant)
        elseif descendant:IsA("BasePart") then
            local parent = descendant.Parent
            while parent and parent ~= gutterFolder do
                if parent:IsA("Model") and isSawbladeName(parent.Name) then
                    registerModel(parent)
                    break
                end
                parent = parent.Parent
            end
        end
    end

    return sawblades
end

local function disableDamage(blade)
    local damagePart = blade.damagePart
    if not damagePart then
        return
    end

    damagePart.CanTouch = false
    damagePart.CanCollide = false
    if blade.originalTransparency then
        damagePart.Transparency = blade.originalTransparency
    end
end

local function enableDamage(blade)
    local damagePart = blade.damagePart
    if not damagePart then
        return
    end

    damagePart.CanTouch = true
    damagePart.CanCollide = false
    damagePart.Transparency = blade.originalTransparency or damagePart.Transparency
end

local function moveBlade(blade, up)
    cancelTween(blade.lastTween)

    local targetCFrame = up and blade.upCFrame or blade.downCFrame
    if blade.model then
        local tween = tweenToCFrame(blade.model, targetCFrame, up and tweenInfoUp or tweenInfoDown)
        if not tween then
            setModelCFrame(blade.model, targetCFrame)
        else
            blade.lastTween = tween
        end
    elseif blade.part then
        local tween = TweenService:Create(blade.part, up and tweenInfoUp or tweenInfoDown, { CFrame = targetCFrame })
        tween:Play()
        blade.lastTween = tween
    end
end

local function setBladeActive(state, blade, active)
    if blade.active == active then
        return
    end

    blade.active = active

    if active then
        enableDamage(blade)
    else
        disableDamage(blade)
    end

    moveBlade(blade, active)
end

local function killCharacter(state, humanoid)
    if not humanoid or humanoid.Health <= 0 then
        return
    end

    humanoid.Health = 0
end

local function scheduleRespawn(state, player)
    if not player then
        return
    end

    local now = os.clock()
    local last = state.pendingRespawns[player]
    if last and now - last < 0.1 then
        return
    end

    state.pendingRespawns[player] = now

    local respawnSeconds = state.respawnSeconds
    if respawnSeconds <= 0 then
        if player.Parent then
            player:LoadCharacter()
        end
        state.pendingRespawns[player] = nil
        return
    end

    task.delay(respawnSeconds, function()
        if not state.running then
            return
        end

        if player.Parent then
            player:LoadCharacter()
        end

        state.pendingRespawns[player] = nil
    end)
end

local function onTouched(state, otherPart)
    if not state.enabled then
        return
    end

    if not otherPart then
        return
    end

    local character = otherPart.Parent
    if not character then
        return
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
        return
    end

    local player = Players:GetPlayerFromCharacter(character)
    killCharacter(state, humanoid)
    if player then
        scheduleRespawn(state, player)
    end
end

local function stopBlade(state, blade)
    setBladeActive(state, blade, false)
    cancelTween(blade.lastTween)
    blade.lastTween = nil
end

local function updateEnabled(state)
    local shouldEnable = state.level >= state.enableLevel
    if shouldEnable == state.enabled then
        return
    end

    state.enabled = shouldEnable

    if not shouldEnable then
        for _, blade in ipairs(state.sawblades) do
            stopBlade(state, blade)
        end
    end
end

local function bladeLoop(state, blade)
    while state.running do
        if not state.enabled then
            task.wait(1)
            goto continue
        end

        local interval = state.rng:NextNumber(state.intervalMin, state.intervalMax)
        local wakeTime = os.clock() + interval
        while state.running and state.enabled and os.clock() < wakeTime do
            task.wait(HEARTBEAT_WAIT)
        end

        if not state.running or not state.enabled then
            goto continue
        end

        setBladeActive(state, blade, true)

        local activeEnd = os.clock() + state.upTime
        while state.running and state.enabled and os.clock() < activeEnd do
            task.wait(HEARTBEAT_WAIT)
        end

        stopBlade(state, blade)

        ::continue::
        task.wait(HEARTBEAT_WAIT)
    end
end

local function bindTouch(state, blade)
    if not blade.damagePart then
        return
    end

    blade.touchConnection = blade.damagePart.Touched:Connect(function(otherPart)
        if not state.running or not blade.active then
            return
        end

        onTouched(state, otherPart)
    end)

    disableDamage(blade)
end

local function disconnectBlade(blade)
    if blade.touchConnection then
        blade.touchConnection:Disconnect()
        blade.touchConnection = nil
    end
    cancelTween(blade.lastTween)
    blade.lastTween = nil

    local damagePart = blade.damagePart
    if damagePart then
        if blade.originalCanTouch ~= nil then
            damagePart.CanTouch = blade.originalCanTouch
        end
        if blade.originalCanCollide ~= nil then
            damagePart.CanCollide = blade.originalCanCollide
        end
        if blade.originalTransparency ~= nil then
            damagePart.Transparency = blade.originalTransparency
        end
    end
end

local function resolveArenaInstance(arenaId, context)
    if context then
        if context.instance then
            return context.instance
        end
        if context.arena then
            return context.arena
        end
        if context.Arena then
            return context.Arena
        end
        if context.model then
            return context.model
        end
    end

    local arenaState = ArenaServer.GetArenaState(arenaId)
    if arenaState then
        return arenaState.instance or arenaState.arena or arenaState.model
    end

    return nil
end

function SawbladeServer.BindArena(selfOrArenaId, maybeArenaIdOrContext, maybeContext)
    local arenaId, context = resolveArguments(selfOrArenaId, maybeArenaIdOrContext, maybeContext)
    if arenaId == nil then
        return nil
    end

    SawbladeServer:UnbindArena(arenaId)

    local sawbladeConfig = (GameConfig.Obstacles and GameConfig.Obstacles.Sawblade) or {}
    local enableLevel = (GameConfig.Obstacles and GameConfig.Obstacles.EnableAtLevel) or math.huge
    local respawnSeconds = (GameConfig.Player and GameConfig.Player.SawbladeRespawnSeconds) or 5

    local arenaInstance = resolveArenaInstance(arenaId, context)
    if not arenaInstance then
        warn(string.format("[SawbladeObstacle] Could not resolve arena instance for %s", tostring(arenaId)))
        return nil
    end

    local state = {
        arenaId = arenaId,
        arena = arenaInstance,
        level = context and context.level or context and context.Level or 1,
        enableLevel = enableLevel,
        intervalMin = sawbladeConfig.PopUpIntervalMin or 6,
        intervalMax = sawbladeConfig.PopUpIntervalMax or 9,
        upTime = sawbladeConfig.UpTimeSeconds or 2,
        respawnSeconds = respawnSeconds,
        sawblades = {},
        running = true,
        enabled = false,
        rng = Random.new(os.clock()),
        pendingRespawns = {},
        warnings = {},
        connections = {},
    }

    state.sawblades = gatherSawblades(arenaInstance, state)

    if #state.sawblades == 0 then
        warnOnce(state, "NoSawblades", string.format("[SawbladeObstacle] Arena %s has no sawblades to control", arenaInstance:GetFullName()))
    end

    for _, blade in ipairs(state.sawblades) do
        bindTouch(state, blade)
        task.spawn(bladeLoop, state, blade)
    end

    state.connections[#state.connections + 1] = arenaInstance.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            SawbladeServer:UnbindArena(arenaId)
        end
    end)

    activeArenas[arenaId] = state
    updateEnabled(state)

    bindingCount += 1
    Players.RespawnTime = state.respawnSeconds

    return state
end

function SawbladeServer.SetLevel(selfOrArenaId, maybeArenaIdOrLevel, maybeLevel)
    local arenaId, level = resolveArguments(selfOrArenaId, maybeArenaIdOrLevel, maybeLevel)
    if arenaId == nil then
        return
    end

    local state = activeArenas[arenaId]
    if not state then
        return
    end

    if type(level) ~= "number" then
        return
    end

    state.level = level
    updateEnabled(state)
end

function SawbladeServer.UnbindArena(selfOrArenaId, maybeArenaId)
    local arenaId = resolveArguments(selfOrArenaId, maybeArenaId)
    if arenaId == nil then
        return
    end

    local state = activeArenas[arenaId]
    if not state then
        return
    end

    state.running = false

    for _, blade in ipairs(state.sawblades) do
        stopBlade(state, blade)
        disconnectBlade(blade)
    end

    for _, connection in ipairs(state.connections) do
        if typeof(connection) == "RBXScriptConnection" then
            connection:Disconnect()
        end
    end

    activeArenas[arenaId] = nil

    if bindingCount > 0 then
        bindingCount -= 1
        if bindingCount <= 0 then
            bindingCount = 0
            Players.RespawnTime = originalRespawnTime
        end
    end
end

return SawbladeServer

