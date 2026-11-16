--!strict
--[=[
	BoosterCatalog
	Catálogo centralizado de familias, tamaños, variantes y rarezas de propulsores (Fase 3.4).

	Fuentes SDD:
	- VehicleSandbox_SDD/docs/04-ITEM-CATALOG.md
	  Confirmado para SmallBooster:
	    DrivingBonus = 0.3 (+0.3x), FuelType = "RocketFuel",
	    IntegratedFuel = 24000, BoostConsumption = 12000,
	    Thrust = 12000, SpeedBoostMultiplier = 1 (1x),
	    Weight = 12, MaxDurability = 130, Price = TBD (nil).
	- VehicleSandbox_SDD/docs/06-ECONOMY-CRATES-DELIVERIES.md:
	  Sistema de 6 rarezas (Common, Uncommon, Rare, Epic, Legendary, Mythic).

	Importante:
	- Todo parámetro sin cifra definitiva en el SDD se etiqueta explícitamente con
	  BalanceStatus = "Provisional_TBD" para recalibración transparente sin romper contratos.
	- Cualquier propulsor físico colocado sin unidad de inventario explícita resuelve exactamente
	  a Small + StandardRocket + Balanced + Common (idéntico a SmallBooster confirmado en SDD).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

export type BoosterFamilySpec = {
	FamilyId: ItemTypes.BoosterFamilyId,
	DisplayName: string,
	Description: string,
	ThrustMultiplier: number,
	SpeedBoostMultiplierFactor: number,
	ConsumptionMultiplier: number,
	IntegratedFuelMultiplier: number,
	WeightMultiplier: number,
	IgnitionRampMultiplier: number,
	BalanceStatus: ItemTypes.BalanceStatusTag,
}

export type ResolveBoosterSpecInput = {
	ItemId: string?,
	BoosterFamilyId: string?,
	BoosterSizeId: string?,
	VariantId: string?,
	RarityId: string?,
}

local ORDERED_SIZE_IDS: { ItemTypes.BoosterSizeId } = { "Small", "Medium", "Large" }
local ORDERED_RARITY_IDS: { ItemTypes.BoosterRarityId } = {
	"Common",
	"Uncommon",
	"Rare",
	"Epic",
	"Legendary",
	"Mythic",
}
local ORDERED_VARIANT_IDS: { ItemTypes.BoosterVariantId } = {
	"Balanced",
	"HighThrust",
	"EcoBurn",
	"Lightweight",
	"Overboost",
}
local ORDERED_FAMILY_IDS: { ItemTypes.BoosterFamilyId } = {
	"StandardRocket",
	"HighImpulse",
	"ExtendedBurn",
}

local BOOSTER_FAMILIES: { [ItemTypes.BoosterFamilyId]: BoosterFamilySpec } = {
	StandardRocket = {
		FamilyId = "StandardRocket",
		DisplayName = "Cohete Modular Estándar",
		Description = "Propulsor químico de combustible RocketFuel con empuje lineal y encendido estable.",
		ThrustMultiplier = 1.00,
		SpeedBoostMultiplierFactor = 1.00,
		ConsumptionMultiplier = 1.00,
		IntegratedFuelMultiplier = 1.00,
		WeightMultiplier = 1.00,
		IgnitionRampMultiplier = 1.00,
		BalanceStatus = "SDD_Confirmed",
	},
	HighImpulse = {
		FamilyId = "HighImpulse",
		DisplayName = "Impulso Rápido",
		Description = "Tobera de alta presión con mayor empuje instantáneo y encendido más agresivo (Provisional TBD).",
		ThrustMultiplier = 1.18,
		SpeedBoostMultiplierFactor = 1.10,
		ConsumptionMultiplier = 1.20,
		IntegratedFuelMultiplier = 0.92,
		WeightMultiplier = 1.08,
		IgnitionRampMultiplier = 0.78,
		BalanceStatus = "Provisional_TBD",
	},
	ExtendedBurn = {
		FamilyId = "ExtendedBurn",
		DisplayName = "Combustión Sostenida",
		Description = "Cámara optimizada para autonomía extendida y menor consumo por segundo de Nitro (Provisional TBD).",
		ThrustMultiplier = 0.88,
		SpeedBoostMultiplierFactor = 0.96,
		ConsumptionMultiplier = 0.78,
		IntegratedFuelMultiplier = 1.25,
		WeightMultiplier = 0.96,
		IgnitionRampMultiplier = 1.15,
		BalanceStatus = "Provisional_TBD",
	},
}

local BOOSTER_SIZES: { [ItemTypes.BoosterSizeId]: ItemTypes.BaseBoosterSizeSpec } = {
	Small = {
		SizeId = "Small",
		DisplayName = "Propulsor Pequeño",
		BaseItemId = "SmallBooster",
		-- Valores exactos confirmados en SDD (docs/04-ITEM-CATALOG.md):
		Thrust = 12000,
		SpeedBoostMultiplier = 1,
		BoostConsumption = 12000,
		IntegratedFuel = 24000,
		Weight = 12,
		MaxDurability = 130,
		FuelType = "RocketFuel",
		DrivingBonus = 0.3,
		-- Curvas temporales y escala visual (Provisional TBD de simulación)
		IgnitionRampSeconds = 0.14,
		ShutdownRampSeconds = 0.16,
		VisualScaleMultiplier = 1.00,
		BalanceStatus = "SDD_Confirmed",
	},
	Medium = {
		SizeId = "Medium",
		DisplayName = "Propulsor Mediano",
		BaseItemId = "SmallBooster", -- Reutiliza el modelo 3D base sin requerir asset nuevo obligatorio
		Thrust = 24000,
		SpeedBoostMultiplier = 1.35,
		BoostConsumption = 21600,
		IntegratedFuel = 48000,
		Weight = 22,
		MaxDurability = 190,
		FuelType = "RocketFuel",
		DrivingBonus = 0.55,
		IgnitionRampSeconds = 0.22,
		ShutdownRampSeconds = 0.24,
		VisualScaleMultiplier = 1.15,
		BalanceStatus = "Provisional_TBD",
	},
	Large = {
		SizeId = "Large",
		DisplayName = "Propulsor Grande",
		BaseItemId = "SmallBooster", -- Reutiliza el modelo 3D base sin requerir asset nuevo obligatorio
		Thrust = 42000,
		SpeedBoostMultiplier = 1.75,
		BoostConsumption = 34000,
		IntegratedFuel = 84000,
		Weight = 36,
		MaxDurability = 280,
		FuelType = "RocketFuel",
		DrivingBonus = 0.90,
		IgnitionRampSeconds = 0.32,
		ShutdownRampSeconds = 0.34,
		VisualScaleMultiplier = 1.30,
		BalanceStatus = "Provisional_TBD",
	},
}

local BOOSTER_VARIANTS: { [ItemTypes.BoosterVariantId]: ItemTypes.BoosterVariantModifiers } = {
	Balanced = {
		VariantId = "Balanced",
		DisplayName = "Estándar Equilibrado",
		Description = "Calibración base de fábrica con relación exacta entre empuje, autonomía Nitro y peso.",
		ThrustDeltaRatio = 0.00,
		SpeedBoostDelta = 0.00,
		ConsumptionDeltaRatio = 0.00,
		IntegratedFuelDeltaRatio = 0.00,
		WeightDeltaRatio = 0.00,
		DurabilityDeltaRatio = 0.00,
		IgnitionRampDeltaRatio = 0.00,
		BalanceStatus = "SDD_Confirmed",
	},
	HighThrust = {
		VariantId = "HighThrust",
		DisplayName = "Alto Empuje",
		Description = "Aumenta la fuerza máxima de vectorización y la respuesta de ignición con mayor gasto de Nitro.",
		ThrustDeltaRatio = 0.22,
		SpeedBoostDelta = 0.12,
		ConsumptionDeltaRatio = 0.18,
		IntegratedFuelDeltaRatio = -0.05,
		WeightDeltaRatio = 0.10,
		DurabilityDeltaRatio = 0.08,
		IgnitionRampDeltaRatio = -0.18,
		BalanceStatus = "Provisional_TBD",
	},
	EcoBurn = {
		VariantId = "EcoBurn",
		DisplayName = "Quemado Eficiente",
		Description = "Reduce sustancialmente el consumo de Nitro e incrementa el depósito integrado con menor pico de empuje.",
		ThrustDeltaRatio = -0.10,
		SpeedBoostDelta = -0.04,
		ConsumptionDeltaRatio = -0.24,
		IntegratedFuelDeltaRatio = 0.20,
		WeightDeltaRatio = -0.04,
		DurabilityDeltaRatio = 0.05,
		IgnitionRampDeltaRatio = 0.10,
		BalanceStatus = "Provisional_TBD",
	},
	Lightweight = {
		VariantId = "Lightweight",
		DisplayName = "Aligerado Aeroespacial",
		Description = "Carcasa ultraliviana con encendido rápido para maniobras de agilidad y despegues ligeros.",
		ThrustDeltaRatio = -0.06,
		SpeedBoostDelta = 0.08,
		ConsumptionDeltaRatio = -0.08,
		IntegratedFuelDeltaRatio = -0.10,
		WeightDeltaRatio = -0.22,
		DurabilityDeltaRatio = -0.06,
		IgnitionRampDeltaRatio = -0.24,
		BalanceStatus = "Provisional_TBD",
	},
	Overboost = {
		VariantId = "Overboost",
		DisplayName = "Sobreempuje Competición",
		Description = "Entrega extrema de empuje y velocidad tope a costa de alto consumo de Nitro y mayor masa.",
		ThrustDeltaRatio = 0.32,
		SpeedBoostDelta = 0.25,
		ConsumptionDeltaRatio = 0.34,
		IntegratedFuelDeltaRatio = 0.05,
		WeightDeltaRatio = 0.14,
		DurabilityDeltaRatio = -0.10,
		IgnitionRampDeltaRatio = -0.28,
		BalanceStatus = "Provisional_TBD",
	},
}

local BOOSTER_RARITIES: { [ItemTypes.BoosterRarityId]: ItemTypes.BoosterRarityModifiers } = {
	Common = {
		RarityId = "Common",
		DisplayName = "Común",
		RankOrder = 1,
		ColorHex = "#B0B8C4",
		ThrustBonusRatio = 0.00,
		SpeedBoostBonus = 0.00,
		EfficiencyBonusRatio = 0.00,
		IntegratedFuelBonusRatio = 0.00,
		WeightDeltaRatio = 0.00,
		DurabilityBonusRatio = 0.00,
		DrivingBonusMultiplier = 1.00,
		BalanceStatus = "SDD_Confirmed",
	},
	Uncommon = {
		RarityId = "Uncommon",
		DisplayName = "No común",
		RankOrder = 2,
		ColorHex = "#4ADE80",
		ThrustBonusRatio = 0.06,
		SpeedBoostBonus = 0.05,
		EfficiencyBonusRatio = 0.04,
		IntegratedFuelBonusRatio = 0.06,
		WeightDeltaRatio = -0.02,
		DurabilityBonusRatio = 0.06,
		DrivingBonusMultiplier = 1.15,
		BalanceStatus = "Provisional_TBD",
	},
	Rare = {
		RarityId = "Rare",
		DisplayName = "Raro",
		RankOrder = 3,
		ColorHex = "#38BDF8",
		ThrustBonusRatio = 0.13,
		SpeedBoostBonus = 0.12,
		EfficiencyBonusRatio = 0.08,
		IntegratedFuelBonusRatio = 0.12,
		WeightDeltaRatio = -0.04,
		DurabilityBonusRatio = 0.14,
		DrivingBonusMultiplier = 1.35,
		BalanceStatus = "Provisional_TBD",
	},
	Epic = {
		RarityId = "Epic",
		DisplayName = "Épico",
		RankOrder = 4,
		ColorHex = "#C084FC",
		ThrustBonusRatio = 0.22,
		SpeedBoostBonus = 0.22,
		EfficiencyBonusRatio = 0.13,
		IntegratedFuelBonusRatio = 0.20,
		WeightDeltaRatio = -0.07,
		DurabilityBonusRatio = 0.24,
		DrivingBonusMultiplier = 1.60,
		BalanceStatus = "Provisional_TBD",
	},
	Legendary = {
		RarityId = "Legendary",
		DisplayName = "Legendario",
		RankOrder = 5,
		ColorHex = "#FBBF24",
		ThrustBonusRatio = 0.34,
		SpeedBoostBonus = 0.35,
		EfficiencyBonusRatio = 0.19,
		IntegratedFuelBonusRatio = 0.30,
		WeightDeltaRatio = -0.10,
		DurabilityBonusRatio = 0.36,
		DrivingBonusMultiplier = 1.95,
		BalanceStatus = "Provisional_TBD",
	},
	Mythic = {
		RarityId = "Mythic",
		DisplayName = "Mítico",
		RankOrder = 6,
		ColorHex = "#F43F5E",
		ThrustBonusRatio = 0.48,
		SpeedBoostBonus = 0.50,
		EfficiencyBonusRatio = 0.26,
		IntegratedFuelBonusRatio = 0.42,
		WeightDeltaRatio = -0.14,
		DurabilityBonusRatio = 0.50,
		DrivingBonusMultiplier = 2.40,
		BalanceStatus = "Provisional_TBD",
	},
}

local function roundTo(value: number, decimals: number): number
	local factor = 10 ^ decimals
	return math.round(value * factor) / factor
end

local BoosterCatalog = {}

for _, fam in pairs(BOOSTER_FAMILIES) do
	table.freeze(fam)
end
table.freeze(BOOSTER_FAMILIES)

for _, sz in pairs(BOOSTER_SIZES) do
	table.freeze(sz)
end
table.freeze(BOOSTER_SIZES)

for _, varSpec in pairs(BOOSTER_VARIANTS) do
	table.freeze(varSpec)
end
table.freeze(BOOSTER_VARIANTS)

for _, rarSpec in pairs(BOOSTER_RARITIES) do
	table.freeze(rarSpec)
end
table.freeze(BOOSTER_RARITIES)

table.freeze(ORDERED_SIZE_IDS)
table.freeze(ORDERED_RARITY_IDS)
table.freeze(ORDERED_VARIANT_IDS)
table.freeze(ORDERED_FAMILY_IDS)

function BoosterCatalog.IsValidFamilyId(id: any): boolean
	return type(id) == "string" and BOOSTER_FAMILIES[id :: ItemTypes.BoosterFamilyId] ~= nil
end

function BoosterCatalog.IsValidSizeId(id: any): boolean
	return type(id) == "string" and BOOSTER_SIZES[id :: ItemTypes.BoosterSizeId] ~= nil
end

function BoosterCatalog.IsValidVariantId(id: any): boolean
	return type(id) == "string" and BOOSTER_VARIANTS[id :: ItemTypes.BoosterVariantId] ~= nil
end

function BoosterCatalog.IsValidRarityId(id: any): boolean
	return type(id) == "string" and BOOSTER_RARITIES[id :: ItemTypes.BoosterRarityId] ~= nil
end

function BoosterCatalog.GetOrderedSizeIds(): { ItemTypes.BoosterSizeId }
	return ORDERED_SIZE_IDS
end

function BoosterCatalog.GetOrderedRarityIds(): { ItemTypes.BoosterRarityId }
	return ORDERED_RARITY_IDS
end

function BoosterCatalog.GetOrderedVariantIds(): { ItemTypes.BoosterVariantId }
	return ORDERED_VARIANT_IDS
end

function BoosterCatalog.GetOrderedFamilyIds(): { ItemTypes.BoosterFamilyId }
	return ORDERED_FAMILY_IDS
end

function BoosterCatalog.GetSizeSpec(sizeId: ItemTypes.BoosterSizeId): ItemTypes.BaseBoosterSizeSpec
	local spec = BOOSTER_SIZES[sizeId]
	if not spec then
		error(`[BoosterCatalog] Unknown BoosterSizeId '{tostring(sizeId)}'`, 2)
	end
	return spec
end

function BoosterCatalog.GetVariantSpec(variantId: ItemTypes.BoosterVariantId): ItemTypes.BoosterVariantModifiers
	local spec = BOOSTER_VARIANTS[variantId]
	if not spec then
		error(`[BoosterCatalog] Unknown BoosterVariantId '{tostring(variantId)}'`, 2)
	end
	return spec
end

function BoosterCatalog.GetRaritySpec(rarityId: ItemTypes.BoosterRarityId): ItemTypes.BoosterRarityModifiers
	local spec = BOOSTER_RARITIES[rarityId]
	if not spec then
		error(`[BoosterCatalog] Unknown BoosterRarityId '{tostring(rarityId)}'`, 2)
	end
	return spec
end

function BoosterCatalog.GetFamilySpec(familyId: ItemTypes.BoosterFamilyId): BoosterFamilySpec
	local spec = BOOSTER_FAMILIES[familyId]
	if not spec then
		error(`[BoosterCatalog] Unknown BoosterFamilyId '{tostring(familyId)}'`, 2)
	end
	return spec
end

function BoosterCatalog.ResolveEffectiveStats(input: ResolveBoosterSpecInput?): ItemTypes.EffectiveBoosterStats
	local opts = input or {}

	local rawSize = opts.BoosterSizeId
	if not rawSize and opts.ItemId == "MediumBooster" then
		rawSize = "Medium"
	elseif not rawSize and opts.ItemId == "LargeBooster" then
		rawSize = "Large"
	end

	local familyId: ItemTypes.BoosterFamilyId = if BoosterCatalog.IsValidFamilyId(opts.BoosterFamilyId)
		then (opts.BoosterFamilyId :: ItemTypes.BoosterFamilyId)
		else "StandardRocket"
	local sizeId: ItemTypes.BoosterSizeId = if BoosterCatalog.IsValidSizeId(rawSize)
		then (rawSize :: ItemTypes.BoosterSizeId)
		else "Small"
	local variantId: ItemTypes.BoosterVariantId = if BoosterCatalog.IsValidVariantId(opts.VariantId)
		then (opts.VariantId :: ItemTypes.BoosterVariantId)
		else "Balanced"
	local rarityId: ItemTypes.BoosterRarityId = if BoosterCatalog.IsValidRarityId(opts.RarityId)
		then (opts.RarityId :: ItemTypes.BoosterRarityId)
		else "Common"

	local family = BOOSTER_FAMILIES[familyId]
	local base = BOOSTER_SIZES[sizeId]
	local variant = BOOSTER_VARIANTS[variantId]
	local rarity = BOOSTER_RARITIES[rarityId]

	local thrust = roundTo(
		base.Thrust * family.ThrustMultiplier * (1 + variant.ThrustDeltaRatio) * (1 + rarity.ThrustBonusRatio),
		2
	)
	local speedBoostMultiplier = roundTo(
		math.max(0.4, base.SpeedBoostMultiplier * family.SpeedBoostMultiplierFactor + variant.SpeedBoostDelta + rarity.SpeedBoostBonus),
		3
	)
	local efficiencyFactor = roundTo(
		math.max(0.4, (1 + rarity.EfficiencyBonusRatio) / math.max(0.4, family.ConsumptionMultiplier * (1 + variant.ConsumptionDeltaRatio))),
		4
	)
	local boostConsumption = roundTo(
		math.max(100, base.BoostConsumption / efficiencyFactor),
		2
	)
	local integratedFuel = roundTo(
		math.max(100, base.IntegratedFuel * family.IntegratedFuelMultiplier * (1 + variant.IntegratedFuelDeltaRatio) * (1 + rarity.IntegratedFuelBonusRatio)),
		2
	)
	local weight = roundTo(
		math.max(2.0, base.Weight * family.WeightMultiplier * (1 + variant.WeightDeltaRatio) * (1 + rarity.WeightDeltaRatio)),
		2
	)
	local maxDurability = math.max(
		20,
		math.round(base.MaxDurability * (1 + variant.DurabilityDeltaRatio) * (1 + rarity.DurabilityBonusRatio))
	)
	local drivingBonus = roundTo(base.DrivingBonus * rarity.DrivingBonusMultiplier, 6)
	local ignitionRampSeconds = roundTo(
		math.max(0.03, base.IgnitionRampSeconds * family.IgnitionRampMultiplier * (1 + variant.IgnitionRampDeltaRatio)),
		3
	)
	local shutdownRampSeconds = roundTo(
		math.max(0.04, base.ShutdownRampSeconds * family.IgnitionRampMultiplier * (1 + variant.IgnitionRampDeltaRatio * 0.5)),
		3
	)

	local isProvisional = family.BalanceStatus == "Provisional_TBD"
		or base.BalanceStatus == "Provisional_TBD"
		or variant.BalanceStatus == "Provisional_TBD"
		or rarity.BalanceStatus == "Provisional_TBD"

	local fullLabel = `{base.DisplayName} [{rarity.DisplayName} · {variant.DisplayName}]`

	local resolved: ItemTypes.EffectiveBoosterStats = {
		BoosterFamilyId = familyId,
		BoosterSizeId = sizeId,
		VariantId = variantId,
		RarityId = rarityId,
		BaseItemId = base.BaseItemId,
		DisplayName = base.DisplayName,
		FullLabel = fullLabel,
		Thrust = thrust,
		SpeedBoostMultiplier = speedBoostMultiplier,
		BoostConsumption = boostConsumption,
		IntegratedFuel = integratedFuel,
		EfficiencyFactor = efficiencyFactor,
		Weight = weight,
		MaxDurability = maxDurability,
		FuelType = base.FuelType,
		DrivingBonus = drivingBonus,
		IgnitionRampSeconds = ignitionRampSeconds,
		ShutdownRampSeconds = shutdownRampSeconds,
		VisualScaleMultiplier = base.VisualScaleMultiplier,
		BalanceStatus = if isProvisional then "Provisional_TBD" else "SDD_Confirmed",
		IsProvisionalBalance = isProvisional,
	}

	return table.freeze(resolved)
end

return table.freeze(BoosterCatalog)

