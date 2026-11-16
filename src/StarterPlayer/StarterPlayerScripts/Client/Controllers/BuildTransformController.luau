--!strict
--[=[
	BuildTransformController
	Orquesta la sesión local de edición/transformación de una pieza colocada (Move / Rotate):
	- Maneja gizmos 3D interactivos (BuildMoveGizmo, BuildRotationGizmo), ajustes finos táctiles/teclado
	  (±0.01 studs en modo Libre, paso de Grid o incremento angular) y guías inteligentes.
	- Valida localmente límites, colisiones OBB/espaciales, conexiones y conectividad global del grafo
	  sin emitir tráfico de red por frame.
	- Al confirmar envía una única operación autoritativa `TransformPiece` con manejo optimista,
	  protección contra doble envío, timeout, rollback y resync automático vía `GetBlueprint`.
]=]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildSnapPolicy = require(ReplicatedStorage.Shared.Building.BuildSnapPolicy)
local BuildTransformMath = require(ReplicatedStorage.Shared.Building.BuildTransformMath)
local BuildAlignmentMath = require(ReplicatedStorage.Shared.Building.BuildAlignmentMath)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)

local BuildState = require(script.Parent.BuildState)
local BuildPreviewController = require(script.Parent.BuildPreviewController)
local BuildPlacementController = require(script.Parent.BuildPlacementController)
local BuildMoveGizmo = require(script.Parent.BuildMoveGizmo)
local BuildRotationGizmo = require(script.Parent.BuildRotationGizmo)
local BuildAlignmentGuides = require(script.Parent.BuildAlignmentGuides)

export type AxisName = "X" | "Y" | "Z"

type TransformSession = {
	PieceId: string,
	ItemId: string,
	BaseLocalCFrame: CFrame,
	WorkingLocalCFrame: CFrame,
	Size: Vector3,
	Attachments: { ConnectionMath.AttachmentSpec },
	PartBoxes: { VehicleTypes.PartBoxSpec }?,
	PreviewGhost: Model?,
	PreviewParts: { BasePart },
	LastColor: Color3?,
	PlacedModel: Model?,
	SavedTransparencies: { [BasePart]: number },
	DeltaDisplay: string,
	IsValid: boolean,
	Reason: string?,
	Detail: string?,
	AlignmentLocks: BuildAlignmentMath.AlignmentLockState,
}

local BuildTransformController = {}

local _session: TransformSession? = nil
local _isConfirmInFlight = false
local _transformSeq = 0
local _operationTimeoutSeconds: number = GameConfig.Building.OperationTimeoutSeconds
local _lastVisualLiftH: number? = nil
local _lastVisualLiftL: number? = nil

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

	local timer = task.delay(timeoutSeconds, function()
		if not finished then
			timedOut = true
			if coroutine.status(callerThread) == "suspended" then
				task.spawn(callerThread)
			end
		end
	end)

	task.spawn(function()
		local t0 = os.clock()
		local ok, res = pcall(invoke, request)
		if (os.clock() - t0) >= timeoutSeconds then
			timedOut = true
		end
		if timedOut then
			return
		end
		finished = true
		pcall(task.cancel, timer)
		callOk = ok
		callResult = res
		if coroutine.status(callerThread) == "suspended" then
			task.spawn(callerThread)
		end
	end)

	if not finished and not timedOut then
		coroutine.yield()
	end

	return callOk, callResult, timedOut
end

local function findPlacedPieceModel(pieceInstanceId: string): Model?
	local plotModel = BuildState.AssignedPlot
	if not plotModel then
		return nil
	end
	local dyn = plotModel:FindFirstChild(GameConfig.PlotContainers.Dynamic)
	local editable = dyn and dyn:FindFirstChild(GameConfig.Building.EditableVehicleName)
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

local function isTransformEditingBlocked(placedModel: Model?): boolean
	if not BuildState.IsEditingMode() then
		return true
	end
	local plotModel = BuildState.AssignedPlot
	if plotModel then
		local dyn = plotModel:FindFirstChild(GameConfig.PlotContainers.Dynamic)
		local editable = dyn and dyn:FindFirstChild(GameConfig.Building.EditableVehicleName)
		if editable and editable:GetAttribute("IsEditableHidden") == true then
			return true
		end
	end
	if placedModel then
		local curr: Instance? = placedModel.Parent
		while curr do
			if curr:IsA("Model") and curr:GetAttribute("IsEditableHidden") == true then
				return true
			end
			curr = curr.Parent
		end
	end
	return false
end

local function restoreDimmedModel(session: TransformSession)
	if not isTransformEditingBlocked(session.PlacedModel) then
		for part, origTransp in pairs(session.SavedTransparencies) do
			if part.Parent then
				part.Transparency = origTransp
			end
		end
	end
	table.clear(session.SavedTransparencies)
end

local function createTransformGhost(itemId: string): (Model?, { BasePart })
	local def = ItemRegistry.TryGet(itemId)
	if not def then
		return nil, {}
	end
	local previewRoot = ReplicatedStorage:FindFirstChild(GameConfig.Building.PreviewAssetsFolder)
	local template = ItemRegistry.ResolveModel(previewRoot, def)
	if not template then
		return nil, {}
	end

	local ghost = template:Clone()
	ghost.Name = `TransformGhost_{def.Id}`
	ghost:SetAttribute("IsTransformGhost", true)

	local parts: { BasePart } = {}
	for _, desc in ipairs(ghost:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
			desc.CanTouch = false
			desc.CanQuery = false
			desc.CastShadow = false
			if PhysicsService:IsCollisionGroupRegistered(GameConfig.Runtime.CollisionGroups.EditorGhost) then
				desc.CollisionGroup = GameConfig.Runtime.CollisionGroups.EditorGhost
			end
			desc.Transparency = GameConfig.Building.GhostTransparency
			desc.Material = Enum.Material.SmoothPlastic
			table.insert(parts, desc)
		elseif desc:IsA("Constraint") or desc:IsA("WeldConstraint") then
			desc.Enabled = false
		elseif desc:IsA("Script") or desc:IsA("LocalScript") then
			desc:Destroy()
		end
	end

	if ghost.PrimaryPart == nil and #parts > 0 then
		ghost.PrimaryPart = parts[1]
	end
	ghost.Parent = Workspace.CurrentCamera or Workspace
	return ghost, parts
end

local function applySessionGhostColor(session: TransformSession, isValid: boolean)
	local targetColor = if isValid then GameConfig.Building.ValidColor else GameConfig.Building.InvalidColor
	if session.LastColor == targetColor then
		return
	end
	session.LastColor = targetColor
	for _, part in ipairs(session.PreviewParts) do
		part.Color = targetColor
	end
end

local function evaluateAndSyncSession(session: TransformSession, deltaLabel: string?)
	local plotModel = BuildState.AssignedPlot
	local buildZone = BuildState.BuildZone
	if not plotModel or not buildZone then
		return
	end

	local effZoneCF = BuildState.GetEffectiveBuildZoneCFrame() or buildZone.CFrame
	local worldCF = effZoneCF:ToWorldSpace(session.WorkingLocalCFrame)
	if session.PreviewGhost and session.PreviewGhost.Parent then
		session.PreviewGhost:PivotTo(worldCF)
	end

	local existingSpecs, spatialIndex = BuildPreviewController.GetExistingSpecsAndIndex()
	local isValid, reason, detail = BuildPreviewController.ValidateCandidate(
		plotModel,
		buildZone,
		session.WorkingLocalCFrame,
		worldCF,
		session.Size,
		existingSpecs,
		spatialIndex,
		{
			ItemId = session.ItemId,
			Attachments = session.Attachments,
			PartBoxes = session.PartBoxes,
			ExcludePieceId = session.PieceId,
		}
	)

	session.IsValid = isValid
	session.Reason = reason
	session.Detail = detail
	if deltaLabel ~= nil then
		session.DeltaDisplay = deltaLabel
	end

	applySessionGhostColor(session, isValid)
	BuildState.SetTransformPreviewState(
		session.PieceId,
		session.BaseLocalCFrame,
		session.WorkingLocalCFrame,
		isValid,
		session.DeltaDisplay,
		reason,
		detail
	)
end

local function ensureSessionForSelectedPiece(): TransformSession?
	local pieceId = BuildState.SelectedPlacedPieceId
	if not pieceId or not BuildState.IsActive or not BuildState.IsEditingMode() then
		BuildTransformController.CancelSession()
		return nil
	end

	local piece = BuildState.GetPiece(pieceId)
	if not piece then
		BuildTransformController.CancelSession()
		return nil
	end

	local placedModelCheck = findPlacedPieceModel(pieceId)
	if isTransformEditingBlocked(placedModelCheck) then
		BuildTransformController.CancelSession()
		return nil
	end

	if _session and _session.PieceId == pieceId then
		-- Sincronizar si el servidor actualizó BaseLocalCFrame cuando no estamos arrastrando ni pendientes
		if not BuildTransformController.HasPendingModification() and (_session.BaseLocalCFrame.Position - piece.LocalCFrame.Position).Magnitude > 1e-4 then
			_session.BaseLocalCFrame = piece.LocalCFrame
			_session.WorkingLocalCFrame = piece.LocalCFrame
		end
		return _session
	end

	BuildTransformController.CancelSession()

	local size, atts, partBoxes = BuildPreviewController.GetItemGeometry(piece.ItemId)
	if not size or not atts then
		return nil
	end

	local ghost, ghostParts = createTransformGhost(piece.ItemId)
	local placedModel = findPlacedPieceModel(pieceId)
	local savedTransp: { [BasePart]: number } = {}
	if placedModel and ghost then
		for _, desc in ipairs(placedModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				savedTransp[desc] = desc.Transparency
				desc.Transparency = math.min(0.88, desc.Transparency + 0.55)
			end
		end
	end

	local newSession: TransformSession = {
		PieceId = pieceId,
		ItemId = piece.ItemId,
		BaseLocalCFrame = piece.LocalCFrame,
		WorkingLocalCFrame = piece.LocalCFrame,
		Size = size,
		Attachments = atts,
		PartBoxes = partBoxes,
		PreviewGhost = ghost,
		PreviewParts = ghostParts,
		LastColor = nil,
		PlacedModel = placedModel,
		SavedTransparencies = savedTransp,
		DeltaDisplay = "0.00",
		IsValid = true,
		Reason = nil,
		Detail = nil,
		AlignmentLocks = {},
	}
	_session = newSession
	evaluateAndSyncSession(newSession, "0.00")
	return newSession
end

function BuildTransformController._SetOperationTimeoutForTests(seconds: number)
	_operationTimeoutSeconds = math.max(0.05, seconds)
end

function BuildTransformController.HasActiveSession(): boolean
	return _session ~= nil
end

function BuildTransformController.HasPendingModification(): boolean
	if not _session then
		return false
	end
	local base = _session.BaseLocalCFrame
	local cur = _session.WorkingLocalCFrame
	if (base.Position - cur.Position).Magnitude > 1e-3 then
		return true
	end
	if base.RightVector:Dot(cur.RightVector) < 0.9999 or base.UpVector:Dot(cur.UpVector) < 0.9999 then
		return true
	end
	return false
end

function BuildTransformController.CancelSession()
	BuildMoveGizmo.EndDrag()
	BuildMoveGizmo.Hide()
	BuildRotationGizmo.EndDrag()
	BuildRotationGizmo.Hide()
	BuildAlignmentGuides.Hide()

	if _session then
		restoreDimmedModel(_session)
		if _session.PreviewGhost then
			_session.PreviewGhost:Destroy()
			_session.PreviewGhost = nil
		end
		table.clear(_session.PreviewParts)
		_session = nil
	end
	BuildState.ClearTransformSession()
end

function BuildTransformController.RevertToBase()
	BuildMoveGizmo.EndDrag()
	BuildRotationGizmo.EndDrag()
	if _session then
		_session.WorkingLocalCFrame = _session.BaseLocalCFrame
		table.clear(_session.AlignmentLocks)
		evaluateAndSyncSession(_session, "0.00")
	end
end

function BuildTransformController.UpdateVisuals(rayOriginWorld: Vector3?, rayDirWorld: Vector3?)
	if not BuildState.IsActive or not BuildState.IsEditingMode() or not BuildState.SelectedPlacedPieceId then
		_lastVisualLiftH = nil
		_lastVisualLiftL = nil
		if _session then
			BuildTransformController.CancelSession()
		else
			BuildMoveGizmo.Hide()
			BuildRotationGizmo.Hide()
		end
		return
	end

	local buildZone = BuildState.BuildZone
	if not buildZone then
		_lastVisualLiftH = nil
		_lastVisualLiftL = nil
		BuildTransformController.CancelSession()
		return
	end

	local session = ensureSessionForSelectedPiece()
	if not session then
		_lastVisualLiftH = nil
		_lastVisualLiftL = nil
		BuildMoveGizmo.Hide()
		BuildRotationGizmo.Hide()
		return
	end

	local liftOffset = BuildState.GetAssemblyOffset()
	local offsetCF = BuildState.GetAssemblyOffsetCFrame()
	if
		_lastVisualLiftH == nil
		or _lastVisualLiftL == nil
		or math.abs((_lastVisualLiftH :: number) - liftOffset.HeightOffset) > 1e-4
		or math.abs((_lastVisualLiftL :: number) - liftOffset.LateralOffset) > 1e-4
	then
		_lastVisualLiftH = liftOffset.HeightOffset
		_lastVisualLiftL = liftOffset.LateralOffset
		evaluateAndSyncSession(session, nil)
	end

	local tool = BuildState.ActiveTool
	if tool == GameConfig.Building.TransformTools.Move then
		BuildRotationGizmo.Hide()

		if BuildMoveGizmo.IsDragging() and rayOriginWorld and rayDirWorld then
			local rawLocalCF, _, deltaLabel = BuildMoveGizmo.UpdateDragFromRay(
				buildZone,
				rayOriginWorld,
				rayDirWorld,
				{
					PositionMode = BuildState.PositionMode,
					GridResolution = BuildState.GridResolution,
				},
				offsetCF
			)
			if rawLocalCF then
				local activeAxis = BuildMoveGizmo.GetActiveAxis()
				local moveAxisDir = if activeAxis == "X"
					then Vector3.xAxis
					elseif activeAxis == "Y" then Vector3.yAxis
					elseif activeAxis == "Z" then Vector3.zAxis
					else nil

				local existingSpecs, spatialIndex = BuildPreviewController.GetExistingSpecsAndIndex()
				local alignRes = BuildAlignmentMath.ComputeAlignments({
					CandidateLocalCFrame = rawLocalCF,
					CandidateItemId = session.ItemId,
					CandidateSize = session.Size,
					CandidateAttachments = session.Attachments,
					ExistingSpecs = existingSpecs,
					SpatialIndex = spatialIndex,
					SurfaceNormalLocal = Vector3.yAxis,
					FloorY = BuildState.GetEffectiveFloorY() or (-buildZone.Size.Y * 0.5),
					PositionMode = BuildState.PositionMode,
					ExcludePieceId = session.PieceId,
					MoveAxisLocal = moveAxisDir,
					SmartSnapEnabled = BuildState.SmartSnapEnabled,
					GuidesEnabled = BuildState.GuidesEnabled,
					ActiveLocks = session.AlignmentLocks,
				})
				session.AlignmentLocks = alignRes.UpdatedLocks
				session.WorkingLocalCFrame = alignRes.FinalLocalCFrame

				local netDelta = (session.WorkingLocalCFrame.Position - session.BaseLocalCFrame.Position)
				local scalarDelta = if moveAxisDir then netDelta:Dot(moveAxisDir) else netDelta.Magnitude
				local shownLabel = if activeAxis
					then `{string.format("%+.2f", scalarDelta)} st ({activeAxis})`
					else deltaLabel
				evaluateAndSyncSession(session, shownLabel)

				if BuildState.GuidesEnabled then
					BuildAlignmentGuides.Render(buildZone, alignRes.Guides, alignRes.Markers, offsetCF)
				else
					BuildAlignmentGuides.Hide()
				end
			end
		elseif rayOriginWorld and rayDirWorld then
			local ext = BuildRotation.GetRotatedExtents(session.Size, session.WorkingLocalCFrame.Rotation)
			BuildMoveGizmo.HitTestFromRay(buildZone, session.WorkingLocalCFrame.Position, ext, rayOriginWorld, rayDirWorld, offsetCF)
		end

		local ext = BuildRotation.GetRotatedExtents(session.Size, session.WorkingLocalCFrame.Rotation)
		BuildMoveGizmo.UpdateVisual(buildZone, session.WorkingLocalCFrame.Position, ext, nil, BuildState.ActiveMoveAxis, offsetCF)
	elseif tool == GameConfig.Building.TransformTools.Rotate then
		BuildMoveGizmo.Hide()
		BuildAlignmentGuides.Hide()

		if BuildRotationGizmo.IsDragging() and rayOriginWorld and rayDirWorld then
			local newLocalCF, _, angleLabel = BuildRotationGizmo.UpdateDragFromRay(
				buildZone,
				rayOriginWorld,
				rayDirWorld,
				{
					ItemId = session.ItemId,
					AngleIncrementDeg = BuildState.AngleIncrementDeg,
				},
				offsetCF
			)
			if newLocalCF then
				session.WorkingLocalCFrame = newLocalCF
				evaluateAndSyncSession(session, angleLabel)
			end
		elseif rayOriginWorld and rayDirWorld then
			local ext = BuildRotation.GetRotatedExtents(session.Size, session.WorkingLocalCFrame.Rotation)
			BuildRotationGizmo.HitTestFromRay(buildZone, session.WorkingLocalCFrame.Position, ext, rayOriginWorld, rayDirWorld, offsetCF)
		end

		local ext = BuildRotation.GetRotatedExtents(session.Size, session.WorkingLocalCFrame.Rotation)
		BuildRotationGizmo.UpdateVisual(buildZone, session.WorkingLocalCFrame.Position, ext, nil, BuildState.ActiveRotateAxis, offsetCF)
	else
		BuildMoveGizmo.Hide()
		BuildRotationGizmo.Hide()
		BuildAlignmentGuides.Hide()
	end
end

function BuildTransformController.TryBeginGizmoDragFromRay(rayOriginWorld: Vector3, rayDirWorld: Vector3): boolean
	if not BuildState.IsActive or not BuildState.SelectedPlacedPieceId then
		return false
	end
	local buildZone = BuildState.BuildZone
	if not buildZone then
		return false
	end
	local session = ensureSessionForSelectedPiece()
	if not session then
		return false
	end

	local ext = BuildRotation.GetRotatedExtents(session.Size, session.WorkingLocalCFrame.Rotation)
	local tool = BuildState.ActiveTool
	local offsetCF = BuildState.GetAssemblyOffsetCFrame()

	if tool == GameConfig.Building.TransformTools.Move then
		local hitAxis = BuildMoveGizmo.HitTestFromRay(buildZone, session.WorkingLocalCFrame.Position, ext, rayOriginWorld, rayDirWorld, offsetCF)
		if hitAxis then
			table.clear(session.AlignmentLocks)
			return BuildMoveGizmo.BeginDragFromRay(hitAxis, buildZone, session.WorkingLocalCFrame, rayOriginWorld, rayDirWorld, offsetCF)
		end
	elseif tool == GameConfig.Building.TransformTools.Rotate then
		local hitAxis = BuildRotationGizmo.HitTestFromRay(buildZone, session.WorkingLocalCFrame.Position, ext, rayOriginWorld, rayDirWorld, offsetCF)
		if hitAxis then
			return BuildRotationGizmo.BeginDragFromRay(hitAxis, buildZone, session.WorkingLocalCFrame, rayOriginWorld, rayDirWorld, session.ItemId, offsetCF)
		end
	end

	return false
end

function BuildTransformController.NudgeAlongAxis(axis: AxisName, direction: number, customStep: number?): boolean
	local session = ensureSessionForSelectedPiece()
	if not session then
		return false
	end

	local step = customStep
		or (if BuildState.PositionMode == GameConfig.Building.PositionModes.Free
			then GameConfig.Building.FreeFineStep
			else BuildSnapPolicy.NormalizeGridResolution(BuildState.GridResolution))
	local signedDelta = step * (if direction < 0 then -1 else 1)
	local dirVec = if axis == "X" then Vector3.xAxis elseif axis == "Y" then Vector3.yAxis else Vector3.zAxis

	session.WorkingLocalCFrame = BuildTransformMath.NudgeLocalCFrame(session.WorkingLocalCFrame, dirVec, signedDelta)
	local netDelta = (session.WorkingLocalCFrame.Position - session.BaseLocalCFrame.Position):Dot(dirVec)
	evaluateAndSyncSession(session, `{string.format("%+.2f", netDelta)} st ({axis})`)
	return true
end

function BuildTransformController.RotateAlongAxisStep(axis: AxisName, direction: number): boolean
	local session = ensureSessionForSelectedPiece()
	if not session then
		return false
	end

	local stepDeg = BuildSnapPolicy.GetEffectiveAngleIncrement(session.ItemId, BuildState.AngleIncrementDeg)
	local signedDeg = stepDeg * (if direction < 0 then -1 else 1)
	local newRot = BuildRotation.RotateAxisDegrees(session.WorkingLocalCFrame.Rotation, axis, signedDeg)
	session.WorkingLocalCFrame = CFrame.new(session.WorkingLocalCFrame.Position) * newRot

	local requested = BuildState.AngleIncrementDeg
	local label = if requested < stepDeg
		then `{axis}: {string.format("%+d°", signedDeg)} (mín {stepDeg}°)`
		else `{axis}: {string.format("%+d°", signedDeg)}`
	evaluateAndSyncSession(session, label)
	return true
end

function BuildTransformController.EndGizmoDrag(
	autoConfirm: boolean?,
	customInvoke: BuildPlacementController.InvokeHandler?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local wasMoving = BuildMoveGizmo.IsDragging()
	local wasRotating = BuildRotationGizmo.IsDragging()
	if not wasMoving and not wasRotating then
		return false, nil
	end

	BuildMoveGizmo.EndDrag()
	BuildRotationGizmo.EndDrag()
	BuildAlignmentGuides.Hide()

	if not _session then
		return false, nil
	end

	if autoConfirm ~= false then
		if not BuildTransformController.HasPendingModification() then
			evaluateAndSyncSession(_session, "0.00")
			return true, nil
		end
		if not _session.IsValid then
			local errReason = _session.Reason or "Posición inválida"
			BuildTransformController.RevertToBase()
			BuildState.SetError(errReason)
			return false, nil
		end
		return BuildTransformController.ConfirmTransform(customInvoke)
	end

	return true, nil
end

function BuildTransformController.ConfirmTransform(
	customInvoke: BuildPlacementController.InvokeHandler?,
	bypassClientValidationForTests: boolean?
): (boolean, BuildProtocol.BuildOperationResponse?)
	local session = _session
	if not session or not BuildState.IsActive then
		return false, nil
	end

	if _isConfirmInFlight then
		BuildState.SetError(BuildProtocol.ErrorCodes.DuplicateInFlight)
		return false, nil
	end

	if not BuildTransformController.HasPendingModification() then
		return true, nil
	end

	if not bypassClientValidationForTests and not session.IsValid then
		BuildState.SetError(session.Reason or "La transformación actual es inválida")
		return false, nil
	end

	local invoke = customInvoke or getDefaultInvokeHandler()
	if not invoke then
		BuildState.SetError("Servidor de construcción no disponible")
		return false, nil
	end

	_transformSeq += 1
	local localPlayer = Players.LocalPlayer
	local userId = if localPlayer then localPlayer.UserId else (BuildState.ExpectedOwnerUserId or 0)
	local clientOpId = `transform_{userId}_{_transformSeq}`

	_isConfirmInFlight = true
	BuildState.SetPendingOpCount(BuildState.PendingOpCount + 1)

	-- Mover visual local provisionalmente mientras viaja la respuesta
	local backupModelCF: CFrame? = nil
	if session.PlacedModel and BuildState.BuildZone then
		local effZoneCF = BuildState.GetEffectiveBuildZoneCFrame() or BuildState.BuildZone.CFrame
		backupModelCF = session.PlacedModel:GetPivot()
		session.PlacedModel:PivotTo(effZoneCF:ToWorldSpace(session.WorkingLocalCFrame))
	end

	local req: BuildProtocol.TransformPieceRequest = {
		Action = "TransformPiece",
		ClientOpId = clientOpId,
		PieceInstanceId = session.PieceId,
		LocalCFrame = session.WorkingLocalCFrame,
	}

	local ok, responseOrErr, timedOut = invokeWithTimeout(invoke, req, _operationTimeoutSeconds)
	_isConfirmInFlight = false
	BuildState.SetPendingOpCount(BuildState.PendingOpCount - 1)

	local function rollbackPlacedModel()
		if session.PlacedModel and backupModelCF then
			session.PlacedModel:PivotTo(backupModelCF)
		end
		session.WorkingLocalCFrame = session.BaseLocalCFrame
		evaluateAndSyncSession(session, "0.00")
	end

	if timedOut then
		rollbackPlacedModel()
		BuildState.SetError(BuildProtocol.ErrorCodes.OperationTimeout)
		BuildPlacementController.SyncBlueprintFromServer(customInvoke)
		return false, nil
	end

	if not ok or type(responseOrErr) ~= "table" then
		rollbackPlacedModel()
		BuildState.SetError("Error de red al transformar pieza")
		return false, nil
	end

	local response = responseOrErr :: BuildProtocol.BuildOperationResponse
	if response.Success and response.TransformedPiece then
		local updated = response.TransformedPiece
		session.BaseLocalCFrame = updated.LocalCFrame
		session.WorkingLocalCFrame = updated.LocalCFrame
		if session.PlacedModel and BuildState.BuildZone then
			local effZoneCF = BuildState.GetEffectiveBuildZoneCFrame() or BuildState.BuildZone.CFrame
			session.PlacedModel:PivotTo(effZoneCF:ToWorldSpace(updated.LocalCFrame))
		end
		if response.Blueprint then
			BuildState.ApplyAuthoritativeBlueprint(response.Blueprint)
		end
		evaluateAndSyncSession(session, "0.00")
		BuildState.SetStatusMessage("Pieza transformada")
		return true, response
	else
		rollbackPlacedModel()
		BuildState.SetError(response.ErrorMessage or response.ErrorCode or "No se pudo transformar la pieza")
		return false, response
	end
end

BuildState.SubscribeBlueprintReplaced(function()
	BuildTransformController.CancelSession()
end)

return BuildTransformController
