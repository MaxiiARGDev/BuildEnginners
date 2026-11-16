--!strict
--[=[
	EconomyPersistenceService
	Persistencia autoritativa de saldo, bono monetario inicial, ingresos offline pendientes
	e historial de idempotencia (PurchaseId / TxId) sobre DataStoreIoHelper (Fase 5.2).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local DataStoreIoHelper = require(ServerScriptService.Server.Security.DataStoreIoHelper)

export type StorageAdapter = DataStoreIoHelper.StorageAdapter

local EconomyPersistenceService = {
	Name = "EconomyPersistenceService",
}

local _store = DataStoreIoHelper.CreateStoreHandle({
	PrimaryStoreName = ShopConfig.Economy.DataStoreName,
})
local _initialized = false
local _started = false

local function sanitizeNonNegNumber(val: any, fallback: number): number
	if type(val) ~= "number" or val ~= val or val == math.huge or val == -math.huge or val < 0 then
		return fallback
	end
	return val
end

local function sanitizeStringArray(raw: any, maxItems: number): { string }
	local out: { string } = {}
	if type(raw) ~= "table" then
		return out
	end
	local seen: { [string]: boolean } = {}
	for _, v in ipairs(raw) do
		if type(v) == "string" and #v > 0 and not seen[v] then
			seen[v] = true
			table.insert(out, v)
		end
	end
	while #out > maxItems do
		table.remove(out, 1)
	end
	return out
end

local function sanitizeLoadedStorage(userId: number, raw: any): ItemTypes.PlayerEconomyStorage?
	if type(raw) ~= "table" then
		return nil
	end

	local breakdown: { { UnitId: string, Label: string, HourlyRate: number, Earned: number } } = {}
	if type(raw.PendingOfflineBreakdown) == "table" then
		for _, entry in ipairs(raw.PendingOfflineBreakdown) do
			if type(entry) == "table" and type(entry.UnitId) == "string" then
				table.insert(breakdown, {
					UnitId = entry.UnitId,
					Label = if type(entry.Label) == "string" then entry.Label else entry.UnitId,
					HourlyRate = sanitizeNonNegNumber(entry.HourlyRate, 0),
					Earned = sanitizeNonNegNumber(entry.Earned, 0),
				})
			end
		end
	end

	local now = os.time()
	return {
		StorageSchemaVersion = if type(raw.StorageSchemaVersion) == "number"
			then raw.StorageSchemaVersion
			else ShopConfig.Economy.StorageSchemaVersion,
		OwnerUserId = userId,
		Balance = math.floor(sanitizeNonNegNumber(raw.Balance, 0)),
		StarterMoneyGranted = raw.StarterMoneyGranted == true,
		UpdatedAt = sanitizeNonNegNumber(raw.UpdatedAt, now),
		LastSeenAt = sanitizeNonNegNumber(raw.LastSeenAt, now),
		PendingOfflineAmount = math.floor(sanitizeNonNegNumber(raw.PendingOfflineAmount, 0)),
		PendingOfflineSeconds = sanitizeNonNegNumber(raw.PendingOfflineSeconds, 0),
		PendingOfflineBreakdown = breakdown,
		OfflineWindowStartAt = sanitizeNonNegNumber(raw.OfflineWindowStartAt, sanitizeNonNegNumber(raw.LastSeenAt, now)),
		ProcessedTxIds = sanitizeStringArray(raw.ProcessedTxIds, ShopConfig.Economy.MaxTrackedProcessedIds),
		ProcessedReceiptIds = sanitizeStringArray(raw.ProcessedReceiptIds, ShopConfig.Economy.MaxTrackedProcessedIds),
	}
end

function EconomyPersistenceService.Init()
	if _initialized then
		return
	end
	_initialized = true
end

function EconomyPersistenceService.Start()
	if not _initialized then
		EconomyPersistenceService.Init()
	end
	_started = true
end

function EconomyPersistenceService.LoadPlayerEconomy(
	userId: number
): (boolean, ItemTypes.PlayerEconomyStorage?, string?, string?)
	local ok, raw, code, msg = _store.LoadRaw(userId, false)
	if not ok then
		return false, nil, code, msg
	end
	return true, sanitizeLoadedStorage(userId, raw), nil, nil
end

function EconomyPersistenceService.SavePlayerEconomy(
	userId: number,
	storage: ItemTypes.PlayerEconomyStorage
): (boolean, string?, string?)
	local breakdownCopy: { { UnitId: string, Label: string, HourlyRate: number, Earned: number } } = {}
	for _, b in ipairs(storage.PendingOfflineBreakdown) do
		table.insert(breakdownCopy, {
			UnitId = b.UnitId,
			Label = b.Label,
			HourlyRate = b.HourlyRate,
			Earned = b.Earned,
		})
	end

	local payload: { [string]: any } = {
		StorageSchemaVersion = ShopConfig.Economy.StorageSchemaVersion,
		OwnerUserId = userId,
		Balance = math.max(0, math.floor(storage.Balance)),
		StarterMoneyGranted = storage.StarterMoneyGranted == true,
		UpdatedAt = storage.UpdatedAt,
		LastSeenAt = storage.LastSeenAt,
		PendingOfflineAmount = math.max(0, math.floor(storage.PendingOfflineAmount)),
		PendingOfflineSeconds = math.max(0, storage.PendingOfflineSeconds),
		PendingOfflineBreakdown = breakdownCopy,
		OfflineWindowStartAt = storage.OfflineWindowStartAt,
		ProcessedTxIds = sanitizeStringArray(storage.ProcessedTxIds, ShopConfig.Economy.MaxTrackedProcessedIds),
		ProcessedReceiptIds = sanitizeStringArray(storage.ProcessedReceiptIds, ShopConfig.Economy.MaxTrackedProcessedIds),
	}

	return _store.SaveRaw(userId, payload)
end

function EconomyPersistenceService.IsBusyForUser(userId: number): boolean
	return _store.IsBusyForUser(userId)
end

function EconomyPersistenceService.GetLastStorageMode(): string
	return _store.GetLastStorageMode()
end

function EconomyPersistenceService._SetStorageAdapterForTests(adapter: StorageAdapter?)
	_store.SetStorageAdapterForTests(adapter)
end

function EconomyPersistenceService._SetSimulateWriteFailureForTests(shouldFail: (boolean | string)?)
	_store.SetSimulateWriteFailureForTests(shouldFail)
end

function EconomyPersistenceService._SetSimulateLoadFailureForTests(shouldFail: (boolean | string)?)
	_store.SetSimulateLoadFailureForTests(shouldFail)
end

function EconomyPersistenceService._GetRawMemorySnapshotForTests(userId: number): { [string]: any }?
	return _store.GetRawMemorySnapshotForTests(userId)
end

function EconomyPersistenceService._ResetForTests(preserveMemoryData: boolean?)
	_store.SetUseMemoryStoreForTests(true)
	_store.ResetForTests(not preserveMemoryData)
end

return EconomyPersistenceService

