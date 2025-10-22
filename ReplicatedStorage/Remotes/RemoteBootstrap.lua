--!strict
-- RemoteBootstrap: ensures shared remotes exist (Events + Functions)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes") or Instance.new("Folder")
remotesFolder.Name = "Remotes"
remotesFolder.Parent = ReplicatedStorage

local function getOrCreateEvent(name: string): RemoteEvent
	local r = remotesFolder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotesFolder
	end
	return r :: RemoteEvent
end

local function getOrCreateFunction(name: string): RemoteFunction
	local r = remotesFolder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteFunction")
		r.Name = name
		r.Parent = remotesFolder
	end
	return r :: RemoteFunction
end

local Remotes = {
	-- Match / flow
	GameStart           = getOrCreateEvent("GameStart"),
	RE_PrepTimer        = getOrCreateEvent("RE_PrepTimer"),
	RE_WaveChanged      = getOrCreateEvent("RE_WaveChanged"),

	-- Combat / state
	RE_MeleeHitAttempt  = getOrCreateEvent("RE_MeleeHitAttempt"),
	RE_TargetHP         = getOrCreateEvent("RE_TargetHP"),

	-- Economy / UI
	RE_CoinPointDelta   = getOrCreateEvent("RE_CoinPointDelta"),
	RE_QuickbarUpdate   = getOrCreateEvent("RE_QuickbarUpdate"),
	ShopOpen            = getOrCreateEvent("ShopOpen"),
	PurchaseMade        = getOrCreateEvent("PurchaseMade"),

	-- Player status / notices
	PlayerKO            = getOrCreateEvent("PlayerKO"),
	RE_Notice           = getOrCreateEvent("RE_Notice"),

	-- Misc progression
	WaveComplete        = getOrCreateEvent("WaveComplete"),

	-- Functions (client -> server request/response)
	RF_UseToken         = getOrCreateFunction("RF_UseToken"),
}

print("[RemoteBootstrap] RemoteEvents/Functions initialized")
return Remotes
