local T = {
  PrepTimer = { --[[
    seconds: number
  ]]},
  WaveChanged = { --[[
    wave: number, level: number
  ]]},
  TargetHP = { --[[
    laneId: number, hp: number, max: number
  ]]},
  CoinPointDelta = { --[[
    coins: number, points: number, reason: string
  ]]},
  QuickbarUpdate = { --[[
    slots: table
  ]]},
  Notice = { --[[
    msg: string, kind: "info"|"warn"|"error"
  ]]},
}
return T
