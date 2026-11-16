--!strict
--[=[
	EngineBehavior (Fase 3.3: contrato modular de motor gobernado centralmente por VehiclePowertrainService)
	Regla SDD / AGENTS.md #7: Sin bucles Heartbeat por pieza; toda la simulación se ejecuta en el orquestador del vehículo.
]=]

local EngineBehavior = {}

function EngineBehavior.Init(runtime: any, partState: any, model: Model)
	if model then
		model:SetAttribute("EngineBehaviorActive", true)
		model:SetAttribute("EngineRuntimeReady", true)
	end
	if type(runtime) == "table" then
		runtime.EnginePieceIds = runtime.EnginePieceIds or {}
		if type(partState) == "table" and type(partState.PieceInstanceId) == "string" then
			if not table.find(runtime.EnginePieceIds, partState.PieceInstanceId) then
				table.insert(runtime.EnginePieceIds, partState.PieceInstanceId)
			end
		end
	end
end

function EngineBehavior.Destroy(_runtime: any, _partState: any, model: Model)
	if model and model.Parent then
		model:SetAttribute("EngineBehaviorActive", false)
		model:SetAttribute("EngineRuntimeReady", false)
	end
end

return EngineBehavior

