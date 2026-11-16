--!strict
--[=[
	SpecialCrateCatalogConfig
	Configuración declarativa centralizada del catálogo definitivo de 14 cajas especiales (Fase 5.3.3).

	Estructura:
	- Exactamente 4 familias comerciales/técnicas:
	    1. "GroundEngines"    (Terrestres · 8 cajas)
	    2. "Boosters"         (Propulsores · 4 cajas)
	    3. "PropellerEngines" (Hélices · 1 caja)
	    4. "JetEngines"       (Reacción · 1 caja)
	- Exactamente 14 cajas especiales ordenadas por progresión con precios obligatorios,
	  tiempos individuales de entrega y stock objetivo de reposición (`RestockQuantity`).
	- Cajas comprables con pool funcional actual:
	    * `BasicEngineCrate` -> `BasicEngineRewards` (Motores terrestres modulares existentes)
	    * `BasicBoosterCrate` -> `BasicBoosterRewards` (Propulsores cohete existentes)
	- Las demás 12 cajas permanecen con `Enabled = false` ("Próximamente") y `RewardPoolId = nil`
	  hasta implementar sus motores/propulsores funcionales correspondientes, sin inventar
	  recompensas ni alterar probabilidades.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)

export type CrateFamilyId = "GroundEngines" | "Boosters" | "PropellerEngines" | "JetEngines"
export type CrateFilterId = "All" | CrateFamilyId
export type CrateIconId = "GroundEngine" | "RocketBooster" | "Propeller" | "JetTurbine"

export type CrateFamilySpec = {
	FamilyId: CrateFamilyId,
	IconId: CrateIconId,
	Glyph: string,
	ImageAssetId: string,
	DisplayName: string,
	FilterLabel: string,
	ShortTag: string,
	AssetSubfolder: string,
	AccentColor: Color3,
	FamilyOrder: number,
}

export type RewardPoolDefinition = {
	PoolId: string,
	TargetCatalog: "Engines" | "Boosters",
	RarityWeights: { [string]: number },
	SizeWeights: { [string]: number },
	AllowedSizes: { string },
	AllowedFamilies: { string },
	AllowedVariants: { string },
	BalanceStatus: string,
}

export type SpecialCrateCatalogEntry = {
	BoxId: string,
	DisplayName: string,
	Description: string,
	Family: CrateFamilyId,
	ProgressionOrder: number,
	Price: number,
	DeliverySeconds: number,
	RestockQuantity: number,
	RestockIntervalSeconds: number,
	Enabled: boolean,
	DisabledReason: string?,
	RewardPoolId: string?,
	AssetSubfolder: string,
	AssetName: string,
	IconId: CrateIconId,
	BalanceStatus: string,
	RobuxSpeedupProductId: number?,
}

local DEFAULT_RARITY_WEIGHTS: { [string]: number } = table.freeze({
	Common = 55,
	Uncommon = 25,
	Rare = 12,
	Epic = 5,
	Legendary = 2.5,
	Mythic = 0.5,
})

local DEFAULT_SIZE_WEIGHTS: { [string]: number } = table.freeze({
	Small = 70,
	Medium = 25,
	Large = 5,
})

local FAMILIES_BY_ID: { [CrateFamilyId]: CrateFamilySpec } = table.freeze({
	GroundEngines = table.freeze({
		FamilyId = "GroundEngines" :: CrateFamilyId,
		IconId = "GroundEngine" :: CrateIconId,
		Glyph = "⚙",
		ImageAssetId = "rbxassetid://0",
		DisplayName = "Motores Terrestres",
		FilterLabel = "Terrestres",
		ShortTag = "TERRESTRES · MOTOR",
		AssetSubfolder = "Motores",
		AccentColor = Color3.fromRGB(242, 186, 42),
		FamilyOrder = 1,
	}),
	Boosters = table.freeze({
		FamilyId = "Boosters" :: CrateFamilyId,
		IconId = "RocketBooster" :: CrateIconId,
		Glyph = "🚀",
		ImageAssetId = "rbxassetid://0",
		DisplayName = "Propulsores",
		FilterLabel = "Propulsores",
		ShortTag = "PROPULSORES · COHETE",
		AssetSubfolder = "Propulsores",
		AccentColor = Color3.fromRGB(72, 196, 255),
		FamilyOrder = 2,
	}),
	PropellerEngines = table.freeze({
		FamilyId = "PropellerEngines" :: CrateFamilyId,
		IconId = "Propeller" :: CrateIconId,
		Glyph = "🛩",
		ImageAssetId = "rbxassetid://0",
		DisplayName = "Motores de Hélice",
		FilterLabel = "Hélices",
		ShortTag = "HÉLICES · AVIÓN",
		AssetSubfolder = "Helices",
		AccentColor = Color3.fromRGB(132, 238, 178),
		FamilyOrder = 3,
	}),
	JetEngines = table.freeze({
		FamilyId = "JetEngines" :: CrateFamilyId,
		IconId = "JetTurbine" :: CrateIconId,
		Glyph = "✈",
		ImageAssetId = "rbxassetid://0",
		DisplayName = "Motores a Reacción",
		FilterLabel = "Reacción",
		ShortTag = "REACCIÓN · TURBINA",
		AssetSubfolder = "Reaccion",
		AccentColor = Color3.fromRGB(244, 114, 182),
		FamilyOrder = 4,
	}),
})

local ORDERED_FAMILY_IDS: { CrateFamilyId } = table.freeze({
	"GroundEngines",
	"Boosters",
	"PropellerEngines",
	"JetEngines",
})

local REWARD_POOLS_BY_ID: { [string]: RewardPoolDefinition } = table.freeze({
	BasicEngineRewards = table.freeze({
		PoolId = "BasicEngineRewards",
		TargetCatalog = "Engines" :: "Engines",
		RarityWeights = DEFAULT_RARITY_WEIGHTS,
		SizeWeights = DEFAULT_SIZE_WEIGHTS,
		AllowedSizes = table.freeze({ "Small", "Medium", "Large" }),
		AllowedFamilies = table.freeze(EngineCatalog.GetOrderedFamilyIds()),
		AllowedVariants = table.freeze(EngineCatalog.GetOrderedVariantIds()),
		BalanceStatus = "PROVISIONAL_TBD",
	}),
	BasicBoosterRewards = table.freeze({
		PoolId = "BasicBoosterRewards",
		TargetCatalog = "Boosters" :: "Boosters",
		RarityWeights = DEFAULT_RARITY_WEIGHTS,
		SizeWeights = DEFAULT_SIZE_WEIGHTS,
		AllowedSizes = table.freeze({ "Small", "Medium", "Large" }),
		AllowedFamilies = table.freeze(BoosterCatalog.GetOrderedFamilyIds()),
		AllowedVariants = table.freeze(BoosterCatalog.GetOrderedVariantIds()),
		BalanceStatus = "PROVISIONAL_TBD",
	}),
})

local CRATE_ENTRIES: { SpecialCrateCatalogEntry } = table.freeze({
	-- === A. MOTORES TERRESTRES (8 CAJAS) ===
	table.freeze({
		BoxId = "BasicEngineCrate",
		DisplayName = "Caja de motor básica",
		Description = "Entrega un motor terrestre modular funcional (Pequeño, Mediano o Grande) con rareza desde Común hasta Mítico.",
		Family = "GroundEngines" :: CrateFamilyId,
		ProgressionOrder = 1,
		Price = 80,
		DeliverySeconds = 15,
		RestockQuantity = 10,
		RestockIntervalSeconds = 300,
		Enabled = true,
		DisabledReason = nil,
		RewardPoolId = "BasicEngineRewards",
		AssetSubfolder = "Motores",
		AssetName = "BasicEngineCrate",
		IconId = "GroundEngine" :: CrateIconId,
		BalanceStatus = "CONFIRMED_PRICE_PROVISIONAL_POOL",
		RobuxSpeedupProductId = nil,
	}),
	table.freeze({
		BoxId = "RoadEngineCrate",
		DisplayName = "Caja de motor de carretera",
		Description = "Nivel 2 de motores terrestres. Pendiente de implementar motores dedicados y tabla de recompensas verificada.",
		Family = "GroundEngines" :: CrateFamilyId,
		ProgressionOrder = 2,
		Price = 850,
		DeliverySeconds = 20,
		RestockQuantity = 8,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Motores de carretera y pool de recompensas en desarrollo.",
		RewardPoolId = nil,
		AssetSubfolder = "Motores",
		AssetName = "RoadEngineCrate",
		IconId = "GroundEngine" :: CrateIconId,
		BalanceStatus = "TBD_REWARDS_DISABLED",
		RobuxSpeedupProductId = nil,
	}),
	table.freeze({
		BoxId = "WorkshopEngineCrate",
		DisplayName = "Caja de motor de taller",
		Description = "Nivel 3 de motores terrestres. Pendiente de implementar motores de taller y tabla de recompensas verificada.",
		Family = "GroundEngines" :: CrateFamilyId,
		ProgressionOrder = 3,
		Price = 2500,
		DeliverySeconds = 40,
		RestockQuantity = 5,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Motores de taller y pool de recompensas en desarrollo.",
		RewardPoolId = nil,
		AssetSubfolder = "Motores",
		AssetName = "WorkshopEngineCrate",
		IconId = "GroundEngine" :: CrateIconId,
		BalanceStatus = "TBD_REWARDS_DISABLED",
		RobuxSpeedupProductId = nil,
	}),
	table.freeze({
		BoxId = "TunedEngineCrate",
		DisplayName = "Caja de motor ajustada",
		Description = "Nivel 4 de motores terrestres. Pendiente de implementar motores ajustados y tabla de recompensas verificada.",
		Family = "GroundEngines" :: CrateFamilyId,
		ProgressionOrder = 4,
		Price = 15000,
		DeliverySeconds = 90,
		RestockQuantity = 3,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Motores ajustados y pool de recompensas en desarrollo.",
		RewardPoolId = nil,
		AssetSubfolder = "Motores",
		AssetName = "TunedEngineCrate",
		IconId = "GroundEngine" :: CrateIconId,
		BalanceStatus = "TBD_REWARDS_DISABLED",
		RobuxSpeedupProductId = nil,
	}),
	table.freeze({
		BoxId = "PerformanceEngineCrate",
		DisplayName = "Caja de motor de rendimiento",
		Description = "Nivel 5 de motores terrestres. Pendiente de implementar motores de rendimiento y tabla de recompensas verificada.",
		Family = "GroundEngines" :: CrateFamilyId,
		ProgressionOrder = 5,
		Price = 38000,
		DeliverySeconds = 240,
		RestockQuantity = 4,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Motores de rendimiento y pool de recompensas en desarrollo.",
		RewardPoolId = nil,
		AssetSubfolder = "Motores",
		AssetName = "PerformanceEngineCrate",
		IconId = "GroundEngine" :: CrateIconId,
		BalanceStatus = "TBD_REWARDS_DISABLED",
		RobuxSpeedupProductId = nil,
	}),
	table.freeze({
		BoxId = "AdvancedEngineCrate",
		DisplayName = "Caja de motor avanzada",
		Description = "Nivel 6 de motores terrestres. Pendiente de implementar motores avanzados y tabla de recompensas verificada.",
		Family = "GroundEngines" :: CrateFamilyId,
		ProgressionOrder = 6,
		Price = 220000,
		DeliverySeconds = 720,
		RestockQuantity = 2,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Motores avanzados y pool de recompensas en desarrollo.",
		RewardPoolId = nil,
		AssetSubfolder = "Motores",
		AssetName = "AdvancedEngineCrate",
		IconId = "GroundEngine" :: CrateIconId,
		BalanceStatus = "TBD_REWARDS_DISABLED",
		RobuxSpeedupProductId = nil,
	}),
	table.freeze({
		BoxId = "UltimateEngineCrate",
		DisplayName = "Caja de motor definitiva",
		Description = "Nivel 7 de motores terrestres. Pendiente de implementar motores definitivos y tabla de recompensas verificada.",
		Family = "GroundEngines" :: CrateFamilyId,
		ProgressionOrder = 7,
		Price = 900000,
		DeliverySeconds = 900,
		RestockQuantity = 2,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Motores definitivos y pool de recompensas en desarrollo.",
		RewardPoolId = nil,
		AssetSubfolder = "Motores",
		AssetName = "UltimateEngineCrate",
		IconId = "GroundEngine" :: CrateIconId,
		BalanceStatus = "TBD_REWARDS_DISABLED",
		RobuxSpeedupProductId = nil,
	}),
	table.freeze({
		BoxId = "TrackEngineCrate",
		DisplayName = "Caja de motor de pista",
		Description = "Nivel 8 de motores terrestres de élite. Pendiente de implementar motores de pista y tabla de recompensas verificada.",
		Family = "GroundEngines" :: CrateFamilyId,
		ProgressionOrder = 8,
		Price = 2500000,
		DeliverySeconds = 900,
		RestockQuantity = 1,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Motores de pista y pool de recompensas en desarrollo.",
		RewardPoolId = nil,
		AssetSubfolder = "Motores",
		AssetName = "TrackEngineCrate",
		IconId = "GroundEngine" :: CrateIconId,
		BalanceStatus = "TBD_REWARDS_DISABLED",
		RobuxSpeedupProductId = nil,
	}),

	-- === B. PROPULSORES (4 CAJAS) ===
	table.freeze({
		BoxId = "BasicBoosterCrate",
		DisplayName = "Caja de refuerzo básica",
		Description = "Entrega un propulsor cohete modular único (Pequeño, Mediano o Grande) con rareza desde Común hasta Mítico.",
		Family = "Boosters" :: CrateFamilyId,
		ProgressionOrder = 1,
		Price = 45000,
		DeliverySeconds = 300,
		RestockQuantity = 4,
		RestockIntervalSeconds = 300,
		Enabled = true,
		DisabledReason = nil,
		RewardPoolId = "BasicBoosterRewards",
		AssetSubfolder = "Propulsores",
		AssetName = "BasicBoosterCrate",
		IconId = "RocketBooster" :: CrateIconId,
		BalanceStatus = "CONFIRMED_PRICE_PROVISIONAL_POOL",
		RobuxSpeedupProductId = nil,
	}),
	table.freeze({
		BoxId = "PerformanceBoosterCrate",
		DisplayName = "Caja de potenciadores de rendimiento",
		Description = "Nivel 2 de propulsores. Pendiente de implementar propulsores de alto rendimiento y pool verificado.",
		Family = "Boosters" :: CrateFamilyId,
		ProgressionOrder = 2,
		Price = 220000,
		DeliverySeconds = 720,
		RestockQuantity = 3,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Propulsores de rendimiento y pool de recompensas en desarrollo.",
		RewardPoolId = nil,
		AssetSubfolder = "Propulsores",
		AssetName = "PerformanceBoosterCrate",
		IconId = "RocketBooster" :: CrateIconId,
		BalanceStatus = "TBD_REWARDS_DISABLED",
		RobuxSpeedupProductId = nil,
	}),
	table.freeze({
		BoxId = "UltimateBoosterCrate",
		DisplayName = "Caja de refuerzo definitiva",
		Description = "Nivel 3 de propulsores. Pendiente de implementar propulsores definitivos y pool verificado.",
		Family = "Boosters" :: CrateFamilyId,
		ProgressionOrder = 3,
		Price = 950000,
		DeliverySeconds = 900,
		RestockQuantity = 1,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Propulsores definitivos y pool de recompensas en desarrollo.",
		RewardPoolId = nil,
		AssetSubfolder = "Propulsores",
		AssetName = "UltimateBoosterCrate",
		IconId = "RocketBooster" :: CrateIconId,
		BalanceStatus = "TBD_REWARDS_DISABLED",
		RobuxSpeedupProductId = nil,
	}),
	table.freeze({
		BoxId = "SpecialBoosterCrate",
		DisplayName = "Caja de refuerzo especial",
		Description = "Nivel 4 de propulsores de élite. Pendiente de implementar propulsores especiales y pool verificado.",
		Family = "Boosters" :: CrateFamilyId,
		ProgressionOrder = 4,
		Price = 2500000,
		DeliverySeconds = 900,
		RestockQuantity = 2,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Propulsores especiales y pool de recompensas en desarrollo.",
		RewardPoolId = nil,
		AssetSubfolder = "Propulsores",
		AssetName = "SpecialBoosterCrate",
		IconId = "RocketBooster" :: CrateIconId,
		BalanceStatus = "TBD_REWARDS_DISABLED",
		RobuxSpeedupProductId = nil,
	}),

	-- === C. MOTORES DE HÉLICE (1 CAJA) ===
	table.freeze({
		BoxId = "AircraftPropellerCrate",
		DisplayName = "Caja de motor de avión",
		Description = "Caja de motores aeronáuticos de hélice. Se habilitará cuando los motores de hélice sean funcionales en construcción y física.",
		Family = "PropellerEngines" :: CrateFamilyId,
		ProgressionOrder = 1,
		Price = 1250000,
		DeliverySeconds = 900,
		RestockQuantity = 2,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Motores de hélice pendientes de implementación funcional.",
		RewardPoolId = nil,
		AssetSubfolder = "Helices",
		AssetName = "AircraftPropellerCrate",
		IconId = "Propeller" :: CrateIconId,
		BalanceStatus = "TBD_FUTURE_MECHANIC_DISABLED",
		RobuxSpeedupProductId = nil,
	}),

	-- === D. MOTORES A REACCIÓN (1 CAJA) ===
	table.freeze({
		BoxId = "JetEngineCrate",
		DisplayName = "Caja de motor a reacción",
		Description = "Caja de turbinas a reacción de máxima potencia. Se habilitará cuando los reactores sean funcionales en construcción y física.",
		Family = "JetEngines" :: CrateFamilyId,
		ProgressionOrder = 1,
		Price = 10000000,
		DeliverySeconds = 900,
		RestockQuantity = 1,
		RestockIntervalSeconds = 300,
		Enabled = false,
		DisabledReason = "Próximamente · Motores a reacción pendientes de implementación funcional.",
		RewardPoolId = nil,
		AssetSubfolder = "Reaccion",
		AssetName = "JetEngineCrate",
		IconId = "JetTurbine" :: CrateIconId,
		BalanceStatus = "TBD_FUTURE_MECHANIC_DISABLED",
		RobuxSpeedupProductId = nil,
	}),
})

local ENTRIES_BY_ID: { [string]: SpecialCrateCatalogEntry } = {}
local ORDERED_BOX_IDS_LIST: { string } = table.create(#CRATE_ENTRIES)
for _, entry in ipairs(CRATE_ENTRIES) do
	if ENTRIES_BY_ID[entry.BoxId] ~= nil then
		error(`[SpecialCrateCatalogConfig] Duplicate BoxId '{entry.BoxId}'`)
	end
	ENTRIES_BY_ID[entry.BoxId] = entry
	table.insert(ORDERED_BOX_IDS_LIST, entry.BoxId)
end
table.freeze(ENTRIES_BY_ID)
table.freeze(ORDERED_BOX_IDS_LIST)

local SpecialCrateCatalogConfig = {}

function SpecialCrateCatalogConfig.GetEntries(): { SpecialCrateCatalogEntry }
	return CRATE_ENTRIES
end

function SpecialCrateCatalogConfig.GetEntry(boxId: string): SpecialCrateCatalogEntry?
	return ENTRIES_BY_ID[boxId]
end

function SpecialCrateCatalogConfig.GetOrderedBoxIds(): { string }
	return ORDERED_BOX_IDS_LIST
end

function SpecialCrateCatalogConfig.GetFamilySpec(familyId: string): CrateFamilySpec
	local direct = FAMILIES_BY_ID[familyId :: CrateFamilyId]
	if direct then
		return direct
	end
	if familyId == "Engines" then
		return FAMILIES_BY_ID.GroundEngines
	elseif familyId == "AircraftEngines" then
		return FAMILIES_BY_ID.PropellerEngines
	end
	return FAMILIES_BY_ID.GroundEngines
end

function SpecialCrateCatalogConfig.NormalizeFamilyId(familyId: string): CrateFamilyId?
	if FAMILIES_BY_ID[familyId :: CrateFamilyId] then
		return familyId :: CrateFamilyId
	end
	if familyId == "Engines" then
		return "GroundEngines"
	elseif familyId == "AircraftEngines" then
		return "PropellerEngines"
	end
	return nil
end

function SpecialCrateCatalogConfig.GetOrderedFamilies(): { CrateFamilySpec }
	local out: { CrateFamilySpec } = table.create(#ORDERED_FAMILY_IDS)
	for _, famId in ipairs(ORDERED_FAMILY_IDS) do
		table.insert(out, FAMILIES_BY_ID[famId])
	end
	return out
end

function SpecialCrateCatalogConfig.GetRewardPool(poolId: string?): RewardPoolDefinition?
	if type(poolId) ~= "string" or #poolId == 0 then
		return nil
	end
	return REWARD_POOLS_BY_ID[poolId]
end

return SpecialCrateCatalogConfig
