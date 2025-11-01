local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ProjectileMotionServer = {}

local DEFAULT_SPEED = 60
local DEFAULT_UP = Vector3.new(0, 1, 0)
local TWO_PI = math.pi * 2

local active = {}

local function getRoot(model)
	if typeof(model) == "Instance" then
		if model:IsA("BasePart") then
			return model
		elseif model:IsA("Model") then
			return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
		end
	end

	return nil
end

local function applyNetworkOwnership(model)
	if typeof(model) ~= "Instance" then
		return
	end

	if model:IsA("BasePart") then
		local ok, err = pcall(function()
			model:SetNetworkOwner(nil)
		end)
		if not ok then
			warn("ProjectileMotionServer: unable to claim network ownership for", model:GetFullName(), err)
		end
		return
	end

	if model:IsA("Model") then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				local ok, err = pcall(function()
					descendant:SetNetworkOwner(nil)
				end)
				if not ok then
					warn("ProjectileMotionServer: unable to claim network ownership for", descendant:GetFullName(), err)
				end
			end
		end
	end
end

local function applyTransform(target, cframe)
	if target:IsA("Model") then
		target:PivotTo(cframe)
	elseif target:IsA("BasePart") then
		target.CFrame = cframe
	end

	local root = getRoot(target)
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

local function resolveSpeed(model, profile)
	local attributeSpeed = nil
	if model:IsA("Model") then
		local root = getRoot(model)
		if root then
			attributeSpeed = root:GetAttribute("Speed")
		end
	end

	if attributeSpeed == nil then
		attributeSpeed = model:GetAttribute("Speed")
	end

	if attributeSpeed == nil and typeof(profile) == "table" then
		attributeSpeed = profile.Speed
	end

	if typeof(attributeSpeed) ~= "number" then
		return DEFAULT_SPEED
	end

	return attributeSpeed
end

local function resolveProfileType(pathProfile)
	if typeof(pathProfile) == "string" then
		return string.lower(pathProfile)
	end

	if typeof(pathProfile) == "table" then
		local profileType = pathProfile.Profile or pathProfile.Type or pathProfile.Kind or pathProfile.Mode or pathProfile.Name
		if typeof(profileType) == "string" then
			return string.lower(profileType)
		end
	end

	return "straight"
end

local function ensureUpVector(forward, up)
	if typeof(up) ~= "Vector3" then
		up = DEFAULT_UP
	end

	if forward.Magnitude == 0 then
		return up.Unit
	end

	local aligned = math.abs(forward.Unit:Dot(up.Unit))
	if aligned >= 0.995 then
		if math.abs(forward.Unit.Y) < 0.995 then
			up = DEFAULT_UP
		else
			up = Vector3.new(1, 0, 0)
		end
	end

	return up.Unit
end

local function createBasis(position, forward, upHint)
	local forwardDir = forward.Magnitude > 0 and forward.Unit or Vector3.new(0, 0, -1)
	local upDir = ensureUpVector(forwardDir, upHint)
	local rightDir = forwardDir:Cross(upDir)
	if rightDir.Magnitude < 1e-4 then
		rightDir = forwardDir:Cross(DEFAULT_UP)
	end
	rightDir = rightDir.Unit
	upDir = rightDir:Cross(forwardDir).Unit

	return CFrame.fromMatrix(position, rightDir, upDir, forwardDir), forwardDir, upDir, rightDir
end

local function buildStraightState(model, profile, initialPosition, forward, up)
	local speed = resolveSpeed(model, profile)
	local _, forwardDir, upDir, rightDir = createBasis(initialPosition, forward, up)

	return {
		speed = speed,
		forward = forwardDir,
		up = upDir,
		right = rightDir,
		position = initialPosition,
	}
end

local function straightStep(state, dt)
	state.position += state.forward * state.speed * dt
	return CFrame.fromMatrix(state.position, state.right, state.up, state.forward)
end

local function buildZigState(model, profile, initialPosition, forward, up)
	local state = buildStraightState(model, profile, initialPosition, forward, up)
	state.frequency = (profile and profile.Frequency) or 4
	state.amplitude = (profile and profile.Amplitude) or 4
	state.phase = 0
	state.lastLateral = 0
	return state
end

local function zigStep(state, dt)
	state.phase += state.frequency * TWO_PI * dt
	local lateral = math.sin(state.phase) * state.amplitude
	local deltaLateral = lateral - state.lastLateral
	state.lastLateral = lateral
	state.position += state.forward * state.speed * dt
	state.position += state.right * deltaLateral

	return CFrame.fromMatrix(state.position, state.right, state.up, state.forward)
end

local function buildArcState(model, profile, initialPosition, forward, up)
	local speed = resolveSpeed(model, profile)
	local launchAngle = profile and profile.LaunchAngle or 30
	launchAngle = math.rad(launchAngle)

	local gravity = profile and profile.Gravity
	if typeof(gravity) ~= "Vector3" then
		gravity = Vector3.new(0, -Workspace.Gravity, 0)
	end

	local forwardDir = forward.Magnitude > 0 and forward.Unit or Vector3.new(0, 0, -1)
	local upDir = ensureUpVector(forwardDir, up)
	local rightDir = forwardDir:Cross(upDir)
	if rightDir.Magnitude < 1e-4 then
		rightDir = forwardDir:Cross(DEFAULT_UP)
	end
	rightDir = rightDir.Unit
	upDir = rightDir:Cross(forwardDir).Unit

	local horizontalSpeed = math.cos(launchAngle) * speed
	local verticalSpeed = math.sin(launchAngle) * speed

	local velocity = forwardDir * horizontalSpeed + upDir * verticalSpeed

	return {
		position = initialPosition,
		velocity = velocity,
		gravity = gravity,
		forward = forwardDir,
		up = upDir,
		right = rightDir,
	}
end

local function arcStep(state, dt)
	state.velocity += state.gravity * dt
	state.position += state.velocity * dt

	local forward = state.velocity.Magnitude > 0.01 and state.velocity.Unit or state.forward
	local right = forward:Cross(state.up)
	if right.Magnitude < 1e-4 then
		right = state.right
	else
		right = right.Unit
	end
	local up = right:Cross(forward)
	if up.Magnitude < 1e-4 then
		up = state.up
	else
		up = up.Unit
	end

	state.forward = forward
	state.up = up
	state.right = right

	return CFrame.fromMatrix(state.position, right, up, forward)
end

local function buildWobbleState(model, profile, initialPosition, forward, up)
	local state = buildStraightState(model, profile, initialPosition, forward, up)
	state.frequency = (profile and profile.Frequency) or 2
	state.amplitude = math.rad((profile and profile.AmplitudeDegrees) or 10)
	state.elapsed = 0
	state.baseFrame = CFrame.fromMatrix(Vector3.zero, state.right, state.up, state.forward)
	return state
end

local function wobbleStep(state, dt)
	state.elapsed += dt
	local yaw = math.sin(state.elapsed * state.frequency * TWO_PI) * state.amplitude
	local orientation = state.baseFrame * CFrame.fromAxisAngle(Vector3.new(0, 1, 0), yaw)
	local direction = orientation.LookVector
	state.position += direction * state.speed * dt
	local right = orientation.RightVector
	local up = orientation.UpVector

	state.forward = direction
	state.right = right
	state.up = up

	return CFrame.fromMatrix(state.position, right, up, direction)
end

local PROFILE_BUILDERS = {
	straight = function(model, profile, startCFrame)
		local initialPosition = startCFrame.Position
		local forward = (profile and profile.Direction) or startCFrame.LookVector
		local up = profile and profile.Up
		local state = buildStraightState(model, profile, initialPosition, forward, up)
		return state, straightStep
	end,
	zig = function(model, profile, startCFrame)
		local initialPosition = startCFrame.Position
		local forward = (profile and profile.Direction) or startCFrame.LookVector
		local up = profile and profile.Up
		local state = buildZigState(model, profile, initialPosition, forward, up)
		return state, zigStep
	end,
	arc = function(model, profile, startCFrame)
		local initialPosition = startCFrame.Position
		local forward = (profile and profile.Direction) or startCFrame.LookVector
		local up = profile and profile.Up
		local state = buildArcState(model, profile, initialPosition, forward, up)
		return state, arcStep
	end,
	wobble = function(model, profile, startCFrame)
		local initialPosition = startCFrame.Position
		local forward = (profile and profile.Direction) or startCFrame.LookVector
		local up = profile and profile.Up
		local state = buildWobbleState(model, profile, initialPosition, forward, up)
		return state, wobbleStep
	end,
}

local PROFILE_ALIASES = {
	straight = "straight",
	zigzag = "zig",
	zig = "zig",
	arc = "arc",
	parabola = "arc",
	wobble = "wobble",
}

local function getProfileBuilder(pathProfile)
	local profileType = resolveProfileType(pathProfile)
	profileType = PROFILE_ALIASES[profileType] or profileType
	return PROFILE_BUILDERS[profileType], profileType
end

function ProjectileMotionServer.Bind(model, pathProfile)
	assert(model, "model is required")

	local root = getRoot(model)
	assert(root, "ProjectileMotionServer.Bind requires a model with a root part")

	ProjectileMotionServer.Unbind(model)

	applyNetworkOwnership(model)

	local builder, profileType = getProfileBuilder(pathProfile)
	assert(builder, string.format("Unsupported projectile profile '%s'", tostring(profileType)))

	local startCFrame
	if model:IsA("Model") then
		startCFrame = model:GetPivot()
	else
		startCFrame = root.CFrame
	end

	local state, stepper = builder(model, typeof(pathProfile) == "table" and pathProfile or nil, startCFrame)
	state.model = model
	state.stepper = stepper
	state.profileType = profileType

	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		if not model.Parent then
			ProjectileMotionServer.Unbind(model)
			return
		end

		local nextCFrame = stepper(state, dt)
		if typeof(nextCFrame) ~= "CFrame" then
			warn("ProjectileMotionServer: stepper returned invalid CFrame for", model:GetFullName())
			ProjectileMotionServer.Unbind(model)
			return
		end

		applyTransform(model, nextCFrame)
	end)

	state.connection = connection
	active[model] = state

	return state
end

function ProjectileMotionServer.Unbind(model)
	local state = active[model]
	if not state then
		return
	end

	if state.connection then
		state.connection:Disconnect()
		state.connection = nil
	end

	active[model] = nil
end

return ProjectileMotionServer