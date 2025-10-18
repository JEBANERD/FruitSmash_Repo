local NetTypes = {
  PrepTimer = { --[[
    seconds: number -- remaining seconds in the current preparation timer
  ]]},
  WaveChanged = { --[[
    wave: number, -- new wave index that players are on
    level: number -- difficulty level associated with the wave
  ]]},
  TargetHP = { --[[
    laneId: number, -- identifier for the lane that the target belongs to
    hp: number, -- current hit points of the target
    max: number -- maximum hit points of the target
  ]]},
  CoinPointDelta = { --[[
    coins: number, -- amount of coins gained (positive) or spent (negative)
    points: number, -- amount of score points added (positive) or removed (negative)
    reason: string -- description or enum tag indicating why the change happened
  ]]},
  QuickbarUpdate = { --[[
    slots: table -- ordered array of quickbar slot entries (slotIndex => { id: string, count: number })
  ]]},
  Notice = { --[[
    msg: string, -- localized or direct message text to display to the player
    kind: "info"|"warn"|"error" -- severity classification for presentation
  ]]},
}

return NetTypes
