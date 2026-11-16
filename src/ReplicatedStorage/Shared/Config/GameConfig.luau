--!strict
--[=[
	GameConfig
	Configuración estructural confirmada del servidor y estaciones.
	Los valores sin confirmar en el SDD permanecen marcados como TBD y no se inventan.
]=]

local GameConfig = {
	-- Confirmado en docs/01-VISION.md y docs/09-MVP-TESTING.md
	MaxPlayers = 10,
	PlotCount = 10,

	-- Nombres de atributos y zonas configurables para evitar rutas rígidas (ej. Base1)
	PlotAttributes = {
		PlotId = "PlotId",
		SlotIndex = "SlotIndex",
		OwnerUserId = "OwnerUserId",
		ZoneId = "ZoneId",
		BuildLiftHeight = "BuildLiftHeightOffset",
		BuildLiftLateral = "BuildLiftLateralOffset",
	},

	ZoneIds = {
		BuildZone = "BuildZone",
		LaunchPoint = "LaunchPoint",
		ShopZone = "ShopZone",
		DeliveryZone = "DeliveryZone",
		StandZone = "StandZone",
	},

	-- Nombres de contenedores e instancias físicas editables en Studio
	PlotContainers = {
		Dynamic = "DynamicRuntime",
		Decorations = "Decorations",
		Structures = "Structures",
		PlotSpawns = "PlotSpawns",
		PlotOrigin = "PlotOrigin",
		PlayerSpawn = "PlayerSpawn",
		VehicleStand = "VehicleStand",
		StandOrigin = "StandOrigin",
		DisplayPlatform = "DisplayPlatform",
		DisplayAnchor = "DisplayAnchor",
		InteractionPoint = "InteractionPoint",
	},

	ItemAttributes = {
		ItemId = "ItemId",
		Category = "Category",
	},

	ConnectionPrefix = "Conn_",

	-- Configuración provisional Fase 2.1 y 2.2 (Editor, Grid, Preview y Conexiones)
	Building = {
		GridSize = 1, -- 1 stud por celda (provisional Fase 2.1)
		DefaultZoneHeight = 32, -- Altura útil sobre el piso de BuildZone si BuildZone es una placa plana
		RotationStepDegrees = 90,
		MaxRaycastDistance = 250,
		PreviewAssetsFolder = "PreviewAssets",
		EditableVehicleName = "EditableVehicle",
		StandPreviewName = "StandPreview",
		GhostTransparency = 0.45,
		OptimisticTransparency = 0.25,
		ValidColor = Color3.fromRGB(60, 220, 100),
		InvalidColor = Color3.fromRGB(235, 65, 65),
		OptimisticColor = Color3.fromRGB(90, 190, 255),
		SelectionHighlightColor = Color3.fromRGB(255, 190, 50),

		-- Tolerancias y límites de construcción (Fase 2.2)
		ConnectionPositionTolerance = 0.55,
		SurfaceConnectionTolerance = 0.15,
		SmartSnapRadius = 1.75,
		OverlapTolerance = 0.05,
		MaxPiecesPerVehicle = 500,
		MaxOpsPerSecond = 25,

		-- Seguridad, sincronización y rendimiento (Fase 2.3)
		MaxReadOpsPerSecond = 10,
		RateLimitBurstWrite = 25,
		RateLimitBurstRead = 10,
		OperationTimeoutSeconds = 5,
		ReconcileGraceSeconds = 1.5,
		ClickDebounceSeconds = 0.05,
		MaxCachedOpIdsPerPlayer = 256,
		SpatialCellSize = 4,
		MaxStringLength = 64,
		MaxPayloadKeys = 8,
		MaxConfigEntries = 32,
		MaxConfigDepth = 2,
		MaxCoordinateMagnitude = 1e5,

		-- Editor avanzado: Grid configurable, Modo Libre, Guías y Gizmos (Fase 2.3.1)
		PositionModes = {
			Grid = "Grid",
			Free = "Free",
		},
		TransformTools = {
			None = "None",
			Move = "Move",
			Rotate = "Rotate",
		},
		GridResolutions = { 1, 0.5, 0.25, 0.1 },
		DefaultGridResolution = 0.25,
		FreeFineStep = 0.01,
		MinTransformStep = 0.01,
		AngleIncrementsDeg = { 90, 45, 15, 1 },
		DefaultAngleIncrementDeg = 90,

		-- Tolerancias e histéresis de alineación inteligente (Fase 2.3.1)
		AlignmentGuideRadius = 0.75,
		AlignmentSnapTolerance = 0.35,
		AlignmentHysteresis = 0.10,
		SurfaceContactSnapTolerance = 0.30,

		-- Modo FaceSnap automático cara con cara (Fase 2.4.2)
		FaceSnapRadius = 1.25,
		FaceSnapTangentMargin = 0.75,
		FaceSnapHysteresis = 0.35,
		FaceSnapMinNormalDot = -0.985,
		FaceSnapMinContactOverlap = 0.05,
		FaceSnapMaxPassiveJump = 1.65,
		FaceSnapValidColor = Color3.fromRGB(95, 245, 165),
		FaceSnapInvalidColor = Color3.fromRGB(255, 95, 95),

		-- Estética visual local del editor (Fase 2.3.1)
		GridVisualHalfSpanStuds = 6,
		GridMinorColor = Color3.fromRGB(115, 145, 185),
		GridMajorColor = Color3.fromRGB(190, 225, 255),
		GridAxisXColor = Color3.fromRGB(235, 85, 85),
		GridAxisZColor = Color3.fromRGB(85, 155, 255),
		GridGuideColor = Color3.fromRGB(255, 230, 95),
		GuideCenterColor = Color3.fromRGB(100, 235, 255),
		GuideEdgeColor = Color3.fromRGB(255, 195, 85),
		GuideAttachmentColor = Color3.fromRGB(110, 255, 145),
		GizmoAxisXColor = Color3.fromRGB(240, 65, 65),
		GizmoAxisYColor = Color3.fromRGB(70, 225, 110),
		GizmoAxisZColor = Color3.fromRGB(70, 145, 255),
		GizmoHighlightColor = Color3.fromRGB(255, 235, 110),
	},

	-- Gestión de blueprints persistentes y tarjetas de guardado (Fase 4.2.1 / transición Fase 5.1)
	Blueprints = {
		CurrentSchemaVersion = 1,
		StorageSchemaVersion = 3,
		MaxSlots = 3,
		MaxSavedBlueprintsPerPlayer = 3,
		MaxNameLength = 32,
		MinNameLength = 1,
		DefaultNamePrefix = "Vehiculo",
		DefaultSlotNamePrefix = "Slot",
		DuplicateSuffix = " (Copia)",
		DataStoreName = "BuildEngineers_PlayerBlueprints_v3",
		LegacyDataStoreName = "BuildEngineers_PlayerBlueprints_v1",
		MaxDriverSeatsPerBlueprint = 1,
		MaxLegacyOverflowEntries = 20,
	},

	-- Inventario central autoritativo y persistente (Fase 5.1)
	Inventory = {
		DataStoreName = "BuildEngineers_PlayerInventory_v1",
		StorageSchemaVersion = 1,
		StarterKitVersion = 1,
		UnlimitedCapacity = true,
		SellRatioTBD = false,
		NormalSellRatio = 0.50,
	},

	-- Kit inicial configurable entregado UNA sola vez al inicializar el inventario del jugador nuevo
	StartingInventory = {
		Enabled = true,
		Items = {
			WoodBlock = 20,
			WoodBeam = 10,
			SmallWheel = 4,
			DriverSeat = 1,
			RegularFuelTank = 1,
			SmallNitroTank = 1,
		},
		UniqueUnits = {
			{
				ItemId = "SmallEngine",
				FamilyId = "StandardCombustion",
				SizeId = "Small",
				VariantId = "Balanced",
				RarityId = "Common",
			},
			{
				ItemId = "SmallBooster",
				FamilyId = "StandardRocket",
				SizeId = "Small",
				VariantId = "Balanced",
				RarityId = "Common",
			},
		},
	},

	-- Elevador físico de taller en BuildZone (Fase 2.4.1)
	Stand = {
		MinHeightOffset = 0,
		MaxHeightOffset = 16,
		MinLateralOffset = -10,
		MaxLateralOffset = 10,
		DefaultHeightOffset = 0,
		DefaultLateralOffset = 0,
		NormalStep = 0.25,
		FineStep = 0.05,
		ContinuousHoldDelaySeconds = 0.18,
		ContinuousSyncIntervalSeconds = 0.10,
		ContinuousNormalSpeed = 4.0,
		ContinuousFineSpeed = 1.0,
		Epsilon = 1e-4,
	},

	-- Validación y preparación del lanzamiento en LaunchPoint (Fase 2.4, sin activar físicas aún)
	LaunchPrep = {
		GroundClearanceStuds = 0.05,
		DriverSeatItemId = "DriverSeat",
		RequiredDriverSeatCount = 1,
		MaxLaunchWidth = 40,
		MaxLaunchHeight = 32,
		MaxLaunchLength = 30,
		ObstructionPadding = 0.08,
	},

	-- Simulación física y ciclo de vida del vehículo en runtime (Fase 3.1)
	Runtime = {
		ModelName = "VehicleRuntime",
		JointsFolderName = "Joints",
		StagingFolderName = "_VehicleRuntimeStaging",
		CollectionTag = "VehicleRuntime",
		-- Decisión configurable (docs/10-OPEN-DECISIONS.md): default false evita griefing e intercolisiones innecesarias.
		VehiclesCollideWithEachOther = false,
		CollisionGroups = {
			VehicleRuntime = "VehicleRuntime",
			EditableVehicle = "EditableVehicle",
			EditorGhost = "EditorGhost",
		},
		States = {
			Editing = "Editing",
			PreparingLaunch = "PreparingLaunch",
			Launching = "Launching",
			Driving = "Driving",
			OnFootRuntime = "OnFootRuntime",
			ReturningToWorkshop = "ReturningToWorkshop",
		},
		PartRoles = {
			RigidStructure = "RigidStructure",
			DriverSeat = "DriverSeat",
			PassengerSeat = "PassengerSeat",
			Wheel = "Wheel",
			SteeringPivot = "SteeringPivot",
			SuspensionCarrier = "SuspensionCarrier",
			FutureWheel = "Wheel", -- Alias de compatibilidad hacia atrás
			Propulsion = "Propulsion",
			FuturePropulsion = "FuturePropulsion",
			AerodynamicSurface = "AerodynamicSurface",
			Decorative = "Decorative",
		},
		SeatMountTimeoutSeconds = 2.0,
		SeatMountRetryIntervalSeconds = 0.06,
		SeatCooldownWaitSeconds = 0.05,
		LaunchCooldownSeconds = 0.75,
		AbandonedTimeoutSeconds = 300,
		AbandonedCleanupCheckIntervalSeconds = 5,
		DestroyVehicleOnDeath = false,
		ExitSeatLateralOffsetStuds = 3.5,
		ExitSeatUpOffsetStuds = 1.5,
	},

	-- Sistema híbrido de ruedas, suspensión y dirección modular (Fase 3.2)
	Wheels = {
		DefaultWheelRadius = 1.0,
		DefaultWheelWidth = 1.0,
		DefaultLocalSpinAxis = Vector3.new(1, 0, 0),

		-- Límites autoritativos y valores base calibrados para SmallWheel en Roblox Studio
		MinSteeringAngleDeg = 0,
		MaxSteeringAngleDeg = 45,
		DefaultMaxSteeringAngleDeg = 28,

		MinSteeringSpeedDegPerSec = 30,
		MaxSteeringSpeedDegPerSec = 360,
		DefaultSteeringSpeedDegPerSec = 180,

		MinSuspensionTravelStuds = 0.1,
		MaxSuspensionTravelStuds = 2.0,
		DefaultSuspensionTravelStuds = 0.7,
		SuspensionCompressRatio = 0.65,

		MinSpringStiffness = 100,
		MaxSpringStiffness = 100000,
		DefaultSpringStiffness = 2800,

		MinSpringDamping = 10,
		MaxSpringDamping = 10000,
		DefaultSpringDamping = 160,

		MinRideHeightOffset = -0.6,
		MaxRideHeightOffset = 0.6,
		DefaultRideHeightOffset = 0.0,

		AutoSpringOmega = 14,
		AutoSpringDampingRatio = 0.70,
		AutoSpringMaxDamping = 520,
		AutoSpringMaxPreloadStuds = 2.2,
		AutoSpringPreloadStuds = 0.14,
		EstimatedDriverMass = 10.6,
		SpringMountHeightOffsetStuds = 3.0,

		CarrierSize = Vector3.new(0.8, 0.8, 0.8),
		PivotSize = Vector3.new(0.75, 0.75, 0.75),
		HubDensity = 3.5,

		WheelElasticity = 0.12,
		WheelFrictionScale = 1.45,
		WheelMinFriction = 0.9,
		WheelMaxFriction = 2.5,
		WheelFrictionWeight = 3,
		WheelElasticityWeight = 2,

		PassiveRollingFrictionTorque = 0.45,
		DefaultBrakeTorque = 150,
		SteeringServoMaxTorque = 150000,
		SteeringAngularResponsiveness = 120,

		AxleGroupLongitudinalToleranceStuds = 0.75,
		CenterLineToleranceStuds = 0.35,
		OrientationAxisMinAlignment = 0.55,
		OrientationUpFlatBlockDot = 0.72,

		EstimatedStudioMassByItemId = {
			WoodBeam = 1.4,
			WoodBlock = 2.8,
			DriverSeat = 2.8,
			SmallWheel = 4.08,
			SmallEngine = 62.8,
			SmallBooster = 52.99,
			RegularFuelTank = 94.2,
			SmallNitroTank = 94.2,
		},
	},

	-- Sistema de motores modulares, transmisión de potencia, variantes y rarezas (Fase 3.3)
	Powertrain = {
		DefaultFamilyId = "StandardCombustion",
		DefaultSizeId = "Small",
		DefaultVariantId = "Balanced",
		DefaultRarityId = "Common",

		-- Límites configurables por pieza en taller
		MinPowerLimitRatio = 0.25,
		MaxPowerLimitRatio = 1.0,
		DefaultPowerLimitRatio = 1.0,
		DefaultThrottleResponseMode = "Balanced",

		-- Transmisión automática de 4 relaciones + Reversa (calibración física provisional)
		FinalDriveRatio = 3.8,
		TransmissionEfficiency = 0.90,
		ForwardGearRatios = { 3.20, 2.15, 1.48, 1.00 },
		ReverseGearRatio = 2.85,
		UpshiftNormalizedRPM = 0.82,
		DownshiftNormalizedRPM = 0.42,
		GearShiftCooldownSeconds = 0.18,

		-- Límites de velocidad en reversa y transición segura Adelante <-> Reversa
		ReverseMaxSpeedRatio = 0.45, -- Fracción de SpeedRegular en reversa
		ReverseTorqueRatio = 0.78,
		ReverseEngageMaxForwardSpeed = 2.2, -- studs/s máximos hacia adelante antes de enganchar reversa
		ReverseEngageMaxBackwardSpeed = 2.2, -- studs/s máximos hacia atrás antes de re-enganchar adelante

		-- Freno de servicio (S en movimiento opuesto)
		ServiceBrakeBaseTorquePerWheel = 3400,
		CoastEngineBrakeTorqueScale = 0.22,
		IdleCreepThreshold = 0.04,

		-- Combinación multimotor: eficiencia decreciente suave + tope técnico de estabilidad PGS
		MultiEngineEfficiencyDecay = 0.92, -- Cada motor adicional aporta 92% respecto al escalado lineal
		MaxCombinedEngines = 8,
		MaxTotalWheelDriveTorque = 180000,
		MaxPerWheelDriveTorque = 45000,

		-- Dinámica de masa, carga y pendiente
		ReferenceLightVehicleMass = 90.0, -- Masa física Studio medida de chasis ligero estándar (~90.3)
		MassLoadSensitivity = 0.0028, -- Sensibilidad de velocidad tope/RPM ante sobrepeso
		SlopeLoadSensitivity = 1.65, -- Sensibilidad de carga en subida

		-- Combustible (autorizado por servidor; unidad temporal de catálogo SDD = Provisional_TBD)
		ConsumeFuelByDefault = true,
		IdleFuelConsumptionFraction = 0.08,
		-- SDD 04-ITEM-CATALOG define IntegratedFuel=0.54 y MaxConsumptionRegular=0.18 sin unidad temporal explícita (ratio 3.0).
		-- Provisional_TBD: 60.0 interpreta MaxConsumptionRegular como unidades/minuto (0.18/min = 0.0030/s => 180 s a pleno consumo).
		FuelConsumptionTimeBaseSeconds = 60.0,
		LowFuelWarningFraction = 0.20,
		FuelTypeTorqueMultiplier = {
			Regular = 1.00,
			Diesel = 1.08, -- Más torque, menor RPM tope (provisional TBD)
			Competicion = 1.15, -- Mayor potencia (provisional TBD)
		},
		FuelTypeSpeedMultiplier = {
			Regular = 1.00,
			Diesel = 0.94,
			Competicion = 1.12,
		},
		FuelTypeConsumptionMultiplier = {
			Regular = 1.00,
			Diesel = 0.92, -- Provisional_TBD
			Competicion = 1.15, -- Provisional_TBD
		},

		-- Telemetría replicada en atributos de RootModel/DriverSeat
		TelemetryUpdateIntervalSeconds = 0.05,
	},

	-- Sistema de propulsores modulares, Nitro (RocketFuel) y empuje vectorial real (Fase 3.4)
	Boosters = {
		DefaultFamilyId = "StandardRocket",
		DefaultSizeId = "Small",
		DefaultVariantId = "Balanced",
		DefaultRarityId = "Common",

		MinThrustLimitRatio = 0.25,
		MaxThrustLimitRatio = 1.0,
		DefaultThrustLimitRatio = 1.0,
		DefaultThrottleCurveMode = "Smooth",

		-- Geometría de SmallBooster: Conn_Front=(0,0,-1.5), tobera trasera=(0,0,+1.5), empuje físico hacia -Z (LookVector)
		DefaultLocalThrustAxis = Vector3.new(0, 0, -1),
		DefaultNozzleLocalOffset = Vector3.new(0, 0, 1.5),

		-- Combustible Nitro (RocketFuel): separado estrictamente de tanques Normal de Engine
		-- SDD 04-ITEM-CATALOG define IntegratedFuel=24000, BoostConsumption=12000 (ratio 2.0) y SmallNitroTank=28800.
		-- Provisional_TBD: 1.0 interpreta BoostConsumption como unidades/s a pleno empuje (2.0s base + 2.4s por SmallNitroTank).
		ConsumeNitroByDefault = true,
		NitroConsumptionTimeBaseSeconds = 1.0,
		LowNitroWarningFraction = 0.20,
		MinimumOperationalDurabilityFraction = 0.05,

		-- Empuje vectorial PGS y envolvente aerodinámica por SpeedBoostMultiplier (Provisional_TBD)
		ThrustForceScale = 1.0,
		BaseEnvelopeSpeedStudsPerSec = 42.0,
		SpeedMultiplierRangeScale = 38.0,
		HighSpeedTaperFloor = 0.12,
		MaxSingleBoosterAppliedThrust = 160000,
		MaxCombinedBoosters = 12,
		MassContributionFactor = 0.0, -- La masa real viene del PhysicalProperties / AssemblyMass

		-- Guía visual en taller y telemetría replicada
		GuideArrowLengthStuds = 3.2,
		TelemetryUpdateIntervalSeconds = 0.05,
	},
}

table.freeze(GameConfig.PlotAttributes)
table.freeze(GameConfig.ZoneIds)
table.freeze(GameConfig.PlotContainers)
table.freeze(GameConfig.ItemAttributes)
table.freeze(GameConfig.Building.PositionModes)
table.freeze(GameConfig.Building.TransformTools)
table.freeze(GameConfig.Building.GridResolutions)
table.freeze(GameConfig.Building.AngleIncrementsDeg)
table.freeze(GameConfig.Building)
table.freeze(GameConfig.Blueprints)
table.freeze(GameConfig.Inventory)
for _, starterUnit in ipairs(GameConfig.StartingInventory.UniqueUnits) do
	table.freeze(starterUnit)
end
table.freeze(GameConfig.StartingInventory.UniqueUnits)
table.freeze(GameConfig.StartingInventory.Items)
table.freeze(GameConfig.StartingInventory)
table.freeze(GameConfig.Stand)
table.freeze(GameConfig.LaunchPrep)
table.freeze(GameConfig.Runtime.CollisionGroups)
table.freeze(GameConfig.Runtime.States)
table.freeze(GameConfig.Runtime.PartRoles)
table.freeze(GameConfig.Runtime)
table.freeze(GameConfig.Wheels.EstimatedStudioMassByItemId)
table.freeze(GameConfig.Wheels)
table.freeze(GameConfig.Powertrain.ForwardGearRatios)
table.freeze(GameConfig.Powertrain.FuelTypeTorqueMultiplier)
table.freeze(GameConfig.Powertrain.FuelTypeSpeedMultiplier)
table.freeze(GameConfig.Powertrain.FuelTypeConsumptionMultiplier)
table.freeze(GameConfig.Powertrain)
table.freeze(GameConfig.Boosters)

return table.freeze(GameConfig)


