--!strict
--[=[
	BuildService
	Servicio autoritativo de servidor para operaciones de construcción (PlacePiece, RemovePiece, GetBlueprint).
	- Valida propiedad exclusivamente vía Player + PlotService (nunca datos de autoridad del cliente).
	- Aplica Token Bucket por jugador distinguiendo lecturas y escrituras antes de costear validaciones pesadas.
	- Valida payloads con BuildPayloadValidator, geometría autorizada con ConnectionService y límites de BuildZone.
	- Emite BlueprintSyncEvent al propietario para sincronización y recuperación de desincronizaciones.
	- Mantiene caché idempotente acotado de ClientOpId y libera recursos en PlayerRemoving/Release.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildGrid = require(ReplicatedStorage.Shared.Building.BuildGrid)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildSnapPolicy = require(ReplicatedStorage.Shared.Building.BuildSnapPolicy)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local VehicleCoordinateMath = require(ReplicatedStorage.Shared.Building.VehicleCoordinateMath)

local PlotService = require(ServerScriptService.Server.Services.PlotService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local BoosterInventoryService = require(ServerScriptService.Server.Services.BoosterInventoryService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local StandPreviewService = require(ServerScriptService.Server.Services.StandPreviewService)
local VehicleLaunchPreparationService = require(ServerScriptService.Server.Services.VehicleLaunchPreparationService)
local VehicleLifecycleService = require(ServerScriptService.Server.Services.VehicleLifecycleService)
local VehicleLaunchService = require(ServerScriptService.Server.Services.VehicleLaunchService)
local VehicleBoosterService = require(ServerScriptService.Server.Services.VehicleBoosterService)
local VehiclePowertrainService = require(ServerScriptService.Server.Services.VehiclePowertrainService)
local TokenBucket = require(ServerScriptService.Server.Security.TokenBucket)
local BuildPayloadValidator = require(ServerScriptService.Server.Security.BuildPayloadValidator)

export type SyncListener = (player: PlotService.PlayerLike, payload: BuildProtocol.BlueprintSyncPayload) -> ()

local BuildService = {
	Name = "BuildService",
}

local _processedOpsByUserId: { [number]: { [string]: BuildProtocol.BuildOperationResponse } } = {}
local _processedOpOrderByUserId: { [number]: { string } } = {}
local _playerBusyLock: { [number]: boolean } = {}
local _plotStaticExcludeCache: { [Model]: { Instance } } = {}
local _connections: { RBXScriptConnection } = {}
local _syncListeners: { SyncListener } = {}
local _unsubPlotReleased: (() -> ())? = nil
local _unsubPlotAssigned: (() -> ())? = nil
local _unsubLifecycleState: (() -> ())? = nil
local _requestRemote: RemoteFunction? = nil
local _syncRemote: RemoteEvent? = nil
local _overlapParams = OverlapParams.new()
_overlapParams.FilterType = Enum.RaycastFilterType.Exclude
local _rateLimiter: TokenBucket.TokenBucketLimiter? = nil
local _clockOverride: (() -> number)? = nil
local _initialized = false
local _started = false

local function getOrCreateRateLimiter(): TokenBucket.TokenBucketLimiter
	if not _rateLimiter then
		_rateLimiter = TokenBucket.Create({
			WriteCapacity = GameConfig.Building.RateLimitBurstWrite,
			WriteRefillPerSecond = GameConfig.Building.MaxOpsPerSecond,
			ReadCapacity = GameConfig.Building.RateLimitBurstRead,
			ReadRefillPerSecond = GameConfig.Building.MaxReadOpsPerSecond,
			Clock = _clockOverride,
		})
	end
	return _rateLimiter :: TokenBucket.TokenBucketLimiter
end

local function makeErrorResponse(
	clientOpId: string?,
	revision: number,
	errorCode: string,
	errorMessage: string,
	blueprintId: string?,
	ownerUserId: number?
): BuildProtocol.BuildOperationResponse
	return {
		Success = false,
		ClientOpId = clientOpId,
		ErrorCode = errorCode,
		ErrorMessage = errorMessage,
		Revision = revision,
		BlueprintId = blueprintId,
		OwnerUserId = ownerUserId,
	}
end

local function emitSyncEvent(player: PlotService.PlayerLike, payload: BuildProtocol.BlueprintSyncPayload)
	if _syncRemote and typeof(player) == "Instance" and (player :: Instance):IsA("Player") then
		(_syncRemote :: RemoteEvent):FireClient(player :: Player, payload)
	end
	if #_syncListeners > 0 then
		for _, listener in ipairs(table.clone(_syncListeners)) do
			task.spawn(listener, player, payload)
		end
	end
end

local function emitInventorySync(
	player: PlotService.PlayerLike,
	revision: number,
	blueprintId: string?,
	clientOpId: string?,
	snapshot: any?
)
	local invSnap = snapshot or InventoryService.GetPlayerSnapshot(player)
	emitSyncEvent(player, {
		Type = BuildProtocol.SyncTypes.InventoryUpdated :: BuildProtocol.BlueprintSyncEventType,
		OwnerUserId = player.UserId,
		BlueprintId = blueprintId or "",
		Revision = revision,
		ClientOpId = clientOpId,
		Inventory = invSnap,
	})
	return invSnap
end

local function cacheOpResponse(userId: number, clientOpId: string, response: BuildProtocol.BuildOperationResponse)
	local cache = _processedOpsByUserId[userId]
	local order = _processedOpOrderByUserId[userId]
	if not cache or not order then
		cache = {}
		order = {}
		_processedOpsByUserId[userId] = cache
		_processedOpOrderByUserId[userId] = order
	end

	if cache[clientOpId] == nil then
		table.insert(order, clientOpId)
		local maxEntries = GameConfig.Building.MaxCachedOpIdsPerPlayer
		while #order > maxEntries do
			local oldestId = table.remove(order, 1)
			if oldestId then
				cache[oldestId] = nil
			end
		end
	end
	cache[clientOpId] = response
end

local function getPlotStaticExclude(plot: PlotService.PlotRecord): { Instance }
	local cached = _plotStaticExcludeCache[plot.Model]
	if cached then
		return cached
	end

	local exclude: { Instance } = { plot.Zones.BuildZone }
	local platform = plot.Model:FindFirstChild("Platform")
	if platform then
		table.insert(exclude, platform)
	end
	if plot.PlotOrigin then
		table.insert(exclude, plot.PlotOrigin)
	end
	if plot.PlayerSpawn then
		table.insert(exclude, plot.PlayerSpawn)
	end
	_plotStaticExcludeCache[plot.Model] = exclude
	return exclude
end

local function buildWorldOverlapExclude(plot: PlotService.PlotRecord): { Instance }
	local staticExclude = getPlotStaticExclude(plot)
	local exclude: { Instance } = table.clone(staticExclude)

	local editableModel = plot.DynamicContainer:FindFirstChild(GameConfig.Building.EditableVehicleName)
	if editableModel then
		table.insert(exclude, editableModel)
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	return exclude
end

local function isBlockingWorldPart(part: BasePart): boolean
	return part.CanCollide
		or part:FindFirstAncestor(GameConfig.PlotContainers.Decorations) ~= nil
		or part:FindFirstAncestor(GameConfig.PlotContainers.Structures) ~= nil
end

local function queryBoxObstruction(worldCFrame: CFrame, boxSize: Vector3): (boolean, string?)
	local shrunkSize = Vector3.new(
		math.max(0.1, boxSize.X - 0.08),
		math.max(0.1, boxSize.Y - 0.08),
		math.max(0.1, boxSize.Z - 0.08)
	)
	local parts = Workspace:GetPartBoundsInBox(worldCFrame, shrunkSize, _overlapParams)
	for _, part in ipairs(parts) do
		if isBlockingWorldPart(part) then
			return true, part.Name
		end
	end
	return false, nil
end

local function hasBlockedWorldGeometry(
	plot: PlotService.PlotRecord,
	worldCFrame: CFrame,
	pieceSize: Vector3
): (boolean, string?)
	_overlapParams.FilterDescendantsInstances = buildWorldOverlapExclude(plot)
	return queryBoxObstruction(worldCFrame, pieceSize)
end

local function resolveItemSizeForLift(itemId: string): Vector3?
	local geom = ConnectionService.GetItemGeometry(itemId)
	return if geom then geom.Size else nil
end

local function hasBlockedAssemblyWorldGeometry(
	plot: PlotService.PlotRecord,
	bp: VehicleTypes.VehicleBlueprint,
	assemblyOffset: VehicleTypes.BuildAssemblyOffset
): (boolean, string?)
	if #bp.Pieces == 0 then
		return false, nil
	end

	_overlapParams.FilterDescendantsInstances = buildWorldOverlapExclude(plot)
	local effectiveZoneCF = VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(plot.Zones.BuildZone.CFrame, assemblyOffset)

	-- Fase amplia O(1): verificar caja envolvente completa del vehículo antes de inspeccionar por pieza
	local bounds = VehicleCoordinateMath.ComputeVehicleBounds(bp.Pieces, resolveItemSizeForLift)
	if bounds.Valid then
		local broadWorldCF = effectiveZoneCF:ToWorldSpace(CFrame.new(bounds.Center))
		local broadBlocked = queryBoxObstruction(broadWorldCF, bounds.Size)
		if not broadBlocked then
			return false, nil
		end
	end

	-- Confirmación exacta por OBB de cada pieza del vehículo
	for _, piece in ipairs(bp.Pieces) do
		local geom = ConnectionService.GetItemGeometry(piece.ItemId)
		if geom then
			local pieceWorldCF = effectiveZoneCF:ToWorldSpace(piece.LocalCFrame)
			local blocked, blockerName = queryBoxObstruction(pieceWorldCF, geom.Size)
			if blocked then
				return true, blockerName
			end
		end
	end

	return false, nil
end

local function handlePlacePiece(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	req: {
		Action: "PlacePiece",
		ClientOpId: string,
		ItemId: string,
		LocalCFrame: CFrame,
		Config: { [string]: any }?,
		InventoryInstanceId: string?,
	}
): BuildProtocol.BuildOperationResponse
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)

	if not ItemRegistry.Has(req.ItemId) then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.UnknownItem,
			"Pieza inexistente en ItemRegistry",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	local geom = ConnectionService.GetItemGeometry(req.ItemId)
	if not geom then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.MissingAsset,
			"Modelo de pieza no disponible",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	if #bp.Pieces >= GameConfig.Building.MaxPiecesPerVehicle then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.MaxPiecesReached,
			"Límite máximo de piezas alcanzado",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	if req.ItemId == GameConfig.LaunchPrep.DriverSeatItemId then
		local seatCount = 0
		for _, piece in ipairs(bp.Pieces) do
			if piece.ItemId == GameConfig.LaunchPrep.DriverSeatItemId then
				seatCount += 1
			end
		end
		if seatCount >= GameConfig.Blueprints.MaxDriverSeatsPerBlueprint then
			return makeErrorResponse(
				req.ClientOpId,
				bp.Revision,
				BuildProtocol.ErrorCodes.TooManyDriverSeats,
				`Solo se permite {GameConfig.Blueprints.MaxDriverSeatsPerBlueprint} DriverSeat por vehículo en el taller`,
				bp.BlueprintId,
				bp.OwnerUserId
			)
		end
	end

	local invValidation = InventoryService.ValidatePlacement(
		player,
		req.ItemId,
		req.InventoryInstanceId,
		"__new_piece__",
		VehicleBlueprintService.GetActivePieceMapForPlayer(player)
	)
	if not invValidation.Valid then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			invValidation.ErrorCode or BuildProtocol.ErrorCodes.InsufficientInventory,
			invValidation.ErrorMessage or "Inventario insuficiente para colocar esta pieza",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end
	local resolvedInventoryInstanceId = invValidation.ResolvedInventoryInstanceId

	local policyOk, normalizedLocalCFOk, rotErrReason = BuildSnapPolicy.ValidateCFrameForItem(req.ItemId, req.LocalCFrame)
	if not policyOk or not normalizedLocalCFOk then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.InvalidRotation,
			rotErrReason or "Rotación no permitida por la política de la pieza",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end
	local normalizedLocalCF = normalizedLocalCFOk
	local candSpecForBounds: ConnectionMath.PieceGeometrySpec = {
		InstanceId = "__bounds_check__",
		ItemId = req.ItemId,
		LocalCFrame = normalizedLocalCF,
		Size = geom.Size,
		Attachments = geom.Attachments,
		PartBoxes = geom.PartBoxes,
	}
	local minBound, maxBound = ConnectionMath.ComputePieceLocalAABB(candSpecForBounds)
	local liftOffset = VehicleBlueprintService.GetLiftOffset(player)

	local inBounds, boundsErr = BuildGrid.ValidateBoundsMinMax(
		plot.Zones.BuildZone.Size,
		minBound,
		maxBound,
		GameConfig.Building.DefaultZoneHeight,
		liftOffset
	)
	if not inBounds then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.OutOfBounds,
			`Fuera de BuildZone ({tostring(boundsErr)})`,
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	-- Validación matemática/espacial de colisiones y detección de conexiones explícitas
	local candidateId = `__pending_{player.UserId}_{bp.Revision + 1}`
	local connOk, connections, connErrCode, connDiag = ConnectionService.ValidatePlacementConnections(
		candidateId,
		req.ItemId,
		normalizedLocalCF,
		bp.Pieces,
		player.UserId,
		bp.Revision,
		bp.Connections
	)
	if not connOk then
		local code = connErrCode or BuildProtocol.ErrorCodes.PieceOverlap
		local msg = if code == BuildProtocol.ErrorCodes.PieceOverlap
			then `La pieza se superpone con otra pieza del vehículo ({tostring(connDiag)})`
			else `Error geométrico al validar colocación ({tostring(connDiag)})`
		return makeErrorResponse(req.ClientOpId, bp.Revision, code, msg, bp.BlueprintId, bp.OwnerUserId)
	end

	local effectiveZoneCF = VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(plot.Zones.BuildZone.CFrame, liftOffset)
	local worldCF = effectiveZoneCF:ToWorldSpace(normalizedLocalCF)
	local blocked, blockerName = hasBlockedWorldGeometry(plot, worldCF, geom.Size)
	if blocked then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.BlockedGeometry,
			`Intersección con geometría bloqueada ({tostring(blockerName)})`,
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	-- Asignar InstanceId autoritativo definitivo solo después de superar todas las validaciones
	local authoritativePieceId = VehicleBlueprintService.AllocateNextPieceId(player)
	for _, conn in ipairs(connections) do
		conn.FromPieceId = authoritativePieceId
	end

	local placedPiece, newRevision = VehicleBlueprintService.AddPiece(
		player,
		plot,
		authoritativePieceId,
		req.ItemId,
		normalizedLocalCF,
		req.Config,
		connections,
		resolvedInventoryInstanceId
	)

	ConnectionService.NotifyPieceAdded(player.UserId, newRevision, placedPiece, connections)
	local invSnap = InventoryService.GetPlayerSnapshot(player)

	emitSyncEvent(player, {
		Type = "PiecePlaced",
		OwnerUserId = bp.OwnerUserId,
		BlueprintId = bp.BlueprintId,
		Revision = newRevision,
		ClientOpId = req.ClientOpId,
		PlacedPiece = placedPiece,
		ConnectionsAdded = connections,
		Inventory = invSnap,
	})

	return {
		Success = true,
		ClientOpId = req.ClientOpId,
		Revision = newRevision,
		BlueprintId = bp.BlueprintId,
		OwnerUserId = bp.OwnerUserId,
		PlacedPiece = placedPiece,
		Connections = connections,
		Blueprint = VehicleBlueprintService.GetBlueprintSnapshot(player),
		Inventory = invSnap,
	}
end

local function handleRemovePiece(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	req: {
		Action: "RemovePiece",
		ClientOpId: string,
		PieceInstanceId: string,
	}
): BuildProtocol.BuildOperationResponse
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)

	local canRemove, removeErrCode = ConnectionService.CanRemovePiece(bp, req.PieceInstanceId)
	if not canRemove then
		local code = removeErrCode or BuildProtocol.ErrorCodes.PieceNotFound
		return makeErrorResponse(req.ClientOpId, bp.Revision, code, "La pieza no existe en tu vehículo", bp.BlueprintId, bp.OwnerUserId)
	end

	local removed, newRevision = VehicleBlueprintService.RemovePiece(player, plot, req.PieceInstanceId)
	if not removed then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.PieceNotFound,
			"La pieza no existe",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	ConnectionService.NotifyPieceRemoved(player.UserId, newRevision, req.PieceInstanceId)
	local invSnap = InventoryService.GetPlayerSnapshot(player)

	emitSyncEvent(player, {
		Type = "PieceRemoved",
		OwnerUserId = bp.OwnerUserId,
		BlueprintId = bp.BlueprintId,
		Revision = newRevision,
		ClientOpId = req.ClientOpId,
		RemovedPieceId = req.PieceInstanceId,
		Inventory = invSnap,
	})

	return {
		Success = true,
		ClientOpId = req.ClientOpId,
		Revision = newRevision,
		BlueprintId = bp.BlueprintId,
		OwnerUserId = bp.OwnerUserId,
		RemovedPieceId = req.PieceInstanceId,
		Blueprint = VehicleBlueprintService.GetBlueprintSnapshot(player),
		Inventory = invSnap,
	}
end

local function handleTransformPiece(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	req: {
		Action: "TransformPiece",
		ClientOpId: string,
		PieceInstanceId: string,
		LocalCFrame: CFrame,
	}
): BuildProtocol.BuildOperationResponse
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local existingPiece = VehicleBlueprintService.GetPieceSnapshot(player, req.PieceInstanceId)
	if not existingPiece then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.PieceNotFound,
			"La pieza seleccionada no existe",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	local geom = ConnectionService.GetItemGeometry(existingPiece.ItemId)
	if not geom then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.MissingAsset,
			"Geometría del componente no disponible",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	local policyOk, normalizedLocalCFOk, rotErrReason = BuildSnapPolicy.ValidateCFrameForItem(existingPiece.ItemId, req.LocalCFrame)
	if not policyOk or not normalizedLocalCFOk then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.InvalidRotation,
			rotErrReason or "Rotación no permitida para este componente",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end
	local normalizedLocalCF = normalizedLocalCFOk
	local candSpecForBounds: ConnectionMath.PieceGeometrySpec = {
		InstanceId = existingPiece.InstanceId,
		ItemId = existingPiece.ItemId,
		LocalCFrame = normalizedLocalCF,
		Size = geom.Size,
		Attachments = geom.Attachments,
		PartBoxes = geom.PartBoxes,
	}
	local minBound, maxBound = ConnectionMath.ComputePieceLocalAABB(candSpecForBounds)
	local liftOffset = VehicleBlueprintService.GetLiftOffset(player)

	local inBounds, boundsErr = BuildGrid.ValidateBoundsMinMax(
		plot.Zones.BuildZone.Size,
		minBound,
		maxBound,
		GameConfig.Building.DefaultZoneHeight,
		liftOffset
	)
	if not inBounds then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.OutOfBounds,
			`Fuera de BuildZone ({tostring(boundsErr)})`,
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	local connOk, newConnections, connErrCode, connDiag = ConnectionService.ValidateTransformConnections(
		existingPiece.InstanceId,
		existingPiece.ItemId,
		normalizedLocalCF,
		bp.Pieces,
		player.UserId,
		bp.Revision,
		bp.Connections
	)
	if not connOk then
		local code = connErrCode or BuildProtocol.ErrorCodes.PieceOverlap
		local msg = if code == BuildProtocol.ErrorCodes.PieceOverlap
			then `La nueva posición se superpone con otra pieza ({tostring(connDiag)})`
			else `Error geométrico al transformar pieza ({tostring(connDiag)})`
		return makeErrorResponse(req.ClientOpId, bp.Revision, code, msg, bp.BlueprintId, bp.OwnerUserId)
	end

	local effectiveZoneCF = VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(plot.Zones.BuildZone.CFrame, liftOffset)
	local worldCF = effectiveZoneCF:ToWorldSpace(normalizedLocalCF)
	local blocked, blockerName = hasBlockedWorldGeometry(plot, worldCF, geom.Size)
	if blocked then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.BlockedGeometry,
			`Intersección con geometría bloqueada ({tostring(blockerName)})`,
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	local updatedPiece, newRevision = VehicleBlueprintService.UpdatePieceTransform(
		player,
		plot,
		existingPiece.InstanceId,
		normalizedLocalCF,
		newConnections
	)
	if not updatedPiece then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.PieceNotFound,
			"La pieza ya no existe",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	ConnectionService.NotifyPieceTransformed(player.UserId, newRevision, updatedPiece, newConnections)

	emitSyncEvent(player, {
		Type = "PieceTransformed",
		OwnerUserId = bp.OwnerUserId,
		BlueprintId = bp.BlueprintId,
		Revision = newRevision,
		ClientOpId = req.ClientOpId,
		TransformedPiece = updatedPiece,
		UpdatedConnections = newConnections,
	})

	return {
		Success = true,
		ClientOpId = req.ClientOpId,
		Revision = newRevision,
		BlueprintId = bp.BlueprintId,
		OwnerUserId = bp.OwnerUserId,
		TransformedPiece = updatedPiece,
		Connections = newConnections,
		Blueprint = VehicleBlueprintService.GetBlueprintSnapshot(player),
	}
end

local function handleUpdatePieceConfig(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	req: {
		Action: "UpdatePieceConfig",
		ClientOpId: string,
		PieceInstanceId: string,
		Config: { [string]: any }?,
		InventoryInstanceId: string?,
		ResetToAuto: boolean?,
	}
): BuildProtocol.BuildOperationResponse
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local existingPiece: VehicleTypes.BlueprintPiece? = nil
	for _, piece in ipairs(bp.Pieces) do
		if piece.InstanceId == req.PieceInstanceId then
			existingPiece = piece
			break
		end
	end

	if not existingPiece then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.PieceNotFound,
			"La pieza especificada no existe en tu vehículo",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	local def = ItemRegistry.TryGet(existingPiece.ItemId)
	if not def or (def.Category ~= "Wheels" and def.Category ~= "Engines" and def.Category ~= "FuelTanks" and def.Category ~= "Boosters") then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.PieceNotConfigurable,
			`El componente '{existingPiece.ItemId}' no admite configuración modular`,
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	local finalConfig: { [string]: any }? = nil
	if def.Category == "Wheels" then
		if req.InventoryInstanceId ~= nil and #req.InventoryInstanceId > 0 then
			return makeErrorResponse(
				req.ClientOpId,
				bp.Revision,
				BuildProtocol.ErrorCodes.InvalidPayload,
				"InventoryInstanceId no aplica a ruedas",
				bp.BlueprintId,
				bp.OwnerUserId
			)
		end
		if req.ResetToAuto ~= true and req.Config ~= nil then
			local okCfg, cleanedCfg, errCode, errMsg = BuildPayloadValidator.ValidateWheelConfigTable(req.Config)
			if not okCfg then
				return makeErrorResponse(
					req.ClientOpId,
					bp.Revision,
					errCode or BuildProtocol.ErrorCodes.InvalidConfigRange,
					errMsg or "Configuración de rueda fuera de rango o inválida",
					bp.BlueprintId,
					bp.OwnerUserId
				)
			end
			finalConfig = cleanedCfg
		end
	elseif def.Category == "Engines" then
		if req.ResetToAuto ~= true and req.InventoryInstanceId ~= nil and #req.InventoryInstanceId > 0 then
			local unitVal = EngineInventoryService.ValidateUnitForBlueprintPiece(
				player,
				req.InventoryInstanceId,
				existingPiece.InstanceId,
				VehicleBlueprintService.GetActivePieceMapForPlayer(player)
			)
			if not unitVal.Valid then
				return makeErrorResponse(
					req.ClientOpId,
					bp.Revision,
					unitVal.ErrorCode or BuildProtocol.ErrorCodes.InvalidPayload,
					unitVal.ErrorMessage or "Unidad de motor no válida",
					bp.BlueprintId,
					bp.OwnerUserId
				)
			end
		end
		if req.ResetToAuto ~= true and req.Config ~= nil then
			local okCfg, cleanedCfg, errCode, errMsg = BuildPayloadValidator.ValidateEngineConfigTable(req.Config)
			if not okCfg then
				return makeErrorResponse(
					req.ClientOpId,
					bp.Revision,
					errCode or BuildProtocol.ErrorCodes.InvalidConfigRange,
					errMsg or "Configuración de motor inválida",
					bp.BlueprintId,
					bp.OwnerUserId
				)
			end
			finalConfig = cleanedCfg
		end
	elseif def.Category == "FuelTanks" then
		if req.ResetToAuto ~= true and req.Config ~= nil then
			local okCfg, cleanedCfg, errCode, errMsg = BuildPayloadValidator.ValidateFuelTankConfigTable(req.Config)
			if not okCfg then
				return makeErrorResponse(
					req.ClientOpId,
					bp.Revision,
					errCode or BuildProtocol.ErrorCodes.InvalidConfigRange,
					errMsg or "Configuración de tanque inválida",
					bp.BlueprintId,
					bp.OwnerUserId
				)
			end
			finalConfig = cleanedCfg
		end
	elseif def.Category == "Boosters" then
		if req.ResetToAuto ~= true and req.InventoryInstanceId ~= nil and #req.InventoryInstanceId > 0 then
			local unitVal = BoosterInventoryService.ValidateUnitForBlueprintPiece(
				player,
				req.InventoryInstanceId,
				existingPiece.InstanceId,
				VehicleBlueprintService.GetActivePieceMapForPlayer(player)
			)
			if not unitVal.Valid then
				return makeErrorResponse(
					req.ClientOpId,
					bp.Revision,
					unitVal.ErrorCode or BuildProtocol.ErrorCodes.InvalidPayload,
					unitVal.ErrorMessage or "Unidad de propulsor no válida",
					bp.BlueprintId,
					bp.OwnerUserId
				)
			end
		end
		if req.ResetToAuto ~= true and req.Config ~= nil then
			local okCfg, cleanedCfg, errCode, errMsg = BuildPayloadValidator.ValidateBoosterConfigTable(req.Config)
			if not okCfg then
				return makeErrorResponse(
					req.ClientOpId,
					bp.Revision,
					errCode or BuildProtocol.ErrorCodes.InvalidConfigRange,
					errMsg or "Configuración de propulsor inválida",
					bp.BlueprintId,
					bp.OwnerUserId
				)
			end
			finalConfig = cleanedCfg
		end
	end

	local updatedPiece, newRevision = VehicleBlueprintService.UpdatePieceConfig(
		player,
		plot,
		existingPiece.InstanceId,
		finalConfig,
		req.ResetToAuto,
		req.InventoryInstanceId
	)
	if not updatedPiece then
		return makeErrorResponse(
			req.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.PieceNotFound,
			"La pieza ya no existe",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	local invSnap = InventoryService.GetPlayerSnapshot(player)
	emitSyncEvent(player, {
		Type = BuildProtocol.SyncTypes.PieceConfigUpdated,
		OwnerUserId = bp.OwnerUserId,
		BlueprintId = bp.BlueprintId,
		Revision = newRevision,
		ClientOpId = req.ClientOpId,
		UpdatedPiece = updatedPiece,
		Inventory = invSnap,
	})

	return {
		Success = true,
		ClientOpId = req.ClientOpId,
		Revision = newRevision,
		BlueprintId = bp.BlueprintId,
		OwnerUserId = bp.OwnerUserId,
		UpdatedPiece = updatedPiece,
		Blueprint = VehicleBlueprintService.GetBlueprintSnapshot(player),
		Inventory = invSnap,
	}
end

local _blueprintOpCacheByUserId: { [number]: { Order: { string }, Responses: { [string]: BuildProtocol.BuildOperationResponse } } } = {}
local _bpClearHookRegistered = false

local function ensureBlueprintCacheResetHook()
	if _bpClearHookRegistered then
		return
	end
	_bpClearHookRegistered = true
	VehicleBlueprintService.OnBlueprintChanged(function(plr, _plot, kind)
		if kind == "PlayerCleared" then
			_blueprintOpCacheByUserId[plr.UserId] = nil
		end
	end)
end

local function emitDirectSyncToPlayer(player: PlotService.PlayerLike, payload: BuildProtocol.BlueprintSyncPayload)
	if typeof(player) == "Instance" and (player :: Instance):IsA("Player") then
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local remotes = if shared then shared:FindFirstChild("Remotes") else nil
		local syncRemote = if remotes then remotes:FindFirstChild(BuildProtocol.SyncRemoteEventName) else nil
		if syncRemote and syncRemote:IsA("RemoteEvent") then
			(syncRemote :: RemoteEvent):FireClient(player :: Player, payload)
		end
	end
end

local function cacheBlueprintOpResponse(userId: number, opId: string?, response: BuildProtocol.BuildOperationResponse)
	if not opId then
		return
	end
	local bucket = _blueprintOpCacheByUserId[userId]
	if not bucket then
		bucket = { Order = {}, Responses = {} }
		_blueprintOpCacheByUserId[userId] = bucket
	end
	if not bucket.Responses[opId] then
		table.insert(bucket.Order, opId)
		if #bucket.Order > GameConfig.Building.MaxCachedOpIdsPerPlayer then
			local oldest = table.remove(bucket.Order, 1)
			if oldest then
				bucket.Responses[oldest] = nil
			end
		end
	end
	bucket.Responses[opId] = response
end

local function dispatchPhase24Action(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	req: any
): (boolean, BuildProtocol.BuildOperationResponse?)
	ensureBlueprintCacheResetHook()
	local action = req.Action
	local userId = player.UserId

	if action == BuildProtocol.Actions.ListBlueprints or action == BuildProtocol.Actions.ListBlueprintSlots then
		local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
		local list, activeId, _ = VehicleBlueprintService.ListBlueprints(player)
		local rev, _ = VehicleBlueprintService.GetCurrentRevision(player)
		local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
		return true, {
			Success = true,
			ClientOpId = req.ClientOpId,
			Revision = rev,
			BlueprintId = activeId,
			OwnerUserId = userId,
			Blueprints = list,
			Slots = slots,
			LoadedSlotIndex = loadedSlotIdx,
			WorkshopPieceCount = VehicleBlueprintService.GetPieceCount(player),
			WorkshopEpoch = epoch,
			LegacyOverflowCount = overflowCount,
			LegacyOverflow = overflowList,
			HasUnsavedChanges = hasUnsaved,
			MaxBlueprints = GameConfig.Blueprints.MaxSlots,
		}
	elseif action == BuildProtocol.Actions.ValidateLaunchPrep then
		local bp = VehicleBlueprintService.GetBlueprintSnapshot(player)
		local report = VehicleLaunchPreparationService.EvaluatePlayerLaunch(player)
		return true, {
			Success = true,
			ClientOpId = req.ClientOpId,
			Revision = bp.Revision,
			BlueprintId = bp.BlueprintId,
			OwnerUserId = userId,
			LaunchPrepReport = report,
		}
	end

	local isBlueprintWriteAction =
		action == BuildProtocol.Actions.CreateBlueprint
		or action == BuildProtocol.Actions.SaveBlueprint
		or action == BuildProtocol.Actions.LoadBlueprint
		or action == BuildProtocol.Actions.SetActiveBlueprint
		or action == BuildProtocol.Actions.DuplicateBlueprint
		or action == BuildProtocol.Actions.RenameBlueprint
		or action == BuildProtocol.Actions.DeleteBlueprint
		or action == BuildProtocol.Actions.SaveBlueprintSlot
		or action == BuildProtocol.Actions.LoadBlueprintSlot
		or action == BuildProtocol.Actions.OverwriteBlueprintSlot
		or action == BuildProtocol.Actions.RenameBlueprintSlot
		or action == BuildProtocol.Actions.DeleteBlueprintSlot
		or action == BuildProtocol.Actions.ClearWorkshop
		or action == BuildProtocol.Actions.RecoverLegacyBlueprint
		or action == BuildProtocol.Actions.SetStandOffset
		or action == BuildProtocol.Actions.ResetStandOffset
		or action == BuildProtocol.Actions.SelectPrimaryAssembly

	if not isBlueprintWriteAction then
		return false, nil
	end

	if not VehicleLifecycleService.CanEditBlueprint(player) then
		local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
		return true,
			makeErrorResponse(
				req.ClientOpId,
				curRev,
				BuildProtocol.ErrorCodes.InvalidPlayerState,
				"No podés modificar ni cambiar blueprints mientras el vehículo está lanzado",
				curId,
				userId
			)
	end

	-- Idempotencia por ClientOpId (permite reintentos seguros ante doble clic o latencia)
	local userCache = _blueprintOpCacheByUserId[userId]
	if userCache and req.ClientOpId and userCache.Responses[req.ClientOpId] then
		return true, userCache.Responses[req.ClientOpId]
	end

	if _playerBusyLock[userId] then
		local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
		return true,
			makeErrorResponse(
				req.ClientOpId,
				curRev,
				BuildProtocol.ErrorCodes.OperationInProgress,
				"Operación de taller en curso",
				curId,
				userId
			)
	end

	_playerBusyLock[userId] = true
	local okExec, execResponse = pcall(function(): BuildProtocol.BuildOperationResponse
		local response: BuildProtocol.BuildOperationResponse
		if action == BuildProtocol.Actions.ClearWorkshop then
			local okClear, emptyDraft, errCode, errMsg = VehicleBlueprintService.ClearWorkshop(
				player,
				plot,
				req.ExpectedRevision,
				req.ExpectedEpoch
			)
			if okClear and emptyDraft then
				StandPreviewService.RebuildForPlayer(player, plot, emptyDraft)
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
				local invSnap = InventoryService.GetPlayerSnapshot(player)
				emitDirectSyncToPlayer(player, {
					Type = BuildProtocol.SyncTypes.WorkshopCleared :: BuildProtocol.BlueprintSyncEventType,
					OwnerUserId = userId,
					BlueprintId = emptyDraft.BlueprintId,
					Revision = emptyDraft.Revision,
					ClientOpId = req.ClientOpId,
					Blueprint = emptyDraft,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = 0,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					Inventory = invSnap,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = emptyDraft.Revision,
					BlueprintId = emptyDraft.BlueprintId,
					OwnerUserId = userId,
					Blueprint = emptyDraft,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = 0,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
					Inventory = invSnap,
				}
			else
				local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
				}
			end
		elseif action == BuildProtocol.Actions.SaveBlueprintSlot then
			local okSave, draftSnap, errCode, errMsg = VehicleBlueprintService.SaveBlueprintSlot(
				player,
				plot,
				req.SlotIndex,
				req.Name,
				req.ExpectedRevision
			)
			if okSave and draftSnap then
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
				local invSnap = InventoryService.GetPlayerSnapshot(player)
				emitDirectSyncToPlayer(player, {
					Type = BuildProtocol.SyncTypes.SlotLibraryUpdated :: BuildProtocol.BlueprintSyncEventType,
					OwnerUserId = userId,
					BlueprintId = draftSnap.BlueprintId,
					Revision = draftSnap.Revision,
					ClientOpId = req.ClientOpId,
					Blueprint = draftSnap,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #draftSnap.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					Inventory = invSnap,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = draftSnap.Revision,
					BlueprintId = draftSnap.BlueprintId,
					OwnerUserId = userId,
					Blueprint = draftSnap,
					Blueprints = list,
					Slots = slots,
					SlotIndex = req.SlotIndex,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #draftSnap.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
					Inventory = invSnap,
				}
			else
				local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
					SlotIndex = req.SlotIndex,
				}
			end
		elseif action == BuildProtocol.Actions.OverwriteBlueprintSlot then
			local okOver, draftSnap, errCode, errMsg = VehicleBlueprintService.OverwriteBlueprintSlot(
				player,
				plot,
				req.SlotIndex,
				req.Name,
				req.ConfirmationStep,
				req.ExpectedSlotRevision,
				req.ExpectedWorkshopRevision
			)
			if okOver and draftSnap then
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
				local invSnap = InventoryService.GetPlayerSnapshot(player)
				emitDirectSyncToPlayer(player, {
					Type = BuildProtocol.SyncTypes.SlotLibraryUpdated :: BuildProtocol.BlueprintSyncEventType,
					OwnerUserId = userId,
					BlueprintId = draftSnap.BlueprintId,
					Revision = draftSnap.Revision,
					ClientOpId = req.ClientOpId,
					Blueprint = draftSnap,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #draftSnap.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					Inventory = invSnap,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = draftSnap.Revision,
					BlueprintId = draftSnap.BlueprintId,
					OwnerUserId = userId,
					Blueprint = draftSnap,
					Blueprints = list,
					Slots = slots,
					SlotIndex = req.SlotIndex,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #draftSnap.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
					Inventory = invSnap,
				}
			else
				local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
					SlotIndex = req.SlotIndex,
				}
			end
		elseif action == BuildProtocol.Actions.LoadBlueprintSlot then
			local okLoad, loadedBp, errCode, errMsg = VehicleBlueprintService.LoadBlueprintSlot(
				player,
				plot,
				req.SlotIndex,
				req.ConfirmDiscardUnsaved
			)
			if okLoad and loadedBp then
				StandPreviewService.RebuildForPlayer(player, plot, loadedBp)
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
				local invSnap = InventoryService.GetPlayerSnapshot(player)
				emitDirectSyncToPlayer(player, {
					Type = BuildProtocol.SyncTypes.BlueprintLoaded :: BuildProtocol.BlueprintSyncEventType,
					OwnerUserId = userId,
					BlueprintId = loadedBp.BlueprintId,
					Revision = loadedBp.Revision,
					ClientOpId = req.ClientOpId,
					Blueprint = loadedBp,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #loadedBp.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					Inventory = invSnap,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = loadedBp.Revision,
					BlueprintId = loadedBp.BlueprintId,
					OwnerUserId = userId,
					Blueprint = loadedBp,
					Blueprints = list,
					Slots = slots,
					SlotIndex = req.SlotIndex,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #loadedBp.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
					Inventory = invSnap,
				}
			else
				local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
					SlotIndex = req.SlotIndex,
				}
			end
		elseif action == BuildProtocol.Actions.RenameBlueprintSlot then
			local okRen, _, errCode, errMsg = VehicleBlueprintService.RenameBlueprintSlot(
				player,
				plot,
				req.SlotIndex,
				req.Name
			)
			local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
			if okRen then
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local activeBp = VehicleBlueprintService.GetBlueprintSnapshot(player)
				local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
				emitDirectSyncToPlayer(player, {
					Type = BuildProtocol.SyncTypes.SlotLibraryUpdated :: BuildProtocol.BlueprintSyncEventType,
					OwnerUserId = userId,
					BlueprintId = activeBp.BlueprintId,
					Revision = activeBp.Revision,
					ClientOpId = req.ClientOpId,
					Blueprint = activeBp,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #activeBp.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = activeBp.Revision,
					BlueprintId = activeBp.BlueprintId,
					OwnerUserId = userId,
					Blueprint = activeBp,
					Blueprints = list,
					Slots = slots,
					SlotIndex = req.SlotIndex,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #activeBp.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
				}
			else
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
					SlotIndex = req.SlotIndex,
				}
			end
		elseif action == BuildProtocol.Actions.DeleteBlueprintSlot then
			local okDel, activeBpAfter, errCode, errMsg = VehicleBlueprintService.DeleteBlueprintSlot(
				player,
				plot,
				req.SlotIndex,
				req.ConfirmationName
			)
			if okDel and activeBpAfter then
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
				local invSnap = InventoryService.GetPlayerSnapshot(player)
				emitDirectSyncToPlayer(player, {
					Type = BuildProtocol.SyncTypes.SlotLibraryUpdated :: BuildProtocol.BlueprintSyncEventType,
					OwnerUserId = userId,
					BlueprintId = activeBpAfter.BlueprintId,
					Revision = activeBpAfter.Revision,
					ClientOpId = req.ClientOpId,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #activeBpAfter.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					Inventory = invSnap,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = activeBpAfter.Revision,
					BlueprintId = activeBpAfter.BlueprintId,
					OwnerUserId = userId,
					Blueprint = activeBpAfter,
					Blueprints = list,
					Slots = slots,
					SlotIndex = req.SlotIndex,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #activeBpAfter.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
					Inventory = invSnap,
				}
			else
				local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
					SlotIndex = req.SlotIndex,
				}
			end
		elseif action == BuildProtocol.Actions.RecoverLegacyBlueprint then
			local okRec, _, errCode, errMsg = VehicleBlueprintService.RecoverLegacyBlueprint(
				player,
				plot,
				req.OriginalBlueprintId,
				req.TargetSlotIndex,
				req.ConfirmationStep
			)
			local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
			if okRec then
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
				emitDirectSyncToPlayer(player, {
					Type = BuildProtocol.SyncTypes.SlotLibraryUpdated :: BuildProtocol.BlueprintSyncEventType,
					OwnerUserId = userId,
					BlueprintId = curId or "",
					Revision = curRev,
					ClientOpId = req.ClientOpId,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = VehicleBlueprintService.GetPieceCount(player),
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
					Blueprints = list,
					Slots = slots,
					SlotIndex = req.TargetSlotIndex,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = VehicleBlueprintService.GetPieceCount(player),
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
				}
			else
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
				}
			end
		elseif action == BuildProtocol.Actions.CreateBlueprint then
			local ok, newBp, errCode, errMsg = VehicleBlueprintService.CreateBlueprint(player, plot, req.Name)
			if ok and newBp then
				StandPreviewService.RebuildForPlayer(player, plot, newBp)
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
				emitDirectSyncToPlayer(player, {
					Type = "BlueprintLoaded",
					OwnerUserId = userId,
					BlueprintId = newBp.BlueprintId,
					Revision = newBp.Revision,
					ClientOpId = req.ClientOpId,
					Blueprint = newBp,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #newBp.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = newBp.Revision,
					BlueprintId = newBp.BlueprintId,
					OwnerUserId = userId,
					Blueprint = newBp,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #newBp.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
				}
			else
				local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
				}
			end
		elseif action == BuildProtocol.Actions.SaveBlueprint then
			local ok, savedBp, errCode, errMsg = VehicleBlueprintService.SaveBlueprint(player, plot, req.Name, req.SaveAsNew)
			if ok and savedBp then
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
				emitDirectSyncToPlayer(player, {
					Type = "BlueprintLibraryUpdated",
					OwnerUserId = userId,
					BlueprintId = savedBp.BlueprintId,
					Revision = savedBp.Revision,
					ClientOpId = req.ClientOpId,
					Blueprint = savedBp,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #savedBp.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = savedBp.Revision,
					BlueprintId = savedBp.BlueprintId,
					OwnerUserId = userId,
					Blueprint = savedBp,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #savedBp.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
				}
			else
				local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
				}
			end
		elseif action == BuildProtocol.Actions.LoadBlueprint or action == BuildProtocol.Actions.SetActiveBlueprint then
			local ok, loadedBp, errCode, errMsg = VehicleBlueprintService.LoadBlueprint(player, plot, req.BlueprintId)
			if ok and loadedBp then
				StandPreviewService.RebuildForPlayer(player, plot, loadedBp)
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
				emitDirectSyncToPlayer(player, {
					Type = "BlueprintLoaded",
					OwnerUserId = userId,
					BlueprintId = loadedBp.BlueprintId,
					Revision = loadedBp.Revision,
					ClientOpId = req.ClientOpId,
					Blueprint = loadedBp,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #loadedBp.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = loadedBp.Revision,
					BlueprintId = loadedBp.BlueprintId,
					OwnerUserId = userId,
					Blueprint = loadedBp,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					WorkshopPieceCount = #loadedBp.Pieces,
					WorkshopEpoch = epoch,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
				}
			else
				local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
				}
			end
		elseif action == BuildProtocol.Actions.DuplicateBlueprint then
			local ok, dupSummary, errCode, errMsg = VehicleBlueprintService.DuplicateBlueprint(player, req.BlueprintId, req.Name)
			local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
			if ok and dupSummary then
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				emitDirectSyncToPlayer(player, {
					Type = "BlueprintLibraryUpdated",
					OwnerUserId = userId,
					BlueprintId = curId or "",
					Revision = curRev,
					ClientOpId = req.ClientOpId,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
					DuplicatedBlueprint = dupSummary,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
				}
			else
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
				}
			end
		elseif action == BuildProtocol.Actions.RenameBlueprint then
			local ok, _, errCode, errMsg = VehicleBlueprintService.RenameBlueprint(player, plot, req.BlueprintId, req.Name)
			local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
			if ok then
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				local activeBp = VehicleBlueprintService.GetBlueprintSnapshot(player)
				emitDirectSyncToPlayer(player, {
					Type = "BlueprintLibraryUpdated",
					OwnerUserId = userId,
					BlueprintId = activeBp.BlueprintId,
					Revision = activeBp.Revision,
					ClientOpId = req.ClientOpId,
					Blueprint = activeBp,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = activeBp.Revision,
					BlueprintId = activeBp.BlueprintId,
					OwnerUserId = userId,
					Blueprint = activeBp,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
				}
			else
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
				}
			end
		elseif action == BuildProtocol.Actions.DeleteBlueprint then
			local ok, activeBpAfter, errCode, errMsg = VehicleBlueprintService.DeleteBlueprint(player, plot, req.BlueprintId)
			if ok and activeBpAfter then
				local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
				local list = VehicleBlueprintService.ListBlueprints(player)
				emitDirectSyncToPlayer(player, {
					Type = "SlotLibraryUpdated",
					OwnerUserId = userId,
					BlueprintId = activeBpAfter.BlueprintId,
					Revision = activeBpAfter.Revision,
					ClientOpId = req.ClientOpId,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					LegacyOverflowCount = overflowCount,
					LegacyOverflow = overflowList,
					HasUnsavedChanges = hasUnsaved,
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = activeBpAfter.Revision,
					BlueprintId = activeBpAfter.BlueprintId,
					OwnerUserId = userId,
					Blueprint = activeBpAfter,
					Blueprints = list,
					Slots = slots,
					LoadedSlotIndex = loadedSlotIdx,
					HasUnsavedChanges = hasUnsaved,
					MaxBlueprints = GameConfig.Blueprints.MaxSlots,
				}
			else
				local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = curRev,
					BlueprintId = curId,
					OwnerUserId = userId,
				}
			end
		elseif action == BuildProtocol.Actions.SetStandOffset or action == BuildProtocol.Actions.ResetStandOffset then
			local liftBounds = VehicleBlueprintService.ComputeLiftBoundsForPlayer(player, plot)
			local targetH = if action == BuildProtocol.Actions.ResetStandOffset
				then liftBounds.DefaultRestHeightOffset
				else req.HeightOffset
			local targetL = if action == BuildProtocol.Actions.ResetStandOffset
				then liftBounds.DefaultRestLateralOffset
				else req.LateralOffset

			local currentBp = VehicleBlueprintService.GetBlueprintSnapshot(player)
			local inRange, _ = VehicleCoordinateMath.IsLiftOffsetWithinBounds(targetH, targetL, liftBounds, GameConfig.Stand.Epsilon)
			if inRange then
				local targetOffset: VehicleTypes.BuildAssemblyOffset = {
					HeightOffset = math.clamp(targetH, liftBounds.MinHeightOffset, liftBounds.MaxHeightOffset),
					LateralOffset = math.clamp(targetL, liftBounds.MinLateralOffset, liftBounds.MaxLateralOffset),
				}
				local blocked, blockerName = hasBlockedAssemblyWorldGeometry(plot, currentBp, targetOffset)
				if blocked then
					return {
						Success = false,
						ClientOpId = req.ClientOpId,
						ErrorCode = BuildProtocol.ErrorCodes.ElevatorBlocked,
						ErrorMessage = `El elevador no puede moverse: obstrucción con '{tostring(blockerName)}'`,
						Revision = currentBp.Revision,
						BlueprintId = currentBp.BlueprintId,
						OwnerUserId = userId,
						LiftBounds = liftBounds,
					}
				end
			end

			local ok, presentation, newRev, errCode, errMsg = VehicleBlueprintService.SetStandOffset(player, plot, targetH, targetL)
			local activeBp = VehicleBlueprintService.GetBlueprintSnapshot(player)
			if ok and presentation then
				StandPreviewService.UpdateOffsets(player, plot, activeBp)
				emitDirectSyncToPlayer(player, {
					Type = "StandPresentationUpdated",
					OwnerUserId = userId,
					BlueprintId = activeBp.BlueprintId,
					Revision = newRev,
					ClientOpId = req.ClientOpId,
					Presentation = presentation,
					BuildAssemblyOffset = presentation,
					HasUnsavedChanges = VehicleBlueprintService.HasUnsavedChanges(player),
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = newRev,
					BlueprintId = activeBp.BlueprintId,
					OwnerUserId = userId,
					Presentation = presentation,
					BuildAssemblyOffset = presentation,
					LiftBounds = liftBounds,
					Blueprint = activeBp,
					HasUnsavedChanges = VehicleBlueprintService.HasUnsavedChanges(player),
				}
			else
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = newRev,
					BlueprintId = activeBp.BlueprintId,
					OwnerUserId = userId,
					LiftBounds = liftBounds,
				}
			end
		elseif action == BuildProtocol.Actions.SelectPrimaryAssembly then
			local ok, analysis, newRev, errCode, errMsg = VehicleBlueprintService.SetPrimaryAssemblyGroup(player, plot, req.GroupId)
			local activeBp = VehicleBlueprintService.GetBlueprintSnapshot(player)
			if ok then
				emitDirectSyncToPlayer(player, {
					Type = "AssemblySelectionUpdated",
					OwnerUserId = userId,
					BlueprintId = activeBp.BlueprintId,
					Revision = newRev,
					ClientOpId = req.ClientOpId,
					Metadata = activeBp.Metadata,
					AssemblyAnalysis = analysis,
					HasUnsavedChanges = VehicleBlueprintService.HasUnsavedChanges(player),
				})
				response = {
					Success = true,
					ClientOpId = req.ClientOpId,
					Revision = newRev,
					BlueprintId = activeBp.BlueprintId,
					OwnerUserId = userId,
					Blueprint = activeBp,
					AssemblyAnalysis = analysis,
					HasUnsavedChanges = VehicleBlueprintService.HasUnsavedChanges(player),
				}
			else
				response = {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = errCode,
					ErrorMessage = errMsg,
					Revision = newRev,
					BlueprintId = activeBp.BlueprintId,
					OwnerUserId = userId,
					AssemblyAnalysis = analysis,
				}
			end
		else
			response = makeErrorResponse(req.ClientOpId, 0, BuildProtocol.ErrorCodes.InvalidPayload, "Acción no soportada", nil, userId)
		end

		return response
	end)
	_playerBusyLock[userId] = nil

	if not okExec then
		local curRev, curId = VehicleBlueprintService.GetCurrentRevision(player)
		return true, makeErrorResponse(
			req.ClientOpId,
			curRev,
			BuildProtocol.ErrorCodes.InvalidPayload,
			`Error ejecutando acción de taller: {tostring(execResponse)}`,
			curId,
			userId
		)
	end

	-- Solo guardar idempotencia si la operación completó sin error transitorio ni fallo de bloqueo
	if execResponse.ErrorCode ~= BuildProtocol.ErrorCodes.OperationInProgress and execResponse.ErrorCode ~= BuildProtocol.ErrorCodes.PersistenceFailed then
		cacheBlueprintOpResponse(userId, req.ClientOpId, execResponse)
	end
	return true, execResponse
end

local function dispatchPhase31Action(
	player: PlotService.PlayerLike,
	req: any
): (boolean, BuildProtocol.BuildOperationResponse?)
	local action = req.Action
	local userId = player.UserId
	local rev, bpId = VehicleBlueprintService.GetCurrentRevision(player)

	if action == BuildProtocol.Actions.GetRuntimeState then
		local snap = VehicleLaunchService.GetRuntimeState(player)
		return true, {
			Success = true,
			ClientOpId = req.ClientOpId,
			Revision = rev,
			BlueprintId = bpId,
			OwnerUserId = userId,
			RuntimeStatus = snap,
			PowertrainState = VehiclePowertrainService.GetPowertrainState(player),
			BoosterState = VehicleBoosterService.GetBoosterState(player),
		}
	elseif action == BuildProtocol.Actions.GetEngineUnits then
		local units = EngineInventoryService.EnsureControlledWorkshopUnits(player)
		return true, {
			Success = true,
			ClientOpId = req.ClientOpId,
			Revision = rev,
			BlueprintId = bpId,
			OwnerUserId = userId,
			EngineUnits = units,
		}
	elseif action == BuildProtocol.Actions.GetBoosterUnits then
		local units = BoosterInventoryService.EnsureControlledWorkshopUnits(player)
		return true, {
			Success = true,
			ClientOpId = req.ClientOpId,
			Revision = rev,
			BlueprintId = bpId,
			OwnerUserId = userId,
			BoosterUnits = units,
		}
	elseif action == BuildProtocol.Actions.SetDrivingInput then
		local okDrive, errCode, errMsg = VehiclePowertrainService.ApplyClientDrivingInput(player, req)
		return true, {
			Success = okDrive,
			ClientOpId = req.ClientOpId,
			ErrorCode = errCode,
			ErrorMessage = errMsg,
			Revision = rev,
			BlueprintId = bpId,
			OwnerUserId = userId,
			PowertrainState = VehiclePowertrainService.GetPowertrainState(player),
			BoosterState = VehicleBoosterService.GetBoosterState(player),
		}
	elseif action == BuildProtocol.Actions.LaunchVehicle then
		local res = VehicleLaunchService.LaunchVehicle(player)
		return true, {
			Success = res.Success,
			ClientOpId = req.ClientOpId,
			ErrorCode = res.ErrorCode,
			ErrorMessage = res.ErrorMessage,
			Revision = rev,
			BlueprintId = bpId,
			OwnerUserId = userId,
			RuntimeStatus = res.RuntimeStatus,
			LaunchPrepReport = res.LaunchPrepReport,
		}
	elseif action == BuildProtocol.Actions.ReturnToWorkshop then
		local res = VehicleLaunchService.ReturnToWorkshop(player)
		return true, {
			Success = res.Success,
			ClientOpId = req.ClientOpId,
			ErrorCode = res.ErrorCode,
			ErrorMessage = res.ErrorMessage,
			Revision = rev,
			BlueprintId = bpId,
			OwnerUserId = userId,
			RuntimeStatus = res.RuntimeStatus,
		}
	elseif action == BuildProtocol.Actions.ResetVehicle then
		local res = VehicleLaunchService.ResetVehicle(player)
		return true, {
			Success = res.Success,
			ClientOpId = req.ClientOpId,
			ErrorCode = res.ErrorCode,
			ErrorMessage = res.ErrorMessage,
			Revision = rev,
			BlueprintId = bpId,
			OwnerUserId = userId,
			RuntimeStatus = res.RuntimeStatus,
			LaunchPrepReport = res.LaunchPrepReport,
		}
	elseif action == BuildProtocol.Actions.ExitVehicleSeat then
		local res = VehicleLaunchService.ExitVehicleSeat(player)
		return true, {
			Success = res.Success,
			ClientOpId = req.ClientOpId,
			ErrorCode = res.ErrorCode,
			ErrorMessage = res.ErrorMessage,
			Revision = rev,
			BlueprintId = bpId,
			OwnerUserId = userId,
			RuntimeStatus = res.RuntimeStatus,
			ExitDestination = res.ExitDestination,
		}
	end

	return false, nil
end

local function dispatchInventoryAction(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	req: any
): (boolean, BuildProtocol.BuildOperationResponse?)
	local action = req.Action
	if
		action ~= BuildProtocol.Actions.GetInventory
		and action ~= BuildProtocol.Actions.SellInventoryItem
		and action ~= BuildProtocol.Actions.UnlinkInventoryFromBlueprints
	then
		return false, nil
	end

	local userId = player.UserId
	local curRev, curBpId = VehicleBlueprintService.GetCurrentRevision(player)

	if action == BuildProtocol.Actions.GetInventory then
		local okLoad, _, loadErrCode, loadErrMsg = InventoryService.EnsurePlayerLoaded(player)
		if not okLoad then
			return true, makeErrorResponse(
				req.ClientOpId,
				curRev,
				loadErrCode or BuildProtocol.ErrorCodes.PersistenceFailed,
				loadErrMsg or "No se pudo cargar tu inventario",
				curBpId,
				userId
			)
		end
		return true, {
			Success = true,
			ClientOpId = req.ClientOpId,
			Revision = curRev,
			BlueprintId = curBpId,
			OwnerUserId = userId,
			Inventory = InventoryService.GetPlayerSnapshot(player),
		}
	end

	-- Idempotencia para mutaciones de inventario
	if req.ClientOpId then
		local userCache = _processedOpsByUserId[userId]
		if userCache and userCache[req.ClientOpId] then
			return true, userCache[req.ClientOpId]
		end
	end

	if _playerBusyLock[userId] then
		return true, makeErrorResponse(
			req.ClientOpId,
			curRev,
			BuildProtocol.ErrorCodes.OperationInProgress,
			"Operación anterior en curso",
			curBpId,
			userId
		)
	end

	_playerBusyLock[userId] = true
	local okCall, resOrErr = pcall(function(): BuildProtocol.BuildOperationResponse
		if action == BuildProtocol.Actions.SellInventoryItem then
			local sellRes = InventoryService.SellItem(player, req.ItemId, req.Quantity, req.ItemInstanceId)
			if not sellRes.Success then
				return {
					Success = false,
					ClientOpId = req.ClientOpId,
					ErrorCode = sellRes.ErrorCode or BuildProtocol.ErrorCodes.InvalidPayload,
					ErrorMessage = sellRes.ErrorMessage or "No se pudo completar la venta",
					Revision = curRev,
					BlueprintId = curBpId,
					OwnerUserId = userId,
					BlockedInWorkshop = sellRes.BlockedInWorkshop,
					BlockedSlotIndices = sellRes.BlockedSlotIndices,
					Inventory = InventoryService.GetPlayerSnapshot(player),
				}
			end

			local syncedInv = emitInventorySync(player, curRev, curBpId, req.ClientOpId, sellRes.Snapshot)
			return {
				Success = true,
				ClientOpId = req.ClientOpId,
				Revision = curRev,
				BlueprintId = curBpId,
				OwnerUserId = userId,
				SellResult = sellRes.SellResult,
				Inventory = syncedInv,
			}
		end

		-- UnlinkInventoryFromBlueprints
		local unlinkRes = VehicleBlueprintService.UnlinkInventoryFromBlueprints(
			player,
			plot,
			req.ItemId,
			req.ItemInstanceId,
			req.TargetSlotIndices,
			req.Confirmed
		)
		if not unlinkRes.Success then
			return {
				Success = false,
				ClientOpId = req.ClientOpId,
				ErrorCode = unlinkRes.ErrorCode or BuildProtocol.ErrorCodes.InvalidPayload,
				ErrorMessage = unlinkRes.ErrorMessage or "No se pudieron desvincular las referencias",
				Revision = curRev,
				BlueprintId = curBpId,
				OwnerUserId = userId,
				ConfirmationRequired = unlinkRes.ConfirmationRequired,
				UnlinkPreview = unlinkRes.UnlinkPreview,
				Inventory = InventoryService.GetPlayerSnapshot(player),
			}
		end

		local updatedBp = unlinkRes.ActiveBlueprint or VehicleBlueprintService.GetBlueprintSnapshot(player)
		if unlinkRes.WorkshopChanged and updatedBp then
			StandPreviewService.RebuildForPlayer(player, plot, updatedBp)
		end

		local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
		local list = VehicleBlueprintService.ListBlueprints(player)
		local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
		local invSnap = InventoryService.GetPlayerSnapshot(player)
		local newRev = updatedBp.Revision
		local newBpId = updatedBp.BlueprintId

		emitSyncEvent(player, {
			Type = (if unlinkRes.WorkshopChanged
				then BuildProtocol.SyncTypes.BlueprintLoaded
				else BuildProtocol.SyncTypes.SlotLibraryUpdated) :: BuildProtocol.BlueprintSyncEventType,
			OwnerUserId = userId,
			BlueprintId = newBpId,
			Revision = newRev,
			ClientOpId = req.ClientOpId,
			Blueprint = if unlinkRes.WorkshopChanged then updatedBp else nil,
			Blueprints = list,
			Slots = slots,
			LoadedSlotIndex = loadedSlotIdx,
			WorkshopPieceCount = #updatedBp.Pieces,
			WorkshopEpoch = epoch,
			LegacyOverflowCount = overflowCount,
			LegacyOverflow = overflowList,
			HasUnsavedChanges = hasUnsaved,
			Inventory = invSnap,
		})
		emitInventorySync(player, newRev, newBpId, req.ClientOpId, invSnap)

		return {
			Success = true,
			ClientOpId = req.ClientOpId,
			Revision = newRev,
			BlueprintId = newBpId,
			OwnerUserId = userId,
			Blueprint = updatedBp,
			Blueprints = list,
			Slots = slots,
			LoadedSlotIndex = loadedSlotIdx,
			WorkshopPieceCount = #updatedBp.Pieces,
			WorkshopEpoch = epoch,
			LegacyOverflowCount = overflowCount,
			LegacyOverflow = overflowList,
			HasUnsavedChanges = hasUnsaved,
			MaxBlueprints = GameConfig.Blueprints.MaxSlots,
			UnlinkPreview = unlinkRes.UnlinkPreview,
			Inventory = invSnap,
		}
	end)
	_playerBusyLock[userId] = nil

	if not okCall then
		warn(`[BuildService] Error interno en '{action}': {tostring(resOrErr)}`)
		return true, makeErrorResponse(
			req.ClientOpId,
			curRev,
			BuildProtocol.ErrorCodes.InvalidPayload,
			"Error interno en operación de inventario",
			curBpId,
			userId
		)
	end

	local response = resOrErr :: BuildProtocol.BuildOperationResponse
	if req.ClientOpId and response.ErrorCode ~= BuildProtocol.ErrorCodes.ConfirmationRequired then
		cacheOpResponse(userId, req.ClientOpId, response)
	end
	return true, response
end

function BuildService.ProcessRequest(player: PlotService.PlayerLike, rawRequest: any): BuildProtocol.BuildOperationResponse
	if not _initialized then
		BuildService.Init()
	end

	if (type(player) ~= "table" and typeof(player) ~= "Instance") or type(player.UserId) ~= "number" then
		return makeErrorResponse(nil, 0, BuildProtocol.ErrorCodes.InvalidPayload, "Jugador inválido")
	end

	local userId = player.UserId
	if type(rawRequest) ~= "table" or getmetatable(rawRequest) ~= nil then
		-- Consumir token antes de responder para frenar spam malformado
		getOrCreateRateLimiter():Consume(userId, "Write")
		return makeErrorResponse(nil, 0, BuildProtocol.ErrorCodes.InvalidPayload, "Solicitud malformada", nil, userId)
	end

	local rawAction = rawget(rawRequest, "Action")
	local bucketKind: TokenBucket.BucketKind = if rawAction == BuildProtocol.Actions.GetBlueprint
			or rawAction == BuildProtocol.Actions.ListBlueprints
			or rawAction == BuildProtocol.Actions.ListBlueprintSlots
			or rawAction == BuildProtocol.Actions.ValidateLaunchPrep
			or rawAction == BuildProtocol.Actions.GetRuntimeState
			or rawAction == BuildProtocol.Actions.GetEngineUnits
			or rawAction == BuildProtocol.Actions.GetBoosterUnits
			or rawAction == BuildProtocol.Actions.GetInventory
			or rawAction == BuildProtocol.Actions.SetDrivingInput
		then "Read"
		else "Write"
	local rawClientOpId = rawget(rawRequest, "ClientOpId")
	local safeOpId: string? = if type(rawClientOpId) == "string" and #rawClientOpId >= 1 and #rawClientOpId <= GameConfig.Building.MaxStringLength
		then rawClientOpId
		else nil

	-- 1. Rate Limiting Token Bucket POR JUGADOR antes de cualquier inspección profunda o geométrica
	local limiter = getOrCreateRateLimiter()
	local allowed = limiter:Consume(userId, bucketKind)
	if not allowed then
		local curRev, curBpId = VehicleBlueprintService.GetCurrentRevision(player)
		return makeErrorResponse(
			safeOpId,
			curRev,
			BuildProtocol.ErrorCodes.RateLimited,
			"Demasiadas operaciones por segundo",
			curBpId or `bp_{userId}`,
			userId
		)
	end

	-- 2. Resolver estación autoritativa del servidor (nunca aceptar PlotId/OwnerUserId del cliente)
	local plot = PlotService.GetPlotByPlayer(player)

	-- 3. Validación estricta de estructura, strings, profundidad, CFrame y rotación 90°
	local reqValid, validatedReq, valErrCode, valErrMsg = BuildPayloadValidator.ValidateRequest(
		rawRequest,
		userId,
		if plot then plot.PlotId else nil
	)
	if not reqValid or not validatedReq then
		local curRev, curBpId = VehicleBlueprintService.GetCurrentRevision(player)
		return makeErrorResponse(
			safeOpId,
			curRev,
			valErrCode or BuildProtocol.ErrorCodes.InvalidPayload,
			valErrMsg or "Payload inválido",
			curBpId,
			userId
		)
	end

	-- 4. Verificar propiedad efectiva de la estación en el servidor
	if not plot then
		return makeErrorResponse(
			validatedReq.ClientOpId,
			0,
			BuildProtocol.ErrorCodes.NoAssignedPlot,
			"No tenés una estación asignada",
			nil,
			userId
		)
	end
	if not PlotService.IsOwner(player, plot.PlotId) then
		return makeErrorResponse(
			validatedReq.ClientOpId,
			0,
			BuildProtocol.ErrorCodes.NotPlotOwner,
			"No sos propietario de esta estación",
			nil,
			userId
		)
	end

	local rawExpectedBpId = rawget(rawRequest, "ExpectedBlueprintId")
	if rawExpectedBpId ~= nil then
		local curRev, curBpId = VehicleBlueprintService.GetCurrentRevision(player)
		if
			type(rawExpectedBpId) ~= "string"
			or #rawExpectedBpId == 0
			or #rawExpectedBpId > GameConfig.Building.MaxStringLength
			or (curBpId ~= nil and rawExpectedBpId ~= curBpId)
		then
			return makeErrorResponse(
				validatedReq.ClientOpId,
				curRev,
				BuildProtocol.ErrorCodes.StaleBlueprintRevision,
				"El blueprint activo cambió mientras se enviaba la edición",
				curBpId,
				userId
			)
		end
	end

	local handledP24, p24Response = dispatchPhase24Action(player, plot, validatedReq)
	if handledP24 and p24Response then
		return p24Response
	end

	local handledP31, p31Response = dispatchPhase31Action(player, validatedReq)
	if handledP31 and p31Response then
		return p31Response
	end

	local handledInv, invResponse = dispatchInventoryAction(player, plot, validatedReq)
	if handledInv and invResponse then
		return invResponse
	end

	-- 5. Idempotencia acotada para operaciones mutadoras con ClientOpId
	if validatedReq.Action ~= "GetBlueprint" and validatedReq.ClientOpId then
		local userCache = _processedOpsByUserId[userId]
		if userCache and userCache[validatedReq.ClientOpId] then
			return userCache[validatedReq.ClientOpId]
		end
	end

	if validatedReq.Action == "GetBlueprint" then
		InventoryService.EnsurePlayerLoaded(player)
		VehicleBlueprintService.EnsureWorkshopVisualsForPlot(player, plot)
		local snapshot = VehicleBlueprintService.GetBlueprintSnapshot(player)
		local slots, loadedSlotIdx, hasUnsaved, overflowCount, overflowList = VehicleBlueprintService.GetBlueprintSlotSummaries(player)
		local list = VehicleBlueprintService.ListBlueprints(player)
		local epoch = VehicleBlueprintService.GetWorkshopEpoch(player)
		return {
			Success = true,
			ClientOpId = validatedReq.ClientOpId,
			Revision = snapshot.Revision,
			BlueprintId = snapshot.BlueprintId,
			OwnerUserId = snapshot.OwnerUserId,
			Blueprint = snapshot,
			Blueprints = list,
			Slots = slots,
			LoadedSlotIndex = loadedSlotIdx,
			WorkshopPieceCount = #snapshot.Pieces,
			WorkshopEpoch = epoch,
			LegacyOverflowCount = overflowCount,
			LegacyOverflow = overflowList,
			HasUnsavedChanges = hasUnsaved,
			MaxBlueprints = GameConfig.Blueprints.MaxSlots,
			RuntimeStatus = VehicleLaunchService.GetRuntimeState(player),
			Inventory = InventoryService.GetPlayerSnapshot(player),
		}
	end

	if not VehicleLifecycleService.CanEditBlueprint(player) then
		local curRev, curBpId = VehicleBlueprintService.GetCurrentRevision(player)
		return makeErrorResponse(
			validatedReq.ClientOpId,
			curRev,
			BuildProtocol.ErrorCodes.InvalidPlayerState,
			"El editor de construcción está deshabilitado mientras el vehículo está activo",
			curBpId,
			userId
		)
	end

	-- Bloqueo exclusivo por UserId: las operaciones de un jugador no bloquean a los demás
	if _playerBusyLock[userId] then
		local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
		return makeErrorResponse(
			validatedReq.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.RateLimited,
			"Operación anterior en curso",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	_playerBusyLock[userId] = true
	local ok, responseOrErr = pcall(function(): BuildProtocol.BuildOperationResponse
		if validatedReq.Action == "PlacePiece" then
			return handlePlacePiece(player, plot, validatedReq)
		elseif validatedReq.Action == "RemovePiece" then
			return handleRemovePiece(player, plot, validatedReq)
		elseif validatedReq.Action == "UpdatePieceConfig" then
			return handleUpdatePieceConfig(player, plot, validatedReq)
		else
			return handleTransformPiece(player, plot, validatedReq)
		end
	end)
	_playerBusyLock[userId] = nil

	if not ok then
		warn(`[BuildService] Internal error processing '{validatedReq.Action}': {tostring(responseOrErr)}`)
		local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
		return makeErrorResponse(
			validatedReq.ClientOpId,
			bp.Revision,
			BuildProtocol.ErrorCodes.InvalidPayload,
			"Error interno de validación",
			bp.BlueprintId,
			bp.OwnerUserId
		)
	end

	local response = responseOrErr :: BuildProtocol.BuildOperationResponse
	if validatedReq.ClientOpId then
		cacheOpResponse(userId, validatedReq.ClientOpId, response)
	end

	return response
end

function BuildService.ClearPlayer(playerOrUserId: PlotService.PlayerLike | number)
	local userId = if type(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	_processedOpsByUserId[userId] = nil
	_processedOpOrderByUserId[userId] = nil
	_blueprintOpCacheByUserId[userId] = nil
	_playerBusyLock[userId] = nil
	if _rateLimiter then
		_rateLimiter:ClearPlayer(userId)
	end
	ConnectionService.ClearPlayer(userId)
end

function BuildService.RegisterSyncListener(listener: SyncListener): () -> ()
	table.insert(_syncListeners, listener)
	return function()
		local idx = table.find(_syncListeners, listener)
		if idx then
			table.remove(_syncListeners, idx)
		end
	end
end

function BuildService.GetTrackedPlayerStats(): { CachedOpPlayers: number, RateLimiterPlayers: number, PlotExcludeCached: number }
	local opPlayers = 0
	for _ in pairs(_processedOpsByUserId) do
		opPlayers += 1
	end
	local plotCount = 0
	for _ in pairs(_plotStaticExcludeCache) do
		plotCount += 1
	end
	return {
		CachedOpPlayers = opPlayers,
		RateLimiterPlayers = if _rateLimiter then _rateLimiter:GetTrackedPlayerCount() else 0,
		PlotExcludeCached = plotCount,
	}
end

function BuildService._SetRateLimitClockForTests(clockFn: (() -> number)?)
	_clockOverride = clockFn
	_rateLimiter = nil
	getOrCreateRateLimiter()
end

function BuildService.Init()
	if _initialized then
		return
	end

	ConnectionService.Init()
	InventoryService.Init()
	VehicleBlueprintService.Init()
	VehicleLifecycleService.Init()
	VehicleLaunchService.Init()
	getOrCreateRateLimiter()

	InventoryService.RegisterRuntimeStateChecker(function(userId: number)
		return not VehicleLifecycleService.CanEditBlueprint(userId)
	end)

	if not _unsubLifecycleState then
		_unsubLifecycleState = VehicleLifecycleService.OnStateChanged(function(playerLikeOrUserId, snapshot)
			local userId = if type(playerLikeOrUserId) == "number" then playerLikeOrUserId else playerLikeOrUserId.UserId
			local targetPlayer: PlotService.PlayerLike? = if type(playerLikeOrUserId) == "number"
				then Players:GetPlayerByUserId(userId)
				else playerLikeOrUserId
			if not targetPlayer then
				targetPlayer = { UserId = userId, Name = `Player_{userId}` } :: PlotService.PlayerLike
			end
			local curRev, curBpId = VehicleBlueprintService.GetCurrentRevision(targetPlayer :: PlotService.PlayerLike)
			emitSyncEvent(targetPlayer :: PlotService.PlayerLike, {
				Type = BuildProtocol.SyncTypes.RuntimeStateUpdated :: BuildProtocol.BlueprintSyncEventType,
				OwnerUserId = userId,
				BlueprintId = curBpId or "",
				Revision = curRev,
				RuntimeStatus = snapshot,
			})
		end)
	end

	if not _unsubPlotAssigned then
		_unsubPlotAssigned = PlotService.OnPlotAssigned(function(playerLike, plotRecord)
			if typeof(playerLike) == "Instance" and playerLike:IsA("Player") then
				task.spawn(function()
					InventoryService.EnsurePlayerLoaded(playerLike)
					VehicleBlueprintService.EnsureWorkshopVisualsForPlot(playerLike, plotRecord)
				end)
			end
		end)
	end

	if not _unsubPlotReleased then
		_unsubPlotReleased = PlotService.OnPlotReleased(function(playerLike, plotRecord)
			BuildService.ClearPlayer(playerLike)
			if plotRecord and plotRecord.Model then
				_plotStaticExcludeCache[plotRecord.Model] = nil
			end
			emitSyncEvent(playerLike, {
				Type = "BlueprintReset",
				OwnerUserId = playerLike.UserId,
				BlueprintId = `bp_{playerLike.UserId}`,
				Revision = 0,
				Blueprint = {
					BlueprintId = `bp_{playerLike.UserId}`,
					OwnerUserId = playerLike.UserId,
					Revision = 0,
					Pieces = {},
					Connections = {},
				},
			})
		end)
	end

	local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
	local remotesFolder = sharedFolder:FindFirstChild("Remotes")
	if not remotesFolder then
		local folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = sharedFolder
		remotesFolder = folder
	end

	local reqRemote = remotesFolder:FindFirstChild(BuildProtocol.RemoteFunctionName)
	if not reqRemote or not reqRemote:IsA("RemoteFunction") then
		if reqRemote then
			reqRemote:Destroy()
		end
		local rf = Instance.new("RemoteFunction")
		rf.Name = BuildProtocol.RemoteFunctionName
		rf.Parent = remotesFolder
		reqRemote = rf
	end

	local syncRemote = remotesFolder:FindFirstChild(BuildProtocol.SyncRemoteEventName)
	if not syncRemote or not syncRemote:IsA("RemoteEvent") then
		if syncRemote then
			syncRemote:Destroy()
		end
		local re = Instance.new("RemoteEvent")
		re.Name = BuildProtocol.SyncRemoteEventName
		re.Parent = remotesFolder
		syncRemote = re
	end

	pcall(function()
		(reqRemote :: RemoteFunction).OnServerInvoke = function(player: Player, rawRequest: any)
			return BuildService.ProcessRequest(player, rawRequest)
		end
	end)

	_requestRemote = reqRemote :: RemoteFunction
	_syncRemote = syncRemote :: RemoteEvent
	_initialized = true
end

function BuildService.Start()
	if _started then
		return
	end
	if not _initialized then
		BuildService.Init()
	end

	table.insert(
		_connections,
		Players.PlayerRemoving:Connect(function(player)
			BuildService.ClearPlayer(player)
		end)
	)

	for _, player in ipairs(Players:GetPlayers()) do
		local plot = PlotService.GetPlotByPlayer(player)
		if plot then
			task.spawn(function()
				VehicleBlueprintService.EnsureWorkshopVisualsForPlot(player, plot)
			end)
		end
	end

	_started = true
end

function BuildService._ResetForTests()
	for _, conn in ipairs(_connections) do
		conn:Disconnect()
	end
	table.clear(_connections)
	if _unsubPlotAssigned then
		_unsubPlotAssigned()
		_unsubPlotAssigned = nil
	end
	if _unsubPlotReleased then
		_unsubPlotReleased()
		_unsubPlotReleased = nil
	end
	if _unsubLifecycleState then
		_unsubLifecycleState()
		_unsubLifecycleState = nil
	end
	table.clear(_syncListeners)
	table.clear(_processedOpsByUserId)
	table.clear(_processedOpOrderByUserId)
	table.clear(_blueprintOpCacheByUserId)
	_bpClearHookRegistered = false
	table.clear(_playerBusyLock)
	table.clear(_plotStaticExcludeCache)
	_clockOverride = nil
	if _rateLimiter then
		_rateLimiter:ResetAll()
		_rateLimiter = nil
	end
	_initialized = false
	_started = false
end

return BuildService
