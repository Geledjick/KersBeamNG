local M = {}

M.outputPorts = {}
M.deviceCategories = {clutchlike = true, torqueConsumer = true}

local max = math.max
local min = math.min
local abs = math.abs
local floor = math.floor
local clamp = clamp

local avToRPM = 9.549296596425384

local function updateEnergyStorageRatios(device)
  device.energyStorageRatios = {}
  device.energyStorageRegenRatios = {}
  for _, s in pairs(device.registeredEnergyStorages) do
    local storage = energyStorage.getStorage(s)
    if storage then
      device.energyStorageRatios[storage.name] = 1 / device.storageWithEnergyCounter
      device.energyStorageRegenRatios[storage.name] = 1 / device.storageCounter
    end
  end
end

local function updateEnergyUsage(device)
  if #device.registeredEnergyStorages == 0 then
    device.spentEnergy = 0
    return
  end

  local hasEnergy = false
  local previousStorageCount = device.storageWithEnergyCounter
  for _, s in pairs(device.registeredEnergyStorages) do
    local storage = energyStorage.getStorage(s)
    if storage then
      local previous = device.previousEnergyLevels[storage.name] or storage.storedEnergy
      local storageRatio = device.spentEnergy > 0 and device.energyStorageRatios[storage.name] or device.energyStorageRegenRatios[storage.name]
      
      storage.storedEnergy = clamp(storage.storedEnergy - (device.spentEnergy * storageRatio), 0, storage.energyCapacity)
      
      if previous > 0 and storage.storedEnergy <= 0 then
        device.storageWithEnergyCounter = device.storageWithEnergyCounter - 1
      elseif previous <= 0 and storage.storedEnergy > 0 then
        device.storageWithEnergyCounter = device.storageWithEnergyCounter + 1
      end
      device.previousEnergyLevels[storage.name] = storage.storedEnergy
      hasEnergy = hasEnergy or storage.storedEnergy > 0
    end
  end

  if previousStorageCount ~= device.storageWithEnergyCounter then
    device:updateEnergyStorageRatios()
  end

  device.spentEnergy = 0
  device.hasEnergy = hasEnergy
end

local function registerStorage(device, storageName)
  for _, s in ipairs(device.registeredEnergyStorages) do
    if s == storageName then return end
  end
  local storage = energyStorage.getStorage(storageName)
  if storage and storage.type == "electricBattery" and storage.energyCapacity > 0 then
    device.storageWithEnergyCounter = device.storageWithEnergyCounter + 1
    device.storageCounter = device.storageCounter + 1
    table.insert(device.registeredEnergyStorages, storageName)
    device:updateEnergyStorageRatios()
    device.hasEnergy = true
    device.previousEnergyLevels[storageName] = storage.storedEnergy
  end
end

local function updateVelocity(device, dt)
  if device.parent then
    device.inputAV = device.parent.outputAV1 * device.gearRatio
  end
end

local function updateTorque(device, dt)
  local inputAV = device.inputAV

  if device.isBroken or not device.parent then
    device.torqueDiff = 0
    device.currentTorque = 0
    return
  end

  local rpmIdx = floor(abs(inputAV) * avToRPM)
  local maxAssist = device.hasEnergy and (device.torqueCurve[rpmIdx] or 0) or 0
  local maxRegen = min(device.maxWantedRegenTorque, device.regenCurve[rpmIdx] or 0)

  local rawCmd = electrics.values[device.commandName] or 0
  local cmd = clamp(rawCmd * device.outputTorqueState, -maxRegen, maxAssist)
  cmd = device.torqueSmoother:get(cmd)
  device.currentTorque = cmd

  device.torqueDiff = -cmd * device.gearRatio

  local grossWork = cmd * inputAV * dt
  local loadForEff = clamp(abs(cmd) / (maxAssist + 1e-30), 0, 1)
  local eff = device.electricalEfficiencyTable[floor(loadForEff * 100) * 0.01] or device.electricalEfficiency
  
  device.spentEnergy = device.spentEnergy + (grossWork >= 0 and grossWork / eff or grossWork * eff)
end

local function updateGFX(device, dt)
  if not device.energyStorageChecked then
    device.energyStorageChecked = true
    if #device.registeredEnergyStorages == 0 and device.energyStorage then
      if type(device.energyStorage) == "string" then
        device:registerStorage(device.energyStorage)
      elseif type(device.energyStorage) == "table" then
        for _, s in pairs(device.energyStorage) do device:registerStorage(s) end
      end
    end
  end

  device:updateEnergyUsage()
  device.outputRPM = abs(device.inputAV) * avToRPM
end

local function selectUpdates(device)
  device.velocityUpdate = updateVelocity
  device.torqueUpdate = updateTorque
end

local function validate(device)
  if #device.registeredEnergyStorages == 0 and device.energyStorage then
    if type(device.energyStorage) == "string" then
      device:registerStorage(device.energyStorage)
    elseif type(device.energyStorage) == "table" then
      for _, s in pairs(device.energyStorage) do device:registerStorage(s) end
    end
  end
  return true
end

local function calculateInertia(device)
  device.cumulativeInertia = (device.virtualInertia or 0.05) / (device.gearRatio * device.gearRatio)
  device.invCumulativeInertia = device.cumulativeInertia > 0 and 1 / device.cumulativeInertia or 0
  device.cumulativeGearRatio = device.gearRatio
  device.maxCumulativeGearRatio = device.gearRatio
end

local function reset(device, jbeamData)
  device.inputAV = 0
  device.outputRPM = 0
  device.torqueDiff = 0
  device.currentTorque = 0
  device.spentEnergy = 0
  device.hasEnergy = true
  device.torqueSmoother:reset()
  selectUpdates(device)
end

local function new(jbeamData)
  local device = {
    deviceCategories = shallowcopy(M.deviceCategories),
    outputPorts = shallowcopy(M.outputPorts),
    name = jbeamData.name,
    type = jbeamData.type,
    inputName = jbeamData.inputName,
    inputIndex = jbeamData.inputIndex or 2,
    gearRatio = jbeamData.gearRatio or 1,
    virtualInertia = jbeamData.inertia or 0.05,
    cumulativeInertia = 1,
    invCumulativeInertia = 1,
    cumulativeGearRatio = 1,
    maxCumulativeGearRatio = 1,
    isPhysicallyDisconnected = true,

    inputAV = 0,
    outputRPM = 0,
    torqueDiff = 0,
    currentTorque = 0,
    outputTorqueState = 1,
    isDisabled = false,
    isBroken = false,

    storageWithEnergyCounter = 0,
    storageCounter = 0,
    registeredEnergyStorages = {},
    previousEnergyLevels = {},
    hasEnergy = true,
    spentEnergy = 0,

    commandName = jbeamData.commandName or "kersTorqueCommand",
    torqueSmoother = newExponentialSmoothing(jbeamData.smoothing or 15),

    reset = reset,
    validate = validate,
    calculateInertia = calculateInertia,
    updateGFX = updateGFX,
    updateEnergyUsage = updateEnergyUsage,
    updateEnergyStorageRatios = updateEnergyStorageRatios,
    registerStorage = registerStorage,
  }

  local torqueTable = jbeamData.torque and tableFromHeaderTable(jbeamData.torque) or {}
  local points = {}
  device.maxRPM = 0
  for _, v in pairs(torqueTable) do
    table.insert(points, {v.rpm, v.torque})
    device.maxRPM = max(device.maxRPM, v.rpm)
  end

  if #points == 0 then
    local rating = jbeamData.torqueRating or 300
    local maxRPM = jbeamData.maxRPM or 10000
    device.maxRPM = maxRPM
    points = {{0, rating}, {maxRPM, rating}}
  end
  device.torqueCurve = createCurve(points)

  if jbeamData.regenTorqueCurve then
    local rt = tableFromHeaderTable(jbeamData.regenTorqueCurve)
    points = {}
    for _, v in pairs(rt) do table.insert(points, {v.rpm, v.torque}) end
    device.regenCurve = createCurve(points)
  else
    local maxRegenTorque = jbeamData.maxRegenTorque or jbeamData.torqueRating or 300
    device.regenCurve = {[0] = 0}
    for i = 1, device.maxRPM do
      local fade = min(1, i / 500)
      device.regenCurve[i] = fade * maxRegenTorque
    end
  end

  local maxRegen = 0
  for i = 0, device.maxRPM do maxRegen = max(maxRegen, device.regenCurve[i] or 0) end
  device.maxWantedRegenTorque = jbeamData.maxRegenTorque or maxRegen

  local eff = jbeamData.electricalEfficiency or 0.95
  device.electricalEfficiency = eff
  device.electricalEfficiencyTable = {}
  for k = 0, 100 do device.electricalEfficiencyTable[k * 0.01] = eff end

  device.energyStorage = jbeamData.energyStorage
  device.jbeamData = jbeamData

  selectUpdates(device)
  return device
end

M.new = new
return M