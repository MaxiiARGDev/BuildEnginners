--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AerodynamicsConfig = require(ReplicatedStorage.Shared.Config.AerodynamicsConfig)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local spec = AerodynamicsConfig.Surfaces.AircraftWingRight

local definition: ItemTypes.ItemDefinition = {
	Id = spec.ItemId,
	DisplayName = spec.DisplayName,
	Description = spec.Description,
	Category = "Aerodynamics",
	AssetFolder = "Aerodinamica",
	InventoryKind = "Stackable",
	Model = spec.ItemId,
	Price = spec.Price,
	Stats = {
		Weight = spec.Weight,
		MaxDurability = spec.MaxDurability,
		ImpactResistance = spec.ImpactResistance,
		DamageMultiplier = spec.DamageMultiplier,
		WingArea = spec.WingArea,
		LiftCoefficientSlope = spec.LiftCoefficientSlope,
		ZeroAlphaLiftCoefficient = spec.ZeroAlphaLiftCoefficient,
		MaxLiftCoefficient = spec.MaxLiftCoefficient,
		BaseDragCoefficient = spec.BaseDragCoefficient,
		InducedDragFactor = spec.InducedDragFactor,
		StallAngleDeg = spec.StallAngleDeg,
		VerticalStabilizerArea = spec.VerticalStabilizerArea,
	},
	PlacementPolicy = {
		RotationMode = "Orthogonal90",
		AllowedAngleStepsDeg = { 90, 45, 15, 1 },
		AllowFreePosition = true,
		AllowFreeRotation = true,
	},
}

return definition
