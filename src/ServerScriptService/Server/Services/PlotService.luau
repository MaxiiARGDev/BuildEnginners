--!strict
--[=[
	PlotService
	Gestiona las 10 estaciones exclusivas clonadas desde ServerStorage.BaseTemplate
	y posicionadas usando los puntos físicos editables en Workspace.PlotSpawns (Plot_01..Plot_10).
	- Sin coordenadas hardcodeadas ni rutas rígidas.
	- Posicionamiento mediante Model:PivotTo() respecto a PlotOrigin.
	- Limpieza exclusiva de DynamicRuntime al liberar una estación, preservando geometría y decoraciones permanentes.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

export type PlayerLike = Player | {
	UserId: number,
	Name: string,
}

export type PlotZones = {
	BuildZone: BasePart,
	LaunchPoint: BasePart,
	ShopZone: BasePart,
	DeliveryZone: BasePart,
	StandZone: BasePart,
}

export type PlotRecord = {
	PlotId: string,
	SlotIndex: number,
	Model: Model,
	PlotOrigin: BasePart,
	PlayerSpawn: BasePart,
	Zones: PlotZones,
	DynamicContainer: Folder,
	ShopDeliveryContainer: Folder,
	VehicleStand: Model?,
	StandDisplayAnchor: BasePart?,
	StandInteractionPoint: BasePart?,
	OwnerUserId: number?,
	OwnerName: string?,
}

export type InitOptions = {
	BaseTemplate: Model?,
	PlotSpawnsFolder: Instance?,
	PlotsParent: Instance?,
	PlotCount: number?,
}

local PlotService = {
	Name = "PlotService",
}

local _plotsById: { [string]: PlotRecord } = {}
local _plotsOrdered: { PlotRecord } = {}
local _plotIdByUserId: { [number]: string } = {}
local _assignedListeners: { (player: PlayerLike, record: PlotRecord) -> () } = {}
local _releasedListeners: { (player: PlayerLike, record: PlotRecord?) -> () } = {}
local _initialized = false
local _started = false
local _connections: { RBXScriptConnection } = {}

local function resolveZones(plotModel: Model): PlotZones
	local found: { [string]: BasePart } = {}
	for _, descendant in ipairs(plotModel:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local zoneId = descendant:GetAttribute(GameConfig.PlotAttributes.ZoneId)
			if type(zoneId) == "string" and zoneId ~= "" then
				found[zoneId] = descendant
			elseif GameConfig.ZoneIds[descendant.Name] ~= nil and found[descendant.Name] == nil then
				found[descendant.Name] = descendant
			end
		end
	end

	local requiredZones = {
		GameConfig.ZoneIds.BuildZone,
		GameConfig.ZoneIds.LaunchPoint,
		GameConfig.ZoneIds.ShopZone,
		GameConfig.ZoneIds.DeliveryZone,
		GameConfig.ZoneIds.StandZone,
	}

	for _, zoneKey in ipairs(requiredZones) do
		if not found[zoneKey] then
			error(`[PlotService] BaseTemplate/Plot '{plotModel.Name}' is missing zone '{zoneKey}'`)
		end
	end

	return {
		BuildZone = found[GameConfig.ZoneIds.BuildZone],
		LaunchPoint = found[GameConfig.ZoneIds.LaunchPoint],
		ShopZone = found[GameConfig.ZoneIds.ShopZone],
		DeliveryZone = found[GameConfig.ZoneIds.DeliveryZone],
		StandZone = found[GameConfig.ZoneIds.StandZone],
	}
end

local function resolvePlotOrigin(model: Model): BasePart
	local origin = model:FindFirstChild(GameConfig.PlotContainers.PlotOrigin)
	if not origin or not origin:IsA("BasePart") then
		error(`[PlotService] '{model.Name}' must contain a BasePart named '{GameConfig.PlotContainers.PlotOrigin}'`)
	end
	return origin
end

local function resolvePlayerSpawn(model: Model): BasePart
	local spawnPart = model:FindFirstChild(GameConfig.PlotContainers.PlayerSpawn)
	if not spawnPart or not spawnPart:IsA("BasePart") then
		error(`[PlotService] '{model.Name}' must contain a BasePart named '{GameConfig.PlotContainers.PlayerSpawn}'`)
	end
	return spawnPart
end

local function resolveVehicleStandRefs(model: Model, standZone: BasePart): (Model?, BasePart?, BasePart?)
	local standInst = model:FindFirstChild(GameConfig.PlotContainers.VehicleStand)
	if not standInst or not standInst:IsA("Model") then
		return nil, standZone, nil
	end
	local anchorInst = standInst:FindFirstChild(GameConfig.PlotContainers.DisplayAnchor, true)
	local anchorPart: BasePart? = if anchorInst and anchorInst:IsA("BasePart") then anchorInst else standZone
	local interactInst = standInst:FindFirstChild(GameConfig.PlotContainers.InteractionPoint, true)
	local interactPart: BasePart? = if interactInst and interactInst:IsA("BasePart") then interactInst else nil
	return standInst, anchorPart, interactPart
end

local function resolveSpawnParts(spawnsFolder: Instance, expectedCount: number): { BasePart }
	local spawns: { BasePart } = {}
	for _, child in ipairs(spawnsFolder:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(spawns, child)
		end
	end

	table.sort(spawns, function(a, b)
		return a.Name < b.Name
	end)

	if #spawns < expectedCount then
		error(`[PlotService] '{spawnsFolder.Name}' must contain at least {expectedCount} spawn BaseParts, found {#spawns}`)
	end

	local selected: { BasePart } = {}
	for i = 1, expectedCount do
		table.insert(selected, spawns[i])
	end
	return selected
end

local function getOrCreatePlotsFolder(plotsParent: Instance?): Folder
	local parent = plotsParent or Workspace
	local existing = parent:FindFirstChild("Plots")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Plots"
	folder.Parent = parent
	return folder
end

local function cleanupDynamicRuntime(record: PlotRecord)
	-- Limpia únicamente el contenido temporal de DynamicRuntime y props de tienda/entrega sin tocar geometría permanente
	record.DynamicContainer:ClearAllChildren()
	if record.ShopDeliveryContainer then
		record.ShopDeliveryContainer:ClearAllChildren()
	end
end

function PlotService.Init(options: InitOptions?)
	if _initialized then
		return
	end

	local template: Model
	if options and options.BaseTemplate then
		template = options.BaseTemplate
	else
		local found = ServerStorage:WaitForChild("BaseTemplate")
		if not found:IsA("Model") then
			error("[PlotService] ServerStorage.BaseTemplate must be a Model")
		end
		template = found
	end

	local templateOrigin = resolvePlotOrigin(template)
	-- Validar zonas y PlayerSpawn de la plantilla antes de clonar
	resolvePlayerSpawn(template)
	resolveZones(template)

	-- Offset entre el pivote actual de BaseTemplate y su PlotOrigin para posicionar con precisión vía PivotTo
	local templatePivotToOrigin = template:GetPivot():ToObjectSpace(templateOrigin.CFrame)

	local spawnsFolder: Instance
	if options and options.PlotSpawnsFolder then
		spawnsFolder = options.PlotSpawnsFolder
	else
		spawnsFolder = Workspace:WaitForChild(GameConfig.PlotContainers.PlotSpawns)
	end

	local count = (options and options.PlotCount) or GameConfig.PlotCount
	local spawnParts = resolveSpawnParts(spawnsFolder, count)

	local plotsFolder = getOrCreatePlotsFolder(options and options.PlotsParent)
	plotsFolder:ClearAllChildren()

	table.clear(_plotsById)
	table.clear(_plotsOrdered)
	table.clear(_plotIdByUserId)

	for slotIndex, spawnPart in ipairs(spawnParts) do
		local plotId = spawnPart.Name
		local clone = template:Clone()
		clone.Name = plotId
		clone:SetAttribute(GameConfig.PlotAttributes.PlotId, plotId)
		clone:SetAttribute(GameConfig.PlotAttributes.SlotIndex, slotIndex)
		clone:SetAttribute(GameConfig.PlotAttributes.OwnerUserId, 0)

		local targetPivot = spawnPart.CFrame * templatePivotToOrigin:Inverse()
		clone:PivotTo(targetPivot)

		local dynamicContainer = clone:FindFirstChild(GameConfig.PlotContainers.Dynamic)
		if not dynamicContainer or not dynamicContainer:IsA("Folder") then
			local folder = Instance.new("Folder")
			folder.Name = GameConfig.PlotContainers.Dynamic
			folder.Parent = clone
			dynamicContainer = folder
		end

		local shopDeliveryContainer = clone:FindFirstChild("ShopDeliveryProps")
		if not shopDeliveryContainer or not shopDeliveryContainer:IsA("Folder") then
			local folder = Instance.new("Folder")
			folder.Name = "ShopDeliveryProps"
			folder.Parent = clone
			shopDeliveryContainer = folder
		end

		clone.Parent = plotsFolder

		local resolvedZones = resolveZones(clone)
		local standModel, displayAnchor, interactionPoint = resolveVehicleStandRefs(clone, resolvedZones.StandZone)

		local record: PlotRecord = {
			PlotId = plotId,
			SlotIndex = slotIndex,
			Model = clone,
			PlotOrigin = resolvePlotOrigin(clone),
			PlayerSpawn = resolvePlayerSpawn(clone),
			Zones = resolvedZones,
			DynamicContainer = dynamicContainer :: Folder,
			ShopDeliveryContainer = shopDeliveryContainer :: Folder,
			VehicleStand = standModel,
			StandDisplayAnchor = displayAnchor,
			StandInteractionPoint = interactionPoint,
			OwnerUserId = nil,
			OwnerName = nil,
		}

		_plotsById[plotId] = record
		table.insert(_plotsOrdered, record)
	end

	_initialized = true
end

function PlotService.Start()
	if _started then
		return
	end
	if not _initialized then
		PlotService.Init()
	end

	for _, player in ipairs(Players:GetPlayers()) do
		PlotService.Assign(player)
	end

	table.insert(
		_connections,
		Players.PlayerAdded:Connect(function(player)
			PlotService.Assign(player)
		end)
	)

	table.insert(
		_connections,
		Players.PlayerRemoving:Connect(function(player)
			PlotService.Release(player)
		end)
	)

	_started = true
end

function PlotService.Assign(player: PlayerLike): (PlotRecord?, string?)
	if not _initialized then
		error("[PlotService] Not initialized")
	end

	local existingPlotId = _plotIdByUserId[player.UserId]
	if existingPlotId then
		return _plotsById[existingPlotId], nil
	end

	for _, record in ipairs(_plotsOrdered) do
		if record.OwnerUserId == nil then
			record.OwnerUserId = player.UserId
			record.OwnerName = player.Name
			record.Model:SetAttribute(GameConfig.PlotAttributes.OwnerUserId, player.UserId)
			if typeof(player) == "Instance" and (player :: Instance):IsA("Player") then
				(player :: Player):SetAttribute(GameConfig.PlotAttributes.PlotId, record.PlotId)
			end
			_plotIdByUserId[player.UserId] = record.PlotId
			for _, listener in ipairs(table.clone(_assignedListeners)) do
				task.spawn(listener, player, record)
			end
			return record, nil
		end
	end

	return nil, "NoFreePlot"
end

function PlotService.Release(player: PlayerLike): boolean
	local plotId = _plotIdByUserId[player.UserId]
	if not plotId then
		return false
	end

	local record = _plotsById[plotId]
	_plotIdByUserId[player.UserId] = nil

	if record then
		cleanupDynamicRuntime(record)
		record.OwnerUserId = nil
		record.OwnerName = nil
		record.Model:SetAttribute(GameConfig.PlotAttributes.OwnerUserId, 0)
	end
	if typeof(player) == "Instance" and (player :: Instance):IsA("Player") then
		(player :: Player):SetAttribute(GameConfig.PlotAttributes.PlotId, nil)
	end

	for _, listener in ipairs(table.clone(_releasedListeners)) do
		task.spawn(listener, player, record)
	end

	return true
end

function PlotService.GetPlotByPlayer(player: PlayerLike): PlotRecord?
	local plotId = _plotIdByUserId[player.UserId]
	if not plotId then
		return nil
	end
	return _plotsById[plotId]
end

function PlotService.GetPlayerSpawn(player: PlayerLike): BasePart?
	local record = PlotService.GetPlotByPlayer(player)
	if not record then
		return nil
	end
	return record.PlayerSpawn
end

function PlotService.OnPlotAssigned(callback: (player: PlayerLike, record: PlotRecord) -> ()): () -> ()
	table.insert(_assignedListeners, callback)
	return function()
		local idx = table.find(_assignedListeners, callback)
		if idx then
			table.remove(_assignedListeners, idx)
		end
	end
end

function PlotService.OnPlotReleased(callback: (player: PlayerLike, record: PlotRecord?) -> ()): () -> ()
	table.insert(_releasedListeners, callback)
	return function()
		local idx = table.find(_releasedListeners, callback)
		if idx then
			table.remove(_releasedListeners, idx)
		end
	end
end

function PlotService.GetPlotById(plotId: string): PlotRecord?
	return _plotsById[plotId]
end

function PlotService.GetZone(plotId: string, zoneId: string): BasePart?
	local record = _plotsById[plotId]
	if not record then
		return nil
	end
	return (record.Zones :: { [string]: BasePart })[zoneId]
end

function PlotService.IsOwner(player: PlayerLike, plotId: string): boolean
	local record = _plotsById[plotId]
	return record ~= nil and record.OwnerUserId == player.UserId
end

function PlotService.GetAllPlots(): { PlotRecord }
	return table.clone(_plotsOrdered)
end

function PlotService.GetFreePlotCount(): number
	local free = 0
	for _, record in ipairs(_plotsOrdered) do
		if record.OwnerUserId == nil then
			free += 1
		end
	end
	return free
end

--[=[
	Solo para pruebas aisladas: reinicia el estado interno de PlotService.
]=]
function PlotService._ResetForTests()
	for _, conn in ipairs(_connections) do
		conn:Disconnect()
	end
	table.clear(_connections)
	for _, record in ipairs(_plotsOrdered) do
		record.Model:Destroy()
	end
	table.clear(_plotsById)
	table.clear(_plotsOrdered)
	table.clear(_plotIdByUserId)
	table.clear(_assignedListeners)
	table.clear(_releasedListeners)
	_initialized = false
	_started = false
end

return PlotService
