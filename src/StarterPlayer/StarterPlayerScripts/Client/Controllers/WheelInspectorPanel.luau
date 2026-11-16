--!strict
--[=[
	WheelInspectorPanel
	Panel contextual PC/Mobile del Inspector de Ruedas en Modo Construcción:
	- Aparece automáticamente cuando el jugador selecciona una rueda colocada en Modo Edición.
	- Muestra rol geométrico detectado (Delantera/Trasera/Central, Izq/Der), origen (Auto vs Manual)
	  de cada campo y advertencias geométricas / ambigüedades sin bloquear edición.
	- Permite modificar dirección, suspensión, parámetros físicos y preparación de tracción (Fase 3.3)
	  usando botones stepper accesibles en PC y pantalla táctil, o restablecer a Auto.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local WheelAutoConfiguration = require(ReplicatedStorage.Shared.Building.WheelAutoConfiguration)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BuildState = require(script.Parent.BuildState)
local WheelConfigController = require(script.Parent.WheelConfigController)

export type WheelInspectorControllerHandle = {
	Frame: Frame,
	ReopenPill: TextButton,
	Refresh: () -> (),
	IsOpen: () -> boolean,
	SetDismissed: (dismissed: boolean) -> (),
	Destroy: () -> (),
}

local WheelInspectorPanel = {}

local AXLE_LABELS: { [string]: string } = {
	Front = "Delantera",
	Rear = "Trasera",
	Middle = "Central",
	SingleAxle = "Eje único",
}

local SIDE_LABELS: { [string]: string } = {
	Left = "Izquierda",
	Right = "Derecha",
	Center = "Centro",
}

local function addCorner(inst: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
end

local function addStroke(inst: GuiObject, color: Color3, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
end

local function makeLabel(name: string, text: string, size: UDim2, parent: Instance, alignX: Enum.TextXAlignment?): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Name = name
	lbl.Text = text
	lbl.Size = size
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = Color3.fromRGB(235, 242, 252)
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 12
	lbl.TextXAlignment = alignX or Enum.TextXAlignment.Left
	lbl.Parent = parent
	return lbl
end

local function makeButton(name: string, text: string, bg: Color3, size: UDim2, parent: Instance): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Text = text
	btn.Size = size
	btn.BackgroundColor3 = bg
	btn.TextColor3 = Color3.fromRGB(244, 248, 255)
	btn.Font = Enum.Font.GothamSemibold
	btn.TextSize = 11
	btn.AutoButtonColor = true
	btn.Active = true
	btn.BorderSizePixel = 0
	btn.Parent = parent
	addCorner(btn, 6)
	return btn
end

function WheelInspectorPanel.DescribeWheelSummary(
	resolved: VehicleTypes.ResolvedWheelConfig,
	analysis: VehicleTypes.VehicleWheelAnalysis
): {
	BadgeMode: string,
	RoleText: string,
	SeatText: string,
	MassText: string,
	Warnings: { string },
}
	local axleLabel = AXLE_LABELS[resolved.Analysis.AxleRole] or resolved.Analysis.AxleRole
	local sideLabel = SIDE_LABELS[resolved.Analysis.SideRole] or resolved.Analysis.SideRole

	local manualCount = 0
	local totalTracked = 0
	for _, src in pairs(resolved.Sources :: { [string]: string }) do
		totalTracked += 1
		if src == "Manual" then
			manualCount += 1
		end
	end

	local badge = "AUTO"
	if manualCount > 0 and manualCount < totalTracked then
		badge = "MIXTO"
	elseif manualCount >= totalTracked and manualCount > 0 then
		badge = "MANUAL"
	end

	local warnings: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, w in ipairs(resolved.Warnings) do
		if not seen[w] then
			seen[w] = true
			table.insert(warnings, w)
		end
	end
	if analysis.IsAmbiguous then
		for _, w in ipairs(analysis.AmbiguityWarnings) do
			if not seen[w] then
				seen[w] = true
				table.insert(warnings, w)
			end
		end
	end

	return {
		BadgeMode = badge,
		RoleText = `Rol: {axleLabel} · {sideLabel} (Eje {resolved.Analysis.AxleGroupIndex}/{math.max(1, resolved.Analysis.TotalAxleGroups)})`,
		SeatText = if analysis.HasSeatReference
			then "Referencia: DriverSeat detectado"
			else "Referencia: Heurística (sin DriverSeat)",
		MassText = string.format("Masa susp. est.: %.1f | Ruedas: %d", analysis.EstimatedChassisMass, analysis.WheelCount),
		Warnings = warnings,
	}
end

function WheelInspectorPanel.Mount(
	parentGui: Instance,
	hooks: {
		OnWheelPanelOpened: (() -> ())?,
		IsBlockedByOtherPanel: (() -> boolean)?,
	}?
): WheelInspectorControllerHandle
	local W = GameConfig.Wheels

	-- Panel contextual anclado en el borde derecho sin tocar barra superior ni EditorPanel inferior
	local frame = Instance.new("Frame")
	frame.Name = "WheelInspectorPanel"
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = UDim2.new(1, -14, 0, 68)
	frame.Size = UDim2.fromOffset(312, 376)
	frame.BackgroundColor3 = Color3.fromRGB(16, 21, 30)
	frame.BackgroundTransparency = 0.06
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 12
	frame.Parent = parentGui
	addCorner(frame, 10)
	addStroke(frame, Color3.fromRGB(78, 128, 188), 1.4)

	-- Píldora discreta por si el usuario cierra el inspector mientras sigue teniendo una rueda seleccionada
	local reopenPill = makeButton(
		"WheelInspectorReopenPill",
		"⚙ Rueda",
		Color3.fromRGB(36, 98, 158),
		UDim2.fromOffset(96, 30),
		parentGui
	)
	reopenPill.AnchorPoint = Vector2.new(1, 0)
	reopenPill.Position = UDim2.new(1, -14, 0, 68)
	reopenPill.Visible = false
	reopenPill.ZIndex = 11
	addStroke(reopenPill, Color3.fromRGB(115, 175, 235), 1)

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, -16, 0, 28)
	header.Position = UDim2.fromOffset(8, 6)
	header.BackgroundTransparency = 1
	header.Parent = frame

	local titleLbl = makeLabel("Title", "Inspector de Rueda", UDim2.new(1, -104, 1, 0), header)
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 14

	local modeBadge = Instance.new("TextLabel")
	modeBadge.Name = "ModeBadge"
	modeBadge.AnchorPoint = Vector2.new(1, 0.5)
	modeBadge.Position = UDim2.new(1, -30, 0.5, 0)
	modeBadge.Size = UDim2.fromOffset(66, 20)
	modeBadge.BackgroundColor3 = Color3.fromRGB(40, 118, 86)
	modeBadge.TextColor3 = Color3.fromRGB(242, 248, 255)
	modeBadge.Font = Enum.Font.GothamBold
	modeBadge.TextSize = 10
	modeBadge.Text = "AUTO"
	modeBadge.BorderSizePixel = 0
	modeBadge.Parent = header
	addCorner(modeBadge, 5)

	local closeBtn = makeButton("CloseBtn", "✕", Color3.fromRGB(98, 52, 56), UDim2.fromOffset(24, 24), header)
	closeBtn.AnchorPoint = Vector2.new(1, 0.5)
	closeBtn.Position = UDim2.new(1, 0, 0.5, 0)

	local summaryBox = Instance.new("Frame")
	summaryBox.Name = "SummaryBox"
	summaryBox.Position = UDim2.fromOffset(8, 36)
	summaryBox.Size = UDim2.new(1, -16, 0, 48)
	summaryBox.BackgroundColor3 = Color3.fromRGB(24, 32, 45)
	summaryBox.BorderSizePixel = 0
	summaryBox.Parent = frame
	addCorner(summaryBox, 7)

	local roleLbl = makeLabel("RoleLbl", "Rol: -", UDim2.new(1, -12, 0, 16), summaryBox)
	roleLbl.Position = UDim2.fromOffset(6, 4)
	roleLbl.Font = Enum.Font.GothamSemibold
	roleLbl.TextSize = 11
	roleLbl.TextColor3 = Color3.fromRGB(165, 220, 255)
	roleLbl.TextTruncate = Enum.TextTruncate.AtEnd

	local subInfoLbl = makeLabel("SubInfoLbl", "-", UDim2.new(1, -12, 0, 16), summaryBox)
	subInfoLbl.Position = UDim2.fromOffset(6, 23)
	subInfoLbl.TextSize = 10
	subInfoLbl.TextColor3 = Color3.fromRGB(178, 194, 214)
	subInfoLbl.TextTruncate = Enum.TextTruncate.AtEnd

	local warnLbl = makeLabel("WarnLbl", "", UDim2.new(1, -16, 0, 26), frame)
	warnLbl.Position = UDim2.fromOffset(8, 86)
	warnLbl.TextSize = 10
	warnLbl.TextWrapped = true
	warnLbl.TextColor3 = Color3.fromRGB(255, 204, 118)
	warnLbl.Visible = false

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "ControlsScroll"
	scroll.Position = UDim2.fromOffset(8, 88)
	scroll.Size = UDim2.new(1, -16, 1, -138)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 5
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.Parent = frame

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 6)
	listLayout.Parent = scroll

	local footer = Instance.new("Frame")
	footer.Name = "Footer"
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.new(0, 8, 1, -6)
	footer.Size = UDim2.new(1, -16, 0, 42)
	footer.BackgroundTransparency = 1
	footer.Parent = frame

	local resetAllBtn = makeButton(
		"ResetAllAutoBtn",
		"Restablecer todo a Auto",
		Color3.fromRGB(58, 90, 134),
		UDim2.new(1, 0, 0, 24),
		footer
	)
	local feedbackLbl = makeLabel("FeedbackLbl", "", UDim2.new(1, 0, 0, 15), footer)
	feedbackLbl.Position = UDim2.fromOffset(0, 26)
	feedbackLbl.TextSize = 10
	feedbackLbl.TextTruncate = Enum.TextTruncate.AtEnd

	local dismissedForPieceId: string? = nil
	local lastSelectedPieceId: string? = nil

	local function sendFieldUpdate(pieceId: string, fieldName: string, value: any)
		task.spawn(function()
			WheelConfigController.SetWheelField(pieceId, fieldName, value)
		end)
	end

	local function buildSectionHeader(text: string, order: number)
		local sec = makeLabel(`Sec_{order}`, text, UDim2.new(1, -4, 0, 16), scroll)
		sec.LayoutOrder = order
		sec.Font = Enum.Font.GothamBold
		sec.TextSize = 11
		sec.TextColor3 = Color3.fromRGB(130, 198, 255)
	end

	local function buildSegmentedSteeringRow(
		pieceId: string,
		resolved: VehicleTypes.ResolvedWheelConfig,
		order: number
	)
		local row = Instance.new("Frame")
		row.Name = "Row_SteeringMode"
		row.Size = UDim2.new(1, -4, 0, 32)
		row.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = scroll
		addCorner(row, 6)

		local lbl = makeLabel(
			"Label",
			`Dirección ({if resolved.Sources.SteeringMode == "Manual" then "Manual" else "Auto"})`,
			UDim2.fromOffset(108, 32),
			row
		)
		lbl.Position = UDim2.fromOffset(6, 0)
		lbl.TextSize = 11

		local modes: { { Id: VehicleTypes.WheelSteeringMode, Text: string } } = {
			{ Id = "Auto", Text = "Auto" },
			{ Id = "Enabled", Text = "Activa" },
			{ Id = "Disabled", Text = "Fija" },
		}
		for idx, item in ipairs(modes) do
			local active = resolved.SteeringMode == item.Id
			local bg = if active then Color3.fromRGB(48, 138, 98) else Color3.fromRGB(46, 56, 74)
			local btn = makeButton(`Btn_{item.Id}`, item.Text, bg, UDim2.fromOffset(56, 24), row)
			btn.Position = UDim2.fromOffset(114 + (idx - 1) * 59, 4)
			btn.TextSize = 10
			btn.Activated:Connect(function()
				sendFieldUpdate(pieceId, "SteeringMode", item.Id)
			end)
		end
	end

	local function buildBoolAutoRow(
		pieceId: string,
		label: string,
		fieldName: string,
		currentVal: boolean,
		isManual: boolean,
		trueText: string,
		falseText: string,
		order: number
	)
		local row = Instance.new("Frame")
		row.Name = `Row_{fieldName}`
		row.Size = UDim2.new(1, -4, 0, 30)
		row.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = scroll
		addCorner(row, 6)

		local lbl = makeLabel("Label", `{label} ({if isManual then "M" else "A"})`, UDim2.fromOffset(140, 30), row)
		lbl.Position = UDim2.fromOffset(6, 0)
		lbl.TextSize = 11

		local toggleBtn = makeButton(
			"ToggleBtn",
			if currentVal then trueText else falseText,
			if currentVal then Color3.fromRGB(46, 142, 92) else Color3.fromRGB(110, 74, 62),
			UDim2.fromOffset(92, 22),
			row
		)
		toggleBtn.Position = UDim2.fromOffset(148, 4)
		toggleBtn.Activated:Connect(function()
			sendFieldUpdate(pieceId, fieldName, not currentVal)
		end)

		local autoBtn = makeButton(
			"AutoBtn",
			"Auto",
			if isManual then Color3.fromRGB(66, 98, 142) else Color3.fromRGB(42, 48, 58),
			UDim2.fromOffset(44, 22),
			row
		)
		autoBtn.Position = UDim2.fromOffset(244, 4)
		autoBtn.TextSize = 10
		autoBtn.Active = isManual
		autoBtn.Activated:Connect(function()
			if isManual then
				sendFieldUpdate(pieceId, fieldName, nil)
			end
		end)
	end

	local function buildStepperRow(
		pieceId: string,
		label: string,
		fieldName: string,
		value: number,
		formatStr: string,
		step: number,
		minVal: number,
		maxVal: number,
		isManual: boolean,
		order: number
	)
		local row = Instance.new("Frame")
		row.Name = `Row_{fieldName}`
		row.Size = UDim2.new(1, -4, 0, 30)
		row.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = scroll
		addCorner(row, 6)

		local lbl = makeLabel("Label", `{label} ({if isManual then "M" else "A"})`, UDim2.fromOffset(112, 30), row)
		lbl.Position = UDim2.fromOffset(6, 0)
		lbl.TextSize = 11
		lbl.TextTruncate = Enum.TextTruncate.AtEnd

		local minusBtn = makeButton("MinusBtn", "-", Color3.fromRGB(58, 72, 96), UDim2.fromOffset(26, 22), row)
		minusBtn.Position = UDim2.fromOffset(118, 4)
		minusBtn.Activated:Connect(function()
			local nextVal = math.clamp(math.round((value - step) * 100) / 100, minVal, maxVal)
			sendFieldUpdate(pieceId, fieldName, nextVal)
		end)

		local valLbl = makeLabel("ValLbl", string.format(formatStr, value), UDim2.fromOffset(66, 30), row, Enum.TextXAlignment.Center)
		valLbl.Position = UDim2.fromOffset(146, 0)
		valLbl.Font = Enum.Font.GothamSemibold
		valLbl.TextSize = 11

		local plusBtn = makeButton("PlusBtn", "+", Color3.fromRGB(58, 72, 96), UDim2.fromOffset(26, 22), row)
		plusBtn.Position = UDim2.fromOffset(214, 4)
		plusBtn.Activated:Connect(function()
			local nextVal = math.clamp(math.round((value + step) * 100) / 100, minVal, maxVal)
			sendFieldUpdate(pieceId, fieldName, nextVal)
		end)

		local autoBtn = makeButton(
			"AutoBtn",
			"A",
			if isManual then Color3.fromRGB(66, 98, 142) else Color3.fromRGB(42, 48, 58),
			UDim2.fromOffset(44, 22),
			row
		)
		autoBtn.Position = UDim2.fromOffset(244, 4)
		autoBtn.TextSize = 10
		autoBtn.Active = isManual
		autoBtn.Activated:Connect(function()
			if isManual then
				sendFieldUpdate(pieceId, fieldName, nil)
			end
		end)
	end

	local function buildSignRow(
		pieceId: string,
		label: string,
		fieldName: string,
		currentSign: number,
		isManual: boolean,
		posText: string,
		negText: string,
		order: number
	)
		local row = Instance.new("Frame")
		row.Name = `Row_{fieldName}`
		row.Size = UDim2.new(1, -4, 0, 30)
		row.BackgroundColor3 = Color3.fromRGB(24, 30, 42)
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = scroll
		addCorner(row, 6)

		local lbl = makeLabel("Label", `{label} ({if isManual then "M" else "A"})`, UDim2.fromOffset(116, 30), row)
		lbl.Position = UDim2.fromOffset(6, 0)
		lbl.TextSize = 11

		local flipBtn = makeButton(
			"FlipBtn",
			if currentSign >= 0 then posText else negText,
			if currentSign >= 0 then Color3.fromRGB(54, 108, 162) else Color3.fromRGB(168, 108, 48),
			UDim2.fromOffset(116, 22),
			row
		)
		flipBtn.Position = UDim2.fromOffset(124, 4)
		flipBtn.TextSize = 10
		flipBtn.Activated:Connect(function()
			sendFieldUpdate(pieceId, fieldName, if currentSign >= 0 then -1 else 1)
		end)

		local autoBtn = makeButton(
			"AutoBtn",
			"A",
			if isManual then Color3.fromRGB(66, 98, 142) else Color3.fromRGB(42, 48, 58),
			UDim2.fromOffset(44, 22),
			row
		)
		autoBtn.Position = UDim2.fromOffset(244, 4)
		autoBtn.TextSize = 10
		autoBtn.Active = isManual
		autoBtn.Activated:Connect(function()
			if isManual then
				sendFieldUpdate(pieceId, fieldName, nil)
			end
		end)
	end

	local function rebuildControls(
		piece: VehicleTypes.BlueprintPiece,
		resolved: VehicleTypes.ResolvedWheelConfig
	)
		for _, child in ipairs(scroll:GetChildren()) do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end

		local manual = WheelAutoConfiguration.ExtractManualOverrides(piece)
		local pid = piece.InstanceId
		local order = 0
		local function nextOrder(): number
			order += 1
			return order
		end

		buildSectionHeader("DIRECCIÓN", nextOrder())
		buildSegmentedSteeringRow(pid, resolved, nextOrder())
		buildStepperRow(
			pid,
			"Ángulo máx",
			"MaxSteeringAngle",
			resolved.MaxSteeringAngle,
			"%.0f°",
			2,
			W.MinSteeringAngleDeg,
			W.MaxSteeringAngleDeg,
			manual ~= nil and manual.MaxSteeringAngle ~= nil,
			nextOrder()
		)
		buildStepperRow(
			pid,
			"Vel. giro",
			"SteeringSpeed",
			resolved.SteeringSpeed,
			"%.0f°/s",
			30,
			W.MinSteeringSpeedDegPerSec,
			W.MaxSteeringSpeedDegPerSec,
			manual ~= nil and manual.SteeringSpeed ~= nil,
			nextOrder()
		)
		buildSignRow(
			pid,
			"Sentido dir.",
			"SteeringDirectionMultiplier",
			resolved.SteeringDirectionMultiplier,
			manual ~= nil and manual.SteeringDirectionMultiplier ~= nil,
			"Normal (+1)",
			"Invertido (-1)",
			nextOrder()
		)

		buildSectionHeader("SUSPENSIÓN", nextOrder())
		buildBoolAutoRow(
			pid,
			"Suspensión",
			"SuspensionEnabled",
			resolved.SuspensionEnabled,
			resolved.Sources.SuspensionEnabled == "Manual",
			"Activa",
			"Fija",
			nextOrder()
		)
		buildStepperRow(
			pid,
			"Recorrido",
			"SuspensionTravel",
			resolved.SuspensionTravel,
			"%.2f st",
			0.1,
			W.MinSuspensionTravelStuds,
			W.MaxSuspensionTravelStuds,
			resolved.Sources.SuspensionTravel == "Manual",
			nextOrder()
		)
		local stiffnessStep = math.max(200, math.round(resolved.SpringStiffness * 0.15 / 100) * 100)
		buildStepperRow(
			pid,
			"Rigidez",
			"SpringStiffness",
			resolved.SpringStiffness,
			"%.0f",
			stiffnessStep,
			W.MinSpringStiffness,
			W.MaxSpringStiffness,
			resolved.Sources.SpringStiffness == "Manual",
			nextOrder()
		)
		buildStepperRow(
			pid,
			"Amortig.",
			"SpringDamping",
			resolved.SpringDamping,
			"%.0f",
			25,
			W.MinSpringDamping,
			W.MaxSpringDamping,
			resolved.Sources.SpringDamping == "Manual",
			nextOrder()
		)
		buildStepperRow(
			pid,
			"Altura (Ride)",
			"RideHeight",
			resolved.RideHeight,
			"%+.2f st",
			0.1,
			W.MinRideHeightOffset,
			W.MaxRideHeightOffset,
			resolved.Sources.RideHeight == "Manual",
			nextOrder()
		)

		buildSectionHeader("TREN MOTRIZ (FASE 3.3)", nextOrder())
		buildBoolAutoRow(
			pid,
			"Tracción",
			"IsDriven",
			resolved.IsDriven,
			resolved.Sources.IsDriven == "Manual",
			"Conduce (Sí)",
			"Libre (No)",
			nextOrder()
		)
		buildSignRow(
			pid,
			"Giro motriz",
			"DriveDirection",
			resolved.DriveDirection,
			resolved.Sources.DriveDirection == "Manual",
			"Adelante (+1)",
			"Reversa (-1)",
			nextOrder()
		)
	end

	local function refresh()
		local piece, resolved, analysis = WheelConfigController.GetSelectedWheelContext()
		if not piece or not resolved or not analysis then
			frame.Visible = false
			reopenPill.Visible = false
			lastSelectedPieceId = nil
			return
		end

		if piece.InstanceId ~= lastSelectedPieceId then
			lastSelectedPieceId = piece.InstanceId
			dismissedForPieceId = nil
			if hooks and hooks.OnWheelPanelOpened then
				hooks.OnWheelPanelOpened()
			end
		end

		local blocked = if hooks and hooks.IsBlockedByOtherPanel then hooks.IsBlockedByOtherPanel() else false
		local shouldShowPanel = (dismissedForPieceId ~= piece.InstanceId) and not blocked
		frame.Visible = shouldShowPanel
		reopenPill.Visible = not shouldShowPanel

		if not shouldShowPanel then
			return
		end

		local summary = WheelInspectorPanel.DescribeWheelSummary(resolved, analysis)
		modeBadge.Text = summary.BadgeMode
		if summary.BadgeMode == "AUTO" then
			modeBadge.BackgroundColor3 = Color3.fromRGB(40, 128, 86)
		elseif summary.BadgeMode == "MIXTO" then
			modeBadge.BackgroundColor3 = Color3.fromRGB(168, 120, 42)
		else
			modeBadge.BackgroundColor3 = Color3.fromRGB(56, 108, 178)
		end

		roleLbl.Text = summary.RoleText
		subInfoLbl.Text = `{summary.SeatText} | {summary.MassText}`

		if #summary.Warnings > 0 then
			warnLbl.Visible = true
			warnLbl.Text = "⚠ " .. summary.Warnings[1]
			scroll.Position = UDim2.fromOffset(8, 114)
			scroll.Size = UDim2.new(1, -16, 1, -164)
		else
			warnLbl.Visible = false
			scroll.Position = UDim2.fromOffset(8, 88)
			scroll.Size = UDim2.new(1, -16, 1, -138)
		end

		if BuildState.LastError and #BuildState.LastError > 0 then
			feedbackLbl.Text = BuildState.LastError
			feedbackLbl.TextColor3 = Color3.fromRGB(245, 118, 118)
		elseif BuildState.StatusMessage and #BuildState.StatusMessage > 0 then
			feedbackLbl.Text = BuildState.StatusMessage
			feedbackLbl.TextColor3 = Color3.fromRGB(165, 224, 178)
		else
			feedbackLbl.Text = "Cambios persistentes en el blueprint activo"
			feedbackLbl.TextColor3 = Color3.fromRGB(165, 194, 220)
		end

		resetAllBtn.Active = resolved.HasManualOverrides and not WheelConfigController.IsBusy()
		resetAllBtn.BackgroundColor3 = if resolved.HasManualOverrides
			then Color3.fromRGB(58, 108, 168)
			else Color3.fromRGB(44, 52, 66)

		rebuildControls(piece, resolved)
	end

	closeBtn.Activated:Connect(function()
		if lastSelectedPieceId then
			dismissedForPieceId = lastSelectedPieceId
		end
		refresh()
	end)

	reopenPill.Activated:Connect(function()
		dismissedForPieceId = nil
		if hooks and hooks.OnWheelPanelOpened then
			hooks.OnWheelPanelOpened()
		end
		refresh()
	end)

	resetAllBtn.Activated:Connect(function()
		local pid = lastSelectedPieceId
		if not pid then
			return
		end
		task.spawn(function()
			WheelConfigController.ResetWheelToAuto(pid)
		end)
	end)

	return {
		Frame = frame,
		ReopenPill = reopenPill,
		Refresh = refresh,
		IsOpen = function()
			return frame.Visible
		end,
		SetDismissed = function(dismissed: boolean)
			dismissedForPieceId = if dismissed then lastSelectedPieceId else nil
			refresh()
		end,
		Destroy = function()
			frame:Destroy()
			reopenPill:Destroy()
		end,
	}
end

return WheelInspectorPanel
