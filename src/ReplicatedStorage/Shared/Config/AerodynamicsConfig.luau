--!strict
--[=[
	AerodynamicsConfig
	Configuración centralizada y editable del sistema modular de aerodinámica (Fase 5.3).

	NOTA DE BALANCE (AGENTS.md):
	- Todos los valores iniciales de precio, masa (Weight), HP (MaxDurability) y coeficientes
	  aerodinámicos están etiquetados explícitamente como BalanceStatus = "Provisional_TBD".
	- Preparado para extenderse en fases posteriores con superficies de control activas
	  (Alerones, Elevadores, Timón de dirección) sin alterar contratos.
]=]

export type AeroSurfaceType = "Wing" | "Tail" | "Glider"

export type AeroControlSurfaceRole = "None" | "Aileron" | "Elevator" | "Rudder"

export type AeroSurfaceSpec = {
	ItemId: string,
	DisplayName: string,
	Description: string,
	SurfaceType: AeroSurfaceType,
	Side: "Left" | "Right" | "Center" | "Symmetric",
	ControlRole: AeroControlSurfaceRole,
	ControlAuthorityDeg: number,
	ControlInvertSign: number,
	Price: number,
	Weight: number,
	MaxDurability: number,
	ImpactResistance: number,
	DamageMultiplier: number,
	WingArea: number,
	ChordLength: number,
	SpanLength: number,
	ZeroAlphaLiftCoefficient: number,
	LiftCoefficientSlope: number,
	MaxLiftCoefficient: number,
	BaseDragCoefficient: number,
	InducedDragFactor: number,
	PostStallDragCoefficient: number,
	StallAngleDeg: number,
	FullStallAngleDeg: number,
	VerticalStabilizerArea: number,
	YawLiftSlope: number,
	MaxYawSideForceCoefficient: number,
	CenterOfPressureLocalOffset: Vector3,
	BalanceStatus: "Provisional_TBD",
}

local AerodynamicsConfig = {
	BalanceStatus = "Provisional_TBD" :: "Provisional_TBD",

	Simulation = {
		BalanceStatus = "Provisional_TBD" :: "Provisional_TBD",
		-- Densidad efectiva del aire en unidades físicas del juego (q = 0.5 * AirDensity * V^2)
		AirDensity = 0.22,
		-- Debajo de este umbral de velocidad relativa el flujo es despreciable y la fuerza es 0 exacta
		MinAirspeedStudsPerSec = 0.50,
		MinChordAirspeedStudsPerSec = 0.35,
		MinAppliedForceThreshold = 0.20,

		-- Límites numéricos de seguridad contra velocidades extremas, explosiones físicas o NaN
		MaxEffectiveAirspeedStudsPerSec = 450.0,
		MaxAngularVelocityContributionStudsPerSec = 140.0,
		MaxForcePerSurface = 85000.0,
		MaxTotalAerodynamicForce = 350000.0,

		-- Comportamiento en pérdida (stall) y flujo inverso
		PostStallLiftScale = 0.72,
		ReverseFlowLiftEfficiency = 0.35,
		SideslipStallAngleDeg = 22.0,
		SideslipFullStallAngleDeg = 38.0,

		-- Telemetría replicada acotada
		AttributePrefix = "AERO_",
		TelemetryUpdateIntervalSeconds = 0.12,

		-- Nombres de instancias físicas en runtime
		AttachmentName = "AeroForceAttachment",
		VectorForceName = "AeroVectorForce",
	},

	OrderedItemIds = {
		"AircraftWingLeft",
		"AircraftWingRight",
		"AircraftWing",
		"AircraftTail",
		"LargeGliderWing",
		"SmallGliderWing",
	},

	Surfaces = {
		AircraftWingLeft = {
			ItemId = "AircraftWingLeft",
			DisplayName = "Ala izquierda",
			Description = "Superficie alar izquierda con perfil sustentador; aporta sustentación y par de balanceo según su posición respecto al centro de masa.",
			SurfaceType = "Wing" :: AeroSurfaceType,
			Side = "Left" :: "Left",
			ControlRole = "Aileron" :: AeroControlSurfaceRole,
			ControlAuthorityDeg = 12.0,
			ControlInvertSign = -1,
			Price = 140,
			Weight = 4.5,
			MaxDurability = 85,
			ImpactResistance = 0.90,
			DamageMultiplier = 1.05,
			WingArea = 16.0,
			ChordLength = 4.0,
			SpanLength = 6.0,
			ZeroAlphaLiftCoefficient = 0.22,
			LiftCoefficientSlope = 4.2,
			MaxLiftCoefficient = 1.45,
			BaseDragCoefficient = 0.045,
			InducedDragFactor = 0.065,
			PostStallDragCoefficient = 0.95,
			StallAngleDeg = 18.0,
			FullStallAngleDeg = 32.0,
			VerticalStabilizerArea = 0.0,
			YawLiftSlope = 0.0,
			MaxYawSideForceCoefficient = 0.0,
			CenterOfPressureLocalOffset = Vector3.new(-0.35, 0.0, -0.15),
			BalanceStatus = "Provisional_TBD" :: "Provisional_TBD",
		},

		AircraftWingRight = {
			ItemId = "AircraftWingRight",
			DisplayName = "Ala derecha",
			Description = "Superficie alar derecha simétrica al ala izquierda; combinadas en par equilibran el balanceo del vehículo.",
			SurfaceType = "Wing" :: AeroSurfaceType,
			Side = "Right" :: "Right",
			ControlRole = "Aileron" :: AeroControlSurfaceRole,
			ControlAuthorityDeg = 12.0,
			ControlInvertSign = 1,
			Price = 140,
			Weight = 4.5,
			MaxDurability = 85,
			ImpactResistance = 0.90,
			DamageMultiplier = 1.05,
			WingArea = 16.0,
			ChordLength = 4.0,
			SpanLength = 6.0,
			ZeroAlphaLiftCoefficient = 0.22,
			LiftCoefficientSlope = 4.2,
			MaxLiftCoefficient = 1.45,
			BaseDragCoefficient = 0.045,
			InducedDragFactor = 0.065,
			PostStallDragCoefficient = 0.95,
			StallAngleDeg = 18.0,
			FullStallAngleDeg = 32.0,
			VerticalStabilizerArea = 0.0,
			YawLiftSlope = 0.0,
			MaxYawSideForceCoefficient = 0.0,
			CenterOfPressureLocalOffset = Vector3.new(0.35, 0.0, -0.15),
			BalanceStatus = "Provisional_TBD" :: "Provisional_TBD",
		},

		AircraftWing = {
			ItemId = "AircraftWing",
			DisplayName = "Ala de avión universal",
			Description = "Sección alar recta y versátil; puede montarse en cualquier costado, orientación o ángulo para generar sustentación o carga aerodinámica.",
			SurfaceType = "Wing" :: AeroSurfaceType,
			Side = "Symmetric" :: "Symmetric",
			ControlRole = "Aileron" :: AeroControlSurfaceRole,
			ControlAuthorityDeg = 10.0,
			ControlInvertSign = 1,
			Price = 160,
			Weight = 5.0,
			MaxDurability = 95,
			ImpactResistance = 0.92,
			DamageMultiplier = 1.00,
			WingArea = 18.0,
			ChordLength = 4.0,
			SpanLength = 6.0,
			ZeroAlphaLiftCoefficient = 0.24,
			LiftCoefficientSlope = 4.3,
			MaxLiftCoefficient = 1.48,
			BaseDragCoefficient = 0.048,
			InducedDragFactor = 0.062,
			PostStallDragCoefficient = 0.95,
			StallAngleDeg = 18.0,
			FullStallAngleDeg = 32.0,
			VerticalStabilizerArea = 0.0,
			YawLiftSlope = 0.0,
			MaxYawSideForceCoefficient = 0.0,
			CenterOfPressureLocalOffset = Vector3.new(0.0, 0.0, -0.10),
			BalanceStatus = "Provisional_TBD" :: "Provisional_TBD",
		},

		AircraftTail = {
			ItemId = "AircraftTail",
			DisplayName = "Cola de avión",
			Description = "Empenaje con estabilizador horizontal y deriva vertical; aporta estabilidad pasiva de cabeceo y guiñada cuando se ubica detrás del centro de masa.",
			SurfaceType = "Tail" :: AeroSurfaceType,
			Side = "Center" :: "Center",
			ControlRole = "Elevator" :: AeroControlSurfaceRole,
			ControlAuthorityDeg = 14.0,
			ControlInvertSign = 1,
			Price = 150,
			Weight = 4.0,
			MaxDurability = 80,
			ImpactResistance = 0.88,
			DamageMultiplier = 1.05,
			WingArea = 10.0,
			ChordLength = 3.0,
			SpanLength = 5.0,
			ZeroAlphaLiftCoefficient = 0.0,
			LiftCoefficientSlope = 3.8,
			MaxLiftCoefficient = 1.25,
			BaseDragCoefficient = 0.040,
			InducedDragFactor = 0.055,
			PostStallDragCoefficient = 0.90,
			StallAngleDeg = 20.0,
			FullStallAngleDeg = 35.0,
			VerticalStabilizerArea = 8.5,
			YawLiftSlope = 3.6,
			MaxYawSideForceCoefficient = 1.20,
			CenterOfPressureLocalOffset = Vector3.new(0.0, 0.25, 0.35),
			BalanceStatus = "Provisional_TBD" :: "Provisional_TBD",
		},

		LargeGliderWing = {
			ItemId = "LargeGliderWing",
			DisplayName = "Ala de planeador grande",
			Description = "Ala de gran envergadura y baja resistencia inducida; ideal para que autos o vehículos ligeros despeguen en rampas y planeen largas distancias.",
			SurfaceType = "Glider" :: AeroSurfaceType,
			Side = "Center" :: "Center",
			ControlRole = "None" :: AeroControlSurfaceRole,
			ControlAuthorityDeg = 0.0,
			ControlInvertSign = 1,
			Price = 260,
			Weight = 6.5,
			MaxDurability = 105,
			ImpactResistance = 0.90,
			DamageMultiplier = 1.05,
			WingArea = 38.0,
			ChordLength = 4.0,
			SpanLength = 12.0,
			ZeroAlphaLiftCoefficient = 0.38,
			LiftCoefficientSlope = 4.8,
			MaxLiftCoefficient = 1.72,
			BaseDragCoefficient = 0.038,
			InducedDragFactor = 0.042,
			PostStallDragCoefficient = 1.05,
			StallAngleDeg = 19.0,
			FullStallAngleDeg = 33.0,
			VerticalStabilizerArea = 0.0,
			YawLiftSlope = 0.0,
			MaxYawSideForceCoefficient = 0.0,
			CenterOfPressureLocalOffset = Vector3.new(0.0, 0.0, -0.10),
			BalanceStatus = "Provisional_TBD" :: "Provisional_TBD",
		},

		SmallGliderWing = {
			ItemId = "SmallGliderWing",
			DisplayName = "Ala de planeador pequeña",
			Description = "Ala compacta de planeo con menor superficie y peso; permite agregar sustentación auxiliar o construir planeadores ligeros.",
			SurfaceType = "Glider" :: AeroSurfaceType,
			Side = "Center" :: "Center",
			ControlRole = "None" :: AeroControlSurfaceRole,
			ControlAuthorityDeg = 0.0,
			ControlInvertSign = 1,
			Price = 130,
			Weight = 3.5,
			MaxDurability = 75,
			ImpactResistance = 0.88,
			DamageMultiplier = 1.05,
			WingArea = 19.0,
			ChordLength = 3.5,
			SpanLength = 7.0,
			ZeroAlphaLiftCoefficient = 0.32,
			LiftCoefficientSlope = 4.4,
			MaxLiftCoefficient = 1.55,
			BaseDragCoefficient = 0.040,
			InducedDragFactor = 0.048,
			PostStallDragCoefficient = 1.00,
			StallAngleDeg = 18.5,
			FullStallAngleDeg = 32.0,
			VerticalStabilizerArea = 0.0,
			YawLiftSlope = 0.0,
			MaxYawSideForceCoefficient = 0.0,
			CenterOfPressureLocalOffset = Vector3.new(0.0, 0.0, -0.10),
			BalanceStatus = "Provisional_TBD" :: "Provisional_TBD",
		},
	},
}

function AerodynamicsConfig.GetSurfaceSpec(itemId: string?): AeroSurfaceSpec?
	if type(itemId) ~= "string" then
		return nil
	end
	return (AerodynamicsConfig.Surfaces :: { [string]: AeroSurfaceSpec })[itemId]
end

function AerodynamicsConfig.IsAerodynamicItem(itemId: string?): boolean
	return AerodynamicsConfig.GetSurfaceSpec(itemId) ~= nil
end

table.freeze(AerodynamicsConfig.Simulation)
table.freeze(AerodynamicsConfig.OrderedItemIds)
for _, spec in pairs(AerodynamicsConfig.Surfaces) do
	table.freeze(spec)
end
table.freeze(AerodynamicsConfig.Surfaces)

return table.freeze(AerodynamicsConfig)

