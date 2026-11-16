--!strict
--[=[
	ConnectionHotfixTests
	Suite de 18 pruebas automatizadas para el hotfix crítico de grafo de conexiones en blueprints:
	  1. Conexiones al colocar piezas (Conn_* + contacto OBB cara con cara sin Conn_* en las 8 piezas base)
	  2. Guardar conexiones (15 piezas + SaveAsNew)
	  3. Cargar conexiones (5+ ciclos y reconstrucción desde guardado/serializado sin perder grupo principal)
	  4. Duplicar blueprint preservando grafo de conexiones y PieceIds válidos
	  5. Crear blueprint nuevo (limpieza de caché de servidor y caché raycast del cliente)
	  6. Cambiar entre blueprints de igual/distinta revisión sin contaminación cruzada
	  7. Agregar piezas conectadas después de cargar (incluyendo caras sin Conn_*)
	  8. Eliminar piezas conectadas sin dejar referencias huérfanas
	  9. Transformar piezas conectadas (separar y volver a acoplar cara con cara)
	 10. Reconstrucción segura del grafo (sin unir piezas separadas ni con 0.45 studs de aire)
	 11. PieceIds válidos y saneo en BlueprintSerializer
	 12. Detección del ensamblaje principal y advertencias de asiento aislado / componentes excluidos
	 13. Exclusión correcta de piezas sueltas junto al vehículo completo de 15 piezas
	 14. Inclusión de motor y 4 ruedas motrices en LaunchPrep tras recargar
	 15. Lanzamiento completo con runtime íntegro y joints deduplicados
	 16. Orientación correcta del asiento en LaunchPoint (plot normal y rotado 90°)
	 17. Compatibilidad y aislamiento simultáneo entre múltiples plots (Plot_01 y Plot_07)
	 18. Regreso al taller, edición adicional, guardado y relanzamiento completo
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local PlotService = require(ServerScriptService.Server.Services.PlotService)
local SpawnService = require(ServerScriptService.Server.Services.SpawnService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local StandPreviewService = require(ServerScriptService.Server.Services.StandPreviewService)
local VehicleLaunchPreparationService = require(ServerScriptService.Server.Services.VehicleLaunchPreparationService)
local ItemRuntimeService = require(ServerScriptService.Server.Services.ItemRuntimeService)
local VehicleAssemblyService = require(ServerScriptService.Server.Services.VehicleAssemblyService)
local VehicleRuntimeService = require(ServerScriptService.Server.Services.VehicleRuntimeService)
local VehicleLifecycleService = require(ServerScriptService.Server.Services.VehicleLifecycleService)
local VehicleLaunchService = require(ServerScriptService.Server.Services.VehicleLaunchService)
local BuildService = require(ServerScriptService.Server.Services.BuildService)
local WheelAutoConfigurationService = require(ServerScriptService.Server.Services.WheelAutoConfigurationService)
local VehicleWheelControllerService = require(ServerScriptService.Server.Services.VehicleWheelControllerService)
local VehiclePowertrainService = require(ServerScriptService.Server.Services.VehiclePowertrainService)

local ClientControllers =
	game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState"))
local BuildPreviewController = require(ClientControllers:WaitForChild("BuildPreviewController"))

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local ConnectionHotfixTests = {}

local function assertTrue(cond: any, msg: string)
	if not cond then
		error(msg, 2)
	end
end

local function assertEqual(actual: any, expected: any, msg: string)
	if actual ~= expected then
		error(`{msg} (expected={tostring(expected)}, actual={tostring(actual)})`, 2)
	end
end

local function countParts(rt: VehicleTypes.VehicleRuntime): number
	local n = 0
	for _ in pairs(rt.Parts) do
		n += 1
	end
	return n
end

local function setupIsolatedWorld(plotCount: number?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder

	local prevPlots = Workspace:FindFirstChild("_ConnHotfixTestPlots")
	if prevPlots then
		prevPlots:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_ConnHotfixTestPlots"
	tempPlots.Parent = Workspace

	BuildPreviewController.DestroyGhost()
	BuildService._ResetForTests()
	VehicleLaunchService._ResetForTests()
	VehicleLifecycleService._ResetForTests()
	VehicleRuntimeService._ResetForTests()
	VehiclePowertrainService._ResetForTests()
	VehicleWheelControllerService._ResetForTests()
	VehicleAssemblyService._ResetForTests()
	ItemRuntimeService._ResetForTests()
	VehicleLaunchPreparationService._ResetForTests()
	StandPreviewService._ResetForTests()
	VehicleBlueprintService._ResetForTests()
	InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
	ConnectionService._ResetForTests()
	WheelAutoConfigurationService._ResetForTests()
	EngineInventoryService.ResetAllForTests()
	SpawnService._ResetForTests()
	PlotService._ResetForTests()
	BuildState.Reset()

	local assets = ServerStorage:WaitForChild("ItemAssets")
	PlotService.Init({
		BaseTemplate = baseTemplate,
		PlotSpawnsFolder = plotSpawns,
		PlotsParent = tempPlots,
		PlotCount = plotCount or 8,
	})
	SpawnService.Init()
	InventoryService.Init()
	EngineInventoryService.Init()
	WheelAutoConfigurationService.Init({ ItemAssetsRoot = assets })
	ConnectionService.Init({ ItemAssetsRoot = assets })
	VehicleAssemblyService.Init({ ItemAssetsRoot = assets })
	VehicleBlueprintService.Init({ ItemAssetsRoot = assets })
	StandPreviewService.Init({ ItemAssetsRoot = assets })
	VehicleLaunchPreparationService.Init({ ItemAssetsRoot = assets })
	ItemRuntimeService.Init({ ItemAssetsRoot = assets })
	VehicleWheelControllerService.Init()
	VehiclePowertrainService.Init()
	VehicleRuntimeService.Init()
	VehicleLifecycleService.Init()
	VehicleLaunchService.Init()
	BuildService.Init()

	local rateClock = 1000
	local lifeClock = 1000
	BuildService._SetRateLimitClockForTests(function()
		rateClock += 1.0
		return rateClock
	end)
	VehicleLaunchService._SetClockForTests(function()
		return lifeClock
	end)
	VehicleLifecycleService._SetClockForTests(function()
		return lifeClock
	end)

	return {
		AdvanceLifeClock = function(seconds: number)
			lifeClock += seconds
		end,
		Teardown = function()
			BuildPreviewController.DestroyGhost()
			BuildService._ResetForTests()
			VehicleLaunchService._ResetForTests()
			VehicleLifecycleService._ResetForTests()
			VehicleRuntimeService._ResetForTests()
			VehiclePowertrainService._ResetForTests()
			VehicleWheelControllerService._ResetForTests()
			VehicleAssemblyService._ResetForTests()
			ItemRuntimeService._ResetForTests()
			VehicleLaunchPreparationService._ResetForTests()
			StandPreviewService._ResetForTests()
			VehicleBlueprintService._ResetForTests()
			InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = false })
			ConnectionService._ResetForTests()
			WheelAutoConfigurationService._ResetForTests()
			EngineInventoryService.ResetAllForTests()
			SpawnService._ResetForTests()
			PlotService._ResetForTests()
			BuildState.Reset()
			tempPlots:Destroy()
		end,
	}
end

local function placePiece(
	player: PlotService.PlayerLike,
	opId: string,
	itemId: string,
	localCF: CFrame,
	config: { [string]: any }?
): VehicleTypes.BlueprintPiece
	local res = BuildService.ProcessRequest(player, {
		Action = BuildProtocol.Actions.PlacePiece,
		ClientOpId = opId,
		ItemId = itemId,
		LocalCFrame = localCF,
		Config = config,
	})
	assertTrue(res.Success and res.PlacedPiece ~= nil, `Failed to place {itemId} ({opId}): {tostring(res.ErrorMessage)}`)
	return res.PlacedPiece :: VehicleTypes.BlueprintPiece
end

--[=[
	Construye un vehículo realista de exactamente 15 piezas donde:
	- El chasis central usa WoodBlock + WoodBeam
	- RegularFuelTank (2x2x3, sin Conn_Top ni Conn_Left/Right) va conectado al bloque central
	- DriverSeat (2x1x2, sin Conn_Front/Left/Right) va colocado ENCIMA de RegularFuelTank (+Y, sin Conn_Top en el tanque)
	- 1 SmallEngine, 4 SmallWheel, y refuerzos WoodBeam/SmallBooster completan las 15 piezas.
	Antes del hotfix, DriverSeat encima de RegularFuelTank quedaba aislado como ensamblaje de 1 pieza con 14 excluidas.
]=]
local function buildRealistic15PieceCar(player: PlotService.PlayerLike, prefix: string): {
	SeatId: string,
	EngineId: string,
	TankId: string,
	WheelIds: { string },
	BlockIds: { string },
}
	-- Fila inferior de chasis principal en Y=1.5: 3 bloques Z=-2, 0, +2 y vigas laterales
	local bFront = placePiece(player, `{prefix}_bF`, "WoodBlock", CFrame.new(0, 1.5, -2))
	local bMid = placePiece(player, `{prefix}_bM`, "WoodBlock", CFrame.new(0, 1.5, 0))
	local bRear = placePiece(player, `{prefix}_bR`, "WoodBlock", CFrame.new(0, 1.5, 2))

	-- Vigas laterales para ejes y refuerzo frontal (Total chasis hasta acá = 8)
	local bFrontL = placePiece(player, `{prefix}_bFL`, "WoodBlock", CFrame.new(-2, 1.5, -2))
	local bFrontR = placePiece(player, `{prefix}_bFR`, "WoodBlock", CFrame.new(2, 1.5, -2))
	local bRearL = placePiece(player, `{prefix}_bRL`, "WoodBlock", CFrame.new(-2, 1.5, 2))
	local bRearR = placePiece(player, `{prefix}_bRR`, "WoodBlock", CFrame.new(2, 1.5, 2))
	local beamF = placePiece(player, `{prefix}_beamF`, "WoodBeam", CFrame.new(0, 1.5, -5))

	-- Tanque de combustible encima de bFront/bMid (Z=[-2.0, +1.0], Y=[2.5, 4.5]) (9)
	local tank = placePiece(player, `{prefix}_tank`, "RegularFuelTank", CFrame.new(0, 3.5, -0.5))

	-- Motor sobre bloque trasero bRear tocando atrás del tanque en Z=+1.0 (Z=[1.0, 3.0], Y=[2.5, 4.5]) (10)
	local engine = placePiece(player, `{prefix}_eng`, "SmallEngine", CFrame.new(0, 3.5, 2.0))

	-- DriverSeat colocado DIRECTAMENTE ENCIMA del RegularFuelTank (+Y sin Conn_Top en el tanque) (11)
	local seat = placePiece(player, `{prefix}_seat`, "DriverSeat", CFrame.new(0, 5.0, -0.5))

	-- 4 Ruedas montadas a los bloques esquineros (12, 13, 14, 15 -> total exacto 15 piezas)
	local wFL = placePiece(player, `{prefix}_wFL`, "SmallWheel", CFrame.new(-3.5, 1.5, -2))
	local wFR = placePiece(player, `{prefix}_wFR`, "SmallWheel", CFrame.new(3.5, 1.5, -2))
	local wRL = placePiece(player, `{prefix}_wRL`, "SmallWheel", CFrame.new(-3.5, 1.5, 2))
	local wRR = placePiece(player, `{prefix}_wRR`, "SmallWheel", CFrame.new(3.5, 1.5, 2))

	return {
		SeatId = seat.InstanceId,
		EngineId = engine.InstanceId,
		TankId = tank.InstanceId,
		WheelIds = { wFL.InstanceId, wFR.InstanceId, wRL.InstanceId, wRR.InstanceId },
		BlockIds = {
			bFront.InstanceId,
			bMid.InstanceId,
			bRear.InstanceId,
			bFrontL.InstanceId,
			bFrontR.InstanceId,
			bRearL.InstanceId,
			bRearR.InstanceId,
			beamF.InstanceId,
		},
	}
end

function ConnectionHotfixTests.AppendTests(results: { TestCaseResult }, runTest: (name: string, fn: () -> ()) -> ())
	-- 1
	runTest("ConnHotfix [01]: Placement detects flush surface connections across missing-Conn_* faces (DriverSeat, FuelTank, Booster, Beam, 45deg)", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41001, Name = "PlaceSurfaceTester" }
		PlotService.Assign(p1)

		-- DriverSeat colocado de frente (-Z), de costado (+X) y encima de RegularFuelTank (+Y sin Conn_Top)
		local tank = placePiece(p1, "p1_tank", "RegularFuelTank", CFrame.new(0, 1.5, 0))
		local seat = placePiece(p1, "p1_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		local frontBlock = placePiece(p1, "p1_front", "WoodBlock", CFrame.new(0, 1.5, -2.5))
		-- WoodBlock en lateral derecho de RegularFuelTank (+X sin Conn_Right)
		local sideBlock = placePiece(p1, "p1_side", "WoodBlock", CFrame.new(2.0, 1.5, 0))
		-- SmallBooster trasero pegado al tanque y bloque al costado de SmallBooster (sin Conn_Right)
		local booster = placePiece(p1, "p1_bst", "SmallBooster", CFrame.new(0, 1.5, 3.0))
		local sideBst = placePiece(p1, "p1_sbst", "WoodBlock", CFrame.new(-1.75, 1.5, 3.0))

		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local analysis = ConnectionService.AnalyzeBlueprintAssemblies(bp)
		assertEqual(#bp.Pieces, 6, "Expected 6 placed pieces")
		assertEqual(#analysis.Groups, 1, `All 6 flush pieces should form 1 connected assembly; got {#analysis.Groups} groups`)
		assertEqual(#analysis.WorkshopPieceIds, 0, "No piece should be wrongly excluded")
		assertTrue(#bp.Connections >= 5, `Expected at least 5 graph edges, got {#bp.Connections}`)

		-- Verificar que una pieza a 0.45 studs de aire NO se conecta por superficie ni una pieza diagonal de esquina
		local farLoose = placePiece(p1, "p1_air", "WoodBlock", CFrame.new(4.45, 1.5, 0)) -- sideBlock X=2 (+1 => 3.0), farLoose X=4.45 (-1 => 3.45, gap = 0.45)
		local diagCorner = placePiece(p1, "p1_diag", "WoodBlock", CFrame.new(-2.0, 3.5, -2.5)) -- solo toca en arista a frontBlock(0,1.5,-2.5)
		local diag = ConnectionService.InspectBlueprintConnections(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		assertEqual(#diag.Groups, 3, "Air-separated (0.45) and edge-only diagonal block must stay separated (3 groups total)")
		assertEqual(#diag.ExcludedPieceIds, 2, "Expected 2 excluded disconnected pieces")
		assertTrue(
			table.find(diag.ExcludedPieceIds, farLoose.InstanceId) ~= nil
				and table.find(diag.ExcludedPieceIds, diagCorner.InstanceId) ~= nil,
			"Both air-gap and edge-graze pieces remain properly excluded"
		)
		assertTrue(
			diag.DisconnectReasons[farLoose.InstanceId] ~= nil and diag.DisconnectReasons[diagCorner.InstanceId] ~= nil,
			"Diagnostics include disconnect reasons for excluded pieces"
		)

		-- También probar ConnectionMath directo con 2 cajas rotadas 45° en contacto rasante vs con aire
		local rot45 = CFrame.Angles(0, math.rad(45), 0)
		local normal45 = rot45.RightVector
		local specA = ConnectionMath.PreparePieceSpec({
			InstanceId = "rA",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 5, 0) * rot45,
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		})
		local specB = ConnectionMath.PreparePieceSpec({
			InstanceId = "rB",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(Vector3.new(0, 5, 0) + normal45 * 2.0) * rot45,
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		})
		local c45 = ConnectionMath.FindCompatibleConnections(specB, { specA })
		assertEqual(#c45, 1, "45-deg flush OBB faces must connect")
		local specB_gap = ConnectionMath.PreparePieceSpec({
			InstanceId = "rBg",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(Vector3.new(0, 5, 0) + normal45 * 2.45) * rot45,
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		})
		assertEqual(#ConnectionMath.FindCompatibleConnections(specB_gap, { specA }), 0, "45-deg OBB with 0.45 gap must stay disconnected")

		local _unused = { tank, seat, frontBlock, sideBlock, booster, sideBst }
		env.Teardown()
	end)

	-- 2
	runTest("ConnHotfix [02]: SaveBlueprint preserves all 15 pieces and full connection graph cleanly", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41002, Name = "SaveConns" }
		PlotService.Assign(p1)
		buildRealistic15PieceCar(p1, "t2")

		local before = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local saveRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprint,
			ClientOpId = "t2_save",
			Name = "Auto15",
		})
		assertTrue(saveRes.Success and saveRes.Blueprint ~= nil, "Save failed")
		local savedBp = saveRes.Blueprint :: VehicleTypes.VehicleBlueprint
		assertEqual(#savedBp.Pieces, 15, "Saved 15 pieces")
		assertEqual(#savedBp.Connections, #before.Connections, "Connection count preserved after Save")

		local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(prep.TotalPieceCount, 15, "Total = 15")
		assertEqual(prep.PieceCount, 15, "PrimaryAssembly = 15")
		assertEqual(prep.WorkshopPieceCount, 0, "Excluded = 0")
		assertEqual(prep.EngineCount, 1, "EngineCount = 1")
		assertEqual(prep.DrivenWheelCount, 4, "DrivenWheelCount = 4")
		env.Teardown()
	end)

	-- 3
	runTest("ConnHotfix [03]: LoadBlueprint across 5 save/load cycles and empty-Connections recovery keeps 15/15 PrimaryAssembly", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41003, Name = "LoadCycles" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildRealistic15PieceCar(p1, "t3")

		local saveRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprint,
			ClientOpId = "t3_save",
			Name = "Car15Cycles",
		})
		assertTrue(saveRes.Success and saveRes.Blueprint ~= nil, "Save failed")
		local targetId = (saveRes.Blueprint :: VehicleTypes.VehicleBlueprint).BlueprintId
		local expectedConns = #(saveRes.Blueprint :: VehicleTypes.VehicleBlueprint).Connections

		-- Crear blueprint nuevo temporal para forzar cambio completo de contexto
		local newRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.CreateBlueprint,
			ClientOpId = "t3_new",
			Name = "Otro",
		})
		assertTrue(newRes.Success, "Create new blueprint failed")

		for cycle = 1, 5 do
			local loadRes = BuildService.ProcessRequest(p1, {
				Action = BuildProtocol.Actions.LoadBlueprint,
				ClientOpId = `t3_load_{cycle}`,
				BlueprintId = targetId,
			})
			assertTrue(loadRes.Success and loadRes.Blueprint ~= nil, `Load cycle {cycle} failed`)
			local loadedBp = loadRes.Blueprint :: VehicleTypes.VehicleBlueprint
			assertEqual(#loadedBp.Pieces, 15, `Cycle {cycle}: expected 15 pieces`)
			assertEqual(#loadedBp.Connections, expectedConns, `Cycle {cycle}: connection count drifted`)

			local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
			assertEqual(prep.PieceCount, 15, `Cycle {cycle}: PrimaryAssembly must be 15`)
			assertEqual(prep.WorkshopPieceCount, 0, `Cycle {cycle}: 0 excluded pieces`)
			assertEqual(prep.EngineCount, 1, `Cycle {cycle}: 1 engine`)
			assertEqual(prep.DrivenWheelCount, 4, `Cycle {cycle}: 4 driven wheels`)

			local resSaveAgain = BuildService.ProcessRequest(p1, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = `t3_resave_{cycle}`,
			})
			assertTrue(resSaveAgain.Success, `Resave cycle {cycle} failed`)
		end

		-- También simular carga/importación de un blueprint guardado legacy con Connections = {}
		local serialized = BlueprintSerializer.SerializeBlueprint(saveRes.Blueprint :: VehicleTypes.VehicleBlueprint)
		serialized.BlueprintId = "bp_legacy_empty_conns"
		serialized.Connections = {}
		local impOk, impBp = VehicleBlueprintService.ImportSerializedBlueprint(p1, plot, serialized)
		assertTrue(impOk and impBp ~= nil, "Import legacy empty-Connections blueprint failed")
		local rebuiltBp = impBp :: VehicleTypes.VehicleBlueprint
		assertTrue(#rebuiltBp.Connections >= 14, `Expected reconstructed valid edges >= 14, got {#rebuiltBp.Connections}`)
		local prepImp = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(prepImp.PieceCount, 15, "Imported legacy vehicle recovered full 15/15 PrimaryAssembly")
		env.Teardown()
	end)

	-- 4
	runTest("ConnHotfix [04]: DuplicateBlueprint preserves connections, reconciles graph and validates all PieceIds", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41004, Name = "DupConns" }
		PlotService.Assign(p1)
		buildRealistic15PieceCar(p1, "t4")

		local saveRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprint,
			ClientOpId = "t4_save",
			Name = "Origen15",
		})
		local srcId = (saveRes.Blueprint :: VehicleTypes.VehicleBlueprint).BlueprintId
		local srcConns = #(saveRes.Blueprint :: VehicleTypes.VehicleBlueprint).Connections

		local dupRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.DuplicateBlueprint,
			ClientOpId = "t4_dup",
			BlueprintId = srcId,
			Name = "Copia15",
		})
		assertTrue(dupRes.Success and dupRes.DuplicatedBlueprint ~= nil, "Duplicate failed")
		local dupId = (dupRes.DuplicatedBlueprint :: VehicleTypes.BlueprintSummary).BlueprintId

		local loadDup = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprint,
			ClientOpId = "t4_load_dup",
			BlueprintId = dupId,
		})
		assertTrue(loadDup.Success and loadDup.Blueprint ~= nil, "Load duplicate failed")
		local dupBp = loadDup.Blueprint :: VehicleTypes.VehicleBlueprint
		assertEqual(#dupBp.Pieces, 15, "Duplicate piece count = 15")
		assertEqual(#dupBp.Connections, srcConns, "Duplicate connections preserved")

		local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(prep.PieceCount, 15, "Duplicate PrimaryAssembly = 15")
		assertEqual(prep.EngineCount, 1, "Duplicate recognizes Engine")
		assertEqual(prep.DrivenWheelCount, 4, "Duplicate recognizes 4 driven wheels")
		env.Teardown()
	end)

	-- 5
	runTest("ConnHotfix [05]: CreateBlueprint resets server cache cleanly and client BuildPreviewController invalidates ray cache at same Revision=0", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41005, Name = "CreateReset" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildRealistic15PieceCar(p1, "t5")

		local createRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.CreateBlueprint,
			ClientOpId = "t5_new1",
			Name = "Nuevo1",
		})
		assertTrue(createRes.Success and createRes.Blueprint ~= nil, "CreateBlueprint #1 failed")
		local bpNew1 = createRes.Blueprint :: VehicleTypes.VehicleBlueprint
		assertEqual(#bpNew1.Pieces, 0, "New blueprint has 0 pieces")
		assertEqual(#bpNew1.Connections, 0, "New blueprint has 0 connections")

		-- Simular caché cliente raycast al cambiar entre dos blueprints distintos ambos con Revision = 0
		BuildState.Reset()
		BuildState.SetExpectedOwner(p1.UserId)
		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		BuildState.ApplyAuthoritativeBlueprint(bpNew1, true)
		BuildState.SetActive(true)
		BuildState.SelectItem("WoodBlock")
		BuildState.SetFaceSnapEnabled(true)
		BuildPreviewController.InvalidateRayCache()

		local origin = plot.Zones.BuildZone.CFrame:PointToWorldSpace(Vector3.new(0, 12, 0))
		local dir = plot.Zones.BuildZone.CFrame:VectorToWorldSpace(Vector3.new(0, -1, 0))
		local ok1, cf1 = BuildPreviewController.UpdateFromRay(origin, dir * 30)
		assertTrue(ok1 and cf1 ~= nil, "Ray update in New1 failed")
		local local1 = plot.Zones.BuildZone.CFrame:PointToObjectSpace((cf1 :: CFrame).Position)

		-- Cambiar a segundo blueprint (Revision = 0, distinto BlueprintId) SIN llamar InvalidateRayCache()
		local rawRev0 = BlueprintSerializer.SerializeBlueprint({
			BlueprintId = "bp_rev0_second",
			OwnerUserId = p1.UserId,
			Name = "SegundoRev0",
			SchemaVersion = GameConfig.Blueprints.CurrentSchemaVersion,
			Revision = 0,
			CreatedAt = os.time(),
			UpdatedAt = os.time(),
			Pieces = {
				{
					InstanceId = "rev0_b1",
					ItemId = "WoodBlock",
					LocalCFrame = CFrame.new(0, local1.Y, 0),
				},
			},
			Connections = {},
		})
		local impOk, bpNew2 = VehicleBlueprintService.ImportSerializedBlueprint(p1, plot, rawRev0)
		assertTrue(impOk and bpNew2 ~= nil, "Import second Rev=0 blueprint failed")
		local bp2 = bpNew2 :: VehicleTypes.VehicleBlueprint
		assertEqual(bp2.Revision, 0, "Imported second blueprint must still have Revision = 0")
		BuildState.ApplyAuthoritativeBlueprint(bp2, true)
		BuildState.SelectItem("WoodBlock")
		local ok2, cf2 = BuildPreviewController.UpdateFromRay(origin, dir * 30)
		assertTrue(ok2 and cf2 ~= nil, "Ray update after switching to second Rev=0 blueprint must NOT fail due to stale cache")
		local local2 = plot.Zones.BuildZone.CFrame:PointToObjectSpace((cf2 :: CFrame).Position)
		assertTrue(
			local2.Y > local1.Y + 1.0,
			`Expected ray cache miss on BlueprintId change at Revision=0 (floor Y={local1.Y}, stacked Y={local2.Y})`
		)

		-- Crear un nuevo blueprint limpio antes de construir el vehículo de 15 piezas
		local createRes3 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.CreateBlueprint,
			ClientOpId = "t5_new3",
			Name = "NuevoLimpio",
		})
		assertTrue(createRes3.Success and createRes3.Blueprint ~= nil, "CreateBlueprint #3 failed")

		-- Construir 15 piezas en el blueprint recién creado y verificar 15/15
		buildRealistic15PieceCar(p1, "t5_fresh")
		local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(prep.PieceCount, 15, "Fresh blueprint build must recognize all 15 connected pieces")
		assertEqual(prep.EngineCount, 1, "Fresh blueprint build detects Engine")
		assertEqual(prep.DrivenWheelCount, 4, "Fresh blueprint build detects 4 driven wheels")
		env.Teardown()
	end)

	-- 6
	runTest("ConnHotfix [06]: Switching repeatedly between blueprints with identical PieceCount/Revision isolates ConnectionService caches", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41006, Name = "SwitchCacheIso" }
		PlotService.Assign(p1)

		-- Blueprint A: bloque en X=0 + asiento en X=0,Y=2.5 (Revision=2)
		placePiece(p1, "s6_a1", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePiece(p1, "s6_a2", "DriverSeat", CFrame.new(0, 3.0, 0))
		local svA = BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.SaveBlueprint, ClientOpId = "s6_svA", Name = "BP_A" })
		local idA = (svA.Blueprint :: VehicleTypes.VehicleBlueprint).BlueprintId

		-- Blueprint B: bloque en X=10 + asiento en X=10,Y=3.0 (misma Revision=2 y misma cantidad=2)
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.CreateBlueprint, ClientOpId = "s6_newB", Name = "BP_B" })
		placePiece(p1, "s6_b1", "WoodBlock", CFrame.new(10, 1.5, 0))
		placePiece(p1, "s6_b2", "DriverSeat", CFrame.new(10, 3.0, 0))
		local svB = BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.SaveBlueprint, ClientOpId = "s6_svB", Name = "BP_B" })
		local idB = (svB.Blueprint :: VehicleTypes.VehicleBlueprint).BlueprintId

		for i = 1, 3 do
			local ldA = BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.LoadBlueprint, ClientOpId = `s6_la_{i}`, BlueprintId = idA })
			assertTrue(ldA.Success, "Load A failed")
			-- Debe poder colocar sin overlap en X=10 (posición vieja de B)
			local testPlaceInA = placePiece(p1, `s6_pa_{i}`, "WoodBlock", CFrame.new(10, 1.5, 0))
			assertTrue(testPlaceInA ~= nil, "Cache from B leaked into A!")
			BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.RemovePiece, ClientOpId = `s6_ra_{i}`, PieceInstanceId = testPlaceInA.InstanceId })

			local ldB = BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.LoadBlueprint, ClientOpId = `s6_lb_{i}`, BlueprintId = idB })
			assertTrue(ldB.Success, "Load B failed")
			-- Debe poder colocar sin overlap en X=0 (posición vieja de A) y conectarse normalmente a B si se coloca en X=12
			local attachB = placePiece(p1, `s6_pb_{i}`, "WoodBlock", CFrame.new(12, 1.5, 0))
			local snapB = VehicleBlueprintService.GetBlueprintSnapshot(p1)
			local analysisB = ConnectionService.AnalyzeBlueprintAssemblies(snapB)
			assertEqual(#analysisB.Groups, 1, `Piece placed next to B on cycle {i} should connect to B`)
			BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.RemovePiece, ClientOpId = `s6_rb_{i}`, PieceInstanceId = attachB.InstanceId })
		end
		env.Teardown()
	end)

	-- 7
	runTest("ConnHotfix [07]: Adding connected pieces after LoadBlueprint incorporates them into PrimaryAssembly across further saves", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41007, Name = "AddAfterLoad" }
		PlotService.Assign(p1)
		buildRealistic15PieceCar(p1, "t7")

		local sv = BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.SaveBlueprint, ClientOpId = "t7_sv", Name = "Car15" })
		local bpId = (sv.Blueprint :: VehicleTypes.VehicleBlueprint).BlueprintId
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.CreateBlueprint, ClientOpId = "t7_tmp", Name = "Tmp" })
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.LoadBlueprint, ClientOpId = "t7_ld", BlueprintId = bpId })

		-- Agregar SmallNitroTank al costado del tanque regular y SmallBooster tocando atrás del motor (+Z)
		placePiece(p1, "t7_add_tank", "SmallNitroTank", CFrame.new(-2, 3.5, -0.5)) -- al lado izquierdo de RegularFuelTank (0, 3.5, -0.5)
		placePiece(p1, "t7_add_bst", "SmallBooster", CFrame.new(0, 3.5, 4.5)) -- tocando atrás del motor (Z=3.0)

		local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(prep.TotalPieceCount, 17, "Total should be 17")
		assertEqual(prep.PieceCount, 17, "Both post-load pieces (including FuelTank side contact) must join PrimaryAssembly")
		assertEqual(prep.WorkshopPieceCount, 0, "Zero excluded pieces")

		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.SaveBlueprint, ClientOpId = "t7_sv2" })
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.LoadBlueprint, ClientOpId = "t7_ld2", BlueprintId = bpId })
		local prepReloaded = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(prepReloaded.PieceCount, 17, "Reloaded blueprint maintains 17/17 connected pieces")
		env.Teardown()
	end)

	-- 8
	runTest("ConnHotfix [08]: Removing connected pieces cleanly strips incident edges without orphan PieceIds", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41008, Name = "RemoveClean" }
		PlotService.Assign(p1)
		local info = buildRealistic15PieceCar(p1, "t8")

		local remRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.RemovePiece,
			ClientOpId = "t8_rem",
			PieceInstanceId = info.WheelIds[1],
		})
		assertTrue(remRes.Success and remRes.Blueprint ~= nil, "Remove wheel failed")
		local bpAfter = remRes.Blueprint :: VehicleTypes.VehicleBlueprint
		assertEqual(#bpAfter.Pieces, 14, "14 pieces remain")

		local byId: { [string]: boolean } = {}
		for _, pc in ipairs(bpAfter.Pieces) do
			byId[pc.InstanceId] = true
		end
		for _, c in ipairs(bpAfter.Connections) do
			assertTrue(byId[c.FromPieceId] and byId[c.ToPieceId], "No orphan PieceIds allowed after RemovePiece")
			assertTrue(c.FromPieceId ~= info.WheelIds[1] and c.ToPieceId ~= info.WheelIds[1], "Removed wheel ID must not appear in Connections")
		end
		env.Teardown()
	end)

	-- 9
	runTest("ConnHotfix [09]: Transforming connected piece away detaches cleanly and moving back flush re-establishes surface connections", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41009, Name = "TransformReconn" }
		PlotService.Assign(p1)

		placePiece(p1, "t9_tank", "RegularFuelTank", CFrame.new(0, 1.5, 0))
		local seat = placePiece(p1, "t9_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		assertEqual(#ConnectionService.AnalyzeBlueprintAssemblies(VehicleBlueprintService.GetBlueprintSnapshot(p1)).Groups, 1, "Connected on tank top initially")

		-- Separar el asiento 4 studs arriba -> queda desconectado en 2 grupos
		local moveAway = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.TransformPiece,
			ClientOpId = "t9_away",
			PieceInstanceId = seat.InstanceId,
			LocalCFrame = CFrame.new(0, 7.0, 0),
		})
		assertTrue(moveAway.Success and moveAway.Blueprint ~= nil, "Move away failed")
		assertEqual(#(moveAway.Blueprint :: VehicleTypes.VehicleBlueprint).Connections, 0, "Detached seat has 0 connections")
		assertEqual(#ConnectionService.AnalyzeBlueprintAssemblies(moveAway.Blueprint :: VehicleTypes.VehicleBlueprint).Groups, 2, "Separated into 2 groups")

		-- Mover asiento contra la cara frontal (-Z) del tanque (tank halfZ=1.5 -> -1.5; seat halfZ=1.0 -> -2.5; sin Conn_Front en DriverSeat!)
		local moveFront = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.TransformPiece,
			ClientOpId = "t9_front",
			PieceInstanceId = seat.InstanceId,
			LocalCFrame = CFrame.new(0, 1.5, -2.5),
		})
		assertTrue(moveFront.Success and moveFront.Blueprint ~= nil, "Move onto tank front failed")
		assertEqual(#(moveFront.Blueprint :: VehicleTypes.VehicleBlueprint).Connections, 1, "Re-attached via OBB flush face contact")
		assertEqual(#ConnectionService.AnalyzeBlueprintAssemblies(moveFront.Blueprint :: VehicleTypes.VehicleBlueprint).Groups, 1, "Reunited into 1 group")
		env.Teardown()
	end)

	-- 10
	runTest("ConnHotfix [10]: ReconcileBlueprintConnections repairs missing touching edges, prunes invalid/phantom edges, deduplicates, never bridges air gaps", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41010, Name = "Reconcile" }
		PlotService.Assign(p1)

		local synthBp: VehicleTypes.VehicleBlueprint = {
			SchemaVersion = 1,
			BlueprintId = "bp_recon",
			OwnerUserId = p1.UserId,
			Name = "Corrupto",
			Revision = 1,
			CreatedAt = 100,
			UpdatedAt = 100,
			VehicleOrigin = CFrame.identity,
			Presentation = { HeightOffset = 0, LateralOffset = 0 },
			Pieces = {
				{ InstanceId = "blk", ItemId = "RegularFuelTank", LocalCFrame = CFrame.new(0, 1.5, 0) },
				{ InstanceId = "seat", ItemId = "DriverSeat", LocalCFrame = CFrame.new(0, 3.0, 0) }, -- tocando +Y sin Conn_Top
				{ InstanceId = "airGap", ItemId = "WoodBlock", LocalCFrame = CFrame.new(2.45, 1.5, 0) }, -- 0.45 gap en X (tank 1.0, blk 1.0 -> 2.0 vs 2.45)
				{ InstanceId = "far", ItemId = "WoodBlock", LocalCFrame = CFrame.new(-10, 1.5, 0) },
			},
			Connections = {
				{ FromPieceId = "ghost_id", FromAttachment = "A", ToPieceId = "blk", ToAttachment = "B" }, -- huérfana
				{ FromPieceId = "blk", FromAttachment = "X", ToPieceId = "blk", ToAttachment = "Y" }, -- auto-lazo
				{ FromPieceId = "blk", FromAttachment = "A", ToPieceId = "far", ToAttachment = "B" }, -- arista fantasma separada físicamente
			},
		}

		local stats = ConnectionService.ReconcileBlueprintConnections(synthBp)
		assertEqual(stats.RemovedInvalidCount, 2, "Expected 2 invalid edges removed (orphan + self-loop)")
		assertEqual(stats.PrunedDetachedCount, 1, "Expected 1 geometrically detached phantom edge pruned")
		assertEqual(stats.AddedCount, 1, "Expected 1 genuine touching edge (tank <-> seat) rebuilt")
		assertEqual(#synthBp.Connections, 1, "Only the 1 real touching edge remains")
		assertTrue(
			(synthBp.Connections[1].FromPieceId == "blk" and synthBp.Connections[1].ToPieceId == "seat")
				or (synthBp.Connections[1].FromPieceId == "seat" and synthBp.Connections[1].ToPieceId == "blk"),
			"Reconciled edge connects blk <-> seat only"
		)

		-- Llamada idempotente segunda vez: no duplica
		local stats2 = ConnectionService.ReconcileBlueprintConnections(synthBp)
		assertEqual(stats2.AddedCount, 0, "Second reconcile adds 0 duplicates")
		assertEqual(#synthBp.Connections, 1, "Still exactly 1 edge")
		env.Teardown()
	end)

	-- 11
	runTest("ConnHotfix [11]: DeserializeBlueprint prunes dangling PieceIds/self-loops/duplicates and new PieceId allocation stays collision-free after Load", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41011, Name = "ValidPieceIds" }
		PlotService.Assign(p1)

		local rawCorrupt = {
			SchemaVersion = 1,
			BlueprintId = "bp_ser_clean",
			OwnerUserId = p1.UserId,
			Name = "DeserSanitize",
			Revision = 4,
			Pieces = {
				{ InstanceId = "p_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.5, 0) },
				{ InstanceId = "p_2", ItemId = "WoodBlock", LocalCFrame = CFrame.new(2, 1.5, 0) },
			},
			Connections = {
				{ FromPieceId = "p_1", FromAttachment = "Conn_Right", ToPieceId = "p_2", ToAttachment = "Conn_Left" },
				{ FromPieceId = "p_2", FromAttachment = "Conn_Left", ToPieceId = "p_1", ToAttachment = "Conn_Right" }, -- duplicado simétrico
				{ FromPieceId = "p_1", FromAttachment = "A", ToPieceId = "p_1", ToAttachment = "B" }, -- auto-lazo
				{ FromPieceId = "p_1", FromAttachment = "A", ToPieceId = "p_999_deleted", ToAttachment = "B" }, -- PieceId inexistente
			},
		}

		local okDeser, cleanBp, errDeser = BlueprintSerializer.DeserializeBlueprint(rawCorrupt, p1.UserId)
		assertTrue(okDeser and cleanBp ~= nil, `Deserialize should sanitize safely; got {tostring(errDeser)}`)
		local bp = cleanBp :: VehicleTypes.VehicleBlueprint
		assertEqual(#bp.Connections, 1, "Deduplicated + pruned to 1 valid edge")

		-- Importar en servicio, guardar, cargar y agregar pieza nueva asegurando que nuevo PieceId es único
		local plot = PlotService.GetPlotByPlayer(p1)
		local impOk = VehicleBlueprintService.ImportSerializedBlueprint(p1, plot, rawCorrupt)
		assertTrue(impOk, "Import failed")
		local extra = placePiece(p1, "p11_new", "DriverSeat", CFrame.new(0, 3.0, 0))
		assertTrue(extra.InstanceId ~= "p_1" and extra.InstanceId ~= "p_2", "Allocated PieceId must not collide with loaded PieceIds")
		local snap = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local idSet: { [string]: boolean } = {}
		for _, pc in ipairs(snap.Pieces) do
			assertTrue(not idSet[pc.InstanceId], `Duplicate PieceId {pc.InstanceId}`)
			idSet[pc.InstanceId] = true
		end
		for _, c in ipairs(snap.Connections) do
			assertTrue(idSet[c.FromPieceId] and idSet[c.ToPieceId], "Every connection references existing PieceIds")
		end
		env.Teardown()
	end)

	-- 12
	runTest("ConnHotfix [12]: LaunchPreparation detects full 15-piece PrimaryAssembly and warns cleanly when DriverSeat is isolated", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41012, Name = "PrimaryAndWarn" }
		PlotService.Assign(p1)

		-- Caso A: Chasis de 14 piezas conectado en Z=0 y DriverSeat realmente aislado con aire en Z=-12
		placePiece(p1, "p12_seat", "DriverSeat", CFrame.new(0, 1.5, -12))
		placePiece(p1, "p12_b1", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePiece(p1, "p12_eng", "SmallEngine", CFrame.new(0, 3.5, 0))
		placePiece(p1, "p12_w1", "SmallWheel", CFrame.new(-1.5, 1.5, 0))
		local repIso = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(repIso.PieceCount, 1, "Isolated seat forms 1-piece PrimaryAssembly")
		assertEqual(repIso.WorkshopPieceCount, 3, "Remaining 3 disconnected pieces excluded")
		assertTrue(repIso.PowertrainWarnings ~= nil and #repIso.PowertrainWarnings >= 2, "Must surface IncompletePrimaryAssembly & ExcludedDriveComponents warnings")
		local joinedWarn = table.concat(repIso.PowertrainWarnings :: { string }, "\n")
		assertTrue(string.find(joinedWarn, "IncompletePrimaryAssembly") ~= nil, "Missing IncompletePrimaryAssembly warning")
		assertTrue(string.find(joinedWarn, "ExcludedDriveComponents") ~= nil, "Missing ExcludedDriveComponents warning")
		-- SDD: no bloquear vehículos no motorizados válidos si están estructuralmente aptos
		assertEqual(repIso.Ready, true, "Non-blocking SDD Ready contract preserved")

		-- Caso B: Vehículo completo conectado de 15 piezas (en otro blueprint)
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.CreateBlueprint, ClientOpId = "p12_new", Name = "Car15" })
		buildRealistic15PieceCar(p1, "p12c")
		local repFull = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(repFull.PieceCount, 15, "Connected 15-piece car detected in full")
		assertEqual(repFull.EngineCount, 1, "Engine recognized")
		assertEqual(repFull.DrivenWheelCount, 4, "4 driven wheels recognized")
		assertEqual(repFull.PowertrainWarnings, nil, "Healthy complete car has zero powertrain warnings")
		env.Teardown()
	end)

	-- 13
	runTest("ConnHotfix [13]: Disconnected loose pieces stay excluded while full 15-piece car launches intact (Fase 2.4.2 parity)", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41013, Name = "LooseExcl" }
		PlotService.Assign(p1)
		buildRealistic15PieceCar(p1, "t13")

		-- Añadir 2 piezas realmente sueltas: una con aire libre en Z=-10 y otra con Y gap=0.45 encima de beamF(0, 1.5, -5) (top=2.0, bottom=2.45)
		local looseAir = placePiece(p1, "t13_l1", "WoodBlock", CFrame.new(0, 1.5, -10))
		local looseNear = placePiece(p1, "t13_l2", "WoodBlock", CFrame.new(0, 3.45, -5))

		local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(prep.TotalPieceCount, 17, "Total = 17")
		assertEqual(prep.PieceCount, 15, "PrimaryAssembly = 15 (only connected vehicle)")
		assertEqual(prep.WorkshopPieceCount, 2, "Exactly 2 loose pieces excluded")
		assertTrue(
			table.find(prep.WorkshopPieceIds :: { string }, looseAir.InstanceId) ~= nil
				and table.find(prep.WorkshopPieceIds :: { string }, looseNear.InstanceId) ~= nil,
			"Loose piece IDs accurately listed in WorkshopPieceIds"
		)

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch succeeded")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		assertEqual(countParts(rt), 15, "Runtime spawned ONLY the 15 connected parts, excluding the 2 loose parts")
		env.Teardown()
	end)

	-- 14
	runTest("ConnHotfix [14]: Engine, fuel tank and 4 driven wheels remain functional in Powertrain after Save + Load cycle", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41014, Name = "MotorWheelLoad" }
		PlotService.Assign(p1)
		buildRealistic15PieceCar(p1, "t14")

		local sv = BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.SaveBlueprint, ClientOpId = "t14_sv", Name = "DriveCar" })
		local bpId = (sv.Blueprint :: VehicleTypes.VehicleBlueprint).BlueprintId
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.CreateBlueprint, ClientOpId = "t14_tmp", Name = "Tmp" })
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.LoadBlueprint, ClientOpId = "t14_ld", BlueprintId = bpId })

		local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(prep.EngineCount, 1, "1 engine")
		assertEqual(prep.WheelCount, 4, "4 wheels")
		assertEqual(prep.DrivenWheelCount, 4, "4 driven wheels")

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success, "Launch succeeded")
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		for _ = 1, 10 do
			VehiclePowertrainService.StepAll(0.05)
			VehicleWheelControllerService.StepAll(0.05)
		end
		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(pt.EngineCount, 1, "Runtime powertrain has 1 engine")
		assertEqual(pt.DrivenWheelCount, 4, "Runtime powertrain drives 4 wheels")
		assertTrue(pt.TotalWheelDriveTorque > 0, "Positive drive torque generated after reload")
		assertTrue(pt.AvailableFuel < pt.TotalFuelCapacity, "Fuel consumed while throttling after reload")
		env.Teardown()
	end)

	-- 15
	runTest("ConnHotfix [15]: Full launch builds all 15 PieceModels with exact deduplicated joint count from Blueprint.Connections", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41015, Name = "FullLaunchJoints" }
		PlotService.Assign(p1)
		buildRealistic15PieceCar(p1, "t15")

		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local wheelIds: { [string]: boolean } = {}
		for _, pc in ipairs(bp.Pieces) do
			if pc.ItemId == "SmallWheel" then
				wheelIds[pc.InstanceId] = true
			end
		end
		local uniqueEdges: { [string]: boolean } = {}
		local expectedEdges = 0
		local expectedRigidEdges = 0
		for _, c in ipairs(bp.Connections) do
			local k = if c.FromPieceId < c.ToPieceId then `{c.FromPieceId}|{c.ToPieceId}` else `{c.ToPieceId}|{c.FromPieceId}`
			if not uniqueEdges[k] then
				uniqueEdges[k] = true
				expectedEdges += 1
				if not wheelIds[c.FromPieceId] and not wheelIds[c.ToPieceId] then
					expectedRigidEdges += 1
				end
			end
		end
		assertTrue(expectedEdges >= 14, `15-piece connected vehicle needs >= 14 unique edges, got {expectedEdges}`)

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Full launch succeeded")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		assertEqual(countParts(rt), 15, "All 15 pieces present in runtime")
		assertEqual(#(rt.Joints or {}), expectedRigidEdges, "Rigid WeldConstraint joints match non-wheel unique connection graph")
		assertEqual(#(rt.WheelPieceIds or {}), 4, "All 4 wheels articulated into WheelPieceIds")
		assertTrue(#(rt.WheelConstraints or {}) >= 4, "All 4 wheels generated WheelConstraints")
		assertTrue(rt.DriverSeatPart ~= nil and rt.DriverSeatPart.MaxSpeed == 0 and rt.DriverSeatPart.Torque == 0, "DriverSeat non-propulsive per SDD")
		env.Teardown()
	end)

	-- 16
	runTest("ConnHotfix [16]: Seat launches upright and forward-aligned to LaunchPoint on both Plot_01 and rotated Plot_07", function()
		local env = setupIsolatedWorld(8)
		local p1: PlotService.PlayerLike = { UserId = 41016, Name = "SeatOrientA" }
		local p7: PlotService.PlayerLike = { UserId = 41017, Name = "SeatOrientB" }
		local plot1 = PlotService.Assign(p1) :: PlotService.PlotRecord
		-- Asignar jugadores 2..6 para llegar al plot 7 rotado
		local fillers: { PlotService.PlayerLike } = {}
		for i = 2, 6 do
			local fp: PlotService.PlayerLike = { UserId = 41900 + i, Name = `Filler_{i}` }
			table.insert(fillers, fp)
			PlotService.Assign(fp)
		end
		local plot7 = PlotService.Assign(p7) :: PlotService.PlotRecord

		-- Caso A: asiento aislado sin rotar en Plot_01
		placePiece(p1, "o1_seat", "DriverSeat", CFrame.new(0, 1.5, 0))
		local lr1 = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr1.Success and lr1.Runtime ~= nil and lr1.Runtime.DriverSeatPart ~= nil, "Isolated seat launch on Plot_01 succeeded")
		local s1 = (lr1.Runtime :: VehicleTypes.VehicleRuntime).DriverSeatPart :: VehicleSeat
		assertTrue(s1.CFrame.UpVector:Dot(Vector3.yAxis) > 0.99, `Plot_01 isolated seat must be upright, Up={s1.CFrame.UpVector}`)
		assertTrue(
			s1.CFrame.LookVector:Dot(plot1.Zones.LaunchPoint.CFrame.LookVector) > 0.99,
			`Plot_01 seat must face LaunchPoint forward, Look={s1.CFrame.LookVector}`
		)

		-- Caso B: vehículo de 15 piezas en Plot_07 rotado
		buildRealistic15PieceCar(p7, "o7")
		local lr7 = VehicleLaunchService.LaunchVehicle(p7, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr7.Success and lr7.Runtime ~= nil and lr7.Runtime.DriverSeatPart ~= nil, "15-piece car launch on rotated Plot_07 succeeded")
		local s7 = (lr7.Runtime :: VehicleTypes.VehicleRuntime).DriverSeatPart :: VehicleSeat
		assertTrue(s7.CFrame.UpVector:Dot(Vector3.yAxis) > 0.99, `Plot_07 seat must be upright, Up={s7.CFrame.UpVector}`)
		assertTrue(
			s7.CFrame.LookVector:Dot(plot7.Zones.LaunchPoint.CFrame.LookVector) > 0.99,
			`Plot_07 seat must align to rotated LaunchPoint forward, Look={s7.CFrame.LookVector}`
		)
		env.Teardown()
	end)

	-- 17
	runTest("ConnHotfix [17]: Concurrent 4-plot building, save/load and launch keep graph caches and runtimes isolated", function()
		local env = setupIsolatedWorld(8)
		local players: { PlotService.PlayerLike } = {}
		local savedIds: { string } = {}
		for idx = 1, 4 do
			local plr: PlotService.PlayerLike = { UserId = 41100 + idx, Name = `MultiPlot_{idx}` }
			PlotService.Assign(plr)
			table.insert(players, plr)
			buildRealistic15PieceCar(plr, `mp{idx}`)
			local sv = BuildService.ProcessRequest(plr, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = `mp{idx}_sv`,
				Name = `Car_{idx}`,
			})
			assertTrue(sv.Success and sv.Blueprint ~= nil, `Save failed for plot {idx}`)
			savedIds[idx] = (sv.Blueprint :: VehicleTypes.VehicleBlueprint).BlueprintId
		end

		for idx, plr in ipairs(players) do
			BuildService.ProcessRequest(plr, { Action = BuildProtocol.Actions.CreateBlueprint, ClientOpId = `mp{idx}_new`, Name = "Reset" })
			BuildService.ProcessRequest(plr, { Action = BuildProtocol.Actions.LoadBlueprint, ClientOpId = `mp{idx}_ld`, BlueprintId = savedIds[idx] })
			local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(plr, { SkipWorldObstructionCheck = true })
			assertEqual(prep.PieceCount, 15, `Plot {idx} kept 15/15 PrimaryAssembly`)
			local lr = VehicleLaunchService.LaunchVehicle(plr, { MountDriver = false, SkipWorldObstructionCheck = true })
			assertTrue(lr.Success and lr.Runtime ~= nil, `Plot {idx} launched`)
			assertEqual(countParts(lr.Runtime :: VehicleTypes.VehicleRuntime), 15, `Plot {idx} runtime has 15 parts`)
		end
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 4, "4 simultaneous isolated runtimes active")
		env.Teardown()
	end)

	-- 18
	runTest("ConnHotfix [18]: ReturnToWorkshop preserves connections, allows new attached piece + save and full relaunch", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 41018, Name = "ReturnRelaunch" }
		PlotService.Assign(p1)
		buildRealistic15PieceCar(p1, "t18")

		local lr1 = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		assertTrue(lr1.Success, "Initial launch succeeded")
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		for _ = 1, 6 do
			VehiclePowertrainService.StepAll(0.05)
			VehicleWheelControllerService.StepAll(0.05)
		end

		local retRes = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(retRes.Success, "ReturnToWorkshop succeeded")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Runtime destroyed cleanly")

		-- Añadir 1 pieza conectada al tanque tras volver al taller, guardar, recargar y relanzar
		placePiece(p1, "t18_nitro", "SmallNitroTank", CFrame.new(2, 3.5, -0.5))
		local sv = BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.SaveBlueprint, ClientOpId = "t18_sv", Name = "Car16" })
		assertTrue(sv.Success and sv.Blueprint ~= nil, "Post-return save failed")
		local id16 = (sv.Blueprint :: VehicleTypes.VehicleBlueprint).BlueprintId
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.LoadBlueprint, ClientOpId = "t18_ld", BlueprintId = id16 })

		local prep2 = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertEqual(prep2.PieceCount, 16, "Relaunched car has 16/16 connected pieces")
		assertEqual(prep2.WorkshopPieceCount, 0, "Zero excluded pieces")

		env.AdvanceLifeClock(GameConfig.Runtime.LaunchCooldownSeconds + 0.1)
		local lr2 = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		assertTrue(lr2.Success and lr2.Runtime ~= nil, `Second launch failed: {tostring(lr2.ErrorCode)} - {tostring(lr2.ErrorMessage)}`)
		assertEqual(countParts(lr2.Runtime :: VehicleTypes.VehicleRuntime), 16, "Relaunched runtime has all 16 pieces")
		env.Teardown()
	end)
end

return ConnectionHotfixTests
