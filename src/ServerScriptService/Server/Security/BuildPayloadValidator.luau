--!strict
--[=[
	BuildPayloadValidator
	Validación estricta de esquemas, tipos, tamaños, profundidad, rotaciones, CFrames finitos
	y rechazo de suplantación de autoridad o referencias arbitrarias en RemoteFunctions.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildSnapPolicy = require(ReplicatedStorage.Shared.Building.BuildSnapPolicy)
local WheelAutoConfiguration = require(ReplicatedStorage.Shared.Building.WheelAutoConfiguration)

export type ValidatedRequest =
	| {
		Action: "PlacePiece",
		ClientOpId: string,
		ItemId: string,
		LocalCFrame: CFrame,
		Config: { [string]: any }?,
		InventoryInstanceId: string?,
	}
	| {
		Action: "RemovePiece",
		ClientOpId: string,
		PieceInstanceId: string,
	}
	| {
		Action: "TransformPiece",
		ClientOpId: string,
		PieceInstanceId: string,
		LocalCFrame: CFrame,
	}
	| {
		Action: "UpdatePieceConfig",
		ClientOpId: string,
		PieceInstanceId: string,
		Config: { [string]: any }?,
		InventoryInstanceId: string?,
		ResetToAuto: boolean?,
	}
	| {
		Action: "GetBlueprint",
		ClientOpId: string?,
	}
	| {
		Action: "ListBlueprints",
		ClientOpId: string?,
	}
	| {
		Action: "CreateBlueprint",
		ClientOpId: string,
		Name: string?,
	}
	| {
		Action: "SaveBlueprint",
		ClientOpId: string,
		Name: string?,
		SaveAsNew: boolean?,
	}
	| {
		Action: "LoadBlueprint",
		ClientOpId: string,
		BlueprintId: string,
	}
	| {
		Action: "SetActiveBlueprint",
		ClientOpId: string,
		BlueprintId: string,
	}
	| {
		Action: "DuplicateBlueprint",
		ClientOpId: string,
		BlueprintId: string,
		Name: string?,
	}
	| {
		Action: "RenameBlueprint",
		ClientOpId: string,
		BlueprintId: string,
		Name: string,
	}
	| {
		Action: "DeleteBlueprint",
		ClientOpId: string,
		BlueprintId: string,
	}
	| {
		Action: "ListBlueprintSlots",
		ClientOpId: string?,
	}
	| {
		Action: "SaveBlueprintSlot",
		ClientOpId: string,
		SlotIndex: number,
		Name: string?,
		ExpectedRevision: number?,
	}
	| {
		Action: "LoadBlueprintSlot",
		ClientOpId: string,
		SlotIndex: number,
		ConfirmDiscardUnsaved: boolean?,
	}
	| {
		Action: "OverwriteBlueprintSlot",
		ClientOpId: string,
		SlotIndex: number,
		Name: string?,
		ConfirmationStep: number,
		ExpectedSlotRevision: number?,
		ExpectedWorkshopRevision: number?,
	}
	| {
		Action: "RenameBlueprintSlot",
		ClientOpId: string,
		SlotIndex: number,
		Name: string,
	}
	| {
		Action: "DeleteBlueprintSlot",
		ClientOpId: string,
		SlotIndex: number,
		ConfirmationName: string?,
	}
	| {
		Action: "ClearWorkshop",
		ClientOpId: string,
		ExpectedRevision: number?,
		ExpectedEpoch: number?,
	}
	| {
		Action: "RecoverLegacyBlueprint",
		ClientOpId: string,
		OriginalBlueprintId: string,
		TargetSlotIndex: number,
		ConfirmationStep: number?,
	}
	| {
		Action: "SetStandOffset",
		ClientOpId: string,
		HeightOffset: number,
		LateralOffset: number,
	}
	| {
		Action: "ResetStandOffset",
		ClientOpId: string,
	}
	| {
		Action: "ValidateLaunchPrep",
		ClientOpId: string?,
	}
	| {
		Action: "SelectPrimaryAssembly",
		ClientOpId: string,
		GroupId: string,
	}
	| {
		Action: "LaunchVehicle",
		ClientOpId: string,
	}
	| {
		Action: "ReturnToWorkshop",
		ClientOpId: string,
	}
	| {
		Action: "ResetVehicle",
		ClientOpId: string,
	}
	| {
		Action: "ExitVehicleSeat",
		ClientOpId: string,
	}
	| {
		Action: "GetRuntimeState",
		ClientOpId: string?,
	}
	| {
		Action: "GetEngineUnits",
		ClientOpId: string?,
	}
	| {
		Action: "GetBoosterUnits",
		ClientOpId: string?,
	}
	| {
		Action: "GetInventory",
		ClientOpId: string?,
	}
	| {
		Action: "SellInventoryItem",
		ClientOpId: string,
		ItemId: string,
		Quantity: number?,
		ItemInstanceId: string?,
	}
	| {
		Action: "UnlinkInventoryFromBlueprints",
		ClientOpId: string,
		ItemId: string?,
		ItemInstanceId: string?,
		TargetSlotIndices: { number }?,
		Confirmed: boolean?,
	}
	| {
		Action: "SetDrivingInput",
		ClientOpId: string?,
		Throttle: number,
		Brake: number,
		RawLongitudinal: number,
		Steer: number,
		Boost: boolean?,
	}

local BuildPayloadValidator = {}

local ALLOWED_KEYS_BY_ACTION: { [string]: { [string]: boolean } } = {
	PlacePiece = {
		Action = true,
		ClientOpId = true,
		ItemId = true,
		LocalCFrame = true,
		Config = true,
		InventoryInstanceId = true,
		ExpectedBlueprintId = true,
	},
	RemovePiece = {
		Action = true,
		ClientOpId = true,
		PieceInstanceId = true,
		ExpectedBlueprintId = true,
	},
	TransformPiece = {
		Action = true,
		ClientOpId = true,
		PieceInstanceId = true,
		LocalCFrame = true,
		ExpectedBlueprintId = true,
	},
	UpdatePieceConfig = {
		Action = true,
		ClientOpId = true,
		PieceInstanceId = true,
		Config = true,
		InventoryInstanceId = true,
		ResetToAuto = true,
		ExpectedBlueprintId = true,
	},
	GetBlueprint = {
		Action = true,
		ClientOpId = true,
	},
	ListBlueprints = {
		Action = true,
		ClientOpId = true,
	},
	CreateBlueprint = {
		Action = true,
		ClientOpId = true,
		Name = true,
	},
	SaveBlueprint = {
		Action = true,
		ClientOpId = true,
		Name = true,
		SaveAsNew = true,
	},
	LoadBlueprint = {
		Action = true,
		ClientOpId = true,
		BlueprintId = true,
	},
	SetActiveBlueprint = {
		Action = true,
		ClientOpId = true,
		BlueprintId = true,
	},
	DuplicateBlueprint = {
		Action = true,
		ClientOpId = true,
		BlueprintId = true,
		Name = true,
	},
	RenameBlueprint = {
		Action = true,
		ClientOpId = true,
		BlueprintId = true,
		Name = true,
	},
	DeleteBlueprint = {
		Action = true,
		ClientOpId = true,
		BlueprintId = true,
	},
	ListBlueprintSlots = {
		Action = true,
		ClientOpId = true,
	},
	SaveBlueprintSlot = {
		Action = true,
		ClientOpId = true,
		SlotIndex = true,
		Name = true,
		ExpectedRevision = true,
	},
	LoadBlueprintSlot = {
		Action = true,
		ClientOpId = true,
		SlotIndex = true,
		ConfirmDiscardUnsaved = true,
	},
	OverwriteBlueprintSlot = {
		Action = true,
		ClientOpId = true,
		SlotIndex = true,
		Name = true,
		ConfirmationStep = true,
		ExpectedSlotRevision = true,
		ExpectedWorkshopRevision = true,
	},
	RenameBlueprintSlot = {
		Action = true,
		ClientOpId = true,
		SlotIndex = true,
		Name = true,
	},
	DeleteBlueprintSlot = {
		Action = true,
		ClientOpId = true,
		SlotIndex = true,
		ConfirmationName = true,
	},
	ClearWorkshop = {
		Action = true,
		ClientOpId = true,
		ExpectedRevision = true,
		ExpectedEpoch = true,
	},
	RecoverLegacyBlueprint = {
		Action = true,
		ClientOpId = true,
		OriginalBlueprintId = true,
		TargetSlotIndex = true,
		ConfirmationStep = true,
	},
	SetStandOffset = {
		Action = true,
		ClientOpId = true,
		HeightOffset = true,
		LateralOffset = true,
	},
	ResetStandOffset = {
		Action = true,
		ClientOpId = true,
	},
	ValidateLaunchPrep = {
		Action = true,
		ClientOpId = true,
	},
	SelectPrimaryAssembly = {
		Action = true,
		ClientOpId = true,
		GroupId = true,
	},
	LaunchVehicle = {
		Action = true,
		ClientOpId = true,
	},
	ReturnToWorkshop = {
		Action = true,
		ClientOpId = true,
	},
	ResetVehicle = {
		Action = true,
		ClientOpId = true,
	},
	ExitVehicleSeat = {
		Action = true,
		ClientOpId = true,
	},
	GetRuntimeState = {
		Action = true,
		ClientOpId = true,
	},
	GetEngineUnits = {
		Action = true,
		ClientOpId = true,
	},
	GetBoosterUnits = {
		Action = true,
		ClientOpId = true,
	},
	GetInventory = {
		Action = true,
		ClientOpId = true,
	},
	SellInventoryItem = {
		Action = true,
		ClientOpId = true,
		ItemId = true,
		Quantity = true,
		ItemInstanceId = true,
	},
	UnlinkInventoryFromBlueprints = {
		Action = true,
		ClientOpId = true,
		ItemId = true,
		ItemInstanceId = true,
		TargetSlotIndices = true,
		Confirmed = true,
	},
	SetDrivingInput = {
		Action = true,
		ClientOpId = true,
		Throttle = true,
		Brake = true,
		RawLongitudinal = true,
		Steer = true,
		Boost = true,
	},
}

local FORBIDDEN_DIRECT_STATS_KEYS: { [string]: boolean } = {
	Stats = true,
	EffectiveStats = true,
	Torque = true,
	PeakTorque = true,
	Power = true,
	PowerRating = true,
	SpeedRegular = true,
	MaxRPM = true,
	IdleRPM = true,
	OptimumRPM = true,
	LimiterRPM = true,
	LimiterRecoveryRPM = true,
	Responsiveness = true,
	Weight = true,
	MaxDurability = true,
	CurrentDurability = true,
	DrivingBonus = true,
	DisconnectRate = true,
	IntegratedFuel = true,
	MaxFuelConsumption = true,
	EfficiencyFactor = true,
	Price = true,
	RarityId = true,
	EngineRarityId = true,
	VariantId = true,
	EngineSizeId = true,
	EngineFamilyId = true,
	Thrust = true,
	AppliedThrust = true,
	EffectiveThrustMax = true,
	TotalAppliedThrust = true,
	SpeedBoostMultiplier = true,
	BoostConsumption = true,
	AvailableNitro = true,
	TotalNitroCapacity = true,
	Nitro = true,
	RocketFuel = true,
	WorldThrustDirection = true,
	BoosterRarityId = true,
	BoosterSizeId = true,
	BoosterFamilyId = true,
}

local SPOOF_AUTHORITY_KEYS: { [string]: boolean } = {
	PlotId = true,
	OwnerUserId = true,
	UserId = true,
	TargetUserId = true,
	TargetPlotId = true,
}

local RESERVED_CONFIG_KEYS: { [string]: boolean } = {
	__index = true,
	__newindex = true,
	__metatable = true,
	OwnerUserId = true,
	PlotId = true,
	ItemId = true,
	InstanceId = true,
	PieceInstanceId = true,
	InventoryInstanceId = true,
	Revision = true,
	Stats = true,
	MaxDurability = true,
	CurrentDurability = true,
	Behavior = true,
	Behaviors = true,
	Script = true,
	ModuleScript = true,
	Permissions = true,
}

local function isFiniteNumber(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isValidSlotIndex(val: any): boolean
	return isFiniteNumber(val) and val % 1 == 0 and val >= 1 and val <= GameConfig.Blueprints.MaxSlots
end

local function isSafeString(val: any, maxLen: number): boolean
	if type(val) ~= "string" then
		return false
	end
	local len = #val
	if len < 1 or len > maxLen then
		return false
	end
	if string.find(val, "[%z%c]") ~= nil then
		return false
	end
	return true
end

local function isSafeIdentifier(val: any, maxLen: number): boolean
	if not isSafeString(val, maxLen) then
		return false
	end
	return string.match(val :: string, "^[%w_%-%.:]+$") ~= nil
end

function BuildPayloadValidator.IsFiniteVector3(v: Vector3): boolean
	return isFiniteNumber(v.X) and isFiniteNumber(v.Y) and isFiniteNumber(v.Z)
end

function BuildPayloadValidator.IsFiniteCFrame(cf: any, maxCoordMag: number?): boolean
	if typeof(cf) ~= "CFrame" then
		return false
	end
	local cframe = cf :: CFrame
	local limit = maxCoordMag or GameConfig.Building.MaxCoordinateMagnitude
	local pos = cframe.Position
	if not BuildPayloadValidator.IsFiniteVector3(pos) then
		return false
	end
	if math.abs(pos.X) > limit or math.abs(pos.Y) > limit or math.abs(pos.Z) > limit then
		return false
	end
	return BuildPayloadValidator.IsFiniteVector3(cframe.RightVector)
		and BuildPayloadValidator.IsFiniteVector3(cframe.UpVector)
		and BuildPayloadValidator.IsFiniteVector3(cframe.LookVector)
end

function BuildPayloadValidator.IsValid90Rotation(cf: CFrame): boolean
	local ortho = BuildRotation.Orthonormalize(cf.Rotation)
	local rightDiff = (cf.RightVector - ortho.RightVector).Magnitude
	local upDiff = (cf.UpVector - ortho.UpVector).Magnitude
	local lookDiff = (cf.LookVector - ortho.LookVector).Magnitude
	if rightDiff > 0.02 or upDiff > 0.02 or lookDiff > 0.02 then
		return false
	end
	if math.abs(ortho.RightVector.Magnitude - 1) > 0.01 or math.abs(ortho.UpVector.Magnitude - 1) > 0.01 then
		return false
	end
	if math.abs(ortho.RightVector:Dot(ortho.UpVector)) > 0.01 then
		return false
	end
	return true
end

local function sanitizeConfigRecursive(
	node: any,
	depth: number,
	visited: { [any]: boolean },
	counter: { Count: number }
): (boolean, any, string?)
	if type(node) ~= "table" or getmetatable(node) ~= nil then
		return false, nil, "Config debe ser una tabla plana sin metatable"
	end
	if visited[node] then
		return false, nil, "Config contiene referencias circulares"
	end
	visited[node] = true

	local maxEntries = GameConfig.Building.MaxConfigEntries
	local maxDepth = GameConfig.Building.MaxConfigDepth
	local maxStrLen = GameConfig.Building.MaxStringLength

	local out: { [any]: any } = {}
	for k, v in pairs(node) do
		counter.Count += 1
		if counter.Count > maxEntries then
			return false, nil, "Config excede el tamaño máximo permitido"
		end

		local keyType = type(k)
		if keyType == "string" then
			if not isSafeString(k, 32) or RESERVED_CONFIG_KEYS[k] or FORBIDDEN_DIRECT_STATS_KEYS[k] then
				return false, nil, `Clave Config no permitida: '{tostring(k)}'`
			end
		elseif keyType == "number" then
			if not isFiniteNumber(k) or k < 1 or k > maxEntries or math.floor(k) ~= k then
				return false, nil, "Índice numérico inválido en Config"
			end
		else
			return false, nil, "Tipo de clave inválido en Config"
		end

		local valType = type(v)
		if valType == "boolean" then
			out[k] = v
		elseif valType == "number" then
			if not isFiniteNumber(v) or math.abs(v) > 1e9 then
				return false, nil, "Número no finito o fuera de rango en Config"
			end
			out[k] = v
		elseif valType == "string" then
			if not isSafeString(v, maxStrLen) then
				return false, nil, "Cadena inválida o demasiado larga en Config"
			end
			out[k] = v
		elseif valType == "table" then
			if depth >= maxDepth then
				return false, nil, "Config excede la profundidad máxima permitida"
			end
			local okSub, sanitizedSub, subErr = sanitizeConfigRecursive(v, depth + 1, visited, counter)
			if not okSub then
				return false, nil, subErr
			end
			out[k] = sanitizedSub
		else
			-- Rechaza Instance, function, thread y cualquier userdata no autorizado
			return false, nil, `Tipo de valor no permitido en Config ({typeof(v)})`
		end
	end

	visited[node] = nil
	return true, out, nil
end

function BuildPayloadValidator.ValidateAndSanitizeConfig(rawConfig: any): (boolean, { [string]: any }?, string?)
	if rawConfig == nil then
		return true, nil, nil
	end
	if type(rawConfig) ~= "table" or getmetatable(rawConfig) ~= nil then
		return false, nil, "Config inválido"
	end

	local visited: { [any]: boolean } = {}
	local counter = { Count = 0 }
	local ok, sanitized, err = sanitizeConfigRecursive(rawConfig, 1, visited, counter)
	if not ok then
		return false, nil, err
	end
	return true, sanitized :: { [string]: any }, nil
end

function BuildPayloadValidator.ValidateWheelConfigTable(rawConfig: any): (boolean, { [string]: any }?, string?, string?)
	if rawConfig == nil then
		return true, nil, nil, nil
	end
	local okSan, sanitized, sanErr = BuildPayloadValidator.ValidateAndSanitizeConfig(rawConfig)
	if not okSan or not sanitized then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, sanErr or "Config inválido"
	end

	for k in pairs(sanitized) do
		if k ~= "Wheel" then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Clave Config no soportada en rueda: '{k}'`
		end
	end

	if sanitized.Wheel == nil then
		return true, nil, nil, nil
	end

	local okWheel, cleanedWheel, wheelErrCode, wheelErrMsg = WheelAutoConfiguration.ValidateManualOverrides(sanitized.Wheel)
	if not okWheel then
		return false,
			nil,
			wheelErrCode or BuildProtocol.ErrorCodes.InvalidPayload,
			wheelErrMsg or "Configuración de rueda inválida"
	end
	if not cleanedWheel then
		return true, nil, nil, nil
	end
	return true, { Wheel = cleanedWheel }, nil, nil
end

function BuildPayloadValidator.ValidateEngineConfigTable(rawConfig: any): (boolean, { [string]: any }?, string?, string?)
	if rawConfig == nil then
		return true, nil, nil, nil
	end
	if type(rawConfig) == "table" then
		for k, v in pairs(rawConfig) do
			if type(k) == "string" and FORBIDDEN_DIRECT_STATS_KEYS[k] then
				return false,
					nil,
					BuildProtocol.ErrorCodes.ForbiddenDirectStatsPayload,
					`El cliente no puede enviar estadísticas o rarezas directas ('{k}')`
			end
			if k == "Engine" and type(v) == "table" then
				for subK in pairs(v) do
					if type(subK) == "string" and FORBIDDEN_DIRECT_STATS_KEYS[subK] then
						return false,
							nil,
							BuildProtocol.ErrorCodes.ForbiddenDirectStatsPayload,
							`El cliente no puede enviar estadísticas o rarezas directas en Config.Engine ('{subK}')`
					end
				end
			end
		end
	end

	local okSan, sanitized, sanErr = BuildPayloadValidator.ValidateAndSanitizeConfig(rawConfig)
	if not okSan or not sanitized then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, sanErr or "Config inválido"
	end

	for k in pairs(sanitized) do
		if k ~= "Engine" then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Clave Config no soportada en motor: '{k}'`
		end
	end

	local eng = sanitized.Engine
	if eng == nil then
		return true, nil, nil, nil
	end
	if type(eng) ~= "table" then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Config.Engine debe ser una tabla"
	end

	local cleaned: { [string]: any } = {}
	local hasAny = false

	for k, v in pairs(eng) do
		if k == "PowerLimitRatio" then
			if type(v) ~= "number" or not isFiniteNumber(v) then
				return false, nil, BuildProtocol.ErrorCodes.InvalidConfigRange, "PowerLimitRatio debe ser un número finito"
			end
			if v < GameConfig.Powertrain.MinPowerLimitRatio or v > GameConfig.Powertrain.MaxPowerLimitRatio then
				return false,
					nil,
					BuildProtocol.ErrorCodes.InvalidConfigRange,
					`PowerLimitRatio fuera de rango [{GameConfig.Powertrain.MinPowerLimitRatio}..{GameConfig.Powertrain.MaxPowerLimitRatio}]`
			end
			cleaned.PowerLimitRatio = math.round(v * 100) / 100
			hasAny = true
		elseif k == "ThrottleResponseMode" then
			if v ~= "Smooth" and v ~= "Balanced" and v ~= "Sport" then
				return false,
					nil,
					BuildProtocol.ErrorCodes.InvalidConfigRange,
					"ThrottleResponseMode debe ser 'Smooth', 'Balanced' o 'Sport'"
			end
			cleaned.ThrottleResponseMode = v
			hasAny = true
		elseif k == "Enabled" then
			if type(v) ~= "boolean" then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Enabled debe ser booleano"
			end
			cleaned.Enabled = v
			hasAny = true
		else
			return false,
				nil,
				BuildProtocol.ErrorCodes.InvalidPayload,
				`Propiedad no permitida en Config.Engine: '{tostring(k)}'`
		end
	end

	if not hasAny then
		return true, nil, nil, nil
	end
	return true, { Engine = cleaned }, nil, nil
end

function BuildPayloadValidator.ValidateBoosterConfigTable(rawConfig: any): (boolean, { [string]: any }?, string?, string?)
	if rawConfig == nil then
		return true, nil, nil, nil
	end
	if type(rawConfig) == "table" then
		for k, v in pairs(rawConfig) do
			if type(k) == "string" and FORBIDDEN_DIRECT_STATS_KEYS[k] then
				return false,
					nil,
					BuildProtocol.ErrorCodes.ForbiddenDirectStatsPayload,
					`El cliente no puede enviar estadísticas o rarezas directas ('{k}')`
			end
			if k == "Booster" and type(v) == "table" then
				for subK in pairs(v) do
					if type(subK) == "string" and FORBIDDEN_DIRECT_STATS_KEYS[subK] then
						return false,
							nil,
							BuildProtocol.ErrorCodes.ForbiddenDirectStatsPayload,
							`El cliente no puede enviar estadísticas o rarezas directas en Config.Booster ('{subK}')`
					end
				end
			end
		end
	end

	local okSan, sanitized, sanErr = BuildPayloadValidator.ValidateAndSanitizeConfig(rawConfig)
	if not okSan or not sanitized then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, sanErr or "Config inválido"
	end

	for k in pairs(sanitized) do
		if k ~= "Booster" then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Clave Config no soportada en propulsor: '{k}'`
		end
	end

	local bst = sanitized.Booster
	if bst == nil then
		return true, nil, nil, nil
	end
	if type(bst) ~= "table" then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Config.Booster debe ser una tabla"
	end

	local cleaned: { [string]: any } = {}
	local hasAny = false

	for k, v in pairs(bst) do
		if k == "ThrustLimitRatio" then
			if type(v) ~= "number" or not isFiniteNumber(v) then
				return false, nil, BuildProtocol.ErrorCodes.InvalidConfigRange, "ThrustLimitRatio debe ser un número finito"
			end
			if v < GameConfig.Boosters.MinThrustLimitRatio or v > GameConfig.Boosters.MaxThrustLimitRatio then
				return false,
					nil,
					BuildProtocol.ErrorCodes.InvalidConfigRange,
					`ThrustLimitRatio fuera de rango [{GameConfig.Boosters.MinThrustLimitRatio}..{GameConfig.Boosters.MaxThrustLimitRatio}]`
			end
			cleaned.ThrustLimitRatio = math.round(v * 100) / 100
			hasAny = true
		elseif k == "ThrottleCurveMode" then
			if v ~= "Instant" and v ~= "Smooth" and v ~= "Sustained" then
				return false,
					nil,
					BuildProtocol.ErrorCodes.InvalidConfigRange,
					"ThrottleCurveMode debe ser 'Instant', 'Smooth' o 'Sustained'"
			end
			cleaned.ThrottleCurveMode = v
			hasAny = true
		elseif k == "Enabled" then
			if type(v) ~= "boolean" then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Enabled debe ser booleano"
			end
			cleaned.Enabled = v
			hasAny = true
		else
			return false,
				nil,
				BuildProtocol.ErrorCodes.InvalidPayload,
				`Propiedad no permitida en Config.Booster: '{tostring(k)}'`
		end
	end

	if not hasAny then
		return true, nil, nil, nil
	end
	return true, { Booster = cleaned }, nil, nil
end

function BuildPayloadValidator.ValidateFuelTankConfigTable(rawConfig: any): (boolean, { [string]: any }?, string?, string?)
	if rawConfig == nil then
		return true, nil, nil, nil
	end
	local okSan, sanitized, sanErr = BuildPayloadValidator.ValidateAndSanitizeConfig(rawConfig)
	if not okSan or not sanitized then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, sanErr or "Config inválido"
	end

	local out: { [string]: any } = {}
	local cleaned: { [string]: any } = {}
	local hasAny = false

	for k, v in pairs(sanitized) do
		if k == "FuelTank" then
			if type(v) ~= "table" then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Config.FuelTank debe ser una tabla"
			end
			for subK, subV in pairs(v) do
				if subK == "SelectedFuelType" then
					if subV ~= "Regular" and subV ~= "Diesel" and subV ~= "Competicion" then
						return false,
							nil,
							BuildProtocol.ErrorCodes.InvalidConfigRange,
							"SelectedFuelType debe ser 'Regular', 'Diesel' o 'Competicion'"
					end
					cleaned.SelectedFuelType = subV
					hasAny = true
				else
					return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Clave no permitida en Config.FuelTank: '{tostring(subK)}'`
				end
			end
		elseif k == "FuelType" then
			if v ~= "Regular" and v ~= "Diesel" and v ~= "Competicion" then
				return false,
					nil,
					BuildProtocol.ErrorCodes.InvalidConfigRange,
					"FuelType debe ser 'Regular', 'Diesel' o 'Competicion'"
			end
			out.FuelType = v
			cleaned.SelectedFuelType = cleaned.SelectedFuelType or v
			hasAny = true
		else
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Clave Config no soportada en tanque: '{k}'`
		end
	end

	if not hasAny then
		return true, nil, nil, nil
	end
	out.FuelTank = cleaned
	return true, out, nil, nil
end

function BuildPayloadValidator.ValidateDrivingInput(rawPayload: any): (boolean, {
	Throttle: number,
	Brake: number,
	RawLongitudinal: number,
	Steer: number,
	Boost: boolean,
}?, string?, string?)
	if type(rawPayload) ~= "table" or getmetatable(rawPayload) ~= nil then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Payload de conducción inválido"
	end

	local rawThrottle = rawget(rawPayload, "Throttle")
	local rawBrake = rawget(rawPayload, "Brake")
	local rawLong = rawget(rawPayload, "RawLongitudinal")
	local rawSteer = rawget(rawPayload, "Steer")
	local rawBoost = rawget(rawPayload, "Boost")

	if rawThrottle ~= nil and not isFiniteNumber(rawThrottle) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Throttle debe ser un número finito"
	end
	if rawBrake ~= nil and not isFiniteNumber(rawBrake) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Brake debe ser un número finito"
	end
	if rawLong ~= nil and not isFiniteNumber(rawLong) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "RawLongitudinal debe ser un número finito"
	end
	if rawSteer ~= nil and not isFiniteNumber(rawSteer) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Steer debe ser un número finito"
	end
	if rawBoost ~= nil and type(rawBoost) ~= "boolean" then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Boost debe ser booleano"
	end

	local throttle = math.clamp(if type(rawThrottle) == "number" then rawThrottle else 0, 0, 1)
	local brake = math.clamp(if type(rawBrake) == "number" then rawBrake else 0, 0, 1)
	local longVal = if type(rawLong) == "number"
		then math.clamp(rawLong, -1, 1)
		else math.clamp(throttle - brake, -1, 1)
	if rawThrottle == nil and rawBrake == nil and type(rawLong) == "number" then
		if longVal > 0 then
			throttle = longVal
			brake = 0
		elseif longVal < 0 then
			throttle = 0
			brake = -longVal
		end
	end
	local steer = math.clamp(if type(rawSteer) == "number" then rawSteer else 0, -1, 1)
	local boost = rawBoost == true

	return true,
		{
			Throttle = throttle,
			Brake = brake,
			RawLongitudinal = longVal,
			Steer = steer,
			Boost = boost,
		},
		nil,
		nil
end

function BuildPayloadValidator.ValidateRequest(
	rawRequest: any,
	callerUserId: number,
	assignedPlotId: string?
): (boolean, ValidatedRequest?, string?, string?)
	if type(rawRequest) ~= "table" or getmetatable(rawRequest) ~= nil then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Solicitud malformada"
	end

	local action = rawget(rawRequest, "Action")
	if not isSafeString(action, 32) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Action inválida"
	end

	local allowedKeys = ALLOWED_KEYS_BY_ACTION[action]
	if not allowedKeys then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Acción desconocida"
	end

	local keyCount = 0
	for k, v in pairs(rawRequest) do
		keyCount += 1
		if keyCount > GameConfig.Building.MaxPayloadKeys then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Payload excede claves permitidas"
		end

		if type(k) ~= "string" or #k > 32 then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Clave de payload inválida"
		end

		if SPOOF_AUTHORITY_KEYS[k] then
			if (k == "PlotId" or k == "TargetPlotId") and assignedPlotId ~= nil and v ~= assignedPlotId then
				return false, nil, BuildProtocol.ErrorCodes.NotPlotOwner, "Intento de operación en estación ajena"
			end
			if (k == "OwnerUserId" or k == "UserId" or k == "TargetUserId") and v ~= callerUserId then
				return false, nil, BuildProtocol.ErrorCodes.NotPlotOwner, "Intento de suplantar propietario"
			end
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Campo de autoridad no aceptado del cliente: {k}`
		end

		if not allowedKeys[k] then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Campo no permitido: {k}`
		end
	end

	local rawClientOpId = rawget(rawRequest, "ClientOpId")
	if
		action == BuildProtocol.Actions.GetBlueprint
		or action == BuildProtocol.Actions.ListBlueprints
		or action == BuildProtocol.Actions.ListBlueprintSlots
		or action == BuildProtocol.Actions.ValidateLaunchPrep
		or action == BuildProtocol.Actions.GetRuntimeState
		or action == BuildProtocol.Actions.GetEngineUnits
		or action == BuildProtocol.Actions.GetBoosterUnits
		or action == BuildProtocol.Actions.GetInventory
	then
		if rawClientOpId ~= nil and not isSafeString(rawClientOpId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ClientOpId inválido"
		end
		return true,
			{
				Action = action :: any,
				ClientOpId = rawClientOpId,
			} :: any,
			nil,
			nil
	elseif action == BuildProtocol.Actions.SetDrivingInput then
		if rawClientOpId ~= nil and not isSafeString(rawClientOpId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ClientOpId inválido"
		end
		local okDrive, driveData, dCode, dMsg = BuildPayloadValidator.ValidateDrivingInput(rawRequest)
		if not okDrive or not driveData then
			return false, nil, dCode or BuildProtocol.ErrorCodes.InvalidPayload, dMsg or "Input de conducción inválido"
		end
		return true,
			{
				Action = "SetDrivingInput",
				ClientOpId = rawClientOpId,
				Throttle = driveData.Throttle,
				Brake = driveData.Brake,
				RawLongitudinal = driveData.RawLongitudinal,
				Steer = driveData.Steer,
				Boost = driveData.Boost,
			},
			nil,
			nil
	end

	-- Acciones mutadoras exigen ClientOpId válido y seguro
	if not isSafeString(rawClientOpId, GameConfig.Building.MaxStringLength) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ClientOpId requerido o inválido"
	end

	if action == BuildProtocol.Actions.PlacePiece then
		local itemId = rawget(rawRequest, "ItemId")
		if type(itemId) ~= "string" or not isSafeIdentifier(itemId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ItemId con formato o tamaño inválido"
		end

		local rawCFrame = rawget(rawRequest, "LocalCFrame")
		if typeof(rawCFrame) ~= "CFrame" or not BuildPayloadValidator.IsFiniteCFrame(rawCFrame) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidCFrame, "CFrame inválido o no finito"
		end

		if not BuildRotation.IsOrthonormalRotation(rawCFrame) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidRotation, "Matriz de rotación no ortonormal o degenerada"
		end

		if ItemRegistry.Has(itemId) then
			local rotOk, rotReason = BuildSnapPolicy.ValidateRotationForItem(itemId, rawCFrame.Rotation)
			if not rotOk then
				return false, nil, BuildProtocol.ErrorCodes.InvalidRotation, rotReason or "Rotación no permitida para este componente"
			end
		end

		local rawInventoryInstanceId = rawget(rawRequest, "InventoryInstanceId")
		local validatedInvId: string? = nil
		if rawInventoryInstanceId ~= nil and rawInventoryInstanceId ~= "" then
			if not isSafeIdentifier(rawInventoryInstanceId, GameConfig.Building.MaxStringLength) then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "InventoryInstanceId con formato inválido"
			end
			validatedInvId = rawInventoryInstanceId
		end

		local rawCfgTable = rawget(rawRequest, "Config")
		local sanitizedConfig: { [string]: any }? = nil

		if ItemRegistry.Has(itemId) then
			local itemDef = ItemRegistry.Get(itemId)
			if itemDef.Category == "Wheels" then
				local okW, wheelCfg, wCode, wMsg = BuildPayloadValidator.ValidateWheelConfigTable(rawCfgTable)
				if not okW then
					return false, nil, wCode or BuildProtocol.ErrorCodes.InvalidPayload, wMsg or "Config de rueda inválida"
				end
				sanitizedConfig = wheelCfg
			elseif itemDef.Category == "Engines" then
				local okE, engCfg, eCode, eMsg = BuildPayloadValidator.ValidateEngineConfigTable(rawCfgTable)
				if not okE then
					return false, nil, eCode or BuildProtocol.ErrorCodes.InvalidPayload, eMsg or "Config de motor inválida"
				end
				sanitizedConfig = engCfg
			elseif itemDef.Category == "FuelTanks" then
				local okF, fuelCfg, fCode, fMsg = BuildPayloadValidator.ValidateFuelTankConfigTable(rawCfgTable)
				if not okF then
					return false, nil, fCode or BuildProtocol.ErrorCodes.InvalidPayload, fMsg or "Config de tanque inválida"
				end
				sanitizedConfig = fuelCfg
			elseif itemDef.Category == "Boosters" then
				local okB, bstCfg, bCode, bMsg = BuildPayloadValidator.ValidateBoosterConfigTable(rawCfgTable)
				if not okB then
					return false, nil, bCode or BuildProtocol.ErrorCodes.InvalidPayload, bMsg or "Config de propulsor inválida"
				end
				sanitizedConfig = bstCfg
			else
				local okCfg, cfg, cfgErr = BuildPayloadValidator.ValidateAndSanitizeConfig(rawCfgTable)
				if not okCfg then
					return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, cfgErr or "Config inválido"
				end
				if cfg and (cfg.Wheel ~= nil or cfg.Engine ~= nil or cfg.FuelTank ~= nil or cfg.Booster ~= nil) then
					return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Config específica no aplica a este tipo de pieza"
				end
				sanitizedConfig = cfg
			end
		else
			local okCfg, cfg, cfgErr = BuildPayloadValidator.ValidateAndSanitizeConfig(rawCfgTable)
			if not okCfg then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, cfgErr or "Config inválido"
			end
			sanitizedConfig = cfg
		end

		return true,
			{
				Action = "PlacePiece",
				ClientOpId = rawClientOpId,
				ItemId = itemId,
				LocalCFrame = rawCFrame,
				Config = sanitizedConfig,
				InventoryInstanceId = validatedInvId,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.RemovePiece then
		local pieceInstanceId = rawget(rawRequest, "PieceInstanceId")
		if type(pieceInstanceId) ~= "string" or not isSafeIdentifier(pieceInstanceId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "PieceInstanceId con formato o tamaño inválido"
		end

		return true,
			{
				Action = "RemovePiece",
				ClientOpId = rawClientOpId,
				PieceInstanceId = pieceInstanceId,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.TransformPiece then
		local pieceInstanceId = rawget(rawRequest, "PieceInstanceId")
		if type(pieceInstanceId) ~= "string" or not isSafeIdentifier(pieceInstanceId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "PieceInstanceId con formato o tamaño inválido"
		end

		local rawCFrame = rawget(rawRequest, "LocalCFrame")
		if typeof(rawCFrame) ~= "CFrame" or not BuildPayloadValidator.IsFiniteCFrame(rawCFrame) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidCFrame, "CFrame inválido o no finito"
		end

		if not BuildRotation.IsOrthonormalRotation(rawCFrame) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidRotation, "Matriz de rotación no ortonormal o degenerada"
		end

		return true,
			{
				Action = "TransformPiece",
				ClientOpId = rawClientOpId,
				PieceInstanceId = pieceInstanceId,
				LocalCFrame = rawCFrame,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.UpdatePieceConfig then
		local pieceInstanceId = rawget(rawRequest, "PieceInstanceId")
		if type(pieceInstanceId) ~= "string" or not isSafeIdentifier(pieceInstanceId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "PieceInstanceId con formato o tamaño inválido"
		end

		local resetToAuto = rawget(rawRequest, "ResetToAuto")
		if resetToAuto ~= nil and type(resetToAuto) ~= "boolean" then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ResetToAuto debe ser booleano"
		end

		local rawInventoryInstanceId = rawget(rawRequest, "InventoryInstanceId")
		local validatedInvId: string? = nil
		if rawInventoryInstanceId ~= nil then
			if rawInventoryInstanceId == "" then
				validatedInvId = ""
			elseif not isSafeIdentifier(rawInventoryInstanceId, GameConfig.Building.MaxStringLength) then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "InventoryInstanceId con formato inválido"
			else
				validatedInvId = rawInventoryInstanceId
			end
		end

		local rawCfg = rawget(rawRequest, "Config")
		local sanitizedCfg: { [string]: any }? = nil
		if resetToAuto ~= true then
			if type(rawCfg) == "table" then
				for k, v in pairs(rawCfg) do
					if type(k) == "string" and FORBIDDEN_DIRECT_STATS_KEYS[k] then
						return false,
							nil,
							BuildProtocol.ErrorCodes.ForbiddenDirectStatsPayload,
							`El cliente no puede enviar estadísticas o rarezas directas ('{k}')`
					end
					if (k == "Engine" or k == "Booster") and type(v) == "table" then
						for subK in pairs(v) do
							if type(subK) == "string" and FORBIDDEN_DIRECT_STATS_KEYS[subK] then
								return false,
									nil,
									BuildProtocol.ErrorCodes.ForbiddenDirectStatsPayload,
									`El cliente no puede enviar estadísticas o rarezas directas en Config.{k} ('{subK}')`
							end
						end
					end
				end
			end

			local okCfg, cfg, cfgErr = BuildPayloadValidator.ValidateAndSanitizeConfig(rawCfg)
			if not okCfg then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, cfgErr or "Config inválido"
			end
			sanitizedCfg = cfg
		elseif rawCfg ~= nil then
			-- Si ResetToAuto=true, ignorar o rechazar tablas malformadas
			if type(rawCfg) ~= "table" or getmetatable(rawCfg) ~= nil then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Config inválido con ResetToAuto"
			end
		end

		return true,
			{
				Action = "UpdatePieceConfig",
				ClientOpId = rawClientOpId,
				PieceInstanceId = pieceInstanceId,
				Config = sanitizedCfg,
				InventoryInstanceId = validatedInvId,
				ResetToAuto = resetToAuto,
			},
			nil,
			nil
	elseif
		action == BuildProtocol.Actions.ListBlueprints
		or action == BuildProtocol.Actions.ListBlueprintSlots
		or action == BuildProtocol.Actions.ValidateLaunchPrep
	then
		return true,
			{
				Action = action,
				ClientOpId = rawClientOpId,
			} :: any,
			nil,
			nil
	elseif action == BuildProtocol.Actions.CreateBlueprint then
		local rawName = rawget(rawRequest, "Name")
		if rawName ~= nil and not isSafeString(rawName, GameConfig.Blueprints.MaxNameLength * 2) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre de blueprint inválido"
		end
		return true,
			{
				Action = "CreateBlueprint",
				ClientOpId = rawClientOpId,
				Name = rawName,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.SaveBlueprint then
		local rawName = rawget(rawRequest, "Name")
		if rawName ~= nil and not isSafeString(rawName, GameConfig.Blueprints.MaxNameLength * 2) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre de blueprint inválido"
		end
		local saveAsNew = rawget(rawRequest, "SaveAsNew")
		if saveAsNew ~= nil and type(saveAsNew) ~= "boolean" then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "SaveAsNew debe ser booleano"
		end
		return true,
			{
				Action = "SaveBlueprint",
				ClientOpId = rawClientOpId,
				Name = rawName,
				SaveAsNew = saveAsNew,
			},
			nil,
			nil
	elseif
		action == BuildProtocol.Actions.LoadBlueprint
		or action == BuildProtocol.Actions.SetActiveBlueprint
		or action == BuildProtocol.Actions.DeleteBlueprint
	then
		local blueprintId = rawget(rawRequest, "BlueprintId")
		if not isSafeIdentifier(blueprintId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "BlueprintId inválido"
		end
		return true,
			{
				Action = action,
				ClientOpId = rawClientOpId,
				BlueprintId = blueprintId,
			} :: any,
			nil,
			nil
	elseif action == BuildProtocol.Actions.DuplicateBlueprint then
		local blueprintId = rawget(rawRequest, "BlueprintId")
		if not isSafeIdentifier(blueprintId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "BlueprintId inválido"
		end
		local rawName = rawget(rawRequest, "Name")
		if rawName ~= nil and not isSafeString(rawName, GameConfig.Blueprints.MaxNameLength * 2) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre inválido"
		end
		return true,
			{
				Action = "DuplicateBlueprint",
				ClientOpId = rawClientOpId,
				BlueprintId = blueprintId,
				Name = rawName,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.RenameBlueprint then
		local blueprintId = rawget(rawRequest, "BlueprintId")
		if not isSafeIdentifier(blueprintId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "BlueprintId inválido"
		end
		local rawName = rawget(rawRequest, "Name")
		if not isSafeString(rawName, GameConfig.Blueprints.MaxNameLength * 2) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre inválido"
		end
		return true,
			{
				Action = "RenameBlueprint",
				ClientOpId = rawClientOpId,
				BlueprintId = blueprintId,
				Name = rawName,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.SaveBlueprintSlot then
		local slotIndex = rawget(rawRequest, "SlotIndex")
		if not isValidSlotIndex(slotIndex) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "SlotIndex inválido (debe ser 1, 2 o 3)"
		end
		local rawName = rawget(rawRequest, "Name")
		if rawName ~= nil and not isSafeString(rawName, GameConfig.Blueprints.MaxNameLength * 2) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre de blueprint inválido"
		end
		local expectedRevision = rawget(rawRequest, "ExpectedRevision")
		if expectedRevision ~= nil and (not isFiniteNumber(expectedRevision) or expectedRevision < 0 or expectedRevision % 1 ~= 0) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ExpectedRevision inválido"
		end
		return true,
			{
				Action = "SaveBlueprintSlot",
				ClientOpId = rawClientOpId,
				SlotIndex = slotIndex,
				Name = rawName,
				ExpectedRevision = expectedRevision,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.LoadBlueprintSlot then
		local slotIndex = rawget(rawRequest, "SlotIndex")
		if not isValidSlotIndex(slotIndex) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "SlotIndex inválido (debe ser 1, 2 o 3)"
		end
		local confirmDiscard = rawget(rawRequest, "ConfirmDiscardUnsaved")
		if confirmDiscard ~= nil and type(confirmDiscard) ~= "boolean" then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ConfirmDiscardUnsaved debe ser booleano"
		end
		return true,
			{
				Action = "LoadBlueprintSlot",
				ClientOpId = rawClientOpId,
				SlotIndex = slotIndex,
				ConfirmDiscardUnsaved = confirmDiscard,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.OverwriteBlueprintSlot then
		local slotIndex = rawget(rawRequest, "SlotIndex")
		if not isValidSlotIndex(slotIndex) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "SlotIndex inválido (debe ser 1, 2 o 3)"
		end
		local confirmationStep = rawget(rawRequest, "ConfirmationStep")
		if confirmationStep ~= 2 then
			return false,
				nil,
				BuildProtocol.ErrorCodes.ConfirmationRequired,
				"Se requiere doble confirmación explícita (ConfirmationStep = 2) para sobrescribir el slot"
		end
		local rawName = rawget(rawRequest, "Name")
		if rawName ~= nil and not isSafeString(rawName, GameConfig.Blueprints.MaxNameLength * 2) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre de blueprint inválido"
		end
		local expectedSlotRev = rawget(rawRequest, "ExpectedSlotRevision")
		if expectedSlotRev ~= nil and (not isFiniteNumber(expectedSlotRev) or expectedSlotRev < 0 or expectedSlotRev % 1 ~= 0) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ExpectedSlotRevision inválido"
		end
		local expectedWorkshopRev = rawget(rawRequest, "ExpectedWorkshopRevision")
		if expectedWorkshopRev ~= nil and (not isFiniteNumber(expectedWorkshopRev) or expectedWorkshopRev < 0 or expectedWorkshopRev % 1 ~= 0) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ExpectedWorkshopRevision inválido"
		end
		return true,
			{
				Action = "OverwriteBlueprintSlot",
				ClientOpId = rawClientOpId,
				SlotIndex = slotIndex,
				Name = rawName,
				ConfirmationStep = confirmationStep,
				ExpectedSlotRevision = expectedSlotRev,
				ExpectedWorkshopRevision = expectedWorkshopRev,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.RenameBlueprintSlot then
		local slotIndex = rawget(rawRequest, "SlotIndex")
		if not isValidSlotIndex(slotIndex) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "SlotIndex inválido (debe ser 1, 2 o 3)"
		end
		local rawName = rawget(rawRequest, "Name")
		if not isSafeString(rawName, GameConfig.Blueprints.MaxNameLength * 2) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre inválido"
		end
		return true,
			{
				Action = "RenameBlueprintSlot",
				ClientOpId = rawClientOpId,
				SlotIndex = slotIndex,
				Name = rawName,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.DeleteBlueprintSlot then
		local slotIndex = rawget(rawRequest, "SlotIndex")
		if not isValidSlotIndex(slotIndex) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "SlotIndex inválido (debe ser 1, 2 o 3)"
		end
		local confirmationName = rawget(rawRequest, "ConfirmationName")
		if confirmationName ~= nil and not isSafeString(confirmationName, GameConfig.Blueprints.MaxNameLength * 2) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidBlueprintName, "ConfirmationName inválido"
		end
		return true,
			{
				Action = "DeleteBlueprintSlot",
				ClientOpId = rawClientOpId,
				SlotIndex = slotIndex,
				ConfirmationName = confirmationName,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.ClearWorkshop then
		local expectedRev = rawget(rawRequest, "ExpectedRevision")
		if expectedRev ~= nil and (not isFiniteNumber(expectedRev) or expectedRev < 0 or expectedRev % 1 ~= 0) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ExpectedRevision inválido"
		end
		local expectedEpoch = rawget(rawRequest, "ExpectedEpoch")
		if expectedEpoch ~= nil and (not isFiniteNumber(expectedEpoch) or expectedEpoch < 0 or expectedEpoch % 1 ~= 0) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ExpectedEpoch inválido"
		end
		return true,
			{
				Action = "ClearWorkshop",
				ClientOpId = rawClientOpId,
				ExpectedRevision = expectedRev,
				ExpectedEpoch = expectedEpoch,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.RecoverLegacyBlueprint then
		local originalId = rawget(rawRequest, "OriginalBlueprintId")
		if not isSafeIdentifier(originalId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "OriginalBlueprintId inválido"
		end
		local targetSlot = rawget(rawRequest, "TargetSlotIndex")
		if not isValidSlotIndex(targetSlot) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "TargetSlotIndex inválido (debe ser 1, 2 o 3)"
		end
		local confirmationStep = rawget(rawRequest, "ConfirmationStep")
		if confirmationStep ~= nil and (not isFiniteNumber(confirmationStep) or confirmationStep % 1 ~= 0) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ConfirmationStep inválido"
		end
		return true,
			{
				Action = "RecoverLegacyBlueprint",
				ClientOpId = rawClientOpId,
				OriginalBlueprintId = originalId,
				TargetSlotIndex = targetSlot,
				ConfirmationStep = confirmationStep,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.SetStandOffset then
		local heightOffset = rawget(rawRequest, "HeightOffset")
		local lateralOffset = rawget(rawRequest, "LateralOffset")
		if not isFiniteNumber(heightOffset) or not isFiniteNumber(lateralOffset) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Offsets de Stand deben ser números finitos"
		end
		return true,
			{
				Action = "SetStandOffset",
				ClientOpId = rawClientOpId,
				HeightOffset = heightOffset,
				LateralOffset = lateralOffset,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.ResetStandOffset then
		return true,
			{
				Action = "ResetStandOffset",
				ClientOpId = rawClientOpId,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.SelectPrimaryAssembly then
		local groupId = rawget(rawRequest, "GroupId")
		if not isSafeIdentifier(groupId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "GroupId inválido"
		end
		return true,
			{
				Action = "SelectPrimaryAssembly",
				ClientOpId = rawClientOpId,
				GroupId = groupId,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.SellInventoryItem then
		local itemId = rawget(rawRequest, "ItemId")
		if type(itemId) ~= "string" or not isSafeIdentifier(itemId, GameConfig.Building.MaxStringLength) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ItemId inválido en solicitud de venta"
		end
		local rawQty = rawget(rawRequest, "Quantity")
		local validQty: number? = nil
		if rawQty ~= nil then
			if not isFiniteNumber(rawQty) or rawQty < 1 or rawQty % 1 ~= 0 then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Quantity debe ser un entero positivo"
			end
			validQty = math.floor(rawQty)
		end
		local rawInstId = rawget(rawRequest, "ItemInstanceId")
		local validInstId: string? = nil
		if rawInstId ~= nil and rawInstId ~= "" then
			if not isSafeIdentifier(rawInstId, GameConfig.Building.MaxStringLength) then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ItemInstanceId inválido"
			end
			validInstId = rawInstId
		end
		return true,
			{
				Action = "SellInventoryItem",
				ClientOpId = rawClientOpId,
				ItemId = itemId,
				Quantity = validQty,
				ItemInstanceId = validInstId,
			},
			nil,
			nil
	elseif action == BuildProtocol.Actions.UnlinkInventoryFromBlueprints then
		local rawItemId = rawget(rawRequest, "ItemId")
		local validItemId: string? = nil
		if rawItemId ~= nil and rawItemId ~= "" then
			if not isSafeIdentifier(rawItemId, GameConfig.Building.MaxStringLength) then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ItemId inválido"
			end
			validItemId = rawItemId
		end
		local rawInstId = rawget(rawRequest, "ItemInstanceId")
		local validInstId: string? = nil
		if rawInstId ~= nil and rawInstId ~= "" then
			if not isSafeIdentifier(rawInstId, GameConfig.Building.MaxStringLength) then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "ItemInstanceId inválido"
			end
			validInstId = rawInstId
		end
		if not validItemId and not validInstId then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Debes indicar ItemId o ItemInstanceId para desvincular"
		end
		local rawSlots = rawget(rawRequest, "TargetSlotIndices")
		local validSlots: { number }? = nil
		if rawSlots ~= nil then
			if type(rawSlots) ~= "table" or getmetatable(rawSlots) ~= nil then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "TargetSlotIndices inválido"
			end
			local list: { number } = {}
			local seen: { [number]: boolean } = {}
			for k, s in pairs(rawSlots) do
				if type(k) ~= "number" or k < 1 or k > GameConfig.Blueprints.MaxSlots or k % 1 ~= 0 or not isValidSlotIndex(s) then
					return false, nil, BuildProtocol.ErrorCodes.InvalidSlotIndex, "TargetSlotIndices contiene un índice inválido"
				end
				if not seen[s] then
					seen[s] = true
					table.insert(list, s)
				end
			end
			validSlots = list
		end
		local rawConfirmed = rawget(rawRequest, "Confirmed")
		if rawConfirmed ~= nil and type(rawConfirmed) ~= "boolean" then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Confirmed debe ser booleano"
		end
		return true,
			{
				Action = "UnlinkInventoryFromBlueprints",
				ClientOpId = rawClientOpId,
				ItemId = validItemId,
				ItemInstanceId = validInstId,
				TargetSlotIndices = validSlots,
				Confirmed = rawConfirmed,
			},
			nil,
			nil
	elseif
		action == BuildProtocol.Actions.LaunchVehicle
		or action == BuildProtocol.Actions.ReturnToWorkshop
		or action == BuildProtocol.Actions.ResetVehicle
		or action == BuildProtocol.Actions.ExitVehicleSeat
	then
		return true,
			{
				Action = action :: any,
				ClientOpId = rawClientOpId,
			} :: any,
			nil,
			nil
	end

	return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Acción no soportada"
end

return BuildPayloadValidator

