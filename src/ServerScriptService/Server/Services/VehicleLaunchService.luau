--!strict
--[=[
	VehicleLaunchService
	Orquestador público del flujo de lanzamiento autoritativo en servidor (Fase 3.1):
	- `LaunchVehicle`: valida preparación, ensambla en staging, publica en Workspace, activa físicas y sienta conductor.
	- `ReturnToWorkshop`: destruye runtime limpio, retorna al jugador al taller y preserva intacto Blueprint/EditableVehicle.
	- `ResetVehicle`: regenera el VehicleRuntime desde el Blueprint intacto en LaunchPoint sin destruir el taller.
	- `ExitVehicleSeat`: pasa a `OnFootRuntime` manteniendo temporalmente el vehículo estacionado.
	- `GetRuntimeState`: consulta snapshot de estado actual del jugador.
	Aplica bloqueo de concurrencia y cooldown anti-spam por jugador.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local PlotService = require(ServerScriptService.Server.Services.PlotService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local VehicleLaunchPreparationService = require(ServerScriptService.Server.Services.VehicleLaunchPreparationService)
local VehicleAssemblyService = require(ServerScriptService.Server.Services.VehicleAssemblyService)
local VehicleRuntimeService = require(ServerScriptService.Server.Services.VehicleRuntimeService)
local VehicleLifecycleService = require(ServerScriptService.Server.Services.VehicleLifecycleService)

export type LaunchActionOptions = {
	MountDriver: boolean?,
	SkipSeatRetryYield: boolean?,
	SimulateSeated: boolean?,
	SkipWorldObstructionCheck: boolean?,
}

export type LaunchActionResult = {
	Success: boolean,
	ErrorCode: string?,
	ErrorMessage: string?,
	RuntimeStatus: VehicleTypes.RuntimeStatusSnapshot,
	LaunchPrepReport: VehicleTypes.LaunchPreparationReport?,
	Runtime: VehicleTypes.VehicleRuntime?,
	ExitDestination: CFrame?,
}

local VehicleLaunchService = {
	Name = "VehicleLaunchService",
}

local _inProgressByUserId: { [number]: boolean } = {}
local _lastActionAtByUserId: { [number]: number } = {}
local _clockFn: () -> number = os.clock
local _unsubPlotReleased: (() -> ())? = nil
local _initialized = false
local _started = false

local function failResult(
	userId: number,
	errCode: string,
	errMsg: string,
	prepReport: VehicleTypes.LaunchPreparationReport?
): LaunchActionResult
	return {
		Success = false,
		ErrorCode = errCode,
		ErrorMessage = errMsg,
		RuntimeStatus = VehicleLifecycleService.GetRuntimeStatusSnapshot(userId),
		LaunchPrepReport = prepReport,
		Runtime = nil,
	}
end

local function checkCooldown(userId: number): (boolean, string?)
	local lastAt = _lastActionAtByUserId[userId]
	local now = _clockFn()
	if lastAt and (now - lastAt) < GameConfig.Runtime.LaunchCooldownSeconds then
		return false, "Esperá un instante antes de volver a lanzar o reiniciar el vehículo."
	end
	return true, nil
end

local function runLaunchPipeline(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	options: LaunchActionOptions?
): LaunchActionResult
	local userId = player.UserId
	local began, beginErrCode, beginErrMsg = VehicleLifecycleService.BeginLaunchPreparation(player)
	if not began then
		return failResult(
			userId,
			beginErrCode or BuildProtocol.ErrorCodes.LaunchInProgress,
			beginErrMsg or "No se pudo iniciar el lanzamiento"
		)
	end

	-- Congelar snapshot autoritativo del blueprint y validar LaunchPoint (sin alterar EditableVehicle ni Blueprint)
	local blueprintSnapshot = VehicleBlueprintService.GetBlueprintSnapshot(player)
	local prepReport = VehicleLaunchPreparationService.EvaluateBlueprintLaunch(blueprintSnapshot, plot, {
		SkipWorldObstructionCheck = if options then options.SkipWorldObstructionCheck else nil,
	})

	if not prepReport.Ready then
		local code = prepReport.PrimaryErrorCode or "LaunchNotReady"
		local msg = prepReport.PrimaryErrorMessage or "El diseño no cumple los requisitos de lanzamiento"
		VehicleLifecycleService.RollbackLaunch(player, code, msg)
		return failResult(userId, code, msg, prepReport)
	end

	if not VehicleLifecycleService.TransitionToLaunching(player) then
		VehicleLifecycleService.RollbackLaunch(player, BuildProtocol.ErrorCodes.InvalidPlayerState, "Transición de lanzamiento inválida")
		return failResult(userId, BuildProtocol.ErrorCodes.InvalidPlayerState, "Transición de lanzamiento inválida", prepReport)
	end

	local stagedOk, assembled, stageErrCode, stageErrMsg = VehicleAssemblyService.AssembleStagingRuntime({
		RuntimeId = `vrt_{userId}_{math.floor(_clockFn() * 1000)}`,
		Player = player,
		Plot = plot,
		Blueprint = blueprintSnapshot,
		PrepReport = prepReport,
		SkipStagingParent = true,
	})

	if not stagedOk or not assembled then
		local code = stageErrCode or BuildProtocol.ErrorCodes.AssemblyBuildFailed
		local msg = stageErrMsg or "Error al ensamblar el vehículo en staging"
		VehicleLifecycleService.RollbackLaunch(player, code, msg)
		return failResult(userId, code, msg, prepReport)
	end

	VehicleBlueprintService.SetEditableVehicleVisible(player, false, "LaunchConfirmed")

	local pubOk, runtime, pubErrCode, pubErrMsg = VehicleRuntimeService.PublishAndActivate({
		Player = player,
		Plot = plot,
		Blueprint = blueprintSnapshot,
		Assembled = assembled,
	})

	if not pubOk or not runtime then
		if assembled.RootModel and assembled.RootModel.Parent then
			assembled.RootModel:Destroy()
		end
		local code = pubErrCode or BuildProtocol.ErrorCodes.AssemblyBuildFailed
		local msg = pubErrMsg or "Error al publicar VehicleRuntime"
		VehicleLifecycleService.RollbackLaunch(player, code, msg)
		return failResult(userId, code, msg, prepReport)
	end

	local seatOk, seatErrCode, seatErrMsg = VehicleLifecycleService.CompleteLaunchWithSeatMount(player, runtime, {
		MountDriver = if options then options.MountDriver else nil,
		SkipSeatRetryYield = if options then options.SkipSeatRetryYield else nil,
		SimulateSeated = if options then options.SimulateSeated else nil,
	})

	if not seatOk then
		return failResult(
			userId,
			seatErrCode or BuildProtocol.ErrorCodes.DriverSeatMountFailed,
			seatErrMsg or "No se pudo completar el montaje del conductor",
			prepReport
		)
	end

	_lastActionAtByUserId[userId] = _clockFn()
	return {
		Success = true,
		RuntimeStatus = VehicleLifecycleService.GetRuntimeStatusSnapshot(userId),
		LaunchPrepReport = prepReport,
		Runtime = runtime,
	}
end

function VehicleLaunchService.LaunchVehicle(player: PlotService.PlayerLike, options: LaunchActionOptions?): LaunchActionResult
	if not _initialized then
		VehicleLaunchService.Init()
	end

	local userId = player.UserId
	if _inProgressByUserId[userId] then
		return failResult(userId, BuildProtocol.ErrorCodes.LaunchInProgress, "Ya hay una operación de lanzamiento en curso")
	end

	local plot = PlotService.GetPlotByPlayer(player)
	if not plot then
		return failResult(userId, BuildProtocol.ErrorCodes.NoAssignedPlot, "No tenés una estación asignada")
	end
	if not PlotService.IsOwner(player, plot.PlotId) then
		return failResult(userId, BuildProtocol.ErrorCodes.NotPlotOwner, "No sos propietario de esta estación")
	end

	local coolOk, coolMsg = checkCooldown(userId)
	if not coolOk then
		return failResult(userId, BuildProtocol.ErrorCodes.LaunchCooldown, coolMsg or "Cooldown de lanzamiento activo")
	end

	_inProgressByUserId[userId] = true
	local ok, resultOrErr = pcall(runLaunchPipeline, player, plot, options)
	_inProgressByUserId[userId] = nil

	if not ok then
		VehicleLifecycleService.RollbackLaunch(player, BuildProtocol.ErrorCodes.AssemblyBuildFailed, tostring(resultOrErr))
		return failResult(userId, BuildProtocol.ErrorCodes.AssemblyBuildFailed, tostring(resultOrErr))
	end

	return resultOrErr :: LaunchActionResult
end

function VehicleLaunchService.ReturnToWorkshop(player: PlotService.PlayerLike): LaunchActionResult
	if not _initialized then
		VehicleLaunchService.Init()
	end

	local userId = player.UserId
	if _inProgressByUserId[userId] then
		return failResult(userId, BuildProtocol.ErrorCodes.OperationInProgress, "Operación de lanzamiento en curso")
	end

	local runtime = VehicleRuntimeService.GetRuntimeByPlayer(userId)
	local state = VehicleLifecycleService.GetPlayerState(userId)
	if not runtime and state == GameConfig.Runtime.States.Editing then
		return failResult(userId, BuildProtocol.ErrorCodes.RuntimeNotActive, "No hay un vehículo activo en runtime")
	end
	if runtime and runtime.OwnerUserId ~= userId then
		return failResult(userId, BuildProtocol.ErrorCodes.NotRuntimeOwner, "No sos propietario de este runtime")
	end

	_inProgressByUserId[userId] = true
	local ok, retOk, errCode, errMsg = pcall(VehicleLifecycleService.ReturnToWorkshop, player, "ManualReturnToWorkshop", true)
	_inProgressByUserId[userId] = nil

	if not ok or not retOk then
		return failResult(
			userId,
			errCode or BuildProtocol.ErrorCodes.InvalidPlayerState,
			errMsg or "No se pudo regresar al taller"
		)
	end

	return {
		Success = true,
		RuntimeStatus = VehicleLifecycleService.GetRuntimeStatusSnapshot(userId),
	}
end

function VehicleLaunchService.ResetVehicle(player: PlotService.PlayerLike, options: LaunchActionOptions?): LaunchActionResult
	if not _initialized then
		VehicleLaunchService.Init()
	end

	local userId = player.UserId
	if _inProgressByUserId[userId] then
		return failResult(userId, BuildProtocol.ErrorCodes.OperationInProgress, "Operación de vehículo ya en curso")
	end

	local plot = PlotService.GetPlotByPlayer(player)
	if not plot then
		return failResult(userId, BuildProtocol.ErrorCodes.NoAssignedPlot, "No tenés una estación asignada")
	end
	if not PlotService.IsOwner(player, plot.PlotId) then
		return failResult(userId, BuildProtocol.ErrorCodes.NotPlotOwner, "No sos propietario de esta estación")
	end

	local existingRuntime = VehicleRuntimeService.GetRuntimeByPlayer(userId)
	local state = VehicleLifecycleService.GetPlayerState(userId)
	if not existingRuntime or (state ~= GameConfig.Runtime.States.Driving and state ~= GameConfig.Runtime.States.OnFootRuntime) then
		return failResult(userId, BuildProtocol.ErrorCodes.RuntimeNotActive, "No hay vehículo activo para reiniciar")
	end
	if existingRuntime.OwnerUserId ~= userId then
		return failResult(userId, BuildProtocol.ErrorCodes.NotRuntimeOwner, "No sos propietario de este runtime")
	end

	local coolOk, coolMsg = checkCooldown(userId)
	if not coolOk then
		return failResult(userId, BuildProtocol.ErrorCodes.LaunchCooldown, coolMsg or "Esperá antes de reiniciar el vehículo")
	end

	_inProgressByUserId[userId] = true

	-- Validar antes de destruir el vehículo viejo (excluyéndolo de detección) para evitar reiniciar sobre otro obstáculo
	local blueprintSnapshot = VehicleBlueprintService.GetBlueprintSnapshot(player)
	local preCheck = VehicleLaunchPreparationService.EvaluateBlueprintLaunch(blueprintSnapshot, plot, {
		SkipWorldObstructionCheck = if options then options.SkipWorldObstructionCheck else nil,
		ExtraExcludeInstances = if existingRuntime.RootModel then { existingRuntime.RootModel } else nil,
	})
	if not preCheck.Ready then
		_inProgressByUserId[userId] = nil
		return failResult(
			userId,
			preCheck.PrimaryErrorCode or "LaunchNotReady",
			preCheck.PrimaryErrorMessage or "LaunchPoint bloqueado para reinicio",
			preCheck
		)
	end

	-- Destruir runtime actual cleanly y regenerar nuevo runtime fresco desde blueprint intacto sin parpadeo del editable
	VehicleLifecycleService.ReturnToWorkshop(player, "ResetVehicle", false, false)
	local ok, resOrErr = pcall(runLaunchPipeline, player, plot, options)
	_inProgressByUserId[userId] = nil

	if not ok then
		VehicleLifecycleService.RollbackLaunch(player, BuildProtocol.ErrorCodes.AssemblyBuildFailed, tostring(resOrErr))
		VehicleBlueprintService.SetEditableVehicleVisible(userId, true, "ResetError")
		return failResult(userId, BuildProtocol.ErrorCodes.AssemblyBuildFailed, tostring(resOrErr))
	end

	local launchResult = resOrErr :: LaunchActionResult
	if not launchResult.Success then
		VehicleBlueprintService.SetEditableVehicleVisible(userId, true, "ResetFailed")
	end
	return launchResult
end

function VehicleLaunchService.ExitVehicleSeat(player: PlotService.PlayerLike): LaunchActionResult
	if not _initialized then
		VehicleLaunchService.Init()
	end

	local userId = player.UserId
	if _inProgressByUserId[userId] then
		return failResult(userId, BuildProtocol.ErrorCodes.OperationInProgress, "Operación en curso")
	end

	local exitOk, errCode, errMsg, exitDestination = VehicleLifecycleService.ExitVehicleSeat(player)
	if not exitOk then
		return failResult(
			userId,
			errCode or BuildProtocol.ErrorCodes.InvalidPlayerState,
			errMsg or "No se pudo salir del asiento"
		)
	end

	return {
		Success = true,
		RuntimeStatus = VehicleLifecycleService.GetRuntimeStatusSnapshot(userId),
		Runtime = VehicleRuntimeService.GetRuntimeByPlayer(userId),
		ExitDestination = exitDestination,
	}
end

function VehicleLaunchService.GetRuntimeState(player: PlotService.PlayerLike): VehicleTypes.RuntimeStatusSnapshot
	return VehicleLifecycleService.GetRuntimeStatusSnapshot(player)
end

function VehicleLaunchService.ClearPlayer(playerOrUserId: PlotService.PlayerLike | number)
	local userId = if type(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	_inProgressByUserId[userId] = nil
	_lastActionAtByUserId[userId] = nil
end

function VehicleLaunchService._SetClockForTests(clockFn: (() -> number)?)
	_clockFn = clockFn or os.clock
end

function VehicleLaunchService.Init()
	if _initialized then
		return
	end
	VehicleAssemblyService.Init()
	VehicleRuntimeService.Init()
	VehicleLifecycleService.Init()
	if not _unsubPlotReleased then
		_unsubPlotReleased = PlotService.OnPlotReleased(function(playerLike)
			VehicleLaunchService.ClearPlayer(playerLike)
		end)
	end
	_initialized = true
end

function VehicleLaunchService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehicleLaunchService.Init()
	end
	_started = true
end

function VehicleLaunchService._ResetForTests()
	if _unsubPlotReleased then
		_unsubPlotReleased()
		_unsubPlotReleased = nil
	end
	table.clear(_inProgressByUserId)
	table.clear(_lastActionAtByUserId)
	_clockFn = os.clock
	_initialized = false
	_started = false
end

return VehicleLaunchService


