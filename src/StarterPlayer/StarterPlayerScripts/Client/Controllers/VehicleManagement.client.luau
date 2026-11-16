--!strict
--[=[
	VehicleManagement.client.luau
	Interfaz responsiva PC/Móvil (no superpuesta a BuildEditorGui) para:
	- Gestión de múltiples Blueprints (crear, guardar, cargar, duplicar, renombrar, eliminar)
	- Controles del VehicleStand exclusivos del propietario (altura, lateral, paso normal/fino, reset)
	- Diagnóstico de preparación de lanzamiento (solo validación sin físicas/conducción)
]=]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)

local BuildState = require(script.Parent:WaitForChild("BuildState"))
local BlueprintManagerController = require(script.Parent:WaitForChild("BlueprintManagerController"))
local StandController = require(script.Parent:WaitForChild("StandController"))
local VehicleLaunchController = require(script.Parent:WaitForChild("VehicleLaunchController"))
local WheelInspectorPanel = require(script.Parent:WaitForChild("WheelInspectorPanel"))
local EngineInspectorPanel = require(script.Parent:WaitForChild("EngineInspectorPanel"))
local BoosterInspectorPanel = require(script.Parent:WaitForChild("BoosterInspectorPanel"))
local VehicleDrivingController = require(script.Parent:WaitForChild("VehicleDrivingController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "VehicleManagementGui"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 15
screenGui.IgnoreGuiInset = false
screenGui.Parent = PlayerGui

local uiScale = Instance.new("UIScale")
uiScale.Scale = 1
uiScale.Parent = screenGui

local function updateResponsiveScale()
	local cam = workspace.CurrentCamera
	local size = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	if size.X < 860 or size.Y < 560 then
		uiScale.Scale = 0.78
	elseif size.X < 1050 then
		uiScale.Scale = 0.88
	else
		uiScale.Scale = 1
	end
end

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(updateResponsiveScale)
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveScale)
end
updateResponsiveScale()

local function styleCorner(inst: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function styleStroke(inst: GuiObject, color: Color3, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
end

local function makeButton(name: string, text: string, bg: Color3, size: UDim2, parent: Instance): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Text = text
	btn.Size = size
	btn.BackgroundColor3 = bg
	btn.TextColor3 = Color3.fromRGB(242, 246, 255)
	btn.Font = Enum.Font.GothamSemibold
	btn.TextSize = 13
	btn.AutoButtonColor = true
	btn.Active = true
	btn.BorderSizePixel = 0
	btn.Parent = parent
	styleCorner(btn, 7)
	return btn
end

local function makeLabel(name: string, text: string, size: UDim2, parent: Instance, alignX: Enum.TextXAlignment?): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Name = name
	lbl.Text = text
	lbl.Size = size
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = Color3.fromRGB(235, 242, 252)
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 13
	lbl.TextXAlignment = alignX or Enum.TextXAlignment.Left
	lbl.Parent = parent
	return lbl
end

local function formatShortTime(unixSeconds: number): string
	if type(unixSeconds) ~= "number" or unixSeconds <= 0 then
		return "--"
	end
	local ok, formatted = pcall(os.date, "%d/%m %H:%M", unixSeconds)
	if ok and type(formatted) == "string" then
		return formatted
	end
	return "--:--"
end

-- === TOP ACTION DOCK (Arriba a la derecha, sin superponerse al botón Construir ni al EditorPanel inferior) ===
local topDock = Instance.new("Frame")
topDock.Name = "TopManagementDock"
topDock.AnchorPoint = Vector2.new(1, 0)
topDock.Position = UDim2.new(1, -14, 0, 12)
topDock.AutomaticSize = Enum.AutomaticSize.X
topDock.Size = UDim2.fromOffset(0, 42)
topDock.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
topDock.BackgroundTransparency = 0.12
topDock.Active = true
topDock.Parent = screenGui
styleCorner(topDock, 10)
styleStroke(topDock, Color3.fromRGB(70, 95, 138), 1)

local topPadding = Instance.new("UIPadding")
topPadding.PaddingLeft = UDim.new(0, 8)
topPadding.PaddingRight = UDim.new(0, 8)
topPadding.Parent = topDock

local topLayout = Instance.new("UIListLayout")
topLayout.FillDirection = Enum.FillDirection.Horizontal
topLayout.SortOrder = Enum.SortOrder.LayoutOrder
topLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
topLayout.VerticalAlignment = Enum.VerticalAlignment.Center
topLayout.Padding = UDim.new(0, 6)
topLayout.Parent = topDock

local bpToggleBtn = makeButton("BlueprintsToggleBtn", "Blueprints (0/3)", Color3.fromRGB(48, 86, 152), UDim2.fromOffset(146, 32), topDock)
bpToggleBtn.LayoutOrder = 1
local invToggleBtn = makeButton("InventoryToggleBtn", "Inventario", Color3.fromRGB(44, 130, 122), UDim2.fromOffset(102, 32), topDock)
invToggleBtn.LayoutOrder = 2
local clearWorkshopBtn = makeButton("ClearWorkshopBtn", "Vaciar taller", Color3.fromRGB(168, 72, 62), UDim2.fromOffset(118, 32), topDock)
clearWorkshopBtn.LayoutOrder = 3
local standToggleBtn = makeButton("StandToggleBtn", "Elevador", Color3.fromRGB(110, 70, 175), UDim2.fromOffset(92, 32), topDock)
standToggleBtn.LayoutOrder = 4
local launchPrepBtn = makeButton("LaunchPrepBtn", "Verificar", Color3.fromRGB(170, 110, 38), UDim2.fromOffset(144, 32), topDock)
launchPrepBtn.LayoutOrder = 5
local launchNowBtn = makeButton("LaunchVehicleBtn", "Lanzar", Color3.fromRGB(46, 152, 86), UDim2.fromOffset(124, 32), topDock)
launchNowBtn.LayoutOrder = 6

-- === BARRA DE CONTROLES DE RUNTIME ACTIVO (PC + Móvil) ===
local runtimeBar = Instance.new("Frame")
runtimeBar.Name = "RuntimeControlsBar"
runtimeBar.AnchorPoint = Vector2.new(0.5, 0)
runtimeBar.Position = UDim2.new(0.5, 0, 0, 62)
runtimeBar.AutomaticSize = Enum.AutomaticSize.X
runtimeBar.Size = UDim2.fromOffset(0, 44)
runtimeBar.BackgroundColor3 = Color3.fromRGB(18, 22, 31)
runtimeBar.BackgroundTransparency = 0.08
runtimeBar.Visible = false
runtimeBar.Active = true
runtimeBar.Parent = screenGui
styleCorner(runtimeBar, 10)
styleStroke(runtimeBar, Color3.fromRGB(58, 156, 102), 1)

local runtimePadding = Instance.new("UIPadding")
runtimePadding.PaddingLeft = UDim.new(0, 12)
runtimePadding.PaddingRight = UDim.new(0, 12)
runtimePadding.Parent = runtimeBar

local runtimeLayout = Instance.new("UIListLayout")
runtimeLayout.FillDirection = Enum.FillDirection.Horizontal
runtimeLayout.SortOrder = Enum.SortOrder.LayoutOrder
runtimeLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
runtimeLayout.VerticalAlignment = Enum.VerticalAlignment.Center
runtimeLayout.Padding = UDim.new(0, 8)
runtimeLayout.Parent = runtimeBar

local runtimeBadgeLbl = makeLabel("RuntimeStateBadge", "Vehículo activo", UDim2.fromOffset(198, 32), runtimeBar, Enum.TextXAlignment.Center)
runtimeBadgeLbl.LayoutOrder = 1
runtimeBadgeLbl.Font = Enum.Font.GothamBold
runtimeBadgeLbl.TextSize = 12
runtimeBadgeLbl.TextColor3 = Color3.fromRGB(165, 240, 188)

local VehicleSeatController = require(script.Parent.VehicleSeatController)

local exitSeatBtn = makeButton("ExitSeatBtn", "Salir del asiento", Color3.fromRGB(178, 120, 42), UDim2.fromOffset(126, 32), runtimeBar)
exitSeatBtn.LayoutOrder = 2
local resetVehicleBtn = makeButton("ResetVehicleBtn", "Reiniciar vehículo", Color3.fromRGB(48, 125, 195), UDim2.fromOffset(144, 32), runtimeBar)
resetVehicleBtn.LayoutOrder = 3
local returnWorkshopBtn = makeButton("ReturnWorkshopBtn", "Regresar al taller", Color3.fromRGB(184, 68, 66), UDim2.fromOffset(148, 32), runtimeBar)
returnWorkshopBtn.LayoutOrder = 4

-- === PANEL DE BLUEPRINTS (Sistema de 3 tarjetas guardadas) ===
local blueprintsPanel = Instance.new("Frame")
blueprintsPanel.Name = "BlueprintsPanel"
blueprintsPanel.Position = UDim2.fromOffset(14, 68)
blueprintsPanel.Size = UDim2.fromOffset(500, 444)
blueprintsPanel.BackgroundColor3 = Color3.fromRGB(18, 22, 31)
blueprintsPanel.BackgroundTransparency = 0.06
blueprintsPanel.Visible = false
blueprintsPanel.Active = true
blueprintsPanel.Parent = screenGui
styleCorner(blueprintsPanel, 10)
styleStroke(blueprintsPanel, Color3.fromRGB(74, 104, 155), 1)

local bpHeader = Instance.new("Frame")
bpHeader.Size = UDim2.new(1, -16, 0, 30)
bpHeader.Position = UDim2.fromOffset(8, 6)
bpHeader.BackgroundTransparency = 1
bpHeader.Parent = blueprintsPanel

local bpTitleLbl = makeLabel("BpTitle", "Blueprints (0/3)", UDim2.new(1, -34, 1, 0), bpHeader)
bpTitleLbl.Font = Enum.Font.GothamBold
bpTitleLbl.TextSize = 15

local bpCloseBtn = makeButton("CloseBtn", "X", Color3.fromRGB(125, 50, 56), UDim2.fromOffset(28, 28), bpHeader)
bpCloseBtn.Position = UDim2.new(1, -28, 0, 1)

local activeStatusLbl = makeLabel("ActiveStatus", "Taller actual: vacío (0 piezas)", UDim2.new(1, -16, 0, 18), blueprintsPanel)
activeStatusLbl.Position = UDim2.fromOffset(8, 38)
activeStatusLbl.TextColor3 = Color3.fromRGB(170, 210, 255)
activeStatusLbl.TextSize = 12

local bpFeedbackLbl = makeLabel("BpFeedback", "El diseño del taller se guarda explícitamente en una tarjeta (Slot 1-3).", UDim2.new(1, -16, 0, 18), blueprintsPanel)
bpFeedbackLbl.Position = UDim2.fromOffset(8, 57)
bpFeedbackLbl.TextColor3 = Color3.fromRGB(165, 180, 205)
bpFeedbackLbl.TextSize = 11
bpFeedbackLbl.TextTruncate = Enum.TextTruncate.AtEnd

local bpCardsScroll = Instance.new("ScrollingFrame")
bpCardsScroll.Name = "BlueprintSlotsScroll"
bpCardsScroll.Position = UDim2.fromOffset(8, 80)
bpCardsScroll.Size = UDim2.new(1, -16, 1, -110)
bpCardsScroll.BackgroundColor3 = Color3.fromRGB(14, 17, 24)
bpCardsScroll.BorderSizePixel = 0
bpCardsScroll.CanvasSize = UDim2.fromOffset(0, 0)
bpCardsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
bpCardsScroll.ScrollBarThickness = 6
bpCardsScroll.Parent = blueprintsPanel
styleCorner(bpCardsScroll, 7)

local cardsLayout = Instance.new("UIListLayout")
cardsLayout.Padding = UDim.new(0, 8)
cardsLayout.SortOrder = Enum.SortOrder.LayoutOrder
cardsLayout.Parent = bpCardsScroll

local cardsPadding = Instance.new("UIPadding")
cardsPadding.PaddingTop = UDim.new(0, 8)
cardsPadding.PaddingBottom = UDim.new(0, 8)
cardsPadding.PaddingLeft = UDim.new(0, 8)
cardsPadding.PaddingRight = UDim.new(0, 8)
cardsPadding.Parent = bpCardsScroll

local bpFooterLbl = makeLabel("BpFooter", "Editar en el taller o conducir no altera las tarjetas guardadas.", UDim2.new(1, -16, 0, 20), blueprintsPanel)
bpFooterLbl.Position = UDim2.new(0, 8, 1, -24)
bpFooterLbl.TextColor3 = Color3.fromRGB(145, 160, 188)
bpFooterLbl.TextSize = 11

-- === PANEL DE INVENTARIO CENTRAL Y CATÁLOGO ===
local inventoryPanel = Instance.new("Frame")
inventoryPanel.Name = "InventoryPanel"
inventoryPanel.Position = UDim2.fromOffset(14, 68)
inventoryPanel.Size = UDim2.fromOffset(560, 464)
inventoryPanel.BackgroundColor3 = Color3.fromRGB(18, 22, 31)
inventoryPanel.BackgroundTransparency = 0.06
inventoryPanel.Visible = false
inventoryPanel.Active = true
inventoryPanel.Parent = screenGui
styleCorner(inventoryPanel, 10)
styleStroke(inventoryPanel, Color3.fromRGB(64, 152, 140), 1)

local invHeader = Instance.new("Frame")
invHeader.Size = UDim2.new(1, -16, 0, 30)
invHeader.Position = UDim2.fromOffset(8, 6)
invHeader.BackgroundTransparency = 1
invHeader.Parent = inventoryPanel

local invTitleLbl = makeLabel("InvTitle", "Inventario y Catálogo", UDim2.new(1, -120, 1, 0), invHeader)
invTitleLbl.Font = Enum.Font.GothamBold
invTitleLbl.TextSize = 15

local invRefreshBtn = makeButton("InvRefreshBtn", "Actualizar", Color3.fromRGB(44, 96, 134), UDim2.fromOffset(82, 26), invHeader)
invRefreshBtn.Position = UDim2.new(1, -114, 0, 2)
invRefreshBtn.TextSize = 11

local invCloseBtn = makeButton("InvCloseBtn", "X", Color3.fromRGB(125, 50, 56), UDim2.fromOffset(28, 26), invHeader)
invCloseBtn.Position = UDim2.new(1, -28, 0, 2)

local invFeedbackLbl = makeLabel(
	"InvFeedback",
	"Administra tus piezas acumulables, unidades únicas de motores/propulsores y referencias en slots.",
	UDim2.new(1, -16, 0, 20),
	inventoryPanel
)
invFeedbackLbl.Position = UDim2.fromOffset(8, 38)
invFeedbackLbl.TextColor3 = Color3.fromRGB(165, 195, 220)
invFeedbackLbl.TextSize = 11
invFeedbackLbl.TextTruncate = Enum.TextTruncate.AtEnd

local invScroll = Instance.new("ScrollingFrame")
invScroll.Name = "InventoryItemsScroll"
invScroll.Position = UDim2.fromOffset(8, 62)
invScroll.Size = UDim2.new(1, -16, 1, -92)
invScroll.BackgroundColor3 = Color3.fromRGB(14, 17, 24)
invScroll.BorderSizePixel = 0
invScroll.CanvasSize = UDim2.fromOffset(0, 0)
invScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
invScroll.ScrollBarThickness = 6
invScroll.Parent = inventoryPanel
styleCorner(invScroll, 7)

local invLayout = Instance.new("UIListLayout")
invLayout.Padding = UDim.new(0, 6)
invLayout.SortOrder = Enum.SortOrder.LayoutOrder
invLayout.Parent = invScroll

local invPad = Instance.new("UIPadding")
invPad.PaddingTop = UDim.new(0, 8)
invPad.PaddingBottom = UDim.new(0, 8)
invPad.PaddingLeft = UDim.new(0, 8)
invPad.PaddingRight = UDim.new(0, 8)
invPad.Parent = invScroll

local invFooterLbl = makeLabel(
	"InvFooter",
	"Piezas normales se venden al 50% de su precio; motores/propulsores únicos sin venta monetaria aún.",
	UDim2.new(1, -16, 0, 20),
	inventoryPanel
)
invFooterLbl.Position = UDim2.new(0, 8, 1, -24)
invFooterLbl.TextColor3 = Color3.fromRGB(145, 165, 190)
invFooterLbl.TextSize = 11

-- === OVERLAY MODAL DE CONFIRMACIÓN (Vaciar taller / Sobrescribir 2 pasos / Guardar / Renombrar / Eliminar) ===
local modalOverlay = Instance.new("Frame")
modalOverlay.Name = "BlueprintConfirmOverlay"
modalOverlay.Size = UDim2.fromScale(1, 1)
modalOverlay.BackgroundColor3 = Color3.fromRGB(6, 9, 14)
modalOverlay.BackgroundTransparency = 0.42
modalOverlay.Visible = false
modalOverlay.Active = true
modalOverlay.ZIndex = 40
modalOverlay.Parent = screenGui

local modalDialog = Instance.new("Frame")
modalDialog.Name = "ModalDialog"
modalDialog.AnchorPoint = Vector2.new(0.5, 0.5)
modalDialog.Position = UDim2.fromScale(0.5, 0.5)
modalDialog.Size = UDim2.fromOffset(456, 260)
modalDialog.BackgroundColor3 = Color3.fromRGB(20, 25, 36)
modalDialog.ZIndex = 41
modalDialog.Active = true
modalDialog.Parent = modalOverlay
styleCorner(modalDialog, 12)
styleStroke(modalDialog, Color3.fromRGB(88, 124, 186), 1.5)

local modalTitleLbl = makeLabel("ModalTitle", "Confirmar", UDim2.new(1, -24, 0, 26), modalDialog)
modalTitleLbl.Position = UDim2.fromOffset(12, 10)
modalTitleLbl.Font = Enum.Font.GothamBold
modalTitleLbl.TextSize = 16
modalTitleLbl.ZIndex = 42

local modalBodyLbl = makeLabel("ModalBody", "", UDim2.new(1, -24, 0, 62), modalDialog)
modalBodyLbl.Position = UDim2.fromOffset(12, 40)
modalBodyLbl.TextYAlignment = Enum.TextYAlignment.Top
modalBodyLbl.TextWrapped = true
modalBodyLbl.TextSize = 12
modalBodyLbl.TextColor3 = Color3.fromRGB(210, 222, 240)
modalBodyLbl.ZIndex = 42

local modalInputBox = Instance.new("TextBox")
modalInputBox.Name = "ModalNameInput"
modalInputBox.Position = UDim2.fromOffset(12, 106)
modalInputBox.Size = UDim2.new(1, -24, 0, 32)
modalInputBox.BackgroundColor3 = Color3.fromRGB(28, 35, 50)
modalInputBox.TextColor3 = Color3.fromRGB(242, 247, 255)
modalInputBox.PlaceholderText = "Nombre del vehículo (1-32 caracteres)..."
modalInputBox.PlaceholderColor3 = Color3.fromRGB(132, 146, 174)
modalInputBox.Text = ""
modalInputBox.ClearTextOnFocus = false
modalInputBox.Font = Enum.Font.Gotham
modalInputBox.TextSize = 13
modalInputBox.Visible = false
modalInputBox.ZIndex = 42
modalInputBox.Parent = modalDialog
styleCorner(modalInputBox, 7)
styleStroke(modalInputBox, Color3.fromRGB(70, 92, 132), 1)

local modalErrorLbl = makeLabel("ModalError", "", UDim2.new(1, -24, 0, 20), modalDialog)
modalErrorLbl.Position = UDim2.new(0, 12, 1, -68)
modalErrorLbl.TextColor3 = Color3.fromRGB(255, 130, 130)
modalErrorLbl.TextSize = 11
modalErrorLbl.Visible = false
modalErrorLbl.ZIndex = 42

local modalContentFrame = Instance.new("ScrollingFrame")
modalContentFrame.Name = "ModalDynamicContent"
modalContentFrame.Position = UDim2.fromOffset(12, 144)
modalContentFrame.Size = UDim2.new(1, -24, 1, -196)
modalContentFrame.BackgroundTransparency = 1
modalContentFrame.BorderSizePixel = 0
modalContentFrame.CanvasSize = UDim2.fromOffset(0, 0)
modalContentFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
modalContentFrame.ScrollBarThickness = 5
modalContentFrame.Visible = false
modalContentFrame.ZIndex = 42
modalContentFrame.Parent = modalDialog

local modalContentLayout = Instance.new("UIListLayout")
modalContentLayout.Padding = UDim.new(0, 6)
modalContentLayout.SortOrder = Enum.SortOrder.LayoutOrder
modalContentLayout.Parent = modalContentFrame

local modalButtonsRow = Instance.new("Frame")
modalButtonsRow.Name = "ModalButtonsRow"
modalButtonsRow.Position = UDim2.new(0, 12, 1, -44)
modalButtonsRow.Size = UDim2.new(1, -24, 0, 34)
modalButtonsRow.BackgroundTransparency = 1
modalButtonsRow.ZIndex = 42
modalButtonsRow.Parent = modalDialog

local modalButtonsLayout = Instance.new("UIListLayout")
modalButtonsLayout.FillDirection = Enum.FillDirection.Horizontal
modalButtonsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
modalButtonsLayout.SortOrder = Enum.SortOrder.LayoutOrder
modalButtonsLayout.Padding = UDim.new(0, 8)
modalButtonsLayout.Parent = modalButtonsRow

-- === PANEL DE ELEVADOR (Derecha superior, solo propietario) ===
local standPanel = Instance.new("Frame")
standPanel.Name = "StandPanel"
standPanel.AnchorPoint = Vector2.new(1, 0)
standPanel.Position = UDim2.new(1, -14, 0, 68)
standPanel.Size = UDim2.fromOffset(290, 336)
standPanel.BackgroundColor3 = Color3.fromRGB(20, 22, 34)
standPanel.BackgroundTransparency = 0.08
standPanel.Visible = false
standPanel.Active = true
standPanel.Parent = screenGui
styleCorner(standPanel, 10)
styleStroke(standPanel, Color3.fromRGB(130, 92, 195), 1)

local standHeader = Instance.new("Frame")
standHeader.Size = UDim2.new(1, -16, 0, 32)
standHeader.Position = UDim2.fromOffset(8, 6)
standHeader.BackgroundTransparency = 1
standHeader.Parent = standPanel

local standTitleLbl = makeLabel("StandTitle", "Elevador del Vehículo", UDim2.new(1, -34, 1, 0), standHeader)
standTitleLbl.Font = Enum.Font.GothamBold
standTitleLbl.TextSize = 15

local standCloseBtn = makeButton("StandCloseBtn", "X", Color3.fromRGB(125, 50, 56), UDim2.fromOffset(28, 28), standHeader)
standCloseBtn.Position = UDim2.new(1, -28, 0, 2)

local standVehicleInfoLbl = makeLabel("VehicleInfo", "Vehiculo 1 (0 piezas)", UDim2.new(1, -16, 0, 20), standPanel)
standVehicleInfoLbl.Position = UDim2.fromOffset(8, 38)
standVehicleInfoLbl.TextColor3 = Color3.fromRGB(190, 175, 240)
standVehicleInfoLbl.TextSize = 12

local standHintLbl = makeLabel("ElevatorHint", "Eleva o centra tu vehículo real para construir debajo. Mantené pulsado para desplazamiento continuo.", UDim2.new(1, -16, 0, 28), standPanel)
standHintLbl.Position = UDim2.fromOffset(8, 56)
standHintLbl.TextColor3 = Color3.fromRGB(165, 176, 198)
standHintLbl.TextSize = 11
standHintLbl.TextWrapped = true

local fineMode = false
local standStepBtn = makeButton("StepModeBtn", "Paso: Normal (0.25)", Color3.fromRGB(68, 56, 118), UDim2.new(1, -16, 0, 30), standPanel)
standStepBtn.Position = UDim2.fromOffset(8, 88)

local heightLbl = makeLabel("HeightVal", "Altura (Y): 0.00  [0.0..16.0]", UDim2.new(1, -16, 0, 20), standPanel)
heightLbl.Position = UDim2.fromOffset(8, 124)
heightLbl.Font = Enum.Font.GothamSemibold

local heightRow = Instance.new("Frame")
heightRow.Position = UDim2.fromOffset(8, 146)
heightRow.Size = UDim2.new(1, -16, 0, 34)
heightRow.BackgroundTransparency = 1
heightRow.Parent = standPanel

local heightDownBtn = makeButton("HeightDownBtn", "Bajar (-Y)", Color3.fromRGB(58, 72, 108), UDim2.new(0.48, 0, 1, 0), heightRow)
local heightUpBtn = makeButton("HeightUpBtn", "Subir (+Y)", Color3.fromRGB(72, 112, 175), UDim2.new(0.48, 0, 1, 0), heightRow)
heightUpBtn.Position = UDim2.new(0.52, 0, 0, 0)

local lateralLbl = makeLabel("LateralVal", "Lateral (X): 0.00  [-10.0..+10.0]", UDim2.new(1, -16, 0, 20), standPanel)
lateralLbl.Position = UDim2.fromOffset(8, 186)
lateralLbl.Font = Enum.Font.GothamSemibold

local lateralRow = Instance.new("Frame")
lateralRow.Position = UDim2.fromOffset(8, 208)
lateralRow.Size = UDim2.new(1, -16, 0, 34)
lateralRow.BackgroundTransparency = 1
lateralRow.Parent = standPanel

local leftBtn = makeButton("LateralLeftBtn", "Izquierda (-X)", Color3.fromRGB(58, 72, 108), UDim2.new(0.48, 0, 1, 0), lateralRow)
local rightBtn = makeButton("LateralRightBtn", "Derecha (+X)", Color3.fromRGB(72, 112, 175), UDim2.new(0.48, 0, 1, 0), lateralRow)
rightBtn.Position = UDim2.new(0.52, 0, 0, 0)

local resetStandBtn = makeButton("ResetStandBtn", "Reiniciar Elevador (0, 0)", Color3.fromRGB(145, 76, 82), UDim2.new(1, -16, 0, 32), standPanel)
resetStandBtn.Position = UDim2.fromOffset(8, 252)

local standFeedbackLbl = makeLabel("StandFeedback", "Desplazamiento temporal del taller", UDim2.new(1, -16, 0, 34), standPanel)
standFeedbackLbl.Position = UDim2.fromOffset(8, 290)
standFeedbackLbl.TextColor3 = Color3.fromRGB(165, 210, 175)
standFeedbackLbl.TextSize = 11
standFeedbackLbl.TextWrapped = true

-- === PANEL DE PREPARACIÓN DE LANZAMIENTO ===
local launchPanel = Instance.new("Frame")
launchPanel.Name = "LaunchPrepPanel"
launchPanel.AnchorPoint = Vector2.new(0.5, 0)
launchPanel.Position = UDim2.new(0.5, 0, 0, 68)
launchPanel.Size = UDim2.fromOffset(390, 215)
launchPanel.BackgroundColor3 = Color3.fromRGB(19, 23, 30)
launchPanel.BackgroundTransparency = 0.06
launchPanel.Visible = false
launchPanel.Active = true
launchPanel.Parent = screenGui
styleCorner(launchPanel, 10)
styleStroke(launchPanel, Color3.fromRGB(190, 130, 55), 1)

local launchHeader = Instance.new("Frame")
launchHeader.Size = UDim2.new(1, -16, 0, 30)
launchHeader.Position = UDim2.fromOffset(8, 6)
launchHeader.BackgroundTransparency = 1
launchHeader.Parent = launchPanel

local launchTitle = makeLabel("LaunchTitle", "Preparación de Lanzamiento", UDim2.new(1, -34, 1, 0), launchHeader)
launchTitle.Font = Enum.Font.GothamBold
launchTitle.TextSize = 14

local launchCloseBtn = makeButton("LaunchCloseBtn", "X", Color3.fromRGB(125, 50, 56), UDim2.fromOffset(26, 26), launchHeader)
launchCloseBtn.Position = UDim2.new(1, -26, 0, 2)

local launchBodyLbl = makeLabel("LaunchBody", "Presiona Verificar para analizar el diseño.", UDim2.new(1, -16, 1, -78), launchPanel)
launchBodyLbl.Position = UDim2.fromOffset(8, 40)
launchBodyLbl.TextYAlignment = Enum.TextYAlignment.Top
launchBodyLbl.TextWrapped = true
launchBodyLbl.TextSize = 12

local launchSelectRow = Instance.new("Frame")
launchSelectRow.Name = "LaunchSelectRow"
launchSelectRow.Position = UDim2.new(0, 8, 1, -34)
launchSelectRow.Size = UDim2.new(1, -16, 0, 28)
launchSelectRow.BackgroundTransparency = 1
launchSelectRow.Visible = false
launchSelectRow.Parent = launchPanel

local launchSelectLayout = Instance.new("UIListLayout")
launchSelectLayout.FillDirection = Enum.FillDirection.Horizontal
launchSelectLayout.Padding = UDim.new(0, 6)
launchSelectLayout.SortOrder = Enum.SortOrder.LayoutOrder
launchSelectLayout.Parent = launchSelectRow

-- Estado interno UI y diálogos modales
local modalBusy = false

local function closeModalDialog()
	modalOverlay.Visible = false
	modalInputBox.Visible = false
	modalInputBox.Text = ""
	modalErrorLbl.Visible = false
	modalErrorLbl.Text = ""
	modalContentFrame.Visible = false
	for _, child in ipairs(modalContentFrame:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for _, child in ipairs(modalButtonsRow:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function setModalError(msg: string?)
	if msg and #msg > 0 then
		modalErrorLbl.Text = msg
		modalErrorLbl.Visible = true
	else
		modalErrorLbl.Text = ""
		modalErrorLbl.Visible = false
	end
end

local function addModalButton(
	name: string,
	text: string,
	bg: Color3,
	order: number,
	width: number,
	onActivated: () -> ()
): TextButton
	local btn = makeButton(name, text, bg, UDim2.fromOffset(width, 32), modalButtonsRow)
	btn.LayoutOrder = order
	btn.TextSize = 12
	btn.ZIndex = 43
	btn.Activated:Connect(function()
		if modalBusy then
			return
		end
		onActivated()
	end)
	return btn
end

local function trimString(value: string): string
	return string.match(value, "^%s*(.-)%s*$") or ""
end

local function getSlotSummary(slotIndex: number): any
	for _, slot in ipairs(BuildState.BlueprintSlots) do
		if slot.SlotIndex == slotIndex then
			return slot
		end
	end
	return {
		SlotIndex = slotIndex,
		State = "Empty",
		IsOccupied = false,
		Name = `Slot {slotIndex}`,
		PieceCount = 0,
		Revision = 0,
		UpdatedAt = 0,
		IsActiveInWorkshop = false,
	}
end

local openClearWorkshopDialog: () -> ()
local openOverwriteStep1Dialog: (slotIndex: number, afterClearWorkshop: boolean) -> ()
local openOverwriteStep2Dialog: (slotIndex: number, chosenName: string, afterClearWorkshop: boolean) -> ()

local function openSaveEmptySlotDialog(slotIndex: number, afterClearWorkshop: boolean)
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(450, 224)
	modalTitleLbl.Text = if afterClearWorkshop
		then `Guardar en SLOT {slotIndex} y vaciar taller`
		else `Guardar en SLOT {slotIndex}`
	modalBodyLbl.Text = `Se guardará una copia de las {#BuildState.BlueprintPieces} piezas actuales del taller en SLOT {slotIndex}.`
	modalInputBox.Visible = true
	local defaultName = if BuildState.BlueprintName
			and #BuildState.BlueprintName > 0
			and BuildState.BlueprintName ~= "Sin título"
		then BuildState.BlueprintName
		else `Vehículo {slotIndex}`
	modalInputBox.Text = defaultName
	modalOverlay.Visible = true

	addModalButton("CancelModalBtn", "Cancelar", Color3.fromRGB(72, 78, 92), 1, 96, function()
		closeModalDialog()
	end)
	addModalButton(
		"ConfirmSaveSlotBtn",
		if afterClearWorkshop then "Guardar y vaciar" else "Guardar",
		Color3.fromRGB(44, 146, 88),
		2,
		if afterClearWorkshop then 140 else 108,
		function()
			local chosen = trimString(modalInputBox.Text)
			if #chosen == 0 then
				chosen = `Vehículo {slotIndex}`
			end
			modalBusy = true
			setModalError(nil)
			task.spawn(function()
				local ok, resp: any
				if afterClearWorkshop then
					ok, resp = BlueprintManagerController.SaveAndClearWorkshop(slotIndex, "Save", chosen)
				else
					ok, resp = BlueprintManagerController.SaveBlueprintSlot(slotIndex, chosen)
				end
				modalBusy = false
				if ok then
					closeModalDialog()
				else
					setModalError((resp and resp.ErrorMessage) or BuildState.LastError or "No se pudo guardar en el slot.")
				end
			end)
		end
	)
end

openOverwriteStep2Dialog = function(slotIndex: number, chosenName: string, afterClearWorkshop: boolean)
	local slot = getSlotSummary(slotIndex)
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(468, 224)
	modalTitleLbl.Text = "Confirmación final (Paso 2/2)"
	modalBodyLbl.Text = if afterClearWorkshop
		then `¿Sobrescribir definitivamente '{slot.Name}' en SLOT {slotIndex} ({slot.PieceCount} pzs) con '{chosenName}' ({#BuildState.BlueprintPieces} pzs) y luego vaciar el taller?`
		else `¿Sobrescribir definitivamente '{slot.Name}' en SLOT {slotIndex} ({slot.PieceCount} pzs) con '{chosenName}' ({#BuildState.BlueprintPieces} pzs)? Esta acción reemplaza el diseño anterior.`
	modalOverlay.Visible = true

	addModalButton("CancelOverwrite2Btn", "Cancelar", Color3.fromRGB(72, 78, 92), 1, 96, function()
		closeModalDialog()
	end)
	addModalButton(
		"ConfirmOverwrite2Btn",
		if afterClearWorkshop then "Sobrescribir y vaciar" else "Confirmar sobrescritura",
		Color3.fromRGB(196, 72, 56),
		2,
		174,
		function()
			modalBusy = true
			setModalError(nil)
			task.spawn(function()
				local ok, resp: any
				if afterClearWorkshop then
					ok, resp = BlueprintManagerController.SaveAndClearWorkshop(slotIndex, "Overwrite", chosenName, 2)
				else
					ok, resp = BlueprintManagerController.OverwriteBlueprintSlot(slotIndex, chosenName, 2)
				end
				modalBusy = false
				if ok then
					closeModalDialog()
				else
					setModalError((resp and resp.ErrorMessage) or BuildState.LastError or "No se pudo sobrescribir el slot.")
				end
			end)
		end
	)
end

openOverwriteStep1Dialog = function(slotIndex: number, afterClearWorkshop: boolean)
	local slot = getSlotSummary(slotIndex)
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(468, 240)
	modalTitleLbl.Text = `Sobrescribir SLOT {slotIndex} (Paso 1/2)`
	modalBodyLbl.Text = `Vas a reemplazar el vehículo guardado '{slot.Name}' ({slot.PieceCount} pzs). Podés ajustar el nombre antes de continuar a la confirmación final:`
	modalInputBox.Visible = true
	modalInputBox.Text = slot.Name
	modalOverlay.Visible = true

	addModalButton("CancelOverwrite1Btn", "Cancelar", Color3.fromRGB(72, 78, 92), 1, 96, function()
		closeModalDialog()
	end)
	addModalButton("NextOverwrite1Btn", "Continuar", Color3.fromRGB(205, 134, 42), 2, 112, function()
		local chosen = trimString(modalInputBox.Text)
		if #chosen == 0 then
			chosen = slot.Name
		end
		openOverwriteStep2Dialog(slotIndex, chosen, afterClearWorkshop)
	end)
end

local function openRenameSlotDialog(slotIndex: number)
	local slot = getSlotSummary(slotIndex)
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(440, 224)
	modalTitleLbl.Text = `Renombrar SLOT {slotIndex}`
	modalBodyLbl.Text = `Ingresá el nuevo nombre para '{slot.Name}' (1 a {GameConfig.Blueprints.MaxNameLength} caracteres). La estructura del vehículo no se modificará.`
	modalInputBox.Visible = true
	modalInputBox.Text = slot.Name
	modalOverlay.Visible = true

	addModalButton("CancelRenameBtn", "Cancelar", Color3.fromRGB(72, 78, 92), 1, 96, function()
		closeModalDialog()
	end)
	addModalButton("ConfirmRenameBtn", "Guardar nombre", Color3.fromRGB(82, 110, 178), 2, 132, function()
		local chosen = trimString(modalInputBox.Text)
		if #chosen < GameConfig.Blueprints.MinNameLength then
			setModalError("El nombre no puede estar vacío.")
			return
		end
		if #chosen > GameConfig.Blueprints.MaxNameLength then
			setModalError(`El nombre no puede superar {GameConfig.Blueprints.MaxNameLength} caracteres.`)
			return
		end
		modalBusy = true
		setModalError(nil)
		task.spawn(function()
			local ok, resp = BlueprintManagerController.RenameBlueprintSlot(slotIndex, chosen)
			modalBusy = false
			if ok then
				closeModalDialog()
			else
				setModalError((resp and resp.ErrorMessage) or BuildState.LastError or "No se pudo renombrar.")
			end
		end)
	end)
end

local function openDeleteSlotDialog(slotIndex: number)
	local slot = getSlotSummary(slotIndex)
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(456, 206)
	modalTitleLbl.Text = `Eliminar SLOT {slotIndex}`
	modalBodyLbl.Text = `¿Seguro que querés eliminar el diseño guardado '{slot.Name}' ({slot.PieceCount} pzs)? El vehículo actual del taller NO se eliminará.`
	modalOverlay.Visible = true

	addModalButton("CancelDeleteBtn", "Cancelar", Color3.fromRGB(72, 78, 92), 1, 96, function()
		closeModalDialog()
	end)
	addModalButton("ConfirmDeleteBtn", "Eliminar slot", Color3.fromRGB(192, 56, 56), 2, 122, function()
		modalBusy = true
		setModalError(nil)
		task.spawn(function()
			local ok, resp = BlueprintManagerController.DeleteBlueprintSlot(slotIndex, slot.Name)
			modalBusy = false
			if ok then
				closeModalDialog()
			else
				setModalError((resp and resp.ErrorMessage) or BuildState.LastError or "No se pudo eliminar el slot.")
			end
		end)
	end)
end

local function openLoadSlotWarningDialog(slotIndex: number)
	local slot = getSlotSummary(slotIndex)
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(462, 210)
	modalTitleLbl.Text = `Cargar SLOT {slotIndex}`
	modalBodyLbl.Text = `Tu taller actual tiene {#BuildState.BlueprintPieces} piezas en edición. ¿Cargar '{slot.Name}' ({slot.PieceCount} pzs) y reemplazar el diseño actual del taller?`
	modalOverlay.Visible = true

	addModalButton("CancelLoadBtn", "Cancelar", Color3.fromRGB(72, 78, 92), 1, 96, function()
		closeModalDialog()
	end)
	addModalButton("ConfirmLoadBtn", "Cargar al taller", Color3.fromRGB(48, 124, 188), 2, 134, function()
		modalBusy = true
		setModalError(nil)
		task.spawn(function()
			local ok, resp = BlueprintManagerController.LoadBlueprintSlot(slotIndex, true)
			modalBusy = false
			if ok then
				closeModalDialog()
			else
				setModalError((resp and resp.ErrorMessage) or BuildState.LastError or "No se pudo cargar el slot.")
			end
		end)
	end)
end

local function openSaveBeforeClearSlotPicker()
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(486, 356)
	modalTitleLbl.Text = "Elegir slot antes de vaciar el taller"
	modalBodyLbl.Text = "Seleccioná un slot vacío para guardar o un slot ocupado para sobrescribir. El taller solo se vaciará si el guardado se confirma en el servidor:"
	modalContentFrame.Position = UDim2.fromOffset(12, 92)
	modalContentFrame.Size = UDim2.new(1, -24, 1, -164)
	modalContentFrame.Visible = true
	modalOverlay.Visible = true

	for i = 1, GameConfig.Blueprints.MaxSlots do
		local slot = getSlotSummary(i)
		local pickCard = Instance.new("Frame")
		pickCard.Name = `PickClearSlot_{i}`
		pickCard.LayoutOrder = i
		pickCard.Size = UDim2.new(1, 0, 0, 56)
		pickCard.BackgroundColor3 = if slot.IsOccupied then Color3.fromRGB(32, 42, 62) else Color3.fromRGB(24, 30, 42)
		pickCard.ZIndex = 43
		pickCard.Parent = modalContentFrame
		styleCorner(pickCard, 8)
		styleStroke(pickCard, Color3.fromRGB(68, 90, 132), 1)

		local infoText = if slot.IsOccupied
			then `SLOT {i} • {slot.Name} ({slot.PieceCount} pzs)`
			else `SLOT {i} • Vacío (disponible)`
		local infoLbl = makeLabel("PickSlotInfo", infoText, UDim2.new(1, -150, 1, 0), pickCard)
		infoLbl.Position = UDim2.fromOffset(10, 0)
		infoLbl.Font = Enum.Font.GothamSemibold
		infoLbl.TextSize = 12
		infoLbl.ZIndex = 44

		local pickBtn = makeButton(
			"PickSlotActionBtn",
			if slot.IsOccupied then "Sobrescribir" else "Guardar acá",
			if slot.IsOccupied then Color3.fromRGB(196, 124, 44) else Color3.fromRGB(44, 146, 88),
			UDim2.fromOffset(126, 30),
			pickCard
		)
		pickBtn.Position = UDim2.new(1, -134, 0.5, -15)
		pickBtn.TextSize = 12
		pickBtn.ZIndex = 44
		pickBtn.Activated:Connect(function()
			if modalBusy then
				return
			end
			if slot.IsOccupied then
				openOverwriteStep1Dialog(i, true)
			else
				openSaveEmptySlotDialog(i, true)
			end
		end)
	end

	addModalButton("BackToClearBtn", "Volver", Color3.fromRGB(72, 78, 92), 1, 96, function()
		openClearWorkshopDialog()
	end)
	addModalButton("CancelPickClearBtn", "Cancelar", Color3.fromRGB(96, 62, 66), 2, 96, function()
		closeModalDialog()
	end)
end

local function openClearFinalConfirmDialog()
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(456, 206)
	modalTitleLbl.Text = "Confirmación final: Limpiar taller"
	modalBodyLbl.Text = `Se limpiarán las {#BuildState.BlueprintPieces} piezas actuales del taller sin guardarlas. Tus tarjetas guardadas (Slots 1-3) e inventario NO se verán afectados.`
	modalOverlay.Visible = true

	addModalButton("CancelFinalClearBtn", "Cancelar", Color3.fromRGB(72, 78, 92), 1, 96, function()
		closeModalDialog()
	end)
	addModalButton("ConfirmFinalClearBtn", "Sí, vaciar taller", Color3.fromRGB(194, 62, 58), 2, 138, function()
		modalBusy = true
		setModalError(nil)
		task.spawn(function()
			local ok, resp = BlueprintManagerController.ClearWorkshop()
			modalBusy = false
			if ok then
				closeModalDialog()
			else
				setModalError((resp and resp.ErrorMessage) or BuildState.LastError or "No se pudo vaciar el taller.")
			end
		end)
	end)
end

openClearWorkshopDialog = function()
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(468, 212)
	modalTitleLbl.Text = "Vaciar taller"
	modalBodyLbl.Text = "¿Estás seguro de que querés vaciar el taller? Podés guardar tu vehículo actual en un slot antes de limpiar."
	modalOverlay.Visible = true

	addModalButton("ClearCancelBtn", "Cancelar", Color3.fromRGB(72, 78, 92), 1, 90, function()
		closeModalDialog()
	end)
	addModalButton("ClearCleanOnlyBtn", "Limpiar taller", Color3.fromRGB(186, 68, 60), 2, 122, function()
		openClearFinalConfirmDialog()
	end)
	addModalButton("ClearSaveFirstBtn", "Guardar vehículo actual", Color3.fromRGB(44, 146, 88), 3, 166, function()
		openSaveBeforeClearSlotPicker()
	end)
end

local function openRecoverLegacyDialog(entry: any)
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(476, 344)
	modalTitleLbl.Text = `Recuperar diseño heredado`
	modalBodyLbl.Text = `Elegí en cuál de los 3 slots guardar '{entry.Name}' ({entry.PieceCount} pzs):`
	modalContentFrame.Position = UDim2.fromOffset(12, 82)
	modalContentFrame.Size = UDim2.new(1, -24, 1, -154)
	modalContentFrame.Visible = true
	modalOverlay.Visible = true

	for i = 1, GameConfig.Blueprints.MaxSlots do
		local slot = getSlotSummary(i)
		local row = Instance.new("Frame")
		row.LayoutOrder = i
		row.Size = UDim2.new(1, 0, 0, 50)
		row.BackgroundColor3 = Color3.fromRGB(28, 36, 52)
		row.ZIndex = 43
		row.Parent = modalContentFrame
		styleCorner(row, 7)

		local lbl = makeLabel(
			"TargetSlotLbl",
			if slot.IsOccupied then `SLOT {i} (Ocupado: {slot.Name})` else `SLOT {i} (Vacío)`,
			UDim2.new(1, -136, 1, 0),
			row
		)
		lbl.Position = UDim2.fromOffset(8, 0)
		lbl.TextSize = 12
		lbl.ZIndex = 44

		local recBtn = makeButton(
			"RecoverToSlotBtn",
			if slot.IsOccupied then "Reemplazar" else "Recuperar",
			if slot.IsOccupied then Color3.fromRGB(190, 118, 42) else Color3.fromRGB(52, 128, 186),
			UDim2.fromOffset(114, 28),
			row
		)
		recBtn.Position = UDim2.new(1, -122, 0.5, -14)
		recBtn.TextSize = 12
		recBtn.ZIndex = 44
		recBtn.Activated:Connect(function()
			if modalBusy then
				return
			end
			modalBusy = true
			setModalError(nil)
			task.spawn(function()
				local step = if slot.IsOccupied then 2 else 1
				local ok, resp = BlueprintManagerController.RecoverLegacyBlueprint(entry.OriginalBlueprintId, i, step)
				modalBusy = false
				if ok then
					closeModalDialog()
				else
					setModalError((resp and resp.ErrorMessage) or BuildState.LastError or "No se pudo recuperar el diseño.")
				end
			end)
		end)
	end

	addModalButton("CancelRecoverBtn", "Cancelar", Color3.fromRGB(72, 78, 92), 1, 96, function()
		closeModalDialog()
	end)
end

local function styleActionButton(btn: TextButton, enabled: boolean, enabledColor: Color3)
	btn.Active = enabled
	btn.AutoButtonColor = enabled
	btn.BackgroundColor3 = if enabled then enabledColor else Color3.fromRGB(56, 62, 74)
	btn.TextColor3 = if enabled then Color3.fromRGB(242, 246, 255) else Color3.fromRGB(145, 152, 168)
end

local function formatSlotListText(slots: { number }?): string
	if not slots or #slots == 0 then
		return "Ninguno"
	end
	local labels: { string } = table.create(#slots)
	for _, sIdx in ipairs(slots) do
		table.insert(labels, `Slot {sIdx}`)
	end
	return table.concat(labels, ", ")
end

local function openUnlinkConfirmDialog(
	targetItemId: string?,
	targetUnitId: string?,
	displayTitle: string,
	blockedInWorkshop: boolean,
	blockedSlots: { number }
)
	closeModalDialog()
	modalDialog.Size = UDim2.fromOffset(474, 240)
	modalTitleLbl.Text = "Desvincular referencias de blueprints"

	local locations: { string } = {}
	if blockedInWorkshop then
		table.insert(locations, "Taller actual")
	end
	if #blockedSlots > 0 then
		table.insert(locations, formatSlotListText(blockedSlots))
	end
	local locText = if #locations > 0 then table.concat(locations, " y ") else "diseños afectados"

	modalBodyLbl.Text =
		`No es posible vender '{displayTitle}' mientras siga referenciado en: {locText}.\n\n`
		.. `¿Deseas desvincular únicamente esas piezas? Se quitarán solo los bloques/unidades correspondientes de los diseños afectados y se conservará el resto de cada vehículo intacto.`
	modalOverlay.Visible = true

	addModalButton("CancelUnlinkBtn", "Cancelar", Color3.fromRGB(72, 78, 92), 1, 102, function()
		closeModalDialog()
	end)
	addModalButton("ConfirmUnlinkBtn", "Desvincular piezas", Color3.fromRGB(196, 114, 42), 2, 148, function()
		if modalBusy then
			return
		end
		modalBusy = true
		setModalError(nil)
		task.spawn(function()
			local ok, resp = BlueprintManagerController.UnlinkInventoryFromBlueprints(
				targetItemId,
				targetUnitId,
				nil,
				true
			)
			modalBusy = false
			if ok then
				closeModalDialog()
			else
				setModalError((resp and resp.ErrorMessage) or BuildState.LastError or "No se pudieron desvincular los diseños.")
			end
		end)
	end)
end

local function rebuildInventoryPanel()
	for _, child in ipairs(invScroll:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local inv = BuildState.Inventory
	if not inv then
		local loadLbl = makeLabel("InvEmpty", "Cargando inventario autoritativo desde el servidor...", UDim2.new(1, 0, 0, 28), invScroll)
		loadLbl.TextColor3 = Color3.fromRGB(175, 195, 220)
		loadLbl.TextSize = 12
		return
	end

	local busy = BlueprintManagerController.IsBusy()
	local orderSeq = 0

	local commonHdr = makeLabel("CommonHdr", "PIEZAS Y OBJETOS ACUMULABLES", UDim2.new(1, 0, 0, 20), invScroll)
	commonHdr.LayoutOrder = orderSeq
	commonHdr.Font = Enum.Font.GothamBold
	commonHdr.TextSize = 11
	commonHdr.TextColor3 = Color3.fromRGB(130, 215, 200)

	for _, entry in ipairs(inv.Items or {}) do
		if entry.InventoryKind == "Stackable" then
			orderSeq += 1
			local row = Instance.new("Frame")
			row.Name = `InvItem_{entry.ItemId}`
			row.LayoutOrder = orderSeq
			row.Size = UDim2.new(1, 0, 0, 62)
			row.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
			row.Parent = invScroll
			styleCorner(row, 7)
			styleStroke(row, Color3.fromRGB(58, 76, 108), 1)

			local titleLbl = makeLabel(
				"Title",
				`{entry.DisplayName} [{entry.CategoryDisplayName}]`,
				UDim2.new(1, -124, 0, 18),
				row
			)
			titleLbl.Position = UDim2.fromOffset(8, 5)
			titleLbl.Font = Enum.Font.GothamBold
			titleLbl.TextSize = 12

			local descLbl = makeLabel("Desc", entry.Description, UDim2.new(1, -124, 0, 15), row)
			descLbl.Position = UDim2.fromOffset(8, 23)
			descLbl.TextSize = 10
			descLbl.TextColor3 = Color3.fromRGB(172, 185, 208)
			descLbl.TextTruncate = Enum.TextTruncate.AtEnd

			local slotText = formatSlotListText(entry.BlockedSlotIndices)
			local statsLbl = makeLabel(
				"Counts",
				`Poseído: {entry.OwnedQuantity} | En taller: {entry.WorkshopReservedQuantity} | Disp: {entry.AvailableToPlace} | Slots: {slotText} | Vendible: {entry.SellableQuantity}`,
				UDim2.new(1, -124, 0, 16),
				row
			)
			statsLbl.Position = UDim2.fromOffset(8, 40)
			statsLbl.TextSize = 10
			statsLbl.TextColor3 = Color3.fromRGB(160, 215, 190)
			statsLbl.TextTruncate = Enum.TextTruncate.AtEnd

			local canSellOne = not busy and entry.SellableQuantity >= 1 and type(entry.SellPrice) == "number"
			local isBlockedByRefs = entry.OwnedQuantity >= 1 and entry.SellableQuantity == 0
			local btnLabel = if isBlockedByRefs
				then "Desvincular"
				elseif type(entry.SellPrice) == "number" then `Vender +${math.floor(entry.SellPrice)}`
				else "Sin valoración"
			local btnBg = if canSellOne
				then Color3.fromRGB(46, 134, 92)
				elseif isBlockedByRefs then Color3.fromRGB(176, 108, 42)
				else Color3.fromRGB(56, 62, 74)

			local actionBtn = makeButton("ItemActionBtn", btnLabel, btnBg, UDim2.fromOffset(102, 28), row)
			actionBtn.Position = UDim2.new(1, -110, 0.5, -14)
			actionBtn.TextSize = 11
			styleActionButton(actionBtn, (canSellOne or (isBlockedByRefs and not busy)), btnBg)

			actionBtn.Activated:Connect(function()
				if BlueprintManagerController.IsBusy() then
					return
				end
				if isBlockedByRefs then
					openUnlinkConfirmDialog(
						entry.ItemId,
						nil,
						entry.DisplayName,
						entry.WorkshopReservedQuantity > 0,
						entry.BlockedSlotIndices or {}
					)
				elseif canSellOne then
					task.spawn(function()
						local ok, resp = BlueprintManagerController.SellInventoryItem(entry.ItemId, 1, nil)
						if not ok and resp and resp.ErrorCode == BuildProtocol.ErrorCodes.SellBlockedByReferences then
							openUnlinkConfirmDialog(
								entry.ItemId,
								nil,
								entry.DisplayName,
								resp.BlockedInWorkshop == true,
								resp.BlockedSlotIndices or {}
							)
						end
					end)
				end
			end)
		end
	end

	orderSeq += 1
	local unitHdr = makeLabel("UnitHdr", `UNIDADES ÚNICAS — MOTORES Y PROPULSORES ({#(inv.UniqueUnits or {})})`, UDim2.new(1, 0, 0, 22), invScroll)
	unitHdr.LayoutOrder = orderSeq
	unitHdr.Font = Enum.Font.GothamBold
	unitHdr.TextSize = 11
	unitHdr.TextColor3 = Color3.fromRGB(240, 200, 120)

	if #(inv.UniqueUnits or {}) == 0 then
		orderSeq += 1
		local emptyUnits = makeLabel("EmptyUnits", "No posees unidades únicas en este momento.", UDim2.new(1, 0, 0, 22), invScroll)
		emptyUnits.LayoutOrder = orderSeq
		emptyUnits.TextSize = 11
		emptyUnits.TextColor3 = Color3.fromRGB(155, 168, 190)
	else
		for _, unit in ipairs(inv.UniqueUnits) do
			orderSeq += 1
			local uRow = Instance.new("Frame")
			uRow.Name = `InvUnit_{unit.ItemInstanceId}`
			uRow.LayoutOrder = orderSeq
			uRow.Size = UDim2.new(1, 0, 0, 56)
			uRow.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
			uRow.Parent = invScroll
			styleCorner(uRow, 7)
			styleStroke(uRow, Color3.fromRGB(84, 78, 128), 1)

			local uTitle = makeLabel("UnitTitle", `{unit.FullLabel} [{ItemCatalog.GetCategoryDisplayName(unit.Category)}]`, UDim2.new(1, -124, 0, 18), uRow)
			uTitle.Position = UDim2.fromOffset(8, 6)
			uTitle.Font = Enum.Font.GothamBold
			uTitle.TextSize = 12
			uTitle.TextTruncate = Enum.TextTruncate.AtEnd

			local refText = if unit.UsedInWorkshop then "Taller" else "Libre en taller"
			local slotsText = formatSlotListText(unit.ReferencedSlotIndices)
			local uMeta = makeLabel(
				"UnitMeta",
				`ID: {unit.ItemInstanceId} | Origen: {ItemCatalog.GetSourceTagLabel(unit.SourceTag)} | Estado: {refText} | Slots: {slotsText}`,
				UDim2.new(1, -124, 0, 16),
				uRow
			)
			uMeta.Position = UDim2.fromOffset(8, 28)
			uMeta.TextSize = 10
			uMeta.TextColor3 = Color3.fromRGB(178, 192, 218)
			uMeta.TextTruncate = Enum.TextTruncate.AtEnd

			local hasRefs = (unit.UsedInWorkshop == true) or #(unit.ReferencedSlotIndices or {}) > 0
			local canSellForMoney = unit.CanSellForMoney == true
			local canSellUnit = not busy and (unit.CanSell == true) and canSellForMoney
			local uBtnText = if hasRefs
				then "Desvincular"
				elseif not canSellForMoney then "Sin valoración"
				else "Vender"
			local uBtnBg = if hasRefs
				then Color3.fromRGB(176, 108, 42)
				elseif canSellUnit then Color3.fromRGB(46, 134, 92)
				else Color3.fromRGB(56, 62, 74)
			local uActionBtn = makeButton("UnitActionBtn", uBtnText, uBtnBg, UDim2.fromOffset(102, 28), uRow)
			uActionBtn.Position = UDim2.new(1, -110, 0.5, -14)
			uActionBtn.TextSize = 11
			styleActionButton(uActionBtn, (not busy and (hasRefs or canSellForMoney)), uBtnBg)

			uActionBtn.Activated:Connect(function()
				if BlueprintManagerController.IsBusy() then
					return
				end
				if hasRefs then
					openUnlinkConfirmDialog(
						unit.ItemId,
						unit.ItemInstanceId,
						unit.FullLabel,
						unit.UsedInWorkshop == true,
						unit.ReferencedSlotIndices or {}
					)
				elseif canSellUnit then
					task.spawn(function()
						local ok, resp = BlueprintManagerController.SellInventoryItem(unit.ItemId, 1, unit.ItemInstanceId)
						if not ok and resp and resp.ErrorCode == BuildProtocol.ErrorCodes.SellBlockedByReferences then
							openUnlinkConfirmDialog(
								unit.ItemId,
								unit.ItemInstanceId,
								unit.FullLabel,
								resp.BlockedInWorkshop == true,
								resp.BlockedSlotIndices or {}
							)
						end
					end)
				end
			end)
		end
	end
end

local function rebuildBlueprintCards()
	for _, child in ipairs(bpCardsScroll:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local draftPieceCount = #BuildState.BlueprintPieces
	local busy = BlueprintManagerController.IsBusy()
	local maxSlots = GameConfig.Blueprints.MaxSlots

	for slotIndex = 1, maxSlots do
		local slot = getSlotSummary(slotIndex)
		local isOccupied = slot.IsOccupied == true
		local isLoadedInWorkshop = isOccupied and (BuildState.LoadedSlotIndex == slotIndex)

		local card = Instance.new("Frame")
		card.Name = `SlotCard_{slotIndex}`
		card.LayoutOrder = slotIndex
		card.Size = UDim2.new(1, 0, 0, 96)
		card.BackgroundColor3 = if isLoadedInWorkshop
			then Color3.fromRGB(30, 46, 74)
			elseif isOccupied then Color3.fromRGB(25, 31, 45)
			else Color3.fromRGB(20, 24, 34)
		card.Parent = bpCardsScroll
		styleCorner(card, 8)
		styleStroke(
			card,
			if isLoadedInWorkshop
				then Color3.fromRGB(95, 165, 255)
				elseif isOccupied then Color3.fromRGB(64, 88, 128)
				else Color3.fromRGB(50, 58, 76),
			if isLoadedInWorkshop then 1.5 else 1
		)

		local slotBadge = makeLabel("SlotBadge", `SLOT {slotIndex}`, UDim2.fromOffset(64, 20), card, Enum.TextXAlignment.Center)
		slotBadge.Position = UDim2.fromOffset(8, 8)
		slotBadge.BackgroundTransparency = 0
		slotBadge.BackgroundColor3 = Color3.fromRGB(48, 66, 102)
		slotBadge.Font = Enum.Font.GothamBold
		slotBadge.TextSize = 11
		styleCorner(slotBadge, 5)

		local stateText = if isLoadedInWorkshop
			then "Guardado • En taller"
			elseif isOccupied then "Guardado"
			else "Vacío"
		local statePill = makeLabel("SlotStatePill", stateText, UDim2.fromOffset(132, 20), card, Enum.TextXAlignment.Center)
		statePill.Position = UDim2.fromOffset(78, 8)
		statePill.BackgroundTransparency = 0
		statePill.BackgroundColor3 = if isLoadedInWorkshop
			then Color3.fromRGB(38, 108, 164)
			elseif isOccupied then Color3.fromRGB(36, 114, 72)
			else Color3.fromRGB(52, 58, 72)
		statePill.Font = Enum.Font.GothamSemibold
		statePill.TextSize = 11
		styleCorner(statePill, 5)

		local titleLbl = makeLabel(
			"CardName",
			if isOccupied then slot.Name else "Slot vacío",
			UDim2.new(1, -224, 0, 20),
			card
		)
		titleLbl.Position = UDim2.fromOffset(218, 8)
		titleLbl.Font = Enum.Font.GothamBold
		titleLbl.TextSize = 13
		titleLbl.TextTruncate = Enum.TextTruncate.AtEnd
		titleLbl.TextColor3 = if isOccupied then Color3.fromRGB(242, 246, 255) else Color3.fromRGB(150, 160, 182)

		local metaStr = if isOccupied
			then `{slot.PieceCount} piezas  |  Última mod.: {formatShortTime(slot.UpdatedAt)}`
			else "0 piezas  |  Sin vehículo guardado"
		local metaLbl = makeLabel("CardMeta", metaStr, UDim2.new(1, -16, 0, 18), card)
		metaLbl.Position = UDim2.fromOffset(8, 33)
		metaLbl.TextColor3 = Color3.fromRGB(172, 188, 214)
		metaLbl.TextSize = 11

		local actionsRow = Instance.new("Frame")
		actionsRow.Name = "CardActionsRow"
		actionsRow.Position = UDim2.fromOffset(8, 58)
		actionsRow.Size = UDim2.new(1, -16, 0, 30)
		actionsRow.BackgroundTransparency = 1
		actionsRow.Parent = card

		local actionsLayout = Instance.new("UIListLayout")
		actionsLayout.FillDirection = Enum.FillDirection.Horizontal
		actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
		actionsLayout.Padding = UDim.new(0, 6)
		actionsLayout.Parent = actionsRow

		if not isOccupied then
			local saveBtn = makeButton(
				"SaveToSlotBtn",
				"Guardar vehículo del taller",
				Color3.fromRGB(44, 146, 88),
				UDim2.fromOffset(218, 28),
				actionsRow
			)
			saveBtn.LayoutOrder = 1
			saveBtn.TextSize = 12
			styleActionButton(saveBtn, (draftPieceCount > 0) and not busy, Color3.fromRGB(44, 146, 88))
			saveBtn.Activated:Connect(function()
				if draftPieceCount <= 0 or BlueprintManagerController.IsBusy() then
					return
				end
				openSaveEmptySlotDialog(slotIndex, false)
			end)
		else
			local loadBtn = makeButton("LoadSlotBtn", "Cargar", Color3.fromRGB(48, 114, 178), UDim2.fromOffset(86, 28), actionsRow)
			loadBtn.LayoutOrder = 1
			loadBtn.TextSize = 12
			styleActionButton(loadBtn, not busy, Color3.fromRGB(48, 114, 178))
			loadBtn.Activated:Connect(function()
				if BlueprintManagerController.IsBusy() then
					return
				end
				if #BuildState.BlueprintPieces > 0 then
					openLoadSlotWarningDialog(slotIndex)
				else
					task.spawn(function()
						local ok, resp = BlueprintManagerController.LoadBlueprintSlot(slotIndex, false)
						if not ok and resp and resp.ErrorCode == BuildProtocol.ErrorCodes.UnsavedWorkshopConfirmationRequired then
							openLoadSlotWarningDialog(slotIndex)
						end
					end)
				end
			end)

			local overwriteBtn = makeButton("OverwriteSlotBtn", "Sobrescribir", Color3.fromRGB(190, 118, 42), UDim2.fromOffset(104, 28), actionsRow)
			overwriteBtn.LayoutOrder = 2
			overwriteBtn.TextSize = 12
			styleActionButton(overwriteBtn, (draftPieceCount > 0) and not busy, Color3.fromRGB(190, 118, 42))
			overwriteBtn.Activated:Connect(function()
				if draftPieceCount <= 0 or BlueprintManagerController.IsBusy() then
					return
				end
				openOverwriteStep1Dialog(slotIndex, false)
			end)

			local renameBtn = makeButton("RenameSlotBtn", "Renombrar", Color3.fromRGB(92, 86, 152), UDim2.fromOffset(92, 28), actionsRow)
			renameBtn.LayoutOrder = 3
			renameBtn.TextSize = 12
			styleActionButton(renameBtn, not busy, Color3.fromRGB(92, 86, 152))
			renameBtn.Activated:Connect(function()
				if BlueprintManagerController.IsBusy() then
					return
				end
				openRenameSlotDialog(slotIndex)
			end)

			local deleteBtn = makeButton("DeleteSlotBtn", "Eliminar", Color3.fromRGB(168, 58, 62), UDim2.fromOffset(84, 28), actionsRow)
			deleteBtn.LayoutOrder = 4
			deleteBtn.TextSize = 12
			styleActionButton(deleteBtn, not busy, Color3.fromRGB(168, 58, 62))
			deleteBtn.Activated:Connect(function()
				if BlueprintManagerController.IsBusy() then
					return
				end
				openDeleteSlotDialog(slotIndex)
			end)
		end
	end

	local legacyList = BuildState.LegacyOverflow
	if #legacyList > 0 then
		local legacyHeader = makeLabel(
			"LegacySectionTitle",
			`Diseños heredados preservados ({BuildState.LegacyOverflowCount}) — sin pérdida de datos:`,
			UDim2.new(1, 0, 0, 22),
			bpCardsScroll
		)
		legacyHeader.LayoutOrder = 10
		legacyHeader.Font = Enum.Font.GothamSemibold
		legacyHeader.TextSize = 11
		legacyHeader.TextColor3 = Color3.fromRGB(245, 206, 128)

		for idx, entry in ipairs(legacyList) do
			local legRow = Instance.new("Frame")
			legRow.Name = `LegacyRow_{entry.OriginalBlueprintId}`
			legRow.LayoutOrder = 10 + idx
			legRow.Size = UDim2.new(1, 0, 0, 42)
			legRow.BackgroundColor3 = Color3.fromRGB(32, 30, 26)
			legRow.Parent = bpCardsScroll
			styleCorner(legRow, 7)
			styleStroke(legRow, Color3.fromRGB(168, 126, 62), 1)

			local legLbl = makeLabel(
				"LegName",
				`{entry.Name} ({entry.PieceCount} pzs) • {formatShortTime(entry.UpdatedAt)}`,
				UDim2.new(1, -118, 1, 0),
				legRow
			)
			legLbl.Position = UDim2.fromOffset(8, 0)
			legLbl.TextSize = 11
			legLbl.TextTruncate = Enum.TextTruncate.AtEnd

			local recoverBtn = makeButton("RecoverLegBtn", "Recuperar", Color3.fromRGB(178, 122, 46), UDim2.fromOffset(96, 26), legRow)
			recoverBtn.Position = UDim2.new(1, -104, 0.5, -13)
			recoverBtn.TextSize = 11
			styleActionButton(recoverBtn, not busy, Color3.fromRGB(178, 122, 46))
			recoverBtn.Activated:Connect(function()
				if BlueprintManagerController.IsBusy() then
					return
				end
				openRecoverLegacyDialog(entry)
			end)
		end
	end
end

local wheelInspector = WheelInspectorPanel.Mount(screenGui, {
	OnWheelPanelOpened = function()
		standPanel.Visible = false
		launchPanel.Visible = false
		blueprintsPanel.Visible = false
		inventoryPanel.Visible = false
	end,
	IsBlockedByOtherPanel = function()
		return standPanel.Visible or launchPanel.Visible or blueprintsPanel.Visible or inventoryPanel.Visible or modalOverlay.Visible
	end,
})

local engineInspector = EngineInspectorPanel.Mount(screenGui, {
	OnEnginePanelOpened = function()
		standPanel.Visible = false
		launchPanel.Visible = false
		blueprintsPanel.Visible = false
		inventoryPanel.Visible = false
	end,
	IsBlockedByOtherPanel = function()
		return standPanel.Visible or launchPanel.Visible or blueprintsPanel.Visible or inventoryPanel.Visible or modalOverlay.Visible
	end,
})

local boosterInspector = BoosterInspectorPanel.Mount(screenGui, {
	OnBoosterPanelOpened = function()
		standPanel.Visible = false
		launchPanel.Visible = false
		blueprintsPanel.Visible = false
		inventoryPanel.Visible = false
	end,
	IsBlockedByOtherPanel = function()
		return standPanel.Visible or launchPanel.Visible or blueprintsPanel.Visible or inventoryPanel.Visible or modalOverlay.Visible
	end,
})

local drivingHud = VehicleDrivingController.Mount(screenGui)

local function refreshUI()
	local occupiedCount = 0
	for _, slot in ipairs(BuildState.BlueprintSlots) do
		if slot.IsOccupied then
			occupiedCount += 1
		end
	end
	local maxSlots = GameConfig.Blueprints.MaxSlots
	local draftCount = #BuildState.BlueprintPieces
	local busy = BlueprintManagerController.IsBusy()
	local loadedSlotStr = if BuildState.LoadedSlotIndex then ` • Cargado de Slot {BuildState.LoadedSlotIndex}` else ""
	local dirtySuffix = if BuildState.HasUnsavedChanges and draftCount > 0 then " *" else ""

	bpToggleBtn.Text = `Blueprints ({occupiedCount}/{maxSlots}){dirtySuffix}`
	bpTitleLbl.Text = `Blueprints ({occupiedCount}/{maxSlots} guardados)`
	if draftCount == 0 then
		activeStatusLbl.Text = "Taller actual: vacío (0 piezas)"
	else
		activeStatusLbl.Text = `Taller actual: {BuildState.BlueprintName} ({draftCount} pzs){loadedSlotStr}{dirtySuffix}`
	end
	if BuildState.LastError and #BuildState.LastError > 0 then
		bpFeedbackLbl.Text = `Error: {BuildState.LastError}`
		bpFeedbackLbl.TextColor3 = Color3.fromRGB(255, 132, 132)
		invFeedbackLbl.Text = `Error: {BuildState.LastError}`
		invFeedbackLbl.TextColor3 = Color3.fromRGB(255, 132, 132)
	elseif BuildState.StatusMessage and #BuildState.StatusMessage > 0 then
		bpFeedbackLbl.Text = BuildState.StatusMessage
		bpFeedbackLbl.TextColor3 = Color3.fromRGB(154, 224, 182)
		invFeedbackLbl.Text = BuildState.StatusMessage
		invFeedbackLbl.TextColor3 = Color3.fromRGB(154, 224, 182)
	else
		bpFeedbackLbl.Text = "El diseño del taller se guarda explícitamente en una tarjeta (Slot 1-3)."
		bpFeedbackLbl.TextColor3 = Color3.fromRGB(165, 180, 205)
		invFeedbackLbl.Text = "Administra tus piezas acumulables, unidades únicas de motores/propulsores y referencias en slots."
		invFeedbackLbl.TextColor3 = Color3.fromRGB(165, 195, 220)
	end

	local editingAllowed = BuildState.IsEditingMode()
	local runtimeState = BuildState.RuntimeState
	local states = GameConfig.Runtime.States
	local runtimeActive = BuildState.IsRuntimeActive()
	local isOwner = StandController.IsOwner()

	bpToggleBtn.Active = editingAllowed
	standToggleBtn.Visible = isOwner
	standToggleBtn.Active = editingAllowed

	local canClear = editingAllowed and draftCount > 0 and not busy
	clearWorkshopBtn.Active = canClear
	clearWorkshopBtn.AutoButtonColor = canClear
	clearWorkshopBtn.BackgroundColor3 = if canClear
		then Color3.fromRGB(178, 72, 62)
		else Color3.fromRGB(58, 64, 76)
	clearWorkshopBtn.TextColor3 = if canClear
		then Color3.fromRGB(244, 246, 255)
		else Color3.fromRGB(140, 148, 165)

	if not editingAllowed then
		bpToggleBtn.BackgroundColor3 = Color3.fromRGB(64, 70, 82)
		invToggleBtn.BackgroundColor3 = Color3.fromRGB(64, 70, 82)
		standToggleBtn.BackgroundColor3 = Color3.fromRGB(64, 70, 82)
		blueprintsPanel.Visible = false
		inventoryPanel.Visible = false
		standPanel.Visible = false
		if modalOverlay.Visible then
			closeModalDialog()
		end
	else
		bpToggleBtn.BackgroundColor3 = Color3.fromRGB(48, 86, 152)
		invToggleBtn.BackgroundColor3 = Color3.fromRGB(44, 130, 122)
		standToggleBtn.BackgroundColor3 = Color3.fromRGB(110, 70, 175)
	end

	runtimeBar.Visible = runtimeActive or runtimeState == states.Launching or runtimeState == states.ReturningToWorkshop
	if runtimeState == states.Driving then
		runtimeBadgeLbl.Text = "Vehículo activo • Conduciendo"
		runtimeBadgeLbl.TextColor3 = Color3.fromRGB(150, 240, 178)
		exitSeatBtn.Visible = true
	elseif runtimeState == states.OnFootRuntime then
		runtimeBadgeLbl.Text = "Vehículo activo • A pie"
		runtimeBadgeLbl.TextColor3 = Color3.fromRGB(245, 208, 120)
		exitSeatBtn.Visible = false
	elseif runtimeState == states.ReturningToWorkshop then
		runtimeBadgeLbl.Text = "Regresando al taller..."
		runtimeBadgeLbl.TextColor3 = Color3.fromRGB(205, 215, 235)
		exitSeatBtn.Visible = false
	elseif runtimeState == states.Launching then
		runtimeBadgeLbl.Text = "Lanzando vehículo..."
		runtimeBadgeLbl.TextColor3 = Color3.fromRGB(205, 215, 235)
		exitSeatBtn.Visible = false
	end

	returnWorkshopBtn.Active = not BuildState.RuntimeActionInFlight and runtimeActive
	resetVehicleBtn.Active = not BuildState.RuntimeActionInFlight and runtimeActive
 local occupied = VehicleSeatController.IsSeated()
 if occupied then
  runtimeBar.Visible = true
  exitSeatBtn.Visible = true
  if runtimeState ~= states.Driving then runtimeBadgeLbl.Text = "Vehículo activo • Pasajero" end
 end
 exitSeatBtn.Active = not BuildState.RuntimeActionInFlight and occupied

	if runtimeState == states.PreparingLaunch then
		launchNowBtn.Text = "Preparando..."
		launchNowBtn.BackgroundColor3 = Color3.fromRGB(178, 130, 50)
		launchNowBtn.Active = false
	elseif runtimeState == states.Launching then
		launchNowBtn.Text = "Lanzando..."
		launchNowBtn.BackgroundColor3 = Color3.fromRGB(178, 130, 50)
		launchNowBtn.Active = false
	elseif runtimeState == states.ReturningToWorkshop then
		launchNowBtn.Text = "Regresando..."
		launchNowBtn.BackgroundColor3 = Color3.fromRGB(130, 90, 62)
		launchNowBtn.Active = false
	elseif runtimeActive then
		launchNowBtn.Text = "Vehículo activo"
		launchNowBtn.BackgroundColor3 = Color3.fromRGB(42, 136, 152)
		launchNowBtn.Active = false
	elseif BuildState.RuntimeErrorMessage then
		launchNowBtn.Text = "Error de lanzamiento"
		launchNowBtn.BackgroundColor3 = Color3.fromRGB(184, 62, 62)
		launchNowBtn.Active = isOwner and not BuildState.RuntimeActionInFlight
	elseif BuildState.LaunchPrepReport and BuildState.LaunchPrepReport.Ready then
		launchNowBtn.Text = "Lanzar"
		launchNowBtn.BackgroundColor3 = Color3.fromRGB(46, 162, 88)
		launchNowBtn.Active = isOwner and not BuildState.RuntimeActionInFlight
	else
		launchNowBtn.Text = "Lanzar"
		launchNowBtn.BackgroundColor3 = Color3.fromRGB(46, 136, 82)
		launchNowBtn.Active = isOwner and not BuildState.RuntimeActionInFlight
	end

	standVehicleInfoLbl.Text = `{BuildState.BlueprintName} | {#BuildState.BlueprintPieces} piezas`
	local pres = BuildState.GetAssemblyOffset()
	local dynBounds = StandController.GetDynamicBounds()
	heightLbl.Text = string.format(
		"Altura (Y): %+.2f  [%.1f..%.1f]",
		pres.HeightOffset,
		dynBounds.MinHeightOffset,
		dynBounds.MaxHeightOffset
	)
	lateralLbl.Text = string.format(
		"Lateral (X): %+.2f  [%+.1f..%+.1f]",
		pres.LateralOffset,
		dynBounds.MinLateralOffset,
		dynBounds.MaxLateralOffset
	)
	standStepBtn.Text = if fineMode
		then `Paso: Fino ({GameConfig.Stand.FineStep} | {GameConfig.Stand.ContinuousFineSpeed} st/s)`
		else `Paso: Normal ({GameConfig.Stand.NormalStep} | {GameConfig.Stand.ContinuousNormalSpeed} st/s)`

	if BuildState.LastError and #BuildState.LastError > 0 then
		standFeedbackLbl.Text = BuildState.LastError
		standFeedbackLbl.TextColor3 = Color3.fromRGB(245, 118, 118)
	elseif BuildState.StatusMessage and #BuildState.StatusMessage > 0 then
		standFeedbackLbl.Text = BuildState.StatusMessage
		standFeedbackLbl.TextColor3 = Color3.fromRGB(165, 224, 178)
	else
		standFeedbackLbl.Text = "Desplazamiento temporal del taller (sin alterar blueprint)"
		standFeedbackLbl.TextColor3 = Color3.fromRGB(165, 210, 175)
	end

	local report = BuildState.LaunchPrepReport
	for _, child in ipairs(launchSelectRow:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	launchSelectRow.Visible = false

	if report then
		local workshopCount = report.WorkshopPieceCount or 0
		local groupCount = report.DisconnectedGroupCount or 1
		local workshopSuffix = if workshopCount > 0
			then `\nTaller (excluidas del lanzamiento): {workshopCount} pzs en {math.max(0, groupCount - 1)} grupo(s)`
			else ""

		if report.Ready then
			launchPrepBtn.BackgroundColor3 = Color3.fromRGB(44, 148, 84)
			launchPrepBtn.Text = "Lanzamiento: Listo"
			local sz = report.BoundingSize or Vector3.zero
			local launchErrLine = if BuildState.RuntimeErrorMessage
				then `\nERROR DE LANZAMIENTO: {BuildState.RuntimeErrorMessage}`
				else ""
			local ptWarnSuffix = if report.PowertrainWarnings and #report.PowertrainWarnings > 0
				then ("\n⚠ " .. table.concat(report.PowertrainWarnings, "\n⚠ "))
				else ""
			local bstWarnSuffix = if report.BoosterWarnings and #report.BoosterWarnings > 0
				then ("\n⚠ " .. table.concat(report.BoosterWarnings, "\n⚠ "))
				else ""
			launchBodyLbl.Text = string.format(
				"ESTADO: LISTO PARA LANZAMIENTO\n"
					.. "Ensamblaje primario: %d pzs | DriverSeat: %d/1 (%s) | Motores: %d | Ruedas motrices: %d/%d\n"
					.. "Propulsores: %d (%d activos) | Nitro (RocketFuel): %.0f\n"
					.. "Dimensiones: %.1f x %.1f x %.1f studs | Holgura: %.2f%s%s%s%s",
				report.PieceCount,
				report.DriverSeatCount,
				tostring(report.DriverSeatPieceId),
				report.EngineCount or 0,
				report.DrivenWheelCount or 0,
				report.WheelCount or 0,
				report.BoosterCount or 0,
				report.FunctionalBoosterCount or 0,
				report.TotalNitroCapacity or 0,
				sz.X,
				sz.Y,
				sz.Z,
				report.GroundClearance or 0,
				workshopSuffix,
				ptWarnSuffix,
				bstWarnSuffix,
				launchErrLine
			)
			if BuildState.IsEditingMode() then
				launchSelectRow.Visible = true
				local launchFromPanelBtn = makeButton(
					"PanelLaunchBtn",
					"Lanzar vehículo ahora",
					Color3.fromRGB(46, 162, 88),
					UDim2.fromOffset(180, 26),
					launchSelectRow
				)
				launchFromPanelBtn.LayoutOrder = 1
				launchFromPanelBtn.Activated:Connect(function()
					task.spawn(function()
						local ok = VehicleLaunchController.LaunchVehicle()
						if ok then
							launchPanel.Visible = false
						end
					end)
				end)
			end
		else
			launchPrepBtn.BackgroundColor3 = Color3.fromRGB(178, 66, 62)
			launchPrepBtn.Text = `Lanzamiento: {tostring(report.ErrorCategory)}`
			local lines = {
				`ESTADO: NO LISTO ({tostring(report.ErrorCategory)} / {tostring(report.PrimaryErrorCode)})`,
				`Ensamblaje: {report.PieceCount} pzs | DriverSeat: {report.DriverSeatCount}/1 | Grupos: {groupCount}`,
			}
			if workshopCount > 0 then
				table.insert(lines, `Taller (sueltas/secundarias): {workshopCount} pzs`)
			end
			for i, iss in ipairs(report.Issues) do
				if i <= 3 then
					table.insert(lines, `• [{iss.Category}] {iss.Message}`)
				end
			end
			launchBodyLbl.Text = table.concat(lines, "\n")

			if report.NeedsPrimarySelection and report.AssemblyGroups then
				launchSelectRow.Visible = true
				local btnOrder = 0
				for _, grp in ipairs(report.AssemblyGroups) do
					if grp.HasDriverSeat and btnOrder < 4 then
						btnOrder += 1
						local pickBtn = makeButton(
							`PickPrimary_{grp.GroupId}`,
							`Vehículo #{btnOrder} ({grp.PieceCount} pzs)`,
							Color3.fromRGB(64, 125, 195),
							UDim2.fromOffset(138, 26),
							launchSelectRow
						)
						pickBtn.LayoutOrder = btnOrder
						pickBtn.TextSize = 11
						pickBtn.TextTruncate = Enum.TextTruncate.AtEnd
						pickBtn.Activated:Connect(function()
							task.spawn(function()
								local okSel = BlueprintManagerController.SelectPrimaryAssembly(grp.GroupId)
								if okSel then
									local okChk, chkRes = StandController.RunLaunchPrepCheck()
									if okChk and chkRes and chkRes.LaunchPrepReport then
										BuildState.SetLaunchPrepReport(chkRes.LaunchPrepReport)
									end
								end
							end)
						end)
					end
				end
			end
		end
	else
		launchPrepBtn.BackgroundColor3 = Color3.fromRGB(170, 110, 38)
		launchPrepBtn.Text = "Verificar Lanzamiento"
	end

	if blueprintsPanel.Visible then
		rebuildBlueprintCards()
	end
	if inventoryPanel.Visible then
		rebuildInventoryPanel()
	end

	wheelInspector.Refresh()
	engineInspector.Refresh()
	boosterInspector.Refresh()
	drivingHud.RefreshVisibility()
end

bpToggleBtn.Activated:Connect(function()
	if not BuildState.IsEditingMode() then
		return
	end
	blueprintsPanel.Visible = not blueprintsPanel.Visible
	if blueprintsPanel.Visible then
		launchPanel.Visible = false
		standPanel.Visible = false
		inventoryPanel.Visible = false
		rebuildBlueprintCards()
		task.spawn(function()
			BlueprintManagerController.RefreshSlots()
		end)
	end
	wheelInspector.Refresh()
	engineInspector.Refresh()
	boosterInspector.Refresh()
	drivingHud.RefreshVisibility()
end)

invToggleBtn.Activated:Connect(function()
	inventoryPanel.Visible = not inventoryPanel.Visible
	if inventoryPanel.Visible then
		launchPanel.Visible = false
		standPanel.Visible = false
		blueprintsPanel.Visible = false
		rebuildInventoryPanel()
		task.spawn(function()
			BlueprintManagerController.RefreshInventory()
		end)
	end
	wheelInspector.Refresh()
	engineInspector.Refresh()
	boosterInspector.Refresh()
	drivingHud.RefreshVisibility()
end)

invCloseBtn.Activated:Connect(function()
	inventoryPanel.Visible = false
	wheelInspector.Refresh()
	engineInspector.Refresh()
	boosterInspector.Refresh()
	drivingHud.RefreshVisibility()
end)

invRefreshBtn.Activated:Connect(function()
	task.spawn(function()
		BlueprintManagerController.RefreshInventory()
	end)
end)

bpCloseBtn.Activated:Connect(function()
	blueprintsPanel.Visible = false
	wheelInspector.Refresh()
	engineInspector.Refresh()
	boosterInspector.Refresh()
	drivingHud.RefreshVisibility()
end)

clearWorkshopBtn.Activated:Connect(function()
	if not BuildState.IsEditingMode() or #BuildState.BlueprintPieces <= 0 or BlueprintManagerController.IsBusy() then
		return
	end
	openClearWorkshopDialog()
end)

standToggleBtn.Activated:Connect(function()
	if not StandController.IsOwner() or not BuildState.IsEditingMode() then
		return
	end
	standPanel.Visible = not standPanel.Visible
	if standPanel.Visible then
		launchPanel.Visible = false
		blueprintsPanel.Visible = false
		inventoryPanel.Visible = false
	end
	wheelInspector.Refresh()
	engineInspector.Refresh()
	boosterInspector.Refresh()
	drivingHud.RefreshVisibility()
end)

standCloseBtn.Activated:Connect(function()
	standPanel.Visible = false
	wheelInspector.Refresh()
	engineInspector.Refresh()
	boosterInspector.Refresh()
	drivingHud.RefreshVisibility()
end)

launchPrepBtn.Activated:Connect(function()
	launchPanel.Visible = true
	blueprintsPanel.Visible = false
	inventoryPanel.Visible = false
	standPanel.Visible = false
	wheelInspector.Refresh()
	engineInspector.Refresh()
	boosterInspector.Refresh()
	task.spawn(function()
		StandController.RunLaunchPrepCheck()
	end)
end)

launchNowBtn.Activated:Connect(function()
	if not StandController.IsOwner() or not BuildState.IsEditingMode() or BuildState.RuntimeActionInFlight then
		return
	end
	blueprintsPanel.Visible = false
	standPanel.Visible = false
	task.spawn(function()
		local ok = VehicleLaunchController.LaunchVehicle()
		if not ok then
			launchPanel.Visible = true
		else
			launchPanel.Visible = false
		end
	end)
end)

returnWorkshopBtn.Activated:Connect(function()
	task.spawn(function()
		VehicleLaunchController.ReturnToWorkshop()
	end)
end)

resetVehicleBtn.Activated:Connect(function()
	task.spawn(function()
		VehicleLaunchController.ResetVehicle()
	end)
end)

exitSeatBtn.Activated:Connect(function()
	task.spawn(function()
		VehicleLaunchController.ExitVehicleSeat()
	end)
end)

launchCloseBtn.Activated:Connect(function()
	launchPanel.Visible = false
	wheelInspector.Refresh()
	engineInspector.Refresh()
	boosterInspector.Refresh()
	drivingHud.RefreshVisibility()
end)

standStepBtn.Activated:Connect(function()
	fineMode = not fineMode
	refreshUI()
end)

local activeHoldBtn: GuiButton? = nil

local function bindElevatorHoldButton(btn: GuiButton, axis: StandController.HoldAxis, dir: number)
	btn.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		activeHoldBtn = btn
		StandController.BeginContinuousHold(axis, dir, fineMode)
	end)

	btn.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		if activeHoldBtn == btn then
			activeHoldBtn = nil
			StandController.EndContinuousHold()
		end
	end)

	btn.MouseLeave:Connect(function()
		if activeHoldBtn == btn then
			activeHoldBtn = nil
			StandController.EndContinuousHold()
		end
	end)
end

bindElevatorHoldButton(heightUpBtn, "Height", 1)
bindElevatorHoldButton(heightDownBtn, "Height", -1)
bindElevatorHoldButton(rightBtn, "Lateral", 1)
bindElevatorHoldButton(leftBtn, "Lateral", -1)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if
		activeHoldBtn
		and (
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		)
	then
		activeHoldBtn = nil
		StandController.EndContinuousHold()
	end
end)

RunService.RenderStepped:Connect(function(dt: number)
	if StandController.IsHoldActive() then
		StandController.StepContinuousHold(dt)
	end
	if boosterInspector.Frame.Visible then
		boosterInspector.RefreshGuidePose()
	end
end)

resetStandBtn.Activated:Connect(function()
	activeHoldBtn = nil
	task.spawn(function()
		StandController.ResetStandOffset()
	end)
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt, triggerPlayer)
	if triggerPlayer ~= LocalPlayer then
		return
	end
	if prompt.Name == "StandPrompt" and StandController.IsOwner() and BuildState.IsEditingMode() then
		local assigned = BuildState.AssignedPlot
		if assigned and prompt:IsDescendantOf(assigned) then
			standPanel.Visible = true
			launchPanel.Visible = false
			refreshUI()
		end
	end
end)

local lastSyncedPlot: Model? = nil
local function syncManagementDataFromServer()
	task.spawn(function()
		BlueprintManagerController.RefreshSlots()
		BlueprintManagerController.RefreshInventory()
		VehicleLaunchController.RefreshRuntimeState()
	end)
end

VehicleSeatController.Start(refreshUI)
screenGui.Destroying:Connect(function() VehicleSeatController.Stop() end)

BuildState.Subscribe(function()
	refreshUI()
	if BuildState.AssignedPlot and BuildState.AssignedPlot ~= lastSyncedPlot then
		lastSyncedPlot = BuildState.AssignedPlot
		syncManagementDataFromServer()
	end
end)

LocalPlayer:GetAttributeChangedSignal(GameConfig.PlotAttributes.PlotId):Connect(function()
	if LocalPlayer:GetAttribute(GameConfig.PlotAttributes.PlotId) ~= nil then
		syncManagementDataFromServer()
	end
end)

refreshUI()
if BuildState.AssignedPlot then
	lastSyncedPlot = BuildState.AssignedPlot
end
if BuildState.AssignedPlot or LocalPlayer:GetAttribute(GameConfig.PlotAttributes.PlotId) ~= nil then
	syncManagementDataFromServer()
end

