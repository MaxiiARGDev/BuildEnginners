--!strict
--[=[
	ItemRuntimeService
	Orquestador modular de comportamientos por pieza en VehicleRuntime.
	- Carga opcionalmente `Behaviors/<ModuleScript>` desde el modelo autorizado en ServerStorage.ItemAssets.
	- Valida identidad (ItemId registrado en ItemRegistry) y contrato del módulo (Init/Destroy).
	- Fase 1: no implementa simulación física ni bucles Heartbeat por pieza.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type BehaviorHandler = {
	Init: ((runtime: VehicleTypes.VehicleRuntime, partState: VehicleTypes.RuntimePartState, model: Model) -> ())?,
	Destroy: ((runtime: VehicleTypes.VehicleRuntime, partState: VehicleTypes.RuntimePartState, model: Model) -> ())?,
}

type ActiveBehaviorEntry = {
	PartState: VehicleTypes.RuntimePartState,
	Model: Model,
	Handler: BehaviorHandler,
}

local ItemRuntimeService = {
	Name = "ItemRuntimeService",
}

local _categoryHandlers: { [string]: BehaviorHandler } = {}
local _behaviorCache: { [string]: BehaviorHandler } = {}
local _activeByRuntime: { [string]: { [string]: ActiveBehaviorEntry } } = {}
local _itemAssetsRoot: Instance? = nil
local _initialized = false

local function validateHandlerContract(handler: any, sourceName: string): BehaviorHandler
	if type(handler) ~= "table" then
		error(`[ItemRuntimeService] Behavior '{sourceName}' must return a table`)
	end
	if handler.Init ~= nil and type(handler.Init) ~= "function" then
		error(`[ItemRuntimeService] Behavior '{sourceName}'.Init must be a function`)
	end
	if handler.Destroy ~= nil and type(handler.Destroy) ~= "function" then
		error(`[ItemRuntimeService] Behavior '{sourceName}'.Destroy must be a function`)
	end
	return handler :: BehaviorHandler
end

function ItemRuntimeService.Init(options: { ItemAssetsRoot: Instance? }?)
	if _initialized then
		return
	end
	_itemAssetsRoot = (options and options.ItemAssetsRoot) or ServerStorage:WaitForChild("ItemAssets")
	_initialized = true
end

function ItemRuntimeService.Start()
	if not _initialized then
		ItemRuntimeService.Init()
	end
end

function ItemRuntimeService.RegisterCategoryHandler(category: ItemTypes.ItemCategory, handler: BehaviorHandler)
	validateHandlerContract(handler, `Category:{category}`)
	_categoryHandlers[category] = handler
end

--[=[
	Resuelve el BehaviorHandler para un ItemId desde el modelo autorizado en ItemAssets
	o desde el manejador por categoría si no tiene módulo propio.
]=]
function ItemRuntimeService.ResolveHandler(itemId: string): BehaviorHandler?
	if not _initialized then
		ItemRuntimeService.Init()
	end

	local def = ItemRegistry.Get(itemId)

	if def.Behavior ~= nil then
		if _behaviorCache[def.Id] then
			return _behaviorCache[def.Id]
		end

		local root = _itemAssetsRoot
		if not root then
			error("[ItemRuntimeService] ItemAssetsRoot is not configured")
		end

		local assetModel = ItemRegistry.ResolveModel(root, def)
		local behaviorsFolder = assetModel and assetModel:FindFirstChild("Behaviors")
		local behaviorScript = behaviorsFolder and behaviorsFolder:FindFirstChild(def.Behavior)

		if not behaviorScript or not behaviorScript:IsA("ModuleScript") then
			error(`[ItemRuntimeService] Missing Behavior ModuleScript '{def.Behavior}' for '{def.Id}'`)
		end

		local ok, loaded = pcall(require, behaviorScript)
		if not ok then
			error(`[ItemRuntimeService] Failed to require Behavior '{def.Behavior}' for '{def.Id}': {tostring(loaded)}`)
		end

		local validated = validateHandlerContract(loaded, `{def.Id}/{def.Behavior}`)
		_behaviorCache[def.Id] = validated
		return validated
	end

	return _categoryHandlers[def.Category]
end

function ItemRuntimeService.InitPart(runtime: VehicleTypes.VehicleRuntime, partState: VehicleTypes.RuntimePartState, model: Model): boolean
	if not _initialized then
		ItemRuntimeService.Init()
	end

	local handler = ItemRuntimeService.ResolveHandler(partState.ItemId)
	if not handler then
		return false
	end

	local runtimeMap = _activeByRuntime[runtime.RuntimeId]
	if not runtimeMap then
		runtimeMap = {}
		_activeByRuntime[runtime.RuntimeId] = runtimeMap
	end

	if runtimeMap[partState.PieceInstanceId] then
		error(`[ItemRuntimeService] Duplicate PartInstanceId '{partState.PieceInstanceId}' in runtime '{runtime.RuntimeId}'`)
	end

	if handler.Init then
		handler.Init(runtime, partState, model)
	end

	runtimeMap[partState.PieceInstanceId] = {
		PartState = partState,
		Model = model,
		Handler = handler,
	}

	return true
end

function ItemRuntimeService.DestroyPart(runtime: VehicleTypes.VehicleRuntime, partState: VehicleTypes.RuntimePartState, model: Model): boolean
	local runtimeMap = _activeByRuntime[runtime.RuntimeId]
	if not runtimeMap then
		return false
	end

	local entry = runtimeMap[partState.PieceInstanceId]
	if not entry then
		return false
	end

	runtimeMap[partState.PieceInstanceId] = nil
	if entry.Handler.Destroy then
		entry.Handler.Destroy(runtime, partState, model)
	end

	return true
end

function ItemRuntimeService.DestroyRuntime(runtime: VehicleTypes.VehicleRuntime): number
	local runtimeMap = _activeByRuntime[runtime.RuntimeId]
	if not runtimeMap then
		return 0
	end

	local count = 0
	for _, entry in pairs(runtimeMap) do
		count += 1
		if entry.Handler.Destroy then
			entry.Handler.Destroy(runtime, entry.PartState, entry.Model)
		end
	end

	_activeByRuntime[runtime.RuntimeId] = nil
	return count
end

function ItemRuntimeService.GetActivePartCount(runtimeId: string): number
	local runtimeMap = _activeByRuntime[runtimeId]
	if not runtimeMap then
		return 0
	end
	local count = 0
	for _ in pairs(runtimeMap) do
		count += 1
	end
	return count
end

function ItemRuntimeService._ResetForTests()
	table.clear(_categoryHandlers)
	table.clear(_behaviorCache)
	table.clear(_activeByRuntime)
	_itemAssetsRoot = nil
	_initialized = false
end

return ItemRuntimeService

