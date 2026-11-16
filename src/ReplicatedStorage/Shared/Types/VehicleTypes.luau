--!strict
--[=[
	VehicleTypes
	Separación estricta entre VehicleBlueprint (diseño persistente autorizado)
	y VehicleRuntime (estado efímero de un intento de conducción).

	Regla SDD: Nunca persistir daño, escombros ni estado temporal del runtime en el blueprint.
]=]

export type VehicleState =
	"Idle"
	| "Editing"
	| "PreparingLaunch"
	| "Launching"
	| "Driving"
	| "OnFootRuntime"
	| "Returning"
	| "ReturningToWorkshop"

export type PartPhysicsRole =
	"RigidStructure"
	| "DriverSeat"
	| "PassengerSeat"
	| "Wheel"
	| "SteeringPivot"
	| "SuspensionCarrier"
	| "Propulsion"
	| "FuturePropulsion"
	| "AerodynamicSurface"
	| "Decorative"

export type WheelSteeringMode = "Auto" | "Enabled" | "Disabled"

export type WheelDriveMode = "Auto" | "Driven" | "Free"

export type WheelAxlePositionRole = "Front" | "Middle" | "Rear" | "SingleAxle" | "Unknown"

export type WheelSideRole = "Left" | "Right" | "Center"

-- Sobrescrituras manuales serializables persistidas opcionalmente en BlueprintPiece.Config.Wheel.
-- Cualquier campo en nil permanece gobernado dinámicamente por Auto / Default del catálogo.
export type WheelPieceConfigOverrides = {
	SteeringMode: ("Enabled" | "Disabled")?,
	MaxSteeringAngle: number?,
	SteeringSpeed: number?,
	SteeringDirectionMultiplier: number?,
	SuspensionEnabled: boolean?,
	SuspensionTravel: number?,
	SpringStiffness: number?,
	SpringDamping: number?,
	RideHeight: number?,
	IsDriven: boolean?,
	DriveDirection: number?,
}

export type WheelPropertySource = "Auto" | "Manual"

export type WheelResolvedSources = {
	SteeringMode: WheelPropertySource,
	MaxSteeringAngle: WheelPropertySource,
	SteeringSpeed: WheelPropertySource,
	SteeringDirectionMultiplier: WheelPropertySource,
	SuspensionEnabled: WheelPropertySource,
	SuspensionTravel: WheelPropertySource,
	SpringStiffness: WheelPropertySource,
	SpringDamping: WheelPropertySource,
	RideHeight: WheelPropertySource,
	IsDriven: WheelPropertySource,
	DriveDirection: WheelPropertySource,
}

export type WheelGeometryAnalysis = {
	PieceInstanceId: string,
	ItemId: string,
	AxleGroupIndex: number,
	TotalAxleGroups: number,
	AxleRole: WheelAxlePositionRole,
	SideRole: WheelSideRole,
	LongitudinalOffset: number,
	LateralOffset: number,
	VerticalOffset: number,
	LocalSpinAxis: Vector3,
	ForwardAlignmentDot: number,
	RightAlignmentDot: number,
	UpAlignmentDot: number,
	WheelRadius: number,
	WheelWidth: number,
	OrientationWarning: string?,
	OrientationBlocksSteering: boolean,
	OrientationBlocksSuspension: boolean,
	IsAmbiguous: boolean,
	AmbiguityReason: string?,
	HasSeatReference: boolean,
}

export type ResolvedWheelConfig = {
	PieceInstanceId: string,
	ItemId: string,
	WheelRadius: number,
	WheelWidth: number,
	LocalSpinAxis: Vector3,
	SteeringMode: WheelSteeringMode,
	EffectiveSteeringEnabled: boolean,
	MaxSteeringAngle: number,
	SteeringSpeed: number,
	SteeringDirectionMultiplier: number,
	SuspensionEnabled: boolean,
	EffectiveSuspensionEnabled: boolean,
	SuspensionTravel: number,
	SpringStiffness: number,
	SpringDamping: number,
	RideHeight: number,
	IsDriven: boolean,
	DriveDirection: number,
	HasManualOverrides: boolean,
	Sources: WheelResolvedSources,
	Analysis: WheelGeometryAnalysis,
	Warnings: { string },
}

export type VehicleWheelAnalysis = {
	HasSeatReference: boolean,
	VehicleForward: Vector3,
	VehicleRight: Vector3,
	VehicleUp: Vector3,
	WheelCount: number,
	AxleCount: number,
	EstimatedChassisMass: number,
	IsAmbiguous: boolean,
	AmbiguityWarnings: { string },
	ByPieceId: { [string]: ResolvedWheelConfig },
	OrderedWheelIds: { string },
}

export type WheelDriveCommand = {
	TargetAngularVelocity: number?,
	TorqueLimit: number?,
	BrakeTorque: number?,
}

export type WheelRuntimeState = {
	WheelId: string,
	PieceInstanceId: string,
	ItemId: string,
	MountPieceId: string?,
	IsDriven: boolean,
	DriveDirection: number,
	WheelRadius: number,
	WheelWidth: number,
	AngularVelocity: number,
	TargetAngularVelocity: number,
	TorqueLimit: number,
	BrakeTorque: number,
	SteeringEnabled: boolean,
	SteeringAngle: number,
	TargetSteeringAngle: number,
	MaxSteeringAngle: number,
	SteeringSpeed: number,
	SuspensionEnabled: boolean,
	SuspensionLength: number,
	ContactState: boolean,
	IsFunctional: boolean,
	ResolvedConfig: ResolvedWheelConfig,
}

export type BlueprintConnection = {
	FromPieceId: string,
	FromAttachment: string,
	ToPieceId: string,
	ToAttachment: string,
}

export type BlueprintPiece = {
	InstanceId: string,
	ItemId: string,
	LocalCFrame: CFrame,
	InventoryInstanceId: string?, -- Único para motores/propulsores con rareza
	Config: { [string]: any }?, -- Ej: FuelType seleccionado en RegularFuelTank
}

export type StandPresentationConfig = {
	HeightOffset: number,
	LateralOffset: number,
}

-- Estado temporal del elevador de construcción dentro de BuildZone (no persiste en piezas)
export type BuildAssemblyOffset = StandPresentationConfig

export type LiftBounds = {
	MinHeightOffset: number,
	MaxHeightOffset: number,
	MinLateralOffset: number,
	MaxLateralOffset: number,
	DefaultRestHeightOffset: number,
	DefaultRestLateralOffset: number,
	VehicleBoundsMin: Vector3?,
	VehicleBoundsMax: Vector3?,
}

export type PartBoxSpec = {
	LocalCFrame: CFrame, -- CFrame relativo al origen/PrimaryPart del modelo
	Size: Vector3,
}

export type AssemblyRole = "PrimaryAssembly" | "SecondaryAssembly" | "LoosePiece"

export type AssemblyComponentSummary = {
	GroupId: string,
	PieceIds: { string },
	PieceCount: number,
	DriverSeatCount: number,
	HasDriverSeat: boolean,
	Role: AssemblyRole,
	BoundsMin: Vector3?,
	BoundsMax: Vector3?,
}

export type AssemblyAnalysis = {
	Groups: { AssemblyComponentSummary },
	GroupIdByPieceId: { [string]: string },
	RoleByPieceId: { [string]: AssemblyRole },
	PrimaryGroupId: string?,
	PrimaryPieceIds: { string },
	WorkshopPieceIds: { string },
	DriverSeatGroupIds: { string },
	NeedsPrimarySelection: boolean,
	AmbiguousPrimary: boolean,
}

export type BlueprintMetadata = {
	SourceBlueprintId: string?,
	Description: string?,
	LastLaunchValidatedAt: number?,
	PrimaryAssemblyGroupId: string?,
	SourceSlotIndex: number?,
	SavedBlueprintId: string?,
	SavedRevision: number?,
	SourceRevision: number?,
}

export type VehicleBlueprint = {
	SchemaVersion: number,
	BlueprintId: string,
	OwnerUserId: number,
	Name: string,
	Revision: number,
	CreatedAt: number,
	UpdatedAt: number,
	VehicleOrigin: CFrame,
	Presentation: StandPresentationConfig,
	Metadata: BlueprintMetadata?,
	Pieces: { BlueprintPiece },
	Connections: { BlueprintConnection },
}

export type BlueprintSummary = {
	BlueprintId: string,
	Name: string,
	SchemaVersion: number,
	Revision: number,
	PieceCount: number,
	CreatedAt: number,
	UpdatedAt: number,
	IsActive: boolean,
	HasUnsavedChanges: boolean,
	Presentation: StandPresentationConfig,
}

export type BlueprintSlotState = "Empty" | "Saved"

export type BlueprintSlotSummary = {
	SlotIndex: number,
	State: BlueprintSlotState,
	IsOccupied: boolean,
	BlueprintId: string?,
	Name: string?,
	PieceCount: number,
	Revision: number?,
	CreatedAt: number?,
	UpdatedAt: number?,
	IsLoadedInWorkshop: boolean,
	HasUnsavedChanges: boolean,
}

export type LegacyOverflowSummary = {
	OriginalBlueprintId: string,
	Name: string,
	PieceCount: number,
	UpdatedAt: number,
	MigratedAt: number,
	RecoveredToSlot: number?,
}

export type LegacyOverflowEntry = {
	OriginalBlueprintId: string,
	Name: string,
	PieceCount: number,
	UpdatedAt: number,
	MigratedAt: number,
	RecoveredToSlot: number?,
	SerializedBlueprint: { [string]: any },
}

export type PlayerBlueprintStorage = {
	StorageSchemaVersion: number,
	OwnerUserId: number,
	StorageRevision: number,
	UpdatedAt: number,
	WorkshopDraft: VehicleBlueprint?,
	Slots: { [string]: VehicleBlueprint? },
	LegacyOverflow: { LegacyOverflowEntry }?,
}

export type LaunchIssueCategory = "BuildError" | "ConfigError" | "LocationError"

export type LaunchIssue = {
	Category: LaunchIssueCategory,
	Code: string,
	Message: string,
}

export type LaunchPreparationReport = {
	Ready: boolean,
	ErrorCategory: LaunchIssueCategory?,
	PrimaryErrorCode: string?,
	PrimaryErrorMessage: string?,
	Issues: { LaunchIssue },
	BlueprintId: string?,
	BlueprintRevision: number,
	PieceCount: number,
	TotalPieceCount: number?,
	WorkshopPieceCount: number?,
	PrimaryAssemblyGroupId: string?,
	PrimaryAssemblyPieceIds: { string }?,
	WorkshopPieceIds: { string }?,
	AssemblyGroups: { AssemblyComponentSummary }?,
	DisconnectedGroupCount: number?,
	NeedsPrimarySelection: boolean?,
	DriverSeatCount: number,
	DriverSeatPieceId: string?,
	WheelCount: number?,
	WheelWarnings: { string }?,
	EngineCount: number?,
	DrivenWheelCount: number?,
	PowertrainWarnings: { string }?,
	BoosterCount: number?,
	FunctionalBoosterCount: number?,
	TotalBoosterThrust: number?,
	TotalNormalFuelCapacity: number?,
	TotalNitroCapacity: number?,
	BoosterWarnings: { string }?,
	BoundsMin: Vector3?,
	BoundsMax: Vector3?,
	BoundingSize: Vector3?,
	GroundClearance: number?,
	LaunchAnchorCFrame: CFrame?,
	CenterWorldCFrame: CFrame?,
	ObstructingPartNames: { string }?,
}

-- Estado temporal por pieza durante un intento de conducción.
-- CurrentDurability, CurrentHealth y CurrentFuel existen EXCLUSIVAMENTE en runtime.
export type PieceHealthState = "Healthy" | "Damaged" | "Disabled"

export type RuntimePartState = {
	PieceId: string?,
	PieceInstanceId: string,
	ItemId: string,
	Category: string?,
	CurrentDurability: number,
	MaxDurability: number,
	Durability: number?,
	MaxHealth: number?,
	CurrentHealth: number?,
	ImpactResistance: number?,
	DamageMultiplier: number?,
	HealthState: PieceHealthState?,
	DamageReceivedTotal: number?,
	ImpactCount: number?,
	LastImpactAt: number?,
	LastImpactRelativeSpeed: number?,
	LastImpactMagnitude: number?,
	CurrentFuel: number?,
	IsDestroyed: boolean?,
	IsDetached: boolean,
	IsFunctional: boolean,
	ModelInstance: Model?,
	PhysicsRole: PartPhysicsRole?,
	PrimaryPart: BasePart?,
	Config: { [string]: any }?,
}

export type RuntimeStatusSnapshot = {
	State: VehicleState,
	RuntimeId: string?,
	PlotId: string?,
	SourceBlueprintId: string?,
	SourceBlueprintRevision: number?,
	DriverSeated: boolean,
	PieceCount: number,
	JointCount: number,
	AbandonedSince: number?,
	ErrorCode: string?,
	ErrorMessage: string?,
}

export type VehicleRuntime = {
	RuntimeId: string,
	OwnerUserId: number,
	PlotId: string,
	SourceBlueprintRevision: number,
	State: VehicleState,
	Parts: { [string]: RuntimePartState },
	RootModel: Model?,
	StartedAt: number,
	SourceBlueprintId: string?,
	PrimaryPart: BasePart?,
	DriverSeatPart: VehicleSeat?,
	DriverSeatDestroyed: boolean?,
	Joints: { WeldConstraint }?,
	WheelPieceIds: { string }?,
	WheelConstraints: { Instance }?,
	WheelMechanisms: { [string]: any }?,
	PropulsionPieceIds: { string }?,
	EnginePieceIds: { string }?,
	FuelTankPieceIds: { string }?,
	BoosterPieceIds: { string }?,
	NitroTankPieceIds: { string }?,
	AerodynamicPieceIds: { string }?,
	PieceAdjacencyById: { [string]: { string } }?,
	NetworkOwnerUserId: number?,
	AbandonedSince: number?,
}

-- Fase 3.3: Configuración persistida en BlueprintPiece.Config.Engine y estado runtime de motores
export type EnginePieceConfig = {
	EngineFamilyId: string?,
	EngineSizeId: ("Small" | "Medium" | "Large")?,
	VariantId: string?,
	RarityId: ("Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic")?,
	PowerLimitRatio: number?, -- 0.25 .. 1.0 (ajuste opcional en taller)
	ThrottleResponseMode: ("Smooth" | "Balanced" | "Sport")?,
	Enabled: boolean?,
}

export type FuelTankPieceConfig = {
	SelectedFuelType: ("Regular" | "Diesel" | "Competicion")?,
}

export type PowertrainGearState = "Forward" | "Neutral" | "Braking" | "Reverse"

export type DrivingControlIntent = {
	Throttle: number, -- 0 .. 1 (acelerador hacia delante)
	Brake: number, -- 0 .. 1 (freno / reversa cuando S está presionado)
	RawLongitudinal: number, -- -1 .. 1 (W=+1, S=-1, analógico)
	Steer: number, -- -1 .. 1 (A=-1, D=+1)
	Boost: boolean?, -- LeftShift / botón táctil BOOST (Fase 3.4)
	Timestamp: number?,
}

export type EngineRuntimeState = {
	PieceInstanceId: string,
	ItemId: string,
	InventoryInstanceId: string?,
	EngineFamilyId: string,
	EngineSizeId: string,
	VariantId: string,
	RarityId: string,
	IsFunctional: boolean,
	IsDetached: boolean,
	Enabled: boolean,
	PowerLimitRatio: number,
	ThrottleResponseMode: string,
	DurabilityEfficiencyFactor: number, -- 0 .. 1 temporal según CurrentDurability / MaxDurability
	CurrentRPM: number,
	TargetRPM: number,
	IdleRPM: number,
	OptimumRPM: number,
	MaxRPM: number,
	LimiterRPM: number,
	LimiterActive: boolean,
	CurrentTorque: number,
	AvailableWheelTorque: number,
	CurrentPower: number,
	LoadFactor: number, -- 0 .. 1
	FuelConsumptionRate: number,
	EffectiveStats: any, -- ItemTypes.EffectiveEngineStats
}

export type PowertrainTelemetrySnapshot = {
	RuntimeId: string,
	OwnerUserId: number,
	EngineCount: number,
	FunctionalEngineCount: number,
	DrivenWheelCount: number,
	FreeWheelCount: number,
	TotalWheelCount: number,
	TotalVehicleMass: number,
	AverageDrivenWheelRadius: number,
	SpeedStudsPerSec: number,
	LongitudinalSpeed: number,
	SlopeDegrees: number,
	SlopeGradeRatio: number,
	GearState: PowertrainGearState,
	ActiveGearIndex: number,
	ActiveGearRatio: number,
	ThrottleInput: number,
	BrakeInput: number,
	SteerInput: number,
	CombinedRPM: number,
	CombinedMaxRPM: number,
	LimiterActive: boolean,
	TotalEngineTorque: number,
	TotalWheelDriveTorque: number,
	PerDrivenWheelTorque: number,
	TargetWheelAngularVelocity: number,
	AppliedBrakeTorque: number,
	CombinedPowerOutput: number,
	CombinedLoadFactor: number,
	MultiEngineEfficiencyFactor: number,
	TotalFuelCapacity: number,
	AvailableFuel: number,
	FuelFraction: number,
	FuelConsumptionRate: number,
	ConsumedFuel: number,
	LowFuel: boolean,
	OutOfFuel: boolean,
	NoDrivenWheelsError: boolean,
	Engines: { EngineRuntimeState },
}

-- Fase 3.4: Configuración persistida en BlueprintPiece.Config.Booster y telemetría runtime de propulsión vectorial
export type BoosterPieceConfig = {
	BoosterFamilyId: string?,
	BoosterSizeId: ("Small" | "Medium" | "Large")?,
	VariantId: string?,
	RarityId: ("Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic")?,
	ThrustLimitRatio: number?, -- 0.25 .. 1.0 (ajuste opcional en taller)
	ThrottleCurveMode: ("Instant" | "Smooth" | "Sustained")?,
	Enabled: boolean?,
}

export type BoosterLifecycleState = "Idle" | "Igniting" | "Active" | "RampDown" | "Depleted" | "Disabled" | "Destroyed"

export type BoosterRuntimeState = {
	PieceInstanceId: string,
	ItemId: string,
	InventoryInstanceId: string?,
	BoosterFamilyId: string,
	BoosterSizeId: string,
	VariantId: string,
	RarityId: string,
	IsFunctional: boolean,
	IsDetached: boolean,
	Enabled: boolean,
	ThrustLimitRatio: number,
	ThrottleCurveMode: string,
	DurabilityEfficiencyFactor: number,
	BoosterState: BoosterLifecycleState,
	ThrottleFraction: number,
	TargetThrottleFraction: number,
	AppliedThrust: number,
	EffectiveThrustMax: number,
	LocalThrustAxis: Vector3,
	WorldThrustDirection: Vector3,
	NitroConsumptionRate: number,
	EffectiveStats: any, -- ItemTypes.EffectiveBoosterStats
}

export type BoosterTelemetrySnapshot = {
	RuntimeId: string,
	OwnerUserId: number,
	BoosterCount: number,
	FunctionalBoosterCount: number,
	ActiveBoosterCount: number,
	BoostInputActive: boolean,
	AnyBoosterActive: boolean,
	SpeedStudsPerSec: number,
	TotalAppliedThrust: number,
	MaxPossibleThrust: number,
	NetThrustVector: Vector3,
	TotalNitroCapacity: number,
	AvailableNitro: number,
	NitroFraction: number,
	NitroConsumptionRate: number,
	ConsumedNitro: number,
	LowNitro: boolean,
	OutOfNitro: boolean,
	Boosters: { BoosterRuntimeState },
}

-- Fase 4.1: Contratos de durabilidad estructural, impactos y telemetría de daño (runtime temporal)
export type PieceDamageRecord = {
	PieceId: string,
	PieceInstanceId: string,
	ItemId: string,
	Category: string,
	MaxHealth: number,
	CurrentHealth: number,
	Durability: number,
	ImpactResistance: number,
	DamageMultiplier: number,
	IntegrityRatio: number,
	IntegrityPercent: number,
	State: PieceHealthState,
	DamageReceivedTotal: number,
	ImpactCount: number,
	LastImpactAt: number?,
	LastImpactRelativeSpeed: number?,
	LastImpactMagnitude: number?,
	BalanceStatus: string,
}

export type DamageDistributionTarget = {
	PieceId: string,
	Weight: number,
	HopDistance: number,
	DistanceFromImpact: number,
	IsPrimaryTarget: boolean,
}

export type DamageImpactContext = {
	SourceType: ("Impact" | "Terrain" | "StaticObstacle" | "DynamicObject" | "VehicleRuntime" | "DevTest" | "API")?,
	OtherName: string?,
	OtherUserId: number?,
	OtherPieceId: string?,
	ImpactPosition: Vector3?,
	ImpactNormal: Vector3?,
	RelativeSpeed: number?,
	NormalSpeed: number?,
	EffectiveMass: number?,
	EstimatedImpulse: number?,
	EstimatedEnergy: number?,
	ImpactMagnitude: number?,
	DamageAmount: number?,
	Timestamp: number?,
	SkipDistribution: boolean?,
	Reason: string?,
}

export type DamageImpactResult = {
	Applied: boolean,
	Reason: string?,
	RuntimeId: string?,
	PrimaryPieceId: string,
	TotalDamageApplied: number,
	PrimaryDamageApplied: number,
	NewDurability: number,
	NewHealth: number,
	MaxHealth: number,
	PrimaryState: PieceHealthState,
	AffectedPieceIds: { string },
	DamageByPieceId: { [string]: number },
	BrokenParts: { string },
	DetachedParts: { string },
}

export type VehicleHealthSummary = {
	RuntimeId: string,
	OwnerUserId: number,
	TotalPieces: number,
	HealthyCount: number,
	DamagedCount: number,
	DisabledCount: number,
	ExhaustedCount: number,
	TotalMaxHealth: number,
	TotalCurrentHealth: number,
	IntegrityRatio: number,
	IntegrityPercent: number,
	TotalDamageReceived: number,
	ImpactCount: number,
	LastImpactAt: number?,
	LastImpactSpeed: number?,
	LastImpactMagnitude: number?,
	LastImpactPieceId: string?,
}

export type DebugImpactRecord = {
	Timestamp: number,
	PieceId: string,
	ItemId: string,
	OtherName: string,
	SourceType: string,
	RelativeSpeed: number,
	NormalSpeed: number,
	EffectiveMass: number,
	EstimatedImpulse: number,
	EstimatedEnergy: number,
	ImpactMagnitude: number,
	TotalDamageApplied: number,
	PrimaryDamageApplied: number,
	PrimaryHealthAfter: number,
	PrimaryMaxHealth: number,
	AffectedCount: number,
}

-- Fase 5.3: Contratos del sistema modular de aerodinámica en runtime
export type AeroSurfaceType = "Wing" | "Tail" | "Glider"

export type AeroControlSurfaceRole = "None" | "Aileron" | "Elevator" | "Rudder"

export type AeroFlightControlInputs = {
	Pitch: number?,
	Roll: number?,
	Yaw: number?,
}

export type AeroSurfaceRuntimeState = {
	PieceInstanceId: string,
	ItemId: string,
	SurfaceType: AeroSurfaceType,
	Side: string,
	ControlRole: AeroControlSurfaceRole,
	IsFunctional: boolean,
	IsDetached: boolean,
	IsStalled: boolean,
	Airspeed: number,
	ChordAirspeed: number,
	AngleOfAttackDeg: number,
	SideslipAngleDeg: number,
	LiftCoefficient: number,
	DragCoefficient: number,
	SideForceCoefficient: number,
	LiftForceMagnitude: number,
	DragForceMagnitude: number,
	SideForceMagnitude: number,
	LiftVectorWorld: Vector3,
	DragVectorWorld: Vector3,
	SideForceVectorWorld: Vector3,
	TotalForceWorld: Vector3,
	WorldApplicationPosition: Vector3,
	TorqueAboutCoMWorld: Vector3,
}

export type AerodynamicsTelemetrySnapshot = {
	RuntimeId: string,
	OwnerUserId: number,
	SurfaceCount: number,
	FunctionalSurfaceCount: number,
	ActiveForceSurfaceCount: number,
	StalledSurfaceCount: number,
	VehicleSpeedStudsPerSec: number,
	TotalLiftMagnitude: number,
	TotalDragMagnitude: number,
	TotalSideForceMagnitude: number,
	NetLiftVectorWorld: Vector3,
	NetDragVectorWorld: Vector3,
	NetAeroForceWorld: Vector3,
	NetAeroTorqueAboutCoMWorld: Vector3,
	Surfaces: { AeroSurfaceRuntimeState },
}

return nil


