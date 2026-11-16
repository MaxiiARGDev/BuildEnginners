--!strict
--[=[
	Phase41Tests
	Suite de pruebas automatizadas de Fase 4.1 (Sistema de Daño Estructural y Durabilidad por Pieza):
	- Inicialización autoritativa de salud/resistencia/multiplicadores por pieza en VehicleDamageService.
	- Perfiles de resistencia por categoría (incluyendo Seats / Utilities / Wheels / Engines / Boosters / FuelTanks / Structures)
	  y herencia de escalado por variante/rareza sin alterar el rendimiento en Fase 4.1.
	- Detección centralizada de colisiones en VehicleImpactService (cinemática, velocidad relativa/normal, período de gracia,
	  deduplicación temporal/ráfaga, filtrado de hubs virtuales SuspensionCarrier/SteeringPivot y auto-colisiones).
	- Daño localizado (directo + amortiguación 1-hop adyacente, 0 propagación a piezas >= 2 hops ni daño global uniforme).
	- Daño acumulativo, clamping estricto [0, MaxHealth], seguridad contra NaN/Inf/negativos y choque vehículo-vs-vehículo.
	- Aislamiento estricto multi-jugador, separación estricta Blueprint vs VehicleRuntime e inventarios persistentes intactos.
	- Reset completo al usar ResetVehicle y ReturnToWorkshop + relanzamiento.
	- Limpieza total de eventos RBXScriptConnection e índices internos (0 leaks al destruir/retornar).
	- Compatibilidad total con vehículos con ruedas, solo-boosters, híbridos y límite de 500 piezas (rechazo en 501, máximo 1 DriverSeat).
	- Pruebas físicas reales en Workspace durante RunService:IsRunning() y herramientas Dev-only con autorización estricta.
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local DamageConfig = require(ReplicatedStorage.Shared.Config.DamageConfig)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local DamageMath = require(ReplicatedStorage.Shared.Damage.DamageMath)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

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
local VehicleRuntimeService = require(ServerScriptService.Server.Services.VehicleRuntimeService)
local VehicleLifecycleService = require(ServerScriptService.Server.Services.VehicleLifecycleService)
local VehicleLaunchService = require(ServerScriptService.Server.Services.VehicleLaunchService)
local BuildService = require(ServerScriptService.Server.Services.BuildService)

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase41Tests = {}

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

local function countRuntimeParts(rt: VehicleTypes.VehicleRuntime): number
	local count = 0
	for _ in pairs(rt.Parts) do
		count += 1
	end
	return count
end

local function setupIsolatedWorld(plotCount: number?, customPlotSpawns: Folder?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = customPlotSpawns or (Workspace:WaitForChild("PlotSpawns") :: Folder)
	local assets = ServerStorage:WaitForChild("ItemAssets")

	local prevPlots = Workspace:FindFirstChild("_Phase41TestPlots")
	if prevPlots then
		prevPlots:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase41TestPlots"
	tempPlots.Parent = Workspace

	BuildService._ResetForTests()
	VehicleLaunchService._ResetForTests()
	VehicleLifecycleService._ResetForTests()
	VehicleRuntimeService._ResetForTests()
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
		FreeWheels: boolean?,
	}?
)
	local opts = options or {}
	local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)

	-- Cadena lineal Z: [-4] = Bumper(front) -> [-2] = SeatFrame -> [0] = Mid -> [2] = EngFrame -> [4] = Rear -> [6] = Tail
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
		nitroTankId = placePieceReq(player, `{prefix}_nitro`, "SmallNitroTank", CFrame.new(2, 2.5, 1.5))
	end

	local boosterId: string? = nil
	if opts.IncludeBooster then
		boosterId = placePieceReq(player, `{prefix}_bst`, "SmallBooster", CFrame.new(0, 2.5, 8.5), nil, opts.BoosterUnitId)
	end

	local wheelIds: { string } = {}
	if opts.IncludeWheels ~= false then
		local wheelCfg = if opts.FreeWheels then { Wheel = { IsDriven = false } } else nil
		table.insert(wheelIds, placePieceReq(player, `{prefix}_wfl`, "SmallWheel", CFrame.new(-1.5, 2.5, -2), wheelCfg))
		table.insert(wheelIds, placePieceReq(player, `{prefix}_wfr`, "SmallWheel", CFrame.new(1.5, 2.5, -2) * wheelFlip, wheelCfg))
		table.insert(wheelIds, placePieceReq(player, `{prefix}_wrl`, "SmallWheel", CFrame.new(-1.5, 2.5, 6), wheelCfg))
		table.insert(wheelIds, placePieceReq(player, `{prefix}_wrr`, "SmallWheel", CFrame.new(1.5, 2.5, 6) * wheelFlip, wheelCfg))
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

function Phase41Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (name: string, fn: () -> ()) -> ()
)
	local _ = results

	-- 01) Per-piece health initialization + exclusion of virtual hubs
	runTest("Fase 4.1 [01]: Per-piece health initializes on runtime parts and ignores virtual wheel hubs", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41001, Name = "P41_Init" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t01", {
			IncludeEngine = true,
			IncludeFuelTank = true,
			IncludeBooster = true,
			IncludeNitroTank = true,
			IncludeWheels = true,
		})

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success and lr.Runtime ~= nil, `Launch failed: {tostring(lr.ErrorCode)}`)
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		local frontHealth = VehicleDamageService.GetPieceHealth(rt, ids.FrontBumperId)
		assertTrue(frontHealth ~= nil, "Front bumper health record must exist")
		local fh = frontHealth :: VehicleTypes.PieceDamageRecord
		assertEqual(fh.PieceId, ids.FrontBumperId, "PieceId matches PieceInstanceId")
		assertEqual(fh.ItemId, "WoodBlock", "ItemId is WoodBlock")
		assertEqual(fh.MaxHealth, 75, "WoodBlock MaxHealth matches MaxDurability (75)")
		assertEqual(fh.CurrentHealth, 75, "Initial CurrentHealth == MaxHealth")
		assertEqual(fh.State, DamageConfig.PieceStates.Healthy, "Initial State == Healthy")
		assertEqual(fh.DamageReceivedTotal, 0, "Initial DamageReceivedTotal == 0")
		assertEqual(fh.ImpactCount, 0, "Initial ImpactCount == 0")

		local partCount = countRuntimeParts(rt)
		local summary = VehicleDamageService.GetVehicleHealthSummary(rt) :: VehicleTypes.VehicleHealthSummary
		assertEqual(summary.TotalPieces, partCount, "Summary TotalPieces matches runtime parts")
		assertEqual(summary.HealthyCount, partCount, "All pieces start Healthy")
		assertEqual(summary.DamagedCount, 0, "DamagedCount starts at 0")
		assertEqual(summary.DisabledCount, 0, "DisabledCount starts at 0")
		assertNear(summary.IntegrityPercent, 100, 1e-4, "Initial IntegrityPercent == 100")

		assertEqual(rt.RootModel:GetAttribute("DMG_TotalPieces"), partCount, "Root telemetry DMG_TotalPieces synced")
		assertNear(rt.RootModel:GetAttribute("DMG_StructuralIntegrityPct") :: number, 100, 1e-2, "Root telemetry IntegrityPct == 100")

		-- Verificar que hubs virtuales (SuspensionCarrier, SteeringPivot) NO reciben daños ni conexiones Touched
		local virtualHubCount = 0
		for _, desc in ipairs(rt.RootModel:GetDescendants()) do
			if desc:IsA("BasePart") then
				local roleAttr = desc:GetAttribute("PartPhysicsRole")
				if roleAttr == GameConfig.Runtime.PartRoles.SuspensionCarrier or roleAttr == GameConfig.Runtime.PartRoles.SteeringPivot then
					virtualHubCount += 1
					assertTrue(desc.CanTouch == false, `{desc.Name} keeps CanTouch = false`)
					assertTrue(desc.CanCollide == false, `{desc.Name} keeps CanCollide = false`)
					assertEqual(VehicleDamageService.GetPieceHealth(rt, desc.Name), nil, `Virtual hub {desc.Name} has no damage record`)
				end
			end
		end
		assertTrue(virtualHubCount >= 4, "Wheeled runtime created virtual hubs that remain un-tracked")
		assertTrue(
			VehicleImpactService.GetActivePartIndexCount() >= partCount
				and VehicleImpactService.GetTrackedConnectionCount() < partCount + virtualHubCount + 4,
			"Active collidable parts indexed cleanly while virtual hubs remain excluded"
		)

		env.Teardown()
	end)

	-- 02) Category profiles, Seats category validation, Variant/Rarity inheritance
	runTest("Fase 4.1 [02]: Category DamageConfig profiles, Seats validation and Variant/Rarity scaling apply properly", function()
		local env = setupIsolatedWorld(2)

		-- Validar nueva categoría Seats y atributos opcionales ImpactResistance / DamageMultiplier en ItemRegistry
		local validSeat, seatErr = ItemRegistry.ValidateDefinition({
			Id = "TestPassengerSeat",
			DisplayName = "Passenger Seat",
			Category = "Seats",
			Model = "PassengerSeat",
			Price = nil,
			Stats = {
				Weight = 6,
				MaxDurability = 180,
				ImpactResistance = 1.4,
				DamageMultiplier = 0.7,
			},
			Behavior = "SeatBehavior",
		}, "Seats")
		assertTrue(validSeat, `Valid Seats definition with Damage stats must pass validation: {tostring(seatErr)}`)

		local badResOk = ItemRegistry.ValidateDefinition({
			Id = "BadSeat",
			DisplayName = "Bad Seat",
			Category = "Seats",
			Model = "PassengerSeat",
			Price = nil,
			Stats = { Weight = 6, MaxDurability = 100, ImpactResistance = 0 },
		}, "Seats")
		assertTrue(not badResOk, "ImpactResistance <= 0 must be rejected by ItemRegistry")

		local seatsProfile = DamageConfig.GetCategoryProfile("Seats")
		assertEqual(seatsProfile.Category, "Seats", "DamageConfig has dedicated Seats profile")
		assertEqual(seatsProfile.BalanceStatus, "Provisional_TBD", "Unconfirmed damage profiles carry Provisional_TBD tag")

		local p1: PlotService.PlayerLike = { UserId = 41002, Name = "P41_Categories" }
		PlotService.Assign(p1)
		local epicUnit = EngineInventoryService.RegisterUnitForTesting(p1, {
			ItemInstanceId = "eng_epic_41",
			EngineSizeId = "Small",
			VariantId = "Racing",
			RarityId = "Epic",
		})
		local expectedEngStats = EngineCatalog.ResolveEffectiveStats({
			ItemId = "SmallEngine",
			VariantId = "Racing",
			RarityId = "Epic",
		})

		local ids = buildLinearTestVehicle(p1, "t02", {
			IncludeEngine = true,
			EngineUnitId = epicUnit.ItemInstanceId,
			IncludeFuelTank = true,
			IncludeBooster = true,
			IncludeWheels = true,
		})

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch failed")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		local engRec = VehicleDamageService.GetPieceHealth(rt, ids.EngineId :: string) :: VehicleTypes.PieceDamageRecord
		assertEqual(engRec.MaxHealth, expectedEngStats.MaxDurability, "Epic engine MaxHealth inherits scaled MaxDurability")
		assertNear(engRec.ImpactResistance, DamageConfig.GetCategoryProfile("Engines").ImpactResistance, 1e-4, "Engine ImpactResistance matches profile")
		assertNear(engRec.DamageMultiplier, DamageConfig.GetCategoryProfile("Engines").DamageMultiplier, 1e-4, "Engine DamageMultiplier matches profile")

		local wheelRec = VehicleDamageService.GetPieceHealth(rt, ids.WheelIds[1]) :: VehicleTypes.PieceDamageRecord
		assertEqual(wheelRec.Category, "Wheels", "Wheel category is Wheels")
		assertNear(wheelRec.ImpactResistance, DamageConfig.GetCategoryProfile("Wheels").ImpactResistance, 1e-4, "Wheel ImpactResistance matches profile")

		-- Comparar daño bajo misma energía cinemática: FuelTank (mult 1.2 / res 0.8) vs Wheel (mult 0.9 / res 1.15)
		local wheelDmgResult = VehicleDamageService.ApplyImpact(rt, ids.WheelIds[1], {
			SourceType = "StaticObstacle",
			DamageAmount = 40,
			SkipDistribution = true,
			Timestamp = env.AdvanceClock(1),
		})
		local tankDmgResult = VehicleDamageService.ApplyImpact(rt, ids.FuelTankId :: string, {
			SourceType = "StaticObstacle",
			DamageAmount = 40,
			SkipDistribution = true,
			Timestamp = env.AdvanceClock(1),
		})
		assertTrue(
			tankDmgResult.PrimaryDamageApplied > wheelDmgResult.PrimaryDamageApplied,
			`Fragile FuelTank ({tankDmgResult.PrimaryDamageApplied}) takes more damage than tougher Wheel ({wheelDmgResult.PrimaryDamageApplied}) under equal raw impact`
		)

		env.Teardown()
	end)

	-- 03) Low speed, resting contact & launch settling grace period produce 0 damage
	runTest("Fase 4.1 [03]: Low-speed contacts, tangential rolling and grace window cause zero damage", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41003, Name = "P41_LowSpeed" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t03", { IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch failed")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		-- A) Contacto dentro de ventana de estabilización inicial (velocidad normal suave < GraceOverrideNormalSpeed)
		local outGrace = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.FrontBumperId,
			SourceType = "Terrain",
			OtherName = "SpawnPlatform",
			OtherTargetKey = "SpawnPlatform",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 16, 0),
			ImpactNormal = Vector3.new(0, 1, 0),
			Timestamp = env.Now() + 0.05,
		})
		assertTrue(
			not outGrace.Triggered and outGrace.RejectReason == "LaunchSettlingGrace",
			`Settling grace ignores light landing settle (got {tostring(outGrace.RejectReason)})`
		)

		-- Avanzar más allá del LaunchSettlingGraceSeconds
		env.AdvanceClock(DamageConfig.Impact.LaunchSettlingGraceSeconds + 0.5)

		-- B) Choque de baja velocidad por debajo del umbral
		local outSlow = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.FrontBumperId,
			SourceType = "StaticObstacle",
			OtherName = "SoftBarrier",
			OtherTargetKey = "SoftBarrier",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 0, 6),
			ImpactNormal = Vector3.new(0, 0, 1),
			Timestamp = env.Now(),
		})
		assertTrue(not outSlow.Triggered, "Low-speed bump (< threshold) must cause zero damage")

		-- C) Rodamiento tangencial paralelo al suelo (velocidad tangencial alta moderada, normal 0)
		local outRoll = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.WheelIds[1],
			SourceType = "Terrain",
			OtherName = "Road",
			OtherTargetKey = "Road_Roll",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 0, -32),
			ImpactNormal = Vector3.new(0, 1, 0),
			Timestamp = env.Now(),
		})
		assertTrue(not outRoll.Triggered, "Normal driving roll along surface normal must cause zero damage")

		-- D) Rebote / separación (v_other - v_piece apunta opuesto a la normal -> NormalSpeed = 0)
		local outSep = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.FrontBumperId,
			SourceType = "StaticObstacle",
			OtherName = "Wall",
			OtherTargetKey = "Wall_Sep",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 0, -35),
			ImpactNormal = Vector3.new(0, 0, 1),
			Timestamp = env.Now(),
		})
		assertTrue(not outSep.Triggered, "Separating / rebounding motion must cause zero damage")

		local fh = VehicleDamageService.GetPieceHealth(rt, ids.FrontBumperId) :: VehicleTypes.PieceDamageRecord
		assertEqual(fh.CurrentHealth, fh.MaxHealth, "Front bumper health stayed 100%")
		assertEqual(fh.ImpactCount, 0, "ImpactCount remained 0")

		env.Teardown()
	end)

	-- 04) High-speed impact proportionality, state transitions and WeldConstraints/Phase4.1 non-degradation
	runTest("Fase 4.1 [04]: High-speed impacts scale damage proportionally (Healthy -> Damaged -> Disabled) without breaking welds or functionality", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41004, Name = "P41_HighSpeed" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t04", { IncludeEngine = true, IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch failed")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		-- Medir daño a 32 studs/s vs 135 studs/s en dos bloques equivalentes (bumper vs tail)
		local midImpact = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.FrontBumperId,
			SourceType = "StaticObstacle",
			OtherName = "ConcreteWallA",
			OtherTargetKey = "WallA",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 0, 32),
			ImpactNormal = Vector3.new(0, 0, 1),
			Timestamp = env.AdvanceClock(1),
		})
		local hardImpact = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.TailFrameId,
			SourceType = "StaticObstacle",
			OtherName = "ConcreteWallB",
			OtherTargetKey = "WallB",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 0, -135),
			ImpactNormal = Vector3.new(0, 0, -1),
			Timestamp = env.AdvanceClock(1),
		})
		assertTrue(midImpact.Triggered and hardImpact.Triggered, "Both medium and hard impacts must apply damage")
		local midDmg = (midImpact.DamageResult :: VehicleTypes.DamageImpactResult).PrimaryDamageApplied
		local hardDmg = (hardImpact.DamageResult :: VehicleTypes.DamageImpactResult).PrimaryDamageApplied
		assertTrue(hardDmg > midDmg * 2, `Higher impact speed ({hardDmg}) must deal substantially more damage than moderate speed ({midDmg})`)

		local frontRec = VehicleDamageService.GetPieceHealth(rt, ids.FrontBumperId) :: VehicleTypes.PieceDamageRecord
		local tailRec = VehicleDamageService.GetPieceHealth(rt, ids.TailFrameId) :: VehicleTypes.PieceDamageRecord
		assertEqual(frontRec.State, DamageConfig.PieceStates.Damaged, "Moderate impact transitions Healthy -> Damaged")
		assertEqual(tailRec.State, DamageConfig.PieceStates.Disabled, "Severe impact reaching 0 HP transitions to Disabled")
		assertEqual(tailRec.CurrentHealth, 0, "Disabled tail frame has CurrentHealth == 0")

		-- En Fase 4.2 las piezas intactas mantienen sus welds y el motor conserva 100%, mientras TailFrame a 0 HP se separa estructuralmente.
		local survivingBrokenWelds = 0
		for _, joint in ipairs(rt.Joints) do
			if not joint.Parent then
				survivingBrokenWelds += 1
			end
		end
		assertEqual(survivingBrokenWelds, 0, "Surviving chassis WeldConstraints remain intact")
		assertEqual(rt.Parts[ids.TailFrameId].IsDetached, true, "0-HP TailFrame detaches in Phase 4.2")
		assertEqual(rt.Parts[ids.TailFrameId].IsFunctional, false, "Detached 0-HP TailFrame becomes non-functional")
		assertEqual(rt.Parts[ids.EngineId :: string].CurrentDurability, rt.Parts[ids.EngineId :: string].MaxDurability, "Engine CurrentDurability untouched in 4.1/4.2")

		env.Teardown()
	end)

	-- 05) Strict localization: primary piece + immediate 1-hop neighbor only; 2+ hops receive 0
	runTest("Fase 4.1 [05]: Impact damage is strictly localized and never applies equal vehicle-wide HP loss", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41005, Name = "P41_Localized" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t05", { IncludeEngine = true, IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch failed")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		local hitRes = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.FrontBumperId,
			SourceType = "StaticObstacle",
			OtherName = "Bollard",
			OtherTargetKey = "Bollard_Loc",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 0, 48),
			ImpactNormal = Vector3.new(0, 0, 1),
			Timestamp = env.AdvanceClock(1),
		})
		assertTrue(hitRes.Triggered and hitRes.DamageResult ~= nil, "Front bumper impact applies damage")
		local dr = hitRes.DamageResult :: VehicleTypes.DamageImpactResult

		local frontLost = (VehicleDamageService.GetPieceHealth(rt, ids.FrontBumperId) :: VehicleTypes.PieceDamageRecord).DamageReceivedTotal
		local seatFrameLost = (VehicleDamageService.GetPieceHealth(rt, ids.SeatFrameId) :: VehicleTypes.PieceDamageRecord).DamageReceivedTotal
		local midLost = (VehicleDamageService.GetPieceHealth(rt, ids.MidFrameId) :: VehicleTypes.PieceDamageRecord).DamageReceivedTotal
		local engLost = (VehicleDamageService.GetPieceHealth(rt, ids.EngineId :: string) :: VehicleTypes.PieceDamageRecord).DamageReceivedTotal
		local rearWheelLost = (VehicleDamageService.GetPieceHealth(rt, ids.WheelIds[4]) :: VehicleTypes.PieceDamageRecord).DamageReceivedTotal

		assertTrue(frontLost > 0, "Struck FrontBumper took primary damage")
		assertTrue(seatFrameLost < frontLost * 0.25, `Adjacent 1-hop SeatFrame ({seatFrameLost}) takes small attenuated shock vs primary ({frontLost})`)
		assertEqual(midLost, 0, "2-hop MidFrame receives 0 damage")
		assertEqual(engLost, 0, "3+ hop Engine receives 0 damage")
		assertEqual(rearWheelLost, 0, "Distant rear wheel receives 0 damage")
		assertEqual(#dr.DetachedParts, 0, "Phase 4.1 returns empty DetachedParts list")

		env.Teardown()
	end)

	-- 06) Cumulative damage across separate cooldown-spaced impacts
	runTest("Fase 4.1 [06]: Cumulative damage reduces piece health monotonically across separate impacts", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41006, Name = "P41_Cumulative" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t06", { IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch failed")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		local hpHistory: { number } = {}
		for hit = 1, 4 do
			env.AdvanceClock(1.0)
			local res = VehicleImpactService.EvaluateImpact(rt, {
				PieceId = ids.FrontBumperId,
				SourceType = "StaticObstacle",
				OtherName = "CurbWall",
				OtherTargetKey = "CurbWall",
				OtherIsStatic = true,
				RelativeVelocity = Vector3.new(0, 0, 34),
				ImpactNormal = Vector3.new(0, 0, 1),
				Timestamp = env.Now(),
			})
			assertTrue(res.Triggered, `Impact #{hit} must trigger after cooldown`)
			local rec = VehicleDamageService.GetPieceHealth(rt, ids.FrontBumperId) :: VehicleTypes.PieceDamageRecord
			table.insert(hpHistory, rec.CurrentHealth)
		end

		assertTrue(hpHistory[1] < 75, "Hit 1 reduces health below 75")
		assertTrue(hpHistory[2] < hpHistory[1], "Hit 2 reduces health further")
		assertTrue(hpHistory[3] <= hpHistory[2], "Hit 3 continues monotone decline or clamps at 0")
		assertTrue(hpHistory[4] <= hpHistory[3] and hpHistory[4] >= 0, "Hit 4 stays clamped >= 0")

		local summary = VehicleDamageService.GetVehicleHealthSummary(rt) :: VehicleTypes.VehicleHealthSummary
		assertEqual(summary.ImpactCount, 4, "Summary ImpactCount equals 4 distinct impacts")

		env.Teardown()
	end)

	-- 07) Duplicate damage prevention via pair cooldown and burst cap
	runTest("Fase 4.1 [07]: Temporal pair cooldown and burst filter prevent duplicate Touched damage", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41007, Name = "P41_Dedup" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t07", { IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch failed")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		local hit1 = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.FrontBumperId,
			SourceType = "StaticObstacle",
			OtherName = "WallDup",
			OtherTargetKey = "WallDup_Key",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 0, 40),
			ImpactNormal = Vector3.new(0, 0, 1),
			Timestamp = env.Now(),
		})
		assertTrue(hit1.Triggered, "Initial impact succeeds")
		local hpAfterFirst = (VehicleDamageService.GetPieceHealth(rt, ids.FrontBumperId) :: VehicleTypes.PieceDamageRecord).CurrentHealth

		-- Disparos repetidos dentro del cooldown de par (0.02s, 0.05s, 0.15s < 0.28s)
		for _, dt in ipairs({ 0.02, 0.05, 0.10 }) do
			local dup = VehicleImpactService.EvaluateImpact(rt, {
				PieceId = ids.FrontBumperId,
				SourceType = "StaticObstacle",
				OtherName = "WallDup",
				OtherTargetKey = "WallDup_Key",
				OtherIsStatic = true,
				RelativeVelocity = Vector3.new(0, 0, 40),
				ImpactNormal = Vector3.new(0, 0, 1),
				Timestamp = env.Now() + dt,
			})
			assertTrue(
				not dup.Triggered and dup.RejectReason == "PairCooldownActive",
				`Duplicate Touched at +{dt}s must be deduplicated (got {tostring(dup.RejectReason)})`
			)
		end

		local hpAfterDups = (VehicleDamageService.GetPieceHealth(rt, ids.FrontBumperId) :: VehicleTypes.PieceDamageRecord).CurrentHealth
		assertEqual(hpAfterDups, hpAfterFirst, "Health unchanged during cooldown deduplication")

		-- Superado el cooldown, el siguiente impacto vuelve a procesarse normalmente
		env.AdvanceClock(DamageConfig.Deduplication.PieceOtherPairCooldownSeconds + 0.05)
		local hit2 = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.FrontBumperId,
			SourceType = "StaticObstacle",
			OtherName = "WallDup",
			OtherTargetKey = "WallDup_Key",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 0, 40),
			ImpactNormal = Vector3.new(0, 0, 1),
			Timestamp = env.Now(),
		})
		assertTrue(hit2.Triggered, "Impact after pair cooldown succeeds normally")

		env.Teardown()
	end)

	-- 08) Clamping [0, MaxHealth] & invalid/NaN/Inf/negative safety
	runTest("Fase 4.1 [08]: Clamps health strictly to [0, MaxHealth] and rejects negative, zero or NaN/Inf inputs", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41008, Name = "P41_Clamp" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t08", { IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch failed")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		-- Entradas inválidas
		for _, badVal in ipairs({ 0, -25, 0 / 0, math.huge, -math.huge }) do
			local res = VehicleDamageService.ApplyImpact(rt, ids.FrontBumperId, { DamageAmount = badVal, Timestamp = env.AdvanceClock(0.1) })
			assertTrue(not res.Applied and res.Reason == "InvalidOrZeroDamage", `Bad damage {tostring(badVal)} rejected cleanly`)
		end

		local badKin = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.FrontBumperId,
			SourceType = "StaticObstacle",
			OtherName = "BadVel",
			OtherTargetKey = "BadVel",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0 / 0, 0, -50),
			Timestamp = env.Now(),
		})
		assertTrue(not badKin.Triggered, "NaN velocity rejected by EvaluateImpact without crashing")

		-- Sobre-daño masivo debe hacer clamp a exactamente 0, sin HP negativo
		local overkill = VehicleDamageService.ApplyImpact(rt, ids.FrontBumperId, {
			SourceType = "API",
			DamageAmount = 999999,
			SkipDistribution = true,
			Timestamp = env.AdvanceClock(1),
		})
		assertTrue(overkill.Applied, "Massive direct damage applies up to remaining HP")
		assertEqual(overkill.NewHealth, 0, "CurrentHealth clamped to exactly 0")
		assertEqual(overkill.PrimaryDamageApplied, 75, "Applied damage capped at remaining MaxHealth (75)")
		assertEqual(overkill.PrimaryState, DamageConfig.PieceStates.Disabled, "State becomes Disabled")

		-- Impactar una pieza ya Disabled no reduce por debajo de 0
		local afterDisabled = VehicleDamageService.ApplyImpact(rt, ids.FrontBumperId, {
			SourceType = "API",
			DamageAmount = 50,
			SkipDistribution = true,
			Timestamp = env.AdvanceClock(1),
		})
		assertEqual(afterDisabled.NewHealth, 0, "Health never drops below 0")
		assertTrue(afterDisabled.NewHealth <= afterDisabled.MaxHealth and afterDisabled.NewHealth >= 0, "HP stays strictly in [0, MaxHealth]")

		env.Teardown()
	end)

	-- 09) Vehicle-to-vehicle crash + self-collision rejection
	runTest("Fase 4.1 [09]: Vehicle-to-vehicle impact distributes damage fairly using reduced mass and blocks self-collision", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41009, Name = "P41_VehA" }
		local p2: PlotService.PlayerLike = { UserId = 41010, Name = "P41_VehB" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)

		local ids1 = buildLinearTestVehicle(p1, "t09a", { IncludeEngine = true, IncludeWheels = true })
		local ids2 = buildLinearTestVehicle(p2, "t09b", { IncludeEngine = true, IncludeWheels = true })

		local lr1 = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		local lr2 = VehicleLaunchService.LaunchVehicle(p2, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr1.Success and lr2.Success, "Both vehicles launched")
		local rt1 = lr1.Runtime :: VehicleTypes.VehicleRuntime
		local rt2 = lr2.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		-- Verificar rechazo de auto-colisión si se pasa una parte del mismo RootModel
		local selfHit = VehicleImpactService.EvaluateImpact(rt1, {
			PieceId = ids1.FrontBumperId,
			StruckPart = rt1.Parts[ids1.FrontBumperId].PrimaryPart,
			OtherPart = rt1.Parts[ids1.RearFrameId].PrimaryPart,
			SourceType = "VehicleRuntime",
			RelativeVelocity = Vector3.new(0, 0, -60),
			Timestamp = env.Now(),
		})
		assertTrue(not selfHit.Triggered and selfHit.RejectReason == "SelfVehicleCollision", "Self-vehicle part collision is rejected cleanly")

		-- Colisión entre Vehículo A y Vehículo B usando masa real del otro vehículo
		local partB = rt2.Parts[ids2.FrontBumperId].PrimaryPart
		local v1Hit = VehicleImpactService.EvaluateImpact(rt1, {
			PieceId = ids1.FrontBumperId,
			StruckPart = rt1.Parts[ids1.FrontBumperId].PrimaryPart,
			OtherPart = partB,
			SourceType = "VehicleRuntime",
			OtherVehicleRuntimeId = rt2.RuntimeId,
			OtherUserId = p2.UserId,
			OtherPieceId = ids2.FrontBumperId,
			OtherMass = rt2.TotalMass,
			OtherIsStatic = false,
			RelativeVelocity = Vector3.new(0, 0, 55),
			ImpactNormal = Vector3.new(0, 0, 1),
			Timestamp = env.AdvanceClock(1),
		})
		local v2Hit = VehicleImpactService.EvaluateImpact(rt2, {
			PieceId = ids2.FrontBumperId,
			StruckPart = partB,
			OtherPart = rt1.Parts[ids1.FrontBumperId].PrimaryPart,
			SourceType = "VehicleRuntime",
			OtherVehicleRuntimeId = rt1.RuntimeId,
			OtherUserId = p1.UserId,
			OtherPieceId = ids1.FrontBumperId,
			OtherMass = rt1.TotalMass,
			OtherIsStatic = false,
			RelativeVelocity = Vector3.new(0, 0, -55),
			ImpactNormal = Vector3.new(0, 0, -1),
			Timestamp = env.Now(),
		})

		assertTrue(v1Hit.Triggered and v2Hit.Triggered, "Vehicle-to-vehicle impacts apply to both vehicles independently")
		local recA = VehicleDamageService.GetPieceHealth(rt1, ids1.FrontBumperId) :: VehicleTypes.PieceDamageRecord
		local recB = VehicleDamageService.GetPieceHealth(rt2, ids2.FrontBumperId) :: VehicleTypes.PieceDamageRecord
		assertTrue(recA.CurrentHealth < recA.MaxHealth and recB.CurrentHealth < recB.MaxHealth, "Both vehicles took localized front impact damage")

		env.Teardown()
	end)

	-- 10) Strict player isolation
	runTest("Fase 4.1 [10]: Damage on one player's vehicle never leaks or mutates another player's vehicle", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41011, Name = "P41_IsoA" }
		local p2: PlotService.PlayerLike = { UserId = 41012, Name = "P41_IsoB" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)

		local ids1 = buildLinearTestVehicle(p1, "t10a", { IncludeEngine = true })
		local ids2 = buildLinearTestVehicle(p2, "t10b", { IncludeEngine = true })

		local lr1 = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		local lr2 = VehicleLaunchService.LaunchVehicle(p2, { SkipWorldObstructionCheck = true, MountDriver = false })
		local rt1 = lr1.Runtime :: VehicleTypes.VehicleRuntime
		local rt2 = lr2.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		VehicleDamageService.ApplyImpact(rt1, ids1.FrontBumperId, {
			SourceType = "StaticObstacle",
			DamageAmount = 90,
			Timestamp = env.AdvanceClock(1),
		})

		local sum1 = VehicleDamageService.GetVehicleHealthSummary(rt1) :: VehicleTypes.VehicleHealthSummary
		local sum2 = VehicleDamageService.GetVehicleHealthSummary(rt2) :: VehicleTypes.VehicleHealthSummary
		assertTrue(sum1.TotalDamageReceived > 0 and sum1.IntegrityPercent < 100, "Player 1 suffered damage")
		assertEqual(sum2.TotalDamageReceived, 0, "Player 2 received strictly 0 damage")
		assertNear(sum2.IntegrityPercent, 100, 1e-4, "Player 2 remains at 100% integrity")
		assertEqual((VehicleDamageService.GetPieceHealth(rt2, ids2.FrontBumperId) :: VehicleTypes.PieceDamageRecord).State, DamageConfig.PieceStates.Healthy, "Player 2 piece remains Healthy")

		env.Teardown()
	end)

	-- 11) ResetVehicle & ReturnToWorkshop restore 100% HP
	runTest("Fase 4.1 [11]: ResetVehicle and ReturnToWorkshop + relaunch restore every piece to 100% health", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41013, Name = "P41_Reset" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t11", { IncludeEngine = true, IncludeWheels = true })
		local lr1 = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		local rt1 = lr1.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		-- Destruir completamente front bumper y dañar asiento
		VehicleDamageService.ApplyImpact(rt1, ids.FrontBumperId, { DamageAmount = 200, Timestamp = env.AdvanceClock(1) })
		assertEqual((VehicleDamageService.GetPieceHealth(rt1, ids.FrontBumperId) :: VehicleTypes.PieceDamageRecord).State, DamageConfig.PieceStates.Disabled, "Front bumper Disabled before ResetVehicle")

		-- ResetVehicle genera nuevo runtime con 100% de salud sin tocar blueprint
		env.AdvanceClock(2.0)
		local resetRes = VehicleLaunchService.ResetVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(resetRes.Success and resetRes.Runtime ~= nil, `ResetVehicle failed: {tostring(resetRes.ErrorCode)}`)
		local rtAfterReset = resetRes.Runtime :: VehicleTypes.VehicleRuntime
		assertTrue(rtAfterReset.RuntimeId ~= rt1.RuntimeId, "ResetVehicle produced a fresh VehicleRuntimeId")

		local resetSum = VehicleDamageService.GetVehicleHealthSummary(rtAfterReset) :: VehicleTypes.VehicleHealthSummary
		assertEqual(resetSum.DisabledCount, 0, "DisabledCount reset to 0 after ResetVehicle")
		assertEqual(resetSum.DamagedCount, 0, "DamagedCount reset to 0 after ResetVehicle")
		assertEqual(resetSum.ImpactCount, 0, "ImpactCount reset to 0 after ResetVehicle")
		assertNear(resetSum.IntegrityPercent, 100, 1e-4, "IntegrityPercent restored to 100% after ResetVehicle")

		-- Dañar nuevamente, volver al taller y relanzar
		VehicleDamageService.ApplyImpact(rtAfterReset, ids.FrontBumperId, { DamageAmount = 50, Timestamp = env.AdvanceClock(1) })
		assertTrue((VehicleDamageService.GetVehicleHealthSummary(rtAfterReset) :: VehicleTypes.VehicleHealthSummary).TotalDamageReceived > 0, "Damage recorded before ReturnToWorkshop")

		local retRes = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(retRes.Success, "ReturnToWorkshop succeeds")
		env.AdvanceClock(2.0)

		local lr2 = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr2.Success and lr2.Runtime ~= nil, "Relaunch succeeds")
		local rt2 = lr2.Runtime :: VehicleTypes.VehicleRuntime
		local frontRelaunch = VehicleDamageService.GetPieceHealth(rt2, ids.FrontBumperId) :: VehicleTypes.PieceDamageRecord
		assertEqual(frontRelaunch.CurrentHealth, frontRelaunch.MaxHealth, "Front bumper restored to MaxHealth after ReturnToWorkshop + relaunch")
		assertEqual(frontRelaunch.DamageReceivedTotal, 0, "DamageReceivedTotal resets to 0 on fresh launch")

		env.Teardown()
	end)

	-- 12) Blueprint & inventory strict persistence separation
	runTest("Fase 4.1 [12]: Original Blueprint and Engine/Booster inventories never persist runtime damage or health fields", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41014, Name = "P41_Persistence" }
		PlotService.Assign(p1)

		local engUnit = EngineInventoryService.RegisterUnitForTesting(p1, {
			ItemInstanceId = "eng_persist_41",
			EngineSizeId = "Small",
			VariantId = "Industrial",
			RarityId = "Rare",
		})
		local bstUnit = BoosterInventoryService.RegisterUnitForTesting(p1, {
			ItemInstanceId = "bst_persist_41",
			BoosterFamilyId = "Solid",
			BoosterSizeId = "Small",
			VariantId = "HighImpulse",
			RarityId = "Epic",
		})

		local ids = buildLinearTestVehicle(p1, "t12", {
			IncludeEngine = true,
			EngineUnitId = engUnit.ItemInstanceId,
			IncludeFuelTank = true,
			IncludeBooster = true,
			BoosterUnitId = bstUnit.ItemInstanceId,
			IncludeNitroTank = true,
			IncludeWheels = true,
		})

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		-- Dañar motor, booster y bloques
		VehicleDamageService.ApplyImpact(rt, ids.EngineId :: string, { DamageAmount = 500, Timestamp = env.AdvanceClock(1) })
		VehicleDamageService.ApplyImpact(rt, ids.BoosterId :: string, { DamageAmount = 500, Timestamp = env.AdvanceClock(1) })
		VehicleDamageService.ApplyImpact(rt, ids.FrontBumperId, { DamageAmount = 500, Timestamp = env.AdvanceClock(1) })

		VehicleLaunchService.ReturnToWorkshop(p1)

		local bpSnap = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local forbiddenKeys = {
			"CurrentHealth",
			"MaxHealth",
			"HealthState",
			"DamageReceivedTotal",
			"ImpactCount",
			"CurrentDurability",
			"IsDetached",
		}
		for _, piece in ipairs(bpSnap.Pieces) do
			local asAny = piece :: any
			for _, key in ipairs(forbiddenKeys) do
				assertEqual(asAny[key], nil, `Blueprint piece {piece.InstanceId} must not contain runtime field '{key}'`)
			end
		end

		local encoded = HttpService:JSONEncode(BlueprintSerializer.SerializeBlueprint(bpSnap))
		for _, key in ipairs(forbiddenKeys) do
			assertTrue(string.find(encoded, key, 1, true) == nil, `Serialized blueprint must not contain '{key}'`)
		end

		local engAfter = EngineInventoryService.GetUnitById(engUnit.ItemInstanceId) :: any
		local bstAfter = BoosterInventoryService.GetUnitById(bstUnit.ItemInstanceId) :: any
		assertTrue(engAfter ~= nil and bstAfter ~= nil, "Engine and Booster inventory units remain registered")
		assertEqual(engAfter.CurrentHealth, nil, "Engine inventory unit has no runtime CurrentHealth")
		assertEqual(bstAfter.CurrentHealth, nil, "Booster inventory unit has no runtime CurrentHealth")

		env.Teardown()
	end)

	-- 13) Zero connection/runtime leaks on ReturnToWorkshop, DestroyRuntimeForPlayer & external destroy
	runTest("Fase 4.1 [13]: ReturnToWorkshop, DestroyRuntime and RootModel:Destroy cleanly release 100% of listeners and indexes", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41015, Name = "P41_Leaks" }
		PlotService.Assign(p1)

		buildLinearTestVehicle(p1, "t13", { IncludeEngine = true, IncludeBooster = true, IncludeWheels = true })

		-- Ciclo 1: Launch + ReturnToWorkshop
		local lr1 = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr1.Success, "Launch 1 succeeds")
		assertTrue(VehicleImpactService.GetTrackedConnectionCount() > 0, "Touched connections active while driving")
		assertEqual(VehicleImpactService.GetActiveVehicleCount(), 1, "1 vehicle active in VehicleImpactService")
		assertEqual(VehicleDamageService.GetRegisteredRuntimeCount(), 1, "1 runtime active in VehicleDamageService")

		VehicleLaunchService.ReturnToWorkshop(p1)
		assertEqual(VehicleImpactService.GetTrackedConnectionCount(), 0, "0 Touched connections remain after ReturnToWorkshop")
		assertEqual(VehicleImpactService.GetActiveVehicleCount(), 0, "0 active vehicles remain in VehicleImpactService")
		assertEqual(VehicleImpactService.GetActivePartIndexCount(), 0, "0 active part indexes remain in VehicleImpactService")
		assertEqual(VehicleDamageService.GetRegisteredRuntimeCount(), 0, "0 runtimes remain in VehicleDamageService")

		-- Ciclo 2: Launch + destrucción externa del RootModel (simula fallback Workspace cleanup)
		env.AdvanceClock(2.0)
		local lr2 = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		local rt2 = lr2.Runtime :: VehicleTypes.VehicleRuntime
		assertTrue(VehicleImpactService.GetTrackedConnectionCount() > 0, "Connections active again on relaunch")

		rt2.RootModel:Destroy()
		VehicleRuntimeService.DestroyRuntimeForPlayer(p1, "TestExternalDestroy")
		assertEqual(VehicleImpactService.GetTrackedConnectionCount(), 0, "0 connections leaked after external RootModel destruction")
		assertEqual(VehicleDamageService.GetRegisteredRuntimeCount(), 0, "0 damage runtimes leaked")

		env.Teardown()
	end)

	-- 14) Wheeled vehicle compatibility & intact WheelConstraints after impacts
	runTest("Fase 4.1 [14]: Wheeled vehicle keeps Steering/Suspension/Constraints intact after wheel impact", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41016, Name = "P41_Wheels" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t14", { IncludeEngine = true, IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		local wheelHit = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.WheelIds[1],
			SourceType = "StaticObstacle",
			OtherName = "Curb",
			OtherTargetKey = "Curb_Wheel",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(-28, 0, 28),
			ImpactNormal = Vector3.new(-0.5, 0, 0.866),
			Timestamp = env.AdvanceClock(1),
		})
		assertTrue(wheelHit.Triggered, "Front wheel registered curb impact")

		-- WheelConstraints siguen vivas y controlables
		local initialConstraints = #(rt.WheelConstraints or {})
		assertTrue(initialConstraints > 0, "WheelConstraints exist")
		for _, c in ipairs(rt.WheelConstraints or {}) do
			assertTrue(c.Parent ~= nil, `Constraint {c.Name} remains parented after Phase 4.1 wheel damage`)
		end

		for _ = 1, 10 do
			VehiclePowertrainService.StepAll(1 / 60)
			VehicleWheelControllerService.StepAll(1 / 60)
		end
		assertEqual(rt.Parts[ids.WheelIds[1]].IsFunctional, true, "Wheel stays functional in Phase 4.1")

		env.Teardown()
	end)

	-- 15) Booster-only vehicle compatibility
	runTest("Fase 4.1 [15]: Booster-only vehicle without engines launches, tracks nitro/booster health and absorbs impacts", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41017, Name = "P41_BoosterOnly" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t15", {
			IncludeEngine = false,
			IncludeBooster = true,
			IncludeNitroTank = true,
			IncludeWheels = true,
			FreeWheels = true,
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success and lr.Runtime ~= nil, "Booster-only vehicle launches validly")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		for _ = 1, 10 do
			VehicleBoosterService.StepAll(1 / 60)
		end

		local bstHit = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = ids.BoosterId :: string,
			SourceType = "StaticObstacle",
			OtherName = "RearPost",
			OtherTargetKey = "RearPost",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 0, -42),
			ImpactNormal = Vector3.new(0, 0, -1),
			Timestamp = env.AdvanceClock(1),
		})
		assertTrue(bstHit.Triggered, "Booster took localized rear impact")
		local bstRec = VehicleDamageService.GetPieceHealth(rt, ids.BoosterId :: string) :: VehicleTypes.PieceDamageRecord
		assertTrue(bstRec.CurrentHealth < bstRec.MaxHealth, "Booster health reduced cleanly")
		local bstState = VehicleBoosterService.GetBoosterState(p1)
		local bstPart = rt.Parts[ids.BoosterId :: string].PrimaryPart
		assertTrue(
			bstState ~= nil
				and bstState.BoosterCount == 1
				and rt.BoosterPieceIds ~= nil
				and #rt.BoosterPieceIds == 1
				and bstPart ~= nil
				and bstPart:FindFirstChildOfClass("VectorForce") ~= nil,
			"Booster constraints/state remain valid"
		)

		env.Teardown()
	end)

	-- 16) Hybrid vehicle (Engine + FuelTank + Booster + NitroTank + Wheels): zero degradation rule in 4.1
	runTest("Fase 4.1 [16]: Hybrid Engine+Booster vehicle retains 100% performance and all welds after Phase 4.1 structural damage", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41018, Name = "P41_Hybrid" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t16", {
			IncludeEngine = true,
			IncludeFuelTank = true,
			IncludeBooster = true,
			IncludeNitroTank = true,
			IncludeWheels = true,
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1, Boost = true })
		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		for _ = 1, 5 do
			VehiclePowertrainService.StepAll(1 / 60)
			VehicleBoosterService.StepAll(1 / 60)
		end
		local ptBefore = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local bsBefore = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot

		-- Dañar parcialmente (>0 HP) motor y booster: sin degradación parcial de rendimiento antes de llegar a 0 HP
		VehicleDamageService.ApplyImpact(rt, ids.EngineId :: string, { DamageAmount = 60, Timestamp = env.AdvanceClock(1) })
		VehicleDamageService.ApplyImpact(rt, ids.BoosterId :: string, { DamageAmount = 60, Timestamp = env.AdvanceClock(1) })
		VehiclePowertrainService.StepAll(1 / 60)
		VehicleBoosterService.StepAll(1 / 60)

		local ptAfter = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local bsAfter = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		local engSlot = VehiclePowertrainService.GetEngineState(p1, ids.EngineId :: string) :: VehicleTypes.EngineRuntimeState
		local bstSlot = VehicleBoosterService.GetBoosterSlotState(p1, ids.BoosterId :: string) :: VehicleTypes.BoosterRuntimeState

		assertEqual(engSlot.IsFunctional, true, "Damaged (>0 HP) Engine keeps IsFunctional == true")
		assertNear(engSlot.DurabilityEfficiencyFactor, 1.0, 1e-4, "Damaged (>0 HP) Engine keeps DurabilityEfficiencyFactor == 1.0")
		assertTrue(ptAfter.TotalEngineTorque >= ptBefore.TotalEngineTorque * 0.99, "Damaged (>0 HP) Engine preserves 100% TotalEngineTorque")
		assertTrue(ptAfter.TotalWheelDriveTorque >= ptBefore.TotalWheelDriveTorque * 0.99, "Damaged (>0 HP) Engine preserves 100% WheelDriveTorque")
		assertEqual(bstSlot.IsFunctional, true, "Damaged (>0 HP) Booster keeps IsFunctional == true")
		assertNear(bstSlot.DurabilityEfficiencyFactor, 1.0, 1e-4, "Damaged (>0 HP) Booster keeps DurabilityEfficiencyFactor == 1.0")
		assertNear(bsAfter.MaxPossibleThrust, bsBefore.MaxPossibleThrust, 1e-2, "Damaged (>0 HP) Booster preserves 100% thrust")
		assertEqual((VehicleDamageService.GetPieceHealth(rt, ids.EngineId :: string) :: VehicleTypes.PieceDamageRecord).State, DamageConfig.PieceStates.Damaged, "Engine HealthState tracks Damaged accurately")

		env.Teardown()
	end)

	-- 17-18) 500 pieces limit + reject 501st piece + damage & clean 0-leak teardown
	runTest("Fase 4.1 [17-18]: 500-piece vehicle launches cleanly, initializes 500 health records, cleans up to 0 and blocks piece #501", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41019, Name = "P41_500Max" }
		PlotService.Assign(p1)

		-- Construir serpentina 10x10x5 (499 WoodBlocks + 1 DriverSeat en capa superior = 500 piezas exactas)
		local lastPos = Vector3.new(-8, 10.5, 10)
		local cornerId = ""
		local countPlaced = 0
		for layer = 0, 4 do
			local y = 2.5 + layer * 2.0
			local zStart = if layer % 2 == 0 then 0 else 9
			local zEnd = if layer % 2 == 0 then 9 else 0
			local zStep = if layer % 2 == 0 then 1 else -1
			for lz = zStart, zEnd, zStep do
				for ix = 0, 9 do
					countPlaced += 1
					local actualIx = if (lz % 2 == layer % 2) then ix else (9 - ix)
					local pos = Vector3.new(-8 + actualIx * 2, y, -8 + lz * 2)
					if countPlaced < GameConfig.Building.MaxPiecesPerVehicle then
						local placedId = placePieceReq(p1, `p500_{countPlaced}`, "WoodBlock", CFrame.new(pos))
						if countPlaced == 1 then
							cornerId = placedId
						end
					else
						lastPos = pos
					end
				end
			end
		end
		local seatId = placePieceReq(p1, "p500_seat", "DriverSeat", CFrame.new(lastPos.X, lastPos.Y - 0.5, lastPos.Z))
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(p1).Pieces, 500, "Blueprint reached exact 500-piece limit")

		-- 18: Rechazar pieza #501
		local overRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "p500_over_501",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(-8, 12.5, 8),
		})
		assertTrue(
			not overRes.Success and overRes.ErrorCode == BuildProtocol.ErrorCodes.MaxPiecesReached,
			`501st piece rejected with MaxPiecesReached, got {tostring(overRes.ErrorCode)}`
		)

		-- 17: Lanzar vehículo de 500 piezas y validar daño + cleanup
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		assertTrue(lr.Success and lr.Runtime ~= nil, `500-piece launch failed: {tostring(lr.ErrorCode)}`)
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		local summary = VehicleDamageService.GetVehicleHealthSummary(rt) :: VehicleTypes.VehicleHealthSummary
		assertEqual(summary.TotalPieces, 500, "VehicleDamageService registered all 500 pieces")
		local trackedConns = VehicleImpactService.GetTrackedConnectionCount()
		assertTrue(trackedConns >= 500 and trackedConns <= 510, `Tracked Touched connections bounded per collidable part (~500, got {trackedConns})`)

		local impactRes = VehicleImpactService.EvaluateImpact(rt, {
			PieceId = cornerId,
			SourceType = "StaticObstacle",
			OtherName = "MegaWall",
			OtherTargetKey = "MegaWall_500",
			OtherIsStatic = true,
			RelativeVelocity = Vector3.new(0, 0, 52),
			ImpactNormal = Vector3.new(0, 0, 1),
			Timestamp = env.Now(),
		})
		assertTrue(impactRes.Triggered, "Impact processed on 500-piece vehicle")
		assertEqual((VehicleDamageService.GetPieceHealth(rt, seatId) :: VehicleTypes.PieceDamageRecord).CurrentHealth, 300, "Far DriverSeat unaffected by opposite corner impact")

		VehicleLaunchService.ReturnToWorkshop(p1)
		assertEqual(VehicleImpactService.GetTrackedConnectionCount(), 0, "0 connections leaked after returning 500-piece vehicle")
		assertEqual(VehicleDamageService.GetRegisteredRuntimeCount(), 0, "0 runtimes remain")

		env.Teardown()
	end)

	-- 19) DriverSeat max 1 per vehicle enforced at LaunchPrep/Assembly
	runTest("Fase 4.1 [19]: Enforces strictly 1 DriverSeat per vehicle while preserving PassengerSeat role support", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41020, Name = "P41_DriverSeatCap" }
		local plot1 = PlotService.Assign(p1) :: PlotService.PlotRecord

		placePieceReq(p1, "ds_b0", "WoodBlock", CFrame.new(0, 2.5, 0))
		placePieceReq(p1, "ds_b1", "WoodBlock", CFrame.new(2, 2.5, 0))
		placePieceReq(p1, "ds_seat1", "DriverSeat", CFrame.new(0, 4.0, 0))
		local secondRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "ds_seat2",
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(2, 4.0, 0),
		})
		assertEqual(secondRes.Success, false, "Workshop blocks 2nd DriverSeat via PlacePiece")
		assertEqual(secondRes.ErrorCode, BuildProtocol.ErrorCodes.TooManyDriverSeats, "Returns TooManyDriverSeats")

		local twoSeatBp: VehicleTypes.VehicleBlueprint = {
			SchemaVersion = 2,
			BlueprintId = "bp_p41_two_seats",
			OwnerUserId = p1.UserId,
			Name = "TwoSeatCheck",
			Revision = 1,
			CreatedAt = 100,
			UpdatedAt = 100,
			VehicleOrigin = CFrame.identity,
			Presentation = { HeightOffset = 0, LateralOffset = 0 },
			Pieces = {
				{ InstanceId = "ds_b0", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 2.5, 0) },
				{ InstanceId = "ds_b1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(2, 2.5, 0) },
				{ InstanceId = "ds_seat1", ItemId = "DriverSeat", LocalCFrame = CFrame.new(0, 4.0, 0) },
				{ InstanceId = "ds_seat2", ItemId = "DriverSeat", LocalCFrame = CFrame.new(2, 4.0, 0) },
			},
			Connections = {},
		}
		ConnectionService.ReconcileBlueprintConnections(twoSeatBp)
		local prep = VehicleLaunchPreparationService.EvaluateBlueprintLaunch(twoSeatBp, plot1, { SkipWorldObstructionCheck = true })
		assertTrue(not prep.Ready, "Vehicle with 2 DriverSeats cannot launch")
		assertEqual(prep.PrimaryErrorCode, "MultipleDriverSeats", "PrimaryErrorCode is MultipleDriverSeats")
		assertEqual(GameConfig.Runtime.PartRoles.PassengerSeat, "PassengerSeat", "GameConfig exposes distinct PassengerSeat physics role")

		env.Teardown()
	end)

	-- 20) 10 concurrent players impact isolation & full cleanup
	runTest("Fase 4.1 [20]: 10 simultaneous player vehicles take independent damage and release 100% of resources on cleanup", function()
		local env = setupIsolatedWorld(10)
		local players: { PlotService.PlayerLike } = {}
		local frontIds: { [number]: string } = {}
		local runtimes: { VehicleTypes.VehicleRuntime } = {}

		for i = 1, 10 do
			local p: PlotService.PlayerLike = { UserId = 42000 + i, Name = `P41_10P_{i}` }
			players[i] = p
			PlotService.Assign(p)
			local ids = buildLinearTestVehicle(p, `ten_{i}`, { IncludeEngine = true, IncludeBooster = true, IncludeWheels = true })
			frontIds[i] = ids.FrontBumperId
			local lr = VehicleLaunchService.LaunchVehicle(p, { SkipWorldObstructionCheck = true, MountDriver = false })
			assertTrue(lr.Success and lr.Runtime ~= nil, `10-player launch failed for #{i}`)
			runtimes[i] = lr.Runtime :: VehicleTypes.VehicleRuntime
		end

		assertEqual(VehicleDamageService.GetRegisteredRuntimeCount(), 10, "10 damage runtimes active simultaneously")
		assertEqual(VehicleImpactService.GetActiveVehicleCount(), 10, "10 impact orchestrators active simultaneously")
		assertTrue(VehicleImpactService.GetTrackedConnectionCount() >= 130, "Touched listeners active for all 10 vehicles")

		env.AdvanceClock(2.0)

		-- Dañar en intensidades distintas jugadores 1..5 y dejar ilesos 6..10
		for i = 1, 5 do
			local res = VehicleImpactService.EvaluateImpact(runtimes[i], {
				PieceId = frontIds[i],
				SourceType = "StaticObstacle",
				OtherName = `Wall_{i}`,
				OtherTargetKey = `Wall_{i}`,
				OtherIsStatic = true,
				RelativeVelocity = Vector3.new(0, 0, 25 + i * 10),
				ImpactNormal = Vector3.new(0, 0, 1),
				Timestamp = env.Now(),
			})
			assertTrue(res.Triggered, `Player #{i} hit registered`)
		end

		local prevDamage = 0
		for i = 1, 5 do
			local dmg = (VehicleDamageService.GetPieceHealth(runtimes[i], frontIds[i]) :: VehicleTypes.PieceDamageRecord).DamageReceivedTotal
			assertTrue(dmg >= prevDamage, `Player #{i} damage monotonic with higher impact speed`)
			prevDamage = dmg
		end
		for i = 6, 10 do
			local sum = VehicleDamageService.GetVehicleHealthSummary(runtimes[i]) :: VehicleTypes.VehicleHealthSummary
			assertNear(sum.IntegrityPercent, 100, 1e-4, `Unaffected Player #{i} remains at 100% integrity`)
		end

		-- Retorno escalonado de todos los jugadores
		for i = 1, 10 do
			VehicleLaunchService.ReturnToWorkshop(players[i])
		end

		assertEqual(VehicleDamageService.GetRegisteredRuntimeCount(), 0, "0 damage runtimes after all 10 return")
		assertEqual(VehicleImpactService.GetActiveVehicleCount(), 0, "0 impact vehicles after all 10 return")
		assertEqual(VehicleImpactService.GetTrackedConnectionCount(), 0, "0 Touched connections remain after all 10 return")
		assertEqual(VehicleImpactService.GetActivePartIndexCount(), 0, "0 part indexes remain after all 10 return")

		env.Teardown()
	end)

	-- 21) SDD ApplyImpact contract + Dev-only debug tool strict authorization
	runTest("Fase 4.1 [21]: SDD ApplyImpact returns full contract and Dev-only test damage blocks unauthorized players", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 41030, Name = "P41_DevAuth" }
		local normalUser: PlotService.PlayerLike = { UserId = 41031, Name = "P41_NormalUser" }
		PlotService.Assign(p1)

		local ids = buildLinearTestVehicle(p1, "t21", { IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		-- Probar autorización estricta Dev-only desactivando whitelist Studio abierta para mocks
		VehicleDamageService.SetDevDebugMode(true)
		VehicleDamageService.SetDevAuthorizedUserIds({ 999999 }, false)

		local denied = VehicleDamageService.ApplyTestDamage(normalUser, rt, ids.FrontBumperId, 50, "ExploitAttempt")
		assertTrue(not denied.Applied and denied.Reason == "UnauthorizedDevTool", "Normal unauthorized user rejected by ApplyTestDamage")

		local allowed = VehicleDamageService.ApplyTestDamage(nil, rt, ids.FrontBumperId, 200, "VerifiedServerDevTest")
		assertTrue(allowed.Applied, "Authoritative server test call succeeds when debug mode enabled")
		assertEqual(allowed.RuntimeId, rt.RuntimeId, "SDD ApplyImpact returns RuntimeId")
		assertEqual(allowed.PrimaryPieceId, ids.FrontBumperId, "SDD ApplyImpact returns PrimaryPieceId")
		assertEqual(allowed.NewDurability, allowed.NewHealth, "SDD NewDurability matches NewHealth")
		assertTrue(table.find(allowed.BrokenParts, ids.FrontBumperId) ~= nil, "BrokenParts includes 0-HP PrimaryPieceId")
		assertTrue(table.find(allowed.DetachedParts, ids.FrontBumperId) ~= nil, "DetachedParts includes 0-HP PrimaryPieceId in Phase 4.2")

		local report = VehicleDamageService.GetDebugReport(rt)
		assertTrue(report ~= nil and #(report :: any).RecentImpacts >= 1, "Debug report records authorized impact")

		VehicleDamageService.SetDevDebugMode(false)
		assertEqual(VehicleDamageService.GetDebugReport(rt), nil, "GetDebugReport returns nil when dev debug mode disabled")

		env.Teardown()
	end)

	-- 22) Live Roblox Studio physics Touched crash validation (active when RunService:IsRunning())
	runTest("Fase 4.1 [22]: Live Workspace physics Touched pipeline records real collision damage cleanly", function()
		if not RunService:IsRunning() then
			-- En Edit mode donde Simulation no avanza automáticamente, validar cálculo DamageMath de caída
			local kin = DamageMath.EvaluateImpactKinematics({
				RelativeVelocity = Vector3.new(0, 45, 0),
				ImpactNormal = Vector3.new(0, 1, 0),
				StruckMass = 80,
				OtherIsStatic = true,
				TimeSinceLaunchSeconds = 2.0,
			})
			assertTrue(kin.PassesThreshold and kin.NormalSpeed >= 44, "Physics drop kinematics pass impact threshold")
			return
		end

		local customSpawns = Instance.new("Folder")
		customSpawns.Name = "_Phase41LiveCrashSpawns"
		customSpawns.Parent = Workspace
		local sp1 = Instance.new("Part")
		sp1.Name = "Plot_Live01"
		sp1.Anchored = true
		sp1.CanCollide = false
		sp1.CanTouch = false
		sp1.CanQuery = false
		sp1.Transparency = 1
		sp1.Position = Vector3.new(2400, 0, 0)
		sp1.Parent = customSpawns

		local env = setupIsolatedWorld(1, customSpawns)
		local p1: PlotService.PlayerLike = { UserId = 41032, Name = "P41_LiveCrash" }
		PlotService.Assign(p1)

		buildLinearTestVehicle(p1, "t22", { IncludeEngine = true, IncludeWheels = true })
		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assertTrue(lr.Success and lr.Runtime ~= nil, "Live test vehicle launched")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		-- Esperar ventana de asentamiento real
		task.wait(DamageConfig.Impact.LaunchSettlingGraceSeconds + 0.15)
		env.AdvanceClock(1.0)

		-- Crear un muro anclado físico justo adelante de la defensa para simular choque real
		local seatPart = rt.DriverSeatPart :: VehicleSeat
		local forward = seatPart.CFrame.LookVector
		local barrier = Instance.new("Part")
		barrier.Name = "_P41_TestBarrier"
		barrier.Anchored = true
		barrier.CanCollide = true
		barrier.CanTouch = true
		barrier.Size = Vector3.new(20, 16, 4)
		barrier.CFrame = CFrame.lookAt(seatPart.Position + forward * 14, seatPart.Position)
		barrier.Parent = Workspace

		local deadline = os.clock() + 1.5
		local damageObserved = false
		while os.clock() < deadline do
			for _, partState in pairs(rt.Parts) do
				local pp = partState.PrimaryPart
				if pp and pp.Parent then
					pp.AssemblyLinearVelocity = forward * 65
				end
			end
			task.wait(0.05)
			local sum = VehicleDamageService.GetVehicleHealthSummary(rt)
			if sum and sum.ImpactCount >= 1 and sum.TotalDamageReceived > 0 then
				damageObserved = true
				break
			end
		end

		barrier:Destroy()
		assertTrue(damageObserved, "Live Roblox physics Touched event triggered authoritative Phase 4.1 damage")

		VehicleLaunchService.ReturnToWorkshop(p1)
		assertEqual(VehicleImpactService.GetTrackedConnectionCount(), 0, "Live test cleanup left 0 Touched connections")

		env.Teardown()
		customSpawns:Destroy()
	end)
end

function Phase41Tests.RunStandalone()
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
			pcall(VehicleDamageService._ResetForTests)
			pcall(VehicleImpactService._ResetForTests)
			pcall(VehicleRuntimeService._ResetForTests)
		end
	end

	Phase41Tests.AppendTests(results, runTest)
	return {
		Passed = passedCount,
		Failed = failedCount,
		Total = #results,
		Results = results,
	}
end

return Phase41Tests
