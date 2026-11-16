--!strict
--[=[
	DamageConfig
	Configuración centralizada e inmutable del sistema de daño estructural y durabilidad por pieza (Fase 4.1).

	Regla SDD / AGENTS.md:
	- Los valores de durabilidad base (`MaxDurability`) provienen del catálogo SDD confirmado cuando existen.
	- Todos los umbrales de colisión, multiplicadores por categoría, parámetros de distribución y escalas
	  físicas no confirmadas en el SDD quedan etiquetados explícitamente como `BalanceStatus = "Provisional_TBD"`.
]=]

export type CategoryDamageProfile = {
	Category: string,
	DefaultMaxHealth: number,
	DefaultDurability: number,
	ImpactResistance: number,
	DamageMultiplier: number,
	BalanceStatus: "Provisional_TBD",
}

local DamageConfig = {
	BalanceStatus = "Provisional_TBD",

	-- Estados posibles por pieza en VehicleDamageService
	PieceStates = {
		Healthy = "Healthy",
		Damaged = "Damaged",
		Disabled = "Disabled",
	},

	-- Parámetros cinemáticos y de energía de impacto (Provisional_TBD)
	Impact = {
		BalanceStatus = "Provisional_TBD",

		-- Umbrales mínimos para distinguir choques reales de contactos de reposo, rodamiento o ajuste inicial
		MinImpactSpeedStudsPerSec = 14.0,
		MinNormalSpeedStudsPerSec = 12.0,
		DamageThresholdSpeedStudsPerSec = 14.0,
		MinDamageThreshold = 1.5,

		-- Ponderación normal vs raspado tangencial (un auto rodando por carretera tiene NormalSpeed ~0)
		NormalSpeedWeight = 1.0,
		TangentialSpeedWeight = 0.12,
		HighSpeedScrapeOverrideSpeed = 48.0, -- Solo raspones extremos tangenciales superan filtro normal

		-- Masa efectiva reducida e impulso/energía
		ReferenceMass = 50.0,
		MassExponent = 0.35,
		MinMassFactor = 0.55,
		MaxMassFactor = 3.00,

		-- Curva de daño: Damage = DamageScale * ((EffectiveSpeed - Threshold)^DamageExponent) * MassFactor
		DamageScale = 0.16,
		DamageExponent = 1.35,
		MaxSingleImpactRawDamage = 2500.0,

		-- Ventana de estabilización inicial al desanclar en LaunchPoint (evita falso daño por asentamiento de resortes)
		LaunchSettlingGraceSeconds = 0.25,
		GraceOverrideNormalSpeed = 24.0,

		-- Seguridad y anti-spoof contra picos anómalos de NetworkOwnership
		MaxTrackedRelativeSpeedStudsPerSec = 350.0,
		MaxContactRayDistanceStuds = 6.0,
	},

	-- Deduplicación temporal y control por pares / ráfagas (evita repetición en Touched)
	Deduplication = {
		BalanceStatus = "Provisional_TBD",
		PieceOtherPairCooldownSeconds = 0.28,
		VehicleOtherBurstWindowSeconds = 0.12,
		MaxProcessedHitsPerBurst = 8,
		VehiclePairCooldownSeconds = 0.20,
		StaleEntryPruneSeconds = 10.0,
	},

	-- Distribución localizada y hooks extensibles hacia conexiones (Fase 4.2/4.3)
	Distribution = {
		BalanceStatus = "Provisional_TBD",
		EnableNeighborShockTransfer = true,
		PrimaryDirectShareWithNeighbors = 0.85,
		MaxAdjacentTransferShare = 0.15,
		MaxAdjacentNeighbors = 6,
		AdjacentDistanceAttenuation = 0.25,
		MaxAdjacentDistanceStuds = 10.0,
		MinDistributedPieceDamage = 0.40,
		MaxPropagationHops = 1, -- En Fase 4.1 solo impacto directo + amortiguación inmediata 1-hop; >=2 hops recibe 0
	},

	-- Telemetría y replicación acotada (nunca reescribir sin cambios reales)
	Telemetry = {
		AttributePrefix = "DMG_",
		MinReplicationIntervalSeconds = 0.10,
	},

	-- Diagnóstico exclusivo para desarrollo/pruebas en servidor
	Debug = {
		DefaultEnabledInStudio = true,
		MaxImpactHistoryPerRuntime = 50,
		WritePieceDebugAttributes = true,
		WritePieceDebugAttributesOnRegister = false,
	},

	-- Perfiles por categoría (reconoce Structures, Wheels, Engines, FuelTanks, Boosters, Seats, Utilities y fallback)
	CategoryProfiles = {
		Structures = {
			Category = "Structures",
			DefaultMaxHealth = 75,
			DefaultDurability = 75,
			ImpactResistance = 1.00,
			DamageMultiplier = 1.00,
			BalanceStatus = "Provisional_TBD",
		},
		Wheels = {
			Category = "Wheels",
			DefaultMaxHealth = 32,
			DefaultDurability = 32,
			ImpactResistance = 1.15,
			DamageMultiplier = 0.90,
			BalanceStatus = "Provisional_TBD",
		},
		Engines = {
			Category = "Engines",
			DefaultMaxHealth = 110,
			DefaultDurability = 110,
			ImpactResistance = 0.85,
			DamageMultiplier = 1.15,
			BalanceStatus = "Provisional_TBD",
		},
		FuelTanks = {
			Category = "FuelTanks",
			DefaultMaxHealth = 100,
			DefaultDurability = 100,
			ImpactResistance = 0.80,
			DamageMultiplier = 1.20,
			BalanceStatus = "Provisional_TBD",
		},
		Boosters = {
			Category = "Boosters",
			DefaultMaxHealth = 130,
			DefaultDurability = 130,
			ImpactResistance = 0.90,
			DamageMultiplier = 1.10,
			BalanceStatus = "Provisional_TBD",
		},
		Seats = {
			Category = "Seats",
			DefaultMaxHealth = 300,
			DefaultDurability = 300,
			ImpactResistance = 1.25,
			DamageMultiplier = 0.80,
			BalanceStatus = "Provisional_TBD",
		},
		Aerodynamics = {
			Category = "Aerodynamics",
			DefaultMaxHealth = 85,
			DefaultDurability = 85,
			ImpactResistance = 0.90,
			DamageMultiplier = 1.05,
			BalanceStatus = "Provisional_TBD",
		},
		Utilities = {
			Category = "Utilities",
			DefaultMaxHealth = 300,
			DefaultDurability = 300,
			ImpactResistance = 1.25,
			DamageMultiplier = 0.80,
			BalanceStatus = "Provisional_TBD",
		},
		Decorations = {
			Category = "Decorations",
			DefaultMaxHealth = 40,
			DefaultDurability = 40,
			ImpactResistance = 0.65,
			DamageMultiplier = 1.25,
			BalanceStatus = "Provisional_TBD",
		},
		Other = {
			Category = "Other",
			DefaultMaxHealth = 75,
			DefaultDurability = 75,
			ImpactResistance = 1.00,
			DamageMultiplier = 1.00,
			BalanceStatus = "Provisional_TBD",
		},
	},
}

table.freeze(DamageConfig.PieceStates)
table.freeze(DamageConfig.Impact)
table.freeze(DamageConfig.Deduplication)
table.freeze(DamageConfig.Distribution)
table.freeze(DamageConfig.Telemetry)
table.freeze(DamageConfig.Debug)
for _, profile in pairs(DamageConfig.CategoryProfiles) do
	table.freeze(profile :: any)
end
table.freeze(DamageConfig.CategoryProfiles)

function DamageConfig.GetCategoryProfile(category: string?): CategoryDamageProfile
	if type(category) == "string" and (DamageConfig.CategoryProfiles :: any)[category] ~= nil then
		return (DamageConfig.CategoryProfiles :: any)[category] :: CategoryDamageProfile
	end
	return DamageConfig.CategoryProfiles.Other :: CategoryDamageProfile
end

return table.freeze(DamageConfig)

