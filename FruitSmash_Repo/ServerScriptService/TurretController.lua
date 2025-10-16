-- TurretController (SERVER)
-- Dynamic combo sequencer with stable slots and rhythmic pacing (no goto)
-- Adds "swing" and rests for readable firing rhythm that accelerates with intensity.

local RS = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- Round state from RoundDirector
local GameActive = RS:WaitForChild("GameActive")
local RoundState = RS:WaitForChild("RoundState")
local RoundIntensity = RoundState:WaitForChild("RoundIntensity")
local RoundPoints = RoundState:WaitForChild("RoundPoints")
local RoundGoal = RoundState:WaitForChild("RoundGoal")

-- Debug / test toggles
local DEBUG_LOG_FIRE = false
local SINGLE_TRACK_TEST = false

-- Base timing
local STEP_BASE_SECONDS = 3.8
local STEP_INTENSITY_SCALE = 0.30
local STEP_PROGRESS_SCALE = 0.22
local STEP_JITTER = 0.30
local STEP_MIN_SECONDS = 0.95

-- Track scaling
local TRACKS_BASE = 1
local TRACKS_PER_INTENSITY = 0.60
local TRACKS_PER_PROGRESS = 0.80
local TRACKS_MAX = 3
local TRACK_STAGGER_MIN = 0.08
local TRACK_STAGGER_MAX = 0.22

-- Lane handling
local RESCAN_LANES_EVERY = 2.0
local SORT_BY_LANE_NUMBER = true

-- Combo generator
local BASE_COMBO_LENGTH = 20
local COMBO_LENGTH_PER_INT = 10
local COMBO_LENGTH_PER_LANE = 2
local DOUBLE_CHANCE_BASE = 0.10
local DOUBLE_CHANCE_INT = 0.10
local AVOID_REPEAT_FACTOR = 0.35
local ROUND_SEED_OFFSET = 99999

-- Cursor cube visual (optional)
local ENABLE_CURSOR_CUBE = false
local CURSOR_TEMPLATE_NAME = "CursorCubeTemplate"

-- === NEW: Pacing configuration ===
local PACE = {
	CHANGE_REST = 0.12,   -- pause after switching turrets
	DOUBLE_REST = 0.06,   -- smaller pause between doubles
	SWING = 0.18,         -- alternates long/short beats
	EXTRA_JITTER = 0.05,  -- extra randomization
	MIN_WAIT = 0.06,      -- floor cap for high intensity
}

-- === Helper Functions ===
local function intensityFactor()
	return tonumber(RoundIntensity.Value) or 1
end

local function progress01()
	local goal = math.max(1, tonumber(RoundGoal.Value) or 1)
	local pts = math.max(0, tonumber(RoundPoints.Value) or 0)
	return math.clamp(pts / goal, 0, 1)
end

local function computeStepSeconds()
	local s = STEP_BASE_SECONDS
	s = s / (1 + STEP_INTENSITY_SCALE * (intensityFactor() - 1))
	s = s / (1 + STEP_PROGRESS_SCALE * progress01())
	s = s + (math.random() * 2 - 1) * STEP_JITTER
	if s < STEP_MIN_SECONDS then s = STEP_MIN_SECONDS end
	return s
end

local function computePacedWait(indexAfter, currentDigit, nextDigit)
	local base = computeStepSeconds()
	local swingFactor = (indexAfter % 2 == 1) and (1 + PACE.SWING) or (1 - PACE.SWING)
	local stepped = base * swingFactor
	local rest = (nextDigit == currentDigit) and PACE.DOUBLE_REST or PACE.CHANGE_REST
	local micro = (math.random() * 2 - 1) * PACE.EXTRA_JITTER
	return math.max(PACE.MIN_WAIT, stepped + rest + micro)
end

local function staggerDelay()
	return math.random() * (TRACK_STAGGER_MAX - TRACK_STAGGER_MIN) + TRACK_STAGGER_MIN
end

local function waitUntilActive()
	if GameActive.Value then return end
	local resumed = false
	local conn
	conn = GameActive.Changed:Connect(function()
		if GameActive.Value then
			resumed = true
			conn:Disconnect()
		end
	end)
	while not resumed and not GameActive.Value do
		task.wait(0.05)
	end
end

-- === Lane Discovery ===
local function collectTurrets()
	local list = {}
	local lanes = Workspace:FindFirstChild("Lanes")

	if lanes and lanes:IsA("Folder") then
		for _, lane in ipairs(lanes:GetChildren()) do
			if lane:IsA("Folder") then
				local t = lane:FindFirstChild("Turret")
				if t and t:IsA("Model") then
					local trig = t:FindFirstChild("FireTrigger")
					if not trig then
						trig = Instance.new("BindableEvent")
						trig.Name = "FireTrigger"
						trig.Parent = t
					end
					table.insert(list, { model = t, trigger = trig, lane = lane })
				end
			end
		end
	end

	if #list == 0 then
		local t = Workspace:FindFirstChild("Turret")
		if t and t:IsA("Model") then
			local trig = t:FindFirstChild("FireTrigger")
			if not trig then
				trig = Instance.new("BindableEvent")
				trig.Name = "FireTrigger"
				trig.Parent = t
			end
			table.insert(list, { model = t, trigger = trig, lane = nil })
		end
	end

	if SORT_BY_LANE_NUMBER then
		table.sort(list, function(a, b)
			local function numKey(name)
				local n = string.match(name or "", "(%d+)$")
				return tonumber(n) or math.huge
			end
			local an = a.lane and numKey(a.lane.Name) or numKey(a.model.Name)
			local bn = b.lane and numKey(b.lane.Name) or numKey(b.model.Name)
			if an == bn then
				return (a.model.Name or "") < (b.model.Name or "")
			end
			return an < bn
		end)
	end

	for i, info in ipairs(list) do
		if info.model then
			info.model:SetAttribute("SlotIndex", i)
		end
	end
	return list
end

-- === Firing ===
local function fireTurret(info)
	if not info or not info.model or not info.model.Parent then return end
	if not GameActive.Value then return end
	if info.trigger then
		info.trigger:Fire()
	end
	if DEBUG_LOG_FIRE then
		local slot = info.model:GetAttribute("SlotIndex") or "?"
		print(("[TC] Fired slot %s"):format(tostring(slot)))
	end
end

-- === Pattern Generation ===
local PATTERN = { 1 }
local PATTERN_STR = "1"

local function pickNextTurret(numTurrets, last)
	if numTurrets <= 1 then return 1 end
	local pick
	repeat
		pick = math.random(1, numTurrets)
	until pick ~= last or math.random() > AVOID_REPEAT_FACTOR
	return pick
end

local function generateComboDigits(numTurrets, intensity)
	numTurrets = math.max(1, numTurrets)
	local length = math.floor(
		BASE_COMBO_LENGTH +
		COMBO_LENGTH_PER_INT * math.max(0, intensity - 1) +
		COMBO_LENGTH_PER_LANE * numTurrets
	)

	local doubleChance = DOUBLE_CHANCE_BASE + DOUBLE_CHANCE_INT * (intensity - 1)
	doubleChance = math.clamp(doubleChance, 0, 0.75)

	local seq = {}
	local last = math.random(1, numTurrets)
	for _ = 1, length do
		local pick = pickNextTurret(numTurrets, last)
		table.insert(seq, pick)
		last = pick
		if math.random() < doubleChance then
			table.insert(seq, pick)
		end
	end
	return seq
end

local function rebuildPatternForRound()
	local lanes = Workspace:FindFirstChild("Lanes")
	local numTurrets = 0
	if lanes then
		for _, lane in ipairs(lanes:GetChildren()) do
			if lane:IsA("Folder") and lane:FindFirstChild("Turret") then
				numTurrets += 1
			end
		end
	end
	if numTurrets == 0 then numTurrets = 1 end

	local intensity = tonumber(RoundIntensity.Value) or 1
	math.randomseed(os.time() + ROUND_SEED_OFFSET + math.floor(intensity * 100))

	local digits = generateComboDigits(numTurrets, intensity)
	PATTERN = digits
	PATTERN_STR = table.concat(digits)

	print(string.format("[TurretController] New combo pattern (len=%d, lanes=%d, I=%.2f): %s",
		#digits, numTurrets, intensity, string.sub(PATTERN_STR, 1, 120)))
end

GameActive.Changed:Connect(function()
	if GameActive.Value then
		rebuildPatternForRound()
	end
end)

task.defer(function()
	if GameActive.Value then
		rebuildPatternForRound()
	end
end)

-- === Pacing Track Runner ===
local function runTrack(trackId, turrets, startIndex, stopSignal)
	local cursor
	if ENABLE_CURSOR_CUBE and turrets[1] then
		local tpl = RS:FindFirstChild(CURSOR_TEMPLATE_NAME)
		if tpl and tpl:IsA("BasePart") then
			cursor = tpl:Clone()
			cursor.Anchored = true
			cursor.CanCollide = false
			cursor.CanTouch = false
			cursor.CanQuery = false
			cursor.Parent = Workspace
			local bp0 = turrets[1].model:FindFirstChildWhichIsA("BasePart")
			if bp0 then cursor.CFrame = bp0.CFrame + Vector3.new(0, 4, 0) end
		end
	end

	local idx = startIndex or 1
	while not stopSignal.stop do
		waitUntilActive()
		if stopSignal.stop then break end

		local n = #PATTERN
		if n == 0 or #turrets == 0 then
			task.wait(0.1)
			continue
		end

		local digit = PATTERN[((idx - 1) % n) + 1]
		local pickIndex = ((digit - 1) % #turrets) + 1
		local pick = turrets[pickIndex]

		if pick then
			fireTurret(pick)
			if cursor then
				local bp = pick.model:FindFirstChildWhichIsA("BasePart")
				if bp then cursor.CFrame = bp.CFrame + Vector3.new(0, 4, 0) end
			end
		end

		local nextDigit = PATTERN[(idx % n) + 1]
		idx += 1

		local waitTime = computePacedWait(idx, digit, nextDigit)
		local t0 = os.clock()
		while (os.clock() - t0) < waitTime do
			if stopSignal.stop or not GameActive.Value then break end
			task.wait(0.05)
		end
	end

	if cursor then cursor:Destroy() end
end

-- === Manager Loop ===
task.spawn(function()
	math.randomseed(os.clock() % 1 * 1e7)
	local turrets = collectTurrets()
	local lastScan = os.clock()
	local tracks = {}

	local function killAllTracks()
		for _, t in ipairs(tracks) do
			t.stop.stop = true
		end
		for _, t in ipairs(tracks) do
			if t.thread and coroutine.status(t.thread) ~= "dead" then
				for _ = 1, 15 do
					if coroutine.status(t.thread) == "dead" then break end
					task.wait(0.02)
				end
			end
		end
		tracks = {}
	end

	while true do
		waitUntilActive()

		if (os.clock() - lastScan) >= RESCAN_LANES_EVERY then
			turrets = collectTurrets()
			lastScan = os.clock()
		end

		local desired = TRACKS_BASE +
			(TRACKS_PER_INTENSITY * math.max(0, intensityFactor() - 1)) +
			(TRACKS_PER_PROGRESS * progress01())
		desired = math.floor(math.clamp(desired, 1, TRACKS_MAX) + 0.5)

		if SINGLE_TRACK_TEST then desired = 1 end

		if #tracks ~= desired then
			killAllTracks()
			for i = 1, desired do
				local stopSignal = { stop = false }
				local co = coroutine.create(function()
					task.wait(staggerDelay())
					runTrack(i, turrets, i, stopSignal)
				end)
				table.insert(tracks, { thread = co, stop = stopSignal })
				coroutine.resume(co)
			end
		end

		task.wait(0.15)
	end
end)

print("[TurretController] Combo sequencer active with rhythmic pacing.")
