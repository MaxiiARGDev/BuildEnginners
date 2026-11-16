--!strict
--[=[
	BuildSnapPolicy
	Política compartida cliente/servidor para resoluciones de grid, modos de posicionamiento
	y rotaciones autorizadas por tipo/ItemId desde ItemRegistry.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)

export type PositionMode = "Grid" | "Free"

local BuildSnapPolicy = {}

function BuildSnapPolicy.IsValidPositionMode(mode: any): boolean
	return mode == GameConfig.Building.PositionModes.Grid or mode == GameConfig.Building.PositionModes.Free
end

function BuildSnapPolicy.NormalizePositionMode(mode: any): PositionMode
	if mode == GameConfig.Building.PositionModes.Free then
		return GameConfig.Building.PositionModes.Free :: PositionMode
	end
	return GameConfig.Building.PositionModes.Grid :: PositionMode
end

function BuildSnapPolicy.IsValidGridResolution(resolution: any): boolean
	if type(resolution) ~= "number" or resolution ~= resolution or resolution <= 0 then
		return false
	end
	for _, allowed in ipairs(GameConfig.Building.GridResolutions) do
		if math.abs(resolution - allowed) < 1e-4 then
			return true
		end
	end
	return false
end

function BuildSnapPolicy.NormalizeGridResolution(resolution: any): number
	if type(resolution) ~= "number" or resolution ~= resolution or resolution <= 0 then
		return GameConfig.Building.DefaultGridResolution
	end
	for _, allowed in ipairs(GameConfig.Building.GridResolutions) do
		if math.abs(resolution - allowed) < 1e-4 then
			return allowed
		end
	end
	return GameConfig.Building.DefaultGridResolution
end

function BuildSnapPolicy.IsValidAngleIncrement(degrees: any): boolean
	if type(degrees) ~= "number" or degrees ~= degrees or degrees <= 0 then
		return false
	end
	for _, allowed in ipairs(GameConfig.Building.AngleIncrementsDeg) do
		if math.abs(degrees - allowed) < 1e-4 then
			return true
		end
	end
	return false
end

function BuildSnapPolicy.NormalizeAngleIncrement(degrees: any): number
	if type(degrees) ~= "number" or degrees ~= degrees or degrees <= 0 then
		return GameConfig.Building.DefaultAngleIncrementDeg
	end
	for _, allowed in ipairs(GameConfig.Building.AngleIncrementsDeg) do
		if math.abs(degrees - allowed) < 1e-4 then
			return allowed
		end
	end
	return GameConfig.Building.DefaultAngleIncrementDeg
end

function BuildSnapPolicy.GetPolicyForItem(itemId: string): ItemRegistry.NormalizedPlacementPolicy
	return ItemRegistry.GetPlacementPolicy(itemId)
end

function BuildSnapPolicy.GetAllowedAngleSteps(itemId: string): { number }
	return ItemRegistry.GetPlacementPolicy(itemId).AllowedAngleStepsDeg
end

function BuildSnapPolicy.IsAngleIncrementAllowed(itemId: string, degrees: number): boolean
	local policy = ItemRegistry.GetPlacementPolicy(itemId)
	if policy.RotationMode == "Free" or policy.AllowFreeRotation then
		return degrees > 0 and degrees <= 90
	end
	if policy.RotationMode == "Orthogonal90" then
		return math.abs(degrees - 90) < 1e-4
	end
	for _, stepDeg in ipairs(policy.AllowedAngleStepsDeg) do
		if math.abs(degrees - stepDeg) < 1e-4 then
			return true
		end
	end
	return false
end

function BuildSnapPolicy.GetEffectiveAngleIncrement(itemId: string?, requestedDeg: number?): number
	if not itemId or itemId == "" or not ItemRegistry.Has(itemId) then
		return 90
	end
	local req = BuildSnapPolicy.NormalizeAngleIncrement(requestedDeg)
	local policy = ItemRegistry.GetPlacementPolicy(itemId)
	if policy.RotationMode == "Orthogonal90" and not policy.AllowFreeRotation then
		return 90
	end
	if BuildSnapPolicy.IsAngleIncrementAllowed(itemId, req) then
		return req
	end
	local steps = policy.AllowedAngleStepsDeg
	return if #steps > 0 then steps[1] else 90
end

function BuildSnapPolicy.SnapValueToStep(value: number, step: number): number
	if step <= 0 then
		return value
	end
	local snapped = math.floor(value / step + 0.5) * step
	if math.abs(snapped) < 1e-6 then
		return 0
	end
	return snapped
end

--[=[
	Valida autoritativamente si la rotación del CFrame está autorizada para `itemId`.
	Devuelve `(ok, normalizedRotationCFrame, errorCode)`.
]=]
function BuildSnapPolicy.ValidateRotationForItem(itemId: string, rotationCFrame: CFrame): (boolean, CFrame?, string?)
	if not BuildRotation.IsOrthonormalRotation(rotationCFrame) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidRotation
	end

	local policy = ItemRegistry.GetPlacementPolicy(itemId)
	if policy.RotationMode == "Free" or policy.AllowFreeRotation then
		return true, BuildRotation.OrthonormalizeGeneral(rotationCFrame), nil
	end

	if policy.RotationMode == "Orthogonal90" then
		if not BuildRotation.IsOrthogonal90(rotationCFrame) then
			return false, nil, BuildProtocol.ErrorCodes.InvalidRotation
		end
		return true, BuildRotation.Orthonormalize(rotationCFrame), nil
	end

	-- Modo StepDegrees: la rotación debe alinear con al menos uno de los pasos permitidos (ej. 90, 45, 15, 1)
	local steps = policy.AllowedAngleStepsDeg
	local minAllowedStep = steps[#steps] or 90
	if not BuildRotation.CheckRotationAlignedToStep(rotationCFrame, minAllowedStep) then
		return false, nil, BuildProtocol.ErrorCodes.InvalidRotation
	end

	if BuildRotation.IsOrthogonal90(rotationCFrame) then
		return true, BuildRotation.Orthonormalize(rotationCFrame), nil
	end
	return true, BuildRotation.OrthonormalizeGeneral(rotationCFrame), nil
end

--[=[
	Valida y normaliza un LocalCFrame completo según la política del objeto.
]=]
function BuildSnapPolicy.ValidateCFrameForItem(itemId: string, localCFrame: CFrame): (boolean, CFrame?, string?)
	local rotOk, normalizedRot, rotErr = BuildSnapPolicy.ValidateRotationForItem(itemId, localCFrame.Rotation)
	if not rotOk or not normalizedRot then
		return false, nil, rotErr or BuildProtocol.ErrorCodes.InvalidRotation
	end

	local policy = ItemRegistry.GetPlacementPolicy(itemId)
	local pos = localCFrame.Position
	if not policy.AllowFreePosition then
		local step = GameConfig.Building.DefaultGridResolution
		pos = Vector3.new(
			BuildSnapPolicy.SnapValueToStep(pos.X, step),
			pos.Y,
			BuildSnapPolicy.SnapValueToStep(pos.Z, step)
		)
	end

	return true, CFrame.new(pos) * normalizedRot, nil
end

return BuildSnapPolicy
