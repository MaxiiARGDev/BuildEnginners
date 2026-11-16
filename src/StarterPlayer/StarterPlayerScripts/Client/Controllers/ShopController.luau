--!strict
--[=[
	ShopController
	Estado reactivo en cliente y comunicador con ShopService (Tienda, Carrito, Cajas Especiales,
	Stock compartido, Pedidos 60 s / 900 s, Robux Pedir Ahora e Ingresos Offline x1 / x5 AdService).
]=]

local AdService = game:GetService("AdService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local BuildState = require(script.Parent.BuildState)

export type StateChangedListener = () -> ()
export type VisualCueListener = (eventType: string, payload: { [string]: any }) -> ()

local ShopController = {}

ShopController.IsLoaded = false
ShopController.Balance = 0
ShopController.ServerClockOffset = 0
ShopController.NextRestockAt = 0
ShopController.RestockEpoch = 0
ShopController.CrateConfigRevision = 0
ShopController.NormalOrderWaitSeconds = ShopConfig.Orders.NormalOrderWaitSeconds
ShopController.SpecialOrderWaitSeconds = ShopConfig.Orders.SpecialOrderWaitSeconds
ShopController.RobuxProducts = {
	RushNormalOrderProductId = 0,
	RushSpecialOrderProductId = 0,
}
ShopController.NormalItems = {} :: { any }
ShopController.SpecialBoxes = {} :: { any }
ShopController.Orders = nil :: any
ShopController.OfflineIncome = nil :: any
ShopController.Cart = {} :: { [string]: number }
ShopController.RewardedAdAvailable = false
ShopController.RewardedAdStatusReason = "Verificando disponibilidad..."
ShopController.OpenRequested = false
ShopController.OfflineModalRequested = false
ShopController.IsBusy = false
ShopController.LastError = nil :: string?
ShopController.LastStatus = nil :: string?

local _listeners: { StateChangedListener } = {}
local _cueListeners: { VisualCueListener } = {}
local _initialized = false
local _syncConn: RBXScriptConnection? = nil

local function makeOpId(prefix: string): string
	return prefix .. string.lower(string.gsub(HttpService:GenerateGUID(false), "-", "")):sub(1, 14)
end

local function notify()
	for _, cb in ipairs(table.clone(_listeners)) do
		task.spawn(cb)
	end
end

local function emitCue(eventType: string, payload: { [string]: any })
	for _, cb in ipairs(table.clone(_cueListeners)) do
		task.spawn(cb, eventType, payload)
	end
end

local function getRemoteFunction(): RemoteFunction?
	local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
	local remotesFolder = sharedFolder and sharedFolder:FindFirstChild("Remotes")
	local rf = remotesFolder and remotesFolder:FindFirstChild(ShopProtocol.RemoteFunctionName)
	if rf and rf:IsA("RemoteFunction") then
		return rf
	end
	return nil
end

local function applySnapshot(snap: any)
	if type(snap) ~= "table" then
		return
	end
	if not ShopController.IsLoaded or ShopController.LastError == "Carga de persistencia en curso" then
		ShopController.LastError = nil
	end
	ShopController.IsLoaded = true
	if type(snap.Balance) == "number" then
		ShopController.Balance = snap.Balance
	end
	if type(snap.ServerNow) == "number" then
		ShopController.ServerClockOffset = snap.ServerNow - os.time()
	end
	if type(snap.NextRestockAt) == "number" then
		ShopController.NextRestockAt = snap.NextRestockAt
	end
	if type(snap.RestockEpoch) == "number" then
		ShopController.RestockEpoch = snap.RestockEpoch
	end
	if type(snap.CrateConfigOverrides) == "table" then
		local rev = if type(snap.CrateConfigRevision) == "number" then snap.CrateConfigRevision else 0
		LootBoxConfig.ApplyEffectiveOverrides(snap.CrateConfigOverrides, rev)
		ShopController.CrateConfigRevision = LootBoxConfig.GetEffectiveRevision()
	end
	if type(snap.NormalItems) == "table" then
		ShopController.NormalItems = snap.NormalItems
	end
	if type(snap.SpecialBoxes) == "table" then
		ShopController.SpecialBoxes = snap.SpecialBoxes
	end
	if type(snap.Orders) == "table" then
		ShopController.Orders = snap.Orders
	end
	if type(snap.OfflineIncome) == "table" then
		ShopController.OfflineIncome = snap.OfflineIncome
		if (snap.OfflineIncome.PendingAmount or 0) > 0 then
			ShopController.OfflineModalRequested = true
		end
	end
	if type(snap.RobuxProducts) == "table" then
		ShopController.RobuxProducts = snap.RobuxProducts
	end
	if type(snap.Inventory) == "table" then
		BuildState.SetInventoryState(snap.Inventory)
	end
	notify()
end

function ShopController.GetEstimatedServerNow(): number
	return os.time() + ShopController.ServerClockOffset
end

function ShopController.CheckRewardedAdAvailabilityAsync()
	if not RunService:IsClient() then
		return
	end
	if ShopConfig.OfflineIncome.RewardedAdDevProductId <= 0 then
		ShopController.RewardedAdAvailable = false
		ShopController.RewardedAdStatusReason = "Producto de anuncio no configurado (Creator Hub)"
		notify()
		return
	end
	local ok, result = pcall(function()
		return AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)
	end)
	if ok and type(result) == "table" and result.AdAvailabilityResult == Enum.AdAvailabilityResult.IsAvailable then
		ShopController.RewardedAdAvailable = true
		ShopController.RewardedAdStatusReason = "Anuncio recompensado listo"
	else
		ShopController.RewardedAdAvailable = false
		local reasonName = if ok and type(result) == "table" and result.AdAvailabilityResult
			then tostring(result.AdAvailabilityResult)
			else "No disponible"
		ShopController.RewardedAdStatusReason = `Anuncio no disponible ({reasonName})`
	end
	notify()
end

function ShopController.Subscribe(listener: StateChangedListener): () -> ()
	table.insert(_listeners, listener)
	return function()
		local idx = table.find(_listeners, listener)
		if idx then
			table.remove(_listeners, idx)
		end
	end
end

function ShopController.SubscribeVisualCue(listener: VisualCueListener): () -> ()
	table.insert(_cueListeners, listener)
	return function()
		local idx = table.find(_cueListeners, listener)
		if idx then
			table.remove(_cueListeners, idx)
		end
	end
end

function ShopController.GetCartQuantity(itemId: string): number
	return ShopController.Cart[itemId] or 0
end

function ShopController.SetCartQuantity(itemId: string, qty: number)
	if not ItemCatalog.IsDirectShopPurchasable(itemId) then
		ShopController.Cart[itemId] = nil
		notify()
		return
	end
	local cleanQty = math.max(0, math.floor(qty))
	if cleanQty == 0 then
		ShopController.Cart[itemId] = nil
	else
		ShopController.Cart[itemId] = math.min(ShopConfig.Orders.MaxQuantityPerLine, cleanQty)
	end
	notify()
end

function ShopController.AddToCart(itemId: string, delta: number?)
	if not ItemCatalog.IsDirectShopPurchasable(itemId) then
		return
	end
	local step = math.floor(delta or 1)
	local cur = ShopController.Cart[itemId] or 0
	ShopController.SetCartQuantity(itemId, cur + step)
end

function ShopController.ClearCart()
	table.clear(ShopController.Cart)
	notify()
end

function ShopController.GetCartSummary(): ({ Lines: { { ItemId: string, DisplayName: string, Quantity: number, UnitPrice: number, LineTotal: number } }, TotalCost: number, CrateCount: number })
	local byId: { [string]: any } = {}
	for _, item in ipairs(ShopController.NormalItems) do
		byId[item.ItemId] = item
	end

	local lines = {}
	local total = 0
	for itemId, qty in pairs(ShopController.Cart) do
		if ItemCatalog.IsDirectShopPurchasable(itemId) then
			local entry = byId[itemId] or ItemCatalog.GetEntry(itemId)
			if qty > 0 and entry and type(entry.Price) == "number" then
				local unitPrice = math.floor(entry.Price)
				local lineTotal = unitPrice * qty
				total += lineTotal
				table.insert(lines, {
					ItemId = itemId,
					DisplayName = entry.DisplayName,
					Quantity = qty,
					UnitPrice = unitPrice,
					LineTotal = lineTotal,
				})
			end
		end
	end
	table.sort(lines, function(a, b)
		return a.DisplayName < b.DisplayName
	end)
	return {
		Lines = lines,
		TotalCost = total,
		CrateCount = #lines,
	}
end

local function invokeShopServer(req: ShopProtocol.ShopRequestPayload): (boolean, ShopProtocol.ShopOperationResponse?)
	local rf = getRemoteFunction()
	if not rf then
		ShopController.LastError = "Servicio de tienda aún conectando..."
		notify()
		return false, nil
	end

	ShopController.IsBusy = true
	ShopController.LastError = nil
	notify()

	local ok, res = pcall(function()
		return rf:InvokeServer(req)
	end)
	ShopController.IsBusy = false

	if not ok or type(res) ~= "table" then
		ShopController.LastError = "Error de comunicación con el servidor de tienda."
		notify()
		return false, nil
	end

	local response = res :: ShopProtocol.ShopOperationResponse
	if response.ShopSnapshot then
		applySnapshot(response.ShopSnapshot)
	elseif type(response.NewBalance) == "number" then
		ShopController.Balance = response.NewBalance
	end

	if not response.Success then
		ShopController.LastError = response.ErrorMessage or "No se pudo completar la operación."
		notify()
		return false, response
	end

	notify()
	return true, response
end

function ShopController.RefreshShop(): (boolean, ShopProtocol.ShopOperationResponse?)
	return invokeShopServer({
		Action = ShopProtocol.Actions.GetShopSnapshot,
		ClientOpId = makeOpId("sget_"),
	})
end

function ShopController.CheckoutNormalCart(): (boolean, ShopProtocol.ShopOperationResponse?)
	local summary = ShopController.GetCartSummary()
	if #summary.Lines == 0 then
		ShopController.LastError = "Tu carrito está vacío."
		notify()
		return false, nil
	end
	local cartReq: { ShopProtocol.CartLineRequest } = {}
	for _, line in ipairs(summary.Lines) do
		table.insert(cartReq, { ItemId = line.ItemId, Quantity = line.Quantity })
	end
	local ok, res = invokeShopServer({
		Action = ShopProtocol.Actions.CheckoutNormalCart,
		ClientOpId = makeOpId("nco_"),
		CartItems = cartReq,
	})
	if ok then
		table.clear(ShopController.Cart)
		ShopController.LastStatus = "Pedido normal confirmado. Llegará en 60 s a DeliveryZone."
		notify()
	end
	return ok, res
end

function ShopController.PurchaseSpecialCrate(boxId: string): (boolean, ShopProtocol.ShopOperationResponse?)
	local ok, res = invokeShopServer({
		Action = ShopProtocol.Actions.PurchaseSpecialCrate,
		ClientOpId = makeOpId("spb_"),
		BoxId = boxId,
	})
	if ok then
		local delivSec = if res and res.Order and type((res.Order :: any).DeliverySeconds) == "number"
			then (res.Order :: any).DeliverySeconds
			else LootBoxConfig.GetDeliverySeconds(boxId)
		local formattedTime = LootBoxConfig.FormatDeliveryTime(delivSec, false)
		ShopController.LastStatus = `Caja especial comprada. Llegará en {formattedTime} a DeliveryZone.`
		notify()
	end
	return ok, res
end

function ShopController.OpenDeliveryCrate(crateId: string): (boolean, ShopProtocol.ShopOperationResponse?)
	return invokeShopServer({
		Action = ShopProtocol.Actions.OpenDeliveryCrate,
		ClientOpId = makeOpId("opn_"),
		CrateId = crateId,
	})
end

function ShopController.PromptRushOrder(orderId: string): (boolean, ShopProtocol.ShopOperationResponse?)
	local ok, res = invokeShopServer({
		Action = ShopProtocol.Actions.PromptRushOrder,
		ClientOpId = makeOpId("rsh_"),
		OrderId = orderId,
	})
	if ok then
		ShopController.LastStatus = "Procesando compra de aceleración con Robux..."
		notify()
	end
	return ok, res
end

function ShopController.ClaimOfflineIncome(useRewardedAd: boolean): (boolean, ShopProtocol.ShopOperationResponse?)
	local ok, res = invokeShopServer({
		Action = ShopProtocol.Actions.ClaimOfflineIncome,
		ClientOpId = makeOpId("off_"),
		UseRewardedAd = useRewardedAd,
	})
	if ok and res then
		ShopController.OfflineModalRequested = false
		ShopController.LastStatus = `¡Recogiste ${res.ClaimedAmount or 0} monedas de ingresos offline!`
		notify()
	end
	return ok, res
end

function ShopController.ClearStatusAndError()
	ShopController.LastError = nil
	ShopController.LastStatus = nil
	notify()
end

function ShopController.DismissOfflineModal()
	ShopController.OfflineModalRequested = false
	notify()
end

function ShopController.Init()
	if _initialized then
		return
	end
	_initialized = true

	task.spawn(function()
		local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
		local remotes = sharedFolder and sharedFolder:WaitForChild("Remotes", 10)
		local ev = remotes and remotes:WaitForChild(ShopProtocol.SyncEventName, 10)
		if ev and ev:IsA("RemoteEvent") then
			if _syncConn then
				_syncConn:Disconnect()
			end
			_syncConn = ev.OnClientEvent:Connect(function(payload: any)
				if type(payload) ~= "table" then
					return
				end
				if type(payload.ServerNow) == "number" then
					ShopController.ServerClockOffset = payload.ServerNow - os.time()
				end
				if payload.ShopSnapshot then
					applySnapshot(payload.ShopSnapshot)
				else
					if type(payload.Balance) == "number" then
						ShopController.Balance = payload.Balance
					end
					if type(payload.SpecialBoxes) == "table" then
						ShopController.SpecialBoxes = payload.SpecialBoxes
					end
					if type(payload.NextRestockAt) == "number" then
						ShopController.NextRestockAt = payload.NextRestockAt
					end
					if type(payload.RestockEpoch) == "number" then
						ShopController.RestockEpoch = payload.RestockEpoch
					end
					if type(payload.CrateConfigOverrides) == "table" then
						local rev = if type(payload.CrateConfigRevision) == "number" then payload.CrateConfigRevision else 0
						LootBoxConfig.ApplyEffectiveOverrides(payload.CrateConfigOverrides, rev)
						ShopController.CrateConfigRevision = LootBoxConfig.GetEffectiveRevision()
					end
					if type(payload.OfflineIncome) == "table" then
						ShopController.OfflineIncome = payload.OfflineIncome
						if (payload.OfflineIncome.PendingAmount or 0) > 0 then
							ShopController.OfflineModalRequested = true
						end
					end
					notify()
				end

				if payload.OpenShopUi == true then
					ShopController.OpenRequested = true
					notify()
				end

				if type(payload.EventType) == "string" then
					emitCue(payload.EventType, payload)
				end
			end)
		end

		ShopController.CheckRewardedAdAvailabilityAsync()
		local ok, res = ShopController.RefreshShop()
		if not ok and res and res.ErrorCode == ShopProtocol.ErrorCodes.OperationInProgress then
			if ShopController.LastError == res.ErrorMessage or ShopController.LastError == "Carga de persistencia en curso" then
				ShopController.LastError = nil
				notify()
			end
			task.delay(0.6, function()
				if not ShopController.IsLoaded then
					ShopController.RefreshShop()
				end
			end)
		end
	end)
end

return ShopController
