--!strict
--[=[
	DriverSeatBehavior (Fase 1: contrato modular sin simulación física todavía)
]=]

local DriverSeatBehavior = {}

function DriverSeatBehavior.Init(runtime: any, partState: any, model: Model)
	-- Fase 1: registro y ciclo de vida modular sin simulación física.
end

function DriverSeatBehavior.Destroy(runtime: any, partState: any, model: Model)
	-- Limpieza modular por pieza.
end

return DriverSeatBehavior

