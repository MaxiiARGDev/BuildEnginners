--!strict
--[=[
	OfflineIncomeService
	Generación pasiva de monedas offline basada únicamente en motores únicos poseídos (Fase 5.2).

	Reglas críticas:
	- Únicamente los motores generan dinero pasivo (propulsores y piezas comunes no generan).
	- Deduplica estrictamente por ItemInstanceId de InventoryService: un motor referenciado en
	  taller + Slot 1 + Slot 2 + Slot 3 cuenta UNA sola vez.
	- Persiste timestamps y ganancia pendiente dentro de EconomyService (mismo DataStore) para evitar
	  duplicaciones entre DataStores independientes ante fallos o reconexiones rápidas.
	- Recoger normal: acredita saldo x1 y limpia pendiente atómicamente.
	- Recoger x5: usa integración oficial con AdService (RewardedVideo) + ProcessReceipt (ProductPurchaseChannel.AdReward).
	  Nunca confía en confirmaciones enviadas únicamente desde cliente; si AdService no está disponible
	  o no completó, mantiene el reclamo normal intacto y devuelve fallo controlado.
	- Tasas configuradas en ShopConfig.OfflineIncome marcadas explícitamente PROVISIONAL_TBD.
]=]

local AdService = game:GetService("AdService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local EconomyService = require(ServerScriptService.Server.Services.EconomyService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)

export type PlayerLike = EconomyService.PlayerLike

export type AdServiceAdapter = {
	ShowRewardedVideoAd: (player: PlayerLike, devProductId: number, placementId: number?) -> (boolean, string?),
}

local OfflineIncomeService = {
	Name = "OfflineIncomeService",
}

local _initialized = false
local _started = false
local _clockFn: () -> number = os.time
local _adAdapterOverride: AdServiceAdapter? = nil
local _claimingLockByUserId: { [number]: boolean } = {}
local _claimListeners: { (userId: number, amount: number, multiplier: number) -> () } = {}

local function extractUserId(playerOrUserId: PlayerLike | number): number
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return playerOrUserId.UserId
	elseif type(playerOrUserId) == "table" and type((playerOrUserId :: any).UserId) == "number" then
		return (playerOrUserId :: any).UserId
	end
	error("[OfflineIncomeService] Jugador inválido", 3)
end

local function emitClaimed(userId: number, amount: number, mult: number)
	for _, cb in ipairs(table.clone(_claimListeners)) do
		task.spawn(cb, userId, amount, mult)
	end
end

function OfflineIncomeService.GetPendingSnapshot(playerOrUserId: PlayerLike | number): {
	PendingAmount: number,
	PendingSeconds: number,
	MultiplierAvailable: boolean,
	RewardedAdMultiplier: number,
	AdConfigured: boolean,
	BalanceStatus: string,
	Breakdown: { { UnitId: string, Label: string, HourlyRate: number, Earned: number } },
}
	local snap = EconomyService.GetSnapshotCopy(playerOrUserId)
	local amount = if snap then snap.PendingOfflineAmount else 0
	local seconds = if snap then snap.PendingOfflineSeconds else 0
	local breakdown = if snap then snap.PendingOfflineBreakdown else {}
	local adConfigured = ShopConfig.OfflineIncome.RewardedAdDevProductId > 0
	return {
		PendingAmount = amount,
		PendingSeconds = seconds,
		MultiplierAvailable = adConfigured or (_adAdapterOverride ~= nil),
		RewardedAdMultiplier = ShopConfig.OfflineIncome.RewardedAdMultiplier,
		AdConfigured = adConfigured,
		BalanceStatus = ShopConfig.OfflineIncome.BalanceStatus,
		Breakdown = breakdown,
	}
end

function OfflineIncomeService.ProcessJoinOfflineIncome(
	playerOrUserId: PlayerLike | number
): (boolean, number, string?, string?)
	if not _initialized then
		OfflineIncomeService.Init()
	end
	local userId = extractUserId(playerOrUserId)
	local okInv = InventoryService.EnsurePlayerLoaded(userId)
	local okEco, ecoSnap, ecoCode, ecoMsg = EconomyService.EnsurePlayerLoaded(userId)
	if not okInv or not okEco or not ecoSnap then
		return false, 0, ecoCode or ShopProtocol.ErrorCodes.PersistenceFailed, ecoMsg or "No se pudo cargar datos offline."
	end

	if not ShopConfig.OfflineIncome.Enabled then
		return true, ecoSnap.PendingOfflineAmount, nil, nil
	end

	local now = _clockFn()
	local lastSeen = ecoSnap.LastSeenAt
	local elapsed = math.clamp(now - lastSeen, 0, ShopConfig.OfflineIncome.MaxAccumulationSeconds)

	-- Deduplicación estricta por ItemInstanceId de unidades únicas de motores
	local engineUnits = InventoryService.GetPlayerEngineUnits(userId)
	local seenUnitIds: { [string]: boolean } = {}
	local breakdownAdditions: { [string]: { UnitId: string, Label: string, HourlyRate: number, Earned: number } } = {}
	local rawNewCoins = 0

	if elapsed >= ShopConfig.OfflineIncome.MinOfflineSeconds then
		for _, unit in ipairs(engineUnits) do
			if unit and type(unit.ItemInstanceId) == "string" and not seenUnitIds[unit.ItemInstanceId] then
				seenUnitIds[unit.ItemInstanceId] = true
				local hourly = ShopConfig.ComputeEngineOfflineHourlyRate(unit.EngineSizeId, unit.RarityId)
				local earnedRaw = ShopConfig.ComputeOfflineCoinsForEngine(unit.EngineSizeId, unit.RarityId, elapsed)
				rawNewCoins += earnedRaw
				local label = if unit.EffectiveStats and type(unit.EffectiveStats.FullLabel) == "string"
					then unit.EffectiveStats.FullLabel
					else unit.ItemId
				breakdownAdditions[unit.ItemInstanceId] = {
					UnitId = unit.ItemInstanceId,
					Label = label,
					HourlyRate = math.round(hourly * 100) / 100,
					Earned = math.floor(earnedRaw),
				}
			end
		end
	end

	local newEarnedInt = math.floor(rawNewCoins)
	local okSave, updatedSnap, saveCode, saveMsg = EconomyService.MutateEconomyRecord(userId, function(draft)
		-- Avanzar siempre LastSeenAt para que este intervalo no vuelva a calcularse dos veces
		draft.LastSeenAt = now
		if newEarnedInt > 0 then
			draft.PendingOfflineAmount += newEarnedInt
			draft.PendingOfflineSeconds += elapsed
			local byUnitId: { [string]: { UnitId: string, Label: string, HourlyRate: number, Earned: number } } = {}
			for _, existing in ipairs(draft.PendingOfflineBreakdown) do
				byUnitId[existing.UnitId] = existing
			end
			for unitId, addEntry in pairs(breakdownAdditions) do
				if byUnitId[unitId] then
					byUnitId[unitId].Earned += addEntry.Earned
					byUnitId[unitId].HourlyRate = addEntry.HourlyRate
				else
					table.insert(draft.PendingOfflineBreakdown, addEntry)
				end
			end
		end
		return true, nil, nil
	end, "OfflineAccrual")

	if not okSave or not updatedSnap then
		return false, 0, saveCode or ShopProtocol.ErrorCodes.PersistenceFailed, saveMsg
	end

	return true, updatedSnap.PendingOfflineAmount, nil, nil
end

function OfflineIncomeService.MarkPlayerActiveCheckpoint(playerOrUserId: PlayerLike | number): boolean
	local userId = extractUserId(playerOrUserId)
	local ok = EconomyService.MutateEconomyRecord(userId, function(draft)
		draft.LastSeenAt = _clockFn()
		return true, nil, nil
	end, "Checkpoint")
	return ok
end

function OfflineIncomeService.CompleteOfflineClaim(
	playerOrUserId: PlayerLike | number,
	multiplier: number,
	receiptId: string?,
	txId: string?
): (boolean, number?, number?, string?, string?)
	local userId = extractUserId(playerOrUserId)
	local mult = math.max(1, math.floor(multiplier))
	local creditedAmount = 0

	local okSave, updated, errCode, errMsg = EconomyService.MutateEconomyRecord(userId, function(draft)
		if type(receiptId) == "string" and #receiptId > 0 and table.find(draft.ProcessedReceiptIds, receiptId) ~= nil then
			return true, nil, nil
		end
		if type(txId) == "string" and #txId > 0 and table.find(draft.ProcessedTxIds, txId) ~= nil then
			return true, nil, nil
		end
		if draft.PendingOfflineAmount <= 0 then
			return false,
				ShopProtocol.ErrorCodes.NoPendingOfflineIncome,
				"No tenés ganancias offline pendientes por recoger."
		end

		creditedAmount = math.floor(draft.PendingOfflineAmount * mult)
		draft.Balance += creditedAmount
		draft.PendingOfflineAmount = 0
		draft.PendingOfflineSeconds = 0
		draft.PendingOfflineBreakdown = {}
		draft.LastSeenAt = _clockFn()
		if type(receiptId) == "string" and #receiptId > 0 then
			table.insert(draft.ProcessedReceiptIds, receiptId)
		end
		if type(txId) == "string" and #txId > 0 then
			table.insert(draft.ProcessedTxIds, txId)
		end
		return true, nil, nil
	end, if mult > 1 then "OfflineIncomeAd5x" else "OfflineIncomeClaim")

	if not okSave or not updated then
		return false, nil, nil, errCode, errMsg
	end

	if creditedAmount > 0 then
		emitClaimed(userId, creditedAmount, mult)
	end
	return true, creditedAmount, updated.Balance, nil, nil
end

function OfflineIncomeService.ClaimOfflineIncome(
	player: PlayerLike,
	useRewardedAd: boolean?,
	clientOpId: string?
): (boolean, number?, number?, string?, string?)
	local userId = extractUserId(player)
	if _claimingLockByUserId[userId] then
		return false, nil, nil, ShopProtocol.ErrorCodes.ConcurrentOperation, "Reclamo de ganancias en progreso."
	end
	_claimingLockByUserId[userId] = true

	local function finish(ok: boolean, claimed: number?, newBal: number?, code: string?, msg: string?): (boolean, number?, number?, string?, string?)
		_claimingLockByUserId[userId] = nil
		return ok, claimed, newBal, code, msg
	end

	local snap = EconomyService.GetSnapshotCopy(userId)
	if not snap or snap.PendingOfflineAmount <= 0 then
		return finish(false, nil, nil, ShopProtocol.ErrorCodes.NoPendingOfflineIncome, "No tenés ganancias offline pendientes.")
	end

	if useRewardedAd ~= true then
		local ok, claimed, bal, code, msg = OfflineIncomeService.CompleteOfflineClaim(userId, 1, nil, clientOpId)
		return finish(ok, claimed, bal, code, msg)
	end

	local devProductId = ShopConfig.OfflineIncome.RewardedAdDevProductId
	if _adAdapterOverride then
		local adOk, adErr = _adAdapterOverride.ShowRewardedVideoAd(player, devProductId, ShopConfig.OfflineIncome.RewardedAdPlacementId)
		if not adOk then
			return finish(false, nil, nil, ShopProtocol.ErrorCodes.RewardedAdNotAvailable, adErr or "Anuncio recompensado no disponible.")
		end
		-- En flujo de adaptador custom/test: el adaptador o ProcessReceipt completa la acreditación
		local afterSnap = EconomyService.GetSnapshotCopy(userId)
		if afterSnap and afterSnap.PendingOfflineAmount == 0 then
			return finish(true, snap.PendingOfflineAmount * ShopConfig.OfflineIncome.RewardedAdMultiplier, afterSnap.Balance, nil, nil)
		end
		return finish(false, nil, nil, ShopProtocol.ErrorCodes.RewardedAdFailed, "Esperando confirmación de ProcessReceipt del anuncio.")
	end

	if devProductId <= 0 then
		return finish(
			false,
			nil,
			nil,
			ShopProtocol.ErrorCodes.RewardedAdNotAvailable,
			"La publicidad recompensada ×5 aún no tiene un Developer Product configurado; podés usar el reclamo normal."
		)
	end

	if typeof(player) ~= "Instance" or not (player :: Instance):IsA("Player") then
		return finish(false, nil, nil, ShopProtocol.ErrorCodes.RewardedAdNotAvailable, "AdService requiere un Player real en línea.")
	end

	local okShow, showRes = pcall(function()
		local reward = AdService:CreateAdRewardFromDevProductId(devProductId)
		return AdService:ShowRewardedVideoAdAsync(player :: Player, reward, ShopConfig.OfflineIncome.RewardedAdPlacementId)
	end)
	if not okShow then
		return finish(
			false,
			nil,
			nil,
			ShopProtocol.ErrorCodes.RewardedAdNotAvailable,
			`Anuncio recompensado no disponible ahora: {tostring(showRes)}`
		)
	end

	if showRes ~= Enum.ShowAdResult.ShowCompleted then
		return finish(
			false,
			nil,
			nil,
			ShopProtocol.ErrorCodes.RewardedAdFailed,
			`El anuncio no se completó ({tostring(showRes)}). Podés reclamar tu monto normal.`
		)
	end

	-- Nota oficial Roblox AdService: la recompensa autoritativa se otorga dentro de MarketplaceService.ProcessReceipt
	-- (ProductPurchaseChannel.AdReward). Solo reflejamos aquí el estado actualizado tras la concesión del receipt.
	local deadline = os.clock() + 3.0
	while os.clock() < deadline do
		local latest = EconomyService.GetSnapshotCopy(userId)
		if latest and latest.PendingOfflineAmount == 0 then
			return finish(true, snap.PendingOfflineAmount * ShopConfig.OfflineIncome.RewardedAdMultiplier, latest.Balance, nil, nil)
		end
		if not RunService:IsRunning() then
			break
		end
		task.wait(0.1)
	end

	return finish(
		false,
		nil,
		nil,
		ShopProtocol.ErrorCodes.RewardedAdFailed,
		"La recompensa ×5 está pendiente de confirmación oficial de Roblox (ProcessReceipt)."
	)
end

function OfflineIncomeService.RegisterClaimedListener(cb: (userId: number, amount: number, mult: number) -> ()): () -> ()
	table.insert(_claimListeners, cb)
	return function()
		local idx = table.find(_claimListeners, cb)
		if idx then
			table.remove(_claimListeners, idx)
		end
	end
end

function OfflineIncomeService._SetClockForTests(clockFn: (() -> number)?)
	_clockFn = clockFn or os.time
end

function OfflineIncomeService._SetAdServiceAdapterForTests(adapter: AdServiceAdapter?)
	_adAdapterOverride = adapter
end

function OfflineIncomeService._ResetForTests()
	table.clear(_claimingLockByUserId)
	table.clear(_claimListeners)
	_clockFn = os.time
	_adAdapterOverride = nil
end

function OfflineIncomeService.Init()
	if _initialized then
		return
	end
	_initialized = true
	EconomyService.Init()
	InventoryService.Init()
end

function OfflineIncomeService.Start()
	if not _initialized then
		OfflineIncomeService.Init()
	end
	if _started then
		return
	end
	_started = true
end

return OfflineIncomeService

