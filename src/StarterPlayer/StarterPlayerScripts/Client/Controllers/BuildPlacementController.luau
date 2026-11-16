--!strict
--[=[
	BuildPlacementController
	Gestiona la colocación optimista local de piezas y su reconciliación con el servidor (Fases 2.2 y 2.3).
	- Muestra inmediatamente una pieza provisional local mientras viaja la solicitud.
	- Evita duplicados en vuelo y doble clic sobre la misma celda/orientación.
	- Soporta timeout configurable y recuperación automática vía GetBlueprint ante pérdida de respuesta.
	- Evita duplicados visuales durante la transición entre pieza provisional y EditableVehicle replicado.
]=]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)

local BuildState = require(script.Parent.BuildState)

export type InvokeHandler = (request: BuildProtocol.BuildRequest) -> BuildProtocol.BuildOperationResponse

type PendingPlacement = {
	ClientOpId: string,
	TargetKey: string,
	GhostModel: Model?,
	StartedAt: number,
	TimedOut: boolean,
}

type ReconcilingEntry = {
	Model: Model,
	Connection: RBXScriptConnection?,
	Timer: thread?,
}

local BuildPlacementController = {}

local _opSequence = 0
local _pendingByOpId: { [string]: PendingPlacement } = {}
local _inFlightTargetKeys: { [string]: boolean } = {}
local _reconcilingByPieceId: { [string]: ReconcilingEntry } = {}
local _operationTimeoutSeconds: number = GameConfig.Building.OperationTimeoutSeconds

local function syncPendingCount()
	local count = 0
	for _ in pairs(_pendingByOpId) do
		count += 1
	end
	BuildState.SetPendingOpCount(count)
end

local function getDefaultInvokeHandler(): InvokeHandler?
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local remotes = shared and shared:FindFirstChild("Remotes")
	local rf = remotes and remotes:FindFirstChild(BuildProtocol.RemoteFunctionName)
	if rf and rf:IsA("RemoteFunction") then
		return function(req: BuildProtocol.BuildRequest): BuildProtocol.BuildOperationResponse
			return (rf :: RemoteFunction):InvokeServer(req)
		end
	end
	return nil
end

local function getEditableVehicleRoot(): Model?
	local plotModel = BuildState.AssignedPlot
	if not plotModel then
		return nil
	end
	local dyn = plotModel:FindFirstChild(GameConfig.PlotContainers.Dynamic)
	local editable = dyn and dyn:FindFirstChild(GameConfig.Building.EditableVehicleName)
	if editable and editable:IsA("Model") then
		return editable
	end
	return nil
end

local function hasReplicatedPieceModel(editable: Model, pieceInstanceId: string): boolean
	for _, child in ipairs(editable:GetChildren()) do
		if child:IsA("Model") and (child.Name == pieceInstanceId or child:GetAttribute("PieceInstanceId") == pieceInstanceId) then
			return true
		end
	end
	return false
end

local function cleanupReconcilingEntry(pieceId: string)
	local entry = _reconcilingByPieceId[pieceId]
	if not entry then
		return
	end
	_reconcilingByPieceId[pieceId] = nil
	if entry.Connection then
		entry.Connection:Disconnect()
		entry.Connection = nil
	end
	if entry.Timer then
		pcall(task.cancel, entry.Timer)
		entry.Timer = nil
	end
	if entry.Model and entry.Model.Parent then
		entry.Model:Destroy()
	end
end

local function handOffOptimisticToReplicated(pieceId: string, optimisticModel: Model)
	local editable = getEditableVehicleRoot()
	if
		not editable
		or not BuildState.IsEditingMode()
		or editable:GetAttribute("IsEditableHidden") == true
		or hasReplicatedPieceModel(editable, pieceId)
	then
		optimisticModel:Destroy()
		return
	end

	-- Si Workspace aún no replicó la pieza confirmada, conservar el modelo provisional brevemente
	-- y destruirlo en cuanto aparezca EditableVehicle.<PieceInstanceId> para evitar doble visual o parpadeo.
	cleanupReconcilingEntry(pieceId)

	local entry: ReconcilingEntry = {
		Model = optimisticModel,
		Connection = nil,
		Timer = nil,
	}
	_reconcilingByPieceId[pieceId] = entry

	entry.Connection = editable.ChildAdded:Connect(function(child: Instance)
		if child.Name == pieceId or child:GetAttribute("PieceInstanceId") == pieceId then
			cleanupReconcilingEntry(pieceId)
		end
	end)

	entry.Timer = task.delay(GameConfig.Building.ReconcileGraceSeconds, function()
		cleanupReconcilingEntry(pieceId)
	end)
end

local function makeTargetKey(itemId: string, localCF: CFrame): string
	local p = localCF.Position
	local r = localCF.RightVector
	local u = localCF.UpVector
	return string.format(
		"%s:%.2f,%.2f,%.2f:%.1f,%.1f,%.1f:%.1f,%.1f,%.1f",
		itemId,
		p.X,
		p.Y,
		p.Z,
		r.X,
		r.Y,
		r.Z,
		u.X,
		u.Y,
		u.Z
	)
end

local function createOptimisticModel(itemId: string, worldCFrame: CFrame, clientOpId: string): Model?
	local def = ItemRegistry.TryGet(itemId)
	if not def then
		return nil
	end

	local previewRoot = ReplicatedStorage:FindFirstChild(GameConfig.Building.PreviewAssetsFolder)
	local template = ItemRegistry.ResolveModel(previewRoot, def)
	if not template then
		return nil
	end

	local clone = template:Clone()
	clone.Name = `Optimistic_{clientOpId}`
	clone:SetAttribute("IsOptimisticPiece", true)
	clone:SetAttribute("ClientOpId", clientOpId)

	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
			desc.CanTouch = false
			desc.CanQuery = false
			desc.CastShadow = false
			if PhysicsService:IsCollisionGroupRegistered(GameConfig.Runtime.CollisionGroups.EditorGhost) then
				desc.CollisionGroup = GameConfig.Runtime.CollisionGroups.EditorGhost
			end
			desc.Transparency = GameConfig.Building.OptimisticTransparency
			desc.Color = GameConfig.Building.OptimisticColor
			desc.Material = Enum.Material.SmoothPlastic
		end
	end

	clone:PivotTo(worldCFrame)
	clone.Parent = Workspace.CurrentCamera or Workspace
	return clone
end

local function invokeWithTimeout(
	invoke: InvokeHandler,
	request: BuildProtocol.BuildRequest,
	timeoutSeconds: number
): (boolean, any, boolean)
	local finished = false
	local callOk = false
	local callResult: any = nil
	local timedOut = false
	local callerThread = coroutine.running()

	task.spawn(function()
		local t0 = os.clock()
		local ok, res = pcall(invoke, request)
		if (os.clock() - t0) >= timeoutSeconds then
			timedOut = true
		end
		callOk = ok
		callResult = res
		finished = true
		if not timedOut and coroutine.status(callerThread) == "suspended" then
			task.spawn(callerThread)
		end
	end)

	if not finished then
		local timeoutThread = task.delay(timeoutSeconds, function()
			if not finished then
				timedOut = true
				if coroutine.status(callerThread) == "suspended" then
					task.spawn(callerThread)
				end
			end
		end)
		coroutine.yield()
		if finished then
			pcall(task.cancel, timeoutThread)
		end
	end

	return callOk, callResult, timedOut
end

function BuildPlacementController.SetOperationTimeoutSeconds(seconds: number?)
	_operationTimeoutSeconds = if seconds and seconds > 0 then seconds else GameConfig.Building.OperationTimeoutSeconds
end

function BuildPlacementController.NotifyReplicatedOrSynced(pieceId: string)
	cleanupReconcilingEntry(pieceId)
end

function BuildPlacementController.SyncBlueprintFromServer(customInvoke: InvokeHandler?): boolean
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		return false
	end

	local ok, res, timedOut = invokeWithTimeout(invoke, { Action = "GetBlueprint" }, _operationTimeoutSeconds)
	if ok and not timedOut and type(res) == "table" and res.Success and res.Blueprint then
		if type(res.WorkshopEpoch) == "number" then
			BuildState.SetWorkshopEpoch(res.WorkshopEpoch)
		end
		BuildState.ApplyAuthoritativeBlueprint(res.Blueprint, true)
		if res.Slots or res.LoadedSlotIndex ~= nil or res.HasUnsavedChanges ~= nil or type(res.LegacyOverflowCount) == "number" then
			BuildState.SetSlotLibraryState(
				res.Slots,
				res.LoadedSlotIndex,
				res.HasUnsavedChanges,
				res.LegacyOverflowCount,
				res.LegacyOverflow
			)
		end
		if res.RuntimeStatus then
			BuildState.SetRuntimeStatus(res.RuntimeStatus)
		end
		if res.Inventory ~= nil then
			BuildState.SetInventoryState(res.Inventory)
		end
		return true
	end
	return false
end

function BuildPlacementController.PlaceCurrentPiece(customInvoke: InvokeHandler?): (boolean, BuildProtocol.BuildOperationResponse?)
	if not BuildState.IsActive or not BuildState.IsEditingMode() or not BuildState.SelectedItemId then
		return false, nil
	end

	if not BuildState.IsValidPlacement or not BuildState.LastSnappedLocalCFrame or not BuildState.LastSnappedCFrame then
		BuildState.SetError(BuildState.ValidationReason or "Posición inválida")
		return false, nil
	end

	local itemId = BuildState.SelectedItemId :: string
	local localCF = BuildState.LastSnappedLocalCFrame :: CFrame
	local worldCF = BuildState.LastSnappedCFrame :: CFrame

	local availQty = BuildState.GetAvailableQuantity(itemId)
	if availQty ~= nil and availQty <= 0 then
		local displayName = ItemCatalog.GetDisplayName(itemId)
		local msg = `No tienes '{displayName}' disponible en tu inventario.`
		BuildState.SetError(msg)
		return false, {
			Success = false,
			ErrorCode = BuildProtocol.ErrorCodes.InsufficientInventory,
			ErrorMessage = msg,
			Revision = BuildState.BlueprintRevision,
			BlueprintId = BuildState.BlueprintId,
		}
	end

	local targetKey = makeTargetKey(itemId, localCF)
	if _inFlightTargetKeys[targetKey] then
		return false, nil
	end

	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	_opSequence += 1
	local localPlayer = Players.LocalPlayer
	local userId = if localPlayer then localPlayer.UserId else (BuildState.ExpectedOwnerUserId or 0)
	local clientOpId = `place_{userId}_{_opSequence}`

	local optimisticModel = createOptimisticModel(itemId, worldCF, clientOpId)
	_inFlightTargetKeys[targetKey] = true
	_pendingByOpId[clientOpId] = {
		ClientOpId = clientOpId,
		TargetKey = targetKey,
		GhostModel = optimisticModel,
		StartedAt = os.clock(),
		TimedOut = false,
	}
	syncPendingCount()

	local request: BuildProtocol.PlacePieceRequest = {
		Action = "PlacePiece",
		ClientOpId = clientOpId,
		ItemId = itemId,
		LocalCFrame = localCF,
		Config = nil,
		ExpectedBlueprintId = BuildState.BlueprintId,
	}

	local requestEpoch = BuildState.TransitionEpoch
	local ok, responseOrErr, timedOut = invokeWithTimeout(invoke, request, _operationTimeoutSeconds)

	local pending = _pendingByOpId[clientOpId]
	if pending then
		_pendingByOpId[clientOpId] = nil
		_inFlightTargetKeys[pending.TargetKey] = nil
	end
	syncPendingCount()

	-- Si fue cancelado explícitamente o cambió el blueprint activo mientras viajaba por red -> descartar respuesta tardía
	if pending == nil or BuildState.TransitionEpoch ~= requestEpoch then
		if optimisticModel and optimisticModel.Parent then
			optimisticModel:Destroy()
		end
		return false, nil
	end

	if timedOut then
		if pending.GhostModel and pending.GhostModel.Parent then
			pending.GhostModel:Destroy()
		end
		BuildState.SetError(BuildProtocol.ErrorCodes.OperationTimeout)
		-- Recuperar estado autoritativo por si el servidor procesó la operación tras perderse la respuesta
		BuildPlacementController.SyncBlueprintFromServer(customInvoke)
		return false, nil
	end

	if not ok or type(responseOrErr) ~= "table" then
		if pending.GhostModel and pending.GhostModel.Parent then
			pending.GhostModel:Destroy()
		end
		BuildState.SetError("Error de red al colocar pieza")
		return false, nil
	end

	local response = responseOrErr :: BuildProtocol.BuildOperationResponse
	if response.Inventory ~= nil then
		BuildState.SetInventoryState(response.Inventory)
	end
	if response.Success then
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint)
		end

		if pending.GhostModel then
			if response.PlacedPiece then
				handOffOptimisticToReplicated(response.PlacedPiece.InstanceId, pending.GhostModel)
			elseif pending.GhostModel.Parent then
				pending.GhostModel:Destroy()
			end
		end

		BuildState.SetStatusMessage(`Pieza colocada ({ItemCatalog.GetDisplayName(itemId)})`)
		return true, response
	else
		if pending.GhostModel and pending.GhostModel.Parent then
			pending.GhostModel:Destroy()
		end
		BuildState.SetError(response.ErrorMessage or response.ErrorCode or "Colocación rechazada")
		return false, response
	end
end

function BuildPlacementController.ClearPending()
	for opId, entry in pairs(_pendingByOpId) do
		if entry.GhostModel and entry.GhostModel.Parent then
			entry.GhostModel:Destroy()
		end
		_pendingByOpId[opId] = nil
	end
	table.clear(_inFlightTargetKeys)

	local pieceIds: { string } = {}
	for pieceId in pairs(_reconcilingByPieceId) do
		table.insert(pieceIds, pieceId)
	end
	for _, pieceId in ipairs(pieceIds) do
		cleanupReconcilingEntry(pieceId)
	end

	syncPendingCount()
end

function BuildPlacementController.GetPendingCount(): number
	local count = 0
	for _ in pairs(_pendingByOpId) do
		count += 1
	end
	return count
end

return BuildPlacementController
