-- PowerupDebugClient (CLIENT) — temp hotkeys: Z=Health, X=CoinBoost, C=Shield
-- Fires a server RemoteEvent to request powerup application.

local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")

local Remotes = RS:WaitForChild("Remotes")
local DebugRequest = Remotes:WaitForChild("PowerupDebugRequest")

local KEYMAP = {
	Z = "HealthPack",
	X = "CoinBoost",
	C = "Shield",
}

-- Optional: small on-screen hint (prints if CoreGui blocked)
pcall(function()
	game.StarterGui:SetCore("SendNotification", {
		Title = "Powerup Debug",
		Text = "Z=Health, X=CoinBoost, C=Shield",
		Duration = 6
	})
end)

UIS.InputBegan:Connect(function(input, gp)
	if gp then return end -- ignore if Roblox is using the key for UI
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

	local key = input.KeyCode.Name
	local pType = KEYMAP[key]
	if pType then
		DebugRequest:FireServer(pType)
	end
end)
