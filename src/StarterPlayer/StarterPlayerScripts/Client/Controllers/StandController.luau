--!strict
--[=[
	StandController
	Controlador cliente exclusivo del propietario de la estación para operar el Elevador
	de Construcción (Stand) dentro de BuildZone:
	- Mueve el EditableVehicle real vertical (Y) y horizontal/lateralmente (X) sin mutar
	  las coordenadas relativas de ninguna pieza del blueprint.
	- Calcula los límites dinámicos locales coherentes con las cotas reales del vehículo.
	- Implementa movimiento continuo al mantener pulsado con coalescencia temporal (<= 10 Hz)
	  y como máximo 1 RPC en vuelo, con rollback visual autoritativo si el servidor rechaza.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local VehicleCoordinateMath = require(ReplicatedStorage.Shared.Building.VehicleCoordinateMath)

local BuildState = require(script.Parent.BuildState)
local BuildPlacementController = require(script.Parent.BuildPlacementController)
local BuildPreviewController = require(script.Parent.BuildPreviewController)

export type InvokeHandler = BuildPlacementController.InvokeHandler
export type HoldAxis = "Height" | "Lateral"

export type HoldDebugStats = {
	RpcSent: number,
	CoalescedSteps: number,
	MaxInFlightObserved: number,
	MinIntervalSecondsObserved: number,
	LastSyncErrorCode: string?,
}

local StandController = {}

local _opSeq = 0
local _authoritativeHeight = GameConfig.Stand.DefaultHeightOffset
local _authoritativeLateral = GameConfig.Stand.DefaultLateralOffset

-- Estado de movimiento continuo (coalescencia sin saturar rate-limit)
local _holdAxis: HoldAxis? = nil
local _holdDirection = 0
local _holdFine = false
local _holdElapsed = 0
local _holdContinuousActive = false
local _desiredHeight = GameConfig.Stand.DefaultHeightOffset
local _desiredLateral = GameConfig.Stand.DefaultLateralOffset
local _sentHeight: number? = nil
local _sentLateral: number? = nil
local _inFlightCount = 0
local _pendingFlush = false
local _lastRpcSentAt = -1
local _activeHoldEpoch = 0
local _trailingFlushTimer: thread? = nil
local _holdInvokeOverride: InvokeHandler? = nil
local _holdClockOverride: (() -> number)? = nil

local function cancelTrailingFlushTimer()
	if _trailingFlushTimer then
		pcall(task.cancel, _trailingFlushTimer)
		_trailingFlushTimer = nil
	end
end

local _debugStats: HoldDebugStats = {
	RpcSent = 0,
	CoalescedSteps = 0,
	MaxInFlightObserved = 0,
	MinIntervalSecondsObserved = math.huge,
	LastSyncErrorCode = nil,
}

local function getClockNow(clockFn: (() -> number)?): number
	if clockFn then
		return clockFn()
	end
	if _holdClockOverride then
		return _holdClockOverride()
	end
	return os.clock()
end

local function roundOffset(value: number): number
	return math.round(value * 100) / 100
end

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

local function makeOpId(prefix: string): string
	_opSeq += 1
	local localPlayer = if RunService:IsRunning() then Players.LocalPlayer else nil
	local userId = if localPlayer then localPlayer.UserId else (BuildState.ExpectedOwnerUserId or 0)
	return `{prefix}_{userId}_{_opSeq}`
end

local function resolvePieceSize(itemId: string): Vector3?
	return BuildPreviewController.GetPieceSize(itemId)
end

local function applyEditableVehicleVisualOffset(heightOffset: number, lateralOffset: number)
	if not StandController.IsOwner() or not BuildState.IsEditingMode() then
		return
	end
	local plot = BuildState.AssignedPlot
	local buildZone = BuildState.BuildZone
	if not plot or not plot.Parent or not buildZone then
		return
	end
	local dynamicRuntime = plot:FindFirstChild(GameConfig.PlotContainers.Dynamic)
	local editableVehicle = dynamicRuntime and dynamicRuntime:FindFirstChild(GameConfig.Building.EditableVehicleName)
	if not editableVehicle or not editableVehicle:IsA("Model") or editableVehicle:GetAttribute("IsEditableHidden") == true then
		return
	end

	local offset: VehicleTypes.BuildAssemblyOffset = {
		HeightOffset = heightOffset,
		LateralOffset = lateralOffset,
	}
	for _, piece in ipairs(BuildState.BlueprintPieces) do
		local pieceModel = editableVehicle:FindFirstChild(piece.InstanceId)
		if pieceModel and pieceModel:IsA("Model") then
			pieceModel:PivotTo(
				VehicleCoordinateMath.BlueprintPieceToBuildZoneWorld(piece.LocalCFrame, buildZone.CFrame, offset)
			)
		end
	end
	editableVehicle.WorldPivot = VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(buildZone.CFrame, offset)
end

local function syncAuthoritativeFromState()
	local pres = BuildState.GetAssemblyOffset()
	_authoritativeHeight = pres.HeightOffset
	_authoritativeLateral = pres.LateralOffset
	if _holdAxis == nil and _inFlightCount == 0 then
		_desiredHeight = pres.HeightOffset
		_desiredLateral = pres.LateralOffset
	end
end

function StandController.IsOwner(): boolean
	local plot = BuildState.AssignedPlot
	if not plot or not plot.Parent then
		return false
	end
	local ownerAttr = plot:GetAttribute(GameConfig.PlotAttributes.OwnerUserId)
	local localPlayer = if RunService:IsRunning() then Players.LocalPlayer else nil
	if localPlayer then
		return ownerAttr == localPlayer.UserId
	end
	if BuildState.ExpectedOwnerUserId ~= nil then
		return ownerAttr == BuildState.ExpectedOwnerUserId
	end
	return false
end

function StandController.GetDynamicBounds(): VehicleTypes.LiftBounds
	local buildZone = BuildState.BuildZone
	local zoneSize = if buildZone
		then buildZone.Size
		else Vector3.new(40, GameConfig.Building.DefaultZoneHeight, 40)
	local platInst = if buildZone and buildZone.Parent then buildZone.Parent:FindFirstChild("Platform") else nil
	local floorLocalY = VehicleCoordinateMath.ComputeZoneFloorLocalY(
		buildZone,
		if platInst and platInst:IsA("BasePart") then platInst :: BasePart else nil
	)
	return VehicleCoordinateMath.ComputeLiftBounds(
		BuildState.BlueprintPieces,
		resolvePieceSize,
		zoneSize,
		GameConfig.Building.DefaultZoneHeight,
		floorLocalY
	)
end

function StandController.ClampOffsetToDynamicBounds(heightOffset: number, lateralOffset: number): (number, number)
	local bounds = StandController.GetDynamicBounds()
	local clampedH = roundOffset(math.clamp(heightOffset, bounds.MinHeightOffset, bounds.MaxHeightOffset))
	local clampedL = roundOffset(math.clamp(lateralOffset, bounds.MinLateralOffset, bounds.MaxLateralOffset))
	return clampedH, clampedL
end

function StandController.ApplyOptimisticVisual(heightOffset: number, lateralOffset: number): boolean
	if not StandController.IsOwner() or not BuildState.IsEditingMode() then
		return false
	end
	local clampedH, clampedL = StandController.ClampOffsetToDynamicBounds(heightOffset, lateralOffset)
	BuildState.SetStandPresentationState({
		HeightOffset = clampedH,
		LateralOffset = clampedL,
	})
	applyEditableVehicleVisualOffset(clampedH, clampedL)
	return true
end

function StandController.SetStandOffset(
	heightOffset: number,
	lateralOffset: number,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	if not StandController.IsOwner() then
		BuildState.SetError("Solo el propietario de la estación puede ajustar el Elevador")
		return false, nil
	end
	if not BuildState.IsEditingMode() then
		BuildState.SetError("El Elevador está bloqueado mientras el vehículo está activo")
		return false, nil
	end

	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	local clampedH, clampedL = StandController.ClampOffsetToDynamicBounds(heightOffset, lateralOffset)
	local prevPres = BuildState.GetAssemblyOffset()
	_authoritativeHeight = prevPres.HeightOffset
	_authoritativeLateral = prevPres.LateralOffset

	local epoch = BuildState.TransitionEpoch
	local ok, res = pcall(invoke, {
		Action = BuildProtocol.Actions.SetStandOffset,
		ClientOpId = makeOpId("stand"),
		HeightOffset = clampedH,
		LateralOffset = clampedL,
	})

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if not ok or type(res) ~= "table" then
		applyEditableVehicleVisualOffset(_authoritativeHeight, _authoritativeLateral)
		BuildState.SetStandPresentationState({
			HeightOffset = _authoritativeHeight,
			LateralOffset = _authoritativeLateral,
		})
		BuildState.SetError("Error de red al ajustar el Elevador")
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		local confirmedPres = response.BuildAssemblyOffset
			or response.Presentation
			or (response.Blueprint and response.Blueprint.Presentation)
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		elseif confirmedPres then
			BuildState.SetStandPresentationState(confirmedPres)
		end
		if confirmedPres then
			_authoritativeHeight = confirmedPres.HeightOffset
			_authoritativeLateral = confirmedPres.LateralOffset
			_desiredHeight = confirmedPres.HeightOffset
			_desiredLateral = confirmedPres.LateralOffset
			applyEditableVehicleVisualOffset(confirmedPres.HeightOffset, confirmedPres.LateralOffset)
		end
		if response.HasUnsavedChanges ~= nil then
			BuildState.SetBlueprintLibraryState(nil, response.HasUnsavedChanges, nil)
		end
		BuildState.SetError(nil)
		return true, response
	end

	applyEditableVehicleVisualOffset(_authoritativeHeight, _authoritativeLateral)
	BuildState.SetStandPresentationState({
		HeightOffset = _authoritativeHeight,
		LateralOffset = _authoritativeLateral,
	})
	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo ajustar el Elevador")
	return false, response
end

function StandController.NudgeHeight(direction: number, fineStep: boolean?, customInvoke: InvokeHandler?)
	local step = if fineStep then GameConfig.Stand.FineStep else GameConfig.Stand.NormalStep
	local cur = BuildState.GetAssemblyOffset()
	return StandController.SetStandOffset(cur.HeightOffset + direction * step, cur.LateralOffset, customInvoke)
end

function StandController.NudgeLateral(direction: number, fineStep: boolean?, customInvoke: InvokeHandler?)
	local step = if fineStep then GameConfig.Stand.FineStep else GameConfig.Stand.NormalStep
	local cur = BuildState.GetAssemblyOffset()
	return StandController.SetStandOffset(cur.HeightOffset, cur.LateralOffset + direction * step, customInvoke)
end

local function cancelHoldInternal()
	_holdAxis = nil
	_holdDirection = 0
	_holdContinuousActive = false
	_holdElapsed = 0
end

local function dispatchHoldSyncIfReady(customInvoke: InvokeHandler?, nowTime: number)
	if not StandController.IsOwner() or not BuildState.IsEditingMode() then
		cancelHoldInternal()
		return
	end
	if _inFlightCount > 0 then
		_pendingFlush = true
		return
	end

	local targetH, targetL = StandController.ClampOffsetToDynamicBounds(_desiredHeight, _desiredLateral)
	local eps = 1e-3
	if _sentHeight and _sentLateral and math.abs(targetH - _sentHeight) < eps and math.abs(targetL - _sentLateral) < eps then
		_pendingFlush = false
		return
	end
	if
		_holdAxis == nil
		and math.abs(targetH - _authoritativeHeight) < eps
		and math.abs(targetL - _authoritativeLateral) < eps
	then
		_pendingFlush = false
		return
	end

	local minInterval = GameConfig.Stand.ContinuousSyncIntervalSeconds
	if _lastRpcSentAt >= 0 and (nowTime - _lastRpcSentAt) < minInterval then
		_pendingFlush = true
		if _holdAxis == nil and not _trailingFlushTimer then
			local waitRemaining = math.max(0.01, minInterval - (nowTime - _lastRpcSentAt))
			local scheduledEpoch = _activeHoldEpoch
			_trailingFlushTimer = task.delay(waitRemaining, function()
				_trailingFlushTimer = nil
				if _activeHoldEpoch == scheduledEpoch and _pendingFlush and _holdAxis == nil then
					dispatchHoldSyncIfReady(customInvoke, getClockNow(nil))
				end
			end)
		end
		return
	end
	cancelTrailingFlushTimer()

	local invoke = customInvoke or _holdInvokeOverride or getDefaultInvokeHandler()
	if not invoke then
		return
	end

	if _lastRpcSentAt >= 0 then
		local deltaInterval = nowTime - _lastRpcSentAt
		if deltaInterval < _debugStats.MinIntervalSecondsObserved then
			_debugStats.MinIntervalSecondsObserved = deltaInterval
		end
	end

	_lastRpcSentAt = nowTime
	_pendingFlush = false
	_sentHeight = targetH
	_sentLateral = targetL
	_inFlightCount += 1
	if _inFlightCount > _debugStats.MaxInFlightObserved then
		_debugStats.MaxInFlightObserved = _inFlightCount
	end
	_debugStats.RpcSent += 1

	local holdEpoch = _activeHoldEpoch
	local transitionEpoch = BuildState.TransitionEpoch

	task.spawn(function()
		local ok, res = pcall(invoke, {
			Action = BuildProtocol.Actions.SetStandOffset,
			ClientOpId = makeOpId("standhold"),
			HeightOffset = targetH,
			LateralOffset = targetL,
		})

		_inFlightCount = math.max(0, _inFlightCount - 1)

		if BuildState.TransitionEpoch ~= transitionEpoch or holdEpoch ~= _activeHoldEpoch then
			return
		end

		if not ok or type(res) ~= "table" then
			_debugStats.LastSyncErrorCode = "NetworkError"
			cancelHoldInternal()
			_desiredHeight = _authoritativeHeight
			_desiredLateral = _authoritativeLateral
			_sentHeight = _authoritativeHeight
			_sentLateral = _authoritativeLateral
			applyEditableVehicleVisualOffset(_authoritativeHeight, _authoritativeLateral)
			BuildState.SetStandPresentationState({
				HeightOffset = _authoritativeHeight,
				LateralOffset = _authoritativeLateral,
			})
			BuildState.SetError("Error de red al mover el Elevador")
			return
		end

		local response = res :: BuildProtocol.BuildOperationResponse
		if response.Success then
			_debugStats.LastSyncErrorCode = nil
			local confirmedPres = response.BuildAssemblyOffset
				or response.Presentation
				or (response.Blueprint and response.Blueprint.Presentation)
			if confirmedPres then
				_authoritativeHeight = confirmedPres.HeightOffset
				_authoritativeLateral = confirmedPres.LateralOffset
			end
			if response.HasUnsavedChanges ~= nil then
				BuildState.SetBlueprintLibraryState(nil, response.HasUnsavedChanges, nil)
			end
			BuildState.SetError(nil)

			-- Si el usuario siguió manteniendo o soltó con otro destino pendiente, despachar actualización final coalescida
			local latestH, latestL = StandController.ClampOffsetToDynamicBounds(_desiredHeight, _desiredLateral)
			if
				_pendingFlush
				or math.abs(latestH - _authoritativeHeight) >= 1e-3
				or math.abs(latestL - _authoritativeLateral) >= 1e-3
			then
				dispatchHoldSyncIfReady(customInvoke, getClockNow(nil))
			elseif confirmedPres then
				BuildState.SetStandPresentationState(confirmedPres)
				applyEditableVehicleVisualOffset(confirmedPres.HeightOffset, confirmedPres.LateralOffset)
			end
		else
			_debugStats.LastSyncErrorCode = response.ErrorCode or "Rejected"
			cancelHoldInternal()
			_pendingFlush = false
			_desiredHeight = _authoritativeHeight
			_desiredLateral = _authoritativeLateral
			_sentHeight = _authoritativeHeight
			_sentLateral = _authoritativeLateral
			applyEditableVehicleVisualOffset(_authoritativeHeight, _authoritativeLateral)
			BuildState.SetStandPresentationState({
				HeightOffset = _authoritativeHeight,
				LateralOffset = _authoritativeLateral,
			})
			BuildState.SetError(response.ErrorMessage or response.ErrorCode or "Movimiento del Elevador rechazado")
		end
	end)
end

function StandController.BeginContinuousHold(
	axis: HoldAxis,
	direction: number,
	fineStep: boolean?,
	customInvoke: InvokeHandler?,
	clockFn: (() -> number)?
): boolean
	if not StandController.IsOwner() then
		BuildState.SetError("Solo el propietario de la estación puede operar el Elevador")
		return false
	end
	if not BuildState.IsEditingMode() then
		BuildState.SetError("El Elevador está bloqueado mientras el vehículo está activo")
		return false
	end

	syncAuthoritativeFromState()
	cancelTrailingFlushTimer()
	_activeHoldEpoch += 1
	_holdAxis = axis
	_holdDirection = if direction >= 0 then 1 else -1
	_holdFine = fineStep == true
	_holdElapsed = 0
	_holdContinuousActive = false
	_pendingFlush = false
	_holdInvokeOverride = customInvoke
	_holdClockOverride = clockFn
	_sentHeight = _authoritativeHeight
	_sentLateral = _authoritativeLateral

	local step = if _holdFine then GameConfig.Stand.FineStep else GameConfig.Stand.NormalStep
	local cur = BuildState.GetAssemblyOffset()
	local nextH = cur.HeightOffset
	local nextL = cur.LateralOffset
	if axis == "Height" then
		nextH += _holdDirection * step
	else
		nextL += _holdDirection * step
	end

	local clampedH, clampedL = StandController.ClampOffsetToDynamicBounds(nextH, nextL)
	_desiredHeight = clampedH
	_desiredLateral = clampedL

	-- Retroalimentación inmediata local en el elevador y el vehículo real
	BuildState.SetStandPresentationState({
		HeightOffset = clampedH,
		LateralOffset = clampedL,
	})
	applyEditableVehicleVisualOffset(clampedH, clampedL)

	local nowTime = getClockNow(clockFn)
	-- Permitir que el tap inicial envíe o coalesza respetando cadencia máxima de 10 Hz
	dispatchHoldSyncIfReady(customInvoke, nowTime)
	return true
end

function StandController.StepContinuousHold(
	dt: number,
	customInvoke: InvokeHandler?,
	clockFn: (() -> number)?
)
	if not _holdAxis then
		return
	end
	if not StandController.IsOwner() or not BuildState.IsEditingMode() then
		cancelHoldInternal()
		return
	end

	local clampedDt = math.clamp(dt, 0, 0.25)
	_holdElapsed += clampedDt
	_debugStats.CoalescedSteps += 1

	local holdDelay = GameConfig.Stand.ContinuousHoldDelaySeconds
	if _holdElapsed >= holdDelay then
		local activeDt = if not _holdContinuousActive then (_holdElapsed - holdDelay) else clampedDt
		_holdContinuousActive = true

		local speed = if _holdFine
			then GameConfig.Stand.ContinuousFineSpeed
			else GameConfig.Stand.ContinuousNormalSpeed
		if _holdAxis == "Height" then
			_desiredHeight += _holdDirection * speed * activeDt
		else
			_desiredLateral += _holdDirection * speed * activeDt
		end

		local clampedH, clampedL = StandController.ClampOffsetToDynamicBounds(_desiredHeight, _desiredLateral)
		_desiredHeight = clampedH
		_desiredLateral = clampedL

		BuildState.SetStandPresentationState({
			HeightOffset = clampedH,
			LateralOffset = clampedL,
		})
		applyEditableVehicleVisualOffset(clampedH, clampedL)
	end

	dispatchHoldSyncIfReady(customInvoke, getClockNow(clockFn))
end

function StandController.EndContinuousHold(customInvoke: InvokeHandler?, clockFn: (() -> number)?)
	if not _holdAxis then
		return
	end
	cancelHoldInternal()
	local nowTime = getClockNow(clockFn)
	local clampedH, clampedL = StandController.ClampOffsetToDynamicBounds(_desiredHeight, _desiredLateral)
	_desiredHeight = clampedH
	_desiredLateral = clampedL
	if
		_sentHeight == nil
		or _sentLateral == nil
		or math.abs(clampedH - _sentHeight) >= 1e-3
		or math.abs(clampedL - _sentLateral) >= 1e-3
	then
		_pendingFlush = true
		dispatchHoldSyncIfReady(customInvoke, nowTime)
	end
end

function StandController.IsHoldActive(): boolean
	return _holdAxis ~= nil
end

function StandController.ResetStandOffset(customInvoke: InvokeHandler?): (boolean, BuildProtocol.BuildOperationResponse?)
	cancelHoldInternal()
	cancelTrailingFlushTimer()
	_pendingFlush = false
	_activeHoldEpoch += 1

	if not StandController.IsOwner() then
		BuildState.SetError("Solo el propietario de la estación puede reiniciar el Elevador")
		return false, nil
	end

	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		return false, nil
	end

	local prevPres = BuildState.GetAssemblyOffset()
	_authoritativeHeight = prevPres.HeightOffset
	_authoritativeLateral = prevPres.LateralOffset

	local epoch = BuildState.TransitionEpoch
	local ok, res = pcall(invoke, {
		Action = BuildProtocol.Actions.ResetStandOffset,
		ClientOpId = makeOpId("standrst"),
	})

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if not ok or type(res) ~= "table" then
		BuildState.SetError("Error de red al reiniciar el Elevador")
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		local confirmedPres = response.BuildAssemblyOffset
			or response.Presentation
			or (response.Blueprint and response.Blueprint.Presentation)
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		elseif confirmedPres then
			BuildState.SetStandPresentationState(confirmedPres)
		end
		if confirmedPres then
			_authoritativeHeight = confirmedPres.HeightOffset
			_authoritativeLateral = confirmedPres.LateralOffset
			_desiredHeight = confirmedPres.HeightOffset
			_desiredLateral = confirmedPres.LateralOffset
			_sentHeight = confirmedPres.HeightOffset
			_sentLateral = confirmedPres.LateralOffset
			applyEditableVehicleVisualOffset(confirmedPres.HeightOffset, confirmedPres.LateralOffset)
		end
		if response.HasUnsavedChanges ~= nil then
			BuildState.SetBlueprintLibraryState(nil, response.HasUnsavedChanges, nil)
		end
		BuildState.SetStatusMessage("Elevador reiniciado a posición base")
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo reiniciar el Elevador")
	return false, response
end

function StandController.RunLaunchPrepCheck(customInvoke: InvokeHandler?): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor no disponible para verificar lanzamiento")
		return false, nil
	end

	local epoch = BuildState.TransitionEpoch
	local ok, res = pcall(invoke, {
		Action = BuildProtocol.Actions.ValidateLaunchPrep,
		ClientOpId = makeOpId("lprep"),
	})

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if not ok or type(res) ~= "table" then
		BuildState.SetError("Error al consultar preparación de lanzamiento")
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success and response.LaunchPrepReport then
		BuildState.SetLaunchPrepReport(response.LaunchPrepReport)
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo verificar el lanzamiento")
	return false, response
end

function StandController.GetHoldDebugStats(): HoldDebugStats
	return table.clone(_debugStats)
end

function StandController.ResetHoldDebugStatsForTests()
	cancelHoldInternal()
	cancelTrailingFlushTimer()
	_inFlightCount = 0
	_pendingFlush = false
	_lastRpcSentAt = -1
	_sentHeight = nil
	_sentLateral = nil
	_holdInvokeOverride = nil
	_holdClockOverride = nil
	_authoritativeHeight = GameConfig.Stand.DefaultHeightOffset
	_authoritativeLateral = GameConfig.Stand.DefaultLateralOffset
	_desiredHeight = GameConfig.Stand.DefaultHeightOffset
	_desiredLateral = GameConfig.Stand.DefaultLateralOffset
	_debugStats = {
		RpcSent = 0,
		CoalescedSteps = 0,
		MaxInFlightObserved = 0,
		MinIntervalSecondsObserved = math.huge,
		LastSyncErrorCode = nil,
	}
end

return StandController
