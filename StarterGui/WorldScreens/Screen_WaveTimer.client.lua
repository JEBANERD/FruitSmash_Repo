--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorkspaceService = game:GetService("Workspace")

local TARGET_GUI_NAME = "WS_WaveTimer"

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

local waveRemote = remotesFolder:FindFirstChild("RE_WaveChanged")
if not waveRemote or not waveRemote:IsA("RemoteEvent") then
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

local function updateWave(level: number, wave: number)
	textLabel.Text = string.format("Level %d — Wave %d/5", level, wave)
end

local waveConnection = waveRemote.OnClientEvent:Connect(function(firstArg, secondArg)
	if not running then
		return
	end

	local level: number? = nil
	local wave: number? = nil

	if typeof(firstArg) == "table" then
		local payload = firstArg
		if payload then
			if payload.level ~= nil then
				level = tonumber(payload.level)
			elseif payload[1] ~= nil then
				level = tonumber(payload[1])
			end

			if payload.wave ~= nil then
				wave = tonumber(payload.wave)
			elseif payload.currentWave ~= nil then
				wave = tonumber(payload.currentWave)
			elseif payload[2] ~= nil then
				wave = tonumber(payload[2])
			end
		end
	elseif typeof(firstArg) == "number" and typeof(secondArg) == "number" then
		level = firstArg
		wave = secondArg
	end

	if not level or not wave then
		return
	end

	level = math.max(0, math.floor(level))
	wave = math.max(0, math.floor(wave))

	updateWave(level, wave)
end)

if waveConnection then
	table.insert(connections, waveConnection)
end
