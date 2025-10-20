--!strict

--[=[
    RemoteBootstrap
    ----------------
    Lightweight bootstrapper for shared RemoteEvents used throughout the game.
    Requiring this module ensures the RemoteEvents exist and returns references
    for other scripts to use when firing signals between the server and clients.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")

-- Utility function to fetch an existing RemoteEvent or create it if missing.
local function getOrCreateRemote(name: string): RemoteEvent
    local remote = remotesFolder:FindFirstChild(name)
    if remote == nil then
        remote = Instance.new("RemoteEvent")
        remote.Name = name
        remote.Parent = remotesFolder
    end
    return remote :: RemoteEvent
end

-- Shared RemoteEvents used across gameplay systems.
local Remotes = {
    -- Fired when the game flow begins to signal all clients the match is starting.
    GameStart = getOrCreateRemote("GameStart"),

    -- Fired when a wave of enemies or objectives has been completed.
    WaveComplete = getOrCreateRemote("WaveComplete"),

    -- Fired when the shop interface should open for a player.
    ShopOpen = getOrCreateRemote("ShopOpen"),

    -- Fired when a player makes a purchase from the shop.
    PurchaseMade = getOrCreateRemote("PurchaseMade"),

    -- Fired when a player has been knocked out and needs to be handled by systems.
    PlayerKO = getOrCreateRemote("PlayerKO"),

    -- Fired whenever target health or shield values change for an arena.
    RE_TargetHP = getOrCreateRemote("RE_TargetHP"),

    -- Fired whenever a player's coins or points change.
    RE_CoinPointDelta = getOrCreateRemote("RE_CoinPointDelta"),
}

print("[RemoteBootstrap] RemoteEvents initialized")

return Remotes
