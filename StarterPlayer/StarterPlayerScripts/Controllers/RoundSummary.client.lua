--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
if not localPlayer then
    return
end

local playerGui = localPlayer:WaitForChild("PlayerGui")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local RemotesModule = remotesFolder:WaitForChild("RemoteBootstrap")

local Remotes = require(RemotesModule)
local roundSummaryRemote: RemoteEvent? = Remotes and Remotes.RE_RoundSummary or nil

if not roundSummaryRemote then
    warn("[RoundSummaryClient] RE_RoundSummary remote is unavailable; summary panel disabled")
    return
end

local screenGui: ScreenGui? = nil
local titleLabel: TextLabel? = nil
local subtitleLabel: TextLabel? = nil
local teamLabels: { [string]: TextLabel } = {}
local playerLabels: { [string]: TextLabel } = {}
local continueButton: TextButton? = nil
local returnButton: TextButton? = nil
local overlayFrame: Frame? = nil

local lastPayload: { [string]: any }? = nil

local TEAM_STATS = {
    { key = "coins", label = "Team Coins" },
    { key = "points", label = "Team Points" },
    { key = "wavesCleared", label = "Waves Cleared" },
    { key = "kos", label = "Team KOs" },
    { key = "tokensUsed", label = "Tokens Used" },
}

local PLAYER_STATS = {
    { key = "coins", label = "Your Coins" },
    { key = "points", label = "Your Points" },
    { key = "kos", label = "Your KOs" },
    { key = "tokensUsed", label = "Tokens Used" },
}

local function formatNumber(value: number): string
    local numeric = if value >= 0 then math.floor(value + 0.5) else math.ceil(value - 0.5)
    local sign = ""
    if numeric < 0 then
        sign = "-"
        numeric = math.abs(numeric)
    end

    local text = tostring(numeric)
    local formatted = text
    while true do
        local replacement
        formatted, replacement = string.gsub(formatted, "^(%d+)(%d%d%d)", "%1,%2")
        if replacement == 0 then
            break
        end
    end

    return sign .. formatted
end

local function sanitizeNumber(value: any): number
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric then
        return 0
    end
    return numeric
end

local function createStatRow(parent: Instance, labelText: string): TextLabel
    local row = Instance.new("Frame")
    row.Name = labelText .. "Row"
    row.BackgroundTransparency = 1
    row.Size = UDim2.new(1, 0, 0, 28)
    row.Parent = parent

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "Name"
    nameLabel.BackgroundTransparency = 1
    nameLabel.Font = Enum.Font.GothamSemibold
    nameLabel.TextColor3 = Color3.fromRGB(210, 214, 228)
    nameLabel.TextSize = 18
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.Size = UDim2.new(1, -120, 1, 0)
    nameLabel.Text = labelText
    nameLabel.Parent = row

    local valueLabel = Instance.new("TextLabel")
    valueLabel.Name = "Value"
    valueLabel.BackgroundTransparency = 1
    valueLabel.Font = Enum.Font.GothamBold
    valueLabel.TextColor3 = Color3.fromRGB(246, 246, 255)
    valueLabel.TextSize = 18
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    valueLabel.AnchorPoint = Vector2.new(1, 0.5)
    valueLabel.Position = UDim2.new(1, 0, 0.5, 0)
    valueLabel.Size = UDim2.new(0, 120, 1, 0)
    valueLabel.Text = "0"
    valueLabel.Parent = row

    return valueLabel
end

local function createSection(parent: Instance, headerText: string, stats: { { key: string, label: string } }): { [string]: TextLabel }
    local section = Instance.new("Frame")
    section.Name = headerText
    section.BackgroundTransparency = 1
    section.Size = UDim2.new(0.5, -12, 1, 0)
    section.Parent = parent

    local header = Instance.new("TextLabel")
    header.Name = "Header"
    header.BackgroundTransparency = 1
    header.Font = Enum.Font.GothamBold
    header.TextColor3 = Color3.fromRGB(240, 242, 250)
    header.TextSize = 22
    header.TextXAlignment = Enum.TextXAlignment.Left
    header.Size = UDim2.new(1, 0, 0, 26)
    header.Text = headerText
    header.Parent = section

    local statsFrame = Instance.new("Frame")
    statsFrame.Name = "Stats"
    statsFrame.BackgroundTransparency = 1
    statsFrame.Position = UDim2.new(0, 0, 0, 32)
    statsFrame.Size = UDim2.new(1, 0, 1, -32)
    statsFrame.Parent = section

    local layout = Instance.new("UIListLayout")
    layout.Name = "StatLayout"
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.VerticalAlignment = Enum.VerticalAlignment.Top
    layout.Padding = UDim.new(0, 8)
    layout.Parent = statsFrame

    local labels: { [string]: TextLabel } = {}
    for _, stat in ipairs(stats) do
        labels[stat.key] = createStatRow(statsFrame, stat.label)
    end

    return labels
end

local function ensureGui(): boolean
    if screenGui and screenGui.Parent then
        return true
    end

    local guiParent = playerGui or localPlayer:FindFirstChildOfClass("PlayerGui")
    if not guiParent then
        return false
    end

    playerGui = guiParent

    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "RoundSummary"
    screenGui.IgnoreGuiInset = true
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.DisplayOrder = 50
    screenGui.Enabled = false
    screenGui.Parent = guiParent

    overlayFrame = Instance.new("Frame")
    overlayFrame.Name = "Overlay"
    overlayFrame.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
    overlayFrame.BackgroundTransparency = 0.35
    overlayFrame.BorderSizePixel = 0
    overlayFrame.Size = UDim2.fromScale(1, 1)
    overlayFrame.Active = true
    overlayFrame.Parent = screenGui

    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.fromScale(0.5, 0.5)
    panel.Size = UDim2.new(0, 480, 0, 420)
    panel.BackgroundColor3 = Color3.fromRGB(22, 24, 32)
    panel.BackgroundTransparency = 0.05
    panel.BorderSizePixel = 0
    panel.Parent = overlayFrame

    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 12)
    panelCorner.Parent = panel

    local panelStroke = Instance.new("UIStroke")
    panelStroke.Thickness = 2
    panelStroke.Transparency = 0.4
    panelStroke.Color = Color3.fromRGB(85, 92, 110)
    panelStroke.Parent = panel

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 28)
    padding.PaddingBottom = UDim.new(0, 32)
    padding.PaddingLeft = UDim.new(0, 32)
    padding.PaddingRight = UDim.new(0, 32)
    padding.Parent = panel

    titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "Title"
    titleLabel.BackgroundTransparency = 1
    titleLabel.Font = Enum.Font.GothamBlack
    titleLabel.TextColor3 = Color3.fromRGB(246, 246, 255)
    titleLabel.TextSize = 32
    titleLabel.TextWrapped = true
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Position = UDim2.new(0, 0, 0, 0)
    titleLabel.Size = UDim2.new(1, 0, 0, 48)
    titleLabel.Text = "Level Complete"
    titleLabel.Parent = panel

    subtitleLabel = Instance.new("TextLabel")
    subtitleLabel.Name = "Subtitle"
    subtitleLabel.BackgroundTransparency = 1
    subtitleLabel.Font = Enum.Font.GothamSemibold
    subtitleLabel.TextColor3 = Color3.fromRGB(198, 204, 216)
    subtitleLabel.TextSize = 20
    subtitleLabel.TextWrapped = true
    subtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
    subtitleLabel.Position = UDim2.new(0, 0, 0, 54)
    subtitleLabel.Size = UDim2.new(1, 0, 0, 28)
    subtitleLabel.Text = ""
    subtitleLabel.Visible = false
    subtitleLabel.Parent = panel

    local sectionsFrame = Instance.new("Frame")
    sectionsFrame.Name = "Sections"
    sectionsFrame.BackgroundTransparency = 1
    sectionsFrame.Position = UDim2.new(0, 0, 0, 98)
    sectionsFrame.Size = UDim2.new(1, 0, 0, 220)
    sectionsFrame.Parent = panel

    local sectionsLayout = Instance.new("UIListLayout")
    sectionsLayout.Name = "SectionsLayout"
    sectionsLayout.FillDirection = Enum.FillDirection.Horizontal
    sectionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    sectionsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    sectionsLayout.Padding = UDim.new(0, 24)
    sectionsLayout.Parent = sectionsFrame

    teamLabels = createSection(sectionsFrame, "Team Totals", TEAM_STATS)
    playerLabels = createSection(sectionsFrame, "Your Stats", PLAYER_STATS)

    local buttonsFrame = Instance.new("Frame")
    buttonsFrame.Name = "Buttons"
    buttonsFrame.AnchorPoint = Vector2.new(0.5, 1)
    buttonsFrame.Position = UDim2.new(0.5, 0, 1, -8)
    buttonsFrame.Size = UDim2.new(1, 0, 0, 56)
    buttonsFrame.BackgroundTransparency = 1
    buttonsFrame.Parent = panel

    local buttonsLayout = Instance.new("UIListLayout")
    buttonsLayout.Name = "ButtonsLayout"
    buttonsLayout.FillDirection = Enum.FillDirection.Horizontal
    buttonsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    buttonsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    buttonsLayout.Padding = UDim.new(0, 16)
    buttonsLayout.Parent = buttonsFrame

    continueButton = Instance.new("TextButton")
    continueButton.Name = "ContinueButton"
    continueButton.AutoButtonColor = true
    continueButton.Size = UDim2.new(0.5, -8, 1, 0)
    continueButton.BackgroundColor3 = Color3.fromRGB(62, 142, 255)
    continueButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    continueButton.Font = Enum.Font.GothamBold
    continueButton.TextSize = 22
    continueButton.Text = "Continue"
    continueButton.Parent = buttonsFrame

    local continueCorner = Instance.new("UICorner")
    continueCorner.CornerRadius = UDim.new(0, 10)
    continueCorner.Parent = continueButton

    returnButton = Instance.new("TextButton")
    returnButton.Name = "ReturnButton"
    returnButton.AutoButtonColor = true
    returnButton.Size = UDim2.new(0.5, -8, 1, 0)
    returnButton.BackgroundColor3 = Color3.fromRGB(224, 76, 84)
    returnButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    returnButton.Font = Enum.Font.GothamBold
    returnButton.TextSize = 22
    returnButton.Text = "Return to Lobby"
    returnButton.Parent = buttonsFrame

    local returnCorner = Instance.new("UICorner")
    returnCorner.CornerRadius = UDim.new(0, 10)
    returnCorner.Parent = returnButton

    continueButton.Activated:Connect(function()
        if screenGui then
            screenGui.Enabled = false
        end
    end)

    returnButton.Activated:Connect(function()
        if screenGui then
            screenGui.Enabled = false
        end

        local payload = lastPayload
        if payload then
            local data = {
                action = "ReturnToLobby",
            }
            if payload.arenaId ~= nil then
                data.arenaId = payload.arenaId
            end
            roundSummaryRemote:FireServer(data)
        else
            roundSummaryRemote:FireServer({ action = "ReturnToLobby" })
        end
    end)

    return true
end

local function updateStats(labels: { [string]: TextLabel }, values: { [string]: any }?)
    for key, label in pairs(labels) do
        if label then
            local rawValue = values and (values[key] or values[string.lower(key)] or values[string.upper(key)]) or 0
            label.Text = formatNumber(sanitizeNumber(rawValue))
        end
    end
end

local function resolveTitle(payload: { [string]: any }): string
    local levelValue = sanitizeNumber(payload.level)
    local outcomeValue = ""
    if typeof(payload.outcome) == "string" then
        outcomeValue = string.lower(payload.outcome)
    end

    if levelValue > 0 then
        if outcomeValue == "victory" then
            return string.format("Level %d Cleared!", levelValue)
        elseif outcomeValue == "defeat" then
            return string.format("Level %d Failed", levelValue)
        end
        return string.format("Level %d Summary", levelValue)
    end

    if outcomeValue == "victory" then
        return "Victory!"
    elseif outcomeValue == "defeat" then
        return "Defeat"
    end

    return "Round Summary"
end

local function applyOutcomeColor(outcome: string)
    if not titleLabel then
        return
    end

    local lowered = string.lower(outcome)
    if lowered == "victory" then
        titleLabel.TextColor3 = Color3.fromRGB(120, 230, 160)
    elseif lowered == "defeat" then
        titleLabel.TextColor3 = Color3.fromRGB(255, 130, 130)
    else
        titleLabel.TextColor3 = Color3.fromRGB(246, 246, 255)
    end
end

local function hidePanel()
    if screenGui then
        screenGui.Enabled = false
    end
end

local function showSummary(payload: { [string]: any })
    if not ensureGui() then
        return
    end

    lastPayload = payload

    if screenGui then
        screenGui.Enabled = true
    end

    local titleText = resolveTitle(payload)
    if titleLabel then
        titleLabel.Text = titleText
    end

    applyOutcomeColor(typeof(payload.outcome) == "string" and payload.outcome or "")

    if subtitleLabel then
        local reasonValue = payload.reason
        if typeof(reasonValue) == "string" and reasonValue ~= "" then
            subtitleLabel.Text = reasonValue
            subtitleLabel.Visible = true
        else
            subtitleLabel.Visible = false
        end
    end

    local totals = if typeof(payload.totals) == "table" then payload.totals else {}
    updateStats(teamLabels, totals)

    local personal = if typeof(payload.player) == "table" then payload.player else {}
    updateStats(playerLabels, personal)
end

roundSummaryRemote.OnClientEvent:Connect(function(payload: any)
    if typeof(payload) ~= "table" then
        return
    end

    showSummary(payload)
end)

localPlayer.AncestryChanged:Connect(function(_, parent)
    if parent == nil then
        hidePanel()
    end
end)

