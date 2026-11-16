--!strict
--[=[
	BlueprintPersistenceService
	Capa de persistencia autoritativa para blueprints y borradores por jugador (Fase 4.2.1 / 5.1).
	- Esquema v3 en BuildEngineers_PlayerBlueprints_v3 para transición limpia con inventario real.
	- Preserva DeserializePlayerStorage para migración no destructiva en pruebas y cargas compatibles.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local DataStoreIoHelper = require(ServerScriptService.Server.Security.DataStoreIoHelper)

export type StorageAdapter = DataStoreIoHelper.StorageAdapter

local BlueprintPersistenceService = {
	Name = "BlueprintPersistenceService",
}

local _store = DataStoreIoHelper.CreateStoreHandle({
	PrimaryStoreName = GameConfig.Blueprints.DataStoreName,
	LegacyStoreName = GameConfig.Blueprints.LegacyDataStoreName,
})
local _initialized = false
local _started = false

local function makeEmptyPlayerStorage(userId: number): VehicleTypes.PlayerBlueprintStorage
	return {
		StorageSchemaVersion = GameConfig.Blueprints.StorageSchemaVersion,
		OwnerUserId = userId,
		StorageRevision = 0,
		UpdatedAt = os.time(),
		WorkshopDraft = nil,
		Slots = {},
		LegacyOverflow = nil,
	}
end

function BlueprintPersistenceService.Init()
	if _initialized then
		return
	end
	_initialized = true
end

function BlueprintPersistenceService.Start()
	if not _initialized then
		BlueprintPersistenceService.Init()
	end
	_started = true
end

function BlueprintPersistenceService.IsBusyForUser(userId: number): boolean
	return _store.IsBusyForUser(userId)
end

function BlueprintPersistenceService.GetLastStorageMode(): string
	return _store.GetLastStorageMode()
end

function BlueprintPersistenceService.SavePlayerStorage(
	userId: number,
	storage: VehicleTypes.PlayerBlueprintStorage
): (boolean, string?, string?)
	if not _initialized then
		BlueprintPersistenceService.Init()
	end
	local serialized = BlueprintSerializer.SerializePlayerStorage(storage)
	return _store.SaveRaw(userId, serialized)
end

function BlueprintPersistenceService.LoadPlayerStorage(
	userId: number
): (boolean, VehicleTypes.PlayerBlueprintStorage?, string?, string?)
	if not _initialized then
		BlueprintPersistenceService.Init()
	end

	-- En transición Fase 5.1 (v3), no arrastrar automáticamente blueprints pre-inventario de DataStore v1/v2 en vivo;
	-- _studioLegacyMemoryStore y _customAdapter mantienen soporte completo de migración determinista para pruebas.
	local okLoad, rawData, errCode, errMsg = _store.LoadRaw(userId, false)
	if not okLoad then
		return false, nil, errCode, errMsg
	end

	if rawData == nil then
		return true, makeEmptyPlayerStorage(userId), nil, nil
	end

	local okDec, decoded, migrated, decErr = BlueprintSerializer.DeserializePlayerStorage(rawData, userId)
	if not okDec or not decoded then
		return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, decErr or "Datos persistidos corruptos"
	end

	if migrated then
		local serializedMigrated = BlueprintSerializer.SerializePlayerStorage(decoded)
		pcall(function()
			_store.SaveRaw(userId, serializedMigrated)
		end)
	end

	return true, decoded, nil, nil
end

function BlueprintPersistenceService._SetStorageAdapterForTests(adapter: StorageAdapter?)
	_store.SetStorageAdapterForTests(adapter)
end

function BlueprintPersistenceService._SetSimulateWriteFailureForTests(shouldFail: (boolean | string)?)
	_store.SetSimulateWriteFailureForTests(shouldFail)
end

function BlueprintPersistenceService._SetSimulateLoadFailureForTests(shouldFail: (boolean | string)?)
	_store.SetSimulateLoadFailureForTests(shouldFail)
end

function BlueprintPersistenceService._SeedLegacyRawForTests(userId: number, rawLegacyData: any)
	_store.SeedLegacyRawForTests(userId, rawLegacyData)
end

function BlueprintPersistenceService._GetRawMemorySnapshotForTests(userId: number): { [string]: any }?
	return _store.GetRawMemorySnapshotForTests(userId)
end

function BlueprintPersistenceService._SetUseMemoryStoreForTests(enabled: boolean?)
	_store.SetUseMemoryStoreForTests(enabled)
end

function BlueprintPersistenceService._ResetForTests(clearSavedMemory: boolean?)
	_store.ResetForTests(clearSavedMemory)
end

return BlueprintPersistenceService
