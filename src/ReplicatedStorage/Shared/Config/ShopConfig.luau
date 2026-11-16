--!strict
--[=[
	ShopConfig
	Configuración centralizada y editable de la Fase 5.2 (Economía, Pedidos, Entregas,
	Restock compartido, Ingresos Offline de Motores, Publicidad Recompensada y Robux).

	NOTA DE BALANCE:
	- Todos los parámetros etiquetados con BalanceStatus = "PROVISIONAL_TBD" están
	  explícitamente autorizados como configuración provisional editable y NO deben
	  interpretarse como balance definitivo final.
	- Los IDs de Developer Products (Robux / Anuncio recompensado) quedan en 0 hasta
	  ingresar los IDs reales desde Creator Hub / Roblox Studio.
]=]

local ShopConfig = {}

ShopConfig.Economy = {
	StartingMoney = 1000, -- Entregado UNA sola vez al jugador nuevo
	NormalSellRatio = 0.50, -- Venta de piezas normales al 50% redondeado hacia abajo
	UniqueUnitMonetarySellEnabled = false, -- Motores/propulsores únicos sin precio individual: venta monetaria bloqueada
	CurrencyName = "monedas",
	CurrencySymbol = "$",
	DataStoreName = "BuildEngineers_PlayerEconomy_v1",
	StorageSchemaVersion = 1,
	MaxTrackedProcessedIds = 250,
}

ShopConfig.Orders = {
	NormalOrderWaitSeconds = 60,
	SpecialOrderWaitSeconds = 900, -- 15 minutos
	RestockIntervalSeconds = 300, -- 5 minutos (reemplazo estricto del stock)
	RobuxSpeedupArrivalSeconds = 5, -- Llegada ~5s tras confirmar ProcessReceipt
	DataStoreName = "BuildEngineers_PlayerOrders_v1",
	StorageSchemaVersion = 1,
	MaxCartLines = 25,
	MaxQuantityPerLine = 1000000, -- Tope técnico anti-overflow (permite compras grandes de 100+ / 1,000+ unidades)
}

ShopConfig.DeliveryZone = {
	VisualCapacity = 6, -- Capacidad visual inicial simultánea en DeliveryZone
	GridColumns = 3,
	GridRows = 2,
	SlotSpacingX = 3.6,
	SlotSpacingZ = 4.2,
	SlotElevationY = 0.0,
	TruckApproachOffset = Vector3.new(24, 0, -24),
	TruckUnloadOffset = Vector3.new(12, 0, -10),
	TruckExitOffset = Vector3.new(26, 0, 18),
	TruckCollisionGroup = "DeliveryProps",
	CrateRevealLifetimeSeconds = 7.5, -- Duración visual del motor/propulsor revelado antes de limpiar modelo temporal
	MaxPromptDistance = 12,
	ShopPromptMaxDistance = 12,
}

ShopConfig.RobuxProducts = {
	-- Rellenar con los IDs reales de Developer Product en Creator Hub (> 0 para habilitar).
	RushNormalOrderProductId = 0,
	RushSpecialOrderProductId = 0,
}

ShopConfig.OfflineIncome = {
	BalanceStatus = "PROVISIONAL_TBD",
	Enabled = true,
	MinOfflineSeconds = 10, -- Ignorar micro-desconexiones inferiores a 10 segundos
	MaxAccumulationSeconds = 86400, -- Tope configurable (24 horas)
	RewardedAdMultiplier = 5, -- Botón Recoger x5 mediante AdService + ProcessReceipt
	RewardedAdDevProductId = 0, -- Developer Product asociado al AdReward en Creator Hub (> 0 para habilitar)
	RewardedAdPlacementId = nil :: number?, -- PlacementId opcional de AdService (Creator Dashboard)

	-- Tasas base PROVISIONAL_TBD (monedas/hora por unidad única de motor, deducidas de tasas preliminares)
	HourlyRatesBySize = {
		Small = 21.88,
		Medium = 87.50,
		Large = 175.00,
	},
	RarityMultipliers = {
		Common = 1.00,
		Uncommon = 1.25,
		Rare = 1.60,
		Epic = 2.15,
		Legendary = 3.00,
		Mythic = 4.50,
	},
}

ShopConfig.Assets = {
	CratesRootFolder = "Crates",
	NormalFolder = "Normales",
	NormalCrateModel = "NormalDeliveryCrate",
	SpecialFolder = "Especiales",
	SpecialEngineFolder = "Motores",
	SpecialBoosterFolder = "Propulsores",
	DeliveryFolder = "Reparto",
	DeliveryTruckModel = "DeliveryTruck",
	ShopCounterModel = "ShopCounter",
	EffectsFolder = "Efectos",
}

function ShopConfig.ComputeNormalSellPrice(buyPrice: number?): number?
	if type(buyPrice) ~= "number" or buyPrice < 0 or buyPrice ~= buyPrice or buyPrice == math.huge then
		return nil
	end
	return math.floor(buyPrice * ShopConfig.Economy.NormalSellRatio)
end

function ShopConfig.ComputeEngineOfflineHourlyRate(sizeId: string?, rarityId: string?): number
	local sizeRate = (ShopConfig.OfflineIncome.HourlyRatesBySize :: { [string]: number })[sizeId or "Small"]
		or ShopConfig.OfflineIncome.HourlyRatesBySize.Small
	local rarityMult = (ShopConfig.OfflineIncome.RarityMultipliers :: { [string]: number })[rarityId or "Common"] or 1.0
	return sizeRate * rarityMult
end

function ShopConfig.ComputeOfflineCoinsForEngine(sizeId: string?, rarityId: string?, elapsedSeconds: number): number
	if elapsedSeconds <= 0 then
		return 0
	end
	local ratePerHour = ShopConfig.ComputeEngineOfflineHourlyRate(sizeId, rarityId)
	return (ratePerHour / 3600) * elapsedSeconds
end

table.freeze(ShopConfig.Economy)
table.freeze(ShopConfig.Orders)
table.freeze(ShopConfig.DeliveryZone)
table.freeze(ShopConfig.RobuxProducts)
table.freeze(ShopConfig.OfflineIncome.HourlyRatesBySize)
table.freeze(ShopConfig.OfflineIncome.RarityMultipliers)
table.freeze(ShopConfig.OfflineIncome)
table.freeze(ShopConfig.Assets)

return ShopConfig

