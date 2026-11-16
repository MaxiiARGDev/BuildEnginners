--!strict
-- Registro autoritativo de asientos. El cliente nunca decide qué ocupante expulsar.
local Workspace = game:GetService("Workspace")
local GameConfig = require(game.ReplicatedStorage.Shared.Config.GameConfig)
local Service = { Name = "VehicleSeatService" }
local entries: { [Instance]: any } = {}
local tempSeats: { [Seat]: boolean } = {}
local tempWatchers: { [RBXScriptConnection]: boolean } = {}

local function clearHumanoidSeatCooldown(_seat: BasePart, hum: Humanoid, destroyImmediately: boolean?, anchorPosition: Vector3?)
	if not hum.Parent then
		return
	end
	hum.Sit = false
	local tmpSeat = Instance.new("Seat")
	tmpSeat.Archivable = false
	tmpSeat.Anchored = true
	tmpSeat.CanCollide = false
	tmpSeat.CanTouch = false
	tmpSeat.CanQuery = false
	tmpSeat.Transparency = 1
	tmpSeat.Size = Vector3.new(0.2, 0.2, 0.2)
	tmpSeat.Position = anchorPosition or Vector3.new(0, 50000, 0)
	tmpSeat.Parent = Workspace
	tempSeats[tmpSeat] = true
	pcall(function()
		tmpSeat:Sit(hum)
	end)
	for _, weld in tmpSeat:GetChildren() do
		if weld.Name == "SeatWeld" and weld:IsA("JointInstance") then
			weld:Destroy()
		end
	end
	hum.Sit = false
	if destroyImmediately then
		tmpSeat.Disabled = true
		tempSeats[tmpSeat] = nil
		if tmpSeat.Parent then
			tmpSeat:Destroy()
		end
		return
	end
	-- Mantener un watcher corto para capturar el callback diferido de tmpSeat:Sit() aunque task.delay(0.05) dispare antes.
	local alive = true
	local sitConn: RBXScriptConnection? = nil
	local spConn: RBXScriptConnection? = nil
	local function stopWatch()
		if not alive then
			return
		end
		alive = false
		if sitConn then
			tempWatchers[sitConn] = nil
			sitConn:Disconnect()
			sitConn = nil
		end
		if spConn then
			tempWatchers[spConn] = nil
			spConn:Disconnect()
			spConn = nil
		end
	end
	local spC = hum:GetPropertyChangedSignal("SeatPart"):Connect(function()
		local sp = hum.SeatPart
		if sp ~= nil and sp ~= tmpSeat and not (sp:IsA("Seat") and tempSeats[sp]) and sp.Parent ~= nil then
			stopWatch()
		end
	end)
	spConn = spC
	tempWatchers[spC] = true

	local sitC = hum:GetPropertyChangedSignal("Sit"):Connect(function()
		if not alive then
			return
		end
		local sp = hum.SeatPart
		if sp ~= nil and sp ~= tmpSeat and not (sp:IsA("Seat") and tempSeats[sp]) and sp.Parent ~= nil then
			stopWatch()
			return
		end
		if hum.Sit then
			hum.Sit = false
		end
	end)
	sitConn = sitC
	tempWatchers[sitC] = true

	task.delay(0.05, function()
		tempSeats[tmpSeat] = nil
		if tmpSeat.Parent then
			tmpSeat.Disabled = true
		end
		if hum.Parent and (hum.SeatPart == nil or hum.SeatPart == tmpSeat) then
			hum.Sit = false
		end
		if tmpSeat.Parent then
			tmpSeat:Destroy()
		end
	end)
	task.delay(0.12, stopWatch)
end

local function releaseGuard(entry)
	for _, conn in entry.HumanoidConnections do conn:Disconnect() end
	table.clear(entry.HumanoidConnections)
	local hum = entry.Humanoid
	if hum and hum.Parent then
		hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, entry.JumpWasEnabled)
	end
	entry.Humanoid = nil
end

local function canEnforceSeatGuard(entry, hum: Humanoid?): boolean
	if entry.Exiting or entries[entry.Seat] ~= entry then
		return false
	end
	if not entry.Seat.Parent or entry.Seat.Disabled then
		return false
	end
	local rt = entry.Runtime
	if rt and (rt.IsDestroyed or rt.State == GameConfig.Runtime.States.ReturningToWorkshop) then
		return false
	end
	if not hum or not hum.Parent or hum.Health <= 0 then
		return false
	end
	return true
end

local function reSeatBlockedHumanoid(entry, hum: Humanoid)
	if not canEnforceSeatGuard(entry, hum) then
		return
	end
	hum.Jump = false
	entry.Seat:Sit(hum)
	if entry.Seat.Occupant ~= hum and canEnforceSeatGuard(entry, hum) then
		clearHumanoidSeatCooldown(entry.Seat, hum, true)
		entry.Seat:Sit(hum)
	end
end

local function guard(entry)
	local hum = entry.Seat.Occupant
	if not hum then
		local prevHum = entry.Humanoid
		if not entry.ReSeating and canEnforceSeatGuard(entry, prevHum) then
			entry.ReSeating = true
			reSeatBlockedHumanoid(entry, prevHum :: Humanoid)
			entry.ReSeating = false
			if entry.Seat.Occupant == prevHum then
				return
			end
			if canEnforceSeatGuard(entry, prevHum) then
				task.defer(function()
					if not entry.ReSeating and entry.Humanoid == prevHum and entry.Seat.Occupant == nil and canEnforceSeatGuard(entry, prevHum) then
						entry.ReSeating = true
						reSeatBlockedHumanoid(entry, prevHum :: Humanoid)
						entry.ReSeating = false
						if entry.Seat.Occupant ~= prevHum then
							releaseGuard(entry)
						end
					end
				end)
				return
			end
		end
		releaseGuard(entry)
		return
	end
	releaseGuard(entry)
	if hum.Health <= 0 then return end
	entry.Humanoid = hum
	entry.JumpWasEnabled = hum:GetStateEnabled(Enum.HumanoidStateType.Jumping)
	hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	hum.Jump = false
	table.insert(entry.HumanoidConnections, hum:GetPropertyChangedSignal("Jump"):Connect(function()
		if not entry.Exiting and hum.Jump then hum.Jump = false end
	end))
	table.insert(entry.HumanoidConnections, hum:GetPropertyChangedSignal("Sit"):Connect(function()
		if hum.Sit or not canEnforceSeatGuard(entry, hum) then return end
		-- Bloquear una salida voluntaria ajena al flujo validado, tanto síncrona como si SeatWeld cae diferido.
		reSeatBlockedHumanoid(entry, hum)
		task.defer(function()
			if entry.Humanoid == hum and canEnforceSeatGuard(entry, hum) and (entry.Seat.Occupant ~= hum or not hum.Sit) then
				entry.ReSeating = true
				reSeatBlockedHumanoid(entry, hum)
				entry.ReSeating = false
			end
		end)
	end))
end

function Service.RegisterRuntime(runtime, fallbackSpawn: BasePart?)
	for _, d in runtime.RootModel:GetDescendants() do
		if (d:IsA("Seat") or d:IsA("VehicleSeat")) and not entries[d] then
			d:SetAttribute("ManagedVehicleSeat", true)
			local entry = { Seat = d, Runtime = runtime, FallbackSpawn = fallbackSpawn,
				HumanoidConnections = {}, Exiting = false, JumpWasEnabled = true }
			entries[d] = entry
			entry.Connection = d:GetPropertyChangedSignal("Occupant"):Connect(function() guard(entry) end)
			guard(entry)
		end
	end
end

function Service.GetRuntimeForHumanoid(hum: Humanoid?)
	local seat = if hum then hum.SeatPart else nil
	local entry = if seat then entries[seat] else nil
	return if entry and seat.Occupant == hum then entry.Runtime else nil
end

-- World-up candidates work with overturned vehicles; query includes the vehicle itself.
function Service.FindSafeExit(character: Model, seat: BasePart, runtime): CFrame?
	local boxCF, size = runtime.RootModel:GetBoundingBox()
	local charCF, charSize = character:GetBoundingBox()
	local pivotOffset = character:GetPivot().Position - charCF.Position
	local ray = RaycastParams.new()
	ray.FilterType = Enum.RaycastFilterType.Exclude
	ray.FilterDescendantsInstances = { character, runtime.RootModel }
	ray.RespectCanCollide = true
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { character }
	overlap.RespectCanCollide = true
	local fallbackExtent = if size.Magnitude < 0.01 then math.max(seat.Size.Magnitude, 4) else size.Magnitude
	local radius = fallbackExtent / 2 + charSize.Magnitude / 2 + GameConfig.Runtime.ExitSeatLateralOffsetStuds
	local center = if size.Magnitude < 0.01 then seat.Position else boxCF.Position
	for ring = 1, 3 do
		for index = 0, 7 do
			local angle = index * math.pi / 4
			local candidate = center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius * ring
			local start = Vector3.new(candidate.X, center.Y + fallbackExtent + charSize.Y, candidate.Z)
			local hit = Workspace:Raycast(start, Vector3.new(0, -(fallbackExtent * 2 + charSize.Y * 4 + radius * 3), 0), ray)
			if hit and hit.Normal.Y > 0.5 then
				local boxCenter = hit.Position + Vector3.new(0, charSize.Y / 2 + 0.15, 0)
				local clear = #Workspace:GetPartBoundsInBox(CFrame.new(boxCenter), charSize, overlap) == 0
				if clear then return CFrame.new(boxCenter + pivotOffset) end
			end
		end
	end
	return nil
end

function Service.ExitHumanoid(hum: Humanoid, forced: boolean?): (boolean, string?, CFrame?)
	local seat = hum.SeatPart
	local entry = if seat then entries[seat] else nil
	if not entry or seat.Occupant ~= hum or not hum.Parent then return false, "NotSeatedDriver", nil end
	local character = hum.Parent :: Model
	local destination = Service.FindSafeExit(character, seat, entry.Runtime)
	if not destination and forced and entry.FallbackSpawn and entry.FallbackSpawn.Parent then
		destination = entry.FallbackSpawn.CFrame + Vector3.new(0, character:GetExtentsSize().Y / 2 + entry.FallbackSpawn.Size.Y / 2, 0)
	end
	if not destination and not forced then return false, "NoSafeExitPosition", nil end
	entry.Exiting = true
	releaseGuard(entry)
	if not forced and seat and seat.Parent then
		local prevCanTouch = seat.CanTouch
		local touchSeq = (tonumber(seat:GetAttribute("_ExitTouchSeq")) or 0) + 1
		seat:SetAttribute("_ExitTouchSeq", touchSeq)
		seat.CanTouch = false
		task.delay(0.75, function()
			if seat.Parent and entries[seat] == entry and not seat.Disabled and seat:GetAttribute("_ExitTouchSeq") == touchSeq then
				seat.CanTouch = prevCanTouch
			end
		end)
	end
	hum.Jump = false
	hum.Sit = false
	for _, weld in seat:GetChildren() do
		if weld.Name == "SeatWeld" and weld:IsA("JointInstance") and
			((weld.Part1 and weld.Part1:IsDescendantOf(character)) or (weld.Part0 and weld.Part0:IsDescendantOf(character))) then
			weld:Destroy()
		end
	end
	if destination then character:PivotTo(destination) end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	clearHumanoidSeatCooldown(seat, hum, true, if destination then destination.Position else nil)
	if destination then character:PivotTo(destination) end
	if root and root:IsA("BasePart") then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	entry.Exiting = false
	return true, nil, destination
end

function Service.ForceEjectSeatOccupant(seat: BasePart, hum: Humanoid)
	local entry = entries[seat]
	if entry then
		entry.Exiting = true
		releaseGuard(entry)
	end
	hum.Jump = false
	hum.Sit = false
	for _, weld in seat:GetChildren() do
		if weld.Name == "SeatWeld" and weld:IsA("JointInstance") then
			local char = hum.Parent
			if not char or ((weld.Part1 and weld.Part1:IsDescendantOf(char)) or (weld.Part0 and weld.Part0:IsDescendantOf(char))) then
				weld:Destroy()
			end
		end
	end
	clearHumanoidSeatCooldown(seat, hum)
	if entry then
		entry.Exiting = false
	end
end

function Service.DetachSeat(seat)
	local entry = entries[seat]
	if not entry then return end
	if seat.Occupant then Service.ExitHumanoid(seat.Occupant, true) end
	seat.Disabled = true
	seat:SetAttribute("ManagedVehicleSeat", false)
	releaseGuard(entry)
	entry.Connection:Disconnect()
	entries[seat] = nil
end

function Service.UnregisterRuntime(runtime)
	for seat, entry in table.clone(entries) do
		if entry.Runtime == runtime then Service.DetachSeat(seat) end
	end
end

function Service.GetRegisteredSeatCount(): number
	local count = 0
	for _ in entries do count += 1 end
	return count
end

function Service.Init()
end

function Service.Start()
end

function Service._ResetForTests()
	for seat in table.clone(entries) do
		Service.DetachSeat(seat)
	end
	table.clear(entries)
	for tmpSeat in table.clone(tempSeats) do
		tempSeats[tmpSeat] = nil
		if tmpSeat.Parent then
			tmpSeat:Destroy()
		end
	end
	for conn in table.clone(tempWatchers) do
		tempWatchers[conn] = nil
		conn:Disconnect()
	end
end

return Service
