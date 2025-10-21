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
	WaveClearBonus = { Base = 20, PerLevel = 5 },     -- 20 + 5*Level
	LevelClearBonus = { Base = 50, PerLevel = 20 },   -- 50 + 20*Level
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
	UseTeleport = true,                -- if false, arenas spawn locally
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
