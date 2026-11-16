--!strict
--[=[
	VehicleBlueprintService
	Administra los VehicleBlueprint autoritativos en memoria por jugador, separando estrictamente:
	- WorkshopDraft (_blueprintsByUserId): borrador editable activo en el taller.
	- SavedSlots (_savedSlotsByUserId): hasta 3 tarjetas persistentes ("1", "2", "3") + LegacyOverflow recuperable.
	- EditableVehicle: representación estática anclada en `Workspace.Plots.<PlotId>.DynamicRuntime.EditableVehicle`.
	No administra StandPreview ni VehicleRuntime (delegados a servicios desacoplados).
]=]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local TextService = game:GetService("TextService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildGrid = require(ReplicatedStorage.Shared.Building.BuildGrid)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildSnapPolicy = require(ReplicatedStorage.Shared.Building.BuildSnapPolicy)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
local VehicleCoordinateMath = require(ReplicatedStorage.Shared.Building.VehicleCoordinateMath)
local WheelAutoConfiguration = require(ReplicatedStorage.Shared.Building.WheelAutoConfiguration)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BlueprintPersistenceService = require(ServerScriptService.Server.Services.BlueprintPersistenceService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local BoosterInventoryService = require(ServerScriptService.Server.Services.BoosterInventoryService)
local PlotService = require(ServerScriptService.Server.Services.PlotService)

export type BlueprintChangeKind =
	"PieceAdded"
	| "PieceRemoved"
	| "PieceTransformed"
	| "PieceConfigUpdated"
	| "BlueprintLoaded"
	| "BlueprintCreated"
	| "BlueprintSaved"
	| "BlueprintRenamed"
	| "PresentationChanged"
	| "AssemblySelectionChanged"
	| "WorkshopCleared"
	| "SlotSaved"
	| "SlotOverwritten"
	| "SlotRenamed"
	| "SlotDeleted"
	| "LegacyRecovered"
	| "InventoryUnlinked"
	| "PlayerCleared"

export type BlueprintChangedListener = (
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	kind: BlueprintChangeKind,
	blueprint: VehicleTypes.VehicleBlueprint?,
	extra: any?
) -> ()

type EditableVisualState = {
	RootModel: Model,
	PiecesById: { [string]: Model },
}

local VehicleBlueprintService = {
	Name = "VehicleBlueprintService",
}

local _blueprintsByUserId: { [number]: VehicleTypes.VehicleBlueprint } = {}
local _savedSlotsByUserId: { [number]: { [string]: VehicleTypes.VehicleBlueprint? } } = {}
local _legacyOverflowByUserId: { [number]: { VehicleTypes.LegacyOverflowEntry } } = {}
local _storageRevisionByUserId: { [number]: number } = {}
local _workshopEpochByUserId: { [number]: number } = {}
local _loadedPersistenceByUserId: { [number]: boolean } = {}
local _persistenceLoadFailedByUserId: { [number]: boolean } = {}
local _slotOpLockByUserId: { [number]: boolean } = {}
local _customTextFilterForTests: ((string, number) -> string)? = nil
local _dirtyByUserId: { [number]: boolean } = {}
local _piecesByIdByUserId: { [number]: { [string]: VehicleTypes.BlueprintPiece } } = {}
local _pieceCounterByUserId: { [number]: number } = {}
local _blueprintCounterByUserId: { [number]: number } = {}
local _liftOffsetByUserId: { [number]: VehicleTypes.BuildAssemblyOffset } = {}
local _visualsByUserId: { [number]: EditableVisualState } = {}
local _changeListeners: { BlueprintChangedListener } = {}
local _connections: { RBXScriptConnection } = {}
local _unsubPlotReleased: (() -> ())? = nil
local _itemAssetsRoot: Instance? = nil
local _fallbackSizeCache: { [string]: Vector3 } = {}
local _initialized = false
local _started = false

local function emitChanged(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	kind: BlueprintChangeKind,
	blueprint: VehicleTypes.VehicleBlueprint?,
	extra: any?
)
	for _, fn in ipairs(table.clone(_changeListeners)) do
		fn(player, plot, kind, blueprint, extra)
	end
end

local function trimString(s: string): string
	local trimmed = string.match(s, "^%s*(.-)%s*$")
	return trimmed or ""
end

local function validateBlueprintName(rawName: any): (boolean, string?, string?)
	if type(rawName) ~= "string" then
		return false, nil, "El nombre debe ser texto válido"
	end
	if string.find(rawName, "[%z%c<>]") ~= nil then
		return false, nil, "El nombre contiene caracteres no permitidos"
	end
	local trimmed = trimString(rawName)
	local utf8Len = utf8.len(trimmed)
	if not utf8Len or utf8Len < (GameConfig.Blueprints.MinNameLength or 1) or utf8Len > GameConfig.Blueprints.MaxNameLength then
		return false, nil, `El nombre debe tener entre 1 y {GameConfig.Blueprints.MaxNameLength} caracteres`
	end
	if string.match(trimmed, "[%wÁÉÍÓÚÜÑáéíóúüñ]") == nil then
		return false, nil, "El nombre debe incluir al menos una letra o número"
	end
	return true, trimmed, nil
end

local function filterAndValidateName(userId: number, rawName: any): (boolean, string?, string?)
	local okBase, trimmed, errMsg = validateBlueprintName(rawName)
	if not okBase or not trimmed then
		return false, nil, errMsg or "Nombre de blueprint inválido"
	end

	if _customTextFilterForTests then
		local okTest, filtered = pcall(_customTextFilterForTests, trimmed, userId)
		if okTest and type(filtered) == "string" then
			local afterTrim = trimString(filtered)
			if #afterTrim >= 1 then
				return true, string.sub(afterTrim, 1, GameConfig.Blueprints.MaxNameLength), nil
			end
			return false, nil, "Nombre rechazado por filtro de texto"
		end
	elseif RunService:IsRunning() and userId > 0 and Players:GetPlayerByUserId(userId) ~= nil then
		local okFilter, filtered = pcall(function()
			local res = TextService:FilterStringAsync(trimmed, userId)
			return res:GetNonChatStringForBroadcastAsync()
		end)
		if okFilter and type(filtered) == "string" and #trimString(filtered) > 0 then
			return true, string.sub(trimString(filtered), 1, GameConfig.Blueprints.MaxNameLength), nil
		end
	end

	return true, trimmed, nil
end

local function makeFallbackName(indexNum: number): string
	local candidate = `{GameConfig.Blueprints.DefaultNamePrefix} {indexNum}`
	return string.sub(candidate, 1, GameConfig.Blueprints.MaxNameLength)
end

local function resolvePieceSize(itemId: string): Vector3?
	local geom = ConnectionService.GetItemGeometry(itemId)
	if geom then
		return geom.Size
	end
	local cached = _fallbackSizeCache[itemId]
	if cached then
		return cached
	end
	if not ItemRegistry.Has(itemId) then
		return nil
	end
	local def = ItemRegistry.Get(itemId)
	local assetsRoot = _itemAssetsRoot or ServerStorage:FindFirstChild("ItemAssets")
	local templateModel = ItemRegistry.ResolveModel(assetsRoot, def)
	if templateModel then
		local _, bbSize = templateModel:GetBoundingBox()
		_fallbackSizeCache[itemId] = bbSize
		return bbSize
	end
	return nil
end

local function recomputeVehicleOrigin(bp: VehicleTypes.VehicleBlueprint)
	if #bp.Pieces == 0 then
		bp.VehicleOrigin = CFrame.identity
		return
	end
	bp.VehicleOrigin = VehicleCoordinateMath.ComputeBaseAnchor(bp.Pieces, resolvePieceSize)
end

local function configureStaticEditablePiece(model: Model, piece: VehicleTypes.BlueprintPiece, ownerUserId: number)
	local behaviors = model:FindFirstChild("Behaviors")
	if behaviors then
		behaviors:Destroy()
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = true
			descendant.CanQuery = true
			descendant.CanTouch = false
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
			if PhysicsService:IsCollisionGroupRegistered(GameConfig.Runtime.CollisionGroups.EditableVehicle) then
				descendant.CollisionGroup = GameConfig.Runtime.CollisionGroups.EditableVehicle
			end
			if descendant:IsA("VehicleSeat") or descendant:IsA("Seat") then
				descendant.Disabled = true
			end
		elseif descendant:IsA("Constraint") or descendant:IsA("WeldConstraint") then
			descendant.Enabled = false
		end
	end

	if model.PrimaryPart == nil then
		local primary = model:FindFirstChild("Primary")
		if primary and primary:IsA("BasePart") then
			model.PrimaryPart = primary
		else
			local anyPart = model:FindFirstChildWhichIsA("BasePart", true)
			if anyPart then
				model.PrimaryPart = anyPart
			end
		end
	end

	model.Name = piece.InstanceId
	model:SetAttribute("PieceInstanceId", piece.InstanceId)
	model:SetAttribute(GameConfig.ItemAttributes.ItemId, piece.ItemId)
	model:SetAttribute(GameConfig.PlotAttributes.OwnerUserId, ownerUserId)
	local hasManualWheelCfg = type(piece.Config) == "table"
		and type(piece.Config.Wheel) == "table"
		and next(piece.Config.Wheel) ~= nil
	model:SetAttribute("HasManualWheelConfig", hasManualWheelCfg)

	local itemDef = ItemRegistry.TryGet(piece.ItemId)
	if itemDef and itemDef.Category == "Engines" then
		local stats = EngineInventoryService.ResolvePieceEffectiveStats(ownerUserId, piece)
		model:SetAttribute("InventoryInstanceId", piece.InventoryInstanceId or "")
		model:SetAttribute("EngineFamilyId", stats.EngineFamilyId)
		model:SetAttribute("EngineSizeId", stats.EngineSizeId)
		model:SetAttribute("EngineVariantId", stats.VariantId)
		model:SetAttribute("EngineRarityId", stats.RarityId)
		model:SetAttribute("EnginePeakTorque", stats.PeakTorque)
		model:SetAttribute("EnginePowerRating", stats.PowerRating)
		model:SetAttribute("EngineSpeedRegular", stats.SpeedRegular)
		model:SetAttribute("EngineWeight", stats.Weight)
		model:SetAttribute("EngineFullLabel", stats.FullLabel)
		model:SetAttribute("EngineBalanceStatus", stats.BalanceStatus)
	elseif itemDef and itemDef.Category == "Boosters" then
		local stats = BoosterInventoryService.ResolvePieceEffectiveStats(ownerUserId, piece)
		model:SetAttribute("InventoryInstanceId", piece.InventoryInstanceId or "")
		model:SetAttribute("BoosterFamilyId", stats.BoosterFamilyId)
		model:SetAttribute("BoosterSizeId", stats.BoosterSizeId)
		model:SetAttribute("BoosterVariantId", stats.VariantId)
		model:SetAttribute("BoosterRarityId", stats.RarityId)
		model:SetAttribute("BoosterThrust", stats.Thrust)
		model:SetAttribute("BoosterSpeedBoostMultiplier", stats.SpeedBoostMultiplier)
		model:SetAttribute("BoosterConsumption", stats.BoostConsumption)
		model:SetAttribute("BoosterIntegratedFuel", stats.IntegratedFuel)
		model:SetAttribute("BoosterWeight", stats.Weight)
		model:SetAttribute("BoosterFullLabel", stats.FullLabel)
		model:SetAttribute("BoosterBalanceStatus", stats.BalanceStatus)
	end
end

local function getTemplateModelForItem(itemId: string): Model
	local def = ItemRegistry.Get(itemId)
	local assetsRoot = _itemAssetsRoot :: Instance
	local templateModel = ItemRegistry.ResolveModel(assetsRoot, def)
	if not templateModel then
		error(`[VehicleBlueprintService] Missing model '{ItemRegistry.GetAssetFolder(def)}/{def.Model}'`)
	end
	return templateModel
end

local function getLiftOffsetForUser(userId: number): VehicleTypes.BuildAssemblyOffset
	local offset = _liftOffsetByUserId[userId]
	if offset then
		return {
			HeightOffset = offset.HeightOffset,
			LateralOffset = offset.LateralOffset,
		}
	end
	return {
		HeightOffset = GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = GameConfig.Stand.DefaultLateralOffset,
	}
end

local function setLiftOffsetForUser(userId: number, heightOffset: number, lateralOffset: number): VehicleTypes.BuildAssemblyOffset
	local clean: VehicleTypes.BuildAssemblyOffset = {
		HeightOffset = heightOffset,
		LateralOffset = lateralOffset,
	}
	_liftOffsetByUserId[userId] = clean
	return {
		HeightOffset = clean.HeightOffset,
		LateralOffset = clean.LateralOffset,
	}
end

local function syncLiftAttributesOnRoot(
	rootModel: Model,
	liftOffset: VehicleTypes.BuildAssemblyOffset,
	effectiveZoneCFrame: CFrame?,
	plot: PlotService.PlotRecord?
)
	rootModel:SetAttribute(GameConfig.PlotAttributes.BuildLiftHeight, liftOffset.HeightOffset)
	rootModel:SetAttribute(GameConfig.PlotAttributes.BuildLiftLateral, liftOffset.LateralOffset)
	if plot and plot.Zones and plot.Zones.BuildZone then
		plot.Zones.BuildZone:SetAttribute(GameConfig.PlotAttributes.BuildLiftHeight, liftOffset.HeightOffset)
		plot.Zones.BuildZone:SetAttribute(GameConfig.PlotAttributes.BuildLiftLateral, liftOffset.LateralOffset)
	end
	if effectiveZoneCFrame then
		rootModel.WorldPivot = effectiveZoneCFrame
	end
end

local function rebuildEditableVehicleModel(
	userId: number,
	plot: PlotService.PlotRecord,
	bp: VehicleTypes.VehicleBlueprint
): EditableVisualState
	local liftOffset = getLiftOffsetForUser(userId)
	local effectiveZoneCF = VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(plot.Zones.BuildZone.CFrame, liftOffset)

	local newRoot = Instance.new("Model")
	newRoot.Name = GameConfig.Building.EditableVehicleName
	newRoot:SetAttribute(GameConfig.PlotAttributes.OwnerUserId, userId)
	newRoot:SetAttribute("BlueprintId", bp.BlueprintId)
	newRoot:SetAttribute("Revision", bp.Revision)
	syncLiftAttributesOnRoot(newRoot, liftOffset, effectiveZoneCF, plot)

	local piecesById: { [string]: Model } = {}
	for _, piece in ipairs(bp.Pieces) do
		local templateModel = getTemplateModelForItem(piece.ItemId)
		local visualClone = templateModel:Clone()
		configureStaticEditablePiece(visualClone, piece, userId)
		local worldCF = effectiveZoneCF:ToWorldSpace(piece.LocalCFrame)
		visualClone:PivotTo(worldCF)
		visualClone.Parent = newRoot
		piecesById[piece.InstanceId] = visualClone
	end

	local oldVisual = _visualsByUserId[userId]
	local oldStray = plot.DynamicContainer:FindFirstChild(GameConfig.Building.EditableVehicleName)
	if oldStray and (not oldVisual or oldStray ~= oldVisual.RootModel) then
		oldStray:Destroy()
	end
	if oldVisual and oldVisual.RootModel.Parent then
		oldVisual.RootModel:Destroy()
	end

	newRoot.Parent = plot.DynamicContainer
	local state: EditableVisualState = {
		RootModel = newRoot,
		PiecesById = piecesById,
	}
	_visualsByUserId[userId] = state
	return state
end

local function ensureEditableVisualState(userId: number, plot: PlotService.PlotRecord, blueprintId: string?): EditableVisualState
	local existing = _visualsByUserId[userId]
	if existing and existing.RootModel.Parent == plot.DynamicContainer then
		return existing
	end

	local oldModel = plot.DynamicContainer:FindFirstChild(GameConfig.Building.EditableVehicleName)
	if oldModel then
		oldModel:Destroy()
	end

	local liftOffset = getLiftOffsetForUser(userId)
	local effectiveZoneCF = VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(plot.Zones.BuildZone.CFrame, liftOffset)

	local rootModel = Instance.new("Model")
	rootModel.Name = GameConfig.Building.EditableVehicleName
	rootModel:SetAttribute(GameConfig.PlotAttributes.OwnerUserId, userId)
	rootModel:SetAttribute("BlueprintId", blueprintId or "")
	rootModel:SetAttribute("Revision", 0)
	syncLiftAttributesOnRoot(rootModel, liftOffset, effectiveZoneCF)
	rootModel.Parent = plot.DynamicContainer

	local state: EditableVisualState = {
		RootModel = rootModel,
		PiecesById = {},
	}
	_visualsByUserId[userId] = state
	return state
end

local function applyEditableVehicleLiftTransform(
	userId: number,
	plot: PlotService.PlotRecord?,
	bp: VehicleTypes.VehicleBlueprint,
	liftOffset: VehicleTypes.BuildAssemblyOffset
)
	local visual = _visualsByUserId[userId]
	if not visual or not visual.RootModel.Parent then
		if plot then
			rebuildEditableVehicleModel(userId, plot, bp)
		end
		return
	end

	visual.RootModel:SetAttribute("Revision", bp.Revision)
	if not plot then
		syncLiftAttributesOnRoot(visual.RootModel, liftOffset, nil)
		return
	end

	local effectiveZoneCF = VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(plot.Zones.BuildZone.CFrame, liftOffset)
	syncLiftAttributesOnRoot(visual.RootModel, liftOffset, effectiveZoneCF, plot)

	local piecesById = visual.PiecesById
	for _, piece in ipairs(bp.Pieces) do
		local pieceModel = piecesById[piece.InstanceId]
		if pieceModel and pieceModel.Parent then
			pieceModel:PivotTo(effectiveZoneCF:ToWorldSpace(piece.LocalCFrame))
		end
	end
end

local function getSavedCountForUser(userId: number): number
	local slots = _savedSlotsByUserId[userId]
	if not slots then
		return 0
	end
	local count = 0
	for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
		if slots[BlueprintSerializer.SlotKey(slotIndex)] ~= nil then
			count += 1
		end
	end
	return count
end

local function getFirstEmptySlotIndex(userId: number): number?
	local slots = _savedSlotsByUserId[userId]
	if not slots then
		return 1
	end
	for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
		if slots[BlueprintSerializer.SlotKey(slotIndex)] == nil then
			return slotIndex
		end
	end
	return nil
end

local function findSlotByBlueprintId(userId: number, blueprintId: string): (number?, VehicleTypes.VehicleBlueprint?)
	local slots = _savedSlotsByUserId[userId]
	if not slots then
		return nil, nil
	end
	for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
		local slotBp = slots[BlueprintSerializer.SlotKey(slotIndex)]
		if slotBp and slotBp.BlueprintId == blueprintId then
			return slotIndex, slotBp
		end
	end
	return nil, nil
end

local function ensureUserLibraryStructures(userId: number)
	if not _savedSlotsByUserId[userId] then
		_savedSlotsByUserId[userId] = {}
	end
	if not _legacyOverflowByUserId[userId] then
		_legacyOverflowByUserId[userId] = {}
	end
	if _storageRevisionByUserId[userId] == nil then
		_storageRevisionByUserId[userId] = 0
	end
	if _workshopEpochByUserId[userId] == nil then
		_workshopEpochByUserId[userId] = 0
	end
	if not _pieceCounterByUserId[userId] then
		_pieceCounterByUserId[userId] = 0
	end
	if not _blueprintCounterByUserId[userId] then
		_blueprintCounterByUserId[userId] = 0
	end
end

local function unbindWorkshopInventoryUnits(bp: VehicleTypes.VehicleBlueprint?)
	if not bp then
		return
	end
	for _, piece in ipairs(bp.Pieces) do
		if piece.InventoryInstanceId then
			EngineInventoryService.UnbindUnitFromPiece(piece.InstanceId, piece.InventoryInstanceId)
			BoosterInventoryService.UnbindUnitFromPiece(piece.InstanceId, piece.InventoryInstanceId)
		end
	end
end

local function bindWorkshopInventoryUnits(player: PlotService.PlayerLike, bp: VehicleTypes.VehicleBlueprint?)
	if not bp then
		return
	end
	InventoryService.EnsurePlayerLoaded(player)
	for _, piece in ipairs(bp.Pieces) do
		if piece.InventoryInstanceId and #piece.InventoryInstanceId > 0 then
			local def = ItemRegistry.TryGet(piece.ItemId)
			if def and def.Category == "Engines" then
				EngineInventoryService.BindUnitToPiece(player, bp.BlueprintId, piece.InstanceId, piece.InventoryInstanceId)
			elseif def and def.Category == "Boosters" then
				BoosterInventoryService.BindUnitToPiece(player, bp.BlueprintId, piece.InstanceId, piece.InventoryInstanceId)
			end
		end
	end
end

local ensureUserLoadedFromPersistence: (userId: number) -> (boolean, string?, string?)

local function computeBlueprintUsageSummary(userId: number): InventoryService.BlueprintUsageSummary
	if not _loadedPersistenceByUserId[userId] and not _persistenceLoadFailedByUserId[userId] then
		ensureUserLoadedFromPersistence(userId)
	end

	local workshopCounts: { [string]: number } = {}
	local workshopUnits: { [string]: boolean } = {}
	local active = _blueprintsByUserId[userId]
	if active then
		for _, piece in ipairs(active.Pieces) do
			workshopCounts[piece.ItemId] = (workshopCounts[piece.ItemId] or 0) + 1
			if type(piece.InventoryInstanceId) == "string" and #piece.InventoryInstanceId > 0 then
				workshopUnits[piece.InventoryInstanceId] = true
			end
		end
	end

	local maxSlotCounts: { [string]: number } = {}
	local slotIndicesByItemId: { [string]: { [number]: number } } = {}
	local slotIndicesByUnitId: { [string]: { number } } = {}
	local seenUnitSlot: { [string]: { [number]: boolean } } = {}

	local slots = _savedSlotsByUserId[userId]
	if slots then
		for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
			local slotBp = slots[BlueprintSerializer.SlotKey(slotIndex)]
			if slotBp then
				local perItemInSlot: { [string]: number } = {}
				for _, piece in ipairs(slotBp.Pieces) do
					perItemInSlot[piece.ItemId] = (perItemInSlot[piece.ItemId] or 0) + 1
					if type(piece.InventoryInstanceId) == "string" and #piece.InventoryInstanceId > 0 then
						local unitSlots = slotIndicesByUnitId[piece.InventoryInstanceId]
						if not unitSlots then
							unitSlots = {}
							slotIndicesByUnitId[piece.InventoryInstanceId] = unitSlots
							seenUnitSlot[piece.InventoryInstanceId] = {}
						end
						if not seenUnitSlot[piece.InventoryInstanceId][slotIndex] then
							seenUnitSlot[piece.InventoryInstanceId][slotIndex] = true
							table.insert(unitSlots, slotIndex)
						end
					end
				end
				for itemId, count in pairs(perItemInSlot) do
					local bySlot = slotIndicesByItemId[itemId]
					if not bySlot then
						bySlot = {}
						slotIndicesByItemId[itemId] = bySlot
					end
					bySlot[slotIndex] = count
					maxSlotCounts[itemId] = math.max(maxSlotCounts[itemId] or 0, count)
				end
			end
		end
	end

	return {
		WorkshopItemCounts = workshopCounts,
		WorkshopUnitIds = workshopUnits,
		MaxSlotItemCounts = maxSlotCounts,
		SlotIndicesByItemId = slotIndicesByItemId,
		SlotIndicesByUnitId = slotIndicesByUnitId,
	}
end

local function cloneUserSlotsTable(userId: number): { [string]: VehicleTypes.VehicleBlueprint? }
	local out: { [string]: VehicleTypes.VehicleBlueprint? } = {}
	local slots = _savedSlotsByUserId[userId]
	if slots then
		for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
			local key = BlueprintSerializer.SlotKey(slotIndex)
			if slots[key] then
				out[key] = BlueprintSerializer.CloneBlueprint(slots[key] :: VehicleTypes.VehicleBlueprint)
			end
		end
	end
	return out
end

local function buildPlayerStorageRecord(userId: number): VehicleTypes.PlayerBlueprintStorage
	local overflowCopy: { VehicleTypes.LegacyOverflowEntry } = {}
	local overflowList = _legacyOverflowByUserId[userId]
	if overflowList then
		for _, entry in ipairs(overflowList) do
			table.insert(overflowCopy, {
				OriginalBlueprintId = entry.OriginalBlueprintId,
				Name = entry.Name,
				PieceCount = entry.PieceCount,
				UpdatedAt = entry.UpdatedAt,
				MigratedAt = entry.MigratedAt,
				RecoveredToSlot = entry.RecoveredToSlot,
				SerializedBlueprint = BlueprintSerializer.DeepCloneTable(entry.SerializedBlueprint) :: { [string]: any },
			})
		end
	end

	local draft = _blueprintsByUserId[userId]
	return {
		StorageSchemaVersion = GameConfig.Blueprints.StorageSchemaVersion,
		OwnerUserId = userId,
		StorageRevision = _storageRevisionByUserId[userId] or 0,
		UpdatedAt = os.time(),
		WorkshopDraft = if draft then BlueprintSerializer.CloneBlueprint(draft) else nil,
		Slots = cloneUserSlotsTable(userId),
		LegacyOverflow = if #overflowCopy > 0 then overflowCopy else nil,
	}
end

ensureUserLoadedFromPersistence = function(userId: number): (boolean, string?, string?)
	ensureUserLibraryStructures(userId)
	if _loadedPersistenceByUserId[userId] then
		return true, nil, nil
	end

	local okLoad, storage, errCode, errMsg = BlueprintPersistenceService.LoadPlayerStorage(userId)
	if not okLoad or not storage then
		_persistenceLoadFailedByUserId[userId] = true
		return false, errCode or BuildProtocol.ErrorCodes.PersistenceFailed, errMsg or "Error leyendo persistencia"
	end

	_loadedPersistenceByUserId[userId] = true
	_persistenceLoadFailedByUserId[userId] = false
	_storageRevisionByUserId[userId] = storage.StorageRevision or 0

	local slotsMap: { [string]: VehicleTypes.VehicleBlueprint? } = {}
	local maxBpCounter = _blueprintCounterByUserId[userId] or 0
	for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
		local key = BlueprintSerializer.SlotKey(slotIndex)
		local slotBp = storage.Slots and storage.Slots[key]
		if slotBp then
			slotsMap[key] = slotBp
			local bpNum = tonumber(string.match(slotBp.BlueprintId, "_(%d+)$"))
			if bpNum and bpNum > maxBpCounter then
				maxBpCounter = bpNum
			end
		end
	end
	_savedSlotsByUserId[userId] = slotsMap
	_legacyOverflowByUserId[userId] = storage.LegacyOverflow or {}
	_blueprintCounterByUserId[userId] = maxBpCounter

	if storage.WorkshopDraft and _blueprintsByUserId[userId] == nil then
		local restoredDraft = storage.WorkshopDraft
		_blueprintsByUserId[userId] = restoredDraft
		local bpNum = tonumber(string.match(restoredDraft.BlueprintId, "_(%d+)$"))
		if bpNum and bpNum > maxBpCounter then
			_blueprintCounterByUserId[userId] = bpNum
		end
	end

	return true, nil, nil
end

local function persistUserStorage(userId: number): (boolean, string?, string?)
	if _persistenceLoadFailedByUserId[userId] then
		local retryOk, retryCode, retryMsg = ensureUserLoadedFromPersistence(userId)
		if not retryOk then
			return false, retryCode or BuildProtocol.ErrorCodes.PersistenceFailed, retryMsg or "No se pudo verificar almacenamiento previo"
		end
	end

	local nextStorageRev = (_storageRevisionByUserId[userId] or 0) + 1
	local record = buildPlayerStorageRecord(userId)
	record.StorageRevision = nextStorageRev

	local okSave, errCode, errMsg = BlueprintPersistenceService.SavePlayerStorage(userId, record)
	if not okSave then
		return false, errCode or BuildProtocol.ErrorCodes.PersistenceFailed, errMsg or "No se pudo guardar en DataStore"
	end

	_storageRevisionByUserId[userId] = nextStorageRev
	_loadedPersistenceByUserId[userId] = true
	_persistenceLoadFailedByUserId[userId] = false
	return true, nil, nil
end

local function allocateNextBlueprintId(userId: number): string
	ensureUserLibraryStructures(userId)
	local seq = (_blueprintCounterByUserId[userId] or 0) + 1
	_blueprintCounterByUserId[userId] = seq
	return `bp_{userId}_{seq}`
end

local function makeEmptyBlueprint(userId: number, blueprintId: string, name: string): VehicleTypes.VehicleBlueprint
	local now = os.time()
	return {
		SchemaVersion = GameConfig.Blueprints.CurrentSchemaVersion,
		BlueprintId = blueprintId,
		OwnerUserId = userId,
		Name = name,
		Revision = 0,
		CreatedAt = now,
		UpdatedAt = now,
		VehicleOrigin = CFrame.identity,
		Presentation = {
			HeightOffset = GameConfig.Stand.DefaultHeightOffset,
			LateralOffset = GameConfig.Stand.DefaultLateralOffset,
		},
		Metadata = nil,
		Pieces = {},
		Connections = {},
	}
end

local function rebuildPieceMapForActive(userId: number, bp: VehicleTypes.VehicleBlueprint)
	local pieceMap: { [string]: VehicleTypes.BlueprintPiece } = {}
	local maxNumericSuffix = _pieceCounterByUserId[userId] or 0
	for _, piece in ipairs(bp.Pieces) do
		pieceMap[piece.InstanceId] = piece
		local suffixStr = string.match(piece.InstanceId, "_(%d+)$")
		local num = if suffixStr then tonumber(suffixStr) else nil
		if num and num > maxNumericSuffix then
			maxNumericSuffix = num
		end
	end
	_piecesByIdByUserId[userId] = pieceMap
	_pieceCounterByUserId[userId] = maxNumericSuffix
end

local function validateBlueprintIntegrityForLoad(
	bp: VehicleTypes.VehicleBlueprint,
	plot: PlotService.PlotRecord?
): (boolean, string?, string?, VehicleTypes.BuildAssemblyOffset?)
	if #bp.Pieces > GameConfig.Building.MaxPiecesPerVehicle then
		return false, BuildProtocol.ErrorCodes.MaxPiecesReached, "Cantidad de piezas excede MaxPiecesPerVehicle", nil
	end

	local invOk, invErrCode, invErrMsg = InventoryService.ValidateBlueprintForLoad(bp.OwnerUserId, bp)
	if not invOk then
		return false, invErrCode or BuildProtocol.ErrorCodes.InsufficientInventory, invErrMsg or "Inventario insuficiente para este blueprint", nil
	end

	local initialLift: VehicleTypes.BuildAssemblyOffset = {
		HeightOffset = GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = GameConfig.Stand.DefaultLateralOffset,
	}
	if plot and #bp.Pieces > 0 then
		local plat = plot.Model:FindFirstChild("Platform")
		local floorLocalY = VehicleCoordinateMath.ComputeZoneFloorLocalY(
			plot.Zones.BuildZone,
			if plat and plat:IsA("BasePart") then plat else nil
		)
		local liftBounds = VehicleCoordinateMath.ComputeLiftBounds(
			bp.Pieces,
			resolvePieceSize,
			plot.Zones.BuildZone.Size,
			GameConfig.Building.DefaultZoneHeight,
			floorLocalY
		)
		initialLift.HeightOffset = liftBounds.DefaultRestHeightOffset
		initialLift.LateralOffset = liftBounds.DefaultRestLateralOffset
	end

	local driverSeatCount = 0
	local candidatePieceMap: { [string]: VehicleTypes.BlueprintPiece } = {}
	for _, piece in ipairs(bp.Pieces) do
		candidatePieceMap[piece.InstanceId] = piece
	end

	for _, piece in ipairs(bp.Pieces) do
		if not ItemRegistry.Has(piece.ItemId) then
			return false, BuildProtocol.ErrorCodes.UnknownItem, `Pieza desconocida '{piece.ItemId}'`, nil
		end
		if piece.ItemId == GameConfig.LaunchPrep.DriverSeatItemId then
			driverSeatCount += 1
			if driverSeatCount > GameConfig.Blueprints.MaxDriverSeatsPerBlueprint then
				return false,
					BuildProtocol.ErrorCodes.TooManyDriverSeats,
					`El blueprint excede el máximo de {GameConfig.Blueprints.MaxDriverSeatsPerBlueprint} DriverSeat permitido`,
					nil
			end
		end

		local pieceSize = resolvePieceSize(piece.ItemId)
		if not pieceSize then
			return false, BuildProtocol.ErrorCodes.MissingAsset, `Modelo faltante para '{piece.ItemId}'`, nil
		end
		local policyOk, _, rotReason = BuildSnapPolicy.ValidateCFrameForItem(piece.ItemId, piece.LocalCFrame)
		if not policyOk then
			return false, BuildProtocol.ErrorCodes.InvalidRotation, rotReason or "CFrame inválido en blueprint", nil
		end

		if type(piece.Config) == "table" and piece.Config.Wheel ~= nil then
			local def = ItemRegistry.TryGet(piece.ItemId)
			if not def or def.Category ~= "Wheels" then
				return false, BuildProtocol.ErrorCodes.PieceNotConfigurable, `Config.Wheel inválido en pieza '{piece.ItemId}'`, nil
			end
			local okW, _, wErrCode, wErrMsg = WheelAutoConfiguration.ValidateManualOverrides(piece.Config.Wheel)
			if not okW then
				return false, wErrCode or BuildProtocol.ErrorCodes.InvalidConfigRange, wErrMsg or "Configuración de rueda inválida en blueprint", nil
			end
		end
		if plot then
			local rotatedExtents = BuildRotation.GetRotatedExtents(pieceSize, piece.LocalCFrame.Rotation)
			local inBounds, boundsErr = BuildGrid.ValidateBounds(
				plot.Zones.BuildZone.Size,
				piece.LocalCFrame.Position,
				rotatedExtents,
				GameConfig.Building.DefaultZoneHeight,
				initialLift
			)
			if not inBounds then
				return false, BuildProtocol.ErrorCodes.OutOfBounds, `Pieza fuera de BuildZone ({tostring(boundsErr)})`, nil
			end
		end
	end

	return true, nil, nil, initialLift
end

local function toSummary(bp: VehicleTypes.VehicleBlueprint, isActive: boolean, hasUnsavedChanges: boolean): VehicleTypes.BlueprintSummary
	return {
		BlueprintId = bp.BlueprintId,
		Name = bp.Name,
		SchemaVersion = bp.SchemaVersion,
		Revision = bp.Revision,
		PieceCount = #bp.Pieces,
		CreatedAt = bp.CreatedAt,
		UpdatedAt = bp.UpdatedAt,
		IsActive = isActive,
		HasUnsavedChanges = isActive and hasUnsavedChanges,
		Presentation = BlueprintSerializer.SanitizePresentation(bp.Presentation),
	}
end

function VehicleBlueprintService.Init(options: { ItemAssetsRoot: Instance? }?)
	if _initialized then
		return
	end
	ItemRegistry.Init()
	BlueprintPersistenceService.Init()
	InventoryService.Init()
	InventoryService.RegisterBlueprintUsageProvider(computeBlueprintUsageSummary)
	_itemAssetsRoot = (options and options.ItemAssetsRoot) or ServerStorage:WaitForChild("ItemAssets")
	table.clear(_fallbackSizeCache)
	if not _unsubPlotReleased then
		_unsubPlotReleased = PlotService.OnPlotReleased(function(playerLike)
			VehicleBlueprintService.ClearPlayer(playerLike)
		end)
	end
	_initialized = true
end

function VehicleBlueprintService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	BlueprintPersistenceService.Start()

	table.insert(
		_connections,
		Players.PlayerRemoving:Connect(function(player)
			VehicleBlueprintService.ClearPlayer(player)
		end)
	)

	if not _unsubPlotReleased then
		_unsubPlotReleased = PlotService.OnPlotReleased(function(playerLike)
			VehicleBlueprintService.ClearPlayer(playerLike)
		end)
	end

	_started = true
end

function VehicleBlueprintService.OnBlueprintChanged(listener: BlueprintChangedListener): () -> ()
	table.insert(_changeListeners, listener)
	return function()
		local idx = table.find(_changeListeners, listener)
		if idx then
			table.remove(_changeListeners, idx)
		end
	end
end

function VehicleBlueprintService.GetOrCreateBlueprint(player: PlotService.PlayerLike): VehicleTypes.VehicleBlueprint
	local bp = _blueprintsByUserId[player.UserId]
	if not bp then
		ensureUserLoadedFromPersistence(player.UserId)
		bp = _blueprintsByUserId[player.UserId]
		if not bp then
			local firstId = allocateNextBlueprintId(player.UserId)
			bp = makeEmptyBlueprint(player.UserId, firstId, makeFallbackName(1))
			_blueprintsByUserId[player.UserId] = bp
			_dirtyByUserId[player.UserId] = false
			_piecesByIdByUserId[player.UserId] = {}
		else
			rebuildPieceMapForActive(player.UserId, bp)
			ConnectionService.ReconcileBlueprintConnections(bp)
			ConnectionService.RebuildPlayerCache(player.UserId, bp)
			bindWorkshopInventoryUnits(player, bp)
			_dirtyByUserId[player.UserId] = false
		end
	end
	return bp
end

function VehicleBlueprintService.GetLiftOffset(player: PlotService.PlayerLike): VehicleTypes.BuildAssemblyOffset
	return getLiftOffsetForUser(player.UserId)
end

function VehicleBlueprintService.GetEffectiveBuildZoneCFrame(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord
): CFrame
	return VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(plot.Zones.BuildZone.CFrame, getLiftOffsetForUser(player.UserId))
end

function VehicleBlueprintService.ComputeLiftBoundsForPlayer(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?
): VehicleTypes.LiftBounds
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local zoneSize = if plot then plot.Zones.BuildZone.Size else Vector3.new(40, 1, 40)
	local floorLocalY: number? = nil
	if plot then
		local plat = plot.Model:FindFirstChild("Platform")
		floorLocalY = VehicleCoordinateMath.ComputeZoneFloorLocalY(
			plot.Zones.BuildZone,
			if plat and plat:IsA("BasePart") then plat else nil
		)
	end
	return VehicleCoordinateMath.ComputeLiftBounds(bp.Pieces, resolvePieceSize, zoneSize, GameConfig.Building.DefaultZoneHeight, floorLocalY)
end

function VehicleBlueprintService.GetBlueprintSnapshot(player: PlotService.PlayerLike): VehicleTypes.VehicleBlueprint
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	recomputeVehicleOrigin(bp)
	local snap = BlueprintSerializer.CloneBlueprint(bp)
	snap.Presentation = getLiftOffsetForUser(player.UserId)
	return snap
end

function VehicleBlueprintService.GetWorkshopEpoch(player: PlotService.PlayerLike): number
	return _workshopEpochByUserId[player.UserId] or 0
end

function VehicleBlueprintService.GetLoadedSlotIndex(player: PlotService.PlayerLike): number?
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	if bp.Metadata and type(bp.Metadata.SourceSlotIndex) == "number" then
		local slotIdx = bp.Metadata.SourceSlotIndex
		local slots = _savedSlotsByUserId[player.UserId]
		if slots and slots[BlueprintSerializer.SlotKey(slotIdx)] ~= nil then
			return slotIdx
		end
	end
	return nil
end

function VehicleBlueprintService.GetBlueprintSlotSummaries(
	player: PlotService.PlayerLike
): (
	{ VehicleTypes.BlueprintSlotSummary },
	number?,
	boolean,
	number,
	{ VehicleTypes.LegacyOverflowSummary }
)
	local active = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	local slots = _savedSlotsByUserId[userId] or {}
	local dirty = _dirtyByUserId[userId] == true
	local loadedSlotIndex = VehicleBlueprintService.GetLoadedSlotIndex(player)

	local summaries: { VehicleTypes.BlueprintSlotSummary } = table.create(GameConfig.Blueprints.MaxSlots)
	for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
		local saved = slots[BlueprintSerializer.SlotKey(slotIndex)]
		if saved then
			local isLoaded = loadedSlotIndex == slotIndex
			table.insert(summaries, {
				SlotIndex = slotIndex,
				State = "Saved",
				IsOccupied = true,
				BlueprintId = saved.BlueprintId,
				Name = saved.Name,
				PieceCount = #saved.Pieces,
				Revision = saved.Revision,
				CreatedAt = saved.CreatedAt,
				UpdatedAt = saved.UpdatedAt,
				IsLoadedInWorkshop = isLoaded,
				HasUnsavedChanges = if isLoaded then dirty else false,
			})
		else
			table.insert(summaries, {
				SlotIndex = slotIndex,
				State = "Empty",
				IsOccupied = false,
				BlueprintId = nil,
				Name = `Slot {slotIndex}`,
				PieceCount = 0,
				Revision = nil,
				CreatedAt = nil,
				UpdatedAt = nil,
				IsLoadedInWorkshop = false,
				HasUnsavedChanges = false,
			})
		end
	end

	local overflowRaw = _legacyOverflowByUserId[userId] or {}
	local overflowSummaries: { VehicleTypes.LegacyOverflowSummary } = table.create(#overflowRaw)
	for _, entry in ipairs(overflowRaw) do
		table.insert(overflowSummaries, {
			OriginalBlueprintId = entry.OriginalBlueprintId,
			Name = entry.Name,
			PieceCount = entry.PieceCount,
			UpdatedAt = entry.UpdatedAt,
			MigratedAt = entry.MigratedAt,
			RecoveredToSlot = entry.RecoveredToSlot,
		})
	end

	return summaries, loadedSlotIndex, dirty, #overflowSummaries, overflowSummaries
end

function VehicleBlueprintService.EnsureWorkshopVisualsForPlot(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?
)
	if not plot then
		return
	end
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	local visual = _visualsByUserId[userId]
	if #bp.Pieces > 0 and (not visual or not visual.RootModel.Parent) then
		rebuildEditableVehicleModel(userId, plot, bp)
		VehicleBlueprintService.SetEditableVehicleVisible(player, VehicleBlueprintService.IsEditableVehicleVisible(player), "WorkshopHydrated")
	end
end

function VehicleBlueprintService.GetSavedBlueprintSnapshot(
	player: PlotService.PlayerLike,
	blueprintId: string
): VehicleTypes.VehicleBlueprint?
	VehicleBlueprintService.GetOrCreateBlueprint(player)
	local _, saved = findSlotByBlueprintId(player.UserId, blueprintId)
	if not saved or saved.OwnerUserId ~= player.UserId then
		return nil
	end
	return BlueprintSerializer.CloneBlueprint(saved)
end

function VehicleBlueprintService.HasUnsavedChanges(player: PlotService.PlayerLike): boolean
	return _dirtyByUserId[player.UserId] == true
end

function VehicleBlueprintService.GetSavedBlueprintCount(player: PlotService.PlayerLike): number
	VehicleBlueprintService.GetOrCreateBlueprint(player)
	return getSavedCountForUser(player.UserId)
end

function VehicleBlueprintService.ListBlueprints(
	player: PlotService.PlayerLike
): ({ VehicleTypes.BlueprintSummary }, string?, boolean)
	local active = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	local slots = _savedSlotsByUserId[userId] or {}
	local dirty = _dirtyByUserId[userId] == true

	local list: { VehicleTypes.BlueprintSummary } = {}
	for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
		local saved = slots[BlueprintSerializer.SlotKey(slotIndex)]
		if saved then
			local isActive = (saved.BlueprintId == active.BlueprintId)
				or (active.Metadata ~= nil and active.Metadata.SourceSlotIndex == slotIndex)
			local sourceForSummary = if isActive then active else saved
			table.insert(list, toSummary(sourceForSummary, isActive, dirty))
		end
	end

	return list, active.BlueprintId, dirty
end

function VehicleBlueprintService.HasPiece(player: PlotService.PlayerLike, pieceInstanceId: string): boolean
	local map = _piecesByIdByUserId[player.UserId]
	return map ~= nil and map[pieceInstanceId] ~= nil
end

function VehicleBlueprintService.GetPieceCount(player: PlotService.PlayerLike): number
	local bp = _blueprintsByUserId[player.UserId]
	return if bp then #bp.Pieces else 0
end

function VehicleBlueprintService.GetCurrentRevision(player: PlotService.PlayerLike): (number, string?)
	local bp = _blueprintsByUserId[player.UserId]
	if bp then
		return bp.Revision, bp.BlueprintId
	end
	return 0, nil
end

function VehicleBlueprintService.AllocateNextPieceId(player: PlotService.PlayerLike): string
	local current = (_pieceCounterByUserId[player.UserId] or 0) + 1
	_pieceCounterByUserId[player.UserId] = current
	return `piece_{player.UserId}_{current}`
end

function VehicleBlueprintService.GetActivePieceMapForPlayer(
	player: PlotService.PlayerLike
): { [string]: VehicleTypes.BlueprintPiece }
	VehicleBlueprintService.GetOrCreateBlueprint(player)
	return _piecesByIdByUserId[player.UserId] or {}
end

function VehicleBlueprintService.AddPiece(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	pieceId: string,
	itemId: string,
	localCFrame: CFrame,
	config: { [string]: any }?,
	newConnections: { VehicleTypes.BlueprintConnection },
	inventoryInstanceId: string?
): (VehicleTypes.BlueprintPiece, number)
	if not _initialized then
		VehicleBlueprintService.Init()
	end

	local templateModel = getTemplateModelForItem(itemId)

	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local pieceMap = _piecesByIdByUserId[player.UserId]
	if pieceMap[pieceId] then
		error(`[VehicleBlueprintService] Duplicate PieceInstanceId '{pieceId}' for user {player.UserId}`)
	end

	local clonedConfig = BlueprintSerializer.DeepCloneTable(config)
	local cleanInvId: string? = if type(inventoryInstanceId) == "string" and #inventoryInstanceId > 0
		then inventoryInstanceId
		else nil

	local itemDef = ItemRegistry.TryGet(itemId)
	if itemDef and itemDef.Category == "Engines" then
		local stats = EngineInventoryService.ResolvePieceEffectiveStats(player.UserId, {
			ItemId = itemId,
			InventoryInstanceId = cleanInvId,
			Config = clonedConfig,
		})
		local authEngCfg = EngineInventoryService.BuildAuthoritativeEngineConfig(
			stats,
			if clonedConfig then clonedConfig.Engine else nil
		)
		local cfgTable: { [string]: any } = if type(clonedConfig) == "table" then clonedConfig else {}
		cfgTable.Engine = BlueprintSerializer.DeepCloneTable(authEngCfg)
		clonedConfig = cfgTable
		EngineInventoryService.BindUnitToPiece(player, bp.BlueprintId, pieceId, cleanInvId)
	elseif itemDef and itemDef.Category == "Boosters" then
		local stats = BoosterInventoryService.ResolvePieceEffectiveStats(player.UserId, {
			ItemId = itemId,
			InventoryInstanceId = cleanInvId,
			Config = clonedConfig,
		})
		local authBstCfg = BoosterInventoryService.BuildAuthoritativeBoosterConfig(
			stats,
			if clonedConfig then clonedConfig.Booster else nil
		)
		local cfgTable: { [string]: any } = if type(clonedConfig) == "table" then clonedConfig else {}
		cfgTable.Booster = BlueprintSerializer.DeepCloneTable(authBstCfg)
		clonedConfig = cfgTable
		BoosterInventoryService.BindUnitToPiece(player, bp.BlueprintId, pieceId, cleanInvId)
	end

	local newPiece: VehicleTypes.BlueprintPiece = {
		InstanceId = pieceId,
		ItemId = itemId,
		LocalCFrame = localCFrame,
		InventoryInstanceId = cleanInvId,
		Config = clonedConfig,
	}

	table.insert(bp.Pieces, newPiece)
	pieceMap[pieceId] = newPiece

	local seenEdges: { [string]: boolean } = {}
	for _, existingConn in ipairs(bp.Connections) do
		local a, b = existingConn.FromPieceId, existingConn.ToPieceId
		local key = if a < b then `{a}|{b}` else `{b}|{a}`
		seenEdges[key] = true
	end
	for _, conn in ipairs(newConnections) do
		local toId = conn.ToPieceId
		if pieceId ~= toId and pieceMap[toId] then
			local key = if pieceId < toId then `{pieceId}|{toId}` else `{toId}|{pieceId}`
			if not seenEdges[key] then
				seenEdges[key] = true
				table.insert(bp.Connections, {
					FromPieceId = pieceId,
					FromAttachment = conn.FromAttachment,
					ToPieceId = toId,
					ToAttachment = conn.ToAttachment,
				})
			end
		end
	end
	bp.Revision += 1
	bp.UpdatedAt = os.time()
	recomputeVehicleOrigin(bp)
	_dirtyByUserId[player.UserId] = true

	local visualState = ensureEditableVisualState(player.UserId, plot, bp.BlueprintId)
	local visualClone = templateModel:Clone()
	configureStaticEditablePiece(visualClone, newPiece, player.UserId)

	local liftOffset = getLiftOffsetForUser(player.UserId)
	local effectiveZoneCF = VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(plot.Zones.BuildZone.CFrame, liftOffset)
	local worldCFrame = effectiveZoneCF:ToWorldSpace(localCFrame)
	visualClone:PivotTo(worldCFrame)
	visualClone.Parent = visualState.RootModel
	visualState.PiecesById[pieceId] = visualClone
	visualState.RootModel:SetAttribute("BlueprintId", bp.BlueprintId)
	visualState.RootModel:SetAttribute("Revision", bp.Revision)
	syncLiftAttributesOnRoot(visualState.RootModel, liftOffset, effectiveZoneCF)
	if visualState.RootModel:GetAttribute("IsEditableHidden") == nil then
		visualState.RootModel:SetAttribute("IsEditableHidden", false)
		visualState.RootModel:SetAttribute("EditableVisibilityState", "Visible")
	end

	local clonedPiece = BlueprintSerializer.ClonePiece(newPiece)
	emitChanged(player, plot, "PieceAdded", bp, clonedPiece)
	return clonedPiece, bp.Revision
end

function VehicleBlueprintService.RemovePiece(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	pieceInstanceId: string
): (boolean, number)
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local pieceMap = _piecesByIdByUserId[player.UserId]
	if not pieceMap or not pieceMap[pieceInstanceId] then
		return false, bp.Revision
	end

	local foundIdx: number? = nil
	for idx, p in ipairs(bp.Pieces) do
		if p.InstanceId == pieceInstanceId then
			foundIdx = idx
			break
		end
	end

	if not foundIdx then
		return false, bp.Revision
	end

	local removedPiece = bp.Pieces[foundIdx]
	if removedPiece and removedPiece.InventoryInstanceId then
		EngineInventoryService.UnbindUnitFromPiece(pieceInstanceId, removedPiece.InventoryInstanceId)
		BoosterInventoryService.UnbindUnitFromPiece(pieceInstanceId, removedPiece.InventoryInstanceId)
	end

	table.remove(bp.Pieces, foundIdx)
	pieceMap[pieceInstanceId] = nil

	local keptConnections: { VehicleTypes.BlueprintConnection } = table.create(#bp.Connections)
	for _, conn in ipairs(bp.Connections) do
		if conn.FromPieceId ~= pieceInstanceId and conn.ToPieceId ~= pieceInstanceId then
			table.insert(keptConnections, conn)
		end
	end
	bp.Connections = keptConnections
	bp.Revision += 1
	bp.UpdatedAt = os.time()
	recomputeVehicleOrigin(bp)
	_dirtyByUserId[player.UserId] = true

	local visualState = _visualsByUserId[player.UserId]
	if visualState then
		local pieceModel = visualState.PiecesById[pieceInstanceId]
		if pieceModel then
			pieceModel:Destroy()
			visualState.PiecesById[pieceInstanceId] = nil
		end
		if visualState.RootModel.Parent then
			visualState.RootModel:SetAttribute("Revision", bp.Revision)
		end
	end

	emitChanged(player, plot, "PieceRemoved", bp, pieceInstanceId)
	return true, bp.Revision
end

function VehicleBlueprintService.GetPieceSnapshot(
	player: PlotService.PlayerLike,
	pieceInstanceId: string
): VehicleTypes.BlueprintPiece?
	local map = _piecesByIdByUserId[player.UserId]
	local piece = if map then map[pieceInstanceId] else nil
	if not piece then
		return nil
	end
	return BlueprintSerializer.ClonePiece(piece)
end

function VehicleBlueprintService.UpdatePieceTransform(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	pieceInstanceId: string,
	newLocalCFrame: CFrame,
	updatedPieceConnections: { VehicleTypes.BlueprintConnection }
): (VehicleTypes.BlueprintPiece?, number)
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local pieceMap = _piecesByIdByUserId[player.UserId]
	local targetPiece = if pieceMap then pieceMap[pieceInstanceId] else nil
	if not targetPiece then
		return nil, bp.Revision
	end

	targetPiece.LocalCFrame = newLocalCFrame

	local nextConnections: { VehicleTypes.BlueprintConnection } = table.create(#bp.Connections + #updatedPieceConnections)
	local seenEdges: { [string]: boolean } = {}
	for _, conn in ipairs(bp.Connections) do
		if
			conn.FromPieceId ~= pieceInstanceId
			and conn.ToPieceId ~= pieceInstanceId
			and conn.FromPieceId ~= conn.ToPieceId
			and pieceMap[conn.FromPieceId]
			and pieceMap[conn.ToPieceId]
		then
			local key = if conn.FromPieceId < conn.ToPieceId
				then `{conn.FromPieceId}|{conn.ToPieceId}`
				else `{conn.ToPieceId}|{conn.FromPieceId}`
			if not seenEdges[key] then
				seenEdges[key] = true
				table.insert(nextConnections, conn)
			end
		end
	end
	for _, conn in ipairs(updatedPieceConnections) do
		if conn.FromPieceId ~= conn.ToPieceId and pieceMap[conn.FromPieceId] and pieceMap[conn.ToPieceId] then
			local key = if conn.FromPieceId < conn.ToPieceId
				then `{conn.FromPieceId}|{conn.ToPieceId}`
				else `{conn.ToPieceId}|{conn.FromPieceId}`
			if not seenEdges[key] then
				seenEdges[key] = true
				table.insert(nextConnections, {
					FromPieceId = conn.FromPieceId,
					FromAttachment = conn.FromAttachment,
					ToPieceId = conn.ToPieceId,
					ToAttachment = conn.ToAttachment,
				})
			end
		end
	end
	bp.Connections = nextConnections
	bp.Revision += 1
	bp.UpdatedAt = os.time()
	recomputeVehicleOrigin(bp)
	_dirtyByUserId[player.UserId] = true

	local visualState = _visualsByUserId[player.UserId]
	if visualState then
		local liftOffset = getLiftOffsetForUser(player.UserId)
		local effectiveZoneCF = VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(plot.Zones.BuildZone.CFrame, liftOffset)
		local pieceModel = visualState.PiecesById[pieceInstanceId]
		if pieceModel then
			local worldCFrame = effectiveZoneCF:ToWorldSpace(newLocalCFrame)
			pieceModel:PivotTo(worldCFrame)
		end
		if visualState.RootModel.Parent then
			visualState.RootModel:SetAttribute("Revision", bp.Revision)
			syncLiftAttributesOnRoot(visualState.RootModel, liftOffset, effectiveZoneCF)
		end
	end

	local clonedPiece = BlueprintSerializer.ClonePiece(targetPiece)
	emitChanged(player, plot, "PieceTransformed", bp, clonedPiece)
	return clonedPiece, bp.Revision
end

function VehicleBlueprintService.UpdatePieceConfig(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	pieceInstanceId: string,
	newConfig: { [string]: any }?,
	resetToAuto: boolean?,
	newInventoryInstanceId: string?
): (VehicleTypes.BlueprintPiece?, number)
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local pieceMap = _piecesByIdByUserId[player.UserId]
	local targetPiece = if pieceMap then pieceMap[pieceInstanceId] else nil
	if not targetPiece then
		return nil, bp.Revision
	end

	local nextConfig: { [string]: any }? = if resetToAuto == true
		then nil
		else BlueprintSerializer.DeepCloneTable(newConfig)
	if nextConfig ~= nil and next(nextConfig) == nil then
		nextConfig = nil
	end

	local itemDef = ItemRegistry.TryGet(targetPiece.ItemId)
	if itemDef and itemDef.Category == "Engines" then
		if resetToAuto == true then
			if targetPiece.InventoryInstanceId then
				EngineInventoryService.UnbindUnitFromPiece(pieceInstanceId, targetPiece.InventoryInstanceId)
			end
			targetPiece.InventoryInstanceId = nil
		elseif newInventoryInstanceId ~= nil then
			if targetPiece.InventoryInstanceId and targetPiece.InventoryInstanceId ~= newInventoryInstanceId then
				EngineInventoryService.UnbindUnitFromPiece(pieceInstanceId, targetPiece.InventoryInstanceId)
			end
			if #newInventoryInstanceId > 0 then
				targetPiece.InventoryInstanceId = newInventoryInstanceId
				EngineInventoryService.BindUnitToPiece(player, bp.BlueprintId, pieceInstanceId, newInventoryInstanceId)
			else
				targetPiece.InventoryInstanceId = nil
			end
		end

		local prevEngCfg = if type(targetPiece.Config) == "table" and type(targetPiece.Config.Engine) == "table"
			then targetPiece.Config.Engine
			else nil
		local incomingEngCfg = if type(nextConfig) == "table" and type(nextConfig.Engine) == "table"
			then nextConfig.Engine
			else nil

		local mergedEngInput: { [string]: any } = {}
		if resetToAuto ~= true and prevEngCfg then
			for k, v in pairs(prevEngCfg) do
				mergedEngInput[k] = v
			end
		end
		if incomingEngCfg then
			for k, v in pairs(incomingEngCfg) do
				mergedEngInput[k] = v
			end
		end

		local stats = EngineInventoryService.ResolvePieceEffectiveStats(player.UserId, {
			ItemId = targetPiece.ItemId,
			InventoryInstanceId = targetPiece.InventoryInstanceId,
			Config = { Engine = mergedEngInput },
		})
		local authEngCfg = EngineInventoryService.BuildAuthoritativeEngineConfig(stats, mergedEngInput)
		local nextCfgTable: { [string]: any } = if type(nextConfig) == "table" then nextConfig else {}
		nextCfgTable.Engine = BlueprintSerializer.DeepCloneTable(authEngCfg)
		nextConfig = nextCfgTable
	elseif itemDef and itemDef.Category == "Boosters" then
		if resetToAuto == true then
			if targetPiece.InventoryInstanceId then
				BoosterInventoryService.UnbindUnitFromPiece(pieceInstanceId, targetPiece.InventoryInstanceId)
			end
			targetPiece.InventoryInstanceId = nil
		elseif newInventoryInstanceId ~= nil then
			if targetPiece.InventoryInstanceId and targetPiece.InventoryInstanceId ~= newInventoryInstanceId then
				BoosterInventoryService.UnbindUnitFromPiece(pieceInstanceId, targetPiece.InventoryInstanceId)
			end
			if #newInventoryInstanceId > 0 then
				targetPiece.InventoryInstanceId = newInventoryInstanceId
				BoosterInventoryService.BindUnitToPiece(player, bp.BlueprintId, pieceInstanceId, newInventoryInstanceId)
			else
				targetPiece.InventoryInstanceId = nil
			end
		end

		local prevBstCfg = if type(targetPiece.Config) == "table" and type(targetPiece.Config.Booster) == "table"
			then targetPiece.Config.Booster
			else nil
		local incomingBstCfg = if type(nextConfig) == "table" and type(nextConfig.Booster) == "table"
			then nextConfig.Booster
			else nil

		local mergedBstInput: { [string]: any } = {}
		if resetToAuto ~= true and prevBstCfg then
			for k, v in pairs(prevBstCfg) do
				mergedBstInput[k] = v
			end
		end
		if incomingBstCfg then
			for k, v in pairs(incomingBstCfg) do
				mergedBstInput[k] = v
			end
		end

		local stats = BoosterInventoryService.ResolvePieceEffectiveStats(player.UserId, {
			ItemId = targetPiece.ItemId,
			InventoryInstanceId = targetPiece.InventoryInstanceId,
			Config = { Booster = mergedBstInput },
		})
		local authBstCfg = BoosterInventoryService.BuildAuthoritativeBoosterConfig(stats, mergedBstInput)
		local nextCfgTable: { [string]: any } = if type(nextConfig) == "table" then nextConfig else {}
		nextCfgTable.Booster = BlueprintSerializer.DeepCloneTable(authBstCfg)
		nextConfig = nextCfgTable
	end

	targetPiece.Config = nextConfig
	bp.Revision += 1
	bp.UpdatedAt = os.time()
	_dirtyByUserId[player.UserId] = true

	local hasManualWheelCfg = type(nextConfig) == "table"
		and type(nextConfig.Wheel) == "table"
		and next(nextConfig.Wheel) ~= nil

	local visualState = _visualsByUserId[player.UserId]
	if visualState then
		local pieceModel = visualState.PiecesById[pieceInstanceId]
		if pieceModel then
			pieceModel:SetAttribute("HasManualWheelConfig", hasManualWheelCfg)
			if itemDef and itemDef.Category == "Engines" then
				local stats = EngineInventoryService.ResolvePieceEffectiveStats(player.UserId, targetPiece)
				pieceModel:SetAttribute("InventoryInstanceId", targetPiece.InventoryInstanceId or "")
				pieceModel:SetAttribute("EngineFamilyId", stats.EngineFamilyId)
				pieceModel:SetAttribute("EngineSizeId", stats.EngineSizeId)
				pieceModel:SetAttribute("EngineVariantId", stats.VariantId)
				pieceModel:SetAttribute("EngineRarityId", stats.RarityId)
				pieceModel:SetAttribute("EnginePeakTorque", stats.PeakTorque)
				pieceModel:SetAttribute("EnginePowerRating", stats.PowerRating)
				pieceModel:SetAttribute("EngineSpeedRegular", stats.SpeedRegular)
				pieceModel:SetAttribute("EngineWeight", stats.Weight)
				pieceModel:SetAttribute("EngineFullLabel", stats.FullLabel)
				pieceModel:SetAttribute("EngineBalanceStatus", stats.BalanceStatus)
			elseif itemDef and itemDef.Category == "Boosters" then
				local stats = BoosterInventoryService.ResolvePieceEffectiveStats(player.UserId, targetPiece)
				pieceModel:SetAttribute("InventoryInstanceId", targetPiece.InventoryInstanceId or "")
				pieceModel:SetAttribute("BoosterFamilyId", stats.BoosterFamilyId)
				pieceModel:SetAttribute("BoosterSizeId", stats.BoosterSizeId)
				pieceModel:SetAttribute("BoosterVariantId", stats.VariantId)
				pieceModel:SetAttribute("BoosterRarityId", stats.RarityId)
				pieceModel:SetAttribute("BoosterThrust", stats.Thrust)
				pieceModel:SetAttribute("BoosterSpeedBoostMultiplier", stats.SpeedBoostMultiplier)
				pieceModel:SetAttribute("BoosterConsumption", stats.BoostConsumption)
				pieceModel:SetAttribute("BoosterIntegratedFuel", stats.IntegratedFuel)
				pieceModel:SetAttribute("BoosterWeight", stats.Weight)
				pieceModel:SetAttribute("BoosterFullLabel", stats.FullLabel)
				pieceModel:SetAttribute("BoosterBalanceStatus", stats.BalanceStatus)
			end
		end
		if visualState.RootModel.Parent then
			visualState.RootModel:SetAttribute("Revision", bp.Revision)
		end
	end

	local clonedPiece = BlueprintSerializer.ClonePiece(targetPiece)
	emitChanged(player, plot, "PieceConfigUpdated", bp, clonedPiece)
	return clonedPiece, bp.Revision
end

function VehicleBlueprintService._SetTextFilterForTests(fn: ((string, number) -> string)?)
	_customTextFilterForTests = fn
end

function VehicleBlueprintService.ClearWorkshop(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	expectedRevision: number?,
	expectedEpoch: number?
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	local active = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId

	if _slotOpLockByUserId[userId] then
		return false, nil, BuildProtocol.ErrorCodes.OperationInProgress, "Operación anterior en curso"
	end
	if expectedRevision ~= nil and active.Revision ~= expectedRevision then
		return false, nil, BuildProtocol.ErrorCodes.StaleBlueprintRevision, "El taller cambió en el servidor; sincronizá antes de limpiar"
	end
	if expectedEpoch ~= nil and (_workshopEpochByUserId[userId] or 0) ~= expectedEpoch then
		return false, nil, BuildProtocol.ErrorCodes.StaleBlueprintRevision, "La sesión del taller cambió; recargá el estado"
	end

	_slotOpLockByUserId[userId] = true
	unbindWorkshopInventoryUnits(active)

	local freshId = allocateNextBlueprintId(userId)
	local emptyDraft = makeEmptyBlueprint(userId, freshId, makeFallbackName(1))
	_blueprintsByUserId[userId] = emptyDraft
	_piecesByIdByUserId[userId] = {}
	_dirtyByUserId[userId] = false
	_workshopEpochByUserId[userId] = (_workshopEpochByUserId[userId] or 0) + 1
	setLiftOffsetForUser(userId, GameConfig.Stand.DefaultHeightOffset, GameConfig.Stand.DefaultLateralOffset)
	ConnectionService.ClearPlayer(userId)

	if plot then
		rebuildEditableVehicleModel(userId, plot, emptyDraft)
		VehicleBlueprintService.SetEditableVehicleVisible(player, VehicleBlueprintService.IsEditableVehicleVisible(player), "WorkshopCleared")
	end

	-- Sincronizar borrador vacío con persistencia de forma segura si ya había datos guardados (no falla la limpieza si es offline/vacío)
	if not _persistenceLoadFailedByUserId[userId] then
		pcall(function()
			if _loadedPersistenceByUserId[userId] then
				local nextStorageRev = (_storageRevisionByUserId[userId] or 0) + 1
				local rec = buildPlayerStorageRecord(userId)
				rec.StorageRevision = nextStorageRev
				local okS = BlueprintPersistenceService.SavePlayerStorage(userId, rec)
				if okS then
					_storageRevisionByUserId[userId] = nextStorageRev
				end
			end
		end)
	end

	_slotOpLockByUserId[userId] = nil
	emitChanged(player, plot, "WorkshopCleared", emptyDraft, nil)
	return true, BlueprintSerializer.CloneBlueprint(emptyDraft), nil, nil
end

function VehicleBlueprintService.SaveBlueprintSlot(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	slotIndex: number,
	rawName: string?,
	expectedRevision: number?
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	if not BlueprintSerializer.IsValidSlotIndex(slotIndex) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "Slot inválido (debe ser 1, 2 o 3)"
	end
	local active = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	if _slotOpLockByUserId[userId] then
		return false, nil, BuildProtocol.ErrorCodes.OperationInProgress, "Operación anterior en curso"
	end

	if #active.Pieces == 0 then
		return false, nil, BuildProtocol.ErrorCodes.EmptyWorkshopDraft, "El taller está vacío; construí al menos una pieza antes de guardar"
	end
	if expectedRevision ~= nil and active.Revision ~= expectedRevision then
		return false, nil, BuildProtocol.ErrorCodes.StaleBlueprintRevision, "El taller cambió; reintentá el guardado"
	end

	local slotKey = BlueprintSerializer.SlotKey(slotIndex)
	if _savedSlotsByUserId[userId][slotKey] ~= nil then
		return false, nil, BuildProtocol.ErrorCodes.SlotOccupied, `El Slot {slotIndex} ya está ocupado; usá Sobrescribir con doble confirmación`
	end

	local valid, errCode, errMsg = validateBlueprintIntegrityForLoad(active, plot)
	if not valid then
		return false, nil, errCode, errMsg
	end

	local chosenName: string
	if rawName ~= nil then
		local okN, filtered, nErr = filterAndValidateName(userId, rawName)
		if not okN or not filtered then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, nErr or "Nombre inválido"
		end
		chosenName = filtered
	else
		local fallbackBase = if type(active.Name) == "string" and #trimString(active.Name) > 0
			and active.Name ~= makeFallbackName(1)
			then active.Name
			else `{GameConfig.Blueprints.DefaultNamePrefix} {slotIndex}`
		local okF, filteredFallback = filterAndValidateName(userId, fallbackBase)
		chosenName = if okF and filteredFallback then filteredFallback else `{GameConfig.Blueprints.DefaultNamePrefix} {slotIndex}`
	end

	_slotOpLockByUserId[userId] = true
	recomputeVehicleOrigin(active)
	ConnectionService.ReconcileBlueprintConnections(active)
	local now = os.time()

	local slotBpId = allocateNextBlueprintId(userId)
	local savedCopy = BlueprintSerializer.CloneBlueprint(active)
	savedCopy.BlueprintId = slotBpId
	savedCopy.Name = chosenName
	savedCopy.CreatedAt = now
	savedCopy.UpdatedAt = now
	savedCopy.Revision = math.max(1, active.Revision)
	savedCopy.Presentation = {
		HeightOffset = GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = GameConfig.Stand.DefaultLateralOffset,
	}
	local slotMeta: VehicleTypes.BlueprintMetadata = savedCopy.Metadata or {}
	slotMeta.SourceSlotIndex = slotIndex
	slotMeta.SavedBlueprintId = slotBpId
	slotMeta.SavedRevision = savedCopy.Revision
	savedCopy.Metadata = slotMeta

	local prevName = active.Name
	local prevUpdatedAt = active.UpdatedAt
	local prevMeta = if active.Metadata then BlueprintSerializer.DeepCloneTable(active.Metadata :: any) else nil
	local prevDirty = _dirtyByUserId[userId]

	active.Name = chosenName
	active.UpdatedAt = now
	local activeMeta: VehicleTypes.BlueprintMetadata = active.Metadata or {}
	activeMeta.SourceSlotIndex = slotIndex
	activeMeta.SavedBlueprintId = slotBpId
	activeMeta.SavedRevision = savedCopy.Revision
	active.Metadata = activeMeta
	_savedSlotsByUserId[userId][slotKey] = savedCopy
	_dirtyByUserId[userId] = false

	local okPersist, pCode, pMsg = persistUserStorage(userId)
	if not okPersist then
		_savedSlotsByUserId[userId][slotKey] = nil
		active.Name = prevName
		active.UpdatedAt = prevUpdatedAt
		active.Metadata = prevMeta :: VehicleTypes.BlueprintMetadata?
		_dirtyByUserId[userId] = prevDirty
		_slotOpLockByUserId[userId] = nil
		return false, nil, pCode or BuildProtocol.ErrorCodes.PersistenceFailed, pMsg or "Fallo de persistencia al guardar slot"
	end

	ConnectionService.RebuildPlayerCache(userId, active)
	local visual = _visualsByUserId[userId]
	if visual and visual.RootModel.Parent then
		visual.RootModel:SetAttribute("BlueprintId", active.BlueprintId)
		visual.RootModel:SetAttribute("Revision", active.Revision)
	end

	_slotOpLockByUserId[userId] = nil
	emitChanged(player, plot, "SlotSaved", active, { SlotIndex = slotIndex, SlotBlueprintId = slotBpId })

	local snapshot = BlueprintSerializer.CloneBlueprint(active)
	snapshot.Presentation = getLiftOffsetForUser(userId)
	return true, snapshot, nil, nil
end

function VehicleBlueprintService.OverwriteBlueprintSlot(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	slotIndex: number,
	rawName: string?,
	confirmationStep: number,
	expectedSlotRevision: number?,
	expectedWorkshopRevision: number?
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	if not BlueprintSerializer.IsValidSlotIndex(slotIndex) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "Slot inválido (debe ser 1, 2 o 3)"
	end
	if confirmationStep ~= 2 then
		return false, nil, BuildProtocol.ErrorCodes.ConfirmationRequired, "Se requiere doble confirmación para sobrescribir"
	end

	local active = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	if _slotOpLockByUserId[userId] then
		return false, nil, BuildProtocol.ErrorCodes.OperationInProgress, "Operación anterior en curso"
	end
	if #active.Pieces == 0 then
		return false, nil, BuildProtocol.ErrorCodes.EmptyWorkshopDraft, "No podés sobrescribir con el taller vacío; usá Eliminar para vaciar la tarjeta"
	end
	if expectedWorkshopRevision ~= nil and active.Revision ~= expectedWorkshopRevision then
		return false, nil, BuildProtocol.ErrorCodes.StaleBlueprintRevision, "El taller cambió; reintentá sobrescribir"
	end

	local slotKey = BlueprintSerializer.SlotKey(slotIndex)
	local existingSlot = _savedSlotsByUserId[userId][slotKey]
	if not existingSlot then
		return false, nil, BuildProtocol.ErrorCodes.SlotEmpty, `El Slot {slotIndex} está vacío; usá Guardar`
	end
	if expectedSlotRevision ~= nil and existingSlot.Revision ~= expectedSlotRevision then
		return false, nil, BuildProtocol.ErrorCodes.StaleBlueprintRevision, "El slot fue modificado por otra operación"
	end

	local valid, errCode, errMsg = validateBlueprintIntegrityForLoad(active, plot)
	if not valid then
		return false, nil, errCode, errMsg
	end

	local targetName = existingSlot.Name
	if rawName ~= nil then
		local okN, filtered, nErr = filterAndValidateName(userId, rawName)
		if not okN or not filtered then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, nErr or "Nombre inválido"
		end
		targetName = filtered
	end

	_slotOpLockByUserId[userId] = true
	recomputeVehicleOrigin(active)
	ConnectionService.ReconcileBlueprintConnections(active)
	local now = os.time()

	local oldSlotClone = BlueprintSerializer.CloneBlueprint(existingSlot)
	local prevActiveName = active.Name
	local prevActiveUpdatedAt = active.UpdatedAt
	local prevActiveMeta = if active.Metadata then BlueprintSerializer.DeepCloneTable(active.Metadata :: any) else nil
	local prevDirty = _dirtyByUserId[userId]

	local newSlotCopy = BlueprintSerializer.CloneBlueprint(active)
	newSlotCopy.BlueprintId = existingSlot.BlueprintId
	newSlotCopy.Name = targetName
	newSlotCopy.CreatedAt = existingSlot.CreatedAt or now
	newSlotCopy.UpdatedAt = now
	newSlotCopy.Revision = math.max((existingSlot.Revision or 0) + 1, active.Revision)
	newSlotCopy.Presentation = {
		HeightOffset = GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = GameConfig.Stand.DefaultLateralOffset,
	}
	local slotMeta: VehicleTypes.BlueprintMetadata = newSlotCopy.Metadata or {}
	slotMeta.SourceSlotIndex = slotIndex
	slotMeta.SavedBlueprintId = existingSlot.BlueprintId
	slotMeta.SavedRevision = newSlotCopy.Revision
	newSlotCopy.Metadata = slotMeta

	active.Name = targetName
	active.UpdatedAt = now
	local activeMeta: VehicleTypes.BlueprintMetadata = active.Metadata or {}
	activeMeta.SourceSlotIndex = slotIndex
	activeMeta.SavedBlueprintId = existingSlot.BlueprintId
	activeMeta.SavedRevision = newSlotCopy.Revision
	active.Metadata = activeMeta

	_savedSlotsByUserId[userId][slotKey] = newSlotCopy
	_dirtyByUserId[userId] = false

	local okPersist, pCode, pMsg = persistUserStorage(userId)
	if not okPersist then
		_savedSlotsByUserId[userId][slotKey] = oldSlotClone
		active.Name = prevActiveName
		active.UpdatedAt = prevActiveUpdatedAt
		active.Metadata = prevActiveMeta :: VehicleTypes.BlueprintMetadata?
		_dirtyByUserId[userId] = prevDirty
		_slotOpLockByUserId[userId] = nil
		return false, nil, pCode or BuildProtocol.ErrorCodes.PersistenceFailed, pMsg or "Fallo de persistencia al sobrescribir slot"
	end

	ConnectionService.RebuildPlayerCache(userId, active)
	_slotOpLockByUserId[userId] = nil
	emitChanged(player, plot, "SlotOverwritten", active, { SlotIndex = slotIndex, SlotBlueprintId = newSlotCopy.BlueprintId })

	local snapshot = BlueprintSerializer.CloneBlueprint(active)
	snapshot.Presentation = getLiftOffsetForUser(userId)
	return true, snapshot, nil, nil
end

function VehicleBlueprintService.LoadBlueprintSlot(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	slotIndex: number,
	confirmDiscardUnsaved: boolean?
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	if not BlueprintSerializer.IsValidSlotIndex(slotIndex) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "Slot inválido (debe ser 1, 2 o 3)"
	end
	local currentActive = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	if _slotOpLockByUserId[userId] then
		return false, nil, BuildProtocol.ErrorCodes.OperationInProgress, "Operación anterior en curso"
	end

	local slotKey = BlueprintSerializer.SlotKey(slotIndex)
	local saved = _savedSlotsByUserId[userId] and _savedSlotsByUserId[userId][slotKey]
	if not saved or saved.OwnerUserId ~= userId then
		return false, nil, BuildProtocol.ErrorCodes.SlotEmpty, `El Slot {slotIndex} está vacío`
	end

	if confirmDiscardUnsaved == false and #currentActive.Pieces > 0 then
		local loadedIdx = VehicleBlueprintService.GetLoadedSlotIndex(player)
		if _dirtyByUserId[userId] == true or loadedIdx ~= slotIndex then
			return false,
				nil,
				BuildProtocol.ErrorCodes.UnsavedWorkshopConfirmationRequired,
				"Tenés cambios o un vehículo en el taller; confirmá antes de reemplazarlo"
		end
	end

	local candidate = BlueprintSerializer.CloneBlueprint(saved)
	local valid, errCode, errMsg, initialLift = validateBlueprintIntegrityForLoad(candidate, plot)
	if not valid then
		return false, nil, errCode, errMsg
	end

	_slotOpLockByUserId[userId] = true
	unbindWorkshopInventoryUnits(currentActive)

	local appliedLift = initialLift or {
		HeightOffset = GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = GameConfig.Stand.DefaultLateralOffset,
	}
	setLiftOffsetForUser(userId, appliedLift.HeightOffset, appliedLift.LateralOffset)
	candidate.Presentation = {
		HeightOffset = appliedLift.HeightOffset,
		LateralOffset = appliedLift.LateralOffset,
	}
	local candMeta: VehicleTypes.BlueprintMetadata = candidate.Metadata or {}
	candMeta.SourceSlotIndex = slotIndex
	candMeta.SavedBlueprintId = saved.BlueprintId
	candMeta.SavedRevision = saved.Revision
	candidate.Metadata = candMeta

	recomputeVehicleOrigin(candidate)
	ConnectionService.ReconcileBlueprintConnections(candidate)
	_blueprintsByUserId[userId] = candidate
	rebuildPieceMapForActive(userId, candidate)
	bindWorkshopInventoryUnits(player, candidate)
	_dirtyByUserId[userId] = false
	_workshopEpochByUserId[userId] = (_workshopEpochByUserId[userId] or 0) + 1

	ConnectionService.RebuildPlayerCache(userId, candidate)
	rebuildEditableVehicleModel(userId, plot, candidate)
	VehicleBlueprintService.SetEditableVehicleVisible(player, VehicleBlueprintService.IsEditableVehicleVisible(player), "BlueprintLoaded")

	_slotOpLockByUserId[userId] = nil
	emitChanged(player, plot, "BlueprintLoaded", candidate, { SlotIndex = slotIndex })
	return true, BlueprintSerializer.CloneBlueprint(candidate), nil, nil
end

function VehicleBlueprintService.RenameBlueprintSlot(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	slotIndex: number,
	rawNewName: string
): (boolean, VehicleTypes.BlueprintSlotSummary?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	if not BlueprintSerializer.IsValidSlotIndex(slotIndex) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "Slot inválido (debe ser 1, 2 o 3)"
	end
	local active = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	if _slotOpLockByUserId[userId] then
		return false, nil, BuildProtocol.ErrorCodes.OperationInProgress, "Operación anterior en curso"
	end

	local slotKey = BlueprintSerializer.SlotKey(slotIndex)
	local saved = _savedSlotsByUserId[userId][slotKey]
	if not saved or saved.OwnerUserId ~= userId then
		return false, nil, BuildProtocol.ErrorCodes.SlotEmpty, `El Slot {slotIndex} está vacío`
	end

	local okName, filtered, nameErr = filterAndValidateName(userId, rawNewName)
	if not okName or not filtered then
		return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, nameErr or "Nombre de blueprint inválido"
	end

	_slotOpLockByUserId[userId] = true
	local prevSavedName = saved.Name
	local prevSavedUpdatedAt = saved.UpdatedAt
	local prevActiveName = active.Name
	local prevActiveUpdatedAt = active.UpdatedAt
	local now = os.time()

	saved.Name = filtered
	saved.UpdatedAt = now
	local isLoaded = VehicleBlueprintService.GetLoadedSlotIndex(player) == slotIndex
	if isLoaded then
		active.Name = filtered
		active.UpdatedAt = now
	end

	local okPersist, pCode, pMsg = persistUserStorage(userId)
	if not okPersist then
		saved.Name = prevSavedName
		saved.UpdatedAt = prevSavedUpdatedAt
		active.Name = prevActiveName
		active.UpdatedAt = prevActiveUpdatedAt
		_slotOpLockByUserId[userId] = nil
		return false, nil, pCode or BuildProtocol.ErrorCodes.PersistenceFailed, pMsg or "Fallo de persistencia al renombrar"
	end

	_slotOpLockByUserId[userId] = nil
	emitChanged(player, plot, "SlotRenamed", active, { SlotIndex = slotIndex, Name = filtered })

	return true, {
		SlotIndex = slotIndex,
		State = "Saved",
		IsOccupied = true,
		BlueprintId = saved.BlueprintId,
		Name = saved.Name,
		PieceCount = #saved.Pieces,
		Revision = saved.Revision,
		CreatedAt = saved.CreatedAt,
		UpdatedAt = saved.UpdatedAt,
		IsLoadedInWorkshop = isLoaded,
		HasUnsavedChanges = if isLoaded then (_dirtyByUserId[userId] == true) else false,
	}, nil, nil
end

function VehicleBlueprintService.DeleteBlueprintSlot(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	slotIndex: number,
	confirmationName: string?
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	if not BlueprintSerializer.IsValidSlotIndex(slotIndex) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "Slot inválido (debe ser 1, 2 o 3)"
	end
	local active = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	if _slotOpLockByUserId[userId] then
		return false, nil, BuildProtocol.ErrorCodes.OperationInProgress, "Operación anterior en curso"
	end

	local slotKey = BlueprintSerializer.SlotKey(slotIndex)
	local saved = _savedSlotsByUserId[userId][slotKey]
	if not saved or saved.OwnerUserId ~= userId then
		return false, nil, BuildProtocol.ErrorCodes.SlotEmpty, `El Slot {slotIndex} ya está vacío`
	end

	if confirmationName ~= nil and trimString(confirmationName) ~= saved.Name then
		return false, nil, BuildProtocol.ErrorCodes.ConfirmationRequired, "Confirmación de eliminación no coincide con el nombre del vehículo"
	end

	_slotOpLockByUserId[userId] = true
	local backupSlot = saved
	local prevMeta = if active.Metadata then BlueprintSerializer.DeepCloneTable(active.Metadata :: any) else nil
	local prevDirty = _dirtyByUserId[userId]

	_savedSlotsByUserId[userId][slotKey] = nil
	if active.Metadata and active.Metadata.SourceSlotIndex == slotIndex then
		active.Metadata.SourceSlotIndex = nil
		active.Metadata.SavedBlueprintId = nil
		active.Metadata.SavedRevision = nil
		if #active.Pieces > 0 then
			_dirtyByUserId[userId] = true
		end
	end

	local okPersist, pCode, pMsg = persistUserStorage(userId)
	if not okPersist then
		_savedSlotsByUserId[userId][slotKey] = backupSlot
		active.Metadata = prevMeta :: VehicleTypes.BlueprintMetadata?
		_dirtyByUserId[userId] = prevDirty
		_slotOpLockByUserId[userId] = nil
		return false, nil, pCode or BuildProtocol.ErrorCodes.PersistenceFailed, pMsg or "Fallo de persistencia al eliminar slot"
	end

	_slotOpLockByUserId[userId] = nil
	-- Eliminar un slot NUNCA modifica las piezas, conexiones ni EditableVehicle del borrador activo.
	emitChanged(player, plot, "SlotDeleted", active, { SlotIndex = slotIndex, DeletedName = backupSlot.Name })
	local snapshot = BlueprintSerializer.CloneBlueprint(active)
	snapshot.Presentation = getLiftOffsetForUser(userId)
	return true, snapshot, nil, nil
end

function VehicleBlueprintService.UnlinkInventoryFromBlueprints(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	targetItemId: string?,
	targetUnitId: string?,
	targetSlotIndices: { number }?,
	confirmed: boolean?
)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	local userId = player.UserId
	ensureUserLibraryStructures(userId)
	if not _loadedPersistenceByUserId[userId] then
		local okLoad, loadErrCode, loadErrMsg = ensureUserLoadedFromPersistence(userId)
		if not okLoad then
			return {
				Success = false,
				ErrorCode = loadErrCode or BuildProtocol.ErrorCodes.PersistenceFailed,
				ErrorMessage = loadErrMsg or "Error leyendo blueprints persistidos",
			}
		end
	end

	local cleanUnitId: string? = if type(targetUnitId) == "string" and #targetUnitId > 0 then targetUnitId else nil
	local cleanItemId: string? = if type(targetItemId) == "string" and #targetItemId > 0 then targetItemId else nil
	if not cleanUnitId and not cleanItemId then
		return {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.InvalidPayload,
			ErrorMessage = "Debes especificar ItemId o ItemInstanceId para desvincular.",
		}
	end

	local function matchesTarget(piece: VehicleTypes.BlueprintPiece): boolean
		if cleanUnitId then
			return piece.InventoryInstanceId == cleanUnitId and (cleanItemId == nil or piece.ItemId == cleanItemId)
		end
		return piece.ItemId == cleanItemId
	end

	local scopedAll = targetSlotIndices == nil or #targetSlotIndices == 0
	local slotAllowed: { [number]: boolean } = {}
	if scopedAll then
		for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
			slotAllowed[slotIndex] = true
		end
	else
		for _, sIdx in ipairs(targetSlotIndices :: { number }) do
			if BlueprintSerializer.IsValidSlotIndex(sIdx) then
				slotAllowed[sIdx] = true
			end
		end
	end

	local affectedSlotIndices: { number } = {}
	local totalMatches = 0
	local slots = _savedSlotsByUserId[userId]
	for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
		if slotAllowed[slotIndex] then
			local slotBp = slots[BlueprintSerializer.SlotKey(slotIndex)]
			if slotBp then
				local slotMatchCount = 0
				for _, piece in ipairs(slotBp.Pieces) do
					if matchesTarget(piece) then
						slotMatchCount += 1
					end
				end
				if slotMatchCount > 0 then
					table.insert(affectedSlotIndices, slotIndex)
					totalMatches += slotMatchCount
				end
			end
		end
	end

	local active = _blueprintsByUserId[userId]
	local workshopMatchCount = 0
	if scopedAll and active then
		for _, piece in ipairs(active.Pieces) do
			if matchesTarget(piece) then
				workshopMatchCount += 1
			end
		end
	end
	local affectedWorkshop = workshopMatchCount > 0
	totalMatches += workshopMatchCount

	local preview = {
		TargetItemId = cleanItemId,
		TargetUnitId = cleanUnitId,
		AffectedSlotIndices = affectedSlotIndices,
		AffectedWorkshop = affectedWorkshop,
		AffectedPieceCount = totalMatches,
	}

	if totalMatches == 0 then
		return {
			Success = true,
			WorkshopChanged = false,
			ModifiedSlotIndices = {},
			RemovedPieceCount = 0,
			UnlinkPreview = preview,
			ActiveBlueprint = VehicleBlueprintService.GetBlueprintSnapshot(player),
		}
	end

	if confirmed ~= true then
		return {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.ConfirmationRequired,
			ErrorMessage = "Confirma la desvinculación para retirar únicamente esas piezas de los diseños afectados.",
			ConfirmationRequired = true,
			UnlinkPreview = preview,
		}
	end

	if affectedWorkshop and InventoryService.IsVehicleInActiveRuntime(userId) then
		return {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.InvalidPlayerState,
			ErrorMessage = "Regresa tu vehículo al taller antes de desvincular piezas que está usando.",
			UnlinkPreview = preview,
		}
	end

	if _slotOpLockByUserId[userId] then
		return {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.OperationInProgress,
			ErrorMessage = "Operación anterior en curso.",
			UnlinkPreview = preview,
		}
	end
	_slotOpLockByUserId[userId] = true

	local backupSlots: { [string]: VehicleTypes.VehicleBlueprint } = {}
	local backupActive = if affectedWorkshop and active then BlueprintSerializer.CloneBlueprint(active) else nil
	local backupPiecesMap = if affectedWorkshop then _piecesByIdByUserId[userId] else nil
	local backupDirty = _dirtyByUserId[userId]

	for _, slotIndex in ipairs(affectedSlotIndices) do
		local key = BlueprintSerializer.SlotKey(slotIndex)
		local slotBp = slots[key]
		if slotBp then
			backupSlots[key] = BlueprintSerializer.CloneBlueprint(slotBp)
			local keptPieces: { VehicleTypes.BlueprintPiece } = {}
			for _, piece in ipairs(slotBp.Pieces) do
				if not matchesTarget(piece) then
					table.insert(keptPieces, piece)
				end
			end
			slotBp.Pieces = keptPieces
			ConnectionService.ReconcileBlueprintConnections(slotBp)
			recomputeVehicleOrigin(slotBp)
			slotBp.Revision += 1
			slotBp.UpdatedAt = os.time()
			if slotBp.Metadata then
				slotBp.Metadata.SavedRevision = slotBp.Revision
			end
		end
	end

	local removedWorkshopPieces: { VehicleTypes.BlueprintPiece } = {}
	if affectedWorkshop and active then
		local keptActive: { VehicleTypes.BlueprintPiece } = {}
		for _, piece in ipairs(active.Pieces) do
			if matchesTarget(piece) then
				table.insert(removedWorkshopPieces, piece)
			else
				table.insert(keptActive, piece)
			end
		end
		active.Pieces = keptActive
		ConnectionService.ReconcileBlueprintConnections(active)
		recomputeVehicleOrigin(active)
		active.Revision += 1
		active.UpdatedAt = os.time()
		rebuildPieceMapForActive(userId, active)
		ConnectionService.RebuildPlayerCache(userId, active)
		_dirtyByUserId[userId] = (#active.Pieces > 0)
	end

	local okPersist, pCode, pMsg = persistUserStorage(userId)
	if not okPersist then
		for key, oldSlot in pairs(backupSlots) do
			slots[key] = oldSlot
		end
		if backupActive then
			_blueprintsByUserId[userId] = backupActive
			_piecesByIdByUserId[userId] = backupPiecesMap or {}
			_dirtyByUserId[userId] = backupDirty
			ConnectionService.RebuildPlayerCache(userId, backupActive)
		end
		_slotOpLockByUserId[userId] = nil
		return {
			Success = false,
			ErrorCode = pCode or BuildProtocol.ErrorCodes.PersistenceFailed,
			ErrorMessage = pMsg or "Fallo de persistencia al desvincular inventario de blueprints.",
			UnlinkPreview = preview,
		}
	end

	_slotOpLockByUserId[userId] = nil

	for _, removedPiece in ipairs(removedWorkshopPieces) do
		if removedPiece.InventoryInstanceId then
			EngineInventoryService.UnbindUnitFromPiece(removedPiece.InstanceId, removedPiece.InventoryInstanceId)
			BoosterInventoryService.UnbindUnitFromPiece(removedPiece.InstanceId, removedPiece.InventoryInstanceId)
		end
	end

	if affectedWorkshop and active then
		_workshopEpochByUserId[userId] = (_workshopEpochByUserId[userId] or 0) + 1
		if plot then
			rebuildEditableVehicleModel(userId, plot, active)
			VehicleBlueprintService.SetEditableVehicleVisible(player, VehicleBlueprintService.IsEditableVehicleVisible(player), "InventoryUnlinked")
		end
	end

	emitChanged(player, plot, "InventoryUnlinked", _blueprintsByUserId[userId], {
		AffectedSlotIndices = affectedSlotIndices,
		AffectedWorkshop = affectedWorkshop,
		RemovedPieceCount = totalMatches,
	})

	return {
		Success = true,
		WorkshopChanged = affectedWorkshop,
		ModifiedSlotIndices = affectedSlotIndices,
		RemovedPieceCount = totalMatches,
		UnlinkPreview = preview,
		ActiveBlueprint = VehicleBlueprintService.GetBlueprintSnapshot(player),
	}
end

function VehicleBlueprintService.RecoverLegacyBlueprint(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	originalBlueprintId: string,
	targetSlotIndex: number,
	confirmationStep: number?
): (boolean, VehicleTypes.BlueprintSlotSummary?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	if not BlueprintSerializer.IsValidSlotIndex(targetSlotIndex) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "Slot destino inválido (1-3)"
	end
	VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	if _slotOpLockByUserId[userId] then
		return false, nil, BuildProtocol.ErrorCodes.OperationInProgress, "Operación anterior en curso"
	end

	local overflow = _legacyOverflowByUserId[userId] or {}
	local targetEntry: VehicleTypes.LegacyOverflowEntry? = nil
	for _, entry in ipairs(overflow) do
		if entry.OriginalBlueprintId == originalBlueprintId then
			targetEntry = entry
			break
		end
	end
	if not targetEntry then
		return false, nil, BuildProtocol.ErrorCodes.LegacyOverflowNotFound, "Diseño heredado no encontrado"
	end

	local slotKey = BlueprintSerializer.SlotKey(targetSlotIndex)
	local oldSlot = _savedSlotsByUserId[userId][slotKey]
	if oldSlot ~= nil and confirmationStep ~= 2 then
		return false, nil, BuildProtocol.ErrorCodes.ConfirmationRequired, "El slot destino está ocupado; confirmá sobrescribir"
	end

	local okDec, candidate = BlueprintSerializer.DeserializeBlueprint(targetEntry.SerializedBlueprint, userId)
	if not okDec or not candidate then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Datos de diseño heredado inválidos"
	end

	local valid, errCode, errMsg = validateBlueprintIntegrityForLoad(candidate, plot)
	if not valid then
		return false, nil, errCode, errMsg
	end

	_slotOpLockByUserId[userId] = true
	local newId = allocateNextBlueprintId(userId)
	candidate.BlueprintId = newId
	candidate.UpdatedAt = os.time()
	local candMeta: VehicleTypes.BlueprintMetadata = candidate.Metadata or {}
	candMeta.SourceBlueprintId = originalBlueprintId
	candMeta.SourceSlotIndex = targetSlotIndex
	candMeta.SavedBlueprintId = newId
	candidate.Metadata = candMeta

	local prevRecoveredTo = targetEntry.RecoveredToSlot
	targetEntry.RecoveredToSlot = targetSlotIndex
	_savedSlotsByUserId[userId][slotKey] = candidate

	local okPersist, pCode, pMsg = persistUserStorage(userId)
	if not okPersist then
		_savedSlotsByUserId[userId][slotKey] = oldSlot
		targetEntry.RecoveredToSlot = prevRecoveredTo
		_slotOpLockByUserId[userId] = nil
		return false, nil, pCode or BuildProtocol.ErrorCodes.PersistenceFailed, pMsg or "Fallo de persistencia recuperando diseño heredado"
	end

	_slotOpLockByUserId[userId] = nil
	emitChanged(player, plot, "LegacyRecovered", nil, { OriginalBlueprintId = originalBlueprintId, SlotIndex = targetSlotIndex })
	return true, {
		SlotIndex = targetSlotIndex,
		State = "Saved",
		IsOccupied = true,
		BlueprintId = candidate.BlueprintId,
		Name = candidate.Name,
		PieceCount = #candidate.Pieces,
		Revision = candidate.Revision,
		CreatedAt = candidate.CreatedAt,
		UpdatedAt = candidate.UpdatedAt,
		IsLoadedInWorkshop = false,
		HasUnsavedChanges = false,
	}, nil, nil
end

function VehicleBlueprintService.CreateBlueprint(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	rawName: string?
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	local currentActive = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId

	local chosenName: string
	if rawName ~= nil then
		local okName, trimmed = validateBlueprintName(rawName)
		if not okName or not trimmed then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre de blueprint inválido"
		end
		chosenName = trimmed
	else
		local nextNum = (_blueprintCounterByUserId[userId] or 0) + 1
		chosenName = makeFallbackName(nextNum)
	end

	unbindWorkshopInventoryUnits(currentActive)
	local newId = allocateNextBlueprintId(userId)
	local emptyBp = makeEmptyBlueprint(userId, newId, chosenName)
	_blueprintsByUserId[userId] = emptyBp
	rebuildPieceMapForActive(userId, emptyBp)
	setLiftOffsetForUser(userId, GameConfig.Stand.DefaultHeightOffset, GameConfig.Stand.DefaultLateralOffset)
	_dirtyByUserId[userId] = false
	_workshopEpochByUserId[userId] = (_workshopEpochByUserId[userId] or 0) + 1
	ConnectionService.ClearPlayer(userId)

	if plot then
		rebuildEditableVehicleModel(userId, plot, emptyBp)
		VehicleBlueprintService.SetEditableVehicleVisible(player, VehicleBlueprintService.IsEditableVehicleVisible(player), "BlueprintCreated")
	end

	emitChanged(player, plot, "BlueprintCreated", emptyBp, nil)
	return true, BlueprintSerializer.CloneBlueprint(emptyBp), nil, nil
end

function VehicleBlueprintService.SaveBlueprint(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	rawName: string?,
	saveAsNew: boolean?
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	local active = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId

	if rawName ~= nil then
		local okName, trimmed = filterAndValidateName(userId, rawName)
		if not okName or not trimmed then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre de blueprint inválido"
		end
		active.Name = trimmed
	end

	local valid, errCode, errMsg = validateBlueprintIntegrityForLoad(active, plot)
	if not valid then
		return false, nil, errCode, errMsg
	end

	recomputeVehicleOrigin(active)
	ConnectionService.ReconcileBlueprintConnections(active)
	local now = os.time()
	active.UpdatedAt = now

	local targetSlotIdx: number? = nil
	if saveAsNew == true then
		targetSlotIdx = getFirstEmptySlotIndex(userId)
		if not targetSlotIdx then
			return false,
				nil,
				BuildProtocol.ErrorCodes.MaxBlueprintsReached,
				`Alcanzaste el límite de {GameConfig.Blueprints.MaxSlots} slots guardados`
		end
		local newId = allocateNextBlueprintId(userId)
		active.BlueprintId = newId
		active.CreatedAt = now
		active.Revision += 1
	else
		local linkedIdx: number? = if active.Metadata and type(active.Metadata.SourceSlotIndex) == "number"
			then active.Metadata.SourceSlotIndex
			else nil
		if linkedIdx and _savedSlotsByUserId[userId][BlueprintSerializer.SlotKey(linkedIdx)] then
			targetSlotIdx = linkedIdx
		else
			local byIdIdx = findSlotByBlueprintId(userId, active.BlueprintId)
			if byIdIdx then
				targetSlotIdx = byIdIdx
			else
				targetSlotIdx = getFirstEmptySlotIndex(userId)
			end
		end
		if not targetSlotIdx then
			return false, nil, BuildProtocol.ErrorCodes.MaxBlueprintsReached, "Límite de slots guardados alcanzado"
		end
	end

	local slotKey = BlueprintSerializer.SlotKey(targetSlotIdx :: number)
	local oldSlotBackup = _savedSlotsByUserId[userId][slotKey]
	local prevMeta = if active.Metadata then BlueprintSerializer.DeepCloneTable(active.Metadata :: any) else nil
	local prevDirty = _dirtyByUserId[userId]

	local savedCopy = BlueprintSerializer.CloneBlueprint(active)
	savedCopy.Presentation = {
		HeightOffset = GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = GameConfig.Stand.DefaultLateralOffset,
	}
	local savedMeta: VehicleTypes.BlueprintMetadata = savedCopy.Metadata or {}
	savedMeta.SourceSlotIndex = targetSlotIdx
	savedMeta.SavedBlueprintId = savedCopy.BlueprintId
	savedCopy.Metadata = savedMeta
	local activeMeta: VehicleTypes.BlueprintMetadata = active.Metadata or {}
	activeMeta.SourceSlotIndex = targetSlotIdx
	activeMeta.SavedBlueprintId = savedCopy.BlueprintId
	active.Metadata = activeMeta

	_savedSlotsByUserId[userId][slotKey] = savedCopy
	_dirtyByUserId[userId] = false

	local okPersist, pCode, pMsg = persistUserStorage(userId)
	if not okPersist then
		_savedSlotsByUserId[userId][slotKey] = oldSlotBackup
		active.Metadata = prevMeta :: VehicleTypes.BlueprintMetadata?
		_dirtyByUserId[userId] = prevDirty
		return false, nil, pCode or BuildProtocol.ErrorCodes.PersistenceFailed, pMsg or "Fallo de persistencia"
	end

	ConnectionService.RebuildPlayerCache(userId, active)

	local visual = _visualsByUserId[userId]
	if visual and visual.RootModel.Parent then
		visual.RootModel:SetAttribute("BlueprintId", active.BlueprintId)
		visual.RootModel:SetAttribute("Revision", active.Revision)
	end

	emitChanged(player, plot, "BlueprintSaved", active, nil)
	local activeSnapshot = BlueprintSerializer.CloneBlueprint(active)
	activeSnapshot.Presentation = getLiftOffsetForUser(userId)
	return true, activeSnapshot, nil, nil
end

function VehicleBlueprintService.LoadBlueprint(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	blueprintId: string
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	VehicleBlueprintService.GetOrCreateBlueprint(player)
	local slotIndex = findSlotByBlueprintId(player.UserId, blueprintId)
	if not slotIndex then
		return false, nil, BuildProtocol.ErrorCodes.BlueprintNotFound, "Blueprint no encontrado o sin permisos"
	end
	return VehicleBlueprintService.LoadBlueprintSlot(player, plot, slotIndex, true)
end

function VehicleBlueprintService.SetActiveBlueprint(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	blueprintId: string
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	return VehicleBlueprintService.LoadBlueprint(player, plot, blueprintId)
end

function VehicleBlueprintService.DuplicateBlueprint(
	player: PlotService.PlayerLike,
	sourceBlueprintId: string,
	rawNewName: string?
): (boolean, VehicleTypes.BlueprintSummary?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId

	local _, source = findSlotByBlueprintId(userId, sourceBlueprintId)
	if not source or source.OwnerUserId ~= userId then
		return false, nil, BuildProtocol.ErrorCodes.BlueprintNotFound, "Blueprint origen no encontrado"
	end

	local emptySlot = getFirstEmptySlotIndex(userId)
	if not emptySlot then
		return false,
			nil,
			BuildProtocol.ErrorCodes.MaxBlueprintsReached,
			`Alcanzaste el límite de {GameConfig.Blueprints.MaxSlots} slots guardados`
	end

	local chosenName: string
	if rawNewName ~= nil then
		local okName, trimmed = filterAndValidateName(userId, rawNewName)
		if not okName or not trimmed then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre inválido para duplicado"
		end
		chosenName = trimmed
	else
		local suffix = GameConfig.Blueprints.DuplicateSuffix
		local maxBase = math.max(1, GameConfig.Blueprints.MaxNameLength - #suffix)
		chosenName = string.sub(source.Name, 1, maxBase) .. suffix
	end

	local newId = allocateNextBlueprintId(userId)
	local copy = BlueprintSerializer.CloneBlueprint(source, userId)
	local now = os.time()
	copy.BlueprintId = newId
	copy.Name = chosenName
	copy.CreatedAt = now
	copy.UpdatedAt = now
	local copyMeta: VehicleTypes.BlueprintMetadata = copy.Metadata or {}
	copyMeta.SourceBlueprintId = sourceBlueprintId
	copyMeta.SourceSlotIndex = emptySlot
	copyMeta.SavedBlueprintId = newId
	copy.Metadata = copyMeta

	-- Regla anti-duplicación de unidades individuales (Fase 3.3 / 4.2.1):
	for _, dupPiece in ipairs(copy.Pieces) do
		if dupPiece.InventoryInstanceId ~= nil then
			dupPiece.InventoryInstanceId = nil
			local itemDef = ItemRegistry.TryGet(dupPiece.ItemId)
			if itemDef and itemDef.Category == "Engines" then
				local prevEng = if type(dupPiece.Config) == "table" and type(dupPiece.Config.Engine) == "table"
					then dupPiece.Config.Engine
					else nil
				local baseStats = EngineInventoryService.ResolvePieceEffectiveStats(userId, {
					ItemId = dupPiece.ItemId,
					InventoryInstanceId = nil,
					Config = nil,
				})
				local authCfg = EngineInventoryService.BuildAuthoritativeEngineConfig(baseStats, prevEng)
				local dupCfg: { [string]: any } = if type(dupPiece.Config) == "table" then dupPiece.Config else {}
				dupCfg.Engine = BlueprintSerializer.DeepCloneTable(authCfg)
				dupPiece.Config = dupCfg
			elseif itemDef and itemDef.Category == "Boosters" then
				local prevBst = if type(dupPiece.Config) == "table" and type(dupPiece.Config.Booster) == "table"
					then dupPiece.Config.Booster
					else nil
				local baseStats = BoosterInventoryService.ResolvePieceEffectiveStats(userId, {
					ItemId = dupPiece.ItemId,
					InventoryInstanceId = nil,
					Config = nil,
				})
				local authCfg = BoosterInventoryService.BuildAuthoritativeBoosterConfig(baseStats, prevBst)
				local dupCfg: { [string]: any } = if type(dupPiece.Config) == "table" then dupPiece.Config else {}
				dupCfg.Booster = BlueprintSerializer.DeepCloneTable(authCfg)
				dupPiece.Config = dupCfg
			end
		end
	end

	ConnectionService.ReconcileBlueprintConnections(copy)
	local slotKey = BlueprintSerializer.SlotKey(emptySlot)
	_savedSlotsByUserId[userId][slotKey] = copy
	local okPersist, pCode, pMsg = persistUserStorage(userId)
	if not okPersist then
		_savedSlotsByUserId[userId][slotKey] = nil
		return false, nil, pCode or BuildProtocol.ErrorCodes.PersistenceFailed, pMsg or "Fallo de persistencia al duplicar"
	end

	return true, toSummary(copy, false, false), nil, nil
end

function VehicleBlueprintService.RenameBlueprint(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	blueprintId: string,
	rawNewName: string
): (boolean, VehicleTypes.BlueprintSummary?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	local active = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	local slotIndex, saved = findSlotByBlueprintId(userId, blueprintId)
	if slotIndex and saved then
		local okR, _, errCode, errMsg = VehicleBlueprintService.RenameBlueprintSlot(player, plot, slotIndex, rawNewName)
		if not okR then
			return false, nil, errCode, errMsg
		end

		local isLoaded = VehicleBlueprintService.GetLoadedSlotIndex(player) == slotIndex
		local updatedSlot = _savedSlotsByUserId[userId][BlueprintSerializer.SlotKey(slotIndex)] :: VehicleTypes.VehicleBlueprint
		return true, toSummary(if isLoaded then active else updatedSlot, isLoaded, _dirtyByUserId[userId] == true), nil, nil
	elseif active.BlueprintId == blueprintId then
		local okName, filtered, nameErr = filterAndValidateName(userId, rawNewName)
		if not okName or not filtered then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, nameErr or "Nombre de blueprint inválido"
		end
		active.Name = filtered
		active.UpdatedAt = os.time()
		emitChanged(player, plot, "BlueprintRenamed", active, { BlueprintId = active.BlueprintId, Name = filtered })
		return true, toSummary(active, VehicleBlueprintService.GetLoadedSlotIndex(player) ~= nil, _dirtyByUserId[userId] == true), nil, nil
	end

	return false, nil, BuildProtocol.ErrorCodes.BlueprintNotFound, "Blueprint no encontrado"
end

function VehicleBlueprintService.DeleteBlueprint(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	blueprintId: string
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	VehicleBlueprintService.GetOrCreateBlueprint(player)
	local slotIndex = findSlotByBlueprintId(player.UserId, blueprintId)
	if not slotIndex then
		return false, nil, BuildProtocol.ErrorCodes.BlueprintNotFound, "Blueprint no encontrado"
	end
	return VehicleBlueprintService.DeleteBlueprintSlot(player, plot, slotIndex, nil)
end

function VehicleBlueprintService.SetStandOffset(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	heightOffset: number,
	lateralOffset: number
): (boolean, VehicleTypes.StandPresentationConfig?, number, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local eps = GameConfig.Stand.Epsilon

	if
		type(heightOffset) ~= "number"
		or heightOffset ~= heightOffset
		or heightOffset == math.huge
		or heightOffset == -math.huge
		or type(lateralOffset) ~= "number"
		or lateralOffset ~= lateralOffset
		or lateralOffset == math.huge
		or lateralOffset == -math.huge
	then
		return false, nil, bp.Revision, BuildProtocol.ErrorCodes.InvalidPayload, "Valores de offset inválidos"
	end

	local resolvedPlot = plot or PlotService.GetPlotForPlayer(player)
	local liftBounds = VehicleBlueprintService.ComputeLiftBoundsForPlayer(player, resolvedPlot)
	local inRange = VehicleCoordinateMath.IsLiftOffsetWithinBounds(heightOffset, lateralOffset, liftBounds, eps)
	if not inRange then
		return false,
			nil,
			bp.Revision,
			BuildProtocol.ErrorCodes.StandOffsetOutOfRange,
			string.format(
				"Offsets fuera de rango dinámico (Altura %.2f..%.2f, Lateral %.2f..%.2f)",
				liftBounds.MinHeightOffset,
				liftBounds.MaxHeightOffset,
				liftBounds.MinLateralOffset,
				liftBounds.MaxLateralOffset
			)
	end

	local clampedH = math.clamp(heightOffset, liftBounds.MinHeightOffset, liftBounds.MaxHeightOffset)
	local clampedL = math.clamp(lateralOffset, liftBounds.MinLateralOffset, liftBounds.MaxLateralOffset)
	clampedH = math.round(clampedH * 1000) / 1000
	clampedL = math.round(clampedL * 1000) / 1000

	local applied = setLiftOffsetForUser(player.UserId, clampedH, clampedL)
	bp.Presentation = {
		HeightOffset = applied.HeightOffset,
		LateralOffset = applied.LateralOffset,
	}
	bp.Revision += 1
	bp.UpdatedAt = os.time()

	applyEditableVehicleLiftTransform(player.UserId, resolvedPlot, bp, applied)

	emitChanged(player, resolvedPlot, "PresentationChanged", bp, {
		HeightOffset = applied.HeightOffset,
		LateralOffset = applied.LateralOffset,
	})
	return true, {
		HeightOffset = applied.HeightOffset,
		LateralOffset = applied.LateralOffset,
	}, bp.Revision, nil, nil
end

function VehicleBlueprintService.ResetStandOffset(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?
): (boolean, VehicleTypes.StandPresentationConfig?, number, string?, string?)
	local resolvedPlot = plot or PlotService.GetPlotForPlayer(player)
	local liftBounds = VehicleBlueprintService.ComputeLiftBoundsForPlayer(player, resolvedPlot)
	return VehicleBlueprintService.SetStandOffset(
		player,
		resolvedPlot,
		liftBounds.DefaultRestHeightOffset,
		liftBounds.DefaultRestLateralOffset
	)
end

--[=[
	Selecciona explícitamente cuál componente conexa (`GroupId`) debe considerarse el ensamblaje primario
	para LaunchPreparation cuando existen múltiples ensamblajes o múltiples DriverSeats desconectados.
]=]
function VehicleBlueprintService.SetPrimaryAssemblyGroup(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	groupId: string
): (boolean, VehicleTypes.AssemblyAnalysis?, number, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId
	local analysis = ConnectionService.AnalyzeBlueprintAssemblies(bp)

	local foundGroup = false
	for _, group in ipairs(analysis.Groups) do
		if group.GroupId == groupId then
			foundGroup = true
			break
		end
	end
	if not foundGroup then
		return false, analysis, bp.Revision, BuildProtocol.ErrorCodes.PrimaryAssemblyNotFound, `No existe ensamblaje con GroupId '{groupId}'`
	end

	local bpMeta: VehicleTypes.BlueprintMetadata = bp.Metadata or {}
	bpMeta.PrimaryAssemblyGroupId = groupId
	bp.Metadata = bpMeta
	bp.Revision += 1
	bp.UpdatedAt = os.time()
	_dirtyByUserId[userId] = true

	local resolvedPlot = plot or PlotService.GetPlotForPlayer(player)
	local updatedAnalysis = ConnectionService.AnalyzeBlueprintAssemblies(bp)
	emitChanged(player, resolvedPlot, "AssemblySelectionChanged", bp, updatedAnalysis)
	return true, updatedAnalysis, bp.Revision, nil, nil
end

function VehicleBlueprintService.ImportSerializedBlueprint(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	rawSerialized: any
): (boolean, VehicleTypes.VehicleBlueprint?, string?, string?)
	if not _initialized then
		VehicleBlueprintService.Init()
	end
	VehicleBlueprintService.GetOrCreateBlueprint(player)
	local userId = player.UserId

	local okDeser, parsedBp, deserErr = BlueprintSerializer.DeserializeBlueprint(rawSerialized, userId)
	if not okDeser or not parsedBp then
		local errCode = if type(deserErr) == "string" and string.find(deserErr, "MaxPiecesPerVehicle", 1, true)
			then BuildProtocol.ErrorCodes.MaxPiecesReached
			else BuildProtocol.ErrorCodes.InvalidPayload
		return false, nil, errCode, deserErr or "Blueprint serializado inválido"
	end

	local valid, errCode, errMsg, initialLift = validateBlueprintIntegrityForLoad(parsedBp, plot)
	if not valid then
		return false, nil, errCode, errMsg
	end

	local existingSlotIdx = findSlotByBlueprintId(userId, parsedBp.BlueprintId)
	local targetSlotIdx = existingSlotIdx or getFirstEmptySlotIndex(userId)
	if not targetSlotIdx then
		return false, nil, BuildProtocol.ErrorCodes.MaxBlueprintsReached, "Límite de slots guardados alcanzado"
	end

	local currentActive = _blueprintsByUserId[userId]
	unbindWorkshopInventoryUnits(currentActive)

	local appliedLift = initialLift or {
		HeightOffset = GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = GameConfig.Stand.DefaultLateralOffset,
	}
	setLiftOffsetForUser(userId, appliedLift.HeightOffset, appliedLift.LateralOffset)
	parsedBp.Presentation = {
		HeightOffset = appliedLift.HeightOffset,
		LateralOffset = appliedLift.LateralOffset,
	}
	local parsedMeta: VehicleTypes.BlueprintMetadata = parsedBp.Metadata or {}
	parsedMeta.SourceSlotIndex = targetSlotIdx
	parsedMeta.SavedBlueprintId = parsedBp.BlueprintId
	parsedBp.Metadata = parsedMeta

	recomputeVehicleOrigin(parsedBp)
	ConnectionService.ReconcileBlueprintConnections(parsedBp)

	local savedCopy = BlueprintSerializer.CloneBlueprint(parsedBp)
	savedCopy.Presentation = {
		HeightOffset = GameConfig.Stand.DefaultHeightOffset,
		LateralOffset = GameConfig.Stand.DefaultLateralOffset,
	}
	_savedSlotsByUserId[userId][BlueprintSerializer.SlotKey(targetSlotIdx)] = savedCopy
	_blueprintsByUserId[userId] = parsedBp
	rebuildPieceMapForActive(userId, parsedBp)
	bindWorkshopInventoryUnits(player, parsedBp)
	_dirtyByUserId[userId] = false
	_workshopEpochByUserId[userId] = (_workshopEpochByUserId[userId] or 0) + 1
	ConnectionService.RebuildPlayerCache(userId, parsedBp)
	if plot then
		rebuildEditableVehicleModel(userId, plot, parsedBp)
		VehicleBlueprintService.SetEditableVehicleVisible(player, VehicleBlueprintService.IsEditableVehicleVisible(player), "BlueprintImported")
	end
	emitChanged(player, plot, "BlueprintLoaded", parsedBp, nil)
	return true, BlueprintSerializer.CloneBlueprint(parsedBp), nil, nil
end

type SavedDescendantVisibility =
	{
		Instance: Instance,
		Kind: "BasePart",
		Transparency: number,
		CastShadow: boolean,
		CanCollide: boolean,
		CanQuery: boolean,
		CanTouch: boolean,
		SeatDisabled: boolean?,
	}
	| {
		Instance: Instance,
		Kind: "DecalTexture",
		Transparency: number,
	}
	| {
		Instance: Instance,
		Kind: "EnabledProp",
		Enabled: boolean,
	}
	| {
		Instance: Instance,
		Kind: "VisibleProp",
		Visible: boolean,
	}
	| {
		Instance: Instance,
		Kind: "ClickDetector",
		MaxActivationDistance: number,
	}

type HiddenEditableSnapshot = {
	RootModel: Model,
	Reason: string?,
	Records: { SavedDescendantVisibility },
	Seen: { [Instance]: boolean },
}

local _hiddenEditableByUserId: { [number]: HiddenEditableSnapshot } = {}
local _desiredHiddenByUserId: { [number]: { Hidden: boolean, Reason: string? } } = {}

local function resolveVisibilityUserId(playerOrUserId: PlotService.PlayerLike | number): number
	return if type(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
end

local function resolveEditableRootModel(userId: number): Model?
	local visualState = _visualsByUserId[userId]
	if visualState and visualState.RootModel and visualState.RootModel.Parent then
		return visualState.RootModel
	end
	local plot = PlotService.GetPlotByPlayer({ UserId = userId, Name = "" } :: PlotService.PlayerLike)
	if plot and plot.DynamicContainer then
		local existing = plot.DynamicContainer:FindFirstChild(GameConfig.Building.EditableVehicleName)
		if existing and existing:IsA("Model") then
			return existing
		end
	end
	return nil
end

local function captureDescendantVisibility(inst: Instance): SavedDescendantVisibility?
	if inst:IsA("BasePart") then
		local seatDisabled: boolean? = nil
		if inst:IsA("Seat") or inst:IsA("VehicleSeat") then
			seatDisabled = inst.Disabled
		end
		return {
			Instance = inst,
			Kind = "BasePart",
			Transparency = inst.Transparency,
			CastShadow = inst.CastShadow,
			CanCollide = inst.CanCollide,
			CanQuery = inst.CanQuery,
			CanTouch = inst.CanTouch,
			SeatDisabled = seatDisabled,
		}
	elseif inst:IsA("Decal") or inst:IsA("Texture") then
		return {
			Instance = inst,
			Kind = "DecalTexture",
			Transparency = inst.Transparency,
		}
	elseif inst:IsA("SelectionBox") or inst:IsA("SelectionSphere") then
		return {
			Instance = inst,
			Kind = "VisibleProp",
			Visible = inst.Visible,
		}
	elseif
		inst:IsA("ParticleEmitter")
		or inst:IsA("Beam")
		or inst:IsA("Trail")
		or inst:IsA("Highlight")
		or inst:IsA("Light")
		or inst:IsA("BillboardGui")
		or inst:IsA("SurfaceGui")
		or inst:IsA("ProximityPrompt")
		or inst:IsA("Fire")
		or inst:IsA("Smoke")
		or inst:IsA("Sparkles")
	then
		return {
			Instance = inst,
			Kind = "EnabledProp",
			Enabled = (inst :: any).Enabled == true,
		}
	elseif inst:IsA("ClickDetector") then
		return {
			Instance = inst,
			Kind = "ClickDetector",
			MaxActivationDistance = inst.MaxActivationDistance,
		}
	end
	return nil
end

local function applyHiddenToDescendantRecord(record: SavedDescendantVisibility)
	local inst = record.Instance
	if not inst or inst.Parent == nil then
		return
	end
	if record.Kind == "BasePart" then
		local part = inst :: BasePart
		part.Transparency = 1
		part.CastShadow = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		if record.SeatDisabled ~= nil and (part:IsA("Seat") or part:IsA("VehicleSeat")) then
			part.Disabled = true
		end
	elseif record.Kind == "DecalTexture" then
		(inst :: Decal).Transparency = 1
	elseif record.Kind == "EnabledProp" then
		(inst :: any).Enabled = false
	elseif record.Kind == "VisibleProp" then
		(inst :: SelectionBox).Visible = false
	elseif record.Kind == "ClickDetector" then
		(inst :: ClickDetector).MaxActivationDistance = 0
	end
end

local function restoreFromDescendantRecord(record: SavedDescendantVisibility)
	local inst = record.Instance
	if not inst or inst.Parent == nil then
		return
	end
	if record.Kind == "BasePart" then
		local part = inst :: BasePart
		part.Transparency = record.Transparency
		part.CastShadow = record.CastShadow
		part.CanCollide = record.CanCollide
		part.CanQuery = record.CanQuery
		part.CanTouch = record.CanTouch
		if record.SeatDisabled ~= nil and (part:IsA("Seat") or part:IsA("VehicleSeat")) then
			part.Disabled = record.SeatDisabled
		end
	elseif record.Kind == "DecalTexture" then
		(inst :: Decal).Transparency = record.Transparency
	elseif record.Kind == "EnabledProp" then
		(inst :: any).Enabled = record.Enabled
	elseif record.Kind == "VisibleProp" then
		(inst :: SelectionBox).Visible = record.Visible
	elseif record.Kind == "ClickDetector" then
		(inst :: ClickDetector).MaxActivationDistance = record.MaxActivationDistance
	end
end

local function syncEditableVisibilityAttributes(rootModel: Model?, isVisible: boolean, reason: string?)
	if not rootModel or rootModel.Parent == nil then
		return
	end
	rootModel:SetAttribute("IsEditableHidden", not isVisible)
	rootModel:SetAttribute("EditableVisibilityState", if isVisible then "Visible" else "Hidden")
	rootModel:SetAttribute("EditableHiddenReason", if isVisible then nil else (reason or "RuntimeActive"))
end

local function hideEditableRootWithSnapshot(userId: number, rootModel: Model, reason: string?)
	local existing = _hiddenEditableByUserId[userId]
	local snap: HiddenEditableSnapshot
	if existing and existing.RootModel == rootModel then
		snap = existing
		if reason ~= nil then
			snap.Reason = reason
		end
	else
		snap = {
			RootModel = rootModel,
			Reason = reason,
			Records = {},
			Seen = {},
		}
		_hiddenEditableByUserId[userId] = snap
	end

	for _, desc in ipairs(rootModel:GetDescendants()) do
		if not snap.Seen[desc] then
			local rec = captureDescendantVisibility(desc)
			if rec then
				snap.Seen[desc] = true
				table.insert(snap.Records, rec)
			end
		end
	end

	for _, rec in ipairs(snap.Records) do
		applyHiddenToDescendantRecord(rec)
	end

	syncEditableVisibilityAttributes(rootModel, false, snap.Reason)
end

--[=[
	Controla de forma autoritativa y reversible la visibilidad e interactividad física
	de `EditableVehicle` durante el ciclo de vida de conducción sin mutar el Blueprint.
]=]
function VehicleBlueprintService.SetEditableVehicleVisible(
	playerOrUserId: PlotService.PlayerLike | number,
	visible: boolean,
	reason: string?
): boolean
	local userId = resolveVisibilityUserId(playerOrUserId)
	local rootModel = resolveEditableRootModel(userId)

	if visible then
		_desiredHiddenByUserId[userId] = nil
		local snap = _hiddenEditableByUserId[userId]
		_hiddenEditableByUserId[userId] = nil
		if snap then
			for _, rec in ipairs(snap.Records) do
				restoreFromDescendantRecord(rec)
			end
			if snap.RootModel and snap.RootModel.Parent then
				syncEditableVisibilityAttributes(snap.RootModel, true, nil)
			end
		end
		if rootModel then
			syncEditableVisibilityAttributes(rootModel, true, nil)
		end
		return true
	end

	_desiredHiddenByUserId[userId] = {
		Hidden = true,
		Reason = reason,
	}
	if not rootModel then
		return false
	end

	hideEditableRootWithSnapshot(userId, rootModel, reason)
	return true
end

function VehicleBlueprintService.IsEditableVehicleVisible(playerOrUserId: PlotService.PlayerLike | number): boolean
	local userId = resolveVisibilityUserId(playerOrUserId)
	local desired = _desiredHiddenByUserId[userId]
	if desired and desired.Hidden then
		return false
	end

	local rootModel = resolveEditableRootModel(userId)
	local snap = _hiddenEditableByUserId[userId]
	if snap then
		if rootModel == nil or snap.RootModel ~= rootModel or snap.RootModel.Parent == nil then
			_hiddenEditableByUserId[userId] = nil
		else
			return false
		end
	end

	if rootModel and rootModel:GetAttribute("IsEditableHidden") == true then
		return false
	end
	return true
end

function VehicleBlueprintService.GetEditableVehicleVisibilityState(playerOrUserId: PlotService.PlayerLike | number): {
	IsVisible: boolean,
	IsHidden: boolean,
	Reason: string?,
	TrackedDescendantCount: number,
	RootModel: Model?,
}
	local userId = resolveVisibilityUserId(playerOrUserId)
	local rootModel = resolveEditableRootModel(userId)
	local isVisible = VehicleBlueprintService.IsEditableVehicleVisible(userId)
	local snap = _hiddenEditableByUserId[userId]
	local desired = _desiredHiddenByUserId[userId]
	local reason: string? = if snap and snap.Reason then snap.Reason elseif desired then desired.Reason else nil
	if not isVisible and reason == nil and rootModel then
		local attrReason = rootModel:GetAttribute("EditableHiddenReason")
		if type(attrReason) == "string" then
			reason = attrReason
		end
	end
	return {
		IsVisible = isVisible,
		IsHidden = not isVisible,
		Reason = reason,
		TrackedDescendantCount = if snap then #snap.Records else 0,
		RootModel = rootModel,
	}
end

function VehicleBlueprintService.GetEditableVehicleModel(player: PlotService.PlayerLike): Model?
	local visualState = _visualsByUserId[player.UserId]
	return if visualState then visualState.RootModel else nil
end

function VehicleBlueprintService.GetTrackedPlayerCount(): number
	local count = 0
	for _ in pairs(_blueprintsByUserId) do
		count += 1
	end
	return count
end

function VehicleBlueprintService.ClearPlayer(player: PlotService.PlayerLike)
	local userId = player.UserId
	local currentDraft = _blueprintsByUserId[userId]
	local hadSavedSlots = getSavedCountForUser(userId) > 0
	local hadOverflow = _legacyOverflowByUserId[userId] ~= nil and #_legacyOverflowByUserId[userId] > 0
	local hadDraftPieces = currentDraft ~= nil and #currentDraft.Pieces > 0

	if _loadedPersistenceByUserId[userId] and not _persistenceLoadFailedByUserId[userId] and (hadSavedSlots or hadOverflow or hadDraftPieces) then
		pcall(function()
			persistUserStorage(userId)
		end)
	end

	unbindWorkshopInventoryUnits(currentDraft)

	_blueprintsByUserId[userId] = nil
	_savedSlotsByUserId[userId] = nil
	_legacyOverflowByUserId[userId] = nil
	_storageRevisionByUserId[userId] = nil
	_workshopEpochByUserId[userId] = nil
	_loadedPersistenceByUserId[userId] = nil
	_persistenceLoadFailedByUserId[userId] = nil
	_slotOpLockByUserId[userId] = nil
	_dirtyByUserId[userId] = nil
	_piecesByIdByUserId[userId] = nil
	_pieceCounterByUserId[userId] = nil
	_blueprintCounterByUserId[userId] = nil
	_liftOffsetByUserId[userId] = nil
	_hiddenEditableByUserId[userId] = nil
	_desiredHiddenByUserId[userId] = nil

	local visualState = _visualsByUserId[userId]
	if visualState then
		if visualState.RootModel.Parent then
			visualState.RootModel:Destroy()
		end
		_visualsByUserId[userId] = nil
	end

	emitChanged(player, nil, "PlayerCleared", nil, nil)
end

function VehicleBlueprintService._ResetForTests(preservePersistence: boolean?)
	for _, conn in ipairs(_connections) do
		conn:Disconnect()
	end
	table.clear(_connections)

	if _unsubPlotReleased then
		_unsubPlotReleased()
		_unsubPlotReleased = nil
	end

	for _, visualState in pairs(_visualsByUserId) do
		if visualState.RootModel.Parent then
			visualState.RootModel:Destroy()
		end
	end
	table.clear(_visualsByUserId)
	table.clear(_blueprintsByUserId)
	table.clear(_savedSlotsByUserId)
	table.clear(_legacyOverflowByUserId)
	table.clear(_storageRevisionByUserId)
	table.clear(_workshopEpochByUserId)
	table.clear(_loadedPersistenceByUserId)
	table.clear(_persistenceLoadFailedByUserId)
	table.clear(_slotOpLockByUserId)
	_customTextFilterForTests = nil
	table.clear(_dirtyByUserId)
	table.clear(_piecesByIdByUserId)
	table.clear(_pieceCounterByUserId)
	table.clear(_blueprintCounterByUserId)
	table.clear(_liftOffsetByUserId)
	table.clear(_hiddenEditableByUserId)
	table.clear(_desiredHiddenByUserId)
	table.clear(_changeListeners)
	table.clear(_fallbackSizeCache)
	_itemAssetsRoot = nil
	_initialized = false
	_started = false
	BlueprintPersistenceService._ResetForTests(not preservePersistence)
	InventoryService.RegisterBlueprintUsageProvider(computeBlueprintUsageSummary)
end

return VehicleBlueprintService
