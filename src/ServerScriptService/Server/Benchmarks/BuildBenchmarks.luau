--!strict
--[=[
	BuildBenchmarks
	Herramienta real de profiling/benchmarks end-to-end para vehículos de 25, 50, 100 y 200 piezas.
	Ejecuta colocación autoritativa real en BuildService, búsqueda de conexiones en ConnectionService,
	SmartSnap con índice espacial en ConnectionMath, validación de eliminación, generación de snapshot
	y conteo real de instancias/memoria en Roblox Studio.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
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

export type BenchmarkEntry = {
	PieceCount: number,
	LastPlaceMs: number,
	AvgPlaceWindowMs: number,
	ValidateConnectionsMs: number,
	SmartSnapWithIndexMs: number,
	RemoveLeafValidateMs: number,
	RemoveCycleValidateMs: number,
	SnapshotSyncMs: number,
	SaveBlueprintMs: number,
	LoadRebuildMs: number,
	StandOffsetUpdateMs: number,
	LaunchPrepMs: number,
	RuntimeLaunchMs: number,
	RuntimeCleanupMs: number,
	RuntimeParts: number,
	RuntimeJoints: number,
	EditableModelCount: number,
	EditableDescendantCount: number,
	LuaHeapDeltaKB: number,
	TotalStudioMemMB: number,
}

export type MultiPlayerLaunchBenchmarkEntry = {
	PlayerCount: number,
	PiecesPerVehicle: number,
	TotalLaunchMs: number,
	AvgPerPlayerLaunchMs: number,
	TotalCleanupMs: number,
	TotalStudioMemMB: number,
}

export type WheelConfigBenchmarkEntry = {
	WheelCount: number,
	TotalPieces: number,
	AnalyzeMs: number,
	LaunchMs: number,
	Step60FramesAvgMs: number,
	WheelConstraints: number,
	RuntimeJoints: number,
	CleanupMs: number,
	TotalStudioMemMB: number,
}

export type WheelMultiPlayerBenchmarkEntry = {
	PlayerCount: number,
	WheelsPerVehicle: number,
	TotalWheels: number,
	TotalLaunchMs: number,
	AvgPerPlayerLaunchMs: number,
	CentralStep60FramesAvgMs: number,
	TotalCleanupMs: number,
	TotalStudioMemMB: number,
}

export type Phase41SizeBenchmarkEntry = {
	PieceCount: number,
	LaunchMs: number,
	TrackedConnections: number,
	TrackedParts: number,
	ImpactEvalAvgUs: number,
	ApplyImpactAvgUs: number,
	SummaryQueryAvgUs: number,
	CleanupMs: number,
	LuaHeapDeltaKB: number,
	TotalStudioMemMB: number,
	RemainingConnectionsAfterCleanup: number,
	RemainingDamageRuntimesAfterCleanup: number,
	RemainingImpactVehiclesAfterCleanup: number,
}

export type Phase41TenPlayerBenchmarkEntry = {
	PlayerCount: number,
	PiecesPerVehicle: number,
	TotalLaunchMs: number,
	BatchImpactTotalMs: number,
	AvgImpactPerVehicleUs: number,
	PeakTrackedConnections: number,
	TotalCleanupMs: number,
	TotalStudioMemMB: number,
	RemainingConnectionsAfterCleanup: number,
	RemainingDamageRuntimesAfterCleanup: number,
	RemainingImpactVehiclesAfterCleanup: number,
	RemainingRuntimesAfterCleanup: number,
}

export type Phase41BenchmarkSuiteResult = {
	SingleVehicleSizes: { Phase41SizeBenchmarkEntry },
	TenPlayersConcurrent: Phase41TenPlayerBenchmarkEntry,
}

local BuildBenchmarks = {}

type BenchStep = {
	ItemId: string,
	LocalCFrame: CFrame,
}

-- Genera un vehículo conectado realista de hasta `count` piezas dentro de BuildZone 40x32x40 sin superposiciones.
-- Para count <= 200 conserva el plan mixto WoodBlock + WoodBeam horizontales/verticales;
-- para count > 200 usa serpentina continua 10x10x5 de WoodBlock (hasta 500 piezas).
local function buildConnectedVehiclePlan(count: number): { BenchStep }
	local plan: { BenchStep } = table.create(count)

	if count > 200 then
		for layer = 0, 4 do
			local y = 1.0 + layer * 2.0
			local zStart = if layer % 2 == 0 then 0 else 9
			local zEnd = if layer % 2 == 0 then 9 else 0
			local zStep = if layer % 2 == 0 then 1 else -1
			for iz = zStart, zEnd, zStep do
				for ix = 0, 9 do
					if #plan >= count then
						return plan
					end
					local actualIx = if (iz % 2 == layer % 2) then ix else (9 - ix)
					local x = -8 + actualIx * 2
					local z = -8 + iz * 2
					table.insert(plan, {
						ItemId = "WoodBlock",
						LocalCFrame = CFrame.new(x, y, z),
					})
				end
			end
		end
		return plan
	end

	-- Capa base: grilla 10x10 de WoodBlock (2x2x2) -> X=[-8..10], Z=[-8..10], Y=1.0 (base Y=0.0 sobre Platform)
	local baseCols = 10
	local baseRows = 10
	for iz = 0, baseRows - 1 do
		for ix = 0, baseCols - 1 do
			if #plan >= count then
				return plan
			end
			-- Recorrido serpentina en Z/X para que cada bloque siempre toque al anterior
			local actualIx = if iz % 2 == 0 then ix else (baseCols - 1 - ix)
			local x = -8 + actualIx * 2
			local z = -8 + iz * 2
			table.insert(plan, {
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(x, 1.0, z),
			})
		end
	end

	-- Segunda capa mixta: sobre cada fila Z pares colocamos pares de WoodBeam horizontales (1x1x4) en Y=2.5
	-- Ocupan Y=[2.0, 3.0], tocando exactamente la cara superior Y=2.0 de la capa base.
	local rotY90 = BuildRotation.RotateY(BuildRotation.Identity(), 1)
	for iz = 0, baseRows - 1 do
		local z = -8 + iz * 2
		for bx = -7, 9, 4 do
			if #plan >= count then
				return plan
			end
			table.insert(plan, {
				ItemId = "WoodBeam",
				LocalCFrame = CFrame.new(bx, 2.5, z) * rotY90,
			})
		end
	end

	-- Tercera capa adicional por si count > 150: postes verticales WoodBeam (1x4x1) encima de horizontales
	local rotX90 = BuildRotation.RotateX(BuildRotation.Identity(), 1)
	for ix = 0, baseCols - 1 do
		local x = -8 + ix * 2
		for iz = 0, 5 do
			if #plan >= count then
				return plan
			end
			local z = -8 + iz * 2
			if iz >= 0 then
				-- Si ya hay WoodBeam horizontal en Y=[2.0..3.0], colocar poste en Y=[3.0..7.0] (centro Y=5.0)
				table.insert(plan, {
					ItemId = "WoodBeam",
					LocalCFrame = CFrame.new(x, 5.0, z) * rotX90,
				})
			end
		end
	end

	return plan
end

local function resetBenchServices()
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
	SpawnService._ResetForTests()
	VehicleLaunchPreparationService._ResetForTests()
	StandPreviewService._ResetForTests()
	VehicleBlueprintService._ResetForTests()
	InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
	ConnectionService._ResetForTests()
	WheelAutoConfigurationService._ResetForTests()
	BoosterInventoryService.ResetAllForTests()
	EngineInventoryService.ResetAllForTests()
	PlotService._ResetForTests()
	InventoryService.Init()
end

local function initBenchServices(tempPlots: Folder, plotCount: number)
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local assets = ServerStorage:WaitForChild("ItemAssets")
	local livePlots = Workspace:FindFirstChild("Plots")
	local plotSpawns: Folder
	if livePlots and #livePlots:GetChildren() > 0 then
		local benchSpawns = Instance.new("Folder")
		benchSpawns.Name = "_BenchPlotSpawns"
		benchSpawns.Parent = tempPlots
		for i = 1, math.max(1, plotCount) do
			local sp = Instance.new("Part")
			sp.Name = string.format("Plot_%02d", i)
			sp.Anchored = true
			sp.CanCollide = false
			sp.CanTouch = false
			sp.CanQuery = false
			sp.Transparency = 1
			sp.Position = Vector3.new(5000 + (i - 1) * 160, 0, 0)
			sp.Parent = benchSpawns
		end
		plotSpawns = benchSpawns
	else
		plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
	end

	resetBenchServices()

	PlotService.Init({
		BaseTemplate = baseTemplate,
		PlotSpawnsFolder = plotSpawns,
		PlotsParent = tempPlots,
		PlotCount = plotCount,
	})
	SpawnService.Init()
	EngineInventoryService.Init()
	BoosterInventoryService.Init()
	WheelAutoConfigurationService.Init({ ItemAssetsRoot = assets })
	ConnectionService.Init({ ItemAssetsRoot = assets })
	VehicleBlueprintService.Init({ ItemAssetsRoot = assets })
	StandPreviewService.Init({ ItemAssetsRoot = assets })
	VehicleLaunchPreparationService.Init({ ItemAssetsRoot = assets })
	ItemRuntimeService.Init({ ItemAssetsRoot = assets })
	VehicleAssemblyService.Init({ ItemAssetsRoot = assets })
	VehicleWheelControllerService.Init()
	VehiclePowertrainService.Init()
	VehicleBoosterService.Init()
	VehicleDamageService.Init()
	VehicleImpactService.Init()
	VehicleRuntimeService.Init()
	VehicleLifecycleService.Init()
	VehicleLaunchService.Init()
	BuildService.Init()
end

local function placeWheeledVehicle(
	player: PlotService.PlayerLike,
	prefix: string,
	wheelCount: number
): number
	local numAxles = math.max(1, math.floor(wheelCount / 2))
	local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)
	local totalPlaced = 0

	local function mustPlace(suffix: string, itemId: string, localCF: CFrame)
		totalPlaced += 1
		local res = BuildService.ProcessRequest(player, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = `{prefix}_{suffix}_{totalPlaced}`,
			ItemId = itemId,
			LocalCFrame = localCF,
		})
		if not res.Success then
			error(`[BuildBenchmarks] Wheeled vehicle PlacePiece failed ({itemId}): {tostring(res.ErrorCode)} - {tostring(res.ErrorMessage)}`)
		end
	end

	-- Eje longitudinal de WoodBlocks de 2x2x2 para conectar todos los ejes con 0 huecos
	local zCoords: { number } = {}
	if numAxles == 1 then
		mustPlace("spine_f", "WoodBlock", CFrame.new(0, 1.5, -2))
		mustPlace("spine_c", "WoodBlock", CFrame.new(0, 1.5, 0))
		mustPlace("spine_r", "WoodBlock", CFrame.new(0, 1.5, 2))
		table.insert(zCoords, 0)
	else
		for i = 1, numAxles do
			local z = -4 + (i - 1) * 2
			mustPlace(`spine_{i}`, "WoodBlock", CFrame.new(0, 1.5, z))
			table.insert(zCoords, z)
		end
	end

	local seatZ = zCoords[math.max(1, math.floor((#zCoords + 1) / 2))]
	mustPlace("seat", "DriverSeat", CFrame.new(0, 3.0, seatZ))

	local wheelsPlaced = 0
	for i, z in ipairs(zCoords) do
		if wheelsPlaced < wheelCount then
			mustPlace(`wl_{i}`, "SmallWheel", CFrame.new(-1.5, 1.5, z))
			wheelsPlaced += 1
		end
		if wheelsPlaced < wheelCount then
			mustPlace(`wr_{i}`, "SmallWheel", CFrame.new(1.5, 1.5, z) * wheelFlip)
			wheelsPlaced += 1
		end
	end

	return totalPlaced
end

function BuildBenchmarks.MeasureSize(targetPieces: number): BenchmarkEntry
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = `BenchPlots_{targetPieces}`
	tempPlots.Parent = Workspace

	initBenchServices(tempPlots, 1)
	-- Usar reloj virtual para evitar límite de 25 ops/s durante la construcción del vehículo de benchmark
	local clockVal = 0
	BuildService._SetRateLimitClockForTests(function()
		clockVal += 1
		return clockVal
	end)
	VehicleLaunchService._SetClockForTests(function()
		return clockVal
	end)

	local benchPlayer: PlotService.PlayerLike = { UserId = 50000 + targetPieces, Name = `Bench_{targetPieces}` }
	local plot = PlotService.Assign(benchPlayer)
	if not plot then
		tempPlots:Destroy()
		error("[BuildBenchmarks] Failed to assign benchmark plot")
	end

	local plan = buildConnectedVehiclePlan(targetPieces)
	if #plan < targetPieces then
		tempPlots:Destroy()
		error(`[BuildBenchmarks] Plan generated only {#plan} steps for {targetPieces}`)
	end

	local heapBeforeKB = gcinfo()

	-- Colocar piezas 1..(targetPieces - 10) de preparación y medir ventana final de 10 piezas
	local warmupCount = math.max(1, targetPieces - 10)
	local lastPlaceMs = 0
	local windowSumMs = 0
	local windowCount = 0
	local lastPlacedId = ""

	for i, step in ipairs(plan) do
		local t0 = os.clock()
		local res = BuildService.ProcessRequest(benchPlayer, {
			Action = BuildProtocol.Actions.PlacePiece,
			ClientOpId = `bench_{targetPieces}_{i}`,
			ItemId = step.ItemId,
			LocalCFrame = step.LocalCFrame,
		})
		local dtMs = (os.clock() - t0) * 1000
		if not res.Success then
			tempPlots:Destroy()
			error(`[BuildBenchmarks] Placement failed at #{i} ({step.ItemId} at {tostring(step.LocalCFrame.Position)}): {tostring(res.ErrorCode)} - {tostring(res.ErrorMessage)}`)
		end
		lastPlacedId = (res.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId
		if i > warmupCount then
			windowSumMs += dtMs
			windowCount += 1
		end
		if i == targetPieces then
			lastPlaceMs = dtMs
		end
	end

	local heapAfterKB = gcinfo()
	local bp = VehicleBlueprintService.GetOrCreateBlueprint(benchPlayer)
	local firstPieceId = bp.Pieces[1].InstanceId

	-- 2. Medir ValidatePlacementConnections (promedio en 50 repeticiones con índice espacial activo)
	local probeCF = CFrame.new(10, 3.0, 10)
	local connRuns = 50
	local tConn0 = os.clock()
	for r = 1, connRuns do
		ConnectionService.ValidatePlacementConnections(
			`__probe_{r}`,
			"WoodBlock",
			probeCF,
			bp.Pieces,
			benchPlayer.UserId,
			bp.Revision,
			bp.Connections
		)
	end
	local validateConnectionsMs = ((os.clock() - tConn0) * 1000) / connRuns

	-- 3. Medir ComputeSmartSnap (cliente con specs preparados + SpatialIndex en N piezas)
	local existingSpecs = ConnectionService.BuildPieceGeometrySpecs(bp.Pieces)
	local clientSpatial = ConnectionMath.CreateSpatialIndex()
	for _, spec in ipairs(existingSpecs) do
		clientSpatial:Insert(spec)
	end
	local blockGeom = ConnectionService.GetItemGeometry("WoodBlock") :: ConnectionService.CachedItemGeometry
	local snapProbeCF = CFrame.new(10.4, 3.0, 9.8)
	local snapRuns = 50
	local tSnap0 = os.clock()
	for _ = 1, snapRuns do
		ConnectionMath.ComputeSmartSnap(
			snapProbeCF,
			blockGeom.Size,
			blockGeom.Attachments,
			existingSpecs,
			nil,
			0.0,
			clientSpatial
		)
	end
	local smartSnapMs = ((os.clock() - tSnap0) * 1000) / snapRuns

	-- 4. Medir validación de eliminación (hoja y nodo interior)
	local remRuns = 50
	local tLeaf0 = os.clock()
	for _ = 1, remRuns do
		ConnectionService.CanRemovePiece(bp, lastPlacedId)
	end
	local removeLeafValidateMs = ((os.clock() - tLeaf0) * 1000) / remRuns

	local tCycle0 = os.clock()
	for _ = 1, remRuns do
		ConnectionService.CanRemovePiece(bp, firstPieceId)
	end
	local removeCycleValidateMs = ((os.clock() - tCycle0) * 1000) / remRuns

	-- 5. Medir snapshot / sincronización de blueprint
	local snapBpRuns = 25
	local tSync0 = os.clock()
	for _ = 1, snapBpRuns do
		VehicleBlueprintService.GetBlueprintSnapshot(benchPlayer)
	end
	local snapshotSyncMs = ((os.clock() - tSync0) * 1000) / snapBpRuns

	-- 5b. Medir Fase 2.4: SaveBlueprint, StandOffsetUpdate, LoadBlueprint (rebuild), LaunchPrep
	local tSave0 = os.clock()
	local saveOk, savedBp = VehicleBlueprintService.SaveBlueprint(benchPlayer, plot, `BenchSave_{targetPieces}`, false)
	local saveBlueprintMs = (os.clock() - tSave0) * 1000
	local targetLoadId = if saveOk and savedBp then savedBp.BlueprintId else bp.BlueprintId

	local offsetRuns = 10
	local tStand0 = os.clock()
	for r = 1, offsetRuns do
		local h = (r % 4) * 0.5
		local lat = ((r % 3) - 1) * 1.0
		VehicleBlueprintService.SetStandOffset(benchPlayer, plot, h, lat)
	end
	local standOffsetUpdateMs = ((os.clock() - tStand0) * 1000) / offsetRuns

	local tLoad0 = os.clock()
	VehicleBlueprintService.LoadBlueprint(benchPlayer, plot, targetLoadId)
	local loadRebuildMs = (os.clock() - tLoad0) * 1000

	local prepRuns = 10
	local tPrep0 = os.clock()
	for _ = 1, prepRuns do
		VehicleLaunchPreparationService.EvaluatePlayerLaunch(benchPlayer, { SkipWorldObstructionCheck = true })
	end
	local launchPrepMs = ((os.clock() - tPrep0) * 1000) / prepRuns

	-- 5b. Colocar un DriverSeat sobre el chasis y medir Launch/Cleanup real de VehicleRuntime
	local runtimeLaunchMs = 0
	local runtimeCleanupMs = 0
	local runtimeParts = 0
	local runtimeJoints = 0

	local removedPos: Vector3? = nil
	if #bp.Pieces >= targetPieces and #bp.Pieces >= 2 then
		-- Reemplazar 1 pieza hoja del tope para mantener exact `targetPieces` con DriverSeat válido
		local leafPiece = bp.Pieces[#bp.Pieces]
		removedPos = leafPiece.LocalCFrame.Position
		BuildService.ProcessRequest(benchPlayer, {
			Action = "RemovePiece",
			ClientOpId = `bench_rm_leaf_{targetPieces}`,
			PieceInstanceId = leafPiece.InstanceId,
		})
	end
	local seatPos: Vector3
	if targetPieces <= 100 then
		seatPos = Vector3.new(-8, 2.5, -8)
	elseif targetPieces <= 200 then
		seatPos = Vector3.new(9, 3.5, 10)
	else
		local rp = removedPos or Vector3.new(-8, 9.0, 10)
		seatPos = Vector3.new(rp.X, rp.Y - 0.5, rp.Z)
	end
	BuildService.ProcessRequest(benchPlayer, {
		Action = "PlacePiece",
		ClientOpId = `bench_seat_{targetPieces}`,
		ItemId = "DriverSeat",
		LocalCFrame = CFrame.new(seatPos),
	})

	local launchRes = VehicleLaunchService.LaunchVehicle(benchPlayer, {
		SkipWorldObstructionCheck = true,
		MountDriver = false,
	})
	if launchRes.Success then
		-- Re-medición limpia
		clockVal += 5
		VehicleLaunchService.ReturnToWorkshop(benchPlayer)
		clockVal += 5
		local tRt0 = os.clock()
		local r2 = VehicleLaunchService.LaunchVehicle(benchPlayer, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
		})
		runtimeLaunchMs = (os.clock() - tRt0) * 1000
		if r2.Success then
			runtimeParts = r2.RuntimeStatus.PieceCount
			runtimeJoints = r2.RuntimeStatus.JointCount
		end
		local tClean0 = os.clock()
		VehicleLaunchService.ReturnToWorkshop(benchPlayer)
		runtimeCleanupMs = (os.clock() - tClean0) * 1000
	end

	-- 6. Contar instancias generadas y memoria
	local editableModel = VehicleBlueprintService.GetEditableVehicleModel(benchPlayer) :: Model
	local editableModels = #editableModel:GetChildren()
	local editableDescendants = #editableModel:GetDescendants()
	local totalStudioMemMB = Stats:GetTotalMemoryUsageMb()

	-- Limpieza limpia
	clientSpatial:Clear()
	resetBenchServices()
	tempPlots:Destroy()

	return {
		PieceCount = targetPieces,
		LastPlaceMs = lastPlaceMs,
		AvgPlaceWindowMs = if windowCount > 0 then windowSumMs / windowCount else lastPlaceMs,
		ValidateConnectionsMs = validateConnectionsMs,
		SmartSnapWithIndexMs = smartSnapMs,
		RemoveLeafValidateMs = removeLeafValidateMs,
		RemoveCycleValidateMs = removeCycleValidateMs,
		SnapshotSyncMs = snapshotSyncMs,
		SaveBlueprintMs = saveBlueprintMs,
		LoadRebuildMs = loadRebuildMs,
		StandOffsetUpdateMs = standOffsetUpdateMs,
		LaunchPrepMs = launchPrepMs,
		RuntimeLaunchMs = runtimeLaunchMs,
		RuntimeCleanupMs = runtimeCleanupMs,
		RuntimeParts = runtimeParts,
		RuntimeJoints = runtimeJoints,
		EditableModelCount = editableModels,
		EditableDescendantCount = editableDescendants,
		LuaHeapDeltaKB = heapAfterKB - heapBeforeKB,
		TotalStudioMemMB = totalStudioMemMB,
	}
end

function BuildBenchmarks.MeasureMultiPlayerLaunch(playerCounts: { number }?): { MultiPlayerLaunchBenchmarkEntry }
	local counts = playerCounts or { 1, 2, 5, 10 }
	local entries: { MultiPlayerLaunchBenchmarkEntry } = {}

	for _, n in ipairs(counts) do
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = `BenchMultiLaunch_{n}`
		tempPlots.Parent = Workspace

		initBenchServices(tempPlots, n)

		local clk = 100
		BuildService._SetRateLimitClockForTests(function()
			clk += 1
			return clk
		end)
		VehicleLaunchService._SetClockForTests(function()
			return clk
		end)

		local players: { any } = {}
		local plan = buildConnectedVehiclePlan(24)
		for i = 1, n do
			local p = { UserId = 9000 + i, Name = `BenchMulti_{i}` }
			players[i] = p
			PlotService.Assign(p)
			for idx, step in ipairs(plan) do
				BuildService.ProcessRequest(p, {
					Action = "PlacePiece",
					ClientOpId = `bm_{i}_{idx}`,
					ItemId = step.ItemId,
					LocalCFrame = step.LocalCFrame,
				})
			end
			BuildService.ProcessRequest(p, {
				Action = "PlacePiece",
				ClientOpId = `bm_{i}_seat`,
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(-8, 2.5, -8),
			})
		end

		local tLaunch0 = os.clock()
		for i = 1, n do
			VehicleLaunchService.LaunchVehicle(players[i], { SkipWorldObstructionCheck = true, MountDriver = false })
		end
		local totalLaunchMs = (os.clock() - tLaunch0) * 1000

		local memMB = Stats:GetTotalMemoryUsageMb()
		local tClean0 = os.clock()
		for i = 1, n do
			VehicleLaunchService.ReturnToWorkshop(players[i])
		end
		local totalCleanupMs = (os.clock() - tClean0) * 1000

		table.insert(entries, {
			PlayerCount = n,
			PiecesPerVehicle = 25,
			TotalLaunchMs = totalLaunchMs,
			AvgPerPlayerLaunchMs = totalLaunchMs / n,
			TotalCleanupMs = totalCleanupMs,
			TotalStudioMemMB = memMB,
		})

		resetBenchServices()
		tempPlots:Destroy()
	end

	return entries
end

function BuildBenchmarks.RunAll(sizes: { number }?): { BenchmarkEntry }
	local targetSizes = sizes or { 25, 50, 100, 250, 500 }
	local results: { BenchmarkEntry } = {}
	for _, size in ipairs(targetSizes) do
		table.insert(results, BuildBenchmarks.MeasureSize(size))
	end
	return results
end

function BuildBenchmarks.FormatReport(entries: { BenchmarkEntry }): string
	local lines = {
		"Pieces | PlaceLast(ms) | ConnVal(ms) | Snap(ms) | Save(ms) | LoadRebuild(ms) | LaunchPrep(ms) | RtLaunch(ms) | RtClean(ms) | RtJoints | Models | TotalMem(MB)",
	}
	for _, e in ipairs(entries) do
		table.insert(
			lines,
			string.format(
				"%6d | %13.3f | %11.3f | %8.3f | %8.3f | %15.3f | %14.3f | %12.3f | %11.3f | %8d | %6d | %12.2f",
				e.PieceCount,
				e.LastPlaceMs,
				e.ValidateConnectionsMs,
				e.SmartSnapWithIndexMs,
				e.SaveBlueprintMs,
				e.LoadRebuildMs,
				e.LaunchPrepMs,
				e.RuntimeLaunchMs,
				e.RuntimeCleanupMs,
				e.RuntimeJoints,
				e.EditableModelCount,
				e.TotalStudioMemMB
			)
		)
	end
	return table.concat(lines, "\n")
end

function BuildBenchmarks.FormatMultiPlayerReport(entries: { MultiPlayerLaunchBenchmarkEntry }): string
	local lines = {
		"Players | Pieces/Veh | TotalLaunch(ms) | AvgPerPlayer(ms) | TotalClean(ms) | TotalMem(MB)",
	}
	for _, e in ipairs(entries) do
		table.insert(
			lines,
			string.format(
				"%7d | %10d | %15.3f | %16.3f | %14.3f | %12.2f",
				e.PlayerCount,
				e.PiecesPerVehicle,
				e.TotalLaunchMs,
				e.AvgPerPlayerLaunchMs,
				e.TotalCleanupMs,
				e.TotalStudioMemMB
			)
		)
	end
	return table.concat(lines, "\n")
end

function BuildBenchmarks.MeasureWheelConfigurations(wheelCounts: { number }?): { WheelConfigBenchmarkEntry }
	local targets = wheelCounts or { 2, 4, 6, 8, 12 }
	local entries: { WheelConfigBenchmarkEntry } = {}

	for _, wheelCount in ipairs(targets) do
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = `BenchWheels_{wheelCount}`
		tempPlots.Parent = Workspace

		initBenchServices(tempPlots, 1)

		local clk = 200
		BuildService._SetRateLimitClockForTests(function()
			clk += 1
			return clk
		end)
		VehicleLaunchService._SetClockForTests(function()
			return clk
		end)

		local player = { UserId = 60000 + wheelCount, Name = `BenchWheel_{wheelCount}` }
		PlotService.Assign(player)
		local totalPieces = placeWheeledVehicle(player, `bw_{wheelCount}`, wheelCount)
		local bp = VehicleBlueprintService.GetOrCreateBlueprint(player)

		-- 1. Análisis geométrico Auto+Manual (promedio en 20 repeticiones)
		local analyzeRuns = 20
		local tAnalyze0 = os.clock()
		for _ = 1, analyzeRuns do
			WheelAutoConfigurationService.AnalyzeBlueprint(bp)
		end
		local analyzeMs = ((os.clock() - tAnalyze0) * 1000) / analyzeRuns

		-- 2. Lanzamiento completo (ensamblaje físico con Carrier+Pivot+Prismatic+Spring+Hinges)
		local tLaunch0 = os.clock()
		local launchRes = VehicleLaunchService.LaunchVehicle(player, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
		})
		local launchMs = (os.clock() - tLaunch0) * 1000
		if not launchRes.Success then
			resetBenchServices()
			tempPlots:Destroy()
			error(`[BuildBenchmarks] Wheel benchmark launch failed ({wheelCount} wheels): {tostring(launchRes.ErrorCode)} - {tostring(launchRes.ErrorMessage)}`)
		end

		local rt = VehicleRuntimeService.GetRuntimeByPlayer(player)
		local wheelConstraintsCount = if rt and rt.WheelConstraints then #rt.WheelConstraints else 0
		local runtimeJointsCount = if rt and rt.Joints then #rt.Joints else 0

		-- 3. Medir 60 frames del orquestador centralizado StepAll con dirección activa
		local frames = 60
		local tStep0 = os.clock()
		for f = 1, frames do
			VehicleWheelControllerService.SetSteerOverrideForTests(player, if f <= 30 then 1 else -1)
			VehicleWheelControllerService.StepAll(1 / 60)
		end
		VehicleWheelControllerService.SetSteerOverrideForTests(player, nil)
		local stepAvgMs = ((os.clock() - tStep0) * 1000) / frames

		local memMB = Stats:GetTotalMemoryUsageMb()
		local tClean0 = os.clock()
		VehicleLaunchService.ReturnToWorkshop(player)
		local cleanupMs = (os.clock() - tClean0) * 1000

		table.insert(entries, {
			WheelCount = wheelCount,
			TotalPieces = totalPieces,
			AnalyzeMs = analyzeMs,
			LaunchMs = launchMs,
			Step60FramesAvgMs = stepAvgMs,
			WheelConstraints = wheelConstraintsCount,
			RuntimeJoints = runtimeJointsCount,
			CleanupMs = cleanupMs,
			TotalStudioMemMB = memMB,
		})

		resetBenchServices()
		tempPlots:Destroy()
	end

	return entries
end

function BuildBenchmarks.MeasureWheelConcurrentPlayers(playerCounts: { number }?): { WheelMultiPlayerBenchmarkEntry }
	local counts = playerCounts or { 1, 2, 5, 10 }
	local entries: { WheelMultiPlayerBenchmarkEntry } = {}
	local wheelsPerVehicle = 4

	for _, n in ipairs(counts) do
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = `BenchWheelMulti_{n}`
		tempPlots.Parent = Workspace

		initBenchServices(tempPlots, n)

		local clk = 300
		BuildService._SetRateLimitClockForTests(function()
			clk += 1
			return clk
		end)
		VehicleLaunchService._SetClockForTests(function()
			return clk
		end)

		local players: { PlotService.PlayerLike } = {}
		for i = 1, n do
			local p: PlotService.PlayerLike = { UserId = 70000 + i, Name = `BenchWheelP_{i}` }
			players[i] = p
			PlotService.Assign(p)
			placeWheeledVehicle(p, `bwm_{n}_{i}`, wheelsPerVehicle)
		end

		local tLaunch0 = os.clock()
		for _, p in ipairs(players) do
			local r = VehicleLaunchService.LaunchVehicle(p, {
				SkipWorldObstructionCheck = true,
				MountDriver = false,
			})
			if not r.Success then
				resetBenchServices()
				tempPlots:Destroy()
				error(`[BuildBenchmarks] Concurrent wheel launch failed for {p.Name}: {tostring(r.ErrorCode)} - {tostring(r.ErrorMessage)}`)
			end
		end
		local totalLaunchMs = (os.clock() - tLaunch0) * 1000

		local frames = 60
		local tStep0 = os.clock()
		for f = 1, frames do
			local steerDir = if f <= 30 then 1 else -1
			for idx, p in ipairs(players) do
				VehicleWheelControllerService.SetSteerOverrideForTests(p, if idx % 2 == 0 then steerDir else -steerDir)
			end
			VehicleWheelControllerService.StepAll(1 / 60)
		end
		local centralStepAvgMs = ((os.clock() - tStep0) * 1000) / frames

		local memMB = Stats:GetTotalMemoryUsageMb()
		local tClean0 = os.clock()
		for _, p in ipairs(players) do
			VehicleLaunchService.ReturnToWorkshop(p)
		end
		local totalCleanupMs = (os.clock() - tClean0) * 1000

		table.insert(entries, {
			PlayerCount = n,
			WheelsPerVehicle = wheelsPerVehicle,
			TotalWheels = n * wheelsPerVehicle,
			TotalLaunchMs = totalLaunchMs,
			AvgPerPlayerLaunchMs = totalLaunchMs / n,
			CentralStep60FramesAvgMs = centralStepAvgMs,
			TotalCleanupMs = totalCleanupMs,
			TotalStudioMemMB = memMB,
		})

		resetBenchServices()
		tempPlots:Destroy()
	end

	return entries
end

function BuildBenchmarks.FormatWheelReport(entries: { WheelConfigBenchmarkEntry }): string
	local lines = {
		"Wheels | Pieces | Analyze(ms) | Launch(ms) | StepAvg(ms) | WConstraints | RtJoints | Clean(ms) | TotalMem(MB)",
	}
	for _, e in ipairs(entries) do
		table.insert(
			lines,
			string.format(
				"%6d | %6d | %11.3f | %10.3f | %11.4f | %12d | %8d | %9.3f | %12.2f",
				e.WheelCount,
				e.TotalPieces,
				e.AnalyzeMs,
				e.LaunchMs,
				e.Step60FramesAvgMs,
				e.WheelConstraints,
				e.RuntimeJoints,
				e.CleanupMs,
				e.TotalStudioMemMB
			)
		)
	end
	return table.concat(lines, "\n")
end

function BuildBenchmarks.FormatWheelMultiPlayerReport(entries: { WheelMultiPlayerBenchmarkEntry }): string
	local lines = {
		"Players | TotalWheels | TotalLaunch(ms) | AvgPerPlayer(ms) | CentralStepAvg(ms) | TotalClean(ms) | TotalMem(MB)",
	}
	for _, e in ipairs(entries) do
		table.insert(
			lines,
			string.format(
				"%7d | %11d | %15.3f | %16.3f | %18.4f | %14.3f | %12.2f",
				e.PlayerCount,
				e.TotalWheels,
				e.TotalLaunchMs,
				e.AvgPerPlayerLaunchMs,
				e.CentralStep60FramesAvgMs,
				e.TotalCleanupMs,
				e.TotalStudioMemMB
			)
		)
	end
	return table.concat(lines, "\n")
end

export type PowertrainBenchmarkReport = {
	VariantRarityResolutionAvgUs: number,
	PowertrainCreationSingleMs: number,
	SingleEngine4WheelsStepAvgMs: number,
	MultiEngine3Engines6WheelsStepAvgMs: number,
	TenVehiclesConcurrentLaunchMs: number,
	TenVehiclesConcurrentStepAvgMs: number,
	TenVehiclesTotalConstraints: number,
	TenVehiclesCleanupMs: number,
	LuaHeapDeltaKB: number,
	TotalStudioMemMB: number,
	ActiveRuntimesAfterCleanup: number,
}

function BuildBenchmarks.RunPowertrainBenchmarks(): PowertrainBenchmarkReport
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
	local assets = ServerStorage:WaitForChild("ItemAssets")

	-- 1) Benchmark de resolución determinística de variantes/rarezas (90 combinaciones x 10 iteraciones = 900 resoluciones)
	local sizes = EngineCatalog.GetOrderedSizeIds()
	local variants = EngineCatalog.GetOrderedVariantIds()
	local rarities = EngineCatalog.GetOrderedRarityIds()
	local tRes0 = os.clock()
	local resCount = 0
	for _ = 1, 10 do
		for _, sz in ipairs(sizes) do
			for _, varId in ipairs(variants) do
				for _, rarId in ipairs(rarities) do
					local st = EngineCatalog.ResolveEffectiveStats({
						EngineSizeId = sz,
						VariantId = varId,
						RarityId = rarId,
					})
					EngineCatalog.EvaluateTorqueAtRPM(st, st.OptimumRPM, false)
					resCount += 1
				end
			end
		end
	end
	local resolutionAvgUs = ((os.clock() - tRes0) * 1e6) / math.max(1, resCount)

	-- 2) Preparar entorno de 10 estaciones para pruebas físicas de tren motriz
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_BenchPlotsPowertrain"
	tempPlots.Parent = Workspace

	resetBenchServices()
	VehiclePowertrainService._ResetForTests()
	EngineInventoryService.ResetAllForTests()

	PlotService.Init({
		BaseTemplate = baseTemplate,
		PlotSpawnsFolder = plotSpawns,
		PlotsParent = tempPlots,
		PlotCount = 10,
	})
	SpawnService.Init()
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

	local clk = 2000
	BuildService._SetRateLimitClockForTests(function()
		clk += 1
		return clk
	end)
	VehicleLaunchService._SetClockForTests(function()
		return clk
	end)

	local heapBeforeKB = collectgarbage("count")

	local function buildMotorBenchKart(player: PlotService.PlayerLike, prefix: string, numEngines: number, numWheels: number)
		local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)
		local axlePairs = math.max(2, math.floor(numWheels / 2))
		for i = 0, axlePairs do
			BuildService.ProcessRequest(player, {
				Action = "PlacePiece",
				ClientOpId = `{prefix}_b_{i}`,
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 2.5, (i - 1) * 2),
			})
		end
		BuildService.ProcessRequest(player, {
			Action = "PlacePiece",
			ClientOpId = `{prefix}_seat`,
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(0, 4.0, -2),
		})
		for e = 1, numEngines do
			local unit = EngineInventoryService.RegisterUnitForTesting(player, {
				ItemInstanceId = `{prefix}_u_{e}`,
				EngineSizeId = if e % 2 == 0 then "Medium" else "Small",
				VariantId = variants[((e - 1) % #variants) + 1],
				RarityId = rarities[((e - 1) % #rarities) + 1],
			})
			BuildService.ProcessRequest(player, {
				Action = "PlacePiece",
				ClientOpId = `{prefix}_eng_{e}`,
				ItemId = "SmallEngine",
				LocalCFrame = CFrame.new(0, 4.5 + (e - 1) * 2, 2),
				InventoryInstanceId = unit.ItemInstanceId,
			})
		end
		for pairIdx = 1, axlePairs do
			local zPos = (pairIdx - 1) * 2 - 2
			BuildService.ProcessRequest(player, {
				Action = "PlacePiece",
				ClientOpId = `{prefix}_wl_{pairIdx}`,
				ItemId = "SmallWheel",
				LocalCFrame = CFrame.new(-1.5, 2.5, zPos),
			})
			BuildService.ProcessRequest(player, {
				Action = "PlacePiece",
				ClientOpId = `{prefix}_wr_{pairIdx}`,
				ItemId = "SmallWheel",
				LocalCFrame = CFrame.new(1.5, 2.5, zPos) * wheelFlip,
			})
		end
	end

	-- 2A) Medir creación y paso de 1 vehículo (1 motor, 4 ruedas)
	local p1: PlotService.PlayerLike = { UserId = 81001, Name = "BenchPT_1" }
	PlotService.Assign(p1)
	buildMotorBenchKart(p1, "bpt1", 1, 4)

	local tCreate0 = os.clock()
	local lr1 = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SkipWorldObstructionCheck = true })
	local createSingleMs = (os.clock() - tCreate0) * 1000
	assert(lr1.Success, "BenchPT_1 launch failed")

	VehiclePowertrainService.SetControlOverrideForTests(p1, { Throttle = 1.0, Steer = 0.3 })
	local tStepSingle0 = os.clock()
	for _ = 1, 120 do
		VehiclePowertrainService.StepAll(1 / 60)
		VehicleWheelControllerService.StepAll(1 / 60)
	end
	local singleStepAvgMs = ((os.clock() - tStepSingle0) * 1000) / 120
	VehicleLaunchService.ReturnToWorkshop(p1)
	PlotService.Release(p1)

	-- 2B) Medir paso de 1 vehículo multimotor/multirueda (3 motores, 6 ruedas)
	local pMulti: PlotService.PlayerLike = { UserId = 81002, Name = "BenchPT_Multi" }
	PlotService.Assign(pMulti)
	buildMotorBenchKart(pMulti, "bptm", 3, 6)
	local lrM = VehicleLaunchService.LaunchVehicle(pMulti, { MountDriver = false, SkipWorldObstructionCheck = true })
	assert(lrM.Success, "BenchPT_Multi launch failed")

	VehiclePowertrainService.SetControlOverrideForTests(pMulti, { Throttle = 1.0, Steer = -0.5 })
	local tStepMulti0 = os.clock()
	for _ = 1, 120 do
		VehiclePowertrainService.StepAll(1 / 60)
		VehicleWheelControllerService.StepAll(1 / 60)
	end
	local multiStepAvgMs = ((os.clock() - tStepMulti0) * 1000) / 120
	VehicleLaunchService.ReturnToWorkshop(pMulti)
	PlotService.Release(pMulti)

	-- 2C) Medir 10 jugadores simultáneos (cada uno con 2 motores y 4 ruedas)
	local players10: { PlotService.PlayerLike } = {}
	for i = 1, 10 do
		local p: PlotService.PlayerLike = { UserId = 82000 + i, Name = `BenchPT10_{i}` }
		players10[i] = p
		PlotService.Assign(p)
		buildMotorBenchKart(p, `bpt10_{i}`, 2, 4)
	end

	local tLaunch10 = os.clock()
	local totalConstraints10 = 0
	for _, p in ipairs(players10) do
		local lr = VehicleLaunchService.LaunchVehicle(p, { MountDriver = false, SkipWorldObstructionCheck = true })
		assert(lr.Success and lr.Runtime ~= nil, "10-player launch failed")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		totalConstraints10 += #(rt.Joints or {}) + #(rt.WheelConstraints or {})
		VehiclePowertrainService.SetControlOverrideForTests(p, { Throttle = 0.9, Steer = 0.25 })
	end
	local launch10Ms = (os.clock() - tLaunch10) * 1000

	local tStep10 = os.clock()
	for _ = 1, 120 do
		VehiclePowertrainService.StepAll(1 / 60)
		VehicleWheelControllerService.StepAll(1 / 60)
	end
	local step10AvgMs = ((os.clock() - tStep10) * 1000) / 120

	local heapAfterKB = collectgarbage("count")
	local memMB = Stats:GetTotalMemoryUsageMb()

	local tClean10 = os.clock()
	for _, p in ipairs(players10) do
		VehicleLaunchService.ReturnToWorkshop(p)
		PlotService.Release(p)
		EngineInventoryService.ClearForPlayer(p)
	end
	local clean10Ms = (os.clock() - tClean10) * 1000
	local remainingRuntimes = VehicleRuntimeService.GetActiveRuntimeCount()

	resetBenchServices()
	VehiclePowertrainService._ResetForTests()
	EngineInventoryService.ResetAllForTests()
	tempPlots:Destroy()

	return {
		VariantRarityResolutionAvgUs = resolutionAvgUs,
		PowertrainCreationSingleMs = createSingleMs,
		SingleEngine4WheelsStepAvgMs = singleStepAvgMs,
		MultiEngine3Engines6WheelsStepAvgMs = multiStepAvgMs,
		TenVehiclesConcurrentLaunchMs = launch10Ms,
		TenVehiclesConcurrentStepAvgMs = step10AvgMs,
		TenVehiclesTotalConstraints = totalConstraints10,
		TenVehiclesCleanupMs = clean10Ms,
		LuaHeapDeltaKB = math.max(0, heapAfterKB - heapBeforeKB),
		TotalStudioMemMB = memMB,
		ActiveRuntimesAfterCleanup = remainingRuntimes,
	}
end

export type BoosterBenchmarkReport = {
	CatalogResolutionAvgUs: number,
	BoosterVehicleLaunchMs: number,
	SingleVehicle2BoostersStepAvgMs: number,
	TenVehiclesConcurrentLaunchMs: number,
	TenVehiclesConcurrentStepAvgMs: number,
	TenVehiclesTotalConstraints: number,
	TenVehiclesCleanupMs: number,
	LuaHeapDeltaKB: number,
	TotalStudioMemMB: number,
	ActiveRuntimesAfterCleanup: number,
}

function BuildBenchmarks.RunBoosterBenchmarks(): BoosterBenchmarkReport
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
	local assets = ServerStorage:WaitForChild("ItemAssets")

	local families = BoosterCatalog.GetOrderedFamilyIds()
	local sizes = BoosterCatalog.GetOrderedSizeIds()
	local variants = BoosterCatalog.GetOrderedVariantIds()
	local rarities = BoosterCatalog.GetOrderedRarityIds()
	local tRes0 = os.clock()
	local resCount = 0
	for _ = 1, 5 do
		for _, famId in ipairs(families) do
			for _, szId in ipairs(sizes) do
				for _, varId in ipairs(variants) do
					for _, rarId in ipairs(rarities) do
						BoosterCatalog.ResolveEffectiveStats({
							BoosterFamilyId = famId,
							BoosterSizeId = szId,
							VariantId = varId,
							RarityId = rarId,
						})
						resCount += 1
					end
				end
			end
		end
	end
	local resolutionAvgUs = ((os.clock() - tRes0) * 1e6) / math.max(1, resCount)

	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_BenchPlotsBoosters"
	tempPlots.Parent = Workspace

	resetBenchServices()
	PlotService.Init({
		BaseTemplate = baseTemplate,
		PlotSpawnsFolder = plotSpawns,
		PlotsParent = tempPlots,
		PlotCount = 10,
	})
	SpawnService.Init()
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

	local clk = 5000
	BuildService._SetRateLimitClockForTests(function()
		clk += 1
		return clk
	end)
	VehicleLaunchService._SetClockForTests(function()
		return clk
	end)

	local heapBeforeKB = collectgarbage("count")
	local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)

	local function buildBoosterBenchCar(player: PlotService.PlayerLike, prefix: string)
		for z = -1, 3 do
			BuildService.ProcessRequest(player, {
				Action = "PlacePiece",
				ClientOpId = `{prefix}_b_{z}`,
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 2.5, z * 2),
			})
		end
		BuildService.ProcessRequest(player, {
			Action = "PlacePiece",
			ClientOpId = `{prefix}_xl`,
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(-2, 2.5, 2),
		})
		BuildService.ProcessRequest(player, {
			Action = "PlacePiece",
			ClientOpId = `{prefix}_xr`,
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 2.5, 2),
		})
		BuildService.ProcessRequest(player, {
			Action = "PlacePiece",
			ClientOpId = `{prefix}_seat`,
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(0, 4.0, -2),
		})
		BuildService.ProcessRequest(player, {
			Action = "PlacePiece",
			ClientOpId = `{prefix}_nit`,
			ItemId = "SmallNitroTank",
			LocalCFrame = CFrame.new(0, 4.5, 5.5),
		})
		for bi, xPos in ipairs({ -2, 2 }) do
			local u = BoosterInventoryService.RegisterUnitForTesting(player, {
				ItemInstanceId = `{prefix}_bu_{bi}`,
				BoosterFamilyId = families[((bi - 1) % #families) + 1],
				BoosterSizeId = if bi == 2 then "Medium" else "Small",
				VariantId = variants[((bi - 1) % #variants) + 1],
				RarityId = rarities[((bi - 1) % #rarities) + 1],
			})
			BuildService.ProcessRequest(player, {
				Action = "PlacePiece",
				ClientOpId = `{prefix}_bst_{bi}`,
				ItemId = "SmallBooster",
				LocalCFrame = CFrame.new(xPos, 2.5, 4.5),
				InventoryInstanceId = u.ItemInstanceId,
			})
		end
		for pairIdx = 1, 2 do
			local zPos = (pairIdx - 1) * 4 - 2
			BuildService.ProcessRequest(player, {
				Action = "PlacePiece",
				ClientOpId = `{prefix}_wl_{pairIdx}`,
				ItemId = "SmallWheel",
				LocalCFrame = CFrame.new(-1.5, 2.5, zPos),
				Config = { Wheel = { IsDriven = false } },
			})
			BuildService.ProcessRequest(player, {
				Action = "PlacePiece",
				ClientOpId = `{prefix}_wr_{pairIdx}`,
				ItemId = "SmallWheel",
				LocalCFrame = CFrame.new(1.5, 2.5, zPos) * wheelFlip,
				Config = { Wheel = { IsDriven = false } },
			})
		end
	end

	-- 1) 1 vehículo con 2 propulsores + SmallNitroTank
	local p1: PlotService.PlayerLike = { UserId = 83001, Name = "BenchBst_1" }
	PlotService.Assign(p1)
	buildBoosterBenchCar(p1, "bb1")
	local tCreate0 = os.clock()
	local lr1 = VehicleLaunchService.LaunchVehicle(p1, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
	local createSingleMs = (os.clock() - tCreate0) * 1000
	assert(lr1.Success, "BenchBst_1 launch failed")

	VehicleBoosterService.SetBoostOverrideForTests(p1, true)
	local tStep1 = os.clock()
	for _ = 1, 120 do
		VehicleBoosterService.StepAll(1 / 60)
	end
	local singleStepAvgMs = ((os.clock() - tStep1) * 1000) / 120
	VehicleLaunchService.ReturnToWorkshop(p1)
	PlotService.Release(p1)

	-- 2) 10 jugadores simultáneos con 2 propulsores + 1 tanque Nitro cada uno
	local players10: { PlotService.PlayerLike } = {}
	for i = 1, 10 do
		local p: PlotService.PlayerLike = { UserId = 84000 + i, Name = `BenchBst10_{i}` }
		players10[i] = p
		PlotService.Assign(p)
		buildBoosterBenchCar(p, `bb10_{i}`)
	end

	local tLaunch10 = os.clock()
	local totalConstraints10 = 0
	for _, p in ipairs(players10) do
		local lr = VehicleLaunchService.LaunchVehicle(p, { MountDriver = false, SimulateSeated = true, SkipWorldObstructionCheck = true })
		assert(lr.Success and lr.Runtime ~= nil, "10-player booster launch failed")
		local rt = lr.Runtime :: VehicleTypes.VehicleRuntime
		totalConstraints10 += #(rt.Joints or {}) + #(rt.WheelConstraints or {})
		VehicleBoosterService.SetBoostOverrideForTests(p, true)
	end
	local launch10Ms = (os.clock() - tLaunch10) * 1000

	local tStep10 = os.clock()
	for _ = 1, 120 do
		VehiclePowertrainService.StepAll(1 / 60)
		VehicleBoosterService.StepAll(1 / 60)
		VehicleWheelControllerService.StepAll(1 / 60)
	end
	local step10AvgMs = ((os.clock() - tStep10) * 1000) / 120

	local heapAfterKB = collectgarbage("count")
	local memMB = Stats:GetTotalMemoryUsageMb()

	local tClean10 = os.clock()
	for _, p in ipairs(players10) do
		VehicleLaunchService.ReturnToWorkshop(p)
		PlotService.Release(p)
		BoosterInventoryService.ClearForPlayer(p)
	end
	local clean10Ms = (os.clock() - tClean10) * 1000
	local remainingRuntimes = VehicleRuntimeService.GetActiveRuntimeCount()

	resetBenchServices()
	tempPlots:Destroy()

	return {
		CatalogResolutionAvgUs = resolutionAvgUs,
		BoosterVehicleLaunchMs = createSingleMs,
		SingleVehicle2BoostersStepAvgMs = singleStepAvgMs,
		TenVehiclesConcurrentLaunchMs = launch10Ms,
		TenVehiclesConcurrentStepAvgMs = step10AvgMs,
		TenVehiclesTotalConstraints = totalConstraints10,
		TenVehiclesCleanupMs = clean10Ms,
		LuaHeapDeltaKB = math.max(0, heapAfterKB - heapBeforeKB),
		TotalStudioMemMB = memMB,
		ActiveRuntimesAfterCleanup = remainingRuntimes,
	}
end

--[=[
	Benchmark dedicado de Fase 4.1:
	- Inicialización, evaluación de impacto, cálculo de daño, telemetría y cleanup en 100 / 250 / 500 piezas
	- Escenario simultáneo de 10 jugadores con impactos y verificación estricta de 0 conexiones residuales.
]=]
function BuildBenchmarks.MeasurePhase41DamageBenchmarks(sizes: { number }?): Phase41BenchmarkSuiteResult
	local targetSizes = sizes or { 100, 250, 500 }
	local sizeEntries: { Phase41SizeBenchmarkEntry } = {}

	for _, targetPieces in ipairs(targetSizes) do
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = `BenchP41_{targetPieces}`
		tempPlots.Parent = Workspace

		initBenchServices(tempPlots, 1)

		local clk = 1000
		BuildService._SetRateLimitClockForTests(function()
			clk += 1
			return clk
		end)
		VehicleLaunchService._SetClockForTests(function()
			return clk
		end)
		VehicleDamageService._SetClockForTests(function()
			return clk
		end)
		VehicleImpactService._SetClockForTests(function()
			return clk
		end)

		local benchPlayer: PlotService.PlayerLike = { UserId = 94100 + targetPieces, Name = `BenchP41_{targetPieces}` }
		local plot = PlotService.Assign(benchPlayer)
		assert(plot ~= nil, "[BuildBenchmarks] MeasurePhase41DamageBenchmarks failed to assign plot")

		local plan = buildConnectedVehiclePlan(targetPieces)
		assert(#plan >= targetPieces, `[BuildBenchmarks] Insufficient plan length ({#plan}) for {targetPieces}`)

		local removedPos: Vector3? = nil
		for i, step in ipairs(plan) do
			local res = BuildService.ProcessRequest(benchPlayer, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = `p41_{targetPieces}_{i}`,
				ItemId = step.ItemId,
				LocalCFrame = step.LocalCFrame,
			})
			assert(res.Success, `[BuildBenchmarks] P41 PlacePiece failed at #{i}: {tostring(res.ErrorCode)} - {tostring(res.ErrorMessage)}`)
			if i == targetPieces then
				removedPos = step.LocalCFrame.Position
			end
		end

		local bp = VehicleBlueprintService.GetOrCreateBlueprint(benchPlayer)
		if #bp.Pieces >= targetPieces then
			local leafPiece = bp.Pieces[#bp.Pieces]
			removedPos = leafPiece.LocalCFrame.Position
			local rmRes = BuildService.ProcessRequest(benchPlayer, {
				Action = "RemovePiece",
				ClientOpId = `p41_rm_leaf_{targetPieces}`,
				PieceInstanceId = leafPiece.InstanceId,
			})
			assert(rmRes.Success, "[BuildBenchmarks] P41 RemovePiece leaf failed")
		end

		local seatPos: Vector3
		if targetPieces <= 100 then
			seatPos = Vector3.new(-8, 2.5, -8)
		elseif targetPieces <= 200 then
			seatPos = Vector3.new(9, 3.5, 10)
		else
			local rp = removedPos or Vector3.new(-8, 9.0, 10)
			seatPos = Vector3.new(rp.X, rp.Y - 0.5, rp.Z)
		end
		local seatRes = BuildService.ProcessRequest(benchPlayer, {
			Action = "PlacePiece",
			ClientOpId = `p41_seat_{targetPieces}`,
			ItemId = "DriverSeat",
			LocalCFrame = CFrame.new(seatPos),
		})
		assert(seatRes.Success, `[BuildBenchmarks] P41 DriverSeat failed: {tostring(seatRes.ErrorCode)} - {tostring(seatRes.ErrorMessage)}`)

		local heapBeforeKB = collectgarbage("count")
		local tLaunch0 = os.clock()
		local launchRes = VehicleLaunchService.LaunchVehicle(benchPlayer, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
		})
		local launchMs = (os.clock() - tLaunch0) * 1000
		assert(launchRes.Success and launchRes.Runtime ~= nil, `[BuildBenchmarks] P41 launch failed: {tostring(launchRes.ErrorCode)}`)
		local runtime = launchRes.Runtime :: VehicleTypes.VehicleRuntime

		local trackedConnections = VehicleImpactService.GetTrackedConnectionCount()
		local trackedParts = VehicleImpactService.GetActivePartIndexCount()

		local sortedPieceIds: { string } = {}
		for pieceId in pairs(runtime.Parts) do
			table.insert(sortedPieceIds, pieceId)
		end
		table.sort(sortedPieceIds)

		local sampleIds: { string } = {}
		local sampleStep = math.max(1, math.floor(#sortedPieceIds / 20))
		for idx = 1, #sortedPieceIds, sampleStep do
			table.insert(sampleIds, sortedPieceIds[idx])
		end

		local impactIterations = 100
		local tImpact0 = os.clock()
		for i = 1, impactIterations do
			local pid = sampleIds[((i - 1) % #sampleIds) + 1]
			clk += 1
			VehicleImpactService.EvaluateImpact(runtime, {
				PieceId = pid,
				SourceType = "StaticObstacle",
				OtherName = `BenchWall_{i}`,
				OtherTargetKey = `BenchWall_{i}`,
				OtherIsStatic = true,
				RelativeVelocity = Vector3.new(0, 0, 45),
				ImpactNormal = Vector3.new(0, 0, 1),
				Timestamp = clk,
				BypassGracePeriod = true,
			})
		end
		local impactEvalAvgUs = (((os.clock() - tImpact0) * 1000000) / impactIterations)

		local applyIterations = 100
		local tApply0 = os.clock()
		for i = 1, applyIterations do
			local pid = sampleIds[((i - 1) % #sampleIds) + 1]
			clk += 1
			VehicleDamageService.ApplyImpact(runtime, pid, {
				SourceType = "API",
				DamageAmount = 5,
				Timestamp = clk,
			})
		end
		local applyImpactAvgUs = (((os.clock() - tApply0) * 1000000) / applyIterations)

		local queryIterations = 200
		local tQuery0 = os.clock()
		for _ = 1, queryIterations do
			VehicleDamageService.GetVehicleHealthSummary(runtime)
		end
		local summaryQueryAvgUs = (((os.clock() - tQuery0) * 1000000) / queryIterations)

		local heapAfterKB = collectgarbage("count")
		local totalMemMB = Stats:GetTotalMemoryUsageMb()

		local tClean0 = os.clock()
		local retRes = VehicleLaunchService.ReturnToWorkshop(benchPlayer)
		local cleanupMs = (os.clock() - tClean0) * 1000
		assert(retRes.Success, "[BuildBenchmarks] P41 ReturnToWorkshop failed")

		table.insert(sizeEntries, {
			PieceCount = #sortedPieceIds,
			LaunchMs = launchMs,
			TrackedConnections = trackedConnections,
			TrackedParts = trackedParts,
			ImpactEvalAvgUs = impactEvalAvgUs,
			ApplyImpactAvgUs = applyImpactAvgUs,
			SummaryQueryAvgUs = summaryQueryAvgUs,
			CleanupMs = cleanupMs,
			LuaHeapDeltaKB = math.max(0, heapAfterKB - heapBeforeKB),
			TotalStudioMemMB = totalMemMB,
			RemainingConnectionsAfterCleanup = VehicleImpactService.GetTrackedConnectionCount(),
			RemainingDamageRuntimesAfterCleanup = VehicleDamageService.GetRegisteredRuntimeCount(),
			RemainingImpactVehiclesAfterCleanup = VehicleImpactService.GetActiveVehicleCount(),
		})

		resetBenchServices()
		tempPlots:Destroy()
	end

	-- Escenario simultáneo: 10 jugadores con vehículos híbridos completos (ruedas, motor, tanque, booster, nitro, asiento)
	local tempPlots10 = Instance.new("Folder")
	tempPlots10.Name = "BenchP41_10Players"
	tempPlots10.Parent = Workspace
	initBenchServices(tempPlots10, 10)

	local clk10 = 5000
	BuildService._SetRateLimitClockForTests(function()
		clk10 += 1
		return clk10
	end)
	VehicleLaunchService._SetClockForTests(function()
		return clk10
	end)
	VehicleDamageService._SetClockForTests(function()
		return clk10
	end)
	VehicleImpactService._SetClockForTests(function()
		return clk10
	end)

	local wheelFlip = BuildRotation.RotateY(BuildRotation.Identity(), 2)
	local function buildFullVehicle(player: PlotService.PlayerLike, prefix: string): number
		local placed = 0
		local function put(suffix: string, itemId: string, cf: CFrame, cfg: { [string]: any }?)
			placed += 1
			local res = BuildService.ProcessRequest(player, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = `{prefix}_{suffix}`,
				ItemId = itemId,
				LocalCFrame = cf,
				Config = cfg,
			})
			assert(res.Success, `[BuildBenchmarks] P41 10P PlacePiece failed ({itemId}): {tostring(res.ErrorCode)} - {tostring(res.ErrorMessage)}`)
		end

		for z = -2, 8, 2 do
			put(`c_{z}`, "WoodBlock", CFrame.new(0, 2.5, z))
		end
		put("seat", "DriverSeat", CFrame.new(0, 4.0, -2))
		put("eng", "SmallEngine", CFrame.new(0, 4.5, 2))
		put("fuel", "RegularFuelTank", CFrame.new(0, 4.5, 5))
		put("nitro", "SmallNitroTank", CFrame.new(0, 4.5, 8))
		put("bst", "SmallBooster", CFrame.new(0, 2.5, 10.5))
		put("wlf", "SmallWheel", CFrame.new(-1.5, 2.5, -2), { Wheel = { IsDriven = true } })
		put("wrf", "SmallWheel", CFrame.new(1.5, 2.5, -2) * wheelFlip, { Wheel = { IsDriven = true } })
		put("wlr", "SmallWheel", CFrame.new(-1.5, 2.5, 6), { Wheel = { IsDriven = true } })
		put("wrr", "SmallWheel", CFrame.new(1.5, 2.5, 6) * wheelFlip, { Wheel = { IsDriven = true } })
		return placed
	end

	local players10: { PlotService.PlayerLike } = {}
	local piecesPerVeh = 0
	for i = 1, 10 do
		local p: PlotService.PlayerLike = { UserId = 95100 + i, Name = `BenchP41_10P_{i}` }
		players10[i] = p
		PlotService.Assign(p)
		piecesPerVeh = buildFullVehicle(p, `p41_10p_{i}`)
	end

	local runtimes10: { VehicleTypes.VehicleRuntime } = {}
	local tLaunch10 = os.clock()
	for i, p in ipairs(players10) do
		local lr = VehicleLaunchService.LaunchVehicle(p, {
			SkipWorldObstructionCheck = true,
			MountDriver = false,
			SimulateSeated = true,
		})
		assert(lr.Success and lr.Runtime ~= nil, `[BuildBenchmarks] 10P launch failed for {p.Name}`)
		runtimes10[i] = lr.Runtime :: VehicleTypes.VehicleRuntime
	end
	local totalLaunch10Ms = (os.clock() - tLaunch10) * 1000
	local peakTrackedConnections = VehicleImpactService.GetTrackedConnectionCount()

	local pieceIds10: { { string } } = {}
	for i, rt in ipairs(runtimes10) do
		local ids: { string } = {}
		for pieceId in pairs(rt.Parts) do
			table.insert(ids, pieceId)
		end
		table.sort(ids)
		pieceIds10[i] = ids
	end

	local tImpact10 = os.clock()
	local totalEval10 = 0
	for round = 1, 10 do
		for i, rt in ipairs(runtimes10) do
			local ids = pieceIds10[i]
			local targetPieceId = ids[((round - 1) % #ids) + 1]
			clk10 += 1
			VehicleImpactService.EvaluateImpact(rt, {
				PieceId = targetPieceId,
				SourceType = "StaticObstacle",
				OtherName = `MultiBarrier_{i}_{round}`,
				OtherTargetKey = `MultiBarrier_{i}_{round}`,
				OtherIsStatic = true,
				RelativeVelocity = Vector3.new(0, 0, 50),
				ImpactNormal = Vector3.new(0, 0, 1),
				Timestamp = clk10,
				BypassGracePeriod = true,
			})
			totalEval10 += 1
		end
	end
	local batchImpactTotalMs = (os.clock() - tImpact10) * 1000
	local mem10MB = Stats:GetTotalMemoryUsageMb()

	local tClean10 = os.clock()
	for _, p in ipairs(players10) do
		VehicleLaunchService.ReturnToWorkshop(p)
		PlotService.Release(p)
	end
	local clean10Ms = (os.clock() - tClean10) * 1000

	local remConn = VehicleImpactService.GetTrackedConnectionCount()
	local remDmg = VehicleDamageService.GetRegisteredRuntimeCount()
	local remImp = VehicleImpactService.GetActiveVehicleCount()
	local remRt = VehicleRuntimeService.GetActiveRuntimeCount()

	resetBenchServices()
	tempPlots10:Destroy()

	return {
		SingleVehicleSizes = sizeEntries,
		TenPlayersConcurrent = {
			PlayerCount = 10,
			PiecesPerVehicle = piecesPerVeh,
			TotalLaunchMs = totalLaunch10Ms,
			BatchImpactTotalMs = batchImpactTotalMs,
			AvgImpactPerVehicleUs = (batchImpactTotalMs * 1000) / math.max(1, totalEval10),
			PeakTrackedConnections = peakTrackedConnections,
			TotalCleanupMs = clean10Ms,
			TotalStudioMemMB = mem10MB,
			RemainingConnectionsAfterCleanup = remConn,
			RemainingDamageRuntimesAfterCleanup = remDmg,
			RemainingImpactVehiclesAfterCleanup = remImp,
			RemainingRuntimesAfterCleanup = remRt,
		},
	}
end

function BuildBenchmarks.FormatPhase41Report(suite: Phase41BenchmarkSuiteResult): string
	local lines = {
		"Phase 4.1 Damage Benchmarks:",
		"Pieces | Launch(ms) | TrackedConns | TrackedParts | ImpactEval(us) | ApplyDmg(us) | Summary(us) | Cleanup(ms) | HeapDelta(KB) | Mem(MB) | RemConns/Dmg/Imp",
	}
	for _, e in ipairs(suite.SingleVehicleSizes) do
		table.insert(
			lines,
			string.format(
				"%6d | %10.3f | %12d | %12d | %14.2f | %12.2f | %11.2f | %11.3f | %13.1f | %7.2f | %d/%d/%d",
				e.PieceCount,
				e.LaunchMs,
				e.TrackedConnections,
				e.TrackedParts,
				e.ImpactEvalAvgUs,
				e.ApplyImpactAvgUs,
				e.SummaryQueryAvgUs,
				e.CleanupMs,
				e.LuaHeapDeltaKB,
				e.TotalStudioMemMB,
				e.RemainingConnectionsAfterCleanup,
				e.RemainingDamageRuntimesAfterCleanup,
				e.RemainingImpactVehiclesAfterCleanup
			)
		)
	end
	local tp = suite.TenPlayersConcurrent
	table.insert(lines, "")
	table.insert(
		lines,
		string.format(
			"10-Player Concurrent (%d pcs/veh): LaunchTotal=%.3fms | 100Impacts=%.3fms (%.2fus/impact) | PeakConns=%d | Clean=%.3fms | Mem=%.2fMB | Rem=%d/%d/%d/%d",
			tp.PiecesPerVehicle,
			tp.TotalLaunchMs,
			tp.BatchImpactTotalMs,
			tp.AvgImpactPerVehicleUs,
			tp.PeakTrackedConnections,
			tp.TotalCleanupMs,
			tp.TotalStudioMemMB,
			tp.RemainingConnectionsAfterCleanup,
			tp.RemainingDamageRuntimesAfterCleanup,
			tp.RemainingImpactVehiclesAfterCleanup,
			tp.RemainingRuntimesAfterCleanup
		)
	)
	return table.concat(lines, "\n")
end

return BuildBenchmarks
