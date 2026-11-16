--!strict
--[=[
	BuildState
	Estado local del editor de construcción (Fases 2.1, 2.2 y 2.3).
	- Resuelve de forma segura la estación asignada al jugador local sin asumir Plot_01.
	- Verifica propietario autoritativo (OwnerUserId) e ID de blueprint antes de aplicar cambios.
	- Garantiza revisiones monotónicas rechazando respuestas duplicadas o antiguas,
	  y detecta brechas de revisión para activar recuperación vía GetBlueprint.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildSnapPolicy = require(ReplicatedStorage.Shared.Building.BuildSnapPolicy)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local FaceSnapMath = require(ReplicatedStorage.Shared.Building.FaceSnapMath)
local VehicleCoordinateMath = require(ReplicatedStorage.Shared.Building.VehicleCoordinateMath)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type StateChangedListener = () -> ()
export type PositionMode = "Grid" | "Free"
export type TransformTool = "None" | "Move" | "Rotate"
export type AxisName = "X" | "Y" | "Z"

local BuildState = {
	IsActive = false,
	AssignedPlot = nil :: Model?,
	BuildZone = nil :: BasePart?,
	ExpectedOwnerUserId = nil :: number?,
	SelectedItemId = nil :: string?,
	SelectedPlacedPieceId = nil :: string?,
	RelativeRotation = BuildRotation.Identity(),
	LastSnappedCFrame = nil :: CFrame?,
	LastSnappedLocalCFrame = nil :: CFrame?,
	IsValidPlacement = false,
	ValidationReason = nil :: string?,
	ValidationDetail = nil :: string?,
	LastError = nil :: string?,
	StatusMessage = nil :: string?,
	PendingOpCount = 0,

	-- Estado de Editor Avanzado (Fase 2.3.1 / 2.4.2)
	PositionMode = GameConfig.Building.PositionModes.Grid :: PositionMode,
	GridResolution = GameConfig.Building.DefaultGridResolution,
	SmartSnapEnabled = true,
	FaceSnapEnabled = true,
	FaceSnapTarget = nil :: FaceSnapMath.FaceSnapVisualTarget?,
	GuidesEnabled = true,
	ActiveTool = GameConfig.Building.TransformTools.None :: TransformTool,
	AngleIncrementDeg = GameConfig.Building.DefaultAngleIncrementDeg,
	ActiveMoveAxis = nil :: AxisName?,
	ActiveRotateAxis = nil :: AxisName?,
	TransformTargetPieceId = nil :: string?,
	TransformBaseLocalCFrame = nil :: CFrame?,
	TransformPreviewLocalCFrame = nil :: CFrame?,
	TransformIsValid = false,
	TransformDeltaDisplay = nil :: string?,

	BlueprintId = nil :: string?,
	BlueprintName = "Vehículo 1",
	BlueprintRevision = 0,
	BlueprintMetadata = nil :: VehicleTypes.BlueprintMetadata?,
	BlueprintPieces = {} :: { VehicleTypes.BlueprintPiece },
	BlueprintConnections = {} :: { VehicleTypes.BlueprintConnection },
	BlueprintSummaries = {} :: { VehicleTypes.BlueprintSummary },
	BlueprintSlots = {} :: { VehicleTypes.BlueprintSlotSummary },
	LoadedSlotIndex = nil :: number?,
	WorkshopEpoch = 0,
	LegacyOverflowCount = 0,
	LegacyOverflow = {} :: { VehicleTypes.LegacyOverflowSummary },
	HasUnsavedChanges = false,
	MaxBlueprints = GameConfig.Blueprints.MaxSavedBlueprintsPerPlayer,
	StandPresentation = {
		HeightOffset = GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = GameConfig.Stand.DefaultLateralOffset,
	} :: VehicleTypes.StandPresentationConfig,
	LaunchPrepReport = nil :: VehicleTypes.LaunchPreparationReport?,
	TransitionEpoch = 0,

	-- Estado de runtime y ciclo de vida del vehículo (Fase 3.1)
	RuntimeState = GameConfig.Runtime.States.Editing :: VehicleTypes.VehicleState,
	RuntimeStatus = nil :: VehicleTypes.RuntimeStatusSnapshot?,
	RuntimeActionInFlight = false,
	RuntimeErrorMessage = nil :: string?,

	-- Inventario central sincronizado desde el servidor (Fase 5.1)
	Inventory = nil :: ItemTypes.PlayerInventorySnapshot?,
}

local _listeners: { StateChangedListener } = {}
local _replaceListeners: { StateChangedListener } = {}

local function notify()
	for _, fn in ipairs(table.clone(_listeners)) do
		task.spawn(fn)
	end
end

local function notifyReplacedSync()
	for _, fn in ipairs(table.clone(_replaceListeners)) do
		pcall(fn)
	end
end

local function getEffectiveExpectedOwnerUserId(): number?
	if BuildState.ExpectedOwnerUserId ~= nil then
		return BuildState.ExpectedOwnerUserId
	end
	local localPlayer = if RunService:IsRunning() then Players.LocalPlayer else nil
	if localPlayer then
		return localPlayer.UserId
	end
	return nil
end

local function findBuildZoneInPlot(plotModel: Model): BasePart?
	for _, descendant in ipairs(plotModel:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if descendant:GetAttribute(GameConfig.PlotAttributes.ZoneId) == GameConfig.ZoneIds.BuildZone then
				return descendant
			end
		end
	end
	local direct = plotModel:FindFirstChild(GameConfig.ZoneIds.BuildZone)
	if direct and direct:IsA("BasePart") then
		return direct
	end
	return nil
end

function BuildState.ResolvePlayerPlot(player: Player): (Model?, BasePart?)
	local plotsFolder = Workspace:FindFirstChild("Plots")
	if not plotsFolder then
		return nil, nil
	end

	for _, child in ipairs(plotsFolder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute(GameConfig.PlotAttributes.OwnerUserId) == player.UserId then
			local bz = findBuildZoneInPlot(child)
			return child, bz
		end
	end

	local attrPlotId = player:GetAttribute(GameConfig.PlotAttributes.PlotId)
	if type(attrPlotId) == "string" and attrPlotId ~= "" then
		local plotModel = plotsFolder:FindFirstChild(attrPlotId)
		if plotModel and plotModel:IsA("Model") and plotModel:GetAttribute(GameConfig.PlotAttributes.OwnerUserId) == player.UserId then
			local bz = findBuildZoneInPlot(plotModel)
			return plotModel, bz
		end
	end

	return nil, nil
end

function BuildState.Subscribe(listener: StateChangedListener): () -> ()
	table.insert(_listeners, listener)
	return function()
		local idx = table.find(_listeners, listener)
		if idx then
			table.remove(_listeners, idx)
		end
	end
end

function BuildState.SubscribeBlueprintReplaced(listener: StateChangedListener): () -> ()
	table.insert(_replaceListeners, listener)
	return function()
		local idx = table.find(_replaceListeners, listener)
		if idx then
			table.remove(_replaceListeners, idx)
		end
	end
end

function BuildState.SetExpectedOwner(userId: number?)
	BuildState.ExpectedOwnerUserId = userId
end

function BuildState.SetPendingOpCount(count: number)
	local clamped = math.max(0, count)
	if BuildState.PendingOpCount ~= clamped then
		BuildState.PendingOpCount = clamped
		notify()
	end
end

function BuildState.SetPlot(plotModel: Model?, buildZone: BasePart?)
	local ownerAttr = if plotModel then plotModel:GetAttribute(GameConfig.PlotAttributes.OwnerUserId) else nil
	if type(ownerAttr) == "number" and ownerAttr > 0 and BuildState.ExpectedOwnerUserId == nil and (if RunService:IsRunning() then Players.LocalPlayer else nil) == nil then
		BuildState.ExpectedOwnerUserId = ownerAttr
	end

	BuildState.AssignedPlot = plotModel
	BuildState.BuildZone = buildZone
	if not plotModel or not buildZone then
		BuildState.IsActive = false
		BuildState.SelectedItemId = nil
		BuildState.SelectedPlacedPieceId = nil
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		BuildState.IsValidPlacement = false
	end
	notify()
end

function BuildState.SetActive(active: boolean): (boolean, string?)
	if active then
		if not BuildState.IsEditingMode() then
			BuildState.LastError = "InvalidPlayerState"
			notify()
			return false, "InvalidPlayerState"
		end
		if not BuildState.AssignedPlot or not BuildState.AssignedPlot.Parent then
			BuildState.LastError = "NoAssignedPlot"
			notify()
			return false, "NoAssignedPlot"
		end
		if not BuildState.BuildZone or not BuildState.BuildZone.Parent then
			BuildState.LastError = "MissingBuildZone"
			notify()
			return false, "MissingBuildZone"
		end
	end

	BuildState.IsActive = active
	BuildState.LastError = nil
	BuildState.StatusMessage = nil
	if not active then
		BuildState.SelectedItemId = nil
		BuildState.SelectedPlacedPieceId = nil
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		BuildState.IsValidPlacement = false
		BuildState.ValidationReason = nil
		BuildState.ValidationDetail = nil
	end
	notify()
	return true, nil
end

function BuildState.SelectItem(itemId: string?)
	if BuildState.SelectedItemId ~= itemId then
		BuildState.SelectedItemId = itemId
		if itemId ~= nil then
			BuildState.SelectedPlacedPieceId = nil
		end
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		BuildState.IsValidPlacement = false
		BuildState.ValidationReason = nil
		BuildState.ValidationDetail = nil
		BuildState.LastError = nil
		BuildState.StatusMessage = nil
		notify()
	end
end

function BuildState.ClearSelection()
	BuildState.SelectItem(nil)
end

function BuildState.SetSelectedPlacedPiece(pieceInstanceId: string?)
	if BuildState.SelectedPlacedPieceId ~= pieceInstanceId then
		BuildState.SelectedPlacedPieceId = pieceInstanceId
		if pieceInstanceId ~= nil then
			BuildState.SelectedItemId = nil
			BuildState.LastSnappedCFrame = nil
			BuildState.LastSnappedLocalCFrame = nil
			BuildState.IsValidPlacement = false
		end
		BuildState.LastError = nil
		BuildState.StatusMessage = nil
		notify()
	end
end

function BuildState.RotateAxis(axisName: AxisName, direction: number?)
	local stepDir = if direction and direction < 0 then -1 else 1
	local itemId = BuildState.SelectedItemId
	if not itemId and BuildState.SelectedPlacedPieceId then
		local piece = BuildState.GetPiece(BuildState.SelectedPlacedPieceId)
		itemId = if piece then piece.ItemId else nil
	end
	local effDeg = BuildSnapPolicy.GetEffectiveAngleIncrement(itemId, BuildState.AngleIncrementDeg)
	BuildState.RelativeRotation = BuildRotation.RotateAxisDegrees(BuildState.RelativeRotation, axisName, effDeg * stepDir)
	BuildState.LastSnappedCFrame = nil
	BuildState.LastSnappedLocalCFrame = nil
	notify()
end

function BuildState.RotateY()
	BuildState.RotateAxis("Y", 1)
end

function BuildState.RotateX()
	BuildState.RotateAxis("X", 1)
end

function BuildState.RotateZ()
	BuildState.RotateAxis("Z", 1)
end

function BuildState.ResetRotation()
	BuildState.RelativeRotation = BuildRotation.Identity()
	BuildState.LastSnappedCFrame = nil
	BuildState.LastSnappedLocalCFrame = nil
	notify()
end

function BuildState.SetPositionMode(mode: PositionMode)
	local normalized = BuildSnapPolicy.NormalizePositionMode(mode)
	if BuildState.PositionMode ~= normalized then
		BuildState.PositionMode = normalized
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		notify()
	end
end

function BuildState.TogglePositionMode(): PositionMode
	local nextMode: PositionMode = if BuildState.PositionMode == GameConfig.Building.PositionModes.Grid
		then GameConfig.Building.PositionModes.Free :: PositionMode
		else GameConfig.Building.PositionModes.Grid :: PositionMode
	BuildState.SetPositionMode(nextMode)
	return nextMode
end

function BuildState.SetGridResolution(resolution: number)
	local normalized = BuildSnapPolicy.NormalizeGridResolution(resolution)
	if math.abs(BuildState.GridResolution - normalized) > 1e-5 then
		BuildState.GridResolution = normalized
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		notify()
	end
end

function BuildState.SetSmartSnapEnabled(enabled: boolean)
	local b = enabled == true
	if BuildState.SmartSnapEnabled ~= b then
		BuildState.SmartSnapEnabled = b
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		notify()
	end
end

function BuildState.SetFaceSnapEnabled(enabled: boolean)
	local b = enabled == true
	if BuildState.FaceSnapEnabled ~= b then
		BuildState.FaceSnapEnabled = b
		if not b then
			BuildState.FaceSnapTarget = nil
		end
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		notify()
	end
end

function BuildState.SetFaceSnapTarget(target: FaceSnapMath.FaceSnapVisualTarget?)
	BuildState.FaceSnapTarget = target
end

function BuildState.SetGuidesEnabled(enabled: boolean)
	local b = enabled == true
	if BuildState.GuidesEnabled ~= b then
		BuildState.GuidesEnabled = b
		notify()
	end
end

function BuildState.SetActiveTool(tool: TransformTool)
	local normalized: TransformTool = if tool == GameConfig.Building.TransformTools.Move
		then "Move"
		elseif tool == GameConfig.Building.TransformTools.Rotate then "Rotate"
		else "None"
	if BuildState.ActiveTool ~= normalized then
		BuildState.ActiveTool = normalized
		BuildState.ActiveMoveAxis = nil
		BuildState.ActiveRotateAxis = nil
		notify()
	end
end

function BuildState.SetAngleIncrementDeg(deg: number)
	local normalized = BuildSnapPolicy.NormalizeAngleIncrement(deg)
	if BuildState.AngleIncrementDeg ~= normalized then
		BuildState.AngleIncrementDeg = normalized
		notify()
	end
end

function BuildState.SetTransformPreviewState(
	pieceId: string?,
	baseLocalCF: CFrame?,
	previewLocalCF: CFrame?,
	isValid: boolean,
	deltaDisplay: string?,
	reason: string?,
	detail: string?
)
	local changed = BuildState.TransformTargetPieceId ~= pieceId
		or BuildState.TransformIsValid ~= isValid
		or BuildState.TransformDeltaDisplay ~= deltaDisplay
		or BuildState.ValidationReason ~= reason
	BuildState.TransformTargetPieceId = pieceId
	BuildState.TransformBaseLocalCFrame = baseLocalCF
	BuildState.TransformPreviewLocalCFrame = previewLocalCF
	BuildState.TransformIsValid = isValid
	BuildState.TransformDeltaDisplay = deltaDisplay
	BuildState.ValidationReason = reason
	BuildState.ValidationDetail = detail
	if previewLocalCF and BuildState.BuildZone then
		BuildState.LastSnappedLocalCFrame = previewLocalCF
		local effectiveZoneCF = BuildState.GetEffectiveBuildZoneCFrame() or BuildState.BuildZone.CFrame
		BuildState.LastSnappedCFrame = effectiveZoneCF:ToWorldSpace(previewLocalCF)
	end
	if changed then
		notify()
	end
end

function BuildState.ClearTransformSession()
	local had = BuildState.TransformTargetPieceId ~= nil or BuildState.TransformPreviewLocalCFrame ~= nil
	BuildState.TransformTargetPieceId = nil
	BuildState.TransformBaseLocalCFrame = nil
	BuildState.TransformPreviewLocalCFrame = nil
	BuildState.TransformIsValid = false
	BuildState.TransformDeltaDisplay = nil
	BuildState.ActiveMoveAxis = nil
	BuildState.ActiveRotateAxis = nil
	if had then
		notify()
	end
end

function BuildState.GetPiece(pieceInstanceId: string): VehicleTypes.BlueprintPiece?
	for _, p in ipairs(BuildState.BlueprintPieces) do
		if p.InstanceId == pieceInstanceId then
			return p
		end
	end
	return nil
end

function BuildState.SetPlacementStatus(
	worldCFrame: CFrame?,
	localCFrame: CFrame?,
	isValid: boolean,
	reason: string?,
	detail: string?
)
	local changed = BuildState.IsValidPlacement ~= isValid
		or BuildState.ValidationReason ~= reason
		or BuildState.ValidationDetail ~= detail
	BuildState.LastSnappedCFrame = worldCFrame
	BuildState.LastSnappedLocalCFrame = localCFrame
	BuildState.IsValidPlacement = isValid
	BuildState.ValidationReason = reason
	BuildState.ValidationDetail = detail
	if changed then
		notify()
	end
end

function BuildState.HasPiece(pieceInstanceId: string): boolean
	for _, p in ipairs(BuildState.BlueprintPieces) do
		if p.InstanceId == pieceInstanceId then
			return true
		end
	end
	return false
end

--[=[
	Aplica una instantánea autoritativa del blueprint si pertenece al propietario esperado
	y su revisión es monotónica (protegiendo contra respuestas duplicadas o fuera de orden).
	`allowEqualRevision`: true cuando proviene de recuperación explícita vía GetBlueprint/FullSync.
]=]
function BuildState.BeginBlueprintTransition(): number
	BuildState.TransitionEpoch += 1
	return BuildState.TransitionEpoch
end

function BuildState.SetBlueprintLibraryState(
	summaries: { VehicleTypes.BlueprintSummary }?,
	hasUnsavedChanges: boolean?,
	maxBlueprints: number?
)
	if summaries then
		BuildState.BlueprintSummaries = summaries
	end
	if hasUnsavedChanges ~= nil then
		BuildState.HasUnsavedChanges = hasUnsavedChanges
	end
	if type(maxBlueprints) == "number" and maxBlueprints > 0 then
		BuildState.MaxBlueprints = maxBlueprints
	end
	notify()
end

function BuildState.SetWorkshopEpoch(epoch: number?)
	if type(epoch) == "number" and epoch >= BuildState.WorkshopEpoch then
		BuildState.WorkshopEpoch = epoch
	end
end

function BuildState.SetSlotLibraryState(
	slots: { VehicleTypes.BlueprintSlotSummary }?,
	loadedSlotIndex: number?,
	hasUnsavedChanges: boolean?,
	legacyOverflowCount: number?,
	legacyOverflow: { VehicleTypes.LegacyOverflowSummary }?
)
	if slots then
		BuildState.BlueprintSlots = table.clone(slots)
	end
	if loadedSlotIndex ~= nil then
		BuildState.LoadedSlotIndex = if loadedSlotIndex >= 1 and loadedSlotIndex <= GameConfig.Blueprints.MaxSlots
			then loadedSlotIndex
			else nil
	elseif slots then
		local resolved: number? = nil
		for _, slot in ipairs(slots) do
			if slot.IsLoadedInWorkshop then
				resolved = slot.SlotIndex
				break
			end
		end
		BuildState.LoadedSlotIndex = resolved
	end
	if hasUnsavedChanges ~= nil then
		BuildState.HasUnsavedChanges = hasUnsavedChanges
	end
	if type(legacyOverflowCount) == "number" and legacyOverflowCount >= 0 then
		BuildState.LegacyOverflowCount = legacyOverflowCount
	end
	if legacyOverflow then
		BuildState.LegacyOverflow = table.clone(legacyOverflow)
		BuildState.LegacyOverflowCount = #legacyOverflow
	end
	notify()
end

function BuildState.GetAssemblyOffset(): VehicleTypes.BuildAssemblyOffset
	local pres = BuildState.StandPresentation
	return {
		HeightOffset = if pres and type(pres.HeightOffset) == "number" then pres.HeightOffset else GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = if pres and type(pres.LateralOffset) == "number" then pres.LateralOffset else GameConfig.Stand.DefaultLateralOffset,
	}
end

function BuildState.GetAssemblyOffsetCFrame(): CFrame
	return VehicleCoordinateMath.GetAssemblyOffsetCFrame(BuildState.GetAssemblyOffset())
end

function BuildState.GetEffectiveBuildZoneCFrame(): CFrame?
	local bz = BuildState.BuildZone
	if not bz then
		return nil
	end
	return VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(bz.CFrame, BuildState.GetAssemblyOffset())
end

function BuildState.GetEffectiveFloorY(): number?
	local bz = BuildState.BuildZone
	if not bz then
		return nil
	end
	return -bz.Size.Y * 0.5 - BuildState.GetAssemblyOffset().HeightOffset
end

function BuildState.SetStandPresentationState(presentation: VehicleTypes.StandPresentationConfig?)
	if type(presentation) == "table" then
		BuildState.StandPresentation = {
			HeightOffset = presentation.HeightOffset or GameConfig.Stand.DefaultHeightOffset,
			LateralOffset = presentation.LateralOffset or GameConfig.Stand.DefaultLateralOffset,
		}
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		notify()
	end
end

function BuildState.SetLaunchPrepReport(report: VehicleTypes.LaunchPreparationReport?)
	BuildState.LaunchPrepReport = report
	notify()
end

function BuildState.SetInventoryState(snapshot: any?)
	if type(snapshot) ~= "table" then
		return
	end
	BuildState.Inventory = snapshot :: ItemTypes.PlayerInventorySnapshot
	notify()
end

function BuildState.GetInventoryEntry(itemId: string): ItemTypes.InventoryItemEntry?
	local inv = BuildState.Inventory
	if not inv or type(inv.ItemsById) ~= "table" then
		return nil
	end
	return inv.ItemsById[itemId]
end

function BuildState.GetOwnedQuantity(itemId: string): number?
	local entry = BuildState.GetInventoryEntry(itemId)
	if not entry then
		return nil
	end
	return entry.OwnedQuantity
end

function BuildState.GetAvailableQuantity(itemId: string): number?
	local entry = BuildState.GetInventoryEntry(itemId)
	if not entry then
		return nil
	end
	local usedInWorkshop = 0
	for _, piece in ipairs(BuildState.BlueprintPieces) do
		if piece.ItemId == itemId then
			usedInWorkshop += 1
		end
	end
	return math.max(0, entry.OwnedQuantity - usedInWorkshop)
end

function BuildState.IsEditingMode(): boolean
	return BuildState.RuntimeState == GameConfig.Runtime.States.Editing
end

function BuildState.IsRuntimeActive(): boolean
	return BuildState.RuntimeState == GameConfig.Runtime.States.Driving
		or BuildState.RuntimeState == GameConfig.Runtime.States.OnFootRuntime
end

function BuildState.SetRuntimeStatus(snapshot: VehicleTypes.RuntimeStatusSnapshot?)
	if type(snapshot) ~= "table" then
		return
	end
	BuildState.RuntimeStatus = snapshot
	BuildState.RuntimeState = snapshot.State
	if snapshot.ErrorMessage and #snapshot.ErrorMessage > 0 then
		BuildState.RuntimeErrorMessage = snapshot.ErrorMessage
	elseif snapshot.State ~= GameConfig.Runtime.States.Editing then
		BuildState.RuntimeErrorMessage = nil
	end
	if snapshot.State ~= GameConfig.Runtime.States.Editing and BuildState.IsActive then
		BuildState.IsActive = false
		BuildState.SelectedItemId = nil
		BuildState.SelectedPlacedPieceId = nil
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
	end
	notify()
end

function BuildState.SetRuntimeActionInFlight(inFlight: boolean, errorMsg: string?, optimisticState: VehicleTypes.VehicleState?)
	BuildState.RuntimeActionInFlight = inFlight
	BuildState.RuntimeErrorMessage = errorMsg
	if optimisticState then
		BuildState.RuntimeState = optimisticState
		if optimisticState ~= GameConfig.Runtime.States.Editing and BuildState.IsActive then
			BuildState.IsActive = false
			BuildState.SelectedItemId = nil
			BuildState.SelectedPlacedPieceId = nil
			BuildState.LastSnappedCFrame = nil
			BuildState.LastSnappedLocalCFrame = nil
		end
	end
	notify()
end

function BuildState.ApplyAuthoritativeBlueprint(blueprint: VehicleTypes.VehicleBlueprint, allowEqualRevision: boolean?): boolean
	if type(blueprint) ~= "table" or type(blueprint.Revision) ~= "number" or type(blueprint.OwnerUserId) ~= "number" then
		return false
	end

	local expectedOwner = getEffectiveExpectedOwnerUserId()
	if expectedOwner ~= nil and blueprint.OwnerUserId ~= expectedOwner then
		return false
	end

	local allowAuthoritativeReplace = allowEqualRevision == true
	local isSameBlueprint = BuildState.BlueprintId == nil or BuildState.BlueprintId == blueprint.BlueprintId
	if not allowAuthoritativeReplace then
		if isSameBlueprint then
			if blueprint.Revision < BuildState.BlueprintRevision then
				return false
			end
			if blueprint.Revision == BuildState.BlueprintRevision and BuildState.BlueprintId ~= nil then
				return false
			end
		else
			-- Cambio de BlueprintId sin permiso explícito de cambio/carga -> rechazar respuesta tardía
			return false
		end
	end

	local prevBlueprintId = BuildState.BlueprintId
	local prevRevision = BuildState.BlueprintRevision
	local prevPieceCount = #BuildState.BlueprintPieces
	local switchedBlueprint = prevBlueprintId ~= nil and prevBlueprintId ~= blueprint.BlueprintId
	local replacedWorkshop = allowAuthoritativeReplace
		and (switchedBlueprint or blueprint.Revision ~= prevRevision or #blueprint.Pieces ~= prevPieceCount or #blueprint.Pieces == 0)

	BuildState.BlueprintId = blueprint.BlueprintId
	BuildState.BlueprintName = blueprint.Name or BuildState.BlueprintName
	BuildState.BlueprintRevision = blueprint.Revision
	BuildState.BlueprintMetadata = if blueprint.Metadata then table.clone(blueprint.Metadata) else nil
	BuildState.BlueprintPieces = table.clone(blueprint.Pieces)
	BuildState.BlueprintConnections = table.clone(blueprint.Connections)

	if type(blueprint.Presentation) == "table" then
		BuildState.StandPresentation = {
			HeightOffset = blueprint.Presentation.HeightOffset or GameConfig.Stand.DefaultHeightOffset,
			LateralOffset = blueprint.Presentation.LateralOffset or GameConfig.Stand.DefaultLateralOffset,
		}
	elseif allowAuthoritativeReplace then
		BuildState.StandPresentation = {
			HeightOffset = GameConfig.Stand.DefaultHeightOffset,
			LateralOffset = GameConfig.Stand.DefaultLateralOffset,
		}
	end

	if blueprint.Metadata and type(blueprint.Metadata.SourceSlotIndex) == "number" then
		BuildState.LoadedSlotIndex = blueprint.Metadata.SourceSlotIndex
	elseif replacedWorkshop or #blueprint.Pieces == 0 then
		BuildState.LoadedSlotIndex = nil
	end

	if switchedBlueprint or replacedWorkshop then
		BuildState.SelectedPlacedPieceId = nil
		BuildState.ClearTransformSession()
		if #blueprint.Pieces == 0 and allowAuthoritativeReplace then
			BuildState.HasUnsavedChanges = false
		end
	elseif BuildState.SelectedPlacedPieceId then
		if not BuildState.HasPiece(BuildState.SelectedPlacedPieceId) then
			BuildState.SelectedPlacedPieceId = nil
		end
	end

	if not allowAuthoritativeReplace and not switchedBlueprint and BuildState.BlueprintRevision > 0 then
		BuildState.HasUnsavedChanges = true
	end

	if replacedWorkshop then
		BuildState.TransitionEpoch += 1
	end

	BuildState.LaunchPrepReport = nil
	BuildState.LastSnappedCFrame = nil
	BuildState.LastSnappedLocalCFrame = nil
	BuildState.IsValidPlacement = false
	BuildState.ValidationReason = nil
	BuildState.ValidationDetail = nil
	BuildState.FaceSnapTarget = nil

	if replacedWorkshop then
		notifyReplacedSync()
	end
	notify()
	return true
end

--[=[
	Aplica un evento incremental enviado por BlueprintSyncEvent.
	Devuelve `(applied, needsFullResync)`.
	Si detecta un salto de revisión (`payload.Revision > current + 1`), solicita recuperación
	completa mediante GetBlueprint.
]=]
function BuildState.ApplySyncEvent(payload: BuildProtocol.BlueprintSyncPayload): (boolean, boolean)
	if type(payload) ~= "table" or type(payload.Revision) ~= "number" or type(payload.OwnerUserId) ~= "number" then
		return false, false
	end

	local expectedOwner = getEffectiveExpectedOwnerUserId()
	if expectedOwner ~= nil and payload.OwnerUserId ~= expectedOwner then
		return false, false
	end

	if (payload :: any).Inventory ~= nil then
		BuildState.SetInventoryState((payload :: any).Inventory)
	end

	if payload.Type == BuildProtocol.SyncTypes.InventoryUpdated then
		return true, false
	end

	if
		payload.Type == BuildProtocol.SyncTypes.BlueprintReset
		or payload.Type == BuildProtocol.SyncTypes.FullSync
		or payload.Type == BuildProtocol.SyncTypes.BlueprintLoaded
		or payload.Type == BuildProtocol.SyncTypes.WorkshopCleared
	then
		if type(payload.WorkshopEpoch) == "number" then
			BuildState.SetWorkshopEpoch(payload.WorkshopEpoch)
		end
		if payload.Blueprint then
			local ok = BuildState.ApplyAuthoritativeBlueprint(payload.Blueprint, true)
			if ok then
				if payload.Blueprints or payload.HasUnsavedChanges ~= nil then
					BuildState.SetBlueprintLibraryState(payload.Blueprints, payload.HasUnsavedChanges, nil)
				end
				if payload.Slots or payload.LoadedSlotIndex ~= nil or payload.HasUnsavedChanges ~= nil or type(payload.LegacyOverflowCount) == "number" then
					BuildState.SetSlotLibraryState(
						payload.Slots,
						payload.LoadedSlotIndex,
						payload.HasUnsavedChanges,
						payload.LegacyOverflowCount,
						payload.LegacyOverflow
					)
				end
				if payload.Type == BuildProtocol.SyncTypes.WorkshopCleared or payload.Type == BuildProtocol.SyncTypes.BlueprintLoaded or payload.Type == BuildProtocol.SyncTypes.BlueprintReset then
					notifyReplacedSync()
				end
			end
			return ok, not ok
		end
		return false, true
	end

	if payload.Type == BuildProtocol.SyncTypes.BlueprintLibraryUpdated or payload.Type == BuildProtocol.SyncTypes.SlotLibraryUpdated then
		if type(payload.WorkshopEpoch) == "number" then
			BuildState.SetWorkshopEpoch(payload.WorkshopEpoch)
		end
		if payload.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(payload.Blueprint, true)
		end
		BuildState.SetBlueprintLibraryState(payload.Blueprints, payload.HasUnsavedChanges, nil)
		if payload.Slots or payload.LoadedSlotIndex ~= nil or payload.HasUnsavedChanges ~= nil or type(payload.LegacyOverflowCount) == "number" then
			BuildState.SetSlotLibraryState(
				payload.Slots,
				payload.LoadedSlotIndex,
				payload.HasUnsavedChanges,
				payload.LegacyOverflowCount,
				payload.LegacyOverflow
			)
		end
		return true, false
	end

	if payload.Type == BuildProtocol.SyncTypes.RuntimeStateUpdated then
		if payload.RuntimeStatus then
			BuildState.SetRuntimeStatus(payload.RuntimeStatus)
		end
		return true, false
	end

	if BuildState.BlueprintId ~= nil and payload.BlueprintId ~= BuildState.BlueprintId then
		return false, true
	end

	if payload.Type == BuildProtocol.SyncTypes.StandPresentationUpdated then
		if payload.Revision <= BuildState.BlueprintRevision then
			return false, false
		end
		if payload.Revision > BuildState.BlueprintRevision + 1 then
			return false, true
		end
		BuildState.BlueprintRevision = payload.Revision
		if payload.Presentation then
			BuildState.StandPresentation = {
				HeightOffset = payload.Presentation.HeightOffset or GameConfig.Stand.DefaultHeightOffset,
				LateralOffset = payload.Presentation.LateralOffset or GameConfig.Stand.DefaultLateralOffset,
			}
		end
		if payload.HasUnsavedChanges ~= nil then
			BuildState.HasUnsavedChanges = payload.HasUnsavedChanges
		end
		notify()
		return true, false
	end

	if payload.Type == BuildProtocol.SyncTypes.AssemblySelectionUpdated then
		if payload.Revision <= BuildState.BlueprintRevision then
			return false, false
		end
		if payload.Revision > BuildState.BlueprintRevision + 1 then
			return false, true
		end
		BuildState.BlueprintRevision = payload.Revision
		BuildState.BlueprintMetadata = if payload.Metadata then table.clone(payload.Metadata) else nil
		if payload.HasUnsavedChanges ~= nil then
			BuildState.HasUnsavedChanges = payload.HasUnsavedChanges
		end
		BuildState.LaunchPrepReport = nil
		notify()
		return true, false
	end

	-- Rechazar confirmaciones duplicadas o eventos tardíos de revisiones anteriores
	if payload.Revision <= BuildState.BlueprintRevision then
		return false, false
	end

	-- Salto de revisión -> desincronización detectada, recuperar mediante GetBlueprint
	if payload.Revision > BuildState.BlueprintRevision + 1 then
		return false, true
	end

	if payload.Type == BuildProtocol.SyncTypes.PiecePlaced and payload.PlacedPiece then
		if BuildState.HasPiece(payload.PlacedPiece.InstanceId) then
			return false, false
		end
		BuildState.BlueprintId = payload.BlueprintId
		BuildState.BlueprintRevision = payload.Revision
		table.insert(BuildState.BlueprintPieces, payload.PlacedPiece)
		if payload.ConnectionsAdded then
			for _, conn in ipairs(payload.ConnectionsAdded) do
				table.insert(BuildState.BlueprintConnections, conn)
			end
		end
		BuildState.HasUnsavedChanges = true
		BuildState.LaunchPrepReport = nil
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		notify()
		return true, false
	elseif payload.Type == BuildProtocol.SyncTypes.PieceRemoved and payload.RemovedPieceId then
		local removedId = payload.RemovedPieceId
		local newPieces: { VehicleTypes.BlueprintPiece } = {}
		local removed = false
		for _, p in ipairs(BuildState.BlueprintPieces) do
			if p.InstanceId == removedId then
				removed = true
			else
				table.insert(newPieces, p)
			end
		end

		if not removed then
			return false, true
		end

		local newConns: { VehicleTypes.BlueprintConnection } = {}
		for _, c in ipairs(BuildState.BlueprintConnections) do
			if c.FromPieceId ~= removedId and c.ToPieceId ~= removedId then
				table.insert(newConns, c)
			end
		end

		BuildState.BlueprintId = payload.BlueprintId
		BuildState.BlueprintRevision = payload.Revision
		BuildState.BlueprintPieces = newPieces
		BuildState.BlueprintConnections = newConns
		if BuildState.SelectedPlacedPieceId == removedId then
			BuildState.SelectedPlacedPieceId = nil
		end
		BuildState.HasUnsavedChanges = true
		BuildState.LaunchPrepReport = nil
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		notify()
		return true, false
	elseif payload.Type == BuildProtocol.SyncTypes.PieceTransformed and payload.TransformedPiece then
		local updated = payload.TransformedPiece
		local replaced = false
		for i, p in ipairs(BuildState.BlueprintPieces) do
			if p.InstanceId == updated.InstanceId then
				BuildState.BlueprintPieces[i] = updated
				replaced = true
				break
			end
		end
		if not replaced then
			return false, true
		end

		local newConns: { VehicleTypes.BlueprintConnection } = {}
		for _, c in ipairs(BuildState.BlueprintConnections) do
			if c.FromPieceId ~= updated.InstanceId and c.ToPieceId ~= updated.InstanceId then
				table.insert(newConns, c)
			end
		end
		if payload.UpdatedConnections then
			for _, c in ipairs(payload.UpdatedConnections) do
				table.insert(newConns, c)
			end
		end

		BuildState.BlueprintId = payload.BlueprintId
		BuildState.BlueprintRevision = payload.Revision
		BuildState.BlueprintConnections = newConns
		BuildState.HasUnsavedChanges = true
		BuildState.LaunchPrepReport = nil
		BuildState.LastSnappedCFrame = nil
		BuildState.LastSnappedLocalCFrame = nil
		notify()
		return true, false
	elseif payload.Type == BuildProtocol.SyncTypes.PieceConfigUpdated and payload.UpdatedPiece then
		local updated = payload.UpdatedPiece
		local replaced = false
		for i, p in ipairs(BuildState.BlueprintPieces) do
			if p.InstanceId == updated.InstanceId then
				BuildState.BlueprintPieces[i] = updated
				replaced = true
				break
			end
		end
		if not replaced then
			return false, true
		end

		BuildState.BlueprintId = payload.BlueprintId
		BuildState.BlueprintRevision = payload.Revision
		BuildState.HasUnsavedChanges = true
		BuildState.LaunchPrepReport = nil
		notify()
		return true, false
	end

	return false, true
end

function BuildState.SetError(err: string?)
	BuildState.LastError = err
	if err then
		BuildState.StatusMessage = nil
	end
	notify()
end

function BuildState.SetStatusMessage(msg: string?)
	BuildState.StatusMessage = msg
	if msg then
		BuildState.LastError = nil
	end
	notify()
end

function BuildState.Reset()
	BuildState.IsActive = false
	BuildState.AssignedPlot = nil
	BuildState.BuildZone = nil
	BuildState.ExpectedOwnerUserId = nil
	BuildState.SelectedItemId = nil
	BuildState.SelectedPlacedPieceId = nil
	BuildState.RelativeRotation = BuildRotation.Identity()
	BuildState.LastSnappedCFrame = nil
	BuildState.LastSnappedLocalCFrame = nil
	BuildState.IsValidPlacement = false
	BuildState.ValidationReason = nil
	BuildState.ValidationDetail = nil
	BuildState.LastError = nil
	BuildState.StatusMessage = nil
	BuildState.PendingOpCount = 0

	BuildState.PositionMode = GameConfig.Building.PositionModes.Grid
	BuildState.GridResolution = GameConfig.Building.DefaultGridResolution
	BuildState.SmartSnapEnabled = true
	BuildState.FaceSnapEnabled = true
	BuildState.FaceSnapTarget = nil
	BuildState.GuidesEnabled = true
	BuildState.ActiveTool = GameConfig.Building.TransformTools.None
	BuildState.AngleIncrementDeg = GameConfig.Building.DefaultAngleIncrementDeg
	BuildState.ActiveMoveAxis = nil
	BuildState.ActiveRotateAxis = nil
	BuildState.TransformTargetPieceId = nil
	BuildState.TransformBaseLocalCFrame = nil
	BuildState.TransformPreviewLocalCFrame = nil
	BuildState.TransformIsValid = false
	BuildState.TransformDeltaDisplay = nil

	BuildState.BlueprintId = nil
	BuildState.BlueprintName = "Vehículo 1"
	BuildState.BlueprintRevision = 0
	BuildState.BlueprintMetadata = nil
	BuildState.HasUnsavedChanges = false
	BuildState.MaxBlueprints = GameConfig.Blueprints.MaxSavedBlueprintsPerPlayer
	BuildState.StandPresentation = {
		HeightOffset = GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = GameConfig.Stand.DefaultLateralOffset,
	}
	BuildState.LaunchPrepReport = nil
	BuildState.TransitionEpoch = 0
	BuildState.LoadedSlotIndex = nil
	BuildState.WorkshopEpoch = 0
	BuildState.LegacyOverflowCount = 0
	BuildState.RuntimeState = GameConfig.Runtime.States.Editing :: VehicleTypes.VehicleState
	BuildState.RuntimeStatus = nil
	BuildState.RuntimeActionInFlight = false
	BuildState.RuntimeErrorMessage = nil
	BuildState.Inventory = nil
	table.clear(BuildState.BlueprintSummaries)
	table.clear(BuildState.BlueprintSlots)
	table.clear(BuildState.LegacyOverflow)
	table.clear(BuildState.BlueprintPieces)
	table.clear(BuildState.BlueprintConnections)
	notifyReplacedSync()
end

return BuildState

