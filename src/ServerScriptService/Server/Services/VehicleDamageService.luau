--!strict
--[=[
	VehicleDamageService
	Servicio autoritativo centralizado para durabilidad por pieza, aplicación de daño,
	distribución localizada con hooks para fases futuras, telemetría y diagnóstico dev-only (Fase 4.1).

	Reglas SDD y de fase:
	- Mantiene la salud individual EXCLUSIVAMENTE en runtime temporal; jamás muta blueprints ni inventario.
	- Cero RemoteEvents de daño desde el cliente; toda mutación pasa por el servidor.
	- Fase 4.1: no elimina WeldConstraints, no desprende piezas ni altera rendimiento de motores/ruedas/boosters/tanques.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DamageConfig = require(ReplicatedStorage.Shared.Config.DamageConfig)
local DamageMath = require(ReplicatedStorage.Shared.Damage.DamageMath)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type DamageChangedListener = (
	runtimeId: string,
	ownerUserId: number,
	impactResult: VehicleTypes.DamageImpactResult,
	summary: VehicleTypes.VehicleHealthSummary
) -> ()

type InternalPieceEntry = {
	Record: VehicleTypes.PieceDamageRecord,
	PartState: VehicleTypes.RuntimePartState,
	ModelInstance: Model?,
	PrimaryPart: BasePart?,
}

type InternalVehicleDamageEntry = {
	RuntimeId: string,
	OwnerUserId: number,
	Runtime: VehicleTypes.VehicleRuntime,
	PiecesById: { [string]: InternalPieceEntry },
	OrderedPieceIds: { string },
	AdjacencyById: { [string]: { string } },
	TotalPieces: number,
	HealthyCount: number,
	DamagedCount: number,
	DisabledCount: number,
	TotalMaxHealth: number,
	TotalCurrentHealth: number,
	TotalDamageReceived: number,
	ImpactCount: number,
	LastImpactAt: number?,
	LastImpactSpeed: number?,
	LastImpactMagnitude: number?,
	LastImpactPieceId: string?,
	DebugHistory: { VehicleTypes.DebugImpactRecord },
	LastTelemetrySyncWallAt: number,
	TelemetryDirty: boolean,
	FlushScheduled: boolean,
	Destroyed: boolean,
}

local VehicleDestructionService = require(script.Parent.VehicleDestructionService)

local VehicleDamageService = {
	Name = "VehicleDamageService",
}

local _entriesByRuntimeId: { [string]: InternalVehicleDamageEntry } = {}
local _entriesByUserId: { [number]: InternalVehicleDamageEntry } = {}
local _damageListeners: { DamageChangedListener } = {}
local _authorizedDevUserIds: { [number]: boolean } = {}
local _devDebugMode = RunService:IsStudio() and DamageConfig.Debug.DefaultEnabledInStudio
local _allowAllStudioDevs = RunService:IsStudio()
local _clockFn: () -> number = os.clock
local _initialized = false
local _started = false

local function nowSeconds(): number
	return _clockFn()
end

local function isFinitePositive(n: any): boolean
	return DamageMath.IsFiniteNumber(n) and n > 0
end

local function resolveEntry(runtimeOrIdOrUser: (VehicleTypes.VehicleRuntime | { UserId: number } | string | number)?): InternalVehicleDamageEntry?
	if runtimeOrIdOrUser == nil then
		return nil
	end
	if type(runtimeOrIdOrUser) == "string" then
		return _entriesByRuntimeId[runtimeOrIdOrUser]
	elseif type(runtimeOrIdOrUser) == "number" then
		return _entriesByUserId[runtimeOrIdOrUser]
	elseif type(runtimeOrIdOrUser) == "table" or typeof(runtimeOrIdOrUser) == "Instance" then
		local anyRef = runtimeOrIdOrUser :: any
		if type(anyRef.RuntimeId) == "string" and _entriesByRuntimeId[anyRef.RuntimeId] ~= nil then
			return _entriesByRuntimeId[anyRef.RuntimeId]
		end
		local userId = anyRef.OwnerUserId or anyRef.UserId
		if type(userId) == "number" then
			return _entriesByUserId[userId]
		end
	end
	return nil
end

local function clonePieceRecord(rec: VehicleTypes.PieceDamageRecord): VehicleTypes.PieceDamageRecord
	return {
		PieceId = rec.PieceId,
		PieceInstanceId = rec.PieceInstanceId,
		ItemId = rec.ItemId,
		Category = rec.Category,
		MaxHealth = rec.MaxHealth,
		CurrentHealth = rec.CurrentHealth,
		Durability = rec.Durability,
		ImpactResistance = rec.ImpactResistance,
		DamageMultiplier = rec.DamageMultiplier,
		IntegrityRatio = rec.IntegrityRatio,
		IntegrityPercent = rec.IntegrityPercent,
		State = rec.State,
		DamageReceivedTotal = rec.DamageReceivedTotal,
		ImpactCount = rec.ImpactCount,
		LastImpactAt = rec.LastImpactAt,
		LastImpactRelativeSpeed = rec.LastImpactRelativeSpeed,
		LastImpactMagnitude = rec.LastImpactMagnitude,
		BalanceStatus = rec.BalanceStatus,
	}
end

local function buildSummary(entry: InternalVehicleDamageEntry): VehicleTypes.VehicleHealthSummary
	local totalMax = math.max(0, entry.TotalMaxHealth)
	local totalCur = math.clamp(entry.TotalCurrentHealth, 0, totalMax)
	local ratio = if totalMax > 0 then math.clamp(totalCur / totalMax, 0, 1) else 1.0
	local pct = math.round(ratio * 10000) / 100

	return {
		RuntimeId = entry.RuntimeId,
		OwnerUserId = entry.OwnerUserId,
		TotalPieces = entry.TotalPieces,
		HealthyCount = entry.HealthyCount,
		DamagedCount = entry.DamagedCount,
		DisabledCount = entry.DisabledCount,
		ExhaustedCount = entry.DisabledCount,
		TotalMaxHealth = math.round(totalMax * 1000) / 1000,
		TotalCurrentHealth = math.round(totalCur * 1000) / 1000,
		IntegrityRatio = ratio,
		IntegrityPercent = pct,
		TotalDamageReceived = math.round(entry.TotalDamageReceived * 1000) / 1000,
		ImpactCount = entry.ImpactCount,
		LastImpactAt = entry.LastImpactAt,
		LastImpactSpeed = entry.LastImpactSpeed,
		LastImpactMagnitude = entry.LastImpactMagnitude,
		LastImpactPieceId = entry.LastImpactPieceId,
	}
end

local function writePieceDebugAttributes(pieceEntry: InternalPieceEntry, lastRelSpeed: number?, lastImpactMag: number?)
	if not _devDebugMode or not DamageConfig.Debug.WritePieceDebugAttributes then
		return
	end
	local model = pieceEntry.ModelInstance
	if not model or not model.Parent then
		return
	end
	local rec = pieceEntry.Record
	model:SetAttribute("DMG_PieceId", rec.PieceId)
	model:SetAttribute("DMG_CurrentHealth", math.round(rec.CurrentHealth * 1000) / 1000)
	model:SetAttribute("DMG_MaxHealth", rec.MaxHealth)
	model:SetAttribute("DMG_Durability", rec.Durability)
	model:SetAttribute("DMG_ImpactResistance", rec.ImpactResistance)
	model:SetAttribute("DMG_DamageMultiplier", rec.DamageMultiplier)
	model:SetAttribute("DMG_State", rec.State)
	model:SetAttribute("DMG_DamageReceivedTotal", math.round(rec.DamageReceivedTotal * 1000) / 1000)
	model:SetAttribute("DMG_ImpactCount", rec.ImpactCount)
	if lastRelSpeed ~= nil then
		model:SetAttribute("DMG_LastRelSpeed", math.round(lastRelSpeed * 100) / 100)
	end
	if lastImpactMag ~= nil then
		model:SetAttribute("DMG_LastImpactMag", math.round(lastImpactMag * 100) / 100)
	end
end

local function writeRootTelemetryAttributes(entry: InternalVehicleDamageEntry)
	local root = entry.Runtime.RootModel
	if not root or not root.Parent then
		return
	end

	local snap = buildSummary(entry)
	local prefix = DamageConfig.Telemetry.AttributePrefix
	root:SetAttribute(`{prefix}TotalPieces`, snap.TotalPieces)
	root:SetAttribute(`{prefix}HealthyCount`, snap.HealthyCount)
	root:SetAttribute(`{prefix}DamagedCount`, snap.DamagedCount)
	root:SetAttribute(`{prefix}DisabledCount`, snap.DisabledCount)
	root:SetAttribute(`{prefix}TotalMaxHealth`, snap.TotalMaxHealth)
	root:SetAttribute(`{prefix}TotalCurrentHealth`, snap.TotalCurrentHealth)
	root:SetAttribute(`{prefix}StructuralIntegrity`, math.round(snap.IntegrityRatio * 10000) / 10000)
	root:SetAttribute(`{prefix}StructuralIntegrityPct`, snap.IntegrityPercent)
	root:SetAttribute(`{prefix}TotalDamageReceived`, snap.TotalDamageReceived)
	root:SetAttribute(`{prefix}ImpactCount`, snap.ImpactCount)
	root:SetAttribute(`{prefix}LastImpactSpeed`, math.round((snap.LastImpactSpeed or 0) * 100) / 100)
	root:SetAttribute(`{prefix}LastImpactMagnitude`, math.round((snap.LastImpactMagnitude or 0) * 100) / 100)
	root:SetAttribute(`{prefix}LastImpactPieceId`, snap.LastImpactPieceId or "")
	root:SetAttribute(`{prefix}DebugEnabled`, _devDebugMode)

	entry.LastTelemetrySyncWallAt = os.clock()
	entry.TelemetryDirty = false
end

local function markTelemetryDirtyAndSync(entry: InternalVehicleDamageEntry, forceImmediate: boolean?)
	if entry.Destroyed then
		return
	end
	entry.TelemetryDirty = true
	local nowWall = os.clock()
	local minInterval = DamageConfig.Telemetry.MinReplicationIntervalSeconds
	if forceImmediate or (nowWall - entry.LastTelemetrySyncWallAt) >= minInterval then
		writeRootTelemetryAttributes(entry)
		return
	end

	if not entry.FlushScheduled then
		entry.FlushScheduled = true
		task.delay(minInterval, function()
			entry.FlushScheduled = false
			if not entry.Destroyed and entry.TelemetryDirty then
				writeRootTelemetryAttributes(entry)
			end
		end)
	end
end

local function adjustStateCounter(entry: InternalVehicleDamageEntry, state: VehicleTypes.PieceHealthState, delta: number)
	if state == DamageConfig.PieceStates.Healthy then
		entry.HealthyCount = math.max(0, entry.HealthyCount + delta)
	elseif state == DamageConfig.PieceStates.Damaged then
		entry.DamagedCount = math.max(0, entry.DamagedCount + delta)
	else
		entry.DisabledCount = math.max(0, entry.DisabledCount + delta)
	end
end

local function resolveInitialPieceProfile(partState: VehicleTypes.RuntimePartState): (string, number, number, number, number, string)
	local def = ItemRegistry.TryGet(partState.ItemId)
	local category = if partState.Category and partState.Category ~= ""
		then partState.Category
		elseif def then def.Category
		else "Other"
	local catProfile = DamageConfig.GetCategoryProfile(category)

	local durability = if isFinitePositive(partState.Durability)
		then partState.Durability :: number
		elseif isFinitePositive(partState.MaxDurability) then partState.MaxDurability
		elseif def and isFinitePositive(def.Stats.MaxDurability) then def.Stats.MaxDurability
		else catProfile.DefaultDurability

	local maxHealth = if isFinitePositive(partState.MaxHealth)
		then partState.MaxHealth :: number
		else durability

	local impactResistance = if isFinitePositive(partState.ImpactResistance)
		then math.max(0.1, partState.ImpactResistance :: number)
		elseif def and def.Stats and isFinitePositive(def.Stats.ImpactResistance) then math.max(0.1, def.Stats.ImpactResistance :: number)
		else catProfile.ImpactResistance

	local damageMultiplier = if partState.DamageMultiplier ~= nil and DamageMath.IsFiniteNumber(partState.DamageMultiplier)
		then math.max(0, partState.DamageMultiplier :: number)
		elseif def and def.Stats and def.Stats.DamageMultiplier ~= nil and DamageMath.IsFiniteNumber(def.Stats.DamageMultiplier) then math.max(0, def.Stats.DamageMultiplier :: number)
		else catProfile.DamageMultiplier

	local balanceTag = if def then "CatalogBase_ResistanceProvisional_TBD" else "Provisional_TBD"
	return category, maxHealth, durability, impactResistance, damageMultiplier, balanceTag
end

local function makeEmptyImpactResult(runtimeId: string?, pieceId: string, reason: string): VehicleTypes.DamageImpactResult
	return {
		Applied = false,
		Reason = reason,
		RuntimeId = runtimeId,
		PrimaryPieceId = pieceId,
		TotalDamageApplied = 0,
		PrimaryDamageApplied = 0,
		NewDurability = 0,
		NewHealth = 0,
		MaxHealth = 0,
		PrimaryState = DamageConfig.PieceStates.Healthy :: VehicleTypes.PieceHealthState,
		AffectedPieceIds = {},
		DamageByPieceId = {},
		BrokenParts = {},
		DetachedParts = {},
	}
end

local function emitDamageChanged(
	entry: InternalVehicleDamageEntry,
	result: VehicleTypes.DamageImpactResult
)
	if #_damageListeners == 0 then
		return
	end
	local summary = buildSummary(entry)
	for _, fn in ipairs(table.clone(_damageListeners)) do
		fn(entry.RuntimeId, entry.OwnerUserId, result, summary)
	end
end

--[=[
	Inicializa el registro de salud individual para todas las piezas físicas del VehicleRuntime.
]=]
function VehicleDamageService.RegisterRuntime(runtime: VehicleTypes.VehicleRuntime)
	if not _initialized then
		VehicleDamageService.Init()
	end

	-- Evitar residuos si existía registro anterior del mismo RuntimeId o propietario
	if _entriesByRuntimeId[runtime.RuntimeId] then
		VehicleDamageService.UnregisterRuntime(runtime.RuntimeId)
	end
	if _entriesByUserId[runtime.OwnerUserId] then
		VehicleDamageService.UnregisterRuntime(_entriesByUserId[runtime.OwnerUserId].RuntimeId)
	end

	local piecesById: { [string]: InternalPieceEntry } = {}
	local orderedIds: { string } = {}
	local healthyCount = 0
	local damagedCount = 0
	local disabledCount = 0
	local totalMaxHealth = 0
	local totalCurrentHealth = 0
	local totalPieces = 0

	for pieceId, partState in pairs(runtime.Parts) do
		local category, maxHp, durability, impactRes, dmgMult, balanceTag = resolveInitialPieceProfile(partState)
		local curHp = maxHp
		local initialState = DamageMath.ResolveHealthState(curHp, maxHp)
		local ratio = if maxHp > 0 then curHp / maxHp else 1.0

		partState.PieceId = pieceId
		partState.Category = category
		partState.MaxHealth = maxHp
		partState.CurrentHealth = curHp
		partState.Durability = durability
		partState.ImpactResistance = impactRes
		partState.DamageMultiplier = dmgMult
		partState.HealthState = initialState
		partState.DamageReceivedTotal = 0
		partState.ImpactCount = 0
		partState.LastImpactAt = nil
		partState.LastImpactRelativeSpeed = nil
		partState.LastImpactMagnitude = nil

		local record: VehicleTypes.PieceDamageRecord = {
			PieceId = pieceId,
			PieceInstanceId = partState.PieceInstanceId,
			ItemId = partState.ItemId,
			Category = category,
			MaxHealth = maxHp,
			CurrentHealth = curHp,
			Durability = durability,
			ImpactResistance = impactRes,
			DamageMultiplier = dmgMult,
			IntegrityRatio = ratio,
			IntegrityPercent = math.round(ratio * 10000) / 100,
			State = initialState,
			DamageReceivedTotal = 0,
			ImpactCount = 0,
			LastImpactAt = nil,
			LastImpactRelativeSpeed = nil,
			LastImpactMagnitude = nil,
			BalanceStatus = balanceTag,
		}

		local pEntry: InternalPieceEntry = {
			Record = record,
			PartState = partState,
			ModelInstance = partState.ModelInstance,
			PrimaryPart = partState.PrimaryPart,
		}
		piecesById[pieceId] = pEntry
		table.insert(orderedIds, pieceId)

		totalPieces += 1
		totalMaxHealth += maxHp
		totalCurrentHealth += curHp
		if initialState == DamageConfig.PieceStates.Healthy then
			healthyCount += 1
		elseif initialState == DamageConfig.PieceStates.Damaged then
			damagedCount += 1
		else
			disabledCount += 1
		end

		if DamageConfig.Debug.WritePieceDebugAttributesOnRegister then
			writePieceDebugAttributes(pEntry, nil, nil)
		end
	end

	table.sort(orderedIds)

	local adjacencyCopy: { [string]: { string } } = {}
	if runtime.PieceAdjacencyById then
		for pid, list in pairs(runtime.PieceAdjacencyById) do
			adjacencyCopy[pid] = table.clone(list)
		end
	end

	local entry: InternalVehicleDamageEntry = {
		RuntimeId = runtime.RuntimeId,
		OwnerUserId = runtime.OwnerUserId,
		Runtime = runtime,
		PiecesById = piecesById,
		OrderedPieceIds = orderedIds,
		AdjacencyById = adjacencyCopy,
		TotalPieces = totalPieces,
		HealthyCount = healthyCount,
		DamagedCount = damagedCount,
		DisabledCount = disabledCount,
		TotalMaxHealth = totalMaxHealth,
		TotalCurrentHealth = totalCurrentHealth,
		TotalDamageReceived = 0,
		ImpactCount = 0,
		LastImpactAt = nil,
		LastImpactSpeed = nil,
		LastImpactMagnitude = nil,
		LastImpactPieceId = nil,
		DebugHistory = {},
		LastTelemetrySyncWallAt = 0,
		TelemetryDirty = false,
		FlushScheduled = false,
		Destroyed = false,
	}

	_entriesByRuntimeId[runtime.RuntimeId] = entry
	_entriesByUserId[runtime.OwnerUserId] = entry

	writeRootTelemetryAttributes(entry)
end

--[=[
	Limpia completamente todos los registros de salud e historial cuando se destruye el VehicleRuntime.
]=]
function VehicleDamageService.UnregisterRuntime(runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number): boolean
	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry then
		return false
	end

	entry.Destroyed = true
	if _entriesByRuntimeId[entry.RuntimeId] == entry then
		_entriesByRuntimeId[entry.RuntimeId] = nil
	end
	if _entriesByUserId[entry.OwnerUserId] == entry then
		_entriesByUserId[entry.OwnerUserId] = nil
	end
	table.clear(entry.PiecesById)
	table.clear(entry.OrderedPieceIds)
	table.clear(entry.AdjacencyById)
	table.clear(entry.DebugHistory)
	return true
end

--[=[
	Contrato compatible SDD (`docs/03-ARCHITECTURE.md`): DamageService.ApplyImpact(runtimeId, partInstanceId, impact)
	Evalúa el plan de distribución localizada del impacto y actualiza únicamente el estado temporal del runtime.
]=]
function VehicleDamageService.ApplyImpact(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number,
	partInstanceId: string,
	impact: VehicleTypes.DamageImpactContext | number
): VehicleTypes.DamageImpactResult
	if not _initialized then
		VehicleDamageService.Init()
	end

	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry or entry.Destroyed then
		return makeEmptyImpactResult(
			if type(runtimeOrIdOrUser) == "string" then runtimeOrIdOrUser else nil,
			partInstanceId,
			"RuntimeNotRegistered"
		)
	end

	local primaryEntry = entry.PiecesById[partInstanceId]
	if not primaryEntry or primaryEntry.PartState.IsDetached then
		return makeEmptyImpactResult(entry.RuntimeId, partInstanceId, "PieceNotFoundInRuntime")
	end

	local ctx: VehicleTypes.DamageImpactContext = if type(impact) == "number"
		then {
			DamageAmount = impact,
			SourceType = "API",
		}
		elseif type(impact) == "table" then impact
		else {
			DamageAmount = 0,
			SourceType = "API",
		}

	local rawDamage = ctx.DamageAmount
	if not isFinitePositive(rawDamage) then
		local out = makeEmptyImpactResult(entry.RuntimeId, partInstanceId, "InvalidOrZeroDamage")
		out.NewDurability = primaryEntry.Record.CurrentHealth
		out.NewHealth = primaryEntry.Record.CurrentHealth
		out.MaxHealth = primaryEntry.Record.MaxHealth
		out.PrimaryState = primaryEntry.Record.State
		return out
	end

	local adjacentNodes: { DamageMath.NeighborGeometryNode } = {}
	local neighborIds = (entry.Runtime.PieceAdjacencyById or entry.AdjacencyById)[partInstanceId]
	if neighborIds then
		for _, nid in ipairs(neighborIds) do
			local nbEntry = entry.PiecesById[nid]
			if nbEntry then
				local nbPos: Vector3? = if nbEntry.PrimaryPart and nbEntry.PrimaryPart.Parent
					then nbEntry.PrimaryPart.Position
					else nil
				table.insert(adjacentNodes, {
					PieceId = nid,
					Position = nbPos,
				})
			end
		end
	end

	local primaryPos: Vector3? = if primaryEntry.PrimaryPart and primaryEntry.PrimaryPart.Parent
		then primaryEntry.PrimaryPart.Position
		else nil

	local targets = DamageMath.ComputeDistributionPlan({
		PrimaryPieceId = partInstanceId,
		PrimaryPosition = primaryPos,
		ImpactPosition = ctx.ImpactPosition or primaryPos,
		AdjacentNeighbors = adjacentNodes,
		AllowNeighborTransfer = ctx.SkipDistribution ~= true,
	})

	local ts = if ctx.Timestamp ~= nil and DamageMath.IsFiniteNumber(ctx.Timestamp) then ctx.Timestamp :: number else nowSeconds()
	local totalDamageApplied = 0
	local primaryDamageApplied = 0
	local affectedPieceIds: { string } = {}
	local damageByPieceId: { [string]: number } = {}
	local brokenParts: { string } = {}
	local stateTransitionOccurred = false

	for _, target in ipairs(targets) do
		local tEntry = entry.PiecesById[target.PieceId]
		if tEntry then
			local rec = tEntry.Record
			local pieceDamage = DamageMath.ComputePieceDamage(rawDamage :: number, {
				ImpactResistance = rec.ImpactResistance,
				DamageMultiplier = rec.DamageMultiplier,
			}, target.Weight)

			local minPieceFloor = if target.IsPrimaryTarget then 0 else DamageConfig.Distribution.MinDistributedPieceDamage
			if pieceDamage > 0 and pieceDamage >= minPieceFloor and rec.CurrentHealth > 0 then
				local prevHealth = rec.CurrentHealth
				local prevState = rec.State
				local nextHealth = math.clamp(prevHealth - pieceDamage, 0, rec.MaxHealth)
				local actualDelta = math.max(0, prevHealth - nextHealth)

				if actualDelta > 0 then
					local nextState = DamageMath.ResolveHealthState(nextHealth, rec.MaxHealth)
					if nextState ~= prevState then
						stateTransitionOccurred = true
						adjustStateCounter(entry, prevState, -1)
						adjustStateCounter(entry, nextState, 1)
					end

					rec.CurrentHealth = nextHealth
					rec.State = nextState
					rec.IntegrityRatio = if rec.MaxHealth > 0 then nextHealth / rec.MaxHealth else 0
					rec.IntegrityPercent = math.round(rec.IntegrityRatio * 10000) / 100
					rec.DamageReceivedTotal += actualDelta
					rec.ImpactCount += 1
					rec.LastImpactAt = ts
					rec.LastImpactRelativeSpeed = ctx.RelativeSpeed
					rec.LastImpactMagnitude = ctx.ImpactMagnitude or actualDelta

					-- Fase 4.1: sincronizar solo campos de salud en RuntimePartState; NO tocar CurrentDurability ni IsFunctional (Fase 4.3).
					tEntry.PartState.CurrentHealth = nextHealth
					tEntry.PartState.HealthState = nextState
					tEntry.PartState.DamageReceivedTotal = rec.DamageReceivedTotal
					tEntry.PartState.ImpactCount = rec.ImpactCount
					tEntry.PartState.LastImpactAt = ts
					tEntry.PartState.LastImpactRelativeSpeed = ctx.RelativeSpeed
					tEntry.PartState.LastImpactMagnitude = rec.LastImpactMagnitude

					entry.TotalCurrentHealth = math.clamp(entry.TotalCurrentHealth - actualDelta, 0, entry.TotalMaxHealth)
					entry.TotalDamageReceived += actualDelta
					totalDamageApplied += actualDelta
					damageByPieceId[target.PieceId] = actualDelta
					table.insert(affectedPieceIds, target.PieceId)

					if target.IsPrimaryTarget then
						primaryDamageApplied = actualDelta
					end
					if nextState == DamageConfig.PieceStates.Disabled then
						table.insert(brokenParts, target.PieceId)
					end

					writePieceDebugAttributes(tEntry, ctx.RelativeSpeed, rec.LastImpactMagnitude)
				end
			end
		end
	end

	if totalDamageApplied <= 0 then
		local out = makeEmptyImpactResult(entry.RuntimeId, partInstanceId, "ZeroEffectiveDamageApplied")
		out.NewDurability = primaryEntry.Record.CurrentHealth
		out.NewHealth = primaryEntry.Record.CurrentHealth
		out.MaxHealth = primaryEntry.Record.MaxHealth
		out.PrimaryState = primaryEntry.Record.State
		return out
	end

	entry.ImpactCount += 1
	entry.LastImpactAt = ts
	entry.LastImpactSpeed = ctx.RelativeSpeed or 0
	entry.LastImpactMagnitude = ctx.ImpactMagnitude or totalDamageApplied
	entry.LastImpactPieceId = partInstanceId

	if _devDebugMode then
		local history = entry.DebugHistory
		table.insert(history, {
			Timestamp = ts,
			PieceId = partInstanceId,
			ItemId = primaryEntry.Record.ItemId,
			OtherName = ctx.OtherName or (ctx.SourceType or "Unknown"),
			SourceType = ctx.SourceType or "Impact",
			RelativeSpeed = ctx.RelativeSpeed or 0,
			NormalSpeed = ctx.NormalSpeed or (ctx.RelativeSpeed or 0),
			EffectiveMass = ctx.EffectiveMass or 0,
			EstimatedImpulse = ctx.EstimatedImpulse or 0,
			EstimatedEnergy = ctx.EstimatedEnergy or 0,
			ImpactMagnitude = entry.LastImpactMagnitude or 0,
			TotalDamageApplied = math.round(totalDamageApplied * 1000) / 1000,
			PrimaryDamageApplied = math.round(primaryDamageApplied * 1000) / 1000,
			PrimaryHealthAfter = primaryEntry.Record.CurrentHealth,
			PrimaryMaxHealth = primaryEntry.Record.MaxHealth,
			AffectedCount = #affectedPieceIds,
		})
		local maxHist = DamageConfig.Debug.MaxImpactHistoryPerRuntime
		while #history > maxHist do
			table.remove(history, 1)
		end
	end

	markTelemetryDirtyAndSync(entry, stateTransitionOccurred)

	local result: VehicleTypes.DamageImpactResult = {
		Applied = true,
		Reason = ctx.Reason,
		RuntimeId = entry.RuntimeId,
		PrimaryPieceId = partInstanceId,
		TotalDamageApplied = math.round(totalDamageApplied * 1000) / 1000,
		PrimaryDamageApplied = math.round(primaryDamageApplied * 1000) / 1000,
		NewDurability = primaryEntry.Record.CurrentHealth,
		NewHealth = primaryEntry.Record.CurrentHealth,
		MaxHealth = primaryEntry.Record.MaxHealth,
		PrimaryState = primaryEntry.Record.State,
		AffectedPieceIds = affectedPieceIds,
		DamageByPieceId = damageByPieceId,
		BrokenParts = brokenParts,
		DetachedParts = {}, -- completado por VehicleDestructionService
	}

	VehicleDestructionService.ProcessImpact(entry.Runtime, result)
	emitDamageChanged(entry, result)
	return result
end

--[=[
	Alias explícito de servidor para aplicar daño autorizado directo sobre una pieza.
]=]
function VehicleDamageService.ApplyDamage(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number,
	pieceId: string,
	rawDamage: number,
	context: VehicleTypes.DamageImpactContext?
): VehicleTypes.DamageImpactResult
	local merged: VehicleTypes.DamageImpactContext = if context then table.clone(context) else {}
	merged.DamageAmount = rawDamage
	return VehicleDamageService.ApplyImpact(runtimeOrIdOrUser, pieceId, merged)
end

function VehicleDamageService.GetPieceHealth(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number,
	pieceId: string
): VehicleTypes.PieceDamageRecord?
	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry or entry.Destroyed then
		return nil
	end
	local pEntry = entry.PiecesById[pieceId]
	if not pEntry then
		return nil
	end
	return clonePieceRecord(pEntry.Record)
end

function VehicleDamageService.GetPieceMaxHealth(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number,
	pieceId: string
): number?
	local rec = VehicleDamageService.GetPieceHealth(runtimeOrIdOrUser, pieceId)
	return if rec then rec.MaxHealth else nil
end

function VehicleDamageService.GetPieceIntegrityPercent(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number,
	pieceId: string
): number?
	local rec = VehicleDamageService.GetPieceHealth(runtimeOrIdOrUser, pieceId)
	return if rec then rec.IntegrityPercent else nil
end

function VehicleDamageService.GetAllPieceHealthStates(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number
): { [string]: VehicleTypes.PieceDamageRecord }
	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry or entry.Destroyed then
		return {}
	end
	local out: { [string]: VehicleTypes.PieceDamageRecord } = {}
	for pid, pEntry in pairs(entry.PiecesById) do
		out[pid] = clonePieceRecord(pEntry.Record)
	end
	return out
end

function VehicleDamageService.GetDamagedPieceCount(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number
): number
	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry or entry.Destroyed then
		return 0
	end
	return entry.DamagedCount
end

function VehicleDamageService.GetDisabledPieceCount(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number
): number
	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry or entry.Destroyed then
		return 0
	end
	return entry.DisabledCount
end

function VehicleDamageService.GetVehicleHealthSummary(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number
): VehicleTypes.VehicleHealthSummary?
	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry or entry.Destroyed then
		return nil
	end
	return buildSummary(entry)
end

function VehicleDamageService.GetVehicleIntegrityPercent(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number
): number?
	local summary = VehicleDamageService.GetVehicleHealthSummary(runtimeOrIdOrUser)
	return if summary then summary.IntegrityPercent else nil
end

--[=[
	Herramientas de depuración y pruebas exclusivas de desarrollo / servidor autorizado.
]=]
function VehicleDamageService.SetDevDebugMode(enabled: boolean)
	_devDebugMode = enabled == true
	for _, entry in pairs(_entriesByRuntimeId) do
		if not entry.Destroyed then
			writeRootTelemetryAttributes(entry)
			if _devDebugMode then
				for _, pEntry in pairs(entry.PiecesById) do
					writePieceDebugAttributes(pEntry, pEntry.Record.LastImpactRelativeSpeed, pEntry.Record.LastImpactMagnitude)
				end
			end
		end
	end
end

function VehicleDamageService.IsDevDebugMode(): boolean
	return _devDebugMode
end

function VehicleDamageService.SetDevAuthorizedUserIds(userIds: { number }, allowStudioAllDevs: boolean?)
	table.clear(_authorizedDevUserIds)
	for _, uid in ipairs(userIds) do
		if type(uid) == "number" then
			_authorizedDevUserIds[uid] = true
		end
	end
	if allowStudioAllDevs ~= nil then
		_allowAllStudioDevs = allowStudioAllDevs
	end
end

function VehicleDamageService.IsDevAuthorized(executor: ({ UserId: number } | number | nil)): boolean
	if not _devDebugMode then
		return false
	end
	if executor == nil then
		-- Llamada directa desde código servidor / tests de servidor
		return true
	end
	local uid: number? = if type(executor) == "number"
		then executor
		elseif (type(executor) == "table" or typeof(executor) == "Instance") and type((executor :: any).UserId) == "number"
			then (executor :: any).UserId
		else nil
	if uid == nil then
		return false
	end
	if _authorizedDevUserIds[uid] then
		return true
	end
	if RunService:IsStudio() and _allowAllStudioDevs then
		local realPlayer = Players:GetPlayerByUserId(uid)
		-- En Studio solo permitir al jugador local cuando el modo Studio dev abierto está habilitado;
		-- los mocks de jugadores normales en pruebas con `_allowAllStudioDevs = false` quedan denegados.
		if realPlayer ~= nil and realPlayer:IsDescendantOf(Players) then
			return true
		end
	end
	return false
end

function VehicleDamageService.ApplyTestDamage(
	executor: ({ UserId: number } | number | nil),
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number,
	pieceId: string,
	damageAmount: number,
	reason: string?
): VehicleTypes.DamageImpactResult
	if not VehicleDamageService.IsDevAuthorized(executor) then
		return makeEmptyImpactResult(
			if type(runtimeOrIdOrUser) == "string" then runtimeOrIdOrUser else nil,
			pieceId,
			"UnauthorizedDevTool"
		)
	end
	return VehicleDamageService.ApplyImpact(runtimeOrIdOrUser, pieceId, {
		SourceType = "DevTest",
		OtherName = "ServerDevTool",
		DamageAmount = damageAmount,
		SkipDistribution = false,
		Reason = reason or "AuthorizedDevTestDamage",
		RelativeSpeed = 0,
		ImpactMagnitude = damageAmount,
	})
end

function VehicleDamageService.GetRecentImpacts(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number
): { VehicleTypes.DebugImpactRecord }
	if not _devDebugMode then
		return {}
	end
	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry or entry.Destroyed then
		return {}
	end
	return table.clone(entry.DebugHistory)
end

function VehicleDamageService.GetDebugReport(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number
): { Summary: VehicleTypes.VehicleHealthSummary, Pieces: { VehicleTypes.PieceDamageRecord }, RecentImpacts: { VehicleTypes.DebugImpactRecord } }?
	if not _devDebugMode then
		return nil
	end
	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry or entry.Destroyed then
		return nil
	end
	local pieces: { VehicleTypes.PieceDamageRecord } = table.create(#entry.OrderedPieceIds)
	for i, pid in ipairs(entry.OrderedPieceIds) do
		local pEntry = entry.PiecesById[pid]
		if pEntry then
			pieces[i] = clonePieceRecord(pEntry.Record)
		end
	end
	return {
		Summary = buildSummary(entry),
		Pieces = pieces,
		RecentImpacts = table.clone(entry.DebugHistory),
	}
end

function VehicleDamageService.GetRegisteredRuntimeCount(): number
	local count = 0
	for _ in pairs(_entriesByRuntimeId) do
		count += 1
	end
	return count
end

function VehicleDamageService.OnDamageChanged(listener: DamageChangedListener): () -> ()
	table.insert(_damageListeners, listener)
	return function()
		local idx = table.find(_damageListeners, listener)
		if idx then
			table.remove(_damageListeners, idx)
		end
	end
end

function VehicleDamageService._SetClockForTests(fn: (() -> number)?)
	_clockFn = fn or os.clock
end

function VehicleDamageService.Init()
	if _initialized then
		return
	end
	ItemRegistry.Init()
	_initialized = true
end

function VehicleDamageService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehicleDamageService.Init()
	end
	_started = true
end

function VehicleDamageService._ResetForTests()
	for runtimeId in pairs(table.clone(_entriesByRuntimeId)) do
		VehicleDamageService.UnregisterRuntime(runtimeId)
	end
	table.clear(_entriesByRuntimeId)
	table.clear(_entriesByUserId)
	table.clear(_damageListeners)
	table.clear(_authorizedDevUserIds)
	_devDebugMode = RunService:IsStudio() and DamageConfig.Debug.DefaultEnabledInStudio
	_allowAllStudioDevs = RunService:IsStudio()
	_clockFn = os.clock
	_initialized = false
	_started = false
end

return VehicleDamageService

