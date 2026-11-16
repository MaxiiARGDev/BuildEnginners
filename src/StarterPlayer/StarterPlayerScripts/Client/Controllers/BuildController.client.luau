--!strict
--[=[
	BuildController.client.luau
	Orquestador cliente único del editor de construcción (Fases 2.1 - 2.3.1).
	- Bucle RenderStepped unificado para preview de colocación, cuadrícula contextual visual,
	  guías de alineación inteligente y gizmos 3D (Traslación / Rotación).
	- Controles responsivos para PC y dispositivos táctiles (Grid/Libre, resoluciones 1/0.5/0.25/0.1,
	  Snap Inteligente, Guías, Mover/Rotar, incrementos 90°/45°/15°/1° y ajuste fino ±0.01).
	- Conecta BlueprintSyncEvent con recuperación automática vía GetBlueprint y limpieza integral.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)

local BuildState = require(script.Parent.BuildState)
local BuildPreviewController = require(script.Parent.BuildPreviewController)
local BuildPlacementController = require(script.Parent.BuildPlacementController)
local BuildSelectionController = require(script.Parent.BuildSelectionController)
local BuildTransformController = require(script.Parent.BuildTransformController)
local BuildMoveGizmo = require(script.Parent.BuildMoveGizmo)
local BuildRotationGizmo = require(script.Parent.BuildRotationGizmo)
local BuildInputController = require(script.Parent.BuildInputController)

local localPlayer = Players.LocalPlayer

local _renderConnection: RBXScriptConnection? = nil
local _lifecycleConnections: { RBXScriptConnection } = {}
local _unsubBuildState: (() -> ())? = nil
local _unsubBlueprintReplaced: (() -> ())? = nil
local _uiScale: UIScale? = nil
local _itemButtons: { [string]: TextButton } = {}
local _gridResButtons: { [number]: TextButton } = {}
local _angleButtons: { [number]: TextButton } = {}
local _modeToggleButton: TextButton? = nil
local _smartSnapButton: TextButton? = nil
local _faceSnapButton: TextButton? = nil
local _guidesButton: TextButton? = nil
local _toolPlaceButton: TextButton? = nil
local _toolMoveButton: TextButton? = nil
local _toolRotateButton: TextButton? = nil
local _confirmTransformButton: TextButton? = nil
local _touchBarFrame: Frame? = nil
local _toggleButton: TextButton? = nil
local _editorPanel: Frame? = nil
local _statusLabel: TextLabel? = nil
local _coordsLabel: TextLabel? = nil
local _lastPrimaryActionAt = 0

local function stopEditorLoop()
	if _renderConnection then
		_renderConnection:Disconnect()
		_renderConnection = nil
	end
end

local function updateEditorStep()
	if not BuildState.IsActive then
		if BuildPreviewController.GetCurrentGhost() ~= nil then
			BuildPreviewController.DestroyGhost()
		else
			BuildPreviewController.HideVisualHelpers()
		end
		BuildTransformController.CancelSession()
		stopEditorLoop()
		return
	end

	local origin, direction = BuildInputController.GetPointerRay()

	if BuildState.SelectedItemId ~= nil then
		if BuildTransformController.HasActiveSession() then
			BuildTransformController.CancelSession()
		else
			BuildMoveGizmo.Hide()
			BuildRotationGizmo.Hide()
		end
		if origin and direction then
			BuildPreviewController.UpdateFromRay(origin, direction)
		end
	elseif BuildState.SelectedPlacedPieceId ~= nil then
		if BuildPreviewController.GetCurrentGhost() ~= nil then
			BuildPreviewController.DestroyGhost()
		end
		BuildTransformController.UpdateVisuals(origin, direction)
	else
		if BuildPreviewController.GetCurrentGhost() ~= nil then
			BuildPreviewController.DestroyGhost()
		else
			BuildPreviewController.HideVisualHelpers()
		end
		if BuildTransformController.HasActiveSession() then
			BuildTransformController.CancelSession()
		else
			BuildMoveGizmo.Hide()
			BuildRotationGizmo.Hide()
		end
	end
end

local function ensureEditorLoop()
	if _renderConnection then
		return
	end
	_renderConnection = RunService.RenderStepped:Connect(updateEditorStep)
	updateEditorStep()
end

local function teardownEditorVisuals()
	BuildTransformController.CancelSession()
	BuildSelectionController.ClearSelection()
	BuildSelectionController.ClearPendingDeletes()
	BuildPlacementController.ClearPending()
	BuildPreviewController.DestroyGhost()
	BuildMoveGizmo.Destroy()
	BuildRotationGizmo.Destroy()
	stopEditorLoop()
end

local function closeEditorCleanly()
	teardownEditorVisuals()
	BuildState.SetActiveTool("None")
	BuildState.SetActive(false)
end

local function refreshAssignedPlot(): boolean
	local prevPlot = BuildState.AssignedPlot
	local prevBuildZone = BuildState.BuildZone
	local plotModel, buildZone = BuildState.ResolvePlayerPlot(localPlayer)
	if prevPlot ~= plotModel then
		if BuildState.IsActive then
			closeEditorCleanly()
		end
		BuildPreviewController.InvalidatePlotCache()
	end
	BuildState.SetPlot(plotModel, buildZone)
	if plotModel and buildZone and (prevPlot ~= plotModel or prevBuildZone == nil) then
		task.spawn(function()
			BuildPlacementController.SyncBlueprintFromServer()
		end)
	end
	return plotModel ~= nil and buildZone ~= nil
end

local function toggleEditor()
	if not BuildState.IsEditingMode() then
		if BuildState.IsActive then
			closeEditorCleanly()
		end
		BuildState.SetError("No podés abrir el editor mientras el vehículo está activo")
		return
	end

	if BuildState.IsActive then
		closeEditorCleanly()
		return
	end

	local character = localPlayer.Character
	if not character or not character.Parent then
		BuildState.SetError("CharacterNotReady")
		return
	end

	if not refreshAssignedPlot() then
		BuildState.SetError("NoAssignedPlot")
		return
	end

	task.spawn(function()
		BuildPlacementController.SyncBlueprintFromServer()
	end)

	local ok = BuildState.SetActive(true)
	if ok then
		ensureEditorLoop()
	end
end

local function selectItem(itemId: string)
	if not BuildState.IsActive then
		return
	end
	BuildTransformController.CancelSession()
	BuildSelectionController.ClearSelection()
	BuildState.SetActiveTool("None")

	if BuildState.SelectedItemId == itemId then
		BuildState.ClearSelection()
		BuildPreviewController.DestroyGhost()
		return
	end

	BuildState.SelectItem(itemId)
	local ghost, err = BuildPreviewController.EnsureGhostForItem(itemId)
	if not ghost then
		BuildState.SetError(err)
		return
	end
	ensureEditorLoop()
	updateEditorStep()
end

local function activateTransformTool(tool: "None" | "Move" | "Rotate")
	if not BuildState.IsActive then
		return
	end
	if tool == "None" then
		BuildTransformController.CancelSession()
		BuildState.SetActiveTool("None")
		return
	end

	BuildState.SelectItem(nil)
	BuildPreviewController.DestroyGhost()

	if BuildState.ActiveTool == tool then
		BuildState.SetActiveTool("None")
		BuildTransformController.CancelSession()
		return
	end

	BuildState.SetActiveTool(tool)
	if not BuildState.SelectedPlacedPieceId and #BuildState.BlueprintPieces > 0 then
		BuildState.SetStatusMessage(`Herramienta {tool}: hacé clic sobre una pieza colocada`)
	end
	ensureEditorLoop()
	updateEditorStep()
end

local function handlePrimaryAction()
	if not BuildState.IsActive then
		return
	end

	local now = os.clock()
	if now - _lastPrimaryActionAt < GameConfig.Building.ClickDebounceSeconds then
		return
	end
	_lastPrimaryActionAt = now

	if BuildState.SelectedItemId ~= nil then
		updateEditorStep()
		task.spawn(function()
			BuildPlacementController.PlaceCurrentPiece()
			updateEditorStep()
		end)
		return
	end

	local origin, direction = BuildInputController.GetPointerRay()
	if origin and direction then
		if BuildTransformController.TryBeginGizmoDragFromRay(origin, direction) then
			return
		end
		BuildTransformController.CancelSession()
		BuildSelectionController.SelectFromRay(origin, direction)
		updateEditorStep()
	end
end

local function handlePrimaryRelease()
	if not BuildState.IsActive then
		return
	end
	if BuildMoveGizmo.IsDragging() or BuildRotationGizmo.IsDragging() then
		task.spawn(function()
			BuildTransformController.EndGizmoDrag(true)
			updateEditorStep()
		end)
	end
end

local function handleRotateInput(axis: "X" | "Y" | "Z")
	if not BuildState.IsActive then
		return
	end
	if BuildState.SelectedItemId then
		BuildState.RotateAxis(axis, 1)
		updateEditorStep()
	elseif BuildState.SelectedPlacedPieceId then
		if BuildState.ActiveTool == "None" then
			BuildState.SetActiveTool("Rotate")
		end
		BuildTransformController.RotateAlongAxisStep(axis, 1)
		updateEditorStep()
	end
end

local function handleConfirmTransform()
	if not BuildState.IsActive then
		return
	end
	if BuildTransformController.HasPendingModification() then
		task.spawn(function()
			BuildTransformController.ConfirmTransform()
			updateEditorStep()
		end)
	end
end

local function handleDeleteAction()
	if not BuildState.IsActive then
		return
	end
	BuildTransformController.CancelSession()
	task.spawn(function()
		BuildSelectionController.DeleteSelectedPiece()
	end)
end

local function cancelOrExit()
	if not BuildState.IsActive then
		return
	end
	if BuildTransformController.HasPendingModification() then
		BuildTransformController.RevertToBase()
	elseif BuildState.SelectedItemId ~= nil then
		BuildState.ClearSelection()
		BuildPreviewController.DestroyGhost()
	elseif BuildState.SelectedPlacedPieceId ~= nil then
		BuildTransformController.CancelSession()
		BuildSelectionController.ClearSelection()
	elseif BuildState.ActiveTool ~= "None" then
		BuildState.SetActiveTool("None")
	else
		closeEditorCleanly()
	end
end

local function updateResponsiveScale()
	if not _uiScale then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local vw = camera.ViewportSize.X
	if vw > 0 and vw < 936 then
		_uiScale.Scale = math.clamp(vw / 940, 0.50, 0.96)
	else
		_uiScale.Scale = 1
	end
end

local function updateUI()
	updateResponsiveScale()

	local editingAllowed = BuildState.IsEditingMode()
	if not editingAllowed then
		if
			BuildPreviewController.GetCurrentGhost() ~= nil
			or BuildTransformController.HasActiveSession()
			or _renderConnection ~= nil
		then
			teardownEditorVisuals()
		end
	end

	if _toggleButton then
		if not editingAllowed then
			_toggleButton.Active = false
			_toggleButton.Text = "En Vehículo"
			_toggleButton.BackgroundColor3 = Color3.fromRGB(95, 102, 118)
		else
			_toggleButton.Active = true
			_toggleButton.Text = if BuildState.IsActive then "Cerrar Editor [B]" else "Modo Construcción [B]"
			_toggleButton.BackgroundColor3 = if BuildState.IsActive
				then Color3.fromRGB(200, 70, 70)
				else Color3.fromRGB(45, 130, 210)
		end
	end

	if _editorPanel then
		_editorPanel.Visible = editingAllowed and BuildState.IsActive
	end

	for itemId, btn in pairs(_itemButtons) do
		local isSelected = BuildState.SelectedItemId == itemId
		local entry = ItemCatalog.GetEntry(itemId)
		local baseLabel = if entry then `{entry.DisplayName} [{entry.CategoryDisplayName}]` else itemId
		local invEntry = BuildState.GetInventoryEntry(itemId)
		local avail = BuildState.GetAvailableQuantity(itemId)
		if invEntry and avail ~= nil then
			btn.Text = `{baseLabel} ({avail}/{invEntry.OwnedQuantity})`
			if isSelected then
				btn.BackgroundColor3 = Color3.fromRGB(60, 160, 95)
				btn.TextColor3 = Color3.fromRGB(245, 250, 255)
			elseif avail <= 0 then
				btn.BackgroundColor3 = Color3.fromRGB(58, 42, 46)
				btn.TextColor3 = Color3.fromRGB(190, 162, 168)
			else
				btn.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
				btn.TextColor3 = Color3.fromRGB(240, 240, 245)
			end
		else
			btn.Text = baseLabel
			btn.BackgroundColor3 = if isSelected
				then Color3.fromRGB(60, 160, 95)
				else Color3.fromRGB(45, 48, 58)
			btn.TextColor3 = Color3.fromRGB(240, 240, 245)
		end
	end

	local isFree = BuildState.PositionMode == GameConfig.Building.PositionModes.Free
	if _modeToggleButton then
		_modeToggleButton.Text = if isFree then "Modo: LIBRE [F]" else "Modo: GRID [F]"
		_modeToggleButton.BackgroundColor3 = if isFree
			then Color3.fromRGB(165, 105, 40)
			else Color3.fromRGB(48, 118, 175)
	end

	for res, btn in pairs(_gridResButtons) do
		local active = (not isFree) and math.abs(BuildState.GridResolution - res) < 1e-4
		btn.BackgroundColor3 = if active then Color3.fromRGB(65, 150, 220) else Color3.fromRGB(48, 53, 64)
		btn.TextColor3 = if isFree then Color3.fromRGB(150, 155, 165) else Color3.fromRGB(240, 240, 245)
	end

	for deg, btn in pairs(_angleButtons) do
		local active = math.abs(BuildState.AngleIncrementDeg - deg) < 1e-4
		btn.BackgroundColor3 = if active then Color3.fromRGB(130, 105, 200) else Color3.fromRGB(48, 53, 64)
	end

	if _smartSnapButton then
		_smartSnapButton.Text = if BuildState.SmartSnapEnabled then "Snap: ON [J]" else "Snap: OFF [J]"
		_smartSnapButton.BackgroundColor3 = if BuildState.SmartSnapEnabled
			then Color3.fromRGB(55, 145, 95)
			else Color3.fromRGB(70, 72, 82)
	end

	if _faceSnapButton then
		_faceSnapButton.Text = if BuildState.FaceSnapEnabled then "FaceSnap: ON [K]" else "FaceSnap: OFF [K]"
		_faceSnapButton.BackgroundColor3 = if BuildState.FaceSnapEnabled
			then Color3.fromRGB(45, 165, 130)
			else Color3.fromRGB(70, 72, 82)
	end

	if _guidesButton then
		_guidesButton.Text = if BuildState.GuidesEnabled then "Guías: ON [H]" else "Guías: OFF [H]"
		_guidesButton.BackgroundColor3 = if BuildState.GuidesEnabled
			then Color3.fromRGB(55, 130, 155)
			else Color3.fromRGB(70, 72, 82)
	end

	if _toolPlaceButton then
		local placing = BuildState.SelectedItemId ~= nil and BuildState.ActiveTool == "None"
		_toolPlaceButton.BackgroundColor3 = if placing then Color3.fromRGB(60, 160, 95) else Color3.fromRGB(52, 58, 70)
	end
	if _toolMoveButton then
		local moving = BuildState.ActiveTool == "Move"
		_toolMoveButton.BackgroundColor3 = if moving then Color3.fromRGB(205, 125, 45) else Color3.fromRGB(52, 58, 70)
	end
	if _toolRotateButton then
		local rotating = BuildState.ActiveTool == "Rotate"
		_toolRotateButton.BackgroundColor3 = if rotating then Color3.fromRGB(145, 90, 205) else Color3.fromRGB(52, 58, 70)
	end

	local hasPendingTransform = BuildTransformController.HasPendingModification()
	if _confirmTransformButton then
		_confirmTransformButton.Visible = BuildState.SelectedPlacedPieceId ~= nil
		_confirmTransformButton.BackgroundColor3 = if hasPendingTransform and BuildState.TransformIsValid
			then Color3.fromRGB(55, 165, 90)
			else Color3.fromRGB(68, 74, 88)
	end

	if _touchBarFrame then
		_touchBarFrame.Visible = BuildState.IsActive and (BuildState.SelectedPlacedPieceId ~= nil or BuildState.SelectedItemId ~= nil)
	end

	if _coordsLabel then
		local activeCF = BuildState.TransformPreviewLocalCFrame or BuildState.LastSnappedLocalCFrame
		if activeCF then
			local p = activeCF.Position
			local deltaStr = if hasPendingTransform and BuildState.TransformDeltaDisplay and BuildState.TransformDeltaDisplay ~= "0.00"
				then ` | Δ {BuildState.TransformDeltaDisplay}`
				else ""
			local resStr = if isFree then "0.01" else tostring(BuildState.GridResolution)
			_coordsLabel.Text = `Pos: ({string.format("%.2f, %.2f, %.2f", p.X, p.Y, p.Z)}) | Paso: {resStr} | Áng: {BuildState.AngleIncrementDeg}°{deltaStr}`
		else
			local resStr = if isFree then "0.01" else tostring(BuildState.GridResolution)
			_coordsLabel.Text = `Pos: (--, --, --) | Paso: {resStr} | Áng: {BuildState.AngleIncrementDeg}°`
		end
	end

	if _statusLabel then
		local plotName = if BuildState.AssignedPlot then BuildState.AssignedPlot.Name else "Sin base"
		local pieceCount = #BuildState.BlueprintPieces
		local syncSuffix = if BuildState.PendingOpCount > 0 then ` | Sincronizando ({BuildState.PendingOpCount})...` else ""
		if BuildState.LastError then
			_statusLabel.Text = `Base: {plotName} ({pieceCount} pzs) | Error: {BuildState.LastError}{syncSuffix}`
			_statusLabel.TextColor3 = Color3.fromRGB(255, 110, 110)
		elseif BuildState.SelectedPlacedPieceId then
			local toolName = BuildState.ActiveTool
			if hasPendingTransform then
				local valText = if BuildState.TransformIsValid then "VÁLIDO [Confirmar/Enter]" else `INVÁLIDO ({BuildState.ValidationReason or "Error"})`
				_statusLabel.Text = `Base: {plotName} | Editando ({toolName}): {valText}{syncSuffix}`
				_statusLabel.TextColor3 = if BuildState.TransformIsValid then Color3.fromRGB(95, 235, 130) else Color3.fromRGB(255, 115, 115)
			else
				_statusLabel.Text = `Base: {plotName} ({pieceCount} pzs) | Sel: {BuildState.SelectedPlacedPieceId} [{toolName}] (Del/Mover/Rotar){syncSuffix}`
				_statusLabel.TextColor3 = Color3.fromRGB(255, 210, 90)
			end
		elseif BuildState.SelectedItemId then
			local selItemId = BuildState.SelectedItemId
			local selDisplay = ItemCatalog.GetDisplayName(selItemId)
			local avail = BuildState.GetAvailableQuantity(selItemId)
			local stockSuffix = if avail ~= nil then ` (Disp: {avail})` else ""
			local faceSuffix = if BuildState.FaceSnapTarget
				then ` [FaceSnap:{BuildState.FaceSnapTarget.TargetFaceId}]`
				else ""
			local validityText = if avail ~= nil and avail <= 0
				then "SIN STOCK EN INVENTARIO"
				elseif BuildState.IsValidPlacement then `VÁLIDO{faceSuffix} [Clic/Colocar]`
				else `INVÁLIDO ({BuildState.ValidationReason or "Fuera de zona"}){faceSuffix}`
			_statusLabel.Text = `Base: {plotName} ({pieceCount} pzs) | {selDisplay}{stockSuffix} | {validityText}{syncSuffix}`
			_statusLabel.TextColor3 = if (avail ~= nil and avail <= 0)
				then Color3.fromRGB(255, 130, 130)
				elseif BuildState.IsValidPlacement then Color3.fromRGB(95, 235, 130)
				else Color3.fromRGB(255, 110, 110)
		elseif BuildState.StatusMessage then
			_statusLabel.Text = `Base: {plotName} ({pieceCount} pzs) | {BuildState.StatusMessage}{syncSuffix}`
			_statusLabel.TextColor3 = Color3.fromRGB(130, 220, 255)
		else
			_statusLabel.Text = `Base: {plotName} ({pieceCount} pzs) | Elegí pieza o hacé clic en una colocada para editar/eliminar{syncSuffix}`
			_statusLabel.TextColor3 = Color3.fromRGB(220, 225, 235)
		end
	end
end

local function createButton(parent: Instance, name: string, text: string, width: number, height: number, order: number, onClick: () -> ()): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.LayoutOrder = order
	btn.Size = UDim2.new(0, width, 0, height)
	btn.BackgroundColor3 = Color3.fromRGB(52, 58, 70)
	btn.TextColor3 = Color3.fromRGB(240, 240, 245)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 11
	btn.Text = text
	btn.AutoButtonColor = true

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn

	btn.Activated:Connect(onClick)
	btn.Parent = parent
	return btn
end

local function buildUI()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("BuildEditorGui")
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BuildEditorGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false

	local toggleBtn = Instance.new("TextButton")
	toggleBtn.Name = "ToggleBuildButton"
	toggleBtn.Size = UDim2.new(0, 190, 0, 40)
	toggleBtn.Position = UDim2.new(0, 16, 0, 16)
	toggleBtn.BackgroundColor3 = Color3.fromRGB(45, 130, 210)
	toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggleBtn.Font = Enum.Font.GothamBold
	toggleBtn.TextSize = 14
	toggleBtn.Text = "Modo Construcción [B]"
	toggleBtn.Parent = screenGui

	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(0, 8)
	toggleCorner.Parent = toggleBtn
	toggleBtn.Activated:Connect(toggleEditor)
	_toggleButton = toggleBtn

	local panel = Instance.new("Frame")
	panel.Name = "EditorPanel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Size = UDim2.new(0, 916, 0, 248)
	panel.Position = UDim2.new(0.5, 0, 1, -12)
	panel.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
	panel.BackgroundTransparency = 0.08
	panel.Visible = false
	panel.Parent = screenGui

	local scale = Instance.new("UIScale")
	scale.Parent = panel
	_uiScale = scale

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 10)
	panelCorner.Parent = panel
	_editorPanel = panel

	-- Fila 1: Estado y coordenadas en vivo
	local status = Instance.new("TextLabel")
	status.Name = "StatusLabel"
	status.Size = UDim2.new(1, -24, 0, 20)
	status.Position = UDim2.new(0, 12, 0, 6)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.GothamMedium
	status.TextSize = 12
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextColor3 = Color3.fromRGB(220, 225, 235)
	status.Text = "Base: --"
	status.Parent = panel
	_statusLabel = status

	local coords = Instance.new("TextLabel")
	coords.Name = "CoordsLabel"
	coords.Size = UDim2.new(1, -24, 0, 18)
	coords.Position = UDim2.new(0, 12, 0, 26)
	coords.BackgroundTransparency = 1
	coords.Font = Enum.Font.Code
	coords.TextSize = 11
	coords.TextXAlignment = Enum.TextXAlignment.Left
	coords.TextColor3 = Color3.fromRGB(165, 210, 255)
	coords.Text = "Pos: (--, --, --)"
	coords.Parent = panel
	_coordsLabel = coords

	-- Fila 2: Barra de precisión (Grid/Libre, Resoluciones, Snap, Guías, Herramientas y Ángulos)
	local precisionBar = Instance.new("Frame")
	precisionBar.Name = "PrecisionBar"
	precisionBar.Size = UDim2.new(1, -24, 0, 32)
	precisionBar.Position = UDim2.new(0, 12, 0, 48)
	precisionBar.BackgroundTransparency = 1
	precisionBar.Parent = panel

	local precLayout = Instance.new("UIListLayout")
	precLayout.FillDirection = Enum.FillDirection.Horizontal
	precLayout.Padding = UDim.new(0, 4)
	precLayout.SortOrder = Enum.SortOrder.LayoutOrder
	precLayout.Parent = precisionBar

	_modeToggleButton = createButton(precisionBar, "ModeToggleButton", "Modo: GRID [F]", 94, 28, 1, function()
		BuildState.TogglePositionMode()
		updateEditorStep()
	end)

	table.clear(_gridResButtons)
	for i, res in ipairs(GameConfig.Building.GridResolutions) do
		local resBtn = createButton(precisionBar, `GridBtn_{res}`, `{res}`, 34, 28, 10 + i, function()
			BuildState.SetPositionMode("Grid")
			BuildState.SetGridResolution(res)
			updateEditorStep()
		end)
		_gridResButtons[res] = resBtn
	end

	_smartSnapButton = createButton(precisionBar, "SmartSnapButton", "Snap: ON [J]", 78, 28, 20, function()
		BuildState.SetSmartSnapEnabled(not BuildState.SmartSnapEnabled)
		updateEditorStep()
	end)

	_faceSnapButton = createButton(precisionBar, "FaceSnapButton", "FaceSnap: ON [K]", 104, 28, 21, function()
		BuildState.SetFaceSnapEnabled(not BuildState.FaceSnapEnabled)
		updateEditorStep()
	end)

	_guidesButton = createButton(precisionBar, "GuidesButton", "Guías: ON [H]", 78, 28, 22, function()
		BuildState.SetGuidesEnabled(not BuildState.GuidesEnabled)
		updateEditorStep()
	end)

	_toolPlaceButton = createButton(precisionBar, "ToolPlaceButton", "Colocar", 56, 28, 30, function()
		activateTransformTool("None")
	end)
	_toolMoveButton = createButton(precisionBar, "ToolMoveButton", "Mover [G]", 66, 28, 31, function()
		activateTransformTool("Move")
	end)
	_toolRotateButton = createButton(precisionBar, "ToolRotateButton", "Rotar [V]", 66, 28, 32, function()
		activateTransformTool("Rotate")
	end)

	table.clear(_angleButtons)
	for i, deg in ipairs(GameConfig.Building.AngleIncrementsDeg) do
		local angBtn = createButton(precisionBar, `AngleBtn_{deg}`, `{deg}°`, 34, 28, 40 + i, function()
			BuildState.SetAngleIncrementDeg(deg)
		end)
		_angleButtons[deg] = angBtn
	end

	-- Fila 3: Catálogo de piezas (ScrollingFrame para soportar las 14+ piezas sin desbordar)
	local itemsContainer = Instance.new("ScrollingFrame")
	itemsContainer.Name = "ItemsContainer"
	itemsContainer.Size = UDim2.new(1, -24, 0, 74)
	itemsContainer.Position = UDim2.new(0, 12, 0, 84)
	itemsContainer.BackgroundTransparency = 1
	itemsContainer.BorderSizePixel = 0
	itemsContainer.CanvasSize = UDim2.fromOffset(0, 0)
	itemsContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
	itemsContainer.ScrollBarThickness = 5
	itemsContainer.Parent = panel

	local itemsLayout = Instance.new("UIGridLayout")
	itemsLayout.CellSize = UDim2.new(0, 193, 0, 33)
	itemsLayout.CellPadding = UDim2.new(0, 6, 0, 6)
	itemsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	itemsLayout.Parent = itemsContainer

	ItemRegistry.Init()
	table.clear(_itemButtons)
	for index, entry in ipairs(ItemCatalog.GetAllEntries()) do
		local itemBtn = Instance.new("TextButton")
		itemBtn.Name = `Item_{entry.Id}`
		itemBtn.LayoutOrder = index
		itemBtn.BackgroundColor3 = Color3.fromRGB(45, 48, 58)
		itemBtn.TextColor3 = Color3.fromRGB(240, 240, 245)
		itemBtn.Font = Enum.Font.GothamMedium
		itemBtn.TextSize = 11
		itemBtn.Text = `{entry.DisplayName} [{entry.CategoryDisplayName}]`
		itemBtn.TextTruncate = Enum.TextTruncate.AtEnd
		itemBtn.Parent = itemsContainer

		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 6)
		c.Parent = itemBtn

		itemBtn.Activated:Connect(function()
			selectItem(entry.Id)
		end)
		_itemButtons[entry.Id] = itemBtn
	end

	-- Fila 4: Controles táctiles / paso fino por eje (X/Y/Z ±)
	local touchBar = Instance.new("Frame")
	touchBar.Name = "PrecisionTouchBar"
	touchBar.Size = UDim2.new(1, -24, 0, 32)
	touchBar.Position = UDim2.new(0, 12, 0, 164)
	touchBar.BackgroundTransparency = 1
	touchBar.Visible = false
	touchBar.Parent = panel
	_touchBarFrame = touchBar

	local touchLayout = Instance.new("UIListLayout")
	touchLayout.FillDirection = Enum.FillDirection.Horizontal
	touchLayout.Padding = UDim.new(0, 6)
	touchLayout.SortOrder = Enum.SortOrder.LayoutOrder
	touchLayout.Parent = touchBar

	local axes: { "X" | "Y" | "Z" } = { "X", "Y", "Z" }
	for idx, axis in ipairs(axes) do
		createButton(touchBar, `Nudge_{axis}_Neg`, `{axis}-`, 58, 28, idx * 2 - 1, function()
			if BuildState.SelectedPlacedPieceId then
				if BuildState.ActiveTool == "Rotate" then
					BuildTransformController.RotateAlongAxisStep(axis, -1)
				else
					if BuildState.ActiveTool == "None" then
						BuildState.SetActiveTool("Move")
					end
					BuildTransformController.NudgeAlongAxis(axis, -1)
				end
				updateEditorStep()
			elseif BuildState.SelectedItemId then
				BuildState.RotateAxis(axis, -1)
				updateEditorStep()
			end
		end)
		createButton(touchBar, `Nudge_{axis}_Pos`, `{axis}+`, 58, 28, idx * 2, function()
			if BuildState.SelectedPlacedPieceId then
				if BuildState.ActiveTool == "Rotate" then
					BuildTransformController.RotateAlongAxisStep(axis, 1)
				else
					if BuildState.ActiveTool == "None" then
						BuildState.SetActiveTool("Move")
					end
					BuildTransformController.NudgeAlongAxis(axis, 1)
				end
				updateEditorStep()
			elseif BuildState.SelectedItemId then
				BuildState.RotateAxis(axis, 1)
				updateEditorStep()
			end
		end)
	end

	-- Fila 5: Barra principal de acciones
	local controlsBar = Instance.new("Frame")
	controlsBar.Name = "ControlsBar"
	controlsBar.Size = UDim2.new(1, -24, 0, 36)
	controlsBar.Position = UDim2.new(0, 12, 1, -42)
	controlsBar.BackgroundTransparency = 1
	controlsBar.Parent = panel

	local controlsLayout = Instance.new("UIListLayout")
	controlsLayout.FillDirection = Enum.FillDirection.Horizontal
	controlsLayout.Padding = UDim.new(0, 6)
	controlsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	controlsLayout.Parent = controlsBar

	createButton(controlsBar, "PlaceButton", "Colocar [Clic]", 92, 32, 1, function()
		if BuildState.IsActive and BuildState.SelectedItemId then
			handlePrimaryAction()
		end
	end)
	local confirmBtn = createButton(controlsBar, "ConfirmTransformButton", "Confirmar [Enter]", 110, 32, 2, function()
		handleConfirmTransform()
	end)
	confirmBtn.Visible = false
	_confirmTransformButton = confirmBtn

	createButton(controlsBar, "DeleteButton", "Eliminar [Del]", 90, 32, 3, function()
		handleDeleteAction()
	end)
	createButton(controlsBar, "RotateYButton", "Rotar Y [R]", 80, 32, 4, function()
		handleRotateInput("Y")
	end)
	createButton(controlsBar, "RotateXButton", "Rotar X [T]", 80, 32, 5, function()
		handleRotateInput("X")
	end)
	createButton(controlsBar, "RotateZButton", "Rotar Z [Y]", 80, 32, 6, function()
		handleRotateInput("Z")
	end)
	createButton(controlsBar, "CancelButton", "Cancelar [Esc]", 92, 32, 7, function()
		cancelOrExit()
	end)
	createButton(controlsBar, "CloseEditorButton", "Salir [B]", 66, 32, 8, function()
		if BuildState.IsActive then
			closeEditorCleanly()
		end
	end)

	screenGui.Parent = playerGui
	updateUI()
end

local function connectSyncRemote()
	local shared = ReplicatedStorage:WaitForChild("Shared", 10)
	local remotes = shared and shared:WaitForChild("Remotes", 10)
	local syncRemote = remotes and remotes:WaitForChild(BuildProtocol.SyncRemoteEventName, 10)
	if syncRemote and syncRemote:IsA("RemoteEvent") then
		table.insert(
			_lifecycleConnections,
			syncRemote.OnClientEvent:Connect(function(payload: BuildProtocol.BlueprintSyncPayload)
				if payload and payload.Type == BuildProtocol.SyncTypes.PiecePlaced and payload.PlacedPiece then
					BuildPlacementController.NotifyReplicatedOrSynced(payload.PlacedPiece.InstanceId)
				end
				local _, needsResync = BuildState.ApplySyncEvent(payload)
				if needsResync then
					task.spawn(function()
						BuildPlacementController.SyncBlueprintFromServer()
					end)
				end
			end)
		)
	end
end

local function cleanupController()
	closeEditorCleanly()
	BuildInputController.Unbind()
	BuildPreviewController._ClearGeometryCacheForTests()
	for _, conn in ipairs(_lifecycleConnections) do
		conn:Disconnect()
	end
	table.clear(_lifecycleConnections)
	if _unsubBuildState then
		_unsubBuildState()
		_unsubBuildState = nil
	end
	if _unsubBlueprintReplaced then
		_unsubBlueprintReplaced()
		_unsubBlueprintReplaced = nil
	end
end

local function onAuthoritativeBlueprintReplaced()
	BuildPlacementController.ClearPending()
	BuildSelectionController.ClearSelection()
	BuildSelectionController.ClearPendingDeletes()
	BuildTransformController.CancelSession()
	BuildMoveGizmo.Hide()
	BuildRotationGizmo.Hide()
	BuildPreviewController.InvalidateWorkshopCaches()
	updateUI()
end

local function init()
	ItemRegistry.Init()
	BuildState.SetExpectedOwner(localPlayer.UserId)
	_unsubBuildState = BuildState.Subscribe(updateUI)
	_unsubBlueprintReplaced = BuildState.SubscribeBlueprintReplaced(onAuthoritativeBlueprintReplaced)
	buildUI()
	refreshAssignedPlot()

	local cam = Workspace.CurrentCamera
	if cam then
		table.insert(
			_lifecycleConnections,
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveScale)
		)
	end

	table.insert(
		_lifecycleConnections,
		localPlayer:GetAttributeChangedSignal(GameConfig.PlotAttributes.PlotId):Connect(function()
			refreshAssignedPlot()
		end)
	)

	table.insert(
		_lifecycleConnections,
		localPlayer.CharacterRemoving:Connect(function()
			closeEditorCleanly()
			BuildPreviewController.InvalidatePlotCache()
		end)
	)

	table.insert(
		_lifecycleConnections,
		localPlayer.CharacterAdded:Connect(function()
			BuildPreviewController.InvalidatePlotCache()
		end)
	)

	local plotsFolder = Workspace:WaitForChild("Plots", 10)
	if plotsFolder then
		local function watchPlotInstance(plotChild: Instance)
			if plotChild:IsA("Model") then
				table.insert(
					_lifecycleConnections,
					plotChild:GetAttributeChangedSignal(GameConfig.PlotAttributes.OwnerUserId):Connect(refreshAssignedPlot)
				)
			end
		end
		for _, child in ipairs(plotsFolder:GetChildren()) do
			watchPlotInstance(child)
		end
		table.insert(
			_lifecycleConnections,
			plotsFolder.ChildAdded:Connect(function(child)
				watchPlotInstance(child)
				refreshAssignedPlot()
			end)
		)
		table.insert(
			_lifecycleConnections,
			plotsFolder.DescendantAdded:Connect(function(descendant)
				if descendant:IsA("BasePart") and descendant.Name == "BuildZone" and (BuildState.AssignedPlot == nil or BuildState.BuildZone == nil) then
					refreshAssignedPlot()
				end
			end)
		)
		refreshAssignedPlot()
	end

	task.spawn(connectSyncRemote)

	BuildInputController.Bind({
		OnToggleEditor = toggleEditor,
		OnRotateY = function()
			handleRotateInput("Y")
		end,
		OnRotateX = function()
			handleRotateInput("X")
		end,
		OnRotateZ = function()
			handleRotateInput("Z")
		end,
		OnPrimaryClick = handlePrimaryAction,
		OnPrimaryRelease = handlePrimaryRelease,
		OnDeleteSelected = handleDeleteAction,
		OnCancelOrExit = cancelOrExit,
		OnConfirmTransform = handleConfirmTransform,
		OnTogglePositionMode = function()
			if BuildState.IsActive then
				BuildState.TogglePositionMode()
				updateEditorStep()
			end
		end,
		OnSelectMoveTool = function()
			activateTransformTool("Move")
		end,
		OnSelectRotateTool = function()
			activateTransformTool("Rotate")
		end,
		OnToggleSmartSnap = function()
			if BuildState.IsActive then
				BuildState.SetSmartSnapEnabled(not BuildState.SmartSnapEnabled)
				updateEditorStep()
			end
		end,
		OnToggleFaceSnap = function()
			if BuildState.IsActive then
				BuildState.SetFaceSnapEnabled(not BuildState.FaceSnapEnabled)
				updateEditorStep()
			end
		end,
		OnToggleGuides = function()
			if BuildState.IsActive then
				BuildState.SetGuidesEnabled(not BuildState.GuidesEnabled)
				updateEditorStep()
			end
		end,
	})

	table.insert(
		_lifecycleConnections,
		script.Destroying:Connect(cleanupController)
	)
end

init()
