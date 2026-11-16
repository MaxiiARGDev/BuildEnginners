--!strict
--[=[
	VehicleLaunchController
	Controlador cliente para el flujo de lanzamiento, retorno al taller, reinicio y salida del asiento (Fase 3.1).
	- Invoca acciones autoritativas sobre `BuildOperationRequest`.
	- Protege contra envíos concurrentes y timeouts de red sin alterar el Blueprint.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)

local BuildState = require(script.Parent.BuildState)
local BuildPlacementController = require(script.Parent.BuildPlacementController)

export type InvokeHandler = BuildPlacementController.InvokeHandler

local VehicleLaunchController = {}

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

local function makeOpId(prefix: string): string
	_opSeq += 1
	local localPlayer = Players.LocalPlayer
	local userId = if localPlayer then localPlayer.UserId else (BuildState.ExpectedOwnerUserId or 0)
	return `{prefix}_{userId}_{_opSeq}`
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

function VehicleLaunchController.RefreshRuntimeState(customInvoke: InvokeHandler?): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		return false, nil
	end

	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.GetRuntimeState,
		ClientOpId = makeOpId("rtstate"),
	}, _operationTimeoutSeconds)

	if not timedOut and ok and type(res) == "table" then
		local response = res :: BuildProtocol.BuildOperationResponse
		if response.Success and response.RuntimeStatus then
			BuildState.SetRuntimeStatus(response.RuntimeStatus)
			return true, response
		end
		return false, response
	end

	return false, nil
end

local function runRuntimeAction(
	actionName: string,
	optimisticState: string?,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	if _inFlight then
		return false, nil
	end

	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetRuntimeActionInFlight(false, "Servidor no disponible")
		return false, nil
	end

	_inFlight = true
	if optimisticState then
		BuildState.SetRuntimeActionInFlight(true, nil, optimisticState :: any)
	else
		BuildState.SetRuntimeActionInFlight(true, nil)
	end

	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = actionName,
		ClientOpId = makeOpId(string.lower(actionName)),
	}, _operationTimeoutSeconds + GameConfig.Runtime.SeatMountTimeoutSeconds)

	_inFlight = false

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetRuntimeActionInFlight(false, "Tiempo de espera agotado o error de red")
		VehicleLaunchController.RefreshRuntimeState(customInvoke)
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.LaunchPrepReport then
		BuildState.SetLaunchPrepReport(response.LaunchPrepReport)
	end
	if response.RuntimeStatus then
		BuildState.SetRuntimeStatus(response.RuntimeStatus)
	end

	if response.Success then
		BuildState.SetRuntimeActionInFlight(false, nil)
		if response.ExitDestination then
			local exitDestination = response.ExitDestination
			local localPlayer = Players.LocalPlayer
			local function applyExitPose()
				local character = if localPlayer then localPlayer.Character else nil
				if not character or not character.Parent then
					return
				end
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.Jump = false
					humanoid.Sit = false
					humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
					humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
				end
				local root = character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					root.AssemblyLinearVelocity = Vector3.zero
					root.AssemblyAngularVelocity = Vector3.zero
				end
				character:PivotTo(exitDestination)
			end
			applyExitPose()
			task.defer(function()
				local character = if localPlayer then localPlayer.Character else nil
				local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
				if root and root:IsA("BasePart") and (root.Position - exitDestination.Position).Magnitude > 1.0 then
					applyExitPose()
				end
			end)
		end
		return true, response
	end

	local errMsg = response.ErrorMessage or response.ErrorCode or "Error de lanzamiento"
	BuildState.SetRuntimeActionInFlight(false, errMsg)
	return false, response
end

function VehicleLaunchController.LaunchVehicle(customInvoke: InvokeHandler?): (boolean, BuildProtocol.BuildOperationResponse?)
	return runRuntimeAction(
		BuildProtocol.Actions.LaunchVehicle,
		GameConfig.Runtime.States.PreparingLaunch,
		customInvoke
	)
end

function VehicleLaunchController.ReturnToWorkshop(customInvoke: InvokeHandler?): (boolean, BuildProtocol.BuildOperationResponse?)
	return runRuntimeAction(
		BuildProtocol.Actions.ReturnToWorkshop,
		GameConfig.Runtime.States.ReturningToWorkshop,
		customInvoke
	)
end

function VehicleLaunchController.ResetVehicle(customInvoke: InvokeHandler?): (boolean, BuildProtocol.BuildOperationResponse?)
	return runRuntimeAction(
		BuildProtocol.Actions.ResetVehicle,
		GameConfig.Runtime.States.PreparingLaunch,
		customInvoke
	)
end

function VehicleLaunchController.ExitVehicleSeat(customInvoke: InvokeHandler?): (boolean, BuildProtocol.BuildOperationResponse?)
	return runRuntimeAction(
		BuildProtocol.Actions.ExitVehicleSeat,
		nil,
		customInvoke
	)
end

function VehicleLaunchController.IsBusy(): boolean
	return _inFlight
end

return VehicleLaunchController

