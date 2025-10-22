--!strict

local HttpService = game:GetService("HttpService")

type Dictionary = { [string]: any }

local TelemetryServer = {}

local sinks: { (string, Dictionary) -> () } = {}
local enabled = true

local function sanitizeValue(value: any, depth: number): any
        if depth > 4 then
                return "<max-depth>"
        end

        local valueType = typeof(value)
        if valueType == "table" then
                local copy: Dictionary = {}
                for key, item in pairs(value) do
                        local keyType = typeof(key)
                        local keyString = if keyType == "string" or keyType == "number"
                                then tostring(key)
                                else string.format("[%s]", keyType)
                        copy[keyString] = sanitizeValue(item, depth + 1)
                end
                return copy
        elseif valueType == "Instance" then
                local ok, result = pcall(function()
                        return value:GetFullName()
                end)
                return if ok then result else value.ClassName
        elseif valueType == "EnumItem" then
                return tostring(value)
        elseif valueType == "number" then
                if value ~= value or value == math.huge or value == -math.huge then
                        return 0
                end
                return value
        elseif valueType == "boolean" or valueType == "string" then
                return value
        elseif valueType == "DateTime" then
                local ok, iso = pcall(value.ToIsoDateTime, value)
                if ok then
                        return iso
                end
                return tostring(value)
        end

        return tostring(value)
end

local function buildPayload(eventName: string, data: any): Dictionary
        local payload: Dictionary = {
                event = eventName,
                timestamp = DateTime.now():ToIsoDateTime(),
        }

        if typeof(data) == "table" then
                for key, value in pairs(data) do
                        if typeof(key) == "string" then
                                payload[key] = sanitizeValue(value, 1)
                        else
                                payload[tostring(key)] = sanitizeValue(value, 1)
                        end
                end
        elseif data ~= nil then
                payload.value = sanitizeValue(data, 1)
        end

        return payload
end

local function emitPrint(eventName: string, payload: Dictionary)
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, payload)
        if ok then
                print(string.format("[Telemetry] %s %s", eventName, encoded))
        else
                print(string.format("[Telemetry] %s {encodingError=\"%s\"}", eventName, tostring(encoded)))
        end
end

local function dispatch(eventName: string, payload: Dictionary)
        emitPrint(eventName, payload)

        for _, sink in ipairs(sinks) do
                local ok, err = pcall(sink, eventName, payload)
                if not ok then
                        warn(string.format("[Telemetry] Sink failed for %s: %s", eventName, tostring(err)))
                end
        end
end

function TelemetryServer.Track(eventName: string, data: any?)
        if not enabled then
                return
        end

        if typeof(eventName) ~= "string" or eventName == "" then
                return
        end

        local payload = buildPayload(eventName, data)
        dispatch(eventName, payload)
end

function TelemetryServer.AddSink(callback: (string, Dictionary) -> ())
        if typeof(callback) ~= "function" then
                return
        end

        table.insert(sinks, callback)
end

function TelemetryServer.SetEnabled(isEnabled: boolean)
        enabled = isEnabled and true or false
end

function TelemetryServer.IsEnabled(): boolean
        return enabled
end

return TelemetryServer

