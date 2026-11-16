--!strict
--[=[
	ShopProtocol
	Contrato cliente <-> servidor para Tienda, Carrito, Pedidos (normales 60s y especiales 900s),
	Stock compartido con restock 300s, DeliveryZone, Aceleración Robux y Ganancias Offline (Fase 5.2).
]=]

local ShopProtocol = {}

ShopProtocol.RemoteFunctionName = "ShopOperationRequest"
ShopProtocol.SyncEventName = "ShopSyncEvent"

ShopProtocol.Actions = table.freeze({
	GetShopSnapshot = "GetShopSnapshot",
	CheckoutNormalCart = "CheckoutNormalCart",
	PurchaseSpecialCrate = "PurchaseSpecialCrate",
	OpenDeliveryCrate = "OpenDeliveryCrate",
	PromptRushOrder = "PromptRushOrder",
	ClaimOfflineIncome = "ClaimOfflineIncome",
})

ShopProtocol.SyncEventTypes = table.freeze({
	Snapshot = "Snapshot",
	StockUpdated = "StockUpdated",
	OrdersUpdated = "OrdersUpdated",
	BalanceUpdated = "BalanceUpdated",
	DeliveryTruckArriving = "DeliveryTruckArriving",
	CrateOpeningEffect = "CrateOpeningEffect",
	OfflineIncomePending = "OfflineIncomePending",
})

ShopProtocol.ErrorCodes = table.freeze({
	InvalidAction = "InvalidAction",
	InvalidPayload = "InvalidPayload",
	UnknownItem = "UnknownItem",
	ItemNotShopPurchasable = "ItemNotShopPurchasable",
	MaxPurchasesReached = "MaxPurchasesReached",
	InsufficientFunds = "InsufficientFunds",
	NormalOrderInProgress = "NormalOrderInProgress",
	UnknownBox = "UnknownBox",
	BoxDisabled = "BoxDisabled",
	OutOfStock = "OutOfStock",
	OrderNotFound = "OrderNotFound",
	OrderNotReady = "OrderNotReady",
	CrateNotFound = "CrateNotFound",
	CrateNotOwner = "CrateNotOwner",
	CrateAlreadyOpened = "CrateAlreadyOpened",
	OpeningInProgress = "OpeningInProgress",
	DeveloperProductNotConfigured = "DeveloperProductNotConfigured",
	OrderAlreadyArrived = "OrderAlreadyArrived",
	RushUnavailable = "RushUnavailable",
	NoPendingOfflineIncome = "NoPendingOfflineIncome",
	RewardedAdNotAvailable = "RewardedAdNotAvailable",
	RewardedAdFailed = "RewardedAdFailed",
	PersistenceFailed = "PersistenceFailed",
	UnauthorizedOperation = "UnauthorizedOperation",
	RateLimited = "RateLimited",
	ConcurrentOperation = "ConcurrentOperation",
})

export type CartLineRequest = {
	ItemId: string,
	Quantity: number,
}

export type ShopRequestPayload = {
	Action: string,
	ClientOpId: string?,
	CartItems: { CartLineRequest }?,
	BoxId: string?,
	CrateId: string?,
	OrderId: string?,
	UseRewardedAd: boolean?,
}

export type ShopOperationResponse = {
	Success: boolean,
	ClientOpId: string?,
	ErrorCode: string?,
	ErrorMessage: string?,
	NewBalance: number?,
	Order: any?,
	OpenedResult: any?,
	ShopSnapshot: any?,
	ClaimedAmount: number?,
	ProductIdToPrompt: number?,
}

return ShopProtocol

