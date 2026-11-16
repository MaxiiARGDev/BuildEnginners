--!strict
--[=[
	WheelConfigController
	Controlador cliente para análisis contextual de ruedas y edición híbrida Auto/Manual:
	- Calcula vista previa local instantánea mediante WheelAutoConfiguration (compartida con servidor).
	- Envía cambios autoritativos por UpdatePieceConfig con protección anti-doble-click, timeout y rollback.
	- Permite editar campos individuales o restablecer un campo / toda la rueda a Auto.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local WheelAutoConfiguration = require(ReplicatedStorage.Shared.Building.WheelAutoConfiguration)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BuildState = require(script.Parent.BuildState)

export type InvokeHandler = (request: any) -> BuildProtocol.BuildOperationResponse

local WheelConfigController = {}

local _opSeq = 0
local _inFlight = false
local _operationTimeoutSeconds = GameConfig.Building.OperationTimeoutSeconds

local function getDefaultInvokeHandler(): InvokeHandler?
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local remotes = shared and shared:FindFirstChild("Remotes")
	local rf = remotes and remotes:FindFirstChild(BuildProtocol.RemoteFunctionName)
	if rf and rf:IsA("RemoteFunction") then
		return function(req: any): BuildProtocol.BuildOperationResponse
			return (rf :: RemoteFunction):InvokeServer(req)
		end
	end
	return nil
end

local function makeOpId(): string
	_opSeq += 1
	local localPlayer = Players.LocalPlayer
	local userId = if localPlayer then localPlayer.UserId else (BuildState.ExpectedOwnerUserId or 0)
	return `wcfg_{userId}_{_opSeq}`
end

local function invokeWithTimeout(
	invoke: InvokeHandler,
	request: any,
	timeoutSeconds: number
): (boolean, any, boolean)
	local finished = false
	local callOk = false
	local callResult: any = nil
	local timedOut = false
	local callerThread = coroutine.running()

	task.spawn(function()
		local ok, res = pcall(invoke, request)
		callOk = ok
		callResult = res
		finished = true
		if not timedOut and coroutine.status(callerThread) == "suspended" then
			task.spawn(callerThread)
		end
	end)

	if not finished then
		local timer = task.delay(timeoutSeconds, function()
			if not finished then
				timedOut = true
				if coroutine.status(callerThread) == "suspended" then
					task.spawn(callerThread)
				end
			end
		end)
		coroutine.yield()
		if finished then
			pcall(task.cancel, timer)
		end
	end

	return callOk, callResult, timedOut
end

local function buildSyntheticBlueprintFromState(): VehicleTypes.VehicleBlueprint
	local ownerId = BuildState.ExpectedOwnerUserId
		or (if Players.LocalPlayer then Players.LocalPlayer.UserId else 0)
	return {
		SchemaVersion = GameConfig.Blueprints.CurrentSchemaVersion,
		BlueprintId = BuildState.BlueprintId or "bp_local",
		OwnerUserId = ownerId,
		Name = BuildState.BlueprintName,
		Revision = BuildState.BlueprintRevision,
		CreatedAt = 0,
		UpdatedAt = 0,
		VehicleOrigin = CFrame.identity,
		Presentation = BuildState.GetAssemblyOffset(),
		Metadata = BuildState.BlueprintMetadata,
		Pieces = BuildState.BlueprintPieces,
		Connections = BuildState.BlueprintConnections,
	}
end

local function cloneOverrides(src: VehicleTypes.WheelPieceConfigOverrides?): VehicleTypes.WheelPieceConfigOverrides
	if not src then
		return {}
	end
	return table.clone(src) :: VehicleTypes.WheelPieceConfigOverrides
end

function WheelConfigController.AnalyzeCurrentBlueprint(targetPieceId: string?): VehicleTypes.VehicleWheelAnalysis
	local bp = buildSyntheticBlueprintFromState()
	local primaryPieceIds: { string }? = nil
	local analysis = ConnectionMath.AnalyzeAssemblies(bp.Pieces, bp.Connections, bp.Metadata)
	if analysis and not analysis.NeedsPrimarySelection and #analysis.PrimaryPieceIds > 0 then
		-- Si targetPieceId pertenece al primario o no hay targetPieceId, usar primario;
		-- si la rueda está en un sub-ensamblaje distinto, dejar que TargetPieceId evalúe su grupo.
		if not targetPieceId then
			primaryPieceIds = analysis.PrimaryPieceIds
		else
			for _, pid in ipairs(analysis.PrimaryPieceIds) do
				if pid == targetPieceId then
					primaryPieceIds = analysis.PrimaryPieceIds
					break
				end
			end
		end
	end

	return WheelAutoConfiguration.AnalyzeBlueprint(bp, {
		PrimaryPieceIds = primaryPieceIds,
		TargetPieceId = targetPieceId,
	})
end

function WheelConfigController.GetSelectedWheelContext(): (
	VehicleTypes.BlueprintPiece?,
	VehicleTypes.ResolvedWheelConfig?,
	VehicleTypes.VehicleWheelAnalysis?
)
	if not BuildState.IsActive or not BuildState.IsEditingMode() then
		return nil, nil, nil
	end
	local pieceId = BuildState.SelectedPlacedPieceId
	if not pieceId then
		return nil, nil, nil
	end
	local piece = BuildState.GetPiece(pieceId)
	if not piece or not WheelAutoConfiguration.IsWheelItem(piece.ItemId) then
		return nil, nil, nil
	end

	local wheelAnalysis = WheelConfigController.AnalyzeCurrentBlueprint(pieceId)
	local resolved = wheelAnalysis.ByPieceId[pieceId]
	return piece, resolved, wheelAnalysis
end

function WheelConfigController.IsBusy(): boolean
	return _inFlight
end

function WheelConfigController.ApplyWheelOverrides(
	pieceInstanceId: string,
	overrides: VehicleTypes.WheelPieceConfigOverrides?,
	invokeOverride: InvokeHandler?
): (boolean, string?)
	if not BuildState.IsEditingMode() then
		return false, "No estás en modo edición"
	end
	if _inFlight then
		return false, "Actualización de rueda en curso"
	end

	local piece = BuildState.GetPiece(pieceInstanceId)
	if not piece or not WheelAutoConfiguration.IsWheelItem(piece.ItemId) then
		return false, "Rueda no encontrada en el blueprint"
	end

	local okValid, cleanedOverrides, _, validErrMsg = WheelAutoConfiguration.ValidateManualOverrides(overrides)
	if not okValid then
		BuildState.SetError(validErrMsg or "Valor inválido para rueda")
		return false, validErrMsg
	end

	local invoke = invokeOverride or getDefaultInvokeHandler()
	if not invoke then
		return false, "Remoto de construcción no disponible"
	end

	local prevConfig = BlueprintSerializer.DeepCloneTable(piece.Config)
	local expectedEpoch = BuildState.TransitionEpoch
	local optimisticConfig: { [string]: any }? = if cleanedOverrides then { Wheel = cleanedOverrides } else nil

	-- Optimistic update
	piece.Config = optimisticConfig
	_inFlight = true
	BuildState.SetPendingOpCount(BuildState.PendingOpCount + 1)

	local request = {
		Action = BuildProtocol.Actions.UpdatePieceConfig,
		ClientOpId = makeOpId(),
		PieceInstanceId = pieceInstanceId,
		Config = optimisticConfig,
		ResetToAuto = (cleanedOverrides == nil),
	}

	local callOk, response, timedOut = invokeWithTimeout(invoke, request, _operationTimeoutSeconds)
	BuildState.SetPendingOpCount(BuildState.PendingOpCount - 1)
	_inFlight = false

	if BuildState.TransitionEpoch ~= expectedEpoch then
		return false, "Cambio cancelado por transición de blueprint"
	end

	if timedOut or not callOk or type(response) ~= "table" then
		local currentPiece = BuildState.GetPiece(pieceInstanceId)
		if currentPiece then
			currentPiece.Config = prevConfig
		end
		local errMsg = if timedOut then "Tiempo agotado actualizando rueda" else "Error comunicando configuración"
		BuildState.SetError(errMsg)
		return false, errMsg
	end

	local res = response :: BuildProtocol.BuildOperationResponse
	if not res.Success then
		local currentPiece = BuildState.GetPiece(pieceInstanceId)
		if currentPiece then
			currentPiece.Config = prevConfig
		end
		local errMsg = res.ErrorMessage or "Servidor rechazó configuración de rueda"
		BuildState.SetError(errMsg)
		return false, errMsg
	end

	if res.Blueprint then
		BuildState.ApplyAuthoritativeBlueprint(res.Blueprint, false)
	elseif res.UpdatedPiece then
		local currentPiece = BuildState.GetPiece(pieceInstanceId)
		if currentPiece then
			currentPiece.Config = res.UpdatedPiece.Config
		end
	end

	BuildState.SetStatusMessage(if cleanedOverrides then "Rueda actualizada (Manual)" else "Rueda restablecida a Auto")
	return true, nil
end

function WheelConfigController.SetWheelField(
	pieceInstanceId: string,
	fieldName: string,
	fieldValue: any,
	invokeOverride: InvokeHandler?
): (boolean, string?)
	local piece = BuildState.GetPiece(pieceInstanceId)
	if not piece or not WheelAutoConfiguration.IsWheelItem(piece.ItemId) then
		return false, "Rueda no encontrada"
	end

	local nextOverrides = cloneOverrides(WheelAutoConfiguration.ExtractManualOverrides(piece)) :: { [string]: any }
	if fieldName == "SteeringMode" and (fieldValue == nil or fieldValue == "Auto") then
		nextOverrides.SteeringMode = nil
		nextOverrides.MaxSteeringAngle = nil
		nextOverrides.SteeringSpeed = nil
		nextOverrides.SteeringDirectionMultiplier = nil
	else
		nextOverrides[fieldName] = fieldValue
	end

	return WheelConfigController.ApplyWheelOverrides(
		pieceInstanceId,
		nextOverrides :: VehicleTypes.WheelPieceConfigOverrides,
		invokeOverride
	)
end

function WheelConfigController.ResetWheelToAuto(
	pieceInstanceId: string,
	invokeOverride: InvokeHandler?
): (boolean, string?)
	return WheelConfigController.ApplyWheelOverrides(pieceInstanceId, nil, invokeOverride)
end

function WheelConfigController._SetOperationTimeoutForTests(seconds: number?)
	_operationTimeoutSeconds = seconds or GameConfig.Building.OperationTimeoutSeconds
end

function WheelConfigController._ResetForTests()
	_inFlight = false
	_opSeq = 0
	_operationTimeoutSeconds = GameConfig.Building.OperationTimeoutSeconds
end

return WheelConfigController
