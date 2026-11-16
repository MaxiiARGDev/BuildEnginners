--!strict
--[=[
	BuildGridVisualizer
	Renderiza la cuadrícula contextual visual del editor exclusivamente en cliente mediante
	un pool reutilizable de LineHandleAdornment (cero creación de Parts por frame).
	- Se alinea a cualquier cara válida (horizontal o vertical) en coordenadas locales de BuildZone.
	- Muestra divisiones según la resolución seleccionada (1, 0.5, 0.25, 0.1).
	- Resalta centro y líneas principales + guía desde el centro de la pieza hasta el punto objetivo.
	- En modo Libre oculta las subdivisiones finas manteniendo referencia de ejes y guía objetivo.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildTransformMath = require(ReplicatedStorage.Shared.Building.BuildTransformMath)

export type GridRenderParams = {
	BuildZone: BasePart,
	SurfaceOriginLocal: Vector3,
	SurfaceNormalLocal: Vector3,
	CandidateLocalPos: Vector3,
	PieceExtents: Vector3,
	GridResolution: number,
	PositionMode: "Grid" | "Free",
	IsValid: boolean,
	AssemblyOffsetCFrame: CFrame?,
}

local BuildGridVisualizer = {}

local MAX_MINOR_LINES = 140
local SURFACE_LIFT_STUDS = 0.025

local _containerFolder: Folder? = nil
local _minorPool: { LineHandleAdornment } = {}
local _majorLines: { LineHandleAdornment } = {}
local _guideLine: LineHandleAdornment? = nil
local _targetDot: SphereHandleAdornment? = nil
local _activeLineCount = 0
local _activeMinorCount = 0
local _lastAdornee: BasePart? = nil

local function getVisualParent(): Instance
	return Workspace.CurrentCamera or Workspace
end

local function createLineAdornment(name: string, thickness: number, zIndex: number, alwaysOnTop: boolean): LineHandleAdornment
	local line = Instance.new("LineHandleAdornment")
	line.Name = name
	line.Thickness = thickness
	line.ZIndex = zIndex
	line.AlwaysOnTop = alwaysOnTop
	line.Visible = false
	line.Length = 1
	return line
end

local function ensurePoolInitialized(buildZone: BasePart)
	local parentHost = getVisualParent()
	if _containerFolder and _containerFolder.Parent ~= parentHost then
		_containerFolder:Destroy()
		_containerFolder = nil
		table.clear(_minorPool)
		table.clear(_majorLines)
		_guideLine = nil
		_targetDot = nil
	end

	if not _containerFolder then
		local existingPool = parentHost:FindFirstChild("BuildGridVisualizerPool")
		while existingPool do
			existingPool:Destroy()
			existingPool = parentHost:FindFirstChild("BuildGridVisualizerPool")
		end
		local folder = Instance.new("Folder")
		folder.Name = "BuildGridVisualizerPool"
		folder.Parent = parentHost
		_containerFolder = folder

		for i = 1, MAX_MINOR_LINES do
			local line = createLineAdornment(`GridLine_{i}`, 1.5, 0, false)
			line.Parent = folder
			_minorPool[i] = line
		end

		for i = 1, 4 do
			local major = createLineAdornment(`GridMajor_{i}`, 3, 1, false)
			major.Parent = folder
			_majorLines[i] = major
		end

		local guide = createLineAdornment("GridTargetGuide", 3.5, 2, false)
		guide.Color3 = GameConfig.Building.GridGuideColor
		guide.Parent = folder
		_guideLine = guide

		local dot = Instance.new("SphereHandleAdornment")
		dot.Name = "GridTargetDot"
		dot.Radius = 0.14
		dot.ZIndex = 2
		dot.AlwaysOnTop = false
		dot.Color3 = GameConfig.Building.GridGuideColor
		dot.Visible = false
		dot.Parent = folder
		_targetDot = dot
	end

	if _lastAdornee ~= buildZone then
		_lastAdornee = buildZone
		for _, line in ipairs(_minorPool) do
			line.Adornee = buildZone
		end
		for _, line in ipairs(_majorLines) do
			line.Adornee = buildZone
		end
		if _guideLine then
			_guideLine.Adornee = buildZone
		end
		if _targetDot then
			_targetDot.Adornee = buildZone
		end
	end
end

local function setLineSegment(
	line: LineHandleAdornment,
	startLocal: Vector3,
	endLocal: Vector3,
	color: Color3,
	transparency: number,
	thickness: number?,
	offsetCF: CFrame?
)
	local pStart = if offsetCF then offsetCF:PointToWorldSpace(startLocal) else startLocal
	local pEnd = if offsetCF then offsetCF:PointToWorldSpace(endLocal) else endLocal
	local delta = pEnd - pStart
	local len = delta.Magnitude
	if len < 1e-4 then
		line.Visible = false
		return
	end
	local dir = delta / len
	local up = if math.abs(dir:Dot(Vector3.yAxis)) > 0.99 then Vector3.xAxis else Vector3.yAxis
	line.CFrame = CFrame.lookAt(pStart, pEnd, up)
	line.Length = len
	line.Color3 = color
	line.Transparency = transparency
	if thickness then
		line.Thickness = thickness
	end
	line.Visible = true
end

function BuildGridVisualizer.Hide()
	if not _containerFolder then
		return
	end
	for _, line in ipairs(_minorPool) do
		line.Visible = false
	end
	for _, line in ipairs(_majorLines) do
		line.Visible = false
	end
	if _guideLine then
		_guideLine.Visible = false
	end
	if _targetDot then
		_targetDot.Visible = false
	end
	_activeLineCount = 0
	_activeMinorCount = 0
end

function BuildGridVisualizer.Render(params: GridRenderParams)
	local bz = params.BuildZone
	if not bz or not bz.Parent then
		BuildGridVisualizer.Hide()
		return
	end

	ensurePoolInitialized(bz)
	local offsetCF = params.AssemblyOffsetCFrame

	local tU, tV, n = BuildTransformMath.ComputeSurfaceAxes(params.SurfaceNormalLocal)
	local planeDist = params.SurfaceOriginLocal:Dot(n)
	local liftedPlaneOrigin = n * (planeDist + SURFACE_LIFT_STUDS)

	-- Proyectar el centro del candidato sobre el plano de la cara seleccionada
	local centerU = params.CandidateLocalPos:Dot(tU)
	local centerV = params.CandidateLocalPos:Dot(tV)
	local surfaceHitProj = liftedPlaneOrigin + tU * (params.SurfaceOriginLocal:Dot(tU)) + tV * (params.SurfaceOriginLocal:Dot(tV))

	local step = math.max(0.05, params.GridResolution)
	local maxPerAxis = math.floor((MAX_MINOR_LINES - 2) / 2)
	local rawSpan = GameConfig.Building.GridVisualHalfSpanStuds
	-- Limitar ventana de cuadrícula cuando step=0.1 para conservar líneas nítidas sin saturar el pool
	local halfSteps = math.clamp(math.floor(rawSpan / step), 4, math.floor((maxPerAxis - 1) / 2))
	local span = halfSteps * step

	local snappedCenterU = BuildTransformMath.SnapValue(centerU, step)
	local snappedCenterV = BuildTransformMath.SnapValue(centerV, step)
	local minU = snappedCenterU - span
	local maxU = snappedCenterU + span
	local minV = snappedCenterV - span
	local maxV = snappedCenterV + span

	local poolIdx = 0
	if params.PositionMode == GameConfig.Building.PositionModes.Grid then
		local minorCol = GameConfig.Building.GridMinorColor
		local majorCol = GameConfig.Building.GridMajorColor

		-- Líneas paralelas a V (variando U)
		for k = -halfSteps, halfSteps do
			local u = snappedCenterU + k * step
			local isMajor = math.abs(u - math.round(u)) < 1e-3
			local isAxis = math.abs(u) < 1e-3
			if not isAxis and poolIdx < MAX_MINOR_LINES then
				poolIdx += 1
				setLineSegment(
					_minorPool[poolIdx],
					liftedPlaneOrigin + tU * u + tV * minV,
					liftedPlaneOrigin + tU * u + tV * maxV,
					if isMajor then majorCol else minorCol,
					if isMajor then 0.2 else 0.55,
					if isMajor then 2.2 else 1.3,
					offsetCF
				)
			end
		end

		-- Líneas paralelas a U (variando V)
		for k = -halfSteps, halfSteps do
			local v = snappedCenterV + k * step
			local isMajor = math.abs(v - math.round(v)) < 1e-3
			local isAxis = math.abs(v) < 1e-3
			if not isAxis and poolIdx < MAX_MINOR_LINES then
				poolIdx += 1
				setLineSegment(
					_minorPool[poolIdx],
					liftedPlaneOrigin + tU * minU + tV * v,
					liftedPlaneOrigin + tU * maxU + tV * v,
					if isMajor then majorCol else minorCol,
					if isMajor then 0.2 else 0.55,
					if isMajor then 2.2 else 1.3,
					offsetCF
				)
			end
		end
	end

	for i = poolIdx + 1, MAX_MINOR_LINES do
		_minorPool[i].Visible = false
	end

	-- Ejes centrales principales sobre el plano + líneas locales del centro objetivo
	local axisColorU = if math.abs(tU.X) > 0.9 then GameConfig.Building.GridAxisXColor else GameConfig.Building.GridMajorColor
	local axisColorV = if math.abs(tV.Z) > 0.9 then GameConfig.Building.GridAxisZColor elseif math.abs(tV.Y) > 0.9 then GameConfig.Building.GizmoAxisYColor else GameConfig.Building.GridMajorColor

	-- Ejes de BuildZone pasando por 0 si caen dentro de la ventana, más cruz en celda actual
	setLineSegment(
		_majorLines[1],
		liftedPlaneOrigin + tU * minU + tV * 0,
		liftedPlaneOrigin + tU * maxU + tV * 0,
		axisColorU,
		0.15,
		3,
		offsetCF
	)
	setLineSegment(
		_majorLines[2],
		liftedPlaneOrigin + tU * 0 + tV * minV,
		liftedPlaneOrigin + tU * 0 + tV * maxV,
		axisColorV,
		0.15,
		3,
		offsetCF
	)

	-- Cruz local centrada en el punto de proyección del candidato sobre la superficie
	local projCand = liftedPlaneOrigin + tU * centerU + tV * centerV
	local crossRadius = math.max(0.4, math.min(2.0, math.max(params.PieceExtents.X, params.PieceExtents.Z) * 0.6))
	local validCol = if params.IsValid then GameConfig.Building.ValidColor else GameConfig.Building.InvalidColor
	setLineSegment(_majorLines[3], projCand - tU * crossRadius, projCand + tU * crossRadius, validCol, 0.1, 2.5, offsetCF)
	setLineSegment(_majorLines[4], projCand - tV * crossRadius, projCand + tV * crossRadius, validCol, 0.1, 2.5, offsetCF)

	-- Guía desde el centro de la pieza hasta el punto objetivo sobre la cara
	if _guideLine then
		local distGuide = (params.CandidateLocalPos - surfaceHitProj).Magnitude
		if distGuide > 0.02 then
			setLineSegment(_guideLine, params.CandidateLocalPos, surfaceHitProj, GameConfig.Building.GridGuideColor, 0.05, 3, offsetCF)
		else
			_guideLine.Visible = false
		end
	end

	if _targetDot then
		local dotPos = if offsetCF then offsetCF:PointToWorldSpace(projCand) else projCand
		_targetDot.CFrame = CFrame.new(dotPos)
		_targetDot.Color3 = validCol
		_targetDot.Transparency = 0.15
		_targetDot.Visible = true
	end

	_activeMinorCount = poolIdx
	_activeLineCount = poolIdx + 4
end

function BuildGridVisualizer.Destroy()
	if _containerFolder then
		_containerFolder:Destroy()
		_containerFolder = nil
	end
	local cam = Workspace.CurrentCamera
	if cam then
		for _, child in ipairs(cam:GetChildren()) do
			if child.Name == "BuildGridVisualizerPool" then
				child:Destroy()
			end
		end
	end
	for _, child in ipairs(Workspace:GetChildren()) do
		if child.Name == "BuildGridVisualizerPool" then
			child:Destroy()
		end
	end
	table.clear(_minorPool)
	table.clear(_majorLines)
	_guideLine = nil
	_targetDot = nil
	_lastAdornee = nil
	_activeLineCount = 0
	_activeMinorCount = 0
end

function BuildGridVisualizer.GetDebugStats(): {
	PoolCapacity: number,
	PooledLines: number,
	ActiveLines: number,
	ActiveMinorLines: number,
	HasContainer: boolean,
	AdorneeName: string?,
}
	return {
		PoolCapacity = #_minorPool + #_majorLines,
		PooledLines = #_minorPool + #_majorLines,
		ActiveLines = _activeLineCount,
		ActiveMinorLines = _activeMinorCount,
		HasContainer = _containerFolder ~= nil,
		AdorneeName = if _lastAdornee then _lastAdornee.Name else nil,
	}
end

return BuildGridVisualizer
