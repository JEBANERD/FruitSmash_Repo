--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorkspaceService = game:GetService("Workspace")

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local systemsFolder = sharedFolder:WaitForChild("Systems")
local Localizer = require(systemsFolder:WaitForChild("Localizer"))

local TARGET_GUI_NAME = "WS_RoundTimer"

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

local prepRemote = remotesFolder:FindFirstChild("RE_PrepTimer")
if not prepRemote or not prepRemote:IsA("RemoteEvent") then
	return
end

local connections: { RBXScriptConnection } = {}
local running = true
local cleaned = false
local countdownToken = 0
local currentLocale = Localizer.getLocalPlayerLocale()
local currentSeconds: number? = nil

local function cleanup()
	if cleaned then
		return
	end
	cleaned = true
	running = false
	countdownToken += 1

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

local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local minutes = math.floor(seconds / 60)
	local remainder = seconds % 60

	if minutes > 0 then
		return string.format("%d:%02d", minutes, remainder)
	end

	return tostring(remainder)
end

local function updateDisplayText(seconds: number?)
        if seconds == nil then
                textLabel.Text = Localizer.t("ui.timers.roundIdle", nil, currentLocale)
        else
                textLabel.Text = formatTime(seconds)
        end
end

local function setDisplay(seconds: number?)
        if typeof(seconds) ~= "number" then
                currentSeconds = nil
                updateDisplayText(nil)
                return
        end

        local sanitized = math.max(0, math.floor(seconds))
        currentSeconds = sanitized
        updateDisplayText(sanitized)
end

local function startCountdown(seconds: number)
        local numeric = tonumber(seconds)
        if not numeric then
                return
        end

	numeric = math.max(0, math.floor(numeric))

	countdownToken += 1
	local token = countdownToken

	setDisplay(numeric)

	if numeric <= 0 then
		return
	end

        task.spawn(function()
                local remaining = numeric
                while running and countdownToken == token and remaining > 0 do
                        task.wait(1)
                        if not running or countdownToken ~= token then
                                break
                        end

                        remaining -= 1
                        if remaining < 0 then
                                remaining = 0
                        end

                        setDisplay(remaining)
                end
        end)
end

local function refreshLocale()
        currentLocale = Localizer.getLocalPlayerLocale()
        updateDisplayText(currentSeconds)
end

refreshLocale()

local prepConnection = prepRemote.OnClientEvent:Connect(function(firstArg, secondArg)
	if not running then
		return
	end

	local seconds: number? = nil
	local stop = false

	if typeof(firstArg) == "table" then
		local payload = firstArg
		if payload.seconds ~= nil then
			seconds = tonumber(payload.seconds)
		end
		if payload.stop ~= nil then
			stop = payload.stop and true or false
		end
	else
		if typeof(firstArg) == "number" then
			seconds = firstArg
		elseif typeof(firstArg) == "string" then
			seconds = tonumber(firstArg)
		end

		if typeof(secondArg) == "boolean" then
			stop = secondArg
		elseif typeof(secondArg) == "table" and secondArg.stop ~= nil then
			stop = secondArg.stop and true or false
		end
	end

	if stop then
		countdownToken += 1
		if seconds ~= nil then
			setDisplay(seconds)
		else
			setDisplay(nil)
		end
		return
	end

	if seconds == nil then
		return
	end

	startCountdown(seconds)
end)

if prepConnection then
	table.insert(connections, prepConnection)
end
