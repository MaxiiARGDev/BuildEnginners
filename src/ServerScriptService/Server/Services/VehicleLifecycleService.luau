--!strict
--[=[
	VehicleLifecycleService
	Máquina de estados autoritativa y ciclo de vida de sesión de vehículo por jugador (Fase 3.1):
	  Editing -> PreparingLaunch -> Launching -> Driving <-> OnFootRuntime -> ReturningToWorkshop -> Editing
	- Bloquea acciones de edición/cambio de blueprint fuera de `Editing`.
	- Controla el montaje seguro en `DriverSeat:Sit(humanoid)` sin condiciones de carrera.
	- Administra salida/reingreso de asiento, retorno al taller, muerte/respawn, desconexión y limpieza de abandonos.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local PlotService = require(ServerScriptService.Server.Services.PlotService)
local SpawnService = require(ServerScriptService.Server.Services.SpawnService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local VehicleRuntimeService = require(ServerScriptService.Server.Services.VehicleRuntimeService)

export type StateChangedListener = (
	playerOrUserId: PlotService.PlayerLike | number,
	snapshot: VehicleTypes.RuntimeStatusSnapshot
) -> ()

export type SeatMountOptions = {
	MountDriver: boolean?,
	SkipSeatRetryYield: boolean?,
	SimulateSeated: boolean?,
}

local VehicleSeatService = require(script.Parent.VehicleSeatService)

local States = GameConfig.Runtime.States

local VehicleLifecycleService = {
	Name = "VehicleLifecycleService",
}

local _statesByUserId: { [number]: VehicleTypes.VehicleState } = {}
local _playerRefsByUserId: { [number]: PlotService.PlayerLike } = {}
local _lastErrorByUserId: { [number]: { Code: string, Message: string } } = {}
local _playerConnsByUserId: { [number]: { RBXScriptConnection } } = {}
local _serviceConnections: { RBXScriptConnection } = {}
local _unsubSeat: (() -> ())? = nil
local _unsubInvalidated: (() -> ())? = nil
local _unsubPlotReleased: (() -> ())? = nil
local _unsubBeforeRespawn: (() -> ())? = nil
local _stateListeners: { StateChangedListener } = {}

local _clockFn: () -> number = os.clock
local _lastAbandonedScanAt = 0
local _initialized = false
local _started = false

local function nowSeconds(): number
	return _clockFn()
end

local function isRealPlayer(player: PlotService.PlayerLike): boolean
	return typeof(player) == "Instance" and (player :: Instance):IsA("Player")
end

local function clearSeatWeld(seat: VehicleSeat?, resetHumanoidCooldown: Humanoid?)
	if not seat then
		return
	end
	local prevOcc = resetHumanoidCooldown or seat.Occupant
	for _, child in ipairs(seat:GetChildren()) do
		if child.Name == "SeatWeld" and child:IsA("JointInstance") then
			child:Destroy()
		end
	end
	if prevOcc and prevOcc.Parent then
		prevOcc.Sit = false
		local tmpSeat = Instance.new("Seat")
		tmpSeat.Parent = seat.Parent or Workspace
		pcall(function()
			tmpSeat:Sit(prevOcc)
		end)
		prevOcc.Sit = false
		tmpSeat:Destroy()
	end
end

local function isPlayerAliveAndConnected(player: PlotService.PlayerLike): (boolean, string?, string?)
	if isRealPlayer(player) then
		local realPlr = player :: Player
		if not realPlr.Parent or realPlr.Parent ~= Players then
			return false, "PlayerDisconnected", "El jugador se desconectó"
		end
		local char = realPlr.Character
		if not char or not char.Parent then
			return false, "CharacterNotReady", "El personaje del jugador no está listo"
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then
			return false, "PlayerDead", "El personaje está muerto"
		end
		return true, nil, nil
	end

	-- Tabla simulada en pruebas unitarias
	local anyTbl = player :: any
	if anyTbl.IsDisconnected then
		return false, "PlayerDisconnected", "El jugador simulado está desconectado"
	end
	if anyTbl.Character then
		local hum = (anyTbl.Character :: Instance):FindFirstChildOfClass("Humanoid")
		if hum and hum.Health <= 0 then
			return false, "PlayerDead", "El personaje simulado está muerto"
		end
	end
	return true, nil, nil
end

local function resolveCharacterAndHumanoid(player: PlotService.PlayerLike): (Model?, Humanoid?)
	if isRealPlayer(player) then
		local realPlr = player :: Player
		local char = realPlr.Character
		local hum = if char then char:FindFirstChildOfClass("Humanoid") else nil
		return char, hum
	end
	local anyTbl = player :: any
	if typeof(anyTbl.Character) == "Instance" and (anyTbl.Character :: Instance):IsA("Model") then
		local char = anyTbl.Character :: Model
		return char, char:FindFirstChildOfClass("Humanoid")
	end
	return nil, nil
end

local function buildSnapshotForUserId(userId: number): VehicleTypes.RuntimeStatusSnapshot
	local state = _statesByUserId[userId] or (States.Editing :: VehicleTypes.VehicleState)
	local runtime = VehicleRuntimeService.GetRuntimeByPlayer(userId)
	local err = _lastErrorByUserId[userId]
	local pieceCount = 0
	if runtime then
		for _ in pairs(runtime.Parts) do
			pieceCount += 1
		end
	end
	local seatOcc = if runtime and runtime.DriverSeatPart then runtime.DriverSeatPart.Occupant else nil

	return {
		State = state,
		RuntimeId = if runtime then runtime.RuntimeId else nil,
		PlotId = if runtime then runtime.PlotId else nil,
		SourceBlueprintId = if runtime then runtime.SourceBlueprintId else nil,
		SourceBlueprintRevision = if runtime then runtime.SourceBlueprintRevision else nil,
		DriverSeated = seatOcc ~= nil or (state == States.Driving and runtime ~= nil),
		PieceCount = pieceCount,
		JointCount = if runtime and runtime.Joints then #runtime.Joints else 0,
		AbandonedSince = if runtime then runtime.AbandonedSince else nil,
		ErrorCode = if err then err.Code else nil,
		ErrorMessage = if err then err.Message else nil,
	}
end

local function emitStateChanged(userId: number)
	local snap = buildSnapshotForUserId(userId)
	local ref: PlotService.PlayerLike | number = _playerRefsByUserId[userId] or userId
	for _, fn in ipairs(table.clone(_stateListeners)) do
		fn(ref, snap)
	end
end

local _suppressRestoreEditableOnEditingByUserId: { [number]: boolean } = {}

local function setStateInternal(userId: number, newState: VehicleTypes.VehicleState, abandonedSince: number?, clearError: boolean?)
	_statesByUserId[userId] = newState
	if clearError ~= false then
		_lastErrorByUserId[userId] = nil
	end
	if
		newState == GameConfig.Runtime.States.Driving
		or newState == GameConfig.Runtime.States.OnFootRuntime
	then
		VehicleBlueprintService.SetEditableVehicleVisible(userId, false, `State:{newState}`)
	elseif newState == GameConfig.Runtime.States.Editing then
		if _suppressRestoreEditableOnEditingByUserId[userId] then
			_suppressRestoreEditableOnEditingByUserId[userId] = nil
		else
			VehicleBlueprintService.SetEditableVehicleVisible(userId, true, "ReturnedToEditing")
		end
	end
	if VehicleRuntimeService.GetRuntimeByPlayer(userId) then
		VehicleRuntimeService.SetRuntimeState(userId, newState, abandonedSince)
	end
	emitStateChanged(userId)
end

local function disconnectPlayerSignals(userId: number)
	local conns = _playerConnsByUserId[userId]
	if conns then
		for _, conn in ipairs(conns) do
			if conn.Connected then
				conn:Disconnect()
			end
		end
		_playerConnsByUserId[userId] = nil
	end
end

local function bindRealCharacterDeath(player: Player, character: Model, conns: { RBXScriptConnection })
	local hum = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 3)
	if hum and hum:IsA("Humanoid") then
		table.insert(
			conns,
			hum.Died:Connect(function()
				local uid = player.UserId
				local currentState = _statesByUserId[uid]
				if currentState == States.PreparingLaunch or currentState == States.Launching then
					VehicleLifecycleService.RollbackLaunch(player, "PlayerDead", "Lanzamiento cancelado por muerte del jugador")
				elseif VehicleRuntimeService.GetRuntimeByPlayer(uid) then
					if GameConfig.Runtime.DestroyVehicleOnDeath then
						VehicleLifecycleService.ReturnToWorkshop(player, "PlayerDied")
					elseif currentState == States.Driving then
						setStateInternal(uid, States.OnFootRuntime :: VehicleTypes.VehicleState, nowSeconds(), true)
					end
				end
			end)
		)
	end
end

local function ensurePlayerBound(player: PlotService.PlayerLike)
	_playerRefsByUserId[player.UserId] = player
	if not isRealPlayer(player) then
		return
	end
	local realPlr = player :: Player
	if _playerConnsByUserId[realPlr.UserId] then
		return
	end

	local conns: { RBXScriptConnection } = {}
	_playerConnsByUserId[realPlr.UserId] = conns

	table.insert(
		conns,
		realPlr.CharacterAdded:Connect(function(char)
			if _playerConnsByUserId[realPlr.UserId] ~= conns then
				return
			end
			bindRealCharacterDeath(realPlr, char, conns)
		end)
	)

	if realPlr.Character then
		bindRealCharacterDeath(realPlr, realPlr.Character, conns)
	end
end

local function moveCharacterOutsideSeat(character: Model, seat: VehicleSeat)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end
	if not seat.Parent then
		return
	end

	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	local sideOffset = Vector3.new(
		GameConfig.Runtime.ExitSeatLateralOffsetStuds,
		GameConfig.Runtime.ExitSeatUpOffsetStuds,
		0
	)
	local targetCF = seat.CFrame * CFrame.new(sideOffset)
	character:PivotTo(targetCF)
end

function VehicleLifecycleService.GetPlayerState(playerOrUserId: PlotService.PlayerLike | number): VehicleTypes.VehicleState
	local userId = if type(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	if _statesByUserId[userId] == States.Driving or _statesByUserId[userId] == States.OnFootRuntime then
		VehicleRuntimeService.GetRuntimeByPlayer(userId)
	end
	return _statesByUserId[userId] or (States.Editing :: VehicleTypes.VehicleState)
end

function VehicleLifecycleService.CanEditBlueprint(playerOrUserId: PlotService.PlayerLike | number): boolean
	return VehicleLifecycleService.GetPlayerState(playerOrUserId) == States.Editing
end

function VehicleLifecycleService.GetRuntimeStatusSnapshot(playerOrUserId: PlotService.PlayerLike | number): VehicleTypes.RuntimeStatusSnapshot
	local userId = if type(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	return buildSnapshotForUserId(userId)
end

function VehicleLifecycleService.BeginLaunchPreparation(player: PlotService.PlayerLike): (boolean, string?, string?)
	if not _initialized then
		VehicleLifecycleService.Init()
	end
	ensurePlayerBound(player)
	local userId = player.UserId
	local state = VehicleLifecycleService.GetPlayerState(userId)

	if state == States.PreparingLaunch or state == States.Launching then
		return false, "LaunchInProgress", "Ya hay un lanzamiento en curso"
	end
	if state == States.ReturningToWorkshop then
		return false, "OperationInProgress", "Regreso al taller en curso"
	end
	if state ~= States.Editing or VehicleRuntimeService.GetRuntimeByPlayer(userId) ~= nil then
		return false, "RuntimeAlreadyActive", "Ya tenés un vehículo activo; regresá al taller o reinicialo"
	end

	local aliveOk, errCode, errMsg = isPlayerAliveAndConnected(player)
	if not aliveOk then
		return false, errCode, errMsg
	end

	if not VehicleRuntimeService.ReserveSlot(userId) then
		return false, "LaunchInProgress", "Slot de lanzamiento ocupado"
	end

	setStateInternal(userId, States.PreparingLaunch :: VehicleTypes.VehicleState, nil, true)
	return true, nil, nil
end

function VehicleLifecycleService.TransitionToLaunching(player: PlotService.PlayerLike): boolean
	local userId = player.UserId
	if VehicleLifecycleService.GetPlayerState(userId) ~= States.PreparingLaunch then
		return false
	end
	setStateInternal(userId, States.Launching :: VehicleTypes.VehicleState, nil, true)
	return true
end

function VehicleLifecycleService.RollbackLaunch(player: PlotService.PlayerLike, errCode: string?, errMsg: string?)
	local userId = player.UserId
	VehicleRuntimeService.ReleaseSlot(userId)
	VehicleRuntimeService.DestroyRuntimeForPlayer(userId, errCode or "LaunchRollback")
	if errCode then
		_lastErrorByUserId[userId] = {
			Code = errCode,
			Message = errMsg or errCode,
		}
	else
		_lastErrorByUserId[userId] = nil
	end
	setStateInternal(userId, States.Editing :: VehicleTypes.VehicleState, nil, errCode == nil)
end

function VehicleLifecycleService.CompleteLaunchWithSeatMount(
	player: PlotService.PlayerLike,
	runtime: VehicleTypes.VehicleRuntime,
	options: SeatMountOptions?
): (boolean, string?, string?)
	local userId = player.UserId
	local character, humanoid = resolveCharacterAndHumanoid(player)

	if options and options.MountDriver == false then
		if options.SimulateSeated and not isRealPlayer(player) and not humanoid then
			setStateInternal(userId, States.Driving :: VehicleTypes.VehicleState, nil, true)
		else
			setStateInternal(userId, States.OnFootRuntime :: VehicleTypes.VehicleState, nowSeconds(), true)
		end
		return true, nil, nil
	end

	if not humanoid or not character then
		if isRealPlayer(player) then
			VehicleLifecycleService.RollbackLaunch(player, "CharacterNotReady", "Personaje no disponible para sentar al conductor")
			return false, "CharacterNotReady", "Personaje no disponible para sentar al conductor"
		end

		-- Mock de prueba sin personaje físico
		if options and options.SimulateSeated then
			setStateInternal(userId, States.Driving :: VehicleTypes.VehicleState, nil, true)
		else
			setStateInternal(userId, States.OnFootRuntime :: VehicleTypes.VehicleState, nowSeconds(), true)
		end
		return true, nil, nil
	end

	local seat = runtime.DriverSeatPart
	if not seat or not seat.Parent then
		VehicleLifecycleService.RollbackLaunch(player, "DriverSeatMountFailed", "DriverSeat no disponible")
		return false, "DriverSeatMountFailed", "DriverSeat no disponible"
	end

	if humanoid.Sit then
		humanoid.Sit = false
		if not (options and options.SkipSeatRetryYield) then
			task.wait(GameConfig.Runtime.SeatCooldownWaitSeconds)
		end
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end

	seat.Disabled = false
	local timeoutAt = os.clock() + GameConfig.Runtime.SeatMountTimeoutSeconds

	while true do
		-- Abortar de inmediato si cambió el jugador, murió o el runtime fue cancelado
		local aliveOk, errCode, errMsg = isPlayerAliveAndConnected(player)
		if not aliveOk then
			VehicleLifecycleService.RollbackLaunch(player, errCode or "PlayerDead", errMsg or "Lanzamiento interrumpido")
			return false, errCode or "PlayerDead", errMsg
		end

		if VehicleRuntimeService.GetRuntimeByPlayer(userId) ~= runtime or not seat.Parent then
			VehicleLifecycleService.RollbackLaunch(player, "DriverSeatMountFailed", "Vehículo invalidado durante el montaje")
			return false, "DriverSeatMountFailed", "Vehículo invalidado durante el montaje"
		end

		if seat.Occupant == humanoid then
			setStateInternal(userId, States.Driving :: VehicleTypes.VehicleState, nil, true)
			return true, nil, nil
		end

		pcall(function()
			seat:Sit(humanoid)
		end)

		if seat.Occupant == humanoid then
			if not (options and options.SkipSeatRetryYield) and RunService:IsRunning() then
				-- Esperar un paso de física para asentar SeatWeld y Humanoid.SeatPart en el motor
				RunService.Heartbeat:Wait()
			end
			if seat.Occupant == humanoid then
				setStateInternal(userId, States.Driving :: VehicleTypes.VehicleState, nil, true)
				return true, nil, nil
			end
		end

		if (options and options.SkipSeatRetryYield) or os.clock() >= timeoutAt then
			break
		end

		if RunService:IsRunning() then
			RunService.Heartbeat:Wait()
		else
			task.wait(GameConfig.Runtime.SeatMountRetryIntervalSeconds)
		end
	end

	VehicleLifecycleService.RollbackLaunch(player, "DriverSeatMountFailed", "No se pudo sentar al jugador en DriverSeat")
	return false, "DriverSeatMountFailed", "No se pudo sentar al jugador en DriverSeat"
end

function VehicleLifecycleService.ExitVehicleSeat(player: PlotService.PlayerLike): (boolean, string?, string?, CFrame?)
	local _, humanoid = resolveCharacterAndHumanoid(player)
	if not humanoid then
		if not isRealPlayer(player) then
			local ownedRuntime = VehicleRuntimeService.GetRuntimeByPlayer(player.UserId)
			if ownedRuntime and ownedRuntime.State == States.Driving then
				setStateInternal(player.UserId, States.OnFootRuntime :: VehicleTypes.VehicleState, nowSeconds(), true)
				return true, nil, nil, nil
			end
		end
		return false, "NotSeatedDriver", "No ocupás un asiento de vehículo", nil
	end
	local runtime = VehicleSeatService.GetRuntimeForHumanoid(humanoid)
	if not runtime then
		return false, "NotSeatedDriver", "No ocupás un asiento de vehículo", nil
	end
	local ok, reason, exitDestination = VehicleSeatService.ExitHumanoid(humanoid, false)
	if not ok then
		return false, reason, "No hay una posición libre y segura para salir", nil
	end
	if runtime.OwnerUserId == player.UserId and runtime.State == States.Driving then
		setStateInternal(player.UserId, States.OnFootRuntime :: VehicleTypes.VehicleState, nowSeconds(), true)
	end
	return true, nil, nil, exitDestination
end

function VehicleLifecycleService.ReturnToWorkshop(
	player: PlotService.PlayerLike,
	reason: string?,
	teleportCharacterToSpawn: boolean?,
	restoreEditableVisibility: boolean?
): (boolean, string?, string?)
	local userId = player.UserId
	local state = VehicleLifecycleService.GetPlayerState(userId)
	local runtime = VehicleRuntimeService.GetRuntimeByPlayer(userId)

	if state == States.ReturningToWorkshop then
		return false, "OperationInProgress", "Regreso al taller ya está en curso"
	end

	if not runtime and state == States.Editing then
		if restoreEditableVisibility ~= false then
			_suppressRestoreEditableOnEditingByUserId[userId] = nil
			VehicleBlueprintService.SetEditableVehicleVisible(userId, true, reason or "ReturnToWorkshopIdle")
		end
		return true, nil, nil
	end

	setStateInternal(userId, States.ReturningToWorkshop :: VehicleTypes.VehicleState, nil, true)

	local character, humanoid = resolveCharacterAndHumanoid(player)
	local wasSeated = humanoid ~= nil and (humanoid.Sit or humanoid.SeatPart ~= nil)
	clearSeatWeld(if runtime then runtime.DriverSeatPart else nil)
	if humanoid and humanoid.Sit then
		humanoid.Sit = false
	end

	VehicleRuntimeService.DestroyRuntimeForPlayer(userId, reason or "ReturnToWorkshop")

	if teleportCharacterToSpawn ~= false then
		local plot = PlotService.GetPlotByPlayer(player)
		if plot and character and character.Parent then
			if isRealPlayer(player) and wasSeated and RunService:IsRunning() then
				for _ = 1, 2 do
					RunService.Heartbeat:Wait()
				end
			end
			if character.Parent and plot.PlayerSpawn.Parent then
				SpawnService.PositionCharacter(character, plot.PlayerSpawn)
			end
		end
	end

	if restoreEditableVisibility == false then
		_suppressRestoreEditableOnEditingByUserId[userId] = true
	else
		_suppressRestoreEditableOnEditingByUserId[userId] = nil
	end

	setStateInternal(userId, States.Editing :: VehicleTypes.VehicleState, nil, true)
	return true, nil, nil
end

function VehicleLifecycleService.CheckAbandonedVehicles(currentClock: number?): number
	local now = currentClock or nowSeconds()
	local cleaned = 0
	for _, runtime in ipairs(VehicleRuntimeService.GetAllActiveRuntimes()) do
		if
			runtime.State == States.OnFootRuntime
			and runtime.AbandonedSince ~= nil
			and (now - runtime.AbandonedSince) >= GameConfig.Runtime.AbandonedTimeoutSeconds
		then
			local plrRef = _playerRefsByUserId[runtime.OwnerUserId]
				or ({ UserId = runtime.OwnerUserId, Name = `Player_{runtime.OwnerUserId}` } :: PlotService.PlayerLike)
			VehicleLifecycleService.ReturnToWorkshop(plrRef, "AbandonedTimeout", false)
			cleaned += 1
		end
	end
	return cleaned
end

function VehicleLifecycleService.ClearPlayer(playerOrUserId: PlotService.PlayerLike | number)
	local userId = if type(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	_suppressRestoreEditableOnEditingByUserId[userId] = nil
	VehicleBlueprintService.SetEditableVehicleVisible(userId, true, "PlayerCleared")
	disconnectPlayerSignals(userId)
	VehicleRuntimeService.DestroyRuntimeForPlayer(userId, "PlayerCleared")
	_statesByUserId[userId] = nil
	_lastErrorByUserId[userId] = nil
	_playerRefsByUserId[userId] = nil
end

function VehicleLifecycleService.OnStateChanged(listener: StateChangedListener): () -> ()
	table.insert(_stateListeners, listener)
	return function()
		local idx = table.find(_stateListeners, listener)
		if idx then
			table.remove(_stateListeners, idx)
		end
	end
end

function VehicleLifecycleService._SetClockForTests(clockFn: (() -> number)?)
	_clockFn = clockFn or os.clock
end

function VehicleLifecycleService.Init()
	if _initialized then
		return
	end

	VehicleBlueprintService.Init()
	VehicleRuntimeService.Init()

	if not _unsubSeat then
		_unsubSeat = VehicleRuntimeService.OnSeatOccupancyChanged(function(runtime, occupant)
			local ownerId = runtime.OwnerUserId
			local currentState = _statesByUserId[ownerId]
			if currentState ~= States.Driving and currentState ~= States.OnFootRuntime then
				return
			end

			local ownerRef = _playerRefsByUserId[ownerId]
			if occupant then
				local ownerChar = if ownerRef then select(1, resolveCharacterAndHumanoid(ownerRef)) else nil
				local isOwnerHumanoid = ownerChar ~= nil and occupant.Parent == ownerChar
				if not isOwnerHumanoid then
					-- Seguridad multijugador: expulsar inmediatamente a otros jugadores del asiento
					local ejectedSeat = runtime.DriverSeatPart
					if ejectedSeat then
						VehicleSeatService.ForceEjectSeatOccupant(ejectedSeat, occupant)
						task.defer(function()
							if ejectedSeat.Parent and ejectedSeat.Occupant == occupant then
								VehicleSeatService.ForceEjectSeatOccupant(ejectedSeat, occupant)
							end
						end)
					else
						occupant.Sit = false
					end
					return
				end
				if currentState ~= States.Driving then
					setStateInternal(ownerId, States.Driving :: VehicleTypes.VehicleState, nil, true)
				end
			else
				if currentState == States.Driving then
					setStateInternal(ownerId, States.OnFootRuntime :: VehicleTypes.VehicleState, nowSeconds(), true)
				end
			end
		end)
	end

	if not _unsubInvalidated then
		_unsubInvalidated = VehicleRuntimeService.OnRuntimeInvalidated(function(runtime, reason)
			local ownerId = runtime.OwnerUserId
			local currentState = _statesByUserId[ownerId]
			if currentState and currentState ~= States.Editing and currentState ~= States.ReturningToWorkshop then
				local ownerRef = _playerRefsByUserId[ownerId]
				if ownerRef then
					local char, hum = resolveCharacterAndHumanoid(ownerRef)
					local plot = PlotService.GetPlotByPlayer(ownerRef)
					if char and char.Parent and plot then
						local wasSeated = hum ~= nil and (hum.Sit or hum.SeatPart ~= nil)
						if hum and hum.Sit then
							hum.Sit = false
						end
						SpawnService.PositionCharacter(char, plot.PlayerSpawn)
						if isRealPlayer(ownerRef) and wasSeated and RunService:IsRunning() then
							task.spawn(function()
								for _ = 1, 2 do
									RunService.Heartbeat:Wait()
								end
								if char.Parent and plot.PlayerSpawn.Parent then
									SpawnService.PositionCharacter(char, plot.PlayerSpawn)
								end
							end)
						end
					end
				end
				_lastErrorByUserId[ownerId] = {
					Code = reason,
					Message = "Vehículo retirado al taller por invalidación física",
				}
				setStateInternal(ownerId, States.Editing :: VehicleTypes.VehicleState, nil, false)
			end
		end)
	end

	if not _unsubPlotReleased then
		_unsubPlotReleased = PlotService.OnPlotReleased(function(playerLike)
			VehicleLifecycleService.ClearPlayer(playerLike)
		end)
	end

	if not _unsubBeforeRespawn then
		_unsubBeforeRespawn = SpawnService.RegisterBeforeRespawnHook(function(playerLike)
			local uid = playerLike.UserId
			local state = _statesByUserId[uid]
			if state == States.PreparingLaunch or state == States.Launching then
				VehicleLifecycleService.RollbackLaunch(playerLike, "PlayerRespawned", "Lanzamiento cancelado por respawn")
			elseif VehicleRuntimeService.GetRuntimeByPlayer(uid) then
				if GameConfig.Runtime.DestroyVehicleOnDeath then
					VehicleLifecycleService.ReturnToWorkshop(playerLike, "PlayerRespawned", false)
				elseif state == States.Driving then
					setStateInternal(uid, States.OnFootRuntime :: VehicleTypes.VehicleState, nowSeconds(), true)
				end
			end
		end)
	end

	_lastAbandonedScanAt = nowSeconds()
	_initialized = true
end

function VehicleLifecycleService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehicleLifecycleService.Init()
	end

	for _, plr in ipairs(Players:GetPlayers()) do
		ensurePlayerBound(plr)
	end

	table.insert(
		_serviceConnections,
		Players.PlayerAdded:Connect(function(plr)
			ensurePlayerBound(plr)
		end)
	)

	table.insert(
		_serviceConnections,
		Players.PlayerRemoving:Connect(function(plr)
			VehicleLifecycleService.ClearPlayer(plr)
		end)
	)

	table.insert(
		_serviceConnections,
		RunService.Heartbeat:Connect(function()
			local now = nowSeconds()
			if (now - _lastAbandonedScanAt) >= GameConfig.Runtime.AbandonedCleanupCheckIntervalSeconds then
				_lastAbandonedScanAt = now
				VehicleLifecycleService.CheckAbandonedVehicles(now)
			end
		end)
	)

	_started = true
end

function VehicleLifecycleService._ResetForTests()
	for _, conn in ipairs(_serviceConnections) do
		conn:Disconnect()
	end
	table.clear(_serviceConnections)

	for userId in pairs(table.clone(_playerConnsByUserId)) do
		disconnectPlayerSignals(userId)
	end
	table.clear(_playerConnsByUserId)

	if _unsubSeat then
		_unsubSeat()
		_unsubSeat = nil
	end
	if _unsubInvalidated then
		_unsubInvalidated()
		_unsubInvalidated = nil
	end
	if _unsubPlotReleased then
		_unsubPlotReleased()
		_unsubPlotReleased = nil
	end
	if _unsubBeforeRespawn then
		_unsubBeforeRespawn()
		_unsubBeforeRespawn = nil
	end

	table.clear(_statesByUserId)
	table.clear(_playerRefsByUserId)
	table.clear(_lastErrorByUserId)
	table.clear(_suppressRestoreEditableOnEditingByUserId)
	table.clear(_stateListeners)
	_clockFn = os.clock
	_lastAbandonedScanAt = 0
	_initialized = false
	_started = false
end

return VehicleLifecycleService

