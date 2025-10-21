--!strict
-- CoinPointController: updates HUD text when coins/points change.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
-- We are a child of the ScreenGui in StarterGui; at runtime we live in PlayerGui
local screenGui = script.Parent
local displayLabel = screenGui:WaitForChild("CoinPointDisplay") :: TextLabel

-- Require RemoteBootstrap safely
local RemotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local ok, RemotesOrErr = pcall(function()
	return require(RemotesFolder:WaitForChild("RemoteBootstrap"))
end)
local Remotes = ok and (RemotesOrErr :: any) or nil
if not ok then
	warn("[HUD_CoinsPoints] RemoteBootstrap require failed: ", RemotesOrErr)
end

local coinPointRemote: RemoteEvent? = Remotes and Remotes.RE_CoinPointDelta or nil

-- Start from player attributes if present
local coinsTotal = (player:GetAttribute("Coins") :: any)
coinsTotal = (typeof(coinsTotal) == "number") and coinsTotal or 0

local pointsTotal = (player:GetAttribute("Points") :: any)
pointsTotal = (typeof(pointsTotal) == "number") and pointsTotal or 0

local renderQueued = false
local lastRenderTime = 0
local MIN_RENDER_INTERVAL = 0.05

local function render()
	renderQueued = false
	lastRenderTime = os.clock()
	displayLabel.Text = string.format("Coins: %d  |  Points: %d", coinsTotal, pointsTotal)
end

local function queueRender()
	if renderQueued then return end
	renderQueued = true
	local delaySeconds = MIN_RENDER_INTERVAL - (os.clock() - lastRenderTime)
	if delaySeconds > 0 then
		task.delay(delaySeconds, render)
	else
		task.defer(render)
	end
end

local function updateTotals(newCoins: number?, newPoints: number?)
	local changed = false
	if typeof(newCoins) == "number" then
		local v = math.max(0, math.floor(newCoins + 0.5))
		if v ~= coinsTotal then coinsTotal = v; changed = true end
	end
	if typeof(newPoints) == "number" then
		local v = math.max(0, math.floor(newPoints + 0.5))
		if v ~= pointsTotal then pointsTotal = v; changed = true end
	end
	if changed then queueRender() end
end

queueRender()

local function applyPayload(payload: any)
	if typeof(payload) ~= "table" then return end

	local totalCoins = payload.totalCoins
	if typeof(totalCoins) ~= "number" then
		local delta = payload.coins
		if typeof(delta) == "number" then totalCoins = coinsTotal + delta end
	end

	local totalPoints = payload.totalPoints
	if typeof(totalPoints) ~= "number" then
		local delta = payload.points
		if typeof(delta) == "number" then totalPoints = pointsTotal + delta end
	end

	updateTotals(totalCoins, totalPoints)
end

-- Attribute mirrors (optional convenience if your Economy sets attributes)
local attrConn = player.AttributeChanged:Connect(function(attr)
	if attr == "Coins" then
		updateTotals(player:GetAttribute("Coins") :: any, nil)
	elseif attr == "Points" then
		updateTotals(nil, player:GetAttribute("Points") :: any)
	end
end)

if coinPointRemote then
	coinPointRemote.OnClientEvent:Connect(applyPayload)
end

script.Destroying:Connect(function()
	if attrConn and attrConn.Connected then attrConn:Disconnect() end
end)
