--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorkspaceService = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local systemsFolder = sharedFolder:WaitForChild("Systems")
local Localizer = require(systemsFolder:WaitForChild("Localizer"))

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
local currentLocale = Localizer.getLocalPlayerLocale()
local lastEntries: { any }? = nil
local lastStatusKey: string? = "ui.leaderboard.fetching"
local lastCustomMessage: string? = nil

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

        local localeConnection = localPlayer:GetAttributeChangedSignal("Locale"):Connect(function()
                refreshLocale()
        end)
        table.insert(connections, localeConnection)
end

local function setStatusText(key: string)
        lastEntries = nil
        lastStatusKey = key
        lastCustomMessage = nil
        textLabel.Text = Localizer.t(key, nil, currentLocale)
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
        local nameValue
        local scoreValue

        if typeof(entry) == "table" then
                nameValue = entry.name or entry.username or entry.displayName or entry.player or entry.user or entry[1]
                scoreValue = entry.score or entry.points or entry.value or entry.total or entry[2]
        else
                nameValue = entry
        end

        local nameText = if nameValue ~= nil then tostring(nameValue) else nil
        if not nameText or nameText == "" then
                nameText = Localizer.t("ui.leaderboard.anonymous", nil, currentLocale)
        end

        local scoreText = nil
        if scoreValue ~= nil then
                scoreText = tostring(scoreValue)
        end

        if scoreText and scoreText ~= "" and scoreText ~= "-" then
                return Localizer.t("ui.leaderboard.entry", {
                        rank = rank,
                        name = nameText,
                        score = scoreText,
                }, currentLocale)
        end

        return Localizer.t("ui.leaderboard.entryNoScore", {
                rank = rank,
                name = nameText,
        }, currentLocale)
end

local function displayEntries(entries: { any })
        lastEntries = entries
        lastStatusKey = nil
        lastCustomMessage = nil
        if #entries == 0 then
                setStatusText("ui.leaderboard.empty")
                return
        end

        local lines: { string } = {}
        local limit = math.min(#entries, 10)
        for index = 1, limit do
                lines[#lines + 1] = formatEntry(index, entries[index])
        end

        textLabel.Text = table.concat(lines, "\n")
end

local function renderLeaderboard(data: any)
        local entries = gatherEntries(data)
        displayEntries(entries)
end

local function refreshLocale()
        currentLocale = Localizer.getLocalPlayerLocale()
        if lastEntries then
                displayEntries(lastEntries)
                return
        end

        if lastStatusKey then
                setStatusText(lastStatusKey)
                return
        end

        if lastCustomMessage then
                textLabel.Text = lastCustomMessage
                return
        end

        setStatusText("ui.leaderboard.fetching")
end

setStatusText("ui.leaderboard.fetching")

local function updateLeaderboard(remote: RemoteFunction)
        setStatusText("ui.leaderboard.fetching")

        local ok, result = pcall(function()
                return remote:InvokeServer()
        end)

        if not running then
		return
	end

        if ok and result ~= nil then
                if typeof(result) == "table" then
                        renderLeaderboard(result)
                        return
                elseif typeof(result) == "string" or typeof(result) == "number" then
                        lastEntries = nil
                        lastStatusKey = nil
                        lastCustomMessage = tostring(result)
                        textLabel.Text = lastCustomMessage
                        return
                end
        end

        setStatusText("ui.leaderboard.unavailable")
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
                        setStatusText("ui.leaderboard.fetching")
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
