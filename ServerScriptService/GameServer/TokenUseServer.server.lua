--!strict
-- TokenUseServer.server.lua
-- Minimal server handler so Quickbar can invoke token usage with server validation.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)
local TokenEffectsServer = require(script.Parent:WaitForChild("TokenEffectsServer"))

-- Use a map type for arbitrary metadata instead of `table`
export type Meta = { [string]: any }

export type UseTokenPayload = {
    effect: string?,
    slot: number?,
    meta: Meta?,
}

local rf: RemoteFunction = Remotes.RF_UseToken

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
