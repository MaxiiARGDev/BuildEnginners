--!strict
--[=[
	EditableVisibilityHotfixTests
	Suite de 15 pruebas automatizadas para el hotfix de ocultamiento/restauración autoritativa
	de `EditableVehicle` durante el ciclo de vida del vehículo (Fases 2.4–3.3):
	  01. Estado inicial en taller (Editing): EditableVehicle visible, sin VehicleRuntime
	  02. Transición Editing -> Driving oculta EditableVehicle y deja único VehicleRuntime visible
	  03. Estado OnFootRuntime (ExitVehicleSeat y MountDriver=false) mantiene EditableVehicle oculto
	  04. ReturnToWorkshop destruye VehicleRuntime y restaura visibilidad/colisiones/queries del EditableVehicle
	  05. Preservación exacta por instancia de propiedades heterogéneas (Transparency parcial, CastShadow=false,
	      CanCollide=false, Decal, Texture, SurfaceAppearance, ParticleEmitter, Beam, Trail, Highlight,
	      PointLight, BillboardGui, SelectionBox, ProximityPrompt, ClickDetector)
	  06. Fallo de lanzamiento (validación y rollback tardío/asiento) mantiene/restaura EditableVehicle visible
	  07. ResetVehicle regenera runtime manteniendo EditableVehicle oculto sin parpadeos ni duplicados (y recupera ante fallo)
	  08. Invariabilidad estricta del Blueprint (LocalCFrames, Connections, Configurations, Presentation, Revision, piezas)
	  09. Bloqueo estricto de construcción y consultas/raycast sobre EditableVehicle mientras está oculto y rehabilitación al regresar
	  10. Idempotencia en llamadas repetidas Hide/Show y ReturnToWorkshop en reposo sin pisar snapshot original
	  11. Invalidación externa del runtime (destrucción externa y AbandonedTimeout) restauran EditableVehicle
	  12. Liberación de plot / ClearPlayer limpia estado sin fugas y permite reutilización limpia por otro jugador
	  13. Aislamiento multijugador simultáneo hasta 10 jugadores (lanzados vs editando y transición cruzada)
	  14. Ciclos repetidos de lanzamiento y regreso (6 ciclos consecutivos con edición intermedia)
	  15. Guardas de controladores cliente (BuildState, BuildSelectionController, BuildTransformController, StandController, BuildPlacementController)
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
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
local VehicleWheelControllerService = require(ServerScriptService.Server.Services.VehicleWheelControllerService)
local VehiclePowertrainService = require(ServerScriptService.Server.Services.VehiclePowertrainService)
local BuildService = require(ServerScriptService.Server.Services.BuildService)
local WheelAutoConfigurationService = require(ServerScriptService.Server.Services.WheelAutoConfigurationService)

local ClientControllers =
	game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState"))
local BuildPreviewController = require(ClientControllers:WaitForChild("BuildPreviewController"))
local BuildSelectionController = require(ClientControllers:WaitForChild("BuildSelectionController"))
local BuildTransformController = require(ClientControllers:WaitForChild("BuildTransformController"))
local StandController = require(ClientControllers:WaitForChild("StandController"))

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local EditableVisibilityHotfixTests = {}

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
		error(`{msg} (expected={string.format("%.4f", expected)}, actual={string.format("%.4f", actual)})`, 2)
	end
end

local function countMapKeys(tbl: { [any]: any }): number
	local n = 0
	for _ in pairs(tbl) do
		n += 1
	end
	return n
end

local function setupIsolatedWorld(plotCount: number?)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder

	local prevPlots = Workspace:FindFirstChild("_EditableVisTestPlots")
	if prevPlots then
		prevPlots:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_EditableVisTestPlots"
	tempPlots.Parent = Workspace

	BuildSelectionController.ClearSelection()
	BuildTransformController.CancelSession()
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
		PlotCount = plotCount or 4,
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

	local rateClock = 5000
	local lifeClock = 5000
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
		TempPlots = tempPlots,
		AdvanceLifeClock = function(seconds: number)
			lifeClock += seconds
		end,
		Teardown = function()
			BuildSelectionController.ClearSelection()
			BuildTransformController.CancelSession()
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

local function buildCompactLaunchableVehicle(player: PlotService.PlayerLike, prefix: string)
	local bF = placePiece(player, `{prefix}_bF`, "WoodBlock", CFrame.new(0, 1.5, -2))
	local bM = placePiece(player, `{prefix}_bM`, "WoodBlock", CFrame.new(0, 1.5, 0))
	local bR = placePiece(player, `{prefix}_bR`, "WoodBlock", CFrame.new(0, 1.5, 2))
	local bFL = placePiece(player, `{prefix}_bFL`, "WoodBlock", CFrame.new(-2, 1.5, -2))
	local bFR = placePiece(player, `{prefix}_bFR`, "WoodBlock", CFrame.new(2, 1.5, -2))
	local bRL = placePiece(player, `{prefix}_bRL`, "WoodBlock", CFrame.new(-2, 1.5, 2))
	local bRR = placePiece(player, `{prefix}_bRR`, "WoodBlock", CFrame.new(2, 1.5, 2))
	local tank = placePiece(player, `{prefix}_tank`, "RegularFuelTank", CFrame.new(0, 3.5, -0.5))
	local eng = placePiece(player, `{prefix}_eng`, "SmallEngine", CFrame.new(0, 3.5, 2.0))
	local seat = placePiece(player, `{prefix}_seat`, "DriverSeat", CFrame.new(0, 5.0, -0.5))
	local wFL = placePiece(player, `{prefix}_wFL`, "SmallWheel", CFrame.new(-3.5, 1.5, -2))
	local wFR = placePiece(player, `{prefix}_wFR`, "SmallWheel", CFrame.new(3.5, 1.5, -2))
	local wRL = placePiece(player, `{prefix}_wRL`, "SmallWheel", CFrame.new(-3.5, 1.5, 2))
	local wRR = placePiece(player, `{prefix}_wRR`, "SmallWheel", CFrame.new(3.5, 1.5, 2))
	return {
		BlockIds = { bF.InstanceId, bM.InstanceId, bR.InstanceId, bFL.InstanceId, bFR.InstanceId, bRL.InstanceId, bRR.InstanceId },
		TankId = tank.InstanceId,
		EngineId = eng.InstanceId,
		SeatId = seat.InstanceId,
		WheelIds = { wFL.InstanceId, wFR.InstanceId, wRL.InstanceId, wRR.InstanceId },
		TotalCount = 14,
	}
end

local function assertEditableHiddenInWorkspace(player: PlotService.PlayerLike, editableModel: Model, label: string)
	assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(player), false, `{label}: IsEditableVehicleVisible must be false`)
	assertEqual(editableModel:GetAttribute("IsEditableHidden"), true, `{label}: IsEditableHidden attribute must be true`)
	assertEqual(editableModel:GetAttribute("EditableVisibilityState"), "Hidden", `{label}: EditableVisibilityState must be Hidden`)

	local partCount = 0
	for _, desc in ipairs(editableModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			partCount += 1
			assertNear(desc.Transparency, 1, 1e-4, `{label}: BasePart {desc:GetFullName()} Transparency must be 1`)
			assertEqual(desc.CastShadow, false, `{label}: BasePart {desc:GetFullName()} CastShadow must be false`)
			assertEqual(desc.CanCollide, false, `{label}: BasePart {desc:GetFullName()} CanCollide must be false`)
			assertEqual(desc.CanQuery, false, `{label}: BasePart {desc:GetFullName()} CanQuery must be false`)
			assertEqual(desc.CanTouch, false, `{label}: BasePart {desc:GetFullName()} CanTouch must be false`)
		elseif desc:IsA("Decal") or desc:IsA("Texture") then
			assertNear(desc.Transparency, 1, 1e-4, `{label}: Decal/Texture {desc.Name} Transparency must be 1`)
		elseif
			desc:IsA("ParticleEmitter")
			or desc:IsA("Beam")
			or desc:IsA("Trail")
			or desc:IsA("Highlight")
			or desc:IsA("Light")
			or desc:IsA("BillboardGui")
			or desc:IsA("SurfaceGui")
			or desc:IsA("ProximityPrompt")
		then
			assertEqual((desc :: any).Enabled, false, `{label}: {desc.ClassName} {desc.Name} Enabled must be false`)
		elseif desc:IsA("SelectionBox") or desc:IsA("SelectionSphere") then
			assertEqual(desc.Visible, false, `{label}: {desc.ClassName} {desc.Name} Visible must be false`)
		elseif desc:IsA("ClickDetector") then
			assertNear(desc.MaxActivationDistance, 0, 1e-4, `{label}: ClickDetector MaxActivationDistance must be 0`)
		end
	end
	assertTrue(partCount > 0, `{label}: EditableVehicle must still contain parts without being destroyed`)
end

local function withDeadDummyCharacter<T>(player: PlotService.PlayerLike, tag: string, callback: () -> T): T
	local deadChar = Instance.new("Model")
	deadChar.Name = "DeadDummyChar_" .. tag
	local deadRoot = Instance.new("Part")
	deadRoot.Name = "HumanoidRootPart"
	deadRoot.Anchored = true
	deadRoot.Parent = deadChar
	local deadHum = Instance.new("Humanoid")
	deadHum.MaxHealth = 100
	deadHum.Health = 0
	deadHum.Parent = deadChar
	deadChar.Parent = Workspace

	local playerAny: any = player
	local prevChar = playerAny.Character
	playerAny.Character = deadChar
	local ok, resultOrErr = pcall(callback)
	playerAny.Character = prevChar
	deadChar:Destroy()
	if not ok then
		error(resultOrErr)
	end
	return resultOrErr
end

function EditableVisibilityHotfixTests.AppendTests(results: { TestCaseResult }, runTest: (name: string, fn: () -> ()) -> ())
	-- 01
	runTest("EditableVis [01]: Estado inicial en taller (Editing) mantiene EditableVehicle visible y sin runtime", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51001, Name = "EditVisInit" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildCompactLaunchableVehicle(p1, "ev01")

		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		assertTrue(editable ~= nil and editable.Parent == plot.DynamicContainer, "EditableVehicle must live in DynamicContainer")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.Editing, "Initial state must be Editing")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "EditableVehicle must start visible")
		assertTrue(editable:GetAttribute("IsEditableHidden") ~= true, "Initial IsEditableHidden cannot be true")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero VehicleRuntime before launch")

		local visiblePartCount = 0
		for _, desc in ipairs(editable:GetDescendants()) do
			if desc:IsA("BasePart") then
				visiblePartCount += 1
				assertTrue(desc.Transparency < 1, `Editable BasePart {desc.Name} starts visible`)
				assertEqual(desc.CanCollide, true, `Editable BasePart {desc.Name} CanCollide starts true`)
				assertEqual(desc.CanQuery, true, `Editable BasePart {desc.Name} CanQuery starts true`)
			end
		end
		assertTrue(visiblePartCount >= 14, "All 14 editable piece parts present and visible")
		env.Teardown()
	end)

	-- 02
	runTest("EditableVis [02]: Editing -> Driving oculta EditableVehicle completamente y deja único VehicleRuntime visible", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51002, Name = "EditVisDrive" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local car = buildCompactLaunchableVehicle(p1, "ev02")
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr.Success and lr.Runtime ~= nil, `Launch failed: {tostring(lr.ErrorCode)} - {tostring(lr.ErrorMessage)}`)
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.Driving, "State must be Driving")
		assertEditableHiddenInWorkspace(p1, editable, "During Driving")
		assertEqual(#editable:GetChildren(), car.TotalCount, "EditableVehicle children count preserved in place")

		-- Único VehicleRuntime activo y visible en DynamicContainer
		local rtModel = rt.RootModel :: Model
		assertTrue(rtModel ~= nil and rtModel ~= editable and rtModel.Parent == plot.DynamicContainer, "Distinct runtime model in DynamicContainer")
		local visibleRuntimeParts = 0
		for _, desc in ipairs(rtModel:GetDescendants()) do
			if desc:IsA("BasePart") and desc.Transparency < 1 then
				visibleRuntimeParts += 1
			end
		end
		assertTrue(visibleRuntimeParts >= 14, "Runtime parts are visible while EditableVehicle is hidden")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 1, "Exactly 1 active VehicleRuntime")
		env.Teardown()
	end)

	-- 03
	runTest("EditableVis [03]: Estado OnFootRuntime (ExitVehicleSeat y MountDriver=false) mantiene EditableVehicle oculto", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51003, Name = "EditVisOnFoot" }
		PlotService.Assign(p1)
		buildCompactLaunchableVehicle(p1, "ev03")
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model

		-- Caso A: Lanzar directamente a OnFootRuntime (MountDriver=false, SimulateSeated=false)
		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			MountDriver = false,
			SimulateSeated = false,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr.Success, "Launch to OnFootRuntime succeeded")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.OnFootRuntime, "State is OnFootRuntime")
		assertEditableHiddenInWorkspace(p1, editable, "OnFootRuntime direct launch")

		-- Caso B: Driving -> ExitVehicleSeat -> OnFootRuntime -> Return
		VehicleLaunchService.ReturnToWorkshop(p1)
		env.AdvanceLifeClock(GameConfig.Runtime.LaunchCooldownSeconds + 0.1)
		local lr2 = VehicleLaunchService.LaunchVehicle(p1, {
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr2.Success, "Second launch to Driving succeeded")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.Driving, "State is Driving")
		assertEditableHiddenInWorkspace(p1, editable, "Driving before ExitVehicleSeat")

		local exitRes = VehicleLaunchService.ExitVehicleSeat(p1)
		assertTrue(exitRes.Success, `ExitVehicleSeat failed: {tostring(exitRes.ErrorMessage)}`)
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.OnFootRuntime, "State transitioned to OnFootRuntime")
		assertEditableHiddenInWorkspace(p1, editable, "OnFootRuntime after ExitVehicleSeat")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 1, "VehicleRuntime remains active in OnFootRuntime")
		env.Teardown()
	end)

	-- 04
	runTest("EditableVis [04]: ReturnToWorkshop destruye VehicleRuntime y restaura visibilidad/colisiones/queries del EditableVehicle", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51004, Name = "EditVisReturn" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildCompactLaunchableVehicle(p1, "ev04")
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr.Success and lr.Runtime ~= nil, "Launch succeeded")
		local rtModel = (lr.Runtime :: VehicleTypes.VehicleRuntime).RootModel :: Model
		assertEditableHiddenInWorkspace(p1, editable, "Before ReturnToWorkshop")

		local retRes = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(retRes.Success, "ReturnToWorkshop succeeded")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.Editing, "State returned to Editing")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Runtime count is 0")
		assertTrue(rtModel.Parent == nil, "Runtime model destroyed cleanly")
		assertTrue(plot.DynamicContainer:FindFirstChild(GameConfig.Runtime.ModelName) == nil, "No stray VehicleRuntime in DynamicContainer")

		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "EditableVehicle restored visible")
		assertEqual(editable:GetAttribute("IsEditableHidden"), false, "IsEditableHidden restored false")
		assertEqual(editable:GetAttribute("EditableVisibilityState"), "Visible", "EditableVisibilityState restored Visible")

		for _, desc in ipairs(editable:GetDescendants()) do
			if desc:IsA("BasePart") then
				assertNear(desc.Transparency, 0, 1e-4, `Restored Transparency == 0 for {desc.Name}`)
				assertEqual(desc.CanCollide, true, `Restored CanCollide == true for {desc.Name}`)
				assertEqual(desc.CanQuery, true, `Restored CanQuery == true for {desc.Name}`)
				assertEqual(desc.CastShadow, true, `Restored CastShadow == true for {desc.Name}`)
			end
		end
		env.Teardown()
	end)

	-- 05
	runTest("EditableVis [05]: Preservación exacta por instancia de propiedades heterogéneas y efectos visuales", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51005, Name = "EditVisProps" }
		PlotService.Assign(p1)
		local car = buildCompactLaunchableVehicle(p1, "ev05")
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model

		-- Configurar propiedades heterogéneas reales sobre piezas distintas dentro de EditableVehicle
		local firstPiece = editable:FindFirstChild(car.BlockIds[1]) :: Model
		local secondPiece = editable:FindFirstChild(car.BlockIds[2]) :: Model
		local firstPart = firstPiece:FindFirstChildWhichIsA("BasePart", true) :: BasePart
		local secondPart = secondPiece:FindFirstChildWhichIsA("BasePart", true) :: BasePart

		firstPart.Transparency = 0.45
		firstPart.CastShadow = false
		firstPart.CanCollide = false -- p.ej. part decorativa no colisionable originalmente

		local decal = Instance.new("Decal")
		decal.Name = "TestDecal"
		decal.Transparency = 0.25
		decal.Parent = secondPart

		local texture = Instance.new("Texture")
		texture.Name = "TestTexture"
		texture.Transparency = 0.35
		texture.Parent = secondPart

		local meshGlass = Instance.new("MeshPart")
		meshGlass.Name = "TestMeshWithSurfaceAppearance"
		meshGlass.Anchored = true
		meshGlass.Transparency = 0.15
		meshGlass.CanCollide = true
		meshGlass.CanQuery = true
		meshGlass.Parent = firstPiece
		local surfaceApp = Instance.new("SurfaceAppearance")
		surfaceApp.Name = "CustomPBR"
		surfaceApp.Parent = meshGlass

		local emitterOn = Instance.new("ParticleEmitter")
		emitterOn.Name = "ActiveSpark"
		emitterOn.Enabled = true
		emitterOn.Parent = secondPart

		local emitterOff = Instance.new("ParticleEmitter")
		emitterOff.Name = "InactiveSpark"
		emitterOff.Enabled = false
		emitterOff.Parent = secondPart

		local att0 = Instance.new("Attachment")
		att0.Parent = firstPart
		local att1 = Instance.new("Attachment")
		att1.Parent = secondPart

		local beam = Instance.new("Beam")
		beam.Attachment0 = att0
		beam.Attachment1 = att1
		beam.Enabled = true
		beam.Parent = firstPart

		local trail = Instance.new("Trail")
		trail.Attachment0 = att0
		trail.Attachment1 = att1
		trail.Enabled = true
		trail.Parent = firstPart

		local hl = Instance.new("Highlight")
		hl.Enabled = true
		hl.Parent = secondPiece

		local light = Instance.new("PointLight")
		light.Enabled = true
		light.Parent = firstPart

		local bbGui = Instance.new("BillboardGui")
		bbGui.Enabled = true
		bbGui.Parent = firstPart

		local selBox = Instance.new("SelectionBox")
		selBox.Adornee = secondPart
		selBox.Visible = true
		selBox.Parent = secondPart

		local prompt = Instance.new("ProximityPrompt")
		prompt.Enabled = true
		prompt.Parent = firstPart

		local clickDet = Instance.new("ClickDetector")
		clickDet.MaxActivationDistance = 24
		clickDet.Parent = secondPart

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr.Success, "Launch with heterogeneous visual instances succeeded")
		assertEditableHiddenInWorkspace(p1, editable, "Heterogeneous launch")
		assertTrue(surfaceApp.Parent == meshGlass, "SurfaceAppearance preserved intact while parent MeshPart Transparency=1")
		assertNear(meshGlass.Transparency, 1, 1e-4, "MeshPart parent of SurfaceAppearance hidden via Transparency=1")

		local retRes = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(retRes.Success, "ReturnToWorkshop succeeded")

		-- Verificar restauración exacta por instancia (nunca aplanar todo a 0 o true)
		assertNear(firstPart.Transparency, 0.45, 1e-4, "Original Transparency 0.45 preserved (NOT flattened to 0)")
		assertEqual(firstPart.CastShadow, false, "Original CastShadow=false preserved")
		assertEqual(firstPart.CanCollide, false, "Original CanCollide=false preserved")
		assertNear(secondPart.Transparency, 0, 1e-4, "Opaque part Transparency=0 preserved")
		assertEqual(secondPart.CastShadow, true, "Opaque part CastShadow=true preserved")
		assertEqual(secondPart.CanCollide, true, "Opaque part CanCollide=true preserved")
		assertNear(meshGlass.Transparency, 0.15, 1e-4, "MeshPart original Transparency 0.15 restored")
		assertTrue(surfaceApp.Parent == meshGlass, "SurfaceAppearance still intact after restore")
		assertNear(decal.Transparency, 0.25, 1e-4, "Decal original Transparency 0.25 restored")
		assertNear(texture.Transparency, 0.35, 1e-4, "Texture original Transparency 0.35 restored")
		assertEqual(emitterOn.Enabled, true, "Originally Enabled ParticleEmitter restored true")
		assertEqual(emitterOff.Enabled, false, "Originally Disabled ParticleEmitter stayed false")
		assertEqual(beam.Enabled, true, "Beam Enabled restored true")
		assertEqual(trail.Enabled, true, "Trail Enabled restored true")
		assertEqual(hl.Enabled, true, "Highlight Enabled restored true")
		assertEqual(light.Enabled, true, "PointLight Enabled restored true")
		assertEqual(bbGui.Enabled, true, "BillboardGui Enabled restored true")
		assertEqual(selBox.Visible, true, "SelectionBox Visible restored true")
		assertEqual(prompt.Enabled, true, "ProximityPrompt Enabled restored true")
		assertNear(clickDet.MaxActivationDistance, 24, 1e-4, "ClickDetector MaxActivationDistance 24 restored")
		env.Teardown()
	end)

	-- 06
	runTest("EditableVis [06]: Fallos de lanzamiento (validación y rollback tardío/asiento) restauran EditableVehicle visible", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51006, Name = "EditVisRollback" }
		PlotService.Assign(p1)
		local b1 = placePiece(p1, "ev06_b1", "WoodBlock", CFrame.new(0, 1.5, -4))
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		local part1 = (editable:FindFirstChild(b1.InstanceId) :: Model):FindFirstChildWhichIsA("BasePart", true) :: BasePart
		part1.Transparency = 0.3

		-- Subcaso A: fallo de preparación (sin DriverSeat) -> permanece en Editing y visible con transparencia 0.3
		local failPrep = VehicleLaunchService.LaunchVehicle(p1, {
			MountDriver = false,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(not failPrep.Success, "Launch without DriverSeat must fail")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.Editing, "State stays Editing on LaunchPrep failure")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "Editable stays visible after failed prep")
		assertNear(part1.Transparency, 0.3, 1e-4, "Partial transparency untouched after failed prep")

		-- Subcaso B: completar vehículo y forzar fallo tardío de montaje en DriverSeat (Character muerto tras PublishAndActivate)
		buildCompactLaunchableVehicle(p1, "ev06")
		part1.Transparency = 0.3
		local failMount = withDeadDummyCharacter(p1, "ev06", function()
			return VehicleLaunchService.LaunchVehicle(p1, {
				MountDriver = true,
				SkipSeatRetryYield = true,
				SkipWorldObstructionCheck = true,
			})
		end)
		assertTrue(not failMount.Success, "Launch with dead Character on MountDriver=true must fail and rollback")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.Editing, "State rolled back to Editing")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Runtime cleaned up after mount rollback")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "Editable restored visible after late mount rollback")
		assertNear(part1.Transparency, 0.3, 1e-4, "Original transparency 0.3 preserved after late mount rollback")
		assertNear(part1.Transparency, 0.3, 1e-4, "Original transparency 0.3 restored after mount rollback")
		assertEqual(part1.CanCollide, true, "CanCollide restored after mount rollback")

		-- Subcaso C: RollbackLaunch directo llamado durante estado Launching con editable oculto
		assertTrue(VehicleLifecycleService.BeginLaunchPreparation(p1), "BeginLaunchPreparation")
		assertTrue(VehicleLifecycleService.TransitionToLaunching(p1), "TransitionToLaunching")
		VehicleBlueprintService.SetEditableVehicleVisible(p1, false, "SimulatedLaunchPublish")
		assertEditableHiddenInWorkspace(p1, editable, "Hidden before direct RollbackLaunch")
		VehicleLifecycleService.RollbackLaunch(p1, "SimulatedFail", "Abort")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.Editing, "Rollback sets Editing")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "Direct RollbackLaunch restores visibility")
		assertNear(part1.Transparency, 0.3, 1e-4, "Original transparency preserved through direct RollbackLaunch")
		env.Teardown()
	end)

	-- 07
	runTest("EditableVis [07]: ResetVehicle regenera VehicleRuntime único manteniendo EditableVehicle oculto y recupera ante error", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51007, Name = "EditVisReset" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildCompactLaunchableVehicle(p1, "ev07")
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model

		local lr1 = VehicleLaunchService.LaunchVehicle(p1, {
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr1.Success and lr1.Runtime ~= nil, "Initial launch succeeded")
		local id1 = (lr1.Runtime :: VehicleTypes.VehicleRuntime).RuntimeId
		assertEditableHiddenInWorkspace(p1, editable, "Before ResetVehicle")

		-- Vigilar que EditableVehicle NUNCA parpadee a visible durante ResetVehicle exitoso
		local unblockedShowCount = 0
		local attrConn = editable:GetAttributeChangedSignal("IsEditableHidden"):Connect(function()
			if editable:GetAttribute("IsEditableHidden") == false then
				unblockedShowCount += 1
			end
		end)

		env.AdvanceLifeClock(GameConfig.Runtime.LaunchCooldownSeconds + 0.1)
		local resetRes = VehicleLaunchService.ResetVehicle(p1, {
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		attrConn:Disconnect()

		assertTrue(resetRes.Success and resetRes.Runtime ~= nil, `ResetVehicle failed: {tostring(resetRes.ErrorMessage)}`)
		local id2 = (resetRes.Runtime :: VehicleTypes.VehicleRuntime).RuntimeId
		assertTrue(id2 ~= id1, "ResetVehicle produced fresh RuntimeId")
		assertEqual(unblockedShowCount, 0, "EditableVehicle must NOT flicker visible during ResetVehicle")
		assertEditableHiddenInWorkspace(p1, editable, "After successful ResetVehicle")
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 1, "Only 1 active runtime after ResetVehicle")

		local runtimeModels = 0
		for _, child in ipairs(plot.DynamicContainer:GetChildren()) do
			if child.Name == GameConfig.Runtime.ModelName then
				runtimeModels += 1
			end
		end
		assertEqual(runtimeModels, 1, "Zero duplicate VehicleRuntime models in DynamicContainer")

		-- Fallo tardío en ResetVehicle (Character muerto tras PublishAndActivate) debe hacer rollback y restaurar editable
		env.AdvanceLifeClock(GameConfig.Runtime.LaunchCooldownSeconds + 0.1)
		local resetFail = withDeadDummyCharacter(p1, "ev07", function()
			return VehicleLaunchService.ResetVehicle(p1, {
				MountDriver = true,
				SkipSeatRetryYield = true,
				SkipWorldObstructionCheck = true,
			})
		end)
		assertTrue(not resetFail.Success, "ResetVehicle with dead character on MountDriver=true rolls back cleanly")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.Editing, "Failed reset returns to Editing")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "Failed reset restores EditableVehicle visible")
		env.Teardown()
	end)

	-- 08
	runTest("EditableVis [08]: Invariabilidad estricta del Blueprint durante todo el ciclo ocultamiento/restauración", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51008, Name = "EditVisBpIntact" }
		PlotService.Assign(p1)
		local car = buildCompactLaunchableVehicle(p1, "ev08")
		BuildService.ProcessRequest(p1, {
			Action = BuildProtocol.Actions.SetStandOffset,
			ClientOpId = "ev08_lift",
			HeightOffset = 2.0,
			LateralOffset = -1.5,
		})

		local before = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		local beforeLiftOffset = VehicleBlueprintService.GetLiftOffset(p1)

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr.Success, "Launch succeeded")
		VehicleLaunchService.ExitVehicleSeat(p1)
		env.AdvanceLifeClock(GameConfig.Runtime.LaunchCooldownSeconds + 0.1)
		VehicleLaunchService.ResetVehicle(p1, { SimulateSeated = true, SkipWorldObstructionCheck = true })
		VehicleLaunchService.ReturnToWorkshop(p1)

		local after = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local afterLiftOffset = VehicleBlueprintService.GetLiftOffset(p1)
		assertEqual(after.BlueprintId, before.BlueprintId, "BlueprintId unchanged")
		assertEqual(after.Revision, before.Revision, "Blueprint Revision unchanged")
		assertEqual(#after.Pieces, #before.Pieces, "Piece count unchanged")
		assertEqual(#after.Connections, #before.Connections, "Connection graph edge count unchanged")
		assertNear(afterLiftOffset.HeightOffset, beforeLiftOffset.HeightOffset, 1e-4, "Stand height offset preserved")
		assertNear(afterLiftOffset.LateralOffset, beforeLiftOffset.LateralOffset, 1e-4, "Stand lateral offset preserved")
		assertEqual(#editable:GetChildren(), car.TotalCount, "EditableVehicle child models preserved")

		local afterById: { [string]: VehicleTypes.BlueprintPiece } = {}
		for _, p in ipairs(after.Pieces) do
			afterById[p.InstanceId] = p
		end
		for _, pBefore in ipairs(before.Pieces) do
			local pAfter = afterById[pBefore.InstanceId]
			assertTrue(pAfter ~= nil, `Missing piece {pBefore.InstanceId}`)
			assertEqual(pAfter.ItemId, pBefore.ItemId, `ItemId unchanged for {pBefore.InstanceId}`)
			assertNear((pAfter.LocalCFrame.Position - pBefore.LocalCFrame.Position).Magnitude, 0, 1e-5, `LocalCFrame unchanged for {pBefore.InstanceId}`)
		end
		env.Teardown()
	end)

	-- 09
	runTest("EditableVis [09]: Bloqueo de mutaciones y raycasts mientras EditableVehicle está oculto y rehabilitación al volver", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51009, Name = "EditVisLock" }
		PlotService.Assign(p1)
		local car = buildCompactLaunchableVehicle(p1, "ev09")
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		local seatModel = editable:FindFirstChild(car.SeatId) :: Model
		local seatPart = seatModel:FindFirstChildWhichIsA("BasePart", true) :: BasePart

		-- Confirmar raycast impacta EditableVehicle antes del lanzamiento
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Include
		rayParams.FilterDescendantsInstances = { editable }
		local hitBefore = Workspace:Raycast(seatPart.Position + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), rayParams)
		assertTrue(hitBefore ~= nil and hitBefore.Instance ~= nil, "Raycast hits EditableVehicle while Editing")

		local lr = VehicleLaunchService.LaunchVehicle(p1, {
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr.Success, "Launch succeeded")

		-- Raycast directo contra EditableVehicle oculto debe ignorarlo (CanQuery=false)
		local hitWhileHidden = Workspace:Raycast(seatPart.Position + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), rayParams)
		assertTrue(hitWhileHidden == nil, "Raycast MUST NOT hit hidden EditableVehicle (CanQuery=false)")

		-- Overlap query tampoco detecta piezas colisionables/consultables en EditableVehicle
		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Include
		overlapParams.FilterDescendantsInstances = { editable }
		local overlapHidden = Workspace:GetPartBoundsInBox(seatPart.CFrame, Vector3.new(6, 6, 6), overlapParams)
		assertEqual(#overlapHidden, 0, "GetPartBoundsInBox ignores hidden EditableVehicle parts (CanQuery=false)")

		-- Toda operación de construcción bloqueada en Driving y en OnFootRuntime
		for _, checkPhase in ipairs({ "Driving", "OnFootRuntime" }) do
			if checkPhase == "OnFootRuntime" then
				VehicleLaunchService.ExitVehicleSeat(p1)
			end
			local placeBlocked = BuildService.ProcessRequest(p1, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = `blk_place_{checkPhase}`,
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(6, 1.5, 0),
			})
			assertTrue(not placeBlocked.Success and placeBlocked.ErrorCode == BuildProtocol.ErrorCodes.InvalidPlayerState, `PlacePiece blocked in {checkPhase}`)

			local removeBlocked = BuildService.ProcessRequest(p1, {
				Action = BuildProtocol.Actions.RemovePiece,
				ClientOpId = `blk_rem_{checkPhase}`,
				PieceInstanceId = car.BlockIds[1],
			})
			assertTrue(not removeBlocked.Success and removeBlocked.ErrorCode == BuildProtocol.ErrorCodes.InvalidPlayerState, `RemovePiece blocked in {checkPhase}`)

			local standBlocked = BuildService.ProcessRequest(p1, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = `blk_stand_{checkPhase}`,
				HeightOffset = 2,
				LateralOffset = 0,
			})
			assertTrue(not standBlocked.Success and standBlocked.ErrorCode == BuildProtocol.ErrorCodes.InvalidPlayerState, `SetStandOffset blocked in {checkPhase}`)
		end

		-- ReturnToWorkshop rehabilita raycast y edición
		VehicleLaunchService.ReturnToWorkshop(p1)
		local hitRestored = Workspace:Raycast(seatPart.Position + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), rayParams)
		assertTrue(hitRestored ~= nil and hitRestored.Instance ~= nil, "Raycast hits EditableVehicle again after ReturnToWorkshop")
		local extra = placePiece(p1, "ev09_after", "WoodBlock", CFrame.new(6, 1.5, 0))
		assertTrue(extra ~= nil, "Building re-enabled after ReturnToWorkshop")
		env.Teardown()
	end)

	-- 10
	runTest("EditableVis [10]: Idempotencia Hide/Hide y Show/Show sin sobrescribir snapshot ni valores originales", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51010, Name = "EditVisIdemp" }
		PlotService.Assign(p1)
		local car = buildCompactLaunchableVehicle(p1, "ev10")
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		local pModel = editable:FindFirstChild(car.BlockIds[1]) :: Model
		local part = pModel:FindFirstChildWhichIsA("BasePart", true) :: BasePart
		part.Transparency = 0.37
		part.CastShadow = false

		assertTrue(VehicleBlueprintService.SetEditableVehicleVisible(p1, false, "Hide1"), "First hide")
		assertTrue(VehicleBlueprintService.SetEditableVehicleVisible(p1, false, "Hide2"), "Second hide idempotent")
		assertEditableHiddenInWorkspace(p1, editable, "After repeated Hide calls")

		assertTrue(VehicleBlueprintService.SetEditableVehicleVisible(p1, true, "Show1"), "First show")
		assertTrue(VehicleBlueprintService.SetEditableVehicleVisible(p1, true, "Show2"), "Second show idempotent")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "Visible after Show calls")
		assertNear(part.Transparency, 0.37, 1e-4, "Repeated Hide calls MUST NOT clobber original 0.37 Transparency with 1.0")
		assertEqual(part.CastShadow, false, "Repeated Hide calls preserve original CastShadow=false")

		-- ReturnToWorkshop en estado ya Editing: LaunchService rechaza con RuntimeNotActive; LifecycleService sana ocultamiento residual
		assertTrue(VehicleBlueprintService.SetEditableVehicleVisible(p1, false, "ResidualHide"), "Force residual hide while Editing")
		local launchIdleReject = VehicleLaunchService.ReturnToWorkshop(p1)
		assertTrue(not launchIdleReject.Success, "VehicleLaunchService.ReturnToWorkshop rejects safely when already Editing")
		local retOk, retErr = VehicleLifecycleService.ReturnToWorkshop(p1, "TestIdleHeal", true)
		assertTrue(retOk, `VehicleLifecycleService.ReturnToWorkshop when already Editing heals residual hide ({tostring(retErr)})`)
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "Residual hide healed")
		assertNear(part.Transparency, 0.37, 1e-4, "Original Transparency preserved when healing residual hide")
		env.Teardown()
	end)

	-- 11
	runTest("EditableVis [11]: Invalidación externa del runtime y AbandonedTimeout restauran EditableVehicle", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51011, Name = "EditVisInval" }
		PlotService.Assign(p1)
		buildCompactLaunchableVehicle(p1, "ev11")
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model

		-- Caso A: destrucción externa del VehicleRuntime -> GetRuntimeByPlayer / reconciliación devuelve a Editing y restaura EditableVehicle
		local lr1 = VehicleLaunchService.LaunchVehicle(p1, {
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr1.Success and lr1.Runtime ~= nil, "First launch succeeded")
		assertEditableHiddenInWorkspace(p1, editable, "Hidden before external runtime destruction")
		local rtModel1 = (lr1.Runtime :: VehicleTypes.VehicleRuntime).RootModel :: Model
		rtModel1:Destroy()
		-- Trigger Ancestry/Reconciliation
		local checkRt = VehicleRuntimeService.GetRuntimeByPlayer(p1)
		assertTrue(checkRt == nil, "Runtime invalidated cleanly")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.Editing, "State returned to Editing on external destruction")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "EditableVehicle restored on external runtime destruction")

		-- Caso B: AbandonedTimeout en OnFootRuntime -> CheckAbandonedVehicles restaura EditableVehicle
		env.AdvanceLifeClock(GameConfig.Runtime.LaunchCooldownSeconds + 0.1)
		local lr2 = VehicleLaunchService.LaunchVehicle(p1, {
			MountDriver = false,
			SimulateSeated = false,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr2.Success, "Second launch to OnFootRuntime succeeded")
		assertEditableHiddenInWorkspace(p1, editable, "Hidden before AbandonedTimeout")

		env.AdvanceLifeClock(GameConfig.Runtime.AbandonedTimeoutSeconds + 5)
		local cleaned = VehicleLifecycleService.CheckAbandonedVehicles()
		assertEqual(cleaned, 1, "CheckAbandonedVehicles cleaned 1 runtime")
		assertEqual(VehicleLifecycleService.GetPlayerState(p1), GameConfig.Runtime.States.Editing, "Abandoned return set state Editing")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "Abandoned cleanup restored EditableVehicle visible")
		env.Teardown()
	end)

	-- 12
	runTest("EditableVis [12]: Liberación de plot / ClearPlayer limpia sin fugas y permite reutilizar el plot limpio", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51012, Name = "EditVisLeave1" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		buildCompactLaunchableVehicle(p1, "ev12a")

		local lr1 = VehicleLaunchService.LaunchVehicle(p1, {
			SimulateSeated = true,
			SkipWorldObstructionCheck = true,
		})
		assertTrue(lr1.Success, "First player launched")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), false, "First player editable hidden")

		-- Simular salida / liberación de plot con vehículo todavía lanzado
		PlotService.Release(p1)
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, "Zero active runtimes after PlotService.Release")
		assertEqual(plot.DynamicContainer:FindFirstChild(GameConfig.Building.EditableVehicleName), nil, "Old EditableVehicle destroyed")
		assertEqual(plot.DynamicContainer:FindFirstChild(GameConfig.Runtime.ModelName), nil, "Old VehicleRuntime destroyed")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, "No stale hidden state cached after Clear/Release")

		-- Nuevo jugador toma la misma estación: su EditableVehicle comienza limpio y 100% visible
		local p2: PlotService.PlayerLike = { UserId = 51099, Name = "EditVisJoin2" }
		local plot2 = PlotService.Assign(p2) :: PlotService.PlotRecord
		assertEqual(plot2.PlotId, plot.PlotId, "Second player reuses released plot")
		placePiece(p2, "ev12b_b1", "WoodBlock", CFrame.new(0, 1.5, 0))
		local editable2 = VehicleBlueprintService.GetEditableVehicleModel(p2) :: Model
		assertTrue(editable2 ~= nil, "New player EditableVehicle created")
		assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p2), true, "New player EditableVehicle starts visible")
		local part2 = editable2:FindFirstChildWhichIsA("BasePart", true) :: BasePart
		assertNear(part2.Transparency, 0, 1e-4, "New player EditableVehicle starts opaque")
		assertEqual(part2.CanCollide, true, "New player EditableVehicle starts collidable")
		env.Teardown()
	end)

	-- 13
	runTest("EditableVis [13]: Aislamiento multijugador simultáneo con 10 jugadores", function()
		local env = setupIsolatedWorld(10)
		local players: { PlotService.PlayerLike } = {}
		local editables: { [number]: Model } = {}

		for i = 1, 10 do
			local plr: PlotService.PlayerLike = { UserId = 52000 + i, Name = `SimVis_{i}` }
			PlotService.Assign(plr)
			buildCompactLaunchableVehicle(plr, `mp{i}`)
			editables[i] = VehicleBlueprintService.GetEditableVehicleModel(plr) :: Model
			table.insert(players, plr)
		end

		-- Impares (1,3,5,7,9) lanzan; pares (2,4,6,8,10) siguen editando
		for i = 1, 10, 2 do
			local lr = VehicleLaunchService.LaunchVehicle(players[i], {
				SimulateSeated = (i ~= 5),
				SkipWorldObstructionCheck = true,
			})
			assertTrue(lr.Success, `Odd player {i} launch failed: {tostring(lr.ErrorMessage)}`)
		end
		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 5, "5 launched players active")

		for i = 1, 10 do
			if i % 2 == 1 then
				assertEditableHiddenInWorkspace(players[i], editables[i], `Odd player {i} launched`)
			else
				assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(players[i]), true, `Even player {i} remains visible`)
				for _, desc in ipairs(editables[i]:GetDescendants()) do
					if desc:IsA("BasePart") then
						assertNear(desc.Transparency, 0, 1e-4, `Even player {i} piece visible`)
						assertEqual(desc.CanCollide, true, `Even player {i} piece CanCollide intact`)
						assertEqual(desc.CanQuery, true, `Even player {i} piece CanQuery intact`)
					end
				end
			end
		end

		-- Cruzar: pares lanzan, impares regresan al taller
		for i = 2, 10, 2 do
			local lr = VehicleLaunchService.LaunchVehicle(players[i], {
				SimulateSeated = true,
				SkipWorldObstructionCheck = true,
			})
			assertTrue(lr.Success, `Even player {i} launch failed`)
		end
		for i = 1, 10, 2 do
			assertTrue(VehicleLaunchService.ReturnToWorkshop(players[i]).Success, `Odd player {i} return`)
		end

		assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 5, "Exactly 5 even runtimes active")
		for i = 1, 10 do
			if i % 2 == 0 then
				assertEditableHiddenInWorkspace(players[i], editables[i], `Even player {i} now launched`)
			else
				assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(players[i]), true, `Odd player {i} restored visible`)
			end
		end
		env.Teardown()
	end)

	-- 14
	runTest("EditableVis [14]: 6 ciclos consecutivos de lanzamiento, conducción, reset y regreso sin fugas ni duplicados", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51014, Name = "EditVisCycles" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local car = buildCompactLaunchableVehicle(p1, "ev14")
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		local refPart = (editable:FindFirstChild(car.BlockIds[1]) :: Model):FindFirstChildWhichIsA("BasePart", true) :: BasePart
		refPart.Transparency = 0.2

		for cycle = 1, 6 do
			env.AdvanceLifeClock(GameConfig.Runtime.LaunchCooldownSeconds + 0.1)
			local lr = VehicleLaunchService.LaunchVehicle(p1, {
				SimulateSeated = true,
				SkipWorldObstructionCheck = true,
			})
			assertTrue(lr.Success, `Cycle {cycle} launch failed`)
			assertEditableHiddenInWorkspace(p1, editable, `Cycle {cycle} driving`)
			assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 1, `Cycle {cycle} runtime count == 1`)

			VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0 })
			VehiclePowertrainService.StepAll(0.05)
			VehicleWheelControllerService.StepAll(0.05)

			assertTrue(VehicleLaunchService.ExitVehicleSeat(p1).Success, `Cycle {cycle} exit seat`)
			assertEditableHiddenInWorkspace(p1, editable, `Cycle {cycle} on foot`)

			if cycle % 2 == 0 then
				env.AdvanceLifeClock(GameConfig.Runtime.LaunchCooldownSeconds + 0.1)
				assertTrue(VehicleLaunchService.ResetVehicle(p1, {
					SimulateSeated = true,
					SkipWorldObstructionCheck = true,
				}).Success, `Cycle {cycle} ResetVehicle failed`)
				assertEditableHiddenInWorkspace(p1, editable, `Cycle {cycle} post-reset`)
			end

			assertTrue(VehicleLaunchService.ReturnToWorkshop(p1).Success, `Cycle {cycle} return failed`)
			assertEqual(VehicleRuntimeService.GetActiveRuntimeCount(), 0, `Cycle {cycle} runtime cleaned`)
			assertEqual(VehicleBlueprintService.IsEditableVehicleVisible(p1), true, `Cycle {cycle} editable visible`)
			assertNear(refPart.Transparency, 0.2, 1e-4, `Cycle {cycle} preserved 0.2 transparency`)

			if cycle == 3 then
				local extra = placePiece(p1, "ev14_mid_extra", "WoodBlock", CFrame.new(0, 1.5, -4))
				assertTrue(extra ~= nil, "Mid-cycle placement after return succeeded")
			end
		end

		local dynamicNames: { [string]: number } = {}
		for _, child in ipairs(plot.DynamicContainer:GetChildren()) do
			dynamicNames[child.Name] = (dynamicNames[child.Name] or 0) + 1
		end
		assertEqual(dynamicNames[GameConfig.Building.EditableVehicleName], 1, "Exactly 1 EditableVehicle after 6 cycles")
		assertEqual(dynamicNames[GameConfig.Runtime.ModelName], nil, "Zero VehicleRuntime remnants after 6 cycles")
		env.Teardown()
	end)

	-- 15
	runTest("EditableVis [15]: Guardas de controladores cliente al ocultar/restaurar EditableVehicle", function()
		local env = setupIsolatedWorld(1)
		local p1: PlotService.PlayerLike = { UserId = 51015, Name = "EditVisClientGuards" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local car = buildCompactLaunchableVehicle(p1, "ev15")
		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		local pieceModel = editable:FindFirstChild(car.BlockIds[1]) :: Model
		local part = pieceModel:FindFirstChildWhichIsA("BasePart", true) :: BasePart

		BuildState.Reset()
		BuildState.SetExpectedOwner(p1.UserId)
		BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), true)
		BuildState.SetActive(true)
		BuildState.SetActiveTool(GameConfig.Building.TransformTools.Move)
		assertTrue(BuildSelectionController.SelectPieceById(car.BlockIds[1]), "Client selected placed piece while Editing")
		BuildTransformController.UpdateVisuals()
		assertTrue(BuildTransformController.HasActiveSession(), "TransformSession opened while Editing")

		-- Simular transición cliente a PreparingLaunch antes/durante ocultamiento autoritativo del servidor
		VehicleBlueprintService.SetEditableVehicleVisible(p1, false, "LaunchConfirmed")
		BuildState.SetRuntimeActionInFlight(true, nil, GameConfig.Runtime.States.PreparingLaunch :: VehicleTypes.VehicleState)
		assertEqual(BuildState.IsActive, false, "Editor closes cleanly on optimistic PreparingLaunch")

		-- CancelSession NO debe sobreescribir Transparency = 1 del servidor al restaurar dimmed transparency
		BuildTransformController.CancelSession()
		assertNear(part.Transparency, 1, 1e-4, "CancelSession must NOT overwrite server-hidden Transparency=1 back to 0")

		-- Selección / elevador cliente bloqueados mientras está oculto o fuera de Editing
		assertEqual(BuildSelectionController.SelectPieceById(car.BlockIds[1]), false, "SelectPieceById blocked while hidden")
		assertEqual(StandController.ApplyOptimisticVisual(2, 0), false, "StandController.ApplyOptimisticVisual blocked out of Editing")

		-- Restaurar a Editing en servidor y cliente -> vuelve a permitir selección
		VehicleBlueprintService.SetEditableVehicleVisible(p1, true, "ReturnedToEditing")
		BuildState.SetRuntimeStatus({
			State = GameConfig.Runtime.States.Editing :: VehicleTypes.VehicleState,
			PlotId = plot.PlotId,
			HasActiveRuntime = false,
			CanLaunch = true,
			CanEdit = true,
		})
		BuildState.SetActive(true)
		assertTrue(BuildSelectionController.SelectPieceById(car.BlockIds[1]), "Client selection works again once back in Editing")
		BuildSelectionController.ClearSelection()
		env.Teardown()
	end)

	-- Sanity helper countMapKeys check (keep Luau happy if unused warning applies)
	local _ = countMapKeys
end

return EditableVisibilityHotfixTests
