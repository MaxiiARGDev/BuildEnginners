--!strict
--[=[
	DamageMath
	Funciones puras y deterministas para cinemática de impactos, cálculo de daño por pieza,
	plan de distribución localizada e integridad estructural ponderada del vehículo (Fase 4.1).
	No realiza llamadas a Workspace ni mantiene estado mutable.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageConfig = require(ReplicatedStorage.Shared.Config.DamageConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type ImpactKinematicsInput = {
	RelativeVelocity: Vector3, -- v_other - v_piece (o aproximación hacia obstáculo)
	ImpactNormal: Vector3?, -- Normal saliente desde el obstáculo hacia la pieza impactada
	StruckMass: number,
	OtherMass: number?,
	OtherIsStatic: boolean?,
	TimeSinceLaunchSeconds: number?,
}

export type ImpactKinematicsResult = {
	PassesThreshold: boolean,
	RejectReason: string?,
	RelativeSpeed: number,
	NormalSpeed: number,
	TangentialSpeed: number,
	EffectiveImpactSpeed: number,
	EffectiveMass: number,
	MassFactor: number,
	EstimatedImpulse: number,
	EstimatedEnergy: number,
	RawDamage: number,
	ImpactMagnitude: number,
}

export type PieceDamageProfileInput = {
	ImpactResistance: number,
	DamageMultiplier: number,
}

export type NeighborGeometryNode = {
	PieceId: string,
	Position: Vector3?,
}

export type DistributionPlanInput = {
	PrimaryPieceId: string,
	PrimaryPosition: Vector3?,
	ImpactPosition: Vector3?,
	AdjacentNeighbors: { NeighborGeometryNode }?,
	AllowNeighborTransfer: boolean?,
}

local DamageMath = {}

function DamageMath.IsFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function DamageMath.IsFiniteVector3(v: any): boolean
	if typeof(v) ~= "Vector3" then
		return false
	end
	return DamageMath.IsFiniteNumber(v.X) and DamageMath.IsFiniteNumber(v.Y) and DamageMath.IsFiniteNumber(v.Z)
end

--[=[
	Calcula el punto más cercano sobre un OBB respecto a un punto en mundo y la normal exterior desde esa cara.
]=]
function DamageMath.ComputeClosestPointOnBox(boxCFrame: CFrame, boxSize: Vector3, worldPoint: Vector3): (Vector3, Vector3)
	local halfX = math.max(0.05, boxSize.X * 0.5)
	local halfY = math.max(0.05, boxSize.Y * 0.5)
	local halfZ = math.max(0.05, boxSize.Z * 0.5)

	local localPos = boxCFrame:PointToObjectSpace(worldPoint)
	local clamped = Vector3.new(
		math.clamp(localPos.X, -halfX, halfX),
		math.clamp(localPos.Y, -halfY, halfY),
		math.clamp(localPos.Z, -halfZ, halfZ)
	)
	local delta = localPos - clamped
	local localNormal: Vector3
	if delta.Magnitude > 1e-4 then
		localNormal = delta.Unit
	else
		-- Si el punto quedó exactamente dentro o sobre una cara, usar la cara más próxima
		local dx = math.abs(halfX - math.abs(localPos.X))
		local dy = math.abs(halfY - math.abs(localPos.Y))
		local dz = math.abs(halfZ - math.abs(localPos.Z))
		if dx <= dy and dx <= dz then
			localNormal = Vector3.new(if localPos.X >= 0 then 1 else -1, 0, 0)
		elseif dy <= dx and dy <= dz then
			localNormal = Vector3.new(0, if localPos.Y >= 0 then 1 else -1, 0)
		else
			localNormal = Vector3.new(0, 0, if localPos.Z >= 0 then 1 else -1)
		end
	end

	local closestWorld = boxCFrame:PointToWorldSpace(clamped)
	local worldNormal = boxCFrame:VectorToWorldSpace(localNormal)
	if worldNormal.Magnitude > 1e-4 then
		worldNormal = worldNormal.Unit
	else
		worldNormal = Vector3.yAxis
	end
	return closestWorld, worldNormal
end

--[=[
	Resuelve el estado textual de salud (`Healthy` | `Damaged` | `Disabled`) manteniendo invariantes [0, MaxHealth].
]=]
function DamageMath.ResolveHealthState(currentHealth: number, maxHealth: number): VehicleTypes.PieceHealthState
	local safeMax = math.max(1e-3, if DamageMath.IsFiniteNumber(maxHealth) then maxHealth else 1)
	local safeCur = math.clamp(if DamageMath.IsFiniteNumber(currentHealth) then currentHealth else 0, 0, safeMax)
	if safeCur <= 1e-5 then
		return DamageConfig.PieceStates.Disabled :: VehicleTypes.PieceHealthState
	elseif safeCur >= safeMax - 1e-5 then
		return DamageConfig.PieceStates.Healthy :: VehicleTypes.PieceHealthState
	end
	return DamageConfig.PieceStates.Damaged :: VehicleTypes.PieceHealthState
end

--[=[
	Calcula la masa efectiva reducida del choque.
	- Ante Terrain/obstáculos anclados (`OtherIsStatic`), domina la masa efectiva del vehículo/componente.
	- Entre dos cuerpos dinámicos (ej. vehículo vs vehículo), usa masa reducida mA*mB/(mA+mB).
]=]
function DamageMath.ComputeEffectiveMass(struckMass: number, otherMass: number?, otherIsStatic: boolean?): number
	local mA = if DamageMath.IsFiniteNumber(struckMass) and struckMass > 0 then struckMass else 10.0
	if otherIsStatic or otherMass == nil or not DamageMath.IsFiniteNumber(otherMass) or otherMass <= 0 then
		return math.max(1.0, mA)
	end
	local mB = otherMass
	return math.max(1.0, (mA * mB) / (mA + mB))
end

--[=[
	Evalúa la cinemática de una colisión y calcula impulso, energía estimada y daño base pre-resistencia.
	- Ignora contactos de reposo y velocidades bajo umbral.
	- Separa componente normal de raspado tangencial para evitar falsos positivos al rodar suavemente.
]=]
function DamageMath.EvaluateImpactKinematics(input: ImpactKinematicsInput): ImpactKinematicsResult
	local cfg = DamageConfig.Impact

	if not DamageMath.IsFiniteVector3(input.RelativeVelocity) then
		return {
			PassesThreshold = false,
			RejectReason = "NonFiniteVelocity",
			RelativeSpeed = 0,
			NormalSpeed = 0,
			TangentialSpeed = 0,
			EffectiveImpactSpeed = 0,
			EffectiveMass = 0,
			MassFactor = 0,
			EstimatedImpulse = 0,
			EstimatedEnergy = 0,
			RawDamage = 0,
			ImpactMagnitude = 0,
		}
	end

	local relVel = input.RelativeVelocity
	local rawRelSpeed = relVel.Magnitude
	local relSpeed = math.min(rawRelSpeed, cfg.MaxTrackedRelativeSpeedStudsPerSec)
	if rawRelSpeed > relSpeed and rawRelSpeed > 1e-5 then
		relVel = relVel * (relSpeed / rawRelSpeed)
	end

	local normalSpeed = relSpeed
	local tangentialSpeed = 0
	if input.ImpactNormal and DamageMath.IsFiniteVector3(input.ImpactNormal) and input.ImpactNormal.Magnitude > 1e-4 then
		local unitNormal = input.ImpactNormal.Unit
		-- Si relVel = v_other - v_piece y normal apunta desde other -> piece, el acercamiento es +relVel·normal
		local approach = relVel:Dot(unitNormal)
		if approach <= 0 then
			-- También tolerar convención invertida solo si no existe separación clara; si |approach| pequeño es separación
			normalSpeed = 0
		else
			normalSpeed = approach
		end
		local normalVec = unitNormal * approach
		local tangentVec = relVel - normalVec
		tangentialSpeed = tangentVec.Magnitude
	end

	local effMass = DamageMath.ComputeEffectiveMass(input.StruckMass, input.OtherMass, input.OtherIsStatic)
	local effectiveImpactSpeed = math.max(
		0,
		normalSpeed * cfg.NormalSpeedWeight + tangentialSpeed * cfg.TangentialSpeedWeight
	)
	local estimatedImpulse = effMass * effectiveImpactSpeed
	local estimatedEnergy = 0.5 * effMass * effectiveImpactSpeed * effectiveImpactSpeed

	local normalOK = normalSpeed >= cfg.MinNormalSpeedStudsPerSec
		or tangentialSpeed >= cfg.HighSpeedScrapeOverrideSpeed
	if not normalOK then
		return {
			PassesThreshold = false,
			RejectReason = "BelowNormalThreshold",
			RelativeSpeed = relSpeed,
			NormalSpeed = normalSpeed,
			TangentialSpeed = tangentialSpeed,
			EffectiveImpactSpeed = effectiveImpactSpeed,
			EffectiveMass = effMass,
			MassFactor = 0,
			EstimatedImpulse = estimatedImpulse,
			EstimatedEnergy = estimatedEnergy,
			RawDamage = 0,
			ImpactMagnitude = estimatedImpulse,
		}
	end

	if relSpeed < cfg.MinImpactSpeedStudsPerSec or effectiveImpactSpeed < cfg.DamageThresholdSpeedStudsPerSec then
		return {
			PassesThreshold = false,
			RejectReason = "BelowSpeedThreshold",
			RelativeSpeed = relSpeed,
			NormalSpeed = normalSpeed,
			TangentialSpeed = tangentialSpeed,
			EffectiveImpactSpeed = effectiveImpactSpeed,
			EffectiveMass = effMass,
			MassFactor = 0,
			EstimatedImpulse = estimatedImpulse,
			EstimatedEnergy = estimatedEnergy,
			RawDamage = 0,
			ImpactMagnitude = estimatedImpulse,
		}
	end

	if input.TimeSinceLaunchSeconds ~= nil and input.TimeSinceLaunchSeconds < cfg.LaunchSettlingGraceSeconds then
		if normalSpeed < cfg.GraceOverrideNormalSpeed then
			return {
				PassesThreshold = false,
				RejectReason = "LaunchSettlingGrace",
				RelativeSpeed = relSpeed,
				NormalSpeed = normalSpeed,
				TangentialSpeed = tangentialSpeed,
				EffectiveImpactSpeed = effectiveImpactSpeed,
				EffectiveMass = effMass,
				MassFactor = 0,
				EstimatedImpulse = estimatedImpulse,
				EstimatedEnergy = estimatedEnergy,
				RawDamage = 0,
				ImpactMagnitude = estimatedImpulse,
			}
		end
	end

	local excessSpeed = math.max(0, effectiveImpactSpeed - cfg.DamageThresholdSpeedStudsPerSec)
	local massRatio = math.max(0.05, effMass / math.max(1, cfg.ReferenceMass))
	local massFactor = math.clamp(massRatio ^ cfg.MassExponent, cfg.MinMassFactor, cfg.MaxMassFactor)
	local rawDamage = math.min(
		cfg.MaxSingleImpactRawDamage,
		cfg.DamageScale * (excessSpeed ^ cfg.DamageExponent) * massFactor
	)

	if rawDamage < cfg.MinDamageThreshold then
		return {
			PassesThreshold = false,
			RejectReason = "BelowDamageThreshold",
			RelativeSpeed = relSpeed,
			NormalSpeed = normalSpeed,
			TangentialSpeed = tangentialSpeed,
			EffectiveImpactSpeed = effectiveImpactSpeed,
			EffectiveMass = effMass,
			MassFactor = massFactor,
			EstimatedImpulse = estimatedImpulse,
			EstimatedEnergy = estimatedEnergy,
			RawDamage = rawDamage,
			ImpactMagnitude = estimatedImpulse,
		}
	end

	return {
		PassesThreshold = true,
		RejectReason = nil,
		RelativeSpeed = relSpeed,
		NormalSpeed = normalSpeed,
		TangentialSpeed = tangentialSpeed,
		EffectiveImpactSpeed = effectiveImpactSpeed,
		EffectiveMass = effMass,
		MassFactor = massFactor,
		EstimatedImpulse = estimatedImpulse,
		EstimatedEnergy = estimatedEnergy,
		RawDamage = rawDamage,
		ImpactMagnitude = estimatedImpulse,
	}
end

--[=[
	Aplica resistencia al impacto y multiplicador de sensibilidad propio de la pieza.
]=]
function DamageMath.ComputePieceDamage(
	rawDamage: number,
	pieceProfile: PieceDamageProfileInput,
	allocationWeight: number?
): number
	if not DamageMath.IsFiniteNumber(rawDamage) or rawDamage <= 0 then
		return 0
	end
	local weight = if allocationWeight ~= nil and DamageMath.IsFiniteNumber(allocationWeight)
		then math.max(0, allocationWeight)
		else 1.0
	if weight <= 0 then
		return 0
	end
	local resistance = if DamageMath.IsFiniteNumber(pieceProfile.ImpactResistance)
		then math.max(0.1, pieceProfile.ImpactResistance)
		else 1.0
	local multiplier = if DamageMath.IsFiniteNumber(pieceProfile.DamageMultiplier)
		then math.max(0, pieceProfile.DamageMultiplier)
		else 1.0

	local finalDmg = (rawDamage * weight * multiplier) / resistance
	if not DamageMath.IsFiniteNumber(finalDmg) or finalDmg <= 0 then
		return 0
	end
	return math.round(finalDmg * 1000) / 1000
end

--[=[
	Planifica la distribución localizada del impacto:
	- La pieza directamente golpeada concentra la mayor parte del daño (`PrimaryDirectShareWithNeighbors` o 1.0).
	- Las piezas conectadas a 1 salto (`Blueprint.Connections`) dentro del radio máximo reciben una transferencia
	  amortiguada proporcional a su cercanía al punto de impacto, dejando la arquitectura preparada para
	  propagación estructural multi-salto en fases futuras sin dañar globalmente todo el vehículo.
]=]
function DamageMath.ComputeDistributionPlan(input: DistributionPlanInput): { VehicleTypes.DamageDistributionTarget }
	local distCfg = DamageConfig.Distribution
	local neighbors = input.AdjacentNeighbors
	local allowTransfer = distCfg.EnableNeighborShockTransfer
		and input.AllowNeighborTransfer ~= false
		and distCfg.MaxPropagationHops >= 1
		and neighbors ~= nil
		and #neighbors > 0

	if not allowTransfer then
		return {
			{
				PieceId = input.PrimaryPieceId,
				Weight = 1.0,
				HopDistance = 0,
				DistanceFromImpact = 0,
				IsPrimaryTarget = true,
			},
		}
	end

	local refPos = input.ImpactPosition or input.PrimaryPosition
	local validNeighbors: { { PieceId: string, Dist: number, RawScore: number } } = {}
	local seen: { [string]: boolean } = { [input.PrimaryPieceId] = true }

	for _, nb in ipairs(neighbors :: { NeighborGeometryNode }) do
		if nb.PieceId ~= "" and not seen[nb.PieceId] then
			seen[nb.PieceId] = true
			local dist = 0
			if refPos and nb.Position and DamageMath.IsFiniteVector3(refPos) and DamageMath.IsFiniteVector3(nb.Position) then
				dist = (nb.Position - refPos).Magnitude
			end
			if dist <= distCfg.MaxAdjacentDistanceStuds then
				local score = 1.0 / (1.0 + dist * distCfg.AdjacentDistanceAttenuation)
				table.insert(validNeighbors, {
					PieceId = nb.PieceId,
					Dist = dist,
					RawScore = score,
				})
			end
		end
	end

	if #validNeighbors == 0 then
		return {
			{
				PieceId = input.PrimaryPieceId,
				Weight = 1.0,
				HopDistance = 0,
				DistanceFromImpact = 0,
				IsPrimaryTarget = true,
			},
		}
	end

	table.sort(validNeighbors, function(a, b)
		if math.abs(a.Dist - b.Dist) > 1e-4 then
			return a.Dist < b.Dist
		end
		return a.PieceId < b.PieceId
	end)

	local maxNeighbors = math.min(#validNeighbors, distCfg.MaxAdjacentNeighbors)
	local totalScore = 0
	for i = 1, maxNeighbors do
		totalScore += validNeighbors[i].RawScore
	end

	if totalScore <= 1e-6 then
		return {
			{
				PieceId = input.PrimaryPieceId,
				Weight = 1.0,
				HopDistance = 0,
				DistanceFromImpact = 0,
				IsPrimaryTarget = true,
			},
		}
	end

	local targets: { VehicleTypes.DamageDistributionTarget } = {
		{
			PieceId = input.PrimaryPieceId,
			Weight = distCfg.PrimaryDirectShareWithNeighbors,
			HopDistance = 0,
			DistanceFromImpact = 0,
			IsPrimaryTarget = true,
		},
	}

	local neighborPool = math.max(0, math.min(distCfg.MaxAdjacentTransferShare, 1.0 - distCfg.PrimaryDirectShareWithNeighbors))
	for i = 1, maxNeighbors do
		local nb = validNeighbors[i]
		local weight = neighborPool * (nb.RawScore / totalScore)
		if weight > 1e-4 then
			table.insert(targets, {
				PieceId = nb.PieceId,
				Weight = weight,
				HopDistance = 1,
				DistanceFromImpact = nb.Dist,
				IsPrimaryTarget = false,
			})
		end
	end

	return targets
end

--[=[
	Calcula la integridad estructural general ponderada por MaxHealth de todas las piezas del runtime:
	  StructuralIntegrity = sum(CurrentHealth) / sum(MaxHealth)
]=]
function DamageMath.ComputeWeightedStructuralIntegrity(pieceStates: { [string]: { CurrentHealth: number, MaxHealth: number } }): {
	TotalPieces: number,
	HealthyCount: number,
	DamagedCount: number,
	DisabledCount: number,
	TotalMaxHealth: number,
	TotalCurrentHealth: number,
	IntegrityRatio: number,
	IntegrityPercent: number,
}
	local totalPieces = 0
	local healthyCount = 0
	local damagedCount = 0
	local disabledCount = 0
	local totalMax = 0
	local totalCur = 0

	for _, rec in pairs(pieceStates) do
		local maxHp = math.max(1e-3, rec.MaxHealth)
		local curHp = math.clamp(rec.CurrentHealth, 0, maxHp)
		totalPieces += 1
		totalMax += maxHp
		totalCur += curHp

		local state = DamageMath.ResolveHealthState(curHp, maxHp)
		if state == DamageConfig.PieceStates.Healthy then
			healthyCount += 1
		elseif state == DamageConfig.PieceStates.Damaged then
			damagedCount += 1
		else
			disabledCount += 1
		end
	end

	local ratio = if totalMax > 0 then math.clamp(totalCur / totalMax, 0, 1) else 1.0
	local pct = math.round(ratio * 10000) / 100

	return {
		TotalPieces = totalPieces,
		HealthyCount = healthyCount,
		DamagedCount = damagedCount,
		DisabledCount = disabledCount,
		TotalMaxHealth = totalMax,
		TotalCurrentHealth = totalCur,
		IntegrityRatio = ratio,
		IntegrityPercent = pct,
	}
end

return DamageMath

