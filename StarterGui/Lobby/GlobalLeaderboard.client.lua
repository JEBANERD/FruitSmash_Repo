--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorkspaceService = game:GetService("Workspace")

local TARGET_GUI_NAME = "WS_GlobalLeaderboard"
local FETCH_INTERVAL_SECONDS = 30

local surfaceGui = WorkspaceService:FindFirstChild(TARGET_GUI_NAME, true)
if not surfaceGui or not surfaceGui:IsA("SurfaceGui") then
    return
end

local textLabel = surfaceGui:FindFirstChildWhichIsA("TextLabel", true)
if not textLabel then
    return
end

textLabel.Text = "Fetching..."

local function getRemotesFolder(): Folder?
    local folder = ReplicatedStorage:FindFirstChild("Remotes")
    if folder and folder:IsA("Folder") then
        return folder
    end

    local ok, result = pcall(function()
        return ReplicatedStorage:WaitForChild("Remotes", 5)
    end)
    if ok and result and result:IsA("Folder") then
        return result
    end

    return nil
end

local remotesFolder = getRemotesFolder()
if not remotesFolder then
    return
end

local connections: { RBXScriptConnection } = {}
local running = true
local cleaned = false

local function cleanup()
    if cleaned then
        return
    end
    cleaned = true
    running = false

    for _, connection in ipairs(connections) do
        if connection and connection.Disconnect then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

script.Destroying:Connect(cleanup)

local localPlayer = Players.LocalPlayer
if localPlayer then
    local ancestryConnection = localPlayer.AncestryChanged:Connect(function(_, parent)
        if parent == nil then
            cleanup()
        end
    end)
    table.insert(connections, ancestryConnection)
end

local function findLeaderboardRemote(): RemoteFunction?
    local remote = remotesFolder:FindFirstChild("RF_GetGlobalLeaderboard")
    if remote and remote:IsA("RemoteFunction") then
        return remote
    end
    return nil
end

local function gatherEntries(rawData: any): { any }
    if typeof(rawData) ~= "table" then
        return {}
    end

    local entriesCandidate: any = rawData
    if typeof(rawData.entries) == "table" then
        entriesCandidate = rawData.entries
    elseif typeof(rawData.data) == "table" then
        entriesCandidate = rawData.data
    end

    if typeof(entriesCandidate) ~= "table" then
        return {}
    end

    local ordered: { any } = {}
    local arrayLength = #entriesCandidate
    if arrayLength > 0 then
        for index = 1, arrayLength do
            ordered[#ordered + 1] = entriesCandidate[index]
        end
    else
        local numericKeys: { number } = {}
        for key, value in pairs(entriesCandidate) do
            if typeof(key) == "number" then
                numericKeys[#numericKeys + 1] = key
            else
                ordered[#ordered + 1] = value
            end
        end
        if #numericKeys > 0 then
            table.sort(numericKeys, function(a, b)
                return a < b
            end)
            for _, key in ipairs(numericKeys) do
                ordered[#ordered + 1] = entriesCandidate[key]
            end
        end
    end

    return ordered
end

local function formatEntry(rank: number, entry: any): string
    if typeof(entry) == "table" then
        local name = entry.name or entry.username or entry.displayName or entry.player or entry.user or entry[1]
        local score = entry.score or entry.points or entry.value or entry.total or entry[2]
        local nameText = name and tostring(name) or "Player"
        local scoreText = score and tostring(score) or "-"
        return string.format("%d. %s — %s", rank, nameText, scoreText)
    end

    return string.format("%d. %s", rank, tostring(entry))
end

local function renderLeaderboard(data: any)
    local entries = gatherEntries(data)
    if #entries == 0 then
        textLabel.Text = "No entries yet"
        return
    end

    local lines: { string } = {}
    local limit = math.min(#entries, 10)
    for index = 1, limit do
        lines[#lines + 1] = formatEntry(index, entries[index])
    end

    textLabel.Text = table.concat(lines, "\n")
end

local function updateLeaderboard(remote: RemoteFunction)
    textLabel.Text = "Fetching..."

    local ok, result = pcall(function()
        return remote:InvokeServer()
    end)

    if not running then
        return
    end

    if ok and result ~= nil then
        if typeof(result) == "table" or typeof(result) == "string" or typeof(result) == "number" then
            if typeof(result) == "table" then
                renderLeaderboard(result)
            else
                textLabel.Text = tostring(result)
            end
        else
            textLabel.Text = "Leaderboard unavailable"
        end
    else
        textLabel.Text = "Leaderboard unavailable"
    end
end

local function pollLoop()
    while running do
        local remote = findLeaderboardRemote()
        if not running then
            break
        end

        if remote then
            updateLeaderboard(remote)
        else
            textLabel.Text = "Fetching..."
        end

        local elapsed = 0
        while running and elapsed < FETCH_INTERVAL_SECONDS do
            local waited = task.wait(1)
            if typeof(waited) ~= "number" then
                waited = 1
            end
            elapsed += waited
        end
    end
end

task.spawn(pollLoop)
