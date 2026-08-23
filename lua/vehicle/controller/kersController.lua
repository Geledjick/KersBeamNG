local M = {}

M.type = "auxiliary"
M.defaultOrder = 1000

local kersMotor = nil
local kersBattery = nil

local mainEngine = nil

local kersPeakTorque = 0
local kersIdleChargeTorque = 0

local max = math.max
local abs = math.abs
local clamp = clamp

local CLUTCH_TORQUE_MARGIN = 1.25         -- clutch safety margin above peak KERS torque
local IDLE_CHARGE_RATIO = 0.1             -- percentage of peak KERS torque for background charging
local REGEN_CUTOFF_RATIO = 0.75           -- below this percentage of idle, regeneration is disabled
local REGEN_SAFE_RATIO = 1.25             -- above this percentage of idle, regeneration is fully enabled
local IDLE_CHARGE_FLOOR_RATIO = 0.85      -- lower boundary of the recharge window (percentage of idle)
local IDLE_CHARGE_RAMP_RATIO = 0.15       -- ramp width at the lower boundary
local STATIONARY_SPEED = 0.5
local BATTERY_FULL = 0.99
local BATTERY_EMPTY = 0.01
local BRAKE_DEADZONE = 0.05
local THROTTLE_DEADZONE = 0.1

-- Peak KERS torque across the entire RPM range 
-- take the maximum from the device torque curve (createCurve).
local function getPeakTorque(device)
  local peak = 0
  for k, v in pairs(device.torqueCurve) do
    if type(k) == "number" and type(v) == "number" then
      peak = max(peak, v)
    end
  end
  return max(peak, 0.0000001) -- protection against division by 0 when the curve is completely empty
end

-- Universal torque capacity boost for a "neighboring" clutchlike device
-- (stock clutch, DCT, or any modded transmission with a lockTorque field).
-- Works without being tied to a part name—it searches based on the presence of the required fields,
-- so it won't break on third-party modded transmissions.
local function boostSiblingClutchCapacity(device)
  if not device or not device.parent or not device.parent.children then
    return
  end

  local kersTorqueAtCrank = getPeakTorque(device) * abs(device.gearRatio)

  for _, sibling in ipairs(device.parent.children) do
    if sibling ~= device and sibling.deviceCategories and sibling.deviceCategories.clutchlike and sibling.lockTorque then
      if not sibling.baseLockTorque then
        sibling.baseLockTorque = sibling.lockTorque
      end

      sibling.lockTorque = sibling.baseLockTorque + kersTorqueAtCrank * CLUTCH_TORQUE_MARGIN

      if sibling.calculateInertia then
        sibling:calculateInertia()
      end
    end
  end
end

-- Permissible recuperation coefficient under braking: 1 = fully permitted,
-- 0 = prohibited (RPM too close to idle/zero). Without this protection
-- recuperation in neutral/close to idle can drag the RPM down.
local function getRegenTaper(engine)
  if engine.isStalled then
    return 0
  end

  local idleAV = engine.idleAV or 0
  if idleAV <= 0 then
    return 1
  end

  local engineAV = engine.outputAV1 or 0
  local regenSafeAV = idleAV * REGEN_SAFE_RATIO
  local regenCutoffAV = idleAV * REGEN_CUTOFF_RATIO

  return clamp((engineAV - regenCutoffAV) / (regenSafeAV - regenCutoffAV), 0, 1)
end

-- Background charging coefficient at idle/neutral/pitstop: operates
-- in a narrow window around idle speed, where the engine is definitely not strained
-- to carry a small additional load or full load in high rpm.
local function getIdleChargeTaper(engine)
  if engine.isStalled then
    return 0
  end

  local idleAV = engine.idleAV or 0
  if idleAV <= 0 then
    return 0
  end

  local engineAV = engine.outputAV1 or 0
  local floorAV = idleAV * IDLE_CHARGE_FLOOR_RATIO
  local rampAV = idleAV * IDLE_CHARGE_RAMP_RATIO

  return clamp((engineAV - floorAV) / rampAV, 0, 1)
end

local function updateFixedStep(dt)
  -- Skip if the necessary parts are not available
  if not kersMotor or not kersBattery or not mainEngine then return end

  local boostInput = electrics.values.kersBoost or 0
  local brakeInput = electrics.values.brake or 0
  local throttleInput = electrics.values.throttle or 0
  local wheelSpeed = obj:getVelocity():length()

  local batteryRatio = kersBattery.remainingRatio or 0

  local targetTorque = 0
  local status = "READY"

  if boostInput > 0 then
    -- Boost is a priority and is always available, regardless of speed.
    if batteryRatio > BATTERY_EMPTY then
      targetTorque = kersPeakTorque * boostInput
      status = "BOOSTING"
    else
      status = "DEPLETED"
    end
  elseif wheelSpeed > STATIONARY_SPEED then
    -- The car is moving: recuperation under the brake, without throttle.
    if brakeInput > BRAKE_DEADZONE and throttleInput < THROTTLE_DEADZONE then
      if batteryRatio < BATTERY_FULL then
        local regenTaper = getRegenTaper(mainEngine)
        targetTorque = -kersPeakTorque * brakeInput * regenTaper
        status = regenTaper > 0.01 and "REGEN" or "REGEN BLOCKED"     
      else
        status = "FULL"
      end
    end
  else
    -- The car is at idle/neutral/pitstop - background charging.
    -- or accelerated recharging if throttle while standing still.
    if batteryRatio < BATTERY_FULL then
      local revTaper = getIdleChargeTaper(mainEngine)
      local chargeRatio = max(IDLE_CHARGE_RATIO, throttleInput)
      targetTorque = -kersPeakTorque * chargeRatio * revTaper

      if revTaper <= 0.01 then
        status = "READY"
      elseif chargeRatio > IDLE_CHARGE_RATIO + 0.01 then
        status = "FAST CHARGE"
      else
        status = "IDLE CHARGE"
      end
    else
      status = "FULL"
    end
  end

  local commandName = kersMotor.commandName or "kersTorqueCommand"
  electrics.values[commandName] = targetTorque

  -- Send datas to the HUD
  electrics.values.kersBatteryPercent = batteryRatio * 100
  electrics.values.kersEnergykWh = kersBattery and (kersBattery.storedEnergy / 3600000) or 0
  electrics.values.kersTorquePercent = (targetTorque / kersPeakTorque) * 100
  electrics.values.kersBoostActive = status == "BOOSTING" and 1 or 0
  electrics.values.kersMotorStatus = status
end

local function updateGFX(dt)
end

local function init(jbeamData)
  electrics.values.kersBoost = electrics.values.kersBoost or 0
end

local function initSecondStage(jbeamData)
  -- Checking for the required parts
  kersMotor = powertrain.getDevice("kers_motor")
  if kersMotor then
    mainEngine = kersMotor.parent
  end
  kersBattery = energyStorage.getStorage("kers_battery")

  electrics.values.kersBoost = electrics.values.kersBoost or 0

  if kersMotor then
    kersPeakTorque = getPeakTorque(kersMotor)
    kersIdleChargeTorque = kersPeakTorque * IDLE_CHARGE_RATIO
    boostSiblingClutchCapacity(kersMotor)
  end
end

local function reset(jbeamData)
  electrics.values.kersBoost = 0
  electrics.values.kersBatteryPercent = 100
  electrics.values.kersEnergykWh = 0
  electrics.values.kersTorquePercent = 0
  electrics.values.kersBoostActive = 0
  electrics.values.kersMotorStatus = "READY"
  electrics.values.kersBoost = electrics.values.kersBoost or 0
end

M.init = init
M.initSecondStage = initSecondStage
M.updateFixedStep = updateFixedStep
M.updateGFX = updateGFX
M.reset = reset

return M