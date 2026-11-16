--!strict
--[=[
	Phase421Tests
	Suite de pruebas automatizadas de Fase 4.2.1 (Hotfix crítico del taller,
	separación estricta WorkshopDraft / SavedBlueprint (Slots 1-3) / VehicleRuntime,
	persisitencia v2 con migración no destructiva de hasta 10 blueprints heredados,
	vaciar taller, sobrecarga/errores de red y regresión de Fase 4.2):
	- Cubre los 27 casos obligatorios de Fase 4.2.1 Etapa 7.
	- Limpieza explícita por referencia exacta (nunca por coincidencias parciales "Temp").
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local BuildGrid = require(ReplicatedStorage.Shared.Building.BuildGrid)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BuildPayloadValidator = require(ServerScriptService.Server.Security.BuildPayloadValidator)
local PlotService = require(ServerScriptService.Server.Services.PlotService)
local SpawnService = require(ServerScriptService.Server.Services.SpawnService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local BoosterInventoryService = require(ServerScriptService.Server.Services.BoosterInventoryService)
local WheelAutoConfigurationService = require(ServerScriptService.Server.Services.WheelAutoConfigurationService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local BlueprintPersistenceService = require(ServerScriptService.Server.Services.BlueprintPersistenceService)
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

local ClientControllers = game:GetService("StarterPlayer")
	:WaitForChild("StarterPlayerScripts")
	:WaitForChild("Client")
	:WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState") :: ModuleScript)
local BuildPreviewController = require(ClientControllers:WaitForChild("BuildPreviewController") :: ModuleScript)
local BlueprintManagerController = require(ClientControllers:WaitForChild("BlueprintManagerController") :: ModuleScript)

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase421Tests = {}

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

local function countDynamicParts(plot: PlotService.PlotRecord): number
	local editable = plot.DynamicContainer:FindFirstChild(GameConfig.Building.EditableVehicleName)
	if not editable then
		return 0
	end
	local count = 0
	for _, desc in ipairs(editable:GetDescendants()) do
		if desc:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

local function resetAllServices(preservePersistence: boolean?)
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
	InventoryService._ResetForTests(preservePersistence, { AutoGrantLegacySuiteQuota = true })
	if not preservePersistence then
		BlueprintPersistenceService._ResetForTests(true)
		BoosterInventoryService.ResetAllForTests()
		EngineInventoryService.ResetAllForTests()
	else
		BlueprintPersistenceService._SetSimulateWriteFailureForTests(false)
		BlueprintPersistenceService._SetSimulateLoadFailureForTests(false)
	end
	ConnectionService._ResetForTests()
	WheelAutoConfigurationService._ResetForTests()
	SpawnService._ResetForTests()
	PlotService._ResetForTests()
	BuildState.Reset()
	BuildPreviewController._ClearGeometryCacheForTests()
	BuildPreviewController.InvalidateWorkshopCaches()
	BuildPreviewController.DestroyGhost()
end

local function initAllServices(tempPlots: Folder, plotCount: number?, customSpawns: Folder?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = customSpawns or (Workspace:WaitForChild("PlotSpawns") :: Folder)
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
	local prevPlots = Workspace:FindFirstChild("_Phase421TestPlots")
	if prevPlots then
		prevPlots:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase421TestPlots"
	tempPlots.Parent = Workspace

	resetAllServices(false)
	initAllServices(tempPlots, plotCount)

	local virtualClock = 20000
	local rateClock = 20000
	local spawnedRefs: { Instance } = { tempPlots }

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
		TrackTemp = function(inst: Instance)
			table.insert(spawnedRefs, inst)
		end,
		AdvanceClock = function(dt: number): number
			virtualClock += dt
			return virtualClock
		end,
		SimulateRejoin = function(newPlotCount: number?)
			resetAllServices(true)
			for _, child in ipairs(tempPlots:GetChildren()) do
				child:Destroy()
			end
			initAllServices(tempPlots, newPlotCount or plotCount)
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
		end,
		Teardown = function()
			resetAllServices(false)
			InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = false })
			for _, inst in ipairs(spawnedRefs) do
				if inst.Parent then
					inst:Destroy()
				end
			end
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

local function buildStarterVehicle(player: PlotService.PlayerLike, prefix: string, includeModules: boolean?)
	local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)
	local b1 = placePieceReq(player, `{prefix}_b1`, "WoodBlock", CFrame.new(0, 2.5, -2))
	local b2 = placePieceReq(player, `{prefix}_b2`, "WoodBlock", CFrame.new(0, 2.5, 0))
	local b3 = placePieceReq(player, `{prefix}_b3`, "WoodBlock", CFrame.new(0, 2.5, 2))
	local b4 = placePieceReq(player, `{prefix}_b4`, "WoodBlock", CFrame.new(0, 2.5, 4))
	local seat = placePieceReq(player, `{prefix}_seat`, "DriverSeat", CFrame.new(0, 4.0, -2))
	placePieceReq(player, `{prefix}_wfl`, "SmallWheel", CFrame.new(-1.5, 2.5, -2))
	placePieceReq(player, `{prefix}_wfr`, "SmallWheel", CFrame.new(1.5, 2.5, -2) * wheelFlip)
	placePieceReq(player, `{prefix}_wrl`, "SmallWheel", CFrame.new(-1.5, 2.5, 4))
	placePieceReq(player, `{prefix}_wrr`, "SmallWheel", CFrame.new(1.5, 2.5, 4) * wheelFlip)

	local engId: string? = nil
	local fuelId: string? = nil
	local bstId: string? = nil
	if includeModules ~= false then
		engId = placePieceReq(player, `{prefix}_eng`, "SmallEngine", CFrame.new(0, 4.5, 0))
		fuelId = placePieceReq(player, `{prefix}_fuel`, "RegularFuelTank", CFrame.new(0, 4.5, 4))
		bstId = placePieceReq(player, `{prefix}_bst`, "SmallBooster", CFrame.new(0, 2.5, 6.5))
	end
	return {
		B1 = b1,
		B2 = b2,
		B3 = b3,
		B4 = b4,
		Seat = seat,
		Engine = engId,
		Fuel = fuelId,
		Booster = bstId,
	}
end

local function makeClientBridge(player: PlotService.PlayerLike): BlueprintManagerController.InvokeHandler
	return function(req: any): BuildProtocol.BuildOperationResponse
		return BuildService.ProcessRequest(player, req)
	end
end

local function buildSyntheticLegacyBlueprint(userId: number, idx: number, updatedAt: number): { [string]: any }
	return {
		BlueprintId = `legacy_bp_{idx}`,
		OwnerUserId = userId,
		Name = `LegacyDesign_{idx}`,
		CreatedAt = updatedAt - 100,
		UpdatedAt = updatedAt,
		Revision = idx,
		Pieces = {
			{
				InstanceId = `p_{idx}_1`,
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 2.5, 0),
			},
			{
				InstanceId = `p_{idx}_2`,
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 4.0, 0),
			},
		},
	}
end

function Phase421Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (name: string, fn: () -> ()) -> ()
)
	local _ = results

	-- 01) Taller inicial vacío y exactamente 3 tarjetas vacías
	runTest("Fase 4.2.1 [01]: Initial workshop starts with 0 pieces, LoadedSlotIndex=nil and 3 Empty slots", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42101, Name = "P421_01" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local res = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.ListBlueprintSlots,
			ClientOpId = "421_01_list",
		})
		assertTrue(res.Success, "ListBlueprintSlots succeeds")
		assertEqual(#(res.Slots or {}), 3, "Exactly 3 blueprint slots returned")
		assertEqual(res.LoadedSlotIndex, nil, "LoadedSlotIndex starts nil")
		assertEqual(res.WorkshopPieceCount, 0, "WorkshopPieceCount starts at 0")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 0, "Service draft has 0 pieces")
		assertEqual(countDynamicParts(plot), 0, "3D workshop has 0 parts")
		for i = 1, 3 do
			local slot = (res.Slots :: { VehicleTypes.BlueprintSlotSummary })[i]
			assertEqual(slot.SlotIndex, i, `Slot {i} index matches`)
			assertEqual(slot.State, "Empty", `Slot {i} state Empty`)
			assertEqual(slot.IsOccupied, false, `Slot {i} IsOccupied=false`)
		end
		env.Teardown()
	end)

	-- 02) Construcción en taller altera solo WorkshopDraft sin alterar tarjetas guardadas
	runTest("Fase 4.2.1 [02]: Building vehicle updates WorkshopDraft only and leaves all 3 slots empty", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42102, Name = "P421_02" }
		PlotService.Assign(p1)

		buildStarterVehicle(p1, "t02", true)
		local draftCount = VehicleBlueprintService.GetPieceCount(p1)
		assertTrue(draftCount >= 12, `Built starter vehicle has >=12 pieces (got {draftCount})`)

		local slots = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)
		assertEqual(#slots, 3, "3 slots present")
		for _, slot in ipairs(slots) do
			assertEqual(slot.IsOccupied, false, "Saved slot stays Empty during draft edits")
			assertEqual(slot.PieceCount, 0, "Saved slot piece count remains 0")
		end
		env.Teardown()
	end)

	-- 03) Guardar en tarjeta vacía crea copia independiente (editar draft después no muta el slot)
	runTest("Fase 4.2.1 [03]: SaveBlueprintSlot copies draft to empty slot independently; empty draft save rejected", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42103, Name = "P421_03" }
		PlotService.Assign(p1)

		-- Empty draft cannot save
		local emptySave = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_03_empty",
			SlotIndex = 1,
			Name = "Vacio",
		})
		assertEqual(emptySave.Success, false, "Saving empty draft is rejected")
		assertEqual(emptySave.ErrorCode, BuildProtocol.ErrorCodes.EmptyWorkshopDraft, "Returns EmptyWorkshopDraft")

		-- Build & save to slot 1
		buildStarterVehicle(p1, "t03", true)
		local originalCount = VehicleBlueprintService.GetPieceCount(p1)

		local saveRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_03_save1",
			SlotIndex = 1,
			Name = "Buggy Alfa",
		})
		assertTrue(saveRes.Success, `SaveBlueprintSlot 1 succeeded: {tostring(saveRes.ErrorMessage)}`)
		local slots = saveRes.Slots :: { VehicleTypes.BlueprintSlotSummary }
		assertEqual(slots[1].IsOccupied, true, "Slot 1 is now occupied")
		assertEqual(slots[1].State, "Saved", "Slot 1 state is Saved")
		assertEqual(slots[1].Name, "Buggy Alfa", "Slot 1 saved name matches")
		assertEqual(slots[1].PieceCount, originalCount, "Slot 1 saved piece count matches")

		-- Edit draft by adding extra block -> Slot 1 MUST remain originalCount
		placePieceReq(p1, "t03_extra", "WoodBlock", CFrame.new(0, 2.5, -4))
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), originalCount + 1, "Workshop draft incremented")
		local refreshedSlots = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)
		assertEqual(refreshedSlots[1].PieceCount, originalCount, "Saved Slot 1 remains completely unaffected by draft edits")
		assertEqual(VehicleBlueprintService.HasUnsavedChanges(p1), true, "Workshop marks unsaved changes after draft edit")
		env.Teardown()
	end)

	-- 04) Cargar tarjeta guardada: directo en taller vacío, advertencia con borrador activo
	runTest("Fase 4.2.1 [04]: LoadBlueprintSlot loads directly to empty workshop and requires confirm when draft non-empty", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42104, Name = "P421_04" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		buildStarterVehicle(p1, "t04", false)
		local countA = VehicleBlueprintService.GetPieceCount(p1)
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_04_save",
			SlotIndex = 1,
			Name = "Chasis Ligero",
		})

		-- Empty workshop then load directly
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.ClearWorkshop,
			ClientOpId = "421_04_clr",
		})
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 0, "Workshop cleared to 0")

		local directLoad = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = "421_04_load_direct",
			SlotIndex = 1,
			ConfirmDiscardUnsaved = false,
		})
		assertTrue(directLoad.Success, "Direct load onto empty workshop succeeds")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), countA, "Workshop restored saved pieces")
		assertEqual(directLoad.LoadedSlotIndex, 1, "LoadedSlotIndex == 1")

		-- Modify workshop draft -> unconfirmed load rejected preserving draft
		placePieceReq(p1, "t04_mod", "WoodBlock", CFrame.new(0, 2.5, -4))
		local blockedLoad = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = "421_04_load_blocked",
			SlotIndex = 1,
			ConfirmDiscardUnsaved = false,
		})
		assertEqual(blockedLoad.Success, false, "Unconfirmed load over dirty draft rejected")
		assertEqual(
			blockedLoad.ErrorCode,
			BuildProtocol.ErrorCodes.UnsavedWorkshopConfirmationRequired,
			"UnsavedWorkshopConfirmationRequired returned"
		)
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), countA + 1, "Draft preserved intact on unconfirmed load")

		-- Confirmed load replaces workshop cleanly
		local confirmedLoad = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = "421_04_load_ok",
			SlotIndex = 1,
			ConfirmDiscardUnsaved = true,
		})
		assertTrue(confirmedLoad.Success, "Confirmed load succeeds")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), countA, "Draft replaced with Slot 1 copy")
		assertEqual(countDynamicParts(plot) > 0, true, "3D workshop parts rebuilt")
		env.Teardown()
	end)

	-- 05) Sobrescribir tarjeta ocupada con doble confirmación obligatoria
	runTest("Fase 4.2.1 [05]: OverwriteBlueprintSlot strictly requires ConfirmationStep=2 on client & server", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42105, Name = "P421_05" }
		PlotService.Assign(p1)
		local bridge = makeClientBridge(p1)

		buildStarterVehicle(p1, "t05", false)
		local initialCount = VehicleBlueprintService.GetPieceCount(p1)
		BlueprintManagerController.SaveBlueprintSlot(1, "Original", bridge)

		placePieceReq(p1, "t05_add", "WoodBlock", CFrame.new(0, 2.5, -4))
		local updatedCount = VehicleBlueprintService.GetPieceCount(p1)

		-- Step 1 only -> rejected on client AND rejected directly by server validator
		local clientStep1Ok, clientStep1Resp = BlueprintManagerController.OverwriteBlueprintSlot(1, "Nuevo", 1, bridge)
		assertEqual(clientStep1Ok, false, "Client blocks step 1 overwrite")
		assertEqual(
			(clientStep1Resp :: BuildProtocol.BuildOperationResponse).ErrorCode,
			BuildProtocol.ErrorCodes.ConfirmationRequired,
			"Client returns ConfirmationRequired"
		)

		local serverStep1 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.OverwriteBlueprintSlot,
			ClientOpId = "421_05_srv1",
			SlotIndex = 1,
			Name = "Nuevo",
			ConfirmationStep = 1,
		})
		assertEqual(serverStep1.Success, false, "Server rejects step 1 overwrite")
		assertEqual(serverStep1.ErrorCode, BuildProtocol.ErrorCodes.ConfirmationRequired, "Validator rejects ConfirmationStep != 2")
		assertEqual(VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1].PieceCount, initialCount, "Slot 1 untouched after step 1 rejections")

		-- Step 2 -> succeeds
		local clientStep2Ok = BlueprintManagerController.OverwriteBlueprintSlot(1, "Version2", 2, bridge)
		assertTrue(clientStep2Ok, "Client + Server Step 2 overwrite succeeds")
		local slots = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)
		assertEqual(slots[1].Name, "Version2", "Slot 1 name updated")
		assertEqual(slots[1].PieceCount, updatedCount, "Slot 1 overwritten with updated count")
		env.Teardown()
	end)

	-- 06) Cancelar sobrescritura en paso 1 y paso 2 sin escrituras
	runTest("Fase 4.2.1 [06]: Cancelling overwrite at step 1 or step 2 performs zero writes", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42106, Name = "P421_06" }
		PlotService.Assign(p1)
		local bridge = makeClientBridge(p1)

		buildStarterVehicle(p1, "t06", false)
		BlueprintManagerController.SaveBlueprintSlot(2, "Estable", bridge)
		local revBefore = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[2].Revision

		placePieceReq(p1, "t06_add", "WoodBlock", CFrame.new(0, 2.5, -4))
		-- Abort step 0 / step 1 attempts (no Step 2 sent)
		local ok0 = BlueprintManagerController.OverwriteBlueprintSlot(2, "Abortado", 0, bridge)
		local ok1 = BlueprintManagerController.OverwriteBlueprintSlot(2, "Abortado", 1, bridge)
		assertEqual(ok0, false, "Step 0 aborted")
		assertEqual(ok1, false, "Step 1 aborted")

		local summaryAfter = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[2]
		assertEqual(summaryAfter.Revision, revBefore, "Zero slot writes when overwrite cancelled")
		assertEqual(summaryAfter.Name, "Estable", "Slot name preserved")
		env.Teardown()
	end)

	-- 07) Renombrar tarjeta con validación de longitud, caracteres y filtrado sin alterar estructura
	runTest("Fase 4.2.1 [07]: RenameBlueprintSlot validates length, chars and text filter while preserving geometry", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42107, Name = "P421_07" }
		PlotService.Assign(p1)

		buildStarterVehicle(p1, "t07", false)
		local pieceCount = VehicleBlueprintService.GetPieceCount(p1)
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_07_save",
			SlotIndex = 1,
			Name = "Base",
		})

		-- Empty / >32 / invalid control chars rejected
		local emptyRen = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.RenameBlueprintSlot,
			ClientOpId = "421_07_r_empty",
			SlotIndex = 1,
			Name = "   ",
		})
		assertEqual(emptyRen.Success, false, "Blank name rejected")

		local longName = string.rep("A", 33)
		local longRen = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.RenameBlueprintSlot,
			ClientOpId = "421_07_r_long",
			SlotIndex = 1,
			Name = longName,
		})
		assertEqual(longRen.Success, false, ">32 char name rejected")

		local badCharRen = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.RenameBlueprintSlot,
			ClientOpId = "421_07_r_char",
			SlotIndex = 1,
			Name = "Mal<Script>",
		})
		assertEqual(badCharRen.Success, false, "Disallowed characters rejected")

		-- Text filter check (simulates TextService:FilterStringAsync censoring)
		VehicleBlueprintService._SetTextFilterForTests(function(rawText, _userId)
			return string.gsub(rawText, "Malo", "####")
		end)
		local okRen = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.RenameBlueprintSlot,
			ClientOpId = "421_07_r_ok",
			SlotIndex = 1,
			Name = "Auto Malo",
		})
		assertTrue(okRen.Success, `Valid rename succeeded: {tostring(okRen.ErrorMessage)}`)
		local slot1 = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1]
		assertEqual(slot1.Name, "Auto ####", "Filtered name applied")
		assertEqual(slot1.PieceCount, pieceCount, "PieceCount preserved untouched after rename")
		local bpSaved = VehicleBlueprintService.GetSavedBlueprintSnapshot(p1, slot1.BlueprintId :: string)
		assertTrue(bpSaved ~= nil and #bpSaved.Pieces == pieceCount, "Saved blueprint structure intact")
		env.Teardown()
	end)

	-- 08) Eliminar tarjeta guardada sin tocar el diseño actual en el taller
	runTest("Fase 4.2.1 [08]: DeleteBlueprintSlot removes only target card and leaves active workshop intact", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42108, Name = "P421_08" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		buildStarterVehicle(p1, "t08", false)
		local count = VehicleBlueprintService.GetPieceCount(p1)
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_08_save",
			SlotIndex = 1,
			Name = "ParaBorrar",
		})
		-- Clear and reload slot 1 so LoadedSlotIndex == 1, then delete slot 1!
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.ClearWorkshop, ClientOpId = "421_08_clr" })
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.LoadBlueprintSlot, ClientOpId = "421_08_load", SlotIndex = 1 })
		assertEqual(VehicleBlueprintService.GetLoadedSlotIndex(p1), 1, "LoadedSlotIndex == 1 before delete")

		local delRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.DeleteBlueprintSlot,
			ClientOpId = "421_08_del",
			SlotIndex = 1,
			ConfirmationName = "ParaBorrar",
		})
		assertTrue(delRes.Success, "DeleteBlueprintSlot succeeded")
		assertEqual(VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1].IsOccupied, false, "Slot 1 is now Empty")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), count, "Active workshop draft pieces preserved untouched")
		assertEqual(countDynamicParts(plot) > 0, true, "3D editable vehicle stays intact in workshop")
		assertEqual(VehicleBlueprintService.GetLoadedSlotIndex(p1), nil, "LoadedSlotIndex cleared cleanly")
		env.Teardown()
	end)

	-- 09) Cancelar / fallar confirmación de eliminación sin cambios
	runTest("Fase 4.2.1 [09]: Wrong ConfirmationName rejects DeleteBlueprintSlot leaving card intact", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42109, Name = "P421_09" }
		PlotService.Assign(p1)

		buildStarterVehicle(p1, "t09", false)
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_09_save",
			SlotIndex = 1,
			Name = "Protegido",
		})

		local badDel = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.DeleteBlueprintSlot,
			ClientOpId = "421_09_del_bad",
			SlotIndex = 1,
			ConfirmationName = "OtroNombre",
		})
		assertEqual(badDel.Success, false, "Mismatched ConfirmationName rejected")
		assertEqual(badDel.ErrorCode, BuildProtocol.ErrorCodes.ConfirmationRequired, "ConfirmationRequired returned")
		assertEqual(VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1].IsOccupied, true, "Slot 1 stays occupied")
		env.Teardown()
	end)

	-- 10) "Vaciar taller" limpia 3D/estado/conexiones/guías sin tocar inventario ni slots
	runTest("Fase 4.2.1 [10]: ClearWorkshop wipes draft, 3D parts and connections while keeping slots & inventory", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42110, Name = "P421_10" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local engUnitsBefore = EngineInventoryService.EnsureControlledWorkshopUnits(p1)
		local bstUnitsBefore = BoosterInventoryService.EnsureControlledWorkshopUnits(p1)
		local engCountBefore = #engUnitsBefore
		local bstCountBefore = #bstUnitsBefore
		buildStarterVehicle(p1, "t10", true)
		local countBefore = VehicleBlueprintService.GetPieceCount(p1)
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_10_s1",
			SlotIndex = 1,
			Name = "SlotIntacto",
		})

		local clearRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.ClearWorkshop,
			ClientOpId = "421_10_clear",
		})
		assertTrue(clearRes.Success, `ClearWorkshop succeeded: {tostring(clearRes.ErrorMessage)}`)
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 0, "Draft pieces == 0")
		assertEqual(countDynamicParts(plot), 0, "3D workshop parts == 0")
		assertEqual(clearRes.WorkshopPieceCount, 0, "Response reports WorkshopPieceCount=0")
		assertEqual(VehicleBlueprintService.GetLoadedSlotIndex(p1), nil, "LoadedSlotIndex cleared")
		assertEqual(#EngineInventoryService.GetPlayerUnits(p1), engCountBefore, "Engine inventory preserved")
		assertEqual(#BoosterInventoryService.GetPlayerUnits(p1), bstCountBefore, "Booster inventory preserved")
		assertEqual(VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1].PieceCount, countBefore, "Saved Slot 1 untouched")
		local bpEmpty = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local inspection = ConnectionService.InspectBlueprintConnections(bpEmpty)
		assertEqual(inspection.TotalPieces, 0, "ConnectionService inspection sees 0 pieces")
		assertEqual(inspection.TotalConnections, 0, "ConnectionService sees 0 structural edges")
		env.Teardown()
	end)

	-- 11) "Vaciar taller" -> "Guardar vehículo actual" -> solo limpia tras ack exitoso
	runTest("Fase 4.2.1 [11]: SaveAndClearWorkshop aborts clear if save fails and clears only after save ack", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42111, Name = "P421_11" }
		PlotService.Assign(p1)
		local bridge = makeClientBridge(p1)

		buildStarterVehicle(p1, "t11", false)
		local draftCount = VehicleBlueprintService.GetPieceCount(p1)

		-- Simulated save failure must ABORT clear!
		BlueprintPersistenceService._SetSimulateWriteFailureForTests(true)
		local failOk, failResp = BlueprintManagerController.SaveAndClearWorkshop(2, "Save", "Fallido", nil, bridge)
		BlueprintPersistenceService._SetSimulateWriteFailureForTests(false)
		assertEqual(failOk, false, "SaveAndClearWorkshop returns false when save fails")
		assertTrue(failResp ~= nil, "Error response propagated")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), draftCount, "Workshop draft preserved when save failed!")
		assertEqual(VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[2].IsOccupied, false, "Slot 2 rolled back cleanly")

		-- Now succeed -> Slot 2 saved AND workshop cleared
		local okSaveClear = BlueprintManagerController.SaveAndClearWorkshop(2, "Save", "Exitoso", nil, bridge)
		assertTrue(okSaveClear, "SaveAndClearWorkshop succeeds once persistence recovers")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 0, "Workshop cleared to 0 after save ack")
		local slots = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)
		assertEqual(slots[2].IsOccupied, true, "Slot 2 persisted")
		assertEqual(slots[2].Name, "Exitoso", "Slot 2 name accurate")
		assertEqual(slots[2].PieceCount, draftCount, "Slot 2 has saved vehicle piece count")
		env.Teardown()
	end)

	-- 12) "Vaciar taller" -> "Cancelar" sin modificaciones
	runTest("Fase 4.2.1 [12]: Aborting SaveAndClear before confirmation keeps workshop and slots untouched", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42112, Name = "P421_12" }
		PlotService.Assign(p1)
		local bridge = makeClientBridge(p1)

		buildStarterVehicle(p1, "t12", false)
		local count = VehicleBlueprintService.GetPieceCount(p1)
		BlueprintManagerController.SaveBlueprintSlot(1, "SlotExistente", bridge)
		placePieceReq(p1, "t12_plus", "WoodBlock", CFrame.new(0, 2.5, -4))

		-- Attempting overwrite-and-clear with confirmationStep != 2 simulates cancel before final step
		local abortOk = BlueprintManagerController.SaveAndClearWorkshop(1, "Overwrite", "Cancelado", 1, bridge)
		assertEqual(abortOk, false, "SaveAndClear with step 1 aborts before saving or clearing")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), count + 1, "Workshop draft untouched")
		assertEqual(VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1].PieceCount, count, "Slot 1 untouched")
		env.Teardown()
	end)

	-- 13) Fallo de persistencia / red simulado -> sin falsos positivos ni pérdida de borrador
	runTest("Fase 4.2.1 [13]: Simulated persistence failure returns PersistenceFailed honestly and rolls back memory", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42113, Name = "P421_13" }
		PlotService.Assign(p1)

		buildStarterVehicle(p1, "t13", false)
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_13_ok",
			SlotIndex = 1,
			Name = "Inicial",
		})
		local rev1 = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1].Revision

		BlueprintPersistenceService._SetSimulateWriteFailureForTests(true)
		local failRename = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.RenameBlueprintSlot,
			ClientOpId = "421_13_fail_ren",
			SlotIndex = 1,
			Name = "Roto",
		})
		local failDel = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.DeleteBlueprintSlot,
			ClientOpId = "421_13_fail_del",
			SlotIndex = 1,
			ConfirmationName = "Inicial",
		})
		BlueprintPersistenceService._SetSimulateWriteFailureForTests(false)

		assertEqual(failRename.Success, false, "Failed rename returns false")
		assertEqual(failRename.ErrorCode, BuildProtocol.ErrorCodes.PersistenceFailed, "Rename returns PersistenceFailed")
		assertEqual(failDel.Success, false, "Failed delete returns false")
		assertEqual(failDel.ErrorCode, BuildProtocol.ErrorCodes.PersistenceFailed, "Delete returns PersistenceFailed")
		local slot1 = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1]
		assertEqual(slot1.IsOccupied, true, "Delete rolled back cleanly")
		assertEqual(slot1.Name, "Inicial", "Rename rolled back cleanly")
		assertEqual(slot1.Revision, rev1, "Revision unchanged after rollback")
		env.Teardown()
	end)

	-- 14) Carga inválida con rollback transaccional conservando borrador actual
	runTest("Fase 4.2.1 [14]: Invalid LoadBlueprintSlot (empty/bad slot) rolls back preserving workshop draft", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42114, Name = "P421_14" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		buildStarterVehicle(p1, "t14", false)
		local draftCount = VehicleBlueprintService.GetPieceCount(p1)
		local beforeParts = countDynamicParts(plot)

		local emptyLoad = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = "421_14_e",
			SlotIndex = 3,
			ConfirmDiscardUnsaved = true,
		})
		assertEqual(emptyLoad.Success, false, "Empty slot load fails")
		assertEqual(emptyLoad.ErrorCode, BuildProtocol.ErrorCodes.SlotEmpty, "Returns SlotEmpty")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), draftCount, "Draft piece count intact")
		assertEqual(countDynamicParts(plot), beforeParts, "3D workshop parts untouched")

		local badIdx = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = "421_14_bad",
			SlotIndex = 4,
			ConfirmDiscardUnsaved = true,
		})
		assertEqual(badIdx.Success, false, "Slot 4 load fails")
		assertEqual(badIdx.ErrorCode, BuildProtocol.ErrorCodes.InvalidSlotIndex, "Validator rejects SlotIndex=4")
		env.Teardown()
	end)

	-- 15) Límite máximo de 3 slots ocupados sin permitir crear un 4º
	runTest("Fase 4.2.1 [15]: Occupying all 3 slots blocks 4th slot and blocks Save onto occupied slot without overwrite", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42115, Name = "P421_15" }
		PlotService.Assign(p1)

		buildStarterVehicle(p1, "t15", false)
		for i = 1, 3 do
			local r = BuildService.ProcessRequest(p1, {
				Action = BuildProtocol.Actions.SaveBlueprintSlot,
				ClientOpId = `421_15_s{i}`,
				SlotIndex = i,
				Name = `Slot_{i}`,
			})
			assertTrue(r.Success, `Save slot {i} succeeds`)
		end

		local dupSave = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_15_occ",
			SlotIndex = 2,
			Name = "NoOverwrite",
		})
		assertEqual(dupSave.Success, false, "SaveBlueprintSlot onto occupied slot fails")
		assertEqual(dupSave.ErrorCode, BuildProtocol.ErrorCodes.SlotOccupied, "Returns SlotOccupied")

		local slot4Save = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_15_s4",
			SlotIndex = 4,
			Name = "SlotCuatro",
		})
		assertEqual(slot4Save.Success, false, "Slot 4 rejected")
		env.Teardown()
	end)

	-- 16) Migración no destructiva desde hasta 10 blueprints antiguos hacia las 3 tarjetas
	runTest("Fase 4.2.1 [16]: Non-destructive migration maps 10 legacy blueprints into 3 slots + 7 recoverable LegacyOverflow", function()
		local env = setupIsolatedWorld(2)
		local userId = 42116
		local p1: PlotService.PlayerLike = { UserId = userId, Name = "P421_16" }

		local legacyList = {}
		for i = 1, 10 do
			table.insert(legacyList, buildSyntheticLegacyBlueprint(userId, i, 1000 + i * 10))
		end
		BlueprintPersistenceService._SeedLegacyRawForTests(userId, {
			Version = 1,
			ActiveBlueprintId = "legacy_bp_10",
			SavedBlueprints = legacyList,
		})

		PlotService.Assign(p1)
		local listRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.ListBlueprintSlots,
			ClientOpId = "421_16_list",
		})
		assertTrue(listRes.Success, "Migration & list succeeded")
		local slots = listRes.Slots :: { VehicleTypes.BlueprintSlotSummary }
		assertEqual(#slots, 3, "3 main slots")
		-- Most recent 3 designs (10, 9, 8) promoted cleanly to Slots 1..3
		assertEqual(slots[1].Name, "LegacyDesign_10", "Slot 1 gets most recent legacy design #10")
		assertEqual(slots[2].Name, "LegacyDesign_9", "Slot 2 gets legacy design #9")
		assertEqual(slots[3].Name, "LegacyDesign_8", "Slot 3 gets legacy design #8")
		assertEqual(listRes.LegacyOverflowCount, 7, "Remaining 7 designs preserved in LegacyOverflow!")
		local overflow = listRes.LegacyOverflow :: { VehicleTypes.LegacyOverflowSummary }
		assertEqual(#overflow, 7, "Overflow list exposes all 7 designs")

		-- Recover overflow #7 -> Slot 3 (occupied -> step 2 confirmation)
		local targetLegacy = overflow[1]
		local recRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.RecoverLegacyBlueprint,
			ClientOpId = "421_16_rec",
			OriginalBlueprintId = targetLegacy.OriginalBlueprintId,
			TargetSlotIndex = 3,
			ConfirmationStep = 2,
		})
		assertTrue(recRes.Success, `RecoverLegacyBlueprint succeeded: {tostring(recRes.ErrorMessage)}`)
		assertEqual(recRes.LegacyOverflowCount, 7, "Overflow preserved non-destructively without losing any entries")
		assertEqual((recRes.LegacyOverflow :: { VehicleTypes.LegacyOverflowSummary })[1].RecoveredToSlot, 3, "Recovered legacy entry marked RecoveredToSlot=3")
		assertEqual((recRes.Slots :: { VehicleTypes.BlueprintSlotSummary })[3].Name, targetLegacy.Name, "Recovered design now in Slot 3")
		env.Teardown()
	end)

	-- 17) Límite de 500 piezas por vehículo mantenido en taller, guardado y carga
	runTest("Fase 4.2.1 [17]: Enforces max 500 pieces limit in workshop, slot save and deserialization/load", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42117, Name = "P421_17" }
		PlotService.Assign(p1)

		local blockGeo = ConnectionService.GetItemGeometry("WoodBlock")
		assertTrue(blockGeo ~= nil, "WoodBlock geometry exists")
		local step = (blockGeo :: any).Size
		-- Build 10 x 10 x 5 = 500 pieces inside BuildZone
		local placed = 0
		for y = 0, 4 do
			for z = 0, 9 do
				for x = 0, 9 do
					placed += 1
					local localPos = Vector3.new((x - 4.5) * step.X, (step.Y * 0.5) + y * step.Y, (z - 4.5) * step.Z)
					placePieceReq(p1, `p500_{placed}`, "WoodBlock", CFrame.new(localPos))
				end
			end
		end
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 500, "Placed exactly 500 connected pieces")

		-- 501st piece rejected
		local overRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "p500_501",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(Vector3.new(0, (step.Y * 0.5) + 5 * step.Y, 0)),
		})
		assertEqual(overRes.Success, false, "501st piece rejected")
		assertEqual(overRes.ErrorCode, BuildProtocol.ErrorCodes.MaxPiecesReached, "Returns MaxPiecesReached")

		-- Saving 500-piece vehicle works & reloading works
		local save500 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "p500_save",
			SlotIndex = 1,
			Name = "Gigante500",
		})
		assertTrue(save500.Success, `Saving 500-piece craft succeeded: {tostring(save500.ErrorMessage)}`)

		-- Corrupted 501-piece legacy/serialized import rejected
		local oversizedBp = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local okDeser500, bpCopyRaw = BlueprintSerializer.DeserializeBlueprint(BlueprintSerializer.SerializeBlueprint(oversizedBp), p1.UserId)
		assertTrue(okDeser500 and bpCopyRaw ~= nil, "Serialized 500-piece blueprint decoded cleanly")
		local bpCopy = bpCopyRaw :: VehicleTypes.VehicleBlueprint
		table.insert(bpCopy.Pieces, {
			InstanceId = "extra_501",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 20, 0),
		})
		local importOk, _, importErr = VehicleBlueprintService.ImportSerializedBlueprint(p1, nil, bpCopy)
		assertEqual(importOk, false, "501-piece blueprint import rejected")
		assertEqual(importErr, BuildProtocol.ErrorCodes.MaxPiecesReached, "Returns MaxPiecesReached on 501-piece import")
		env.Teardown()
	end)

	-- 18) Máximo 1 DriverSeat por vehículo al guardar y cargar
	runTest("Fase 4.2.1 [18]: Enforces max 1 DriverSeat in workshop, save validation and load validation", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42118, Name = "P421_18" }
		PlotService.Assign(p1)

		placePieceReq(p1, "t18_b1", "WoodBlock", CFrame.new(0, 2.5, 0))
		placePieceReq(p1, "t18_b2", "WoodBlock", CFrame.new(0, 2.5, 2))
		placePieceReq(p1, "t18_s1", "DriverSeat", CFrame.new(0, 4.0, 0))

		local seat2Res = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "t18_s2",
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(0, 4.0, 2),
		})
		assertEqual(seat2Res.Success, false, "Second DriverSeat blocked in workshop")
		assertEqual(seat2Res.ErrorCode, BuildProtocol.ErrorCodes.TooManyDriverSeats, "Returns TooManyDriverSeats")

		-- Seed legacy payload with 2 DriverSeats -> loading or saving must reject cleanly
		local twoSeatBp = buildSyntheticLegacyBlueprint(p1.UserId, 99, 9999)
		twoSeatBp.Connections = {}
		table.insert(twoSeatBp.Pieces, {
			InstanceId = "seat_2",
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(2, 4.0, 0),
		})
		local serializedTwo = BlueprintSerializer.SerializeBlueprint(twoSeatBp :: any)
		local okDeserTwo, deserTwoRaw = BlueprintSerializer.DeserializeBlueprint(
			HttpService:JSONDecode(HttpService:JSONEncode(serializedTwo)),
			p1.UserId
		)
		assertTrue(okDeserTwo and deserTwoRaw ~= nil, "Synthetic 2-seat payload decoded cleanly")
		local deserTwoSeats = deserTwoRaw :: VehicleTypes.VehicleBlueprint
		local okImp, _, impCode = VehicleBlueprintService.ImportSerializedBlueprint(p1, nil, deserTwoSeats)
		assertEqual(okImp, false, "Blueprint with 2 DriverSeats rejected on import/load validation")
		assertEqual(impCode, BuildProtocol.ErrorCodes.TooManyDriverSeats, "Returns TooManyDriverSeats on blueprint load")
		env.Teardown()
	end)

	-- 19) Sin duplicación de motores/boosters entre inventario, borrador y slots
	runTest("Fase 4.2.1 [19]: Engines and boosters are never duplicated across draft, slots, clear and reload", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42119, Name = "P421_19" }
		PlotService.Assign(p1)

		EngineInventoryService.EnsureControlledWorkshopUnits(p1)
		BoosterInventoryService.EnsureControlledWorkshopUnits(p1)
		local enginesBefore = EngineInventoryService.GetPlayerUnits(p1)
		local boostersBefore = BoosterInventoryService.GetPlayerUnits(p1)
		local engCount0 = #enginesBefore
		local bstCount0 = #boostersBefore
		assertTrue(engCount0 >= 1 and bstCount0 >= 1, "Starter engine and booster unit provisioned")

		local engUnitId = enginesBefore[1].ItemInstanceId
		local bstUnitId = boostersBefore[1].ItemInstanceId

		placePieceReq(p1, "t19_b1", "WoodBlock", CFrame.new(0, 2.5, 0))
		placePieceReq(p1, "t19_b2", "WoodBlock", CFrame.new(0, 2.5, 2))
		placePieceReq(p1, "t19_b3", "WoodBlock", CFrame.new(0, 2.5, 4))
		placePieceReq(p1, "t19_eng", "SmallEngine", CFrame.new(0, 4.5, 0), nil, engUnitId)
		placePieceReq(p1, "t19_bst", "SmallBooster", CFrame.new(0, 2.5, 6.5), nil, bstUnitId)

		-- Same unit cannot be placed twice simultaneously
		local dupEng = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = "t19_dup_eng",
			ItemId = "SmallEngine",
			LocalCFrame = CFrame.new(0, 4.5, 2),
			InventoryInstanceId = engUnitId,
		})
		assertEqual(dupEng.Success, false, "Duplicate engine unit in workshop rejected")

		-- Save to Slot 1 & Slot 2 (same vehicle config saved in 2 slots should NEVER duplicate owned unit records)
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "t19_s1",
			SlotIndex = 1,
			Name = "Copy1",
		})
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "t19_s2",
			SlotIndex = 2,
			Name = "Copy2",
		})
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.ClearWorkshop, ClientOpId = "t19_clr" })

		assertEqual(#EngineInventoryService.GetPlayerUnits(p1), engCount0, "Engine inventory count strictly invariant")
		assertEqual(#BoosterInventoryService.GetPlayerUnits(p1), bstCount0, "Booster inventory count strictly invariant")

		-- Load back Slot 1 -> cleanly rebinds owned unit
		local loadOk = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = "t19_load1",
			SlotIndex = 1,
		})
		assertTrue(loadOk.Success, "Slot 1 reloaded cleanly")
		assertEqual(#EngineInventoryService.GetPlayerUnits(p1), engCount0, "Still zero extra engine units created")
		assertEqual(#BoosterInventoryService.GetPlayerUnits(p1), bstCount0, "Still zero extra booster units created")
		env.Teardown()
	end)

	-- 20) Cero piezas invisibles o referencias huérfanas tras limpiar o cambiar slot
	runTest("Fase 4.2.1 [20]: Zero invisible parts or orphan connection references after clear or slot switch", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42120, Name = "P421_20" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		-- Build 28-piece structure (7x4 connected grid within BuildZone bounds) matching original bug report scale
		placePieceReq(p1, "t20_root", "WoodBlock", CFrame.new(-6, 2.5, 0))
		for i = 1, 27 do
			local gx = ((i % 7) * 2) - 6
			local gz = math.floor(i / 7) * 2
			placePieceReq(p1, `t20_p_{i}`, "WoodBlock", CFrame.new(gx, 2.5, gz))
		end
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 28, "28 pieces placed")

		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.ClearWorkshop,
			ClientOpId = "t20_clr",
		})

		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 0, "Draft 0 pieces")
		assertEqual(countDynamicParts(plot), 0, "DynamicContainer EditableVehicle has 0 BaseParts")
		local editableAfterClear = plot.DynamicContainer:FindFirstChild(GameConfig.Building.EditableVehicleName)
		assertTrue(editableAfterClear == nil or #editableAfterClear:GetChildren() == 0, "Or model removed/empty")
		local bpSnap = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local insp = ConnectionService.InspectBlueprintConnections(bpSnap)
		assertEqual(insp.TotalPieces, 0, "0 piece specs")
		assertEqual(insp.TotalConnections, 0, "0 edge specs")
		env.Teardown()
	end)

	-- 21) Cero guías fantasma de snap/alineación/FaceSnap ni cachés stale tras reemplazo a rev 0
	runTest("Fase 4.2.1 [21]: BuildPreviewController invalidates caches and accepts rev 0 replacement cleanly", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42121, Name = "P421_21" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local buildZone = plot.Zones.BuildZone

		buildStarterVehicle(p1, "t21", false)
		local bpFilled = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		BuildState.SetExpectedOwner(p1.UserId)
		BuildState.SetPlot(plot.Model, buildZone)
		assertTrue(BuildState.ApplyAuthoritativeBlueprint(bpFilled, true), "Client applied filled blueprint")
		assertEqual(#BuildState.BlueprintPieces, 9, "Client HUD counter == 9 pieces")

		BuildState.SelectItem("WoodBlock")
		BuildState.SetActive(true)
		-- Populate BuildPreviewController caches over filled blueprint
		local hitWorld = buildZone.CFrame:PointToWorldSpace(Vector3.new(0, 2.5, 6))
		BuildPreviewController.UpdateAtWorldPoint(hitWorld, Vector3.yAxis, nil)
		local snapBefore = BuildPreviewController._GetCacheSnapshotForTests()
		assertTrue(snapBefore.CachedSpecsCount >= 1 and snapBefore.HasTargetCFrame, "Preview cache populated prior to clear")

		-- Now simulate server clear / replace with rev 0 empty blueprint (previously rejected when rev < previous!)
		local replaceCount = 0
		local unsub = BuildState.SubscribeBlueprintReplaced(function()
			replaceCount += 1
		end)
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.ClearWorkshop, ClientOpId = "t21_clr" })
		local bpCleared = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local revLowerZero = table.clone(bpCleared) :: any
		revLowerZero.Revision = 0 -- Explicitly verify revision < prior rev still applies!

		local accepted = BuildState.ApplyAuthoritativeBlueprint(revLowerZero, true)
		assertTrue(accepted, "ApplyAuthoritativeBlueprint(..., true) accepts rev 0 authoritative replacement!")
		assertEqual(replaceCount >= 1, true, "SubscribeBlueprintReplaced fired synchronously")
		assertEqual(#BuildState.BlueprintPieces, 0, "HUD piece count reset cleanly to 0")

		local snapAfter = BuildPreviewController._GetCacheSnapshotForTests()
		assertEqual(snapAfter.CachedSpecsCount, 0, "BuildPreviewController wiped existing piece specs")
		assertEqual(snapAfter.HasTargetCFrame, false, "Cleared cached target CFrame")
		assertEqual(snapAfter.HasLastRay, false, "Cleared cached ray origin")
		unsub()
		env.Teardown()
	end)

	-- 22) Colocación válida de nueva primera pieza tras vaciar taller (sin BelowFloor falso + arg fix StandController)
	runTest("Fase 4.2.1 [22]: First piece placement after ClearWorkshop succeeds cleanly without BelowFloor false positive", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42122, Name = "P421_22" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local buildZone = plot.Zones.BuildZone

		buildStarterVehicle(p1, "t22", false)
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.SetStandOffset, ClientOpId = "t22_up", HeightOffset = 6, LateralOffset = 2 })
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.ClearWorkshop, ClientOpId = "t22_clr" })

		-- Negative Y placement below floor still caught legitimately as BelowFloor
		local okBelow, reasonBelow = BuildGrid.ValidateBounds(
			buildZone.Size,
			Vector3.new(0, -1, 0),
			Vector3.new(2, 2, 2),
			GameConfig.Building.DefaultZoneHeight,
			{ HeightOffset = 0, LateralOffset = 0 }
		)
		assertEqual(okBelow, false, "ValidateBounds rejects Y=-1")
		assertEqual(reasonBelow, "BelowFloor", "BelowFloor reason preserved on actual underground placement")

		-- Valid first piece on workshop floor after clear + reset lift
		local firstId = placePieceReq(p1, "t22_new1", "WoodBlock", CFrame.new(0, 2.5, 0))
		assertTrue(#firstId > 0, "First piece placed cleanly after ClearWorkshop")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 1, "Workshop piece count accurately == 1")
		assertEqual(countDynamicParts(plot) > 0, true, "New piece physically visible in workshop")
		env.Teardown()
	end)

	-- 23) Ciclo completo de bug repro: construir -> lanzar -> volver -> vaciar -> construir de cero
	runTest("Fase 4.2.1 [23]: Full Stage 1 bug repro loop (Build->Launch->Return->Clear->Place) passes end-to-end", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42123, Name = "P421_23" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		buildStarterVehicle(p1, "t23", true)
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "t23_save",
			SlotIndex = 1,
			Name = "CamionetaTest",
		})
		local savedCount = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1].PieceCount

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch succeeded")
		env.AdvanceClock(2.0)

		local ret = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(ret.Success, "ReturnToWorkshop succeeded")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), savedCount, "Workshop restored original blueprint after return")

		local clr = BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.ClearWorkshop, ClientOpId = "t23_clr" })
		assertTrue(clr.Success, "ClearWorkshop succeeded after returning from launch")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 0, "HUD piece count == 0")
		assertEqual(countDynamicParts(plot), 0, "0 phantom geometry parts")

		local freshId = placePieceReq(p1, "t23_fresh", "WoodBlock", CFrame.new(0, 2.5, 0))
		assertTrue(#freshId > 0, "Fresh first piece placed cleanly after launch + return + clear")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 1, "HUD counter == 1")
		assertEqual(VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1].PieceCount, savedCount, "Slot 1 untouched by entire loop")
		env.Teardown()
	end)

	-- 24) Regresión Fase 4.2: daños, rotura de fragmentos y protección de asiento preservados
	runTest("Fase 4.2.1 [24]: Phase 4.2 damage detachment & seat protection work normally without mutating saved slots", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42124, Name = "P421_24" }
		PlotService.Assign(p1)

		local ids = buildStarterVehicle(p1, "t24", true)
		local extraNose = placePieceReq(p1, "t24_nose", "WoodBlock", CFrame.new(0, 2.5, -4))
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "t24_s1",
			SlotIndex = 1,
			Name = "Blindado",
		})
		local savedCount = VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1].PieceCount

		local lr = VehicleLaunchService.LaunchVehicle(p1, { SkipWorldObstructionCheck = true, MountDriver = false, SimulateSeated = true })
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch succeeded")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		env.AdvanceClock(2.0)

		-- Apply lethal impact to nose piece
		local maxHp = rt.Parts[extraNose].MaxHealth
		VehicleDamageService.ApplyImpact(rt, extraNose, {
			DamageAmount = maxHp + 50,
			Timestamp = env.AdvanceClock(1),
			Reason = "TestCrash",
		})
		assertEqual(rt.Parts[extraNose].IsDetached, true, "0 HP piece detached into fragment")

		-- Space/unsolicited unseat rejected unless ExitVehicleSeat used
		local dSeat = rt.DriverSeatPart :: VehicleSeat
		assertEqual(dSeat:GetAttribute("ManagedVehicleSeat"), true, "DriverSeat guarded by VehicleSeatService")
		local dummyChar = Instance.new("Model")
		dummyChar.Name = "_P421SeatDummy"
		local dummyRoot = Instance.new("Part")
		dummyRoot.Name = "HumanoidRootPart"
		dummyRoot.Size = Vector3.new(2, 2, 1)
		dummyRoot.CFrame = dSeat.CFrame * CFrame.new(0, 3, 0)
		dummyRoot.Parent = dummyChar
		local dummyHum = Instance.new("Humanoid")
		dummyHum.Parent = dummyChar
		dummyChar.PrimaryPart = dummyRoot
		dummyChar.Parent = env.TempPlots
		p1.Character = dummyChar
		dSeat:Sit(dummyHum)
		task.wait()
		assertEqual(dSeat.Occupant, dummyHum, "Dummy seated in DriverSeat")
		assertEqual(dummyHum:GetStateEnabled(Enum.HumanoidStateType.Jumping), false, "Jumping disabled in DriverSeat")
		dummyHum.Jump = true
		dummyHum.Sit = false
		task.wait()
		assertEqual(dummyHum.Jump, false, "Space/Jump blocked while seated")
		assertEqual(dSeat.Occupant, dummyHum, "Casual unseat blocked & re-seated")
		local okExit = VehicleLifecycleService.ExitVehicleSeat(p1)
		assertEqual(okExit, true, "Authorized ExitVehicleSeat ejects cleanly")
		assertEqual(dSeat.Occupant, nil, "DriverSeat vacated on authorized exit")
		dummyChar:Destroy()
		p1.Character = nil

		VehicleLaunchService.ReturnToWorkshop(p1)
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), savedCount, "Draft intact after runtime destruction")
		assertEqual(VehicleBlueprintService.GetBlueprintSlotSummaries(p1)[1].PieceCount, savedCount, "Slot 1 untouched by runtime destruction")
		local _ = ids
		env.Teardown()
	end)

	-- 25) Solicitudes concurrentes y doble clic (idempotencia por ClientOpId + bloqueo de cliente + epoch)
	runTest("Fase 4.2.1 [25]: Concurrent requests, double-click idempotency, Busy lock & stale WorkshopEpoch checks", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42125, Name = "P421_25" }
		PlotService.Assign(p1)

		buildStarterVehicle(p1, "t25", false)
		local epoch0 = VehicleBlueprintService.GetWorkshopEpoch(p1)

		-- Duplicate ClientOpId returns idempotent response without repeating save
		local reqSave = {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_25_idem",
			SlotIndex = 1,
			Name = "Idem",
		}
		local r1 = BuildService.ProcessRequest(p1, reqSave)
		local r2 = BuildService.ProcessRequest(p1, reqSave)
		assertTrue(r1.Success and r2.Success, "Idempotent duplicate returns success cleanly")
		assertEqual(
			(r1.Slots :: { VehicleTypes.BlueprintSlotSummary })[1].Revision,
			(r2.Slots :: { VehicleTypes.BlueprintSlotSummary })[1].Revision,
			"Slot revision not bumped twice on duplicate op"
		)

		-- Stale ExpectedEpoch rejected on ClearWorkshop
		local staleClr = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.ClearWorkshop,
			ClientOpId = "421_25_stale_clr",
			ExpectedEpoch = epoch0 + 99,
		})
		assertEqual(staleClr.Success, false, "Stale WorkshopEpoch rejected")

		-- Client double-click / concurrent operation blocked while in-flight
		local releaseHold = false
		local secondOk, secondResp: any
		local slowBridge = function(req: any): BuildProtocol.BuildOperationResponse
			while not releaseHold do
				task.wait(0.02)
			end
			return BuildService.ProcessRequest(p1, req)
		end

		local firstDone = false
		local firstOk = false
		task.spawn(function()
			firstOk = BlueprintManagerController.SaveBlueprintSlot(2, "Slot2", slowBridge)
			firstDone = true
		end)
		task.wait(0.03)
		assertEqual(BlueprintManagerController.IsBusy(), true, "Controller IsBusy() == true during in-flight op")
		secondOk, secondResp = BlueprintManagerController.DeleteBlueprintSlot(1, "Idem", slowBridge)
		assertEqual(secondOk, false, "Overlapping second operation blocked immediately")
		assertEqual(secondResp.ErrorCode, BuildProtocol.ErrorCodes.OperationInProgress, "Returns OperationInProgress")

		releaseHold = true
		local deadline = os.clock() + 3.0
		while not firstDone and os.clock() < deadline do
			task.wait(0.02)
		end
		assertTrue(firstOk, "First operation finished cleanly")
		assertEqual(BlueprintManagerController.IsBusy(), false, "Controller IsBusy() cleared after completion")
		env.Teardown()
	end)

	-- 26) Guardado + desconexión + reconexión verificando persistencia real
	runTest("Fase 4.2.1 [26]: Saved 3-slot state persists across player disconnect & rejoin with BaseTemplate intact", function()
		local env = setupIsolatedWorld(2)
		local p1: PlotService.PlayerLike = { UserId = 42126, Name = "P421_26" }
		PlotService.Assign(p1)

		buildStarterVehicle(p1, "t26", true)
		local count1 = VehicleBlueprintService.GetPieceCount(p1)
		local okS1 = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SaveBlueprintSlot,
			ClientOpId = "421_26_s1",
			SlotIndex = 1,
			Name = "Persistente1",
		})
		assertTrue(okS1.Success, "Slot 1 saved before disconnect")

		-- Empty workshop then disconnect
		BuildService.ProcessRequest(p1, { Action = BuildProtocol.Actions.ClearWorkshop, ClientOpId = "421_26_clr" })
		assertTrue(BlueprintPersistenceService._GetRawMemorySnapshotForTests(p1.UserId) ~= nil, "Persistence snapshot stored")

		-- Full service reload preserving persistence store (simulates disconnect -> rejoin)
		env.SimulateRejoin(2)
		PlotService.Assign(p1)

		local listAfter = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.ListBlueprintSlots,
			ClientOpId = "421_26_rejoin_list",
		})
		assertTrue(listAfter.Success, "ListBlueprintSlots after rejoin succeeds")
		local slotsAfter = listAfter.Slots :: { VehicleTypes.BlueprintSlotSummary }
		assertEqual(slotsAfter[1].IsOccupied, true, "Slot 1 survived disconnect & rejoin")
		assertEqual(slotsAfter[1].Name, "Persistente1", "Slot 1 name survived")
		assertEqual(slotsAfter[1].PieceCount, count1, "Slot 1 pieces survived")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), 0, "Cleared workshop stayed cleared on rejoin")

		-- Load persisted slot back cleanly
		local reloadRes = BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.LoadBlueprintSlot,
			ClientOpId = "421_26_rejoin_load",
			SlotIndex = 1,
		})
		assertTrue(reloadRes.Success, "Persisted slot loads into workshop after rejoin")
		assertEqual(VehicleBlueprintService.GetPieceCount(p1), count1, "Loaded vehicle has exact persisted pieces")

		local baseTemplate = ServerStorage:FindFirstChild("BaseTemplate")
		assertTrue(baseTemplate ~= nil and #baseTemplate:GetDescendants() >= 25, "ServerStorage.BaseTemplate intact (>=25 descendants)")
		env.Teardown()
	end)

	-- 27) Verificación de visibilidad, contratos UI de 3 tarjetas y no existencia de flujos ambiguos
	runTest("Fase 4.2.1 [27]: 3-slot config, client controllers and UI contracts match Fase 4.2.1 rules", function()
		assertEqual(GameConfig.Blueprints.StorageSchemaVersion, 3, "StorageSchemaVersion == 3")
		assertEqual(GameConfig.Blueprints.MaxSlots, 3, "MaxSlots == 3")
		assertEqual(GameConfig.Blueprints.MaxSavedBlueprintsPerPlayer, 3, "MaxSavedBlueprintsPerPlayer == 3")
		assertEqual(GameConfig.Blueprints.MaxDriverSeatsPerBlueprint, 1, "MaxDriverSeatsPerBlueprint == 1")
		assertEqual(GameConfig.Building.MaxPiecesPerVehicle, 500, "MaxPiecesPerVehicle == 500")

		-- Verify BuildPayloadValidator rejects legacy/unknown payloads cleanly & requires ConfirmationStep=2 for overwrite
		local badOverOk = BuildPayloadValidator.ValidateRequest({
			Action = BuildProtocol.Actions.OverwriteBlueprintSlot,
			ClientOpId = "421_27_bad_ovw",
			SlotIndex = 1,
			ConfirmationStep = 1,
		} :: any, 42127, nil)
		assertEqual(badOverOk, false, "Validator enforces ConfirmationStep == 2")

		local okClear, _, _ = BuildPayloadValidator.ValidateRequest({
			Action = BuildProtocol.Actions.ClearWorkshop,
			ClientOpId = "421_27_clr",
		} :: any, 42127, nil)
		assertTrue(okClear, "Validator accepts ClearWorkshop payload")

		-- When running in Studio Edit mode (.Source readable), assert UI removes "Recargar" and implements required labels
		if not RunService:IsRunning() then
			local mgmtScript = ClientControllers:WaitForChild("VehicleManagement") :: LocalScript
			local src = mgmtScript.Source
			assertEqual(string.find(src, "Recargar", 1, true), nil, "Recargar button completely removed from VehicleManagement UI")
			assertEqual(string.find(src, "QuickSaveBtn", 1, true), nil, "Ambiguous QuickSaveBtn removed from VehicleManagement UI")
			assertTrue(string.find(src, "Vaciar taller", 1, true) ~= nil, "Vaciar taller button present")
			assertTrue(string.find(src, "Guardar vehículo del taller", 1, true) ~= nil, "Empty card action present")
			assertTrue(string.find(src, "Sobrescribir", 1, true) ~= nil, "Sobrescribir action present")
			assertTrue(string.find(src, "Renombrar", 1, true) ~= nil, "Renombrar action present")
			assertTrue(string.find(src, "Eliminar", 1, true) ~= nil, "Eliminar action present")
			assertTrue(string.find(src, "¿Estás seguro de que querés vaciar el taller?", 1, true) ~= nil, "Exact clear confirmation copy present")
		end
	end)
end

function Phase421Tests.RunStandalone()
	local results: { TestCaseResult } = {}
	local passedCount = 0
	local failedCount = 0

	local function runTest(name: string, fn: () -> ())
		local ok, err = xpcall(fn, debug.traceback)
		if ok then
			passedCount += 1
			table.insert(results, { Name = name, Passed = true, Error = nil })
		else
			failedCount += 1
			table.insert(results, { Name = name, Passed = false, Error = tostring(err) })
			pcall(function()
				BuildState.Reset()
				BuildPlacementController.ClearPending()
				BuildPreviewController.InvalidateWorkshopCaches()
				BuildPreviewController.DestroyGhost()
				local leftover = Workspace:FindFirstChild("_Phase421TestPlots")
				if leftover then
					leftover:Destroy()
				end
			end)
			pcall(resetAllServices, false)
		end
	end

	Phase421Tests.AppendTests(results, runTest)
	return {
		Passed = passedCount,
		Failed = failedCount,
		Total = #results,
		Results = results,
	}
end

Phase421Tests.RunAll = Phase421Tests.RunStandalone

return Phase421Tests

