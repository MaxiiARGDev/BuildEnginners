--!strict
--[=[
	VehicleLaunchPreparationService
	Servicio de validación y preparación previa al lanzamiento en LaunchPoint (Fase 2.4).
	- Realiza consultas estrictamente de solo lectura sobre ActiveBlueprint y LaunchPoint.
	- Verifica integridad del grafo, piezas válidas, dimensiones, presencia exacta de 1 DriverSeat funcional
	  y obstrucciones físicas en LaunchPoint.
	- Calcula LaunchAnchorCFrame (sin enterrar bajo Platform), CenterWorldCFrame y BoundingSize.
	- NO crea VehicleRuntime, NO activa conducción, motores, propulsores ni físicas todavía (Fase 3).
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local VehicleCoordinateMath = require(ReplicatedStorage.Shared.Building.VehicleCoordinateMath)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local ConnectionService = require(ServerScriptService.Server.Services.ConnectionService)
local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local BoosterInventoryService = require(ServerScriptService.Server.Services.BoosterInventoryService)
local PlotService = require(ServerScriptService.Server.Services.PlotService)
local VehicleBlueprintService = require(ServerScriptService.Server.Services.VehicleBlueprintService)
local WheelAutoConfigurationService = require(ServerScriptService.Server.Services.WheelAutoConfigurationService)

export type LaunchCheckOptions = {
	GroundClearance: number?,
	MaxLaunchDimensions: Vector3?,
	SkipWorldObstructionCheck: boolean?,
	ExtraExcludeInstances: { Instance }?,
}

local VehicleLaunchPreparationService = {
	Name = "VehicleLaunchPreparationService",
}

local _itemAssetsRoot: Instance? = nil
local _fallbackSizeCache: { [string]: Vector3 } = {}
local _overlapParams = OverlapParams.new()
_overlapParams.FilterType = Enum.RaycastFilterType.Exclude
local _initialized = false
local _started = false

local function resolvePieceSize(itemId: string): Vector3?
	local geom = ConnectionService.GetItemGeometry(itemId)
	if geom then
		return geom.Size
	end
	local cached = _fallbackSizeCache[itemId]
	if cached then
		return cached
	end
	if not ItemRegistry.Has(itemId) then
		return nil
	end
	local def = ItemRegistry.Get(itemId)
	local assetsRoot = _itemAssetsRoot or ServerStorage:FindFirstChild("ItemAssets")
	local templateModel = ItemRegistry.ResolveModel(assetsRoot, def)
	if templateModel then
		local _, bbSize = templateModel:GetBoundingBox()
		_fallbackSizeCache[itemId] = bbSize
		return bbSize
	end
	return nil
end

local function isDriverSeatAssetFunctional(): boolean
	local itemId = GameConfig.LaunchPrep.DriverSeatItemId
	if not ItemRegistry.Has(itemId) then
		return false
	end
	local def = ItemRegistry.Get(itemId)
	local assetsRoot = _itemAssetsRoot or ServerStorage:FindFirstChild("ItemAssets")
	local templateModel = ItemRegistry.ResolveModel(assetsRoot, def)
	if not templateModel then
		return false
	end
	local seat = templateModel:FindFirstChildWhichIsA("VehicleSeat", true)
	return seat ~= nil
end

local function collectPlotExcludes(plot: PlotService.PlotRecord): { Instance }
	local exclude: { Instance } = {
		plot.Zones.BuildZone,
		plot.Zones.LaunchPoint,
		plot.Zones.ShopZone,
		plot.Zones.DeliveryZone,
		plot.Zones.StandZone,
		plot.PlotOrigin,
		plot.PlayerSpawn,
		plot.DynamicContainer,
	}
	local platform = plot.Model:FindFirstChild("Platform")
	if platform then
		table.insert(exclude, platform)
	end
	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate then
		table.insert(exclude, baseplate)
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			table.insert(exclude, plr.Character)
		end
	end
	return exclude
end

local function detectLaunchObstructions(
	plot: PlotService.PlotRecord,
	centerWorldCF: CFrame,
	boundingSize: Vector3,
	extraExcludes: { Instance }?
): { string }
	local exclude = collectPlotExcludes(plot)
	if extraExcludes then
		for _, inst in ipairs(extraExcludes) do
			table.insert(exclude, inst)
		end
	end
	_overlapParams.FilterDescendantsInstances = exclude

	local pad = GameConfig.LaunchPrep.ObstructionPadding
	local querySize = Vector3.new(
		math.max(0.2, boundingSize.X - pad),
		math.max(0.2, boundingSize.Y - pad),
		math.max(0.2, boundingSize.Z - pad)
	)
	local hitParts = Workspace:GetPartBoundsInBox(centerWorldCF, querySize, _overlapParams)
	local blockingNames: { string } = {}
	for _, part in ipairs(hitParts) do
		if
			part.CanCollide
			or part:FindFirstAncestor(GameConfig.PlotContainers.Decorations)
			or part:FindFirstAncestor(GameConfig.PlotContainers.Structures)
		then
			table.insert(blockingNames, part:GetFullName())
		end
	end
	return blockingNames
end

function VehicleLaunchPreparationService.EvaluateBlueprintLaunch(
	blueprint: VehicleTypes.VehicleBlueprint?,
	plot: PlotService.PlotRecord?,
	options: LaunchCheckOptions?
): VehicleTypes.LaunchPreparationReport
	if not _initialized then
		VehicleLaunchPreparationService.Init()
	end

	local issues: { VehicleTypes.LaunchIssue } = {}
	local function addIssue(category: VehicleTypes.LaunchIssueCategory, code: string, msg: string)
		table.insert(issues, {
			Category = category,
			Code = code,
			Message = msg,
		})
	end

	if not plot then
		addIssue("LocationError", "NoAssignedPlot", "El jugador no tiene una estación asignada.")
		return {
			Ready = false,
			ErrorCategory = issues[1].Category,
			PrimaryErrorCode = issues[1].Code,
			PrimaryErrorMessage = issues[1].Message,
			Issues = issues,
			BlueprintId = if blueprint then blueprint.BlueprintId else nil,
			BlueprintRevision = if blueprint then blueprint.Revision else 0,
			PieceCount = if blueprint then #blueprint.Pieces else 0,
			TotalPieceCount = if blueprint then #blueprint.Pieces else 0,
			WorkshopPieceCount = 0,
			PrimaryAssemblyGroupId = nil,
			PrimaryAssemblyPieceIds = {},
			WorkshopPieceIds = {},
			AssemblyGroups = {},
			DisconnectedGroupCount = 0,
			NeedsPrimarySelection = false,
			DriverSeatCount = 0,
			DriverSeatPieceId = nil,
			BoundsMin = nil,
			BoundsMax = nil,
			BoundingSize = nil,
			GroundClearance = nil,
			LaunchAnchorCFrame = nil,
			CenterWorldCFrame = nil,
			ObstructingPartNames = nil,
		}
	end

	local launchPoint = plot.Zones and plot.Zones.LaunchPoint
	if not launchPoint or not launchPoint.Parent then
		addIssue("LocationError", "MissingLaunchPoint", "La estación no tiene una zona LaunchPoint válida.")
	end

	if not blueprint then
		addIssue("BuildError", "MissingBlueprint", "No hay blueprint activo para preparar el lanzamiento.")
		return {
			Ready = false,
			ErrorCategory = issues[1].Category,
			PrimaryErrorCode = issues[1].Code,
			PrimaryErrorMessage = issues[1].Message,
			Issues = issues,
			BlueprintId = nil,
			BlueprintRevision = 0,
			PieceCount = 0,
			TotalPieceCount = 0,
			WorkshopPieceCount = 0,
			PrimaryAssemblyGroupId = nil,
			PrimaryAssemblyPieceIds = {},
			WorkshopPieceIds = {},
			AssemblyGroups = {},
			DisconnectedGroupCount = 0,
			NeedsPrimarySelection = false,
			DriverSeatCount = 0,
			DriverSeatPieceId = nil,
			BoundsMin = nil,
			BoundsMax = nil,
			BoundingSize = nil,
			GroundClearance = nil,
			LaunchAnchorCFrame = nil,
			CenterWorldCFrame = nil,
			ObstructingPartNames = nil,
		}
	end

	local totalPieceCount = #blueprint.Pieces
	if totalPieceCount == 0 then
		addIssue("BuildError", "EmptyVehicle", "El vehículo debe tener al menos 1 pieza antes de lanzar.")
	end

	if totalPieceCount > GameConfig.Building.MaxPiecesPerVehicle then
		addIssue(
			"BuildError",
			"MaxPiecesReached",
			`El vehículo supera el máximo de {GameConfig.Building.MaxPiecesPerVehicle} piezas.`
		)
	end

	local analysis = ConnectionService.AnalyzeBlueprintAssemblies(blueprint)
	local primaryIdSet: { [string]: boolean } = {}
	for _, pid in ipairs(analysis.PrimaryPieceIds) do
		primaryIdSet[pid] = true
	end

	local primaryPieces: { VehicleTypes.BlueprintPiece } = {}
	for _, piece in ipairs(blueprint.Pieces) do
		if primaryIdSet[piece.InstanceId] then
			table.insert(primaryPieces, piece)
		end
	end

	local driverSeatCount = 0
	local firstDriverSeatId: string? = nil
	local allPrimaryAssetsValid = true

	if analysis.AmbiguousPrimary then
		driverSeatCount = #analysis.DriverSeatGroupIds
		addIssue(
			"ConfigError",
			BuildProtocol.ErrorCodes.AmbiguousPrimaryAssembly,
			`Hay {#analysis.DriverSeatGroupIds} vehículos separados con DriverSeat; seleccioná cuál ensamblaje lanzar.`
		)
	elseif #primaryPieces > 0 then
		for _, piece in ipairs(primaryPieces) do
			if not ItemRegistry.Has(piece.ItemId) then
				allPrimaryAssetsValid = false
				addIssue("BuildError", "UnknownItem", `Pieza desconocida en ensamblaje primario: {piece.ItemId}`)
			elseif not resolvePieceSize(piece.ItemId) then
				allPrimaryAssetsValid = false
				addIssue("BuildError", "MissingAsset", `Modelo faltante para pieza: {piece.ItemId}`)
			end

			if piece.ItemId == GameConfig.LaunchPrep.DriverSeatItemId then
				driverSeatCount += 1
				if not firstDriverSeatId then
					firstDriverSeatId = piece.InstanceId
				end
			end
		end

		if driverSeatCount == 0 then
			addIssue(
				"ConfigError",
				"MissingDriverSeat",
				"Falta 1 DriverSeat funcional en el ensamblaje para poder conducir el vehículo."
			)
		elseif driverSeatCount > GameConfig.LaunchPrep.RequiredDriverSeatCount then
			addIssue(
				"ConfigError",
				"MultipleDriverSeats",
				`El ensamblaje primario tiene {driverSeatCount} DriverSeats conectados; solo se permite 1.`
			)
		elseif not isDriverSeatAssetFunctional() then
			addIssue("ConfigError", "NonFunctionalDriverSeat", "El DriverSeat no contiene un VehicleSeat funcional.")
		end

		if #primaryPieces > 1 and allPrimaryAssetsValid then
			local specs = ConnectionService.BuildPieceGeometrySpecs(primaryPieces)
			for i = 1, #specs do
				local a = specs[i]
				for j = i + 1, #specs do
					local b = specs[j]
					if ConnectionMath.SpecsOverlap(a, b) then
						addIssue(
							"BuildError",
							"OverlappingPieces",
							`Piezas superpuestas detectadas ({a.InstanceId} y {b.InstanceId}).`
						)
						break
					end
				end
				if issues[#issues] and issues[#issues].Code == "OverlappingPieces" then
					break
				end
			end
		end
	end

	local bounds = if #primaryPieces > 0 and not analysis.AmbiguousPrimary
		then VehicleCoordinateMath.ComputeVehicleBounds(primaryPieces, resolvePieceSize)
		else { Valid = false, Min = Vector3.zero, Max = Vector3.zero, Size = Vector3.zero, Center = Vector3.zero }
	local groundClearance = (options and options.GroundClearance) or GameConfig.LaunchPrep.GroundClearanceStuds
	local maxDims = (options and options.MaxLaunchDimensions)
		or Vector3.new(
			GameConfig.LaunchPrep.MaxLaunchWidth,
			GameConfig.LaunchPrep.MaxLaunchHeight,
			GameConfig.LaunchPrep.MaxLaunchLength
		)

	local launchAnchorCFrame: CFrame? = nil
	local centerWorldCFrame: CFrame? = nil
	local obstructingNames: { string }? = nil

	if bounds.Valid then
		if bounds.Size.X > maxDims.X + 1e-3 or bounds.Size.Y > maxDims.Y + 1e-3 or bounds.Size.Z > maxDims.Z + 1e-3 then
			addIssue(
				"BuildError",
				"VehicleExceedsLaunchBounds",
				string.format(
					"Dimensiones (%.1f x %.1f x %.1f) exceden el límite de lanzamiento (%.1f x %.1f x %.1f).",
					bounds.Size.X,
					bounds.Size.Y,
					bounds.Size.Z,
					maxDims.X,
					maxDims.Y,
					maxDims.Z
				)
			)
		end

		if launchPoint and launchPoint.Parent then
			local floorAnchor = VehicleCoordinateMath.ComputeLaunchFloorWorld(launchPoint, groundClearance)
			launchAnchorCFrame = floorAnchor
			local centerWorld = floorAnchor * CFrame.new(0, bounds.Size.Y * 0.5, 0)
			centerWorldCFrame = centerWorld

			if not (options and options.SkipWorldObstructionCheck) then
				local blockers = detectLaunchObstructions(
					plot,
					centerWorld,
					bounds.Size,
					if options then options.ExtraExcludeInstances else nil
				)
				if #blockers > 0 then
					obstructingNames = blockers
					addIssue(
						"LocationError",
						"LaunchAreaBlocked",
						`La zona de lanzamiento está obstruida ({blockers[1]}).`
					)
				end
			end
		end
	end

	local wheelCount = 0
	local drivenWheelCount = 0
	local engineCount = 0
	local boosterCount = 0
	local functionalBoosterCount = 0
	local totalBoosterThrust = 0
	local totalNormalFuelCapacity = 0
	local totalNitroCapacity = 0
	local wheelWarnings: { string }? = nil
	local powertrainWarnings: { string }? = nil
	local boosterWarnings: { string }? = nil
	if #primaryPieces > 0 then
		for _, p in ipairs(primaryPieces) do
			local def = ItemRegistry.TryGet(p.ItemId)
			if def then
				if def.Category == "Engines" then
					engineCount += 1
					local engStats = EngineInventoryService.ResolvePieceEffectiveStats(blueprint.OwnerUserId, p)
					totalNormalFuelCapacity += (engStats.IntegratedFuel or 0)
				elseif def.Category == "Boosters" then
					boosterCount += 1
					local bstStats = BoosterInventoryService.ResolvePieceEffectiveStats(blueprint.OwnerUserId, p)
					totalNitroCapacity += (bstStats.IntegratedFuel or 0)
					local bstCfg = if type(p.Config) == "table" and type(p.Config.Booster) == "table"
						then p.Config.Booster
						else nil
					local isEnabled = not (bstCfg and bstCfg.Enabled == false)
					if isEnabled then
						functionalBoosterCount += 1
						local thrustRatio = if bstCfg and type(bstCfg.ThrustLimitRatio) == "number"
							then math.clamp(
								bstCfg.ThrustLimitRatio,
								GameConfig.Boosters.MinThrustLimitRatio,
								GameConfig.Boosters.MaxThrustLimitRatio
							)
							else GameConfig.Boosters.DefaultThrustLimitRatio
						totalBoosterThrust += bstStats.Thrust * thrustRatio
					end
				elseif def.Category == "FuelTanks" then
					local fuelCap = def.Stats.Capacity or 0
					if def.Stats.FuelType == "RocketFuel" or def.Stats.FuelSubtype == "Nitro" then
						totalNitroCapacity += fuelCap
					else
						totalNormalFuelCapacity += fuelCap
					end
				end
			end
		end

		local wheelAnalysis = WheelAutoConfigurationService.AnalyzeBlueprint(blueprint, {
			PrimaryPieceIds = analysis.PrimaryPieceIds,
		})
		wheelCount = wheelAnalysis.WheelCount
		if wheelCount > 0 then
			local warns: { string } = {}
			local seenWarn: { [string]: boolean } = {}
			for _, msg in ipairs(wheelAnalysis.AmbiguityWarnings) do
				if not seenWarn[msg] then
					seenWarn[msg] = true
					table.insert(warns, msg)
				end
			end
			for _, wid in ipairs(wheelAnalysis.OrderedWheelIds) do
				local resolved = wheelAnalysis.ByPieceId[wid]
				if resolved then
					if resolved.IsDriven then
						drivenWheelCount += 1
					end
					for _, wmsg in ipairs(resolved.Warnings) do
						if not seenWarn[wmsg] then
							seenWarn[wmsg] = true
							table.insert(warns, wmsg)
						end
					end
				end
			end
			if #warns > 0 then
				wheelWarnings = warns
			end
		end

		local excludedEngineCount = 0
		local excludedWheelCount = 0
		local excludedBoosterCount = 0
		if #analysis.WorkshopPieceIds > 0 then
			for _, p in ipairs(blueprint.Pieces) do
				if not primaryIdSet[p.InstanceId] then
					local def = ItemRegistry.TryGet(p.ItemId)
					if def then
						if def.Category == "Engines" then
							excludedEngineCount += 1
						elseif def.Category == "Wheels" then
							excludedWheelCount += 1
						elseif def.Category == "Boosters" then
							excludedBoosterCount += 1
						end
					end
				end
			end
		end

		local ptWarns: { string } = {}
		local bstWarns: { string } = {}
		if #primaryPieces == 1 and firstDriverSeatId ~= nil then
			if #analysis.WorkshopPieceIds > 0 then
				table.insert(
					ptWarns,
					`IncompletePrimaryAssembly: El ensamblaje principal solo contiene el DriverSeat aislado ({#analysis.WorkshopPieceIds} pieza(s) desconectada(s) serán excluidas del lanzamiento).`
				)
			else
				table.insert(
					ptWarns,
					"IncompletePrimaryAssembly: El vehículo solo tiene un DriverSeat aislado sin chasis, motor ni ruedas."
				)
			end
		elseif engineCount == 0 and wheelCount == 0 and boosterCount == 0 then
			table.insert(
				ptWarns,
				"NoPropulsionInstalled: El ensamblaje principal carece de motor y ruedas motrices; vehículo sin propulsión terrestre activa."
			)
		elseif engineCount > 0 and drivenWheelCount == 0 then
			table.insert(
				ptWarns,
				"NoDrivenWheels: El vehículo tiene motores instalados pero ninguna rueda motriz válida configurada."
			)
		elseif engineCount == 0 and wheelCount > 0 and boosterCount == 0 then
			table.insert(
				ptWarns,
				"NoEngineInstalled: El vehículo no tiene motores en el ensamblaje principal; solo rodará pasivamente."
			)
		elseif engineCount == 0 and boosterCount > 0 then
			table.insert(
				bstWarns,
				"BoosterOnlyPropulsion: El vehículo solo utiliza propulsores Nitro (RocketFuel), sin motor terrestre."
			)
		end
		if boosterCount > 0 and functionalBoosterCount == 0 then
			table.insert(
				bstWarns,
				"AllBoostersDisabled: Todos los propulsores instalados están deshabilitados en su configuración."
			)
		end
		if excludedEngineCount > 0 or excludedWheelCount > 0 then
			table.insert(
				ptWarns,
				`ExcludedDriveComponents: Hay {excludedEngineCount} motor(es) y {excludedWheelCount} rueda(s) desconectados del ensamblaje principal que quedarán fuera del lanzamiento.`
			)
		end
		if excludedBoosterCount > 0 then
			table.insert(
				bstWarns,
				`ExcludedBoosters: Hay {excludedBoosterCount} propulsor(es) desconectado(s) del ensamblaje principal que no se activarán.`
			)
		end
		if #ptWarns > 0 then
			powertrainWarnings = ptWarns
		end
		if #bstWarns > 0 then
			boosterWarnings = bstWarns
		end
	end

	local primaryIssue = issues[1]
	return {
		Ready = (#issues == 0),
		ErrorCategory = if primaryIssue then primaryIssue.Category else nil,
		PrimaryErrorCode = if primaryIssue then primaryIssue.Code else nil,
		PrimaryErrorMessage = if primaryIssue then primaryIssue.Message else nil,
		Issues = issues,
		BlueprintId = blueprint.BlueprintId,
		BlueprintRevision = blueprint.Revision,
		PieceCount = if #primaryPieces > 0 then #primaryPieces else totalPieceCount,
		TotalPieceCount = totalPieceCount,
		WorkshopPieceCount = #analysis.WorkshopPieceIds,
		PrimaryAssemblyGroupId = analysis.PrimaryGroupId,
		PrimaryAssemblyPieceIds = analysis.PrimaryPieceIds,
		WorkshopPieceIds = analysis.WorkshopPieceIds,
		AssemblyGroups = analysis.Groups,
		DisconnectedGroupCount = #analysis.Groups,
		NeedsPrimarySelection = analysis.NeedsPrimarySelection,
		DriverSeatCount = driverSeatCount,
		DriverSeatPieceId = if driverSeatCount == 1 and not analysis.AmbiguousPrimary then firstDriverSeatId else nil,
		WheelCount = wheelCount,
		WheelWarnings = wheelWarnings,
		EngineCount = engineCount,
		DrivenWheelCount = drivenWheelCount,
		PowertrainWarnings = powertrainWarnings,
		BoosterCount = boosterCount,
		FunctionalBoosterCount = functionalBoosterCount,
		TotalBoosterThrust = totalBoosterThrust,
		TotalNormalFuelCapacity = totalNormalFuelCapacity,
		TotalNitroCapacity = totalNitroCapacity,
		BoosterWarnings = boosterWarnings,
		BoundsMin = if bounds.Valid then bounds.Min else nil,
		BoundsMax = if bounds.Valid then bounds.Max else nil,
		BoundingSize = if bounds.Valid then bounds.Size else nil,
		GroundClearance = groundClearance,
		LaunchAnchorCFrame = launchAnchorCFrame,
		CenterWorldCFrame = centerWorldCFrame,
		ObstructingPartNames = obstructingNames,
	}
end

function VehicleLaunchPreparationService.EvaluatePlayerLaunch(
	player: PlotService.PlayerLike,
	options: LaunchCheckOptions?
): VehicleTypes.LaunchPreparationReport
	if not _initialized then
		VehicleLaunchPreparationService.Init()
	end
	local plot = PlotService.GetPlotByPlayer(player)
	local bp = VehicleBlueprintService.GetBlueprintSnapshot(player)
	return VehicleLaunchPreparationService.EvaluateBlueprintLaunch(bp, plot, options)
end

function VehicleLaunchPreparationService.ComputePieceLaunchWorldCFrames(
	blueprint: VehicleTypes.VehicleBlueprint,
	launchAnchorCFrame: CFrame
): { [string]: CFrame }
	local analysis = ConnectionService.AnalyzeBlueprintAssemblies(blueprint)
	if analysis.NeedsPrimarySelection or #analysis.PrimaryPieceIds == 0 then
		return {}
	end

	local primaryIdSet: { [string]: boolean } = {}
	for _, pid in ipairs(analysis.PrimaryPieceIds) do
		primaryIdSet[pid] = true
	end

	local primaryPieces: { VehicleTypes.BlueprintPiece } = {}
	for _, piece in ipairs(blueprint.Pieces) do
		if primaryIdSet[piece.InstanceId] then
			table.insert(primaryPieces, piece)
		end
	end

	if #primaryPieces == 0 then
		return {}
	end

	local originCF = VehicleCoordinateMath.ComputeBaseAnchor(primaryPieces, resolvePieceSize)
	local out: { [string]: CFrame } = {}
	for _, piece in ipairs(primaryPieces) do
		out[piece.InstanceId] = VehicleCoordinateMath.BlueprintPieceToLaunchWorld(
			piece.LocalCFrame,
			originCF,
			launchAnchorCFrame
		)
	end
	return out
end

function VehicleLaunchPreparationService.Init(options: { ItemAssetsRoot: Instance? }?)
	if _initialized then
		return
	end
	ItemRegistry.Init()
	_itemAssetsRoot = (options and options.ItemAssetsRoot) or ServerStorage:WaitForChild("ItemAssets")
	table.clear(_fallbackSizeCache)
	_initialized = true
end

function VehicleLaunchPreparationService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehicleLaunchPreparationService.Init()
	end
	_started = true
end

function VehicleLaunchPreparationService._ResetForTests()
	table.clear(_fallbackSizeCache)
	_itemAssetsRoot = nil
	_initialized = false
	_started = false
end

return VehicleLaunchPreparationService
