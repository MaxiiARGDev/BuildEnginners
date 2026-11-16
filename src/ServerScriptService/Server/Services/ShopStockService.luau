--!strict
--[=[
	ShopStockService
	Stock compartido por todos los jugadores dentro de la instancia de servidor actual (Fases 5.2 y 5.3.2).

	Reglas críticas:
	- Aplica únicamente a cajas especiales habilitadas (nunca a componentes normales).
	- Cada BoxId tiene su propio stock independiente (StockMin, StockMax, CurrentStock, RestockIntervalSeconds).
	- Al iniciar servidor o cumplirse el intervalo de una caja, REEMPLAZA el stock anterior de esa caja,
	  nunca lo acumula ni lo suma.
	- Descuento síncrono atómico por BoxId antes de cualquier operación DataStore asíncrona para evitar
	  sobreventa en compras simultáneas de la última unidad.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local ShopStockService = {
	Name = "ShopStockService",
}

local _initialized = false
local _started = false
local _clockFn: () -> number = os.time
local _rng = Random.new()
local _rngOverride: ((min: number, max: number, boxId: string) -> number)? = nil

local _stockByBoxId: { [string]: number } = {}
local _nextRestockAtByBoxId: { [string]: number } = {}
local _lastRestockAtByBoxId: { [string]: number } = {}
local _nextRestockAt = 0
local _lastRestockAt = 0
local _restockEpoch = 0
local _heartbeatConn: RBXScriptConnection? = nil
local _accumCheck = 0
local _stockChangedListeners: { (reason: string) -> () } = {}

local function drawRestockQty(boxDef: LootBoxConfig.LootBoxDefinition): number
	local minQ, maxQ = LootBoxConfig.GetStockBounds(boxDef.BoxId)
	if _rngOverride then
		local picked = _rngOverride(minQ, maxQ, boxDef.BoxId)
		return math.clamp(math.floor(picked), minQ, maxQ)
	end
	return _rng:NextInteger(minQ, maxQ)
end

local function recomputeGlobalNextRestockAt(now: number)
	local earliest: number? = nil
	for _, boxDef in ipairs(LootBoxConfig.GetEnabledBoxes()) do
		local nextAt = _nextRestockAtByBoxId[boxDef.BoxId]
		if type(nextAt) == "number" and nextAt > 0 then
			if earliest == nil or nextAt < earliest then
				earliest = nextAt
			end
		end
	end
	_nextRestockAt = earliest or (now + ShopConfig.Orders.RestockIntervalSeconds)
end

local function emitStockChanged(reason: string)
	for _, cb in ipairs(table.clone(_stockChangedListeners)) do
		task.spawn(cb, reason)
	end
end

function ShopStockService.ExecuteBoxRestock(boxId: string, reason: string?): number
	local now = _clockFn()
	local boxDef = LootBoxConfig.GetBox(boxId)
	if not boxDef or not boxDef.Enabled then
		_stockByBoxId[boxId] = 0
		return 0
	end
	local _, _, intervalSec = LootBoxConfig.GetStockBounds(boxId)
	local newQty = drawRestockQty(boxDef)
	-- REGLA CRÍTICA: reemplazo estricto, nunca suma.
	_stockByBoxId[boxId] = newQty
	_lastRestockAtByBoxId[boxId] = now
	_nextRestockAtByBoxId[boxId] = now + intervalSec
	_lastRestockAt = now
	recomputeGlobalNextRestockAt(now)
	_restockEpoch += 1
	emitStockChanged(reason or `BoxRestock:{boxId}`)
	return newQty
end

function ShopStockService.ExecuteRestock(reason: string?): number
	local now = _clockFn()
	-- REGLA CRÍTICA: reemplazo absoluto por cada BoxId, nunca acumulación.
	for _, boxDef in ipairs(LootBoxConfig.GetEnabledBoxes()) do
		local _, _, intervalSec = LootBoxConfig.GetStockBounds(boxDef.BoxId)
		_stockByBoxId[boxDef.BoxId] = drawRestockQty(boxDef)
		_lastRestockAtByBoxId[boxDef.BoxId] = now
		_nextRestockAtByBoxId[boxDef.BoxId] = now + intervalSec
	end
	_lastRestockAt = now
	recomputeGlobalNextRestockAt(now)
	_restockEpoch += 1
	emitStockChanged(reason or "Restock")
	return _restockEpoch
end

function ShopStockService.GetStock(boxId: string): number
	return _stockByBoxId[boxId] or 0
end

function ShopStockService.GetNextRestockAtForBox(boxId: string): number
	return _nextRestockAtByBoxId[boxId] or _nextRestockAt
end

function ShopStockService.GetSecondsUntilRestockForBox(boxId: string): number
	local target = _nextRestockAtByBoxId[boxId] or _nextRestockAt
	return math.max(0, target - _clockFn())
end

function ShopStockService.GetNextRestockAt(): number
	return _nextRestockAt
end

function ShopStockService.GetLastRestockAt(): number
	return _lastRestockAt
end

function ShopStockService.GetRestockEpoch(): number
	return _restockEpoch
end

function ShopStockService.GetSecondsUntilRestock(): number
	return math.max(0, _nextRestockAt - _clockFn())
end

function ShopStockService.GetAllStockSnapshots(): { any }
	local now = _clockFn()
	local out: { any } = {}
	for _, boxDef in ipairs(LootBoxConfig.GetAllBoxes()) do
		local minQ, maxQ, intervalSec = LootBoxConfig.GetStockBounds(boxDef.BoxId)
		local currentStock = if boxDef.Enabled then (_stockByBoxId[boxDef.BoxId] or 0) else 0
		local nextBoxRestock = _nextRestockAtByBoxId[boxDef.BoxId] or _nextRestockAt
		local remSec = if boxDef.Enabled then math.max(0, nextBoxRestock - now) else 0
		local hasValidPool = LootBoxConfig.HasValidRewardPool(boxDef.BoxId)
		table.insert(out, {
			BoxId = boxDef.BoxId,
			DisplayName = boxDef.DisplayName,
			Description = boxDef.Description,
			Family = boxDef.Family,
			RewardCategory = boxDef.RewardCategory,
			ProgressionOrder = boxDef.ProgressionOrder,
			FamilyIcon = boxDef.FamilyIcon,
			IconId = boxDef.IconId,
			Price = boxDef.Price,
			DeliverySeconds = LootBoxConfig.GetDeliverySeconds(boxDef.BoxId),
			Enabled = boxDef.Enabled,
			DisabledReason = boxDef.DisabledReason,
			RewardPoolId = boxDef.RewardPoolId,
			HasValidRewardPool = hasValidPool,
			AssetSubfolder = boxDef.AssetSubfolder,
			ModelName = boxDef.ModelName,
			Stock = currentStock,
			CurrentStock = currentStock,
			RestockQuantity = boxDef.RestockQuantity,
			StockMin = minQ,
			StockMax = maxQ,
			RestockMin = minQ,
			RestockMax = maxQ,
			RestockIntervalSeconds = intervalSec,
			NextRestockAt = nextBoxRestock,
			SecondsUntilRestock = remSec,
			RarityWeights = boxDef.RarityWeights,
			SizeWeights = boxDef.SizeWeights,
		})
	end
	return out
end

function ShopStockService.TryReserveUnit(boxId: string): (boolean, string?, string?)
	if not _initialized then
		ShopStockService.Init()
	end
	local boxDef = LootBoxConfig.GetBox(boxId)
	if not boxDef then
		return false, ShopProtocol.ErrorCodes.UnknownBox, `Caja especial desconocida: '{tostring(boxId)}'.`
	end
	if not boxDef.Enabled then
		return false,
			ShopProtocol.ErrorCodes.BoxDisabled,
			boxDef.DisabledReason or `La caja '{boxDef.DisplayName}' no está habilitada.`
	end

	local current = _stockByBoxId[boxId] or 0
	if current <= 0 then
		local rem = math.ceil(ShopStockService.GetSecondsUntilRestockForBox(boxId))
		return false,
			ShopProtocol.ErrorCodes.OutOfStock,
			`No hay stock disponible de '{boxDef.DisplayName}'. Próxima reposición en {rem} s.`
	end

	-- Decremento síncrono atómico exclusivamente sobre esta BoxId antes de ceder ejecución en DataStore
	_stockByBoxId[boxId] = current - 1
	emitStockChanged("Reserved")
	return true, nil, nil
end

function ShopStockService.ReleaseUnit(boxId: string)
	local boxDef = LootBoxConfig.GetBox(boxId)
	if not boxDef or not boxDef.Enabled then
		return
	end
	_stockByBoxId[boxId] = (_stockByBoxId[boxId] or 0) + 1
	emitStockChanged("Released")
end

function ShopStockService.StepRestockCheck(): boolean
	if not _initialized then
		return false
	end
	local now = _clockFn()
	local restockedAny = false
	for _, boxDef in ipairs(LootBoxConfig.GetEnabledBoxes()) do
		local _, _, intervalSec = LootBoxConfig.GetStockBounds(boxDef.BoxId)
		local nextAt = _nextRestockAtByBoxId[boxDef.BoxId]
		if nextAt == nil or nextAt <= 0 then
			_nextRestockAtByBoxId[boxDef.BoxId] = now + intervalSec
		elseif now >= nextAt then
			_stockByBoxId[boxDef.BoxId] = drawRestockQty(boxDef)
			_lastRestockAtByBoxId[boxDef.BoxId] = now
			_nextRestockAtByBoxId[boxDef.BoxId] = now + intervalSec
			restockedAny = true
		end
	end
	if restockedAny then
		_lastRestockAt = now
		recomputeGlobalNextRestockAt(now)
		_restockEpoch += 1
		emitStockChanged("ScheduledRestock")
		return true
	end
	recomputeGlobalNextRestockAt(now)
	return false
end

function ShopStockService.RegisterStockChangedListener(listener: (reason: string) -> ()): () -> ()
	table.insert(_stockChangedListeners, listener)
	return function()
		local idx = table.find(_stockChangedListeners, listener)
		if idx then
			table.remove(_stockChangedListeners, idx)
		end
	end
end

function ShopStockService.SyncWithEffectiveConfig(reason: string?)
	local now = _clockFn()
	local changed = false
	for _, boxDef in ipairs(LootBoxConfig.GetAllBoxes()) do
		if not boxDef.Enabled then
			if (_stockByBoxId[boxDef.BoxId] or 0) ~= 0 then
				_stockByBoxId[boxDef.BoxId] = 0
				changed = true
			end
			_nextRestockAtByBoxId[boxDef.BoxId] = 0
		else
			local minQ, maxQ, intervalSec = LootBoxConfig.GetStockBounds(boxDef.BoxId)
			if _nextRestockAtByBoxId[boxDef.BoxId] == nil or _nextRestockAtByBoxId[boxDef.BoxId] <= 0 then
				_stockByBoxId[boxDef.BoxId] = drawRestockQty(boxDef)
				_lastRestockAtByBoxId[boxDef.BoxId] = now
				_nextRestockAtByBoxId[boxDef.BoxId] = now + intervalSec
				changed = true
			else
				-- Ajustar tope de restock o fecha si disminuyó el intervalo sin alterar disponibilidad válida actual
				if _stockByBoxId[boxDef.BoxId] == nil then
					_stockByBoxId[boxDef.BoxId] = drawRestockQty(boxDef)
					changed = true
				elseif (_stockByBoxId[boxDef.BoxId] or 0) > maxQ then
					_stockByBoxId[boxDef.BoxId] = maxQ
					changed = true
				elseif (_stockByBoxId[boxDef.BoxId] or 0) < 0 then
					_stockByBoxId[boxDef.BoxId] = minQ
					changed = true
				end
				if _nextRestockAtByBoxId[boxDef.BoxId] > now + intervalSec then
					_nextRestockAtByBoxId[boxDef.BoxId] = now + intervalSec
				end
			end
		end
	end
	recomputeGlobalNextRestockAt(now)
	if changed or reason ~= nil then
		_restockEpoch += 1
		emitStockChanged(reason or "ConfigReloaded")
	end
end

function ShopStockService._SetClockForTests(clockFn: (() -> number)?)
	_clockFn = clockFn or os.time
end

function ShopStockService._SetRngForTests(rngFn: ((min: number, max: number, boxId: string) -> number)?)
	_rngOverride = rngFn
end

function ShopStockService._SetStockForTests(boxId: string, amount: number)
	_stockByBoxId[boxId] = math.max(0, math.floor(amount))
	local boxDef = LootBoxConfig.GetBox(boxId)
	if boxDef and boxDef.Enabled and _nextRestockAtByBoxId[boxId] == nil then
		local now = _clockFn()
		local _, _, intervalSec = LootBoxConfig.GetStockBounds(boxId)
		_nextRestockAtByBoxId[boxId] = now + intervalSec
		recomputeGlobalNextRestockAt(now)
	end
	emitStockChanged("TestOverride")
end

function ShopStockService._ResetForTests()
	if _heartbeatConn then
		_heartbeatConn:Disconnect()
		_heartbeatConn = nil
	end
	table.clear(_stockByBoxId)
	table.clear(_nextRestockAtByBoxId)
	table.clear(_lastRestockAtByBoxId)
	table.clear(_stockChangedListeners)
	_clockFn = os.time
	_rngOverride = nil
	_nextRestockAt = 0
	_lastRestockAt = 0
	_restockEpoch = 0
	_accumCheck = 0
	_initialized = false
	_started = false
end

function ShopStockService.Init()
	if _initialized then
		return
	end
	_initialized = true
	ShopStockService.ExecuteRestock("InitialServerBoot")
end

function ShopStockService.Start()
	if not _initialized then
		ShopStockService.Init()
	end
	if _started then
		return
	end
	_started = true

	if _heartbeatConn then
		_heartbeatConn:Disconnect()
	end
	_heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
		_accumCheck += dt
		if _accumCheck >= 0.5 then
			_accumCheck = 0
			ShopStockService.StepRestockCheck()
		end
	end)
end

return ShopStockService
