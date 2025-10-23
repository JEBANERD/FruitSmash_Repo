--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")

local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local ShopConfigModule = require(configFolder:WaitForChild("ShopConfig"))

local gameConfig = if typeof(GameConfigModule.Get) == "function" then GameConfigModule.Get() else GameConfigModule
local uiConfig = gameConfig.UI or {}

if uiConfig.UseQuickbar == false then
	return
end

local quickbarConfig = uiConfig.Quickbar or {}

local meleeSlotCount = math.clamp(quickbarConfig.MeleeSlots or 2, 0, 2)
local tokenSlotCount = math.clamp(quickbarConfig.TokenSlots or 3, 0, 3)

if meleeSlotCount + tokenSlotCount <= 0 then
	return
end

type SlotKind = "melee" | "token"

type SlotDefinition = {
	kind: SlotKind,
	index: number,
}

type QuickbarMeleeEntry = {
	Id: string,
	Active: boolean?,
}

type QuickbarTokenEntry = {
	Id: string,
	Count: number?,
	StackLimit: number?,
}

type QuickbarState = {
	melee: { QuickbarMeleeEntry? }?,
	tokens: { QuickbarTokenEntry? }?,
	coins: number?,
}

local shopItems = if typeof(ShopConfigModule.All) == "function" then ShopConfigModule.All() else ShopConfigModule.Items or {}

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local quickbarUpdateRemote = remotesFolder:WaitForChild("RE_QuickbarUpdate") :: RemoteEvent
local useTokenRemote = remotesFolder:WaitForChild("RF_UseToken") :: RemoteFunction

local slotDefinitions: { SlotDefinition } = {}
local slotIndexByKind = {
	melee = {} :: { [number]: number },
	token = {} :: { [number]: number },
}

for index = 1, meleeSlotCount do
	local definition: SlotDefinition = { kind = "melee", index = index }
	table.insert(slotDefinitions, definition)
	slotIndexByKind.melee[index] = #slotDefinitions
end

for index = 1, tokenSlotCount do
	local definition: SlotDefinition = { kind = "token", index = index }
	table.insert(slotDefinitions, definition)
	slotIndexByKind.token[index] = #slotDefinitions
end

local totalSlotCount = #slotDefinitions

local KEY_CODES = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
}

local HOTKEY_LABELS = {
	"1",
	"2",
	"3",
	"4",
	"5",
}

type QuickbarPalette = {
        slotEmpty: Color3,
        slotFilled: Color3,
        slotActive: Color3,
        slotUnavailable: Color3,
        slotText: Color3,
        slotDisabledText: Color3,
        frameBackground: Color3,
        frameStroke: Color3,
}

local DEFAULT_PALETTE_ID = "off"

local COLORBLIND_PALETTES: { [string]: QuickbarPalette } = {
        ["off"] = {
                slotEmpty = Color3.fromRGB(28, 28, 32),
                slotFilled = Color3.fromRGB(52, 60, 72),
                slotActive = Color3.fromRGB(72, 132, 255),
                slotUnavailable = Color3.fromRGB(40, 40, 46),
                slotText = Color3.fromRGB(255, 255, 255),
                slotDisabledText = Color3.fromRGB(190, 190, 190),
                frameBackground = Color3.fromRGB(15, 15, 18),
                frameStroke = Color3.fromRGB(255, 255, 255),
        },
        ["deuteranopia"] = {
                slotEmpty = Color3.fromRGB(34, 36, 46),
                slotFilled = Color3.fromRGB(70, 86, 132),
                slotActive = Color3.fromRGB(255, 176, 0),
                slotUnavailable = Color3.fromRGB(50, 54, 70),
                slotText = Color3.fromRGB(255, 255, 255),
                slotDisabledText = Color3.fromRGB(212, 212, 212),
                frameBackground = Color3.fromRGB(18, 20, 30),
                frameStroke = Color3.fromRGB(255, 194, 120),
        },
        ["protanopia"] = {
                slotEmpty = Color3.fromRGB(34, 38, 48),
                slotFilled = Color3.fromRGB(72, 92, 136),
                slotActive = Color3.fromRGB(255, 168, 96),
                slotUnavailable = Color3.fromRGB(52, 58, 74),
                slotText = Color3.fromRGB(255, 255, 255),
                slotDisabledText = Color3.fromRGB(214, 214, 214),
                frameBackground = Color3.fromRGB(20, 22, 32),
                frameStroke = Color3.fromRGB(255, 204, 150),
        },
        ["tritanopia"] = {
                slotEmpty = Color3.fromRGB(34, 34, 48),
                slotFilled = Color3.fromRGB(78, 84, 132),
                slotActive = Color3.fromRGB(210, 120, 210),
                slotUnavailable = Color3.fromRGB(52, 52, 72),
                slotText = Color3.fromRGB(255, 255, 255),
                slotDisabledText = Color3.fromRGB(216, 216, 216),
                frameBackground = Color3.fromRGB(20, 20, 30),
                frameStroke = Color3.fromRGB(214, 168, 214),
        },
}

local activePaletteId: string = DEFAULT_PALETTE_ID
local activePalette: QuickbarPalette = COLORBLIND_PALETTES[DEFAULT_PALETTE_ID]

local quickbarSafeAreaFrame: Frame? = nil
local safeAreaPadding: UIPadding? = nil
local cameraViewportConnection: RBXScriptConnection? = nil
local lastSafeAreaInsets = { left = -1, top = -1, right = -1, bottom = -1 }
local quickbarStroke: UIStroke? = nil

local function resolvePaletteId(candidate: any): string
        if typeof(candidate) ~= "string" then
                return DEFAULT_PALETTE_ID
        end
        local normalized = string.lower(candidate)
        if COLORBLIND_PALETTES[normalized] then
                return normalized
        end
        return DEFAULT_PALETTE_ID
end

local function sanitizeInset(value: number?): number
        if typeof(value) ~= "number" then
                return 0
        end
        return math.max(0, math.floor(value + 0.5))
end

local function computeSafeAreaInsets(): (number, number, number, number)
        local left, top, right, bottom = 0, 0, 0, 0

        local ok, safeTopLeft, safeBottomRight = pcall(function()
                return GuiService:GetSafeZoneOffsets()
        end)
        if ok and typeof(safeTopLeft) == "Vector2" and typeof(safeBottomRight) == "Vector2" then
                left = safeTopLeft.X
                top = safeTopLeft.Y
                right = safeBottomRight.X
                bottom = safeBottomRight.Y
        else
                local insetOk, guiTopLeft, guiBottomRight = pcall(function()
                        return GuiService:GetGuiInset()
                end)
                if insetOk and typeof(guiTopLeft) == "Vector2" and typeof(guiBottomRight) == "Vector2" then
                        left = guiTopLeft.X
                        top = guiTopLeft.Y
                        right = guiBottomRight.X
                        bottom = guiBottomRight.Y
                end
        end

        return sanitizeInset(left), sanitizeInset(top), sanitizeInset(right), sanitizeInset(bottom)
end

local function updateSafeAreaPadding()
        if not safeAreaPadding then
                return
        end

        local left, top, right, bottom = computeSafeAreaInsets()
        if lastSafeAreaInsets.left == left and lastSafeAreaInsets.top == top and lastSafeAreaInsets.right == right and lastSafeAreaInsets.bottom == bottom then
                return
        end

        safeAreaPadding.PaddingLeft = UDim.new(0, left)
        safeAreaPadding.PaddingTop = UDim.new(0, top)
        safeAreaPadding.PaddingRight = UDim.new(0, right)
        safeAreaPadding.PaddingBottom = UDim.new(0, bottom)

        lastSafeAreaInsets.left = left
        lastSafeAreaInsets.top = top
        lastSafeAreaInsets.right = right
        lastSafeAreaInsets.bottom = bottom
end

local function updateCameraViewportConnection(camera: Camera?)
        if cameraViewportConnection then
                cameraViewportConnection:Disconnect()
                cameraViewportConnection = nil
        end
        if camera then
                cameraViewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateSafeAreaPadding)
        end
end

local slotButtons: { [number]: TextButton } = {}
local slotHotkeyLabels: { [number]: string } = {}
local slotActionNames: { [number]: string } = {}
local connections: { RBXScriptConnection } = {}

local currentMelee: { [number]: QuickbarMeleeEntry? } = {}
local currentTokens: { [number]: QuickbarTokenEntry? } = {}

local quickbarGuiName = "QuickbarHUD"
local existingGui = playerGui:FindFirstChild(quickbarGuiName)
if existingGui and existingGui:IsA("ScreenGui") then
	existingGui:Destroy()
end

local quickbarScreenGui = Instance.new("ScreenGui")
quickbarScreenGui.Name = quickbarGuiName
quickbarScreenGui.IgnoreGuiInset = true
quickbarScreenGui.ResetOnSpawn = false
quickbarScreenGui.DisplayOrder = 5
quickbarScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
quickbarScreenGui.Parent = playerGui

quickbarSafeAreaFrame = Instance.new("Frame")
quickbarSafeAreaFrame.Name = "SafeArea"
quickbarSafeAreaFrame.Size = UDim2.new(1, 0, 1, 0)
quickbarSafeAreaFrame.BackgroundTransparency = 1
quickbarSafeAreaFrame.BorderSizePixel = 0
quickbarSafeAreaFrame.Parent = quickbarScreenGui

safeAreaPadding = Instance.new("UIPadding")
safeAreaPadding.Name = "SafeAreaPadding"
safeAreaPadding.Parent = quickbarSafeAreaFrame

local buttonWidth = if UserInputService.TouchEnabled then 140 else 120
local buttonHeight = if UserInputService.TouchEnabled then 108 else 84
local slotPadding = if UserInputService.TouchEnabled then 12 else 10
local frameWidth = totalSlotCount * buttonWidth + math.max(totalSlotCount - 1, 0) * slotPadding + 24
local frameHeight = buttonHeight + 28

local quickbarFrame = Instance.new("Frame")
quickbarFrame.Name = "QuickbarContainer"
quickbarFrame.AnchorPoint = Vector2.new(0.5, 1)
quickbarFrame.Position = UDim2.new(0.5, 0, 1, -24)
quickbarFrame.Size = UDim2.new(0, frameWidth, 0, frameHeight)
quickbarFrame.BackgroundColor3 = activePalette.frameBackground
quickbarFrame.BackgroundTransparency = 0.2
quickbarFrame.BorderSizePixel = 0
quickbarFrame.Parent = quickbarSafeAreaFrame

local quickbarCorner = Instance.new("UICorner")
quickbarCorner.CornerRadius = UDim.new(0, 12)
quickbarCorner.Parent = quickbarFrame

quickbarStroke = Instance.new("UIStroke")
quickbarStroke.Thickness = 1
quickbarStroke.Transparency = 0.85
quickbarStroke.Color = activePalette.frameStroke
quickbarStroke.Parent = quickbarFrame

local framePadding = Instance.new("UIPadding")
framePadding.PaddingBottom = UDim.new(0, 12)
framePadding.PaddingTop = UDim.new(0, 12)
framePadding.PaddingLeft = UDim.new(0, 12)
framePadding.PaddingRight = UDim.new(0, 12)
framePadding.Parent = quickbarFrame

local listLayout = Instance.new("UIListLayout")
listLayout.Name = "SlotLayout"
listLayout.FillDirection = Enum.FillDirection.Horizontal
listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
listLayout.Padding = UDim.new(0, slotPadding)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = quickbarFrame

updateSafeAreaPadding()
updateCameraViewportConnection(Workspace.CurrentCamera)

local okSafeZone, safeZoneSignal = pcall(function()
        return GuiService:GetPropertyChangedSignal("SafeZoneOffsets")
end)
if okSafeZone and typeof(safeZoneSignal) == "RBXScriptSignal" then
        table.insert(connections, (safeZoneSignal :: RBXScriptSignal):Connect(updateSafeAreaPadding))
end

local okInset, insetSignal = pcall(function()
        return GuiService:GetPropertyChangedSignal("GuiInset")
end)
if okInset and typeof(insetSignal) == "RBXScriptSignal" then
        table.insert(connections, (insetSignal :: RBXScriptSignal):Connect(updateSafeAreaPadding))
end

table.insert(connections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        updateCameraViewportConnection(Workspace.CurrentCamera)
        updateSafeAreaPadding()
end))

local function getItemDisplayName(itemId: string): string
	local itemInfo = if typeof(shopItems) == "table" then shopItems[itemId] else nil
	if typeof(itemInfo) == "table" then
		local nameValue = itemInfo.Name
		if typeof(nameValue) == "string" and nameValue ~= "" then
			return nameValue
		end
		local idValue = itemInfo.Id
		if typeof(idValue) == "string" and idValue ~= "" then
			return idValue
		end
	end
	return itemId
end

local function updateContextActionTitle(slotOrderIndex: number, title: string)
	local actionName = slotActionNames[slotOrderIndex]
	if actionName then
		ContextActionService:SetTitle(actionName, title)
	end
end

local function setSlotVisual(slotOrderIndex: number, entry: QuickbarMeleeEntry | QuickbarTokenEntry | nil, kind: SlotKind)
        local button = slotButtons[slotOrderIndex]
        if not button then
                return
        end

        local hotkeyLabel = slotHotkeyLabels[slotOrderIndex] or tostring(slotOrderIndex)
        local headerText = string.format("[%s]", hotkeyLabel)
        local palette = activePalette

        if entry == nil then
                button.Text = if kind == "token"
                        then string.format("%s\n%s", headerText, "No Token")
                        else string.format("%s\n%s", headerText, "No Melee")
                button.BackgroundColor3 = palette.slotEmpty
                button.TextColor3 = palette.slotDisabledText
                button.TextTransparency = 0.35
                button.AutoButtonColor = false
                button.Active = false
                updateContextActionTitle(slotOrderIndex, string.format("Slot %s", hotkeyLabel))
                return
        end

        button.TextColor3 = palette.slotText
        button.TextTransparency = 0

        if kind == "token" then
                local tokenEntry = entry :: QuickbarTokenEntry
                local countValue = if typeof(tokenEntry.Count) == "number" then tokenEntry.Count else 0
                local limitValue = if typeof(tokenEntry.StackLimit) == "number" then tokenEntry.StackLimit else nil
                local displayName = getItemDisplayName(tokenEntry.Id)
                local countText = if limitValue and limitValue > 0 then string.format("%d/%d", countValue, limitValue) else string.format("x%d", countValue)

                button.Text = string.format("%s\n%s\n%s", headerText, displayName, countText)
                if countValue <= 0 then
                        button.BackgroundColor3 = palette.slotUnavailable
                        button.TextColor3 = palette.slotDisabledText
                        button.TextTransparency = 0.35
                        button.AutoButtonColor = false
                        button.Active = false
                else
                        button.BackgroundColor3 = palette.slotFilled
                        button.AutoButtonColor = true
                        button.Active = true
                end
                updateContextActionTitle(slotOrderIndex, string.format("%s (%s)", hotkeyLabel, displayName))
        else
                local meleeEntry = entry :: QuickbarMeleeEntry
                local displayName = getItemDisplayName(meleeEntry.Id)
                local statusText = if meleeEntry.Active then "Equipped" else "Ready"

                button.Text = string.format("%s\n%s\n%s", headerText, displayName, statusText)
                button.BackgroundColor3 = meleeEntry.Active and palette.slotActive or palette.slotFilled
                button.AutoButtonColor = true
                button.Active = true
                updateContextActionTitle(slotOrderIndex, string.format("%s (%s)", hotkeyLabel, statusText))
        end
end

local function refreshQuickbarSlots()
        for orderIndex, definition in ipairs(slotDefinitions) do
                if definition.kind == "token" then
                        setSlotVisual(orderIndex, currentTokens[definition.index], "token")
                else
                        setSlotVisual(orderIndex, currentMelee[definition.index], "melee")
                end
        end
end

local function applyQuickbarPalette(paletteId: any, force: boolean?)
        local normalized = resolvePaletteId(paletteId)
        if force or activePaletteId ~= normalized then
                activePaletteId = normalized
                activePalette = COLORBLIND_PALETTES[normalized] or COLORBLIND_PALETTES[DEFAULT_PALETTE_ID]
        end

        if quickbarFrame then
                quickbarFrame.BackgroundColor3 = activePalette.frameBackground
        end
        if quickbarStroke then
                quickbarStroke.Color = activePalette.frameStroke
        end

        refreshQuickbarSlots()
end

local missingTokenRemoteWarned = false

local function requestUseToken(slotIndex: number)
	local remote = useTokenRemote
	if not remote then
		if not missingTokenRemoteWarned then
			missingTokenRemoteWarned = true
			warn("[QuickbarController] RF_UseToken remote is unavailable; cannot use tokens.")
		end
		return
	end

	local success, err = pcall(function()
		remote:InvokeServer(slotIndex)
	end)

	if not success then
		warn(string.format("[QuickbarController] Failed to invoke RF_UseToken for slot %d: %s", slotIndex, tostring(err)))
	end
end

local function onSlotActivated(slotOrderIndex: number)
	local definition = slotDefinitions[slotOrderIndex]
	if not definition then
		return
	end

	if definition.kind == "token" then
		local entry = currentTokens[definition.index]
		if not entry then
			return
		end

		local countValue = if typeof(entry.Count) == "number" then entry.Count else 0
		if countValue <= 0 then
			return
		end

		requestUseToken(definition.index)
	end
end

local function createSlotButton(slotOrderIndex: number, definition: SlotDefinition)
	local button = Instance.new("TextButton")
        button.Name = string.format("%sSlot%d", definition.kind == "token" and "Token" or "Melee", definition.index)
        button.LayoutOrder = slotOrderIndex
        button.Size = UDim2.new(0, buttonWidth, 0, buttonHeight)
        button.BackgroundColor3 = activePalette.slotEmpty
        button.AutoButtonColor = false
        button.BorderSizePixel = 0
        button.Text = ""
        button.TextColor3 = activePalette.slotText
        button.TextSize = 18
        button.TextWrapped = true
        button.TextYAlignment = Enum.TextYAlignment.Center
        button.LineHeight = 1.05
        button.Font = Enum.Font.GothamMedium
        button.RichText = false
        button.ZIndex = 2
        button:SetAttribute("FS_BaseTextSize", 18)
        button.Parent = quickbarFrame

	slotButtons[slotOrderIndex] = button
	slotHotkeyLabels[slotOrderIndex] = HOTKEY_LABELS[slotOrderIndex] or tostring(slotOrderIndex)

	local actionName = string.format("QuickbarSlot%d", slotOrderIndex)
	slotActionNames[slotOrderIndex] = actionName

	local keyCode = KEY_CODES[slotOrderIndex]
	local function actionHandler(_: string, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then
			onSlotActivated(slotOrderIndex)
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end

	if keyCode then
		ContextActionService:BindAction(actionName, actionHandler, true, keyCode)
	else
		ContextActionService:BindAction(actionName, actionHandler, true)
	end
	ContextActionService:SetButton(actionName, button)
	ContextActionService:SetTitle(actionName, string.format("Slot %s", slotHotkeyLabels[slotOrderIndex]))

	local connection = button:GetPropertyChangedSignal("Parent"):Connect(function()
		if button.Parent == nil then
			ContextActionService:UnbindAction(actionName)
		end
	end)
	table.insert(connections, connection)

	return button
end

for orderIndex, definition in ipairs(slotDefinitions) do
        createSlotButton(orderIndex, definition)
end

applyQuickbarPalette(localPlayer:GetAttribute("ColorblindPalette"), true)

local function applyQuickbarState(rawState: QuickbarState?)
        if typeof(rawState) ~= "table" then
                for orderIndex, definition in ipairs(slotDefinitions) do
                        setSlotVisual(orderIndex, nil, definition.kind)
                end
		return
	end

	table.clear(currentMelee)
	table.clear(currentTokens)

	local meleeEntriesRaw = rawState.melee
	if typeof(meleeEntriesRaw) == "table" then
		for index = 1, meleeSlotCount do
			local entry = meleeEntriesRaw[index]
			if typeof(entry) == "table" and typeof(entry.Id) == "string" then
				local sanitized: QuickbarMeleeEntry = {
					Id = entry.Id,
					Active = entry.Active == true,
				}
				currentMelee[index] = sanitized
			else
				currentMelee[index] = nil
			end
		end
	end

	local tokenEntriesRaw = rawState.tokens
	if typeof(tokenEntriesRaw) == "table" then
		for index = 1, tokenSlotCount do
			local entry = tokenEntriesRaw[index]
			if typeof(entry) == "table" and typeof(entry.Id) == "string" then
				local countValue = if typeof(entry.Count) == "number" then entry.Count else 0
				local limitValue = if typeof(entry.StackLimit) == "number" then entry.StackLimit else nil
				local sanitized: QuickbarTokenEntry = {
					Id = entry.Id,
					Count = countValue,
					StackLimit = limitValue,
				}
				currentTokens[index] = sanitized
			else
				currentTokens[index] = nil
			end
		end
	end

	for index = 1, meleeSlotCount do
		local orderIndex = slotIndexByKind.melee[index]
		if orderIndex then
			setSlotVisual(orderIndex, currentMelee[index], "melee")
		end
	end

	for index = 1, tokenSlotCount do
		local orderIndex = slotIndexByKind.token[index]
		if orderIndex then
			setSlotVisual(orderIndex, currentTokens[index], "token")
		end
	end
end

applyQuickbarState(nil)

local quickbarConnection = quickbarUpdateRemote.OnClientEvent:Connect(function(state: QuickbarState)
        applyQuickbarState(state)
end)
table.insert(connections, quickbarConnection)

table.insert(connections, localPlayer.AttributeChanged:Connect(function(name)
        if name == "ColorblindPalette" then
                applyQuickbarPalette(localPlayer:GetAttribute("ColorblindPalette"), false)
        end
end))

script.Destroying:Connect(function()
        for _, actionName in pairs(slotActionNames) do
                ContextActionService:UnbindAction(actionName)
        end
        for _, connection in ipairs(connections) do
                connection:Disconnect()
        end
        if cameraViewportConnection then
                cameraViewportConnection:Disconnect()
                cameraViewportConnection = nil
        end
        safeAreaPadding = nil
        quickbarSafeAreaFrame = nil
        quickbarStroke = nil
        lastSafeAreaInsets = { left = -1, top = -1, right = -1, bottom = -1 }
end)
