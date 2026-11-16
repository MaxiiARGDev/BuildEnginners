--!strict
--[=[
	VehicleRuntimeService
	Administra el registro autoritativo de instancias físicas `VehicleRuntime`:
	- Máximo 1 `VehicleRuntime` activo por jugador con bloqueo de concurrencia en creación.
	- Publicación desde staging hacia `plot.DynamicContainer`, activación física segura sin explosiones
	  (desanclaje controlado con velocidades inicializadas a cero).
	- Integración con `ItemRuntimeService` para inicializar/destruir comportamientos modulares por pieza.
	- Política explícita de NetworkOwnership:
	  * Mientras el dueño está sentado conduciendo (`Driving`): NetworkOwner = dueño (control responsivo seguro).
	  * Cuando el vehículo queda desocupado (`OnFootRuntime`) o durante activación inicial: NetworkOwner = Servidor (`nil`),
	    evitando explotación física cliente-side y robos de ownership.
	- Limpieza determinista de conexiones RBXScriptConnection, comportamientos e instancias en memoria/Workspace.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local ItemRuntimeService = require(ServerScriptService.Server.Services.ItemRuntimeService)
local PlotService = require(ServerScriptService.Server.Services.PlotService)
local VehicleAssemblyService = require(ServerScriptService.Server.Services.VehicleAssemblyService)
local AerodynamicsService = require(ServerScriptService.Server.Services.AerodynamicsService)
local VehicleBoosterService = require(ServerScriptService.Server.Services.VehicleBoosterService)
local VehicleDamageService = require(ServerScriptService.Server.Services.VehicleDamageService)
local VehicleImpactService = require(ServerScriptService.Server.Services.VehicleImpactService)
local VehiclePowertrainService = require(ServerScriptService.Server.Services.VehiclePowertrainService)
local VehicleWheelControllerService = require(ServerScriptService.Server.Services.VehicleWheelControllerService)

export type SeatOccupancyListener = (runtime: VehicleTypes.VehicleRuntime, occupant: Humanoid?) -> ()
export type RuntimeInvalidatedListener = (runtime: VehicleTypes.VehicleRuntime, reason: string) -> ()

type InternalRuntimeEntry = {
	Runtime: VehicleTypes.VehicleRuntime,
	Plot: PlotService.PlotRecord,
	Connections: { RBXScriptConnection },
	LastOccupant: Humanoid?,
	Destroyed: boolean,
}

local VehicleDestructionService = require(script.Parent.VehicleDestructionService)
local VehicleSeatService = require(script.Parent.VehicleSeatService)

local VehicleRuntimeService = {
	Name = "VehicleRuntimeService",
}

local _entriesByUserId: { [number]: InternalRuntimeEntry } = {}
local _entryByModel: { [Model]: InternalRuntimeEntry } = {}
local _reservedSlotsByUserId: { [number]: boolean } = {}
local _runtimeSeq = 0

local _seatListeners: { SeatOccupancyListener } = {}
local _invalidationListeners: { RuntimeInvalidatedListener } = {}
local _initialized = false
local _started = false

local function emitSeatOccupancy(runtime: VehicleTypes.VehicleRuntime, occupant: Humanoid?)
	for _, fn in ipairs(table.clone(_seatListeners)) do
		fn(runtime, occupant)
	end
end

local function emitInvalidated(runtime: VehicleTypes.VehicleRuntime, reason: string)
	for _, fn in ipairs(table.clone(_invalidationListeners)) do
		fn(runtime, reason)
	end
end

local function disconnectEntryConnections(entry: InternalRuntimeEntry)
	for _, conn in ipairs(entry.Connections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(entry.Connections)
end

local function getLivePlayerInstance(userId: number): Player?
	local plr = Players:GetPlayerByUserId(userId)
	if plr and plr:IsDescendantOf(Players) then
		return plr
	end
	return nil
end

function VehicleRuntimeService.ReserveSlot(userId: number): boolean
	if _reservedSlotsByUserId[userId] or _entriesByUserId[userId] ~= nil then
		return false
	end
	_reservedSlotsByUserId[userId] = true
	return true
end

function VehicleRuntimeService.ReleaseSlot(userId: number)
	_reservedSlotsByUserId[userId] = nil
end

function VehicleRuntimeService.IsSlotReserved(userId: number): boolean
	return _reservedSlotsByUserId[userId] == true
end

function VehicleRuntimeService.ApplyNetworkOwnership(runtime: VehicleTypes.VehicleRuntime, grantToOwner: boolean): number?
	local rootModel = runtime.RootModel
	if not rootModel or not rootModel:IsDescendantOf(Workspace) then
		runtime.NetworkOwnerUserId = nil
		return nil
	end

	local targetPlayer: Player? = if grantToOwner then getLivePlayerInstance(runtime.OwnerUserId) else nil
	local targetOwnerId: number? = if targetPlayer then targetPlayer.UserId else nil

	local visitedRoots: { [BasePart]: boolean } = {}
	local rootCount = 0
	for _, desc in ipairs(rootModel:GetDescendants()) do
		if desc:IsA("BasePart") and not desc.Anchored then
			local assemblyRoot = desc:GetRootPart() or desc
			if not visitedRoots[assemblyRoot] then
				visitedRoots[assemblyRoot] = true
				rootCount += 1
				local canCheck, isMutable = pcall(function()
					return assemblyRoot:CanSetNetworkOwnership()
				end)
				if canCheck and isMutable then
					pcall(function()
						assemblyRoot:SetNetworkOwner(targetPlayer)
					end)
				end
			end
		end
	end

	runtime.NetworkOwnerUserId = targetOwnerId
	rootModel:SetAttribute("NetworkOwnerUserId", targetOwnerId or 0)
	rootModel:SetAttribute("NetworkAssemblyRootsCount", rootCount)
	return targetOwnerId
end

function VehicleRuntimeService.PublishAndActivate(params: {
	RuntimeId: string?,
	Player: PlotService.PlayerLike,
	Plot: PlotService.PlotRecord,
	Blueprint: VehicleTypes.VehicleBlueprint,
	Assembled: VehicleAssemblyService.AssembledStagingResult,
}): (boolean, VehicleTypes.VehicleRuntime?, string?, string?)
	if not _initialized then
		VehicleRuntimeService.Init()
	end

	local userId = params.Player.UserId
	if _entriesByUserId[userId] ~= nil then
		return false, nil, "RuntimeAlreadyActive", "El jugador ya tiene un VehicleRuntime activo"
	end

	local plot = params.Plot
	local assembled = params.Assembled
	local rootModel = assembled.RootModel

	-- Limpiar cualquier resto previo del contenedor dinámico excepto EditableVehicle
	local strayRuntime = plot.DynamicContainer:FindFirstChild(GameConfig.Runtime.ModelName)
	if strayRuntime and strayRuntime ~= rootModel then
		strayRuntime:Destroy()
	end

	_runtimeSeq += 1
	local runtimeId = params.RuntimeId or rootModel:GetAttribute("RuntimeId") or `vrt_{userId}_{_runtimeSeq}`
	rootModel:SetAttribute("RuntimeId", runtimeId)

	local runtime: VehicleTypes.VehicleRuntime = {
		RuntimeId = runtimeId,
		OwnerUserId = userId,
		PlotId = plot.PlotId,
		SourceBlueprintId = params.Blueprint.BlueprintId,
		SourceBlueprintRevision = params.Blueprint.Revision,
		State = GameConfig.Runtime.States.Launching :: VehicleTypes.VehicleState,
		Parts = assembled.PartsState,
		RootModel = rootModel,
		PrimaryPart = assembled.PrimaryPart,
		DriverSeatPart = assembled.DriverSeatPart,
		Joints = assembled.Joints,
		WheelPieceIds = assembled.WheelPieceIds,
		WheelConstraints = assembled.WheelConstraints,
		WheelMechanisms = assembled.WheelMechanisms,
		PropulsionPieceIds = assembled.PropulsionPieceIds,
		BoosterPieceIds = assembled.BoosterPieceIds,
		NitroTankPieceIds = assembled.NitroTankPieceIds,
		AerodynamicPieceIds = assembled.AerodynamicPieceIds,
		PieceAdjacencyById = assembled.PieceAdjacencyById,
		NetworkOwnerUserId = nil,
		AbandonedSince = nil,
		StartedAt = os.clock(),
	}

	local entry: InternalRuntimeEntry = {
		Runtime = runtime,
		Plot = plot,
		Connections = {},
		LastOccupant = nil,
		Destroyed = false,
	}

	_entriesByUserId[userId] = entry
	_entryByModel[rootModel] = entry

	-- Inicializar comportamientos modulares autorizados en ItemRuntimeService
	for pieceId, pieceModel in pairs(assembled.PieceModelsById) do
		local partState = assembled.PartsState[pieceId]
		if partState then
			ItemRuntimeService.InitPart(runtime, partState, pieceModel)
		end
	end

	-- Publicar el modelo completamente ensamblado al Workspace dentro del contenedor del plot
	rootModel.Parent = plot.DynamicContainer

	-- Activar físicas de manera atómica en un solo recorrido: poner velocidades en cero antes de desanclar
	local partsToUnanchor: { BasePart } = {}
	for _, desc in ipairs(rootModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.AssemblyLinearVelocity = Vector3.zero
			desc.AssemblyAngularVelocity = Vector3.zero
			desc.CollisionGroup = GameConfig.Runtime.CollisionGroups.VehicleRuntime
			table.insert(partsToUnanchor, desc)
		end
	end
	for _, part in ipairs(partsToUnanchor) do
		part.Anchored = false
	end

	-- Por defecto iniciar con ownership de servidor hasta confirmar asiento válido del dueño
	VehicleRuntimeService.ApplyNetworkOwnership(runtime, false)

	-- Registrar en el orquestador centralizado de ruedas/suspensión/dirección (Fase 3.2), tren motriz (Fase 3.3), propulsores (Fase 3.4) y daño estructural (Fase 4.1)
	VehicleWheelControllerService.RegisterRuntime(runtime)
	VehiclePowertrainService.RegisterRuntime(runtime)
	VehicleBoosterService.RegisterRuntime(runtime)
	AerodynamicsService.RegisterRuntime(runtime)
	VehicleDamageService.RegisterRuntime(runtime)
	VehicleImpactService.RegisterRuntime(runtime)
	VehicleSeatService.RegisterRuntime(runtime, plot.PlayerSpawn)
	VehicleDestructionService.RegisterRuntime(runtime, function(changedRuntime)
		VehicleImpactService.RefreshRuntime(changedRuntime)
		if changedRuntime.DriverSeatDestroyed then emitSeatOccupancy(changedRuntime, nil) end
	end)

	-- Vigilar cambios de ocupante en DriverSeat y destrucción externa del modelo
	table.insert(
		entry.Connections,
		assembled.DriverSeatPart:GetPropertyChangedSignal("Occupant"):Connect(function()
			if entry.Destroyed then
				return
			end
			local occ = assembled.DriverSeatPart.Occupant
			local hum = if occ and occ:IsA("Humanoid") then occ else nil
			entry.LastOccupant = hum
			emitSeatOccupancy(runtime, hum)
		end)
	)

	local function handleExternalRemoval(_, newParent: Instance?)
		if entry.Destroyed then
			return
		end
		if newParent == nil or not rootModel:IsDescendantOf(Workspace) then
			VehicleRuntimeService.DestroyRuntimeForPlayer(userId, "ExternalModelDestroyed")
			emitInvalidated(runtime, "ExternalModelDestroyed")
		end
	end

	table.insert(entry.Connections, rootModel.AncestryChanged:Connect(handleExternalRemoval))
	table.insert(
		entry.Connections,
		assembled.DriverSeatPart.AncestryChanged:Connect(function(_, newParent)
			if entry.Destroyed then
				return
			end
			if runtime.DriverSeatDestroyed then return end
			if newParent == nil or not assembled.DriverSeatPart:IsDescendantOf(rootModel) then
				VehicleRuntimeService.DestroyRuntimeForPlayer(userId, "DriverSeatDestroyed")
				emitInvalidated(runtime, "DriverSeatDestroyed")
			end
		end)
	)

	_reservedSlotsByUserId[userId] = nil
	return true, runtime, nil, nil
end

function VehicleRuntimeService.SetRuntimeState(userId: number, newState: VehicleTypes.VehicleState, abandonedSince: number?)
	local entry = _entriesByUserId[userId]
	if not entry or entry.Destroyed then
		return
	end
	entry.Runtime.State = newState
	entry.Runtime.AbandonedSince = abandonedSince
	if entry.Runtime.RootModel and entry.Runtime.RootModel.Parent then
		entry.Runtime.RootModel:SetAttribute("RuntimeState", newState)
	end
	if newState ~= GameConfig.Runtime.States.Driving then
		VehicleBoosterService.CutBoostForPlayer(userId, `State:{newState}`)
	end
	VehicleRuntimeService.ApplyNetworkOwnership(
		entry.Runtime,
		newState == GameConfig.Runtime.States.Driving
	)
end

function VehicleRuntimeService.DestroyRuntimeForPlayer(playerOrUserId: PlotService.PlayerLike | number, reason: string?): boolean
	local userId = if type(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	_reservedSlotsByUserId[userId] = nil

	local entry = _entriesByUserId[userId]
	if not entry then
		return false
	end

	entry.Destroyed = true
	_entriesByUserId[userId] = nil
	if entry.Runtime.RootModel then
		_entryByModel[entry.Runtime.RootModel] = nil
	end

	disconnectEntryConnections(entry)

	VehicleSeatService.UnregisterRuntime(entry.Runtime)

	local seat = entry.Runtime.DriverSeatPart
	if seat and seat.Parent then
		local occupant = seat.Occupant
		if occupant then
			occupant.Sit = false
		end
		seat.Disabled = true
	end
	VehicleDestructionService.UnregisterRuntime(entry.Runtime)
	VehicleImpactService.UnregisterRuntime(entry.Runtime)
	VehicleDamageService.UnregisterRuntime(entry.Runtime)
	VehicleRuntimeService.ApplyNetworkOwnership(entry.Runtime, false)
	VehicleBoosterService.CutBoostForPlayer(userId, reason or "DestroyRuntime")
	VehicleBoosterService.UnregisterRuntime(entry.Runtime)
	AerodynamicsService.UnregisterRuntime(entry.Runtime)
	VehiclePowertrainService.UnregisterRuntime(entry.Runtime)
	VehicleWheelControllerService.UnregisterRuntime(entry.Runtime)
	ItemRuntimeService.DestroyRuntime(entry.Runtime)

	if entry.Runtime.RootModel and entry.Runtime.RootModel.Parent then
		entry.Runtime.RootModel:Destroy()
	end
	entry.Runtime.RootModel = nil
	entry.Runtime.PrimaryPart = nil
	entry.Runtime.DriverSeatPart = nil
	entry.Runtime.WheelConstraints = nil
	entry.Runtime.WheelMechanisms = nil
	entry.Runtime.State = GameConfig.Runtime.States.ReturningToWorkshop :: VehicleTypes.VehicleState

	return true
end

local function reconcileActiveEntries()
	local snapshot: { InternalRuntimeEntry } = {}
	for _, entry in pairs(_entriesByUserId) do
		table.insert(snapshot, entry)
	end
	for _, entry in ipairs(snapshot) do
		if not entry.Destroyed then
			local rt = entry.Runtime
			local root = rt.RootModel
			local seat = rt.DriverSeatPart
			if not root or root.Parent == nil or not root:IsDescendantOf(Workspace) then
				VehicleRuntimeService.DestroyRuntimeForPlayer(rt.OwnerUserId, "ExternalModelDestroyed")
				emitInvalidated(rt, "ExternalModelDestroyed")
			elseif rt.DriverSeatDestroyed then
				-- Casco pasivo válido: el asiento destruido no invalida todo el runtime.
			elseif not seat or seat.Parent == nil or not seat:IsDescendantOf(root) then
				VehicleRuntimeService.DestroyRuntimeForPlayer(rt.OwnerUserId, "DriverSeatDestroyed")
				emitInvalidated(rt, "DriverSeatDestroyed")
			else
				local occ = seat.Occupant
				local hum = if occ and occ:IsA("Humanoid") then occ else nil
				if entry.LastOccupant ~= hum then
					entry.LastOccupant = hum
					emitSeatOccupancy(rt, hum)
				end
			end
		end
	end
end

function VehicleRuntimeService.GetRuntimeByPlayer(playerOrUserId: PlotService.PlayerLike | number): VehicleTypes.VehicleRuntime?
	reconcileActiveEntries()
	local userId = if type(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	local entry = _entriesByUserId[userId]
	if entry and not entry.Destroyed then
		return entry.Runtime
	end
	return nil
end

function VehicleRuntimeService.GetRuntimeByModel(model: Model): VehicleTypes.VehicleRuntime?
	reconcileActiveEntries()
	local entry = _entryByModel[model]
	if entry and not entry.Destroyed then
		return entry.Runtime
	end
	return nil
end

function VehicleRuntimeService.GetAllActiveRuntimes(): { VehicleTypes.VehicleRuntime }
	reconcileActiveEntries()
	local out: { VehicleTypes.VehicleRuntime } = {}
	for _, entry in pairs(_entriesByUserId) do
		if not entry.Destroyed then
			table.insert(out, entry.Runtime)
		end
	end
	return out
end

function VehicleRuntimeService.GetActiveRuntimeCount(): number
	reconcileActiveEntries()
	local count = 0
	for _ in pairs(_entriesByUserId) do
		count += 1
	end
	return count
end

function VehicleRuntimeService.GetTrackedConnectionCount(): number
	reconcileActiveEntries()
	local total = 0
	for _, entry in pairs(_entriesByUserId) do
		for _, conn in ipairs(entry.Connections) do
			if conn.Connected then
				total += 1
			end
		end
	end
	return total
end

function VehicleRuntimeService.OnSeatOccupancyChanged(listener: SeatOccupancyListener): () -> ()
	table.insert(_seatListeners, listener)
	return function()
		local idx = table.find(_seatListeners, listener)
		if idx then
			table.remove(_seatListeners, idx)
		end
	end
end

function VehicleRuntimeService.OnRuntimeInvalidated(listener: RuntimeInvalidatedListener): () -> ()
	table.insert(_invalidationListeners, listener)
	return function()
		local idx = table.find(_invalidationListeners, listener)
		if idx then
			table.remove(_invalidationListeners, idx)
		end
	end
end

function VehicleRuntimeService.Init()
	if _initialized then
		return
	end
	VehicleAssemblyService.Init()
	ItemRuntimeService.Init()
	VehiclePowertrainService.Init()
	AerodynamicsService.Init()
	VehicleDamageService.Init()
	VehicleImpactService.Init()
	VehicleSeatService.Init()
	VehicleDestructionService.Init()
	_initialized = true
end

function VehicleRuntimeService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehicleRuntimeService.Init()
	end
	_started = true
end

function VehicleRuntimeService._ResetForTests()
	for userId in pairs(table.clone(_entriesByUserId)) do
		VehicleRuntimeService.DestroyRuntimeForPlayer(userId, "ResetForTests")
	end
	VehicleSeatService._ResetForTests()
	VehicleDestructionService._ResetForTests()
	VehicleImpactService._ResetForTests()
	VehicleDamageService._ResetForTests()
	AerodynamicsService._ResetForTests()
	VehiclePowertrainService._ResetForTests()
	table.clear(_entriesByUserId)
	table.clear(_entryByModel)
	table.clear(_reservedSlotsByUserId)
	table.clear(_seatListeners)
	table.clear(_invalidationListeners)
	_runtimeSeq = 0
	_initialized = false
	_started = false
end

return VehicleRuntimeService


