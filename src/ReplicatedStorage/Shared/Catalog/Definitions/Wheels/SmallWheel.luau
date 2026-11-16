--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local definition: ItemTypes.ItemDefinition = {
	Id = "SmallWheel",
	DisplayName = "Rueda pequeña",
	Description = "Rueda compacta compatible con suspensión, dirección y tracción.",
	Category = "Wheels",
	AssetFolder = "Ruedas",
	Model = "SmallWheel",
	Price = 25,
	Stats = {
		Weight = 4,
		MaxDurability = 32,
		Eq = 0.6, -- Significado exacto TBD (docs/04-ITEM-CATALOG.md)
		Grip = 1.1,
	},
	Behavior = nil,
}

return definition

