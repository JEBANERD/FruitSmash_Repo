--!strict

local CameraFeelBus = {}

local requestEvent = Instance.new("BindableEvent")
requestEvent.Name = "CameraFeelRequest"

local function emit(kind: string, payload: any?)
        requestEvent:Fire(kind, payload)
end

function CameraFeelBus.Connect(listener: (string, any?) -> ()): RBXScriptConnection
        return requestEvent.Event:Connect(listener)
end

function CameraFeelBus.HitShake(scale: number?)
        local clamped = if typeof(scale) == "number" then math.max(scale, 0) else 1
        emit("shake", {
                profile = "hit",
                scale = clamped,
        })
end

function CameraFeelBus.CustomShake(options: {[string]: any}?)
        emit("shake", options)
end

function CameraFeelBus.TokenBump(scale: number?)
        local clamped = if typeof(scale) == "number" then math.max(scale, 0) else 1
        emit("token", {
                scale = clamped,
        })
end

function CameraFeelBus.ReportSprint(active: boolean)
        emit("sprint", {
                active = active == true,
        })
end

function CameraFeelBus.Emit(kind: string, payload: any?)
        emit(kind, payload)
end

return CameraFeelBus
