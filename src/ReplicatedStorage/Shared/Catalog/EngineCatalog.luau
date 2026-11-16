--!strict
--[=[
	EngineCatalog
	Registro centralizado e inmutable de familias, tamaños, variantes, rarezas y curvas de torque
	para motores modulares (Fase 3.3).

	Fórmula determinística de resolución de estadísticas:
		EffectiveStat(prop) = BaseSizeStat(prop) * FamilyMod(prop) * (1 + VariantDelta(prop)) * (1 + RarityBonus(prop))

	Garantías SDD:
	- Small + Balanced + Common preserva exactamente los valores del diseñador en docs/04-ITEM-CATALOG.md
	  (SpeedRegular=36, PeakTorque=1400, Weight=8, MaxDurability=110, IntegratedFuel=0.54, MaxConsumption=0.18, DrivingBonus=0.0025).
	- Medium + Balanced + Common preserva exactamente los valores del diseñador en docs/04-ITEM-CATALOG.md
	  (SpeedRegular=50, PeakTorque=4200, Weight=14, MaxDurability=150, IntegratedFuel=0.90, MaxConsumption=0.30, DrivingBonus=0.015).
	- Las 6 rarezas (Common..Mythic) aplican modificadores diferenciados por propiedad y respetan la curva de
	  bonificación por conducción de referencia en docs/06-ECONOMY-CRATES-DELIVERIES.md (+0.0025x .. +0.0065x).
	- Los parámetros calibrados fuera de las tablas confirmadas del SDD llevan BalanceStatus = "Provisional_TBD".
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

export type EngineFamilySpec = {
	FamilyId: ItemTypes.EngineFamilyId,
	DisplayName: string,
	Description: string,
	TorqueMultiplier: number,
	PowerMultiplier: number,
	RPMMultiplier: number,
	WeightMultiplier: number,
	EfficiencyMultiplier: number,
	BalanceStatus: ItemTypes.BalanceStatusTag,
}

export type ResolveEngineSpecInput = {
	ItemId: string?,
	EngineFamilyId: string?,
	EngineSizeId: string?,
	VariantId: string?,
	RarityId: string?,
}

local EngineCatalog = {}

local ORDERED_SIZE_IDS: { ItemTypes.EngineSizeId } = { "Small", "Medium", "Large" }
local ORDERED_RARITY_IDS: { ItemTypes.EngineRarityId } = {
	"Common",
	"Uncommon",
	"Rare",
	"Epic",
	"Legendary",
	"Mythic",
}
local ORDERED_VARIANT_IDS: { ItemTypes.EngineVariantId } = {
	"Balanced",
	"HighTorque",
	"HighRev",
	"EcoLight",
	"Overdrive",
}
local ORDERED_FAMILY_IDS: { ItemTypes.EngineFamilyId } = {
	"StandardCombustion",
	"CompactTurbine",
	"HeavyDiesel",
}

local TORQUE_CURVES: { [string]: ItemTypes.TorqueCurveSpec } = {
	StandardCurve = {
		Id = "StandardCurve",
		DisplayName = "Curva Equilibrada",
		IdleTorqueFactor = 0.58,
		PeakTorqueNormalizedRPM = 0.56,
		RedlineTorqueFactor = 0.78,
		CutoffDropPerNormalizedRPM = 6.0,
		Points = {
			{ NormalizedRPM = 0.00, TorqueFactor = 0.58 },
			{ NormalizedRPM = 0.20, TorqueFactor = 0.76 },
			{ NormalizedRPM = 0.42, TorqueFactor = 0.94 },
			{ NormalizedRPM = 0.56, TorqueFactor = 1.00 },
			{ NormalizedRPM = 0.74, TorqueFactor = 0.96 },
			{ NormalizedRPM = 0.90, TorqueFactor = 0.86 },
			{ NormalizedRPM = 1.00, TorqueFactor = 0.78 },
		},
	},
	LowEndTorqueCurve = {
		Id = "LowEndTorqueCurve",
		DisplayName = "Curva de Empuje Bajo",
		IdleTorqueFactor = 0.72,
		PeakTorqueNormalizedRPM = 0.38,
		RedlineTorqueFactor = 0.66,
		CutoffDropPerNormalizedRPM = 6.5,
		Points = {
			{ NormalizedRPM = 0.00, TorqueFactor = 0.72 },
			{ NormalizedRPM = 0.18, TorqueFactor = 0.90 },
			{ NormalizedRPM = 0.38, TorqueFactor = 1.00 },
			{ NormalizedRPM = 0.58, TorqueFactor = 0.95 },
			{ NormalizedRPM = 0.78, TorqueFactor = 0.82 },
			{ NormalizedRPM = 1.00, TorqueFactor = 0.66 },
		},
	},
	HighRevCurve = {
		Id = "HighRevCurve",
		DisplayName = "Curva de Altas RPM",
		IdleTorqueFactor = 0.46,
		PeakTorqueNormalizedRPM = 0.78,
		RedlineTorqueFactor = 0.91,
		CutoffDropPerNormalizedRPM = 7.0,
		Points = {
			{ NormalizedRPM = 0.00, TorqueFactor = 0.46 },
			{ NormalizedRPM = 0.25, TorqueFactor = 0.62 },
			{ NormalizedRPM = 0.50, TorqueFactor = 0.82 },
			{ NormalizedRPM = 0.68, TorqueFactor = 0.96 },
			{ NormalizedRPM = 0.78, TorqueFactor = 1.00 },
			{ NormalizedRPM = 0.92, TorqueFactor = 0.96 },
			{ NormalizedRPM = 1.00, TorqueFactor = 0.91 },
		},
	},
	EcoCurve = {
		Id = "EcoCurve",
		DisplayName = "Curva Lineal Eficiente",
		IdleTorqueFactor = 0.62,
		PeakTorqueNormalizedRPM = 0.48,
		RedlineTorqueFactor = 0.74,
		CutoffDropPerNormalizedRPM = 5.5,
		Points = {
			{ NormalizedRPM = 0.00, TorqueFactor = 0.62 },
			{ NormalizedRPM = 0.25, TorqueFactor = 0.84 },
			{ NormalizedRPM = 0.48, TorqueFactor = 1.00 },
			{ NormalizedRPM = 0.72, TorqueFactor = 0.92 },
			{ NormalizedRPM = 1.00, TorqueFactor = 0.74 },
		},
	},
	OverdriveCurve = {
		Id = "OverdriveCurve",
		DisplayName = "Curva Competición Ancha",
		IdleTorqueFactor = 0.60,
		PeakTorqueNormalizedRPM = 0.66,
		RedlineTorqueFactor = 0.88,
		CutoffDropPerNormalizedRPM = 7.5,
		Points = {
			{ NormalizedRPM = 0.00, TorqueFactor = 0.60 },
			{ NormalizedRPM = 0.22, TorqueFactor = 0.80 },
			{ NormalizedRPM = 0.46, TorqueFactor = 0.95 },
			{ NormalizedRPM = 0.66, TorqueFactor = 1.00 },
			{ NormalizedRPM = 0.86, TorqueFactor = 0.96 },
			{ NormalizedRPM = 1.00, TorqueFactor = 0.88 },
		},
	},
}

local ENGINE_FAMILIES: { [ItemTypes.EngineFamilyId]: EngineFamilySpec } = {
	StandardCombustion = {
		FamilyId = "StandardCombustion",
		DisplayName = "Combustión Modular",
		Description = "Familia base de combustión interna compatible con combustible Regular, Diésel y Competición.",
		TorqueMultiplier = 1.00,
		PowerMultiplier = 1.00,
		RPMMultiplier = 1.00,
		WeightMultiplier = 1.00,
		EfficiencyMultiplier = 1.00,
		BalanceStatus = "SDD_Confirmed",
	},
	CompactTurbine = {
		FamilyId = "CompactTurbine",
		DisplayName = "Turbina Ligera",
		Description = "Arquitectura de altas revoluciones y menor peso con menor par en baja (Provisional TBD).",
		TorqueMultiplier = 0.88,
		PowerMultiplier = 1.14,
		RPMMultiplier = 1.22,
		WeightMultiplier = 0.84,
		EfficiencyMultiplier = 0.90,
		BalanceStatus = "Provisional_TBD",
	},
	HeavyDiesel = {
		FamilyId = "HeavyDiesel",
		DisplayName = "Bloque Diésel Industrial",
		Description = "Arquitectura de carrera larga con alto par de arrastre para cargas pesadas (Provisional TBD).",
		TorqueMultiplier = 1.24,
		PowerMultiplier = 0.95,
		RPMMultiplier = 0.82,
		WeightMultiplier = 1.18,
		EfficiencyMultiplier = 1.12,
		BalanceStatus = "Provisional_TBD",
	},
}

local ENGINE_SIZES: { [ItemTypes.EngineSizeId]: ItemTypes.BaseEngineSizeSpec } = {
	Small = {
		SizeId = "Small",
		DisplayName = "Motor Pequeño",
		BaseItemId = "SmallEngine",
		-- Valores exactos SDD (docs/04-ITEM-CATALOG.md):
		SpeedRegular = 36,
		BaseTorque = 1400,
		BasePowerRating = 120,
		IdleRPM = 900,
		OptimumRPM = 3600,
		MaxRPM = 5800,
		LimiterRPM = 6100,
		LimiterRecoveryRPM = 5750,
		Responsiveness = 5.2,
		EngineBrakingFactor = 0.22,
		Weight = 8,
		MaxDurability = 110,
		FuelType = "Normal",
		IntegratedFuel = 0.54,
		MaxConsumptionRegular = 0.18,
		DrivingBonus = 0.0025,
		DisconnectRate = 21.88,
		VisualScaleMultiplier = 1.00,
		BalanceStatus = "SDD_Confirmed",
	},
	Medium = {
		SizeId = "Medium",
		DisplayName = "Motor Mediano",
		BaseItemId = "SmallEngine", -- Reutiliza el modelo 3D base sin requerir un asset separado obligatorio
		-- Valores exactos SDD (docs/04-ITEM-CATALOG.md):
		SpeedRegular = 50,
		BaseTorque = 4200,
		BasePowerRating = 290,
		IdleRPM = 850,
		OptimumRPM = 3800,
		MaxRPM = 6200,
		LimiterRPM = 6500,
		LimiterRecoveryRPM = 6100,
		Responsiveness = 4.6,
		EngineBrakingFactor = 0.25,
		Weight = 14,
		MaxDurability = 150,
		FuelType = "Normal",
		IntegratedFuel = 0.90,
		MaxConsumptionRegular = 0.30,
		DrivingBonus = 0.015,
		DisconnectRate = 87.50,
		VisualScaleMultiplier = 1.15,
		BalanceStatus = "SDD_Confirmed",
	},
	Large = {
		SizeId = "Large",
		DisplayName = "Motor Grande",
		BaseItemId = "SmallEngine", -- Reutiliza el modelo 3D base
		-- Valores calibrados provisionales (marcados explícitamente como Provisional_TBD según regla 1 AGENTS.md)
		SpeedRegular = 64,
		BaseTorque = 7800,
		BasePowerRating = 520,
		IdleRPM = 800,
		OptimumRPM = 3500,
		MaxRPM = 5600,
		LimiterRPM = 5900,
		LimiterRecoveryRPM = 5550,
		Responsiveness = 3.9,
		EngineBrakingFactor = 0.28,
		Weight = 22,
		MaxDurability = 200,
		FuelType = "Normal",
		IntegratedFuel = 1.40,
		MaxConsumptionRegular = 0.48,
		DrivingBonus = 0.035,
		DisconnectRate = 175.00,
		VisualScaleMultiplier = 1.30,
		BalanceStatus = "Provisional_TBD",
	},
}

local ENGINE_VARIANTS: { [ItemTypes.EngineVariantId]: ItemTypes.EngineVariantModifiers } = {
	Balanced = {
		VariantId = "Balanced",
		DisplayName = "Estándar Equilibrado",
		Description = "Configuración base de fábrica con entrega progresiva de par y potencia.",
		TorqueDeltaRatio = 0.00,
		PowerDeltaRatio = 0.00,
		SpeedRegularDeltaRatio = 0.00,
		IdleRPMDeltaRatio = 0.00,
		OptimumRPMDeltaRatio = 0.00,
		MaxRPMDeltaRatio = 0.00,
		ResponsivenessDeltaRatio = 0.00,
		WeightDeltaRatio = 0.00,
		EfficiencyDeltaRatio = 0.00,
		DurabilityDeltaRatio = 0.00,
		CurveSpecId = "StandardCurve",
		BalanceStatus = "SDD_Confirmed",
	},
	HighTorque = {
		VariantId = "HighTorque",
		DisplayName = "Alto Torque (Tracción Pesada)",
		Description = "Mayor empuje desde bajas RPM para subir pendientes y mover chasis pesados, con menor velocidad punta.",
		TorqueDeltaRatio = 0.22,
		PowerDeltaRatio = 0.04,
		SpeedRegularDeltaRatio = -0.08,
		IdleRPMDeltaRatio = -0.08,
		OptimumRPMDeltaRatio = -0.15,
		MaxRPMDeltaRatio = -0.12,
		ResponsivenessDeltaRatio = -0.06,
		WeightDeltaRatio = 0.12,
		EfficiencyDeltaRatio = -0.04,
		DurabilityDeltaRatio = 0.10,
		CurveSpecId = "LowEndTorqueCurve",
		BalanceStatus = "Provisional_TBD",
	},
	HighRev = {
		VariantId = "HighRev",
		DisplayName = "Altas RPM (Velocidad)",
		Description = "Rango extendido de revoluciones y mayor velocidad punta, pero menor empuje en arranque.",
		TorqueDeltaRatio = -0.10,
		PowerDeltaRatio = 0.18,
		SpeedRegularDeltaRatio = 0.14,
		IdleRPMDeltaRatio = 0.10,
		OptimumRPMDeltaRatio = 0.18,
		MaxRPMDeltaRatio = 0.20,
		ResponsivenessDeltaRatio = 0.16,
		WeightDeltaRatio = -0.06,
		EfficiencyDeltaRatio = -0.08,
		DurabilityDeltaRatio = -0.05,
		CurveSpecId = "HighRevCurve",
		BalanceStatus = "Provisional_TBD",
	},
	EcoLight = {
		VariantId = "EcoLight",
		DisplayName = "Compacto Eficiente",
		Description = "Bloque aligerado con menor masa y consumo reducido para vehículos ágiles.",
		TorqueDeltaRatio = -0.07,
		PowerDeltaRatio = -0.04,
		SpeedRegularDeltaRatio = 0.02,
		IdleRPMDeltaRatio = -0.05,
		OptimumRPMDeltaRatio = -0.05,
		MaxRPMDeltaRatio = -0.04,
		ResponsivenessDeltaRatio = 0.12,
		WeightDeltaRatio = -0.18,
		EfficiencyDeltaRatio = 0.24,
		DurabilityDeltaRatio = 0.00,
		CurveSpecId = "EcoCurve",
		BalanceStatus = "Provisional_TBD",
	},
	Overdrive = {
		VariantId = "Overdrive",
		DisplayName = "Sobrealimentado (Competición)",
		Description = "Entrega agresiva de par y potencia en banda media-alta con mayor peso y consumo.",
		TorqueDeltaRatio = 0.15,
		PowerDeltaRatio = 0.24,
		SpeedRegularDeltaRatio = 0.12,
		IdleRPMDeltaRatio = 0.08,
		OptimumRPMDeltaRatio = 0.10,
		MaxRPMDeltaRatio = 0.12,
		ResponsivenessDeltaRatio = 0.20,
		WeightDeltaRatio = 0.10,
		EfficiencyDeltaRatio = -0.18,
		DurabilityDeltaRatio = -0.04,
		CurveSpecId = "OverdriveCurve",
		BalanceStatus = "Provisional_TBD",
	},
}

-- 6 rarezas (docs/06-ECONOMY-CRATES-DELIVERIES.md):
-- Modificadores diferenciados por propiedad (no un único multiplicador plano).
local ENGINE_RARITIES: { [ItemTypes.EngineRarityId]: ItemTypes.EngineRarityModifiers } = {
	Common = {
		RarityId = "Common",
		DisplayName = "Común",
		RankOrder = 1,
		ColorHex = "#B0B8C4",
		TorqueBonusRatio = 0.00,
		PowerBonusRatio = 0.00,
		SpeedBonusRatio = 0.00,
		RPMBandBonusRatio = 0.00,
		ResponsivenessBonusRatio = 0.00,
		EfficiencyBonusRatio = 0.00,
		WeightDeltaRatio = 0.00,
		DurabilityBonusRatio = 0.00,
		DrivingBonusMultiplier = 1.00, -- 0.0025 en SmallEngine (SDD docs/06)
		BalanceStatus = "SDD_Confirmed",
	},
	Uncommon = {
		RarityId = "Uncommon",
		DisplayName = "No común",
		RankOrder = 2,
		ColorHex = "#4ADE80",
		TorqueBonusRatio = 0.06,
		PowerBonusRatio = 0.07,
		SpeedBonusRatio = 0.04,
		RPMBandBonusRatio = 0.03,
		ResponsivenessBonusRatio = 0.05,
		EfficiencyBonusRatio = 0.04,
		WeightDeltaRatio = -0.02,
		DurabilityBonusRatio = 0.05,
		DrivingBonusMultiplier = 1.16, -- 0.0029 en SmallEngine (SDD docs/06)
		BalanceStatus = "Provisional_TBD",
	},
	Rare = {
		RarityId = "Rare",
		DisplayName = "Raro",
		RankOrder = 3,
		ColorHex = "#38BDF8",
		TorqueBonusRatio = 0.13,
		PowerBonusRatio = 0.15,
		SpeedBonusRatio = 0.08,
		RPMBandBonusRatio = 0.06,
		ResponsivenessBonusRatio = 0.11,
		EfficiencyBonusRatio = 0.08,
		WeightDeltaRatio = -0.04,
		DurabilityBonusRatio = 0.12,
		DrivingBonusMultiplier = 1.36, -- 0.0034 en SmallEngine (SDD docs/06)
		BalanceStatus = "Provisional_TBD",
	},
	Epic = {
		RarityId = "Epic",
		DisplayName = "Épico",
		RankOrder = 4,
		ColorHex = "#C084FC",
		TorqueBonusRatio = 0.22,
		PowerBonusRatio = 0.25,
		SpeedBonusRatio = 0.13,
		RPMBandBonusRatio = 0.10,
		ResponsivenessBonusRatio = 0.18,
		EfficiencyBonusRatio = 0.13,
		WeightDeltaRatio = -0.07,
		DurabilityBonusRatio = 0.20,
		DrivingBonusMultiplier = 1.64, -- 0.0041 en SmallEngine (SDD docs/06)
		BalanceStatus = "Provisional_TBD",
	},
	Legendary = {
		RarityId = "Legendary",
		DisplayName = "Legendario",
		RankOrder = 5,
		ColorHex = "#FBBF24",
		TorqueBonusRatio = 0.34,
		PowerBonusRatio = 0.38,
		SpeedBonusRatio = 0.19,
		RPMBandBonusRatio = 0.15,
		ResponsivenessBonusRatio = 0.26,
		EfficiencyBonusRatio = 0.19,
		WeightDeltaRatio = -0.10,
		DurabilityBonusRatio = 0.30,
		DrivingBonusMultiplier = 2.04, -- 0.0051 en SmallEngine (SDD docs/06)
		BalanceStatus = "Provisional_TBD",
	},
	Mythic = {
		RarityId = "Mythic",
		DisplayName = "Mítico",
		RankOrder = 6,
		ColorHex = "#F43F5E",
		TorqueBonusRatio = 0.48,
		PowerBonusRatio = 0.54,
		SpeedBonusRatio = 0.26,
		RPMBandBonusRatio = 0.20,
		ResponsivenessBonusRatio = 0.36,
		EfficiencyBonusRatio = 0.26,
		WeightDeltaRatio = -0.14,
		DurabilityBonusRatio = 0.45,
		DrivingBonusMultiplier = 2.60, -- 0.0065 en SmallEngine (SDD docs/06)
		BalanceStatus = "Provisional_TBD",
	},
}

local function roundTo(value: number, decimals: number): number
	local mult = 10 ^ decimals
	return math.round(value * mult) / mult
end

-- Congelar definiciones estáticas
for _, curve in pairs(TORQUE_CURVES) do
	for _, pt in ipairs(curve.Points) do
		table.freeze(pt)
	end
	table.freeze(curve.Points)
	table.freeze(curve)
end
table.freeze(TORQUE_CURVES)

for _, fam in pairs(ENGINE_FAMILIES) do
	table.freeze(fam)
end
table.freeze(ENGINE_FAMILIES)

for _, sz in pairs(ENGINE_SIZES) do
	table.freeze(sz)
end
table.freeze(ENGINE_SIZES)

for _, varSpec in pairs(ENGINE_VARIANTS) do
	table.freeze(varSpec)
end
table.freeze(ENGINE_VARIANTS)

for _, rarSpec in pairs(ENGINE_RARITIES) do
	table.freeze(rarSpec)
end
table.freeze(ENGINE_RARITIES)

table.freeze(ORDERED_SIZE_IDS)
table.freeze(ORDERED_RARITY_IDS)
table.freeze(ORDERED_VARIANT_IDS)
table.freeze(ORDERED_FAMILY_IDS)

function EngineCatalog.IsValidFamilyId(id: any): boolean
	return type(id) == "string" and ENGINE_FAMILIES[id :: ItemTypes.EngineFamilyId] ~= nil
end

function EngineCatalog.IsValidSizeId(id: any): boolean
	return type(id) == "string" and ENGINE_SIZES[id :: ItemTypes.EngineSizeId] ~= nil
end

function EngineCatalog.IsValidVariantId(id: any): boolean
	return type(id) == "string" and ENGINE_VARIANTS[id :: ItemTypes.EngineVariantId] ~= nil
end

function EngineCatalog.IsValidRarityId(id: any): boolean
	return type(id) == "string" and ENGINE_RARITIES[id :: ItemTypes.EngineRarityId] ~= nil
end

function EngineCatalog.GetOrderedSizeIds(): { ItemTypes.EngineSizeId }
	return ORDERED_SIZE_IDS
end

function EngineCatalog.GetOrderedRarityIds(): { ItemTypes.EngineRarityId }
	return ORDERED_RARITY_IDS
end

function EngineCatalog.GetOrderedVariantIds(): { ItemTypes.EngineVariantId }
	return ORDERED_VARIANT_IDS
end

function EngineCatalog.GetOrderedFamilyIds(): { ItemTypes.EngineFamilyId }
	return ORDERED_FAMILY_IDS
end

function EngineCatalog.GetSizeSpec(sizeId: ItemTypes.EngineSizeId): ItemTypes.BaseEngineSizeSpec
	local spec = ENGINE_SIZES[sizeId]
	if not spec then
		error(`[EngineCatalog] Unknown EngineSizeId '{tostring(sizeId)}'`, 2)
	end
	return spec
end

function EngineCatalog.GetVariantSpec(variantId: ItemTypes.EngineVariantId): ItemTypes.EngineVariantModifiers
	local spec = ENGINE_VARIANTS[variantId]
	if not spec then
		error(`[EngineCatalog] Unknown EngineVariantId '{tostring(variantId)}'`, 2)
	end
	return spec
end

function EngineCatalog.GetRaritySpec(rarityId: ItemTypes.EngineRarityId): ItemTypes.EngineRarityModifiers
	local spec = ENGINE_RARITIES[rarityId]
	if not spec then
		error(`[EngineCatalog] Unknown EngineRarityId '{tostring(rarityId)}'`, 2)
	end
	return spec
end

function EngineCatalog.GetFamilySpec(familyId: ItemTypes.EngineFamilyId): EngineFamilySpec
	local spec = ENGINE_FAMILIES[familyId]
	if not spec then
		error(`[EngineCatalog] Unknown EngineFamilyId '{tostring(familyId)}'`, 2)
	end
	return spec
end

function EngineCatalog.GetTorqueCurve(curveSpecId: string): ItemTypes.TorqueCurveSpec
	return TORQUE_CURVES[curveSpecId] or TORQUE_CURVES.StandardCurve
end

-- Resuelve determinísticamente las estadísticas efectivas de un motor a partir de Familia + Tamaño + Variante + Rareza.
function EngineCatalog.ResolveEffectiveStats(input: ResolveEngineSpecInput?): ItemTypes.EffectiveEngineStats
	local opts = input or {}

	-- Si viene de un ItemId específico (ej. SmallEngine), inferir tamaño por defecto si no se especificó
	local rawSize = opts.EngineSizeId
	if not rawSize and opts.ItemId == "MediumEngine" then
		rawSize = "Medium"
	elseif not rawSize and opts.ItemId == "LargeEngine" then
		rawSize = "Large"
	end

	local familyId: ItemTypes.EngineFamilyId = if EngineCatalog.IsValidFamilyId(opts.EngineFamilyId)
		then (opts.EngineFamilyId :: ItemTypes.EngineFamilyId)
		else "StandardCombustion"
	local sizeId: ItemTypes.EngineSizeId = if EngineCatalog.IsValidSizeId(rawSize)
		then (rawSize :: ItemTypes.EngineSizeId)
		else "Small"
	local variantId: ItemTypes.EngineVariantId = if EngineCatalog.IsValidVariantId(opts.VariantId)
		then (opts.VariantId :: ItemTypes.EngineVariantId)
		else "Balanced"
	local rarityId: ItemTypes.EngineRarityId = if EngineCatalog.IsValidRarityId(opts.RarityId)
		then (opts.RarityId :: ItemTypes.EngineRarityId)
		else "Common"

	local family = ENGINE_FAMILIES[familyId]
	local base = ENGINE_SIZES[sizeId]
	local variant = ENGINE_VARIANTS[variantId]
	local rarity = ENGINE_RARITIES[rarityId]
	local curve = EngineCatalog.GetTorqueCurve(variant.CurveSpecId)

	-- Fórmula matemática determinística y diferenciada por propiedad:
	local peakTorque = roundTo(
		base.BaseTorque * family.TorqueMultiplier * (1 + variant.TorqueDeltaRatio) * (1 + rarity.TorqueBonusRatio),
		2
	)
	local powerRating = roundTo(
		base.BasePowerRating * family.PowerMultiplier * (1 + variant.PowerDeltaRatio) * (1 + rarity.PowerBonusRatio),
		2
	)
	local speedRegular = roundTo(
		base.SpeedRegular * (1 + variant.SpeedRegularDeltaRatio) * (1 + rarity.SpeedBonusRatio),
		2
	)

	local idleRPM = math.max(400, math.round(base.IdleRPM * family.RPMMultiplier * (1 + variant.IdleRPMDeltaRatio)))
	local optimumRPM = math.max(
		idleRPM + 600,
		math.round(base.OptimumRPM * family.RPMMultiplier * (1 + variant.OptimumRPMDeltaRatio) * (1 + rarity.RPMBandBonusRatio * 0.5))
	)
	local maxRPM = math.max(
		optimumRPM + 800,
		math.round(base.MaxRPM * family.RPMMultiplier * (1 + variant.MaxRPMDeltaRatio) * (1 + rarity.RPMBandBonusRatio))
	)
	local limiterSpan = math.max(200, base.LimiterRPM - base.MaxRPM)
	local recoverySpan = math.max(150, base.MaxRPM - base.LimiterRecoveryRPM)
	local limiterRPM = maxRPM + limiterSpan
	local limiterRecoveryRPM = maxRPM - recoverySpan

	local responsiveness = roundTo(
		math.max(1.0, base.Responsiveness * (1 + variant.ResponsivenessDeltaRatio) * (1 + rarity.ResponsivenessBonusRatio)),
		3
	)
	local weight = roundTo(
		math.max(2.0, base.Weight * family.WeightMultiplier * (1 + variant.WeightDeltaRatio) * (1 + rarity.WeightDeltaRatio)),
		2
	)
	local maxDurability = math.max(
		20,
		math.round(base.MaxDurability * (1 + variant.DurabilityDeltaRatio) * (1 + rarity.DurabilityBonusRatio))
	)

	local efficiencyFactor = roundTo(
		math.max(0.4, family.EfficiencyMultiplier * (1 + variant.EfficiencyDeltaRatio) * (1 + rarity.EfficiencyBonusRatio)),
		4
	)
	local maxFuelConsumption = roundTo(base.MaxConsumptionRegular / efficiencyFactor, 4)
	local drivingBonus = roundTo(base.DrivingBonus * rarity.DrivingBonusMultiplier, 6)

	local isProvisional = family.BalanceStatus == "Provisional_TBD"
		or base.BalanceStatus == "Provisional_TBD"
		or variant.BalanceStatus == "Provisional_TBD"
		or rarity.BalanceStatus == "Provisional_TBD"

	local fullLabel = `{base.DisplayName} [{rarity.DisplayName} · {variant.DisplayName}]`

	local resolved: ItemTypes.EffectiveEngineStats = {
		EngineFamilyId = familyId,
		EngineSizeId = sizeId,
		VariantId = variantId,
		RarityId = rarityId,
		BaseItemId = base.BaseItemId,
		DisplayName = base.DisplayName,
		FullLabel = fullLabel,
		SpeedRegular = speedRegular,
		PeakTorque = peakTorque,
		PowerRating = powerRating,
		IdleRPM = idleRPM,
		OptimumRPM = optimumRPM,
		MaxRPM = maxRPM,
		LimiterRPM = limiterRPM,
		LimiterRecoveryRPM = limiterRecoveryRPM,
		Responsiveness = responsiveness,
		EngineBrakingFactor = base.EngineBrakingFactor,
		Weight = weight,
		MaxDurability = maxDurability,
		FuelType = base.FuelType,
		IntegratedFuel = base.IntegratedFuel,
		MaxFuelConsumption = maxFuelConsumption,
		EfficiencyFactor = efficiencyFactor,
		DrivingBonus = drivingBonus,
		DisconnectRate = base.DisconnectRate,
		CurveSpecId = curve.Id,
		TorqueCurve = curve,
		BalanceStatus = if isProvisional then "Provisional_TBD" else "SDD_Confirmed",
		IsProvisionalBalance = isProvisional,
	}

	return table.freeze(resolved)
end

-- Evalúa la curva de torque a unas RPM dadas, incluyendo zona de ralentí, banda útil, pico, caída a altas RPM y corte al limitador.
function EngineCatalog.EvaluateTorqueAtRPM(
	stats: ItemTypes.EffectiveEngineStats,
	currentRPM: number,
	limiterActive: boolean?
): (number, number)
	if limiterActive then
		-- En corte de inyección el par motor se reduce drásticamente hasta recuperar RPM seguras
		return 0, 0
	end

	local clampedRPM = math.max(stats.IdleRPM, currentRPM)
	if clampedRPM >= stats.LimiterRPM then
		return 0, 0
	end

	local rpmSpan = math.max(1, stats.MaxRPM - stats.IdleRPM)
	local normRPM = (clampedRPM - stats.IdleRPM) / rpmSpan
	local curve = stats.TorqueCurve
	local points = curve.Points

	local factor = curve.IdleTorqueFactor
	if normRPM <= 0 then
		factor = points[1].TorqueFactor
	elseif normRPM >= 1.0 then
		-- Entre MaxRPM y LimiterRPM cae progresivamente
		local overNorm = (clampedRPM - stats.MaxRPM) / math.max(1, stats.LimiterRPM - stats.MaxRPM)
		factor = math.max(0.05, curve.RedlineTorqueFactor * (1 - overNorm * 0.85))
	else
		for i = 1, #points - 1 do
			local p0 = points[i]
			local p1 = points[i + 1]
			if normRPM >= p0.NormalizedRPM and normRPM <= p1.NormalizedRPM then
				local segSpan = math.max(1e-5, p1.NormalizedRPM - p0.NormalizedRPM)
				local alpha = (normRPM - p0.NormalizedRPM) / segSpan
				factor = p0.TorqueFactor + (p1.TorqueFactor - p0.TorqueFactor) * alpha
				break
			end
		end
	end

	local torque = stats.PeakTorque * factor
	return torque, factor
end

return table.freeze(EngineCatalog)

