--!strict
-- StressConfig.lua
-- Toggle-heavy load test harness. Set Enabled = true to activate overrides.

export type NpcConfig = {
        Enabled: boolean?,
        MaxSwingsPerCycle: number?,
        SwingDelaySeconds: number?,
        SearchIntervalSeconds: number?,
        HitCooldownSeconds: number?,
        AwardFruit: boolean?,
        AwardRequiresActivePlayers: boolean?,
}

export type AutoStartConfig = {
        Enabled: boolean?,
        PartyId: string?,
        StartLevel: number?,
        SkipPrep: boolean?,
}

export type DiagnosticsConfig = {
        Verbose: boolean?,
        SetGameAttribute: boolean?,
}

export type StressConfig = {
        Enabled: boolean,
        FruitRateMultiplier: number?,
        TargetLaneCount: number?,
        ForceObstacles: boolean?,
        AutoStartArena: AutoStartConfig?,
        NpcBatters: NpcConfig?,
        Diagnostics: DiagnosticsConfig?,
}

local Config: StressConfig = {
        -- Flip to true when you want the soak harness to take over.
        Enabled = false,

        -- Multiply turret shot rate (fruit spawn driver). Default baseline is ~0.6.
        FruitRateMultiplier = 5,

        -- Force the arena to expose this many lanes immediately.
        TargetLaneCount = 8,

        -- When true, obstacles unlock at level 1.
        ForceObstacles = true,

        -- Automatically spawn a local arena and skip prep when the harness is active.
        AutoStartArena = {
                Enabled = true,
                PartyId = "StressHarness",
                StartLevel = 1,
                SkipPrep = true,
        },

        -- Optional headless NPC style hitters that keep fruit turnover high.
        NpcBatters = {
                Enabled = false,
                MaxSwingsPerCycle = 20,
                SwingDelaySeconds = 0.05,
                SearchIntervalSeconds = 0.25,
                HitCooldownSeconds = 0.15,
                AwardFruit = false,
                AwardRequiresActivePlayers = true,
        },

        Diagnostics = {
                Verbose = true,
                SetGameAttribute = true,
        },
}

return Config

