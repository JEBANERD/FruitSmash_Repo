-- PowerupDebugServer (SERVER) — temp hotkey testing for powerups
-- Accepts debug requests from trusted testers and applies effects via PowerupEffects.

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Remotes
local Remotes = RS:FindFirstChild("Remotes") or Instance.new("Folder", RS)
Remotes.Name = "Remotes"

local DebugRequest = Remotes:FindFirstChild("PowerupDebugRequest") or Instance.new("RemoteEvent")
DebugRequest.Name = "PowerupDebugRequest"
DebugRequest.Parent = Remotes

-- Effects
local PowerupEffects = require(game.ServerScriptService:WaitForChild("PowerupEffects"))

-- Config
local COOLDOWN = 0.5 -- seconds between requests per player
local ALLOW_ALL_TESTERS = false -- set true if you want anyone to use the keys

-- Trust gate: only place owner in live games, everyone in Studio if ALLOW_ALL_TESTERS is false
local function isTrusted(plr: Player)
	if ALLOW_ALL_TESTERS then return true end
	if RunService:IsStudio() then return true end
	return plr.UserId == game.CreatorId
end

-- Per-player cooldown
local lastUse: {[Player]: number} = {}

local VALID = {
	healthpack = true,
	health = true,
	coinboost = true,
	coinx2 = true,
	doublecoins = true,
	shield = true,
}

DebugRequest.OnServerEvent:Connect(function(plr, powerupType: string)
	if not plr or typeof(powerupType) ~= "string" then return end
	if not isTrusted(plr) then return end

	local now = os.clock()
	if lastUse[plr] and (now - lastUse[plr]) < COOLDOWN then return end
	lastUse[plr] = now

	local t = powerupType:lower()
	if not VALID[t] then return end

	-- Route to effects. For player-centric boosts we pass plr; for target effects, plr is ignored safely.
	local ok, err = pcall(function()
		PowerupEffects.ApplyPowerup(t, plr)
	end)
	if not ok then
		warn("[PowerupDebugServer] Apply error:", t, err)
	end
end)

-- Cleanup table when players leave
Players.PlayerRemoving:Connect(function(plr) lastUse[plr] = nil end)

print("[PowerupDebugServer] Debug keys active: Z=Health, X=CoinBoost, C=Shield (trusted testers only).")
