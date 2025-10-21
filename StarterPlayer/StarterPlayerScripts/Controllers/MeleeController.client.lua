
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local localPlayer: Player = Players.LocalPlayer

local RemotesModule = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))
local meleeRemote: RemoteEvent? = RemotesModule and RemotesModule.RE_MeleeHitAttempt or nil

local ACTION_NAME = "FruitSmashMeleeSwing"
local SWING_COOLDOWN_SECONDS = 0.35
local MAX_MELEE_DISTANCE = 18
local CLIENT_DISTANCE_PADDING = 4
local MAX_TARGET_DISTANCE = MAX_MELEE_DISTANCE + CLIENT_DISTANCE_PADDING
local SWING_RAY_DISTANCE = 60
local SWING_ANIMATION_ID = "rbxassetid://507771019" -- Sword slash placeholder

local pointerLocation: Vector2? = nil
local lastSwingTime = -math.huge
local character: Model? = nil
local humanoid: Humanoid? = nil
local humanoidDiedConn: RBXScriptConnection? = nil
local swingAnimation: Animation? = nil
local swingTrack: AnimationTrack? = nil

local mouse = localPlayer:GetMouse()

local function hasFruitAttributes(part: BasePart): boolean
	if part:GetAttribute("Damage") ~= nil then
		return true
	end
	if part:GetAttribute("Wear") ~= nil then
		return true
	end
	if part:GetAttribute("Path") ~= nil then
		return true
	end
	if part:GetAttribute("HPClass") ~= nil then
		return true
	end
	if part:GetAttribute("Coins") ~= nil then
		return true
	end
	if part:GetAttribute("Points") ~= nil then
		return true
	end
	return false
end

local function resolveFruitPartFromInstance(instance: Instance?): BasePart?
	local current = instance
	while current do
		if current:IsA("BasePart") and hasFruitAttributes(current) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function cleanupSwingTrack()
	if swingTrack then
		swingTrack:Stop(0)
		swingTrack:Destroy()
		swingTrack = nil
	end
end

local function disconnectHumanoid()
	if humanoidDiedConn then
		humanoidDiedConn:Disconnect()
		humanoidDiedConn = nil
	end
end

local function setHumanoid(newHumanoid: Humanoid?)
	if humanoid == newHumanoid then
		return
	end

	disconnectHumanoid()
	cleanupSwingTrack()
	humanoid = newHumanoid

	if newHumanoid then
		humanoidDiedConn = newHumanoid.Died:Connect(function()
			cleanupSwingTrack()
			disconnectHumanoid()
			humanoid = nil
		end)
	end
end

local function setCharacter(newCharacter: Model?)
	character = newCharacter

	local newHumanoid: Humanoid? = nil
	if newCharacter then
		newHumanoid = newCharacter:FindFirstChildOfClass("Humanoid")
		if not newHumanoid then
			local ok, result = pcall(function()
				return newCharacter:WaitForChild("Humanoid", 5)
			end)
			if ok and typeof(result) == "Instance" and result:IsA("Humanoid") then
				newHumanoid = result
			end
		end
	end

	setHumanoid(newHumanoid)
end

local function ensureSwingAnimation(): Animation
	if swingAnimation then
		return swingAnimation
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = SWING_ANIMATION_ID
	swingAnimation = animation
	return animation
end

local function ensureSwingTrack(): AnimationTrack?
	if not humanoid then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	if swingTrack and swingTrack.Parent ~= animator then
		cleanupSwingTrack()
	end

	if not swingTrack then
		local animation = ensureSwingAnimation()
		swingTrack = animator:LoadAnimation(animation)
		swingTrack.Priority = Enum.AnimationPriority.Action
	end

	return swingTrack
end

local function playSwingAnimation()
	local track = ensureSwingTrack()
	if not track then
		return
	end

	if track.IsPlaying then
		track:Stop(0)
	end
	track:Play(0.05, 1, 1)
end

local function recordPointerFromInput(input: InputObject)
	local position = input.Position
	if typeof(position) ~= "Vector3" then
		return
	end
	pointerLocation = Vector2.new(position.X, position.Y)
end

-- Finds the nearest fruit part around a position
local function findNearestFruit(position: Vector3, radius: number): BasePart?
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude -- was Blacklist (deprecated)
	if character then
		overlapParams.FilterDescendantsInstances = { character }
	else
		overlapParams.FilterDescendantsInstances = {}
	end
	overlapParams.MaxParts = 100

	-- GetPartBoundsInRadius is safe; no need for pcall
	local parts = Workspace:GetPartBoundsInRadius(position, radius, overlapParams)
	if not parts then
		return nil
	end

	local closest: BasePart? = nil
	local closestDist = math.huge

	for _, part in ipairs(parts) do
		if part:IsA("BasePart") then
			local fruitPart = resolveFruitPartFromInstance(part)
			if fruitPart then
				local distance = (fruitPart.Position - position).Magnitude
				if distance < closestDist then
					closestDist = distance
					closest = fruitPart
				end
			end
		end
	end

	return closest
end

-- Raycasts forward and resolves a valid fruit target + hit position
local function resolveRaycastTarget(rayOrigin: Vector3, rayDirection: Vector3): (BasePart?, Vector3?)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude -- was Blacklist (deprecated)
	if character then
		params.FilterDescendantsInstances = { character }
	else
		params.FilterDescendantsInstances = {}
	end
	params.IgnoreWater = true

	local result = Workspace:Raycast(rayOrigin, rayDirection, params)
	if result then
		local fruitPart = resolveFruitPartFromInstance(result.Instance)
		if fruitPart then
			return fruitPart, result.Position
		end
	end

	return nil, nil
end

local function resolveSwingTarget(inputObject: InputObject?): (BasePart?, Vector3?)
	if mouse then
		local mouseTarget = mouse.Target
		local fruitPart = resolveFruitPartFromInstance(mouseTarget)
		if fruitPart then
			local hitCFrame = mouse.Hit
			local hitPosition = hitCFrame and hitCFrame.Position or fruitPart.Position
			return fruitPart, hitPosition
		end
	end

	local pointer: Vector2? = nil
	if inputObject then
		local position = inputObject.Position
		if typeof(position) == "Vector3" then
			pointer = Vector2.new(position.X, position.Y)
		end
	end

	if not pointer then
		pointer = pointerLocation
	end

	if not pointer and UserInputService.MouseEnabled then
		local mouseLocation = UserInputService:GetMouseLocation()
		pointer = Vector2.new(mouseLocation.X, mouseLocation.Y)
	end

	local camera = Workspace.CurrentCamera
	if camera and pointer then
		local unitRay = camera:ViewportPointToRay(pointer.X, pointer.Y)
		local fruitPart, hitPosition = resolveRaycastTarget(unitRay.Origin, unitRay.Direction * SWING_RAY_DISTANCE)
		if fruitPart then
			return fruitPart, hitPosition
		end
	end

	if character then
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart and camera then
			local forward = camera.CFrame.LookVector
			local searchPosition = rootPart.Position + forward * (MAX_MELEE_DISTANCE * 0.75)
			local fallbackPart = findNearestFruit(searchPosition, MAX_TARGET_DISTANCE)
			if fallbackPart then
				return fallbackPart, fallbackPart.Position
			end
		elseif rootPart then
			local fallbackPart = findNearestFruit(rootPart.Position, MAX_TARGET_DISTANCE)
			if fallbackPart then
				return fallbackPart, fallbackPart.Position
			end
		end
	end

	return nil, nil
end

local function fireSwing(inputObject: InputObject?)
	if not meleeRemote then
		warn("[MeleeController] RE_MeleeHitAttempt remote missing")
		return
	end

	local now = os.clock()
	if now - lastSwingTime < SWING_COOLDOWN_SECONDS then
		return
	end

	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local fruitPart, hitPosition = resolveSwingTarget(inputObject)
	if not fruitPart then
		return
	end

	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		local referencePosition = hitPosition or fruitPart.Position
		local distance = (rootPart.Position - referencePosition).Magnitude
		if distance > MAX_TARGET_DISTANCE then
			return
		end
	end

	lastSwingTime = now

	playSwingAnimation()

	local fruitIdValue = fruitPart:GetAttribute("FruitId")
	local fruitId = if typeof(fruitIdValue) == "string" and fruitIdValue ~= "" then fruitIdValue else fruitPart.Name
	local attackPosition = hitPosition or fruitPart.Position

	meleeRemote:FireServer({
		fruit = fruitPart,
		fruitId = fruitId,
		position = attackPosition,
	})
end

local function actionHandler(actionName: string, inputState: Enum.UserInputState, inputObject: InputObject?)
	if actionName ~= ACTION_NAME then
		return Enum.ContextActionResult.Pass
	end

	if inputState == Enum.UserInputState.Begin then
		if inputObject then
			recordPointerFromInput(inputObject)
		end
		fireSwing(inputObject)
		return Enum.ContextActionResult.Sink
	end

	return Enum.ContextActionResult.Pass
end

local function onInputBegan(input: InputObject, processed: boolean)
	if processed then
		return
	end

	if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
		recordPointerFromInput(input)
	end
end

local function onInputChanged(input: InputObject, processed: boolean)
	if processed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
		recordPointerFromInput(input)
	end
end

if localPlayer.Character then
	setCharacter(localPlayer.Character)
end

localPlayer.CharacterAdded:Connect(function(newCharacter)
	setCharacter(newCharacter)
end)

localPlayer.CharacterRemoving:Connect(function()
	setCharacter(nil)
end)

UserInputService.InputBegan:Connect(onInputBegan)
UserInputService.InputChanged:Connect(onInputChanged)

ContextActionService:BindAction(
	ACTION_NAME,
	actionHandler,
	false,
	Enum.UserInputType.MouseButton1,
	Enum.UserInputType.Touch,
	Enum.KeyCode.ButtonR2,
	Enum.KeyCode.ButtonL2,
	Enum.KeyCode.ButtonR1,
	Enum.KeyCode.ButtonX
)
