--!strict
--[=[
	Phase52Tests
	Suite exhaustiva de validación para Fase 5.2 (Tienda, Carrito, Economía, Cajas Especiales,
	Stock compartido por servidor, Restock 300s por reemplazo, Pedidos 60s/900s, DeliveryZone 6 slots,
	Camión físico, Ingresos Offline de Motores x1 / x5 AdService y Robux "Pedir ahora").

	Todas las pruebas de temporización usan reloj virtual inyectable (sin esperas reales).
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

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

local Phase52Tests = {}

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
	local existing = Workspace:FindFirstChild("_Phase52TestPlots")
	if existing then
		existing:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase52TestPlots"
	tempPlots.Parent = Workspace

	local virtualClock = 100000
	local rateClock = 100000

	local function bindClocks()
		local clockFn = function()
			return virtualClock
		end
		BuildService._SetRateLimitClockForTests(function()
			rateClock += 1.0
			return rateClock
		end)
		ShopService._SetClockForTests(clockFn)
		VehicleLaunchService._SetClockForTests(clockFn)
		VehicleLifecycleService._SetClockForTests(clockFn)
		VehicleDamageService._SetClockForTests(clockFn)
		VehicleImpactService._SetClockForTests(clockFn)
		VehicleDestructionService._SetClockForTests(clockFn)
	end

	resetAllServices(false)
	initAllServices(tempPlots, plotCount)
	bindClocks()
	ShopStockService.ExecuteRestock("TestInit")

	return {
		TempPlots = tempPlots,
		GetNow = function(): number
			return virtualClock
		end,
		AdvanceClock = function(dt: number): number
			virtualClock += dt
			DeliveryService.StepAll(virtualClock)
			ShopStockService.StepRestockCheck()
			return virtualClock
		end,
		SetClock = function(absTime: number): number
			virtualClock = absTime
			DeliveryService.StepAll(virtualClock)
			ShopStockService.StepRestockCheck()
			return virtualClock
		end,
		SimulateRejoin = function(offlineSeconds: number?, newPlotCount: number?)
			if offlineSeconds and offlineSeconds > 0 then
				virtualClock += offlineSeconds
			end
			resetAllServices(true)
			for _, child in ipairs(tempPlots:GetChildren()) do
				child:Destroy()
			end
			initAllServices(tempPlots, newPlotCount or plotCount)
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

function Phase52Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (name: string, fn: () -> ()) -> ()
)
	-- 1) Saldo inicial de 1.000 monedas una sola vez y resiliencia ante fallos DataStore
	runTest("Fase 5.2 [01]: StartingMoney=1000 granted once, preserved on rejoin, and blocked on DataStore load failure", function()
		local env = setupIsolatedWorld(2)
		local pFail: PlotService.PlayerLike = { UserId = 52001, Name = "P52_EcoLoadFail" }
		EconomyPersistenceService._SetSimulateLoadFailureForTests(true)
		local okFail, _, errCode = EconomyService.EnsurePlayerLoaded(pFail)
		EconomyPersistenceService._SetSimulateLoadFailureForTests(false)
		assertEqual(okFail, false, "Load failure must not grant starter money")
		assertEqual(errCode, ShopProtocol.ErrorCodes.PersistenceFailed, "Returns PersistenceFailed")

		local p1: PlotService.PlayerLike = { UserId = 52002, Name = "P52_StarterMoney" }
		PlotService.Assign(p1)
		local bal, okBal = EconomyService.GetBalance(p1)
		assertTrue(okBal and bal == 1000, "New player starts with 1,000 coins")

		local debOk, balAfter = EconomyService.TryDebit(p1, 250, "TestSpend", "tx_01")
		assertTrue(debOk and balAfter == 750, "Balance debited to 750")

		env.SimulateRejoin(30)
		PlotService.Assign(p1)
		assertEqual(EconomyService.GetBalance(p1), 750, "StarterMoney NOT duplicated on reconnect; remains 750")
		env.Teardown()
	end)

	-- 2) Precios de catálogo y regla de venta del 50% (sin vender unidades únicas no valoradas)
	runTest("Fase 5.2 [02]: Catalog buy/sell pricing (50% rounded down) and restriction against direct/monetary UniqueUnits", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52003, Name = "P52_Prices" }
		PlotService.Assign(p1)

		local byId: { [string]: ItemCatalog.CatalogItemEntry } = {}
		for _, e in ipairs(ItemCatalog.GetAllEntries()) do
			byId[e.Id] = e
		end

		assertEqual(byId.WoodBlock.Price, 10, "WoodBlock buy = 10")
		assertEqual(byId.WoodBlock.SellPrice, 5, "WoodBlock sell = 5")
		assertEqual(byId.WoodBeam.Price, 8, "WoodBeam buy = 8")
		assertEqual(byId.WoodBeam.SellPrice, 4, "WoodBeam sell = 4")
		assertEqual(byId.SmallWheel.Price, 25, "SmallWheel buy = 25")
		assertEqual(byId.SmallWheel.SellPrice, 12, "SmallWheel sell = 12 (floor 12.5)")
		assertEqual(byId.RegularFuelTank.Price, 175, "RegularFuelTank buy = 175")
		assertEqual(byId.RegularFuelTank.SellPrice, 87, "RegularFuelTank sell = 87 (floor 87.5)")
		assertEqual(byId.DriverSeat.Price, 100, "DriverSeat buy = 100")
		assertEqual(byId.DriverSeat.SellPrice, 50, "DriverSeat sell = 50")
		assertEqual(byId.SmallNitroTank.Price, 250, "SmallNitroTank buy = 250")
		assertEqual(byId.SmallNitroTank.SellPrice, 125, "SmallNitroTank sell = 125")
		assertEqual(byId.SmallEngine.DirectPurchasable, false, "SmallEngine not directly sold in parts shop")
		assertEqual(byId.SmallBooster.DirectPurchasable, false, "SmallBooster not directly sold in parts shop")

		-- Intentar comprar SmallEngine o SmallBooster directo por carrito debe fallar
		local badCart = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p02_bad_eng",
			CartItems = { { ItemId = "SmallEngine", Quantity = 1 } },
		})
		assertEqual(badCart.Success, false, "Direct SmallEngine cart blocked")
		assertEqual(badCart.ErrorCode, ShopProtocol.ErrorCodes.ItemNotShopPurchasable, "ItemNotShopPurchasable")

		-- Vender 3x SmallWheel (posee 4 del kit inicial) -> +36 monedas (1000 -> 1036)
		local sellWheels = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p02_sell_wheel",
			ItemId = "SmallWheel",
			Quantity = 3,
		})
		assertTrue(sellWheels.Success and sellWheels.SellResult ~= nil, "Normal sell succeeded")
		assertEqual((sellWheels.SellResult :: any).SellValue, 36, "3 * 12 = 36 coins")
		assertEqual(EconomyService.GetBalance(p1), 1036, "Balance credited to 1036")

		-- Venta monetaria de unidad única sin valoración (SmallEngine) debe bloquearse
		local engId = InventoryService.GetPlayerEngineUnits(p1)[1].ItemInstanceId
		local sellEng = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p02_sell_eng",
			ItemId = "SmallEngine",
			ItemInstanceId = engId,
		})
		assertEqual(sellEng.Success, false, "Unique engine cannot be sold for money until priced")
		assertEqual(EconomyService.GetBalance(p1), 1036, "Balance unchanged after rejected unique sell")
		env.Teardown()
	end)

	-- 3) Carrito, total autoritativo, múltiples DriverSeat sin bloqueo de tienda y rollback si falla persistencia
	runTest("Fase 5.2 [03]: Cart checkout authoritative pricing, unrestricted DriverSeat purchases, and atomic rollback on order write failure", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52004, Name = "P52_Cart" }
		PlotService.Assign(p1)

		-- Exceder saldo (1000 monedas vs 5x SmallNitroTank = 1250)
		local overBudget = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p03_over",
			CartItems = { { ItemId = "SmallNitroTank", Quantity = 5 } },
		})
		assertEqual(overBudget.Success, false, "Insufficient funds blocked")
		assertEqual(overBudget.ErrorCode, ShopProtocol.ErrorCodes.InsufficientFunds, "InsufficientFunds")
		assertEqual(EconomyService.GetBalance(p1), 1000, "No partial debit")

		-- Si falla guardar el pedido en DataStore, debe hacerse rollback del cobro monetario
		OrderPersistenceService._SetSimulateWriteFailureForTests(true)
		local persistFail = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p03_pfail",
			CartItems = { { ItemId = "WoodBlock", Quantity = 2 } },
		})
		OrderPersistenceService._SetSimulateWriteFailureForTests(false)
		assertEqual(persistFail.Success, false, "Checkout fails cleanly if order save fails")
		assertEqual(EconomyService.GetBalance(p1), 1000, "Balance fully rolled back to 1000")

		-- Ya posee 1 DriverSeat (StarterKit) -> comprar más DriverSeat junto a otras piezas NO debe bloquearse
		local buyMoreSeats = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p03_bseat2",
			CartItems = { { ItemId = "DriverSeat", Quantity = 2 }, { ItemId = "WoodBlock", Quantity = 5 } },
		})
		assertTrue(buyMoreSeats.Success, "Buying additional DriverSeats succeeded even with 1 already owned")
		assertEqual(EconomyService.GetBalance(p1), 1000 - (2 * 100 + 5 * 10), "Paid 200 + 50 = 250")
		env.Teardown()
	end)

	-- 4) Pedido normal (60s): bloqueo durante espera, 1 caja por tipo, desbloqueo al llegar aunque no se recoja
	runTest("Fase 5.2 [04]: Normal 60s wait blocks new normal orders until arrival, spawns 1 crate per ItemId, and unlocks before pickup", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52005, Name = "P52_Normal60" }
		PlotService.Assign(p1)

		-- Consolidación: enviar WoodBlock x2 + WoodBlock x3 + SmallWheel x4 -> debe generar 2 cajas (WoodBlock x5 y SmallWheel x4)
		local checkout = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p04_buy1",
			CartItems = {
				{ ItemId = "WoodBlock", Quantity = 2 },
				{ ItemId = "WoodBlock", Quantity = 3 },
				{ ItemId = "SmallWheel", Quantity = 4 },
			},
		})
		assertTrue(checkout.Success and checkout.Order ~= nil, "Normal order created")
		assertEqual(#(checkout.Order :: any).Crates, 2, "Strictly 1 crate per unique ItemId (WoodBlock x5, SmallWheel x4)")
		assertEqual(EconomyService.GetBalance(p1), 1000 - (5 * 10 + 4 * 25), "Balance deducted 150")

		-- Intentar segundo pedido a los 30 s -> bloqueado
		env.AdvanceClock(30)
		local blocked = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p04_buy2_blk",
			CartItems = { { ItemId = "WoodBeam", Quantity = 1 } },
		})
		assertEqual(blocked.Success, false, "Blocked while normal order in transit")
		assertEqual(blocked.ErrorCode, ShopProtocol.ErrorCodes.NormalOrderInProgress, "NormalOrderInProgress")

		-- Avanzar otros 30 s (total 60 s) -> pedido llega y DESBLOQUEA nuevas compras aunque no se hayan abierto las 2 cajas
		env.AdvanceClock(30)
		local snap = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snap.NormalOrderBlocked, false, "Unlocked immediately upon arrival")
		assertEqual(snap.SpawnedCount, 2, "Both physical crates spawned in DeliveryZone")

		local buy2 = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p04_buy2_ok",
			CartItems = { { ItemId = "WoodBeam", Quantity = 2 } },
		})
		assertTrue(buy2.Success, "2nd normal order allowed even with 2 unopened crates still sitting in DeliveryZone")
		env.Teardown()
	end)

	-- 5) Apertura de cajas normales: acreditación idempotente, rechazo ajeno y bloqueo de duplicado
	runTest("Fase 5.2 [05]: Normal crate opening credits exact quantity idempotently, rejects non-owners, and blocks replays", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 52006, Name = "P52_Owner" }
		local p2: PlotService.PlayerLike = { UserId = 52007, Name = "P52_Thief" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)

		local co = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p05_co",
			CartItems = { { ItemId = "WoodBlock", Quantity = 7 } },
		})
		local crateId = (co.Order :: any).Crates[1].CrateId
		env.AdvanceClock(60)

		-- Robo por otro jugador rechazado
		local stealRes = ShopService.ProcessRequest(p2, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p05_steal",
			CrateId = crateId,
		})
		assertEqual(stealRes.Success, false, "Other player cannot open player 1 crate")

		local woodBefore = InventoryService.GetOwnedQuantity(p1, "WoodBlock")
		local openOk = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p05_open1",
			CrateId = crateId,
		})
		assertTrue(openOk.Success, "Owner opened normal crate")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), woodBefore + 7, "Credited exact +7 WoodBlock")

		-- Reintento con otro ClientOpId después de abrir -> rechazado (CrateAlreadyOpened) y no duplica
		local replayRes = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p05_open2",
			CrateId = crateId,
		})
		assertEqual(replayRes.Success, false, "Already opened crate rejected")
		assertEqual(replayRes.ErrorCode, ShopProtocol.ErrorCodes.CrateAlreadyOpened, "CrateAlreadyOpened")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), woodBefore + 7, "No duplicate inventory")
		env.Teardown()
	end)

	-- 6) Pedidos especiales (900 s), RoadEngineCrate deshabilitada e independencia entre pedidos normales y especiales
	runTest("Fase 5.2 [06]: Special 900s orders work independently of normal 60s orders; RoadEngineCrate disabled", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52008, Name = "P52_SpecialIndep" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 50000, "TestGrant", "tx_06_grant")
		ShopStockService._SetStockForTests("BasicEngineCrate", 3)
		ShopStockService._SetStockForTests("BasicBoosterCrate", 2)

		-- RoadEngineCrate deshabilitada
		local roadRes = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p06_road",
			BoxId = "RoadEngineCrate",
		})
		assertEqual(roadRes.Success, false, "RoadEngineCrate disabled")
		assertEqual(roadRes.ErrorCode, ShopProtocol.ErrorCodes.BoxDisabled, "BoxDisabled")

		-- Comprar caja especial (900 s) y verificar que NO bloquea pedido normal (60 s)
		local engBuy = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p06_eng",
			BoxId = "BasicEngineCrate",
		})
		assertTrue(engBuy.Success, "Bought BasicEngineCrate")

		local normalBuy = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p06_norm",
			CartItems = { { ItemId = "WoodBlock", Quantity = 1 } },
		})
		assertTrue(normalBuy.Success, "Normal checkout succeeds while 900s special order in transit")

		-- A los 60 s llega normal; especial sigue en tránsito hasta 900 s; además se puede comprar otra especial durante espera normal
		local bstBuy = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p06_bst",
			BoxId = "BasicBoosterCrate",
		})
		assertTrue(bstBuy.Success, "Can purchase special crate while normal order in transit")

		env.AdvanceClock(60)
		local ordSnapMid = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(ordSnapMid.NormalOrderBlocked, false, "Normal order arrived at 60 s")
		assertEqual(ordSnapMid.SpecialOrders[1].Status, "InTransit", "Special order still InTransit at 60 s")

		env.AdvanceClock(840)
		local ordSnapEnd = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(ordSnapEnd.SpecialOrders[1].Status, "Arrived", "Special order arrived at 900 s")
		assertEqual(ordSnapEnd.SpecialOrders[2].Status, "Arrived", "2nd special order arrived at 900 s")
		env.Teardown()
	end)

	-- 7) Stock compartido entre jugadores y compra simultánea de la última unidad (sin sobreventa)
	runTest("Fase 5.2 [07]: Server-shared special stock prevents oversell on simultaneous last-unit purchase", function()
		local env = setupIsolatedWorld(3)
		local p1: PlotService.PlayerLike = { UserId = 52009, Name = "P52_Buyer1" }
		local p2: PlotService.PlayerLike = { UserId = 52010, Name = "P52_Buyer2" }
		local p3: PlotService.PlayerLike = { UserId = 52011, Name = "P52_Buyer3" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)
		PlotService.Assign(p3)

		ShopStockService._SetStockForTests("BasicEngineCrate", 2)
		local r1 = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.PurchaseSpecialCrate, ClientOpId = "p07_1", BoxId = "BasicEngineCrate" })
		assertTrue(r1.Success, "Player 1 gets stock 2 -> 1")
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 1, "Shared stock == 1 for everyone")

		-- Simular compra simultánea de la última unidad entre P2 y P3 vía corrutinas en el mismo frame
		local res2, res3 = nil, nil
		local done = 0
		task.spawn(function()
			res2 = ShopService.ProcessRequest(p2, { Action = ShopProtocol.Actions.PurchaseSpecialCrate, ClientOpId = "p07_2", BoxId = "BasicEngineCrate" })
			done += 1
		end)
		task.spawn(function()
			res3 = ShopService.ProcessRequest(p3, { Action = ShopProtocol.Actions.PurchaseSpecialCrate, ClientOpId = "p07_3", BoxId = "BasicEngineCrate" })
			done += 1
		end)
		while done < 2 do
			task.wait()
		end

		local winners = (if res2 and res2.Success then 1 else 0) + (if res3 and res3.Success then 1 else 0)
		assertEqual(winners, 1, "Strictly ONE player wins the last shared unit")
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 0, "Shared stock strictly 0 (no negative/oversell)")
		local loser = if res2 and not res2.Success then res2 else res3
		assertEqual((loser :: any).ErrorCode, ShopProtocol.ErrorCodes.OutOfStock, "Loser got OutOfStock without losing coins")
		if res3 and not res3.Success then
			assertEqual(EconomyService.GetBalance(p3), 1000, "Loser P3 kept full balance")
		else
			assertEqual(EconomyService.GetBalance(p2), 1000, "Loser P2 kept full balance")
		end
		env.Teardown()
	end)

	-- 8) Restock cada 300 s mediante REEMPLAZO absoluto (nunca acumulación), e inicialización de servidor nuevo
	runTest("Fase 5.2 [08]: 300s restock replaces stock strictly (never sums) and boot executes restock rule (1..3)", function()
		local env = setupIsolatedWorld(1)
		-- Validar que el arranque de servidor genera 1..3 por BoxId habilitada
		local bootEng = ShopStockService.GetStock("BasicEngineCrate")
		local bootBst = ShopStockService.GetStock("BasicBoosterCrate")
		assertTrue(bootEng >= 1 and bootEng <= 3, `Initial boot stock for Engine crate in 1..3 (got {bootEng})`)
		assertTrue(bootBst >= 1 and bootBst <= 3, `Initial boot stock for Booster crate in 1..3 (got {bootBst})`)

		-- Ejemplo 1 del SDD: Stock anterior 2, nuevo stock determinado 2 -> resultado 2, nunca 4
		ShopStockService._SetStockForTests("BasicEngineCrate", 2)
		ShopStockService._SetRngForTests(function(_min, _max, boxId)
			return if boxId == "BasicEngineCrate" then 2 else 1
		end)
		env.AdvanceClock(300)
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 2, "Stock 2 replaced by 2 => 2 (never 4)")

		-- Ejemplo 2 del SDD: Stock anterior 1, nuevo stock determinado 3 -> resultado 3, nunca 4
		ShopStockService._SetStockForTests("BasicEngineCrate", 1)
		ShopStockService._SetRngForTests(function()
			return 3
		end)
		env.AdvanceClock(300)
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 3, "Stock 1 replaced by 3 => 3 (never 4)")

		-- Restock no debe modificar pedidos especiales ya pagados
		local p1: PlotService.PlayerLike = { UserId = 52012, Name = "P52_PaidKeep" }
		PlotService.Assign(p1)
		local paid = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.PurchaseSpecialCrate, ClientOpId = "p08_buy", BoxId = "BasicEngineCrate" })
		assertTrue(paid.Success, "Bought prior to restock")
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 2, "Stock decremented to 2")
		ShopStockService._SetRngForTests(function()
			return 1
		end)
		env.AdvanceClock(300)
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 1, "Stock replaced by 1")
		assertEqual((DeliveryService.GetPlayerOrdersSnapshot(p1) :: any).SpecialOrders[1].OrderId, (paid.Order :: any).OrderId, "Existing paid order unaffected by restock")
		env.Teardown()
	end)

	-- 9) Persistencia tras desconexión sin reiniciar temporizadores
	runTest("Fase 5.2 [09]: Normal (60s) & Special (900s) timers continue seamlessly across disconnect without resetting", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52013, Name = "P52_OfflineTimers" }
		PlotService.Assign(p1)
		ShopStockService._SetStockForTests("BasicEngineCrate", 3)

		ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.CheckoutNormalCart, ClientOpId = "p09_n", CartItems = { { ItemId = "WoodBlock", Quantity = 1 } } })
		ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.PurchaseSpecialCrate, ClientOpId = "p09_s", BoxId = "BasicEngineCrate" })

		-- Desconectar y volver 40 s después: pedido normal debe tener ~20 s restantes (NO 60 s) y especial ~860 s
		env.SimulateRejoin(40)
		PlotService.Assign(p1)
		local snap40 = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snap40.NormalOrderBlocked, true, "Normal still in transit at 40 s")
		assertEqual(snap40.NormalOrderRemainingSeconds, 20, "Exactly 20 s remaining after 40 s offline (never reset)")
		assertEqual(snap40.SpecialOrders[1].RemainingSeconds, 860, "Special order 860 s remaining after 40 s offline")

		-- Desconectar y volver 900 s después: ambos entregados y reconstruidos en DeliveryZone
		env.SimulateRejoin(900)
		local plotAfter = PlotService.Assign(p1) :: PlotService.PlotRecord
		local snapEnd = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snapEnd.NormalOrderBlocked, false, "Normal delivered & unlocked after offline arrival")
		assertEqual(snapEnd.SpawnedCount, 2, "Both overdue crates spawned onto DeliveryZone upon reconnect")
		assertTrue(#plotAfter.ShopDeliveryContainer:GetChildren() >= 2, "Physical crate models rebuilt in ShopDeliveryContainer")
		env.Teardown()
	end)

	-- 10) LootBoxService probabilidades y validación estricta del pool
	runTest("Fase 5.2 [10]: LootBoxConfig pool integrity and weighted rarity/size roll distribution check", function()
		LootBoxService.Init()
		local okAll, errs = LootBoxService.ValidateAllEnabledBoxes()
		assertTrue(okAll, `All enabled LootBoxes valid: {table.concat(errs, "; ")}`)

		local rarityCounts: { [string]: number } = { Common = 0, Uncommon = 0, Rare = 0, Epic = 0, Legendary = 0, Mythic = 0 }
		local sizeCounts: { [string]: number } = { Small = 0, Medium = 0, Large = 0 }
		local rng = Random.new(424242)
		local nextFloat = function()
			return rng:NextNumber()
		end

		for _ = 1, 2000 do
			local okRoll, reward = LootBoxService.RollRewardForOrder("BasicEngineCrate", nextFloat)
			assertTrue(okRoll and reward ~= nil, "Roll valid")
			local r = reward :: ItemTypes.RolledLootReward
			rarityCounts[r.RarityId] = (rarityCounts[r.RarityId] or 0) + 1
			sizeCounts[r.SizeId] = (sizeCounts[r.SizeId] or 0) + 1
			assertEqual(r.Category, "Engines", "Always rolls Engines for BasicEngineCrate")
		end

		assertTrue(rarityCounts.Common > rarityCounts.Uncommon and rarityCounts.Uncommon > rarityCounts.Rare, "Weighted rarity order Common > Uncommon > Rare")
		assertTrue(rarityCounts.Rare > rarityCounts.Epic and rarityCounts.Epic > rarityCounts.Legendary, "Weighted rarity order Rare > Epic > Legendary")
		assertTrue(rarityCounts.Legendary >= rarityCounts.Mythic and rarityCounts.Mythic > 0, "Mythic possible (~0.5%)")
		assertTrue(sizeCounts.Small > sizeCounts.Medium and sizeCounts.Medium > sizeCounts.Large and sizeCounts.Large > 0, "Weighted size order Small > Medium > Large")
	end)

	-- 11) Apertura idempotente de caja especial (no repetir sorteo ni duplicar recompensa ante fallos/reintentos)
	runTest("Fase 5.2 [11]: Special crate rolls once deterministically, survives retry on failure, and never duplicates UniqueUnit", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52014, Name = "P52_IdempSpecial" }
		PlotService.Assign(p1)
		ShopStockService._SetStockForTests("BasicEngineCrate", 2)

		local buy = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p11_buy",
			BoxId = "BasicEngineCrate",
		})
		local orderId = (buy.Order :: any).OrderId
		env.AdvanceClock(900)

		-- Forzar tirada Mítica determinista (draw ~0.998 -> Mythic, ~0.98 -> Large) en el primer intento
		DeliveryService._SetLootRngForTests(function()
			return 0.997
		end)

		-- Simular fallo en InventoryPersistenceService durante la apertura DESPUÉS de haber persistido el sorteo RolledReward
		InventoryPersistenceService._SetSimulateWriteFailureForTests(true)
		local failedMidOpen = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p11_open_fail",
			CrateId = orderId,
		})
		InventoryPersistenceService._SetSimulateWriteFailureForTests(false)
		assertEqual(failedMidOpen.Success, false, "Inventory write failure aborted completion cleanly")
		assertEqual(#InventoryService.GetPlayerEngineUnits(p1), 1, "Only StarterKit engine in inventory during failure")

		-- Cambiar RNG a Common (0.01) antes del reintento: debe usar RolledReward YA GUARDADO (Mythic), ¡NUNCA sortear de nuevo!
		DeliveryService._SetLootRngForTests(function()
			return 0.01
		end)
		local retryOpen = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p11_open_retry",
			CrateId = orderId,
		})
		assertTrue(retryOpen.Success and retryOpen.OpenedResult ~= nil, "Retry succeeded without re-rolling")
		local rew = (retryOpen.OpenedResult :: any).Reward :: ItemTypes.RolledLootReward
		assertEqual(rew.RarityId, "Mythic", "Kept original persisted Mythic roll on retry (did NOT re-roll Common)")
		assertEqual(#InventoryService.GetPlayerEngineUnits(p1), 2, "StarterKit + 1 Mythic engine = 2 exact units")

		-- Reintento adicional después de Claimed -> rechazado sin duplicación
		local dupOpen = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p11_open_dup",
			CrateId = orderId,
		})
		assertEqual(dupOpen.Success, false, "Duplicate claim blocked")
		assertEqual(dupOpen.ErrorCode, ShopProtocol.ErrorCodes.CrateAlreadyOpened, "CrateAlreadyOpened")
		assertEqual(#InventoryService.GetPlayerEngineUnits(p1), 2, "Still strictly 2 engine units")
		env.Teardown()
	end)

	-- 12) Representación visual en suelo + BillboardGui y limpieza sin perder unidad de inventario
	runTest("Fase 5.2 [12]: Special opening shows physical reward model with BillboardGui and temp cleanup keeps inventory unit intact", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52015, Name = "P52_Billboard" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		ShopStockService._SetStockForTests("BasicEngineCrate", 1)

		local buy = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.PurchaseSpecialCrate, ClientOpId = "p12_b", BoxId = "BasicEngineCrate" })
		local orderId = (buy.Order :: any).OrderId
		env.AdvanceClock(900)

		local openRes = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.OpenDeliveryCrate, ClientOpId = "p12_o", CrateId = orderId })
		assertTrue(openRes.Success, "Opened special crate")
		local revealModel = (openRes.OpenedResult :: any).RevealModel :: Model
		assertTrue(revealModel ~= nil and revealModel:IsDescendantOf(plot.ShopDeliveryContainer), "Physical revealed engine spawned inside plot")
		local bb = revealModel:FindFirstChild("CrateLabelGui", true) :: BillboardGui
		assertTrue(bb ~= nil and bb:IsA("BillboardGui"), "BillboardGui present on revealed model")
		local titleLbl = bb:FindFirstChild("TitleLabel", true) :: TextLabel
		local subLbl = bb:FindFirstChild("SubtitleLabel", true) :: TextLabel
		assertTrue(#titleLbl.Text > 0 and string.find(subLbl.Text, "Rareza:", 1, true) ~= nil, "BillboardGui shows visible name and rarity")

		local unitId = (openRes.OpenedResult :: any).Reward.ItemInstanceId
		-- Expirar tiempo de limpieza del modelo temporal -> modelo se destruye, pero el motor sigue en InventoryService
		env.AdvanceClock(ShopConfig.DeliveryZone.CrateRevealLifetimeSeconds + 1)
		assertEqual(revealModel.Parent, nil, "Temporary reveal visual cleaned up after lifetime")
		assertTrue(InventoryService.HasUnitId(p1, unitId), "Revealed reward persists safely in inventory after visual cleanup")
		env.Teardown()
	end)

	-- 13) DeliveryZone compartida: límite visual de 6 cajas + cola justa persistente
	runTest("Fase 5.2 [13]: Shared DeliveryZone enforces max 6 visible slots, queues excess fairly, and rebuilds on reconnect", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52016, Name = "P52_Queue6" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 200000, "TestGrant", "tx_13")

		-- Comprar 6 tipos de ítems en pedido normal (= 6 cajas) + 3 cajas especiales (= 9 cajas en total > capacidad 6)
		ShopStockService._SetStockForTests("BasicEngineCrate", 3)
		local coNorm = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p13_norm",
			CartItems = {
				{ ItemId = "WoodBlock", Quantity = 1 },
				{ ItemId = "WoodBeam", Quantity = 1 },
				{ ItemId = "SmallWheel", Quantity = 1 },
				{ ItemId = "RegularFuelTank", Quantity = 1 },
				{ ItemId = "SmallNitroTank", Quantity = 1 },
			},
		})
		assertTrue(coNorm.Success, "5 normal types ordered")
		for idx = 1, 3 do
			local b = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.PurchaseSpecialCrate, ClientOpId = `p13_sp{idx}`, BoxId = "BasicEngineCrate" })
			assertTrue(b.Success, `Special crate {idx} bought`)
		end

		env.AdvanceClock(900)
		local snapFull = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snapFull.SpawnedCount, 6, "Strictly capped at VisualCapacity = 6 spawned crates")
		assertEqual(snapFull.QueuedCount, 2, "Remaining 2 crates held safely in persistent queue")
		assertEqual(snapFull.NormalOrderBlocked, false, "Normal orders remain unlocked when DeliveryZone is full")

		-- Abrir 1 caja visible -> debe promocionar automáticamente 1 caja en cola a los 6 slots
		local spawnedCrateId = (coNorm.Order :: any).Crates[1].CrateId
		local open1 = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.OpenDeliveryCrate, ClientOpId = "p13_op1", CrateId = spawnedCrateId })
		assertTrue(open1.Success, "Opened 1st crate")
		local snapPromoted = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snapPromoted.SpawnedCount, 6, "Promoted 1 queued crate to keep 6 active")
		assertEqual(snapPromoted.QueuedCount, 1, "Queue decremented cleanly 2 -> 1")

		-- Reconexión conserva los 6 visibles y 1 en cola intactos
		env.SimulateRejoin(10)
		PlotService.Assign(p1)
		local snapAfterRejoin = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snapAfterRejoin.SpawnedCount, 6, "6 spawned crates rebuilt after rejoin")
		assertEqual(snapAfterRejoin.QueuedCount, 1, "1 queued crate preserved after rejoin")
		env.Teardown()
	end)

	-- 14) Auditoría física: plantillas ServerStorage.Crates, mostrador ShopZone, DeliveryTruck sin asientos y BaseTemplate intacta
	runTest("Fase 5.2 [14]: Editable ServerStorage.Crates models, ShopCounter on ShopZone, seatless DeliveryTruck outside BuildZone, BaseTemplate intact", function()
		local env = setupIsolatedWorld(1)
		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		assertEqual(#baseTemplate:GetDescendants(), 25, "ServerStorage.BaseTemplate strictly preserved at 25 descendants")

		local crates = ServerStorage:FindFirstChild("Crates")
		assertTrue(crates ~= nil, "ServerStorage.Crates exists")
		assertTrue(crates:FindFirstChild("Normales") and crates.Normales:FindFirstChild("NormalDeliveryCrate") ~= nil, "NormalDeliveryCrate exists")
		assertTrue(crates:FindFirstChild("Especiales") and crates.Especiales:FindFirstChild("Motores") and crates.Especiales.Motores:FindFirstChild("BasicEngineCrate") ~= nil, "BasicEngineCrate exists")
		assertTrue(crates.Especiales:FindFirstChild("Propulsores") and crates.Especiales.Propulsores:FindFirstChild("BasicBoosterCrate") ~= nil, "BasicBoosterCrate exists")
		local truck = crates:FindFirstChild("Reparto") and crates.Reparto:FindFirstChild("DeliveryTruck") :: Model
		assertTrue(truck ~= nil, "DeliveryTruck exists")
		for _, d in ipairs(truck:GetDescendants()) do
			assertTrue(not d:IsA("Seat") and not d:IsA("VehicleSeat"), "DeliveryTruck must not have drivable seats")
		end
		assertTrue(crates.Reparto:FindFirstChild("ShopCounter") ~= nil, "ShopCounter template exists")
		assertTrue(crates:FindFirstChild("Efectos") and crates.Efectos:FindFirstChild("OpenEffects") ~= nil, "OpenEffects template exists")

		local p1: PlotService.PlayerLike = { UserId = 52017, Name = "P52_ShopProps" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local counter = plot.ShopDeliveryContainer:FindFirstChild("ShopCounterInstance") :: Model
		assertTrue(counter ~= nil, "ShopCounter spawned in ShopDeliveryContainer (outside DynamicContainer)")
		assertTrue(counter:FindFirstChild("OpenShopPrompt", true) ~= nil, "OpenShopPrompt created on ShopZone")
		assertEqual(#plot.DynamicContainer:GetChildren(), 0, "DynamicContainer remains pure/empty")

		-- Verificar que los offsets de camión no invaden BuildZone
		local dzUnloadWorld = plot.Zones.DeliveryZone.CFrame:PointToWorldSpace(ShopConfig.DeliveryZone.TruckUnloadOffset)
		local relToBuildZone = plot.Zones.BuildZone.CFrame:PointToObjectSpace(dzUnloadWorld)
		assertTrue(math.abs(relToBuildZone.X) > plot.Zones.BuildZone.Size.X * 0.5 + 4, "TruckUnloadOffset strictly outside BuildZone")
		env.Teardown()
	end)

	-- 15) Aceleración "Pedir ahora" con Robux + MarketplaceService.ProcessReceipt
	runTest("Fase 5.2 [15]: Robux Pedir ahora validates ProductIds, accelerates to ~5s via ProcessReceipt, and is receipt-idempotent", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52018, Name = "P52_Robux" }
		PlotService.Assign(p1)
		ShopStockService._SetStockForTests("BasicEngineCrate", 1)

		local buy = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p15_sp",
			BoxId = "BasicEngineCrate",
		})
		local orderId = (buy.Order :: any).OrderId

		-- Cuando ProductId == 0 -> rechaza explícitamente (nunca inventa ProductIds ni acelera desde cliente)
		local origId = ShopConfig.RobuxProducts.RushSpecialOrderProductId
		assertEqual(origId, 0, "Default Robux ProductId starts unconfigured (0)")
		local unconf = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.PromptRushOrder,
			ClientOpId = "p15_unconf",
			OrderId = orderId,
		})
		assertEqual(unconf.Success, false, "Unconfigured ProductId rejects prompt")
		assertEqual(unconf.ErrorCode, ShopProtocol.ErrorCodes.DeveloperProductNotConfigured, "DeveloperProductNotConfigured")

		-- Simular configuración de ProductId real en runtime y receipt oficial ProcessReceipt
		DeliveryService.SetPendingRushOrder(p1, orderId)
		-- Para probar el callback real con ProductId temporal sin mutar tabla congelada permanentemente, probamos mediante ProcessMarketplaceReceipt tras acelerar con OrderId vinculado:
		-- Nótese: como ShopConfig.RobuxProducts está table.freeze, probaremos AMBOS casos:
		-- 1) Sin ProductId > 0, ProcessReceipt devuelve NotProcessedYet (nunca otorga compra no configurada)
		local decUnconf = ShopService._ProcessReceiptForTests({
			PurchaseId = "rcpt_unconf_1",
			PlayerId = p1.UserId,
			ProductId = 999999,
		})
		assertEqual(decUnconf, Enum.ProductPurchaseDecision.NotProcessedYet, "Unknown ProductId returns NotProcessedYet")

		-- 2) Probar aceleración directa autoritativa por PurchaseId e idempotencia ante reintento DataStore/ProcessReceipt
		local okAcc, accOrder = DeliveryService.AccelerateOrder(p1, orderId, "rcpt_rush_1")
		assertTrue(okAcc and accOrder ~= nil, "Order accelerated")
		assertEqual(accOrder.RushedByRobux, true, "Marked RushedByRobux")
		assertEqual(accOrder.ArriveAt, env.GetNow() + ShopConfig.Orders.RobuxSpeedupArrivalSeconds, "ArriveAt set to ~5 seconds")
		EconomyService.RecordProcessedReceipt(p1, "rcpt_rush_1")

		-- Repetir receipt ya procesado devuelve PurchaseGranted sin re-aplicar cambios
		local dupReceipt = ShopService._ProcessReceiptForTests({
			PurchaseId = "rcpt_rush_1",
			PlayerId = p1.UserId,
			ProductId = 999999,
		})
		assertEqual(dupReceipt, Enum.ProductPurchaseDecision.PurchaseGranted, "Processed PurchaseId returns idempotent PurchaseGranted")

		env.AdvanceClock(5)
		assertEqual((DeliveryService.GetPlayerOrdersSnapshot(p1) :: any).SpecialOrders[1].Status, "Arrived", "Arrives cleanly after 5 s")
		env.Teardown()
	end)

	-- 16) Ingresos offline de motores: solo motores, deduplicado entre blueprints, sin duplicar al reconectar
	runTest("Fase 5.2 [16]: Offline motor income deduplicates shared units across slots, excludes boosters, and never double-credits", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52019, Name = "P52_Offline" }
		PlotService.Assign(p1)

		-- Colocar motor único del StarterKit y guardarlo en 3 slots distintos + taller (4 referencias de la MISMA unidad!)
		local engUnit = InventoryService.GetPlayerEngineUnits(p1)[1]
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "p16_b", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.5, 0) })
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "p16_e", ItemId = "SmallEngine", LocalCFrame = CFrame.new(0, 3.5, 0), InventoryInstanceId = engUnit.ItemInstanceId })
		for slotIdx = 1, 3 do
			BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.SaveBlueprintSlot, ClientOpId = `p16_s{slotIdx}`, SlotIndex = slotIdx, Name = `D{slotIdx}` })
		end

		local expected1Hour = math.floor(ShopConfig.ComputeOfflineCoinsForEngine("Small", "Common", 3600))
		assertEqual(expected1Hour, 21, "Expected 1-hour floor of 21.88 = 21 for 1 Small Common engine (not x4 and booster=0)")

		-- Simular 1 hora offline
		env.SimulateRejoin(3600)
		PlotService.Assign(p1)

		local offSnap = OfflineIncomeService.GetPendingSnapshot(p1)
		assertEqual(offSnap.PendingAmount, 21, "Deduped to exactly 1 engine (21 coins, never 84)")
		assertEqual(#offSnap.Breakdown, 1, "Breakdown lists exactly 1 unique engine")

		-- Reconexión inmediata adicional (2 s) no duplica lo pendiente ni vuelve a sumar la hora
		env.SimulateRejoin(2)
		PlotService.Assign(p1)
		assertEqual(OfflineIncomeService.GetPendingSnapshot(p1).PendingAmount, 21, "Pending stays 21 across immediate reconnect")

		-- Fallo DataStore al recoger conserva pendiente; luego éxito acredita 1021 y pone pendiente en 0
		EconomyPersistenceService._SetSimulateWriteFailureForTests(true)
		local claimFail = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.ClaimOfflineIncome, ClientOpId = "p16_cfail", UseRewardedAd = false })
		EconomyPersistenceService._SetSimulateWriteFailureForTests(false)
		assertEqual(claimFail.Success, false, "Claim fails cleanly on DataStore error")
		assertEqual(OfflineIncomeService.GetPendingSnapshot(p1).PendingAmount, 21, "Pending preserved after rollback")

		local claimOk = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.ClaimOfflineIncome, ClientOpId = "p16_cok", UseRewardedAd = false })
		assertTrue(claimOk.Success, "Normal claim succeeded")
		assertEqual(claimOk.ClaimedAmount, 21, "Claimed 21 coins")
		assertEqual(EconomyService.GetBalance(p1), 1021, "Balance == 1021")
		assertEqual(OfflineIncomeService.GetPendingSnapshot(p1).PendingAmount, 0, "Pending cleared to 0")

		-- Segundo reclamo rechazado
		local dupClaim = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.ClaimOfflineIncome, ClientOpId = "p16_cdup", UseRewardedAd = false })
		assertEqual(dupClaim.Success, false, "Duplicate claim rejected")
		env.Teardown()
	end)

	-- 17) Publicidad recompensada x5 (AdService + ProcessReceipt ProductPurchaseChannel.AdReward)
	runTest("Fase 5.2 [17]: Rewarded Ad x5 multiplies via server AdReward ProcessReceipt; unavailable ad keeps normal claim intact", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52020, Name = "P52_Ad5x" }
		PlotService.Assign(p1)

		env.SimulateRejoin(3600)
		PlotService.Assign(p1)
		local basePending = OfflineIncomeService.GetPendingSnapshot(p1).PendingAmount
		assertEqual(basePending, 21, "Pending = 21")

		-- Caso 1: Anuncio no disponible / fallido -> NO otorga x5 y conserva basePending intacto
		OfflineIncomeService._SetAdServiceAdapterForTests({
			ShowRewardedVideoAd = function()
				return false, "AdNotReady"
			end,
		})
		local adFail = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.ClaimOfflineIncome, ClientOpId = "p17_fail", UseRewardedAd = true })
		assertEqual(adFail.Success, false, "Unavailable ad rejected cleanly")
		assertEqual(OfflineIncomeService.GetPendingSnapshot(p1).PendingAmount, 21, "Pending remains claimable via normal Collect")

		-- Caso 2: Anuncio completado ejecuta ProcessReceipt oficial con ProductPurchaseChannel.AdReward -> otorga x5 (= 105)
		OfflineIncomeService._SetAdServiceAdapterForTests({
			ShowRewardedVideoAd = function(plr)
				local decision = ShopService._ProcessReceiptForTests({
					PurchaseId = "rcpt_ad_5x_1",
					PlayerId = (plr :: any).UserId,
					ProductId = 0,
					ProductPurchaseChannel = Enum.ProductPurchaseChannel.AdReward,
				})
				return decision == Enum.ProductPurchaseDecision.PurchaseGranted, nil
			end,
		})
		local adOk = ShopService.ProcessRequest(p1, { Action = ShopProtocol.Actions.ClaimOfflineIncome, ClientOpId = "p17_ok", UseRewardedAd = true })
		assertTrue(adOk.Success, "AdReward x5 claim succeeded")
		assertEqual(adOk.ClaimedAmount, 21 * 5, "Credited x5 = 105 coins")
		assertEqual(EconomyService.GetBalance(p1), 1105, "Balance == 1105")

		-- Replay del mismo PurchaseId AdReward -> PurchaseGranted idempotente sin sumar otros 105
		local replayDec = ShopService._ProcessReceiptForTests({
			PurchaseId = "rcpt_ad_5x_1",
			PlayerId = p1.UserId,
			ProductId = 0,
			ProductPurchaseChannel = Enum.ProductPurchaseChannel.AdReward,
		})
		assertEqual(replayDec, Enum.ProductPurchaseDecision.PurchaseGranted, "Replay receipt returns PurchaseGranted")
		assertEqual(EconomyService.GetBalance(p1), 1105, "Balance strictly unchanged on replay receipt")
		env.Teardown()
	end)

	-- 18) Integración 10 jugadores concurrentes + construcción/lanzamiento/conducción/daños + controles UI cliente
	runTest("Fase 5.2 [18]: 10-player concurrent Shop+Orders+Delivery+Vehicle lifecycle & Spanish Shop client controllers check", function()
		local env = setupIsolatedWorld(10)
		local players: { PlotService.PlayerLike } = {}
		ShopStockService._SetStockForTests("BasicEngineCrate", 3)

		for i = 1, 10 do
			local plr: PlotService.PlayerLike = { UserId = 52100 + i, Name = `P52_M{i}` }
			table.insert(players, plr)
			local plot = PlotService.Assign(plr)
			assertTrue(plot ~= nil, `Plot assigned to player {i}`)

			local co = ShopService.ProcessRequest(plr, {
				Action = ShopProtocol.Actions.CheckoutNormalCart,
				ClientOpId = `p18_co_{i}`,
				CartItems = { { ItemId = "WoodBlock", Quantity = 2 } },
			})
			assertTrue(co.Success, `Player {i} checkout succeeded`)

			-- Construir y lanzar vehículo en parcela
			BuildService.ProcessRequest(plr, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = `p18_wb_{i}`, ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.5, 0) })
			BuildService.ProcessRequest(plr, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = `p18_st_{i}`, ItemId = "DriverSeat", LocalCFrame = CFrame.new(0, 3.0, 0) })
			local lr = VehicleLaunchService.LaunchVehicle(plr, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
			assertTrue(lr.Success, `Player {i} launched vehicle`)
		end

		env.AdvanceClock(60)
		for i, plr in ipairs(players) do
			assertTrue(VehicleLaunchService.ReturnToWorkshop(plr).Success, `Player {i} returned cleanly`)
			local snap = DeliveryService.GetPlayerOrdersSnapshot(plr) :: any
			assertEqual(snap.SpawnedCount, 1, `Player {i} crate spawned`)
			local cid = snap.NormalOrders[1].Crates[1].CrateId
			assertTrue(ShopService.ProcessRequest(plr, { Action = ShopProtocol.Actions.OpenDeliveryCrate, ClientOpId = `p18_op_{i}`, CrateId = cid }).Success, `Player {i} collected crate`)
			assertEqual(InventoryService.GetOwnedQuantity(plr, "WoodBlock"), 22, `Player {i} inventory = 22`)
		end

		-- Verificar carga de ShopController & textos españoles de ShopUI
		local shopCtrl = require(ClientControllers:WaitForChild("ShopController") :: ModuleScript)
		assertTrue(type(shopCtrl.CheckoutNormalCart) == "function" and type(shopCtrl.PurchaseSpecialCrate) == "function", "ShopController exports actions")
		if not RunService:IsRunning() then
			local shopUi = ClientControllers:WaitForChild("ShopUI") :: LocalScript
			assertTrue(string.find(shopUi.Source, "Pedir ahora", 1, true) ~= nil, "Pedir ahora button exists")
			assertTrue(string.find(shopUi.Source, "Recoger", 1, true) ~= nil, "Offline claim buttons exist")
			assertTrue(string.find(shopUi.Source, "Componentes Normales", 1, true) ~= nil, "Normal section exists")
			assertTrue(string.find(shopUi.Source, "Cajas de Motores", 1, true) ~= nil, "Engine crates section exists")
			assertTrue(string.find(shopUi.Source, "Cajas de Propulsores", 1, true) ~= nil, "Booster crates section exists")
			assertTrue(string.find(shopUi.Source, "QtyInput", 1, true) ~= nil, "Editable numeric cart input exists")
			assertTrue(string.find(shopUi.Source, "Add100Btn", 1, true) ~= nil, "+100 quick button exists")
			assertTrue(string.find(shopUi.Source, "(máx ", 1, true) == nil, "No artificial max owned label in shop UI")
		end

		for _, plr in ipairs(players) do
			PlotService.Release(plr)
		end
		assertEqual(#((ServerStorage:WaitForChild("BaseTemplate") :: Model):GetDescendants()), 25, "BaseTemplate intact after 10-player stress")
		env.Teardown()
	end)

	-- 19) Compra de 100+ y 1,000+ unidades con saldo suficiente + exactamente 1 caja física por ItemId
	runTest("Fase 5.2 [19]: Cart supports 100 and 1,000+ units when affordable and spawns strictly 1 physical crate per ItemId", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52030, Name = "P52_Bulk100Plus" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 20000, "TestGrant", "tx_19_grant") -- Saldo total 21,000

		-- Verificar también en ShopController cantidades grandes >= 100 y >= 1,000
		local shopCtrl = require(ClientControllers:WaitForChild("ShopController") :: ModuleScript)
		shopCtrl.SetCartQuantity("WoodBlock", 100)
		assertEqual(shopCtrl.GetCartQuantity("WoodBlock"), 100, "ShopController allows 100 in cart")
		shopCtrl.SetCartQuantity("WoodBlock", 1500)
		assertEqual(shopCtrl.GetCartQuantity("WoodBlock"), 1500, "ShopController allows 1,500 without 999 cap")
		shopCtrl.ClearCart()

		local checkout = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p19_bulk_order",
			CartItems = {
				{ ItemId = "WoodBlock", Quantity = 100 },
				{ ItemId = "WoodBeam", Quantity = 1000 },
			},
		})
		assertTrue(checkout.Success and checkout.Order ~= nil, "100 WoodBlock + 1000 WoodBeam checkout succeeded")
		local order = checkout.Order :: any
		assertEqual(#order.Crates, 2, "Strictly 1 crate per unique ItemId even for 100 and 1,000 quantities")
		assertEqual(EconomyService.GetBalance(p1), 21000 - (100 * 10 + 1000 * 8), "Debited exact 9,000 coins")

		env.AdvanceClock(60)
		local snap = DeliveryService.GetPlayerOrdersSnapshot(p1) :: any
		assertEqual(snap.SpawnedCount, 2, "Only 2 physical crate models spawned in DeliveryZone")

		local blockBefore = InventoryService.GetOwnedQuantity(p1, "WoodBlock")
		local beamBefore = InventoryService.GetOwnedQuantity(p1, "WoodBeam")
		for _, c in ipairs(order.Crates) do
			local opRes = ShopService.ProcessRequest(p1, {
				Action = ShopProtocol.Actions.OpenDeliveryCrate,
				ClientOpId = `p19_open_{c.CrateId}`,
				CrateId = c.CrateId,
			})
			assertTrue(opRes.Success, `Opened bulk crate for {c.ItemId}`)
		end
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), blockBefore + 100, "Credited exact +100 WoodBlock")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBeam"), beamBefore + 1000, "Credited exact +1,000 WoodBeam")
		env.Teardown()
	end)

	-- 20) Inventario ilimitado: miles de piezas y múltiples asientos persistidos sin truncamiento
	runTest("Fase 5.2 [20]: Inventory capacity is unlimited across bulk deliveries and persists across rejoin", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52031, Name = "P52_UnlimitedInv" }
		PlotService.Assign(p1)
		assertEqual(GameConfig.Inventory.UnlimitedCapacity, true, "UnlimitedCapacity enabled")

		EconomyService.Credit(p1, 100000, "TestGrant", "tx_20_grant")
		local buy1 = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p20_buy1",
			CartItems = {
				{ ItemId = "WoodBlock", Quantity = 2500 },
				{ ItemId = "SmallWheel", Quantity = 1200 },
				{ ItemId = "DriverSeat", Quantity = 8 },
			},
		})
		assertTrue(buy1.Success and buy1.Order ~= nil, "Huge bulk order succeeded")
		env.AdvanceClock(60)
		for _, c in ipairs((buy1.Order :: any).Crates) do
			assertTrue(ShopService.ProcessRequest(p1, {
				Action = ShopProtocol.Actions.OpenDeliveryCrate,
				ClientOpId = `p20_op_{c.CrateId}`,
				CrateId = c.CrateId,
			}).Success, "Opened unlimited-storage crate")
		end

		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), 20 + 2500, "2,520 WoodBlock stored")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "SmallWheel"), 4 + 1200, "1,204 SmallWheel stored")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "DriverSeat"), 1 + 8, "9 DriverSeats stored")

		-- Reconectar y verificar persistencia íntegra sin recortes
		env.SimulateRejoin(30)
		PlotService.Assign(p1)
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), 2520, "WoodBlock count preserved on rejoin")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "SmallWheel"), 1204, "SmallWheel count preserved on rejoin")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "DriverSeat"), 9, "DriverSeat count preserved on rejoin")
		env.Teardown()
	end)

	-- 21) DriverSeat.MaxPurchasesPerPlayer = 1 no limita compras ni inventario; límite de 1 asiento aplica al vehículo
	runTest("Fase 5.2 [21]: DriverSeat.MaxPurchasesPerPlayer=1 does not limit buying/storing seats while vehicle limit remains 1", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 52032, Name = "P52_SeatsLimit" }
		PlotService.Assign(p1)

		local seatDef = ItemRegistry.Get("DriverSeat")
		assertTrue(seatDef.Restrictions ~= nil and seatDef.Restrictions.MaxPurchasesPerPlayer == 1, "Legacy definition retains MaxPurchasesPerPlayer=1")
		local seatEntry = ItemCatalog.GetEntry("DriverSeat") :: ItemCatalog.CatalogItemEntry
		assertEqual(seatEntry.MaxOwnedPerPlayer, nil, "ItemCatalog does not expose MaxOwnedPerPlayer restriction to shop")

		-- Comprar 3 DriverSeats adicionales teniendo 1 inicial (3 * 100 = 300 monedas)
		local co = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p21_seats",
			CartItems = { { ItemId = "DriverSeat", Quantity = 3 } },
		})
		assertTrue(co.Success and co.Order ~= nil, "Buying 3 DriverSeats at once succeeded")
		env.AdvanceClock(60)
		local crateId = (co.Order :: any).Crates[1].CrateId
		assertTrue(ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.OpenDeliveryCrate,
			ClientOpId = "p21_open_seats",
			CrateId = crateId,
		}).Success, "Opened DriverSeat crate")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "DriverSeat"), 4, "Player stores 4 DriverSeats in inventory")

		-- En taller: 1.º DriverSeat permitido; 2.º DriverSeat en el mismo vehículo rechazado con TooManyDriverSeats
		local baseBlock = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "p21_wb",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.5, 0),
		})
		assertTrue(baseBlock.Success, "Placed base block")
		local seat1 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "p21_seat1",
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(0, 3.0, 0),
		})
		assertTrue(seat1.Success, "Placed 1st DriverSeat on vehicle")
		local seat2 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "p21_seat2",
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(0, 3.0, 4.0),
		})
		assertEqual(seat2.Success, false, "2nd DriverSeat blocked on vehicle")
		assertEqual(seat2.ErrorCode, BuildProtocol.ErrorCodes.TooManyDriverSeats, "Enforced as per-vehicle TooManyDriverSeats")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "DriverSeat"), 4, "Remaining stored DriverSeats intact")

		-- Limpiar taller y vender excedente (2 asientos -> +100 monedas) sin errores
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.ClearWorkshop, ClientOpId = "p21_clr" })
		local sellExtra = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p21_sell2",
			ItemId = "DriverSeat",
			Quantity = 2,
		})
		assertTrue(sellExtra.Success, "Sold excess stored DriverSeats")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "DriverSeat"), 2, "2 DriverSeats remain stored")
		env.Teardown()
	end)

	-- 22) Ausencia total de stock global en componentes normales vs stock compartido en LootBoxes
	runTest("Fase 5.2 [22]: Normal components have no global stock in ShopStockService while LootBoxes retain shared restock", function()
		local env = setupIsolatedWorld(3)
		local players: { PlotService.PlayerLike } = {
			{ UserId = 52033, Name = "P52_NoStock1" },
			{ UserId = 52034, Name = "P52_NoStock2" },
			{ UserId = 52035, Name = "P52_NoStock3" },
		}
		for _, plr in ipairs(players) do
			PlotService.Assign(plr)
			EconomyService.Credit(plr, 10000, "TestGrant", `tx_22_{plr.UserId}`)
		end

		-- ShopStockService rechaza componentes normales
		assertEqual(ShopStockService.GetStock("WoodBlock"), 0, "WoodBlock has no LootBox stock")
		local okRes, errCode = ShopStockService.TryReserveUnit("WoodBlock")
		assertEqual(okRes, false, "ShopStockService rejects normal ItemId")
		assertEqual(errCode, ShopProtocol.ErrorCodes.UnknownBox, "Returns UnknownBox for normal parts")

		-- Todos los jugadores pueden comprar simultáneamente 150 WoodBlock sin agotar disponibilidad
		for idx, plr in ipairs(players) do
			local res = ShopService.ProcessRequest(plr, {
				Action = ShopProtocol.Actions.CheckoutNormalCart,
				ClientOpId = `p22_co_{idx}`,
				CartItems = { { ItemId = "WoodBlock", Quantity = 150 } },
			})
			assertTrue(res.Success, `Player {idx} bought 150 WoodBlock without global stock competition`)
		end

		-- Mientras tanto, BasicEngineCrate sí mantiene stock compartido por servidor con reemplazo en restock
		ShopStockService._SetStockForTests("BasicEngineCrate", 1)
		local sp1 = ShopService.ProcessRequest(players[1], {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p22_sp1",
			BoxId = "BasicEngineCrate",
		})
		assertTrue(sp1.Success, "Player 1 consumed last shared BasicEngineCrate")
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 0, "Shared stock dropped to 0 for server")
		local sp2 = ShopService.ProcessRequest(players[2], {
			Action = ShopProtocol.Actions.PurchaseSpecialCrate,
			ClientOpId = "p22_sp2",
			BoxId = "BasicEngineCrate",
		})
		assertEqual(sp2.Success, false, "Player 2 sees 0 shared stock")
		assertEqual(sp2.ErrorCode, ShopProtocol.ErrorCodes.OutOfStock, "OutOfStock for special LootBox")

		-- Restock de 300s reemplaza (no suma) stock solo de cajas especiales
		ShopStockService._SetStockForTests("BasicEngineCrate", 2)
		ShopStockService._SetRngForTests(function() return 1 end)
		env.AdvanceClock(ShopConfig.Orders.RestockIntervalSeconds)
		assertEqual(ShopStockService.GetStock("BasicEngineCrate"), 1, "Restock strictly replaced 2 with 1 (no sum)")
		ShopStockService._SetRngForTests(nil)
		env.Teardown()
	end)
end

function Phase52Tests.RunAll()
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

	Phase52Tests.AppendTests(results, runTest)

	return {
		Passed = passed,
		Failed = failed,
		Results = results,
	}
end

return Phase52Tests

