--!strict
--[=[
	EngineInventoryService
	Adaptador de dominio para unidades únicas de motores (EngineUnitRecord) respaldado por
	el inventario central autoritativo InventoryService (Fase 3.3 / Fase 5.1).

	Responsabilidades:
	- Mantiene la API específica de motores usada por VehiclePowertrainService, BuildService y pruebas.
	- Delega almacenamiento, persistencia y propiedad al inventario central (InventoryService).
	- No crea kits de prueba gratuitos en producción: EnsureControlledWorkshopUnits solo inyecta
	  muestras DevWorkshopSample cuando InventoryService.IsLegacyTestQuotaEnabled() está activo.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local EngineCatalog = require(ReplicatedStorage.Shared.Catalog.EngineCatalog)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local InventoryService = require(ServerScriptService.Server.Services.InventoryService)

export type PlayerLike = Player | {
	UserId: number,
	Name: string,
}

export type GrantEngineUnitParams = {
	ItemInstanceId: string?,
	ItemId: string?,
	EngineFamilyId: ItemTypes.EngineFamilyId?,
	EngineSizeId: ItemTypes.EngineSizeId?,
	VariantId: ItemTypes.EngineVariantId?,
	RarityId: ItemTypes.EngineRarityId?,
	SourceTag: string?,
}

export type UnitValidationResult = {
	Valid: boolean,
	ErrorCode: string?,
	ErrorMessage: string?,
	Unit: ItemTypes.EngineUnitRecord?,
}

local EngineInventoryService = {
	Name = "EngineInventoryService",
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
	error("[EngineInventoryService] Jugador o UserId inválido", 3)
end

function EngineInventoryService.RegisterUnitForTesting(
	playerOrUserId: PlayerLike | number,
	params: GrantEngineUnitParams?
): ItemTypes.EngineUnitRecord
	return InventoryService.GrantEngineUnitForTests(playerOrUserId, params)
end

function EngineInventoryService.EnsureControlledWorkshopUnits(
	playerOrUserId: PlayerLike | number
): { ItemTypes.EngineUnitRecord }
	local userId = extractUserId(playerOrUserId)
	if InventoryService.IsLegacyTestQuotaEnabled() then
		local current = InventoryService.GetPlayerEngineUnits(userId)
		if #current == 0 then
			local presets: { GrantEngineUnitParams } = {
				{
					ItemInstanceId = `dev_{userId}_small_common_bal_1`,
					EngineSizeId = "Small",
					VariantId = "Balanced",
					RarityId = "Common",
					SourceTag = "StarterDefault",
				},
				{
					ItemInstanceId = `dev_{userId}_small_common_bal_2`,
					EngineSizeId = "Small",
					VariantId = "Balanced",
					RarityId = "Common",
					SourceTag = "StarterDefault",
				},
				{
					ItemInstanceId = `dev_{userId}_small_uncommon_htq`,
					EngineSizeId = "Small",
					VariantId = "HighTorque",
					RarityId = "Uncommon",
					SourceTag = "DevWorkshopSample",
				},
				{
					ItemInstanceId = `dev_{userId}_small_rare_hrev`,
					EngineSizeId = "Small",
					VariantId = "HighRev",
					RarityId = "Rare",
					SourceTag = "DevWorkshopSample",
				},
				{
					ItemInstanceId = `dev_{userId}_med_common_bal`,
					EngineSizeId = "Medium",
					VariantId = "Balanced",
					RarityId = "Common",
					SourceTag = "DevWorkshopSample",
				},
				{
					ItemInstanceId = `dev_{userId}_med_epic_ovd`,
					EngineSizeId = "Medium",
					VariantId = "Overdrive",
					RarityId = "Epic",
					SourceTag = "DevWorkshopSample",
				},
			}
			for _, preset in ipairs(presets) do
				InventoryService.AddEngineUnit(userId, preset)
			end
		end
	end

	return InventoryService.GetPlayerEngineUnits(userId)
end

function EngineInventoryService.GetUnitById(itemInstanceId: string?): ItemTypes.EngineUnitRecord?
	local unit = InventoryService.GetUnitById(itemInstanceId)
	if not unit then
		return nil
	end
	local def = ItemRegistry.TryGet(unit.ItemId)
	if def and def.Category == "Engines" then
		return unit :: ItemTypes.EngineUnitRecord
	end
	return nil
end

function EngineInventoryService.GetPlayerUnits(playerOrUserId: PlayerLike | number): { ItemTypes.EngineUnitRecord }
	return InventoryService.GetPlayerEngineUnits(playerOrUserId)
end

function EngineInventoryService.ValidateUnitForBlueprintPiece(
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
			ErrorCode = "InvalidEngineUnitId",
			ErrorMessage = "El identificador de unidad de motor debe ser un string válido.",
			Unit = nil,
		}
	end

	local userId = extractUserId(playerOrUserId)
	local unit = EngineInventoryService.GetUnitById(inventoryInstanceId)
	if not unit then
		return {
			Valid = false,
			ErrorCode = BuildProtocol.ErrorCodes.UnknownEngineUnit,
			ErrorMessage = `La unidad de motor '{inventoryInstanceId}' no existe en el registro del servidor.`,
			Unit = nil,
		}
	end

	if unit.OwnerUserId ~= userId then
		return {
			Valid = false,
			ErrorCode = BuildProtocol.ErrorCodes.UnauthorizedEngineUnit,
			ErrorMessage = "No puedes usar una unidad de motor que pertenece a otro jugador.",
			Unit = nil,
		}
	end

	if activePieces then
		for otherPieceId, otherPiece in pairs(activePieces) do
			if otherPieceId ~= pieceInstanceId and otherPiece.InventoryInstanceId == inventoryInstanceId then
				return {
					Valid = false,
					ErrorCode = BuildProtocol.ErrorCodes.DuplicateEngineUnitInBlueprint,
					ErrorMessage = `La unidad de motor '{inventoryInstanceId}' ya está instalada en otra pieza del vehículo ({otherPieceId}).`,
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

function EngineInventoryService.BindUnitToPiece(
	playerOrUserId: PlayerLike | number,
	blueprintId: string,
	pieceInstanceId: string,
	inventoryInstanceId: string?
)
	if type(inventoryInstanceId) ~= "string" or #inventoryInstanceId == 0 then
		return
	end
	local userId = extractUserId(playerOrUserId)
	local unit = EngineInventoryService.GetUnitById(inventoryInstanceId)
	if unit and unit.OwnerUserId == userId then
		boundLocationByUnitId[inventoryInstanceId] = {
			UserId = userId,
			BlueprintId = blueprintId,
			PieceInstanceId = pieceInstanceId,
		}
	end
end

function EngineInventoryService.UnbindUnitFromPiece(pieceInstanceId: string, inventoryInstanceId: string?)
	if type(inventoryInstanceId) == "string" and #inventoryInstanceId > 0 then
		local bound = boundLocationByUnitId[inventoryInstanceId]
		if bound and bound.PieceInstanceId == pieceInstanceId then
			boundLocationByUnitId[inventoryInstanceId] = nil
		end
	end
end

function EngineInventoryService.ResolvePieceEffectiveStats(
	ownerUserId: number?,
	pieceOrState: {
		ItemId: string,
		InventoryInstanceId: string?,
		Config: { [string]: any }?,
	}
): (ItemTypes.EffectiveEngineStats, ItemTypes.EngineUnitRecord?)
	local invId = pieceOrState.InventoryInstanceId
	if type(invId) == "string" and #invId > 0 then
		local unit = EngineInventoryService.GetUnitById(invId)
		if unit and (ownerUserId == nil or unit.OwnerUserId == ownerUserId) then
			return unit.EffectiveStats, unit
		end
	end

	local engCfg = if type(pieceOrState.Config) == "table" and type(pieceOrState.Config.Engine) == "table"
		then pieceOrState.Config.Engine
		else nil

	local stats = EngineCatalog.ResolveEffectiveStats({
		ItemId = pieceOrState.ItemId,
		EngineFamilyId = if engCfg then engCfg.EngineFamilyId else nil,
		EngineSizeId = if engCfg then engCfg.EngineSizeId else nil,
		VariantId = if engCfg then engCfg.VariantId else nil,
		RarityId = if engCfg then engCfg.RarityId else nil,
	})
	return stats, nil
end

function EngineInventoryService.BuildAuthoritativeEngineConfig(
	stats: ItemTypes.EffectiveEngineStats,
	existingEngineCfg: { [string]: any }?
): VehicleTypes.EnginePieceConfig
	local powerLimit = 1.0
	local responseMode: "Smooth" | "Balanced" | "Sport" = "Balanced"
	local enabled = true

	if type(existingEngineCfg) == "table" then
		if type(existingEngineCfg.PowerLimitRatio) == "number" then
			powerLimit = math.clamp(existingEngineCfg.PowerLimitRatio, 0.25, 1.0)
		end
		if
			existingEngineCfg.ThrottleResponseMode == "Smooth"
			or existingEngineCfg.ThrottleResponseMode == "Balanced"
			or existingEngineCfg.ThrottleResponseMode == "Sport"
		then
			responseMode = existingEngineCfg.ThrottleResponseMode
		end
		if type(existingEngineCfg.Enabled) == "boolean" then
			enabled = existingEngineCfg.Enabled
		end
	end

	return table.freeze({
		EngineFamilyId = stats.EngineFamilyId,
		EngineSizeId = stats.EngineSizeId,
		VariantId = stats.VariantId,
		RarityId = stats.RarityId,
		PowerLimitRatio = powerLimit,
		ThrottleResponseMode = responseMode,
		Enabled = enabled,
	})
end

function EngineInventoryService.ClearForPlayer(playerOrUserId: PlayerLike | number)
	local userId = extractUserId(playerOrUserId)
	for id, bound in pairs(boundLocationByUnitId) do
		if bound.UserId == userId then
			boundLocationByUnitId[id] = nil
		end
	end
end

function EngineInventoryService.ResetAllForTests()
	table.clear(boundLocationByUnitId)
	InventoryService._ClearAllUnitsPreservingModeForTests()
end

function EngineInventoryService.Init()
	if initialized then
		return
	end
	initialized = true
	InventoryService.Init()

	Players.PlayerRemoving:Connect(function(player)
		EngineInventoryService.ClearForPlayer(player.UserId)
	end)
end

return table.freeze(EngineInventoryService)
