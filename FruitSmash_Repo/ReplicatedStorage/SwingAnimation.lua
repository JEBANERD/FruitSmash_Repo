local TweenService = game:GetService("TweenService")

local function playSwing(character)
	local hum = character:FindFirstChildOfClass("Humanoid")
	print("[SwingAnimation] playSwing called; hum.RigType =", hum and hum.RigType)

	if not hum then return end

	if hum.RigType == Enum.HumanoidRigType.R15 then
		local ut = character:FindFirstChild("UpperTorso")
		local rs = ut and ut:FindFirstChild("RightShoulder")
		if rs and rs:IsA("Motor6D") then
			local orig = rs.Transform
			print("[SwingAnimation] Found RightShoulder, starting tween")

			-- TEMP TEST: force a transform much bigger
			rs.Transform = CFrame.Angles(0, 0, math.rad(-1.5))
			task.wait(0.2)
			rs.Transform = orig

			-- Original intended swing
			local swingCF = CFrame.Angles(math.rad(-60), math.rad(0), math.rad(-40))
			local t1 = TweenService:Create(rs, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Transform = swingCF})
			local t2 = TweenService:Create(rs, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Transform = orig})
			t1:Play()
			t1.Completed:Wait()
			t2:Play()
			t2.Completed:Wait()
			rs.Transform = orig
		else
			print("[SwingAnimation] RightShoulder not found or not Motor6D")
		end
	else
		print("[SwingAnimation] hum.RigType ≠ R15, trying R6 path")
		-- same fallback code for R6...
	end
end

return {
	PlaySwing = playSwing
}
