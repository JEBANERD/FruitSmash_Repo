--!strict
-- GameConfig.lua
-- Central tunables for gameplay, difficulty, economy, power-ups, durability, obstacles, lanes.
-- Everything else should read from this file only.

local C = {}

-- == Turrets / Firing ==
C.Turrets = {
	BaseShotsPerSecond = 0.6,   -- Level 1 baseline
	ShotsPerLevelPct   = 0.06,  -- +6% per level
	TwoAtOnceLevel     = 5,     -- allow up to 2 simultaneous turrets from this level
	ThreeAtOnceLevel   = 15,    -- occasional 3-at-once from this level
}

-- == Lanes & Expansion ==
C.Lanes = {
	StartCount = 4,
	MaxCount   = 8,
	UnlockAt   = {6, 8}, -- when arena expands walls to reveal lanes
	ExpansionSmoothingLevels = 2, -- levels to normalize spawn rate after unlock
	ExpansionTemporaryRatePenalty = 0.10, -- reduce per-lane rate by 10% just after unlock
}

-- == Targets ==
C.Targets = {
	StartHP = 200,
	-- +10% every 10 levels (0-based: at levels 10,20,30..)
	TenLevelBandScalePct = 0.10,
	ShieldFXTag = "TargetShieldFX", -- optional CollectionService tag for visuals
}

-- == Players ==
C.Player = {
	MaxHP = 100,
        Sprint = {
                Enabled = true,
                BaseWalkSpeed   = 16, -- Roblox default
                BaseSprintSpeed = 22, -- sprint speed without buffs
                Stamina = {
                        Enabled = true,
                        DrainPerSecond = 18,
                        RegenPerSecond = 12,
                },
        },
        Settings = {
                Defaults = {
                        SprintToggle = false,
                        AimAssistWindow = 0.75,
                        CameraShakeStrength = 0.7,
                        ColorblindPalette = "Off",
                        TextScale = 1,
                        Locale = "en",
                },
                Limits = {
                        AimAssistWindow = { Min = 0, Max = 1 },
                        CameraShakeStrength = { Min = 0, Max = 1 },
                        TextScale = { Min = 0.8, Max = 1.4 },
                },
                ColorblindPalettes = {
                        {
                                Id = "Off",
                                Name = "Off",
                                TintColor = Color3.fromRGB(255, 255, 255),
                                Saturation = 0,
                                Contrast = 0,
                                Brightness = 0,
                        },
                        {
                                Id = "Deuteranopia",
                                Name = "Deuteranopia",
                                TintColor = Color3.fromRGB(248, 246, 234),
                                Saturation = -0.18,
                                Contrast = 0.08,
                                Brightness = 0.02,
                        },
                        {
                                Id = "Protanopia",
                                Name = "Protanopia",
                                TintColor = Color3.fromRGB(234, 244, 255),
                                Saturation = -0.14,
                                Contrast = 0.07,
                                Brightness = 0.01,
                        },
                        {
                                Id = "Tritanopia",
                                Name = "Tritanopia",
                                TintColor = Color3.fromRGB(240, 255, 246),
                                Saturation = -0.12,
                                Contrast = 0.05,
                                Brightness = 0.03,
                        },
                },
        },
        SawbladeRespawnSeconds = 5,
        MiniTurretHitDamage    = 25,
}

-- == Melee & Durability ==
C.Melee = {
	DefaultWeapon = "WoodenBat",
	BreakDisableSeconds = 8, -- when durability hits 0
	ReturnDurabilityPct = 0.50, -- after disable window, returns with 50% dura
	BaseDamage = 25, -- baseline melee, weapon modifiers may add
	DurabilityRepairPerKit = 100, -- shop repair kit amount
}

-- == Power-Ups ==
C.PowerUps = {
	SpeedBoost = {
		DurationSeconds = 8,
		SpeedMultiplier = 1.35, -- applies to walk & sprint
	},
	DoubleCoins = {
		DurationSeconds = 15,
	},
	BurstClear = {
		GrantCoinsForRecentlyHitWindow = 0.3, -- seconds; anti-farm
	},
	TargetShield = {
		DurationSeconds = 10,
	},
	TargetHealthBoost = {
		MaxHPBonusPct = 0.20,
		HealCurrentPct = 0.20,
	},
	AutoRepairMelee = {
		DurationSeconds = 10,
		RepairPerSecond = 4,
	},
}

-- == Obstacles ==
C.Obstacles = {
	EnableAtLevel = 10, -- level threshold for obstacles presence
	Sawblade = {
		PopUpIntervalMin = 6.0,
		PopUpIntervalMax = 9.0,
		UpTimeSeconds    = 2.2,
	},
	MiniTurret = {
		FireIntervalMin = 2.5,
		FireIntervalMax = 3.5,
		Damage          = 25,
		ProjectileSpeed = 70,
	},
}

-- == Economy ==
C.Economy = {
        CoinsPerFruitOverride = nil, -- use FruitConfig values when nil
        WaveClearBonus = {
                -- Each band starts counting PerLevel from its MinLevel to ease tuning
                Bands = {
                        { MinLevel = 1,  Base = 14, PointsBase = 6,  PerLevel = 1, PointsPerLevel = 1 },
                        { MinLevel = 10, Base = 22, PointsBase = 8,  PerLevel = 1, PointsPerLevel = 1 },
                        { MinLevel = 20, Base = 28, PointsBase = 10, PerLevel = 1, PointsPerLevel = 1 },
                        { MinLevel = 30, Base = 34, PointsBase = 12, PerLevel = 1, PointsPerLevel = 1 },
                },
        },
        LevelClearBonus = {
                Bands = {
                        { MinLevel = 1,  Base = 35, PointsBase = 18, PerLevel = 2, PointsPerLevel = 1 },
                        { MinLevel = 10, Base = 60, PointsBase = 22, PerLevel = 3, PointsPerLevel = 1 },
                        { MinLevel = 20, Base = 80, PointsBase = 26, PerLevel = 3, PointsPerLevel = 2 },
                        { MinLevel = 30, Base = 95, PointsBase = 30, PerLevel = 3, PointsPerLevel = 2 },
                },
        },
        PointsPerFruitOverride = nil, -- use FruitConfig values when nil
}

-- == Rerolls & Continues ==
C.Monetization = {
	Reroll = {
		FlatFeeCoins = 25,
		TokenPriceCoins = 100,
		CapPerTenLevels = 3, -- combined cap (direct fee + tokens) per 10 rounds
	},
	Continue = {
		CapPerSession = 3,
		RobuxPrice    = 29,
		AllowAd       = true,
	},
}

-- == UI/UX flags ==

C.UI = {
	UseQuickbar = true,
	Quickbar = {
		MeleeSlots = 2,
		TokenSlots = 3,
	},
	HUD = {
		ShowCoins = true,
		ShowPoints = true,
	},
	WorldScreens = {
		WaveTimerEnabled = true,
		RoundTimerEnabled = true,
	},
}


-- == Match / Teleport Settings ==
C.Match = {
	UseTeleport = false,                -- if false, arenas spawn locally
	MatchPlaceId = 88313846397368,     -- your Match place id
	LobbyPlaceId = game.PlaceId,       -- auto-filled by each place at runtime
	StartGraceSeconds = 5,             -- delay before starting arena after last teleport
	DebugPrint = true,                 -- toggle verbose logs
}

-- == Helper ==
function C.Get()
	return C
end

return C
