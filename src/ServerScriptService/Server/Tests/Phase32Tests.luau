--!strict
--[=[
	Phase32Tests
	Suite de 38 pruebas automatizadas de Fase 3.2 (Sistema híbrido de ruedas, suspensión
	Prismatic+Spring, dirección Servo, contrato de tren motriz Fase 3.3, análisis geométrico
	compartido, precedencia Auto/Manual, inspector contextual PC/Mobile, seguridad,
	serialización/compatibilidad y concurrencia de 10 jugadores).
	Se integra en Phase1Tests.RunAll().
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
local WheelAutoConfiguration = require(ReplicatedStorage.Shared.Building.WheelAutoConfiguration)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local PlotService = require(ServerScriptService.Server.Services.PlotService)
local SpawnService = require(ServerScriptService.Server.Services.SpawnService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
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

local ClientControllers = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState"))
local WheelConfigController = require(ClientControllers:WaitForChild("WheelConfigController"))
local WheelInspectorPanel = require(ClientControllers:WaitForChild("WheelInspectorPanel"))

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase32Tests = {}

local function setupIsolatedWorld(plotCount: number?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder

	local prevPlots = Workspace:FindFirstChild("_Phase32TestPlots")
	if prevPlots then
		prevPlots:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase32TestPlots"
	tempPlots.Parent = Workspace

	BuildService._ResetForTests()
	VehicleLaunchService._ResetForTests()
	VehicleLifecycleService._ResetForTests()
	VehicleRuntimeService._ResetForTests()
	VehicleWheelControllerService._ResetForTests()
	VehicleAssemblyService._ResetForTests()
	ItemRuntimeService._ResetForTests()
	VehicleLaunchPreparationService._ResetForTests()
	StandPreviewService._ResetForTests()
	VehicleBlueprintService._ResetForTests()
	InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
	ConnectionService._ResetForTests()
	WheelAutoConfigurationService._ResetForTests()
	SpawnService._ResetForTests()
	PlotService._ResetForTests()
	BuildState.Reset()
	WheelConfigController._ResetForTests()

	local assets = ServerStorage:WaitForChild("ItemAssets")
	PlotService.Init({
		BaseTemplate = baseTemplate,
		PlotSpawnsFolder = plotSpawns,
		PlotsParent = tempPlots,
		PlotCount = plotCount or 2,
	})
	SpawnService.Init()
	InventoryService.Init()
	WheelAutoConfigurationService.Init({ ItemAssetsRoot = assets })
	ConnectionService.Init({ ItemAssetsRoot = assets })
	VehicleAssemblyService.Init({ ItemAssetsRoot = assets })
	VehicleBlueprintService.Init({ ItemAssetsRoot = assets })
	StandPreviewService.Init({ ItemAssetsRoot = assets })
	VehicleLaunchPreparationService.Init({ ItemAssetsRoot = assets })
	ItemRuntimeService.Init({ ItemAssetsRoot = assets })
	VehicleWheelControllerService.Init()
	VehicleRuntimeService.Init()
	VehicleLifecycleService.Init()
	VehicleLaunchService.Init()
	BuildService.Init()

	local fakeClock = 500
	local rateLimitClock = 500
	BuildService._SetRateLimitClockForTests(function()
		rateLimitClock += 1.0
		return rateLimitClock
	end)
	VehicleLaunchService._SetClockForTests(function()
		return fakeClock
	end)
	VehicleLifecycleService._SetClockForTests(function()
		return fakeClock
	end)

	return {
		TempPlots = tempPlots,
		AdvanceClock = function(dt: number)
			fakeClock += dt
			return fakeClock
		end,
		Teardown = function()
			BuildService._ResetForTests()
			VehicleLaunchService._ResetForTests()
			VehicleLifecycleService._ResetForTests()
			VehicleRuntimeService._ResetForTests()
			VehicleWheelControllerService._ResetForTests()
			VehicleAssemblyService._ResetForTests()
			ItemRuntimeService._ResetForTests()
			VehicleLaunchPreparationService._ResetForTests()
			StandPreviewService._ResetForTests()
			VehicleBlueprintService._ResetForTests()
			InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = false })
			ConnectionService._ResetForTests()
			WheelAutoConfigurationService._ResetForTests()
			SpawnService._ResetForTests()
			PlotService._ResetForTests()
			BuildState.Reset()
			WheelConfigController._ResetForTests()
			tempPlots:Destroy()
		end,
	}
end

local function placePieceReq(
	player: PlotService.PlayerLike,
	opId: string,
	itemId: string,
	localCF: CFrame,
	config: { [string]: any }?
): string
	local res = BuildService.ProcessRequest(player, {
		Action = "PlacePiece",
		ClientOpId = opId,
		ItemId = itemId,
		LocalCFrame = localCF,
		Config = config,
	})
	if not res.Success or not res.PlacedPiece then
		error(`Failed PlacePiece {opId} ({itemId}): {tostring(res.ErrorCode)} - {tostring(res.ErrorMessage)}`)
	end
	return res.PlacedPiece.InstanceId
end

local function buildFourWheelKart(
	player: PlotService.PlayerLike,
	prefix: string,
	options: {
		Heavy: boolean?,
		WheelConfigs: { FL: { [string]: any }?, FR: { [string]: any }?, RL: { [string]: any }?, RR: { [string]: any }? }?,
		SeatYawSteps: number?,
	}?
): { FL: string, FR: string, RL: string, RR: string, SeatId: string, MountFrontId: string }
	local seatYaw = if options and options.SeatYawSteps then options.SeatYawSteps else 0
	local kartRot = BuildRotation.RotateY(BuildRotation.Identity(), seatYaw)
	local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)

	placePieceReq(player, `{prefix}_b0`, "WoodBlock", kartRot * CFrame.new(0, 1.5, 0), nil)
	local frontBlockId = placePieceReq(player, `{prefix}_bf`, "WoodBlock", kartRot * CFrame.new(0, 1.5, -2), nil)
	placePieceReq(player, `{prefix}_br`, "WoodBlock", kartRot * CFrame.new(0, 1.5, 2), nil)
	local seatId = placePieceReq(player, `{prefix}_seat`, "DriverSeat", kartRot * CFrame.new(0, 3.0, 0), nil)

	if options and options.Heavy then
		placePieceReq(player, `{prefix}_br2`, "WoodBlock", kartRot * CFrame.new(0, 1.5, 4), nil)
		placePieceReq(player, `{prefix}_br3`, "WoodBlock", kartRot * CFrame.new(0, 1.5, 6), nil)
		placePieceReq(player, `{prefix}_eng`, "SmallEngine", kartRot * CFrame.new(0, 3.5, 2), nil)
		placePieceReq(player, `{prefix}_tank`, "RegularFuelTank", kartRot * CFrame.new(0, 3.5, 5), nil)
	end

	local wcfgs = if options then options.WheelConfigs else nil
	local fl = placePieceReq(
		player,
		`{prefix}_fl`,
		"SmallWheel",
		kartRot * CFrame.new(-1.5, 1.5, -2),
		if wcfgs then wcfgs.FL else nil
	)
	local fr = placePieceReq(
		player,
		`{prefix}_fr`,
		"SmallWheel",
		kartRot * CFrame.new(1.5, 1.5, -2) * wheelFlip,
		if wcfgs then wcfgs.FR else nil
	)
	local rl = placePieceReq(
		player,
		`{prefix}_rl`,
		"SmallWheel",
		kartRot * CFrame.new(-1.5, 1.5, 2),
		if wcfgs then wcfgs.RL else nil
	)
	local rr = placePieceReq(
		player,
		`{prefix}_rr`,
		"SmallWheel",
		kartRot * CFrame.new(1.5, 1.5, 2) * wheelFlip,
		if wcfgs then wcfgs.RR else nil
	)

	return {
		FL = fl,
		FR = fr,
		RL = rl,
		RR = rr,
		SeatId = seatId,
		MountFrontId = frontBlockId,
	}
end

function Phase32Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (name: string, fn: () -> ()) -> ()
)
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

	local function assertNear(actual: number, expected: number, tol: number, msg: string)
		if math.abs(actual - expected) > tol then
			error(`{msg} (expected={string.format("%.4f", expected)}±{tol}, actual={string.format("%.4f", actual)})`, 2)
		end
	end

	-- 1
	runTest("Fase 3.2 [01]: SmallWheel asset attributes, WheelHub attachment and measured cylinder spec", function()
		local env = setupIsolatedWorld(1)
		local wheelTemplate = ServerStorage:WaitForChild("ItemAssets"):WaitForChild("Ruedas"):WaitForChild("SmallWheel") :: Model
		local prim = (wheelTemplate.PrimaryPart or wheelTemplate:FindFirstChild("Primary")) :: Part
		assertTrue(prim ~= nil and prim:IsA("Part"), "SmallWheel Primary is a Part")
		assertEqual(prim.Shape, Enum.PartType.Cylinder, "SmallWheel is cylindrical")
		assertTrue(prim:FindFirstChild("WheelHub") ~= nil, "SmallWheel has WheelHub attachment")
		assertTrue(prim:FindFirstChild("Conn_Axle") ~= nil and prim:FindFirstChild("Conn_AxleRight") ~= nil, "SmallWheel keeps Conn_Axle & Conn_AxleRight")

		local spec = WheelAutoConfigurationService.GetWheelItemSpec("SmallWheel")
		assertNear(spec.WheelRadius, 1.0, 0.01, "True cylinder radius is 1.0 stud")
		assertNear(spec.WheelWidth, 1.0, 0.01, "True cylinder width is 1.0 stud")
		assertTrue(math.abs(spec.LocalSpinAxis.X) > 0.99, "Spin axis is local X")
		env.Teardown()
	end)

	-- 2
	runTest("Fase 3.2 [02]: Hybrid precedence strict (Defaults < Auto < Manual) with per-field Auto reversion", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32002, Name = "Precedence" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t02")

		local analysisAuto = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		local autoFL = analysisAuto.ByPieceId[w.FL]
		assertEqual(autoFL.Sources.SteeringMode, "Auto", "Front steering initially Auto")
		assertEqual(autoFL.EffectiveSteeringEnabled, true, "Front wheel auto-steers")
		assertEqual(autoFL.Sources.MaxSteeringAngle, "Auto", "Angle initially Auto")

		local r1 = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "t02_upd1",
			PieceInstanceId = w.RL,
			Config = { Wheel = { SteeringMode = "Enabled", MaxSteeringAngle = 14, SteeringDirectionMultiplier = -1 } },
		})
		assertTrue(r1.Success, "UpdatePieceConfig succeeds on rear wheel")

		local analysisMix = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		local mixRL = analysisMix.ByPieceId[w.RL]
		assertEqual(mixRL.Sources.SteeringMode, "Manual", "Rear steering now Manual")
		assertEqual(mixRL.EffectiveSteeringEnabled, true, "Manual steering enabled rear wheel")
		assertEqual(mixRL.MaxSteeringAngle, 14, "Manual angle preserved")
		assertEqual(mixRL.SteeringDirectionMultiplier, -1, "Manual counter-steer preserved")
		assertEqual(mixRL.Sources.SuspensionEnabled, "Auto", "Suspension stayed Auto when only steering changed")

		-- Limpiar un campo individual enviando tabla parcial sin MaxSteeringAngle -> vuelve a Auto pero conserva SteeringMode
		local r2 = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "t02_upd2",
			PieceInstanceId = w.RL,
			Config = { Wheel = { SteeringMode = "Enabled" } },
		})
		assertTrue(r2.Success, "Partial override update succeeds")
		local analysisMix2 = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		local mixRL2 = analysisMix2.ByPieceId[w.RL]
		assertEqual(mixRL2.Sources.SteeringMode, "Manual", "SteeringMode stays Manual")
		assertEqual(mixRL2.Sources.MaxSteeringAngle, "Auto", "MaxSteeringAngle reverted to Auto")
		assertEqual(mixRL2.MaxSteeringAngle, GameConfig.Wheels.DefaultMaxSteeringAngleDeg, "Reverted to Auto angle")
		env.Teardown()
	end)

	-- 3
	runTest("Fase 3.2 [03]: Zero TemporaryWheelWeld and complete Carrier/Pivot/Constraint structural hierarchy", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32003, Name = "Hierarchy" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t03")
		local lRes = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lRes.Success and lRes.Runtime ~= nil, "Launched")
		local rt = lRes.Runtime :: VehicleTypes.VehicleRuntime

		for _, j in ipairs(rt.Joints or {}) do
			assertTrue(j:GetAttribute("JointRole") ~= "TemporaryWheelWeld", "No TemporaryWheelWeld allowed in Fase 3.2")
		end

		local mechs = rt.WheelMechanisms :: { [string]: any }
		assertTrue(mechs ~= nil, "WheelMechanisms table attached to runtime")

		local mFL = mechs[w.FL]
		assertTrue(mFL.CarrierPart ~= nil and mFL.PivotPart ~= nil, "Front wheel creates CarrierPart and SteeringPivot")
		assertEqual(mFL.CarrierPart.CanCollide, false, "Carrier non-collidable")
		assertEqual(mFL.CarrierPart.Massless, false, "Carrier has finite mass for spring stability")
		assertEqual(mFL.PivotPart.CanCollide, false, "Pivot non-collidable")
		assertTrue(mFL.Prismatic ~= nil and mFL.Spring ~= nil and mFL.SteeringHinge ~= nil and mFL.AxleHinge ~= nil, "Front wheel has all 4 mechanical constraints")

		local mRL = mechs[w.RL]
		assertTrue(mRL.CarrierPart ~= nil and mRL.PivotPart == nil, "Rear fixed wheel omits unnecessary SteeringPivot")
		assertTrue(mRL.SteeringHinge == nil and mRL.AxleHinge ~= nil, "Rear fixed wheel has no SteeringHinge")
		env.Teardown()
	end)

	-- 4
	runTest("Fase 3.2 [04]: Mass-aware SpringStiffness, bounded SpringDamping and static-load FreeLength calibration", function()
		local env = setupIsolatedWorld(2)
		local pLight: PlotService.PlayerLike = { UserId = 320041, Name = "LightSpring" }
		local pHeavy: PlotService.PlayerLike = { UserId = 320042, Name = "HeavySpring" }
		PlotService.Assign(pLight)
		PlotService.Assign(pHeavy)

		local wl = buildFourWheelKart(pLight, "l4", { Heavy = false })
		local wh = buildFourWheelKart(pHeavy, "h4", { Heavy = true })

		local lr = VehicleLaunchService.LaunchVehicle(pLight, { MountDriver = false, SkipWorldObstructionCheck = true })
		local hr = VehicleLaunchService.LaunchVehicle(pHeavy, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success and hr.Success, "Both launched")

		local mLight = (lr.Runtime :: any).WheelMechanisms[wl.FL]
		local mHeavy = (hr.Runtime :: any).WheelMechanisms[wh.FL]

		assertTrue(mHeavy.Spring.Stiffness > mLight.Spring.Stiffness * 4, "Heavy vehicle auto-calibrates substantially higher stiffness")
		assertTrue(mHeavy.Spring.Damping <= GameConfig.Wheels.AutoSpringMaxDamping, "Damping respects PGS reduced-mass stability cap")
		assertTrue(mLight.Spring.FreeLength > GameConfig.Wheels.SpringMountHeightOffsetStuds, "Light spring applies static preload")
		assertTrue(mHeavy.Spring.FreeLength >= mLight.Spring.FreeLength, "Heavy spring applies preload proportional to gravity load")
		env.Teardown()
	end)

	-- 5
	runTest("Fase 3.2 [05]: Custom RideHeight and SuspensionTravel apply cleanly to Prismatic & Spring limits", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32005, Name = "RideHeight" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t05", {
			WheelConfigs = {
				FL = { Wheel = { RideHeight = 0.4, SuspensionTravel = 1.2 } },
				RL = { Wheel = { RideHeight = -0.3, SuspensionTravel = 0.4 } },
			},
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local mFL = (lr.Runtime :: any).WheelMechanisms[w.FL]
		local mRL = (lr.Runtime :: any).WheelMechanisms[w.RL]

		assertNear(mFL.Prismatic.UpperLimit - mFL.Prismatic.LowerLimit, 1.2, 0.01, "FL Prismatic span equals 1.2")
		assertNear(mRL.Prismatic.UpperLimit - mRL.Prismatic.LowerLimit, 0.4, 0.01, "RL Prismatic span equals 0.4")
		assertTrue(mFL.Spring.FreeLength > mRL.Spring.FreeLength, "Positive RideHeight increases target rest length")
		env.Teardown()
	end)

	-- 6
	runTest("Fase 3.2 [06]: SuspensionEnabled = false omits Carrier, Prismatic and Spring while preserving Steering", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32006, Name = "NoSusp" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t06", {
			WheelConfigs = {
				FL = { Wheel = { SuspensionEnabled = false, SteeringMode = "Enabled" } },
			},
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local mFL = (lr.Runtime :: any).WheelMechanisms[w.FL]
		assertTrue(mFL.CarrierPart == nil and mFL.Prismatic == nil and mFL.Spring == nil, "No carrier/prismatic/spring when suspension disabled")
		assertTrue(mFL.PivotPart ~= nil and mFL.SteeringHinge ~= nil, "Steering still active without suspension")
		assertEqual(mFL.SteeringHinge.Attachment0.Parent, mFL.MountPart, "SteeringHinge connects MountPart -> PivotPart directly")
		env.Teardown()
	end)

	-- 7
	runTest("Fase 3.2 [07]: SteeringMode = Disabled removes SteeringPivot & SteeringHinge on front wheel", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32007, Name = "NoSteer" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t07", {
			WheelConfigs = {
				FL = { Wheel = { SteeringMode = "Disabled" } },
			},
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local mFL = (lr.Runtime :: any).WheelMechanisms[w.FL]
		assertTrue(mFL.CarrierPart ~= nil and mFL.Prismatic ~= nil, "Suspension preserved")
		assertTrue(mFL.PivotPart == nil and mFL.SteeringHinge == nil, "SteeringPivot omitted cleanly")
		assertEqual(mFL.AxleHinge.Attachment0.Parent, mFL.CarrierPart, "AxleHinge attaches CarrierPart -> Wheel directly")
		env.Teardown()
	end)

	-- 8
	runTest("Fase 3.2 [08]: Suspension=false + Steering=Disabled produces direct zero-hub rolling AxleHinge", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32008, Name = "RigidAxle" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t08", {
			WheelConfigs = {
				RL = { Wheel = { SuspensionEnabled = false, SteeringMode = "Disabled" } },
			},
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local mRL = (lr.Runtime :: any).WheelMechanisms[w.RL]
		assertTrue(mRL.CarrierPart == nil and mRL.PivotPart == nil, "Zero intermediate hubs")
		assertEqual(mRL.AxleHinge.Attachment0.Parent, mRL.MountPart, "AxleHinge attaches MountPart -> WheelPart")
		env.Teardown()
	end)

	-- 9
	runTest("Fase 3.2 [09]: 4-wheel standard car auto-classification (Front steers Left/Right, Rear fixed)", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32009, Name = "Standard4W" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t09")
		local wa = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))

		assertEqual(wa.WheelCount, 4, "4 wheels detected")
		assertEqual(wa.AxleCount, 2, "2 axles detected")
		assertEqual(wa.IsAmbiguous, false, "Standard symmetric 4-wheel not ambiguous")
		assertEqual(wa.ByPieceId[w.FL].Analysis.AxleRole, "Front", "FL is Front")
		assertEqual(wa.ByPieceId[w.FL].Analysis.SideRole, "Left", "FL is Left")
		assertEqual(wa.ByPieceId[w.FR].Analysis.SideRole, "Right", "FR is Right")
		assertEqual(wa.ByPieceId[w.FR].EffectiveSteeringEnabled, true, "FR auto-steers")
		assertEqual(wa.ByPieceId[w.RL].Analysis.AxleRole, "Rear", "RL is Rear")
		assertEqual(wa.ByPieceId[w.RL].EffectiveSteeringEnabled, false, "RL fixed")
		assertEqual(wa.ByPieceId[w.RR].EffectiveSteeringEnabled, false, "RR fixed")
		env.Teardown()
	end)

	-- 10
	runTest("Fase 3.2 [10]: 2-wheel inline motorcycle layout steers front, keeps rear fixed, emits balance advisory", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32010, Name = "Moto2W" }
		PlotService.Assign(p1)
		local beamCross = BuildRotation.RotateY(BuildRotation.Identity(), 1)
		placePieceReq(p1, "m_b0", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceReq(p1, "m_cf", "WoodBeam", CFrame.new(0, 1.5, -1.5) * beamCross)
		placePieceReq(p1, "m_ff", "WoodBeam", CFrame.new(-1.0, 1.5, -4.0))
		placePieceReq(p1, "m_cr", "WoodBeam", CFrame.new(0, 1.5, 1.5) * beamCross)
		placePieceReq(p1, "m_fr", "WoodBeam", CFrame.new(-1.0, 1.5, 4.0))
		placePieceReq(p1, "m_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		local wF = placePieceReq(p1, "m_wf", "SmallWheel", CFrame.new(0, 1.5, -4))
		local wR = placePieceReq(p1, "m_wr", "SmallWheel", CFrame.new(0, 1.5, 4))

		local wa = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		assertEqual(wa.WheelCount, 2, "2 inline wheels")
		assertEqual(wa.AxleCount, 2, "2 longitudinal axles")
		assertEqual(wa.ByPieceId[wF].EffectiveSteeringEnabled, true, "Front bike wheel auto-steers")
		assertEqual(wa.ByPieceId[wR].EffectiveSteeringEnabled, false, "Rear bike wheel fixed")
		assertTrue(#wa.ByPieceId[wF].Warnings > 0, "Emits inline lateral balance advisory")
		env.Teardown()
	end)

	-- 11
	runTest("Fase 3.2 [11]: 2-wheel parallel single-axle marks ambiguous & allows Manual override recovery", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32011, Name = "SingleAxle" }
		PlotService.Assign(p1)
		placePieceReq(p1, "s_b0", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceReq(p1, "s_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		local wL = placePieceReq(p1, "s_wl", "SmallWheel", CFrame.new(-1.5, 1.5, 0))
		local wR = placePieceReq(p1, "s_wr", "SmallWheel", CFrame.new(1.5, 1.5, 0) * BuildRotation.RotateY(BuildRotation.Identity(), 2))

		local wa = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		assertEqual(wa.AxleCount, 1, "Single axle")
		assertTrue(wa.IsAmbiguous, "Single axle flagged ambiguous")
		assertEqual(wa.ByPieceId[wL].EffectiveSteeringEnabled, false, "Single axle auto-steering safely disabled")

		BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "s_man",
			PieceInstanceId = wL,
			Config = { Wheel = { SteeringMode = "Enabled" } },
		})
		local waAfter = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		assertEqual(waAfter.ByPieceId[wL].EffectiveSteeringEnabled, true, "Manual override enables steering despite ambiguity")
		assertEqual(waAfter.ByPieceId[wR].EffectiveSteeringEnabled, false, "Other wheel remains Auto disabled")
		env.Teardown()
	end)

	-- 12
	runTest("Fase 3.2 [12]: 3-wheel trike (1 front center + 2 rear) auto-steers front center only", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32012, Name = "Trike3W" }
		PlotService.Assign(p1)
		local beamCross = BuildRotation.RotateY(BuildRotation.Identity(), 1)
		placePieceReq(p1, "tr_b0", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceReq(p1, "tr_cf", "WoodBeam", CFrame.new(0, 1.5, -1.5) * beamCross)
		placePieceReq(p1, "tr_ff", "WoodBeam", CFrame.new(-1.0, 1.5, -4.0))
		placePieceReq(p1, "tr_br", "WoodBlock", CFrame.new(0, 1.5, 2))
		placePieceReq(p1, "tr_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		local wf = placePieceReq(p1, "tr_wf", "SmallWheel", CFrame.new(0, 1.5, -4))
		local wrl = placePieceReq(p1, "tr_wrl", "SmallWheel", CFrame.new(-1.5, 1.5, 2))
		local wrr = placePieceReq(p1, "tr_wrr", "SmallWheel", CFrame.new(1.5, 1.5, 2) * BuildRotation.RotateY(BuildRotation.Identity(), 2))

		local wa = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		assertEqual(wa.WheelCount, 3, "3 wheels")
		assertEqual(wa.ByPieceId[wf].Analysis.SideRole, "Center", "Front wheel centered")
		assertEqual(wa.ByPieceId[wf].EffectiveSteeringEnabled, true, "Front wheel steers")
		assertEqual(wa.ByPieceId[wrl].EffectiveSteeringEnabled, false, "Rear left fixed")
		assertEqual(wa.ByPieceId[wrr].EffectiveSteeringEnabled, false, "Rear right fixed")
		env.Teardown()
	end)

	-- 13
	runTest("Fase 3.2 [13]: 6-wheel & 8-wheel heavy multi-axle clustering + manual rear counter-steer", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32013, Name = "Truck8W" }
		PlotService.Assign(p1)
		placePieceReq(p1, "t_b0", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceReq(p1, "t_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		local zCoords = { -4, -2, 2, 4 }
		local idsByAxle: { { L: string, R: string } } = {}
		local flip = BuildRotation.RotateY(BuildRotation.Identity(), 2)
		for idx, z in ipairs(zCoords) do
			if z ~= 0 then
				placePieceReq(p1, `t_ch_{idx}`, "WoodBlock", CFrame.new(0, 1.5, z))
			end
			local wl = placePieceReq(p1, `t_wl_{idx}`, "SmallWheel", CFrame.new(-1.5, 1.5, z))
			local wr = placePieceReq(p1, `t_wr_{idx}`, "SmallWheel", CFrame.new(1.5, 1.5, z) * flip)
			table.insert(idsByAxle, { L = wl, R = wr })
		end

		local wa = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		assertEqual(wa.WheelCount, 8, "8 wheels detected")
		assertEqual(wa.AxleCount, 4, "4 axles clustered")
		assertEqual(wa.ByPieceId[idsByAxle[1].L].Analysis.AxleRole, "Front", "Axle 1 Front")
		assertEqual(wa.ByPieceId[idsByAxle[2].L].Analysis.AxleRole, "Middle", "Axle 2 Middle")
		assertEqual(wa.ByPieceId[idsByAxle[4].L].Analysis.AxleRole, "Rear", "Axle 4 Rear")
		assertEqual(wa.ByPieceId[idsByAxle[1].L].EffectiveSteeringEnabled, true, "Front axle auto-steers")
		assertEqual(wa.ByPieceId[idsByAxle[2].L].EffectiveSteeringEnabled, false, "Middle axle fixed")
		assertEqual(wa.ByPieceId[idsByAxle[4].L].EffectiveSteeringEnabled, false, "Rear axle fixed")

		BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "t8_rear_cs",
			PieceInstanceId = idsByAxle[4].L,
			Config = { Wheel = { SteeringMode = "Enabled", SteeringDirectionMultiplier = -1, MaxSteeringAngle = 16 } },
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		VehicleWheelControllerService.SetSteerOverrideForTests(p1, 1)
		VehicleWheelControllerService.StepAll(0.4)

		local fSt = VehicleWheelControllerService.GetWheelState(p1, idsByAxle[1].L) :: VehicleTypes.WheelRuntimeState
		local rSt = VehicleWheelControllerService.GetWheelState(p1, idsByAxle[4].L) :: VehicleTypes.WheelRuntimeState
		assertTrue(fSt.TargetSteeringAngle < -20, "Front turns negative on right steer (+1)")
		assertTrue(rSt.TargetSteeringAngle > 10, "Rear counter-steers positive on right steer (+1)")
		assertTrue(lr.Success, "8-wheel vehicle launches cleanly")
		env.Teardown()
	end)

	-- 14
	runTest("Fase 3.2 [14]: Asymmetric layout flags clear warning and resolves safely without crashing", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32014, Name = "Asym" }
		PlotService.Assign(p1)
		placePieceReq(p1, "a_b0", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceReq(p1, "a_bf", "WoodBlock", CFrame.new(0, 1.5, -2))
		placePieceReq(p1, "a_br", "WoodBlock", CFrame.new(0, 1.5, 2))
		placePieceReq(p1, "a_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		placePieceReq(p1, "a_wl1", "SmallWheel", CFrame.new(-1.5, 1.5, -2))
		placePieceReq(p1, "a_wl2", "SmallWheel", CFrame.new(-1.5, 1.5, 0))
		placePieceReq(p1, "a_wl3", "SmallWheel", CFrame.new(-1.5, 1.5, 2))

		local wa = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		assertEqual(wa.WheelCount, 3, "3 wheels on left side")
		assertTrue(wa.IsAmbiguous, "Asymmetric lateral distribution detected")
		assertTrue(#wa.AmbiguityWarnings >= 1, "Emits lateral asymmetry warning")
		env.Teardown()
	end)

	-- 15
	runTest("Fase 3.2 [15]: Rotated DriverSeat (+90 deg yaw) reorients Front/Rear axes and Axle/Steering constraints", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32015, Name = "RotatedSeat" }
		PlotService.Assign(p1)
		-- DriverSeat mirando hacia -X (Yaw +90°): la derecha geométrica es -Z y adelante es -X
		local seatRot = BuildRotation.RotateY(BuildRotation.Identity(), 1)
		placePieceReq(p1, "r_b0", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceReq(p1, "r_bf", "WoodBlock", CFrame.new(-2, 1.5, 0))
		placePieceReq(p1, "r_br", "WoodBlock", CFrame.new(2, 1.5, 0))
		placePieceReq(p1, "r_seat", "DriverSeat", CFrame.new(0, 3.0, 0) * seatRot)

		local wheelTurnedL = BuildRotation.RotateY(BuildRotation.Identity(), 1)
		local wheelTurnedR = BuildRotation.RotateY(BuildRotation.Identity(), 3)
		local wFL = placePieceReq(p1, "r_wfl", "SmallWheel", CFrame.new(-2, 1.5, 1.5) * wheelTurnedL)
		local wFR = placePieceReq(p1, "r_wfr", "SmallWheel", CFrame.new(-2, 1.5, -1.5) * wheelTurnedR)
		local wRL = placePieceReq(p1, "r_wrl", "SmallWheel", CFrame.new(2, 1.5, 1.5) * wheelTurnedL)
		local wRR = placePieceReq(p1, "r_wrr", "SmallWheel", CFrame.new(2, 1.5, -1.5) * wheelTurnedR)

		local wa = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		assertTrue(wa.HasSeatReference, "Uses rotated DriverSeat reference")
		assertEqual(wa.ByPieceId[wFL].Analysis.AxleRole, "Front", "World -X became Front for +90° yaw DriverSeat")
		assertEqual(wa.ByPieceId[wFR].Analysis.AxleRole, "Front", "wFR is Front")
		assertEqual(wa.ByPieceId[wRL].Analysis.AxleRole, "Rear", "World +X became Rear")
		assertEqual(wa.ByPieceId[wRR].EffectiveSteeringEnabled, false, "Rear axle fixed")
		assertEqual(wa.ByPieceId[wFL].EffectiveSteeringEnabled, true, "Front axle steers")
		assertEqual(wa.ByPieceId[wFR].Analysis.SideRole, "Right", "Seat-relative Right classified correctly")

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Rotated vehicle launched cleanly")
		env.Teardown()
	end)

	-- 16
	runTest("Fase 3.2 [16]: Blueprint without DriverSeat degrades gracefully to heuristic longitudinal framing", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32016, Name = "NoSeatYet" }
		PlotService.Assign(p1)
		placePieceReq(p1, "ns_b0", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceReq(p1, "ns_bf", "WoodBlock", CFrame.new(0, 1.5, -2))
		placePieceReq(p1, "ns_br", "WoodBlock", CFrame.new(0, 1.5, 2))
		local w1 = placePieceReq(p1, "ns_w1", "SmallWheel", CFrame.new(-1.5, 1.5, -2))
		placePieceReq(p1, "ns_w2", "SmallWheel", CFrame.new(-1.5, 1.5, 2))

		local wa = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		assertEqual(wa.HasSeatReference, false, "HasSeatReference false without DriverSeat")
		assertEqual(wa.WheelCount, 2, "Analyzes wheels safely without DriverSeat")
		assertTrue(wa.ByPieceId[w1] ~= nil, "ResolvedWheelConfig produced without DriverSeat")
		env.Teardown()
	end)

	-- 17
	runTest("Fase 3.2 [17]: Flat horizontal or perpendicular wheels warn & safely block invalid suspension/steering", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32017, Name = "FlatWheel" }
		PlotService.Assign(p1)
		placePieceReq(p1, "fw_b0", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceReq(p1, "fw_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		-- RotateZ 90° pone el eje X cilíndrico apuntando verticalmente (+Y)
		local flatRot = BuildRotation.RotateZ(BuildRotation.Identity(), 1)
		local wFlat = placePieceReq(
			p1,
			"fw_w1",
			"SmallWheel",
			CFrame.new(0, 3.0, -2) * CFrame.Angles(0, 0, 0) -- dummy; let's connect top/side cleanly
		)
		-- Mover a encima de b0 con orientación horizontal válida (o probar en cara delantera bloque con RotateZ)
		BuildService.ProcessRequest(p1, { Action = "RemovePiece", ClientOpId = "fw_rm", PieceInstanceId = wFlat })
		placePieceReq(p1, "fw_bf", "WoodBlock", CFrame.new(0, 1.5, -4))
		placePieceReq(p1, "fw_bm", "WoodBlock", CFrame.new(0, 1.5, -2))
		local wFlatTop = placePieceReq(
			p1,
			"fw_wflat",
			"SmallWheel",
			CFrame.new(0, 3.0, -4) * flatRot,
			{ Wheel = { SteeringMode = "Enabled" } }
		)

		local wa = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		local resFlat = wa.ByPieceId[wFlatTop]
		assertTrue(resFlat.Analysis.OrientationBlocksSteering, "Horizontal wheel blocks steering")
		assertTrue(resFlat.Analysis.OrientationBlocksSuspension, "Horizontal wheel blocks vertical suspension")
		assertEqual(resFlat.EffectiveSteeringEnabled, false, "Even manual forced steering is safely blocked on flat wheel")
		assertEqual(resFlat.EffectiveSuspensionEnabled, false, "Suspension safely blocked on flat wheel")
		assertTrue(#resFlat.Warnings >= 1, "Orientation warning surfaced")
		env.Teardown()
	end)

	-- 18
	runTest("Fase 3.2 [18]: Disconnected workshop pieces do NOT pollute primary vehicle mass or axle analysis", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32018, Name = "ScopedPrimary" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t18")

		local baseAnalysis = WheelAutoConfigurationService.AnalyzeBlueprint(
			VehicleBlueprintService.GetBlueprintSnapshot(p1),
			{ TargetPieceId = w.SeatId }
		)
		local baseMass = baseAnalysis.EstimatedChassisMass

		-- Agregar chatarra pesada desconectada en BuildZone (RegularFuelTank suelto + SmallWheel suelta)
		placePieceReq(p1, "loose_tank", "RegularFuelTank", CFrame.new(10, 1.5, 10))
		placePieceReq(p1, "loose_wheel", "SmallWheel", CFrame.new(-10, 1.5, 10))

		local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertTrue(prep.Ready, "Loose workshop parts do not block launch when DriverSeat group is unique")

		local scopedAnalysis = WheelAutoConfigurationService.AnalyzeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), {
			PrimaryPieceIds = prep.PrimaryAssemblyPieceIds,
		})
		assertEqual(scopedAnalysis.WheelCount, 4, "Scoped analysis ignores loose wheel")
		assertNear(scopedAnalysis.EstimatedChassisMass, baseMass, 0.01, "Loose heavy fuel tank excluded from primary chassis mass")
		env.Teardown()
	end)

	-- 19
	runTest("Fase 3.2 [19]: Left (0 deg) and Right (180 deg) wheels align AxleHinge axes to identical forward vector", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32019, Name = "SpinAlign" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t19")
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local mechs = rt.WheelMechanisms :: { [string]: any }
		local seat = rt.DriverSeatPart :: VehicleSeat

		local axL = mechs[w.FL].AxleHinge.Attachment0.WorldAxis
		local axR = mechs[w.FR].AxleHinge.Attachment0.WorldAxis
		local expectedAxis = -seat.CFrame.RightVector
		assertTrue(axL:Dot(expectedAxis) > 0.99, "Left AxleHinge aligned to -VehicleRight")
		assertTrue(axR:Dot(expectedAxis) > 0.99, "Right AxleHinge aligned to -VehicleRight")
		assertTrue(axL:Dot(axR) > 0.99, "Left and Right axle spin vectors point identically")
		env.Teardown()
	end)

	-- 20
	runTest("Fase 3.2 [20]: Centralized Steering Servo rate-limiting, sign convention and direction multiplier", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32020, Name = "SteerServo" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t20", {
			WheelConfigs = {
				FL = { Wheel = { MaxSteeringAngle = 30, SteeringSpeed = 120 } },
				RL = { Wheel = { SteeringMode = "Enabled", MaxSteeringAngle = 15, SteeringDirectionMultiplier = -1 } },
			},
		})
		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })

		VehicleWheelControllerService.SetSteerOverrideForTests(p1, -1)
		VehicleWheelControllerService.StepAll(0.1) -- 120 °/s * 0.1s = 12° max step
		local midFL = VehicleWheelControllerService.GetWheelState(p1, w.FL) :: VehicleTypes.WheelRuntimeState
		assertNear(midFL.TargetSteeringAngle, 12.0, 0.2, "Steer rate limited cleanly by SteeringSpeed")

		VehicleWheelControllerService.StepAll(0.25) -- completa hasta +30°
		local fullFL = VehicleWheelControllerService.GetWheelState(p1, w.FL) :: VehicleTypes.WheelRuntimeState
		local fullRL = VehicleWheelControllerService.GetWheelState(p1, w.RL) :: VehicleTypes.WheelRuntimeState
		assertNear(fullFL.TargetSteeringAngle, 30.0, 0.1, "Left steer (-1) reaches +30 deg")
		assertNear(fullRL.TargetSteeringAngle, -15.0, 0.1, "Inverted rear steer turns -15 deg")

		VehicleWheelControllerService.SetSteerOverrideForTests(p1, 1)
		for _ = 1, 3 do
			VehicleWheelControllerService.StepAll(0.2)
		end
		local rightFL = VehicleWheelControllerService.GetWheelState(p1, w.FL) :: VehicleTypes.WheelRuntimeState
		assertNear(rightFL.TargetSteeringAngle, -30.0, 0.1, "Right steer (+1) reaches -30 deg")
		env.Teardown()
	end)

	-- 21
	runTest("Fase 3.2 [21]: Exiting DriverSeat / clearing steering returns TargetSteeringAngle smoothly to 0", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32021, Name = "AutoCenter" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t21")
		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })

		VehicleWheelControllerService.SetSteerOverrideForTests(p1, -1)
		VehicleWheelControllerService.StepAll(0.4)
		assertTrue((VehicleWheelControllerService.GetWheelState(p1, w.FL) :: any).TargetSteeringAngle > 20, "Steered")

		VehicleWheelControllerService.SetSteerOverrideForTests(p1, nil)
		VehicleWheelControllerService.StepAll(0.4)
		local centered = VehicleWheelControllerService.GetWheelState(p1, w.FL) :: VehicleTypes.WheelRuntimeState
		assertNear(centered.TargetSteeringAngle, 0, 0.1, "Returns cleanly to 0 deg when unoccupied")
		env.Teardown()
	end)

	-- 22
	runTest("Fase 3.2 [22]: Calibrated Tire PhysicalProperties & NoCollisionConstraint clearance graph", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32022, Name = "TireProps" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t22")
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local mFL = (lr.Runtime :: any).WheelMechanisms[w.FL]

		local props = mFL.WheelPart.CustomPhysicalProperties :: PhysicalProperties
		assertTrue(props ~= nil, "Calibrated CustomPhysicalProperties applied")
		assertNear(props.Elasticity, GameConfig.Wheels.WheelElasticity, 0.01, "Reduced bounce Elasticity")
		assertTrue(props.Friction >= GameConfig.Wheels.WheelMinFriction, "Scaled tire friction applied")
		assertTrue(#mFL.NoCollisions >= 3, "NoCollisionConstraints protect wheel from Mount, Carrier, Pivot & nearby chassis")
		env.Teardown()
	end)

	-- 23
	runTest("Fase 3.2 [23]: Passive rolling resistance only (zero phantom self-propulsion in Fase 3.2)", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32023, Name = "PassiveRoll" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t23")
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local mFL = (lr.Runtime :: any).WheelMechanisms[w.FL]
		local seat = (lr.Runtime :: VehicleTypes.VehicleRuntime).DriverSeatPart :: VehicleSeat

		assertEqual(seat.Torque, 0, "DriverSeat Torque remains 0")
		assertEqual(seat.MaxSpeed, 0, "DriverSeat MaxSpeed remains 0")
		assertEqual(mFL.AxleHinge.AngularVelocity, 0, "Axle target velocity is 0 passively")
		assertNear(mFL.AxleHinge.MotorMaxTorque, GameConfig.Wheels.PassiveRollingFrictionTorque, 1e-4, "Only passive rolling resistance applied")
		env.Teardown()
	end)

	-- 24
	runTest("Fase 3.2 [24]: Fase 3.3 Powertrain Contract (Drive commands, IsDriven gating, BrakeTorque, ClearDrive)", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32024, Name = "PowertrainContract" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t24", {
			WheelConfigs = {
				FL = { Wheel = { IsDriven = false } },
				FR = { Wheel = { IsDriven = true, DriveDirection = -1 } },
				RL = { Wheel = { IsDriven = true, DriveDirection = 1 } },
			},
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		local allStates = VehicleWheelControllerService.GetVehicleWheels(p1)
		assertEqual(#allStates, 4, "GetVehicleWheels exposes all 4 wheels")

		local okSet = VehicleWheelControllerService.SetVehicleDriveCommands(p1, {
			TargetAngularVelocity = 20,
			TorqueLimit = 4000,
		})
		assertTrue(okSet, "SetVehicleDriveCommands accepted")

		local flSt = VehicleWheelControllerService.GetWheelState(p1, w.FL) :: VehicleTypes.WheelRuntimeState
		local frSt = VehicleWheelControllerService.GetWheelState(p1, w.FR) :: VehicleTypes.WheelRuntimeState
		local rlSt = VehicleWheelControllerService.GetWheelState(p1, w.RL) :: VehicleTypes.WheelRuntimeState
		assertEqual(flSt.TorqueLimit, 0, "Non-driven wheel keeps passive resistance when Motor commanded")
		assertEqual(frSt.TorqueLimit, 4000, "Driven wheel receives TorqueLimit")
		assertEqual(frSt.TargetAngularVelocity, -20, "DriveDirection = -1 flips commanded AngularVelocity")
		assertEqual(rlSt.TargetAngularVelocity, 20, "DriveDirection = +1 keeps forward AngularVelocity")

		-- Brake overrides Motor even on non-driven wheels
		VehicleWheelControllerService.SetWheelDriveCommand(p1, w.FL, { BrakeTorque = 950 })
		local flBrake = VehicleWheelControllerService.GetWheelState(p1, w.FL) :: VehicleTypes.WheelRuntimeState
		assertEqual(flBrake.BrakeTorque, 950, "BrakeTorque applied cleanly")
		assertEqual((rt.WheelMechanisms :: any)[w.FL].AxleHinge.MotorMaxTorque, 950, "AxleHinge receives brake torque")

		VehicleWheelControllerService.ClearDriveCommands(p1)
		local rlCleared = VehicleWheelControllerService.GetWheelState(p1, w.RL) :: VehicleTypes.WheelRuntimeState
		assertEqual(rlCleared.TorqueLimit, 0, "ClearDriveCommands resets driven wheels back to passive rolling")
		env.Teardown()
	end)

	-- 25
	runTest("Fase 3.2 [25]: Non-functional or detached wheel zeroes Motor torque & centers Steering safely", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32025, Name = "DetachSafe" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t25")
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		VehicleWheelControllerService.SetSteerOverrideForTests(p1, -1)
		VehicleWheelControllerService.SetWheelDriveCommand(p1, w.FL, { TargetAngularVelocity = 12, TorqueLimit = 3000 })
		VehicleWheelControllerService.StepAll(0.4)
		assertTrue((VehicleWheelControllerService.GetWheelState(p1, w.FL) :: any).IsFunctional, "Initially functional")

		rt.Parts[w.FL].IsFunctional = false
		VehicleWheelControllerService.StepAll(0.1)
		local brokenSt = VehicleWheelControllerService.GetWheelState(p1, w.FL) :: VehicleTypes.WheelRuntimeState
		assertEqual(brokenSt.IsFunctional, false, "Detected non-functional wheel")
		assertEqual((rt.WheelMechanisms :: any)[w.FL].AxleHinge.MotorMaxTorque, 0, "MotorMaxTorque disabled when non-functional")
		assertEqual((rt.WheelMechanisms :: any)[w.FL].SteeringHinge.TargetAngle, 0, "Steering centered when non-functional")
		env.Teardown()
	end)

	-- 26
	runTest("Fase 3.2 [26]: Centralized single orchestrator (no scripts inside wheel rigs) & clean unregister", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32026, Name = "NoScripts" }
		PlotService.Assign(p1)
		buildFourWheelKart(p1, "t26")
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local root = (lr.Runtime :: VehicleTypes.VehicleRuntime).RootModel :: Model

		for _, desc in ipairs(root:GetDescendants()) do
			assertTrue(not desc:IsA("BaseScript"), `No Script/LocalScript permitted inside runtime vehicle ({desc:GetFullName()})`)
		end
		assertEqual(VehicleWheelControllerService.GetRegisteredVehicleCount(), 1, "1 vehicle in central controller")

		VehicleLaunchService.ReturnToWorkshop(p1)
		assertEqual(VehicleWheelControllerService.GetRegisteredVehicleCount(), 0, "Unregistered on ReturnToWorkshop")
		env.Teardown()
	end)

	-- 27
	runTest("Fase 3.2 [27]: Multi-assembly NetworkOwnership tracks Chassis + Carriers + Pivots + Wheels roots", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32027, Name = "MultiNetOwner" }
		PlotService.Assign(p1)
		buildFourWheelKart(p1, "t27")
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local root = rt.RootModel :: Model

		local rootCount = root:GetAttribute("NetworkAssemblyRootsCount") :: number
		-- 1 chassis + 4 carriers + 2 front pivots + 4 wheels = 11 distinct physical roots
		assertEqual(rootCount, 11, "All 11 multi-assembly roots visited cleanly by ApplyNetworkOwnership")
		assertEqual(rt.NetworkOwnerUserId, nil, "Unmanned starts owned by server")

		VehicleLifecycleService.CompleteLaunchWithSeatMount(p1, rt, { MountDriver = true, SimulateSeated = true, SkipSeatRetryYield = true })
		-- Fake player table has no Player Instance -> owner remains nil cleanly while state moves cleanly; check attribute present
		assertTrue(root:GetAttribute("NetworkOwnerUserId") ~= nil, "NetworkOwner attribute tracked")
		env.Teardown()
	end)

	-- 28
	runTest("Fase 3.2 [28]: Server UpdatePieceConfig mutates Revision, Editable attribute, SyncEvent & ClientOpId idempotency", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32028, Name = "NetSync" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t28")

		local capturedSyncs: { BuildProtocol.BlueprintSyncPayload } = {}
		local unsub = BuildService.RegisterSyncListener(function(targetPlayer, payload)
			if targetPlayer.UserId == p1.UserId and payload.Type == BuildProtocol.SyncTypes.PieceConfigUpdated then
				table.insert(capturedSyncs, payload)
			end
		end)

		local req = {
			Action = "UpdatePieceConfig",
			ClientOpId = "t28_cfg_1",
			PieceInstanceId = w.FL,
			Config = { Wheel = { MaxSteeringAngle = 42, IsDriven = false } },
		}
		local r1 = BuildService.ProcessRequest(p1, req)
		assertTrue(r1.Success and r1.UpdatedPiece ~= nil, "First UpdatePieceConfig succeeds")
		local rev1 = r1.Revision

		local editableRoot = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		local editableModel = editableRoot:FindFirstChild(w.FL) :: Model
		assertEqual(editableModel:GetAttribute("HasManualWheelConfig"), true, "Editable piece tagged HasManualWheelConfig=true")
		assertEqual(#capturedSyncs, 1, "PieceConfigUpdated sync emitted once")

		-- Reenvío idempotente con mismo ClientOpId
		local rDup = BuildService.ProcessRequest(p1, req)
		assertTrue(rDup.Success and rDup.Revision == rev1, "Duplicate ClientOpId returns cached response without double revision bump")
		assertEqual(#capturedSyncs, 1, "No duplicate SyncEvent emitted on retry")

		unsub()
		env.Teardown()
	end)

	-- 29
	runTest("Fase 3.2 [29]: ResetToAuto = true restores pure Auto defaults & clears Piece.Config", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32029, Name = "ResetAuto" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t29", {
			WheelConfigs = {
				FL = { Wheel = { SteeringMode = "Disabled", SpringStiffness = 5000, IsDriven = false } },
			},
		})

		local beforePiece = VehicleBlueprintService.GetPieceSnapshot(p1, w.FL) :: VehicleTypes.BlueprintPiece
		assertTrue(beforePiece.Config ~= nil, "Initially manual config stored")

		local rReset = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "t29_reset",
			PieceInstanceId = w.FL,
			ResetToAuto = true,
		})
		assertTrue(rReset.Success, "ResetToAuto succeeds")
		local afterPiece = VehicleBlueprintService.GetPieceSnapshot(p1, w.FL) :: VehicleTypes.BlueprintPiece
		assertEqual(afterPiece.Config, nil, "Config cleared to nil on ResetToAuto")
		local editableAfter = (VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model):FindFirstChild(w.FL) :: Model
		assertEqual(editableAfter:GetAttribute("HasManualWheelConfig"), false, "Editable flag cleared")
		env.Teardown()
	end)

	-- 30
	runTest("Fase 3.2 [30]: Save/Load/Duplicate Blueprint preserves wheel config & SchemaVersion 0 backward compatibility", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32030, Name = "PersistCompat" }
		local plot = PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t30", {
			WheelConfigs = {
				RL = { Wheel = { SteeringMode = "Enabled", MaxSteeringAngle = 18, SteeringDirectionMultiplier = -1, IsDriven = false } },
			},
		})

		local okSave, savedSummary = VehicleBlueprintService.SaveBlueprint(p1, plot, "CustomCrawler", false)
		assertTrue(okSave and savedSummary ~= nil, "Saved blueprint")

		local okDup, dupSummary = VehicleBlueprintService.DuplicateBlueprint(p1, (savedSummary :: any).BlueprintId, "CrawlerV2")
		assertTrue(okDup and dupSummary ~= nil, "Duplicated blueprint")

		local okLoad = VehicleBlueprintService.LoadBlueprint(p1, plot, (dupSummary :: any).BlueprintId)
		assertTrue(okLoad, "Loaded duplicated blueprint")
		local loadedRL = VehicleBlueprintService.GetPieceSnapshot(p1, w.RL) :: VehicleTypes.BlueprintPiece
		assertTrue(loadedRL.Config ~= nil and loadedRL.Config.Wheel.MaxSteeringAngle == 18, "Manual wheel override survived Save/Duplicate/Load")

		-- Legacy SchemaVersion = 0 sin campo Config en piezas
		local legacyRaw = {
			SchemaVersion = 0,
			BlueprintId = "bp_legacy",
			OwnerUserId = p1.UserId,
			Name = "LegacyCar",
			Revision = 3,
			Pieces = {
				{ InstanceId = "leg_1", ItemId = "WoodBlock", LocalCFrame = { 0, 1.5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
				{ InstanceId = "leg_2", ItemId = "DriverSeat", LocalCFrame = { 0, 3.0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
				{ InstanceId = "leg_3", ItemId = "SmallWheel", LocalCFrame = { -1.5, 1.5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
			},
			Connections = {},
		}
		local okDeser, legacyBp = BlueprintSerializer.DeserializeBlueprint(legacyRaw, p1.UserId)
		assertTrue(okDeser and legacyBp ~= nil, "Legacy SchemaVersion 0 deserialized and migrated cleanly")
		local legAnalysis = WheelAutoConfigurationService.AnalyzeBlueprint(legacyBp :: VehicleTypes.VehicleBlueprint)
		assertEqual(legAnalysis.ByPieceId["leg_3"].SteeringMode, "Auto", "Legacy wheel resolves cleanly to Auto")
		env.Teardown()
	end)

	-- 31
	runTest("Fase 3.2 [31]: Strict Blueprint vs Runtime separation during Launch, DriveCommands & ReturnToWorkshop", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32031, Name = "SepRuntime" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t31", {
			WheelConfigs = {
				FL = { Wheel = { MaxSteeringAngle = 22 } },
			},
		})
		local revBefore = VehicleBlueprintService.GetBlueprintSnapshot(p1).Revision

		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		VehicleWheelControllerService.SetVehicleDriveCommands(p1, { TargetAngularVelocity = 30, TorqueLimit = 5000 })
		VehicleWheelControllerService.SetSteerOverrideForTests(p1, 1)
		VehicleWheelControllerService.StepAll(0.5)
		VehicleLaunchService.ReturnToWorkshop(p1)

		local bpAfter = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		assertEqual(bpAfter.Revision, revBefore, "Blueprint Revision unchanged across runtime lifecycle")
		local flPiece = VehicleBlueprintService.GetPieceSnapshot(p1, w.FL) :: VehicleTypes.BlueprintPiece
		assertEqual((flPiece.Config :: any).Wheel.MaxSteeringAngle, 22, "Manual config intact after ReturnToWorkshop")
		assertEqual((flPiece.Config :: any).Wheel.AngularVelocity, nil, "No transient runtime state leaked into Blueprint")
		env.Teardown()
	end)

	-- 32
	runTest("Fase 3.2 [32]: Security rejections (out-of-range, NaN/Inf, metatables, non-wheel piece, spoofing)", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 320321, Name = "Attacker" }
		local p2: PlotService.PlayerLike = { UserId = 320322, Name = "Victim" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)
		local w1 = buildFourWheelKart(p1, "atk")
		local w2 = buildFourWheelKart(p2, "vic")

		local badRange = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "sec_1",
			PieceInstanceId = w1.FL,
			Config = { Wheel = { MaxSteeringAngle = 999 } },
		})
		assertTrue(not badRange.Success and badRange.ErrorCode == BuildProtocol.ErrorCodes.InvalidConfigRange, "Out-of-range MaxSteeringAngle rejected")

		local badNaN = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "sec_2",
			PieceInstanceId = w1.FL,
			Config = { Wheel = { SpringStiffness = 0 / 0 } },
		})
		assertTrue(not badNaN.Success, "NaN SpringStiffness rejected")

		local metaTbl = setmetatable({ Wheel = { MaxSteeringAngle = 20 } }, { __index = function() return 1 end })
		local badMeta = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "sec_3",
			PieceInstanceId = w1.FL,
			Config = metaTbl,
		})
		assertTrue(not badMeta.Success and badMeta.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Metatable Config rejected")

		local badPiece = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "sec_4",
			PieceInstanceId = w1.MountFrontId,
			Config = { Wheel = { MaxSteeringAngle = 20 } },
		})
		assertTrue(not badPiece.Success and badPiece.ErrorCode == BuildProtocol.ErrorCodes.PieceNotConfigurable, "Non-wheel rejected as PieceNotConfigurable")

		local crossPlayer = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "sec_5",
			PieceInstanceId = w2.FL,
			Config = { Wheel = { MaxSteeringAngle = 20 } },
		})
		assertTrue(not crossPlayer.Success and crossPlayer.ErrorCode == BuildProtocol.ErrorCodes.PieceNotFound, "Cross-player UpdatePieceConfig blocked")

		local badUnknownKey = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "sec_6",
			PieceInstanceId = w1.FL,
			Config = { Wheel = { HackedTurbo = 9999 } },
		})
		assertTrue(not badUnknownKey.Success, "Unknown field rejected")
		env.Teardown()
	end)

	-- 33
	runTest("Fase 3.2 [33]: UpdatePieceConfig blocked cleanly while vehicle is launched (non-Editing state)", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32033, Name = "EditLock" }
		PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t33")
		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })

		local blocked = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "t33_lock",
			PieceInstanceId = w.FL,
			Config = { Wheel = { MaxSteeringAngle = 35 } },
		})
		assertTrue(not blocked.Success and blocked.ErrorCode == BuildProtocol.ErrorCodes.InvalidPlayerState, "Config edits rejected during active runtime")
		env.Teardown()
	end)

	-- 34
	runTest("Fase 3.2 [34]: VehicleLaunchPreparationService reports non-blocking WheelCount & WheelWarnings", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32034, Name = "PrepInfo" }
		PlotService.Assign(p1)
		placePieceReq(p1, "p_b0", "WoodBlock", CFrame.new(0, 1.5, 0))
		placePieceReq(p1, "p_seat", "DriverSeat", CFrame.new(0, 3.0, 0))
		placePieceReq(p1, "p_wl", "SmallWheel", CFrame.new(-1.5, 1.5, 0))
		placePieceReq(p1, "p_wr", "SmallWheel", CFrame.new(1.5, 1.5, 0) * BuildRotation.RotateY(BuildRotation.Identity(), 2))

		local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1, { SkipWorldObstructionCheck = true })
		assertTrue(prep.Ready, "Ambiguous wheel layout advisory does NOT block launch")
		assertEqual(prep.WheelCount, 2, "PrepReport exposes WheelCount")
		assertTrue(prep.WheelWarnings ~= nil and #(prep.WheelWarnings :: { string }) >= 1, "PrepReport surfaces wheel advisory")
		env.Teardown()
	end)

	-- 35
	runTest("Fase 3.2 [35]: Client WheelConfigController optimistic apply, rollback on reject, & BuildState PieceConfigUpdated sync", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32035, Name = "ClientSync" }
		local plot = PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t35")

		BuildState.Reset()
		BuildState.ExpectedOwnerUserId = p1.UserId
		local plotRec = plot :: PlotService.PlotRecord
		BuildState.SetPlot(plotRec.Model, plotRec.Zones.BuildZone)
		BuildState.SetActive(true)
		BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), true)
		BuildState.SetSelectedPlacedPiece(w.FL)

		-- Rechazo del servidor -> rollback preserva nil anterior
		local okFail = WheelConfigController.SetWheelField(w.FL, "MaxSteeringAngle", 40, function()
			return {
				Success = false,
				Revision = BuildState.BlueprintRevision,
				ErrorCode = BuildProtocol.ErrorCodes.InvalidConfigRange,
				ErrorMessage = "Rechazado en prueba",
			}
		end)
		assertEqual(okFail, false, "Failed server call returns false")
		assertEqual((BuildState.GetPiece(w.FL) :: any).Config, nil, "Rollback restored previous nil config")

		-- Éxito real contra BuildService + selección conservada
		local okSucc = WheelConfigController.SetWheelField(w.FL, "MaxSteeringAngle", 36, function(req)
			return BuildService.ProcessRequest(p1, req)
		end)
		assertTrue(okSucc, "Real server SetWheelField succeeded")
		assertEqual((BuildState.GetPiece(w.FL) :: any).Config.Wheel.MaxSteeringAngle, 36, "Client BuildState updated cleanly")
		assertEqual(BuildState.SelectedPlacedPieceId, w.FL, "Selected wheel stays selected after config edit")

		-- Evento incremental SyncEvent desde revisión siguiente
		local nextPiece = BlueprintSerializer.ClonePiece(BuildState.GetPiece(w.RL) :: VehicleTypes.BlueprintPiece)
		nextPiece.Config = { Wheel = { SteeringMode = "Enabled" } }
		local applied, needsResync = BuildState.ApplySyncEvent({
			Type = BuildProtocol.SyncTypes.PieceConfigUpdated,
			OwnerUserId = p1.UserId,
			BlueprintId = BuildState.BlueprintId :: string,
			Revision = BuildState.BlueprintRevision + 1,
			UpdatedPiece = nextPiece,
		})
		assertTrue(applied and not needsResync, "Incremental PieceConfigUpdated sync applied cleanly")
		assertEqual((BuildState.GetPiece(w.RL) :: any).Config.Wheel.SteeringMode, "Enabled", "Sync updated RL config")
		env.Teardown()
	end)

	-- 36
	runTest("Fase 3.2 [36]: Contextual WheelInspectorPanel visibility rules, badges & zero UI overlap bounds", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32036, Name = "UITest" }
		local plot = PlotService.Assign(p1)
		local w = buildFourWheelKart(p1, "t36")

		BuildState.Reset()
		BuildState.ExpectedOwnerUserId = p1.UserId
		local plotRec = plot :: PlotService.PlotRecord
		BuildState.SetPlot(plotRec.Model, plotRec.Zones.BuildZone)
		BuildState.SetActive(true)
		BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), true)

		local testGui = Instance.new("ScreenGui")
		local handle = WheelInspectorPanel.Mount(testGui, {})
		handle.Refresh()
		assertEqual(handle.IsOpen(), false, "Inspector hidden with no selection")

		-- Seleccionar bloque no rueda -> sigue oculto
		BuildState.SetSelectedPlacedPiece(w.MountFrontId)
		handle.Refresh()
		assertEqual(handle.IsOpen(), false, "Inspector stays hidden on WoodBlock")

		-- Seleccionar SmallWheel -> aparece automáticamente en modo AUTO
		BuildState.SetSelectedPlacedPiece(w.FL)
		handle.Refresh()
		assertEqual(handle.IsOpen(), true, "Inspector opens automatically for selected SmallWheel")
		local badge = handle.Frame:FindFirstChild("Header") and (handle.Frame :: any).Header:FindFirstChild("ModeBadge") :: TextLabel
		assertEqual(badge.Text, "AUTO", "Badge displays AUTO initially")

		-- Verificar geometría sin colisión contra barra superior (Y <= 56) ni EditorPanel inferior (altura 248px desde abajo en 720p)
		-- WheelInspectorPanel está en AnchorPoint (1,0), Pos (1,-14, 0, 68), Size (312, 376): Y_top = 68 (> 56), Y_bottom = 444 (< 720 - 248 - 12 = 460)!
		local topY = handle.Frame.Position.Y.Offset
		local heightPx = handle.Frame.Size.Y.Offset
		assertTrue(topY >= 64, "Inspector clears top 56px action bar")
		assertTrue(topY + heightPx <= 720 - 248 - 12, "Inspector clears bottom 248px EditorPanel on 720p viewport")

		-- Editar manualmente -> cambia a MIXTO y al pasar a Driving se oculta
		WheelConfigController.SetWheelField(w.FL, "MaxSteeringAngle", 32, function(req)
			return BuildService.ProcessRequest(p1, req)
		end)
		handle.Refresh()
		assertEqual(badge.Text, "MIXTO", "Badge updates to MIXTO when mixed manual/auto")

		BuildState.SetRuntimeStatus({
			State = GameConfig.Runtime.States.Driving :: VehicleTypes.VehicleState,
			DriverSeated = true,
			PieceCount = 8,
			JointCount = 3,
		})
		handle.Refresh()
		assertEqual(handle.IsOpen(), false, "Inspector hides automatically outside Editing mode")

		handle.Destroy()
		testGui:Destroy()
		env.Teardown()
	end)

	-- 37
	runTest("Fase 3.2 [37]: 10-player concurrent multi-vehicle wheel editing, launch, central StepAll & isolated cleanup", function()
		local env = setupIsolatedWorld(10)
		local players: { PlotService.PlayerLike } = {}
		local wheelRefs: { { FL: string, RL: string } } = {}

		for i = 1, 10 do
			local plr: PlotService.PlayerLike = { UserId = 32100 + i, Name = `WheelPlayer_{i}` }
			players[i] = plr
			PlotService.Assign(plr)
			local w = buildFourWheelKart(plr, `p{i}`, {
				Heavy = (i % 2 == 0),
				SeatYawSteps = (i % 4),
			})
			wheelRefs[i] = { FL = w.FL, RL = w.RL }

			-- Personalización distinta por jugador
			local customAngle = 15 + i * 2
			local rCfg = BuildService.ProcessRequest(plr, {
				Action = "UpdatePieceConfig",
				ClientOpId = `cfg_{i}`,
				PieceInstanceId = w.FL,
				Config = { Wheel = { MaxSteeringAngle = customAngle } },
			})
			assertTrue(rCfg.Success, `Player {i} UpdatePieceConfig succeeded`)
		end

		for i = 1, 10 do
			local lr = VehicleLaunchService.LaunchVehicle(players[i], { MountDriver = false, SkipWorldObstructionCheck = true })
			assertTrue(lr.Success, `Player {i} launched simultaneously`)
		end
		assertEqual(VehicleWheelControllerService.GetRegisteredVehicleCount(), 10, "All 10 vehicles tracked concurrently")

		-- Aplicar comandos independientes de dirección y potencia en cada vehículo sin interferencia
		for i = 1, 10 do
			local signSteer = if i % 2 == 0 then 1 else -1
			VehicleWheelControllerService.SetSteerOverrideForTests(players[i], signSteer)
			VehicleWheelControllerService.SetVehicleDriveCommands(players[i], {
				TargetAngularVelocity = 10 + i,
				TorqueLimit = 1000 + i * 100,
			})
		end
		for _ = 1, 3 do
			VehicleWheelControllerService.StepAll(0.2)
		end

		for i = 1, 10 do
			local st = VehicleWheelControllerService.GetWheelState(players[i], wheelRefs[i].FL) :: VehicleTypes.WheelRuntimeState
			local expectedAngle = 15 + i * 2
			local signSteer = if i % 2 == 0 then 1 else -1
			assertNear(st.TargetSteeringAngle, -signSteer * expectedAngle, 0.2, `Player {i} independent MaxSteeringAngle`)
			assertEqual(st.TorqueLimit, 1000 + i * 100, `Player {i} independent drive command isolated`)
		end

		for i = 1, 10 do
			local ret = VehicleLaunchService.ReturnToWorkshop(players[i])
			assertTrue(ret.Success, `Player {i} returned cleanly`)
			PlotService.Release(players[i])
		end
		assertEqual(VehicleWheelControllerService.GetRegisteredVehicleCount(), 0, "Zero leftover tracked vehicles after 10-player teardown")
		env.Teardown()
	end)

	-- 38
	runTest("Fase 3.2 [38]: Repeated Launch/Reset/Return cycles (10x) yield zero orphan rigs, constraints or memory leaks", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 32038, Name = "LeakCheck" }
		local plot = PlotService.Assign(p1)
		buildFourWheelKart(p1, "t38")

		for iter = 1, 10 do
			env.AdvanceClock(5)
			local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
			assertTrue(lr.Success, `Iter {iter} launch succeeded`)
			env.AdvanceClock(5)
			local rr = VehicleLaunchService.ResetVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
			assertTrue(rr.Success, `Iter {iter} reset succeeded`)
			env.AdvanceClock(5)
			local ret = VehicleLaunchService.ReturnToWorkshop(p1)
			assertTrue(ret.Success, `Iter {iter} return succeeded`)
		end

		assertEqual(VehicleWheelControllerService.GetRegisteredVehicleCount(), 0, "Zero registered vehicles after 10 cycles")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero active runtimes")
		assertEqual(VehicleRuntimeService.GetTrackedConnectionCount(), 0, "Zero leaked RBXScriptConnections")
		assertTrue(plot.DynamicContainer:FindFirstChild(GameConfig.Runtime.ModelName) == nil, "DynamicContainer free of orphan runtime models")
		PlotService.Release(p1)
		assertEqual(VehicleBlueprintService.GetTrackedPlayerCount(), 0, "Zero tracked blueprints after Release")
		env.Teardown()
	end)
end

return Phase32Tests
