--!strict
--[=[
	VehicleAssemblyService
	Ensambla físicamente un VehicleRuntime temporal en un contenedor de staging fuera de escena
	(`ServerStorage._VehicleRuntimeStaging`) a partir del ensamblaje primario autorizado del Blueprint.
	- Administra CollisionGroups (`VehicleRuntime`, `EditableVehicle`, `EditorGhost`).
	- Clona únicamente desde `ServerStorage.ItemAssets`, sanitizando scripts y creando joints `WeldConstraint`
	  deduplicados según `Blueprint.Connections` (sin O(N²) redundante).
	- Respeta roles físicos (`RigidStructure`, `DriverSeat`, `FutureWheel`, `FuturePropulsion`, `Decorative`)
	  preparados para articulación/conducción en Fase 3.2 sin activarla aún en Fase 3.1.
]=]

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local DamageConfig = require(ReplicatedStorage.Shared.Config.DamageConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local VehicleCoordinateMath = require(ReplicatedStorage.Shared.Building.VehicleCoordinateMath)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local EngineInventoryService = require(ServerScriptService.Server.Services.EngineInventoryService)
local BoosterInventoryService = require(ServerScriptService.Server.Services.BoosterInventoryService)
local PlotService = require(ServerScriptService.Server.Services.PlotService)
local VehicleLaunchPreparationService = require(ServerScriptService.Server.Services.VehicleLaunchPreparationService)
local WheelAutoConfigurationService = require(ServerScriptService.Server.Services.WheelAutoConfigurationService)
local WheelMechanismBuilder = require(ServerScriptService.Server.Services.WheelMechanismBuilder)

export type AssembledStagingResult = {
	RootModel: Model,
	PrimaryPart: BasePart,
	DriverSeatPart: VehicleSeat,
	DriverSeatPieceId: string,
	PartsState: { [string]: VehicleTypes.RuntimePartState },
	PieceModelsById: { [string]: Model },
	Joints: { WeldConstraint },
	WheelPieceIds: { string },
	WheelConstraints: { Instance },
	WheelMechanisms: { [string]: WheelMechanismBuilder.BuiltWheelMechanism },
	WheelAnalysis: VehicleTypes.VehicleWheelAnalysis?,
	PropulsionPieceIds: { string },
	BoosterPieceIds: { string },
	NitroTankPieceIds: { string },
	AerodynamicPieceIds: { string },
	PieceAdjacencyById: { [string]: { string } },
	PieceCount: number,
	JointCount: number,
}

local VehicleAssemblyService = {
	Name = "VehicleAssemblyService",
}

local _itemAssetsRoot: Instance? = nil
local _stagingRoot: Folder? = nil
local _initialized = false
local _started = false

local function ensureGroupRegistered(groupName: string)
	if not PhysicsService:IsCollisionGroupRegistered(groupName) then
		PhysicsService:RegisterCollisionGroup(groupName)
	end
end

local function ensureStagingRoot(): Folder
	if _stagingRoot and _stagingRoot.Parent then
		return _stagingRoot
	end
	local existing = ServerStorage:FindFirstChild(GameConfig.Runtime.StagingFolderName)
	if existing and existing:IsA("Folder") then
		_stagingRoot = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = GameConfig.Runtime.StagingFolderName
	folder.Parent = ServerStorage
	_stagingRoot = folder
	return folder
end

function VehicleAssemblyService.EnsureCollisionGroups(vehiclesCollideWithEachOther: boolean?)
	local groups = GameConfig.Runtime.CollisionGroups
	ensureGroupRegistered(groups.VehicleRuntime)
	ensureGroupRegistered(groups.EditableVehicle)
	ensureGroupRegistered(groups.EditorGhost)

	local collideVehicles = if vehiclesCollideWithEachOther ~= nil
		then vehiclesCollideWithEachOther
		else GameConfig.Runtime.VehiclesCollideWithEachOther

	PhysicsService:CollisionGroupSetCollidable(groups.EditorGhost, "Default", false)
	PhysicsService:CollisionGroupSetCollidable(groups.EditorGhost, groups.EditableVehicle, false)
	PhysicsService:CollisionGroupSetCollidable(groups.EditorGhost, groups.VehicleRuntime, false)
	PhysicsService:CollisionGroupSetCollidable(groups.EditorGhost, groups.EditorGhost, false)

	PhysicsService:CollisionGroupSetCollidable(groups.EditableVehicle, "Default", true)
	PhysicsService:CollisionGroupSetCollidable(groups.EditableVehicle, groups.EditableVehicle, false)
	PhysicsService:CollisionGroupSetCollidable(groups.EditableVehicle, groups.VehicleRuntime, false)

	PhysicsService:CollisionGroupSetCollidable(groups.VehicleRuntime, "Default", true)
	PhysicsService:CollisionGroupSetCollidable(groups.VehicleRuntime, groups.VehicleRuntime, collideVehicles)
end

function VehicleAssemblyService.SetVehiclesCollideWithEachOther(enabled: boolean)
	VehicleAssemblyService.EnsureCollisionGroups(enabled)
end

function VehicleAssemblyService.ResolvePartPhysicsRole(itemDef: ItemTypes.ItemDefinition): VehicleTypes.PartPhysicsRole
	if itemDef.Id == GameConfig.LaunchPrep.DriverSeatItemId then
		return GameConfig.Runtime.PartRoles.DriverSeat :: VehicleTypes.PartPhysicsRole
	elseif itemDef.Category == "Seats" then
		return GameConfig.Runtime.PartRoles.PassengerSeat :: VehicleTypes.PartPhysicsRole
	elseif itemDef.Category == "Wheels" then
		return GameConfig.Runtime.PartRoles.FutureWheel :: VehicleTypes.PartPhysicsRole
	elseif itemDef.Category == "Engines" or itemDef.Category == "Boosters" then
		return GameConfig.Runtime.PartRoles.FuturePropulsion :: VehicleTypes.PartPhysicsRole
	elseif itemDef.Category == "Aerodynamics" then
		return GameConfig.Runtime.PartRoles.AerodynamicSurface :: VehicleTypes.PartPhysicsRole
	elseif itemDef.Category == "Decorations" then
		return GameConfig.Runtime.PartRoles.Decorative :: VehicleTypes.PartPhysicsRole
	end
	return GameConfig.Runtime.PartRoles.RigidStructure :: VehicleTypes.PartPhysicsRole
end

local function resolveAuthorizedAssetModel(def: ItemTypes.ItemDefinition): Model?
	local root = _itemAssetsRoot or ServerStorage:FindFirstChild("ItemAssets")
	return ItemRegistry.ResolveModel(root, def)
end

local function configureClonedRuntimePiece(
	pieceModel: Model,
	piece: VehicleTypes.BlueprintPiece,
	def: ItemTypes.ItemDefinition,
	role: VehicleTypes.PartPhysicsRole,
	ownerUserId: number,
	jointsOut: { WeldConstraint },
	jointsFolder: Folder
): (BasePart?, VehicleSeat?, number)
	local behaviorsFolder = pieceModel:FindFirstChild("Behaviors")
	if behaviorsFolder then
		behaviorsFolder:Destroy()
	end

	local parts: { BasePart } = {}
	local foundSeat: VehicleSeat? = nil

	for _, desc in ipairs(pieceModel:GetDescendants()) do
		if desc:IsA("LuaSourceContainer") then
			desc:Destroy()
		elseif desc:IsA("WeldConstraint") or desc:IsA("Constraint") then
			-- Limpiar constraints residuales del modelo plantilla para reconstruirlos de forma controlada
			desc:Destroy()
		elseif desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = true
			desc.CanQuery = true
			desc.CanTouch = true
			desc.AssemblyLinearVelocity = Vector3.zero
			desc.AssemblyAngularVelocity = Vector3.zero
			desc.CollisionGroup = GameConfig.Runtime.CollisionGroups.VehicleRuntime

			if desc:IsA("VehicleSeat") then
				desc.Disabled = false
				desc.HeadsUpDisplay = false
				desc:SetAttribute("CatalogMaxSpeed", desc.MaxSpeed)
				desc:SetAttribute("CatalogTorque", desc.Torque)
				desc:SetAttribute("CatalogTurnSpeed", desc.TurnSpeed)
				-- Fase 3.1: mantener DriverSeat funcional sin activar motorización automática ni conducción.
				desc.MaxSpeed = 0
				desc.Torque = 0
				desc.TurnSpeed = 0
				if not foundSeat then
					foundSeat = desc
				end
			elseif desc:IsA("Seat") then
				desc.Disabled = role ~= GameConfig.Runtime.PartRoles.PassengerSeat
			end

			table.insert(parts, desc)
		end
	end

	local primaryPart: BasePart? = nil
	local explicitPrimary = pieceModel:FindFirstChild("Primary")
	if explicitPrimary and explicitPrimary:IsA("BasePart") then
		primaryPart = explicitPrimary
	elseif pieceModel.PrimaryPart and pieceModel.PrimaryPart:IsA("BasePart") then
		primaryPart = pieceModel.PrimaryPart
	elseif foundSeat then
		primaryPart = foundSeat
	elseif #parts > 0 then
		primaryPart = parts[1]
	end

	if not primaryPart then
		return nil, foundSeat
	end

	pieceModel.PrimaryPart = primaryPart

	-- Si un componente futuro posee sub-partes rígidas, unirlas únicamente a su PrimaryPart
	for _, subPart in ipairs(parts) do
		if subPart ~= primaryPart then
			local subWeld = Instance.new("WeldConstraint")
			subWeld.Name = `InternalWeld_{piece.InstanceId}_{subPart.Name}`
			subWeld:SetAttribute("JointRole", "InternalSubPartWeld")
			subWeld:SetAttribute("PieceInstanceId", piece.InstanceId)
			subWeld.Part0 = primaryPart
			subWeld.Part1 = subPart
			subWeld.Enabled = true
			subWeld.Parent = jointsFolder
			table.insert(jointsOut, subWeld)
		end
	end

	pieceModel.Name = piece.InstanceId
	pieceModel:SetAttribute("PieceInstanceId", piece.InstanceId)
	pieceModel:SetAttribute(GameConfig.ItemAttributes.ItemId, piece.ItemId)
	pieceModel:SetAttribute(GameConfig.ItemAttributes.Category, def.Category)
	pieceModel:SetAttribute(GameConfig.PlotAttributes.OwnerUserId, ownerUserId)
	pieceModel:SetAttribute("PartPhysicsRole", role)
	pieceModel:SetAttribute("Weight", def.Stats.Weight)
	pieceModel:SetAttribute("MaxDurability", def.Stats.MaxDurability)
	pieceModel:SetAttribute("MaxHealth", def.Stats.MaxDurability)

	if role == GameConfig.Runtime.PartRoles.Wheel then
		pieceModel:SetAttribute("WheelState", "PendingWheelArticulation")
		pieceModel:SetAttribute("ArticulationReady", true)
	elseif role == GameConfig.Runtime.PartRoles.FuturePropulsion then
		pieceModel:SetAttribute("PropulsionCategory", def.Category)
		pieceModel:SetAttribute("PropulsionActive", def.Category == "Engines" or def.Category == "Boosters")
		if def.Category == "Engines" then
			local effectiveStats = EngineInventoryService.ResolvePieceEffectiveStats(ownerUserId, piece)
			pieceModel:SetAttribute("InventoryInstanceId", piece.InventoryInstanceId or "")
			pieceModel:SetAttribute("EngineFamilyId", effectiveStats.EngineFamilyId)
			pieceModel:SetAttribute("EngineSizeId", effectiveStats.EngineSizeId)
			pieceModel:SetAttribute("EngineVariantId", effectiveStats.VariantId)
			pieceModel:SetAttribute("EngineRarityId", effectiveStats.RarityId)
			pieceModel:SetAttribute("EnginePeakTorque", effectiveStats.PeakTorque)
			pieceModel:SetAttribute("EnginePowerRating", effectiveStats.PowerRating)
			pieceModel:SetAttribute("EngineSpeedRegular", effectiveStats.SpeedRegular)
			pieceModel:SetAttribute("Weight", effectiveStats.Weight)
			pieceModel:SetAttribute("MaxDurability", effectiveStats.MaxDurability)
			pieceModel:SetAttribute("EngineFullLabel", effectiveStats.FullLabel)
			pieceModel:SetAttribute("EngineBalanceStatus", effectiveStats.BalanceStatus)

			local weightScale = if def.Stats.Weight > 0 then effectiveStats.Weight / def.Stats.Weight else 1.0
			if math.abs(weightScale - 1.0) > 1e-3 then
				for _, p in ipairs(parts) do
					local baseProps = p.CurrentPhysicalProperties
					local nextDensity = math.clamp(baseProps.Density * weightScale, 0.05, 100.0)
					p.CustomPhysicalProperties = PhysicalProperties.new(
						nextDensity,
						baseProps.Friction,
						baseProps.Elasticity,
						baseProps.FrictionWeight,
						baseProps.ElasticityWeight
					)
				end
			end
		elseif def.Category == "Boosters" then
			local effectiveStats = BoosterInventoryService.ResolvePieceEffectiveStats(ownerUserId, piece)
			pieceModel:SetAttribute("InventoryInstanceId", piece.InventoryInstanceId or "")
			pieceModel:SetAttribute("BoosterFamilyId", effectiveStats.BoosterFamilyId)
			pieceModel:SetAttribute("BoosterSizeId", effectiveStats.BoosterSizeId)
			pieceModel:SetAttribute("BoosterVariantId", effectiveStats.VariantId)
			pieceModel:SetAttribute("BoosterRarityId", effectiveStats.RarityId)
			pieceModel:SetAttribute("BoosterThrust", effectiveStats.Thrust)
			pieceModel:SetAttribute("BoosterSpeedBoostMultiplier", effectiveStats.SpeedBoostMultiplier)
			pieceModel:SetAttribute("BoosterConsumption", effectiveStats.BoostConsumption)
			pieceModel:SetAttribute("BoosterIntegratedFuel", effectiveStats.IntegratedFuel)
			pieceModel:SetAttribute("Weight", effectiveStats.Weight)
			pieceModel:SetAttribute("MaxDurability", effectiveStats.MaxDurability)
			pieceModel:SetAttribute("BoosterFullLabel", effectiveStats.FullLabel)
			pieceModel:SetAttribute("BoosterBalanceStatus", effectiveStats.BalanceStatus)

			local weightScale = if def.Stats.Weight > 0 then effectiveStats.Weight / def.Stats.Weight else 1.0
			if math.abs(weightScale - 1.0) > 1e-3 then
				for _, p in ipairs(parts) do
					local baseProps = p.CurrentPhysicalProperties
					local nextDensity = math.clamp(baseProps.Density * weightScale, 0.05, 100.0)
					p.CustomPhysicalProperties = PhysicalProperties.new(
						nextDensity,
						baseProps.Friction,
						baseProps.Elasticity,
						baseProps.FrictionWeight,
						baseProps.ElasticityWeight
					)
				end
			end
		end
	elseif role == GameConfig.Runtime.PartRoles.AerodynamicSurface then
		pieceModel:SetAttribute("AeroWingArea", def.Stats.WingArea or 0)
		local totalVolume = 0
		for _, p in ipairs(parts) do
			if not p.Massless then
				totalVolume += (p.Size.X * p.Size.Y * p.Size.Z)
			end
		end
		if totalVolume > 1e-4 and def.Stats.Weight > 0 then
			local targetDensity = math.clamp(def.Stats.Weight / totalVolume, 0.05, 100.0)
			for _, p in ipairs(parts) do
				local baseProps = p.CurrentPhysicalProperties
				p.CustomPhysicalProperties = PhysicalProperties.new(
					targetDensity,
					baseProps.Friction,
					baseProps.Elasticity,
					baseProps.FrictionWeight,
					baseProps.ElasticityWeight
				)
			end
		end
	end

	if piece.Config then
		for cfgKey, cfgVal in pairs(piece.Config) do
			if type(cfgKey) == "string" and (type(cfgVal) == "string" or type(cfgVal) == "number" or type(cfgVal) == "boolean") then
				pieceModel:SetAttribute(`Config_{cfgKey}`, cfgVal)
			end
		end
	end

	local totalMass = 0
	for _, p in ipairs(parts) do
		if not p.Massless then
			totalMass += p:GetMass()
		end
	end

	return primaryPart, foundSeat, totalMass
end

local function resolveInitialFuel(def: ItemTypes.ItemDefinition): number?
	if def.Stats.Capacity ~= nil then
		return def.Stats.Capacity
	elseif def.Stats.IntegratedFuel ~= nil then
		return def.Stats.IntegratedFuel
	end
	return nil
end

local function isAssemblyConnectedFromRoot(
	rootPieceId: string,
	primaryIdSet: { [string]: boolean },
	adjacency: { [string]: { [string]: boolean } },
	expectedCount: number
): boolean
	if expectedCount <= 1 then
		return primaryIdSet[rootPieceId] == true
	end

	local visited: { [string]: boolean } = { [rootPieceId] = true }
	local queue = { rootPieceId }
	local head = 1
	local visitedCount = 1

	while head <= #queue do
		local current = queue[head]
		head += 1
		local neighbors = adjacency[current]
		if neighbors then
			for nb in pairs(neighbors) do
				if primaryIdSet[nb] and not visited[nb] then
					visited[nb] = true
					visitedCount += 1
					table.insert(queue, nb)
				end
			end
		end
	end

	return visitedCount == expectedCount
end

function VehicleAssemblyService.AssembleStagingRuntime(params: {
	RuntimeId: string,
	Player: PlotService.PlayerLike,
	Plot: PlotService.PlotRecord,
	Blueprint: VehicleTypes.VehicleBlueprint,
	PrepReport: VehicleTypes.LaunchPreparationReport,
	SkipStagingParent: boolean?,
}): (boolean, AssembledStagingResult?, string?, string?)
	if not _initialized then
		VehicleAssemblyService.Init()
	end

	local prep = params.PrepReport
	local blueprint = params.Blueprint
	local plot = params.Plot
	local player = params.Player

	if not prep.Ready then
		return false, nil, prep.PrimaryErrorCode or "LaunchNotReady", prep.PrimaryErrorMessage or "Diseño no listo para lanzar"
	end

	local launchFloorCF = prep.LaunchAnchorCFrame
		or VehicleCoordinateMath.ComputeLaunchFloorWorld(plot.Zones.LaunchPoint, GameConfig.LaunchPrep.GroundClearanceStuds)
	local worldCFramesById = VehicleLaunchPreparationService.ComputePieceLaunchWorldCFrames(blueprint, launchFloorCF)

	local primaryIdSet: { [string]: boolean } = {}
	local primaryCount = 0
	for pid in pairs(worldCFramesById) do
		primaryIdSet[pid] = true
		primaryCount += 1
	end

	if primaryCount == 0 then
		return false, nil, "AssemblyBuildFailed", "No hay piezas en el ensamblaje primario para construir el vehículo"
	end

	local stagingRoot = ensureStagingRoot()
	local runtimeModel = Instance.new("Model")
	runtimeModel.Name = GameConfig.Runtime.ModelName
	runtimeModel:SetAttribute("IsVehicleRuntime", true)
	runtimeModel:SetAttribute("RuntimeId", params.RuntimeId)
	runtimeModel:SetAttribute(GameConfig.PlotAttributes.OwnerUserId, player.UserId)
	runtimeModel:SetAttribute(GameConfig.PlotAttributes.PlotId, plot.PlotId)
	runtimeModel:SetAttribute("SourceBlueprintId", blueprint.BlueprintId)
	runtimeModel:SetAttribute("SourceBlueprintRevision", blueprint.Revision)
	runtimeModel:SetAttribute("RuntimeState", GameConfig.Runtime.States.Launching)
	CollectionService:AddTag(runtimeModel, GameConfig.Runtime.CollectionTag)

	local jointsFolder = Instance.new("Folder")
	jointsFolder.Name = GameConfig.Runtime.JointsFolderName
	jointsFolder.Parent = runtimeModel

	-- Mantener runtimeModel off-tree durante el ensamblado para evitar overhead por cada pieza/weld en DataModel.

	local partsState: { [string]: VehicleTypes.RuntimePartState } = {}
	local pieceModelsById: { [string]: Model } = {}
	local piecePrimaryPartsById: { [string]: BasePart } = {}
	local pieceRolesById: { [string]: VehicleTypes.PartPhysicsRole } = {}
	local partMassByPieceId: { [string]: number } = {}
	local joints: { WeldConstraint } = {}
	local wheelPieceIds: { string } = {}
	local propulsionPieceIds: { string } = {}
	local boosterPieceIds: { string } = {}
	local nitroTankPieceIds: { string } = {}
	local aerodynamicPieceIds: { string } = {}
	local primaryPieceIdsList: { string } = {}
	local wheelConstraints: { Instance } = {}
	local wheelMechanisms: { [string]: WheelMechanismBuilder.BuiltWheelMechanism } = {}
	local pieceAdjacencyById: { [string]: { string } } = {}
	local wheelAnalysis: VehicleTypes.VehicleWheelAnalysis? = nil
	local driverSeatPart: VehicleSeat? = nil
	local driverSeatPieceId: string? = nil
	local driverSeatPiece: VehicleTypes.BlueprintPiece? = nil

	local buildOk, buildErr = pcall(function()
		for _, piece in ipairs(blueprint.Pieces) do
			local targetWorldCF = worldCFramesById[piece.InstanceId]
			if not targetWorldCF then
				continue
			end

			table.insert(primaryPieceIdsList, piece.InstanceId)

			local itemDef = ItemRegistry.TryGet(piece.ItemId)
			if not itemDef then
				error(`UnknownItem:{piece.ItemId}`)
			end

			local template = resolveAuthorizedAssetModel(itemDef)
			if not template then
				error(`MissingAsset:{piece.ItemId}`)
			end

			local role = VehicleAssemblyService.ResolvePartPhysicsRole(itemDef)
			local clone = template:Clone()
			local piecePrimary, foundSeat, totalMass = configureClonedRuntimePiece(
				clone,
				piece,
				itemDef,
				role,
				player.UserId,
				joints,
				jointsFolder
			)
			if not piecePrimary then
				clone:Destroy()
				error(`MissingPrimaryPart:{piece.ItemId}`)
			end

			clone:PivotTo(targetWorldCF)
			clone.Parent = runtimeModel

			partMassByPieceId[piece.InstanceId] = totalMass

			pieceModelsById[piece.InstanceId] = clone
			piecePrimaryPartsById[piece.InstanceId] = piecePrimary
			pieceRolesById[piece.InstanceId] = role

			if role == GameConfig.Runtime.PartRoles.Wheel then
				table.insert(wheelPieceIds, piece.InstanceId)
			elseif role == GameConfig.Runtime.PartRoles.FuturePropulsion then
				table.insert(propulsionPieceIds, piece.InstanceId)
			end
			if itemDef.Category == "Boosters" then
				table.insert(boosterPieceIds, piece.InstanceId)
			elseif itemDef.Category == "Aerodynamics" then
				table.insert(aerodynamicPieceIds, piece.InstanceId)
			elseif
				itemDef.Category == "FuelTanks"
				and (itemDef.Stats.FuelType == "RocketFuel" or itemDef.Stats.FuelSubtype == "Nitro")
			then
				table.insert(nitroTankPieceIds, piece.InstanceId)
			end

			local catProfile = DamageConfig.GetCategoryProfile(itemDef.Category)
			local impactResistance = if itemDef.Stats and itemDef.Stats.ImpactResistance ~= nil
				then math.max(0.1, itemDef.Stats.ImpactResistance)
				else catProfile.ImpactResistance
			local damageMultiplier = if itemDef.Stats and itemDef.Stats.DamageMultiplier ~= nil
				then math.max(0, itemDef.Stats.DamageMultiplier)
				else catProfile.DamageMultiplier

			if role == GameConfig.Runtime.PartRoles.DriverSeat then
				if not foundSeat then
					error(`NonFunctionalDriverSeat:{piece.InstanceId}`)
				end
				if driverSeatPart ~= nil then
					error("MultipleDriverSeatsInAssembly")
				end
				driverSeatPart = foundSeat
				driverSeatPieceId = piece.InstanceId
				driverSeatPiece = piece
			end

			local effectiveMaxDurability = itemDef.Stats.MaxDurability
			local effectiveInitialFuel = resolveInitialFuel(itemDef)
			local runtimeCfg: { [string]: any }? = if piece.Config then table.clone(piece.Config) else nil
			if itemDef.Category == "Engines" then
				local engStats = EngineInventoryService.ResolvePieceEffectiveStats(player.UserId, piece)
				effectiveMaxDurability = engStats.MaxDurability
				effectiveInitialFuel = engStats.IntegratedFuel
				local cfgTable: { [string]: any } = runtimeCfg or {}
				cfgTable._InventoryInstanceId = piece.InventoryInstanceId
				cfgTable._ResolvedEngineStats = engStats
				runtimeCfg = cfgTable
			elseif itemDef.Category == "Boosters" then
				local bstStats = BoosterInventoryService.ResolvePieceEffectiveStats(player.UserId, piece)
				effectiveMaxDurability = bstStats.MaxDurability
				effectiveInitialFuel = bstStats.IntegratedFuel
				local cfgTable: { [string]: any } = runtimeCfg or {}
				cfgTable._InventoryInstanceId = piece.InventoryInstanceId
				cfgTable._ResolvedBoosterStats = bstStats
				runtimeCfg = cfgTable
			end

			clone:SetAttribute("MaxHealth", effectiveMaxDurability)

			partsState[piece.InstanceId] = {
				PieceId = piece.InstanceId,
				PieceInstanceId = piece.InstanceId,
				ItemId = piece.ItemId,
				Category = itemDef.Category,
				CurrentDurability = effectiveMaxDurability,
				MaxDurability = effectiveMaxDurability,
				Durability = effectiveMaxDurability,
				MaxHealth = effectiveMaxDurability,
				CurrentHealth = effectiveMaxDurability,
				ImpactResistance = impactResistance,
				DamageMultiplier = damageMultiplier,
				HealthState = DamageConfig.PieceStates.Healthy :: VehicleTypes.PieceHealthState,
				DamageReceivedTotal = 0,
				ImpactCount = 0,
				CurrentFuel = effectiveInitialFuel,
				IsDetached = false,
				IsFunctional = true,
				ModelInstance = clone,
				PhysicsRole = role,
				PrimaryPart = piecePrimary,
				Config = runtimeCfg,
			}
		end

		if not driverSeatPart or not driverSeatPieceId or not driverSeatPiece then
			error("DriverSeatMissingInAssembly")
		end

		runtimeModel.PrimaryPart = driverSeatPart

		-- Crear joints rígidos estrictamente sobre conexiones NO-rueda del Blueprint,
		-- registrando el soporte conectado de cada rueda para articularla en Fase 3.2.
		local seenPairs: { [string]: boolean } = {}
		local adjacency: { [string]: { [string]: boolean } } = {}
		local mountByWheelId: { [string]: string } = {}

		for _, conn in ipairs(blueprint.Connections) do
			if primaryIdSet[conn.FromPieceId] and primaryIdSet[conn.ToPieceId] and conn.FromPieceId ~= conn.ToPieceId then
				local idA, idB = conn.FromPieceId, conn.ToPieceId
				local pairKey = if idA < idB then `{idA}|{idB}` else `{idB}|{idA}`
				if not seenPairs[pairKey] then
					seenPairs[pairKey] = true

					local adjA = adjacency[idA]
					if not adjA then
						adjA = {}
						adjacency[idA] = adjA
					end
					adjA[idB] = true

					local adjB = adjacency[idB]
					if not adjB then
						adjB = {}
						adjacency[idB] = adjB
					end
					adjB[idA] = true

					local part0 = piecePrimaryPartsById[idA]
					local part1 = piecePrimaryPartsById[idB]
					if not part0 or not part1 then
						error(`MissingJointEndpoint:{pairKey}`)
					end

					local roleA = pieceRolesById[idA]
					local roleB = pieceRolesById[idB]
					local isWheelA = roleA == GameConfig.Runtime.PartRoles.Wheel
					local isWheelB = roleB == GameConfig.Runtime.PartRoles.Wheel
					local isWheelJoint = isWheelA or isWheelB

					if isWheelJoint then
						if isWheelA and not isWheelB and not mountByWheelId[idA] then
							mountByWheelId[idA] = idB
						elseif isWheelB and not isWheelA and not mountByWheelId[idB] then
							mountByWheelId[idB] = idA
						elseif isWheelA and isWheelB then
							if not mountByWheelId[idA] then
								mountByWheelId[idA] = idB
							end
						end
					else
						local weld = Instance.new("WeldConstraint")
						weld.Name = `Joint_{idA}_{idB}`
						weld:SetAttribute("JointRole", "RigidStructureJoint")
						weld.Part0 = part0
						weld.Part1 = part1
						weld.Enabled = true
						weld.Parent = jointsFolder
						table.insert(joints, weld)
					end
				end
			end
		end

		if not isAssemblyConnectedFromRoot(driverSeatPieceId :: string, primaryIdSet, adjacency, primaryCount) then
			error("DisconnectedPrimaryAssembly")
		end

		for pieceId, neighborSet in pairs(adjacency) do
			local neighbors: { string } = {}
			for nid in pairs(neighborSet) do
				table.insert(neighbors, nid)
			end
			table.sort(neighbors)
			pieceAdjacencyById[pieceId] = neighbors
		end

		if #wheelPieceIds > 0 then
			local computedAnalysis = WheelAutoConfigurationService.AnalyzeBlueprint(blueprint, {
				PrimaryPieceIds = primaryPieceIdsList,
				PartMassByPieceId = partMassByPieceId,
			})
			wheelAnalysis = computedAnalysis

			local mechResult = WheelMechanismBuilder.BuildWheelMechanisms({
				RootModel = runtimeModel,
				WheelPieceIds = wheelPieceIds,
				PieceModelsById = pieceModelsById,
				PiecePrimaryPartsById = piecePrimaryPartsById,
				PieceRolesById = pieceRolesById,
				MountByWheelId = mountByWheelId,
				WheelAnalysis = computedAnalysis,
				DriverSeatPiece = driverSeatPiece :: VehicleTypes.BlueprintPiece,
				DriverSeatPart = driverSeatPart :: VehicleSeat,
			})
			wheelConstraints = mechResult.Constraints
			wheelMechanisms = mechResult.MechanismsByPieceId
   -- El grafo físico usa solo el soporte realmente construido para cada rueda.
   for id, neighbors in pieceAdjacencyById do
    local kept = {}
    for _, other in neighbors do
     local wa, wb = wheelMechanisms[id], wheelMechanisms[other]
     if (not wa and not wb) or (wa and wa.MountPieceId == other) or (wb and wb.MountPieceId == id) then table.insert(kept, other) end
    end
    pieceAdjacencyById[id] = kept
   end
		end
	end)

	if not buildOk or not driverSeatPart or not driverSeatPieceId then
		runtimeModel:Destroy()
		return false, nil, "AssemblyBuildFailed", `Error ensamblando vehículo físico: {tostring(buildErr)}`
	end

	runtimeModel:SetAttribute("PieceCount", primaryCount)
	runtimeModel:SetAttribute("JointCount", #joints)
	runtimeModel:SetAttribute("WheelCount", #wheelPieceIds)
	runtimeModel:SetAttribute("WheelConstraintCount", #wheelConstraints)
	if not params.SkipStagingParent then
		runtimeModel.Parent = stagingRoot
	end

	return true,
		{
			RootModel = runtimeModel,
			PrimaryPart = driverSeatPart,
			DriverSeatPart = driverSeatPart,
			DriverSeatPieceId = driverSeatPieceId,
			PartsState = partsState,
			PieceModelsById = pieceModelsById,
			Joints = joints,
			WheelPieceIds = wheelPieceIds,
			WheelConstraints = wheelConstraints,
			WheelMechanisms = wheelMechanisms,
			WheelAnalysis = wheelAnalysis,
			PropulsionPieceIds = propulsionPieceIds,
			BoosterPieceIds = boosterPieceIds,
			NitroTankPieceIds = nitroTankPieceIds,
			AerodynamicPieceIds = aerodynamicPieceIds,
			PieceAdjacencyById = pieceAdjacencyById,
			PieceCount = primaryCount,
			JointCount = #joints,
		},
		nil,
		nil
end

function VehicleAssemblyService.ClearStaging()
	local existing = _stagingRoot or ServerStorage:FindFirstChild(GameConfig.Runtime.StagingFolderName)
	if existing then
		existing:ClearAllChildren()
	end
end

function VehicleAssemblyService.Init(options: { ItemAssetsRoot: Instance?, VehiclesCollideWithEachOther: boolean? }?)
	if _initialized then
		return
	end
	ItemRegistry.Init()
	_itemAssetsRoot = (options and options.ItemAssetsRoot) or ServerStorage:WaitForChild("ItemAssets")
	ensureStagingRoot()
	VehicleAssemblyService.EnsureCollisionGroups(if options then options.VehiclesCollideWithEachOther else nil)
	_initialized = true
end

function VehicleAssemblyService.Start()
	if _started then
		return
	end
	if not _initialized then
		VehicleAssemblyService.Init()
	end
	_started = true
end

function VehicleAssemblyService._ResetForTests()
	VehicleAssemblyService.ClearStaging()
	_itemAssetsRoot = nil
	_initialized = false
	_started = false
end

return VehicleAssemblyService


