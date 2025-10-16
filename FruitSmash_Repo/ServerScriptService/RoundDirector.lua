-- RoundDirector (SERVER, FINAL HUD SYNC)
-- Tokenized rounds + late-joiner sync + dual fast-start support + robust cleanup + shield reset

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Modules = RS:WaitForChild("Modules")
local ShieldState = require(Modules:WaitForChild("ShieldState"))
local PowerupEffects = require(script.Parent:WaitForChild("PowerupEffects"))

-- === CONFIG ===
local DEFAULT_COUNTDOWN = 10
local FAST_COUNTDOWN = 3
local POST_COUNTDOWN_GRACE = 2
local INTERMISSION_EVERY = 5
local INTERMISSION_TIME = 30

-- === REMOTES / VALUES ===
local Remotes = RS:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = RS
end

local function ensureRemoteEvent(name: string): RemoteEvent
	local e = Remotes:FindFirstChild(name)
	if not e then
		e = Instance.new("RemoteEvent")
		e.Name = name
		e.Parent = Remotes
	end
	return e :: RemoteEvent
end

local function ensureBindable(name: string): BindableEvent
	local b = Remotes:FindFirstChild(name)
	if not b then
		b = Instance.new("BindableEvent")
		b.Name = name
		b.Parent = Remotes
	end
	return b :: BindableEvent
end

local StartCountdown    = ensureRemoteEvent("StartCountdown")
local RestartRequested  = ensureRemoteEvent("RestartRequested")
local RoundUpdate       = ensureRemoteEvent("RoundUpdate")
local RoundPointsAdd    = ensureBindable("RoundPointsAdd")

local FastStartFlag = RS:FindFirstChild("FastStartRequested") :: BoolValue
if not FastStartFlag then
	FastStartFlag = Instance.new("BoolValue")
	FastStartFlag.Name = "FastStartRequested"
	FastStartFlag.Value = false
	FastStartFlag.Parent = RS
end

local RequestFastStart  = Remotes:FindFirstChild("RequestFastStart") :: BindableEvent?

-- Global game-active flag
local GameActive = RS:FindFirstChild("GameActive") :: BoolValue
if not GameActive then
	GameActive = Instance.new("BoolValue")
	GameActive.Name = "GameActive"
	GameActive.Value = false
	GameActive.Parent = RS
end

-- === GLOBAL SHIELD FLAG (new integration) ===
local TargetShieldFlag = RS:FindFirstChild("TargetShieldActive") :: BoolValue
if not TargetShieldFlag then
	TargetShieldFlag = Instance.new("BoolValue")
	TargetShieldFlag.Name = "TargetShieldActive"
	TargetShieldFlag.Value = false
	TargetShieldFlag.Parent = RS
end

-- === ROUND STATE FOLDER ===
local RoundState = RS:FindFirstChild("RoundState")
if not RoundState then
	RoundState = Instance.new("Folder")
	RoundState.Name = "RoundState"
	RoundState.Parent = RS
end

local function ensureValue(container: Instance, className: string, name: string, default: any)
	local v = container:FindFirstChild(name)
	if not v then
		v = Instance.new(className)
		v.Name = name
		v.Value = default
		v.Parent = container
	end
	return v
end

local RoundNumber    = ensureValue(RoundState, "IntValue",    "RoundNumber",    1) :: IntValue
local RoundGoal      = ensureValue(RoundState, "IntValue",    "RoundGoal",      100) :: IntValue
local RoundPoints    = ensureValue(RoundState, "IntValue",    "RoundPoints",    0) :: IntValue
local RoundIntensity = ensureValue(RoundState, "NumberValue", "RoundIntensity", 1) :: NumberValue

-- === INTERNAL STATE ===
local phase = "idle"
local roundToken = 0
local currentCountdownEndsAt: number? = nil

-- === HELPERS ===
local function computeIntensity(round: number)
	return 1 + (round - 1) * 0.25
end

local function computeGoal(round: number)
	return 100 + (round - 1) * 50
end

local function broadcastRoundUpdate()
	RoundUpdate:FireAllClients({
		round = RoundNumber.Value,
		goal = RoundGoal.Value,
		points = RoundPoints.Value,
		intensity = RoundIntensity.Value,
		phase = phase
	})
end

local function setPhase(newPhase: string)
	phase = newPhase
	broadcastRoundUpdate()
end

-- === NEW: Reset all shield states globally & locally ===
local function resetAllShields()
        PowerupEffects.ClearAllShields()
        TargetShieldFlag.Value = false

        local lanes = Workspace:FindFirstChild("Lanes")
        if lanes then
                for _, lane in ipairs(lanes:GetChildren()) do
                        local t = lane:FindFirstChild("Target")
                        if t then
                                ShieldState.Set(t, false)
                                local shieldBubble = t:FindFirstChild("TargetShieldBubble")
                                if shieldBubble then
                                        shieldBubble:Destroy()
                                end
                        end
                end
        end
        print("[RoundDirector] 🛡️ All shields reset (local + global).")
end
-- Just after creating TargetShieldFlag
TargetShieldFlag.Changed:Connect(function(newVal)
	if newVal then
		print("[RoundDirector] 🛡️ Global shield activated (power-up triggered).")
	else
		print("[RoundDirector] 🔓 Global shield deactivated (expired or reset).")
	end
end)



-- Robust cleanup: removes foldered fruits and any stray tagged bits
local function clearProjectiles()
	local folder = Workspace:FindFirstChild("ActiveProjectiles")
	if folder and folder:IsA("Folder") then
		for _, c in ipairs(folder:GetChildren()) do
			c:Destroy()
		end
	end
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:GetAttribute("FruitName") ~= nil then
			inst:Destroy()
		elseif inst:IsA("LinearVelocity") and inst.Name == "StraightFlight" then
			local parent = inst.Parent
			if parent and parent:GetAttribute("FruitName") ~= nil then
				parent:Destroy()
			else
				inst:Destroy()
			end
		end
	end

	-- 🧹 Also clear any shield remnants on projectile cleanup
	resetAllShields()
end

local function resetAllTargetsHP()
	local lanes = Workspace:FindFirstChild("Lanes")
	if not lanes then return end
	for _, lane in ipairs(lanes:GetChildren()) do
		local target = lane:FindFirstChild("Target")
		if target then
			local health = target:FindFirstChild("Health")
			local max = target:FindFirstChild("MaxHealth")
			if health and max and health:IsA("NumberValue") and max:IsA("NumberValue") then
				health.Value = max.Value
			end
			-- 🩹 Clear shields on reset
                        ShieldState.Set(target, false)
                        local shieldBubble = target:FindFirstChild("TargetShieldBubble")
                        if shieldBubble then
                                shieldBubble:Destroy()
                        end
		end
	end
	TargetShieldFlag.Value = false
end

-- Cancels ANY in-progress round setup
local function abortCountdown()
	roundToken += 1
	currentCountdownEndsAt = nil
	GameActive.Value = false
	setPhase("idle")
	clearProjectiles()
	resetAllShields()
end

-- === ROUND LOGIC ===
local function beginRound(countdownSeconds: number, opts: { resetTargets: boolean? }?)
	local token = roundToken + 1
	roundToken = token

	GameActive.Value = false
	currentCountdownEndsAt = os.clock() + countdownSeconds
	clearProjectiles()
	resetAllShields()

	if opts and opts.resetTargets then
		resetAllTargetsHP()
	end

	RoundPoints.Value = 0
	setPhase("countdown")

	StartCountdown:FireAllClients(countdownSeconds, token)

	task.spawn(function()
		task.wait(math.max(1, countdownSeconds))
		if roundToken ~= token then return end

		setPhase("grace")
		task.wait(POST_COUNTDOWN_GRACE)
		if roundToken ~= token then return end

		GameActive.Value = true
		setPhase("active")
	end)
end

local function endRound()
	GameActive.Value = false
	clearProjectiles()
	resetAllShields()

	if RoundNumber.Value < 1 then
		RoundNumber.Value = 1
	end

	if RoundNumber.Value >= INTERMISSION_EVERY
		and (RoundNumber.Value % INTERMISSION_EVERY == 0) then
		setPhase("intermission")
		print("[RoundDirector] 🛒 Intermission phase (shop time).")
		task.wait(INTERMISSION_TIME)
	else
		setPhase("idle")
	end

	RoundNumber.Value += 1
	RoundIntensity.Value = computeIntensity(RoundNumber.Value)
	RoundGoal.Value = computeGoal(RoundNumber.Value)
	RoundPoints.Value = 0
	broadcastRoundUpdate()

	beginRound(DEFAULT_COUNTDOWN, { resetTargets = false })
end

-- === BOOT ===
task.defer(function()
	print("[RoundDirector] ✅ Loaded — HUD linked, tokenized countdown.")
	RoundIntensity.Value = computeIntensity(RoundNumber.Value)
	RoundGoal.Value = computeGoal(RoundNumber.Value)
	resetAllShields()
	beginRound(DEFAULT_COUNTDOWN, { resetTargets = true })
end)

-- === LATE-JOINER SYNC ===
Players.PlayerAdded:Connect(function(plr)
	RoundUpdate:FireClient(plr, {
		round = RoundNumber.Value,
		goal = RoundGoal.Value,
		points = RoundPoints.Value,
		intensity = RoundIntensity.Value,
		phase = phase
	})

	if phase == "countdown" or phase == "grace" then
		local remain = 3
		if currentCountdownEndsAt then
			remain = math.max(1, math.ceil(currentCountdownEndsAt - os.clock()))
		end
		StartCountdown:FireClient(plr, remain, roundToken)
	end
end)

-- === SCORE UPDATES ===
RoundPointsAdd.Event:Connect(function(amount)
	if typeof(amount) ~= "number" then return end
	RoundPoints.Value = math.max(0, RoundPoints.Value + amount)
	broadcastRoundUpdate()
end)

RoundPoints:GetPropertyChangedSignal("Value"):Connect(function()
	if RoundPoints.Value >= RoundGoal.Value and phase == "active" then
		endRound()
	end
end)

-- === FAST START (Bool Flag) ===
FastStartFlag:GetPropertyChangedSignal("Value"):Connect(function()
	if not FastStartFlag.Value then return end
	FastStartFlag.Value = false

	if phase == "intermission" then
		print("[RoundDirector] Ignored fast start during intermission.")
		return
	end

	if phase == "countdown" or phase == "grace" then
		abortCountdown()
	end
	if phase ~= "active" then
		print("[RoundDirector] ⚡ Fast start → 3s countdown (flag).")
		beginRound(FAST_COUNTDOWN, { resetTargets = false })
	end
end)

-- === FAST START (BindableEvent) ===
if RequestFastStart and RequestFastStart.IsA and RequestFastStart:IsA("BindableEvent") then
	RequestFastStart.Event:Connect(function()
		if phase == "intermission" then
			print("[RoundDirector] Ignored fast start during intermission (bindable).")
			return
		end
		if phase == "countdown" or phase == "grace" then
			abortCountdown()
		end
		if phase ~= "active" then
			print("[RoundDirector] ⚡ Fast start → 3s countdown (bindable).")
			beginRound(FAST_COUNTDOWN, { resetTargets = false })
		end
	end)
end

-- === RESTART HANDLER ===
local lastRestartAt = 0
local RESTART_COOLDOWN = 5

local function isTrusted(plr: Player): boolean
	return plr.UserId == game.CreatorId
end

RestartRequested.OnServerEvent:Connect(function(plr: Player)
	local now = os.clock()
	if (now - lastRestartAt) < RESTART_COOLDOWN then return end
	lastRestartAt = now

	if not isTrusted(plr) then
		warn("[RoundDirector] Restart denied for non-trusted player: ", plr and plr.Name)
		return
	end

	print("[RoundDirector] 🔁 Restart requested by", plr.Name)
	abortCountdown()
	resetAllTargetsHP()
	resetAllShields()

	RoundNumber.Value = 1
	RoundIntensity.Value = computeIntensity(1)
	RoundGoal.Value = computeGoal(1)
	RoundPoints.Value = 0
	broadcastRoundUpdate()

	beginRound(DEFAULT_COUNTDOWN, { resetTargets = false })
end)

