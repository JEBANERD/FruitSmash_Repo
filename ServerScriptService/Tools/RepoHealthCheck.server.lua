--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local PREFIX = "[RepoHealth]"

local totalChecks = 0
local failedChecks = 0

local function logResult(ok: boolean, name: string, detail: string?)
        local icon = if ok then "✅" else "❌"
        local message = string.format("%s %s %s", PREFIX, icon, name)
        if detail and detail ~= "" then
                message = string.format("%s - %s", message, detail)
        end
        print(message)
end

local function runCheck(name: string, fn: () -> any)
        totalChecks += 1
        local ok, result = pcall(fn)
        if ok then
                local detail: string? = nil
                if result ~= nil then
                        if typeof(result) == "string" then
                                detail = result
                        else
                                detail = tostring(result)
                        end
                end
                logResult(true, name, detail)
        else
                failedChecks += 1
                logResult(false, name, tostring(result))
        end
end

local function waitForCondition(condition: () -> any, timeout: number?, interval: number?)
        local limit = if timeout and timeout > 0 then timeout else 5
        local step = if interval and interval > 0 then interval else 0.1
        local start = os.clock()
        while os.clock() - start <= limit do
                local ok, value = pcall(condition)
                if ok and value then
                        return value
                end
                task.wait(step)
        end
        return nil
end

runCheck("Shared config present", function()
        local shared = ReplicatedStorage:FindFirstChild("Shared")
        assert(shared, "ReplicatedStorage.Shared missing")

        local configFolder = shared:FindFirstChild("Config")
        assert(configFolder, "Shared.Config folder missing")

        local requiredConfigs = { "GameConfig", "FruitConfig", "ShopConfig" }
        for _, moduleName in ipairs(requiredConfigs) do
                local module = configFolder:FindFirstChild(moduleName)
                assert(module, string.format("Missing Config.%s", moduleName))
                assert(module:IsA("ModuleScript"), string.format("Config.%s is not a ModuleScript", moduleName))
        end

        local gameConfigModule = require(configFolder:WaitForChild("GameConfig"))
        local gameConfig = if typeof(gameConfigModule) == "table" and typeof(gameConfigModule.Get) == "function"
                then gameConfigModule.Get()
                else gameConfigModule
        assert(typeof(gameConfig) == "table", "GameConfig did not return a table")

        local uiSection = gameConfig.UI
        assert(typeof(uiSection) == "table", "GameConfig.UI missing")
        assert(typeof(uiSection.UseQuickbar) == "boolean", "UI.UseQuickbar must be a boolean")

        local matchSection = gameConfig.Match
        assert(typeof(matchSection) == "table", "GameConfig.Match missing")
        assert(typeof(matchSection.UseTeleport) == "boolean", "Match.UseTeleport must be a boolean")

        return string.format("UI.UseQuickbar=%s, Match.UseTeleport=%s",
                tostring(uiSection.UseQuickbar), tostring(matchSection.UseTeleport))
end)

runCheck("ServerStorage arena templates", function()
        local templates = ServerStorage:FindFirstChild("ArenaTemplates")
        assert(templates, "Missing ServerStorage.ArenaTemplates")
        local baseArena = templates:FindFirstChild("BaseArena")
        assert(baseArena, "Missing ServerStorage.ArenaTemplates.BaseArena")
        return "BaseArena located"
end)

runCheck("RemoteBootstrap remotes", function()
        local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
        assert(remotesFolder, "ReplicatedStorage.Remotes missing")

        local remoteModule = remotesFolder:FindFirstChild("RemoteBootstrap")
        assert(remoteModule and remoteModule:IsA("ModuleScript"), "RemoteBootstrap module missing")
        local remotes = require(remoteModule)
        assert(typeof(remotes) == "table", "RemoteBootstrap returned unexpected type")

        local requiredRemotes = {
                { key = "GameStart", className = "RemoteEvent" },
                { key = "RE_QuickbarUpdate", className = "RemoteEvent" },
                { key = "RF_UseToken", className = "RemoteFunction" },
        }

        local verified = {}
        for _, info in ipairs(requiredRemotes) do
                local remote = remotes[info.key]
                assert(remote, string.format("Missing remotes.%s", info.key))
                assert(remote.ClassName == info.className,
                        string.format("%s expected %s, found %s", info.key, info.className, remote.ClassName))
                table.insert(verified, info.key)
        end

        return "Verified: " .. table.concat(verified, ", ")
end)

runCheck("GameServer task modules", function()
        local gameServer = ServerScriptService:FindFirstChild("GameServer")
        assert(gameServer, "ServerScriptService.GameServer missing")

        local requiredModules = {
                { name = "AnalyticsServer", className = "Script" },
                { name = "ArenaAdapter", className = "ModuleScript" },
                { name = "ArenaServer", className = "ModuleScript" },
                { name = "ArenaTemplateSetup", className = "Script" },
                { name = "FruitSpawnerServer", className = "ModuleScript" },
                { name = "HUDServer", className = "ModuleScript" },
                { name = "MatchmakingServer", className = "ModuleScript" },
                { name = "ProjectileMotionServer", className = "ModuleScript" },
                { name = "ProjectileServer", className = "ModuleScript" },
                { name = "QuickbarServer", className = "ModuleScript" },
                { name = "RoundDirectorServer", className = "ModuleScript" },
                { name = "TargetHealthServer", className = "ModuleScript" },
                { name = "TokenEffectsServer", className = "ModuleScript" },
                { name = "TokenUseServer", className = "Script" },
                { name = "TurretControllerServer", className = "ModuleScript" },
        }

        local missing = {}
        local wrongClass = {}
        for _, requirement in ipairs(requiredModules) do
                local inst = gameServer:FindFirstChild(requirement.name)
                if not inst then
                        table.insert(missing, requirement.name)
                else
                        if requirement.className and not inst:IsA(requirement.className) then
                                table.insert(wrongClass,
                                        string.format("%s is %s", requirement.name, inst.ClassName))
                        elseif not inst:IsA("LuaSourceContainer") then
                                table.insert(wrongClass,
                                        string.format("%s is not a script/module", requirement.name))
                        end
                end
        end

        if #missing > 0 then
                error("Missing: " .. table.concat(missing, ", "))
        end
        if #wrongClass > 0 then
                error("Wrong class: " .. table.concat(wrongClass, "; "))
        end

        return string.format("%d modules verified", #requiredModules)
end)

runCheck("RF_UseToken mock invoke", function()
        local remotes = require(ReplicatedStorage.Remotes.RemoteBootstrap)
        local rf = remotes.RF_UseToken
        assert(rf, "RF_UseToken missing")
        assert(rf:IsA("RemoteFunction"), "RF_UseToken is not a RemoteFunction")

        local handler = waitForCondition(function()
                return if typeof(rf.OnServerInvoke) == "function" then rf.OnServerInvoke else nil
        end, 8, 0.25)
        assert(handler, "RF_UseToken.OnServerInvoke not ready")

        local player = Players:GetPlayers()[1]
        if not player then
                player = waitForCondition(function()
                        return Players:GetPlayers()[1]
                end, 10, 0.25)
        end
        assert(player, "No players available for RF_UseToken test")

        local ok, response = pcall(handler, player, { slot = 1 })
        assert(ok, "RF_UseToken handler errored: " .. tostring(response))
        assert(typeof(response) == "table", "RF_UseToken did not return a table")
        assert(response.ok == false, "Expected ok=false response")

        local errMsg = if typeof(response.err) == "string" then response.err elseif typeof(response.error) == "string" then response.error else "none"
        return "response.err=" .. errMsg
end)

local passed = totalChecks - failedChecks
local summaryIcon = if failedChecks == 0 then "✅" else "❌"
print(string.format("%s %s Summary: %d/%d checks passed", PREFIX, summaryIcon, passed, totalChecks))
