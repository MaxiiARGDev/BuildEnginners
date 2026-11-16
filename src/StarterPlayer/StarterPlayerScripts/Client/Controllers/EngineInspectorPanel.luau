--!strict
--[=[
	EngineInspectorPanel
	Panel contextual del Modo Construcción para inspeccionar y configurar motores instalados (Fase 3.3).
	- Muestra Nombre, Tamaño, Rareza, Variante, Potencia, Torque Pico, Rango de RPM, Peso, Bonificación de conducción
	  y etiqueta explícita de estado de balance (Confirmado SDD vs Provisional TBD).
	- Permite seleccionar entre las unidades de motor registradas del jugador (InventoryInstanceId) o volver al motor
	  base del catálogo (Reset a Base), además de ajustar límite de potencia y modo de respuesta de acelerador.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BuildState = require(script.Parent.BuildState)

export type MountOptions = {
	OnEnginePanelOpened: (() -> ())?,
	IsBlockedByOtherPanel: (() -> boolean)?,
}

export type MountedEngineInspector = {
	Frame: Frame,
	Refresh: () -> (),
	Close: () -> (),
}

local EngineInspectorPanel = {}

local RARITY_COLORS: { [string]: Color3 } = {
	Common = Color3.fromRGB(176, 184, 196),
	Uncommon = Color3.fromRGB(74, 222, 128),
	Rare = Color3.fromRGB(56, 189, 248),
	Epic = Color3.fromRGB(192, 132, 252),
	Legendary = Color3.fromRGB(251, 191, 36),
	Mythic = Color3.fromRGB(244, 63, 94),
}

local function getBuildRequestRemote(): RemoteFunction?
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local remotes = if shared then shared:FindFirstChild("Remotes") else nil
	local rf = if remotes then remotes:FindFirstChild(BuildProtocol.RemoteFunctionName) else nil
	if rf and rf:IsA("RemoteFunction") then
		return rf
	end
	return nil
end

local function makeButton(
	name: string,
	text: string,
	bgColor: Color3,
	size: UDim2,
	parent: Instance
): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Size = size
	btn.BackgroundColor3 = bgColor
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = true
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 11
	btn.TextColor3 = Color3.fromRGB(245, 247, 252)
	btn.Text = text
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn
	return btn
end

function EngineInspectorPanel.Mount(screenGui: ScreenGui, options: MountOptions?): MountedEngineInspector
	local opts = options or {}
	local opCounter = 0
	local requestInFlight = false
	local cachedUnits: { ItemTypes.EngineUnitRecord } = {}
	local lastUnitsFetchClock = 0

	local panel = Instance.new("Frame")
	panel.Name = "EngineInspectorPanel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -16, 0, 58)
	panel.Size = UDim2.fromOffset(390, 440)
	panel.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(215, 135, 58)
	stroke.Thickness = 1.2
	stroke.Parent = panel

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Name = "TitleLabel"
	titleLbl.Size = UDim2.new(1, -110, 0, 24)
	titleLbl.Position = UDim2.fromOffset(12, 8)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 14
	titleLbl.TextColor3 = Color3.fromRGB(242, 246, 255)
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Text = "Inspector de Motor"
	titleLbl.Parent = panel

	local balanceBadge = Instance.new("TextLabel")
	balanceBadge.Name = "BalanceBadge"
	balanceBadge.Size = UDim2.fromOffset(118, 20)
	balanceBadge.Position = UDim2.new(1, -158, 0, 10)
	balanceBadge.BackgroundColor3 = Color3.fromRGB(40, 82, 62)
	balanceBadge.Font = Enum.Font.GothamBold
	balanceBadge.TextSize = 10
	balanceBadge.TextColor3 = Color3.fromRGB(190, 245, 210)
	balanceBadge.Text = "SDD Confirmado"
	balanceBadge.Parent = panel

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 5)
	badgeCorner.Parent = balanceBadge

	local closeBtn = makeButton("CloseBtn", "X", Color3.fromRGB(70, 76, 92), UDim2.fromOffset(26, 24), panel)
	closeBtn.Position = UDim2.new(1, -34, 0, 8)

	local subtitleLbl = Instance.new("TextLabel")
	subtitleLbl.Name = "SubtitleLabel"
	subtitleLbl.Size = UDim2.new(1, -24, 0, 18)
	subtitleLbl.Position = UDim2.fromOffset(12, 34)
	subtitleLbl.BackgroundTransparency = 1
	subtitleLbl.Font = Enum.Font.GothamBold
	subtitleLbl.TextSize = 12
	subtitleLbl.TextColor3 = Color3.fromRGB(180, 215, 255)
	subtitleLbl.TextXAlignment = Enum.TextXAlignment.Left
	subtitleLbl.Text = "--"
	subtitleLbl.Parent = panel

	local statsBox = Instance.new("TextLabel")
	statsBox.Name = "StatsBox"
	statsBox.Size = UDim2.new(1, -24, 0, 108)
	statsBox.Position = UDim2.fromOffset(12, 56)
	statsBox.BackgroundColor3 = Color3.fromRGB(28, 33, 44)
	statsBox.BorderSizePixel = 0
	statsBox.Font = Enum.Font.Code
	statsBox.TextSize = 11
	statsBox.TextColor3 = Color3.fromRGB(228, 234, 245)
	statsBox.TextXAlignment = Enum.TextXAlignment.Left
	statsBox.TextYAlignment = Enum.TextYAlignment.Top
	statsBox.TextWrapped = true
	statsBox.Text = ""
	statsBox.Parent = panel

	local statsCorner = Instance.new("UICorner")
	statsCorner.CornerRadius = UDim.new(0, 6)
	statsCorner.Parent = statsBox

	local statsPad = Instance.new("UIPadding")
	statsPad.PaddingLeft = UDim.new(0, 8)
	statsPad.PaddingRight = UDim.new(0, 8)
	statsPad.PaddingTop = UDim.new(0, 6)
	statsPad.PaddingBottom = UDim.new(0, 6)
	statsPad.Parent = statsBox

	-- Controles de respuesta y potencia
	local tuningRow = Instance.new("Frame")
	tuningRow.Name = "TuningRow"
	tuningRow.Size = UDim2.new(1, -24, 0, 62)
	tuningRow.Position = UDim2.fromOffset(12, 170)
	tuningRow.BackgroundTransparency = 1
	tuningRow.Parent = panel

	local powerLbl = Instance.new("TextLabel")
	powerLbl.Size = UDim2.fromOffset(120, 24)
	powerLbl.Position = UDim2.fromOffset(0, 2)
	powerLbl.BackgroundTransparency = 1
	powerLbl.Font = Enum.Font.GothamMedium
	powerLbl.TextSize = 11
	powerLbl.TextColor3 = Color3.fromRGB(210, 218, 232)
	powerLbl.TextXAlignment = Enum.TextXAlignment.Left
	powerLbl.Text = "Límite Potencia:"
	powerLbl.Parent = tuningRow

	local respLbl = Instance.new("TextLabel")
	respLbl.Size = UDim2.fromOffset(120, 24)
	respLbl.Position = UDim2.fromOffset(0, 32)
	respLbl.BackgroundTransparency = 1
	respLbl.Font = Enum.Font.GothamMedium
	respLbl.TextSize = 11
	respLbl.TextColor3 = Color3.fromRGB(210, 218, 232)
	respLbl.TextXAlignment = Enum.TextXAlignment.Left
	respLbl.Text = "Respuesta Acel.:"
	respLbl.Parent = tuningRow

	-- Selector de unidades de motor (Inventario / Muestra controlada de taller)
	local unitsHeaderLbl = Instance.new("TextLabel")
	unitsHeaderLbl.Name = "UnitsHeader"
	unitsHeaderLbl.Size = UDim2.new(1, -24, 0, 20)
	unitsHeaderLbl.Position = UDim2.fromOffset(12, 236)
	unitsHeaderLbl.BackgroundTransparency = 1
	unitsHeaderLbl.Font = Enum.Font.GothamBold
	unitsHeaderLbl.TextSize = 11
	unitsHeaderLbl.TextColor3 = Color3.fromRGB(240, 205, 130)
	unitsHeaderLbl.TextXAlignment = Enum.TextXAlignment.Left
	unitsHeaderLbl.Text = "Unidades en Inventario:"
	unitsHeaderLbl.Parent = panel

	local unitsScroll = Instance.new("ScrollingFrame")
	unitsScroll.Name = "UnitsScroll"
	unitsScroll.Size = UDim2.new(1, -24, 0, 140)
	unitsScroll.Position = UDim2.fromOffset(12, 258)
	unitsScroll.BackgroundColor3 = Color3.fromRGB(16, 19, 26)
	unitsScroll.BorderSizePixel = 0
	unitsScroll.ScrollBarThickness = 5
	unitsScroll.CanvasSize = UDim2.fromOffset(0, 0)
	unitsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	unitsScroll.Parent = panel

	local unitsListLayout = Instance.new("UIListLayout")
	unitsListLayout.Padding = UDim.new(0, 4)
	unitsListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	unitsListLayout.Parent = unitsScroll

	local resetBaseBtn = makeButton(
		"ResetBaseBtn",
		"Restaurar Motor Base (Small · Común · Equilibrado)",
		Color3.fromRGB(98, 66, 48),
		UDim2.new(1, -24, 0, 28),
		panel
	)
	resetBaseBtn.Position = UDim2.fromOffset(12, 404)

	local function findSelectedEnginePiece(): VehicleTypes.BlueprintPiece?
		local selId = BuildState.SelectedPlacedPieceId
		if not selId or not BuildState.IsActive or not BuildState.IsEditingMode() then
			return nil
		end
		for _, piece in ipairs(BuildState.BlueprintPieces) do
			if piece.InstanceId == selId then
				local def = ItemRegistry.TryGet(piece.ItemId)
				if def and def.Category == "Engines" then
					return piece
				end
				return nil
			end
		end
		return nil
	end

	local refreshPanel: () -> ()

	local function sendEngineConfigUpdate(
		pieceId: string,
		newEngineCfg: { [string]: any }?,
		inventoryInstanceId: string?,
		resetToAuto: boolean?
	)
		if requestInFlight then
			return
		end
		local rf = getBuildRequestRemote()
		if not rf then
			return
		end
		requestInFlight = true
		opCounter += 1

		task.spawn(function()
			local ok, res = pcall(function()
				return rf:InvokeServer({
					Action = BuildProtocol.Actions.UpdatePieceConfig,
					ClientOpId = `engcfg_{opCounter}_{math.floor(os.clock() * 1000)}`,
					PieceInstanceId = pieceId,
					Config = if newEngineCfg then { Engine = newEngineCfg } else nil,
					InventoryInstanceId = inventoryInstanceId,
					ResetToAuto = resetToAuto,
					ExpectedBlueprintId = BuildState.BlueprintId,
				})
			end)
			requestInFlight = false
			if ok and type(res) == "table" then
				local resp = res :: BuildProtocol.BuildOperationResponse
				if (resp :: any).Inventory ~= nil then
					BuildState.SetInventoryState((resp :: any).Inventory)
				end
				if resp.Success and resp.Blueprint then
					BuildState.ApplyAuthoritativeBlueprint(resp.Blueprint)
				elseif not resp.Success then
					BuildState.SetError(resp.ErrorMessage or resp.ErrorCode or "No se pudo actualizar el motor")
				end
			end
			refreshPanel()
		end)
	end

	local function fetchUnitsFromServerIfNeeded()
		local now = os.clock()
		if now - lastUnitsFetchClock < 2.0 and #cachedUnits > 0 then
			return
		end
		lastUnitsFetchClock = now
		local rf = getBuildRequestRemote()
		if not rf then
			return
		end
		task.spawn(function()
			local ok, res = pcall(function()
				return rf:InvokeServer({
					Action = BuildProtocol.Actions.GetEngineUnits,
					ClientOpId = `getunits_{math.floor(os.clock() * 1000)}`,
				})
			end)
			if ok and type(res) == "table" and res.Success and type(res.EngineUnits) == "table" then
				cachedUnits = res.EngineUnits
				if panel.Visible then
					refreshPanel()
				end
			end
		end)
	end

	local pwr50Btn = makeButton("Pwr50", "50%", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(72, 24), tuningRow)
	pwr50Btn.Position = UDim2.fromOffset(124, 2)
	local pwr75Btn = makeButton("Pwr75", "75%", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(72, 24), tuningRow)
	pwr75Btn.Position = UDim2.fromOffset(202, 2)
	local pwr100Btn = makeButton("Pwr100", "100%", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(78, 24), tuningRow)
	pwr100Btn.Position = UDim2.fromOffset(280, 2)

	local respSmoothBtn = makeButton("RespSmooth", "Suave", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(72, 24), tuningRow)
	respSmoothBtn.Position = UDim2.fromOffset(124, 32)
	local respBalBtn = makeButton("RespBal", "Normal", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(72, 24), tuningRow)
	respBalBtn.Position = UDim2.fromOffset(202, 32)
	local respSportBtn = makeButton("RespSport", "Sport", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(78, 24), tuningRow)
	respSportBtn.Position = UDim2.fromOffset(280, 32)

	local function setTuningField(field: string, value: any)
		local piece = findSelectedEnginePiece()
		if not piece then
			return
		end
		local curEng = if type(piece.Config) == "table" and type(piece.Config.Engine) == "table"
			then piece.Config.Engine
			else {}
		local payload: { [string]: any } = {
			PowerLimitRatio = curEng.PowerLimitRatio or 1.0,
			ThrottleResponseMode = curEng.ThrottleResponseMode or "Balanced",
			Enabled = if type(curEng.Enabled) == "boolean" then curEng.Enabled else true,
		}
		payload[field] = value
		sendEngineConfigUpdate(piece.InstanceId, payload, nil, false)
	end

	pwr50Btn.Activated:Connect(function()
		setTuningField("PowerLimitRatio", 0.50)
	end)
	pwr75Btn.Activated:Connect(function()
		setTuningField("PowerLimitRatio", 0.75)
	end)
	pwr100Btn.Activated:Connect(function()
		setTuningField("PowerLimitRatio", 1.00)
	end)

	respSmoothBtn.Activated:Connect(function()
		setTuningField("ThrottleResponseMode", "Smooth")
	end)
	respBalBtn.Activated:Connect(function()
		setTuningField("ThrottleResponseMode", "Balanced")
	end)
	respSportBtn.Activated:Connect(function()
		setTuningField("ThrottleResponseMode", "Sport")
	end)

	resetBaseBtn.Activated:Connect(function()
		local piece = findSelectedEnginePiece()
		if not piece then
			return
		end
		sendEngineConfigUpdate(piece.InstanceId, nil, "", true)
	end)

	closeBtn.Activated:Connect(function()
		panel.Visible = false
	end)

	refreshPanel = function()
		if opts.IsBlockedByOtherPanel and opts.IsBlockedByOtherPanel() then
			panel.Visible = false
			return
		end

		local piece = findSelectedEnginePiece()
		if not piece then
			panel.Visible = false
			return
		end

		if not panel.Visible and opts.OnEnginePanelOpened then
			opts.OnEnginePanelOpened()
		end
		panel.Visible = true
		fetchUnitsFromServerIfNeeded()

		local engCfg = if type(piece.Config) == "table" and type(piece.Config.Engine) == "table"
			then piece.Config.Engine
			else nil
		local stats = EngineCatalog.ResolveEffectiveStats({
			ItemId = piece.ItemId,
			EngineFamilyId = if engCfg then engCfg.EngineFamilyId else nil,
			EngineSizeId = if engCfg then engCfg.EngineSizeId else nil,
			VariantId = if engCfg then engCfg.VariantId else nil,
			RarityId = if engCfg then engCfg.RarityId else nil,
		})

		subtitleLbl.Text = stats.FullLabel
		subtitleLbl.TextColor3 = RARITY_COLORS[stats.RarityId] or Color3.fromRGB(220, 230, 245)

		if stats.IsProvisionalBalance then
			balanceBadge.Text = "Provisional (TBD)"
			balanceBadge.BackgroundColor3 = Color3.fromRGB(115, 78, 28)
			balanceBadge.TextColor3 = Color3.fromRGB(255, 224, 150)
		else
			balanceBadge.Text = "SDD Confirmado"
			balanceBadge.BackgroundColor3 = Color3.fromRGB(36, 86, 58)
			balanceBadge.TextColor3 = Color3.fromRGB(185, 248, 208)
		end

		local pwrLimit = if engCfg and type(engCfg.PowerLimitRatio) == "number" then engCfg.PowerLimitRatio else 1.0
		local respMode = if engCfg and type(engCfg.ThrottleResponseMode) == "string" then engCfg.ThrottleResponseMode else "Balanced"
		local unitLabel = if piece.InventoryInstanceId and #piece.InventoryInstanceId > 0
			then piece.InventoryInstanceId
			else "Catálogo Base (Sin unidad única)"

		local lines = {
			`Unidad: {unitLabel}`,
			`Tamaño: {stats.EngineSizeId} | Rareza: {stats.RarityId} | Variante: {stats.VariantId}`,
			string.format(
				"Torque Pico: %.0f | Potencia: %.0f | Vel. Ref: %.1f st/s",
				stats.PeakTorque * pwrLimit,
				stats.PowerRating * pwrLimit,
				stats.SpeedRegular
			),
			string.format(
				"RPM: %d (Idle) -> %d (Ópt) -> %d (Máx) [Corte: %d]",
				stats.IdleRPM,
				stats.OptimumRPM,
				stats.MaxRPM,
				stats.LimiterRPM
			),
			string.format(
				"Peso: %.1f | Durabilidad: %d | Bono Cond.: +%.4fx",
				stats.Weight,
				stats.MaxDurability,
				stats.DrivingBonus
			),
			string.format(
				"Combustible Integrado: %.2f | Consumo Máx: %.3f/min (%.4f/s)",
				stats.IntegratedFuel,
				stats.MaxFuelConsumption,
				stats.MaxFuelConsumption / math.max(1, GameConfig.Powertrain.FuelConsumptionTimeBaseSeconds)
			),
		}
		statsBox.Text = table.concat(lines, "\n")

		pwr50Btn.BackgroundColor3 = if math.abs(pwrLimit - 0.50) < 0.05 then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)
		pwr75Btn.BackgroundColor3 = if math.abs(pwrLimit - 0.75) < 0.05 then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)
		pwr100Btn.BackgroundColor3 = if math.abs(pwrLimit - 1.00) < 0.05 then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)

		respSmoothBtn.BackgroundColor3 = if respMode == "Smooth" then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)
		respBalBtn.BackgroundColor3 = if respMode == "Balanced" then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)
		respSportBtn.BackgroundColor3 = if respMode == "Sport" then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)

		-- Reconstruir lista de unidades disponibles
		for _, child in ipairs(unitsScroll:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local usedByPieceId: { [string]: string } = {}
		for _, bpPiece in ipairs(BuildState.BlueprintPieces) do
			if bpPiece.InventoryInstanceId and #bpPiece.InventoryInstanceId > 0 then
				usedByPieceId[bpPiece.InventoryInstanceId] = bpPiece.InstanceId
			end
		end

		local displayUnits = if BuildState.Inventory and type(BuildState.Inventory.EngineUnits) == "table"
			then BuildState.Inventory.EngineUnits
			else cachedUnits

		if #displayUnits == 0 then
			local emptyLbl = Instance.new("TextLabel")
			emptyLbl.Name = "EmptyUnitsLabel"
			emptyLbl.Size = UDim2.new(1, -8, 0, 28)
			emptyLbl.BackgroundTransparency = 1
			emptyLbl.Font = Enum.Font.GothamMedium
			emptyLbl.TextSize = 11
			emptyLbl.TextColor3 = Color3.fromRGB(165, 175, 195)
			emptyLbl.Text = "No tienes unidades de motor disponibles en tu inventario."
			emptyLbl.TextWrapped = true
			emptyLbl.Parent = unitsScroll
		end

		for idx, unit in ipairs(displayUnits) do
			local uStats = unit.EffectiveStats
			local assignedPieceId = usedByPieceId[unit.ItemInstanceId]
			local isCurrent = assignedPieceId == piece.InstanceId
			local isUsedElsewhere = assignedPieceId ~= nil and not isCurrent

			local statusTag = if isCurrent
				then "[INSTALADA AQUÍ]"
				elseif isUsedElsewhere then `[EN USO: {assignedPieceId}]`
				else "[DISPONIBLE]"

			local rowBtn = makeButton(
				`Unit_{idx}`,
				`{uStats.FullLabel} | Tq:{math.round(uStats.PeakTorque)} | {statusTag}`,
				if isCurrent
					then Color3.fromRGB(42, 128, 86)
					elseif isUsedElsewhere then Color3.fromRGB(62, 52, 58)
					else Color3.fromRGB(38, 48, 66),
				UDim2.new(1, -8, 0, 26),
				unitsScroll
			)
			rowBtn.LayoutOrder = idx
			rowBtn.TextXAlignment = Enum.TextXAlignment.Left
			rowBtn.TextTruncate = Enum.TextTruncate.AtEnd

			local pad = Instance.new("UIPadding")
			pad.PaddingLeft = UDim.new(0, 8)
			pad.Parent = rowBtn

			rowBtn.Activated:Connect(function()
				if isUsedElsewhere then
					BuildState.SetError("Esa unidad de motor ya está instalada en otra pieza del vehículo.")
					return
				end
				sendEngineConfigUpdate(piece.InstanceId, nil, unit.ItemInstanceId, false)
			end)
		end
	end

	return {
		Frame = panel,
		Refresh = refreshPanel,
		Close = function()
			panel.Visible = false
		end,
	}
end

return EngineInspectorPanel
