--!strict
--[=[
	LootBoxConfig
	Capa unificada de acceso y resolución efectiva de Cajas Especiales sobre `SpecialCrateCatalogConfig`
	(Fases 5.2, 5.3.2 y 5.3.3).

	- No duplica precios, tiempos ni stock: deriva todas las definiciones base desde
	  `SpecialCrateCatalogConfig` (exactamente 14 cajas en 4 familias).
	- Resuelve la configuración efectiva combinando:
	    1. Valores predeterminados del catálogo (`SpecialCrateCatalogConfig`).
	    2. Overrides administrativos persistentes sincronizados (`_effectiveOverridesById`).
	    3. Overrides aislados exclusivos para suites de pruebas (`_testOverridesById`).
	- Nunca almacena estado efímero de servidor (`CurrentStock`) dentro de overrides globales.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local SpecialCrateCatalogConfig = require(ReplicatedStorage.Shared.Config.SpecialCrateCatalogConfig)

export type LootBoxRewardCategory = SpecialCrateCatalogConfig.CrateFamilyId
export type CrateFamilyFilter = SpecialCrateCatalogConfig.CrateFilterId
export type CrateFamilyIconId = SpecialCrateCatalogConfig.CrateIconId
export type CrateFamilyVisualSpec = SpecialCrateCatalogConfig.CrateFamilySpec

export type CrateOverridePatch = {
	Price: number?,
	DeliverySeconds: number?,
	RestockQuantity: number?,
	StockMin: number?,
	StockMax: number?,
	RestockIntervalSeconds: number?,
	Enabled: boolean?,
	DisabledReason: string?,
}

export type LootBoxDefinition = {
	BoxId: string,
	DisplayName: string,
	Description: string,
	Family: LootBoxRewardCategory,
	RewardCategory: LootBoxRewardCategory, -- Alias compatible con contratos previos
	ProgressionOrder: number,
	FamilyIcon: CrateFamilyIconId,
	IconId: CrateFamilyIconId,
	Price: number?,
	DeliverySeconds: number,
	RestockQuantity: number,
	StockMin: number,
	StockMax: number,
	RestockIntervalSeconds: number,
	Enabled: boolean,
	DisabledReason: string?,
	RewardPoolId: string?,
	AssetSubfolder: string, -- Carpeta dentro de ServerStorage.Crates.Especiales
	ModelName: string,
	AssetName: string,
	Restock: {
		MinQuantity: number,
		MaxQuantity: number,
		IntervalSeconds: number?,
	},
	RarityWeights: { [string]: number }, -- Porcentajes sumando 100
	SizeWeights: { [string]: number }, -- Porcentajes sumando 100
	AllowedSizes: { string },
	AllowedFamilies: { string },
	AllowedVariants: { string },
	BalanceStatus: string,
	RobuxSpeedupProductId: number?,
}

local _effectiveOverridesById: { [string]: CrateOverridePatch } = {}
local _effectiveRevision = 0
local _testOverridesById: { [string]: LootBoxDefinition } = {}

local LootBoxConfig = {}

local function getFamilyOrder(cat: LootBoxRewardCategory): number
	local spec = SpecialCrateCatalogConfig.GetFamilySpec(cat)
	return spec.FamilyOrder
end

local function cloneArray(arr: { string }?): { string }
	if type(arr) ~= "table" then
		return {}
	end
	return table.clone(arr)
end

local function cloneDict(dict: { [string]: number }?): { [string]: number }
	if type(dict) ~= "table" then
		return {}
	end
	return table.clone(dict)
end

local function materializeEntry(entry: SpecialCrateCatalogConfig.SpecialCrateCatalogEntry): LootBoxDefinition
	local override = _effectiveOverridesById[entry.BoxId]
	local pool = SpecialCrateCatalogConfig.GetRewardPool(entry.RewardPoolId)

	local price = entry.Price
	local deliverySeconds = entry.DeliverySeconds
	local restockQty = entry.RestockQuantity
	local stockMin = restockQty
	local stockMax = restockQty
	local restockInterval = entry.RestockIntervalSeconds
	local enabled = entry.Enabled
	local disabledReason = entry.DisabledReason

	if override then
		if type(override.Price) == "number" then
			price = override.Price
		end
		if type(override.DeliverySeconds) == "number" then
			deliverySeconds = override.DeliverySeconds
		end
		if type(override.RestockQuantity) == "number" then
			restockQty = override.RestockQuantity
			stockMin = restockQty
			stockMax = restockQty
		end
		if type(override.StockMin) == "number" then
			stockMin = override.StockMin
		end
		if type(override.StockMax) == "number" then
			stockMax = override.StockMax
		end
		if type(override.RestockIntervalSeconds) == "number" then
			restockInterval = override.RestockIntervalSeconds
		end
		if type(override.Enabled) == "boolean" then
			enabled = override.Enabled
		end
		if override.DisabledReason ~= nil then
			disabledReason = override.DisabledReason
		end
	end

	-- Regla de integridad: si una caja no tiene pool funcional válido, jamás puede quedar habilitada
	if enabled and pool == nil then
		enabled = false
		if not disabledReason or #disabledReason == 0 then
			disabledReason = "Próximamente · Pool de recompensas pendiente de implementación."
		end
	end

	return {
		BoxId = entry.BoxId,
		DisplayName = entry.DisplayName,
		Description = entry.Description,
		Family = entry.Family,
		RewardCategory = entry.Family,
		ProgressionOrder = entry.ProgressionOrder,
		FamilyIcon = entry.IconId,
		IconId = entry.IconId,
		Price = price,
		DeliverySeconds = math.max(1, math.floor(deliverySeconds)),
		RestockQuantity = math.max(0, math.floor(restockQty)),
		StockMin = math.max(0, math.floor(stockMin)),
		StockMax = math.max(math.floor(stockMin), math.floor(stockMax)),
		RestockIntervalSeconds = math.max(1, math.floor(restockInterval)),
		Enabled = enabled,
		DisabledReason = disabledReason,
		RewardPoolId = entry.RewardPoolId,
		AssetSubfolder = entry.AssetSubfolder,
		ModelName = entry.AssetName,
		AssetName = entry.AssetName,
		Restock = {
			MinQuantity = math.max(0, math.floor(stockMin)),
			MaxQuantity = math.max(math.floor(stockMin), math.floor(stockMax)),
			IntervalSeconds = math.max(1, math.floor(restockInterval)),
		},
		RarityWeights = if pool then cloneDict(pool.RarityWeights) else {},
		SizeWeights = if pool then cloneDict(pool.SizeWeights) else {},
		AllowedSizes = if pool then cloneArray(pool.AllowedSizes) else {},
		AllowedFamilies = if pool then cloneArray(pool.AllowedFamilies) else {},
		AllowedVariants = if pool then cloneArray(pool.AllowedVariants) else {},
		BalanceStatus = entry.BalanceStatus,
		RobuxSpeedupProductId = entry.RobuxSpeedupProductId,
	}
end

local function compareBoxesByProgression(a: LootBoxDefinition, b: LootBoxDefinition, groupFamilies: boolean): boolean
	if groupFamilies and a.RewardCategory ~= b.RewardCategory then
		local fa = getFamilyOrder(a.RewardCategory)
		local fb = getFamilyOrder(b.RewardCategory)
		if fa ~= fb then
			return fa < fb
		end
	end
	local pa = a.ProgressionOrder or 999
	local pb = b.ProgressionOrder or 999
	if pa ~= pb then
		return pa < pb
	end
	if a.Enabled ~= b.Enabled then
		return a.Enabled == true
	end
	local priceA = if type(a.Price) == "number" then a.Price else math.huge
	local priceB = if type(b.Price) == "number" then b.Price else math.huge
	if priceA ~= priceB then
		return priceA < priceB
	end
	return a.BoxId < b.BoxId
end

function LootBoxConfig.GetFamilySpec(category: string): CrateFamilyVisualSpec
	return SpecialCrateCatalogConfig.GetFamilySpec(category)
end

function LootBoxConfig.GetOrderedFamilies(): { CrateFamilyVisualSpec }
	return SpecialCrateCatalogConfig.GetOrderedFamilies()
end

function LootBoxConfig.FormatDeliveryTime(seconds: number?, compact: boolean?): string
	local s = math.max(0, math.floor(seconds or 900))
	if s < 60 then
		return `{s} s`
	end
	local m = math.floor(s / 60)
	local rem = s % 60
	if rem == 0 then
		if compact then
			return `{m} min`
		end
		return `{m} min ({s} s)`
	end
	if compact then
		return `{m}m {rem}s`
	end
	return `{m} min {rem} s ({s} s)`
end

function LootBoxConfig.GetBaseEntry(boxId: string): SpecialCrateCatalogConfig.SpecialCrateCatalogEntry?
	return SpecialCrateCatalogConfig.GetEntry(boxId)
end

function LootBoxConfig.GetOrderedBoxIds(): { string }
	return SpecialCrateCatalogConfig.GetOrderedBoxIds()
end

function LootBoxConfig.GetBox(boxId: string): LootBoxDefinition?
	if _testOverridesById[boxId] then
		return _testOverridesById[boxId]
	end
	local baseEntry = SpecialCrateCatalogConfig.GetEntry(boxId)
	if not baseEntry then
		return nil
	end
	return materializeEntry(baseEntry)
end

function LootBoxConfig.GetDeliverySeconds(boxId: string): number
	local def = LootBoxConfig.GetBox(boxId)
	if def and type(def.DeliverySeconds) == "number" and def.DeliverySeconds > 0 then
		return math.floor(def.DeliverySeconds)
	end
	return 900
end

function LootBoxConfig.GetStockBounds(boxId: string): (number, number, number)
	local def = LootBoxConfig.GetBox(boxId)
	if not def then
		return 0, 0, 300
	end
	local minQ = if type(def.StockMin) == "number"
		then def.StockMin
		elseif type(def.RestockQuantity) == "number" then def.RestockQuantity
		else (def.Restock and def.Restock.MinQuantity or 0)
	local maxQ = if type(def.StockMax) == "number"
		then def.StockMax
		elseif type(def.RestockQuantity) == "number" then def.RestockQuantity
		else (def.Restock and def.Restock.MaxQuantity or 0)
	local interval = if type(def.RestockIntervalSeconds) == "number" and def.RestockIntervalSeconds > 0
		then def.RestockIntervalSeconds
		else (def.Restock and def.Restock.IntervalSeconds or 300)
	local cleanMin = math.max(0, math.floor(minQ))
	local cleanMax = math.max(cleanMin, math.floor(maxQ))
	return cleanMin, cleanMax, math.max(1, math.floor(interval))
end

function LootBoxConfig.GetAllBoxes(): { LootBoxDefinition }
	local seen: { [string]: boolean } = {}
	local list: { LootBoxDefinition } = {}
	for _, entry in ipairs(SpecialCrateCatalogConfig.GetEntries()) do
		local def = _testOverridesById[entry.BoxId] or materializeEntry(entry)
		seen[entry.BoxId] = true
		table.insert(list, def)
	end
	for boxId, def in pairs(_testOverridesById) do
		if not seen[boxId] then
			seen[boxId] = true
			table.insert(list, def)
		end
	end
	table.sort(list, function(a, b)
		return compareBoxesByProgression(a, b, true)
	end)
	return list
end

function LootBoxConfig.GetBoxesByFamily(familyFilter: string): { LootBoxDefinition }
	local all = LootBoxConfig.GetAllBoxes()
	if familyFilter == "All" then
		return all
	end
	local normalized = SpecialCrateCatalogConfig.NormalizeFamilyId(familyFilter)
	local targetFam = normalized or familyFilter
	local filtered: { LootBoxDefinition } = {}
	for _, def in ipairs(all) do
		if def.RewardCategory == targetFam or def.Family == targetFam then
			table.insert(filtered, def)
		end
	end
	table.sort(filtered, function(a, b)
		return compareBoxesByProgression(a, b, false)
	end)
	return filtered
end

function LootBoxConfig.GetEnabledBoxes(): { LootBoxDefinition }
	local list: { LootBoxDefinition } = {}
	for _, def in ipairs(LootBoxConfig.GetAllBoxes()) do
		if def.Enabled then
			table.insert(list, def)
		end
	end
	return list
end

function LootBoxConfig.ApplyEffectiveOverrides(overridesByBoxId: { [string]: CrateOverridePatch }?, revision: number?)
	table.clear(_effectiveOverridesById)
	if type(overridesByBoxId) == "table" then
		for boxId, patch in pairs(overridesByBoxId) do
			if type(boxId) == "string" and type(patch) == "table" and SpecialCrateCatalogConfig.GetEntry(boxId) ~= nil then
				_effectiveOverridesById[boxId] = table.clone(patch)
			end
		end
	end
	if type(revision) == "number" and revision >= 0 then
		_effectiveRevision = math.floor(revision)
	end
end

function LootBoxConfig.ClearEffectiveOverrides()
	table.clear(_effectiveOverridesById)
	_effectiveRevision = 0
end

function LootBoxConfig.ExportEffectiveOverrides(): { [string]: CrateOverridePatch }
	local copy: { [string]: CrateOverridePatch } = {}
	for boxId, patch in pairs(_effectiveOverridesById) do
		copy[boxId] = table.clone(patch)
	end
	return copy
end

function LootBoxConfig.GetEffectiveRevision(): number
	return _effectiveRevision
end

function LootBoxConfig._SetBoxOverrideForTests(boxId: string, overrideDef: LootBoxDefinition?)
	if overrideDef == nil then
		_testOverridesById[boxId] = nil
	else
		_testOverridesById[boxId] = overrideDef
	end
end

function LootBoxConfig._ClearOverridesForTests()
	table.clear(_testOverridesById)
end

function LootBoxConfig.IsCombinationValid(
	boxDef: LootBoxDefinition,
	familyId: string,
	sizeId: string,
	variantId: string,
	rarityId: string
): (boolean, string?, string?)
	ItemRegistry.Init()
	local pool = SpecialCrateCatalogConfig.GetRewardPool(boxDef.RewardPoolId)
	local targetCatalog = if pool then pool.TargetCatalog elseif boxDef.RewardCategory == "Boosters" then "Boosters" elseif boxDef.RewardCategory == "GroundEngines" then "Engines" else nil
	if targetCatalog == "Engines" then
		if not EngineCatalog.IsValidFamilyId(familyId) then
			return false, nil, `Invalid engine family '{familyId}'`
		end
		if not EngineCatalog.IsValidSizeId(sizeId) then
			return false, nil, `Invalid engine size '{sizeId}'`
		end
		if not EngineCatalog.IsValidVariantId(variantId) then
			return false, nil, `Invalid engine variant '{variantId}'`
		end
		if not EngineCatalog.IsValidRarityId(rarityId) then
			return false, nil, `Invalid engine rarity '{rarityId}'`
		end
		local stats = EngineCatalog.ResolveEffectiveStats({
			EngineFamilyId = familyId,
			EngineSizeId = sizeId,
			VariantId = variantId,
			RarityId = rarityId,
		})
		if not ItemRegistry.Has(stats.BaseItemId) then
			return false, nil, `Missing ItemRegistry entry '{stats.BaseItemId}'`
		end
		return true, stats.BaseItemId, nil
	elseif targetCatalog == "Boosters" then
		if not BoosterCatalog.IsValidFamilyId(familyId) then
			return false, nil, `Invalid booster family '{familyId}'`
		end
		if not BoosterCatalog.IsValidSizeId(sizeId) then
			return false, nil, `Invalid booster size '{sizeId}'`
		end
		if not BoosterCatalog.IsValidVariantId(variantId) then
			return false, nil, `Invalid booster variant '{variantId}'`
		end
		if not BoosterCatalog.IsValidRarityId(rarityId) then
			return false, nil, `Invalid booster rarity '{rarityId}'`
		end
		local stats = BoosterCatalog.ResolveEffectiveStats({
			BoosterFamilyId = familyId,
			BoosterSizeId = sizeId,
			VariantId = variantId,
			RarityId = rarityId,
		})
		if not ItemRegistry.Has(stats.BaseItemId) then
			return false, nil, `Missing ItemRegistry entry '{stats.BaseItemId}'`
		end
		return true, stats.BaseItemId, nil
	end
	return false, nil, `Family '{tostring(boxDef.RewardCategory)}' has no functional engine/booster implementation yet`
end

function LootBoxConfig.HasValidRewardPool(boxId: string): (boolean, string?)
	local boxDef = LootBoxConfig.GetBox(boxId)
	if not boxDef then
		return false, `Unknown BoxId '{tostring(boxId)}'`
	end
	if type(boxDef.RewardPoolId) ~= "string" or #boxDef.RewardPoolId == 0 then
		return false, `Box '{boxId}' has no RewardPoolId assigned`
	end
	local pool = SpecialCrateCatalogConfig.GetRewardPool(boxDef.RewardPoolId)
	if not pool then
		return false, `Box '{boxId}' references unknown RewardPoolId '{tostring(boxDef.RewardPoolId)}'`
	end
	local orderedRarities = if pool.TargetCatalog == "Engines"
		then EngineCatalog.GetOrderedRarityIds()
		else BoosterCatalog.GetOrderedRarityIds()
	local raritySum = 0
	for _, rId in ipairs(orderedRarities) do
		local w = boxDef.RarityWeights[rId]
		if type(w) ~= "number" or w < 0 or w ~= w then
			return false, `Box '{boxId}' invalid RarityWeight for '{rId}'`
		end
		raritySum += w
	end
	if math.abs(raritySum - 100) > 0.05 then
		return false, `Box '{boxId}' RarityWeights must sum to 100 (got {raritySum})`
	end

	if #boxDef.AllowedSizes == 0 or #boxDef.AllowedFamilies == 0 or #boxDef.AllowedVariants == 0 then
		return false, `Box '{boxId}' has empty AllowedSizes / AllowedFamilies / AllowedVariants`
	end
	local sizeSum = 0
	for _, sId in ipairs(boxDef.AllowedSizes) do
		local w = boxDef.SizeWeights[sId]
		if type(w) ~= "number" or w <= 0 or w ~= w then
			return false, `Box '{boxId}' invalid SizeWeight for '{sId}'`
		end
		sizeSum += w
	end
	if math.abs(sizeSum - 100) > 0.05 then
		return false, `Box '{boxId}' SizeWeights must sum to 100 (got {sizeSum})`
	end

	for _, fam in ipairs(boxDef.AllowedFamilies) do
		for _, sz in ipairs(boxDef.AllowedSizes) do
			for _, var in ipairs(boxDef.AllowedVariants) do
				for _, rar in ipairs(orderedRarities) do
					if (boxDef.RarityWeights[rar] or 0) > 0 then
						local ok, _, err = LootBoxConfig.IsCombinationValid(boxDef, fam, sz, var, rar)
						if not ok then
							return false, err
						end
					end
				end
			end
		end
	end

	return true, nil
end

function LootBoxConfig.ValidateBoxPool(boxId: string): (boolean, string?)
	local boxDef = LootBoxConfig.GetBox(boxId)
	if not boxDef then
		return false, `Unknown BoxId '{tostring(boxId)}'`
	end
	if not boxDef.Enabled then
		return false, boxDef.DisabledReason or `Box '{boxId}' is disabled`
	end
	if type(boxDef.Price) ~= "number" or boxDef.Price <= 0 or boxDef.Price ~= boxDef.Price or boxDef.Price == math.huge then
		return false, `Box '{boxId}' missing valid positive Price`
	end
	return LootBoxConfig.HasValidRewardPool(boxId)
end

return LootBoxConfig
