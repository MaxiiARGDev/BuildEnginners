--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local definition: ItemTypes.ItemDefinition = {
	Id = "WoodBlock",
	DisplayName = "Bloque de madera",
	Description = "Bloque estructural versátil para armar el chasis del vehículo.",
	Category = "Structures",
	AssetFolder = "Bloques",
	Model = "WoodBlock",
	Price = 10,
	Stats = {
		Weight = 5,
		MaxDurability = 75,
	},
	Behavior = nil,
}

return definition

