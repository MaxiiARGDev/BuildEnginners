--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local definition: ItemTypes.ItemDefinition = {
	Id = "SmallBooster",
	DisplayName = "Propulsor pequeño",
	Description = "Propulsor vectorial de cohete con Nitro integrado; soporta familias, variantes y rarezas.",
	Category = "Boosters",
	AssetFolder = "Propulsores",
	InventoryKind = "UniqueUnit",
	Model = "SmallBooster",
	Price = nil, -- Precio individual TBD (docs/04-ITEM-CATALOG.md)
	Stats = {
		Weight = 12,
		MaxDurability = 130,
		DrivingBonus = 0.3, -- +0.3x
		FuelType = "RocketFuel",
		IntegratedFuel = 24000,
		BoostConsumption = 12000,
		Thrust = 12000,
		SpeedBoostMultiplier = 1, -- 1x
	},
	Behavior = "BoosterBehavior",
}

return definition

