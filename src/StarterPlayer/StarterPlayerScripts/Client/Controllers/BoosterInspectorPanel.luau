--!strict
--[=[
	BoosterInspectorPanel
	Panel contextual del Modo Construcción para inspeccionar y configurar propulsores instalados (Fase 3.4).
	- Muestra Familia, Tamaño, Rareza, Variante, Empuje, Multiplicador de Velocidad Máxima, Nitro Integrado,
	  Consumo, Durabilidad, Peso, Rampa de ignición/apagado, dirección 3D de empuje en vehículo y mundo,
	  y etiqueta explícita de estado de balance (Confirmado SDD vs Provisional TBD).
	- Muestra una guía 3D no física de dirección de empuje (BoosterThrustGuide) en el taller.
	- Permite seleccionar unidades de propulsor del jugador (InventoryInstanceId) o restaurar la base del catálogo,
	  ajustar Límite de Empuje (25% / 50% / 75% / 100%), Curva de Ignición (Instant / Smooth / Sustained) y Activo ON/OFF.
]=]

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BuildState = require(script.Parent.BuildState)

export type MountOptions = {
	OnBoosterPanelOpened: (() -> ())?,
	IsBlockedByOtherPanel: (() -> boolean)?,
}

export type MountedBoosterInspector = {
	Frame: Frame,
	Refresh: () -> (),
	RefreshGuidePose: () -> (),
	Close: () -> (),
	GetActiveGuideModel: () -> Model?,
	Destroy: () -> (),
}

local BoosterInspectorPanel = {}

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

function BoosterInspectorPanel.DescribeThrustDirection(dir: Vector3): string
	if dir.Magnitude < 1e-4 then
		return "Indefinida"
	end
	local u = dir.Unit
	if u.Z <= -0.92 then
		return "Adelante (-Z)"
	elseif u.Z >= 0.92 then
		return "Atrás (+Z)"
	elseif u.Y >= 0.92 then
		return "Arriba (+Y)"
	elseif u.Y <= -0.92 then
		return "Abajo (-Y)"
	elseif u.X >= 0.92 then
		return "Derecha (+X)"
	elseif u.X <= -0.92 then
		return "Izquierda (-X)"
	end
	return string.format("Diagonal (%.2f, %.2f, %.2f)", u.X, u.Y, u.Z)
end

local function applyNonPhysicalGuideProps(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CastShadow = false
	local ghostGroup = GameConfig.Runtime.CollisionGroups.EditorGhost
	if PhysicsService:IsCollisionGroupRegistered(ghostGroup) then
		part.CollisionGroup = ghostGroup
	end
end

local function findPlacedPieceModel(pieceInstanceId: string): Model?
	local plot = BuildState.AssignedPlot
	if not plot then
		return nil
	end
	local dyn = plot:FindFirstChild(GameConfig.PlotContainers.Dynamic)
	local editable = if dyn then dyn:FindFirstChild(GameConfig.Building.EditableVehicleName) else nil
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

local function resolvePieceWorldCFrame(piece: VehicleTypes.BlueprintPiece): CFrame
	local pieceModel = findPlacedPieceModel(piece.InstanceId)
	if pieceModel then
		return pieceModel:GetPivot()
	end
	local effZone = BuildState.GetEffectiveBuildZoneCFrame()
	if effZone then
		return effZone:ToWorldSpace(piece.LocalCFrame)
	end
	return piece.LocalCFrame
end

function BoosterInspectorPanel.Mount(screenGui: ScreenGui, options: MountOptions?): MountedBoosterInspector
	local opts = options or {}
	local opCounter = 0
	local requestInFlight = false
	local cachedUnits: { ItemTypes.BoosterUnitRecord } = {}
	local lastUnitsFetchClock = 0
	local activeGuideModel: Model? = nil

	local panel = Instance.new("Frame")
	panel.Name = "BoosterInspectorPanel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -16, 0, 58)
	panel.Size = UDim2.fromOffset(396, 488)
	panel.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(56, 189, 248)
	stroke.Thickness = 1.2
	stroke.Parent = panel

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Name = "TitleLabel"
	titleLbl.Size = UDim2.new(1, -160, 0, 24)
	titleLbl.Position = UDim2.fromOffset(12, 8)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 14
	titleLbl.TextColor3 = Color3.fromRGB(242, 246, 255)
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Text = "Inspector de Propulsor"
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
	subtitleLbl.TextColor3 = Color3.fromRGB(155, 222, 255)
	subtitleLbl.TextXAlignment = Enum.TextXAlignment.Left
	subtitleLbl.Text = "--"
	subtitleLbl.Parent = panel

	local statsBox = Instance.new("TextLabel")
	statsBox.Name = "StatsBox"
	statsBox.Size = UDim2.new(1, -24, 0, 126)
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

	-- Controles de ajuste de empuje, curva y habilitado
	local tuningRow = Instance.new("Frame")
	tuningRow.Name = "TuningRow"
	tuningRow.Size = UDim2.new(1, -24, 0, 92)
	tuningRow.Position = UDim2.fromOffset(12, 188)
	tuningRow.BackgroundTransparency = 1
	tuningRow.Parent = panel

	local thrustLbl = Instance.new("TextLabel")
	thrustLbl.Size = UDim2.fromOffset(118, 24)
	thrustLbl.Position = UDim2.fromOffset(0, 2)
	thrustLbl.BackgroundTransparency = 1
	thrustLbl.Font = Enum.Font.GothamMedium
	thrustLbl.TextSize = 11
	thrustLbl.TextColor3 = Color3.fromRGB(210, 218, 232)
	thrustLbl.TextXAlignment = Enum.TextXAlignment.Left
	thrustLbl.Text = "Límite Empuje:"
	thrustLbl.Parent = tuningRow

	local curveLbl = Instance.new("TextLabel")
	curveLbl.Size = UDim2.fromOffset(118, 24)
	curveLbl.Position = UDim2.fromOffset(0, 32)
	curveLbl.BackgroundTransparency = 1
	curveLbl.Font = Enum.Font.GothamMedium
	curveLbl.TextSize = 11
	curveLbl.TextColor3 = Color3.fromRGB(210, 218, 232)
	curveLbl.TextXAlignment = Enum.TextXAlignment.Left
	curveLbl.Text = "Curva Ignición:"
	curveLbl.Parent = tuningRow

	local activeLbl = Instance.new("TextLabel")
	activeLbl.Size = UDim2.fromOffset(118, 24)
	activeLbl.Position = UDim2.fromOffset(0, 62)
	activeLbl.BackgroundTransparency = 1
	activeLbl.Font = Enum.Font.GothamMedium
	activeLbl.TextSize = 11
	activeLbl.TextColor3 = Color3.fromRGB(210, 218, 232)
	activeLbl.TextXAlignment = Enum.TextXAlignment.Left
	activeLbl.Text = "Estado Propulsor:"
	activeLbl.Parent = tuningRow

	local lim25Btn = makeButton("Thrust25", "25%", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(58, 24), tuningRow)
	lim25Btn.Position = UDim2.fromOffset(122, 2)
	local lim50Btn = makeButton("Thrust50", "50%", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(58, 24), tuningRow)
	lim50Btn.Position = UDim2.fromOffset(185, 2)
	local lim75Btn = makeButton("Thrust75", "75%", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(58, 24), tuningRow)
	lim75Btn.Position = UDim2.fromOffset(248, 2)
	local lim100Btn = makeButton("Thrust100", "100%", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(61, 24), tuningRow)
	lim100Btn.Position = UDim2.fromOffset(311, 2)

	local curveInstantBtn = makeButton("CurveInstant", "Instant", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(78, 24), tuningRow)
	curveInstantBtn.Position = UDim2.fromOffset(122, 32)
	local curveSmoothBtn = makeButton("CurveSmooth", "Smooth", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(78, 24), tuningRow)
	curveSmoothBtn.Position = UDim2.fromOffset(205, 32)
	local curveSustainedBtn = makeButton("CurveSustained", "Sustained", Color3.fromRGB(48, 56, 72), UDim2.fromOffset(84, 24), tuningRow)
	curveSustainedBtn.Position = UDim2.fromOffset(288, 32)

	local toggleEnabledBtn = makeButton(
		"ToggleEnabledBtn",
		"ACTIVO (Responde a LeftShift)",
		Color3.fromRGB(36, 128, 86),
		UDim2.fromOffset(250, 24),
		tuningRow
	)
	toggleEnabledBtn.Position = UDim2.fromOffset(122, 62)

	-- Selector de unidades de propulsor
	local unitsHeaderLbl = Instance.new("TextLabel")
	unitsHeaderLbl.Name = "UnitsHeader"
	unitsHeaderLbl.Size = UDim2.new(1, -24, 0, 20)
	unitsHeaderLbl.Position = UDim2.fromOffset(12, 286)
	unitsHeaderLbl.BackgroundTransparency = 1
	unitsHeaderLbl.Font = Enum.Font.GothamBold
	unitsHeaderLbl.TextSize = 11
	unitsHeaderLbl.TextColor3 = Color3.fromRGB(145, 220, 255)
	unitsHeaderLbl.TextXAlignment = Enum.TextXAlignment.Left
	unitsHeaderLbl.Text = "Unidades en Inventario:"
	unitsHeaderLbl.Parent = panel

	local unitsScroll = Instance.new("ScrollingFrame")
	unitsScroll.Name = "UnitsScroll"
	unitsScroll.Size = UDim2.new(1, -24, 0, 134)
	unitsScroll.Position = UDim2.fromOffset(12, 308)
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
		"Restaurar Propulsor Base (Small · Estándar · Equilibrado · Común)",
		Color3.fromRGB(48, 82, 108),
		UDim2.new(1, -24, 0, 28),
		panel
	)
	resetBaseBtn.Position = UDim2.fromOffset(12, 448)

	local function destroyGuide()
		if activeGuideModel then
			activeGuideModel:Destroy()
			activeGuideModel = nil
		end
	end

	local function ensureGuideModel(): Model
		if activeGuideModel and activeGuideModel.Parent ~= nil then
			return activeGuideModel
		end
		destroyGuide()

		local guide = Instance.new("Model")
		guide.Name = "BoosterThrustGuide"

		local shaft = Instance.new("Part")
		shaft.Name = "ThrustShaft"
		shaft.Material = Enum.Material.Neon
		shaft.Color = Color3.fromRGB(56, 200, 255)
		shaft.Transparency = 0.15
		applyNonPhysicalGuideProps(shaft)
		shaft.Parent = guide

		local tipLeft = Instance.new("Part")
		tipLeft.Name = "ThrustTipLeft"
		tipLeft.Material = Enum.Material.Neon
		tipLeft.Color = Color3.fromRGB(120, 235, 255)
		tipLeft.Transparency = 0.1
		applyNonPhysicalGuideProps(tipLeft)
		tipLeft.Parent = guide

		local tipRight = Instance.new("Part")
		tipRight.Name = "ThrustTipRight"
		tipRight.Material = Enum.Material.Neon
		tipRight.Color = Color3.fromRGB(120, 235, 255)
		tipRight.Transparency = 0.1
		applyNonPhysicalGuideProps(tipRight)
		tipRight.Parent = guide

		local nozzleMarker = Instance.new("Part")
		nozzleMarker.Name = "NozzleMarker"
		nozzleMarker.Shape = Enum.PartType.Ball
		nozzleMarker.Size = Vector3.new(0.45, 0.45, 0.45)
		nozzleMarker.Material = Enum.Material.Neon
		nozzleMarker.Color = Color3.fromRGB(255, 145, 48)
		nozzleMarker.Transparency = 0.18
		applyNonPhysicalGuideProps(nozzleMarker)
		nozzleMarker.Parent = guide

		guide.PrimaryPart = shaft
		guide.Parent = Workspace.CurrentCamera or Workspace
		activeGuideModel = guide
		return guide
	end

	local function findSelectedBoosterPiece(): VehicleTypes.BlueprintPiece?
		local selId = BuildState.SelectedPlacedPieceId
		if not selId or not BuildState.IsActive or not BuildState.IsEditingMode() then
			return nil
		end
		for _, piece in ipairs(BuildState.BlueprintPieces) do
			if piece.InstanceId == selId then
				local def = ItemRegistry.TryGet(piece.ItemId)
				if def and def.Category == "Boosters" then
					return piece
				end
				return nil
			end
		end
		return nil
	end

	local function updateGuideForPiece(piece: VehicleTypes.BlueprintPiece?, enabled: boolean)
		if not piece or not BuildState.IsActive or not BuildState.IsEditingMode() then
			destroyGuide()
			return
		end

		local guide = ensureGuideModel()
		local pieceWorldCF = resolvePieceWorldCFrame(piece)
		local localAxis = GameConfig.Boosters.DefaultLocalThrustAxis
		if localAxis.Magnitude < 1e-4 then
			localAxis = Vector3.new(0, 0, -1)
		else
			localAxis = localAxis.Unit
		end

		local nozzleOffset = GameConfig.Boosters.DefaultNozzleLocalOffset
		local arrowLen = math.max(1.5, GameConfig.Boosters.GuideArrowLengthStuds)
		local startLocal = localAxis * 1.55
		local tipLocal = localAxis * (1.55 + arrowLen)

		local startWorld = pieceWorldCF:PointToWorldSpace(startLocal)
		local tipWorld = pieceWorldCF:PointToWorldSpace(tipLocal)
		local worldThrustDir = pieceWorldCF:VectorToWorldSpace(localAxis).Unit
		local vehicleThrustDir = piece.LocalCFrame:VectorToWorldSpace(localAxis).Unit
		local dirLabel = BoosterInspectorPanel.DescribeThrustDirection(vehicleThrustDir)

		local shaftColor = if enabled then Color3.fromRGB(56, 200, 255) else Color3.fromRGB(130, 140, 156)
		local tipColor = if enabled then Color3.fromRGB(135, 240, 255) else Color3.fromRGB(150, 160, 175)

		local shaft = guide:FindFirstChild("ThrustShaft")
		if shaft and shaft:IsA("BasePart") then
			shaft.Size = Vector3.new(0.22, 0.22, arrowLen)
			shaft.CFrame = CFrame.lookAt((startWorld + tipWorld) * 0.5, tipWorld)
			shaft.Color = shaftColor
		end

		local rightLocal = pieceWorldCF:VectorToWorldSpace(Vector3.new(1, 0, 0))
		if math.abs(rightLocal:Dot(worldThrustDir)) > 0.95 then
			rightLocal = pieceWorldCF:VectorToWorldSpace(Vector3.new(0, 1, 0))
		end
		local wingSpanDir = worldThrustDir:Cross(rightLocal)
		if wingSpanDir.Magnitude < 1e-4 then
			wingSpanDir = Vector3.new(1, 0, 0)
		else
			wingSpanDir = wingSpanDir.Unit:Cross(worldThrustDir).Unit
		end

		local wingBackCenter = tipWorld - worldThrustDir * 0.72
		local wingLeftBack = wingBackCenter - wingSpanDir * 0.48
		local wingRightBack = wingBackCenter + wingSpanDir * 0.48

		local tipLeft = guide:FindFirstChild("ThrustTipLeft")
		if tipLeft and tipLeft:IsA("BasePart") then
			tipLeft.Size = Vector3.new(0.18, 0.18, (tipWorld - wingLeftBack).Magnitude)
			tipLeft.CFrame = CFrame.lookAt((wingLeftBack + tipWorld) * 0.5, tipWorld)
			tipLeft.Color = tipColor
		end

		local tipRight = guide:FindFirstChild("ThrustTipRight")
		if tipRight and tipRight:IsA("BasePart") then
			tipRight.Size = Vector3.new(0.18, 0.18, (tipWorld - wingRightBack).Magnitude)
			tipRight.CFrame = CFrame.lookAt((wingRightBack + tipWorld) * 0.5, tipWorld)
			tipRight.Color = tipColor
		end

		local nozzleMarker = guide:FindFirstChild("NozzleMarker")
		if nozzleMarker and nozzleMarker:IsA("BasePart") then
			nozzleMarker.CFrame = pieceWorldCF:ToWorldSpace(CFrame.new(nozzleOffset))
			nozzleMarker.Color = if enabled then Color3.fromRGB(255, 145, 48) else Color3.fromRGB(110, 118, 130)
		end

		guide:SetAttribute("PieceInstanceId", piece.InstanceId)
		guide:SetAttribute("WorldThrustDirection", worldThrustDir)
		guide:SetAttribute("VehicleThrustDirection", vehicleThrustDir)
		guide:SetAttribute("DirectionLabel", dirLabel)
	end

	local refreshPanel: () -> ()

	local function sendBoosterConfigUpdate(
		pieceId: string,
		newBoosterCfg: { [string]: any }?,
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
					ClientOpId = `bstcfg_{opCounter}_{math.floor(os.clock() * 1000)}`,
					PieceInstanceId = pieceId,
					Config = if newBoosterCfg then { Booster = newBoosterCfg } else nil,
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
					BuildState.SetError(resp.ErrorMessage or resp.ErrorCode or "No se pudo actualizar el propulsor")
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
					Action = BuildProtocol.Actions.GetBoosterUnits,
					ClientOpId = `getbunits_{math.floor(os.clock() * 1000)}`,
				})
			end)
			if ok and type(res) == "table" and res.Success and type(res.BoosterUnits) == "table" then
				cachedUnits = res.BoosterUnits
				if panel.Visible then
					refreshPanel()
				end
			end
		end)
	end

	local function setTuningField(field: string, value: any)
		local piece = findSelectedBoosterPiece()
		if not piece then
			return
		end
		local curCfg = if type(piece.Config) == "table" and type(piece.Config.Booster) == "table"
			then piece.Config.Booster
			else {}
		local payload: { [string]: any } = {
			ThrustLimitRatio = curCfg.ThrustLimitRatio or GameConfig.Boosters.DefaultThrustLimitRatio,
			ThrottleCurveMode = curCfg.ThrottleCurveMode or GameConfig.Boosters.DefaultThrottleCurveMode,
			Enabled = if type(curCfg.Enabled) == "boolean" then curCfg.Enabled else true,
		}
		payload[field] = value
		sendBoosterConfigUpdate(piece.InstanceId, payload, nil, false)
	end

	lim25Btn.Activated:Connect(function()
		setTuningField("ThrustLimitRatio", 0.25)
	end)
	lim50Btn.Activated:Connect(function()
		setTuningField("ThrustLimitRatio", 0.50)
	end)
	lim75Btn.Activated:Connect(function()
		setTuningField("ThrustLimitRatio", 0.75)
	end)
	lim100Btn.Activated:Connect(function()
		setTuningField("ThrustLimitRatio", 1.00)
	end)

	curveInstantBtn.Activated:Connect(function()
		setTuningField("ThrottleCurveMode", "Instant")
	end)
	curveSmoothBtn.Activated:Connect(function()
		setTuningField("ThrottleCurveMode", "Smooth")
	end)
	curveSustainedBtn.Activated:Connect(function()
		setTuningField("ThrottleCurveMode", "Sustained")
	end)

	toggleEnabledBtn.Activated:Connect(function()
		local piece = findSelectedBoosterPiece()
		if not piece then
			return
		end
		local curCfg = if type(piece.Config) == "table" and type(piece.Config.Booster) == "table"
			then piece.Config.Booster
			else nil
		local curEnabled = if curCfg and type(curCfg.Enabled) == "boolean" then curCfg.Enabled else true
		setTuningField("Enabled", not curEnabled)
	end)

	resetBaseBtn.Activated:Connect(function()
		local piece = findSelectedBoosterPiece()
		if not piece then
			return
		end
		sendBoosterConfigUpdate(piece.InstanceId, nil, "", true)
	end)

	closeBtn.Activated:Connect(function()
		panel.Visible = false
		destroyGuide()
	end)

	local function refreshGuidePose()
		if not panel.Visible then
			destroyGuide()
			return
		end
		local piece = findSelectedBoosterPiece()
		if not piece then
			destroyGuide()
			return
		end
		local bstCfg = if type(piece.Config) == "table" and type(piece.Config.Booster) == "table"
			then piece.Config.Booster
			else nil
		local enabled = if bstCfg and type(bstCfg.Enabled) == "boolean" then bstCfg.Enabled else true
		updateGuideForPiece(piece, enabled)
	end

	refreshPanel = function()
		if opts.IsBlockedByOtherPanel and opts.IsBlockedByOtherPanel() then
			panel.Visible = false
			destroyGuide()
			return
		end

		local piece = findSelectedBoosterPiece()
		if not piece then
			panel.Visible = false
			destroyGuide()
			return
		end

		if not panel.Visible and opts.OnBoosterPanelOpened then
			opts.OnBoosterPanelOpened()
		end
		panel.Visible = true
		fetchUnitsFromServerIfNeeded()

		local bstCfg = if type(piece.Config) == "table" and type(piece.Config.Booster) == "table"
			then piece.Config.Booster
			else nil
		local stats = BoosterCatalog.ResolveEffectiveStats({
			ItemId = piece.ItemId,
			BoosterFamilyId = if bstCfg then bstCfg.BoosterFamilyId else nil,
			BoosterSizeId = if bstCfg then bstCfg.BoosterSizeId else nil,
			VariantId = if bstCfg then bstCfg.VariantId else nil,
			RarityId = if bstCfg then bstCfg.RarityId else nil,
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

		local thrustLimit = if bstCfg and type(bstCfg.ThrustLimitRatio) == "number"
			then bstCfg.ThrustLimitRatio
			else GameConfig.Boosters.DefaultThrustLimitRatio
		local curveMode = if bstCfg and type(bstCfg.ThrottleCurveMode) == "string"
			then bstCfg.ThrottleCurveMode
			else GameConfig.Boosters.DefaultThrottleCurveMode
		local enabled = if bstCfg and type(bstCfg.Enabled) == "boolean" then bstCfg.Enabled else true

		local unitLabel = if piece.InventoryInstanceId and #piece.InventoryInstanceId > 0
			then piece.InventoryInstanceId
			else "Catálogo Base (Sin unidad única)"

		local localAxis = GameConfig.Boosters.DefaultLocalThrustAxis
		if localAxis.Magnitude < 1e-4 then
			localAxis = Vector3.new(0, 0, -1)
		else
			localAxis = localAxis.Unit
		end
		local pieceWorldCF = resolvePieceWorldCFrame(piece)
		local worldThrustDir = pieceWorldCF:VectorToWorldSpace(localAxis).Unit
		local vehicleThrustDir = piece.LocalCFrame:VectorToWorldSpace(localAxis).Unit
		local dirLabel = BoosterInspectorPanel.DescribeThrustDirection(vehicleThrustDir)

		local lines = {
			`Unidad: {unitLabel} | {if enabled then "ACTIVO" else "DESACTIVADO"}`,
			`Familia: {stats.BoosterFamilyId} | Tam: {stats.BoosterSizeId} | {stats.RarityId} · {stats.VariantId}`,
			string.format(
				"Empuje Efectivo: %.0f (Base %.0f) | Vel. Máx Mult: %.2fx",
				stats.Thrust * thrustLimit,
				stats.Thrust,
				stats.SpeedBoostMultiplier
			),
			string.format(
				"Nitro Int.: %.0f | Consumo: %.0f/s | Durab.: %d | Peso: %.1f | Bono: +%.2fx",
				stats.IntegratedFuel,
				stats.BoostConsumption * thrustLimit,
				stats.MaxDurability,
				stats.Weight,
				stats.DrivingBonus
			),
			string.format(
				"Rampa Ign./Apag.: %.2fs / %.2fs | Curva: %s",
				stats.IgnitionRampSeconds,
				stats.ShutdownRampSeconds,
				curveMode
			),
			string.format(
				"Dirección Empuje (Veh.): %s | Mundo: (%.2f, %.2f, %.2f)",
				dirLabel,
				worldThrustDir.X,
				worldThrustDir.Y,
				worldThrustDir.Z
			),
		}
		statsBox.Text = table.concat(lines, "\n")

		lim25Btn.BackgroundColor3 = if math.abs(thrustLimit - 0.25) < 0.05 then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)
		lim50Btn.BackgroundColor3 = if math.abs(thrustLimit - 0.50) < 0.05 then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)
		lim75Btn.BackgroundColor3 = if math.abs(thrustLimit - 0.75) < 0.05 then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)
		lim100Btn.BackgroundColor3 = if math.abs(thrustLimit - 1.00) < 0.05 then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)

		curveInstantBtn.BackgroundColor3 = if curveMode == "Instant" then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)
		curveSmoothBtn.BackgroundColor3 = if curveMode == "Smooth" then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)
		curveSustainedBtn.BackgroundColor3 = if curveMode == "Sustained" then Color3.fromRGB(48, 138, 198) else Color3.fromRGB(48, 56, 72)

		if enabled then
			toggleEnabledBtn.Text = "ACTIVO (Responde a LeftShift)"
			toggleEnabledBtn.BackgroundColor3 = Color3.fromRGB(36, 128, 86)
		else
			toggleEnabledBtn.Text = "DESACTIVADO (Ignora Boost)"
			toggleEnabledBtn.BackgroundColor3 = Color3.fromRGB(132, 58, 58)
		end

		updateGuideForPiece(piece, enabled)

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

		local displayUnits = if BuildState.Inventory and type(BuildState.Inventory.BoosterUnits) == "table"
			then BuildState.Inventory.BoosterUnits
			else cachedUnits

		if #displayUnits == 0 then
			local emptyLbl = Instance.new("TextLabel")
			emptyLbl.Name = "EmptyUnitsLabel"
			emptyLbl.Size = UDim2.new(1, -8, 0, 28)
			emptyLbl.BackgroundTransparency = 1
			emptyLbl.Font = Enum.Font.GothamMedium
			emptyLbl.TextSize = 11
			emptyLbl.TextColor3 = Color3.fromRGB(165, 175, 195)
			emptyLbl.Text = "No tienes unidades de propulsor disponibles en tu inventario."
			emptyLbl.TextWrapped = true
			emptyLbl.Parent = unitsScroll
		end

		for idx, unit in ipairs(displayUnits) do
			local uStats = unit.EffectiveStats
			local assignedPieceId = usedByPieceId[unit.ItemInstanceId]
			local isCurrent = assignedPieceId == piece.InstanceId
			local isUsedElsewhere = assignedPieceId ~= nil and not isCurrent

			local statusTag = if isCurrent
				then "[INSTALADO AQUÍ]"
				elseif isUsedElsewhere then `[EN USO: {assignedPieceId}]`
				else "[DISPONIBLE]"

			local rowBtn = makeButton(
				`Unit_{idx}`,
				`{uStats.FullLabel} | Emp:{math.round(uStats.Thrust)} | {statusTag}`,
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
					BuildState.SetError("Esa unidad de propulsor ya está instalada en otra pieza del vehículo.")
					return
				end
				sendBoosterConfigUpdate(piece.InstanceId, nil, unit.ItemInstanceId, false)
			end)
		end
	end

	return {
		Frame = panel,
		Refresh = refreshPanel,
		RefreshGuidePose = refreshGuidePose,
		Close = function()
			panel.Visible = false
			destroyGuide()
		end,
		GetActiveGuideModel = function(): Model?
			return activeGuideModel
		end,
		Destroy = function()
			destroyGuide()
			panel:Destroy()
		end,
	}
end

return BoosterInspectorPanel

