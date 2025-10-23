--!strict
-- DevTest_QuickbarFeeder.server.lua
-- Sends a sample quickbar state so the HUD has something to render in Studio.
-- Safe to keep around; you can disable/remove in live builds.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)

-- Pull ShopConfig for proper Ids / effects
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local Items = (type(ShopConfig.All) == "function" and ShopConfig.All()) or ShopConfig.Items

do
        local gameServer = ServerScriptService:FindFirstChild("GameServer")
        local quickbarModule = gameServer and gameServer:FindFirstChild("QuickbarServer")
        if quickbarModule and quickbarModule:IsA("ModuleScript") then
                local ok, quickbar = pcall(require, quickbarModule)
                if ok and typeof(quickbar) == "table" then
                        local isEnabled = (quickbar :: any).IsEnabled
                        local active = false
                        if typeof(isEnabled) == "function" then
                                local okCall, result = pcall(isEnabled)
                                active = okCall and result == true
                        else
                                active = true
                        end
                        if active then
                                warn("[DevTest QuickbarFeeder] QuickbarServer is active; skipping sample feeder.")
                                return
                        end
                end
        end
end

type QuickbarMeleeEntry = { Id: string, Active: boolean? }
type QuickbarTokenEntry = { Id: string, Count: number?, StackLimit: number? }
type QuickbarState = {
	melee: { QuickbarMeleeEntry? }?,
	tokens: { QuickbarTokenEntry? }?,
	coins: number?,
}

local function findToken(id: string): QuickbarTokenEntry
	local t = (Items and Items[id]) or {}
	return {
		Id = id,
		Count = 1,
		StackLimit = (typeof(t.StackLimit) == "number") and t.StackLimit or nil,
	}
end

local function buildSampleState(): QuickbarState
	return {
		melee = {
			{ Id = "WoodenBat", Active = true },
			nil, -- second melee slot empty
		},
		tokens = {
			findToken("Token_SpeedBoost"),
			findToken("Token_DoubleCoins"),
			findToken("Token_Shield"),
		},
		coins = 999, -- purely visual for now
	}
end

local function sendState(plr: Player)
	local state = buildSampleState()
	Remotes.RE_QuickbarUpdate:FireClient(plr, state)
end

-- On join, give them something to look at
Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Once(function()
		sendState(plr)
	end)
end)

-- Also resend when your local test starts (so it repopulates after teleport/pivot)
local gameStartRemote = Remotes.GameStart
if gameStartRemote and typeof(gameStartRemote) == "Instance" and gameStartRemote:IsA("RemoteEvent") then
        local function broadcastGameStart(payload: any?)
                local ok, err = pcall(gameStartRemote.FireAllClients, gameStartRemote, payload)
                if not ok then
                        warn(string.format("[DevTest QuickbarFeeder] Failed to broadcast GameStart: %s", tostring(err)))
                end
        end

        -- If you fire GameStart from server anywhere, mirror quickbar to everyone
        gameStartRemote.OnServerEvent:Connect(function(player, payload)
                for _, p in ipairs(Players:GetPlayers()) do
                        sendState(p)
                end
                broadcastGameStart(payload)
        end)
end

print("[DevTest] Quickbar feeder ready (sending sample state).")
