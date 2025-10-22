--!strict
-- TokenUseServer.server.lua
-- Minimal server handler so Quickbar can invoke token usage in local tests.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)

-- Use a map type for arbitrary metadata instead of `table`
export type Meta = { [string]: any }

export type UseTokenPayload = {
	effect: string?,   -- "SpeedBoost" | "DoubleCoins" | "TargetShield" | "BurstClear" | "AutoRepairMelee" | "TargetHealthBoost"
	slot: number?,     -- quickbar slot index [optional]
	meta: Meta?,       -- arbitrary extra data from client
}

local rf: RemoteFunction = Remotes.RF_UseToken

rf.OnServerInvoke = function(player: Player, payload: UseTokenPayload?)
	-- Basic validation
	if typeof(payload) ~= "table" then
		return { ok = false, err = "BadPayload" }
	end

	local effect = payload.effect
	if typeof(effect) ~= "string" then
		return { ok = false, err = "NoEffect" }
	end

	print(("[TokenUse] %s requested effect %s (slot=%s)")
		:format(player.Name, effect, tostring(payload.slot)))

	-- TODO: Wire to real effect application here.

	-- Optional feedback
	if Remotes.RE_Notice then
		Remotes.RE_Notice:FireClient(player, { msg = "Token used: " .. effect, kind = "info" })
	end

	return { ok = true }
end

print("[TokenUseServer] RF_UseToken handler ready.")
