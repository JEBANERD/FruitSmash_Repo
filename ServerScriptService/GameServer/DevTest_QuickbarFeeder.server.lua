--!strict
-- DevTest_QuickbarFeeder.server.lua
-- Sends a sample quickbar state so the HUD has something to render in Studio.
-- Safe to keep around; guarded to avoid impacting live builds.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
        return
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)

-- Pull ShopConfig for proper Ids / effects
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local Items = (type(ShopConfig.All) == "function" and ShopConfig.All()) or ShopConfig.Items or {}

type QuickbarMeleeEntry = { Id: string, Active: boolean? }
type QuickbarTokenEntry = { Id: string, Count: number?, StackLimit: number? }
type QuickbarState = {
        melee: { QuickbarMeleeEntry? }?,
        tokens: { QuickbarTokenEntry? }?,
        coins: number?,
}

type MockData = { Coins: number }
type MockInventory = {
        ActiveMelee: string?,
        MeleeLoadout: {string},
        TokenCounts: {[string]: number},
}

local SAMPLE_MELEE = "WoodenBat"
local SAMPLE_TOKENS = { "Token_SpeedBoost", "Token_DoubleCoins", "Token_Shield" }
local SAMPLE_COINS = 999

local QuickbarServer: any = nil

do
        local gameServer = ServerScriptService:FindFirstChild("GameServer")
        local quickbarModule = gameServer and gameServer:FindFirstChild("QuickbarServer")
        if quickbarModule and quickbarModule:IsA("ModuleScript") then
                local ok, quickbar = pcall(require, quickbarModule)
                if ok and typeof(quickbar) == "table" then
                        QuickbarServer = quickbar
                else
                        warn(string.format("[DevTest QuickbarFeeder] Failed to require QuickbarServer: %s", tostring(quickbar)))
                end
        end
end

local function createMockDataAndInventory(): (MockData, MockInventory)
        local loadout = { SAMPLE_MELEE }
        local tokenCounts: {[string]: number} = {}
        for _, tokenId in ipairs(SAMPLE_TOKENS) do
                tokenCounts[tokenId] = 1
        end

        local data: MockData = { Coins = SAMPLE_COINS }
        local inventory: MockInventory = {
                ActiveMelee = SAMPLE_MELEE,
                MeleeLoadout = loadout,
                TokenCounts = tokenCounts,
        }

        return data, inventory
end

local function registerMockInventoryResolver()
        if QuickbarServer == nil then
                return
        end

        local registerResolver = (QuickbarServer :: any).RegisterInventoryResolver
        if typeof(registerResolver) ~= "function" then
                return
        end

        local ok, err = pcall(function()
                registerResolver(function(_player: Player)
                        local data, inventory = createMockDataAndInventory()
                        return data, inventory
                end)
        end)

        if not ok then
                warn(string.format("[DevTest QuickbarFeeder] Failed to register mock inventory resolver: %s", tostring(err)))
        end
end

registerMockInventoryResolver()

local function findToken(id: string): QuickbarTokenEntry
        local t = (Items and Items[id]) or {}
        local stackLimit = if typeof(t) == "table" and typeof(t.StackLimit) == "number" then t.StackLimit else nil
        return {
                Id = id,
                Count = 1,
                StackLimit = stackLimit,
        }
end

local function buildManualState(): QuickbarState
        local tokens: {QuickbarTokenEntry?} = {}
        for index, tokenId in ipairs(SAMPLE_TOKENS) do
                tokens[index] = findToken(tokenId)
        end

        return {
                melee = {
                        { Id = SAMPLE_MELEE, Active = true },
                        nil, -- second melee slot empty
                },
                tokens = tokens,
                coins = SAMPLE_COINS,
        }
end

local function buildSampleState(): QuickbarState
        if QuickbarServer ~= nil then
                local buildState = (QuickbarServer :: any).BuildState
                if typeof(buildState) == "function" then
                        local data, inventory = createMockDataAndInventory()
                        local ok, state = pcall(buildState, data, inventory)
                        if ok and typeof(state) == "table" then
                                return state :: QuickbarState
                        end
                end
        end

        return buildManualState()
end

local function sendState(player: Player)
        if QuickbarServer ~= nil then
                local refresh = (QuickbarServer :: any).Refresh
                if typeof(refresh) == "function" then
                        local data, inventory = createMockDataAndInventory()
                        local ok, err = pcall(refresh, player, data, inventory)
                        if ok then
                                return
                        end
                        warn(string.format("[DevTest QuickbarFeeder] QuickbarServer.Refresh failed: %s", tostring(err)))
                end
        end

        local state = buildSampleState()
        Remotes.RE_QuickbarUpdate:FireClient(player, state)
end

local function attachPlayer(player: Player)
        if player.Character ~= nil then
                task.defer(sendState, player)
                return
        end

        player.CharacterAdded:Once(function()
                sendState(player)
        end)
end

Players.PlayerAdded:Connect(attachPlayer)

for _, player in ipairs(Players:GetPlayers()) do
        attachPlayer(player)
end

local gameStartRemote = Remotes.GameStart
if gameStartRemote and typeof(gameStartRemote) == "Instance" and gameStartRemote:IsA("RemoteEvent") then
        local function broadcastGameStart(payload: any?)
                local ok, err = pcall(gameStartRemote.FireAllClients, gameStartRemote, payload)
                if not ok then
                        warn(string.format("[DevTest QuickbarFeeder] Failed to broadcast GameStart: %s", tostring(err)))
                end
        end

        gameStartRemote.OnServerEvent:Connect(function(_player, payload)
                for _, p in ipairs(Players:GetPlayers()) do
                        sendState(p)
                end
                broadcastGameStart(payload)
        end)
end

print("[DevTest] Quickbar feeder ready (sending sample state).")
