--!strict
--[=[
	Phase42Tests
	Suite de pruebas automatizadas de Fase 4.2 (Desconexión estructural, Fragmentos/Escombros,
	Asientos autoritativos y Eliminación completa del Freno de Mano):
	- Configuración y alcances exactos de límites: 20 s de vida de escombros, 500 piezas/vehículo
	  y por runtime en escombros, y 1500 piezas de escombros globales del servidor (FIFO).
	- Eliminación total del freno de mano (GameConfig, protocolo/validador, controles y HUD).
	- Fragmentación estructural al alcanzar 0 HP: corte de aristas cruzadas, preservación de
	  WeldConstraints internos en cada fragmento (VehicleFragment) y colisión VehicleDebris.
	- Limpieza de ruedas, montajes, boosters, tanques de nitro, motores y tanques de combustible.
	- Destrucción de DriverSeat -> casco pasivo sin borrar vehículo; destrucción total -> IsDestroyed.
	- Protección autoritativa de asientos (bloqueo de Space / Jump / Sit=false ajeno, salida por
	  "Salir del asiento" + FindSafeExit + limpieza de cooldown y soporte multi-asiento).
	- Inmutabilidad estricta de Blueprints e Inventarios, prueba de 10 jugadores sin fugas (0/0/0/0)
	  y validación física real en Roblox Studio (cuando RunService:IsRunning() == true).
]=]

local HttpService = game:GetService("HttpService")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
local DamageConfig = require(ReplicatedStorage.Shared.Config.DamageConfig)
local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local DamageMath = require(ReplicatedStorage.Shared.Damage.DamageMath)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BuildPayloadValidator = require(ServerScriptService.Server.Security.BuildPayloadValidator)
local PlotService = require(ServerScriptService.Server.Services.PlotService)
local SpawnService = require(ServerScriptService.Server.Services.SpawnService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local BoosterInventoryService = require(ServerScriptService.Server.Services.BoosterInventoryService)
local WheelAutoConfigurationService = require(ServerScriptService.Server.Services.WheelAutoConfigurationService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local StandPreviewService = require(ServerScriptService.Server.Services.StandPreviewService)
local VehicleLaunchPreparationService = require(ServerScriptService.Server.Services.VehicleLaunchPreparationService)
local ItemRuntimeService = require(ServerScriptService.Server.Services.ItemRuntimeService)
local VehicleAssemblyService = require(ServerScriptService.Server.Services.VehicleAssemblyService)
local VehicleWheelControllerService = require(ServerScriptService.Server.Services.VehicleWheelControllerService)
local VehiclePowertrainService = require(ServerScriptService.Server.Services.VehiclePowertrainService)
local VehicleBoosterService = require(ServerScriptService.Server.Services.VehicleBoosterService)
local VehicleDamageService = require(ServerScriptService.Server.Services.VehicleDamageService)
local VehicleImpactService = require(ServerScriptService.Server.Services.VehicleImpactService)
local VehicleDestructionService = require(ServerScriptService.Server.Services.VehicleDestructionService)
local VehicleSeatService = require(ServerScriptService.Server.Services.VehicleSeatService)
local VehicleRuntimeService = require(ServerScriptService.Server.Services.VehicleRuntimeService)
local VehicleLifecycleService = require(ServerScriptService.Server.Services.VehicleLifecycleService)
local VehicleLaunchService = require(ServerScriptService.Server.Services.VehicleLaunchService)
local BuildService = require(ServerScriptService.Server.Services.BuildService)

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase42Tests = {}

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

local function assertNear(actual: number, expected: number, tol: number, msg: string)
	if math.abs(actual - expected) > tol then
		error(`{msg} (expected {expected} +- {tol}, got {actual})`, 2)
	end
end

local function setupIsolatedWorld(plotCount: number?, customPlotSpawns: Folder?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = customPlotSpawns or (Workspace:WaitForChild("PlotSpawns") :: Folder)
	local assets = ServerStorage:WaitForChild("ItemAssets")

	local prevPlots = Workspace:FindFirstChild("_Phase42TestPlots")
	if prevPlots then
		prevPlots:Destroy()
	end
	for _, tempName in { "_P42SeatGround", "_P42SeatSpawns", "_P42LiveGround", "_Phase42LiveSpawns" } do
		local existing = Workspace:FindFirstChild(tempName)
		if existing and existing ~= customPlotSpawns then
			existing:Destroy()
		end
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase42TestPlots"
	tempPlots.Parent = Workspace

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
	VehicleBlueprintService._ResetForTests()
	InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
	ConnectionService._ResetForTests()
	WheelAutoConfigurationService._ResetForTests()
	BoosterInventoryService.ResetAllForTests()
	EngineInventoryService.ResetAllForTests()
	SpawnService._ResetForTests()
	PlotService._ResetForTests()

	PlotService.Init({
		BaseTemplate = baseTemplate,
		PlotSpawnsFolder = plotSpawns,
		PlotsParent = tempPlots,
		PlotCount = plotCount or 2,
	})
	SpawnService.Init()
	InventoryService.Init()
	EngineInventoryService.Init()
	BoosterInventoryService.Init()
	WheelAutoConfigurationService.Init({ ItemAssetsRoot = assets })
	ConnectionService.Init({ ItemAssetsRoot = assets })
	VehicleAssemblyService.Init({ ItemAssetsRoot = assets })
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

	local virtualClock = 10000
	local rateClock = 10000
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

	return {
		TempPlots = tempPlots,
		Now = function(): number
			return virtualClock
		end,
		AdvanceClock = function(dt: number): number
			virtualClock += dt
			return virtualClock
		end,
		Teardown = function()
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
			VehicleBlueprintService._ResetForTests()
			InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = false })
			ConnectionService._ResetForTests()
			WheelAutoConfigurationService._ResetForTests()
			BoosterInventoryService.ResetAllForTests()
			EngineInventoryService.ResetAllForTests()
			SpawnService._ResetForTests()
			PlotService._ResetForTests()
			tempPlots:Destroy()
		end,
	}
end

local function placePieceReq(
	player: PlotService.PlayerLike,
	opId: string,
	itemId: string,
	localCF: CFrame,
	config: { [string]: any }?,
	inventoryUnitId: string?
): string
	local res = BuildService.ProcessRequest(player, {
		Action = BuildProtocol.Actions.PlacePiece,
		ClientOpId = opId,
		ItemId = itemId,
		LocalCFrame = localCF,
		Config = config,
		InventoryInstanceId = inventoryUnitId,
	})
	assertTrue(
		res.Success and res.PlacedPiece ~= nil,
		`PlacePiece failed ({itemId}): {tostring(res.ErrorCode)} - {tostring(res.ErrorMessage)}`
	)
	return (res.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId
end

local function buildLinearTestVehicle(
	player: PlotService.PlayerLike,
	prefix: string,
	options: {
		IncludeEngine: boolean?,
		EngineUnitId: string?,
		IncludeFuelTank: boolean?,
		IncludeBooster: boolean?,
		BoosterUnitId: string?,
		IncludeNitroTank: boolean?,
		IncludeWheels: boolean?,
	}?
)
	local opts = options or {}
	local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)

	-- Cadena lineal Z: [-4] Front -> [-2] SeatFrame -> [0] Mid -> [2] EngFrame -> [4] Rear -> [6] Tail
	local frontBumperId = placePieceReq(player, `{prefix}_b_front`, "WoodBlock", CFrame.new(0, 2.5, -4))
	local seatFrameId = placePieceReq(player, `{prefix}_b_seat`, "WoodBlock", CFrame.new(0, 2.5, -2))
	local midFrameId = placePieceReq(player, `{prefix}_b_mid`, "WoodBlock", CFrame.new(0, 2.5, 0))
	local engFrameId = placePieceReq(player, `{prefix}_b_eng`, "WoodBlock", CFrame.new(0, 2.5, 2))
	local rearFrameId = placePieceReq(player, `{prefix}_b_rear`, "WoodBlock", CFrame.new(0, 2.5, 4))
	local tailFrameId = placePieceReq(player, `{prefix}_b_tail`, "WoodBlock", CFrame.new(0, 2.5, 6))

	local seatId = placePieceReq(player, `{prefix}_seat`, "DriverSeat", CFrame.new(0, 4.0, -2))

	local engineId: string? = nil
	if opts.IncludeEngine then
		engineId = placePieceReq(player, `{prefix}_eng`, "SmallEngine", CFrame.new(0, 4.5, 2), nil, opts.EngineUnitId)
	end

	local fuelTankId: string? = nil
	if opts.IncludeFuelTank then
		fuelTankId = placePieceReq(player, `{prefix}_fuel`, "RegularFuelTank", CFrame.new(0, 4.5, 5))
	end

	local nitroTankId: string? = nil
	if opts.IncludeNitroTank then
		nitroTankId = placePieceReq(player, `{prefix}_nitro`, "SmallNitroTank", CFrame.new(2, 2.5, 2))
	end

	local boosterId: string? = nil
	if opts.IncludeBooster then
		boosterId = placePieceReq(player, `{prefix}_bst`, "SmallBooster", CFrame.new(0, 2.5, 8.5), nil, opts.BoosterUnitId)
	end

	local wheelIds: { string } = {}
	if opts.IncludeWheels ~= false then
		table.insert(wheelIds, placePieceReq(player, `{prefix}_wfl`, "SmallWheel", CFrame.new(-1.5, 2.5, -2)))
		table.insert(wheelIds, placePieceReq(player, `{prefix}_wfr`, "SmallWheel", CFrame.new(1.5, 2.5, -2) * wheelFlip))
		table.insert(wheelIds, placePieceReq(player, `{prefix}_wrl`, "SmallWheel", CFrame.new(-1.5, 2.5, 6)))
		table.insert(wheelIds, placePieceReq(player, `{prefix}_wrr`, "SmallWheel", CFrame.new(1.5, 2.5, 6) * wheelFlip))
	end

	return {
		FrontBumperId = frontBumperId,
		SeatFrameId = seatFrameId,
		MidFrameId = midFrameId,
		EngFrameId = engFrameId,
		RearFrameId = rearFrameId,
		TailFrameId = tailFrameId,
		SeatId = seatId,
		EngineId = engineId,
		FuelTankId = fuelTankId,
		NitroTankId = nitroTankId,
		BoosterId = boosterId,
		WheelIds = wheelIds,
	}
end

local function createDummyRig(name: string, position: Vector3): (Model, Humanoid)
	local model = Instance.new("Model")
	model.Name = name

	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.CFrame = CFrame.new(position)
	hrp.Anchored = false
	hrp.CanCollide = true
	hrp.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.CFrame = CFrame.new(position)
	torso.CanCollide = false
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.5, 1.5, 1.5)
	head.CFrame = CFrame.new(position + Vector3.new(0, 1.75, 0))
	head.CanCollide = false
	head.Parent = model

	local w1 = Instance.new("WeldConstraint")
	w1.Part0 = hrp
	w1.Part1 = torso
	w1.Parent = hrp

	local w2 = Instance.new("WeldConstraint")
	w2.Part0 = hrp
	w2.Part1 = head
	w2.Parent = hrp

	local hum = Instance.new("Humanoid")
	hum.Name = "Humanoid"
	hum.Parent = model

	model.PrimaryPart = hrp
	model.Parent = Workspace
	return model, hum
end

local function countFragmentsInDynamic(plot: PlotService.PlotRecord): { Model }
	local out: { Model } = {}
	for _, child in ipairs(plot.DynamicContainer:GetChildren()) do
		if child:IsA("Model") and child.Name == "VehicleFragment" and child:GetAttribute("VehicleDebris") == true then
			table.insert(out, child)
		end
	end
	return out
end

function Phase42Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (name: string, fn: () -> ()) -> ()
)
	local _ = results

	-- 01) DestructionConfig & GameConfig exact limits scope
	runTest("Fase 4.2 [01]: DestructionConfig defines 20s TTL, 500 per-runtime & 1500 server debris caps, aligned with 500 pieces/vehicle", function()
		assertEqual(DestructionConfig.DebrisLifetimeSeconds, 20, "DebrisLifetimeSeconds == 20")
		assertEqual(DestructionConfig.MaxDebrisPiecesPerRuntime, 500, "MaxDebrisPiecesPerRuntime == 500")
		assertEqual(DestructionConfig.MaxDebrisPiecesServer, 1500, "MaxDebrisPiecesServer == 1500")
		assertEqual(DestructionConfig.DebrisCollisionGroup, "VehicleDebris", "DebrisCollisionGroup == VehicleDebris")
		assertEqual(GameConfig.Building.MaxPiecesPerVehicle, 500, "GameConfig.Building.MaxPiecesPerVehicle == 500")
	end)

	-- 02) Complete Handbrake removal + Space jump blocking + "Salir del asiento" preserved
	runTest("Fase 4.2 [02]: Handbrake completely removed across config, protocol, HUD & controls; Space blocked and Exit button preserved", function()
		assertEqual((GameConfig.Powertrain :: any).HandbrakeTorquePerWheel, nil, "HandbrakeTorquePerWheel removed")

		local okVal, _, errCode = BuildPayloadValidator.ValidateRequest({
			Action = BuildProtocol.Actions.SetDrivingInput,
			ClientOpId = "p42_hb",
			Throttle = 1,
			Handbrake = true,
		} :: any, 42002, nil)
		assertEqual(okVal, false, "SetDrivingInput rejects legacy Handbrake")
		assertEqual(errCode, BuildProtocol.ErrorCodes.InvalidPayload, "InvalidPayload returned on Handbrake")

		local clientControllers = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
		local driveSrc = (clientControllers:WaitForChild("VehicleDrivingController") :: ModuleScript).Source
		local seatCtrlSrc = (clientControllers:WaitForChild("VehicleSeatController") :: ModuleScript).Source
		local mgmtSrc = (clientControllers:WaitForChild("VehicleManagement") :: LocalScript).Source

		assertEqual(string.find(driveSrc, "Handbrake", 1, true), nil, "No Handbrake identifier in VehicleDrivingController")
		assertEqual(string.find(driveSrc, "Enum.KeyCode.Space", 1, true), nil, "No Space keybinding in VehicleDrivingController")
		assertTrue(string.find(seatCtrlSrc, "CharacterJump", 1, true) ~= nil, "VehicleSeatController sinks CharacterJump")
		assertTrue(string.find(seatCtrlSrc, "Enum.KeyCode.Space", 1, true) ~= nil, "VehicleSeatController sinks Space")
		assertTrue(string.find(seatCtrlSrc, "Enum.KeyCode.ButtonA", 1, true) ~= nil, "VehicleSeatController sinks ButtonA")
		assertTrue(string.find(seatCtrlSrc, "Enum.HumanoidStateType.Jumping", 1, true) ~= nil, "VehicleSeatController disables Jumping state")
		assertTrue(string.find(mgmtSrc, "Salir del asiento", 1, true) ~= nil, "Salir del asiento button preserved in HUD")
		assertTrue(string.find(mgmtSrc, "VehicleSeatController.IsSeated()", 1, true) ~= nil, "HUD checks VehicleSeatController.IsSeated()")
	end)

	-- 03) Single-piece 0 HP detachment -> VehicleFragment, cross-weld cut, VehicleDebris setup & velocity inheritance
	runTest("Fase 4.2 [03]: Single piece hitting 0 HP detaches into VehicleFragment with VehicleDebris group and cuts cross-welds", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42003, Name = "P42_SingleDetach" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local ids = buildLinearTestVehicle(p1, "d03", { IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch succeeded")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		local frontPart = rt.Parts[ids.FrontBumperId].PrimaryPart :: BasePart
		local seatPart = rt.Parts[ids.SeatFrameId].PrimaryPart :: BasePart
		frontPart.AssemblyLinearVelocity = Vector3.new(0, 0, -25)

		local frontBridgeWeldCount = 0
		for _, joint in ipairs(rt.Joints) do
			if joint:IsA("WeldConstraint") and ((joint.Part0 == frontPart and joint.Part1 == seatPart) or (joint.Part1 == frontPart and joint.Part0 == seatPart)) then
				frontBridgeWeldCount += 1
			end
		end
		assertTrue(frontBridgeWeldCount >= 1, "Bridge weld existed between FrontBumper and SeatFrame before 0 HP")

		local res = VehicleDamageService.ApplyImpact(rt, ids.FrontBumperId, {
			DamageAmount = 100,
			Timestamp = env.AdvanceClock(1),
		})
		assertTrue(res.Applied and table.find(res.BrokenParts, ids.FrontBumperId) ~= nil, "FrontBumper reached 0 HP")
		assertTrue(table.find(res.DetachedParts, ids.FrontBumperId) ~= nil, "FrontBumper included in DetachedParts")

		local partState = rt.Parts[ids.FrontBumperId]
		assertEqual(partState.IsDetached, true, "FrontBumper IsDetached == true")
		assertEqual(partState.IsDestroyed, true, "FrontBumper IsDestroyed == true")
		assertEqual(partState.IsFunctional, false, "FrontBumper IsFunctional == false")

		local fragments = countFragmentsInDynamic(plot)
		assertEqual(#fragments, 1, "Exactly 1 VehicleFragment created")
		local frag = fragments[1]
		assertEqual(frag:GetAttribute("OwnerUserId"), p1.UserId, "Fragment tracks OwnerUserId")
		assertEqual(frag:GetAttribute("RuntimeId"), rt.RuntimeId, "Fragment tracks RuntimeId")
		assertTrue((partState.ModelInstance :: Model):IsDescendantOf(frag), "Detached model reparented inside VehicleFragment")
		assertEqual(frontPart.CollisionGroup, DestructionConfig.DebrisCollisionGroup, "Debris assigned VehicleDebris collision group")
		assertEqual(frontPart.CanTouch, false, "Debris CanTouch disabled")
		assertEqual(frontPart.Anchored, false, "Debris remains unanchored")
		assertNear(frontPart.AssemblyLinearVelocity.Z, -25, 0.5, "Debris preserves pre-detachment velocity")
		assertEqual(PhysicsService:CollisionGroupsAreCollidable(DestructionConfig.DebrisCollisionGroup, "VehicleRuntime"), false, "Debris does not collide with VehicleRuntime")
		assertEqual(PhysicsService:CollisionGroupsAreCollidable(DestructionConfig.DebrisCollisionGroup, "VehicleDebris"), false, "Debris does not collide with Debris")
		assertEqual(#((rt.PieceAdjacencyById or {})[ids.FrontBumperId] or {}), 0, "Adjacency cleared for detached piece")

		-- Verificar que el puente Front<->SeatFrame fue destruido mientras el chasis restante conserva sus welds
		local remainingJoints = 0
		for _, joint in ipairs(rt.Joints) do
			assertTrue(joint.Parent ~= nil, "Remaining rt.Joints only holds live parented welds")
			remainingJoints += 1
		end
		assertTrue(remainingJoints >= 4, "Surviving main chassis keeps structural welds")
		assertEqual(VehicleDestructionService.GetStats().Pieces, 1, "Stats tracks 1 debris piece")

		VehicleLaunchService.ReturnToWorkshop(p1)
		assertEqual(VehicleDestructionService.GetStats().Fragments, 0, "ReturnToWorkshop clears fragments")
		env.Teardown()
	end)

	-- 04) Structural BFS split keeps internal fragment WeldConstraints intact while cutting bridges
	runTest("Fase 4.2 [04]: Structural BFS split preserves internal WeldConstraints inside separated VehicleFragment", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42004, Name = "P42_BFSSplit" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local ids = buildLinearTestVehicle(p1, "d04", {
			IncludeEngine = true,
			IncludeFuelTank = true,
			IncludeBooster = true,
			IncludeWheels = true,
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		-- Romper MidFrame (Z=0): corta SeatFrame[-2] <-> MidFrame[0] <-> EngFrame[2]
		-- El subgrafo trasero completo (EngFrame, Engine, RearFrame, FuelTank, TailFrame, Booster, WRL, WRR) debe separarse unido en un VehicleFragment
		local res = VehicleDamageService.ApplyImpact(rt, ids.MidFrameId, {
			DamageAmount = 100,
			Timestamp = env.AdvanceClock(1),
		})
		assertTrue(res.Applied, "MidFrame impact applied")
		assertTrue(table.find(res.DetachedParts, ids.MidFrameId) ~= nil, "MidFrame detached")
		assertTrue(table.find(res.DetachedParts, ids.EngFrameId) ~= nil, "EngFrame split cleanly")
		assertTrue(table.find(res.DetachedParts, ids.TailFrameId) ~= nil, "TailFrame split cleanly")
		assertTrue(table.find(res.DetachedParts, ids.EngineId :: string) ~= nil, "Engine split cleanly with rear block")
		assertTrue(table.find(res.DetachedParts, ids.BoosterId :: string) ~= nil, "Booster split cleanly with rear block")

		-- Delantero sigue vivo
		assertEqual(rt.Parts[ids.SeatId].IsDetached, false, "DriverSeat survives in main chassis")
		assertEqual(rt.Parts[ids.FrontBumperId].IsDetached, false, "FrontBumper survives in main chassis")

		-- Mitad trasera no recibió daño destructivo directo (IsDestroyed=false, IsDetached=true)
		assertEqual(rt.Parts[ids.MidFrameId].IsDestroyed, true, "Broken MidFrame has IsDestroyed == true")
		assertEqual(rt.Parts[ids.TailFrameId].IsDestroyed, false, "Separated intact TailFrame has IsDestroyed == false")
		assertEqual(rt.Parts[ids.TailFrameId].IsFunctional, false, "Separated intact TailFrame becomes IsFunctional == false")

		local fragments = countFragmentsInDynamic(plot)
		assertEqual(#fragments, 2, "Expect 2 fragments: [1 broken MidFrame] + [1 connected Rear Assembly]")

		local rearFrag: Model? = nil
		for _, frag in ipairs(fragments) do
			if (rt.Parts[ids.TailFrameId].ModelInstance :: Model):IsDescendantOf(frag) then
				rearFrag = frag
				break
			end
		end
		assertTrue(rearFrag ~= nil, "Found multi-piece Rear VehicleFragment")
		assertTrue((rt.Parts[ids.EngFrameId].ModelInstance :: Model):IsDescendantOf(rearFrag :: Model), "EngFrame and TailFrame share same VehicleFragment")
		assertTrue((rt.Parts[ids.FuelTankId :: string].ModelInstance :: Model):IsDescendantOf(rearFrag :: Model), "FuelTank shares same VehicleFragment")

		-- Contar WeldConstraints internos vivos dentro del fragmento trasero
		local internalWelds = 0
		for _, desc in ipairs((rearFrag :: Model):GetDescendants()) do
			if desc:IsA("WeldConstraint") and desc.Enabled and desc.Part0 and desc.Part1 then
				if desc.Part0:IsDescendantOf(rearFrag :: Model) and desc.Part1:IsDescendantOf(rearFrag :: Model) then
					internalWelds += 1
				end
			end
		end
		assertTrue(internalWelds >= 4, `Internal WeldConstraints preserved inside rear VehicleFragment (got {internalWelds})`)
		env.Teardown()
	end)

	-- 05) Direct wheel break & mount structural split clean up WheelController & HingeConstraints
	runTest("Fase 4.2 [05]: Destroying a wheel or wheel-mount chassis disables HingeConstraints and zeroes WheelController state", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42005, Name = "P42_Wheels" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local ids = buildLinearTestVehicle(p1, "d05", { IncludeEngine = true, IncludeFuelTank = true, IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1, Steer = 1 })
		for _ = 1, 3 do
			VehiclePowertrainService.StepAll(1 / 60)
			VehicleWheelControllerService.StepAll(1 / 60)
		end

		-- A) Golpe directo a rueda trasera izquierda (WRL)
		local wrlId = ids.WheelIds[3]
		local wrlStateBefore = VehicleWheelControllerService.GetWheelState(p1, wrlId)
		assertTrue(wrlStateBefore ~= nil, "WRL runtime wheel exists")
		local wrlMech = (rt.WheelMechanisms or {})[wrlId]

		local resW = VehicleDamageService.ApplyImpact(rt, wrlId, { DamageAmount = 150, Timestamp = env.AdvanceClock(1) })
		assertTrue(table.find(resW.DetachedParts, wrlId) ~= nil, "Direct 0 HP wheel detached")
		if wrlMech and wrlMech.AxleHinge then
			assertEqual(wrlMech.AxleHinge.ActuatorType, Enum.ActuatorType.None, "Detached wheel AxleHinge deactivated")
			assertEqual(wrlMech.AxleHinge.MotorMaxTorque, 0, "Detached wheel MotorMaxTorque == 0")
		end
		if wrlMech and wrlMech.SteeringHinge then
			assertEqual(wrlMech.SteeringHinge.ActuatorType, Enum.ActuatorType.None, "Detached wheel SteeringHinge deactivated")
			assertEqual(wrlMech.SteeringHinge.ServoMaxTorque, 0, "Detached wheel ServoMaxTorque == 0")
		end
		assertEqual(VehicleWheelControllerService.GetWheelState(p1, wrlId), nil, "Detached wheel cleared from WheelController")

		-- B) Romper RearFrame para desprender el soporte del eje trasero derecho (WRR)
		local wrrId = ids.WheelIds[4]
		local wrrMech = (rt.WheelMechanisms or {})[wrrId]
		VehicleDamageService.ApplyImpact(rt, ids.RearFrameId, { DamageAmount = 100, Timestamp = env.AdvanceClock(1) })
		assertEqual(rt.Parts[wrrId].IsDetached, true, "WRR detaches when RearFrame splits")
		assertEqual(rt.Parts[wrrId].IsDestroyed, false, "Split intact WRR stays IsDestroyed == false")
		assertEqual(VehicleWheelControllerService.GetWheelState(p1, wrrId), nil, "Split WRR cleared from WheelController")

		local frags = countFragmentsInDynamic(plot)
		local wrrModel = rt.Parts[wrrId].ModelInstance :: Model
		local wrrFrag: Model? = nil
		for _, f in ipairs(frags) do
			if wrrModel:IsDescendantOf(f) then
				wrrFrag = f
				break
			end
		end
		assertTrue(wrrFrag ~= nil, "Split WRR resides in a VehicleFragment")
		if wrrMech and wrrMech.CarrierPart then
			assertTrue(wrrMech.CarrierPart:IsDescendantOf(wrrFrag :: Model), "WRR CarrierPart travels with split fragment")
		end

		-- Rueda delantera izquierda intacta sigue operando
		VehiclePowertrainService.StepAll(1 / 60)
		VehicleWheelControllerService.StepAll(1 / 60)
		assertTrue(VehicleWheelControllerService.GetWheelState(p1, ids.WheelIds[1]) ~= nil, "Surviving front wheel remains active")
		env.Teardown()
	end)

	-- 06) Booster & NitroTank detachment immediately cuts VectorForce and BS_* telemetry
	runTest("Fase 4.2 [06]: Destroying Booster or NitroTank cuts VectorForce and immediately updates BS_* telemetry", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42006, Name = "P42_Boosters" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "d06", {
			IncludeBooster = true,
			IncludeNitroTank = true,
			IncludeWheels = true,
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local root = rt.RootModel :: Model
		env.AdvanceClock(2.0)

		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		for _ = 1, 10 do
			VehicleBoosterService.StepAll(0.05)
		end
		assertTrue((root:GetAttribute("BS_TotalAppliedThrust") or 0) > 0, "Booster actively producing thrust before destruction")

		local boosterPart = rt.Parts[ids.BoosterId :: string].PrimaryPart :: BasePart
		VehicleDamageService.ApplyImpact(rt, ids.BoosterId :: string, { DamageAmount = 150, Timestamp = env.AdvanceClock(1) })

		-- Inmediato sin esperar otro StepAll
		assertEqual(root:GetAttribute("BS_TotalAppliedThrust"), 0, "BS_TotalAppliedThrust flushed to 0 immediately on Booster 0 HP")
		assertEqual(root:GetAttribute("BS_MaxPossibleThrust"), 0, "BS_MaxPossibleThrust flushed to 0 immediately")
		assertEqual(root:GetAttribute("BS_ActiveBoosterCount"), 0, "BS_ActiveBoosterCount flushed to 0")
		for _, desc in ipairs(boosterPart:GetDescendants()) do
			if desc:IsA("VectorForce") then
				assertTrue(not desc.Enabled or desc.Force.Magnitude == 0, "Detached VectorForce disabled/zeroed")
			end
		end

		VehicleDamageService.ApplyImpact(rt, ids.NitroTankId :: string, { DamageAmount = 480, Timestamp = env.AdvanceClock(1) })
		assertEqual(root:GetAttribute("BS_TotalNitroCapacity"), 0, "BS_TotalNitroCapacity drops to 0 immediately on NitroTank 0 HP")
		assertEqual(root:GetAttribute("BS_AvailableNitro"), 0, "BS_AvailableNitro drops to 0 immediately")
		env.Teardown()
	end)

	-- 07) Engine & FuelTank detachment updates Powertrain & PT_* telemetry immediately
	runTest("Fase 4.2 [07]: Destroying Engine or FuelTank cuts Powertrain torque and immediately updates PT_* telemetry", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 420071, Name = "P42_Engine" }
		local p2: PlotService.PlayerLike = { UserId = 420072, Name = "P42_Fuel" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)

		local ids1 = buildLinearTestVehicle(p1, "d07a", { IncludeEngine = true, IncludeFuelTank = true, IncludeWheels = true })
		local lr1 = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		local rt1 = lr1.Runtime :: VehicleTypes.VehicleRuntime
		local root1 = rt1.RootModel :: Model

		local ids2 = buildLinearTestVehicle(p2, "d07b", { IncludeEngine = true, IncludeFuelTank = true, IncludeWheels = true })
		local lr2 = VehicleLaunchService.LaunchVehicle(p2, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		local rt2 = lr2.Runtime :: VehicleTypes.VehicleRuntime
		local root2 = rt2.RootModel :: Model

		env.AdvanceClock(2.0)
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1 })
		VehiclePowertrainService.SetControlOverrideForTests(p2, { Throttle = 1 })
		for _ = 1, 5 do
			VehiclePowertrainService.StepAll(1 / 60)
		end
		assertTrue((root1:GetAttribute("PT_TotalEngineTorque") or 0) > 0, "P1 produces drive torque initially")
		assertTrue((root2:GetAttribute("PT_AvailableFuel") or 0) > 0.1, "P2 has fuel initially")

		-- Romper motor en P1
		VehicleDamageService.ApplyImpact(rt1, ids1.EngineId :: string, { DamageAmount = 250, Timestamp = env.AdvanceClock(1) })
		assertEqual(root1:GetAttribute("PT_EngineCount"), 0, "PT_EngineCount drops to 0 immediately")
		assertEqual(root1:GetAttribute("PT_FunctionalEngineCount"), 0, "PT_FunctionalEngineCount drops to 0 immediately")
		assertEqual(root1:GetAttribute("PT_TotalEngineTorque"), 0, "PT_TotalEngineTorque drops to 0 immediately")

		-- Romper tanque en P2 (SmallEngine conserva 0.54 de combustible integrado; la capacidad y combustible del tanque 1.5 desaparecen inmediatamente)
		local capBefore = root2:GetAttribute("PT_TotalFuelCapacity") :: number
		local fuelBefore = root2:GetAttribute("PT_AvailableFuel") :: number
		assertNear(capBefore, 2.04, 1e-3, "Initial capacity equals tank (1.5) + integrated engine reserve (0.54)")
		VehicleDamageService.ApplyImpact(rt2, ids2.FuelTankId :: string, { DamageAmount = 250, Timestamp = env.AdvanceClock(1) })
		assertNear(root2:GetAttribute("PT_TotalFuelCapacity") :: number, 0.54, 1e-3, "PT_TotalFuelCapacity drops tank 1.50 immediately on 0 HP")
		assertNear(root2:GetAttribute("PT_AvailableFuel") :: number, math.max(0, fuelBefore - 1.5), 2e-2, "PT_AvailableFuel drops tank fuel immediately on 0 HP")
		VehiclePowertrainService.SetFuelLevelForTests(p2, 0.002)
		for _ = 1, 25 do
			VehiclePowertrainService.StepAll(0.25)
			if root2:GetAttribute("PT_OutOfFuel") == true then
				break
			end
		end
		assertEqual(root2:GetAttribute("PT_AvailableFuel"), 0, "Remaining integrated reserve depletes cleanly to 0")
		assertEqual(root2:GetAttribute("PT_OutOfFuel"), true, "PT_OutOfFuel switches true once integrated reserve empties")
		VehiclePowertrainService.StepAll(1 / 60)
		assertEqual(root2:GetAttribute("PT_TotalEngineTorque"), 0, "Zero fuel produces 0 drive torque on StepAll")
		env.Teardown()
	end)

	-- 08) Destroying DriverSeat produces passive surviving hull without destroying VehicleRuntime
	runTest("Fase 4.2 [08]: Destroying DriverSeat yields passive surviving hull without invalidating VehicleRuntime", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42008, Name = "P42_NoSeat" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "d08", { IncludeEngine = true, IncludeFuelTank = true, IncludeBooster = true, IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local root = rt.RootModel :: Model
		local seatPart = rt.DriverSeatPart :: VehicleSeat
		env.AdvanceClock(2.0)

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1, Steer = 1 })
		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		VehiclePowertrainService.StepAll(1 / 60)
		VehicleBoosterService.StepAll(1 / 60)
		VehicleWheelControllerService.StepAll(1 / 60)

		VehicleDamageService.ApplyImpact(rt, ids.SeatId, { DamageAmount = 500, SkipDistribution = true, Timestamp = env.AdvanceClock(1) })

		assertEqual(rt.DriverSeatDestroyed, true, "DriverSeatDestroyed flagged true")
		assertEqual(rt.DriverSeatPart, nil, "DriverSeatPart cleared to nil")
		assertTrue(not rt.IsDestroyed, "VehicleRuntime remains non-destroyed passive hull")
		assertEqual(root:GetAttribute("DriverSeatDestroyed"), true, "DriverSeatDestroyed attribute synced")
		assertEqual(seatPart.Disabled, true, "Detached DriverSeat disabled")
		assertEqual(seatPart:GetAttribute("ManagedVehicleSeat"), false, "ManagedVehicleSeat disabled")
		assertEqual(VehicleRuntimeService.GetRuntimeByPlayer(p1), rt, "Runtime remains registered cleanly")
		assertTrue(rt.PrimaryPart ~= nil and rt.PrimaryPart.Parent ~= nil, "Passive hull reassigned valid PrimaryPart")

		-- Controles completamente cortados tras perder DriverSeat
		VehiclePowertrainService.StepAll(1 / 60)
		VehicleBoosterService.StepAll(1 / 60)
		VehicleWheelControllerService.StepAll(1 / 60)
		assertEqual(root:GetAttribute("BS_TotalAppliedThrust"), 0, "Booster cut on DriverSeatDestroyed")
		assertEqual(root:GetAttribute("PT_TotalEngineTorque"), 0, "Powertrain torque cut on DriverSeatDestroyed")
		local flSt = VehicleWheelControllerService.GetWheelState(p1, ids.WheelIds[1]) :: VehicleTypes.WheelRuntimeState
		assertNear(flSt.TargetSteeringAngle, 0, 1e-4, "Steering reset to 0 on DriverSeatDestroyed")

		assertTrue(VehicleLaunchService.ReturnToWorkshop(p1).Success, "ReturnToWorkshop cleans passive hull")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero leftover runtimes")
		env.Teardown()
	end)

	-- 09) All pieces reaching 0 HP (#groups == 0) marks rt.IsDestroyed cleanly and StepAll does not error
	runTest("Fase 4.2 [09]: Full destruction leaving zero surviving groups sets IsDestroyed and safely cuts all loops", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 42009, Name = "P42_TotalWipe" }
		PlotService.Assign(p1)

		local baseId = placePieceReq(p1, "wipe_b", "WoodBlock", CFrame.new(0, 2.5, 0))
		local seatId = placePieceReq(p1, "wipe_s", "DriverSeat", CFrame.new(0, 4.0, 0))
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local root = rt.RootModel :: Model
		env.AdvanceClock(2.0)

		VehicleDamageService.ApplyImpact(rt, baseId, { DamageAmount = 100, Timestamp = env.AdvanceClock(1) })
		assertTrue(not rt.IsDestroyed, "Seat still intact -> not total wipe yet")
		VehicleDamageService.ApplyImpact(rt, seatId, { DamageAmount = 500, Timestamp = env.AdvanceClock(1) })

		assertEqual(rt.IsDestroyed, true, "Zero remaining groups sets rt.IsDestroyed == true")
		assertEqual(rt.DriverSeatDestroyed, true, "DriverSeatDestroyed true")
		assertEqual(root:GetAttribute("IsDestroyed"), true, "IsDestroyed root attribute true")
		assertEqual(rt.PrimaryPart, nil, "PrimaryPart cleared on #groups == 0")

		VehiclePowertrainService.StepAll(1 / 60)
		VehicleBoosterService.StepAll(1 / 60)
		VehicleWheelControllerService.StepAll(1 / 60)
		env.Teardown()
	end)

	-- 10) Authoritative seat guard (Sit=false / Jump=true blocked), thief cooldown clear, multi-seat & safe exit
	runTest("Fase 4.2 [10]: VehicleSeatService blocks unwanted exit/Jump, clears cooldown, handles passenger Seat detach and safe Exit", function()
		local customSpawns = Instance.new("Folder")
		customSpawns.Name = "_P42SeatSpawns"
		customSpawns.Parent = Workspace
		local sp = Instance.new("Part")
		sp.Name = "Plot_S01"
		sp.Anchored = true
		sp.CanCollide = false
		sp.CanTouch = false
		sp.CanQuery = false
		sp.Transparency = 1
		sp.Position = Vector3.new(1800, 50, 0)
		sp.Parent = customSpawns

		local ground = Instance.new("Part")
		ground.Name = "_P42SeatGround"
		ground.Anchored = true
		ground.CanCollide = true
		ground.Size = Vector3.new(240, 4, 240)
		ground.Position = Vector3.new(1800, 46, 0)
		ground.Parent = Workspace

		local env = setupIsolatedWorld(1, customSpawns)
		local p1: PlotService.PlayerLike = { UserId = 42010, Name = "P42_SeatOwner" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "d10", { IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local dSeat = rt.DriverSeatPart :: VehicleSeat

		-- Anexar un asiento adicional de pasajero soldado sobre TailFrame y registrar
		local tailPart = rt.Parts[ids.TailFrameId]
		local passSeat = Instance.new("Seat")
		passSeat.Name = "PassengerSeat"
		passSeat.Size = Vector3.new(2, 1, 2)
		passSeat.CFrame = (tailPart.PrimaryPart :: BasePart).CFrame * CFrame.new(0, 1.5, 0)
		passSeat.Parent = tailPart.ModelInstance
		local passWeld = Instance.new("WeldConstraint")
		passWeld.Part0 = tailPart.PrimaryPart
		passWeld.Part1 = passSeat
		passWeld.Parent = passSeat
		VehicleSeatService.RegisterRuntime(rt)

		assertEqual(dSeat:GetAttribute("ManagedVehicleSeat"), true, "DriverSeat marked ManagedVehicleSeat")
		assertEqual(passSeat:GetAttribute("ManagedVehicleSeat"), true, "PassengerSeat marked ManagedVehicleSeat")

		local ownerChar, ownerHum = createDummyRig("OwnerChar", dSeat.Position + Vector3.new(0, 4, 0))
		p1.Character = ownerChar
		local passChar, passHum = createDummyRig("PassChar", passSeat.Position + Vector3.new(0, 4, 0))
		local thiefChar, thiefHum = createDummyRig("ThiefChar", dSeat.Position + Vector3.new(0, 8, 0))

		dSeat:Sit(ownerHum)
		passSeat:Sit(passHum)
		task.wait()
		assertEqual(dSeat.Occupant, ownerHum, "Owner seated in DriverSeat")
		assertEqual(passSeat.Occupant, passHum, "Passenger seated in PassengerSeat")
		assertEqual(ownerHum:GetStateEnabled(Enum.HumanoidStateType.Jumping), false, "Owner Jumping disabled while seated")
		assertEqual(passHum:GetStateEnabled(Enum.HumanoidStateType.Jumping), false, "Passenger Jumping disabled while seated")

		-- Simular intento de bypass (Jump = true o Sit = false directo en Humanoid)
		ownerHum.Jump = true
		ownerHum.Sit = false
		passHum.Sit = false
		task.wait()
		assertEqual(ownerHum.Jump, false, "Owner Hum.Jump blocked immediately")
		assertEqual(dSeat.Occupant, ownerHum, "Owner Hum.Sit=false blocked; re-seated automatically")
		assertEqual(passSeat.Occupant, passHum, "Passenger Hum.Sit=false blocked; stays seated")

		-- Verificar expulsión de pasajero al desprenderse su asiento sin afectar al conductor
		VehicleSeatService.DetachSeat(passSeat)
		task.wait()
		assertEqual(passSeat.Occupant, nil, "Passenger ejected when PassengerSeat detached")
		assertEqual(passSeat.Disabled, true, "Detached PassengerSeat disabled")
		assertEqual(dSeat.Occupant, ownerHum, "Owner remains seated in DriverSeat")

		-- Probar ForceEjectSeatOccupant con thief + cooldown clear -> dueño vuelve a sentarse sin fallo
		VehicleSeatService.ExitHumanoid(ownerHum, true)
		task.wait(0.05)
		dSeat:Sit(thiefHum)
		task.wait()
		VehicleSeatService.ForceEjectSeatOccupant(dSeat, thiefHum)
		task.wait()
		assertEqual(dSeat.Occupant, nil, "Thief forcefully ejected")
		dSeat:Sit(ownerHum)
		task.wait(0.05)
		assertEqual(dSeat.Occupant, ownerHum, "Owner re-seats immediately without cooldown blockage")

		-- Salida voluntaria autorizada ("Salir del asiento")
		local exitOk, exitErr = VehicleLifecycleService.ExitVehicleSeat(p1)
		assertTrue(exitOk, `Authorized ExitVehicleSeat succeeded: {tostring(exitErr)}`)
		assertEqual(dSeat.Occupant, nil, "DriverSeat cleared on authorized exit")
		assertEqual(ownerHum:GetStateEnabled(Enum.HumanoidStateType.Jumping), true, "Jumping restored after exit")
		assertEqual(rt.State, GameConfig.Runtime.States.OnFootRuntime, "Runtime transitioned to OnFootRuntime")
		assertTrue((ownerChar:GetPivot().Position - dSeat.Position).Magnitude >= 3.0, "Owner placed cleanly outside vehicle bounds")

		ownerChar:Destroy()
		passChar:Destroy()
		thiefChar:Destroy()
		VehicleLaunchService.ReturnToWorkshop(p1)
		assertEqual(VehicleSeatService.GetRegisteredSeatCount(), 0, "Zero registered seats after ReturnToWorkshop")
		env.Teardown()
		ground:Destroy()
		customSpawns:Destroy()
	end)

	-- 11) 20s debris lifetime expiration
	runTest("Fase 4.2 [11]: VehicleFragments persist until 19.9s and are cleanly destroyed at 20.0s TTL", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 42011, Name = "P42_TTL20" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local ids = buildLinearTestVehicle(p1, "d11", { IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		VehicleDamageService.ApplyImpact(rt, ids.FrontBumperId, { DamageAmount = 100, Timestamp = env.Now() })
		assertEqual(VehicleDestructionService.GetStats().Fragments, 1, "Fragment active immediately after split")
		local frag = countFragmentsInDynamic(plot)[1]

		env.AdvanceClock(DestructionConfig.DebrisLifetimeSeconds - 0.1)
		VehicleDestructionService.CleanupExpired()
		assertEqual(VehicleDestructionService.GetStats().Fragments, 1, "Fragment retained at 19.9s (< 20s)")
		assertTrue(frag.Parent ~= nil, "Fragment still parented before TTL")

		env.AdvanceClock(0.15)
		VehicleDestructionService.CleanupExpired()
		assertEqual(VehicleDestructionService.GetStats().Fragments, 0, "Fragment purged cleanly at >= 20.0s")
		assertEqual(VehicleDestructionService.GetStats().Pieces, 0, "Pieces counter drops to 0 on expiration")
		assertEqual(frag.Parent, nil, "Expired fragment Model destroyed")
		env.Teardown()
	end)

	-- 12) Exact 500 per-vehicle/runtime & 1500 server FIFO debris limits
	runTest("Fase 4.2 [12]: Enforces 500 pieces/vehicle + 500 debris/runtime + 1500 server debris FIFO eviction", function()
		local env = setupIsolatedWorld(4)

		-- Verificar límite 500 piezas/vehículo (rechaza #501) y tope 500 escombros/runtime en Plot 1
		local pMax: PlotService.PlayerLike = { UserId = 42120, Name = "P42_Max500" }
		PlotService.Assign(pMax)
		local lastPos = Vector3.new(-8, 10.5, 10)
		local placed = 0
		for layer = 0, 4 do
			local y = 2.5 + layer * 2.0
			local zStart = if layer % 2 == 0 then 0 else 9
			local zEnd = if layer % 2 == 0 then 9 else 0
			local zStep = if layer % 2 == 0 then 1 else -1
			for lz = zStart, zEnd, zStep do
				for ix = 0, 9 do
					placed += 1
					if placed <= 499 then
						local pos = Vector3.new(-9 + ix * 2, y, -9 + lz * 2)
						lastPos = pos
						placePieceReq(pMax, `m5_{placed}`, "WoodBlock", CFrame.new(pos))
					end
				end
			end
			task.wait()
		end
		placePieceReq(pMax, "m5_seat", "DriverSeat", CFrame.new(lastPos + Vector3.new(0, 1.5, 0)))
		local rejected501 = BuildService.ProcessRequest(pMax, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "m5_over",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(-9, 12.5, -9),
		})
		assertEqual(rejected501.Success, false, "Rejects 501st piece on vehicle")

		-- Reiniciar P1..P4 con 4 vehículos de 396 piezas (3 torres x 128 + 3 puentes + 8 espina + 1 asiento) = 1584 piezas -> 1548 escombros > 1500
		env.Teardown()
		env = setupIsolatedWorld(4)

		local firstFrag: Model? = nil
		local newestFrag: Model? = nil
		local towerXs = { -8, -2, 4 }
		local spineXs = { -8, -6, -4, -2, 0, 2, 4, 6 }
		for idx = 1, 4 do
			local p: PlotService.PlayerLike = { UserId = 42200 + idx, Name = `P42_GlobalCap_{idx}` }
			local plot = PlotService.Assign(p) :: PlotService.PlotRecord

			for sIdx, sx in ipairs(spineXs) do
				placePieceReq(p, `sp_{sIdx}`, "WoodBlock", CFrame.new(sx, 2.5, -9))
			end
			placePieceReq(p, "spine_seat", "DriverSeat", CFrame.new(-8, 4.0, -9))

			local bridgeIds: { string } = {}
			for tIdx, tx in ipairs(towerXs) do
				local bridge = placePieceReq(p, `br_{tIdx}`, "WoodBlock", CFrame.new(tx, 2.5, -7))
				table.insert(bridgeIds, bridge)
				for layer = 0, 7 do
					local y = 2.5 + layer * 2.0
					if layer % 2 == 0 then
						for rz = 0, 7 do
							placePieceReq(p, `tw_{tIdx}_{layer}_a_{rz}`, "WoodBlock", CFrame.new(tx, y, -5 + rz * 2))
						end
						for rz = 7, 0, -1 do
							placePieceReq(p, `tw_{tIdx}_{layer}_b_{rz}`, "WoodBlock", CFrame.new(tx + 2, y, -5 + rz * 2))
						end
					else
						for rz = 0, 7 do
							placePieceReq(p, `tw_{tIdx}_{layer}_b_{rz}`, "WoodBlock", CFrame.new(tx + 2, y, -5 + rz * 2))
						end
						for rz = 7, 0, -1 do
							placePieceReq(p, `tw_{tIdx}_{layer}_a_{rz}`, "WoodBlock", CFrame.new(tx, y, -5 + rz * 2))
						end
					end
				end
				task.wait()
			end

			local lr = VehicleLaunchService.LaunchVehicle(p, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
			assertTrue(lr.Success and lr.Runtime ~= nil, `Player {idx} 396-piece vehicle launched`)
			local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
			env.AdvanceClock(2.0)

			for tIdx, bId in ipairs(bridgeIds) do
				VehicleDamageService.ApplyImpact(rt, bId, { DamageAmount = 100, Timestamp = env.AdvanceClock(0.1) })
				local frags = countFragmentsInDynamic(plot)
				if idx == 1 and tIdx == 1 and #frags >= 1 then
					firstFrag = frags[1]
				end
				if idx == 4 and tIdx == #bridgeIds and #frags >= 1 then
					newestFrag = frags[#frags]
				end
			end
			task.wait()
		end

		local finalStats = VehicleDestructionService.GetStats()
		assertTrue(finalStats.Pieces <= DestructionConfig.MaxDebrisPiecesServer, `Server global debris pieces capped at <= 1500 (got {finalStats.Pieces})`)
		assertTrue(finalStats.Pieces >= 1200, `Expected substantial surviving newest debris near cap (got {finalStats.Pieces})`)
		if firstFrag then
			assertEqual(firstFrag.Parent, nil, "Oldest FIFO debris fragment was evicted first once global cap exceeded 1500")
		end
		if newestFrag then
			assertTrue(newestFrag.Parent ~= nil, "Newest debris fragment survives FIFO global eviction")
		end
		env.Teardown()
	end)

	-- 13) Partial (>0 HP) no degradation + strict Blueprint & Inventory immutability across total destruction
	runTest("Fase 4.2 [13]: Partial >0 HP triggers no detachment; full destruction leaves Blueprint and Inventory untouched", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 42013, Name = "P42_Immutable" }
		PlotService.Assign(p1)

		local engUnits = EngineInventoryService.EnsureControlledWorkshopUnits(p1)
		local bstUnits = BoosterInventoryService.EnsureControlledWorkshopUnits(p1)
		assertTrue(#engUnits >= 1 and #bstUnits >= 1, "Inventory starter units present")
		local engUnitId = engUnits[1].ItemInstanceId
		local bstUnitId = bstUnits[1].ItemInstanceId

		local ids = buildLinearTestVehicle(p1, "d13", {
			IncludeEngine = true,
			EngineUnitId = engUnitId,
			IncludeFuelTank = true,
			IncludeBooster = true,
			BoosterUnitId = bstUnitId,
			IncludeNitroTank = true,
			IncludeWheels = true,
		})
		local bpBeforeJson = HttpService:JSONEncode(BlueprintSerializer.SerializeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1)))
		local editableBefore = #(VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model):GetChildren()

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		-- Daño parcial > 0 HP no desprende nada ni degrada
		local partial = VehicleDamageService.ApplyImpact(rt, ids.FrontBumperId, { DamageAmount = 20, Timestamp = env.AdvanceClock(1) })
		assertEqual(#partial.DetachedParts, 0, "Partial damage (>0 HP) produces zero DetachedParts")

		-- Destrucción severa a 0 HP en varias partes
		VehicleDamageService.ApplyImpact(rt, ids.MidFrameId, { DamageAmount = 100, Timestamp = env.AdvanceClock(1) })
		VehicleDamageService.ApplyImpact(rt, ids.SeatId, { DamageAmount = 500, SkipDistribution = true, Timestamp = env.AdvanceClock(1) })
		assertTrue(VehicleDestructionService.GetStats().Fragments >= 2, "Fragments created during runtime destruction")

		VehicleLaunchService.ReturnToWorkshop(p1)

		local bpAfterJson = HttpService:JSONEncode(BlueprintSerializer.SerializeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1)))
		local editableAfter = #(VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model):GetChildren()
		assertEqual(bpAfterJson, bpBeforeJson, "Persistent Blueprint JSON untouched by runtime destruction")
		assertEqual(editableAfter, editableBefore, "EditableVehicle child count untouched")

		local engAfter = EngineInventoryService.GetPlayerUnits(p1)
		local bstAfter = BoosterInventoryService.GetPlayerUnits(p1)
		assertEqual(#engAfter, #engUnits, "Engine inventory count untouched")
		assertEqual(#bstAfter, #bstUnits, "Booster inventory count untouched")
		assertEqual(engAfter[1].RarityId, engUnits[1].RarityId, "Engine rarity untouched")
		assertEqual(bstAfter[1].RarityId, bstUnits[1].RarityId, "Booster rarity untouched")
		env.Teardown()
	end)

	-- 14) 10-player concurrent destruction stress test & 0/0/0/0 leak verification
	runTest("Fase 4.2 [14]: 10-player simultaneous destruction & ReturnToWorkshop leaves zero fragments, seats or connections", function()
		local env = setupIsolatedWorld(10)
		local players: { PlotService.PlayerLike } = {}

		for i = 1, 10 do
			local p: PlotService.PlayerLike = { UserId = 42300 + i, Name = `P42_Multi_{i}` }
			PlotService.Assign(p)
			table.insert(players, p)
			local ids = buildLinearTestVehicle(p, `m{i}`, { IncludeEngine = true, IncludeFuelTank = true, IncludeBooster = true, IncludeWheels = true })
			local lr = VehicleLaunchService.LaunchVehicle(p, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
			assertTrue(lr.Success and lr.Runtime ~= nil, `Player {i} launch succeeded`)
			local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
			env.AdvanceClock(2.0)
			VehicleDamageService.ApplyImpact(rt, ids.MidFrameId, { DamageAmount = 100, Timestamp = env.AdvanceClock(0.1) })
			task.wait()
		end

		local statsActive = VehicleDestructionService.GetStats()
		assertEqual(statsActive.Runtimes, 10, "10 runtimes tracked concurrently")
		assertTrue(statsActive.Fragments >= 20, `Concurrent splits created across all 10 plots (got {statsActive.Fragments})`)

		for i = 1, 10 do
			assertTrue(VehicleLaunchService.ReturnToWorkshop(players[i]).Success, `Player {i} ReturnToWorkshop succeeded`)
		end

		local statsAfterReturn = VehicleDestructionService.GetStats()
		assertEqual(statsAfterReturn.Runtimes, 0, "Zero tracked destruction runtimes")
		assertEqual(statsAfterReturn.Fragments, 0, "Zero leftover debris fragments")
		assertEqual(statsAfterReturn.Pieces, 0, "Zero leftover debris pieces")
		assertEqual(statsAfterReturn.Connections, 0, "Zero destruction Heartbeat connections")
		assertEqual(VehicleSeatService.GetRegisteredSeatCount(), 0, "Zero registered seats")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero active runtimes")
		assertEqual(VehicleRuntimeService.GetTrackedConnectionCount(), 0, "Zero tracked runtime connections")
		assertEqual(VehicleImpactService.GetTrackedConnectionCount(), 0, "Zero impact Touched connections")

		env.Teardown()
	end)

	-- 15) Live Workspace Physics crash detachment (active when RunService:IsRunning()) + kinematics fallback in Edit mode
	runTest("Fase 4.2 [15]: Live Workspace physics high-speed impact breaks 0 HP pieces into physical VehicleFragments cleanly", function()
		if not RunService:IsRunning() then
			local kin = DamageMath.EvaluateImpactKinematics({
				RelativeVelocity = Vector3.new(0, 0, -140),
				ImpactNormal = Vector3.new(0, 0, -1),
				StruckMass = 80,
				OtherIsStatic = true,
				TimeSinceLaunchSeconds = 2.0,
			})
			assertTrue(kin.PassesThreshold and kin.NormalSpeed >= 139, "Edit-mode kinematics sanity check passed")
			return
		end

		local customSpawns = Instance.new("Folder")
		customSpawns.Name = "_Phase42LiveSpawns"
		customSpawns.Parent = Workspace
		local sp1 = Instance.new("Part")
		sp1.Name = "Plot_Live42"
		sp1.Anchored = true
		sp1.CanCollide = false
		sp1.CanTouch = false
		sp1.CanQuery = false
		sp1.Transparency = 1
		sp1.Position = Vector3.new(2800, 10, 0)
		sp1.Parent = customSpawns

		local ground = Instance.new("Part")
		ground.Name = "_P42LiveGround"
		ground.Anchored = true
		ground.CanCollide = true
		ground.Size = Vector3.new(240, 4, 240)
		ground.Position = Vector3.new(2800, 6, 0)
		ground.Parent = Workspace

		local env = setupIsolatedWorld(1, customSpawns)
		local p1: PlotService.PlayerLike = { UserId = 42015, Name = "P42_LiveCrash" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local ids = buildLinearTestVehicle(p1, "d15", { IncludeEngine = true, IncludeFuelTank = true, IncludeBooster = true, IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Live Phase 4.2 test vehicle launched")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local root = rt.RootModel :: Model

		task.wait(DamageConfig.Impact.LaunchSettlingGraceSeconds + 0.15)
		env.AdvanceClock(1.0)

		local seatPart = rt.DriverSeatPart :: VehicleSeat
		local forward = seatPart.CFrame.LookVector
		local barrier = Instance.new("Part")
		barrier.Name = "_P42_TestBarrier"
		barrier.Anchored = true
		barrier.CanCollide = true
		barrier.CanTouch = true
		barrier.Size = Vector3.new(24, 18, 6)
		barrier.CFrame = CFrame.lookAt(seatPart.Position + forward * 16, seatPart.Position)
		barrier.Parent = Workspace

		local deadline = os.clock() + 2.5
		local fragmentObserved = false
		while os.clock() < deadline do
			for _, partState in pairs(rt.Parts) do
				local pp = partState.PrimaryPart
				if pp and pp.Parent and not partState.IsDetached then
					pp.AssemblyLinearVelocity = forward * 145
				end
			end
			task.wait(0.05)
			if #countFragmentsInDynamic(plot) >= 1 then
				fragmentObserved = true
				break
			end
		end

		barrier:Destroy()
		assertTrue(fragmentObserved, "Real Studio PGS collision reduced 0 HP piece and detached VehicleFragment")
		assertTrue((root:GetAttribute("DestructionLastMs") or 999) < 25, `Destruction step under 25 ms budget (got {tostring(root:GetAttribute("DestructionLastMs"))})`)
		assertEqual(rt.Parts[ids.FrontBumperId].IsDetached or (#countFragmentsInDynamic(plot) >= 1), true, "Real physical detachment recorded")

		VehicleLaunchService.ReturnToWorkshop(p1)
		assertEqual(VehicleDestructionService.GetStats().Fragments, 0, "Live test ReturnToWorkshop cleans fragments")
		env.Teardown()
		ground:Destroy()
		customSpawns:Destroy()
	end)
end

function Phase42Tests.RunStandalone()
	local results: { TestCaseResult } = {}
	local passedCount = 0
	local failedCount = 0

	local function runTest(name: string, fn: () -> ())
		local ok, err = pcall(fn)
		if ok then
			passedCount += 1
			table.insert(results, { Name = name, Passed = true, Error = nil })
		else
			failedCount += 1
			table.insert(results, { Name = name, Passed = false, Error = tostring(err) })
			pcall(VehicleDestructionService._ResetForTests)
			pcall(VehicleSeatService._ResetForTests)
			pcall(VehicleDamageService._ResetForTests)
			pcall(VehicleImpactService._ResetForTests)
			pcall(VehicleRuntimeService._ResetForTests)
		end
	end

	Phase42Tests.AppendTests(results, runTest)
	return {
		Passed = passedCount,
		Failed = failedCount,
		Total = #results,
		Results = results,
	}
end

return Phase42Tests
