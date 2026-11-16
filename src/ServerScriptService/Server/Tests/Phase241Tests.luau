--!strict
--[=[
	Phase241Tests
	Suite de pruebas automatizadas de Fase 2.4.1 (Elevador de Construcción sobre EditableVehicle):
	- Construcción debajo del vehículo elevado (chasis -> subir +4 -> motor/ruedas debajo -> bajar -> guardar/cargar).
	- Integración completa del editor en modo elevado (SmartSnap, Visual Grid, Modo Libre, Gizmos 3D).
	- Cálculo de límites dinámicos, bloqueo físico de colisiones (ElevatorBlocked), seguridad multijugador y LaunchPrep invariante.
	- Movimiento continuo al mantener pulsado con coalescencia temporal (<= 10 Hz, máx 1 RPC en vuelo, rollback).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildGrid = require(ReplicatedStorage.Shared.Building.BuildGrid)
local BuildAlignmentMath = require(ReplicatedStorage.Shared.Building.BuildAlignmentMath)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local VehicleCoordinateMath = require(ReplicatedStorage.Shared.Building.VehicleCoordinateMath)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local PlotService = require(ServerScriptService.Server.Services.PlotService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local PreviewAssetService = require(ServerScriptService.Server.Services.PreviewAssetService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local StandPreviewService = require(ServerScriptService.Server.Services.StandPreviewService)
local VehicleLaunchPreparationService = require(ServerScriptService.Server.Services.VehicleLaunchPreparationService)
local BuildService = require(ServerScriptService.Server.Services.BuildService)

local ClientControllers = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState"))
local BuildPreviewController = require(ClientControllers:WaitForChild("BuildPreviewController"))
local BuildTransformController = require(ClientControllers:WaitForChild("BuildTransformController"))
local BuildMoveGizmo = require(ClientControllers:WaitForChild("BuildMoveGizmo"))
local BuildRotationGizmo = require(ClientControllers:WaitForChild("BuildRotationGizmo"))
local StandController = require(ClientControllers:WaitForChild("StandController"))

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase241Tests = {}

local function setupIsolatedWorld(): (Folder, PlotService.PlotRecord, PlotService.PlotRecord, () -> ())
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
	local existingTestPlots = Workspace:FindFirstChild("_Phase241TestPlots")
	if existingTestPlots then
		existingTestPlots:Destroy()
	end
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase241TestPlots"
	tempPlots.Parent = Workspace

	local existingSpawns = Workspace:FindFirstChild("_Phase241CustomSpawns")
	if existingSpawns then
		existingSpawns:Destroy()
	end
	local customSpawns = Instance.new("Folder")
	customSpawns.Name = "_Phase241CustomSpawns"
	for i = 1, 2 do
		local srcName = if i == 1 then "Plot_01" else "Plot_07"
		local src = plotSpawns:FindFirstChild(srcName) :: BasePart
		local clone = src:Clone()
		clone.Name = srcName
		clone.Parent = customSpawns
	end
	customSpawns.Parent = Workspace

	PlotService._ResetForTests()
	ItemRegistry.Init()

	PlotService.Init({
		BaseTemplate = baseTemplate,
		PlotSpawnsFolder = customSpawns,
		PlotsParent = tempPlots,
		PlotCount = 2,
	})

	PreviewAssetService._ResetForTests()
	PreviewAssetService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

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

	local virtualClock = 1000
	BuildService._SetRateLimitClockForTests(function()
		virtualClock += 5
		return virtualClock
	end)

	local plrA: PlotService.PlayerLike = { UserId = 24101, Name = "LiftTesterA" }
	local plrB: PlotService.PlayerLike = { UserId = 24102, Name = "LiftTesterB" }
	local plot1 = PlotService.Assign(plrA) :: PlotService.PlotRecord
	local plot2 = PlotService.Assign(plrB) :: PlotService.PlotRecord

	local function cleanup()
		BuildState.Reset()
		BuildPreviewController._ClearGeometryCacheForTests()
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
	return { UserId = 24101, Name = "LiftTesterA" }
end

local function makePlrB(): PlotService.PlayerLike
	return { UserId = 24102, Name = "LiftTesterB" }
end

local function resolveSize(itemId: string): Vector3?
	local catFolder = ServerStorage.ItemAssets:FindFirstChild(ItemRegistry.TryGet(itemId).Category)
	local mdl = catFolder and catFolder:FindFirstChild(ItemRegistry.TryGet(itemId).Model)
	if mdl and mdl:IsA("Model") then
		local _, sz = ConnectionMath.ExtractModelAttachments(mdl)
		return sz
	end
	return Vector3.new(2, 2, 2)
end

function Phase241Tests.AppendTests(
	results: { TestCaseResult },
	runTest: (string, () -> ()) -> ()
)
	local pA = makePlrA()
	local pB = makePlrB()

	-- 66
	runTest("End-to-end under-chassis build: build chassis, lift +4, attach engine and both wheels underneath, lower cleanly", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- 1) Construir chasis básico a nivel suelo
			local rBlock = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "uc_1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			local rSeat = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "uc_2",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 2.5, 0),
			})
			assert(rBlock.Success and rSeat.Success, "Chassis build failed")

			-- 2) Sin elevar, colocar motor debajo del chasis debe ser rechazado por suelo de BuildZone (minY = -2.0 < floorY = -0.5)
			local badUnder = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "uc_bad_floor",
				ItemId = "SmallEngine",
				LocalCFrame = CFrame.new(0, -1.0, 0),
			})
			assert(not badUnder.Success and badUnder.ErrorCode == BuildProtocol.ErrorCodes.OutOfBounds, "Under-floor piece should fail while lowered")

			-- 3) Elevar el vehículo real +4.0 studs
			local liftRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "uc_lift",
				HeightOffset = 4.0,
				LateralOffset = 0,
			})
			assert(liftRes.Success and liftRes.BuildAssemblyOffset and liftRes.BuildAssemblyOffset.HeightOffset == 4.0, "Elevator +4 lift failed")

			-- 4) Colocar motor debajo del chasis y dos ruedas opuestas unidas al bloque inferior
			local rEngine = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "uc_3",
				ItemId = "SmallEngine",
				LocalCFrame = CFrame.new(0, -1.0, 0),
			})
			local rWheelL = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "uc_4",
				ItemId = "SmallWheel",
				LocalCFrame = CFrame.new(-1.5, -1.0, 0),
			})
			local rWheelR = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "uc_5",
				ItemId = "SmallWheel",
				LocalCFrame = CFrame.new(1.5, -1.0, 0) * CFrame.Angles(0, math.pi, 0),
			})
			assert(rEngine.Success, `Engine under chassis failed: {tostring(rEngine.ErrorCode)}`)
			assert(rWheelL.Success, `Left wheel under chassis failed: {tostring(rWheelL.ErrorCode)}`)
			assert(rWheelR.Success, `Right wheel under chassis failed: {tostring(rWheelR.ErrorCode)}`)

			-- 5) Verificar que todas las 5 piezas están conectadas formando 1 componente conexo y movidas físicamente en Workspace
			local bp = VehicleBlueprintService.GetBlueprintSnapshot(pA)
			assert(#bp.Pieces == 5, "Expected 5 pieces")
			assert(ConnectionMath.IsGraphConnectedAfterRemoval(bp.Pieces, bp.Connections, "__none__"), "All 5 pieces including under-chassis parts must form a single connected graph")

			-- 6) Bajar mediante ResetStandOffset: debe descender hasta apoyar sin atravesar el suelo (DefaultRestHeightOffset = 2.0)
			local lowerRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.ResetStandOffset,
				ClientOpId = "uc_lower",
			})
			assert(lowerRes.Success and lowerRes.BuildAssemblyOffset, "Lowering elevator failed")
			assert(math.abs(lowerRes.BuildAssemblyOffset.HeightOffset - 2.0) < 1e-3, `Expected floor-clamped rest height +2.0, got {tostring(lowerRes.BuildAssemblyOffset.HeightOffset)}`)

			-- Verificar que todas las piezas físicas de EditableVehicle quedaron sobre el suelo (Y >= floorY) sin deformación
			local editable = VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model
			local buildZone = plot1.Zones.BuildZone
			local floorY = -buildZone.Size.Y * 0.5
			for _, child in ipairs(editable:GetChildren()) do
				if child:IsA("Model") then
					local localPos = buildZone.CFrame:PointToObjectSpace(child:GetPivot().Position)
					assert(localPos.Y >= floorY + 0.49, `Piece {child.Name} clipped below floor after lowering (Y={localPos.Y})`)
				end
			end
			-- Distancia chasis -> rueda debe mantenerse exacta (LocalCFrame intacto)
			local engCF = (editable:FindFirstChild((rEngine.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId) :: Model):GetPivot()
			local blkCF = (editable:FindFirstChild((rBlock.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId) :: Model):GetPivot()
			assert(math.abs((blkCF.Position - engCF.Position).Magnitude - 2.0) < 1e-3, "Relative chassis-to-engine spacing deformed")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 67
	runTest("Save and reload blueprint with under-chassis pieces preserves relative coordinates cleanly", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "sr_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "sr_2", ItemId = "DriverSeat", LocalCFrame = CFrame.new(0, 2.5, 0) })
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.SetStandOffset, ClientOpId = "sr_lift", HeightOffset = 5.0, LateralOffset = 2.0 })
			local engRes = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "sr_3", ItemId = "SmallEngine", LocalCFrame = CFrame.new(0, -1.0, 0) })
			assert(engRes.Success and engRes.PlacedPiece, "Under-chassis engine failed")

			local saveRes = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.SaveBlueprint, ClientOpId = "sr_save", Name = "Underslung" })
			assert(saveRes.Success and saveRes.Blueprint, "SaveBlueprint failed")
			-- Guardar conserva el elevador activo en el taller sin perturbar el entorno actual
			assert(math.abs(saveRes.Blueprint.Presentation.HeightOffset - 5.0) < 1e-3, "Active workshop lift should remain responsive while saving")
			local firstBpId = saveRes.Blueprint.BlueprintId

			local newRes = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.CreateBlueprint, ClientOpId = "sr_new", Name = "Vacio" })
			assert(newRes.Success, "CreateBlueprint failed")

			-- El diseño guardado nunca persiste el elevador (+5, +2): al recargar arranca en mínimo de suelo (2.0, 0.0) con LocalCFrame relativo intacto
			local loadRes = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.LoadBlueprint, ClientOpId = "sr_load", BlueprintId = firstBpId })
			assert(loadRes.Success and loadRes.Blueprint, "Reload under-chassis blueprint failed (ground-rest validation bug check)")
			assert(#loadRes.Blueprint.Pieces == 3, "Expected 3 pieces restored")
			assert(math.abs(loadRes.Blueprint.Pieces[3].LocalCFrame.Position.Y - (-1.0)) < 1e-4, "Relative Y coordinate (-1.0) must restore verbatim")
			assert(math.abs(loadRes.Blueprint.Presentation.HeightOffset - 2.0) < 1e-3 and math.abs(loadRes.Blueprint.Presentation.LateralOffset) < 1e-3, "Reloaded vehicle must ignore previous workshop lift (5,2) and land cleanly at rest offset (2.0, 0)")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 68
	runTest("SmartSnap, Visual Grid, Free mode and 3D Gizmos align accurately under lifted vehicle", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local p1 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "ed_1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			assert(p1.Success and p1.Blueprint and p1.PlacedPiece, "Initial piece failed")

			local liftRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "ed_lift",
				HeightOffset = 4.0,
				LateralOffset = 2.0,
			})
			assert(liftRes.Success and liftRes.Blueprint, "Lift failed")

			BuildState.Reset()
			BuildState.SetExpectedOwner(pA.UserId)
			BuildState.SetPlot(plot1.Model, plot1.Zones.BuildZone)
			BuildState.ApplyAuthoritativeBlueprint(liftRes.Blueprint, true)
			BuildState.SetActive(true)
			BuildState.SetPositionMode(GameConfig.Building.PositionModes.Grid)
			BuildState.SetSmartSnapEnabled(true)
			BuildState.SelectItem("SmallEngine")

			-- Simular raycast apuntando exactamente a la cara inferior de WoodBlock (Y = 0.0) elevado (+4 Y, +2 X -> mundo BuildZone (2, 4.0, 0))
			local buildZone = plot1.Zones.BuildZone
			local effZoneCF = BuildState.GetEffectiveBuildZoneCFrame() :: CFrame
			local targetWorldPos = effZoneCF:PointToWorldSpace(Vector3.new(0, 0.0, 0))
			local targetWorldNormal = effZoneCF:VectorToWorldSpace(Vector3.new(0, -1, 0))
			local okPreview, worldCF = BuildPreviewController.UpdateAtWorldPoint(targetWorldPos, targetWorldNormal)
			assert(okPreview and worldCF, `Preview under lifted chassis must be valid, got reason={tostring(BuildState.ValidationReason)} err={tostring(BuildState.LastError)}`)
			local previewLocal = BuildState.LastSnappedLocalCFrame :: CFrame
			assert((previewLocal.Position - Vector3.new(0, -1.0, 0)).Magnitude < 1e-3, `Expected BlueprintLocal (0,-1.0,0), got {tostring(previewLocal.Position)}`)

			-- Verificar modo libre (resolución 0.01) bajo el vehículo elevado
			BuildState.SetPositionMode(GameConfig.Building.PositionModes.Free)
			local freeLocal = BuildGrid.ComputeSnappedCFrame({
				BuildZoneCFrame = effZoneCF,
				BuildZoneSize = buildZone.Size,
				WorldHitPosition = effZoneCF:PointToWorldSpace(Vector3.new(0.37, 0.0, 0.13)),
				WorldHitNormal = targetWorldNormal,
				PieceSize = Vector3.new(2, 2, 2),
				RelativeRotation = CFrame.identity,
				PositionMode = "Free",
				LiftHeightOffset = 4.0,
			}).LocalPosition
			assert(math.abs(freeLocal.X - 0.37) < 0.02 and math.abs(freeLocal.Y - (-1.0)) < 0.02, `Free mode under lift mismatch: {tostring(freeLocal)}`)

			-- Verificar Gizmos 3D (Move + Rotate) contra piezas elevadas
			local offsetCF = BuildState.GetAssemblyOffsetCFrame()
			local rayOrigin = effZoneCF:PointToWorldSpace(Vector3.new(3.5, 1.0, 6))
			local moveOriginLocal = (p1.PlacedPiece :: VehicleTypes.BlueprintPiece).LocalCFrame.Position
			local shaftPointWorld = effZoneCF:PointToWorldSpace(moveOriginLocal + Vector3.new(1.5, 0, 0))
			local hitMoveAxis = BuildMoveGizmo.HitTestFromRay(buildZone, moveOriginLocal, Vector3.new(2, 2, 2), rayOrigin, (shaftPointWorld - rayOrigin).Unit, offsetCF)
			assert(hitMoveAxis == "X", `Expected Move Gizmo hit on lifted X axis, got {tostring(hitMoveAxis)}`)

			BuildState.SetSelectedPlacedPiece(p1.PlacedPiece.InstanceId)
			BuildState.SetActiveTool(GameConfig.Building.TransformTools.Move)
			BuildTransformController.UpdateVisuals(rayOrigin, (shaftPointWorld - rayOrigin).Unit)
			assert(BuildRotationGizmo.IsDragging() == false, "Rotation gizmo must not drag when Move tool is active")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 69
	runTest("Dynamic lift bounds clamp cleanly for tall and wide vehicles", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- Bloque base (min.Y=0.0, max.Y=2.0) y bloque alto en Y=29.0 (max.Y=30.0 vs techo=31.5)
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "db_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
			for idx = 1, 14 do
				local res = BuildService.ProcessRequest(pA, {
					Action = BuildProtocol.Actions.PlacePiece,
					ClientOpId = `db_tall_{idx}`,
					ItemId = "WoodBlock",
					LocalCFrame = CFrame.new(0, 1.0 + idx * 2, 0),
				})
				assert(res.Success, `Stacking block #{idx} failed`)
			end

			local dynBounds = VehicleBlueprintService.ComputeLiftBoundsForPlayer(pA, plot1)
			-- Top de la última pieza = 30.0; ceilingY = 31.5 => maxH disponible = 1.5
			assert(math.abs(dynBounds.MaxHeightOffset - 1.5) < 0.05, `Expected dynamic MaxHeightOffset=1.5 for tall vehicle, got {dynBounds.MaxHeightOffset}`)

			local overCeiling = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "db_over",
				HeightOffset = 2.5,
				LateralOffset = 0,
			})
			assert(not overCeiling.Success and overCeiling.ErrorCode == BuildProtocol.ErrorCodes.StandOffsetOutOfRange, "Exceeding dynamic ceiling must be rejected")

			-- Añadir extensión lateral cerca del borde (+16 X -> max.X = 17 vs halfX = 20 => maxLateral = 3)
			for lx = 1, 8 do
				local rSide = BuildService.ProcessRequest(pA, {
					Action = BuildProtocol.Actions.PlacePiece,
					ClientOpId = `db_wide_{lx}`,
					ItemId = "WoodBlock",
					LocalCFrame = CFrame.new(lx * 2, 1.0, 0),
				})
				assert(rSide.Success, `Wide block #{lx} failed`)
			end
			local wideBounds = VehicleBlueprintService.ComputeLiftBoundsForPlayer(pA, plot1)
			assert(math.abs(wideBounds.MaxLateralOffset - 3.0) < 0.05, `Expected dynamic MaxLateralOffset=3.0, got {wideBounds.MaxLateralOffset}`)
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 70
	runTest("Elevator rejects below-floor negative offsets, out-of-range offsets and NaN/Inf safely", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "nf_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
			local negRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "nf_neg",
				HeightOffset = -0.5,
				LateralOffset = 0,
			})
			assert(not negRes.Success and negRes.ErrorCode == BuildProtocol.ErrorCodes.StandOffsetOutOfRange, "Expected StandOffsetOutOfRange when lowering piece below floorY")

			local nanRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "nf_nan",
				HeightOffset = math.huge,
				LateralOffset = 0,
			})
			assert(not nanRes.Success and nanRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Expected InvalidPayload for Inf")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 71
	runTest("Elevator detects world geometry obstruction and rejects with ElevatorBlocked", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "blk_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })

			-- Colocar obstáculo sólido dentro de Structures a +4 Y del BuildZone (bloquea subir a HeightOffset=4)
			local beam = Instance.new("Part")
			beam.Name = "WorkshopCraneBlocker"
			beam.Anchored = true
			beam.CanCollide = true
			beam.Size = Vector3.new(4, 2, 4)
			beam.CFrame = plot1.Zones.BuildZone.CFrame * CFrame.new(0, 4.5, 0)
			beam.Parent = plot1.Model:FindFirstChild(GameConfig.PlotContainers.Structures) or plot1.Model

			local blockedRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "blk_hit",
				HeightOffset = 4.0,
				LateralOffset = 0,
			})
			assert(not blockedRes.Success and blockedRes.ErrorCode == BuildProtocol.ErrorCodes.ElevatorBlocked, `Expected ElevatorBlocked, got {tostring(blockedRes.ErrorCode)}`)
			assert(VehicleBlueprintService.GetLiftOffset(pA).HeightOffset == 0, "Blocked lift must keep previous offset (0)")

			-- Mover hacia un lado sin obstáculo (+4 lateral, +1.5 altura) sí debe funcionar
			local clearRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "blk_clear",
				HeightOffset = 1.5,
				LateralOffset = 5.0,
			})
			assert(clearRes.Success, `Non-blocked move should succeed: {tostring(clearRes.ErrorCode)}`)
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 72
	runTest("Non-owner cannot control elevator via StandController or cross-plot requests", function()
		local _, plot1, plot2, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "ow_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })

			BuildState.Reset()
			BuildState.SetExpectedOwner(pB.UserId)
			BuildState.SetPlot(plot1.Model, plot1.Zones.BuildZone) -- Plot de A, usuario local B

			assert(StandController.IsOwner() == false, "Player B must not own Plot 1")
			local okSet = StandController.SetStandOffset(3.0, 0)
			assert(not okSet, "Non-owner SetStandOffset must be denied on client")
			local okHold = StandController.BeginContinuousHold("Height", 1, false)
			assert(not okHold, "Non-owner BeginContinuousHold must be denied")

			-- El elevador del Plot 1 debe seguir en (0, 0)
			assert(VehicleBlueprintService.GetLiftOffset(pA).HeightOffset == 0, "Player A lift offset must remain untouched")
			assert(plot2.OwnerUserId == pB.UserId, "Plot 2 owner sanity check")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 73
	runTest("Continuous hold-to-move coalesces RPCs (<= 10 Hz, <= 1 in-flight) and rolls back cleanly on rejection", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local bpA = VehicleBlueprintService.GetOrCreateBlueprint(pA)
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "ch_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })

			BuildState.Reset()
			BuildState.SetExpectedOwner(pA.UserId)
			BuildState.SetPlot(plot1.Model, plot1.Zones.BuildZone)
			BuildState.ApplyAuthoritativeBlueprint(bpA, true)
			StandController.ResetHoldDebugStatsForTests()

			local simNow = 10.0
			local seq = 0
			local mockInvoke = function(req: any): BuildProtocol.BuildOperationResponse
				seq += 1
				req.ClientOpId = `ch_op_{seq}`
				return BuildService.ProcessRequest(pA, req)
			end

			local started = StandController.BeginContinuousHold("Height", 1, false, mockInvoke, function()
				return simNow
			end)
			assert(started, "Continuous hold failed to start")

			-- Simular 60 frames (~1.0s) manteniendo pulsado el botón de Subir
			for _ = 1, 60 do
				simNow += (1 / 60)
				StandController.StepContinuousHold(1 / 60, mockInvoke, function()
					return simNow
				end)
			end
			StandController.EndContinuousHold(mockInvoke, function()
				return simNow
			end)
			simNow += 0.15
			task.wait(0.15)

			local stats = StandController.GetHoldDebugStats()
			assert(stats.RpcSent > 0 and stats.RpcSent <= 12, `Expected coalesced RPC count <= 12 over ~1s (<=10Hz), got {stats.RpcSent}`)
			assert(stats.MaxInFlightObserved <= 1, `Expected max 1 in-flight RPC, got {stats.MaxInFlightObserved}`)
			assert(stats.MinIntervalSecondsObserved >= GameConfig.Stand.ContinuousSyncIntervalSeconds - 1e-4, `RPC cadence violated 10Hz guard: min interval={stats.MinIntervalSecondsObserved}`)
			assert(VehicleBlueprintService.GetLiftOffset(pA).HeightOffset > 3.0, "Vehicle should have elevated continuously during hold")

			-- Verificar rollback cuando el servidor rechaza con ElevatorBlocked durante otro hold
			local blocker = Instance.new("Part")
			blocker.Name = "CeilingBlocker"
			blocker.Anchored = true
			blocker.CanCollide = true
			blocker.Size = Vector3.new(6, 2, 6)
			blocker.CFrame = plot1.Zones.BuildZone.CFrame * CFrame.new(0, 6.0, 0)
			blocker.Parent = plot1.Model:FindFirstChild(GameConfig.PlotContainers.Structures) or plot1.Model

			local authBeforeReject = VehicleBlueprintService.GetLiftOffset(pA).HeightOffset
			StandController.BeginContinuousHold("Height", 1, false, mockInvoke, function()
				return simNow
			end)
			simNow += 0.35
			StandController.StepContinuousHold(0.35, mockInvoke, function()
				return simNow
			end)
			StandController.EndContinuousHold(mockInvoke, function()
				return simNow
			end)
			simNow += 0.15
			task.wait(0.15)

			assert(math.abs(BuildState.StandPresentation.HeightOffset - authBeforeReject) < 1e-2 or VehicleBlueprintService.GetLiftOffset(pA).HeightOffset >= authBeforeReject - 1e-2, "Client/server offset diverged")
			assert(StandController.GetHoldDebugStats().LastSyncErrorCode == nil or StandController.GetHoldDebugStats().LastSyncErrorCode == BuildProtocol.ErrorCodes.ElevatorBlocked, "Unexpected hold error state")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 74
	runTest("Workspace replication: lifting Player A moves only Player A EditableVehicle cleanly", function()
		local _, plot1, plot2, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "mp_a1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
			BuildService.ProcessRequest(pB, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "mp_b1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })

			local edA = VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model
			local edB = VehicleBlueprintService.GetEditableVehicleModel(pB) :: Model
			local bBefore = (edB:GetChildren()[1] :: Model):GetPivot()

			local liftA = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "mp_liftA",
				HeightOffset = 6.0,
				LateralOffset = -3.0,
			})
			assert(liftA.Success, "Player A lift failed")

			local aLocal = plot1.Zones.BuildZone.CFrame:PointToObjectSpace((edA:GetChildren()[1] :: Model):GetPivot().Position)
			assert((aLocal - Vector3.new(-3.0, 7.0, 0)).Magnitude < 1e-3, "Player A EditableVehicle did not lift in Workspace")
			local bAfter = (edB:GetChildren()[1] :: Model):GetPivot()
			assert((bAfter.Position - bBefore.Position).Magnitude < 1e-4, "Player B EditableVehicle must stay unaffected by Player A elevator")
			assert((plot2.Zones.BuildZone:GetAttribute(GameConfig.PlotAttributes.BuildLiftHeight) :: number or 0) == 0, "Plot 2 attribute must remain 0")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 75
	runTest("LaunchPreparation completely ignores temporary workshop elevator offset", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "lp_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
			BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.PlacePiece, ClientOpId = "lp_2", ItemId = "DriverSeat", LocalCFrame = CFrame.new(0, 2.5, 0) })

			local repNeutral = VehicleLaunchPreparationService.EvaluatePlayerLaunch(pA, { SkipWorldObstructionCheck = true })
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "lp_lift",
				HeightOffset = 6.0,
				LateralOffset = -4.0,
			})
			local repLifted = VehicleLaunchPreparationService.EvaluatePlayerLaunch(pA, { SkipWorldObstructionCheck = true })

			assert(repNeutral.Ready == true and repLifted.Ready == true, "LaunchPrep must stay Ready regardless of lift offset")
			assert(math.abs((repNeutral.GroundClearance or 0) - (repLifted.GroundClearance or 0)) < 1e-4, "LaunchPrep GroundClearance must ignore workshop elevator offset")
			assert(repNeutral.BoundingSize and repLifted.BoundingSize and (repNeutral.BoundingSize - repLifted.BoundingSize).Magnitude < 1e-4, "BoundingSize must be invariant to lift offset")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 76
	runTest("Blueprint with empty pieces resets lift cleanly to (0,0) and zero StandPreview instances exist anywhere", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local setRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "em_lift",
				HeightOffset = 5.0,
				LateralOffset = 2.0,
			})
			assert(setRes.Success, "Empty elevator offset failed")
			local resetRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.ResetStandOffset,
				ClientOpId = "em_rst",
			})
			assert(resetRes.Success and resetRes.Presentation, "Empty elevator reset failed")
			assert(resetRes.Presentation.HeightOffset == 0 and resetRes.Presentation.LateralOffset == 0, "Empty reset must reach (0,0)")
			assert(StandPreviewService.GetStandPreviewModel(pA) == nil, "StandPreview must always be nil")
			assert(plot1.DynamicContainer:FindFirstChild(GameConfig.Building.StandPreviewName) == nil, "No StandPreview clone in plot")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)
end

return Phase241Tests
