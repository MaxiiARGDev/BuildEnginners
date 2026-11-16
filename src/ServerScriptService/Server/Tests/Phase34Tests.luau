--!strict
--[=[
	Phase34Tests
	Suite de 46 pruebas automatizadas de Fase 3.4 (Propulsores Modulares, Nitro y Empuje Vectorial):
	- Fidelidad estricta SDD para SmallBooster y SmallNitroTank + etiquetado explícito Provisional_TBD.
	- Inventario autoritativo de propulsores (BoosterInventoryService), anti-duplicación y anti-spoof.
	- Empuje vectorial dinámico 3D vía VectorForce (ApplyAtCenterOfMass = false, RelativeTo = World):
	  empuje simétrico, yaw por montaje descentrado, reversa/frenado, empuje vertical (TWR), rotación dinámica.
	- Separación estricta de pools de combustible: Normal vs Nitro (RocketFuel), sin contaminación cruzada.
	- Curvas de ignición/apagado (Instant, Smooth, Sustained), ThrottleLimitRatio, Enabled ON/OFF,
	  degradación por durabilidad sin mutar Blueprint, envolvente aerodinámica y embrague overrunning.
	- Vehículos propulsados únicamente por boosters (0 motores, 0 ruedas motrices).
	- Ciclo de vida (OnFootRuntime, ReturnToWorkshop, ResetVehicle), orquestador único Heartbeat,
	  BoosterBehavior reactivo sin Heartbeat por pieza, concurrencia de 10 jugadores,
	  controles PC (LeftShift vs Space) / móvil (TouchBoostBtn), HUD de Nitro y guía 3D en taller.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
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
local BoosterInventoryService = require(ServerScriptService.Server.Services.BoosterInventoryService)
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
local VehicleBoosterService = require(ServerScriptService.Server.Services.VehicleBoosterService)
local BuildPayloadValidator = require(ServerScriptService.Server.Security.BuildPayloadValidator)

local BoosterBehavior = require(ServerStorage.ItemAssets.Propulsores.SmallBooster.Behaviors.BoosterBehavior)

local ClientControllers = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState"))
local BoosterInspectorPanel = require(ClientControllers:WaitForChild("BoosterInspectorPanel"))
local VehicleDrivingController = require(ClientControllers:WaitForChild("VehicleDrivingController"))

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase34Tests = {}

local function setupIsolatedWorld(plotCount: number?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder

	local prevPlots = Workspace:FindFirstChild("_Phase34TestPlots")
	if prevPlots then
		prevPlots:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase34TestPlots"
	tempPlots.Parent = Workspace

	BuildService._ResetForTests()
	VehicleLaunchService._ResetForTests()
	VehicleLifecycleService._ResetForTests()
	VehicleRuntimeService._ResetForTests()
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
	VehicleRuntimeService.Init()
	VehicleLifecycleService.Init()
	VehicleLaunchService.Init()
	BuildService.Init()

	local fakeClock = 4000
	local rateLimitClock = 4000
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
			BuildState.Reset()
			tempPlots:Destroy()
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

local function assertNear(actual: number, expected: number, tol: number, msg: string)
	if math.abs(actual - expected) > tol then
		error(`{msg} (expected {expected} ± {tol}, got {actual})`, 2)
	end
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

type BoosterSetupSpec = {
	Offset: CFrame?,
	Config: { [string]: any }?,
	UnitId: string?,
}

local function buildBoosterVehicle(
	player: PlotService.PlayerLike,
	prefix: string,
	options: {
		IncludeEngine: boolean?,
		IncludeNormalTank: boolean?,
		IncludeNitroTank: boolean?,
		NitroTankCount: number?,
		AddRearCrossbar: boolean?,
		HeavyBlocks: number?,
		Boosters: { BoosterSetupSpec }?,
	}?
): {
	SeatId: string,
	EngineId: string?,
	NormalTankId: string?,
	NitroTankIds: { string },
	BoosterIds: { string },
	WheelIds: { string },
}
	local opts = options or {}
	local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)
	local includeEngine = if opts.IncludeEngine == true then true else false
	local freeWheelCfg = if not includeEngine then { Wheel = { IsDriven = false } } else nil

	placePieceReq(player, `{prefix}_bf`, "WoodBlock", CFrame.new(0, 2.5, -2), nil)
	placePieceReq(player, `{prefix}_bm`, "WoodBlock", CFrame.new(0, 2.5, 0), nil)
	placePieceReq(player, `{prefix}_br`, "WoodBlock", CFrame.new(0, 2.5, 2), nil)
	local seatId = placePieceReq(player, `{prefix}_seat`, "DriverSeat", CFrame.new(0, 4.0, -2), nil)

	local nitroCount = opts.NitroTankCount or (if opts.IncludeNitroTank then 1 else 0)
	local engineId: string? = nil
	if includeEngine then
		engineId = placePieceReq(player, `{prefix}_eng`, "SmallEngine", CFrame.new(0, 4.5, 2), nil)
	end

	local spineEndZ = 2
	local normalTankZ = 4.5
	local firstNitroZ = if opts.IncludeNormalTank then 7.5 else 5.5
	local maxNeededZ = 2
	if opts.IncludeNormalTank then
		maxNeededZ = math.max(maxNeededZ, normalTankZ + 1.5)
	end
	if nitroCount >= 1 then
		maxNeededZ = math.max(maxNeededZ, firstNitroZ + (nitroCount - 1) * 3.0 + 1.5)
	end
	while spineEndZ < maxNeededZ do
		spineEndZ += 2
		placePieceReq(player, `{prefix}_sp_{spineEndZ}`, "WoodBlock", CFrame.new(0, 2.5, spineEndZ), nil)
	end

	if opts.AddRearCrossbar then
		placePieceReq(player, `{prefix}_bf2`, "WoodBlock", CFrame.new(0, 2.5, -4), nil)
		placePieceReq(player, `{prefix}_xl`, "WoodBlock", CFrame.new(-2, 2.5, 2), nil)
		placePieceReq(player, `{prefix}_xr`, "WoodBlock", CFrame.new(2, 2.5, 2), nil)
	end

	-- Apilar lastre por encima de las ruedas (Y >= 4.5, Z en [0..2]) para evitar cualquier colisión con ruedas/DriverSeat/booster trasero
	local heavy = opts.HeavyBlocks or 0
	local ballastColumns = {
		{ x = 0, z = 0 },
		{ x = -2, z = 0 },
		{ x = 2, z = 0 },
		{ x = 0, z = 2 },
		{ x = -2, z = 2 },
		{ x = 2, z = 2 },
	}
	local placedBallast = 0
	local layerIdx = 0
	while placedBallast < heavy do
		local yLayer = 4.5 + layerIdx * 2
		for _, col in ipairs(ballastColumns) do
			if placedBallast >= heavy then
				break
			end
			if not (includeEngine and col.x == 0 and col.z == 2 and yLayer == 4.5) then
				placedBallast += 1
				placePieceReq(player, `{prefix}_hv_{placedBallast}`, "WoodBlock", CFrame.new(col.x, yLayer, col.z), nil)
			end
		end
		layerIdx += 1
	end

	local normalTankId: string? = nil
	if opts.IncludeNormalTank then
		normalTankId = placePieceReq(player, `{prefix}_ntnk`, "RegularFuelTank", CFrame.new(0, 4.5, normalTankZ), nil)
	end

	local nitroIds: { string } = {}
	for ni = 1, nitroCount do
		local zPos = firstNitroZ + (ni - 1) * 3.0
		local nid = placePieceReq(player, `{prefix}_nit_{ni}`, "SmallNitroTank", CFrame.new(0, 4.5, zPos), nil)
		table.insert(nitroIds, nid)
	end

	local frontWheelZ = if opts.AddRearCrossbar then -4 else -2
	local rearWheelZ = if opts.AddRearCrossbar then 0 else 2
	local fl = placePieceReq(player, `{prefix}_fl`, "SmallWheel", CFrame.new(-1.5, 2.5, frontWheelZ), freeWheelCfg)
	local fr = placePieceReq(player, `{prefix}_fr`, "SmallWheel", CFrame.new(1.5, 2.5, frontWheelZ) * wheelFlip, freeWheelCfg)
	local rl = placePieceReq(player, `{prefix}_rl`, "SmallWheel", CFrame.new(-1.5, 2.5, rearWheelZ), freeWheelCfg)
	local rr = placePieceReq(player, `{prefix}_rr`, "SmallWheel", CFrame.new(1.5, 2.5, rearWheelZ) * wheelFlip, freeWheelCfg)

	local boosterIds: { string } = {}
	local defaultTailZ = spineEndZ + 2.5
	local specs: { BoosterSetupSpec } = opts.Boosters or {
		{ Offset = CFrame.new(0, 2.5, defaultTailZ) },
	}
	for bi, spec in ipairs(specs) do
		local cf = spec.Offset or CFrame.new(0, 2.5, defaultTailZ)
		local bid = placePieceReq(player, `{prefix}_bst_{bi}`, "SmallBooster", cf, spec.Config, spec.UnitId)
		table.insert(boosterIds, bid)
	end

	return {
		SeatId = seatId,
		EngineId = engineId,
		NormalTankId = normalTankId,
		NitroTankIds = nitroIds,
		BoosterIds = boosterIds,
		WheelIds = { fl, fr, rl, rr },
	}
end

local function stepAllDriving(steps: number, dt: number)
	for _ = 1, steps do
		VehiclePowertrainService.StepAll(dt)
		VehicleBoosterService.StepAll(dt)
		VehicleWheelControllerService.StepAll(dt)
	end
end

function Phase34Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (name: string, fn: () -> ()) -> ()
)
	local _ = results

	-- 1) SDD Fidelity SmallBooster
	runTest("Fase 3.4 [1]: SmallBooster catalog matches SDD stats verbatim and is tagged SDD_Confirmed", function()
		local def = ItemRegistry.Get("SmallBooster")
		assertEqual(def.Category, "Boosters", "SmallBooster category is Boosters")
		assertEqual(def.Stats.Weight, 12, "Weight == 12")
		assertEqual(def.Stats.MaxDurability, 130, "MaxDurability == 130")
		assertEqual(def.Stats.DrivingBonus, 0.3, "DrivingBonus == 0.3")
		assertEqual(def.Stats.FuelType, "RocketFuel", "FuelType == RocketFuel")
		assertEqual(def.Stats.IntegratedFuel, 24000, "IntegratedFuel == 24000")
		assertEqual(def.Stats.BoostConsumption, 12000, "BoostConsumption == 12000")
		assertEqual(def.Stats.Thrust, 12000, "Thrust == 12000")
		assertEqual(def.Stats.SpeedBoostMultiplier, 1, "SpeedBoostMultiplier == 1")
		assertEqual(def.Stats.Price, nil, "No invented Price (TBD)")

		local base = BoosterCatalog.ResolveEffectiveStats({ ItemId = "SmallBooster" })
		assertEqual(base.BoosterSizeId, "Small", "Base size is Small")
		assertEqual(base.BoosterFamilyId, "StandardRocket", "Base family is StandardRocket")
		assertEqual(base.VariantId, "Balanced", "Base variant is Balanced")
		assertEqual(base.RarityId, "Common", "Base rarity is Common")
		assertEqual(base.Thrust, 12000, "Resolved thrust == 12000")
		assertEqual(base.IntegratedFuel, 24000, "Resolved integrated Nitro == 24000")
		assertEqual(base.BoostConsumption, 12000, "Resolved consumption == 12000")
		assertEqual(base.BalanceStatus, "SDD_Confirmed", "Default base booster is SDD_Confirmed")
		assertEqual(base.IsProvisionalBalance, false, "IsProvisionalBalance == false for confirmed SDD base")
	end)

	-- 2) Non-SDD variants, sizes, families, rarities tagged Provisional_TBD
	runTest("Fase 3.4 [2]: Non-SDD sizes/families/variants/6 rarities resolve deterministically as Provisional_TBD", function()
		local base = BoosterCatalog.ResolveEffectiveStats({ ItemId = "SmallBooster" })
		local epic = BoosterCatalog.ResolveEffectiveStats({
			ItemId = "SmallBooster",
			BoosterSizeId = "Medium",
			BoosterFamilyId = "HighImpulse",
			VariantId = "Overboost",
			RarityId = "Epic",
		})
		assertEqual(epic.BaseItemId, "SmallBooster", "Medium/HighImpulse reuses BaseItemId SmallBooster without new asset")
		assertEqual(epic.BalanceStatus, "Provisional_TBD", "Non-SDD combination marked Provisional_TBD")
		assertEqual(epic.IsProvisionalBalance, true, "IsProvisionalBalance == true")
		assertTrue(epic.Thrust > base.Thrust * 2, "Higher size/family/variant/rarity yields significantly higher thrust")

		local sizes = BoosterCatalog.GetOrderedSizeIds()
		local rarities = BoosterCatalog.GetOrderedRarityIds()
		assertEqual(#sizes, 3, "3 booster sizes")
		assertEqual(#rarities, 6, "6 SDD rarities")
		local prevThrust = 0
		for _, rar in ipairs(rarities) do
			local st = BoosterCatalog.ResolveEffectiveStats({ RarityId = rar })
			assertTrue(st.Thrust >= prevThrust, `Rarity progression monotonic at {rar}`)
			if rar ~= "Common" then
				assertEqual(st.BalanceStatus, "Provisional_TBD", `Rarity {rar} marked Provisional_TBD`)
			end
			prevThrust = st.Thrust
		end
	end)

	-- 3) SDD Fidelity SmallNitroTank
	runTest("Fase 3.4 [3]: SmallNitroTank exists with SDD capacity 28800 and RocketFuel/Nitro tags", function()
		local tankDef = ItemRegistry.Get("SmallNitroTank")
		assertEqual(tankDef.Category, "FuelTanks", "SmallNitroTank category FuelTanks")
		assertEqual(tankDef.Stats.Capacity, 28800, "Capacity == 28800")
		assertEqual(tankDef.Stats.FuelType, "RocketFuel", "FuelType == RocketFuel")
		assertEqual(tankDef.Stats.FuelSubtype, "Nitro", "FuelSubtype == Nitro")
		assertEqual(tankDef.Stats.Price, nil, "No invented Price (TBD)")
	end)

	-- 4) Placing SmallBooster without unit auto-assigns owned unit and resolves SDD base without mutating Blueprint
	runTest("Fase 3.4 [4]: Placing SmallBooster without explicit unit auto-assigns owned unit and persists no runtime/invented stats", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34004, Name = "BaseBoosterCheck" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p4")
		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local found = false
		for _, pc in ipairs(bp.Pieces) do
			if pc.InstanceId == v.BoosterIds[1] then
				found = true
				assertTrue(type(pc.InventoryInstanceId) == "string" and #pc.InventoryInstanceId > 0, "Auto-assigned owned booster InventoryInstanceId per A4")
				assertTrue(pc.Config ~= nil and pc.Config.Booster ~= nil, "Config.Booster resolved")
				assertEqual(pc.Config.Booster.BoosterSizeId, "Small", "Resolves to SDD Small")
				assertEqual(pc.Config.Booster.RarityId, "Common", "Resolves to SDD Common")
				assertEqual((pc :: any).CurrentFuel, nil, "No CurrentFuel persisted on blueprint")
				assertEqual((pc :: any).CurrentDurability, nil, "No CurrentDurability persisted on blueprint")
				assertEqual((pc :: any).Thrust, nil, "No flat Thrust persisted on blueprint")
			end
		end
		assertTrue(found, "Placed booster exists in blueprint")
		env.Teardown()
	end)

	-- 5) BoosterInventoryService units + equip / swap / duplicate lock / reset
	runTest("Fase 3.4 [5]: BuildService GetBoosterUnits, equip, swap, duplicate lock, and ResetToAuto", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34005, Name = "BstInvSwap" }
		PlotService.Assign(p1)

		local unitsRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.GetBoosterUnits,
			ClientOpId = "p5_get",
		})
		assertTrue(unitsRes.Success and type(unitsRes.BoosterUnits) == "table", "GetBoosterUnits succeeded")
		assertTrue(#(unitsRes.BoosterUnits :: { any }) >= 4, "Controlled workshop units provisioned")

		local v = buildBoosterVehicle(p1, "p5", {
			AddRearCrossbar = true,
			Boosters = {
				{ Offset = CFrame.new(-2, 2.5, 4.5) },
				{ Offset = CFrame.new(2, 2.5, 4.5) },
			},
		})
		local b1, b2 = v.BoosterIds[1], v.BoosterIds[2]

		-- En Fase 5.1 (A4), colocar b1 y b2 auto-asigna 2 unidades propias; elegimos 2 unidades libres para equip/swap
		local usedByAutoAssign: { [string]: boolean } = {}
		for _, pc in ipairs(VehicleBlueprintService.GetBlueprintSnapshot(p1).Pieces) do
			if pc.InventoryInstanceId and #pc.InventoryInstanceId > 0 then
				usedByAutoAssign[pc.InventoryInstanceId] = true
			end
		end
		local freeUnits: { any } = {}
		for _, u in ipairs(unitsRes.BoosterUnits :: { any }) do
			if not usedByAutoAssign[u.ItemInstanceId] then
				table.insert(freeUnits, u)
			end
		end
		assertTrue(#freeUnits >= 2, "At least 2 free booster units remain after auto-assigning 2 slots")
		local u1 = freeUnits[1]
		local u2 = freeUnits[2]

		local eq1 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UpdatePieceConfig,
			ClientOpId = "p5_eq1",
			PieceInstanceId = b1,
			InventoryInstanceId = u1.ItemInstanceId,
		})
		assertTrue(eq1.Success, "Equip u1 on b1 succeeded")

		-- Intentar duplicar u1 en b2 debe fallar
		local dupRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UpdatePieceConfig,
			ClientOpId = "p5_dup",
			PieceInstanceId = b2,
			InventoryInstanceId = u1.ItemInstanceId,
		})
		assertEqual(dupRes.Success, false, "Duplicate InventoryInstanceId across two boosters blocked")

		-- Intercambiar u1 -> u2 en b1 debe liberar u1 para b2
		local sw1 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UpdatePieceConfig,
			ClientOpId = "p5_sw1",
			PieceInstanceId = b1,
			InventoryInstanceId = u2.ItemInstanceId,
		})
		assertTrue(sw1.Success, "Swap b1 to u2 succeeded")

		local eqFree = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UpdatePieceConfig,
			ClientOpId = "p5_eqfree",
			PieceInstanceId = b2,
			InventoryInstanceId = u1.ItemInstanceId,
		})
		assertTrue(eqFree.Success, "Previously bound u1 freed and equipped on b2")

		-- ResetToAuto libera unidad
		local rst = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UpdatePieceConfig,
			ClientOpId = "p5_rst",
			PieceInstanceId = b1,
			ResetToAuto = true,
			InventoryInstanceId = "",
		})
		assertTrue(rst.Success, "ResetToAuto succeeded")
		local eqFreed2 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UpdatePieceConfig,
			ClientOpId = "p5_eqfreed2",
			PieceInstanceId = b2,
			InventoryInstanceId = u2.ItemInstanceId,
		})
		assertTrue(eqFreed2.Success, "Unit u2 freed after ResetToAuto")
		env.Teardown()
	end)

	-- 6) Security: Anti-spoofing direct stats / rarities in PlacePiece & UpdatePieceConfig
	runTest("Fase 3.4 [6]: Client spoofing direct stats, rarity, family, or size is rejected authoritatively", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34006, Name = "AntiSpoofBst" }
		local p2: PlotService.PlayerLike = { UserId = 34007, Name = "ForeignOwnerBst" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)

		local foreignUnit = BoosterInventoryService.RegisterUnitForTesting(p2, {
			RarityId = "Mythic",
			VariantId = "Overboost",
			BoosterSizeId = "Large",
		})

		local v = buildBoosterVehicle(p1, "p6")
		local bid = v.BoosterIds[1]

		for _, forbiddenField in ipairs({ "Thrust", "BoostConsumption", "IntegratedFuel", "RarityId", "BoosterSizeId", "BoosterFamilyId", "VariantId" }) do
			local cfgPayload = { Booster = { [forbiddenField] = if forbiddenField == "Thrust" then 999999 else "Mythic" } }
			local res = BuildService.ProcessRequest(p1, {
				Action = BuildProtocol.Actions.UpdatePieceConfig,
				ClientOpId = `p6_spoof_{forbiddenField}`,
				PieceInstanceId = bid,
				Config = cfgPayload,
			})
			assertEqual(res.Success, false, `Spoof key {forbiddenField} rejected`)
			assertEqual(res.ErrorCode, BuildProtocol.ErrorCodes.ForbiddenDirectStatsPayload, `Exact ForbiddenDirectStatsPayload error for {forbiddenField}`)
		end

		local foreignRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UpdatePieceConfig,
			ClientOpId = "p6_foreign",
			PieceInstanceId = bid,
			InventoryInstanceId = foreignUnit.ItemInstanceId,
		})
		assertEqual(foreignRes.Success, false, "Equipping another player's InventoryInstanceId rejected")
		env.Teardown()
	end)

	-- 7) Security: Config bounds (ThrustLimitRatio, ThrottleCurveMode, Enabled)
	runTest("Fase 3.4 [7]: BuildPayloadValidator enforces ThrustLimitRatio bounds and valid ThrottleCurveMode", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34008, Name = "BstCfgBounds" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p7")

		local ok1 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UpdatePieceConfig,
			ClientOpId = "p7_ok",
			PieceInstanceId = v.BoosterIds[1],
			Config = { Booster = { ThrustLimitRatio = 0.25, ThrottleCurveMode = "Sustained", Enabled = true } },
		})
		assertTrue(ok1.Success, "Valid booster config accepted")

		local badCurve = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UpdatePieceConfig,
			ClientOpId = "p7_badcurve",
			PieceInstanceId = v.BoosterIds[1],
			Config = { Booster = { ThrottleCurveMode = "TurboCheat" } },
		})
		assertEqual(badCurve.Success, false, "Invalid ThrottleCurveMode rejected")

		local badLimit = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.UpdatePieceConfig,
			ClientOpId = "p7_badlim",
			PieceInstanceId = v.BoosterIds[1],
			Config = { Booster = { ThrustLimitRatio = 9.0 } },
		})
		assertEqual(badLimit.Success, false, "Out-of-range ThrustLimitRatio > 1.0 rejected")
		env.Teardown()
	end)

	-- 8) Security: ApplyClientBoostInput ownership & runtime state verification
	runTest("Fase 3.4 [8]: VehicleBoosterService validates owner and rejects OnFoot boost injection", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 34009, Name = "BoostOwnerA" }
		local p2: PlotService.PlayerLike = { UserId = 34010, Name = "BoostOtherB" }
		PlotService.Assign(p1)
		PlotService.Assign(p2)
		buildBoosterVehicle(p1, "p8")

		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })

		local okForeign, errForeign = VehicleBoosterService.ApplyClientBoostInput(p2, true)
		assertEqual(okForeign, false, "Non-owner cannot activate p1 booster")
		assertTrue(errForeign ~= nil, "Error code returned")
		assertEqual(VehicleBoosterService.IsBoostActiveForPlayer(p1), false, "p1 booster remains off")

		local okOwner = VehicleBoosterService.ApplyClientBoostInput(p1, true)
		assertTrue(okOwner, "Owner can activate booster while seated Driving")
		VehicleBoosterService.StepAll(0.1)
		assertTrue(VehicleBoosterService.IsBoostActiveForPlayer(p1), "p1 booster active after owner input")

		VehicleLifecycleService.ExitVehicleSeat(p1)
		local okOnFoot, errOnFoot = VehicleBoosterService.ApplyClientBoostInput(p1, true)
		assertEqual(okOnFoot, false, "Boost input rejected while OnFootRuntime")
		assertTrue(errOnFoot ~= nil, "Error code returned on OnFootRuntime")
		env.Teardown()
	end)

	-- 9) ValidateRequest handles SetDrivingInput + Boost payload strictly
	runTest("Fase 3.4 [9]: BuildPayloadValidator ValidateRequest validates SetDrivingInput Boost field cleanly", function()
		local valOk, reqOk, errCode1 = BuildPayloadValidator.ValidateRequest({
			Action = BuildProtocol.Actions.SetDrivingInput,
			ClientOpId = "op9_1",
			Throttle = 0,
			Brake = 0,
			Steer = 0,
			Boost = true,
		})
		assertEqual(valOk, true, `Valid SetDrivingInput accepted ({tostring(errCode1)})`)
		assertEqual(reqOk ~= nil and (reqOk :: any).Boost, true, "Validated request preserves Boost = true")

		local hbRejectedOk, _, hbErr = BuildPayloadValidator.ValidateRequest({
			Action = BuildProtocol.Actions.SetDrivingInput,
			ClientOpId = "op9_hb",
			Handbrake = true,
		} :: any)
		assertEqual(hbRejectedOk, false, "Legacy Handbrake field rejected by ValidateRequest")
		assertEqual(hbErr, BuildProtocol.ErrorCodes.InvalidPayload, "InvalidPayload error code on Handbrake")

		local badOk, reqBad, errBad = BuildPayloadValidator.ValidateRequest({
			Action = BuildProtocol.Actions.SetDrivingInput,
			ClientOpId = "op9_2",
			Boost = "yes" :: any,
		})
		assertEqual(badOk, false, "ValidateRequest returns false on bad Boost")
		assertEqual(reqBad, nil, "Non-boolean Boost rejected by ValidateRequest")
		assertEqual(errBad, BuildProtocol.ErrorCodes.InvalidPayload, "InvalidPayload error code")
	end)

	-- 10) VectorForce properties: ApplyAtCenterOfMass = false, RelativeTo = World, real Attachment
	runTest("Fase 3.4 [10]: Runtime creates VectorForce with ApplyAtCenterOfMass=false and RelativeTo=World", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34011, Name = "VFProps" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p10")

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local slot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1])
		assertTrue(slot ~= nil, "Booster slot registered")

		local bPart = rt.Parts[v.BoosterIds[1]].PrimaryPart :: BasePart
		local vf = bPart:FindFirstChild("BoosterVectorForce") :: VectorForce
		assertTrue(vf ~= nil and vf:IsA("VectorForce"), "BoosterVectorForce exists on booster PrimaryPart")
		assertEqual(vf.ApplyAtCenterOfMass, false, "VectorForce ApplyAtCenterOfMass must be false for off-center torque")
		assertEqual(vf.RelativeTo, Enum.ActuatorRelativeTo.World, "VectorForce RelativeTo must be World")
		assertTrue(vf.Attachment0 ~= nil and vf.Attachment0:IsDescendantOf(rt.RootModel), "VectorForce Attachment0 anchored to vehicle assembly")
		assertEqual(vf.Enabled, false, "Disabled while idle")
		env.Teardown()
	end)

	-- 11) Real Studio physics forward acceleration (Symmetric Rear Boost)
	runTest("Fase 3.4 [11]: Real physics forward booster accelerates vehicle along WorldThrustDirection", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34012, Name = "PhysicsForward" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p11")

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local refPart = (rt.DriverSeatPart or rt.PrimaryPart) :: BasePart
		local startPos = refPart.Position

		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		local tEnd = os.clock() + 0.45
		while os.clock() < tEnd do
			stepAllDriving(1, 0.02)
			task.wait(0.02)
		end

		local snap = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		local slot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState
		assertTrue(snap.AnyBoosterActive, "Booster active")
		assertTrue(slot.AppliedThrust > 8000, `VectorForce pushing strongly ({slot.AppliedThrust})`)
		local forwardSpeed = refPart.AssemblyLinearVelocity:Dot(refPart.CFrame.LookVector)
		local forwardDisp = (refPart.Position - startPos):Dot(refPart.CFrame.LookVector)
		assertTrue(forwardSpeed > 5.0, `Real forward speed gained ({forwardSpeed} st/s)`)
		assertTrue(forwardDisp > 1.0, `Vehicle moved forward in Studio physics ({forwardDisp} studs)`)
		VehicleBoosterService.SetBoostOverrideForTests(p1, nil)
		env.Teardown()
	end)

	-- 12) Reversed Booster (180 deg Y) pushes backwards / brakes
	runTest("Fase 3.4 [12]: Reversed 180-deg booster reverses WorldThrustDirection and pushes backward", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34013, Name = "PhysicsReverse" }
		PlotService.Assign(p1)
		local revRot = BuildRotation.RotateY(BuildRotation.Identity(), 2)
		buildBoosterVehicle(p1, "p12", {
			Boosters = {
				{ Offset = CFrame.new(0, 4.25, 2) * revRot },
			},
		})

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local refPart = (rt.DriverSeatPart or rt.PrimaryPart) :: BasePart

		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		local tEnd = os.clock() + 0.40
		while os.clock() < tEnd do
			stepAllDriving(1, 0.02)
			task.wait(0.02)
		end

		local snap = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertTrue(snap.NetThrustVector:Dot(-refPart.CFrame.LookVector) > 8000, "Net thrust points backward relative to DriverSeat")
		local forwardSpeed = refPart.AssemblyLinearVelocity:Dot(refPart.CFrame.LookVector)
		assertTrue(forwardSpeed < -4.0, `Vehicle accelerates in reverse ({forwardSpeed} st/s)`)
		VehicleBoosterService.SetBoostOverrideForTests(p1, nil)
		env.Teardown()
	end)

	-- 13) Upward (+Y) thrust lifts light vehicle but cannot lift ballasted 25%-capped heavy vehicle
	runTest("Fase 3.4 [13]: Upward (+Y) booster lifts light vehicle while heavy 25%-capped vehicle stays grounded", function()
		local env = setupIsolatedWorld(2)
		local pLight: PlotService.PlayerLike = { UserId = 34014, Name = "LightLift" }
		local pHeavy: PlotService.PlayerLike = { UserId = 34015, Name = "HeavyNoLift" }
		PlotService.Assign(pLight)
		PlotService.Assign(pHeavy)

		local upRot = BuildRotation.RotateX(BuildRotation.Identity(), 1)
		local lightUnits = {}
		local heavyUnits = {}
		for i = 1, 4 do
			lightUnits[i] = BoosterInventoryService.RegisterUnitForTesting(pLight, {
				BoosterSizeId = "Small",
				BoosterFamilyId = "HighImpulse",
				VariantId = "Overboost",
				RarityId = "Mythic",
			}).ItemInstanceId
			heavyUnits[i] = BoosterInventoryService.RegisterUnitForTesting(pHeavy, {
				BoosterSizeId = "Small",
				BoosterFamilyId = "HighImpulse",
				VariantId = "Overboost",
				RarityId = "Mythic",
			}).ItemInstanceId
		end

		buildBoosterVehicle(pLight, "p13L", {
			AddRearCrossbar = true,
			IncludeEngine = false,
			Boosters = {
				{
					Offset = CFrame.new(-1.75, 3.0, -2) * upRot,
					Config = { Booster = { ThrottleCurveMode = "Instant" } },
					UnitId = lightUnits[1],
				},
				{
					Offset = CFrame.new(1.75, 3.0, -2) * upRot,
					Config = { Booster = { ThrottleCurveMode = "Instant" } },
					UnitId = lightUnits[2],
				},
				{
					Offset = CFrame.new(-2, 3.0, 3.75) * upRot,
					Config = { Booster = { ThrottleCurveMode = "Instant", ThrustLimitRatio = 0.94 } },
					UnitId = lightUnits[3],
				},
				{
					Offset = CFrame.new(2, 3.0, 3.75) * upRot,
					Config = { Booster = { ThrottleCurveMode = "Instant", ThrustLimitRatio = 0.94 } },
					UnitId = lightUnits[4],
				},
			},
		})
		buildBoosterVehicle(pHeavy, "p13H", {
			AddRearCrossbar = true,
			IncludeEngine = false,
			HeavyBlocks = 14,
			Boosters = {
				{
					Offset = CFrame.new(-1.75, 3.0, -2) * upRot,
					Config = { Booster = { ThrustLimitRatio = 0.25, ThrottleCurveMode = "Instant" } },
					UnitId = heavyUnits[1],
				},
				{
					Offset = CFrame.new(1.75, 3.0, -2) * upRot,
					Config = { Booster = { ThrustLimitRatio = 0.25, ThrottleCurveMode = "Instant" } },
					UnitId = heavyUnits[2],
				},
				{
					Offset = CFrame.new(-2, 3.0, 3.75) * upRot,
					Config = { Booster = { ThrustLimitRatio = 0.25, ThrottleCurveMode = "Instant" } },
					UnitId = heavyUnits[3],
				},
				{
					Offset = CFrame.new(2, 3.0, 3.75) * upRot,
					Config = { Booster = { ThrustLimitRatio = 0.25, ThrottleCurveMode = "Instant" } },
					UnitId = heavyUnits[4],
				},
			},
		})

		local lrL = VehicleLaunchService.LaunchVehicle(pLight, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local lrH = VehicleLaunchService.LaunchVehicle(pHeavy, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local refL = (lrL.Runtime :: VehicleTypes.VehicleRuntime).PrimaryPart :: BasePart
		local refH = (lrH.Runtime :: VehicleTypes.VehicleRuntime).PrimaryPart :: BasePart
		local startYL = refL.Position.Y
		local startYH = refH.Position.Y

		VehicleBoosterService.SetBoostOverrideForTests(pLight, true)
		VehicleBoosterService.SetBoostOverrideForTests(pHeavy, true)
		local tEnd = os.clock() + 0.32
		while os.clock() < tEnd do
			stepAllDriving(1, 0.02)
			task.wait(0.02)
		end

		local snapL = VehicleBoosterService.GetBoosterState(pLight) :: VehicleTypes.BoosterTelemetrySnapshot
		assertTrue(snapL.NetThrustVector.Y > 70000, `Upward NetThrustVector.Y > 70000 ({snapL.NetThrustVector.Y})`)
		local dyL = refL.Position.Y - startYL
		local dyH = refH.Position.Y - startYH
		assertTrue(dyL > 1.2 or refL.AssemblyLinearVelocity.Y > 4.0, `Light upward booster lifts vehicle cleanly (dy={dyL}, vy={refL.AssemblyLinearVelocity.Y})`)
		assertTrue(dyH < dyL * 0.5, `Heavy capped booster rises significantly less / stays grounded (dyH={dyH} vs dyL={dyL})`)
		VehicleBoosterService.SetBoostOverrideForTests(pLight, nil)
		VehicleBoosterService.SetBoostOverrideForTests(pHeavy, nil)
		env.Teardown()
	end)

	-- 14 & 15) Off-center Asymmetric Yaw vs Symmetric Twin Boosters
	runTest("Fase 3.4 [14]: Off-center asymmetric booster produces real yaw torque vs symmetric twin setup", function()
		local env = setupIsolatedWorld(2)
		local pAsym: PlotService.PlayerLike = { UserId = 34016, Name = "AsymYaw" }
		local pSym: PlotService.PlayerLike = { UserId = 34017, Name = "SymTwin" }
		PlotService.Assign(pAsym)
		PlotService.Assign(pSym)

		buildBoosterVehicle(pAsym, "p14a", {
			AddRearCrossbar = true,
			Boosters = {
				{ Offset = CFrame.new(2, 2.5, 4.5) },
			},
		})
		buildBoosterVehicle(pSym, "p14s", {
			AddRearCrossbar = true,
			Boosters = {
				{ Offset = CFrame.new(-2, 2.5, 4.5) },
				{ Offset = CFrame.new(2, 2.5, 4.5) },
			},
		})

		local lrA = VehicleLaunchService.LaunchVehicle(pAsym, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local lrS = VehicleLaunchService.LaunchVehicle(pSym, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local refA = (lrA.Runtime :: VehicleTypes.VehicleRuntime).PrimaryPart :: BasePart
		local refS = (lrS.Runtime :: VehicleTypes.VehicleRuntime).PrimaryPart :: BasePart

		VehicleBoosterService.SetBoostOverrideForTests(pAsym, true)
		VehicleBoosterService.SetBoostOverrideForTests(pSym, true)
		local tEnd = os.clock() + 0.40
		while os.clock() < tEnd do
			stepAllDriving(1, 0.02)
			task.wait(0.02)
		end

		local yawRateAsym = math.abs(refA.AssemblyAngularVelocity.Y)
		local yawRateSym = math.abs(refS.AssemblyAngularVelocity.Y)
		local fwdSym = refS.AssemblyLinearVelocity:Dot(refS.CFrame.LookVector)
		assertTrue(yawRateAsym > 0.35, `Asymmetric offset booster produces real yaw angular velocity ({yawRateAsym} rad/s)`)
		assertTrue(yawRateAsym > yawRateSym * 2.5 + 0.15, `Asymmetric yaw ({yawRateAsym}) exceeds symmetric ({yawRateSym})`)
		assertTrue(fwdSym > 8.0, `Symmetric twin boosters accelerate straight strongly ({fwdSym} st/s)`)
		VehicleBoosterService.SetBoostOverrideForTests(pAsym, nil)
		VehicleBoosterService.SetBoostOverrideForTests(pSym, nil)
		env.Teardown()
	end)

	-- 15) Diagonal / Sideways rotated booster aims thrust along WorldSpace of rotated nozzle
	runTest("Fase 3.4 [15]: Sideways 90-deg booster aims VectorForce laterally relative to chassis", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34018, Name = "LateralYaw" }
		PlotService.Assign(p1)
		local rotLeft = BuildRotation.RotateY(BuildRotation.Identity(), 1) -- -Z -> -X
		buildBoosterVehicle(p1, "p15", {
			Boosters = {
				{ Offset = CFrame.new(0, 4.25, 2) * rotLeft },
			},
		})

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local ref = rt.PrimaryPart :: BasePart
		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		VehicleBoosterService.StepAll(0.15)
		VehicleBoosterService.StepAll(0.15)

		local snap = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertTrue(snap.NetThrustVector:Dot(-ref.CFrame.RightVector) > 8000, "Lateral 90-deg booster aims along -RightVector")
		env.Teardown()
	end)

	-- 16) Dynamic rotation tracking: as assembly rotates, WorldThrustDirection tracks PrimaryPart.CFrame
	runTest("Fase 3.4 [16]: Dynamic WorldThrustDirection updates live when vehicle rotates in world", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34019, Name = "DynamicWorldDir" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p16")
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local bPart = rt.Parts[v.BoosterIds[1]].PrimaryPart :: BasePart

		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		VehicleBoosterService.StepAll(0.1)
		local dir1 = (VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState).WorldThrustDirection

		rt.RootModel:PivotTo(rt.RootModel:GetPivot() * CFrame.Angles(0, math.rad(90), 0))
		VehicleBoosterService.StepAll(0.05)
		local dir2 = (VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState).WorldThrustDirection
		assertNear(dir1:Dot(dir2), 0, 0.05, "WorldThrustDirection rotated 90 deg with chassis")
		assertTrue(dir2:Dot(bPart.CFrame.LookVector) > 0.99, "Matches live booster LookVector")
		env.Teardown()
	end)

	-- 17) LaunchPreparationService reports BoosterCount, FunctionalBoosterCount, TotalNitroCapacity & separate Normal Fuel
	runTest("Fase 3.4 [17]: LaunchPreparationService separates TotalNormalFuelCapacity and TotalNitroCapacity", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34020, Name = "LaunchPrepSplit" }
		PlotService.Assign(p1)
		buildBoosterVehicle(p1, "p17", {
			IncludeEngine = true,
			IncludeNormalTank = true,
			IncludeNitroTank = true,
		})

		local report = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1)
		assertEqual(report.Ready, true, "Hybrid vehicle ready")
		assertEqual(report.BoosterCount, 1, "1 booster")
		assertEqual(report.FunctionalBoosterCount, 1, "1 functional booster")
		assertEqual(report.TotalBoosterThrust, 12000, "TotalBoosterThrust == 12000")
		assertNear(report.TotalNormalFuelCapacity or 0, 0.54 + 1.5, 1e-4, "Normal fuel excludes Nitro capacity (SmallEngine 0.54 + RegularFuelTank 1.5 = 2.04)")
		assertNear(report.TotalNitroCapacity or 0, 24000 + 28800, 1e-2, "Nitro capacity sums SmallBooster + SmallNitroTank (52800)")
		env.Teardown()
	end)

	-- 18) Integrated + SmallNitroTank capacity strict sum & isolation from Powertrain
	runTest("Fase 3.4 [18]: Nitro pool integrates SmallBooster (24000) + SmallNitroTank (28800) without touching Powertrain fuel", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34021, Name = "FuelIsolation" }
		PlotService.Assign(p1)
		buildBoosterVehicle(p1, "p18", {
			IncludeEngine = true,
			IncludeNitroTank = true,
		})

		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local bs = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot

		assertNear(pt.TotalFuelCapacity, 0.54, 1e-4, "Powertrain Normal fuel == 0.54 (no Nitro leaked in)")
		assertNear(bs.TotalNitroCapacity, 52800, 1e-2, "Booster Nitro == 52800 (24000 + 28800)")
		assertNear(bs.AvailableNitro, 52800, 1e-2, "AvailableNitro == 52800")
		env.Teardown()
	end)

	-- 19) Engine throttle alone consumes Normal fuel ONLY; Nitro stays 100%
	runTest("Fase 3.4 [19]: Accelerating Engine alone consumes Normal fuel while Nitro remains 100%", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34022, Name = "EngineOnlyBurn" }
		PlotService.Assign(p1)
		buildBoosterVehicle(p1, "p19", {
			IncludeEngine = true,
			IncludeNitroTank = true,
		})

		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0, Boost = false })
		stepAllDriving(48, 0.25)

		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local bs = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertTrue(pt.AvailableFuel < 0.52, `Normal fuel decreased ({pt.AvailableFuel})`)
		assertNear(bs.AvailableNitro, 52800, 1e-3, "Nitro stayed untouched at 52800")
		assertEqual(bs.ConsumedNitro, 0, "ConsumedNitro == 0")
		env.Teardown()
	end)

	-- 20) Boosting alone consumes Nitro ONLY; Engine Normal fuel only incurs idle burn (zero boost leakage)
	runTest("Fase 3.4 [20]: Firing Boost with Throttle=0 consumes Nitro while Engine Normal fuel remains untouched", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 34023, Name = "BoostOnlyBurn" }
		local pIdle: PlotService.PlayerLike = { UserId = 34053, Name = "IdleBaselineBurn" }
		PlotService.Assign(p1)
		PlotService.Assign(pIdle)
		buildBoosterVehicle(p1, "p20", {
			IncludeEngine = true,
			IncludeNitroTank = true,
		})
		buildBoosterVehicle(pIdle, "p20i", {
			IncludeEngine = true,
			IncludeNitroTank = true,
		})

		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleLaunchService.LaunchVehicle(pIdle, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 0, Boost = true })
		VehiclePowertrainService.SetControlOverrideForTests(pIdle, { Throttle = 0, Boost = false })
		stepAllDriving(12, 0.1)

		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local ptIdle = VehiclePowertrainService.GetPowertrainState(pIdle) :: VehicleTypes.PowertrainTelemetrySnapshot
		local bs = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertNear(pt.AvailableFuel, ptIdle.AvailableFuel, 1e-4, "Engine Normal fuel matches idle baseline during Boost (0 boost leakage)")
		assertTrue(bs.AvailableNitro < 52800 - 4000, `Nitro consumed significantly ({bs.AvailableNitro})`)
		assertNear(bs.ConsumedNitro, bs.TotalNitroCapacity - bs.AvailableNitro, 1e-2, "ConsumedNitro matches delta")
		env.Teardown()
	end)

	-- 21) Normal Fuel = 0 -> Booster still fires on Nitro!
	runTest("Fase 3.4 [21]: OutOfFuel (Normal) stops engine drive while Booster continues thrusting on Nitro", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34024, Name = "NormalEmptyNitroWorks" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p21", { IncludeEngine = true })

		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehiclePowertrainService.SetFuelLevelForTests(p1, 0)
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0, Boost = true })
		stepAllDriving(10, 0.1)

		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local bs = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		local slot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState
		assertEqual(pt.OutOfFuel, true, "Engine Normal fuel is empty")
		assertEqual(pt.TotalWheelDriveTorque, 0, "Engine wheel torque is 0")
		assertTrue(bs.AnyBoosterActive, "Booster remains active")
		assertTrue(slot.AppliedThrust > 9000, `Booster generates full thrust ({slot.AppliedThrust}) despite OutOfFuel`)
		env.Teardown()
	end)

	-- 22) Nitro = 0 -> Booster cuts cleanly while Engine still drives wheels normally!
	runTest("Fase 3.4 [22]: OutOfNitro enters Depleted and cuts VectorForce while Engine still drives wheels normally", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34025, Name = "NitroEmptyEngineWorks" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p22", { IncludeEngine = true })

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0, Boost = true })
		-- Drenar todo el Nitro (24000 a 12000/s ~ 2.0s + rampa)
		stepAllDriving(30, 0.1)

		local bs = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local slot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState
		local vf = (rt.Parts[v.BoosterIds[1]].PrimaryPart :: BasePart):FindFirstChild("BoosterVectorForce") :: VectorForce

		assertEqual(bs.OutOfNitro, true, "OutOfNitro flagged")
		assertEqual(bs.AvailableNitro, 0, "AvailableNitro clamped to 0")
		assertEqual(slot.BoosterState, "Depleted", "BoosterState transitions to Depleted")
		assertEqual(vf.Enabled, false, "VectorForce disabled when Depleted")
		assertEqual(vf.Force, Vector3.zero, "VectorForce Force zeroed when Depleted")
		assertEqual(pt.OutOfFuel, false, "Engine Normal fuel still available")
		assertTrue(pt.TotalWheelDriveTorque > 500, "Engine keeps driving wheels normally")
		env.Teardown()
	end)

	-- 23) Multiple Boosters + Multi SmallNitroTank drain proportionally & accurately
	runTest("Fase 3.4 [23]: Two Boosters + Two SmallNitroTanks share Nitro pool proportionally", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34026, Name = "MultiNitroShare" }
		PlotService.Assign(p1)
		buildBoosterVehicle(p1, "p23", {
			AddRearCrossbar = true,
			NitroTankCount = 2,
			Boosters = {
				{ Offset = CFrame.new(-2, 2.5, 4.5) },
				{ Offset = CFrame.new(2, 2.5, 4.5) },
			},
		})

		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local bs0 = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		-- 2*24000 + 2*28800 = 105600
		assertNear(bs0.TotalNitroCapacity, 105600, 1.0, "Total Nitro sums 2 integrated + 2 SmallNitroTank")

		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		stepAllDriving(10, 0.1) -- 1.0 s total, after ramp ~24000/s rate
		local bs1 = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertEqual(bs1.ActiveBoosterCount, 2, "Both boosters active")
		assertTrue(bs1.ConsumedNitro > 15000 and bs1.ConsumedNitro <= 25000, `Dual consumption consistent with 2x12000/s ({bs1.ConsumedNitro})`)
		env.Teardown()
	end)

	-- 24) ThrottleCurveModes: Instant reaches peak thrust faster than Smooth & Sustained
	runTest("Fase 3.4 [24]: Ignition curve modes Instant > Smooth > Sustained ramp response timing", function()
		local env = setupIsolatedWorld(3)
		local pInst: PlotService.PlayerLike = { UserId = 34027, Name = "CurveInstant" }
		local pSmooth: PlotService.PlayerLike = { UserId = 34028, Name = "CurveSmooth" }
		local pSust: PlotService.PlayerLike = { UserId = 34029, Name = "CurveSustained" }
		PlotService.Assign(pInst)
		PlotService.Assign(pSmooth)
		PlotService.Assign(pSust)

		local vI = buildBoosterVehicle(pInst, "cI", { Boosters = { { Config = { Booster = { ThrottleCurveMode = "Instant" } } } } })
		local vS = buildBoosterVehicle(pSmooth, "cS", { Boosters = { { Config = { Booster = { ThrottleCurveMode = "Smooth" } } } } })
		local vU = buildBoosterVehicle(pSust, "cU", { Boosters = { { Config = { Booster = { ThrottleCurveMode = "Sustained" } } } } })

		VehicleLaunchService.LaunchVehicle(pInst, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleLaunchService.LaunchVehicle(pSmooth, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleLaunchService.LaunchVehicle(pSust, { SimulateSeated = true, SkipWorldObstructionCheck = true })

		VehicleBoosterService.SetBoostOverrideForTests(pInst, true)
		VehicleBoosterService.SetBoostOverrideForTests(pSmooth, true)
		VehicleBoosterService.SetBoostOverrideForTests(pSust, true)
		VehicleBoosterService.StepAll(0.05)

		local tI = (VehicleBoosterService.GetBoosterSlotState(pInst, vI.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState).ThrottleFraction
		local tS = (VehicleBoosterService.GetBoosterSlotState(pSmooth, vS.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState).ThrottleFraction
		local tU = (VehicleBoosterService.GetBoosterSlotState(pSust, vU.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState).ThrottleFraction
		assertEqual(tI, 1.0, "Instant hits 100% throttle immediately")
		assertTrue(tS > tU and tS < 1.0, `Smooth ({tS}) ramps faster than Sustained ({tU}) at 0.05s`)
		env.Teardown()
	end)

	-- 25) Smooth RampDown to Idle on releasing Boost
	runTest("Fase 3.4 [25]: Releasing Boost transitions Smooth booster through RampDown down to Idle", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34030, Name = "RampDownIdle" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p25", {
			Boosters = { { Config = { Booster = { ThrottleCurveMode = "Smooth" } } } },
		})

		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		stepAllDriving(6, 0.05)
		local activeSlot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState
		assertEqual(activeSlot.BoosterState, "Active", "Reached Active state")

		VehicleBoosterService.SetBoostOverrideForTests(p1, false)
		VehicleBoosterService.StepAll(0.04)
		local midSlot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState
		assertEqual(midSlot.BoosterState, "RampDown", "Transitions smoothly into RampDown")
		assertTrue(midSlot.ThrottleFraction > 0.05 and midSlot.ThrottleFraction < 1.0, "Decaying throttle during RampDown")

		stepAllDriving(10, 0.05)
		local idleSlot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState
		assertEqual(idleSlot.BoosterState, "Idle", "Settles to Idle")
		assertEqual(idleSlot.AppliedThrust, 0, "AppliedThrust == 0 when Idle")
		env.Teardown()
	end)

	-- 26) ThrustLimitRatio (25% / 50% / 75% / 100%) scales thrust & consumption cleanly
	runTest("Fase 3.4 [26]: ThrustLimitRatio linearly scales EffectiveThrustMax and NitroConsumptionRate", function()
		local env = setupIsolatedWorld(2)
		local pFull: PlotService.PlayerLike = { UserId = 34031, Name = "Lim100" }
		local pHalf: PlotService.PlayerLike = { UserId = 34032, Name = "Lim50" }
		PlotService.Assign(pFull)
		PlotService.Assign(pHalf)

		buildBoosterVehicle(pFull, "lf", { Boosters = { { Config = { Booster = { ThrottleCurveMode = "Instant", ThrustLimitRatio = 1.0 } } } } })
		buildBoosterVehicle(pHalf, "lh", { Boosters = { { Config = { Booster = { ThrottleCurveMode = "Instant", ThrustLimitRatio = 0.5 } } } } })

		VehicleLaunchService.LaunchVehicle(pFull, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleLaunchService.LaunchVehicle(pHalf, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleBoosterService.SetBoostOverrideForTests(pFull, true)
		VehicleBoosterService.SetBoostOverrideForTests(pHalf, true)
		VehicleBoosterService.StepAll(0.1)

		local sFull = VehicleBoosterService.GetBoosterState(pFull) :: VehicleTypes.BoosterTelemetrySnapshot
		local sHalf = VehicleBoosterService.GetBoosterState(pHalf) :: VehicleTypes.BoosterTelemetrySnapshot
		assertNear(sHalf.TotalAppliedThrust, sFull.TotalAppliedThrust * 0.5, 50, "50% thrust limit halves thrust")
		assertNear(sHalf.NitroConsumptionRate, sFull.NitroConsumptionRate * 0.5, 50, "50% thrust limit halves consumption rate")
		env.Teardown()
	end)

	-- 27) Enabled = false disables individual booster selectively while twin keeps working
	runTest("Fase 3.4 [27]: Enabled=false disables one booster cleanly while sibling booster fires", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34033, Name = "SelectiveDisable" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p27", {
			AddRearCrossbar = true,
			Boosters = {
				{ Offset = CFrame.new(-2, 2.5, 4.5), Config = { Booster = { Enabled = false } } },
				{ Offset = CFrame.new(2, 2.5, 4.5), Config = { Booster = { Enabled = true, ThrottleCurveMode = "Instant" } } },
			},
		})

		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		VehicleBoosterService.StepAll(0.05)

		local disSlot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState
		local enSlot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[2]) :: VehicleTypes.BoosterRuntimeState
		assertEqual(disSlot.BoosterState, "Disabled", "Disabled booster stays Disabled")
		assertEqual(disSlot.AppliedThrust, 0, "Disabled booster produces 0 thrust")
		assertEqual(enSlot.BoosterState, "Active", "Enabled booster fires normally")
		assertTrue(enSlot.AppliedThrust > 10000, "Enabled booster outputs thrust")
		env.Teardown()
	end)

	-- 28) Runtime durability degradation reduces thrust without mutating Blueprint
	runTest("Fase 3.4 [28]: Runtime durability damage scales booster thrust and cuts out when destroyed (<5%)", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34034, Name = "BstDurability" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p28", {
			Boosters = { { Config = { Booster = { ThrottleCurveMode = "Instant" } } } },
		})

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local partSt = rt.Parts[v.BoosterIds[1]]

		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		VehicleBoosterService.StepAll(0.02)
		local fullThrust = (VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState).AppliedThrust

		-- Dañar durabilidad runtime al 50% (factor = 0.85) y luego al 25% (factor = 0.60)
		partSt.CurrentDurability = partSt.MaxDurability * 0.50
		VehicleBoosterService.StepAll(0.02)
		local halfSlot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState
		assertNear(halfSlot.DurabilityEfficiencyFactor, 0.85, 0.02, "Durability efficiency factor is 0.85 at 50% HP")
		assertTrue(halfSlot.AppliedThrust < fullThrust * 0.90, "50% damaged booster outputs reduced thrust")

		partSt.CurrentDurability = partSt.MaxDurability * 0.25
		VehicleBoosterService.StepAll(0.02)
		local lowSlot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState
		assertTrue(lowSlot.DurabilityEfficiencyFactor < 0.75, "Durability efficiency factor drops below 0.75 at 25% HP")
		assertTrue(lowSlot.AppliedThrust < fullThrust * 0.70, "25% damaged booster outputs sharply reduced thrust")

		-- Romper debajo del 5% mínimo operativo
		partSt.CurrentDurability = 0
		partSt.IsFunctional = false
		VehicleBoosterService.StepAll(0.02)
		local deadSlot = VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState
		assertEqual(deadSlot.BoosterState, "Destroyed", "0 HP marks booster Destroyed")
		assertEqual(deadSlot.AppliedThrust, 0, "Destroyed booster outputs 0 thrust")

		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		for _, pc in ipairs(bp.Pieces) do
			assertEqual((pc :: any).CurrentDurability, nil, "Blueprint has no runtime CurrentDurability mutation")
		end
		env.Teardown()
	end)

	-- 29) Overrunning clutch in VehiclePowertrainService (zero brake/coast drag during Boost)
	runTest("Fase 3.4 [29]: Powertrain overrunning clutch frees driven wheels when booster accelerates beyond top speed", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34035, Name = "OverrunningClutch" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p29", { IncludeEngine = true })

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local refPart = (rt.DriverSeatPart or rt.PrimaryPart) :: BasePart

		-- Vehículo lanzado a 130 st/s (muy por encima de SpeedRegular=60 de SmallEngine) bajo Boost activo
		refPart.AssemblyLinearVelocity = refPart.CFrame.LookVector * 130.0
		VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0, Boost = true })
		stepAllDriving(4, 0.05)

		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		local rlSt = VehicleWheelControllerService.GetWheelState(p1, v.WheelIds[3]) :: VehicleTypes.WheelRuntimeState
		assertEqual(pt.TotalWheelDriveTorque, 0, "Overrunning clutch cuts opposing engine torque above top speed")
		assertEqual(pt.AppliedBrakeTorque, 0, "Overrunning clutch applies 0 drag brake while booster overspeeds")
		assertEqual(rlSt.BrakeTorque, 0, "Driven wheel BrakeTorque == 0 so booster flies unimpeded")
		env.Teardown()
	end)

	-- 30) Aerodynamic speed envelope taper at high speed without NaN
	runTest("Fase 3.4 [30]: Aerodynamic envelope tapers thrust above top speed cleanly with zero NaN", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34036, Name = "AeroEnvelope" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p30", {
			Boosters = { { Config = { Booster = { ThrottleCurveMode = "Instant" } } } },
		})

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local refPart = (rt.DriverSeatPart or rt.PrimaryPart) :: BasePart

		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		refPart.AssemblyLinearVelocity = Vector3.zero
		VehicleBoosterService.StepAll(0.02)
		local lowSpeedThrust = (VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState).AppliedThrust

		refPart.AssemblyLinearVelocity = refPart.CFrame.LookVector * 200.0
		VehicleBoosterService.StepAll(0.02)
		local highSpeedThrust = (VehicleBoosterService.GetBoosterSlotState(p1, v.BoosterIds[1]) :: VehicleTypes.BoosterRuntimeState).AppliedThrust
		assertTrue(highSpeedThrust == highSpeedThrust and highSpeedThrust >= 0, "Finite non-NaN thrust at 200 st/s")
		assertTrue(highSpeedThrust < lowSpeedThrust, `Aerodynamic envelope tapers thrust at high speed ({highSpeedThrust} < {lowSpeedThrust})`)
		env.Teardown()
	end)

	-- 31) Booster-only vehicle (0 engines, 0 driven wheels): LaunchPrep Ready=true & accelerates via Boost
	runTest("Fase 3.4 [31]: Booster-only vehicle (0 engines, 0 driven wheels) validates Ready and drives via Boost", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34037, Name = "PureBoosterCar" }
		PlotService.Assign(p1)
		buildBoosterVehicle(p1, "p31", {
			IncludeEngine = false,
			IncludeNormalTank = false,
		})

		local report = VehicleLaunchPreparationService.EvaluatePlayerLaunch(p1)
		assertEqual(report.Ready, true, "Booster-only car Ready without Engine/DrivenWheels errors")
		assertEqual(report.EngineCount, 0, "0 engines")
		assertEqual(report.DrivenWheelCount, 0, "0 driven wheels")
		assertEqual(report.BoosterCount, 1, "1 booster")

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Booster-only launch succeeded")
		local pt = VehiclePowertrainService.GetPowertrainState(p1) :: VehicleTypes.PowertrainTelemetrySnapshot
		assertEqual(pt.NoDrivenWheelsError, false, "NoDrivenWheelsError not raised when 0 engines")

		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		stepAllDriving(3, 0.1)
		local bs = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertTrue(bs.TotalAppliedThrust > 9000, "Pure rocket craft produces full thrust")
		env.Teardown()
	end)

	-- 32) Exiting DriverSeat (OnFootRuntime) cuts VectorForce immediately & preserves remaining Nitro
	runTest("Fase 3.4 [32]: Exiting DriverSeat cuts VectorForce immediately, preserves Nitro, and resumes on re-entry", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34038, Name = "OnFootNitro" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p32", {
			Boosters = { { Config = { Booster = { ThrottleCurveMode = "Instant" } } } },
		})

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local vf = (rt.Parts[v.BoosterIds[1]].PrimaryPart :: BasePart):FindFirstChild("BoosterVectorForce") :: VectorForce

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Boost = true })
		stepAllDriving(8, 0.1)
		local bsBefore = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertTrue(bsBefore.AvailableNitro < 24000 - 4000, "Nitro consumed while boosting")
		assertTrue(vf.Enabled and vf.Force.Magnitude > 5000, "VectorForce active prior to seat exit")

		VehiclePowertrainService.SetControlOverrideForTests(p1, nil)
		local exOk = VehicleLifecycleService.ExitVehicleSeat(p1)
		assertTrue(exOk, "Exited DriverSeat cleanly")
		assertEqual(rt.State, GameConfig.Runtime.States.OnFootRuntime, "State is OnFootRuntime")
		assertEqual(vf.Enabled, false, "VectorForce disabled immediately on ExitVehicleSeat")
		assertEqual(vf.Force, Vector3.zero, "VectorForce Force zeroed immediately")

		local remBeforeReenter = (VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot).AvailableNitro
		local reOk = VehicleLifecycleService.CompleteLaunchWithSeatMount(p1, rt, { SimulateSeated = true, SkipSeatRetryYield = true })
		assertTrue(reOk, "Re-entered DriverSeat")
		assertNear((VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot).AvailableNitro, remBeforeReenter, 1e-2, "Remaining Nitro preserved without refill on re-entry")

		VehiclePowertrainService.SetControlOverrideForTests(p1, { Boost = true })
		stepAllDriving(4, 0.1)
		local bsAfter = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertTrue(bsAfter.AvailableNitro < remBeforeReenter, "Nitro resumes draining on boost after re-entry")
		env.Teardown()
	end)

	-- 33) ReturnToWorkshop & ResetVehicle clean booster slots completely and leave Blueprint pure
	runTest("Fase 3.4 [33]: ReturnToWorkshop and ResetVehicle clear booster slots without mutating Blueprint", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34039, Name = "CleanupLifecycle" }
		PlotService.Assign(p1)
		buildBoosterVehicle(p1, "p33", { IncludeNitroTank = true })
		local bp0 = BlueprintSerializer.CloneBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))

		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		stepAllDriving(20, 0.1)
		assertTrue((VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot).AvailableNitro < 52800, "Nitro consumed")

		env.AdvanceClock(2.0)
		local rstRes = VehicleLaunchService.ResetVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		assertTrue(rstRes.Success, "ResetVehicle succeeded")
		local bsReset = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertNear(bsReset.AvailableNitro, 52800, 1e-2, "ResetVehicle restores fresh 52800 Nitro")
		assertEqual(bsReset.ConsumedNitro, 0, "ConsumedNitro resets to 0")

		local retRes = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(retRes.Success, "ReturnToWorkshop succeeded")
		assertEqual(VehicleBoosterService.GetBoosterState(p1), nil, "Booster context unregistered after ReturnToWorkshop")

		local bp1 = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		assertEqual(bp1.Revision, bp0.Revision, "Blueprint revision untouched")
		env.Teardown()
	end)

	-- 34) Sequential relaunches start with fresh full Nitro regardless of previous depletion
	runTest("Fase 3.4 [34]: Relaunch starts with fresh 100% Nitro even after total depletion in prior attempt", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34040, Name = "RelaunchFreshNitro" }
		PlotService.Assign(p1)
		buildBoosterVehicle(p1, "p34")

		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		stepAllDriving(35, 0.1)
		assertEqual((VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot).OutOfNitro, true, "First run depleted Nitro completely")

		VehicleLaunchService.ReturnToWorkshop(p1)
		env.AdvanceClock(2.0)
		VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local bs2 = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertNear(bs2.AvailableNitro, 24000, 1e-2, "Second launch starts with fresh 24000 Nitro")
		assertEqual(bs2.OutOfNitro, false, "OutOfNitro cleared on fresh launch")
		env.Teardown()
	end)

	-- 35) Single centralized orchestrator, ZERO scripts/Heartbeat loops inside ItemAsset SmallBooster
	runTest("Fase 3.4 [35]: SmallBooster uses centralized VehicleBoosterService with zero per-part Script/Heartbeat loops", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34041, Name = "CentralizedCheck" }
		PlotService.Assign(p1)
		buildBoosterVehicle(p1, "p35")

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		for _, desc in ipairs(rt.RootModel:GetDescendants()) do
			assertTrue(not desc:IsA("Script") and not desc:IsA("LocalScript"), `No Script inside assembled VehicleRuntime ({desc:GetFullName()})`)
		end

		local behaviorMod = ServerStorage.ItemAssets.Propulsores.SmallBooster.Behaviors.BoosterBehavior
		local codeOnly = string.gsub(string.gsub(behaviorMod.Source, "%-%-%[=*%[.-%]=*%]", ""), "%-%-[^\n]*", "")
		assertEqual(string.find(codeOnly, "Heartbeat"), nil, "BoosterBehavior code has zero Heartbeat loops")
		assertEqual(string.find(codeOnly, "Stepped"), nil, "BoosterBehavior code has zero Stepped loops")
		env.Teardown()
	end)

	-- 36) BoosterBehavior initializes NozzleAttachment, emitters, pointlight, safe ThrustSound and toggles reactively
	runTest("Fase 3.4 [36]: BoosterBehavior reactive VFX activates at NozzleAttachment and shuts off cleanly on Destroy", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34042, Name = "BehaviorVFX" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p36", {
			Boosters = { { Config = { Booster = { ThrottleCurveMode = "Instant" } } } },
		})

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		local partSt = rt.Parts[v.BoosterIds[1]]
		local model = partSt.ModelInstance :: Model
		local prim = partSt.PrimaryPart :: BasePart

		assertEqual(model:GetAttribute("BehaviorInitialized"), true, "ItemRuntimeService initialized BoosterBehavior on launch")
		local nozzleAtt = prim:FindFirstChild("NozzleAttachment") :: Attachment
		assertTrue(nozzleAtt ~= nil and nozzleAtt:IsA("Attachment"), "NozzleAttachment present")
		assertNear((nozzleAtt.Position - GameConfig.Boosters.DefaultNozzleLocalOffset).Magnitude, 0, 1e-4, "NozzleAttachment placed at +Z nozzle offset")

		local flame = nozzleAtt:FindFirstChild("FlameEmitter") :: ParticleEmitter
		local smoke = nozzleAtt:FindFirstChild("SmokeEmitter") :: ParticleEmitter
		local light = nozzleAtt:FindFirstChild("NozzleLight") :: PointLight
		local sound = prim:FindFirstChild("ThrustSound") :: Sound
		assertTrue(flame ~= nil and smoke ~= nil and light ~= nil and sound ~= nil, "All nozzle VFX/Audio children created")
		assertEqual(flame.Enabled, false, "Flame initially off")
		assertEqual(light.Enabled, false, "Light initially off")
		assertEqual(sound.SoundId, "", "Safe empty SoundId avoids bogus audio asset warnings")

		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		VehicleBoosterService.StepAll(0.05)
		task.wait()
		assertEqual(flame.Enabled, true, "Flame activates reactively via attribute change")
		assertEqual(smoke.Enabled, true, "Smoke activates reactively")
		assertEqual(light.Enabled, true, "Light activates reactively")
		assertTrue(light.Brightness > 1.0, "PointLight brightness scales during boost")

		BoosterBehavior.Destroy(rt, partSt, model)
		assertEqual(flame.Enabled, false, "Flame shuts off cleanly on Destroy")
		assertEqual(light.Enabled, false, "Light shuts off cleanly on Destroy")
		env.Teardown()
	end)

	-- 37) Multiple rarities/families apply distinct runtime attributes and physical mass
	runTest("Fase 3.4 [37]: Mythic Overboost Medium Booster applies greater thrust, Nitro capacity, and mass than Common Small", function()
		local env = setupIsolatedWorld(2)
		local pCommon: PlotService.PlayerLike = { UserId = 34043, Name = "CommonBst" }
		local pMythic: PlotService.PlayerLike = { UserId = 34044, Name = "MythicBst" }
		PlotService.Assign(pCommon)
		PlotService.Assign(pMythic)

		local mythicUnit = BoosterInventoryService.RegisterUnitForTesting(pMythic, {
			BoosterSizeId = "Medium",
			BoosterFamilyId = "HighImpulse",
			VariantId = "Overboost",
			RarityId = "Mythic",
		})
		local vC = buildBoosterVehicle(pCommon, "c37")
		local vM = buildBoosterVehicle(pMythic, "m37", {
			Boosters = { { UnitId = mythicUnit.ItemInstanceId } },
		})

		local lrC = VehicleLaunchService.LaunchVehicle(pCommon, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local lrM = VehicleLaunchService.LaunchVehicle(pMythic, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rtC = lrC.Runtime :: VehicleTypes.VehicleRuntime
		local rtM = lrM.Runtime :: VehicleTypes.VehicleRuntime

		local mC = (rtC.Parts[vC.BoosterIds[1]].ModelInstance :: Model)
		local mM = (rtM.Parts[vM.BoosterIds[1]].ModelInstance :: Model)
		assertEqual(mM:GetAttribute("BoosterRarityId"), "Mythic", "BoosterRarityId attribute set on assembled Mythic booster")
		assertTrue((mM:GetAttribute("BoosterThrust") :: number) > (mC:GetAttribute("BoosterThrust") :: number) * 2, "Mythic thrust > 2x Common")

		local bsC = VehicleBoosterService.GetBoosterState(pCommon) :: VehicleTypes.BoosterTelemetrySnapshot
		local bsM = VehicleBoosterService.GetBoosterState(pMythic) :: VehicleTypes.BoosterTelemetrySnapshot
		assertTrue(bsM.TotalNitroCapacity > bsC.TotalNitroCapacity, "Medium/Mythic has higher integrated Nitro reserve")
		env.Teardown()
	end)

	-- 38) Detaching/destroying 1 of 2 boosters keeps survivor functional and updates NetThrustVector
	runTest("Fase 3.4 [38]: Destroying 1 of 2 boosters updates FunctionalBoosterCount and preserves survivor thrust", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34045, Name = "PartialDamage" }
		PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p38", {
			AddRearCrossbar = true,
			Boosters = {
				{ Offset = CFrame.new(-2, 2.5, 4.5), Config = { Booster = { ThrottleCurveMode = "Instant" } } },
				{ Offset = CFrame.new(2, 2.5, 4.5), Config = { Booster = { ThrottleCurveMode = "Instant" } } },
			},
		})

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		VehicleBoosterService.StepAll(0.05)

		local sBefore = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertEqual(sBefore.FunctionalBoosterCount, 2, "Both boosters functional initially")

		rt.Parts[v.BoosterIds[1]].IsDetached = true
		VehicleBoosterService.StepAll(0.05)
		local sAfter = VehicleBoosterService.GetBoosterState(p1) :: VehicleTypes.BoosterTelemetrySnapshot
		assertEqual(sAfter.FunctionalBoosterCount, 1, "FunctionalBoosterCount drops to 1")
		assertNear(sAfter.TotalAppliedThrust, sBefore.TotalAppliedThrust * 0.5, 100, "TotalAppliedThrust halves with 1 survivor")
		env.Teardown()
	end)

	-- 39) 10 concurrent players across 10 plots boosting & stepping independently
	runTest("Fase 3.4 [39]: 10 concurrent players run hybrid/booster vehicles across 10 plots without cross-contamination", function()
		local env = setupIsolatedWorld(10)
		local players: { PlotService.PlayerLike } = {}
		for i = 1, 10 do
			local p: PlotService.PlayerLike = { UserId = 34100 + i, Name = `BstP{i}` }
			PlotService.Assign(p)
			table.insert(players, p)
			buildBoosterVehicle(p, `m10_{i}`, {
				IncludeEngine = (i % 2 == 1),
				IncludeNitroTank = (i % 3 == 0),
				Boosters = { { Config = { Booster = { ThrottleCurveMode = "Instant" } } } },
			})
			local lr = VehicleLaunchService.LaunchVehicle(p, { SimulateSeated = true, SkipWorldObstructionCheck = true })
			assertTrue(lr.Success, `Player {i} launch succeeded`)
			VehicleBoosterService.SetBoostOverrideForTests(p, i % 2 == 0)
		end

		stepAllDriving(8, 0.05)
		for i, p in ipairs(players) do
			local bs = VehicleBoosterService.GetBoosterState(p) :: VehicleTypes.BoosterTelemetrySnapshot
			if i % 2 == 0 then
				assertTrue(bs.AnyBoosterActive and bs.ConsumedNitro > 1000, `Even player {i} boosted cleanly`)
			else
				assertEqual(bs.AnyBoosterActive, false, `Odd player {i} did not falsely boost`)
				assertEqual(bs.ConsumedNitro, 0, `Odd player {i} consumed 0 Nitro`)
			end
		end

		for _, p in ipairs(players) do
			VehicleLaunchService.ReturnToWorkshop(p)
		end
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "All 10 runtimes cleaned up")
		env.Teardown()
	end)

	-- 40) Controls PC: LeftShift (Boost) only, Handbrake completely removed from VehicleDrivingController
	runTest("Fase 3.4 [40]: VehicleDrivingController triggers Boost via LeftShift with Handbrake completely removed", function()
		local src = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers"):WaitForChild("VehicleDrivingController").Source
		local shiftBlock = string.match(src, "Enum%.KeyCode%.LeftShift[^\n]*\n[^\n]*Boost%s*=%s*true")
		assertTrue(shiftBlock ~= nil, "LeftShift maps cleanly to Boost")
		assertEqual(string.find(src, "Handbrake", 1, true), nil, "Handbrake completely removed from VehicleDrivingController")
		assertEqual(string.find(src, "Space or Enum.KeyCode.LeftShift"), nil, "LeftShift must NOT share Space binding")
	end)

	-- 41) Mobile TouchBoostBtn present alongside drive touch buttons, without TouchHandbrakeBtn
	runTest("Fase 3.4 [41]: VehicleDrivingController mounts mobile TouchBoostBtn without TouchHandbrakeBtn", function()
		local testGui = Instance.new("ScreenGui")
		local hud = VehicleDrivingController.Mount(testGui)
		local mobileFrame = hud.TouchControlsFrame
		assertTrue(mobileFrame ~= nil and mobileFrame.Name == "MobileDrivingControls", "TouchControlsFrame exists")
		local boostBtn = mobileFrame:FindFirstChild("TouchBoostBtn") :: TextButton
		local hbBtn = mobileFrame:FindFirstChild("TouchHandbrakeBtn")
		local thrBtn = mobileFrame:FindFirstChild("TouchThrottleBtn") :: TextButton
		assertTrue(boostBtn ~= nil and boostBtn:IsA("TextButton"), "TouchBoostBtn mounted for mobile players")
		assertEqual(hbBtn, nil, "TouchHandbrakeBtn completely removed")
		assertTrue(thrBtn ~= nil, "TouchThrottleBtn remains intact")
		assertEqual(boostBtn.Text, "BOOST", "TouchBoostBtn labeled BOOST")
		hud.Destroy()
		testGui:Destroy()
	end)

	-- 42) HUD Nitro sync, BoostBadge, BoosterSummaryLabel, low/empty Nitro alerts & booster-only message
	runTest("Fase 3.4 [42]: Driving HUD syncs Nitro bar, BoostBadge ON/OFF/NO NITRO and booster-only alerts", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34046, Name = "HudNitroSync" }
		local plot = PlotService.Assign(p1)
		buildBoosterVehicle(p1, "p42", {
			IncludeEngine = false,
			Boosters = { { Config = { Booster = { ThrottleCurveMode = "Instant" } } } },
		})
		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local lr = VehicleLaunchService.LaunchVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime

		BuildState.SetExpectedOwner(p1.UserId)
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
			JointCount = 5,
		})

		local testGui = Instance.new("ScreenGui")
		local hud = VehicleDrivingController.Mount(testGui)
		local boostBadge = hud.HudFrame:FindFirstChild("BoostBadge") :: TextLabel
		local nitroLbl = hud.HudFrame:FindFirstChild("NitroLabel") :: TextLabel
		local nitroFill = (hud.HudFrame:FindFirstChild("NitroBarBg") :: Frame):FindFirstChild("NitroBarFill") :: Frame
		local bstSummary = hud.HudFrame:FindFirstChild("BoosterSummaryLabel") :: TextLabel
		local bottomLbl = hud.HudFrame:FindFirstChild("BottomStatusLabel") :: TextLabel

		-- Idle lleno
		stepAllDriving(2, 0.05)
		hud.RefreshVisibility()
		assertEqual(boostBadge.Text, "BOOST OFF", "Badge shows BOOST OFF when idle")
		assertTrue(string.find(nitroLbl.Text, "24000") ~= nil and string.find(nitroLbl.Text, "%%") ~= nil, "NitroLabel displays capacity and %")
		assertTrue(nitroFill.Size.X.Scale > 0.90, "NitroBarFill near 100%")
		assertTrue(string.find(bottomLbl.Text, "SOLO PROPULSIÓN NITRO") ~= nil, "Booster-only hint shown")

		-- Boost activo
		VehicleBoosterService.SetBoostOverrideForTests(p1, true)
		stepAllDriving(2, 0.05)
		hud.RefreshVisibility()
		assertEqual(boostBadge.Text, "BOOST ON", "Badge switches to BOOST ON")
		assertTrue(string.find(bstSummary.Text, "Activos: 1") ~= nil, "BoosterSummaryLabel counts active booster")

		-- Agotado
		VehicleBoosterService.SetNitroLevelForTests(p1, 0)
		stepAllDriving(2, 0.05)
		hud.RefreshVisibility()
		assertEqual(boostBadge.Text, "NO NITRO", "Badge displays NO NITRO when depleted")
		assertEqual(nitroFill.Size.X.Scale, 0, "NitroBarFill collapses to 0")
		assertTrue(string.find(bottomLbl.Text, "SIN NITRO") ~= nil, "Out of nitro alert rendered")

		hud.Destroy()
		testGui:Destroy()
		env.Teardown()
	end)

	-- 43) BoosterInspectorPanel SDD Confirmado vs Provisional (TBD) badges
	runTest("Fase 3.4 [43]: BoosterInspectorPanel displays SDD Confirmado for base SmallBooster and Provisional (TBD) for Epic unit", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34047, Name = "InspectorBadges" }
		local plot = PlotService.Assign(p1)
		local epicUnit = BoosterInventoryService.RegisterUnitForTesting(p1, {
			BoosterFamilyId = "ExtendedBurn",
			BoosterSizeId = "Medium",
			VariantId = "Lightweight",
			RarityId = "Epic",
		})
		local v = buildBoosterVehicle(p1, "p43", {
			AddRearCrossbar = true,
			Boosters = {
				{ Offset = CFrame.new(-2, 2.5, 4.5) },
				{ Offset = CFrame.new(2, 2.5, 4.5), UnitId = epicUnit.ItemInstanceId },
			},
		})
		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)

		BuildState.SetExpectedOwner(p1.UserId)
		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		BuildState.ApplyAuthoritativeBlueprint(bp)
		BuildState.SetActive(true)
		BuildState.SetRuntimeStatus({
			State = "Editing",
			RuntimeId = nil,
			PlotId = plot.PlotId,
			SourceBlueprintId = bp.BlueprintId,
			SourceBlueprintRevision = bp.Revision,
			DriverSeated = false,
			PieceCount = #bp.Pieces,
			JointCount = 0,
		})

		local testGui = Instance.new("ScreenGui")
		local insp = BoosterInspectorPanel.Mount(testGui)
		local badge = insp.Frame:FindFirstChild("BalanceBadge") :: TextLabel
		local statsBox = insp.Frame:FindFirstChild("StatsBox") :: TextLabel

		BuildState.SetSelectedPlacedPiece(v.BoosterIds[1])
		insp.Refresh()
		assertEqual(insp.Frame.Visible, true, "Panel visible for SmallBooster")
		assertEqual(badge.Text, "SDD Confirmado", "Base SmallBooster displays SDD Confirmado badge")
		assertTrue(string.find(statsBox.Text, "Adelante") ~= nil, "Direction label displays Adelante (-Z)")

		BuildState.SetSelectedPlacedPiece(v.BoosterIds[2])
		insp.Refresh()
		assertEqual(badge.Text, "Provisional (TBD)", "Epic variant displays Provisional (TBD) badge")
		assertTrue(string.find(statsBox.Text, "ExtendedBurn") ~= nil, "Displays BoosterFamilyId")

		insp.Destroy()
		testGui:Destroy()
		env.Teardown()
	end)

	-- 44) BoosterInspectorPanel 3D non-physical BoosterThrustGuide aligns dynamically
	runTest("Fase 3.4 [44]: BoosterInspectorPanel spawns non-physical 3D thrust guide matching piece orientation", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34048, Name = "Guide3D" }
		local plot = PlotService.Assign(p1)
		local upRot = BuildRotation.RotateX(BuildRotation.Identity(), 1)
		local v = buildBoosterVehicle(p1, "p44", {
			AddRearCrossbar = true,
			Boosters = {
				{ Offset = CFrame.new(-2, 2.5, 4.5) },
				{ Offset = CFrame.new(2, 3.0, 3.75) * upRot },
			},
		})
		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)

		BuildState.SetExpectedOwner(p1.UserId)
		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		BuildState.ApplyAuthoritativeBlueprint(bp)
		BuildState.SetActive(true)
		BuildState.SetRuntimeStatus({
			State = "Editing",
			RuntimeId = nil,
			PlotId = plot.PlotId,
			SourceBlueprintId = bp.BlueprintId,
			SourceBlueprintRevision = bp.Revision,
			DriverSeated = false,
			PieceCount = #bp.Pieces,
			JointCount = 0,
		})

		local testGui = Instance.new("ScreenGui")
		local insp = BoosterInspectorPanel.Mount(testGui)

		BuildState.SetSelectedPlacedPiece(v.BoosterIds[1])
		insp.Refresh()
		local guide1 = insp.GetActiveGuideModel()
		assertTrue(guide1 ~= nil and guide1:IsDescendantOf(Workspace), "Guide exists in Workspace/Camera")
		assertEqual(guide1:GetAttribute("DirectionLabel"), "Adelante (-Z)", "Forward booster guide labeled Adelante (-Z)")
		for _, part in ipairs(guide1:GetDescendants()) do
			if part:IsA("BasePart") then
				assertEqual(part.CanCollide, false, "Guide part must have CanCollide=false")
				assertEqual(part.CanTouch, false, "Guide part must have CanTouch=false")
				assertEqual(part.CanQuery, false, "Guide part must have CanQuery=false")
				assertEqual(part.Anchored, true, "Guide part must be Anchored=true")
			end
		end

		BuildState.SetSelectedPlacedPiece(v.BoosterIds[2])
		insp.Refresh()
		local guide2 = insp.GetActiveGuideModel()
		assertTrue(guide2 ~= nil, "Guide stays alive for rotated booster")
		assertEqual(guide2:GetAttribute("DirectionLabel"), "Arriba (+Y)", "Upward booster guide labeled Arriba (+Y)")
		local vecDir = guide2:GetAttribute("VehicleThrustDirection") :: Vector3
		assertTrue(vecDir.Y > 0.95, `VehicleThrustDirection points +Y ({tostring(vecDir)})`)

		insp.Destroy()
		testGui:Destroy()
		env.Teardown()
	end)

	-- 45) Guide cleanup on deselect / non-booster / Editing exit
	runTest("Fase 3.4 [45]: Selecting non-booster, deselecting, or launching cleans up 3D BoosterThrustGuide completely", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34049, Name = "GuideCleanup" }
		local plot = PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p45")
		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)

		BuildState.SetExpectedOwner(p1.UserId)
		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		BuildState.ApplyAuthoritativeBlueprint(bp)
		BuildState.SetActive(true)
		BuildState.SetRuntimeStatus({
			State = "Editing",
			RuntimeId = nil,
			PlotId = plot.PlotId,
			SourceBlueprintId = bp.BlueprintId,
			SourceBlueprintRevision = bp.Revision,
			DriverSeated = false,
			PieceCount = #bp.Pieces,
			JointCount = 0,
		})

		local testGui = Instance.new("ScreenGui")
		local insp = BoosterInspectorPanel.Mount(testGui)

		BuildState.SetSelectedPlacedPiece(v.BoosterIds[1])
		insp.Refresh()
		assertTrue(insp.GetActiveGuideModel() ~= nil, "Guide created when booster selected")

		-- Cambiar a Seat (no booster)
		BuildState.SetSelectedPlacedPiece(v.SeatId)
		insp.Refresh()
		assertEqual(insp.Frame.Visible, false, "Inspector hides on non-booster")
		assertEqual(insp.GetActiveGuideModel(), nil, "Guide destroyed when switching to non-booster")

		-- Volver a seleccionar y luego pasar a Driving
		BuildState.SetSelectedPlacedPiece(v.BoosterIds[1])
		insp.Refresh()
		assertTrue(insp.GetActiveGuideModel() ~= nil, "Guide re-created")
		BuildState.SetActive(false)
		BuildState.SetRuntimeStatus({
			State = "Driving",
			RuntimeId = "rt_fake",
			PlotId = plot.PlotId,
			SourceBlueprintId = bp.BlueprintId,
			SourceBlueprintRevision = bp.Revision,
			DriverSeated = true,
			PieceCount = #bp.Pieces,
			JointCount = 0,
		})
		insp.Refresh()
		assertEqual(insp.Frame.Visible, false, "Inspector closes on launch")
		assertEqual(insp.GetActiveGuideModel(), nil, "Guide destroyed cleanly on launch transition")

		insp.Destroy()
		testGui:Destroy()
		env.Teardown()
	end)

	-- 46) Regresión API server-only en controladores cliente + propiedades/ciclo completo de BoosterThrustGuide
	runTest("Fase 3.4 [46]: Client visual guide & inspectors contain zero server-only APIs and enforce BoosterThrustGuide lifecycle", function()
		local forbiddenServerOnlyApis = {
			"CollisionGroupSetCollidable",
			"RegisterCollisionGroup",
			"UnregisterCollisionGroup",
			"RenameCollisionGroup",
			"SetNetworkOwner",
			"SetNetworkOwnershipAuto",
			"GetNetworkOwner",
		}
		local clientControllersToAudit = {
			"BoosterInspectorPanel",
			"BuildPlacementController",
			"BuildPreviewController",
			"BuildTransformController",
			"EngineInspectorPanel",
			"WheelConfigController",
			"VehicleManagement",
		}
		for _, scriptName in ipairs(clientControllersToAudit) do
			local mod = ClientControllers:FindFirstChild(scriptName) :: LuaSourceContainer?
			assertTrue(mod ~= nil, `Client controller '{scriptName}' exists for API audit`)
			local rawSource = (mod :: any).Source :: string
			local codeOnly = string.gsub(string.gsub(rawSource, "%-%-%[=*%[.-%]=*%]", ""), "%-%-[^\n]*", "")
			for _, apiName in ipairs(forbiddenServerOnlyApis) do
				assertEqual(
					string.find(codeOnly, apiName, 1, true),
					nil,
					`Client script '{scriptName}' must not invoke server-only API '{apiName}'`
				)
			end
		end

		local inspectorMod = ClientControllers:WaitForChild("BoosterInspectorPanel") :: ModuleScript
		local inspectorCode = string.gsub(string.gsub(inspectorMod.Source, "%-%-%[=*%[.-%]=*%]", ""), "%-%-[^\n]*", "")
		assertTrue(
			string.find(inspectorCode, "IsCollisionGroupRegistered", 1, true) ~= nil,
			"BoosterInspectorPanel validates CollisionGroup registration before assigning"
		)
		local applyFnStart = string.find(inspectorCode, "local function applyNonPhysicalGuideProps", 1, true)
		local applyFnEnd = if applyFnStart then string.find(inspectorCode, "\nend", applyFnStart, true) else nil
		assertTrue(applyFnStart ~= nil and applyFnEnd ~= nil, "Found applyNonPhysicalGuideProps definition")
		local applyBody = string.sub(inspectorCode, applyFnStart :: number, applyFnEnd :: number)
		assertEqual(
			string.find(applyBody, "pcall", 1, true),
			nil,
			"applyNonPhysicalGuideProps must not use pcall to hide invalid API calls"
		)

		local function countGuidesInWorkspace(): number
			local count = 0
			for _, desc in ipairs(Workspace:GetDescendants()) do
				if desc:IsA("Model") and desc.Name == "BoosterThrustGuide" then
					count += 1
				end
			end
			return count
		end

		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 34050, Name = "GuideRegression" }
		local plot = PlotService.Assign(p1)
		local v = buildBoosterVehicle(p1, "p46", {
			AddRearCrossbar = true,
			Boosters = { { Offset = CFrame.new(-2, 4.5, 2) } },
		})
		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)

		BuildState.SetExpectedOwner(p1.UserId)
		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		BuildState.ApplyAuthoritativeBlueprint(bp)
		BuildState.SetActive(true)
		BuildState.SetRuntimeStatus({
			State = "Editing",
			RuntimeId = nil,
			PlotId = plot.PlotId,
			SourceBlueprintId = bp.BlueprintId,
			SourceBlueprintRevision = bp.Revision,
			DriverSeated = false,
			PieceCount = #bp.Pieces,
			JointCount = 0,
		})

		local testGui = Instance.new("ScreenGui")
		local insp = BoosterInspectorPanel.Mount(testGui)
		assertEqual(countGuidesInWorkspace(), 0, "No guide before selection")

		-- Seleccionar repetidamente: 1 guía única, no física, CollisionGroup EditorGhost
		BuildState.SetSelectedPlacedPiece(v.BoosterIds[1])
		insp.Refresh()
		insp.Refresh()
		insp.Refresh()
		assertEqual(countGuidesInWorkspace(), 1, "Repeated Refresh produces exactly 1 BoosterThrustGuide")

		local guide = insp.GetActiveGuideModel()
		assertTrue(guide ~= nil, "Active BoosterThrustGuide exists")
		local ghostGroup = GameConfig.Runtime.CollisionGroups.EditorGhost
		for _, part in ipairs((guide :: Model):GetDescendants()) do
			if part:IsA("BasePart") then
				assertEqual(part.Anchored, true, "Guide BasePart Anchored=true")
				assertEqual(part.CanCollide, false, "Guide BasePart CanCollide=false")
				assertEqual(part.CanTouch, false, "Guide BasePart CanTouch=false")
				assertEqual(part.CanQuery, false, "Guide BasePart CanQuery=false")
				assertEqual(part.Massless, true, "Guide BasePart Massless=true")
				assertEqual(part.CastShadow, false, "Guide BasePart CastShadow=false")
				assertEqual(part.CollisionGroup, ghostGroup, "Guide BasePart uses EditorGhost CollisionGroup")
			end
		end

		-- Rotar booster en el lugar (Y rotation) y validar actualización de guía sin duplicación
		local rotYCF = CFrame.new(-2, 4.5, 2) * BuildRotation.RotateY(BuildRotation.Identity(), 1)
		local tfRes = BuildService.ProcessRequest(p1, {
			Action = "TransformPiece",
			ClientOpId = "p46_rot_y",
			PieceInstanceId = v.BoosterIds[1],
			LocalCFrame = rotYCF,
		})
		assertTrue(tfRes.Success, "TransformPiece rotating booster succeeds")
		BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		insp.RefreshGuidePose()
		assertEqual(countGuidesInWorkspace(), 1, "Rotating booster keeps exactly 1 BoosterThrustGuide")
		local updatedGuide = insp.GetActiveGuideModel()
		assertTrue(updatedGuide ~= nil, "Guide stays alive after rotation")
		local updatedLabel = (updatedGuide :: Model):GetAttribute("DirectionLabel") :: string
		assertTrue(updatedLabel ~= "Adelante (-Z)", `Rotated guide direction updated from forward (got '{updatedLabel}')`)

		-- Eliminar booster y validar limpieza total
		local rmRes = BuildService.ProcessRequest(p1, {
			Action = "RemovePiece",
			ClientOpId = "p46_rm_booster",
			PieceInstanceId = v.BoosterIds[1],
		})
		assertTrue(rmRes.Success, "Removing booster succeeds")
		BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1))
		insp.Refresh()
		assertEqual(insp.Frame.Visible, false, "Inspector hides when selected booster is deleted")
		assertEqual(insp.GetActiveGuideModel(), nil, "GetActiveGuideModel becomes nil after booster removal")
		assertEqual(countGuidesInWorkspace(), 0, "Zero BoosterThrustGuide instances remain after deletion")

		insp.Destroy()
		testGui:Destroy()
		env.Teardown()
	end)
end

return Phase34Tests
