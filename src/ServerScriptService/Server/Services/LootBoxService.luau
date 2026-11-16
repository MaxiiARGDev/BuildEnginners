--!strict
--[=[
	LootBoxService
	Validación de pools de cajas especiales y selección aleatoria ponderada exclusivamente en servidor (Fase 5.2).

	Reutiliza EngineCatalog, BoosterCatalog e ItemRegistry sin inventar rarezas ni generar resultados
	inexistentes. Las instancias RolledLootReward se persisten en el pedido para evitar repetir sorteos.
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local SpecialCrateCatalogConfig = require(ReplicatedStorage.Shared.Config.SpecialCrateCatalogConfig)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local LootBoxService = {
	Name = "LootBoxService",
}

local _initialized = false
local _started = false
local _clockFn: () -> number = os.time
local _rng = Random.new()

local function defaultNextNumber(): number
	return _rng:NextNumber()
end

function LootBoxService.PickWeighted(
	orderedKeys: { string },
	weights: { [string]: number },
	nextFloatFn: (() -> number)?
): string
	local totalWeight = 0
	for _, k in ipairs(orderedKeys) do
		local w = weights[k] or 0
		if w > 0 then
			totalWeight += w
		end
	end
	if totalWeight <= 0 then
		error("[LootBoxService] Total weight must be > 0")
	end

	local draw = (nextFloatFn or defaultNextNumber)()
	draw = math.clamp(draw, 0, 0.999999999) * totalWeight
	local acc = 0
	local lastPositive = orderedKeys[1]
	for _, k in ipairs(orderedKeys) do
		local w = weights[k] or 0
		if w > 0 then
			lastPositive = k
			acc += w
			if draw < acc then
				return k
			end
		end
	end
	return lastPositive
end

function LootBoxService.RollRewardForOrder(
	boxId: string,
	nextFloatFn: (() -> number)?
): (boolean, ItemTypes.RolledLootReward?, string?, string?)
	if not _initialized then
		LootBoxService.Init()
	end

	local boxDef = LootBoxConfig.GetBox(boxId)
	if not boxDef then
		return false, nil, ShopProtocol.ErrorCodes.UnknownBox, `Caja desconocida: '{tostring(boxId)}'.`
	end
	if not boxDef.Enabled then
		return false, nil, ShopProtocol.ErrorCodes.BoxDisabled, boxDef.DisabledReason or `Caja deshabilitada.`
	end

	local poolOk, poolErr = LootBoxConfig.ValidateBoxPool(boxId)
	if not poolOk then
		return false, nil, ShopProtocol.ErrorCodes.BoxDisabled, `Configuración inválida de caja '{boxId}': {tostring(poolErr)}`
	end

	local poolDef = SpecialCrateCatalogConfig.GetRewardPool(boxDef.RewardPoolId)
	local targetCatalog = if poolDef
		then poolDef.TargetCatalog
		elseif boxDef.RewardCategory == "Boosters" then "Boosters"
		elseif boxDef.RewardCategory == "GroundEngines" then "Engines"
		else nil
	if targetCatalog ~= "Engines" and targetCatalog ~= "Boosters" then
		return false, nil, ShopProtocol.ErrorCodes.BoxDisabled, `La familia '{boxDef.RewardCategory}' aún no tiene motores funcionales.`
	end

	local randFn = nextFloatFn or defaultNextNumber
	local orderedRarities = if targetCatalog == "Engines"
		then EngineCatalog.GetOrderedRarityIds()
		else BoosterCatalog.GetOrderedRarityIds()

	local rarityId = LootBoxService.PickWeighted(orderedRarities, boxDef.RarityWeights, randFn)
	local sizeId = LootBoxService.PickWeighted(boxDef.AllowedSizes, boxDef.SizeWeights, randFn)

	local famIdx = math.clamp(math.floor(randFn() * #boxDef.AllowedFamilies) + 1, 1, #boxDef.AllowedFamilies)
	local varIdx = math.clamp(math.floor(randFn() * #boxDef.AllowedVariants) + 1, 1, #boxDef.AllowedVariants)
	local familyId = boxDef.AllowedFamilies[famIdx]
	local variantId = boxDef.AllowedVariants[varIdx]

	local validCombo, baseItemId, comboErr = LootBoxConfig.IsCombinationValid(boxDef, familyId, sizeId, variantId, rarityId)
	if not validCombo or not baseItemId then
		return false, nil, ShopProtocol.ErrorCodes.InvalidPayload, `Resultado inválido sorteado: {tostring(comboErr)}`
	end

	local displayName = baseItemId
	local fullLabel = baseItemId
	local prefix = if targetCatalog == "Engines" then "engunit_" else "bstunit_"
	local instanceId = prefix .. string.lower(string.gsub(HttpService:GenerateGUID(false), "-", "")):sub(1, 16)

	if targetCatalog == "Engines" then
		local stats = EngineCatalog.ResolveEffectiveStats({
			ItemId = baseItemId,
			EngineFamilyId = familyId,
			EngineSizeId = sizeId,
			VariantId = variantId,
			RarityId = rarityId,
		})
		displayName = stats.DisplayName
		fullLabel = stats.FullLabel
	else
		local stats = BoosterCatalog.ResolveEffectiveStats({
			ItemId = baseItemId,
			BoosterFamilyId = familyId,
			BoosterSizeId = sizeId,
			VariantId = variantId,
			RarityId = rarityId,
		})
		displayName = stats.DisplayName
		fullLabel = stats.FullLabel
	end

	local rolledCategory = if targetCatalog == "Engines" then "Engines" else "Boosters"
	local rolled: ItemTypes.RolledLootReward = {
		BoxId = boxId,
		ItemId = baseItemId,
		Category = rolledCategory,
		FamilyId = familyId,
		SizeId = sizeId,
		VariantId = variantId,
		RarityId = rarityId,
		ItemInstanceId = instanceId,
		DisplayName = displayName,
		FullLabel = fullLabel,
		RolledAt = _clockFn(),
		CreditedToInventory = false,
	}
	return true, rolled, nil, nil
end

function LootBoxService.ValidateAllEnabledBoxes(): (boolean, { string })
	local errs: { string } = {}
	for _, boxDef in ipairs(LootBoxConfig.GetEnabledBoxes()) do
		local ok, err = LootBoxConfig.ValidateBoxPool(boxDef.BoxId)
		if not ok then
			table.insert(errs, err or boxDef.BoxId)
		end
	end
	return #errs == 0, errs
end

function LootBoxService._SetClockForTests(clockFn: (() -> number)?)
	_clockFn = clockFn or os.time
end

function LootBoxService._ResetForTests()
	_clockFn = os.time
	_initialized = false
	_started = false
end

function LootBoxService.Init()
	if _initialized then
		return
	end
	_initialized = true
	ItemRegistry.Init()
	local ok, errs = LootBoxService.ValidateAllEnabledBoxes()
	if not ok then
		error(`[LootBoxService] Invalid LootBoxConfig: {table.concat(errs, "; ")}`)
	end
end

function LootBoxService.Start()
	if not _initialized then
		LootBoxService.Init()
	end
	_started = true
end

return LootBoxService

