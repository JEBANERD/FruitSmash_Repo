--!strict

local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))

local gameConfig = if typeof(GameConfigModule.Get) == "function" then GameConfigModule.Get() else GameConfigModule
local uiConfig = gameConfig.UI or {}

if uiConfig.UseQuickbar == false then
	return
end

local quickbarConfig = uiConfig.Quickbar or {}
local meleeSlotCount = math.clamp(quickbarConfig.MeleeSlots or 2, 0, 8)
local tokenSlotCount = math.clamp(quickbarConfig.TokenSlots or 3, 0, 8)

if meleeSlotCount + tokenSlotCount <= 0 then
	return
end

local CameraFeelBus = require(script.Parent:WaitForChild("CameraFeelBus"))

type SlotKind = "melee" | "token"
type SlotDefinition = {
	kind: SlotKind,
	index: number,
}

type DirectionInfo = {
        keyCode: Enum.KeyCode,
        name: string,
}

type BindActionInput = Enum.KeyCode | Enum.UserInputType

local slotDefinitions: { SlotDefinition } = {}

for index = 1, meleeSlotCount do
	table.insert(slotDefinitions, { kind = "melee", index = index })
end

for index = 1, tokenSlotCount do
	table.insert(slotDefinitions, { kind = "token", index = index })
end

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local useTokenRemoteInstance = remotesFolder:WaitForChild("RF_UseToken")
local useTokenRemote: RemoteFunction? =
        if useTokenRemoteInstance:IsA("RemoteFunction") then useTokenRemoteInstance else nil

local missingTokenRemoteWarned = false

local function requestUseToken(slotIndex: number): boolean
        local remote = useTokenRemote
        if remote == nil then
                if not missingTokenRemoteWarned then
                        missingTokenRemoteWarned = true
                        warn("[ControllerSupport] RF_UseToken remote is unavailable; cannot use tokens.")
                end
                return false
	end

	CameraFeelBus.TokenBump()

	local success, result = pcall(function()
		return remote:InvokeServer(slotIndex)
	end)

	if not success then
		warn(string.format("[ControllerSupport] Failed to invoke RF_UseToken for slot %d: %s", slotIndex, tostring(result)))
		return false
	end
	return true
end

local quickbarGuiName = "QuickbarHUD"
local quickbarContainerName = "QuickbarContainer"

local quickbarFrame: Frame? = nil
local slotButtonsOrdered: { GuiButton } = {}

local glyphObjects: { [GuiButton]: ImageLabel? } = {}
local glyphAssignments: { [GuiButton]: number? } = {}
local glyphImages: { [Enum.KeyCode]: string? } = {}
local buttonCleanupConnections: { [GuiButton]: RBXScriptConnection? } = {}

local DPAD_LAYOUT: { DirectionInfo } = {
        { keyCode = Enum.KeyCode.DPadLeft, name = "Left" },
        { keyCode = Enum.KeyCode.DPadUp, name = "Up" },
        { keyCode = Enum.KeyCode.DPadRight, name = "Right" },
        { keyCode = Enum.KeyCode.DPadDown, name = "Down" },
}

local pageStartIndex = 1

local connections: { RBXScriptConnection } = {}
local quickbarConnections: { RBXScriptConnection } = {}
local boundActions: { string } = {}
local menuOpen = false

local function isDescendantOfQuickbar(instance: Instance?): boolean
	while instance do
		if instance == quickbarFrame then
			return true
		end
		instance = instance.Parent
	end
	return false
end

local function shouldAllowQuickbarInput(): boolean
	if not quickbarFrame or not quickbarFrame.Parent then
		return false
	end
	if menuOpen then
		return false
	end

	local selected = GuiService.SelectedObject
	if selected and not isDescendantOfQuickbar(selected) then
		return false
	end
	return true
end

local function isGamepadInputType(inputType: Enum.UserInputType?): boolean
        if inputType == nil then
                return false
        end
        local value = inputType.Value
        local first = Enum.UserInputType.Gamepad1.Value
	local last = Enum.UserInputType.Gamepad8.Value
	if value >= first and value <= last then
		return true
	end
	local name = tostring(inputType)
	return string.find(name, "Gamepad", 1, true) ~= nil
end

local lastInputType: Enum.UserInputType? = UserInputService:GetLastInputType()
local gamepadPreferred = isGamepadInputType(lastInputType)

local function clearButtonTracking(button: GuiButton)
	local glyph = glyphObjects[button]
	if glyph then
		glyph:Destroy()
		glyphObjects[button] = nil
	end
	glyphAssignments[button] = nil
	local conn = buttonCleanupConnections[button]
	if conn then
		conn:Disconnect()
		buttonCleanupConnections[button] = nil
	end
end

local function updateGlyphVisibility()
        local shouldShow = gamepadPreferred and quickbarFrame ~= nil and quickbarFrame.Parent ~= nil and shouldAllowQuickbarInput()
        for button, glyph in pairs(glyphObjects) do
                if glyph then
                        local assigned = glyphAssignments[button]
                        glyph.Visible = shouldShow and assigned ~= nil
                end
        end
end

local function ensureGlyph(button: GuiButton, directionInfo: DirectionInfo)
	local glyph = glyphObjects[button]
	if not glyph then
		glyph = Instance.new("ImageLabel")
		glyph.Name = "ControllerGlyph"
		glyph.BackgroundTransparency = 1
		glyph.Size = UDim2.fromOffset(28, 28)
		glyph.Position = UDim2.new(0, 6, 0, 6)
		glyph.ImageColor3 = Color3.new(1, 1, 1)
		glyph.ZIndex = button.ZIndex + 1
		glyph.Visible = false
		glyph.Parent = button
		glyphObjects[button] = glyph

                if buttonCleanupConnections[button] == nil then
                        buttonCleanupConnections[button] = button.Destroying:Connect(function()
                                clearButtonTracking(button)
                                updateGlyphVisibility()
                        end)
                end
	end

        local cachedImage = glyphImages[directionInfo.keyCode]
        if cachedImage == nil then
                local ok, result = pcall(function()
                        return UserInputService:GetImageForKeyCode(directionInfo.keyCode)
                end)
                if ok and typeof(result) == "string" then
			cachedImage = result
		else
			cachedImage = ""
		end
		glyphImages[directionInfo.keyCode] = cachedImage
	end

        glyph.Image = cachedImage or ""
end

local function updateGlyphAssignments()
        for button, _ in pairs(glyphAssignments) do
                glyphAssignments[button] = nil
        end

        local totalSlots = #slotButtonsOrdered
        if totalSlots == 0 then
                pageStartIndex = 1
                updateGlyphVisibility()
                return
        end

	local dpadCount = #DPAD_LAYOUT
	local maxStart = math.max(totalSlots - (dpadCount - 1), 1)
	if pageStartIndex > maxStart then
		pageStartIndex = maxStart
	end
	if pageStartIndex < 1 then
		pageStartIndex = 1
	end

        for button, glyph in pairs(glyphObjects) do
                if glyph then
                        glyph.Visible = false
                end
        end

	for offset, directionInfo in ipairs(DPAD_LAYOUT) do
		local slotIndex = pageStartIndex + offset - 1
		local button = slotButtonsOrdered[slotIndex]
		if button then
			glyphAssignments[button] = offset
			ensureGlyph(button, directionInfo)
		end
	end

	updateGlyphVisibility()
end

local function refreshSlotButtons()
	local frame = quickbarFrame
	if not frame then
		for button in pairs(glyphObjects) do
			clearButtonTracking(button)
		end
		table.clear(slotButtonsOrdered)
		updateGlyphAssignments()
		return
	end

	local newButtons: { GuiButton } = {}
	local presentMap: { [GuiButton]: boolean } = {}

	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("GuiButton") then
			table.insert(newButtons, child)
			presentMap[child] = true
		end
	end

	table.sort(newButtons, function(a: GuiButton, b: GuiButton)
		local orderA = a.LayoutOrder
		local orderB = b.LayoutOrder
		if orderA == orderB then
			return a.Name < b.Name
		end
		return orderA < orderB
	end)

	for button in pairs(glyphObjects) do
		if not presentMap[button] then
			clearButtonTracking(button)
		end
	end

	for _, button in ipairs(newButtons) do
                if buttonCleanupConnections[button] == nil then
                        buttonCleanupConnections[button] = button.Destroying:Connect(function()
                                clearButtonTracking(button)
                                updateGlyphVisibility()
                        end)
                end
	end

	slotButtonsOrdered = newButtons
	updateGlyphAssignments()
end

local function setQuickbarFrame(frame: Frame?)
	if quickbarFrame == frame then
		return
	end

	for _, conn in ipairs(quickbarConnections) do
		conn:Disconnect()
	end
	table.clear(quickbarConnections)

	quickbarFrame = frame

	if not frame then
		refreshSlotButtons()
		return
	end

	table.insert(quickbarConnections, frame.ChildAdded:Connect(function(child)
		if child:IsA("GuiButton") then
			task.defer(refreshSlotButtons)
		end
	end))
	table.insert(quickbarConnections, frame.ChildRemoved:Connect(function(child)
		if child:IsA("GuiButton") then
			task.defer(refreshSlotButtons)
		end
	end))
	table.insert(quickbarConnections, frame.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			setQuickbarFrame(nil)
		end
	end))

	refreshSlotButtons()
end

local function tryAttachQuickbar()
	local gui = playerGui:FindFirstChild(quickbarGuiName)
	if gui and gui:IsA("ScreenGui") then
		local container = gui:FindFirstChild(quickbarContainerName)
		if container and container:IsA("Frame") then
			setQuickbarFrame(container)
			return
		end
	end
	setQuickbarFrame(nil)
end

local function setGamepadPreferred(preferred: boolean)
	if gamepadPreferred ~= preferred then
		gamepadPreferred = preferred
	end
	updateGlyphVisibility()
end

local function activateSlot(slotIndex: number): boolean
	if slotIndex < 1 or slotIndex > #slotDefinitions then
		return false
	end

	if not shouldAllowQuickbarInput() then
		return false
	end

	local button = slotButtonsOrdered[slotIndex]
	if not button then
		return false
	end

	local isActiveValue = button.Active
	local isActive = if typeof(isActiveValue) == "boolean" then isActiveValue else true
	if not isActive then
		return false
	end

	local ok, err = pcall(function()
		(button :: any):Activate()
	end)

	if ok then
		return true
	end

	local definition = slotDefinitions[slotIndex]
	if definition and definition.kind == "token" then
		return requestUseToken(definition.index)
	end

	warn(string.format("[ControllerSupport] Failed to activate quickbar slot %d: %s", slotIndex, tostring(err)))
	return false
end

local function cycleSlots(delta: number): boolean
	local totalSlots = #slotButtonsOrdered
	if totalSlots == 0 then
		return false
	end

	if not shouldAllowQuickbarInput() then
		return false
	end

	local dpadCount = #DPAD_LAYOUT
	local maxStart = math.max(totalSlots - (dpadCount - 1), 1)
	if maxStart <= 1 then
		return false
	end

	local newStart = pageStartIndex + delta
	if newStart < 1 then
		newStart = maxStart
	elseif newStart > maxStart then
		newStart = 1
	end

	if newStart == pageStartIndex then
		return false
	end

	pageStartIndex = newStart
	updateGlyphAssignments()
	return true
end

local function useFirstAvailableToken(): boolean
	if not shouldAllowQuickbarInput() then
		return false
	end

	for slotIndex, definition in ipairs(slotDefinitions) do
		if definition.kind == "token" then
			local button = slotButtonsOrdered[slotIndex]
			if button then
				local isActiveValue = button.Active
				local isActive = if typeof(isActiveValue) == "boolean" then isActiveValue else true
				if isActive then
					if activateSlot(slotIndex) then
						return true
					end
				end
			end
		end
	end
	return false
end

local function bindAction(
        name: string,
        handler: (string, Enum.UserInputState, InputObject?) -> Enum.ContextActionResult,
        ...: BindActionInput
)
        ContextActionService:UnbindAction(name)
        ContextActionService:BindAction(name, handler, false, ...)
        table.insert(boundActions, name)
end

for _, conn in ipairs(connections) do
	conn:Disconnect()
end

connections = {
        playerGui.ChildAdded:Connect(function(child: Instance)
                if child.Name == quickbarGuiName then
                        task.defer(tryAttachQuickbar)
                end
        end),
        playerGui.ChildRemoved:Connect(function(child: Instance)
                if child.Name == quickbarGuiName then
                        setQuickbarFrame(nil)
                end
        end),
        UserInputService.LastInputTypeChanged:Connect(function(newType: Enum.UserInputType)
                if isGamepadInputType(newType) then
                        setGamepadPreferred(true)
                elseif not UserInputService.GamepadEnabled then
                        setGamepadPreferred(false)
                end
        end),
        UserInputService.GamepadConnected:Connect(function(_gamepad: Enum.UserInputType)
                setGamepadPreferred(true)
        end),
        UserInputService.GamepadDisconnected:Connect(function(_gamepad: Enum.UserInputType)
                if not UserInputService.GamepadEnabled then
                        setGamepadPreferred(false)
                else
                        setGamepadPreferred(isGamepadInputType(UserInputService:GetLastInputType()))
                end
	end),
	GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(function()
		updateGlyphVisibility()
	end),
}

do
	local okOpened, signalOpened = pcall(function()
		return GuiService.MenuOpened
	end)
	if okOpened and signalOpened then
		table.insert(connections, (signalOpened :: any):Connect(function()
			menuOpen = true
			updateGlyphVisibility()
		end))
	end

	local okClosed, signalClosed = pcall(function()
		return GuiService.MenuClosed
	end)
	if okClosed and signalClosed then
		table.insert(connections, (signalClosed :: any):Connect(function()
			menuOpen = false
			updateGlyphVisibility()
		end))
	end
end

setGamepadPreferred(gamepadPreferred or UserInputService.GamepadEnabled)

local ACTION_PREFIX = "FruitSmash_ControllerSupport_"

for offset, directionInfo in ipairs(DPAD_LAYOUT) do
	local actionName = ACTION_PREFIX .. "DPad" .. directionInfo.name
	bindAction(actionName, function(_actionName: string, state: Enum.UserInputState)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end

		if not shouldAllowQuickbarInput() then
			return Enum.ContextActionResult.Pass
		end

		local slotIndex = pageStartIndex + offset - 1
		if activateSlot(slotIndex) then
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, directionInfo.keyCode)
end

bindAction(ACTION_PREFIX .. "CyclePrev", function(_actionName: string, state: Enum.UserInputState)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not shouldAllowQuickbarInput() then
		return Enum.ContextActionResult.Pass
	end
	if cycleSlots(-1) then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end, Enum.KeyCode.ButtonL1)

bindAction(ACTION_PREFIX .. "CycleNext", function(_actionName: string, state: Enum.UserInputState)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not shouldAllowQuickbarInput() then
		return Enum.ContextActionResult.Pass
	end
	if cycleSlots(1) then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end, Enum.KeyCode.ButtonR1)

bindAction(ACTION_PREFIX .. "TokenButton", function(_actionName: string, state: Enum.UserInputState)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not shouldAllowQuickbarInput() then
		return Enum.ContextActionResult.Pass
	end
	if useFirstAvailableToken() then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end, Enum.KeyCode.ButtonX)

task.defer(tryAttachQuickbar)

script.Destroying:Connect(function()
	for _, actionName in ipairs(boundActions) do
		ContextActionService:UnbindAction(actionName)
	end
	for _, conn in ipairs(connections) do
		conn:Disconnect()
	end
	for _, conn in ipairs(quickbarConnections) do
		conn:Disconnect()
	end
        for _, conn in pairs(buttonCleanupConnections) do
                if conn then
                        conn:Disconnect()
                end
        end
end)
