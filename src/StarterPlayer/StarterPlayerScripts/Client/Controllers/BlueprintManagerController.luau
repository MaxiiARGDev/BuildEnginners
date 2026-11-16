--!strict
--[=[
	BlueprintManagerController
	Controlador cliente para gestionar múltiples blueprints (crear, guardar, cargar,
	duplicar, renombrar, eliminar y listar), con protección contra operaciones pendientes,
	respuestas tardías fuera de orden y rollback limpio sobre BuildState.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)

local BuildState = require(script.Parent.BuildState)
local BuildPlacementController = require(script.Parent.BuildPlacementController)

export type InvokeHandler = BuildPlacementController.InvokeHandler

local BlueprintManagerController = {}

local _opSeq = 0
local _opInFlight: string? = nil
local _operationTimeoutSeconds = GameConfig.Building.OperationTimeoutSeconds

function BlueprintManagerController.IsBusy(): boolean
	return _opInFlight ~= nil
end

function BlueprintManagerController.GetActiveOperation(): string?
	return _opInFlight
end

local function makeBusyResponse(message: string?): BuildProtocol.BuildOperationResponse
	return {
		Success = false,
		ErrorCode = BuildProtocol.ErrorCodes.OperationInProgress,
		ErrorMessage = message or "Ya hay una operación de blueprint en curso. Esperá un momento.",
	}
end

local function makeValidationResponse(code: string, message: string): BuildProtocol.BuildOperationResponse
	return {
		Success = false,
		ErrorCode = code,
		ErrorMessage = message,
	}
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

local function cancelPendingEditorWork()
	BuildPlacementController.ClearPending()
	BuildState.ClearTransformSession()
	BuildState.SetSelectedPlacedPiece(nil)
	BuildState.SelectItem(nil)
end

local function applyLibraryMetadata(response: BuildProtocol.BuildOperationResponse)
	if response.WorkshopEpoch ~= nil then
		BuildState.SetWorkshopEpoch(response.WorkshopEpoch)
	end
	if
		response.Slots ~= nil
		or response.LegacyOverflow ~= nil
		or response.LegacyOverflowCount ~= nil
		or response.LoadedSlotIndex ~= nil
	then
		BuildState.SetSlotLibraryState(
			if response.Slots ~= nil then response.Slots else BuildState.BlueprintSlots,
			response.LoadedSlotIndex,
			response.HasUnsavedChanges,
			response.LegacyOverflowCount,
			response.LegacyOverflow
		)
	end
	if response.Blueprints ~= nil then
		BuildState.SetBlueprintLibraryState(response.Blueprints, response.HasUnsavedChanges, response.MaxBlueprints)
	end
	if (response :: any).Inventory ~= nil then
		BuildState.SetInventoryState((response :: any).Inventory)
	end
end

local function runExclusiveOp(
	opLabel: string,
	runner: (invoke: InvokeHandler) -> (boolean, BuildProtocol.BuildOperationResponse?),
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	if _opInFlight ~= nil then
		local busyResp = makeBusyResponse(`Operación en curso ({_opInFlight}); aguardá antes de ejecutar {opLabel}.`)
		BuildState.SetError(busyResp.ErrorMessage)
		return false, busyResp
	end

	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	_opInFlight = opLabel
	local ok, resultOk, resultResp = pcall(runner, invoke)
	_opInFlight = nil

	if not ok then
		BuildState.SetError("Error interno ejecutando operación de blueprint")
		return false, nil
	end

	return resultOk, resultResp
end

function BlueprintManagerController.RefreshSlots(
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		return false, nil
	end

	local epoch = BuildState.TransitionEpoch
	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.ListBlueprintSlots,
		ClientOpId = makeOpId("listslots"),
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		applyLibraryMetadata(response)
		return true, response
	end

	return false, response
end

function BlueprintManagerController.RefreshList(customInvoke: InvokeHandler?): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		return false, nil
	end

	local epoch = BuildState.TransitionEpoch
	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.ListBlueprints,
		ClientOpId = makeOpId("listbp"),
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		applyLibraryMetadata(response)
		return true, response
	end

	return false, response
end

function BlueprintManagerController.CreateBlueprint(
	name: string?,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	cancelPendingEditorWork()
	local epoch = BuildState.BeginBlueprintTransition()

	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.CreateBlueprint,
		ClientOpId = makeOpId("createbp"),
		Name = name,
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetError("Error de red o tiempo agotado al crear blueprint")
		BuildPlacementController.SyncBlueprintFromServer(customInvoke)
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success and response.Blueprint then
		BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		applyLibraryMetadata(response)
		BuildState.SetStatusMessage(`Nuevo blueprint creado: {response.Blueprint.Name}`)
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo crear el blueprint")
	return false, response
end

function BlueprintManagerController.SaveBlueprint(
	name: string?,
	saveAsNew: boolean?,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	local epoch = BuildState.TransitionEpoch
	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.SaveBlueprint,
		ClientOpId = makeOpId("savebp"),
		Name = name,
		SaveAsNew = saveAsNew,
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetError("Error de red al guardar blueprint")
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success and response.Blueprint then
		BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		applyLibraryMetadata(response)
		BuildState.SetStatusMessage(`Blueprint guardado: {response.Blueprint.Name}`)
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo guardar")
	return false, response
end

function BlueprintManagerController.LoadBlueprint(
	blueprintId: string,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	cancelPendingEditorWork()
	local epoch = BuildState.BeginBlueprintTransition()

	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.LoadBlueprint,
		ClientOpId = makeOpId("loadbp"),
		BlueprintId = blueprintId,
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetError("Error al cargar blueprint; resincronizando")
		BuildPlacementController.SyncBlueprintFromServer(customInvoke)
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success and response.Blueprint then
		BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		applyLibraryMetadata(response)
		BuildState.SetStatusMessage(`Blueprint cargado: {response.Blueprint.Name}`)
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo cargar el blueprint")
	return false, response
end

function BlueprintManagerController.DuplicateBlueprint(
	blueprintId: string,
	newName: string?,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.DuplicateBlueprint,
		ClientOpId = makeOpId("dupbp"),
		BlueprintId = blueprintId,
		Name = newName,
	}, _operationTimeoutSeconds)

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetError("Error al duplicar blueprint")
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		applyLibraryMetadata(response)
		local dupName = if response.DuplicatedBlueprint then response.DuplicatedBlueprint.Name else "Copia"
		BuildState.SetStatusMessage(`Blueprint duplicado: {dupName}`)
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo duplicar")
	return false, response
end

function BlueprintManagerController.RenameBlueprint(
	blueprintId: string,
	newName: string,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	local epoch = BuildState.TransitionEpoch
	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.RenameBlueprint,
		ClientOpId = makeOpId("renbp"),
		BlueprintId = blueprintId,
		Name = newName,
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetError("Error al renombrar blueprint")
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		end
		applyLibraryMetadata(response)
		BuildState.SetStatusMessage(`Blueprint renombrado`)
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo renombrar")
	return false, response
end

function BlueprintManagerController.DeleteBlueprint(
	blueprintId: string,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	local deletingActive = (BuildState.BlueprintId == blueprintId)
	if deletingActive then
		cancelPendingEditorWork()
	end
	local epoch = BuildState.BeginBlueprintTransition()

	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.DeleteBlueprint,
		ClientOpId = makeOpId("delbp"),
		BlueprintId = blueprintId,
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetError("Error al eliminar blueprint")
		BuildPlacementController.SyncBlueprintFromServer(customInvoke)
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		end
		applyLibraryMetadata(response)
		BuildState.SetStatusMessage("Blueprint eliminado")
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo eliminar")
	return false, response
end

function BlueprintManagerController.SelectPrimaryAssembly(
	groupId: string,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.SelectPrimaryAssembly,
		ClientOpId = makeOpId("selasm"),
		GroupId = groupId,
	}, _operationTimeoutSeconds)

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetError("Error al seleccionar ensamblaje primario")
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		end
		BuildState.SetStatusMessage(`Ensamblaje primario: {groupId}`)
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo seleccionar ensamblaje")
	return false, response
end

local function isValidSlotIndex(slotIndex: any): boolean
	return type(slotIndex) == "number"
		and slotIndex == math.floor(slotIndex)
		and slotIndex >= 1
		and slotIndex <= GameConfig.Blueprints.MaxSlots
end

local function executeSaveSlotInternal(
	invoke: InvokeHandler,
	slotIndex: number,
	name: string?,
	expectedRevision: number?
): (boolean, BuildProtocol.BuildOperationResponse?)
	if not isValidSlotIndex(slotIndex) then
		local resp = makeValidationResponse(
			BuildProtocol.ErrorCodes.InvalidSlotIndex,
			`Índice de slot inválido (1..{GameConfig.Blueprints.MaxSlots}).`
		)
		BuildState.SetError(resp.ErrorMessage)
		return false, resp
	end

	local epoch = BuildState.TransitionEpoch
	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.SaveBlueprintSlot,
		ClientOpId = makeOpId("saveslot"),
		SlotIndex = slotIndex,
		Name = name,
		ExpectedRevision = expectedRevision,
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetError("Error de conexión al guardar en el slot.")
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		end
		applyLibraryMetadata(response)
		local slotSummary = if response.Slots then response.Slots[slotIndex] else nil
		local savedName = if slotSummary and slotSummary.Name then slotSummary.Name else (`Slot {slotIndex}`)
		BuildState.SetStatusMessage(`Guardado en Slot {slotIndex}: {savedName}`)
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo guardar en el slot")
	return false, response
end

local function executeOverwriteSlotInternal(
	invoke: InvokeHandler,
	slotIndex: number,
	name: string?,
	confirmationStep: number,
	expectedSlotRevision: number?,
	expectedWorkshopRevision: number?
): (boolean, BuildProtocol.BuildOperationResponse?)
	if not isValidSlotIndex(slotIndex) then
		local resp = makeValidationResponse(
			BuildProtocol.ErrorCodes.InvalidSlotIndex,
			`Índice de slot inválido (1..{GameConfig.Blueprints.MaxSlots}).`
		)
		BuildState.SetError(resp.ErrorMessage)
		return false, resp
	end

	if confirmationStep ~= 2 then
		local resp = makeValidationResponse(
			BuildProtocol.ErrorCodes.ConfirmationRequired,
			"Se requiere confirmación en 2 pasos (ConfirmationStep = 2) para sobrescribir."
		)
		BuildState.SetError(resp.ErrorMessage)
		return false, resp
	end

	local epoch = BuildState.TransitionEpoch
	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.OverwriteBlueprintSlot,
		ClientOpId = makeOpId("ovwslot"),
		SlotIndex = slotIndex,
		Name = name,
		ConfirmationStep = 2,
		ExpectedSlotRevision = expectedSlotRevision,
		ExpectedWorkshopRevision = expectedWorkshopRevision,
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetError("Error de conexión al sobrescribir el slot.")
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		end
		applyLibraryMetadata(response)
		local slotSummary = if response.Slots then response.Slots[slotIndex] else nil
		local savedName = if slotSummary and slotSummary.Name then slotSummary.Name else (`Slot {slotIndex}`)
		BuildState.SetStatusMessage(`Slot {slotIndex} sobrescrito: {savedName}`)
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo sobrescribir el slot")
	return false, response
end

local function executeClearWorkshopInternal(
	invoke: InvokeHandler,
	expectedRevision: number?,
	expectedEpoch: number?
): (boolean, BuildProtocol.BuildOperationResponse?)
	BuildPlacementController.ClearPending()
	local epoch = BuildState.BeginBlueprintTransition()

	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.ClearWorkshop,
		ClientOpId = makeOpId("clearws"),
		ExpectedRevision = expectedRevision,
		ExpectedEpoch = expectedEpoch,
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		BuildState.SetError("Error de conexión al vaciar el taller; resincronizando")
		BuildPlacementController.SyncBlueprintFromServer(invoke)
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		cancelPendingEditorWork()
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
		end
		applyLibraryMetadata(response)
		BuildState.SetStatusMessage("Taller vaciado. Podés construir desde cero.")
		return true, response
	end

	BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo vaciar el taller")
	return false, response
end

function BlueprintManagerController.SaveBlueprintSlot(
	slotIndex: number,
	name: string?,
	customInvoke: InvokeHandler?,
	expectedRevision: number?
): (boolean, BuildProtocol.BuildOperationResponse?)
	return runExclusiveOp("SaveBlueprintSlot", function(invoke)
		return executeSaveSlotInternal(invoke, slotIndex, name, expectedRevision)
	end, customInvoke)
end

function BlueprintManagerController.OverwriteBlueprintSlot(
	slotIndex: number,
	name: string?,
	confirmationStep: number,
	customInvoke: InvokeHandler?,
	expectedSlotRevision: number?,
	expectedWorkshopRevision: number?
): (boolean, BuildProtocol.BuildOperationResponse?)
	return runExclusiveOp("OverwriteBlueprintSlot", function(invoke)
		return executeOverwriteSlotInternal(
			invoke,
			slotIndex,
			name,
			confirmationStep,
			expectedSlotRevision,
			expectedWorkshopRevision
		)
	end, customInvoke)
end

function BlueprintManagerController.LoadBlueprintSlot(
	slotIndex: number,
	confirmDiscardUnsaved: boolean?,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	return runExclusiveOp("LoadBlueprintSlot", function(invoke)
		if not isValidSlotIndex(slotIndex) then
			local resp = makeValidationResponse(
				BuildProtocol.ErrorCodes.InvalidSlotIndex,
				`Índice de slot inválido (1..{GameConfig.Blueprints.MaxSlots}).`
			)
			BuildState.SetError(resp.ErrorMessage)
			return false, resp
		end

		BuildPlacementController.ClearPending()
		local epoch = BuildState.BeginBlueprintTransition()

		local ok, res, timedOut = invokeWithTimeout(invoke, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = makeOpId("loadslot"),
			SlotIndex = slotIndex,
			ConfirmDiscardUnsaved = confirmDiscardUnsaved == true,
		}, _operationTimeoutSeconds)

		if BuildState.TransitionEpoch ~= epoch then
			return false, nil
		end

		if timedOut or not ok or type(res) ~= "table" then
			BuildState.SetError("Error de conexión al cargar el slot; resincronizando")
			BuildPlacementController.SyncBlueprintFromServer(invoke)
			return false, nil
		end

		local response = res :: BuildProtocol.BuildOperationResponse
		if response.Success and response.Blueprint then
			cancelPendingEditorWork()
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
			applyLibraryMetadata(response)
			BuildState.SetStatusMessage(`Slot {slotIndex} cargado al taller: {response.Blueprint.Name}`)
			return true, response
		end

		BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo cargar el slot")
		return false, response
	end, customInvoke)
end

function BlueprintManagerController.RenameBlueprintSlot(
	slotIndex: number,
	newName: string,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	return runExclusiveOp("RenameBlueprintSlot", function(invoke)
		if not isValidSlotIndex(slotIndex) then
			local resp = makeValidationResponse(
				BuildProtocol.ErrorCodes.InvalidSlotIndex,
				`Índice de slot inválido (1..{GameConfig.Blueprints.MaxSlots}).`
			)
			BuildState.SetError(resp.ErrorMessage)
			return false, resp
		end

		if type(newName) ~= "string" then
			local resp = makeValidationResponse(BuildProtocol.ErrorCodes.InvalidBlueprintName, "Nombre inválido.")
			BuildState.SetError(resp.ErrorMessage)
			return false, resp
		end

		local epoch = BuildState.TransitionEpoch
		local ok, res, timedOut = invokeWithTimeout(invoke, {
			Action = BuildProtocol.Actions.RenameBlueprintSlot,
			ClientOpId = makeOpId("renslot"),
			SlotIndex = slotIndex,
			Name = newName,
		}, _operationTimeoutSeconds)

		if BuildState.TransitionEpoch ~= epoch then
			return false, nil
		end

		if timedOut or not ok or type(res) ~= "table" then
			BuildState.SetError("Error de conexión al renombrar el slot.")
			return false, nil
		end

		local response = res :: BuildProtocol.BuildOperationResponse
		if response.Success then
			if response.Blueprint then
				BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
			end
			applyLibraryMetadata(response)
			BuildState.SetStatusMessage(`Slot {slotIndex} renombrado`)
			return true, response
		end

		BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo renombrar el slot")
		return false, response
	end, customInvoke)
end

function BlueprintManagerController.DeleteBlueprintSlot(
	slotIndex: number,
	confirmationName: string?,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	return runExclusiveOp("DeleteBlueprintSlot", function(invoke)
		if not isValidSlotIndex(slotIndex) then
			local resp = makeValidationResponse(
				BuildProtocol.ErrorCodes.InvalidSlotIndex,
				`Índice de slot inválido (1..{GameConfig.Blueprints.MaxSlots}).`
			)
			BuildState.SetError(resp.ErrorMessage)
			return false, resp
		end

		local epoch = BuildState.TransitionEpoch
		local ok, res, timedOut = invokeWithTimeout(invoke, {
			Action = BuildProtocol.Actions.DeleteBlueprintSlot,
			ClientOpId = makeOpId("delslot"),
			SlotIndex = slotIndex,
			ConfirmationName = confirmationName,
		}, _operationTimeoutSeconds)

		if BuildState.TransitionEpoch ~= epoch then
			return false, nil
		end

		if timedOut or not ok or type(res) ~= "table" then
			BuildState.SetError("Error de conexión al eliminar el slot.")
			return false, nil
		end

		local response = res :: BuildProtocol.BuildOperationResponse
		if response.Success then
			applyLibraryMetadata(response)
			BuildState.SetStatusMessage(`Slot {slotIndex} eliminado (el taller actual se conserva intacto).`)
			return true, response
		end

		BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo eliminar el slot")
		return false, response
	end, customInvoke)
end

function BlueprintManagerController.ClearWorkshop(
	customInvoke: InvokeHandler?,
	expectedRevision: number?,
	expectedEpoch: number?
): (boolean, BuildProtocol.BuildOperationResponse?)
	return runExclusiveOp("ClearWorkshop", function(invoke)
		return executeClearWorkshopInternal(invoke, expectedRevision, expectedEpoch)
	end, customInvoke)
end

function BlueprintManagerController.SaveAndClearWorkshop(
	slotIndex: number,
	mode: "Save" | "Overwrite",
	name: string?,
	confirmationStep: number?,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	return runExclusiveOp("SaveAndClearWorkshop", function(invoke)
		if mode ~= "Save" and mode ~= "Overwrite" then
			local resp = makeValidationResponse(
				BuildProtocol.ErrorCodes.InvalidPayload,
				"Modo inválido para guardar y vaciar taller."
			)
			BuildState.SetError(resp.ErrorMessage)
			return false, resp
		end

		local saveOk, saveResp: BuildProtocol.BuildOperationResponse?
		if mode == "Save" then
			saveOk, saveResp = executeSaveSlotInternal(invoke, slotIndex, name, nil)
		else
			saveOk, saveResp = executeOverwriteSlotInternal(invoke, slotIndex, name, confirmationStep or 0, nil, nil)
		end

		if not saveOk then
			return false, saveResp
		end

		local clearOk, clearResp = executeClearWorkshopInternal(invoke, nil, nil)
		if clearOk then
			BuildState.SetStatusMessage(`Vehículo guardado en Slot {slotIndex} y taller vaciado.`)
		end
		return clearOk, clearResp
	end, customInvoke)
end

function BlueprintManagerController.RecoverLegacyBlueprint(
	originalBlueprintId: string,
	targetSlotIndex: number,
	confirmationStep: number?,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	return runExclusiveOp("RecoverLegacyBlueprint", function(invoke)
		if not isValidSlotIndex(targetSlotIndex) then
			local resp = makeValidationResponse(
				BuildProtocol.ErrorCodes.InvalidSlotIndex,
				`Índice de slot destino inválido (1..{GameConfig.Blueprints.MaxSlots}).`
			)
			BuildState.SetError(resp.ErrorMessage)
			return false, resp
		end

		if type(originalBlueprintId) ~= "string" or #originalBlueprintId == 0 then
			local resp = makeValidationResponse(
				BuildProtocol.ErrorCodes.LegacyOverflowNotFound,
				"Identificador de blueprint heredado inválido."
			)
			BuildState.SetError(resp.ErrorMessage)
			return false, resp
		end

		local epoch = BuildState.TransitionEpoch
		local ok, res, timedOut = invokeWithTimeout(invoke, {
			Action = BuildProtocol.Actions.RecoverLegacyBlueprint,
			ClientOpId = makeOpId("recleg"),
			OriginalBlueprintId = originalBlueprintId,
			TargetSlotIndex = targetSlotIndex,
			ConfirmationStep = confirmationStep,
		}, _operationTimeoutSeconds)

		if BuildState.TransitionEpoch ~= epoch then
			return false, nil
		end

		if timedOut or not ok or type(res) ~= "table" then
			BuildState.SetError("Error de conexión al recuperar el blueprint heredado.")
			return false, nil
		end

		local response = res :: BuildProtocol.BuildOperationResponse
		if response.Success then
			applyLibraryMetadata(response)
			BuildState.SetStatusMessage(`Diseño heredado recuperado en Slot {targetSlotIndex}.`)
			return true, response
		end

		BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo recuperar el diseño heredado")
		return false, response
	end, customInvoke)
end

function BlueprintManagerController.RefreshInventory(
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		return false, nil
	end

	local epoch = BuildState.TransitionEpoch
	local ok, res, timedOut = invokeWithTimeout(invoke, {
		Action = BuildProtocol.Actions.GetInventory,
		ClientOpId = makeOpId("getinv"),
	}, _operationTimeoutSeconds)

	if BuildState.TransitionEpoch ~= epoch then
		return false, nil
	end

	if timedOut or not ok or type(res) ~= "table" then
		return false, nil
	end

	local response = res :: BuildProtocol.BuildOperationResponse
	if response.Success then
		applyLibraryMetadata(response)
		return true, response
	end

	return false, response
end

function BlueprintManagerController.SellInventoryItem(
	itemId: string,
	quantity: number?,
	itemInstanceId: string?,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	return runExclusiveOp("SellInventoryItem", function(invoke)
		if type(itemId) ~= "string" or #itemId == 0 then
			local resp = makeValidationResponse(BuildProtocol.ErrorCodes.InvalidPayload, "ItemId inválido.")
			BuildState.SetError(resp.ErrorMessage)
			return false, resp
		end

		local epoch = BuildState.TransitionEpoch
		local ok, res, timedOut = invokeWithTimeout(invoke, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = makeOpId("sellinv"),
			ItemId = itemId,
			Quantity = quantity,
			ItemInstanceId = itemInstanceId,
		}, _operationTimeoutSeconds)

		if BuildState.TransitionEpoch ~= epoch then
			return false, nil
		end

		if timedOut or not ok or type(res) ~= "table" then
			BuildState.SetError("Error de conexión al vender del inventario.")
			return false, nil
		end

		local response = res :: BuildProtocol.BuildOperationResponse
		applyLibraryMetadata(response)
		if response.Success then
			local sellRes = (response :: any).SellResult
			local name = ItemCatalog.GetDisplayName(itemId)
			local soldQty = if sellRes and type(sellRes.SoldQuantity) == "number" then sellRes.SoldQuantity else (quantity or 1)
			local note = if sellRes and type(sellRes.CurrencyNote) == "string" then sellRes.CurrencyNote else "Valor TBD"
			BuildState.SetStatusMessage(`Vendido: {soldQty}x {name} ({note}).`)
			return true, response
		end

		BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo completar la venta.")
		return false, response
	end, customInvoke)
end

function BlueprintManagerController.UnlinkInventoryFromBlueprints(
	itemId: string?,
	itemInstanceId: string?,
	targetSlotIndices: { number }?,
	confirmed: boolean?,
	customInvoke: InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	return runExclusiveOp("UnlinkInventoryFromBlueprints", function(invoke)
		local epoch = BuildState.TransitionEpoch
		local ok, res, timedOut = invokeWithTimeout(invoke, {
			Action = BuildProtocol.Actions.UnlinkInventoryFromBlueprints,
			ClientOpId = makeOpId("unlink"),
			ItemId = itemId,
			ItemInstanceId = itemInstanceId,
			TargetSlotIndices = targetSlotIndices,
			Confirmed = confirmed,
		}, _operationTimeoutSeconds)

		if BuildState.TransitionEpoch ~= epoch then
			return false, nil
		end

		if timedOut or not ok or type(res) ~= "table" then
			BuildState.SetError("Error de conexión al desvincular diseños.")
			return false, nil
		end

		local response = res :: BuildProtocol.BuildOperationResponse
		applyLibraryMetadata(response)
		if response.Success then
			if response.Blueprint then
				BuildState.ApplyAuthoritativeBlueprint(response.Blueprint, true)
			end
			local preview = (response :: any).UnlinkPreview
			local removedCount = if preview and type(preview.AffectedPieceCount) == "number" then preview.AffectedPieceCount else 0
			BuildState.SetStatusMessage(`Desvinculadas {removedCount} piezas afectadas conservando tus diseños.`)
			return true, response
		end

		if response.ErrorCode ~= BuildProtocol.ErrorCodes.ConfirmationRequired then
			BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo desvincular del inventario.")
		end
		return false, response
	end, customInvoke)
end

return BlueprintManagerController

