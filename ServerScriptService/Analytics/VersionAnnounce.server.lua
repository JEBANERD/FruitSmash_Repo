--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DEFAULT_VERSION = string.format("place-%d", game.PlaceVersion)
local DEFAULT_COMMIT = "local-dev"

local version = DEFAULT_VERSION
local commit = DEFAULT_COMMIT
local generatedAt: string? = nil

local function applyBuildInfo(info: any)
    if typeof(info) ~= "table" then
        return
    end

    local cast = info :: any
    if typeof(cast.Version) == "string" and cast.Version ~= "" then
        version = cast.Version
    end
    if typeof(cast.Commit) == "string" and cast.Commit ~= "" then
        commit = cast.Commit
    end
    if typeof(cast.GeneratedAt) == "string" and cast.GeneratedAt ~= "" then
        generatedAt = cast.GeneratedAt
    end
end

local buildInfoModule = ReplicatedStorage:FindFirstChild("Shared")
if buildInfoModule then
    buildInfoModule = (buildInfoModule :: Instance):FindFirstChild("Config")
    if buildInfoModule then
        local module = (buildInfoModule :: Instance):FindFirstChild("BuildInfo")
        if module and module:IsA("ModuleScript") then
            local ok, info = pcall(require, module)
            if ok then
                applyBuildInfo(info)
            end
        end
    end
end

local okFlags, flagsModule = pcall(function()
    return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Flags"))
end)
if okFlags and typeof(flagsModule) == "table" then
    local metadata = (flagsModule :: any).Metadata
    applyBuildInfo(metadata)
end

local scriptVersion = script:GetAttribute("Version")
if typeof(scriptVersion) == "string" and scriptVersion ~= "" then
    version = scriptVersion
end

local scriptCommit = script:GetAttribute("Commit")
if typeof(scriptCommit) == "string" and scriptCommit ~= "" then
    commit = scriptCommit
end

local gameVersionAttr = game:GetAttribute("BuildVersion")
if typeof(gameVersionAttr) == "string" and gameVersionAttr ~= "" then
    version = gameVersionAttr
end

local gameCommitAttr = game:GetAttribute("BuildCommit")
if typeof(gameCommitAttr) == "string" and gameCommitAttr ~= "" then
    commit = gameCommitAttr
end

local tokens = {}

local function pushToken(label: string, value: string?)
    if typeof(value) == "string" and value ~= "" then
        table.insert(tokens, string.format("%s=%s", label, value))
    end
end

pushToken("version", version)
pushToken("commit", commit)
pushToken("generated", generatedAt)
pushToken("place", tostring(game.PlaceId))
pushToken("job", game.JobId ~= "" and game.JobId or nil)

local messageBody = table.concat(tokens, " ")
if messageBody == "" then
    messageBody = "version=unknown"
end

local prettyVersion = version ~= "" and version or "unknown"
local prettyCommit = commit ~= "" and commit or "unknown"
local metadataSuffix = messageBody ~= "" and string.format(" [%s]", messageBody) or ""

print(string.format("[VersionAnnounce] FruitSmash v%s (commit %s)%s", prettyVersion, prettyCommit, metadataSuffix))

pcall(game.SetAttribute, game, "BuildVersion", version)
pcall(game.SetAttribute, game, "BuildCommit", commit)
if generatedAt then
    pcall(game.SetAttribute, game, "BuildGeneratedAt", generatedAt)
end
