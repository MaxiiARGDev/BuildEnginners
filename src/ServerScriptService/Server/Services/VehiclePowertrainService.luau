--!strict
--[=[
	VehiclePowertrainService
	Orquestador central en servidor de motores modulares, transmisión automática, curvas de torque,
	combinación multimotor, controles de conducción y consumo de combustible (Fase 3.3).

	Reglas SDD y AGENTS.md:
	- Un único bucle Heartbeat centralizado para todos los vehículos activos (cero scripts Heartbeat por pieza).
	- Estadísticas efectivas de motores resueltas una sola vez al registrar el VehicleRuntime (sin recalcular desde cero cada frame).
	- Toda la tracción física pasa por VehicleWheelControllerService hacia los AxleHinge de las ruedas motrices.
	- Nunca persiste desgaste, daño ni combustible consumido de vuelta en el VehicleBlueprint.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BuildPayloadValidator = require(ServerScriptService.Server.Security.BuildPayloadValidator)
local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local VehicleBoosterService = require(ServerScriptService.Server.Services.VehicleBoosterService)
local VehicleWheelControllerService = require(ServerScriptService.Server.Services.VehicleWheelControllerService)

export type PlayerLike = Player | {
	UserId: number,
	Name: string,
}

type InternalEngineSlot = {
	PieceInstanceId: string,
	ItemId: string,
	InventoryInstanceId: string?,
	PartState: VehicleTypes.RuntimePartState,
	EffectiveStats: ItemTypes.EffectiveEngineStats,
	PowerLimitRatio: number,
	ThrottleResponseMode: "Smooth" | "Balanced" | "Sport",
	Enabled: boolean,
	CurrentRPM: number,
	TargetRPM: number,
	LimiterActive: boolean,
	CurrentTorque: number,
	AvailableWheelTorque: number,
	CurrentPower: number,
	LoadFactor: number,
	DurabilityEfficiencyFactor: number,
	FuelConsumptionRate: number,
}

type InternalFuelTankSlot = {
	PieceInstanceId: string,
	ItemId: string,
	PartState: VehicleTypes.RuntimePartState,
	Capacity: number,
	SelectedFuelType: "Regular" | "Diesel" | "Competicion",
}

type VehiclePowertrainContext = {
	Runtime: VehicleTypes.VehicleRuntime,
	OwnerUserId: number,
	EngineSlots: { InternalEngineSlot },
	EngineSlotsByPieceId: { [string]: InternalEngineSlot },
	FuelTankSlots: { InternalFuelTankSlot },
	SelectedFuelType: "Regular" | "Diesel" | "Competicion",
	GearState: VehicleTypes.PowertrainGearState,
	ActiveGearIndex: number,
	ActiveGearRatio: number,
	SimulatedTime: number,
	LastGearShiftClock: number,
	SmoothedTargetLinearSpeed: number,
	TotalVehicleMass: number,
	LastMassRecalcClock: number,
	ConsumeFuelEnabled: boolean,
	ConsumedFuel: number,
	LastFuelWarningFlag: boolean,
	LastOutOfFuelFlag: boolean,
	ClientDrivingInput: VehicleTypes.DrivingControlIntent?,
	TestControlOverride: VehicleTypes.DrivingControlIntent?,
	LastTelemetryWriteClock: number,
	LastSnapshot: VehicleTypes.PowertrainTelemetrySnapshot,
}

local VehiclePowertrainService = {
	Name = "VehiclePowertrainService",
}

local _initialized = false
local _started = false
local _heartbeatConn: RBXScriptConnection? = nil
local _drivingInputRemote: RemoteEvent? = nil
local _contextsByUserId: { [number]: VehiclePowertrainContext } = {}

local function extractUserId(playerOrUserId: PlayerLike | number): number
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return playerOrUserId.UserId
	elseif type(playerOrUserId) == "table" and type((playerOrUserId :: any).UserId) == "number" then
		return (playerOrUserId :: any).UserId
	end
	error("[VehiclePowertrainService] Invalid player or userId", 3)
end

local function computeTotalVehicleMass(rootModel: Model?): number
	if not rootModel or not rootModel.Parent then
		return GameConfig.Powertrain.ReferenceLightVehicleMass
	end
	local seenParts: { [BasePart]: boolean } = {}
	local totalMass = 0
	for _, desc in ipairs(rootModel:GetDescendants()) do
		if desc:IsA("BasePart") and not desc.Massless and not seenParts[desc] then
			seenParts[desc] = true
			totalMass += desc:GetMass()
		end
	end
	return math.max(10.0, totalMass)
end

local function resolveResponseMultiplier(mode: string): number
	if mode == "Smooth" then
		return 0.72
	elseif mode == "Sport" then
		return 1.35
	end
	return 1.00
end

local function computeDurabilityEfficiency(partState: VehicleTypes.RuntimePartState): number
	if not partState.IsFunctional or partState.IsDetached then
		return 0
	end
	local maxDur = math.max(1, partState.MaxDurability)
	local curDur = math.clamp(partState.CurrentDurability, 0, maxDur)
	if curDur <= 0 then
		return 0
	end
	local ratio = curDur / maxDur
	-- Entre 100% y 50% de durabilidad conserva casi todo su rendimiento; debajo de 50% degrada hasta 35%
	if ratio >= 0.5 then
		return 0.85 + (ratio - 0.5) * 0.30
	end
	return 0.35 + (ratio / 0.5) * 0.50
end

local function computeFuelPools(ctx: VehiclePowertrainContext): (number, number)
	local totalCap = 0
	local avail = 0

	for _, slot in ipairs(ctx.EngineSlots) do
		if slot.PartState.IsFunctional and not slot.PartState.IsDetached then
			totalCap += slot.EffectiveStats.IntegratedFuel
			avail += math.max(0, slot.PartState.CurrentFuel or 0)
		end
	end

	for _, tank in ipairs(ctx.FuelTankSlots) do
		if tank.PartState.IsFunctional and not tank.PartState.IsDetached then
			totalCap += tank.Capacity
			avail += math.max(0, tank.PartState.CurrentFuel or 0)
		end
	end

	return totalCap, avail
end

local function drainFuelFromContext(ctx: VehiclePowertrainContext, amountToDrain: number): number
	if amountToDrain <= 0 then
		return 0
	end
	local remaining = amountToDrain

	-- Drenar primero de tanques dedicados y luego del combustible integrado de los motores
	for _, tank in ipairs(ctx.FuelTankSlots) do
		if remaining <= 0 then
			break
		end
		if tank.PartState.IsFunctional and not tank.PartState.IsDetached then
			local cur = math.max(0, tank.PartState.CurrentFuel or 0)
			if cur > 0 then
				local take = math.min(cur, remaining)
				tank.PartState.CurrentFuel = math.max(0, cur - take)
				remaining -= take
			end
		end
	end

	for _, slot in ipairs(ctx.EngineSlots) do
		if remaining <= 0 then
			break
		end
		if slot.PartState.IsFunctional and not slot.PartState.IsDetached then
			local cur = math.max(0, slot.PartState.CurrentFuel or 0)
			if cur > 0 then
				local take = math.min(cur, remaining)
				slot.PartState.CurrentFuel = math.max(0, cur - take)
				remaining -= take
			end
		end
	end

	return math.max(0, amountToDrain - remaining)
end

local function resolveActiveDriverControls(ctx: VehiclePowertrainContext): VehicleTypes.DrivingControlIntent
 if ctx.Runtime.DriverSeatDestroyed then
  return { Throttle = 0, Brake = 0, RawLongitudinal = 0, Steer = 0, Boost = false, Timestamp = os.clock() }
 end
	if ctx.TestControlOverride then
		return ctx.TestControlOverride
	end

	local runtime = ctx.Runtime
	local seat = runtime.DriverSeatPart
	local isSeatedDriver = seat ~= nil and seat.Parent ~= nil and seat.Occupant ~= nil

	if ctx.ClientDrivingInput and isSeatedDriver then
		-- Combinar con ThrottleFloat/SteerFloat del asiento si el cliente no está presionando botones explícitos
		local cInput = ctx.ClientDrivingInput
		local seatThrottle = if seat then math.clamp(seat.ThrottleFloat, -1, 1) else 0
		local seatSteer = if seat then math.clamp(seat.SteerFloat, -1, 1) else 0

		local rawLong = cInput.RawLongitudinal
		local throttle = cInput.Throttle
		local brake = cInput.Brake
		if math.abs(rawLong) < 1e-3 and throttle < 1e-3 and brake < 1e-3 and math.abs(seatThrottle) > 1e-3 then
			rawLong = seatThrottle
			if seatThrottle > 0 then
				throttle = seatThrottle
				brake = 0
			else
				throttle = 0
				brake = -seatThrottle
			end
		end
		local steer = if math.abs(cInput.Steer) > 1e-3 then cInput.Steer else seatSteer

		return {
			Throttle = throttle,
			Brake = brake,
			RawLongitudinal = rawLong,
			Steer = steer,
			Boost = cInput.Boost == true,
		}
	end

	if isSeatedDriver and seat then
		local tf = math.clamp(seat.ThrottleFloat, -1, 1)
		local sf = math.clamp(seat.SteerFloat, -1, 1)
		return {
			Throttle = if tf > 0 then tf else 0,
			Brake = if tf < 0 then -tf else 0,
			RawLongitudinal = tf,
			Steer = sf,
			Boost = false,
		}
	end

	return {
		Throttle = 0,
		Brake = 0,
		RawLongitudinal = 0,
		Steer = 0,
		Boost = false,
	}
end

local function buildTelemetrySnapshot(
	ctx: VehiclePowertrainContext,
	params: {
		FunctionalEngines: number,
		DrivenWheels: number,
		FreeWheels: number,
		TotalWheels: number,
		AvgWheelRadius: number,
		Speed: number,
		LongSpeed: number,
		SlopeDeg: number,
		SlopeGrade: number,
		Controls: VehicleTypes.DrivingControlIntent,
		CombinedRPM: number,
		CombinedMaxRPM: number,
		LimiterActive: boolean,
		TotalEngineTorque: number,
		TotalWheelDriveTorque: number,
		PerDrivenWheelTorque: number,
		TargetWheelOmega: number,
		AppliedBrakeTorque: number,
		CombinedPower: number,
		CombinedLoad: number,
		MultiEngineEfficiency: number,
		TotalFuelCap: number,
		AvailableFuel: number,
		FuelFraction: number,
		TotalFuelRate: number,
		ConsumedFuel: number,
		LowFuel: boolean,
		OutOfFuel: boolean,
		NoDrivenWheelsError: boolean,
	}
): VehicleTypes.PowertrainTelemetrySnapshot
	local engineStates: { VehicleTypes.EngineRuntimeState } = table.create(#ctx.EngineSlots)
	for _, slot in ipairs(ctx.EngineSlots) do
		table.insert(engineStates, {
			PieceInstanceId = slot.PieceInstanceId,
			ItemId = slot.ItemId,
			InventoryInstanceId = slot.InventoryInstanceId,
			EngineFamilyId = slot.EffectiveStats.EngineFamilyId,
			EngineSizeId = slot.EffectiveStats.EngineSizeId,
			VariantId = slot.EffectiveStats.VariantId,
			RarityId = slot.EffectiveStats.RarityId,
			IsFunctional = slot.PartState.IsFunctional and not slot.PartState.IsDetached,
			IsDetached = slot.PartState.IsDetached,
			Enabled = slot.Enabled,
			PowerLimitRatio = slot.PowerLimitRatio,
			ThrottleResponseMode = slot.ThrottleResponseMode,
			DurabilityEfficiencyFactor = slot.DurabilityEfficiencyFactor,
			CurrentRPM = slot.CurrentRPM,
			TargetRPM = slot.TargetRPM,
			IdleRPM = slot.EffectiveStats.IdleRPM,
			OptimumRPM = slot.EffectiveStats.OptimumRPM,
			MaxRPM = slot.EffectiveStats.MaxRPM,
			LimiterRPM = slot.EffectiveStats.LimiterRPM,
			LimiterActive = slot.LimiterActive,
			CurrentTorque = slot.CurrentTorque,
			AvailableWheelTorque = slot.AvailableWheelTorque,
			CurrentPower = slot.CurrentPower,
			LoadFactor = slot.LoadFactor,
			FuelConsumptionRate = slot.FuelConsumptionRate,
			EffectiveStats = slot.EffectiveStats,
		})
	end

	return {
		RuntimeId = ctx.Runtime.RuntimeId,
		OwnerUserId = ctx.OwnerUserId,
		EngineCount = #ctx.EngineSlots,
		FunctionalEngineCount = params.FunctionalEngines,
		DrivenWheelCount = params.DrivenWheels,
		FreeWheelCount = params.FreeWheels,
		TotalWheelCount = params.TotalWheels,
		TotalVehicleMass = ctx.TotalVehicleMass,
		AverageDrivenWheelRadius = params.AvgWheelRadius,
		SpeedStudsPerSec = params.Speed,
		LongitudinalSpeed = params.LongSpeed,
		SlopeDegrees = params.SlopeDeg,
		SlopeGradeRatio = params.SlopeGrade,
		GearState = ctx.GearState,
		ActiveGearIndex = ctx.ActiveGearIndex,
		ActiveGearRatio = ctx.ActiveGearRatio,
		ThrottleInput = params.Controls.Throttle,
		BrakeInput = params.Controls.Brake,
		SteerInput = params.Controls.Steer,
		CombinedRPM = params.CombinedRPM,
		CombinedMaxRPM = params.CombinedMaxRPM,
		LimiterActive = params.LimiterActive,
		TotalEngineTorque = params.TotalEngineTorque,
		TotalWheelDriveTorque = params.TotalWheelDriveTorque,
		PerDrivenWheelTorque = params.PerDrivenWheelTorque,
		TargetWheelAngularVelocity = params.TargetWheelOmega,
		AppliedBrakeTorque = params.AppliedBrakeTorque,
		CombinedPowerOutput = params.CombinedPower,
		CombinedLoadFactor = params.CombinedLoad,
		MultiEngineEfficiencyFactor = params.MultiEngineEfficiency,
		TotalFuelCapacity = params.TotalFuelCap,
		AvailableFuel = params.AvailableFuel,
		FuelFraction = params.FuelFraction,
		FuelConsumptionRate = params.TotalFuelRate,
		ConsumedFuel = params.ConsumedFuel,
		LowFuel = params.LowFuel,
		OutOfFuel = params.OutOfFuel,
		NoDrivenWheelsError = params.NoDrivenWheelsError,
		Engines = engineStates,
	}
end

local function writeTelemetryAttributes(ctx: VehiclePowertrainContext, snap: VehicleTypes.PowertrainTelemetrySnapshot)
	local root = ctx.Runtime.RootModel
	if not root or not root.Parent then
		return
	end
	root:SetAttribute("PT_EngineCount", snap.EngineCount)
	root:SetAttribute("PT_FunctionalEngineCount", snap.FunctionalEngineCount)
	root:SetAttribute("PT_DrivenWheelCount", snap.DrivenWheelCount)
	root:SetAttribute("PT_TotalVehicleMass", math.round(snap.TotalVehicleMass * 10) / 10)
	root:SetAttribute("PT_SpeedStudsPerSec", math.round(snap.SpeedStudsPerSec * 10) / 10)
	root:SetAttribute("PT_LongitudinalSpeed", math.round(snap.LongitudinalSpeed * 10) / 10)
	root:SetAttribute("PT_SlopeDegrees", math.round(snap.SlopeDegrees * 10) / 10)
	root:SetAttribute("PT_GearState", snap.GearState)
	root:SetAttribute("PT_ActiveGearIndex", snap.ActiveGearIndex)
	root:SetAttribute("PT_CombinedRPM", math.round(snap.CombinedRPM))
	root:SetAttribute("PT_CombinedMaxRPM", math.round(snap.CombinedMaxRPM))
	root:SetAttribute("PT_LimiterActive", snap.LimiterActive)
	root:SetAttribute("PT_TotalEngineTorque", math.round(snap.TotalEngineTorque))
	root:SetAttribute("PT_TotalWheelDriveTorque", math.round(snap.TotalWheelDriveTorque))
	root:SetAttribute("PT_CombinedPowerOutput", math.round(snap.CombinedPowerOutput))
	root:SetAttribute("PT_CombinedLoadFactor", math.round(snap.CombinedLoadFactor * 100) / 100)
	root:SetAttribute("PT_ThrottleInput", math.round(snap.ThrottleInput * 100) / 100)
	root:SetAttribute("PT_BrakeInput", math.round(snap.BrakeInput * 100) / 100)
	root:SetAttribute("PT_AvailableFuel", math.round(snap.AvailableFuel * 10000) / 10000)
	root:SetAttribute("PT_TotalFuelCapacity", math.round(snap.TotalFuelCapacity * 10000) / 10000)
	root:SetAttribute("PT_FuelFraction", math.round(snap.FuelFraction * 10000) / 10000)
	root:SetAttribute("PT_FuelConsumptionRate", math.round(snap.FuelConsumptionRate * 100000) / 100000)
	root:SetAttribute("PT_ConsumedFuel", math.round(snap.ConsumedFuel * 10000) / 10000)
	root:SetAttribute("PT_LowFuel", snap.LowFuel)
	root:SetAttribute("PT_OutOfFuel", snap.OutOfFuel)
	root:SetAttribute("PT_NoDrivenWheelsError", snap.NoDrivenWheelsError)
end

local function stepVehiclePowertrain(ctx: VehiclePowertrainContext, dt: number)
	local P = GameConfig.Powertrain
	local runtime = ctx.Runtime
	local rootModel = runtime.RootModel
	if not rootModel or not rootModel.Parent then
		return
	end

	ctx.SimulatedTime += math.max(0, dt)
	local simNow = ctx.SimulatedTime
	local wallNow = os.clock()
	if simNow - ctx.LastMassRecalcClock >= 0.5 then
		ctx.TotalVehicleMass = computeTotalVehicleMass(rootModel)
		ctx.LastMassRecalcClock = simNow
	end

	-- 1) Leer ruedas desde VehicleWheelControllerService
	local wheelStates = VehicleWheelControllerService.GetVehicleWheels(ctx.OwnerUserId)
	local totalWheels = #wheelStates
	local drivenWheels = 0
	local freeWheels = 0
	local radiusSum = 0

	for _, w in ipairs(wheelStates) do
		if w.IsFunctional and not w.IsDetached then
			if w.ResolvedConfig.IsDriven then
				drivenWheels += 1
				radiusSum += math.max(0.25, w.ResolvedConfig.WheelRadius)
			else
				freeWheels += 1
			end
		end
	end

	local avgWheelRadius = if drivenWheels > 0
		then (radiusSum / drivenWheels)
		else GameConfig.Wheels.DefaultWheelRadius

	-- 2) Cinemática longitudinal y pendiente del chasis
	local refPart = runtime.DriverSeatPart or runtime.PrimaryPart
	local linVel = if refPart then refPart.AssemblyLinearVelocity else Vector3.zero
	local worldForward = if refPart then refPart.CFrame.LookVector else Vector3.new(0, 0, -1)
	local speed = linVel.Magnitude
	local longSpeed = linVel:Dot(worldForward)
	local slopeSin = math.clamp(worldForward.Y, -0.95, 0.95)
	local slopeDeg = math.deg(math.asin(slopeSin))

	-- 3) Controles del conductor autorizado
	local seat = runtime.DriverSeatPart
	local isSeatedDriver = (not runtime.DriverSeatDestroyed) and seat ~= nil and seat.Parent ~= nil and seat.Occupant ~= nil
	if runtime.DriverSeatDestroyed then
		ctx.ClientDrivingInput = nil
		ctx.TestControlOverride = nil
	elseif not isSeatedDriver and not ctx.TestControlOverride then
		ctx.ClientDrivingInput = nil
	end

	local controls = resolveActiveDriverControls(ctx)
	if not runtime.DriverSeatDestroyed and (ctx.TestControlOverride or (ctx.ClientDrivingInput and math.abs(controls.Steer) > 1e-3)) then
		VehicleWheelControllerService.SetSteerOverrideForTests(ctx.OwnerUserId, controls.Steer)
	else
		VehicleWheelControllerService.SetSteerOverrideForTests(ctx.OwnerUserId, nil)
	end

	-- 4) Contabilizar motores funcionales
	local functionalEngines = 0
	for _, slot in ipairs(ctx.EngineSlots) do
		slot.DurabilityEfficiencyFactor = computeDurabilityEfficiency(slot.PartState)
		if slot.Enabled and slot.DurabilityEfficiencyFactor > 0 then
			functionalEngines += 1
		end
	end

	-- Si no hay ningún motor instalado en el vehículo (ej. pruebas puras de ruedas de Fase 3.2),
	-- marcamos shouldSendWheelCommands = false salvo que haya controles activos o motores presentes.
	local shouldSendWheelCommands = (#ctx.EngineSlots > 0)
		or (ctx.ClientDrivingInput ~= nil)
		or (ctx.TestControlOverride ~= nil)

	local noDrivenWheelsError = (#ctx.EngineSlots > 0 and drivenWheels == 0)

	-- 5) Estado de combustible
	local totalFuelCap, availFuel = computeFuelPools(ctx)
	local outOfFuel = (#ctx.EngineSlots > 0) and (totalFuelCap <= 1e-5 or availFuel <= 1e-5)

	-- 6) Máquina de estados de dirección de marcha, frenado y transición segura Forward <-> Reverse
	local prevGearState = ctx.GearState
	local prevGearIndex = ctx.ActiveGearIndex
	local effectiveThrottle = 0
	local serviceBrakeRatio = 0

	if outOfFuel then
		-- Sin combustible: freno de servicio y dirección siguen operando; acelerador y reversa motorizada quedan cortados
		if controls.Brake > P.IdleCreepThreshold then
			ctx.GearState = "Braking"
			ctx.ActiveGearIndex = 0
			ctx.ActiveGearRatio = 0
			serviceBrakeRatio = controls.Brake
		else
			ctx.GearState = "Neutral"
			ctx.ActiveGearIndex = 0
			ctx.ActiveGearRatio = 0
		end
	elseif controls.Throttle > P.IdleCreepThreshold and controls.Brake <= P.IdleCreepThreshold then
		-- Jugador solicita avanzar (W)
		if longSpeed < -P.ReverseEngageMaxBackwardSpeed then
			-- El vehículo aún retrocede con velocidad significativa: frenar antes de invertir par
			ctx.GearState = "Braking"
			ctx.ActiveGearIndex = 0
			ctx.ActiveGearRatio = 0
			serviceBrakeRatio = controls.Throttle
		else
			ctx.GearState = "Forward"
			effectiveThrottle = controls.Throttle
		end
	elseif controls.Brake > P.IdleCreepThreshold and controls.Throttle <= P.IdleCreepThreshold then
		-- Jugador presiona S (Freno / Reversa)
		if longSpeed > P.ReverseEngageMaxForwardSpeed then
			-- El vehículo avanza por encima del umbral seguro: aplicar freno de servicio progresivo
			ctx.GearState = "Braking"
			ctx.ActiveGearIndex = 0
			ctx.ActiveGearRatio = 0
			serviceBrakeRatio = controls.Brake
		else
			-- Velocidad hacia delante suficientemente baja o ya detenido/retrocediendo: engranar Reversa
			ctx.GearState = "Reverse"
			ctx.ActiveGearIndex = -1
			ctx.ActiveGearRatio = P.ReverseGearRatio
			effectiveThrottle = controls.Brake
		end
	elseif controls.Throttle > P.IdleCreepThreshold and controls.Brake > P.IdleCreepThreshold then
		-- Freno y acelerador simultáneos: priorizar frenado seguro
		ctx.GearState = "Braking"
		ctx.ActiveGearIndex = 0
		ctx.ActiveGearRatio = 0
		serviceBrakeRatio = math.max(controls.Brake, 0.5)
	else
		ctx.GearState = "Neutral"
		ctx.ActiveGearIndex = 0
		ctx.ActiveGearRatio = 0
	end

	-- 7) Selección automática de relación de transmisión en Forward
	local gears = P.ForwardGearRatios
	local numGears = #gears
	if ctx.GearState == "Forward" then
		if ctx.ActiveGearIndex < 1 or ctx.ActiveGearIndex > numGears then
			ctx.ActiveGearIndex = 1
		end

		-- Estimar velocidad de referencia promedio de los motores activos
		local refSpeedSum = 0
		for _, slot in ipairs(ctx.EngineSlots) do
			if slot.Enabled and slot.DurabilityEfficiencyFactor > 0 then
				refSpeedSum += slot.EffectiveStats.SpeedRegular * slot.PowerLimitRatio
			end
		end
		local avgRefSpeed = if functionalEngines > 0 then (refSpeedSum / functionalEngines) else 36
		local speedFraction = math.clamp(math.max(0, longSpeed) / math.max(8, avgRefSpeed), 0, 1.2)

		--En pendientes pronunciadas hacia arriba, mantener relaciones bajas para multiplicar torque
		local climbPenalty = math.max(0, slopeSin) * 1.45
		local adjustedFraction = math.max(0, speedFraction - climbPenalty * 0.35)

		local desiredGear = 1
		if adjustedFraction >= 0.76 then
			desiredGear = 4
		elseif adjustedFraction >= 0.48 then
			desiredGear = 3
		elseif adjustedFraction >= 0.24 then
			desiredGear = 2
		else
			desiredGear = 1
		end

		if desiredGear ~= ctx.ActiveGearIndex and (simNow - ctx.LastGearShiftClock) >= P.GearShiftCooldownSeconds then
			ctx.ActiveGearIndex = desiredGear
			ctx.LastGearShiftClock = simNow
		end
		ctx.ActiveGearRatio = gears[ctx.ActiveGearIndex] or gears[1]
	end

	-- 8) Factor de carga física por masa y pendiente
	local massRatio = ctx.TotalVehicleMass / math.max(20, P.ReferenceLightVehicleMass)
	local gradeLoad = if ctx.GearState == "Reverse"
		then math.max(0, -slopeSin) * P.SlopeLoadSensitivity
		else math.max(0, slopeSin) * P.SlopeLoadSensitivity
	local baseVehicleLoad = math.clamp((massRatio - 1.0) * 0.22 + gradeLoad, 0, 0.92)

	-- Multiplicadores de tipo de combustible
	local fuelTorqueMult = P.FuelTypeTorqueMultiplier[ctx.SelectedFuelType] or 1.0
	local fuelSpeedMult = P.FuelTypeSpeedMultiplier[ctx.SelectedFuelType] or 1.0

	-- 9) Simulación individual por motor (RPM, limitador, curva de torque, potencia y consumo)
	local wheelAbsOmega = math.abs(longSpeed) / math.max(0.25, avgWheelRadius)
	local topGearRatio = gears[1] or 3.2
	local gearNormRatio = if ctx.ActiveGearRatio > 0 then (ctx.ActiveGearRatio / topGearRatio) else 1.0

	local engineWheelTorques: { number } = {}
	local totalEngineTorque = 0
	local combinedPower = 0
	local rpmSum = 0
	local maxRpmSum = 0
	local anyLimiter = false
	local loadSum = 0
	local totalFuelRate = 0
	local weightedTargetSpeedSum = 0
	local weightSumForSpeed = 0

	for _, slot in ipairs(ctx.EngineSlots) do
		local stats = slot.EffectiveStats
		local isWorking = slot.Enabled and slot.DurabilityEfficiencyFactor > 0 and not outOfFuel and not noDrivenWheelsError

		if not isWorking then
			slot.TargetRPM = 0
			slot.CurrentRPM = math.max(0, slot.CurrentRPM - 3500 * dt)
			slot.LimiterActive = false
			slot.CurrentTorque = 0
			slot.AvailableWheelTorque = 0
			slot.CurrentPower = 0
			slot.LoadFactor = 0
			slot.FuelConsumptionRate = 0
			if slot.PartState.ModelInstance then
				slot.PartState.ModelInstance:SetAttribute("CurrentRPM", math.round(slot.CurrentRPM))
				slot.PartState.ModelInstance:SetAttribute("CurrentTorque", 0)
				slot.PartState.ModelInstance:SetAttribute("LimiterActive", false)
			end
			continue
		end

		local rpmSpan = math.max(100, stats.MaxRPM - stats.IdleRPM)
		local ratedTopOmega = (stats.SpeedRegular * fuelSpeedMult * slot.PowerLimitRatio) / math.max(0.25, avgWheelRadius)
		local coupledNorm = math.clamp((wheelAbsOmega / math.max(1, ratedTopOmega)) * gearNormRatio, 0, 1.15)
		local wheelCoupledRPM = stats.IdleRPM + coupledNorm * rpmSpan

		local freeRevRPM = stats.IdleRPM + effectiveThrottle * (stats.LimiterRPM - stats.IdleRPM)
		local loadWeight = if (ctx.GearState == "Forward" or ctx.GearState == "Reverse") and drivenWheels > 0
			then math.clamp(0.55 + baseVehicleLoad * 0.35, 0.35, 0.90)
			else 0.0

		local targetRPM = stats.IdleRPM
		if effectiveThrottle > 0 then
			targetRPM = wheelCoupledRPM * loadWeight + freeRevRPM * (1 - loadWeight)
			-- Permitir que a pleno acelerador y alta velocidad alcance el limitador
			if effectiveThrottle >= 0.98 and coupledNorm >= 0.96 then
				targetRPM = stats.LimiterRPM + 40
			end
		else
			targetRPM = math.max(stats.IdleRPM, wheelCoupledRPM * 0.78)
		end

		slot.TargetRPM = targetRPM

		local respRate = stats.Responsiveness * resolveResponseMultiplier(slot.ThrottleResponseMode)
		local rpmAlpha = math.clamp(respRate * dt, 0.02, 1.0)
		slot.CurrentRPM = math.max(stats.IdleRPM, slot.CurrentRPM + (targetRPM - slot.CurrentRPM) * rpmAlpha)

		-- Histéresis del limitador de RPM
		if slot.CurrentRPM >= stats.LimiterRPM then
			slot.LimiterActive = true
		elseif slot.LimiterActive and slot.CurrentRPM <= stats.LimiterRecoveryRPM then
			slot.LimiterActive = false
		end
		if slot.LimiterActive then
			anyLimiter = true
			slot.CurrentRPM = math.max(stats.LimiterRecoveryRPM - 40, slot.CurrentRPM - 2400 * dt)
		end

		local curveTorque = EngineCatalog.EvaluateTorqueAtRPM(stats, slot.CurrentRPM, slot.LimiterActive)
		local activeTorque = 0
		if (ctx.GearState == "Forward" or ctx.GearState == "Reverse") and effectiveThrottle > 0 then
			activeTorque = curveTorque
				* effectiveThrottle
				* slot.PowerLimitRatio
				* slot.DurabilityEfficiencyFactor
				* fuelTorqueMult
			if ctx.GearState == "Reverse" then
				activeTorque *= P.ReverseTorqueRatio
			end
		end

		local wheelTorqueFromEngine = activeTorque * ctx.ActiveGearRatio * P.FinalDriveRatio * P.TransmissionEfficiency
		slot.CurrentTorque = activeTorque
		slot.AvailableWheelTorque = wheelTorqueFromEngine

		local normRPM = math.clamp((slot.CurrentRPM - stats.IdleRPM) / rpmSpan, 0, 1)
		slot.CurrentPower = stats.PowerRating
			* (activeTorque / math.max(1, stats.PeakTorque))
			* (0.35 + 0.65 * normRPM)

		local throttleRatio = effectiveThrottle * (0.35 + 0.65 * slot.PowerLimitRatio)
		local externalLoadContribution = (0.15 + 0.85 * effectiveThrottle) * math.clamp(baseVehicleLoad, 0, 1) * 0.36
		local rpmLoadContribution = if effectiveThrottle > 0 then 0.22 * normRPM else 0.05 * normRPM
		slot.LoadFactor = math.clamp(0.42 * throttleRatio + rpmLoadContribution + externalLoadContribution, 0, 1)

		local idleFrac = P.IdleFuelConsumptionFraction
		local fuelConsMult = if P.FuelTypeConsumptionMultiplier
			then (P.FuelTypeConsumptionMultiplier[ctx.SelectedFuelType] or 1.0)
			else 1.0
		local maxConsPerSec = stats.MaxFuelConsumption / math.max(1, P.FuelConsumptionTimeBaseSeconds)
		local consRate = maxConsPerSec * fuelConsMult * (idleFrac + (1 - idleFrac) * slot.LoadFactor)
		slot.FuelConsumptionRate = consRate

		totalEngineTorque += activeTorque
		combinedPower += slot.CurrentPower
		rpmSum += slot.CurrentRPM
		maxRpmSum += stats.MaxRPM
		loadSum += slot.LoadFactor
		totalFuelRate += consRate

		if wheelTorqueFromEngine > 0 then
			table.insert(engineWheelTorques, wheelTorqueFromEngine)
			local effSpeed = stats.SpeedRegular * fuelSpeedMult * slot.PowerLimitRatio * slot.DurabilityEfficiencyFactor
			weightedTargetSpeedSum += effSpeed * wheelTorqueFromEngine
			weightSumForSpeed += wheelTorqueFromEngine
		end

		if slot.PartState.ModelInstance then
			slot.PartState.ModelInstance:SetAttribute("CurrentRPM", math.round(slot.CurrentRPM))
			slot.PartState.ModelInstance:SetAttribute("CurrentTorque", math.round(slot.CurrentTorque))
			slot.PartState.ModelInstance:SetAttribute("LimiterActive", slot.LimiterActive)
		end
	end

	-- Drenar combustible si está habilitado en configuración o prueba
	if ctx.ConsumeFuelEnabled and totalFuelRate > 0 and dt > 0 then
		local drained = drainFuelFromContext(ctx, totalFuelRate * dt)
		ctx.ConsumedFuel += drained
		totalFuelCap, availFuel = computeFuelPools(ctx)
		outOfFuel = (#ctx.EngineSlots > 0) and (totalFuelCap <= 1e-5 or availFuel <= 1e-5)
		if outOfFuel then
			table.clear(engineWheelTorques)
			totalEngineTorque = 0
			combinedPower = 0
			totalFuelRate = 0
			anyLimiter = false
			for _, slot in ipairs(ctx.EngineSlots) do
				slot.CurrentTorque = 0
				slot.AvailableWheelTorque = 0
				slot.CurrentPower = 0
				slot.LoadFactor = 0
				slot.FuelConsumptionRate = 0
				slot.LimiterActive = false
				if slot.PartState.ModelInstance then
					slot.PartState.ModelInstance:SetAttribute("CurrentTorque", 0)
					slot.PartState.ModelInstance:SetAttribute("LimiterActive", false)
				end
			end
		end
	end

	-- 10) Regla explícita de combinación multimotor (rendimientos decrecientes suaves + tope técnico)
	table.sort(engineWheelTorques, function(a, b)
		return a > b
	end)

	local rawWheelTorqueSum = 0
	local combinedWheelTorque = 0
	local decay = P.MultiEngineEfficiencyDecay
	for idx, wt in ipairs(engineWheelTorques) do
		if idx <= P.MaxCombinedEngines then
			rawWheelTorqueSum += wt
			local mult = decay ^ (idx - 1)
			combinedWheelTorque += wt * mult
		end
	end
	combinedWheelTorque = math.min(combinedWheelTorque, P.MaxTotalWheelDriveTorque)
	local multiEngineEfficiency = if rawWheelTorqueSum > 0 then (combinedWheelTorque / rawWheelTorqueSum) else 1.0

	-- 11) Conversión a comandos de ruedas motrices y frenado
	local perDrivenWheelTorque = if drivenWheels > 0
		then math.min(P.MaxPerWheelDriveTorque, combinedWheelTorque / drivenWheels)
		else 0

	local targetWheelOmega = 0
	local appliedBrakeTorque = 0

	if ctx.GearState == "Braking" then
		appliedBrakeTorque = P.ServiceBrakeBaseTorquePerWheel * math.clamp(serviceBrakeRatio, 0.15, 1.0)
		perDrivenWheelTorque = 0
		targetWheelOmega = 0
		ctx.SmoothedTargetLinearSpeed = 0
	elseif ctx.GearState == "Forward" and perDrivenWheelTorque > 0 and drivenWheels > 0 then
		local baseTopSpeed = if weightSumForSpeed > 0
			then (weightedTargetSpeedSum / weightSumForSpeed)
			else 36.0
		-- Bonificación multimotor frente a masa pesada: más motores sostienen mejor la velocidad bajo carga
		local massPerEngine = math.max(0, ctx.TotalVehicleMass - P.ReferenceLightVehicleMass) / math.max(1, functionalEngines)
		local massSpeedFactor = 1.0 / (1.0 + massPerEngine * P.MassLoadSensitivity)
		local multiEngineTopSpeedBonus = 1.0 + math.min(0.18, math.max(0, functionalEngines - 1) * 0.06)
		local effectiveMaxLinearSpeed = baseTopSpeed * massSpeedFactor * multiEngineTopSpeedBonus * effectiveThrottle

		local boostActive = VehicleBoosterService.IsBoostActiveForPlayer(ctx.OwnerUserId)
			or (rootModel:GetAttribute("BS_AnyActive") == true)
		if boostActive and longSpeed > effectiveMaxLinearSpeed then
			-- Embrague unidireccional (overrunning clutch): cuando los propulsores superan la velocidad
			-- tope del motor, las ruedas motrices ruedan libres sin frenar el empuje del cohete.
			combinedWheelTorque = 0
			perDrivenWheelTorque = 0
			appliedBrakeTorque = 0
			ctx.SmoothedTargetLinearSpeed = math.max(ctx.SmoothedTargetLinearSpeed, effectiveMaxLinearSpeed)
			targetWheelOmega = longSpeed / math.max(0.25, avgWheelRadius)
		else
			-- Rampa progresiva de velocidad objetivo ponderada por relación potencia/masa
			local accelRate = 28.0 * massSpeedFactor * multiEngineTopSpeedBonus
			local minLaunchSpeed = effectiveMaxLinearSpeed * 0.65
			ctx.SmoothedTargetLinearSpeed = math.clamp(
				math.max(minLaunchSpeed, math.abs(longSpeed), ctx.SmoothedTargetLinearSpeed) + accelRate * math.max(0.01, dt),
				0,
				effectiveMaxLinearSpeed
			)
			targetWheelOmega = ctx.SmoothedTargetLinearSpeed / math.max(0.25, avgWheelRadius)
		end
	elseif ctx.GearState == "Reverse" and perDrivenWheelTorque > 0 and drivenWheels > 0 then
		local baseTopSpeed = if weightSumForSpeed > 0
			then (weightedTargetSpeedSum / weightSumForSpeed)
			else 36.0
		local maxRevSpeed = baseTopSpeed * P.ReverseMaxSpeedRatio * effectiveThrottle
		ctx.SmoothedTargetLinearSpeed = maxRevSpeed
		targetWheelOmega = -(maxRevSpeed / math.max(0.25, avgWheelRadius))
	else
		-- Neutral / Coasting: sin combustible o sin motor funcional, permitir rodamiento libre por inercia
		local boostActive = VehicleBoosterService.IsBoostActiveForPlayer(ctx.OwnerUserId)
			or (rootModel:GetAttribute("BS_AnyActive") == true)
		targetWheelOmega = 0
		perDrivenWheelTorque = 0
		ctx.SmoothedTargetLinearSpeed = math.max(0, ctx.SmoothedTargetLinearSpeed - 30.0 * math.max(0.01, dt))
		if math.abs(longSpeed) > 0.5 and functionalEngines > 0 and not outOfFuel and not noDrivenWheelsError and not boostActive then
			appliedBrakeTorque = GameConfig.Wheels.DefaultBrakeTorque * P.CoastEngineBrakeTorqueScale
		end
	end

	-- Enviar comandos autoritativos a VehicleWheelControllerService únicamente si hay motores o input de conducción activo
	if shouldSendWheelCommands then
		if drivenWheels > 0 or appliedBrakeTorque > 0 then
			VehicleWheelControllerService.SetVehicleDriveCommands(ctx.OwnerUserId, {
				TargetAngularVelocity = targetWheelOmega,
				TorqueLimit = perDrivenWheelTorque,
				BrakeTorque = appliedBrakeTorque,
			})
		else
			VehicleWheelControllerService.ClearDriveCommands(ctx.OwnerUserId)
		end
	end

	local avgRPM = if functionalEngines > 0 then (rpmSum / functionalEngines) else 0
	local avgMaxRPM = if functionalEngines > 0 then (maxRpmSum / functionalEngines) else 5800
	local avgLoad = if functionalEngines > 0 then (loadSum / functionalEngines) else 0

	local fuelFraction = if totalFuelCap > 0 then math.clamp(availFuel / totalFuelCap, 0, 1) else 0
	local lowFuel = (#ctx.EngineSlots > 0) and (not outOfFuel) and (totalFuelCap > 0) and (fuelFraction <= P.LowFuelWarningFraction)

	local snapshot = buildTelemetrySnapshot(ctx, {
		FunctionalEngines = functionalEngines,
		DrivenWheels = drivenWheels,
		FreeWheels = freeWheels,
		TotalWheels = totalWheels,
		AvgWheelRadius = avgWheelRadius,
		Speed = speed,
		LongSpeed = longSpeed,
		SlopeDeg = slopeDeg,
		SlopeGrade = slopeSin,
		Controls = controls,
		CombinedRPM = avgRPM,
		CombinedMaxRPM = avgMaxRPM,
		LimiterActive = anyLimiter,
		TotalEngineTorque = totalEngineTorque,
		TotalWheelDriveTorque = combinedWheelTorque,
		PerDrivenWheelTorque = perDrivenWheelTorque,
		TargetWheelOmega = targetWheelOmega,
		AppliedBrakeTorque = appliedBrakeTorque,
		CombinedPower = combinedPower,
		CombinedLoad = avgLoad,
		MultiEngineEfficiency = multiEngineEfficiency,
		TotalFuelCap = totalFuelCap,
		AvailableFuel = availFuel,
		FuelFraction = fuelFraction,
		TotalFuelRate = totalFuelRate,
		ConsumedFuel = ctx.ConsumedFuel,
		LowFuel = lowFuel,
		OutOfFuel = outOfFuel,
		NoDrivenWheelsError = noDrivenWheelsError,
	})
	ctx.LastSnapshot = snapshot

	local gearChanged = (ctx.GearState ~= prevGearState) or (ctx.ActiveGearIndex ~= prevGearIndex)
	local fuelAlertChanged = (lowFuel ~= ctx.LastFuelWarningFlag) or (outOfFuel ~= ctx.LastOutOfFuelFlag)
	ctx.LastFuelWarningFlag = lowFuel
	ctx.LastOutOfFuelFlag = outOfFuel

	if gearChanged or fuelAlertChanged or (simNow - ctx.LastTelemetryWriteClock) >= P.TelemetryUpdateIntervalSeconds then
		ctx.LastTelemetryWriteClock = simNow
		writeTelemetryAttributes(ctx, snapshot)
	end
end

function VehiclePowertrainService.RegisterRuntime(runtime: VehicleTypes.VehicleRuntime)
	if not runtime then
		return
	end
	local userId = runtime.OwnerUserId
	VehiclePowertrainService.UnregisterRuntime(runtime)

	local engineSlots: { InternalEngineSlot } = {}
	local engineSlotsByPieceId: { [string]: InternalEngineSlot } = {}
	local fuelTankSlots: { InternalFuelTankSlot } = {}
	local selectedFuelType: "Regular" | "Diesel" | "Competicion" = "Regular"

	local enginePieceIds: { string } = {}
	local fuelTankPieceIds: { string } = {}

	-- Orden determinístico por PieceInstanceId
	local sortedPieceIds: { string } = {}
	for pid in pairs(runtime.Parts) do
		table.insert(sortedPieceIds, pid)
	end
	table.sort(sortedPieceIds)

	for _, pid in ipairs(sortedPieceIds) do
		local partState = runtime.Parts[pid]
		local itemDef = ItemRegistry.TryGet(partState.ItemId)
		if not itemDef then
			continue
		end

		if itemDef.Category == "Engines" then
			local cfg = partState.Config
			local invId: string? = if cfg and type(cfg._InventoryInstanceId) == "string" and #cfg._InventoryInstanceId > 0
				then cfg._InventoryInstanceId
				else nil
			local cachedStats: ItemTypes.EffectiveEngineStats? = if cfg then cfg._ResolvedEngineStats else nil
			local effectiveStats = cachedStats
				or (EngineInventoryService.ResolvePieceEffectiveStats(userId, {
					ItemId = partState.ItemId,
					InventoryInstanceId = invId,
					Config = cfg,
				}))

			local engCfg = if cfg and type(cfg.Engine) == "table" then cfg.Engine else nil
			local powerLimit = if engCfg and type(engCfg.PowerLimitRatio) == "number"
				then math.clamp(engCfg.PowerLimitRatio, GameConfig.Powertrain.MinPowerLimitRatio, GameConfig.Powertrain.MaxPowerLimitRatio)
				else GameConfig.Powertrain.DefaultPowerLimitRatio
			local respMode: "Smooth" | "Balanced" | "Sport" = if engCfg
					and (engCfg.ThrottleResponseMode == "Smooth" or engCfg.ThrottleResponseMode == "Balanced" or engCfg.ThrottleResponseMode == "Sport")
				then engCfg.ThrottleResponseMode
				else "Balanced"
			local enabled = if engCfg and type(engCfg.Enabled) == "boolean" then engCfg.Enabled else true

			local slot: InternalEngineSlot = {
				PieceInstanceId = pid,
				ItemId = partState.ItemId,
				InventoryInstanceId = invId,
				PartState = partState,
				EffectiveStats = effectiveStats,
				PowerLimitRatio = powerLimit,
				ThrottleResponseMode = respMode,
				Enabled = enabled,
				CurrentRPM = effectiveStats.IdleRPM,
				TargetRPM = effectiveStats.IdleRPM,
				LimiterActive = false,
				CurrentTorque = 0,
				AvailableWheelTorque = 0,
				CurrentPower = 0,
				LoadFactor = 0,
				DurabilityEfficiencyFactor = computeDurabilityEfficiency(partState),
				FuelConsumptionRate = 0,
			}

			table.insert(engineSlots, slot)
			engineSlotsByPieceId[pid] = slot
			table.insert(enginePieceIds, pid)
		elseif itemDef.Category == "FuelTanks" and itemDef.Stats.FuelSubtype == "Normal" then
			local cfg = partState.Config
			local ftCfg = if cfg and type(cfg.FuelTank) == "table" then cfg.FuelTank else nil
			local selFuel: "Regular" | "Diesel" | "Competicion" = if ftCfg
					and (ftCfg.SelectedFuelType == "Regular" or ftCfg.SelectedFuelType == "Diesel" or ftCfg.SelectedFuelType == "Competicion")
				then ftCfg.SelectedFuelType
				else "Regular"
			selectedFuelType = selFuel

			table.insert(fuelTankSlots, {
				PieceInstanceId = pid,
				ItemId = partState.ItemId,
				PartState = partState,
				Capacity = itemDef.Stats.Capacity or 1.5,
				SelectedFuelType = selFuel,
			})
			table.insert(fuelTankPieceIds, pid)
		end
	end

	runtime.EnginePieceIds = enginePieceIds
	runtime.FuelTankPieceIds = fuelTankPieceIds

	local totalMass = computeTotalVehicleMass(runtime.RootModel)
	local emptyControls: VehicleTypes.DrivingControlIntent = {
		Throttle = 0,
		Brake = 0,
		RawLongitudinal = 0,
		Steer = 0,
		Boost = false,
	}

	local ctx: VehiclePowertrainContext = {
		Runtime = runtime,
		OwnerUserId = userId,
		EngineSlots = engineSlots,
		EngineSlotsByPieceId = engineSlotsByPieceId,
		FuelTankSlots = fuelTankSlots,
		SelectedFuelType = selectedFuelType,
		GearState = "Neutral",
		ActiveGearIndex = 0,
		ActiveGearRatio = 0,
		SimulatedTime = 0,
		LastGearShiftClock = -10,
		SmoothedTargetLinearSpeed = 0,
		TotalVehicleMass = totalMass,
		LastMassRecalcClock = 0,
		ConsumeFuelEnabled = GameConfig.Powertrain.ConsumeFuelByDefault,
		ConsumedFuel = 0,
		LastFuelWarningFlag = false,
		LastOutOfFuelFlag = false,
		ClientDrivingInput = nil,
		TestControlOverride = nil,
		LastTelemetryWriteClock = -10,
		LastSnapshot = nil :: any,
	}

	_contextsByUserId[userId] = ctx

	-- Ejecutar un primer paso de inicialización de telemetría (dt = 0)
	stepVehiclePowertrain(ctx, 0)
	writeTelemetryAttributes(ctx, ctx.LastSnapshot)
end

function VehiclePowertrainService.DetachPiece(runtime, pieceId)
	local ctx = _contextsByUserId[runtime.OwnerUserId]
	if not ctx or ctx.Runtime ~= runtime then
		return
	end
	ctx.EngineSlotsByPieceId[pieceId] = nil
	for _, list in { ctx.EngineSlots, ctx.FuelTankSlots } do
		for i = #list, 1, -1 do
			if list[i].PieceInstanceId == pieceId or list[i].PartState == runtime.Parts[pieceId] then
				table.remove(list, i)
			end
		end
	end
	if runtime.PropulsionPieceIds then
		local idx = table.find(runtime.PropulsionPieceIds, pieceId)
		if idx then
			table.remove(runtime.PropulsionPieceIds, idx)
		end
	end
	-- Recalculate commands immediately; no old engine torque survives this transaction.
	stepVehiclePowertrain(ctx, 0)
	writeTelemetryAttributes(ctx, ctx.LastSnapshot)
end

function VehiclePowertrainService.UnregisterRuntime(runtimeOrUserId: VehicleTypes.VehicleRuntime | number)
	local userId = if type(runtimeOrUserId) == "number"
		then runtimeOrUserId
		else runtimeOrUserId.OwnerUserId
	local existing = _contextsByUserId[userId]
	if existing then
		_contextsByUserId[userId] = nil
	end
end

-- Procesa input de conducción enviado por un jugador real, verificando que sea propietario y esté sentado en DriverSeat.
function VehiclePowertrainService.ApplyClientDrivingInput(
	player: PlayerLike,
	rawInput: any
): (boolean, string?, string?)
	local userId = extractUserId(player)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return false, BuildProtocol.ErrorCodes.RuntimeNotActive, "No tienes un vehículo activo en conducción"
	end

	if ctx.Runtime.OwnerUserId ~= userId then
		return false, BuildProtocol.ErrorCodes.NotRuntimeOwner, "No eres el propietario de este vehículo"
	end

	local seat = ctx.Runtime.DriverSeatPart
	local occupant = if seat then seat.Occupant else nil
	if typeof(player) == "Instance" and player:IsA("Player") then
		local char = player.Character
		local hum = if char then char:FindFirstChildOfClass("Humanoid") else nil
		if not occupant or occupant ~= hum then
			return false, BuildProtocol.ErrorCodes.NotSeatedDriver, "Debes estar sentado en el DriverSeat para controlar el vehículo"
		end
	elseif ctx.Runtime.State ~= GameConfig.Runtime.States.Driving and not occupant then
		return false, BuildProtocol.ErrorCodes.NotSeatedDriver, "El vehículo no tiene conductor sentado"
	end

	local okVal, validated, errCode, errMsg = BuildPayloadValidator.ValidateDrivingInput(rawInput)
	if not okVal or not validated then
		return false, errCode or BuildProtocol.ErrorCodes.InvalidPayload, errMsg or "Input de conducción inválido"
	end

	local boostPressed = validated.Boost == true
	ctx.ClientDrivingInput = {
		Throttle = validated.Throttle,
		Brake = validated.Brake,
		RawLongitudinal = validated.RawLongitudinal,
		Steer = validated.Steer,
		Boost = boostPressed,
		Timestamp = os.clock(),
	}
	if VehicleBoosterService.GetBoosterState(player) ~= nil then
		local okBoost, bErrCode, bErrMsg = VehicleBoosterService.ApplyClientBoostInput(player, boostPressed)
		if not okBoost then
			return false, bErrCode, bErrMsg
		end
	end

	return true, nil, nil
end

function VehiclePowertrainService.SetControlOverrideForTests(
	playerOrUserId: PlayerLike | number,
	override: {
		Throttle: number?,
		Brake: number?,
		RawLongitudinal: number?,
		Steer: number?,
		Boost: boolean?,
	}?
)
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return
	end
	if override == nil then
		ctx.TestControlOverride = nil
		VehicleWheelControllerService.SetSteerOverrideForTests(userId, nil)
		VehicleBoosterService.SetBoostOverrideForTests(userId, nil)
		return
	end

	local throttle = math.clamp(override.Throttle or 0, 0, 1)
	local brake = math.clamp(override.Brake or 0, 0, 1)
	local rawLong = if override.RawLongitudinal ~= nil
		then math.clamp(override.RawLongitudinal, -1, 1)
		else math.clamp(throttle - brake, -1, 1)
	if override.Throttle == nil and override.Brake == nil and override.RawLongitudinal ~= nil then
		if rawLong > 0 then
			throttle = rawLong
			brake = 0
		elseif rawLong < 0 then
			throttle = 0
			brake = -rawLong
		end
	end
	local steer = math.clamp(override.Steer or 0, -1, 1)
	local boost = override.Boost == true

	ctx.TestControlOverride = {
		Throttle = throttle,
		Brake = brake,
		RawLongitudinal = rawLong,
		Steer = steer,
		Boost = boost,
		Timestamp = os.clock(),
	}
	if override.Boost ~= nil then
		VehicleBoosterService.SetBoostOverrideForTests(userId, boost)
	end
end

function VehiclePowertrainService.SetFuelConsumptionEnabled(playerOrUserId: PlayerLike | number, enabled: boolean)
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if ctx then
		ctx.ConsumeFuelEnabled = enabled == true
	end
end

function VehiclePowertrainService.SetFuelLevelForTests(playerOrUserId: PlayerLike | number, fuelAmountPerSource: number)
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return
	end
	local clamped = math.max(0, fuelAmountPerSource)
	for _, slot in ipairs(ctx.EngineSlots) do
		slot.PartState.CurrentFuel = math.min(slot.EffectiveStats.IntegratedFuel, clamped)
	end
	for _, tank in ipairs(ctx.FuelTankSlots) do
		tank.PartState.CurrentFuel = math.min(tank.Capacity, clamped)
	end
end

function VehiclePowertrainService.GetPowertrainState(
	playerOrUserId: PlayerLike | number
): VehicleTypes.PowertrainTelemetrySnapshot?
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return nil
	end
	return ctx.LastSnapshot
end

function VehiclePowertrainService.GetEngineState(
	playerOrUserId: PlayerLike | number,
	pieceInstanceId: string
): VehicleTypes.EngineRuntimeState?
	local snap = VehiclePowertrainService.GetPowertrainState(playerOrUserId)
	if not snap then
		return nil
	end
	for _, eng in ipairs(snap.Engines) do
		if eng.PieceInstanceId == pieceInstanceId then
			return eng
		end
	end
	return nil
end

function VehiclePowertrainService.StepAll(dt: number)
	local clampedDt = math.clamp(dt, 0, 0.25)
	for _, ctx in pairs(_contextsByUserId) do
		stepVehiclePowertrain(ctx, clampedDt)
	end
end

function VehiclePowertrainService.Init()
	if _initialized then
		return
	end

	local existingRemote = ReplicatedStorage:FindFirstChild(BuildProtocol.DrivingInputRemoteEventName)
	if existingRemote and existingRemote:IsA("RemoteEvent") then
		_drivingInputRemote = existingRemote
	else
		if existingRemote then
			existingRemote:Destroy()
		end
		local remote = Instance.new("RemoteEvent")
		remote.Name = BuildProtocol.DrivingInputRemoteEventName
		remote.Parent = ReplicatedStorage
		_drivingInputRemote = remote
	end

	_initialized = true
end

function VehiclePowertrainService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehiclePowertrainService.Init()
	end

	if _drivingInputRemote then
		_drivingInputRemote.OnServerEvent:Connect(function(player: Player, rawInput: any)
			VehiclePowertrainService.ApplyClientDrivingInput(player, rawInput)
		end)
	end

	if not _heartbeatConn then
		_heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
			VehiclePowertrainService.StepAll(dt)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		VehiclePowertrainService.UnregisterRuntime(player.UserId)
	end)

	_started = true
end

function VehiclePowertrainService._ResetForTests()
	table.clear(_contextsByUserId)
end

return VehiclePowertrainService

