--!strict
--[=[
	ItemTypes
	Contratos de tipos para categorías, estadísticas y definiciones de objetos del catálogo.
	Los campos marcados como opcionales pueden permanecer en nil cuando están pendientes (TBD) en el SDD.
]=]

export type ItemCategory =
	"Structures"
	| "Wheels"
	| "Engines"
	| "Boosters"
	| "FuelTanks"
	| "Seats"
	| "Aerodynamics"
	| "Utilities"
	| "Decorations"
	| "Other"

export type FuelCategory = "Normal" | "RocketFuel"

export type RegularFuelOption = "Regular" | "Diesel" | "Competicion"

export type ItemStats = {
	Weight: number,
	MaxDurability: number,
	ImpactResistance: number?, -- Multiplicador >= 0.1 de mitigación ante impactos (nil => perfil de categoría Provisional_TBD)
	DamageMultiplier: number?, -- Factor >= 0 de sensibilidad al daño recibido (nil => perfil de categoría Provisional_TBD)

	-- Wheels
	Eq: number?, -- Significado exacto TBD (docs/04, docs/10)
	Grip: number?,

	-- FuelTanks
	FuelSubtype: ("Normal" | "Nitro")?,
	FuelType: FuelCategory?,
	SelectableFuelTypes: { RegularFuelOption }?,
	Capacity: number?,

	-- Engines
	SpeedRegular: number?, -- bloques/s con regular
	Torque: number?,
	DrivingBonus: number?, -- bonificación por conducción (ej. 0.0025 => +0.0025x)
	DisconnectRate: number?, -- monedas/hora, semántica exacta TBD (docs/04, docs/10)
	IntegratedFuel: number?,
	MaxConsumptionRegular: number?,

	-- Boosters
	BoostConsumption: number?,
	Thrust: number?,
	SpeedBoostMultiplier: number?,

	-- Aerodynamics (Fase 5.3 — Provisional_TBD)
	WingArea: number?,
	LiftCoefficientSlope: number?,
	ZeroAlphaLiftCoefficient: number?,
	MaxLiftCoefficient: number?,
	BaseDragCoefficient: number?,
	InducedDragFactor: number?,
	StallAngleDeg: number?,
	VerticalStabilizerArea: number?,
}

export type ItemRestrictions = {
	MaxPurchasesPerPlayer: number?,
}

export type RotationPolicyMode = "Orthogonal90" | "StepDegrees" | "Free"

export type ItemPlacementPolicy = {
	RotationMode: RotationPolicyMode?,
	AllowedAngleStepsDeg: { number }?,
	AllowFreePosition: boolean?,
	AllowFreeRotation: boolean?,
}

export type InventoryItemKind = "Stackable" | "UniqueUnit"

export type ItemDefinition = {
	Id: string,
	DisplayName: string,
	Description: string?,
	Category: ItemCategory,
	AssetFolder: string?, -- Carpeta física en ServerStorage.ItemAssets / PreviewAssets (p. ej. "Bloques")
	InventoryKind: InventoryItemKind?, -- Stackable (cantidad entera) o UniqueUnit (instancia única)
	Model: string,
	Price: number?, -- nil cuando está TBD en docs/04-ITEM-CATALOG.md
	SellPrice: number?, -- nil mientras fórmula/economía de venta sea TBD
	Stats: ItemStats,
	Restrictions: ItemRestrictions?,
	PlacementPolicy: ItemPlacementPolicy?, -- nil => Orthogonal90 por defecto
	Behavior: string?, -- Nombre del ModuleScript dentro de Behaviors/ del modelo, si aplica
}

export type AssetValidationResult = {
	Valid: boolean,
	Errors: { string },
	CheckedCount: number,
}

-- Fase 3.3: Motores modulares, tamaños, variantes, rarezas y curvas de torque
export type EngineFamilyId = "StandardCombustion" | "CompactTurbine" | "HeavyDiesel"

export type EngineSizeId = "Small" | "Medium" | "Large"

export type EngineRarityId = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic"

export type EngineVariantId = "Balanced" | "HighTorque" | "HighRev" | "EcoLight" | "Overdrive"

export type BalanceStatusTag = "SDD_Confirmed" | "Provisional_TBD"

export type TorqueCurvePoint = {
	NormalizedRPM: number, -- 0.0 (Idle) .. 1.0 (MaxRPM)
	TorqueFactor: number, -- Multiplicador relativo al PeakTorque (ej. 0.45 .. 1.0)
}

export type TorqueCurveSpec = {
	Id: string,
	DisplayName: string,
	IdleTorqueFactor: number,
	PeakTorqueNormalizedRPM: number,
	RedlineTorqueFactor: number,
	CutoffDropPerNormalizedRPM: number,
	Points: { TorqueCurvePoint },
}

export type BaseEngineSizeSpec = {
	SizeId: EngineSizeId,
	DisplayName: string,
	BaseItemId: string, -- Modelo base 3D reutilizado (ej. "SmallEngine")
	SpeedRegular: number, -- studs/s de referencia SDD
	BaseTorque: number, -- Torque base SDD (Small=1400, Medium=4200, Large=7800 provisional)
	BasePowerRating: number, -- Potencia efectiva de referencia
	IdleRPM: number,
	OptimumRPM: number,
	MaxRPM: number,
	LimiterRPM: number,
	LimiterRecoveryRPM: number,
	Responsiveness: number, -- Tasa de respuesta de acelerador/RPM (1/s)
	EngineBrakingFactor: number,
	Weight: number,
	MaxDurability: number,
	FuelType: FuelCategory,
	IntegratedFuel: number,
	MaxConsumptionRegular: number,
	DrivingBonus: number,
	DisconnectRate: number,
	VisualScaleMultiplier: number,
	BalanceStatus: BalanceStatusTag,
}

export type EngineVariantModifiers = {
	VariantId: EngineVariantId,
	DisplayName: string,
	Description: string,
	TorqueDeltaRatio: number, -- ej. +0.18 para HighTorque
	PowerDeltaRatio: number,
	SpeedRegularDeltaRatio: number,
	IdleRPMDeltaRatio: number,
	OptimumRPMDeltaRatio: number,
	MaxRPMDeltaRatio: number,
	ResponsivenessDeltaRatio: number,
	WeightDeltaRatio: number,
	EfficiencyDeltaRatio: number, -- >0 reduce consumo por unidad de carga
	DurabilityDeltaRatio: number,
	CurveSpecId: string,
	BalanceStatus: BalanceStatusTag,
}

export type EngineRarityModifiers = {
	RarityId: EngineRarityId,
	DisplayName: string,
	RankOrder: number, -- 1 (Common) .. 6 (Mythic)
	ColorHex: string,
	-- Modificadores diferenciados por propiedad (no un único multiplicador plano):
	TorqueBonusRatio: number,
	PowerBonusRatio: number,
	SpeedBonusRatio: number,
	RPMBandBonusRatio: number,
	ResponsivenessBonusRatio: number,
	EfficiencyBonusRatio: number,
	WeightDeltaRatio: number, -- Puede aligerar o incrementar levemente según aleación
	DurabilityBonusRatio: number,
	DrivingBonusMultiplier: number, -- Referencia SDD docs/06 (+0.0025x -> +0.0065x en SmallEngine)
	BalanceStatus: BalanceStatusTag,
}

export type EffectiveEngineStats = {
	EngineFamilyId: EngineFamilyId,
	EngineSizeId: EngineSizeId,
	VariantId: EngineVariantId,
	RarityId: EngineRarityId,
	BaseItemId: string,
	DisplayName: string,
	FullLabel: string,
	SpeedRegular: number,
	PeakTorque: number,
	PowerRating: number,
	IdleRPM: number,
	OptimumRPM: number,
	MaxRPM: number,
	LimiterRPM: number,
	LimiterRecoveryRPM: number,
	Responsiveness: number,
	EngineBrakingFactor: number,
	Weight: number,
	MaxDurability: number,
	FuelType: FuelCategory,
	IntegratedFuel: number,
	MaxFuelConsumption: number,
	EfficiencyFactor: number,
	DrivingBonus: number,
	DisconnectRate: number,
	CurveSpecId: string,
	TorqueCurve: TorqueCurveSpec,
	BalanceStatus: BalanceStatusTag,
	IsProvisionalBalance: boolean,
}

export type EngineUnitRecord = {
	ItemInstanceId: string,
	OwnerUserId: number,
	ItemId: string,
	EngineFamilyId: EngineFamilyId,
	EngineSizeId: EngineSizeId,
	VariantId: EngineVariantId,
	RarityId: EngineRarityId,
	CreatedAt: number,
	SourceTag: string, -- "StarterDefault" | "DevTestGrant" | "FutureCrate"
	EffectiveStats: EffectiveEngineStats,
}

-- Fase 3.4: Propulsores modulares, tamaños, variantes, rarezas y empuje vectorial
export type BoosterFamilyId = "StandardRocket" | "HighImpulse" | "ExtendedBurn"

export type BoosterSizeId = "Small" | "Medium" | "Large"

export type BoosterRarityId = EngineRarityId

export type BoosterVariantId = "Balanced" | "HighThrust" | "EcoBurn" | "Lightweight" | "Overboost"

export type BaseBoosterSizeSpec = {
	SizeId: BoosterSizeId,
	DisplayName: string,
	BaseItemId: string, -- Modelo base 3D reutilizado (ej. "SmallBooster")
	Thrust: number, -- Empuje base SDD (Small=12000 confirmado)
	SpeedBoostMultiplier: number, -- Aumento de velocidad SDD (Small=1x confirmado)
	BoostConsumption: number, -- Consumo en potenciación SDD (Small=12000 confirmado)
	IntegratedFuel: number, -- RocketFuel integrado SDD (Small=24000 confirmado)
	Weight: number,
	MaxDurability: number,
	FuelType: FuelCategory,
	DrivingBonus: number,
	IgnitionRampSeconds: number,
	ShutdownRampSeconds: number,
	VisualScaleMultiplier: number,
	BalanceStatus: BalanceStatusTag,
}

export type BoosterVariantModifiers = {
	VariantId: BoosterVariantId,
	DisplayName: string,
	Description: string,
	ThrustDeltaRatio: number,
	SpeedBoostDelta: number,
	ConsumptionDeltaRatio: number,
	IntegratedFuelDeltaRatio: number,
	WeightDeltaRatio: number,
	DurabilityDeltaRatio: number,
	IgnitionRampDeltaRatio: number,
	BalanceStatus: BalanceStatusTag,
}

export type BoosterRarityModifiers = {
	RarityId: BoosterRarityId,
	DisplayName: string,
	RankOrder: number,
	ColorHex: string,
	ThrustBonusRatio: number,
	SpeedBoostBonus: number,
	EfficiencyBonusRatio: number,
	IntegratedFuelBonusRatio: number,
	WeightDeltaRatio: number,
	DurabilityBonusRatio: number,
	DrivingBonusMultiplier: number,
	BalanceStatus: BalanceStatusTag,
}

export type EffectiveBoosterStats = {
	BoosterFamilyId: BoosterFamilyId,
	BoosterSizeId: BoosterSizeId,
	VariantId: BoosterVariantId,
	RarityId: BoosterRarityId,
	BaseItemId: string,
	DisplayName: string,
	FullLabel: string,
	Thrust: number,
	SpeedBoostMultiplier: number,
	BoostConsumption: number,
	IntegratedFuel: number,
	EfficiencyFactor: number,
	Weight: number,
	MaxDurability: number,
	FuelType: FuelCategory,
	DrivingBonus: number,
	IgnitionRampSeconds: number,
	ShutdownRampSeconds: number,
	VisualScaleMultiplier: number,
	BalanceStatus: BalanceStatusTag,
	IsProvisionalBalance: boolean,
}

export type BoosterUnitRecord = {
	ItemInstanceId: string,
	OwnerUserId: number,
	ItemId: string,
	BoosterFamilyId: BoosterFamilyId,
	BoosterSizeId: BoosterSizeId,
	VariantId: BoosterVariantId,
	RarityId: BoosterRarityId,
	CreatedAt: number,
	SourceTag: string, -- "StarterKit" | "StarterDefault" | "DevTestGrant" | "FutureCrate"
	EffectiveStats: EffectiveBoosterStats,
}

-- Fase 5.1: Inventario central autoritativo y catálogo unificado
export type InventoryUnitSummary = {
	ItemInstanceId: string,
	ItemId: string,
	Category: ItemCategory,
	DisplayName: string,
	FullLabel: string,
	FamilyId: string,
	SizeId: string,
	VariantId: string,
	RarityId: string,
	UsedInWorkshop: boolean,
	ReferencedSlotIndices: { number },
	AvailableToPlaceInWorkshop: boolean,
	CanSell: boolean,
	CanSellForMoney: boolean?,
	SourceTag: string,
	CreatedAt: number,
	EffectiveStats: any,
}

export type InventoryItemEntry = {
	ItemId: string,
	DisplayName: string,
	Description: string,
	Category: ItemCategory,
	CategoryDisplayName: string,
	AssetFolder: string,
	InventoryKind: InventoryItemKind,
	Price: number?,
	SellPrice: number?,
	OwnedQuantity: number,
	WorkshopReservedQuantity: number,
	BlueprintMaxReferencedQuantity: number,
	LockedFromSale: number,
	AvailableToPlace: number,
	SellableQuantity: number,
	BlockedSlotIndices: { number },
}

export type PlayerInventorySnapshot = {
	OwnerUserId: number,
	InventoryRevision: number,
	StarterKitGranted: boolean,
	StarterKitVersion: number,
	Items: { InventoryItemEntry },
	ItemsById: { [string]: InventoryItemEntry },
	UniqueUnits: { InventoryUnitSummary },
	EngineUnits: { InventoryUnitSummary },
	BoosterUnits: { InventoryUnitSummary },
}

export type SerializedInventoryUnit = {
	ItemInstanceId: string,
	ItemId: string,
	Category: "Engines" | "Boosters",
	FamilyId: string,
	SizeId: string,
	VariantId: string,
	RarityId: string,
	CreatedAt: number,
	SourceTag: string,
}

export type PlayerInventoryStorage = {
	StorageSchemaVersion: number,
	OwnerUserId: number,
	InventoryRevision: number,
	UpdatedAt: number,
	StarterKitGranted: boolean,
	StarterKitVersion: number,
	Items: { [string]: number },
	UniqueUnits: { SerializedInventoryUnit },
}

-- Fase 5.2: Economía, Pedidos, Cajas Especiales, DeliveryZone e Ingresos Offline
export type PlayerEconomyStorage = {
	StorageSchemaVersion: number,
	OwnerUserId: number,
	Balance: number,
	StarterMoneyGranted: boolean,
	UpdatedAt: number,
	LastSeenAt: number,
	PendingOfflineAmount: number,
	PendingOfflineSeconds: number,
	PendingOfflineBreakdown: { { UnitId: string, Label: string, HourlyRate: number, Earned: number } },
	OfflineWindowStartAt: number,
	ProcessedTxIds: { string },
	ProcessedReceiptIds: { string },
}

export type OrderCrateStatus = "Queued" | "Spawned" | "Opened"

export type NormalOrderCrateRecord = {
	CrateId: string,
	OrderId: string,
	ItemId: string,
	Quantity: number,
	Status: OrderCrateStatus,
	SlotIndex: number?,
	OpenedAt: number?,
	CreditedToInventory: boolean,
}

export type NormalOrderLine = {
	ItemId: string,
	Quantity: number,
	UnitPrice: number,
	LineTotal: number,
}

export type NormalOrderStatus = "InTransit" | "Arrived" | "Collected"

export type NormalOrderRecord = {
	OrderId: string,
	OrderType: "Normal",
	OwnerUserId: number,
	Status: NormalOrderStatus,
	CreatedAt: number,
	ArriveAt: number,
	ArrivedAt: number?,
	DeliveryUnlocked: boolean,
	RushedByRobux: boolean,
	RushPurchaseId: string?,
	TotalCost: number,
	Lines: { NormalOrderLine },
	Crates: { NormalOrderCrateRecord },
	TruckAnimated: boolean?,
}

export type RolledLootReward = {
	BoxId: string,
	ItemId: string,
	Category: "Engines" | "Boosters",
	FamilyId: string,
	SizeId: string,
	VariantId: string,
	RarityId: string,
	ItemInstanceId: string,
	DisplayName: string,
	FullLabel: string,
	RolledAt: number,
	CreditedToInventory: boolean,
}

export type SpecialOrderStatus = "InTransit" | "Arrived" | "Opened" | "Claimed"

export type SpecialOrderRecord = {
	OrderId: string,
	OrderType: "Special",
	OwnerUserId: number,
	BoxId: string,
	RewardCategory: "Engines" | "Boosters",
	PricePaid: number,
	Status: SpecialOrderStatus,
	CreatedAt: number,
	ArriveAt: number,
	ArrivedAt: number?,
	RushedByRobux: boolean,
	RushPurchaseId: string?,
	SlotIndex: number?,
	OpeningStartedAt: number?,
	RolledReward: RolledLootReward?,
	TruckAnimated: boolean?,
}

export type PlayerOrdersStorage = {
	StorageSchemaVersion: number,
	OwnerUserId: number,
	OrdersRevision: number,
	UpdatedAt: number,
	ActiveNormalOrderId: string?,
	PendingRushOrderId: string?,
	NormalOrders: { NormalOrderRecord },
	SpecialOrders: { SpecialOrderRecord },
	ProcessedTxIds: { string },
}

export type BoxStockEntrySnapshot = {
	BoxId: string,
	DisplayName: string,
	Description: string,
	RewardCategory: "Engines" | "Boosters",
	Price: number?,
	Enabled: boolean,
	DisabledReason: string?,
	Stock: number,
	RestockMin: number,
	RestockMax: number,
	RarityWeights: { [string]: number },
	SizeWeights: { [string]: number },
}

return nil

