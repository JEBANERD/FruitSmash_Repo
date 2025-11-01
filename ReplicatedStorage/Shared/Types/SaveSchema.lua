--!strict

export type PlayerStats = {
    TotalPoints: number,
    HighestLevel: number,
    TotalWavesCleared: number,
    TotalFruitSmashed: number,
    TutorialCompleted: boolean,
}

export type PlayerSettings = {
    SprintToggle: boolean,
    AimAssistWindow: number,
    CameraShakeStrength: number,
    ColorblindPalette: string,
    TextScale: number,
}

export type CosmeticsData = {
    Trails: { [number]: string } | {},
    Emotes: { [number]: string } | {},
}

export type SaveData = {
    Coins: number,
    Upgrades: { [string]: number } | {},
    Stats: PlayerStats,
    Settings: PlayerSettings,
    Cosmetics: CosmeticsData,
    RerollTokens: number,
}

export type SaveSchema = {
    Defaults: SaveData,
}

local Schema: SaveSchema = {
    Defaults = {
        Coins = 0,
        Upgrades = {},
        Stats = {
            TotalPoints = 0,
            HighestLevel = 0,
            TotalWavesCleared = 0,
            TotalFruitSmashed = 0,
            TutorialCompleted = false,
        },
        Settings = {
            SprintToggle = false,
            AimAssistWindow = 0.75,
            CameraShakeStrength = 0.7,
            ColorblindPalette = "Off",
            TextScale = 1,
        },
        Cosmetics = {
            Trails = {},
            Emotes = {},
        },
        RerollTokens = 0,
    },
}

return Schema
