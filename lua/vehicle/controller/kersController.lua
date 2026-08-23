local M = {}

M.type = "auxiliary"
M.defaultOrder = 1000

local kersMotor = nil
local kersBattery = nil

local mainEngine = nil

local kersPeakTorque = 0
local kersIdleChargeTorque = 20

local max = math.max
local abs = math.abs
local clamp = clamp

local function getPeakTorque(device)
  local peak = 0
  for k, v in pairs(device.torqueCurve) do
    if type(k) == "number" and type(v) == "number" then
      peak = max(peak, v)
    end
  end
  return peak
end

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

      sibling.lockTorque = sibling.baseLockTorque + kersTorqueAtCrank * 1.25

      if sibling.calculateInertia then
        sibling:calculateInertia()
      end
    end
  end
end

local function getRegenTaper(engine)
  if engine.isStalled then
    return 0
  end

  local idleAV = engine.idleAV or 0
  if idleAV <= 0 then
    return 1
  end

  local engineAV = engine.outputAV1 or 0
  local regenSafeAV = idleAV * 1.25
  local regenCutoffAV = idleAV * 0.75

  return clamp((engineAV - regenCutoffAV) / (regenSafeAV - regenCutoffAV), 0, 1)
end

local function getIdleChargeTaper(engine)
  if engine.isStalled then
    return 0
  end

  local idleAV = engine.idleAV or 0
  if idleAV <= 0 then
    return 0
  end

  local engineAV = engine.outputAV1 or 0
  local floorAV = idleAV * 0.85
  local ceilAV = idleAV * 1.6
  local rampAV = idleAV * 0.15

  if engineAV < floorAV or engineAV > ceilAV then
    return 0
  end

  return clamp((engineAV - floorAV) / rampAV, 0, 1)
end

local function updateFixedStep(dt)
  if not kersMotor then
    kersMotor = powertrain.getDevice("kers_motor")
  end
  if not kersBattery then
    kersBattery = energyStorage.getStorage("kers_battery")
  end
  if not mainEngine then
    mainEngine = kersMotor.parent
  end

  if not kersMotor or not kersBattery or not mainEngine then return end

  local boostInput = electrics.values.kersBoost or 0
  local brakeInput = electrics.values.brake or 0
  local throttleInput = electrics.values.throttle or 0
  local wheelSpeed = obj:getVelocity():length()

  local batteryRatio = kersBattery and kersBattery.remainingRatio or 0

  local targetTorque = 0
  local status = "READY"

  if boostInput > 0 then
    if batteryRatio > 0.01 then
      targetTorque = kersPeakTorque * boostInput
      status = "BOOSTING"
    else
      status = "DEPLETED"
    end
  elseif wheelSpeed > 0.5 then
    if brakeInput > 0.05 and throttleInput < 0.1 then
      if batteryRatio < 0.99 then
        local regenTaper = getRegenTaper(mainEngine)
        targetTorque = -kersPeakTorque * brakeInput * regenTaper
        status = regenTaper > 0.01 and "REGEN" or "REGEN BLOCKED"     
      else
        status = "FULL"
      end
    end
  else
    if batteryRatio < 0.99 then
      local idleTaper = getIdleChargeTaper(mainEngine)
      targetTorque = -kersIdleChargeTorque * idleTaper
      status = idleTaper > 0.01 and "IDLE CHARGE" or "READY"
    else
      status = "FULL"
    end
  end

  local commandName = kersMotor.commandName or "kersTorqueCommand"
  electrics.values[commandName] = targetTorque

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
  kersMotor = powertrain.getDevice("kers_motor")
  kersBattery = energyStorage.getStorage("kers_battery")
  electrics.values.kersBoost = electrics.values.kersBoost or 0

  if kersMotor then
    kersPeakTorque = getPeakTorque(kersMotor)
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