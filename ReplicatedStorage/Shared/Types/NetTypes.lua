--!strict

export type PrepTimer = {
    seconds: number,
}

export type WaveChanged = {
    wave: number,
    level: number,
}

export type TargetHP = {
    laneId: number,
    hp: number,
    max: number,
}

export type CoinPointDelta = {
    coins: number,
    points: number,
    reason: string,
}

export type QuickbarUpdate = {
    slots: { [number]: any },
}

export type Notice = {
    msg: string,
    kind: "info" | "warn" | "error",
}

local NetTypes = {
    PrepTimer = {} :: PrepTimer,
    WaveChanged = {} :: WaveChanged,
    TargetHP = {} :: TargetHP,
    CoinPointDelta = {} :: CoinPointDelta,
    QuickbarUpdate = {} :: QuickbarUpdate,
    Notice = {} :: Notice,
}

return NetTypes
