--!strict
--[=[
	Phase24Tests
	Suite de 25 pruebas automatizadas de Fase 2.4 (Blueprints versionados, Stand editable,
	StandPreview estático, VehicleLaunchPreparation, seguridad y concurrencia).
	Se integra en Phase1Tests.RunAll() manteniendo las 40 pruebas previas intactas (total 65).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
local VehicleCoordinateMath = require(ReplicatedStorage.Shared.Building.VehicleCoordinateMath)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local PlotService = require(ServerScriptService.Server.Services.PlotService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local StandPreviewService = require(ServerScriptService.Server.Services.StandPreviewService)
local VehicleLaunchPreparationService = require(ServerScriptService.Server.Services.VehicleLaunchPreparationService)
local BuildService = require(ServerScriptService.Server.Services.BuildService)

local ClientControllers = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
local BuildState = require(ClientControllers:WaitForChild("BuildState"))
local BuildPlacementController = require(ClientControllers:WaitForChild("BuildPlacementController"))
local BlueprintManagerController = require(ClientControllers:WaitForChild("BlueprintManagerController"))
local StandController = require(ClientControllers:WaitForChild("StandController"))

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

local Phase24Tests = {}

local function setupIsolatedWorld(): (Folder, PlotService.PlotRecord, PlotService.PlotRecord, () -> ())
	local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
	local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
	local tempPlots = Instance.new("Folder")
	tempPlots.Name = "_Phase24TestPlots"
	tempPlots.Parent = Workspace

	local prevPlots = Workspace:FindFirstChild("_Phase24TestPlots")
	if prevPlots and prevPlots ~= tempPlots then
		prevPlots:Destroy()
	end

	-- Crear clones de PlotSpawns con Plot_07 rotado para probar invarianza en estaciones rotadas
	local customSpawns = Instance.new("Folder")
	customSpawns.Name = "_Phase24CustomSpawns"
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

	local plrA: PlotService.PlayerLike = { UserId = 24001, Name = "TestBuilderA" }
	local plrB: PlotService.PlayerLike = { UserId = 24002, Name = "TestBuilderB" }
	local plot1 = PlotService.Assign(plrA) :: PlotService.PlotRecord
	local plot2 = PlotService.Assign(plrB) :: PlotService.PlotRecord

	local function cleanup()
		BuildState.Reset()
		BuildPlacementController.ClearPending()
		BuildService._ResetForTests()
		VehicleLaunchPreparationService._ResetForTests()
		StandPreviewService._ResetForTests()
		VehicleBlueprintService._ResetForTests()
		InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = false })
		ConnectionService._ResetForTests()
		PlotService._ResetForTests()
		for _, child in ipairs(Workspace:GetChildren()) do
			if child.Name == "BlockingCrate" then
				child:Destroy()
			end
		end
		tempPlots:Destroy()
		customSpawns:Destroy()
	end

	return tempPlots, plot1, plot2, cleanup
end

local function makeTestPlayerA(): PlotService.PlayerLike
	return { UserId = 24001, Name = "TestBuilderA" }
end

local function makeTestPlayerB(): PlotService.PlayerLike
	return { UserId = 24002, Name = "TestBuilderB" }
end

function Phase24Tests.AppendTests(
	results: { TestCaseResult },
	runCase: (name: string, fn: () -> ()) -> ()
)
	local pA = makeTestPlayerA()
	local pB = makeTestPlayerB()

	-- 41
	runCase("Blueprint schema v1 serializes and migrates legacy v0 cleanly", function()
		local fracCF = CFrame.new(1.37, 2.55, -0.83) * CFrame.Angles(0, math.rad(15), 0)
		local bp: VehicleTypes.VehicleBlueprint = {
			SchemaVersion = 1,
			BlueprintId = "bp_test_v1",
			OwnerUserId = 123,
			Name = "Mi Vehiculo Frac",
			Revision = 4,
			CreatedAt = 1000,
			UpdatedAt = 1050,
			VehicleOrigin = CFrame.new(0, 0.5, 0),
			Presentation = { HeightOffset = 2.5, LateralOffset = -1.25 },
			Metadata = { SourceBlueprintId = "bp_orig" },
			Pieces = {
				{
					InstanceId = "piece_123_1",
					ItemId = "WoodBlock",
					LocalCFrame = fracCF,
					Config = { Custom = "abc" },
				},
			},
			Connections = {},
		}

		local serialized = BlueprintSerializer.SerializeBlueprint(bp)
		assert(serialized.SchemaVersion == 1, "SchemaVersion must serialize as 1")
		assert(type(serialized.Pieces[1].LocalCFrame) == "table" and #serialized.Pieces[1].LocalCFrame == 12, "CFrame must serialize to 12 numbers")

		local ok, restored, err = BlueprintSerializer.DeserializeBlueprint(serialized, 123)
		assert(ok and restored, "Deserialize failed: " .. tostring(err))
		assert(restored.Name == "Mi Vehiculo Frac", "Name mismatch")
		assert((restored.Pieces[1].LocalCFrame.Position - fracCF.Position).Magnitude < 1e-4, "Fractional position lost")
		assert((restored.Pieces[1].LocalCFrame.LookVector - fracCF.LookVector).Magnitude < 1e-4, "Angle lost")
		assert(math.abs(restored.Presentation.HeightOffset - 2.5) < 1e-4, "Presentation height lost")

		-- Legacy v0 sin SchemaVersion, Name, Presentation, VehicleOrigin
		local legacyRaw = {
			BlueprintId = "bp_legacy",
			OwnerUserId = 999,
			Revision = 2,
			Pieces = {
				{
					InstanceId = "piece_999_1",
					ItemId = "WoodBlock",
					LocalCFrame = CFrame.new(0, 0.5, 0),
				},
			},
			Connections = {},
		}
		local okLeg, legBp, legErr = BlueprintSerializer.DeserializeBlueprint(legacyRaw, 123)
		assert(okLeg and legBp, "Legacy migration failed: " .. tostring(legErr))
		assert(legBp.SchemaVersion == GameConfig.Blueprints.CurrentSchemaVersion, "Migrated SchemaVersion must equal current")
		assert(legBp.OwnerUserId == 123, "Target owner override must apply")
		assert(legBp.Presentation.HeightOffset == 0 and legBp.Presentation.LateralOffset == 0, "Default presentation expected")
	end)

	-- 42
	runCase("BlueprintSerializer rejects invalid SchemaVersion, NaN CFrames, and duplicate IDs", function()
		local badVersion = { SchemaVersion = 999, BlueprintId = "b1", OwnerUserId = 1, Pieces = {} }
		local ok1 = BlueprintSerializer.DeserializeBlueprint(badVersion)
		assert(not ok1, "Should reject future SchemaVersion")

		local nanNum = 0 / 0
		local badNan = {
			SchemaVersion = 1,
			BlueprintId = "b1",
			OwnerUserId = 1,
			Pieces = {
				{ InstanceId = "p1", ItemId = "WoodBlock", LocalCFrame = { nanNum, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
			},
		}
		local ok2 = BlueprintSerializer.DeserializeBlueprint(badNan)
		assert(not ok2, "Should reject NaN CFrame components")

		local dupPiece = {
			SchemaVersion = 1,
			BlueprintId = "b1",
			OwnerUserId = 1,
			Pieces = {
				{ InstanceId = "dup", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 0.5, 0) },
				{ InstanceId = "dup", ItemId = "WoodBlock", LocalCFrame = CFrame.new(2, 0.5, 0) },
			},
		}
		local ok3 = BlueprintSerializer.DeserializeBlueprint(dupPiece)
		assert(not ok3, "Should reject duplicate piece InstanceId")
	end)

	-- 43
	runCase("VehicleCoordinateMath preserves designs identically between Plot_01 and rotated Plot_07", function()
		local _, plot1, plot2, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- Construir en plot1 desplazado a X=4.25, Z=-2.75
			local res1 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "rot_1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(4.25, 1.0, -2.75),
			})
			assert(res1.Success, "Place 1 failed: " .. tostring(res1.ErrorMessage))
			local bp = VehicleBlueprintService.GetBlueprintSnapshot(pA)

			local function sizeOf(itemId: string): Vector3?
				local g = ConnectionService.GetItemGeometry(itemId)
				return if g then g.Size else nil
			end

			local bounds = VehicleCoordinateMath.ComputeVehicleBounds(bp.Pieces, sizeOf)
			assert(bounds.Valid, "Bounds must be valid")
			assert((bounds.Center - Vector3.new(4.25, 1.0, -2.75)).Magnitude < 1e-4, "Center mismatch")
			assert((bounds.BaseAnchorCFrame.Position - Vector3.new(4.25, 0.0, -2.75)).Magnitude < 1e-4, "BaseAnchor should sit on min.Y")

			-- Verificar Stand en Plot_07 rotado 90°
			local anchor1 = StandPreviewService.GetStandAnchorCFrame(plot1)
			local anchor2 = StandPreviewService.GetStandAnchorCFrame(plot2)
			local pres = { HeightOffset = 1.5, LateralOffset = 2.0 }

			local standPos1 = VehicleCoordinateMath.BlueprintPieceToStandWorld(bp.Pieces[1].LocalCFrame, bounds.BaseAnchorCFrame, anchor1, pres)
			local standPos2 = VehicleCoordinateMath.BlueprintPieceToStandWorld(bp.Pieces[1].LocalCFrame, bounds.BaseAnchorCFrame, anchor2, pres)

			local rel1 = anchor1:ToObjectSpace(standPos1)
			local rel2 = anchor2:ToObjectSpace(standPos2)
			assert((rel1.Position - rel2.Position).Magnitude < 1e-3, "Relative stand transform must match across rotated plots")
			assert((rel1.Position - Vector3.new(2.0, 2.5, 0)).Magnitude < 1e-3, "Expected height (1.5+1.0=2.5) and lateral (2.0)")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 44
	runCase("SaveBlueprint manages 3 initially-empty slots and enforces MaxSavedBlueprintsPerPlayer", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local maxAllowed = GameConfig.Blueprints.MaxSavedBlueprintsPerPlayer
			-- Fase 4.2.1: jugador nuevo inicia con 0 vehículos guardados y 3 tarjetas vacías
			assert(VehicleBlueprintService.GetSavedBlueprintCount(pA) == 0, "Initial saved count must be 0")
			local initialSlots = VehicleBlueprintService.GetBlueprintSlotSummaries(pA)
			assert(#initialSlots == maxAllowed, `Expected {maxAllowed} blueprint slots`)
			for idx = 1, maxAllowed do
				assert(initialSlots[idx].SlotIndex == idx and initialSlots[idx].State == "Empty", `Slot {idx} must start Empty`)
			end

			-- Construir al menos una pieza en el taller antes de guardar en slots
			local placeRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "slot44_p1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			assert(placeRes.Success, "Starter PlacePiece failed")

			for i = 1, maxAllowed do
				local r = BuildService.ProcessRequest(pA, {
					Action = BuildProtocol.Actions.SaveBlueprint,
					ClientOpId = `sv_{i}`,
					Name = `Slot_{i}`,
					SaveAsNew = true,
				})
				assert(r.Success, `SaveBlueprint #{i} failed: {tostring(r.ErrorCode)}`)
			end
			assert(VehicleBlueprintService.GetSavedBlueprintCount(pA) == maxAllowed, "Should reach exact MaxSavedBlueprintsPerPlayer")

			local slotsAfterSave = VehicleBlueprintService.GetBlueprintSlotSummaries(pA)
			for idx = 1, maxAllowed do
				assert(slotsAfterSave[idx].State == "Saved", `Slot {idx} must be Saved`)
			end

			local rOver = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = "sv_over",
				Name = "OverLimit",
				SaveAsNew = true,
			})
			assert(not rOver.Success and rOver.ErrorCode == BuildProtocol.ErrorCodes.MaxBlueprintsReached, "Should reject exceeding 3-slot limit")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 45
	runCase("SaveBlueprint isolates SavedBlueprints from subsequent ActiveBlueprint mutations", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "s_p1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "s_p2",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 2.5, 0),
			})

			local saveRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = "s_save",
				Name = "AutoV1",
			})
			assert(saveRes.Success and saveRes.BlueprintId, "Save failed")
			assert(not saveRes.HasUnsavedChanges, "After Save, HasUnsavedChanges must be false")

			-- Continuar editando ActiveBlueprint SIN guardar
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "s_p3",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(2, 1.0, 0),
			})
			assert(VehicleBlueprintService.GetPieceCount(pA) == 3, "ActiveBlueprint must have 3 pieces")
			assert(VehicleBlueprintService.HasUnsavedChanges(pA), "ActiveBlueprint should be dirty after edit")

			local savedSnap = VehicleBlueprintService.GetSavedBlueprintSnapshot(pA, saveRes.BlueprintId :: string) :: VehicleTypes.VehicleBlueprint
			assert(#savedSnap.Pieces == 2, "SavedBlueprint must remain at 2 pieces until explicitly saved again")

			-- Recargar SavedBlueprint descarta la edición no guardada
			local reloadRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.LoadBlueprint,
				ClientOpId = "s_reload",
				BlueprintId = saveRes.BlueprintId,
			})
			assert(reloadRes.Success, "Reload failed")
			assert(VehicleBlueprintService.GetPieceCount(pA) == 2, "Reloading should revert to saved 2 pieces")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 46
	runCase("DuplicateBlueprint isolates copy completely from future edits on source", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "d_p1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			local saveRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = "d_save",
				Name = "Original",
			})
			local origId = saveRes.BlueprintId :: string

			local dupRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.DuplicateBlueprint,
				ClientOpId = "d_dup",
				BlueprintId = origId,
				Name = "Copia Independiente",
			})
			assert(dupRes.Success and dupRes.DuplicatedBlueprint, "Duplicate failed")
			local dupId = dupRes.DuplicatedBlueprint.BlueprintId

			-- Modificar diseño original y volver a guardarlo
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "d_p2",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(2, 1.0, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = "d_save2",
			})

			local origSaved = VehicleBlueprintService.GetSavedBlueprintSnapshot(pA, origId) :: VehicleTypes.VehicleBlueprint
			local dupSaved = VehicleBlueprintService.GetSavedBlueprintSnapshot(pA, dupId) :: VehicleTypes.VehicleBlueprint
			assert(#origSaved.Pieces == 2, "Original should now have 2 pieces")
			assert(#dupSaved.Pieces == 1, "Duplicated blueprint must still have only 1 piece")
			assert(dupSaved.Metadata and dupSaved.Metadata.SourceBlueprintId == origId, "Metadata should trace source ID")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 47
	runCase("LoadBlueprint preserves fractional positions and 0.1-stud offsets without loss", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- Colocar con coordenada fraccional de precisión libre/fina
			local targetCF = CFrame.new(1.35, 1.0, -2.15)
			local placeRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "f_p1",
				ItemId = "WoodBlock",
				LocalCFrame = targetCF,
			})
			assert(placeRes.Success, "Fractional placement failed: " .. tostring(placeRes.ErrorMessage))
			local saveRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = "f_s1",
				Name = "Fraccional",
			})
			local fracBpId = saveRes.BlueprintId :: string

			-- Cambiar a nuevo diseño y volver al anterior
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.CreateBlueprint,
				ClientOpId = "f_cr",
				Name = "Vacio",
			})
			assert(#(VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model):GetChildren() == 0, "EditableVehicle must be empty on new blueprint")

			local loadRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.LoadBlueprint,
				ClientOpId = "f_ld",
				BlueprintId = fracBpId,
			})
			assert(loadRes.Success and loadRes.Blueprint, "Load failed")
			local loadedPos = loadRes.Blueprint.Pieces[1].LocalCFrame.Position
			assert((loadedPos - targetCF.Position).Magnitude < 1e-4, "Fractional position must survive Create/Load roundtrip")

			local editable = VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model
			assert(#editable:GetChildren() == 1, "EditableVehicle must rebuild 1 piece on Load")
			local pieceModel = editable:GetChildren()[1] :: Model
			local expectedWorld = plot1.Zones.BuildZone.CFrame:ToWorldSpace(targetCF)
			assert((pieceModel:GetPivot().Position - expectedWorld.Position).Magnitude < 1e-3, "Editable piece world pos mismatch")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 48
	runCase("LoadBlueprint rolls back atomically when candidate blueprint is invalid", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- Diseñar vehículo válido en slot 1
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "rb_p1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			local save1 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = "rb_s1",
				Name = "Valido",
			})
			local validId = save1.BlueprintId :: string

			-- Intentar importar un blueprint corrupto con pieza inexistente
			local okImp, _, errCode = VehicleBlueprintService.ImportSerializedBlueprint(pA, nil, {
				SchemaVersion = 1,
				BlueprintId = "bp_corrupt",
				OwnerUserId = pA.UserId,
				Name = "Corrupto",
				Revision = 1,
				Pieces = {
					{ InstanceId = "bad_1", ItemId = "NonExistentPartXYZ", LocalCFrame = CFrame.new(0, 0.5, 0) },
				},
				Connections = {},
			})
			assert(not okImp and errCode == BuildProtocol.ErrorCodes.UnknownItem, "Should reject corrupt itemId")
			assert(VehicleBlueprintService.GetOrCreateBlueprint(pA).BlueprintId == validId, "ActiveBlueprint must remain unchanged on failure")
			assert(#(VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model):GetChildren() == 1, "EditableVehicle must stay intact")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 49
	runCase("RenameBlueprint validates names and updates active & saved entries", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local bp = VehicleBlueprintService.GetOrCreateBlueprint(pA)
			local bad1 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.RenameBlueprint,
				ClientOpId = "rn_bad1",
				BlueprintId = bp.BlueprintId,
				Name = "    ",
			})
			assert(not bad1.Success, "Whitespace-only name must fail")

			local bad2 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.RenameBlueprint,
				ClientOpId = "rn_bad2",
				BlueprintId = bp.BlueprintId,
				Name = "Bad\nName",
			})
			assert(not bad2.Success, "Control char name must fail")

			local good = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.RenameBlueprint,
				ClientOpId = "rn_good",
				BlueprintId = bp.BlueprintId,
				Name = "  Camion Cohete  ",
			})
			assert(good.Success and good.Blueprint, "Valid rename should succeed")
			assert(good.Blueprint.Name == "Camion Cohete", "Name must be trimmed cleanly")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 50
	runCase("DeleteBlueprint allows deleting last saved blueprint leaving 3 empty slots without affecting workshop or inventory", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			EngineInventoryService.ClearForPlayer(pA)
			local units = EngineInventoryService.EnsureControlledWorkshopUnits(pA)
			assert(#units >= 1, "Expected starter workshop engine unit")
			local unitId = units[1].ItemInstanceId
			local initialUnitCount = #units

			local p1Res = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "del50_p1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			assert(p1Res.Success, "WoodBlock placement failed")
			local p2Res = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "del50_p2",
				ItemId = "SmallEngine",
				LocalCFrame = CFrame.new(0, 1.0, 2.0),
				InventoryInstanceId = unitId,
			})
			assert(p2Res.Success, "SmallEngine placement failed")

			local saveRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = "del50_save",
				Name = "UnicoGuardado",
			})
			assert(saveRes.Success and saveRes.BlueprintId, "SaveBlueprint failed")
			local savedBpId = saveRes.BlueprintId :: string
			assert(VehicleBlueprintService.GetSavedBlueprintCount(pA) == 1, "Expected 1 saved blueprint before delete")

			-- Agregar una pieza adicional al taller activo (queda como borrador sin guardar)
			local p3Res = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "del50_p3",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(2.0, 1.0, 0),
			})
			assert(p3Res.Success, "Extra WoodBlock placement failed")

			-- Fase 4.2.1: eliminar el último blueprint guardado está permitido y deja 3 tarjetas vacías
			local delLast = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.DeleteBlueprint,
				ClientOpId = "del_last",
				BlueprintId = savedBpId,
			})
			assert(delLast.Success, `Must allow deleting last saved blueprint: {tostring(delLast.ErrorCode)}`)
			assert(VehicleBlueprintService.GetSavedBlueprintCount(pA) == 0, "Saved count must drop to 0")

			local slotsAfter = VehicleBlueprintService.GetBlueprintSlotSummaries(pA)
			assert(#slotsAfter == GameConfig.Blueprints.MaxSlots, "Slot list must always keep 3 cards")
			for idx = 1, #slotsAfter do
				assert(slotsAfter[idx].State == "Empty", `Slot {idx} must become Empty`)
			end

			-- El borrador activo del taller y su inventario asociado permanecen intactos
			assert(VehicleBlueprintService.GetPieceCount(pA) == 3, "Workshop draft pieces must remain untouched")
			assert(#(VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model):GetChildren() == 3, "EditableVehicle model must keep all 3 pieces")
			assert(VehicleBlueprintService.HasUnsavedChanges(pA), "Workshop draft with pieces and no matching slot must stay unsaved")
			assert(#EngineInventoryService.GetPlayerUnits(pA) == initialUnitCount, "Inventory unit count must remain intact")
			local unitAfter = EngineInventoryService.GetUnitById(unitId)
			assert(unitAfter ~= nil and unitAfter.OwnerUserId == pA.UserId, "Bound engine inventory unit must remain intact")

			local activeSnap = VehicleBlueprintService.GetBlueprintSnapshot(pA)
			local foundBoundPiece = false
			for _, pc in ipairs(activeSnap.Pieces) do
				if pc.InventoryInstanceId == unitId then
					foundBoundPiece = true
					break
				end
			end
			assert(foundBoundPiece, "Workshop engine piece must retain InventoryInstanceId binding")
		end)
		EngineInventoryService.ClearForPlayer(pA)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 51
	runCase("BaseTemplate.VehicleStand is physically editable and PlotService resolves DisplayAnchor", function()
		local _, plot1, plot2, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local tpl = ServerStorage:WaitForChild("BaseTemplate")
			local tplStand = tpl:FindFirstChild("VehicleStand")
			assert(tplStand and tplStand:IsA("Model"), "Missing BaseTemplate.VehicleStand")
			assert(tplStand:FindFirstChild("Decorations") ~= nil, "Missing Decorations")
			assert(tplStand:FindFirstChild("InteractionPoint") ~= nil, "Missing InteractionPoint")

			assert(plot1.VehicleStand ~= nil and plot1.StandDisplayAnchor ~= nil and plot1.StandInteractionPoint ~= nil, "Plot1 must expose VehicleStand, DisplayAnchor and InteractionPoint")
			assert(plot2.VehicleStand ~= nil and plot2.StandDisplayAnchor ~= nil and plot2.StandInteractionPoint ~= nil, "Plot2 must expose VehicleStand, DisplayAnchor and InteractionPoint")
			assert(plot1.Zones.StandZone ~= nil, "StandZone compatibility must remain intact")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 52
	runCase("Workshop elevator uses only EditableVehicle and never creates duplicate StandPreview", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "sp_1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "sp_2",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 2.5, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "sp_3",
				ItemId = "SmallBooster",
				LocalCFrame = CFrame.new(0, 1.0, 2.5),
			})

			assert(StandPreviewService.GetStandPreviewModel(pA) == nil, "StandPreview model must not exist")
			assert(StandPreviewService.GetTrackedPlayerCount() == 0, "StandPreviewService must track 0 duplicate models")
			assert(plot1.DynamicContainer:FindFirstChild(GameConfig.Building.StandPreviewName) == nil, "DynamicRuntime must not contain StandPreview")

			local editableVehicle = VehicleBlueprintService.GetEditableVehicleModel(pA)
			assert(editableVehicle and editableVehicle.Parent == plot1.DynamicContainer, "EditableVehicle must be active in DynamicRuntime")
			assert(#editableVehicle:GetChildren() == 3, "EditableVehicle must contain 3 pieces")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 53
	runCase("Elevator moves real EditableVehicle inside BuildZone without mutating LocalCFrames or dirty flag", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local origLocalCF = CFrame.new(2, 1.0, 0)
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "so_1",
				ItemId = "WoodBlock",
				LocalCFrame = origLocalCF,
			})
			local saveRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SaveBlueprint,
				ClientOpId = "so_save",
			})
			assert(saveRes.Success, "SaveBlueprint failed")
			assert(not VehicleBlueprintService.HasUnsavedChanges(pA), "Expected clean saved blueprint before lift move")

			local editableModel = VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model
			local pieceBefore = (editableModel:GetChildren()[1] :: Model):GetPivot()

			local setRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "so_set",
				HeightOffset = 3.25,
				LateralOffset = -2.50,
			})
			assert(setRes.Success and setRes.Presentation, "SetStandOffset failed")

			-- Blueprint LocalCFrame y dirty flag no deben mutar al mover el elevador
			local bpAfter = VehicleBlueprintService.GetBlueprintSnapshot(pA)
			assert((bpAfter.Pieces[1].LocalCFrame.Position - origLocalCF.Position).Magnitude < 1e-4, "Blueprint LocalCFrame must not mutate")
			assert(not VehicleBlueprintService.HasUnsavedChanges(pA), "Elevator movement must not mark blueprint dirty")

			-- El EditableVehicle real debe haberse desplazado en espacio de BuildZone (+3.25 Y, -2.50 X)
			local pieceAfter = (editableModel:GetChildren()[1] :: Model):GetPivot()
			local deltaInZone = plot1.Zones.BuildZone.CFrame:VectorToObjectSpace(pieceAfter.Position - pieceBefore.Position)
			assert((deltaInZone - Vector3.new(-2.50, 3.25, 0)).Magnitude < 1e-3, "EditableVehicle lift delta mismatch")
			assert(
				math.abs((plot1.Zones.BuildZone:GetAttribute(GameConfig.PlotAttributes.BuildLiftHeight) :: number) - 3.25) < 1e-4,
				"BuildZone lift height attribute mismatch"
			)

			local resetRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.ResetStandOffset,
				ClientOpId = "so_rst",
			})
			assert(resetRes.Success and resetRes.Presentation, "ResetStandOffset failed")
			assert(resetRes.Presentation.HeightOffset == 0 and resetRes.Presentation.LateralOffset == 0, "Offsets must reset to (0,0)")

			local pieceReset = (editableModel:GetChildren()[1] :: Model):GetPivot()
			assert((pieceReset.Position - pieceBefore.Position).Magnitude < 1e-3, "EditableVehicle must return to original position")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 54
	runCase("Stand offset rejects out-of-range and NaN/Inf spoof values", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local resHigh = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "bad_h",
				HeightOffset = GameConfig.Stand.MaxHeightOffset + 2,
				LateralOffset = 0,
			})
			assert(not resHigh.Success and resHigh.ErrorCode == BuildProtocol.ErrorCodes.StandOffsetOutOfRange, "Expected StandOffsetOutOfRange for HeightOffset")

			local resLat = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "bad_l",
				HeightOffset = 1,
				LateralOffset = GameConfig.Stand.MinLateralOffset - 1,
			})
			assert(not resLat.Success and resLat.ErrorCode == BuildProtocol.ErrorCodes.StandOffsetOutOfRange, "Expected StandOffsetOutOfRange for LateralOffset")

			local resNan = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "bad_nan",
				HeightOffset = 0 / 0,
				LateralOffset = 0,
			})
			assert(not resNan.Success and resNan.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Expected InvalidPayload for NaN")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 55
	runCase("Plot ownership and cross-player blueprint/stand isolation enforced", function()
		local _, plot1, plot2, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local bpA = VehicleBlueprintService.GetOrCreateBlueprint(pA)
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "iso_p1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 0.5, 0),
			})

			-- Jugador B intenta cargar, renombrar, duplicar o borrar blueprint de Jugador A
			local badLoad = BuildService.ProcessRequest(pB, {
				Action = BuildProtocol.Actions.LoadBlueprint,
				ClientOpId = "iso_l",
				BlueprintId = bpA.BlueprintId,
			})
			assert(not badLoad.Success and badLoad.ErrorCode == BuildProtocol.ErrorCodes.BlueprintNotFound, "Player B must not load Player A blueprint")

			local badDup = BuildService.ProcessRequest(pB, {
				Action = BuildProtocol.Actions.DuplicateBlueprint,
				ClientOpId = "iso_d",
				BlueprintId = bpA.BlueprintId,
			})
			assert(not badDup.Success and badDup.ErrorCode == BuildProtocol.ErrorCodes.BlueprintNotFound, "Player B must not duplicate Player A blueprint")

			local badRen = BuildService.ProcessRequest(pB, {
				Action = BuildProtocol.Actions.RenameBlueprint,
				ClientOpId = "iso_r",
				BlueprintId = bpA.BlueprintId,
				Name = "Hacked",
			})
			assert(not badRen.Success and badRen.ErrorCode == BuildProtocol.ErrorCodes.BlueprintNotFound, "Player B must not rename Player A blueprint")

			-- Controlador cliente verifica propiedad del Stand (Plot de A visto por B -> IsOwner false)
			BuildState.Reset()
			BuildState.SetExpectedOwner(pB.UserId)
			BuildState.SetPlot(plot2.Model, plot2.Zones.BuildZone)
			assert(StandController.IsOwner() == true, "B owns Plot 2")
			BuildState.SetPlot(plot1.Model, plot1.Zones.BuildZone)
			assert(StandController.IsOwner() == false, "StandController must deny non-owner controls on Plot A")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 56
	runCase("Plot release cleans up EditableVehicle and elevator state without altering base VehicleStand", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "cl_1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 0.5, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.SetStandOffset,
				ClientOpId = "cl_lift",
				HeightOffset = 2.0,
				LateralOffset = 1.0,
			})
			assert(StandPreviewService.GetStandPreviewModel(pA) == nil, "No StandPreview should ever exist")
			PlotService.Release(pA)
			assert(StandPreviewService.GetStandPreviewModel(pA) == nil, "StandPreview ref must remain nil after release")
			assert(plot1.DynamicContainer:FindFirstChild(GameConfig.Building.StandPreviewName) == nil, "DynamicRuntime StandPreview must not exist")
			assert(plot1.DynamicContainer:FindFirstChild(GameConfig.Building.EditableVehicleName) == nil, "EditableVehicle must be destroyed on release")
			assert(plot1.VehicleStand ~= nil and plot1.VehicleStand.Parent == plot1.Model, "Editable VehicleStand model must stay intact")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 57
	runCase("LaunchPreparation rejects empty vehicle cleanly without spawning runtime", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local res = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.ValidateLaunchPrep,
				ClientOpId = "lp_empty",
			})
			assert(res.Success and res.LaunchPrepReport, "ValidateLaunchPrep RPC failed")
			local report = res.LaunchPrepReport :: VehicleTypes.LaunchPreparationReport
			assert(not report.Ready, "Empty vehicle cannot be ready")
			assert(report.ErrorCategory == "BuildError" and report.PrimaryErrorCode == "EmptyVehicle", "Expected BuildError/EmptyVehicle")
			assert(plot1.DynamicContainer:FindFirstChild("VehicleRuntime") == nil, "Must NEVER create VehicleRuntime in Fase 2.4")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 58
	runCase("LaunchPreparation requires exactly 1 functional DriverSeat (ConfigError)", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- 0 DriverSeats
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "ds_b1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			local r0 = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.ValidateLaunchPrep })
			local rep0 = r0.LaunchPrepReport :: VehicleTypes.LaunchPreparationReport
			assert(not rep0.Ready and rep0.ErrorCategory == "ConfigError" and rep0.PrimaryErrorCode == "MissingDriverSeat", "Expected MissingDriverSeat ConfigError")

			-- En el taller (Fase 4.2.1), el 2.º DriverSeat queda bloqueado directamente en PlacePiece
			local s1Res = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "ds_s1",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 2.5, 0),
			})
			local b2Res = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "ds_b2",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 2),
			})
			assert(s1Res.Success and b2Res.Success, "Single seat setup must succeed")
			local s2Res = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "ds_s2",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 2.5, 2),
			})
			assert(not s2Res.Success and s2Res.ErrorCode == BuildProtocol.ErrorCodes.TooManyDriverSeats, "Workshop rejects 2nd DriverSeat with TooManyDriverSeats")

			-- Defensa en profundidad: LaunchPreparation rechaza un blueprint sintético conectado con 2 DriverSeats
			local twoSeatBp: VehicleTypes.VehicleBlueprint = {
				SchemaVersion = 2,
				BlueprintId = "bp_two_seats",
				OwnerUserId = pA.UserId,
				Name = "TwoSeats",
				Revision = 1,
				CreatedAt = 100,
				UpdatedAt = 100,
				VehicleOrigin = CFrame.identity,
				Presentation = { HeightOffset = 0, LateralOffset = 0 },
				Pieces = {
					{ InstanceId = "b1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) },
					{ InstanceId = "b2", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 2) },
					{ InstanceId = "s1", ItemId = "DriverSeat", LocalCFrame = CFrame.new(0, 2.5, 0) },
					{ InstanceId = "s2", ItemId = "DriverSeat", LocalCFrame = CFrame.new(0, 2.5, 2) },
				},
				Connections = {},
			}
			ConnectionService.ReconcileBlueprintConnections(twoSeatBp)
			local rep2 = VehicleLaunchPreparationService.EvaluateBlueprintLaunch(twoSeatBp, plot1, { SkipWorldObstructionCheck = true })
			assert(not rep2.Ready and rep2.ErrorCategory == "ConfigError" and rep2.PrimaryErrorCode == "MultipleDriverSeats", "Expected MultipleDriverSeats ConfigError")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 59
	runCase("LaunchPreparation passes with 1 DriverSeat even without engines or fuel tanks", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "ok_b1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "ok_s1",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 2.5, 0),
			})
			local res = BuildService.ProcessRequest(pA, { Action = BuildProtocol.Actions.ValidateLaunchPrep })
			local rep = res.LaunchPrepReport :: VehicleTypes.LaunchPreparationReport
			assert(rep.Ready == true, "Should be Ready without engine/fuel; got " .. tostring(rep.PrimaryErrorMessage))
			assert(rep.DriverSeatCount == 1 and rep.DriverSeatPieceId ~= nil, "Must report exact 1 DriverSeat")
			assert(rep.BoundingSize ~= nil and rep.BoundingSize.Y >= 2.9, "BoundingSize should be ~ (2, 3, 2)")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 60
	runCase("LaunchPreparation isolates PrimaryAssembly with loose workshop parts and still catches AmbiguousPrimaryAssembly and launch bounds", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local multiGroupBp: VehicleTypes.VehicleBlueprint = {
				SchemaVersion = 1,
				BlueprintId = "bp_disc",
				OwnerUserId = pA.UserId,
				Name = "MultiGroup",
				Revision = 1,
				CreatedAt = 100,
				UpdatedAt = 100,
				VehicleOrigin = CFrame.identity,
				Presentation = { HeightOffset = 0, LateralOffset = 0 },
				Pieces = {
					{ InstanceId = "p1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 0.5, 0) },
					{ InstanceId = "p2", ItemId = "DriverSeat", LocalCFrame = CFrame.new(10, 2.0, 0) },
				},
				Connections = {},
			}
			local repIsolated = VehicleLaunchPreparationService.EvaluateBlueprintLaunch(multiGroupBp, plot1, { SkipWorldObstructionCheck = true })
			assert(repIsolated.Ready == true, "Single DriverSeat assembly should be Ready even with loose WoodBlock; got " .. tostring(repIsolated.PrimaryErrorMessage))
			assert(repIsolated.PieceCount == 1 and repIsolated.TotalPieceCount == 2 and repIsolated.WorkshopPieceCount == 1, "Expected 1 primary piece + 1 loose workshop piece")

			-- Dos grupos desconectados ambos con DriverSeat -> AmbiguousPrimaryAssembly hasta elegir
			local ambigBp: VehicleTypes.VehicleBlueprint = {
				SchemaVersion = 1,
				BlueprintId = "bp_ambig",
				OwnerUserId = pA.UserId,
				Name = "Ambig",
				Revision = 1,
				CreatedAt = 100,
				UpdatedAt = 100,
				VehicleOrigin = CFrame.identity,
				Presentation = { HeightOffset = 0, LateralOffset = 0 },
				Pieces = {
					{ InstanceId = "s1", ItemId = "DriverSeat", LocalCFrame = CFrame.new(-6, 0, 0) },
					{ InstanceId = "s2", ItemId = "DriverSeat", LocalCFrame = CFrame.new(6, 0, 0) },
				},
				Connections = {},
			}
			local repAmbig = VehicleLaunchPreparationService.EvaluateBlueprintLaunch(ambigBp, plot1, { SkipWorldObstructionCheck = true })
			assert(not repAmbig.Ready and repAmbig.PrimaryErrorCode == BuildProtocol.ErrorCodes.AmbiguousPrimaryAssembly and repAmbig.NeedsPrimarySelection == true, "Expected AmbiguousPrimaryAssembly")

			-- Oversized dimensions check
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "ov_b1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 0.5, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "ov_s1",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 2.0, 0),
			})
			local bp = VehicleBlueprintService.GetBlueprintSnapshot(pA)
			local repSize = VehicleLaunchPreparationService.EvaluateBlueprintLaunch(bp, plot1, {
				MaxLaunchDimensions = Vector3.new(1.5, 1.5, 1.5),
				SkipWorldObstructionCheck = true,
			})
			assert(not repSize.Ready and repSize.PrimaryErrorCode == "VehicleExceedsLaunchBounds", "Expected VehicleExceedsLaunchBounds")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 61
	runCase("LaunchPreparation detects spatial obstructions on LaunchPoint as LocationError", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "obs_b1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 0.5, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "obs_s1",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 2.0, 0),
			})

			local blocker = Instance.new("Part")
			blocker.Name = "BlockingCrate"
			blocker.Size = Vector3.new(4, 4, 4)
			blocker.Anchored = true
			blocker.CanCollide = true
			blocker.CFrame = plot1.Zones.LaunchPoint.CFrame * CFrame.new(0, 1.5, 0)
			blocker.Parent = Workspace

			local repBlocked = VehicleLaunchPreparationService.EvaluatePlayerLaunch(pA)
			assert(not repBlocked.Ready, "Must reject blocked launch zone")
			assert(repBlocked.ErrorCategory == "LocationError" and repBlocked.PrimaryErrorCode == "LaunchAreaBlocked", "Expected LocationError/LaunchAreaBlocked")
			assert(repBlocked.ObstructingPartNames and #repBlocked.ObstructingPartNames >= 1, "Must list obstructing parts")

			blocker:Destroy()
			local repClear = VehicleLaunchPreparationService.EvaluatePlayerLaunch(pA)
			assert(repClear.Ready, "After removing obstruction, launch must be Ready")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 62
	runCase("LaunchPreparation computes ground clearance above LaunchPoint without burying lowest piece", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			-- Colocar chasis a Y=2.5 (elevado) + rueda colgando debajo Y=1.5..3.5 -> min.Y está debajo de DriverSeat
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "clr_b1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 2.5, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "clr_s1",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 4.0, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "clr_w1",
				ItemId = "SmallWheel",
				LocalCFrame = CFrame.new(-1.5, 2.25, 0),
			})

			local rep = VehicleLaunchPreparationService.EvaluatePlayerLaunch(pA, { SkipWorldObstructionCheck = true })
			assert(rep.Ready and rep.LaunchAnchorCFrame, "Should compute LaunchAnchorCFrame")
			local bp = VehicleBlueprintService.GetBlueprintSnapshot(pA)
			local pieceWorldCFs = VehicleLaunchPreparationService.ComputePieceLaunchWorldCFrames(bp, rep.LaunchAnchorCFrame :: CFrame)

			local lpFloorY = plot1.Zones.LaunchPoint.Position.Y - plot1.Zones.LaunchPoint.Size.Y * 0.5
			local minWorldY = math.huge
			for _, piece in ipairs(bp.Pieces) do
				local g = ConnectionService.GetItemGeometry(piece.ItemId) :: ConnectionService.CachedItemGeometry
				local wCF = pieceWorldCFs[piece.InstanceId]
				local ext = BuildRotation.GetRotatedExtents(g.Size, wCF.Rotation)
				minWorldY = math.min(minWorldY, wCF.Position.Y - ext.Y * 0.5)
			end
			assert(math.abs(minWorldY - (lpFloorY + GameConfig.LaunchPrep.GroundClearanceStuds)) < 1e-3, "Lowest vehicle point must sit at exact platform floor + ground clearance")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 63
	runCase("Concurrent blueprint switch rejects stale PlacePiece and ignores out-of-order client response", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local bp1 = VehicleBlueprintService.GetOrCreateBlueprint(pA)
			local cr2 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.CreateBlueprint,
				ClientOpId = "st_cr2",
				Name = "NuevoActivo",
			})
			local bp2 = cr2.Blueprint :: VehicleTypes.VehicleBlueprint

			-- Servidor recibe edición tardía referenciando ExpectedBlueprintId = bp1 después del cambio a bp2
			local staleRes = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "st_late",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 0.5, 0),
				ExpectedBlueprintId = bp1.BlueprintId,
			})
			assert(not staleRes.Success and staleRes.ErrorCode == BuildProtocol.ErrorCodes.StaleBlueprintRevision, "Server must reject stale ExpectedBlueprintId")
			assert(VehicleBlueprintService.GetPieceCount(pA) == 0, "Active bp2 must remain untouched")

			-- Cliente ignora respuesta tardía si TransitionEpoch avanzó durante vuelo
			BuildState.Reset()
			BuildState.SetExpectedOwner(pA.UserId)
			BuildState.SetPlot(plot1.Model, plot1.Zones.BuildZone)
			BuildState.ApplyAuthoritativeBlueprint(bp2, true)
			BuildState.BeginBlueprintTransition()
			local appliedWrong = BuildState.ApplyAuthoritativeBlueprint(bp1, false)
			assert(not appliedWrong, "BuildState must reject non-explicit blueprint swap")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 64
	runCase("Blueprint and Stand RPCs respect ClientOpId idempotency on duplicate retries", function()
		local _, _, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			local r1 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.CreateBlueprint,
				ClientOpId = "idem_create_1",
				Name = "Idempotente",
			})
			assert(r1.Success, "First create must succeed")
			local countAfter1 = VehicleBlueprintService.GetSavedBlueprintCount(pA)

			local r2 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.CreateBlueprint,
				ClientOpId = "idem_create_1",
				Name = "Idempotente",
			})
			assert(r2.Success and r2.BlueprintId == r1.BlueprintId, "Retry must return same BlueprintId")
			assert(VehicleBlueprintService.GetSavedBlueprintCount(pA) == countAfter1, "Idempotent retry must NOT create a second slot")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)

	-- 65
	runCase("Full Fase 2.4 workflow (build, save, stand offset, launch prep, switch, reload) via client controllers", function()
		local _, plot1, _, cleanup = setupIsolatedWorld()
		local okRun, errRun = pcall(function()
			BuildState.Reset()
			BuildState.SetExpectedOwner(pA.UserId)
			BuildState.SetPlot(plot1.Model, plot1.Zones.BuildZone)
			BuildState.SetActive(true)

			local function mockInvoke(req: any): BuildProtocol.BuildOperationResponse
				return BuildService.ProcessRequest(pA, req)
			end

			BuildPlacementController.SyncBlueprintFromServer(mockInvoke)
			BlueprintManagerController.RefreshList(mockInvoke)
			local firstBpId = BuildState.BlueprintId :: string

			-- Construir vehículo 4 piezas (WoodBlock + DriverSeat + 2 ruedas)
			local pRes1 = BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "wf_1",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "wf_2",
				ItemId = "DriverSeat",
				LocalCFrame = CFrame.new(0, 2.5, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "wf_3",
				ItemId = "SmallWheel",
				LocalCFrame = CFrame.new(-1.5, 1.0, 0),
			})
			BuildService.ProcessRequest(pA, {
				Action = BuildProtocol.Actions.PlacePiece,
				ClientOpId = "wf_4",
				ItemId = "SmallWheel",
				LocalCFrame = CFrame.new(1.5, 1.0, 0) * CFrame.Angles(0, math.pi, 0),
			})
			assert(pRes1.Success, "Placement failed")

			-- Ajustar Elevador mediante StandController y guardar
			local okOff = StandController.SetStandOffset(2.5, -1.5, mockInvoke)
			assert(okOff and math.abs(BuildState.StandPresentation.HeightOffset - 2.5) < 1e-3, "StandController offset sync failed")
			local okSave = BlueprintManagerController.SaveBlueprint("Rover Final", false, mockInvoke)
			assert(okSave and BuildState.BlueprintName == "Rover Final", "SaveBlueprint failed")

			-- Verificar Lanzamiento mientras está elevado (debe ignorar offset del elevador)
			local okPrep, prepResp = StandController.RunLaunchPrepCheck(mockInvoke)
			assert(okPrep and prepResp and prepResp.LaunchPrepReport and prepResp.LaunchPrepReport.Ready, "LaunchPrep must be Ready for 4-piece Rover")

			-- Crear nuevo blueprint vacío -> EditableVehicle debe vaciarse a 0 piezas y elevador resetearse
			local okNew = BlueprintManagerController.CreateBlueprint("Proyecto 2", mockInvoke)
			assert(okNew and #BuildState.BlueprintPieces == 0, "New blueprint must be empty")
			assert(StandPreviewService.GetStandPreviewModel(pA) == nil, "StandPreview must remain nil")
			assert(#(VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model):GetChildren() == 0, "EditableVehicle must have 0 pieces on empty blueprint")

			-- Volver a cargar "Rover Final" -> 4 piezas restauradas, offset temporal reiniciado a (0, 0), sin VehicleRuntime ni StandPreview
			local okLoad = BlueprintManagerController.LoadBlueprint(firstBpId, mockInvoke)
			assert(okLoad and #BuildState.BlueprintPieces == 4, "Reloaded Rover must have 4 pieces")
			assert(math.abs(BuildState.StandPresentation.HeightOffset) < 1e-3 and math.abs(BuildState.StandPresentation.LateralOffset) < 1e-3, "Saved load must start with neutral workshop lift (0, 0)")
			assert(StandPreviewService.GetStandPreviewModel(pA) == nil, "StandPreview must remain nil on reload")
			assert(#(VehicleBlueprintService.GetEditableVehicleModel(pA) :: Model):GetChildren() == 4, "EditableVehicle must restore 4 pieces")
			assert(plot1.DynamicContainer:FindFirstChild("VehicleRuntime") == nil, "No VehicleRuntime should exist")
		end)
		cleanup()
		if not okRun then error(errRun) end
	end)
end

return Phase24Tests
