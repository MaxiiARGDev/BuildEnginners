--!strict
--[=[
	EconomyService
	Billetera central autoritativa de monedas del jugador (Fase 5.2).

	Responsabilidades:
	- Entrega ShopConfig.Economy.StartingMoney (1,000 monedas) estrictamente UNA sola vez
	  al crear un jugador nuevo (StarterMoneyGranted = true), nunca en reconexiones ni
	  ante fallo de carga de DataStoreService.
	- Ejecuta TryDebit y Credit de forma atómica con persistencia y rollback en memoria.
	- Mantiene idempotencia por TxId y PurchaseId (Developer Products / AdRewards).
	- Conecta con InventoryService (RegisterSellPayoutProvider) para pagar el 50% del
	  precio de compra en venta de piezas normales.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local EconomyPersistenceService = require(ServerScriptService.Server.Services.EconomyPersistenceService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)

export type PlayerLike = Player | {
	UserId: number,
	Name: string,
}

local EconomyService = {
	Name = "EconomyService",
}

local _initialized = false
local _started = false
local _clockFn: () -> number = os.time
local _storageByUserId: { [number]: ItemTypes.PlayerEconomyStorage } = {}
local _balanceChangedListeners: { (userId: number, newBalance: number, reason: string?) -> () } = {}

local function extractUserId(playerOrUserId: PlayerLike | number): number
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return playerOrUserId.UserId
	elseif type(playerOrUserId) == "table" and type((playerOrUserId :: any).UserId) == "number" then
		return (playerOrUserId :: any).UserId
	end
	error("[EconomyService] Jugador o UserId inválido", 3)
end

local function cloneStorage(s: ItemTypes.PlayerEconomyStorage): ItemTypes.PlayerEconomyStorage
	local breakdownCopy: { { UnitId: string, Label: string, HourlyRate: number, Earned: number } } =
		table.create(#s.PendingOfflineBreakdown)
	for _, b in ipairs(s.PendingOfflineBreakdown) do
		table.insert(breakdownCopy, {
			UnitId = b.UnitId,
			Label = b.Label,
			HourlyRate = b.HourlyRate,
			Earned = b.Earned,
		})
	end

	return {
		StorageSchemaVersion = s.StorageSchemaVersion,
		OwnerUserId = s.OwnerUserId,
		Balance = s.Balance,
		StarterMoneyGranted = s.StarterMoneyGranted,
		UpdatedAt = s.UpdatedAt,
		LastSeenAt = s.LastSeenAt,
		PendingOfflineAmount = s.PendingOfflineAmount,
		PendingOfflineSeconds = s.PendingOfflineSeconds,
		PendingOfflineBreakdown = breakdownCopy,
		OfflineWindowStartAt = s.OfflineWindowStartAt,
		ProcessedTxIds = table.clone(s.ProcessedTxIds),
		ProcessedReceiptIds = table.clone(s.ProcessedReceiptIds),
	}
end

local function createFreshStorage(userId: number, grantStarter: boolean): ItemTypes.PlayerEconomyStorage
	local now = _clockFn()
	return {
		StorageSchemaVersion = ShopConfig.Economy.StorageSchemaVersion,
		OwnerUserId = userId,
		Balance = if grantStarter then ShopConfig.Economy.StartingMoney else 0,
		StarterMoneyGranted = grantStarter,
		UpdatedAt = now,
		LastSeenAt = now,
		PendingOfflineAmount = 0,
		PendingOfflineSeconds = 0,
		PendingOfflineBreakdown = {},
		OfflineWindowStartAt = now,
		ProcessedTxIds = {},
		ProcessedReceiptIds = {},
	}
end

local function appendTrackedId(list: { string }, value: string)
	if not table.find(list, value) then
		table.insert(list, value)
		while #list > ShopConfig.Economy.MaxTrackedProcessedIds do
			table.remove(list, 1)
		end
	end
end

local function emitBalanceChanged(userId: number, balance: number, reason: string?)
	for _, cb in ipairs(table.clone(_balanceChangedListeners)) do
		task.spawn(cb, userId, balance, reason)
	end
end

function EconomyService.GetNow(): number
	return _clockFn()
end

function EconomyService.EnsurePlayerLoaded(
	playerOrUserId: PlayerLike | number
): (boolean, ItemTypes.PlayerEconomyStorage?, string?, string?)
	if not _initialized then
		EconomyService.Init()
	end

	local userId = extractUserId(playerOrUserId)
	local cached = _storageByUserId[userId]
	if cached then
		return true, cached, nil, nil
	end

	local okLoad, loaded, loadCode, loadMsg = EconomyPersistenceService.LoadPlayerEconomy(userId)
	if not okLoad then
		-- CRÍTICO: nunca otorgar StartingMoney si falla DataStore
		return false, nil, loadCode or ShopProtocol.ErrorCodes.PersistenceFailed, loadMsg or "Error al cargar saldo."
	end

	if loaded then
		_storageByUserId[userId] = loaded
		return true, loaded, nil, nil
	end

	local fresh = createFreshStorage(userId, true)
	local okSave, saveCode, saveMsg = EconomyPersistenceService.SavePlayerEconomy(userId, fresh)
	if not okSave then
		return false, nil, saveCode or ShopProtocol.ErrorCodes.PersistenceFailed, saveMsg or "Error al inicializar billetera."
	end

	_storageByUserId[userId] = fresh
	return true, fresh, nil, nil
end

function EconomyService.MutateEconomyRecord(
	playerOrUserId: PlayerLike | number,
	mutateFn: (draft: ItemTypes.PlayerEconomyStorage) -> (boolean, string?, string?),
	reason: string?
): (boolean, ItemTypes.PlayerEconomyStorage?, string?, string?)
	local userId = extractUserId(playerOrUserId)
	local okLoad, current, loadCode, loadMsg = EconomyService.EnsurePlayerLoaded(userId)
	if not okLoad or not current then
		return false, nil, loadCode, loadMsg
	end

	local prevBalance = current.Balance
	local draft = cloneStorage(current)
	local okMutate, mutCode, mutMsg = mutateFn(draft)
	if not okMutate then
		return false, nil, mutCode, mutMsg
	end

	draft.Balance = math.max(0, math.floor(draft.Balance))
	draft.UpdatedAt = _clockFn()

	local okSave, saveCode, saveMsg = EconomyPersistenceService.SavePlayerEconomy(userId, draft)
	if not okSave then
		return false, nil, saveCode or ShopProtocol.ErrorCodes.PersistenceFailed, saveMsg or "No se pudo guardar la economía."
	end

	_storageByUserId[userId] = draft
	if draft.Balance ~= prevBalance then
		emitBalanceChanged(userId, draft.Balance, reason)
	end
	return true, draft, nil, nil
end

function EconomyService.GetBalance(playerOrUserId: PlayerLike | number): (number, boolean)
	local okLoad, storage = EconomyService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad or not storage then
		return 0, false
	end
	return storage.Balance, true
end

function EconomyService.GetSnapshotCopy(playerOrUserId: PlayerLike | number): ItemTypes.PlayerEconomyStorage?
	local okLoad, storage = EconomyService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad or not storage then
		return nil
	end
	return cloneStorage(storage)
end

function EconomyService.CanAfford(playerOrUserId: PlayerLike | number, amount: number): boolean
	if type(amount) ~= "number" or amount < 0 or amount ~= amount or amount == math.huge then
		return false
	end
	local bal, okLoad = EconomyService.GetBalance(playerOrUserId)
	if not okLoad then
		return false
	end
	return bal >= math.floor(amount)
end

function EconomyService.HasProcessedTxId(playerOrUserId: PlayerLike | number, txId: string?): boolean
	if type(txId) ~= "string" or #txId == 0 then
		return false
	end
	local okLoad, storage = EconomyService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad or not storage then
		return false
	end
	return table.find(storage.ProcessedTxIds, txId) ~= nil
end

function EconomyService.HasProcessedReceipt(playerOrUserId: PlayerLike | number, receiptId: string?): boolean
	if type(receiptId) ~= "string" or #receiptId == 0 then
		return false
	end
	local okLoad, storage = EconomyService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad or not storage then
		return false
	end
	return table.find(storage.ProcessedReceiptIds, receiptId) ~= nil
end

function EconomyService.TryDebit(
	playerOrUserId: PlayerLike | number,
	amount: number,
	reason: string?,
	txId: string?
): (boolean, number?, string?, string?)
	if type(amount) ~= "number" or amount <= 0 or amount ~= amount or amount == math.huge or amount % 1 ~= 0 then
		return false, nil, ShopProtocol.ErrorCodes.InvalidPayload, "El monto a descontar debe ser un entero positivo."
	end
	local debit = math.floor(amount)
	local okCommit, draft, errCode, errMsg = EconomyService.MutateEconomyRecord(playerOrUserId, function(d)
		if type(txId) == "string" and #txId > 0 and table.find(d.ProcessedTxIds, txId) ~= nil then
			return true, nil, nil
		end
		if d.Balance < debit then
			return false,
				ShopProtocol.ErrorCodes.InsufficientFunds,
				`Saldo insuficiente: necesitás ${debit} monedas y tenés ${d.Balance}.`
		end
		d.Balance -= debit
		if type(txId) == "string" and #txId > 0 then
			appendTrackedId(d.ProcessedTxIds, txId)
		end
		return true, nil, nil
	end, reason or "Debit")
	if not okCommit or not draft then
		return false, nil, errCode, errMsg
	end
	return true, draft.Balance, nil, nil
end

function EconomyService.Credit(
	playerOrUserId: PlayerLike | number,
	amount: number,
	reason: string?,
	txId: string?,
	receiptId: string?
): (boolean, number?, string?, string?)
	if type(amount) ~= "number" or amount <= 0 or amount ~= amount or amount == math.huge or amount % 1 ~= 0 then
		return false, nil, ShopProtocol.ErrorCodes.InvalidPayload, "El monto a acreditar debe ser un entero positivo."
	end
	local credit = math.floor(amount)
	local okCommit, draft, errCode, errMsg = EconomyService.MutateEconomyRecord(playerOrUserId, function(d)
		if type(txId) == "string" and #txId > 0 and table.find(d.ProcessedTxIds, txId) ~= nil then
			return true, nil, nil
		end
		if type(receiptId) == "string" and #receiptId > 0 and table.find(d.ProcessedReceiptIds, receiptId) ~= nil then
			return true, nil, nil
		end
		d.Balance += credit
		if type(txId) == "string" and #txId > 0 then
			appendTrackedId(d.ProcessedTxIds, txId)
		end
		if type(receiptId) == "string" and #receiptId > 0 then
			appendTrackedId(d.ProcessedReceiptIds, receiptId)
		end
		return true, nil, nil
	end, reason or "Credit")
	if not okCommit or not draft then
		return false, nil, errCode, errMsg
	end
	return true, draft.Balance, nil, nil
end

function EconomyService.RecordProcessedReceipt(
	playerOrUserId: PlayerLike | number,
	receiptId: string
): (boolean, string?, string?)
	if type(receiptId) ~= "string" or #receiptId == 0 then
		return false, ShopProtocol.ErrorCodes.InvalidPayload, "ReceiptId inválido."
	end
	local okCommit, _, errCode, errMsg = EconomyService.MutateEconomyRecord(playerOrUserId, function(d)
		appendTrackedId(d.ProcessedReceiptIds, receiptId)
		return true, nil, nil
	end, "RecordReceipt")
	return okCommit, errCode, errMsg
end

function EconomyService.RegisterBalanceChangedListener(
	listener: (userId: number, newBalance: number, reason: string?) -> ()
): () -> ()
	table.insert(_balanceChangedListeners, listener)
	return function()
		local idx = table.find(_balanceChangedListeners, listener)
		if idx then
			table.remove(_balanceChangedListeners, idx)
		end
	end
end

function EconomyService.ClearPlayerMemory(playerOrUserId: PlayerLike | number)
	local userId = extractUserId(playerOrUserId)
	_storageByUserId[userId] = nil
end

function EconomyService.InitWithBalanceForTests(
	playerOrUserId: PlayerLike | number,
	balance: number,
	markStarterGranted: boolean?
): boolean
	local userId = extractUserId(playerOrUserId)
	local s = createFreshStorage(userId, if markStarterGranted == nil then true else markStarterGranted == true)
	s.Balance = math.max(0, math.floor(balance))
	local okSave = EconomyPersistenceService.SavePlayerEconomy(userId, s)
	if not okSave then
		return false
	end
	_storageByUserId[userId] = s
	return true
end

function EconomyService._SetClockForTests(clockFn: (() -> number)?)
	_clockFn = clockFn or os.time
end

function EconomyService._ResetForTests(preservePersistence: boolean?)
	table.clear(_storageByUserId)
	table.clear(_balanceChangedListeners)
	_clockFn = os.time
	if not preservePersistence then
		EconomyPersistenceService._ResetForTests(true)
	end
end

function EconomyService.Init()
	if not _initialized then
		_initialized = true
		EconomyPersistenceService.Init()

		Players.PlayerRemoving:Connect(function(player)
			EconomyService.ClearPlayerMemory(player.UserId)
		end)
	end

	-- Siempre re-registrar el proveedor de pago de venta en InventoryService
	InventoryService.RegisterSellPayoutProvider(function(userId: number, amount: number, txId: string)
		return EconomyService.Credit(userId, amount, "InventorySell", txId, nil)
	end)
end

function EconomyService.Start()
	if not _initialized then
		EconomyService.Init()
	end
	if _started then
		return
	end
	_started = true
	EconomyPersistenceService.Start()
end

return EconomyService

