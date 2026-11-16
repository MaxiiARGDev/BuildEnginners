--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local definition: ItemTypes.ItemDefinition = {
	Id = "SmallNitroTank",
	DisplayName = "Tanque de nitro",
	Description = "Tanque presurizado de RocketFuel para ampliar la autonomía de los propulsores.",
	Category = "FuelTanks",
	AssetFolder = "Tanques",
	Model = "SmallNitroTank",
	Price = 250, -- Fase 5.2 confirmado
	Stats = {
		Weight = 12,
		MaxDurability = 100,
		FuelSubtype = "Nitro",
		FuelType = "RocketFuel",
		Capacity = 28800,
	},
	Behavior = nil,
}

return definition

