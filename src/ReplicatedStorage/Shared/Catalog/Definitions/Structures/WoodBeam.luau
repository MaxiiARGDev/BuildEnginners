--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local definition: ItemTypes.ItemDefinition = {
	Id = "WoodBeam",
	DisplayName = "Viga de madera",
	Description = "Viga alargada y liviana para unir ejes, defensas o extensiones.",
	Category = "Structures",
	AssetFolder = "Bloques",
	Model = "WoodBeam",
	Price = 8,
	Stats = {
		Weight = 1.8,
		MaxDurability = 70,
	},
	Behavior = nil,
}

return definition

