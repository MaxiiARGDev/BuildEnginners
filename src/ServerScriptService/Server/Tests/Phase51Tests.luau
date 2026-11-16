--!strict
--[=[
	Phase51Tests
	Suite de pruebas de aceptación de la Fase 5.1:
	Inventario Central Autoritativo + Catálogo en Español + Carpetas Físicas en Español.

	Cobertura de los 15 casos obligatorios:
	 1. Estado vacío (InitEmptyForTests) + StarterKit otorgado UNA sola vez y nunca ante fallo DataStore
	 2. Adquisición de piezas comunes y unidades únicas (motores y propulsores)
	 3. Cantidades acumuladas correctamente y persistidas en DataStore
	 4. Colocación válida con inventario suficiente (comunes + auto-asignación A4 + unidad explícita)
	 5. Rechazo por inventario insuficiente (servidor + cliente + rollback sin piezas fantasma)
	 6. Prevención de duplicación de unidades únicas y rechazo de unidades ajenas/inexistentes
	 7. Retiro (RemovePiece / ClearWorkshop) y reutilización inmediata sin consumo
	 8. Tres blueprints compartiendo piezas/unidades (MAX sin sumar slots y validación al cargar)
	 9. Bloqueo de venta de piezas o unidades referenciadas por taller o slots guardados
	10. Desvinculación explícita confirmada (bloqueo en runtime activo) + venta atómica y rollback DataStore
	11. Persistencia completa tras reconexión simulada (sin duplicar StarterKit ni perder instancias)
	12. Conservación estricta del inventario tras destrucción física severa y retorno al taller
	13. Validación física de los 8 modelos desde carpetas en español y protección de BaseTemplate (25 descendientes)
	14. Catálogo centralizado en español (`ItemCatalog`, categorías y UI cliente)
	15. Regresión E2E: construcción con inventario real -> slot -> lanzamiento -> destrucción -> retorno -> venta
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BlueprintPersistenceService = require(ServerScriptService.Server.Services.BlueprintPersistenceService)
local BoosterInventoryService = require(ServerScriptService.Server.Services.BoosterInventoryService)
local BuildService = require(ServerScriptService.Server.Services.BuildService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local EconomyPersistenceService = require(ServerScriptService.Server.Services.EconomyPersistenceService)
local EconomyService = require(ServerScriptService.Server.Services.EconomyService)
local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local InventoryPersistenceService = require(ServerScriptService.Server.Services.InventoryPersistenceService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local ItemRuntimeService = require(ServerScriptService.Server.Services.ItemRuntimeService)
local PlotService = require(ServerScriptService.Server.Services.PlotService)
local PreviewAssetService = require(ServerScriptService.Server.Services.PreviewAssetService)
local SpawnService = require(ServerScriptService.Server.Services.SpawnService)
local StandPreviewService = require(ServerScriptService.Server.Services.StandPreviewService)
local VehicleAssemblyService = require(ServerScriptService.Server.Services.VehicleAssemblyService)
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
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local WheelAutoConfigurationService = require(ServerScriptService.Server.Services.WheelAutoConfigurationService)

local ClientControllers = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState") :: ModuleScript)
local BuildPreviewController = require(ClientControllers:WaitForChild("BuildPreviewController") :: ModuleScript)
local BuildPlacementController = require(ClientControllers:WaitForChild("BuildPlacementController") :: ModuleScript)
local BlueprintManagerController = require(ClientControllers:WaitForChild("BlueprintManagerController") :: ModuleScript)

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase51Tests = {}

local function assertTrue(cond: boolean, msg: string)
	if not cond then
		error(msg, 2)
	end
end

local function assertEqual(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(`{label}: esperado '{tostring(expected)}', obtenido '{tostring(actual)}'`, 2)
	end
end

local function resetAllStrictServices(preservePersistence: boolean?)
	BuildService._ResetForTests()
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
	VehicleBlueprintService._SetTextFilterForTests(nil)
	VehicleBlueprintService._ResetForTests(preservePersistence)
	InventoryService._ResetForTests(preservePersistence, { AutoGrantLegacySuiteQuota = false })
	EconomyService._ResetForTests(preservePersistence)
	if not preservePersistence then
		BlueprintPersistenceService._ResetForTests(true)
		InventoryPersistenceService._ResetForTests(true)
		EconomyPersistenceService._ResetForTests(true)
	else
		BlueprintPersistenceService._SetSimulateWriteFailureForTests(false)
		BlueprintPersistenceService._SetSimulateLoadFailureForTests(false)
		InventoryPersistenceService._SetSimulateWriteFailureForTests(false)
		InventoryPersistenceService._SetSimulateLoadFailureForTests(false)
		EconomyPersistenceService._SetSimulateWriteFailureForTests(false)
		EconomyPersistenceService._SetSimulateLoadFailureForTests(false)
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

local function initAllStrictServices(tempPlots: Folder, plotCount: number?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
	local assets = ServerStorage:WaitForChild("ItemAssets")

	ItemRegistry.Init()
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
	VehicleDamageService.Init()
	VehicleImpactService.Init()
	VehicleDestructionService.Init()
	VehicleSeatService.Init()
	VehicleRuntimeService.Init()
	VehicleLifecycleService.Init()
	VehicleLaunchService.Init()
	BuildService.Init()
end

local function setupIsolatedWorld(plotCount: number?)
	local existing = Workspace:FindFirstChild("_Phase51TestPlots")
	if existing then
		existing:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase51TestPlots"
	tempPlots.Parent = Workspace

	resetAllStrictServices(false)
	initAllStrictServices(tempPlots, plotCount)

	local virtualClock = 50000
	local rateClock = 50000
	BuildService._SetRateLimitClockForTests(function()
		rateClock += 1.0
		return rateClock
	end)
	VehicleLaunchService._SetClockForTests(function()
		return virtualClock
	end)
	VehicleLifecycleService._SetClockForTests(function()
		return virtualClock
	end)
	VehicleDamageService._SetClockForTests(function()
		return virtualClock
	end)
	VehicleImpactService._SetClockForTests(function()
		return virtualClock
	end)
	VehicleDestructionService._SetClockForTests(function()
		return virtualClock
	end)

	local createdCleanupRefs: { Instance } = {}

	return {
		TempPlots = tempPlots,
		AdvanceClock = function(dt: number): number
			virtualClock += dt
			return virtualClock
		end,
		TrackTemp = function(inst: Instance)
			table.insert(createdCleanupRefs, inst)
		end,
		SimulateRejoin = function(newPlotCount: number?)
			resetAllStrictServices(true)
			for _, child in ipairs(tempPlots:GetChildren()) do
				child:Destroy()
			end
			initAllStrictServices(tempPlots, newPlotCount or plotCount)
			BuildService._SetRateLimitClockForTests(function()
				rateClock += 1.0
				return rateClock
			end)
			VehicleLaunchService._SetClockForTests(function()
				return virtualClock
			end)
			VehicleLifecycleService._SetClockForTests(function()
				return virtualClock
			end)
			VehicleDamageService._SetClockForTests(function()
				return virtualClock
			end)
			VehicleImpactService._SetClockForTests(function()
				return virtualClock
			end)
			VehicleDestructionService._SetClockForTests(function()
				return virtualClock
			end)
		end,
		Teardown = function()
			resetAllStrictServices(false)
			for _, inst in ipairs(createdCleanupRefs) do
				if inst.Parent then
					inst:Destroy()
				end
			end
			if tempPlots.Parent then
				tempPlots:Destroy()
			end
		end,
	}
end

local function makeClientBridge(player: PlotService.PlayerLike)
	return function(req: any): BuildProtocol.BuildOperationResponse
		return BuildService.ProcessRequest(player, req)
	end
end

local function placeReq(
	player: PlotService.PlayerLike,
	opId: string,
	itemId: string,
	localCF: CFrame,
	inventoryUnitId: string?
): BuildProtocol.BuildOperationResponse
	return BuildService.ProcessRequest(player, {
		Action = BuildProtocol.Actions.PlacePiece,
		ClientOpId = opId,
		ItemId = itemId,
		LocalCFrame = localCF,
		InventoryInstanceId = inventoryUnitId,
	})
end

local function assertPlaceOk(
	player: PlotService.PlayerLike,
	opId: string,
	itemId: string,
	localCF: CFrame,
	inventoryUnitId: string?
): string
	local res = placeReq(player, opId, itemId, localCF, inventoryUnitId)
	assertTrue(
		res.Success and res.PlacedPiece ~= nil,
		`PlacePiece falló ({itemId}): {tostring(res.ErrorCode)} - {tostring(res.ErrorMessage)}`
	)
	return (res.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId
end

local function buildStarterVehicle(player: PlotService.PlayerLike, prefix: string)
	local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)
	local b1 = assertPlaceOk(player, `{prefix}_b1`, "WoodBlock", CFrame.new(0, 2.5, -2))
	local b2 = assertPlaceOk(player, `{prefix}_b2`, "WoodBlock", CFrame.new(0, 2.5, 0))
	local b3 = assertPlaceOk(player, `{prefix}_b3`, "WoodBlock", CFrame.new(0, 2.5, 2))
	local b4 = assertPlaceOk(player, `{prefix}_b4`, "WoodBlock", CFrame.new(0, 2.5, 4))

	local wFL = assertPlaceOk(player, `{prefix}_wfl`, "SmallWheel", CFrame.new(-1.5, 2.5, -2))
	local wFR = assertPlaceOk(player, `{prefix}_wfr`, "SmallWheel", CFrame.new(1.5, 2.5, -2) * wheelFlip)
	local wRL = assertPlaceOk(player, `{prefix}_wrl`, "SmallWheel", CFrame.new(-1.5, 2.5, 4))
	local wRR = assertPlaceOk(player, `{prefix}_wrr`, "SmallWheel", CFrame.new(1.5, 2.5, 4) * wheelFlip)

	local seat = assertPlaceOk(player, `{prefix}_seat`, "DriverSeat", CFrame.new(0, 4.0, -2))
	local engine = assertPlaceOk(player, `{prefix}_eng`, "SmallEngine", CFrame.new(0, 4.5, 0))
	local nitro = assertPlaceOk(player, `{prefix}_nitro`, "SmallNitroTank", CFrame.new(2, 2.5, 1))
	local tank = assertPlaceOk(player, `{prefix}_tank`, "RegularFuelTank", CFrame.new(0, 4.5, 4))
	local booster = assertPlaceOk(player, `{prefix}_bst`, "SmallBooster", CFrame.new(0, 2.5, 6.5))

	return {
		Blocks = { b1, b2, b3, b4 },
		Wheels = { wFL, wFR, wRL, wRR },
		TankId = tank,
		NitroId = nitro,
		SeatId = seat,
		EngineId = engine,
		BoosterId = booster,
	}
end

function Phase51Tests.AppendTests(results: { TestCaseResult }, runTest: (name: string, fn: () -> ()) -> ())
	-- 1) Estado vacío, kit inicial una sola vez y protección ante fallo DataStore
	runTest("Fase 5.1 [01]: Empty init, single StarterKit grant (GameConfig.StartingInventory) and failure safety", function()
		local env = setupIsolatedWorld(2)
		assertEqual(InventoryService.IsLegacyTestQuotaEnabled(), false, "Legacy test quota debe iniciar estrictamente false")

		local pFail: PlotService.PlayerLike = { UserId = 51001, Name = "P51_Fail" }
		local pEmpty: PlotService.PlayerLike = { UserId = 51002, Name = "P51_Empty" }
		local pStarter: PlotService.PlayerLike = { UserId = 51003, Name = "P51_Starter" }

		-- Fallo de DataStore al cargar nunca debe inventar ni entregar kit inicial
		InventoryPersistenceService._SetSimulateLoadFailureForTests(true)
		local okFail, _, failCode = InventoryService.EnsurePlayerLoaded(pFail)
		assertEqual(okFail, false, "EnsurePlayerLoaded falla honestamente ante error de DataStore")
		assertEqual(failCode, BuildProtocol.ErrorCodes.PersistenceFailed, "ErrorCode == PersistenceFailed")
		assertEqual(InventoryService.GetOwnedQuantity(pFail, "WoodBlock"), 0, "Zero fallos inventados cuando falló lectura")
		assertEqual(InventoryPersistenceService._GetRawMemorySnapshotForTests(pFail.UserId), nil, "Nada persistido tras fallo de lectura")
		InventoryPersistenceService._SetSimulateLoadFailureForTests(false)

		-- InitEmptyForTests entrega exactamente 0 en todo y persiste vacío
		assertTrue(InventoryService.InitEmptyForTests(pEmpty, true), "InitEmptyForTests persistido")
		local emptySnap = InventoryService.GetPlayerSnapshot(pEmpty)
		assertTrue(emptySnap ~= nil, "Snapshot vacío obtenido")
		for _, entry in ipairs((emptySnap :: any).Items) do
			assertEqual(entry.OwnedQuantity, 0, `{entry.ItemId} inicia en 0 en inventario vacío`)
		end
		assertEqual(#(emptySnap :: any).UniqueUnits, 0, "Cero unidades únicas en inventario vacío")

		-- Jugador nuevo recibe GameConfig.StartingInventory exactamente una vez
		local okLoad = InventoryService.EnsurePlayerLoaded(pStarter)
		assertTrue(okLoad, "StarterKit inicializado para jugador nuevo")
		assertEqual(InventoryService.GetOwnedQuantity(pStarter, "WoodBlock"), 20, "StarterKit WoodBlock=20")
		assertEqual(InventoryService.GetOwnedQuantity(pStarter, "WoodBeam"), 10, "StarterKit WoodBeam=10")
		assertEqual(InventoryService.GetOwnedQuantity(pStarter, "SmallWheel"), 4, "StarterKit SmallWheel=4")
		assertEqual(InventoryService.GetOwnedQuantity(pStarter, "DriverSeat"), 1, "StarterKit DriverSeat=1")
		assertEqual(InventoryService.GetOwnedQuantity(pStarter, "RegularFuelTank"), 1, "StarterKit RegularFuelTank=1")
		assertEqual(InventoryService.GetOwnedQuantity(pStarter, "SmallNitroTank"), 1, "StarterKit SmallNitroTank=1")
		assertEqual(#InventoryService.GetPlayerEngineUnits(pStarter), 1, "StarterKit 1 SmallEngine único")
		assertEqual(#InventoryService.GetPlayerBoosterUnits(pStarter), 1, "StarterKit 1 SmallBooster único")

		local starterEngId = InventoryService.GetPlayerEngineUnits(pStarter)[1].ItemInstanceId
		local starterBstId = InventoryService.GetPlayerBoosterUnits(pStarter)[1].ItemInstanceId

		-- Reconexión jamás duplica StarterKit
		env.SimulateRejoin(2)
		assertEqual(InventoryService.GetOwnedQuantity(pStarter, "WoodBlock"), 20, "Tras reconexión WoodBlock sigue siendo 20")
		assertEqual(#InventoryService.GetPlayerEngineUnits(pStarter), 1, "Tras reconexión sigue siendo 1 motor único")
		assertEqual(InventoryService.GetPlayerEngineUnits(pStarter)[1].ItemInstanceId, starterEngId, "Misma instancia de motor preservada")
		assertEqual(InventoryService.GetPlayerBoosterUnits(pStarter)[1].ItemInstanceId, starterBstId, "Misma instancia de propulsor preservada")
		env.Teardown()
	end)

	-- 2) Adquisición de piezas comunes y unidades únicas
	runTest("Fase 5.1 [02]: Acquire common items and unique engine/booster units with server stats", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51004, Name = "P51_Acquire" }
		assertTrue(InventoryService.InitEmptyForTests(p1, true), "Init empty")

		local okAdd, errCode = InventoryService.AddItem(p1, "WoodBlock", 6)
		assertTrue(okAdd and errCode == nil, "AddItem WoodBlock")
		local okEng, engUnit = InventoryService.AddEngineUnit(p1, {
			EngineFamilyId = "StandardCombustion",
			EngineSizeId = "Small",
			VariantId = "HighTorque",
			RarityId = "Rare",
			SourceTag = "ShopPurchase",
		})
		assertTrue(okEng and engUnit ~= nil, "AddEngineUnit Rare")
		local okBst, bstUnit = InventoryService.AddBoosterUnit(p1, {
			BoosterFamilyId = "HighImpulse",
			BoosterSizeId = "Medium",
			VariantId = "Overboost",
			RarityId = "Epic",
			SourceTag = "CrateDrop",
		})
		assertTrue(okBst and bstUnit ~= nil, "AddBoosterUnit Epic")

		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), 6, "WoodBlock == 6")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "SmallEngine"), 1, "SmallEngine == 1")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "SmallBooster"), 1, "SmallBooster == 1")
		assertEqual((engUnit :: any).RarityId, "Rare", "Engine rarity Rare calculada en servidor")
		assertTrue((bstUnit :: any).EffectiveStats.Thrust > 12000, "Booster Epic Medium > base Small")
		assertEqual(ItemRegistry.Get("WoodBlock").SellPrice, nil, "SellPrice TBD sin inventar precios")
		env.Teardown()
	end)

	-- 3) Acumulación correcta de cantidades y validaciones de entrada
	runTest("Fase 5.1 [03]: Common item quantities accumulate atomically and reject invalid grants", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51005, Name = "P51_Stack" }
		assertTrue(InventoryService.InitEmptyForTests(p1, true), "Init empty")

		assertTrue(InventoryService.AddItem(p1, "WoodBeam", 4), "Add +4")
		assertTrue(InventoryService.AddItem(p1, "WoodBeam", 5), "Add +5")
		assertTrue(InventoryService.AddItem(p1, "WoodBeam", 3), "Add +3")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBeam"), 12, "Accumulated == 12")

		local okZero = InventoryService.AddItem(p1, "WoodBeam", 0)
		local okNeg = InventoryService.AddItem(p1, "WoodBeam", -2)
		local okFrac = InventoryService.AddItem(p1, "WoodBeam", 1.5)
		local okUniqueAsStack = InventoryService.AddItem(p1, "SmallEngine", 1)
		assertEqual(okZero, false, "0 rejected")
		assertEqual(okNeg, false, "negative rejected")
		assertEqual(okFrac, false, "fractional rejected")
		assertEqual(okUniqueAsStack, false, "unique unit cannot use stackable AddItem")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBeam"), 12, "Quantity unchanged after rejects")
		env.Teardown()
	end)

	-- 4) Colocación válida (comunes + auto-asignación de unidad única A4)
	runTest("Fase 5.1 [04]: Placing items reserves counts cleanly and auto-assigns owned unique units", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51006, Name = "P51_PlaceOk" }
		PlotService.Assign(p1)

		local starterSnap = InventoryService.GetPlayerSnapshot(p1)
		assertTrue(starterSnap ~= nil and (starterSnap :: any).ItemsById.WoodBlock.AvailableToPlace == 20, "20 WoodBlock disponibles")

		local resBlock = placeReq(p1, "p4_b1", "WoodBlock", CFrame.new(0, 2.5, 0))
		assertTrue(resBlock.Success, "WoodBlock colocado")
		assertEqual((resBlock.Inventory :: any).ItemsById.WoodBlock.OwnedQuantity, 20, "OwnedQuantity intacto (20)")
		assertEqual((resBlock.Inventory :: any).ItemsById.WoodBlock.WorkshopReservedQuantity, 1, "WorkshopReservedQuantity == 1")
		assertEqual((resBlock.Inventory :: any).ItemsById.WoodBlock.AvailableToPlace, 19, "AvailableToPlace == 19")

		-- Motor colocado SIN especificar InventoryInstanceId -> auto-asigna la unidad del StarterKit (A4)
		local resEng = placeReq(p1, "p4_eng", "SmallEngine", CFrame.new(0, 4.5, 0))
		assertTrue(resEng.Success and resEng.PlacedPiece ~= nil, `Motor auto-asignado: {tostring(resEng.ErrorMessage)}`)
		local starterEngId = InventoryService.GetPlayerEngineUnits(p1)[1].ItemInstanceId
		assertEqual((resEng.PlacedPiece :: any).InventoryInstanceId, starterEngId, "Auto-asignó exactamente el ItemInstanceId del dueño")
		assertEqual((resEng.Inventory :: any).ItemsById.SmallEngine.AvailableToPlace, 0, "AvailableToPlace motor == 0")
		env.Teardown()
	end)

	-- 5) Rechazo por inventario insuficiente (servidor + cliente optimista con rollback)
	runTest("Fase 5.1 [05]: Rejects placement when insufficient inventory on both client and server without ghost leaks", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51007, Name = "P51_NoStock" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		assertTrue(InventoryService.InitEmptyForTests(p1, true), "Empty inventory")
		assertTrue(InventoryService.AddItem(p1, "WoodBlock", 1), "Grant exact 1 WoodBlock")

		local bridge = makeClientBridge(p1)
		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		BuildState.SetActive(true)
		BuildState.SelectItem("WoodBlock")
		BuildPlacementController.SyncBlueprintFromServer(bridge)
		assertEqual(BuildState.GetAvailableQuantity("WoodBlock"), 1, "Cliente ve 1 disponible")

		-- Colocar el único WoodBlock disponible
		BuildState.SetPlacementStatus(CFrame.new(plot.Zones.BuildZone.Position + Vector3.new(0, 2, 0)), CFrame.new(0, 2.5, 0), true, nil, nil)
		local ok1, r1 = BuildPlacementController.PlaceCurrentPiece(bridge)
		assertTrue(ok1 and r1 ~= nil and r1.Success, "Primer WoodBlock colocado vía controlador")
		assertEqual(BuildState.GetAvailableQuantity("WoodBlock"), 0, "Cliente ve 0 disponibles")

		-- Segundo intento desde cliente: rechazado localmente con 0 ghosts pendientes
		BuildState.SetPlacementStatus(CFrame.new(plot.Zones.BuildZone.Position + Vector3.new(2, 2, 0)), CFrame.new(2, 2.5, 0), true, nil, nil)
		local okClientBlock, rClientBlock = BuildPlacementController.PlaceCurrentPiece(bridge)
		assertEqual(okClientBlock, false, "Cliente rechaza 2do WoodBlock sin stock")
		assertEqual((rClientBlock :: any).ErrorCode, BuildProtocol.ErrorCodes.InsufficientInventory, "Código InsufficientInventory")
		assertEqual(BuildPlacementController.GetPendingCount(), 0, "0 ghosts en vuelo")

		-- Intentar bypass directo al servidor (2do WoodBlock + motor sin stock) -> servidor rechaza autoritativamente
		local srvBlockFail = placeReq(p1, "p5_srv_blk", "WoodBlock", CFrame.new(2, 2.5, 0))
		assertEqual(srvBlockFail.Success, false, "Servidor rechaza WoodBlock excedente")
		assertEqual(srvBlockFail.ErrorCode, BuildProtocol.ErrorCodes.InsufficientInventory, "Servidor devuelve InsufficientInventory")

		local srvEngFail = placeReq(p1, "p5_srv_eng", "SmallEngine", CFrame.new(0, 4.5, 0))
		assertEqual(srvEngFail.Success, false, "Servidor rechaza motor sin unidades propias")
		assertEqual(srvEngFail.ErrorCode, BuildProtocol.ErrorCodes.InsufficientInventory, "Servidor devuelve InsufficientInventory en motor")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 1, "Solo permanece 1 pieza legítima en el blueprint")

		-- Simular cliente con caché desactualizada (spoof) -> RPC al servidor falla y hace rollback visual limpio
		BuildState.SetInventoryState({
			OwnerUserId = p1.UserId,
			InventoryRevision = 999,
			ItemsById = { WoodBlock = { ItemId = "WoodBlock", OwnedQuantity = 10 } },
		})
		BuildState.SetPlacementStatus(CFrame.new(plot.Zones.BuildZone.Position + Vector3.new(2, 2, 0)), CFrame.new(2, 2.5, 0), true, nil, nil)
		local okSpoof, rSpoof = BuildPlacementController.PlaceCurrentPiece(bridge)
		assertEqual(okSpoof, false, "Servidor rechaza cliente con estado desactualizado")
		assertEqual((rSpoof :: any).ErrorCode, BuildProtocol.ErrorCodes.InsufficientInventory, "Rollback por InsufficientInventory")
		assertEqual(BuildPlacementController.GetPendingCount(), 0, "Ghost destruido en rollback")
		env.Teardown()
	end)

	-- 6) Prevención de duplicación de unidades únicas y rechazo de unidades ajenas
	runTest("Fase 5.1 [06]: Prevents duplicating unique units and rejects foreign/forged unit IDs", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 51008, Name = "P51_Own" }
		local p2: PlotService.PlayerLike = { UserId = 51009, Name = "P51_Other" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)

		assertPlaceOk(p1, "p6_b1", "WoodBlock", CFrame.new(0, 2.5, 0))
		assertPlaceOk(p1, "p6_b2", "WoodBlock", CFrame.new(0, 2.5, 2))
		local p1EngId = InventoryService.GetPlayerEngineUnits(p1)[1].ItemInstanceId
		local p1BstId = InventoryService.GetPlayerBoosterUnits(p1)[1].ItemInstanceId
		local p2EngId = InventoryService.GetPlayerEngineUnits(p2)[1].ItemInstanceId

		assertPlaceOk(p1, "p6_e1", "SmallEngine", CFrame.new(0, 4.5, 0), p1EngId)
		local dupEng = placeReq(p1, "p6_e_dup", "SmallEngine", CFrame.new(0, 4.5, 2), p1EngId)
		assertEqual(dupEng.Success, false, "Mismo motor bloqueado en 2da pieza")
		assertEqual(dupEng.ErrorCode, BuildProtocol.ErrorCodes.DuplicateEngineUnitInBlueprint, "DuplicateEngineUnitInBlueprint")

		assertPlaceOk(p1, "p6_bst1", "SmallBooster", CFrame.new(0, 2.5, 4.5), p1BstId)
		local dupBst = placeReq(p1, "p6_bst_dup", "SmallBooster", CFrame.new(0, 4.5, 4.5), p1BstId)
		assertEqual(dupBst.Success, false, "Mismo propulsor bloqueado en 2da pieza")
		assertEqual(dupBst.ErrorCode, BuildProtocol.ErrorCodes.DuplicateBoosterUnitInBlueprint, "DuplicateBoosterUnitInBlueprint")

		local stolen = placeReq(p1, "p6_stolen", "SmallEngine", CFrame.new(0, 4.5, 2), p2EngId)
		assertEqual(stolen.Success, false, "Motor de otro jugador rechazado")
		assertEqual(stolen.ErrorCode, BuildProtocol.ErrorCodes.UnauthorizedEngineUnit, "UnauthorizedEngineUnit")

		local forgedStats = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "p6_forge",
			ItemId = "SmallEngine",
			LocalCFrame = CFrame.new(0, 4.5, 2),
			Config = { PeakTorque = 999999 },
		})
		assertEqual(forgedStats.Success, false, "Inyección directa de estadísticas rechazada")
		assertEqual(forgedStats.ErrorCode, BuildProtocol.ErrorCodes.ForbiddenDirectStatsPayload, "ForbiddenDirectStatsPayload")
		env.Teardown()
	end)

	-- 7) Retiro y reutilización inmediata (RemovePiece y ClearWorkshop)
	runTest("Fase 5.1 [07]: RemovePiece and ClearWorkshop release pieces cleanly without consumption", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51010, Name = "P51_Reuse" }
		PlotService.Assign(p1)

		local v = buildStarterVehicle(p1, "p7")
		local midSnap = InventoryService.GetPlayerSnapshot(p1) :: any
		assertEqual(midSnap.ItemsById.WoodBlock.AvailableToPlace, 16, "20 - 4 == 16 disponibles")
		assertEqual(midSnap.ItemsById.SmallEngine.AvailableToPlace, 0, "Motor reservado")

		-- Retirar bloque + motor -> disponibles de inmediato
		local remRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.RemovePiece,
			ClientOpId = "p7_rem_eng",
			PieceInstanceId = v.EngineId,
		})
		assertTrue(remRes.Success, "Motor retirado")
		assertEqual((remRes.Inventory :: any).ItemsById.SmallEngine.AvailableToPlace, 1, "Motor vuelve a 1 disponible sin perderse")

		-- Reutilizar inmediatamente
		assertPlaceOk(p1, "p7_re_eng", "SmallEngine", CFrame.new(0, 4.5, 0))

		-- Vaciar taller -> todo vuelve a estar 100% disponible
		local clrRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.ClearWorkshop,
			ClientOpId = "p7_clr",
		})
		assertTrue(clrRes.Success, "ClearWorkshop exitoso")
		local postClear = clrRes.Inventory :: any
		assertEqual(postClear.ItemsById.WoodBlock.AvailableToPlace, 20, "WoodBlock 20/20 disponible")
		assertEqual(postClear.ItemsById.SmallWheel.AvailableToPlace, 4, "SmallWheel 4/4 disponible")
		assertEqual(postClear.ItemsById.SmallEngine.AvailableToPlace, 1, "SmallEngine 1/1 disponible")
		assertEqual(postClear.ItemsById.SmallBooster.AvailableToPlace, 1, "SmallBooster 1/1 disponible")
		env.Teardown()
	end)

	-- 8) Tres blueprints compartiendo piezas/unidades (MAX entre slots, nunca suma)
	runTest("Fase 5.1 [08]: Up to 3 saved blueprints share owned items/units using MAX rule (never summing slots)", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51011, Name = "P51_Share" }
		PlotService.Assign(p1)

		buildStarterVehicle(p1, "p8")

		for sIdx = 1, 3 do
			local sv = BuildService.ProcessRequest(p1, {
				Action = BuildProtocol.Actions.SaveBlueprintSlot,
				ClientOpId = `p8_save_{sIdx}`,
				SlotIndex = sIdx,
				Name = `Diseno_{sIdx}`,
			})
			assertTrue(sv.Success, `Slot {sIdx} guardado`)
		end

		local snap = InventoryService.GetPlayerSnapshot(p1) :: any
		assertEqual(snap.ItemsById.WoodBlock.OwnedQuantity, 20, "Propiedad de WoodBlock sigue en 20")
		assertEqual(snap.ItemsById.WoodBlock.BlueprintMaxReferencedQuantity, 4, "Referencia en slots == MAX(4,4,4) == 4 (nunca 12)")
		assertEqual(snap.ItemsById.WoodBlock.LockedFromSale, 4, "Bloqueados para venta == 4")
		assertEqual(snap.ItemsById.WoodBlock.SellableQuantity, 16, "Vendibles == 16")
		assertEqual(snap.ItemsById.SmallWheel.BlueprintMaxReferencedQuantity, 4, "4 ruedas compartidas en 3 slots (no 12)")
		assertEqual(#snap.ItemsById.SmallWheel.BlockedSlotIndices, 3, "Los 3 slots listados en referencias")
		assertEqual(#snap.EngineUnits, 1, "Sigue siendo exactamente 1 unidad de motor")
		assertEqual(#snap.EngineUnits[1].ReferencedSlotIndices, 3, "La unidad única marca Slots {1, 2, 3}")

		-- Cargar Slot 2 funciona perfectamente compartiendo el mismo motor/ruedas
		local ld2 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = "p8_ld2",
			SlotIndex = 2,
			ConfirmDiscardUnsaved = true,
		})
		assertTrue(ld2.Success, "Cargar Slot 2 que comparte inventario funciona sin duplicación")
		assertEqual(#InventoryService.GetPlayerEngineUnits(p1), 1, "Total de unidades sigue siendo 1 tras cargar slot")
		env.Teardown()
	end)

	-- 9) Bloqueo de venta cuando hay referencias en taller o slots
	runTest("Fase 5.1 [09]: Blocks selling referenced items/units with exact blocking workshop and slots info", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51012, Name = "P51_SellBlock" }
		PlotService.Assign(p1)

		local v = buildStarterVehicle(p1, "p9")
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "p9_s1",
			SlotIndex = 1,
			Name = "Auto1",
		}).Success, "Slot 1 guardado")
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "p9_s2",
			SlotIndex = 2,
			Name = "Auto2",
		}).Success, "Slot 2 guardado")

		-- WoodBlock: posee 20, usados 4 -> vender 16 es válido, vender 17 falla con BlockedSlotIndices
		local failWood = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p9_sell_wood_17",
			ItemId = "WoodBlock",
			Quantity = 17,
		})
		assertEqual(failWood.Success, false, "Vender 17 WoodBlock bloqueado")
		assertEqual(failWood.ErrorCode, BuildProtocol.ErrorCodes.SellBlockedByReferences, "SellBlockedByReferences")
		assertEqual(failWood.BlockedInWorkshop, true, "BlockedInWorkshop true")
		assertEqual(#(failWood.BlockedSlotIndices :: { number }), 2, "Slot 1 y Slot 2 bloqueando")

		-- Motor único en taller + Slot 1 + Slot 2: venta bloqueada
		local engId = InventoryService.GetPlayerEngineUnits(p1)[1].ItemInstanceId
		local failEng = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p9_sell_eng",
			ItemId = "SmallEngine",
			ItemInstanceId = engId,
		})
		assertEqual(failEng.Success, false, "Venta de motor bloqueada por taller + slots")
		assertEqual(failEng.ErrorCode, BuildProtocol.ErrorCodes.SellBlockedByReferences, "SellBlockedByReferences en unidad única")
		assertEqual(failEng.BlockedInWorkshop, true, "BlockedInWorkshop true para motor")

		-- Vaciar taller -> ya no está en taller, pero Slot 1 y 2 siguen bloqueando la venta
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.ClearWorkshop, ClientOpId = "p9_clr" })
		local failEngSlotsOnly = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p9_sell_eng2",
			ItemId = "SmallEngine",
			ItemInstanceId = engId,
		})
		assertEqual(failEngSlotsOnly.Success, false, "Venta sigue bloqueada solo por slots")
		assertEqual(failEngSlotsOnly.BlockedInWorkshop, false, "BlockedInWorkshop false")
		assertEqual(#(failEngSlotsOnly.BlockedSlotIndices :: { number }), 2, "Slots 1 y 2 siguen listados")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "SmallEngine"), 1, "Unidad no se eliminó")
		env.Teardown()
	end)

	-- 10) Desvinculación confirmada + bloqueo en runtime activo + venta atómica y rollback DataStore
	runTest("Fase 5.1 [10]: Confirmed Unlink removes only target references (blocked in active runtime) then allows atomic sell with rollback", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51013, Name = "P51_UnlinkSell" }
		PlotService.Assign(p1)

		buildStarterVehicle(p1, "p10")
		local pieceCountFull = VehicleBlueprintService.GetPieceCount(p1)
		local engId = InventoryService.GetPlayerEngineUnits(p1)[1].ItemInstanceId
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "p10_s1",
			SlotIndex = 1,
			Name = "AutoUnlink",
		}).Success, "Slot 1 guardado")

		-- Mientras el vehículo esté lanzado en runtime activo, desvincular lo que usa el vehículo lanzado debe bloquearse
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr.Success, "Vehículo lanzado")
		local unlinkDuringRuntime = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UnlinkInventoryFromBlueprints,
			ClientOpId = "p10_unlink_rt",
			ItemId = "SmallEngine",
			ItemInstanceId = engId,
			Confirmed = true,
		})
		assertEqual(unlinkDuringRuntime.Success, false, "Desvincular bloqueado durante runtime activo")
		assertEqual(unlinkDuringRuntime.ErrorCode, BuildProtocol.ErrorCodes.InvalidPlayerState, "InvalidPlayerState mientras activo")

		-- Regresar al taller
		assertTrue(VehicleLaunchService.ReturnToWorkshop(p1).Success, "Regreso al taller")

		-- Preview (Confirmed=false) retorna detalles sin modificar diseños
		local previewRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UnlinkInventoryFromBlueprints,
			ClientOpId = "p10_unlink_prev",
			ItemId = "SmallEngine",
			ItemInstanceId = engId,
			Confirmed = false,
		})
		assertEqual(previewRes.Success, false, "Requiere confirmación explícita")
		assertEqual(previewRes.ConfirmationRequired, true, "ConfirmationRequired == true")
		assertTrue(previewRes.UnlinkPreview ~= nil and (previewRes.UnlinkPreview :: any).AffectedWorkshop == true, "Detecta taller afectado")
		assertEqual(#(previewRes.UnlinkPreview :: any).AffectedSlotIndices, 1, "Detecta Slot 1 afectado")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), pieceCountFull, "Sin mutación antes de confirmar")

		-- Confirmado: retira SOLO el motor de taller y Slot 1, preservando las demás piezas y el Slot 1
		local unlinkOk = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UnlinkInventoryFromBlueprints,
			ClientOpId = "p10_unlink_go",
			ItemId = "SmallEngine",
			ItemInstanceId = engId,
			Confirmed = true,
		})
		assertTrue(unlinkOk.Success, `Desvincular exitoso: {tostring(unlinkOk.ErrorMessage)}`)
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), pieceCountFull - 1, "Solo se eliminó 1 pieza (el motor)")
		local slotSummary = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1]
		assertTrue(slotSummary.IsOccupied, "Slot 1 NO fue eliminado")
		assertEqual(slotSummary.PieceCount, pieceCountFull - 1, "Slot 1 conserva el resto de piezas intactas")
		assertEqual((unlinkOk.Inventory :: any).EngineUnits[1].UsedInWorkshop, false, "Motor ya desvinculado del taller")
		assertEqual(#((unlinkOk.Inventory :: any).EngineUnits[1].ReferencedSlotIndices), 0, "Motor ya sin referencias en slots")

		-- Fase 5.2: motores/propulsores únicos sin valoración individual no se venden por monedas
		local rejectUniqueSell = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p10_sell_unique_reject",
			ItemId = "SmallEngine",
			ItemInstanceId = engId,
		})
		assertEqual(rejectUniqueSell.Success, false, "Motor único sin precio individual no permite venta monetaria")

		-- Desvincular y probar rollback/venta atómica sobre WoodBlock (valor venta 50% -> $5 c/u)
		local unlinkWood = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UnlinkInventoryFromBlueprints,
			ClientOpId = "p10_unlink_wood",
			ItemId = "WoodBlock",
			Confirmed = true,
		})
		assertTrue(unlinkWood.Success, "Desvinculación de WoodBlock exitosa")

		-- Rollback si falla escritura en DataStore al vender
		InventoryPersistenceService._SetSimulateWriteFailureForTests(true)
		local sellFail = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p10_sell_fail",
			ItemId = "WoodBlock",
			Quantity = 10,
		})
		InventoryPersistenceService._SetSimulateWriteFailureForTests(false)
		assertEqual(sellFail.Success, false, "Fallo DataStore aborta venta")
		assertEqual(sellFail.ErrorCode, BuildProtocol.ErrorCodes.PersistenceFailed, "PersistenceFailed")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), 20, "Rollback completo: bloques siguen en inventario")

		-- Venta definitiva exitosa de 10 WoodBlock -> paga 50% ($50)
		local sellOk = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p10_sell_ok",
			ItemId = "WoodBlock",
			Quantity = 10,
		})
		assertTrue(sellOk.Success and sellOk.SellResult ~= nil, `Venta exitosa: {tostring(sellOk.ErrorMessage)}`)
		assertEqual((sellOk.SellResult :: any).SoldQuantity, 10, "10 WoodBlock vendidos")
		assertEqual((sellOk.SellResult :: any).SellValue, 50, "SellValue paga 50% ($5 * 10 = $50)")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), 10, "10 WoodBlock restantes tras venta")
		env.Teardown()
	end)

	-- 11) Persistencia tras reconexión simulada
	runTest("Fase 5.1 [11]: Full persistence survives simulated rejoin without duplicating StarterKit or losing custom units", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 51014, Name = "P51_Persist" }
		PlotService.Assign(p1)

		assertTrue(InventoryService.AddItem(p1, "WoodBlock", 5), "Add +5 WoodBlock -> 25")
		local okRare, rareEng = InventoryService.AddEngineUnit(p1, {
			VariantId = "HighRev",
			RarityId = "Rare",
			SourceTag = "ShopPurchase",
		})
		assertTrue(okRare and rareEng ~= nil, "Rare engine acquired")
		local rareId = (rareEng :: any).ItemInstanceId

		-- Usar algunas piezas, vender 2 WoodBlock libres, guardar Slot 1
		assertPlaceOk(p1, "p11_b1", "WoodBlock", CFrame.new(0, 2.5, 0))
		assertPlaceOk(p1, "p11_e1", "SmallEngine", CFrame.new(0, 4.5, 0), rareId)
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "p11_s1",
			SlotIndex = 1,
			Name = "Persistido",
		}).Success, "Slot 1 guardado")
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p11_sell2",
			ItemId = "WoodBlock",
			Quantity = 2,
		}).Success, "2 WoodBlock vendidos -> 23")

		-- Simular desconexión y reconexión total del servidor manteniendo persistencia DataStore/MemoryStore
		env.SimulateRejoin(2)
		PlotService.Assign(p1)

		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), 23, "WoodBlock == 23 tras reconectar")
		assertEqual(#InventoryService.GetPlayerEngineUnits(p1), 2, "2 motores únicos preservados (StarterKit + Rare)")
		local rareRestored = EngineInventoryService.GetUnitById(rareId)
		assertTrue(rareRestored ~= nil and rareRestored.RarityId == "Rare" and rareRestored.VariantId == "HighRev", "Stats/Rareza Rare reconstruidos por servidor tras reconexión")
		local ld = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = "p11_ld1",
			SlotIndex = 1,
			ConfirmDiscardUnsaved = true,
		})
		assertTrue(ld.Success, "Slot 1 recarga limpiamente tras reconexión con las unidades persistidas")
		env.Teardown()
	end)

	-- 12) Conservación del inventario tras destrucción física severa
	runTest("Fase 5.1 [12]: Severe physical destruction leaves persistent inventory and slots completely untouched", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51015, Name = "P51_Destruct" }
		PlotService.Assign(p1)

		local v = buildStarterVehicle(p1, "p12")
		local snapBefore = InventoryService.GetPlayerSnapshot(p1) :: any
		local woodBefore = snapBefore.ItemsById.WoodBlock.OwnedQuantity
		local engCountBefore = #snapBefore.EngineUnits
		local bstCountBefore = #snapBefore.BoosterUnits

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Lanzamiento exitoso")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		VehicleDamageService.ApplyImpact(rt, v.Blocks[1], { DamageAmount = 500, Timestamp = env.AdvanceClock(0.5) })
		VehicleDamageService.ApplyImpact(rt, v.EngineId, { DamageAmount = 500, SkipDistribution = true, Timestamp = env.AdvanceClock(0.5) })
		VehicleDamageService.ApplyImpact(rt, v.BoosterId, { DamageAmount = 500, SkipDistribution = true, Timestamp = env.AdvanceClock(0.5) })
		assertTrue(VehicleDestructionService.GetStats().Fragments >= 1, "Se generaron fragmentos físicos reales")

		assertTrue(VehicleLaunchService.ReturnToWorkshop(p1).Success, "Regreso al taller limpio")

		local snapAfter = InventoryService.GetPlayerSnapshot(p1) :: any
		assertEqual(snapAfter.ItemsById.WoodBlock.OwnedQuantity, woodBefore, "WoodBlock intacto tras destrucción")
		assertEqual(#snapAfter.EngineUnits, engCountBefore, "Motores intactos tras destrucción")
		assertEqual(#snapAfter.BoosterUnits, bstCountBefore, "Propulsores intactos tras destrucción")
		assertEqual(snapAfter.ItemsById.SmallEngine.WorkshopReservedQuantity, 1, "Inventario sigue reservando el motor en taller")
		env.Teardown()
	end)

	-- 13) Carga de los 8 modelos desde carpetas en español + protección de BaseTemplate (25 descendientes)
	runTest("Fase 5.1 [13]: Validates 8 physical models in Spanish folders in ItemAssets & PreviewAssets and preserves BaseTemplate", function()
		local env = setupIsolatedWorld(1)
		local itemAssets = ServerStorage:WaitForChild("ItemAssets")
		local previewAssets = ReplicatedStorage:WaitForChild("PreviewAssets")

		local expectedFolders = {
			Bloques = { "WoodBlock", "WoodBeam" },
			Ruedas = { "SmallWheel" },
			Motores = { "SmallEngine" },
			Asientos = { "DriverSeat" },
			Tanques = { "RegularFuelTank", "SmallNitroTank" },
			Propulsores = { "SmallBooster" },
			Aerodinamica = {
				"AircraftWingLeft",
				"AircraftWingRight",
				"AircraftWing",
				"AircraftTail",
				"LargeGliderWing",
				"SmallGliderWing",
			},
		}

		for folderName, itemNames in pairs(expectedFolders) do
			local srvFolder = itemAssets:FindFirstChild(folderName)
			assertTrue(srvFolder ~= nil and srvFolder:IsA("Folder"), `ServerStorage.ItemAssets.{folderName} debe existir`)
			local prvFolder = previewAssets:FindFirstChild(folderName)
			assertTrue(prvFolder ~= nil and prvFolder:IsA("Folder"), `ReplicatedStorage.PreviewAssets.{folderName} debe existir`)

			for _, itemName in ipairs(itemNames) do
				local srvModel = (srvFolder :: Folder):FindFirstChild(itemName)
				assertTrue(srvModel ~= nil and srvModel:IsA("Model"), `Falta modelo {folderName}.{itemName} en ItemAssets`)
				local prvModel = (prvFolder :: Folder):FindFirstChild(itemName)
				assertTrue(prvModel ~= nil and prvModel:IsA("Model"), `Falta modelo {folderName}.{itemName} en PreviewAssets`)
				local resolved, assetFolder = ItemRegistry.ResolveModel(itemAssets, itemName)
				assertEqual(assetFolder, folderName, `AssetFolder para {itemName}`)
				assertEqual(resolved, srvModel, `ResolveModel resolvió carpeta {folderName}`)
			end
		end

		local validation = ItemRegistry.ValidateAssets(itemAssets)
		assertTrue(validation.Valid, "ValidateAssets falla: " .. table.concat(validation.Errors, "; "))
		assertEqual(validation.CheckedCount, 14, "CheckedCount == 14")

		-- Verificar que BaseTemplate conserva exactamente sus 25 descendientes
		local baseTemplate = ServerStorage:FindFirstChild("BaseTemplate")
		assertTrue(baseTemplate ~= nil and baseTemplate:IsA("Model"), "ServerStorage.BaseTemplate existe")
		assertEqual(#(baseTemplate :: Model):GetDescendants(), 25, "ServerStorage.BaseTemplate mantiene sus 25 descendientes intactos")
		env.Teardown()
	end)

	-- 14) Catálogo y textos visibles en español (sin inventar valores TBD)
	runTest("Fase 5.1 [14]: Spanish catalog entries, categories, DriverSeat=Seats/Asientos, and client UI Spanish bindings", function()
		ItemRegistry.Init()
		local entries = ItemCatalog.GetAllEntries()
		assertEqual(#entries, 14, "Catálogo tiene 14 objetos")

		local driverDef = ItemRegistry.Get("DriverSeat")
		assertEqual(driverDef.Category, "Seats", "DriverSeat Category == 'Seats'")
		assertEqual(ItemCatalog.GetCategoryDisplayName("Seats"), "Asientos", "Seats muestra 'Asientos'")

		local byId: { [string]: ItemCatalog.CatalogItemEntry } = {}
		for _, e in ipairs(entries) do
			byId[e.Id] = e
			assertTrue(#e.DisplayName > 0 and #e.Description > 0 and #e.CategoryDisplayName > 0, `Textos españoles completos en {e.Id}`)
		end

		assertEqual(byId.WoodBlock.Price, 10, "WoodBlock.Price == 10")
		assertEqual(byId.WoodBlock.SellPrice, 5, "WoodBlock.SellPrice == 5 (50%)")
		assertEqual(byId.WoodBeam.Price, 8, "WoodBeam.Price == 8")
		assertEqual(byId.WoodBeam.SellPrice, 4, "WoodBeam.SellPrice == 4 (50%)")
		assertEqual(byId.SmallWheel.Price, 25, "SmallWheel.Price == 25")
		assertEqual(byId.SmallWheel.SellPrice, 12, "SmallWheel.SellPrice == 12 (50% floor)")
		assertEqual(byId.RegularFuelTank.Price, 175, "RegularFuelTank.Price == 175")
		assertEqual(byId.RegularFuelTank.SellPrice, 87, "RegularFuelTank.SellPrice == 87 (50% floor)")
		assertEqual(byId.SmallNitroTank.Price, 250, "SmallNitroTank.Price == 250 (Fase 5.2)")
		assertEqual(byId.SmallNitroTank.SellPrice, 125, "SmallNitroTank.SellPrice == 125 (50%)")
		assertEqual(byId.DriverSeat.Price, 100, "DriverSeat.Price == 100 (Fase 5.2)")
		assertEqual(byId.DriverSeat.SellPrice, 50, "DriverSeat.SellPrice == 50 (50%)")
		assertEqual(byId.SmallEngine.Price, nil, "SmallEngine no tiene compra directa (cajas)")
		assertEqual(byId.SmallEngine.SellPrice, nil, "SmallEngine.SellPrice sigue nil (TBD)")
		assertEqual(byId.SmallBooster.Price, nil, "SmallBooster no tiene compra directa (cajas)")
		assertEqual(byId.SmallBooster.SellPrice, nil, "SmallBooster.SellPrice sigue nil (TBD)")

		assertEqual(byId.WoodBlock.DisplayName, "Bloque de madera", "WoodBlock en español")
		assertEqual(byId.WoodBeam.DisplayName, "Viga de madera", "WoodBeam en español")
		assertEqual(byId.SmallWheel.DisplayName, "Rueda pequeña", "SmallWheel en español")
		assertEqual(byId.SmallEngine.DisplayName, "Motor pequeño", "SmallEngine en español")
		assertEqual(byId.DriverSeat.DisplayName, "Asiento del conductor", "DriverSeat en español")
		assertEqual(byId.RegularFuelTank.DisplayName, "Tanque de combustible", "RegularFuelTank en español")
		assertEqual(byId.SmallNitroTank.DisplayName, "Tanque de nitro", "SmallNitroTank en español")
		assertEqual(byId.SmallBooster.DisplayName, "Propulsor pequeño", "SmallBooster en español")

		-- Verificar que los scripts cliente cargan ItemCatalog y contienen UI en español
		local engPanelMod = require(ClientControllers:WaitForChild("EngineInspectorPanel") :: ModuleScript)
		local bstPanelMod = require(ClientControllers:WaitForChild("BoosterInspectorPanel") :: ModuleScript)
		assertTrue(type(engPanelMod.Mount) == "function" and type(bstPanelMod.Mount) == "function", "Inspectores cargan limpiamente")
		if not game:GetService("RunService"):IsRunning() then
			local vm = ClientControllers:WaitForChild("VehicleManagement") :: LocalScript
			local bc = ClientControllers:WaitForChild("BuildController") :: LocalScript
			assertTrue(string.find(vm.Source, "InventoryToggleBtn", 1, true) ~= nil, "Botón Inventario presente")
			assertTrue(string.find(vm.Source, "InventoryPanel", 1, true) ~= nil, "Panel Inventario presente")
			assertTrue(string.find(vm.Source, "Desvincular", 1, true) ~= nil, "Modal desvincular presente")
			assertTrue(string.find(bc.Source, "ItemCatalog.GetAllEntries", 1, true) ~= nil, "Paleta usa ItemCatalog centralizado")
		end
	end)

	-- 15) Flujo E2E completo con inventario real: construir -> slot -> lanzar -> destruir -> volver -> vender
	runTest("Fase 5.1 [15]: E2E real-inventory regression across build, slot save, launch, drive, damage, return and sell", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 51016, Name = "P51_E2E" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local starter = buildStarterVehicle(p1, "p15")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 13, "Vehículo completo de 13 piezas construido con StarterKit")

		-- Intentar agregar un segundo asiento de conductor (posee 1) -> bloqueado (TooManyDriverSeats o InsufficientInventory)
		local extraSeat = placeReq(p1, "p15_seat2", "DriverSeat", CFrame.new(0, 6.0, 2))
		assertEqual(extraSeat.Success, false, "No se permite 2do DriverSeat")

		-- Guardar Slot 1
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "p15_s1",
			SlotIndex = 1,
			Name = "VehiculoE2E",
		}).Success, "Slot 1 guardado")

		-- Lanzar y aplicar aceleración + boost + impacto parcial + retorno
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, `E2E Launch failed: {tostring(lr.ErrorMessage)}`)
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(0.2)

		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SetDrivingInput,
			ClientOpId = "p15_drive",
			Throttle = 1,
			Brake = 0,
			RawLongitudinal = 1,
			Steer = 0,
			Boost = true,
		})
		VehiclePowertrainService.StepAll(1 / 60)
		VehicleBoosterService.StepAll(1 / 60)

		VehicleDamageService.ApplyImpact(rt, starter.Blocks[1], { DamageAmount = 500, Timestamp = env.AdvanceClock(1.0) })
		assertTrue(VehicleLaunchService.ReturnToWorkshop(p1).Success, "Regreso al taller E2E exitoso")

		-- Regresar limpió destrucción y preservó inventario + blueprint
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 13, "Las 13 piezas intactas en el taller")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), 20, "Inventario intacto tras retorno")

		-- Vender 10 WoodBlocks excedentes (16 vendibles: 20 - 4 en uso)
		local sellSpare = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p15_sell_spare",
			ItemId = "WoodBlock",
			Quantity = 10,
		})
		assertTrue(sellSpare.Success, "Venta de 10 bloques sobrantes permitida")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "WoodBlock"), 10, "WoodBlock ahora == 10")

		-- Limpiar jugador y verificar 0 fugas
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.ClearWorkshop, ClientOpId = "p15_clr" })
		PlotService.Release(p1)
		assertEqual(#plot.DynamicContainer:GetChildren(), 0, "DynamicContainer vacío")
		assertEqual(VehicleBlueprintService.GetTrackedPlayerCount(), 0, "0 blueprints activos en memoria")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "0 runtimes activos")
		assertEqual(VehicleDestructionService.GetStats().Fragments, 0, "0 fragmentos residuales")
		env.Teardown()
	end)
end

function Phase51Tests.RunAll()
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

	Phase51Tests.AppendTests(results, runTest)

	return {
		Passed = passed,
		Failed = failed,
		Results = results,
	}
end

return Phase51Tests
