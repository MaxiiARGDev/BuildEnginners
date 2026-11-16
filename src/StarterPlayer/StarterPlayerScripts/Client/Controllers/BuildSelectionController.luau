--!strict
--[=[
	BuildSelectionController
	Gestiona la selección visual de piezas colocadas dentro de EditableVehicle de la propia estación
	y la eliminación optimista con protección contra doble clic, timeout configurable, rollback
	y recuperación automática vía GetBlueprint ante pérdida de respuesta.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)

local BuildState = require(script.Parent.BuildState)
local BuildPlacementController = require(script.Parent.BuildPlacementController)

local BuildSelectionController = {}

local _highlight: Highlight? = nil
local _deleteSeq = 0
local _pendingDeleteIds: { [string]: boolean } = {}
local _operationTimeoutSeconds: number = GameConfig.Building.OperationTimeoutSeconds
local _raycastParams = RaycastParams.new()
_raycastParams.FilterType = Enum.RaycastFilterType.Include
_raycastParams.IgnoreWater = true

local function getDefaultInvokeHandler(): BuildPlacementController.InvokeHandler?
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

local function findPieceModelById(pieceInstanceId: string): Model?
	local editable = getEditableVehicleRoot()
	if not editable then
		return nil
	end
	for _, child in ipairs(editable:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("PieceInstanceId") == pieceInstanceId then
			return child
		end
	end
	return nil
end

local function updateSelectionHighlight(targetModel: Model?)
	if not targetModel then
		if _highlight then
			_highlight:Destroy()
			_highlight = nil
		end
		return
	end

	if not _highlight then
		local hl = Instance.new("Highlight")
		hl.Name = "BuildSelectionHighlight"
		hl.FillTransparency = 0.75
		hl.FillColor = GameConfig.Building.SelectionHighlightColor
		hl.OutlineColor = GameConfig.Building.SelectionHighlightColor
		hl.OutlineTransparency = 0
		_highlight = hl
	end

	local activeHighlight = _highlight :: Highlight
	activeHighlight.Adornee = targetModel
	activeHighlight.Parent = targetModel
end

local function invokeWithTimeout(
	invoke: BuildPlacementController.InvokeHandler,
	request: BuildProtocol.BuildRequest,
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

local function isEditableVehicleHidden(editable: Model?): boolean
	return editable ~= nil and editable:GetAttribute("IsEditableHidden") == true
end

local function restoreTransparencies(savedTransparencies: { [BasePart]: number })
	local editable = getEditableVehicleRoot()
	if not BuildState.IsEditingMode() or isEditableVehicleHidden(editable) then
		return
	end
	for part, origT in pairs(savedTransparencies) do
		if part.Parent then
			part.Transparency = origT
		end
	end
end

function BuildSelectionController.SetOperationTimeoutSeconds(seconds: number?)
	_operationTimeoutSeconds = if seconds and seconds > 0 then seconds else GameConfig.Building.OperationTimeoutSeconds
end

function BuildSelectionController.ClearSelection()
	updateSelectionHighlight(nil)
	BuildState.SetSelectedPlacedPiece(nil)
end

function BuildSelectionController.ClearPendingDeletes()
	table.clear(_pendingDeleteIds)
end

function BuildSelectionController.GetPendingDeleteCount(): number
	local count = 0
	for _ in pairs(_pendingDeleteIds) do
		count += 1
	end
	return count
end

function BuildSelectionController.SelectPieceById(pieceInstanceId: string?): boolean
	local editable = getEditableVehicleRoot()
	if not BuildState.IsEditingMode() or isEditableVehicleHidden(editable) then
		BuildSelectionController.ClearSelection()
		return false
	end

	if not pieceInstanceId then
		BuildSelectionController.ClearSelection()
		return false
	end

	local pieceModel = findPieceModelById(pieceInstanceId)
	if not pieceModel then
		BuildSelectionController.ClearSelection()
		return false
	end

	BuildState.SetSelectedPlacedPiece(pieceInstanceId)
	updateSelectionHighlight(pieceModel)
	return true
end

function BuildSelectionController.SelectFromRay(rayOrigin: Vector3, rayDirection: Vector3): string?
	if not BuildState.IsActive or not BuildState.IsEditingMode() then
		BuildSelectionController.ClearSelection()
		return nil
	end

	local editable = getEditableVehicleRoot()
	if not editable or isEditableVehicleHidden(editable) then
		BuildSelectionController.ClearSelection()
		return nil
	end

	_raycastParams.FilterDescendantsInstances = { editable }
	local hit = Workspace:Raycast(rayOrigin, rayDirection.Unit * GameConfig.Building.MaxRaycastDistance, _raycastParams)
	if not hit or not hit.Instance then
		BuildSelectionController.ClearSelection()
		return nil
	end

	local current: Instance? = hit.Instance
	while current and current ~= editable do
		if current:IsA("Model") and type(current:GetAttribute("PieceInstanceId")) == "string" then
			local pieceId = current:GetAttribute("PieceInstanceId") :: string
			BuildSelectionController.SelectPieceById(pieceId)
			return pieceId
		end
		current = current.Parent
	end

	BuildSelectionController.ClearSelection()
	return nil
end

function BuildSelectionController.DeleteSelectedPiece(
	customInvoke: BuildPlacementController.InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	if not BuildState.IsActive or not BuildState.IsEditingMode() or not BuildState.SelectedPlacedPieceId then
		BuildState.SetError("No hay ninguna pieza seleccionada para eliminar")
		return false, nil
	end

	local pieceId = BuildState.SelectedPlacedPieceId :: string
	if _pendingDeleteIds[pieceId] then
		-- Protección contra doble clic o eliminación duplicada mientras sigue en vuelo
		return false, nil
	end

	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	_deleteSeq += 1
	local localPlayer = Players.LocalPlayer
	local userId = if localPlayer then localPlayer.UserId else (BuildState.ExpectedOwnerUserId or 0)
	local clientOpId = `remove_{userId}_{_deleteSeq}`

	-- Ocultar de forma optimista guardando transparencias previas por si hay rollback
	local pieceModel = findPieceModelById(pieceId)
	local savedTransparencies: { [BasePart]: number } = {}
	if pieceModel then
		for _, desc in ipairs(pieceModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				savedTransparencies[desc] = desc.Transparency
				desc.Transparency = 1
			end
		end
	end

	_pendingDeleteIds[pieceId] = true

	local request: BuildProtocol.RemovePieceRequest = {
		Action = "RemovePiece",
		ClientOpId = clientOpId,
		PieceInstanceId = pieceId,
	}

	local ok, responseOrErr, timedOut = invokeWithTimeout(invoke, request, _operationTimeoutSeconds)
	_pendingDeleteIds[pieceId] = nil

	if timedOut then
		restoreTransparencies(savedTransparencies)
		BuildState.SetError(BuildProtocol.ErrorCodes.OperationTimeout)
		BuildPlacementController.SyncBlueprintFromServer(customInvoke)
		return false, nil
	end

	if not ok or type(responseOrErr) ~= "table" then
		restoreTransparencies(savedTransparencies)
		BuildState.SetError("Error de red al eliminar pieza")
		return false, nil
	end

	local response = responseOrErr :: BuildProtocol.BuildOperationResponse
	if response.Success then
		BuildSelectionController.ClearSelection()
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint)
		end
		BuildState.SetStatusMessage("Pieza eliminada")
		return true, response
	else
		restoreTransparencies(savedTransparencies)
		BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo eliminar la pieza")
		return false, response
	end
end

BuildState.SubscribeBlueprintReplaced(function()
	BuildSelectionController.ClearSelection()
	BuildSelectionController.ClearPendingDeletes()
end)

return BuildSelectionController
