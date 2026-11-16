--!strict
--[=[
	ShopUI.client.luau
	Controlador visual de Tienda sobre la jerarquía editable `StarterGui.ShopGui` (Fases 5.3.1 y 5.3.2).
	- Referencia las instancias existentes en `PlayerGui.ShopGui` (clonadas desde `StarterGui.ShopGui`).
	- Pestaña unificada "Cajas de motores" con barra secundaria editable `CrateFamilyFilterBar`
	  ("Todas", "Vehículos", "Propulsores", "Aviones").
	- Identificación visual por familia (`FamilyIconBadge`: ⚙ Vehículos, 🚀 Propulsores, 🛩 Aviones),
	  orden de progresión (`ProgressionOrder`), tiempo de entrega individual (`DeliverySeconds`)
	  y stock independiente por `BoxId`.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local ItemCatalog = require(ReplicatedStorage.Shared.Catalog.ItemCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopConfig = require(ReplicatedStorage.Shared.Config.ShopConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local ShopGuiSchema = require(ReplicatedStorage.Shared.UI.ShopGuiSchema)
local ShopStatsResolver = require(ReplicatedStorage.Shared.UI.ShopStatsResolver)
local ShopController = require(script.Parent.ShopController)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

ShopController.Init()
ItemRegistry.Init()

local legacyGui = playerGui:FindFirstChild("ShopAndEconomyGui")
if legacyGui then
	legacyGui:Destroy()
end

local function isUpdatedShopGui(gui: Instance?): boolean
	if not gui or not gui:IsA("ScreenGui") or gui.Name ~= "ShopGui" then
		return false
	end
	local mf = gui:FindFirstChild("MainFrame")
	return mf ~= nil and mf:FindFirstChild("CrateFamilyFilterBar") ~= nil and mf:FindFirstChild("EmptyCatalogOverlay") ~= nil
end

local function acquireShopGui(): ScreenGui
	local chosen: ScreenGui? = nil
	local immediate = playerGui:FindFirstChild("ShopGui") or playerGui:WaitForChild("ShopGui", 2)
	if isUpdatedShopGui(immediate) then
		chosen = immediate :: ScreenGui
	else
		local starterCopy = StarterGui:FindFirstChild("ShopGui")
		if isUpdatedShopGui(starterCopy) then
			local cloned = (starterCopy :: ScreenGui):Clone()
			cloned.Parent = playerGui
			chosen = cloned
		else
			chosen = ShopGuiSchema.BuildScreenGui(playerGui)
		end
	end

	local finalGui = chosen :: ScreenGui
	finalGui:SetAttribute("_ManagedByShopUI", true)

	for _, child in ipairs(playerGui:GetChildren()) do
		if child ~= finalGui and child.Name == "ShopGui" then
			child:Destroy()
		end
	end

	return finalGui
end

local shopGui = acquireShopGui()
playerGui.ChildAdded:Connect(function(child: Instance)
	if child ~= shopGui and child.Name == "ShopGui" and child:GetAttribute("_ManagedByShopUI") ~= true then
		task.defer(function()
			if child.Parent and child ~= shopGui and child:GetAttribute("_ManagedByShopUI") ~= true then
				child:Destroy()
			end
		end)
	end
end)
local responsiveScale = shopGui:WaitForChild("ResponsiveScale") :: UIScale

-- 1. Referencias a EconomyHudDock
local hudDock = shopGui:WaitForChild("EconomyHudDock") :: Frame
local moneyBadge = hudDock:WaitForChild("MoneyBadge") :: TextLabel
local shopToggleBtn = hudDock:WaitForChild("ShopToggleBtn") :: TextButton
local ordersToggleBtn = hudDock:WaitForChild("OrdersToggleBtn") :: TextButton
local offlinePendingBtn = hudDock:WaitForChild("OfflinePendingBtn") :: TextButton

-- 2. Referencias a MainFrame
local mainFrame = shopGui:WaitForChild("MainFrame") :: Frame
local header = mainFrame:WaitForChild("Header") :: Frame
local balanceSummaryLbl = header:WaitForChild("BalanceSummaryLabel") :: TextLabel
local restockCountdownLbl = header:WaitForChild("RestockCountdownLabel") :: TextLabel
local ordersBtn = header:WaitForChild("OrdersButton") :: TextButton
local closeBtn = header:WaitForChild("CloseButton") :: TextButton

local categoryTabs = mainFrame:WaitForChild("CategoryTabs") :: ScrollingFrame
local categoryBtnTemplate = categoryTabs:WaitForChild("CategoryButtonTemplate") :: TextButton
categoryBtnTemplate.Visible = false

local crateFamilyFilterBar = mainFrame:WaitForChild("CrateFamilyFilterBar") :: Frame
local crateFilterBtnTemplate = crateFamilyFilterBar:WaitForChild("CrateFilterButtonTemplate") :: TextButton
crateFilterBtnTemplate.Visible = false
local filterAllBtn = crateFamilyFilterBar:WaitForChild("Filter_All") :: TextButton
local filterEnginesBtn = crateFamilyFilterBar:WaitForChild("Filter_Engines") :: TextButton
local filterBoostersBtn = crateFamilyFilterBar:WaitForChild("Filter_Boosters") :: TextButton
local filterAircraftBtn = crateFamilyFilterBar:WaitForChild("Filter_AircraftEngines") :: TextButton

local statusBanner = mainFrame:WaitForChild("StatusBanner") :: TextLabel

local catalogScroll = mainFrame:WaitForChild("CatalogScroll") :: ScrollingFrame
local catalogGridLayout = catalogScroll:WaitForChild("CatalogGridLayout") :: UIGridLayout
local itemCardTemplate = catalogScroll:WaitForChild("ItemCardTemplate") :: Frame
itemCardTemplate.Visible = false

local emptyCatalogOverlay = mainFrame:WaitForChild("EmptyCatalogOverlay") :: Frame
local emptyIconLbl = emptyCatalogOverlay:WaitForChild("EmptyIconLabel") :: TextLabel
local emptyTitleLbl = emptyCatalogOverlay:WaitForChild("EmptyTitleLabel") :: TextLabel
local emptySubtitleLbl = emptyCatalogOverlay:WaitForChild("EmptySubtitleLabel") :: TextLabel

local cartPanel = mainFrame:WaitForChild("CartPanel") :: Frame
local cartItemsScroll = cartPanel:WaitForChild("CartItemsScroll") :: ScrollingFrame
local emptyCartLbl = cartItemsScroll:WaitForChild("EmptyCartLabel") :: TextLabel
local cartItemTemplate = cartItemsScroll:WaitForChild("CartItemTemplate") :: Frame
cartItemTemplate.Visible = false
local cartWaitNoteLbl = cartPanel:WaitForChild("CartWaitNote") :: TextLabel
local cartTotalLbl = cartPanel:WaitForChild("CartTotalLbl") :: TextLabel
local checkoutCartBtn = cartPanel:WaitForChild("CheckoutCartBtn") :: TextButton
local clearCartBtn = cartPanel:WaitForChild("ClearCartBtn") :: TextButton

-- 3. Referencias a ItemDetailsModal
local itemDetailsModal = shopGui:WaitForChild("ItemDetailsModal") :: Frame
local itemModalHeader = itemDetailsModal:WaitForChild("Header") :: Frame
local itemModalTitle = itemModalHeader:WaitForChild("TitleLabel") :: TextLabel
local itemModalCategory = itemModalHeader:WaitForChild("CategorySubtitle") :: TextLabel
local itemModalCloseBtn = itemModalHeader:WaitForChild("CloseButton") :: TextButton
local itemModalLeft = itemDetailsModal:WaitForChild("LeftColumn") :: Frame
local itemModalPreviewContainer = itemModalLeft:WaitForChild("PreviewContainer") :: Frame
local itemModalViewport = itemModalPreviewContainer:WaitForChild("PreviewViewport") :: ViewportFrame
local itemModalPriceBadge = itemModalLeft:WaitForChild("PriceBadge") :: TextLabel
local itemModalOwnedBadge = itemModalLeft:WaitForChild("OwnedBadge") :: TextLabel
local itemModalDesc = itemModalLeft:WaitForChild("DescriptionLabel") :: TextLabel
local itemModalRight = itemDetailsModal:WaitForChild("RightColumn") :: Frame
local statsScroll = itemModalRight:WaitForChild("StatsScroll") :: ScrollingFrame
local statRowTemplate = statsScroll:WaitForChild("StatRowTemplate") :: Frame
statRowTemplate.Visible = false

-- 4. Referencias a LootBoxDetailsModal
local lootBoxModal = shopGui:WaitForChild("LootBoxDetailsModal") :: Frame
local boxModalHeader = lootBoxModal:WaitForChild("Header") :: Frame
local boxModalFamilyBadge = boxModalHeader:FindFirstChild("FamilyIconBadge") :: Frame?
local boxModalTitle = boxModalHeader:WaitForChild("TitleLabel") :: TextLabel
local boxModalCategory = boxModalHeader:WaitForChild("CategoryBadge") :: TextLabel
local boxModalCloseBtn = boxModalHeader:WaitForChild("CloseButton") :: TextButton
local boxModalLeft = lootBoxModal:WaitForChild("LeftColumn") :: Frame
local boxModalPreviewContainer = boxModalLeft:WaitForChild("PreviewContainer") :: Frame
local boxModalViewport = boxModalPreviewContainer:WaitForChild("PreviewViewport") :: ViewportFrame
local boxModalDesc = boxModalLeft:WaitForChild("DescriptionLabel") :: TextLabel
local boxModalPriceLbl = boxModalLeft:WaitForChild("PriceInfoLabel") :: TextLabel
local boxModalDeliveryLbl = boxModalLeft:WaitForChild("DeliveryTimeLabel") :: TextLabel
local boxModalStockLbl = boxModalLeft:WaitForChild("StockInfoLabel") :: TextLabel
local boxModalBuyBtn = boxModalLeft:WaitForChild("BuyModalButton") :: TextButton
local boxModalRight = lootBoxModal:WaitForChild("RightColumn") :: Frame
local rewardsSummaryLbl = boxModalRight:WaitForChild("RewardsSummaryLabel") :: TextLabel
local rewardsScroll = boxModalRight:WaitForChild("RewardsScroll") :: ScrollingFrame
local rewardRowTemplate = rewardsScroll:WaitForChild("RewardRowTemplate") :: Frame
rewardRowTemplate.Visible = false

-- 5. Referencias a OrdersModal
local ordersModal = shopGui:WaitForChild("OrdersModal") :: Frame
local ordersModalHeader = ordersModal:WaitForChild("Header") :: Frame
local zoneSummaryLbl = ordersModalHeader:WaitForChild("ZoneSummaryLabel") :: TextLabel
local ordersModalCloseBtn = ordersModalHeader:WaitForChild("CloseButton") :: TextButton
local ordersScroll = ordersModal:WaitForChild("OrdersScroll") :: ScrollingFrame
local emptyOrdersLbl = ordersScroll:WaitForChild("EmptyOrdersLabel") :: TextLabel
local orderRowTemplate = ordersScroll:WaitForChild("OrderRowTemplate") :: Frame
orderRowTemplate.Visible = false

-- 6. Referencias a OfflineIncomeModal
local offlineModal = shopGui:WaitForChild("OfflineIncomeModal") :: Frame
local offCloseBtn = offlineModal:WaitForChild("OfflineCloseBtn") :: TextButton
local offAmountLbl = offlineModal:WaitForChild("OfflineAmountLbl") :: TextLabel
local offTimeLbl = offlineModal:WaitForChild("OfflineTimeLbl") :: TextLabel
local offBreakdownScroll = offlineModal:WaitForChild("OfflineBreakdownScroll") :: ScrollingFrame
local engineRowTemplate = offBreakdownScroll:WaitForChild("EngineRowTemplate") :: TextLabel
engineRowTemplate.Visible = false
local offNormalBtn = offlineModal:WaitForChild("ClaimNormalBtn") :: TextButton
local offAdBtn = offlineModal:WaitForChild("ClaimAd5xBtn") :: TextButton
local offAdStatusLbl = offlineModal:WaitForChild("OfflineAdStatusLbl") :: TextLabel

-- 7. Referencias a Notifications
local notificationsFrame = shopGui:WaitForChild("Notifications") :: Frame
local toastLbl = notificationsFrame:WaitForChild("ShopDeliveryToast") :: TextLabel

-- Categorías superiores (con una única pestaña unificada "Cajas de motores")
export type CategoryTabSpec = {
	Id: string,
	Label: string,
}

local CATEGORY_TABS: { CategoryTabSpec } = {
	{ Id = "All", Label = "Todas" },
	{ Id = "Structures", Label = "Bloques" },
	{ Id = "Wheels", Label = "Ruedas" },
	{ Id = "Seats", Label = "Asientos" },
	{ Id = "FuelTanks", Label = "Tanques" },
	{ Id = "Aerodynamics", Label = "Aerodinámica" },
	{ Id = "Crates", Label = "Cajas de motores" },
}

local CRATE_FAMILY_FILTERS: { { Id: LootBoxConfig.CrateFamilyFilter, Button: TextButton } } = {
	{ Id = "All", Button = filterAllBtn },
	{ Id = "Engines", Button = filterEnginesBtn },
	{ Id = "Boosters", Button = filterBoostersBtn },
	{ Id = "AircraftEngines", Button = filterAircraftBtn },
}

local _selectedCategoryId = "All"
local _selectedCrateFamilyFilter: LootBoxConfig.CrateFamilyFilter = "All"
local _selectedCrateQtyByBoxId: { [string]: number } = {}
local _openLootBoxId: string? = nil
local _openItemDetailsId: string? = nil
local _toastNonce = 0
local _categoryButtonsById: { [string]: TextButton } = {}
local _activeCardsByKey: { [string]: { Card: Frame, Kind: "Normal" | "SpecialBox", TargetId: string } } = {}
local _lastRenderedSignature = ""
local _liveOrderCountdowns: { { Label: TextLabel, ArriveAt: number, OrderType: string, RushBtn: TextButton? } } = {}

local refreshAllUi: () -> ()

local function formatMMSS(totalSec: number): string
	local s = math.max(0, math.floor(totalSec))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local remS = s % 60
	if h > 0 then
		return string.format("%02d:%02d:%02d", h, m, remS)
	end
	return string.format("%02d:%02d", m, remS)
end

local function formatMoney(amount: number?): string
	local v = math.floor(amount or 0)
	local s = tostring(v)
	local out = string.reverse(string.gsub(string.reverse(s), "(%d%d%d)", "%1,"))
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return `${out}`
end

local function parseHexColor(hex: string): Color3
	local clean = string.gsub(hex, "#", "")
	if #clean == 6 then
		local r = tonumber(string.sub(clean, 1, 2), 16) or 180
		local g = tonumber(string.sub(clean, 3, 4), 16) or 180
		local b = tonumber(string.sub(clean, 5, 6), 16) or 180
		return Color3.fromRGB(r, g, b)
	end
	return Color3.fromRGB(176, 184, 196)
end

local function showToast(msg: string)
	_toastNonce += 1
	local myNonce = _toastNonce
	toastLbl.Text = msg
	toastLbl.Visible = true
	task.delay(4.2, function()
		if _toastNonce == myNonce then
			toastLbl.Visible = false
		end
	end)
end

local function applyFamilyIconToBadge(badgeFrame: Frame?, rewardCategory: LootBoxConfig.LootBoxRewardCategory)
	if not badgeFrame then
		return
	end
	local famSpec = LootBoxConfig.GetFamilySpec(rewardCategory)
	badgeFrame.Visible = true
	local stroke = badgeFrame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = famSpec.AccentColor
	end
	local img = badgeFrame:FindFirstChild("FamilyIconImage") :: ImageLabel?
	local glyph = badgeFrame:FindFirstChild("FamilyIconGlyph") :: TextLabel?
	local hasCustomImage = type(famSpec.ImageAssetId) == "string"
		and #famSpec.ImageAssetId > 0
		and famSpec.ImageAssetId ~= "rbxassetid://0"
	if img then
		img.Image = famSpec.ImageAssetId
		img.ImageColor3 = famSpec.AccentColor
		img.Visible = hasCustomImage
	end
	if glyph then
		glyph.Text = famSpec.Glyph
		glyph.TextColor3 = famSpec.AccentColor
		glyph.Visible = not hasCustomImage
	end
end

-- === PREVIEWS 3D SANITIZADOS CON VIEWPORTFRAME + WORLDMODEL ===
local function findPreviewModelTemplate(assetFolder: string, modelName: string, isCrate: boolean?): Model?
	local previewAssets = ReplicatedStorage:FindFirstChild("PreviewAssets")
	if not previewAssets then
		return nil
	end
	if isCrate then
		local cratesFolder = previewAssets:FindFirstChild("CajasEspeciales")
		local sub = cratesFolder and cratesFolder:FindFirstChild(assetFolder)
		local crateModel = sub and sub:FindFirstChild(modelName)
		if crateModel and crateModel:IsA("Model") then
			return crateModel
		end
		if assetFolder == "Motores" then
			local mSub = cratesFolder and cratesFolder:FindFirstChild("Motores")
			local fallbackCrate = mSub and mSub:FindFirstChild("BasicEngineCrate")
			if fallbackCrate and fallbackCrate:IsA("Model") then
				return fallbackCrate
			end
		elseif assetFolder == "Propulsores" then
			local bSub = cratesFolder and cratesFolder:FindFirstChild("Propulsores")
			local fallbackCrate = bSub and bSub:FindFirstChild("BasicBoosterCrate")
			if fallbackCrate and fallbackCrate:IsA("Model") then
				return fallbackCrate
			end
		end
		return nil
	end

	local folder = previewAssets:FindFirstChild(assetFolder)
	local model = folder and folder:FindFirstChild(modelName)
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

local function populateViewportPreview(vp: ViewportFrame, assetFolder: string, modelName: string, isCrate: boolean?)
	local worldModel = vp:FindFirstChildOfClass("WorldModel")
	if not worldModel then
		local wm = Instance.new("WorldModel")
		wm.Name = "WorldModel"
		wm.Parent = vp
		worldModel = wm
	end
	worldModel:ClearAllChildren()

	local srcModel = findPreviewModelTemplate(assetFolder, modelName, isCrate)
	if not srcModel then
		return
	end

	local clone = srcModel:Clone()
	local behaviors = clone:FindFirstChild("Behaviors")
	if behaviors then
		behaviors:Destroy()
	end
	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("LuaSourceContainer") then
			desc:Destroy()
		elseif desc:IsA("BasePart") then
			desc.Anchored = true
			desc.CanCollide = false
			desc.CanTouch = false
			desc.CanQuery = false
			desc.CastShadow = false
		elseif desc:IsA("Constraint") or desc:IsA("WeldConstraint") then
			desc.Enabled = false
		end
	end

	clone.Parent = worldModel
	local boxCF, boxSize = clone:GetBoundingBox()
	local pivotOffset = clone:GetPivot().Position - boxCF.Position
	clone:PivotTo(CFrame.new(pivotOffset))

	local cam = vp.CurrentCamera
	if not cam or not cam:IsDescendantOf(vp) then
		local existingCam = vp:FindFirstChildOfClass("Camera")
		if existingCam then
			cam = existingCam
		else
			local newCam = Instance.new("Camera")
			newCam.Name = "PreviewCamera"
			newCam.FieldOfView = 40
			newCam.Parent = vp
			cam = newCam
		end
		vp.CurrentCamera = cam
	end

	local maxDim = math.max(boxSize.X, boxSize.Y, boxSize.Z, 1.8)
	local dist = maxDim * 1.42
	local camPos = Vector3.new(dist * 0.68, dist * 0.52, dist * 0.86)
	;(cam :: Camera).CFrame = CFrame.lookAt(camPos, Vector3.zero)
end

-- === ESCALADO RESPONSIVE (PC / TABLET / MÓVIL) ===
local function updateResponsiveLayout()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local vpSize = cam.ViewportSize
	if vpSize.X <= 0 or vpSize.Y <= 0 then
		return
	end

	if vpSize.X < 740 or vpSize.Y < 460 then
		local scale = math.clamp(math.min(vpSize.X / 840, vpSize.Y / 500), 0.58, 0.86)
		responsiveScale.Scale = scale
		catalogGridLayout.CellSize = UDim2.fromOffset(170, 248)
	elseif vpSize.X < 1040 then
		local scale = math.clamp(math.min(vpSize.X / 980, vpSize.Y / 600), 0.78, 0.96)
		responsiveScale.Scale = scale
		catalogGridLayout.CellSize = UDim2.fromOffset(180, 252)
	else
		responsiveScale.Scale = 1.0
		catalogGridLayout.CellSize = UDim2.fromOffset(188, 256)
	end
end

if Workspace.CurrentCamera then
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveLayout)
end
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if Workspace.CurrentCamera then
		Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveLayout)
		updateResponsiveLayout()
	end
end)
updateResponsiveLayout()

-- === VENTANA DE DETALLES DE COMPONENTE (`ItemDetailsModal`) ===
local function openItemDetailsModal(itemId: string)
	local details = ShopStatsResolver.ResolveItemDetails(itemId)
	if not details then
		return
	end
	_openItemDetailsId = itemId
	lootBoxModal.Visible = false

	itemModalTitle.Text = details.DisplayName
	itemModalCategory.Text = `Categoría: {details.CategoryDisplayName}`
	itemModalDesc.Text = details.Description

	if details.DirectPurchasable and type(details.Price) == "number" then
		local sellStr = if type(details.SellPrice) == "number" then ` · Venta: {formatMoney(details.SellPrice)}` else ""
		itemModalPriceBadge.Text = `Compra: {formatMoney(details.Price)}{sellStr}`
	else
		itemModalPriceBadge.Text = "Obtenible mediante Caja Especial"
	end

	local ownedQty = 0
	for _, it in ipairs(ShopController.NormalItems) do
		if it.ItemId == itemId then
			ownedQty = it.OwnedQuantity or 0
			break
		end
	end
	itemModalOwnedBadge.Text = `En tu inventario: {ownedQty} unidades`

	populateViewportPreview(itemModalViewport, details.AssetFolder, details.ModelName, false)

	for _, ch in ipairs(statsScroll:GetChildren()) do
		if ch:IsA("Frame") and ch ~= statRowTemplate then
			ch:Destroy()
		end
	end

	for idx, rowData in ipairs(details.StatsRows) do
		local row = statRowTemplate:Clone()
		row.Name = `StatRow_{idx}`
		row.LayoutOrder = idx
		row.Visible = true
		local nameLbl = row:FindFirstChild("StatNameLabel") :: TextLabel?
		local valLbl = row:FindFirstChild("StatValueLabel") :: TextLabel?
		if nameLbl then
			nameLbl.Text = rowData.Name
		end
		if valLbl then
			valLbl.Text = rowData.Value
		end
		row.Parent = statsScroll
	end

	statsScroll.CanvasPosition = Vector2.zero
	itemDetailsModal.Visible = true
end

-- === VENTANA DE DETALLES DE CAJA ESPECIAL (`LootBoxDetailsModal`) ===
local function getSpecialBoxLiveRecord(boxId: string): any?
	for _, b in ipairs(ShopController.SpecialBoxes) do
		if b.BoxId == boxId then
			return b
		end
	end
	return nil
end

local function refreshOpenLootBoxModalDynamicFields()
	if not lootBoxModal.Visible or not _openLootBoxId then
		return
	end
	local boxDetails = ShopStatsResolver.ResolveLootBoxDetails(_openLootBoxId)
	if not boxDetails then
		return
	end

	local liveBox = getSpecialBoxLiveRecord(_openLootBoxId)
	local stock = if liveBox and type(liveBox.Stock) == "number" then liveBox.Stock else 0
	local maxStock = if liveBox and type(liveBox.RestockMax) == "number" then liveBox.RestockMax else boxDetails.RestockMax
	local now = ShopController.GetEstimatedServerNow()
	local boxNextRestock = if liveBox and type(liveBox.NextRestockAt) == "number" and liveBox.NextRestockAt > 0
		then liveBox.NextRestockAt
		else ShopController.NextRestockAt
	local restockRem = math.max(0, boxNextRestock - now)

	if not boxDetails.Enabled then
		boxModalStockLbl.Text = boxDetails.DisabledReason or "Próximamente"
		boxModalStockLbl.TextColor3 = Color3.fromRGB(240, 128, 120)
	else
		boxModalStockLbl.Text = `Stock servidor: {stock}/{maxStock} · Restock en: {formatMMSS(restockRem)}`
		boxModalStockLbl.TextColor3 = if stock > 0
			then Color3.fromRGB(135, 240, 170)
			else Color3.fromRGB(240, 128, 120)
	end

	local canBuy = boxDetails.Enabled
		and not ShopController.IsBusy
		and stock > 0
		and type(boxDetails.Price) == "number"
		and ShopController.Balance >= (boxDetails.Price :: number)

	boxModalBuyBtn.Active = canBuy
	boxModalBuyBtn.AutoButtonColor = canBuy
	if not boxDetails.Enabled then
		boxModalBuyBtn.Text = "Próximamente"
		boxModalBuyBtn.BackgroundColor3 = Color3.fromRGB(64, 70, 84)
		boxModalBuyBtn.TextColor3 = Color3.fromRGB(205, 214, 230)
	elseif stock <= 0 then
		boxModalBuyBtn.Text = "Sin stock"
		boxModalBuyBtn.BackgroundColor3 = Color3.fromRGB(64, 70, 84)
		boxModalBuyBtn.TextColor3 = Color3.fromRGB(205, 214, 230)
	else
		boxModalBuyBtn.Text = `Comprar ({formatMoney(boxDetails.Price)})`
		boxModalBuyBtn.BackgroundColor3 = if canBuy
			then Color3.fromRGB(242, 186, 42)
			else Color3.fromRGB(84, 90, 106)
		boxModalBuyBtn.TextColor3 = if canBuy
			then Color3.fromRGB(18, 22, 30)
			else Color3.fromRGB(215, 222, 236)
	end
end

local function openLootBoxDetailsModal(boxId: string)
	local boxDetails = ShopStatsResolver.ResolveLootBoxDetails(boxId)
	local boxDef = LootBoxConfig.GetBox(boxId)
	if not boxDetails or not boxDef then
		return
	end
	_openLootBoxId = boxId
	itemDetailsModal.Visible = false

	applyFamilyIconToBadge(boxModalFamilyBadge, boxDef.RewardCategory)
	local famSpec = LootBoxConfig.GetFamilySpec(boxDef.RewardCategory)

	boxModalTitle.Text = boxDetails.DisplayName
	boxModalCategory.Text = `{famSpec.Glyph} Familia: {famSpec.DisplayName} ({famSpec.FilterLabel})`
	boxModalDesc.Text = boxDetails.Description
	boxModalPriceLbl.Text = if type(boxDetails.Price) == "number"
		then `Precio: {formatMoney(boxDetails.Price)}`
		else "Precio: Por definir (TBD)"
	boxModalDeliveryLbl.Text = `Tiempo de entrega: {LootBoxConfig.FormatDeliveryTime(boxDetails.DeliveryTimeSeconds, false)}`
	rewardsSummaryLbl.Text = boxDetails.SummaryText

	populateViewportPreview(boxModalViewport, boxDetails.AssetSubfolder, boxDetails.ModelName, true)

	for _, ch in ipairs(rewardsScroll:GetChildren()) do
		if ch:IsA("Frame") and ch ~= rewardRowTemplate then
			ch:Destroy()
		end
	end

	for idx, reward in ipairs(boxDetails.PossibleRewards) do
		local row = rewardRowTemplate:Clone()
		row.Name = `RewardRow_{reward.TierId}`
		row.LayoutOrder = idx
		row.Visible = true

		local rarBadge = row:FindFirstChild("RarityBadge") :: TextLabel?
		local nameLbl = row:FindFirstChild("RewardNameLabel") :: TextLabel?
		local probLbl = row:FindFirstChild("ProbabilityLabel") :: TextLabel?
		local bonusLbl = row:FindFirstChild("BonusesLabel") :: TextLabel?
		local stroke = row:FindFirstChildOfClass("UIStroke")

		local rarColor = parseHexColor(reward.RarityColorHex)
		if rarBadge then
			rarBadge.Text = string.upper(reward.RarityDisplayName)
			rarBadge.TextColor3 = rarColor
		end
		if stroke then
			stroke.Color = rarColor
		end
		if nameLbl then
			nameLbl.Text = reward.RewardName
		end
		if probLbl then
			probLbl.Text = reward.ProbabilityLabel
		end
		if bonusLbl then
			bonusLbl.Text = reward.BonusesSummary
		end

		row.Parent = rewardsScroll
	end

	rewardsScroll.CanvasPosition = Vector2.zero
	refreshOpenLootBoxModalDynamicFields()
	lootBoxModal.Visible = true
end

-- === PESTAÑAS DE CATEGORÍAS Y BARRA SECUNDARIA DE FILTROS DE CAJAS ===
local function buildCategoryTabButtons()
	for _, ch in ipairs(categoryTabs:GetChildren()) do
		if ch:IsA("TextButton") and ch ~= categoryBtnTemplate then
			ch:Destroy()
		end
	end
	table.clear(_categoryButtonsById)

	for idx, spec in ipairs(CATEGORY_TABS) do
		local btn = categoryBtnTemplate:Clone()
		btn.Name = `CatFilter_{spec.Label}`
		btn.LayoutOrder = idx
		btn.Text = spec.Label
		btn.Visible = true
		btn.Parent = categoryTabs
		_categoryButtonsById[spec.Id] = btn

		btn.Activated:Connect(function()
			if _selectedCategoryId ~= spec.Id then
				_selectedCategoryId = spec.Id
				catalogScroll.CanvasPosition = Vector2.zero
				refreshAllUi()
			end
		end)
	end
end

local function updateCategoryAndFilterStyles()
	for _, spec in ipairs(CATEGORY_TABS) do
		local btn = _categoryButtonsById[spec.Id]
		if btn then
			local isSelected = (_selectedCategoryId == spec.Id)
			btn.BackgroundColor3 = if isSelected
				then Color3.fromRGB(242, 186, 42)
				else Color3.fromRGB(30, 38, 54)
			btn.TextColor3 = if isSelected
				then Color3.fromRGB(18, 22, 30)
				else Color3.fromRGB(232, 238, 250)
			local stroke = btn:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = if isSelected
					then Color3.fromRGB(255, 224, 112)
					else Color3.fromRGB(64, 82, 114)
			end
		end
	end

	local showCrateBar = (_selectedCategoryId == "Crates")
	crateFamilyFilterBar.Visible = showCrateBar
	if showCrateBar then
		statusBanner.Position = UDim2.fromOffset(16, 130)
		catalogScroll.Position = UDim2.fromOffset(14, 152)
		catalogScroll.Size = UDim2.new(1, -284, 1, -166)
		cartPanel.Position = UDim2.new(1, -262, 0, 152)
		cartPanel.Size = UDim2.new(0, 248, 1, -166)
	else
		statusBanner.Position = UDim2.fromOffset(16, 94)
		catalogScroll.Position = UDim2.fromOffset(14, 118)
		catalogScroll.Size = UDim2.new(1, -284, 1, -132)
		cartPanel.Position = UDim2.new(1, -262, 0, 118)
		cartPanel.Size = UDim2.new(0, 248, 1, -132)
	end

	for _, fSpec in ipairs(CRATE_FAMILY_FILTERS) do
		local isSelected = (_selectedCrateFamilyFilter == fSpec.Id)
		fSpec.Button.BackgroundColor3 = if isSelected
			then Color3.fromRGB(242, 186, 42)
			else Color3.fromRGB(30, 38, 54)
		fSpec.Button.TextColor3 = if isSelected
			then Color3.fromRGB(18, 22, 30)
			else Color3.fromRGB(232, 238, 250)
		local stroke = fSpec.Button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if isSelected
				then Color3.fromRGB(255, 224, 112)
				else Color3.fromRGB(64, 82, 114)
		end
	end
end

for _, fSpec in ipairs(CRATE_FAMILY_FILTERS) do
	fSpec.Button.Activated:Connect(function()
		if _selectedCrateFamilyFilter ~= fSpec.Id then
			_selectedCrateFamilyFilter = fSpec.Id
			catalogScroll.CanvasPosition = Vector2.zero
			refreshAllUi()
		end
	end)
end

buildCategoryTabButtons()

-- === CARRITO DE COMPRAS (`CartPanel`) ===
local function rebuildCart()
	for _, ch in ipairs(cartItemsScroll:GetChildren()) do
		if ch:IsA("Frame") and ch ~= cartItemTemplate then
			ch:Destroy()
		end
	end

	local summary = ShopController.GetCartSummary()
	emptyCartLbl.Visible = (#summary.Lines == 0)

	for idx, line in ipairs(summary.Lines) do
		local row = cartItemTemplate:Clone()
		row.Name = `CartLine_{line.ItemId}`
		row.LayoutOrder = idx + 1
		row.Visible = true

		local titleLbl = row:FindFirstChild("Title") :: TextLabel?
		local subLbl = row:FindFirstChild("SubTotal") :: TextLabel?
		local remBtn = row:FindFirstChild("RemoveBtn") :: TextButton?
		local delBtn = row:FindFirstChild("DelBtn") :: TextButton?

		if titleLbl then
			titleLbl.Text = `{line.Quantity}x {line.DisplayName}`
		end
		if subLbl then
			subLbl.Text = `{formatMoney(line.LineTotal)} (1 caja)`
		end
		if remBtn then
			remBtn.Activated:Connect(function()
				ShopController.AddToCart(line.ItemId, -1)
			end)
		end
		if delBtn then
			delBtn.Activated:Connect(function()
				ShopController.SetCartQuantity(line.ItemId, 0)
			end)
		end

		row.Parent = cartItemsScroll
	end

	local orders = ShopController.Orders
	local blockedNormal = orders and orders.NormalOrderBlocked == true
	local remNormal = if orders then (orders.NormalOrderRemainingSeconds or 0) else 0
	if blockedNormal then
		cartWaitNoteLbl.Text = `Pedido normal en tránsito ({formatMMSS(remNormal)}). Se desbloquea al llegar.`
		cartWaitNoteLbl.TextColor3 = Color3.fromRGB(248, 198, 112)
	else
		cartWaitNoteLbl.Text = "Entrega normal: 60 s · 1 caja física por cada tipo de componente."
		cartWaitNoteLbl.TextColor3 = Color3.fromRGB(178, 210, 232)
	end

	cartTotalLbl.Text = `Total: {formatMoney(summary.TotalCost)} ({summary.CrateCount} cajas)`
	local canCheckout = (not ShopController.IsBusy)
		and (#summary.Lines > 0)
		and (not blockedNormal)
		and (ShopController.Balance >= summary.TotalCost)
	checkoutCartBtn.Active = canCheckout
	checkoutCartBtn.AutoButtonColor = canCheckout
	checkoutCartBtn.BackgroundColor3 = if canCheckout
		then Color3.fromRGB(242, 186, 42)
		else Color3.fromRGB(64, 72, 86)
	checkoutCartBtn.TextColor3 = if canCheckout
		then Color3.fromRGB(18, 22, 30)
		else Color3.fromRGB(190, 198, 214)
end

-- === RENDERIZADO Y ACTUALIZACIÓN DEL CATÁLOGO PRINCIPAL (`CatalogScroll`) ===
local function getNormalItemLiveRecord(itemId: string): any?
	for _, it in ipairs(ShopController.NormalItems) do
		if it.ItemId == itemId then
			return it
		end
	end
	return nil
end

local function getSelectedCrateQuantity(boxId: string, maxStock: number): number
	local raw = _selectedCrateQtyByBoxId[boxId] or 1
	if maxStock <= 0 then
		return 1
	end
	return math.clamp(math.floor(raw), 1, maxStock)
end

local function updateCardLiveState(record: { Card: Frame, Kind: "Normal" | "SpecialBox", TargetId: string })
	local card = record.Card
	local deliveryLbl = card:FindFirstChild("DeliveryTimeLabel") :: TextLabel?
	local ownedStockLbl = card:FindFirstChild("OwnedStockLabel") :: TextLabel?
	local priceRow = card:FindFirstChild("PriceRow") :: Frame?
	local priceLbl = priceRow and priceRow:FindFirstChild("PriceLabel") :: TextLabel?
	local qtyControls = card:FindFirstChild("QuantityControls") :: Frame?
	local buyBtn = card:FindFirstChild("BuyButton") :: TextButton?

	if record.Kind == "Normal" then
		local live = getNormalItemLiveRecord(record.TargetId)
		local entry = ItemCatalog.GetEntry(record.TargetId)
		local price = if live and type(live.Price) == "number" then live.Price elseif entry then entry.Price else 0
		local sellPrice = if live and type(live.SellPrice) == "number" then live.SellPrice elseif entry then entry.SellPrice else 0
		local owned = if live and type(live.OwnedQuantity) == "number" then live.OwnedQuantity else 0
		local inCart = ShopController.GetCartQuantity(record.TargetId)

		if deliveryLbl then
			deliveryLbl.Text = `⏱ Entrega: {ShopConfig.Orders.NormalOrderWaitSeconds} s (1 caja/tipo)`
			deliveryLbl.TextColor3 = Color3.fromRGB(148, 214, 246)
		end
		if ownedStockLbl then
			ownedStockLbl.Text = `Poseés: {owned} · Venta: {formatMoney(sellPrice)}`
			ownedStockLbl.TextColor3 = Color3.fromRGB(164, 184, 212)
		end
		if priceLbl then
			priceLbl.Text = formatMoney(price)
		end
		if qtyControls then
			qtyControls.Visible = true
			local qtyBox = qtyControls:FindFirstChild("QtyInput") :: TextBox?
			if qtyBox and not qtyBox:IsFocused() then
				qtyBox.Text = tostring(inCart)
			end
		end
		if buyBtn then
			buyBtn.Text = if inCart > 0 then `En carrito ({inCart}) · +1` else "Agregar al carrito"
			buyBtn.BackgroundColor3 = Color3.fromRGB(242, 186, 42)
			buyBtn.TextColor3 = Color3.fromRGB(18, 22, 30)
			buyBtn.Active = true
			buyBtn.AutoButtonColor = true
		end
	elseif record.Kind == "SpecialBox" then
		local boxDef = LootBoxConfig.GetBox(record.TargetId)
		local live = getSpecialBoxLiveRecord(record.TargetId)
		local enabled = if live ~= nil then (live.Enabled == true) elseif boxDef then boxDef.Enabled else false
		local stock = if live and type(live.Stock) == "number" then live.Stock else 0
		local maxStock = if live and type(live.RestockMax) == "number"
			then live.RestockMax
			elseif boxDef then boxDef.StockMax
			else 0
		local price = if live and type(live.Price) == "number" then live.Price elseif boxDef then boxDef.Price else nil
		local delSeconds = if live and type(live.DeliverySeconds) == "number"
			then live.DeliverySeconds
			else LootBoxConfig.GetDeliverySeconds(record.TargetId)
		local selectedQty = getSelectedCrateQuantity(record.TargetId, stock)

		if deliveryLbl then
			deliveryLbl.Text = `⏱ Entrega: {LootBoxConfig.FormatDeliveryTime(delSeconds, false)}`
			deliveryLbl.TextColor3 = Color3.fromRGB(246, 208, 112)
		end
		if priceLbl then
			priceLbl.Text = if type(price) == "number" then formatMoney(price) else "Por definir"
		end
		if ownedStockLbl then
			if not enabled then
				ownedStockLbl.Text = "Estado: Próximamente"
				ownedStockLbl.TextColor3 = Color3.fromRGB(240, 128, 120)
			else
				local now = ShopController.GetEstimatedServerNow()
				local nextRestock = if live and type(live.NextRestockAt) == "number" and live.NextRestockAt > 0
					then live.NextRestockAt
					else ShopController.NextRestockAt
				local rem = math.max(0, nextRestock - now)
				ownedStockLbl.Text = `Stock: {stock}/{maxStock} · Restock {formatMMSS(rem)}`
				ownedStockLbl.TextColor3 = if stock > 0
					then Color3.fromRGB(135, 240, 170)
					else Color3.fromRGB(240, 128, 120)
			end
		end
		if qtyControls then
			qtyControls.Visible = true
			local qtyBox = qtyControls:FindFirstChild("QtyInput") :: TextBox?
			local add5Btn = qtyControls:FindFirstChild("Add5Btn") :: TextButton?
			local add100Btn = qtyControls:FindFirstChild("Add100Btn") :: TextButton?
			if add5Btn then
				add5Btn.Visible = false
			end
			if add100Btn then
				add100Btn.Visible = false
			end
			if qtyBox and not qtyBox:IsFocused() then
				qtyBox.Text = tostring(if enabled and stock > 0 then selectedQty else 0)
			end
		end
		if buyBtn then
			local totalCost = if type(price) == "number" then price * selectedQty else math.huge
			local canBuy = enabled
				and (not ShopController.IsBusy)
				and stock >= selectedQty
				and stock > 0
				and type(price) == "number"
				and ShopController.Balance >= totalCost
			buyBtn.Active = canBuy
			buyBtn.AutoButtonColor = canBuy
			if not enabled then
				buyBtn.Text = "Próximamente"
				buyBtn.BackgroundColor3 = Color3.fromRGB(64, 70, 84)
				buyBtn.TextColor3 = Color3.fromRGB(205, 214, 230)
			elseif stock <= 0 then
				buyBtn.Text = "Sin stock"
				buyBtn.BackgroundColor3 = Color3.fromRGB(64, 70, 84)
				buyBtn.TextColor3 = Color3.fromRGB(205, 214, 230)
			else
				buyBtn.Text = if selectedQty > 1
					then `Comprar {selectedQty}x ({formatMoney(totalCost)})`
					else `Comprar ({formatMoney(price)})`
				buyBtn.BackgroundColor3 = if canBuy
					then Color3.fromRGB(242, 186, 42)
					else Color3.fromRGB(84, 90, 106)
				buyBtn.TextColor3 = if canBuy
					then Color3.fromRGB(18, 22, 30)
					else Color3.fromRGB(215, 222, 236)
			end
		end
	end
end

local function buildDesiredCatalogList(): { { Key: string, Kind: "Normal" | "SpecialBox", TargetId: string } }
	local out: { { Key: string, Kind: "Normal" | "SpecialBox", TargetId: string } } = {}

	if _selectedCategoryId == "Crates" then
		for _, box in ipairs(LootBoxConfig.GetBoxesByFamily(_selectedCrateFamilyFilter)) do
			table.insert(out, { Key = `Box_{box.BoxId}`, Kind = "SpecialBox", TargetId = box.BoxId })
		end
		return out
	end

	-- Componentes normales comprables directamente (filtra por ShopAvailability == "DirectShop" / DirectPurchasable == true)
	for _, entry in ipairs(ItemCatalog.GetPurchasableShopItems()) do
		if entry.DirectPurchasable and entry.ShopAvailability == "DirectShop" then
			if _selectedCategoryId == "All" or entry.Category == _selectedCategoryId then
				table.insert(out, { Key = `Item_{entry.Id}`, Kind = "Normal", TargetId = entry.Id })
			end
		end
	end

	-- En la vista superior "Todas" mostramos también todas las Cajas Especiales ordenadas por familia y ProgressionOrder
	if _selectedCategoryId == "All" then
		for _, box in ipairs(LootBoxConfig.GetAllBoxes()) do
			table.insert(out, { Key = `Box_{box.BoxId}`, Kind = "SpecialBox", TargetId = box.BoxId })
		end
	end

	return out
end

local function updateEmptyOverlayState(cardCount: number)
	if _selectedCategoryId == "Crates" and cardCount == 0 then
		local famSpec = if _selectedCrateFamilyFilter ~= "All"
			then LootBoxConfig.GetFamilySpec(_selectedCrateFamilyFilter :: LootBoxConfig.LootBoxRewardCategory)
			else nil
		if famSpec then
			emptyIconLbl.Text = famSpec.Glyph
			emptyIconLbl.TextColor3 = famSpec.AccentColor
			emptyTitleLbl.Text = `Cajas de {famSpec.DisplayName} — Próximamente`
			emptySubtitleLbl.Text = `Todavía no existen cajas configuradas para la familia '{famSpec.FilterLabel}'. Se mostrarán automáticamente aquí cuando estén habilitadas.`
		else
			emptyIconLbl.Text = "📦"
			emptyTitleLbl.Text = "Sin cajas disponibles"
			emptySubtitleLbl.Text = "No hay cajas configuradas en este filtro."
		end
		emptyCatalogOverlay.Visible = true
	else
		emptyCatalogOverlay.Visible = false
	end
end

local function renderCatalogCards()
	local desired = buildDesiredCatalogList()
	updateEmptyOverlayState(#desired)

	local sigParts = { _selectedCategoryId, _selectedCrateFamilyFilter }
	for _, d in ipairs(desired) do
		table.insert(sigParts, d.Key)
	end
	local signature = table.concat(sigParts, "|")

	if signature == _lastRenderedSignature then
		for _, rec in pairs(_activeCardsByKey) do
			updateCardLiveState(rec)
		end
		return
	end

	_lastRenderedSignature = signature
	for _, ch in ipairs(catalogScroll:GetChildren()) do
		if ch:IsA("Frame") and ch ~= itemCardTemplate then
			ch:Destroy()
		end
	end
	table.clear(_activeCardsByKey)

	for idx, spec in ipairs(desired) do
		local card = itemCardTemplate:Clone()
		card.LayoutOrder = idx
		card.Visible = true

		local famBadge = card:FindFirstChild("FamilyIconBadge") :: Frame?
		local catBadge = card:FindFirstChild("CategoryBadge") :: TextLabel?
		local infoBtn = card:FindFirstChild("InfoButton") :: TextButton?
		local prevContainer = card:FindFirstChild("PreviewContainer") :: Frame?
		local vp = prevContainer and prevContainer:FindFirstChild("PreviewViewport") :: ViewportFrame?
		local titleLbl = card:FindFirstChild("TitleLabel") :: TextLabel?
		local qtyControls = card:FindFirstChild("QuantityControls") :: Frame?
		local buyBtn = card:FindFirstChild("BuyButton") :: TextButton?
		local stroke = card:FindFirstChildOfClass("UIStroke")

		if spec.Kind == "Normal" then
			local entry = ItemCatalog.GetEntry(spec.TargetId)
			card.Name = `ShopItem_{spec.TargetId}`
			if famBadge then
				famBadge.Visible = false
			end
			if catBadge and entry then
				catBadge.Position = UDim2.fromOffset(10, 8)
				catBadge.Size = UDim2.new(1, -44, 0, 18)
				catBadge.Text = string.upper(entry.CategoryDisplayName)
				catBadge.TextColor3 = Color3.fromRGB(132, 188, 232)
			end
			if titleLbl and entry then
				titleLbl.Text = entry.DisplayName
			end
			if vp and entry then
				populateViewportPreview(vp, entry.AssetFolder, spec.TargetId, false)
			end
			if infoBtn then
				infoBtn.Activated:Connect(function()
					openItemDetailsModal(spec.TargetId)
				end)
			end
			if qtyControls then
				local minusBtn = qtyControls:FindFirstChild("MinusBtn") :: TextButton?
				local qtyBox = qtyControls:FindFirstChild("QtyInput") :: TextBox?
				local plusBtn = qtyControls:FindFirstChild("PlusBtn") :: TextButton?
				local add5Btn = qtyControls:FindFirstChild("Add5Btn") :: TextButton?
				local add100Btn = qtyControls:FindFirstChild("Add100Btn") :: TextButton?

				if add5Btn then
					add5Btn.Visible = true
				end
				if add100Btn then
					add100Btn.Visible = true
				end
				if minusBtn then
					minusBtn.Activated:Connect(function()
						ShopController.AddToCart(spec.TargetId, -1)
					end)
				end
				if plusBtn then
					plusBtn.Activated:Connect(function()
						ShopController.AddToCart(spec.TargetId, 1)
					end)
				end
				if add5Btn then
					add5Btn.Activated:Connect(function()
						ShopController.AddToCart(spec.TargetId, 5)
					end)
				end
				if add100Btn then
					add100Btn.Activated:Connect(function()
						ShopController.AddToCart(spec.TargetId, 100)
					end)
				end
				if qtyBox then
					qtyBox.FocusLost:Connect(function()
						local parsed = tonumber(qtyBox.Text)
						if parsed and parsed >= 0 then
							ShopController.SetCartQuantity(spec.TargetId, math.floor(parsed))
						else
							qtyBox.Text = tostring(ShopController.GetCartQuantity(spec.TargetId))
						end
					end)
				end
			end
			if buyBtn then
				buyBtn.Activated:Connect(function()
					ShopController.AddToCart(spec.TargetId, 1)
				end)
			end
		elseif spec.Kind == "SpecialBox" then
			local boxDef = LootBoxConfig.GetBox(spec.TargetId)
			card.Name = `SpecialBox_{spec.TargetId}`
			if boxDef then
				local famSpec = LootBoxConfig.GetFamilySpec(boxDef.RewardCategory)
				applyFamilyIconToBadge(famBadge, boxDef.RewardCategory)
				if stroke then
					stroke.Color = if boxDef.Enabled
						then famSpec.AccentColor
						else Color3.fromRGB(84, 92, 110)
				end
				if catBadge then
					catBadge.Position = UDim2.fromOffset(34, 8)
					catBadge.Size = UDim2.new(1, -68, 0, 18)
					catBadge.Text = famSpec.ShortTag
					catBadge.TextColor3 = famSpec.AccentColor
				end
				if titleLbl then
					titleLbl.Text = boxDef.DisplayName
				end
				if vp then
					populateViewportPreview(vp, boxDef.AssetSubfolder, boxDef.ModelName, true)
				end
			end
			if infoBtn then
				infoBtn.Activated:Connect(function()
					openLootBoxDetailsModal(spec.TargetId)
				end)
			end
			if qtyControls then
				local minusBtn = qtyControls:FindFirstChild("MinusBtn") :: TextButton?
				local qtyBox = qtyControls:FindFirstChild("QtyInput") :: TextBox?
				local plusBtn = qtyControls:FindFirstChild("PlusBtn") :: TextButton?

				if minusBtn then
					minusBtn.Activated:Connect(function()
						local live = getSpecialBoxLiveRecord(spec.TargetId)
						local maxS = if live and type(live.Stock) == "number" then live.Stock else 1
						local cur = getSelectedCrateQuantity(spec.TargetId, maxS)
						_selectedCrateQtyByBoxId[spec.TargetId] = math.max(1, cur - 1)
						local rec = _activeCardsByKey[spec.Key]
						if rec then
							updateCardLiveState(rec)
						end
					end)
				end
				if plusBtn then
					plusBtn.Activated:Connect(function()
						local live = getSpecialBoxLiveRecord(spec.TargetId)
						local maxS = if live and type(live.Stock) == "number" then live.Stock else 1
						local cur = getSelectedCrateQuantity(spec.TargetId, maxS)
						_selectedCrateQtyByBoxId[spec.TargetId] = math.clamp(cur + 1, 1, math.max(1, maxS))
						local rec = _activeCardsByKey[spec.Key]
						if rec then
							updateCardLiveState(rec)
						end
					end)
				end
				if qtyBox then
					qtyBox.FocusLost:Connect(function()
						local live = getSpecialBoxLiveRecord(spec.TargetId)
						local maxS = if live and type(live.Stock) == "number" then live.Stock else 1
						local parsed = tonumber(qtyBox.Text)
						if parsed and parsed >= 1 then
							_selectedCrateQtyByBoxId[spec.TargetId] = math.clamp(math.floor(parsed), 1, math.max(1, maxS))
						end
						local rec = _activeCardsByKey[spec.Key]
						if rec then
							updateCardLiveState(rec)
						end
					end)
				end
			end
			if buyBtn then
				buyBtn.Activated:Connect(function()
					if buyBtn.Active then
						local live = getSpecialBoxLiveRecord(spec.TargetId)
						local maxS = if live and type(live.Stock) == "number" then live.Stock else 1
						local qty = getSelectedCrateQuantity(spec.TargetId, maxS)
						for _ = 1, qty do
							local ok = ShopController.PurchaseSpecialCrate(spec.TargetId)
							if not ok then
								break
							end
						end
						_selectedCrateQtyByBoxId[spec.TargetId] = 1
						refreshAllUi()
					end
				end)
			end
		end

		card.Parent = catalogScroll
		local rec = {
			Card = card,
			Kind = spec.Kind,
			TargetId = spec.TargetId,
		}
		_activeCardsByKey[spec.Key] = rec
		updateCardLiveState(rec)
	end
end

-- === VENTANA DE MIS PEDIDOS (`OrdersModal`) ===
local function rebuildOrdersModal()
	for _, ch in ipairs(ordersScroll:GetChildren()) do
		if ch:IsA("Frame") and ch ~= orderRowTemplate then
			ch:Destroy()
		end
	end
	table.clear(_liveOrderCountdowns)

	local orders = ShopController.Orders
	if not orders then
		zoneSummaryLbl.Text = "Cargando estado de DeliveryZone..."
		emptyOrdersLbl.Visible = true
		return
	end

	zoneSummaryLbl.Text = `DeliveryZone compartida: {orders.SpawnedCount}/{orders.DeliveryZoneCapacity} cajas físicas visibles · En cola: {orders.QueuedCount}`

	local seq = 1
	local function addOrderCard(o: any, isSpecial: boolean)
		seq += 1
		local row = orderRowTemplate:Clone()
		row.Name = `OrderRow_{o.OrderId}`
		row.LayoutOrder = seq
		row.Visible = true

		local stroke = row:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if isSpecial
				then Color3.fromRGB(214, 162, 58)
				else Color3.fromRGB(70, 152, 136)
		end

		local titleLbl = row:FindFirstChild("OrderTitle") :: TextLabel?
		local statusLbl = row:FindFirstChild("OrderCountdown") :: TextLabel?
		local detLbl = row:FindFirstChild("OrderDetail") :: TextLabel?
		local rushBtn = row:FindFirstChild("PedirAhoraBtn") :: TextButton?
		local readyBadge = row:FindFirstChild("ReadyBadge") :: TextLabel?

		if titleLbl then
			if isSpecial then
				local delSec = o.DeliverySeconds or LootBoxConfig.GetDeliverySeconds(o.BoxId)
				titleLbl.Text = `{o.DisplayName} [Caja Especial · {LootBoxConfig.FormatDeliveryTime(delSec, true)}]`
			else
				titleLbl.Text = `Pedido Normal ({#(o.Crates or {})} cajas · 60 s)`
			end
		end

		if detLbl then
			if isSpecial then
				detLbl.Text = if o.Status == "Opened" and o.RolledReward
					then `Recompensa sorteada: {o.RolledReward.FullLabel} (reclamar en DeliveryZone)`
					else "Ve a DeliveryZone cuando llegue para abrirla por ProximityPrompt."
			else
				local parts = {}
				for _, c in ipairs(o.Crates or {}) do
					local tag = if c.Status == "Opened" then "✓" elseif c.Status == "Spawned" then "En zona" else "En cola"
					table.insert(parts, `{c.Quantity}x {c.DisplayName} [{tag}]`)
				end
				detLbl.Text = table.concat(parts, " · ")
			end
		end

		local activeRushBtn: TextButton? = nil
		if o.Status == "InTransit" then
			local prodId = if isSpecial
				then ShopController.RobuxProducts.RushSpecialOrderProductId
				else ShopController.RobuxProducts.RushNormalOrderProductId
			local prodConfigured = type(prodId) == "number" and prodId > 0
			if rushBtn then
				rushBtn.Visible = true
				rushBtn.Text = if prodConfigured then "Pedir ahora (Robux)" else "Pedir ahora (ID pendiente)"
				rushBtn.BackgroundColor3 = if prodConfigured
					then Color3.fromRGB(242, 186, 42)
					else Color3.fromRGB(64, 70, 84)
				rushBtn.TextColor3 = if prodConfigured
					then Color3.fromRGB(18, 22, 30)
					else Color3.fromRGB(205, 214, 230)
				rushBtn.Active = prodConfigured
				rushBtn.AutoButtonColor = prodConfigured
				rushBtn.Activated:Connect(function()
					ShopController.PromptRushOrder(o.OrderId)
				end)
				activeRushBtn = rushBtn
			end
			if readyBadge then
				readyBadge.Visible = false
			end
		else
			if rushBtn then
				rushBtn.Visible = false
			end
			if readyBadge then
				readyBadge.Visible = true
				readyBadge.Text = if o.Status == "Opened" then "Recompensa lista" else "Entregado en zona"
			end
		end

		row.Parent = ordersScroll
		if statusLbl then
			table.insert(_liveOrderCountdowns, {
				Label = statusLbl,
				ArriveAt = o.ReadyAt or o.ArriveAt,
				OrderType = if o.Status == "InTransit" then "InTransit" else "Arrived",
				RushBtn = activeRushBtn,
			})
		end
	end

	for _, o in ipairs(orders.NormalOrders or {}) do
		addOrderCard(o, false)
	end
	for _, o in ipairs(orders.SpecialOrders or {}) do
		addOrderCard(o, true)
	end

	emptyOrdersLbl.Visible = (seq == 1)
end

-- === VENTANA DE INGRESOS OFFLINE (`OfflineIncomeModal`) ===
local function rebuildOfflineModal()
	local off = ShopController.OfflineIncome
	local pending = if off then (off.PendingAmount or 0) else 0
	offlinePendingBtn.Visible = pending > 0
	offlinePendingBtn.Text = `Offline +{formatMoney(pending)}`

	if not off or pending <= 0 then
		offlineModal.Visible = false
		return
	end

	offAmountLbl.Text = `+{formatMoney(pending)} monedas`
	offTimeLbl.Text = `Tiempo acumulado offline: {formatMMSS(off.PendingSeconds or 0)}`

	for _, ch in ipairs(offBreakdownScroll:GetChildren()) do
		if ch:IsA("TextLabel") and ch ~= engineRowTemplate then
			ch:Destroy()
		end
	end
	for idx, row in ipairs(off.Breakdown or {}) do
		local lbl = engineRowTemplate:Clone()
		lbl.Name = `EngineRow_{idx}`
		lbl.LayoutOrder = idx
		lbl.Visible = true
		lbl.Text = `• {row.Label}: +{formatMoney(row.Earned)} ({row.HourlyRate}/h)`
		lbl.Parent = offBreakdownScroll
	end

	local mult = off.RewardedAdMultiplier or 5
	offNormalBtn.Text = `Recoger ({formatMoney(pending)})`
	offAdBtn.Text = `Recoger ×{mult} ({formatMoney(pending * mult)})`

	local adOk = ShopController.RewardedAdAvailable and (off.AdConfigured == true) and not ShopController.IsBusy
	offAdBtn.Active = adOk
	offAdBtn.AutoButtonColor = adOk
	offAdBtn.BackgroundColor3 = if adOk then Color3.fromRGB(242, 186, 42) else Color3.fromRGB(70, 74, 86)
	offAdBtn.TextColor3 = if adOk then Color3.fromRGB(18, 22, 30) else Color3.fromRGB(205, 212, 226)
	offAdStatusLbl.Text = if adOk
		then "Anuncio recompensado disponible para recoger ×5."
		else `{ShopController.RewardedAdStatusReason} — Usá el reclamo normal.`

	if ShopController.OfflineModalRequested then
		offlineModal.Visible = true
	end
end

-- === ACTUALIZACIÓN DE TEMPORIZADORES EN VIVO ===
local function updateLiveCountdowns()
	local now = ShopController.GetEstimatedServerNow()
	local restockRem = math.max(0, ShopController.NextRestockAt - now)
	restockCountdownLbl.Text = `Restock cajas: {formatMMSS(restockRem)}`

	refreshOpenLootBoxModalDynamicFields()
	for _, rec in pairs(_activeCardsByKey) do
		if rec.Kind == "SpecialBox" then
			updateCardLiveState(rec)
		end
	end

	for _, entry in ipairs(_liveOrderCountdowns) do
		if entry.OrderType == "InTransit" then
			local rem = math.max(0, entry.ArriveAt - now)
			entry.Label.Text = if rem > 0 then `Llega en {formatMMSS(rem)}` else "Llegando a DeliveryZone..."
			if entry.RushBtn then
				local prodConfigured = entry.RushBtn.Text == "Pedir ahora (Robux)"
				local active = prodConfigured and rem > ShopConfig.Orders.RobuxSpeedupArrivalSeconds
				entry.RushBtn.Active = active
			end
		else
			entry.Label.Text = "Entregado — Acercate a DeliveryZone"
			entry.Label.TextColor3 = Color3.fromRGB(135, 242, 165)
		end
	end
end

refreshAllUi = function()
	local formattedBal = formatMoney(ShopController.Balance)
	moneyBadge.Text = formattedBal
	balanceSummaryLbl.Text = formattedBal

	local activeCount = 0
	if ShopController.Orders then
		activeCount = #(ShopController.Orders.NormalOrders or {}) + #(ShopController.Orders.SpecialOrders or {})
	end
	local ordersText = `Mis Pedidos ({activeCount})`
	ordersToggleBtn.Text = ordersText
	ordersBtn.Text = ordersText

	if ShopController.OpenRequested then
		ShopController.OpenRequested = false
		mainFrame.Visible = true
	end

	if ShopController.LastError then
		statusBanner.Text = ShopController.LastError
		statusBanner.TextColor3 = Color3.fromRGB(246, 128, 128)
	elseif ShopController.LastStatus then
		statusBanner.Text = ShopController.LastStatus
		statusBanner.TextColor3 = Color3.fromRGB(142, 238, 168)
	else
		statusBanner.Text = "Explorá componentes modulares, cajas especiales por familia o consultá fichas técnicas (ⓘ)."
		statusBanner.TextColor3 = Color3.fromRGB(172, 206, 232)
	end

	updateCategoryAndFilterStyles()
	renderCatalogCards()
	rebuildCart()
	rebuildOrdersModal()
	rebuildOfflineModal()

	if itemDetailsModal.Visible and _openItemDetailsId then
		local ownedQty = 0
		for _, it in ipairs(ShopController.NormalItems) do
			if it.ItemId == _openItemDetailsId then
				ownedQty = it.OwnedQuantity or 0
				break
			end
		end
		itemModalOwnedBadge.Text = `En tu inventario: {ownedQty} unidades`
	end

	updateLiveCountdowns()
end

-- === CONEXIÓN DE EVENTOS DE BOTONES ===
shopToggleBtn.Activated:Connect(function()
	mainFrame.Visible = not mainFrame.Visible
	if mainFrame.Visible then
		ShopController.RefreshShop()
	end
end)

closeBtn.Activated:Connect(function()
	mainFrame.Visible = false
	itemDetailsModal.Visible = false
	lootBoxModal.Visible = false
end)

local function toggleOrdersModal()
	ordersModal.Visible = not ordersModal.Visible
	if ordersModal.Visible then
		ShopController.RefreshShop()
	end
end

ordersToggleBtn.Activated:Connect(toggleOrdersModal)
ordersBtn.Activated:Connect(toggleOrdersModal)

ordersModalCloseBtn.Activated:Connect(function()
	ordersModal.Visible = false
end)

itemModalCloseBtn.Activated:Connect(function()
	itemDetailsModal.Visible = false
	_openItemDetailsId = nil
end)

boxModalCloseBtn.Activated:Connect(function()
	lootBoxModal.Visible = false
	_openLootBoxId = nil
end)

boxModalBuyBtn.Activated:Connect(function()
	if boxModalBuyBtn.Active and _openLootBoxId then
		ShopController.PurchaseSpecialCrate(_openLootBoxId)
	end
end)

offlinePendingBtn.Activated:Connect(function()
	ShopController.OfflineModalRequested = true
	offlineModal.Visible = true
end)

offCloseBtn.Activated:Connect(function()
	offlineModal.Visible = false
	ShopController.DismissOfflineModal()
end)

offNormalBtn.Activated:Connect(function()
	ShopController.ClaimOfflineIncome(false)
end)

offAdBtn.Activated:Connect(function()
	if offAdBtn.Active then
		ShopController.ClaimOfflineIncome(true)
	end
end)

checkoutCartBtn.Activated:Connect(function()
	if checkoutCartBtn.Active then
		ShopController.CheckoutNormalCart()
	end
end)

clearCartBtn.Activated:Connect(function()
	ShopController.ClearCart()
end)

ShopController.Subscribe(refreshAllUi)
ShopController.SubscribeVisualCue(function(eventType: string, payload: { [string]: any })
	if eventType == ShopProtocol.SyncEventTypes.DeliveryTruckArriving then
		showToast("¡Llegó el camión de reparto con tu pedido a DeliveryZone!")
	elseif eventType == ShopProtocol.SyncEventTypes.CrateOpeningEffect then
		if payload.IsSpecial and type(payload.Reward) == "table" then
			showToast(`¡Caja abierta! Obtuviste: {payload.Reward.FullLabel}`)
		else
			showToast(`¡Recogido: {payload.Quantity or 1}x {payload.DisplayName or "Objeto"}!`)
		end
	end
end)

task.spawn(function()
	while shopGui.Parent do
		updateLiveCountdowns()
		task.wait(1)
	end
end)

local actionBridge = Instance.new("BindableEvent")
actionBridge.Name = "UiActionBridge"
actionBridge.Event:Connect(function(action: string, arg1: any, arg2: any)
	if action == "OpenShop" then
		mainFrame.Visible = true
		refreshAllUi()
	elseif action == "CloseShop" then
		mainFrame.Visible = false
		itemDetailsModal.Visible = false
		lootBoxModal.Visible = false
	elseif action == "SelectCategory" then
		local cat = tostring(arg1 or "All")
		if cat == "Engines" or cat == "Boosters" or cat == "AircraftEngines" then
			_selectedCategoryId = "Crates"
			_selectedCrateFamilyFilter = cat :: LootBoxConfig.CrateFamilyFilter
		else
			_selectedCategoryId = cat
		end
		catalogScroll.CanvasPosition = Vector2.zero
		refreshAllUi()
	elseif action == "SelectCrateFamilyFilter" then
		_selectedCategoryId = "Crates"
		_selectedCrateFamilyFilter = tostring(arg1 or "All") :: LootBoxConfig.CrateFamilyFilter
		catalogScroll.CanvasPosition = Vector2.zero
		refreshAllUi()
	elseif action == "OpenItemDetails" then
		openItemDetailsModal(tostring(arg1))
	elseif action == "CloseItemDetails" then
		itemDetailsModal.Visible = false
		_openItemDetailsId = nil
	elseif action == "OpenLootBoxDetails" then
		openLootBoxDetailsModal(tostring(arg1))
	elseif action == "CloseLootBoxDetails" then
		lootBoxModal.Visible = false
		_openLootBoxId = nil
	elseif action == "OpenOrdersModal" then
		ordersModal.Visible = true
		rebuildOrdersModal()
	elseif action == "CloseOrdersModal" then
		ordersModal.Visible = false
	elseif action == "AddToCart" then
		ShopController.AddToCart(tostring(arg1), tonumber(arg2) or 1)
		refreshAllUi()
	elseif action == "SetCartQuantity" then
		ShopController.SetCartQuantity(tostring(arg1), tonumber(arg2) or 0)
		refreshAllUi()
	elseif action == "ClearCart" then
		ShopController.ClearCart()
		refreshAllUi()
	end
end)
actionBridge.Parent = shopGui

refreshAllUi()
