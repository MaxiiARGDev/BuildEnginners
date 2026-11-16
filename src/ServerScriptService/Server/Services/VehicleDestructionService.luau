--!strict
-- Una transacción síncrona por resultado de daño; nunca se modifica el blueprint.
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")
local Config = require(game.ReplicatedStorage.Shared.Config.DestructionConfig)
local Services = script.Parent
local Wheels = require(Services.VehicleWheelControllerService)
local Powertrain = require(Services.VehiclePowertrainService)
local Boosters = require(Services.VehicleBoosterService)
local Aerodynamics = require(Services.AerodynamicsService)
local Items = require(Services.ItemRuntimeService)
local Seats = require(Services.VehicleSeatService)
local Service = { Name = "VehicleDestructionService" }
local entries: { [string]: any } = {}
local debris: { any } = {}
local heartbeat: RBXScriptConnection? = nil
local clock = os.clock

local function removeFragment(fragment)
	if fragment.Removed then return end
	fragment.Removed = true
	fragment.Model:Destroy()
	for _, id in fragment.PieceIds do
		local part = fragment.Runtime.Parts[id]
		if part then part.ModelInstance = nil; part.PrimaryPart = nil end
	end
end

function Service.CleanupExpired(now: number?)
	local current = now or clock()
	local total = 0
	local byRuntime = {}
	for _, fragment in debris do
		if not fragment.Removed and (fragment.ExpiresAt <= current or not fragment.Model.Parent) then removeFragment(fragment) end
		if not fragment.Removed then
			total += #fragment.PieceIds
			local id = fragment.Runtime.RuntimeId
			byRuntime[id] = (byRuntime[id] or 0) + #fragment.PieceIds
		end
	end
	for _, fragment in debris do
		local id = fragment.Runtime.RuntimeId
		if not fragment.Removed and (total > Config.MaxDebrisPiecesServer or byRuntime[id] > Config.MaxDebrisPiecesPerRuntime) then
			total -= #fragment.PieceIds
			byRuntime[id] -= #fragment.PieceIds
			removeFragment(fragment)
		end
	end
	for i = #debris, 1, -1 do if debris[i].Removed then table.remove(debris, i) end end
	if #debris == 0 and heartbeat then heartbeat:Disconnect(); heartbeat = nil end
end

function Service.RegisterRuntime(runtime, onStructureChanged)
	Service.UnregisterRuntime(runtime)
	if not PhysicsService:IsCollisionGroupRegistered(Config.DebrisCollisionGroup) then
		PhysicsService:RegisterCollisionGroup(Config.DebrisCollisionGroup)
	end
	for _, groupName in { "VehicleRuntime", "EditableVehicle", "EditorGhost", Config.DebrisCollisionGroup } do
		if PhysicsService:IsCollisionGroupRegistered(groupName) then
			PhysicsService:CollisionGroupSetCollidable(Config.DebrisCollisionGroup, groupName, false)
		end
	end
	entries[runtime.RuntimeId] = { Runtime = runtime, OnChanged = onStructureChanged, Processing = false }
end

-- BFS: solo aristas del runtime que corresponden a uniones físicas reales.
function Service.ComputeComponents(runtime, broken)
	local seen = {}
	local groups = {}
	local ids = {}
	for id, part in runtime.Parts do if not part.IsDetached and not broken[id] then table.insert(ids, id) end end
	table.sort(ids)
	for _, seed in ids do
		if seen[seed] then continue end
		local group = { seed }; seen[seed] = true
		local cursor = 1
		while cursor <= #group do
			local id = group[cursor]; cursor += 1
			for _, neighbor in (runtime.PieceAdjacencyById or {})[id] or {} do
				local part = runtime.Parts[neighbor]
				if part and not part.IsDetached and not broken[neighbor] and not seen[neighbor] then
					seen[neighbor] = true; table.insert(group, neighbor)
				end
			end
		end
		table.insert(groups, group)
	end
	return groups
end

function Service.ProcessImpact(runtime, result)
	local entry = entries[runtime.RuntimeId]
	if not entry or entry.Processing or #result.BrokenParts == 0 then return end
	local broken = {}
	for _, id in result.BrokenParts do
		local part = runtime.Parts[id]
		if part and not part.IsDetached and not part.IsDestroyed and part.CurrentHealth == 0 and part.HealthState == "Disabled" then broken[id] = true end
	end
	if next(broken) == nil then return end
	entry.Processing = true
	local started = os.clock()
	local root = runtime.RootModel
	local groups = Service.ComputeComponents(runtime, broken)
	local driverId = nil
	for id, part in runtime.Parts do if part.PrimaryPart == runtime.DriverSeatPart and runtime.DriverSeatPart then driverId = id end end
	local main = nil
	for _, group in groups do if driverId and table.find(group, driverId) then main = group; break end end
	-- Sin conductor: conservar el mayor componente como casco pasivo, nunca borrar el vehículo.
	if not main then
		for _, group in groups do if not main or #group > #main then main = group end end
	end
	local membership = {}
	local fragments = {}
	for _, group in groups do
		if group == main then for _, id in group do membership[id] = 0 end
		else table.insert(fragments, group); for _, id in group do membership[id] = #fragments end end
	end
	local brokenIds = {}
	for id in broken do table.insert(brokenIds, id) end
	table.sort(brokenIds)
	for _, id in brokenIds do table.insert(fragments, { id }); membership[id] = #fragments end
	local partIds = {}
	local velocities = {}
	for id, part in runtime.Parts do
		if membership[id] ~= nil and part.ModelInstance then
			for _, d in part.ModelInstance:GetDescendants() do if d:IsA("BasePart") then partIds[d] = id end end
		end
	end
	for id, mech in runtime.WheelMechanisms or {} do
		if mech.CarrierPart then partIds[mech.CarrierPart] = id end
		if mech.PivotPart then partIds[mech.PivotPart] = id end
	end
	for part, id in partIds do
		if (membership[id] or 0) > 0 then
			velocities[part] = { Linear = part.AssemblyLinearVelocity, Angular = part.AssemblyAngularVelocity, Center = part.AssemblyCenterOfMass }
		end
	end
	local models = {}
	for index, group in fragments do
		local model = Instance.new("Model")
		model.Name = "VehicleFragment"
		model:SetAttribute("VehicleDebris", true)
		model:SetAttribute("OwnerUserId", runtime.OwnerUserId)
		model:SetAttribute("RuntimeId", runtime.RuntimeId)
		model.Parent = root.Parent
		models[index] = model
		table.insert(debris, { Model = model, Runtime = runtime, PieceIds = group, ExpiresAt = clock() + Config.DebrisLifetimeSeconds })
	end
	-- Occupants must leave before joints are cut or seats are reparented.
	for id, groupIndex in membership do
		if groupIndex == 0 then continue end
		local part = runtime.Parts[id]
		part.IsDestroyed = broken[id] == true
		part.IsDetached = true
		part.IsFunctional = false
		table.insert(result.DetachedParts, id)
		if part.ModelInstance then
			for _, d in part.ModelInstance:GetDescendants() do
				if d:IsA("Seat") or d:IsA("VehicleSeat") then Seats.DetachSeat(d) end
			end
			Items.DestroyPart(runtime, part, part.ModelInstance)
		end
	end
	if driverId and membership[driverId] ~= 0 then
		runtime.DriverSeatDestroyed = true
		runtime.DriverSeatPart = nil
		Powertrain.SetControlOverrideForTests(runtime.OwnerUserId, nil)
		Boosters.CutBoostForPlayer(runtime.OwnerUserId, "DriverSeatDestroyed")
		Wheels.ClearDriveCommands(runtime.OwnerUserId)
	end
	-- Cut only edges across components. Preserve internal welds and passive mechanisms.
	for _, joint in root:GetDescendants() do
		local a, b = nil, nil
		if joint:IsA("WeldConstraint") or joint:IsA("JointInstance") or joint:IsA("NoCollisionConstraint") then
			a, b = joint.Part0, joint.Part1
		elseif joint:IsA("Constraint") then
			a = if joint.Attachment0 then joint.Attachment0.Parent else nil
			b = if joint.Attachment1 then joint.Attachment1.Parent else nil
		end
		local ia, ib = partIds[a], partIds[b]
		local ga, gb = if ia then membership[ia] else nil, if ib then membership[ib] else nil
		if ga ~= nil and gb ~= nil then
			if ga ~= gb then joint:Destroy()
			elseif ga > 0 then
				if joint:IsA("HingeConstraint") then joint.ActuatorType = Enum.ActuatorType.None; joint.MotorMaxTorque = 0; joint.ServoMaxTorque = 0 end
				joint.Parent = models[ga]
			end
		elseif joint:IsA("VectorForce") and ga and ga > 0 then
			joint.Force = Vector3.zero
			joint.Enabled = false
		elseif (a and b) and ((ga and ga > 0 and gb == nil) or (gb and gb > 0 and ga == nil)) then
			joint:Destroy()
		end
	end
	for id, groupIndex in membership do
		if groupIndex == 0 then continue end
		local part = runtime.Parts[id]
		local model = part.ModelInstance
		local mech = if runtime.WheelMechanisms then runtime.WheelMechanisms[id] else nil
		if mech then
			for _, auxiliary in { mech.CarrierPart, mech.PivotPart } do if auxiliary then auxiliary.Parent = models[groupIndex] end end
			local rigFolder = root:FindFirstChild("WheelRig_" .. id, true)
			if rigFolder then rigFolder.Parent = models[groupIndex] end
		end
		Wheels.DetachPiece(runtime, id)
		Powertrain.DetachPiece(runtime, id)
		Boosters.DetachPiece(runtime, id)
		Aerodynamics.DetachPiece(runtime, id)
		if model then model:SetAttribute("IsDetached", true); model:SetAttribute("IsDestroyed", broken[id] == true); model.Parent = models[groupIndex] end
	end
	local updatedAssemblies = {}
	for part, velocity in velocities do
		if part.Parent then
			part:SetAttribute("VehicleDebris", true)
			part.CollisionGroup = Config.DebrisCollisionGroup
			part.CanTouch = false
			part.Anchored = false
			local assembly = part.AssemblyRootPart or part
			if not updatedAssemblies[assembly] then
				updatedAssemblies[assembly] = true
				assembly.AssemblyLinearVelocity = velocity.Linear + velocity.Angular:Cross(assembly.AssemblyCenterOfMass - velocity.Center)
				assembly.AssemblyAngularVelocity = velocity.Angular
			end
			local canSet = part:CanSetNetworkOwnership()
			if canSet then part:SetNetworkOwner(nil) end
		end
	end
	for id, neighbors in runtime.PieceAdjacencyById or {} do
		if membership[id] and membership[id] > 0 then runtime.PieceAdjacencyById[id] = {}
		else
			local kept = {}
			for _, other in neighbors do if membership[other] == 0 then table.insert(kept, other) end end
			runtime.PieceAdjacencyById[id] = kept
		end
	end
	for _, field in { "Joints", "WheelConstraints" } do
		local kept = {}
		for _, joint in runtime[field] or {} do if joint.Parent and joint:IsDescendantOf(root) then table.insert(kept, joint) end end
		runtime[field] = kept
	end
	if runtime.DriverSeatDestroyed or not main then
		runtime.PrimaryPart = if main then runtime.Parts[main[1]].PrimaryPart else nil
		root.PrimaryPart = runtime.PrimaryPart
	end
	if not main then
		runtime.IsDestroyed = true
		runtime.DriverSeatDestroyed = true
		runtime.DriverSeatPart = nil
		Powertrain.SetControlOverrideForTests(runtime.OwnerUserId, nil)
		Boosters.CutBoostForPlayer(runtime.OwnerUserId, "VehicleDestroyed")
		Wheels.ClearDriveCommands(runtime.OwnerUserId)
	end
	root:SetAttribute("IsDestroyed", runtime.IsDestroyed == true)
	root:SetAttribute("DriverSeatDestroyed", runtime.DriverSeatDestroyed == true)
	root:SetAttribute("DestructionLastMs", (os.clock() - started) * 1000)
	entry.Processing = false
	if entry.OnChanged then entry.OnChanged(runtime) end
	Service.CleanupExpired()
	if #debris > 0 and not heartbeat and RunService:IsRunning() then
		heartbeat = RunService.Heartbeat:Connect(function() Service.CleanupExpired() end)
	end
end

function Service.UnregisterRuntime(runtime)
	entries[runtime.RuntimeId] = nil
	for _, fragment in debris do if fragment.Runtime == runtime then removeFragment(fragment) end end
	Service.CleanupExpired()
end

function Service.GetStats()
	local count, pieces = 0, 0
	for _ in entries do count += 1 end
	for _, fragment in debris do pieces += #fragment.PieceIds end
	return { Runtimes = count, Fragments = #debris, Pieces = pieces, Connections = if heartbeat then 1 else 0 }
end

function Service._SetClockForTests(fn: (() -> number)?)
	clock = fn or os.clock
end

function Service.Init()
	-- CollisionGroup registration se asegura al registrar un VehicleRuntime.
end

function Service.Start()
end

function Service._ResetForTests()
	for _, fragment in table.clone(debris) do
		removeFragment(fragment)
	end
	table.clear(debris)
	table.clear(entries)
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
	clock = os.clock
end

return Service

