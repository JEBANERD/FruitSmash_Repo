--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local CameraFeelBus = require(script.Parent:WaitForChild("CameraFeelBus"))

local MAX_SHAKE_INTENSITY = 1
local DEFAULT_HIT_AMPLITUDE = 0.36
local DEFAULT_SHAKE_DURATION = 0.20
local DEFAULT_SHAKE_FREQUENCY = 12
local DEFAULT_SHAKE_DAMPING = 1.8
local MAX_SHAKE_AMPLITUDE = 0.6

local TOKEN_SHAKE_AMPLITUDE = 0.22
local TOKEN_SHAKE_DURATION = 0.16
local TOKEN_SHAKE_FREQUENCY = 14
local TOKEN_SHAKE_DAMPING = 1.3
local TOKEN_FOV_IMPULSE = 2.5

local SPRINT_FOV_MAX = 10
local FOV_SMOOTH_RATE = 12
local FOV_MIN = 40
local FOV_MAX = 95
local FOV_IMPULSE_MAX = 6
local FOV_IMPULSE_DECAY = 10

local cameraShakeStrength = 0.7
local sprintActive = false

local activeCamera: Camera? = nil
local activeShakeConn: RBXScriptConnection? = nil
local activeShakeCamera: Camera? = nil
local activeShakeOffset = Vector3.zero

local baseFOV = 70
local currentFOV = 70
local targetFOV = 70
local fovImpulse = 0

local function updateShakeStrength()
        local attr = localPlayer:GetAttribute("CameraShakeStrength")
        if typeof(attr) == "number" then
                cameraShakeStrength = math.clamp(attr, 0, MAX_SHAKE_INTENSITY)
        else
                cameraShakeStrength = 0.7
        end
end

local function clearShake()
        if activeShakeConn then
                activeShakeConn:Disconnect()
                activeShakeConn = nil
        end

        if activeShakeCamera and activeShakeOffset.Magnitude > 0 then
                local camera = activeShakeCamera
                local offset = activeShakeOffset
                local ok = pcall(function()
                        camera.CFrame = camera.CFrame * CFrame.new(-offset)
                end)
                if not ok then
                        local current = Workspace.CurrentCamera
                        if current then
                                pcall(function()
                                        current.CFrame = current.CFrame * CFrame.new(-offset)
                                end)
                        end
                end
        end

        activeShakeCamera = nil
        activeShakeOffset = Vector3.zero
end

local function captureCamera(camera: Camera?)
        clearShake()
        activeCamera = camera
        if camera then
                baseFOV = camera.FieldOfView
                currentFOV = baseFOV
                targetFOV = baseFOV
        end
end

local function ensureCamera(): Camera?
        local camera = Workspace.CurrentCamera
        if camera ~= activeCamera then
                captureCamera(camera)
        end
        return camera
end

local function addFovImpulse(amount: number)
        if amount <= 0 then
                return
        end
        fovImpulse = math.clamp(fovImpulse + amount, 0, FOV_IMPULSE_MAX)
end

local function playShake(options: {[string]: any}?)
        local camera = ensureCamera()
        if not camera or cameraShakeStrength <= 0 then
                return
        end

        local scaleValue = 1
        if options and typeof(options.scale) == "number" then
                scaleValue = math.max(options.scale, 0)
        end

        local amplitude = (options and options.amplitude) or DEFAULT_HIT_AMPLITUDE
        amplitude = math.clamp(amplitude * scaleValue * cameraShakeStrength, 0, MAX_SHAKE_AMPLITUDE)
        if amplitude <= 0 then
                return
        end

        local duration = math.clamp((options and options.duration) or DEFAULT_SHAKE_DURATION, 0.05, 0.5)
        local frequency = math.clamp((options and options.frequency) or DEFAULT_SHAKE_FREQUENCY, 4, 30)
        local damping = math.clamp((options and options.damping) or DEFAULT_SHAKE_DAMPING, 1, 4)

        clearShake()

        activeShakeCamera = camera
        local startTime = os.clock()
        local seedX = math.random(1, 1000)
        local seedY = math.random(1, 1000)

        activeShakeConn = RunService.RenderStepped:Connect(function()
                local currentCamera = Workspace.CurrentCamera
                if not currentCamera or currentCamera ~= camera then
                        clearShake()
                        return
                end

                local now = os.clock()
                local elapsed = now - startTime
                local progress = elapsed / duration
                if progress >= 1 then
                        clearShake()
                        return
                end

                local life = math.max(0, 1 - progress)
                local decay = life ^ damping
                local sample = now * frequency

                local offset = Vector3.new(
                        math.noise(sample, seedX, 0),
                        math.noise(seedY, sample, 0),
                        0
                ) * amplitude * decay

                currentCamera.CFrame = currentCamera.CFrame * CFrame.new(offset - activeShakeOffset)
                activeShakeOffset = offset
        end)
end

local function updateSprintState(active: boolean)
        if sprintActive ~= active then
                sprintActive = active
        end
end

local function handleBusEvent(kind: string, payload: any?)
        if kind == "shake" then
                local options = if typeof(payload) == "table" then payload else nil
                local profile = options and options.profile
                if profile == "hit" then
                        playShake({
                                amplitude = DEFAULT_HIT_AMPLITUDE,
                                duration = 0.22,
                                frequency = 12,
                                damping = 1.9,
                                scale = options and options.scale or 1,
                        })
                else
                        playShake(options)
                end
        elseif kind == "token" then
                local scaleValue = 1
                if typeof(payload) == "table" and typeof((payload :: any).scale) == "number" then
                        scaleValue = math.max((payload :: any).scale, 0)
                end

                playShake({
                        amplitude = TOKEN_SHAKE_AMPLITUDE,
                        duration = TOKEN_SHAKE_DURATION,
                        frequency = TOKEN_SHAKE_FREQUENCY,
                        damping = TOKEN_SHAKE_DAMPING,
                        scale = scaleValue,
                })

                addFovImpulse(TOKEN_FOV_IMPULSE * cameraShakeStrength * scaleValue)
        elseif kind == "sprint" then
                local active = false
                if typeof(payload) == "table" and (payload :: any).active == true then
                        active = true
                end
                updateSprintState(active)
        end
end

local function updateFov(dt: number)
        local camera = ensureCamera()
        if not camera then
                return
        end

        if not sprintActive and fovImpulse == 0 then
                local actualFov = camera.FieldOfView
                if math.abs(actualFov - baseFOV) > 0.5 and math.abs(actualFov - currentFOV) > 0.5 then
                        baseFOV = actualFov
                        currentFOV = actualFov
                        targetFOV = actualFov
                end
        end

        if fovImpulse > 0 then
                fovImpulse *= math.exp(-FOV_IMPULSE_DECAY * dt)
                if fovImpulse < 0.05 then
                        fovImpulse = 0
                end
        end

        local sprintBoost = if sprintActive then cameraShakeStrength * SPRINT_FOV_MAX else 0
        targetFOV = math.clamp(baseFOV + sprintBoost + fovImpulse, FOV_MIN, FOV_MAX)

        local alpha = 1 - math.exp(-FOV_SMOOTH_RATE * dt)
        if alpha > 0 then
                currentFOV += (targetFOV - currentFOV) * alpha
        else
                currentFOV = targetFOV
        end

        if math.abs(currentFOV - camera.FieldOfView) > 0.01 then
                camera.FieldOfView = currentFOV
        end
end

updateShakeStrength()
localPlayer:GetAttributeChangedSignal("CameraShakeStrength"):Connect(updateShakeStrength)

CameraFeelBus.Connect(function(kind: string, payload: any?)
        handleBusEvent(kind, payload)
end)

if Workspace.CurrentCamera then
        captureCamera(Workspace.CurrentCamera)
end

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        captureCamera(Workspace.CurrentCamera)
end)

RunService.RenderStepped:Connect(function(dt)
        updateFov(dt)
end)
