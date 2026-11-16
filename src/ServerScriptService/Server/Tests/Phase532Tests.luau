--!strict
--[=[
	Phase532Tests
	Suite automatizada de validación para la Fase 5.3.2:
	Unificación de Cajas Especiales y Progresión Individual (StarterGui.ShopGui).
	Cubre los 18 puntos obligatorios de verificación de la Sección 10:
	  [01] Una sola pestaña principal 'Cajas de motores' y barra secundaria CrateFamilyFilterBar en StarterGui.ShopGui.
	  [02] Los 4 filtros secundarios (Todas, Vehículos, Propulsores, Aviones) existen y están configurados.
	  [03] Cada filtro muestra exclusivamente las cajas de su familia y ordenadas por ProgressionOrder.
	  [04] No aparece ningún motor ni propulsor individual como producto comprable en tienda.
	  [05] Cada caja conserva su precio real y estado de habilitación.
	  [06] Cada caja tiene su propio DeliverySeconds autoritativo por BoxId (120s vs 900s, etc.).
	  [07] Stock y RestockIntervalSeconds independientes por BoxId (StockMin, StockMax, CurrentStock).
	  [08] El restock reemplaza existencias sin acumular el stock sobrante.
	  [09] ReadyAt / ArriveAt persistente calculado al comprar (inmune a cambios posteriores de DeliverySeconds).
	  [10] Los pedidos continúan avanzando mientras el jugador está desconectado.
	  [11] Compras simultáneas de la última unidad no sobrevenden el stock (solo 1 ganador, 0 negativo).
	  [12] Las probabilidades reales de recompensa (55/25/12/5/2.5/0.5% y 70/25/5%, 18 niveles = 100%) permanecen intactas.
	  [13] El carrito de componentes normales (100+ unidades, 60s espera) sigue funcionando.
	  [14] Los componentes normales mantienen stock ilimitado (ShopStockService solo gestiona LootBoxes).
	  [15] StarterGui.ShopGui sigue siendo editable visualmente en Studio.
	  [16] Compatibilidad automática con cajas futuras de Aviones (RewardCategory = AircraftEngines).
	  [17] Ninguna tarjeta desborda textos ni oculta precios, tiempos o botones de compra/información.
	  [18] BaseTemplate conserva exactamente sus 25 descendientes.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local ShopGuiSchema = require(ReplicatedStorage.Shared.UI.ShopGuiSchema)
local ShopStatsResolver = require(ReplicatedStorage.Shared.UI.ShopStatsResolver)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local AerodynamicsService = require(ServerScriptService.Server.Services.AerodynamicsService)
local BlueprintPersistenceService = require(ServerScriptService.Server.Services.BlueprintPersistenceService)
local BoosterInventoryService = require(ServerScriptService.Server.Services.BoosterInventoryService)
local BuildService = require(ServerScriptService.Server.Services.BuildService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local DeliveryService = require(ServerScriptService.Server.Services.DeliveryService)
local EconomyPersistenceService = require(ServerScriptService.Server.Services.EconomyPersistenceService)
local EconomyService = require(ServerScriptService.Server.Services.EconomyService)
local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local InventoryPersistenceService = require(ServerScriptService.Server.Services.InventoryPersistenceService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local ItemRuntimeService = require(ServerScriptService.Server.Services.ItemRuntimeService)
local LootBoxService = require(ServerScriptService.Server.Services.LootBoxService)
local OfflineIncomeService = require(ServerScriptService.Server.Services.OfflineIncomeService)
local OrderPersistenceService = require(ServerScriptService.Server.Services.OrderPersistenceService)
local PlotService = require(ServerScriptService.Server.Services.PlotService)
local PreviewAssetService = require(ServerScriptService.Server.Services.PreviewAssetService)
local ShopService = require(ServerScriptService.Server.Services.ShopService)
local ShopStockService = require(ServerScriptService.Server.Services.ShopStockService)
local SpawnService = require(ServerScriptService.Server.Services.SpawnService)
local StandPreviewService = require(ServerScriptService.Server.Services.StandPreviewService)
local VehicleAssemblyService = require(ServerScriptService.Server.Services.VehicleAssemblyService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local VehicleBoosterService = require(ServerScriptService.Server.Services.VehicleBoosterService)
local VehicleDamageService = require(ServerScriptService.Server.Services.VehicleDamageService)
local VehicleDestructionService = require(ServerScriptService.Server.Services.VehicleDestructionService)
local VehicleImpactService = require(ServerScriptService.Server.Services.VehicleImpactService)
local VehicleLaunchPreparationService = require(ServerScriptService.Server.Services.VehicleLaunchPreparationService)
local VehicleLaunchService = require(ServerScriptService.Server.Services.VehicleLaunchService)
local VehicleLifecycleService = require(ServerScriptService.Server.Services.VehicleLifecycleService)
local VehiclePowertrainService = require(ServerScriptService.Server.Services.VehiclePowertrainService)
local VehicleRuntimeService = require(ServerScriptService.Server.Services.VehicleRuntimeService)
local VehicleSeatService = require(ServerScriptService.Server.Services.VehicleSeatService)
local VehicleWheelControllerService = require(ServerScriptService.Server.Services.VehicleWheelControllerService)
local WheelAutoConfigurationService = require(ServerScriptService.Server.Services.WheelAutoConfigurationService)

local ClientControllers = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState") :: ModuleScript)
local BuildPlacementController = require(ClientControllers:WaitForChild("BuildPlacementController") :: ModuleScript)
local BuildPreviewController = require(ClientControllers:WaitForChild("BuildPreviewController") :: ModuleScript)

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase532Tests = {}

local function assertTrue(cond: any, msg: string)
	if not cond then
		error(msg, 2)
	end
end

local function assertEqual(actual: any, expected: any, msg: string)
	if actual ~= expected then
		error(`{msg} (expected '{tostring(expected)}', got '{tostring(actual)}')`, 2)
	end
end

local function resetAllServices(preservePersistence: boolean)
	LootBoxConfig._ClearOverridesForTests()
	BuildService._ResetForTests()
	ShopService._ResetForTests()
	OfflineIncomeService._ResetForTests()
	DeliveryService._ResetForTests(preservePersistence)
	ShopStockService._ResetForTests()
	EconomyService._ResetForTests(preservePersistence)
	AerodynamicsService._ResetForTests()
	VehicleLaunchService._ResetForTests()
	VehicleLifecycleService._ResetForTests()
	VehicleRuntimeService._ResetForTests()
	VehicleSeatService._ResetForTests()
	VehicleDestructionService._ResetForTests()
	VehicleImpactService._ResetForTests()
	VehicleDamageService._ResetForTests()
	VehicleBoosterService._ResetForTests()
	VehiclePowertrainService._ResetForTests()
	VehicleWheelControllerService._ResetForTests()
	VehicleAssemblyService._ResetForTests()
	ItemRuntimeService._ResetForTests()
	VehicleLaunchPreparationService._ResetForTests()
	StandPreviewService._ResetForTests()
	VehicleBlueprintService._ResetForTests(preservePersistence)
	InventoryService._ResetForTests(preservePersistence, { AutoGrantLegacySuiteQuota = false })
	if not preservePersistence then
		BlueprintPersistenceService._ResetForTests(true)
		InventoryPersistenceService._ResetForTests(true)
		EconomyPersistenceService._ResetForTests(true)
		OrderPersistenceService._ResetForTests(true)
	else
		BlueprintPersistenceService._SetSimulateWriteFailureForTests(false)
		BlueprintPersistenceService._SetSimulateLoadFailureForTests(false)
		InventoryPersistenceService._SetSimulateWriteFailureForTests(false)
		InventoryPersistenceService._SetSimulateLoadFailureForTests(false)
		EconomyPersistenceService._SetSimulateWriteFailureForTests(false)
		EconomyPersistenceService._SetSimulateLoadFailureForTests(false)
		OrderPersistenceService._SetSimulateWriteFailureForTests(false)
		OrderPersistenceService._SetSimulateLoadFailureForTests(false)
	end
	ConnectionService._ResetForTests()
	WheelAutoConfigurationService._ResetForTests()
	PreviewAssetService._ResetForTests()
	SpawnService._ResetForTests()
	PlotService._ResetForTests()
	BuildState.Reset()
	BuildPlacementController.ClearPending()
	BuildPreviewController._ClearGeometryCacheForTests()
	BuildPreviewController.InvalidateWorkshopCaches()
	BuildPreviewController.DestroyGhost()
end

local function initAllServices(tempPlots: Folder, plotCount: number?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
	local assets = ServerStorage:WaitForChild("ItemAssets")

	ItemRegistry.Init()
	PlotService.Init({
		BaseTemplate = baseTemplate,
		PlotSpawnsFolder = plotSpawns,
		PlotsParent = tempPlots,
		PlotCount = plotCount or 3,
	})
	SpawnService.Init()
	PreviewAssetService.Init({ ItemAssetsRoot = assets, TargetParent = ReplicatedStorage })
	InventoryPersistenceService.Init()
	InventoryService.Init()
	EconomyPersistenceService.Init()
	EconomyService.Init()
	EngineInventoryService.Init()
	BoosterInventoryService.Init()
	WheelAutoConfigurationService.Init({ ItemAssetsRoot = assets })
	ConnectionService.Init({ ItemAssetsRoot = assets })
	VehicleAssemblyService.Init({ ItemAssetsRoot = assets })
	BlueprintPersistenceService.Init()
	VehicleBlueprintService.Init({ ItemAssetsRoot = assets })
	StandPreviewService.Init({ ItemAssetsRoot = assets })
	VehicleLaunchPreparationService.Init({ ItemAssetsRoot = assets })
	ItemRuntimeService.Init({ ItemAssetsRoot = assets })
	VehicleWheelControllerService.Init()
	VehiclePowertrainService.Init()
	VehicleBoosterService.Init()
	AerodynamicsService.Init()
	VehicleDamageService.Init()
	VehicleImpactService.Init()
	VehicleDestructionService.Init()
	VehicleSeatService.Init()
	VehicleRuntimeService.Init()
	VehicleLifecycleService.Init()
	VehicleLaunchService.Init()
	BuildService.Init()
	OrderPersistenceService.Init()
	ShopStockService.Init()
	LootBoxService.Init()
	DeliveryService.Init()
	OfflineIncomeService.Init()
	ShopService.Init()
end

local function setupIsolatedWorld(plotCount: number?)
	local existing = Workspace:FindFirstChild("_Phase532TestPlots")
	if existing then
		existing:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase532TestPlots"
	tempPlots.Parent = Workspace

	local virtualClock = 532000
	local rateClock = 532000

	local function bindClocks()
		local clockFn = function()
			return virtualClock
		end
		BuildService._SetRateLimitClockForTests(function()
			rateClock += 1.0
			return rateClock
		end)
		ShopService._SetClockForTests(clockFn)
		DeliveryService._SetClockForTests(clockFn)
		ShopStockService._SetClockForTests(clockFn)
		EconomyService._SetClockForTests(clockFn)
		OfflineIncomeService._SetClockForTests(clockFn)
		LootBoxService._SetClockForTests(clockFn)
	end

	resetAllServices(false)
	initAllServices(tempPlots, plotCount)
	bindClocks()
	ShopStockService.ExecuteRestock("TestInit")

	return {
		GetNow = function(): number
			return virtualClock
		end,
		AdvanceClock = function(seconds: number): number
			virtualClock += math.max(0, math.floor(seconds))
			DeliveryService.StepAll(virtualClock)
			ShopStockService.StepRestockCheck()
			return virtualClock
		end,
		SimulateRejoin = function(offlineSeconds: number?)
			if offlineSeconds and offlineSeconds > 0 then
				virtualClock += offlineSeconds
			end
			resetAllServices(true)
			for _, child in ipairs(tempPlots:GetChildren()) do
				child:Destroy()
			end
			initAllServices(tempPlots, plotCount)
			bindClocks()
		end,
		Teardown = function()
			resetAllServices(false)
			if tempPlots.Parent then
				tempPlots:Destroy()
			end
		end,
	}
end

local function indexStockSnapshots(): { [string]: any }
	local byId: { [string]: any } = {}
	for _, entry in ipairs(ShopStockService.GetAllStockSnapshots()) do
		byId[entry.BoxId] = entry
	end
	return byId
end

local function patchBoxForTest(boxId: string, patches: { [string]: any }): LootBoxConfig.LootBoxDefinition
	LootBoxConfig._ClearOverridesForTests()
	local baseDef = LootBoxConfig.GetBox(boxId)
	if not baseDef then
		error(`Missing base box '{boxId}' for test override`, 2)
	end
	local cloned = table.clone(baseDef :: any)
	for k, v in pairs(patches) do
		cloned[k] = v
	end
	LootBoxConfig._SetBoxOverrideForTests(boxId, cloned)
	return cloned
end

function Phase532Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (name: string, fn: () -> ()) -> ()
)
	-- [01] Una sola pestaña principal de cajas + CrateFamilyFilterBar editable
	runTest("Fase 5.3.2 [01]: Unified 'Cajas de motores' top category and editable CrateFamilyFilterBar in StarterGui.ShopGui", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local mainFrame = sg:FindFirstChild("MainFrame") :: Frame
		assertTrue(mainFrame ~= nil, "MainFrame exists")

		local catTabs = mainFrame:FindFirstChild("CategoryTabs") :: ScrollingFrame
		assertTrue(catTabs ~= nil and catTabs:IsA("ScrollingFrame"), "CategoryTabs ScrollingFrame exists")
		assertTrue(catTabs:FindFirstChild("CategoryButtonTemplate") ~= nil, "CategoryButtonTemplate exists")

		local crateFilterBar = mainFrame:FindFirstChild("CrateFamilyFilterBar") :: Frame
		assertTrue(crateFilterBar ~= nil and crateFilterBar:IsA("Frame"), "CrateFamilyFilterBar exists in MainFrame")
		assertTrue(crateFilterBar.Visible == false, "CrateFamilyFilterBar starts hidden until 'Cajas de motores' is selected")
	end)

	-- [02] Los 4 filtros secundarios (Todas, Vehículos, Propulsores, Aviones)
	runTest("Fase 5.3.2 [02]: Secondary filter bar exposes Todas, Vehículos, Propulsores, and Aviones buttons", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local bar = sg.MainFrame:FindFirstChild("CrateFamilyFilterBar") :: Frame
		assertTrue(bar ~= nil, "CrateFamilyFilterBar exists")

		local fTpl = bar:FindFirstChild("CrateFilterButtonTemplate") :: TextButton
		local fAll = bar:FindFirstChild("Filter_All") :: TextButton
		local fEng = bar:FindFirstChild("Filter_Engines") :: TextButton
		local fBoo = bar:FindFirstChild("Filter_Boosters") :: TextButton
		local fAir = bar:FindFirstChild("Filter_AircraftEngines") :: TextButton

		assertTrue(fTpl ~= nil and fTpl.Visible == false, "CrateFilterButtonTemplate exists and hidden")
		assertEqual(fAll.Text, "Todas", "Filter_All text is Todas")
		assertEqual(fEng.Text, "⚙ Vehículos", "Filter_Engines text is ⚙ Vehículos")
		assertEqual(fBoo.Text, "🚀 Propulsores", "Filter_Boosters text is 🚀 Propulsores")
		assertEqual(fAir.Text, "🛩 Aviones", "Filter_AircraftEngines text is 🛩 Aviones")
	end)

	-- [03] Filtrado exclusivo por familia y ordenamiento por ProgressionOrder
	runTest("Fase 5.3.2 [03]: LootBoxConfig.GetBoxesByFamily filters exclusively by RewardCategory and sorts by ProgressionOrder", function()
		LootBoxConfig._ClearOverridesForTests()
		local allBoxes = LootBoxConfig.GetBoxesByFamily("All")
		local engBoxes = LootBoxConfig.GetBoxesByFamily("Engines")
		local booBoxes = LootBoxConfig.GetBoxesByFamily("Boosters")
		local airBoxes = LootBoxConfig.GetBoxesByFamily("AircraftEngines")

		assertEqual(#engBoxes, 2, "Engines family returns BasicEngineCrate and RoadEngineCrate")
		assertEqual(engBoxes[1].BoxId, "BasicEngineCrate", "First Engines box by ProgressionOrder is BasicEngineCrate")
		assertEqual(engBoxes[2].BoxId, "RoadEngineCrate", "Second Engines box by ProgressionOrder is RoadEngineCrate")
		assertTrue(engBoxes[1].ProgressionOrder < engBoxes[2].ProgressionOrder, "ProgressionOrder increases monotonically")

		assertEqual(#booBoxes, 1, "Boosters family returns BasicBoosterCrate only")
		assertEqual(booBoxes[1].BoxId, "BasicBoosterCrate", "Boosters box is BasicBoosterCrate")

		assertEqual(#airBoxes, 0, "AircraftEngines family starts empty cleanly")

		assertEqual(#allBoxes, 3, "All family returns all 3 configured boxes")
		assertEqual(allBoxes[1].BoxId, "BasicEngineCrate", "All[1] = BasicEngineCrate")
		assertEqual(allBoxes[2].BoxId, "RoadEngineCrate", "All[2] = RoadEngineCrate")
		assertEqual(allBoxes[3].BoxId, "BasicBoosterCrate", "All[3] = BasicBoosterCrate")
	end)

	-- [04] Ningún motor ni propulsor individual aparece como producto comprable
	runTest("Fase 5.3.2 [04]: Zero individual engines or boosters appear as direct shop products", function()
		local directItems = ItemCatalog.GetPurchasableShopItems()
		assertEqual(#directItems, 12, "Strictly 12 direct purchasable items")
		for _, entry in ipairs(directItems) do
			assertTrue(not ItemCatalog.IsLootBoxExclusiveReward(entry.Id), `No exclusive reward '{entry.Id}' in GetPurchasableShopItems`)
			assertTrue(entry.Category ~= "Engines" and entry.Category ~= "Boosters", `No individual engine/booster '{entry.Id}' sold directly`)
		end
		assertEqual(ItemCatalog.IsDirectShopPurchasable("SmallEngine"), false, "SmallEngine not direct purchasable")
		assertEqual(ItemCatalog.IsDirectShopPurchasable("SmallBooster"), false, "SmallBooster not direct purchasable")
	end)

	-- [05] Cada caja conserva su precio real y estado de habilitación
	runTest("Fase 5.3.2 [05]: Each crate preserves its real price and Enabled flag", function()
		local basicEng = LootBoxConfig.GetBox("BasicEngineCrate")
		local roadEng = LootBoxConfig.GetBox("RoadEngineCrate")
		local basicBoo = LootBoxConfig.GetBox("BasicBoosterCrate")

		assertTrue(basicEng ~= nil, "BasicEngineCrate defined")
		assertEqual((basicEng :: any).Price, 80, "BasicEngineCrate Price == 80")
		assertEqual((basicEng :: any).Enabled, true, "BasicEngineCrate Enabled == true")

		assertTrue(basicBoo ~= nil, "BasicBoosterCrate defined")
		assertEqual((basicBoo :: any).Price, 45000, "BasicBoosterCrate Price == 45000")
		assertEqual((basicBoo :: any).Enabled, true, "BasicBoosterCrate Enabled == true")

		assertTrue(roadEng ~= nil, "RoadEngineCrate defined")
		assertEqual((roadEng :: any).Price, nil, "RoadEngineCrate Price == nil")
		assertEqual((roadEng :: any).Enabled, false, "RoadEngineCrate Enabled == false")
	end)

	-- [06] Cada caja tiene su propio tiempo de entrega autoritativo (DeliverySeconds por BoxId)
	runTest("Fase 5.3.2 [06]: Each BoxId supports individual authoritative DeliverySeconds and formatted time", function()
		LootBoxConfig._ClearOverridesForTests()
		assertEqual(LootBoxConfig.GetDeliverySeconds("BasicEngineCrate"), 900, "Default BasicEngineCrate DeliverySeconds == 900")
		assertEqual(LootBoxConfig.GetDeliverySeconds("BasicBoosterCrate"), 900, "Default BasicBoosterCrate DeliverySeconds == 900")

		patchBoxForTest("BasicEngineCrate", {
			DeliverySeconds = 120,
		})
		assertEqual(LootBoxConfig.GetDeliverySeconds("BasicEngineCrate"), 120, "Overridden BasicEngineCrate DeliverySeconds == 120")
		assertEqual(LootBoxConfig.GetDeliverySeconds("BasicBoosterCrate"), 900, "Untouched BasicBoosterCrate DeliverySeconds == 900")

		local resEng = ShopStatsResolver.ResolveLootBoxDetails("BasicEngineCrate")
		local resBoo = ShopStatsResolver.ResolveLootBoxDetails("BasicBoosterCrate")
		assertTrue(resEng ~= nil and resEng.DeliveryTimeSeconds == 120, "Resolved BasicEngineCrate DeliveryTimeSeconds == 120")
		assertEqual(LootBoxConfig.FormatDeliveryTime(120, false), "2 min (120 s)", "Formatted 120 s delivery label")
		assertTrue(resBoo ~= nil and resBoo.DeliveryTimeSeconds == 900, "Resolved BasicBoosterCrate DeliveryTimeSeconds == 900")
		assertEqual(LootBoxConfig.FormatDeliveryTime(900, false), "15 min (900 s)", "Formatted 900 s delivery label")

		LootBoxConfig._ClearOverridesForTests()
		assertEqual(LootBoxConfig.GetDeliverySeconds("BasicEngineCrate"), 900, "Restored BasicEngineCrate DeliverySeconds == 900")
	end)

	-- [07] Stock y RestockIntervalSeconds independientes por BoxId
	runTest("Fase 5.3.2 [07]: Independent StockMin, StockMax, CurrentStock, and RestockIntervalSeconds per BoxId", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53207, Name = "P532_IndepStock" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 200000, "TestGrant", "tx_532_07")

		ShopStockService._SetStockForTests("BasicEngineCrate", 3)
		ShopStockService._SetStockForTests("BasicBoosterCrate", 2)

		local buyRes = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p532_07_buy",
			BoxId = "BasicEngineCrate",
		})
		assertTrue(buyRes.Success, "Bought 1 BasicEngineCrate")
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 2, "BasicEngineCrate stock decremented to 2")
		assertEqual(ShopStockService.GetStock("BasicBoosterCrate"), 2, "BasicBoosterCrate stock untouched (still 2)")

		-- Configurar RestockIntervalSeconds independiente para BasicEngineCrate (180s vs 300s)
		patchBoxForTest("BasicEngineCrate", {
			RestockIntervalSeconds = 180,
			StockMin = 4,
			StockMax = 4,
		})
		ShopStockService.ExecuteBoxRestock("BasicEngineCrate", "TestReset180")
		ShopStockService._SetStockForTests("BasicEngineCrate", 1)
		ShopStockService._SetStockForTests("BasicBoosterCrate", 0)

		-- Avanzar 200s: solo BasicEngineCrate (180s) debe reabastecerse; BasicBoosterCrate (300s) sigue en 0
		env.AdvanceClock(200)
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 4, "BasicEngineCrate restocked independently at 180s")
		assertEqual(ShopStockService.GetStock("BasicBoosterCrate"), 0, "BasicBoosterCrate NOT yet restocked at 200s (<300s)")

		env.Teardown()
	end)

	-- [08] El restock reemplaza existencias sin acumular el stock sobrante
	runTest("Fase 5.3.2 [08]: Restock strictly replaces stock per BoxId (never accumulates)", function()
		local env = setupIsolatedWorld(1)
		ShopStockService._SetStockForTests("BasicEngineCrate", 3)
		ShopStockService._SetStockForTests("BasicBoosterCrate", 2)
		ShopStockService._SetRngForTests(function(_minQ, _maxQ, boxId)
			if boxId == "BasicEngineCrate" then
				return 2
			end
			return 1
		end)

		env.AdvanceClock(ShopConfig.Orders.RestockIntervalSeconds)
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 2, "BasicEngineCrate replaced 3 -> 2 (never 5)")
		assertEqual(ShopStockService.GetStock("BasicBoosterCrate"), 1, "BasicBoosterCrate replaced 2 -> 1 (never 3)")

		local snaps = indexStockSnapshots()
		assertEqual(snaps["BasicEngineCrate"].StockMin, 1, "Snapshot exposes StockMin=1")
		assertEqual(snaps["BasicEngineCrate"].StockMax, 3, "Snapshot exposes StockMax=3")
		assertEqual(snaps["BasicEngineCrate"].CurrentStock, 2, "Snapshot exposes CurrentStock=2")
		assertEqual(snaps["BasicBoosterCrate"].CurrentStock, 1, "Snapshot exposes CurrentStock=1")

		ShopStockService._SetRngForTests(nil)
		env.Teardown()
	end)

	-- [09] ReadyAt calculado al comprar e inmune a cambios posteriores de config
	runTest("Fase 5.3.2 [09]: Order persists ReadyAt at purchase time; later config DeliverySeconds edits do not mutate existing orders", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53209, Name = "P532_ReadyAt" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 50000, "TestGrant", "tx_532_09")
		ShopStockService._SetStockForTests("BasicEngineCrate", 3)

		patchBoxForTest("BasicEngineCrate", {
			DeliverySeconds = 180,
		})
		local boughtAt = env.GetNow()
		local res = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p532_09_buy",
			BoxId = "BasicEngineCrate",
		})
		assertTrue(res.Success, "Special crate purchased with DeliverySeconds=180")
		local snapBefore = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		local orderBefore = snapBefore.SpecialOrders[1]
		assertEqual(orderBefore.ReadyAt, boughtAt + 180, "ReadyAt persisted as boughtAt + 180")
		assertEqual(orderBefore.RemainingSeconds, 180, "RemainingSeconds == 180")

		-- Cambiar DeliverySeconds de BasicEngineCrate a 3600s DESPUÉS de comprar
		patchBoxForTest("BasicEngineCrate", {
			DeliverySeconds = 3600,
		})
		env.AdvanceClock(60)
		local snapAfter = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		local orderAfter = snapAfter.SpecialOrders[1]
		assertEqual(orderAfter.ReadyAt, boughtAt + 180, "Existing order ReadyAt unchanged after config edit")
		assertEqual(orderAfter.RemainingSeconds, 120, "Existing order RemainingSeconds == 120 after 60s")

		env.Teardown()
	end)

	-- [10] Los pedidos continúan avanzando mientras el jugador está desconectado
	runTest("Fase 5.3.2 [10]: Special crate orders continue advancing seamlessly while player is offline", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53210, Name = "P532_Offline" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 50000, "TestGrant", "tx_532_10")
		ShopStockService._SetStockForTests("BasicEngineCrate", 3)

		local buy = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p532_10_buy",
			BoxId = "BasicEngineCrate",
		})
		assertTrue(buy.Success, "Purchased BasicEngineCrate")

		-- Offline 400 s -> 500 s restantes (de 900 s)
		env.SimulateRejoin(400)
		PlotService.Assign(p1)
		local snapMid = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snapMid.SpecialOrders[1].RemainingSeconds, 500, "500 s remaining after 400 s offline")
		assertEqual(snapMid.SpecialOrders[1].Status, "InTransit", "Still InTransit at 400 s")

		-- Offline otros 550 s (total 950 s > 900 s) -> Arrived al reconectar
		env.SimulateRejoin(550)
		PlotService.Assign(p1)
		local snapEnd = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snapEnd.SpecialOrders[1].RemainingSeconds, 0, "0 s remaining after 950 s offline")
		assertEqual(snapEnd.SpecialOrders[1].Status, "Arrived", "Order Arrived upon reconnect")

		env.Teardown()
	end)

	-- [11] Compras simultáneas de la última unidad no sobrevenden el stock
	runTest("Fase 5.3.2 [11]: Simultaneous purchases of last shared crate unit allow strictly 1 buyer and reject oversell", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 53211, Name = "P532_Conc1" }
		local p2: PlotService.PlayerLike = { UserId = 53212, Name = "P532_Conc2" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)
		ShopStockService._SetStockForTests("BasicEngineCrate", 1)

		local r1, r2 = nil, nil
		local done = 0
		task.spawn(function()
			r1 = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.PurchaseSpecialCrate, ClientOpId = "p532_c1", BoxId = "BasicEngineCrate" })
			done += 1
		end)
		task.spawn(function()
			r2 = ShopService.ProcessRequest(p2, { Action = ShopProtocol.Actions.PurchaseSpecialCrate, ClientOpId = "p532_c2", BoxId = "BasicEngineCrate" })
			done += 1
		end)
		while done < 2 do
			task.wait()
		end

		local winners = (if r1 and r1.Success then 1 else 0) + (if r2 and r2.Success then 1 else 0)
		assertEqual(winners, 1, "Strictly 1 winner for last unit")
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 0, "Stock strictly 0")
		local loser = if r1 and not r1.Success then r1 else r2
		assertEqual((loser :: any).ErrorCode, ShopProtocol.ErrorCodes.OutOfStock, "Loser rejected with OutOfStock")

		env.Teardown()
	end)

	-- [12] Las probabilidades reales de recompensa permanecen intactas (18 niveles = 100%)
	runTest("Fase 5.3.2 [12]: Reward rarity probabilities (55/25/12/5/2.5/0.5%) and size subtiers (70/25/5%) sum to 100.00%", function()
		LootBoxConfig._ClearOverridesForTests()
		ItemRegistry.Init()
		LootBoxService.Init()
		local validAll, allErrs = LootBoxService.ValidateAllEnabledBoxes()
		assertTrue(validAll and #allErrs == 0, `All enabled LootBoxes valid: {table.concat(allErrs, "; ")}`)

		for _, boxId in ipairs({ "BasicEngineCrate", "BasicBoosterCrate" }) do
			local okPool, poolErr = LootBoxConfig.ValidateBoxPool(boxId)
			assertTrue(okPool, `ValidateBoxPool({boxId}): {tostring(poolErr)}`)
			local boxDef = LootBoxConfig.GetBox(boxId) :: LootBoxConfig.LootBoxDefinition
			assertTrue(math.abs(boxDef.RarityWeights.Common - 55) < 1e-6, `{boxId} Common 55%`)
			assertTrue(math.abs(boxDef.RarityWeights.Uncommon - 25) < 1e-6, `{boxId} Uncommon 25%`)
			assertTrue(math.abs(boxDef.RarityWeights.Rare - 12) < 1e-6, `{boxId} Rare 12%`)
			assertTrue(math.abs(boxDef.RarityWeights.Epic - 5) < 1e-6, `{boxId} Epic 5%`)
			assertTrue(math.abs(boxDef.RarityWeights.Legendary - 2.5) < 1e-6, `{boxId} Legendary 2.5%`)
			assertTrue(math.abs(boxDef.RarityWeights.Mythic - 0.5) < 1e-6, `{boxId} Mythic 0.5%`)
			assertTrue(math.abs(boxDef.SizeWeights.Small - 70) < 1e-6, `{boxId} Small 70%`)
			assertTrue(math.abs(boxDef.SizeWeights.Medium - 25) < 1e-6, `{boxId} Medium 25%`)
			assertTrue(math.abs(boxDef.SizeWeights.Large - 5) < 1e-6, `{boxId} Large 5%`)

			local details = ShopStatsResolver.ResolveLootBoxDetails(boxId)
			assertTrue(details ~= nil, `{boxId} details resolved`)
			local d = details :: ShopStatsResolver.ResolvedLootBoxDetails
			assertEqual(#d.PossibleRewards, 18, `{boxId} strictly 18 rarity x size tiers`)
			local sumPct = 0
			for _, row in ipairs(d.PossibleRewards) do
				sumPct += row.ProbabilityPercent
			end
			assertTrue(math.abs(sumPct - 100.0) < 0.01, `{boxId} probabilities sum to 100.00% (got {sumPct})`)
		end
	end)

	-- [13] El carrito de componentes normales (100+ unidades, 60s espera) sigue funcionando
	runTest("Fase 5.3.2 [13]: Normal component cart supports 100+ units with 60s wait and 1 crate per ItemId", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53213, Name = "P532_NormalCart" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 50000, "TestGrant", "tx_532_13")

		local co = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p532_13_cart",
			CartItems = {
				{ ItemId = "WoodBlock", Quantity = 100 },
				{ ItemId = "DriverSeat", Quantity = 2 },
			},
		})
		assertTrue(co.Success, "Normal cart 100+ units succeeded")
		assertEqual(#(co.Order :: any).Crates, 2, "Strictly 1 crate per ItemId")

		local snapBefore = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snapBefore.NormalOrderBlocked, true, "Normal order blocked during 60s transit")
		assertEqual(snapBefore.NormalOrderRemainingSeconds, 60, "Normal order remaining = 60s")

		env.AdvanceClock(60)
		local snapAfter = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snapAfter.NormalOrderBlocked, false, "Normal order delivered at 60s")
		env.Teardown()
	end)

	-- [14] Los componentes normales mantienen stock ilimitado
	runTest("Fase 5.3.2 [14]: Normal components have unlimited stock (ShopStockService tracks only LootBoxes)", function()
		local snaps = indexStockSnapshots()
		local directItems = ItemCatalog.GetPurchasableShopItems()
		for _, entry in ipairs(directItems) do
			assertEqual(snaps[entry.Id], nil, `Normal component '{entry.Id}' not tracked/restricted in ShopStockService`)
		end
		assertTrue(snaps["BasicEngineCrate"] ~= nil, "BasicEngineCrate tracked in ShopStockService")
		assertTrue(snaps["BasicBoosterCrate"] ~= nil, "BasicBoosterCrate tracked in ShopStockService")
	end)

	-- [15] StarterGui.ShopGui sigue siendo editable visualmente en Studio
	runTest("Fase 5.3.2 [15]: StarterGui.ShopGui remains physically present and editable with all Fase 5.3.2 elements", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local mf = sg:FindFirstChild("MainFrame") :: Frame
		local cs = mf:FindFirstChild("CatalogScroll") :: ScrollingFrame
		local tpl = cs:FindFirstChild("ItemCardTemplate") :: Frame
		local badge = tpl:FindFirstChild("FamilyIconBadge") :: Frame
		local lootModal = sg:FindFirstChild("LootBoxDetailsModal") :: Frame

		assertTrue(mf:FindFirstChild("CrateFamilyFilterBar") ~= nil, "MainFrame.CrateFamilyFilterBar exists")
		assertTrue(mf:FindFirstChild("EmptyCatalogOverlay") ~= nil, "MainFrame.EmptyCatalogOverlay exists")
		assertTrue(badge ~= nil, "ItemCardTemplate.FamilyIconBadge exists")
		assertTrue(badge:FindFirstChild("FamilyIconImage") ~= nil, "FamilyIconBadge.FamilyIconImage exists")
		assertTrue(badge:FindFirstChild("FamilyIconGlyph") ~= nil, "FamilyIconBadge.FamilyIconGlyph exists")
		assertTrue(tpl:FindFirstChild("DeliveryTimeLabel") ~= nil, "ItemCardTemplate.DeliveryTimeLabel exists")
		assertTrue(lootModal.Header:FindFirstChild("FamilyIconBadge") ~= nil, "LootBoxDetailsModal.Header.FamilyIconBadge exists")
		assertTrue(lootModal.LeftColumn:FindFirstChild("DeliveryTimeLabel") ~= nil, "LootBoxDetailsModal.LeftColumn.DeliveryTimeLabel exists")
	end)

	-- [16] Compatibilidad automática con cajas futuras de Aviones (RewardCategory = AircraftEngines)
	runTest("Fase 5.3.2 [16]: Future AircraftEngines crate integrates automatically into Aviones and Todas without code rewrites", function()
		local baseEng = LootBoxConfig.GetBox("BasicEngineCrate") :: LootBoxConfig.LootBoxDefinition
		local mockAir = table.clone(baseEng :: any)
		mockAir.BoxId = "BasicAircraftEngineCrate"
		mockAir.DisplayName = "Caja Básica de Motores de Avión"
		mockAir.Description = "Motores de hélice experimentales para avión."
		mockAir.RewardCategory = "AircraftEngines"
		mockAir.ProgressionOrder = 10
		mockAir.FamilyIcon = "AircraftPropeller"
		mockAir.Price = 12000
		mockAir.DeliverySeconds = 600
		mockAir.RestockIntervalSeconds = 300
		mockAir.StockMin = 1
		mockAir.StockMax = 3
		LootBoxConfig._SetBoxOverrideForTests("BasicAircraftEngineCrate", mockAir)

		local airBoxes = LootBoxConfig.GetBoxesByFamily("AircraftEngines")
		local allBoxes = LootBoxConfig.GetBoxesByFamily("All")
		local resolvedAir = ShopStatsResolver.ResolveLootBoxDetails("BasicAircraftEngineCrate")
		local famSpec = LootBoxConfig.GetFamilySpec("AircraftEngines")

		assertEqual(#airBoxes, 1, "Aviones filter detects 1 future AircraftEngines crate")
		assertEqual(airBoxes[1].BoxId, "BasicAircraftEngineCrate", "AircraftEngines box returned cleanly")
		assertEqual(#allBoxes, 4, "Todas crates includes new AircraftEngines box cleanly")
		assertEqual(allBoxes[4].BoxId, "BasicAircraftEngineCrate", "AircraftEngines grouped after Boosters")
		assertTrue(resolvedAir ~= nil, "ShopStatsResolver resolves BasicAircraftEngineCrate")
		assertEqual(famSpec.Glyph, "🛩", "AircraftEngines uses airplane glyph 🛩")
		assertEqual((resolvedAir :: any).DeliveryTimeSeconds, 600, "DeliveryTimeSeconds == 600")
		assertEqual((resolvedAir :: any).CategoryDisplayName, "Motores de Avión", "CategoryDisplayName == Motores de Avión")

		LootBoxConfig._ClearOverridesForTests()
		assertEqual(#LootBoxConfig.GetBoxesByFamily("AircraftEngines"), 0, "Cleaned up future AircraftEngines test mock")
	end)

	-- [17] Prevención de desborde en tarjetas y controles visibles
	runTest("Fase 5.3.2 [17]: ItemCardTemplate enforces ClipsDescendants, wrapped scaled title, and all visible controls", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local tpl = sg.MainFrame.CatalogScroll:FindFirstChild("ItemCardTemplate") :: Frame
		local title = tpl:FindFirstChild("TitleLabel") :: TextLabel
		local constraint = title:FindFirstChildOfClass("UITextSizeConstraint")

		assertEqual(tpl.ClipsDescendants, true, "ItemCardTemplate.ClipsDescendants == true")
		assertEqual(title.TextWrapped, true, "TitleLabel.TextWrapped == true")
		assertEqual(title.TextScaled, true, "TitleLabel.TextScaled == true")
		assertTrue(constraint ~= nil, "TitleLabel has UITextSizeConstraint")
		assertTrue(tpl:FindFirstChild("DeliveryTimeLabel") ~= nil, "DeliveryTimeLabel present")
		assertTrue(tpl:FindFirstChild("OwnedStockLabel") ~= nil, "OwnedStockLabel present")
		assertTrue(tpl:FindFirstChild("PriceRow") ~= nil, "PriceRow present")
		assertTrue(tpl:FindFirstChild("InfoButton") ~= nil, "InfoButton ⓘ present")
		assertTrue(tpl:FindFirstChild("QuantityControls") ~= nil, "QuantityControls present")
		assertTrue(tpl:FindFirstChild("BuyButton") ~= nil, "BuyButton present")
	end)

	-- [18] ServerStorage.BaseTemplate conserva exactamente 25 descendientes
	runTest("Fase 5.3.2 [18]: ServerStorage.BaseTemplate strictly preserves 25 descendants", function()
		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		assertEqual(#baseTemplate:GetDescendants(), 25, "BaseTemplate must remain at 25 descendants")
	end)
end

function Phase532Tests.RunAll()
	local results: { TestCaseResult } = {}
	local passed = 0
	local failed = 0

	local function runTest(name: string, fn: () -> ())
		local ok, err = xpcall(fn, debug.traceback)
		if ok then
			passed += 1
			table.insert(results, { Name = name, Passed = true, Error = nil })
		else
			failed += 1
			table.insert(results, { Name = name, Passed = false, Error = tostring(err) })
		end
	end

	Phase532Tests.AppendTests(results, runTest)

	return {
		Passed = passed,
		Failed = failed,
		Total = passed + failed,
		Results = results,
	}
end

return Phase532Tests
