-- RoundPointsBridge (SERVER)
-- Forwards your existing scoring signals into the Round system.

local RS = game:GetService("ReplicatedStorage")
local Remotes = RS:WaitForChild("Remotes")

-- Round-side sink
local RoundPointsAdd: BindableEvent = Remotes:WaitForChild("RoundPointsAdd") :: BindableEvent

-- Existing game signals (present in your project per RemoteBootstrap)
local ScoreUpdated: RemoteEvent?   = Remotes:FindFirstChild("ScoreUpdated")
local FruitSmashed: RemoteEvent?   = Remotes:FindFirstChild("FruitSmashed")

-- Helper: add if numeric
local function addPointsMaybe(p)
	if typeof(p) == "number" then
		if p ~= 0 then
			RoundPointsAdd:Fire(p)
		end
	end
end

-- 1) FruitSmashed can carry a payload (try common patterns)
if FruitSmashed then
	FruitSmashed.OnServerEvent:Connect(function(player, payload, maybePoints, ...)
		-- Accept either a table {points=...} or a raw number
		if typeof(payload) == "table" and typeof(payload.points) == "number" then
			addPointsMaybe(payload.points)
		else
			addPointsMaybe(maybePoints) -- in case it’s sent as the 2nd arg
		end
	end)
end

-- 2) ScoreUpdated often looks like: (player, newScore, delta) or (player, delta)
if ScoreUpdated then
	ScoreUpdated.OnServerEvent:Connect(function(player, a, b, ...)
		-- Prefer a "delta" if present
		if typeof(b) == "number" then
			addPointsMaybe(b)
		else
			addPointsMaybe(a)
		end
	end)
end

print("[RoundPointsBridge] Ready (listening to FruitSmashed/ScoreUpdated).")
