-- GameFlowServer (COMPAT STUB v2)
-- Purpose: keep legacy Remote names around WITHOUT controlling gameplay.
-- RoundDirector is the only authority for countdowns and GameActive.

local RS = game:GetService("ReplicatedStorage")

-- Ensure Remotes folder exists
local Remotes = RS:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = RS
end

-- Idempotent helper
local function ensureRemoteEvent(name)
	local r = Remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = Remotes
	end
	return r
end

-- Keep these RemoteEvents available so other code doesn't error.
-- (We DO NOT connect handlers here; RoundDirector owns behavior.)
local StartCountdown   = ensureRemoteEvent("StartCountdown")
local RestartRequested = ensureRemoteEvent("RestartRequested")
local QuitRequested    = ensureRemoteEvent("QuitRequested")

-- Optional legacy object: RequestFastStart may exist as a RemoteEvent OR BindableEvent.
-- We DO NOT use it anymore. The fast-start path is the BoolValue below.
-- Leave it as-is to avoid breaking older assets.
if not Remotes:FindFirstChild("RequestFastStart") then
	-- If you want a RemoteEvent for UI pings, uncomment:
	-- local ev = Instance.new("RemoteEvent")
	-- ev.Name = "RequestFastStart"
	-- ev.Parent = Remotes
end

-- Primary fast-start signal for RoundDirector
local FastStartFlag = RS:FindFirstChild("FastStartRequested")
if not FastStartFlag then
	FastStartFlag = Instance.new("BoolValue")
	FastStartFlag.Name = "FastStartRequested"
	FastStartFlag.Parent = RS
end

print("[GameFlowServer][Compat] Loaded. RoundDirector owns countdowns/GameActive. No listeners here.")
