--!strict
--[=[
	Bootstrap.server.lua
	Punto de entrada centralizado del servidor (Fase 1).
	- Inicializa ItemRegistry y valida todos los modelos/atributos de ItemAssets.
	- Carga e inicializa servicios en orden controlado (Init -> Start) con manejo de errores.
	- No contiene lógica de gameplay.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local ShopGuiSchema = require(ReplicatedStorage.Shared.UI.ShopGuiSchema)

local ServicesFolder = ServerScriptService.Server:WaitForChild("Services")

export type ServiceModule = {
	Name: string,
	Init: ((options: any?) -> ())?,
	Start: (() -> ())?,
}

local SERVICE_LOAD_ORDER = {
	"PlotService",
	"SpawnService",
	"PreviewAssetService",
	"InventoryPersistenceService",
	"InventoryService",
	"EconomyPersistenceService",
	"EconomyService",
	"EngineInventoryService",
	"BoosterInventoryService",
	"WheelAutoConfigurationService",
	"ConnectionService",
	"VehicleAssemblyService",
	"BlueprintPersistenceService",
	"VehicleBlueprintService",
	"StandPreviewService",
	"VehicleLaunchPreparationService",
	"ItemRuntimeService",
	"VehicleWheelControllerService",
	"VehiclePowertrainService",
	"VehicleBoosterService",
	"AerodynamicsService",
	"VehicleDamageService",
	"VehicleImpactService",
	"VehicleSeatService",
	"VehicleDestructionService",
	"VehicleRuntimeService",
	"VehicleLifecycleService",
	"VehicleLaunchService",
	"BuildService",
	"OrderPersistenceService",
	"GameConfigService",
	"ShopStockService",
	"LootBoxService",
	"DeliveryService",
	"OfflineIncomeService",
	"ShopService",
}

local function runStep(stepName: string, fn: () -> ())
	local ok, err = xpcall(fn, debug.traceback)
	if not ok then
		error(`[Bootstrap] Failed during '{stepName}':\n{tostring(err)}`, 0)
	end
end

local function loadServices(): { ServiceModule }
	local loaded: { ServiceModule } = {}
	for _, serviceName in ipairs(SERVICE_LOAD_ORDER) do
		local moduleScript = ServicesFolder:FindFirstChild(serviceName)
		if not moduleScript or not moduleScript:IsA("ModuleScript") then
			error(`[Bootstrap] Missing service ModuleScript '{serviceName}'`)
		end
		local service = require(moduleScript) :: ServiceModule
		if type(service) ~= "table" or type(service.Name) ~= "string" then
			error(`[Bootstrap] Service '{serviceName}' must return a table with Name`)
		end
		table.insert(loaded, service)
	end
	return loaded
end

local function main()
	-- 1. Catálogo centralizado e inmutable y verificación de StarterGui.ShopGui
	runStep("ItemRegistry.Init", function()
		ItemRegistry.Init()
		ShopGuiSchema.EnsureStarterGui()
	end)

	-- 2. Normalización y validación de modelos/atributos/comportamientos en ServerStorage.ItemAssets
	runStep("ItemRegistry.ValidateAssets", function()
		local itemAssets = ServerStorage:WaitForChild("ItemAssets")
		ItemRegistry.NormalizeAssets(itemAssets)
		local result = ItemRegistry.ValidateAssets(itemAssets)
		if not result.Valid then
			error("Asset validation failed:\n - " .. table.concat(result.Errors, "\n - "))
		end
		print(`[Bootstrap] ItemRegistry validated {#ItemRegistry.GetAll()} definitions and {result.CheckedCount} asset models.`)
	end)

	-- 3. Carga de servicios en orden controlado
	local services = loadServices()

	-- 4. Fase Init
	for _, service in ipairs(services) do
		if service.Init then
			runStep(`{service.Name}.Init`, function()
				service.Init(nil)
			end)
		end
	end

	-- 5. Fase Start
	for _, service in ipairs(services) do
		if service.Start then
			runStep(`{service.Name}.Start`, function()
				service.Start()
			end)
		end
	end

	ReplicatedStorage:SetAttribute("ServerBootstrapReady", true)
	print(`[Bootstrap] Phase 1 server initialization complete ({#services} services).`)
end

main()

