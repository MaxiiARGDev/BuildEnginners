--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local definition: ItemTypes.ItemDefinition = {
	Id = "SmallEngine",
	DisplayName = "Motor pequeño",
	Description = "Motor modular de combustión con combustible integrado; soporta variantes y rarezas.",
	Category = "Engines",
	AssetFolder = "Motores",
	InventoryKind = "UniqueUnit",
	Model = "SmallEngine",
	Price = nil, -- Precio individual TBD (docs/04-ITEM-CATALOG.md)
	Stats = {
		Weight = 8,
		MaxDurability = 110,
		SpeedRegular = 36, -- bloques/s con regular
		Torque = 1400,
		DrivingBonus = 0.0025, -- +0.0025x
		DisconnectRate = 21.88, -- monedas/hora, semántica TBD (docs/04-ITEM-CATALOG.md)
		FuelType = "Normal",
		IntegratedFuel = 0.54,
		MaxConsumptionRegular = 0.18,
	},
	Behavior = "EngineBehavior",
}

return definition

