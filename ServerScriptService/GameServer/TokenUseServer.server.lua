--!strict
-- TokenUseServer.server.lua
-- Minimal server handler so Quickbar can invoke token usage with server validation.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)
local TokenEffectsServer = require(script.Parent:WaitForChild("TokenEffectsServer"))

local gameServerFolder = ServerScriptService:WaitForChild("GameServer")
local QuickbarServer = require(gameServerFolder:WaitForChild("QuickbarServer"))
local ShopServer = require(gameServerFolder:WaitForChild("Shop"):WaitForChild("ShopServer"))

local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local shopItems = (type(ShopConfig.All) == "function" and ShopConfig.All()) or ShopConfig.Items or {}

-- Use a map type for arbitrary metadata instead of `table`
export type Meta = { [string]: any }

export type UseTokenPayload = {
    effect: string?,
    slot: number?,
    meta: Meta?,
}

local rf: RemoteFunction = Remotes.RF_UseToken

rf.OnServerInvoke = function(player: Player, payload: UseTokenPayload?)
        if typeof(player) ~= "Instance" or not player:IsA("Player") then
                return { ok = false, err = "InvalidPlayer" }
        end

        local slotIndex: number? = nil
        local requestedEffect: string? = nil

        if typeof(payload) == "number" then
                slotIndex = payload
        elseif typeof(payload) == "table" then
                slotIndex = payload.slot or payload.index
                if typeof(payload.effect) == "string" then
                        requestedEffect = payload.effect
                end
        else
                return { ok = false, err = "BadPayload" }
        end

        if typeof(slotIndex) ~= "number" or slotIndex < 1 then
                return { ok = false, err = "NoSlot" }
        end

        local profile, data, inventory = ShopServer.GetProfileAndInventory(player)
        if not profile or not data or not inventory then
                return { ok = false, err = "NoInventory" }
        end

        local quickbarState = QuickbarServer.BuildState(data, inventory)
        local tokenEntry = quickbarState.tokens[slotIndex]
        if typeof(tokenEntry) ~= "table" or typeof(tokenEntry.Id) ~= "string" then
                return { ok = false, err = "EmptySlot" }
        end

        local tokenId = tokenEntry.Id
        local counts = inventory.TokenCounts
        if typeof(counts) ~= "table" then
                counts = {}
                inventory.TokenCounts = counts
        end

        local currentCount = if typeof(counts[tokenId]) == "number" then counts[tokenId] else tonumber(counts[tokenId]) or 0
        if currentCount <= 0 then
                return { ok = false, err = "OutOfToken" }
        end

        local itemInfo = shopItems[tokenId]
        local effect = requestedEffect
        if typeof(effect) ~= "string" or effect == "" then
                if typeof(itemInfo) == "table" and typeof(itemInfo.Effect) == "string" then
                        effect = itemInfo.Effect
                else
                        effect = tokenId
                end
        end

        print(("[TokenUse] %s consumed %s (slot=%d, effect=%s)")
                :format(player.Name, tokenId, slotIndex, tostring(effect)))

        counts[tokenId] = math.max(currentCount - 1, 0)
        ShopServer.MarkProfileDirty(player, profile)

        local newState = QuickbarServer.Refresh(player, data, inventory)

        if Remotes.RE_Notice then
                Remotes.RE_Notice:FireClient(player, { msg = "Token used: " .. tostring(effect), kind = "info" })
        end

        return {
                ok = true,
                tokenId = tokenId,
                effect = effect,
                remaining = counts[tokenId],
                quickbar = newState,
        }
local function parsePayload(payload: any): (string?, number?)
    if payload == nil then
        return nil, nil
    end

    local effectName: string? = nil
    local slotIndex: number? = nil

    if typeof(payload) == "number" then
        slotIndex = payload
    elseif typeof(payload) == "table" then
        effectName = payload.effect or payload.Effect
        slotIndex = payload.slot or payload.Slot or payload.index or payload.Index
    elseif typeof(payload) == "string" then
        effectName = payload
    end

    return effectName, slotIndex
end

rf.OnServerInvoke = function(player: Player, payload: UseTokenPayload?)
    local effectName, slotIndex = parsePayload(payload)

    local result = TokenEffectsServer.Use(player, effectName, slotIndex)
    if typeof(result) ~= "table" then
        return { ok = false, err = "NoResult" }
    end

    if result.ok and Remotes.RE_Notice then
        local messageEffect = result.effect or effectName or "token"
        Remotes.RE_Notice:FireClient(player, {
            msg = string.format("Token used: %s", tostring(messageEffect)),
            kind = "info",
        })
    end

    return result
end

Players.PlayerRemoving:Connect(function(player)
    TokenEffectsServer.ExpireAll(player)
end)

print("[TokenUseServer] RF_UseToken handler ready.")
