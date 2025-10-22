--!strict
-- TokenUseServer.server.lua
-- Minimal server handler so Quickbar can invoke token usage in local tests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)

local gameServerFolder = ServerScriptService:WaitForChild("GameServer")
local QuickbarServer = require(gameServerFolder:WaitForChild("QuickbarServer"))
local ShopServer = require(gameServerFolder:WaitForChild("Shop"):WaitForChild("ShopServer"))

local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local shopItems = (type(ShopConfig.All) == "function" and ShopConfig.All()) or ShopConfig.Items or {}

-- Use a map type for arbitrary metadata instead of `table`
export type Meta = { [string]: any }

export type UseTokenPayload = {
	effect: string?,   -- "SpeedBoost" | "DoubleCoins" | "TargetShield" | "BurstClear" | "AutoRepairMelee" | "TargetHealthBoost"
	slot: number?,     -- quickbar slot index [optional]
	meta: Meta?,       -- arbitrary extra data from client
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
end

print("[TokenUseServer] RF_UseToken handler ready.")
