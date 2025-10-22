--!strict
-- PlayerController.client.lua
-- Handles sprinting, stamina, jump assist (mobile/controller), and speed-boost multipliers.

--// Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--// Player
local localPlayer: Player = Players.LocalPlayer
localPlayer:WaitForChild("PlayerGui") -- ensure GUI tree exists for mobile virtual buttons

--// Config
local GameConfigModule = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig")
)
local GameConfig = if typeof(GameConfigModule.Get) == "function" then GameConfigModule.Get() else GameConfigModule

local playerConfig = GameConfig.Player or {}
local sprintConfig = playerConfig.Sprint or {}
local staminaConfig = sprintConfig.Stamina or {}
local speedBoostConfig = (GameConfig.PowerUps and GameConfig.PowerUps.SpeedBoost) or {}

local SPRINT_ENABLED = sprintConfig.Enabled ~= false
local BASE_WALK_SPEED: number = sprintConfig.BaseWalkSpeed or 16
local BASE_SPRINT_SPEED: number = sprintConfig.BaseSprintSpeed or math.max(BASE_WALK_SPEED * 1.25, BASE_WALK_SPEED)

local STAMINA_ENABLED = staminaConfig.Enabled ~= false
local STAMINA_MAX: number = math.max(staminaConfig.Max or 100, 1)
local STAMINA_DRAIN_PER_SEC: number = math.max(staminaConfig.DrainPerSecond or 18, 0)
local STAMINA_REGEN_PER_SEC: number = math.max(staminaConfig.RegenPerSecond or 12, 0)

local DEFAULT_SPEEDBOOST_MULT: number = speedBoostConfig.SpeedMultiplier or 1

--// State
local character: Model? = nil
local humanoid: Humanoid? = nil

local currentWalkSpeed: number = 0
local isSprintRequested: boolean = false
local isSprinting: boolean = false
local currentStamina: number = STAMINA_MAX

--// Actions
local ACTION_SPRINT = "FruitSmash_Sprint"
local ACTION_JUMP = "FruitSmash_Jump"

--// Connections
local conHeartbeat: RBXScriptConnection? = nil
local conHumanoidDied: RBXScriptConnection? = nil
local conCharacterRemoving: RBXScriptConnection? = nil

--=============================================================
-- Utility
--=============================================================

local function readSpeedBoostMultiplierFrom(instance: Instance?): number
	if instance == nil then
		return 1
	end

	local mult = 1
	local hadExplicit = false

	local attrMult = instance:GetAttribute("SpeedBoostMultiplier")
	if typeof(attrMult) == "number" and attrMult > 0 then
		mult *= attrMult
		hadExplicit = true
	end

	local nv = instance:FindFirstChild("SpeedBoostMultiplier")
	if nv and nv:IsA("NumberValue") and nv.Value > 0 then
		mult *= nv.Value
		hadExplicit = true
	end

	if not hadExplicit then
		local attrActive = instance:GetAttribute("SpeedBoostActive")
		local bv = instance:FindFirstChild("SpeedBoostActive")
		local active = (attrActive == true) or (bv and bv:IsA("BoolValue") and bv.Value)
		if active then
			mult *= DEFAULT_SPEEDBOOST_MULT
		end
	end

	if mult < 0.01 then
		mult = 0.01
	end
	return mult
end

local function getTotalSpeedBoostMultiplier(): number
	local total = 1

	total *= readSpeedBoostMultiplierFrom(localPlayer)

	local c: Model? = character
	if c then
		total *= readSpeedBoostMultiplierFrom(c)
	end

	local h: Humanoid? = humanoid
	if h then
		total *= readSpeedBoostMultiplierFrom(h)
	end

	if total < 0.01 then total = 0.01 end
	return total
end

local function resolveBaseSpeeds(): (number, number)
	local walk = BASE_WALK_SPEED
	local sprint = BASE_SPRINT_SPEED

	local function apply(instance: Instance?)
		if not instance then return end
		local ow = instance:GetAttribute("BaseWalkSpeed")
		if typeof(ow) == "number" and ow >= 0 then
			walk = ow
		end
		local os = instance:GetAttribute("BaseSprintSpeed")
		if typeof(os) == "number" and os >= 0 then
			sprint = os
		end
	end

	apply(localPlayer)

	local c: Model? = character
	if c then apply(c) end

	local h: Humanoid? = humanoid
	if h then apply(h) end

	if sprint < walk then
		sprint = walk
	end
	return walk, sprint
end

local function applyHumanoidWalkSpeed(): ()
	local h: Humanoid? = humanoid
	if not h then return end

	local walk, sprint = resolveBaseSpeeds()
	local base = if isSprinting then sprint else walk
	local target = base * getTotalSpeedBoostMultiplier()

	if math.abs(target - currentWalkSpeed) > 0.01 then
		currentWalkSpeed = target
		h.WalkSpeed = target
	end
end

local function resetStamina(): ()
	currentStamina = STAMINA_MAX
end

local function setSprintRequest(requested: boolean): ()
	if not SPRINT_ENABLED then
		isSprintRequested = false
		return
	end
	isSprintRequested = requested
end

--=============================================================
-- Tick / Update
--=============================================================

local function updateSprint(dt: number): ()
	local h: Humanoid? = humanoid
	if h == nil then
		return
	end

	if not SPRINT_ENABLED then
		if isSprinting then
			isSprinting = false
		end
		if STAMINA_ENABLED and currentStamina < STAMINA_MAX then
			currentStamina = math.min(STAMINA_MAX, currentStamina + STAMINA_REGEN_PER_SEC * dt)
		end
		applyHumanoidWalkSpeed()
		return
	end

	if h.Health <= 0 then
		if isSprinting then
			isSprinting = false
		end
		if STAMINA_ENABLED and currentStamina < STAMINA_MAX then
			currentStamina = math.min(STAMINA_MAX, currentStamina + STAMINA_REGEN_PER_SEC * dt)
		end
		applyHumanoidWalkSpeed()
		return
	end

	local isMoving = h.MoveDirection.Magnitude > 0.05
	local staminaOK = (not STAMINA_ENABLED) or currentStamina > 0

	local shouldSprint = isSprintRequested and isMoving and staminaOK
	isSprinting = shouldSprint

	if STAMINA_ENABLED then
		if shouldSprint then
			currentStamina = math.max(0, currentStamina - STAMINA_DRAIN_PER_SEC * dt)
			if currentStamina <= 0 then
				isSprinting = false
				isSprintRequested = false
			end
		else
			currentStamina = math.min(STAMINA_MAX, currentStamina + STAMINA_REGEN_PER_SEC * dt)
		end
	end

	applyHumanoidWalkSpeed()
end

local function onHeartbeat(dt: number): ()
	updateSprint(dt)
end

--=============================================================
-- Input
--=============================================================

local function onSprintAction(_actionName: string, inputState: Enum.UserInputState, _input: InputObject?): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		setSprintRequest(true)
		return Enum.ContextActionResult.Sink
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		setSprintRequest(false)
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function onJumpAction(_actionName: string, inputState: Enum.UserInputState, input: InputObject?): Enum.ContextActionResult
	local h: Humanoid? = humanoid
	if h == nil then
		return Enum.ContextActionResult.Pass
	end

	-- Keyboard space uses Roblox default jump; we add virtual for mobile/controller.
	if input and input.UserInputType == Enum.UserInputType.Keyboard then
		return Enum.ContextActionResult.Pass
	end

	if inputState == Enum.UserInputState.Begin then
		h.Jump = true
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function bindInput(): ()
	local makeTouchButtons = UserInputService.TouchEnabled

        ContextActionService:BindAction(
                ACTION_SPRINT,
                onSprintAction,
                makeTouchButtons,
                Enum.KeyCode.LeftShift,
                Enum.KeyCode.RightShift,
                Enum.KeyCode.ButtonL3,
                Enum.KeyCode.ButtonR3,
                Enum.KeyCode.ButtonB
        )
	if makeTouchButtons then
		ContextActionService:SetTitle(ACTION_SPRINT, "SPRINT")
		ContextActionService:SetPosition(ACTION_SPRINT, UDim2.new(0.70, 0, 0.86, 0))
	end

	ContextActionService:BindAction(
		ACTION_JUMP,
		onJumpAction,
		makeTouchButtons,
		Enum.KeyCode.Space, Enum.KeyCode.ButtonA
	)
	if makeTouchButtons then
		ContextActionService:SetTitle(ACTION_JUMP, "JUMP")
		ContextActionService:SetPosition(ACTION_JUMP, UDim2.new(0.86, 0, 0.86, 0))
	end
end

--=============================================================
-- Character / Humanoid wiring
--=============================================================

local function disconnectAll(): ()
	if conHeartbeat then conHeartbeat:Disconnect(); conHeartbeat = nil end
	if conHumanoidDied then conHumanoidDied:Disconnect(); conHumanoidDied = nil end
	if conCharacterRemoving then conCharacterRemoving:Disconnect(); conCharacterRemoving = nil end
end

local function prepareHumanoid(h: Humanoid): ()
	humanoid = h
	resetStamina()
	currentWalkSpeed = 0
	applyHumanoidWalkSpeed()

	if conHumanoidDied then conHumanoidDied:Disconnect(); conHumanoidDied = nil end
	conHumanoidDied = h.Died:Connect(function()
		isSprinting = false
		isSprintRequested = false
		applyHumanoidWalkSpeed()
	end)

	if conHeartbeat then conHeartbeat:Disconnect(); conHeartbeat = nil end
	conHeartbeat = RunService.Heartbeat:Connect(onHeartbeat)
end

local function onCharacterAdded(newChar: Model): ()
	disconnectAll()

	-- Keep your upvalues in sync, but operate on a non-optional local 'c'
	character = newChar
	humanoid = nil

	local c: Model = newChar

	-- Strict-safe Humanoid lookup
	local found: Humanoid? = c:FindFirstChildOfClass("Humanoid")
	if found == nil then
		found = c:WaitForChild("Humanoid") :: Humanoid
	end
	if found then
		prepareHumanoid(found)
	end

	-- Rebind removal watcher using the concrete 'c', not the upvalue
	if conCharacterRemoving then
		conCharacterRemoving:Disconnect()
		conCharacterRemoving = nil
	end
	conCharacterRemoving = c.AncestryChanged:Connect(function(_inst: Instance, parent: Instance?)
		if parent == nil then
			disconnectAll()
			character = nil
			humanoid = nil
			isSprintRequested = false
			isSprinting = false
			currentWalkSpeed = 0
		end
	end)
end

--=============================================================
-- Bootstrap
--=============================================================

bindInput()

-- Strict-safe initial character fetch (never pass Model? to onCharacterAdded)
task.defer(function()
	local existing: Model = localPlayer.Character or localPlayer.CharacterAdded:Wait()
	onCharacterAdded(existing)
end)

-- Respawns
localPlayer.CharacterAdded:Connect(onCharacterAdded)

-- Update speed live if attributes affecting speed change
localPlayer.AttributeChanged:Connect(function(_attr: string)
	applyHumanoidWalkSpeed()
end)

-- Ensure references remain valid (handles teleports within same place etc.)
RunService.Heartbeat:Connect(function()
	local c: Model? = character
	if c and not c:IsDescendantOf(Workspace) then
		disconnectAll()
		character = nil
		humanoid = nil
		isSprintRequested = false
		isSprinting = false
		currentWalkSpeed = 0
	end
end)
