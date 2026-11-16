--!strict
--[=[
	PreviewAssetService
	Publica copias visuales sanitizadas de los modelos autorizados de ServerStorage.ItemAssets
	hacia ReplicatedStorage.PreviewAssets para que el cliente pueda generar el ghost local.
	- Elimina carpetas Behaviors y cualquier Script/LocalScript/ModuleScript de las copias.
	- Mantiene intactos los modelos originales en ServerStorage.ItemAssets.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)

local PreviewAssetService = {
	Name = "PreviewAssetService",
}

local _previewRoot: Folder? = nil
local _initialized = false

local function sanitizeModelForPreview(model: Model)
	local behaviors = model:FindFirstChild("Behaviors")
	if behaviors then
		behaviors:Destroy()
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("LuaSourceContainer") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.CastShadow = false
		elseif descendant:IsA("Constraint") or descendant:IsA("WeldConstraint") then
			descendant.Enabled = false
		end
	end

	if model.PrimaryPart == nil then
		local primary = model:FindFirstChild("Primary")
		if primary and primary:IsA("BasePart") then
			model.PrimaryPart = primary
		else
			local anyPart = model:FindFirstChildWhichIsA("BasePart", true)
			if anyPart then
				model.PrimaryPart = anyPart
			end
		end
	end
end

function PreviewAssetService.Init(options: { ItemAssetsRoot: Instance?, TargetParent: Instance? }?)
	if _initialized then
		return
	end

	ItemRegistry.Init()

	local itemAssetsRoot = (options and options.ItemAssetsRoot) or ServerStorage:WaitForChild("ItemAssets")
	local targetParent = (options and options.TargetParent) or ReplicatedStorage

	local existing = targetParent:FindFirstChild(GameConfig.Building.PreviewAssetsFolder)
	if existing then
		existing:Destroy()
	end

	local previewRoot = Instance.new("Folder")
	previewRoot.Name = GameConfig.Building.PreviewAssetsFolder
	previewRoot.Parent = targetParent

	for _, def in ipairs(ItemRegistry.GetAll()) do
		local folderName = ItemRegistry.GetAssetFolder(def)
		local srcModel = ItemRegistry.ResolveModel(itemAssetsRoot, def)
		if not srcModel then
			error(`[PreviewAssetService] Missing authoritative model '{folderName}/{def.Model}' for '{def.Id}'`)
		end

		local dstCategory = previewRoot:FindFirstChild(folderName)
		if not dstCategory then
			local folder = Instance.new("Folder")
			folder.Name = folderName
			folder.Parent = previewRoot
			dstCategory = folder
		end

		local visualCopy = srcModel:Clone()
		sanitizeModelForPreview(visualCopy)
		visualCopy.Parent = dstCategory
	end

	local cratesRoot = ServerStorage:FindFirstChild("Crates")
	if cratesRoot then
		local especiales = cratesRoot:FindFirstChild("Especiales")
		if especiales then
			local dstEspeciales = Instance.new("Folder")
			dstEspeciales.Name = "CajasEspeciales"
			dstEspeciales.Parent = previewRoot
			for _, sub in ipairs(especiales:GetChildren()) do
				if sub:IsA("Folder") then
					local dstSub = Instance.new("Folder")
					dstSub.Name = sub.Name
					dstSub.Parent = dstEspeciales
					for _, crateModel in ipairs(sub:GetChildren()) do
						if crateModel:IsA("Model") then
							local copy = crateModel:Clone()
							sanitizeModelForPreview(copy)
							copy.Parent = dstSub
						end
					end
				elseif sub:IsA("Model") then
					local copy = sub:Clone()
					sanitizeModelForPreview(copy)
					copy.Parent = dstEspeciales
				end
			end
		end
	end

	_previewRoot = previewRoot
	targetParent:SetAttribute("PreviewAssetsReady", true)
	_initialized = true
end

function PreviewAssetService.Start()
	if not _initialized then
		PreviewAssetService.Init()
	end
end

function PreviewAssetService.GetPreviewRoot(): Folder?
	return _previewRoot
end

function PreviewAssetService._ResetForTests()
	if _previewRoot then
		_previewRoot:Destroy()
		_previewRoot = nil
	end
	_initialized = false
end

return PreviewAssetService

