--!strict
--[=[
	BoosterInventoryService
	Adaptador de dominio para unidades únicas de propulsores (BoosterUnitRecord) respaldado por
	el inventario central autoritativo InventoryService (Fase 3.4 / Fase 5.1).

	Responsabilidades:
	- Mantiene la API específica de propulsores usada por VehicleBoosterService, BuildService y pruebas.
	- Delega almacenamiento, persistencia y propiedad al inventario central (InventoryService).
	- No crea muestras gratuitas en producción: EnsureControlledWorkshopUnits solo agrega
	  DevWorkshopSample cuando InventoryService.IsLegacyTestQuotaEnabled() está activo.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BoosterCatalog = require(ReplicatedStorage.Shared.Catalog.BoosterCatalog)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local InventoryService = require(ServerScriptService.Server.Services.InventoryService)

export type PlayerLike = Player | {
	UserId: number,
	Name: string,
}

export type GrantBoosterUnitParams = {
	ItemInstanceId: string?,
	ItemId: string?,
	BoosterFamilyId: ItemTypes.BoosterFamilyId?,
	BoosterSizeId: ItemTypes.BoosterSizeId?,
	VariantId: ItemTypes.BoosterVariantId?,
	RarityId: ItemTypes.BoosterRarityId?,
	SourceTag: string?,
}

export type UnitValidationResult = {
	Valid: boolean,
	ErrorCode: string?,
	ErrorMessage: string?,
	Unit: ItemTypes.BoosterUnitRecord?,
}

local BoosterInventoryService = {
	Name = "BoosterInventoryService",
}

local initialized = false
local boundLocationByUnitId: { [string]: { UserId: number, BlueprintId: string, PieceInstanceId: string } } = {}

local function extractUserId(playerOrUserId: PlayerLike | number): number
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return playerOrUserId.UserId
	elseif type(playerOrUserId) == "table" and type((playerOrUserId :: any).UserId) == "number" then
		return (playerOrUserId :: any).UserId
	end
	error("[BoosterInventoryService] Jugador o UserId inválido", 3)
end

function BoosterInventoryService.RegisterUnitForTesting(
	playerOrUserId: PlayerLike | number,
	params: GrantBoosterUnitParams?
): ItemTypes.BoosterUnitRecord
	return InventoryService.GrantBoosterUnitForTests(playerOrUserId, params)
end

BoosterInventoryService.GrantBoosterUnitForTests = BoosterInventoryService.RegisterUnitForTesting

function BoosterInventoryService.EnsureControlledWorkshopUnits(
	playerOrUserId: PlayerLike | number
): { ItemTypes.BoosterUnitRecord }
	local userId = extractUserId(playerOrUserId)
	if InventoryService.IsLegacyTestQuotaEnabled() then
		local current = InventoryService.GetPlayerBoosterUnits(userId)
		if #current == 0 then
			local presets: { GrantBoosterUnitParams } = {
				{
					ItemInstanceId = `dev_{userId}_bst_small_common_bal_1`,
					BoosterFamilyId = "StandardRocket",
					BoosterSizeId = "Small",
					VariantId = "Balanced",
					RarityId = "Common",
					SourceTag = "StarterDefault",
				},
				{
					ItemInstanceId = `dev_{userId}_bst_small_common_bal_2`,
					BoosterFamilyId = "StandardRocket",
					BoosterSizeId = "Small",
					VariantId = "Balanced",
					RarityId = "Common",
					SourceTag = "StarterDefault",
				},
				{
					ItemInstanceId = `dev_{userId}_bst_small_uncommon_ht`,
					BoosterFamilyId = "HighImpulse",
					BoosterSizeId = "Small",
					VariantId = "HighThrust",
					RarityId = "Uncommon",
					SourceTag = "DevWorkshopSample",
				},
				{
					ItemInstanceId = `dev_{userId}_bst_small_rare_eco`,
					BoosterFamilyId = "ExtendedBurn",
					BoosterSizeId = "Small",
					VariantId = "EcoBurn",
					RarityId = "Rare",
					SourceTag = "DevWorkshopSample",
				},
				{
					ItemInstanceId = `dev_{userId}_bst_med_common_bal`,
					BoosterFamilyId = "StandardRocket",
					BoosterSizeId = "Medium",
					VariantId = "Balanced",
					RarityId = "Common",
					SourceTag = "DevWorkshopSample",
				},
				{
					ItemInstanceId = `dev_{userId}_bst_med_epic_ovb`,
					BoosterFamilyId = "HighImpulse",
					BoosterSizeId = "Medium",
					VariantId = "Overboost",
					RarityId = "Epic",
					SourceTag = "DevWorkshopSample",
				},
			}
			for _, preset in ipairs(presets) do
				InventoryService.AddBoosterUnit(userId, preset)
			end
		end
	end

	return InventoryService.GetPlayerBoosterUnits(userId)
end

function BoosterInventoryService.GetUnitById(itemInstanceId: string?): ItemTypes.BoosterUnitRecord?
	local unit = InventoryService.GetUnitById(itemInstanceId)
	if not unit then
		return nil
	end
	local def = ItemRegistry.TryGet(unit.ItemId)
	if def and def.Category == "Boosters" then
		return unit :: ItemTypes.BoosterUnitRecord
	end
	return nil
end

function BoosterInventoryService.GetPlayerUnits(playerOrUserId: PlayerLike | number): { ItemTypes.BoosterUnitRecord }
	return InventoryService.GetPlayerBoosterUnits(playerOrUserId)
end

function BoosterInventoryService.ValidateUnitForBlueprintPiece(
	playerOrUserId: PlayerLike | number,
	inventoryInstanceId: string?,
	pieceInstanceId: string,
	activePieces: { [string]: VehicleTypes.BlueprintPiece }?
): UnitValidationResult
	if inventoryInstanceId == nil or inventoryInstanceId == "" then
		return {
			Valid = true,
			ErrorCode = nil,
			ErrorMessage = nil,
			Unit = nil,
		}
	end

	if type(inventoryInstanceId) ~= "string" then
		return {
			Valid = false,
			ErrorCode = BuildProtocol.ErrorCodes.InvalidBoosterInventoryUnit,
			ErrorMessage = "El identificador de unidad de propulsor debe ser un string válido.",
			Unit = nil,
		}
	end

	local userId = extractUserId(playerOrUserId)
	local unit = BoosterInventoryService.GetUnitById(inventoryInstanceId)
	if not unit then
		return {
			Valid = false,
			ErrorCode = BuildProtocol.ErrorCodes.UnknownBoosterUnit,
			ErrorMessage = `La unidad de propulsor '{inventoryInstanceId}' no existe en el registro del servidor.`,
			Unit = nil,
		}
	end

	if unit.OwnerUserId ~= userId then
		return {
			Valid = false,
			ErrorCode = BuildProtocol.ErrorCodes.UnauthorizedBoosterUnit,
			ErrorMessage = "No puedes usar un propulsor que pertenece a otro jugador.",
			Unit = nil,
		}
	end

	if activePieces then
		for otherPieceId, otherPiece in pairs(activePieces) do
			if otherPieceId ~= pieceInstanceId and otherPiece.InventoryInstanceId == inventoryInstanceId then
				return {
					Valid = false,
					ErrorCode = BuildProtocol.ErrorCodes.DuplicateBoosterUnitInBlueprint,
					ErrorMessage = `La unidad de propulsor '{inventoryInstanceId}' ya está instalada en otra pieza ({otherPieceId}).`,
					Unit = nil,
				}
			end
		end
	end

	return {
		Valid = true,
		ErrorCode = nil,
		ErrorMessage = nil,
		Unit = unit,
	}
end

function BoosterInventoryService.BindUnitToPiece(
	playerOrUserId: PlayerLike | number,
	blueprintId: string,
	pieceInstanceId: string,
	inventoryInstanceId: string?
)
	if type(inventoryInstanceId) ~= "string" or #inventoryInstanceId == 0 then
		return
	end
	local userId = extractUserId(playerOrUserId)
	local unit = BoosterInventoryService.GetUnitById(inventoryInstanceId)
	if unit and unit.OwnerUserId == userId then
		boundLocationByUnitId[inventoryInstanceId] = {
			UserId = userId,
			BlueprintId = blueprintId,
			PieceInstanceId = pieceInstanceId,
		}
	end
end

function BoosterInventoryService.UnbindUnitFromPiece(pieceInstanceId: string, inventoryInstanceId: string?)
	if type(inventoryInstanceId) == "string" and #inventoryInstanceId > 0 then
		local bound = boundLocationByUnitId[inventoryInstanceId]
		if bound and bound.PieceInstanceId == pieceInstanceId then
			boundLocationByUnitId[inventoryInstanceId] = nil
		end
	end
end

function BoosterInventoryService.ResolvePieceEffectiveStats(
	ownerUserId: number?,
	pieceOrState: {
		ItemId: string,
		InventoryInstanceId: string?,
		Config: { [string]: any }?,
	}
): (ItemTypes.EffectiveBoosterStats, ItemTypes.BoosterUnitRecord?)
	local invId = pieceOrState.InventoryInstanceId
	if type(invId) == "string" and #invId > 0 then
		local unit = BoosterInventoryService.GetUnitById(invId)
		if unit and (ownerUserId == nil or unit.OwnerUserId == ownerUserId) then
			return unit.EffectiveStats, unit
		end
	end

	local bstCfg = if type(pieceOrState.Config) == "table" and type(pieceOrState.Config.Booster) == "table"
		then pieceOrState.Config.Booster
		else nil

	local stats = BoosterCatalog.ResolveEffectiveStats({
		ItemId = pieceOrState.ItemId,
		BoosterFamilyId = if bstCfg then bstCfg.BoosterFamilyId else nil,
		BoosterSizeId = if bstCfg then bstCfg.BoosterSizeId else nil,
		VariantId = if bstCfg then bstCfg.VariantId else nil,
		RarityId = if bstCfg then bstCfg.RarityId else nil,
	})
	return stats, nil
end

function BoosterInventoryService.BuildAuthoritativeBoosterConfig(
	stats: ItemTypes.EffectiveBoosterStats,
	existingBoosterCfg: { [string]: any }?
): VehicleTypes.BoosterPieceConfig
	local thrustLimit = GameConfig.Boosters.DefaultThrustLimitRatio
	local curveMode: "Instant" | "Smooth" | "Sustained" = "Smooth"
	local enabled = true

	if type(existingBoosterCfg) == "table" then
		if type(existingBoosterCfg.ThrustLimitRatio) == "number" then
			thrustLimit = math.clamp(
				existingBoosterCfg.ThrustLimitRatio,
				GameConfig.Boosters.MinThrustLimitRatio,
				GameConfig.Boosters.MaxThrustLimitRatio
			)
		end
		if
			existingBoosterCfg.ThrottleCurveMode == "Instant"
			or existingBoosterCfg.ThrottleCurveMode == "Smooth"
			or existingBoosterCfg.ThrottleCurveMode == "Sustained"
		then
			curveMode = existingBoosterCfg.ThrottleCurveMode
		end
		if type(existingBoosterCfg.Enabled) == "boolean" then
			enabled = existingBoosterCfg.Enabled
		end
	end

	return table.freeze({
		BoosterFamilyId = stats.BoosterFamilyId,
		BoosterSizeId = stats.BoosterSizeId,
		VariantId = stats.VariantId,
		RarityId = stats.RarityId,
		ThrustLimitRatio = thrustLimit,
		ThrottleCurveMode = curveMode,
		Enabled = enabled,
	})
end

function BoosterInventoryService.ClearForPlayer(playerOrUserId: PlayerLike | number)
	local userId = extractUserId(playerOrUserId)
	for id, bound in pairs(boundLocationByUnitId) do
		if bound.UserId == userId then
			boundLocationByUnitId[id] = nil
		end
	end
end

function BoosterInventoryService.ResetAllForTests()
	table.clear(boundLocationByUnitId)
	InventoryService._ClearAllUnitsPreservingModeForTests()
end

function BoosterInventoryService.Init()
	if initialized then
		return
	end
	initialized = true
	InventoryService.Init()

	Players.PlayerRemoving:Connect(function(player)
		BoosterInventoryService.ClearForPlayer(player.UserId)
	end)
end

return table.freeze(BoosterInventoryService)
