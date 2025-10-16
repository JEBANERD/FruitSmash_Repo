-- RemoteBootstrap_AddRoundPointsAdd (SERVER)
local RS = game:GetService("ReplicatedStorage")
local Remotes = RS:FindFirstChild("Remotes") or Instance.new("Folder", RS)
Remotes.Name = "Remotes"

if not Remotes:FindFirstChild("RoundPointsAdd") then
	local evt = Instance.new("BindableEvent")
	evt.Name = "RoundPointsAdd"
	evt.Parent = Remotes
	print("[Bootstrap] Created Remotes.RoundPointsAdd")
end
