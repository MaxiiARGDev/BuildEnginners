--!strict
--[=[
	VehicleBoosterService
	Orquestador centralizado en servidor de propulsores modulares, Nitro (RocketFuel) y
	empuje vectorial real (Fase 3.4).

	Reglas SDD y AGENTS.md:
	- Un único bucle Heartbeat centralizado para todos los vehículos activos (cero Heartbeat por pieza).
	- Vectorización real basada en la orientación física actual de cada propulsor:
	  WorldThrustDirection = BoosterWorldCFrame:VectorToWorldSpace(LocalThrustAxis)
	  aplicada con VectorForce (ApplyAtCenterOfMass = false, RelativeTo = World) sobre un Attachment
	  rígido del ensamblaje para producir torque/yaw/pitch naturales sin teletransporte CFrame.
	- Combustible Nitro (RocketFuel) completamente separado del combustible Normal de motores.
	- Nunca persiste Nitro gastado ni durabilidad degradada de vuelta al VehicleBlueprint.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BoosterInventoryService = require(ServerScriptService.Server.Services.BoosterInventoryService)

export type PlayerLike = Player | {
	UserId: number,
	Name: string,
}

type InternalBoosterSlot = {
	PieceInstanceId: string,
	ItemId: string,
	InventoryInstanceId: string?,
	PartState: VehicleTypes.RuntimePartState,
	PrimaryPart: BasePart?,
	ModelInstance: Model?,
	ThrustAttachment: Attachment?,
	VectorForce: VectorForce?,
	EffectiveStats: ItemTypes.EffectiveBoosterStats,
	ThrustLimitRatio: number,
	ThrottleCurveMode: "Instant" | "Smooth" | "Sustained",
	Enabled: boolean,
	DurabilityEfficiencyFactor: number,
	BoosterState: VehicleTypes.BoosterLifecycleState,
	ThrottleFraction: number,
	TargetThrottleFraction: number,
	AppliedThrust: number,
	EffectiveThrustMax: number,
	LocalThrustAxis: Vector3,
	WorldThrustDirection: Vector3,
	NitroConsumptionRate: number,
	LastVisualAttrThrottle: number,
	LastVisualAttrState: string,
}

type InternalNitroTankSlot = {
	PieceInstanceId: string,
	ItemId: string,
	PartState: VehicleTypes.RuntimePartState,
	Capacity: number,
}

type VehicleBoosterContext = {
	Runtime: VehicleTypes.VehicleRuntime,
	OwnerUserId: number,
	BoosterSlots: { InternalBoosterSlot },
	BoosterSlotsByPieceId: { [string]: InternalBoosterSlot },
	NitroTankSlots: { InternalNitroTankSlot },
	SimulatedTime: number,
	ConsumeNitroEnabled: boolean,
	ConsumedNitro: number,
	ClientBoostInput: { Active: boolean, UpdatedAt: number, AllowUnoccupiedSimulatedSeat: boolean? }?,
	TestBoostOverride: boolean?,
	LastAnyActiveFlag: boolean,
	LastLowNitroFlag: boolean,
	LastOutOfNitroFlag: boolean,
	LastTelemetryWriteClock: number,
	LastSnapshot: VehicleTypes.BoosterTelemetrySnapshot,
}

local VehicleBoosterService = {
	Name = "VehicleBoosterService",
}

local _initialized = false
local _started = false
local _heartbeatConn: RBXScriptConnection? = nil
local _contextsByUserId: { [number]: VehicleBoosterContext } = {}

local function extractUserId(playerOrUserId: PlayerLike | number): number
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return playerOrUserId.UserId
	elseif type(playerOrUserId) == "table" and type((playerOrUserId :: any).UserId) == "number" then
		return (playerOrUserId :: any).UserId
	end
	error("[VehicleBoosterService] Invalid player or userId", 3)
end

local function computeDurabilityEfficiency(partState: VehicleTypes.RuntimePartState): number
	if not partState.IsFunctional or partState.IsDetached then
		return 0
	end
	local maxDur = math.max(1, partState.MaxDurability)
	local curDur = math.clamp(partState.CurrentDurability, 0, maxDur)
	local ratio = curDur / maxDur
	if ratio < GameConfig.Boosters.MinimumOperationalDurabilityFraction then
		return 0
	end
	if ratio >= 0.5 then
		return 0.85 + (ratio - 0.5) * 0.30
	end
	return 0.35 + (ratio / 0.5) * 0.50
end

local function computeNitroPools(ctx: VehicleBoosterContext): (number, number)
	local totalCap = 0
	local avail = 0

	for _, slot in ipairs(ctx.BoosterSlots) do
		if slot.PartState.IsFunctional and not slot.PartState.IsDetached then
			totalCap += slot.EffectiveStats.IntegratedFuel
			avail += math.max(0, slot.PartState.CurrentFuel or 0)
		end
	end

	for _, tank in ipairs(ctx.NitroTankSlots) do
		if tank.PartState.IsFunctional and not tank.PartState.IsDetached then
			totalCap += tank.Capacity
			avail += math.max(0, tank.PartState.CurrentFuel or 0)
		end
	end

	return totalCap, avail
end

local function drainNitroFromContext(ctx: VehicleBoosterContext, amountToDrain: number): number
	if amountToDrain <= 0 then
		return 0
	end
	local remaining = amountToDrain

	-- Drenar primero de tanques dedicados de Nitro (SmallNitroTank) y luego de los propulsores (IntegratedFuel)
	for _, tank in ipairs(ctx.NitroTankSlots) do
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

	for _, slot in ipairs(ctx.BoosterSlots) do
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

local function resolveCurveRates(slot: InternalBoosterSlot): (number, number)
	local upT = math.max(0.03, slot.EffectiveStats.IgnitionRampSeconds)
	local downT = math.max(0.04, slot.EffectiveStats.ShutdownRampSeconds)
	if slot.ThrottleCurveMode == "Instant" then
		return 50.0, 25.0
	elseif slot.ThrottleCurveMode == "Sustained" then
		return 0.65 / upT, 0.60 / downT
	end
	return 1.0 / upT, 1.0 / downT
end

local function computeEnvelopeFactor(speedAlongThrust: number, speedBoostMult: number): number
	local B = GameConfig.Boosters
	local maxEnvelopeSpeed = B.BaseEnvelopeSpeedStudsPerSec + speedBoostMult * B.SpeedMultiplierRangeScale
	local ratio = math.max(0, speedAlongThrust) / math.max(10, maxEnvelopeSpeed)
	if ratio <= 0.75 then
		return 1.0
	end
	local taperAlpha = math.clamp((ratio - 0.75) / 0.45, 0, 1)
	return B.HighSpeedTaperFloor + (1.0 - B.HighSpeedTaperFloor) * (1.0 - taperAlpha)
end

local function resolveActiveBoostIntent(ctx: VehicleBoosterContext): boolean
	if ctx.Runtime.DriverSeatDestroyed then return false end
	if ctx.TestBoostOverride ~= nil then
		return ctx.TestBoostOverride == true
	end

	local runtime = ctx.Runtime
	if runtime.State ~= GameConfig.Runtime.States.Driving then
		ctx.ClientBoostInput = nil
		return false
	end

	local seat = runtime.DriverSeatPart
	local isSeatedDriver = seat ~= nil and seat.Parent ~= nil and seat.Occupant ~= nil
	local isSimulatedDriver = ctx.ClientBoostInput ~= nil and ctx.ClientBoostInput.AllowUnoccupiedSimulatedSeat == true
	if not isSeatedDriver and not isSimulatedDriver then
		ctx.ClientBoostInput = nil
		return false
	end

	return ctx.ClientBoostInput ~= nil and ctx.ClientBoostInput.Active == true
end

local function writeSlotAttributes(slot: InternalBoosterSlot, forceWrite: boolean?)
	local model = slot.ModelInstance
	if not model or not model.Parent then
		return
	end
	local stateChanged = slot.LastVisualAttrState ~= slot.BoosterState
	local throttleDelta = math.abs(slot.LastVisualAttrThrottle - slot.ThrottleFraction)
	if not forceWrite and not stateChanged and throttleDelta < 0.025 then
		return
	end

	slot.LastVisualAttrState = slot.BoosterState
	slot.LastVisualAttrThrottle = slot.ThrottleFraction

	local active = slot.AppliedThrust > 0.5
		and (slot.BoosterState == "Igniting" or slot.BoosterState == "Active" or slot.BoosterState == "RampDown")
	model:SetAttribute("BoosterActive", active)
	model:SetAttribute("BoosterState", slot.BoosterState)
	model:SetAttribute("ThrottleFraction", math.round(slot.ThrottleFraction * 1000) / 1000)
	model:SetAttribute("AppliedThrust", math.round(slot.AppliedThrust * 10) / 10)
	model:SetAttribute("WorldThrustDirection", slot.WorldThrustDirection)
	model:SetAttribute("BoosterEnabled", slot.Enabled)
end

local function writeRootTelemetryAttributes(ctx: VehicleBoosterContext, snap: VehicleTypes.BoosterTelemetrySnapshot)
	local root = ctx.Runtime.RootModel
	if not root or not root.Parent then
		return
	end
	root:SetAttribute("BS_BoosterCount", snap.BoosterCount)
	root:SetAttribute("BS_FunctionalBoosterCount", snap.FunctionalBoosterCount)
	root:SetAttribute("BS_ActiveBoosterCount", snap.ActiveBoosterCount)
	root:SetAttribute("BS_BoostInputActive", snap.BoostInputActive)
	root:SetAttribute("BS_AnyActive", snap.AnyBoosterActive)
	root:SetAttribute("BS_TotalAppliedThrust", math.round(snap.TotalAppliedThrust * 10) / 10)
	root:SetAttribute("BS_MaxPossibleThrust", math.round(snap.MaxPossibleThrust * 10) / 10)
	root:SetAttribute("BS_NetThrustVector", snap.NetThrustVector)
	root:SetAttribute("BS_TotalNitroCapacity", math.round(snap.TotalNitroCapacity * 10) / 10)
	root:SetAttribute("BS_AvailableNitro", math.round(snap.AvailableNitro * 10) / 10)
	root:SetAttribute("BS_NitroFraction", math.round(snap.NitroFraction * 10000) / 10000)
	root:SetAttribute("BS_NitroConsumptionRate", math.round(snap.NitroConsumptionRate * 10) / 10)
	root:SetAttribute("BS_ConsumedNitro", math.round(snap.ConsumedNitro * 10) / 10)
	root:SetAttribute("BS_LowNitro", snap.LowNitro)
	root:SetAttribute("BS_OutOfNitro", snap.OutOfNitro)
end

local function buildSnapshot(
	ctx: VehicleBoosterContext,
	params: {
		FunctionalBoosters: number,
		ActiveBoosters: number,
		BoostInputActive: boolean,
		AnyActive: boolean,
		SpeedStudsPerSec: number,
		TotalAppliedThrust: number,
		MaxPossibleThrust: number,
		NetThrustVector: Vector3,
		TotalNitroCap: number,
		AvailableNitro: number,
		NitroFraction: number,
		NitroRate: number,
		LowNitro: boolean,
		OutOfNitro: boolean,
	}
): VehicleTypes.BoosterTelemetrySnapshot
	local boosterStates: { VehicleTypes.BoosterRuntimeState } = {}
	for _, slot in ipairs(ctx.BoosterSlots) do
		table.insert(boosterStates, {
			PieceInstanceId = slot.PieceInstanceId,
			ItemId = slot.ItemId,
			InventoryInstanceId = slot.InventoryInstanceId,
			BoosterFamilyId = slot.EffectiveStats.BoosterFamilyId,
			BoosterSizeId = slot.EffectiveStats.BoosterSizeId,
			VariantId = slot.EffectiveStats.VariantId,
			RarityId = slot.EffectiveStats.RarityId,
			IsFunctional = slot.PartState.IsFunctional and slot.DurabilityEfficiencyFactor > 0,
			IsDetached = slot.PartState.IsDetached,
			Enabled = slot.Enabled,
			ThrustLimitRatio = slot.ThrustLimitRatio,
			ThrottleCurveMode = slot.ThrottleCurveMode,
			DurabilityEfficiencyFactor = slot.DurabilityEfficiencyFactor,
			BoosterState = slot.BoosterState,
			ThrottleFraction = slot.ThrottleFraction,
			TargetThrottleFraction = slot.TargetThrottleFraction,
			AppliedThrust = slot.AppliedThrust,
			EffectiveThrustMax = slot.EffectiveThrustMax,
			LocalThrustAxis = slot.LocalThrustAxis,
			WorldThrustDirection = slot.WorldThrustDirection,
			NitroConsumptionRate = slot.NitroConsumptionRate,
			EffectiveStats = slot.EffectiveStats,
		})
	end

	return {
		RuntimeId = ctx.Runtime.RuntimeId,
		OwnerUserId = ctx.OwnerUserId,
		BoosterCount = #ctx.BoosterSlots,
		FunctionalBoosterCount = params.FunctionalBoosters,
		ActiveBoosterCount = params.ActiveBoosters,
		BoostInputActive = params.BoostInputActive,
		AnyBoosterActive = params.AnyActive,
		SpeedStudsPerSec = params.SpeedStudsPerSec,
		TotalAppliedThrust = params.TotalAppliedThrust,
		MaxPossibleThrust = params.MaxPossibleThrust,
		NetThrustVector = params.NetThrustVector,
		TotalNitroCapacity = params.TotalNitroCap,
		AvailableNitro = params.AvailableNitro,
		NitroFraction = params.NitroFraction,
		NitroConsumptionRate = params.NitroRate,
		ConsumedNitro = ctx.ConsumedNitro,
		LowNitro = params.LowNitro,
		OutOfNitro = params.OutOfNitro,
		Boosters = boosterStates,
	}
end

local function stepVehicleBoosters(ctx: VehicleBoosterContext, dt: number)
	local B = GameConfig.Boosters
	local runtime = ctx.Runtime
	local rootModel = runtime.RootModel
	if not rootModel or not rootModel.Parent then
		return
	end

	local clampedDt = math.max(0, dt)
	ctx.SimulatedTime += clampedDt
	local simNow = ctx.SimulatedTime

	local boostPressed = resolveActiveBoostIntent(ctx)
	local totalNitroCap, availNitro = computeNitroPools(ctx)
	local outOfNitro = (#ctx.BoosterSlots > 0) and (totalNitroCap <= 1e-3 or availNitro <= 1e-3)

	-- Calcular durabilidad y orientación mundial dinámica de cada propulsor
	local functionalBoosters = 0
	local maxPossibleThrust = 0
	for _, slot in ipairs(ctx.BoosterSlots) do
		slot.DurabilityEfficiencyFactor = computeDurabilityEfficiency(slot.PartState)
		if slot.PrimaryPart and slot.PrimaryPart.Parent then
			local rawDir = slot.PrimaryPart.CFrame:VectorToWorldSpace(slot.LocalThrustAxis)
			slot.WorldThrustDirection = if rawDir.Magnitude > 1e-4 then rawDir.Unit else Vector3.new(0, 0, -1)
		end

		slot.EffectiveThrustMax = slot.EffectiveStats.Thrust
			* B.ThrustForceScale
			* slot.ThrustLimitRatio
			* slot.DurabilityEfficiencyFactor

		if slot.Enabled and slot.DurabilityEfficiencyFactor > 0 then
			functionalBoosters += 1
			maxPossibleThrust += math.min(B.MaxSingleBoosterAppliedThrust, slot.EffectiveThrustMax)
		end
	end

	-- Calcular curvas de ignición / ramp-down y demanda de consumo Nitro
	local totalRequestedDrain = 0
	local requestedDrainBySlot: { [InternalBoosterSlot]: number } = {}

	for _, slot in ipairs(ctx.BoosterSlots) do
		local upRate, downRate = resolveCurveRates(slot)
		if slot.DurabilityEfficiencyFactor <= 0 then
			slot.TargetThrottleFraction = 0
			slot.ThrottleFraction = 0
			slot.BoosterState = "Destroyed"
			slot.NitroConsumptionRate = 0
		elseif not slot.Enabled then
			slot.TargetThrottleFraction = 0
			slot.ThrottleFraction = math.max(0, slot.ThrottleFraction - downRate * clampedDt)
			if slot.ThrottleFraction <= 0.01 then
				slot.ThrottleFraction = 0
				slot.BoosterState = "Disabled"
			else
				slot.BoosterState = "RampDown"
			end
		elseif outOfNitro then
			slot.TargetThrottleFraction = 0
			slot.ThrottleFraction = 0
			slot.BoosterState = "Depleted"
			slot.NitroConsumptionRate = 0
		elseif boostPressed then
			slot.TargetThrottleFraction = 1.0
			slot.ThrottleFraction = math.min(1.0, slot.ThrottleFraction + upRate * (if clampedDt > 0 then clampedDt else 0))
			if clampedDt <= 0 and slot.ThrottleFraction <= 0 then
				-- Tick dt=0 inicial con override activo empieza en ignición mínima medible si se desea o avanza con StepAll(dt>0)
				slot.BoosterState = "Igniting"
			else
				slot.BoosterState = if slot.ThrottleFraction < 0.96 then "Igniting" else "Active"
			end
		else
			slot.TargetThrottleFraction = 0
			slot.ThrottleFraction = math.max(0, slot.ThrottleFraction - downRate * clampedDt)
			if slot.ThrottleFraction <= 0.01 then
				slot.ThrottleFraction = 0
				slot.BoosterState = "Idle"
			else
				slot.BoosterState = "RampDown"
			end
		end

		local isBurning = slot.ThrottleFraction > 0.01
			and (slot.BoosterState == "Igniting" or slot.BoosterState == "Active" or slot.BoosterState == "RampDown")
		if isBurning and ctx.ConsumeNitroEnabled and clampedDt > 0 then
			-- Durante RampDown consume proporcionalmente menos según ThrottleFraction
			local rate = (slot.EffectiveStats.BoostConsumption / math.max(0.05, B.NitroConsumptionTimeBaseSeconds))
				* slot.ThrottleFraction
				* slot.ThrustLimitRatio
			slot.NitroConsumptionRate = rate
			local want = rate * clampedDt
			requestedDrainBySlot[slot] = want
			totalRequestedDrain += want
		else
			slot.NitroConsumptionRate = 0
		end
	end

	-- Drenaje autoritativo proporcional si varios propulsores compiten por el último resto de Nitro
	local fuelScaleThisTick = 1.0
	if ctx.ConsumeNitroEnabled and totalRequestedDrain > 0 and clampedDt > 0 then
		if totalRequestedDrain > availNitro then
			fuelScaleThisTick = math.clamp(availNitro / math.max(1e-6, totalRequestedDrain), 0, 1)
			local drained = drainNitroFromContext(ctx, availNitro)
			ctx.ConsumedNitro += drained
		else
			local drained = drainNitroFromContext(ctx, totalRequestedDrain)
			ctx.ConsumedNitro += drained
		end
	end

	-- Reevaluar Nitro tras drenaje
	totalNitroCap, availNitro = computeNitroPools(ctx)
	outOfNitro = (#ctx.BoosterSlots > 0) and (totalNitroCap <= 1e-3 or availNitro <= 1e-3)

	local refPart = runtime.DriverSeatPart or runtime.PrimaryPart
	local refVel = if refPart then refPart.AssemblyLinearVelocity else Vector3.zero
	local vehicleSpeed = refVel.Magnitude

	local totalAppliedThrust = 0
	local netThrustVector = Vector3.zero
	local activeBoosters = 0
	local totalNitroRate = 0

	for _, slot in ipairs(ctx.BoosterSlots) do
		local applied = 0
		local isWorking = slot.Enabled
			and slot.DurabilityEfficiencyFactor > 0
			and slot.ThrottleFraction > 0.01
			and (slot.BoosterState == "Igniting" or slot.BoosterState == "Active" or slot.BoosterState == "RampDown")

		if isWorking then
			local slotVel = if slot.PrimaryPart and slot.PrimaryPart.Parent
				then slot.PrimaryPart.AssemblyLinearVelocity
				else refVel
			local speedAlong = math.max(0, slotVel:Dot(slot.WorldThrustDirection))
			local envFactor = computeEnvelopeFactor(speedAlong, slot.EffectiveStats.SpeedBoostMultiplier)
			local rawForce = slot.EffectiveThrustMax * slot.ThrottleFraction * envFactor * fuelScaleThisTick
			applied = math.clamp(rawForce, 0, B.MaxSingleBoosterAppliedThrust)
		end

		if outOfNitro and slot.DurabilityEfficiencyFactor > 0 and slot.Enabled then
			if fuelScaleThisTick <= 0 or clampedDt > 0 then
				-- Ya agotado tras este tick: la reserva quedó en 0
				if availNitro <= 1e-3 then
					slot.BoosterState = "Depleted"
					slot.ThrottleFraction = 0
					slot.NitroConsumptionRate = 0
				end
			end
		end

		slot.AppliedThrust = applied
		if slot.VectorForce and slot.VectorForce.Parent then
			if applied > 0.5 then
				slot.VectorForce.Force = slot.WorldThrustDirection * applied
				slot.VectorForce.Enabled = true
			else
				slot.VectorForce.Force = Vector3.zero
				slot.VectorForce.Enabled = false
			end
		end

		if applied > 0.5 then
			activeBoosters += 1
			totalAppliedThrust += applied
			netThrustVector += slot.WorldThrustDirection * applied
		end
		totalNitroRate += slot.NitroConsumptionRate
		writeSlotAttributes(slot, false)
	end

	local anyActive = activeBoosters > 0
	local nitroFraction = if totalNitroCap > 0 then math.clamp(availNitro / totalNitroCap, 0, 1) else 0
	local lowNitro = (#ctx.BoosterSlots > 0)
		and (not outOfNitro)
		and (totalNitroCap > 0)
		and (nitroFraction <= B.LowNitroWarningFraction)

	local snapshot = buildSnapshot(ctx, {
		FunctionalBoosters = functionalBoosters,
		ActiveBoosters = activeBoosters,
		BoostInputActive = boostPressed,
		AnyActive = anyActive,
		SpeedStudsPerSec = vehicleSpeed,
		TotalAppliedThrust = totalAppliedThrust,
		MaxPossibleThrust = maxPossibleThrust,
		NetThrustVector = netThrustVector,
		TotalNitroCap = totalNitroCap,
		AvailableNitro = availNitro,
		NitroFraction = nitroFraction,
		NitroRate = totalNitroRate,
		LowNitro = lowNitro,
		OutOfNitro = outOfNitro,
	})
	ctx.LastSnapshot = snapshot

	local stateTransition = (anyActive ~= ctx.LastAnyActiveFlag)
		or (lowNitro ~= ctx.LastLowNitroFlag)
		or (outOfNitro ~= ctx.LastOutOfNitroFlag)
	ctx.LastAnyActiveFlag = anyActive
	ctx.LastLowNitroFlag = lowNitro
	ctx.LastOutOfNitroFlag = outOfNitro

	if stateTransition or (simNow - ctx.LastTelemetryWriteClock) >= B.TelemetryUpdateIntervalSeconds then
		ctx.LastTelemetryWriteClock = simNow
		writeRootTelemetryAttributes(ctx, snapshot)
	end
end

function VehicleBoosterService.RegisterRuntime(runtime: VehicleTypes.VehicleRuntime)
	if not runtime then
		return
	end
	local userId = runtime.OwnerUserId
	VehicleBoosterService.UnregisterRuntime(runtime)

	local boosterSlots: { InternalBoosterSlot } = {}
	local boosterSlotsByPieceId: { [string]: InternalBoosterSlot } = {}
	local nitroTankSlots: { InternalNitroTankSlot } = {}
	local boosterPieceIds: { string } = {}
	local nitroTankPieceIds: { string } = {}

	local sortedIds: { string } = {}
	for pid in pairs(runtime.Parts) do
		table.insert(sortedIds, pid)
	end
	table.sort(sortedIds)

	for _, pid in ipairs(sortedIds) do
		local partState = runtime.Parts[pid]
		local itemDef = ItemRegistry.TryGet(partState.ItemId)
		if not itemDef then
			continue
		end

		if itemDef.Category == "Boosters" then
			local cfg = partState.Config
			local invId: string? = if cfg and type(cfg._InventoryInstanceId) == "string" and #cfg._InventoryInstanceId > 0
				then cfg._InventoryInstanceId
				else nil
			local cachedStats: ItemTypes.EffectiveBoosterStats? = if cfg then cfg._ResolvedBoosterStats else nil
			local effectiveStats = cachedStats
				or (BoosterInventoryService.ResolvePieceEffectiveStats(userId, {
					ItemId = partState.ItemId,
					InventoryInstanceId = invId,
					Config = cfg,
				}))

			local bstCfg = if cfg and type(cfg.Booster) == "table" then cfg.Booster else nil
			local thrustLimit = if bstCfg and type(bstCfg.ThrustLimitRatio) == "number"
				then math.clamp(bstCfg.ThrustLimitRatio, GameConfig.Boosters.MinThrustLimitRatio, GameConfig.Boosters.MaxThrustLimitRatio)
				else GameConfig.Boosters.DefaultThrustLimitRatio
			local curveMode: "Instant" | "Smooth" | "Sustained" = if bstCfg
					and (bstCfg.ThrottleCurveMode == "Instant" or bstCfg.ThrottleCurveMode == "Smooth" or bstCfg.ThrottleCurveMode == "Sustained")
				then bstCfg.ThrottleCurveMode
				else "Smooth"
			local enabled = if bstCfg and type(bstCfg.Enabled) == "boolean" then bstCfg.Enabled else true

			local primaryPart = partState.PrimaryPart
			local thrustAtt: Attachment? = nil
			local vectorForce: VectorForce? = nil
			local localAxis = GameConfig.Boosters.DefaultLocalThrustAxis
			local initialWorldDir = Vector3.new(0, 0, -1)

			if primaryPart then
				local existingAtt = primaryPart:FindFirstChild("BoosterThrustAttachment")
				if existingAtt and existingAtt:IsA("Attachment") then
					thrustAtt = existingAtt
				else
					local att = Instance.new("Attachment")
					att.Name = "BoosterThrustAttachment"
					att.Position = Vector3.zero
					att.Parent = primaryPart
					thrustAtt = att
				end

				local existingForce = primaryPart:FindFirstChild("BoosterVectorForce")
				if existingForce and existingForce:IsA("VectorForce") then
					vectorForce = existingForce
				else
					local vf = Instance.new("VectorForce")
					vf.Name = "BoosterVectorForce"
					vf.Attachment0 = thrustAtt
					vf.ApplyAtCenterOfMass = false
					vf.RelativeTo = Enum.ActuatorRelativeTo.World
					vf.Force = Vector3.zero
					vf.Enabled = false
					vf.Parent = primaryPart
					vectorForce = vf
				end

				local rawDir = primaryPart.CFrame:VectorToWorldSpace(localAxis)
				initialWorldDir = if rawDir.Magnitude > 1e-4 then rawDir.Unit else Vector3.new(0, 0, -1)
			end

			local durEff = computeDurabilityEfficiency(partState)
			local initialState: VehicleTypes.BoosterLifecycleState = if durEff <= 0
				then "Destroyed"
				elseif not enabled then "Disabled"
				elseif (partState.CurrentFuel or 0) <= 1e-3 and #nitroTankSlots == 0 and effectiveStats.IntegratedFuel <= 0 then "Depleted"
				else "Idle"

			local slot: InternalBoosterSlot = {
				PieceInstanceId = pid,
				ItemId = partState.ItemId,
				InventoryInstanceId = invId,
				PartState = partState,
				PrimaryPart = primaryPart,
				ModelInstance = partState.ModelInstance,
				ThrustAttachment = thrustAtt,
				VectorForce = vectorForce,
				EffectiveStats = effectiveStats,
				ThrustLimitRatio = thrustLimit,
				ThrottleCurveMode = curveMode,
				Enabled = enabled,
				DurabilityEfficiencyFactor = durEff,
				BoosterState = initialState,
				ThrottleFraction = 0,
				TargetThrottleFraction = 0,
				AppliedThrust = 0,
				EffectiveThrustMax = effectiveStats.Thrust * GameConfig.Boosters.ThrustForceScale * thrustLimit * durEff,
				LocalThrustAxis = localAxis,
				WorldThrustDirection = initialWorldDir,
				NitroConsumptionRate = 0,
				LastVisualAttrThrottle = -1,
				LastVisualAttrState = "",
			}

			writeSlotAttributes(slot, true)
			table.insert(boosterSlots, slot)
			boosterSlotsByPieceId[pid] = slot
			table.insert(boosterPieceIds, pid)
		elseif itemDef.Category == "FuelTanks" and (itemDef.Stats.FuelType == "RocketFuel" or itemDef.Stats.FuelSubtype == "Nitro") then
			table.insert(nitroTankSlots, {
				PieceInstanceId = pid,
				ItemId = partState.ItemId,
				PartState = partState,
				Capacity = itemDef.Stats.Capacity or 28800,
			})
			table.insert(nitroTankPieceIds, pid)
		end
	end

	runtime.BoosterPieceIds = boosterPieceIds
	runtime.NitroTankPieceIds = nitroTankPieceIds

	local ctx: VehicleBoosterContext = {
		Runtime = runtime,
		OwnerUserId = userId,
		BoosterSlots = boosterSlots,
		BoosterSlotsByPieceId = boosterSlotsByPieceId,
		NitroTankSlots = nitroTankSlots,
		SimulatedTime = 0,
		ConsumeNitroEnabled = GameConfig.Boosters.ConsumeNitroByDefault,
		ConsumedNitro = 0,
		ClientBoostInput = nil,
		TestBoostOverride = nil,
		LastAnyActiveFlag = false,
		LastLowNitroFlag = false,
		LastOutOfNitroFlag = false,
		LastTelemetryWriteClock = -10,
		LastSnapshot = nil :: any,
	}

	_contextsByUserId[userId] = ctx
	stepVehicleBoosters(ctx, 0)
	writeRootTelemetryAttributes(ctx, ctx.LastSnapshot)
end

function VehicleBoosterService.DetachPiece(runtime, pieceId)
	local ctx = _contextsByUserId[runtime.OwnerUserId]
	if not ctx or ctx.Runtime ~= runtime then
		return
	end
	for i = #ctx.BoosterSlots, 1, -1 do
		local slot = ctx.BoosterSlots[i]
		if slot.PieceInstanceId == pieceId or slot.PartState == runtime.Parts[pieceId] then
			if slot.VectorForce then
				slot.VectorForce.Force = Vector3.zero
				slot.VectorForce.Enabled = false
				slot.VectorForce:Destroy()
				slot.VectorForce = nil
			end
			slot.ThrustAttachment = nil
			slot.AppliedThrust = 0
			slot.ThrottleFraction = 0
			slot.TargetThrottleFraction = 0
			slot.NitroConsumptionRate = 0
			slot.BoosterState = "Destroyed"
			writeSlotAttributes(slot, true)
			table.remove(ctx.BoosterSlots, i)
		end
	end
	for i = #ctx.NitroTankSlots, 1, -1 do
		if ctx.NitroTankSlots[i].PieceInstanceId == pieceId or ctx.NitroTankSlots[i].PartState == runtime.Parts[pieceId] then
			table.remove(ctx.NitroTankSlots, i)
		end
	end
	if ctx.BoosterSlotsByPieceId then
		ctx.BoosterSlotsByPieceId[pieceId] = nil
	end
	if runtime.BoosterPieceIds then
		local idx = table.find(runtime.BoosterPieceIds, pieceId)
		if idx then
			table.remove(runtime.BoosterPieceIds, idx)
		end
	end
	if runtime.NitroTankPieceIds then
		local idx = table.find(runtime.NitroTankPieceIds, pieceId)
		if idx then
			table.remove(runtime.NitroTankPieceIds, idx)
		end
	end
	stepVehicleBoosters(ctx, 0)
	writeRootTelemetryAttributes(ctx, ctx.LastSnapshot)
end

function VehicleBoosterService.UnregisterRuntime(runtimeOrUserId: VehicleTypes.VehicleRuntime | number)
	local userId = if type(runtimeOrUserId) == "number"
		then runtimeOrUserId
		else runtimeOrUserId.OwnerUserId
	local existing = _contextsByUserId[userId]
	if existing then
		for _, slot in ipairs(existing.BoosterSlots) do
			if slot.VectorForce then
				slot.VectorForce.Force = Vector3.zero
				slot.VectorForce.Enabled = false
			end
			slot.AppliedThrust = 0
			slot.ThrottleFraction = 0
			slot.BoosterState = "Idle"
			writeSlotAttributes(slot, true)
		end
		_contextsByUserId[userId] = nil
	end
end

function VehicleBoosterService.ApplyClientBoostInput(
	player: PlayerLike,
	boostActive: any
): (boolean, string?, string?)
	local userId = extractUserId(player)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return false, BuildProtocol.ErrorCodes.RuntimeNotActive, "No tienes un vehículo activo en conducción"
	end

	if ctx.Runtime.OwnerUserId ~= userId then
		return false, BuildProtocol.ErrorCodes.NotRuntimeOwner, "No eres el propietario de este vehículo"
	end

	if type(boostActive) ~= "boolean" then
		return false, BuildProtocol.ErrorCodes.InvalidPayload, "Boost debe ser booleano"
	end

	local seat = ctx.Runtime.DriverSeatPart
	local occupant = if seat then seat.Occupant else nil
	local isRealPlayer = typeof(player) == "Instance" and player:IsA("Player")
	if isRealPlayer then
		local char = player.Character
		local hum = if char then char:FindFirstChildOfClass("Humanoid") else nil
		if not occupant or occupant ~= hum then
			return false, BuildProtocol.ErrorCodes.NotSeatedDriver, "Debes estar sentado en el DriverSeat para activar propulsores"
		end
	elseif ctx.Runtime.State ~= GameConfig.Runtime.States.Driving and not occupant then
		return false, BuildProtocol.ErrorCodes.NotSeatedDriver, "El vehículo no tiene conductor sentado"
	end

	ctx.ClientBoostInput = {
		Active = boostActive,
		UpdatedAt = os.clock(),
		AllowUnoccupiedSimulatedSeat = (not isRealPlayer) and (ctx.Runtime.State == GameConfig.Runtime.States.Driving),
	}
	return true, nil, nil
end

function VehicleBoosterService.CutBoostForPlayer(playerOrUserId: PlayerLike | number, _reason: string?)
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return
	end
	ctx.ClientBoostInput = nil
	ctx.TestBoostOverride = nil
	for _, slot in ipairs(ctx.BoosterSlots) do
		slot.TargetThrottleFraction = 0
		slot.ThrottleFraction = 0
		slot.AppliedThrust = 0
		slot.NitroConsumptionRate = 0
		if slot.DurabilityEfficiencyFactor <= 0 then
			slot.BoosterState = "Destroyed"
		elseif not slot.Enabled then
			slot.BoosterState = "Disabled"
		else
			slot.BoosterState = "Idle"
		end
		if slot.VectorForce then
			slot.VectorForce.Force = Vector3.zero
			slot.VectorForce.Enabled = false
		end
		writeSlotAttributes(slot, true)
	end
	stepVehicleBoosters(ctx, 0)
	writeRootTelemetryAttributes(ctx, ctx.LastSnapshot)
end

function VehicleBoosterService.SetBoostOverrideForTests(playerOrUserId: PlayerLike | number, boostActive: boolean?)
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if ctx then
		ctx.TestBoostOverride = boostActive
	end
end

function VehicleBoosterService.SetNitroConsumptionEnabled(playerOrUserId: PlayerLike | number, enabled: boolean)
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if ctx then
		ctx.ConsumeNitroEnabled = enabled == true
	end
end

function VehicleBoosterService.SetNitroLevelForTests(playerOrUserId: PlayerLike | number, nitroPerSource: number)
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return
	end
	local clamped = math.max(0, nitroPerSource)
	for _, slot in ipairs(ctx.BoosterSlots) do
		slot.PartState.CurrentFuel = math.min(slot.EffectiveStats.IntegratedFuel, clamped)
	end
	for _, tank in ipairs(ctx.NitroTankSlots) do
		tank.PartState.CurrentFuel = math.min(tank.Capacity, clamped)
	end
	stepVehicleBoosters(ctx, 0)
	writeRootTelemetryAttributes(ctx, ctx.LastSnapshot)
end

function VehicleBoosterService.SetBoosterEnabledForTests(
	playerOrUserId: PlayerLike | number,
	pieceInstanceId: string,
	enabled: boolean
)
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if ctx then
		local slot = ctx.BoosterSlotsByPieceId[pieceInstanceId]
		if slot then
			slot.Enabled = enabled == true
		end
	end
end

function VehicleBoosterService.GetBoosterState(
	playerOrUserId: PlayerLike | number
): VehicleTypes.BoosterTelemetrySnapshot?
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return nil
	end
	return ctx.LastSnapshot
end

function VehicleBoosterService.GetBoosterSlotState(
	playerOrUserId: PlayerLike | number,
	pieceInstanceId: string
): VehicleTypes.BoosterRuntimeState?
	local snap = VehicleBoosterService.GetBoosterState(playerOrUserId)
	if not snap then
		return nil
	end
	for _, b in ipairs(snap.Boosters) do
		if b.PieceInstanceId == pieceInstanceId then
			return b
		end
	end
	return nil
end

function VehicleBoosterService.IsBoostActiveForPlayer(playerOrUserId: PlayerLike | number): boolean
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	return ctx ~= nil and ctx.LastSnapshot ~= nil and ctx.LastSnapshot.AnyBoosterActive
end

function VehicleBoosterService.StepAll(dt: number)
	local clampedDt = math.clamp(dt, 0, 0.25)
	for _, ctx in pairs(_contextsByUserId) do
		stepVehicleBoosters(ctx, clampedDt)
	end
end

function VehicleBoosterService.Init()
	if _initialized then
		return
	end
	_initialized = true
end

function VehicleBoosterService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehicleBoosterService.Init()
	end
	if not _heartbeatConn then
		_heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
			VehicleBoosterService.StepAll(dt)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		VehicleBoosterService.UnregisterRuntime(player.UserId)
	end)
	_started = true
end

function VehicleBoosterService._ResetForTests()
	for _, ctx in pairs(_contextsByUserId) do
		for _, slot in ipairs(ctx.BoosterSlots) do
			if slot.VectorForce then
				slot.VectorForce.Force = Vector3.zero
				slot.VectorForce.Enabled = false
			end
		end
	end
	table.clear(_contextsByUserId)
end

return VehicleBoosterService


