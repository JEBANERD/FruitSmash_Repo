--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
if not localPlayer then
    return
end

local RemotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not RemotesFolder then
    local ok, result = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 5)
    end)
    if ok and result then
        RemotesFolder = result
    end
end

local Remotes
if RemotesFolder then
    local ok, result = pcall(function()
        return require(RemotesFolder:WaitForChild("RemoteBootstrap"))
    end)
    if ok then
        Remotes = result
    else
        warn("[HUDController] Failed to require RemoteBootstrap:", result)
    end
end

local coinRemote: RemoteEvent? = Remotes and Remotes.RE_CoinPointDelta or nil
local prepRemote: RemoteEvent? = Remotes and Remotes.RE_PrepTimer or nil
local waveRemote: RemoteEvent? = Remotes and Remotes.RE_WaveChanged or nil
local targetRemote: RemoteEvent? = Remotes and Remotes.RE_TargetHP or nil

local playerGui: PlayerGui? = localPlayer:FindFirstChildOfClass("PlayerGui")
if not playerGui then
    local ok, result = pcall(function()
        return localPlayer:WaitForChild("PlayerGui", 5)
    end)
    if ok and result and result:IsA("PlayerGui") then
        playerGui = result
    end
end

local HUD_NAME = "HUD"
local HUD_SECTION_NAME = "HUD_CoinsPoints"

local COUNTER_ANIMATION_MIN = 0.18
local COUNTER_ANIMATION_MAX = 0.6
local COUNTER_SPEED_FACTOR = 0.02
local DELTA_TWEEN_TIME = 0.75
local LANE_PANEL_WIDTH = 84
local LANE_PANEL_PADDING = 12
local LANE_PANEL_HEIGHT = 140
local LANE_PANEL_MIN_WIDTH = 220
local LANE_PANEL_MAX_WIDTH = 540

type LanePalette = {
    hpHigh: Color3,
    hpMid: Color3,
    hpLow: Color3,
    hpShield: Color3,
    damageFlash: Color3,
    deltaGain: Color3,
    deltaLoss: Color3,
}

local DEFAULT_PALETTE_ID = "off"

local COLORBLIND_PALETTES: { [string]: LanePalette } = {
    ["off"] = {
        hpHigh = Color3.fromRGB(90, 220, 110),
        hpMid = Color3.fromRGB(255, 200, 100),
        hpLow = Color3.fromRGB(255, 100, 100),
        hpShield = Color3.fromRGB(120, 200, 255),
        damageFlash = Color3.fromRGB(255, 80, 80),
        deltaGain = Color3.fromRGB(140, 255, 140),
        deltaLoss = Color3.fromRGB(255, 140, 140),
    },
    ["deuteranopia"] = {
        hpHigh = Color3.fromRGB(50, 185, 255),
        hpMid = Color3.fromRGB(255, 203, 64),
        hpLow = Color3.fromRGB(255, 125, 40),
        hpShield = Color3.fromRGB(120, 200, 255),
        damageFlash = Color3.fromRGB(255, 170, 60),
        deltaGain = Color3.fromRGB(90, 200, 255),
        deltaLoss = Color3.fromRGB(255, 160, 80),
    },
    ["protanopia"] = {
        hpHigh = Color3.fromRGB(60, 190, 255),
        hpMid = Color3.fromRGB(255, 210, 72),
        hpLow = Color3.fromRGB(255, 140, 90),
        hpShield = Color3.fromRGB(120, 200, 255),
        damageFlash = Color3.fromRGB(255, 160, 96),
        deltaGain = Color3.fromRGB(84, 195, 255),
        deltaLoss = Color3.fromRGB(255, 168, 120),
    },
    ["tritanopia"] = {
        hpHigh = Color3.fromRGB(70, 205, 132),
        hpMid = Color3.fromRGB(235, 205, 88),
        hpLow = Color3.fromRGB(200, 120, 210),
        hpShield = Color3.fromRGB(120, 200, 255),
        damageFlash = Color3.fromRGB(210, 130, 210),
        deltaGain = Color3.fromRGB(100, 215, 160),
        deltaLoss = Color3.fromRGB(210, 150, 210),
    },
}

local activePaletteId: string = DEFAULT_PALETTE_ID
local activePalette: LanePalette = COLORBLIND_PALETTES[DEFAULT_PALETTE_ID]

local safeAreaFrame: Frame? = nil
local safeAreaPadding: UIPadding? = nil
local cameraViewportConnection: RBXScriptConnection? = nil
local lastSafeAreaInsets = { left = -1, top = -1, right = -1, bottom = -1 }

local FRIENDLY_PHASE = {
    prep = "Prep",
    wave = "Wave",
    intermission = "Intermission",
    lobby = "Lobby",
    gameover = "Game Over",
    defeat = "Defeat",
    victory = "Victory",
    results = "Results",
}

local connections: { RBXScriptConnection } = {}
local cleanupTasks: { () -> () } = {}

local hudGui: ScreenGui? = nil
local hudContainer: Frame? = nil
local timerLabel: TextLabel? = nil
local waveLabel: TextLabel? = nil
local lanesPanel: Frame? = nil
local lanesContainer: Frame? = nil
local safePadding: UIPadding? = nil
local cameraViewportConnection: RBXScriptConnection? = nil

local lanePanels: { [number]: {
    frame: Frame,
    fill: Frame,
    flash: Frame,
    hpLabel: TextLabel,
    laneLabel: TextLabel,
    shieldLabel: TextLabel,
    fillTween: Tween?,
    flashTween: Tween?,
    percent: number,
    currentHp: number,
    maxHp: number,
} } = {}

local counterState = {
    coins = {
        total = 0,
        animator = nil :: any,
        valueLabel = nil :: TextLabel?,
        deltaLabel = nil :: TextLabel?,
        deltaBasePosition = nil :: UDim2?,
        deltaTween = nil :: Tween?,
        deltaConnection = nil :: RBXScriptConnection?,
    },
    points = {
        total = 0,
        animator = nil :: any,
        valueLabel = nil :: TextLabel?,
        deltaLabel = nil :: TextLabel?,
        deltaBasePosition = nil :: UDim2?,
        deltaTween = nil :: Tween?,
        deltaConnection = nil :: RBXScriptConnection?,
    },
}

local statusState = {
    phase = "Lobby",
    wave = 0,
    level = 0,
    countdownActive = false,
    countdownEndsAt = nil :: number?,
    staticSeconds = nil :: number?,
}

local laneState = {
    count = 0,
    shieldActive = false,
    shieldExpiresAt = nil :: number?,
}

local currentArenaFilter: string? = nil

local function getSafeInsets(): (Vector2, Vector2)
    local insetTopLeft, insetBottomRight = GuiService:GetGuiInset()
    local ok, safeInset = pcall(function()
        return GuiService:GetSafeAreaInset()
    end)
    if ok and typeof(safeInset) == "Rect" then
        local minVector = (safeInset :: Rect).Min
        local maxVector = (safeInset :: Rect).Max
        if typeof(minVector) == "Vector2" then
            insetTopLeft = Vector2.new(math.max(insetTopLeft.X, minVector.X), math.max(insetTopLeft.Y, minVector.Y))
        end
        if typeof(maxVector) == "Vector2" then
            insetBottomRight = Vector2.new(math.max(insetBottomRight.X, maxVector.X), math.max(insetBottomRight.Y, maxVector.Y))
        end
    end
    return insetTopLeft, insetBottomRight
end

local function updateSafePadding()
    if not safePadding then
        return
    end
    local insetTopLeft, insetBottomRight = getSafeInsets()
    safePadding.PaddingTop = UDim.new(0, math.floor(insetTopLeft.Y + 0.5))
    safePadding.PaddingLeft = UDim.new(0, math.floor(insetTopLeft.X + 0.5))
    safePadding.PaddingBottom = UDim.new(0, math.floor(insetBottomRight.Y + 0.5))
    safePadding.PaddingRight = UDim.new(0, math.floor(insetBottomRight.X + 0.5))
end

local function connectCameraViewportListener(camera: Camera?)
    if cameraViewportConnection then
        cameraViewportConnection:Disconnect()
        cameraViewportConnection = nil
    end
    if not camera then
        return
    end
    cameraViewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        updateSafePadding()
    end)
end

local function initSafeAreaListeners()
    local properties = { "SafeAreaInsetTop", "SafeAreaInsetBottom", "SafeAreaInsetLeft", "SafeAreaInsetRight" }
    for _, property in ipairs(properties) do
        local ok, signal = pcall(function()
            return GuiService:GetPropertyChangedSignal(property)
        end)
        if ok and signal then
            table.insert(connections, (signal :: any):Connect(function()
                updateSafePadding()
            end))
        end
    end

    connectCameraViewportListener(workspace.CurrentCamera)
    table.insert(connections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        connectCameraViewportListener(workspace.CurrentCamera)
        updateSafePadding()
    end))
end

local function disconnectAll()
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function runCleanupTasks()
    for _, taskFn in ipairs(cleanupTasks) do
        local ok, err = pcall(taskFn)
        if not ok then
            warn("[HUDController] Cleanup task failed:", err)
        end
    end
    table.clear(cleanupTasks)
end

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

table.insert(cleanupTasks, function()
    if cameraViewportConnection then
        cameraViewportConnection:Disconnect()
        cameraViewportConnection = nil
    end
end)

local function onDestroy()
    disconnectAll()
    runCleanupTasks()
    lanePanels = {}
    hudGui = nil
    hudContainer = nil
    timerLabel = nil
    waveLabel = nil
    lanesPanel = nil
    lanesContainer = nil
    safePadding = nil
    if cameraViewportConnection then
        cameraViewportConnection:Disconnect()
        cameraViewportConnection = nil
    end
    safeAreaFrame = nil
    safeAreaPadding = nil
    lastSafeAreaInsets = { left = -1, top = -1, right = -1, bottom = -1 }
end

script.Destroying:Connect(onDestroy)

local ancestryConnection = localPlayer.AncestryChanged:Connect(function(_, parent)
    if parent == nil then
        onDestroy()
    end
end)
table.insert(connections, ancestryConnection)

local function formatNumber(value: number): string
    local intValue = if value >= 0 then math.floor(value + 0.5) else math.ceil(value - 0.5)
    local sign = ""
    if intValue < 0 then
        sign = "-"
        intValue = math.abs(intValue)
    end
    local formatted = tostring(intValue)
    local k
    while true do
        formatted, k = string.gsub(formatted, "^(%d+)(%d%d%d)", "%1,%2")
        if k == 0 then
            break
        end
    end
    return sign .. formatted
end

local function formatTime(seconds: number): string
    local numeric = math.max(0, seconds)
    local whole = math.floor(numeric + 0.5)
    local minutes = math.floor(whole / 60)
    local remainder = whole % 60
    if minutes > 0 then
        return string.format("%d:%02d", minutes, remainder)
    end
    return tostring(remainder)
end

local function createAnimator(initialValue: number, onStep: (number) -> ())
    local valueObject = Instance.new("NumberValue")
    valueObject.Value = initialValue
    local connection = valueObject:GetPropertyChangedSignal("Value"):Connect(function()
        onStep(valueObject.Value)
    end)

    local animator = {
        valueObject = valueObject,
        tween = nil :: Tween?,
    }

    function animator:setTarget(targetValue: number)
        local current = valueObject.Value
        local delta = math.abs(targetValue - current)
        local duration = math.clamp(COUNTER_SPEED_FACTOR * delta + COUNTER_ANIMATION_MIN, COUNTER_ANIMATION_MIN, COUNTER_ANIMATION_MAX)
        if self.tween then
            self.tween:Cancel()
            self.tween = nil
        end
        self.tween = TweenService:Create(valueObject, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Value = targetValue,
        })
        self.tween:Play()
    end

    function animator:jump(targetValue: number)
        if self.tween then
            self.tween:Cancel()
            self.tween = nil
        end
        valueObject.Value = targetValue
    end

    function animator:destroy()
        if self.tween then
            self.tween:Cancel()
            self.tween = nil
        end
        connection:Disconnect()
        valueObject:Destroy()
    end

    table.insert(cleanupTasks, function()
        animator:destroy()
    end)

    return animator
end

local function playDelta(counter, delta: number)
    local label = counter.deltaLabel
    if not label then
        return
    end

    if counter.deltaTween then
        counter.deltaTween:Cancel()
        counter.deltaTween = nil
    end
    if counter.deltaConnection then
        counter.deltaConnection:Disconnect()
        counter.deltaConnection = nil
    end

    label.Position = counter.deltaBasePosition or label.Position
    label.TextTransparency = 0
    label.Text = string.format("%+d", delta >= 0 and math.floor(delta + 0.5) or math.ceil(delta - 0.5))
    if delta >= 0 then
        label.TextColor3 = activePalette.deltaGain
    else
        label.TextColor3 = activePalette.deltaLoss
    end

    local targetPosition = (counter.deltaBasePosition or label.Position) + UDim2.new(0, 0, 0, -14)
    local tween = TweenService:Create(label, TweenInfo.new(DELTA_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Position = targetPosition,
        TextTransparency = 1,
    })
    counter.deltaTween = tween
    counter.deltaConnection = tween.Completed:Connect(function()
        if counter.deltaTween == tween then
            counter.deltaTween = nil
        end
        if counter.deltaConnection then
            counter.deltaConnection:Disconnect()
            counter.deltaConnection = nil
        end
        label.Position = counter.deltaBasePosition or label.Position
    end)
    tween:Play()
end

local function updateCounter(counter, newValue: number)
    local animator = counter.animator
    local valueLabel = counter.valueLabel
    if not animator or not valueLabel then
        return
    end

    local clamped = math.max(0, math.floor(newValue + 0.5))
    local delta = clamped - counter.total
    counter.total = clamped
    animator:setTarget(clamped)
    if delta ~= 0 then
        playDelta(counter, delta)
    end
end

local function applyCounterInstant(counter, newValue: number)
    local animator = counter.animator
    local valueLabel = counter.valueLabel
    if not animator or not valueLabel then
        return
    end
    local clamped = math.max(0, math.floor(newValue + 0.5))
    counter.total = clamped
    animator:jump(clamped)
end

local function determineFriendlyPhase(): string
    local phase = statusState.phase
    if typeof(phase) == "string" and phase ~= "" then
        local lower = string.lower(phase)
        return FRIENDLY_PHASE[lower] or phase
    end
    if statusState.countdownActive then
        return "Prep"
    end
    if statusState.wave > 0 then
        return "Wave"
    end
    return "Ready"
end

local lastTimerText: string? = nil
local function refreshTimerLabel()
    if not timerLabel then
        return
    end

    local phaseText = determineFriendlyPhase()
    local remaining: number? = nil

    if statusState.countdownActive and statusState.countdownEndsAt then
        local seconds = math.max(0, statusState.countdownEndsAt - os.clock())
        if seconds <= 0 then
            statusState.countdownActive = false
            statusState.countdownEndsAt = nil
            statusState.staticSeconds = 0
        else
            remaining = seconds
        end
    end

    if not remaining and statusState.staticSeconds then
        remaining = statusState.staticSeconds
    end

    local display: string
    if remaining then
        display = string.format("%s: %s", phaseText, formatTime(remaining))
    else
        display = phaseText
    end

    if display ~= lastTimerText then
        timerLabel.Text = display
        lastTimerText = display
    end
end

local lastWaveText: string? = nil
local function refreshWaveLabel()
    if not waveLabel then
        return
    end

    local text: string
    if statusState.wave <= 0 then
        local phase = determineFriendlyPhase()
        text = string.format("Level %d — %s", math.max(statusState.level, 0), phase)
    else
        text = string.format("Level %d — Wave %d", math.max(statusState.level, 0), math.max(statusState.wave, 0))
    end

    if text ~= lastWaveText then
        waveLabel.Text = text
        lastWaveText = text
    end
end

local function computeLanePanelWidth(count: number): number
    if count <= 0 then
        return LANE_PANEL_MIN_WIDTH
    end
    local width = count * LANE_PANEL_WIDTH + math.max(0, count - 1) * LANE_PANEL_PADDING + 24
    width = math.clamp(width, LANE_PANEL_MIN_WIDTH, LANE_PANEL_MAX_WIDTH)
    return width
end

local function updateShieldLabels()
    local active = laneState.shieldActive
    local remainingText: string? = nil
    if active and laneState.shieldExpiresAt then
        local remaining = math.max(0, laneState.shieldExpiresAt - os.clock())
        if remaining <= 0 then
            laneState.shieldActive = false
            laneState.shieldExpiresAt = nil
        else
            remainingText = string.format("Shield %ds", math.ceil(remaining))
        end
    end

    local palette = activePalette
    for _, panel in pairs(lanePanels) do
        panel.flash.BackgroundColor3 = palette.damageFlash
        if active then
            panel.shieldLabel.TextTransparency = 0
            panel.shieldLabel.Text = remainingText or "Shield"
            panel.fill.BackgroundColor3 = palette.hpShield
        else
            panel.shieldLabel.TextTransparency = 1
            panel.fill.BackgroundColor3 = colorForPercent(panel.percent)
        end
    end
end

local function setLaneCount(count: number)
    count = math.max(0, math.floor(count + 0.5))
    if laneState.count == count then
        return
    end
    laneState.count = count

    if lanesPanel then
        lanesPanel.Visible = count > 0
        lanesPanel.Size = UDim2.new(0, computeLanePanelWidth(count), 0, LANE_PANEL_HEIGHT)
    end

    if lanesContainer then
        lanesContainer.Size = UDim2.new(1, -16, 1, -48)
    end

    if count <= 0 then
        for _, panel in pairs(lanePanels) do
            if panel.fillTween then
                panel.fillTween:Cancel()
                panel.fillTween = nil
            end
            if panel.flashTween then
                panel.flashTween:Cancel()
                panel.flashTween = nil
            end
            panel.frame:Destroy()
        end
        table.clear(lanePanels)
        return
    end

    for index = 1, count do
        if not lanePanels[index] and lanesContainer then
            local frame = Instance.new("Frame")
            frame.Name = string.format("Lane_%d", index)
            frame.LayoutOrder = index
            frame.Size = UDim2.new(0, LANE_PANEL_WIDTH, 1, -12)
            frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
            frame.BackgroundTransparency = 0.1
            frame.BorderSizePixel = 0
            frame.Parent = lanesContainer

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 8)
            corner.Parent = frame

            local laneLabel = Instance.new("TextLabel")
            laneLabel.Name = "LaneLabel"
            laneLabel.AnchorPoint = Vector2.new(0.5, 0)
            laneLabel.Position = UDim2.new(0.5, 0, 0, 6)
            laneLabel.Size = UDim2.new(1, -12, 0, 18)
            laneLabel.BackgroundTransparency = 1
            laneLabel.Font = Enum.Font.GothamSemibold
            laneLabel.TextSize = 14
            laneLabel.TextColor3 = Color3.fromRGB(215, 215, 215)
            laneLabel.Text = string.format("Lane %d", index)
            laneLabel.Parent = frame

            local shieldLabel = Instance.new("TextLabel")
            shieldLabel.Name = "ShieldLabel"
            shieldLabel.AnchorPoint = Vector2.new(0.5, 0)
            shieldLabel.Position = UDim2.new(0.5, 0, 0, 26)
            shieldLabel.Size = UDim2.new(1, -12, 0, 16)
            shieldLabel.BackgroundTransparency = 1
            shieldLabel.Font = Enum.Font.GothamBold
            shieldLabel.TextSize = 12
            shieldLabel.TextColor3 = Color3.fromRGB(140, 210, 255)
            shieldLabel.TextTransparency = 1
            shieldLabel.Text = "Shield"
            shieldLabel.Parent = frame

            local barHolder = Instance.new("Frame")
            barHolder.Name = "Bar"
            barHolder.AnchorPoint = Vector2.new(0.5, 0)
            barHolder.Position = UDim2.new(0.5, 0, 0, 44)
            barHolder.Size = UDim2.new(1, -16, 0, 64)
            barHolder.BackgroundTransparency = 1
            barHolder.Parent = frame

            local barBackground = Instance.new("Frame")
            barBackground.Name = "Background"
            barBackground.Size = UDim2.new(1, 0, 1, 0)
            barBackground.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
            barBackground.BackgroundTransparency = 0.15
            barBackground.BorderSizePixel = 0
            barBackground.Parent = barHolder

            local barCorner = Instance.new("UICorner")
            barCorner.CornerRadius = UDim.new(0, 6)
            barCorner.Parent = barBackground

            local fill = Instance.new("Frame")
            fill.Name = "Fill"
            fill.AnchorPoint = Vector2.new(0, 1)
            fill.Position = UDim2.new(0, 0, 1, 0)
            fill.Size = UDim2.new(1, 0, 0, 0)
            fill.BackgroundColor3 = colorForPercent(1)
            fill.BorderSizePixel = 0
            fill.Parent = barBackground

            local fillCorner = Instance.new("UICorner")
            fillCorner.CornerRadius = UDim.new(0, 6)
            fillCorner.Parent = fill

            local flash = Instance.new("Frame")
            flash.Name = "DamageFlash"
            flash.Size = UDim2.new(1, 0, 1, 0)
            flash.BackgroundColor3 = activePalette.damageFlash
            flash.BackgroundTransparency = 1
            flash.BorderSizePixel = 0
            flash.ZIndex = 2
            flash.Parent = barBackground

            local flashCorner = Instance.new("UICorner")
            flashCorner.CornerRadius = UDim.new(0, 6)
            flashCorner.Parent = flash

            local hpLabel = Instance.new("TextLabel")
            hpLabel.Name = "HPLabel"
            hpLabel.AnchorPoint = Vector2.new(0.5, 1)
            hpLabel.Position = UDim2.new(0.5, 0, 1, -6)
            hpLabel.Size = UDim2.new(1, -12, 0, 18)
            hpLabel.BackgroundTransparency = 1
            hpLabel.Font = Enum.Font.Gotham
            hpLabel.TextSize = 13
            hpLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
            hpLabel.Text = "0 / 0"
            hpLabel.Parent = frame

            lanePanels[index] = {
                frame = frame,
                fill = fill,
                flash = flash,
                hpLabel = hpLabel,
                laneLabel = laneLabel,
                shieldLabel = shieldLabel,
                fillTween = nil,
                flashTween = nil,
                percent = 1,
                currentHp = 0,
                maxHp = 0,
            }
        end
    end

    for index, panel in pairs(lanePanels) do
        if index > count then
            if panel.fillTween then
                panel.fillTween:Cancel()
            end
            if panel.flashTween then
                panel.flashTween:Cancel()
            end
            panel.frame:Destroy()
            lanePanels[index] = nil
        end
    end

    updateShieldLabels()
end

local function ensureLaneContainer()
    if lanesPanel then
        return
    end

    if not hudContainer then
        return
    end

    lanesPanel = Instance.new("Frame")
    lanesPanel.Name = "LanesPanel"
    lanesPanel.AnchorPoint = Vector2.new(0.5, 1)
    lanesPanel.Position = UDim2.new(0.5, 0, 1, -36)
    lanesPanel.Size = UDim2.new(0, LANE_PANEL_MIN_WIDTH, 0, LANE_PANEL_HEIGHT)
    lanesPanel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    lanesPanel.BackgroundTransparency = 0.2
    lanesPanel.BorderSizePixel = 0
    lanesPanel.Visible = false
    lanesPanel.Parent = hudContainer

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = lanesPanel

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Transparency = 0.85
    stroke.Parent = lanesPanel

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.AnchorPoint = Vector2.new(0.5, 0)
    title.Position = UDim2.new(0.5, 0, 0, 8)
    title.Size = UDim2.new(1, -16, 0, 22)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 16
    title.TextColor3 = Color3.fromRGB(240, 240, 240)
    title.Text = "Target Lanes"
    title.Parent = lanesPanel

    lanesContainer = Instance.new("Frame")
    lanesContainer.Name = "LaneContainer"
    lanesContainer.Position = UDim2.new(0, 8, 0, 32)
    lanesContainer.Size = UDim2.new(1, -16, 1, -48)
    lanesContainer.BackgroundTransparency = 1
    lanesContainer.Parent = lanesPanel

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding = UDim.new(0, LANE_PANEL_PADDING)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = lanesContainer

    setLaneCount(laneState.count)
end

local function createCounters()
    if not hudContainer then
        return
    end

    local frame = Instance.new("Frame")
    frame.Name = "Counters"
    frame.Position = UDim2.new(0, 20, 0, 20)
    frame.Size = UDim2.new(0, 280, 0, 120)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    frame.BackgroundTransparency = 0.2
    frame.BorderSizePixel = 0
    frame.Parent = hudContainer

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Transparency = 0.85
    stroke.Parent = frame

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 10)
    padding.PaddingBottom = UDim.new(0, 10)
    padding.PaddingLeft = UDim.new(0, 12)
    padding.PaddingRight = UDim.new(0, 12)
    padding.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 10)
    layout.Parent = frame

    local function createRow(name: string, layoutOrder: number)
        local row = Instance.new("Frame")
        row.Name = name .. "Row"
        row.BackgroundTransparency = 1
        row.Size = UDim2.new(1, 0, 0, 40)
        row.LayoutOrder = layoutOrder
        row.Parent = frame

        local label = Instance.new("TextLabel")
        label.Name = "Label"
        label.BackgroundTransparency = 1
        label.Size = UDim2.new(0.4, 0, 1, 0)
        label.Font = Enum.Font.GothamSemibold
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextColor3 = Color3.fromRGB(200, 200, 200)
        label.TextSize = 16
        label.Text = string.upper(name)
        label.Parent = row

        local valueLabel = Instance.new("TextLabel")
        valueLabel.Name = "Value"
        valueLabel.AnchorPoint = Vector2.new(1, 0.5)
        valueLabel.Position = UDim2.new(1, 0, 0.5, 0)
        valueLabel.Size = UDim2.new(0.6, 0, 1, 0)
        valueLabel.BackgroundTransparency = 1
        valueLabel.Font = Enum.Font.GothamBold
        valueLabel.TextXAlignment = Enum.TextXAlignment.Right
        valueLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        valueLabel.TextSize = 22
        valueLabel.Text = "0"
        valueLabel.Parent = row

        local deltaLabel = Instance.new("TextLabel")
        deltaLabel.Name = "Delta"
        deltaLabel.AnchorPoint = Vector2.new(1, 1)
        deltaLabel.Position = UDim2.new(1, 0, 1, -4)
        deltaLabel.Size = UDim2.new(0.6, 0, 0, 22)
        deltaLabel.BackgroundTransparency = 1
        deltaLabel.Font = Enum.Font.GothamSemibold
        deltaLabel.TextXAlignment = Enum.TextXAlignment.Right
        deltaLabel.TextColor3 = activePalette.deltaGain
        deltaLabel.TextSize = 14
        deltaLabel.TextTransparency = 1
        deltaLabel.Text = "+0"
        deltaLabel.Parent = row

        return valueLabel, deltaLabel
    end

    local coinsValue, coinsDelta = createRow("Coins", 1)
    local pointsValue, pointsDelta = createRow("Points", 2)

    counterState.coins.valueLabel = coinsValue
    counterState.coins.deltaLabel = coinsDelta
    counterState.coins.deltaBasePosition = coinsDelta.Position
    counterState.coins.animator = createAnimator(0, function(value)
        if counterState.coins.valueLabel then
            counterState.coins.valueLabel.Text = formatNumber(value)
        end
    end)

    counterState.points.valueLabel = pointsValue
    counterState.points.deltaLabel = pointsDelta
    counterState.points.deltaBasePosition = pointsDelta.Position
    counterState.points.animator = createAnimator(0, function(value)
        if counterState.points.valueLabel then
            counterState.points.valueLabel.Text = formatNumber(value)
        end
    end)
end

local function createStatusPanel()
    if not hudContainer then
        return
    end

    local panel = Instance.new("Frame")
    panel.Name = "StatusPanel"
    panel.AnchorPoint = Vector2.new(0.5, 0)
    panel.Position = UDim2.new(0.5, 0, 0, 18)
    panel.Size = UDim2.new(0, 260, 0, 84)
    panel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    panel.BackgroundTransparency = 0.2
    panel.BorderSizePixel = 0
    panel.Parent = hudContainer

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = panel

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Color = Color3.fromRGB(255, 255, 255)
    stroke.Transparency = 0.85
    stroke.Parent = panel

    timerLabel = Instance.new("TextLabel")
    timerLabel.Name = "TimerLabel"
    timerLabel.AnchorPoint = Vector2.new(0.5, 0)
    timerLabel.Position = UDim2.new(0.5, 0, 0, 12)
    timerLabel.Size = UDim2.new(1, -24, 0, 38)
    timerLabel.BackgroundTransparency = 1
    timerLabel.Font = Enum.Font.GothamBold
    timerLabel.TextSize = 26
    timerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    timerLabel.TextXAlignment = Enum.TextXAlignment.Center
    timerLabel.Text = "Lobby"
    timerLabel.Parent = panel

    waveLabel = Instance.new("TextLabel")
    waveLabel.Name = "WaveLabel"
    waveLabel.AnchorPoint = Vector2.new(0.5, 0)
    waveLabel.Position = UDim2.new(0.5, 0, 0, 48)
    waveLabel.Size = UDim2.new(1, -24, 0, 28)
    waveLabel.BackgroundTransparency = 1
    waveLabel.Font = Enum.Font.Gotham
    waveLabel.TextSize = 18
    waveLabel.TextColor3 = Color3.fromRGB(210, 210, 210)
    waveLabel.TextXAlignment = Enum.TextXAlignment.Center
    waveLabel.Text = "Level 0 — Lobby"
    waveLabel.Parent = panel

    refreshTimerLabel()
    refreshWaveLabel()
end

local function createHudGui()
    if hudGui then
        return
    end

    hudGui = Instance.new("ScreenGui")
    hudGui.Name = HUD_NAME
    hudGui.IgnoreGuiInset = true
    hudGui.ResetOnSpawn = false
    hudGui.DisplayOrder = 10
    hudGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    if playerGui then
        hudGui.Parent = playerGui
    else
        hudGui.Parent = localPlayer:WaitForChild("PlayerGui")
    end

    safeAreaFrame = Instance.new("Frame")
    safeAreaFrame.Name = "SafeArea"
    safeAreaFrame.Size = UDim2.new(1, 0, 1, 0)
    safeAreaFrame.BackgroundTransparency = 1
    safeAreaFrame.BorderSizePixel = 0
    safeAreaFrame.Parent = hudGui

    safeAreaPadding = Instance.new("UIPadding")
    safeAreaPadding.Name = "SafeAreaPadding"
    safeAreaPadding.Parent = safeAreaFrame

    hudContainer = Instance.new("Frame")
    hudContainer.Name = HUD_SECTION_NAME
    hudContainer.Size = UDim2.new(1, 0, 1, 0)
    hudContainer.BackgroundTransparency = 1
    hudContainer.Parent = safeAreaFrame

    updateSafeAreaPadding()
    updateCameraViewportConnection(Workspace.CurrentCamera)

    table.insert(connections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        updateCameraViewportConnection(Workspace.CurrentCamera)
        updateSafeAreaPadding()
    end))

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

    safePadding = Instance.new("UIPadding")
    safePadding.Name = "SafeAreaPadding"
    safePadding.Parent = hudContainer
    updateSafePadding()
    initSafeAreaListeners()

    createCounters()
    createStatusPanel()
    ensureLaneContainer()
    applyPalette(localPlayer:GetAttribute("ColorblindPalette"), true)
end

createHudGui()

local function ensureHudParent()
    if not hudGui then
        return
    end
    local currentParent = hudGui.Parent
    local desiredParent = localPlayer:FindFirstChildOfClass("PlayerGui")
    if desiredParent and currentParent ~= desiredParent then
        hudGui.Parent = desiredParent
        playerGui = desiredParent
    end
end

table.insert(connections, localPlayer.ChildAdded:Connect(function(child)
    if child:IsA("PlayerGui") then
        playerGui = child
        ensureHudParent()
    end
end))

table.insert(connections, localPlayer.ChildRemoved:Connect(function(child)
    if child:IsA("PlayerGui") then
        playerGui = nil
        task.defer(ensureHudParent)
    end
end))

local function updateArenaFilter()
    local arenaAttr = localPlayer:GetAttribute("ArenaId")
    if arenaAttr ~= nil then
        currentArenaFilter = tostring(arenaAttr)
    else
        currentArenaFilter = nil
    end
end

updateArenaFilter()

table.insert(connections, localPlayer:GetAttributeChangedSignal("ArenaId"):Connect(updateArenaFilter))

local function arenaMatches(arenaId: any): boolean
    if currentArenaFilter == nil then
        return true
    end
    if arenaId == nil then
        return false
    end
    return tostring(arenaId) == currentArenaFilter
end

local function applyShieldStatus(active: boolean, remaining: number?)
    laneState.shieldActive = active
    if active and remaining and remaining > 0 then
        laneState.shieldExpiresAt = os.clock() + remaining
    else
        laneState.shieldExpiresAt = nil
    end
    updateShieldLabels()
end

local function colorForPercent(pct: number): Color3
    local palette = activePalette
    if laneState.shieldActive then
        return palette.hpShield
    end
    if pct >= 0.6 then
        return palette.hpHigh
    elseif pct >= 0.3 then
        return palette.hpMid
    else
        return palette.hpLow
    end
end

local function refreshPaletteVisuals()
    local palette = activePalette

    local coinsDelta = counterState.coins.deltaLabel
    if coinsDelta then
        local text = coinsDelta.Text
        if typeof(text) == "string" and string.sub(text, 1, 1) == "-" then
            coinsDelta.TextColor3 = palette.deltaLoss
        else
            coinsDelta.TextColor3 = palette.deltaGain
        end
    end

    local pointsDelta = counterState.points.deltaLabel
    if pointsDelta then
        local text = pointsDelta.Text
        if typeof(text) == "string" and string.sub(text, 1, 1) == "-" then
            pointsDelta.TextColor3 = palette.deltaLoss
        else
            pointsDelta.TextColor3 = palette.deltaGain
        end
    end

    updateShieldLabels()
end

local function applyPalette(paletteId: any, force: boolean?)
    local normalized = resolvePaletteId(paletteId)
    if force or activePaletteId ~= normalized then
        activePaletteId = normalized
        activePalette = COLORBLIND_PALETTES[normalized] or COLORBLIND_PALETTES[DEFAULT_PALETTE_ID]
    end
    refreshPaletteVisuals()
end

local function updateLane(laneId: number, payload: { [string]: any })
    ensureLaneContainer()

    local laneCountValue = payload.laneCount or payload.LaneCount
    if typeof(laneCountValue) == "number" then
        setLaneCount(laneCountValue)
    end

    local shieldActive = payload.shieldActive
    if shieldActive == nil then
        shieldActive = payload.ShieldActive
    end
    if typeof(shieldActive) == "boolean" then
        local remaining = payload.shieldRemaining or payload.ShieldRemaining
        local numericRemaining = if typeof(remaining) == "number" then remaining else nil
        applyShieldStatus(shieldActive, numericRemaining)
    end

    if laneId <= 0 then
        return
    end

    setLaneCount(math.max(laneState.count, laneId))

    local panel = lanePanels[laneId]
    if not panel then
        return
    end

    local percent = payload.pct or payload.Pct or payload.percent or payload.Percent
    if typeof(percent) ~= "number" then
        percent = panel.percent
    end

    local maxHp = payload.maxHp or payload.MaxHP
    if typeof(maxHp) == "number" then
        panel.maxHp = math.max(0, math.floor(maxHp + 0.5))
    end

    local currentHp = payload.currentHp or payload.CurrentHP
    if typeof(currentHp) == "number" then
        panel.currentHp = math.max(0, math.floor(currentHp + 0.5))
    elseif panel.maxHp > 0 and typeof(percent) == "number" then
        panel.currentHp = math.max(0, math.floor(panel.maxHp * percent + 0.5))
    end

    local previousPercent = panel.percent
    if typeof(percent) == "number" then
        panel.percent = math.clamp(percent, 0, 1)
    end

    if panel.maxHp > 0 then
        panel.hpLabel.Text = string.format("%s / %s", formatNumber(panel.currentHp), formatNumber(panel.maxHp))
    else
        panel.hpLabel.Text = formatNumber(panel.currentHp)
    end

    if panel.fillTween then
        panel.fillTween:Cancel()
        panel.fillTween = nil
    end

    local fillGoal = panel.percent
    panel.fillTween = TweenService:Create(panel.fill, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Size = UDim2.new(1, 0, fillGoal, 0),
    })
    panel.fillTween:Play()

    panel.fill.BackgroundColor3 = colorForPercent(panel.percent)

    if panel.flashTween then
        panel.flashTween:Cancel()
        panel.flashTween = nil
    end

    if previousPercent and panel.percent < previousPercent - 0.001 then
        panel.flash.BackgroundTransparency = 0.3
        panel.flash.BackgroundColor3 = activePalette.damageFlash
        panel.flashTween = TweenService:Create(panel.flash, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            BackgroundTransparency = 1,
        })
        panel.flashTween:Play()
    end
end

local function handleCoinPayload(payload: { [string]: any })
    local totalCoins = payload.totalCoins or payload.TotalCoins
    if typeof(totalCoins) == "number" then
        updateCounter(counterState.coins, totalCoins)
    elseif typeof(payload.coins) == "number" or typeof(payload.Coins) == "number" then
        local delta = payload.coins or payload.Coins
        updateCounter(counterState.coins, counterState.coins.total + (delta or 0))
    end

    local totalPoints = payload.totalPoints or payload.TotalPoints
    if typeof(totalPoints) == "number" then
        updateCounter(counterState.points, totalPoints)
    elseif typeof(payload.points) == "number" or typeof(payload.Points) == "number" then
        local delta = payload.points or payload.Points
        updateCounter(counterState.points, counterState.points.total + (delta or 0))
    end
end

local function onCoinEvent(firstArg, secondArg)
    if typeof(firstArg) == "table" then
        handleCoinPayload(firstArg)
        if typeof(secondArg) == "table" then
            handleCoinPayload(secondArg)
        end
        return
    end

    local payload: { [string]: any } = {}
    if typeof(firstArg) == "number" then
        payload.coins = firstArg
    end
    if typeof(secondArg) == "number" then
        payload.points = secondArg
    elseif typeof(secondArg) == "table" then
        for key, value in pairs(secondArg) do
            payload[key] = value
        end
    end
    handleCoinPayload(payload)
end

local function parseSeconds(value: any): number?
    if typeof(value) == "number" then
        return value
    end
    if typeof(value) == "string" then
        local numeric = tonumber(value)
        if numeric then
            return numeric
        end
    end
    return nil
end

local function onPrepEvent(firstArg, secondArg)
    local payload: { [string]: any } = {}

    if typeof(firstArg) == "table" then
        for key, value in pairs(firstArg) do
            payload[key] = value
        end
        if typeof(secondArg) == "table" then
            for key, value in pairs(secondArg) do
                payload[key] = value
            end
        end
    else
        payload.seconds = firstArg
        if typeof(secondArg) == "boolean" then
            payload.stop = secondArg
        elseif typeof(secondArg) == "table" then
            for key, value in pairs(secondArg) do
                payload[key] = value
            end
        end
    end

    local arenaId = payload.arenaId or payload.ArenaId
    if arenaId ~= nil and not arenaMatches(arenaId) then
        return
    end

    local seconds = parseSeconds(payload.seconds or payload.Seconds)
    local stopValue = payload.stop
    if stopValue == nil then
        stopValue = payload.Stop
    end
    local stop = stopValue and true or false

    if stop then
        statusState.countdownActive = false
        statusState.countdownEndsAt = nil
        statusState.staticSeconds = seconds and math.max(0, math.floor(seconds + 0.5)) or nil
    elseif seconds ~= nil then
        local rounded = math.max(0, math.floor(seconds + 0.5))
        if rounded <= 0 then
            statusState.countdownActive = false
            statusState.countdownEndsAt = nil
            statusState.staticSeconds = 0
        else
            statusState.countdownActive = true
            statusState.countdownEndsAt = os.clock() + rounded
            statusState.staticSeconds = rounded
        end
    end

    if statusState.phase == nil or statusState.phase == "" or string.lower(statusState.phase) == "lobby" then
        statusState.phase = "Prep"
    end

    refreshTimerLabel()
    refreshWaveLabel()
end

local function onWaveEvent(firstArg, secondArg, thirdArg)
    local payload: { [string]: any } = {}

    if typeof(firstArg) == "table" then
        for key, value in pairs(firstArg) do
            payload[key] = value
        end
        if typeof(secondArg) == "table" then
            for key, value in pairs(secondArg) do
                payload[key] = value
            end
        end
    else
        payload.level = firstArg
        if typeof(secondArg) == "number" then
            payload.wave = secondArg
        elseif typeof(secondArg) == "table" then
            for key, value in pairs(secondArg) do
                payload[key] = value
            end
        end
        if typeof(thirdArg) == "table" then
            for key, value in pairs(thirdArg) do
                payload[key] = value
            end
        end
    end

    local arenaId = payload.arenaId or payload.ArenaId
    if arenaId ~= nil and not arenaMatches(arenaId) then
        return
    end

    local waveValue = payload.wave or payload.Wave or payload.currentWave or payload.CurrentWave
    local levelValue = payload.level or payload.Level
    local phaseValue = payload.phase or payload.Phase

    if typeof(waveValue) == "number" then
        statusState.wave = math.max(0, math.floor(waveValue + 0.5))
    end
    if typeof(levelValue) == "number" then
        statusState.level = math.max(0, math.floor(levelValue + 0.5))
    end
    if typeof(phaseValue) == "string" then
        statusState.phase = phaseValue
    elseif statusState.wave > 0 then
        statusState.phase = "Wave"
    end

    if statusState.phase and string.lower(statusState.phase) ~= "prep" then
        statusState.countdownActive = false
        statusState.countdownEndsAt = nil
        statusState.staticSeconds = nil
    end

    refreshTimerLabel()
    refreshWaveLabel()
end

local function onTargetEvent(payload)
    if typeof(payload) ~= "table" then
        return
    end

    local arenaId = payload.arenaId or payload.ArenaId
    if arenaId ~= nil and not arenaMatches(arenaId) then
        return
    end

    local laneValue = payload.lane or payload.Lane or payload.laneId or payload.LaneId
    local laneId = if typeof(laneValue) == "number" then laneValue else tonumber(laneValue)
    if not laneId then
        return
    end

    local gameOver = payload.gameOver
    if gameOver == nil then
        gameOver = payload.GameOver
    end
    if gameOver then
        statusState.phase = "Defeat"
    end

    updateLane(laneId, payload)
end

local function syncAttributes()
    local coinsAttr = localPlayer:GetAttribute("Coins")
    if typeof(coinsAttr) == "number" then
        applyCounterInstant(counterState.coins, coinsAttr)
    else
        applyCounterInstant(counterState.coins, counterState.coins.total)
    end

    local pointsAttr = localPlayer:GetAttribute("Points")
    if typeof(pointsAttr) == "number" then
        applyCounterInstant(counterState.points, pointsAttr)
    else
        applyCounterInstant(counterState.points, counterState.points.total)
    end

    refreshTimerLabel()
    refreshWaveLabel()
    updateShieldLabels()
end

syncAttributes()

local attributeConnection = localPlayer.AttributeChanged:Connect(function(name)
    if name == "Coins" then
        local value = localPlayer:GetAttribute("Coins")
        if typeof(value) == "number" then
            updateCounter(counterState.coins, value)
        end
    elseif name == "Points" then
        local value = localPlayer:GetAttribute("Points")
        if typeof(value) == "number" then
            updateCounter(counterState.points, value)
        end
    elseif name == "ArenaId" then
        updateArenaFilter()
    elseif name == "ColorblindPalette" then
        applyPalette(localPlayer:GetAttribute("ColorblindPalette"), false)
    end
end)
table.insert(connections, attributeConnection)

if coinRemote then
    table.insert(connections, coinRemote.OnClientEvent:Connect(onCoinEvent))
end

if prepRemote then
    table.insert(connections, prepRemote.OnClientEvent:Connect(onPrepEvent))
end

if waveRemote then
    table.insert(connections, waveRemote.OnClientEvent:Connect(onWaveEvent))
end

if targetRemote then
    table.insert(connections, targetRemote.OnClientEvent:Connect(onTargetEvent))
end

local renderConnection = RunService.RenderStepped:Connect(function()
    if statusState.countdownActive then
        refreshTimerLabel()
    end
    if laneState.shieldActive and laneState.shieldExpiresAt then
        updateShieldLabels()
    end
end)
table.insert(connections, renderConnection)

ensureHudParent()
refreshTimerLabel()
refreshWaveLabel()
updateShieldLabels()
