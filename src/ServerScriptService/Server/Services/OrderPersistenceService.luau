--!strict
--[=[
	OrderPersistenceService
	Persistencia autoritativa de pedidos normales (60 s), pedidos especiales (900 s),
	cajas pendientes/abiertas/reclamadas en DeliveryZone y sorteos registrados (Fase 5.2).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local DataStoreIoHelper = require(ServerScriptService.Server.Security.DataStoreIoHelper)

export type StorageAdapter = DataStoreIoHelper.StorageAdapter

local OrderPersistenceService = {
	Name = "OrderPersistenceService",
}

local _store = DataStoreIoHelper.CreateStoreHandle({
	PrimaryStoreName = ShopConfig.Orders.DataStoreName,
})
local _initialized = false
local _started = false

local function sanitizeNumber(val: any, fallback: number): number
	if type(val) ~= "number" or val ~= val or val == math.huge or val == -math.huge then
		return fallback
	end
	return val
end

local function sanitizeCrates(rawCrates: any, fallbackOrderId: string): { ItemTypes.NormalOrderCrateRecord }
	local out: { ItemTypes.NormalOrderCrateRecord } = {}
	if type(rawCrates) ~= "table" then
		return out
	end
	for _, c in ipairs(rawCrates) do
		if type(c) == "table" and type(c.CrateId) == "string" and type(c.ItemId) == "string" and type(c.Quantity) == "number" then
			local status: ItemTypes.OrderCrateStatus = if c.Status == "Spawned" or c.Status == "Opened"
				then c.Status
				else "Queued"
			table.insert(out, {
				CrateId = c.CrateId,
				OrderId = if type(c.OrderId) == "string" then c.OrderId else fallbackOrderId,
				ItemId = c.ItemId,
				Quantity = math.max(1, math.floor(c.Quantity)),
				Status = status,
				SlotIndex = if type(c.SlotIndex) == "number" then math.floor(c.SlotIndex) else nil,
				OpenedAt = if type(c.OpenedAt) == "number" then c.OpenedAt else nil,
				CreditedToInventory = c.CreditedToInventory == true,
			})
		end
	end
	return out
end

local function sanitizeLines(rawLines: any): { ItemTypes.NormalOrderLine }
	local out: { ItemTypes.NormalOrderLine } = {}
	if type(rawLines) ~= "table" then
		return out
	end
	for _, l in ipairs(rawLines) do
		if type(l) == "table" and type(l.ItemId) == "string" and type(l.Quantity) == "number" then
			table.insert(out, {
				ItemId = l.ItemId,
				Quantity = math.max(1, math.floor(l.Quantity)),
				UnitPrice = sanitizeNumber(l.UnitPrice, 0),
				LineTotal = sanitizeNumber(l.LineTotal, 0),
			})
		end
	end
	return out
end

local function sanitizeRolledReward(raw: any): ItemTypes.RolledLootReward?
	if type(raw) ~= "table" then
		return nil
	end
	if type(raw.ItemInstanceId) ~= "string" or type(raw.ItemId) ~= "string" then
		return nil
	end
	local cat: "Engines" | "Boosters" = if raw.Category == "Boosters" then "Boosters" else "Engines"
	return {
		BoxId = if type(raw.BoxId) == "string" then raw.BoxId else "",
		ItemId = raw.ItemId,
		Category = cat,
		FamilyId = if type(raw.FamilyId) == "string" then raw.FamilyId else "",
		SizeId = if type(raw.SizeId) == "string" then raw.SizeId else "Small",
		VariantId = if type(raw.VariantId) == "string" then raw.VariantId else "Balanced",
		RarityId = if type(raw.RarityId) == "string" then raw.RarityId else "Common",
		ItemInstanceId = raw.ItemInstanceId,
		DisplayName = if type(raw.DisplayName) == "string" then raw.DisplayName else raw.ItemId,
		FullLabel = if type(raw.FullLabel) == "string" then raw.FullLabel else raw.ItemId,
		RolledAt = sanitizeNumber(raw.RolledAt, os.time()),
		CreditedToInventory = raw.CreditedToInventory == true,
	}
end

local function sanitizeLoadedStorage(userId: number, raw: any): ItemTypes.PlayerOrdersStorage?
	if type(raw) ~= "table" then
		return nil
	end

	local normalOrders: { ItemTypes.NormalOrderRecord } = {}
	if type(raw.NormalOrders) == "table" then
		for _, o in ipairs(raw.NormalOrders) do
			if type(o) == "table" and type(o.OrderId) == "string" then
				local st: ItemTypes.NormalOrderStatus = if o.Status == "Arrived" or o.Status == "Collected"
					then o.Status
					else "InTransit"
				table.insert(normalOrders, {
					OrderId = o.OrderId,
					OrderType = "Normal",
					OwnerUserId = userId,
					Status = st,
					CreatedAt = sanitizeNumber(o.CreatedAt, 0),
					ArriveAt = sanitizeNumber(o.ArriveAt, 0),
					ArrivedAt = if type(o.ArrivedAt) == "number" then o.ArrivedAt else nil,
					DeliveryUnlocked = o.DeliveryUnlocked == true,
					RushedByRobux = o.RushedByRobux == true,
					RushPurchaseId = if type(o.RushPurchaseId) == "string" then o.RushPurchaseId else nil,
					TotalCost = sanitizeNumber(o.TotalCost, 0),
					Lines = sanitizeLines(o.Lines),
					Crates = sanitizeCrates(o.Crates, o.OrderId),
					TruckAnimated = o.TruckAnimated == true,
				})
			end
		end
	end

	local specialOrders: { ItemTypes.SpecialOrderRecord } = {}
	if type(raw.SpecialOrders) == "table" then
		for _, o in ipairs(raw.SpecialOrders) do
			if type(o) == "table" and type(o.OrderId) == "string" and type(o.BoxId) == "string" then
				local st: ItemTypes.SpecialOrderStatus = if o.Status == "Arrived" or o.Status == "Opened" or o.Status == "Claimed"
					then o.Status
					else "InTransit"
				local cat: "Engines" | "Boosters" = if o.RewardCategory == "Boosters" then "Boosters" else "Engines"
				table.insert(specialOrders, {
					OrderId = o.OrderId,
					OrderType = "Special",
					OwnerUserId = userId,
					BoxId = o.BoxId,
					RewardCategory = cat,
					PricePaid = sanitizeNumber(o.PricePaid, 0),
					Status = st,
					CreatedAt = sanitizeNumber(o.CreatedAt, 0),
					ArriveAt = sanitizeNumber(o.ArriveAt, 0),
					ArrivedAt = if type(o.ArrivedAt) == "number" then o.ArrivedAt else nil,
					RushedByRobux = o.RushedByRobux == true,
					RushPurchaseId = if type(o.RushPurchaseId) == "string" then o.RushPurchaseId else nil,
					SlotIndex = if type(o.SlotIndex) == "number" then math.floor(o.SlotIndex) else nil,
					OpeningStartedAt = if type(o.OpeningStartedAt) == "number" then o.OpeningStartedAt else nil,
					RolledReward = sanitizeRolledReward(o.RolledReward),
					TruckAnimated = o.TruckAnimated == true,
				})
			end
		end
	end

	local txIds: { string } = {}
	if type(raw.ProcessedTxIds) == "table" then
		for _, id in ipairs(raw.ProcessedTxIds) do
			if type(id) == "string" and #id > 0 then
				table.insert(txIds, id)
			end
		end
		while #txIds > ShopConfig.Economy.MaxTrackedProcessedIds do
			table.remove(txIds, 1)
		end
	end

	return {
		StorageSchemaVersion = ShopConfig.Orders.StorageSchemaVersion,
		OwnerUserId = userId,
		OrdersRevision = math.max(0, math.floor(sanitizeNumber(raw.OrdersRevision, 0))),
		UpdatedAt = sanitizeNumber(raw.UpdatedAt, os.time()),
		ActiveNormalOrderId = if type(raw.ActiveNormalOrderId) == "string" and #raw.ActiveNormalOrderId > 0
			then raw.ActiveNormalOrderId
			else nil,
		PendingRushOrderId = if type(raw.PendingRushOrderId) == "string" and #raw.PendingRushOrderId > 0
			then raw.PendingRushOrderId
			else nil,
		NormalOrders = normalOrders,
		SpecialOrders = specialOrders,
		ProcessedTxIds = txIds,
	}
end

function OrderPersistenceService.Init()
	if _initialized then
		return
	end
	_initialized = true
end

function OrderPersistenceService.Start()
	if not _initialized then
		OrderPersistenceService.Init()
	end
	_started = true
end

function OrderPersistenceService.LoadPlayerOrders(
	userId: number
): (boolean, ItemTypes.PlayerOrdersStorage?, string?, string?)
	local ok, raw, code, msg = _store.LoadRaw(userId, false)
	if not ok then
		return false, nil, code, msg
	end
	return true, sanitizeLoadedStorage(userId, raw), nil, nil
end

function OrderPersistenceService.SavePlayerOrders(
	userId: number,
	storage: ItemTypes.PlayerOrdersStorage
): (boolean, string?, string?)
	local payload: { [string]: any } = {
		StorageSchemaVersion = ShopConfig.Orders.StorageSchemaVersion,
		OwnerUserId = userId,
		OrdersRevision = storage.OrdersRevision,
		UpdatedAt = storage.UpdatedAt,
		ActiveNormalOrderId = storage.ActiveNormalOrderId,
		PendingRushOrderId = storage.PendingRushOrderId,
		NormalOrders = storage.NormalOrders,
		SpecialOrders = storage.SpecialOrders,
		ProcessedTxIds = storage.ProcessedTxIds,
	}
	return _store.SaveRaw(userId, payload)
end

function OrderPersistenceService.IsBusyForUser(userId: number): boolean
	return _store.IsBusyForUser(userId)
end

function OrderPersistenceService.GetLastStorageMode(): string
	return _store.GetLastStorageMode()
end

function OrderPersistenceService._SetStorageAdapterForTests(adapter: StorageAdapter?)
	_store.SetStorageAdapterForTests(adapter)
end

function OrderPersistenceService._SetSimulateWriteFailureForTests(shouldFail: (boolean | string)?)
	_store.SetSimulateWriteFailureForTests(shouldFail)
end

function OrderPersistenceService._SetSimulateLoadFailureForTests(shouldFail: (boolean | string)?)
	_store.SetSimulateLoadFailureForTests(shouldFail)
end

function OrderPersistenceService._GetRawMemorySnapshotForTests(userId: number): { [string]: any }?
	return _store.GetRawMemorySnapshotForTests(userId)
end

function OrderPersistenceService._ResetForTests(preserveMemoryData: boolean?)
	_store.SetUseMemoryStoreForTests(true)
	_store.ResetForTests(not preserveMemoryData)
end

return OrderPersistenceService

