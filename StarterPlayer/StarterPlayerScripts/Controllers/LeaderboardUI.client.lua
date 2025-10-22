--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
if not localPlayer then
    return
end

local playerGui: PlayerGui = localPlayer:WaitForChild("PlayerGui")

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local remotesModule = require(remotesFolder:WaitForChild("RemoteBootstrap"))

local sessionRemote: RemoteEvent? = remotesModule and remotesModule.RE_SessionLeaderboard or nil
local globalFunction: RemoteFunction? = remotesModule and remotesModule.RF_GetGlobalLeaderboard or nil

local SESSION_ROWS = 10
local GLOBAL_REFRESH_INTERVAL = 30

local backgroundColor = Color3.fromRGB(18, 20, 30)
local highlightColor = Color3.fromRGB(255, 228, 116)
local defaultTextColor = Color3.fromRGB(235, 235, 235)
local placeholderTextColor = Color3.fromRGB(200, 200, 200)
local subtitleTextColor = Color3.fromRGB(210, 210, 210)
local headerTextColor = Color3.fromRGB(255, 255, 255)
local openButtonColor = Color3.fromRGB(26, 29, 44)
local openButtonActiveColor = Color3.fromRGB(38, 41, 58)

local scoreboardVisible = false
local tabToggleActive = false
local globalRequestInFlight = false

local screenGui = playerGui:FindFirstChild("LeaderboardUI")
if screenGui and not screenGui:IsA("ScreenGui") then
    screenGui = nil
end

if not screenGui then
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "LeaderboardUI"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = 20
    screenGui.Parent = playerGui
else
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = math.max(screenGui.DisplayOrder, 20)
    screenGui.Parent = playerGui
end

local function reparentToPlayerGui(newGui: PlayerGui?)
    if not newGui then
        return
    end
    playerGui = newGui
    screenGui.Parent = playerGui
end

localPlayer.ChildAdded:Connect(function(child)
    if child:IsA("PlayerGui") then
        reparentToPlayerGui(child)
    end
end)

localPlayer.ChildRemoved:Connect(function(child)
    if child:IsA("PlayerGui") then
        task.defer(function()
            local replacement = localPlayer:FindFirstChildOfClass("PlayerGui")
            if replacement then
                reparentToPlayerGui(replacement)
            end
        end)
    end
end)

local existingContainer = screenGui:FindFirstChild("LeaderboardContainer")
if existingContainer and existingContainer:IsA("Frame") then
    existingContainer:Destroy()
end

local container = Instance.new("Frame")
container.Name = "LeaderboardContainer"
container.AnchorPoint = Vector2.new(1, 0.5)
container.Position = UDim2.new(1, -40, 0.5, 0)
container.Size = UDim2.new(0, 420, 0, 0)
container.AutomaticSize = Enum.AutomaticSize.Y
container.BackgroundColor3 = backgroundColor
container.BackgroundTransparency = 0.1
container.BorderSizePixel = 0
container.Visible = false
container.Parent = screenGui

local containerCorner = Instance.new("UICorner")
containerCorner.CornerRadius = UDim.new(0, 12)
containerCorner.Parent = container

local containerStroke = Instance.new("UIStroke")
containerStroke.Color = Color3.fromRGB(255, 255, 255)
containerStroke.Transparency = 0.85
containerStroke.Thickness = 1
containerStroke.Parent = container

local containerPadding = Instance.new("UIPadding")
containerPadding.PaddingTop = UDim.new(0, 16)
containerPadding.PaddingBottom = UDim.new(0, 16)
containerPadding.PaddingLeft = UDim.new(0, 18)
containerPadding.PaddingRight = UDim.new(0, 18)
containerPadding.Parent = container

local containerLayout = Instance.new("UIListLayout")
containerLayout.FillDirection = Enum.FillDirection.Vertical
containerLayout.SortOrder = Enum.SortOrder.LayoutOrder
containerLayout.Padding = UDim.new(0, 12)
containerLayout.Parent = container

local headerLabel = Instance.new("TextLabel")
headerLabel.Name = "Header"
headerLabel.LayoutOrder = 1
headerLabel.Size = UDim2.new(1, 0, 0, 32)
headerLabel.BackgroundTransparency = 1
headerLabel.Font = Enum.Font.GothamBold
headerLabel.TextSize = 24
headerLabel.TextColor3 = headerTextColor
headerLabel.TextXAlignment = Enum.TextXAlignment.Left
headerLabel.Text = "Points Leaderboard"
headerLabel.Parent = container

local subHeaderLabel = Instance.new("TextLabel")
subHeaderLabel.Name = "SubHeader"
subHeaderLabel.LayoutOrder = 2
subHeaderLabel.Size = UDim2.new(1, 0, 0, 20)
subHeaderLabel.BackgroundTransparency = 1
subHeaderLabel.Font = Enum.Font.Gotham
subHeaderLabel.TextSize = 16
subHeaderLabel.TextColor3 = subtitleTextColor
subHeaderLabel.TextTransparency = 0.1
subHeaderLabel.TextXAlignment = Enum.TextXAlignment.Left
subHeaderLabel.Text = "Hold Tab to view · Press R to refresh global"
subHeaderLabel.Parent = container

local sessionSection = Instance.new("Frame")
sessionSection.Name = "SessionSection"
sessionSection.LayoutOrder = 3
sessionSection.Size = UDim2.new(1, 0, 0, 0)
sessionSection.AutomaticSize = Enum.AutomaticSize.Y
sessionSection.BackgroundTransparency = 1
sessionSection.Parent = container

local sessionLayout = Instance.new("UIListLayout")
sessionLayout.FillDirection = Enum.FillDirection.Vertical
sessionLayout.SortOrder = Enum.SortOrder.LayoutOrder
sessionLayout.Padding = UDim.new(0, 6)
sessionLayout.Parent = sessionSection

local sessionTitle = Instance.new("TextLabel")
sessionTitle.Name = "SessionTitle"
sessionTitle.LayoutOrder = 1
sessionTitle.Size = UDim2.new(1, 0, 0, 24)
sessionTitle.BackgroundTransparency = 1
sessionTitle.Font = Enum.Font.GothamBold
sessionTitle.TextSize = 20
sessionTitle.TextColor3 = headerTextColor
sessionTitle.TextXAlignment = Enum.TextXAlignment.Left
sessionTitle.Text = "This Session"
sessionTitle.Parent = sessionSection

local sessionStatusLabel = Instance.new("TextLabel")
sessionStatusLabel.Name = "SessionStatus"
sessionStatusLabel.LayoutOrder = 2
sessionStatusLabel.Size = UDim2.new(1, 0, 0, 20)
sessionStatusLabel.BackgroundTransparency = 1
sessionStatusLabel.Font = Enum.Font.Gotham
sessionStatusLabel.TextSize = 16
sessionStatusLabel.TextColor3 = subtitleTextColor
sessionStatusLabel.TextTransparency = 0.3
sessionStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
sessionStatusLabel.Text = "No scores yet."
sessionStatusLabel.Parent = sessionSection

local sessionList = Instance.new("Frame")
sessionList.Name = "SessionList"
sessionList.LayoutOrder = 3
sessionList.Size = UDim2.new(1, 0, 0, 0)
sessionList.AutomaticSize = Enum.AutomaticSize.Y
sessionList.BackgroundTransparency = 1
sessionList.Parent = sessionSection

local sessionListLayout = Instance.new("UIListLayout")
sessionListLayout.FillDirection = Enum.FillDirection.Vertical
sessionListLayout.SortOrder = Enum.SortOrder.LayoutOrder
sessionListLayout.Padding = UDim.new(0, 4)
sessionListLayout.Parent = sessionList

local sessionRows: {TextLabel} = {}
for index = 1, SESSION_ROWS do
    local row = Instance.new("TextLabel")
    row.Name = string.format("SessionRow%d", index)
    row.LayoutOrder = index
    row.Size = UDim2.new(1, 0, 0, 24)
    row.BackgroundTransparency = 1
    row.Font = Enum.Font.Gotham
    row.TextSize = 18
    row.TextColor3 = placeholderTextColor
    row.TextTransparency = 0.55
    row.TextXAlignment = Enum.TextXAlignment.Left
    row.TextTruncate = Enum.TextTruncate.AtEnd
    row.TextWrapped = false
    row.Text = string.format("%d. —", index)
    row.Parent = sessionList
    sessionRows[index] = row
end

local globalSection = Instance.new("Frame")
globalSection.Name = "GlobalSection"
globalSection.LayoutOrder = 4
globalSection.Size = UDim2.new(1, 0, 0, 0)
globalSection.AutomaticSize = Enum.AutomaticSize.Y
globalSection.BackgroundTransparency = 1
globalSection.Parent = container

local globalLayout = Instance.new("UIListLayout")
globalLayout.FillDirection = Enum.FillDirection.Vertical
globalLayout.SortOrder = Enum.SortOrder.LayoutOrder
globalLayout.Padding = UDim.new(0, 6)
globalLayout.Parent = globalSection

local globalTitle = Instance.new("TextLabel")
globalTitle.Name = "GlobalTitle"
globalTitle.LayoutOrder = 1
globalTitle.Size = UDim2.new(1, 0, 0, 24)
globalTitle.BackgroundTransparency = 1
globalTitle.Font = Enum.Font.GothamBold
globalTitle.TextSize = 20
globalTitle.TextColor3 = headerTextColor
globalTitle.TextXAlignment = Enum.TextXAlignment.Left
globalTitle.Text = "Global Top"
globalTitle.Parent = globalSection

local globalStatusLabel = Instance.new("TextLabel")
globalStatusLabel.Name = "GlobalStatus"
globalStatusLabel.LayoutOrder = 2
globalStatusLabel.Size = UDim2.new(1, 0, 0, 20)
globalStatusLabel.BackgroundTransparency = 1
globalStatusLabel.Font = Enum.Font.Gotham
globalStatusLabel.TextSize = 16
globalStatusLabel.TextColor3 = subtitleTextColor
globalStatusLabel.TextTransparency = 0.3
globalStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
globalStatusLabel.Text = "Global leaderboard pending..."
globalStatusLabel.Parent = globalSection

local globalList = Instance.new("Frame")
globalList.Name = "GlobalList"
globalList.LayoutOrder = 3
globalList.Size = UDim2.new(1, 0, 0, 0)
globalList.AutomaticSize = Enum.AutomaticSize.Y
globalList.BackgroundTransparency = 1
globalList.Parent = globalSection

local globalListLayout = Instance.new("UIListLayout")
globalListLayout.FillDirection = Enum.FillDirection.Vertical
globalListLayout.SortOrder = Enum.SortOrder.LayoutOrder
globalListLayout.Padding = UDim.new(0, 4)
globalListLayout.Parent = globalList

local globalRows: {TextLabel} = {}
for index = 1, SESSION_ROWS do
    local row = Instance.new("TextLabel")
    row.Name = string.format("GlobalRow%d", index)
    row.LayoutOrder = index
    row.Size = UDim2.new(1, 0, 0, 24)
    row.BackgroundTransparency = 1
    row.Font = Enum.Font.Gotham
    row.TextSize = 18
    row.TextColor3 = placeholderTextColor
    row.TextTransparency = 0.55
    row.TextXAlignment = Enum.TextXAlignment.Left
    row.TextTruncate = Enum.TextTruncate.AtEnd
    row.TextWrapped = false
    row.Text = string.format("%d. —", index)
    row.Parent = globalList
    globalRows[index] = row
end

local footer = Instance.new("Frame")
footer.Name = "Footer"
footer.LayoutOrder = 5
footer.Size = UDim2.new(1, 0, 0, 0)
footer.AutomaticSize = Enum.AutomaticSize.Y
footer.BackgroundTransparency = 1
footer.Parent = container

local footerLayout = Instance.new("UIListLayout")
footerLayout.FillDirection = Enum.FillDirection.Vertical
footerLayout.SortOrder = Enum.SortOrder.LayoutOrder
footerLayout.Padding = UDim.new(0, 4)
footerLayout.Parent = footer

local yourRankLabel = Instance.new("TextLabel")
yourRankLabel.Name = "YourRank"
yourRankLabel.LayoutOrder = 1
yourRankLabel.Size = UDim2.new(1, 0, 0, 20)
yourRankLabel.BackgroundTransparency = 1
yourRankLabel.Font = Enum.Font.Gotham
yourRankLabel.TextSize = 16
yourRankLabel.TextColor3 = subtitleTextColor
yourRankLabel.TextXAlignment = Enum.TextXAlignment.Left
yourRankLabel.Text = "Your Rank: —"
yourRankLabel.Parent = footer

local yourScoreLabel = Instance.new("TextLabel")
yourScoreLabel.Name = "YourScore"
yourScoreLabel.LayoutOrder = 2
yourScoreLabel.Size = UDim2.new(1, 0, 0, 20)
yourScoreLabel.BackgroundTransparency = 1
yourScoreLabel.Font = Enum.Font.Gotham
yourScoreLabel.TextSize = 16
yourScoreLabel.TextColor3 = subtitleTextColor
yourScoreLabel.TextXAlignment = Enum.TextXAlignment.Left
yourScoreLabel.Text = "Your Points: 0"
yourScoreLabel.Parent = footer

local openButton = screenGui:FindFirstChild("LeaderboardOpenButton")
if openButton and not openButton:IsA("TextButton") then
    openButton = nil
end

if not openButton then
    openButton = Instance.new("TextButton")
    openButton.Name = "LeaderboardOpenButton"
    openButton.AnchorPoint = Vector2.new(0, 1)
    openButton.Position = UDim2.new(0, 32, 1, -32)
    openButton.Size = UDim2.new(0, 150, 0, 44)
    openButton.BackgroundColor3 = openButtonColor
    openButton.BackgroundTransparency = 0.05
    openButton.BorderSizePixel = 0
    openButton.AutoButtonColor = true
    openButton.Font = Enum.Font.GothamBold
    openButton.TextSize = 18
    openButton.TextColor3 = headerTextColor
    openButton.Text = "Leaderboard"
    openButton.Parent = screenGui

    local buttonCorner = Instance.new("UICorner")
    buttonCorner.CornerRadius = UDim.new(0, 10)
    buttonCorner.Parent = openButton

    local buttonStroke = Instance.new("UIStroke")
    buttonStroke.Color = Color3.fromRGB(255, 255, 255)
    buttonStroke.Transparency = 0.85
    buttonStroke.Thickness = 1
    buttonStroke.Parent = openButton
else
    openButton.Text = "Leaderboard"
    openButton.BackgroundColor3 = openButtonColor
    openButton.Parent = screenGui
end

local sessionState = {
    entries = {} :: { { [string]: any } },
    totalPlayers = 0,
    yourRank = nil :: number?,
    yourScore = 0,
    updated = 0,
}

local globalState = {
    entries = {} :: { { [string]: any } },
    loading = false,
    error = nil :: string?,
    updated = 0,
    lastRequest = 0,
}

local function formatPoints(value: number): string
    return string.format("%d", value)
end

local function normalizeEntries(raw: any, limit: number): { { [string]: any } }
    if typeof(raw) ~= "table" then
        return {}
    end

    local candidate: any = raw
    if typeof(raw.entries) == "table" then
        candidate = raw.entries
    elseif typeof(raw.data) == "table" then
        candidate = raw.data
    elseif typeof(raw.top) == "table" then
        candidate = raw.top
    end

    if typeof(candidate) ~= "table" then
        return {}
    end

    local buffer: { any } = {}
    if #candidate > 0 then
        for index = 1, math.min(#candidate, limit) do
            buffer[#buffer + 1] = candidate[index]
        end
    else
        for _, value in pairs(candidate) do
            if typeof(value) == "table" then
                buffer[#buffer + 1] = value
            end
        end
    end

    table.sort(buffer, function(a, b)
        local rankA = tonumber((a :: any).rank or (a :: any).Rank)
        local rankB = tonumber((b :: any).rank or (b :: any).Rank)
        if rankA and rankB and rankA ~= rankB then
            return rankA < rankB
        end
        local scoreA = tonumber((a :: any).score or (a :: any).points or (a :: any).value) or 0
        local scoreB = tonumber((b :: any).score or (b :: any).points or (b :: any).value) or 0
        if scoreA == scoreB then
            local userA = tonumber((a :: any).userId or (a :: any).UserId) or 0
            local userB = tonumber((b :: any).userId or (b :: any).UserId) or 0
            return userA < userB
        end
        return scoreA > scoreB
    end)

    local normalized: { { [string]: any } } = {}
    for index, entry in ipairs(buffer) do
        if index > limit then
            break
        end

        if typeof(entry) == "table" then
            local userId = tonumber((entry :: any).userId or (entry :: any).UserId)
            local scoreValue = tonumber((entry :: any).score or (entry :: any).points or (entry :: any).value or (entry :: any).total) or 0
            if scoreValue >= 0 then
                scoreValue = math.floor(scoreValue + 0.5)
            else
                scoreValue = math.ceil(scoreValue - 0.5)
            end
            if scoreValue < 0 then
                scoreValue = 0
            end

            local nameValue = (entry :: any).displayName or (entry :: any).DisplayName or (entry :: any).name or (entry :: any).Name or (entry :: any).username or (entry :: any).Username or (entry :: any).player
            local nameText = typeof(nameValue) == "string" and nameValue or (userId and string.format("User %d", userId) or string.format("Player %d", index))
            local displayName = (entry :: any).displayName or (entry :: any).DisplayName
            if typeof(displayName) ~= "string" then
                displayName = nameText
            end

            normalized[#normalized + 1] = {
                userId = userId,
                score = scoreValue,
                points = scoreValue,
                value = scoreValue,
                name = nameText,
                username = typeof((entry :: any).username) == "string" and (entry :: any).username or nameText,
                displayName = displayName,
                rank = tonumber((entry :: any).rank or (entry :: any).Rank) or index,
            }
        end
    end

    return normalized
end

local function renderSession()
    if #sessionState.entries == 0 then
        sessionStatusLabel.Text = "No scores yet."
        sessionStatusLabel.TextTransparency = 0.35
    else
        local total = math.max(sessionState.totalPlayers, #sessionState.entries)
        sessionStatusLabel.Text = string.format("Top players this session (%d total)", total)
        sessionStatusLabel.TextTransparency = 0.1
    end

    for index, row in ipairs(sessionRows) do
        local entry = sessionState.entries[index]
        if entry then
            local name = entry.displayName or entry.name or string.format("Player %d", index)
            local score = tonumber(entry.score or entry.points or entry.value) or 0
            local rank = tonumber(entry.rank) or index
            row.Text = string.format("%d. %s — %s", rank, name, formatPoints(score))
            row.TextTransparency = 0
            if entry.userId and tonumber(entry.userId) == localPlayer.UserId then
                row.Font = Enum.Font.GothamBold
                row.TextColor3 = highlightColor
            else
                row.Font = Enum.Font.Gotham
                row.TextColor3 = defaultTextColor
            end
        else
            row.Text = string.format("%d. —", index)
            row.TextTransparency = 0.55
            row.Font = Enum.Font.Gotham
            row.TextColor3 = placeholderTextColor
        end
    end

    local totalPlayers = math.max(sessionState.totalPlayers, #sessionState.entries)
    local rank = sessionState.yourRank
    if typeof(rank) == "number" and rank > 0 then
        yourRankLabel.Text = string.format("Your Rank: #%d of %d", math.floor(rank + 0.5), math.max(totalPlayers, math.floor(rank + 0.5)))
    elseif totalPlayers > 0 then
        yourRankLabel.Text = string.format("Your Rank: — of %d", totalPlayers)
    else
        yourRankLabel.Text = "Your Rank: —"
    end

    yourScoreLabel.Text = string.format("Your Points: %s", formatPoints(sessionState.yourScore or 0))
end

local function renderGlobal()
    if globalState.loading then
        globalStatusLabel.Text = "Loading global leaderboard..."
        globalStatusLabel.TextTransparency = 0.05
    elseif globalState.error then
        globalStatusLabel.Text = string.format("%s (press R to retry)", globalState.error)
        globalStatusLabel.TextTransparency = 0
    elseif #globalState.entries == 0 then
        globalStatusLabel.Text = "No global scores yet."
        globalStatusLabel.TextTransparency = 0.35
    else
        if globalState.updated > 0 then
            local delta = math.max(0, os.time() - globalState.updated)
            if delta < 60 then
                globalStatusLabel.Text = "Updated just now"
            elseif delta < 3600 then
                globalStatusLabel.Text = string.format("Updated %d min ago", math.floor(delta / 60))
            else
                globalStatusLabel.Text = os.date("Updated %b %d, %I:%M %p", globalState.updated)
            end
        else
            globalStatusLabel.Text = "Latest global standings"
        end
        globalStatusLabel.TextTransparency = 0.1
    end

    for index, row in ipairs(globalRows) do
        local entry = globalState.entries[index]
        if entry then
            local name = entry.displayName or entry.name or string.format("Player %d", index)
            local score = tonumber(entry.score or entry.points or entry.value) or 0
            local rank = tonumber(entry.rank) or index
            row.Text = string.format("%d. %s — %s", rank, name, formatPoints(score))
            row.TextTransparency = 0
            if entry.userId and tonumber(entry.userId) == localPlayer.UserId then
                row.Font = Enum.Font.GothamBold
                row.TextColor3 = highlightColor
            else
                row.Font = Enum.Font.Gotham
                row.TextColor3 = defaultTextColor
            end
        else
            row.Text = string.format("%d. —", index)
            row.TextTransparency = 0.55
            row.Font = Enum.Font.Gotham
            row.TextColor3 = placeholderTextColor
        end
    end
end

local function updateOpenButtonVisual()
    if not openButton or not openButton:IsA("TextButton") then
        return
    end

    openButton.Text = scoreboardVisible and "Close" or "Leaderboard"
    openButton.BackgroundColor3 = scoreboardVisible and openButtonActiveColor or openButtonColor
end

local function requestGlobalLeaderboard(force: boolean?)
    if not globalFunction then
        globalState.error = "Global leaderboard unavailable."
        globalState.loading = false
        renderGlobal()
        return
    end

    local now = os.clock()
    if globalRequestInFlight then
        return
    end

    if not force and now - globalState.lastRequest < GLOBAL_REFRESH_INTERVAL then
        return
    end

    globalState.lastRequest = now
    globalState.loading = true
    globalState.error = nil
    globalRequestInFlight = true
    renderGlobal()

    task.spawn(function()
        local ok, result = pcall(function()
            return globalFunction:InvokeServer(SESSION_ROWS)
        end)
        globalRequestInFlight = false

        if ok and typeof(result) == "table" then
            local entries = normalizeEntries(result, SESSION_ROWS)
            globalState.entries = entries
            local updatedValue = result.updated or result.timestamp or result.time
            if typeof(updatedValue) == "number" then
                globalState.updated = math.floor(updatedValue)
            else
                globalState.updated = os.time()
            end
            if typeof(result.error) == "string" then
                globalState.error = result.error
            elseif typeof(result.message) == "string" then
                globalState.error = result.message
            else
                globalState.error = nil
            end
            globalState.loading = false
        else
            globalState.loading = false
            if typeof(result) == "table" then
                local fallbackEntries = normalizeEntries(result, SESSION_ROWS)
                if #fallbackEntries > 0 then
                    globalState.entries = fallbackEntries
                end
            end
            globalState.error = "Failed to load global leaderboard."
            if not ok then
                warn(string.format("[LeaderboardUI] Global leaderboard request failed: %s", tostring(result)))
            end
        end

        renderGlobal()
    end)
end

local function setVisible(visible: boolean)
    if scoreboardVisible == visible then
        return
    end

    scoreboardVisible = visible
    container.Visible = visible
    updateOpenButtonVisual()

    if visible then
        renderSession()
        renderGlobal()
        if os.clock() - globalState.lastRequest >= GLOBAL_REFRESH_INTERVAL then
            requestGlobalLeaderboard(false)
        end
    else
        tabToggleActive = false
    end
end

openButton.MouseButton1Click:Connect(function()
    if scoreboardVisible then
        setVisible(false)
    else
        setVisible(true)
        requestGlobalLeaderboard(false)
    end
end)

if sessionRemote then
    sessionRemote.OnClientEvent:Connect(function(payload)
        if typeof(payload) ~= "table" then
            return
        end

        local entries = normalizeEntries(payload, SESSION_ROWS)
        sessionState.entries = entries

        local totalPlayersValue = payload.totalPlayers or payload.total or payload.count
        local totalPlayersNumeric = tonumber(totalPlayersValue)
        if totalPlayersNumeric and totalPlayersNumeric > 0 then
            sessionState.totalPlayers = math.floor(totalPlayersNumeric + 0.5)
        else
            sessionState.totalPlayers = #entries
        end

        local rankValue = payload.yourRank or payload.rank or payload.position
        local numericRank = tonumber(rankValue)
        if numericRank and numericRank > 0 then
            sessionState.yourRank = math.floor(numericRank + 0.5)
        else
            sessionState.yourRank = nil
        end

        local scoreCandidate = payload.yourScore or payload.score or payload.points or payload.totalPoints
        local numericScore = tonumber(scoreCandidate)
        if numericScore then
            if numericScore >= 0 then
                numericScore = math.floor(numericScore + 0.5)
            else
                numericScore = math.ceil(numericScore - 0.5)
            end
            if numericScore < 0 then
                numericScore = 0
            end
            sessionState.yourScore = numericScore
        end

        local updatedCandidate = payload.updated or payload.timestamp or payload.time
        if typeof(updatedCandidate) == "number" then
            sessionState.updated = math.floor(updatedCandidate)
        else
            sessionState.updated = os.time()
        end

        renderSession()
    end)
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then
        return
    end

    if input.UserInputType == Enum.UserInputType.Keyboard then
        if input.KeyCode == Enum.KeyCode.Tab then
            if not scoreboardVisible then
                setVisible(true)
                tabToggleActive = true
            else
                tabToggleActive = false
            end
            requestGlobalLeaderboard(false)
        elseif scoreboardVisible and input.KeyCode == Enum.KeyCode.R then
            requestGlobalLeaderboard(true)
        end
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Tab then
        if tabToggleActive then
            setVisible(false)
        end
        tabToggleActive = false
    end
end)

renderSession()
renderGlobal()
updateOpenButtonVisual()
