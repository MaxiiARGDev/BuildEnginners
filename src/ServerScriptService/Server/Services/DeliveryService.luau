--!strict
--[=[
	DeliveryService
	Gestor autoritativo de pedidos (Normales 60 s / Especiales 900 s), entregas en DeliveryZone,
	camión de reparto físico y apertura idempotente de cajas (Fase 5.2).

	Invariantes críticas:
	- Los temporizadores usan timestamps absolutos persistentes: al desconectar siguen corriendo y
	  nunca se reinician al reconectar.
	- Pedidos normales desbloquean nuevas compras apenas vence ArriveAt (Status = "Arrived"),
	  incluso si todas las plazas físicas (VisualCapacity = 6) de DeliveryZone están ocupadas.
	- Cola justa compartida entre cajas normales y especiales cuando DeliveryZone supera 6 cajas.
	- Apertura de caja especial sortea y persiste RolledReward una sola vez antes de acreditar en
	  InventoryService, impidiendo sorteos repetidos o duplicación de recompensas.
	- Reveal físico del motor/propulsor sobre DeliveryZone con BillboardGui (nombre y rareza),
	  siempre como representación visual desechable tras haber sido acreditado de forma segura.
	- El camión de reparto (ServerStorage.Crates.Reparto.DeliveryTruck) permanece fuera de BuildZone,
	  sin asientos ni colisiones destructivas contra vehículos de jugadores; cualquier fallo visual no
	  afecta jamás la entrega autoritativa del pedido.
]=]

local HttpService = game:GetService("HttpService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local LootBoxService = require(ServerScriptService.Server.Services.LootBoxService)
local OrderPersistenceService = require(ServerScriptService.Server.Services.OrderPersistenceService)
local PlotService = require(ServerScriptService.Server.Services.PlotService)

export type PlayerLike = PlotService.PlayerLike

local DeliveryService = {
	Name = "DeliveryService",
}

local _initialized = false
local _started = false
local _clockFn: () -> number = os.time
local _lootRngOverride: (() -> number)? = nil

local _ordersByUserId: { [number]: ItemTypes.PlayerOrdersStorage } = {}
local _userLocks: { [number]: boolean } = {}
local _openingCrateLocks: { [string]: boolean } = {}
local _spawnedCrateModelsByCrateId: { [string]: Model } = {}
local _temporaryPropsToCleanup: { { ExpiresAt: number, Model: Instance, OwnerUserId: number } } = {}
local _heartbeatConn: RBXScriptConnection? = nil
local _accumStep = 0

local _ordersUpdatedListeners: { (userId: number, reason: string) -> () } = {}
local _truckArrivingListeners: { (userId: number, orderId: string, orderType: string) -> () } = {}
local _crateEffectListeners: { (userId: number, payload: { [string]: any }) -> () } = {}

local function extractUserId(playerOrUserId: PlayerLike | number): number
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return playerOrUserId.UserId
	elseif type(playerOrUserId) == "table" and type((playerOrUserId :: any).UserId) == "number" then
		return (playerOrUserId :: any).UserId
	end
	error("[DeliveryService] Jugador inválido", 3)
end

local function makeId(prefix: string): string
	return prefix .. string.lower(string.gsub(HttpService:GenerateGUID(false), "-", "")):sub(1, 16)
end

local function ensureCollisionGroupsRegistered()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(ShopConfig.DeliveryZone.TruckCollisionGroup)
	end)
	for _, group in ipairs({
		GameConfig.Runtime.CollisionGroupName,
		GameConfig.Building.EditableCollisionGroupName,
		GameConfig.Building.GhostCollisionGroupName,
		"VehicleDebris",
	}) do
		pcall(function()
			PhysicsService:CollisionGroupSetCollidable(ShopConfig.DeliveryZone.TruckCollisionGroup, group, false)
		end)
	end
end

local function createFreshOrdersStorage(userId: number): ItemTypes.PlayerOrdersStorage
	return {
		StorageSchemaVersion = ShopConfig.Orders.StorageSchemaVersion,
		OwnerUserId = userId,
		OrdersRevision = 0,
		UpdatedAt = _clockFn(),
		ActiveNormalOrderId = nil,
		PendingRushOrderId = nil,
		NormalOrders = {},
		SpecialOrders = {},
		ProcessedTxIds = {},
	}
end

local function cloneOrdersStorage(s: ItemTypes.PlayerOrdersStorage): ItemTypes.PlayerOrdersStorage
	local copyNormal: { ItemTypes.NormalOrderRecord } = table.create(#s.NormalOrders)
	for _, o in ipairs(s.NormalOrders) do
		local linesCopy = table.create(#o.Lines)
		for _, l in ipairs(o.Lines) do
			table.insert(linesCopy, table.clone(l))
		end
		local cratesCopy = table.create(#o.Crates)
		for _, c in ipairs(o.Crates) do
			table.insert(cratesCopy, table.clone(c))
		end
		table.insert(copyNormal, {
			OrderId = o.OrderId,
			OrderType = "Normal",
			OwnerUserId = o.OwnerUserId,
			Status = o.Status,
			CreatedAt = o.CreatedAt,
			ArriveAt = o.ArriveAt,
			ArrivedAt = o.ArrivedAt,
			DeliveryUnlocked = o.DeliveryUnlocked,
			RushedByRobux = o.RushedByRobux,
			RushPurchaseId = o.RushPurchaseId,
			TotalCost = o.TotalCost,
			Lines = linesCopy,
			Crates = cratesCopy,
			TruckAnimated = o.TruckAnimated,
		})
	end

	local copySpecial: { ItemTypes.SpecialOrderRecord } = table.create(#s.SpecialOrders)
	for _, o in ipairs(s.SpecialOrders) do
		local readyAt = (o :: any).ReadyAt or o.ArriveAt
		table.insert(copySpecial, {
			OrderId = o.OrderId,
			OrderType = "Special",
			OwnerUserId = o.OwnerUserId,
			BoxId = o.BoxId,
			RewardCategory = o.RewardCategory,
			PricePaid = o.PricePaid,
			Status = o.Status,
			CreatedAt = o.CreatedAt,
			ArriveAt = readyAt,
			ReadyAt = readyAt,
			DeliverySeconds = (o :: any).DeliverySeconds,
			ArrivedAt = o.ArrivedAt,
			RushedByRobux = o.RushedByRobux,
			RushPurchaseId = o.RushPurchaseId,
			SlotIndex = o.SlotIndex,
			OpeningStartedAt = o.OpeningStartedAt,
			RolledReward = if o.RolledReward then table.clone(o.RolledReward) else nil,
			TruckAnimated = o.TruckAnimated,
		} :: any)
	end

	return {
		StorageSchemaVersion = s.StorageSchemaVersion,
		OwnerUserId = s.OwnerUserId,
		OrdersRevision = s.OrdersRevision,
		UpdatedAt = s.UpdatedAt,
		ActiveNormalOrderId = s.ActiveNormalOrderId,
		PendingRushOrderId = s.PendingRushOrderId,
		NormalOrders = copyNormal,
		SpecialOrders = copySpecial,
		ProcessedTxIds = table.clone(s.ProcessedTxIds),
	}
end

local function emitOrdersUpdated(userId: number, reason: string)
	for _, cb in ipairs(table.clone(_ordersUpdatedListeners)) do
		task.spawn(cb, userId, reason)
	end
end

local function emitTruckArriving(userId: number, orderId: string, orderType: string)
	for _, cb in ipairs(table.clone(_truckArrivingListeners)) do
		task.spawn(cb, userId, orderId, orderType)
	end
end

local function emitCrateEffect(userId: number, payload: { [string]: any })
	for _, cb in ipairs(table.clone(_crateEffectListeners)) do
		task.spawn(cb, userId, payload)
	end
end

local function commitOrdersMutation(
	userId: number,
	mutateFn: (draft: ItemTypes.PlayerOrdersStorage) -> (boolean, string?, string?)
): (boolean, ItemTypes.PlayerOrdersStorage?, string?, string?)
	local cur = _ordersByUserId[userId]
	if not cur then
		return false, nil, ShopProtocol.ErrorCodes.PersistenceFailed, "Pedidos no cargados."
	end
	local draft = cloneOrdersStorage(cur)
	local okMut, errCode, errMsg = mutateFn(draft)
	if not okMut then
		return false, nil, errCode, errMsg
	end
	draft.OrdersRevision += 1
	draft.UpdatedAt = _clockFn()
	local okSave, saveCode, saveMsg = OrderPersistenceService.SavePlayerOrders(userId, draft)
	if not okSave then
		return false, nil, saveCode or ShopProtocol.ErrorCodes.PersistenceFailed, saveMsg or "Error al guardar pedidos."
	end
	_ordersByUserId[userId] = draft
	return true, draft, nil, nil
end

local function sanitizeModelVisual(model: Model, anchored: boolean, canCollide: boolean)
	local firstPart: BasePart? = model.PrimaryPart
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Seat") or d:IsA("VehicleSeat") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = anchored
			d.CanCollide = canCollide
			d.CollisionGroup = ShopConfig.DeliveryZone.TruckCollisionGroup
			if not firstPart or d.Name == "Primary" then
				firstPart = d
			end
		end
	end
	if not model.PrimaryPart and firstPart then
		model.PrimaryPart = firstPart
	end
end

local function resolveCrateTemplate(isSpecial: boolean, boxId: string?): Model
	local cratesRoot = ServerStorage:FindFirstChild(ShopConfig.Assets.CratesRootFolder)
	if cratesRoot then
		if isSpecial and boxId then
			local boxDef = LootBoxConfig.GetBox(boxId)
			local specials = cratesRoot:FindFirstChild(ShopConfig.Assets.SpecialFolder)
			if specials and boxDef then
				local catFolder = specials:FindFirstChild(boxDef.AssetSubfolder)
				local direct = (catFolder and catFolder:FindFirstChild(boxDef.ModelName))
					or specials:FindFirstChild(boxDef.ModelName, true)
				if direct and direct:IsA("Model") then
					return direct:Clone()
				end
			end
		else
			local normals = cratesRoot:FindFirstChild(ShopConfig.Assets.NormalFolder)
			local found = (normals and normals:FindFirstChild(ShopConfig.Assets.NormalCrateModel))
				or cratesRoot:FindFirstChild(ShopConfig.Assets.NormalCrateModel, true)
			if found and found:IsA("Model") then
				return found:Clone()
			end
		end
	end

	-- Fallback seguro si el creador borró temporalmente una plantilla en Explorer
	local fallback = Instance.new("Model")
	fallback.Name = if isSpecial and boxId then boxId else ShopConfig.Assets.NormalCrateModel
	local p = Instance.new("Part")
	p.Name = "Primary"
	p.Size = Vector3.new(2.4, 2.0, 2.4)
	p.Anchored = true
	p.Color = if isSpecial then Color3.fromRGB(220, 155, 50) else Color3.fromRGB(165, 118, 72)
	p.Parent = fallback
	fallback.PrimaryPart = p
	return fallback
end

local function resolveDeliveryTruckTemplate(): Model?
	local cratesRoot = ServerStorage:FindFirstChild(ShopConfig.Assets.CratesRootFolder)
	if not cratesRoot then
		return nil
	end
	local deliveryFolder = cratesRoot:FindFirstChild(ShopConfig.Assets.DeliveryFolder)
	local truck = (deliveryFolder and deliveryFolder:FindFirstChild(ShopConfig.Assets.DeliveryTruckModel))
		or cratesRoot:FindFirstChild(ShopConfig.Assets.DeliveryTruckModel, true)
	if truck and truck:IsA("Model") then
		return truck:Clone()
	end
	return nil
end

local function playTruckDeliveryAnimation(userId: number, plot: PlotService.PlotRecord, orderId: string, orderType: string)
	emitTruckArriving(userId, orderId, orderType)
	if not RunService:IsRunning() then
		return
	end
	local truck = resolveDeliveryTruckTemplate()
	if not truck then
		return
	end

	task.spawn(function()
		pcall(function()
			local container = plot.ShopDeliveryContainer
			if not container or not container.Parent then
				truck:Destroy()
				return
			end
			sanitizeModelVisual(truck, true, false)
			local dzCF = plot.Zones.DeliveryZone.CFrame
			local topOffset = plot.Zones.DeliveryZone.Size.Y * 0.5
			local startPos = dzCF:PointToWorldSpace(ShopConfig.DeliveryZone.TruckApproachOffset + Vector3.new(0, topOffset, 0))
			local stopPos = dzCF:PointToWorldSpace(ShopConfig.DeliveryZone.TruckUnloadOffset + Vector3.new(0, topOffset, 0))
			local exitPos = dzCF:PointToWorldSpace(ShopConfig.DeliveryZone.TruckExitOffset + Vector3.new(0, topOffset, 0))

			truck.Name = `DeliveryTruck_{orderId}`
			truck:PivotTo(CFrame.lookAt(startPos, stopPos))
			truck.Parent = container

			local cratesRoot = ServerStorage:FindFirstChild(ShopConfig.Assets.CratesRootFolder)
			local effects = cratesRoot and cratesRoot:FindFirstChild(ShopConfig.Assets.EffectsFolder)
			local arriveSnd = effects and effects:FindFirstChild("CrateArriveSound", true)
			if arriveSnd and arriveSnd:IsA("Sound") and #arriveSnd.SoundId > 0 and truck.PrimaryPart then
				local sClone = arriveSnd:Clone()
				sClone.Parent = truck.PrimaryPart
				sClone:Play()
			end

			local function tweenPivot(fromCF: CFrame, toCF: CFrame, dur: number)
				local elapsed = 0
				while elapsed < dur and truck.Parent and container.Parent do
					local dt = task.wait()
					elapsed += dt
					local alpha = math.clamp(elapsed / dur, 0, 1)
					local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
					truck:PivotTo(fromCF:Lerp(toCF, eased))
				end
			end

			local arrivalCF = CFrame.lookAt(stopPos, Vector3.new(exitPos.X, stopPos.Y, exitPos.Z))
			tweenPivot(CFrame.lookAt(startPos, stopPos), arrivalCF, 0.85)
			task.wait(0.45)
			tweenPivot(arrivalCF, CFrame.lookAt(exitPos, exitPos + (exitPos - stopPos)), 0.85)

			if truck.Parent then
				truck:Destroy()
			end
		end)
	end)
end

local function getSlotWorldCFrame(zone: BasePart, slotIndex: number): CFrame
	local cols = math.max(1, ShopConfig.DeliveryZone.GridColumns)
	local rows = math.max(1, ShopConfig.DeliveryZone.GridRows)
	local col = ((slotIndex - 1) % cols)
	local row = math.floor((slotIndex - 1) / cols)
	local centerOffsetX = (col - (cols - 1) * 0.5) * ShopConfig.DeliveryZone.SlotSpacingX
	local centerOffsetZ = (row - (rows - 1) * 0.5) * ShopConfig.DeliveryZone.SlotSpacingZ
	local topY = zone.Size.Y * 0.5 + ShopConfig.DeliveryZone.SlotElevationY
	return zone.CFrame * CFrame.new(centerOffsetX, topY, centerOffsetZ)
end

local function attachCrateBillboard(part: BasePart, title: string, subtitle: string, accentColor: Color3)
	local gui = Instance.new("BillboardGui")
	gui.Name = "CrateLabelGui"
	gui.Size = UDim2.fromOffset(180, 48)
	gui.StudsOffset = Vector3.new(0, 2.5, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 48
	gui.Parent = part

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	bg.BackgroundTransparency = 0.16
	bg.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = bg
	local stroke = Instance.new("UIStroke")
	stroke.Color = accentColor
	stroke.Thickness = 1.5
	stroke.Parent = bg

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Name = "TitleLabel"
	titleLbl.Size = UDim2.new(1, -8, 0, 22)
	titleLbl.Position = UDim2.fromOffset(4, 3)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 12
	titleLbl.TextColor3 = accentColor
	titleLbl.Text = title
	titleLbl.TextTruncate = Enum.TextTruncate.AtEnd
	titleLbl.Parent = bg

	local subLbl = Instance.new("TextLabel")
	subLbl.Name = "SubtitleLabel"
	subLbl.Size = UDim2.new(1, -8, 0, 18)
	subLbl.Position = UDim2.fromOffset(4, 25)
	subLbl.BackgroundTransparency = 1
	subLbl.Font = Enum.Font.Gotham
	subLbl.TextSize = 11
	subLbl.TextColor3 = Color3.fromRGB(232, 238, 248)
	subLbl.Text = subtitle
	subLbl.TextTruncate = Enum.TextTruncate.AtEnd
	subLbl.Parent = bg
end

local function clearSpawnedCrateModel(crateId: string)
	local existing = _spawnedCrateModelsByCrateId[crateId]
	if existing then
		_spawnedCrateModelsByCrateId[crateId] = nil
		if existing.Parent then
			existing:Destroy()
		end
	end
end

local function buildPhysicalCrateModel(
	userId: number,
	plot: PlotService.PlotRecord,
	crateId: string,
	isSpecial: boolean,
	boxId: string?,
	itemId: string?,
	qty: number?,
	slotIndex: number
)
	local container = plot.ShopDeliveryContainer
	if not container or not container.Parent then
		return
	end
	clearSpawnedCrateModel(crateId)

	local model = resolveCrateTemplate(isSpecial, boxId)
	model.Name = `DeliveryCrate_{crateId}`
	sanitizeModelVisual(model, true, true)
	model:SetAttribute("CrateId", crateId)
	model:SetAttribute("OwnerUserId", userId)
	model:SetAttribute("IsSpecial", isSpecial)
	if boxId then
		model:SetAttribute("BoxId", boxId)
	end
	if itemId then
		model:SetAttribute("ItemId", itemId)
	end

	local slotCF = getSlotWorldCFrame(plot.Zones.DeliveryZone, slotIndex)
	local prim = model.PrimaryPart :: BasePart
	local heightHalf = prim.Size.Y * 0.5
	local targetCF = slotCF * CFrame.new(0, heightHalf, 0)
	local pivotToPrim = model:GetPivot():ToObjectSpace(prim.CFrame)
	model:PivotTo(targetCF * pivotToPrim:Inverse())

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "OpenCratePrompt"
	prompt.MaxActivationDistance = ShopConfig.DeliveryZone.MaxPromptDistance
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0
	if isSpecial and boxId then
		local boxDef = LootBoxConfig.GetBox(boxId)
		prompt.ObjectText = if boxDef then boxDef.DisplayName else boxId
		prompt.ActionText = "Abrir Caja Especial"
		attachCrateBillboard(
			prim,
			prompt.ObjectText,
			"Caja Especial · Abrir [E]",
			Color3.fromRGB(255, 198, 72)
		)
	else
		local dispName = ItemCatalog.GetDisplayName(itemId or "")
		prompt.ObjectText = `{qty or 1}x {dispName}`
		prompt.ActionText = "Recoger Caja"
		attachCrateBillboard(
			prim,
			dispName,
			`Cantidad: ×{qty or 1} · Abrir [E]`,
			Color3.fromRGB(110, 224, 190)
		)
	end
	prompt.Parent = prim

	prompt.Triggered:Connect(function(triggerPlayer: Player)
		if triggerPlayer.UserId ~= userId then
			return
		end
		DeliveryService.OpenCrate(triggerPlayer, crateId)
	end)

	model.Parent = container
	_spawnedCrateModelsByCrateId[crateId] = model
end

local function spawnRevealedSpecialUnitModel(
	userId: number,
	plot: PlotService.PlotRecord?,
	slotIndex: number?,
	reward: ItemTypes.RolledLootReward
): Model?
	if not plot or not plot.ShopDeliveryContainer or not plot.ShopDeliveryContainer.Parent then
		return nil
	end

	local itemDef = ItemRegistry.TryGet(reward.ItemId)
	local folderName = if itemDef then ItemRegistry.GetAssetFolder(itemDef) else (if reward.Category == "Boosters" then "Propulsores" else "Motores")
	local itemAssets = ServerStorage:FindFirstChild("ItemAssets")
	local folder = itemAssets and itemAssets:FindFirstChild(folderName)
	local template = folder and folder:FindFirstChild(reward.ItemId)
	local revealModel: Model
	if template and template:IsA("Model") then
		revealModel = template:Clone()
	else
		revealModel = Instance.new("Model")
		local p = Instance.new("Part")
		p.Name = "Primary"
		p.Size = Vector3.new(2, 2, 2)
		p.Parent = revealModel
		revealModel.PrimaryPart = p
	end

	revealModel.Name = `RevealedReward_{reward.ItemInstanceId}`
	sanitizeModelVisual(revealModel, true, false)
	revealModel:SetAttribute("IsRevealedRewardVisual", true)
	revealModel:SetAttribute("OwnerUserId", userId)
	revealModel:SetAttribute("ItemInstanceId", reward.ItemInstanceId)
	revealModel:SetAttribute("RarityId", reward.RarityId)

	local hex = ItemCatalog.GetRarityColorHex(reward.RarityId)
	local okCol, rarityColor = pcall(Color3.fromHex, hex)
	local badgeColor = if okCol then rarityColor else Color3.fromRGB(240, 200, 90)

	local prim = revealModel.PrimaryPart :: BasePart
	if reward.RarityId ~= "Common" then
		prim.Color = badgeColor
	end

	local slotCF = getSlotWorldCFrame(plot.Zones.DeliveryZone, slotIndex or 1)
	local targetCF = slotCF * CFrame.new(0, prim.Size.Y * 0.5 + 0.15, 0)
	local pivotToPrim = revealModel:GetPivot():ToObjectSpace(prim.CFrame)
	revealModel:PivotTo(targetCF * pivotToPrim:Inverse())

	attachCrateBillboard(prim, reward.FullLabel, `Rareza: {reward.RarityId} · Guardado en Inventario`, badgeColor)

	local cratesRoot = ServerStorage:FindFirstChild(ShopConfig.Assets.CratesRootFolder)
	local effects = cratesRoot and cratesRoot:FindFirstChild(ShopConfig.Assets.EffectsFolder)
	local burst = effects and effects:FindFirstChild("OpenSparkEmitter", true)
	if burst and burst:IsA("ParticleEmitter") then
		local bClone = burst:Clone()
		bClone.Parent = prim
		bClone:Emit(24)
	end
	local glow = effects and effects:FindFirstChild("CrateGlowLight", true)
	if glow and glow:IsA("PointLight") then
		local lClone = glow:Clone()
		lClone.Color = badgeColor
		lClone.Parent = prim
	end

	revealModel.Parent = plot.ShopDeliveryContainer
	table.insert(_temporaryPropsToCleanup, {
		ExpiresAt = _clockFn() + ShopConfig.DeliveryZone.CrateRevealLifetimeSeconds,
		Model = revealModel,
		OwnerUserId = userId,
	})
	return revealModel
end

local function collectFairPendingCrates(storage: ItemTypes.PlayerOrdersStorage): {
	SpawnedSlots: { [number]: string },
	QueuedEntries: { { IsSpecial: boolean, CrateId: string, OrderId: string, ItemId: string?, Quantity: number?, BoxId: string?, ArriveAt: number } },
}
	local spawnedSlots: { [number]: string } = {}
	local normalQueue: { any } = {}
	local specialQueue: { any } = {}

	for _, o in ipairs(storage.NormalOrders) do
		if o.Status == "Arrived" then
			for _, c in ipairs(o.Crates) do
				if c.Status == "Spawned" and c.SlotIndex then
					spawnedSlots[c.SlotIndex] = c.CrateId
				elseif c.Status == "Queued" or (c.Status == "Spawned" and not c.SlotIndex) then
					table.insert(normalQueue, {
						IsSpecial = false,
						CrateId = c.CrateId,
						OrderId = o.OrderId,
						ItemId = c.ItemId,
						Quantity = c.Quantity,
						ArriveAt = o.ArriveAt,
					})
				end
			end
		end
	end

	for _, o in ipairs(storage.SpecialOrders) do
		if o.Status == "Arrived" or o.Status == "Opened" then
			if o.SlotIndex then
				spawnedSlots[o.SlotIndex] = o.OrderId
			else
				table.insert(specialQueue, {
					IsSpecial = true,
					CrateId = o.OrderId,
					OrderId = o.OrderId,
					BoxId = o.BoxId,
					ArriveAt = o.ArriveAt,
				})
			end
		end
	end

	table.sort(normalQueue, function(a, b)
		if a.ArriveAt ~= b.ArriveAt then return a.ArriveAt < b.ArriveAt end
		return a.CrateId < b.CrateId
	end)
	table.sort(specialQueue, function(a, b)
		if a.ArriveAt ~= b.ArriveAt then return a.ArriveAt < b.ArriveAt end
		return a.CrateId < b.CrateId
	end)

	-- Intercalado justo 1:1 para evitar inanición entre pedidos normales y cajas especiales en DeliveryZone compartida
	local interleaved: { any } = {}
	local ni, si = 1, 1
	while ni <= #normalQueue or si <= #specialQueue do
		if ni <= #normalQueue and (si > #specialQueue or normalQueue[ni].ArriveAt <= specialQueue[si].ArriveAt) then
			table.insert(interleaved, normalQueue[ni])
			ni += 1
			if si <= #specialQueue then
				table.insert(interleaved, specialQueue[si])
				si += 1
			end
		elseif si <= #specialQueue then
			table.insert(interleaved, specialQueue[si])
			si += 1
			if ni <= #normalQueue then
				table.insert(interleaved, normalQueue[ni])
				ni += 1
			end
		end
	end

	return {
		SpawnedSlots = spawnedSlots,
		QueuedEntries = interleaved,
	}
end

function DeliveryService.ReconcileDeliveryZoneForUser(userId: number): boolean
	local storage = _ordersByUserId[userId]
	if not storage then
		return false
	end

	local plot = PlotService.GetPlotByPlayer({ UserId = userId, Name = "" })
	local cap = ShopConfig.DeliveryZone.VisualCapacity
	local fair = collectFairPendingCrates(storage)
	local occupied = fair.SpawnedSlots
	local assignedAny = false

	-- Asignar espacios libres (1..VisualCapacity)
	for _, entry in ipairs(fair.QueuedEntries) do
		local freeSlot: number? = nil
		for idx = 1, cap do
			if not occupied[idx] then
				freeSlot = idx
				break
			end
		end
		if not freeSlot then
			break
		end
		occupied[freeSlot] = entry.CrateId
		entry.AssignedSlot = freeSlot
		assignedAny = true
	end

	if assignedAny then
		local assignedMap: { [string]: number } = {}
		for _, entry in ipairs(fair.QueuedEntries) do
			if entry.AssignedSlot then
				assignedMap[entry.CrateId] = entry.AssignedSlot
			end
		end
		commitOrdersMutation(userId, function(draft)
			for _, o in ipairs(draft.NormalOrders) do
				for _, c in ipairs(o.Crates) do
					if assignedMap[c.CrateId] then
						c.Status = "Spawned"
						c.SlotIndex = assignedMap[c.CrateId]
					end
				end
			end
			for _, o in ipairs(draft.SpecialOrders) do
				if assignedMap[o.OrderId] then
					o.SlotIndex = assignedMap[o.OrderId]
				end
			end
			return true, nil, nil
		end)
		storage = _ordersByUserId[userId] :: ItemTypes.PlayerOrdersStorage
	end

	-- Reconstruir o verificar presencia física de modelos asignados en la DeliveryZone del jugador
	if plot and plot.ShopDeliveryContainer and plot.ShopDeliveryContainer.Parent then
		for _, o in ipairs(storage.NormalOrders) do
			if o.Status == "Arrived" then
				for _, c in ipairs(o.Crates) do
					if c.Status == "Spawned" and c.SlotIndex then
						local existing = _spawnedCrateModelsByCrateId[c.CrateId]
						if not existing or not existing.Parent then
							buildPhysicalCrateModel(userId, plot, c.CrateId, false, nil, c.ItemId, c.Quantity, c.SlotIndex)
						end
					elseif c.Status == "Opened" then
						clearSpawnedCrateModel(c.CrateId)
					end
				end
			end
		end
		for _, o in ipairs(storage.SpecialOrders) do
			if (o.Status == "Arrived" or o.Status == "Opened") and o.SlotIndex then
				local existing = _spawnedCrateModelsByCrateId[o.OrderId]
				if not existing or not existing.Parent then
					buildPhysicalCrateModel(userId, plot, o.OrderId, true, o.BoxId, nil, nil, o.SlotIndex)
				end
			elseif o.Status == "Claimed" then
				clearSpawnedCrateModel(o.OrderId)
			end
		end
	end

	return true
end

function DeliveryService.ProcessArrivalsForUser(userId: number): boolean
	local storage = _ordersByUserId[userId]
	if not storage then
		return false
	end

	local now = _clockFn()
	local needsUpdate = false
	local newlyArrived: { { OrderId: string, OrderType: string } } = {}

	for _, o in ipairs(storage.NormalOrders) do
		if o.Status == "InTransit" and now >= o.ArriveAt then
			needsUpdate = true
			table.insert(newlyArrived, { OrderId = o.OrderId, OrderType = "Normal" })
		end
	end
	for _, o in ipairs(storage.SpecialOrders) do
		if o.Status == "InTransit" and now >= o.ArriveAt then
			needsUpdate = true
			table.insert(newlyArrived, { OrderId = o.OrderId, OrderType = "Special" })
		end
	end

	if needsUpdate then
		local okCommit = commitOrdersMutation(userId, function(draft)
			for _, o in ipairs(draft.NormalOrders) do
				if o.Status == "InTransit" and now >= o.ArriveAt then
					o.Status = "Arrived"
					o.ArrivedAt = now
					o.DeliveryUnlocked = true
					o.TruckAnimated = true
					if draft.ActiveNormalOrderId == o.OrderId then
						draft.ActiveNormalOrderId = nil
					end
					if draft.PendingRushOrderId == o.OrderId then
						draft.PendingRushOrderId = nil
					end
				end
			end
			for _, o in ipairs(draft.SpecialOrders) do
				if o.Status == "InTransit" and now >= o.ArriveAt then
					o.Status = "Arrived"
					o.ArrivedAt = now
					o.TruckAnimated = true
					if draft.PendingRushOrderId == o.OrderId then
						draft.PendingRushOrderId = nil
					end
				end
			end
			return true, nil, nil
		end)
		if okCommit then
			local plot = PlotService.GetPlotByPlayer({ UserId = userId, Name = "" })
			for _, arr in ipairs(newlyArrived) do
				if plot then
					playTruckDeliveryAnimation(userId, plot, arr.OrderId, arr.OrderType)
				end
			end
			DeliveryService.ReconcileDeliveryZoneForUser(userId)
			emitOrdersUpdated(userId, "OrderArrived")
		end
	else
		DeliveryService.ReconcileDeliveryZoneForUser(userId)
	end

	return needsUpdate
end

function DeliveryService.EnsurePlayerLoaded(
	playerOrUserId: PlayerLike | number
): (boolean, ItemTypes.PlayerOrdersStorage?, string?, string?)
	if not _initialized then
		DeliveryService.Init()
	end
	local userId = extractUserId(playerOrUserId)
	local cached = _ordersByUserId[userId]
	if cached then
		return true, cached, nil, nil
	end

	local okLoad, loaded, code, msg = OrderPersistenceService.LoadPlayerOrders(userId)
	if not okLoad then
		return false, nil, code or ShopProtocol.ErrorCodes.PersistenceFailed, msg or "Error al cargar pedidos."
	end

	local finalStorage = loaded or createFreshOrdersStorage(userId)
	_ordersByUserId[userId] = finalStorage
	DeliveryService.ProcessArrivalsForUser(userId)
	return true, _ordersByUserId[userId], nil, nil
end

function DeliveryService.GetPlayerOrdersSnapshot(playerOrUserId: PlayerLike | number): {
	ActiveNormalOrderId: string?,
	NormalOrderBlocked: boolean,
	NormalOrderRemainingSeconds: number,
	PendingRushOrderId: string?,
	NormalOrders: { any },
	SpecialOrders: { any },
	QueuedCount: number,
	SpawnedCount: number,
	DeliveryZoneCapacity: number,
}?
	local okLoad, storage = DeliveryService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad or not storage then
		return nil
	end
	local userId = extractUserId(playerOrUserId)
	DeliveryService.ProcessArrivalsForUser(userId)
	storage = _ordersByUserId[userId] :: ItemTypes.PlayerOrdersStorage

	local now = _clockFn()
	local queuedCount = 0
	local spawnedCount = 0
	local normalRemaining = 0

	local normalOut: { any } = {}
	for _, o in ipairs(storage.NormalOrders) do
		local rem = math.max(0, o.ArriveAt - now)
		if o.Status == "InTransit" and storage.ActiveNormalOrderId == o.OrderId then
			normalRemaining = rem
		end
		local cratesOut = {}
		local unopened = 0
		for _, c in ipairs(o.Crates) do
			if c.Status == "Queued" then
				queuedCount += 1
				unopened += 1
			elseif c.Status == "Spawned" then
				spawnedCount += 1
				unopened += 1
			end
			table.insert(cratesOut, {
				CrateId = c.CrateId,
				ItemId = c.ItemId,
				DisplayName = ItemCatalog.GetDisplayName(c.ItemId),
				Quantity = c.Quantity,
				Status = c.Status,
				SlotIndex = c.SlotIndex,
			})
		end
		if o.Status ~= "Collected" or unopened > 0 then
			table.insert(normalOut, {
				OrderId = o.OrderId,
				OrderType = "Normal",
				Status = o.Status,
				CreatedAt = o.CreatedAt,
				ArriveAt = o.ArriveAt,
				RemainingSeconds = rem,
				TotalCost = o.TotalCost,
				RushedByRobux = o.RushedByRobux,
				Crates = cratesOut,
			})
		end
	end

	local specialOut: { any } = {}
	for _, o in ipairs(storage.SpecialOrders) do
		if o.Status ~= "Claimed" then
			if o.Status == "Arrived" or o.Status == "Opened" then
				if o.SlotIndex then
					spawnedCount += 1
				else
					queuedCount += 1
				end
			end
			local boxDef = LootBoxConfig.GetBox(o.BoxId)
			local readyAt = (o :: any).ReadyAt or o.ArriveAt
			local delSec = (o :: any).DeliverySeconds or math.max(0, readyAt - o.CreatedAt)
			table.insert(specialOut, {
				OrderId = o.OrderId,
				OrderType = "Special",
				BoxId = o.BoxId,
				DisplayName = if boxDef then boxDef.DisplayName else o.BoxId,
				RewardCategory = o.RewardCategory,
				PricePaid = o.PricePaid,
				Status = o.Status,
				CreatedAt = o.CreatedAt,
				ArriveAt = readyAt,
				ReadyAt = readyAt,
				DeliverySeconds = delSec,
				RemainingSeconds = math.max(0, readyAt - now),
				RushedByRobux = o.RushedByRobux,
				SlotIndex = o.SlotIndex,
				RolledReward = o.RolledReward,
			})
		end
	end

	return {
		ActiveNormalOrderId = storage.ActiveNormalOrderId,
		NormalOrderBlocked = storage.ActiveNormalOrderId ~= nil,
		NormalOrderRemainingSeconds = normalRemaining,
		PendingRushOrderId = storage.PendingRushOrderId,
		NormalOrders = normalOut,
		SpecialOrders = specialOut,
		QueuedCount = queuedCount,
		SpawnedCount = spawnedCount,
		DeliveryZoneCapacity = ShopConfig.DeliveryZone.VisualCapacity,
	}
end

function DeliveryService.GetPendingNormalQuantityForItem(playerOrUserId: PlayerLike | number, itemId: string): number
	local okLoad, storage = DeliveryService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad or not storage then
		return 0
	end
	local qty = 0
	for _, o in ipairs(storage.NormalOrders) do
		if o.Status ~= "Collected" then
			for _, c in ipairs(o.Crates) do
				if c.ItemId == itemId and c.Status ~= "Opened" then
					qty += c.Quantity
				end
			end
		end
	end
	return qty
end

function DeliveryService.IsNormalOrderInProgress(playerOrUserId: PlayerLike | number): boolean
	local okLoad, storage = DeliveryService.EnsurePlayerLoaded(playerOrUserId)
	if not okLoad or not storage then
		return false
	end
	local userId = extractUserId(playerOrUserId)
	DeliveryService.ProcessArrivalsForUser(userId)
	local latest = _ordersByUserId[userId]
	return latest ~= nil and latest.ActiveNormalOrderId ~= nil
end

function DeliveryService.CreateNormalOrder(
	playerOrUserId: PlayerLike | number,
	lines: { ItemTypes.NormalOrderLine },
	totalCost: number,
	txId: string?
): (boolean, ItemTypes.NormalOrderRecord?, string?, string?)
	local userId = extractUserId(playerOrUserId)
	local okLoad, _, loadCode, loadMsg = DeliveryService.EnsurePlayerLoaded(userId)
	if not okLoad then
		return false, nil, loadCode, loadMsg
	end
	DeliveryService.ProcessArrivalsForUser(userId)

	local now = _clockFn()
	local orderId = makeId("nord_")
	local crates: { ItemTypes.NormalOrderCrateRecord } = table.create(#lines)
	for _, line in ipairs(lines) do
		table.insert(crates, {
			CrateId = makeId("ncrate_"),
			OrderId = orderId,
			ItemId = line.ItemId,
			Quantity = line.Quantity,
			Status = "Queued",
			SlotIndex = nil,
			OpenedAt = nil,
			CreditedToInventory = false,
		})
	end

	local record: ItemTypes.NormalOrderRecord = {
		OrderId = orderId,
		OrderType = "Normal",
		OwnerUserId = userId,
		Status = "InTransit",
		CreatedAt = now,
		ArriveAt = now + ShopConfig.Orders.NormalOrderWaitSeconds,
		ArrivedAt = nil,
		DeliveryUnlocked = false,
		RushedByRobux = false,
		RushPurchaseId = nil,
		TotalCost = totalCost,
		Lines = lines,
		Crates = crates,
		TruckAnimated = false,
	}

	local createdOrExisting: ItemTypes.NormalOrderRecord = record
	local okCommit, _, errCode, errMsg = commitOrdersMutation(userId, function(draft)
		if type(txId) == "string" and #txId > 0 and table.find(draft.ProcessedTxIds, txId) ~= nil then
			if #draft.NormalOrders > 0 then
				createdOrExisting = draft.NormalOrders[#draft.NormalOrders]
			end
			return true, nil, nil
		end
		if draft.ActiveNormalOrderId ~= nil then
			return false,
				ShopProtocol.ErrorCodes.NormalOrderInProgress,
				"Ya tenés un pedido normal en camino. Esperá a que llegue para crear otro."
		end
		table.insert(draft.NormalOrders, record)
		draft.ActiveNormalOrderId = orderId
		if type(txId) == "string" and #txId > 0 then
			table.insert(draft.ProcessedTxIds, txId)
		end
		return true, nil, nil
	end)

	if not okCommit then
		return false, nil, errCode, errMsg
	end

	emitOrdersUpdated(userId, "NormalOrderCreated")
	return true, createdOrExisting, nil, nil
end

function DeliveryService.CreateSpecialOrder(
	playerOrUserId: PlayerLike | number,
	boxDef: LootBoxConfig.LootBoxDefinition,
	pricePaid: number,
	txId: string?
): (boolean, ItemTypes.SpecialOrderRecord?, string?, string?)
	local userId = extractUserId(playerOrUserId)
	local okLoad, _, loadCode, loadMsg = DeliveryService.EnsurePlayerLoaded(userId)
	if not okLoad then
		return false, nil, loadCode, loadMsg
	end

	local now = _clockFn()
	local orderId = makeId("sord_")
	local deliverySeconds = LootBoxConfig.GetDeliverySeconds(boxDef.BoxId)
	local readyAt = now + deliverySeconds
	local record: ItemTypes.SpecialOrderRecord = ({
		OrderId = orderId,
		OrderType = "Special",
		OwnerUserId = userId,
		BoxId = boxDef.BoxId,
		RewardCategory = boxDef.RewardCategory,
		PricePaid = pricePaid,
		Status = "InTransit",
		CreatedAt = now,
		ArriveAt = readyAt,
		ReadyAt = readyAt,
		DeliverySeconds = deliverySeconds,
		ArrivedAt = nil,
		RushedByRobux = false,
		RushPurchaseId = nil,
		SlotIndex = nil,
		OpeningStartedAt = nil,
		RolledReward = nil,
		TruckAnimated = false,
	} :: any)

	local createdOrExisting: ItemTypes.SpecialOrderRecord = record
	local okCommit, _, errCode, errMsg = commitOrdersMutation(userId, function(draft)
		if type(txId) == "string" and #txId > 0 and table.find(draft.ProcessedTxIds, txId) ~= nil then
			if #draft.SpecialOrders > 0 then
				createdOrExisting = draft.SpecialOrders[#draft.SpecialOrders]
			end
			return true, nil, nil
		end
		table.insert(draft.SpecialOrders, record)
		if type(txId) == "string" and #txId > 0 then
			table.insert(draft.ProcessedTxIds, txId)
		end
		return true, nil, nil
	end)

	if not okCommit then
		return false, nil, errCode, errMsg
	end

	emitOrdersUpdated(userId, "SpecialOrderCreated")
	return true, createdOrExisting, nil, nil
end

local function allNormalCratesOpened(order: ItemTypes.NormalOrderRecord): boolean
	for _, c in ipairs(order.Crates) do
		if c.Status ~= "Opened" then
			return false
		end
	end
	return true
end

function DeliveryService.OpenCrate(
	playerOrUserId: PlayerLike | number,
	crateOrOrderId: string
): (boolean, any?, string?, string?)
	local userId = extractUserId(playerOrUserId)
	if type(crateOrOrderId) ~= "string" or #crateOrOrderId == 0 then
		return false, nil, ShopProtocol.ErrorCodes.InvalidPayload, "CrateId inválido."
	end

	local okLoad, _, loadCode, loadMsg = DeliveryService.EnsurePlayerLoaded(userId)
	if not okLoad then
		return false, nil, loadCode, loadMsg
	end
	DeliveryService.ProcessArrivalsForUser(userId)

	local lockKey = `{userId}:{crateOrOrderId}`
	if _openingCrateLocks[lockKey] or _userLocks[userId] then
		return false, nil, ShopProtocol.ErrorCodes.OpeningInProgress, "Apertura de caja ya en progreso."
	end
	_openingCrateLocks[lockKey] = true
	_userLocks[userId] = true

	local function unlock()
		_openingCrateLocks[lockKey] = nil
		_userLocks[userId] = nil
	end

	local storage = _ordersByUserId[userId] :: ItemTypes.PlayerOrdersStorage

	-- 1) Buscar en cajas normales
	local targetNormalOrder: ItemTypes.NormalOrderRecord? = nil
	local targetCrate: ItemTypes.NormalOrderCrateRecord? = nil
	for _, o in ipairs(storage.NormalOrders) do
		for _, c in ipairs(o.Crates) do
			if c.CrateId == crateOrOrderId then
				targetNormalOrder = o
				targetCrate = c
				break
			end
		end
		if targetCrate then
			break
		end
	end

	if targetCrate and targetNormalOrder then
		if targetNormalOrder.Status == "InTransit" then
			unlock()
			return false, nil, ShopProtocol.ErrorCodes.OrderNotReady, "El pedido normal todavía está en camino."
		end
		if targetCrate.Status == "Opened" or targetCrate.CreditedToInventory then
			unlock()
			return false, nil, ShopProtocol.ErrorCodes.CrateAlreadyOpened, "Esta caja normal ya fue recogida."
		end

		local itemId = targetCrate.ItemId
		local qty = targetCrate.Quantity
		local okAdd, addCode, addMsg = InventoryService.AddItem(userId, itemId, qty)
		if not okAdd then
			unlock()
			return false, nil, addCode or ShopProtocol.ErrorCodes.PersistenceFailed, addMsg or "No se pudieron acreditar las piezas."
		end

		local now = _clockFn()
		local okCommit, _, commitCode, commitMsg = commitOrdersMutation(userId, function(draft)
			for _, o in ipairs(draft.NormalOrders) do
				if o.OrderId == targetNormalOrder.OrderId then
					for _, c in ipairs(o.Crates) do
						if c.CrateId == targetCrate.CrateId then
							c.Status = "Opened"
							c.SlotIndex = nil
							c.OpenedAt = now
							c.CreditedToInventory = true
							break
						end
					end
					if allNormalCratesOpened(o) then
						o.Status = "Collected"
					end
					break
				end
			end
			return true, nil, nil
		end)

		if not okCommit then
			-- Si no se pudo persistir el cierre de la caja, intentar revertir piezas acreditadas en memoria/DS para no duplicar
			-- (o permitir reintento manteniendo estado consistido)
			pcall(function()
				InventoryService.ConsumeForRollbackIfAvailable(userId, itemId, qty)
			end)
			unlock()
			return false, nil, commitCode or ShopProtocol.ErrorCodes.PersistenceFailed, commitMsg
		end

		clearSpawnedCrateModel(targetCrate.CrateId)
		emitCrateEffect(userId, {
			CrateId = targetCrate.CrateId,
			IsSpecial = false,
			ItemId = itemId,
			DisplayName = ItemCatalog.GetDisplayName(itemId),
			Quantity = qty,
		})
		DeliveryService.ReconcileDeliveryZoneForUser(userId)
		emitOrdersUpdated(userId, "NormalCrateOpened")
		unlock()

		return true, {
			IsSpecial = false,
			CrateId = targetCrate.CrateId,
			ItemId = itemId,
			DisplayName = ItemCatalog.GetDisplayName(itemId),
			Quantity = qty,
		}, nil, nil
	end

	-- 2) Buscar en cajas especiales
	local targetSpecial: ItemTypes.SpecialOrderRecord? = nil
	for _, o in ipairs(storage.SpecialOrders) do
		if o.OrderId == crateOrOrderId then
			targetSpecial = o
			break
		end
	end

	if not targetSpecial then
		unlock()
		return false, nil, ShopProtocol.ErrorCodes.CrateNotFound, "No se encontró la caja solicitada."
	end
	if targetSpecial.OwnerUserId ~= userId then
		unlock()
		return false, nil, ShopProtocol.ErrorCodes.CrateNotOwner, "No podés abrir una caja que pertenece a otro jugador."
	end
	if targetSpecial.Status == "InTransit" then
		unlock()
		return false, nil, ShopProtocol.ErrorCodes.OrderNotReady, "La caja especial todavía está en camino."
	end
	if targetSpecial.Status == "Claimed" then
		unlock()
		return false, nil, ShopProtocol.ErrorCodes.CrateAlreadyOpened, "Esta caja especial ya fue abierta y acreditada."
	end

	-- PASO CRÍTICO IDEMPOTENTE: si aún no hay sorteo registrado, sortear y PERSISTIR RolledReward antes de acreditar/animar.
	-- Ante un reintento posterior tras fallo intermedio, se reutiliza exactamente RolledReward sin repetir el sorteo.
	local rolledReward: ItemTypes.RolledLootReward? = targetSpecial.RolledReward
	if not rolledReward then
		local rollOk, freshRoll, rollCode, rollMsg = LootBoxService.RollRewardForOrder(targetSpecial.BoxId, _lootRngOverride)
		if not rollOk or not freshRoll then
			unlock()
			return false, nil, rollCode or ShopProtocol.ErrorCodes.InvalidPayload, rollMsg or "Error al sortear recompensa."
		end

		local okPersistRoll, _, rollSaveCode, rollSaveMsg = commitOrdersMutation(userId, function(draft)
			for _, o in ipairs(draft.SpecialOrders) do
				if o.OrderId == targetSpecial.OrderId then
					if o.RolledReward then
						-- Conservar resultado previo si ya existiera por concurrencia
						freshRoll = o.RolledReward
					else
						o.RolledReward = freshRoll
						o.Status = "Opened"
						o.OpeningStartedAt = _clockFn()
					end
					return true, nil, nil
				end
			end
			return false, ShopProtocol.ErrorCodes.OrderNotFound, "Pedido especial no encontrado."
		end)
		if not okPersistRoll then
			unlock()
			return false, nil, rollSaveCode or ShopProtocol.ErrorCodes.PersistenceFailed, rollSaveMsg
		end
		rolledReward = freshRoll
	end

	local reward = rolledReward :: ItemTypes.RolledLootReward
	-- Acreditar en InventoryService usando el mismo ItemInstanceId persistido (idempotente)
	local creditOk, unitRecord, creditCode, creditMsg
	if reward.Category == "Engines" then
		creditOk, unitRecord, creditCode, creditMsg = InventoryService.AddEngineUnit(userId, {
			ItemInstanceId = reward.ItemInstanceId,
			ItemId = reward.ItemId,
			EngineFamilyId = reward.FamilyId :: any,
			EngineSizeId = reward.SizeId :: any,
			VariantId = reward.VariantId :: any,
			RarityId = reward.RarityId :: any,
			SourceTag = "CrateDrop",
		})
	else
		creditOk, unitRecord, creditCode, creditMsg = InventoryService.AddBoosterUnit(userId, {
			ItemInstanceId = reward.ItemInstanceId,
			ItemId = reward.ItemId,
			BoosterFamilyId = reward.FamilyId :: any,
			BoosterSizeId = reward.SizeId :: any,
			VariantId = reward.VariantId :: any,
			RarityId = reward.RarityId :: any,
			SourceTag = "CrateDrop",
		})
	end

	if not creditOk or not unitRecord then
		unlock()
		return false, nil, creditCode or ShopProtocol.ErrorCodes.PersistenceFailed, creditMsg or "No se pudo acreditar la unidad al inventario."
	end

	local prevSlot = targetSpecial.SlotIndex
	local okClaimSave, _, claimCode, claimMsg = commitOrdersMutation(userId, function(draft)
		for _, o in ipairs(draft.SpecialOrders) do
			if o.OrderId == targetSpecial.OrderId then
				o.Status = "Claimed"
				o.SlotIndex = nil
				if o.RolledReward then
					o.RolledReward.CreditedToInventory = true
				end
				return true, nil, nil
			end
		end
		return false, ShopProtocol.ErrorCodes.OrderNotFound, "Pedido especial no encontrado."
	end)
	if not okClaimSave then
		unlock()
		return false, nil, claimCode or ShopProtocol.ErrorCodes.PersistenceFailed, claimMsg
	end

	clearSpawnedCrateModel(targetSpecial.OrderId)
	local plot = PlotService.GetPlotByPlayer({ UserId = userId, Name = "" })
	local revealModel = spawnRevealedSpecialUnitModel(userId, plot, prevSlot, reward)

	emitCrateEffect(userId, {
		CrateId = targetSpecial.OrderId,
		IsSpecial = true,
		BoxId = targetSpecial.BoxId,
		Reward = reward,
	})
	DeliveryService.ReconcileDeliveryZoneForUser(userId)
	emitOrdersUpdated(userId, "SpecialCrateOpened")
	unlock()

	return true, {
		IsSpecial = true,
		OrderId = targetSpecial.OrderId,
		BoxId = targetSpecial.BoxId,
		Reward = reward,
		Unit = unitRecord,
		RevealModel = revealModel,
	}, nil, nil
end

function DeliveryService.SetPendingRushOrder(playerOrUserId: PlayerLike | number, orderId: string?): boolean
	local userId = extractUserId(playerOrUserId)
	local okLoad = DeliveryService.EnsurePlayerLoaded(userId)
	if not okLoad then
		return false
	end
	local okCommit = commitOrdersMutation(userId, function(draft)
		draft.PendingRushOrderId = orderId
		return true, nil, nil
	end)
	return okCommit
end

function DeliveryService.AccelerateOrder(
	playerOrUserId: PlayerLike | number,
	orderId: string?,
	purchaseId: string?
): (boolean, any?, string?, string?)
	local userId = extractUserId(playerOrUserId)
	local okLoad, _, loadCode, loadMsg = DeliveryService.EnsurePlayerLoaded(userId)
	if not okLoad then
		return false, nil, loadCode, loadMsg
	end
	DeliveryService.ProcessArrivalsForUser(userId)

	local now = _clockFn()
	local targetArriveAt = now + ShopConfig.Orders.RobuxSpeedupArrivalSeconds
	local acceleratedOrder: any = nil

	local okCommit, _, commitCode, commitMsg = commitOrdersMutation(userId, function(draft)
		if type(purchaseId) == "string" and #purchaseId > 0 then
			for _, o in ipairs(draft.NormalOrders) do
				if o.RushPurchaseId == purchaseId then
					acceleratedOrder = o
					return true, nil, nil
				end
			end
			for _, o in ipairs(draft.SpecialOrders) do
				if o.RushPurchaseId == purchaseId then
					acceleratedOrder = o
					return true, nil, nil
				end
			end
		end

		local requestedId = orderId or draft.PendingRushOrderId
		local found: any = nil
		if type(requestedId) == "string" then
			for _, o in ipairs(draft.NormalOrders) do
				if o.OrderId == requestedId then
					found = o
					break
				end
			end
			if not found then
				for _, o in ipairs(draft.SpecialOrders) do
					if o.OrderId == requestedId then
						found = o
						break
					end
				end
			end
		end

		-- Fallback: primer pedido en tránsito si no se indicó id específico
		if not found then
			for _, o in ipairs(draft.NormalOrders) do
				if o.Status == "InTransit" then
					found = o
					break
				end
			end
			if not found then
				for _, o in ipairs(draft.SpecialOrders) do
					if o.Status == "InTransit" then
						found = o
						break
					end
				end
			end
		end

		if not found then
			return false, ShopProtocol.ErrorCodes.OrderNotFound, "No se encontró un pedido en tránsito para acelerar."
		end
		if found.Status ~= "InTransit" then
			return false, ShopProtocol.ErrorCodes.OrderAlreadyArrived, "El pedido ya llegó o fue completado."
		end

		local nextArriveAt = math.min(found.ArriveAt, targetArriveAt)
		found.ArriveAt = nextArriveAt
		if found.OrderType == "Special" then
			(found :: any).ReadyAt = nextArriveAt
		end
		found.RushedByRobux = true
		found.RushPurchaseId = purchaseId
		if draft.PendingRushOrderId == found.OrderId then
			draft.PendingRushOrderId = nil
		end
		acceleratedOrder = found
		return true, nil, nil
	end)

	if not okCommit then
		return false, nil, commitCode or ShopProtocol.ErrorCodes.PersistenceFailed, commitMsg
	end

	emitOrdersUpdated(userId, "OrderRushed")
	return true, acceleratedOrder, nil, nil
end

function DeliveryService.FindOrderForUser(playerOrUserId: PlayerLike | number, orderId: string): (any?, string?)
	local userId = extractUserId(playerOrUserId)
	local okLoad, storage = DeliveryService.EnsurePlayerLoaded(userId)
	if not okLoad or not storage then
		return nil, nil
	end
	for _, o in ipairs(storage.NormalOrders) do
		if o.OrderId == orderId then
			return o, "Normal"
		end
	end
	for _, o in ipairs(storage.SpecialOrders) do
		if o.OrderId == orderId then
			return o, "Special"
		end
	end
	return nil, nil
end

function DeliveryService.StepAll(nowOverride: number?)
	if not _initialized then
		return
	end
	local now = nowOverride or _clockFn()
	local userIds: { number } = {}
	for userId, _ in pairs(_ordersByUserId) do
		table.insert(userIds, userId)
	end
	for _, userId in ipairs(userIds) do
		DeliveryService.ProcessArrivalsForUser(userId)
	end

	-- Limpiar visuales temporales de recompensas ya expiradas (nunca elimina recompensas de inventario)
	for i = #_temporaryPropsToCleanup, 1, -1 do
		local entry = _temporaryPropsToCleanup[i]
		if now >= entry.ExpiresAt then
			table.remove(_temporaryPropsToCleanup, i)
			if entry.Model and entry.Model.Parent then
				entry.Model:Destroy()
			end
		end
	end
end

function DeliveryService.CleanupPlayerVisuals(playerOrUserId: PlayerLike | number)
	local userId = extractUserId(playerOrUserId)
	local storage = _ordersByUserId[userId]
	if storage then
		for _, o in ipairs(storage.NormalOrders) do
			for _, c in ipairs(o.Crates) do
				clearSpawnedCrateModel(c.CrateId)
			end
		end
		for _, o in ipairs(storage.SpecialOrders) do
			clearSpawnedCrateModel(o.OrderId)
		end
	end
	for i = #_temporaryPropsToCleanup, 1, -1 do
		if _temporaryPropsToCleanup[i].OwnerUserId == userId then
			if _temporaryPropsToCleanup[i].Model and _temporaryPropsToCleanup[i].Model.Parent then
				_temporaryPropsToCleanup[i].Model:Destroy()
			end
			table.remove(_temporaryPropsToCleanup, i)
		end
	end
	_ordersByUserId[userId] = nil
	_userLocks[userId] = nil
end

function DeliveryService.GetSpawnedCrateModel(crateId: string): Model?
	return _spawnedCrateModelsByCrateId[crateId]
end

function DeliveryService.RegisterOrdersUpdatedListener(cb: (userId: number, reason: string) -> ()): () -> ()
	table.insert(_ordersUpdatedListeners, cb)
	return function()
		local idx = table.find(_ordersUpdatedListeners, cb)
		if idx then
			table.remove(_ordersUpdatedListeners, idx)
		end
	end
end

function DeliveryService.RegisterTruckArrivingListener(cb: (userId: number, orderId: string, orderType: string) -> ()): () -> ()
	table.insert(_truckArrivingListeners, cb)
	return function()
		local idx = table.find(_truckArrivingListeners, cb)
		if idx then
			table.remove(_truckArrivingListeners, idx)
		end
	end
end

function DeliveryService.RegisterCrateEffectListener(cb: (userId: number, payload: { [string]: any }) -> ()): () -> ()
	table.insert(_crateEffectListeners, cb)
	return function()
		local idx = table.find(_crateEffectListeners, cb)
		if idx then
			table.remove(_crateEffectListeners, idx)
		end
	end
end

function DeliveryService._SetClockForTests(clockFn: (() -> number)?)
	_clockFn = clockFn or os.time
	LootBoxService._SetClockForTests(_clockFn)
end

function DeliveryService._SetLootRngForTests(rngFn: (() -> number)?)
	_lootRngOverride = rngFn
end

function DeliveryService._ResetForTests(preservePersistence: boolean?)
	if _heartbeatConn then
		_heartbeatConn:Disconnect()
		_heartbeatConn = nil
	end
	for crateId, m in pairs(_spawnedCrateModelsByCrateId) do
		if m and m.Parent then
			m:Destroy()
		end
		_spawnedCrateModelsByCrateId[crateId] = nil
	end
	for _, entry in ipairs(_temporaryPropsToCleanup) do
		if entry.Model and entry.Model.Parent then
			entry.Model:Destroy()
		end
	end
	table.clear(_temporaryPropsToCleanup)
	table.clear(_ordersByUserId)
	table.clear(_userLocks)
	table.clear(_openingCrateLocks)
	table.clear(_ordersUpdatedListeners)
	table.clear(_truckArrivingListeners)
	table.clear(_crateEffectListeners)
	_clockFn = os.time
	_lootRngOverride = nil
	_accumStep = 0
	if not preservePersistence then
		OrderPersistenceService._ResetForTests(true)
	end
	LootBoxService._ResetForTests()
	_initialized = false
	_started = false
end

function DeliveryService.Init()
	if _initialized then
		return
	end
	_initialized = true
	ensureCollisionGroupsRegistered()
	OrderPersistenceService.Init()
	LootBoxService.Init()

	Players.PlayerRemoving:Connect(function(player)
		DeliveryService.CleanupPlayerVisuals(player.UserId)
	end)
end

function DeliveryService.Start()
	if not _initialized then
		DeliveryService.Init()
	end
	if _started then
		return
	end
	_started = true
	OrderPersistenceService.Start()
	LootBoxService.Start()

	if _heartbeatConn then
		_heartbeatConn:Disconnect()
	end
	_heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
		_accumStep += dt
		if _accumStep >= 0.5 then
			_accumStep = 0
			DeliveryService.StepAll()
		end
	end)
end

return DeliveryService

