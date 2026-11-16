--!strict
--[=[
	Phase242Tests
	Suite de 22 pruebas automatizadas de Fase 2.4.2 (Objetivo A: piezas desconectadas y
	multi-ensamblaje en taller/lanzamiento; Objetivo B: modo FaceSnap cara con cara,
	geometrías compuestas, histéresis, prioridades del pipeline, visualizador y rendimiento).
	Se integra en Phase1Tests.RunAll() sumando 98 pruebas totales.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildGrid = require(ReplicatedStorage.Shared.Building.BuildGrid)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local FaceSnapMath = require(ReplicatedStorage.Shared.Building.FaceSnapMath)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local PlotService = require(ServerScriptService.Server.Services.PlotService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local StandPreviewService = require(ServerScriptService.Server.Services.StandPreviewService)
local VehicleLaunchPreparationService = require(ServerScriptService.Server.Services.VehicleLaunchPreparationService)
local BuildService = require(ServerScriptService.Server.Services.BuildService)

local ClientControllers = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState"))
local BuildPreviewController = require(ClientControllers:WaitForChild("BuildPreviewController"))
local BuildPlacementController = require(ClientControllers:WaitForChild("BuildPlacementController"))
local BuildSelectionController = require(ClientControllers:WaitForChild("BuildSelectionController"))
local BuildTransformController = require(ClientControllers:WaitForChild("BuildTransformController"))
local BuildMoveGizmo = require(ClientControllers:WaitForChild("BuildMoveGizmo"))
local BuildRotationGizmo = require(ClientControllers:WaitForChild("BuildRotationGizmo"))
local BuildFaceSnapVisualizer = require(ClientControllers:WaitForChild("BuildFaceSnapVisualizer"))
local StandController = require(ClientControllers:WaitForChild("StandController"))

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase242Tests = {}

local function setupIsolatedWorld(): (Folder, PlotService.PlotRecord, PlotService.PlotRecord, () -> ())
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder

	local prevPlots = Workspace:FindFirstChild("_Phase242TestPlots")
	if prevPlots then
		prevPlots:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase242TestPlots"
	tempPlots.Parent = Workspace

	local prevSpawns = Workspace:FindFirstChild("_Phase242CustomSpawns")
	if prevSpawns then
		prevSpawns:Destroy()
	end
	local customSpawns = Instance.new("Folder")
	customSpawns.Name = "_Phase242CustomSpawns"
	for i = 1, 2 do
		local srcName = if i == 1 then "Plot_01" else "Plot_07"
		local src = plotSpawns:FindFirstChild(srcName) :: BasePart
		local clone = src:Clone()
		clone.Name = srcName
		if i == 2 then
			clone.CFrame = CFrame.new(src.Position) * CFrame.Angles(0, math.rad(90), 0)
		end
		clone.Parent = customSpawns
	end

	PlotService._ResetForTests()
	PlotService.Init({
		BaseTemplate = baseTemplate,
		PlotSpawnsFolder = customSpawns,
		PlotsParent = tempPlots,
		PlotCount = 2,
	})

	ConnectionService._ResetForTests()
	ConnectionService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

	InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
	InventoryService.Init()

	VehicleBlueprintService._ResetForTests()
	VehicleBlueprintService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

	StandPreviewService._ResetForTests()
	StandPreviewService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

	VehicleLaunchPreparationService._ResetForTests()
	VehicleLaunchPreparationService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

	BuildService._ResetForTests()
	BuildService.Init()

	local tClock = 100
	BuildService._SetRateLimitClockForTests(function()
		tClock += 5
		return tClock
	end)

	BuildState.Reset()
	BuildPreviewController._ClearGeometryCacheForTests()
	BuildPlacementController.ClearPending()
	BuildSelectionController.ClearSelection()
	BuildTransformController.CancelSession()
	BuildFaceSnapVisualizer.Destroy()
	StandController.ResetHoldDebugStatsForTests()

	local pA = { UserId = 24201, Name = "TestBuilder242A" }
	local pB = { UserId = 24202, Name = "TestBuilder242B" }
	local plot1 = PlotService.Assign(pA)
	local plot2 = PlotService.Assign(pB)
	assert(plot1 and plot2, "Isolated plots failed to assign")

	local function cleanup()
		BuildState.Reset()
		BuildPreviewController._ClearGeometryCacheForTests()
		BuildPlacementController.ClearPending()
		BuildSelectionController.ClearSelection()
		BuildTransformController.CancelSession()
		BuildMoveGizmo.Destroy()
		BuildRotationGizmo.Destroy()
		BuildFaceSnapVisualizer.Destroy()
		StandController.ResetHoldDebugStatsForTests()
		BuildService._ResetForTests()
		VehicleLaunchPreparationService._ResetForTests()
		StandPreviewService._ResetForTests()
		VehicleBlueprintService._ResetForTests()
		InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = false })
		ConnectionService._ResetForTests()
		PlotService._ResetForTests()
		tempPlots:Destroy()
		customSpawns:Destroy()
	end

	return tempPlots, plot1, plot2, cleanup
end

local function makePlrA(): PlotService.PlayerLike
	return { UserId = 24201, Name = "TestBuilder242A" }
end

local function makePlrB(): PlotService.PlayerLike
	return { UserId = 24202, Name = "TestBuilder242B" }
end

local function syncClientStateForPlot(player: PlotService.PlayerLike, plot: PlotService.PlotRecord, bp: VehicleTypes.VehicleBlueprint?)
	BuildState.Reset()
	BuildState.SetExpectedOwner(player.UserId)
	BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
	if bp then
		BuildState.ApplyAuthoritativeBlueprint(bp, true)
	end
	BuildState.SetActive(true)
	BuildState.SetPositionMode(GameConfig.Building.PositionModes.Grid)
	BuildState.SetSmartSnapEnabled(true)
	BuildState.SetFaceSnapEnabled(true)
	BuildState.SetGuidesEnabled(false)
end

local function makeProcessInvoke(player: PlotService.PlayerLike): BuildPlacementController.InvokeHandler
	return function(req: BuildProtocol.BuildRequest): BuildProtocol.BuildOperationResponse
		return BuildService.ProcessRequest(player, req)
	end
end

local function findVisualizerPool(): Folder?
	local cam = Workspace.CurrentCamera
	if cam then
		local f = cam:FindFirstChild("BuildFaceSnapVisualizerPool")
		if f and f:IsA("Folder") then
			return f
		end
	end
	local w = Workspace:FindFirstChild("BuildFaceSnapVisualizerPool")
	if w and w:IsA("Folder") then
		return w
	end
	return nil
end

local function computeMinFaceDistanceBetweenSpecs(
	specA: ConnectionMath.PieceGeometrySpec,
	specB: ConnectionMath.PieceGeometrySpec
): number
	local facesA = FaceSnapMath.ExtractPieceFaces(specA.LocalCFrame, specA.Size, specA.PartBoxes)
	local facesB = FaceSnapMath.ExtractPieceFaces(specB.LocalCFrame, specB.Size, specB.PartBoxes)
	local best = math.huge
	for _, fA in ipairs(facesA) do
		for _, fB in ipairs(facesB) do
			if fA.Normal:Dot(fB.Normal) <= -0.985 then
				local gap = math.abs((fB.Center - fA.Center):Dot(fA.Normal))
				if gap < best then
					best = gap
				end
			end
		end
	end
	return best
end

function Phase242Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (string, () -> ()) -> ()
)
	local pA = makePlrA()
	local pB = makePlrB()

	-- 77 (Objetivo A1)
	runTest("Obj A1: Placing two completely separated pieces succeeds without DisconnectedPiece error", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local r1 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "a1_1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(-4, 1.0, 0),
			})
			local r2 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "a1_2",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(4, 1.0, 0),
			})
			assert(r1.Success and r2.Success, `Separated placements failed: r1={tostring(r1.ErrorCode)} r2={tostring(r2.ErrorCode)}`)

			local bp = VehicleBlueprintService.GetBlueprintSnapshot(pA)
			assert(#bp.Pieces == 2, "Expected 2 pieces")
			assert(#bp.Connections == 0, "Expected 0 connections between separated pieces")

			local analysis = ConnectionService.AnalyzeBlueprintAssemblies(bp)
			assert(#analysis.Groups == 2, `Expected 2 disconnected groups, got {#analysis.Groups}`)
			assert(#analysis.PrimaryPieceIds == 1 and #analysis.WorkshopPieceIds == 1, "Expected 1 diagnostic primary and 1 workshop piece")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 78 (Objetivo A2)
	runTest("Obj A2: Placing 10 independent pieces without DriverSeat or connections across BuildZone succeeds", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local catalogOrder = {
				"WoodBlock",
				"WoodBeam",
				"SmallEngine",
				"SmallBooster",
				"RegularFuelTank",
				"SmallNitroTank",
				"SmallWheel",
				"WoodBlock",
				"WoodBeam",
				"SmallEngine",
			}
			for i, itemId in ipairs(catalogOrder) do
				local row = math.floor((i - 1) / 5)
				local col = (i - 1) % 5
				local x = -8 + col * 4
				local z = -4 + row * 8
				local y = 1.0
				local res = BuildService.ProcessRequest(pA, {
					Action = BuildProtocol.Actions.PlacePiece,
					ClientOpId = `a2_{i}`,
					ItemId = itemId,
					LocalCFrame = CFrame.new(x, y, z),
				})
				assert(res.Success, `Independent piece #{i} ({itemId}) failed: {tostring(res.ErrorCode)} {tostring(res.Message)}`)
			end

			local bp = VehicleBlueprintService.GetBlueprintSnapshot(pA)
			assert(#bp.Pieces == 10, `Expected 10 pieces, got {#bp.Pieces}`)
			assert(#bp.Connections == 0, `Expected 0 connections, got {#bp.Connections}`)

			local analysis = ConnectionService.AnalyzeBlueprintAssemblies(bp)
			assert(#analysis.Groups == 10, `Expected 10 independent groups, got {#analysis.Groups}`)
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 79 (Objetivo A3)
	runTest("Obj A3: Separating a connected piece via 3D Move Gizmo drag succeeds and splits into 2 groups", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local rA = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "a3_1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			local rB = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "a3_2",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(2, 1.0, 0),
			})
			assert(rA.Success and rB.Success and rB.PlacedPiece, "Initial connected pair failed")
			assert(#(rB.Blueprint :: VehicleTypes.VehicleBlueprint).Connections == 1, "Expected 1 initial connection")

			syncClientStateForPlot(pA, plot1, rB.Blueprint)
			local pieceBId = (rB.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId
			BuildState.SetSelectedPlacedPiece(pieceBId)
			BuildState.SetActiveTool(GameConfig.Building.TransformTools.Move)

			local effCF = BuildState.GetEffectiveBuildZoneCFrame() :: CFrame
			local offsetCF = BuildState.GetAssemblyOffsetCFrame()
			local startLocal = (rB.PlacedPiece :: VehicleTypes.BlueprintPiece).LocalCFrame.Position
			local rayOrigin = effCF:PointToWorldSpace(startLocal + Vector3.new(2.0, 0, 8))
			local grabWorld = effCF:PointToWorldSpace(startLocal + Vector3.new(2.0, 0, 0))
			local began = BuildTransformController.TryBeginGizmoDragFromRay(rayOrigin, (grabWorld - rayOrigin).Unit)
			assert(began and BuildMoveGizmo.IsDragging(), "Move gizmo drag failed to begin on X shaft")

			local destRayOrigin = effCF:PointToWorldSpace(startLocal + Vector3.new(6.0, 0, 8))
			local destWorld = effCF:PointToWorldSpace(startLocal + Vector3.new(6.0, 0, 0))
			BuildTransformController.UpdateVisuals(destRayOrigin, (destWorld - destRayOrigin).Unit)

			local endOk, endRes = BuildTransformController.EndGizmoDrag(true, makeProcessInvoke(pA))
			assert(endOk and endRes and endRes.Success and endRes.Blueprint, `Move gizmo split failed: {tostring(endRes and endRes.ErrorCode)}`)
			assert(#endRes.Blueprint.Pieces == 2, "Expected 2 pieces after gizmo separation")
			assert(#endRes.Blueprint.Connections == 0, `Expected 0 connections after separation, got {#endRes.Blueprint.Connections}`)
			assert(offsetCF == CFrame.identity, "Expected neutral offset")

			local analysis = ConnectionService.AnalyzeBlueprintAssemblies(endRes.Blueprint)
			assert(#analysis.Groups == 2, `Expected 2 separated assembly groups, got {#analysis.Groups}`)
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 80 (Objetivo A4)
	runTest("Obj A4: Deleting central bridge piece B from A-B-C leaves 2 independent groups without rejection", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local rA = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a4_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(-2, 1.0, 0) })
			local rB = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a4_2", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
			local rC = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a4_3", ItemId = "WoodBlock", LocalCFrame = CFrame.new(2, 1.0, 0) })
			assert(rA.Success and rB.Success and rC.Success and rB.PlacedPiece, "Bridge A-B-C setup failed")
			assert(#(rC.Blueprint :: VehicleTypes.VehicleBlueprint).Connections == 2, "Expected 2 initial connections")

			local remB = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.RemovePiece,
				ClientOpId = "a4_rem",
				PieceInstanceId = (rB.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId,
			})
			assert(remB.Success and remB.Blueprint, `Deleting bridge B should succeed, got {tostring(remB.ErrorCode)}`)
			assert(#remB.Blueprint.Pieces == 2, "Expected 2 remaining pieces (A and C)")
			assert(#remB.Blueprint.Connections == 0, "Expected 0 connections after bridge removal")

			local analysis = ConnectionService.AnalyzeBlueprintAssemblies(remB.Blueprint)
			assert(#analysis.Groups == 2, "Expected A and C to become 2 separate groups")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 81 (Objetivo A5)
	runTest("Obj A5: Reconnecting two separated groups A and C via B merges back into 1 connected assembly", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a5_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(-2, 1.0, 0) })
			local rC = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a5_2", ItemId = "WoodBlock", LocalCFrame = CFrame.new(2, 1.0, 0) })
			assert(rC.Success and rC.Blueprint, "Two separated blocks failed")
			assert(#ConnectionService.AnalyzeBlueprintAssemblies(rC.Blueprint).Groups == 2, "Expected 2 groups before bridge")

			local rBridge = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "a5_3",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			assert(rBridge.Success and rBridge.Blueprint, "Reconnection bridge failed")
			assert(#rBridge.Blueprint.Connections == 2, "Expected 2 connections after bridge placement")
			assert(#ConnectionService.AnalyzeBlueprintAssemblies(rBridge.Blueprint).Groups == 1, "Expected 1 merged connected assembly")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 82 (Objetivo A6)
	runTest("Obj A6: Saving and loading blueprint preserves multiple disconnected groups and exact positions", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local r1 = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a6_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(-6, 1.0, 0) })
			local r2 = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a6_2", ItemId = "DriverSeat", LocalCFrame = CFrame.new(-6, 2.5, 0) })
			local r3 = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a6_3", ItemId = "SmallEngine", LocalCFrame = CFrame.new(6, 1.0, 2) })
			local r4 = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a6_4", ItemId = "RegularFuelTank", LocalCFrame = CFrame.new(6, 3.0, 2) })
			local r5 = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a6_5", ItemId = "SmallWheel", LocalCFrame = CFrame.new(0, 1.0, -7) })
			assert(r1.Success and r2.Success and r3.Success and r4.Success and r5.Success and r5.PlacedPiece, "Multi-group setup failed")

			local expectedPosById: { [string]: Vector3 } = {}
			local snapshotBeforeSave = VehicleBlueprintService.GetBlueprintSnapshot(pA)
			for _, piece in ipairs(snapshotBeforeSave.Pieces) do
				expectedPosById[piece.InstanceId] = piece.LocalCFrame.Position
			end

			local saveRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = "a6_save",
				Name = "MultiGroupSave",
			})
			assert(saveRes.Success and saveRes.Blueprint, "Save failed")
			local savedId = saveRes.Blueprint.BlueprintId

			local newRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.CreateBlueprint,
				ClientOpId = "a6_new",
				Name = "TempEmpty",
			})
			assert(newRes.Success, "Create temp empty blueprint failed")

			local loadRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.LoadBlueprint,
				ClientOpId = "a6_load",
				BlueprintId = savedId,
			})
			assert(loadRes.Success and loadRes.Blueprint, `Load multi-group blueprint failed: {tostring(loadRes.ErrorCode)}`)
			assert(#loadRes.Blueprint.Pieces == 5, `Expected 5 restored pieces, got {#loadRes.Blueprint.Pieces}`)
			assert(#loadRes.Blueprint.Connections == 2, `Expected 2 explicit connections preserved, got {#loadRes.Blueprint.Connections}`)
			for _, piece in ipairs(loadRes.Blueprint.Pieces) do
				local orig = expectedPosById[piece.InstanceId]
				assert(orig and (piece.LocalCFrame.Position - orig).Magnitude < 1e-4, `Piece {piece.InstanceId} position drifted on reload`)
			end

			local analysis = ConnectionService.AnalyzeBlueprintAssemblies(loadRes.Blueprint)
			assert(#analysis.Groups == 3, `Expected 3 groups after reload, got {#analysis.Groups}`)
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 83 (Objetivo A7)
	runTest("Obj A7: Workshop elevator (SetStandOffset / ResetStandOffset) moves all connected and loose pieces coherently", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local rSeatBlock = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a7_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(-4, 1.0, 0) })
			local rLoose = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a7_2", ItemId = "SmallWheel", LocalCFrame = CFrame.new(5, 1.0, -3) })
			assert(rSeatBlock.Success and rLoose.Success and rSeatBlock.PlacedPiece and rLoose.PlacedPiece, "Setup failed")

			local liftRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "a7_lift",
				HeightOffset = 5.0,
				LateralOffset = -2.5,
			})
			assert(liftRes.Success, "Lift failed")

			local editable = VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model
			local buildZone = plot1.Zones.BuildZone
			local mMain = editable:FindFirstChild(rSeatBlock.PlacedPiece.InstanceId) :: Model
			local mLoose = editable:FindFirstChild(rLoose.PlacedPiece.InstanceId) :: Model
			assert(mMain and mLoose, "EditableVehicle missing disconnected piece model")

			local localMain = buildZone.CFrame:PointToObjectSpace(mMain:GetPivot().Position)
			local localLoose = buildZone.CFrame:PointToObjectSpace(mLoose:GetPivot().Position)
			assert((localMain - Vector3.new(-6.5, 6.0, 0)).Magnitude < 1e-3, `Main piece lifted position mismatch: {localMain}`)
			assert((localLoose - Vector3.new(2.5, 6.0, -3)).Magnitude < 1e-3, `Loose piece lifted position mismatch: {localLoose}`)

			local rstRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.ResetStandOffset,
				ClientOpId = "a7_rst",
			})
			assert(rstRes.Success and rstRes.BuildAssemblyOffset, "Reset lift failed")
			assert(rstRes.BuildAssemblyOffset.HeightOffset == 0 and rstRes.BuildAssemblyOffset.LateralOffset == 0, "Expected ground reset (0,0)")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 84 (Objetivo A8a)
	runTest("Obj A8a: LaunchPreparation isolates PrimaryAssembly with DriverSeat, excludes loose pieces, never auto-merges close unconnected pieces", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- Ensamblaje primario: WoodBlock (0, 1.0, 0) + DriverSeat (0, 2.5, 0)
			local rBlk = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a8a_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
			local rSeat = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a8a_2", ItemId = "DriverSeat", LocalCFrame = CFrame.new(0, 2.5, 0) })
			-- Pieza suelta visualmente muy cercana (gap = 0.45 studs > tolerance, sin conexión Conn_*) en (2.45, 1.0, 0)
			local rCloseLoose = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a8a_3", ItemId = "WoodBlock", LocalCFrame = CFrame.new(2.45, 1.0, 0) })
			assert(rBlk.Success and rSeat.Success and rCloseLoose.Success and rBlk.PlacedPiece and rSeat.PlacedPiece and rCloseLoose.PlacedPiece, "Setup failed")
			assert(#(rCloseLoose.Blueprint :: VehicleTypes.VehicleBlueprint).Connections == 1, "Close loose piece at 0.45 gap must NOT auto-connect")

			local report = VehicleLaunchPreparationService.EvaluatePlayerLaunch(pA, { SkipWorldObstructionCheck = true })
			assert(report.Ready == true, `LaunchPrep should be Ready with loose workshop piece, got {tostring(report.PrimaryErrorCode)}`)
			assert(report.PieceCount == 2, `Primary piece count should be 2, got {report.PieceCount}`)
			assert(report.TotalPieceCount == 3, `Total workshop pieces should be 3, got {tostring(report.TotalPieceCount)}`)
			assert(report.WorkshopPieceCount == 1, `Excluded workshop piece count should be 1, got {tostring(report.WorkshopPieceCount)}`)
			assert(report.DisconnectedGroupCount == 2, `Expected 2 groups, got {tostring(report.DisconnectedGroupCount)}`)
			assert(report.NeedsPrimarySelection == false, "Should auto-select unique DriverSeat assembly")

			local bp = VehicleBlueprintService.GetBlueprintSnapshot(pA)
			local launchWorld = VehicleLaunchPreparationService.ComputePieceLaunchWorldCFrames(bp, CFrame.new(0, 10, 0))
			assert(launchWorld[rBlk.PlacedPiece.InstanceId] ~= nil, "Primary block missing from launch output")
			assert(launchWorld[rSeat.PlacedPiece.InstanceId] ~= nil, "Primary seat missing from launch output")
			assert(launchWorld[rCloseLoose.PlacedPiece.InstanceId] == nil, "Loose piece must NOT enter launch world CFrames")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 85 (Objetivo A8b)
	runTest("Obj A8b: Two disconnected DriverSeat assemblies trigger AmbiguousPrimaryAssembly and SelectPrimaryAssembly RPC selects group cleanly", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- Parte 1: Blueprint sintético legado/externo con 2 grupos desconectados con DriverSeat -> AmbiguousPrimaryAssembly
			local ambigBp: VehicleTypes.VehicleBlueprint = {
				SchemaVersion = 2,
				BlueprintId = "bp_a8b_ambig",
				OwnerUserId = pA.UserId,
				Name = "AmbigA8b",
				Revision = 1,
				CreatedAt = 100,
				UpdatedAt = 100,
				VehicleOrigin = CFrame.identity,
				Presentation = { HeightOffset = 0, LateralOffset = 0 },
				Pieces = {
					{ InstanceId = "a_b1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(-5, 1.0, 0) },
					{ InstanceId = "a_s1", ItemId = "DriverSeat", LocalCFrame = CFrame.new(-5, 2.5, 0) },
					{ InstanceId = "a_b2", ItemId = "WoodBlock", LocalCFrame = CFrame.new(5, 1.0, 0) },
					{ InstanceId = "a_s2", ItemId = "DriverSeat", LocalCFrame = CFrame.new(5, 2.5, 0) },
				},
				Connections = {},
			}
			ConnectionService.ReconcileBlueprintConnections(ambigBp)
			local repAmb = VehicleLaunchPreparationService.EvaluateBlueprintLaunch(ambigBp, plot1, { SkipWorldObstructionCheck = true })
			assert(repAmb.Ready == false, "Two disconnected DriverSeats must require disambiguation")
			assert(repAmb.NeedsPrimarySelection == true, "Expected NeedsPrimarySelection = true")
			assert(repAmb.PrimaryErrorCode == BuildProtocol.ErrorCodes.AmbiguousPrimaryAssembly, `Expected AmbiguousPrimaryAssembly, got {tostring(repAmb.PrimaryErrorCode)}`)
			assert(next(VehicleLaunchPreparationService.ComputePieceLaunchWorldCFrames(ambigBp, CFrame.identity)) == nil, "Ambiguous launch output must be empty until disambiguated")

			local targetSynthGroupId: string? = nil
			assert(repAmb.AssemblyGroups, "Missing AssemblyGroups")
			for _, grp in ipairs(repAmb.AssemblyGroups :: { VehicleTypes.AssemblyComponentSummary }) do
				if table.find(grp.PieceIds, "a_s2") then
					targetSynthGroupId = grp.GroupId
					break
				end
			end
			assert(targetSynthGroupId ~= nil, "Could not locate second seat GroupId")

			ambigBp.Metadata = { PrimaryAssemblyGroupId = targetSynthGroupId }
			local repResolvedSynth = VehicleLaunchPreparationService.EvaluateBlueprintLaunch(ambigBp, plot1, { SkipWorldObstructionCheck = true })
			assert(repResolvedSynth.Ready == true, `Resolved launch should be Ready, got {tostring(repResolvedSynth.PrimaryErrorCode)}`)
			assert(repResolvedSynth.PrimaryAssemblyGroupId == targetSynthGroupId, "Resolved launch primary group mismatch")
			assert(repResolvedSynth.PieceCount == 2 and repResolvedSynth.WorkshopPieceCount == 2, "Expected 2 primary pieces and 2 workshop pieces left behind")

			-- Parte 2: En taller (máx. 1 DriverSeat), validar RPC SelectPrimaryAssembly entre 2 grupos desconectados
			local r1 = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a8b_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(-5, 1.0, 0) })
			local r2 = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a8b_2", ItemId = "DriverSeat", LocalCFrame = CFrame.new(-5, 2.5, 0) })
			local r3 = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "a8b_3", ItemId = "WoodBlock", LocalCFrame = CFrame.new(5, 1.0, 0) })
			assert(r1.Success and r2.Success and r3.Success and r2.PlacedPiece, "Two-group workshop setup failed")

			local livePrep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(pA, { SkipWorldObstructionCheck = true })
			assert(livePrep.Ready == true and livePrep.PrimaryAssemblyGroupId ~= nil, "Single DriverSeat group resolves cleanly")
			local selRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SelectPrimaryAssembly,
				ClientOpId = "a8b_sel",
				GroupId = livePrep.PrimaryAssemblyGroupId :: string,
			})
			assert(selRes.Success and selRes.Blueprint and selRes.Blueprint.Metadata, `SelectPrimaryAssembly failed: {tostring(selRes.ErrorCode)}`)
			assert((selRes.Blueprint.Metadata :: VehicleTypes.BlueprintMetadata).PrimaryAssemblyGroupId == livePrep.PrimaryAssemblyGroupId, "PrimaryAssemblyGroupId metadata not persisted")
			assert(selRes.AssemblyAnalysis and selRes.AssemblyAnalysis.PrimaryGroupId == livePrep.PrimaryAssemblyGroupId, "AssemblyAnalysis missing selected PrimaryGroupId")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 86 (Objetivo B1)
	runTest("Obj B1: FaceSnap aligns cleanly across all 6 faces (+X, -X, +Y, -Y, +Z, -Z) with gap = 0", function()
		local baseSpec: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "target_blk",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 5.0, 0),
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		}
		ConnectionMath.PreparePieceSpec(baseSpec)
		local existing = { baseSpec }

		local dirs = {
			{ Face = "+X", Normal = Vector3.xAxis, ExpectedPos = Vector3.new(2, 5.0, 0) },
			{ Face = "-X", Normal = -Vector3.xAxis, ExpectedPos = Vector3.new(-2, 5.0, 0) },
			{ Face = "+Y", Normal = Vector3.yAxis, ExpectedPos = Vector3.new(0, 7.0, 0) },
			{ Face = "-Y", Normal = -Vector3.yAxis, ExpectedPos = Vector3.new(0, 3.0, 0) },
			{ Face = "+Z", Normal = Vector3.zAxis, ExpectedPos = Vector3.new(0, 5.0, 2) },
			{ Face = "-Z", Normal = -Vector3.zAxis, ExpectedPos = Vector3.new(0, 5.0, -2) },
		}

		for _, d in ipairs(dirs) do
			local roughPos = Vector3.new(0, 5.0, 0) + d.Normal * 2.35
			local res = FaceSnapMath.ComputeFaceSnap({
				BaseLocalCFrame = CFrame.new(roughPos),
				CandidateItemId = "WoodBlock",
				CandidateSize = Vector3.new(2, 2, 2),
				CandidateAttachments = {},
				ExistingPieces = existing,
				TargetPieceId = "target_blk",
				SurfaceHitLocal = Vector3.new(0, 5.0, 0) + d.Normal * 1.0,
				SurfaceNormalLocal = d.Normal,
			})
			assert(res.Matched and res.VisualTarget, `FaceSnap failed on face {d.Face}: {tostring(res.RejectReason)}`)
			assert(res.VisualTarget.TargetFaceId == d.Face, `Expected TargetFaceId {d.Face}, got {res.VisualTarget.TargetFaceId}`)
			assert((res.SnappedLocalCFrame.Position - d.ExpectedPos).Magnitude < 1e-4, `Expected exact zero-gap position {d.ExpectedPos} on {d.Face}, got {res.SnappedLocalCFrame.Position}`)
		end
	end)

	-- 87 (Objetivo B2)
	runTest("Obj B2: FaceSnap preserves player 90/180/270 rotations AND snaps rotated diagonal (45 deg) OBB faces cleanly", function()
		-- A) Rotaciones ortogonales 90/180/270 sobre bloque asimétrico WoodBeam (1x1x4)
		local targetBox: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "rot_tgt",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 4, 0),
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		}
		ConnectionMath.PreparePieceSpec(targetBox)
		for _, angleDeg in ipairs({ 90, 180, 270 }) do
			local candRot = CFrame.Angles(0, math.rad(angleDeg), 0)
			local isZAlongX = (angleDeg == 90 or angleDeg == 270)
			local halfAlongX = if isZAlongX then 2.0 else 0.5
			local roughX = 1.0 + halfAlongX + 0.35
			local res = FaceSnapMath.ComputeFaceSnap({
				BaseLocalCFrame = CFrame.new(roughX, 4, 0) * candRot,
				CandidateItemId = "WoodBeam",
				CandidateSize = Vector3.new(1, 1, 4),
				CandidateAttachments = {},
				ExistingPieces = { targetBox },
				TargetPieceId = "rot_tgt",
				SurfaceHitLocal = Vector3.new(1.0, 4, 0),
				SurfaceNormalLocal = Vector3.xAxis,
			})
			assert(res.Matched, `Rotated {angleDeg} deg FaceSnap failed`)
			local dotRight = res.SnappedLocalCFrame.RightVector:Dot(candRot.RightVector)
			local dotLook = res.SnappedLocalCFrame.LookVector:Dot(candRot.LookVector)
			assert(dotRight > 0.9999 and dotLook > 0.9999, `FaceSnap altered player rotation at {angleDeg} deg`)
			assert(math.abs(res.SnappedLocalCFrame.Position.X - (1.0 + halfAlongX)) < 1e-4, `Exact contact X mismatch at {angleDeg} deg`)
		end

		-- B) OBB rotado en diagonal (45 deg en eje Y): alinear caras paralelas opuestas sin perder orientación diagonal
		local diagRot = CFrame.Angles(0, math.rad(45), 0)
		local diagTarget: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "diag_tgt",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 4, 0) * diagRot,
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		}
		ConnectionMath.PreparePieceSpec(diagTarget)

		local diagNormal = diagRot.RightVector -- cara +X local rotada 45 deg
		local resDiag = FaceSnapMath.ComputeFaceSnap({
			BaseLocalCFrame = CFrame.new(diagNormal * 2.45 + Vector3.new(0, 4, 0)) * diagRot,
			CandidateItemId = "WoodBlock",
			CandidateSize = Vector3.new(2, 2, 2),
			CandidateAttachments = {},
			ExistingPieces = { diagTarget },
			TargetPieceId = "diag_tgt",
			SurfaceHitLocal = Vector3.new(0, 4, 0) + diagNormal * 1.0,
			SurfaceNormalLocal = diagNormal,
		})
		assert(resDiag.Matched, `Diagonal 45 deg OBB FaceSnap failed: {tostring(resDiag.RejectReason)}`)
		assert(resDiag.SnappedLocalCFrame.RightVector:Dot(diagRot.RightVector) > 0.9999, "Diagonal rotation changed unexpectedly")
		local candSpec: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "diag_cand",
			ItemId = "WoodBlock",
			LocalCFrame = resDiag.SnappedLocalCFrame,
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		}
		assert(computeMinFaceDistanceBetweenSpecs(diagTarget, candSpec) < 1e-4, "Diagonal snapped OBB gap is not zero")
	end)

	-- 88 (Objetivo B3)
	runTest("Obj B3: FaceSnap works across heterogeneous catalog sizes (Seat front, Booster back, FuelTank, Wheel)", function()
		local _, assetsRoot = nil, ServerStorage:WaitForChild("ItemAssets")
		local itemsToTest = {
			{ Target = "DriverSeat", Normal = -Vector3.zAxis, Cand = "WoodBlock" },     -- Frente de DriverSeat (sin Conn_Front)
			{ Target = "SmallBooster", Normal = Vector3.zAxis, Cand = "WoodBeam" },     -- Atrás de Booster (sin Conn_Back)
			{ Target = "RegularFuelTank", Normal = Vector3.xAxis, Cand = "SmallEngine" }, -- Costado de FuelTank (sin Conn_Right)
			{ Target = "SmallWheel", Normal = Vector3.yAxis, Cand = "WoodBlock" },      -- Tope de SmallWheel (sin Conn_Top)
		}

		for _, tc in ipairs(itemsToTest) do
			local targetModel = assetsRoot:FindFirstChild(tc.Target, true) :: Model
			local candModel = assetsRoot:FindFirstChild(tc.Cand, true) :: Model
			assert(targetModel and candModel, `Missing catalog asset for {tc.Target} or {tc.Cand}`)
			local _, tSize, tBoxes = ConnectionMath.ExtractModelGeometry(targetModel)
			local _, cSize, cBoxes = ConnectionMath.ExtractModelGeometry(candModel)
			local tSpec: ConnectionMath.PieceGeometrySpec = {
				InstanceId = `t_{tc.Target}`,
				ItemId = tc.Target,
				LocalCFrame = CFrame.new(0, 5, 0),
				Size = tSize,
				Attachments = {},
				PartBoxes = tBoxes,
			}
			ConnectionMath.PreparePieceSpec(tSpec)

			local hitPos = Vector3.new(0, 5, 0) + Vector3.new(tc.Normal.X * tSize.X * 0.5, tc.Normal.Y * tSize.Y * 0.5, tc.Normal.Z * tSize.Z * 0.5)
			local candRough = hitPos + Vector3.new(tc.Normal.X * (cSize.X * 0.5 + 0.4), tc.Normal.Y * (cSize.Y * 0.5 + 0.4), tc.Normal.Z * (cSize.Z * 0.5 + 0.4))
			local res = FaceSnapMath.ComputeFaceSnap({
				BaseLocalCFrame = CFrame.new(candRough),
				CandidateItemId = tc.Cand,
				CandidateSize = cSize,
				CandidateAttachments = {},
				CandidatePartBoxes = cBoxes,
				ExistingPieces = { tSpec },
				TargetPieceId = tSpec.InstanceId,
				SurfaceHitLocal = hitPos,
				SurfaceNormalLocal = tc.Normal,
			})
			assert(res.Matched, `FaceSnap failed for {tc.Cand} onto {tc.Target}: {tostring(res.RejectReason)}`)

			local candSpec: ConnectionMath.PieceGeometrySpec = {
				InstanceId = "c_probe",
				ItemId = tc.Cand,
				LocalCFrame = res.SnappedLocalCFrame,
				Size = cSize,
				Attachments = {},
				PartBoxes = cBoxes,
			}
			local gap = computeMinFaceDistanceBetweenSpecs(tSpec, candSpec)
			assert(gap < 1e-4, `Expected zero gap for {tc.Cand} -> {tc.Target}, got {gap}`)
		end
	end)

	-- 89 (Objetivo B4)
	runTest("Obj B4: FaceSnap supports multi-BasePart L-shaped composite models via PartBoxes extraction and detects internal collision", function()
		-- Construir un modelo L-shaped de 2 BaseParts: vertical (2x4x2) + ala +X (4x1x2)
		local lModel = Instance.new("Model")
		lModel.Name = "CompositeLShape"
		local partA = Instance.new("Part")
		partA.Size = Vector3.new(2, 4, 2)
		partA.CFrame = CFrame.new(-1, 0, 0)
		partA.Anchored = true
		partA.Parent = lModel
		local partB = Instance.new("Part")
		partB.Size = Vector3.new(4, 1, 2)
		partB.CFrame = CFrame.new(1, -1.5, 0)
		partB.Anchored = true
		partB.Parent = lModel
		lModel.PrimaryPart = partA

		local _, totalSize, partBoxes = ConnectionMath.ExtractModelGeometry(lModel)
		lModel:Destroy()
		assert(#partBoxes == 2, `Expected 2 PartBoxes from composite model, got {#partBoxes}`)

		-- Respecto a PrimaryPart (partA): partA ocupa local X=[-1..1], Y=[-2..2]; ala partB ocupa X=[0..4], Y=[-2..-1]
		-- Al colocar compSpec en (0, 6, 0): partA cubre X=[-1..1], Y=[4..8]; ala partB cubre X=[0..4], Y=[4..5]
		local compSpec: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "comp_L",
			ItemId = "CompositeL",
			LocalCFrame = CFrame.new(0, 6, 0),
			Size = totalSize,
			Attachments = {},
			PartBoxes = partBoxes,
		}
		ConnectionMath.PreparePieceSpec(compSpec)

		-- Snappear un bloque (2x2x2) en el hueco libre superior derecho (+X de partA en X=1.0, Y=7.0 -> centro en X=2.0)
		local resHollow = FaceSnapMath.ComputeFaceSnap({
			BaseLocalCFrame = CFrame.new(2.2, 7.0, 0),
			CandidateItemId = "WoodBlock",
			CandidateSize = Vector3.new(2, 2, 2),
			CandidateAttachments = {},
			ExistingPieces = { compSpec },
			TargetPieceId = "comp_L",
			SurfaceHitLocal = Vector3.new(1.0, 7.0, 0),
			SurfaceNormalLocal = Vector3.xAxis,
		})
		assert(resHollow.Matched, `Composite L-shape hollow pocket must accept WoodBlock without false AABB rejection, got {tostring(resHollow.RejectReason)}`)
		assert(math.abs(resHollow.SnappedLocalCFrame.Position.X - 2.0) < 1e-4, `Expected snap against inner vertical face X=2.0, got {resHollow.SnappedLocalCFrame.Position.X}`)

		-- Bajar el candidato hacia Y=4.5 para chocar con el ala horizontal (partB Y=[4..5]) -> debe rechazar por PieceOverlap
		local resCollideWing = FaceSnapMath.ComputeFaceSnap({
			BaseLocalCFrame = CFrame.new(2.2, 4.5, 0),
			CandidateItemId = "WoodBlock",
			CandidateSize = Vector3.new(2, 2, 2),
			CandidateAttachments = {},
			ExistingPieces = { compSpec },
			TargetPieceId = "comp_L",
			SurfaceHitLocal = Vector3.new(1.0, 5.5, 0),
			SurfaceNormalLocal = Vector3.xAxis,
		})
		assert(not resCollideWing.Matched and resCollideWing.RejectReason == "PieceOverlap", `Expected PieceOverlap against composite wing sub-box, got matched={resCollideWing.Matched} reason={tostring(resCollideWing.RejectReason)}`)
	end)

	-- 90 (Objetivo B5)
	runTest("Obj B5: FaceSnap rejects resulting overlap against a third obstacle piece with PieceOverlap", function()
		local t1: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "ov_1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 5, 0),
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		}
		local obstacle: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "ov_block",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2.5, 5, 0), -- ocupa X=[1.5..3.5], bloqueando snappeo a X=2.0 (ocuparía [1..3])
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		}
		ConnectionMath.PreparePieceSpec(t1)
		ConnectionMath.PreparePieceSpec(obstacle)

		local res = FaceSnapMath.ComputeFaceSnap({
			BaseLocalCFrame = CFrame.new(2.1, 5, 0),
			CandidateItemId = "WoodBlock",
			CandidateSize = Vector3.new(2, 2, 2),
			CandidateAttachments = {},
			ExistingPieces = { t1, obstacle },
			TargetPieceId = "ov_1",
			SurfaceHitLocal = Vector3.new(1.0, 5, 0),
			SurfaceNormalLocal = Vector3.xAxis,
			MaxRadius = 0.8, -- restringir para no saltar sobre cara derecha del obstáculo
		})
		assert(not res.Matched, "FaceSnap must reject position that collides with obstacle")
		assert(res.RejectReason == "PieceOverlap", `Expected PieceOverlap, got {tostring(res.RejectReason)}`)
		assert(res.VisualTarget and not res.VisualTarget.IsValid, "VisualTarget should signal invalid red state")
	end)

	-- 91 (Objetivo B6)
	runTest("Obj B6: FaceSnap rejects OutOfBounds / BelowFloor and allows under-face snap once elevator lifts", function()
		local buildZoneSize = Vector3.new(40, 1, 40)
		local maxZoneHeight = 32
		local target: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "floor_blk",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 0.5, 0), -- bottom Y = -0.5 == floorY
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		}
		ConnectionMath.PreparePieceSpec(target)

		-- Intentar pegar bajo cara -Y con elevador en 0 -> centro en -1.5, minY = -2.5 < -0.5 -> OutOfBounds
		local resLow = FaceSnapMath.ComputeFaceSnap({
			BaseLocalCFrame = CFrame.new(0, -1.7, 0),
			CandidateItemId = "WoodBlock",
			CandidateSize = Vector3.new(2, 2, 2),
			CandidateAttachments = {},
			ExistingPieces = { target },
			TargetPieceId = "floor_blk",
			SurfaceHitLocal = Vector3.new(0, -0.5, 0),
			SurfaceNormalLocal = -Vector3.yAxis,
			BuildZoneSize = buildZoneSize,
			MaxZoneHeight = maxZoneHeight,
			AssemblyOffset = { HeightOffset = 0, LateralOffset = 0 },
		})
		assert(not resLow.Matched and resLow.RejectReason == "OutOfBounds", `Expected OutOfBounds below floor, got matched={resLow.Matched} reason={tostring(resLow.RejectReason)}`)

		-- Con elevador en +4.0 -> floor efectivo = -4.5 -> ahora snappea perfectamente a (0, -1.5, 0)!
		local resLifted = FaceSnapMath.ComputeFaceSnap({
			BaseLocalCFrame = CFrame.new(0, -1.7, 0),
			CandidateItemId = "WoodBlock",
			CandidateSize = Vector3.new(2, 2, 2),
			CandidateAttachments = {},
			ExistingPieces = { target },
			TargetPieceId = "floor_blk",
			SurfaceHitLocal = Vector3.new(0, -0.5, 0),
			SurfaceNormalLocal = -Vector3.yAxis,
			BuildZoneSize = buildZoneSize,
			MaxZoneHeight = maxZoneHeight,
			AssemblyOffset = { HeightOffset = 4.0, LateralOffset = 0 },
		})
		assert(resLifted.Matched, `Under-chassis FaceSnap when lifted +4 should match, got {tostring(resLifted.RejectReason)}`)
		assert((resLifted.SnappedLocalCFrame.Position - Vector3.new(0, -1.5, 0)).Magnitude < 1e-4, "Under-chassis lifted snap pos mismatch")

		-- Fuera de X en borde de BuildZone (+20)
		local edgeTarget: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "edge_blk",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(19, 1, 0),
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		}
		ConnectionMath.PreparePieceSpec(edgeTarget)
		local resEdge = FaceSnapMath.ComputeFaceSnap({
			BaseLocalCFrame = CFrame.new(21.2, 1, 0),
			CandidateItemId = "WoodBlock",
			CandidateSize = Vector3.new(2, 2, 2),
			CandidateAttachments = {},
			ExistingPieces = { edgeTarget },
			TargetPieceId = "edge_blk",
			SurfaceHitLocal = Vector3.new(20, 1, 0),
			SurfaceNormalLocal = Vector3.xAxis,
			BuildZoneSize = buildZoneSize,
			MaxZoneHeight = maxZoneHeight,
			AssemblyOffset = { HeightOffset = 0, LateralOffset = 0 },
		})
		assert(not resEdge.Matched and resEdge.RejectReason == "OutOfBounds", `Expected OutOfBounds past X border, got {tostring(resEdge.RejectReason)}`)
	end)

	-- 92 (Objetivo B7)
	runTest("Obj B7: FaceSnap LockState hysteresis prevents jitter/jumping between competing adjacent faces", function()
		local blkLeft: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "h_left",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 5, 0),
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		}
		local blkRight: ConnectionMath.PieceGeometrySpec = {
			InstanceId = "h_right",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2.2, 5, 0), -- gap de 0.2 studs en medio o dos caras cercanas competidoras
			Size = Vector3.new(2, 2, 2),
			Attachments = {},
		}
		ConnectionMath.PreparePieceSpec(blkLeft)
		ConnectionMath.PreparePieceSpec(blkRight)

		local lockState = FaceSnapMath.CreateLockState()
		-- Primer enganche: cara +Y de blkLeft (Y=6, centro Z=0, X=0)
		local r1 = FaceSnapMath.ComputeFaceSnap({
			BaseLocalCFrame = CFrame.new(0.8, 7.2, 0),
			CandidateItemId = "WoodBlock",
			CandidateSize = Vector3.new(2, 2, 2),
			CandidateAttachments = {},
			ExistingPieces = { blkLeft, blkRight },
			LockState = lockState,
		})
		assert(r1.Matched and r1.VisualTarget, "Initial lock acquisition failed")
		local lockedPieceId = r1.VisualTarget.TargetPieceId
		assert(lockedPieceId == "h_left", `Expected lock on h_left, got {lockedPieceId}`)

		-- Mover ligeramente el cursor hacia la cara opuesta (X = 1.25 -> más cerca del centro de h_right en X=2.2, pero dentro de histéresis)
		local r2 = FaceSnapMath.ComputeFaceSnap({
			BaseLocalCFrame = CFrame.new(1.25, 7.2, 0),
			CandidateItemId = "WoodBlock",
			CandidateSize = Vector3.new(2, 2, 2),
			CandidateAttachments = {},
			ExistingPieces = { blkLeft, blkRight },
			LockState = lockState,
		})
		assert(r2.Matched and r2.VisualTarget, "Hysteresis evaluation failed")
		assert(r2.VisualTarget.TargetPieceId == "h_left", `Hysteresis should preserve h_left without flicker, jumped to {r2.VisualTarget.TargetPieceId}`)
	end)

	-- 93 (Objetivo B8)
	runTest("Obj B8: FaceSnap OFF mode completely disables face snapping and hides visualizer", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local rBooster = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "b8_1",
				ItemId = "SmallBooster", -- +X/+Z carecen de Conn_*
				LocalCFrame = CFrame.new(0, 2.0, 0),
			})
			assert(rBooster.Success and rBooster.Blueprint and rBooster.PlacedPiece, "Booster failed")

			syncClientStateForPlot(pA, plot1, rBooster.Blueprint)
			BuildState.SelectItem("WoodBlock")
			BuildState.SetFaceSnapEnabled(false)

			local effCF = BuildState.GetEffectiveBuildZoneCFrame() :: CFrame
			local hitLocal = Vector3.new(0.75, 2.0, 0) -- cara +X de SmallBooster (size 1.5x1.5x3)
			local okP, _ = BuildPreviewController.UpdateAtWorldPoint(
				effCF:PointToWorldSpace(hitLocal),
				effCF:VectorToWorldSpace(Vector3.xAxis),
				{ TargetPieceId = rBooster.PlacedPiece.InstanceId }
			)
			assert(okP, "Preview should still fall back cleanly to Grid when FaceSnap is OFF")
			assert(BuildState.FaceSnapTarget == nil, "FaceSnapTarget must be nil when FaceSnap is OFF")

			local pool = findVisualizerPool()
			if pool then
				for _, child in ipairs(pool:GetChildren()) do
					if child:IsA("LineHandleAdornment") or child:IsA("SphereHandleAdornment") then
						assert(not child.Visible, "FaceSnap visualizer adornments must be hidden when FaceSnap is OFF")
					end
				end
			end
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 94 (Objetivo B9)
	runTest("Obj B9: Priority pipeline gives SmartSnap precedence over FaceSnap and falls back cleanly without double-snapping", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- DriverSeat (2x1x2) tiene Conn_Bottom y Conn_Back (+Z), NO tiene Conn_Front (-Z)
			local rSeat = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "b9_1",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 2.0, 0),
			})
			assert(rSeat.Success and rSeat.Blueprint and rSeat.PlacedPiece, "Seat placement failed")

			syncClientStateForPlot(pA, plot1, rSeat.Blueprint)
			BuildState.SelectItem("WoodBlock")
			BuildState.SetSmartSnapEnabled(true)
			BuildState.SetFaceSnapEnabled(true)

			local effCF = BuildState.GetEffectiveBuildZoneCFrame() :: CFrame

			-- Caso 1: Apuntar a cara trasera (+Z) donde DriverSeat SÍ tiene Conn_Back -> SmartSnap debe ganar (Priority 1)
			local okBack, _ = BuildPreviewController.UpdateAtWorldPoint(
				effCF:PointToWorldSpace(Vector3.new(0, 2.0, 1.0)),
				effCF:VectorToWorldSpace(Vector3.zAxis),
				{ TargetPieceId = rSeat.PlacedPiece.InstanceId }
			)
			assert(okBack, "Back snap should succeed")
			assert(BuildState.FaceSnapTarget == nil, "SmartSnap (Priority 1) should win over FaceSnap without double-snapping")

			-- Caso 2: Apuntar a cara frontal (-Z) donde DriverSeat NO tiene Conn_Front -> FaceSnap toma el relevo (Priority 2)
			local okFront, _ = BuildPreviewController.UpdateAtWorldPoint(
				effCF:PointToWorldSpace(Vector3.new(0, 2.0, -1.0)),
				effCF:VectorToWorldSpace(-Vector3.zAxis),
				{ TargetPieceId = rSeat.PlacedPiece.InstanceId }
			)
			assert(okFront, `Front FaceSnap fallback failed: {tostring(BuildState.ValidationReason)}`)
			assert(BuildState.FaceSnapTarget ~= nil and BuildState.FaceSnapTarget.TargetFaceId == "-Z", "FaceSnap (Priority 2) should activate on face lacking Conn_*")
			local snappedPos = (BuildState.LastSnappedLocalCFrame :: CFrame).Position
			assert((snappedPos - Vector3.new(0, 2.0, -2.0)).Magnitude < 1e-4, `Expected exact contact Z=-2.0, got {snappedPos}`)
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 95 (Objetivo B10)
	runTest("Obj B10: BuildFaceSnapVisualizer displays valid/invalid colors and leaves zero leftover adornments on Destroy", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local buildZone = plot1.Zones.BuildZone
			local validTarget: FaceSnapMath.FaceSnapVisualTarget = {
				TargetPieceId = "v_1",
				TargetFaceId = "+X",
				TargetBoxIndex = 1,
				CandidateFaceId = "-X",
				CandidateBoxIndex = 1,
				TargetFaceCenter = Vector3.new(1, 2, 0),
				TargetFaceNormal = Vector3.xAxis,
				TargetTangentU = Vector3.yAxis,
				TargetTangentV = Vector3.zAxis,
				TargetHalfU = 1,
				TargetHalfV = 1,
				ContactPoint = Vector3.new(1, 2, 0),
				IsValid = true,
			}
			BuildFaceSnapVisualizer.Render(buildZone, validTarget, CFrame.identity)
			local pool = findVisualizerPool()
			assert(pool ~= nil, "BuildFaceSnapVisualizerPool must be created on Render")
			local line1 = pool:FindFirstChild("FaceSnapLine_1") :: LineHandleAdornment
			local sphere = pool:FindFirstChild("FaceSnapContactSphere") :: SphereHandleAdornment
			assert(line1.Visible and sphere.Visible, "Adornments must be visible on valid target")
			assert(line1.Color3 == GameConfig.Building.FaceSnapValidColor, "Valid face snap line color mismatch")

			validTarget.IsValid = false
			BuildFaceSnapVisualizer.Render(buildZone, validTarget, CFrame.identity)
			assert(line1.Color3 == GameConfig.Building.FaceSnapInvalidColor, "Invalid face snap line color mismatch")

			BuildFaceSnapVisualizer.Hide()
			assert(not line1.Visible and not sphere.Visible, "Hide must turn off all adornments")

			BuildFaceSnapVisualizer.Destroy()
			assert(findVisualizerPool() == nil, "Destroy must remove BuildFaceSnapVisualizerPool cleanly")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 96 (Objetivo B11)
	runTest("Obj B11: End-to-End UpdateFromRay -> FaceSnap -> PlaceCurrentPiece confirms exact zero-gap piece on server", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- Colocar SmallBooster (size 1.5x1.5x3) cuya cara +Z trasera NO tiene Conn_*
			local rBooster = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "b11_1",
				ItemId = "SmallBooster",
				LocalCFrame = CFrame.new(0, 3.0, 0),
			})
			assert(rBooster.Success and rBooster.Blueprint and rBooster.PlacedPiece, "Booster setup failed")

			syncClientStateForPlot(pA, plot1, rBooster.Blueprint)
			BuildState.SelectItem("WoodBlock")
			BuildState.SetFaceSnapEnabled(true)
			BuildState.SetSmartSnapEnabled(true)

			-- Asegurar que el modelo físico EditableVehicle está listo para raycast real de UpdateFromRay
			local editable = VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model
			assert(editable and editable:FindFirstChild(rBooster.PlacedPiece.InstanceId), "Missing booster model in Workspace")

			local effCF = BuildState.GetEffectiveBuildZoneCFrame() :: CFrame
			-- Rayo desde +Z apuntando al centro trasero del SmallBooster (local Z = +1.5, Y = 3.0)
			local rayOrigin = effCF:PointToWorldSpace(Vector3.new(0, 3.0, 8.0))
			local rayTarget = effCF:PointToWorldSpace(Vector3.new(0, 3.0, 0))
			local okRay, _ = BuildPreviewController.UpdateFromRay(rayOrigin, (rayTarget - rayOrigin).Unit * 20)
			assert(okRay, `UpdateFromRay FaceSnap failed: {tostring(BuildState.ValidationReason)}`)
			assert(BuildState.FaceSnapTarget ~= nil and BuildState.FaceSnapTarget.TargetFaceId == "+Z", "Expected FaceSnap hit onto +Z face of SmallBooster")

			local placedOk, placeRes = BuildPlacementController.PlaceCurrentPiece(makeProcessInvoke(pA))
			assert(placedOk and placeRes and placeRes.Success and placeRes.PlacedPiece, `Server rejected FaceSnap placement: {tostring(placeRes and placeRes.ErrorCode)}`)
			-- SmallBooster halfZ = 1.5, WoodBlock halfZ = 1.0 -> Z exacto = 2.5
			local placedZ = placeRes.PlacedPiece.LocalCFrame.Position.Z
			assert(math.abs(placedZ - 2.5) < 1e-3, `Expected exact zero-gap Z=2.5, got {placedZ}`)
			local placedConns = (placeRes.Blueprint :: VehicleTypes.VehicleBlueprint).Connections
			assert(#placedConns == 1, `Expected 1 surface connection on zero-gap FaceSnapped Booster back, got {#placedConns}`)
			assert(
				placedConns[1].FromAttachment == "Surface_-Z" or placedConns[1].ToAttachment == "Surface_+Z",
				`Expected Surface face connection on Booster back, got {placedConns[1].FromAttachment} -> {placedConns[1].ToAttachment}`
			)
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 97 (Objetivo B12)
	runTest("Obj B12: FaceSnap parity under rotated plot (Plot_07 90 deg) and lifted BuildAssemblyOffset (+3.5 Y, +2.0 X)", function()
		local _, _, plot2, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local rSeat = BuildService.ProcessRequest(pB, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "b12_1",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 1.5, 0),
			})
			local liftRes = BuildService.ProcessRequest(pB, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "b12_lift",
				HeightOffset = 3.5,
				LateralOffset = 2.0,
			})
			assert(rSeat.Success and liftRes.Success and liftRes.Blueprint and rSeat.PlacedPiece, "Setup on rotated plot failed")

			syncClientStateForPlot(pB, plot2, liftRes.Blueprint)
			BuildState.SelectItem("WoodBlock")
			BuildState.SetFaceSnapEnabled(true)

			local effCF = BuildState.GetEffectiveBuildZoneCFrame() :: CFrame
			-- Rayo sobre cara lateral derecha (+X) del DriverSeat en estación rotada y elevada
			local rayOrigin = effCF:PointToWorldSpace(Vector3.new(6.0, 1.5, 0))
			local rayTarget = effCF:PointToWorldSpace(Vector3.new(0, 1.5, 0))
			local okRay, _ = BuildPreviewController.UpdateFromRay(rayOrigin, (rayTarget - rayOrigin).Unit * 20)
			assert(okRay, `UpdateFromRay on rotated+lifted plot failed: {tostring(BuildState.ValidationReason)}`)
			assert(BuildState.FaceSnapTarget and BuildState.FaceSnapTarget.TargetFaceId == "+X", "Expected +X FaceSnap target")

			local placedOk, placeRes = BuildPlacementController.PlaceCurrentPiece(makeProcessInvoke(pB))
			assert(placedOk and placeRes and placeRes.Success and placeRes.PlacedPiece, "Rotated+lifted FaceSnap placement rejected")
			assert((placeRes.PlacedPiece.LocalCFrame.Position - Vector3.new(2.0, 1.5, 0)).Magnitude < 1e-3, `Local parity mismatch: {placeRes.PlacedPiece.LocalCFrame.Position}`)
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 98 (Objetivo B13)
	runTest("Obj B13: Performance gate - FaceSnapMath.ComputeFaceSnap averages under 2.5 ms near 30 pieces", function()
		local specs: { ConnectionMath.PieceGeometrySpec } = {}
		local spatial = ConnectionMath.CreateSpatialIndex(4)
		for i = 1, 30 do
			local x = ((i - 1) % 6 - 2.5) * 3.0
			local z = (math.floor((i - 1) / 6) - 2.0) * 3.0
			local sp: ConnectionMath.PieceGeometrySpec = {
				InstanceId = `perf_{i}`,
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(x, 4, z),
				Size = Vector3.new(2, 2, 2),
				Attachments = {},
			}
			ConnectionMath.PreparePieceSpec(sp)
			table.insert(specs, sp)
			spatial:Insert(sp)
		end

		local lockState = FaceSnapMath.CreateLockState()
		local t0 = os.clock()
		for iter = 1, 40 do
			local jitter = (iter % 5) * 0.05
			FaceSnapMath.ComputeFaceSnap({
				BaseLocalCFrame = CFrame.new(1.5 + jitter, 6.2, 0),
				CandidateItemId = "WoodBlock",
				CandidateSize = Vector3.new(2, 2, 2),
				CandidateAttachments = {},
				ExistingPieces = specs,
				SpatialIndex = spatial,
				LockState = lockState,
				BuildZoneSize = Vector3.new(40, 1, 40),
				MaxZoneHeight = 32,
				AssemblyOffset = { HeightOffset = 0, LateralOffset = 0 },
			})
		end
		local elapsedMs = (os.clock() - t0) * 1000
		local avgMs = elapsedMs / 40
		assert(avgMs < 2.5, string.format("FaceSnap average cost too high near 30 pieces: %.3f ms/call", avgMs))
	end)
end

return Phase242Tests
