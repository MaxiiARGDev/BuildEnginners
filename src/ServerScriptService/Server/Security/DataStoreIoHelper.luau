--!strict
--[=[
	DataStoreIoHelper
	Utilidad compartida de acceso autoritativo a DataStoreService con:
	- Bloqueo exclusivo por UserId contra escrituras/lecturas concurrentes.
	- Respaldo automático en memoria en Studio cuando "Studio access to APIs" está deshabilitado.
	- Aislamiento determinista para suites de prueba (_useMemoryStoreForTests).
	- Hooks explícitos de prueba (adaptador custom y simulación de fallos de lectura/escritura).
]=]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BlueprintSerializer = require(ReplicatedStorage.Shared.Building.BlueprintSerializer)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)

export type StorageAdapter = {
	Load: (userId: number, key: string) -> (boolean, any, string?),
	Save: (userId: number, key: string, payload: { [string]: any }) -> (boolean, string?),
}

export type StoreHandle = {
	IsBusyForUser: (userId: number) -> boolean,
	GetLastStorageMode: () -> string,
	SaveRaw: (userId: number, serialized: { [string]: any }) -> (boolean, string?, string?),
	LoadRaw: (userId: number, readLegacyInLive: boolean?) -> (boolean, any, string?, string?),
	SetStorageAdapterForTests: (adapter: StorageAdapter?) -> (),
	SetSimulateWriteFailureForTests: (shouldFail: (boolean | string)?) -> (),
	SetSimulateLoadFailureForTests: (shouldFail: (boolean | string)?) -> (),
	SeedLegacyRawForTests: (userId: number, rawLegacyData: any) -> (),
	GetRawMemorySnapshotForTests: (userId: number) -> { [string]: any }?,
	SetUseMemoryStoreForTests: (enabled: boolean?) -> (),
	ResetForTests: (clearSavedMemory: boolean?) -> (),
}

local DataStoreIoHelper = {}

local function makePlayerKey(userId: number): string
	return `player_{userId}`
end

local function isStudioApiAccessDisabledError(errStr: string): boolean
	local lower = string.lower(errStr)
	return string.find(lower, "studio access to apis", 1, true) ~= nil
		or string.find(lower, "error code: 7", 1, true) ~= nil
		or string.find(lower, "http requests can only be executed", 1, true) ~= nil
end

function DataStoreIoHelper.CreateStoreHandle(options: {
	PrimaryStoreName: string,
	LegacyStoreName: string?,
}): StoreHandle
	local _ioLocksByUserId: { [number]: boolean } = {}
	local _studioMemoryStore: { [string]: { [string]: any } } = {}
	local _studioLegacyMemoryStore: { [string]: any } = {}
	local _lastStorageMode = "DataStore"

	local _customAdapter: StorageAdapter? = nil
	local _simulateWriteFailure: (boolean | string)? = nil
	local _simulateLoadFailure: (boolean | string)? = nil
	local _useMemoryStoreForTests = false

	local _cachedPrimaryDs: DataStore? = nil
	local _cachedLegacyDs: DataStore? = nil
	local _dataStoreApiBlockedInStudio = false

	local function getDataStores(): (DataStore?, DataStore?, boolean, string?)
		if _dataStoreApiBlockedInStudio then
			return nil, nil, true, nil
		end
		if _cachedPrimaryDs then
			return _cachedPrimaryDs, _cachedLegacyDs, false, nil
		end

		local okPrimary, primaryOrErr = pcall(function()
			return DataStoreService:GetDataStore(options.PrimaryStoreName)
		end)
		if not okPrimary then
			local msg = tostring(primaryOrErr)
			if RunService:IsStudio() and isStudioApiAccessDisabledError(msg) then
				_dataStoreApiBlockedInStudio = true
				return nil, nil, true, nil
			end
			return nil, nil, false, msg
		end

		_cachedPrimaryDs = primaryOrErr :: DataStore
		if type(options.LegacyStoreName) == "string" and #options.LegacyStoreName > 0 then
			local okLegacy, legacyOrErr = pcall(function()
				return DataStoreService:GetDataStore(options.LegacyStoreName :: string)
			end)
			if okLegacy then
				_cachedLegacyDs = legacyOrErr :: DataStore
			end
		end
		return _cachedPrimaryDs, _cachedLegacyDs, false, nil
	end

	local handle = {} :: StoreHandle

	function handle.IsBusyForUser(userId: number): boolean
		return _ioLocksByUserId[userId] == true
	end

	function handle.GetLastStorageMode(): string
		return _lastStorageMode
	end

	function handle.SaveRaw(userId: number, serialized: { [string]: any }): (boolean, string?, string?)
		if type(userId) ~= "number" or userId == 0 then
			return false, BuildProtocol.ErrorCodes.InvalidPayload, "UserId inválido para persistencia"
		end
		if _ioLocksByUserId[userId] then
			return false, BuildProtocol.ErrorCodes.OperationInProgress, "Persistencia en curso para este jugador"
		end

		_ioLocksByUserId[userId] = true
		local key = makePlayerKey(userId)

		local okRun, saveOk, errCode, errMsg = pcall(function(): (boolean, string?, string?)
			if _simulateWriteFailure ~= nil and _simulateWriteFailure ~= false then
				local reason = if type(_simulateWriteFailure) == "string"
					then _simulateWriteFailure
					else "Fallo simulado al persistir datos en DataStore"
				return false, BuildProtocol.ErrorCodes.PersistenceFailed, reason
			end

			if _customAdapter then
				_lastStorageMode = "TestAdapter"
				local okAd, adErr = _customAdapter.Save(userId, key, serialized)
				if not okAd then
					return false, BuildProtocol.ErrorCodes.PersistenceFailed, adErr or "Error en adaptador de almacenamiento"
				end
				return true, nil, nil
			end

			if _useMemoryStoreForTests or not RunService:IsRunning() then
				_lastStorageMode = "StudioMemoryFallback"
				_studioMemoryStore[key] = serialized
				return true, nil, nil
			end

			local primaryDs, _, apiBlocked, dsInitErr = getDataStores()
			if apiBlocked then
				_lastStorageMode = "StudioMemoryFallback"
				_studioMemoryStore[key] = serialized
				return true, nil, nil
			end
			if not primaryDs then
				return false, BuildProtocol.ErrorCodes.PersistenceFailed, dsInitErr or "DataStore no disponible"
			end

			_lastStorageMode = "DataStore"
			local writeOk, writeErr = pcall(function()
				primaryDs:UpdateAsync(key, function(_oldData)
					return serialized
				end)
			end)
			if not writeOk then
				local errStr = tostring(writeErr)
				if RunService:IsStudio() and isStudioApiAccessDisabledError(errStr) then
					_dataStoreApiBlockedInStudio = true
					_lastStorageMode = "StudioMemoryFallback"
					_studioMemoryStore[key] = serialized
					return true, nil, nil
				end
				return false, BuildProtocol.ErrorCodes.PersistenceFailed, `No se pudo guardar en DataStore: {errStr}`
			end

			return true, nil, nil
		end)

		_ioLocksByUserId[userId] = nil
		if not okRun then
			return false, BuildProtocol.ErrorCodes.PersistenceFailed, tostring(saveOk)
		end
		return saveOk, errCode, errMsg
	end

	function handle.LoadRaw(userId: number, readLegacyInLive: boolean?): (boolean, any, string?, string?)
		if type(userId) ~= "number" or userId == 0 then
			return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "UserId inválido para carga"
		end
		if _ioLocksByUserId[userId] then
			return false, nil, BuildProtocol.ErrorCodes.OperationInProgress, "Carga de persistencia en curso"
		end

		_ioLocksByUserId[userId] = true
		local key = makePlayerKey(userId)

		local okRun, loadOk, rawOut, errCode, errMsg = pcall(function(): (boolean, any, string?, string?)
			if _simulateLoadFailure ~= nil and _simulateLoadFailure ~= false then
				local reason = if type(_simulateLoadFailure) == "string"
					then _simulateLoadFailure
					else "Fallo simulado al leer datos de DataStore"
				return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, reason
			end

			local rawData: any = nil
			if _customAdapter then
				_lastStorageMode = "TestAdapter"
				local okAd, adData, adErr = _customAdapter.Load(userId, key)
				if not okAd then
					return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, adErr or "Error leyendo almacenamiento"
				end
				rawData = adData
			elseif _useMemoryStoreForTests or not RunService:IsRunning() then
				_lastStorageMode = "StudioMemoryFallback"
				local memV2 = _studioMemoryStore[key]
				local memV1 = _studioLegacyMemoryStore[key]
				rawData = if memV2 ~= nil
					then BlueprintSerializer.DeepCloneTable(memV2)
					else BlueprintSerializer.DeepCloneTable(memV1)
			else
				local primaryDs, legacyDs, apiBlocked, dsInitErr = getDataStores()
				if apiBlocked then
					_lastStorageMode = "StudioMemoryFallback"
					local memV2 = _studioMemoryStore[key]
					local memV1 = _studioLegacyMemoryStore[key]
					rawData = if memV2 ~= nil
						then BlueprintSerializer.DeepCloneTable(memV2)
						else BlueprintSerializer.DeepCloneTable(memV1)
				elseif not primaryDs then
					return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, dsInitErr or "DataStore no disponible"
				else
					_lastStorageMode = "DataStore"
					local readOk, dsValOrErr = pcall(function()
						return primaryDs:GetAsync(key)
					end)
					if not readOk then
						local errStr = tostring(dsValOrErr)
						if RunService:IsStudio() and isStudioApiAccessDisabledError(errStr) then
							_dataStoreApiBlockedInStudio = true
							_lastStorageMode = "StudioMemoryFallback"
							local memV2 = _studioMemoryStore[key]
							local memV1 = _studioLegacyMemoryStore[key]
							rawData = if memV2 ~= nil
								then BlueprintSerializer.DeepCloneTable(memV2)
								else BlueprintSerializer.DeepCloneTable(memV1)
						else
							return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, `Error al leer DataStore: {errStr}`
						end
					else
						rawData = dsValOrErr
						if rawData == nil and readLegacyInLive == true and legacyDs then
							local legOk, legVal = pcall(function()
								return legacyDs:GetAsync(key)
							end)
							if legOk and legVal ~= nil then
								rawData = legVal
							end
						end
						if rawData == nil and _studioLegacyMemoryStore[key] ~= nil then
							rawData = BlueprintSerializer.DeepCloneTable(_studioLegacyMemoryStore[key])
						end
					end
				end
			end

			return true, rawData, nil, nil
		end)

		_ioLocksByUserId[userId] = nil
		if not okRun then
			return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, tostring(loadOk)
		end
		return loadOk, rawOut, errCode, errMsg
	end

	function handle.SetStorageAdapterForTests(adapter: StorageAdapter?)
		_customAdapter = adapter
	end

	function handle.SetSimulateWriteFailureForTests(shouldFail: (boolean | string)?)
		_simulateWriteFailure = shouldFail
	end

	function handle.SetSimulateLoadFailureForTests(shouldFail: (boolean | string)?)
		_simulateLoadFailure = shouldFail
	end

	function handle.SeedLegacyRawForTests(userId: number, rawLegacyData: any)
		local key = makePlayerKey(userId)
		_studioMemoryStore[key] = nil
		_studioLegacyMemoryStore[key] = BlueprintSerializer.DeepCloneTable(rawLegacyData) or rawLegacyData
	end

	function handle.GetRawMemorySnapshotForTests(userId: number): { [string]: any }?
		local key = makePlayerKey(userId)
		local data = _studioMemoryStore[key]
		return if data then BlueprintSerializer.DeepCloneTable(data) else nil
	end

	function handle.SetUseMemoryStoreForTests(enabled: boolean?)
		_useMemoryStoreForTests = enabled == true
	end

	function handle.ResetForTests(clearSavedMemory: boolean?)
		table.clear(_ioLocksByUserId)
		_customAdapter = nil
		_simulateWriteFailure = nil
		_simulateLoadFailure = nil
		_useMemoryStoreForTests = true
		if clearSavedMemory ~= false then
			table.clear(_studioMemoryStore)
			table.clear(_studioLegacyMemoryStore)
		end
	end

	return handle
end

return DataStoreIoHelper

