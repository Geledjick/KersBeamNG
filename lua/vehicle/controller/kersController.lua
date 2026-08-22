local M = {}

M.type = "auxiliary"
M.defaultOrder = 1000

local kersMotor = nil
local kersBattery = nil

local clamp = clamp

local function updateFixedStep(dt)
  if not kersMotor then
    kersMotor = powertrain.getDevice("kers_motor")
  end
  if not kersBattery then
    kersBattery = energyStorage.getStorage("kers_battery")
  end

  if not kersMotor then return end

  local boostInput = electrics.values.kersBoost or 0
  local brakeInput = electrics.values.brake or 0
  local throttleInput = electrics.values.throttle or 0

  local batteryRatio = kersBattery and kersBattery.remainingRatio or 0
  local maxTorque = kersMotor.jbeamData.torqueRating or 300

  local targetTorque = 0
  local status = "READY"

  if boostInput > 0 then
    if batteryRatio > 0.01 then
      targetTorque = maxTorque * boostInput
      status = "BOOSTING"
    else
      status = "DEPLETED"
    end
  elseif brakeInput > 0.05 and throttleInput < 0.1 then
    if batteryRatio < 0.99 then
      targetTorque = -maxTorque * clamp(2 * brakeInput, 0, 1)
      status = "REGEN"
    else
      status = "FULL"
    end
  end

  local commandName = kersMotor.commandName or "kersTorqueCommand"
  electrics.values[commandName] = targetTorque

  electrics.values.kersBatteryPercent = batteryRatio * 100
  electrics.values.kersEnergykWh = kersBattery and (kersBattery.storedEnergy / 3600000) or 0
  electrics.values.kersTorquePercent = (targetTorque / maxTorque) * 100
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