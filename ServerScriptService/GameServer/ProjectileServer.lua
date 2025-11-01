--!strict
local ProjectileServer = {}

local projectileModule = script.Parent:FindFirstChild("ProjectileMotionServer")
local ProjectileMotionServer

if projectileModule then
    local ok, result = pcall(require, projectileModule)
    if ok then
        ProjectileMotionServer = result
    else
        warn(string.format("[ProjectileServer] Failed to require ProjectileMotionServer: %s", tostring(result)))
    end
else
    warn("[ProjectileServer] ProjectileMotionServer module is missing")
end

local function ensureMotion()
    if ProjectileMotionServer then
        return true
    end

    return false
end

function ProjectileServer.Track(instance, params)
    if not ensureMotion() then
        return nil
    end

    if not instance then
        warn("[ProjectileServer] Track called without an instance")
        return nil
    end

    local ok, result = pcall(ProjectileMotionServer.Bind, instance, params)
    if not ok then
        warn(string.format("[ProjectileServer] Failed to track %s: %s", instance:GetFullName(), tostring(result)))
        return nil
    end

    return result
end

function ProjectileServer.Untrack(instance)
    if not ensureMotion() or not instance then
        return
    end

    local ok, err = pcall(ProjectileMotionServer.Unbind, instance)
    if not ok then
        warn(string.format("[ProjectileServer] Failed to untrack %s: %s", instance:GetFullName(), tostring(err)))
    end
end

return ProjectileServer
