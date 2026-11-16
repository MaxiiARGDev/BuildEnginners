--!strict
--[=[
	GameConfigService
	Servicio centralizado y autoritativo de configuración administrativa persistente (Fase 5.3.3).

	Dominios arquitectónicos previstos:
	  - "Crates"      (IMPLEMENTADO Y ACTIVO en Fase 5.3.3)
	  - "Economy"     (Reservado para fases futuras)
	  - "Events"      (Reservado para fases futuras)
	  - "Multipliers" (Reservado para fases futuras)
	  - "Rewards"     (Reservado para fases futuras)

	Capas de resolución efectiva:
	  1. Valores predeterminados declarativos (`SpecialCrateCatalogConfig`).
	  2. Overrides administrativos persistentes en DataStore independiente (`BuildEngineers_GameConfig_v1`).
	  3. Estado efímero de cada instancia de servidor (ej. `CurrentStock` en `ShopStockService`, nunca guardado aquí).

	Infraestructura multi-servidor:
	  - Escrituras atómicas mediante `DataStore:UpdateAsync` con `SchemaVersion` y `Revision` monotónica.
	  - Invalidación liviana vía `MessagingService` (solo transporta dominio/revisión, nunca sustituye al DataStore).
	  - Inmunidad ante mensajes antiguos o fallos transitorios de DataStore/MessagingService.
]=]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)
local LootBoxConfig = require(ReplicatedStorage.Shared.Config.LootBoxConfig)
local ShopProtocol = require(ReplicatedStorage.Shared.Building.ShopProtocol)
local SpecialCrateCatalogConfig = require(ReplicatedStorage.Shared.Config.SpecialCrateCatalogConfig)

export type ConfigDomain = "Crates" | "Economy" | "Events" | "Multipliers" | "Rewards"

-- Tipos de contrato preparados para el futuro `StarterGui.AdminPanelGui` (sin UI ni remotes públicos en Fase 5.3.3).
export type AdminPermissionScope =
	"Crates.EditConfig"
	| "Crates.ToggleEnabled"
	| "Crates.ResetConfig"
	| "Economy.GrantCurrency"
	| "Crates.GrantCrate"
	| "Events.Manage"
	| "Multipliers.Manage"

export type AdminAccessPolicy = {
	AuthorizedUserIds: { number },
	GroupId: number?,
	MinGroupRank: number?,
	PermissionScopes: { [string]: boolean },
}

export type AdminActorMetadata = {
	ActorUserId: number?,
	PermissionScope: AdminPermissionScope?,
}

export type PersistedDomainPayload = {
	SchemaVersion: number,
	Revision: number,
	UpdatedAt: number,
	LastModifiedByUserId: number?,
	Overrides: { [string]: { [string]: any } },
}

export type GlobalStorageAdapter = {
	Get: (key: string) -> (boolean, any, string?),
	Update: (key: string, transformFn: (oldValue: any) -> any) -> (boolean, any, string?),
}

export type MessagingBridge = {
	Publish: (topic: string, message: any) -> (boolean, string?),
	Subscribe: (topic: string, callback: (message: { Data: any }) -> ()) -> (() -> ())?,
}

local GameConfigService = {
	Name = "GameConfigService",
}

local DATASTORE_NAME = "BuildEngineers_GameConfig_v1"
local CRATES_DATASTORE_KEY = "domain_Crates_v1"
local MESSAGING_TOPIC = "BuildEngineers_ConfigSync_v1"
local SCHEMA_VERSION = 1

local ACTIVE_DOMAINS: { [string]: boolean } = {
	Crates = true,
}

local RESERVED_DOMAINS: { [string]: boolean } = {
	Crates = true,
	Economy = true,
	Events = true,
	Multipliers = true,
	Rewards = true,
}

local ALLOWED_CRATE_OVERRIDE_FIELDS: { [string]: boolean } = {
	Price = true,
	DeliverySeconds = true,
	RestockQuantity = true,
	StockMin = true,
	StockMax = true,
	RestockIntervalSeconds = true,
	Enabled = true,
	DisabledReason = true,
}

local LIMITS = {
	PriceMin = 1,
	PriceMax = 1000000000,
	DeliverySecondsMin = 1,
	DeliverySecondsMax = 604800,
	StockMin = 0,
	StockMax = 1000,
	RestockIntervalMin = 5,
	RestockIntervalMax = 86400,
	DisabledReasonMaxLen = 200,
}

local _initialized = false
local _started = false
local _clockFn: () -> number = os.time
local _jobId = if type(game.JobId) == "string" and #game.JobId > 0
	then game.JobId
	else ("studio_" .. string.sub(string.gsub(HttpService:GenerateGUID(false), "-", ""), 1, 10))

local _currentRevision = 0
local _currentOverrides: { [string]: LootBoxConfig.CrateOverridePatch } = {}
local _lastLoadError: string? = nil
local _lastStorageMode = "DataStore"

local _memoryStore: { [string]: PersistedDomainPayload } = {}
local _customAdapter: GlobalStorageAdapter? = nil
local _messagingBridge: MessagingBridge? = nil
local _messagingSubCleanup: any = nil
local _useMemoryStoreForTests = false
local _simulateLoadFailure: (boolean | string)? = nil
local _simulateWriteFailure: (boolean | string)? = nil
local _dataStoreBlockedInStudio = false
local _cachedDataStore: DataStore? = nil
local _ioBusy = false

local _configChangedListeners: { (domain: string, revision: number, reason: string) -> () } = {}

local function deepCloneOverrides(src: { [string]: any }?): { [string]: { [string]: any } }
	local out: { [string]: { [string]: any } } = {}
	if type(src) ~= "table" then
		return out
	end
	for boxId, patch in pairs(src) do
		if type(boxId) == "string" and type(patch) == "table" then
			local patchCopy: { [string]: any } = {}
			for k, v in pairs(patch) do
				if ALLOWED_CRATE_OVERRIDE_FIELDS[k] then
					patchCopy[k] = v
				end
			end
			if next(patchCopy) ~= nil then
				out[boxId] = patchCopy
			end
		end
	end
	return out
end

local function isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isStudioApiDisabledErr(errStr: string): boolean
	local lower = string.lower(errStr)
	return string.find(lower, "studio access to apis", 1, true) ~= nil
		or string.find(lower, "error code: 7", 1, true) ~= nil
		or string.find(lower, "http requests can only be executed", 1, true) ~= nil
end

local function getDataStore(): (DataStore?, boolean, string?)
	if _dataStoreBlockedInStudio then
		return nil, true, nil
	end
	if _cachedDataStore then
		return _cachedDataStore, false, nil
	end
	local ok, dsOrErr = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if not ok then
		local msg = tostring(dsOrErr)
		if RunService:IsStudio() and isStudioApiDisabledErr(msg) then
			_dataStoreBlockedInStudio = true
			return nil, true, nil
		end
		return nil, false, msg
	end
	_cachedDataStore = dsOrErr :: DataStore
	return _cachedDataStore, false, nil
end

local function clonePayload(p: PersistedDomainPayload): PersistedDomainPayload
	return {
		SchemaVersion = p.SchemaVersion,
		Revision = p.Revision,
		UpdatedAt = p.UpdatedAt,
		LastModifiedByUserId = p.LastModifiedByUserId,
		Overrides = deepCloneOverrides(p.Overrides),
	}
end

local function emitConfigChanged(domain: string, revision: number, reason: string)
	for _, cb in ipairs(table.clone(_configChangedListeners)) do
		task.spawn(cb, domain, revision, reason)
	end
end

local function publishInvalidation(domain: string, revision: number)
	local payload = {
		Domain = domain,
		Revision = revision,
		OriginJobId = _jobId,
		SentAt = _clockFn(),
	}
	if _messagingBridge then
		pcall(function()
			_messagingBridge.Publish(MESSAGING_TOPIC, payload)
		end)
		return
	end
	if not RunService:IsRunning() or _useMemoryStoreForTests then
		return
	end
	pcall(function()
		MessagingService:PublishAsync(MESSAGING_TOPIC, payload)
	end)
end

local function readPersistedCratesPayload(): (boolean, PersistedDomainPayload?, string?, string?)
	if _simulateLoadFailure ~= nil and _simulateLoadFailure ~= false then
		local reason = if type(_simulateLoadFailure) == "string"
			then _simulateLoadFailure
			else "Fallo simulado al leer configuración global"
		return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, reason
	end

	if _customAdapter then
		_lastStorageMode = "TestAdapter"
		local okAd, raw, adErr = _customAdapter.Get(CRATES_DATASTORE_KEY)
		if not okAd then
			return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, adErr or "Error en adaptador de configuración"
		end
		return true, raw, nil, nil
	end

	if _useMemoryStoreForTests or not RunService:IsRunning() then
		_lastStorageMode = "StudioMemoryFallback"
		local mem = _memoryStore[CRATES_DATASTORE_KEY]
		return true, if mem then clonePayload(mem) else nil, nil, nil
	end

	local ds, apiBlocked, dsErr = getDataStore()
	if apiBlocked then
		_lastStorageMode = "StudioMemoryFallback"
		local mem = _memoryStore[CRATES_DATASTORE_KEY]
		return true, if mem then clonePayload(mem) else nil, nil, nil
	end
	if not ds then
		return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, dsErr or "DataStore de configuración no disponible"
	end

	_lastStorageMode = "DataStore"
	local okGet, rawOrErr = pcall(function()
		return ds:GetAsync(CRATES_DATASTORE_KEY)
	end)
	if not okGet then
		local errStr = tostring(rawOrErr)
		if RunService:IsStudio() and isStudioApiDisabledErr(errStr) then
			_dataStoreBlockedInStudio = true
			_lastStorageMode = "StudioMemoryFallback"
			local mem = _memoryStore[CRATES_DATASTORE_KEY]
			return true, if mem then clonePayload(mem) else nil, nil, nil
		end
		return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, `Error GetAsync configuración: {errStr}`
	end
	return true, rawOrErr, nil, nil
end

local function updatePersistedCratesPayload(
	transformFn: (current: PersistedDomainPayload) -> PersistedDomainPayload
): (boolean, PersistedDomainPayload?, string?, string?)
	if _simulateWriteFailure ~= nil and _simulateWriteFailure ~= false then
		local reason = if type(_simulateWriteFailure) == "string"
			then _simulateWriteFailure
			else "Fallo simulado al guardar configuración global"
		return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, reason
	end

	local normalizeOld = function(oldRaw: any): PersistedDomainPayload
		if type(oldRaw) == "table" and type(oldRaw.Revision) == "number" then
			return {
				SchemaVersion = if type(oldRaw.SchemaVersion) == "number" then oldRaw.SchemaVersion else SCHEMA_VERSION,
				Revision = math.max(0, math.floor(oldRaw.Revision)),
				UpdatedAt = if type(oldRaw.UpdatedAt) == "number" then oldRaw.UpdatedAt else 0,
				LastModifiedByUserId = oldRaw.LastModifiedByUserId,
				Overrides = deepCloneOverrides(oldRaw.Overrides),
			}
		end
		return {
			SchemaVersion = SCHEMA_VERSION,
			Revision = 0,
			UpdatedAt = 0,
			LastModifiedByUserId = nil,
			Overrides = {},
		}
	end

	if _customAdapter then
		_lastStorageMode = "TestAdapter"
		local okAd, savedRaw, adErr = _customAdapter.Update(CRATES_DATASTORE_KEY, function(oldRaw)
			local cur = normalizeOld(oldRaw)
			return transformFn(cur)
		end)
		if not okAd then
			return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, adErr or "Error en Update de adaptador"
		end
		return true, normalizeOld(savedRaw), nil, nil
	end

	if _useMemoryStoreForTests or not RunService:IsRunning() then
		_lastStorageMode = "StudioMemoryFallback"
		local cur = normalizeOld(_memoryStore[CRATES_DATASTORE_KEY])
		local updated = clonePayload(transformFn(cur))
		_memoryStore[CRATES_DATASTORE_KEY] = updated
		return true, clonePayload(updated), nil, nil
	end

	local ds, apiBlocked, dsErr = getDataStore()
	if apiBlocked then
		_lastStorageMode = "StudioMemoryFallback"
		local cur = normalizeOld(_memoryStore[CRATES_DATASTORE_KEY])
		local updated = clonePayload(transformFn(cur))
		_memoryStore[CRATES_DATASTORE_KEY] = updated
		return true, clonePayload(updated), nil, nil
	end
	if not ds then
		return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, dsErr or "DataStore de configuración no disponible"
	end

	_lastStorageMode = "DataStore"
	local updatedResult: PersistedDomainPayload? = nil
	local okUpd, updErr = pcall(function()
		updatedResult = ds:UpdateAsync(CRATES_DATASTORE_KEY, function(oldRaw)
			local cur = normalizeOld(oldRaw)
			return transformFn(cur)
		end)
	end)
	if not okUpd then
		local errStr = tostring(updErr)
		if RunService:IsStudio() and isStudioApiDisabledErr(errStr) then
			_dataStoreBlockedInStudio = true
			_lastStorageMode = "StudioMemoryFallback"
			local cur = normalizeOld(_memoryStore[CRATES_DATASTORE_KEY])
			local updated = clonePayload(transformFn(cur))
			_memoryStore[CRATES_DATASTORE_KEY] = updated
			return true, clonePayload(updated), nil, nil
		end
		return false, nil, BuildProtocol.ErrorCodes.PersistenceFailed, `Error UpdateAsync configuración: {errStr}`
	end
	return true, if updatedResult then normalizeOld(updatedResult) else nil, nil, nil
end

local function validateDomainSupported(domain: string): (boolean, string?, string?)
	if type(domain) ~= "string" or not RESERVED_DOMAINS[domain] then
		return false, BuildProtocol.ErrorCodes.InvalidPayload, `Dominio de configuración desconocido: '{tostring(domain)}'.`
	end
	if not ACTIVE_DOMAINS[domain] then
		return false, "DomainNotImplemented", `El dominio '{domain}' está reservado para una fase posterior y aún no admite modificaciones.`
	end
	return true, nil, nil
end

function GameConfigService.GetSupportedDomains(): { { Domain: ConfigDomain, Active: boolean } }
	return {
		{ Domain = "Crates" :: ConfigDomain, Active = true },
		{ Domain = "Economy" :: ConfigDomain, Active = false },
		{ Domain = "Events" :: ConfigDomain, Active = false },
		{ Domain = "Multipliers" :: ConfigDomain, Active = false },
		{ Domain = "Rewards" :: ConfigDomain, Active = false },
	}
end

function GameConfigService.GetRevision(domain: string): number
	if domain == "Crates" then
		return _currentRevision
	end
	return 0
end

function GameConfigService.GetLastLoadError(): string?
	return _lastLoadError
end

function GameConfigService.GetConfig(domain: string, key: string): any?
	if domain ~= "Crates" then
		return nil
	end
	return LootBoxConfig.GetBox(key)
end

function GameConfigService.GetAllConfigs(domain: string): ({ [string]: any }?, number)
	if domain ~= "Crates" then
		return nil, 0
	end
	local byId: { [string]: any } = {}
	for _, def in ipairs(LootBoxConfig.GetAllBoxes()) do
		byId[def.BoxId] = def
	end
	return byId, _currentRevision
end

function GameConfigService.ValidateOverride(
	domain: string,
	key: string,
	changes: { [string]: any }
): (boolean, LootBoxConfig.CrateOverridePatch?, string?, string?)
	local okDom, domCode, domMsg = validateDomainSupported(domain)
	if not okDom then
		return false, nil, domCode, domMsg
	end
	if type(key) ~= "string" or #key == 0 then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Clave de configuración vacía."
	end
	local baseEntry = LootBoxConfig.GetBaseEntry(key)
	if not baseEntry then
		return false, nil, ShopProtocol.ErrorCodes.UnknownBox, `No existe ninguna caja con BoxId '{key}'.`
	end
	if type(changes) ~= "table" or next(changes) == nil then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Debes proporcionar al menos un campo válido para modificar."
	end

	local existingOverride = _currentOverrides[key]
	local currentDef = LootBoxConfig.GetBox(key)
	local sanitized: LootBoxConfig.CrateOverridePatch = {}

	for field, val in pairs(changes) do
		if not ALLOWED_CRATE_OVERRIDE_FIELDS[field] then
			return false,
				nil,
				BuildProtocol.ErrorCodes.InvalidPayload,
				`Campo '{tostring(field)}' no autorizado para override administrativo (ej. estado efímero/estructura protegida).`
		end

		if field == "Price" then
			if not isFiniteNumber(val) or val < LIMITS.PriceMin or val > LIMITS.PriceMax then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Precio inválido: debe estar entre {LIMITS.PriceMin} y {LIMITS.PriceMax}.`
			end
			sanitized.Price = math.floor(val)
		elseif field == "DeliverySeconds" then
			if not isFiniteNumber(val) or val < LIMITS.DeliverySecondsMin or val > LIMITS.DeliverySecondsMax then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Tiempo de entrega inválido: debe estar entre {LIMITS.DeliverySecondsMin} y {LIMITS.DeliverySecondsMax} s.`
			end
			sanitized.DeliverySeconds = math.floor(val)
		elseif field == "RestockQuantity" then
			if not isFiniteNumber(val) or val < LIMITS.StockMin or val > LIMITS.StockMax then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Stock de reposición inválido: debe estar entre {LIMITS.StockMin} y {LIMITS.StockMax}.`
			end
			local cleanQty = math.floor(val)
			sanitized.RestockQuantity = cleanQty
			if changes.StockMin == nil then
				sanitized.StockMin = cleanQty
			end
			if changes.StockMax == nil then
				sanitized.StockMax = cleanQty
			end
		elseif field == "StockMin" then
			if not isFiniteNumber(val) or val < LIMITS.StockMin or val > LIMITS.StockMax then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `StockMin inválido: debe estar entre {LIMITS.StockMin} y {LIMITS.StockMax}.`
			end
			sanitized.StockMin = math.floor(val)
		elseif field == "StockMax" then
			if not isFiniteNumber(val) or val < LIMITS.StockMin or val > LIMITS.StockMax then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `StockMax inválido: debe estar entre {LIMITS.StockMin} y {LIMITS.StockMax}.`
			end
			sanitized.StockMax = math.floor(val)
		elseif field == "RestockIntervalSeconds" then
			if not isFiniteNumber(val) or val < LIMITS.RestockIntervalMin or val > LIMITS.RestockIntervalMax then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `Intervalo de restock inválido: debe estar entre {LIMITS.RestockIntervalMin} y {LIMITS.RestockIntervalMax} s.`
			end
			sanitized.RestockIntervalSeconds = math.floor(val)
		elseif field == "Enabled" then
			if type(val) ~= "boolean" then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "Enabled debe ser booleano."
			end
			sanitized.Enabled = val
		elseif field == "DisabledReason" then
			if type(val) ~= "string" then
				return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, "DisabledReason debe ser texto."
			end
			sanitized.DisabledReason = string.sub(val, 1, LIMITS.DisabledReasonMaxLen)
		end
	end

	-- Coherencia StockMin <= StockMax respecto al estado efectivo resultante
	local effMin = sanitized.StockMin
		or (if existingOverride and type(existingOverride.StockMin) == "number" then existingOverride.StockMin elseif currentDef then currentDef.StockMin else baseEntry.RestockQuantity)
	local effMax = sanitized.StockMax
		or (if existingOverride and type(existingOverride.StockMax) == "number" then existingOverride.StockMax elseif currentDef then currentDef.StockMax else baseEntry.RestockQuantity)
	if effMin > effMax then
		return false, nil, BuildProtocol.ErrorCodes.InvalidPayload, `StockMin ({effMin}) no puede ser mayor que StockMax ({effMax}).`
	end

	-- Regla de integridad: jamás permitir habilitar una caja sin RewardPool funcional válido
	local effEnabled = if sanitized.Enabled ~= nil
		then sanitized.Enabled
		elseif existingOverride and existingOverride.Enabled ~= nil then existingOverride.Enabled
		else baseEntry.Enabled
	if effEnabled then
		local okPool, poolErr = LootBoxConfig.HasValidRewardPool(key)
		if not okPool then
			return false,
				nil,
				"InvalidRewardPool",
				`No se puede habilitar '{baseEntry.DisplayName}': {tostring(poolErr)}. Las cajas sin motores funcionales deben permanecer como Próximamente.`
		end
	end

	return true, sanitized, nil, nil
end

function GameConfigService.ApplyOverride(
	domain: string,
	key: string,
	changes: { [string]: any },
	actorMeta: AdminActorMetadata?
): (boolean, { Revision: number, Config: any }?, string?, string?)
	local okVal, sanitized, valCode, valMsg = GameConfigService.ValidateOverride(domain, key, changes)
	if not okVal or not sanitized then
		return false, nil, valCode, valMsg
	end
	if _ioBusy then
		return false, nil, BuildProtocol.ErrorCodes.OperationInProgress, "Actualización de configuración en curso."
	end

	_ioBusy = true
	local now = _clockFn()
	local okSave, savedPayload, saveCode, saveMsg = updatePersistedCratesPayload(function(cur)
		local nextOverrides = deepCloneOverrides(cur.Overrides)
		local boxPatch = nextOverrides[key] or {}
		for f, v in pairs(sanitized :: { [string]: any }) do
			boxPatch[f] = v
		end
		nextOverrides[key] = boxPatch
		local nextRev = math.max(cur.Revision, _currentRevision) + 1
		return {
			SchemaVersion = SCHEMA_VERSION,
			Revision = nextRev,
			UpdatedAt = now,
			LastModifiedByUserId = actorMeta and actorMeta.ActorUserId or nil,
			Overrides = nextOverrides,
		}
	end)
	_ioBusy = false

	if not okSave or not savedPayload then
		return false, nil, saveCode or BuildProtocol.ErrorCodes.PersistenceFailed, saveMsg or "Error al guardar override de configuración."
	end

	_currentRevision = savedPayload.Revision
	_currentOverrides = deepCloneOverrides(savedPayload.Overrides) :: { [string]: LootBoxConfig.CrateOverridePatch }
	_lastLoadError = nil
	LootBoxConfig.ApplyEffectiveOverrides(_currentOverrides, _currentRevision)
	emitConfigChanged("Crates", _currentRevision, `ApplyOverride:{key}`)
	publishInvalidation("Crates", _currentRevision)

	return true, {
		Revision = _currentRevision,
		Config = LootBoxConfig.GetBox(key),
	}, nil, nil
end

function GameConfigService.ResetOverride(
	domain: string,
	key: string?,
	actorMeta: AdminActorMetadata?
): (boolean, { Revision: number }?, string?, string?)
	local okDom, domCode, domMsg = validateDomainSupported(domain)
	if not okDom then
		return false, nil, domCode, domMsg
	end
	if key ~= nil and (type(key) ~= "string" or not LootBoxConfig.GetBaseEntry(key)) then
		return false, nil, ShopProtocol.ErrorCodes.UnknownBox, `Caja desconocida: '{tostring(key)}'.`
	end
	if _ioBusy then
		return false, nil, BuildProtocol.ErrorCodes.OperationInProgress, "Actualización de configuración en curso."
	end

	_ioBusy = true
	local now = _clockFn()
	local okSave, savedPayload, saveCode, saveMsg = updatePersistedCratesPayload(function(cur)
		local nextOverrides = deepCloneOverrides(cur.Overrides)
		if type(key) == "string" and #key > 0 then
			nextOverrides[key] = nil
		else
			table.clear(nextOverrides)
		end
		local nextRev = math.max(cur.Revision, _currentRevision) + 1
		return {
			SchemaVersion = SCHEMA_VERSION,
			Revision = nextRev,
			UpdatedAt = now,
			LastModifiedByUserId = actorMeta and actorMeta.ActorUserId or nil,
			Overrides = nextOverrides,
		}
	end)
	_ioBusy = false

	if not okSave or not savedPayload then
		return false, nil, saveCode or BuildProtocol.ErrorCodes.PersistenceFailed, saveMsg or "Error al restablecer configuración."
	end

	_currentRevision = savedPayload.Revision
	_currentOverrides = deepCloneOverrides(savedPayload.Overrides) :: { [string]: LootBoxConfig.CrateOverridePatch }
	_lastLoadError = nil
	LootBoxConfig.ApplyEffectiveOverrides(_currentOverrides, _currentRevision)
	emitConfigChanged("Crates", _currentRevision, `ResetOverride:{tostring(key or "All")}`)
	publishInvalidation("Crates", _currentRevision)

	return true, { Revision = _currentRevision }, nil, nil
end

function GameConfigService.ReloadConfig(domain: string, forceApplySameOrHigher: boolean?): (boolean, { Revision: number }?, string?, string?)
	local okDom, domCode, domMsg = validateDomainSupported(domain)
	if not okDom then
		return false, nil, domCode, domMsg
	end

	local okLoad, rawPayload, loadCode, loadMsg = readPersistedCratesPayload()
	if not okLoad then
		-- Fallback seguro: conserva defaults / última configuración válida sin romper el servicio
		_lastLoadError = loadMsg or "Error al recargar configuración global"
		return false, { Revision = _currentRevision }, loadCode, _lastLoadError
	end

	if rawPayload == nil then
		-- Nunca hubo overrides persistidos aún: usar catálogo predeterminado de manera segura
		if _currentRevision == 0 then
			_currentOverrides = {}
			LootBoxConfig.ApplyEffectiveOverrides(_currentOverrides, 0)
		end
		_lastLoadError = nil
		return true, { Revision = _currentRevision }, nil, nil
	end

	if type(rawPayload) ~= "table" or type(rawPayload.Revision) ~= "number" then
		_lastLoadError = "Formato de configuración persistida inválido; conservando configuración segura."
		return false, { Revision = _currentRevision }, BuildProtocol.ErrorCodes.PersistenceFailed, _lastLoadError
	end

	local incomingRev = math.max(0, math.floor(rawPayload.Revision))
	-- Nunca permitir que una revisión vieja sobrescriba una revisión más reciente ya cargada
	if incomingRev < _currentRevision then
		return true, { Revision = _currentRevision }, nil, nil
	end
	if incomingRev == _currentRevision and not forceApplySameOrHigher and _initialized then
		return true, { Revision = _currentRevision }, nil, nil
	end

	local cleaned = deepCloneOverrides(rawPayload.Overrides)
	-- Sanitizar overrides frente a reglas actuales por si hubiera un cambio obsoleto o corrupto
	for boxId, patch in pairs(cleaned) do
		local base = LootBoxConfig.GetBaseEntry(boxId)
		if not base then
			cleaned[boxId] = nil
		elseif patch.Enabled == true then
			local okPool = LootBoxConfig.HasValidRewardPool(boxId)
			if not okPool then
				patch.Enabled = false
			end
		end
	end

	_currentRevision = incomingRev
	_currentOverrides = cleaned :: { [string]: LootBoxConfig.CrateOverridePatch }
	_lastLoadError = nil
	LootBoxConfig.ApplyEffectiveOverrides(_currentOverrides, _currentRevision)
	emitConfigChanged("Crates", _currentRevision, "ReloadConfig")

	return true, { Revision = _currentRevision }, nil, nil
end

function GameConfigService.HandleSyncMessage(messageData: any): boolean
	if type(messageData) ~= "table" then
		return false
	end
	if messageData.Domain ~= "Crates" then
		return false
	end
	local incomingRev = tonumber(messageData.Revision)
	if not incomingRev or incomingRev <= _currentRevision then
		-- Ignorar mensajes sin revisión o de revisión igual/antigua
		return false
	end
	local ok = GameConfigService.ReloadConfig("Crates", false)
	return ok
end

function GameConfigService.RegisterConfigChangedListener(
	listener: (domain: string, revision: number, reason: string) -> ()
): () -> ()
	table.insert(_configChangedListeners, listener)
	return function()
		local idx = table.find(_configChangedListeners, listener)
		if idx then
			table.remove(_configChangedListeners, idx)
		end
	end
end

function GameConfigService._GetLastStorageMode(): string
	return _lastStorageMode
end

function GameConfigService._SetClockForTests(clockFn: (() -> number)?)
	_clockFn = clockFn or os.time
end

function GameConfigService._SetStorageAdapterForTests(adapter: GlobalStorageAdapter?)
	_customAdapter = adapter
end

function GameConfigService._SetMessagingBridgeForTests(bridge: MessagingBridge?)
	_messagingBridge = bridge
end

function GameConfigService._SetUseMemoryStoreForTests(enabled: boolean?)
	_useMemoryStoreForTests = (enabled == true)
end

function GameConfigService._SetSimulateLoadFailureForTests(shouldFail: (boolean | string)?)
	_simulateLoadFailure = shouldFail
end

function GameConfigService._SetSimulateWriteFailureForTests(shouldFail: (boolean | string)?)
	_simulateWriteFailure = shouldFail
end

function GameConfigService._ResetForTests(clearMemoryData: boolean?)
	if _messagingSubCleanup then
		if type(_messagingSubCleanup) == "function" then
			pcall(_messagingSubCleanup)
		elseif typeof(_messagingSubCleanup) == "RBXScriptConnection" then
			_messagingSubCleanup:Disconnect()
		end
		_messagingSubCleanup = nil
	end
	table.clear(_configChangedListeners)
	table.clear(_currentOverrides)
	_currentRevision = 0
	_lastLoadError = nil
	_ioBusy = false
	_clockFn = os.time
	_simulateLoadFailure = nil
	_simulateWriteFailure = nil
	if clearMemoryData then
		table.clear(_memoryStore)
		_customAdapter = nil
		_messagingBridge = nil
		_useMemoryStoreForTests = false
	end
	LootBoxConfig.ClearEffectiveOverrides()
	_initialized = false
	_started = false
end

function GameConfigService.Init()
	if _initialized then
		return
	end
	_initialized = true
	LootBoxConfig.ClearEffectiveOverrides()
	local ok = GameConfigService.ReloadConfig("Crates", true)
	if not ok then
		-- Fallback seguro garantizado ante fallo inicial de DataStore
		table.clear(_currentOverrides)
		_currentRevision = 0
		LootBoxConfig.ApplyEffectiveOverrides(_currentOverrides, 0)
	end
end

function GameConfigService.Start()
	if not _initialized then
		GameConfigService.Init()
	end
	if _started then
		return
	end
	_started = true

	if _messagingBridge then
		_messagingSubCleanup = _messagingBridge.Subscribe(MESSAGING_TOPIC, function(msg)
			GameConfigService.HandleSyncMessage(if type(msg) == "table" and msg.Data ~= nil then msg.Data else msg)
		end)
		return
	end

	if not RunService:IsRunning() or _useMemoryStoreForTests then
		return
	end

	task.spawn(function()
		local okSub, connOrErr = pcall(function()
			return MessagingService:SubscribeAsync(MESSAGING_TOPIC, function(msg)
				GameConfigService.HandleSyncMessage(msg and msg.Data)
			end)
		end)
		if okSub then
			_messagingSubCleanup = connOrErr
		end
	end)
end

return GameConfigService
