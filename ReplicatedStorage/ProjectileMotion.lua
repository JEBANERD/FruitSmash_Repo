-- ProjectileMotion: moves a projectile from start -> end with raycast collision.
-- NEW: options.IgnoreInstances = { Instance, ... } to ignore (players, tools, etc.)
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Motion = {}

export type LaunchOptions = {
	Speed: number?, Path: string?, Ease: Enum.EasingStyle?,
	ControlOffset: number?, Amplitude: number?, Frequency: number?,
	MaxTime: number?, Debug: boolean?,
	OnHit: (Instance?) -> ()?,         -- called with hit.Instance OR nil if we reached the end
	IgnoreInstances: {Instance}?,      -- NEW: things to ignore in raycasts (players, tools,…)
}

local function dirAndDist(a: Vector3, b: Vector3)
	local d = b - a; local m = d.Magnitude
	return (m > 0 and d/m or Vector3.zAxis), m
end

local function bezier2(p0, p1, p2, t)
	local u = 1 - t
	return u*u*p0 + 2*u*t*p1 + t*t*p2
end

local function setTransform(root: Instance, pos: Vector3, lookDir: Vector3)
	local cf = CFrame.new(pos, pos + (lookDir.Magnitude > 0 and lookDir or Vector3.zAxis))
	if root:IsA("BasePart") then
		root.CFrame = cf
	elseif root:IsA("Model") then
		if not root.PrimaryPart then
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("BasePart") then root.PrimaryPart = d; break end
			end
		end
		if root.PrimaryPart then root:PivotTo(cf) end
	end
end

local function segmentCast(a: Vector3, b: Vector3, ignore: {Instance})
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = ignore
	return Workspace:Raycast(a, (b - a), p)
end

function Motion.Launch(root: Instance, startPos: Vector3, endPos: Vector3, options: LaunchOptions?)
	options = options or {}
	local speed = options.Speed or 60
	local path = string.lower(options.Path or "linear")
	local ctrlDist = options.ControlOffset or 15
	local amp = options.Amplitude or 4
	local freq = options.Frequency or 2
	local onHit = options.OnHit
	local extraIgnore = options.IgnoreInstances or {}

	local rootPart: BasePart? = nil
	if root:IsA("BasePart") then
		rootPart = root
	elseif root:IsA("Model") then
		rootPart = root.PrimaryPart
		if not rootPart then
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("BasePart") then root.PrimaryPart = d; rootPart = d; break end
			end
		end
	end
	if not rootPart then warn("[ProjectileMotion] No BasePart to move"); return end

	rootPart.Anchored = true
	rootPart.CanCollide = false

	local forward, distance = dirAndDist(startPos, endPos)
	if distance <= 0.01 then
		setTransform(root, endPos, forward)
		if onHit then onHit(nil) end
		return
	end

	local right = forward:Cross(Vector3.yAxis)
	if right.Magnitude < 1e-3 then right = forward:Cross(Vector3.xAxis) end
	right = right.Unit
	local up = right:Cross(forward).Unit

	local totalTime = distance / math.max(speed, 0.01)
	local maxTime = options.MaxTime or (totalTime * 1.5 + 2.0)
	local t, elapsed = 0, 0
	local lastPos = startPos
	setTransform(root, startPos, forward)

	local ignore: {Instance} = { root }
	for _, inst in ipairs(extraIgnore) do table.insert(ignore, inst) end
	if root:IsA("Model") then table.insert(ignore, root) end

	local control: Vector3? = nil
	if path == "bezier" then
		local upAxis = math.abs(forward:Dot(Vector3.yAxis)) > 0.9 and Vector3.xAxis or Vector3.yAxis
		control = (startPos + endPos) * 0.5 + upAxis * ctrlDist
	end

	if path == "bounce" then
		local bounceCount = 3
		local bounceHeights = {amp * 1.2, amp, amp * 0.6}
		local segmentTime = totalTime / bounceCount
		local bounceIndex = 1
		local localTime = 0
		local conn; conn = RunService.Heartbeat:Connect(function(dt)
			if not root or not root.Parent then if conn then conn:Disconnect() end return end

			elapsed += dt
			localTime += dt
			if elapsed > maxTime then if onHit then task.spawn(onHit, nil) end if conn then conn:Disconnect() end return end

			if bounceIndex > bounceCount then
				if onHit then task.spawn(onHit, nil) end
				if conn then conn:Disconnect() end
				return
			end

			local startT = (bounceIndex - 1) / bounceCount
			local endT = bounceIndex / bounceCount
			local p0 = startPos:Lerp(endPos, startT)
			local p2 = startPos:Lerp(endPos, endT)
			local ctrl = (p0 + p2) / 2 + Vector3.yAxis * bounceHeights[bounceIndex]
			local bounceT = math.clamp(localTime / segmentTime, 0, 1)
			targetPos = bezier2(p0, ctrl, p2, bounceT)

			local cast = segmentCast(lastPos, targetPos, ignore)
			if cast then
				setTransform(root, cast.Position, forward)
				if onHit then task.spawn(onHit, cast.Instance) end
				if conn then conn:Disconnect() end
				return
			end

			local look = (targetPos - lastPos); if look.Magnitude < 1e-6 then look = forward end
			setTransform(root, targetPos, look.Unit)
			lastPos = targetPos

			if bounceT >= 1 then
				localTime = 0
				bounceIndex += 1
			end
		end)
		return
	end

	local conn; conn = RunService.Heartbeat:Connect(function(dt)
		if not root or not root.Parent then if conn then conn:Disconnect() end return end

		elapsed += dt
		t = math.clamp(elapsed / math.max(totalTime, 1e-3), 0, 1)

		local targetPos: Vector3
		if path == "linear" then
			targetPos = startPos:Lerp(endPos, t)
		elseif path == "bezier" and control then
			targetPos = bezier2(startPos, control, endPos, t)
		elseif path == "zigzag" then
			local base = startPos:Lerp(endPos, t)
			local wiggle = math.sin(elapsed * (math.pi * 2) * freq) * amp
			targetPos = base + right * wiggle
		else
			targetPos = startPos:Lerp(endPos, t)
		end

		local cast = segmentCast(lastPos, targetPos, ignore)
		if cast then
			setTransform(root, cast.Position, forward)
			if onHit then task.spawn(onHit, cast.Instance) end
			if conn then conn:Disconnect() end
			return
		end

		local look = (targetPos - lastPos); if look.Magnitude < 1e-6 then look = forward end
		setTransform(root, targetPos, look.Unit)
		lastPos = targetPos

		if t >= 1 then
			if onHit then task.spawn(onHit, nil) end
			if conn then conn:Disconnect() end
		elseif elapsed > maxTime then
			warn("[ProjectileMotion] Timeout")
			if conn then conn:Disconnect() end
		end
	end)
end

return Motion
