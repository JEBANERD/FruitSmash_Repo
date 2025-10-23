--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local localPlayer = Players.LocalPlayer
if not localPlayer then
    return
end

local playerGui: PlayerGui? = localPlayer:FindFirstChildOfClass("PlayerGui")
if not playerGui then
    local ok, result = pcall(function()
        return localPlayer:WaitForChild("PlayerGui", 5)
    end)
    if ok and result and result:IsA("PlayerGui") then
        playerGui = result
    end
end

local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
    local ok, result = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 5)
    end)
    if ok and result and result:IsA("Folder") then
        remotesFolder = result
    end
end

local Remotes
if remotesFolder then
    local ok, result = pcall(function()
        return require(remotesFolder:WaitForChild("RemoteBootstrap"))
    end)
    if ok then
        Remotes = result
    else
        warn("[QueueUI] Failed to require RemoteBootstrap:", result)
    end
end

local partyUpdateRemote: RemoteEvent? = Remotes and Remotes.PartyUpdate or nil
if not partyUpdateRemote then
    warn("[QueueUI] PartyUpdate remote missing")
    return
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "QueueUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 25
if playerGui then
    screenGui.Parent = playerGui
end

local backgroundColor = Color3.fromRGB(26, 29, 44)
local highlightColor = Color3.fromRGB(255, 228, 116)
local textColor = Color3.fromRGB(235, 235, 235)
local subTextColor = Color3.fromRGB(205, 208, 224)

local container = Instance.new("Frame")
container.Name = "QueueContainer"
container.AnchorPoint = Vector2.new(0.5, 0)
container.Position = UDim2.new(0.5, 0, 0, 80)
container.Size = UDim2.new(0, 360, 0, 0)
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
containerStroke.Color = highlightColor
containerStroke.Transparency = 0.85
containerStroke.Thickness = 1
containerStroke.Parent = container

local containerPadding = Instance.new("UIPadding")
containerPadding.PaddingTop = UDim.new(0, 14)
containerPadding.PaddingBottom = UDim.new(0, 14)
containerPadding.PaddingLeft = UDim.new(0, 18)
containerPadding.PaddingRight = UDim.new(0, 18)
containerPadding.Parent = container

local containerLayout = Instance.new("UIListLayout")
containerLayout.FillDirection = Enum.FillDirection.Vertical
containerLayout.SortOrder = Enum.SortOrder.LayoutOrder
containerLayout.Padding = UDim.new(0, 8)
containerLayout.Parent = container

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.LayoutOrder = 1
titleLabel.Size = UDim2.new(1, 0, 0, 0)
titleLabel.AutomaticSize = Enum.AutomaticSize.Y
titleLabel.BackgroundTransparency = 1
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 20
titleLabel.TextColor3 = textColor
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Text = "Matchmaking"
titleLabel.Parent = container

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.LayoutOrder = 2
statusLabel.Size = UDim2.new(1, 0, 0, 0)
statusLabel.AutomaticSize = Enum.AutomaticSize.Y
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 18
statusLabel.TextColor3 = textColor
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Text = ""
statusLabel.Parent = container

local detailLabel = Instance.new("TextLabel")
detailLabel.Name = "Detail"
detailLabel.LayoutOrder = 3
detailLabel.Size = UDim2.new(1, 0, 0, 0)
detailLabel.AutomaticSize = Enum.AutomaticSize.Y
detailLabel.BackgroundTransparency = 1
detailLabel.Font = Enum.Font.Gotham
detailLabel.TextSize = 15
detailLabel.TextColor3 = subTextColor
detailLabel.TextTransparency = 0.05
detailLabel.TextWrapped = true
detailLabel.TextXAlignment = Enum.TextXAlignment.Left
detailLabel.Visible = false
detailLabel.Text = ""
detailLabel.Parent = container

local membersLabel = Instance.new("TextLabel")
membersLabel.Name = "Members"
membersLabel.LayoutOrder = 4
membersLabel.Size = UDim2.new(1, 0, 0, 0)
membersLabel.AutomaticSize = Enum.AutomaticSize.Y
membersLabel.BackgroundTransparency = 1
membersLabel.Font = Enum.Font.Gotham
membersLabel.TextSize = 15
membersLabel.TextColor3 = subTextColor
membersLabel.TextTransparency = 0.05
membersLabel.TextWrapped = true
membersLabel.TextXAlignment = Enum.TextXAlignment.Left
membersLabel.Visible = false
membersLabel.Text = ""
membersLabel.Parent = container

local connections: { RBXScriptConnection } = {}

local countdownConnection: RBXScriptConnection? = nil
local countdownEndsAt: number? = nil
local currentStatusKey: string? = nil
local currentMembersKey: string? = nil
local currentRetryAttempt: number? = nil

local function trackConnection(connection: RBXScriptConnection?)
    if connection then
        table.insert(connections, connection)
    end
end

local function reparentToGui(newGui: PlayerGui?)
    if not newGui then
        return
    end

    playerGui = newGui
    screenGui.Parent = newGui
end

local function stopCountdown()
    if countdownConnection then
        countdownConnection:Disconnect()
        countdownConnection = nil
    end
    countdownEndsAt = nil
end

local function setDetailText(text: string?)
    if typeof(text) == "string" and text ~= "" then
        detailLabel.Text = text
        detailLabel.Visible = true
    else
        detailLabel.Text = ""
        detailLabel.Visible = false
    end
end

local function updateMembersLabel(membersPayload: any)
    if typeof(membersPayload) ~= "table" then
        if membersLabel.Visible then
            membersLabel.Visible = false
            membersLabel.Text = ""
        end
        currentMembersKey = nil
        return
    end

    local names = {}
    for _, entry in ipairs(membersPayload) do
        if typeof(entry) == "table" then
            local nameValue = entry.name or entry.Name or entry.displayName or entry.DisplayName
            if typeof(nameValue) == "string" and nameValue ~= "" then
                table.insert(names, nameValue)
            else
                local userIdValue = entry.userId or entry.UserId
                if typeof(userIdValue) == "number" then
                    table.insert(names, string.format("Player %d", userIdValue))
                end
            end
        elseif typeof(entry) == "Instance" and entry:IsA("Player") then
            table.insert(names, entry.Name)
        elseif typeof(entry) == "string" then
            table.insert(names, entry)
        elseif typeof(entry) == "number" then
            table.insert(names, string.format("Player %d", entry))
        end
    end

    local membersKey = table.concat(names, "|")
    if membersKey == currentMembersKey then
        return
    end
    currentMembersKey = membersKey

    if #names == 0 then
        membersLabel.Text = ""
        membersLabel.Visible = false
        return
    end

    membersLabel.Text = string.format("Party: %s", table.concat(names, ", "))
    membersLabel.Visible = true
end

local function updateRetryLabel()
    if not countdownEndsAt then
        return
    end

    local remaining = math.max(0, countdownEndsAt - os.clock())
    local seconds = math.max(0, math.ceil(remaining))
    local attemptSuffix = ""

    if currentRetryAttempt and currentRetryAttempt > 1 then
        attemptSuffix = string.format(" (attempt %d)", currentRetryAttempt)
    end

    if seconds <= 0 then
        statusLabel.Text = string.format("Requeueing now%s...", attemptSuffix)
    else
        statusLabel.Text = string.format("Retrying in %ds%s...", seconds, attemptSuffix)
    end
end

local function startCountdown(durationSeconds: number)
    stopCountdown()

    countdownEndsAt = os.clock() + math.max(0, durationSeconds)
    updateRetryLabel()

    countdownConnection = RunService.Heartbeat:Connect(function()
        if not countdownEndsAt then
            stopCountdown()
            return
        end

        if os.clock() >= countdownEndsAt then
            updateRetryLabel()
            stopCountdown()
        else
            updateRetryLabel()
        end
    end)
end

local function computeStateKey(status: string?, extra: any?): string
    local parts = {}

    if typeof(status) == "string" then
        table.insert(parts, status)
    end

    if typeof(extra) == "table" then
        local keys = {}
        for key in pairs(extra) do
            table.insert(keys, key)
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)

        for _, key in ipairs(keys) do
            local value = extra[key]
            local valueText
            if typeof(value) == "table" then
                local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
                if ok then
                    valueText = encoded
                else
                    valueText = tostring(value)
                end
            else
                valueText = tostring(value)
            end

            table.insert(parts, string.format("%s=%s", tostring(key), valueText))
        end
    elseif extra ~= nil then
        table.insert(parts, tostring(extra))
    end

    return table.concat(parts, "|")
end

local function clearState()
    stopCountdown()
    currentStatusKey = nil
    currentMembersKey = nil
    currentRetryAttempt = nil

    statusLabel.Text = ""
    setDetailText(nil)
    membersLabel.Visible = false
    membersLabel.Text = ""
    container.Visible = false
end

local function applyStatus(status: string, extra: any?): boolean
    stopCountdown()
    currentRetryAttempt = nil

    local lowered = string.lower(status)

    if lowered == "queued" then
        container.Visible = true
        statusLabel.Text = "Searching for a match..."
        setDetailText("We'll notify you as soon as matchmaking completes.")
        return true
    elseif lowered == "teleporting" then
        container.Visible = true
        statusLabel.Text = "Teleporting to your match..."
        setDetailText("Please stay in the experience while we connect you.")
        return true
    elseif lowered == "local" then
        container.Visible = true
        statusLabel.Text = "Starting a local arena..."
        setDetailText("No match server available; playing on this server instead.")
        return true
    elseif lowered == "retrying" then
        container.Visible = true

        local attempt = 1
        local delaySeconds = 0
        local reasonText: string? = nil

        if typeof(extra) == "table" then
            local attemptValue = extra.attempt
            if typeof(attemptValue) == "number" then
                attempt = math.max(1, math.floor(attemptValue + 0.5))
            end

            local delayValue = extra.retryDelaySeconds or extra.retryDelayRounded
            if typeof(delayValue) == "number" then
                delaySeconds = math.max(0, delayValue)
            end

            local reasonValue = extra.reason
            if typeof(reasonValue) == "string" then
                reasonText = reasonValue
            end
        end

        if delaySeconds <= 0 then
            delaySeconds = 10
        end

        currentRetryAttempt = attempt
        startCountdown(delaySeconds)

        local detailParts = { string.format("Attempt %d", attempt) }
        if reasonText and reasonText ~= "" then
            table.insert(detailParts, string.format("Latest issue: %s", reasonText))
        end
        table.insert(detailParts, "We'll retry automatically. Please stay in the experience.")
        setDetailText(table.concat(detailParts, " • "))

        return true
    end

    container.Visible = false
    setDetailText(nil)
    statusLabel.Text = ""
    return false
end

local function cleanup()
    stopCountdown()
    for _, connection in ipairs(connections) do
        if connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

trackConnection(localPlayer.ChildAdded:Connect(function(child)
    if child:IsA("PlayerGui") then
        reparentToGui(child)
    end
end))

trackConnection(localPlayer.ChildRemoved:Connect(function(child)
    if child:IsA("PlayerGui") then
        task.defer(function()
            local replacement = localPlayer:FindFirstChildOfClass("PlayerGui")
            if replacement then
                reparentToGui(replacement)
            end
        end)
    end
end))

if not playerGui then
    local replacement = localPlayer:FindFirstChildOfClass("PlayerGui")
    if replacement then
        reparentToGui(replacement)
    end
end

trackConnection(localPlayer.AncestryChanged:Connect(function(_, parent)
    if parent == nil then
        cleanup()
    end
end))

script.Destroying:Connect(cleanup)

local partyConnection = partyUpdateRemote.OnClientEvent:Connect(function(payload)
    if typeof(payload) ~= "table" then
        return
    end

    updateMembersLabel(payload.members)

    local status = payload.status
    if typeof(status) ~= "string" then
        return
    end

    local loweredStatus = string.lower(status)

    if loweredStatus == "disbanded" then
        clearState()
        return
    end

    if loweredStatus == "update" then
        return
    end

    local statusKey = computeStateKey(status, payload.extra)
    if statusKey ~= "" and statusKey == currentStatusKey then
        return
    end

    local handled = applyStatus(status, payload.extra)
    if handled then
        currentStatusKey = statusKey
    else
        currentStatusKey = nil
    end
end)

trackConnection(partyConnection)

clearState()
