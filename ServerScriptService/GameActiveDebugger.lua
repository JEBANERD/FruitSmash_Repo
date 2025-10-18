local RS = game:GetService("ReplicatedStorage")
local GA: BoolValue = RS:WaitForChild("GameActive") :: BoolValue

print("[GameActiveDebugger] Start: ", GA.Value)
GA.Changed:Connect(function()
	print("[GameActiveDebugger] GameActive ->", GA.Value, " @", os.clock())
end)
