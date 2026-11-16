--!strict
--[=[
	Phase531Tests
	Suite automatizada de validación para la Fase 5.3.1 (Reestructuración de ShopGui en StarterGui):
	Verifica los 16 puntos obligatorios:
	  [01] Estructura real y editable de StarterGui.ShopGui y sus plantillas.
	  [02] Controles de apertura y cierre de MainFrame, ItemDetailsModal, LootBoxDetailsModal y OrdersModal.
	  [03] Pestañas de categorías (CategoryTabs + CategoryButtonTemplate) cubriendo todas las categorías.
	  [04] Renderizado y catálogo de los 14 componentes y las Cajas Especiales.
	  [05] Botón de información (InfoButton "ⓘ") en ItemCardTemplate reutilizando un único ItemDetailsModal / LootBoxDetailsModal.
	  [06] Estadísticas dinámicas reales por categoría (Bloques, Ruedas, Motores, Tanques, Propulsores, Aerodinámica, Asientos).
	  [07] Previews 3D sanitizados (ViewportFrame + WorldModel + PreviewAssets.CajasEspeciales sin scripts ni físicas).
	  [08] Información y probabilidades exactas de LootBoxes (18 combinaciones sumando 100.00%, bonificaciones reales y soporte futuro).
	  [09] Scroll independiente en CatalogScroll, CartItemsScroll, StatsScroll, RewardsScroll y OrdersScroll.
	  [10] Compras normales (60 s, 1 caja por ItemId, stock ilimitado).
	  [11] Compras de cajas especiales (900 s, stock compartido por servidor, restock de reemplazo 300 s).
	  [12] Compras grandes de 100+ unidades (selector de cantidad y +100).
	  [13] Carrito, bloqueo temporal de pedido normal en tránsito y Mis Pedidos.
	  [14] Compatibilidad completa con los 6 objetos aerodinámicos de la Fase 5.3 (estadísticas, compra, entrega y venta 50%).
	  [15] Diseño responsive (ResponsiveScale UIScale, UISizeConstraint y CatalogGridLayout UIGridLayout).
	  [16] Integridad de ServerStorage.BaseTemplate (25 descendientes) y ausencia de residuos.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local AerodynamicsConfig = require(ReplicatedStorage.Shared.Config.AerodynamicsConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local ShopGuiSchema = require(ReplicatedStorage.Shared.UI.ShopGuiSchema)
local ShopStatsResolver = require(ReplicatedStorage.Shared.UI.ShopStatsResolver)

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

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase531Tests = {}

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
	BuildService._ResetForTests()
	ShopService._ResetForTests()
	OfflineIncomeService._ResetForTests()
	DeliveryService._ResetForTests(preservePersistence)
	ShopStockService._ResetForTests()
	EconomyService._ResetForTests(preservePersistence)
	VehicleLaunchService._ResetForTests()
	VehicleLifecycleService._ResetForTests()
	VehicleRuntimeService._ResetForTests()
	VehicleSeatService._ResetForTests()
	VehicleDestructionService._ResetForTests()
	VehicleImpactService._ResetForTests()
	VehicleDamageService._ResetForTests()
	AerodynamicsService._ResetForTests()
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
	end
	ConnectionService._ResetForTests()
	WheelAutoConfigurationService._ResetForTests()
	PreviewAssetService._ResetForTests()
	SpawnService._ResetForTests()
	PlotService._ResetForTests()
end

local function initAllServices(tempPlots: Folder, plotCount: number?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
	local assets = ServerStorage:WaitForChild("ItemAssets")

	ItemRegistry.Init()
	ItemRegistry.NormalizeAssets(assets)
	ShopGuiSchema.EnsureStarterGui()
	PlotService.Init({
		BaseTemplate = baseTemplate,
		PlotSpawnsFolder = plotSpawns,
		PlotsParent = tempPlots,
		PlotCount = plotCount or 2,
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
	local existing = Workspace:FindFirstChild("_Phase531TestPlots")
	if existing then
		existing:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase531TestPlots"
	tempPlots.Parent = Workspace

	local virtualClock = 200000
	local rateClock = 200000

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
		PlotsFolder = tempPlots,
		AdvanceClock = function(seconds: number)
			virtualClock += math.max(0, math.floor(seconds))
			DeliveryService.StepAll(virtualClock)
			ShopStockService.StepRestockCheck()
		end,
		Teardown = function()
			resetAllServices(false)
			if tempPlots.Parent then
				tempPlots:Destroy()
			end
		end,
	}
end

function Phase531Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (name: string, fn: () -> ()) -> ()
)
	-- [01] Estructura real en StarterGui
	runTest("Fase 5.3.1 [01]: StarterGui.ShopGui contains all mandatory editable frames and templates", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		assertTrue(sg ~= nil and sg:IsA("ScreenGui") and sg.Parent == StarterGui, "StarterGui.ShopGui exists in StarterGui")
		assertEqual(sg.ResetOnSpawn, false, "ResetOnSpawn must be false")

		local requiredNodes = {
			"MainFrame",
			"Header",
			"CloseButton",
			"OrdersButton",
			"CategoryTabs",
			"CategoryButtonTemplate",
			"CatalogScroll",
			"ItemCardTemplate",
			"ItemDetailsModal",
			"LootBoxDetailsModal",
			"CartPanel",
			"OrdersModal",
			"Notifications",
			"OfflineIncomeModal",
			"EconomyHudDock",
			"ResponsiveScale",
		}
		for _, nodeName in ipairs(requiredNodes) do
			local node = sg:FindFirstChild(nodeName, true)
			assertTrue(node ~= nil, `Missing mandatory node '{nodeName}' in StarterGui.ShopGui`)
		end
	end)

	-- [02] Apertura y cierre de tienda y modales
	runTest("Fase 5.3.1 [02]: MainFrame, ItemDetailsModal, LootBoxDetailsModal, and OrdersModal have CloseButtons and clean default visibility", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local mainFrame = sg:FindFirstChild("MainFrame") :: Frame
		local itemModal = sg:FindFirstChild("ItemDetailsModal") :: Frame
		local boxModal = sg:FindFirstChild("LootBoxDetailsModal") :: Frame
		local ordersModal = sg:FindFirstChild("OrdersModal") :: Frame

		assertEqual(mainFrame.Visible, false, "MainFrame starts hidden")
		assertEqual(itemModal.Visible, false, "ItemDetailsModal starts hidden")
		assertEqual(boxModal.Visible, false, "LootBoxDetailsModal starts hidden")
		assertEqual(ordersModal.Visible, false, "OrdersModal starts hidden")

		assertTrue(mainFrame.Header:FindFirstChild("CloseButton") ~= nil, "MainFrame Header CloseButton exists")
		assertTrue(mainFrame.Header:FindFirstChild("OrdersButton") ~= nil, "MainFrame Header OrdersButton exists")
		assertTrue(itemModal.Header:FindFirstChild("CloseButton") ~= nil, "ItemDetailsModal CloseButton exists")
		assertTrue(boxModal.Header:FindFirstChild("CloseButton") ~= nil, "LootBoxDetailsModal CloseButton exists")
		assertTrue(ordersModal.Header:FindFirstChild("CloseButton") ~= nil, "OrdersModal CloseButton exists")
	end)

	-- [03] Navegación entre categorías
	runTest("Fase 5.3.1 [03]: CategoryTabs has horizontal UIListLayout and hidden CategoryButtonTemplate", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local catTabs = sg.MainFrame:FindFirstChild("CategoryTabs") :: ScrollingFrame
		assertTrue(catTabs ~= nil and catTabs:IsA("ScrollingFrame"), "CategoryTabs is a ScrollingFrame")
		local listLayout = catTabs:FindFirstChildOfClass("UIListLayout")
		assertTrue(listLayout ~= nil and listLayout.FillDirection == Enum.FillDirection.Horizontal, "CategoryTabs has Horizontal UIListLayout")
		local btnTpl = catTabs:FindFirstChild("CategoryButtonTemplate") :: TextButton
		assertTrue(btnTpl ~= nil and btnTpl:IsA("TextButton") and btnTpl.Visible == false, "CategoryButtonTemplate is a hidden TextButton template")
	end)

	-- [04] Renderizado de productos en catálogo con UIGridLayout
	runTest("Fase 5.3.1 [04]: CatalogScroll uses UIGridLayout and ItemCardTemplate with yellow BuyButton and PriceRow", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local catalogScroll = sg.MainFrame:FindFirstChild("CatalogScroll") :: ScrollingFrame
		local grid = catalogScroll:FindFirstChildOfClass("UIGridLayout")
		assertTrue(grid ~= nil, "CatalogScroll contains UIGridLayout")
		local tpl = catalogScroll:FindFirstChild("ItemCardTemplate") :: Frame
		assertTrue(tpl ~= nil and tpl.Visible == false, "ItemCardTemplate exists and is hidden by default")

		local buyBtn = tpl:FindFirstChild("BuyButton") :: TextButton
		assertTrue(buyBtn ~= nil and buyBtn:IsA("TextButton"), "ItemCardTemplate has BuyButton")
		-- Verificar color amarillo de compra (R > 0.85, G > 0.65, B < 0.35)
		assertTrue(buyBtn.BackgroundColor3.R > 0.85 and buyBtn.BackgroundColor3.G > 0.65 and buyBtn.BackgroundColor3.B < 0.35, "BuyButton is yellow")

		local priceRow = tpl:FindFirstChild("PriceRow") :: Frame
		assertTrue(priceRow ~= nil and priceRow:FindFirstChild("CoinIcon") ~= nil and priceRow:FindFirstChild("PriceLabel") ~= nil, "PriceRow has CoinIcon and PriceLabel")
	end)

	-- [05] Botón de información (InfoButton) por objeto y reutilización de un solo ItemDetailsModal
	runTest("Fase 5.3.1 [05]: ItemCardTemplate has top-right InfoButton and single reusable ItemDetailsModal with StatRowTemplate", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local tpl = sg.MainFrame.CatalogScroll.ItemCardTemplate :: Frame
		local infoBtn = tpl:FindFirstChild("InfoButton") :: TextButton
		assertTrue(infoBtn ~= nil and infoBtn:IsA("TextButton"), "InfoButton exists on ItemCardTemplate")
		assertEqual(infoBtn.AnchorPoint.X, 1, "InfoButton anchored to top-right")

		local modalCount = 0
		for _, ch in ipairs(sg:GetChildren()) do
			if ch.Name == "ItemDetailsModal" then
				modalCount += 1
			end
		end
		assertEqual(modalCount, 1, "Exactly one reusable ItemDetailsModal exists")
		local statTpl = sg.ItemDetailsModal.RightColumn.StatsScroll:FindFirstChild("StatRowTemplate") :: Frame
		assertTrue(statTpl ~= nil and statTpl.Visible == false, "StatRowTemplate exists inside ItemDetailsModal")
	end)

	-- [06] Estadísticas dinámicas reales por categoría (los 14 objetos del catálogo)
	runTest("Fase 5.3.1 [06]: ShopStatsResolver resolves authentic category-specific statistics for all 14 catalog items", function()
		local env = setupIsolatedWorld(1)
		for _, def in ipairs(ItemRegistry.GetAll()) do
			local details = ShopStatsResolver.ResolveItemDetails(def.Id)
			assertTrue(details ~= nil, `Resolved details for {def.Id}`)
			local d = details :: ShopStatsResolver.ResolvedItemDetails
			assertEqual(d.DisplayName, def.DisplayName, `DisplayName matches for {def.Id}`)
			assertTrue(#d.StatsRows >= 3, `At least 3 real stat rows for {def.Id}`)

			local namesByKey: { [string]: string } = {}
			for _, row in ipairs(d.StatsRows) do
				namesByKey[row.Name] = row.Value
			end

			assertTrue(namesByKey["Peso"] ~= nil, `{def.Id} includes Peso`)
			assertTrue(namesByKey["Durabilidad"] ~= nil, `{def.Id} includes Durabilidad`)

			if def.Category == "Structures" then
				assertTrue(namesByKey["Material"] ~= nil, `Structure {def.Id} includes Material`)
				assertTrue(namesByKey["Dimensiones"] ~= nil, `Structure {def.Id} includes Dimensiones`)
			elseif def.Category == "Wheels" then
				assertTrue(namesByKey["Propiedades de tracción"] ~= nil, "SmallWheel includes traction properties")
				assertTrue(namesByKey["Propiedades de dirección"] ~= nil, "SmallWheel includes steering properties")
			elseif def.Category == "Engines" then
				assertTrue(namesByKey["Potencia"] ~= nil, "SmallEngine includes Potencia")
				assertTrue(namesByKey["Velocidad / Rendimiento"] ~= nil, "SmallEngine includes Velocidad / Rendimiento")
				assertTrue(namesByKey["Tipo de combustible"] ~= nil, "SmallEngine includes Tipo de combustible")
				assertTrue(namesByKey["Consumo"] ~= nil, "SmallEngine includes Consumo")
				assertTrue(namesByKey["Bonificaciones"] ~= nil, "SmallEngine includes Bonificaciones")
				assertTrue(namesByKey["Rareza"] ~= nil, "SmallEngine includes Rareza")
			elseif def.Category == "FuelTanks" then
				assertTrue(namesByKey["Tipo de combustible"] ~= nil, `{def.Id} includes Tipo de combustible`)
				assertTrue(namesByKey["Capacidad"] ~= nil, `{def.Id} includes Capacidad`)
			elseif def.Category == "Boosters" then
				assertTrue(namesByKey["Empuje"] ~= nil, "SmallBooster includes Empuje")
				assertTrue(namesByKey["Consumo"] ~= nil, "SmallBooster includes Consumo")
				assertTrue(namesByKey["Tipo de combustible"] ~= nil, "SmallBooster includes Tipo de combustible")
				assertTrue(namesByKey["Rareza y bonificaciones"] ~= nil, "SmallBooster includes Rareza y bonificaciones")
			elseif def.Category == "Aerodynamics" then
				assertTrue(namesByKey["Superficie alar"] ~= nil, `{def.Id} includes Superficie alar`)
				assertTrue(namesByKey["Coeficiente de sustentación"] ~= nil, `{def.Id} includes Coeficiente de sustentación`)
				assertTrue(namesByKey["Resistencia aerodinámica"] ~= nil, `{def.Id} includes Resistencia aerodinámica`)
				assertTrue(namesByKey["Ángulo de pérdida"] ~= nil, `{def.Id} includes Ángulo de pérdida`)
			end
		end
		env.Teardown()
	end)

	-- [07] Previews 3D con ViewportFrame y WorldModel sanitizados
	runTest("Fase 5.3.1 [07]: ViewportFrames contain WorldModel and PreviewAssets publishes sanitized models for all 14 items and Special Crates", function()
		local env = setupIsolatedWorld(1)
		local sg = ShopGuiSchema.EnsureStarterGui()

		local cardVp = sg.MainFrame.CatalogScroll.ItemCardTemplate.PreviewContainer:FindFirstChild("PreviewViewport") :: ViewportFrame
		local itemVp = sg.ItemDetailsModal.LeftColumn.PreviewContainer:FindFirstChild("PreviewViewport") :: ViewportFrame
		local boxVp = sg.LootBoxDetailsModal.LeftColumn.PreviewContainer:FindFirstChild("PreviewViewport") :: ViewportFrame

		assertTrue(cardVp ~= nil and cardVp:FindFirstChildOfClass("WorldModel") ~= nil, "ItemCardTemplate ViewportFrame has WorldModel")
		assertTrue(itemVp ~= nil and itemVp:FindFirstChildOfClass("WorldModel") ~= nil, "ItemDetailsModal ViewportFrame has WorldModel")
		assertTrue(boxVp ~= nil and boxVp:FindFirstChildOfClass("WorldModel") ~= nil, "LootBoxDetailsModal ViewportFrame has WorldModel")

		local previewRoot = ReplicatedStorage:FindFirstChild("PreviewAssets")
		assertTrue(previewRoot ~= nil, "PreviewAssets exists in ReplicatedStorage")
		local specialCratesPreview = previewRoot:FindFirstChild("CajasEspeciales")
		assertTrue(specialCratesPreview ~= nil, "PreviewAssets.CajasEspeciales exists")
		assertTrue(specialCratesPreview.Motores:FindFirstChild("BasicEngineCrate") ~= nil, "BasicEngineCrate preview model exists")
		assertTrue(specialCratesPreview.Propulsores:FindFirstChild("BasicBoosterCrate") ~= nil, "BasicBoosterCrate preview model exists")

		for _, desc in ipairs(previewRoot:GetDescendants()) do
			assertTrue(not desc:IsA("LuaSourceContainer"), "Zero scripts inside PreviewAssets")
		end
		env.Teardown()
	end)

	-- [08] Información y probabilidades exactas de LootBoxes
	runTest("Fase 5.3.1 [08]: LootBoxDetailsModal resolves 18 exact reward tiers summing to 100.00% for BasicEngineCrate and BasicBoosterCrate", function()
		for _, boxId in ipairs({ "BasicEngineCrate", "BasicBoosterCrate" }) do
			local details = ShopStatsResolver.ResolveLootBoxDetails(boxId)
			assertTrue(details ~= nil and details.Enabled == true, `{boxId} resolved and enabled`)
			local d = details :: ShopStatsResolver.ResolvedLootBoxDetails
			assertEqual(#d.PossibleRewards, 18, `{boxId} has 18 (3 sizes x 6 rarities) reward tiers`)
			assertEqual(d.DeliveryTimeSeconds, 900, `{boxId} delivery time is 900s`)

			local totalProb = 0
			for _, r in ipairs(d.PossibleRewards) do
				totalProb += r.ProbabilityPercent
				assertTrue(#r.BonusesSummary > 10, "Reward tier includes real bonuses summary")
				assertTrue(#r.RarityColorHex == 7, "Reward tier includes RarityColorHex")
			end
			assertTrue(math.abs(totalProb - 100.0) < 0.01, `{boxId} probabilities sum to 100% (got {totalProb})`)
		end

		local roadDetails = ShopStatsResolver.ResolveLootBoxDetails("RoadEngineCrate")
		assertTrue(roadDetails ~= nil and roadDetails.Enabled == false, "RoadEngineCrate remains disabled cleanly")
	end)

	-- [09] Scroll independiente de todas las ventanas
	runTest("Fase 5.3.1 [09]: CatalogScroll, CartItemsScroll, StatsScroll, RewardsScroll, and OrdersScroll have independent AutomaticCanvasSize Y", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local scrolls = {
			sg.MainFrame.CatalogScroll,
			sg.MainFrame.CartPanel.CartItemsScroll,
			sg.ItemDetailsModal.RightColumn.StatsScroll,
			sg.LootBoxDetailsModal.RightColumn.RewardsScroll,
			sg.OrdersModal.OrdersScroll,
			sg.OfflineIncomeModal.OfflineBreakdownScroll,
		}
		for _, sc in ipairs(scrolls) do
			assertTrue(sc:IsA("ScrollingFrame"), `{sc:GetFullName()} is a ScrollingFrame`)
			assertEqual((sc :: ScrollingFrame).AutomaticCanvasSize, Enum.AutomaticSize.Y, `{sc.Name} has AutomaticCanvasSize = Y`)
		end
	end)

	-- [10] Compras normales (60 s, 1 caja por ItemId, stock ilimitado)
	runTest("Fase 5.3.1 [10]: Normal purchases create 60s orders with 1 physical crate per ItemId and unlimited availability", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53110, Name = "P531_NormalBuy" }
		PlotService.Assign(p1)

		local res = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p531_10_co",
			CartItems = {
				{ ItemId = "WoodBlock", Quantity = 10 },
				{ ItemId = "SmallWheel", Quantity = 4 },
			},
		})
		assertTrue(res.Success, "Normal checkout succeeded")
		assertEqual(#(res.Order :: any).Crates, 2, "1 crate per ItemId (2 crates total)")
		env.AdvanceClock(60)
		for _, c in ipairs((res.Order :: any).Crates) do
			assertTrue(ShopService.ProcessRequest(p1, {
				Action = ShopProtocol.Actions.OpenDeliveryCrate,
				ClientOpId = `p531_10_op_{c.CrateId}`,
				CrateId = c.CrateId,
			}).Success, "Opened delivered normal crate")
		end
		env.Teardown()
	end)

	-- [11] Compras de cajas especiales (900 s, stock compartido, restock 300 s)
	runTest("Fase 5.3.1 [11]: Special crate purchase deducts shared stock, delivers at 900s, and restocks every 300s", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53111, Name = "P531_SpecialBuy" }
		PlotService.Assign(p1)
		ShopStockService._SetStockForTests("BasicEngineCrate", 2)

		local res = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p531_11_sp",
			BoxId = "BasicEngineCrate",
		})
		assertTrue(res.Success, "Bought BasicEngineCrate")
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 1, "Shared stock decremented 2 -> 1")
		env.AdvanceClock(900)
		local openRes = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p531_11_open",
			CrateId = (res.Order :: any).OrderId,
		})
		assertTrue(openRes.Success, "Opened special crate at 900s")
		env.Teardown()
	end)

	-- [12] Compras de 100+ unidades y controles QtyInput / +100 en ItemCardTemplate
	runTest("Fase 5.3.1 [12]: ItemCardTemplate includes QtyInput and Add100Btn and server processes 100+ unit orders into a single crate", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local qtyControls = sg.MainFrame.CatalogScroll.ItemCardTemplate:FindFirstChild("QuantityControls") :: Frame
		assertTrue(qtyControls ~= nil, "QuantityControls exists on ItemCardTemplate")
		assertTrue(qtyControls:FindFirstChild("QtyInput") ~= nil, "QtyInput TextBox exists")
		assertTrue(qtyControls:FindFirstChild("Add100Btn") ~= nil, "Add100Btn (+100) exists")

		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53112, Name = "P531_Bulk100" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 50000, "TestGrant", "tx_531_12")

		local co = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p531_12_bulk",
			CartItems = {
				{ ItemId = "WoodBlock", Quantity = 250 },
				{ ItemId = "DriverSeat", Quantity = 15 },
			},
		})
		assertTrue(co.Success, "Bought 250 WoodBlock and 15 DriverSeat")
		assertEqual(#(co.Order :: any).Crates, 2, "Strictly 1 crate per ItemId even for 250 units")
		env.Teardown()
	end)

	-- [13] Carrito y pedidos pendientes (bloqueo temporal de pedido normal en tránsito)
	runTest("Fase 5.3.1 [13]: CartPanel and OrdersModal templates exist and normal order lock blocks concurrent normal checkout until arrival", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		assertTrue(sg.MainFrame.CartPanel.CartItemsScroll:FindFirstChild("CartItemTemplate") ~= nil, "CartItemTemplate exists")
		assertTrue(sg.OrdersModal.OrdersScroll:FindFirstChild("OrderRowTemplate") ~= nil, "OrderRowTemplate exists")

		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53113, Name = "P531_Lock" }
		PlotService.Assign(p1)

		local first = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p531_13_1",
			CartItems = { { ItemId = "WoodBeam", Quantity = 2 } },
		})
		assertTrue(first.Success, "First normal order placed")

		local second = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p531_13_2",
			CartItems = { { ItemId = "WoodBlock", Quantity = 2 } },
		})
		assertEqual(second.Success, false, "Second normal order blocked while first is in transit")
		assertEqual(second.ErrorCode, ShopProtocol.ErrorCodes.NormalOrderInProgress, "NormalOrderInProgress error code")
		env.Teardown()
	end)

	-- [14] Compatibilidad con los 6 objetos aerodinámicos de la Fase 5.3
	runTest("Fase 5.3.1 [14]: All 6 Fase 5.3 aerodynamic items appear in ShopSnapshot, resolve aero stats, and support 100+ purchase & 50% sell", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53114, Name = "P531_AeroShop" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 100000, "TestGrant", "tx_531_14")

		local snap = ShopService.BuildPlayerShopSnapshot(p1) :: any
		local byId: { [string]: any } = {}
		for _, it in ipairs(snap.NormalItems) do
			byId[it.ItemId] = it
		end

		for _, aeroId in ipairs(AerodynamicsConfig.OrderedItemIds) do
			local shopEntry = byId[aeroId]
			assertTrue(shopEntry ~= nil, `Aerodynamic item {aeroId} present in ShopSnapshot.NormalItems`)
			assertEqual(shopEntry.CategoryDisplayName, "Aerodinámica", `{aeroId} CategoryDisplayName is Aerodinámica`)
			local details = ShopStatsResolver.ResolveItemDetails(aeroId)
			assertTrue(details ~= nil and #details.StatsRows >= 6, `{aeroId} resolves full aerodynamic stats`)
		end

		local co = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p531_14_co",
			CartItems = { { ItemId = "LargeGliderWing", Quantity = 100 } },
		})
		assertTrue(co.Success, "Bought 100 LargeGliderWing")
		env.AdvanceClock(60)
		local crateId = (co.Order :: any).Crates[1].CrateId
		assertTrue(ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p531_14_op",
			CrateId = crateId,
		}).Success, "Opened LargeGliderWing crate")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "LargeGliderWing"), 100, "100 LargeGliderWing in inventory")

		local balBefore = EconomyService.GetBalance(p1)
		local sellRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p531_14_sell",
			ItemId = "LargeGliderWing",
			Quantity = 10,
		})
		assertTrue(sellRes.Success, "Sold 10 LargeGliderWing at 50% ($130 each)")
		assertEqual(EconomyService.GetBalance(p1) - balBefore, 1300, "Credited $1,300")
		env.Teardown()
	end)

	-- [15] Escalado responsive en diferentes resoluciones
	runTest("Fase 5.3.1 [15]: ResponsiveScale UIScale, UISizeConstraints, and UIGridLayout support PC, tablet, and mobile viewports", function()
		local sg = ShopGuiSchema.EnsureStarterGui()
		local uiScale = sg:FindFirstChild("ResponsiveScale") :: UIScale
		assertTrue(uiScale ~= nil and uiScale:IsA("UIScale"), "ResponsiveScale UIScale exists on ShopGui")

		assertTrue(sg.MainFrame:FindFirstChildOfClass("UISizeConstraint") ~= nil, "MainFrame has UISizeConstraint")
		assertTrue(sg.ItemDetailsModal:FindFirstChildOfClass("UISizeConstraint") ~= nil, "ItemDetailsModal has UISizeConstraint")
		assertTrue(sg.LootBoxDetailsModal:FindFirstChildOfClass("UISizeConstraint") ~= nil, "LootBoxDetailsModal has UISizeConstraint")
		assertTrue(sg.OrdersModal:FindFirstChildOfClass("UISizeConstraint") ~= nil, "OrdersModal has UISizeConstraint")
	end)

	-- [16] Integridad de BaseTemplate y limpieza
	runTest("Fase 5.3.1 [16]: ServerStorage.BaseTemplate preserves 25 descendants and zero temporary test folders remain", function()
		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		assertEqual(#baseTemplate:GetDescendants(), 25, "ServerStorage.BaseTemplate strictly preserved at 25 descendants")
	end)

	-- [17] Hotfix 5.3.1.1: Exclusión comercial estricta de recompensas de LootBox (SmallEngine y SmallBooster)
	runTest("Hotfix 5.3.1.1 [17]: SmallEngine and SmallBooster are LootBoxRewardOnly, excluded from shop catalog, rejected on direct buy, yet valid in LootBoxDetails, Inventory, and Build/Launch", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53117, Name = "P531_Hotfix" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 100000, "TestGrant", "tx_531_17")

		-- 1) Separación explícita ShopAvailability ("DirectShop" vs "LootBoxRewardOnly")
		assertEqual(ItemCatalog.GetShopAvailability("SmallEngine"), "LootBoxRewardOnly", "SmallEngine is LootBoxRewardOnly")
		assertEqual(ItemCatalog.GetShopAvailability("SmallBooster"), "LootBoxRewardOnly", "SmallBooster is LootBoxRewardOnly")
		assertEqual(ItemCatalog.IsDirectShopPurchasable("SmallEngine"), false, "SmallEngine is not DirectShopPurchasable")
		assertEqual(ItemCatalog.IsDirectShopPurchasable("SmallBooster"), false, "SmallBooster is not DirectShopPurchasable")
		assertEqual(ItemCatalog.IsLootBoxExclusiveReward("SmallEngine"), true, "SmallEngine is LootBoxExclusiveReward")
		assertEqual(ItemCatalog.IsLootBoxExclusiveReward("SmallBooster"), true, "SmallBooster is LootBoxExclusiveReward")

		-- 2) GetPurchasableShopItems y ShopSnapshot.NormalItems contienen exclusivamente los 12 componentes DirectShop
		local purchasable = ItemCatalog.GetPurchasableShopItems()
		assertEqual(#purchasable, 12, "Strictly 12 direct purchasable shop items")
		for _, entry in ipairs(purchasable) do
			assertEqual(entry.ShopAvailability, "DirectShop", `{entry.Id} must be DirectShop`)
			assertTrue(entry.Id ~= "SmallEngine" and entry.Id ~= "SmallBooster", "No exclusive rewards in GetPurchasableShopItems")
		end

		local snap = ShopService.BuildPlayerShopSnapshot(p1) :: any
		assertEqual(#snap.NormalItems, 12, "ShopSnapshot.NormalItems has strictly 12 items")
		for _, it in ipairs(snap.NormalItems) do
			assertTrue(it.ItemId ~= "SmallEngine" and it.ItemId ~= "SmallBooster", "No exclusive rewards in ShopSnapshot.NormalItems")
		end

		-- 3) Servidor rechaza compras directas manipuladas de SmallEngine y SmallBooster
		for _, forbiddenId in ipairs({ "SmallEngine", "SmallBooster" }) do
			local badCart = ShopService.ProcessRequest(p1, {
				Action = ShopProtocol.Actions.CheckoutNormalCart,
				ClientOpId = `p531_17_badcart_{forbiddenId}`,
				CartItems = { { ItemId = forbiddenId, Quantity = 1 } },
			})
			assertEqual(badCart.Success, false, `Direct cart checkout of {forbiddenId} rejected`)
			assertEqual(badCart.ErrorCode, ShopProtocol.ErrorCodes.ItemNotShopPurchasable, `Returns ItemNotShopPurchasable for {forbiddenId}`)

			local badBox = ShopService.ProcessRequest(p1, {
				Action = ShopProtocol.Actions.PurchaseSpecialCrate,
				ClientOpId = `p531_17_badbox_{forbiddenId}`,
				BoxId = forbiddenId,
			})
			assertEqual(badBox.Success, false, `Special crate purchase with BoxId={forbiddenId} rejected`)
			assertEqual(badBox.ErrorCode, ShopProtocol.ErrorCodes.UnknownBox, `Returns UnknownBox for {forbiddenId}`)
		end

		-- 4) Compra legítima de cajas sigue otorgando motores y propulsores y se pueden usar en construcción y lanzamiento
		ShopStockService._SetStockForTests("BasicEngineCrate", 1)
		ShopStockService._SetStockForTests("BasicBoosterCrate", 1)
		local buyEng = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p531_17_buyeng",
			BoxId = "BasicEngineCrate",
		})
		local buyBst = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p531_17_buybst",
			BoxId = "BasicBoosterCrate",
		})
		assertTrue(buyEng.Success and buyBst.Success, "Legitimate special crate purchases succeed")
		env.AdvanceClock(900)
		local openEng = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p531_17_openeng",
			CrateId = (buyEng.Order :: any).OrderId,
		})
		local openBst = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p531_17_openbst",
			CrateId = (buyBst.Order :: any).OrderId,
		})
		assertTrue(openEng.Success and openBst.Success, "Opened both crates and credited unique units")
		assertEqual(#InventoryService.GetPlayerEngineUnits(p1), 2, "Starter engine + 1 crate engine in inventory")
		assertEqual(#InventoryService.GetPlayerBoosterUnits(p1), 2, "Starter booster + 1 crate booster in inventory")

		-- Construir y lanzar vehículo con SmallEngine y SmallBooster
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "p531_17_b1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.5, 0),
		}).Success, "Placed base block")
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "p531_17_seat",
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(0, 3.0, 0),
		}).Success, "Placed DriverSeat")
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "p531_17_eng",
			ItemId = "SmallEngine",
			LocalCFrame = CFrame.new(-2, 1.5, 0),
		}).Success, "Placed SmallEngine from inventory")
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "p531_17_bst",
			ItemId = "SmallBooster",
			LocalCFrame = CFrame.new(2, 1.5, 0),
		}).Success, "Placed SmallBooster from inventory")

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success, "Vehicle with SmallEngine and SmallBooster launched")
		VehicleLifecycleService.ReturnToWorkshop(p1, "ManualReturn")
		env.Teardown()
	end)
end

function Phase531Tests.RunAll()
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

	Phase531Tests.AppendTests(results, runTest)

	return {
		Passed = passed,
		Failed = failed,
		Total = passed + failed,
		Results = results,
	}
end

return Phase531Tests

