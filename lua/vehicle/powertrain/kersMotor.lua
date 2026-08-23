local M = {}

M.outputPorts = {}
M.deviceCategories = {clutchlike = true, torqueConsumer = true}

local max = math.max
local min = math.min
local abs = math.abs
local floor = math.floor
local clamp = clamp

-- Converting rad/s to rpm: 60 / (2*pi)
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

-- Distributes the accumulated energy consumption/income per tick (device.spentEnergy)
-- across all registered batteries proportionally to their number.
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
      
      -- Tracking zero-crossings to correctly calculate storageWithEnergyCounter
      -- (how much energy the batteries can actually supply right now).
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

-- Kinematics: The KERS shaft rotates faster/slower than the crankshaft.
-- in gearRatio times. device.parent.outputAV1 may be missing in the first few ticks.
-- Until the powertrain tree is fully assembled, hence the double check.
local function updateVelocity(device, dt)
  if device.parent and device.parent.outputAV1 then
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

  -- Torque moves "up the tree" to the engine, also scaling with gearRatio
  -- down speed x gearRatio, up torque x gearRatio,
  -- otherwise power wouldn't be conserved through the gearing).
  device.torqueDiff = -cmd * device.gearRatio

  local grossWork = cmd * inputAV * dt

  -- Take the efficiency from the load curve (0-100%), from electricalEfficiencyCurve
  local loadPercent = clamp(abs(cmd) / (maxAssist + 1e-30), 0, 1) * 100
  local eff = (device.electricalEfficiencyCurve and device.electricalEfficiencyCurve[floor(loadPercent)]) or 0
  
  -- Efficiency asymmetry: during acceleration (grossWork >= 0), we expend more energy than
  -- useful mechanical work (division); during recuperation (grossWork < 0),
  -- less energy enters the battery than is removed from the shaft (multiplication). This simulates
  -- real losses in the electronics/windings in both directions of the energy flow.
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

-- Rotor inertia reflected on the crankshaft: I_equiv = I_rotor * gearRatio * gearRatio
-- (rotational energy is conserved when transitioning through a rigid gear
-- see the discussion history for a detailed analysis of the formula direction).
local function calculateInertia(device)
  device.cumulativeInertia = (device.virtualInertia or 0.05) * (device.gearRatio * device.gearRatio)
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
    
    -- Inform the engine about the mass of the rotor, which is rigidly bolted to its shaft,
    -- so that the engine correctly calculates the total inertia during acceleration/braking by torque
    -- (without this field, the engine "doesn't see" the mass of the KERS at all).
    virtualInertia = jbeamData.inertia or 0.05,
    additionalEngineInertia = (jbeamData.inertia or 0.05) * ((jbeamData.gearRatio or 1) * (jbeamData.gearRatio or 1)),
    cumulativeInertia = 1,
    invCumulativeInertia = 1,
    
    cumulativeGearRatio = 1,
    maxCumulativeGearRatio = 1,

    -- The rigid link is always "connected" the device doesn't have a slip model,
    -- so this flag should always be false.
    isPhysicallyDisconnected = false,

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
    torqueSmoother = newExponentialSmoothing(jbeamData.smoothing or 100),

    reset = reset,
    validate = validate,
    calculateInertia = calculateInertia,
    updateGFX = updateGFX,
    updateEnergyUsage = updateEnergyUsage,
    updateEnergyStorageRatios = updateEnergyStorageRatios,
    registerStorage = registerStorage,
  }

  -- Torque is set by the rpm/torque map from jbeam.
  local points = {}
  device.maxRPM = 0
  if jbeamData.torque then
    local torqueTable = tableFromHeaderTable(jbeamData.torque)
    for _, v in pairs(torqueTable) do
      table.insert(points, {v.rpm, v.torque})
      device.maxRPM = max(device.maxRPM, v.rpm)
    end    
  end

  if #points == 0 then
    log("E", "kersMotor.new", "Device hasn't torque table in jbeamData!")
    device.maxRPM = 1
    points = {{0, 0}, {1, 0}}
  end
  device.torqueCurve = createCurve(points)

  -- Without a separate recovery curve, use the same form as acceleration.
  if jbeamData.regenTorque then
    local rt = tableFromHeaderTable(jbeamData.regenTorque)
    local regenPoints = {}
    for _, v in pairs(rt) do table.insert(regenPoints, {v.rpm, v.torque}) end
    device.regenCurve = createCurve(regenPoints)
  else
    device.regenCurve = device.torqueCurve
  end

  local maxRegen = 0
  for i = 0, device.maxRPM do maxRegen = max(maxRegen, device.regenCurve[i] or 0) end
  device.maxWantedRegenTorque = jbeamData.maxRegenTorque or maxRegen

  -- Electrical efficiency is set by the load/efficiency map from jbeam.
  if jbeamData.electricalEfficiencyCurve then
    local effTable = tableFromHeaderTable(jbeamData.electricalEfficiencyCurve)
    local effPoints = {}
    for _, v in pairs(effTable) do table.insert(effPoints, {v.load, v.efficiency}) end
    device.electricalEfficiencyCurve = createCurve(effPoints)
  else
    log("E", "kersMotor.new", "Device hasn't electricalEfficiencyCurve table in jbeamData!")
  end

  device.energyStorage = jbeamData.energyStorage
  device.jbeamData = jbeamData

  selectUpdates(device)
  return device
end

M.new = new
return M