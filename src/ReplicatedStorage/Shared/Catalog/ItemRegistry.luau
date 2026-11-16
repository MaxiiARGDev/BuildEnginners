--!strict
--[=[
	ItemRegistry
	Catálogo centralizado e inmutable de piezas del juego.
	- Registra automáticamente definiciones desde Catalog/Definitions/<Category>/<ItemId>.
	- Valida identificadores únicos, categorías, estadísticas y opcionalmente modelos/atributos en servidor.
	- No modifica servicios de construcción ni lógica de gameplay al añadir nuevas piezas.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local VALID_CATEGORIES: { [string]: boolean } = {
	Structures = true,
	Wheels = true,
	Engines = true,
	Boosters = true,
	FuelTanks = true,
	Seats = true,
	Aerodynamics = true,
	Utilities = true,
	Decorations = true,
	Other = true,
}

local CATEGORY_DISPLAY_NAMES: { [string]: string } = table.freeze({
	Structures = "Bloques",
	Wheels = "Ruedas",
	Engines = "Motores",
	Boosters = "Propulsores",
	FuelTanks = "Tanques",
	Seats = "Asientos",
	Aerodynamics = "Aerodinámica",
	Utilities = "Utilidades",
	Decorations = "Decoraciones",
	Other = "Otros",
})

local CATEGORY_ASSET_FOLDERS: { [string]: string } = table.freeze({
	Structures = "Bloques",
	Wheels = "Ruedas",
	Engines = "Motores",
	Boosters = "Propulsores",
	FuelTanks = "Tanques",
	Seats = "Asientos",
	Aerodynamics = "Aerodinamica",
	Utilities = "Utilidades",
	Decorations = "Decoraciones",
	Other = "Otros",
})

local CATEGORY_SORT_ORDER: { [string]: number } = table.freeze({
	Structures = 1,
	Wheels = 2,
	Engines = 3,
	Seats = 4,
	FuelTanks = 5,
	Boosters = 6,
	Aerodynamics = 7,
	Utilities = 8,
	Decorations = 9,
	Other = 10,
})

local VALID_ROTATION_MODES: { [string]: boolean } = {
	Orthogonal90 = true,
	StepDegrees = true,
	Free = true,
}

export type NormalizedPlacementPolicy = {
	RotationMode: ItemTypes.RotationPolicyMode,
	AllowedAngleStepsDeg: { number },
	AllowFreePosition: boolean,
	AllowFreeRotation: boolean,
}

local DEFAULT_PLACEMENT_POLICY: NormalizedPlacementPolicy = table.freeze({
	RotationMode = "Orthogonal90" :: ItemTypes.RotationPolicyMode,
	AllowedAngleStepsDeg = table.freeze({ 90 }),
	AllowFreePosition = true,
	AllowFreeRotation = false,
})

local NUMERIC_OPTIONAL_STATS = {
	"DamageMultiplier",
	"Eq",
	"Grip",
	"Capacity",
	"SpeedRegular",
	"Torque",
	"DrivingBonus",
	"DisconnectRate",
	"IntegratedFuel",
	"MaxConsumptionRegular",
	"BoostConsumption",
	"Thrust",
	"SpeedBoostMultiplier",
	"WingArea",
	"LiftCoefficientSlope",
	"ZeroAlphaLiftCoefficient",
	"MaxLiftCoefficient",
	"BaseDragCoefficient",
	"InducedDragFactor",
	"StallAngleDeg",
	"VerticalStabilizerArea",
}

local ItemRegistry = {}

local _itemsById: { [string]: ItemTypes.ItemDefinition } = {}
local _itemsByCategory: { [string]: { ItemTypes.ItemDefinition } } = {}
local _testOverridesById: { [string]: ItemTypes.ItemDefinition } = {}
local _initialized = false

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function deepFreeze<T>(tbl: T): T
	if type(tbl) ~= "table" then
		return tbl
	end
	for _, v in pairs(tbl :: any) do
		if type(v) == "table" then
			deepFreeze(v)
		end
	end
	if not table.isfrozen(tbl :: any) then
		table.freeze(tbl :: any)
	end
	return tbl
end

local function validateDefinition(def: any, expectedCategory: string?): (boolean, string?)
	if type(def) ~= "table" then
		return false, "Definition must return a table"
	end
	if type(def.Id) ~= "string" or def.Id == "" then
		return false, "Definition.Id must be a non-empty string"
	end
	if type(def.DisplayName) ~= "string" or def.DisplayName == "" then
		return false, `Definition '{def.Id}': DisplayName must be a non-empty string`
	end
	if def.Description ~= nil and (type(def.Description) ~= "string" or def.Description == "") then
		return false, `Definition '{def.Id}': Description must be nil or a non-empty string`
	end
	if def.AssetFolder ~= nil and (type(def.AssetFolder) ~= "string" or def.AssetFolder == "") then
		return false, `Definition '{def.Id}': AssetFolder must be nil or a non-empty string`
	end
	if def.InventoryKind ~= nil and def.InventoryKind ~= "Stackable" and def.InventoryKind ~= "UniqueUnit" then
		return false, `Definition '{def.Id}': InventoryKind inválido`
	end
	if type(def.Category) ~= "string" or not VALID_CATEGORIES[def.Category] then
		return false, `Definition '{def.Id}': invalid Category '{tostring(def.Category)}'`
	end
	if expectedCategory and def.Category ~= expectedCategory then
		return false, `Definition '{def.Id}': Category '{def.Category}' does not match folder '{expectedCategory}'`
	end
	if type(def.Model) ~= "string" or def.Model == "" then
		return false, `Definition '{def.Id}': Model must be a non-empty string`
	end
	if def.Price ~= nil and (not isFiniteNumber(def.Price) or def.Price < 0) then
		return false, `Definition '{def.Id}': Price must be nil (TBD) or a finite number >= 0`
	end
	if def.SellPrice ~= nil and (not isFiniteNumber(def.SellPrice) or def.SellPrice < 0) then
		return false, `Definition '{def.Id}': SellPrice must be nil (TBD) or a finite number >= 0`
	end
	if type(def.Stats) ~= "table" then
		return false, `Definition '{def.Id}': Stats table is required`
	end
	if not isFiniteNumber(def.Stats.Weight) or def.Stats.Weight <= 0 then
		return false, `Definition '{def.Id}': Stats.Weight must be a finite number > 0`
	end
	if not isFiniteNumber(def.Stats.MaxDurability) or def.Stats.MaxDurability <= 0 then
		return false, `Definition '{def.Id}': Stats.MaxDurability must be a finite number > 0`
	end
	if def.Stats.ImpactResistance ~= nil and (not isFiniteNumber(def.Stats.ImpactResistance) or def.Stats.ImpactResistance <= 0) then
		return false, `Definition '{def.Id}': Stats.ImpactResistance must be nil or a finite number > 0`
	end

	for _, statKey in ipairs(NUMERIC_OPTIONAL_STATS) do
		local value = def.Stats[statKey]
		if value ~= nil and (not isFiniteNumber(value) or value < 0) then
			return false, `Definition '{def.Id}': Stats.{statKey} must be nil or a finite number >= 0`
		end
	end

	if def.Behavior ~= nil and (type(def.Behavior) ~= "string" or def.Behavior == "") then
		return false, `Definition '{def.Id}': Behavior must be nil or a non-empty string`
	end

	if def.PlacementPolicy ~= nil then
		if type(def.PlacementPolicy) ~= "table" then
			return false, `Definition '{def.Id}': PlacementPolicy must be nil or a table`
		end
		local pol = def.PlacementPolicy
		if pol.RotationMode ~= nil and (type(pol.RotationMode) ~= "string" or not VALID_ROTATION_MODES[pol.RotationMode]) then
			return false, `Definition '{def.Id}': PlacementPolicy.RotationMode inválido`
		end
		if pol.AllowedAngleStepsDeg ~= nil then
			if type(pol.AllowedAngleStepsDeg) ~= "table" or #pol.AllowedAngleStepsDeg == 0 then
				return false, `Definition '{def.Id}': PlacementPolicy.AllowedAngleStepsDeg must be a non-empty array`
			end
			for _, stepDeg in ipairs(pol.AllowedAngleStepsDeg) do
				if not isFiniteNumber(stepDeg) or stepDeg <= 0 or stepDeg > 90 then
					return false, `Definition '{def.Id}': invalid angle step '{tostring(stepDeg)}'`
				end
			end
		end
		if pol.AllowFreePosition ~= nil and type(pol.AllowFreePosition) ~= "boolean" then
			return false, `Definition '{def.Id}': PlacementPolicy.AllowFreePosition must be boolean`
		end
		if pol.AllowFreeRotation ~= nil and type(pol.AllowFreeRotation) ~= "boolean" then
			return false, `Definition '{def.Id}': PlacementPolicy.AllowFreeRotation must be boolean`
		end
	end

	return true, nil
end

local function hasConnectionAttachment(model: Model): boolean
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Attachment") and string.sub(descendant.Name, 1, #GameConfig.ConnectionPrefix) == GameConfig.ConnectionPrefix then
			return true
		end
	end
	return false
end

export type DefinitionEntry = {
	Definition: any,
	ExpectedCategory: string?,
	SourceName: string?,
}

--[=[
	Valida una definición individual de objeto sin registrarla.
]=]
function ItemRegistry.ValidateDefinition(def: any, expectedCategory: string?): (boolean, string?)
	return validateDefinition(def, expectedCategory)
end

--[=[
	Carga y valida una lista de entradas de definición en memoria (tablas Luau).
	No modifica el registro global; útil tanto para LoadFromFolder como para pruebas unitarias.
]=]
function ItemRegistry.LoadFromEntries(entries: { DefinitionEntry }): ({ [string]: ItemTypes.ItemDefinition }, { [string]: { ItemTypes.ItemDefinition } })
	local byId: { [string]: ItemTypes.ItemDefinition } = {}
	local byCategory: { [string]: { ItemTypes.ItemDefinition } } = {}

	for categoryName in pairs(VALID_CATEGORIES) do
		byCategory[categoryName] = {}
	end

	for index, entry in ipairs(entries) do
		local sourceName = entry.SourceName or `entry#{index}`
		local valid, errMsg = validateDefinition(entry.Definition, entry.ExpectedCategory)
		if not valid then
			error(`[ItemRegistry] Invalid definition '{sourceName}': {errMsg}`)
		end

		local typedDef = entry.Definition :: ItemTypes.ItemDefinition
		if byId[typedDef.Id] ~= nil then
			error(`[ItemRegistry] Duplicate ItemId '{typedDef.Id}' in '{sourceName}'`)
		end

		deepFreeze(typedDef)
		byId[typedDef.Id] = typedDef
		table.insert(byCategory[typedDef.Category], typedDef)
	end

	for _, list in pairs(byCategory) do
		table.sort(list, function(a, b)
			return a.Id < b.Id
		end)
		table.freeze(list)
	end
	table.freeze(byId)
	table.freeze(byCategory)

	return byId, byCategory
end

--[=[
	Conveniencia para cargar y validar definiciones directamente desde tablas Luau.
]=]
function ItemRegistry.LoadFromTables(definitions: { any }): ({ [string]: ItemTypes.ItemDefinition }, { [string]: { ItemTypes.ItemDefinition } })
	local entries: { DefinitionEntry } = {}
	for index, def in ipairs(definitions) do
		table.insert(entries, {
			Definition = def,
			ExpectedCategory = nil,
			SourceName = `table#{index}`,
		})
	end
	return ItemRegistry.LoadFromEntries(entries)
end

--[=[
	Carga y valida todas las definiciones desde una carpeta raíz (por defecto Catalog/Definitions).
	Permite pasar una raíz personalizada en pruebas unitarias sin contaminar el registro global.
]=]
function ItemRegistry.LoadFromFolder(definitionsRoot: Instance): ({ [string]: ItemTypes.ItemDefinition }, { [string]: { ItemTypes.ItemDefinition } })
	local entries: { DefinitionEntry } = {}

	for _, categoryFolder in ipairs(definitionsRoot:GetChildren()) do
		if categoryFolder:IsA("Folder") then
			local categoryName = categoryFolder.Name
			if not VALID_CATEGORIES[categoryName] then
				error(`[ItemRegistry] Unknown category folder '{categoryName}'`)
			end

			for _, moduleScript in ipairs(categoryFolder:GetChildren()) do
				if moduleScript:IsA("ModuleScript") then
					local ok, def = pcall(require, moduleScript)
					if not ok then
						error(`[ItemRegistry] Failed to require definition '{categoryName}/{moduleScript.Name}': {tostring(def)}`)
					end

					table.insert(entries, {
						Definition = def,
						ExpectedCategory = categoryName,
						SourceName = `{categoryName}/{moduleScript.Name}`,
					})
				end
			end
		end
	end

	return ItemRegistry.LoadFromEntries(entries)
end

function ItemRegistry.Init(definitionsRoot: Instance?)
	if _initialized and definitionsRoot == nil then
		return
	end
	local root = definitionsRoot or script.Parent:WaitForChild("Definitions")
	_itemsById, _itemsByCategory = ItemRegistry.LoadFromFolder(root)
	_initialized = true
end

function ItemRegistry.IsInitialized(): boolean
	return _initialized
end

function ItemRegistry.Has(itemId: string): boolean
	if not _initialized then
		ItemRegistry.Init()
	end
	return (_testOverridesById[itemId] or _itemsById[itemId]) ~= nil
end

function ItemRegistry.TryGet(itemId: string): ItemTypes.ItemDefinition?
	if not _initialized then
		ItemRegistry.Init()
	end
	return _testOverridesById[itemId] or _itemsById[itemId]
end

function ItemRegistry.Get(itemId: string): ItemTypes.ItemDefinition
	local def = ItemRegistry.TryGet(itemId)
	if not def then
		error(`[ItemRegistry] Unknown ItemId '{tostring(itemId)}'`)
	end
	return def
end

--[=[
	Devuelve la política normalizada de colocación/rotación para un `ItemId`.
	Los objetos sin configuración explícita conservan rotaciones ortogonales de 90°.
]=]
function ItemRegistry.GetPlacementPolicy(itemId: string): NormalizedPlacementPolicy
	local def = ItemRegistry.TryGet(itemId)
	if not def or not def.PlacementPolicy then
		return DEFAULT_PLACEMENT_POLICY
	end

	local raw = def.PlacementPolicy
	local mode: ItemTypes.RotationPolicyMode = raw.RotationMode or "Orthogonal90"
	local steps: { number }
	if raw.AllowedAngleStepsDeg and #raw.AllowedAngleStepsDeg > 0 then
		steps = table.clone(raw.AllowedAngleStepsDeg)
		table.sort(steps, function(a, b)
			return a > b
		end)
		table.freeze(steps)
	elseif mode == "Orthogonal90" then
		steps = DEFAULT_PLACEMENT_POLICY.AllowedAngleStepsDeg
	elseif mode == "Free" then
		steps = table.freeze({ 90, 45, 15, 1 })
	else
		steps = table.freeze({ 90, 45, 15, 1 })
	end

	return table.freeze({
		RotationMode = mode,
		AllowedAngleStepsDeg = steps,
		AllowFreePosition = if raw.AllowFreePosition ~= nil then raw.AllowFreePosition else true,
		AllowFreeRotation = if raw.AllowFreeRotation ~= nil then raw.AllowFreeRotation else (mode == "Free"),
	})
end

function ItemRegistry._SetTestDefinitionForTests(def: ItemTypes.ItemDefinition)
	local ok, err = validateDefinition(def, nil)
	if not ok then
		error(`[ItemRegistry] Invalid test definition: {tostring(err)}`)
	end
	local copy = deepFreeze(table.clone(def))
	_testOverridesById[def.Id] = copy
end

function ItemRegistry._ClearTestOverridesForTests()
	table.clear(_testOverridesById)
end

function ItemRegistry.GetByCategory(category: ItemTypes.ItemCategory): { ItemTypes.ItemDefinition }
	if not _initialized then
		ItemRegistry.Init()
	end
	local list = _itemsByCategory[category]
	if not list then
		error(`[ItemRegistry] Unknown category '{tostring(category)}'`)
	end
	return list
end

function ItemRegistry.GetAll(): { ItemTypes.ItemDefinition }
	if not _initialized then
		ItemRegistry.Init()
	end
	local all: { ItemTypes.ItemDefinition } = {}
	for _, def in pairs(_itemsById) do
		table.insert(all, def)
	end
	table.sort(all, function(a, b)
		return a.Id < b.Id
	end)
	return all
end

function ItemRegistry.GetCategories(): { string }
	local cats = {}
	for k in pairs(VALID_CATEGORIES) do
		table.insert(cats, k)
	end
	table.sort(cats, function(a, b)
		return (CATEGORY_SORT_ORDER[a] or 99) < (CATEGORY_SORT_ORDER[b] or 99)
	end)
	return cats
end

function ItemRegistry.GetCategoryDisplayName(category: string): string
	return CATEGORY_DISPLAY_NAMES[category] or category
end

function ItemRegistry.GetCategorySortOrder(category: string): number
	return CATEGORY_SORT_ORDER[category] or 99
end

function ItemRegistry.GetAssetFolder(defOrCategoryOrItemId: ItemTypes.ItemDefinition | string): string
	if type(defOrCategoryOrItemId) == "table" then
		local def = defOrCategoryOrItemId :: ItemTypes.ItemDefinition
		if type(def.AssetFolder) == "string" and #def.AssetFolder > 0 then
			return def.AssetFolder
		end
		return CATEGORY_ASSET_FOLDERS[def.Category] or def.Category
	elseif type(defOrCategoryOrItemId) == "string" then
		if CATEGORY_ASSET_FOLDERS[defOrCategoryOrItemId] then
			return CATEGORY_ASSET_FOLDERS[defOrCategoryOrItemId]
		end
		local def = ItemRegistry.TryGet(defOrCategoryOrItemId)
		if def then
			return ItemRegistry.GetAssetFolder(def)
		end
		return defOrCategoryOrItemId
	end
	return "Other"
end

function ItemRegistry.GetDisplayName(itemId: string): string
	local def = ItemRegistry.TryGet(itemId)
	return if def then def.DisplayName else itemId
end

function ItemRegistry.GetDescription(itemId: string): string
	local def = ItemRegistry.TryGet(itemId)
	if def and type(def.Description) == "string" and #def.Description > 0 then
		return def.Description
	end
	return "Componente modular de construcción."
end

function ItemRegistry.GetInventoryKind(defOrItemId: ItemTypes.ItemDefinition | string): ItemTypes.InventoryItemKind
	local def = if type(defOrItemId) == "table"
		then (defOrItemId :: ItemTypes.ItemDefinition)
		else ItemRegistry.TryGet(defOrItemId)
	if not def then
		return "Stackable"
	end
	if def.InventoryKind == "UniqueUnit" or def.Category == "Engines" or def.Category == "Boosters" then
		return "UniqueUnit"
	end
	return "Stackable"
end

function ItemRegistry.IsUniqueInventoryItem(defOrItemId: ItemTypes.ItemDefinition | string): boolean
	return ItemRegistry.GetInventoryKind(defOrItemId) == "UniqueUnit"
end

--[=[
	Resuelve el Model autorizado o de preview para una definición dentro de ServerStorage.ItemAssets
	o ReplicatedStorage.PreviewAssets usando el mapeo central de carpetas en español.
]=]
function ItemRegistry.ResolveModel(assetsRoot: Instance?, defOrItemId: ItemTypes.ItemDefinition | string): (Model?, string?)
	if not assetsRoot then
		return nil, nil
	end
	local def = if type(defOrItemId) == "table"
		then (defOrItemId :: ItemTypes.ItemDefinition)
		else ItemRegistry.TryGet(defOrItemId)
	if not def then
		return nil, nil
	end
	local folderName = ItemRegistry.GetAssetFolder(def)
	local folder = assetsRoot:FindFirstChild(folderName)
	local model = if folder then folder:FindFirstChild(def.Model) else nil
	if model and model:IsA("Model") then
		return model, folderName
	end
	return nil, folderName
end

--[=[
	En modelos sincronizados por carpeta en Rojo, asigna PrimaryPart desde el hijo "Primary"
	si aún no está enlazado en el archivo de modelo.
]=]
function ItemRegistry.NormalizeAssets(itemAssetsRoot: Instance)
	for _, categoryFolder in ipairs(itemAssetsRoot:GetChildren()) do
		if categoryFolder:IsA("Folder") then
			for _, model in ipairs(categoryFolder:GetChildren()) do
				if model:IsA("Model") and model.PrimaryPart == nil then
					local primary = model:FindFirstChild("Primary")
					if primary and primary:IsA("BasePart") then
						model.PrimaryPart = primary
					end
				end
			end
		end
	end
end

--[=[
	Valida que todos los objetos registrados tengan su modelo en ServerStorage.ItemAssets/<CarpetaEspañol>/<Model>,
	atributos ItemId/Category correctos, PrimaryPart, puntos de conexión (Conn_*) y módulo Behavior si aplica.
]=]
function ItemRegistry.ValidateAssets(itemAssetsRoot: Instance): ItemTypes.AssetValidationResult
	if not _initialized then
		ItemRegistry.Init()
	end

	local errors: { string } = {}
	local checked = 0

	for _, def in pairs(_itemsById) do
		checked += 1
		local folderName = ItemRegistry.GetAssetFolder(def)
		local categoryFolder = itemAssetsRoot:FindFirstChild(folderName)
		if not categoryFolder then
			table.insert(errors, `Missing asset folder 'ItemAssets/{folderName}' for '{def.Id}'`)
			continue
		end

		local model = categoryFolder:FindFirstChild(def.Model)
		if not model or not model:IsA("Model") then
			table.insert(errors, `Missing Model 'ItemAssets/{folderName}/{def.Model}' for '{def.Id}'`)
			continue
		end

		if not model.PrimaryPart then
			table.insert(errors, `Model '{def.Id}' is missing PrimaryPart`)
		end

		local attrItemId = model:GetAttribute(GameConfig.ItemAttributes.ItemId)
		if attrItemId ~= def.Id then
			table.insert(errors, `Model '{def.Id}' attribute '{GameConfig.ItemAttributes.ItemId}' expected '{def.Id}', got '{tostring(attrItemId)}'`)
		end

		local attrCategory = model:GetAttribute(GameConfig.ItemAttributes.Category)
		if attrCategory ~= def.Category then
			table.insert(errors, `Model '{def.Id}' attribute '{GameConfig.ItemAttributes.Category}' expected '{def.Category}', got '{tostring(attrCategory)}'`)
		end

		if not hasConnectionAttachment(model) then
			table.insert(errors, `Model '{def.Id}' has no connection Attachment starting with '{GameConfig.ConnectionPrefix}'`)
		end

		if def.Behavior ~= nil then
			local behaviorsFolder = model:FindFirstChild("Behaviors")
			local behaviorModule = behaviorsFolder and behaviorsFolder:FindFirstChild(def.Behavior)
			if not behaviorModule or not behaviorModule:IsA("ModuleScript") then
				table.insert(errors, `Model '{def.Id}' is missing ModuleScript 'Behaviors/{def.Behavior}'`)
			end
		end
	end

	return {
		Valid = #errors == 0,
		Errors = errors,
		CheckedCount = checked,
	}
end

return ItemRegistry
