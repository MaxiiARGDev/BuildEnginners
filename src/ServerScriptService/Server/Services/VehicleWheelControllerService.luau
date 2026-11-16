--!strict
--[=[
	VehicleWheelControllerService
	Orquestador centralizado por vehículo para el sistema de ruedas, suspensión y dirección (Fase 3.2):
	- Ejecuta un único loop RunService.Heartbeat centralizado (sin scripts por rueda).
	- Lee entrada autoritativa de dirección del asiento (VehicleSeat.SteerFloat cuando hay ocupante,
	  o override controlado en pruebas) y comanda los SteeringHinges Servo respetando SteeringSpeed y signos.
	- Mantiene rodamiento pasivo sin autopropulsión en Fase 3.2 (PassiveRollingFrictionTorque).
	- Expone el contrato limpio para tren motriz de Fase 3.3 (SetWheelDriveCommand / SetVehicleDriveCommands /
	  GetVehicleWheels / GetWheelState / ClearDriveCommands).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local WheelMechanismBuilder = require(ServerScriptService.Server.Services.WheelMechanismBuilder)

type BuiltWheelMechanism = WheelMechanismBuilder.BuiltWheelMechanism

type WheelControlEntry = {
	WheelId: string,
	Mechanism: BuiltWheelMechanism,
	DriveCommand: VehicleTypes.WheelDriveCommand?,
	CurrentTargetAngle: number,
	State: VehicleTypes.WheelRuntimeState,
}

type VehicleControlEntry = {
	UserId: number,
	Runtime: VehicleTypes.VehicleRuntime,
	DriverSeat: VehicleSeat,
	SteerTestOverride: number?,
	WheelsById: { [string]: WheelControlEntry },
	OrderedWheelIds: { string },
	RayParams: RaycastParams,
}

local VehicleWheelControllerService = {
	Name = "VehicleWheelControllerService",
}

local _vehiclesByUserId: { [number]: VehicleControlEntry } = {}
local _heartbeatConn: RBXScriptConnection? = nil
local _initialized = false
local _started = false

local function resolveUserId(playerOrUserId: { UserId: number } | number): number
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	end
	return playerOrUserId.UserId
end

local function cloneWheelState(st: VehicleTypes.WheelRuntimeState): VehicleTypes.WheelRuntimeState
	return {
		WheelId = st.WheelId,
		PieceInstanceId = st.PieceInstanceId,
		ItemId = st.ItemId,
		MountPieceId = st.MountPieceId,
		IsDriven = st.IsDriven,
		DriveDirection = st.DriveDirection,
		WheelRadius = st.WheelRadius,
		WheelWidth = st.WheelWidth,
		AngularVelocity = st.AngularVelocity,
		TargetAngularVelocity = st.TargetAngularVelocity,
		TorqueLimit = st.TorqueLimit,
		BrakeTorque = st.BrakeTorque,
		SteeringEnabled = st.SteeringEnabled,
		SteeringAngle = st.SteeringAngle,
		TargetSteeringAngle = st.TargetSteeringAngle,
		MaxSteeringAngle = st.MaxSteeringAngle,
		SteeringSpeed = st.SteeringSpeed,
		SuspensionEnabled = st.SuspensionEnabled,
		SuspensionLength = st.SuspensionLength,
		ContactState = st.ContactState,
		IsFunctional = st.IsFunctional,
		ResolvedConfig = st.ResolvedConfig,
	}
end

local function updateWheelContactState(entry: VehicleControlEntry, wEntry: WheelControlEntry)
	local mech = wEntry.Mechanism
	local wheelPart = mech.WheelPart
	if not wheelPart.Parent or not wheelPart:IsDescendantOf(Workspace) then
		wEntry.State.ContactState = false
		return
	end

	local refPart = if not entry.Runtime.DriverSeatDestroyed and entry.DriverSeat and entry.DriverSeat.Parent
		then entry.DriverSeat
		else entry.Runtime.PrimaryPart
	local downDir = if refPart and refPart.Parent then -refPart.CFrame.UpVector else Vector3.new(0, -1, 0)
	local result = Workspace:Raycast(wheelPart.Position, downDir * (mech.WheelRadius + 0.22), entry.RayParams)
	wEntry.State.ContactState = result ~= nil
end

local function stepSingleVehicle(entry: VehicleControlEntry, dt: number)
	local runtime = entry.Runtime
	local rootModel = runtime.RootModel
	local seat = entry.DriverSeat
	if not rootModel or not rootModel.Parent then
		return
	end

	local steerInput = 0
	if not runtime.DriverSeatDestroyed then
		if entry.SteerTestOverride ~= nil then
			steerInput = math.clamp(entry.SteerTestOverride, -1, 1)
		elseif seat and seat.Parent and seat.Occupant ~= nil and not seat.Disabled then
			steerInput = math.clamp(seat.SteerFloat, -1, 1)
		end
	end

	local W = GameConfig.Wheels
	local clampedDt = math.clamp(dt, 1 / 240, 0.25)

	for _, wid in ipairs(entry.OrderedWheelIds) do
		local wEntry = entry.WheelsById[wid]
		if not wEntry then
			continue
		end

		local mech = wEntry.Mechanism
		local resolved = mech.ResolvedConfig
		local partState = runtime.Parts[wid]
		local isFunctional = (partState == nil or (partState.IsFunctional and not partState.IsDetached))
			and mech.WheelPart.Parent ~= nil
			and mech.AxleHinge.Parent ~= nil
		wEntry.State.IsFunctional = isFunctional

		-- 1) Dirección Servo
		local steeringHinge = mech.SteeringHinge
		if steeringHinge and steeringHinge.Parent then
			if resolved.EffectiveSteeringEnabled and isFunctional then
				-- En Roblox (+Y Up): ángulo positivo gira izquierda, SteerFloat=+1 (D/derecha) -> ángulo negativo
				local desiredAngle = -steerInput * resolved.MaxSteeringAngle * resolved.SteeringDirectionMultiplier
				desiredAngle = math.clamp(desiredAngle, -W.MaxSteeringAngleDeg, W.MaxSteeringAngleDeg)

				local maxStep = resolved.SteeringSpeed * clampedDt
				local delta = desiredAngle - wEntry.CurrentTargetAngle
				if math.abs(delta) > maxStep then
					wEntry.CurrentTargetAngle += (if delta >= 0 then maxStep else -maxStep)
				else
					wEntry.CurrentTargetAngle = desiredAngle
				end

				steeringHinge.AngularSpeed = math.rad(resolved.SteeringSpeed)
				steeringHinge.TargetAngle = wEntry.CurrentTargetAngle
				wEntry.State.TargetSteeringAngle = wEntry.CurrentTargetAngle
				wEntry.State.SteeringAngle = steeringHinge.CurrentAngle
			else
				steeringHinge.TargetAngle = 0
				wEntry.CurrentTargetAngle = 0
				wEntry.State.TargetSteeringAngle = 0
				wEntry.State.SteeringAngle = steeringHinge.CurrentAngle
			end
		else
			wEntry.State.TargetSteeringAngle = 0
			wEntry.State.SteeringAngle = 0
		end

		-- 2) Suspensión
		if mech.Prismatic and mech.Prismatic.Parent then
			wEntry.State.SuspensionLength = mech.Prismatic.CurrentPosition
		else
			wEntry.State.SuspensionLength = 0
		end

		-- 3) Eje de giro (rodamiento pasivo en Fase 3.2 o torque motriz/freno en Fase 3.3+)
		local axleHinge = mech.AxleHinge
		if axleHinge and axleHinge.Parent then
			if not isFunctional then
				axleHinge.MotorMaxTorque = 0
				axleHinge.AngularVelocity = 0
				wEntry.State.TargetAngularVelocity = 0
				wEntry.State.TorqueLimit = 0
				wEntry.State.BrakeTorque = 0
			else
				local cmd = wEntry.DriveCommand
				local brakeTorque = if cmd and type(cmd.BrakeTorque) == "number" then math.max(0, cmd.BrakeTorque) else 0
				local torqueLimit = if cmd and type(cmd.TorqueLimit) == "number" then math.max(0, cmd.TorqueLimit) else 0
				local targetVel = if cmd and type(cmd.TargetAngularVelocity) == "number"
					then cmd.TargetAngularVelocity
					else 0

				if brakeTorque > 0 then
					axleHinge.AngularVelocity = 0
					axleHinge.MotorMaxTorque = brakeTorque
					wEntry.State.TargetAngularVelocity = 0
					wEntry.State.TorqueLimit = 0
					wEntry.State.BrakeTorque = brakeTorque
				elseif torqueLimit > 0 and resolved.IsDriven then
					local directedOmega = targetVel * resolved.DriveDirection
					axleHinge.AngularVelocity = directedOmega
					axleHinge.MotorMaxTorque = torqueLimit
					wEntry.State.TargetAngularVelocity = directedOmega
					wEntry.State.TorqueLimit = torqueLimit
					wEntry.State.BrakeTorque = 0
				else
					-- Sin motorización activa en Fase 3.2: solo fricción pasiva de rodamiento
					axleHinge.AngularVelocity = 0
					axleHinge.MotorMaxTorque = W.PassiveRollingFrictionTorque
					wEntry.State.TargetAngularVelocity = 0
					wEntry.State.TorqueLimit = 0
					wEntry.State.BrakeTorque = 0
				end
			end

			local att0 = axleHinge.Attachment0
			local axisWorld = if att0 then att0.WorldAxis else Vector3.new(-1, 0, 0)
			wEntry.State.AngularVelocity = mech.WheelPart.AssemblyAngularVelocity:Dot(axisWorld)
		end

		updateWheelContactState(entry, wEntry)
	end
end

function VehicleWheelControllerService.RegisterRuntime(runtime: VehicleTypes.VehicleRuntime)
	if not _initialized then
		VehicleWheelControllerService.Init()
	end

	local userId = runtime.OwnerUserId
	_vehiclesByUserId[userId] = nil

	local rootModel = runtime.RootModel
	local seat = runtime.DriverSeatPart
	if not rootModel or not seat then
		return
	end

	local mechsMap = (runtime.WheelMechanisms :: any) :: { [string]: BuiltWheelMechanism }?
	if not mechsMap or next(mechsMap) == nil then
		return
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { rootModel }

	local orderedIds: { string } = {}
	if runtime.WheelPieceIds then
		for _, wid in ipairs(runtime.WheelPieceIds) do
			if mechsMap[wid] then
				table.insert(orderedIds, wid)
			end
		end
	end
	for wid in pairs(mechsMap) do
		local found = false
		for _, existing in ipairs(orderedIds) do
			if existing == wid then
				found = true
				break
			end
		end
		if not found then
			table.insert(orderedIds, wid)
		end
	end

	local wheelsById: { [string]: WheelControlEntry } = {}
	for _, wid in ipairs(orderedIds) do
		local mech = mechsMap[wid]
		local resolved = mech.ResolvedConfig
		local initialState: VehicleTypes.WheelRuntimeState = {
			WheelId = wid,
			PieceInstanceId = mech.PieceInstanceId,
			ItemId = mech.ItemId,
			MountPieceId = mech.MountPieceId,
			IsDriven = resolved.IsDriven,
			DriveDirection = resolved.DriveDirection,
			WheelRadius = resolved.WheelRadius,
			WheelWidth = resolved.WheelWidth,
			AngularVelocity = 0,
			TargetAngularVelocity = 0,
			TorqueLimit = 0,
			BrakeTorque = 0,
			SteeringEnabled = resolved.EffectiveSteeringEnabled,
			SteeringAngle = 0,
			TargetSteeringAngle = 0,
			MaxSteeringAngle = resolved.MaxSteeringAngle,
			SteeringSpeed = resolved.SteeringSpeed,
			SuspensionEnabled = resolved.EffectiveSuspensionEnabled,
			SuspensionLength = if mech.Prismatic then mech.Prismatic.CurrentPosition else 0,
			ContactState = false,
			IsFunctional = true,
			ResolvedConfig = resolved,
		}
		wheelsById[wid] = {
			WheelId = wid,
			Mechanism = mech,
			DriveCommand = nil,
			CurrentTargetAngle = 0,
			State = initialState,
		}
	end

	local entry: VehicleControlEntry = {
		UserId = userId,
		Runtime = runtime,
		DriverSeat = seat,
		SteerTestOverride = nil,
		WheelsById = wheelsById,
		OrderedWheelIds = orderedIds,
		RayParams = rayParams,
	}
	_vehiclesByUserId[userId] = entry

	-- Paso inicial inmediato para fijar ángulos y fricción pasiva antes del primer frame
	stepSingleVehicle(entry, 1 / 60)
end

function VehicleWheelControllerService.DetachPiece(runtime, pieceId)
	local entry = _vehiclesByUserId[runtime.OwnerUserId]
	if entry and entry.Runtime == runtime then
		local wEntry = entry.WheelsById[pieceId]
		if wEntry then
			wEntry.DriveCommand = nil
			wEntry.State.IsFunctional = false
			wEntry.State.TargetAngularVelocity = 0
			wEntry.State.TorqueLimit = 0
			wEntry.State.BrakeTorque = 0
			wEntry.State.TargetSteeringAngle = 0
			local mech = wEntry.Mechanism
			if mech then
				if mech.AxleHinge and mech.AxleHinge.Parent then
					mech.AxleHinge.ActuatorType = Enum.ActuatorType.None
					mech.AxleHinge.MotorMaxTorque = 0
					mech.AxleHinge.AngularVelocity = 0
				end
				if mech.SteeringHinge and mech.SteeringHinge.Parent then
					mech.SteeringHinge.ActuatorType = Enum.ActuatorType.None
					mech.SteeringHinge.ServoMaxTorque = 0
					mech.SteeringHinge.TargetAngle = 0
				end
			end
		end
		entry.WheelsById[pieceId] = nil
		local index = table.find(entry.OrderedWheelIds, pieceId)
		if index then
			table.remove(entry.OrderedWheelIds, index)
		end
	end
	if runtime.WheelMechanisms then
		runtime.WheelMechanisms[pieceId] = nil
	end
	if runtime.WheelPieceIds then
		local index = table.find(runtime.WheelPieceIds, pieceId)
		if index then
			table.remove(runtime.WheelPieceIds, index)
		end
	end
end

function VehicleWheelControllerService.UnregisterRuntime(runtimeOrUserId: VehicleTypes.VehicleRuntime | { UserId: number } | number)
	if type(runtimeOrUserId) == "number" then
		_vehiclesByUserId[runtimeOrUserId] = nil
		return
	end
	local anyObj = runtimeOrUserId :: any
	local userId = anyObj.OwnerUserId or anyObj.UserId
	if type(userId) == "number" then
		local entry = _vehiclesByUserId[userId]
		if entry then
			if anyObj.RuntimeId == nil or entry.Runtime.RuntimeId == anyObj.RuntimeId then
				_vehiclesByUserId[userId] = nil
			end
		end
	end
end

function VehicleWheelControllerService.SetSteerOverrideForTests(
	playerOrUserId: { UserId: number } | number,
	steerValue: number?
)
	local userId = resolveUserId(playerOrUserId)
	local entry = _vehiclesByUserId[userId]
	if not entry then
		return
	end
	entry.SteerTestOverride = if steerValue ~= nil then math.clamp(steerValue, -1, 1) else nil
end

function VehicleWheelControllerService.SetWheelDriveCommand(
	playerOrUserId: { UserId: number } | number,
	wheelId: string,
	command: VehicleTypes.WheelDriveCommand
): boolean
	local userId = resolveUserId(playerOrUserId)
	local entry = _vehiclesByUserId[userId]
	if not entry then
		return false
	end
	local wEntry = entry.WheelsById[wheelId]
	if not wEntry then
		return false
	end
	wEntry.DriveCommand = {
		TargetAngularVelocity = command.TargetAngularVelocity,
		TorqueLimit = command.TorqueLimit,
		BrakeTorque = command.BrakeTorque,
	}
	stepSingleVehicle(entry, 1 / 60)
	return true
end

function VehicleWheelControllerService.SetVehicleDriveCommands(
	playerOrUserId: { UserId: number } | number,
	commands: { [string]: VehicleTypes.WheelDriveCommand } | VehicleTypes.WheelDriveCommand
): boolean
	local userId = resolveUserId(playerOrUserId)
	local entry = _vehiclesByUserId[userId]
	if not entry then
		return false
	end

	local anyCmd = commands :: any
	local isSingleCommand = anyCmd.TargetAngularVelocity ~= nil
		or anyCmd.TorqueLimit ~= nil
		or anyCmd.BrakeTorque ~= nil
		or next(anyCmd) == nil

	if isSingleCommand then
		local sharedCmd = commands :: VehicleTypes.WheelDriveCommand
		for _, wid in ipairs(entry.OrderedWheelIds) do
			local wEntry = entry.WheelsById[wid]
			if wEntry then
				wEntry.DriveCommand = {
					TargetAngularVelocity = sharedCmd.TargetAngularVelocity,
					TorqueLimit = sharedCmd.TorqueLimit,
					BrakeTorque = sharedCmd.BrakeTorque,
				}
			end
		end
	else
		local byId = commands :: { [string]: VehicleTypes.WheelDriveCommand }
		for wid, wEntry in pairs(entry.WheelsById) do
			local cmd = byId[wid]
			if cmd then
				wEntry.DriveCommand = {
					TargetAngularVelocity = cmd.TargetAngularVelocity,
					TorqueLimit = cmd.TorqueLimit,
					BrakeTorque = cmd.BrakeTorque,
				}
			else
				wEntry.DriveCommand = nil
			end
		end
	end

	stepSingleVehicle(entry, 1 / 60)
	return true
end

function VehicleWheelControllerService.ClearDriveCommands(playerOrUserId: { UserId: number } | number): boolean
	local userId = resolveUserId(playerOrUserId)
	local entry = _vehiclesByUserId[userId]
	if not entry then
		return false
	end
	if entry.Runtime.DriverSeatDestroyed then
		entry.SteerTestOverride = nil
	end
	for _, wEntry in pairs(entry.WheelsById) do
		wEntry.DriveCommand = nil
	end
	stepSingleVehicle(entry, 1 / 60)
	return true
end

function VehicleWheelControllerService.GetVehicleWheels(
	playerOrUserId: { UserId: number } | number
): { VehicleTypes.WheelRuntimeState }
	local userId = resolveUserId(playerOrUserId)
	local entry = _vehiclesByUserId[userId]
	if not entry then
		return {}
	end
	local out: { VehicleTypes.WheelRuntimeState } = table.create(#entry.OrderedWheelIds)
	for _, wid in ipairs(entry.OrderedWheelIds) do
		local wEntry = entry.WheelsById[wid]
		if wEntry then
			updateWheelContactState(entry, wEntry)
			table.insert(out, cloneWheelState(wEntry.State))
		end
	end
	return out
end

function VehicleWheelControllerService.GetWheelState(
	playerOrUserId: { UserId: number } | number,
	wheelId: string
): VehicleTypes.WheelRuntimeState?
	local userId = resolveUserId(playerOrUserId)
	local entry = _vehiclesByUserId[userId]
	if not entry then
		return nil
	end
	local wEntry = entry.WheelsById[wheelId]
	if not wEntry then
		return nil
	end
	updateWheelContactState(entry, wEntry)
	return cloneWheelState(wEntry.State)
end

function VehicleWheelControllerService.GetRegisteredVehicleCount(): number
	local count = 0
	for _ in pairs(_vehiclesByUserId) do
		count += 1
	end
	return count
end

function VehicleWheelControllerService.StepAll(dt: number)
	local staleUserIds: { number }? = nil
	for userId, entry in pairs(_vehiclesByUserId) do
		local rt = entry.Runtime
		if not rt.RootModel or not rt.RootModel.Parent then
			if not staleUserIds then
				staleUserIds = {}
			end
			table.insert(staleUserIds :: { number }, userId)
		else
			stepSingleVehicle(entry, dt)
		end
	end
	if staleUserIds then
		for _, uid in ipairs(staleUserIds) do
			_vehiclesByUserId[uid] = nil
		end
	end
end

function VehicleWheelControllerService.Init()
	if _initialized then
		return
	end
	_initialized = true
end

function VehicleWheelControllerService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehicleWheelControllerService.Init()
	end
	_heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
		VehicleWheelControllerService.StepAll(dt)
	end)
	_started = true
end

function VehicleWheelControllerService._ResetForTests()
	if _heartbeatConn then
		_heartbeatConn:Disconnect()
		_heartbeatConn = nil
	end
	table.clear(_vehiclesByUserId)
	_initialized = false
	_started = false
end

return VehicleWheelControllerService


