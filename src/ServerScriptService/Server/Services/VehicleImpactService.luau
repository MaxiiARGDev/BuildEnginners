--!strict
--[=[
	VehicleImpactService
	Orquestador centralizado de detección física de colisiones en servidor (Fase 4.1).
	Zero scripts individuales por pieza: gestiona conexiones Touched por BasePart físico colisionable
	y calcula velocidad relativa real, normal de contacto, masa efectiva y deduplicación temporal
	antes de delegar la aplicación del daño a VehicleDamageService.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local DamageConfig = require(ReplicatedStorage.Shared.Config.DamageConfig)
local DamageMath = require(ReplicatedStorage.Shared.Damage.DamageMath)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local VehicleDamageService = require(ServerScriptService.Server.Services.VehicleDamageService)

export type SyntheticImpactInput = {
	PieceId: string,
	StruckPart: BasePart?,
	OtherPart: BasePart?,
	SourceType: ("Impact" | "Terrain" | "StaticObstacle" | "DynamicObject" | "VehicleRuntime")?,
	OtherName: string?,
	OtherTargetKey: string?,
	OtherVehicleRuntimeId: string?,
	OtherUserId: number?,
	OtherPieceId: string?,
	OtherIsStatic: boolean?,
	OtherMass: number?,
	StruckMass: number?,
	RelativeVelocity: Vector3,
	ImpactNormal: Vector3?,
	ImpactPosition: Vector3?,
	Timestamp: number?,
	BypassGracePeriod: boolean?,
}

export type EvaluatedImpactOutcome = {
	Triggered: boolean,
	RejectReason: string?,
	Kinematics: DamageMath.ImpactKinematicsResult?,
	DamageResult: VehicleTypes.DamageImpactResult?,
}

type BurstWindowState = {
	WindowStartAt: number,
	Count: number,
}

type ImpactVehicleEntry = {
	RuntimeId: string,
	OwnerUserId: number,
	Runtime: VehicleTypes.VehicleRuntime,
	RootModel: Model,
	RootPart: BasePart?,
	ActivatedAt: number,
	TotalVehicleMass: number,
	PartToPieceId: { [BasePart]: string },
	Connections: { RBXScriptConnection },
	PiecePairCooldowns: { [string]: number },
	BurstByOtherKey: { [string]: BurstWindowState },
	TerrainRayParams: RaycastParams,
	CurrLinearVel: Vector3,
	CurrAngularVel: Vector3,
	CurrCenterOfMass: Vector3,
	CurrCapturedAt: number,
	PrevLinearVel: Vector3,
	PrevAngularVel: Vector3,
	PrevCenterOfMass: Vector3,
	PrevCapturedAt: number,
	Destroyed: boolean,
}

local VehicleImpactService = {
	Name = "VehicleImpactService",
}

local _entriesByRuntimeId: { [string]: ImpactVehicleEntry } = {}
local _entriesByUserId: { [number]: ImpactVehicleEntry } = {}
local _runtimeByPart: { [BasePart]: ImpactVehicleEntry } = {}
-- Identidad local al servidor, sin APIs restringidas ni referencias fuertes a piezas eliminadas.
local _obstacleKeys: { [BasePart]: string } = setmetatable({}, { __mode = "k" })
local _nextObstacleId = 0

local function getObstacleKey(part: BasePart): string
	local key = _obstacleKeys[part]
	if key == nil then
		_nextObstacleId += 1
		key = `obstacle:{_nextObstacleId}`
		_obstacleKeys[part] = key
	end
	return key
end

local _clockFn: () -> number = os.clock
local _preSimConn: RBXScriptConnection? = nil
local _initialized = false
local _started = false

local PRE_STEP_VELOCITY_MAX_AGE_SECONDS = 0.08
local MIN_SOLVER_IMPULSE_DELTA_V = 2.0

local function resolveEntryRootPart(entry: ImpactVehicleEntry): BasePart?
	local seatPart = entry.Runtime.DriverSeatPart
	if seatPart and seatPart.Parent then
		entry.RootPart = seatPart
		return seatPart
	end
	local primary = entry.RootModel.PrimaryPart
	if primary and primary.Parent then
		entry.RootPart = primary
		return primary
	end
	if entry.RootPart and entry.RootPart.Parent then
		return entry.RootPart
	end
	for part in pairs(entry.PartToPieceId) do
		if part.Parent then
			local rp = part:GetRootPart() or part
			entry.RootPart = rp
			return rp
		end
	end
	entry.RootPart = nil
	return nil
end

local function captureEntryVelocitySnapshot(entry: ImpactVehicleEntry, nowWall: number)
	local rp = resolveEntryRootPart(entry)
	if not rp then
		return
	end
	local lin = rp.AssemblyLinearVelocity
	local ang = rp.AssemblyAngularVelocity
	local com = rp.AssemblyCenterOfMass
	if not (DamageMath.IsFiniteVector3(lin) and DamageMath.IsFiniteVector3(ang) and DamageMath.IsFiniteVector3(com)) then
		return
	end

	entry.PrevLinearVel = entry.CurrLinearVel
	entry.PrevAngularVel = entry.CurrAngularVel
	entry.PrevCenterOfMass = entry.CurrCenterOfMass
	entry.PrevCapturedAt = entry.CurrCapturedAt

	entry.CurrLinearVel = lin
	entry.CurrAngularVel = ang
	entry.CurrCenterOfMass = com
	entry.CurrCapturedAt = nowWall
end

local function resolvePointVelocityFromSnapshot(
	entry: ImpactVehicleEntry,
	worldPoint: Vector3,
	nowWall: number,
	usePrev: boolean
): Vector3?
	local capturedAt = if usePrev then entry.PrevCapturedAt else entry.CurrCapturedAt
	if capturedAt <= 0 or (nowWall - capturedAt) > PRE_STEP_VELOCITY_MAX_AGE_SECONDS then
		return nil
	end
	local lin = if usePrev then entry.PrevLinearVel else entry.CurrLinearVel
	local ang = if usePrev then entry.PrevAngularVel else entry.CurrAngularVel
	local com = if usePrev then entry.PrevCenterOfMass else entry.CurrCenterOfMass
	local vel = lin + ang:Cross(worldPoint - com)
	if DamageMath.IsFiniteVector3(vel) then
		return vel
	end
	return nil
end

local function syncPreSimulationConnection()
	if next(_entriesByRuntimeId) ~= nil and RunService:IsRunning() then
		if _preSimConn == nil or not _preSimConn.Connected then
			_preSimConn = RunService.PreSimulation:Connect(function()
				local nowWall = os.clock()
				for _, entry in pairs(_entriesByRuntimeId) do
					if not entry.Destroyed then
						captureEntryVelocitySnapshot(entry, nowWall)
					end
				end
			end)
		end
	elseif _preSimConn then
		if _preSimConn.Connected then
			_preSimConn:Disconnect()
		end
		_preSimConn = nil
	end
end

local function nowSeconds(): number
	return _clockFn()
end

local function isCollidablePhysicalPart(part: BasePart): boolean
	if not part.CanCollide or not part.CanTouch then
		return false
	end
	local role = part:GetAttribute("PartPhysicsRole")
	if role == GameConfig.Runtime.PartRoles.SuspensionCarrier or role == GameConfig.Runtime.PartRoles.SteeringPivot then
		return false
	end
	return true
end

local function computeVehicleMassSnapshot(rootModel: Model): number
	local total = 0
	for _, desc in ipairs(rootModel:GetDescendants()) do
		if desc:IsA("BasePart") and not desc.Massless then
			total += desc:GetMass()
		end
	end
	return math.max(5.0, total)
end

local function resolveEntry(runtimeOrIdOrUser: (VehicleTypes.VehicleRuntime | { UserId: number } | string | number)?): ImpactVehicleEntry?
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

local function isCharacterBodyPart(instance: BasePart): boolean
	local parent = instance.Parent
	if parent and parent:IsA("Model") then
		if parent:FindFirstChildOfClass("Humanoid") ~= nil then
			return true
		end
		if Players:GetPlayerFromCharacter(parent) ~= nil then
			return true
		end
	elseif parent and parent:IsA("Accessory") then
		return true
	end
	return false
end

local function safeVelocityAtPoint(part: BasePart, worldPos: Vector3): Vector3
	local ok, vel = pcall(function()
		return part:GetVelocityAtPosition(worldPos)
	end)
	if ok and DamageMath.IsFiniteVector3(vel) then
		return vel
	end
	local lin = part.AssemblyLinearVelocity
	return if DamageMath.IsFiniteVector3(lin) then lin else Vector3.zero
end

local function pruneStalePairEntries(entry: ImpactVehicleEntry, now: number)
	local staleWindow = DamageConfig.Deduplication.StaleEntryPruneSeconds
	for key, ts in pairs(entry.PiecePairCooldowns) do
		if (now - ts) > staleWindow then
			entry.PiecePairCooldowns[key] = nil
		end
	end
	for key, burst in pairs(entry.BurstByOtherKey) do
		if (now - burst.WindowStartAt) > staleWindow then
			entry.BurstByOtherKey[key] = nil
		end
	end
end

local function checkAndCommitDeduplication(
	entry: ImpactVehicleEntry,
	pieceId: string,
	otherTargetKey: string,
	otherVehicleRuntimeId: string?,
	now: number
): (boolean, string?)
	local dedup = DamageConfig.Deduplication

	-- 1. Cooldown estricto por par (PieceId, OtherTargetKey) para evitar spam de Touched en el mismo contacto/rebote
	local piecePairKey = `{pieceId}|{otherTargetKey}`
	local prevPieceAt = entry.PiecePairCooldowns[piecePairKey]
	if prevPieceAt and (now - prevPieceAt) < dedup.PieceOtherPairCooldownSeconds then
		return false, "PairCooldownActive"
	end

	-- 2. Si el choque es contra otro VehicleRuntime, deduplicar también (PieceId, OtherVehicleRuntimeId)
	local vehiclePairKey: string? = nil
	if otherVehicleRuntimeId and otherVehicleRuntimeId ~= "" then
		vehiclePairKey = `{pieceId}|veh:{otherVehicleRuntimeId}`
		local prevVehAt = entry.PiecePairCooldowns[vehiclePairKey]
		if prevVehAt and (now - prevVehAt) < dedup.VehiclePairCooldownSeconds then
			return false, "VehiclePairCooldownActive"
		end
	end

	-- 3. Protección por ráfaga (p. ej. caída plana de vehículo de 500 piezas tocando el suelo a la vez)
	local burstKey = if otherVehicleRuntimeId and otherVehicleRuntimeId ~= ""
		then `veh:{otherVehicleRuntimeId}`
		else otherTargetKey
	local burst = entry.BurstByOtherKey[burstKey]
	if burst and (now - burst.WindowStartAt) < dedup.VehicleOtherBurstWindowSeconds then
		if burst.Count >= dedup.MaxProcessedHitsPerBurst then
			return false, "BurstCapReached"
		end
	end

	-- Registrar ventana antes de aplicar daño
	entry.PiecePairCooldowns[piecePairKey] = now
	if vehiclePairKey then
		entry.PiecePairCooldowns[vehiclePairKey] = now
	end
	if not burst or (now - burst.WindowStartAt) >= dedup.VehicleOtherBurstWindowSeconds then
		entry.BurstByOtherKey[burstKey] = {
			WindowStartAt = now,
			Count = 1,
		}
	else
		burst.Count += 1
	end

	-- Limpieza ligera ocasional si crece la tabla
	local pairCount = 0
	for _ in pairs(entry.PiecePairCooldowns) do
		pairCount += 1
		if pairCount > 128 then
			pruneStalePairEntries(entry, now)
			break
		end
	end

	return true, nil
end

local function processEvaluatedImpact(entry: ImpactVehicleEntry, params: SyntheticImpactInput): EvaluatedImpactOutcome
	if entry.Destroyed then
		return { Triggered = false, RejectReason = "RuntimeDestroyed" }
	end

	local rt = entry.Runtime
	if rt.Parts[params.PieceId] and rt.Parts[params.PieceId].IsDetached then return { Triggered = false, RejectReason = "DetachedPiece" } end
	if params.OtherPart and params.OtherPart:GetAttribute("VehicleDebris") then return { Triggered = false, RejectReason = "DebrisContact" } end
	if
		rt.State == GameConfig.Runtime.States.Editing
		or rt.State == GameConfig.Runtime.States.PreparingLaunch
		or rt.State == GameConfig.Runtime.States.ReturningToWorkshop
	then
		return { Triggered = false, RejectReason = "InactiveLifecycleState" }
	end

	if params.OtherVehicleRuntimeId ~= nil and params.OtherVehicleRuntimeId == entry.RuntimeId then
		return { Triggered = false, RejectReason = "SelfVehicleCollision" }
	end
	if params.OtherPart and (entry.PartToPieceId[params.OtherPart] ~= nil or params.OtherPart:IsDescendantOf(entry.RootModel)) then
		return { Triggered = false, RejectReason = "SelfVehicleCollision" }
	end

	local ts = if params.Timestamp ~= nil and DamageMath.IsFiniteNumber(params.Timestamp) then params.Timestamp :: number else nowSeconds()
	local struckMass = if params.StruckMass ~= nil and DamageMath.IsFiniteNumber(params.StruckMass)
		then params.StruckMass :: number
		else entry.TotalVehicleMass

	local timeSinceLaunch = if params.BypassGracePeriod then nil else math.max(0, ts - entry.ActivatedAt)

	local kinematics = DamageMath.EvaluateImpactKinematics({
		RelativeVelocity = params.RelativeVelocity,
		ImpactNormal = params.ImpactNormal,
		StruckMass = struckMass,
		OtherMass = params.OtherMass,
		OtherIsStatic = params.OtherIsStatic,
		TimeSinceLaunchSeconds = timeSinceLaunch,
	})

	if not kinematics.PassesThreshold then
		return {
			Triggered = false,
			RejectReason = kinematics.RejectReason or "BelowImpactThreshold",
			Kinematics = kinematics,
		}
	end

	local targetKey = params.OtherTargetKey or params.OtherName or "WorldObstacle"
	local dedupOk, dedupReason = checkAndCommitDeduplication(
		entry,
		params.PieceId,
		targetKey,
		params.OtherVehicleRuntimeId,
		ts
	)
	if not dedupOk then
		return {
			Triggered = false,
			RejectReason = dedupReason,
			Kinematics = kinematics,
		}
	end

	local dmgResult = VehicleDamageService.ApplyImpact(entry.RuntimeId, params.PieceId, {
		SourceType = (params.SourceType or "Impact") :: any,
		OtherName = params.OtherName or targetKey,
		OtherUserId = params.OtherUserId,
		OtherPieceId = params.OtherPieceId,
		ImpactPosition = params.ImpactPosition,
		ImpactNormal = params.ImpactNormal,
		RelativeSpeed = kinematics.RelativeSpeed,
		NormalSpeed = kinematics.NormalSpeed,
		EffectiveMass = kinematics.EffectiveMass,
		EstimatedImpulse = kinematics.EstimatedImpulse,
		EstimatedEnergy = kinematics.EstimatedEnergy,
		ImpactMagnitude = kinematics.ImpactMagnitude,
		DamageAmount = kinematics.RawDamage,
		Timestamp = ts,
		Reason = "PhysicsCollision",
	})

	return {
		Triggered = dmgResult.Applied,
		RejectReason = if dmgResult.Applied then nil else (dmgResult.Reason or "DamageNotApplied"),
		Kinematics = kinematics,
		DamageResult = dmgResult,
	}
end

local function handleRealPartTouched(entry: ImpactVehicleEntry, struckPart: BasePart, pieceId: string, otherPart: BasePart)
	if entry.Destroyed or entry.Runtime.Parts[pieceId].IsDetached or otherPart:GetAttribute("VehicleDebris") then
		return
	end
	if not otherPart or not otherPart.Parent then
		return
	end
	-- Ignorar colisiones dentro del propio vehículo
	if entry.PartToPieceId[otherPart] ~= nil or otherPart:IsDescendantOf(entry.RootModel) then
		return
	end

	local isTerrain = otherPart:IsA("Terrain")
	if not isTerrain then
		if not otherPart.CanCollide then
			return
		end
		if otherPart.CollisionGroup == GameConfig.Runtime.CollisionGroups.EditableVehicle
			or otherPart.CollisionGroup == GameConfig.Runtime.CollisionGroups.EditorGhost
		then
			return
		end
		if isCharacterBodyPart(otherPart) then
			return
		end
	end

	local otherEntry = _runtimeByPart[otherPart]
	local sourceType: "Terrain" | "StaticObstacle" | "DynamicObject" | "VehicleRuntime"
	local otherIsStatic = false
	local otherMass: number? = nil
	local otherName = otherPart.Name
	local otherTargetKey: string
	local otherVehicleId: string? = nil
	local otherUserId: number? = nil
	local otherPieceId: string? = nil

	if otherEntry and not otherEntry.Destroyed and otherEntry ~= entry then
		sourceType = "VehicleRuntime"
		otherIsStatic = false
		otherMass = math.max(5.0, otherEntry.TotalVehicleMass)
		otherVehicleId = otherEntry.RuntimeId
		otherUserId = otherEntry.OwnerUserId
		otherPieceId = otherEntry.PartToPieceId[otherPart]
		otherName = `{otherEntry.RootModel.Name}:{otherPieceId or otherPart.Name}`
		otherTargetKey = `{otherEntry.RuntimeId}|{otherPieceId or otherPart.Name}`
	elseif isTerrain then
		sourceType = "Terrain"
		otherIsStatic = true
		otherName = "Terrain"
		otherTargetKey = "Terrain"
	elseif otherPart.Anchored then
		sourceType = "StaticObstacle"
		otherIsStatic = true
		otherTargetKey = getObstacleKey(otherPart)
	else
		sourceType = "DynamicObject"
		otherIsStatic = false
		otherMass = math.max(1.0, otherPart.AssemblyMass)
		otherTargetKey = getObstacleKey(otherPart)
	end

	local contactPos = struckPart.Position
	local contactNormal: Vector3
	local vOther = Vector3.zero

	if isTerrain then
		local linVel = struckPart.AssemblyLinearVelocity
		local dir = if DamageMath.IsFiniteVector3(linVel) and linVel.Magnitude > 1.0
			then linVel.Unit
			else -Vector3.yAxis
		local rayLen = DamageConfig.Impact.MaxContactRayDistanceStuds
		local hit = Workspace:Raycast(struckPart.Position, dir * rayLen, entry.TerrainRayParams)
		if not hit then
			hit = Workspace:Raycast(struckPart.Position + Vector3.new(0, 1, 0), -Vector3.yAxis * (rayLen + 1), entry.TerrainRayParams)
		end
		if hit then
			contactPos = hit.Position
			contactNormal = hit.Normal
		else
			contactNormal = if DamageMath.IsFiniteVector3(linVel) and linVel.Magnitude > 1e-3
				then -linVel.Unit
				else Vector3.yAxis
		end
	else
		local closest, n = DamageMath.ComputeClosestPointOnBox(otherPart.CFrame, otherPart.Size, struckPart.Position)
		contactPos = closest
		contactNormal = n
		if not otherPart.Anchored then
			vOther = safeVelocityAtPoint(otherPart, contactPos)
		end
	end

	local vPieceNow = safeVelocityAtPoint(struckPart, contactPos)
	local relativeVelocity = vOther - vPieceNow

	-- En Deferred SignalBehavior, Touched suele ejecutarse tras resolver el impulso del paso físico
	-- (pudiendo reflejar velocidad anulada o de rebote). Consultar instantáneas PreSimulation por vehículo.
	local nowWall = os.clock()
	local bestApproach = relativeVelocity:Dot(contactNormal)
	for _, usePrev in ipairs({ false, true }) do
		local vPiecePre = resolvePointVelocityFromSnapshot(entry, contactPos, nowWall, usePrev)
		if vPiecePre then
			local vOtherPre = vOther
			if otherEntry and not otherEntry.Destroyed then
				vOtherPre = resolvePointVelocityFromSnapshot(otherEntry, contactPos, nowWall, usePrev) or vOther
			elseif otherPart.Anchored or isTerrain then
				vOtherPre = Vector3.zero
			end
			local relPre = vOtherPre - vPiecePre
			local approachPre = relPre:Dot(contactNormal)
			if approachPre > bestApproach then
				local impulseDeltaN = (vPieceNow - vPiecePre):Dot(contactNormal)
				local ageSec = if usePrev then (nowWall - entry.PrevCapturedAt) else (nowWall - entry.CurrCapturedAt)
				if (not usePrev and ageSec <= 0.035) or impulseDeltaN >= MIN_SOLVER_IMPULSE_DELTA_V then
					bestApproach = approachPre
					relativeVelocity = relPre
				end
			end
		end
	end

	-- Masa efectiva del impacto (para masa de ensamblaje propio usar AssemblyMass en estructuras rígidas o masa total registrada)
	local pieceRoot = struckPart:GetRootPart() or struckPart
	local selfEffMass = math.max(entry.TotalVehicleMass, if DamageMath.IsFiniteNumber(pieceRoot.AssemblyMass) then pieceRoot.AssemblyMass else 5.0)

	processEvaluatedImpact(entry, {
		PieceId = pieceId,
		StruckPart = struckPart,
		OtherPart = otherPart,
		SourceType = sourceType,
		OtherName = otherName,
		OtherTargetKey = otherTargetKey,
		OtherVehicleRuntimeId = otherVehicleId,
		OtherUserId = otherUserId,
		OtherPieceId = otherPieceId,
		OtherIsStatic = otherIsStatic,
		OtherMass = otherMass,
		StruckMass = selfEffMass,
		RelativeVelocity = relativeVelocity,
		ImpactNormal = contactNormal,
		ImpactPosition = contactPos,
		Timestamp = nowSeconds(),
	})
end

--[=[
	Conecta la detección de colisiones para un VehicleRuntime recién activado.
	Garantiza cero conexiones duplicadas en partes existentes y total limpieza al desmontar.
]=]
function VehicleImpactService.RegisterRuntime(runtime: VehicleTypes.VehicleRuntime)
	if not _initialized then
		VehicleImpactService.Init()
	end

	local rootModel = runtime.RootModel
	if not rootModel then
		return
	end

	if _entriesByRuntimeId[runtime.RuntimeId] then
		VehicleImpactService.UnregisterRuntime(runtime.RuntimeId)
	end
	if _entriesByUserId[runtime.OwnerUserId] then
		VehicleImpactService.UnregisterRuntime(_entriesByUserId[runtime.OwnerUserId].RuntimeId)
	end

	local terrainRayParams = RaycastParams.new()
	terrainRayParams.FilterType = Enum.RaycastFilterType.Include
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		terrainRayParams.FilterDescendantsInstances = { terrain }
	end

	local partToPieceId: { [BasePart]: string } = {}
	local connections: { RBXScriptConnection } = {}

	local entry: ImpactVehicleEntry = {
		RuntimeId = runtime.RuntimeId,
		OwnerUserId = runtime.OwnerUserId,
		Runtime = runtime,
		RootModel = rootModel,
		RootPart = runtime.DriverSeatPart or rootModel.PrimaryPart,
		ActivatedAt = nowSeconds(),
		TotalVehicleMass = computeVehicleMassSnapshot(rootModel),
		PartToPieceId = partToPieceId,
		Connections = connections,
		PiecePairCooldowns = {},
		BurstByOtherKey = {},
		TerrainRayParams = terrainRayParams,
		CurrLinearVel = Vector3.zero,
		CurrAngularVel = Vector3.zero,
		CurrCenterOfMass = Vector3.zero,
		CurrCapturedAt = 0,
		PrevLinearVel = Vector3.zero,
		PrevAngularVel = Vector3.zero,
		PrevCenterOfMass = Vector3.zero,
		PrevCapturedAt = 0,
		Destroyed = false,
	}

	_entriesByRuntimeId[runtime.RuntimeId] = entry
	_entriesByUserId[runtime.OwnerUserId] = entry
	captureEntryVelocitySnapshot(entry, os.clock())
	syncPreSimulationConnection()

	for pieceId, partState in pairs(runtime.Parts) do
		if partState.IsDetached then continue end
		local model = partState.ModelInstance
		if model then
			for _, desc in ipairs(model:GetDescendants()) do
				if desc:IsA("BasePart") and partToPieceId[desc] == nil then
					partToPieceId[desc] = pieceId
					_runtimeByPart[desc] = entry
					if isCollidablePhysicalPart(desc) then
						local conn = desc.Touched:Connect(function(otherPart: BasePart)
							handleRealPartTouched(entry, desc, pieceId, otherPart)
						end)
						table.insert(connections, conn)
					end
				end
			end
		elseif partState.PrimaryPart and partToPieceId[partState.PrimaryPart] == nil then
			local pp = partState.PrimaryPart
			partToPieceId[pp] = pieceId
			_runtimeByPart[pp] = entry
			if isCollidablePhysicalPart(pp) then
				local conn = pp.Touched:Connect(function(otherPart: BasePart)
					handleRealPartTouched(entry, pp, pieceId, otherPart)
				end)
				table.insert(connections, conn)
			end
		end
	end
end

function VehicleImpactService.RefreshRuntime(runtime)
 local previous = _entriesByRuntimeId[runtime.RuntimeId]
 if not previous then return end
 local activated = previous.ActivatedAt
 local cooldowns, bursts = previous.PiecePairCooldowns, previous.BurstByOtherKey
 -- Unregister clears its maps, so preserve the cooldown snapshots.
 cooldowns, bursts = table.clone(cooldowns), table.clone(bursts)
 VehicleImpactService.RegisterRuntime(runtime)
 local current = _entriesByRuntimeId[runtime.RuntimeId]
 current.ActivatedAt = activated
 current.PiecePairCooldowns, current.BurstByOtherKey = cooldowns, bursts
end

function VehicleImpactService.UnregisterRuntime(runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number): boolean
	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry then
		return false
	end

	entry.Destroyed = true
	for _, conn in ipairs(entry.Connections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(entry.Connections)

	for part in pairs(entry.PartToPieceId) do
		if _runtimeByPart[part] == entry then
			_runtimeByPart[part] = nil
		end
	end
	table.clear(entry.PartToPieceId)
	table.clear(entry.PiecePairCooldowns)
	table.clear(entry.BurstByOtherKey)

	if _entriesByRuntimeId[entry.RuntimeId] == entry then
		_entriesByRuntimeId[entry.RuntimeId] = nil
	end
	if _entriesByUserId[entry.OwnerUserId] == entry then
		_entriesByUserId[entry.OwnerUserId] = nil
	end
	syncPreSimulationConnection()

	return true
end

--[=[
	Punto de entrada determinista de evaluación física para simulaciones controladas y pruebas automatizadas.
]=]
function VehicleImpactService.EvaluateImpact(
	runtimeOrIdOrUser: VehicleTypes.VehicleRuntime | { UserId: number } | string | number,
	params: SyntheticImpactInput
): EvaluatedImpactOutcome
	if not _initialized then
		VehicleImpactService.Init()
	end
	local entry = resolveEntry(runtimeOrIdOrUser)
	if not entry or entry.Destroyed then
		return { Triggered = false, RejectReason = "RuntimeNotRegistered" }
	end
	return processEvaluatedImpact(entry, params)
end

function VehicleImpactService.GetTrackedConnectionCount(): number
	local total = 0
	for _, entry in pairs(_entriesByRuntimeId) do
		if not entry.Destroyed then
			for _, conn in ipairs(entry.Connections) do
				if conn.Connected then
					total += 1
				end
			end
		end
	end
	return total
end

function VehicleImpactService.GetActiveVehicleCount(): number
	local count = 0
	for _, entry in pairs(_entriesByRuntimeId) do
		if not entry.Destroyed then
			count += 1
		end
	end
	return count
end

function VehicleImpactService.GetActivePartIndexCount(): number
	local count = 0
	for _ in pairs(_runtimeByPart) do
		count += 1
	end
	return count
end

function VehicleImpactService._SetClockForTests(fn: (() -> number)?)
	_clockFn = fn or os.clock
end

function VehicleImpactService.Init()
	if _initialized then
		return
	end
	VehicleDamageService.Init()
	_initialized = true
end

function VehicleImpactService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehicleImpactService.Init()
	end
	_started = true
end

function VehicleImpactService._ResetForTests()
	for runtimeId in pairs(table.clone(_entriesByRuntimeId)) do
		VehicleImpactService.UnregisterRuntime(runtimeId)
	end
	if _preSimConn then
		if _preSimConn.Connected then
			_preSimConn:Disconnect()
		end
		_preSimConn = nil
	end
	table.clear(_entriesByRuntimeId)
	table.clear(_entriesByUserId)
	table.clear(_runtimeByPart)
	table.clear(_obstacleKeys)
	_nextObstacleId = 0
	_clockFn = os.clock
	_initialized = false
	_started = false
end

return VehicleImpactService

