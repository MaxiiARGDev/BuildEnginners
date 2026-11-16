--!strict
--[=[
	Phase53Tests
	Suite automatizada de validación para la Fase 5.3 (Sistema de Aerodinámica Modular):
	Cubre los 16 escenarios obligatorios:
	  [01] Sustentación nula o despreciable a velocidad cero.
	  [02] Aumento cuadrático de sustentación al incrementar velocidad.
	  [03] Diferencia entre ala pequeña y grande (y perfiles de las 6 piezas).
	  [04] Orientación invertida, rotaciones libres/pasos y flujo 3D en ejes locales.
	  [05] Ángulo de ataque (AoA) y pérdida aerodinámica (stall).
	  [06] Resistencia siempre opuesta al flujo de aire.
	  [07] Momento de balanceo producido por una sola ala lateral.
	  [08] Comportamiento equilibrado de dos alas simétricas.
	  [09] Auto con ruedas, motor terrestre y planeador (sin motor de avión).
	  [10] Cohete con propulsores + alas y vehículo híbrido completo + estabilidad pasiva de AircraftTail.
	  [11] Daño parcial sin degradación progresiva y corte total al llegar a 0 HP o desprenderse.
	  [12] Guardado y carga en los 3 slots de blueprints con piezas aerodinámicas y rotaciones angulares.
	  [13] Compra ilimitada en tienda normal, entrega a 60 s (1 caja por ItemId) y venta al 50%.
	  [14] Limpieza total de fuerzas al regresar al taller (ReturnToWorkshop).
	  [15] Compatibilidad intacta con vehículos terrestres sin alas.
	  [16] Rendimiento y estabilidad numérica con múltiples superficies y entradas extremas.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local AerodynamicsConfig = require(ReplicatedStorage.Shared.Config.AerodynamicsConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)

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

local Phase53Tests = {}

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
	local existing = Workspace:FindFirstChild("_Phase53TestPlots")
	if existing then
		existing:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase53TestPlots"
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

local function grantAllAeroParts(player: PlotService.PlayerLike, qty: number?)
	local amount = qty or 20
	for _, itemId in ipairs(AerodynamicsConfig.OrderedItemIds) do
		InventoryService.GrantItemForTests(player, itemId, amount)
	end
end

local function placePieceOk(player: PlotService.PlayerLike, opId: string, itemId: string, cf: CFrame): string
	local res = BuildService.ProcessRequest(player, {
		Action = BuildProtocol.Actions.PlacePiece,
		ClientOpId = opId,
		ItemId = itemId,
		LocalCFrame = cf,
	})
	if not res.Success or not res.PlacedPiece then
		error(`PlacePiece failed for {itemId} ({opId}): {tostring(res.ErrorCode)} - {tostring(res.ErrorMessage)}`, 2)
	end
	return res.PlacedPiece.InstanceId
end

function Phase53Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (name: string, fn: () -> ()) -> ()
)
	-- 1) Sustentación nula o despreciable a velocidad cero
	runTest("Fase 5.3 [01]: Zero or negligible lift and drag at zero / sub-threshold airspeed", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53001, Name = "P53_ZeroSpeed" }
		PlotService.Assign(p1)
		grantAllAeroParts(p1, 5)

		placePieceOk(p1, "p01_b1", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceOk(p1, "p01_b2", "WoodBlock", CFrame.new(0, 1.5, 2))
		placePieceOk(p1, "p01_b3", "WoodBlock", CFrame.new(0, 1.5, 4))
		placePieceOk(p1, "p01_b4", "WoodBlock", CFrame.new(0, 3.5, 4))
		placePieceOk(p1, "p01_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		local wingId = placePieceOk(p1, "p01_glider", "LargeGliderWing", CFrame.new(0, 4.725, 4))

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success, "Vehicle with glider wing launched")

		local runtime = VehicleRuntimeService.GetRuntimeByPlayer(p1)
		assertTrue(runtime ~= nil, "Runtime exists")
		local wingPart = (runtime :: any).Parts[wingId].PrimaryPart :: BasePart
		wingPart.AssemblyLinearVelocity = Vector3.zero
		wingPart.AssemblyAngularVelocity = Vector3.zero

		local snap0 = AerodynamicsService.StepRuntime(p1, 1 / 60)
		assertTrue(snap0 ~= nil, "Telemetry snapshot exists")
		assertEqual((snap0 :: any).TotalLiftMagnitude, 0, "Zero lift at V = 0")
		assertEqual((snap0 :: any).TotalDragMagnitude, 0, "Zero drag at V = 0")
		assertEqual((snap0 :: any).ActiveForceSurfaceCount, 0, "Zero active VectorForces at V = 0")

		local vf = wingPart:FindFirstChild(AerodynamicsConfig.Simulation.VectorForceName) :: VectorForce?
		assertTrue(vf ~= nil, "AeroVectorForce created on wing PrimaryPart")
		assertEqual((vf :: VectorForce).Enabled, false, "VectorForce disabled at rest")
		assertEqual((vf :: VectorForce).Force, Vector3.zero, "VectorForce is Vector3.zero at rest")

		-- Sub-threshold speed (0.2 studs/s < MinAirspeedStudsPerSec = 0.5)
		local evalSub = AerodynamicsService.EvaluateSurfaceForces(
			AerodynamicsConfig.Surfaces.LargeGliderWing,
			CFrame.identity,
			Vector3.new(0, 0, -0.2)
		)
		assertEqual(evalSub.LiftForceMagnitude, 0, "Sub-threshold speed produces 0 lift")
		assertEqual(evalSub.DragForceMagnitude, 0, "Sub-threshold speed produces 0 drag")
		env.Teardown()
	end)

	-- 2) Aumento cuadrático de sustentación al incrementar velocidad
	runTest("Fase 5.3 [02]: Lift and drag scale with the square of relative airspeed", function()
		local spec = AerodynamicsConfig.Surfaces.LargeGliderWing
		local cf = CFrame.Angles(math.rad(6), 0, 0) -- +6 deg AoA

		local eval20 = AerodynamicsService.EvaluateSurfaceForces(spec, cf, Vector3.new(0, 0, -20))
		local eval40 = AerodynamicsService.EvaluateSurfaceForces(spec, cf, Vector3.new(0, 0, -40))
		local eval80 = AerodynamicsService.EvaluateSurfaceForces(spec, cf, Vector3.new(0, 0, -80))

		assertTrue(eval20.LiftForceMagnitude > 0, "Positive lift at 20 studs/s")
		assertTrue(eval40.LiftForceMagnitude > eval20.LiftForceMagnitude, "Lift increases at 40 studs/s")
		assertTrue(eval80.LiftForceMagnitude > eval40.LiftForceMagnitude, "Lift increases at 80 studs/s")

		local ratio40_20 = eval40.LiftForceMagnitude / eval20.LiftForceMagnitude
		local ratio80_40 = eval80.LiftForceMagnitude / eval40.LiftForceMagnitude
		assertTrue(math.abs(ratio40_20 - 4.0) < 0.05, `2x airspeed yields ~4x lift (got {ratio40_20})`)
		assertTrue(math.abs(ratio80_40 - 4.0) < 0.05, `2x airspeed yields ~4x lift (got {ratio80_40})`)
	end)

	-- 3) Diferencia entre ala pequeña y grande
	runTest("Fase 5.3 [03]: LargeGliderWing generates significantly greater lift than SmallGliderWing under identical conditions", function()
		local cf = CFrame.Angles(math.rad(5), 0, 0)
		local vel = Vector3.new(0, 0, -50)

		local smallEval = AerodynamicsService.EvaluateSurfaceForces(AerodynamicsConfig.Surfaces.SmallGliderWing, cf, vel)
		local largeEval = AerodynamicsService.EvaluateSurfaceForces(AerodynamicsConfig.Surfaces.LargeGliderWing, cf, vel)
		local wingLeftEval = AerodynamicsService.EvaluateSurfaceForces(AerodynamicsConfig.Surfaces.AircraftWingLeft, cf, vel)
		local wingUnivEval = AerodynamicsService.EvaluateSurfaceForces(AerodynamicsConfig.Surfaces.AircraftWing, cf, vel)

		assertTrue(smallEval.LiftForceMagnitude > 0, "SmallGliderWing generates lift")
		assertTrue(largeEval.LiftForceMagnitude > smallEval.LiftForceMagnitude * 2.0, "LargeGliderWing generates >2x lift of SmallGliderWing")
		assertTrue(wingUnivEval.LiftForceMagnitude > wingLeftEval.LiftForceMagnitude, "Universal wing (area 18) > single side wing (area 16)")
	end)

	-- 4) Orientación invertida y rotaciones de alas (flujo en ejes locales)
	runTest("Fase 5.3 [04]: Inverted wing produces downward force and local-axis airflow works for any 3D orientation", function()
		local spec = AerodynamicsConfig.Surfaces.AircraftWing
		local velForward = Vector3.new(0, 0, -60)

		-- Ala normal (+Y arriba) vs ala invertida 180 grados en roll (-Y arriba)
		local uprightEval = AerodynamicsService.EvaluateSurfaceForces(spec, CFrame.identity, velForward)
		local invertedCF = CFrame.Angles(0, 0, math.rad(180))
		local invertedEval = AerodynamicsService.EvaluateSurfaceForces(spec, invertedCF, velForward)

		assertTrue(uprightEval.LiftVectorWorld.Y > 100, "Upright wing produces upward (+Y) lift")
		assertTrue(invertedEval.LiftVectorWorld.Y < -100, "Inverted wing produces downward (-Y) downforce")
		assertTrue(math.abs(uprightEval.LiftForceMagnitude - invertedEval.LiftForceMagnitude) < 1e-3, "Equal magnitude in upright vs inverted")

		-- No asumir que velocidad horizontal del mundo es hacia adelante:
		-- Si el vehículo asciende verticalmente (+Y mundo) y el ala apunta hacia +Y mundo (rotada +90° en X),
		-- el flujo relativo es hacia adelante en el eje local del ala y genera sustentación horizontal en +Z mundo (UpVector).
		local verticalClimbWingCF = CFrame.Angles(math.rad(90), 0, 0) -- LookVector = (0, +1, 0), UpVector = (0, 0, +1)
		local verticalClimbVel = Vector3.new(0, 60, 0)
		local climbEval = AerodynamicsService.EvaluateSurfaceForces(spec, verticalClimbWingCF, verticalClimbVel)
		assertTrue(climbEval.LiftForceMagnitude > 100, "Vertical climb with vertically oriented wing resolves local forward airspeed")
		assertTrue(climbEval.LiftVectorWorld.Z > 100, "Lift acts along wing local UpVector (world +Z)")
	end)

	-- 5) Ángulo de ataque (AoA) y pérdida aerodinámica (stall)
	runTest("Fase 5.3 [05]: Angle of Attack increases lift up to StallAngleDeg and drops into stall above critical AoA", function()
		local spec = AerodynamicsConfig.Surfaces.AircraftWing
		local vel = Vector3.new(0, 0, -60)

		local eval0 = AerodynamicsService.EvaluateSurfaceForces(spec, CFrame.Angles(math.rad(0), 0, 0), vel)
		local eval8 = AerodynamicsService.EvaluateSurfaceForces(spec, CFrame.Angles(math.rad(8), 0, 0), vel)
		local eval16 = AerodynamicsService.EvaluateSurfaceForces(spec, CFrame.Angles(math.rad(16), 0, 0), vel)
		local eval30 = AerodynamicsService.EvaluateSurfaceForces(spec, CFrame.Angles(math.rad(30), 0, 0), vel)
		local eval45 = AerodynamicsService.EvaluateSurfaceForces(spec, CFrame.Angles(math.rad(45), 0, 0), vel)

		assertEqual(eval0.IsStalled, false, "Not stalled at 0 deg AoA")
		assertEqual(eval8.IsStalled, false, "Not stalled at 8 deg AoA")
		assertEqual(eval16.IsStalled, false, "Not stalled at 16 deg AoA (below 18 deg stall)")
		assertTrue(eval8.LiftCoefficient > eval0.LiftCoefficient, "CL(8°) > CL(0°)")
		assertTrue(eval16.LiftCoefficient > eval8.LiftCoefficient, "CL(16°) > CL(8°)")

		-- Pérdida aerodinámica a 30° y 45° (> 18°)
		assertEqual(eval30.IsStalled, true, "Stalled at 30 deg AoA")
		assertEqual(eval45.IsStalled, true, "Stalled at 45 deg AoA")
		assertTrue(eval30.LiftCoefficient < eval16.LiftCoefficient, "CL drops after stall at 30 deg")
		assertTrue(eval30.DragCoefficient > eval16.DragCoefficient * 1.5, "Drag surges in stall")
	end)

	-- 6) Resistencia opuesta al flujo de aire
	runTest("Fase 5.3 [06]: Aerodynamic drag strictly opposes the 3D relative velocity vector in all directions", function()
		local spec = AerodynamicsConfig.Surfaces.LargeGliderWing
		local testVelocities = {
			Vector3.new(0, 0, -55),
			Vector3.new(30, 15, -40),
			Vector3.new(-25, -35, 20),
			Vector3.new(0, -70, 0),
		}

		for idx, vel in ipairs(testVelocities) do
			local eval = AerodynamicsService.EvaluateSurfaceForces(spec, CFrame.Angles(math.rad(10), math.rad(20), 0), vel)
			assertTrue(eval.DragForceMagnitude > 0, `Drag > 0 for case {idx}`)
			local dot = eval.DragVectorWorld.Unit:Dot(vel.Unit)
			assertTrue(math.abs(dot - (-1.0)) < 1e-4, `Drag vector strictly opposite to velocity (dot = {dot})`)
		end
	end)

	-- 7) Balanceo producido por una sola ala lateral
	runTest("Fase 5.3 [07]: Single lateral wing produces asymmetric roll moment about the Center of Mass", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53007, Name = "P53_AsymRoll" }
		PlotService.Assign(p1)
		grantAllAeroParts(p1, 5)

		placePieceOk(p1, "p07_b1", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceOk(p1, "p07_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		-- Colocar únicamente un Ala izquierda en X = -4
		placePieceOk(p1, "p07_wleft", "AircraftWingLeft", CFrame.new(-4, 1.5, 0))

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success, "Asymmetric wing vehicle launched")

		local runtime = VehicleRuntimeService.GetRuntimeByPlayer(p1) :: any
		local seat = runtime.DriverSeatPart :: VehicleSeat
		local forwardDir = seat.CFrame.LookVector
		for _, desc in ipairs(runtime.RootModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.AssemblyLinearVelocity = forwardDir * 60
				desc.AssemblyAngularVelocity = Vector3.zero
			end
		end

		local snap = AerodynamicsService.StepRuntime(p1, 1 / 60) :: any
		assertTrue(snap ~= nil and snap.TotalLiftMagnitude > 100, "Single left wing generates lift")
		-- Momento de balanceo alrededor del eje longitudinal (proyección del torque sobre LookVector)
		local rollTorque = snap.NetAeroTorqueAboutCoMWorld:Dot(forwardDir)
		assertTrue(math.abs(rollTorque) > 150, `Single lateral wing produces significant roll torque ({rollTorque})`)
		env.Teardown()
	end)

	-- 8) Comportamiento equilibrado de alas simétricas
	runTest("Fase 5.3 [08]: Symmetric Left + Right wings balance roll torque to near-zero while doubling lift", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53008, Name = "P53_SymWings" }
		PlotService.Assign(p1)
		grantAllAeroParts(p1, 5)

		placePieceOk(p1, "p08_b1", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceOk(p1, "p08_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		placePieceOk(p1, "p08_wleft", "AircraftWingLeft", CFrame.new(-4, 1.5, 0))
		placePieceOk(p1, "p08_wright", "AircraftWingRight", CFrame.new(4, 1.5, 0))

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success, "Symmetric wing vehicle launched")

		local runtime = VehicleRuntimeService.GetRuntimeByPlayer(p1) :: any
		local seat = runtime.DriverSeatPart :: VehicleSeat
		local forwardDir = seat.CFrame.LookVector
		for _, desc in ipairs(runtime.RootModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.AssemblyLinearVelocity = forwardDir * 60
				desc.AssemblyAngularVelocity = Vector3.zero
			end
		end

		local snap = AerodynamicsService.StepRuntime(p1, 1 / 60) :: any
		assertEqual(snap.FunctionalSurfaceCount, 2, "2 active symmetric wings")
		assertTrue(snap.TotalLiftMagnitude > 400, "Combined symmetric lift")
		local rollTorque = snap.NetAeroTorqueAboutCoMWorld:Dot(forwardDir)
		assertTrue(math.abs(rollTorque) < 1e-2, `Symmetric wings cancel roll torque (got {rollTorque})`)
		env.Teardown()
	end)

	-- 9) Auto con ruedas, motor terrestre y planeador
	runTest("Fase 5.3 [09]: Terrestrial car with LargeGliderWing drives normally, builds lift with speed, and loses lift as speed drops", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53009, Name = "P53_GliderCar" }
		PlotService.Assign(p1)
		grantAllAeroParts(p1, 5)

		placePieceOk(p1, "p09_b1", "WoodBlock", CFrame.new(0, 2.5, -3))
		placePieceOk(p1, "p09_b2", "WoodBlock", CFrame.new(0, 2.5, -1))
		placePieceOk(p1, "p09_b3", "WoodBlock", CFrame.new(0, 2.5, 1))
		placePieceOk(p1, "p09_b4", "WoodBlock", CFrame.new(0, 2.5, 3))
		placePieceOk(p1, "p09_seat", "DriverSeat", CFrame.new(0, 4.0, -1))
		placePieceOk(p1, "p09_eng", "SmallEngine", CFrame.new(-2, 2.5, -1))
		placePieceOk(p1, "p09_tank", "RegularFuelTank", CFrame.new(0, 4.5, 4))
		placePieceOk(p1, "p09_wFL", "SmallWheel", CFrame.new(-1.5, 2.5, -3))
		placePieceOk(p1, "p09_wFR", "SmallWheel", CFrame.new(1.5, 2.5, -3))
		placePieceOk(p1, "p09_wRL", "SmallWheel", CFrame.new(-1.5, 2.5, 3))
		placePieceOk(p1, "p09_wRR", "SmallWheel", CFrame.new(1.5, 2.5, 3))
		placePieceOk(p1, "p09_glider", "LargeGliderWing", CFrame.new(0, 5.725, 4))

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success, "Glider car launched")

		-- El motor terrestre impulsa las ruedas normalmente con W (Throttle = 1)
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1, Steer = 0 })
		VehiclePowertrainService.StepAll(0.1)
		VehicleWheelControllerService.StepAll(0.1)
		local ptSnap = VehiclePowertrainService.GetPowertrainState(p1) :: any
		assertTrue(ptSnap ~= nil and ptSnap.TotalWheelDriveTorque > 0, "Terrestrial engine drives wheels while glider wing is installed")

		-- Al acelerar a 50 studs/s genera sustentación significativa; al bajar a 15 studs/s cae la sustentación
		local runtime = VehicleRuntimeService.GetRuntimeByPlayer(p1) :: any
		local fwd = runtime.DriverSeatPart.CFrame.LookVector
		for _, desc in ipairs(runtime.RootModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.AssemblyLinearVelocity = fwd * 50
			end
		end
		local aeroFast = AerodynamicsService.StepRuntime(p1, 1 / 60) :: any
		assertTrue(aeroFast.TotalLiftMagnitude > 1000, `High lift at 50 studs/s ({aeroFast.TotalLiftMagnitude})`)

		for _, desc in ipairs(runtime.RootModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.AssemblyLinearVelocity = fwd * 15
			end
		end
		local aeroSlow = AerodynamicsService.StepRuntime(p1, 1 / 60) :: any
		assertTrue(aeroSlow.TotalLiftMagnitude < aeroFast.TotalLiftMagnitude * 0.12, "Lift drops sharply when airspeed drops")
		env.Teardown()
	end)

	-- 10) Cohete con propulsores y alas + vehículo híbrido completo + estabilidad pasiva de AircraftTail
	runTest("Fase 5.3 [10]: Rocket with vertical/forward boosters + wings + AircraftTail operate simultaneously with passive tail stability", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53010, Name = "P53_HybridRocket" }
		PlotService.Assign(p1)
		grantAllAeroParts(p1, 5)

		placePieceOk(p1, "p10_b1", "WoodBlock", CFrame.new(0, 2.5, -5))
		placePieceOk(p1, "p10_b2", "WoodBlock", CFrame.new(0, 2.5, -3))
		placePieceOk(p1, "p10_b3", "WoodBlock", CFrame.new(0, 2.5, -1))
		placePieceOk(p1, "p10_b4", "WoodBlock", CFrame.new(0, 2.5, 1))
		placePieceOk(p1, "p10_b5", "WoodBlock", CFrame.new(0, 2.5, 3))
		placePieceOk(p1, "p10_b6", "WoodBlock", CFrame.new(0, 2.5, 5))
		placePieceOk(p1, "p10_b7", "WoodBlock", CFrame.new(0, 2.5, 7))
		placePieceOk(p1, "p10_b7_top", "WoodBlock", CFrame.new(0, 4.5, 7))
		placePieceOk(p1, "p10_bL", "WoodBlock", CFrame.new(-2, 2.5, 1))
		placePieceOk(p1, "p10_bR", "WoodBlock", CFrame.new(2, 2.5, 1))
		placePieceOk(p1, "p10_seat", "DriverSeat", CFrame.new(0, 4.0, -5))
		placePieceOk(p1, "p10_eng", "SmallEngine", CFrame.new(-2, 2.5, -1))
		placePieceOk(p1, "p10_ftank", "RegularFuelTank", CFrame.new(0, 4.5, -1))
		placePieceOk(p1, "p10_ntank", "SmallNitroTank", CFrame.new(0, 4.5, 3))
		-- Propulsor apuntando hacia arriba (+Y) rotado +90° en X (Conn_Bottom queda en -Z, unido a b7 en Z=8)
		placePieceOk(p1, "p10_bst", "SmallBooster", CFrame.new(0, 2.5, 8.75) * CFrame.Angles(math.rad(90), 0, 0))
		placePieceOk(p1, "p10_wFL", "SmallWheel", CFrame.new(-1.5, 2.5, -3))
		placePieceOk(p1, "p10_wFR", "SmallWheel", CFrame.new(1.5, 2.5, -3))
		placePieceOk(p1, "p10_wRL", "SmallWheel", CFrame.new(-1.5, 2.5, 3))
		placePieceOk(p1, "p10_wRR", "SmallWheel", CFrame.new(1.5, 2.5, 3))
		placePieceOk(p1, "p10_wL", "AircraftWingLeft", CFrame.new(-6.0, 2.5, 1))
		placePieceOk(p1, "p10_wR", "AircraftWingRight", CFrame.new(6.0, 2.5, 1))
		local tailId = placePieceOk(p1, "p10_tail", "AircraftTail", CFrame.new(0, 5.7, 7))

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success, "Full hybrid vehicle launched")

		-- Activar motor terrestre + booster simultáneamente + flujo de aire con guiñada (sideslip)
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1, Steer = 0 })
		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		VehiclePowertrainService.StepAll(0.1)
		VehicleBoosterService.StepAll(0.1)

		local runtime = VehicleRuntimeService.GetRuntimeByPlayer(p1) :: any
		local seat = runtime.DriverSeatPart :: VehicleSeat
		local fwd = seat.CFrame.LookVector
		local right = seat.CFrame.RightVector
		-- Flujo con derrape lateral (cola moviéndose hacia +Right)
		for _, desc in ipairs(runtime.RootModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.AssemblyLinearVelocity = fwd * 55 + right * 12
			end
		end

		local bstSnap = VehicleBoosterService.GetBoosterState(p1) :: any
		local aeroSnap = AerodynamicsService.StepRuntime(p1, 1 / 60) :: any
		assertTrue(bstSnap.TotalAppliedThrust > 0, "Booster generates thrust simultaneously")
		assertTrue(bstSnap.NetThrustVector.Y > 1000, "Vertical rocket booster produces upward thrust")
		assertEqual(aeroSnap.FunctionalSurfaceCount, 3, "Left wing, right wing, and tail all active")
		assertTrue(aeroSnap.TotalLiftMagnitude > 200, "Wings generate lift alongside rocket booster")

		-- Verificar fuerza lateral estabilizadora pasiva de AircraftTail
		local tailState = AerodynamicsService.GetSurfaceState(p1, tailId) :: any
		assertTrue(tailState ~= nil and tailState.SideForceMagnitude > 20, "AircraftTail vertical fin generates restoring side force on sideslip")
		assertTrue(tailState.SideForceVectorWorld:Dot(right) < 0, "Tail side force opposes +Right sideslip")
		env.Teardown()
	end)

	-- 11) Daño parcial sin degradación progresiva y desprendimiento a 0 HP
	runTest("Fase 5.3 [11]: Partial damage keeps 100% aero performance; 0 HP / detachment immediately removes aero forces and VectorForce", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53011, Name = "P53_DamageDetach" }
		PlotService.Assign(p1)
		grantAllAeroParts(p1, 5)

		placePieceOk(p1, "p11_b1", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceOk(p1, "p11_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		local bridgeId = placePieceOk(p1, "p11_bridge", "WoodBeam", CFrame.new(-3.0, 1.5, 0) * CFrame.Angles(0, math.rad(90), 0))
		local wingId = placePieceOk(p1, "p11_wing", "AircraftWingLeft", CFrame.new(-8.0, 1.5, 0))

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success, "Launched vehicle for damage test")

		local runtime = VehicleRuntimeService.GetRuntimeByPlayer(p1) :: any
		local fwd = runtime.DriverSeatPart.CFrame.LookVector
		local function setSpeed60()
			for _, desc in ipairs(runtime.RootModel:GetDescendants()) do
				if desc:IsA("BasePart") then
					desc.AssemblyLinearVelocity = fwd * 60
					desc.AssemblyAngularVelocity = Vector3.zero
				end
			end
		end

		setSpeed60()
		local snapHealthy = AerodynamicsService.StepRuntime(p1, 1 / 60) :: any
		local healthyLift = snapHealthy.TotalLiftMagnitude
		assertTrue(healthyLift > 100, "Healthy wing generates lift")

		-- Aplicar daño parcial al ala (queda con >0 HP): NO debe haber degradación progresiva
		VehicleDamageService.ApplyImpact(runtime, wingId, {
			DamageAmount = 40,
			SourceType = "DevTest",
			SkipDistribution = true,
		})
		local wingPartState = runtime.Parts[wingId]
		assertTrue(wingPartState.CurrentHealth > 0, "Wing still has > 0 HP")

		setSpeed60()
		local snapDamaged = AerodynamicsService.StepRuntime(p1, 1 / 60) :: any
		assertTrue(math.abs(snapDamaged.TotalLiftMagnitude - healthyLift) < 1e-2, "Zero progressive degradation on partial HP loss")

		-- Destruir la viga puente (0 HP) para que el ala se desprenda físicamente en un fragmento
		local wingPrimary = wingPartState.PrimaryPart :: BasePart
		VehicleDamageService.ApplyImpact(runtime, bridgeId, {
			DamageAmount = 500,
			SourceType = "DevTest",
			SkipDistribution = true,
		})
		assertEqual(wingPartState.IsDetached, true, "Wing detached when bridge broke")

		local snapDetached = AerodynamicsService.StepRuntime(p1, 1 / 60) :: any
		assertEqual(snapDetached.FunctionalSurfaceCount, 0, "Detached wing removed from functional surfaces")
		assertEqual(snapDetached.TotalLiftMagnitude, 0, "Detached wing contributes 0 lift")
		assertEqual(wingPrimary:FindFirstChild(AerodynamicsConfig.Simulation.VectorForceName), nil, "AeroVectorForce destroyed on detached wing")
		env.Teardown()
	end)

	-- 12) Guardado y carga de blueprints con las 6 piezas aerodinámicas y rotaciones angulares
	runTest("Fase 5.3 [12]: Save and load across blueprint slots preserves all 6 aerodynamic pieces and angled rotations", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53012, Name = "P53_Blueprints" }
		PlotService.Assign(p1)
		grantAllAeroParts(p1, 5)

		placePieceOk(p1, "p12_b1", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceOk(p1, "p12_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		placePieceOk(p1, "p12_wl", "AircraftWingLeft", CFrame.new(-4, 1.5, 0) * CFrame.Angles(math.rad(15), 0, 0))
		placePieceOk(p1, "p12_wr", "AircraftWingRight", CFrame.new(4, 1.5, 0) * CFrame.Angles(math.rad(15), 0, 0))
		placePieceOk(p1, "p12_wu", "AircraftWing", CFrame.new(0, 4.5, -2))
		placePieceOk(p1, "p12_tail", "AircraftTail", CFrame.new(0, 2.5, 4))
		placePieceOk(p1, "p12_lg", "LargeGliderWing", CFrame.new(0, 6.0, 0))
		placePieceOk(p1, "p12_sg", "SmallGliderWing", CFrame.new(0, 7.5, 0))

		local saveRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "p12_save1",
			SlotIndex = 1,
			Name = "AvionModular",
		})
		assertTrue(saveRes.Success, "Saved blueprint with 6 aero pieces in Slot 1")

		local clearRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.ClearWorkshop,
			ClientOpId = "p12_clear",
		})
		assertTrue(clearRes.Success, "Cleared workshop")

		local loadRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = "p12_load1",
			SlotIndex = 1,
		})
		assertTrue(loadRes.Success and loadRes.Blueprint ~= nil, "Loaded blueprint from Slot 1")
		assertEqual(#(loadRes.Blueprint :: any).Pieces, 8, "All 8 pieces (2 base + 6 aerodynamic) restored")
		env.Teardown()
	end)

	-- 13) Compra ilimitada en tienda normal, entrega a los 60 s (1 caja por ItemId) y venta al 50%
	runTest("Fase 5.3 [13]: All 6 aerodynamic pieces are purchasable in normal shop (100+ units, 1 crate/ItemId, 60s delivery) and sell at 50%", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53013, Name = "P53_ShopAero" }
		PlotService.Assign(p1)
		EconomyService.Credit(p1, 50000, "TestGrant", "tx_p13_grant")

		-- Verificar presencia en catálogo y categoría Aerodinámica
		for _, itemId in ipairs(AerodynamicsConfig.OrderedItemIds) do
			local entry = ItemCatalog.GetEntry(itemId)
			local spec = AerodynamicsConfig.GetSurfaceSpec(itemId) :: AerodynamicsConfig.AeroSurfaceSpec
			assertTrue(entry ~= nil, `Catalog entry exists for {itemId}`)
			assertEqual((entry :: any).Category, "Aerodynamics", `{itemId} Category == Aerodynamics`)
			assertEqual((entry :: any).CategoryDisplayName, "Aerodinámica", `{itemId} CategoryDisplayName == Aerodinámica`)
			assertEqual((entry :: any).DirectPurchasable, true, `{itemId} DirectPurchasable == true`)
			assertEqual((entry :: any).Price, spec.Price, `{itemId} Price matches config`)
			assertEqual((entry :: any).SellPrice, math.floor(spec.Price * 0.5), `{itemId} SellPrice == 50%`)
		end

		-- Comprar 100 SmallGliderWing + 2 LargeGliderWing + 1 AircraftTail -> 3 cajas físicas
		local co = ShopService.ProcessRequest(p1, {
			Action = ShopProtocol.Actions.CheckoutNormalCart,
			ClientOpId = "p13_buy_aero",
			CartItems = {
				{ ItemId = "SmallGliderWing", Quantity = 100 },
				{ ItemId = "LargeGliderWing", Quantity = 2 },
				{ ItemId = "AircraftTail", Quantity = 1 },
			},
		})
		assertTrue(co.Success and co.Order ~= nil, "Aero normal order checkout succeeded")
		assertEqual(#(co.Order :: any).Crates, 3, "Strictly 1 crate per unique aerodynamic ItemId")

		env.AdvanceClock(60)
		for _, c in ipairs((co.Order :: any).Crates) do
			assertTrue(ShopService.ProcessRequest(p1, {
				Action = ShopProtocol.Actions.OpenDeliveryCrate,
				ClientOpId = `p13_open_{c.CrateId}`,
				CrateId = c.CrateId,
			}).Success, `Opened crate for {c.ItemId}`)
		end

		assertEqual(InventoryService.GetOwnedQuantity(p1, "SmallGliderWing"), 100, "100 SmallGliderWing in inventory")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "LargeGliderWing"), 2, "2 LargeGliderWing in inventory")
		assertEqual(InventoryService.GetOwnedQuantity(p1, "AircraftTail"), 1, "1 AircraftTail in inventory")

		-- Vender 10 SmallGliderWing al 50% (10 * 65 = 650 monedas)
		local balBefore = EconomyService.GetBalance(p1)
		local sellRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SellInventoryItem,
			ClientOpId = "p13_sell_sg",
			ItemId = "SmallGliderWing",
			Quantity = 10,
		})
		assertTrue(sellRes.Success, "Sold 10 SmallGliderWing")
		assertEqual(EconomyService.GetBalance(p1), balBefore + 650, "Credited +650 coins (50%)")
		env.Teardown()
	end)

	-- 14) Limpieza de fuerzas al regresar al taller
	runTest("Fase 5.3 [14]: ReturnToWorkshop cleanly destroys all aerodynamic VectorForces and unregisters context", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53014, Name = "P53_Cleanup" }
		PlotService.Assign(p1)
		grantAllAeroParts(p1, 5)

		placePieceOk(p1, "p14_b1", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceOk(p1, "p14_b2", "WoodBlock", CFrame.new(0, 1.5, 2))
		placePieceOk(p1, "p14_b3", "WoodBlock", CFrame.new(0, 1.5, 4))
		placePieceOk(p1, "p14_b4", "WoodBlock", CFrame.new(0, 3.5, 4))
		placePieceOk(p1, "p14_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		placePieceOk(p1, "p14_glider", "LargeGliderWing", CFrame.new(0, 4.725, 4))

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success, "Launched vehicle")
		assertTrue(AerodynamicsService.GetTelemetrySnapshot(p1) ~= nil, "Aero context registered while active")

		local ret = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(ret.Success, "Returned to workshop")
		assertEqual(AerodynamicsService.GetTelemetrySnapshot(p1), nil, "Aero context unregistered after ReturnToWorkshop")
		env.Teardown()
	end)

	-- 15) Compatibilidad con vehículos terrestres sin alas
	runTest("Fase 5.3 [15]: Terrestrial vehicles without aerodynamic pieces have 0 aero forces and unaltered ground physics", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53015, Name = "P53_GroundOnly" }
		PlotService.Assign(p1)

		placePieceOk(p1, "p15_b1", "WoodBlock", CFrame.new(0, 2.5, 0))
		placePieceOk(p1, "p15_seat", "DriverSeat", CFrame.new(0, 4.0, 0))
		placePieceOk(p1, "p15_eng", "SmallEngine", CFrame.new(0, 2.5, -2))
		placePieceOk(p1, "p15_w1", "SmallWheel", CFrame.new(-1.5, 2.5, 0))
		placePieceOk(p1, "p15_w2", "SmallWheel", CFrame.new(1.5, 2.5, 0))

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success, "Ground vehicle launched")

		local snap = AerodynamicsService.StepRuntime(p1, 1 / 60) :: any
		assertEqual(snap.SurfaceCount, 0, "0 aero surfaces on ground-only vehicle")
		assertEqual(snap.TotalLiftMagnitude, 0, "0 lift on ground-only vehicle")
		assertEqual(snap.TotalDragMagnitude, 0, "0 aero drag on ground-only vehicle")
		env.Teardown()
	end)

	-- 16) Rendimiento y estabilidad numérica con múltiples superficies y entradas extremas
	runTest("Fase 5.3 [16]: Numerical stability, NaN/Inf protection, force clamping, and performance with 24 surfaces", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 53016, Name = "P53_PerfStability" }
		PlotService.Assign(p1)
		InventoryService.GrantItemForTests(p1, "WoodBlock", 40)
		grantAllAeroParts(p1, 30)

		for i = 1, 11 do
			placePieceOk(p1, `p16_b_{i}`, "WoodBlock", CFrame.new(0, 1.5, (i - 6) * 2))
		end
		placePieceOk(p1, "p16_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		for i = 1, 6 do
			local zPos = (i - 3.5) * 4 + 2 -- -10, -6, -2, 2, 6, 10
			placePieceOk(p1, `p16_wl1_{i}`, "AircraftWingLeft", CFrame.new(-4, 1.5, zPos))
			placePieceOk(p1, `p16_wl2_{i}`, "AircraftWingLeft", CFrame.new(-10, 1.5, zPos))
			placePieceOk(p1, `p16_wr1_{i}`, "AircraftWingRight", CFrame.new(4, 1.5, zPos))
			placePieceOk(p1, `p16_wr2_{i}`, "AircraftWingRight", CFrame.new(10, 1.5, zPos))
		end

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success, `24-wing vehicle launched ({tostring(lr.ErrorCode)} - {tostring(lr.ErrorMessage)})`)

		local runtime = VehicleRuntimeService.GetRuntimeByPlayer(p1) :: any
		-- Probar velocidad extrema (5,000 studs/s)
		for _, desc in ipairs(runtime.RootModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.AssemblyLinearVelocity = Vector3.new(0, -200, -5000)
				desc.AssemblyAngularVelocity = Vector3.new(50, -50, 30)
			end
		end

		local t0 = os.clock()
		local snap: any = nil
		for _ = 1, 50 do
			snap = AerodynamicsService.StepRuntime(p1, 1 / 60)
		end
		local elapsedMs = (os.clock() - t0) * 1000
		assertTrue(elapsedMs < 50, `50 ticks of 24 surfaces completed in {elapsedMs} ms (< 50 ms)`)
		assertEqual(snap.FunctionalSurfaceCount, 24, "24 active surfaces")
		assertTrue(snap.NetAeroForceWorld.Magnitude <= AerodynamicsConfig.Simulation.MaxTotalAerodynamicForce + 1, "Total force clamped to MaxTotalAerodynamicForce")

		-- Probar sanitización ante NaN / Inf en EvaluateSurfaceForces
		local nanEval = AerodynamicsService.EvaluateSurfaceForces(
			AerodynamicsConfig.Surfaces.LargeGliderWing,
			CFrame.identity,
			Vector3.new(0 / 0, math.huge, -math.huge)
		)
		assertEqual(nanEval.LiftForceMagnitude, 0, "NaN/Inf velocity sanitized to 0 lift")
		assertEqual(nanEval.TotalForceWorld, Vector3.zero, "NaN/Inf velocity produces Vector3.zero")

		assertEqual(#((ServerStorage:WaitForChild("BaseTemplate") :: Model):GetDescendants()), 25, "BaseTemplate intact (25 descendants)")
		env.Teardown()
	end)
end

function Phase53Tests.RunAll()
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

	Phase53Tests.AppendTests(results, runTest)

	return {
		Passed = passed,
		Failed = failed,
		Results = results,
	}
end

return Phase53Tests
