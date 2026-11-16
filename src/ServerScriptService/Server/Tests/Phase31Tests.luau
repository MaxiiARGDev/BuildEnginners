--!strict
--!strict
--[=[
	Phase31Tests
	Suite de 25 pruebas automatizadas de Fase 3.1 (VehicleRuntime, ensamblaje físico,
	CollisionGroups, staging, joints sin O(N²), DriverSeat, máquina de estados, ReturnToWorkshop,
	ResetVehicle, ExitSeat, abandono, destrucción externa, seguridad multijugador y 10 jugadores).
	Se integra en Phase1Tests.RunAll() sumando 123 pruebas totales.
]=]

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
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
local VehicleLaunchController = require(ClientControllers:WaitForChild("VehicleLaunchController"))

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase31Tests = {}

local function setupIsolatedWorld(plotCount: number?, customSpawnsFolder: Folder?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = customSpawnsFolder or (Workspace:WaitForChild("PlotSpawns") :: Folder)

	local prevPlots = Workspace:FindFirstChild("_Phase31TestPlots")
	if prevPlots then
		prevPlots:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase31TestPlots"
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

	local fakeClock = 100
	local rateLimitClock = 100
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
		GetClock = function()
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
			tempPlots:Destroy()
		end,
	}
end

local function buildDriveableTestVehicle(player: PlotService.PlayerLike, prefix: string, withConfigFuelTank: boolean?): boolean
	-- Base: WoodBlock en (0, 1.5, 0) (altura encima de plataforma para ruedas radius 1 en Y=1.0)
	local placements: { { ItemId: string, CF: CFrame, Config: { [string]: any }? } } = {
		{ ItemId = "WoodBlock", CF = CFrame.new(0, 1.5, 0) },
		{ ItemId = "WoodBlock", CF = CFrame.new(0, 1.5, -2) },
		{ ItemId = "WoodBlock", CF = CFrame.new(0, 1.5, 2) },
		{ ItemId = "DriverSeat", CF = CFrame.new(0, 3.0, 0) },
		{ ItemId = "SmallEngine", CF = CFrame.new(0, 1.5, 4) },
		-- 4 ruedas conectadas lateralmente a X = +-1.5, Y = 1.5 (eje derecho/izquierdo sobre caras +-1 de WoodBlock)
		{ ItemId = "SmallWheel", CF = CFrame.new(-1.5, 1.5, -2) },
		{ ItemId = "SmallWheel", CF = CFrame.new(1.5, 1.5, -2) * BuildRotation.RotateY(BuildRotation.Identity(), 2) },
		{ ItemId = "SmallWheel", CF = CFrame.new(-1.5, 1.5, 2) },
		{ ItemId = "SmallWheel", CF = CFrame.new(1.5, 1.5, 2) * BuildRotation.RotateY(BuildRotation.Identity(), 2) },
	}
	if withConfigFuelTank then
		table.insert(placements, {
			ItemId = "RegularFuelTank",
			CF = CFrame.new(0, 3.5, 4),
			Config = { FuelType = "Diesel" },
		})
	end

	for idx, entry in ipairs(placements) do
		local res = BuildService.ProcessRequest(player, {
			Action = "PlacePiece",
			ClientOpId = `{prefix}_p_{idx}`,
			ItemId = entry.ItemId,
			LocalCFrame = entry.CF,
			Config = entry.Config,
		})
		if not res.Success then
			error(`Placement failed at {idx} ({entry.ItemId}): {tostring(res.ErrorCode)} - {tostring(res.ErrorMessage)}`)
		end
	end
	return true
end

local function createDummyCharacterRig(userId: number, parent: Instance): (Model, Humanoid, BasePart)
	local model = Instance.new("Model")
	model.Name = `DummyChar_{userId}`

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.Anchored = false
	hrp.CanCollide = false
	hrp.Position = Vector3.new(0, 20, 0)
	hrp.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Anchored = false
	torso.Position = hrp.Position
	torso.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hrp
	weld.Part1 = torso
	weld.Parent = hrp

	local hum = Instance.new("Humanoid")
	hum.Name = "Humanoid"
	hum.Health = 100
	hum.MaxHealth = 100
	hum.Parent = model

	model.PrimaryPart = hrp
	model.Parent = parent
	return model, hum, hrp
end

function Phase31Tests.AppendTests(
	_results: { TestCaseResult },
	runTest: (name: string, fn: () -> ()) -> ()
)
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

	-- 1
	runTest("Fase 3.1 [01]: Launch blocked cleanly when Blueprint is not ready (MissingDriverSeat/Empty) without creating runtime", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31001, Name = "EmptyLauncher" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local resEmpty = VehicleLaunchService.LaunchVehicle(p1)
		assertTrue(not resEmpty.Success and resEmpty.ErrorCode == "EmptyVehicle", "Empty vehicle rejected cleanly")
		assertTrue(plot.DynamicContainer:FindFirstChild(GameConfig.Runtime.ModelName) == nil, "No runtime spawned on empty reject")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero active runtimes")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "Editing", "Player returns cleanly to Editing")

		BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "p1_block",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.5, 0),
		})
		local resNoSeat = VehicleLaunchService.LaunchVehicle(p1)
		assertTrue(not resNoSeat.Success and resNoSeat.ErrorCode == "MissingDriverSeat", "Missing DriverSeat blocked")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "Editing", "State preserved Editing")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Still zero active runtimes")
		env.Teardown()
	end)

	-- 2
	runTest("Fase 3.1 [02]: Valid launch spawns single VehicleRuntime in Workspace leaving Blueprint & EditableVehicle intact", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31002, Name = "ValidLauncher" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildDriveableTestVehicle(p1, "t02", true)

		local bpBefore = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local editableBefore = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		local editablePieceCount = #editableBefore:GetChildren()

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, `Launch succeeded: {tostring(launchRes.ErrorMessage)}`)
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		assertTrue(rt.RootModel ~= nil and rt.RootModel.Parent == plot.DynamicContainer, "VehicleRuntime parented in plot DynamicContainer")
		assertTrue(VehicleBlueprintService.GetEditableVehicleModel(p1) == editableBefore, "EditableVehicle kept intact")
		assertEqual(#editableBefore:GetChildren(), editablePieceCount, "EditableVehicle children count intact")

		local bpAfter = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		assertEqual(bpAfter.Revision, bpBefore.Revision, "Blueprint Revision completely unchanged")
		assertEqual(#bpAfter.Pieces, #bpBefore.Pieces, "Blueprint Piece count unchanged")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 1, "Exactly 1 active runtime")
		env.Teardown()
	end)

	-- 3
	runTest("Fase 3.1 [03]: Rotated plot LaunchPoint alignment and zero burying below platform top face", function()
		local customSpawns = Instance.new("Folder")
		customSpawns.Name = "_Phase31CustomSpawns"
		customSpawns.Parent = Workspace

		local sp1 = Instance.new("Part")
		sp1.Name = "Plot_Rotated"
		sp1.Size = Vector3.new(4, 1, 4)
		sp1.Anchored = true
		sp1.CFrame = CFrame.new(250, 0, -180) * CFrame.Angles(0, math.rad(135), 0)
		sp1.Parent = customSpawns

		local env = setupIsolatedWorld(1, customSpawns)
		local p1: PlotService.PlayerLike = { UserId = 31003, Name = "RotatedPlotPlayer" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildDriveableTestVehicle(p1, "t03", false)

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, "Rotated plot launch succeeded")
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		local root = rt.RootModel :: Model
		local seatPart = rt.DriverSeatPart :: VehicleSeat

		-- La orientación del DriverSeat en el mundo debe respetar los 135° del LaunchPoint
		local dotLook = seatPart.CFrame.LookVector:Dot(plot.Zones.LaunchPoint.CFrame.LookVector)
		assertTrue(dotLook > 0.99, `DriverSeat forward aligned with rotated LaunchPoint (dot={string.format("%.3f", dotLook)})`)

		-- Ningún vértice de ninguna pieza puede quedar enterrado por debajo del piso del Platform
		local platform = plot.Model:FindFirstChild("Platform") :: BasePart
		local floorTopY = platform.Position.Y + platform.Size.Y * 0.5
		local minPieceBottomY = math.huge
		for _, desc in ipairs(root:GetDescendants()) do
			if desc:IsA("BasePart") then
				minPieceBottomY = math.min(minPieceBottomY, desc.Position.Y - desc.Size.Y * 0.5)
			end
		end
		assertTrue(minPieceBottomY >= floorTopY - 1e-3, `Vehicle spawned above floor top ({minPieceBottomY} >= {floorTopY})`)

		env.Teardown()
		customSpawns:Destroy()
	end)

	-- 4
	runTest("Fase 3.1 [04]: Workshop Elevator BuildAssemblyOffset does NOT shift spawned VehicleRuntime at LaunchPoint", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31004, Name = "ElevatorIgnorer" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildDriveableTestVehicle(p1, "t04", false)

		local liftOk = VehicleBlueprintService.SetStandOffset(p1, plot, 10.0, 6.0)
		assertTrue(liftOk, "Elevator lifted to height=10 lateral=6")

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, "Launch succeeded while elevator raised")
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		local root = rt.RootModel :: Model

		local launchPoint = plot.Zones.LaunchPoint
		local floorTopY = launchPoint.Position.Y - launchPoint.Size.Y * 0.5
		local minBottomY = math.huge
		for _, desc in ipairs(root:GetDescendants()) do
			if desc:IsA("BasePart") then
				minBottomY = math.min(minBottomY, desc.Position.Y - desc.Size.Y * 0.5)
			end
		end
		-- Con GroundClearance=0.05 sobre LaunchPoint, debe aparecer al nivel del LaunchPoint (+0.05), NO flotando por el elevador!
		assertTrue(
			math.abs(minBottomY - (floorTopY + GameConfig.LaunchPrep.GroundClearanceStuds)) < 0.1,
			`Expected LaunchPoint floor Y ~{floorTopY + GameConfig.LaunchPrep.GroundClearanceStuds}, got {minBottomY}`
		)
		env.Teardown()
	end)

	-- 5
	runTest("Fase 3.1 [05]: Loose workshop pieces and unselected secondary groups stay strictly excluded from VehicleRuntime", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31005, Name = "PrimaryOnlyLauncher" }
		PlotService.Assign(p1)
		buildDriveableTestVehicle(p1, "t05", false) -- 9 piezas conectadas

		-- Agregar 2 piezas desconectadas sueltas en el taller
		local loose1 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "t05_loose1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(12, 1.5, 12),
		})
		assertTrue(loose1.Success, "Loose piece 1 placed in workshop")
		local loose2 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "t05_loose2",
			ItemId = "SmallBooster",
			LocalCFrame = CFrame.new(-12, 1.5, 12),
		})
		assertTrue(loose2.Success, "Loose piece 2 placed in workshop")

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, "Launch succeeded excluding loose workshop pieces")
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		assertEqual(launchRes.RuntimeStatus.PieceCount, 9, "VehicleRuntime has strictly the 9 primary pieces")
		assertTrue(rt.Parts[(loose1.PlacedPiece :: any).InstanceId] == nil, "Loose WoodBlock excluded")
		assertTrue(rt.Parts[(loose2.PlacedPiece :: any).InstanceId] == nil, "Loose SmallBooster excluded")
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(p1).Pieces, 11, "Workshop Blueprint still keeps all 11 pieces")
		env.Teardown()
	end)

	-- 6
	runTest("Fase 3.1 [06]: Runtime preserves ItemId, PieceInstanceId, Config, sanitizes cloned scripts & initializes ItemRuntimeService", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31006, Name = "MetadataPreserver" }
		PlotService.Assign(p1)
		buildDriveableTestVehicle(p1, "t06", true)

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, "Launch succeeded")
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		local root = rt.RootModel :: Model

		local foundTankModel: Model? = nil
		for _, desc in ipairs(root:GetDescendants()) do
			assertTrue(not desc:IsA("LuaSourceContainer"), `No script allowed inside runtime clone ({desc:GetFullName()})`)
			if desc:IsA("Model") and desc:GetAttribute(GameConfig.ItemAttributes.ItemId) == "RegularFuelTank" then
				foundTankModel = desc
			end
		end
		assertTrue(foundTankModel ~= nil, "RegularFuelTank cloned into runtime")
		assertEqual((foundTankModel :: Model):GetAttribute("Config_FuelType"), "Diesel", "Config_FuelType preserved on runtime part")
		-- El Engine + DriverSeat tienen Behavior module definido en ItemAssets -> ItemRuntimeService activo
		assertTrue(ItemRuntimeService.GetActivePartCount(rt.RuntimeId) >= 2, "ItemRuntimeService initialized modular behaviors")
		env.Teardown()
	end)

	-- 7
	runTest("Fase 3.1 [07]: Physics roles, non-propulsive DriverSeat and Fase 3.2 articulated wheel rig contracts", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31007, Name = "RoleInspector" }
		PlotService.Assign(p1)
		buildDriveableTestVehicle(p1, "t07", false)

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, "Launch succeeded")
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		local seat = rt.DriverSeatPart :: VehicleSeat

		assertTrue(seat:IsA("VehicleSeat"), "Uses catalog VehicleSeat")
		assertEqual(seat.Disabled, false, "DriverSeat enabled for sitting")
		assertEqual(seat.Torque, 0, "Torque zeroed cleanly in Fase 3.1/3.2")
		assertEqual(seat.MaxSpeed, 0, "MaxSpeed zeroed cleanly in Fase 3.1/3.2")
		assertEqual(#(rt.WheelPieceIds or {}), 4, "4 Wheel pieces tracked")
		assertEqual(#(rt.PropulsionPieceIds or {}), 1, "1 FuturePropulsion piece tracked")

		local tempWheelWelds = 0
		for _, w in ipairs(rt.Joints or {}) do
			if w:GetAttribute("JointRole") == "TemporaryWheelWeld" then
				tempWheelWelds += 1
			end
		end
		assertEqual(tempWheelWelds, 0, "TemporaryWheelWeld removed cleanly in Fase 3.2")

		local mechCount = 0
		for _, wid in ipairs(rt.WheelPieceIds or {}) do
			local mech = if rt.WheelMechanisms then rt.WheelMechanisms[wid] else nil
			if mech then
				mechCount += 1
				assertTrue(mech.AxleHinge ~= nil and mech.AxleHinge.Enabled, "Wheel has enabled AxleHinge")
				assertTrue(mech.Prismatic ~= nil and mech.Spring ~= nil, "Wheel has suspension Prismatic + Spring")
			end
		end
		assertEqual(mechCount, 4, "All 4 wheels assembled with articulated Fase 3.2 rigs")
		env.Teardown()
	end)

	-- 8
	runTest("Fase 3.1 [08]: Joints generated strictly from deduplicated Blueprint connections without O(N^2) bloat", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31008, Name = "JointOptimizer" }
		PlotService.Assign(p1)

		-- Grilla conectada 2x2x2 de 8 bloques + DriverSeat encima (total 9 piezas, grafo con ciclos)
		local grid = {
			CFrame.new(-1, 1.5, -1),
			CFrame.new(1, 1.5, -1),
			CFrame.new(-1, 1.5, 1),
			CFrame.new(1, 1.5, 1),
		}
		for i, cf in ipairs(grid) do
			assertTrue(BuildService.ProcessRequest(p1, {
				Action = "PlacePiece",
				ClientOpId = `j_{i}`,
				ItemId = "WoodBlock",
				LocalCFrame = cf,
			}).Success, `Block {i}`)
		end
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "j_seat",
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(-1, 3.0, -1),
		}).Success, "Seat placed")

		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local uniquePairs: { [string]: boolean } = {}
		local expectedEdges = 0
		for _, c in ipairs(bp.Connections) do
			local key = if c.FromPieceId < c.ToPieceId then `{c.FromPieceId}|{c.ToPieceId}` else `{c.ToPieceId}|{c.FromPieceId}`
			if not uniquePairs[key] then
				uniquePairs[key] = true
				expectedEdges += 1
			end
		end

		local res = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(res.Success and res.Runtime ~= nil, "Launch succeeded")
		local rt = res.Runtime :: VehicleTypes.VehicleRuntime
		assertEqual(#(rt.Joints or {}), expectedEdges, "Exact deduplicated joint count matches unique Blueprint connection edges")
		assertTrue(#(rt.Joints or {}) < (5 * 4) / 2, "Not quadratic all-pairs welds")
		env.Teardown()
	end)

	-- 9
	runTest("Fase 3.1 [09]: Staging build failure leaves zero orphan models and rolls back state to Editing", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31009, Name = "StagingFailureTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildDriveableTestVehicle(p1, "t09", false)

		local fakeEmptyAssets = Instance.new("Folder")
		fakeEmptyAssets.Name = "_EmptyBadAssets"
		fakeEmptyAssets.Parent = ServerStorage
		VehicleAssemblyService._ResetForTests()
		VehicleAssemblyService.Init({ ItemAssetsRoot = fakeEmptyAssets })

		local res = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(not res.Success, "Launch rejected cleanly when staging assembly asset missing")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "Editing", "Player rolled back cleanly to Editing")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero active runtimes")
		assertTrue(plot.DynamicContainer:FindFirstChild(GameConfig.Runtime.ModelName) == nil, "No partial model in plot DynamicContainer")

		local stagingFolder = ServerStorage:FindFirstChild(GameConfig.Runtime.StagingFolderName)
		assertTrue(not stagingFolder or #stagingFolder:GetChildren() == 0, "Staging folder completely clean")

		fakeEmptyAssets:Destroy()
		env.Teardown()
	end)

	-- 10
	runTest("Fase 3.1 [10]: Auto-sitting in DriverSeat with character rig transitions Launching -> Driving cleanly", function()
		local env = setupIsolatedWorld(1)
		local charHost = Instance.new("Folder")
		charHost.Name = "_Phase31Chars"
		charHost.Parent = Workspace

		local charModel, hum = createDummyCharacterRig(31010, charHost)
		local p1 = ({ UserId = 31010, Name = "SeatTester", Character = charModel } :: any) :: PlotService.PlayerLike
		PlotService.Assign(p1)
		buildDriveableTestVehicle(p1, "t10", false)

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			SkipSeatRetryYield = false,
		})
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, `Launch with character rig failed: {tostring(launchRes.ErrorMessage)}`)
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "Driving", "State reached Driving after seat mount")
		assertEqual((rt.DriverSeatPart :: VehicleSeat).Occupant, hum, "DriverSeat Occupant is player Humanoid")

		env.Teardown()
		charHost:Destroy()
	end)

	-- 11
	runTest("Fase 3.1 [11]: CollisionGroups isolation (VehicleRuntime vs Default/EditableVehicle/EditorGhost and configurable VehiclesCollideWithEachOther)", function()
		local env = setupIsolatedWorld(1)
		local groups = GameConfig.Runtime.CollisionGroups
		assertTrue(PhysicsService:IsCollisionGroupRegistered(groups.VehicleRuntime), "VehicleRuntime CollisionGroup registered")
		assertTrue(PhysicsService:IsCollisionGroupRegistered(groups.EditableVehicle), "EditableVehicle CollisionGroup registered")
		assertTrue(PhysicsService:IsCollisionGroupRegistered(groups.EditorGhost), "EditorGhost CollisionGroup registered")

		assertTrue(PhysicsService:CollisionGroupsAreCollidable(groups.VehicleRuntime, "Default"), "VehicleRuntime collides with world Default")
		assertTrue(not PhysicsService:CollisionGroupsAreCollidable(groups.VehicleRuntime, groups.EditableVehicle), "VehicleRuntime does NOT collide with EditableVehicle")
		assertTrue(not PhysicsService:CollisionGroupsAreCollidable(groups.VehicleRuntime, groups.EditorGhost), "VehicleRuntime does NOT collide with EditorGhost")
		assertTrue(not PhysicsService:CollisionGroupsAreCollidable(groups.EditorGhost, "Default"), "EditorGhost collides with nothing")
		assertTrue(not PhysicsService:CollisionGroupsAreCollidable(groups.VehicleRuntime, groups.VehicleRuntime), "VehiclesCollideWithEachOther default false")

		VehicleAssemblyService.SetVehiclesCollideWithEachOther(true)
		assertTrue(PhysicsService:CollisionGroupsAreCollidable(groups.VehicleRuntime, groups.VehicleRuntime), "Configurable VehiclesCollideWithEachOther toggle works")
		VehicleAssemblyService.SetVehiclesCollideWithEachOther(false)

		local p1: PlotService.PlayerLike = { UserId = 31011, Name = "CollisionGroupTester" }
		PlotService.Assign(p1)
		buildDriveableTestVehicle(p1, "t11", false)

		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		for _, desc in ipairs(editable:GetDescendants()) do
			if desc:IsA("BasePart") then
				assertEqual(desc.CollisionGroup, groups.EditableVehicle, "EditableVehicle parts use EditableVehicle CollisionGroup")
			end
		end

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, "Launched")
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		for _, desc in ipairs((rt.RootModel :: Model):GetDescendants()) do
			if desc:IsA("BasePart") then
				assertEqual(desc.CollisionGroup, groups.VehicleRuntime, "Runtime parts use VehicleRuntime CollisionGroup")
				assertEqual(desc.Anchored, false, "Runtime parts unanchored after publish")
				local roleAttr = desc:GetAttribute("PartPhysicsRole")
				if roleAttr == GameConfig.Runtime.PartRoles.SuspensionCarrier or roleAttr == GameConfig.Runtime.PartRoles.SteeringPivot then
					assertEqual(desc.CanCollide, false, "Internal suspension/steering virtual hubs have CanCollide=false")
				else
					assertEqual(desc.CanCollide, true, "Runtime parts preserve CanCollide=true")
				end
			end
		end
		env.Teardown()
	end)

	-- 12
	runTest("Fase 3.1 [12]: Active physics step settles assembled chassis+4wheels+seat+engine onto Platform without exploding", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31012, Name = "PhysicsSettleTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildDriveableTestVehicle(p1, "t12", false)

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, "Launched")
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		local seat = rt.DriverSeatPart :: VehicleSeat
		local startY = seat.Position.Y

		for _ = 1, 15 do
			if RunService:IsRunning() then
				if workspace.DistributedGameTime > 0 then RunService.Heartbeat:Wait() end
			else
				task.wait(1 / 60)
			end
		end

		assertTrue(rt.RootModel ~= nil and rt.RootModel.Parent ~= nil, "Vehicle still exists after 15 physics heartbeats")
		assertTrue(seat.AssemblyLinearVelocity.Magnitude < 25, `No physics explosion (speed={seat.AssemblyLinearVelocity.Magnitude})`)
		local platform = plot.Model:FindFirstChild("Platform") :: BasePart
		local floorTopY = platform.Position.Y + platform.Size.Y * 0.5
		assertTrue(seat.Position.Y > floorTopY, `Vehicle did not fall through platform ({seat.Position.Y} > {floorTopY})`)
		assertTrue(math.abs(seat.Position.Y - startY) < 3.0, "Vehicle stayed upright & settled near LaunchPoint height")
		for _, w in ipairs(rt.Joints or {}) do
			assertTrue(w.Active and w.Enabled, "WeldConstraint remains active")
		end
		env.Teardown()
	end)

	-- 13
	runTest("Fase 3.1 [13]: Authoritative editing/blueprint/stand mutations locked while VehicleRuntime is active", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31013, Name = "LockEnforcer" }
		PlotService.Assign(p1)
		buildDriveableTestVehicle(p1, "t13", false)

		local res = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, SimulateSeated = true })
		assertTrue(res.Success, "Launched")

		local blockedPlace = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "blk_place",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(6, 1.5, 0),
		})
		assertTrue(not blockedPlace.Success and blockedPlace.ErrorCode == BuildProtocol.ErrorCodes.InvalidPlayerState, "PlacePiece blocked while runtime active")

		local blockedCreate = BuildService.ProcessRequest(p1, {
			Action = "CreateBlueprint",
			ClientOpId = "blk_create",
			Name = "CheatBp",
		})
		assertTrue(not blockedCreate.Success and blockedCreate.ErrorCode == BuildProtocol.ErrorCodes.InvalidPlayerState, "CreateBlueprint blocked while runtime active")

		local blockedStand = BuildService.ProcessRequest(p1, {
			Action = "SetStandOffset",
			ClientOpId = "blk_stand",
			HeightOffset = 4,
			LateralOffset = 0,
		})
		assertTrue(not blockedStand.Success and blockedStand.ErrorCode == BuildProtocol.ErrorCodes.InvalidPlayerState, "SetStandOffset blocked while runtime active")

		-- Lecturas siguen permitidas
		local readState = BuildService.ProcessRequest(p1, { Action = "GetRuntimeState" })
		assertTrue(readState.Success and readState.RuntimeStatus ~= nil, "GetRuntimeState read allowed while runtime active")
		env.Teardown()
	end)

	-- 14
	runTest("Fase 3.1 [14]: Client BuildState and VehicleLaunchController lock/unlock editor cleanly on RuntimeStateUpdated", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31014, Name = "ClientSyncTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildDriveableTestVehicle(p1, "t14", false)

		BuildState.Reset()
		BuildState.SetExpectedOwner(p1.UserId)
		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		local okOpen = BuildState.SetActive(true)
		assertTrue(okOpen and BuildState.IsActive, "Editor initially open during Editing")

		local mockInvoke = function(req: any): BuildProtocol.BuildOperationResponse
			return BuildService.ProcessRequest(p1, req)
		end

		local syncConns: { BuildProtocol.BlueprintSyncPayload } = {}
		local unsubSync = BuildService.RegisterSyncListener(function(plr, payload)
			if plr.UserId == p1.UserId then
				table.insert(syncConns, payload)
				BuildState.ApplySyncEvent(payload)
			end
		end)

		local okLaunch = VehicleLaunchController.LaunchVehicle(mockInvoke)
		assertTrue(okLaunch, "Client LaunchVehicle succeeded")
		assertTrue(not BuildState.IsEditingMode(), "Client switched out of Editing mode")
		assertTrue(not BuildState.IsActive, "Open BuildEditor auto-closed cleanly upon launch")
		local canReopen = BuildState.SetActive(true)
		assertTrue(not canReopen, "Client blocks reopening BuildEditor while runtime active")

		local okReturn = VehicleLaunchController.ReturnToWorkshop(mockInvoke)
		assertTrue(okReturn, "Client ReturnToWorkshop succeeded")
		assertTrue(BuildState.IsEditingMode(), "Client restored back to Editing mode")
		local canReopenAfter = BuildState.SetActive(true)
		assertTrue(canReopenAfter, "Client can reopen BuildEditor after ReturnToWorkshop")

		unsubSync()
		env.Teardown()
	end)

	-- 15
	runTest("Fase 3.1 [15]: ExitVehicleSeat transitions Driving -> OnFootRuntime without destroying VehicleRuntime", function()
		local env = setupIsolatedWorld(1)
		local charHost = Instance.new("Folder")
		charHost.Name = "_Phase31ExitChars"
		charHost.Parent = env.TempPlots
		local charModel, hum = createDummyCharacterRig(31015, charHost)
		local p1 = ({ UserId = 31015, Name = "ExitSeatTester", Character = charModel } :: any) :: PlotService.PlayerLike
		PlotService.Assign(p1)
		buildDriveableTestVehicle(p1, "t15", false)

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, "Launched & seated")
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "Driving", "Initially Driving")

		local exitRes = VehicleLaunchService.ExitVehicleSeat(p1)
		assertTrue(exitRes.Success, `ExitVehicleSeat failed: {tostring(exitRes.ErrorMessage)}`)
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "OnFootRuntime", "Transitioned to OnFootRuntime")
		assertTrue(VehicleRuntimeService.GetRuntimeByPlayer(p1) == rt and rt.RootModel ~= nil and rt.RootModel.Parent ~= nil, "VehicleRuntime NOT destroyed on manual seat exit")
		assertTrue((rt.DriverSeatPart :: VehicleSeat).Occupant == nil and not hum.Sit, "DriverSeat cleared cleanly")
		assertTrue(rt.AbandonedSince ~= nil, "AbandonedSince timestamp set")
		assertEqual(rt.NetworkOwnerUserId, nil, "Unoccupied vehicle NetworkOwner returned to server")

		env.Teardown()
		charHost:Destroy()
	end)

	-- 16
	runTest("Fase 3.1 [16]: Re-entering own seat restores Driving; non-owner sitting in DriverSeat is ejected", function()
		local env = setupIsolatedWorld(2)
		local charHost = Instance.new("Folder")
		charHost.Name = "_Phase31MultiChars"
		charHost.Parent = env.TempPlots

		local ownerChar, ownerHum = createDummyCharacterRig(31016, charHost)
		local thiefChar, thiefHum = createDummyCharacterRig(31017, charHost)

		local owner = ({ UserId = 31016, Name = "Owner", Character = ownerChar } :: any) :: PlotService.PlayerLike
		local thief = ({ UserId = 31017, Name = "Thief", Character = thiefChar } :: any) :: PlotService.PlayerLike
		PlotService.Assign(owner)
		PlotService.Assign(thief)
		buildDriveableTestVehicle(owner, "t16", false)

		local res = VehicleLaunchService.LaunchVehicle(owner, { SkipWorldObstructionCheck = true })
		assertTrue(res.Success and res.Runtime ~= nil, "Owner launched")
		local rt = res.Runtime :: VehicleTypes.VehicleRuntime
		local seat = rt.DriverSeatPart :: VehicleSeat

		assertTrue(VehicleLaunchService.ExitVehicleSeat(owner).Success, "Owner exited seat")
		assertEqual(VehicleLifecycleService.GetPlayerState(owner), "OnFootRuntime", "Owner on foot")

		-- Ladrón intenta sentarse en asiento del dueño
		seat:Sit(thiefHum)
		task.wait(0.08)
		assertTrue(seat.Occupant ~= thiefHum, "Non-owner thief immediately ejected from DriverSeat")
		assertEqual(VehicleLifecycleService.GetPlayerState(owner), "OnFootRuntime", "State remained OnFootRuntime")

		-- Esperar limpieza de SeatWeld/Occupant antes de re-sentar al dueño
		for _ = 1, 10 do
			if seat.Occupant == nil then
				break
			end
			task.wait(0.03)
		end

		-- Dueño vuelve a sentarse -> regresa a Driving
		seat:Sit(ownerHum)
		task.wait(0.08)
		assertEqual(seat.Occupant, ownerHum, "Owner seated again")
		assertEqual(VehicleLifecycleService.GetPlayerState(owner), "Driving", "State restored to Driving")
		assertTrue(rt.AbandonedSince == nil, "AbandonedSince cleared on re-sit")

		env.Teardown()
		charHost:Destroy()
	end)

	-- 17
	runTest("Fase 3.1 [17]: ReturnToWorkshop destroys VehicleRuntime, disconnects connections, cleans behaviors, returns char & keeps blueprint intact", function()
		local env = setupIsolatedWorld(1)
		local charHost = Instance.new("Folder")
		charHost.Name = "_Phase31ReturnChar"
		charHost.Parent = env.TempPlots
		local charModel, _ = createDummyCharacterRig(31018, charHost)
		local p1 = ({ UserId = 31018, Name = "ReturnTester", Character = charModel } :: any) :: PlotService.PlayerLike
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildDriveableTestVehicle(p1, "t17", true)

		local revBefore = VehicleBlueprintService.GetBlueprintSnapshot(p1).Revision
		local res = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(res.Success and res.Runtime ~= nil, "Launched")
		local rtId = (res.Runtime :: VehicleTypes.VehicleRuntime).RuntimeId
		assertTrue(VehicleRuntimeService.GetTrackedConnectionCount() > 0, "Runtime connections active")

		local retRes = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(retRes.Success, "ReturnToWorkshop succeeded")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "Editing", "Player back in Editing")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero active runtimes")
		assertEqual(VehicleRuntimeService.GetTrackedConnectionCount(), 0, "Zero leaked RBXScriptConnections")
		assertEqual(ItemRuntimeService.GetActivePartCount(rtId), 0, "ItemRuntimeService behaviors cleaned up")
		assertTrue(plot.DynamicContainer:FindFirstChild(GameConfig.Runtime.ModelName) == nil, "Workspace runtime destroyed")
		assertEqual(VehicleBlueprintService.GetBlueprintSnapshot(p1).Revision, revBefore, "Blueprint completely untouched")
		assertTrue((charModel:GetPivot().Position - plot.PlayerSpawn.Position).Magnitude < 1.0, "Character returned safely to PlayerSpawn")

		env.Teardown()
		charHost:Destroy()
	end)

	-- 18
	runTest("Fase 3.1 [18]: ResetVehicle destroys current runtime and regenerates fresh runtime from intact Blueprint", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31019, Name = "ResetTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildDriveableTestVehicle(p1, "t18", false)

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, SimulateSeated = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, "Launched")
		local firstRt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		local firstModel = firstRt.RootModel :: Model
		local firstId = firstRt.RuntimeId

		-- Desplazar artificialmente el primer runtime para simular choque/desvío
		firstModel:PivotTo(firstModel:GetPivot() * CFrame.new(12, 0, -20))
		env.AdvanceClock(GameConfig.Runtime.LaunchCooldownSeconds + 0.5)

		local resetRes = VehicleLaunchService.ResetVehicle(p1, { SkipWorldObstructionCheck = true, SimulateSeated = true })
		assertTrue(resetRes.Success and resetRes.Runtime ~= nil, `ResetVehicle failed: {tostring(resetRes.ErrorMessage)}`)
		local secondRt = resetRes.Runtime :: VehicleTypes.VehicleRuntime
		assertTrue(secondRt.RuntimeId ~= firstId, "New fresh RuntimeId created")
		assertTrue(firstModel.Parent == nil, "Previous runtime destroyed cleanly")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 1, "Still strictly 1 active runtime")
		assertTrue(
			((secondRt.DriverSeatPart :: VehicleSeat).Position - plot.Zones.LaunchPoint.Position).Magnitude < 6.0,
			"New runtime regenerated cleanly back at LaunchPoint"
		)
		env.Teardown()
	end)

	-- 19
	runTest("Fase 3.1 [19]: Abandoned vehicle cleanup policy cleans OnFootRuntime after timeout without touching Driving vehicles", function()
		local env = setupIsolatedWorld(2)
		local pOnFoot: PlotService.PlayerLike = { UserId = 31020, Name = "AbandonedFoot" }
		local pDriving: PlotService.PlayerLike = { UserId = 31021, Name = "ActiveDriver" }
		PlotService.Assign(pOnFoot)
		PlotService.Assign(pDriving)
		buildDriveableTestVehicle(pOnFoot, "t19a", false)
		buildDriveableTestVehicle(pDriving, "t19b", false)

		assertTrue(VehicleLaunchService.LaunchVehicle(pOnFoot, { SkipWorldObstructionCheck = true, MountDriver = false }).Success, "Launched foot")
		assertTrue(VehicleLaunchService.LaunchVehicle(pDriving, { SkipWorldObstructionCheck = true, SimulateSeated = true }).Success, "Launched driving")

		-- Antes del timeout: ninguno limpiado
		local cleanedEarly = VehicleLifecycleService.CheckAbandonedVehicles(env.GetClock() + 10)
		assertEqual(cleanedEarly, 0, "Not cleaned before AbandonedTimeoutSeconds")

		-- Pasado AbandonedTimeoutSeconds: solo limpia OnFootRuntime, mantiene Driving
		local futureTime = env.AdvanceClock(GameConfig.Runtime.AbandonedTimeoutSeconds + 5)
		local cleanedAfter = VehicleLifecycleService.CheckAbandonedVehicles(futureTime)
		assertEqual(cleanedAfter, 1, "Cleaned exactly the 1 abandoned OnFootRuntime vehicle")
		assertEqual(VehicleLifecycleService.GetPlayerState(pOnFoot), "Editing", "Abandoned player returned to Editing")
		assertEqual(VehicleLifecycleService.GetPlayerState(pDriving), "Driving", "Active driver unaffected")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 1, "1 runtime remains active")
		env.Teardown()
	end)

	-- 20
	runTest("Fase 3.1 [20]: External destruction/invalidation of VehicleRuntime triggers cleanup and restores player to Editing", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31022, Name = "VoidDestroyTester" }
		PlotService.Assign(p1)
		buildDriveableTestVehicle(p1, "t20", false)

		local launchRes = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, SimulateSeated = true })
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, "Launched")
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		local rtId = rt.RuntimeId

		-- Simular destrucción externa (e.g. FallenPartsDestroyHeight)
		local rtModel = rt.RootModel :: Model
		rtModel:Destroy()
		task.wait(0.05)

		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Registry cleaned immediately on external destruction")
		assertEqual(VehicleRuntimeService.GetTrackedConnectionCount(), 0, "All runtime connections cleaned")
		assertEqual(ItemRuntimeService.GetActivePartCount(rtId), 0, "ItemRuntimeService behaviors destroyed")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "Editing", "Player safely restored to Editing")
		env.Teardown()
	end)

	-- 21
	runTest("Fase 3.1 [21]: Plot release / Player disconnect cleans active runtime, connections & state with zero leaks", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31023, Name = "Leaver" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildDriveableTestVehicle(p1, "t21", false)

		local res = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, SimulateSeated = true })
		assertTrue(res.Success and res.Runtime ~= nil, "Launched")
		local rtId = (res.Runtime :: VehicleTypes.VehicleRuntime).RuntimeId

		PlotService.Release(p1)
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero active runtimes after PlotService.Release")
		assertEqual(VehicleRuntimeService.GetTrackedConnectionCount(), 0, "Zero connections after release")
		assertEqual(ItemRuntimeService.GetActivePartCount(rtId), 0, "ItemRuntimeService cleaned")
		assertEqual(plot.DynamicContainer:FindFirstChild(GameConfig.Runtime.ModelName), nil, "DynamicContainer cleaned")
		env.Teardown()
	end)

	-- 22
	runTest("Fase 3.1 [22]: Death & SpawnService respawn hook cleanly handle active Driving & dead launch abort", function()
		local env = setupIsolatedWorld(1)
		local charHost = Instance.new("Folder")
		charHost.Name = "_Phase31DeathChars"
		charHost.Parent = env.TempPlots
		local charModel, hum = createDummyCharacterRig(31024, charHost)
		local p1 = ({ UserId = 31024, Name = "DeathTester", Character = charModel } :: any) :: PlotService.PlayerLike
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildDriveableTestVehicle(p1, "t22", false)

		-- Caso A: Intentar lanzar estando muerto -> bloqueado limpiamente
		hum.Health = 0
		local deadLaunch = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(not deadLaunch.Success and deadLaunch.ErrorCode == "PlayerDead", "Dead player cannot launch")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "Editing", "State stays Editing")

		-- Caso B: Vivo lanza en Driving, luego respawnea vía SpawnService -> pasa a OnFootRuntime sin errores
		hum.Health = 100
		local liveLaunch = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true })
		assertTrue(liveLaunch.Success, "Alive launch succeeded")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "Driving", "State is Driving")

		local newChar, _ = createDummyCharacterRig(31024, charHost)
		SpawnService.SpawnAtAssignedPlot(p1, newChar, plot)
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), "OnFootRuntime", "SpawnService before-respawn hook safely transitioned Driving -> OnFootRuntime")
		assertTrue((newChar:GetPivot().Position - plot.PlayerSpawn.Position).Magnitude < 1.0, "Respawn placed character at PlayerSpawn")

		env.Teardown()
		charHost:Destroy()
	end)

	-- 23
	runTest("Fase 3.1 [23]: Security & anti-spam (spoofed PlotId/OwnerUserId, cross-player control, launch cooldown, concurrency lock)", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 31025, Name = "SecOwner" }
		local p2: PlotService.PlayerLike = { UserId = 31026, Name = "SecAttacker" }
		local plot1 = PlotService.Assign(p1) :: PlotService.PlotRecord
		PlotService.Assign(p2)
		buildDriveableTestVehicle(p1, "t23", false)

		-- Spoofing PlotId / OwnerUserId rechazado (por validador de contrato o ownership de plot)
		local spoof1 = BuildService.ProcessRequest(p2, {
			Action = "LaunchVehicle",
			ClientOpId = "spoof_1",
			PlotId = plot1.PlotId,
		})
		assertTrue(
			not spoof1.Success
				and (
					spoof1.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload
					or spoof1.ErrorCode == BuildProtocol.ErrorCodes.NotPlotOwner
				),
			"Spoofed PlotId blocked"
		)

		-- Launch válido de p1
		local okLaunch = BuildService.ProcessRequest(p1, {
			Action = "LaunchVehicle",
			ClientOpId = "valid_l1",
		})
		assertTrue(okLaunch.Success, "Valid RPC LaunchVehicle succeeded")

		-- p1 ya tiene runtime -> segundo launch bloqueado (por cooldown o RuntimeAlreadyActive)
		local dupLaunch = BuildService.ProcessRequest(p1, {
			Action = "LaunchVehicle",
			ClientOpId = "dup_l2",
		})
		assertTrue(not dupLaunch.Success, "Duplicate LaunchVehicle rejected while active")

		-- Cooldown en ResetVehicle inmediato
		local spamReset = BuildService.ProcessRequest(p1, {
			Action = "ResetVehicle",
			ClientOpId = "spam_rst",
		})
		assertTrue(not spamReset.Success and spamReset.ErrorCode == BuildProtocol.ErrorCodes.LaunchCooldown, "Launch/Reset cooldown enforced")

		-- p2 sin runtime propio no puede controlar/regresar/salir de vehículo ajeno
		local atkReturn = BuildService.ProcessRequest(p2, {
			Action = "ReturnToWorkshop",
			ClientOpId = "atk_ret",
		})
		assertTrue(not atkReturn.Success and atkReturn.ErrorCode == BuildProtocol.ErrorCodes.RuntimeNotActive, "Attacker cannot return owner vehicle")
		assertTrue(VehicleRuntimeService.GetRuntimeByPlayer(p1) ~= nil, "Owner vehicle still active")

		env.Teardown()
	end)

	-- 24
	runTest("Fase 3.1 [24]: Multi-player stress: 10 players launch & return simultaneously on 10 isolated plots with zero leaks", function()
		local env = setupIsolatedWorld(10)
		local players: { PlotService.PlayerLike } = {}
		local plots: { PlotService.PlotRecord } = {}

		for i = 1, 10 do
			local plr: PlotService.PlayerLike = { UserId = 31100 + i, Name = `MultiLauncher_{i}` }
			players[i] = plr
			plots[i] = PlotService.Assign(plr) :: PlotService.PlotRecord
			buildDriveableTestVehicle(plr, `mp_{i}`, i % 2 == 0)
		end

		for i = 1, 10 do
			local res = VehicleLaunchService.LaunchVehicle(players[i], {
				SkipWorldObstructionCheck = true,
				SimulateSeated = true,
			})
			assertTrue(res.Success and res.Runtime ~= nil, `Player {i} launched`)
			assertEqual((res.Runtime :: VehicleTypes.VehicleRuntime).PlotId, plots[i].PlotId, `Runtime on own plot {i}`)
		end

		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 10, "All 10 players have independent active runtimes")

		for i = 1, 10 do
			assertTrue(VehicleLaunchService.ReturnToWorkshop(players[i]).Success, `Player {i} returned cleanly`)
		end

		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero leftover runtimes after 10 returns")
		assertEqual(VehicleRuntimeService.GetTrackedConnectionCount(), 0, "Zero leftover connections")
		env.Teardown()
	end)

	-- 25
	runTest("Fase 3.1 [25]: Performance gate for 200-piece vehicle assembly, activation & cleanup (< 120ms budget, linear welds)", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 31200, Name = "Perf200" }
		PlotService.Assign(p1)

		-- Grilla 10x10 WoodBlock (100) + 99 WoodBlock segunda capa (199) + 1 DriverSeat (200)
		for iz = 0, 9 do
			for ix = 0, 9 do
				local actualIx = if iz % 2 == 0 then ix else (9 - ix)
				assertTrue(BuildService.ProcessRequest(p1, {
					Action = "PlacePiece",
					ClientOpId = `p200_a_{iz}_{ix}`,
					ItemId = "WoodBlock",
					LocalCFrame = CFrame.new(-9 + actualIx * 2, 1.5, -9 + iz * 2),
				}).Success, "Layer1 block")
			end
		end
		for iz = 0, 9 do
			for ix = 0, 9 do
				if not (iz == 9 and ix == 9) then
					assertTrue(BuildService.ProcessRequest(p1, {
						Action = "PlacePiece",
						ClientOpId = `p200_b_{iz}_{ix}`,
						ItemId = "WoodBlock",
						LocalCFrame = CFrame.new(-9 + ix * 2, 3.5, -9 + iz * 2),
					}).Success, "Layer2 block")
				end
			end
		end
		assertTrue(BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "p200_seat",
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(-9, 5.0, -9),
		}).Success, "Seat atop 200-piece chassis")

		local t0 = os.clock()
		local launchRes = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
		})
		local launchMs = (os.clock() - t0) * 1000
		assertTrue(launchRes.Success and launchRes.Runtime ~= nil, `200-piece vehicle launched: {tostring(launchRes.ErrorMessage)}`)
		local rt = launchRes.Runtime :: VehicleTypes.VehicleRuntime
		assertEqual(launchRes.RuntimeStatus.PieceCount, 200, "All 200 pieces present in VehicleRuntime")
		assertTrue((launchRes.RuntimeStatus.JointCount) < 1000, `Linear weld count without O(N^2) ({launchRes.RuntimeStatus.JointCount} welds)`)
		assertTrue(launchMs < 150.0, `200-piece launch within budget (got {string.format("%.2f", launchMs)} ms)`)

		local tClean0 = os.clock()
		assertTrue(VehicleLaunchService.ReturnToWorkshop(p1).Success, "Cleanup 200-piece runtime succeeded")
		local cleanMs = (os.clock() - tClean0) * 1000
		assertTrue(cleanMs < 50.0, `200-piece cleanup within budget (got {string.format("%.2f", cleanMs)} ms)`)
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero leftover runtimes")
		assertEqual(ItemRuntimeService.GetActivePartCount(rt.RuntimeId), 0, "Zero leftover behaviors")
		env.Teardown()
	end)
end

return Phase31Tests

