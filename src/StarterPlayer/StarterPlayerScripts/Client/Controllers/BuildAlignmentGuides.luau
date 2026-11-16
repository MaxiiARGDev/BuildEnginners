--!strict
--[=[
	BuildAlignmentGuides
	Renderiza localmente en el cliente las guías de alineación inteligente
	(centros, caras, bordes, ejes principales, puntos de conexión Conn_*) mediante
	un pool reutilizable de LineHandleAdornment y SphereHandleAdornment sin Parts.
]=]

local Workspace = game:GetService("Workspace")

local BuildAlignmentMath = require(game:GetService("ReplicatedStorage").Shared.Building.BuildAlignmentMath)

local BuildAlignmentGuides = {}

local MAX_GUIDE_LINES = 24
local MAX_GUIDE_MARKERS = 12

local _containerFolder: Folder? = nil
local _linePool: { LineHandleAdornment } = {}
local _markerPool: { SphereHandleAdornment } = {}
local _activeLineCount = 0
local _activeMarkerCount = 0
local _lastAdornee: BasePart? = nil

local function getVisualParent(): Instance
	return Workspace.CurrentCamera or Workspace
end

local function ensurePoolInitialized(buildZone: BasePart)
	local host = getVisualParent()
	if _containerFolder and _containerFolder.Parent ~= host then
		_containerFolder:Destroy()
		_containerFolder = nil
		table.clear(_linePool)
		table.clear(_markerPool)
	end

	if not _containerFolder then
		local folder = Instance.new("Folder")
		folder.Name = "BuildAlignmentGuidesPool"
		folder.Parent = host
		_containerFolder = folder

		for i = 1, MAX_GUIDE_LINES do
			local line = Instance.new("LineHandleAdornment")
			line.Name = `AlignGuideLine_{i}`
			line.AlwaysOnTop = false
			line.ZIndex = 3
			line.Visible = false
			line.Length = 1
			line.Parent = folder
			_linePool[i] = line
		end

		for i = 1, MAX_GUIDE_MARKERS do
			local sphere = Instance.new("SphereHandleAdornment")
			sphere.Name = `AlignGuideMarker_{i}`
			sphere.AlwaysOnTop = false
			sphere.ZIndex = 4
			sphere.Visible = false
			sphere.Radius = 0.15
			sphere.Parent = folder
			_markerPool[i] = sphere
		end
	end

	if _lastAdornee ~= buildZone then
		_lastAdornee = buildZone
		for _, line in ipairs(_linePool) do
			line.Adornee = buildZone
		end
		for _, sphere in ipairs(_markerPool) do
			sphere.Adornee = buildZone
		end
	end
end

local function lookCFrameLocal(startPos: Vector3, endPos: Vector3): (CFrame, number)
	local delta = endPos - startPos
	local len = delta.Magnitude
	if len < 1e-4 then
		return CFrame.new(startPos), 0
	end
	local dir = delta / len
	local up = if math.abs(dir.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(startPos, endPos, up), len
end

function BuildAlignmentGuides.Render(
	buildZone: BasePart,
	guides: { BuildAlignmentMath.AlignmentGuideSegment },
	markers: { BuildAlignmentMath.AlignmentMarker },
	assemblyOffsetCFrame: CFrame?
)
	if not buildZone or not buildZone.Parent then
		BuildAlignmentGuides.Hide()
		return
	end

	ensurePoolInitialized(buildZone)

	local offsetCF = assemblyOffsetCFrame
	local lineCount = math.min(#guides, MAX_GUIDE_LINES)
	for i = 1, lineCount do
		local g = guides[i]
		local line = _linePool[i]
		local pStart = if offsetCF then offsetCF:PointToWorldSpace(g.StartLocal) else g.StartLocal
		local pEnd = if offsetCF then offsetCF:PointToWorldSpace(g.EndLocal) else g.EndLocal
		local cf, len = lookCFrameLocal(pStart, pEnd)
		if len >= 0.04 then
			line.Adornee = buildZone
			line.CFrame = cf
			line.Length = len
			line.Color3 = g.Color
			line.Thickness = g.Thickness
			line.Transparency = 0.1
			line.Visible = true
		else
			line.Visible = false
		end
	end
	for i = lineCount + 1, MAX_GUIDE_LINES do
		_linePool[i].Visible = false
	end

	local markerCount = math.min(#markers, MAX_GUIDE_MARKERS)
	for i = 1, markerCount do
		local m = markers[i]
		local sphere = _markerPool[i]
		local markerPos = if offsetCF then offsetCF:PointToWorldSpace(m.PositionLocal) else m.PositionLocal
		sphere.Adornee = buildZone
		sphere.CFrame = CFrame.new(markerPos)
		sphere.Radius = m.Radius
		sphere.Color3 = m.Color
		sphere.Transparency = 0.15
		sphere.Visible = true
	end
	for i = markerCount + 1, MAX_GUIDE_MARKERS do
		_markerPool[i].Visible = false
	end

	_activeLineCount = lineCount
	_activeMarkerCount = markerCount
end

function BuildAlignmentGuides.Hide()
	_activeLineCount = 0
	_activeMarkerCount = 0
	for _, line in ipairs(_linePool) do
		line.Visible = false
	end
	for _, sphere in ipairs(_markerPool) do
		sphere.Visible = false
	end
end

function BuildAlignmentGuides.Destroy()
	_activeLineCount = 0
	_activeMarkerCount = 0
	_lastAdornee = nil
	if _containerFolder then
		_containerFolder:Destroy()
		_containerFolder = nil
	end
	table.clear(_linePool)
	table.clear(_markerPool)
end

function BuildAlignmentGuides.GetDebugStats(): { ActiveLines: number, ActiveMarkers: number, HasContainer: boolean }
	return {
		ActiveLines = _activeLineCount,
		ActiveMarkers = _activeMarkerCount,
		HasContainer = _containerFolder ~= nil,
	}
end

return BuildAlignmentGuides
