--!strict
--[=[
	ItemCatalog
	Fachada centralizada de catálogo en español sobre ItemRegistry, EngineCatalog y BoosterCatalog (Fase 5.1).
	- Punto único de nombres visibles, descripciones, carpetas físicas y textos para interfaz/inventario.
	- Evita duplicar traducciones entre paneles de cliente y mensajes de servidor.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)

export type ShopAvailability = "DirectShop" | "LootBoxRewardOnly"

export type CatalogItemEntry = {
	Id: string,
	DisplayName: string,
	Description: string,
	Category: ItemTypes.ItemCategory,
	CategoryDisplayName: string,
	AssetFolder: string,
	InventoryKind: ItemTypes.InventoryItemKind,
	IsUniqueUnit: boolean,
	DirectPurchasable: boolean,
	ShopAvailability: ShopAvailability,
	Price: number?,
	SellPrice: number?,
	Stats: ItemTypes.ItemStats,
	MaxOwnedPerPlayer: number?,
}

local ItemCatalog = {}

local FUEL_SUBTYPE_LABELS: { [string]: string } = {
	Regular = "Regular",
	Diesel = "Diésel",
	Competicion = "Competición",
	Normal = "Combustible normal",
	Nitro = "Nitro (RocketFuel)",
	RocketFuel = "Combustible cohete",
}

local SOURCE_TAG_LABELS: { [string]: string } = {
	StarterKit = "Kit inicial",
	StarterDefault = "Base inicial",
	DevWorkshopSample = "Muestra de taller",
	DevTestGrant = "Prueba / Desarrollo",
	ShopPurchase = "Tienda",
	CrateDrop = "Caja especial",
	FutureCrate = "Caja especial",
}

local RARITY_HEX: { [string]: string } = {
	Common = "#B0B8C4",
	Uncommon = "#4ADE80",
	Rare = "#38BDF8",
	Epic = "#C084FC",
	Legendary = "#FBBF24",
	Mythic = "#F43F5E",
}

local function computeEffectiveSellPrice(def: ItemTypes.ItemDefinition): number?
	if ItemRegistry.IsUniqueInventoryItem(def) then
		return if ShopConfig.Economy.UniqueUnitMonetarySellEnabled then def.SellPrice else nil
	end
	if type(def.SellPrice) == "number" then
		return math.floor(def.SellPrice)
	end
	return ShopConfig.ComputeNormalSellPrice(def.Price)
end

local function makeEntry(def: ItemTypes.ItemDefinition): CatalogItemEntry
	local kind = ItemRegistry.GetInventoryKind(def)
	local isUnique = kind == "UniqueUnit"
	local sellPrice = computeEffectiveSellPrice(def)
	local explicitAvail = (def :: any).ShopAvailability
	local directPurchasable = if explicitAvail ~= nil
		then (explicitAvail == "DirectShop")
		else ((not isUnique) and type(def.Price) == "number" and (def.Price :: number) >= 0)
	local shopAvailability: ShopAvailability = if directPurchasable then "DirectShop" else "LootBoxRewardOnly"
	return {
		Id = def.Id,
		DisplayName = def.DisplayName,
		Description = ItemRegistry.GetDescription(def.Id),
		Category = def.Category,
		CategoryDisplayName = ItemRegistry.GetCategoryDisplayName(def.Category),
		AssetFolder = ItemRegistry.GetAssetFolder(def),
		InventoryKind = kind,
		IsUniqueUnit = isUnique,
		DirectPurchasable = directPurchasable,
		ShopAvailability = shopAvailability,
		Price = def.Price,
		SellPrice = sellPrice,
		Stats = def.Stats,
		MaxOwnedPerPlayer = nil, -- El límite de piezas (ej. 1 DriverSeat) aplica al vehículo en taller, nunca a compras/inventario
	}
end

function ItemCatalog.GetShopAvailability(defOrItemId: ItemTypes.ItemDefinition | string): ShopAvailability
	local def = if type(defOrItemId) == "string" then ItemRegistry.TryGet(defOrItemId) else defOrItemId
	if not def then
		return "LootBoxRewardOnly"
	end
	return makeEntry(def).ShopAvailability
end

function ItemCatalog.IsDirectShopPurchasable(defOrItemId: ItemTypes.ItemDefinition | string): boolean
	return ItemCatalog.GetShopAvailability(defOrItemId) == "DirectShop"
end

function ItemCatalog.IsLootBoxExclusiveReward(defOrItemId: ItemTypes.ItemDefinition | string): boolean
	return ItemCatalog.GetShopAvailability(defOrItemId) == "LootBoxRewardOnly"
end

function ItemCatalog.GetEntry(itemId: string): CatalogItemEntry?
	local def = ItemRegistry.TryGet(itemId)
	if not def then
		return nil
	end
	return makeEntry(def)
end

function ItemCatalog.GetAllEntries(): { CatalogItemEntry }
	local defs = ItemRegistry.GetAll()
	local entries: { CatalogItemEntry } = table.create(#defs)
	for _, def in ipairs(defs) do
		table.insert(entries, makeEntry(def))
	end
	table.sort(entries, function(a, b)
		local oa = ItemRegistry.GetCategorySortOrder(a.Category)
		local ob = ItemRegistry.GetCategorySortOrder(b.Category)
		if oa ~= ob then
			return oa < ob
		end
		return a.DisplayName < b.DisplayName
	end)
	return entries
end

function ItemCatalog.GetPurchasableShopItems(): { CatalogItemEntry }
	local out: { CatalogItemEntry } = {}
	for _, entry in ipairs(ItemCatalog.GetAllEntries()) do
		if entry.DirectPurchasable then
			table.insert(out, entry)
		end
	end
	return out
end

function ItemCatalog.GetSellPrice(defOrItemId: ItemTypes.ItemDefinition | string): number?
	local def = if type(defOrItemId) == "string" then ItemRegistry.TryGet(defOrItemId) else defOrItemId
	if not def then
		return nil
	end
	return computeEffectiveSellPrice(def)
end

function ItemCatalog.GetDisplayName(itemId: string): string
	return ItemRegistry.GetDisplayName(itemId)
end

function ItemCatalog.GetDescription(itemId: string): string
	return ItemRegistry.GetDescription(itemId)
end

function ItemCatalog.GetCategoryDisplayName(category: string): string
	return ItemRegistry.GetCategoryDisplayName(category)
end

function ItemCatalog.GetAssetFolder(defOrItemId: ItemTypes.ItemDefinition | string): string
	return ItemRegistry.GetAssetFolder(defOrItemId)
end

function ItemCatalog.FormatPriceLabel(price: number?): string
	if type(price) == "number" then
		return `${math.floor(price)}`
	end
	return "Solo en cajas especiales"
end

function ItemCatalog.FormatSellNote(entryOrSellPrice: CatalogItemEntry | number?): string
	local sellPrice: number? = if type(entryOrSellPrice) == "table"
		then (entryOrSellPrice :: CatalogItemEntry).SellPrice
		else entryOrSellPrice
	if type(sellPrice) == "number" then
		return `Valor de venta: ${math.floor(sellPrice)}`
	end
	return "Venta no habilitada (valoración TBD)"
end

function ItemCatalog.GetFuelLabel(fuelKey: string): string
	return FUEL_SUBTYPE_LABELS[fuelKey] or fuelKey
end

function ItemCatalog.GetSourceTagLabel(sourceTag: string): string
	return SOURCE_TAG_LABELS[sourceTag] or sourceTag
end

function ItemCatalog.GetRarityColorHex(rarityId: string): string
	return RARITY_HEX[rarityId] or "#B0B8C4"
end

function ItemCatalog.FormatEngineUnitLabel(
	itemId: string,
	familyId: string?,
	sizeId: string?,
	variantId: string?,
	rarityId: string?
): (string, string)
	local stats = EngineCatalog.ResolveEffectiveStats({
		ItemId = itemId,
		EngineFamilyId = familyId,
		EngineSizeId = sizeId,
		VariantId = variantId,
		RarityId = rarityId,
	})
	return stats.DisplayName, stats.FullLabel
end

function ItemCatalog.FormatBoosterUnitLabel(
	itemId: string,
	familyId: string?,
	sizeId: string?,
	variantId: string?,
	rarityId: string?
): (string, string)
	local stats = BoosterCatalog.ResolveEffectiveStats({
		ItemId = itemId,
		BoosterFamilyId = familyId,
		BoosterSizeId = sizeId,
		VariantId = variantId,
		RarityId = rarityId,
	})
	return stats.DisplayName, stats.FullLabel
end

return ItemCatalog

