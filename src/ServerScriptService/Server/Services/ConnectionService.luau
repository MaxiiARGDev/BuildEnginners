--!strict
--[=[
	ConnectionService
	Servicio autoritativo de servidor para extracción de geometría/attachments inmutables,
	validación optimizada de conexiones con índice espacial AABB por jugador y verificación
	de integridad estructural (grafo conexo) al eliminar piezas.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type CachedItemGeometry = {
	ItemId: string,
	Size: Vector3,
	Attachments: { ConnectionMath.AttachmentSpec },
	PartBoxes: { VehicleTypes.PartBoxSpec },
	BoundsMin: Vector3,
	BoundsMax: Vector3,
}

type PlayerConnectionCache = {
	Revision: number,
	HasGraph: boolean,
	SpatialIndex: ConnectionMath.SpatialIndex,
	SpecsById: { [string]: ConnectionMath.PieceGeometrySpec },
	NeighborsById: { [string]: { [string]: boolean } },
	NeighborCountById: { [string]: number },
}

local ConnectionService = {
	Name = "ConnectionService",
}

local _geometryByItemId: { [string]: CachedItemGeometry } = {}
local _assetsRoot: Instance? = nil
local _playerCaches: { [number]: PlayerConnectionCache } = {}
local _connections: { RBXScriptConnection } = {}
local _initialized = false
local _started = false

local function freezeAttachmentList(atts: { ConnectionMath.AttachmentSpec }): { ConnectionMath.AttachmentSpec }
	local frozen: { ConnectionMath.AttachmentSpec } = table.create(#atts)
	for i, att in ipairs(atts) do
		frozen[i] = table.freeze({
			Name = att.Name,
			LocalPosition = att.LocalPosition,
			LocalNormal = att.LocalNormal,
		})
	end
	return table.freeze(frozen)
end

local function freezePartBoxList(boxes: { VehicleTypes.PartBoxSpec }): { VehicleTypes.PartBoxSpec }
	local frozen: { VehicleTypes.PartBoxSpec } = table.create(#boxes)
	for i, box in ipairs(boxes) do
		frozen[i] = table.freeze({
			LocalCFrame = box.LocalCFrame,
			Size = box.Size,
		})
	end
	return table.freeze(frozen)
end

local function makePreparedSpec(
	instanceId: string,
	itemId: string,
	localCFrame: CFrame,
	geom: CachedItemGeometry
): ConnectionMath.PieceGeometrySpec
	local spec: ConnectionMath.PieceGeometrySpec = {
		InstanceId = instanceId,
		ItemId = itemId,
		LocalCFrame = localCFrame,
		Size = geom.Size,
		Attachments = geom.Attachments,
		PartBoxes = geom.PartBoxes,
	}
	return ConnectionMath.PreparePieceSpec(spec)
end

local function addEdgeToCache(cache: PlayerConnectionCache, a: string, b: string)
	if a == b then
		return
	end
	local adjA = cache.NeighborsById[a]
	if not adjA then
		adjA = {}
		cache.NeighborsById[a] = adjA
		cache.NeighborCountById[a] = 0
	end
	if not adjA[b] then
		adjA[b] = true
		cache.NeighborCountById[a] = (cache.NeighborCountById[a] or 0) + 1
	end

	local adjB = cache.NeighborsById[b]
	if not adjB then
		adjB = {}
		cache.NeighborsById[b] = adjB
		cache.NeighborCountById[b] = 0
	end
	if not adjB[a] then
		adjB[a] = true
		cache.NeighborCountById[b] = (cache.NeighborCountById[b] or 0) + 1
	end
end

local function resolveItemGeometry(itemId: string): CachedItemGeometry?
	local cached = _geometryByItemId[itemId]
	if cached then
		return cached
	end
	local def = ItemRegistry.TryGet(itemId)
	local assetsRoot = _assetsRoot or ServerStorage:FindFirstChild("ItemAssets")
	if not def or not assetsRoot then
		return nil
	end
	local model = ItemRegistry.ResolveModel(assetsRoot, def)
	if not model then
		return nil
	end
	local attachments, partSize, partBoxes, boundsMin, boundsMax = ConnectionMath.ExtractModelGeometry(model)
	return table.freeze({
		ItemId = def.Id,
		Size = partSize,
		Attachments = freezeAttachmentList(attachments),
		PartBoxes = freezePartBoxList(partBoxes),
		BoundsMin = boundsMin,
		BoundsMax = boundsMax,
	})
end

local function buildPlayerCache(
	ownerUserId: number,
	pieces: { VehicleTypes.BlueprintPiece },
	connections: { VehicleTypes.BlueprintConnection }?,
	revision: number
): PlayerConnectionCache
	local spatial = ConnectionMath.CreateSpatialIndex()
	local specsById: { [string]: ConnectionMath.PieceGeometrySpec } = {}
	local neighborsById: { [string]: { [string]: boolean } } = {}
	local neighborCountById: { [string]: number } = {}

	for _, piece in ipairs(pieces) do
		local geom = resolveItemGeometry(piece.ItemId)
		if geom then
			local spec = makePreparedSpec(piece.InstanceId, piece.ItemId, piece.LocalCFrame, geom)
			specsById[piece.InstanceId] = spec
			spatial:Insert(spec)
			neighborsById[piece.InstanceId] = {}
			neighborCountById[piece.InstanceId] = 0
		end
	end

	local cache: PlayerConnectionCache = {
		Revision = revision,
		HasGraph = connections ~= nil or #pieces == 0,
		SpatialIndex = spatial,
		SpecsById = specsById,
		NeighborsById = neighborsById,
		NeighborCountById = neighborCountById,
	}

	if connections then
		for _, conn in ipairs(connections) do
			addEdgeToCache(cache, conn.FromPieceId, conn.ToPieceId)
		end
	end

	_playerCaches[ownerUserId] = cache
	return cache
end

local function ensureCacheForPlacement(
	ownerUserId: number,
	existingPieces: { VehicleTypes.BlueprintPiece },
	blueprintRevision: number?,
	existingConnections: { VehicleTypes.BlueprintConnection }?
): PlayerConnectionCache
	local cache = _playerCaches[ownerUserId]
	local rev = blueprintRevision or -1
	if
		cache
		and cache.Revision == rev
		and rev >= 0
		and cache.SpatialIndex:Count() == #existingPieces
	then
		local validForPieces = true
		for _, piece in ipairs(existingPieces) do
			local cachedSpec = cache.SpecsById[piece.InstanceId]
			if
				not cachedSpec
				or cachedSpec.ItemId ~= piece.ItemId
				or (cachedSpec.LocalCFrame.Position - piece.LocalCFrame.Position).Magnitude > 1e-4
			then
				validForPieces = false
				break
			end
		end
		if validForPieces then
			return cache
		end
	end
	return buildPlayerCache(ownerUserId, existingPieces, existingConnections, rev)
end

function ConnectionService.Init(options: { ItemAssetsRoot: Instance? }?)
	if _initialized then
		return
	end

	ItemRegistry.Init()
	local assetsRoot = (options and options.ItemAssetsRoot) or ServerStorage:WaitForChild("ItemAssets")
	_assetsRoot = assetsRoot
	ItemRegistry.NormalizeAssets(assetsRoot)

	table.clear(_geometryByItemId)
	for _, def in ipairs(ItemRegistry.GetAll()) do
		local model = ItemRegistry.ResolveModel(assetsRoot, def)
		if not model then
			error(`[ConnectionService] Missing model '{ItemRegistry.GetAssetFolder(def)}/{def.Model}' for '{def.Id}'`)
		end

		local attachments, partSize, partBoxes, boundsMin, boundsMax = ConnectionMath.ExtractModelGeometry(model)
		_geometryByItemId[def.Id] = table.freeze({
			ItemId = def.Id,
			Size = partSize,
			Attachments = freezeAttachmentList(attachments),
			PartBoxes = freezePartBoxList(partBoxes),
			BoundsMin = boundsMin,
			BoundsMax = boundsMax,
		})
	end

	_initialized = true
end

function ConnectionService.Start()
	if _started then
		return
	end
	if not _initialized then
		ConnectionService.Init()
	end

	table.insert(
		_connections,
		Players.PlayerRemoving:Connect(function(player)
			ConnectionService.ClearPlayer(player.UserId)
		end)
	)

	_started = true
end

function ConnectionService.GetItemGeometry(itemId: string): CachedItemGeometry?
	if not _initialized then
		ConnectionService.Init()
	end
	return resolveItemGeometry(itemId)
end

function ConnectionService.BuildPieceGeometrySpecs(pieces: { VehicleTypes.BlueprintPiece }): { ConnectionMath.PieceGeometrySpec }
	if not _initialized then
		ConnectionService.Init()
	end

	local list: { ConnectionMath.PieceGeometrySpec } = table.create(#pieces)
	for _, piece in ipairs(pieces) do
		local geom = resolveItemGeometry(piece.ItemId)
		if geom then
			table.insert(list, makePreparedSpec(piece.InstanceId, piece.ItemId, piece.LocalCFrame, geom))
		end
	end
	return list
end

function ConnectionService.NotifyPieceAdded(
	ownerUserId: number,
	newRevision: number,
	piece: VehicleTypes.BlueprintPiece,
	newConnections: { VehicleTypes.BlueprintConnection }
)
	local geom = resolveItemGeometry(piece.ItemId)
	if not geom then
		return
	end
	local cache = _playerCaches[ownerUserId]
	if not cache then
		cache = buildPlayerCache(ownerUserId, { piece }, newConnections, newRevision)
		return
	end

	local spec = makePreparedSpec(piece.InstanceId, piece.ItemId, piece.LocalCFrame, geom)
	cache.SpecsById[piece.InstanceId] = spec
	cache.SpatialIndex:Insert(spec)
	if not cache.NeighborsById[piece.InstanceId] then
		cache.NeighborsById[piece.InstanceId] = {}
		cache.NeighborCountById[piece.InstanceId] = 0
	end
	for _, conn in ipairs(newConnections) do
		addEdgeToCache(cache, conn.FromPieceId, conn.ToPieceId)
	end
	cache.Revision = newRevision
end

function ConnectionService.NotifyPieceTransformed(
	ownerUserId: number,
	newRevision: number,
	updatedPiece: VehicleTypes.BlueprintPiece,
	newPieceConnections: { VehicleTypes.BlueprintConnection }
)
	local cache = _playerCaches[ownerUserId]
	if not cache then
		return
	end
	local geom = resolveItemGeometry(updatedPiece.ItemId)
	if not geom then
		return
	end

	local pieceId = updatedPiece.InstanceId
	cache.SpatialIndex:Remove(pieceId)

	local oldAdj = cache.NeighborsById[pieceId]
	if oldAdj then
		for neighborId in pairs(oldAdj) do
			local neighborAdj = cache.NeighborsById[neighborId]
			if neighborAdj and neighborAdj[pieceId] then
				neighborAdj[pieceId] = nil
				cache.NeighborCountById[neighborId] = math.max(0, (cache.NeighborCountById[neighborId] or 1) - 1)
			end
		end
	end
	cache.NeighborsById[pieceId] = {}
	cache.NeighborCountById[pieceId] = 0

	local spec = makePreparedSpec(pieceId, updatedPiece.ItemId, updatedPiece.LocalCFrame, geom)
	cache.SpecsById[pieceId] = spec
	cache.SpatialIndex:Insert(spec)

	for _, conn in ipairs(newPieceConnections) do
		addEdgeToCache(cache, conn.FromPieceId, conn.ToPieceId)
	end
	cache.Revision = newRevision
end

--[=[
	Valida que transformar una pieza existente a `newLocalCFrame` no genere superposiciones.
	En Fase 2.4.2 permite separar piezas o dividir el vehículo en múltiples ensamblajes o piezas sueltas;
	devuelve las conexiones explícitas válidas en la nueva posición (pueden ser 0).
]=]
function ConnectionService.ValidateTransformConnections(
	pieceInstanceId: string,
	itemId: string,
	newLocalCFrame: CFrame,
	existingPieces: { VehicleTypes.BlueprintPiece },
	ownerUserId: number?,
	blueprintRevision: number?,
	existingConnections: { VehicleTypes.BlueprintConnection }?
): (boolean, { VehicleTypes.BlueprintConnection }, string?, string?)
	if not _initialized then
		ConnectionService.Init()
	end

	local geom = resolveItemGeometry(itemId)
	if not geom then
		return false, {}, BuildProtocol.ErrorCodes.UnknownItem, "UnknownItem"
	end

	local candidateSpec = makePreparedSpec(pieceInstanceId, itemId, newLocalCFrame, geom)
	local existingSpecs: { ConnectionMath.PieceGeometrySpec } = {}
	local spatialIndex: ConnectionMath.SpatialIndex? = nil

	if ownerUserId ~= nil and blueprintRevision ~= nil then
		local cache = ensureCacheForPlacement(ownerUserId, existingPieces, blueprintRevision, existingConnections)
		spatialIndex = cache.SpatialIndex
	else
		existingSpecs = ConnectionService.BuildPieceGeometrySpecs(existingPieces)
	end

	local overlaps, blocker = ConnectionMath.AnyOverlap(candidateSpec, existingSpecs, nil, spatialIndex)
	if overlaps and blocker then
		return false, {}, BuildProtocol.ErrorCodes.PieceOverlap, `Overlaps:{blocker.InstanceId}[{blocker.ItemId}]`
	end

	if #existingPieces <= 1 then
		return true, {}, nil, nil
	end

	local newConnections = ConnectionMath.FindCompatibleConnections(candidateSpec, existingSpecs, nil, nil, spatialIndex)
	return true, newConnections, nil, nil
end

function ConnectionService.NotifyPieceRemoved(
	ownerUserId: number,
	newRevision: number,
	pieceInstanceId: string
)
	local cache = _playerCaches[ownerUserId]
	if not cache then
		return
	end

	cache.SpatialIndex:Remove(pieceInstanceId)
	cache.SpecsById[pieceInstanceId] = nil

	local adj = cache.NeighborsById[pieceInstanceId]
	if adj then
		for neighborId in pairs(adj) do
			local neighborAdj = cache.NeighborsById[neighborId]
			if neighborAdj and neighborAdj[pieceInstanceId] then
				neighborAdj[pieceInstanceId] = nil
				cache.NeighborCountById[neighborId] = math.max(0, (cache.NeighborCountById[neighborId] or 1) - 1)
			end
		end
		cache.NeighborsById[pieceInstanceId] = nil
		cache.NeighborCountById[pieceInstanceId] = nil
	end
	cache.Revision = newRevision
end

--[=[
	Valida que una pieza candidata no se superponga con piezas existentes.
	En Fase 2.4.2 se permiten piezas desconectadas o ensamblajes separados; devuelve
	las conexiones compatibles encontradas (pueden ser 0).
]=]
function ConnectionService.ValidatePlacementConnections(
	candidateInstanceId: string,
	itemId: string,
	localCFrame: CFrame,
	existingPieces: { VehicleTypes.BlueprintPiece },
	ownerUserId: number?,
	blueprintRevision: number?,
	existingConnections: { VehicleTypes.BlueprintConnection }?
): (boolean, { VehicleTypes.BlueprintConnection }, string?, string?)
	if not _initialized then
		ConnectionService.Init()
	end

	local geom = resolveItemGeometry(itemId)
	if not geom then
		return false, {}, BuildProtocol.ErrorCodes.UnknownItem, "UnknownItem"
	end

	local candidateSpec = makePreparedSpec(candidateInstanceId, itemId, localCFrame, geom)
	local existingSpecs: { ConnectionMath.PieceGeometrySpec } = {}
	local spatialIndex: ConnectionMath.SpatialIndex? = nil

	if ownerUserId ~= nil and blueprintRevision ~= nil then
		local cache = ensureCacheForPlacement(ownerUserId, existingPieces, blueprintRevision, existingConnections)
		spatialIndex = cache.SpatialIndex
	else
		existingSpecs = ConnectionService.BuildPieceGeometrySpecs(existingPieces)
	end

	local overlaps, blocker = ConnectionMath.AnyOverlap(candidateSpec, existingSpecs, nil, spatialIndex)
	if overlaps and blocker then
		return false, {}, BuildProtocol.ErrorCodes.PieceOverlap, `Overlaps:{blocker.InstanceId}[{blocker.ItemId}]`
	end

	if #existingPieces == 0 then
		return true, {}, nil, nil
	end

	local connections = ConnectionMath.FindCompatibleConnections(candidateSpec, existingSpecs, nil, nil, spatialIndex)
	return true, connections, nil, nil
end

--[=[
	Verifica que la pieza exista en el blueprint.
	En Fase 2.4.2 se permite eliminar cualquier pieza aunque divida el vehículo en múltiples grupos.
]=]
function ConnectionService.CanRemovePiece(
	blueprint: VehicleTypes.VehicleBlueprint,
	pieceInstanceId: string
): (boolean, string?)
	for _, piece in ipairs(blueprint.Pieces) do
		if piece.InstanceId == pieceInstanceId then
			return true, nil
		end
	end

	return false, BuildProtocol.ErrorCodes.PieceNotFound
end

--[=[
	Analiza todas las componentes conexas de un blueprint utilizando su grafo explícito de conexiones
	y geometrías reales cacheadas.
]=]
function ConnectionService.AnalyzeBlueprintAssemblies(
	blueprint: VehicleTypes.VehicleBlueprint
): VehicleTypes.AssemblyAnalysis
	if not _initialized then
		ConnectionService.Init()
	end
	local specs = ConnectionService.BuildPieceGeometrySpecs(blueprint.Pieces)
	local specsById: { [string]: ConnectionMath.PieceGeometrySpec } = {}
	for _, spec in ipairs(specs) do
		specsById[spec.InstanceId] = spec
	end
	local preferred = if blueprint.Metadata then blueprint.Metadata.PrimaryAssemblyGroupId else nil
	return ConnectionMath.AnalyzeAssemblies(blueprint.Pieces, blueprint.Connections, preferred, specsById)
end

--[=[
	Reconstruye y sanea de forma segura el grafo `blueprint.Connections`:
	  - Elimina referencias a `PieceId` inexistentes, auto-lazos y aristas duplicadas.
	  - Opcionalmente valida aristas existentes contra la geometría real (descartando piezas separadas).
	  - Reconstruye únicamente conexiones faltantes geométricamente válidas (attachments `Conn_*` o caras OBB en contacto
	    dentro de tolerancia), sin unir jamás piezas separadas físicamente.
]=]
function ConnectionService.ReconcileBlueprintConnections(
	blueprint: VehicleTypes.VehicleBlueprint,
	options: { ValidateExistingGeometry: boolean?, RebuildMissing: boolean? }?
): {
	AddedCount: number,
	RemovedInvalidCount: number,
	DeduplicatedCount: number,
	PrunedDetachedCount: number,
	TotalConnections: number,
}
	if not _initialized then
		ConnectionService.Init()
	end

	local validateExisting = if options and options.ValidateExistingGeometry ~= nil
		then options.ValidateExistingGeometry
		else true
	local rebuildMissing = if options and options.RebuildMissing ~= nil
		then options.RebuildMissing
		else true

	local validPieceById: { [string]: VehicleTypes.BlueprintPiece } = {}
	local specs: { ConnectionMath.PieceGeometrySpec } = table.create(#blueprint.Pieces)
	local specsById: { [string]: ConnectionMath.PieceGeometrySpec } = {}
	local spatial = ConnectionMath.CreateSpatialIndex()

	for _, piece in ipairs(blueprint.Pieces) do
		local geom = resolveItemGeometry(piece.ItemId)
		if geom then
			validPieceById[piece.InstanceId] = piece
			local spec = makePreparedSpec(piece.InstanceId, piece.ItemId, piece.LocalCFrame, geom)
			specsById[piece.InstanceId] = spec
			table.insert(specs, spec)
			spatial:Insert(spec)
		end
	end

	local cleanConnections: { VehicleTypes.BlueprintConnection } = {}
	local seenEdges: { [string]: boolean } = {}
	local removedInvalid = 0
	local deduplicated = 0
	local prunedDetached = 0
	local added = 0

	for _, conn in ipairs(blueprint.Connections or {}) do
		local fromId = conn.FromPieceId
		local toId = conn.ToPieceId
		if
			type(fromId) ~= "string"
			or type(toId) ~= "string"
			or type(conn.FromAttachment) ~= "string"
			or type(conn.ToAttachment) ~= "string"
			or fromId == toId
			or not validPieceById[fromId]
			or not validPieceById[toId]
		then
			removedInvalid += 1
			continue
		end

		local edgeKey = if fromId < toId then `{fromId}|{toId}` else `{toId}|{fromId}`
		if seenEdges[edgeKey] then
			deduplicated += 1
			continue
		end

		if validateExisting then
			local specA = specsById[fromId]
			local specB = specsById[toId]
			if
				ConnectionMath.SpecsOverlap(specA, specB)
				or #ConnectionMath.FindCompatibleConnections(specA, { specB }) == 0
			then
				prunedDetached += 1
				continue
			end
		end

		seenEdges[edgeKey] = true
		table.insert(cleanConnections, {
			FromPieceId = fromId,
			FromAttachment = conn.FromAttachment,
			ToPieceId = toId,
			ToAttachment = conn.ToAttachment,
		})
	end

	if rebuildMissing and #specs >= 2 then
		for _, piece in ipairs(blueprint.Pieces) do
			local specA = specsById[piece.InstanceId]
			if specA then
				local candidates = ConnectionMath.FindCompatibleConnections(specA, specs, nil, nil, spatial)
				for _, candConn in ipairs(candidates) do
					local fromId = candConn.FromPieceId
					local toId = candConn.ToPieceId
					if fromId ~= toId and specsById[toId] then
						local edgeKey = if fromId < toId then `{fromId}|{toId}` else `{toId}|{fromId}`
						if not seenEdges[edgeKey] and not ConnectionMath.SpecsOverlap(specA, specsById[toId]) then
							seenEdges[edgeKey] = true
							table.insert(cleanConnections, {
								FromPieceId = fromId,
								FromAttachment = candConn.FromAttachment,
								ToPieceId = toId,
								ToAttachment = candConn.ToAttachment,
							})
							added += 1
						end
					end
				end
			end
		end
	end

	blueprint.Connections = cleanConnections
	return {
		AddedCount = added,
		RemovedInvalidCount = removedInvalid,
		DeduplicatedCount = deduplicated,
		PrunedDetachedCount = prunedDetached,
		TotalConnections = #cleanConnections,
	}
end

--[=[
	Genera un reporte diagnóstico completo del grafo de conexiones, grupos y motivos de desconexión.
]=]
function ConnectionService.InspectBlueprintConnections(blueprint: VehicleTypes.VehicleBlueprint): {
	BlueprintId: string,
	TotalPieces: number,
	TotalConnections: number,
	GroupCount: number,
	PrimaryGroupId: string?,
	DriverSeatPieceIds: { string },
	ExcludedPieceIds: { string },
	Groups: { { GroupId: string, PieceCount: number, PieceIds: { string }, HasDriverSeat: boolean } },
	DisconnectReasons: { [string]: string },
}
	if not _initialized then
		ConnectionService.Init()
	end

	local specs = ConnectionService.BuildPieceGeometrySpecs(blueprint.Pieces)
	local specsById: { [string]: ConnectionMath.PieceGeometrySpec } = {}
	for _, s in ipairs(specs) do
		specsById[s.InstanceId] = s
	end

	local analysis = ConnectionService.AnalyzeBlueprintAssemblies(blueprint)
	local seatIds: { string } = {}
	for _, piece in ipairs(blueprint.Pieces) do
		if piece.ItemId == GameConfig.LaunchPrep.DriverSeatItemId then
			table.insert(seatIds, piece.InstanceId)
		end
	end

	local groupsSummary: { { GroupId: string, PieceCount: number, PieceIds: { string }, HasDriverSeat: boolean } } =
		table.create(#analysis.Groups)
	for _, grp in ipairs(analysis.Groups) do
		table.insert(groupsSummary, {
			GroupId = grp.GroupId,
			PieceCount = grp.PieceCount,
			PieceIds = table.clone(grp.PieceIds),
			HasDriverSeat = grp.HasDriverSeat,
		})
	end

	local disconnectReasons: { [string]: string } = {}
	for _, excludedId in ipairs(analysis.WorkshopPieceIds) do
		local spec = specsById[excludedId]
		if spec then
			disconnectReasons[excludedId] = ConnectionMath.DiagnoseConnectionFailure(spec, specs)
		else
			disconnectReasons[excludedId] = "MissingGeometrySpec"
		end
	end

	return {
		BlueprintId = blueprint.BlueprintId,
		TotalPieces = #blueprint.Pieces,
		TotalConnections = #blueprint.Connections,
		GroupCount = #analysis.Groups,
		PrimaryGroupId = analysis.PrimaryGroupId,
		DriverSeatPieceIds = seatIds,
		ExcludedPieceIds = table.clone(analysis.WorkshopPieceIds),
		Groups = groupsSummary,
		DisconnectReasons = disconnectReasons,
	}
end

function ConnectionService.RebuildPlayerCache(ownerUserId: number, blueprint: VehicleTypes.VehicleBlueprint)
	if not _initialized then
		ConnectionService.Init()
	end
	ConnectionService.ClearPlayer(ownerUserId)
	buildPlayerCache(ownerUserId, blueprint.Pieces, blueprint.Connections, blueprint.Revision)
end

function ConnectionService.ClearPlayer(userId: number)
	local cache = _playerCaches[userId]
	if cache then
		cache.SpatialIndex:Clear()
		_playerCaches[userId] = nil
	end
end

function ConnectionService.GetTrackedCacheCount(): number
	local count = 0
	for _ in pairs(_playerCaches) do
		count += 1
	end
	return count
end

function ConnectionService._ResetForTests()
	for _, conn in ipairs(_connections) do
		conn:Disconnect()
	end
	table.clear(_connections)
	for userId in pairs(_playerCaches) do
		ConnectionService.ClearPlayer(userId)
	end
	table.clear(_geometryByItemId)
	_assetsRoot = nil
	_initialized = false
	_started = false
end

return ConnectionService
