--!strict
--[=[
	BuildProtocol
	Contratos de red, tipos de solicitud/respuesta y códigos de error
	para el sistema de construcción autoritativo (Fase 2.2).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type PlacePieceRequest = {
	Action: "PlacePiece",
	ClientOpId: string,
	ItemId: string,
	LocalCFrame: CFrame, -- Relativo al CFrame de BuildZone de la estación
	Config: { [string]: any }?,
	InventoryInstanceId: string?,
	ExpectedBlueprintId: string?,
}

export type RemovePieceRequest = {
	Action: "RemovePiece",
	ClientOpId: string,
	PieceInstanceId: string,
	ExpectedBlueprintId: string?,
}

export type TransformPieceRequest = {
	Action: "TransformPiece",
	ClientOpId: string,
	PieceInstanceId: string,
	LocalCFrame: CFrame, -- Nueva posición/orientación relativa al CFrame de BuildZone
	ExpectedBlueprintId: string?,
}

export type GetBlueprintRequest = {
	Action: "GetBlueprint",
	ClientOpId: string?,
}

export type ListBlueprintsRequest = {
	Action: "ListBlueprints",
	ClientOpId: string?,
}

export type CreateBlueprintRequest = {
	Action: "CreateBlueprint",
	ClientOpId: string,
	Name: string?,
}

export type SaveBlueprintRequest = {
	Action: "SaveBlueprint",
	ClientOpId: string,
	Name: string?,
	SaveAsNew: boolean?,
}

export type LoadBlueprintRequest = {
	Action: "LoadBlueprint",
	ClientOpId: string,
	BlueprintId: string,
}

export type SetActiveBlueprintRequest = {
	Action: "SetActiveBlueprint",
	ClientOpId: string,
	BlueprintId: string,
}

export type DuplicateBlueprintRequest = {
	Action: "DuplicateBlueprint",
	ClientOpId: string,
	BlueprintId: string,
	Name: string?,
}

export type RenameBlueprintRequest = {
	Action: "RenameBlueprint",
	ClientOpId: string,
	BlueprintId: string,
	Name: string,
}

export type DeleteBlueprintRequest = {
	Action: "DeleteBlueprint",
	ClientOpId: string,
	BlueprintId: string,
}

export type ListBlueprintSlotsRequest = {
	Action: "ListBlueprintSlots",
	ClientOpId: string?,
}

export type SaveBlueprintSlotRequest = {
	Action: "SaveBlueprintSlot",
	ClientOpId: string,
	SlotIndex: number,
	Name: string?,
	ExpectedRevision: number?,
}

export type LoadBlueprintSlotRequest = {
	Action: "LoadBlueprintSlot",
	ClientOpId: string,
	SlotIndex: number,
	ConfirmDiscardUnsaved: boolean?,
}

export type OverwriteBlueprintSlotRequest = {
	Action: "OverwriteBlueprintSlot",
	ClientOpId: string,
	SlotIndex: number,
	Name: string?,
	ConfirmationStep: number,
	ExpectedSlotRevision: number?,
	ExpectedWorkshopRevision: number?,
}

export type RenameBlueprintSlotRequest = {
	Action: "RenameBlueprintSlot",
	ClientOpId: string,
	SlotIndex: number,
	Name: string,
}

export type DeleteBlueprintSlotRequest = {
	Action: "DeleteBlueprintSlot",
	ClientOpId: string,
	SlotIndex: number,
	ConfirmationName: string?,
}

export type ClearWorkshopRequest = {
	Action: "ClearWorkshop",
	ClientOpId: string,
	ExpectedRevision: number?,
	ExpectedEpoch: number?,
}

export type RecoverLegacyBlueprintRequest = {
	Action: "RecoverLegacyBlueprint",
	ClientOpId: string,
	OriginalBlueprintId: string,
	TargetSlotIndex: number,
	ConfirmationStep: number?,
}

export type SetStandOffsetRequest = {
	Action: "SetStandOffset",
	ClientOpId: string,
	HeightOffset: number,
	LateralOffset: number,
}

export type ResetStandOffsetRequest = {
	Action: "ResetStandOffset",
	ClientOpId: string,
}

export type ValidateLaunchPrepRequest = {
	Action: "ValidateLaunchPrep",
	ClientOpId: string?,
}

export type SelectPrimaryAssemblyRequest = {
	Action: "SelectPrimaryAssembly",
	ClientOpId: string,
	GroupId: string,
}

export type UpdatePieceConfigRequest = {
	Action: "UpdatePieceConfig",
	ClientOpId: string,
	PieceInstanceId: string,
	Config: { [string]: any }?,
	InventoryInstanceId: string?,
	ResetToAuto: boolean?,
	ExpectedBlueprintId: string?,
}

export type GetInventoryRequest = {
	Action: "GetInventory",
	ClientOpId: string?,
}

export type SellInventoryItemRequest = {
	Action: "SellInventoryItem",
	ClientOpId: string,
	ItemId: string,
	Quantity: number?,
	ItemInstanceId: string?,
}

export type UnlinkInventoryFromBlueprintsRequest = {
	Action: "UnlinkInventoryFromBlueprints",
	ClientOpId: string,
	ItemId: string?,
	ItemInstanceId: string?,
	TargetSlotIndices: { number }?,
	Confirmed: boolean?,
}

export type BuildRequest =
	PlacePieceRequest
	| RemovePieceRequest
	| TransformPieceRequest
	| UpdatePieceConfigRequest
	| GetInventoryRequest
	| SellInventoryItemRequest
	| UnlinkInventoryFromBlueprintsRequest
	| GetBlueprintRequest
	| ListBlueprintsRequest
	| CreateBlueprintRequest
	| SaveBlueprintRequest
	| LoadBlueprintRequest
	| SetActiveBlueprintRequest
	| DuplicateBlueprintRequest
	| RenameBlueprintRequest
	| DeleteBlueprintRequest
	| ListBlueprintSlotsRequest
	| SaveBlueprintSlotRequest
	| LoadBlueprintSlotRequest
	| OverwriteBlueprintSlotRequest
	| RenameBlueprintSlotRequest
	| DeleteBlueprintSlotRequest
	| ClearWorkshopRequest
	| RecoverLegacyBlueprintRequest
	| SetStandOffsetRequest
	| ResetStandOffsetRequest
	| ValidateLaunchPrepRequest
	| SelectPrimaryAssemblyRequest

export type BuildOperationResponse = {
	Success: boolean,
	ClientOpId: string?,
	ErrorCode: string?,
	ErrorMessage: string?,
	Revision: number,
	BlueprintId: string?,
	OwnerUserId: number?,
	PlacedPiece: VehicleTypes.BlueprintPiece?,
	RemovedPieceId: string?,
	TransformedPiece: VehicleTypes.BlueprintPiece?,
	UpdatedPiece: VehicleTypes.BlueprintPiece?,
	Connections: { VehicleTypes.BlueprintConnection }?,
	Blueprint: VehicleTypes.VehicleBlueprint?,
	Blueprints: { VehicleTypes.BlueprintSummary }?,
	Slots: { VehicleTypes.BlueprintSlotSummary }?,
	SlotIndex: number?,
	LoadedSlotIndex: number?,
	WorkshopPieceCount: number?,
	WorkshopEpoch: number?,
	LegacyOverflowCount: number?,
	LegacyOverflow: { VehicleTypes.LegacyOverflowSummary }?,
	DuplicatedBlueprint: VehicleTypes.BlueprintSummary?,
	HasUnsavedChanges: boolean?,
	MaxBlueprints: number?,
	Presentation: VehicleTypes.StandPresentationConfig?,
	BuildAssemblyOffset: VehicleTypes.BuildAssemblyOffset?,
	LiftBounds: VehicleTypes.LiftBounds?,
	LaunchPrepReport: VehicleTypes.LaunchPreparationReport?,
	AssemblyAnalysis: VehicleTypes.AssemblyAnalysis?,
	RuntimeStatus: VehicleTypes.RuntimeStatusSnapshot?,
	ExitDestination: CFrame?,
	EngineUnits: { any }?,
	PowertrainState: VehicleTypes.PowertrainTelemetrySnapshot?,
	BoosterUnits: { any }?,
	BoosterState: VehicleTypes.BoosterTelemetrySnapshot?,
	Inventory: any?,
	SellResult: {
		SoldItemId: string,
		SoldQuantity: number,
		RemovedUnitId: string?,
		SellValue: number?,
		CurrencyNote: string,
	}?,
	UnlinkPreview: {
		TargetItemId: string?,
		TargetUnitId: string?,
		AffectedSlotIndices: { number },
		AffectedWorkshop: boolean,
		AffectedPieceCount: number,
	}?,
	BlockedInWorkshop: boolean?,
	BlockedSlotIndices: { number }?,
	ConfirmationRequired: boolean?,
}

export type BlueprintSyncEventType =
	"FullSync"
	| "PiecePlaced"
	| "PieceRemoved"
	| "PieceTransformed"
	| "PieceConfigUpdated"
	| "BlueprintReset"
	| "BlueprintLoaded"
	| "WorkshopCleared"
	| "StandPresentationUpdated"
	| "BlueprintLibraryUpdated"
	| "SlotLibraryUpdated"
	| "AssemblySelectionUpdated"
	| "RuntimeStateUpdated"
	| "InventoryUpdated"

export type BlueprintSyncPayload = {
	Type: BlueprintSyncEventType,
	OwnerUserId: number,
	BlueprintId: string,
	Revision: number,
	ClientOpId: string?,
	PlacedPiece: VehicleTypes.BlueprintPiece?,
	ConnectionsAdded: { VehicleTypes.BlueprintConnection }?,
	RemovedPieceId: string?,
	TransformedPiece: VehicleTypes.BlueprintPiece?,
	UpdatedPiece: VehicleTypes.BlueprintPiece?,
	UpdatedConnections: { VehicleTypes.BlueprintConnection }?,
	Blueprint: VehicleTypes.VehicleBlueprint?,
	Blueprints: { VehicleTypes.BlueprintSummary }?,
	Slots: { VehicleTypes.BlueprintSlotSummary }?,
	LoadedSlotIndex: number?,
	WorkshopPieceCount: number?,
	WorkshopEpoch: number?,
	LegacyOverflowCount: number?,
	LegacyOverflow: { VehicleTypes.LegacyOverflowSummary }?,
	HasUnsavedChanges: boolean?,
	Presentation: VehicleTypes.StandPresentationConfig?,
	BuildAssemblyOffset: VehicleTypes.BuildAssemblyOffset?,
	Metadata: VehicleTypes.BlueprintMetadata?,
	AssemblyAnalysis: VehicleTypes.AssemblyAnalysis?,
	RuntimeStatus: VehicleTypes.RuntimeStatusSnapshot?,
	Inventory: any?,
}

local BuildProtocol = {
	RemoteFunctionName = "BuildOperationRequest",
	SyncRemoteEventName = "BlueprintSyncEvent",
	DrivingInputRemoteEventName = "VehicleDrivingInputEvent",

	Actions = {
		PlacePiece = "PlacePiece",
		RemovePiece = "RemovePiece",
		TransformPiece = "TransformPiece",
		UpdatePieceConfig = "UpdatePieceConfig",
		GetBlueprint = "GetBlueprint",
		ListBlueprints = "ListBlueprints",
		CreateBlueprint = "CreateBlueprint",
		SaveBlueprint = "SaveBlueprint",
		LoadBlueprint = "LoadBlueprint",
		SetActiveBlueprint = "SetActiveBlueprint",
		DuplicateBlueprint = "DuplicateBlueprint",
		RenameBlueprint = "RenameBlueprint",
		DeleteBlueprint = "DeleteBlueprint",
		ListBlueprintSlots = "ListBlueprintSlots",
		SaveBlueprintSlot = "SaveBlueprintSlot",
		LoadBlueprintSlot = "LoadBlueprintSlot",
		OverwriteBlueprintSlot = "OverwriteBlueprintSlot",
		RenameBlueprintSlot = "RenameBlueprintSlot",
		DeleteBlueprintSlot = "DeleteBlueprintSlot",
		ClearWorkshop = "ClearWorkshop",
		RecoverLegacyBlueprint = "RecoverLegacyBlueprint",
		SetStandOffset = "SetStandOffset",
		ResetStandOffset = "ResetStandOffset",
		ValidateLaunchPrep = "ValidateLaunchPrep",
		SelectPrimaryAssembly = "SelectPrimaryAssembly",
		LaunchVehicle = "LaunchVehicle",
		ReturnToWorkshop = "ReturnToWorkshop",
		ResetVehicle = "ResetVehicle",
		ExitVehicleSeat = "ExitVehicleSeat",
		GetRuntimeState = "GetRuntimeState",
		GetEngineUnits = "GetEngineUnits",
		GetBoosterUnits = "GetBoosterUnits",
		GetInventory = "GetInventory",
		SellInventoryItem = "SellInventoryItem",
		UnlinkInventoryFromBlueprints = "UnlinkInventoryFromBlueprints",
		SetDrivingInput = "SetDrivingInput",
	},

	SyncTypes = {
		FullSync = "FullSync",
		PiecePlaced = "PiecePlaced",
		PieceRemoved = "PieceRemoved",
		PieceTransformed = "PieceTransformed",
		PieceConfigUpdated = "PieceConfigUpdated",
		BlueprintReset = "BlueprintReset",
		BlueprintLoaded = "BlueprintLoaded",
		WorkshopCleared = "WorkshopCleared",
		StandPresentationUpdated = "StandPresentationUpdated",
		BlueprintLibraryUpdated = "BlueprintLibraryUpdated",
		SlotLibraryUpdated = "SlotLibraryUpdated",
		AssemblySelectionUpdated = "AssemblySelectionUpdated",
		RuntimeStateUpdated = "RuntimeStateUpdated",
		InventoryUpdated = "InventoryUpdated",
	},

	ErrorCodes = {
		RateLimited = "RateLimited",
		InvalidPayload = "InvalidPayload",
		NoAssignedPlot = "NoAssignedPlot",
		NotPlotOwner = "NotPlotOwner",
		UnknownItem = "UnknownItem",
		MissingAsset = "MissingAsset",
		InvalidCFrame = "InvalidCFrame",
		InvalidRotation = "InvalidRotation",
		OutOfBounds = "OutOfBounds",
		BlockedGeometry = "BlockedGeometry",
		PieceOverlap = "PieceOverlap",
		DisconnectedPiece = "DisconnectedPiece",
		MaxPiecesReached = "MaxPiecesReached",
		PieceNotFound = "PieceNotFound",
		WouldDisconnectVehicle = "WouldDisconnectVehicle",
		OperationTimeout = "OperationTimeout",
		DuplicateInFlight = "DuplicateInFlight",
		BlueprintNotFound = "BlueprintNotFound",
		MaxBlueprintsReached = "MaxBlueprintsReached",
		CannotDeleteLastBlueprint = "CannotDeleteLastBlueprint",
		InvalidBlueprintName = "InvalidBlueprintName",
		StaleBlueprintRevision = "StaleBlueprintRevision",
		StandOffsetOutOfRange = "StandOffsetOutOfRange",
		ElevatorBlocked = "ElevatorBlocked",
		OperationInProgress = "OperationInProgress",
		AmbiguousPrimaryAssembly = "AmbiguousPrimaryAssembly",
		PrimaryAssemblyNotFound = "PrimaryAssemblyNotFound",
		InvalidPlayerState = "InvalidPlayerState",
		LaunchInProgress = "LaunchInProgress",
		RuntimeAlreadyActive = "RuntimeAlreadyActive",
		RuntimeNotActive = "RuntimeNotActive",
		LaunchCooldown = "LaunchCooldown",
		DriverSeatMountFailed = "DriverSeatMountFailed",
		NotRuntimeOwner = "NotRuntimeOwner",
		CharacterNotReady = "CharacterNotReady",
		PlayerDead = "PlayerDead",
		AssemblyBuildFailed = "AssemblyBuildFailed",
		InvalidConfigRange = "InvalidConfigRange",
		PieceNotConfigurable = "PieceNotConfigurable",
		UnknownEngineUnit = "UnknownEngineUnit",
		UnauthorizedEngineUnit = "UnauthorizedEngineUnit",
		DuplicateEngineUnitInBlueprint = "DuplicateEngineUnitInBlueprint",
		UnknownBoosterUnit = "UnknownBoosterUnit",
		UnauthorizedBoosterUnit = "UnauthorizedBoosterUnit",
		DuplicateBoosterUnitInBlueprint = "DuplicateBoosterUnitInBlueprint",
		InvalidBoosterInventoryUnit = "InvalidBoosterInventoryUnit",
		NoDrivenWheels = "NoDrivenWheels",
		NotSeatedDriver = "NotSeatedDriver",
		ForbiddenDirectStatsPayload = "ForbiddenDirectStatsPayload",
		InvalidSlotIndex = "InvalidSlotIndex",
		SlotEmpty = "SlotEmpty",
		SlotOccupied = "SlotOccupied",
		EmptyWorkshopDraft = "EmptyWorkshopDraft",
		TooManyDriverSeats = "TooManyDriverSeats",
		ConfirmationRequired = "ConfirmationRequired",
		PersistenceFailed = "PersistenceFailed",
		LegacyOverflowNotFound = "LegacyOverflowNotFound",
		UnsavedWorkshopConfirmationRequired = "UnsavedWorkshopConfirmationRequired",
		InsufficientInventory = "InsufficientInventory",
		SellBlockedByReferences = "SellBlockedByReferences",
		UnitNotOwned = "UnitNotOwned",
		InventoryLocked = "InventoryLocked",
	},
}

table.freeze(BuildProtocol.Actions)
table.freeze(BuildProtocol.SyncTypes)
table.freeze(BuildProtocol.ErrorCodes)

return table.freeze(BuildProtocol)

