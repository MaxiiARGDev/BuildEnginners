--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local definition: ItemTypes.ItemDefinition = {
	Id = "DriverSeat",
	DisplayName = "Asiento del conductor",
	Description = "Asiento principal obligatorio para conducir el vehículo (máximo 1 por vehículo).",
	Category = "Seats",
	AssetFolder = "Asientos",
	Model = "DriverSeat",
	Price = 100, -- Fase 5.2 confirmado
	Stats = {
		Weight = 8,
		MaxDurability = 300,
	},
	Restrictions = {
		MaxPurchasesPerPlayer = 1,
	},
	Behavior = "DriverSeatBehavior",
}

return definition

