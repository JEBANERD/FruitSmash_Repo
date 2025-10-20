--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
localPlayer:WaitForChild("PlayerGui") -- ensure GUI tree ready for touch buttons

local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local gameConfig = if typeof(GameConfigModule.Get) == "function" then GameConfigModule.Get() else GameConfigModule

local playerConfig = gameConfig.Player or {}
local sprintConfig = playerConfig.Sprint or {}
local sprintEnabled = sprintConfig.Enabled ~= false
local defaultWalkSpeed = sprintConfig.BaseWalkSpeed or 16
local defaultSprintSpeed = sprintConfig.BaseSprintSpeed or math.max(defaultWalkSpeed * 1.25, defaultWalkSpeed)

local staminaConfig = sprintConfig.Stamina or {}
local staminaEnabled = staminaConfig.Enabled ~= false
local staminaDrainPerSecond = math.max(staminaConfig.DrainPerSecond or 18, 0)
local staminaRegenPerSecond = math.max(staminaConfig.RegenPerSecond or 12, 0)
local maxStamina = math.max(staminaConfig.Max or 100, 1)

local speedBoostConfig = (gameConfig.PowerUps and gameConfig.PowerUps.SpeedBoost) or {}
local defaultSpeedBoostMultiplier = speedBoostConfig.SpeedMultiplier or 1

local character: Model? = nil
local humanoid: Humanoid? = nil

local sprintActionName = "FruitSmashSprint"
local jumpActionName = "FruitSmashJump"

local isSprintRequested = false
local isSprinting = false
local currentWalkSpeed = 0
local currentStamina = maxStamina

local heartbeatConnection: RBXScriptConnection? = nil
local characterRemovingConnection: RBXScriptConnection? = nil
local humanoidDiedConnection: RBXScriptConnection? = nil

local function readSpeedBoostMultiplierFrom(instance: Instance?): number
    if instance == nil then
        return 1
    end

    local multiplier = 1
    local hasExplicitMultiplier = false

    local attributeMultiplier = instance:GetAttribute("SpeedBoostMultiplier")
    if typeof(attributeMultiplier) == "number" and attributeMultiplier > 0 then
        multiplier *= attributeMultiplier
        hasExplicitMultiplier = true
    end

    local valueObject = instance:FindFirstChild("SpeedBoostMultiplier")
    if valueObject and valueObject:IsA("NumberValue") and valueObject.Value > 0 then
        multiplier *= valueObject.Value
        hasExplicitMultiplier = true
    end

    if not hasExplicitMultiplier then
        local attributeActive = instance:GetAttribute("SpeedBoostActive")
        local boolObject = instance:FindFirstChild("SpeedBoostActive")
        local isActive = attributeActive == true
            or (boolObject and boolObject:IsA("BoolValue") and boolObject.Value)

        if isActive then
            multiplier *= defaultSpeedBoostMultiplier
        end
    end

    return multiplier
end

local function getTotalSpeedBoostMultiplier(): number
    local totalMultiplier = 1

    totalMultiplier *= readSpeedBoostMultiplierFrom(localPlayer)
    totalMultiplier *= readSpeedBoostMultiplierFrom(character)
    totalMultiplier *= readSpeedBoostMultiplierFrom(humanoid)

    if totalMultiplier < 0.01 then
        totalMultiplier = 0.01
    end

    return totalMultiplier
end

local function resolveBaseSpeeds(): (number, number)
    local resolvedWalk = defaultWalkSpeed
    local resolvedSprint = defaultSprintSpeed

    local function applyOverrides(instance: Instance?)
        if instance == nil then
            return
        end

        local overrideWalk = instance:GetAttribute("BaseWalkSpeed")
        if typeof(overrideWalk) == "number" and overrideWalk >= 0 then
            resolvedWalk = overrideWalk
        end

        local overrideSprint = instance:GetAttribute("BaseSprintSpeed")
        if typeof(overrideSprint) == "number" and overrideSprint >= 0 then
            resolvedSprint = overrideSprint
        end
    end

    applyOverrides(localPlayer)
    applyOverrides(character)
    applyOverrides(humanoid)

    if resolvedSprint < resolvedWalk then
        resolvedSprint = resolvedWalk
    end

    return resolvedWalk, resolvedSprint
end

local function applyHumanoidWalkSpeed()
    if not humanoid then
        return
    end

    local walkSpeed, sprintSpeed = resolveBaseSpeeds()
    local baseSpeed = if isSprinting then sprintSpeed else walkSpeed
    local targetSpeed = baseSpeed * getTotalSpeedBoostMultiplier()

    if math.abs(targetSpeed - currentWalkSpeed) > 0.01 then
        currentWalkSpeed = targetSpeed
        humanoid.WalkSpeed = targetSpeed
    end
end

local function resetStamina()
    currentStamina = maxStamina
end

local function setSprintRequest(isRequested: boolean)
    if not sprintEnabled then
        isSprintRequested = false
        return
    end

    if isSprintRequested ~= isRequested then
        isSprintRequested = isRequested
    end
end

local function updateSprint(dt: number)
    if humanoid == nil then
        return
    end

    if not sprintEnabled then
        if isSprinting then
            isSprinting = false
        end
        if staminaEnabled and currentStamina < maxStamina then
            currentStamina = math.min(maxStamina, currentStamina + staminaRegenPerSecond * dt)
        end
        applyHumanoidWalkSpeed()
        return
    end

    if humanoid.Health <= 0 then
        if isSprinting then
            isSprinting = false
        end
        if staminaEnabled and currentStamina < maxStamina then
            currentStamina = math.min(maxStamina, currentStamina + staminaRegenPerSecond * dt)
        end
        applyHumanoidWalkSpeed()
        return
    end

    local isMoving = humanoid.MoveDirection.Magnitude > 0.05
    local staminaAvailable = (not staminaEnabled) or currentStamina > 0

    local shouldSprint = isSprintRequested and isMoving and staminaAvailable
    isSprinting = shouldSprint

    if staminaEnabled then
        if shouldSprint then
            currentStamina = math.max(0, currentStamina - staminaDrainPerSecond * dt)
            if currentStamina <= 0 then
                isSprinting = false
                isSprintRequested = false
            end
        else
            currentStamina = math.min(maxStamina, currentStamina + staminaRegenPerSecond * dt)
        end
    end

    applyHumanoidWalkSpeed()
end

local function onHeartbeat(dt: number)
    updateSprint(dt)
end

local function onSprintAction(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject?)
    if inputState == Enum.UserInputState.Begin then
        setSprintRequest(true)
        return Enum.ContextActionResult.Sink
    elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
        setSprintRequest(false)
        return Enum.ContextActionResult.Sink
    end

    return Enum.ContextActionResult.Pass
end

local function onJumpAction(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject?)
    if humanoid == nil then
        return Enum.ContextActionResult.Pass
    end

    if inputObject and inputObject.UserInputType == Enum.UserInputType.Keyboard then
        return Enum.ContextActionResult.Pass
    end

    if inputState == Enum.UserInputState.Begin then
        humanoid.Jump = true
        return Enum.ContextActionResult.Sink
    end

    return Enum.ContextActionResult.Pass
end

local function bindInputActions()
    local createTouchButtons = UserInputService.TouchEnabled

    ContextActionService:BindAction(sprintActionName, onSprintAction, createTouchButtons, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.ButtonL3, Enum.KeyCode.ButtonR3)
    if createTouchButtons then
        ContextActionService:SetPosition(sprintActionName, UDim2.new(0.7, 0, 0.85, 0))
        ContextActionService:SetTitle(sprintActionName, "SPRINT")
    end

    ContextActionService:BindAction(jumpActionName, onJumpAction, createTouchButtons, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
    if createTouchButtons then
        ContextActionService:SetPosition(jumpActionName, UDim2.new(0.85, 0, 0.85, 0))
        ContextActionService:SetTitle(jumpActionName, "JUMP")
    end
end

local function disconnectConnections()
    if heartbeatConnection then
        heartbeatConnection:Disconnect()
        heartbeatConnection = nil
    end

    if humanoidDiedConnection then
        humanoidDiedConnection:Disconnect()
        humanoidDiedConnection = nil
    end

    if characterRemovingConnection then
        characterRemovingConnection:Disconnect()
        characterRemovingConnection = nil
    end
end

local function prepareHumanoid(newHumanoid: Humanoid)
    humanoid = newHumanoid
    resetStamina()
    currentWalkSpeed = 0
    applyHumanoidWalkSpeed()

    if humanoidDiedConnection then
        humanoidDiedConnection:Disconnect()
    end

    humanoidDiedConnection = humanoid.Died:Connect(function()
        isSprinting = false
        isSprintRequested = false
        applyHumanoidWalkSpeed()
    end)

    if heartbeatConnection then
        heartbeatConnection:Disconnect()
    end

    heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)
end

local function onCharacterAdded(newCharacter: Model)
    disconnectConnections()

    character = newCharacter
    humanoid = nil

    local foundHumanoid = character:FindFirstChildOfClass("Humanoid")
    if foundHumanoid == nil then
        foundHumanoid = character:WaitForChild("Humanoid")
    end

    if foundHumanoid then
        prepareHumanoid(foundHumanoid)
    end

    if characterRemovingConnection then
        characterRemovingConnection:Disconnect()
    end

    characterRemovingConnection = character.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            disconnectConnections()
            character = nil
            humanoid = nil
            isSprintRequested = false
            isSprinting = false
            currentWalkSpeed = 0
        end
    end)
end

bindInputActions()

if localPlayer.Character then
    onCharacterAdded(localPlayer.Character)
end

localPlayer.CharacterAdded:Connect(onCharacterAdded)

localPlayer:GetPropertyChangedSignal("Character"):Connect(function()
    if localPlayer.Character then
        onCharacterAdded(localPlayer.Character)
    end
end)

-- React to attribute changes for live speed adjustments
localPlayer.AttributeChanged:Connect(function()
    applyHumanoidWalkSpeed()
end)

RunService.Heartbeat:Connect(function()
    if character and not character:IsDescendantOf(workspace) then
        disconnectConnections()
        character = nil
        humanoid = nil
        isSprintRequested = false
        isSprinting = false
        currentWalkSpeed = 0
    end
end)
