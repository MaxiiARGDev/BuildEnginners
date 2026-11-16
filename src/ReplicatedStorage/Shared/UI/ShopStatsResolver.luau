--!strict
--[=[
	ShopStatsResolver
	Resolvedor puro y autoritativo de estadísticas dinámicas por categoría de objeto
	y tabla de recompensas/probabilidades reales de LootBoxes (Fase 5.3.1).
	- Obtiene todos los datos exclusivamente de ItemCatalog, ItemRegistry, GameConfig,
	  AerodynamicsConfig, EngineCatalog, BoosterCatalog, LootBoxConfig y ShopConfig.
	- Nunca inventa estadísticas ni porcentajes.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AerodynamicsConfig = require(ReplicatedStorage.Shared.Config.AerodynamicsConfig)
local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local SpecialCrateCatalogConfig = require(ReplicatedStorage.Shared.Config.SpecialCrateCatalogConfig)

export type StatRowData = {
	Name: string,
	Value: string,
}

export type ResolvedItemDetails = {
	ItemId: string,
	DisplayName: string,
	Category: string,
	CategoryDisplayName: string,
	AssetFolder: string,
	ModelName: string,
	Description: string,
	Price: number?,
	SellPrice: number?,
	DirectPurchasable: boolean,
	StatsRows: { StatRowData },
}

export type ResolvedLootBoxRewardRow = {
	TierId: string,
	SizeId: string,
	SizeDisplayName: string,
	RarityId: string,
	RarityDisplayName: string,
	RarityColorHex: string,
	RewardName: string,
	ProbabilityPercent: number,
	RarityPercent: number,
	SizePercent: number,
	ProbabilityLabel: string,
	BonusesSummary: string,
}

export type ResolvedLootBoxDetails = {
	BoxId: string,
	DisplayName: string,
	Description: string,
	Family: string,
	RewardCategory: string,
	CategoryDisplayName: string,
	FamilyGlyph: string,
	FamilyShortTag: string,
	Price: number?,
	Enabled: boolean,
	DisabledReason: string?,
	RewardPoolId: string?,
	HasValidRewardPool: boolean,
	DeliveryTimeSeconds: number,
	RestockQuantity: number,
	RestockIntervalSeconds: number,
	RestockMin: number,
	RestockMax: number,
	AssetSubfolder: string,
	ModelName: string,
	SummaryText: string,
	PossibleRewards: { ResolvedLootBoxRewardRow },
}

local MATERIAL_LABELS_ES: { [Enum.Material]: string } = {
	[Enum.Material.Wood] = "Madera",
	[Enum.Material.WoodPlanks] = "Tablones de madera",
	[Enum.Material.Metal] = "Metal",
	[Enum.Material.DiamondPlate] = "Placa diamantada",
	[Enum.Material.CorrodedMetal] = "Metal industrial",
	[Enum.Material.SmoothPlastic] = "Compuesto liso",
	[Enum.Material.Plastic] = "Polímero",
	[Enum.Material.Neon] = "Neón",
	[Enum.Material.Glass] = "Vidrio",
	[Enum.Material.Fabric] = "Tela",
	[Enum.Material.Concrete] = "Hormigón",
}

local AERO_ROLE_DESCRIPTIONS: { [string]: string } = {
	AircraftWingLeft = "Ala lateral izquierda: genera sustentación y momento de alabeo (roll) según su distancia al centro de masa.",
	AircraftWingRight = "Ala lateral derecha: genera sustentación y equilibra el alabeo al montarse en simetría con el ala izquierda.",
	AircraftWing = "Ala universal simétrica: puede colocarse en cualquier lado o centro del vehículo para aportar sustentación directa.",
	AircraftTail = "Estabilizador de cola con deriva vertical: aporta estabilidad pasiva en cabeceo (pitch) y guiñada (yaw).",
	LargeGliderWing = "Ala de planeador de gran envergadura: máxima superficie alar para planear incluso en vehículos terrestres sin motor de avión.",
	SmallGliderWing = "Ala de planeador compacta: sustentación ligera y bajo peso para vehículos ágiles o híbridos.",
}

local ShopStatsResolver = {}

local function formatNumber(n: number, maxDecimals: number?): string
	local dec = maxDecimals or 2
	local factor = 10 ^ dec
	local rounded = math.round(n * factor) / factor
	if math.abs(rounded - math.round(rounded)) < 1e-6 then
		return tostring(math.round(rounded))
	end
	return tostring(rounded)
end

local function inspectModelMaterialAndSize(assetFolder: string, modelName: string): (string?, Vector3?)
	local previewAssets = ReplicatedStorage:FindFirstChild("PreviewAssets")
	local folder = previewAssets and previewAssets:FindFirstChild(assetFolder)
	local model = folder and folder:FindFirstChild(modelName)
	if not model or not model:IsA("Model") then
		local ServerStorage = game:GetService("ServerStorage")
		local ok, itemAssets = pcall(function()
			return ServerStorage:FindFirstChild("ItemAssets")
		end)
		if ok and itemAssets then
			local sFolder = itemAssets:FindFirstChild(assetFolder)
			model = sFolder and sFolder:FindFirstChild(modelName)
		end
	end
	if not model or not model:IsA("Model") then
		return nil, nil
	end
	local primary = model.PrimaryPart or model:FindFirstChild("Primary") or model:FindFirstChildWhichIsA("BasePart", true)
	local matLabel: string? = nil
	local dims: Vector3? = nil
	if primary and primary:IsA("BasePart") then
		matLabel = MATERIAL_LABELS_ES[primary.Material] or primary.Material.Name
		local _, boxSize = model:GetBoundingBox()
		dims = boxSize
	end
	return matLabel, dims
end

function ShopStatsResolver.ResolveItemDetails(itemId: string): ResolvedItemDetails?
	ItemRegistry.Init()
	local def = ItemRegistry.TryGet(itemId)
	local entry = ItemCatalog.GetEntry(itemId)
	if not def or not entry then
		return nil
	end

	local stats = def.Stats
	local rows: { StatRowData } = {}
	local function addRow(name: string, value: string?)
		if value and #value > 0 then
			table.insert(rows, { Name = name, Value = value })
		end
	end

	local matLabel, dims = inspectModelMaterialAndSize(entry.AssetFolder, def.Model)
	local dimsText: string? = nil
	if dims then
		dimsText = `{formatNumber(dims.X, 2)} × {formatNumber(dims.Y, 2)} × {formatNumber(dims.Z, 2)} studs`
	elseif def.AerodynamicSpecs and def.AerodynamicSpecs.Size then
		local sz = def.AerodynamicSpecs.Size
		dimsText = `{formatNumber(sz.X, 2)} × {formatNumber(sz.Y, 2)} × {formatNumber(sz.Z, 2)} studs`
	end

	if def.Category == "Structures" then
		addRow("Peso", `{formatNumber(stats.Weight)} u`)
		addRow("Durabilidad", `{formatNumber(stats.MaxDurability)} HP`)
		if matLabel then
			addRow("Material", matLabel)
		end
		if dimsText then
			addRow("Dimensiones", dimsText)
		end
		addRow("Descripción", entry.Description)
	elseif def.Category == "Wheels" then
		local W = GameConfig.Wheels
		addRow("Peso", `{formatNumber(stats.Weight)} u`)
		addRow("Durabilidad", `{formatNumber(stats.MaxDurability)} HP`)
		if type(stats.Grip) == "number" then
			addRow("Propiedades de tracción", `Agarre {formatNumber(stats.Grip)} · Motriz/Libre configurable (Fricción ×{formatNumber(W.WheelFrictionScale)})`)
		end
		addRow("Propiedades de dirección", `Auto / Manual · Giro máx. {formatNumber(W.DefaultMaxSteeringAngleDeg)}° ({formatNumber(W.DefaultSteeringSpeedDegPerSec)}°/s)`)
		addRow("Suspensión base", `Recorrido {formatNumber(W.DefaultSuspensionTravelStuds)} st · Rigidez {formatNumber(W.DefaultSpringStiffness)} · Amort. {formatNumber(W.DefaultSpringDamping)}`)
		if type(stats.Eq) == "number" then
			addRow("Equilibrio (Eq)", formatNumber(stats.Eq))
		end
		if dimsText then
			addRow("Dimensiones", dimsText)
		end
	elseif def.Category == "Engines" then
		local resolved = EngineCatalog.ResolveEffectiveStats({
			ItemId = def.Id,
			EngineFamilyId = "StandardCombustion",
			EngineSizeId = "Small",
			VariantId = "Balanced",
			RarityId = "Common",
		})
		addRow("Potencia", `{formatNumber(resolved.PowerRating)} CV · Torque pico: {formatNumber(resolved.PeakTorque)} N·m`)
		if type(stats.SpeedRegular) == "number" then
			addRow("Velocidad / Rendimiento", `{formatNumber(stats.SpeedRegular)} studs/s ({formatNumber(resolved.IdleRPM, 0)}–{formatNumber(resolved.MaxRPM, 0)} RPM)`)
		end
		if type(stats.FuelType) == "string" then
			addRow("Tipo de combustible", `{ItemCatalog.GetFuelLabel(stats.FuelType)} (Regular, Diésel, Competición)`)
		end
		if type(stats.MaxConsumptionRegular) == "number" then
			local intFuel = if type(stats.IntegratedFuel) == "number" then ` · Integrado: {formatNumber(stats.IntegratedFuel)} L` else ""
			addRow("Consumo", `{formatNumber(stats.MaxConsumptionRegular)} L/s{intFuel}`)
		end
		if type(stats.DrivingBonus) == "number" then
			local offRate = if type(stats.DisconnectRate) == "number" then ` · Offline: ${formatNumber(stats.DisconnectRate)}/h` else ""
			addRow("Bonificaciones", `+{formatNumber(stats.DrivingBonus * 100, 2)}% conducción{offRate}`)
		end
		addRow("Rareza", "Común a Mítico (6 rarezas, 3 tamaños, 3 familias y 5 variantes)")
		addRow("Peso", `{formatNumber(stats.Weight)} u`)
		addRow("Durabilidad", `{formatNumber(stats.MaxDurability)} HP`)
	elseif def.Category == "FuelTanks" then
		local fuelKey = (stats :: any).FuelSubtype or stats.FuelType
		if type(fuelKey) == "string" then
			local extra = ""
			if type((stats :: any).SelectableFuelTypes) == "table" then
				extra = " (Regular, Diésel, Competición)"
			end
			addRow("Tipo de combustible", `{ItemCatalog.GetFuelLabel(fuelKey)}{extra}`)
		end
		if type(stats.Capacity) == "number" then
			local unitStr = if stats.FuelType == "RocketFuel" then "unidades Nitro" else "L"
			addRow("Capacidad", `{formatNumber(stats.Capacity)} {unitStr}`)
		end
		addRow("Peso", `{formatNumber(stats.Weight)} u`)
		addRow("Durabilidad", `{formatNumber(stats.MaxDurability)} HP`)
		if dimsText then
			addRow("Dimensiones", dimsText)
		end
	elseif def.Category == "Boosters" then
		if type(stats.Thrust) == "number" then
			local mult = if type(stats.SpeedBoostMultiplier) == "number" then ` (Mult. vel.: {formatNumber(stats.SpeedBoostMultiplier)}x)` else ""
			addRow("Empuje", `{formatNumber(stats.Thrust)} N{mult}`)
		end
		if type(stats.BoostConsumption) == "number" then
			local intNitro = if type(stats.IntegratedFuel) == "number" then ` · Integrado: {formatNumber(stats.IntegratedFuel)} u` else ""
			addRow("Consumo", `{formatNumber(stats.BoostConsumption)} u/s{intNitro}`)
		end
		if type(stats.FuelType) == "string" then
			addRow("Tipo de combustible", ItemCatalog.GetFuelLabel(stats.FuelType))
		end
		addRow("Durabilidad", `{formatNumber(stats.MaxDurability)} HP`)
		addRow("Peso", `{formatNumber(stats.Weight)} u`)
		if type(stats.DrivingBonus) == "number" then
			addRow("Rareza y bonificaciones", `+{formatNumber(stats.DrivingBonus)}x conducción · 6 rarezas (Común a Mítico, hasta +48% empuje)`)
		end
	elseif def.Category == "Aerodynamics" then
		local aero = (AerodynamicsConfig.Surfaces :: any)[def.Id]
		if aero then
			local areaStr = `{formatNumber(aero.WingArea)} m²`
			if aero.VerticalStabilizerArea and aero.VerticalStabilizerArea > 0 then
				areaStr ..= ` (+{formatNumber(aero.VerticalStabilizerArea)} m² estabilizador vertical)`
			end
			addRow("Superficie alar", areaStr)
			addRow("Coeficiente de sustentación", `CL máx. {formatNumber(aero.MaxLiftCoefficient)} · Pendiente {formatNumber(aero.LiftCoefficientSlope)}/rad`)
			addRow("Resistencia aerodinámica", `CD base {formatNumber(aero.BaseDragCoefficient)} · Inducida {formatNumber(aero.InducedDragFactor)}`)
			addRow("Ángulo de pérdida", `{formatNumber(aero.StallAngleDeg)}° (CD post-pérdida {formatNumber(aero.PostStallDragCoefficient)})`)
		end
		addRow("Peso", `{formatNumber(stats.Weight)} u`)
		addRow("Durabilidad", `{formatNumber(stats.MaxDurability)} HP`)
		addRow("Función", AERO_ROLE_DESCRIPTIONS[def.Id] or entry.Description)
		if dimsText then
			addRow("Dimensiones", dimsText)
		end
	else
		-- Asientos y utilidades
		addRow("Peso", `{formatNumber(stats.Weight)} u`)
		addRow("Durabilidad", `{formatNumber(stats.MaxDurability)} HP`)
		if def.Id == "DriverSeat" then
			addRow("Límite en vehículo", "1 asiento de conductor por vehículo (inventario ilimitado)")
		end
		if matLabel then
			addRow("Material", matLabel)
		end
		if dimsText then
			addRow("Dimensiones", dimsText)
		end
	end

	return {
		ItemId = def.Id,
		DisplayName = entry.DisplayName,
		Category = def.Category,
		CategoryDisplayName = entry.CategoryDisplayName,
		AssetFolder = entry.AssetFolder,
		ModelName = def.Model,
		Description = entry.Description,
		Price = entry.Price,
		SellPrice = entry.SellPrice,
		DirectPurchasable = entry.DirectPurchasable,
		StatsRows = rows,
	}
end

function ShopStatsResolver.ResolveLootBoxDetails(boxId: string): ResolvedLootBoxDetails?
	local boxDef = LootBoxConfig.GetBox(boxId)
	if not boxDef then
		return nil
	end

	local famSpec = LootBoxConfig.GetFamilySpec(boxDef.RewardCategory)
	local catLabel = famSpec.DisplayName
	local pool = SpecialCrateCatalogConfig.GetRewardPool(boxDef.RewardPoolId)
	local hasValidPool = pool ~= nil and LootBoxConfig.HasValidRewardPool(boxId)

	local targetCatalog = if pool
		then pool.TargetCatalog
		elseif boxDef.RewardCategory == "Boosters" then "Boosters"
		elseif boxDef.RewardCategory == "GroundEngines" then "Engines"
		else nil

	local possibleRewards: { ResolvedLootBoxRewardRow } = {}
	if hasValidPool and targetCatalog ~= nil and #boxDef.AllowedSizes > 0 and #boxDef.AllowedFamilies > 0 and #boxDef.AllowedVariants > 0 then
		local orderedRarities = if targetCatalog == "Engines"
			then EngineCatalog.GetOrderedRarityIds()
			else BoosterCatalog.GetOrderedRarityIds()

		local raritySum = 0
		for _, rId in ipairs(orderedRarities) do
			raritySum += (boxDef.RarityWeights[rId] or 0)
		end
		if raritySum <= 0 then
			raritySum = 100
		end

		local sizeSum = 0
		for _, sId in ipairs(boxDef.AllowedSizes) do
			sizeSum += (boxDef.SizeWeights[sId] or 0)
		end
		if sizeSum <= 0 then
			sizeSum = 100
		end

		local defaultFamily = boxDef.AllowedFamilies[1]
		local defaultVariant = boxDef.AllowedVariants[1]
		for _, rId in ipairs(orderedRarities) do
			local rWeight = boxDef.RarityWeights[rId] or 0
			if rWeight > 0 then
				local rPct = (rWeight / raritySum) * 100
				for _, sId in ipairs(boxDef.AllowedSizes) do
					local sWeight = boxDef.SizeWeights[sId] or 0
					if sWeight > 0 then
						local sPct = (sWeight / sizeSum) * 100
						local jointPct = (rPct * sPct) / 100
						if targetCatalog == "Engines" then
							local rSpec = EngineCatalog.GetRaritySpec(rId :: any)
							local sSpec = EngineCatalog.GetSizeSpec(sId :: any)
							local eff = EngineCatalog.ResolveEffectiveStats({
								ItemId = sSpec.BaseItemId,
								EngineFamilyId = defaultFamily,
								EngineSizeId = sId,
								VariantId = defaultVariant,
								RarityId = rId,
							})
							local offRate = ShopConfig.ComputeEngineOfflineHourlyRate(sId, rId)
							local bonusStr = `Torque {formatNumber(eff.PeakTorque, 0)} N·m · Pot. {formatNumber(eff.PowerRating, 0)} CV · Vel. {formatNumber(eff.SpeedRegular, 1)} st/s · Bonif. +{formatNumber(eff.DrivingBonus * 100, 2)}% · Offline ${formatNumber(offRate, 2)}/h · {formatNumber(eff.MaxDurability, 0)} HP`
							table.insert(possibleRewards, {
								TierId = `{sId}_{rId}`,
								SizeId = sId,
								SizeDisplayName = sSpec.DisplayName,
								RarityId = rId,
								RarityDisplayName = rSpec.DisplayName,
								RarityColorHex = rSpec.ColorHex,
								RewardName = `{sSpec.DisplayName} [{rSpec.DisplayName}]`,
								ProbabilityPercent = jointPct,
								RarityPercent = rPct,
								SizePercent = sPct,
								ProbabilityLabel = string.format("%.2f%% (Rar. %s%%)", jointPct, formatNumber(rPct, 1)),
								BonusesSummary = bonusStr,
							})
						else
							local rSpec = BoosterCatalog.GetRaritySpec(rId :: any)
							local sSpec = BoosterCatalog.GetSizeSpec(sId :: any)
							local eff = BoosterCatalog.ResolveEffectiveStats({
								ItemId = sSpec.BaseItemId,
								BoosterFamilyId = defaultFamily,
								BoosterSizeId = sId,
								VariantId = defaultVariant,
								RarityId = rId,
							})
							local bonusStr = `Empuje {formatNumber(eff.Thrust, 0)} N · Mult. vel. {formatNumber(eff.SpeedBoostMultiplier, 2)}x · Nitro int. {formatNumber(eff.IntegratedFuel, 0)} u · Bonif. +{formatNumber(eff.DrivingBonus, 2)}x · {formatNumber(eff.MaxDurability, 0)} HP`
							table.insert(possibleRewards, {
								TierId = `{sId}_{rId}`,
								SizeId = sId,
								SizeDisplayName = sSpec.DisplayName,
								RarityId = rId,
								RarityDisplayName = rSpec.DisplayName,
								RarityColorHex = rSpec.ColorHex,
								RewardName = `{sSpec.DisplayName} [{rSpec.DisplayName}]`,
								ProbabilityPercent = jointPct,
								RarityPercent = rPct,
								SizePercent = sPct,
								ProbabilityLabel = string.format("%.2f%% (Rar. %s%%)", jointPct, formatNumber(rPct, 1)),
								BonusesSummary = bonusStr,
							})
						end
					end
				end
			end
		end
	end

	local summaryText = if not boxDef.Enabled or not hasValidPool
		then (boxDef.DisabledReason or "Próximamente · Motores y tabla de recompensas pendientes de implementación.")
		else `Pool: {boxDef.RewardPoolId} · Rarezas: Común 55% · No común 25% · Raro 12% · Épico 5% · Legendario 2.5% · Mítico 0.5% | Tamaños: Pequeño 70% · Mediano 25% · Grande 5% ({#boxDef.AllowedFamilies} familias × {#boxDef.AllowedVariants} variantes)`

	local minQ, maxQ, intervalSec = LootBoxConfig.GetStockBounds(boxDef.BoxId)
	return {
		BoxId = boxDef.BoxId,
		DisplayName = boxDef.DisplayName,
		Description = boxDef.Description,
		Family = boxDef.Family,
		RewardCategory = boxDef.RewardCategory,
		CategoryDisplayName = catLabel,
		FamilyGlyph = famSpec.Glyph,
		FamilyShortTag = famSpec.ShortTag,
		Price = boxDef.Price,
		Enabled = boxDef.Enabled and hasValidPool,
		DisabledReason = boxDef.DisabledReason,
		RewardPoolId = boxDef.RewardPoolId,
		HasValidRewardPool = hasValidPool,
		DeliveryTimeSeconds = LootBoxConfig.GetDeliverySeconds(boxDef.BoxId),
		RestockQuantity = boxDef.RestockQuantity,
		RestockIntervalSeconds = intervalSec,
		RestockMin = minQ,
		RestockMax = maxQ,
		AssetSubfolder = boxDef.AssetSubfolder,
		ModelName = boxDef.ModelName,
		SummaryText = summaryText,
		PossibleRewards = possibleRewards,
	}
end

return ShopStatsResolver
