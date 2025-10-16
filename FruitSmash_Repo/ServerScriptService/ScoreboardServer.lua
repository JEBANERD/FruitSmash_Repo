-- ScoreboardServer: wires players to ScoreService and ensures remote exists
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local ScoreService = require(game.ServerScriptService:WaitForChild("ScoreService"))

local Remotes = RS:FindFirstChild("Remotes") or Instance.new("Folder", RS)
Remotes.Name = "Remotes"
local ScoreUpdated = Remotes:FindFirstChild("ScoreUpdated") or Instance.new("RemoteEvent", Remotes)
ScoreUpdated.Name = "ScoreUpdated"

Players.PlayerAdded:Connect(function(plr)
	ScoreService.InitPlayer(plr)
end)

-- Optional: reset everyone at server boot
for _, plr in ipairs(Players:GetPlayers()) do
	ScoreService.InitPlayer(plr)
end
