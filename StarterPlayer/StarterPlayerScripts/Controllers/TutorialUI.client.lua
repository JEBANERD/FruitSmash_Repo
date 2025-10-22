--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
if not localPlayer then
    return
end

local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local remoteBootstrap = require(remotesFolder:WaitForChild("RemoteBootstrap"))

local tutorialRemote: RemoteFunction? = remoteBootstrap and remoteBootstrap.RF_Tutorial or nil
if not tutorialRemote then
    warn("[TutorialUI] RF_Tutorial remote missing; skipping onboarding flow.")
    return
end

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local GameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = if typeof(GameConfigModule.Get) == "function" then GameConfigModule.Get() else GameConfigModule

local obstaclesConfig = if typeof(GameConfig) == "table" then (GameConfig :: any).Obstacles else nil
local obstacleLevel = 10
if typeof(obstaclesConfig) == "table" then
    local levelValue = (obstaclesConfig :: any).EnableAtLevel
    if typeof(levelValue) == "number" then
        if levelValue >= math.huge then
            obstacleLevel = math.huge
        else
            obstacleLevel = math.max(1, math.floor(levelValue + 0.5))
        end
    end
end

local TUTORIAL_ATTR_NAME = "TutorialCompleted"

local function requestTutorialCompleted(): boolean?
    local remote = tutorialRemote
    if not remote then
        return nil
    end
    local ok, result = pcall(function()
        return remote:InvokeServer({ action = "status" })
    end)
    if ok and typeof(result) == "table" then
        local completedValue = (result :: any).completed or (result :: any).Completed
        if typeof(completedValue) == "boolean" then
            return completedValue
        end
    elseif not ok then
        warn("[TutorialUI] Failed to fetch tutorial state:", result)
    end
    return nil
end

local existing = localPlayer:GetAttribute(TUTORIAL_ATTR_NAME)
if existing == true then
    return
end

local remoteCompleted = requestTutorialCompleted()
if remoteCompleted == true then
    return
end

type InputMode = "KeyboardMouse" | "Gamepad" | "Touch"

type TutorialContext = {
    inputMode: InputMode,
    sprintToggle: boolean,
    obstacleLevel: number,
}

local function resolveInputModeFromType(inputType: Enum.UserInputType?): InputMode
    if inputType == Enum.UserInputType.Touch then
        return "Touch"
    end
    if inputType and string.find(inputType.Name, "Gamepad") then
        return "Gamepad"
    end
    if inputType == Enum.UserInputType.Keyboard
        or inputType == Enum.UserInputType.MouseMovement
        or inputType == Enum.UserInputType.MouseButton1
        or inputType == Enum.UserInputType.MouseButton2
        or inputType == Enum.UserInputType.MouseWheel then
        return "KeyboardMouse"
    end
    if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.GamepadEnabled then
        return "Touch"
    end
    if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
        return "Gamepad"
    end
    return "KeyboardMouse"
end

local tutorialContext: TutorialContext = {
    inputMode = resolveInputModeFromType(UserInputService:GetLastInputType()),
    sprintToggle = localPlayer:GetAttribute("SprintToggle") == true,
    obstacleLevel = obstacleLevel,
}

type TutorialStep = {
    id: string,
    title: string,
    getLines: (context: TutorialContext) -> {string},
}

local steps: { TutorialStep } = {
    {
        id = "move",
        title = "Move Around",
        getLines = function(context: TutorialContext): {string}
            if context.inputMode == "Touch" then
                return {
                    "Drag the on-screen joystick to run around the arena.",
                    "Swipe the camera side to look around while you move.",
                }
            elseif context.inputMode == "Gamepad" then
                return {
                    "Tilt the left stick to move and the right stick to look.",
                    "Strafe around fruit to line up the perfect swing.",
                }
            else
                return {
                    "Use W A S D (or the arrow keys) to move.",
                    "Move your mouse to aim before you swing.",
                }
            end
        end,
    },
    {
        id = "sprint",
        title = "Sprint & Stamina",
        getLines = function(context: TutorialContext): {string}
            if context.inputMode == "Touch" then
                return {
                    "Tap the SPRINT button near jump for a burst of speed.",
                    "Stamina refills automatically whenever you slow down.",
                }
            elseif context.inputMode == "Gamepad" then
                return {
                    "Click the left stick (L3) or press B to sprint.",
                    "Take short breaks to recharge stamina between bursts.",
                }
            else
                local sprintLine = if context.sprintToggle
                    then "Press Left Shift to toggle sprint on and off."
                    else "Hold Left Shift while you move to sprint."
                return {
                    sprintLine,
                    "You can swap sprint modes anytime in Settings.",
                }
            end
        end,
    },
    {
        id = "swing",
        title = "Swing Your Bat",
        getLines = function(context: TutorialContext): {string}
            if context.inputMode == "Touch" then
                return {
                    "Tap near a fruit to swing your bat at it.",
                    "Aim assist is available in Settings if you need extra help.",
                }
            elseif context.inputMode == "Gamepad" then
                return {
                    "Press RT to swing — LT or A work in a pinch too.",
                    "Face each fruit to keep your combo streak alive.",
                }
            else
                return {
                    "Click the left mouse button to swing your bat.",
                    "Aim at fruit to build combos and earn extra rewards.",
                }
            end
        end,
    },
    {
        id = "tokens",
        title = "Use Tokens",
        getLines = function(context: TutorialContext): {string}
            if context.inputMode == "Touch" then
                return {
                    "Tap the quickbar buttons at the bottom to use tokens.",
                    "Tokens provide boosts — stock up before the next level.",
                }
            elseif context.inputMode == "Gamepad" then
                return {
                    "Use the D-Pad to trigger tokens in each quickbar slot.",
                    "Directional taps fire the matching slot instantly.",
                }
            else
                return {
                    "Tokens live in the quickbar at the bottom of the screen.",
                    "Press number keys 1–5 to activate the matching slot.",
                }
            end
        end,
    },
    {
        id = "shop",
        title = "Visit the Shop",
        getLines = function(_context: TutorialContext): {string}
            return {
                "Spend your coins between waves at the Shop in the lobby.",
                "Grab new tokens or upgrade melee gear before the next round.",
            }
        end,
    },
    {
        id = "obstacles",
        title = "Watch for Obstacles",
        getLines = function(context: TutorialContext): {string}
            local levelInfo = context.obstacleLevel
            local line
            if levelInfo == math.huge then
                line = "Hazards unlock as you reach the higher levels."
            else
                local levelNumber = math.max(1, math.floor(levelInfo + 0.5))
                line = string.format("Hazards like sawblades unlock at Level %d.", levelNumber)
            end
            return {
                line,
                "Jump or sprint past traps to keep your streak alive.",
            }
        end,
    },
}

local totalSteps = #steps
local currentStepIndex = 1

local screenGui: ScreenGui? = nil
local bodyFrame: Frame? = nil
local progressLabel: TextLabel? = nil
local titleLabel: TextLabel? = nil
local buttonNext: TextButton? = nil
local skipButton: TextButton? = nil

local connections: { RBXScriptConnection } = {}
local sessionClosed = false

local glyphCache: { [Enum.KeyCode]: string } = {}

local function getGlyphImage(keyCode: Enum.KeyCode): string
    local cached = glyphCache[keyCode]
    if cached ~= nil then
        return cached
    end

    local ok, result = pcall(function()
        return UserInputService:GetImageForKeyCode(keyCode)
    end)

    local image = ""
    if ok and typeof(result) == "string" then
        image = result
    end
    glyphCache[keyCode] = image
    return image
end

local function createDPadGlyphRow(): Frame
    local row = Instance.new("Frame")
    row.Name = "DPadGlyphRow"
    row.BackgroundTransparency = 1
    row.Size = UDim2.new(1, 0, 0, 48)
    row.ZIndex = 3

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding = UDim.new(0, 12)
    layout.Parent = row

    local directions = {
        { key = Enum.KeyCode.DPadLeft, label = "Left" },
        { key = Enum.KeyCode.DPadUp, label = "Up" },
        { key = Enum.KeyCode.DPadRight, label = "Right" },
        { key = Enum.KeyCode.DPadDown, label = "Down" },
    }

    for _, entry in ipairs(directions) do
        local container = Instance.new("Frame")
        container.BackgroundTransparency = 1
        container.Size = UDim2.new(0, 72, 1, 0)
        container.ZIndex = 3
        container.Parent = row

        local image = Instance.new("ImageLabel")
        image.BackgroundTransparency = 1
        image.AnchorPoint = Vector2.new(0.5, 0)
        image.Position = UDim2.new(0.5, 0, 0, 0)
        image.Size = UDim2.new(0, 28, 0, 28)
        image.ZIndex = 3
        local glyph = getGlyphImage(entry.key)
        image.Image = glyph
        image.ImageTransparency = glyph ~= "" and 0 or 1
        image.Parent = container

        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.AnchorPoint = Vector2.new(0.5, 0)
        label.Position = UDim2.new(0.5, 0, 0, 30)
        label.Size = UDim2.new(1, 0, 0, 14)
        label.Font = Enum.Font.Gotham
        label.TextSize = 12
        label.TextColor3 = Color3.fromRGB(200, 200, 220)
        label.TextXAlignment = Enum.TextXAlignment.Center
        label.Text = entry.label
        label.ZIndex = 3
        label.Parent = container
    end

    return row
end

local function disconnectConnections()
    for _, connection in ipairs(connections) do
        if connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function destroyTutorial()
    disconnectConnections()
    if screenGui then
        screenGui:Destroy()
        screenGui = nil
    end
end

local function sendState(action: string, completedFlag: boolean?)
    local remote = tutorialRemote
    if not remote then
        return
    end
    task.spawn(function()
        local payload = { action = action }
        if completedFlag ~= nil then
            payload.completed = completedFlag
        end
        local ok, result = pcall(function()
            return remote:InvokeServer(payload)
        end)
        if not ok then
            warn("[TutorialUI] Failed to report tutorial state:", result)
        end
    end)
end

local function renderStep()
    local frame = bodyFrame
    local progress = progressLabel
    local title = titleLabel
    local nextButton = buttonNext
    if not frame or not progress or not title or not nextButton then
        return
    end

    local step = steps[currentStepIndex]
    if not step then
        return
    end

    progress.Text = string.format("Tip %d of %d", currentStepIndex, totalSteps)
    title.Text = step.title

    for _, child in ipairs(frame:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end

    local lines = step.getLines(tutorialContext)
    local createdCount = 0
    for _, text in ipairs(lines) do
        if type(text) == "string" and text ~= "" then
            createdCount += 1
            local label = Instance.new("TextLabel")
            label.BackgroundTransparency = 1
            label.Size = UDim2.new(1, 0, 0, 0)
            label.AutomaticSize = Enum.AutomaticSize.Y
            label.Font = Enum.Font.Gotham
            label.TextSize = 18
            label.TextColor3 = Color3.fromRGB(230, 230, 240)
            label.TextXAlignment = Enum.TextXAlignment.Left
            label.TextYAlignment = Enum.TextYAlignment.Top
            label.TextWrapped = true
            label.Text = text
            label.ZIndex = 3
            label.LayoutOrder = createdCount
            label.Parent = frame
        end
    end

    if step.id == "tokens" and tutorialContext.inputMode == "Gamepad" then
        local glyphRow = createDPadGlyphRow()
        glyphRow.LayoutOrder = createdCount + 1
        glyphRow.Parent = frame
    end

    nextButton.Text = if currentStepIndex >= totalSteps then "Finish" else "Next"
end

local function completeTutorial(action: string)
    if sessionClosed then
        return
    end
    sessionClosed = true
    sendState(action, true)
    destroyTutorial()
end

local function createInterface()
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "TutorialUI"
    screenGui.DisplayOrder = 35
    screenGui.IgnoreGuiInset = true
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = playerGui

    local overlay = Instance.new("Frame")
    overlay.Name = "Overlay"
    overlay.BackgroundColor3 = Color3.new(0, 0, 0)
    overlay.BackgroundTransparency = 0.45
    overlay.BorderSizePixel = 0
    overlay.Size = UDim2.new(1, 0, 1, 0)
    overlay.ZIndex = 1
    overlay.Parent = screenGui

    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.new(0.5, 0, 0.5, 0)
    panel.Size = UDim2.new(0, 460, 0, 360)
    panel.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
    panel.BackgroundTransparency = 0.05
    panel.BorderSizePixel = 0
    panel.ZIndex = 2
    panel.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = panel

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Color = Color3.fromRGB(80, 90, 110)
    stroke.Parent = panel

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 24)
    padding.PaddingBottom = UDim.new(0, 24)
    padding.PaddingLeft = UDim.new(0, 24)
    padding.PaddingRight = UDim.new(0, 24)
    padding.Parent = panel

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 16)
    layout.Parent = panel

    progressLabel = Instance.new("TextLabel")
    progressLabel.Name = "Progress"
    progressLabel.BackgroundTransparency = 1
    progressLabel.Size = UDim2.new(1, 0, 0, 20)
    progressLabel.Font = Enum.Font.Gotham
    progressLabel.TextSize = 14
    progressLabel.TextColor3 = Color3.fromRGB(190, 190, 210)
    progressLabel.TextXAlignment = Enum.TextXAlignment.Right
    progressLabel.Text = ""
    progressLabel.LayoutOrder = 1
    progressLabel.ZIndex = 3
    progressLabel.Parent = panel

    titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "Title"
    titleLabel.BackgroundTransparency = 1
    titleLabel.Size = UDim2.new(1, 0, 0, 30)
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 26
    titleLabel.TextColor3 = Color3.new(1, 1, 1)
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Text = ""
    titleLabel.LayoutOrder = 2
    titleLabel.ZIndex = 3
    titleLabel.Parent = panel

    bodyFrame = Instance.new("Frame")
    bodyFrame.Name = "Body"
    bodyFrame.BackgroundTransparency = 1
    bodyFrame.Size = UDim2.new(1, 0, 0, 0)
    bodyFrame.AutomaticSize = Enum.AutomaticSize.Y
    bodyFrame.LayoutOrder = 3
    bodyFrame.ZIndex = 3
    bodyFrame.Parent = panel

    local bodyLayout = Instance.new("UIListLayout")
    bodyLayout.FillDirection = Enum.FillDirection.Vertical
    bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
    bodyLayout.Padding = UDim.new(0, 10)
    bodyLayout.Parent = bodyFrame

    local buttonRow = Instance.new("Frame")
    buttonRow.Name = "Buttons"
    buttonRow.BackgroundTransparency = 1
    buttonRow.Size = UDim2.new(1, 0, 0, 44)
    buttonRow.LayoutOrder = 4
    buttonRow.ZIndex = 3
    buttonRow.Parent = panel

    skipButton = Instance.new("TextButton")
    skipButton.Name = "SkipButton"
    skipButton.AnchorPoint = Vector2.new(0, 0)
    skipButton.Position = UDim2.new(0, 0, 0, 0)
    skipButton.Size = UDim2.new(0, 160, 1, 0)
    skipButton.BackgroundColor3 = Color3.fromRGB(52, 56, 72)
    skipButton.AutoButtonColor = false
    skipButton.TextColor3 = Color3.fromRGB(220, 220, 235)
    skipButton.Font = Enum.Font.Gotham
    skipButton.TextSize = 16
    skipButton.Text = "Skip Tutorial"
    skipButton.ZIndex = 3
    skipButton.Parent = buttonRow

    local skipCorner = Instance.new("UICorner")
    skipCorner.CornerRadius = UDim.new(0, 10)
    skipCorner.Parent = skipButton

    buttonNext = Instance.new("TextButton")
    buttonNext.Name = "NextButton"
    buttonNext.AnchorPoint = Vector2.new(1, 0)
    buttonNext.Position = UDim2.new(1, 0, 0, 0)
    buttonNext.Size = UDim2.new(0, 160, 1, 0)
    buttonNext.BackgroundColor3 = Color3.fromRGB(90, 140, 255)
    buttonNext.AutoButtonColor = false
    buttonNext.TextColor3 = Color3.new(1, 1, 1)
    buttonNext.Font = Enum.Font.GothamSemibold
    buttonNext.TextSize = 16
    buttonNext.Text = "Next"
    buttonNext.ZIndex = 3
    buttonNext.Parent = buttonRow

    local nextCorner = Instance.new("UICorner")
    nextCorner.CornerRadius = UDim.new(0, 10)
    nextCorner.Parent = buttonNext

    renderStep()

    table.insert(connections, skipButton.MouseButton1Click:Connect(function()
        completeTutorial("skip")
    end))

    table.insert(connections, buttonNext.MouseButton1Click:Connect(function()
        if sessionClosed then
            return
        end
        if currentStepIndex < totalSteps then
            currentStepIndex += 1
            renderStep()
        else
            completeTutorial("complete")
        end
    end))
end

createInterface()

table.insert(connections, UserInputService.LastInputTypeChanged:Connect(function(newType)
    local newMode = resolveInputModeFromType(newType)
    if tutorialContext.inputMode ~= newMode then
        tutorialContext.inputMode = newMode
        if not sessionClosed then
            renderStep()
        end
    end
end))

table.insert(connections, localPlayer:GetAttributeChangedSignal("SprintToggle"):Connect(function()
    local newValue = localPlayer:GetAttribute("SprintToggle") == true
    if tutorialContext.sprintToggle ~= newValue then
        tutorialContext.sprintToggle = newValue
        if not sessionClosed then
            renderStep()
        end
    end
end))
