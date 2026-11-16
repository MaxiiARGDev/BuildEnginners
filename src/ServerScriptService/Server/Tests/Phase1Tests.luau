--!strict
--[=[
	Phase1Tests
	Suite de pruebas de aceptación de la Fase 1 (docs/09-MVP-TESTING.md):
	1. ItemRegistry: 8 objetos iniciales, inmutabilidad, detección de duplicados/estadísticas inválidas, validación de modelos.
	2. PlotService: 10 jugadores reciben estaciones distintas desde plantilla, 11vo rechazado, liberación/reasignación sin restos.
	3. ItemRuntimeService: carga modular de Behaviors/<ModuleScript> y duplicación sin conflictos (sin simulación física).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildGrid = require(ReplicatedStorage.Shared.Building.BuildGrid)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildSnapPolicy = require(ReplicatedStorage.Shared.Building.BuildSnapPolicy)
local BuildTransformMath = require(ReplicatedStorage.Shared.Building.BuildTransformMath)
local BuildAlignmentMath = require(ReplicatedStorage.Shared.Building.BuildAlignmentMath)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local PlotService = require(ServerScriptService.Server.Services.PlotService)
local SpawnService = require(ServerScriptService.Server.Services.SpawnService)
local InventoryService = require(ServerScriptService.Server.Services.InventoryService)
local PreviewAssetService = require(ServerScriptService.Server.Services.PreviewAssetService)
local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local BuildService = require(ServerScriptService.Server.Services.BuildService)
local ItemRuntimeService = require(ServerScriptService.Server.Services.ItemRuntimeService)
local BuildPayloadValidator = require(ServerScriptService.Server.Security.BuildPayloadValidator)
local BuildBenchmarks = require(ServerScriptService.Server.Benchmarks.BuildBenchmarks)

export type TestCaseResult = {
	Name: string,
	Passed: boolean,
	Error: string?,
}

export type TestSuiteResult = {
	Passed: number,
	Failed: number,
	Results: { TestCaseResult },
}

local Phase1Tests = {}

local function assertTrue(condition: boolean, message: string)
	if not condition then
		error(message, 2)
	end
end

local function assertEqual(actual: any, expected: any, message: string)
	if actual ~= expected then
		error(`{message}: expected '{tostring(expected)}', got '{tostring(actual)}'`, 2)
	end
end

function Phase1Tests.RunCoreOnly(): TestSuiteResult
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
		end
	end

	runTest("ItemRegistry registers all 8 initial items immutably", function()
		ItemRegistry.Init()
		local expectedIds = {
			"WoodBeam",
			"WoodBlock",
			"SmallWheel",
			"SmallEngine",
			"RegularFuelTank",
			"SmallBooster",
			"SmallNitroTank",
			"DriverSeat",
			"AircraftWingLeft",
			"AircraftWingRight",
			"AircraftWing",
			"AircraftTail",
			"LargeGliderWing",
			"SmallGliderWing",
		}

		local all = ItemRegistry.GetAll()
		assertEqual(#all, #expectedIds, "Total registered items")

		for _, itemId in ipairs(expectedIds) do
			assertTrue(ItemRegistry.Has(itemId), `Missing item '{itemId}'`)
			local def = ItemRegistry.Get(itemId)
			assertTrue(table.isfrozen(def), `Definition '{itemId}' must be frozen`)
			assertTrue(table.isfrozen(def.Stats), `Definition.Stats '{itemId}' must be frozen`)
		end

		-- Verificar estadísticas clave sin inventar valores TBD
		local smallEngine = ItemRegistry.Get("SmallEngine")
		assertEqual(smallEngine.Price, nil, "SmallEngine.Price must remain nil (TBD)")
		assertEqual(smallEngine.Stats.Torque, 1400, "SmallEngine.Torque")

		local driverSeat = ItemRegistry.Get("DriverSeat")
		assertTrue(driverSeat.Restrictions ~= nil and driverSeat.Restrictions.MaxPurchasesPerPlayer == 1, "DriverSeat max 1 purchase")
	end)

	runTest("ItemRegistry validates ServerStorage.ItemAssets models and attributes", function()
		local itemAssets = ServerStorage:WaitForChild("ItemAssets")
		ItemRegistry.NormalizeAssets(itemAssets)
		local validation = ItemRegistry.ValidateAssets(itemAssets)
		assertTrue(validation.Valid, "ValidateAssets errors: " .. table.concat(validation.Errors, "; "))
		assertEqual(validation.CheckedCount, 14, "CheckedCount")
	end)

	runTest("ItemRegistry rejects duplicate IDs, invalid stats, invalid categories, and incomplete definitions", function()
		-- 1. IDs duplicados
		local okDup, errDup = pcall(function()
			ItemRegistry.LoadFromTables({
				{
					Id = "DupItem",
					DisplayName = "A",
					Category = "Structures",
					Model = "WoodBeam",
					Stats = { Weight = 1, MaxDurability = 10 },
				},
				{
					Id = "DupItem",
					DisplayName = "B",
					Category = "Structures",
					Model = "WoodBeam",
					Stats = { Weight = 2, MaxDurability = 20 },
				},
			})
		end)
		assertTrue(not okDup, "Duplicate ItemId should raise an error")
		assertTrue(string.find(tostring(errDup), "Duplicate ItemId", 1, true) ~= nil, `Expected duplicate error, got: {tostring(errDup)}`)

		-- 2. Estadísticas inválidas (peso negativo, durabilidad 0, NaN)
		local invalidStatsCases: { { Label: string, Def: any } } = {
			{
				Label = "negative Weight",
				Def = {
					Id = "BadWeight",
					DisplayName = "Bad",
					Category = "Structures",
					Model = "WoodBeam",
					Stats = { Weight = -5, MaxDurability = 10 },
				},
			},
			{
				Label = "zero MaxDurability",
				Def = {
					Id = "BadDurability",
					DisplayName = "Bad",
					Category = "Structures",
					Model = "WoodBeam",
					Stats = { Weight = 5, MaxDurability = 0 },
				},
			},
			{
				Label = "NaN Weight",
				Def = {
					Id = "NaNWeight",
					DisplayName = "Bad",
					Category = "Structures",
					Model = "WoodBeam",
					Stats = { Weight = 0 / 0, MaxDurability = 10 },
				},
			},
		}

		for _, case in ipairs(invalidStatsCases) do
			local okStat = pcall(function()
				ItemRegistry.LoadFromTables({ case.Def })
			end)
			assertTrue(not okStat, `{case.Label} should raise an error`)
		end

		-- 3. Categorías inválidas (categoría inexistente y mismatch de carpeta)
		local okBadCat = pcall(function()
			ItemRegistry.LoadFromTables({
				{
					Id = "BadCatItem",
					DisplayName = "BadCat",
					Category = "Weapons",
					Model = "WoodBeam",
					Stats = { Weight = 1, MaxDurability = 10 },
				},
			})
		end)
		assertTrue(not okBadCat, "Unknown Category should raise an error")

		local okMismatch = pcall(function()
			ItemRegistry.LoadFromEntries({
				{
					Definition = {
						Id = "MismatchItem",
						DisplayName = "Mismatch",
						Category = "Wheels",
						Model = "SmallWheel",
						Stats = { Weight = 4, MaxDurability = 32 },
					},
					ExpectedCategory = "Structures",
					SourceName = "Structures/MismatchItem",
				},
			})
		end)
		assertTrue(not okMismatch, "Category mismatch with ExpectedCategory should raise an error")

		-- 4. Definiciones incompletas
		local incompleteCases: { { Label: string, Def: any } } = {
			{
				Label = "missing Id",
				Def = { DisplayName = "NoId", Category = "Structures", Model = "WoodBeam", Stats = { Weight = 1, MaxDurability = 10 } },
			},
			{
				Label = "missing DisplayName",
				Def = { Id = "NoName", Category = "Structures", Model = "WoodBeam", Stats = { Weight = 1, MaxDurability = 10 } },
			},
			{
				Label = "missing Model",
				Def = { Id = "NoModel", DisplayName = "NoModel", Category = "Structures", Stats = { Weight = 1, MaxDurability = 10 } },
			},
			{
				Label = "missing Stats",
				Def = { Id = "NoStats", DisplayName = "NoStats", Category = "Structures", Model = "WoodBeam" },
			},
		}

		for _, case in ipairs(incompleteCases) do
			local okInc = pcall(function()
				ItemRegistry.LoadFromTables({ case.Def })
			end)
			assertTrue(not okInc, `Incomplete definition ({case.Label}) should raise an error`)
		end
	end)

	runTest("PlotService assigns 10 unique plots from physical BaseTemplate and PlotSpawns, and cleans only DynamicRuntime", function()
		local baseTemplate = ServerStorage:FindFirstChild("BaseTemplate")
		assertTrue(baseTemplate ~= nil and baseTemplate:IsA("Model"), "ServerStorage.BaseTemplate must be a real Model")
		local templateModel = baseTemplate :: Model

		local templateOrigin = templateModel:FindFirstChild("PlotOrigin")
		assertTrue(templateOrigin ~= nil and templateOrigin:IsA("BasePart"), "BaseTemplate.PlotOrigin must exist")
		assertTrue(templateModel:FindFirstChild("Platform") ~= nil, "BaseTemplate.Platform must exist")
		assertTrue(templateModel:FindFirstChild("Decorations") ~= nil, "BaseTemplate.Decorations must exist")
		assertTrue(templateModel:FindFirstChild("Structures") ~= nil, "BaseTemplate.Structures must exist")
		assertTrue(templateModel:FindFirstChild("DynamicRuntime") ~= nil, "BaseTemplate.DynamicRuntime must exist")

		local plotSpawns = Workspace:FindFirstChild("PlotSpawns")
		assertTrue(plotSpawns ~= nil and plotSpawns:IsA("Folder"), "Workspace.PlotSpawns Folder must exist")

		for i = 1, 10 do
			local spawnName = string.format("Plot_%02d", i)
			local spawnPart = (plotSpawns :: Folder):FindFirstChild(spawnName)
			assertTrue(spawnPart ~= nil and spawnPart:IsA("BasePart") and (spawnPart :: BasePart).Anchored, `Spawn '{spawnName}' must be an anchored BasePart`)
		end

		local testPlotsContainer = Instance.new("Folder")
		testPlotsContainer.Name = "TestPlotsWorkspace"
		testPlotsContainer.Parent = ServerStorage

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = templateModel,
			PlotSpawnsFolder = plotSpawns :: Folder,
			PlotsParent = testPlotsContainer,
			PlotCount = GameConfig.PlotCount,
		})

		assertEqual(PlotService.GetFreePlotCount(), 10, "Initial free plot count")

		-- Verificar que cada clon respeta posición/rotación de su spawn, mantiene zonas relativas, duplica decoraciones y no se superpone
		local allPlots = PlotService.GetAllPlots()
		assertEqual(#allPlots, 10, "Cloned plot count")

		local templateDecorations = templateModel:FindFirstChild("Decorations") :: Folder
		local expectedDecorCount = #templateDecorations:GetChildren()
		local templateBuildOffset = (templateOrigin :: BasePart).CFrame:ToObjectSpace((templateModel:FindFirstChild("BuildZone") :: BasePart).CFrame)

		local platforms: { BasePart } = {}
		for _, plot in ipairs(allPlots) do
			local spawnPart = (plotSpawns :: Folder):FindFirstChild(plot.PlotId) :: BasePart
			local originDelta = (plot.PlotOrigin.CFrame.Position - spawnPart.CFrame.Position).Magnitude
			assertTrue(originDelta < 0.05, `Plot '{plot.PlotId}' PlotOrigin position mismatch: {originDelta}`)

			local actualBuildOffset = plot.PlotOrigin.CFrame:ToObjectSpace(plot.Zones.BuildZone.CFrame)
			local zoneOffsetDelta = (actualBuildOffset.Position - templateBuildOffset.Position).Magnitude
			assertTrue(zoneOffsetDelta < 0.05, `Plot '{plot.PlotId}' BuildZone relative offset mismatch`)

			local clonedDecor = plot.Model:FindFirstChild("Decorations") :: Folder
			assertTrue(clonedDecor ~= nil, `Plot '{plot.PlotId}' missing Decorations folder`)
			assertEqual(#clonedDecor:GetChildren(), expectedDecorCount, `Plot '{plot.PlotId}' decorations count`)

			local platform = plot.Model:FindFirstChild("Platform") :: BasePart
			assertTrue(platform ~= nil, `Plot '{plot.PlotId}' missing Platform`)
			for _, other in ipairs(platforms) do
				local dist = (platform.Position - other.Position).Magnitude
				assertTrue(dist > platform.Size.X * 0.5 + other.Size.X * 0.5, `Overlap detected between {plot.PlotId} and another plot`)
			end
			table.insert(platforms, platform)
		end

		local seenPlotIds: { [string]: boolean } = {}
		local players: { PlotService.PlayerLike } = {}

		for i = 1, 10 do
			local mockPlayer: PlotService.PlayerLike = { UserId = 1000 + i, Name = `TestPlayer_{i}` }
			table.insert(players, mockPlayer)
			local plot, err = PlotService.Assign(mockPlayer)
			assertTrue(plot ~= nil, `Failed to assign plot {i}: {tostring(err)}`)
			assertTrue(not seenPlotIds[(plot :: PlotService.PlotRecord).PlotId], `Duplicate plot assigned: {(plot :: PlotService.PlotRecord).PlotId}`)
			seenPlotIds[(plot :: PlotService.PlotRecord).PlotId] = true

			local zones = (plot :: PlotService.PlotRecord).Zones
			assertTrue(zones.BuildZone ~= nil and zones.LaunchPoint ~= nil and zones.ShopZone ~= nil and zones.DeliveryZone ~= nil and zones.StandZone ~= nil, "All 5 zones must exist")
		end

		assertEqual(PlotService.GetFreePlotCount(), 0, "Free plot count when full")

		-- 11vo jugador debe ser rechazado limpiamente
		local extraPlayer: PlotService.PlayerLike = { UserId = 9999, Name = "ExtraPlayer" }
		local extraPlot, extraErr = PlotService.Assign(extraPlayer)
		assertEqual(extraPlot, nil, "11th player must not get a plot")
		assertEqual(extraErr, "NoFreePlot", "11th player error code")

		-- Simular restos en DynamicRuntime del jugador 3 y liberar; verificar que decoraciones y geometría permanecen intactas
		local p3 = players[3]
		local p3Plot = PlotService.GetPlotByPlayer(p3) :: PlotService.PlotRecord
		local leftover = Instance.new("Part")
		leftover.Name = "LeftoverDebris"
		leftover.Parent = p3Plot.DynamicContainer

		local released = PlotService.Release(p3)
		assertTrue(released, "Release should return true")
		assertEqual(PlotService.GetFreePlotCount(), 1, "Free plot count after release")
		assertEqual(#p3Plot.DynamicContainer:GetChildren(), 0, "DynamicContainer must be empty after release")
		assertEqual(#(p3Plot.Model:FindFirstChild("Decorations") :: Folder):GetChildren(), expectedDecorCount, "Permanent decorations must survive release")
		assertTrue(p3Plot.Model:FindFirstChild("Platform") ~= nil, "Platform must survive release")

		-- Reasignar a nuevo jugador en el slot liberado
		local replacement: PlotService.PlayerLike = { UserId = 2001, Name = "Replacement" }
		local newPlot = PlotService.Assign(replacement)
		assertTrue(newPlot ~= nil, "Replacement should receive freed plot")
		assertEqual((newPlot :: PlotService.PlotRecord).PlotId, p3Plot.PlotId, "Replacement should reuse freed plot")

		PlotService._ResetForTests()
		testPlotsContainer:Destroy()
	end)

	runTest("PlotService respects rotated PlotSpawns and preserves relative zone orientation", function()
		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		local templateOrigin = baseTemplate:FindFirstChild("PlotOrigin") :: BasePart
		local templateBuild = baseTemplate:FindFirstChild("BuildZone") :: BasePart
		local expectedRel = templateOrigin.CFrame:ToObjectSpace(templateBuild.CFrame)

		local tempSpawns = Instance.new("Folder")
		tempSpawns.Name = "TempRotatedSpawns"
		tempSpawns.Parent = ServerStorage

		local rotatedSpawn = Instance.new("Part")
		rotatedSpawn.Name = "Plot_01"
		rotatedSpawn.Anchored = true
		rotatedSpawn.CFrame = CFrame.new(500, 10, -250) * CFrame.Angles(0, math.rad(90), 0)
		rotatedSpawn.Parent = tempSpawns

		local tempPlots = Instance.new("Folder")
		tempPlots.Name = "TempRotatedPlots"
		tempPlots.Parent = ServerStorage

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = tempSpawns,
			PlotsParent = tempPlots,
			PlotCount = 1,
		})

		local plot = PlotService.GetPlotById("Plot_01") :: PlotService.PlotRecord
		assertTrue(plot ~= nil, "Rotated Plot_01 must exist")

		local posErr = (plot.PlotOrigin.CFrame.Position - rotatedSpawn.CFrame.Position).Magnitude
		assertTrue(posErr < 0.05, `Rotated spawn position mismatch: {posErr}`)

		local lookDot = plot.PlotOrigin.CFrame.LookVector:Dot(rotatedSpawn.CFrame.LookVector)
		assertTrue(lookDot > 0.999, `Rotated spawn orientation mismatch (dot={lookDot})`)

		local actualRel = plot.PlotOrigin.CFrame:ToObjectSpace(plot.Zones.BuildZone.CFrame)
		local relErr = (actualRel.Position - expectedRel.Position).Magnitude
		assertTrue(relErr < 0.05, `Relative zone offset changed after rotation: {relErr}`)

		PlotService._ResetForTests()
		tempSpawns:Destroy()
		tempPlots:Destroy()
	end)

	runTest("PlotService positions Platform above Baseplate and supports elevated PlotSpawns", function()
		local baseplate = Workspace:FindFirstChild("Baseplate")
		assertTrue(baseplate ~= nil and baseplate:IsA("BasePart"), "Workspace.Baseplate must exist")
		local bp = baseplate :: BasePart
		local baseplateTopY = bp.Position.Y + bp.Size.Y / 2

		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder

		local testPlots = Instance.new("Folder")
		testPlots.Name = "TestVerticalPlots"
		testPlots.Parent = ServerStorage

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = plotSpawns,
			PlotsParent = testPlots,
			PlotCount = GameConfig.PlotCount,
		})

		for _, plot in ipairs(PlotService.GetAllPlots()) do
			local platform = plot.Model:FindFirstChild("Platform") :: BasePart
			local platformBottomY = platform.Position.Y - platform.Size.Y / 2
			local platformTopY = platform.Position.Y + platform.Size.Y / 2

			assertTrue(platformBottomY >= baseplateTopY - 0.01, `Plot '{plot.PlotId}' Platform bottom ({platformBottomY}) is below Baseplate top ({baseplateTopY})`)
			assertTrue(platformTopY > baseplateTopY, `Plot '{plot.PlotId}' Platform top ({platformTopY}) must be above Baseplate top ({baseplateTopY})`)
		end

		PlotService._ResetForTests()
		testPlots:Destroy()

		-- Verificar altura elevada arbitraria (ej. Y = 40)
		local elevatedSpawns = Instance.new("Folder")
		elevatedSpawns.Name = "TestElevatedSpawns"
		elevatedSpawns.Parent = ServerStorage

		local elevatedPart = Instance.new("Part")
		elevatedPart.Name = "Plot_01"
		elevatedPart.Anchored = true
		elevatedPart.CFrame = CFrame.new(0, 40, 0) * CFrame.Angles(0, math.rad(45), 0)
		elevatedPart.Parent = elevatedSpawns

		local elevatedPlots = Instance.new("Folder")
		elevatedPlots.Name = "TestElevatedPlots"
		elevatedPlots.Parent = ServerStorage

		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = elevatedSpawns,
			PlotsParent = elevatedPlots,
			PlotCount = 1,
		})

		local elevatedPlot = PlotService.GetPlotById("Plot_01") :: PlotService.PlotRecord
		local elevatedPlatform = elevatedPlot.Model:FindFirstChild("Platform") :: BasePart
		local elevatedBottomY = elevatedPlatform.Position.Y - elevatedPlatform.Size.Y / 2
		assertTrue(math.abs(elevatedBottomY - 40) < 0.05, `Elevated Platform bottom expected 40, got {elevatedBottomY}`)

		PlotService._ResetForTests()
		elevatedSpawns:Destroy()
		elevatedPlots:Destroy()
	end)

	runTest("SpawnService spawns players at their assigned PlayerSpawn with orientation and respawn isolation", function()
		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		local playerSpawnTemplate = baseTemplate:FindFirstChild("PlayerSpawn")
		assertTrue(playerSpawnTemplate ~= nil and playerSpawnTemplate:IsA("BasePart"), "BaseTemplate.PlayerSpawn must exist")
		local psPart = playerSpawnTemplate :: BasePart
		assertTrue(psPart.Anchored and not psPart.CanCollide and not psPart.CanTouch and psPart.Transparency == 1, "PlayerSpawn properties invalid")

		local tempSpawns = Instance.new("Folder")
		tempSpawns.Name = "TestSpawnPoints"
		tempSpawns.Parent = ServerStorage

		local sp1 = Instance.new("Part")
		sp1.Name = "Plot_01"
		sp1.Anchored = true
		sp1.CFrame = CFrame.new(0, 0, 0)
		sp1.Parent = tempSpawns

		local sp2 = Instance.new("Part")
		sp2.Name = "Plot_02"
		sp2.Anchored = true
		sp2.CFrame = CFrame.new(300, 15, 0) * CFrame.Angles(0, math.rad(90), 0)
		sp2.Parent = tempSpawns

		local tempPlots = Instance.new("Folder")
		tempPlots.Name = "TestSpawnPlots"
		tempPlots.Parent = ServerStorage

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = tempSpawns,
			PlotsParent = tempPlots,
			PlotCount = 2,
		})

		SpawnService._ResetForTests()
		SpawnService.Init()

		local hookCount = 0
		SpawnService.RegisterBeforeRespawnHook(function()
			hookCount += 1
		end)

		local function makeMockCharacter(name: string): (Model, Part)
			local char = Instance.new("Model")
			char.Name = name
			local hrp = Instance.new("Part")
			hrp.Name = "HumanoidRootPart"
			hrp.Size = Vector3.new(2, 2, 1)
			hrp.Anchored = true
			hrp.AssemblyLinearVelocity = Vector3.new(0, -50, 0)
			hrp.Parent = char
			char.PrimaryPart = hrp
			char.Parent = tempPlots
			return char, hrp
		end

		local p1: PlotService.PlayerLike = { UserId = 5001, Name = "SpawnP1" }
		local p2: PlotService.PlayerLike = { UserId = 5002, Name = "SpawnP2" }
		local plot1 = PlotService.Assign(p1) :: PlotService.PlotRecord
		local plot2 = PlotService.Assign(p2) :: PlotService.PlotRecord

		local char1, hrp1 = makeMockCharacter("Char1")
		local char2, hrp2 = makeMockCharacter("Char2")

		assertTrue(SpawnService.SpawnAtAssignedPlot(p1, char1), "Spawn p1")
		assertTrue(SpawnService.SpawnAtAssignedPlot(p2, char2), "Spawn p2")

		-- Verificar posición por encima de Platform y orientación respetada
		local p1Platform = plot1.Model:FindFirstChild("Platform") :: BasePart
		assertTrue(hrp1.Position.Y > p1Platform.Position.Y + p1Platform.Size.Y / 2, "Char1 must be above Platform")
		assertTrue((hrp1.Position - plot1.PlayerSpawn.Position).Magnitude < 0.05, "Char1 position matches Plot_01 PlayerSpawn")

		local p2LookDot = hrp2.CFrame.LookVector:Dot(plot2.PlayerSpawn.CFrame.LookVector)
		assertTrue(p2LookDot > 0.999, "Char2 orientation matches rotated Plot_02 PlayerSpawn")
		assertTrue((hrp1.Position - hrp2.Position).Magnitude > 100, "Two players must spawn on different bases")

		-- Simular respawn en la misma base
		char1:PivotTo(CFrame.new(999, 999, 999))
		assertTrue(SpawnService.SpawnAtAssignedPlot(p1, char1), "Respawn p1")
		assertEqual((PlotService.GetPlotByPlayer(p1) :: PlotService.PlotRecord).PlotId, plot1.PlotId, "Same plot kept on respawn")
		assertTrue((hrp1.Position - plot1.PlayerSpawn.Position).Magnitude < 0.05, "Respawn returned to Plot_01 PlayerSpawn")
		assertEqual(hookCount, 3, "BeforeRespawnHook invoked on each spawn/respawn")

		SpawnService._ResetForTests()
		PlotService._ResetForTests()
		tempSpawns:Destroy()
		tempPlots:Destroy()
	end)

	runTest("ItemRuntimeService loads modular behaviors and supports duplicated models without conflict", function()
		ItemRuntimeService._ResetForTests()
		ItemRuntimeService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		local runtime: VehicleTypes.VehicleRuntime = {
			RuntimeId = "rt_test_1",
			OwnerUserId = 1001,
			PlotId = "Plot_1",
			SourceBlueprintRevision = 1,
			State = "PreparingLaunch",
			Parts = {},
			RootModel = nil,
			StartedAt = os.clock(),
		}

		local engineTemplate = ServerStorage.ItemAssets.Motores.SmallEngine :: Model
		local clone1 = engineTemplate:Clone()
		local clone2 = engineTemplate:Clone()

		local state1: VehicleTypes.RuntimePartState = {
			PieceInstanceId = "piece_1",
			ItemId = "SmallEngine",
			CurrentDurability = 110,
			MaxDurability = 110,
			CurrentFuel = 0.54,
			IsDetached = false,
			IsFunctional = true,
			ModelInstance = clone1,
		}
		local state2: VehicleTypes.RuntimePartState = {
			PieceInstanceId = "piece_2",
			ItemId = "SmallEngine",
			CurrentDurability = 110,
			MaxDurability = 110,
			CurrentFuel = 0.54,
			IsDetached = false,
			IsFunctional = true,
			ModelInstance = clone2,
		}

		assertTrue(ItemRuntimeService.InitPart(runtime, state1, clone1), "InitPart clone1")
		assertTrue(ItemRuntimeService.InitPart(runtime, state2, clone2), "InitPart clone2")
		assertEqual(ItemRuntimeService.GetActivePartCount(runtime.RuntimeId), 2, "Two active parts in runtime")

		local destroyedCount = ItemRuntimeService.DestroyRuntime(runtime)
		assertEqual(destroyedCount, 2, "DestroyRuntime should clean up both parts")
		assertEqual(ItemRuntimeService.GetActivePartCount(runtime.RuntimeId), 0, "Active parts after DestroyRuntime")

		clone1:Destroy()
		clone2:Destroy()
		ItemRuntimeService._ResetForTests()
	end)

	runTest("BuildRotation performs exact 90-degree R/T/Y rotations and computes rotated extents", function()
		local rot = BuildRotation.Identity()
		for _ = 1, 4 do
			rot = BuildRotation.RotateY(rot, 1)
		end
		assertTrue(rot.RightVector:Dot(Vector3.xAxis) > 0.9999 and rot.UpVector:Dot(Vector3.yAxis) > 0.9999, "4x RotateY must return to identity")

		for _ = 1, 4 do
			rot = BuildRotation.RotateX(rot, 1)
		end
		assertTrue(rot.RightVector:Dot(Vector3.xAxis) > 0.9999 and rot.UpVector:Dot(Vector3.yAxis) > 0.9999, "4x RotateX must return to identity")

		for _ = 1, 4 do
			rot = BuildRotation.RotateZ(rot, 1)
		end
		assertTrue(rot.RightVector:Dot(Vector3.xAxis) > 0.9999 and rot.UpVector:Dot(Vector3.yAxis) > 0.9999, "4x RotateZ must return to identity")

		local beamSize = Vector3.new(1, 2, 4)
		local rotY90 = BuildRotation.RotateY(BuildRotation.Identity(), 1)
		local extY = BuildRotation.GetRotatedExtents(beamSize, rotY90)
		assertTrue(math.abs(extY.X - 4) < 1e-4 and math.abs(extY.Y - 2) < 1e-4 and math.abs(extY.Z - 1) < 1e-4, `Expected (4,2,1), got {tostring(extY)}`)

		local rotX90 = BuildRotation.RotateX(BuildRotation.Identity(), 1)
		local extX = BuildRotation.GetRotatedExtents(beamSize, rotX90)
		assertTrue(math.abs(extX.X - 1) < 1e-4 and math.abs(extX.Y - 4) < 1e-4 and math.abs(extX.Z - 2) < 1e-4, `Expected (1,4,2), got {tostring(extX)}`)
	end)

	runTest("BuildGrid snaps positive/negative coordinates, respects rotated BuildZone, and validates bounds", function()
		assertEqual(BuildGrid.SnapValue(1.4, 1), 1, "Snap +1.4")
		assertEqual(BuildGrid.SnapValue(1.6, 1), 2, "Snap +1.6")
		assertEqual(BuildGrid.SnapValue(-1.4, 1), -1, "Snap -1.4")
		assertEqual(BuildGrid.SnapValue(-1.6, 1), -2, "Snap -1.6")
		assertEqual(BuildGrid.SnapValue(-0.1, 1), 0, "Snap -0.1")

		local zoneCF = CFrame.new(100, 2, -50) * CFrame.Angles(0, math.rad(90), 0)
		local zoneSize = Vector3.new(40, 1, 40)
		local pieceSize = Vector3.new(2, 2, 2)

		local input: BuildGrid.SnapInput = {
			BuildZoneCFrame = zoneCF,
			BuildZoneSize = zoneSize,
			WorldHitPosition = zoneCF:PointToWorldSpace(Vector3.new(-7.3, -2.0, 11.4)),
			WorldHitNormal = zoneCF.UpVector,
			PieceSize = pieceSize,
			RelativeRotation = BuildRotation.Identity(),
			GridSize = 1,
		}

		local snap1 = BuildGrid.ComputeSnappedCFrame(input)
		local snap2 = BuildGrid.ComputeSnappedCFrame(input)
		assertEqual(snap1.WorldCFrame, snap2.WorldCFrame, "ComputeSnappedCFrame must be deterministic")
		assertEqual(snap1.LocalPosition.X, -7, "Snapped local X")
		assertEqual(snap1.LocalPosition.Z, 11, "Snapped local Z")

		local floorY = -zoneSize.Y * 0.5
		local bottomY = snap1.LocalPosition.Y - snap1.RotatedExtents.Y * 0.5
		assertTrue(bottomY >= floorY - 1e-4, `Piece bottom ({bottomY}) must not be below floor ({floorY})`)

		local validIn, reasonIn = BuildGrid.ValidateBounds(zoneSize, snap1.LocalPosition, snap1.RotatedExtents, 32)
		assertTrue(validIn, `Expected valid in-bounds placement, got {tostring(reasonIn)}`)

		-- Posición fuera de límites debe conservarse sin clamp y marcarse inválida
		local outInput: BuildGrid.SnapInput = {
			BuildZoneCFrame = zoneCF,
			BuildZoneSize = zoneSize,
			WorldHitPosition = zoneCF:PointToWorldSpace(Vector3.new(25, 0, 0)),
			WorldHitNormal = zoneCF.UpVector,
			PieceSize = pieceSize,
			RelativeRotation = BuildRotation.Identity(),
			GridSize = 1,
		}
		local snapOut = BuildGrid.ComputeSnappedCFrame(outInput)
		assertEqual(snapOut.LocalPosition.X, 25, "Out-of-bounds X must not be clamped")
		local validOut, reasonOut = BuildGrid.ValidateBounds(zoneSize, snapOut.LocalPosition, snapOut.RotatedExtents, 32)
		assertTrue(not validOut and reasonOut == "OutOfBoundsX", `Expected OutOfBoundsX, got {tostring(reasonOut)}`)
	end)

	runTest("PreviewAssetService publishes sanitized visual models without modifying ServerStorage.ItemAssets", function()
		local tempParent = Instance.new("Folder")
		tempParent.Name = "TempPreviewHost"
		tempParent.Parent = ServerStorage

		PreviewAssetService._ResetForTests()
		PreviewAssetService.Init({
			ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets"),
			TargetParent = tempParent,
		})

		local previewRoot = PreviewAssetService.GetPreviewRoot()
		assertTrue(previewRoot ~= nil, "PreviewAssets folder must exist")

		for _, def in ipairs(ItemRegistry.GetAll()) do
			local model = ItemRegistry.ResolveModel(previewRoot, def)
			assertTrue(model ~= nil and model:IsA("Model"), `Missing preview model for '{def.Id}'`)
			assertTrue(model:FindFirstChild("Behaviors") == nil, `Preview model '{def.Id}' must not expose Behaviors`)
			assertTrue(model:FindFirstChildWhichIsA("LuaSourceContainer", true) == nil, `Preview model '{def.Id}' must not contain scripts`)
		end

		-- Verificar que el original en ServerStorage conserva su Behavior
		local origEngine = ServerStorage.ItemAssets.Motores.SmallEngine
		assertTrue(origEngine:FindFirstChild("Behaviors") ~= nil, "Original SmallEngine in ServerStorage must keep Behaviors")

		PreviewAssetService._ResetForTests()
		tempParent:Destroy()
	end)

	runTest("BuildPreviewController and BuildState support 8 items, R/T/Y rotations, bounds/overlap validation, and ghost cleanup", function()
		local StarterPlayer = game:GetService("StarterPlayer")
		local controllers = StarterPlayer.StarterPlayerScripts.Client.Controllers
		local BuildState = require(controllers.BuildState)
		local BuildPreviewController = require(controllers.BuildPreviewController)

		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = "TempEditorPlots"
		tempPlots.Parent = Workspace

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = plotSpawns,
			PlotsParent = tempPlots,
			PlotCount = 2,
		})

		PreviewAssetService._ResetForTests()
		PreviewAssetService.Init({
			ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets"),
			TargetParent = ReplicatedStorage,
		})

		local mockPlayer: PlotService.PlayerLike = { UserId = 7777, Name = "EditorTester" }
		local assigned = PlotService.Assign(mockPlayer) :: PlotService.PlotRecord
		assertTrue(assigned ~= nil, "Plot assigned to EditorTester")

		BuildState.Reset()
		BuildState.SetPlot(assigned.Model, assigned.Zones.BuildZone)
		local okAct = BuildState.SetActive(true)
		assertTrue(okAct, "BuildState.SetActive(true)")

		-- Seleccionar los 8 objetos y verificar su ghost sin colisiones
		for _, def in ipairs(ItemRegistry.GetAll()) do
			BuildState.SelectItem(def.Id)
			local ghost, err = BuildPreviewController.EnsureGhostForItem(def.Id)
			assertTrue(ghost ~= nil and err == nil, `Ghost creation failed for '{def.Id}': {tostring(err)}`)
			local primary = (ghost :: Model).PrimaryPart :: BasePart
			assertTrue(primary ~= nil and primary.Anchored and not primary.CanCollide and not primary.CanQuery, `Ghost physics flags invalid for '{def.Id}'`)
		end

		-- Posición válida en el centro de BuildZone
		BuildState.SelectItem("WoodBeam")
		BuildState.ResetRotation()
		local bz = assigned.Zones.BuildZone
		local validCenter, cfCenter = BuildPreviewController.UpdateAtWorldPoint(bz.Position, bz.CFrame.UpVector)
		assertTrue(validCenter and cfCenter ~= nil, `Expected valid center placement, reason: {tostring(BuildState.ValidationReason)}`)

		-- Rotaciones R/T/Y
		BuildState.RotateY()
		BuildState.RotateX()
		BuildState.RotateZ()
		local validRot, cfRot = BuildPreviewController.UpdateAtWorldPoint(bz.Position + Vector3.new(2, 0, 2), bz.CFrame.UpVector)
		assertTrue(validRot and cfRot ~= nil, "Expected valid rotated placement")

		-- Posición fuera de BuildZone marcada como inválida
		local validOut, _ = BuildPreviewController.UpdateAtWorldPoint(bz.Position + Vector3.new(80, 0, 0), bz.CFrame.UpVector)
		assertTrue(not validOut and BuildState.ValidationReason == "OutOfBoundsX", `Expected OutOfBoundsX, got {tostring(BuildState.ValidationReason)}`)

		-- Salir del editor destruye el ghost
		BuildState.SetActive(false)
		BuildPreviewController.DestroyGhost()
		assertTrue(BuildPreviewController.GetCurrentGhost() == nil, "Ghost must be nil after exiting editor")

		BuildState.Reset()
		PlotService._ResetForTests()
		tempPlots:Destroy()
	end)

	runTest("BuildService places first piece, connects subsequent pieces, rejects floating/overlap/out-of-bounds/invalid requests, and deduplicates OpIds", function()
		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = "TempBuildServicePlots"
		tempPlots.Parent = Workspace

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = plotSpawns,
			PlotsParent = tempPlots,
			PlotCount = 2,
		})

		ConnectionService._ResetForTests()
		ConnectionService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
		InventoryService.Init()

		VehicleBlueprintService._ResetForTests()
		VehicleBlueprintService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		BuildService._ResetForTests()
		BuildService.Init()

		local p1: PlotService.PlayerLike = { UserId = 8001, Name = "BuilderOne" }
		local plot1 = PlotService.Assign(p1) :: PlotService.PlotRecord
		assertTrue(plot1 ~= nil, "Plot1 assigned")

		-- 1. Colocación válida de primera pieza (WoodBlock 2x2x2 en (0, 1.0, 0))
		local res1 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "op_1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
		})
		assertTrue(res1.Success and res1.PlacedPiece ~= nil, `First piece failed: {tostring(res1.ErrorCode)} - {tostring(res1.ErrorMessage)}`)
		assertEqual(#(res1.Blueprint :: VehicleTypes.VehicleBlueprint).Pieces, 1, "Blueprint piece count after 1st piece")

		-- 13. Protección contra solicitudes duplicadas (mismo ClientOpId)
		local resDup = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "op_1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
		})
		assertTrue(resDup.Success, "Duplicate OpId should return cached success")
		assertEqual((resDup.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId, (res1.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId, "Duplicate OpId must return same PieceInstanceId")
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(p1).Pieces, 1, "Duplicate OpId must not add 2nd piece")

		-- 2. Segunda pieza conectada (WoodBlock en (2, 1.0, 0) conecta Conn_Left <-> Conn_Right)
		local res2 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "op_2",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
		})
		assertTrue(res2.Success, `Connected 2nd piece failed: {tostring(res2.ErrorCode)}`)
		assertEqual(#(res2.Blueprint :: VehicleTypes.VehicleBlueprint).Pieces, 2, "Blueprint has 2 pieces")
		assertEqual(#(res2.Blueprint :: VehicleTypes.VehicleBlueprint).Connections, 1, "Blueprint has 1 connection")

		-- 5. Tercera pieza rotada y conectada (WoodBeam 1x1x4 rotada 90° en Y -> 4x1x1 en (5, 1.0, 0), conecta en X=3 con X=3 de pieza 2)
		local rotY90 = BuildRotation.RotateY(BuildRotation.Identity(), 1)
		local res3 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "op_3",
			ItemId = "WoodBeam",
			LocalCFrame = CFrame.new(5, 1.0, 0) * rotY90,
		})
		assertTrue(res3.Success, `Rotated connected WoodBeam failed: {tostring(res3.ErrorCode)} - {tostring(res3.ErrorMessage)}`)
		assertEqual(#(res3.Blueprint :: VehicleTypes.VehicleBlueprint).Pieces, 3, "Blueprint has 3 pieces")

		-- 3. Fase 2.4.2: Pieza desconectada libre dentro de BuildZone es permitida y forma un grupo independiente
		local resFloat = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "op_float",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(-10, 1.0, -10),
		})
		assertTrue(resFloat.Success, `Disconnected piece inside BuildZone should succeed in Fase 2.4.2, got {tostring(resFloat.ErrorCode)}`)
		local floatBp = resFloat.Blueprint :: VehicleTypes.VehicleBlueprint
		assertEqual(#floatBp.Pieces, 4, "Blueprint now has 4 pieces including loose WoodBlock")
		local floatAnalysis = ConnectionService.AnalyzeBlueprintAssemblies(floatBp)
		assertEqual(#floatAnalysis.Groups, 2, "Loose block adds 2nd independent assembly group")

		-- 7. Rechazo de superposición
		local resOverlap = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "op_overlap",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
		})
		assertTrue(not resOverlap.Success and resOverlap.ErrorCode == BuildProtocol.ErrorCodes.PieceOverlap, `Expected PieceOverlap, got {tostring(resOverlap.ErrorCode)}`)

		-- 6. Rechazo fuera de BuildZone
		local resOOB = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "op_oob",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(30, 1.0, 0),
		})
		assertTrue(not resOOB.Success and resOOB.ErrorCode == BuildProtocol.ErrorCodes.OutOfBounds, `Expected OutOfBounds, got {tostring(resOOB.ErrorCode)}`)

		-- 11. Rechazo de ItemId inexistente
		local resUnknown = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "op_unknown",
			ItemId = "NonExistentHyperDrive",
			LocalCFrame = CFrame.new(0, 3.0, 0),
		})
		assertTrue(not resUnknown.Success and resUnknown.ErrorCode == BuildProtocol.ErrorCodes.UnknownItem, "Expected UnknownItem")

		-- 12. Rechazo de CFrames inválidos (NaN y rotación de 45°)
		local resNaN = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "op_nan",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0 / 0, 1.0, 0),
		})
		assertTrue(not resNaN.Success and resNaN.ErrorCode == BuildProtocol.ErrorCodes.InvalidCFrame, "Expected InvalidCFrame")

		local resBadRot = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "op_badrot",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 3.0, 0) * CFrame.Angles(0, math.rad(45), 0),
		})
		assertTrue(not resBadRot.Success and resBadRot.ErrorCode == BuildProtocol.ErrorCodes.InvalidRotation, "Expected InvalidRotation")

		BuildService._ResetForTests()
		VehicleBlueprintService._ResetForTests()
		ConnectionService._ResetForTests()
		PlotService._ResetForTests()
		tempPlots:Destroy()
	end)

	runTest("BuildService enforces structural integrity on removal, player isolation, smart snap, optimistic reconciliation, and disconnect cleanup", function()
		local StarterPlayer = game:GetService("StarterPlayer")
		local controllers = StarterPlayer.StarterPlayerScripts.Client.Controllers
		local BuildState = require(controllers.BuildState)
		local BuildPreviewController = require(controllers.BuildPreviewController)
		local BuildPlacementController = require(controllers.BuildPlacementController)
		local BuildSelectionController = require(controllers.BuildSelectionController)

		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = "TempIntegrityPlots"
		tempPlots.Parent = Workspace

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = plotSpawns,
			PlotsParent = tempPlots,
			PlotCount = 2,
		})

		PreviewAssetService._ResetForTests()
		PreviewAssetService.Init({
			ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets"),
			TargetParent = ReplicatedStorage,
		})

		ConnectionService._ResetForTests()
		ConnectionService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
		InventoryService.Init()

		VehicleBlueprintService._ResetForTests()
		VehicleBlueprintService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		BuildService._ResetForTests()
		BuildService.Init()

		local p1: PlotService.PlayerLike = { UserId = 9001, Name = "PlayerA" }
		local p2: PlotService.PlayerLike = { UserId = 9002, Name = "PlayerB" }
		local plot1 = PlotService.Assign(p1) :: PlotService.PlotRecord
		local plot2 = PlotService.Assign(p2) :: PlotService.PlotRecord

		-- Construir cadena A - B - C en PlayerA
		local rA = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "pA_1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
		})
		local rB = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "pA_2",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
		})
		local rC = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "pA_3",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(4, 1.0, 0),
		})
		assertTrue(rA.Success and rB.Success and rC.Success, "Chain A-B-C placed")
		local idA = (rA.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId
		local idB = (rB.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId
		local idC = (rC.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

		-- 4. Verificar SmartSnap hacia el bloque C (cerca de X=5.6 -> snap exacto a X=6)
		local geomBlock = ConnectionService.GetItemGeometry("WoodBlock") :: ConnectionService.CachedItemGeometry
		local existingSpecs = ConnectionService.BuildPieceGeometrySpecs(VehicleBlueprintService.GetBlueprintSnapshot(p1).Pieces)
		local smartMatch = ConnectionMath.ComputeSmartSnap(
			CFrame.new(5.6, 1.0, 0.2),
			geomBlock.Size,
			geomBlock.Attachments,
			existingSpecs,
			1.75
		)
		assertTrue(smartMatch ~= nil, "SmartSnap should match near block C")
		assertTrue(((smartMatch :: ConnectionMath.SmartSnapMatch).SnappedLocalCFrame.Position - Vector3.new(6, 1.0, 0)).Magnitude < 0.01, "SmartSnap position should be exact (6, 1.0, 0)")

		-- 10. Aislamiento entre jugadores: PlayerB no puede eliminar piezas de PlayerA
		local crossDel = BuildService.ProcessRequest(p2, {
			Action = "RemovePiece",
			ClientOpId = "pB_hack",
			PieceInstanceId = idA,
		})
		assertTrue(not crossDel.Success and crossDel.ErrorCode == BuildProtocol.ErrorCodes.PieceNotFound, "PlayerB must not delete PlayerA piece")

		-- 9. Fase 2.4.2: Eliminar puente B entre A y C divide el diseño en 2 grupos independientes sin error
		local bridgeDel = BuildService.ProcessRequest(p1, {
			Action = "RemovePiece",
			ClientOpId = "pA_delB",
			PieceInstanceId = idB,
		})
		assertTrue(bridgeDel.Success, `Bridge removal should split cleanly in Fase 2.4.2, got {tostring(bridgeDel.ErrorCode)}`)
		local bpAfterBridge = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		assertEqual(#bpAfterBridge.Pieces, 2, "Blueprint has 2 pieces (A and C) after removing bridge B")
		assertEqual(#bpAfterBridge.Connections, 0, "Blueprint has 0 connections after removing bridge B")

		-- 8 y 14. Reconciliación optimista de colocación y eliminación desde cliente + rechazo de revisiones antiguas
		BuildState.Reset()
		BuildState.SetPlot(plot2.Model, plot2.Zones.BuildZone)
		BuildState.SetActive(true)
		BuildState.SelectItem("WoodBlock")
		BuildPreviewController._ClearGeometryCacheForTests()
		local validPreview, _ = BuildPreviewController.UpdateAtWorldPoint(plot2.Zones.BuildZone.Position, plot2.Zones.BuildZone.CFrame.UpVector)
		assertTrue(validPreview, "Preview valid on Plot2")

		local placedOk, placeRes = BuildPlacementController.PlaceCurrentPiece(function(req)
			return BuildService.ProcessRequest(p2, req)
		end)
		assertTrue(placedOk and placeRes ~= nil and placeRes.Success, "Optimistic placement succeeded on Plot2")
		assertEqual(BuildPlacementController.GetPendingCount(), 0, "Pending optimistic ghosts cleared after ack")
		assertEqual(#BuildState.BlueprintPieces, 1, "Client BuildState synced 1 piece")

		-- Protección contra respuesta fuera de orden (revisión menor ignorada)
		local appliedStale = BuildState.ApplyAuthoritativeBlueprint({
			BlueprintId = "bp_stale",
			OwnerUserId = p2.UserId,
			Revision = 0,
			Pieces = {},
			Connections = {},
		})
		assertTrue(not appliedStale and #BuildState.BlueprintPieces == 1, "Stale blueprint revision must be ignored")

		-- Eliminar extremos C y A en PlayerA hasta dejar el blueprint vacío (16. Integridad tras múltiples operaciones)
		local delC = BuildService.ProcessRequest(p1, { Action = "RemovePiece", ClientOpId = "del_C", PieceInstanceId = idC })
		local delA = BuildService.ProcessRequest(p1, { Action = "RemovePiece", ClientOpId = "del_A", PieceInstanceId = idA })
		assertTrue(delC.Success and delA.Success, "Sequential removals C -> A must succeed")
		local finalBpA = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		assertEqual(#finalBpA.Pieces, 0, "Blueprint A empty after removing all pieces")
		assertEqual(#finalBpA.Connections, 0, "Blueprint A connections empty")
		local editableA = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		assertEqual(#editableA:GetChildren(), 0, "EditableVehicle A has 0 children")

		-- Eliminación optimista desde BuildSelectionController en PlayerB
		local p2PieceId = BuildState.BlueprintPieces[1].InstanceId
		assertTrue(BuildSelectionController.SelectPieceById(p2PieceId), "Select piece on Plot2")
		local delP2Ok, _ = BuildSelectionController.DeleteSelectedPiece(function(req)
			return BuildService.ProcessRequest(p2, req)
		end)
		assertTrue(delP2Ok and #BuildState.BlueprintPieces == 0, "Optimistic deletion on Plot2 succeeded")

		-- 15. Limpieza al desconectarse
		VehicleBlueprintService.ClearPlayer(p1)
		PlotService.Release(p1)
		assertTrue(VehicleBlueprintService.GetEditableVehicleModel(p1) == nil, "EditableVehicle cleared on disconnect")
		assertEqual(#plot1.DynamicContainer:GetChildren(), 0, "Plot1 DynamicContainer empty after disconnect")

		BuildSelectionController.ClearSelection()
		BuildPreviewController.DestroyGhost()
		BuildState.Reset()
		BuildService._ResetForTests()
		VehicleBlueprintService._ResetForTests()
		ConnectionService._ResetForTests()
		PlotService._ResetForTests()
		tempPlots:Destroy()
	end)

	runTest("SmartSnap and ConnectionService support perpendicular WoodBeams, end-to-end, WoodBeam-to-WoodBlock, 90-degree rotations, border connections, and reject disconnected/overlapping pieces", function()
		local StarterPlayer = game:GetService("StarterPlayer")
		local controllers = StarterPlayer.StarterPlayerScripts.Client.Controllers
		local BuildState = require(controllers.BuildState)
		local BuildPreviewController = require(controllers.BuildPreviewController)
		local BuildPlacementController = require(controllers.BuildPlacementController)

		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = "TempHotfixConnPlots"
		tempPlots.Parent = Workspace

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = plotSpawns,
			PlotsParent = tempPlots,
			PlotCount = 1,
		})

		PreviewAssetService._ResetForTests()
		PreviewAssetService.Init({
			ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets"),
			TargetParent = ReplicatedStorage,
		})

		ConnectionService._ResetForTests()
		ConnectionService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
		InventoryService.Init()

		VehicleBlueprintService._ResetForTests()
		VehicleBlueprintService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		BuildService._ResetForTests()
		BuildService.Init()

		local p1: PlotService.PlayerLike = { UserId = 9501, Name = "BeamEngineer" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local bz = plot.Zones.BuildZone

		BuildState.Reset()
		BuildState.SetPlot(plot.Model, bz)
		BuildState.SetActive(true)
		BuildPreviewController._ClearGeometryCacheForTests()

		local function sendToServer(req: BuildProtocol.BuildOperationRequest)
			return BuildService.ProcessRequest(p1, req)
		end

		-- 1. Colocar una WoodBeam vertical (rotada 90° en X -> 1x4x1) apoyada en el piso en (0, 2.0, 0)
		BuildState.SelectItem("WoodBeam")
		BuildState.ResetRotation()
		BuildState.RotateX() -- 1x1x4 -> 1x4x1
		local validVert, _ = BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(Vector3.new(0, 0, 0)),
			bz.CFrame.UpVector
		)
		assertTrue(validVert, `Vertical WoodBeam preview should be valid, got {tostring(BuildState.ValidationReason)}`)
		local okVert, resVert = BuildPlacementController.PlaceCurrentPiece(sendToServer)
		assertTrue(okVert and resVert ~= nil and resVert.Success, `Vertical WoodBeam placement failed: {tostring(resVert and resVert.ErrorMessage)}`)

		-- 2. Dos WoodBeam conectadas perpendicularmente: WoodBeam horizontal (1x1x4) conectada a la estructura vertical
		-- 2a. Apuntando al piso junto a la viga vertical (Z = 2.8 -> SmartSnap a Z = 2.5, Y = 0.5)
		BuildState.ResetRotation() -- 1x1x4 horizontal
		local validPerpFloor, _ = BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(Vector3.new(0, 0, 2.8)),
			bz.CFrame.UpVector
		)
		assertTrue(
			validPerpFloor,
			`Horizontal WoodBeam on floor next to vertical WoodBeam should be valid, got {tostring(BuildState.ValidationReason)} ({tostring(BuildState.ValidationDetail)})`
		)
		local snappedPerpFloor = BuildState.LastSnappedLocalCFrame :: CFrame
		assertTrue(
			(snappedPerpFloor.Position - Vector3.new(0, 0.5, 2.5)).Magnitude < 0.05,
			`Expected horizontal beam snapped to (0, 0.5, 2.5), got {tostring(snappedPerpFloor.Position)}`
		)
		local okPerp1, resPerp1 = BuildPlacementController.PlaceCurrentPiece(sendToServer)
		assertTrue(okPerp1 and resPerp1 ~= nil and resPerp1.Success, `Perpendicular floor WoodBeam server validation failed: {tostring(resPerp1 and resPerp1.ErrorMessage)}`)

		-- 2b. Apuntando directamente a la cara lateral de la viga vertical a media altura (Y = 2.0, Z = -0.5)
		local validPerpMid, _ = BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(Vector3.new(0, 2.0, -0.5)),
			bz.CFrame:VectorToWorldSpace(Vector3.new(0, 0, -1))
		)
		assertTrue(
			validPerpMid,
			`Horizontal WoodBeam at mid-height of vertical WoodBeam should be valid, got {tostring(BuildState.ValidationReason)} ({tostring(BuildState.ValidationDetail)})`
		)
		local okPerp2, resPerp2 = BuildPlacementController.PlaceCurrentPiece(sendToServer)
		assertTrue(okPerp2 and resPerp2 ~= nil and resPerp2.Success, `Perpendicular mid-height WoodBeam failed: {tostring(resPerp2 and resPerp2.ErrorMessage)}`)

		-- 1 (cont.). Dos WoodBeam conectadas extremo con extremo: extender la viga horizontal de (0, 0.5, 2.5) hasta (0, 0.5, 6.5)
		local validEndToEnd, _ = BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(Vector3.new(0, 0.5, 4.5)),
			bz.CFrame:VectorToWorldSpace(Vector3.new(0, 0, 1))
		)
		assertTrue(validEndToEnd, `End-to-end WoodBeam should be valid, got {tostring(BuildState.ValidationReason)}`)
		local okE2E, resE2E = BuildPlacementController.PlaceCurrentPiece(sendToServer)
		assertTrue(okE2E and resE2E ~= nil and resE2E.Success, "End-to-end WoodBeam placement failed")

		-- 3. WoodBeam conectada con WoodBlock (y viceversa, sobre la viga a media altura para apoyar sin enterrarse en Platform)
		BuildState.SelectItem("WoodBlock")
		BuildState.ResetRotation()
		local validBlock, _ = BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(Vector3.new(0, 2.0, -4.5)),
			bz.CFrame:VectorToWorldSpace(Vector3.new(0, 0, -1))
		)
		assertTrue(validBlock, `WoodBlock connected to WoodBeam should be valid, got {tostring(BuildState.ValidationReason)}`)
		local okBlock, resBlock = BuildPlacementController.PlaceCurrentPiece(sendToServer)
		assertTrue(okBlock and resBlock ~= nil and resBlock.Success, "WoodBlock connected to WoodBeam failed")

		-- 4. Conexiones en distintas orientaciones de 90° (R / T / Y) sobre el WoodBlock
		BuildState.SelectItem("WoodBeam")
		BuildState.ResetRotation()
		BuildState.RotateY() -- R: 4x1x1 a lo largo de X
		BuildState.RotateX() -- T: giro de 90° sobre eje X manteniendo extensión 4x1x1
		local blockPos = ((resBlock :: BuildProtocol.BuildOperationResponse).PlacedPiece :: VehicleTypes.BlueprintPiece).LocalCFrame.Position
		local validRot90, _ = BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(blockPos + Vector3.new(1, 0, 0)),
			bz.CFrame:VectorToWorldSpace(Vector3.new(1, 0, 0))
		)
		assertTrue(validRot90, `90-degree rotated WoodBeam on WoodBlock should be valid, got {tostring(BuildState.ValidationReason)}`)
		local okRot90, resRot90 = BuildPlacementController.PlaceCurrentPiece(sendToServer)
		assertTrue(okRot90 and resRot90 ~= nil and resRot90.Success, "Rotated 90-degree WoodBeam placement failed")

		-- También probar rotación Y (eje Z) sobre la cara superior del WoodBlock
		BuildState.ResetRotation()
		BuildState.RotateZ() -- Y: giro de 90° en eje Z
		local validRotZ, _ = BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(blockPos + Vector3.new(0, 1, 0)),
			bz.CFrame:VectorToWorldSpace(Vector3.new(0, 1, 0))
		)
		assertTrue(validRotZ, `Z-rotated WoodBeam on top of WoodBlock should be valid, got {tostring(BuildState.ValidationReason)}`)
		local okRotZ, resRotZ = BuildPlacementController.PlaceCurrentPiece(sendToServer)
		assertTrue(okRotZ and resRotZ ~= nil and resRotZ.Success, "Z-rotated WoodBeam placement failed")

		-- 5. Conexiones cerca del borde de BuildZone (X = 17..20 en BuildZone de 40x1x40)
		local resBorderBase = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "border_chain_1",
			ItemId = "WoodBeam",
			LocalCFrame = CFrame.new(7.0, 0.5, blockPos.Z) * BuildRotation.RotateY(BuildRotation.Identity(), 1),
		})
		local resBorder2 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "border_chain_2",
			ItemId = "WoodBeam",
			LocalCFrame = CFrame.new(11.0, 0.5, blockPos.Z) * BuildRotation.RotateY(BuildRotation.Identity(), 1),
		})
		local resBorder3 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "border_chain_3",
			ItemId = "WoodBeam",
			LocalCFrame = CFrame.new(15.0, 0.5, blockPos.Z) * BuildRotation.RotateY(BuildRotation.Identity(), 1),
		})
		local resBorderBlock = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "border_chain_block",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(18.0, 1.0, blockPos.Z), -- Ocupa X = [17, 19]
		})
		local resBorderEdge = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "border_chain_edge",
			ItemId = "WoodBeam",
			LocalCFrame = CFrame.new(19.5, 2.0, blockPos.Z) * BuildRotation.RotateX(BuildRotation.Identity(), 1), -- Viga vertical en X = [19, 20], justo en el límite +20 de BuildZone
		})
		assertTrue(
			resBorderBase.Success and resBorder2.Success and resBorder3.Success and resBorderBlock.Success and resBorderEdge.Success,
			`Border connection failed: {tostring(resBorderEdge.ErrorCode)} - {tostring(resBorderEdge.ErrorMessage)}`
		)

		-- 6. Fase 2.4.2: Pieza suelta distante dentro de BuildZone es válida en cliente y servidor con 0 conexiones
		local validFar, _ = BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(Vector3.new(-15, 0, -15)),
			bz.CFrame.UpVector
		)
		assertTrue(validFar and BuildState.ValidationReason == nil, `Distant loose piece inside BuildZone should be valid, got {tostring(BuildState.ValidationReason)}`)

		local resFarServer = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "far_loose_valid",
			ItemId = "WoodBeam",
			LocalCFrame = CFrame.new(-15, 0.5, -15),
		})
		assertTrue(resFarServer.Success, `Server must allow distant loose piece, got {tostring(resFarServer.ErrorCode)}`)

		-- 7. Rechazo de piezas superpuestas
		local resOverlapServer = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "overlap_vertical",
			ItemId = "WoodBeam",
			LocalCFrame = CFrame.new(0, 0.5, 2.0), -- Se superpone 0.5 studs con la viga vertical en Z = [-0.5, 0.5]
		})
		assertTrue(not resOverlapServer.Success and resOverlapServer.ErrorCode == BuildProtocol.ErrorCodes.PieceOverlap, `Server must reject overlapping piece, got {tostring(resOverlapServer.ErrorCode)}`)

		BuildPreviewController.DestroyGhost()
		BuildState.Reset()
		BuildService._ResetForTests()
		VehicleBlueprintService._ResetForTests()
		ConnectionService._ResetForTests()
		PlotService._ResetForTests()
		tempPlots:Destroy()
	end)

	runTest("Security: BuildService and BuildPayloadValidator reject all 12 exploit/malformed attack vectors and enforce TokenBucket per player", function()
		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = "TempSecurityPlots"
		tempPlots.Parent = Workspace

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = plotSpawns,
			PlotsParent = tempPlots,
			PlotCount = 2,
		})

		ConnectionService._ResetForTests()
		ConnectionService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
		InventoryService.Init()

		VehicleBlueprintService._ResetForTests()
		VehicleBlueprintService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		BuildService._ResetForTests()
		BuildService.Init()

		local virtualNow = 100
		BuildService._SetRateLimitClockForTests(function()
			return virtualNow
		end)

		local p1: PlotService.PlayerLike = { UserId = 71001, Name = "Defender1" }
		local p2: PlotService.PlayerLike = { UserId = 71002, Name = "Attacker2" }
		local plot1 = PlotService.Assign(p1) :: PlotService.PlotRecord
		local plot2 = PlotService.Assign(p2) :: PlotService.PlotRecord

		-- Colocar pieza inicial en p1
		local seedRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "sec_seed_1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
			Config = { FuelType = "Regular" }, -- Config benigno sí permitido y clonado
		})
		assertTrue(seedRes.Success and seedRes.PlacedPiece ~= nil, "Seed piece with safe Config must succeed")
		local p1PieceId = (seedRes.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

		-- 1. Intentar colocar pieza en base ajena (suplantando PlotId / OwnerUserId)
		local spoofPlotRes = BuildService.ProcessRequest(p2, {
			Action = "PlacePiece",
			ClientOpId = "atk_spoof_plot",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
			PlotId = plot1.PlotId,
		})
		assertTrue(not spoofPlotRes.Success and spoofPlotRes.ErrorCode == BuildProtocol.ErrorCodes.NotPlotOwner, `Expected NotPlotOwner for PlotId spoof, got {tostring(spoofPlotRes.ErrorCode)}`)
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(p1).Pieces, 1, "Plot1 blueprint must remain untouched")

		local spoofOwnerRes = BuildService.ProcessRequest(p2, {
			Action = "PlacePiece",
			ClientOpId = "atk_spoof_owner",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
			OwnerUserId = p1.UserId,
		})
		assertTrue(not spoofOwnerRes.Success and spoofOwnerRes.ErrorCode == BuildProtocol.ErrorCodes.NotPlotOwner, "Expected NotPlotOwner for OwnerUserId spoof")
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(p2).Pieces, 0, "Attacker blueprint remains empty")

		-- 2. Intentar eliminar pieza de otro jugador
		local stealDelRes = BuildService.ProcessRequest(p2, {
			Action = "RemovePiece",
			ClientOpId = "atk_del_other",
			PieceInstanceId = p1PieceId,
		})
		assertTrue(not stealDelRes.Success and stealDelRes.ErrorCode == BuildProtocol.ErrorCodes.PieceNotFound, "Expected PieceNotFound deleting other player's piece")
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(p1).Pieces, 1, "Victim piece must still exist")

		-- 3. Enviar ItemId inexistente
		local unknownItemRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_bad_item",
			ItemId = "OrbitalLaserCannon",
			LocalCFrame = CFrame.new(2, 1.0, 0),
		})
		assertTrue(not unknownItemRes.Success and unknownItemRes.ErrorCode == BuildProtocol.ErrorCodes.UnknownItem, "Expected UnknownItem")

		-- 4. Enviar InstanceId falsificado / malformado
		local forgedIdRes = BuildService.ProcessRequest(p1, {
			Action = "RemovePiece",
			ClientOpId = "atk_forged_id",
			PieceInstanceId = "piece_forged_999999",
		})
		assertTrue(not forgedIdRes.Success and forgedIdRes.ErrorCode == BuildProtocol.ErrorCodes.PieceNotFound, "Expected PieceNotFound for forged id")

		local injectedPathRes = BuildService.ProcessRequest(p1, {
			Action = "RemovePiece",
			ClientOpId = "atk_path_id",
			PieceInstanceId = "../../AdminScript",
		})
		assertTrue(not injectedPathRes.Success and injectedPathRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Expected InvalidPayload for illegal chars in InstanceId")

		-- 5. Enviar CFrame con NaN, +Inf y -Inf
		local nanRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_nan",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0 / 0, 1.0, 0),
		})
		assertTrue(not nanRes.Success and nanRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidCFrame, "Expected InvalidCFrame for NaN")

		local infRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_inf",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(math.huge, 1.0, -math.huge),
		})
		assertTrue(not infRes.Success and infRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidCFrame, "Expected InvalidCFrame for Infinity")

		-- 6. Enviar rotación no permitida (30°)
		local badRotRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_badrot",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0) * CFrame.Angles(0, math.rad(30), 0),
		})
		assertTrue(not badRotRes.Success and badRotRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidRotation, "Expected InvalidRotation")

		-- 7. Colocar fuera de BuildZone
		local oobRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_oob",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 50),
		})
		assertTrue(not oobRes.Success and oobRes.ErrorCode == BuildProtocol.ErrorCodes.OutOfBounds, "Expected OutOfBounds")

		-- 8. Payloads excesivamente grandes, profundos, cíclicos, con Instances o reservados
		local hugeStrRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = string.rep("X", 200),
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
		})
		assertTrue(not hugeStrRes.Success and hugeStrRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Oversized ClientOpId rejected")

		local cyclicCfg: { [string]: any } = {}
		cyclicCfg.Self = cyclicCfg
		local cyclicRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_cyclic",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
			Config = cyclicCfg,
		})
		assertTrue(not cyclicRes.Success and cyclicRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Cyclic Config rejected")

		local deepCfg = { A = { B = { C = 1 } } }
		local deepRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_deep",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
			Config = deepCfg,
		})
		assertTrue(not deepRes.Success and deepRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Deeply nested Config rejected")

		local oversizedCfg: { [string]: any } = {}
		for k = 1, GameConfig.Building.MaxConfigEntries + 5 do
			oversizedCfg[`k{k}`] = k
		end
		local bigCfgRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_bigcfg",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
			Config = oversizedCfg,
		})
		assertTrue(not bigCfgRes.Success and bigCfgRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Oversized Config table rejected")

		local tempPart = Instance.new("Part")
		local instCfgRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_instcfg",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
			Config = { Target = tempPart },
		})
		tempPart:Destroy()
		assertTrue(not instCfgRes.Success and instCfgRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Instance inside Config rejected")

		local reservedCfgRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_rescfg",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
			Config = { MaxDurability = 999999 },
		})
		assertTrue(not reservedCfgRes.Success and reservedCfgRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Reserved key in Config rejected")

		local extraFieldsRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_extra",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
			PieceSize = Vector3.new(100, 100, 100),
		})
		assertTrue(not extraFieldsRes.Success and extraFieldsRes.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Unknown root field PieceSize rejected")

		-- 9. Repetir ClientOpId (idempotencia estricta)
		local repeatRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "sec_seed_1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0), -- Incluso intentando cambiar coordenadas con mismo ClientOpId
		})
		assertTrue(repeatRes.Success and (repeatRes.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId == p1PieceId, "Repeated ClientOpId returns cached idempotent response")
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(p1).Pieces, 1, "Repeated ClientOpId did not duplicate piece")

		-- 10. Superar rate limit en p2 y verificar que p1 no se ve afectado + recarga por tiempo en TokenBucket
		virtualNow = 200
		local blockedCount = 0
		for burst = 1, GameConfig.Building.RateLimitBurstWrite + 5 do
			local r = BuildService.ProcessRequest(p2, {
				Action = "PlacePiece",
				ClientOpId = `spam_w_{burst}`,
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			if r.ErrorCode == BuildProtocol.ErrorCodes.RateLimited then
				blockedCount += 1
			end
		end
		assertTrue(blockedCount >= 5, `Write rate limiter should block excess burst (>=5), blocked {blockedCount}`)

		-- p1 sigue teniendo tokens intactos sin afectarse por el abuso de p2
		local p1AfterP2Spam = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "p1_unaffected",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
		})
		assertTrue(p1AfterP2Spam.Success, "p1 must remain unaffected while p2 is rate limited")

		-- Rate limit independiente para lecturas (GetBlueprint)
		local readBlocked = 0
		for rb = 1, GameConfig.Building.RateLimitBurstRead + 3 do
			local rr = BuildService.ProcessRequest(p2, { Action = "GetBlueprint" })
			if rr.ErrorCode == BuildProtocol.ErrorCodes.RateLimited then
				readBlocked += 1
			end
		end
		assertTrue(readBlocked >= 3, `Read rate limiter should block excess GetBlueprint spam, blocked {readBlocked}`)

		-- Recarga de Token Bucket tras avanzar reloj virtual 1 segundo
		virtualNow = 201
		local p2Recovered = BuildService.ProcessRequest(p2, {
			Action = "PlacePiece",
			ClientOpId = "p2_after_refill",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0), -- Adyacente a (0,1.0,0) colocado por spam_w_1
		})
		assertTrue(
			p2Recovered.Success,
			`p2 TokenBucket should refill after 1 second, got {tostring(p2Recovered.ErrorCode)} - {tostring(p2Recovered.ErrorMessage)}`
		)

		-- 11. Superar límite máximo de piezas (500 en Fase 4.1)
		-- Construir piezas restantes conectadas en serpentina compacta 10x10x5 (Y=1, 3, 5, 7, 9)
		local p2Count = #VehicleBlueprintService.GetBlueprintSnapshot(p2).Pieces
		local capPositions: { Vector3 } = {}
		for layer = 0, 4 do
			local y = 1.0 + layer * 2.0
			local zStart = if layer % 2 == 0 then 0 else 9
			local zEnd = if layer % 2 == 0 then 9 else 0
			local zStep = if layer % 2 == 0 then 1 else -1
			for lz = zStart, zEnd, zStep do
				for lx = 0, 9 do
					local dirX = if (lz % 2 == layer % 2) then lx else (9 - lx)
					if not (layer == 0 and lz == 0 and (dirX == 0 or dirX == 1)) then
						table.insert(capPositions, Vector3.new(dirX * 2, y, lz * 2))
					end
				end
			end
		end

		for step, nextPos in ipairs(capPositions) do
			if p2Count >= GameConfig.Building.MaxPiecesPerVehicle then
				break
			end
			virtualNow += 1
			local okAdd = BuildService.ProcessRequest(p2, {
				Action = "PlacePiece",
				ClientOpId = `cap_{step}`,
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(nextPos),
			})
			assertTrue(okAdd.Success, `Security cap step {step} failed at {tostring(nextPos)}: {tostring(okAdd.ErrorCode)} - {tostring(okAdd.ErrorMessage)}`)
			p2Count += 1
		end
		assertEqual(
			p2Count,
			GameConfig.Building.MaxPiecesPerVehicle,
			`p2 reached MaxPiecesPerVehicle ({GameConfig.Building.MaxPiecesPerVehicle})`
		)

		virtualNow += 1
		local overLimitRes = BuildService.ProcessRequest(p2, {
			Action = "PlacePiece",
			ClientOpId = "atk_over_max_pieces",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, -2),
		})
		assertTrue(
			not overLimitRes.Success and overLimitRes.ErrorCode == BuildProtocol.ErrorCodes.MaxPiecesReached,
			`Expected MaxPiecesReached on piece #{GameConfig.Building.MaxPiecesPerVehicle + 1}, got {tostring(overLimitRes.ErrorCode)}`
		)

		-- 12. Enviar operaciones después de perder la estación
		PlotService.Release(p1)
		virtualNow += 1
		local afterLossRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "atk_after_release",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(4, 1.0, 0),
		})
		assertTrue(not afterLossRes.Success and afterLossRes.ErrorCode == BuildProtocol.ErrorCodes.NoAssignedPlot, `Expected NoAssignedPlot after plot release, got {tostring(afterLossRes.ErrorCode)}`)
		assertEqual(#(plot1.DynamicContainer:GetChildren()), 0, "Released Plot1 DynamicContainer must be empty")

		-- Liberar p2 también y comprobar limpieza total de cachés y estadísticas
		PlotService.Release(p2)
		local statsMid = BuildService.GetTrackedPlayerStats()
		assertEqual(statsMid.CachedOpPlayers, 0, "Zero CachedOpPlayers after plot releases")
		assertEqual(statsMid.RateLimiterPlayers, 1, "Connected p1 without plot remains rate-limited after post-release spam")
		BuildService.ClearPlayer(p1) -- Simula PlayerRemoving de p1
		local statsAfter = BuildService.GetTrackedPlayerStats()
		assertEqual(statsAfter.CachedOpPlayers, 0, "Zero CachedOpPlayers after disconnect")
		assertEqual(statsAfter.RateLimiterPlayers, 0, "Zero RateLimiterPlayers after PlayerRemoving")
		assertEqual(ConnectionService.GetTrackedCacheCount(), 0, "Zero ConnectionService caches after releases")
		assertEqual(VehicleBlueprintService.GetTrackedPlayerCount(), 0, "Zero VehicleBlueprintService blueprints after releases")

		BuildService._ResetForTests()
		VehicleBlueprintService._ResetForTests()
		ConnectionService._ResetForTests()
		PlotService._ResetForTests()
		tempPlots:Destroy()
	end)

	runTest("Synchronization: BlueprintSyncEvent delta updates, monotonic rejection of duplicates/stale ops, cross-player filter, timeouts, and GetBlueprint recovery", function()
		local StarterPlayer = game:GetService("StarterPlayer")
		local controllers = StarterPlayer.StarterPlayerScripts.Client.Controllers
		local BuildState = require(controllers.BuildState)
		local BuildPreviewController = require(controllers.BuildPreviewController)
		local BuildPlacementController = require(controllers.BuildPlacementController)
		local BuildSelectionController = require(controllers.BuildSelectionController)

		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = "TempSyncPlots"
		tempPlots.Parent = Workspace

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = plotSpawns,
			PlotsParent = tempPlots,
			PlotCount = 2,
		})

		PreviewAssetService._ResetForTests()
		PreviewAssetService.Init({
			ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets"),
			TargetParent = ReplicatedStorage,
		})

		ConnectionService._ResetForTests()
		ConnectionService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
		InventoryService.Init()

		VehicleBlueprintService._ResetForTests()
		VehicleBlueprintService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		BuildService._ResetForTests()
		BuildService.Init()

		local p1: PlotService.PlayerLike = { UserId = 72001, Name = "SyncPlayer1" }
		local p2: PlotService.PlayerLike = { UserId = 72002, Name = "SyncPlayer2" }
		local plot1 = PlotService.Assign(p1) :: PlotService.PlotRecord
		PlotService.Assign(p2)

		local receivedEventsForP1: { BuildProtocol.BlueprintSyncPayload } = {}
		local unsubSync = BuildService.RegisterSyncListener(function(targetPlayer, payload)
			if targetPlayer.UserId == p1.UserId then
				table.insert(receivedEventsForP1, payload)
			end
		end)

		BuildState.Reset()
		BuildState.SetExpectedOwner(p1.UserId)
		BuildState.SetPlot(plot1.Model, plot1.Zones.BuildZone)
		BuildState.SetActive(true)
		BuildPreviewController._ClearGeometryCacheForTests()

		-- Servidor coloca pieza 1 y 2 para generar eventos BlueprintSyncEvent de p1
		local r1 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "sync_1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
		})
		local r2 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "sync_2",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
		})
		assertTrue(r1.Success and r2.Success, "Server placed 2 pieces")
		task.wait() -- Permitir task.spawn de SyncListener

		assertEqual(#receivedEventsForP1, 2, "2 BlueprintSyncEvent payloads emitted for p1")
		assertEqual(receivedEventsForP1[1].Type, BuildProtocol.SyncTypes.PiecePlaced, "First event type")

		-- Aplicar evento 1 (Rev 1)
		local app1, gap1 = BuildState.ApplySyncEvent(receivedEventsForP1[1])
		assertTrue(app1 and not gap1 and BuildState.BlueprintRevision == 1 and #BuildState.BlueprintPieces == 1, "Apply rev 1 delta")

		-- Confirmación duplicada (Rev 1 nuevamente): debe ignorarse y NO crear 2da pieza
		local appDup, gapDup = BuildState.ApplySyncEvent(receivedEventsForP1[1])
		assertTrue(not appDup and not gapDup and #BuildState.BlueprintPieces == 1, "Duplicate Rev 1 event must be ignored")

		-- Aplicar evento 2 (Rev 2)
		local app2, gap2 = BuildState.ApplySyncEvent(receivedEventsForP1[2])
		assertTrue(app2 and not gap2 and BuildState.BlueprintRevision == 2 and #BuildState.BlueprintPieces == 2, "Apply rev 2 delta")

		-- Respuesta/evento de otro jugador (p2) debe ser rechazada
		local otherApplied, otherGap = BuildState.ApplySyncEvent({
			Type = "PiecePlaced",
			OwnerUserId = p2.UserId,
			BlueprintId = `bp_{p2.UserId}`,
			Revision = 99,
			PlacedPiece = {
				InstanceId = "piece_p2_hack",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			},
		})
		assertTrue(not otherApplied and not otherGap and BuildState.BlueprintRevision == 2 and #BuildState.BlueprintPieces == 2, "Cross-player sync event must be ignored")

		-- Eliminar pieza 2 en servidor (Rev 3) y verificar detección de brecha si faltó evento, o aplicar Rev 3 y luego evento viejo Rev 2
		local r3 = BuildService.ProcessRequest(p1, {
			Action = "RemovePiece",
			ClientOpId = "sync_3",
			PieceInstanceId = (r2.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId,
		})
		assertTrue(r3.Success, "Remove piece 2 succeeded")
		task.wait()
		local delEvent = receivedEventsForP1[3]
		local app3, gap3 = BuildState.ApplySyncEvent(delEvent)
		assertTrue(app3 and not gap3 and BuildState.BlueprintRevision == 3 and #BuildState.BlueprintPieces == 1, "Remove piece delta applied")

		-- Evento tardío (Rev 2 de colocación ya obsoleta): no debe restaurar pieza eliminada ni bajar revisión
		local lateApplied, _ = BuildState.ApplySyncEvent(receivedEventsForP1[2])
		assertTrue(not lateApplied and BuildState.BlueprintRevision == 3 and #BuildState.BlueprintPieces == 1, "Late Rev 2 event must not resurrect deleted piece")

		-- Brecha de revisión (salta de Rev 3 a Rev 5) -> debe señalar needsFullResync y recuperarse con GetBlueprint
		local gapApplied, needsResync = BuildState.ApplySyncEvent({
			Type = "PiecePlaced",
			OwnerUserId = p1.UserId,
			BlueprintId = `bp_{p1.UserId}`,
			Revision = 5,
			PlacedPiece = {
				InstanceId = "piece_future",
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(6, 1.0, 0),
			},
		})
		assertTrue(not gapApplied and needsResync, "Revision jump must trigger needsFullResync")
		local syncedOk = BuildPlacementController.SyncBlueprintFromServer(function(req)
			return BuildService.ProcessRequest(p1, req)
		end)
		assertTrue(syncedOk and BuildState.BlueprintRevision == 3 and #BuildState.BlueprintPieces == 1, "GetBlueprint recovery synchronized revision 3")

		-- Timeout y recuperación cuando se pierde respuesta (servidor sí la procesó, cliente perdió respuesta)
		BuildPlacementController.SetOperationTimeoutSeconds(0.1)
		BuildState.SelectItem("WoodBlock")
		BuildState.ResetRotation()
		local prevOk, _ = BuildPreviewController.UpdateAtWorldPoint(
			plot1.Zones.BuildZone.CFrame:PointToWorldSpace(Vector3.new(2, 0, 0)),
			plot1.Zones.BuildZone.CFrame.UpVector
		)
		assertTrue(prevOk, "Preview valid next to piece 1")

		local lostOk, lostRes = BuildPlacementController.PlaceCurrentPiece(function(req)
			if req.Action == "PlacePiece" then
				-- Simular que servidor procesó pero la respuesta tardó/se perdió > 0.1s
				BuildService.ProcessRequest(p1, req)
				task.wait(0.25)
				return { Success = false, Revision = 0 }
			end
			return BuildService.ProcessRequest(p1, req)
		end)
		assertTrue(not lostOk and lostRes == nil, "Timed-out op returns failure cleanly")
		assertEqual(BuildPlacementController.GetPendingCount(), 0, "Pending op must not remain stuck after timeout")
		-- Recuperación automática vía GetBlueprint debe haber sincronizado la pieza colocada (ahora 2 piezas, Rev 4)
		assertEqual(#BuildState.BlueprintPieces, 2, "Automatic GetBlueprint recovery synced server-committed piece after lost ack")
		assertEqual(BuildState.BlueprintRevision, 4, "Synced to Rev 4")

		-- Protección contra doble clic en PlaceCurrentPiece y DeleteSelectedPiece mientras hay op en vuelo
		BuildPlacementController.SetOperationTimeoutSeconds(2.0)
		BuildSelectionController.SetOperationTimeoutSeconds(2.0)
		local deleteInvokeCount = 0
		local p2Id = BuildState.BlueprintPieces[2].InstanceId
		assertTrue(BuildSelectionController.SelectPieceById(p2Id), "Select piece 2 for async delete")

		local delRes1: boolean? = nil
		local delRes2: boolean? = nil
		task.spawn(function()
			local ok1 = BuildSelectionController.DeleteSelectedPiece(function(req)
				deleteInvokeCount += 1
				task.wait(0.08)
				return BuildService.ProcessRequest(p1, req)
			end)
			delRes1 = ok1
		end)
		task.wait(0.01)
		-- Segundo clic inmediato en Delete para la misma pieza debe ser bloqueado por _pendingDeleteIds
		delRes2 = BuildSelectionController.DeleteSelectedPiece(function(req)
			deleteInvokeCount += 1
			return BuildService.ProcessRequest(p1, req)
		end)
		task.wait(0.12)
		assertTrue(delRes1 == true and delRes2 == false, "Double delete while in-flight must only execute once")
		assertEqual(deleteInvokeCount, 1, "Server invoked only once for double-clicked Delete")
		assertEqual(BuildSelectionController.GetPendingDeleteCount(), 0, "PendingDeleteCount cleared after completion")

		unsubSync()
		BuildPlacementController.SetOperationTimeoutSeconds(nil)
		BuildSelectionController.SetOperationTimeoutSeconds(nil)
		BuildSelectionController.ClearSelection()
		BuildPlacementController.ClearPending()
		BuildPreviewController.DestroyGhost()
		BuildState.Reset()
		BuildService._ResetForTests()
		VehicleBlueprintService._ResetForTests()
		ConnectionService._ResetForTests()
		PlotService._ResetForTests()
		tempPlots:Destroy()
	end)

	runTest("Optimization: SpatialIndex equivalence with brute-force math, O(1) incremental remove/clear, and lifecycle cleanup", function()
		local assetsRoot = ServerStorage:WaitForChild("ItemAssets")
		local blockModel = assetsRoot:FindFirstChild("WoodBlock", true) :: Model
		local beamModel = assetsRoot:FindFirstChild("WoodBeam", true) :: Model
		assertTrue(blockModel ~= nil and beamModel ~= nil, "ItemAssets WoodBlock and WoodBeam must exist")

		local blockAtts, blockSize = ConnectionMath.ExtractModelAttachments(blockModel)
		local beamAtts, beamSize = ConnectionMath.ExtractModelAttachments(beamModel)

		local spatial = ConnectionMath.CreateSpatialIndex(GameConfig.Building.SpatialCellSize)
		local specsList: { ConnectionMath.PieceGeometrySpec } = {}

		local function addExisting(id: string, itemId: string, cf: CFrame, size: Vector3, atts: { ConnectionMath.AttachmentSpec })
			local spec = ConnectionMath.PreparePieceSpec({
				InstanceId = id,
				ItemId = itemId,
				LocalCFrame = cf,
				Size = size,
				Attachments = atts,
			})
			table.insert(specsList, spec)
			spatial:Insert(spec)
		end

		addExisting("sp_1", "WoodBlock", CFrame.new(0, 0.5, 0), blockSize, blockAtts)
		addExisting("sp_2", "WoodBlock", CFrame.new(2, 0.5, 0), blockSize, blockAtts)
		addExisting("sp_3", "WoodBlock", CFrame.new(4, 0.5, 0), blockSize, blockAtts)
		addExisting("sp_4", "WoodBeam", CFrame.new(7, 0.5, 0) * BuildRotation.RotateY(BuildRotation.Identity(), 1), beamSize, beamAtts)
		addExisting("sp_5", "WoodBeam", CFrame.new(4, 3.5, 0) * BuildRotation.RotateX(BuildRotation.Identity(), 1), beamSize, beamAtts)
		assertEqual(spatial:Count(), 5, "SpatialIndex tracks 5 inserted pieces")

		-- Equivalencia exacta entre FindCompatibleConnections sin índice y con SpatialIndex
		local candConnSpec = ConnectionMath.PreparePieceSpec({
			InstanceId = "cand_conn",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 2.5, 0),
			Size = blockSize,
			Attachments = blockAtts,
		})
		local bruteConns = ConnectionMath.FindCompatibleConnections(candConnSpec, specsList, nil, nil, nil)
		local indexedConns = ConnectionMath.FindCompatibleConnections(candConnSpec, specsList, nil, nil, spatial)
		assertEqual(#indexedConns, #bruteConns, "SpatialIndex FindCompatibleConnections must match brute-force count")
		assertTrue(#indexedConns >= 1, "Candidate must find compatible connection on sp_2")
		assertEqual(indexedConns[1].PieceAInstanceId, bruteConns[1].PieceAInstanceId, "Connection PieceA matches")
		assertEqual(indexedConns[1].PieceBInstanceId, bruteConns[1].PieceBInstanceId, "Connection PieceB matches")
		assertEqual(indexedConns[1].AttachmentA, bruteConns[1].AttachmentA, "Connection AttachmentA matches")
		assertEqual(indexedConns[1].AttachmentB, bruteConns[1].AttachmentB, "Connection AttachmentB matches")

		-- Equivalencia exacta de AnyOverlap
		local candOverlap = ConnectionMath.PreparePieceSpec({
			InstanceId = "cand_ov",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2.1, 0.5, 0),
			Size = blockSize,
			Attachments = blockAtts,
		})
		local bOv, bBlocker = ConnectionMath.AnyOverlap(candOverlap, specsList, nil, nil)
		local iOv, iBlocker = ConnectionMath.AnyOverlap(candOverlap, specsList, nil, spatial)
		assertEqual(iOv, bOv, "SpatialIndex AnyOverlap must match brute-force")
		assertTrue(bBlocker ~= nil and iBlocker ~= nil and bBlocker.InstanceId == iBlocker.InstanceId, "Overlap blocker ID matches")

		-- Equivalencia exacta de ComputeSmartSnap con índice espacial
		local nearCF = CFrame.new(2, 2.85, 0)
		local bSnap = ConnectionMath.ComputeSmartSnap(nearCF, blockSize, blockAtts, specsList, nil, -0.5, nil)
		local iSnap = ConnectionMath.ComputeSmartSnap(nearCF, blockSize, blockAtts, specsList, nil, -0.5, spatial)
		assertTrue(bSnap ~= nil and iSnap ~= nil, "Both brute-force and SpatialIndex SmartSnap must succeed")
		assertTrue(
			((bSnap :: ConnectionMath.SmartSnapMatch).SnappedLocalCFrame.Position - (iSnap :: ConnectionMath.SmartSnapMatch).SnappedLocalCFrame.Position).Magnitude < 1e-4,
			"SpatialIndex ComputeSmartSnap CFrame matches brute-force"
		)

		-- Remove y Clear limpian celdas correctamente
		assertTrue(spatial:Remove("sp_2"), "Remove existing piece from SpatialIndex")
		assertEqual(spatial:Count(), 4, "SpatialIndex count decrements after Remove")
		assertTrue(not spatial:Remove("nonexistent"), "Remove nonexistent returns false")
		local postRemoveConns = ConnectionMath.FindCompatibleConnections(candConnSpec, specsList, nil, nil, spatial)
		assertEqual(#postRemoveConns, 0, "Removed piece is no longer returned by SpatialIndex queries")

		spatial:Clear()
		assertEqual(spatial:Count(), 0, "SpatialIndex Count is 0 after Clear")
	end)

	runTest("[SIMULATED SERVER MULTIPLAYER] Concurrent building, isolation, replication check, disconnect cleanup & plot reuse for 2, 5, and 10 players", function()
		local baseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model
		local plotSpawns = Workspace:WaitForChild("PlotSpawns") :: Folder
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = "TempSimMultiplayerPlots"
		tempPlots.Parent = Workspace

		PlotService._ResetForTests()
		PlotService.Init({
			BaseTemplate = baseTemplate,
			PlotSpawnsFolder = plotSpawns,
			PlotsParent = tempPlots,
			PlotCount = 10,
		})

		ConnectionService._ResetForTests()
		ConnectionService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
		InventoryService.Init()

		VehicleBlueprintService._ResetForTests()
		VehicleBlueprintService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })

		BuildService._ResetForTests()
		BuildService.Init()

		-- Escenario 1: Validación progresiva con 2, 5 y 10 jugadores simultáneos + visibilidad mutua en Workspace + aislamiento
		local players10: { PlotService.PlayerLike } = {}
		local plotsByIdx: { PlotService.PlotRecord } = {}
		for i = 1, 10 do
			local p: PlotService.PlayerLike = { UserId = 81000 + i, Name = `SimBuilder_{i}` }
			players10[i] = p
			local pl = PlotService.Assign(p) :: PlotService.PlotRecord
			assertTrue(pl ~= nil, `Assign plot for SimBuilder_{i}`)
			plotsByIdx[i] = pl
		end

		-- Asegurar estaciones distintas
		local uniquePlots: { [string]: boolean } = {}
		for i = 1, 10 do
			assertTrue(not uniquePlots[plotsByIdx[i].PlotId], "Each of 10 builders must have unique PlotId")
			uniquePlots[plotsByIdx[i].PlotId] = true
		end

		-- Etapas explícitas de concurrencia: primero 2 jugadores, luego primeros 5, finalmente los 10 completos
		local targetSizes = { 6, 8, 10, 12, 14, 16, 18, 20, 22, 24 }
		local progress = table.create(10, 0) :: { number }
		local function advanceGroup(groupSize: number, upToStep: number)
			for step = 0, upToStep do
				for idx = 1, groupSize do
					if progress[idx] == step and step < targetSizes[idx] then
						local p = players10[idx]
						local lx = step % 5
						local lz = math.floor(step / 5)
						local dirX = if lz % 2 == 0 then lx else (4 - lx)
						local itemId = if step == targetSizes[idx] - 1 then "DriverSeat" else "WoodBlock"
						local yOffset = if itemId == "DriverSeat" then 2.5 else 1.0
						local targetPos = if itemId == "DriverSeat"
							then Vector3.new(0, yOffset, 0)
							else Vector3.new(dirX * 2, yOffset, lz * 2)

						local r = BuildService.ProcessRequest(p, {
							Action = "PlacePiece",
							ClientOpId = `mp_p{idx}_s{step}`,
							ItemId = itemId,
							LocalCFrame = CFrame.new(targetPos),
						})
						assertTrue(r.Success, `SimPlayer {idx} step {step} failed: {tostring(r.ErrorCode)} - {tostring(r.ErrorMessage)}`)
						progress[idx] += 1
					end
				end
			end
		end

		advanceGroup(2, 3)
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(players10[1]).Pieces, 4, "2-player stage P1 count")
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(players10[2]).Pieces, 4, "2-player stage P2 count")
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(players10[5]).Pieces, 0, "5/10 players untouched during 2-player stage")

		advanceGroup(5, 7)
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(players10[5]).Pieces, 8, "5-player stage P5 count")
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(players10[10]).Pieces, 0, "Player 10 untouched during 5-player stage")

		advanceGroup(10, 23)

		-- Verificar aislamiento total de Blueprints, Revisiones y presencia física replicable en Workspace.Plots
		for idx = 1, 10 do
			local p = players10[idx]
			local bp = VehicleBlueprintService.GetBlueprintSnapshot(p)
			assertEqual(#bp.Pieces, targetSizes[idx], `SimPlayer {idx} piece count`)
			assertEqual(bp.Revision, targetSizes[idx], `SimPlayer {idx} revision`)
			assertEqual(bp.OwnerUserId, p.UserId, `SimPlayer {idx} OwnerUserId`)

			local editable = VehicleBlueprintService.GetEditableVehicleModel(p) :: Model
			assertTrue(editable ~= nil and editable:IsDescendantOf(Workspace), `SimPlayer {idx} EditableVehicle present in Workspace for other clients to see`)
			assertEqual(#editable:GetChildren(), targetSizes[idx], `SimPlayer {idx} EditableVehicle child count`)

			-- Cada pieza en bp solo pertenece a p.UserId y nadie más puede borrarla
			local attacker = players10[(idx % 10) + 1]
			local atkDel = BuildService.ProcessRequest(attacker, {
				Action = "RemovePiece",
				ClientOpId = `atk_cross_{idx}`,
				PieceInstanceId = bp.Pieces[1].InstanceId,
			})
			assertTrue(not atkDel.Success and atkDel.ErrorCode == BuildProtocol.ErrorCodes.PieceNotFound, "Cross-player delete rejected across all 10 players")
		end

		-- Escenario 2: Desconectar jugador 3 en plena sesión y verificar que los otros 9 permanecen intactos + reasignación limpia de Plot de #3
		local leavingPlayer = players10[3]
		local freedPlotId = plotsByIdx[3].PlotId
		local freedDynContainer = plotsByIdx[3].DynamicContainer
		PlotService.Release(leavingPlayer)
		assertEqual(#freedDynContainer:GetChildren(), 0, "Freed plot DynamicContainer cleared immediately")
		assertTrue(not BuildService.ProcessRequest(leavingPlayer, {
			Action = "PlacePiece",
			ClientOpId = "ghost_after_leave",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
		}).Success, "Disconnected player cannot mutate anything")

		-- Otros jugadores (#1, #2, #5, #10) conservan su vehículo intacto y pueden seguir construyendo
		for _, survivorIdx in ipairs({ 1, 2, 5, 10 }) do
			local survBp = VehicleBlueprintService.GetBlueprintSnapshot(players10[survivorIdx])
			assertEqual(#survBp.Pieces, targetSizes[survivorIdx], `Survivor {survivorIdx} piece count unaffected by player 3 disconnect`)
		end

		-- Reemplazo entra al servidor y recibe la estación liberada completamente limpia
		local newcomer: PlotService.PlayerLike = { UserId = 82099, Name = "Newcomer" }
		local newcomerPlot = PlotService.Assign(newcomer) :: PlotService.PlotRecord
		assertTrue(newcomerPlot ~= nil and newcomerPlot.PlotId == freedPlotId, "Newcomer receives freed plot")
		assertEqual(#VehicleBlueprintService.GetBlueprintSnapshot(newcomer).Pieces, 0, "Newcomer starts with empty blueprint")
		local newPlace = BuildService.ProcessRequest(newcomer, {
			Action = "PlacePiece",
			ClientOpId = "newcomer_1",
			ItemId = "WoodBeam",
			LocalCFrame = CFrame.new(0, 0.5, 0),
		})
		assertTrue(newPlace.Success, "Newcomer can build cleanly on reused plot")

		-- Limpieza final de los 10 jugadores restantes
		for idx = 1, 10 do
			if idx ~= 3 then
				PlotService.Release(players10[idx])
			end
		end
		PlotService.Release(newcomer)
		assertEqual(PlotService.GetFreePlotCount(), 10, "All 10 plots free after cleanup")
		assertEqual(VehicleBlueprintService.GetTrackedPlayerCount(), 0, "Zero leftover blueprints")
		assertEqual(ConnectionService.GetTrackedCacheCount(), 0, "Zero leftover spatial caches")

		BuildService._ResetForTests()
		VehicleBlueprintService._ResetForTests()
		ConnectionService._ResetForTests()
		PlotService._ResetForTests()
		tempPlots:Destroy()
	end)

	runTest("Benchmark Gate: BuildBenchmarks measures 25-piece mixed vehicle cleanly with zero leftover state", function()
		local entry = BuildBenchmarks.MeasureSize(25)
		assertEqual(entry.PieceCount, 25, "Benchmark PieceCount must equal 25")
		assertEqual(entry.EditableModelCount, 25, "Benchmark must build 25 physical EditableVehicle piece models")
		assertTrue(entry.EditableDescendantCount >= 25, "Benchmark must count descendants inside EditableVehicle")
		assertTrue(entry.LastPlaceMs >= 0 and entry.ValidateConnectionsMs >= 0 and entry.SmartSnapWithIndexMs >= 0, "Benchmark timings must be non-negative")
		assertEqual(VehicleBlueprintService.GetTrackedPlayerCount(), 0, "BuildBenchmarks must clean up VehicleBlueprintService state")
		assertEqual(ConnectionService.GetTrackedCacheCount(), 0, "BuildBenchmarks must clean up ConnectionService caches")
		assertEqual(BuildService.GetTrackedPlayerStats().CachedOpPlayers, 0, "BuildBenchmarks must clean up BuildService caches")
	end)

	-- =========================================================================
	-- FASE 2.3.1 — EDITOR AVANZADO: GRID VISUAL, MODO LIBRE Y GIZMOS 3D (21-40)
	-- =========================================================================

	local function getControllersFolder()
		return game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Client"):WaitForChild("Controllers")
	end

	local function setupAdvEnv(plotCount: number?)
		local tempPlots = Instance.new("Folder")
		tempPlots.Name = "TempAdvTestsPlots"
		tempPlots.Parent = Workspace

		PlotService._ResetForTests()
		ConnectionService._ResetForTests()
		InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = true })
		VehicleBlueprintService._ResetForTests()
		BuildService._ResetForTests()
		PreviewAssetService._ResetForTests()
		ItemRegistry._ClearTestOverridesForTests()
		ItemRegistry.Init()
		InventoryService.Init()

		PlotService.Init({
			BaseTemplate = ServerStorage:WaitForChild("BaseTemplate") :: Model,
			PlotSpawnsFolder = Workspace:WaitForChild("PlotSpawns") :: Folder,
			PlotsParent = tempPlots,
			PlotCount = plotCount or 2,
		})
		PreviewAssetService.Init({
			ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets"),
			TargetParent = ReplicatedStorage,
		})
		ConnectionService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })
		VehicleBlueprintService.Init({ ItemAssetsRoot = ServerStorage:WaitForChild("ItemAssets") })
		BuildService.Init()

		local controllers = getControllersFolder()
		local BuildState = require(controllers:WaitForChild("BuildState"))
		local BuildPreviewController = require(controllers:WaitForChild("BuildPreviewController"))
		local BuildTransformController = require(controllers:WaitForChild("BuildTransformController"))
		local BuildSelectionController = require(controllers:WaitForChild("BuildSelectionController"))
		local BuildGridVisualizer = require(controllers:WaitForChild("BuildGridVisualizer"))
		local BuildAlignmentGuides = require(controllers:WaitForChild("BuildAlignmentGuides"))
		local BuildMoveGizmo = require(controllers:WaitForChild("BuildMoveGizmo"))
		local BuildRotationGizmo = require(controllers:WaitForChild("BuildRotationGizmo"))

		BuildTransformController.CancelSession()
		BuildSelectionController.ClearSelection()
		BuildPreviewController._ClearGeometryCacheForTests()
		BuildState.Reset()

		local function teardown()
			BuildTransformController.CancelSession()
			BuildSelectionController.ClearSelection()
			BuildPreviewController.DestroyGhost()
			BuildPreviewController._ClearGeometryCacheForTests()
			BuildGridVisualizer.Destroy()
			BuildAlignmentGuides.Destroy()
			BuildMoveGizmo.Destroy()
			BuildRotationGizmo.Destroy()
			BuildState.Reset()
			ItemRegistry._ClearTestOverridesForTests()
			BuildService._ResetForTests()
			VehicleBlueprintService._ResetForTests()
			InventoryService._ResetForTests(false, { AutoGrantLegacySuiteQuota = false })
			ConnectionService._ResetForTests()
			PlotService._ResetForTests()
			PreviewAssetService._ResetForTests()
			tempPlots:Destroy()
		end

		return {
			TempPlots = tempPlots,
			BuildState = BuildState,
			BuildPreviewController = BuildPreviewController,
			BuildTransformController = BuildTransformController,
			BuildSelectionController = BuildSelectionController,
			BuildGridVisualizer = BuildGridVisualizer,
			BuildAlignmentGuides = BuildAlignmentGuides,
			BuildMoveGizmo = BuildMoveGizmo,
			BuildRotationGizmo = BuildRotationGizmo,
			Teardown = teardown,
		}
	end

	-- 21
	runTest("Fase 2.3.1 [21]: Configurable grid snap supports 1, 0.5, 0.25 (default), 0.1 with flush contact on odd/fractional sizes", function()
		assertEqual(GameConfig.Building.DefaultGridResolution, 0.25, "Default grid resolution must be 0.25")
		assertEqual(BuildGrid.SnapValue(0.38), 0.5, "Default snap 0.38 -> 0.5 at 0.25? wait: floor(0.38/0.25+0.5)=2 -> 0.5")
		assertEqual(BuildGrid.SnapValue(0.14), 0.25, "Default snap 0.14 -> 0.25")

		local bzCF = CFrame.new(10, 5, -20)
		local bzSize = Vector3.new(40, 1, 40)

		for _, res in ipairs({ 1, 0.5, 0.25, 0.1 }) do
			local hitLocal = Vector3.new(1.37, -0.5, -0.63)
			local snap = BuildGrid.ComputeSnappedCFrame({
				BuildZoneCFrame = bzCF,
				BuildZoneSize = bzSize,
				WorldHitPosition = bzCF:PointToWorldSpace(hitLocal),
				WorldHitNormal = bzCF.UpVector,
				PieceSize = Vector3.new(1.5, 1.5, 3), -- SmallBooster fraccionario
				RelativeRotation = BuildRotation.Identity(),
				PositionMode = "Grid",
				GridSize = res,
			})
			assertTrue(math.abs(snap.LocalPosition.Y - 0.25) < 1e-4, `Fractional piece floor contact Y must stay flush at 0.25 for res={res}`)
			local expectedX = math.floor(hitLocal.X / res + 0.5) * res
			assertTrue(math.abs(snap.LocalPosition.X - expectedX) < 1e-4, `Expected X={expectedX} for res={res}, got {snap.LocalPosition.X}`)
		end
	end)

	-- 22
	runTest("Fase 2.3.1 [22]: WoodBeam centers smoothly over another WoodBeam and between adjacent WoodBlocks without 1.75 jump", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23101, Name = "CenterTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local bz = plot.Zones.BuildZone

		-- Dos WoodBlocks adyacentes en X = 0 y X = 2 (junta exactamente en X = 1.0)
		local r1 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "c_b1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
		})
		local r2 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "c_b2",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
		})
		assertTrue(r1.Success and r2.Success, "Base adjacent WoodBlocks must place")

		env.BuildState.SetPlot(plot.Model, bz)
		env.BuildState.SetActive(true)
		env.BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), true)
		env.BuildState.SelectItem("WoodBeam")
		env.BuildState.SetPositionMode("Grid")
		env.BuildState.SetGridResolution(0.25)

		-- Apuntar exactamente a la junta entre ambos bloques (X = 1.0, Y = 2.0 cara superior)
		local okMid, _ = env.BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(Vector3.new(1.0, 2.0, 0)),
			bz.CFrame.UpVector
		)
		assertTrue(okMid, `WoodBeam centered over seam X=1.0 must be valid, got {tostring(env.BuildState.ValidationReason)}`)
		local cfMid = env.BuildState.LastSnappedLocalCFrame :: CFrame
		assertTrue(math.abs(cfMid.Position.X - 1.0) < 0.05 and math.abs(cfMid.Position.Y - 2.5) < 0.05,
			`Expected WoodBeam centered at seam (1.0, 2.5, 0), got {tostring(cfMid.Position)}`)

		-- Apuntar sobre posición intermedia 0.5 -> nunca debe saltar de vuelta a 0 o 2
		local okHalf, _ = env.BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(Vector3.new(0.5, 2.0, 0)),
			bz.CFrame.UpVector
		)
		assertTrue(okHalf, "Intermediate 0.5 position must be valid")
		local cfHalf = env.BuildState.LastSnappedLocalCFrame :: CFrame
		assertTrue(math.abs(cfHalf.Position.X - 0.5) < 0.05, `Expected intermediate X=0.5, got {cfHalf.Position.X}`)

		-- Prueba de histéresis en borde de celda (0.125 ± epsilon)
		local s1 = BuildTransformMath.SnapValueWithHysteresis(0.12, 0.25, 0, 0.08)
		local s2 = BuildTransformMath.SnapValueWithHysteresis(0.135, 0.25, 0, 0.08)
		assertEqual(s1, 0, "Should hold cell 0 below hysteresis threshold")
		assertEqual(s2, 0, "Should still hold cell 0 inside hysteresis band (0.5+0.08)*0.25=0.145")
		local s3 = BuildTransformMath.SnapValueWithHysteresis(0.16, 0.25, 0, 0.08)
		assertEqual(s3, 0.25, "Should advance cleanly once past hysteresis band")

		env.Teardown()
	end)

	-- 23
	runTest("Fase 2.3.1 [23]: Free positioning mode permits continuous 0.01 precision while enforcing bounds, overlap, and connections", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23102, Name = "FreeTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local bz = plot.Zones.BuildZone

		local baseRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "free_base",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
		})
		assertTrue(baseRes.Success, "Base block placed")

		env.BuildState.SetPlot(plot.Model, bz)
		env.BuildState.SetActive(true)
		env.BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), true)
		env.BuildState.SelectItem("WoodBeam")
		env.BuildState.SetPositionMode("Free")
		env.BuildState.SetSmartSnapEnabled(false)

		-- Posición continua 0.37 studs sobre la cara superior del WoodBlock
		local okFree, _ = env.BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(Vector3.new(0.37, 2.0, 0.13)),
			bz.CFrame.UpVector
		)
		assertTrue(okFree, `Free placement on top surface must be valid: {tostring(env.BuildState.ValidationReason)}`)
		local freeCF = env.BuildState.LastSnappedLocalCFrame :: CFrame
		assertTrue(math.abs(freeCF.Position.X - 0.37) < 0.02 and math.abs(freeCF.Position.Z - 0.13) < 0.02,
			`Expected continuous Free pos (0.37, 2.5, 0.13), got {tostring(freeCF.Position)}`)

		-- Enviar esta posición continua al servidor -> autoritativo preserva 0.01 sin redondear a 0.25
		local serverRes = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "free_beam_exact",
			ItemId = "WoodBeam",
			LocalCFrame = freeCF,
		})
		assertTrue(serverRes.Success and serverRes.PlacedPiece ~= nil, `Server must accept Free position: {tostring(serverRes.ErrorMessage)}`)
		local placedPos = (serverRes.PlacedPiece :: VehicleTypes.BlueprintPiece).LocalCFrame.Position
		assertTrue(math.abs(placedPos.X - 0.37) < 0.015, `Server preserved Free X=0.37, got {placedPos.X}`)

		-- Verificar que modo Libre sigue rechazando fuera de zona y desconexión
		local okOut, _ = env.BuildPreviewController.UpdateAtWorldPoint(
			bz.CFrame:PointToWorldSpace(Vector3.new(45, 0, 0)),
			bz.CFrame.UpVector
		)
		assertTrue(not okOut and env.BuildState.ValidationReason == "OutOfBoundsX", "Free mode preview still rejects OutOfBoundsX")
		local srvOut = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "free_oob",
			ItemId = "WoodBeam",
			LocalCFrame = CFrame.new(45, 0.5, 0),
		})
		assertTrue(not srvOut.Success and srvOut.ErrorCode == BuildProtocol.ErrorCodes.OutOfBounds, "Server Free mode rejects OutOfBounds")

		-- Verificar nudge fino 0.01 studs
		local nudged = BuildTransformMath.NudgeLocalCFrame(CFrame.new(1, 2, 3), Vector3.xAxis, 0.01)
		assertTrue(math.abs(nudged.Position.X - 1.01) < 1e-5, "Nudge 0.01 stud precision exact")

		env.Teardown()
	end)

	-- 24
	runTest("Fase 2.3.1 [24]: Visual grid aligns to rotated BuildZone and vertical faces with pooled LineHandleAdornment (0 Parts)", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23103, Name = "GridVisTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local bz = plot.Zones.BuildZone
		local origPivot = plot.Model:GetPivot()
		plot.Model:PivotTo(CFrame.new(Vector3.new(30, 0, -25)) * CFrame.Angles(0, math.rad(37), 0))

		-- Renderizar piso horizontal con resolución 0.5
		env.BuildGridVisualizer.Render({
			BuildZone = bz,
			SurfaceOriginLocal = Vector3.new(0, -0.5, 0),
			SurfaceNormalLocal = Vector3.yAxis,
			CandidateLocalPos = Vector3.new(1, 0.5, -2),
			PieceExtents = Vector3.new(2, 2, 2),
			GridResolution = 0.5,
			PositionMode = "Grid",
			IsValid = true,
		})
		local statsFloor = env.BuildGridVisualizer.GetDebugStats()
		assertTrue(statsFloor.ActiveLines > 10 and statsFloor.PoolCapacity >= 100, "Floor visual grid should activate pooled lines")
		assertEqual(statsFloor.AdorneeName, bz.Name, "Visual grid Adornee must be BuildZone")

		-- Renderizar pared vertical (+X)
		env.BuildGridVisualizer.Render({
			BuildZone = bz,
			SurfaceOriginLocal = Vector3.new(1, 2, 0),
			SurfaceNormalLocal = Vector3.xAxis,
			CandidateLocalPos = Vector3.new(2, 2, 0),
			PieceExtents = Vector3.new(2, 2, 2),
			GridResolution = 0.25,
			PositionMode = "Grid",
			IsValid = true,
		})
		local statsWall = env.BuildGridVisualizer.GetDebugStats()
		assertTrue(statsWall.ActiveLines > 10, "Vertical wall grid must activate pooled lines")

		-- En modo Free oculta subdivisiones finas manteniendo ejes principales
		env.BuildGridVisualizer.Render({
			BuildZone = bz,
			SurfaceOriginLocal = Vector3.new(0, -0.5, 0),
			SurfaceNormalLocal = Vector3.yAxis,
			CandidateLocalPos = Vector3.new(0.17, 0.5, 0),
			PieceExtents = Vector3.new(2, 2, 2),
			GridResolution = 0.25,
			PositionMode = "Free",
			IsValid = true,
		})
		local statsFree = env.BuildGridVisualizer.GetDebugStats()
		assertEqual(statsFree.ActiveMinorLines, 0, "Free mode should hide fine grid subdivision lines")
		assertTrue(statsFree.ActiveLines <= 4, "Free mode keeps at most major axes and crosshair")

		-- Limpieza completa
		env.BuildGridVisualizer.Hide()
		env.BuildGridVisualizer.Destroy()
		local statsDestroyed = env.BuildGridVisualizer.GetDebugStats()
		assertTrue(not statsDestroyed.HasContainer, "Grid visualizer container must destroy cleanly")
		assertTrue(Workspace.CurrentCamera == nil or Workspace.CurrentCamera:FindFirstChild("BuildGridVisualizerPool") == nil, "No leftover grid pool")

		plot.Model:PivotTo(origPivot)
		env.Teardown()
	end)

	-- 25
	runTest("Fase 2.3.1 [25]: Alignment guides stay informative with SmartSnap OFF & enforce priority/hysteresis when ON", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23104, Name = "AlignTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local bz = plot.Zones.BuildZone

		BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "al_root",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
		})
		local specs = ConnectionService.BuildPieceGeometrySpecs(VehicleBlueprintService.GetBlueprintSnapshot(p1).Pieces)
		local geomBlock = ConnectionService.GetItemGeometry("WoodBlock") :: ConnectionService.CachedItemGeometry

		-- Con SmartSnap OFF y Guides ON, estando a 0.08 studs del eje X=0 y centro de pieza -> no mueve CFrame pero sí emite guías
		local rawCF = CFrame.new(0.08, 3.0, 0.05)
		local offRes = BuildAlignmentMath.ComputeAlignments({
			CandidateLocalCFrame = rawCF,
			CandidateItemId = "WoodBlock",
			CandidateSize = geomBlock.Size,
			CandidateAttachments = geomBlock.Attachments,
			ExistingSpecs = specs,
			SurfaceNormalLocal = Vector3.yAxis,
			PositionMode = "Free",
			SmartSnapEnabled = false,
			GuidesEnabled = true,
		})
		assertTrue(not offRes.WasSnapped and (offRes.FinalLocalCFrame.Position - rawCF.Position).Magnitude < 1e-5,
			"SmartSnap OFF must not alter CandidateLocalCFrame")
		assertTrue(#offRes.Guides >= 1 or #offRes.Markers >= 1, "Informative alignment guides must emit even with SmartSnap OFF")

		env.BuildAlignmentGuides.Render(bz, offRes.Guides, offRes.Markers)
		local gStats = env.BuildAlignmentGuides.GetDebugStats()
		assertTrue(gStats.HasContainer and (gStats.ActiveLines + gStats.ActiveMarkers) > 0, "BuildAlignmentGuides rendered pooled adornments")

		-- Con SmartSnap ON, snap determinista alinea exactamente a X=0, Z=0 (FaceCenter/Attachment)
		local onRes = BuildAlignmentMath.ComputeAlignments({
			CandidateLocalCFrame = CFrame.new(0.12, 3.0, 0.12),
			CandidateItemId = "WoodBlock",
			CandidateSize = geomBlock.Size,
			CandidateAttachments = geomBlock.Attachments,
			ExistingSpecs = specs,
			SurfaceNormalLocal = Vector3.yAxis,
			PositionMode = "Grid",
			SmartSnapEnabled = true,
			GuidesEnabled = true,
		})
		assertTrue(onRes.WasSnapped, "SmartSnap ON should snap within AlignmentSnapTolerance")
		assertTrue(math.abs(onRes.FinalLocalCFrame.Position.X) < 1e-4 and math.abs(onRes.FinalLocalCFrame.Position.Z) < 1e-4,
			`Expected snap to center (0, 3.0, 0), got {tostring(onRes.FinalLocalCFrame.Position)}`)

		env.Teardown()
	end)

	-- 26
	runTest("Fase 2.3.1 [26]: 3D Move Gizmo supports ray hit-test, zero initial jump, Grid/Free precision drag, and Cancel", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23105, Name = "MoveGizmoTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local bz = plot.Zones.BuildZone

		local startLocalCF = CFrame.new(0, 0.5, 0)
		local extents = Vector3.new(2, 2, 2)
		env.BuildMoveGizmo.UpdateVisual(bz, startLocalCF.Position, extents)
		assertTrue(env.BuildMoveGizmo.GetDebugStats().Visible, "Move gizmo visuals visible")

		-- Rayo apuntando al eje X en local (2.2, 0.5, 0) desde cámara superior-lateral
		local camWorld = bz.CFrame:PointToWorldSpace(Vector3.new(2.2, 5.5, 8.0))
		local hitTargetWorld = bz.CFrame:PointToWorldSpace(Vector3.new(2.2, 0.5, 0))
		local rayDir = (hitTargetWorld - camWorld).Unit

		local hitAxis = env.BuildMoveGizmo.HitTestFromRay(bz, startLocalCF.Position, extents, camWorld, rayDir)
		assertEqual(hitAxis, "X", "HitTestFromRay must select X axis handle")

		local began = env.BuildMoveGizmo.BeginDragFromRay("X", bz, startLocalCF, camWorld, rayDir)
		assertTrue(began, "BeginDragFromRay succeeded")

		-- Mismo rayo en frame inicial -> cero salto inicial (delta = 0)
		local cf0, d0, _ = env.BuildMoveGizmo.UpdateDragFromRay(bz, camWorld, rayDir, { PositionMode = "Grid", GridResolution = 0.25 })
		assertTrue(cf0 ~= nil and math.abs(d0) < 1e-4, `Initial drag frame must produce 0 jump, got {d0}`)

		-- Mover rayo +1.28 studs sobre eje X: en Grid 0.25 -> +1.25; en Free -> +1.28
		local movedWorld = bz.CFrame:PointToWorldSpace(Vector3.new(2.2 + 1.28, 0.5, 0))
		local movedDir = (movedWorld - camWorld).Unit
		local cfGrid, dGrid, _ = env.BuildMoveGizmo.UpdateDragFromRay(bz, camWorld, movedDir, { PositionMode = "Grid", GridResolution = 0.25 })
		assertTrue(cfGrid ~= nil and math.abs(dGrid - 1.25) < 0.02, `Grid 0.25 drag expected +1.25, got {dGrid}`)

		local cfFree, dFree, _ = env.BuildMoveGizmo.UpdateDragFromRay(bz, camWorld, movedDir, { PositionMode = "Free" })
		assertTrue(cfFree ~= nil and math.abs(dFree - 1.28) < 0.02, `Free drag expected +1.28, got {dFree}`)

		local cancelledCF = env.BuildMoveGizmo.CancelDrag()
		assertTrue(cancelledCF ~= nil and (cancelledCF.Position - startLocalCF.Position).Magnitude < 1e-5, "CancelDrag restores original CFrame")

		env.Teardown()
	end)

	-- 27
	runTest("Fase 2.3.1 [27]: 3D Rotation Gizmo handles X/Y/Z rings, continuous angle unwrapping across 0/360, and 90/45/15/1 steps", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23106, Name = "RotGizmoTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local bz = plot.Zones.BuildZone

		ItemRegistry._SetTestDefinitionForTests({
			Id = "TestFreeRotBlock",
			DisplayName = "Test Free Rot Block",
			Category = "Structures",
			Model = "WoodBlock",
			Stats = {
				Weight = 10,
				MaxDurability = 100,
			},
			PlacementPolicy = { RotationMode = "Free", AllowedAngleStepsDeg = { 90, 45, 15, 1 }, AllowFreePosition = true, AllowFreeRotation = true },
		})

		local startCF = CFrame.new(0, 1.5, 0)
		local extents = Vector3.new(2, 2, 2)
		local radius = env.BuildRotationGizmo.ComputeRingRadius(extents)
		env.BuildRotationGizmo.UpdateVisual(bz, startCF.Position, extents)

		-- Apuntar al anillo Y (normal = Y, en plano horizontal y = 1.5) en ángulo 0° (Z+)
		local camWorld = bz.CFrame:PointToWorldSpace(Vector3.new(0, 12, radius))
		local hitPtWorld = bz.CFrame:PointToWorldSpace(Vector3.new(0, 1.5, radius))
		local dir0 = (hitPtWorld - camWorld).Unit

		local hitRing = env.BuildRotationGizmo.HitTestFromRay(bz, startCF.Position, extents, camWorld, dir0)
		assertEqual(hitRing, "Y", "HitTestFromRay must detect Y ring")

		assertTrue(env.BuildRotationGizmo.BeginDragFromRay("Y", bz, startCF, camWorld, dir0, "WoodBlock"), "Begin Y ring drag")

		-- Barrer continuo > 360 grados (en pasos de 50°) verificando desenrollado sin saltos
		local prevRaw = 0
		for step = 1, 8 do
			local theta = math.rad(step * 50)
			-- Rotación positiva respecto al eje Y parte de Z+ hacia X+
			local pt = bz.CFrame:PointToWorldSpace(Vector3.new(math.sin(theta) * radius, 1.5, math.cos(theta) * radius))
			local d = (pt - camWorld).Unit
			env.BuildRotationGizmo.UpdateDragFromRay(bz, camWorld, d, { ItemId = "TestFreeRotBlock", AngleIncrementDeg = 1 })
			local raw = env.BuildRotationGizmo.GetRawUnwrappedDeg()
			assertTrue(raw > prevRaw + 35, `Expected continuous increasing unwrapped angle, step={step} raw={raw} prev={prevRaw}`)
			prevRaw = raw
		end
		assertTrue(prevRaw > 380, `Expected full wraparound past 360°, got {prevRaw}`)

		-- Verificar que WoodBlock (Orthogonal90) fuerza 90° incluso si se pide 15°
		local _, snappedOrtho, _ = env.BuildRotationGizmo.UpdateDragFromRay(bz, camWorld, dir0, { ItemId = "WoodBlock", AngleIncrementDeg = 15 })
		assertEqual(math.abs(snappedOrtho) % 90, 0, "Orthogonal90 item must stay locked to 90° multiples")

		-- Verificar incrementos 45° / 15° / 1° en TestFreeRotBlock
		env.BuildRotationGizmo.EndDrag()
		local pAng = bz.CFrame:PointToWorldSpace(Vector3.new(0, 1.5, radius))
		env.BuildRotationGizmo.BeginDragFromRay("Y", bz, startCF, camWorld, (pAng - camWorld).Unit, "TestFreeRotBlock")
		local pt47 = bz.CFrame:PointToWorldSpace(Vector3.new(math.sin(math.rad(47)) * radius, 1.5, math.cos(math.rad(47)) * radius))
		local _, d45, _ = env.BuildRotationGizmo.UpdateDragFromRay(bz, camWorld, (pt47 - camWorld).Unit, { ItemId = "TestFreeRotBlock", AngleIncrementDeg = 45 })
		assertEqual(d45, 45, "47° drag snapped to 45°")
		local _, d15, _ = env.BuildRotationGizmo.UpdateDragFromRay(bz, camWorld, (pt47 - camWorld).Unit, { ItemId = "TestFreeRotBlock", AngleIncrementDeg = 15 })
		assertEqual(d15, 45, "47° drag snapped to 45° under 15° step")
		local _, d1, _ = env.BuildRotationGizmo.UpdateDragFromRay(bz, camWorld, (pt47 - camWorld).Unit, { ItemId = "TestFreeRotBlock", AngleIncrementDeg = 1 })
		assertEqual(d1, 47, "47° drag snapped to 47° under 1° step")

		env.Teardown()
	end)

	-- 28
	runTest("Fase 2.3.1 [28]: ItemRegistry PlacementPolicy defaults to Orthogonal90 & enforces StepDegrees/Free rules server-side", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23107, Name = "PolicyTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		-- 1. Todos los 8 ítems existentes mantienen Orthogonal90 por defecto
		for _, def in ipairs(ItemRegistry.GetAll()) do
			local pol = ItemRegistry.GetPlacementPolicy(def.Id)
			assertEqual(pol.RotationMode, "Orthogonal90", `{def.Id} must default to Orthogonal90`)
		end

		-- 2. WoodBlock rechaza 45° tanto en cliente como en servidor
		local rot45 = CFrame.Angles(0, math.rad(45), 0)
		local resDenied = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "deny_45_wood",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0) * rot45,
		})
		assertTrue(not resDenied.Success and resDenied.ErrorCode == BuildProtocol.ErrorCodes.InvalidRotation,
			"Server must reject 45° on Orthogonal90 WoodBlock with InvalidRotation")

		-- 3. Objeto con StepDegrees={45} acepta 45° pero rechaza 15°
		ItemRegistry._SetTestDefinitionForTests({
			Id = "TestStep45",
			DisplayName = "Test Step 45",
			Category = "Structures",
			Model = "WoodBlock",
			Stats = {
				Weight = 10,
				MaxDurability = 100,
			},
			PlacementPolicy = { RotationMode = "StepDegrees", AllowedAngleStepsDeg = { 45 }, AllowFreePosition = true, AllowFreeRotation = false },
		})

		local ok45 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "allow_45_step",
			ItemId = "TestStep45",
			LocalCFrame = CFrame.new(0, 1.0, 0) * rot45,
		})
		assertTrue(ok45.Success, `Server must accept authorized 45° on TestStep45: {tostring(ok45.ErrorMessage)}`)

		local deny15 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "deny_15_step",
			ItemId = "TestStep45",
			LocalCFrame = CFrame.new(4, 1.0, 0) * CFrame.Angles(0, math.rad(15), 0),
		})
		assertTrue(not deny15.Success and deny15.ErrorCode == BuildProtocol.ErrorCodes.InvalidRotation,
			"Server must reject unauthorized 15° on StepDegrees={45} item")

		-- 4. Validación de catálogo rechaza PlacementPolicy malformada
		local badValid, _ = ItemRegistry.ValidateDefinition({
			Id = "BadPolicy",
			DisplayName = "Bad",
			Category = "Structures",
			Model = "WoodBlock",
			Stats = {
				Weight = 1,
				MaxDurability = 10,
			},
			PlacementPolicy = { RotationMode = "Diagonal999" },
		})
		assertTrue(not badValid, "Invalid PlacementPolicy.RotationMode must be rejected by ItemRegistry")

		env.Teardown()
	end)

	-- 29
	runTest("Fase 2.3.1 [29]: ConnectionMath SAT OBB overlap avoids AABB false positives on 45-degree boxes while detecting true overlaps", function()
		local size = Vector3.new(2, 2, 2)
		-- Rotados 45° en Y: AABB extendido es ~2.828 de lado (half=1.414), pero caras rotadas separadas por gap real
		local rot45 = CFrame.Angles(0, math.rad(45), 0)
		local cfA = CFrame.new(0, 1, 0) * rot45
		-- Centros distan a lo largo del eje diagonal local (sqrt(2)+eps, 0, sqrt(2)+eps) *? No: centro a centro 2.15 perpendicular a caras -> sin overlap!
		local cfSeparate = CFrame.new(1.52, 1, 1.52) * rot45 -- dist = 2.149 (> 2.0) pero AABB dx=1.52 < 2.828!
		assertTrue(not ConnectionMath.BoxesOverlap(cfA, size, cfSeparate, size, 0.05),
			"45° separated OBBs must NOT falsely overlap despite AABB overlap")

		local cfIntersecting = CFrame.new(1.10, 1, 1.10) * rot45 -- dist = 1.55 < 2.0 -> sí colisionan
		assertTrue(ConnectionMath.BoxesOverlap(cfA, size, cfIntersecting, size, 0.05),
			"45° genuinely intersecting OBBs MUST overlap cleanly")
	end)

	-- 30
	runTest("Fase 2.3.1 [30]: BuildService authoritative TransformPiece moves/rotates placed piece, updates EditableVehicle, edges, Revision & sync", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23108, Name = "TransformAuth" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local syncEvents: { BuildProtocol.BlueprintSyncPayload } = {}
		local unsub = BuildService.RegisterSyncListener(function(targetPlayer, payload)
			if targetPlayer.UserId == p1.UserId then
				table.insert(syncEvents, payload)
			end
		end)

		local b1 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "tr_b1",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(0, 1.0, 0),
		})
		local b2 = BuildService.ProcessRequest(p1, {
			Action = "PlacePiece",
			ClientOpId = "tr_b2",
			ItemId = "WoodBlock",
			LocalCFrame = CFrame.new(2, 1.0, 0),
		})
		assertTrue(b1.Success and b2.Success and b2.PlacedPiece ~= nil, "Setup 2 blocks")
		local piece2Id = (b2.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

		-- Deslizar b2 al otro lado de b1 en X = 0, Y = 3.0 (encima del bloque raíz) rotado 90° en Y
		local newLocalCF = CFrame.new(0, 3.0, 0) * BuildRotation.RotateY(BuildRotation.Identity(), 1)
		local trRes = BuildService.ProcessRequest(p1, {
			Action = "TransformPiece",
			ClientOpId = "tr_move_top",
			PieceInstanceId = piece2Id,
			LocalCFrame = newLocalCF,
		})
		assertTrue(trRes.Success and trRes.TransformedPiece ~= nil, `TransformPiece failed: {tostring(trRes.ErrorMessage)}`)
		assertEqual(trRes.Revision, 3, "Blueprint Revision must advance monotonically to 3")

		local editable = VehicleBlueprintService.GetEditableVehicleModel(p1) :: Model
		local model2: Model? = nil
		for _, ch in ipairs(editable:GetChildren()) do
			if ch:IsA("Model") and ch:GetAttribute("PieceInstanceId") == piece2Id then
				model2 = ch
				break
			end
		end
		assertTrue(model2 ~= nil, "Piece2 physical model exists in EditableVehicle")
		local expectedWorld = plot.Zones.BuildZone.CFrame:ToWorldSpace(newLocalCF)
		assertTrue(((model2 :: Model):GetPivot().Position - expectedWorld.Position).Magnitude < 0.02,
			"Physical EditableVehicle model pivoted to transformed CFrame")

		local lastSync = syncEvents[#syncEvents]
		assertEqual(lastSync.Type, BuildProtocol.SyncTypes.PieceTransformed, "BlueprintSyncEvent must broadcast PieceTransformed")
		assertEqual(lastSync.Revision, 3, "Sync event Revision matches")

		unsub()
		env.Teardown()
	end)

	-- 31
	runTest("Fase 2.4.2 [31]: TransformPiece allows detaching C and splitting bridge B into independent assemblies cleanly", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23109, Name = "BridgeTester" }
		PlotService.Assign(p1)

		-- Cadena A(0,1.0,0) -- B(2,1.0,0) -- C(4,1.0,0)
		local rA = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "br_a", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
		local rB = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "br_b", ItemId = "WoodBlock", LocalCFrame = CFrame.new(2, 1.0, 0) })
		local rC = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "br_c", ItemId = "WoodBlock", LocalCFrame = CFrame.new(4, 1.0, 0) })
		assertTrue(rA.Success and rB.Success and rC.Success, "3-block chain built")
		local idB = (rB.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId
		local idC = (rC.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

		-- 1. Mover C lejos en el vacío -> permitido como pieza suelta independiente
		local resDisc = BuildService.ProcessRequest(p1, {
			Action = "TransformPiece",
			ClientOpId = "br_disc",
			PieceInstanceId = idC,
			LocalCFrame = CFrame.new(10, 1.0, 10),
		})
		assertTrue(resDisc.Success, `Expected loose transform to succeed, got {tostring(resDisc.ErrorCode)}`)

		-- 2. Mover B lejos a (-8, 1.0, -8) -> divide en 3 grupos sueltos con 0 conexiones
		local resSplit = BuildService.ProcessRequest(p1, {
			Action = "TransformPiece",
			ClientOpId = "br_split",
			PieceInstanceId = idB,
			LocalCFrame = CFrame.new(-8, 1.0, -8),
		})
		assertTrue(resSplit.Success, `Expected split transform to succeed, got {tostring(resSplit.ErrorCode)}`)
		local bpSplit = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		assertEqual(bpSplit.Revision, 5, "Valid transforms increment revision cleanly")
		assertEqual(#bpSplit.Connections, 0, "Separated pieces have 0 connections")
		assertEqual(#ConnectionService.AnalyzeBlueprintAssemblies(bpSplit).Groups, 3, "Three isolated pieces form 3 groups")

		env.Teardown()
	end)

	-- 32
	runTest("Fase 2.3.1 [32]: TransformPiece rejects PieceOverlap, OutOfBounds, BlockedGeometry, InvalidRotation, and PieceNotFound", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23110, Name = "RejectTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord

		local r1 = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "rj_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
		local r2 = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "rj_2", ItemId = "WoodBlock", LocalCFrame = CFrame.new(2, 1.0, 0) })
		assertTrue(r1.Success and r2.Success, "Base blocks placed")
		local id1 = (r1.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId
		local id2 = (r2.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

		local resOverlap = BuildService.ProcessRequest(p1, {
			Action = "TransformPiece", ClientOpId = "rj_ov", PieceInstanceId = id2, LocalCFrame = CFrame.new(0, 1.0, 0),
		})
		assertTrue(not resOverlap.Success and resOverlap.ErrorCode == BuildProtocol.ErrorCodes.PieceOverlap, "Rejects PieceOverlap")

		local resBounds = BuildService.ProcessRequest(p1, {
			Action = "TransformPiece", ClientOpId = "rj_oob", PieceInstanceId = id1, LocalCFrame = CFrame.new(30, 1.0, 0),
		})
		assertTrue(not resBounds.Success and resBounds.ErrorCode == BuildProtocol.ErrorCodes.OutOfBounds, "Rejects OutOfBounds")

		local resRot = BuildService.ProcessRequest(p1, {
			Action = "TransformPiece", ClientOpId = "rj_rot", PieceInstanceId = id1, LocalCFrame = CFrame.new(0, 1.0, 0) * CFrame.Angles(0, math.rad(30), 0),
		})
		assertTrue(not resRot.Success and resRot.ErrorCode == BuildProtocol.ErrorCodes.InvalidRotation, "Rejects unauthorized 30° on Orthogonal90")

		local resMissing = BuildService.ProcessRequest(p1, {
			Action = "TransformPiece", ClientOpId = "rj_miss", PieceInstanceId = "nonexistent_99", LocalCFrame = CFrame.new(0, 1.0, 0),
		})
		assertTrue(not resMissing.Success and resMissing.ErrorCode == BuildProtocol.ErrorCodes.PieceNotFound, "Rejects PieceNotFound")

		-- Obstáculo físico en plot
		local wall = Instance.new("Part")
		wall.Name = "TestBlocker"
		wall.Anchored = true
		wall.CanCollide = true
		wall.Size = Vector3.new(2, 4, 2)
		wall.CFrame = plot.Zones.BuildZone.CFrame:ToWorldSpace(CFrame.new(0, 3.0, 0))
		wall.Parent = plot.Model

		local resBlocked = BuildService.ProcessRequest(p1, {
			Action = "TransformPiece", ClientOpId = "rj_blk", PieceInstanceId = id2, LocalCFrame = CFrame.new(0, 3.0, 0),
		})
		assertTrue(not resBlocked.Success and resBlocked.ErrorCode == BuildProtocol.ErrorCodes.BlockedGeometry,
			`Expected BlockedGeometry, got {tostring(resBlocked.ErrorCode)}`)

		wall:Destroy()
		env.Teardown()
	end)

	-- 33
	runTest("Fase 2.3.1 [33]: BuildTransformController handles optimistic nudge 0.01, Cancel/Revert, single confirm RPC, and idempotency", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23111, Name = "OptTransformTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local r1 = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "opt_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
		assertTrue(r1.Success and r1.PlacedPiece ~= nil, "Base block placed")
		local id1 = (r1.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

		env.BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		env.BuildState.SetActive(true)
		env.BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), true)
		env.BuildState.SetPositionMode("Free")
		env.BuildState.SetActiveTool("Move")
		env.BuildSelectionController.SelectPieceById(id1)

		local rpcCount = 0
		local function sendSpy(req: BuildProtocol.BuildRequest)
			rpcCount += 1
			return BuildService.ProcessRequest(p1, req)
		end

		-- Nudges locales 3 veces -> 0 tráfico de red
		assertTrue(env.BuildTransformController.NudgeAlongAxis("X", 1, 0.01), "Nudge 1")
		assertTrue(env.BuildTransformController.NudgeAlongAxis("X", 1, 0.01), "Nudge 2")
		assertTrue(env.BuildTransformController.NudgeAlongAxis("Z", -1, 0.01), "Nudge 3")
		assertEqual(rpcCount, 0, "Local nudging must produce 0 RPCs before confirm")
		assertTrue(env.BuildTransformController.HasPendingModification(), "Has pending local modification")

		-- Revertir restaura sin red
		env.BuildTransformController.RevertToBase()
		assertTrue(not env.BuildTransformController.HasPendingModification(), "RevertToBase clears pending modification")
		assertEqual(rpcCount, 0, "RevertToBase sends 0 RPCs")

		-- Reaplicar nudge 0.05 y confirmar -> 1 único RPC y servidor en 0.05
		env.BuildTransformController.NudgeAlongAxis("X", 1, 0.05)
		local okConf, confRes = env.BuildTransformController.ConfirmTransform(sendSpy)
		assertTrue(okConf and confRes ~= nil and confRes.Success, "ConfirmTransform succeeded")
		assertEqual(rpcCount, 1, "ConfirmTransform sends exactly 1 RPC")
		local srvPiece = VehicleBlueprintService.GetPieceSnapshot(p1, id1) :: VehicleTypes.BlueprintPiece
		assertTrue(math.abs(srvPiece.LocalCFrame.Position.X - 0.05) < 1e-4, "Server stored exact 0.05 offset")

		-- Verificar idempotencia en BuildService enviando el mismo ClientOpId
		local dupRes = BuildService.ProcessRequest(p1, {
			Action = "TransformPiece",
			ClientOpId = confRes.ClientOpId :: string,
			PieceInstanceId = id1,
			LocalCFrame = CFrame.new(2, 1.0, 0),
		})
		assertTrue(dupRes.Success and dupRes.Revision == confRes.Revision, "Duplicate ClientOpId returns idempotent cached revision")

		env.Teardown()
	end)

	-- 34
	runTest("Fase 2.3.1 [34]: BuildTransformController recovers from RPC timeout via rollback and GetBlueprint resync", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23112, Name = "TimeoutTransformTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local r1 = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "to_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
		local id1 = (r1.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

		env.BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		env.BuildState.SetActive(true)
		env.BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), true)
		env.BuildState.SetPositionMode("Free")
		env.BuildState.SetActiveTool("Move")
		env.BuildSelectionController.SelectPieceById(id1)
		env.BuildTransformController._SetOperationTimeoutForTests(0.1)

		local didGetBlueprint = false
		local function slowTimeoutInvoke(req: BuildProtocol.BuildRequest)
			if req.Action == "TransformPiece" then
				task.wait(0.25)
				return BuildService.ProcessRequest(p1, req)
			end
			didGetBlueprint = true
			return BuildService.ProcessRequest(p1, req)
		end

		env.BuildTransformController.NudgeAlongAxis("X", 1, 0.5)
		local okConf, _ = env.BuildTransformController.ConfirmTransform(slowTimeoutInvoke)
		assertTrue(not okConf, "Timed out ConfirmTransform must return false")
		assertEqual(env.BuildState.LastError, BuildProtocol.ErrorCodes.OperationTimeout, "Sets OperationTimeout error")
		assertTrue(didGetBlueprint, "Triggers GetBlueprint resync after transform timeout")

		local previewCF = env.BuildState.TransformPreviewLocalCFrame :: CFrame
		assertTrue((previewCF.Position - Vector3.new(0, 1.0, 0)).Magnitude < 1e-4, "Rolled back preview to server position")

		env.BuildTransformController._SetOperationTimeoutForTests(GameConfig.Building.OperationTimeoutSeconds)
		env.Teardown()
	end)

	-- 35
	runTest("Fase 2.3.1 [35]: BuildState.ApplySyncEvent handles PieceTransformed monotonically and filters stale/foreign events", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23113, Name = "SyncTransformTester" }
		PlotService.Assign(p1)
		local r1 = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "sy_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
		local pA = r1.PlacedPiece :: VehicleTypes.BlueprintPiece

		env.BuildState.SetExpectedOwner(p1.UserId)
		env.BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), true)
		assertEqual(env.BuildState.BlueprintRevision, 1, "Initial sync rev 1")

		-- Evento extranjero ignorado
		local foreignOk, _ = env.BuildState.ApplySyncEvent({
			Type = "PieceTransformed",
			OwnerUserId = 999999,
			BlueprintId = env.BuildState.BlueprintId :: string,
			Revision = 2,
			TransformedPiece = pA,
		})
		assertTrue(not foreignOk, "Foreign PieceTransformed must be ignored")

		-- Evento válido R=2
		local updatedPiece: VehicleTypes.BlueprintPiece = {
			InstanceId = pA.InstanceId,
			ItemId = pA.ItemId,
			LocalCFrame = CFrame.new(0.25, 1.0, 0),
			InventoryInstanceId = nil,
			Config = {},
		}
		local okSync, needsResync = env.BuildState.ApplySyncEvent({
			Type = "PieceTransformed",
			OwnerUserId = p1.UserId,
			BlueprintId = env.BuildState.BlueprintId :: string,
			Revision = 2,
			TransformedPiece = updatedPiece,
			UpdatedConnections = {},
		})
		assertTrue(okSync and not needsResync, "Valid PieceTransformed R=2 applied cleanly")
		assertEqual(env.BuildState.BlueprintRevision, 2, "Client revision advanced to 2")
		local clPiece = env.BuildState.GetPiece(pA.InstanceId) :: VehicleTypes.BlueprintPiece
		assertTrue(math.abs(clPiece.LocalCFrame.Position.X - 0.25) < 1e-4, "Client piece position updated by delta sync")

		-- Salto de revisión R=5 pide FullSync
		local gapOk, gapResync = env.BuildState.ApplySyncEvent({
			Type = "PieceTransformed",
			OwnerUserId = p1.UserId,
			BlueprintId = env.BuildState.BlueprintId :: string,
			Revision = 5,
			TransformedPiece = updatedPiece,
		})
		assertTrue(not gapOk and gapResync, "Revision gap on PieceTransformed requests GetBlueprint resync")

		env.Teardown()
	end)

	-- 36
	runTest("Fase 2.3.1 [36]: TransformPiece security rejects spoofed authority, scaled matrices, NaN CFrames, and cross-player edits", function()
		local env = setupAdvEnv(2)
		local pA: PlotService.PlayerLike = { UserId = 23114, Name = "OwnerA" }
		local pB: PlotService.PlayerLike = { UserId = 23115, Name = "AttackerB" }
		PlotService.Assign(pA)
		PlotService.Assign(pB)

		local rA = BuildService.ProcessRequest(pA, { Action = "PlacePiece", ClientOpId = "sec_a", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
		local idA = (rA.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

		-- Cross-player
		local cross = BuildService.ProcessRequest(pB, {
			Action = "TransformPiece",
			ClientOpId = "atk_cross",
			PieceInstanceId = idA,
			LocalCFrame = CFrame.new(1, 1.0, 0),
		})
		assertTrue(not cross.Success and cross.ErrorCode == BuildProtocol.ErrorCodes.PieceNotFound, "Cross-player transform rejected")

		-- Spoof key PlotId (estación ajena -> NotPlotOwner; estación propia como campo cliente -> InvalidPayload)
		local spoofOther = BuildService.ProcessRequest(pA, {
			Action = "TransformPiece",
			ClientOpId = "atk_spoof_other",
			PieceInstanceId = idA,
			LocalCFrame = CFrame.new(0, 1.0, 0),
			PlotId = "Plot_02",
		})
		assertTrue(not spoofOther.Success and spoofOther.ErrorCode == BuildProtocol.ErrorCodes.NotPlotOwner, "Spoofed foreign PlotId in TransformPiece rejected")

		local spoofSelf = BuildService.ProcessRequest(pA, {
			Action = "TransformPiece",
			ClientOpId = "atk_spoof_self",
			PieceInstanceId = idA,
			LocalCFrame = CFrame.new(0, 1.0, 0),
			PlotId = "Plot_01",
		})
		assertTrue(not spoofSelf.Success and spoofSelf.ErrorCode == BuildProtocol.ErrorCodes.InvalidPayload, "Spoofed own PlotId key in TransformPiece rejected")

		-- Matriz escalada / no ortonormal
		local scaledCF = CFrame.fromMatrix(Vector3.new(0, 1.0, 0), Vector3.new(2, 0, 0), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1))
		local resScale = BuildService.ProcessRequest(pA, {
			Action = "TransformPiece",
			ClientOpId = "atk_scale",
			PieceInstanceId = idA,
			LocalCFrame = scaledCF,
		})
		assertTrue(not resScale.Success and resScale.ErrorCode == BuildProtocol.ErrorCodes.InvalidRotation, "Non-orthonormal matrix rejected")

		-- NaN CFrame
		local nanCF = CFrame.new(0 / 0, 1.0, 0)
		local resNaN = BuildService.ProcessRequest(pA, {
			Action = "TransformPiece",
			ClientOpId = "atk_nan",
			PieceInstanceId = idA,
			LocalCFrame = nanCF,
		})
		assertTrue(not resNaN.Success and resNaN.ErrorCode == BuildProtocol.ErrorCodes.InvalidCFrame, "NaN CFrame rejected")

		env.Teardown()
	end)

	-- 37
	runTest("Fase 2.3.1 [37]: End-to-end ray-driven Move and Rotate gizmo workflow commits valid TransformPiece to server", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23116, Name = "E2EGizmoTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local bz = plot.Zones.BuildZone

		local rRoot = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "e2e_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
		local rBeam = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "e2e_2", ItemId = "WoodBeam", LocalCFrame = CFrame.new(0, 2.5, 0) })
		assertTrue(rRoot.Success and rBeam.Success and rBeam.PlacedPiece ~= nil, "Setup root + beam")
		local beamId = (rBeam.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

		env.BuildState.SetPlot(plot.Model, bz)
		env.BuildState.SetActive(true)
		env.BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), true)
		env.BuildState.SetPositionMode("Grid")
		env.BuildState.SetGridResolution(0.25)
		env.BuildState.SetActiveTool("Move")
		env.BuildSelectionController.SelectPieceById(beamId)

		local function sendSrv(req: BuildProtocol.BuildRequest)
			return BuildService.ProcessRequest(p1, req)
		end

		-- Inicializar visuales de Move gizmo sobre beam (0, 2.5, 0)
		env.BuildTransformController.UpdateVisuals()
		local camWorld = bz.CFrame:PointToWorldSpace(Vector3.new(1.8, 7.5, 8.0))
		local handleXWorld = bz.CFrame:PointToWorldSpace(Vector3.new(2.2, 2.5, 0))
		local rayBegin = (handleXWorld - camWorld).Unit

		local startedDrag = env.BuildTransformController.TryBeginGizmoDragFromRay(camWorld, rayBegin)
		assertTrue(startedDrag, "Ray hit X axis of Move gizmo on beam")

		-- Deslizar +0.50 studs sobre X manteniendo conexión con cara superior de WoodBlock
		local draggedWorld = bz.CFrame:PointToWorldSpace(Vector3.new(2.7, 2.5, 0))
		env.BuildTransformController.UpdateVisuals(camWorld, (draggedWorld - camWorld).Unit)
		local okEndMove, resMove = env.BuildTransformController.EndGizmoDrag(true, sendSrv)
		assertTrue(okEndMove and resMove ~= nil and resMove.Success, `E2E gizmo Move failed: {tostring(resMove and resMove.ErrorMessage)}`)
		local movedSrv = VehicleBlueprintService.GetPieceSnapshot(p1, beamId) :: VehicleTypes.BlueprintPiece
		assertTrue(math.abs(movedSrv.LocalCFrame.Position.X - 0.5) < 0.05, `Expected server beam at X=0.5, got {movedSrv.LocalCFrame.Position.X}`)

		-- Ahora rotar Y 90° mediante Rotate Gizmo ray drag
		env.BuildState.SetActiveTool("Rotate")
		env.BuildTransformController.UpdateVisuals()
		local rRad = env.BuildRotationGizmo.ComputeRingRadius(Vector3.new(1, 1, 4))
		local camRotWorld = bz.CFrame:PointToWorldSpace(Vector3.new(0.5, 14.5, rRad * 0.5))
		local ang0 = math.rad(35)
		local ang90 = math.rad(125)
		local ringPt0 = bz.CFrame:PointToWorldSpace(Vector3.new(0.5 + math.sin(ang0) * rRad, 2.5, math.cos(ang0) * rRad))
		assertTrue(env.BuildTransformController.TryBeginGizmoDragFromRay(camRotWorld, (ringPt0 - camRotWorld).Unit), "Ray hit Y ring")
		assertEqual(env.BuildRotationGizmo.GetActiveAxis(), "Y", "Selected ring must be Y")
		local ringPt90 = bz.CFrame:PointToWorldSpace(Vector3.new(0.5 + math.sin(ang90) * rRad, 2.5, math.cos(ang90) * rRad))
		env.BuildTransformController.UpdateVisuals(camRotWorld, (ringPt90 - camRotWorld).Unit)
		local okEndRot, resRot = env.BuildTransformController.EndGizmoDrag(true, sendSrv)
		assertTrue(okEndRot and resRot ~= nil and resRot.Success, `E2E gizmo Rotate failed: {tostring(resRot and resRot.ErrorMessage)}`)
		local rotSrv = VehicleBlueprintService.GetPieceSnapshot(p1, beamId) :: VehicleTypes.BlueprintPiece
		assertTrue(math.abs(rotSrv.LocalCFrame.LookVector.Z) < 0.1, "Beam rotated 90° around Y on server")

		env.Teardown()
	end)

	-- 38
	runTest("Fase 2.3.1 [38]: Repeated tool switching & cleanup leaves zero leftover adornments, containers, or session leaks", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23117, Name = "CleanupTester" }
		local plot = PlotService.Assign(p1) :: PlotService.PlotRecord
		local r1 = BuildService.ProcessRequest(p1, { Action = "PlacePiece", ClientOpId = "cl_1", ItemId = "WoodBlock", LocalCFrame = CFrame.new(0, 1.0, 0) })
		local id1 = (r1.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

		env.BuildState.SetPlot(plot.Model, plot.Zones.BuildZone)
		env.BuildState.SetActive(true)
		env.BuildState.ApplyAuthoritativeBlueprint(VehicleBlueprintService.GetBlueprintSnapshot(p1), true)

		for cycle = 1, 10 do
			env.BuildState.SelectItem("WoodBlock")
			env.BuildPreviewController.UpdateAtWorldPoint(plot.Zones.BuildZone.Position, plot.Zones.BuildZone.CFrame.UpVector)
			env.BuildState.SelectItem(nil)
			env.BuildPreviewController.DestroyGhost()

			env.BuildState.SetActiveTool(if cycle % 2 == 0 then "Rotate" else "Move")
			env.BuildSelectionController.SelectPieceById(id1)
			env.BuildTransformController.UpdateVisuals()
			env.BuildTransformController.CancelSession()
			env.BuildSelectionController.ClearSelection()
		end

		env.Teardown()
		assertTrue(not env.BuildTransformController.HasActiveSession(), "No lingering transform session")
		assertTrue(not env.BuildGridVisualizer.GetDebugStats().HasContainer, "Grid container cleaned")
		assertTrue(not env.BuildAlignmentGuides.GetDebugStats().HasContainer, "Guides container cleaned")
		assertTrue(not env.BuildMoveGizmo.GetDebugStats().HasContainer, "Move gizmo container cleaned")
		assertTrue(not env.BuildRotationGizmo.GetDebugStats().HasContainer, "Rotation gizmo container cleaned")
		assertEqual(VehicleBlueprintService.GetTrackedPlayerCount(), 0, "Zero blueprints tracked")
		assertEqual(ConnectionService.GetTrackedCacheCount(), 0, "Zero connection caches tracked")
	end)

	-- 39
	runTest("Fase 2.3.1 [39]: 10-player concurrent TransformPiece + Free/Grid edits remain isolated across all plots", function()
		local env = setupAdvEnv(10)
		local players = {}
		local rootIds = {}

		for i = 1, 10 do
			local plr: PlotService.PlayerLike = { UserId = 24000 + i, Name = `AdvSim_{i}` }
			players[i] = plr
			PlotService.Assign(plr)
			local r0 = BuildService.ProcessRequest(plr, {
				Action = "PlacePiece",
				ClientOpId = `p{i}_root`,
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new(0, 1.0, 0),
			})
			assertTrue(r0.Success and r0.PlacedPiece ~= nil, `Player {i} placed root`)
			rootIds[i] = (r0.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId
		end

		for i = 1, 10 do
			local offset = 0.01 * i
			local rBeam = BuildService.ProcessRequest(players[i], {
				Action = "PlacePiece",
				ClientOpId = `p{i}_beam`,
				ItemId = "WoodBeam",
				LocalCFrame = CFrame.new(offset, 2.5, 0),
			})
			assertTrue(rBeam.Success and rBeam.PlacedPiece ~= nil, `Player {i} placed Free offset beam`)
			local beamId = (rBeam.PlacedPiece :: VehicleTypes.BlueprintPiece).InstanceId

			local rMove = BuildService.ProcessRequest(players[i], {
				Action = "TransformPiece",
				ClientOpId = `p{i}_move`,
				PieceInstanceId = beamId,
				LocalCFrame = CFrame.new(-offset, 2.5, 0) * BuildRotation.RotateY(BuildRotation.Identity(), 1),
			})
			assertTrue(rMove.Success and rMove.Revision == 3, `Player {i} TransformPiece rev 3`)
			local snap = VehicleBlueprintService.GetPieceSnapshot(players[i], beamId) :: VehicleTypes.BlueprintPiece
			assertTrue(math.abs(snap.LocalCFrame.Position.X + offset) < 1e-4, `Player {i} preserved own transformed Free coordinate`)
		end

		-- Asegurar aislamiento entre bases vecinas una vez todos alcanzaron Revision 3
		for i = 1, 10 do
			local victim = players[(i % 10) + 1]
			local atk = BuildService.ProcessRequest(players[i], {
				Action = "TransformPiece",
				ClientOpId = `p{i}_atk`,
				PieceInstanceId = rootIds[(i % 10) + 1],
				LocalCFrame = CFrame.new(1, 1.0, 0),
			})
			assertTrue(not atk.Success and atk.ErrorCode == BuildProtocol.ErrorCodes.PieceNotFound, "Cross-plot transform blocked")
			assertEqual(VehicleBlueprintService.GetBlueprintSnapshot(victim).Revision, 3, "Victim blueprint untouched")
		end

		for i = 1, 10 do
			PlotService.Release(players[i])
		end
		env.Teardown()
	end)

	-- 40
	runTest("Fase 2.3.1 [40]: Performance sanity gate for BuildAlignmentMath near 25-piece vehicle (< 5ms/frame) & full clean teardown", function()
		local env = setupAdvEnv(1)
		local p1: PlotService.PlayerLike = { UserId = 23120, Name = "PerfAdvTester" }
		PlotService.Assign(p1)

		for i = 0, 24 do
			local res = BuildService.ProcessRequest(p1, {
				Action = "PlacePiece",
				ClientOpId = `perf_{i}`,
				ItemId = "WoodBlock",
				LocalCFrame = CFrame.new((i % 5) * 2 - 4, 1.0 + math.floor(i / 5) * 2, 0),
			})
			assertTrue(res.Success, `Placed perf block {i}`)
		end

		local bp = VehicleBlueprintService.GetBlueprintSnapshot(p1)
		local specs = ConnectionService.BuildPieceGeometrySpecs(bp.Pieces)
		local idx = ConnectionMath.CreateSpatialIndex()
		for _, s in ipairs(specs) do
			idx:Insert(s)
		end
		local geom = ConnectionService.GetItemGeometry("WoodBeam") :: ConnectionService.CachedItemGeometry

		local t0 = os.clock()
		for iter = 1, 20 do
			BuildAlignmentMath.ComputeAlignments({
				CandidateLocalCFrame = CFrame.new(0.12 + iter * 0.01, 11.0, 0.05),
				CandidateItemId = "WoodBeam",
				CandidateSize = geom.Size,
				CandidateAttachments = geom.Attachments,
				ExistingSpecs = specs,
				SpatialIndex = idx,
				SurfaceNormalLocal = Vector3.yAxis,
				PositionMode = "Free",
				SmartSnapEnabled = true,
				GuidesEnabled = true,
			})
		end
		local avgMs = ((os.clock() - t0) / 20) * 1000
		assertTrue(avgMs < 5.0, `Expected BuildAlignmentMath average < 5.0 ms near 25 pieces, got {string.format("%.3f", avgMs)} ms`)

		env.Teardown()
		assertEqual(VehicleBlueprintService.GetTrackedPlayerCount(), 0, "Zero leftover tracked blueprints")
	end)

	return {
		Passed = passedCount,
		Failed = failedCount,
		Results = results,
	}
end

function Phase1Tests.RunAll(): TestSuiteResult
	local core = Phase1Tests.RunCoreOnly()
	local results = core.Results
	local passedCount = core.Passed
	local failedCount = core.Failed

	local function runTest(name: string, fn: () -> ())
		local ok, err = xpcall(fn, debug.traceback)
		if ok then
			passedCount += 1
			table.insert(results, { Name = name, Passed = true, Error = nil })
		else
			failedCount += 1
			table.insert(results, { Name = name, Passed = false, Error = tostring(err) })
		end
	end

	local Phase24Tests = require(script.Parent:WaitForChild("Phase24Tests"))
	Phase24Tests.AppendTests(results, runTest)

	local Phase241Tests = require(script.Parent:WaitForChild("Phase241Tests"))
	Phase241Tests.AppendTests(results, runTest)

	local Phase242Tests = require(script.Parent:WaitForChild("Phase242Tests"))
	Phase242Tests.AppendTests(results, runTest)

	local Phase31Tests = require(script.Parent:WaitForChild("Phase31Tests"))
	Phase31Tests.AppendTests(results, runTest)

	local Phase32Tests = require(script.Parent:WaitForChild("Phase32Tests"))
	Phase32Tests.AppendTests(results, runTest)

	local Phase33Tests = require(script.Parent:WaitForChild("Phase33Tests"))
	Phase33Tests.AppendTests(results, runTest)

	local Phase34Tests = require(script.Parent:WaitForChild("Phase34Tests"))
	Phase34Tests.AppendTests(results, runTest)

	local Phase41Tests = require(script.Parent:WaitForChild("Phase41Tests"))
	Phase41Tests.AppendTests(results, runTest)

	local Phase42Tests = require(script.Parent:WaitForChild("Phase42Tests"))
	Phase42Tests.AppendTests(results, runTest)

	local ConnectionHotfixTests = require(script.Parent:WaitForChild("ConnectionHotfixTests"))
	ConnectionHotfixTests.AppendTests(results, runTest)

	local EditableVisibilityHotfixTests = require(script.Parent:WaitForChild("EditableVisibilityHotfixTests"))
	EditableVisibilityHotfixTests.AppendTests(results, runTest)

	return {
		Passed = passedCount,
		Failed = failedCount,
		Results = results,
	}
end

return Phase1Tests

