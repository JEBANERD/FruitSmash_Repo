--!strict
-- BotLoad.server.lua
-- Applies the StressConfig overrides and optionally drives headless NPC swings.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

local stressModule = script:FindFirstChild("StressConfig")
if not stressModule or not stressModule:IsA("ModuleScript") then
        warn("[StressHarness] StressConfig module missing; aborting load harness.")
        return
end

local okConfig, stressConfigRaw = pcall(require, stressModule)
if not okConfig then
        warn(string.format("[StressHarness] Failed to require StressConfig: %s", tostring(stressConfigRaw)))
        return
end

if typeof(stressConfigRaw) ~= "table" then
        warn("[StressHarness] StressConfig returned unexpected value; aborting.")
        return
end

local stressConfig = stressConfigRaw :: { [string]: any }
if stressConfig.Enabled ~= true then
        if stressConfig.Diagnostics == nil or stressConfig.Diagnostics.Verbose ~= false then
                print("[StressHarness] StressConfig disabled; harness idle.")
        end
        return
end

local diagnostics = (stressConfig.Diagnostics or {}) :: { [string]: any }
local function log(message: string, ...: any)
        if diagnostics.Verbose ~= false then
                print(string.format("[StressHarness] " .. message, ...))
        end
end

local function warnf(message: string, ...: any)
        warn(string.format("[StressHarness] " .. message, ...))
end

local cleanupCallbacks: { () -> () } = {}
local cleanupBound = false

local function registerCleanup(callback: () -> ())
        table.insert(cleanupCallbacks, callback)
        if not cleanupBound then
                cleanupBound = true
                script.Destroying:Connect(function()
                        for index = #cleanupCallbacks, 1, -1 do
                                local fn = cleanupCallbacks[index]
                                local ok, err = pcall(fn)
                                if not ok then
                                        warnf("Cleanup callback failed: %s", tostring(err))
                                end
                        end
                end)

                game:BindToClose(function()
                        for index = #cleanupCallbacks, 1, -1 do
                                local fn = cleanupCallbacks[index]
                                local ok, err = pcall(fn)
                                if not ok then
                                        warnf("Cleanup callback failed: %s", tostring(err))
                                end
                        end
                end)
        end
end

local function safeSetAttribute(target: Instance, name: string, value: any)
        local ok, err = pcall(target.SetAttribute, target, name, value)
        if not ok and diagnostics.Verbose ~= false then
                local fullName = tostring(target)
                local okName, resolved = pcall(target.GetFullName, target)
                if okName then
                        fullName = resolved
                end
                warnf("Failed to set attribute %s on %s: %s", tostring(name), fullName, tostring(err))
        end
end

if diagnostics.SetGameAttribute ~= false then
        safeSetAttribute(game, "StressHarnessActive", true)
        registerCleanup(function()
                safeSetAttribute(game, "StressHarnessActive", false)
        end)
end

local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
local configFolder = sharedFolder:WaitForChild("Config")
local gameConfigModule = require(configFolder:WaitForChild("GameConfig"))
local GameConfig = if typeof((gameConfigModule :: any).Get) == "function" then (gameConfigModule :: any).Get() else gameConfigModule

local fruitMultiplier = tonumber(stressConfig.FruitRateMultiplier) or 1
if fruitMultiplier ~= 1 then
        local turrets = GameConfig.Turrets
        if typeof(turrets) ~= "table" then
                turrets = {}
                GameConfig.Turrets = turrets
        end

        local baseShots = turrets.BaseShotsPerSecond
        if typeof(baseShots) == "number" then
                turrets.BaseShotsPerSecond = baseShots * fruitMultiplier
        else
                turrets.BaseShotsPerSecond = fruitMultiplier
        end

        local perLevel = turrets.ShotsPerLevelPct
        if typeof(perLevel) == "number" then
                turrets.ShotsPerLevelPct = perLevel * fruitMultiplier
        end

        turrets._StressMultiplier = fruitMultiplier
        log("Applied fruit rate multiplier x%.2f", fruitMultiplier)
end

local targetLaneCount = tonumber(stressConfig.TargetLaneCount)
if targetLaneCount and targetLaneCount > 0 then
        local lanes = GameConfig.Lanes
        if typeof(lanes) ~= "table" then
                lanes = {}
                GameConfig.Lanes = lanes
        end

        lanes.StartCount = targetLaneCount

        local maxCount = tonumber(lanes.MaxCount)
        if not maxCount or maxCount < targetLaneCount then
                lanes.MaxCount = targetLaneCount
        end

        lanes.UnlockAt = {}
        lanes.ExpansionSmoothingLevels = 0
        lanes.ExpansionTemporaryRatePenalty = 0
        log("Forced lane count to %d", targetLaneCount)
end

if stressConfig.ForceObstacles ~= false then
        local obstacles = GameConfig.Obstacles
        if typeof(obstacles) ~= "table" then
                obstacles = {}
                GameConfig.Obstacles = obstacles
        end
        obstacles.EnableAtLevel = 1
        log("Obstacles enabled from level 1")
end

local function firstArenaId(): string?
        local okArenaServer, arenaModule = pcall(function()
                return ServerScriptService:WaitForChild("GameServer"):WaitForChild("ArenaServer")
        end)
        if not okArenaServer then
                warnf("ArenaServer module missing: %s", tostring(arenaModule))
                return nil
        end

        local ArenaServer = require(arenaModule)
        local getAll = (ArenaServer :: any).GetAllArenas
        if typeof(getAll) == "function" then
                local okAll, arenas = pcall(getAll)
                if okAll and typeof(arenas) == "table" then
                        for id in pairs(arenas) do
                                return tostring(id)
                        end
                end
        end
        return nil
end

local autoStart = stressConfig.AutoStartArena
if typeof(autoStart) == "table" and autoStart.Enabled ~= false then
        local gameServerFolder = ServerScriptService:WaitForChild("GameServer")
        local arenaModule = gameServerFolder:WaitForChild("ArenaServer")
        local roundModule = gameServerFolder:WaitForChild("RoundDirectorServer")
        local ArenaServer = require(arenaModule)
        local RoundDirectorServer = require(roundModule)

        local arenaId = firstArenaId()
        if not arenaId then
                local partyId = if typeof(autoStart.PartyId) == "string" and autoStart.PartyId ~= "" then autoStart.PartyId else "StressHarness"
                local okSpawn, result = pcall(ArenaServer.SpawnArena, partyId)
                if okSpawn then
                        arenaId = typeof(result) == "string" and result or tostring(result)
                        log("Spawned arena %s for party %s", arenaId, partyId)
                else
                        warnf("Arena spawn failed: %s", tostring(result))
                end
        else
                log("Using existing arena %s", arenaId)
        end

        if arenaId then
                local startLevel = tonumber(autoStart.StartLevel) or 1
                task.defer(function()
                        local okStart, startErr = pcall(RoundDirectorServer.Start, arenaId, { StartLevel = startLevel })
                        if not okStart then
                                warnf("RoundDirector.Start failed: %s", tostring(startErr))
                                return
                        end

                        if autoStart.SkipPrep ~= false then
                                task.defer(function()
                                        local okSkip, skipErr = pcall(RoundDirectorServer.SkipPrep, arenaId)
                                        if not okSkip and diagnostics.Verbose ~= false then
                                                warnf("SkipPrep failed: %s", tostring(skipErr))
                                        end
                                end)
                        end
                end)
        end
end

local npcConfig = stressConfig.NpcBatters
if typeof(npcConfig) == "table" and npcConfig.Enabled == true then
        local running = true
        registerCleanup(function()
                running = false
        end)

        local hitCooldown = math.max(0, tonumber(npcConfig.HitCooldownSeconds) or 0.1)
        local swingDelay = math.max(0, tonumber(npcConfig.SwingDelaySeconds) or 0)
        local searchInterval = math.max(0.05, tonumber(npcConfig.SearchIntervalSeconds) or 0.2)
        local maxSwings = math.max(1, math.floor((tonumber(npcConfig.MaxSwingsPerCycle) or 15) + 0.5))
        local awardEnabled = npcConfig.AwardFruit == true
        local requireActivePlayers = npcConfig.AwardRequiresActivePlayers ~= false

        local economy: any = nil
        if awardEnabled then
                local okEconomy, module = pcall(function()
                        return ServerScriptService:WaitForChild("GameServer"):WaitForChild("Economy"):WaitForChild("EconomyServer")
                end)
                if okEconomy then
                        local okRequire, result = pcall(require, module)
                        if okRequire then
                                economy = result
                        else
                                warnf("Failed to require EconomyServer: %s", tostring(result))
                        end
                else
                        warnf("EconomyServer module missing: %s", tostring(module))
                end
        end

        local lastHits = setmetatable({}, { __mode = "k" })
        local random = Random.new()

        local function getPrimary(instance: Instance?): BasePart?
                if not instance then
                        return nil
                end

                if instance:IsA("BasePart") then
                        return instance
                end

                if instance:IsA("Model") then
                        local primary = instance.PrimaryPart
                        if primary and primary:IsA("BasePart") then
                                return primary
                        end
                        for _, child in ipairs(instance:GetDescendants()) do
                                if child:IsA("BasePart") then
                                        return child
                                end
                        end
                end

                return nil
        end

        local function destroyFruit(instance: Instance?): boolean
                if not instance then
                        return false
                end

                local target: Instance = instance
                if instance:IsA("BasePart") then
                        local parent = instance.Parent
                        if parent and parent:IsA("Model") then
                                target = parent
                        end
                end

                local okDestroy = pcall(function()
                        target:Destroy()
                end)

                if okDestroy then
                        lastHits[instance] = nil
                        lastHits[target] = nil
                elseif diagnostics.Verbose ~= false then
                        warnf("Failed to destroy fruit instance")
                end

                return okDestroy
        end

        local function safeGetAttribute(instance: Instance, name: string): any
                local okAttr, value = pcall(instance.GetAttribute, instance, name)
                if okAttr then
                        return value
                end
                return nil
        end

        local function pickPlayer(arenaId: any): Player?
                local players = Players:GetPlayers()
                if #players == 0 then
                        return nil
                end

                local candidates: { Player } = {}
                if arenaId ~= nil then
                        for _, player in ipairs(players) do
                                local attr = player:GetAttribute("ArenaId")
                                if attr == arenaId then
                                        table.insert(candidates, player)
                                end
                        end
                end

                if requireActivePlayers and #candidates == 0 then
                        return nil
                end

                local pool = if #candidates > 0 then candidates else players
                local index = random:NextInteger(1, #pool)
                return pool[index]
        end

        log("NPC batters active (max swings %d, interval %.2fs)", maxSwings, searchInterval)

        task.spawn(function()
                while running do
                        local fruits = CollectionService:GetTagged("Fruit")
                        local swings = 0
                        local now = os.clock()

                        for _, instance in ipairs(fruits) do
                                if not running then
                                        break
                                end
                                if swings >= maxSwings then
                                        break
                                end
                                if not instance or instance.Parent == nil then
                                        continue
                                end

                                local lastHit = lastHits[instance]
                                if lastHit and now - lastHit < hitCooldown then
                                        continue
                                end

                                local primary = getPrimary(instance)
                                if not primary then
                                        continue
                                end

                                lastHits[instance] = now

                                if diagnostics.Verbose ~= false then
                                        safeSetAttribute(instance, "StressHitAt", now)
                                end

                                local fruitId = safeGetAttribute(instance, "FruitId")
                                local arenaId = safeGetAttribute(instance, "ArenaId")

                                destroyFruit(instance)
                                swings += 1

                                if awardEnabled and economy and fruitId then
                                        local player = pickPlayer(arenaId)
                                        if player then
                                                local okAward, err = pcall(economy.AwardFruit, player, fruitId)
                                                if not okAward and diagnostics.Verbose ~= false then
                                                        warnf("AwardFruit failed: %s", tostring(err))
                                                end
                                        end
                                end

                                if swingDelay > 0 then
                                        task.wait(swingDelay)
                                end
                        end

                        if not running then
                                break
                        end

                        task.wait(searchInterval)
                end
        end)
end

log("Load/soak harness online. Fruit rate x%.2f, lanes=%s, NPC=%s", fruitMultiplier, tostring(targetLaneCount or "default"), tostring(typeof(npcConfig) == "table" and npcConfig.Enabled == true))

registerCleanup(function()
        log("Load/soak harness shutting down.")
end)

