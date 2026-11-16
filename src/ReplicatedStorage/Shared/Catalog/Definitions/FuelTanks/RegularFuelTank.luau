--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local definition: ItemTypes.ItemDefinition = {
	Id = "RegularFuelTank",
	DisplayName = "Tanque de combustible",
	Description = "Depósito para combustible normal compatible con Regular, Diésel o Competición.",
	Category = "FuelTanks",
	AssetFolder = "Tanques",
	Model = "RegularFuelTank",
	Price = 175,
	Stats = {
		Weight = 8,
		MaxDurability = 100,
		FuelSubtype = "Normal",
		FuelType = "Normal",
		SelectableFuelTypes = { "Regular", "Diesel", "Competicion" },
		Capacity = 1.5,
	},
	Behavior = nil,
}

return definition

