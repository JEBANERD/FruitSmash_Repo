-- RemotesBootstrap: guarantees Remotes folder, core RemoteEvents, Bindables, and GameActive.
local RS = game:GetService("ReplicatedStorage")

-- Ensure Remotes folder
local Remotes = RS:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = RS
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local e = Remotes:FindFirstChild(name)
	if not e then
		e = Instance.new("RemoteEvent")
		e.Name = name
		e.Parent = Remotes
	end
	return e :: RemoteEvent
end

local function ensureBindable(name: string): BindableEvent
	local b = Remotes:FindFirstChild(name)
	if not b then
		b = Instance.new("BindableEvent")
		b.Name = name
		b.Parent = Remotes
	end
	return b :: BindableEvent
end

-- Core UI/game flow events
ensureRemoteEvent("StartCountdown")
ensureRemoteEvent("GameOverEvent")
ensureRemoteEvent("RestartRequested")
ensureRemoteEvent("QuitRequested")

-- Combat / FX channels (created here if missing; safe to keep)
ensureRemoteEvent("PlayerSwing")
ensureRemoteEvent("FruitSmashed")

-- Scoring remote usually created by ScoreService; keep it if present, else create for safety
if not Remotes:FindFirstChild("ScoreUpdated") then
	local _ = ensureRemoteEvent("ScoreUpdated")
end

-- 🔹 New: server-only bindable used by the Fast Start ring
ensureBindable("RequestFastStart")

-- Shared game-state flag
if not RS:FindFirstChild("GameActive") then
	local b = Instance.new("BoolValue")
	b.Name = "GameActive"
	b.Value = false -- rounds start paused until countdown completes
	b.Parent = RS
end

print("[RemotesBootstrap] Remotes ready (StartCountdown, GameOverEvent, Restart/Quit, PlayerSwing, FruitSmashed, ScoreUpdated, RequestFastStart).")
