-- HitSFXClient (optional local backup so the hitter ALWAYS hears it instantly)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local FruitSmashed = Remotes:WaitForChild("FruitSmashed")

local Assets = ReplicatedStorage:WaitForChild("Assets")
local Sounds = Assets:WaitForChild("Sounds")
local SFX_FruitSplat = Sounds:WaitForChild("SFX_FruitSplat")

FruitSmashed.OnClientEvent:Connect(function(payload)
	local pos = payload and payload.Position
	if not pos then return end

	-- local quick sound near camera/player
	local sound = Instance.new("Sound")
	sound.SoundId = SFX_FruitSplat.SoundId
	sound.Volume = math.max(0.2, SFX_FruitSplat.Volume)
	sound.PlaybackSpeed = SFX_FruitSplat.PlaybackSpeed > 0 and SFX_FruitSplat.PlaybackSpeed or 1
	-- Parent to SoundService for local (non-spatial) playback or to a small part near camera if you prefer spatialized
	sound.Parent = game:GetService("SoundService")
	sound:Play()

	game:GetService("Debris"):AddItem(sound, 2)
end)
