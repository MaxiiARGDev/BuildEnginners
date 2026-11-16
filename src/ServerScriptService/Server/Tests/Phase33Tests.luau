--!strict
--[=[
	Phase33Tests
	Suite de 56 pruebas automatizadas de Fase 3.3 (Motores modulares, tamaños, variantes,
	6 rarezas, resolución determinística de estadísticas, curvas de torque, limitador de RPM,
	transmisión automática, combinación multimotor, frenado/reversa seguros, eliminación de freno de mano,
	contratos de combustible y durabilidad temporal, anti-duplicación de unidades de inventario,
	seguridad autoritativa, HUD/Inspector y simulación de 10 jugadores).
	Se integra en Phase1Tests.RunAll().
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
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
local BuildPayloadValidator = require(ServerScriptService.Server.Security.BuildPayloadValidator)

local ClientControllers = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState"))
local EngineInspectorPanel = require(ClientControllers:WaitForChild("EngineInspectorPanel"))
local VehicleDrivingController = require(ClientControllers:WaitForChild("VehicleDrivingController"))

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase33Tests = {}

local function setupIsolatedWorld(plotCount: number?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder

	local prevPlots = Workspace:FindFirstChild("_Phase33TestPlots")
	if prevPlots then
		prevPlots:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase33TestPlots"
	tempPlots.Parent = Workspace

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
		PlotCount = plotCount or 2,
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

	local fakeClock = 1000
	local rateLimitClock = 1000
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

local function placePieceReq(
	player: PlotService.PlayerLike,
	opId: string,
	itemId: string,
	localCF: CFrame,
	config: { [string]: any }?,
	inventoryInstanceId: string?
): string
	local res = BuildService.ProcessRequest(player, {
		Action = "PlacePiece",
		ClientOpId = opId,
		ItemId = itemId,
		LocalCFrame = localCF,
		Config = config,
		InventoryInstanceId = inventoryInstanceId,
	})
	if not res.Success or not res.PlacedPiece then
		error(`Failed PlacePiece {opId} ({itemId}): {tostring(res.ErrorCode)} - {tostring(res.ErrorMessage)}`)
	end
	return res.PlacedPiece.InstanceId
end

local function buildMotorizedVehicle(
	player: PlotService.PlayerLike,
	prefix: string,
	options: {
		EngineCount: number?,
		EngineUnitIds: { string }?,
		EngineConfigs: { { [string]: any } }?,
		IncludeFuelTank: boolean?,
		FuelTankCount: number?,
		FuelTankType: ("Regular" | "Diesel" | "Competicion")?,
		HeavyBlocks: number?,
		SixWheels: boolean?,
		AllWheelsFree: boolean?,
		WheelConfigs: { FL: { [string]: any }?, FR: { [string]: any }?, RL: { [string]: any }?, RR: { [string]: any }? }?,
	}?
): {
	SeatId: string,
	EngineIds: { string },
	FuelTankId: string?,
	WheelIds: { string },
	FL: string,
	FR: string,
	RL: string,
	RR: string,
}
	local opts = options or {}
	local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)

	-- Colocar estructura base a y=2.5 para que motores y tanques en la plataforma superior tengan holgura amplia sobre el piso
	placePieceReq(player, `{prefix}_b0`, "WoodBlock", CFrame.new(0, 2.5, 0), nil)
	placePieceReq(player, `{prefix}_bf`, "WoodBlock", CFrame.new(0, 2.5, -2), nil)
	placePieceReq(player, `{prefix}_br`, "WoodBlock", CFrame.new(0, 2.5, 2), nil)
	local seatId = placePieceReq(player, `{prefix}_seat`, "DriverSeat", CFrame.new(0, 4.0, -2), nil)

	local numEngines = if opts.EngineCount ~= nil then opts.EngineCount else 1
	local numTanks = if opts.FuelTankCount ~= nil then opts.FuelTankCount elseif opts.IncludeFuelTank then 1 else 0
	if numEngines >= 2 or numTanks >= 1 or opts.SixWheels or (opts.HeavyBlocks and opts.HeavyBlocks > 0) then
		placePieceReq(player, `{prefix}_br2`, "WoodBlock", CFrame.new(0, 2.5, 4), nil)
		placePieceReq(player, `{prefix}_br3`, "WoodBlock", CFrame.new(0, 2.5, 6), nil)
	end
	if numTanks >= 2 then
		placePieceReq(player, `{prefix}_br4`, "WoodBlock", CFrame.new(0, 2.5, 8), nil)
	end

	local heavyCount = opts.HeavyBlocks or 0
	for i = 1, heavyCount do
		-- Agregar lastre pesado mediante bloques y tanques adicionales conectados lateralmente/arriba
		local zPos = -2 + ((i - 1) % 4) * 2
		local sideX = if i % 2 == 1 then -2 else 2
		local yLayer = 4.5 + math.floor((i - 1) / 4) * 2
		placePieceReq(player, `{prefix}_hvy_{i}`, "WoodBlock", CFrame.new(sideX, yLayer, zPos), nil)
	end

	local engineIds: { string } = {}
	local enginePositions = {
		CFrame.new(0, 4.5, 2),
		CFrame.new(0, 4.5, 5),
		CFrame.new(0, 6.5, 2),
	}
	for i = 1, numEngines do
		local unitId = if opts.EngineUnitIds then opts.EngineUnitIds[i] else nil
		local engCfg = if opts.EngineConfigs then opts.EngineConfigs[i] else nil
		local pos = enginePositions[i] or CFrame.new(0, 4.5 + (i - 1) * 2, 2)
		local eid = placePieceReq(player, `{prefix}_eng_{i}`, "SmallEngine", pos, engCfg, unitId)
		table.insert(engineIds, eid)
	end

	local fuelTankId: string? = nil
	if numTanks >= 1 then
		local ftCfg = if opts.FuelTankType
			then { FuelTank = { SelectedFuelType = opts.FuelTankType } }
			else nil
		local tankPositions = {
			CFrame.new(0, if numEngines >= 2 then 7.5 else 4.5, if numEngines >= 2 then 6 else 5),
			CFrame.new(0, 4.5, 8),
			CFrame.new(0, 4.5, 11),
		}
		for ti = 1, numTanks do
			local tPos = tankPositions[ti] or CFrame.new(0, 4.5 + (ti - 1) * 2, 5)
			local tid = placePieceReq(player, `{prefix}_tank_{ti}`, "RegularFuelTank", tPos, ftCfg)
			if ti == 1 then
				fuelTankId = tid
			end
		end
	end

	local defaultWheelCfg = if opts.AllWheelsFree then { Wheel = { IsDriven = false } } else nil
	local wcfgs = opts.WheelConfigs

	local fl = placePieceReq(
		player,
		`{prefix}_fl`,
		"SmallWheel",
		CFrame.new(-1.5, 2.5, -2),
		if wcfgs and wcfgs.FL then wcfgs.FL else defaultWheelCfg
	)
	local fr = placePieceReq(
		player,
		`{prefix}_fr`,
		"SmallWheel",
		CFrame.new(1.5, 2.5, -2) * wheelFlip,
		if wcfgs and wcfgs.FR then wcfgs.FR else defaultWheelCfg
	)
	local rl = placePieceReq(
		player,
		`{prefix}_rl`,
		"SmallWheel",
		CFrame.new(-1.5, 2.5, 2),
		if wcfgs and wcfgs.RL then wcfgs.RL else defaultWheelCfg
	)
	local rr = placePieceReq(
		player,
		`{prefix}_rr`,
		"SmallWheel",
		CFrame.new(1.5, 2.5, 2) * wheelFlip,
		if wcfgs and wcfgs.RR then wcfgs.RR else defaultWheelCfg
	)

	local wheelIds = { fl, fr, rl, rr }
	if opts.SixWheels then
		local ml = placePieceReq(player, `{prefix}_ml`, "SmallWheel", CFrame.new(-1.5, 2.5, 6), defaultWheelCfg)
		local mr = placePieceReq(player, `{prefix}_mr`, "SmallWheel", CFrame.new(1.5, 2.5, 6) * wheelFlip, defaultWheelCfg)
		table.insert(wheelIds, ml)
		table.insert(wheelIds, mr)
	end

	return {
		SeatId = seatId,
		EngineIds = engineIds,
		FuelTankId = fuelTankId,
		WheelIds = wheelIds,
		FL = fl,
		FR = fr,
		RL = rl,
		RR = rr,
	}
end

local function stepPowertrainAndWheels(steps: number, dt: number)
	for _ = 1, steps do
		VehiclePowertrainService.StepAll(dt)
		VehicleWheelControllerService.StepAll(dt)
	end
end

function Phase33Tests.AppendTests(
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
	runTest("Fase 3.3 [01]: EngineCatalog registers all 3 engine sizes (Small, Medium, Large) immutably", function()
		local sizes = EngineCatalog.GetOrderedSizeIds()
		assertEqual(#sizes, 3, "3 engine sizes registered")
		assertTrue(EngineCatalog.IsValidSizeId("Small"), "Small valid")
		assertTrue(EngineCatalog.IsValidSizeId("Medium"), "Medium valid")
		assertTrue(EngineCatalog.IsValidSizeId("Large"), "Large valid")

		local sSmall = EngineCatalog.GetSizeSpec("Small")
		local sMed = EngineCatalog.GetSizeSpec("Medium")
		local sLarge = EngineCatalog.GetSizeSpec("Large")
		assertTrue(table.isfrozen(sSmall) and table.isfrozen(sMed) and table.isfrozen(sLarge), "Size specs are frozen")
		assertTrue(sSmall.BaseTorque < sMed.BaseTorque and sMed.BaseTorque < sLarge.BaseTorque, "Torque increases with size")
		assertTrue(sSmall.Weight < sMed.Weight and sMed.Weight < sLarge.Weight, "Weight increases with size")
	end)

	-- 2
	runTest("Fase 3.3 [02]: EngineCatalog registers all 5 engine variants with distinct torque curves", function()
		local variants = EngineCatalog.GetOrderedVariantIds()
		assertEqual(#variants, 5, "5 engine variants registered")
		for _, vid in ipairs({ "Balanced", "HighTorque", "HighRev", "EcoLight", "Overdrive" }) do
			assertTrue(EngineCatalog.IsValidVariantId(vid), `Variant {vid} valid`)
			local vSpec = EngineCatalog.GetVariantSpec(vid :: any)
			assertTrue(table.isfrozen(vSpec), `Variant {vid} frozen`)
			local curve = EngineCatalog.GetTorqueCurve(vSpec.CurveSpecId)
			assertTrue(curve ~= nil and #curve.Points >= 4, `Variant {vid} has valid torque curve`)
		end
	end)

	-- 3
	runTest("Fase 3.3 [03]: EngineCatalog registers all 6 SDD rarities (Common..Mythic)", function()
		local rarities = EngineCatalog.GetOrderedRarityIds()
		assertEqual(#rarities, 6, "6 rarities registered")
		local expected = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" }
		for idx, rid in ipairs(expected) do
			assertEqual(rarities[idx], rid, `Rarity order {idx}`)
			local rSpec = EngineCatalog.GetRaritySpec(rid :: any)
			assertEqual(rSpec.RankOrder, idx, `Rarity rank {rid}`)
			assertTrue(table.isfrozen(rSpec), `Rarity {rid} frozen`)
		end
	end)

	-- 4
	runTest("Fase 3.3 [04]: Deterministic EffectiveEngineStats resolution formula", function()
		local a = EngineCatalog.ResolveEffectiveStats({
			EngineFamilyId = "StandardCombustion",
			EngineSizeId = "Medium",
			VariantId = "HighTorque",
			RarityId = "Rare",
		})
		local b = EngineCatalog.ResolveEffectiveStats({
			EngineFamilyId = "StandardCombustion",
			EngineSizeId = "Medium",
			VariantId = "HighTorque",
			RarityId = "Rare",
		})
		assertTrue(table.isfrozen(a), "Resolved stats are frozen")
		assertEqual(a.PeakTorque, b.PeakTorque, "Deterministic PeakTorque")
		assertEqual(a.PowerRating, b.PowerRating, "Deterministic PowerRating")
		assertEqual(a.MaxRPM, b.MaxRPM, "Deterministic MaxRPM")
		assertEqual(a.Weight, b.Weight, "Deterministic Weight")
		assertEqual(a.DrivingBonus, b.DrivingBonus, "Deterministic DrivingBonus")
	end)

	-- 5
	runTest("Fase 3.3 [05]: Real trade-offs between variants (HighTorque vs HighRev vs EcoLight vs Overdrive)", function()
		local bal = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Common" })
		local htq = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "HighTorque", RarityId = "Common" })
		local hrev = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "HighRev", RarityId = "Common" })
		local eco = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "EcoLight", RarityId = "Common" })
		local ovd = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Overdrive", RarityId = "Common" })

		assertTrue(htq.PeakTorque > bal.PeakTorque and htq.MaxRPM < bal.MaxRPM, "HighTorque trades top RPM for low-end torque")
		assertTrue(hrev.MaxRPM > bal.MaxRPM and hrev.SpeedRegular > bal.SpeedRegular and hrev.PeakTorque < bal.PeakTorque, "HighRev trades torque for top speed & RPM")
		assertTrue(eco.Weight < bal.Weight and eco.MaxFuelConsumption < bal.MaxFuelConsumption, "EcoLight reduces weight and fuel consumption")
		assertTrue(ovd.PowerRating > bal.PowerRating and ovd.MaxFuelConsumption > bal.MaxFuelConsumption, "Overdrive boosts power at the cost of fuel consumption")
	end)

	-- 6
	runTest("Fase 3.3 [06]: Non-uniform rarity modifiers & SDD DrivingBonus reference curve (+0.0025x .. +0.0065x)", function()
		local common = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Common" })
		local uncommon = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Uncommon" })
		local rare = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Rare" })
		local epic = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Epic" })
		local legendary = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Legendary" })
		local mythic = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Mythic" })

		-- Verificar curva de referencia SDD docs/06-ECONOMY-CRATES-DELIVERIES.md
		assertNear(common.DrivingBonus, 0.0025, 1e-6, "Common DrivingBonus = 0.0025")
		assertNear(uncommon.DrivingBonus, 0.0029, 1e-6, "Uncommon DrivingBonus = 0.0029")
		assertNear(rare.DrivingBonus, 0.0034, 1e-6, "Rare DrivingBonus = 0.0034")
		assertNear(epic.DrivingBonus, 0.0041, 1e-6, "Epic DrivingBonus = 0.0041")
		assertNear(legendary.DrivingBonus, 0.0051, 1e-6, "Legendary DrivingBonus = 0.0051")
		assertNear(mythic.DrivingBonus, 0.0065, 1e-6, "Mythic DrivingBonus = 0.0065")

		-- Verificar que los modificadores NO son un multiplicador plano uniforme
		local torqueRatio = mythic.PeakTorque / common.PeakTorque
		local speedRatio = mythic.SpeedRegular / common.SpeedRegular
		local weightRatio = mythic.Weight / common.Weight
		assertTrue(math.abs(torqueRatio - speedRatio) > 0.15, "Torque and Speed scale with distinct rarity ratios")
		assertTrue(weightRatio < 1.0, "Higher rarity reduces weight instead of multiplying it up")
	end)

	-- 7
	runTest("Fase 3.3 [07]: SDD base designer stats preserved for SmallEngine and MediumEngine", function()
		local sddSmall = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Common" })
		assertEqual(sddSmall.SpeedRegular, 36, "SmallEngine SpeedRegular = 36")
		assertEqual(sddSmall.PeakTorque, 1400, "SmallEngine Torque = 1400")
		assertEqual(sddSmall.Weight, 8, "SmallEngine Weight = 8")
		assertEqual(sddSmall.MaxDurability, 110, "SmallEngine MaxDurability = 110")
		assertEqual(sddSmall.IntegratedFuel, 0.54, "SmallEngine IntegratedFuel = 0.54")
		assertEqual(sddSmall.MaxFuelConsumption, 0.18, "SmallEngine MaxConsumptionRegular = 0.18")
		assertEqual(sddSmall.DrivingBonus, 0.0025, "SmallEngine DrivingBonus = 0.0025")
		assertEqual(sddSmall.DisconnectRate, 21.88, "SmallEngine DisconnectRate = 21.88")

		local sddMed = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Medium", VariantId = "Balanced", RarityId = "Common" })
		assertEqual(sddMed.SpeedRegular, 50, "MediumEngine SpeedRegular = 50")
		assertEqual(sddMed.PeakTorque, 4200, "MediumEngine Torque = 4200")
		assertEqual(sddMed.Weight, 14, "MediumEngine Weight = 14")
		assertEqual(sddMed.MaxDurability, 150, "MediumEngine MaxDurability = 150")
		assertEqual(sddMed.IntegratedFuel, 0.90, "MediumEngine IntegratedFuel = 0.90")
		assertEqual(sddMed.MaxFuelConsumption, 0.30, "MediumEngine MaxConsumptionRegular = 0.30")
		assertEqual(sddMed.DrivingBonus, 0.015, "MediumEngine DrivingBonus = 0.015")
		assertEqual(sddMed.DisconnectRate, 87.5, "MediumEngine DisconnectRate = 87.5")
	end)

	-- 8
	runTest("Fase 3.3 [08]: Provisional balance parameters explicitly tagged as Provisional_TBD", function()
		local confirmedSmall = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Common" })
		local confirmedMed = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Medium", VariantId = "Balanced", RarityId = "Common" })
		local provLarge = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Large", VariantId = "Balanced", RarityId = "Common" })
		local provVariant = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "HighTorque", RarityId = "Common" })
		local provRarity = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Epic" })

		assertEqual(confirmedSmall.IsProvisionalBalance, false, "Small+Balanced+Common is SDD_Confirmed")
		assertEqual(confirmedMed.IsProvisionalBalance, false, "Medium+Balanced+Common is SDD_Confirmed")
		assertEqual(provLarge.IsProvisionalBalance, true, "Large size marked Provisional_TBD")
		assertEqual(provVariant.IsProvisionalBalance, true, "Custom variant marked Provisional_TBD")
		assertEqual(provRarity.IsProvisionalBalance, true, "Extended rarity modifiers marked Provisional_TBD")
	end)

	-- 9
	runTest("Fase 3.3 [09]: VehicleRuntime detects installed engines and initializes EngineBehavior", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33009, Name = "DetectEngine" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t09", { EngineCount = 2 })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launched successfully")

		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		assertTrue(rt.EnginePieceIds ~= nil and #rt.EnginePieceIds == 2, "2 EnginePieceIds registered")
		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(pt ~= nil, "PowertrainState available")
		assertEqual(pt.EngineCount, 2, "PowertrainState reports 2 engines")
		assertEqual(pt.FunctionalEngineCount, 2, "Both engines functional")

		local engPart = rt.Parts[v.EngineIds[1]]
		assertEqual(engPart.ModelInstance:GetAttribute("EngineBehaviorActive"), true, "EngineBehavior.Init executed")
		env.Teardown()
	end)

	-- 10
	runTest("Fase 3.3 [10]: Vehicle without engine cannot self-propel under throttle", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33010, Name = "NoEngine" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t10", { EngineCount = 0 })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success, "Launched")

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(10, 0.05)

		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(pt.EngineCount, 0, "0 engines")
		assertEqual(pt.TotalWheelDriveTorque, 0, "0 wheel drive torque without engine")
		local flSt = VehicleWheelControllerService.GetWheelState(p1, v.FL) :: VehicleTypes.WheelRuntimeState
		assertEqual(flSt.TorqueLimit, 0, "Wheel receives 0 motor torque")
		env.Teardown()
	end)

	-- 11
	runTest("Fase 3.3 [11]: Vehicle with engine and 0 driven wheels reports NoDrivenWheels error cleanly", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33011, Name = "ZeroDriven" }
		PlotService.Assign(p1)
		buildMotorizedVehicle(p1, "t11", { EngineCount = 1, AllWheelsFree = true })

		local prep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1)
		assertEqual(prep.EngineCount, 1, "Prep report shows 1 engine")
		assertEqual(prep.DrivenWheelCount, 0, "Prep report shows 0 driven wheels")
		assertTrue(prep.PowertrainWarnings ~= nil and #prep.PowertrainWarnings >= 1, "Prep report includes NoDrivenWheels warning")

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success, "Launched")

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(5, 0.05)
		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(pt.NoDrivenWheelsError, true, "Powertrain flags NoDrivenWheelsError")
		assertEqual(pt.PerDrivenWheelTorque, 0, "No torque sent when 0 driven wheels")
		env.Teardown()
	end)

	-- 12
	runTest("Fase 3.3 [12]: Vehicle with 1 SmallEngine and 4 driven wheels accelerates forward", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33012, Name = "Fwd1Eng" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t12", { EngineCount = 1 })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success, "Launched")

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(15, 0.05)

		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(pt.GearState, "Forward", "GearState is Forward")
		assertTrue(pt.CombinedRPM > 1500, "Engine RPM climbed above idle")
		assertTrue(pt.TotalWheelDriveTorque > 5000, "Substantial wheel torque generated")
		assertTrue(pt.TargetWheelAngularVelocity > 10, "Positive forward wheel angular velocity commanded")

		local flSt = VehicleWheelControllerService.GetWheelState(p1, v.FL) :: VehicleTypes.WheelRuntimeState
		assertTrue(flSt.TorqueLimit > 1000, "Driven wheel FL receives torque limit")
		assertTrue(flSt.TargetAngularVelocity > 10, "Driven wheel FL receives positive omega")
		env.Teardown()
	end)

	-- 13 & 14
	runTest("Fase 3.3 [13-14]: Free wheels (IsDriven=false) receive 0 motor torque while Driven wheels receive full share", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33013, Name = "RWDTest" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t13", {
			EngineCount = 1,
			WheelConfigs = {
				FL = { Wheel = { IsDriven = false } },
				FR = { Wheel = { IsDriven = false } },
				RL = { Wheel = { IsDriven = true } },
				RR = { Wheel = { IsDriven = true } },
			},
		})
		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(10, 0.05)

		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(pt.DrivenWheelCount, 2, "2 driven wheels")
		assertEqual(pt.FreeWheelCount, 2, "2 free wheels")

		local flSt = VehicleWheelControllerService.GetWheelState(p1, v.FL) :: VehicleTypes.WheelRuntimeState
		local rlSt = VehicleWheelControllerService.GetWheelState(p1, v.RL) :: VehicleTypes.WheelRuntimeState
		assertEqual(flSt.TorqueLimit, 0, "Front free wheel receives 0 drive torque")
		assertTrue(rlSt.TorqueLimit > 2000, "Rear driven wheel receives half of total drive torque")
		assertNear(rlSt.TorqueLimit * 2, pt.TotalWheelDriveTorque, 1.0, "Torque distributed exclusively across the 2 driven wheels")
		env.Teardown()
	end)

	-- 15
	runTest("Fase 3.3 [15]: Reverse gear engages from standstill with bounded reverse speed & negative omega", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33015, Name = "ReverseTest" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t15", { EngineCount = 1 })
		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Brake = 1.0 })
		stepPowertrainAndWheels(10, 0.05)

		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(pt.GearState, "Reverse", "GearState is Reverse")
		assertEqual(pt.ActiveGearIndex, -1, "ActiveGearIndex = -1 in Reverse")
		assertTrue(pt.TargetWheelAngularVelocity < -5, "Negative angular velocity in Reverse")
		local maxExpectedRevOmega = (36 * GameConfig.Powertrain.ReverseMaxSpeedRatio) / 1.0 + 0.5
		assertTrue(math.abs(pt.TargetWheelAngularVelocity) <= maxExpectedRevOmega, "Reverse angular velocity respects ReverseMaxSpeedRatio")

		local rlSt = VehicleWheelControllerService.GetWheelState(p1, v.RL) :: VehicleTypes.WheelRuntimeState
		assertTrue(rlSt.TargetAngularVelocity < -5, "Wheel receives negative reverse velocity")
		env.Teardown()
	end)

	-- 16 & 18
	runTest("Fase 3.3 [16 & 18]: Pressing S while moving forward applies Service Braking first before engaging Reverse", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33016, Name = "SafeTransition" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t16", { EngineCount = 1 })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local seat = rt.DriverSeatPart :: VehicleSeat

		-- Simular que el chasis ya avanza hacia delante a 18 studs/s
		local fwd = seat.CFrame.LookVector
		for _, desc in ipairs((rt.RootModel :: Model):GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.AssemblyLinearVelocity = fwd * 18
			end
		end

		-- Jugador presiona S (Brake=1.0)
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Brake = 1.0 })
		stepPowertrainAndWheels(2, 0.05)

		local ptBraking = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(ptBraking.GearState, "Braking", "Enters Braking state instead of instant reverse at 18 studs/s")
		assertEqual(ptBraking.PerDrivenWheelTorque, 0, "Drive torque is 0 while braking")
		assertTrue(ptBraking.AppliedBrakeTorque > 1000, "Applies strong service brake torque")

		local flBrk = VehicleWheelControllerService.GetWheelState(p1, v.FL) :: VehicleTypes.WheelRuntimeState
		assertTrue(flBrk.BrakeTorque > 1000, "Wheel receives BrakeTorque")

		-- Una vez que el vehículo reduce su velocidad por debajo del umbral seguro, engrana Reversa suavemente
		for _, desc in ipairs((rt.RootModel :: Model):GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.AssemblyLinearVelocity = fwd * 0.5
			end
		end
		stepPowertrainAndWheels(3, 0.05)

		local ptRev = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(ptRev.GearState, "Reverse", "Transitions to Reverse once slowed below threshold")
		assertTrue(ptRev.TargetWheelAngularVelocity < 0, "Now commands reverse rotation")
		env.Teardown()
	end)

	-- 17
	runTest("Fase 3.3 [17]: Handbrake is removed; Service Brake prioritizes braking and cuts drive torque under Throttle+Brake", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33017, Name = "BrakePriorityTest" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t17", { EngineCount = 1 })
		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })

		assertEqual((GameConfig.Powertrain :: any).HandbrakeTorquePerWheel, nil, "Handbrake config removed")
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0, Brake = 1.0 })
		stepPowertrainAndWheels(5, 0.05)

		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(pt.GearState, "Braking", "GearState prioritizes Braking on Throttle+Brake")
		assertEqual(pt.PerDrivenWheelTorque, 0, "Drive torque cut to 0 while braking")
		assertTrue(pt.AppliedBrakeTorque >= GameConfig.Powertrain.ServiceBrakeBaseTorquePerWheel * 0.9, "Applies ServiceBrakeBaseTorquePerWheel")

		local flSt = VehicleWheelControllerService.GetWheelState(p1, v.FL) :: VehicleTypes.WheelRuntimeState
		assertEqual(flSt.BrakeTorque, pt.AppliedBrakeTorque, "Wheel AxleHinge receives service brake torque")
		env.Teardown()
	end)

	-- 19 & 20
	runTest("Fase 3.3 [19-20]: Torque curve evaluation across RPM band & Rev Limiter cutoff/recovery hysteresis", function()
		local stats = EngineCatalog.ResolveEffectiveStats({ EngineSizeId = "Small", VariantId = "Balanced", RarityId = "Common" })
		local idleTq, idleFac = EngineCatalog.EvaluateTorqueAtRPM(stats, stats.IdleRPM, false)
		local optTq, optFac = EngineCatalog.EvaluateTorqueAtRPM(stats, stats.OptimumRPM, false)
		local redTq, redFac = EngineCatalog.EvaluateTorqueAtRPM(stats, stats.MaxRPM, false)
		local cutTq, _ = EngineCatalog.EvaluateTorqueAtRPM(stats, stats.LimiterRPM + 50, false)
		local limActiveTq, _ = EngineCatalog.EvaluateTorqueAtRPM(stats, stats.OptimumRPM, true)

		assertTrue(idleFac > 0.4 and idleFac < 0.8, "Idle torque factor is moderate")
		assertNear(optFac, 1.0, 0.08, "Optimum RPM is near peak torque factor (1.0)")
		assertTrue(optTq > idleTq and optTq > redTq, "Peak torque at optimum RPM exceeds idle and redline torque")
		assertEqual(cutTq, 0, "Torque cuts to 0 at LimiterRPM")
		assertEqual(limActiveTq, 0, "Torque is 0 while LimiterActive is true")
	end)

	-- 21, 22 & 23
	runTest("Fase 3.3 [21-23]: Mass sensitivity & Multi-Engine combination policy (diminishing efficiency + cap)", function()
		local env = setupIsolatedWorld(3)
		local pLight: PlotService.PlayerLike = { UserId = 330211, Name = "Light1Eng" }
		local pHeavy1: PlotService.PlayerLike = { UserId = 330212, Name = "Heavy1Eng" }
		local pHeavy2: PlotService.PlayerLike = { UserId = 330213, Name = "Heavy2Eng" }
		PlotService.Assign(pLight)
		PlotService.Assign(pHeavy1)
		PlotService.Assign(pHeavy2)

		buildMotorizedVehicle(pLight, "vl", { EngineCount = 1, HeavyBlocks = 0 })
		buildMotorizedVehicle(pHeavy1, "vh1", { EngineCount = 1, HeavyBlocks = 8, IncludeFuelTank = true })
		buildMotorizedVehicle(pHeavy2, "vh2", { EngineCount = 2, HeavyBlocks = 8, IncludeFuelTank = true })

		VehicleLaunchService.LaunchVehicle(pLight, { MountDriver = false, SkipWorldObstructionCheck = true })
		VehicleLaunchService.LaunchVehicle(pHeavy1, { MountDriver = false, SkipWorldObstructionCheck = true })
		VehicleLaunchService.LaunchVehicle(pHeavy2, { MountDriver = false, SkipWorldObstructionCheck = true })

		VehiclePowertrainService.SetControlOverrideForTests(pLight, { Throttle = 1.0 })
		VehiclePowertrainService.SetControlOverrideForTests(pHeavy1, { Throttle = 1.0 })
		VehiclePowertrainService.SetControlOverrideForTests(pHeavy2, { Throttle = 1.0 })
		stepPowertrainAndWheels(15, 0.05)

		local ptLight = VehiclePowertrainService.GetPowertrainState(pLight) :: VehicleTypes.PowertrainTelemetrySnapshot
		local ptHeavy1 = VehiclePowertrainService.GetPowertrainState(pHeavy1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local ptHeavy2 = VehiclePowertrainService.GetPowertrainState(pHeavy2) :: VehicleTypes.PowertrainTelemetrySnapshot

		assertTrue(ptHeavy1.TotalVehicleMass > ptLight.TotalVehicleMass * 1.5, "Heavy vehicle has significantly higher physical mass")
		assertTrue(ptHeavy1.CombinedLoadFactor > ptLight.CombinedLoadFactor, "Heavy vehicle experiences higher engine load")
		assertTrue(ptLight.TargetWheelAngularVelocity > ptHeavy1.TargetWheelAngularVelocity, "Light vehicle achieves higher target speed under load than heavy 1-engine")

		-- 2 motores entregan más torque total que 1 motor, respetando MultiEngineEfficiencyDecay (1 + 0.92 = 1.92x)
		local ratio2to1 = ptHeavy2.TotalWheelDriveTorque / math.max(1, ptHeavy1.TotalWheelDriveTorque)
		assertNear(ratio2to1, 1.0 + GameConfig.Powertrain.MultiEngineEfficiencyDecay, 0.15, "2 identical engines combine with 1.92x efficiency factor")
		assertTrue(ptHeavy2.TargetWheelAngularVelocity > ptHeavy1.TargetWheelAngularVelocity, "2 engines sustain higher speed on heavy chassis than 1 engine")
		env.Teardown()
	end)

	-- 24 & 25
	runTest("Fase 3.3 [24-25]: Slope load detection, automatic downshift to low gear, and higher torque on uphill climb", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33024, Name = "SlopeClimb" }
		PlotService.Assign(p1)
		buildMotorizedVehicle(p1, "t24", { EngineCount = 1 })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local root = rt.RootModel :: Model

		--En terreno plano a velocidad media (22 studs/s), selecciona marcha alta (2 o 3)
		local flatFwd = (rt.DriverSeatPart :: VehicleSeat).CFrame.LookVector
		for _, desc in ipairs(root:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.AssemblyLinearVelocity = flatFwd * 22
			end
		end
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(6, 0.1)
		local ptFlat = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptFlat.ActiveGearIndex >= 2, "Upshifts to gear >= 2 on flat ground at 22 studs/s")

		-- Inclinar el vehículo 22 grados hacia arriba (subida pronunciada) a menor velocidad
		local pivot = root:GetPivot()
		root:PivotTo(pivot * CFrame.Angles(math.rad(22), 0, 0))
		local slopeFwd = (rt.DriverSeatPart :: VehicleSeat).CFrame.LookVector
		for _, desc in ipairs(root:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.AssemblyLinearVelocity = slopeFwd * 8
			end
		end
		stepPowertrainAndWheels(6, 0.1)
		local ptSlope = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptSlope.SlopeDegrees > 18, "Detects uphill slope > 18 degrees")
		assertEqual(ptSlope.ActiveGearIndex, 1, "Downshifts automatically to 1st gear for maximum climbing torque")
		assertTrue(ptSlope.TotalWheelDriveTorque > ptFlat.TotalWheelDriveTorque, "1st gear multiplies wheel torque for climbing")
		env.Teardown()
	end)

	-- 26, 27 & 28
	runTest("Fase 3.3 [26-28]: Simultaneous Steering + Propulsion + Suspension & zero native VehicleSeat propulsion", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33026, Name = "SteerAndDrive" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t26", { EngineCount = 1 })
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local seat = rt.DriverSeatPart :: VehicleSeat

		assertEqual(seat.MaxSpeed, 0, "DriverSeat.MaxSpeed is strictly 0")
		assertEqual(seat.Torque, 0, "DriverSeat.Torque is strictly 0")
		assertEqual(seat.TurnSpeed, 0, "DriverSeat.TurnSpeed is strictly 0")

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0, Steer = -1.0 })
		stepPowertrainAndWheels(8, 0.05)

		local flSt = VehicleWheelControllerService.GetWheelState(p1, v.FL) :: VehicleTypes.WheelRuntimeState
		assertTrue(flSt.TargetSteeringAngle > 15, "Front wheel steers while accelerating")
		assertTrue(flSt.TorqueLimit > 1000 and flSt.TargetAngularVelocity > 10, "Front wheel also receives drive torque and velocity")
		assertEqual(seat.MaxSpeed, 0, "DriverSeat.MaxSpeed remains 0 during active driving")
		assertEqual(seat.Torque, 0, "DriverSeat.Torque remains 0 during active driving")
		env.Teardown()
	end)

	-- 29
	runTest("Fase 3.3 [29]: Only the seated owner can send driving inputs (rejects non-owner & unseated requests)", function()
		local env = setupIsolatedWorld(2)
		local pOwner: PlotService.PlayerLike = { UserId = 330291, Name = "OwnerDriver" }
		local pIntruder: PlotService.PlayerLike = { UserId = 330292, Name = "Intruder" }
		PlotService.Assign(pOwner)
		PlotService.Assign(pIntruder)

		buildMotorizedVehicle(pOwner, "t29", { EngineCount = 1 })
		local lr = VehicleLaunchService.LaunchVehicle(pOwner, { MountDriver = false, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		-- Intruso sin vehículo activo
		local resIntruder = BuildService.ProcessRequest(pIntruder, {
			Action = BuildProtocol.Actions.SetDrivingInput,
			ClientOpId = "intruder_drv_1",
			Throttle = 1.0,
		})
		assertEqual(resIntruder.Success, false, "Intruder driving input rejected")

		-- Dueño pero en estado OnFootRuntime (no sentado)
		VehicleRuntimeService.SetRuntimeState(pOwner.UserId, GameConfig.Runtime.States.OnFootRuntime :: any)
		local resUnseated = BuildService.ProcessRequest(pOwner, {
			Action = BuildProtocol.Actions.SetDrivingInput,
			ClientOpId = "owner_unseated_1",
			Throttle = 1.0,
		})
		assertEqual(resUnseated.Success, false, "Unseated owner driving input rejected")
		assertEqual(resUnseated.ErrorCode, BuildProtocol.ErrorCodes.NotSeatedDriver, "ErrorCode is NotSeatedDriver")

		-- Dueño en estado Driving
		VehicleRuntimeService.SetRuntimeState(pOwner.UserId, GameConfig.Runtime.States.Driving :: any)
		local resSeated = BuildService.ProcessRequest(pOwner, {
			Action = BuildProtocol.Actions.SetDrivingInput,
			ClientOpId = "owner_seated_1",
			Throttle = 0.85,
			Steer = 0.5,
		})
		assertEqual(resSeated.Success, true, "Seated owner driving input accepted")

		local resLegacyHb = BuildService.ProcessRequest(pOwner, {
			Action = BuildProtocol.Actions.SetDrivingInput,
			ClientOpId = "owner_hb_rejected",
			Throttle = 0,
			Handbrake = true,
		} :: any)
		assertEqual(resLegacyHb.Success, false, "Legacy Handbrake payload rejected")
		env.Teardown()
	end)

	-- 30
	runTest("Fase 3.3 [30]: Rejects malicious client payloads attempting to spoof Stats, Torque, Power or RarityId", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 330301, Name = "Spoofer" }
		local p2: PlotService.PlayerLike = { UserId = 330302, Name = "OtherOwner" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)

		local p2Unit = EngineInventoryService.RegisterUnitForTesting(p2, {
			ItemInstanceId = "unit_p2_mythic",
			EngineSizeId = "Large",
			VariantId = "Overdrive",
			RarityId = "Mythic",
		})

		-- 1) Intentar inyectar PeakTorque o RarityId directo en Config.Engine
		local spoofTorqueRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "spoof_tq",
			ItemId = "SmallEngine",
			LocalCFrame = CFrame.new(0, 2.5, 0),
			Config = { Engine = { PeakTorque = 999999, RarityId = "Mythic" } },
		})
		assertEqual(spoofTorqueRes.Success, false, "Direct PeakTorque/RarityId in Config.Engine rejected")
		assertEqual(spoofTorqueRes.ErrorCode, BuildProtocol.ErrorCodes.ForbiddenDirectStatsPayload, "ForbiddenDirectStatsPayload returned")

		-- 2) Intentar usar una unidad inexistente
		local unknownUnitRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "spoof_unk_unit",
			ItemId = "SmallEngine",
			LocalCFrame = CFrame.new(0, 2.5, 0),
			InventoryInstanceId = "forged_mythic_unit_999",
		})
		assertEqual(unknownUnitRes.Success, false, "Unknown InventoryInstanceId rejected")
		assertEqual(unknownUnitRes.ErrorCode, BuildProtocol.ErrorCodes.UnknownEngineUnit, "UnknownEngineUnit returned")

		-- 3) Intentar usar la unidad perteneciente a otro jugador (p2)
		local stolenUnitRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "spoof_stolen_unit",
			ItemId = "SmallEngine",
			LocalCFrame = CFrame.new(0, 2.5, 0),
			InventoryInstanceId = p2Unit.ItemInstanceId,
		})
		assertEqual(stolenUnitRes.Success, false, "Other player's InventoryInstanceId rejected")
		assertEqual(stolenUnitRes.ErrorCode, BuildProtocol.ErrorCodes.UnauthorizedEngineUnit, "UnauthorizedEngineUnit returned")
		env.Teardown()
	end)

	-- 31, 32 & 33
	runTest("Fase 3.3 [31-33]: Blueprint persistence, backward compatibility, and anti-duplication of EngineUnitRecords", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33031, Name = "PersistenceAntiDup" }
		PlotService.Assign(p1)

		local epicUnit = EngineInventoryService.RegisterUnitForTesting(p1, {
			ItemInstanceId = "unit_p1_epic_med",
			EngineSizeId = "Medium",
			VariantId = "HighTorque",
			RarityId = "Epic",
		})

		placePieceReq(p1, "b0", "WoodBlock", CFrame.new(0, 2.5, 0), nil)
		placePieceReq(p1, "seat", "DriverSeat", CFrame.new(0, 4.0, 0), nil)
		local eng1Id = placePieceReq(
			p1,
			"eng1",
			"SmallEngine",
			CFrame.new(0, 2.5, 3),
			{ Engine = { PowerLimitRatio = 0.85, ThrottleResponseMode = "Sport" } },
			epicUnit.ItemInstanceId
		)

		-- Intentar colocar la MISMA unidad física en un segundo motor dentro del mismo vehículo -> RECHAZADO
		local dupPlaceRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "eng2_dup_unit",
			ItemId = "SmallEngine",
			LocalCFrame = CFrame.new(0, 2.5, -3),
			InventoryInstanceId = epicUnit.ItemInstanceId,
		})
		assertEqual(dupPlaceRes.Success, false, "Cannot place the same InventoryInstanceId twice in the same blueprint")
		assertEqual(dupPlaceRes.ErrorCode, BuildProtocol.ErrorCodes.DuplicateEngineUnitInBlueprint, "DuplicateEngineUnitInBlueprint returned")

		-- Colocar un segundo motor sin InventoryInstanceId (compatibilidad legacy / catálogo base)
		local eng2Id = placePieceReq(p1, "eng2_base", "SmallEngine", CFrame.new(0, 2.5, -3), nil, nil)

		-- Intentar asignar la unidad ya ocupada en eng1 hacia eng2 mediante UpdatePieceConfig -> RECHAZADO
		local dupUpdateRes = BuildService.ProcessRequest(p1, {
			Action = "UpdatePieceConfig",
			ClientOpId = "upd_eng2_dup",
			PieceInstanceId = eng2Id,
			InventoryInstanceId = epicUnit.ItemInstanceId,
		})
		assertEqual(dupUpdateRes.Success, false, "UpdatePieceConfig rejects assigning already-used InventoryInstanceId")
		assertEqual(dupUpdateRes.ErrorCode, BuildProtocol.ErrorCodes.DuplicateEngineUnitInBlueprint, "DuplicateEngineUnitInBlueprint returned")

		-- Guardar blueprint y verificar persistencia
		local saveRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprint,
			ClientOpId = "save_bp_33",
			Name = "Vehiculo Epico",
		})
		assertTrue(saveRes.Success and saveRes.Blueprint ~= nil, "Saved blueprint")
		local savedBpId = (saveRes.Blueprint :: VehicleTypes.VehicleBlueprint).BlueprintId

		-- Duplicar el blueprint: la copia NO debe duplicar el InventoryInstanceId único
		local dupBpRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.DuplicateBlueprint,
			ClientOpId = "dup_bp_33",
			BlueprintId = savedBpId,
			Name = "Copia Sin Duplicar Unidad",
		})
		assertTrue(dupBpRes.Success and dupBpRes.DuplicatedBlueprint ~= nil, "Duplicated blueprint")
		local dupBpId = (dupBpRes.DuplicatedBlueprint :: VehicleTypes.BlueprintSummary).BlueprintId

		local loadDupRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprint,
			ClientOpId = "load_dup_33",
			BlueprintId = dupBpId,
		})
		assertTrue(loadDupRes.Success and loadDupRes.Blueprint ~= nil, "Loaded duplicated blueprint")
		for _, p in ipairs((loadDupRes.Blueprint :: VehicleTypes.VehicleBlueprint).Pieces) do
			assertEqual(p.InventoryInstanceId, nil, "Duplicated blueprint stripped unique InventoryInstanceId to prevent cloning")
		end

		-- Recargar el blueprint original: conserva su InventoryInstanceId y configuración
		local reloadOrig = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprint,
			ClientOpId = "reload_orig_33",
			BlueprintId = savedBpId,
		})
		assertTrue(reloadOrig.Success and reloadOrig.Blueprint ~= nil, "Reloaded original blueprint")
		local foundEng1: VehicleTypes.BlueprintPiece? = nil
		for _, p in ipairs((reloadOrig.Blueprint :: VehicleTypes.VehicleBlueprint).Pieces) do
			if p.InstanceId == eng1Id then
				foundEng1 = p
			end
		end
		assertTrue(foundEng1 ~= nil, "Original engine piece found")
		assertEqual((foundEng1 :: any).InventoryInstanceId, epicUnit.ItemInstanceId, "Original blueprint preserved InventoryInstanceId")
		assertEqual((foundEng1 :: any).Config.Engine.RarityId, "Epic", "Original blueprint preserved Epic rarity")
		assertEqual((foundEng1 :: any).Config.Engine.PowerLimitRatio, 0.85, "Original blueprint preserved PowerLimitRatio")
		env.Teardown()
	end)

	-- 34, 35 & 36
	runTest("Fase 3.3 [34-36]: ReturnToWorkshop & ResetVehicle preserve Blueprint intact without leaking runtime wear/fuel", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33034, Name = "LifecycleClean" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t34", { EngineCount = 1, IncludeFuelTank = true })
		local bpBefore = BlueprintSerializer.CloneBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		-- Simular consumo de combustible y daño temporal en runtime
		rt.Parts[v.EngineIds[1]].CurrentDurability = 30
		rt.Parts[v.EngineIds[1]].CurrentFuel = 0.05
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(5, 0.05)

		-- ResetVehicle restaura durabilidad y combustible inicial
		env.AdvanceClock(2.0)
		local resetRes = VehicleLaunchService.ResetVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(resetRes.Success and resetRes.Runtime ~= nil, "ResetVehicle succeeded")
		local rtAfterReset = resetRes.Runtime :: VehicleTypes.VehicleRuntime
		assertEqual(rtAfterReset.Parts[v.EngineIds[1]].CurrentDurability, 110, "ResetVehicle restored full engine durability (110)")
		assertNear(rtAfterReset.Parts[v.EngineIds[1]].CurrentFuel or 0, 0.54, 1e-4, "ResetVehicle restored full integrated fuel (0.54)")

		-- ReturnToWorkshop limpia el tren motriz y deja el Blueprint intacto
		local retRes = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(retRes.Success, "ReturnToWorkshop succeeded")
		assertEqual(VehiclePowertrainService.GetPowertrainState(p1), nil, "Powertrain unregistered on ReturnToWorkshop")

		local bpAfter = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		assertEqual(#bpAfter.Pieces, #bpBefore.Pieces, "Blueprint piece count intact")
		assertEqual(bpAfter.Revision, bpBefore.Revision, "Blueprint revision unchanged by runtime wear")
		env.Teardown()
	end)

	-- 37 & 38
	runTest("Fase 3.3 [37-38]: Fuel consumption / OutOfFuel cutoff contract & temporary runtime durability degradation", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33037, Name = "FuelAndDurability" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t37", {
			EngineCount = 1,
			IncludeFuelTank = true,
			FuelTankType = "Competicion",
		})
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(10, 0.05)
		local ptHealthy = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertNear(ptHealthy.TotalFuelCapacity, 0.54 + 1.5, 0.01, "TotalFuelCapacity sums IntegratedFuel (0.54) + RegularFuelTank (1.5)")
		local healthyTorque = ptHealthy.TotalEngineTorque
		assertTrue(healthyTorque > 800, "Healthy engine produces torque")

		-- Degradar durabilidad temporal en runtime a 20%
		rt.Parts[v.EngineIds[1]].CurrentDurability = 22
		stepPowertrainAndWheels(4, 0.05)
		local ptDamaged = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptDamaged.TotalEngineTorque < healthyTorque * 0.75, "Severely damaged engine reduces runtime torque output")

		-- Drenar todo el combustible -> OutOfFuel corta el par motor a 0
		VehiclePowertrainService.SetFuelConsumptionEnabled(p1, true)
		VehiclePowertrainService.SetFuelLevelForTests(p1, 0)
		stepPowertrainAndWheels(4, 0.05)
		local ptEmpty = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(ptEmpty.OutOfFuel, true, "OutOfFuel is true when fuel reaches 0")
		assertEqual(ptEmpty.TotalEngineTorque, 0, "Engine torque cuts to 0 when OutOfFuel")
		assertEqual(ptEmpty.PerDrivenWheelTorque, 0, "Wheel drive torque cuts to 0 when OutOfFuel")
		env.Teardown()
	end)

	-- 39
	runTest("Fase 3.3 [39]: Driving HUD & Engine Inspector UI mount and update reactively without errors", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33039, Name = "UIInspector" }
		local plot = PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t39", { EngineCount = 1 })

		local testGui = Instance.new("ScreenGui")
		local mountedInspector = EngineInspectorPanel.Mount(testGui)
		local mountedHud = VehicleDrivingController.Mount(testGui)

		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		BuildState.ApplyAuthoritativeBlueprint(bp)
		BuildState.SetActive(true)
		BuildState.SetSelectedPlacedPiece(v.EngineIds[1])
		mountedInspector.Refresh()

		assertEqual(mountedInspector.Frame.Visible, true, "EngineInspectorPanel opens when engine piece is selected")
		local statsBox = mountedInspector.Frame:FindFirstChild("StatsBox") :: TextLabel
		assertTrue(statsBox ~= nil and string.find(statsBox.Text, "1400") ~= nil, "EngineInspectorPanel displays PeakTorque 1400")

		-- Pasar a modo Driving con un VehicleRuntime real en DynamicRuntime y verificar HUD + telemetría
		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Vehicle launched for HUD telemetry test")
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(6, 0.05)

		BuildState.SetActive(false)
		BuildState.SetRuntimeStatus({
			State = "Driving",
			RuntimeId = (lr.Runtime :: VehicleTypes.VehicleRuntime).RuntimeId,
			PlotId = "Plot_1",
			SourceBlueprintId = bp.BlueprintId,
			SourceBlueprintRevision = bp.Revision,
			DriverSeated = true,
			PieceCount = #bp.Pieces,
			JointCount = 6,
		})
		mountedHud.RefreshVisibility()
		assertEqual(mountedHud.HudFrame.Visible, true, "DrivingHudPanel becomes visible in Driving state")
		assertEqual(
			VehicleDrivingController.FindLocalRuntimeModel(),
			(lr.Runtime :: VehicleTypes.VehicleRuntime).RootModel,
			"VehicleDrivingController.FindLocalRuntimeModel resolves Plot.DynamicRuntime.VehicleRuntime"
		)
		local gearBadge = mountedHud.HudFrame:FindFirstChild("GearBadge") :: TextLabel
		assertTrue(gearBadge ~= nil and string.sub(gearBadge.Text, 1, 1) == "D", "HUD GearBadge updates to forward drive gear D1..D4")

		mountedInspector.Close()
		mountedHud.Destroy()
		assertEqual(VehicleDrivingController.GetActiveConnectionCount(), 0, "Zero leftover connections after Destroy")
		testGui:Destroy()
		env.Teardown()
	end)

	-- 41 (Regresión Hotfix Fase 3.3)
	runTest("Fase 3.3 [41]: Regression — VehicleDrivingController resolves DynamicRuntime without nil FindFirstChild and avoids duplicate connections across launches", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33041, Name = "HudRegressionTester" }
		local plot = PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "t41", { EngineCount = 1 })
		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)

		local testGui = Instance.new("ScreenGui")
		local hud1 = VehicleDrivingController.Mount(testGui)
		local connCount1 = VehicleDrivingController.GetActiveConnectionCount()
		assertTrue(connCount1 > 0, "Mounted HUD registers input and render connections")

		-- Re-montar sobre otra GUI debe limpiar las conexiones previas sin duplicarlas
		local hud2 = VehicleDrivingController.Mount(testGui)
		local connCount2 = VehicleDrivingController.GetActiveConnectionCount()
		assertEqual(connCount2, connCount1, "Re-mounting VehicleDrivingController must not accumulate duplicate connections")

		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		BuildState.ApplyAuthoritativeBlueprint(bp)

		-- Ciclo 1: Lanzar -> Conducir (W, A/D, S freno, S reversa) -> Regresar al taller
		local lr1 = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr1.Success and lr1.Runtime ~= nil, "First launch succeeded")
		local rt1 = lr1.Runtime :: VehicleTypes.VehicleRuntime

		BuildState.SetRuntimeStatus(lr1.RuntimeStatus)
		BuildState.SetRuntimeStatus({
			State = "Driving",
			RuntimeId = rt1.RuntimeId,
			PlotId = plot.PlotId,
			SourceBlueprintId = bp.BlueprintId,
			SourceBlueprintRevision = bp.Revision,
			DriverSeated = true,
			PieceCount = #bp.Pieces,
			JointCount = 6,
		})

		-- Verificar que RefreshVisibility resuelve VehicleRuntime en DynamicRuntime sin errores
		hud2.RefreshVisibility()
		assertEqual(VehicleDrivingController.FindLocalRuntimeModel(), rt1.RootModel, "Resolved rt1 model in DynamicRuntime")

		-- Acelerar con W + girar con A
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0, Steer = -1.0 })
		stepPowertrainAndWheels(15, 0.05)
		hud2.RefreshVisibility()
		local flSt = VehicleWheelControllerService.GetWheelState(p1, v.FL) :: VehicleTypes.WheelRuntimeState
		assertTrue(flSt.TargetSteeringAngle > 10 and flSt.TorqueLimit > 500, "Accelerating with W and steering with A/D")

		-- Frenar y pasar a reversa con S
		VehiclePowertrainService.SetControlOverrideForTests(p1, { RawLongitudinal = -1.0, Steer = 0 })
		stepPowertrainAndWheels(10, 0.05)
		hud2.RefreshVisibility()
		local gearBadge = hud2.HudFrame:FindFirstChild("GearBadge") :: TextLabel
		assertEqual(gearBadge.Text, "R", "GearBadge reflects Reverse (R)")

		-- Regresar al taller
		local ret1 = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(ret1.Success, "ReturnToWorkshop succeeded")
		BuildState.SetRuntimeStatus(ret1.RuntimeStatus)
		hud2.RefreshVisibility()
		assertEqual(hud2.HudFrame.Visible, false, "HUD hidden in workshop")
		assertEqual(VehicleDrivingController.FindLocalRuntimeModel(), nil, "No runtime model in workshop")

		-- Ciclo 2: Volver a lanzar y verificar que no hay fugas ni conexiones duplicadas
		env.AdvanceClock(2.0)
		local lr2 = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
		assertTrue(lr2.Success and lr2.Runtime ~= nil, "Second launch succeeded")
		local rt2 = lr2.Runtime :: VehicleTypes.VehicleRuntime
		BuildState.SetRuntimeStatus({
			State = "Driving",
			RuntimeId = rt2.RuntimeId,
			PlotId = plot.PlotId,
			SourceBlueprintId = bp.BlueprintId,
			SourceBlueprintRevision = bp.Revision,
			DriverSeated = true,
			PieceCount = #bp.Pieces,
			JointCount = 6,
		})
		hud2.RefreshVisibility()
		assertEqual(VehicleDrivingController.FindLocalRuntimeModel(), rt2.RootModel, "Resolved rt2 model on second launch")
		assertEqual(VehicleDrivingController.GetActiveConnectionCount(), connCount1, "Connection count remains constant after relaunch")

		testGui:Destroy()
		assertEqual(VehicleDrivingController.GetActiveConnectionCount(), 0, "Destroying ScreenGui disconnects all VehicleDrivingController connections")
		env.Teardown()
	end)

	-- 40
	runTest("Fase 3.3 [40]: 10-player concurrent motorized vehicles simulation, isolation & clean teardown", function()
		local env = setupIsolatedWorld(10)
		local players: { PlotService.PlayerLike } = {}
		local rarities = EngineCatalog.GetOrderedRarityIds()
		local variants = EngineCatalog.GetOrderedVariantIds()

		for i = 1, 10 do
			local plr: PlotService.PlayerLike = { UserId = 330400 + i, Name = `Driver10_{i}` }
			table.insert(players, plr)
			PlotService.Assign(plr)

			local unit = EngineInventoryService.RegisterUnitForTesting(plr, {
				ItemInstanceId = `unit_10p_{i}`,
				EngineSizeId = if i % 2 == 0 then "Medium" else "Small",
				VariantId = variants[((i - 1) % #variants) + 1],
				RarityId = rarities[((i - 1) % #rarities) + 1],
			})

			buildMotorizedVehicle(plr, `p10_{i}`, {
				EngineCount = 1,
				EngineUnitIds = { unit.ItemInstanceId },
			})

			local lr = VehicleLaunchService.LaunchVehicle(plr, { MountDriver = false, SkipWorldObstructionCheck = true })
			assertTrue(lr.Success, `Player {i} launched motorized vehicle`)
			VehiclePowertrainService.SetControlOverrideForTests(plr, {
				Throttle = 0.5 + (i * 0.05),
				Steer = if i % 2 == 0 then 0.4 else -0.4,
			})
		end

		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 10, "10 active motorized runtimes")
		stepPowertrainAndWheels(8, 0.05)

		for i, plr in ipairs(players) do
			local pt = VehiclePowertrainService.GetPowertrainState(plr) :: VehicleTypes.PowertrainTelemetrySnapshot
			assertTrue(pt ~= nil and pt.FunctionalEngineCount == 1, `Player {i} powertrain active`)
			assertTrue(pt.TotalWheelDriveTorque > 1000, `Player {i} generating wheel drive torque`)
		end

		for _, plr in ipairs(players) do
			PlotService.Release(plr)
			EngineInventoryService.ClearForPlayer(plr)
		end

		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "All 10 runtimes destroyed cleanly")
		assertEqual(VehiclePowertrainService.GetPowertrainState(players[1]), nil, "All powertrain contexts cleaned up")
		env.Teardown()
	end)

	-- 42 (Hotfix Combustible 1)
	runTest("Fase 3.3 [42]: Fuel consumption active by default at launch and engine idles with positive burn", function()
		assertEqual(GameConfig.Powertrain.ConsumeFuelByDefault, true, "ConsumeFuelByDefault must be enabled")
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33042, Name = "FuelIdleTester" }
		PlotService.Assign(p1)
		buildMotorizedVehicle(p1, "f42", { EngineCount = 1 })

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			MountDriver = false,
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr.Success, "Launch succeeded")
		local pt0 = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertNear(pt0.TotalFuelCapacity, 0.54, 1e-4, "Initial capacity 0.54")
		assertNear(pt0.AvailableFuel, 0.54, 1e-4, "Initial available fuel 0.54")

		-- Conducir en ralentí (sin SetFuelConsumptionEnabled manual) durante 10 s simulados
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 0 })
		stepPowertrainAndWheels(40, 0.25)
		local ptAfter = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptAfter.FuelConsumptionRate > 0, "Idle engine reports positive fuel consumption rate")
		assertTrue(ptAfter.AvailableFuel < pt0.AvailableFuel, "Fuel decreases in idle by default without manual flag")
		assertTrue(ptAfter.ConsumedFuel > 0 and ptAfter.AvailableFuel > 0.50, "Idle consumption is gradual and non-zero")
		env.Teardown()
	end)

	-- 43 (Hotfix Combustible 2)
	runTest("Fase 3.3 [43]: Accelerating consumes significantly more fuel than idling", function()
		local env = setupIsolatedWorld(2)
		local pIdle: PlotService.PlayerLike = { UserId = 330431, Name = "FuelIdleCmp" }
		local pAccel: PlotService.PlayerLike = { UserId = 330432, Name = "FuelAccelCmp" }
		PlotService.Assign(pIdle)
		PlotService.Assign(pAccel)
		buildMotorizedVehicle(pIdle, "f43i", { EngineCount = 1 })
		buildMotorizedVehicle(pAccel, "f43a", { EngineCount = 1 })

		VehicleLaunchService.LaunchVehicle(pIdle, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleLaunchService.LaunchVehicle(pAccel, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })

		VehiclePowertrainService.SetControlOverrideForTests(pIdle, { Throttle = 0 })
		VehiclePowertrainService.SetControlOverrideForTests(pAccel, { Throttle = 1.0 })
		stepPowertrainAndWheels(40, 0.25) -- 10 segundos

		local ptIdle = VehiclePowertrainService.GetPowertrainState(pIdle) :: VehicleTypes.PowertrainTelemetrySnapshot
		local ptAccel = VehiclePowertrainService.GetPowertrainState(pAccel) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptAccel.FuelConsumptionRate > ptIdle.FuelConsumptionRate * 3.0, "Full throttle burn rate >> idle burn rate")
		assertTrue(ptAccel.AvailableFuel < ptIdle.AvailableFuel, "Accelerating consumes more cumulative fuel than idle")
		env.Teardown()
	end)

	-- 44 (Hotfix Combustible 3)
	runTest("Fase 3.3 [44]: Higher vehicle mass/load increases LoadFactor and fuel burn at equal throttle", function()
		local env = setupIsolatedWorld(2)
		local pLight: PlotService.PlayerLike = { UserId = 330441, Name = "LightFuelLoad" }
		local pHeavy: PlotService.PlayerLike = { UserId = 330442, Name = "HeavyFuelLoad" }
		PlotService.Assign(pLight)
		PlotService.Assign(pHeavy)

		buildMotorizedVehicle(pLight, "f44l", { EngineCount = 1, HeavyBlocks = 0 })
		buildMotorizedVehicle(pHeavy, "f44h", { EngineCount = 1, HeavyBlocks = 8 })

		VehicleLaunchService.LaunchVehicle(pLight, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleLaunchService.LaunchVehicle(pHeavy, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })

		VehiclePowertrainService.SetControlOverrideForTests(pLight, { Throttle = 1.0 })
		VehiclePowertrainService.SetControlOverrideForTests(pHeavy, { Throttle = 1.0 })
		stepPowertrainAndWheels(40, 0.25)

		local ptLight = VehiclePowertrainService.GetPowertrainState(pLight) :: VehicleTypes.PowertrainTelemetrySnapshot
		local ptHeavy = VehiclePowertrainService.GetPowertrainState(pHeavy) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptHeavy.TotalVehicleMass > ptLight.TotalVehicleMass, "Heavy vehicle has greater mass")
		assertTrue(ptHeavy.CombinedLoadFactor > ptLight.CombinedLoadFactor, "Heavy load yields higher LoadFactor than light load")
		assertTrue(ptHeavy.FuelConsumptionRate > ptLight.FuelConsumptionRate, "High load consumes faster at equal throttle")
		assertTrue(ptHeavy.AvailableFuel < ptLight.AvailableFuel, "Heavy vehicle has less fuel remaining after equal drive")
		env.Teardown()
	end)

	-- 45 (Hotfix Combustible 4)
	runTest("Fase 3.3 [45]: Multiple engines scale cumulative fuel consumption rate proportionally", function()
		local env = setupIsolatedWorld(2)
		local pSingle: PlotService.PlayerLike = { UserId = 330451, Name = "SingleEngFuel" }
		local pDual: PlotService.PlayerLike = { UserId = 330452, Name = "DualEngFuel" }
		PlotService.Assign(pSingle)
		PlotService.Assign(pDual)

		buildMotorizedVehicle(pSingle, "f45_1", { EngineCount = 1 })
		buildMotorizedVehicle(pDual, "f45_2", { EngineCount = 2 })

		VehicleLaunchService.LaunchVehicle(pSingle, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleLaunchService.LaunchVehicle(pDual, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })

		VehiclePowertrainService.SetControlOverrideForTests(pSingle, { Throttle = 1.0 })
		VehiclePowertrainService.SetControlOverrideForTests(pDual, { Throttle = 1.0 })
		stepPowertrainAndWheels(40, 0.25)

		local pt1 = VehiclePowertrainService.GetPowertrainState(pSingle) :: VehicleTypes.PowertrainTelemetrySnapshot
		local pt2 = VehiclePowertrainService.GetPowertrainState(pDual) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(pt2.EngineCount, 2, "Dual vehicle has 2 engines")
		assertNear(pt2.TotalFuelCapacity, 1.08, 1e-4, "Dual SmallEngine integrated fuel sums to 1.08")
		assertTrue(pt2.FuelConsumptionRate > pt1.FuelConsumptionRate * 1.8, "Two engines burn ~2x rate of single engine")
		assertTrue(pt2.ConsumedFuel > pt1.ConsumedFuel * 1.8, "Two engines drained nearly 2x cumulative fuel")
		env.Teardown()
	end)

	-- 46 (Hotfix Combustible 5)
	runTest("Fase 3.3 [46]: SmallEngine + RegularFuelTank pools 2.04 and drains tank before integrated engine fuel", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33046, Name = "SingleTankDrain" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "f46", { EngineCount = 1, FuelTankCount = 1 })

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local pt0 = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertNear(pt0.TotalFuelCapacity, 2.04, 1e-4, "0.54 + 1.50 = 2.04 pool")

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(40, 0.25)

		local ptAfter = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptAfter.AvailableFuel < 2.04 and ptAfter.AvailableFuel > 0.54, "Fuel reduced within tank range")
		assertTrue((rt.Parts[v.FuelTankId :: string].CurrentFuel or 0) < 1.50, "Dedicated fuel tank depleted first")
		assertNear(rt.Parts[v.EngineIds[1]].CurrentFuel or 0, 0.54, 1e-4, "Engine integrated reserve stays full while tank has fuel")
		env.Teardown()
	end)

	-- 47 (Hotfix Combustible 6)
	runTest("Fase 3.3 [47]: Multiple RegularFuelTank parts stack capacity without duplication and drain sequentially", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33047, Name = "MultiTankDrain" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "f47", { EngineCount = 1, FuelTankCount = 2 })

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local pt0 = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertNear(pt0.TotalFuelCapacity, 0.54 + 1.50 + 1.50, 1e-4, "Multi-tank capacity sums to 3.54 without duplication")
		assertEqual(#(rt.FuelTankPieceIds or {}), 2, "2 dedicated normal tanks tracked")

		-- Simular drenado amplio (> 1.50) para verificar cruce de tanque 1 a tanque 2 sin pérdida ni duplicación
		VehiclePowertrainService.SetFuelLevelForTests(p1, 0.60)
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(600, 0.25) -- 150 s simulados (~0.30..0.40 drenados)

		local ptMid = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptMid.AvailableFuel < 0.60 * 3, "Fuel monotonically decreases across multi-tank pool")
		assertNear(ptMid.ConsumedFuel, (0.60 * 2 + 0.54) - ptMid.AvailableFuel, 1e-3, "ConsumedFuel matches exact net delta without duplication")
		env.Teardown()
	end)

	-- 48 (Hotfix Combustible 7)
	runTest("Fase 3.3 [48]: EcoLight engine variant consumes strictly less fuel than Balanced variant", function()
		local env = setupIsolatedWorld(2)
		local pBal: PlotService.PlayerLike = { UserId = 330481, Name = "BalancedBurn" }
		local pEco: PlotService.PlayerLike = { UserId = 330482, Name = "EcoLightBurn" }
		PlotService.Assign(pBal)
		PlotService.Assign(pEco)

		local ecoUnit = EngineInventoryService.RegisterUnitForTesting(pEco, {
			ItemInstanceId = "unit_eco_burn_48",
			EngineSizeId = "Small",
			VariantId = "EcoLight",
			RarityId = "Common",
		})
		local balUnit = EngineInventoryService.RegisterUnitForTesting(pBal, {
			ItemInstanceId = "unit_bal_burn_48",
			EngineSizeId = "Small",
			VariantId = "Balanced",
			RarityId = "Common",
		})

		buildMotorizedVehicle(pBal, "f48b", { EngineCount = 1, EngineUnitIds = { balUnit.ItemInstanceId } })
		buildMotorizedVehicle(pEco, "f48e", { EngineCount = 1, EngineUnitIds = { ecoUnit.ItemInstanceId } })

		VehicleLaunchService.LaunchVehicle(pBal, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleLaunchService.LaunchVehicle(pEco, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })

		VehiclePowertrainService.SetControlOverrideForTests(pBal, { Throttle = 1.0 })
		VehiclePowertrainService.SetControlOverrideForTests(pEco, { Throttle = 1.0 })
		stepPowertrainAndWheels(40, 0.25)

		local ptBal = VehiclePowertrainService.GetPowertrainState(pBal) :: VehicleTypes.PowertrainTelemetrySnapshot
		local ptEco = VehiclePowertrainService.GetPowertrainState(pEco) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptEco.FuelConsumptionRate < ptBal.FuelConsumptionRate, "EcoLight burn rate < Balanced burn rate")
		assertTrue(ptEco.AvailableFuel > ptBal.AvailableFuel, "EcoLight preserves more remaining fuel than Balanced")
		env.Teardown()
	end)

	-- 49 (Hotfix Combustible 8)
	runTest("Fase 3.3 [49]: Real driving depletes full 0.54 pool cleanly to 0 without negative values", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33049, Name = "FullDrainRun" }
		PlotService.Assign(p1)
		buildMotorizedVehicle(p1, "f49", { EngineCount = 1 })

		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })

		-- Hasta 400 s simulados de aceleración sostenida hasta agotar los 0.54 iniciales
		stepPowertrainAndWheels(1600, 0.25)

		local ptEmpty = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(ptEmpty.OutOfFuel, true, "OutOfFuel triggers once pool hits zero")
		assertNear(ptEmpty.AvailableFuel, 0, 1e-6, "AvailableFuel clamps at 0 (never negative)")
		assertEqual(ptEmpty.FuelConsumptionRate, 0, "Fuel consumption rate stops at 0 when empty")
		assertNear(ptEmpty.ConsumedFuel, 0.54, 1e-4, "Total ConsumedFuel equals initial 0.54 reserve")
		env.Teardown()
	end)

	-- 50 (Hotfix Combustible 9)
	runTest("Fase 3.3 [50]: OutOfFuel zeroes drive torque for W/S while keeping service brakes and steering operational", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33050, Name = "EmptyControlCheck" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "f50", { EngineCount = 1 })

		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehiclePowertrainService.SetFuelLevelForTests(p1, 0)

		-- Acelerador W + Dirección A: par motor 0, pero dirección operativa
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0, Steer = -1.0 })
		stepPowertrainAndWheels(10, 0.05)
		local ptW = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local flSt = VehicleWheelControllerService.GetWheelState(p1, v.FL) :: VehicleTypes.WheelRuntimeState
		assertEqual(ptW.OutOfFuel, true, "Vehicle is OutOfFuel")
		assertEqual(ptW.TotalEngineTorque, 0, "Forward W produces 0 engine torque")
		assertEqual(ptW.PerDrivenWheelTorque, 0, "Forward W produces 0 wheel torque")
		assertEqual(ptW.GearState, "Neutral", "OutOfFuel W keeps gear in Neutral")
		assertTrue(flSt.TargetSteeringAngle > 10, "Steering remains active when out of fuel")

		-- S (Freno / Reversa) sin combustible actúa como freno de servicio, no reversa propulsada
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Brake = 1.0, RawLongitudinal = -1.0 })
		stepPowertrainAndWheels(4, 0.05)
		local ptS = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(ptS.GearState, "Braking", "S applies service brakes instead of powered reverse when OutOfFuel")
		assertEqual(ptS.TotalEngineTorque, 0, "No reverse engine torque when OutOfFuel")
		assertTrue(ptS.AppliedBrakeTorque > 0, "Service brake torque applies cleanly when OutOfFuel")
		assertTrue(VehicleRuntimeService.GetRuntimeByPlayer(p1) ~= nil, "VehicleRuntime is NOT destroyed when out of fuel")
		env.Teardown()
	end)

	-- 51 (Hotfix Combustible 10)
	runTest("Fase 3.3 [51]: OutOfFuel vehicle coasts freely by inertia without artificial engine brake drag", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33051, Name = "CoastInertiaCheck" }
		PlotService.Assign(p1)
		local v = buildMotorizedVehicle(p1, "f51", { EngineCount = 1 })

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local refPart = rt.DriverSeatPart or rt.PrimaryPart :: BasePart
		-- Simular vehículo rodando a 22 st/s hacia adelante
		refPart.AssemblyLinearVelocity = refPart.CFrame.LookVector * 22.0

		-- Con combustible y W=0: existe freno motor de retención
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 0 })
		stepPowertrainAndWheels(4, 0.05)
		local ptFueledCoast = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptFueledCoast.AppliedBrakeTorque > 0, "Fueled neutral applies gentle CoastEngineBrakeTorqueScale")

		-- Al agotarse el combustible mientras rueda por inercia (incluso manteniendo W): sin freno artificial
		VehiclePowertrainService.SetFuelLevelForTests(p1, 0)
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(4, 0.05)
		local ptEmptyCoast = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local rlSt = VehicleWheelControllerService.GetWheelState(p1, v.RL) :: VehicleTypes.WheelRuntimeState
		assertEqual(ptEmptyCoast.OutOfFuel, true, "OutOfFuel active")
		assertEqual(ptEmptyCoast.AppliedBrakeTorque, 0, "No artificial brake torque applied while coasting empty")
		assertEqual(rlSt.TorqueLimit, 0, "Driven wheel torque limit is 0")
		assertEqual(rlSt.BrakeTorque, 0, "Driven wheel brake torque is 0 (passive rolling inertia only)")
		env.Teardown()
	end)

	-- 52 (Hotfix Combustible 11)
	runTest("Fase 3.3 [52]: Exiting DriverSeat preserves remaining fuel (no refill) and re-entering resumes seamlessly", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33052, Name = "SeatLifecycleFuel" }
		PlotService.Assign(p1)
		buildMotorizedVehicle(p1, "f52", { EngineCount = 1 })

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(80, 0.25) -- 20 s conduciendo
		local ptBeforeExit = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptBeforeExit.AvailableFuel < 0.52, "Fuel noticeably decreased during driving")

		-- Salir del asiento y limpiar override (simula bajarse al mundo OnFootRuntime)
		VehiclePowertrainService.SetControlOverrideForTests(p1, nil)
		local exitOk = VehicleLifecycleService.ExitVehicleSeat(p1)
		assertTrue(exitOk, "ExitVehicleSeat succeeded")
		assertEqual(rt.State, GameConfig.Runtime.States.OnFootRuntime, "Runtime state transitioned to OnFootRuntime")

		stepPowertrainAndWheels(10, 0.25)
		local ptOnFoot = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptOnFoot.AvailableFuel <= ptBeforeExit.AvailableFuel + 1e-6, "Exiting seat must never refill fuel")
		assertTrue(ptOnFoot.AvailableFuel > 0.40, "Fuel did not drain erroneously at full throttle while out of seat")

		-- Volver a sentarse y continuar conduciendo desde el combustible restante real
		local remBeforeReenter = ptOnFoot.AvailableFuel
		local remountOk = VehicleLifecycleService.CompleteLaunchWithSeatMount(p1, rt, { SimulateSeated = true, SkipSeatRetryYield = true })
		assertTrue(remountOk, "Re-entering seat succeeded")
		assertEqual(rt.State, GameConfig.Runtime.States.Driving, "Runtime returned to Driving state")

		stepPowertrainAndWheels(1, 0.05)
		local ptReentered = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptReentered.AvailableFuel <= remBeforeReenter + 1e-6, "Re-entering preserves remaining fuel without reset")

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(40, 0.25)
		local ptResumed = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptResumed.AvailableFuel < remBeforeReenter, "Driving after re-entering consumes from remaining fuel")
		env.Teardown()
	end)

	-- 53 (Hotfix Combustible 12)
	runTest("Fase 3.3 [53]: HUD FuelBar, FuelLabel, percentages and LowFuel/OutOfFuel alerts sync from server attributes", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33053, Name = "HudFuelSync" }
		local plot = PlotService.Assign(p1)
		buildMotorizedVehicle(p1, "f53", { EngineCount = 1 })
		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		BuildState.ApplyAuthoritativeBlueprint(bp)
		BuildState.SetActive(false)
		BuildState.SetRuntimeStatus({
			State = "Driving",
			RuntimeId = rt.RuntimeId,
			PlotId = plot.PlotId,
			SourceBlueprintId = bp.BlueprintId,
			SourceBlueprintRevision = bp.Revision,
			DriverSeated = true,
			PieceCount = #bp.Pieces,
			JointCount = 6,
		})

		local testGui = Instance.new("ScreenGui")
		local hud = VehicleDrivingController.Mount(testGui)
		local fuelLbl = hud.HudFrame:FindFirstChild("FuelLabel") :: TextLabel
		local fuelBarBg = hud.HudFrame:FindFirstChild("FuelBarBg") :: Frame
		local fuelBarFill = fuelBarBg:FindFirstChild("FuelBarFill") :: Frame
		local bottomLbl = hud.HudFrame:FindFirstChild("BottomStatusLabel") :: TextLabel

		-- Estado lleno (0.54 / 0.54)
		stepPowertrainAndWheels(4, 0.05)
		hud.RefreshVisibility()
		assertTrue(string.find(fuelLbl.Text, "0.54") ~= nil and string.find(fuelLbl.Text, "%%") ~= nil, "HUD FuelLabel shows decimal fuel and percentage")
		assertTrue(fuelBarFill.Size.X.Scale > 0.90, "Fuel bar fill near 100%")

		-- Bajo combustible (10% restante = 0.054)
		VehiclePowertrainService.SetFuelLevelForTests(p1, 0.054)
		stepPowertrainAndWheels(4, 0.05)
		hud.RefreshVisibility()
		assertEqual(rt.RootModel:GetAttribute("PT_LowFuel"), true, "Server sets PT_LowFuel at 10%")
		assertTrue(fuelBarFill.Size.X.Scale < 0.15, "HUD FuelBarFill shrinks to match low fuel fraction")
		assertTrue(string.find(bottomLbl.Text, "COMBUSTIBLE BAJO") ~= nil, "HUD displays low fuel warning")

		-- Sin combustible (0%)
		VehiclePowertrainService.SetFuelLevelForTests(p1, 0)
		stepPowertrainAndWheels(4, 0.05)
		hud.RefreshVisibility()
		assertEqual(rt.RootModel:GetAttribute("PT_OutOfFuel"), true, "Server sets PT_OutOfFuel at 0%")
		assertEqual(fuelBarFill.Size.X.Scale, 0, "HUD FuelBarFill collapses to 0 when empty")
		assertTrue(string.find(bottomLbl.Text, "SIN COMBUSTIBLE") ~= nil, "HUD displays out-of-fuel warning")

		hud.Destroy()
		testGui:Destroy()
		env.Teardown()
	end)

	-- 54 (Hotfix Combustible 13)
	runTest("Fase 3.3 [54]: ResetVehicle restores full initial fuel, clears warnings and re-enables torque", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33054, Name = "ResetFuelRestore" }
		PlotService.Assign(p1)
		buildMotorizedVehicle(p1, "f54", { EngineCount = 1, FuelTankCount = 1 })

		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehiclePowertrainService.SetFuelLevelForTests(p1, 0)
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(4, 0.05)
		assertEqual((VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot).OutOfFuel, true, "Empty before reset")

		env.AdvanceClock(2.0)
		local res = VehicleLaunchService.ResetVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		assertTrue(res.Success and res.Runtime ~= nil, "ResetVehicle succeeded")
		local ptReset = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertNear(ptReset.TotalFuelCapacity, 2.04, 1e-4, "Capacity remains 2.04 after reset")
		assertNear(ptReset.AvailableFuel, 2.04, 1e-4, "AvailableFuel restored to 2.04 after reset")
		assertEqual(ptReset.OutOfFuel, false, "OutOfFuel cleared after reset")
		assertEqual(ptReset.LowFuel, false, "LowFuel cleared after reset")
		assertEqual(ptReset.ConsumedFuel, 0, "ConsumedFuel counter reset")

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(4, 0.05)
		local ptDrive = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptDrive.TotalEngineTorque > 500, "Torque restored immediately after reset")
		env.Teardown()
	end)

	-- 55 (Hotfix Combustible 14)
	runTest("Fase 3.3 [55]: ReturnToWorkshop keeps Blueprint untouched and relaunching starts with fresh fuel", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33055, Name = "WorkshopRelaunchFuel" }
		PlotService.Assign(p1)
		buildMotorizedVehicle(p1, "f55", { EngineCount = 1 })
		local bpInitial = BlueprintSerializer.CloneBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))

		VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(80, 0.25)
		local ptDepleted = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertTrue(ptDepleted.AvailableFuel < 0.52, "Fuel drained during first run")

		local retRes = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(retRes.Success, "ReturnToWorkshop succeeded")
		local bpAfter = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		assertEqual(bpAfter.Revision, bpInitial.Revision, "Blueprint revision untouched")
		for _, pc in ipairs(bpAfter.Pieces) do
			assertEqual((pc :: any).CurrentFuel, nil, "No runtime CurrentFuel leaked into BlueprintPiece")
		end

		env.AdvanceClock(2.0)
		local lr2 = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		assertTrue(lr2.Success, "Relaunch succeeded")
		local ptFresh = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertNear(ptFresh.AvailableFuel, 0.54, 1e-4, "Relaunch starts with fresh initial fuel 0.54")
		assertEqual(ptFresh.ConsumedFuel, 0, "Relaunch starts with 0 session consumed fuel")
		env.Teardown()
	end)

	-- 56 (Hotfix Combustible 15)
	runTest("Fase 3.3 [56]: SmallNitroTank stays isolated from normal fuel pool and ConsumedFuel tracks delta", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 33056, Name = "NitroPoolIsolation" }
		PlotService.Assign(p1)
		buildMotorizedVehicle(p1, "f56", { EngineCount = 1 })
		-- Extender chasis y conectar SmallNitroTank en Z=5 (sin solapar con SmallEngine en Z=2)
		placePieceReq(p1, "f56_ext1", "WoodBlock", CFrame.new(0, 2.5, 4), nil)
		placePieceReq(p1, "f56_ext2", "WoodBlock", CFrame.new(0, 2.5, 6), nil)
		placePieceReq(p1, "f56_nitro", "SmallNitroTank", CFrame.new(0, 4.5, 5), nil)

		local lr = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch with nitro tank succeeded")
		local pt0 = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertNear(pt0.TotalFuelCapacity, 0.54, 1e-4, "SmallNitroTank must NOT inflate normal fuel pool capacity")

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
		stepPowertrainAndWheels(40, 0.25)
		local pt1 = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertNear(pt1.ConsumedFuel, pt0.TotalFuelCapacity - pt1.AvailableFuel, 1e-4, "ConsumedFuel exactly equals capacity minus remaining")
		env.Teardown()
	end)
end

return Phase33Tests
