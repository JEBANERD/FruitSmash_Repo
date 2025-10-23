--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Lighting = game:GetService("Lighting")

local localPlayer: Player = Players.LocalPlayer
local playerGui: PlayerGui = localPlayer:WaitForChild("PlayerGui")

local remotesModule = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))
local saveRemote: RemoteFunction? = remotesModule and remotesModule.RF_SaveSettings or nil
local pushRemote: RemoteEvent? = remotesModule and remotesModule.RE_SettingsPushed or nil
local tutorialRemote: RemoteFunction? = remotesModule and remotesModule.RF_Tutorial or nil

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = if typeof((GameConfigModule :: any).Get) == "function" then (GameConfigModule :: any).Get() else GameConfigModule

local playerSection = if typeof(GameConfig) == "table" then (GameConfig :: any).Player else nil
local settingsConfig = if typeof(playerSection) == "table" then (playerSection :: any).Settings else nil
local defaultsConfig = if typeof(settingsConfig) == "table" then (settingsConfig :: any).Defaults else nil
local limitsConfig = if typeof(settingsConfig) == "table" then (settingsConfig :: any).Limits else nil
local palettesConfig = if typeof(settingsConfig) == "table" then (settingsConfig :: any).ColorblindPalettes else nil

local paletteOrder: {{[string]: any}} = {}
local paletteLookup: {[string]: any} = {}
local paletteIndexLookup: {[string]: number} = {}

if typeof(palettesConfig) == "table" then
  for _, entry in ipairs(palettesConfig) do
    if typeof(entry) == "table" then
      local idValue = (entry :: any).Id or (entry :: any).id or (entry :: any).Name or (entry :: any).name
      if typeof(idValue) == "string" and idValue ~= "" then
        local record = {
          Id = idValue,
          Name = typeof((entry :: any).Name) == "string" and (entry :: any).Name or idValue,
          TintColor = (entry :: any).TintColor,
          Saturation = typeof((entry :: any).Saturation) == "number" and (entry :: any).Saturation or 0,
          Contrast = typeof((entry :: any).Contrast) == "number" and (entry :: any).Contrast or 0,
          Brightness = typeof((entry :: any).Brightness) == "number" and (entry :: any).Brightness or 0,
        }
        table.insert(paletteOrder, record)
        paletteLookup[idValue] = record
        paletteLookup[string.lower(idValue)] = record
        paletteIndexLookup[idValue] = #paletteOrder
      end
    end
  end
end

if #paletteOrder == 0 then
  local fallback = {
    Id = "Off",
    Name = "Off",
    TintColor = Color3.new(1, 1, 1),
    Saturation = 0,
    Contrast = 0,
    Brightness = 0,
  }
  table.insert(paletteOrder, fallback)
  paletteLookup[fallback.Id] = fallback
  paletteLookup[string.lower(fallback.Id)] = fallback
  paletteIndexLookup[fallback.Id] = 1
end

local function resolvePaletteId(value: any): string
  if typeof(value) == "string" and value ~= "" then
    local direct = paletteLookup[value]
    if direct then
      return direct.Id
    end
    local lowered = string.lower(value)
    local lowerEntry = paletteLookup[lowered]
    if lowerEntry then
      return lowerEntry.Id
    end
  end
  return paletteOrder[1].Id
end

local function clampValue(key: string, value: any, fallback: number): number
  local numeric = if typeof(value) == "number" then value else tonumber(value)
  if typeof(numeric) ~= "number" then
    numeric = fallback
  end
  if typeof(limitsConfig) == "table" then
    local limit = (limitsConfig :: any)[key]
    if typeof(limit) == "table" then
      local minValue = (limit :: any).Min
      local maxValue = (limit :: any).Max
      local minNumeric = if typeof(minValue) == "number" then minValue else tonumber(minValue)
      local maxNumeric = if typeof(maxValue) == "number" then maxValue else tonumber(maxValue)
      if typeof(minNumeric) == "number" then
        numeric = math.max(minNumeric, numeric)
      end
      if typeof(maxNumeric) == "number" then
        numeric = math.min(maxNumeric, numeric)
      end
    end
  end
  return numeric
end

local DEFAULT_SETTINGS = {
  SprintToggle = typeof(defaultsConfig) == "table" and (defaultsConfig :: any).SprintToggle == true or false,
  AimAssistWindow = clampValue("AimAssistWindow", typeof(defaultsConfig) == "table" and (defaultsConfig :: any).AimAssistWindow or 0.75, 0.75),
  CameraShakeStrength = clampValue("CameraShakeStrength", typeof(defaultsConfig) == "table" and (defaultsConfig :: any).CameraShakeStrength or 0.7, 0.7),
  ColorblindPalette = resolvePaletteId(typeof(defaultsConfig) == "table" and (defaultsConfig :: any).ColorblindPalette or nil),
  TextScale = clampValue("TextScale", typeof(defaultsConfig) == "table" and (defaultsConfig :: any).TextScale or 1, 1),
}

local currentSettings = {
  SprintToggle = DEFAULT_SETTINGS.SprintToggle,
  AimAssistWindow = DEFAULT_SETTINGS.AimAssistWindow,
  CameraShakeStrength = DEFAULT_SETTINGS.CameraShakeStrength,
  ColorblindPalette = DEFAULT_SETTINGS.ColorblindPalette,
  TextScale = DEFAULT_SETTINGS.TextScale,
}

local COLOR_CORRECTION_NAME = "FruitSmash_Colorblind"
local colorCorrection = Lighting:FindFirstChild(COLOR_CORRECTION_NAME)
if not colorCorrection then
  colorCorrection = Instance.new("ColorCorrectionEffect")
  colorCorrection.Name = COLOR_CORRECTION_NAME
  colorCorrection.Enabled = false
  colorCorrection.Parent = Lighting
end

local currentTextScale = currentSettings.TextScale or 1
local trackedTextConnections: {RBXScriptConnection} = {}
local controllerConnections: {RBXScriptConnection} = {}
local focusOrder: {GuiObject} = {}
local focusCleanupConnections: {[GuiObject]: RBXScriptConnection} = {}
local toggleButton: TextButton? = nil
local mainFrame: Frame? = nil
local panelVisible = false

local ACTION_TOGGLE_SETTINGS = "FruitSmash_Settings_Toggle"

local function trackControllerConnection(connection: RBXScriptConnection)
  table.insert(controllerConnections, connection)
end

local function isGamepadInputType(inputType: Enum.UserInputType): boolean
  if inputType == Enum.UserInputType.Gamepad then
    return true
  end
  local name = tostring(inputType)
  return string.find(name, "Gamepad") ~= nil
end

local function cleanupFocusable(object: GuiObject)
  local connection = focusCleanupConnections[object]
  if connection then
    connection:Disconnect()
    focusCleanupConnections[object] = nil
  end
  for index, entry in ipairs(focusOrder) do
    if entry == object then
      table.remove(focusOrder, index)
      break
    end
  end
end

local function rebuildFocusChain()
  if toggleButton then
    if panelVisible and toggleButton.Parent then
      toggleButton.NextSelectionUp = nil
    else
      toggleButton.NextSelectionDown = nil
      toggleButton.NextSelectionUp = nil
    end
  end

  local previous: GuiObject? = if panelVisible and toggleButton and toggleButton.Parent then toggleButton else nil

  for _, object in ipairs(focusOrder) do
    local withinPanel = object.Parent and (not mainFrame or object:IsDescendantOf(mainFrame))
    if panelVisible and withinPanel and object.Visible ~= false and (not object:IsA("GuiButton") or object.Active ~= false) then
      if previous then
        previous.NextSelectionDown = object
      end
      object.NextSelectionUp = previous
      previous = object
    else
      object.NextSelectionUp = nil
      object.NextSelectionDown = nil
    end
  end

  if panelVisible and previous and previous ~= toggleButton then
    previous.NextSelectionDown = nil
  end
end

local function registerFocusable(object: GuiObject)
  for _, entry in ipairs(focusOrder) do
    if entry == object then
      return
    end
  end

  object.Selectable = true
  focusCleanupConnections[object] = object.AncestryChanged:Connect(function(_, parent)
    if parent == nil then
      cleanupFocusable(object)
      rebuildFocusChain()
    end
  end)
  table.insert(focusOrder, object)
  rebuildFocusChain()
end

local gamepadPreferred = isGamepadInputType(UserInputService:GetLastInputType())

local function focusFirstControl()
  if not gamepadPreferred then
    return
  end

  if panelVisible then
    for _, object in ipairs(focusOrder) do
      if object.Parent and object.Visible ~= false then
        GuiService.SelectedObject = object
        return
      end
    end
  end

  if toggleButton and toggleButton.Parent then
    GuiService.SelectedObject = toggleButton
  end
end

local function setGamepadPreferred(preferred: boolean)
  if gamepadPreferred == preferred then
    return
  end

  gamepadPreferred = preferred
  if not gamepadPreferred then
    local selected = GuiService.SelectedObject
    if selected and ((toggleButton and selected == toggleButton) or (mainFrame and selected:IsDescendantOf(mainFrame))) then
      GuiService.SelectedObject = nil
    end
    return
  end

  focusFirstControl()
end

local function applyScaleToTextObject(instance: Instance)
  if not instance:IsA("TextLabel") and not instance:IsA("TextButton") and not instance:IsA("TextBox") then
    return
  end
  if instance.TextScaled then
    return
  end
  local baseSize = instance:GetAttribute("FS_BaseTextSize")
  if typeof(baseSize) ~= "number" then
    baseSize = instance.TextSize
    instance:SetAttribute("FS_BaseTextSize", baseSize)
  end
  local scaled = math.floor(math.clamp(baseSize * currentTextScale, 8, 72) + 0.5)
  instance.TextSize = scaled
end

local function disconnectTextObservers()
  for _, connection in ipairs(trackedTextConnections) do
    connection:Disconnect()
  end
  table.clear(trackedTextConnections)
end

local function observeGuiText(container: Instance?)
  if not container then
    return
  end
  for _, descendant in ipairs(container:GetDescendants()) do
    applyScaleToTextObject(descendant)
  end
  local connection = container.DescendantAdded:Connect(function(descendant)
    applyScaleToTextObject(descendant)
  end)
  table.insert(trackedTextConnections, connection)
end

disconnectTextObservers()
observeGuiText(playerGui)

localPlayer.ChildAdded:Connect(function(child)
  if child:IsA("PlayerGui") then
    disconnectTextObservers()
    observeGuiText(child)
    playerGui = child
  end
end)

localPlayer.ChildRemoved:Connect(function(child)
  if child:IsA("PlayerGui") then
    task.defer(function()
      local replacement = localPlayer:FindFirstChildOfClass("PlayerGui")
      playerGui = replacement or playerGui
      disconnectTextObservers()
      observeGuiText(replacement)
    end)
  end
end)

local function applyColorblindPalette(paletteId: string)
  local entry = paletteLookup[paletteId] or paletteLookup[string.lower(paletteId)]
  if not entry then
    colorCorrection.Enabled = false
    return
  end
  if string.lower(entry.Id) == "off" then
    colorCorrection.Enabled = false
    return
  end
  colorCorrection.Enabled = true
  colorCorrection.TintColor = entry.TintColor or Color3.new(1, 1, 1)
  colorCorrection.Saturation = typeof(entry.Saturation) == "number" and entry.Saturation or 0
  colorCorrection.Contrast = typeof(entry.Contrast) == "number" and entry.Contrast or 0
  colorCorrection.Brightness = typeof(entry.Brightness) == "number" and entry.Brightness or 0
end

local function refreshAllText()
  if playerGui then
    for _, descendant in ipairs(playerGui:GetDescendants()) do
      applyScaleToTextObject(descendant)
    end
  end
end

local sprintToggleButton: TextButton? = nil
local aimAssistSliderSet: ((number) -> ())? = nil
local cameraShakeSliderSet: ((number) -> ())? = nil
local textScaleSliderSet: ((number) -> ())? = nil
local paletteValueLabel: TextLabel? = nil

local pendingSave = false

local function scheduleSave()
  if pendingSave or not saveRemote then
    return
  end
  pendingSave = true
  task.delay(0.25, function()
    pendingSave = false
    if not saveRemote then
      return
    end
    local payload = {
      SprintToggle = currentSettings.SprintToggle,
      AimAssistWindow = currentSettings.AimAssistWindow,
      CameraShakeStrength = currentSettings.CameraShakeStrength,
      ColorblindPalette = currentSettings.ColorblindPalette,
      TextScale = currentSettings.TextScale,
    }
    local ok, result = pcall(function()
      return saveRemote:InvokeServer(payload)
    end)
    if ok and typeof(result) == "table" then
      currentSettings.SprintToggle = result.SprintToggle == true
      currentSettings.AimAssistWindow = clampValue("AimAssistWindow", result.AimAssistWindow, currentSettings.AimAssistWindow)
      currentSettings.CameraShakeStrength = clampValue("CameraShakeStrength", result.CameraShakeStrength, currentSettings.CameraShakeStrength)
      currentSettings.ColorblindPalette = resolvePaletteId(result.ColorblindPalette)
      currentSettings.TextScale = clampValue("TextScale", result.TextScale, currentSettings.TextScale)
    end
  end)
end

local function updateSprintToggleUI()
  if not sprintToggleButton then
    return
  end
  sprintToggleButton.Text = if currentSettings.SprintToggle then "Toggle to Sprint" else "Hold to Sprint"
  sprintToggleButton.BackgroundColor3 = if currentSettings.SprintToggle then Color3.fromRGB(72, 128, 255) else Color3.fromRGB(60, 60, 72)
end

local function updatePaletteUI()
  if not paletteValueLabel then
    return
  end
  local palette = paletteLookup[currentSettings.ColorblindPalette] or paletteLookup[string.lower(currentSettings.ColorblindPalette)]
  local displayName = if palette and typeof(palette.Name) == "string" then palette.Name else currentSettings.ColorblindPalette
  paletteValueLabel.Text = string.format("Colorblind Palette: %s", displayName)
end

local function applySetting(key: string, value: any, skipSave: boolean?)
  if key == "SprintToggle" then
    local newValue = value == true
    if currentSettings.SprintToggle ~= newValue then
      currentSettings.SprintToggle = newValue
      localPlayer:SetAttribute("SprintToggle", newValue)
      updateSprintToggleUI()
      if not skipSave then scheduleSave() end
    else
      updateSprintToggleUI()
    end
    return
  elseif key == "AimAssistWindow" then
    local newValue = clampValue("AimAssistWindow", value, currentSettings.AimAssistWindow)
    if currentSettings.AimAssistWindow ~= newValue then
      currentSettings.AimAssistWindow = newValue
      localPlayer:SetAttribute("AimAssistWindow", newValue)
      if aimAssistSliderSet then aimAssistSliderSet(newValue) end
      if not skipSave then scheduleSave() end
    elseif aimAssistSliderSet then
      aimAssistSliderSet(newValue)
    end
    return
  elseif key == "CameraShakeStrength" then
    local newValue = clampValue("CameraShakeStrength", value, currentSettings.CameraShakeStrength)
    if currentSettings.CameraShakeStrength ~= newValue then
      currentSettings.CameraShakeStrength = newValue
      localPlayer:SetAttribute("CameraShakeStrength", newValue)
      if cameraShakeSliderSet then cameraShakeSliderSet(newValue) end
      if not skipSave then scheduleSave() end
    elseif cameraShakeSliderSet then
      cameraShakeSliderSet(newValue)
    end
    return
  elseif key == "ColorblindPalette" then
    local newId = resolvePaletteId(value)
    if currentSettings.ColorblindPalette ~= newId then
      currentSettings.ColorblindPalette = newId
      localPlayer:SetAttribute("ColorblindPalette", newId)
      applyColorblindPalette(newId)
      updatePaletteUI()
      if not skipSave then scheduleSave() end
    else
      updatePaletteUI()
    end
    return
  elseif key == "TextScale" then
    local newValue = clampValue("TextScale", value, currentSettings.TextScale)
    if currentSettings.TextScale ~= newValue then
      currentSettings.TextScale = newValue
      currentTextScale = newValue
      localPlayer:SetAttribute("TextScale", newValue)
      refreshAllText()
      if textScaleSliderSet then textScaleSliderSet(newValue) end
      if not skipSave then scheduleSave() end
    elseif textScaleSliderSet then
      textScaleSliderSet(newValue)
    end
    return
  end
end

local function applySettings(settingsTable: any, skipSave: boolean?)
  if typeof(settingsTable) ~= "table" then
    return
  end
  applySetting("SprintToggle", settingsTable.SprintToggle, true)
  applySetting("AimAssistWindow", settingsTable.AimAssistWindow, true)
  applySetting("CameraShakeStrength", settingsTable.CameraShakeStrength, true)
  applySetting("ColorblindPalette", settingsTable.ColorblindPalette, true)
  applySetting("TextScale", settingsTable.TextScale, true)
  if not skipSave then
    scheduleSave()
  end
end

local function createScreenGui(): ScreenGui
  local gui = Instance.new("ScreenGui")
  gui.Name = "SettingsUI"
  gui.ResetOnSpawn = false
  gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
  gui.DisplayOrder = 10
  gui.Parent = playerGui
  return gui
end

local screenGui = createScreenGui()

toggleButton = Instance.new("TextButton")
toggleButton.Name = "ToggleButton"
toggleButton.Size = UDim2.new(0, 160, 0, 44)
toggleButton.Position = UDim2.new(0, 16, 0, 16)
toggleButton.BackgroundColor3 = Color3.fromRGB(45, 45, 60)
toggleButton.AutoButtonColor = false
toggleButton.TextColor3 = Color3.new(1, 1, 1)
toggleButton.Font = Enum.Font.GothamSemibold
toggleButton.TextSize = 18
toggleButton.Text = "Settings"
toggleButton.Parent = screenGui
toggleButton.Selectable = true

mainFrame = Instance.new("Frame")
mainFrame.Name = "Panel"
mainFrame.Visible = false
mainFrame.Position = UDim2.new(0, 16, 0, 64)
mainFrame.Size = UDim2.new(0, 340, 0, 380)
mainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
mainFrame.BackgroundTransparency = 0.1
mainFrame.BorderSizePixel = 0
mainFrame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = mainFrame

local stroke = Instance.new("UIStroke")
stroke.Thickness = 1
stroke.Color = Color3.fromRGB(80, 80, 96)
stroke.Parent = mainFrame

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.BackgroundTransparency = 1
titleLabel.Size = UDim2.new(1, -20, 0, 32)
titleLabel.Position = UDim2.new(0, 10, 0, 10)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 20
titleLabel.TextColor3 = Color3.new(1, 1, 1)
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Text = "Accessibility & Controls"
titleLabel.Parent = mainFrame

local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton"
closeButton.Size = UDim2.new(0, 96, 0, 40)
closeButton.Position = UDim2.new(1, -106, 0, 14)
closeButton.BackgroundColor3 = Color3.fromRGB(60, 60, 72)
closeButton.AutoButtonColor = false
closeButton.TextColor3 = Color3.new(1, 1, 1)
closeButton.Font = Enum.Font.Gotham
closeButton.TextSize = 16
closeButton.Text = "Close"
closeButton.Parent = mainFrame

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 8)
closeCorner.Parent = closeButton

registerFocusable(closeButton)

local contentFrame = Instance.new("Frame")
contentFrame.Name = "Content"
contentFrame.BackgroundTransparency = 1
contentFrame.Position = UDim2.new(0, 12, 0, 52)
contentFrame.Size = UDim2.new(1, -24, 1, -64)
contentFrame.Parent = mainFrame

local listLayout = Instance.new("UIListLayout")
listLayout.FillDirection = Enum.FillDirection.Vertical
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding = UDim.new(0, 12)
listLayout.Parent = contentFrame

local function createSectionLabel(text: string)
  local label = Instance.new("TextLabel")
  label.BackgroundTransparency = 1
  label.Size = UDim2.new(1, 0, 0, 26)
  label.Font = Enum.Font.GothamBold
  label.TextSize = 16
  label.TextColor3 = Color3.fromRGB(180, 180, 200)
  label.TextXAlignment = Enum.TextXAlignment.Left
  label.Text = text
  label.LayoutOrder = #contentFrame:GetChildren() + 1
  label.Parent = contentFrame
end

local function createToggleRow()
  local row = Instance.new("Frame")
  row.Name = "SprintToggleRow"
  row.BackgroundTransparency = 1
  row.Size = UDim2.new(1, 0, 0, 48)
  row.LayoutOrder = #contentFrame:GetChildren() + 1
  row.Parent = contentFrame

  local label = Instance.new("TextLabel")
  label.BackgroundTransparency = 1
  label.Size = UDim2.new(0.6, 0, 1, 0)
  label.Font = Enum.Font.Gotham
  label.TextSize = 16
  label.TextColor3 = Color3.new(1, 1, 1)
  label.TextXAlignment = Enum.TextXAlignment.Left
  label.TextWrapped = true
  label.Text = "Sprint Input"
  label.Parent = row

  local description = Instance.new("TextLabel")
  description.BackgroundTransparency = 1
  description.Size = UDim2.new(0.6, 0, 0, 18)
  description.Position = UDim2.new(0, 0, 0, 26)
  description.Font = Enum.Font.Gotham
  description.TextSize = 13
  description.TextColor3 = Color3.fromRGB(170, 170, 190)
  description.TextXAlignment = Enum.TextXAlignment.Left
  description.Text = "Choose between hold or toggle to sprint"
  description.Parent = row

  sprintToggleButton = Instance.new("TextButton")
  sprintToggleButton.Name = "SprintModeButton"
  sprintToggleButton.AnchorPoint = Vector2.new(1, 0.5)
  sprintToggleButton.Position = UDim2.new(1, 0, 0.5, 0)
  sprintToggleButton.Size = UDim2.new(0.38, 0, 0, 44)
  sprintToggleButton.BackgroundColor3 = Color3.fromRGB(60, 60, 72)
  sprintToggleButton.AutoButtonColor = false
  sprintToggleButton.TextColor3 = Color3.new(1, 1, 1)
  sprintToggleButton.Font = Enum.Font.GothamSemibold
  sprintToggleButton.TextSize = 16
  sprintToggleButton.Text = "Hold to Sprint"
  sprintToggleButton.Parent = row

  local buttonCorner = Instance.new("UICorner")
  buttonCorner.CornerRadius = UDim.new(0, 10)
  buttonCorner.Parent = sprintToggleButton

  registerFocusable(sprintToggleButton)

  sprintToggleButton.Activated:Connect(function()
    applySetting("SprintToggle", not currentSettings.SprintToggle)
  end)

  updateSprintToggleUI()
end

local function createSliderRow(name: string, key: string, minValue: number, maxValue: number, step: number, formatter: ((number) -> string)?)
  local row = Instance.new("Frame")
  row.Name = key .. "Row"
  row.BackgroundTransparency = 1
  row.Size = UDim2.new(1, 0, 0, 70)
  row.LayoutOrder = #contentFrame:GetChildren() + 1
  row.Parent = contentFrame

  local label = Instance.new("TextLabel")
  label.BackgroundTransparency = 1
  label.Size = UDim2.new(1, 0, 0, 22)
  label.Font = Enum.Font.Gotham
  label.TextSize = 16
  label.TextColor3 = Color3.new(1, 1, 1)
  label.TextXAlignment = Enum.TextXAlignment.Left
  label.Text = name
  label.Parent = row

  local valueLabel = Instance.new("TextLabel")
  valueLabel.BackgroundTransparency = 1
  valueLabel.Size = UDim2.new(1, 0, 0, 18)
  valueLabel.Position = UDim2.new(0, 0, 0, 24)
  valueLabel.Font = Enum.Font.Gotham
  valueLabel.TextSize = 14
  valueLabel.TextColor3 = Color3.fromRGB(180, 180, 196)
  valueLabel.TextXAlignment = Enum.TextXAlignment.Left
  valueLabel.Text = ""
  valueLabel.Parent = row

  local sliderTrack = Instance.new("TextButton")
  sliderTrack.Name = key .. "Track"
  sliderTrack.BackgroundColor3 = Color3.fromRGB(60, 60, 72)
  sliderTrack.BorderSizePixel = 0
  sliderTrack.AutoButtonColor = false
  sliderTrack.Text = ""
  sliderTrack.Position = UDim2.new(0, 0, 0, 48)
  sliderTrack.Size = UDim2.new(1, 0, 0, 12)
  sliderTrack.Parent = row

  registerFocusable(sliderTrack)

  local fill = Instance.new("Frame")
  fill.BackgroundColor3 = Color3.fromRGB(120, 180, 255)
  fill.BorderSizePixel = 0
  fill.Size = UDim2.new(0, 0, 1, 0)
  fill.ZIndex = sliderTrack.ZIndex + 1
  fill.Parent = sliderTrack

  local knob = Instance.new("Frame")
  knob.BackgroundColor3 = Color3.fromRGB(200, 220, 255)
  knob.Size = UDim2.new(0, 18, 0, 18)
  knob.AnchorPoint = Vector2.new(0.5, 0.5)
  knob.Position = UDim2.new(0, 0, 0.5, 0)
  knob.ZIndex = sliderTrack.ZIndex + 2
  knob.Parent = sliderTrack

  local knobCorner = Instance.new("UICorner")
  knobCorner.CornerRadius = UDim.new(1, 0)
  knobCorner.Parent = knob

  local currentValue = minValue
  local dragging = false
  local lastThumbstickStep = 0
  local THUMBSTICK_DEADZONE = 0.25
  local THUMBSTICK_REPEAT = 0.18

  local function formatValue(value: number): string
    if formatter then
      return formatter(value)
    end
    return string.format("%.2f", value)
  end

  local function setVisual(value: number)
    local alpha = if maxValue > minValue then (value - minValue) / (maxValue - minValue) else 0
    alpha = math.clamp(alpha, 0, 1)
    fill.Size = UDim2.new(alpha, 0, 1, 0)
    knob.Position = UDim2.new(alpha, 0, 0.5, 0)
    valueLabel.Text = formatValue(value)
  end

  local function commit(value: number, fromInput: boolean)
    local clamped = math.clamp(value, minValue, maxValue)
    if step > 0 then
      clamped = minValue + math.floor((clamped - minValue) / step + 0.5) * step
      clamped = math.clamp(clamped, minValue, maxValue)
    end
    if math.abs(clamped - currentValue) > 1e-4 then
      currentValue = clamped
      setVisual(currentValue)
      applySetting(key, currentValue, not fromInput)
    else
      setVisual(currentValue)
    end
  end

  local function stepBy(deltaSteps: number)
    if deltaSteps == 0 then
      return
    end
    local increment = step
    if increment <= 0 then
      increment = (maxValue - minValue) / 20
      if increment == 0 then
        increment = 0.05
      end
    end
    commit(currentValue + increment * deltaSteps, true)
  end

  local function updateFromInput(positionX: number)
    local trackPosition = sliderTrack.AbsolutePosition.X
    local trackSize = sliderTrack.AbsoluteSize.X
    if trackSize <= 0 then
      return
    end
    local ratio = math.clamp((positionX - trackPosition) / trackSize, 0, 1)
    local target = minValue + (maxValue - minValue) * ratio
    commit(target, true)
  end

  sliderTrack.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
      dragging = true
      updateFromInput(input.Position.X)
      local endedConnection
      endedConnection = input.Changed:Connect(function()
        if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
          dragging = false
          if endedConnection then
            endedConnection:Disconnect()
          end
        end
      end)
    elseif input.UserInputType == Enum.UserInputType.Gamepad1 then
      if input.KeyCode == Enum.KeyCode.DPadLeft then
        stepBy(-1)
      elseif input.KeyCode == Enum.KeyCode.DPadRight then
        stepBy(1)
      end
    end
  end)

  sliderTrack.InputChanged:Connect(function(input)
    if dragging then
      if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        updateFromInput(input.Position.X)
      end
      return
    end

    if input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick1 then
      if GuiService.SelectedObject ~= sliderTrack then
        lastThumbstickStep = 0
        return
      end

      local direction = input.Position.X
      local magnitude = math.abs(direction)
      if magnitude > THUMBSTICK_DEADZONE then
        local now = os.clock()
        if now - lastThumbstickStep >= THUMBSTICK_REPEAT then
          stepBy(direction > 0 and 1 or -1)
          lastThumbstickStep = now
        end
      else
        lastThumbstickStep = 0
      end
    end
  end)

  knob.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
      dragging = true
      local endedConnection
      endedConnection = input.Changed:Connect(function()
        if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
          dragging = false
          if endedConnection then
            endedConnection:Disconnect()
          end
        end
      end)
    end
  end)

  UserInputService.InputChanged:Connect(function(input)
    if not dragging then
      return
    end
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
      updateFromInput(input.Position.X)
    end
  end)

  sliderTrack.SelectionLost:Connect(function()
    lastThumbstickStep = 0
  end)

  if key == "AimAssistWindow" then
    aimAssistSliderSet = function(value)
      currentValue = value
      setVisual(currentValue)
    end
    aimAssistSliderSet(currentSettings.AimAssistWindow)
  elseif key == "CameraShakeStrength" then
    cameraShakeSliderSet = function(value)
      currentValue = value
      setVisual(currentValue)
    end
    cameraShakeSliderSet(currentSettings.CameraShakeStrength)
  elseif key == "TextScale" then
    textScaleSliderSet = function(value)
      currentValue = value
      setVisual(currentValue)
    end
    textScaleSliderSet(currentSettings.TextScale)
  else
    currentValue = minValue
    setVisual(currentValue)
  end
end

local function createPaletteRow()
  local row = Instance.new("Frame")
  row.Name = "PaletteRow"
  row.BackgroundTransparency = 1
  row.Size = UDim2.new(1, 0, 0, 60)
  row.LayoutOrder = #contentFrame:GetChildren() + 1
  row.Parent = contentFrame

  paletteValueLabel = Instance.new("TextButton")
  paletteValueLabel.Name = "PaletteValue"
  paletteValueLabel.BackgroundTransparency = 1
  paletteValueLabel.AutoButtonColor = false
  paletteValueLabel.Size = UDim2.new(0.7, 0, 0, 26)
  paletteValueLabel.Font = Enum.Font.Gotham
  paletteValueLabel.TextSize = 16
  paletteValueLabel.TextColor3 = Color3.new(1, 1, 1)
  paletteValueLabel.TextXAlignment = Enum.TextXAlignment.Left
  paletteValueLabel.Text = ""
  paletteValueLabel.Parent = row

  registerFocusable(paletteValueLabel)

  local previousButton = Instance.new("TextButton")
  previousButton.Size = UDim2.new(0, 44, 0, 44)
  previousButton.Position = UDim2.new(0.72, 0, 0, 8)
  previousButton.BackgroundColor3 = Color3.fromRGB(60, 60, 72)
  previousButton.AutoButtonColor = false
  previousButton.TextColor3 = Color3.new(1, 1, 1)
  previousButton.Font = Enum.Font.GothamSemibold
  previousButton.TextSize = 18
  previousButton.Text = "<"
  previousButton.Selectable = false
  previousButton.Parent = row

  local nextButton = Instance.new("TextButton")
  nextButton.Size = UDim2.new(0, 44, 0, 44)
  nextButton.Position = UDim2.new(0.85, 0, 0, 8)
  nextButton.BackgroundColor3 = Color3.fromRGB(60, 60, 72)
  nextButton.AutoButtonColor = false
  nextButton.TextColor3 = Color3.new(1, 1, 1)
  nextButton.Font = Enum.Font.GothamSemibold
  nextButton.TextSize = 18
  nextButton.Text = ">"
  nextButton.Selectable = false
  nextButton.Parent = row

  local cornerA = Instance.new("UICorner")
  cornerA.CornerRadius = UDim.new(0, 8)
  cornerA.Parent = previousButton

  local cornerB = Instance.new("UICorner")
  cornerB.CornerRadius = UDim.new(0, 8)
  cornerB.Parent = nextButton

  local paletteThumbstickTime = 0

  local function selectByOffset(delta: number)
    local currentId = currentSettings.ColorblindPalette
    local index = paletteIndexLookup[currentId] or 1
    local newIndex = ((index - 1 + delta) % #paletteOrder) + 1
    applySetting("ColorblindPalette", paletteOrder[newIndex].Id)
  end

  previousButton.Activated:Connect(function()
    selectByOffset(-1)
  end)

  nextButton.Activated:Connect(function()
    selectByOffset(1)
  end)

  paletteValueLabel.Activated:Connect(function()
    selectByOffset(1)
  end)

  paletteValueLabel.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Gamepad1 then
      if input.KeyCode == Enum.KeyCode.DPadLeft then
        selectByOffset(-1)
      elseif input.KeyCode == Enum.KeyCode.DPadRight then
        selectByOffset(1)
      end
    end
  end)

  paletteValueLabel.InputChanged:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Gamepad1 or input.KeyCode ~= Enum.KeyCode.Thumbstick1 then
      return
    end

    if GuiService.SelectedObject ~= paletteValueLabel then
      paletteThumbstickTime = 0
      return
    end

    local axis = input.Position.X
    if math.abs(axis) < 0.3 then
      paletteThumbstickTime = 0
      return
    end

    local now = os.clock()
    if now - paletteThumbstickTime >= 0.2 then
      selectByOffset(axis > 0 and 1 or -1)
      paletteThumbstickTime = now
    end
  end)

  paletteValueLabel.SelectionLost:Connect(function()
    paletteThumbstickTime = 0
  end)

  updatePaletteUI()
end

local function createTutorialResetRow()
  local row = Instance.new("Frame")
  row.Name = "TutorialResetRow"
  row.BackgroundTransparency = 1
  row.Size = UDim2.new(1, 0, 0, 78)
  row.LayoutOrder = #contentFrame:GetChildren() + 1
  row.Parent = contentFrame

  local title = Instance.new("TextLabel")
  title.BackgroundTransparency = 1
  title.Size = UDim2.new(1, -150, 0, 22)
  title.Font = Enum.Font.Gotham
  title.TextSize = 16
  title.TextColor3 = Color3.new(1, 1, 1)
  title.TextXAlignment = Enum.TextXAlignment.Left
  title.Text = "Tutorial"
  title.Parent = row

  local description = Instance.new("TextLabel")
  description.BackgroundTransparency = 1
  description.Size = UDim2.new(1, -160, 0, 44)
  description.Position = UDim2.new(0, 0, 0, 26)
  description.Font = Enum.Font.Gotham
  description.TextSize = 14
  description.TextColor3 = Color3.fromRGB(180, 180, 196)
  description.TextXAlignment = Enum.TextXAlignment.Left
  description.TextYAlignment = Enum.TextYAlignment.Top
  description.TextWrapped = true
  description.Text = "Replay the onboarding tips the next time you join."
  description.Parent = row

  local button = Instance.new("TextButton")
  button.Name = "ResetTutorialButton"
  button.AnchorPoint = Vector2.new(1, 0)
  button.Position = UDim2.new(1, 0, 0, 30)
  button.Size = UDim2.new(0, 160, 0, 44)
  button.BackgroundColor3 = Color3.fromRGB(60, 60, 72)
  button.AutoButtonColor = false
  button.TextColor3 = Color3.new(1, 1, 1)
  button.Font = Enum.Font.GothamSemibold
  button.TextSize = 16
  button.Text = "Reset Tutorial"
  button.Parent = row

  local buttonCorner = Instance.new("UICorner")
  buttonCorner.CornerRadius = UDim.new(0, 10)
  buttonCorner.Parent = button

  if not tutorialRemote then
    button.Text = "Unavailable"
    button.AutoButtonColor = false
    button.TextTransparency = 0.4
    button.Active = false
    return
  end

  registerFocusable(button)

  local busy = false
  button.Activated:Connect(function()
    if busy then
      return
    end
    busy = true
    local originalText = button.Text
    button.Text = "Resetting..."

    task.spawn(function()
      local success = false
      local remote = tutorialRemote
      if remote then
        local ok, result = pcall(function()
          return remote:InvokeServer({ action = "reset" })
        end)
        if ok and typeof(result) == "table" then
          local completedValue = (result :: any).completed or (result :: any).Completed
          if completedValue == false then
            success = true
          end
        elseif not ok then
          warn("[SettingsUI] Tutorial reset failed:", result)
        end
      end

      task.defer(function()
        if success then
          button.Text = "Tutorial Reset"
          task.delay(2, function()
            if button.Parent then
              button.Text = originalText
            end
          end)
        else
          button.Text = originalText
        end
        busy = false
      end)
    end)
  end)
end

local function setPanelVisible(visible: boolean)
  if panelVisible == visible then
    if mainFrame then
      if visible then
        mainFrame.Visible = true
      else
        mainFrame.BackgroundTransparency = 0.1
        mainFrame.Visible = false
      end
    end
    return
  end

  panelVisible = visible

  if mainFrame then
    if visible then
      mainFrame.Visible = true
      TweenService:Create(mainFrame, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        BackgroundTransparency = 0.05,
      }):Play()
    else
      mainFrame.BackgroundTransparency = 0.1
      mainFrame.Visible = false
    end
  end

  rebuildFocusChain()

  if visible then
    if gamepadPreferred then
      focusFirstControl()
    end
  elseif gamepadPreferred and toggleButton and toggleButton.Parent then
    GuiService.SelectedObject = toggleButton
  end
end

local function formatPercentage(value: number): string
  return string.format("%d%%", math.floor(math.clamp(value, 0, 1) * 100 + 0.5))
end

local function formatTextScale(value: number): string
  return string.format("%d%%", math.floor(value * 100 + 0.5))
end

createSectionLabel("Movement")
createToggleRow()
createSliderRow("Aim Assist Window", "AimAssistWindow", 0, 1, 0.05, function(value)
  if value <= 0 then
    return "Off"
  end
  return string.format("%d%%", math.floor(value * 100 + 0.5))
end)

createSectionLabel("Feedback")
createSliderRow("Camera Shake Strength", "CameraShakeStrength", 0, 1, 0.05, formatPercentage)
createPaletteRow()

createSectionLabel("UI")
createSliderRow("Text Scale", "TextScale", clampValue("TextScale", 0.8, 0.8), clampValue("TextScale", 1.4, 1.4), 0.05, formatTextScale)

createSectionLabel("Onboarding")
createTutorialResetRow()

trackControllerConnection(UserInputService.LastInputTypeChanged:Connect(function(newType)
  if isGamepadInputType(newType) then
    setGamepadPreferred(true)
  elseif not UserInputService.GamepadEnabled then
    setGamepadPreferred(false)
  end
end))

trackControllerConnection(UserInputService.GamepadConnected:Connect(function()
  setGamepadPreferred(true)
end))

trackControllerConnection(UserInputService.GamepadDisconnected:Connect(function()
  if not UserInputService.GamepadEnabled then
    setGamepadPreferred(false)
  else
    setGamepadPreferred(isGamepadInputType(UserInputService:GetLastInputType()))
  end
end))

do
  local okOpened, menuOpened = pcall(function()
    return GuiService.MenuOpened
  end)
  if okOpened and menuOpened then
    trackControllerConnection((menuOpened :: any):Connect(function()
      setPanelVisible(false)
    end))
  end
end

ContextActionService:UnbindAction(ACTION_TOGGLE_SETTINGS)
ContextActionService:BindAction(ACTION_TOGGLE_SETTINGS, function(_actionName: string, state: Enum.UserInputState)
  if state ~= Enum.UserInputState.Begin then
    return Enum.ContextActionResult.Pass
  end
  setPanelVisible(not panelVisible)
  return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.ButtonSelect)

setGamepadPreferred(gamepadPreferred or UserInputService.GamepadEnabled)

applyColorblindPalette(currentSettings.ColorblindPalette)
refreshAllText()
updateSprintToggleUI()
updatePaletteUI()

local function requestInitialSettings()
  if not saveRemote then
    applySettings(DEFAULT_SETTINGS, true)
    return
  end
  local ok, result = pcall(function()
    return saveRemote:InvokeServer(nil)
  end)
  if ok and typeof(result) == "table" then
    applySettings(result, true)
  else
    applySettings(DEFAULT_SETTINGS, true)
  end
end

if pushRemote then
  pushRemote.OnClientEvent:Connect(function(payload)
    if typeof(payload) == "table" then
      applySettings(payload, true)
    end
  end)
end

requestInitialSettings()

toggleButton.Activated:Connect(function()
  setPanelVisible(not panelVisible)
end)

closeButton.Activated:Connect(function()
  setPanelVisible(false)
end)

script.Destroying:Connect(function()
  ContextActionService:UnbindAction(ACTION_TOGGLE_SETTINGS)
  for _, connection in ipairs(controllerConnections) do
    connection:Disconnect()
  end
  table.clear(controllerConnections)
  for _, connection in pairs(focusCleanupConnections) do
    connection:Disconnect()
  end
  table.clear(focusCleanupConnections)
end)

applySettings(currentSettings, true)
