--!strict
--[=[
	WheelAutoConfigurationService
	Servicio autoritativo de servidor que inspecciona los assets físicos en ServerStorage.ItemAssets
	(radios, anchos, ejes cilíndricos reales y masas reales de partes) y delega el análisis
	geométrico determinista y la precedencia híbrida Auto/Manual en WheelAutoConfiguration.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local WheelAutoConfiguration = require(ReplicatedStorage.Shared.Building.WheelAutoConfiguration)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local WheelAutoConfigurationService = {
	Name = "WheelAutoConfigurationService",
}

local _itemAssetsRoot: Instance? = nil
local _wheelGeomByItemId: { [string]: WheelAutoConfiguration.WheelItemSpec } = {}
local _measuredMassByItemId: { [string]: number } = {}
local _initialized = false
local _started = false

local function parseSpinAxisAttribute(rawAttr: any): Vector3?
	if typeof(rawAttr) == "Vector3" and rawAttr.Magnitude > 1e-4 then
		return rawAttr.Unit
	elseif type(rawAttr) == "string" then
		local upper = string.upper(rawAttr)
		if upper == "X" or upper == "+X" then
			return Vector3.new(1, 0, 0)
		elseif upper == "-X" then
			return Vector3.new(-1, 0, 0)
		elseif upper == "Y" or upper == "+Y" then
			return Vector3.new(0, 1, 0)
		elseif upper == "-Y" then
			return Vector3.new(0, -1, 0)
		elseif upper == "Z" or upper == "+Z" then
			return Vector3.new(0, 0, 1)
		elseif upper == "-Z" then
			return Vector3.new(0, 0, -1)
		end
	end
	return nil
end

local function inspectWheelAssetSpec(model: Model): WheelAutoConfiguration.WheelItemSpec
	local primary = model.PrimaryPart or model:FindFirstChild("Primary") :: BasePart? or model:FindFirstChildWhichIsA("BasePart", true)
	if not primary or not primary:IsA("BasePart") then
		return {
			WheelRadius = GameConfig.Wheels.DefaultWheelRadius,
			WheelWidth = GameConfig.Wheels.DefaultWheelWidth,
			LocalSpinAxis = GameConfig.Wheels.DefaultLocalSpinAxis,
		}
	end

	local localSpinAxis = parseSpinAxisAttribute(model:GetAttribute("LocalSpinAxis"))
	local radius = model:GetAttribute("WheelRadius")
	local width = model:GetAttribute("WheelWidth")

	if not localSpinAxis then
		if primary:IsA("Part") and primary.Shape == Enum.PartType.Cylinder then
			-- En Roblox, el eje circular de PartType.Cylinder es siempre X local
			localSpinAxis = Vector3.new(1, 0, 0)
		else
			local hub = primary:FindFirstChild("WheelHub")
			if hub and hub:IsA("Attachment") and hub.Axis.Magnitude > 1e-4 then
				localSpinAxis = hub.Axis.Unit
			else
				localSpinAxis = GameConfig.Wheels.DefaultLocalSpinAxis
			end
		end
	end

	if type(radius) ~= "number" or radius <= 0 then
		if math.abs(localSpinAxis.X) >= 0.7 then
			radius = math.max(primary.Size.Y, primary.Size.Z) * 0.5
		elseif math.abs(localSpinAxis.Y) >= 0.7 then
			radius = math.max(primary.Size.X, primary.Size.Z) * 0.5
		else
			radius = math.max(primary.Size.X, primary.Size.Y) * 0.5
		end
	end

	if type(width) ~= "number" or width <= 0 then
		if math.abs(localSpinAxis.X) >= 0.7 then
			width = primary.Size.X
		elseif math.abs(localSpinAxis.Y) >= 0.7 then
			width = primary.Size.Y
		else
			width = primary.Size.Z
		end
	end

	return {
		WheelRadius = radius :: number,
		WheelWidth = width :: number,
		LocalSpinAxis = localSpinAxis :: Vector3,
	}
end

local function computeModelMass(model: Model): number
	local total = 0
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and not desc.Massless then
			total += desc:GetMass()
		end
	end
	return total
end

local function rebuildAssetCaches()
	table.clear(_wheelGeomByItemId)
	table.clear(_measuredMassByItemId)

	local assetsRoot = _itemAssetsRoot or ServerStorage:FindFirstChild("ItemAssets")
	if not assetsRoot then
		return
	end

	for _, def in ipairs(ItemRegistry.GetAll()) do
		local model = ItemRegistry.ResolveModel(assetsRoot, def)
		if model then
			local m = computeModelMass(model)
			if m > 0 then
				_measuredMassByItemId[def.Id] = m
			end
			if def.Category == "Wheels" then
				_wheelGeomByItemId[def.Id] = inspectWheelAssetSpec(model)
			end
		end
	end
end

function WheelAutoConfigurationService.GetWheelItemSpec(itemId: string): WheelAutoConfiguration.WheelItemSpec
	if not _initialized then
		WheelAutoConfigurationService.Init()
	end
	return WheelAutoConfiguration.ResolveWheelItemSpec(itemId, _wheelGeomByItemId)
end

function WheelAutoConfigurationService.InspectWheelAsset(model: Model): WheelAutoConfiguration.WheelItemSpec
	return inspectWheelAssetSpec(model)
end

function WheelAutoConfigurationService.AnalyzeBlueprint(
	blueprint: VehicleTypes.VehicleBlueprint,
	options: WheelAutoConfiguration.AnalyzeOptions?
): VehicleTypes.VehicleWheelAnalysis
	if not _initialized then
		WheelAutoConfigurationService.Init()
	end

	local massByPieceId: { [string]: number } = {}
	if options and options.PartMassByPieceId then
		for k, v in pairs(options.PartMassByPieceId) do
			massByPieceId[k] = v
		end
	end
	for _, piece in ipairs(blueprint.Pieces) do
		if massByPieceId[piece.InstanceId] == nil and _measuredMassByItemId[piece.ItemId] ~= nil then
			massByPieceId[piece.InstanceId] = _measuredMassByItemId[piece.ItemId]
		end
	end

	return WheelAutoConfiguration.AnalyzeBlueprint(blueprint, {
		PrimaryPieceIds = if options then options.PrimaryPieceIds else nil,
		TargetPieceId = if options then options.TargetPieceId else nil,
		PartMassByPieceId = massByPieceId,
		WheelGeometryByItemId = (if options and options.WheelGeometryByItemId then options.WheelGeometryByItemId else _wheelGeomByItemId),
	})
end

function WheelAutoConfigurationService.Init(options: { ItemAssetsRoot: Instance? }?)
	if _initialized then
		return
	end
	ItemRegistry.Init()
	_itemAssetsRoot = (options and options.ItemAssetsRoot) or ServerStorage:WaitForChild("ItemAssets")
	rebuildAssetCaches()
	_initialized = true
end

function WheelAutoConfigurationService.Start()
	if _started then
		return
	end
	if not _initialized then
		WheelAutoConfigurationService.Init()
	end
	_started = true
end

function WheelAutoConfigurationService._ResetForTests()
	table.clear(_wheelGeomByItemId)
	table.clear(_measuredMassByItemId)
	_itemAssetsRoot = nil
	_initialized = false
	_started = false
end

return WheelAutoConfigurationService

