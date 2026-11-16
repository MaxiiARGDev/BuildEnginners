--!strict
--[=[
	InventoryService
	Inventario central autoritativo y persistente del jugador (Fase 5.1).

	Responsabilidades:
	- Fuente única de verdad del servidor para piezas comunes (acumulables por ItemId) y
	  unidades únicas (motores/propulsores por ItemInstanceId).
	- Otorga GameConfig.StartingInventory UNA sola vez por jugador nuevo (StarterKitGranted),
	  nunca al reconectar ni ante errores de carga de DataStore.
	- Valida disponibilidad al colocar piezas, auto-asigna unidades únicas libres cuando no se
	  especifica ItemInstanceId y valida carga completa de blueprints.
	- Calcula disponibilidad en taller y bloqueo por referencias en Workshop + Slots 1..3
	  (usando MAX entre slots guardados y nunca sumando los 3 slots).
	- Ejecuta ventas atómicas (SellValue = nil mientras precios/ratio sigan TBD) con rollback
	  completo si falla la persistencia.
]=]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local InventoryPersistenceService = require(ServerScriptService.Server.Services.InventoryPersistenceService)

export type PlayerLike = Player | {
	UserId: number,
	Name: string,
}

export type BlueprintUsageSummary = {
	WorkshopItemCounts: { [string]: number },
	WorkshopUnitIds: { [string]: boolean },
	MaxSlotItemCounts: { [string]: number },
	SlotIndicesByItemId: { [string]: { [number]: number } },
	SlotIndicesByUnitId: { [string]: { number } },
}

export type PlacementValidationResult = {
	Valid: boolean,
	ErrorCode: string?,
	ErrorMessage: string?,
	ResolvedInventoryInstanceId: string?,
	UnitRecord: any?,
}

export type SellResultPayload = {
	SoldItemId: string,
	SoldQuantity: number,
	RemovedUnitId: string?,
	SellValue: number?,
	NewBalance: number?,
	CurrencyNote: string,
}

export type SellResponse = {
	Success: boolean,
	ErrorCode: string?,
	ErrorMessage: string?,
	SellResult: SellResultPayload?,
	Snapshot: ItemTypes.PlayerInventorySnapshot?,
	BlockedInWorkshop: boolean?,
	BlockedSlotIndices: { number }?,
}

local InventoryService = {
	Name = "InventoryService",
}

local _initialized = false
local _started = false
local _autoGrantLegacyQuota = false

local _storageByUserId: { [number]: ItemTypes.PlayerInventoryStorage } = {}
local _unitRecordsById: { [string]: any } = {}
local _unitIdsByUserId: { [number]: { string } } = {}
local _blueprintUsageProvider: ((userId: number) -> BlueprintUsageSummary)? = nil
local _runtimeStateChecker: ((userId: number) -> boolean)? = nil
local _sellPayoutProvider: ((userId: number, amount: number, txId: string) -> (boolean, number?, string?, string?))? = nil

local function extractUserId(playerOrUserId: PlayerLike | number): number
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return playerOrUserId.UserId
	elseif type(playerOrUserId) == "table" and type((playerOrUserId :: any).UserId) == "number" then
		return (playerOrUserId :: any).UserId
	end
	error("[InventoryService] Jugador o UserId inválido", 3)
end

local function isPositiveInt(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value >= 1 and value % 1 == 0
end

local function generateUnitInstanceId(prefix: string): string
	return prefix .. string.lower(string.gsub(HttpService:GenerateGUID(false), "-", "")):sub(1, 16)
end

local function cloneStorage(storage: ItemTypes.PlayerInventoryStorage): ItemTypes.PlayerInventoryStorage
	local itemsCopy: { [string]: number } = {}
	for itemId, qty in pairs(storage.Items) do
		if qty > 0 then
			itemsCopy[itemId] = qty
		end
	end

	local unitsCopy: { ItemTypes.SerializedInventoryUnit } = table.create(#storage.UniqueUnits)
	for _, unit in ipairs(storage.UniqueUnits) do
		table.insert(unitsCopy, {
			ItemInstanceId = unit.ItemInstanceId,
			ItemId = unit.ItemId,
			Category = unit.Category,
			FamilyId = unit.FamilyId,
			SizeId = unit.SizeId,
			VariantId = unit.VariantId,
			RarityId = unit.RarityId,
			CreatedAt = unit.CreatedAt,
			SourceTag = unit.SourceTag,
		})
	end

	return {
		StorageSchemaVersion = storage.StorageSchemaVersion,
		OwnerUserId = storage.OwnerUserId,
		InventoryRevision = storage.InventoryRevision,
		UpdatedAt = storage.UpdatedAt,
		StarterKitGranted = storage.StarterKitGranted,
		StarterKitVersion = storage.StarterKitVersion,
		Items = itemsCopy,
		UniqueUnits = unitsCopy,
	}
end

local function materializeUnitRecord(
	ownerUserId: number,
	unit: ItemTypes.SerializedInventoryUnit
): (any?, string?)
	if unit.Category == "Engines" then
		local stats = EngineCatalog.ResolveEffectiveStats({
			ItemId = unit.ItemId,
			EngineFamilyId = unit.FamilyId :: any,
			EngineSizeId = unit.SizeId :: any,
			VariantId = unit.VariantId :: any,
			RarityId = unit.RarityId :: any,
		})
		local record: ItemTypes.EngineUnitRecord = table.freeze({
			ItemInstanceId = unit.ItemInstanceId,
			OwnerUserId = ownerUserId,
			ItemId = stats.BaseItemId,
			EngineFamilyId = stats.EngineFamilyId,
			EngineSizeId = stats.EngineSizeId,
			VariantId = stats.VariantId,
			RarityId = stats.RarityId,
			CreatedAt = unit.CreatedAt,
			SourceTag = unit.SourceTag,
			EffectiveStats = stats,
		})
		return record, "Engines"
	elseif unit.Category == "Boosters" then
		local stats = BoosterCatalog.ResolveEffectiveStats({
			ItemId = unit.ItemId,
			BoosterFamilyId = unit.FamilyId :: any,
			BoosterSizeId = unit.SizeId :: any,
			VariantId = unit.VariantId :: any,
			RarityId = unit.RarityId :: any,
		})
		local record: ItemTypes.BoosterUnitRecord = table.freeze({
			ItemInstanceId = unit.ItemInstanceId,
			OwnerUserId = ownerUserId,
			ItemId = stats.BaseItemId,
			BoosterFamilyId = stats.BoosterFamilyId,
			BoosterSizeId = stats.BoosterSizeId,
			VariantId = stats.VariantId,
			RarityId = stats.RarityId,
			CreatedAt = unit.CreatedAt,
			SourceTag = unit.SourceTag,
			EffectiveStats = stats,
		})
		return record, "Boosters"
	end
	return nil, nil
end

local function clearUnitCacheForUser(userId: number)
	local existingIds = _unitIdsByUserId[userId]
	if existingIds then
		for _, unitId in ipairs(existingIds) do
			local rec = _unitRecordsById[unitId]
			if rec and rec.OwnerUserId == userId then
				_unitRecordsById[unitId] = nil
			end
		end
		_unitIdsByUserId[userId] = nil
	end
end

local function rebuildUnitCacheForUser(userId: number, storage: ItemTypes.PlayerInventoryStorage)
	clearUnitCacheForUser(userId)
	local idList: { string } = table.create(#storage.UniqueUnits)
	for _, unit in ipairs(storage.UniqueUnits) do
		local existingGlobal = _unitRecordsById[unit.ItemInstanceId]
		if existingGlobal and existingGlobal.OwnerUserId ~= userId then
			error(`[InventoryService] Colisión de ItemInstanceId '{unit.ItemInstanceId}' entre usuarios`, 2)
		end
		local record = materializeUnitRecord(userId, unit)
		if record then
			_unitRecordsById[unit.ItemInstanceId] = record
			table.insert(idList, unit.ItemInstanceId)
		end
	end
	_unitIdsByUserId[userId] = idList
end

local function createEmptyStorage(userId: number, starterGranted: boolean): ItemTypes.PlayerInventoryStorage
	return {
		StorageSchemaVersion = GameConfig.Inventory.StorageSchemaVersion,
		OwnerUserId = userId,
		InventoryRevision = 1,
		UpdatedAt = os.time(),
		StarterKitGranted = starterGranted,
		StarterKitVersion = if starterGranted then GameConfig.Inventory.StarterKitVersion else 0,
		Items = {},
		UniqueUnits = {},
	}
end

local function applyStartingInventory(storage: ItemTypes.PlayerInventoryStorage)
	if not GameConfig.StartingInventory.Enabled then
		return
	end

	for itemId, qty in pairs(GameConfig.StartingInventory.Items) do
		local def = ItemRegistry.TryGet(itemId)
		if def and not ItemRegistry.IsUniqueInventoryItem(def) and isPositiveInt(qty) then
			storage.Items[itemId] = (storage.Items[itemId] or 0) + math.floor(qty)
		end
	end

	local now = os.time()
	for _, unitSpec in ipairs(GameConfig.StartingInventory.UniqueUnits) do
		local def = ItemRegistry.TryGet(unitSpec.ItemId)
		if def and (def.Category == "Engines" or def.Category == "Boosters") then
			local prefix = if def.Category == "Engines" then "engunit_" else "bstunit_"
			table.insert(storage.UniqueUnits, {
				ItemInstanceId = generateUnitInstanceId(prefix),
				ItemId = def.Id,
				Category = def.Category :: ("Engines" | "Boosters"),
				FamilyId = unitSpec.FamilyId,
				SizeId = unitSpec.SizeId,
				VariantId = unitSpec.VariantId,
				RarityId = unitSpec.RarityId,
				CreatedAt = now,
				SourceTag = "StarterKit",
			})
		end
	end

	storage.StarterKitGranted = true
	storage.StarterKitVersion = GameConfig.Inventory.StarterKitVersion
end

local function applyLegacyTestSuiteQuota(storage: ItemTypes.PlayerInventoryStorage)
	local now = os.time()
	for _, def in ipairs(ItemRegistry.GetAll()) do
		if not ItemRegistry.IsUniqueInventoryItem(def) then
			local current = storage.Items[def.Id] or 0
			if current < 1000 then
				storage.Items[def.Id] = 1000
			end
		end
	end

	local enginePresets: { { Id: string?, Fam: string, Size: string, Var: string, Rarity: string, Tag: string } } = {
		{ Id = `dev_{storage.OwnerUserId}_small_common_bal_1`, Fam = "StandardCombustion", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "StarterDefault" },
		{ Id = `dev_{storage.OwnerUserId}_small_common_bal_2`, Fam = "StandardCombustion", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "StarterDefault" },
		{ Id = `dev_{storage.OwnerUserId}_small_uncommon_htq`, Fam = "StandardCombustion", Size = "Small", Var = "HighTorque", Rarity = "Uncommon", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_small_rare_hrev`, Fam = "StandardCombustion", Size = "Small", Var = "HighRev", Rarity = "Rare", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_med_common_bal`, Fam = "StandardCombustion", Size = "Medium", Var = "Balanced", Rarity = "Common", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_med_epic_ovd`, Fam = "StandardCombustion", Size = "Medium", Var = "Overdrive", Rarity = "Epic", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_small_common_raw_1`, Fam = "StandardCombustion", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_small_common_raw_2`, Fam = "StandardCombustion", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_small_common_raw_3`, Fam = "StandardCombustion", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_small_common_raw_4`, Fam = "StandardCombustion", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "DevWorkshopSample" },
	}

	local existingIds: { [string]: boolean } = {}
	for _, u in ipairs(storage.UniqueUnits) do
		existingIds[u.ItemInstanceId] = true
	end

	for _, preset in ipairs(enginePresets) do
		if preset.Id and not existingIds[preset.Id] then
			existingIds[preset.Id] = true
			table.insert(storage.UniqueUnits, {
				ItemInstanceId = preset.Id,
				ItemId = "SmallEngine",
				Category = "Engines",
				FamilyId = preset.Fam,
				SizeId = preset.Size,
				VariantId = preset.Var,
				RarityId = preset.Rarity,
				CreatedAt = now,
				SourceTag = preset.Tag,
			})
		end
	end

	local boosterPresets: { { Id: string?, Fam: string, Size: string, Var: string, Rarity: string, Tag: string } } = {
		{ Id = `dev_{storage.OwnerUserId}_bst_small_common_bal_1`, Fam = "StandardRocket", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "StarterDefault" },
		{ Id = `dev_{storage.OwnerUserId}_bst_small_common_bal_2`, Fam = "StandardRocket", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "StarterDefault" },
		{ Id = `dev_{storage.OwnerUserId}_bst_small_uncommon_ht`, Fam = "HighImpulse", Size = "Small", Var = "HighThrust", Rarity = "Uncommon", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_bst_small_rare_eco`, Fam = "ExtendedBurn", Size = "Small", Var = "EcoBurn", Rarity = "Rare", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_bst_med_common_bal`, Fam = "StandardRocket", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_bst_med_epic_ovb`, Fam = "HighImpulse", Size = "Medium", Var = "Overboost", Rarity = "Epic", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_bst_small_common_raw_1`, Fam = "StandardRocket", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_bst_small_common_raw_2`, Fam = "StandardRocket", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_bst_small_common_raw_3`, Fam = "StandardRocket", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "DevWorkshopSample" },
		{ Id = `dev_{storage.OwnerUserId}_bst_small_common_raw_4`, Fam = "StandardRocket", Size = "Small", Var = "Balanced", Rarity = "Common", Tag = "DevWorkshopSample" },
	}

	for _, preset in ipairs(boosterPresets) do
		if preset.Id and not existingIds[preset.Id] then
			existingIds[preset.Id] = true
			table.insert(storage.UniqueUnits, {
				ItemInstanceId = preset.Id,
				ItemId = "SmallBooster",
				Category = "Boosters",
				FamilyId = preset.Fam,
				SizeId = preset.Size,
				VariantId = preset.Var,
				RarityId = preset.Rarity,
				CreatedAt = now,
				SourceTag = preset.Tag,
			})
		end
	end
end

local function commitStorageMutation(
	userId: number,
	mutateFn: (draft: ItemTypes.PlayerInventoryStorage) -> (boolean, string?, string?)
): (boolean, ItemTypes.PlayerInventoryStorage?, string?, string?)
	local current = _storageByUserId[userId]
	if not current then
		return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, "Inventario del jugador no cargado."
	end

	local draft = cloneStorage(current)
	local okMutate, mutErrCode, mutErrMsg = mutateFn(draft)
	if not okMutate then
		return false, nil, mutErrCode, mutErrMsg
	end

	draft.InventoryRevision += 1
	draft.UpdatedAt = os.time()

	local okSave, saveErrCode, saveErrMsg = InventoryPersistenceService.SavePlayerInventory(userId, draft)
	if not okSave then
		return false, nil, saveErrCode or BuildProtocol.ErrorCodes.PersistenceFailed, saveErrMsg or "Error al guardar inventario."
	end

	_storageByUserId[userId] = draft
	rebuildUnitCacheForUser(userId, draft)
	return true, draft, nil, nil
end

local function emptyUsageSummary(): BlueprintUsageSummary
	return {
		WorkshopItemCounts = {},
		WorkshopUnitIds = {},
		MaxSlotItemCounts = {},
		SlotIndicesByItemId = {},
		SlotIndicesByUnitId = {},
	}
end

local function getBlueprintUsage(userId: number): BlueprintUsageSummary
	if _blueprintUsageProvider then
		return _blueprintUsageProvider(userId)
	end
	return emptyUsageSummary()
end

function InventoryService.RegisterBlueprintUsageProvider(provider: ((userId: number) -> BlueprintUsageSummary)?)
	_blueprintUsageProvider = provider
end

function InventoryService.RegisterRuntimeStateChecker(checker: ((userId: number) -> boolean)?)
	_runtimeStateChecker = checker
end

function InventoryService.RegisterSellPayoutProvider(
	provider: ((userId: number, amount: number, txId: string) -> (boolean, number?, string?, string?))?
)
	_sellPayoutProvider = provider
end

function InventoryService.HasUnitId(playerOrUserId: PlayerLike | number, itemInstanceId: string?): boolean
	if type(itemInstanceId) ~= "string" or #itemInstanceId == 0 then
		return false
	end
	local okLoad = InventoryService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad then
		return false
	end
	local userId = extractUserId(playerOrUserId)
	local rec = _unitRecordsById[itemInstanceId]
	return rec ~= nil and rec.OwnerUserId == userId
end

function InventoryService.IsLegacyTestQuotaEnabled(): boolean
	return _autoGrantLegacyQuota == true
end

function InventoryService.IsVehicleInActiveRuntime(playerOrUserId: PlayerLike | number): boolean
	if not _runtimeStateChecker then
		return false
	end
	local userId = extractUserId(playerOrUserId)
	return _runtimeStateChecker(userId) == true
end

function InventoryService.EnsurePlayerLoaded(
	playerOrUserId: PlayerLike | number
): (boolean, ItemTypes.PlayerInventoryStorage?, string?, string?)
	if not _initialized then
		InventoryService.Init()
	end

	local userId = extractUserId(playerOrUserId)
	local cached = _storageByUserId[userId]
	if cached then
		return true, cached, nil, nil
	end

	local okLoad, loadedStorage, errCode, errMsg = InventoryPersistenceService.LoadPlayerInventory(userId)
	if not okLoad then
		-- CRÍTICO: nunca otorgar kit inicial cuando falla la carga de DataStore
		return false, nil, errCode or BuildProtocol.ErrorCodes.PersistenceFailed, errMsg or "Error al cargar inventario."
	end

	if loadedStorage then
		if _autoGrantLegacyQuota then
			applyLegacyTestSuiteQuota(loadedStorage)
		end
		_storageByUserId[userId] = loadedStorage
		rebuildUnitCacheForUser(userId, loadedStorage)
		return true, loadedStorage, nil, nil
	end

	local fresh = createEmptyStorage(userId, false)
	if _autoGrantLegacyQuota then
		applyStartingInventory(fresh)
		applyLegacyTestSuiteQuota(fresh)
	else
		applyStartingInventory(fresh)
	end

	local okSave, saveErrCode, saveErrMsg = InventoryPersistenceService.SavePlayerInventory(userId, fresh)
	if not okSave then
		return false, nil, saveErrCode or BuildProtocol.ErrorCodes.PersistenceFailed, saveErrMsg or "No se pudo inicializar el inventario."
	end

	_storageByUserId[userId] = fresh
	rebuildUnitCacheForUser(userId, fresh)
	return true, fresh, nil, nil
end

function InventoryService.GetOwnedQuantity(playerOrUserId: PlayerLike | number, itemId: string): number
	local okLoad, storage = InventoryService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad or not storage then
		return 0
	end
	if ItemRegistry.IsUniqueInventoryItem(itemId) then
		local count = 0
		for _, unit in ipairs(storage.UniqueUnits) do
			if unit.ItemId == itemId then
				count += 1
			end
		end
		return count
	end
	return storage.Items[itemId] or 0
end

function InventoryService.GetUnitById(itemInstanceId: string?): any?
	if type(itemInstanceId) ~= "string" or #itemInstanceId == 0 then
		return nil
	end
	return _unitRecordsById[itemInstanceId]
end

function InventoryService.GetPlayerEngineUnits(playerOrUserId: PlayerLike | number): { ItemTypes.EngineUnitRecord }
	local okLoad = InventoryService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad then
		return {}
	end
	local userId = extractUserId(playerOrUserId)
	local ids = _unitIdsByUserId[userId]
	if not ids then
		return {}
	end
	local result: { ItemTypes.EngineUnitRecord } = {}
	for _, id in ipairs(ids) do
		local rec = _unitRecordsById[id]
		if rec and ItemRegistry.Get(rec.ItemId).Category == "Engines" then
			table.insert(result, rec)
		end
	end
	return result
end

function InventoryService.GetPlayerBoosterUnits(playerOrUserId: PlayerLike | number): { ItemTypes.BoosterUnitRecord }
	local okLoad = InventoryService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad then
		return {}
	end
	local userId = extractUserId(playerOrUserId)
	local ids = _unitIdsByUserId[userId]
	if not ids then
		return {}
	end
	local result: { ItemTypes.BoosterUnitRecord } = {}
	for _, id in ipairs(ids) do
		local rec = _unitRecordsById[id]
		if rec and ItemRegistry.Get(rec.ItemId).Category == "Boosters" then
			table.insert(result, rec)
		end
	end
	return result
end

function InventoryService.AddItem(
	playerOrUserId: PlayerLike | number,
	itemId: string,
	quantity: number
): (boolean, string?, string?)
	local userId = extractUserId(playerOrUserId)
	local def = ItemRegistry.TryGet(itemId)
	if not def then
		return false, BuildProtocol.ErrorCodes.UnknownItem, `Objeto desconocido en catálogo: '{tostring(itemId)}'.`
	end
	if ItemRegistry.IsUniqueInventoryItem(def) then
		return false, BuildProtocol.ErrorCodes.InvalidPayload, `'{def.DisplayName}' requiere registrar una unidad única.`
	end
	if not isPositiveInt(quantity) then
		return false, BuildProtocol.ErrorCodes.InvalidPayload, "La cantidad a agregar debe ser un entero positivo."
	end

	local okLoad, _, loadCode, loadMsg = InventoryService.EnsurePlayerLoaded(userId)
	if not okLoad then
		return false, loadCode, loadMsg
	end

	local okCommit, _, errCode, errMsg = commitStorageMutation(userId, function(draft)
		draft.Items[itemId] = (draft.Items[itemId] or 0) + math.floor(quantity)
		return true, nil, nil
	end)
	return okCommit, errCode, errMsg
end

function InventoryService.ConsumeForRollbackIfAvailable(
	playerOrUserId: PlayerLike | number,
	itemId: string,
	quantity: number
): boolean
	local userId = extractUserId(playerOrUserId)
	if not isPositiveInt(quantity) or not _storageByUserId[userId] then
		return false
	end
	local qty = math.floor(quantity)
	local okCommit = commitStorageMutation(userId, function(draft)
		local cur = draft.Items[itemId] or 0
		if cur < qty then
			return false, BuildProtocol.ErrorCodes.InsufficientInventory, "Rollback skip"
		end
		local nextQty = cur - qty
		draft.Items[itemId] = if nextQty > 0 then nextQty else nil
		return true, nil, nil
	end)
	return okCommit
end

function InventoryService.AddEngineUnit(
	playerOrUserId: PlayerLike | number,
	params: {
		ItemInstanceId: string?,
		ItemId: string?,
		EngineFamilyId: ItemTypes.EngineFamilyId?,
		EngineSizeId: ItemTypes.EngineSizeId?,
		VariantId: ItemTypes.EngineVariantId?,
		RarityId: ItemTypes.EngineRarityId?,
		SourceTag: string?,
	}?
): (boolean, ItemTypes.EngineUnitRecord?, string?, string?)
	local userId = extractUserId(playerOrUserId)
	local opts = params or {}

	local okLoad, _, loadCode, loadMsg = InventoryService.EnsurePlayerLoaded(userId)
	if not okLoad then
		return false, nil, loadCode, loadMsg
	end

	local rawInstanceId = opts.ItemInstanceId
	local instanceId = if type(rawInstanceId) == "string" and #rawInstanceId > 0
		then rawInstanceId
		else generateUnitInstanceId("engunit_")

	local existingGlobal = _unitRecordsById[instanceId]
	if existingGlobal and existingGlobal.OwnerUserId ~= userId then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `[InventoryService] ItemInstanceId '{instanceId}' ya pertenece a otro jugador.`
	end
	if existingGlobal and existingGlobal.OwnerUserId == userId and type(rawInstanceId) == "string" and #rawInstanceId > 0 then
		return true, existingGlobal, nil, nil
	end

	local effectiveStats = EngineCatalog.ResolveEffectiveStats({
		ItemId = opts.ItemId or "SmallEngine",
		EngineFamilyId = opts.EngineFamilyId or GameConfig.Powertrain.DefaultFamilyId :: any,
		EngineSizeId = opts.EngineSizeId or GameConfig.Powertrain.DefaultSizeId :: any,
		VariantId = opts.VariantId or GameConfig.Powertrain.DefaultVariantId :: any,
		RarityId = opts.RarityId or GameConfig.Powertrain.DefaultRarityId :: any,
	})

	local createdAt = os.time()
	local serializedUnit: ItemTypes.SerializedInventoryUnit = {
		ItemInstanceId = instanceId,
		ItemId = effectiveStats.BaseItemId,
		Category = "Engines",
		FamilyId = effectiveStats.EngineFamilyId,
		SizeId = effectiveStats.EngineSizeId,
		VariantId = effectiveStats.VariantId,
		RarityId = effectiveStats.RarityId,
		CreatedAt = createdAt,
		SourceTag = opts.SourceTag or "ShopPurchase",
	}

	local okCommit, _, errCode, errMsg = commitStorageMutation(userId, function(draft)
		for idx, existing in ipairs(draft.UniqueUnits) do
			if existing.ItemInstanceId == instanceId then
				draft.UniqueUnits[idx] = serializedUnit
				return true, nil, nil
			end
		end
		table.insert(draft.UniqueUnits, serializedUnit)
		return true, nil, nil
	end)
	if not okCommit then
		return false, nil, errCode, errMsg
	end

	return true, _unitRecordsById[instanceId], nil, nil
end

function InventoryService.AddBoosterUnit(
	playerOrUserId: PlayerLike | number,
	params: {
		ItemInstanceId: string?,
		ItemId: string?,
		BoosterFamilyId: ItemTypes.BoosterFamilyId?,
		BoosterSizeId: ItemTypes.BoosterSizeId?,
		VariantId: ItemTypes.BoosterVariantId?,
		RarityId: ItemTypes.BoosterRarityId?,
		SourceTag: string?,
	}?
): (boolean, ItemTypes.BoosterUnitRecord?, string?, string?)
	local userId = extractUserId(playerOrUserId)
	local opts = params or {}

	local okLoad, _, loadCode, loadMsg = InventoryService.EnsurePlayerLoaded(userId)
	if not okLoad then
		return false, nil, loadCode, loadMsg
	end

	local rawInstanceId = opts.ItemInstanceId
	local instanceId = if type(rawInstanceId) == "string" and #rawInstanceId > 0
		then rawInstanceId
		else generateUnitInstanceId("bstunit_")

	local existingGlobal = _unitRecordsById[instanceId]
	if existingGlobal and existingGlobal.OwnerUserId ~= userId then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `[InventoryService] ItemInstanceId '{instanceId}' ya pertenece a otro jugador.`
	end
	if existingGlobal and existingGlobal.OwnerUserId == userId and type(rawInstanceId) == "string" and #rawInstanceId > 0 then
		return true, existingGlobal, nil, nil
	end

	local effectiveStats = BoosterCatalog.ResolveEffectiveStats({
		ItemId = opts.ItemId or "SmallBooster",
		BoosterFamilyId = opts.BoosterFamilyId or GameConfig.Boosters.DefaultFamilyId :: any,
		BoosterSizeId = opts.BoosterSizeId or GameConfig.Boosters.DefaultSizeId :: any,
		VariantId = opts.VariantId or GameConfig.Boosters.DefaultVariantId :: any,
		RarityId = opts.RarityId or GameConfig.Boosters.DefaultRarityId :: any,
	})

	local createdAt = os.time()
	local serializedUnit: ItemTypes.SerializedInventoryUnit = {
		ItemInstanceId = instanceId,
		ItemId = effectiveStats.BaseItemId,
		Category = "Boosters",
		FamilyId = effectiveStats.BoosterFamilyId,
		SizeId = effectiveStats.BoosterSizeId,
		VariantId = effectiveStats.VariantId,
		RarityId = effectiveStats.RarityId,
		CreatedAt = createdAt,
		SourceTag = opts.SourceTag or "ShopPurchase",
	}

	local okCommit, _, errCode, errMsg = commitStorageMutation(userId, function(draft)
		for idx, existing in ipairs(draft.UniqueUnits) do
			if existing.ItemInstanceId == instanceId then
				draft.UniqueUnits[idx] = serializedUnit
				return true, nil, nil
			end
		end
		table.insert(draft.UniqueUnits, serializedUnit)
		return true, nil, nil
	end)
	if not okCommit then
		return false, nil, errCode, errMsg
	end

	return true, _unitRecordsById[instanceId], nil, nil
end

function InventoryService.FindAvailableUniqueUnit(
	playerOrUserId: PlayerLike | number,
	itemId: string,
	activePieces: { [string]: VehicleTypes.BlueprintPiece }?,
	excludePieceId: string?
): any?
	local okLoad, storage = InventoryService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad or not storage then
		return nil
	end

	local usedIds: { [string]: boolean } = {}
	if activePieces then
		for pieceId, piece in pairs(activePieces) do
			if pieceId ~= excludePieceId and type(piece.InventoryInstanceId) == "string" and #piece.InventoryInstanceId > 0 then
				usedIds[piece.InventoryInstanceId] = true
			end
		end
	end

	local bestCandidate: any = nil
	for _, unit in ipairs(storage.UniqueUnits) do
		if unit.ItemId == itemId and not usedIds[unit.ItemInstanceId] then
			local record = _unitRecordsById[unit.ItemInstanceId]
			if record then
				if unit.SourceTag == "StarterKit" or unit.SourceTag == "StarterDefault" then
					return record
				end
				if not bestCandidate then
					bestCandidate = record
				end
			end
		end
	end

	return bestCandidate
end

function InventoryService.ValidatePlacement(
	playerOrUserId: PlayerLike | number,
	itemId: string,
	inventoryInstanceId: string?,
	pieceInstanceId: string,
	activePieces: { [string]: VehicleTypes.BlueprintPiece }?
): PlacementValidationResult
	local def = ItemRegistry.TryGet(itemId)
	if not def then
		return {
			Valid = false,
			ErrorCode = BuildProtocol.ErrorCodes.UnknownItem,
			ErrorMessage = `Objeto desconocido: '{tostring(itemId)}'.`,
		}
	end

	local userId = extractUserId(playerOrUserId)
	local okLoad, storage, errCode, errMsg = InventoryService.EnsurePlayerLoaded(userId)
	if not okLoad or not storage then
		return {
			Valid = false,
			ErrorCode = errCode or BuildProtocol.ErrorCodes.PersistenceFailed,
			ErrorMessage = errMsg or "No se pudo verificar tu inventario.",
		}
	end

	if ItemRegistry.IsUniqueInventoryItem(def) then
		local isEngine = def.Category == "Engines"
		local chosenId = inventoryInstanceId

		if type(chosenId) == "string" and #chosenId > 0 then
			local unit = _unitRecordsById[chosenId]
			if not unit then
				return {
					Valid = false,
					ErrorCode = if isEngine then BuildProtocol.ErrorCodes.UnknownEngineUnit else BuildProtocol.ErrorCodes.UnknownBoosterUnit,
					ErrorMessage = `La unidad '{chosenId}' no existe en el registro del servidor.`,
				}
			end
			if unit.OwnerUserId ~= userId then
				return {
					Valid = false,
					ErrorCode = if isEngine then BuildProtocol.ErrorCodes.UnauthorizedEngineUnit else BuildProtocol.ErrorCodes.UnauthorizedBoosterUnit,
					ErrorMessage = "No puedes usar una unidad que pertenece a otro jugador.",
				}
			end
			if unit.ItemId ~= itemId then
				return {
					Valid = false,
					ErrorCode = BuildProtocol.ErrorCodes.InvalidPayload,
					ErrorMessage = `La unidad '{chosenId}' corresponde a '{unit.ItemId}', no a '{itemId}'.`,
				}
			end
			if activePieces then
				for otherPieceId, otherPiece in pairs(activePieces) do
					if otherPieceId ~= pieceInstanceId and otherPiece.InventoryInstanceId == chosenId then
						return {
							Valid = false,
							ErrorCode = if isEngine
								then BuildProtocol.ErrorCodes.DuplicateEngineUnitInBlueprint
								else BuildProtocol.ErrorCodes.DuplicateBoosterUnitInBlueprint,
							ErrorMessage = `La unidad '{chosenId}' ya está instalada en este vehículo ({otherPieceId}).`,
						}
					end
				end
			end
			return {
				Valid = true,
				ResolvedInventoryInstanceId = chosenId,
				UnitRecord = unit,
			}
		end

		if chosenId ~= nil and type(chosenId) ~= "string" then
			return {
				Valid = false,
				ErrorCode = BuildProtocol.ErrorCodes.InvalidPayload,
				ErrorMessage = "InventoryInstanceId debe ser una cadena válida.",
			}
		end

		-- Respuesta A4: si el cliente omite InventoryInstanceId, auto-asignar unidad libre del jugador
		local freeUnit = InventoryService.FindAvailableUniqueUnit(userId, itemId, activePieces, pieceInstanceId)
		if not freeUnit then
			return {
				Valid = false,
				ErrorCode = BuildProtocol.ErrorCodes.InsufficientInventory,
				ErrorMessage = `No tienes unidades disponibles de '{def.DisplayName}' en tu inventario.`,
			}
		end

		return {
			Valid = true,
			ResolvedInventoryInstanceId = freeUnit.ItemInstanceId,
			UnitRecord = freeUnit,
		}
	end

	-- Objeto común acumulable
	if inventoryInstanceId ~= nil and #inventoryInstanceId > 0 then
		return {
			Valid = false,
			ErrorCode = BuildProtocol.ErrorCodes.InvalidPayload,
			ErrorMessage = `InventoryInstanceId solo aplica a motores o propulsores, no a '{def.DisplayName}'.`,
		}
	end

	local usedCount = 0
	if activePieces then
		for otherPieceId, piece in pairs(activePieces) do
			if otherPieceId ~= pieceInstanceId and piece.ItemId == itemId then
				usedCount += 1
			end
		end
	end

	if _autoGrantLegacyQuota and storage.Items[itemId] == nil then
		storage.Items[itemId] = 1000
	end

	local owned = storage.Items[itemId] or 0
	if usedCount + 1 > owned then
		return {
			Valid = false,
			ErrorCode = BuildProtocol.ErrorCodes.InsufficientInventory,
			ErrorMessage = `Inventario insuficiente de '{def.DisplayName}' ({owned} en propiedad, {usedCount} en uso).`,
		}
	end

	return {
		Valid = true,
		ResolvedInventoryInstanceId = nil,
		UnitRecord = nil,
	}
end

function InventoryService.ValidateBlueprintForLoad(
	playerOrUserId: PlayerLike | number,
	blueprint: VehicleTypes.VehicleBlueprint
): (boolean, string?, string?)
	local userId = extractUserId(playerOrUserId)
	local okLoad, storage, loadCode, loadMsg = InventoryService.EnsurePlayerLoaded(userId)
	if not okLoad or not storage then
		return false, loadCode or BuildProtocol.ErrorCodes.PersistenceFailed, loadMsg or "No se pudo cargar tu inventario."
	end

	local neededByItemId: { [string]: number } = {}
	local seenUnits: { [string]: string } = {}
	local availableByUniqueItemId: { [string]: number } = {}
	for _, unit in ipairs(storage.UniqueUnits) do
		availableByUniqueItemId[unit.ItemId] = (availableByUniqueItemId[unit.ItemId] or 0) + 1
	end
	local neededUniqueByItemId: { [string]: number } = {}

	for pieceId, piece in pairs(blueprint.Pieces) do
		local def = ItemRegistry.TryGet(piece.ItemId)
		if not def then
			return false, BuildProtocol.ErrorCodes.UnknownItem, `El diseño contiene un objeto desconocido ('{tostring(piece.ItemId)}').`
		end

		if ItemRegistry.IsUniqueInventoryItem(def) then
			local invId = piece.InventoryInstanceId
			local isEngine = def.Category == "Engines"
			if type(invId) == "string" and #invId > 0 then
				local unit = _unitRecordsById[invId]
				if not unit then
					return false,
						if isEngine then BuildProtocol.ErrorCodes.UnknownEngineUnit else BuildProtocol.ErrorCodes.UnknownBoosterUnit,
						`El diseño referencia una unidad que ya no existe en tu inventario ('{invId}').`
				end
				if unit.OwnerUserId ~= userId then
					return false,
						if isEngine then BuildProtocol.ErrorCodes.UnauthorizedEngineUnit else BuildProtocol.ErrorCodes.UnauthorizedBoosterUnit,
						`El diseño referencia una unidad que pertenece a otro jugador ('{invId}').`
				end
				if unit.ItemId ~= piece.ItemId then
					return false,
						BuildProtocol.ErrorCodes.InvalidPayload,
						`La unidad '{invId}' no coincide con la pieza '{piece.ItemId}'.`
				end
				if seenUnits[invId] then
					return false,
						if isEngine
							then BuildProtocol.ErrorCodes.DuplicateEngineUnitInBlueprint
							else BuildProtocol.ErrorCodes.DuplicateBoosterUnitInBlueprint,
						`El diseño duplica ilegalmente la unidad '{invId}' entre piezas ({seenUnits[invId]} y {pieceId}).`
				end
				seenUnits[invId] = pieceId
			elseif not _autoGrantLegacyQuota then
				neededUniqueByItemId[piece.ItemId] = (neededUniqueByItemId[piece.ItemId] or 0) + 1
				if neededUniqueByItemId[piece.ItemId] > (availableByUniqueItemId[piece.ItemId] or 0) then
					return false,
						BuildProtocol.ErrorCodes.UnitNotOwned,
						`El diseño requiere un '{def.DisplayName}' que ya no tienes disponible en tu inventario.`
				end
			end
		else
			neededByItemId[piece.ItemId] = (neededByItemId[piece.ItemId] or 0) + 1
		end
	end

	for itemId, needed in pairs(neededByItemId) do
		if _autoGrantLegacyQuota and storage.Items[itemId] == nil then
			storage.Items[itemId] = 1000
		end
		local owned = storage.Items[itemId] or 0
		if owned < needed then
			local displayName = ItemCatalog.GetDisplayName(itemId)
			return false,
				BuildProtocol.ErrorCodes.InsufficientInventory,
				`Inventario insuficiente para cargar el diseño: necesitas {needed}x '{displayName}' y posees {owned}.`
		end
	end

	return true, nil, nil
end

function InventoryService.GetPlayerSnapshot(playerOrUserId: PlayerLike | number): ItemTypes.PlayerInventorySnapshot?
	local userId = extractUserId(playerOrUserId)
	local okLoad, storage = InventoryService.EnsurePlayerLoaded(userId)
	if not okLoad or not storage then
		return nil
	end

	local usage = getBlueprintUsage(userId)
	local entries = ItemCatalog.GetAllEntries()

	local itemsList: { ItemTypes.InventoryItemEntry } = table.create(#entries)
	local itemsById: { [string]: ItemTypes.InventoryItemEntry } = {}

	local uniqueUnitsCountByItemId: { [string]: number } = {}
	for _, u in ipairs(storage.UniqueUnits) do
		uniqueUnitsCountByItemId[u.ItemId] = (uniqueUnitsCountByItemId[u.ItemId] or 0) + 1
	end

	for _, catalogEntry in ipairs(entries) do
		local itemId = catalogEntry.Id
		local isUnique = catalogEntry.IsUniqueUnit
		local owned = if isUnique then (uniqueUnitsCountByItemId[itemId] or 0) else (storage.Items[itemId] or 0)
		local workshopUsed = usage.WorkshopItemCounts[itemId] or 0
		local maxSlotUsed = usage.MaxSlotItemCounts[itemId] or 0
		local lockedFromSale = math.max(workshopUsed, maxSlotUsed)
		local availableToPlace = math.max(0, owned - workshopUsed)
		local sellableQuantity = math.max(0, owned - lockedFromSale)

		local blockedSlots: { number } = {}
		local slotMap = usage.SlotIndicesByItemId[itemId]
		if slotMap then
			for slotIdx = 1, GameConfig.Blueprints.MaxSlots do
				if (slotMap[slotIdx] or 0) > 0 then
					table.insert(blockedSlots, slotIdx)
				end
			end
		end

		local itemEntry: ItemTypes.InventoryItemEntry = {
			ItemId = itemId,
			DisplayName = catalogEntry.DisplayName,
			Description = catalogEntry.Description,
			Category = catalogEntry.Category,
			CategoryDisplayName = catalogEntry.CategoryDisplayName,
			AssetFolder = catalogEntry.AssetFolder,
			InventoryKind = catalogEntry.InventoryKind,
			Price = catalogEntry.Price,
			SellPrice = catalogEntry.SellPrice,
			OwnedQuantity = owned,
			WorkshopReservedQuantity = workshopUsed,
			BlueprintMaxReferencedQuantity = maxSlotUsed,
			LockedFromSale = lockedFromSale,
			AvailableToPlace = availableToPlace,
			SellableQuantity = sellableQuantity,
			BlockedSlotIndices = blockedSlots,
		}
		table.insert(itemsList, itemEntry)
		itemsById[itemId] = itemEntry
	end

	local uniqueUnits: { ItemTypes.InventoryUnitSummary } = {}
	local engineUnits: { ItemTypes.InventoryUnitSummary } = {}
	local boosterUnits: { ItemTypes.InventoryUnitSummary } = {}

	for _, rawUnit in ipairs(storage.UniqueUnits) do
		local rec = _unitRecordsById[rawUnit.ItemInstanceId]
		if rec then
			local usedWorkshop = usage.WorkshopUnitIds[rawUnit.ItemInstanceId] == true
			local refSlots = table.clone(usage.SlotIndicesByUnitId[rawUnit.ItemInstanceId] or {})
			table.sort(refSlots)
			local canSell = not usedWorkshop and #refSlots == 0
			local def = ItemRegistry.Get(rec.ItemId)
			local eff = rec.EffectiveStats
			local unitSellPrice = ItemCatalog.GetSellPrice(def)
			local summary: ItemTypes.InventoryUnitSummary = {
				ItemInstanceId = rec.ItemInstanceId,
				ItemId = rec.ItemId,
				Category = def.Category,
				DisplayName = eff.DisplayName,
				FullLabel = eff.FullLabel,
				FamilyId = rawUnit.FamilyId,
				SizeId = rawUnit.SizeId,
				VariantId = rawUnit.VariantId,
				RarityId = rawUnit.RarityId,
				UsedInWorkshop = usedWorkshop,
				ReferencedSlotIndices = refSlots,
				AvailableToPlaceInWorkshop = not usedWorkshop,
				CanSell = canSell and unitSellPrice ~= nil,
				CanSellForMoney = unitSellPrice ~= nil,
				SourceTag = rawUnit.SourceTag,
				CreatedAt = rawUnit.CreatedAt,
				EffectiveStats = eff,
			}
			table.insert(uniqueUnits, summary)
			if def.Category == "Engines" then
				table.insert(engineUnits, summary)
			elseif def.Category == "Boosters" then
				table.insert(boosterUnits, summary)
			end
		end
	end

	return {
		OwnerUserId = userId,
		InventoryRevision = storage.InventoryRevision,
		StarterKitGranted = storage.StarterKitGranted,
		StarterKitVersion = storage.StarterKitVersion,
		Items = itemsList,
		ItemsById = itemsById,
		UniqueUnits = uniqueUnits,
		EngineUnits = engineUnits,
		BoosterUnits = boosterUnits,
	}
end

function InventoryService.SellItem(
	playerOrUserId: PlayerLike | number,
	itemId: string,
	quantity: number?,
	itemInstanceId: string?
): SellResponse
	local userId = extractUserId(playerOrUserId)
	local def = ItemRegistry.TryGet(itemId)
	if not def then
		return {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.UnknownItem,
			ErrorMessage = `Objeto desconocido: '{tostring(itemId)}'.`,
		}
	end

	local okLoad, storage, loadCode, loadMsg = InventoryService.EnsurePlayerLoaded(userId)
	if not okLoad or not storage then
		return {
			Success = false,
			ErrorCode = loadCode or BuildProtocol.ErrorCodes.PersistenceFailed,
			ErrorMessage = loadMsg or "No se pudo cargar tu inventario.",
		}
	end

	if InventoryService.IsVehicleInActiveRuntime(userId) then
		return {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.InvalidPlayerState,
			ErrorMessage = "Regresa tu vehículo al taller antes de vender piezas o unidades del inventario.",
		}
	end

	local usage = getBlueprintUsage(userId)
	local unitSellPrice = ItemCatalog.GetSellPrice(def)
	local currencyNote = ItemCatalog.FormatSellNote(unitSellPrice)

	if ItemRegistry.IsUniqueInventoryItem(def) then
		if type(itemInstanceId) ~= "string" or #itemInstanceId == 0 then
			return {
				Success = false,
				ErrorCode = BuildProtocol.ErrorCodes.InvalidPayload,
				ErrorMessage = `Debes indicar el ItemInstanceId de la unidad de '{def.DisplayName}' a vender.`,
			}
		end

		local unitRecord = _unitRecordsById[itemInstanceId]
		if not unitRecord or unitRecord.OwnerUserId ~= userId or unitRecord.ItemId ~= itemId then
			return {
				Success = false,
				ErrorCode = BuildProtocol.ErrorCodes.UnitNotOwned,
				ErrorMessage = `La unidad '{itemInstanceId}' no pertenece a tu inventario actual de '{def.DisplayName}'.`,
			}
		end

		local blockedInWorkshop = usage.WorkshopUnitIds[itemInstanceId] == true
		local blockedSlots = table.clone(usage.SlotIndicesByUnitId[itemInstanceId] or {})
		table.sort(blockedSlots)
		if blockedInWorkshop or #blockedSlots > 0 then
			local parts: { string } = {}
			if blockedInWorkshop then
				table.insert(parts, "taller actual")
			end
			if #blockedSlots > 0 then
				local slotStrs: { string } = table.create(#blockedSlots)
				for _, sIdx in ipairs(blockedSlots) do
					table.insert(slotStrs, `Slot {sIdx}`)
				end
				table.insert(parts, table.concat(slotStrs, ", "))
			end
			return {
				Success = false,
				ErrorCode = BuildProtocol.ErrorCodes.SellBlockedByReferences,
				ErrorMessage = `No puedes vender '{unitRecord.EffectiveStats.FullLabel}' porque sigue en uso en: {table.concat(parts, " y ")}. Desvincúlala de esos diseños primero.`,
				BlockedInWorkshop = blockedInWorkshop,
				BlockedSlotIndices = blockedSlots,
			}
		end

		if unitSellPrice == nil then
			return {
				Success = false,
				ErrorCode = BuildProtocol.ErrorCodes.InvalidPlayerState,
				ErrorMessage = "No se permite vender motores ni propulsores únicos hasta configurar su valoración individual.",
			}
		end

		local okCommit, _, commitErrCode, commitErrMsg = commitStorageMutation(userId, function(draft)
			local foundIdx: number? = nil
			for idx, u in ipairs(draft.UniqueUnits) do
				if u.ItemInstanceId == itemInstanceId then
					foundIdx = idx
					break
				end
			end
			if not foundIdx then
				return false, BuildProtocol.ErrorCodes.UnitNotOwned, "La unidad ya no existe en tu inventario."
			end
			table.remove(draft.UniqueUnits, foundIdx)
			return true, nil, nil
		end)
		if not okCommit then
			return {
				Success = false,
				ErrorCode = commitErrCode or BuildProtocol.ErrorCodes.PersistenceFailed,
				ErrorMessage = commitErrMsg or "Error al guardar la venta de la unidad.",
			}
		end

		return {
			Success = true,
			SellResult = {
				SoldItemId = itemId,
				SoldQuantity = 1,
				RemovedUnitId = itemInstanceId,
				SellValue = def.SellPrice, -- TBD hasta Fase 5.2 (nil si no está definido)
				CurrencyNote = currencyNote,
			},
			Snapshot = InventoryService.GetPlayerSnapshot(userId),
		}
	end

	-- Venta de objeto común acumulable
	local qtyToSell = if quantity == nil then 1 else quantity
	if not isPositiveInt(qtyToSell) then
		return {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.InvalidPayload,
			ErrorMessage = "La cantidad a vender debe ser un número entero positivo.",
		}
	end
	qtyToSell = math.floor(qtyToSell)

	local owned = storage.Items[itemId] or 0
	if owned < qtyToSell then
		return {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.InsufficientInventory,
			ErrorMessage = `No puedes vender {qtyToSell}x '{def.DisplayName}' porque solo posees {owned}.`,
		}
	end

	local remainingAfterSale = owned - qtyToSell
	local workshopUsed = usage.WorkshopItemCounts[itemId] or 0
	local blockedInWorkshop = remainingAfterSale < workshopUsed

	local blockedSlots: { number } = {}
	local slotCounts = usage.SlotIndicesByItemId[itemId]
	if slotCounts then
		for slotIdx = 1, GameConfig.Blueprints.MaxSlots do
			if (slotCounts[slotIdx] or 0) > remainingAfterSale then
				table.insert(blockedSlots, slotIdx)
			end
		end
	end

	if blockedInWorkshop or #blockedSlots > 0 then
		local parts: { string } = {}
		if blockedInWorkshop then
			table.insert(parts, `taller ({workshopUsed} usadas)`)
		end
		if #blockedSlots > 0 then
			local slotStrs: { string } = table.create(#blockedSlots)
			for _, sIdx in ipairs(blockedSlots) do
				local cnt = if slotCounts then (slotCounts[sIdx] or 0) else 0
				table.insert(slotStrs, `Slot {sIdx} ({cnt} usadas)`)
			end
			table.insert(parts, table.concat(slotStrs, ", "))
		end
		return {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.SellBlockedByReferences,
			ErrorMessage = `No puedes vender {qtyToSell}x '{def.DisplayName}' porque dejaría piezas sin respaldo en: {table.concat(parts, " y ")}.`,
			BlockedInWorkshop = blockedInWorkshop,
			BlockedSlotIndices = blockedSlots,
		}
	end

	if unitSellPrice == nil then
		return {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.InvalidPlayerState,
			ErrorMessage = `El objeto '{def.DisplayName}' aún no tiene valoración de venta configurada.`,
		}
	end

	local preSellSnapshot = cloneStorage(storage)
	local okCommit, _, commitErrCode, commitErrMsg = commitStorageMutation(userId, function(draft)
		local cur = draft.Items[itemId] or 0
		if cur < qtyToSell then
			return false, BuildProtocol.ErrorCodes.InsufficientInventory, "Cantidad insuficiente al confirmar la venta."
		end
		local nextQty = cur - qtyToSell
		draft.Items[itemId] = if nextQty > 0 then nextQty else nil
		return true, nil, nil
	end)
	if not okCommit then
		return {
			Success = false,
			ErrorCode = commitErrCode or BuildProtocol.ErrorCodes.PersistenceFailed,
			ErrorMessage = commitErrMsg or "Error al guardar la venta.",
		}
	end

	local sellValueTotal = math.floor(unitSellPrice :: number) * qtyToSell
	local newBalance: number? = nil
	if _sellPayoutProvider and sellValueTotal > 0 then
		local txId = `inv_sell_{userId}_{itemId}_{qtyToSell}_{HttpService:GenerateGUID(false)}`
		local okPay, paidBalance, payErrCode, payErrMsg = _sellPayoutProvider(userId, sellValueTotal, txId)
		if not okPay then
			-- Rollback completo de inventario si falló el abono/persistencia económica
			_storageByUserId[userId] = preSellSnapshot
			rebuildUnitCacheForUser(userId, preSellSnapshot)
			pcall(function()
				InventoryPersistenceService.SavePlayerInventory(userId, preSellSnapshot)
			end)
			return {
				Success = false,
				ErrorCode = payErrCode or BuildProtocol.ErrorCodes.PersistenceFailed,
				ErrorMessage = payErrMsg or "Error al acreditar las monedas de la venta.",
			}
		end
		newBalance = paidBalance
	end

	return {
		Success = true,
		SellResult = {
			SoldItemId = itemId,
			SoldQuantity = qtyToSell,
			RemovedUnitId = nil,
			SellValue = sellValueTotal,
			NewBalance = newBalance,
			CurrencyNote = `+{sellValueTotal} monedas`,
		},
		Snapshot = InventoryService.GetPlayerSnapshot(userId),
	}
end

function InventoryService.ClearPlayerMemory(playerOrUserId: PlayerLike | number)
	local userId = extractUserId(playerOrUserId)
	_storageByUserId[userId] = nil
	clearUnitCacheForUser(userId)
end

-- Helper exclusivo para pruebas: inicializa inventario vacío (0 objetos, 0 unidades) y persiste
function InventoryService.InitEmptyForTests(playerOrUserId: PlayerLike | number, markStarterGranted: boolean?): boolean
	local userId = extractUserId(playerOrUserId)
	local empty = createEmptyStorage(userId, markStarterGranted == true)
	local okSave = InventoryPersistenceService.SavePlayerInventory(userId, empty)
	if not okSave then
		return false
	end
	_storageByUserId[userId] = empty
	rebuildUnitCacheForUser(userId, empty)
	return true
end

function InventoryService.GrantItemForTests(
	playerOrUserId: PlayerLike | number,
	itemId: string,
	quantity: number
): (boolean, string?, string?)
	return InventoryService.AddItem(playerOrUserId, itemId, quantity)
end

function InventoryService.GrantEngineUnitForTests(
	playerOrUserId: PlayerLike | number,
	params: {
		ItemInstanceId: string?,
		ItemId: string?,
		EngineFamilyId: ItemTypes.EngineFamilyId?,
		EngineSizeId: ItemTypes.EngineSizeId?,
		VariantId: ItemTypes.EngineVariantId?,
		RarityId: ItemTypes.EngineRarityId?,
		SourceTag: string?,
	}?
): ItemTypes.EngineUnitRecord
	local opts = table.clone(params or {})
	opts.SourceTag = opts.SourceTag or "DevTestGrant"
	local ok, unit, _, errMsg = InventoryService.AddEngineUnit(playerOrUserId, opts)
	if not ok or not unit then
		error(`[InventoryService.GrantEngineUnitForTests] {tostring(errMsg)}`, 2)
	end
	return unit
end

function InventoryService.GrantBoosterUnitForTests(
	playerOrUserId: PlayerLike | number,
	params: {
		ItemInstanceId: string?,
		ItemId: string?,
		BoosterFamilyId: ItemTypes.BoosterFamilyId?,
		BoosterSizeId: ItemTypes.BoosterSizeId?,
		VariantId: ItemTypes.BoosterVariantId?,
		RarityId: ItemTypes.BoosterRarityId?,
		SourceTag: string?,
	}?
): ItemTypes.BoosterUnitRecord
	local opts = table.clone(params or {})
	opts.SourceTag = opts.SourceTag or "DevTestGrant"
	local ok, unit, _, errMsg = InventoryService.AddBoosterUnit(playerOrUserId, opts)
	if not ok or not unit then
		error(`[InventoryService.GrantBoosterUnitForTests] {tostring(errMsg)}`, 2)
	end
	return unit
end

function InventoryService._ResetForTests(
	preservePersistence: boolean?,
	opts: { AutoGrantLegacySuiteQuota: boolean? }?
)
	table.clear(_storageByUserId)
	table.clear(_unitRecordsById)
	table.clear(_unitIdsByUserId)
	_autoGrantLegacyQuota = if type(opts) == "table" and opts.AutoGrantLegacySuiteQuota == true then true else false
	if not preservePersistence then
		InventoryPersistenceService._ResetForTests(true)
	end
end

function InventoryService._ClearAllUnitsPreservingModeForTests()
	table.clear(_storageByUserId)
	table.clear(_unitRecordsById)
	table.clear(_unitIdsByUserId)
	InventoryPersistenceService._ResetForTests(true)
end

function InventoryService.Init()
	if _initialized then
		return
	end
	_initialized = true
	ItemRegistry.Init()
	InventoryPersistenceService.Init()

	Players.PlayerRemoving:Connect(function(player)
		InventoryService.ClearPlayerMemory(player.UserId)
	end)
end

function InventoryService.Start()
	if not _initialized then
		InventoryService.Init()
	end
	if _started then
		return
	end
	_started = true
	InventoryPersistenceService.Start()
end

return InventoryService
