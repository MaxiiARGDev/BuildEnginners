--!strict
--[=[
	BuildPreviewController
	Administra el ghost 3D local (semitransparente, sin colisiones ni réplica a otros jugadores),
	aplica snap inteligente acelerado mediante índice espacial AABB y caché por revisión,
	y evita consultas redundantes de Raycast / GetPartBoundsInBox cuando la entrada no cambió.
]=]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildGrid = require(ReplicatedStorage.Shared.Building.BuildGrid)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildSnapPolicy = require(ReplicatedStorage.Shared.Building.BuildSnapPolicy)
local BuildAlignmentMath = require(ReplicatedStorage.Shared.Building.BuildAlignmentMath)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local FaceSnapMath = require(ReplicatedStorage.Shared.Building.FaceSnapMath)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BuildState = require(script.Parent.BuildState)
local BuildGridVisualizer = require(script.Parent.BuildGridVisualizer)
local BuildAlignmentGuides = require(script.Parent.BuildAlignmentGuides)
local BuildFaceSnapVisualizer = require(script.Parent.BuildFaceSnapVisualizer)

type CachedPreviewGeometry = {
	Size: Vector3,
	Attachments: { ConnectionMath.AttachmentSpec },
	PartBoxes: { VehicleTypes.PartBoxSpec },
}

type PlotExcludeCache = {
	PlotModel: Model,
	ZoneParts: { Instance },
	OverlapBase: { Instance },
}

local BuildPreviewController = {}

local _currentGhost: Model? = nil
local _currentGhostItemId: string? = nil
local _currentGhostParts: { BasePart } = {}
local _currentPieceSize: Vector3 = Vector3.new(2, 2, 2)
local _currentAttachments: { ConnectionMath.AttachmentSpec } = {}
local _currentPartBoxes: { VehicleTypes.PartBoxSpec } = {}
local _geometryCache: { [string]: CachedPreviewGeometry } = {}
local _lastAppliedColor: Color3? = nil
local _lastTargetCFrame: CFrame? = nil
local _lastTargetLocalCFrame: CFrame? = nil
local _lastValidatedBlueprintId: string? = nil
local _lastValidatedRevision: number = -1
local _lastValidatedPieceCount: number = -1
local _lastValidatedLiftH: number? = nil
local _lastValidatedLiftL: number? = nil
local _lastValidatedEpoch: number = -1
local _prevSnappedLocalPos: Vector3? = nil
local _alignmentLocks: BuildAlignmentMath.AlignmentLockState = {}
local _faceLockState: FaceSnapMath.FaceLockState = FaceSnapMath.CreateLockState()

-- Caché de especificaciones y hash espacial de piezas confirmadas del blueprint actual
local _cachedSpecsKey: string? = nil
local _cachedExistingSpecs: { ConnectionMath.PieceGeometrySpec } = {}
local _cachedSpatialIndex: ConnectionMath.SpatialIndex = ConnectionMath.CreateSpatialIndex()

-- Caché de exclusiones de plot para evitar Plot:GetDescendants() por frame
local _plotExcludeCache: PlotExcludeCache? = nil

-- Caché de último raycast para evitar repetir raycasts e índices en frames ociosos
local _lastRayOrigin: Vector3? = nil
local _lastRayDirection: Vector3? = nil
local _lastRayBlueprintId: string? = nil
local _lastRayRevision: number = -1
local _lastRayItemId: string? = nil
local _lastRayRotation: CFrame? = nil
local _lastRayMode: string? = nil
local _lastRayResolution: number? = nil
local _lastRaySmartSnap: boolean? = nil
local _lastRayFaceSnap: boolean? = nil
local _lastRayGuides: boolean? = nil
local _lastRayTool: string? = nil
local _lastRayLiftH: number? = nil
local _lastRayLiftL: number? = nil
local _lastRayEpoch: number = -1

local _raycastParams = RaycastParams.new()
_raycastParams.FilterType = Enum.RaycastFilterType.Exclude
_raycastParams.IgnoreWater = true

local _overlapParams = OverlapParams.new()
_overlapParams.FilterType = Enum.RaycastFilterType.Exclude

local function getGhostParent(): Instance
	return Workspace.CurrentCamera or Workspace
end

local function applyGhostColor(color: Color3)
	if _lastAppliedColor == color then
		return
	end
	_lastAppliedColor = color
	for _, part in ipairs(_currentGhostParts) do
		part.Color = color
	end
end

local function getOrExtractPreviewGeometry(itemId: string): CachedPreviewGeometry?
	if _geometryCache[itemId] then
		return _geometryCache[itemId]
	end

	local def = ItemRegistry.TryGet(itemId)
	if not def then
		return nil
	end

	local previewRoot = ReplicatedStorage:FindFirstChild(GameConfig.Building.PreviewAssetsFolder)
	local template = ItemRegistry.ResolveModel(previewRoot, def)
	if not template then
		return nil
	end

	local attachments, size, partBoxes = ConnectionMath.ExtractModelGeometry(template)
	local entry: CachedPreviewGeometry = {
		Size = size,
		Attachments = attachments,
		PartBoxes = partBoxes,
	}
	_geometryCache[itemId] = entry
	return entry
end

local function getExistingGeometrySpecsAndIndex(): ({ ConnectionMath.PieceGeometrySpec }, ConnectionMath.SpatialIndex)
	local pieceCount = #BuildState.BlueprintPieces
	local cacheKey = `{BuildState.BlueprintId or "local"}:{BuildState.BlueprintRevision}:{BuildState.TransitionEpoch}:{pieceCount}`
	if _cachedSpecsKey == cacheKey then
		return _cachedExistingSpecs, _cachedSpatialIndex
	end

	_cachedSpatialIndex:Clear()
	local specs: { ConnectionMath.PieceGeometrySpec } = table.create(pieceCount)
	for _, piece in ipairs(BuildState.BlueprintPieces) do
		local geom = getOrExtractPreviewGeometry(piece.ItemId)
		if geom then
			local spec: ConnectionMath.PieceGeometrySpec = ConnectionMath.PreparePieceSpec({
				InstanceId = piece.InstanceId,
				ItemId = piece.ItemId,
				LocalCFrame = piece.LocalCFrame,
				Size = geom.Size,
				Attachments = geom.Attachments,
				PartBoxes = geom.PartBoxes,
			})
			table.insert(specs, spec)
			_cachedSpatialIndex:Insert(spec)
		end
	end

	_cachedExistingSpecs = specs
	_cachedSpecsKey = cacheKey
	return _cachedExistingSpecs, _cachedSpatialIndex
end

local function getOrBuildPlotExcludeCache(plotModel: Model, buildZone: BasePart): PlotExcludeCache
	if _plotExcludeCache and _plotExcludeCache.PlotModel == plotModel and plotModel.Parent ~= nil then
		return _plotExcludeCache
	end

	local zoneParts: { Instance } = {}
	for _, desc in ipairs(plotModel:GetDescendants()) do
		if desc:IsA("BasePart") and desc:GetAttribute(GameConfig.PlotAttributes.ZoneId) ~= nil and desc ~= buildZone then
			table.insert(zoneParts, desc)
		end
	end

	local overlapBase: { Instance } = { buildZone }
	local platform = plotModel:FindFirstChild("Platform")
	if platform then
		table.insert(overlapBase, platform)
	end
	local plotOrigin = plotModel:FindFirstChild(GameConfig.PlotContainers.PlotOrigin)
	if plotOrigin then
		table.insert(overlapBase, plotOrigin)
	end
	local playerSpawn = plotModel:FindFirstChild(GameConfig.PlotContainers.PlayerSpawn)
	if playerSpawn then
		table.insert(overlapBase, playerSpawn)
	end

	local cache: PlotExcludeCache = {
		PlotModel = plotModel,
		ZoneParts = zoneParts,
		OverlapBase = overlapBase,
	}
	_plotExcludeCache = cache
	return cache
end

local function configureGhostInstance(model: Model): ({ BasePart }, Vector3)
	local parts: { BasePart } = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.CastShadow = false
			if PhysicsService:IsCollisionGroupRegistered(GameConfig.Runtime.CollisionGroups.EditorGhost) then
				descendant.CollisionGroup = GameConfig.Runtime.CollisionGroups.EditorGhost
			end
			descendant.Transparency = GameConfig.Building.GhostTransparency
			descendant.Material = Enum.Material.SmoothPlastic
			table.insert(parts, descendant)
		elseif descendant:IsA("Constraint") or descendant:IsA("WeldConstraint") then
			descendant.Enabled = false
		end
	end

	if model.PrimaryPart == nil then
		local primary = model:FindFirstChild("Primary")
		if primary and primary:IsA("BasePart") then
			model.PrimaryPart = primary
		elseif #parts > 0 then
			model.PrimaryPart = parts[1]
		end
	end

	local pieceSize = if model.PrimaryPart then model.PrimaryPart.Size else model:GetExtentsSize()
	return parts, pieceSize
end

local function cframesAlmostEqual(a: CFrame?, b: CFrame): boolean
	if not a then
		return false
	end
	if (a.Position - b.Position).Magnitude > 1e-4 then
		return false
	end
	if a.RightVector:Dot(b.RightVector) < 0.9999 or a.UpVector:Dot(b.UpVector) < 0.9999 then
		return false
	end
	return true
end

function BuildPreviewController.InvalidateRayCache()
	_lastRayOrigin = nil
	_lastRayDirection = nil
	_lastRayBlueprintId = nil
	_lastRayRevision = -1
	_lastRayItemId = nil
	_lastRayRotation = nil
	_lastRayMode = nil
	_lastRayResolution = nil
	_lastRaySmartSnap = nil
	_lastRayFaceSnap = nil
	_lastRayGuides = nil
	_lastRayTool = nil
	_lastRayLiftH = nil
	_lastRayLiftL = nil
	_lastRayEpoch = -1
	_lastTargetCFrame = nil
	_lastTargetLocalCFrame = nil
	_lastValidatedBlueprintId = nil
	_lastValidatedRevision = -1
	_lastValidatedPieceCount = -1
	_lastValidatedLiftH = nil
	_lastValidatedLiftL = nil
	_lastValidatedEpoch = -1
end

function BuildPreviewController.InvalidateWorkshopCaches()
	_cachedSpecsKey = nil
	table.clear(_cachedExistingSpecs)
	_cachedSpatialIndex:Clear()
	_plotExcludeCache = nil
	BuildPreviewController.ResetAlignmentHysteresis()
	BuildPreviewController.HideVisualHelpers()
	BuildPreviewController.InvalidateRayCache()
	if not BuildState.SelectedItemId and _currentGhost then
		BuildPreviewController.DestroyGhost()
	end
end

function BuildPreviewController.ResetAlignmentHysteresis()
	_prevSnappedLocalPos = nil
	_alignmentLocks = {}
	FaceSnapMath.ClearLockState(_faceLockState)
	BuildState.SetFaceSnapTarget(nil)
end

function BuildPreviewController.HideVisualHelpers()
	BuildGridVisualizer.Hide()
	BuildAlignmentGuides.Hide()
	BuildFaceSnapVisualizer.Hide()
	BuildState.SetFaceSnapTarget(nil)
end

function BuildPreviewController.InvalidatePlotCache()
	_plotExcludeCache = nil
	BuildPreviewController.InvalidateRayCache()
end

function BuildPreviewController.DestroyGhost()
	if _currentGhost then
		_currentGhost:Destroy()
		_currentGhost = nil
	end
	_currentGhostItemId = nil
	_currentGhostParts = {}
	_currentAttachments = {}
	_currentPartBoxes = {}
	_lastAppliedColor = nil
	BuildPreviewController.ResetAlignmentHysteresis()
	BuildPreviewController.HideVisualHelpers()
	BuildPreviewController.InvalidateRayCache()
end

function BuildPreviewController.GetItemGeometry(itemId: string): (Vector3?, { ConnectionMath.AttachmentSpec }?, { VehicleTypes.PartBoxSpec }?)
	local entry = getOrExtractPreviewGeometry(itemId)
	if not entry then
		return nil, nil, nil
	end
	return entry.Size, entry.Attachments, entry.PartBoxes
end

function BuildPreviewController.GetExistingSpecsAndIndex(): ({ ConnectionMath.PieceGeometrySpec }, ConnectionMath.SpatialIndex)
	return getExistingGeometrySpecsAndIndex()
end

function BuildPreviewController.EnsureGhostForItem(itemId: string): (Model?, string?)
	if _currentGhost and _currentGhost.Parent and _currentGhostItemId == itemId then
		return _currentGhost, nil
	end

	BuildPreviewController.DestroyGhost()

	local def = ItemRegistry.TryGet(itemId)
	if not def then
		return nil, `UnknownItem:{itemId}`
	end

	local previewRoot = ReplicatedStorage:FindFirstChild(GameConfig.Building.PreviewAssetsFolder)
	local template = ItemRegistry.ResolveModel(previewRoot, def)
	if not template then
		return nil, `MissingPreviewModel:{ItemRegistry.GetAssetFolder(def)}/{def.Model}`
	end

	local ghost = template:Clone()
	ghost.Name = `BuildGhost_{def.Id}`
	ghost:SetAttribute("IsBuildGhost", true)

	local parts, pieceSize = configureGhostInstance(ghost)
	if #parts == 0 or not ghost.PrimaryPart then
		ghost:Destroy()
		return nil, `InvalidPreviewGeometry:{def.Id}`
	end

	local geom = getOrExtractPreviewGeometry(itemId)
	local attachments = if geom then table.clone(geom.Attachments) else {}
	local partBoxes = if geom then table.clone(geom.PartBoxes) else {}

	ghost.Parent = getGhostParent()
	_currentGhost = ghost
	_currentGhostItemId = itemId
	_currentGhostParts = parts
	_currentPieceSize = pieceSize
	_currentAttachments = attachments
	_currentPartBoxes = partBoxes
	_lastAppliedColor = nil
	BuildPreviewController.InvalidateRayCache()

	return ghost, nil
end

function BuildPreviewController.ValidateCandidate(
	plotModel: Model,
	buildZone: BasePart,
	localCFrame: CFrame,
	worldCFrame: CFrame,
	pieceSize: Vector3,
	existingSpecs: { ConnectionMath.PieceGeometrySpec },
	spatialIndex: ConnectionMath.SpatialIndex?,
	options: {
		ItemId: string?,
		Attachments: { ConnectionMath.AttachmentSpec }?,
		PartBoxes: { VehicleTypes.PartBoxSpec }?,
		ExcludePieceId: string?,
	}?
): (boolean, string?, string?)
	local effectiveItemId = (options and options.ItemId) or _currentGhostItemId or ""
	local effectiveAtts = (options and options.Attachments) or _currentAttachments
	local effectiveBoxes = (options and options.PartBoxes) or _currentPartBoxes
	local excludeId = options and options.ExcludePieceId

	if effectiveItemId ~= "" and ItemRegistry.Has(effectiveItemId) then
		local rotOk, rotReason = BuildSnapPolicy.ValidateRotationForItem(effectiveItemId, localCFrame.Rotation)
		if not rotOk then
			return false, BuildProtocol.ErrorCodes.InvalidRotation, rotReason
		end
	end

	local candidateSpec: ConnectionMath.PieceGeometrySpec = ConnectionMath.PreparePieceSpec({
		InstanceId = excludeId or "__ghost__",
		ItemId = effectiveItemId,
		LocalCFrame = localCFrame,
		Size = pieceSize,
		Attachments = effectiveAtts,
		PartBoxes = effectiveBoxes,
	})

	local minBound, maxBound = ConnectionMath.ComputePieceLocalAABB(candidateSpec)
	local inBounds, boundsReason = BuildGrid.ValidateBoundsMinMax(
		buildZone.Size,
		minBound,
		maxBound,
		GameConfig.Building.DefaultZoneHeight,
		BuildState.GetAssemblyOffset()
	)
	if not inBounds then
		return false, boundsReason, nil
	end

	-- Filtrar existingSpecs cuando excluimos una pieza que se está transformando
	local activeSpecs = existingSpecs
	if excludeId then
		local filtered = {}
		for _, spec in ipairs(existingSpecs) do
			if spec.InstanceId ~= excludeId then
				table.insert(filtered, spec)
			end
		end
		activeSpecs = filtered
	end

	-- Superposición entre piezas del vehículo mediante índice espacial (AABB + SAT OBB / sub-cajas compuestas)
	local overlaps, blocker = ConnectionMath.AnyOverlap(candidateSpec, activeSpecs, nil, spatialIndex)
	if overlaps and blocker then
		return false, BuildProtocol.ErrorCodes.PieceOverlap, `Overlaps:{blocker.InstanceId}[{blocker.ItemId}]`
	end

	-- Solo consultar GetPartBoundsInBox cuando las reglas matemáticas/espaciales ya son válidas
	local plotCache = getOrBuildPlotExcludeCache(plotModel, buildZone)
	local exclude = table.clone(plotCache.OverlapBase)

	local dynamicRuntime = plotModel:FindFirstChild(GameConfig.PlotContainers.Dynamic)
	local editableVehicle = dynamicRuntime and dynamicRuntime:FindFirstChild(GameConfig.Building.EditableVehicleName)
	if editableVehicle then
		table.insert(exclude, editableVehicle)
	end
	if _currentGhost then
		table.insert(exclude, _currentGhost)
	end
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		table.insert(exclude, localPlayer.Character)
	end

	_overlapParams.FilterDescendantsInstances = exclude
	local boxesToCheck = ConnectionMath.GetEffectivePartBoxes(candidateSpec)
	for _, box in ipairs(boxesToCheck) do
		local shrunkSize = Vector3.new(
			math.max(0.1, box.Size.X - 0.08),
			math.max(0.1, box.Size.Y - 0.08),
			math.max(0.1, box.Size.Z - 0.08)
		)
		local boxWorldCF = worldCFrame * box.LocalCFrame
		local overlapping = Workspace:GetPartBoundsInBox(boxWorldCF, shrunkSize, _overlapParams)
		for _, part in ipairs(overlapping) do
			if
				part.CanCollide
				or part:FindFirstAncestor(GameConfig.PlotContainers.Decorations)
				or part:FindFirstAncestor(GameConfig.PlotContainers.Structures)
			then
				return false, `BlockedBy:{part.Name}`, nil
			end
		end
	end

	return true, nil, nil
end

local function resolvePieceIdFromInstance(inst: Instance?): string?
	local curr = inst
	while curr and curr ~= Workspace do
		local attr = curr:GetAttribute("PieceInstanceId")
		if type(attr) == "string" and attr ~= "" then
			return attr
		end
		curr = curr.Parent
	end
	return nil
end

function BuildPreviewController.UpdateAtWorldPoint(
	worldHitPos: Vector3,
	worldHitNormal: Vector3?,
	extraContext: {
		TargetPieceId: string?,
		RayOrigin: Vector3?,
		RayDirection: Vector3?,
	}?
): (boolean, CFrame?)
	if not BuildState.IsActive or not BuildState.SelectedItemId then
		BuildPreviewController.DestroyGhost()
		return false, nil
	end

	local plotModel = BuildState.AssignedPlot
	local buildZone = BuildState.BuildZone
	if not plotModel or not buildZone then
		BuildPreviewController.DestroyGhost()
		return false, nil
	end

	local ghost, err = BuildPreviewController.EnsureGhostForItem(BuildState.SelectedItemId)
	if not ghost then
		BuildState.SetError(err)
		return false, nil
	end

	local effectivePosMode = BuildSnapPolicy.NormalizePositionMode(BuildState.PositionMode)
	local effectiveGridStep = BuildSnapPolicy.NormalizeGridResolution(BuildState.GridResolution)
	local liftOffset = BuildState.GetAssemblyOffset()
	local offsetCF = BuildState.GetAssemblyOffsetCFrame()
	local effectiveZoneCF = buildZone.CFrame * offsetCF

	local gridSnap = BuildGrid.ComputeSnappedCFrame({
		BuildZoneCFrame = effectiveZoneCF,
		BuildZoneSize = buildZone.Size,
		WorldHitPosition = worldHitPos,
		WorldHitNormal = worldHitNormal,
		PieceSize = _currentPieceSize,
		RelativeRotation = BuildState.RelativeRotation,
		PositionMode = effectivePosMode,
		GridSize = effectiveGridStep,
		PrevSnappedLocalPos = _prevSnappedLocalPos,
		HysteresisRatio = 0.08,
		LiftHeightOffset = liftOffset.HeightOffset,
	})
	_prevSnappedLocalPos = gridSnap.LocalPosition

	local existingSpecs, spatialIndex = getExistingGeometrySpecsAndIndex()
	local floorY = -buildZone.Size.Y * 0.5 - liftOffset.HeightOffset

	-- Prioridad 1: SmartSnap por Attachments Conn_* (y alineaciones Grid/Free base)
	local alignRes = BuildAlignmentMath.ComputeAlignments({
		CandidateLocalCFrame = gridSnap.LocalCFrame,
		CandidateItemId = BuildState.SelectedItemId,
		CandidateSize = _currentPieceSize,
		CandidateAttachments = _currentAttachments,
		ExistingSpecs = existingSpecs,
		SpatialIndex = spatialIndex,
		SurfaceNormalLocal = gridSnap.SurfaceNormalLocal,
		SurfaceOriginLocal = gridSnap.SurfaceOriginLocal,
		FloorY = floorY,
		PositionMode = effectivePosMode,
		SmartSnapEnabled = BuildState.SmartSnapEnabled,
		GuidesEnabled = BuildState.GuidesEnabled,
		ActiveLocks = _alignmentLocks,
	})

	local finalLocalCF = alignRes.FinalLocalCFrame
	local visualGuides = alignRes.Guides
	local visualMarkers = alignRes.Markers
	local nextLocks = alignRes.UpdatedLocks
	local activeFaceSnapTarget: FaceSnapMath.FaceSnapVisualTarget? = nil

	if alignRes.SmartSnapMatch ~= nil then
		-- SmartSnap ganó en Prioridad 1: no aplicar FaceSnap para evitar doble snap contradictorio
		FaceSnapMath.ClearLockState(_faceLockState)
	elseif BuildState.FaceSnapEnabled and #existingSpecs > 0 then
		-- Prioridad 2: FaceSnap geométrico cara con cara
		local hitLocal = effectiveZoneCF:PointToObjectSpace(worldHitPos)
		local rayOriginLocal = if extraContext and extraContext.RayOrigin
			then effectiveZoneCF:PointToObjectSpace(extraContext.RayOrigin)
			else nil
		local rayDirLocal = if extraContext and extraContext.RayDirection
			then effectiveZoneCF:VectorToObjectSpace(extraContext.RayDirection)
			else nil

		local faceRes = FaceSnapMath.ComputeFaceSnap({
			BaseLocalCFrame = gridSnap.LocalCFrame,
			CandidateItemId = BuildState.SelectedItemId,
			CandidateSize = _currentPieceSize,
			CandidateAttachments = _currentAttachments,
			CandidatePartBoxes = _currentPartBoxes,
			ExistingPieces = existingSpecs,
			SpatialIndex = spatialIndex,
			TargetPieceId = if extraContext then extraContext.TargetPieceId else nil,
			SurfaceHitLocal = hitLocal,
			SurfaceNormalLocal = gridSnap.SurfaceNormalLocal,
			RayOriginLocal = rayOriginLocal,
			RayDirectionLocal = rayDirLocal,
			BuildZoneSize = buildZone.Size,
			MaxZoneHeight = GameConfig.Building.DefaultZoneHeight,
			AssemblyOffset = liftOffset,
			LockState = _faceLockState,
		})

		activeFaceSnapTarget = faceRes.VisualTarget
		if faceRes.Matched then
			finalLocalCF = faceRes.SnappedLocalCFrame
			nextLocks = {}
			if BuildState.GuidesEnabled then
				local guideOnly = BuildAlignmentMath.ComputeAlignments({
					CandidateLocalCFrame = finalLocalCF,
					CandidateItemId = BuildState.SelectedItemId,
					CandidateSize = _currentPieceSize,
					CandidateAttachments = _currentAttachments,
					ExistingSpecs = existingSpecs,
					SpatialIndex = spatialIndex,
					SurfaceNormalLocal = gridSnap.SurfaceNormalLocal,
					SurfaceOriginLocal = gridSnap.SurfaceOriginLocal,
					FloorY = floorY,
					PositionMode = effectivePosMode,
					SmartSnapEnabled = false,
					GuidesEnabled = true,
					ActiveLocks = {},
				})
				visualGuides = guideOnly.Guides
				visualMarkers = guideOnly.Markers
			end
		end
	else
		FaceSnapMath.ClearLockState(_faceLockState)
	end

	_alignmentLocks = nextLocks

	local finalWorldCF = effectiveZoneCF:ToWorldSpace(finalLocalCF)
	local isValid = BuildState.IsValidPlacement
	local reason: string? = BuildState.ValidationReason
	local detail: string? = BuildState.ValidationDetail

	local liftOffset = BuildState.GetAssemblyOffset()
	local liftChanged = _lastValidatedLiftH == nil
		or _lastValidatedLiftL == nil
		or math.abs((_lastValidatedLiftH :: number) - liftOffset.HeightOffset) > 1e-4
		or math.abs((_lastValidatedLiftL :: number) - liftOffset.LateralOffset) > 1e-4
	local bpStateChanged = _lastValidatedBlueprintId ~= BuildState.BlueprintId
		or _lastValidatedRevision ~= BuildState.BlueprintRevision
		or _lastValidatedPieceCount ~= #BuildState.BlueprintPieces
		or _lastValidatedEpoch ~= BuildState.TransitionEpoch

	if
		not cframesAlmostEqual(_lastTargetCFrame, finalWorldCF)
		or not cframesAlmostEqual(_lastTargetLocalCFrame, finalLocalCF)
		or BuildState.LastSnappedLocalCFrame == nil
		or liftChanged
		or bpStateChanged
	then
		_lastTargetCFrame = finalWorldCF
		_lastTargetLocalCFrame = finalLocalCF
		_lastValidatedBlueprintId = BuildState.BlueprintId
		_lastValidatedRevision = BuildState.BlueprintRevision
		_lastValidatedPieceCount = #BuildState.BlueprintPieces
		_lastValidatedLiftH = liftOffset.HeightOffset
		_lastValidatedLiftL = liftOffset.LateralOffset
		_lastValidatedEpoch = BuildState.TransitionEpoch
		ghost:PivotTo(finalWorldCF)

		isValid, reason, detail = BuildPreviewController.ValidateCandidate(
			plotModel,
			buildZone,
			finalLocalCF,
			finalWorldCF,
			_currentPieceSize,
			existingSpecs,
			spatialIndex
		)
		applyGhostColor(if isValid then GameConfig.Building.ValidColor else GameConfig.Building.InvalidColor)
		BuildState.SetPlacementStatus(finalWorldCF, finalLocalCF, isValid, reason, detail)
	end

	if activeFaceSnapTarget and not isValid then
		activeFaceSnapTarget.IsValid = false
		activeFaceSnapTarget.RejectReason = reason
	end
	BuildState.SetFaceSnapTarget(activeFaceSnapTarget)
	BuildFaceSnapVisualizer.Render(buildZone, activeFaceSnapTarget, offsetCF)

	local rotatedExtents = BuildRotation.GetRotatedExtents(_currentPieceSize, finalLocalCF.Rotation)
	BuildGridVisualizer.Render({
		BuildZone = buildZone,
		SurfaceOriginLocal = gridSnap.SurfaceOriginLocal,
		SurfaceNormalLocal = gridSnap.SurfaceNormalLocal,
		CandidateLocalPos = finalLocalCF.Position,
		PieceExtents = rotatedExtents,
		GridResolution = effectiveGridStep,
		PositionMode = effectivePosMode,
		IsValid = isValid,
		AssemblyOffsetCFrame = offsetCF,
	})

	if BuildState.GuidesEnabled then
		BuildAlignmentGuides.Render(buildZone, visualGuides, visualMarkers, offsetCF)
	else
		BuildAlignmentGuides.Hide()
	end

	return isValid, finalWorldCF
end

function BuildPreviewController.UpdateFromRay(rayOrigin: Vector3, rayDirection: Vector3, forceRefresh: boolean?): (boolean, CFrame?)
	if not BuildState.IsActive or not BuildState.SelectedItemId then
		return false, nil
	end

	local plotModel = BuildState.AssignedPlot
	local buildZone = BuildState.BuildZone
	if not plotModel or not buildZone then
		return false, nil
	end

	local unitDir = rayDirection.Unit
	local curLift = BuildState.GetAssemblyOffset()
	if
		not forceRefresh
		and _lastRayOrigin
		and _lastRayDirection
		and _lastRayBlueprintId == BuildState.BlueprintId
		and _lastRayRevision == BuildState.BlueprintRevision
		and _lastRayItemId == BuildState.SelectedItemId
		and _lastRayRotation == BuildState.RelativeRotation
		and _lastRayMode == BuildState.PositionMode
		and _lastRayResolution == BuildState.GridResolution
		and _lastRaySmartSnap == BuildState.SmartSnapEnabled
		and _lastRayFaceSnap == BuildState.FaceSnapEnabled
		and _lastRayGuides == BuildState.GuidesEnabled
		and _lastRayTool == BuildState.ActiveTool
		and _lastRayLiftH ~= nil
		and math.abs((_lastRayLiftH :: number) - curLift.HeightOffset) < 1e-4
		and _lastRayLiftL ~= nil
		and math.abs((_lastRayLiftL :: number) - curLift.LateralOffset) < 1e-4
		and _lastRayEpoch == BuildState.TransitionEpoch
		and (_lastRayOrigin - rayOrigin).Magnitude < 1e-4
		and _lastRayDirection:Dot(unitDir) > 0.999999
		and _currentGhost ~= nil
	then
		return BuildState.IsValidPlacement, BuildState.LastSnappedCFrame
	end

	_lastRayOrigin = rayOrigin
	_lastRayDirection = unitDir
	_lastRayBlueprintId = BuildState.BlueprintId
	_lastRayRevision = BuildState.BlueprintRevision
	_lastRayItemId = BuildState.SelectedItemId
	_lastRayRotation = BuildState.RelativeRotation
	_lastRayMode = BuildState.PositionMode
	_lastRayResolution = BuildState.GridResolution
	_lastRaySmartSnap = BuildState.SmartSnapEnabled
	_lastRayFaceSnap = BuildState.FaceSnapEnabled
	_lastRayGuides = BuildState.GuidesEnabled
	_lastRayTool = BuildState.ActiveTool
	_lastRayLiftH = curLift.HeightOffset
	_lastRayLiftL = curLift.LateralOffset
	_lastRayEpoch = BuildState.TransitionEpoch

	local plotCache = getOrBuildPlotExcludeCache(plotModel, buildZone)
	local filterList: { Instance } = table.clone(plotCache.ZoneParts)
	if _currentGhost then
		table.insert(filterList, _currentGhost)
	end
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		table.insert(filterList, localPlayer.Character)
	end
	_raycastParams.FilterDescendantsInstances = filterList

	local scaledDir = unitDir * GameConfig.Building.MaxRaycastDistance
	local hit = Workspace:Raycast(rayOrigin, scaledDir, _raycastParams)

	if hit then
		if hit.Instance == buildZone then
			local planeHit, planeNormal = BuildGrid.IntersectBuildPlane(buildZone.CFrame, buildZone.Size, rayOrigin, unitDir)
			if planeHit then
				return BuildPreviewController.UpdateAtWorldPoint(planeHit, planeNormal, {
					TargetPieceId = nil,
					RayOrigin = rayOrigin,
					RayDirection = unitDir,
				})
			end
		end
		return BuildPreviewController.UpdateAtWorldPoint(hit.Position, hit.Normal, {
			TargetPieceId = resolvePieceIdFromInstance(hit.Instance),
			RayOrigin = rayOrigin,
			RayDirection = unitDir,
		})
	end

	local planeHit, planeNormal = BuildGrid.IntersectBuildPlane(buildZone.CFrame, buildZone.Size, rayOrigin, unitDir)
	if planeHit then
		return BuildPreviewController.UpdateAtWorldPoint(planeHit, planeNormal, {
			TargetPieceId = nil,
			RayOrigin = rayOrigin,
			RayDirection = unitDir,
		})
	end

	local fallbackPos = if _lastTargetCFrame then _lastTargetCFrame.Position else buildZone.Position
	return BuildPreviewController.UpdateAtWorldPoint(fallbackPos, buildZone.CFrame.UpVector, {
		TargetPieceId = nil,
		RayOrigin = rayOrigin,
		RayDirection = unitDir,
	})
end

function BuildPreviewController.GetCurrentGhost(): Model?
	return _currentGhost
end

function BuildPreviewController.GetPieceSize(itemId: string): Vector3?
	local geom = getOrExtractPreviewGeometry(itemId)
	return if geom then geom.Size else nil
end

function BuildPreviewController._ClearGeometryCacheForTests()
	table.clear(_geometryCache)
	BuildPreviewController.InvalidateWorkshopCaches()
	BuildPreviewController.InvalidateRayCache()
	BuildGridVisualizer.Destroy()
	BuildAlignmentGuides.Destroy()
	BuildFaceSnapVisualizer.Destroy()
end

function BuildPreviewController._GetCacheSnapshotForTests(): { CachedSpecsCount: number, CachedSpecsKey: string?, HasTargetCFrame: boolean, HasLastRay: boolean }
	return {
		CachedSpecsCount = #_cachedExistingSpecs,
		CachedSpecsKey = _cachedSpecsKey,
		HasTargetCFrame = _lastTargetCFrame ~= nil,
		HasLastRay = _lastRayOrigin ~= nil,
	}
end

BuildState.SubscribeBlueprintReplaced(BuildPreviewController.InvalidateWorkshopCaches)

return BuildPreviewController
