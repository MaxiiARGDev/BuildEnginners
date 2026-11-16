--!strict
--[=[
	InventoryPersistenceService
	Capa de persistencia autoritativa en DataStoreService para el inventario central por jugador (Fase 5.1).
	- Almacena versión de esquema, bandera StarterKitGranted, cantidades comunes e instancias únicas de motores/propulsores.
	- Nunca confía en estadísticas serializadas del cliente: guarda únicamente IDs de catálogo y metadatos de unidad.
	- Propaga fallos de persistencia sin otorgar kits duplicados ni confirmar escrituras falsas.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local DataStoreIoHelper = require(ServerScriptService.Server.Security.DataStoreIoHelper)

export type StorageAdapter = DataStoreIoHelper.StorageAdapter

local InventoryPersistenceService = {
	Name = "InventoryPersistenceService",
}

local _store = DataStoreIoHelper.CreateStoreHandle({
	PrimaryStoreName = GameConfig.Inventory.DataStoreName,
})
local _initialized = false
local _started = false

local function isFiniteNonNegInt(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v >= 0 and v % 1 == 0
end

function InventoryPersistenceService.SerializeStorage(storage: ItemTypes.PlayerInventoryStorage): { [string]: any }
	local cleanItems: { [string]: number } = {}
	for itemId, qty in pairs(storage.Items or {}) do
		if type(itemId) == "string" and #itemId > 0 and isFiniteNonNegInt(qty) and qty > 0 then
			cleanItems[itemId] = math.floor(qty)
		end
	end

	local cleanUnits: { { [string]: any } } = {}
	for _, unit in ipairs(storage.UniqueUnits or {}) do
		if type(unit.ItemInstanceId) == "string" and #unit.ItemInstanceId > 0 then
			table.insert(cleanUnits, {
				ItemInstanceId = unit.ItemInstanceId,
				ItemId = unit.ItemId,
				Category = unit.Category,
				FamilyId = unit.FamilyId,
				SizeId = unit.SizeId,
				VariantId = unit.VariantId,
				RarityId = unit.RarityId,
				CreatedAt = if type(unit.CreatedAt) == "number" then unit.CreatedAt else os.time(),
				SourceTag = if type(unit.SourceTag) == "string" then unit.SourceTag else "StarterKit",
			})
		end
	end

	return {
		StorageSchemaVersion = GameConfig.Inventory.StorageSchemaVersion,
		OwnerUserId = storage.OwnerUserId,
		InventoryRevision = storage.InventoryRevision or 0,
		UpdatedAt = storage.UpdatedAt or os.time(),
		StarterKitGranted = storage.StarterKitGranted == true,
		StarterKitVersion = storage.StarterKitVersion or GameConfig.Inventory.StarterKitVersion,
		Items = cleanItems,
		UniqueUnits = cleanUnits,
	}
end

function InventoryPersistenceService.DeserializeStorage(
	raw: any,
	expectedUserId: number
): (boolean, ItemTypes.PlayerInventoryStorage?, string?)
	if type(raw) ~= "table" then
		return false, nil, "Formato de inventario persistido inválido"
	end

	local ver = raw.StorageSchemaVersion
	if type(ver) ~= "number" or ver < 1 or ver > GameConfig.Inventory.StorageSchemaVersion or ver % 1 ~= 0 then
		return false, nil, `Versión de esquema de inventario no soportada: {tostring(ver)}`
	end

	local items: { [string]: number } = {}
	if type(raw.Items) == "table" then
		for itemId, qty in pairs(raw.Items) do
			if type(itemId) == "string" and ItemRegistry.Has(itemId) and not ItemRegistry.IsUniqueInventoryItem(itemId) then
				if isFiniteNonNegInt(qty) and qty > 0 then
					items[itemId] = math.floor(qty)
				end
			end
		end
	end

	local units: { ItemTypes.SerializedInventoryUnit } = {}
	local seenUnitIds: { [string]: boolean } = {}
	if type(raw.UniqueUnits) == "table" then
		for _, rawUnit in ipairs(raw.UniqueUnits) do
			if
				type(rawUnit) == "table"
				and type(rawUnit.ItemInstanceId) == "string"
				and #rawUnit.ItemInstanceId > 0
				and not seenUnitIds[rawUnit.ItemInstanceId]
				and type(rawUnit.ItemId) == "string"
				and ItemRegistry.Has(rawUnit.ItemId)
			then
				local def = ItemRegistry.Get(rawUnit.ItemId)
				if def.Category == "Engines" or def.Category == "Boosters" then
					seenUnitIds[rawUnit.ItemInstanceId] = true
					table.insert(units, {
						ItemInstanceId = rawUnit.ItemInstanceId,
						ItemId = def.Id,
						Category = def.Category :: ("Engines" | "Boosters"),
						FamilyId = if type(rawUnit.FamilyId) == "string" then rawUnit.FamilyId else "",
						SizeId = if type(rawUnit.SizeId) == "string" then rawUnit.SizeId else "Small",
						VariantId = if type(rawUnit.VariantId) == "string" then rawUnit.VariantId else "Balanced",
						RarityId = if type(rawUnit.RarityId) == "string" then rawUnit.RarityId else "Common",
						CreatedAt = if type(rawUnit.CreatedAt) == "number" then rawUnit.CreatedAt else os.time(),
						SourceTag = if type(rawUnit.SourceTag) == "string" then rawUnit.SourceTag else "StarterKit",
					})
				end
			end
		end
	end

	return true,
		{
			StorageSchemaVersion = GameConfig.Inventory.StorageSchemaVersion,
			OwnerUserId = expectedUserId,
			InventoryRevision = if isFiniteNonNegInt(raw.InventoryRevision) then raw.InventoryRevision else 0,
			UpdatedAt = if type(raw.UpdatedAt) == "number" then raw.UpdatedAt else os.time(),
			StarterKitGranted = raw.StarterKitGranted == true,
			StarterKitVersion = if isFiniteNonNegInt(raw.StarterKitVersion) then raw.StarterKitVersion else 0,
			Items = items,
			UniqueUnits = units,
		},
		nil
end

function InventoryPersistenceService.Init()
	if _initialized then
		return
	end
	ItemRegistry.Init()
	_initialized = true
end

function InventoryPersistenceService.Start()
	if not _initialized then
		InventoryPersistenceService.Init()
	end
	_started = true
end

function InventoryPersistenceService.IsBusyForUser(userId: number): boolean
	return _store.IsBusyForUser(userId)
end

function InventoryPersistenceService.GetLastStorageMode(): string
	return _store.GetLastStorageMode()
end

function InventoryPersistenceService.SavePlayerInventory(
	userId: number,
	storage: ItemTypes.PlayerInventoryStorage
): (boolean, string?, string?)
	if not _initialized then
		InventoryPersistenceService.Init()
	end
	local serialized = InventoryPersistenceService.SerializeStorage(storage)
	return _store.SaveRaw(userId, serialized)
end

function InventoryPersistenceService.LoadPlayerInventory(
	userId: number
): (boolean, ItemTypes.PlayerInventoryStorage?, string?, string?)
	if not _initialized then
		InventoryPersistenceService.Init()
	end
	local okLoad, rawData, errCode, errMsg = _store.LoadRaw(userId, false)
	if not okLoad then
		return false, nil, errCode or BuildProtocol.ErrorCodes.PersistenceFailed, errMsg
	end
	if rawData == nil then
		return true, nil, nil, nil
	end
	local okDec, parsed, decErr = InventoryPersistenceService.DeserializeStorage(rawData, userId)
	if not okDec or not parsed then
		return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, decErr or "Inventario persistido corrupto"
	end
	return true, parsed, nil, nil
end

function InventoryPersistenceService._SetStorageAdapterForTests(adapter: StorageAdapter?)
	_store.SetStorageAdapterForTests(adapter)
end

function InventoryPersistenceService._SetSimulateWriteFailureForTests(shouldFail: (boolean | string)?)
	_store.SetSimulateWriteFailureForTests(shouldFail)
end

function InventoryPersistenceService._SetSimulateLoadFailureForTests(shouldFail: (boolean | string)?)
	_store.SetSimulateLoadFailureForTests(shouldFail)
end

function InventoryPersistenceService._GetRawMemorySnapshotForTests(userId: number): { [string]: any }?
	return _store.GetRawMemorySnapshotForTests(userId)
end

function InventoryPersistenceService._SetUseMemoryStoreForTests(enabled: boolean?)
	_store.SetUseMemoryStoreForTests(enabled)
end

function InventoryPersistenceService._ResetForTests(clearSavedMemory: boolean?)
	_store.ResetForTests(clearSavedMemory)
end

return InventoryPersistenceService

