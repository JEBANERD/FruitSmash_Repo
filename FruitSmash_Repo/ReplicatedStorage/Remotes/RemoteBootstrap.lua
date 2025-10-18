local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[=[
RemoteBootstrap.lua
This module ensures that all globally shared RemoteEvents and BindableEvents
used by both the server and clients exist before gameplay systems run. The
script can be required from ServerScriptService during server start up.
]=]

-- Definitions describing each remote endpoint. New remotes shared by the
-- server systems can be added to this table to register them automatically.
local REMOTE_DEFINITIONS = {
    -- Signals clients that the round has concluded and they should display the
    -- game over UI.
    {
        name = "GameOverEvent",
        className = "RemoteEvent",
    },

    -- Broadcasts the countdown timer to clients before a round begins.
    {
        name = "StartCountdown",
        className = "RemoteEvent",
    },

    -- Sent from clients requesting that the current round is restarted.
    {
        name = "RestartRequested",
        className = "RemoteEvent",
    },

    -- Notifies participants that a power-up has been activated and should be processed.
    {
        name = "PowerupTriggered",
        className = "RemoteEvent",
    },

    -- Internal signal used to coordinate automatic turret fire across systems without networking.
    {
        name = "FireTrigger",
        className = "BindableEvent",
    },
}

-- Ensures the Remotes folder exists under ReplicatedStorage so both the server
-- and clients share the same location for cross-context communication.
local function ensureRemotesFolder()
    local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")

    if not remotesFolder then
        remotesFolder = Instance.new("Folder")
        remotesFolder.Name = "Remotes"
        remotesFolder.Parent = ReplicatedStorage
    end

    return remotesFolder
end

-- Creates or retrieves each remote declared in REMOTE_DEFINITIONS and returns
-- a lookup table keyed by remote name for convenience when requiring this
-- module.
local function initializeRemotes(remotesFolder)
    local references = {}
    local initializedNames = {}

    for _, definition in ipairs(REMOTE_DEFINITIONS) do
        local existing = remotesFolder:FindFirstChild(definition.name)

        if not existing then
            existing = Instance.new(definition.className)
            existing.Name = definition.name
            existing.Parent = remotesFolder
        end

        references[definition.name] = existing
        table.insert(initializedNames, string.format("%s (%s)", definition.name, definition.className))
    end

    print(string.format(
        "[RemoteBootstrap] Initialized remotes: %s",
        table.concat(initializedNames, ", ")
    ))

    return references
end

-- Entry point for the module. Requiring this script will ensure the remotes are
-- ready for use before other systems run.
local remotesFolder = ensureRemotesFolder()
local remotes = initializeRemotes(remotesFolder)

-- Small safety yield to ensure remote creation propagates before dependent
-- scripts continue execution. This keeps initialization order deterministic.
task.wait()

return remotes
