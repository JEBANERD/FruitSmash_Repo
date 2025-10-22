--!strict
-- TokenUseServer.server.lua
-- Handles RF_UseToken requests with guard-validated payloads and delegates
-- execution to TokenEffectsServer.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Guard = require(ServerScriptService:WaitForChild("Moderation"):WaitForChild("GuardServer"))
local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)
local TokenEffectsServer = require(script.Parent:WaitForChild("TokenEffectsServer"))

local useTokenRemote: RemoteFunction? = Remotes and Remotes.RF_UseToken or nil

local MAX_EFFECT_NAME_LENGTH = 64
local MAX_SLOT_INDEX = 24

export type UseTokenRequest = {
	effect: string?,
	slot: number?,
}

local function parsePayload(payload: any): (string?, number?)
	if payload == nil then
		return nil, nil
	end

	local effectName: string? = nil
	local slotIndex: number? = nil
	local payloadType = typeof(payload)

	if payloadType == "number" then
		slotIndex = payload
	elseif payloadType == "string" then
		effectName = payload
	elseif payloadType == "table" then
		local effectCandidate = payload.effect or payload.Effect or payload.id or payload.Id
		if typeof(effectCandidate) == "string" and effectCandidate ~= "" then
			effectName = effectCandidate
		end

		local slotCandidate = payload.slot or payload.Slot or payload.index or payload.Index
		if slotCandidate ~= nil then
			if typeof(slotCandidate) == "number" then
				slotIndex = slotCandidate
			elseif typeof(slotCandidate) == "string" then
				local numeric = tonumber(slotCandidate)
				if numeric then
					slotIndex = numeric
				end
			end
		end
	end

	return effectName, slotIndex
end

local function validateUseTokenPayload(_player: Player, payload: any)
	local valueType = typeof(payload)
	if payload ~= nil and valueType ~= "number" and valueType ~= "string" and valueType ~= "table" then
		return false, "BadPayload"
	end

	local effectName, slotIndex = parsePayload(payload)

	if slotIndex ~= nil then
		local numericSlot = tonumber(slotIndex)
		if not numericSlot then
			return false, "BadSlot"
		end

		numericSlot = math.floor(numericSlot)
		if numericSlot < 1 or numericSlot > MAX_SLOT_INDEX then
			return false, "BadSlot"
		end

		slotIndex = numericSlot
	end

	if effectName ~= nil then
		if typeof(effectName) ~= "string" then
			return false, "BadEffect"
		end

		if effectName == "" then
			effectName = nil
		elseif #effectName > MAX_EFFECT_NAME_LENGTH then
			effectName = string.sub(effectName, 1, MAX_EFFECT_NAME_LENGTH)
		end
	end

	if slotIndex == nil and effectName == nil then
		return false, "BadPayload"
	end

	return true, {
		effect = effectName,
		slot = slotIndex,
	}
end

local function handleUseToken(player: Player, request: UseTokenRequest?)
	local effectName = request and request.effect or nil
	local slotIndex = request and request.slot or nil

	local result = TokenEffectsServer.Use(player, effectName, slotIndex)
	if typeof(result) ~= "table" then
		return { ok = false, err = "NoResult" }
	end

	if result.ok and Remotes.RE_Notice then
		local messageEffect = result.effect or effectName or "token"
		local okNotice, errNotice = pcall(Remotes.RE_Notice.FireClient, Remotes.RE_Notice, player, {
			msg = string.format("Token used: %s", tostring(messageEffect)),
			kind = "info",
		})
		if not okNotice then
			warn(string.format("[TokenUseServer] Failed to send notice: %s", tostring(errNotice)))
		end
	end

	return result
end

if useTokenRemote then
	Guard.WrapRemote(useTokenRemote, {
		remoteName = "RF_UseToken",
		rateLimit = { maxCalls = 3, interval = 1 },
		validator = validateUseTokenPayload,
		rejectResponse = function(reason)
			return { ok = false, err = reason }
		end,
	}, handleUseToken)
else
	warn("[TokenUseServer] RF_UseToken remote missing.")
end

Players.PlayerRemoving:Connect(function(player)
	TokenEffectsServer.ExpireAll(player)
end)

print("[TokenUseServer] RF_UseToken handler ready.")
