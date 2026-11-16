--!strict
--[=[
	ShopService
	Orquestador autoritativo de Tienda Física en ShopZone, Carrito, Cajas Especiales,
	Stock compartido, Pedidos (60 s / 900 s), Aceleración con Robux (ProcessReceipt)
	y Ganancias Offline (Fase 5.2).
]=]

local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local DeliveryService = require(ServerScriptService.Server.Services.DeliveryService)
local EconomyService = require(ServerScriptService.Server.Services.EconomyService)
local GameConfigService = require(ServerScriptService.Server.Services.GameConfigService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local OfflineIncomeService = require(ServerScriptService.Server.Services.OfflineIncomeService)
local PlotService = require(ServerScriptService.Server.Services.PlotService)
local ShopStockService = require(ServerScriptService.Server.Services.ShopStockService)

local SecurityFolder = ServerScriptService.Server:WaitForChild("Security")
local TokenBucket = require(SecurityFolder:WaitForChild("TokenBucket") :: ModuleScript)

export type PlayerLike = PlotService.PlayerLike

local ShopService = {
	Name = "ShopService",
}

local _initialized = false
local _started = false
local _clockFn: () -> number = os.time

local _remoteFunction: RemoteFunction? = nil
local _syncEvent: RemoteEvent? = nil
local _rateLimiter = TokenBucket.Create({
	WriteCapacity = 25,
	WriteRefillPerSecond = 8,
	ReadCapacity = 15,
	ReadRefillPerSecond = 6,
})
local _userOpLocks: { [number]: boolean } = {}
local _processedOpsByUserId: { [number]: { [string]: ShopProtocol.ShopOperationResponse } } = {}
local _connections: { RBXScriptConnection } = {}
local _unsubs: { () -> () } = {}

local function extractUserId(playerOrUserId: PlayerLike | number): number
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return playerOrUserId.UserId
	elseif type(playerOrUserId) == "table" and type((playerOrUserId :: any).UserId) == "number" then
		return (playerOrUserId :: any).UserId
	end
	error("[ShopService] Jugador inválido", 3)
end

local function makeOpId(prefix: string): string
	return prefix .. string.lower(string.gsub(HttpService:GenerateGUID(false), "-", "")):sub(1, 14)
end

local function ensureRemotes(): (RemoteFunction, RemoteEvent)
	local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
	local remotesFolder = sharedFolder:FindFirstChild("Remotes")
	if not remotesFolder then
		local folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = sharedFolder
		remotesFolder = folder
	end

	local rf = remotesFolder:FindFirstChild(ShopProtocol.RemoteFunctionName) :: RemoteFunction?
	if not rf then
		local newRf = Instance.new("RemoteFunction")
		newRf.Name = ShopProtocol.RemoteFunctionName
		newRf.Parent = remotesFolder
		rf = newRf
	end

	local ev = remotesFolder:FindFirstChild(ShopProtocol.SyncEventName) :: RemoteEvent?
	if not ev then
		local newEv = Instance.new("RemoteEvent")
		newEv.Name = ShopProtocol.SyncEventName
		newEv.Parent = remotesFolder
		ev = newEv
	end

	_remoteFunction = rf
	_syncEvent = ev
	return rf :: RemoteFunction, ev :: RemoteEvent
end

local function checkRateLimit(userId: number, isWrite: boolean): boolean
	local ok = _rateLimiter:Consume(userId, if isWrite then "Write" else "Read", 1)
	return ok
end

local function makeError(clientOpId: string?, errorCode: string, message: string): ShopProtocol.ShopOperationResponse
	return {
		Success = false,
		ClientOpId = clientOpId,
		ErrorCode = errorCode,
		ErrorMessage = message,
	}
end

local function fireSyncToUser(userId: number, eventType: string, payload: { [string]: any })
	if not _syncEvent then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end
	payload.EventType = eventType
	payload.ServerNow = _clockFn()
	_syncEvent:FireClient(player, payload)
end

local function broadcastStockSync(reason: string)
	if not _syncEvent then
		return
	end
	local payload = {
		EventType = ShopProtocol.SyncEventTypes.StockUpdated,
		Reason = reason,
		ServerNow = _clockFn(),
		NextRestockAt = ShopStockService.GetNextRestockAt(),
		SecondsUntilRestock = ShopStockService.GetSecondsUntilRestock(),
		RestockEpoch = ShopStockService.GetRestockEpoch(),
		CrateConfigRevision = GameConfigService.GetRevision("Crates"),
		CrateConfigOverrides = LootBoxConfig.ExportEffectiveOverrides(),
		SpecialBoxes = ShopStockService.GetAllStockSnapshots(),
	}
	_syncEvent:FireAllClients(payload)
end

function ShopService.BuildPlayerShopSnapshot(playerOrUserId: PlayerLike | number): ({ [string]: any }?, string?, string?)
	local userId = extractUserId(playerOrUserId)
	local okEco, ecoSnap, ecoCode, ecoMsg = EconomyService.EnsurePlayerLoaded(userId)
	if not okEco or not ecoSnap then
		return nil, ecoCode or ShopProtocol.ErrorCodes.PersistenceFailed, ecoMsg
	end
	local okInv, _, invCode, invMsg = InventoryService.EnsurePlayerLoaded(userId)
	if not okInv then
		return nil, invCode or ShopProtocol.ErrorCodes.PersistenceFailed, invMsg
	end
	local okOrd, _, ordCode, ordMsg = DeliveryService.EnsurePlayerLoaded(userId)
	if not okOrd then
		return nil, ordCode or ShopProtocol.ErrorCodes.PersistenceFailed, ordMsg
	end

	local normalItems = {}
	for _, entry in ipairs(ItemCatalog.GetPurchasableShopItems()) do
		local pendingQty = DeliveryService.GetPendingNormalQuantityForItem(userId, entry.Id)
		local ownedQty = InventoryService.GetOwnedQuantity(userId, entry.Id)
		table.insert(normalItems, {
			ItemId = entry.Id,
			DisplayName = entry.DisplayName,
			Description = entry.Description,
			Category = entry.Category,
			CategoryDisplayName = entry.CategoryDisplayName,
			AssetFolder = entry.AssetFolder,
			Price = entry.Price,
			SellPrice = entry.SellPrice,
			OwnedQuantity = ownedQty,
			PendingDeliveryQuantity = pendingQty,
			MaxOwnedPerPlayer = nil,
			Stats = entry.Stats,
		})
	end

	local ordersSnap = DeliveryService.GetPlayerOrdersSnapshot(userId)
	local offlineSnap = OfflineIncomeService.GetPendingSnapshot(userId)
	local invSnap = InventoryService.GetPlayerSnapshot(userId)

	return {
		OwnerUserId = userId,
		ServerNow = _clockFn(),
		Balance = ecoSnap.Balance,
		CurrencyName = ShopConfig.Economy.CurrencyName,
		CurrencySymbol = ShopConfig.Economy.CurrencySymbol,
		NormalOrderWaitSeconds = ShopConfig.Orders.NormalOrderWaitSeconds,
		SpecialOrderWaitSeconds = ShopConfig.Orders.SpecialOrderWaitSeconds,
		RestockIntervalSeconds = ShopConfig.Orders.RestockIntervalSeconds,
		RobuxSpeedupArrivalSeconds = ShopConfig.Orders.RobuxSpeedupArrivalSeconds,
		NextRestockAt = ShopStockService.GetNextRestockAt(),
		SecondsUntilRestock = ShopStockService.GetSecondsUntilRestock(),
		RestockEpoch = ShopStockService.GetRestockEpoch(),
		CrateConfigRevision = GameConfigService.GetRevision("Crates"),
		CrateConfigOverrides = LootBoxConfig.ExportEffectiveOverrides(),
		RobuxProducts = {
			RushNormalOrderProductId = ShopConfig.RobuxProducts.RushNormalOrderProductId,
			RushSpecialOrderProductId = ShopConfig.RobuxProducts.RushSpecialOrderProductId,
		},
		NormalItems = normalItems,
		SpecialBoxes = ShopStockService.GetAllStockSnapshots(),
		Orders = ordersSnap,
		OfflineIncome = offlineSnap,
		Inventory = invSnap,
	}, nil, nil
end

local function syncFullOrdersAndInventory(userId: number, reason: string?)
	local snap = ShopService.BuildPlayerShopSnapshot(userId)
	if snap then
		fireSyncToUser(userId, ShopProtocol.SyncEventTypes.OrdersUpdated, {
			Reason = reason or "Sync",
			ShopSnapshot = snap,
		})
	end
end

local function spawnShopCounterForPlot(player: PlayerLike, plot: PlotService.PlotRecord)
	local container = plot.ShopDeliveryContainer
	if not container or not container.Parent then
		return
	end
	local existing = container:FindFirstChild("ShopCounterInstance")
	if existing then
		existing:Destroy()
	end

	local cratesRoot = ServerStorage:FindFirstChild(ShopConfig.Assets.CratesRootFolder)
	local deliveryFolder = cratesRoot and cratesRoot:FindFirstChild(ShopConfig.Assets.DeliveryFolder)
	local template = (deliveryFolder and deliveryFolder:FindFirstChild(ShopConfig.Assets.ShopCounterModel))
		or (cratesRoot and cratesRoot:FindFirstChild(ShopConfig.Assets.ShopCounterModel, true))

	local counter: Model
	if template and template:IsA("Model") then
		counter = template:Clone()
	else
		counter = Instance.new("Model")
		local basePart = Instance.new("Part")
		basePart.Name = "Primary"
		basePart.Size = Vector3.new(6, 2.8, 2.4)
		basePart.Anchored = true
		basePart.Color = Color3.fromRGB(46, 56, 76)
		basePart.Parent = counter
		counter.PrimaryPart = basePart
	end

	counter.Name = "ShopCounterInstance"
	local firstPart: BasePart? = counter.PrimaryPart
	for _, d in ipairs(counter:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Seat") or d:IsA("VehicleSeat") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			if not firstPart or d.Name == "Primary" then
				firstPart = d
			end
		end
	end
	if not counter.PrimaryPart and firstPart then
		counter.PrimaryPart = firstPart
	end

	local prim = counter.PrimaryPart :: BasePart
	local shopZone = plot.Zones.ShopZone
	local targetCF = shopZone.CFrame * CFrame.new(0, shopZone.Size.Y * 0.5 + prim.Size.Y * 0.5, 0)
	local pivotToPrim = counter:GetPivot():ToObjectSpace(prim.CFrame)
	counter:PivotTo(targetCF * pivotToPrim:Inverse())

	local promptTarget = counter:FindFirstChild("PromptAnchor", true)
	local promptParent: Instance = if promptTarget and (promptTarget:IsA("Attachment") or promptTarget:IsA("BasePart"))
		then promptTarget
		else prim

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "OpenShopPrompt"
	prompt.ObjectText = "Tienda de Componentes y Cajas"
	prompt.ActionText = "Abrir Tienda"
	prompt.MaxActivationDistance = ShopConfig.DeliveryZone.ShopPromptMaxDistance
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0
	prompt.Parent = promptParent

	local ownerUserId = player.UserId
	prompt.Triggered:Connect(function(triggerPlayer: Player)
		if triggerPlayer.UserId ~= ownerUserId then
			return
		end
		local snap = ShopService.BuildPlayerShopSnapshot(triggerPlayer)
		if snap then
			fireSyncToUser(ownerUserId, ShopProtocol.SyncEventTypes.Snapshot, {
				OpenShopUi = true,
				ShopSnapshot = snap,
			})
		end
	end)

	counter.Parent = container
end

local function checkoutNormalCart(
	player: PlayerLike,
	req: ShopProtocol.ShopRequestPayload
): ShopProtocol.ShopOperationResponse
	local userId = extractUserId(player)
	if type(req.CartItems) ~= "table" or #req.CartItems == 0 then
		return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.InvalidPayload, "El carrito está vacío.")
	end
	if #req.CartItems > ShopConfig.Orders.MaxCartLines then
		return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.InvalidPayload, "El carrito excede el máximo de líneas.")
	end

	local okLoad, _, loadCode, loadMsg = EconomyService.EnsurePlayerLoaded(userId)
	if not okLoad then
		return makeError(req.ClientOpId, loadCode or ShopProtocol.ErrorCodes.PersistenceFailed, loadMsg or "Error de economía.")
	end
	local okOrdLoad, _, ordCode, ordMsg = DeliveryService.EnsurePlayerLoaded(userId)
	if not okOrdLoad then
		return makeError(req.ClientOpId, ordCode or ShopProtocol.ErrorCodes.PersistenceFailed, ordMsg or "Error de pedidos.")
	end
	local okInvLoad, _, invCode, invMsg = InventoryService.EnsurePlayerLoaded(userId)
	if not okInvLoad then
		return makeError(req.ClientOpId, invCode or ShopProtocol.ErrorCodes.PersistenceFailed, invMsg or "Error de inventario.")
	end

	if DeliveryService.IsNormalOrderInProgress(userId) then
		return makeError(
			req.ClientOpId,
			ShopProtocol.ErrorCodes.NormalOrderInProgress,
			"Ya tenés un pedido normal en camino (60 s). Esperá a que llegue para volver a comprar piezas normales."
		)
	end

	-- Consolidar por ItemId para garantizar exactamente UNA caja física por tipo de componente
	local qtyByItemId: { [string]: number } = {}
	local orderedItemIds: { string } = {}
	for _, rawLine in ipairs(req.CartItems) do
		if type(rawLine) ~= "table" or type(rawLine.ItemId) ~= "string" then
			return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.InvalidPayload, "Línea de carrito inválida.")
		end
		local q = rawLine.Quantity
		if type(q) ~= "number" or q ~= q or q == math.huge or q < 1 or q > ShopConfig.Orders.MaxQuantityPerLine or q % 1 ~= 0 then
			return makeError(
				req.ClientOpId,
				ShopProtocol.ErrorCodes.InvalidPayload,
				`Cantidad inválida para '{rawLine.ItemId}'.`
			)
		end
		if qtyByItemId[rawLine.ItemId] == nil then
			qtyByItemId[rawLine.ItemId] = 0
			table.insert(orderedItemIds, rawLine.ItemId)
		end
		qtyByItemId[rawLine.ItemId] += math.floor(q)
	end

	local lines: { ItemTypes.NormalOrderLine } = table.create(#orderedItemIds)
	local totalCost = 0
	for _, itemId in ipairs(orderedItemIds) do
		local qty = qtyByItemId[itemId]
		local entry = ItemCatalog.GetEntry(itemId)
		if not entry then
			return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.UnknownItem, `Objeto desconocido: '{itemId}'.`)
		end
		if not entry.DirectPurchasable or type(entry.Price) ~= "number" then
			return makeError(
				req.ClientOpId,
				ShopProtocol.ErrorCodes.ItemNotShopPurchasable,
				`'{entry.DisplayName}' no se compra directamente; obtenelo mediante cajas especiales.`
			)
		end
		if qty < 1 or qty > ShopConfig.Orders.MaxQuantityPerLine or qty % 1 ~= 0 then
			return makeError(
				req.ClientOpId,
				ShopProtocol.ErrorCodes.InvalidPayload,
				`Cantidad total inválida para '{entry.DisplayName}'.`
			)
		end

		local unitPrice = math.floor(entry.Price)
		local lineTotal = unitPrice * qty
		totalCost += lineTotal
		table.insert(lines, {
			ItemId = itemId,
			Quantity = qty,
			UnitPrice = unitPrice,
			LineTotal = lineTotal,
		})
	end

	local txId = req.ClientOpId or makeOpId("ncart_")
	local okDebit, newBal, debitCode, debitMsg = EconomyService.TryDebit(userId, totalCost, "NormalCartCheckout", txId)
	if not okDebit then
		return makeError(req.ClientOpId, debitCode or ShopProtocol.ErrorCodes.InsufficientFunds, debitMsg or "Saldo insuficiente.")
	end

	local okOrder, orderRec, orderErrCode, orderErrMsg = DeliveryService.CreateNormalOrder(userId, lines, totalCost, txId)
	if not okOrder or not orderRec then
		-- Rollback monetario completo si falló persistir el pedido
		EconomyService.Credit(userId, totalCost, "NormalCartOrderRollback", `rb_{txId}`, nil)
		return makeError(
			req.ClientOpId,
			orderErrCode or ShopProtocol.ErrorCodes.PersistenceFailed,
			orderErrMsg or "Error al registrar tu pedido."
		)
	end

	local snap = ShopService.BuildPlayerShopSnapshot(userId)
	return {
		Success = true,
		ClientOpId = req.ClientOpId,
		NewBalance = newBal,
		Order = orderRec,
		ShopSnapshot = snap,
	}
end

local function purchaseSpecialCrate(
	player: PlayerLike,
	req: ShopProtocol.ShopRequestPayload
): ShopProtocol.ShopOperationResponse
	local userId = extractUserId(player)
	local boxId = req.BoxId
	if type(boxId) ~= "string" or #boxId == 0 then
		return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.InvalidPayload, "Debes indicar BoxId.")
	end

	local boxDef = LootBoxConfig.GetBox(boxId)
	if not boxDef then
		return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.UnknownBox, `Caja especial desconocida: '{boxId}'.`)
	end
	if not boxDef.Enabled or type(boxDef.Price) ~= "number" or boxDef.Price <= 0 then
		return makeError(
			req.ClientOpId,
			ShopProtocol.ErrorCodes.BoxDisabled,
			boxDef.DisabledReason or `'{boxDef.DisplayName}' estará disponible próximamente.`
		)
	end
	local poolOk, poolErr = LootBoxConfig.ValidateBoxPool(boxId)
	if not poolOk then
		return makeError(
			req.ClientOpId,
			ShopProtocol.ErrorCodes.BoxDisabled,
			boxDef.DisabledReason or `'{boxDef.DisplayName}' aún no tiene pool de recompensas válido ({tostring(poolErr)}).`
		)
	end

	local okEco, _, ecoCode, ecoMsg = EconomyService.EnsurePlayerLoaded(userId)
	if not okEco then
		return makeError(req.ClientOpId, ecoCode or ShopProtocol.ErrorCodes.PersistenceFailed, ecoMsg or "Error de economía.")
	end
	local okOrdLoad, _, ordCode, ordMsg = DeliveryService.EnsurePlayerLoaded(userId)
	if not okOrdLoad then
		return makeError(req.ClientOpId, ordCode or ShopProtocol.ErrorCodes.PersistenceFailed, ordMsg or "Error de pedidos.")
	end

	local price = math.floor(boxDef.Price)
	if not EconomyService.CanAfford(userId, price) then
		local curBal = EconomyService.GetBalance(userId)
		return makeError(
			req.ClientOpId,
			ShopProtocol.ErrorCodes.InsufficientFunds,
			`Saldo insuficiente para '{boxDef.DisplayName}': cuesta ${price} y tenés ${curBal}.`
		)
	end

	-- Reserva atómica síncrona del stock compartido antes de ceder en DataStore
	local okStock, stockCode, stockMsg = ShopStockService.TryReserveUnit(boxId)
	if not okStock then
		return makeError(req.ClientOpId, stockCode or ShopProtocol.ErrorCodes.OutOfStock, stockMsg or "Sin stock disponible.")
	end

	local txId = req.ClientOpId or makeOpId("scrate_")
	local okDebit, newBal, debitCode, debitMsg = EconomyService.TryDebit(userId, price, `SpecialBox:{boxId}`, txId)
	if not okDebit then
		ShopStockService.ReleaseUnit(boxId)
		return makeError(req.ClientOpId, debitCode or ShopProtocol.ErrorCodes.InsufficientFunds, debitMsg or "Error al cobrar la caja.")
	end

	local okOrder, orderRec, orderErrCode, orderErrMsg = DeliveryService.CreateSpecialOrder(userId, boxDef, price, txId)
	if not okOrder or not orderRec then
		EconomyService.Credit(userId, price, `SpecialBoxRollback:{boxId}`, `rb_{txId}`, nil)
		ShopStockService.ReleaseUnit(boxId)
		return makeError(
			req.ClientOpId,
			orderErrCode or ShopProtocol.ErrorCodes.PersistenceFailed,
			orderErrMsg or "Error al registrar pedido de caja especial."
		)
	end

	local snap = ShopService.BuildPlayerShopSnapshot(userId)
	return {
		Success = true,
		ClientOpId = req.ClientOpId,
		NewBalance = newBal,
		Order = orderRec,
		ShopSnapshot = snap,
	}
end

local function handlePromptRushOrder(
	player: PlayerLike,
	req: ShopProtocol.ShopRequestPayload
): ShopProtocol.ShopOperationResponse
	local userId = extractUserId(player)
	if type(req.OrderId) ~= "string" or #req.OrderId == 0 then
		return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.InvalidPayload, "Debes indicar OrderId para acelerar.")
	end

	local order, orderKind = DeliveryService.FindOrderForUser(userId, req.OrderId)
	if not order then
		return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.OrderNotFound, "Pedido no encontrado.")
	end
	if order.Status ~= "InTransit" then
		return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.OrderAlreadyArrived, "El pedido ya llegó a DeliveryZone.")
	end

	local remaining = order.ArriveAt - _clockFn()
	if remaining <= ShopConfig.Orders.RobuxSpeedupArrivalSeconds then
		return makeError(
			req.ClientOpId,
			ShopProtocol.ErrorCodes.RushUnavailable,
			"El camión ya está llegando en menos de 5 segundos."
		)
	end

	local productId = 0
	if orderKind == "Special" then
		local boxDef = LootBoxConfig.GetBox(order.BoxId)
		if boxDef and type(boxDef.RobuxSpeedupProductId) == "number" and boxDef.RobuxSpeedupProductId > 0 then
			productId = boxDef.RobuxSpeedupProductId
		else
			productId = ShopConfig.RobuxProducts.RushSpecialOrderProductId
		end
	else
		productId = ShopConfig.RobuxProducts.RushNormalOrderProductId
	end

	if type(productId) ~= "number" or productId <= 0 then
		return makeError(
			req.ClientOpId,
			ShopProtocol.ErrorCodes.DeveloperProductNotConfigured,
			"Aceleración con Robux pendiente de configurar Developer Product ID en ShopConfig."
		)
	end

	DeliveryService.SetPendingRushOrder(userId, req.OrderId)
	if typeof(player) == "Instance" and (player :: Instance):IsA("Player") then
		pcall(function()
			MarketplaceService:PromptProductPurchase(player :: Player, productId)
		end)
	end

	return {
		Success = true,
		ClientOpId = req.ClientOpId,
		ProductIdToPrompt = productId,
		Order = order,
	}
end

function ShopService.ProcessMarketplaceReceipt(receiptInfo: {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	CurrencySpent: number?,
	ProductPurchaseChannel: any?,
}): Enum.ProductPurchaseDecision
	if type(receiptInfo) ~= "table" or type(receiptInfo.PlayerId) ~= "number" or type(receiptInfo.PurchaseId) ~= "string" then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local userId = receiptInfo.PlayerId
	local purchaseId = receiptInfo.PurchaseId
	local productId = receiptInfo.ProductId

	local okEco = EconomyService.EnsurePlayerLoaded(userId)
	if not okEco then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if EconomyService.HasProcessedReceipt(userId, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- 1) Publicidad recompensada oficial (AdReward): x5 ganancias offline pendientes
	local isAdRewardChannel = receiptInfo.ProductPurchaseChannel == Enum.ProductPurchaseChannel.AdReward
	local adDevProdId = ShopConfig.OfflineIncome.RewardedAdDevProductId
	if isAdRewardChannel or (adDevProdId > 0 and productId == adDevProdId) then
		local okClaim, _, newBal = OfflineIncomeService.CompleteOfflineClaim(
			userId,
			ShopConfig.OfflineIncome.RewardedAdMultiplier,
			purchaseId,
			nil
		)
		if not okClaim then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		syncFullOrdersAndInventory(userId, "OfflineIncomeAd5x")
		if newBal then
			fireSyncToUser(userId, ShopProtocol.SyncEventTypes.BalanceUpdated, { Balance = newBal })
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- 2) Developer Product de aceleración "Pedir ahora" (~5 s)
	local matchesRushProduct = (ShopConfig.RobuxProducts.RushNormalOrderProductId > 0 and productId == ShopConfig.RobuxProducts.RushNormalOrderProductId)
		or (ShopConfig.RobuxProducts.RushSpecialOrderProductId > 0 and productId == ShopConfig.RobuxProducts.RushSpecialOrderProductId)
	if not matchesRushProduct then
		for _, boxDef in ipairs(LootBoxConfig.GetEnabledBoxes()) do
			if boxDef.RobuxSpeedupProductId == productId and productId > 0 then
				matchesRushProduct = true
				break
			end
		end
	end

	if matchesRushProduct then
		local okRush, _, rushCode = DeliveryService.AccelerateOrder(userId, nil, purchaseId)
		if not okRush then
			if rushCode == ShopProtocol.ErrorCodes.PersistenceFailed then
				return Enum.ProductPurchaseDecision.NotProcessedYet
			end
			-- Si no existe orden en tránsito pero el producto se cobró, registrar igualmente? No conceder gratis ni re-acreditar erróneamente; devolver NotProcessedYet si no encontró orden pendiente.
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local okRec = EconomyService.RecordProcessedReceipt(userId, purchaseId)
		if not okRec then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		syncFullOrdersAndInventory(userId, "OrderRushed")
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function ShopService.ProcessRequest(player: PlayerLike, req: ShopProtocol.ShopRequestPayload): ShopProtocol.ShopOperationResponse
	if not _initialized then
		ShopService.Init()
	end
	if type(req) ~= "table" or type(req.Action) ~= "string" then
		return makeError(nil, ShopProtocol.ErrorCodes.InvalidPayload, "Solicitud inválida.")
	end

	local userId = extractUserId(player)
	local action = req.Action
	local isRead = action == ShopProtocol.Actions.GetShopSnapshot

	if not checkRateLimit(userId, not isRead) then
		return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.RateLimited, "Demasiadas operaciones de tienda.")
	end

	if isRead then
		local snap, errCode, errMsg = ShopService.BuildPlayerShopSnapshot(userId)
		if not snap then
			return makeError(req.ClientOpId, errCode or ShopProtocol.ErrorCodes.PersistenceFailed, errMsg or "No se pudo cargar la tienda.")
		end
		return {
			Success = true,
			ClientOpId = req.ClientOpId,
			NewBalance = snap.Balance,
			ShopSnapshot = snap,
		}
	end

	if type(req.ClientOpId) == "string" and #req.ClientOpId > 0 then
		local cache = _processedOpsByUserId[userId]
		if cache and cache[req.ClientOpId] then
			return cache[req.ClientOpId]
		end
	end

	if _userOpLocks[userId] then
		return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.ConcurrentOperation, "Operación de tienda en curso.")
	end
	_userOpLocks[userId] = true

	local response: ShopProtocol.ShopOperationResponse
	local okExec, resOrErr = pcall(function()
		if action == ShopProtocol.Actions.CheckoutNormalCart then
			return checkoutNormalCart(player, req)
		elseif action == ShopProtocol.Actions.PurchaseSpecialCrate then
			return purchaseSpecialCrate(player, req)
		elseif action == ShopProtocol.Actions.OpenDeliveryCrate then
			local okOpen, openedRes, openCode, openMsg = DeliveryService.OpenCrate(player, req.CrateId or "")
			if not okOpen then
				return makeError(req.ClientOpId, openCode or ShopProtocol.ErrorCodes.InvalidPayload, openMsg or "No se pudo abrir la caja.")
			end
			return {
				Success = true,
				ClientOpId = req.ClientOpId,
				OpenedResult = openedRes,
				NewBalance = EconomyService.GetBalance(userId),
				ShopSnapshot = ShopService.BuildPlayerShopSnapshot(userId),
			}
		elseif action == ShopProtocol.Actions.PromptRushOrder then
			return handlePromptRushOrder(player, req)
		elseif action == ShopProtocol.Actions.ClaimOfflineIncome then
			local okClaim, claimed, newBal, claimCode, claimMsg = OfflineIncomeService.ClaimOfflineIncome(
				player,
				req.UseRewardedAd == true,
				req.ClientOpId
			)
			if not okClaim then
				return makeError(
					req.ClientOpId,
					claimCode or ShopProtocol.ErrorCodes.NoPendingOfflineIncome,
					claimMsg or "No se pudieron reclamar ganancias offline."
				)
			end
			return {
				Success = true,
				ClientOpId = req.ClientOpId,
				ClaimedAmount = claimed,
				NewBalance = newBal,
				ShopSnapshot = ShopService.BuildPlayerShopSnapshot(userId),
			}
		else
			return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.InvalidAction, `Acción de tienda desconocida: '{action}'.`)
		end
	end)

	_userOpLocks[userId] = nil

	if not okExec then
		return makeError(req.ClientOpId, ShopProtocol.ErrorCodes.InvalidPayload, tostring(resOrErr))
	end
	response = resOrErr :: ShopProtocol.ShopOperationResponse

	if response.Success and type(req.ClientOpId) == "string" and #req.ClientOpId > 0 then
		local cache = _processedOpsByUserId[userId]
		if not cache then
			cache = {}
			_processedOpsByUserId[userId] = cache
		end
		cache[req.ClientOpId] = response
	end

	return response
end

function ShopService.HandlePlayerAssignedPlot(player: PlayerLike, plot: PlotService.PlotRecord)
	spawnShopCounterForPlot(player, plot)
	local userId = extractUserId(player)
	EconomyService.EnsurePlayerLoaded(userId)
	InventoryService.EnsurePlayerLoaded(userId)
	DeliveryService.EnsurePlayerLoaded(userId)
	OfflineIncomeService.ProcessJoinOfflineIncome(userId)
	DeliveryService.ProcessArrivalsForUser(userId)

	local snap = ShopService.BuildPlayerShopSnapshot(userId)
	if snap then
		fireSyncToUser(userId, ShopProtocol.SyncEventTypes.Snapshot, {
			ShopSnapshot = snap,
		})
		if snap.OfflineIncome and snap.OfflineIncome.PendingAmount > 0 then
			fireSyncToUser(userId, ShopProtocol.SyncEventTypes.OfflineIncomePending, {
				OfflineIncome = snap.OfflineIncome,
			})
		end
	end
end

function ShopService._ProcessReceiptForTests(receiptInfo: any): Enum.ProductPurchaseDecision
	return ShopService.ProcessMarketplaceReceipt(receiptInfo)
end

function ShopService._SetClockForTests(clockFn: (() -> number)?)
	_clockFn = clockFn or os.time
	EconomyService._SetClockForTests(_clockFn)
	GameConfigService._SetClockForTests(_clockFn)
	ShopStockService._SetClockForTests(_clockFn)
	DeliveryService._SetClockForTests(_clockFn)
	OfflineIncomeService._SetClockForTests(_clockFn)
end

function ShopService._ResetForTests()
	for _, conn in ipairs(_connections) do
		conn:Disconnect()
	end
	table.clear(_connections)
	for _, u in ipairs(_unsubs) do
		u()
	end
	table.clear(_unsubs)
	_rateLimiter:ResetAll()
	table.clear(_userOpLocks)
	table.clear(_processedOpsByUserId)
	_clockFn = os.time
	_initialized = false
	_started = false
end

function ShopService.Init()
	if _initialized then
		return
	end
	_initialized = true

	EconomyService.Init()
	GameConfigService.Init()
	ShopStockService.Init()
	DeliveryService.Init()
	OfflineIncomeService.Init()

	table.insert(
		_unsubs,
		GameConfigService.RegisterConfigChangedListener(function(domain: string, _revision: number, reason: string)
			if domain == "Crates" then
				ShopStockService.SyncWithEffectiveConfig(reason)
				broadcastStockSync(reason)
			end
		end)
	)

	table.insert(
		_unsubs,
		EconomyService.RegisterBalanceChangedListener(function(userId: number, newBalance: number, reason: string?)
			fireSyncToUser(userId, ShopProtocol.SyncEventTypes.BalanceUpdated, {
				Balance = newBalance,
				Reason = reason,
			})
		end)
	)
	table.insert(
		_unsubs,
		ShopStockService.RegisterStockChangedListener(function(reason: string)
			broadcastStockSync(reason)
		end)
	)
	table.insert(
		_unsubs,
		DeliveryService.RegisterOrdersUpdatedListener(function(userId: number, reason: string)
			syncFullOrdersAndInventory(userId, reason)
		end)
	)
	table.insert(
		_unsubs,
		DeliveryService.RegisterTruckArrivingListener(function(userId: number, orderId: string, orderType: string)
			fireSyncToUser(userId, ShopProtocol.SyncEventTypes.DeliveryTruckArriving, {
				OrderId = orderId,
				OrderType = orderType,
			})
		end)
	)
	table.insert(
		_unsubs,
		DeliveryService.RegisterCrateEffectListener(function(userId: number, payload: { [string]: any })
			fireSyncToUser(userId, ShopProtocol.SyncEventTypes.CrateOpeningEffect, payload)
		end)
	)
	table.insert(
		_unsubs,
		PlotService.OnPlotAssigned(function(player: PlayerLike, plot: PlotService.PlotRecord)
			ShopService.HandlePlayerAssignedPlot(player, plot)
		end)
	)
	table.insert(
		_unsubs,
		PlotService.OnPlotReleased(function(player: PlayerLike)
			DeliveryService.CleanupPlayerVisuals(player)
			OfflineIncomeService.MarkPlayerActiveCheckpoint(player)
		end)
	)
end

function ShopService.Start()
	if not _initialized then
		ShopService.Init()
	end
	if _started then
		return
	end
	_started = true

	EconomyService.Start()
	GameConfigService.Start()
	ShopStockService.Start()
	DeliveryService.Start()
	OfflineIncomeService.Start()

	local rf = ensureRemotes()
	rf.OnServerInvoke = function(player: Player, req: any)
		return ShopService.ProcessRequest(player, req)
	end

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		return ShopService.ProcessMarketplaceReceipt(receiptInfo)
	end

	table.insert(
		_connections,
		Players.PlayerRemoving:Connect(function(player: Player)
			OfflineIncomeService.MarkPlayerActiveCheckpoint(player.UserId)
			_rateLimiter:ClearPlayer(player.UserId)
			_processedOpsByUserId[player.UserId] = nil
			_userOpLocks[player.UserId] = nil
		end)
	)

	-- Inicializar parcelas que ya estuvieran asignadas antes de Start()
	for _, p in ipairs(Players:GetPlayers()) do
		local existingPlot = PlotService.GetPlotByPlayer(p)
		if existingPlot then
			ShopService.HandlePlayerAssignedPlot(p, existingPlot)
		end
	end
end

return ShopService
