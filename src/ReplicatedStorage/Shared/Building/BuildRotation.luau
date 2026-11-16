--!strict
--[=[
	BuildRotation
	Cálculo determinista de rotaciones ortogonales en incrementos de 90°
	en el espacio local de BuildZone.
	- R: eje vertical local (Y)
	- T: primer eje horizontal local (X)
	- Y: segundo eje horizontal local (Z)
]=]

local STEP_RAD = math.rad(90)

local BuildRotation = {}

local function snapComponent(v: number): number
	local r = math.round(v)
	if r == 0 then
		return 0
	end
	return math.clamp(r, -1, 1)
end

local function snapUnitVector(vec: Vector3): Vector3
	return Vector3.new(snapComponent(vec.X), snapComponent(vec.Y), snapComponent(vec.Z))
end

local function isFinite(n: number): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

function BuildRotation.Identity(): CFrame
	return CFrame.identity
end

--[=[
	Comprueba que la rotación del CFrame sea una base derecha ortonormal (escala 1, sin cizalla/sesgo).
]=]
function BuildRotation.IsOrthonormalRotation(rotation: CFrame, tol: number?): boolean
	local eps = tol or 0.02
	local r = rotation.RightVector
	local u = rotation.UpVector
	local l = rotation.LookVector
	if not (isFinite(r.X) and isFinite(r.Y) and isFinite(r.Z) and isFinite(u.X) and isFinite(u.Y) and isFinite(u.Z) and isFinite(l.X) and isFinite(l.Y) and isFinite(l.Z)) then
		return false
	end
	if math.abs(r.Magnitude - 1) > eps or math.abs(u.Magnitude - 1) > eps or math.abs(l.Magnitude - 1) > eps then
		return false
	end
	if math.abs(r:Dot(u)) > eps or math.abs(r:Dot(l)) > eps or math.abs(u:Dot(l)) > eps then
		return false
	end
	-- Determinante positivo (+1, mano derecha)
	if r:Cross(u):Dot(-l) < (1 - eps) then
		return false
	end
	return true
end

--[=[
	Comprueba si una rotación corresponde a múltiplos ortogonales exactos de 90°.
]=]
function BuildRotation.IsOrthogonal90(rotation: CFrame, tol: number?): boolean
	if not BuildRotation.IsOrthonormalRotation(rotation, tol) then
		return false
	end
	local eps = tol or 0.02
	local ortho = BuildRotation.Orthonormalize(rotation)
	if (rotation.RightVector - ortho.RightVector).Magnitude > eps then
		return false
	end
	if (rotation.UpVector - ortho.UpVector).Magnitude > eps then
		return false
	end
	if (rotation.LookVector - ortho.LookVector).Magnitude > eps then
		return false
	end
	return true
end

--[=[
	Ortonormaliza una rotación cualquiera por Gram-Schmidt para eliminar deriva flotante
	conservando ángulos no múltiplos de 90°.
]=]
function BuildRotation.OrthonormalizeGeneral(rotation: CFrame): CFrame
	local r = rotation.RightVector
	if r.Magnitude < 1e-4 then
		r = Vector3.xAxis
	else
		r = r.Unit
	end
	local uRaw = rotation.UpVector - r * rotation.UpVector:Dot(r)
	local u = if uRaw.Magnitude < 1e-4 then (if math.abs(r.Y) < 0.9 then Vector3.yAxis:Cross(r).Unit else Vector3.zAxis:Cross(r).Unit) else uRaw.Unit
	local b = r:Cross(u).Unit
	return CFrame.fromMatrix(Vector3.zero, r, u, b)
end

--[=[
	Ortonormaliza una rotación en múltiplos de 90° para eliminar deriva de punto flotante.
]=]
function BuildRotation.Orthonormalize(rotation: CFrame): CFrame
	local right = snapUnitVector(rotation.RightVector)
	local up = snapUnitVector(rotation.UpVector)
	local back = snapUnitVector(-rotation.LookVector)
	return CFrame.fromMatrix(Vector3.zero, right, up, back)
end

-- Tecla R: rotar 90° sobre el eje vertical local (Y)
function BuildRotation.RotateY(current: CFrame, steps: number?): CFrame
	local n = steps or 1
	return BuildRotation.Orthonormalize(CFrame.Angles(0, STEP_RAD * n, 0) * current)
end

-- Tecla T: rotar 90° sobre el primer eje horizontal local (X)
function BuildRotation.RotateX(current: CFrame, steps: number?): CFrame
	local n = steps or 1
	return BuildRotation.Orthonormalize(CFrame.Angles(STEP_RAD * n, 0, 0) * current)
end

-- Tecla Y: rotar 90° sobre el segundo eje horizontal local (Z)
function BuildRotation.RotateZ(current: CFrame, steps: number?): CFrame
	local n = steps or 1
	return BuildRotation.Orthonormalize(CFrame.Angles(0, 0, STEP_RAD * n) * current)
end

--[=[
	Rota una orientación por un ángulo arbitrario (en grados) respecto a un eje local de BuildZone ("X"|"Y"|"Z").
]=]
function BuildRotation.RotateAxisDegrees(current: CFrame, axisName: string, degrees: number): CFrame
	local rad = math.rad(degrees)
	local deltaRot = if axisName == "X"
		then CFrame.Angles(rad, 0, 0)
		elseif axisName == "Y" then CFrame.Angles(0, rad, 0)
		else CFrame.Angles(0, 0, rad)
	local combined = deltaRot * current.Rotation
	if math.abs(degrees % 90) < 1e-4 and BuildRotation.IsOrthogonal90(current, 0.02) then
		return BuildRotation.Orthonormalize(combined)
	end
	return BuildRotation.OrthonormalizeGeneral(combined)
end

function BuildRotation.SnapAngleDegrees(angleDeg: number, incrementDeg: number): number
	if incrementDeg <= 0 then
		return angleDeg
	end
	local snapped = math.floor(angleDeg / incrementDeg + 0.5) * incrementDeg
	if snapped == 0 then
		return 0
	end
	return snapped
end

local function isAngleTripleMultiple(rx: number, ry: number, rz: number, stepDeg: number, tolDeg: number): boolean
	local dx = math.deg(rx)
	local dy = math.deg(ry)
	local dz = math.deg(rz)
	local sx = math.abs(dx - math.floor(dx / stepDeg + 0.5) * stepDeg)
	local sy = math.abs(dy - math.floor(dy / stepDeg + 0.5) * stepDeg)
	local sz = math.abs(dz - math.floor(dz / stepDeg + 0.5) * stepDeg)
	return sx <= tolDeg and sy <= tolDeg and sz <= tolDeg
end

--[=[
	Comprueba si una rotación corresponde a incrementos permitidos de `stepDeg` respecto a los ejes locales.
]=]
function BuildRotation.CheckRotationAlignedToStep(rotation: CFrame, stepDeg: number, tolDeg: number?): boolean
	if not BuildRotation.IsOrthonormalRotation(rotation) then
		return false
	end
	if stepDeg >= 89.9 then
		return BuildRotation.IsOrthogonal90(rotation)
	end
	local eps = tolDeg or 0.25
	local rot = rotation.Rotation

	local rx1, ry1, rz1 = rot:ToEulerAnglesXYZ()
	if isAngleTripleMultiple(rx1, ry1, rz1, stepDeg, eps) then
		return true
	end

	local ry2, rx2, rz2 = rot:ToEulerAnglesYXZ()
	if isAngleTripleMultiple(rx2, ry2, rz2, stepDeg, eps) then
		return true
	end

	local axis, angleRad = rot:ToAxisAngle()
	if angleRad < 1e-4 then
		return true
	end
	local absX = math.abs(axis.X)
	local absY = math.abs(axis.Y)
	local absZ = math.abs(axis.Z)
	local isCardinalAxis = (absX > 0.999 and absY < 0.01 and absZ < 0.01)
		or (absY > 0.999 and absX < 0.01 and absZ < 0.01)
		or (absZ > 0.999 and absX < 0.01 and absY < 0.01)
	if isCardinalAxis then
		local deg = math.deg(angleRad)
		if math.abs(deg - math.floor(deg / stepDeg + 0.5) * stepDeg) <= eps then
			return true
		end
	end

	return false
end

--[=[
	Calcula las dimensiones del bounding box alineado a los ejes locales de BuildZone
	para una pieza de tamaño `size` con orientación `rotation`.
]=]
function BuildRotation.GetRotatedExtents(size: Vector3, rotation: CFrame): Vector3
	local r = rotation.RightVector
	local u = rotation.UpVector
	local b = -rotation.LookVector

	local ex = math.abs(r.X) * size.X + math.abs(u.X) * size.Y + math.abs(b.X) * size.Z
	local ey = math.abs(r.Y) * size.X + math.abs(u.Y) * size.Y + math.abs(b.Y) * size.Z
	local ez = math.abs(r.Z) * size.X + math.abs(u.Z) * size.Y + math.abs(b.Z) * size.Z

	return Vector3.new(ex, ey, ez)
end

return BuildRotation

