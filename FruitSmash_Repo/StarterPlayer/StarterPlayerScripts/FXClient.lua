-- FXClient: camera shake + optional gamepad rumble on FruitSmashed
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HapticService = game:GetService("HapticService")

local Remotes = RS:WaitForChild("Remotes")
local FruitSmashed = Remotes:WaitForChild("FruitSmashed")

local player = Players.LocalPlayer

-- Simple 1-tap shake
local function cameraShake(duration, magnitude)
	local cam = workspace.CurrentCamera
	if not cam then return end
	local start = tick()
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local t = tick() - start
		if t >= duration then
			if conn then conn:Disconnect() end
			-- reset any offset
			cam.CFrame = cam.CFrame
			return
		end
		-- tiny random offset that eases out
		local alpha = 1 - (t / duration)
		local dx = (math.noise(t*20, 0, 0) - 0.5) * 2 * magnitude * alpha
		local dy = (math.noise(0, t*20, 0) - 0.5) * 2 * magnitude * alpha
		cam.CFrame = cam.CFrame * CFrame.new(dx, dy, 0)
	end)
end

-- Optional gamepad vibration (if supported)
local function rumble(duration, strength)
	for _, enum in ipairs(Enum.UserInputType:GetEnumItems()) do
		if enum.Name:find("Gamepad") then
			local slot = Enum.UserInputType[enum.Name]
			if HapticService:IsMotorSupported(slot, Enum.VibrationMotor.Large) then
				HapticService:SetMotor(slot, Enum.VibrationMotor.Large, strength)
				task.delay(duration, function()
					HapticService:SetMotor(slot, Enum.VibrationMotor.Large, 0)
				end)
			end
		end
	end
end

FruitSmashed.OnClientEvent:Connect(function(payload)
	-- small shake + rumble
	cameraShake(0.12, 0.08)
	rumble(0.10, 0.25)
end)
