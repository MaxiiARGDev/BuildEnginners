--!strict
--[=[
	WheelMechanismBuilder
	Construye los mecanismos articulados modulares de cada rueda en Runtime:
	- SuspensionCarrier + PrismaticConstraint + SpringConstraint (eje vertical real del vehículo).
	- SteeringPivot opcional + HingeConstraint Servo (eje Up del vehículo, omitido si dirección inactiva).
	- Axle HingeConstraint Motor calibrado sobre el eje cilíndrico real normalizado a -VehicleRight
	  (rodamiento hacia adelante consistente en ruedas izquierda/derecha y DriverSeat rotados).
	- Propiedades físicas de neumático calibradas (Elasticity reducida y Friction escalada por Grip).
	- NoCollisionConstraints entre rueda, soportes y partes de chasis adyacentes dentro de su envolvente.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type BuiltWheelMechanism = {
	WheelId: string,
	PieceInstanceId: string,
	ItemId: string,
	MountPieceId: string,
	MountPart: BasePart,
	WheelPart: BasePart,
	WheelModel: Model,
	CarrierPart: Part?,
	PivotPart: Part?,
	Prismatic: PrismaticConstraint?,
	Spring: SpringConstraint?,
	SteeringHinge: HingeConstraint?,
	AxleHinge: HingeConstraint,
	NoCollisions: { NoCollisionConstraint },
	ResolvedConfig: VehicleTypes.ResolvedWheelConfig,
	AxleAxisSignFlipped: boolean,
	WheelRadius: number,
	WheelWidth: number,
	HasManualOverrides: boolean,
}

export type BuildWheelMechanismsParams = {
	RootModel: Model,
	WheelPieceIds: { string },
	PieceModelsById: { [string]: Model },
	PiecePrimaryPartsById: { [string]: BasePart },
	PieceRolesById: { [string]: VehicleTypes.PartPhysicsRole },
	MountByWheelId: { [string]: string },
	WheelAnalysis: VehicleTypes.VehicleWheelAnalysis,
	DriverSeatPiece: VehicleTypes.BlueprintPiece,
	DriverSeatPart: VehicleSeat,
}

export type BuildWheelMechanismsResult = {
	MechanismsByPieceId: { [string]: BuiltWheelMechanism },
	Constraints: { Instance },
	MechanismsFolder: Folder,
}

local WheelMechanismBuilder = {}

local function createNoCollision(part0: BasePart, part1: BasePart, roleName: string, parent: Instance): NoCollisionConstraint
	local nc = Instance.new("NoCollisionConstraint")
	nc.Name = `NoCol_{part0.Name}_{part1.Name}`
	nc.Part0 = part0
	nc.Part1 = part1
	nc.Enabled = true
	nc:SetAttribute("ConstraintRole", roleName)
	nc.Parent = parent
	return nc
end

local function createHubPart(
	name: string,
	size: Vector3,
	worldCF: CFrame,
	hubDensity: number,
	role: string,
	wheelPieceId: string,
	parent: Instance
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = worldCF
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Anchored = false
	part.Massless = false
	part.CustomPhysicalProperties = PhysicalProperties.new(hubDensity, 0, 0, 0, 0)
	part.CollisionGroup = GameConfig.Runtime.CollisionGroups.VehicleRuntime
	part:SetAttribute("PartPhysicsRole", role)
	part:SetAttribute("WheelPieceId", wheelPieceId)
	part.Parent = parent
	return part
end

local function makeOrthonormalFrameFromAxis(axis: Vector3, preferredSecondary: Vector3, fallbackSecondary: Vector3): CFrame
	local xAxis = axis.Unit
	local projected = preferredSecondary - xAxis * preferredSecondary:Dot(xAxis)
	if projected.Magnitude < 1e-4 then
		projected = fallbackSecondary - xAxis * fallbackSecondary:Dot(xAxis)
	end
	if projected.Magnitude < 1e-4 then
		local alt = if math.abs(xAxis.Y) < 0.9 then Vector3.new(0, 1, 0) else Vector3.new(1, 0, 0)
		projected = alt - xAxis * alt:Dot(xAxis)
	end
	local yAxis = projected.Unit
	return CFrame.fromMatrix(Vector3.zero, xAxis, yAxis)
end

local function applyCalibratedTirePhysics(wheelModel: Model, wheelPart: BasePart, itemId: string)
	local W = GameConfig.Wheels
	local def = ItemRegistry.TryGet(itemId)
	local grip = if def and def.Stats and type(def.Stats.Grip) == "number" then def.Stats.Grip else 1.0
	local friction = math.clamp(grip * W.WheelFrictionScale, W.WheelMinFriction, W.WheelMaxFriction)

	for _, desc in ipairs(wheelModel:GetDescendants()) do
		if desc:IsA("BasePart") then
			local curProps = desc.CurrentPhysicalProperties
			local density = if curProps then curProps.Density else 1.3
			desc.CustomPhysicalProperties = PhysicalProperties.new(
				density,
				friction,
				W.WheelElasticity,
				W.WheelFrictionWeight,
				W.WheelElasticityWeight
			)
		end
	end

	-- Asegurar referencia explícita en Primary
	if not wheelPart.CustomPhysicalProperties then
		wheelPart.CustomPhysicalProperties = PhysicalProperties.new(
			1.3,
			friction,
			W.WheelElasticity,
			W.WheelFrictionWeight,
			W.WheelElasticityWeight
		)
	end
end

function WheelMechanismBuilder.BuildWheelMechanisms(params: BuildWheelMechanismsParams): BuildWheelMechanismsResult
	local W = GameConfig.Wheels
	local analysis = params.WheelAnalysis

	local mechanismsFolder = Instance.new("Folder")
	mechanismsFolder.Name = "WheelMechanisms"
	mechanismsFolder.Parent = params.RootModel

	-- Transformación exacta Blueprint-Local -> Staging World usando el DriverSeat real clonado
	local localToWorld = params.DriverSeatPart.CFrame * params.DriverSeatPiece.LocalCFrame:Inverse()
	local worldForward = localToWorld:VectorToWorldSpace(analysis.VehicleForward).Unit
	local worldRight = localToWorld:VectorToWorldSpace(analysis.VehicleRight).Unit
	local worldUp = localToWorld:VectorToWorldSpace(analysis.VehicleUp).Unit
	local baseVehRot = CFrame.fromMatrix(Vector3.zero, worldRight, worldUp)

	local gravity = if Workspace.Gravity > 0 then Workspace.Gravity else 196.2
	local suspendedCount = 0
	for _, wid in ipairs(params.WheelPieceIds) do
		local resolved = analysis.ByPieceId[wid]
		if resolved and resolved.EffectiveSuspensionEnabled then
			suspendedCount += 1
		end
	end
	local effMassPerWheel = (analysis.EstimatedChassisMass + 0.5 * W.EstimatedDriverMass)
		/ math.max(1, if suspendedCount > 0 then suspendedCount else math.max(1, #params.WheelPieceIds))
	local staticLoadForce = effMassPerWheel * gravity

	-- Colectar partes no-rueda del chasis para limpiar posibles rozamientos en pozos de rueda
	local chassisPartsByPieceId: { [string]: { BasePart } } = {}
	for pid, model in pairs(params.PieceModelsById) do
		if params.PieceRolesById[pid] ~= GameConfig.Runtime.PartRoles.Wheel then
			local list: { BasePart } = {}
			for _, desc in ipairs(model:GetDescendants()) do
				if desc:IsA("BasePart") then
					table.insert(list, desc)
				end
			end
			chassisPartsByPieceId[pid] = list
		end
	end

	local mechanismsByPieceId: { [string]: BuiltWheelMechanism } = {}
	local allConstraints: { Instance } = {}

	local function trackConstraint(inst: Instance): Instance
		table.insert(allConstraints, inst)
		return inst
	end

	for _, wheelPieceId in ipairs(params.WheelPieceIds) do
		local wheelModel = params.PieceModelsById[wheelPieceId]
		local wheelPart = params.PiecePrimaryPartsById[wheelPieceId]
		local resolved = analysis.ByPieceId[wheelPieceId]
		local mountPieceId = params.MountByWheelId[wheelPieceId]
		local mountPart = if mountPieceId then params.PiecePrimaryPartsById[mountPieceId] else nil

		if not wheelModel or not wheelPart or not resolved or not mountPieceId or not mountPart then
			error(`MissingWheelMechanismEndpoint:{wheelPieceId}`)
		end

		local wheelCenter = wheelPart.Position
		local hubWorldCF = CFrame.new(wheelCenter) * baseVehRot

		local wheelRigFolder = Instance.new("Folder")
		wheelRigFolder.Name = `WheelRig_{wheelPieceId}`
		wheelRigFolder:SetAttribute("WheelPieceId", wheelPieceId)
		wheelRigFolder:SetAttribute("MountPieceId", mountPieceId)
		wheelRigFolder.Parent = mechanismsFolder

		applyCalibratedTirePhysics(wheelModel, wheelPart, resolved.ItemId)

		wheelModel:SetAttribute("WheelState", "ArticulatedReady")
		wheelModel:SetAttribute("ArticulationReady", true)
		wheelModel:SetAttribute("HasSuspension", resolved.EffectiveSuspensionEnabled)
		wheelModel:SetAttribute("HasSteering", resolved.EffectiveSteeringEnabled)
		wheelModel:SetAttribute("IsDriven", resolved.IsDriven)
		wheelModel:SetAttribute("AxleRole", resolved.Analysis.AxleRole)
		wheelModel:SetAttribute("SideRole", resolved.Analysis.SideRole)
		wheelModel:SetAttribute("HasManualWheelConfig", resolved.HasManualOverrides)

		local noCollisions: { NoCollisionConstraint } = {}
		local ncAddedParts: { [BasePart]: boolean } = {}
		local function addNoCol(partOther: BasePart, roleName: string)
			if partOther == wheelPart or ncAddedParts[partOther] then
				return
			end
			ncAddedParts[partOther] = true
			local nc = createNoCollision(wheelPart, partOther, roleName, wheelRigFolder)
			trackConstraint(nc)
			table.insert(noCollisions, nc)
		end

		-- NoCollision obligatorio con el soporte principal y todas sus sub-partes
		addNoCol(mountPart, "WheelMountNoCollision")
		local mountList = chassisPartsByPieceId[mountPieceId]
		if mountList then
			for _, mp in ipairs(mountList) do
				addNoCol(mp, "WheelMountSubNoCollision")
			end
		end

		-- NoCollision preventivo contra partes del mismo chasis cercanas al recorrido de suspensión/giro
		local clearanceRadius = resolved.WheelRadius
			+ (if resolved.EffectiveSuspensionEnabled then resolved.SuspensionTravel else 0)
			+ 0.45
		for otherPid, partList in pairs(chassisPartsByPieceId) do
			if otherPid ~= mountPieceId then
				for _, cp in ipairs(partList) do
					local halfDiag = cp.Size.Magnitude * 0.5
					if (cp.Position - wheelCenter).Magnitude <= clearanceRadius + halfDiag then
						addNoCol(cp, "WheelChassisClearance")
					end
				end
			end
		end

		local carrierPart: Part? = nil
		local pivotPart: Part? = nil
		local prismatic: PrismaticConstraint? = nil
		local spring: SpringConstraint? = nil
		local steeringHinge: HingeConstraint? = nil

		local currentSupportPart: BasePart = mountPart

		-- 1) Etapa de Suspensión (Prismatic + Spring a lo largo de worldUp)
		if resolved.EffectiveSuspensionEnabled then
			local carrier = createHubPart(
				`Carrier_{wheelPieceId}`,
				W.CarrierSize,
				hubWorldCF,
				W.HubDensity,
				GameConfig.Runtime.PartRoles.SuspensionCarrier,
				wheelPieceId,
				wheelRigFolder
			)
			carrierPart = carrier
			addNoCol(carrier, "WheelCarrierNoCollision")

			local suspAnchorOffset = W.SpringMountHeightOffsetStuds
			local springTopWorld = wheelCenter + worldUp * suspAnchorOffset
			local suspOrientWorld = makeOrthonormalFrameFromAxis(-worldUp, worldForward, worldRight)

			local attMountSusp = Instance.new("Attachment")
			attMountSusp.Name = `AttMountSusp_{wheelPieceId}`
			attMountSusp.CFrame = mountPart.CFrame:ToObjectSpace(CFrame.new(springTopWorld) * suspOrientWorld)
			attMountSusp.Parent = mountPart

			local attCarrierSusp = Instance.new("Attachment")
			attCarrierSusp.Name = `AttCarrierSusp_{wheelPieceId}`
			attCarrierSusp.CFrame = carrier.CFrame:ToObjectSpace(CFrame.new(wheelCenter) * suspOrientWorld)
			attCarrierSusp.Parent = carrier

			local targetDistance = suspAnchorOffset + resolved.RideHeight
			local compressTravel = resolved.SuspensionTravel * W.SuspensionCompressRatio
			local reboundTravel = resolved.SuspensionTravel * (1 - W.SuspensionCompressRatio)

			local pCons = Instance.new("PrismaticConstraint")
			pCons.Name = `PrismaticSusp_{wheelPieceId}`
			pCons.Attachment0 = attMountSusp
			pCons.Attachment1 = attCarrierSusp
			pCons.LimitsEnabled = true
			pCons.LowerLimit = targetDistance - compressTravel
			pCons.UpperLimit = targetDistance + reboundTravel
			pCons.Restitution = 0
			pCons.ActuatorType = Enum.ActuatorType.None
			pCons.Enabled = true
			pCons:SetAttribute("ConstraintRole", "WheelSuspensionPrismatic")
			pCons:SetAttribute("WheelPieceId", wheelPieceId)
			pCons:SetAttribute("MountPieceId", mountPieceId)
			pCons.Parent = wheelRigFolder
			prismatic = pCons
			trackConstraint(pCons)

			local preloadComp = math.clamp(
				staticLoadForce / math.max(W.MinSpringStiffness, resolved.SpringStiffness),
				0,
				W.AutoSpringMaxPreloadStuds or 2.2
			)

			local sCons = Instance.new("SpringConstraint")
			sCons.Name = `SpringSusp_{wheelPieceId}`
			sCons.Attachment0 = attMountSusp
			sCons.Attachment1 = attCarrierSusp
			sCons.LimitsEnabled = false
			sCons.Stiffness = resolved.SpringStiffness
			sCons.Damping = resolved.SpringDamping
			sCons.FreeLength = math.max(0.25, targetDistance + preloadComp)
			sCons.MaxForce = math.huge
			sCons.Visible = false
			sCons.Enabled = true
			sCons:SetAttribute("ConstraintRole", "WheelSuspensionSpring")
			sCons:SetAttribute("WheelPieceId", wheelPieceId)
			sCons:SetAttribute("MountPieceId", mountPieceId)
			sCons.Parent = wheelRigFolder
			spring = sCons
			trackConstraint(sCons)

			currentSupportPart = carrier
		end

		-- 2) Etapa de Dirección (SteeringPivot + HingeConstraint Servo alrededor de worldUp)
		if resolved.EffectiveSteeringEnabled then
			local pivot = createHubPart(
				`Pivot_{wheelPieceId}`,
				W.PivotSize,
				hubWorldCF,
				W.HubDensity,
				GameConfig.Runtime.PartRoles.SteeringPivot,
				wheelPieceId,
				wheelRigFolder
			)
			pivotPart = pivot
			addNoCol(pivot, "WheelPivotNoCollision")

			local steerOrientWorld = makeOrthonormalFrameFromAxis(worldUp, worldForward, worldRight)

			local attSteerBase = Instance.new("Attachment")
			attSteerBase.Name = `AttSteerBase_{wheelPieceId}`
			attSteerBase.CFrame = currentSupportPart.CFrame:ToObjectSpace(CFrame.new(wheelCenter) * steerOrientWorld)
			attSteerBase.Parent = currentSupportPart

			local attSteerPivot = Instance.new("Attachment")
			attSteerPivot.Name = `AttSteerPivot_{wheelPieceId}`
			attSteerPivot.CFrame = pivot.CFrame:ToObjectSpace(CFrame.new(wheelCenter) * steerOrientWorld)
			attSteerPivot.Parent = pivot

			local sHinge = Instance.new("HingeConstraint")
			sHinge.Name = `SteeringHinge_{wheelPieceId}`
			sHinge.Attachment0 = attSteerBase
			sHinge.Attachment1 = attSteerPivot
			sHinge.ActuatorType = Enum.ActuatorType.Servo
			sHinge.LimitsEnabled = true
			sHinge.LowerAngle = -W.MaxSteeringAngleDeg
			sHinge.UpperAngle = W.MaxSteeringAngleDeg
			sHinge.TargetAngle = 0
			sHinge.AngularSpeed = math.rad(resolved.SteeringSpeed)
			sHinge.AngularResponsiveness = W.SteeringAngularResponsiveness or 120
			sHinge.ServoMaxTorque = W.SteeringServoMaxTorque
			sHinge.Enabled = true
			sHinge:SetAttribute("ConstraintRole", "WheelSteeringServo")
			sHinge:SetAttribute("WheelPieceId", wheelPieceId)
			sHinge:SetAttribute("MountPieceId", mountPieceId)
			sHinge.Parent = wheelRigFolder
			steeringHinge = sHinge
			trackConstraint(sHinge)

			currentSupportPart = pivot
		end

		-- 3) Etapa de Eje de Giro (Axle HingeConstraint Motor sobre eje cilíndrico normalizado a -worldRight)
		local rawSpinWorld = wheelPart.CFrame:VectorToWorldSpace(resolved.LocalSpinAxis).Unit
		local desiredSpinRef = -worldRight
		local spinSignFlipped = false
		local axleAxisWorld = rawSpinWorld
		if rawSpinWorld:Dot(desiredSpinRef) < 0 then
			axleAxisWorld = -rawSpinWorld
			spinSignFlipped = true
		end

		local axleOrientWorld = makeOrthonormalFrameFromAxis(axleAxisWorld, worldUp, worldForward)

		local attAxleBase = Instance.new("Attachment")
		attAxleBase.Name = `AttAxleBase_{wheelPieceId}`
		attAxleBase.CFrame = currentSupportPart.CFrame:ToObjectSpace(CFrame.new(wheelCenter) * axleOrientWorld)
		attAxleBase.Parent = currentSupportPart

		local attAxleWheel = Instance.new("Attachment")
		attAxleWheel.Name = `AttAxleWheel_{wheelPieceId}`
		attAxleWheel.CFrame = wheelPart.CFrame:ToObjectSpace(CFrame.new(wheelCenter) * axleOrientWorld)
		attAxleWheel.Parent = wheelPart

		local aHinge = Instance.new("HingeConstraint")
		aHinge.Name = `AxleHinge_{wheelPieceId}`
		aHinge.Attachment0 = attAxleBase
		aHinge.Attachment1 = attAxleWheel
		aHinge.ActuatorType = Enum.ActuatorType.Motor
		aHinge.LimitsEnabled = false
		aHinge.AngularVelocity = 0
		aHinge.MotorMaxTorque = W.PassiveRollingFrictionTorque
		aHinge.MotorMaxAcceleration = 500
		aHinge.Enabled = true
		aHinge:SetAttribute("ConstraintRole", "WheelAxleHinge")
		aHinge:SetAttribute("WheelPieceId", wheelPieceId)
		aHinge:SetAttribute("MountPieceId", mountPieceId)
		aHinge.Parent = wheelRigFolder
		trackConstraint(aHinge)

		mechanismsByPieceId[wheelPieceId] = {
			WheelId = wheelPieceId,
			PieceInstanceId = wheelPieceId,
			ItemId = resolved.ItemId,
			MountPieceId = mountPieceId,
			MountPart = mountPart,
			WheelPart = wheelPart,
			WheelModel = wheelModel,
			CarrierPart = carrierPart,
			PivotPart = pivotPart,
			Prismatic = prismatic,
			Spring = spring,
			SteeringHinge = steeringHinge,
			AxleHinge = aHinge,
			NoCollisions = noCollisions,
			ResolvedConfig = resolved,
			AxleAxisSignFlipped = spinSignFlipped,
			WheelRadius = resolved.WheelRadius,
			WheelWidth = resolved.WheelWidth,
			HasManualOverrides = resolved.HasManualOverrides,
		}
	end

	return {
		MechanismsByPieceId = mechanismsByPieceId,
		Constraints = allConstraints,
		MechanismsFolder = mechanismsFolder,
	}
end

return WheelMechanismBuilder
