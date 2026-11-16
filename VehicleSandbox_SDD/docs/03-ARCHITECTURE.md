# 03 — Arquitectura de software

## Stack
Roblox Studio, Luau, Rojo; integración con herramientas de desarrollo asistido opcional.

## Árbol sugerido
```text
ReplicatedStorage/
  Shared/
    Config/{GameConfig,EconomyConfig,PhysicsConfig,RarityConfig}
    Catalog/{ItemRegistry,Definitions/{Structures,Wheels,Engines,Boosters,FuelTanks,Utilities}}
    Building/{GridMath,PlacementRules,ConnectionRules}
    Types/{ItemTypes,VehicleTypes}
    Remotes/
ServerStorage/
  ItemAssets/{Structures,Wheels,Engines,Boosters,FuelTanks,Utilities}/
  Crates/
  BaseTemplate/
  MissionAssets/
ServerScriptService/
  Server/
    Services/{PlotService,InventoryService,BuildingService,VehicleService,VehiclePhysicsService,DamageService,ItemRuntimeService,ShopService,StockService,DeliveryService,CrateService,EconomyService,DistanceService,MissionService,DataService}
    Bootstrap.server.lua
StarterPlayer/StarterPlayerScripts/Client/Controllers/
  {BuildController,VehicleController,CameraController,ShopController,UIController}
```

## Contratos principales
- `ItemRegistry.Get(itemId)`: definición validada, inmutable.
- `PlotService.Assign(player)`: estación libre y referencias por identificadores, no rutas Base1.
- `BuildingService.ApplyEdit(player, operation, revision)`: valida propiedad, inventario, límites, geometría y revisión; devuelve ack o rechazo.
- `VehicleService.Launch(player)`: bloquea blueprint, crea runtime, ensambla, activa conducción.
- `VehicleService.Return(player, reason)`: operación idempotente; limpia runtime y restaura modo edición.
- `DamageService.ApplyImpact(runtimeId, partInstanceId, impact)`: solo modifica estado temporal.
- `ItemRuntimeService.Init(runtime, part) / Destroy(runtime, part)`: comportamiento por categoría o por modelo.

## Modelo y comportamiento
- Definiciones autoritativas en módulos del servidor; opcionalmente replicar solo metadatos públicos al cliente.
- Modelos dentro de `ServerStorage.ItemAssets/<Category>/<ItemId>`; atributos para identificadores y puntos de conexión.
- Si el objeto requiere comportamiento propio, puede incluir `Behaviors/<ModuleScript>`; lo carga el orquestador central después de validar identidad y contrato.
- Nunca confiar en `Attributes`, precios, rarezas o estadísticas enviados por el cliente.
- Separar el `ItemId` del `InventoryInstanceId` para objetos obtenidos con rarezas y propiedades únicas.

## Edición inmediata
- Preview y colocación provisional locales en el mismo frame cuando sea posible.
- Cliente envía operación con ID y revisión; servidor valida, confirma y replica.
- Ante rechazo, rollback visual; ante conflictos, reconciliación desde estado autorizado.
- No prometer latencia de red real de 0 ms.

## Multijugador
- Diez estaciones exclusivas; propiedad y permisos comprobados en servidor.
- Cada jugador construye su propio vehículo en la V1; colaboración en un mismo vehículo no está confirmada.
- Vehículos runtime pueden utilizar NetworkOwnership para suavidad, pero la economía, daño autoritativo y recompensas se verifican en servidor.

## Protocolo implementado en Fase 2.3 / 2.3.1 (Construcción y Transformación 3D)
- **Transporte**: `BuildOperationRequest` (`RemoteFunction`, ACK/reject inmediato para `PlacePiece`, `RemovePiece`, `TransformPiece` y `GetBlueprint`) + `BlueprintSyncEvent` (`RemoteEvent` servidor → propietario con deltas `PiecePlaced`, `PieceRemoved`, `PieceTransformed`, `BlueprintReset`).
- **Seguridad y aislamiento**: `TokenBucket` por `UserId` (lecturas y escrituras separadas) + `BuildPayloadValidator` (esquema estricto, tipos, longitud, profundidad máxima 2, sin ciclos/Instances/metatablas, rechazo de campos de autoridad y matrices no ortonormales/degeneradas, sanitización de `Config`) + `BuildSnapPolicy` (validación autoritativa de rotación según `PlacementPolicy` del catálogo).
- **Cliente optimista y bucle único**: estado monotónico en `BuildState` por `BlueprintRevision` + `OwnerUserId` + `BlueprintId`, detección de brechas con resincronización automática vía `GetBlueprint`, timeout configurable (`OperationTimeoutSeconds = 5`), debounce de clic, anti-doble borrado, sesión optimista `BuildTransformController` (revert/confirm/rollback en timeout o rechazo) y único `RenderStepped` en `BuildController.client.luau` coordinando `BuildPreviewController`, `BuildGridVisualizer`, `BuildAlignmentGuides`, `BuildMoveGizmo` y `BuildRotationGizmo`.
- **Ciclo de vida**: limpieza en `PlayerRemoving`, `PlotService.OnPlotReleased`, `CharacterRemoving` y destrucción del controlador.


## Fase 2.4 — Gestión de Blueprints, Stand y Preparación de Lanzamiento
- **Contratos y matemática compartida (`ReplicatedStorage/Shared`)**:
  - `Types/VehicleTypes.luau`: `StandPresentationConfig`, `BlueprintMetadata`, `BlueprintSummary`, `LaunchIssueCategory`, `LaunchIssue`, `LaunchPreparationReport` y campos de versión/presentación en `VehicleBlueprint`.
  - `Config/GameConfig.luau`: secciones congeladas `Blueprints`, `Stand`, `LaunchPrep`, `Building.StandPreviewName` y entradas de Stand en `PlotContainers`.
  - `Building/BuildProtocol.luau`: acciones `ListBlueprints`, `CreateBlueprint`, `SaveBlueprint`, `LoadBlueprint`, `SetActiveBlueprint`, `DuplicateBlueprint`, `RenameBlueprint`, `DeleteBlueprint`, `SetStandOffset`, `ResetStandOffset`, `ValidateLaunchPrep`; soporte de `ExpectedBlueprintId` y eventos de sincronización `BlueprintLoaded`, `StandPresentationUpdated`, `BlueprintLibraryUpdated`.
  - `Building/VehicleCoordinateMath.luau`: límites por pieza y vehículo, cálculo de `BaseAnchor` y conversión consistente entre `BuildZone`, `VehicleStand` (`DisplayAnchor`) y `LaunchPoint` incluyendo plots rotados.
  - `Building/BlueprintSerializer.luau`: serialización JSON segura v1, copia profunda, migración de formato legado v0 y rechazo de NaN, duplicados o versiones incompatibles.
- **Servicios autoritativos (`ServerScriptService/Server`)**:
  - `Services/VehicleBlueprintService.luau`: CRUD atómico sobre `SavedBlueprints`, seguimiento de cambios en `ActiveBlueprint`, notificaciones por `OnBlueprintChanged`, importación serializada y limpieza en `ClearPlayer`.
  - `Services/PlotService.luau`: resolución de `VehicleStand`, `StandDisplayAnchor` y `StandInteractionPoint` en `PlotRecord`.
  - `Services/StandPreviewService.luau`: introducido originalmente en Fase 2.4 para vista previa separada; en Fase 2.4.1 queda reducido a stub compatible sin crear `StandPreview` (eliminando cualquier instancia residual).
  - `Services/VehicleLaunchPreparationService.luau`: reporte de preparación de lanzamiento de solo lectura sobre `LaunchPoint`.
  - `Services/BuildService.luau` y `Security/BuildPayloadValidator.luau`: despacho seguro Fase 2.4, caché por `ClientOpId`, límite de tasa y verificación de `ExpectedBlueprintId`.
- **Controladores cliente (`StarterPlayerScripts/Client/Controllers`)**:
  - `BlueprintManagerController.luau`, `StandController.luau` y `VehicleManagement.client.luau`, coordinados con `BuildState.luau` y `BuildPlacementController.luau`.

## Fase 2.4.1 — Reconversión del Stand a Elevador de Construcción
- **Contratos y matemática de ensamblaje elevado (`ReplicatedStorage/Shared`)**:
  - `Types/VehicleTypes.luau` y `Building/BuildProtocol.luau`: tipos `BuildAssemblyOffset` y `LiftBounds`, además de `ErrorCodes.ElevatorBlocked = "ElevatorBlocked"`.
  - `Config/GameConfig.luau`: `PlotAttributes.BuildLiftHeight = "BuildLiftHeightOffset"`, `PlotAttributes.BuildLiftLateral = "BuildLiftLateralOffset"`, y parámetros en `GameConfig.Stand` (`MaxHeightOffset = 16`, `MinLateralOffset = -10`, `MaxLateralOffset = 10`, `ContinuousHoldDelaySeconds = 0.18`, `ContinuousSyncIntervalSeconds = 0.10`, `ContinuousNormalSpeed = 4.0`, `ContinuousFineSpeed = 1.0`).
  - `Building/VehicleCoordinateMath.luau`: `GetAssemblyOffsetCFrame`, `GetEffectiveBuildZoneCFrame`, `ComputePhysicalLocalPosition`, `ComputeLiftBoundsFromExtents`, `ComputeLiftBounds`, `IsLiftOffsetWithinBounds` y soporte opcional `assemblyOffset` en `BlueprintPieceToBuildZoneWorld`.
  - `Building/BuildTransformMath.luau` y `Building/BuildGrid.luau`: `LiftHeightOffset` para piso físico efectivo en colocación y validación de límites de `BuildZone` respecto al ensamblaje elevado (`ValidateBounds`).
- **Servicios autoritativos y modelo físico (`ServerScriptService/Server` y Studio MCP)**:
  - `VehicleBlueprintService.luau`: estado temporal de taller `_liftOffsetByUserId`, `ComputeLiftBoundsForPlayer`, `GetLiftOffset`, `GetEffectiveBuildZoneCFrame`, `ResetStandOffset`, actualización física directa de `EditableVehicle` (`WorldPivot` y atributos compartidos con `BuildZone`), guardado de diseño en presentación neutral `(0, 0)` y recarga automática con altura mínima de descanso para piezas bajo chasis sin ensuciar `_dirtyByUserId`.
  - `BuildService.luau`: validación autoritativa de `LiftBounds` dinámicos en `SetStandOffset`/`ResetStandOffset`, detección de colisión externa `ElevatorBlocked` (broadphase O(1) + OBB por pieza) y límites físicos efectivos en colocación y transformación.
  - `ServerStorage.BaseTemplate.VehicleStand`: `StandPrompt` actualizado en Studio MCP (`ObjectText = "Elevador de Construcción"`, `ActionText = "Abrir Elevador"`).
- **Controladores y gizmos en cliente (`StarterPlayerScripts/Client/Controllers`)**:
  - `BuildState.luau`: `GetAssemblyOffset`, `GetAssemblyOffsetCFrame`, `GetEffectiveBuildZoneCFrame` y `GetEffectiveFloorY`.
  - `BuildPreviewController.luau`, `BuildTransformController.luau`, `BuildGridVisualizer.luau`, `BuildAlignmentGuides.luau`, `BuildMoveGizmo.luau` y `BuildRotationGizmo.luau`: compatibilidad con `AssemblyOffsetCFrame` y piso físico efectivo durante elevación/traslación lateral.
  - `StandController.luau` y `VehicleManagement.client.luau`: `GetDynamicBounds`, `ClampOffsetToDynamicBounds`, `ApplyOptimisticVisual`, pulsación continua coalescida (`BeginContinuousHold`, `StepContinuousHold`, `EndContinuousHold`, `_trailingFlushTimer`) acotada a `<= 10 Hz` con máximo 1 RPC pendiente, rollback ante rechazo y feedback en UI (`StandFeedback`).

## Fase 2.4.2 — Construcción Libre Multi-Ensamblaje y `FaceSnap` Cara con Cara
- **Tipos, protocolo y configuración compartida (`ReplicatedStorage/Shared`)**:
  - `Types/VehicleTypes.luau`: `PartBoxSpec`, `AssemblyRole` (`"PrimaryAssembly" | "SecondaryAssembly" | "LoosePiece"`), `AssemblyComponentSummary`, `AssemblyAnalysis`, `BlueprintMetadata.PrimaryAssemblyGroupId` y campos multi-ensamblaje en `LaunchPreparationReport` (`TotalPieceCount`, `WorkshopPieceCount`, `PrimaryAssemblyGroupId`, `PrimaryAssemblyPieceIds`, `WorkshopPieceIds`, `AssemblyGroups`, `DisconnectedGroupCount`, `NeedsPrimarySelection`).
  - `Building/BuildProtocol.luau`: acción `SelectPrimaryAssembly`, solicitud `SelectPrimaryAssemblyRequest`, evento `AssemblySelectionUpdated` y códigos `AmbiguousPrimaryAssembly` / `PrimaryAssemblyNotFound`.
  - `Config/GameConfig.luau`: parámetros de `FaceSnap` bajo `GameConfig.Building` (`FaceSnapRadius`, `FaceSnapTangentMargin`, `FaceSnapHysteresis`, `FaceSnapMinNormalDot`, `FaceSnapMinContactOverlap`, `FaceSnapMaxPassiveJump`, `FaceSnapValidColor`, `FaceSnapInvalidColor`).
  - `Building/ConnectionMath.luau`: extracción de geometría compuesta `ExtractModelGeometry` (`Attachments`, `Size`, `PartBoxes`, `BoundsMin`, `BoundsMax`, conservando `ExtractModelAttachments` como wrapper compatible), `GetEffectivePartBoxes`, `ComputePieceLocalAABB`, `SpecsOverlap` / `AnyOverlap` sobre sub-cajas OBB y análisis de grafo explícito `AnalyzeAssemblies` sin auto-unión por proximidad visual.
  - `Building/BuildGrid.luau`: `ValidateBoundsMinMax` compartido con `ValidateBounds` para límites reales de piezas compuestas o rotadas.
  - `Building/FaceSnapMath.luau` (nuevo): `CreateLockState`, `ClearLockState`, `ExtractPieceFaces`, `ComputeFaceSnap` para las 6 caras OBB (`±X`, `±Y`, `±Z`) de modelos simples y compuestos en cualquier rotación, con validación OBB/límites e histéresis.
  - `Building/BuildAlignmentMath.luau`: señalización consistente de `SmartSnapMatch` en Priority 1 cuando un ajuste `Conn_*` ya queda conectado sin superposición.
- **Servicios autoritativos (`ServerScriptService/Server`)**:
  - `Services/ConnectionService.luau`: caché por `ItemId` con `PartBoxes` y límites locales, eliminación de rechazos por `DisconnectedPiece`/`WouldDisconnectVehicle`, mantenimiento explícito de componentes conexos y método `AnalyzeBlueprintAssemblies`.
  - `Services/VehicleBlueprintService.luau`: evento `AssemblySelectionChanged`, `SetPrimaryAssemblyGroup`, persistencia de `Metadata.PrimaryAssemblyGroupId` y carga libre de blueprints con piezas sueltas o múltiples grupos.
  - `Services/BuildService.luau` y `Security/BuildPayloadValidator.luau`: despacho seguro de `SelectPrimaryAssembly` y validación de límites compuestos (`ComputePieceLocalAABB` + `ValidateBoundsMinMax`) en colocación/transformación.
  - `Services/VehicleLaunchPreparationService.luau`: `EvaluateBlueprintLaunch` y `ComputePieceLaunchWorldCFrames` operan de solo lectura aislando únicamente `PrimaryAssembly`, excluyendo piezas de taller y exigiendo desambiguación ante múltiples `DriverSeat` desconectados (`AmbiguousPrimaryAssembly`).
- **Controladores y visuales cliente (`StarterPlayerScripts/Client/Controllers`)**:
  - `BuildFaceSnapVisualizer.luau` (nuevo): pool fijo de `5 LineHandleAdornment + 1 SphereHandleAdornment` (`BuildFaceSnapVisualizerPool`) para resaltar cara destino, normal y punto de contacto sin crear `BasePart`s por frame.
  - `BuildState.luau`, `BuildInputController.luau`, `BuildPreviewController.luau`, `BuildTransformController.luau`, `BuildController.client.luau`: estado y atajo `FaceSnap: ON/OFF [K]` en `PrecisionBar`, raycast con `TargetPieceId` en `UpdateFromRay`, pipeline ordenado (`SmartSnap` -> `FaceSnap` -> `Grid` / `Free`) y liberación de transformación con gizmos sin restricción de conectividad.
  - `BlueprintManagerController.luau` y `VehicleManagement.client.luau`: método `SelectPrimaryAssembly` y botones dinámicos de selección de vehículo primario en `LaunchPrepPanel`.

## Fase 3.1 — `VehicleRuntime`, Ensamblaje Físico y Sistema de Lanzamiento
- **Contratos y configuración compartida (`ReplicatedStorage/Shared`)**:
  - `Config/GameConfig.luau`: sección congelada `GameConfig.Runtime` (`ModelName = "VehicleRuntime"`, `JointsFolderName = "Joints"`, `StagingFolderName = "_VehicleRuntimeStaging"`, `CollisionGroups`, `VehiclesCollideWithEachOther = false`, `States`, `PartRoles`, `SeatMountTimeoutSeconds = 2.0`, `SeatMountRetryIntervalSeconds = 0.06`, `SeatCooldownWaitSeconds = 0.05`, `LaunchCooldownSeconds = 0.75`, `AbandonedTimeoutSeconds = 300`, `AbandonedCleanupCheckIntervalSeconds = 5`, `DestroyVehicleOnDeath = false`, `ExitSeatLateralOffsetStuds = 3.5`, `ExitSeatUpOffsetStuds = 1.5`).
  - `Types/VehicleTypes.luau`: extensión de `VehicleState`, nuevo tipo `PartPhysicsRole`, `RuntimeStatusSnapshot` y campos de estado físico temporal en `RuntimePartState` / `VehicleRuntime`.
  - `Building/BuildProtocol.luau`: acciones `LaunchVehicle`, `ReturnToWorkshop`, `ResetVehicle`, `ExitVehicleSeat`, `GetRuntimeState`; evento de sincronización `RuntimeStateUpdated` y códigos `InvalidPlayerState`, `LaunchInProgress`, `RuntimeAlreadyActive`, `RuntimeNotActive`, `LaunchCooldown`, `DriverSeatMountFailed`, `NotRuntimeOwner`, `CharacterNotReady`, `PlayerDead`, `AssemblyBuildFailed`.
- **Servicios autoritativos desacoplados (`ServerScriptService/Server`, 13 servicios en `Bootstrap.server.lua`)**:
  - `Services/VehicleAssemblyService.luau`: registro y reglas de `CollisionGroups` (`VehicleRuntime`, `EditableVehicle`, `EditorGhost`), ensamblaje en `ServerStorage._VehicleRuntimeStaging` exclusivamente sobre `PrimaryAssembly`, sanitización de `LuaSourceContainer` / constraints ajenos, asignación de `PartPhysicsRole` / atributos de preparación para Fase 3.2 (`FutureWheel` / `FuturePropulsion`) y generación deduplicada O(E) de `WeldConstraint`s desde `Blueprint.Connections`.
  - `Services/VehicleRuntimeService.luau`: registro único `1` runtime activo por jugador con bloqueo de slot por concurrencia, inicialización y destrucción de `ItemRuntimeService` por pieza, publicación en `plot.DynamicContainer` con velocidades en cero antes de desanclar, política explícita de `NetworkOwnership` (dueño en `Driving`, servidor `nil` en reposo `OnFootRuntime`) y limpieza determinista de señales e instancias ante remoción externa.
  - `Services/VehicleLifecycleService.luau`: máquina de estados autoritativa (`Editing -> PreparingLaunch -> Launching -> Driving <-> OnFootRuntime -> ReturningToWorkshop -> Editing`), montaje sin carreras de `DriverSeat:Sit(humanoid)`, eyección inmediata de ocupantes no propietarios, desmonte seguro previo al retorno a `plot.PlayerSpawn`, verificación de abandono, hooks de `Humanoid.Died`, `SpawnService.RegisterBeforeRespawnHook`, `PlotService.OnPlotReleased` y `PlayerRemoving`.
  - `Services/VehicleLaunchService.luau`: orquestador público (`LaunchVehicle`, `ReturnToWorkshop`, `ResetVehicle`, `ExitVehicleSeat`, `GetRuntimeState`) con exclusión mutua por `UserId` y cooldown por acción.
  - `Services/BuildService.luau` y `Security/BuildPayloadValidator.luau`: validación estricta de las 5 acciones de runtime, bloqueo `InvalidPlayerState` para toda mutación de taller fuera de `Editing` y emisión de `RuntimeStateUpdated`.
- **Cliente, aislamiento visual y UI (`StarterPlayerScripts/Client/Controllers`)**:
  - `VehicleLaunchController.luau` (nuevo), `BuildState.luau`, `BuildController.client.luau`, `BuildPlacementController.luau`, `VehicleManagement.client.luau` y controladores de preview/gizmos: cierre automático y bloqueo del editor al salir de `Editing`, asignación de `CollisionGroup = EditorGhost` en ghosts y de `EditableVehicle` en servidor, dock superior con `Lanzar` y `RuntimeControlsBar` (`Vehículo activo`, `Salir del asiento`, `Reiniciar vehículo`, `Regresar al taller`).

## Fase 3.2 — Sistema Híbrido de Ruedas, Suspensión y Dirección Modular
- **Assets y definición física (`ServerStorage/ItemAssets/Wheels`)**:
  - `SmallWheel/Primary.model.json` y `SmallWheel/init.meta.json`: parte cilíndrica `[1, 2, 2]` con `Attachment` centrado `WheelHub` `[0, 0, 0]`, attachments estructurales `Conn_Axle`/`Conn_AxleRight` intactos y atributos declarativos (`WheelRadius = 1.0`, `WheelWidth = 1.0`, `LocalSpinAxis = "X"`, `LocalSuspensionAxis = "Y"`).
- **Contratos y matemática compartida (`ReplicatedStorage/Shared`)**:
  - `Types/VehicleTypes.luau`: tipos `WheelSteeringMode`, `WheelPieceConfigOverrides`, `WheelResolvedSources`, `WheelGeometryAnalysis`, `ResolvedWheelConfig`, `VehicleWheelAnalysis`, `WheelDriveCommand`, `WheelRuntimeState`; listas `WheelConstraints`/`WheelMechanisms` en `VehicleRuntime` y campos informativos `WheelCount`/`WheelWarnings` en `LaunchPreparationReport`.
  - `Config/GameConfig.luau`: sección congelada `GameConfig.Wheels` (límites de ángulo `0..45°`, velocidad `30..360°/s`, recorrido `0.1..2.0` studs, rigidez `100..100000`, amortiguación `10..10000`, altura `-0.6..0.6`, parámetros auto calibrados `AutoSpringOmega = 14`, `AutoSpringDampingRatio = 0.70`, `AutoSpringMaxDamping = 520`, `AutoSpringMaxPreloadStuds = 2.2`, fricción pasiva `PassiveRollingFrictionTorque = 0.45`) y roles `Wheel`, `SteeringPivot`, `SuspensionCarrier` en `GameConfig.Runtime.PartRoles`.
  - `Building/BuildProtocol.luau`: acción `UpdatePieceConfig`, evento `PieceConfigUpdated` y códigos `InvalidConfigRange`, `PieceNotConfigurable`.
  - `Building/WheelAutoConfiguration.luau` (nuevo): detector geométrico determinista compartido cliente-servidor (eje delantero/central/trasero, lado izq/centro/der, asimetrías y orientaciones no estándar), cálculo de resorte auto por carga estática y resolución híbrida estricta `Defaults < Auto < Manual`.
- **Servicios autoritativos desacoplados (`ServerScriptService/Server`, 15 servicios en `Bootstrap.server.lua`)**:
  - `Services/WheelAutoConfigurationService.luau` (nuevo): cachea geometría real y masas medidas de `ItemAssets` y expone `AnalyzeBlueprint` / `ResolveWheelItemSpec`.
  - `Services/WheelMechanismBuilder.luau` (nuevo): genera el rig articulado por rueda (`Carrier`, `Pivot` opcional, `PrismaticConstraint`, `SpringConstraint`, Servo `SteeringHinge`, Motor `AxleHinge` alineado a `-VehicleRight` y `NoCollisionConstraint`s preventivas) sin `TemporaryWheelWeld`.
  - `Services/VehicleWheelControllerService.luau` (nuevo): orquestador central único en `RunService.Heartbeat` para dirección Servo con límite de velocidad angular, rodamiento pasivo y contrato motriz de Fase 3.3 (`SetWheelDriveCommand`, `SetVehicleDriveCommands`, `ClearDriveCommands`, `GetVehicleWheels`, `GetWheelState`).
  - `Services/VehicleAssemblyService.luau`, `Services/VehicleRuntimeService.luau`, `Services/VehicleLaunchPreparationService.luau`, `Services/VehicleBlueprintService.luau`, `Services/BuildService.luau` y `Security/BuildPayloadValidator.luau`: integración de montaje, registro/desregistro en ciclo de vida, reporte no bloqueante de ruedas y validación/persistencia segura de `UpdatePieceConfig`.
- **Cliente, edición optimista y UI (`StarterPlayerScripts/Client/Controllers`)**:
  - `BuildState.luau`: manejo incremental de `PieceConfigUpdated` conservando selección activa.
  - `WheelConfigController.luau` (nuevo): análisis instantáneo local, actualización optimista con timeout, idempotencia, rollback ante rechazo y restablecimiento parcial/total a `Auto`.
  - `WheelInspectorPanel.luau` (nuevo) y `VehicleManagement.client.luau`: inspector contextual PC/Mobile con badge `AUTO`/`MIXTO`/`MANUAL`, rol detectado, advertencias, steppers táctiles y píldora de reapertura coordinado sin solapamiento con los demás paneles.

## Fase 3.3 — Motores Modulares, Variantes, Rarezas y Transmisión de Potencia
- **Catálogo, tipos y configuración compartida (`ReplicatedStorage/Shared`)**:
  - `Catalog/EngineCatalog.luau` (nuevo): resolución determinista `ResolveEngineEffectiveStats(sizeId, variantId, rarityId)` separando explícitamente los valores confirmados del diseñador en SDD (`SmallEngine`, `MediumEngine`) de los parámetros calibrados/provisionales (`BalanceSource = "Provisional_TBD"` para `Large`, las 5 variantes `Standard`, `HighTorque`, `HighSpeed`, `Efficient`, `HeavyDuty` y las 6 rarezas `Common`, `Uncommon`, `Rare`, `Epic`, `Legendary`, `Mythic`), cálculo de torque por curva RPM (`EvaluateNormalizedTorqueCurve`), relación de caja automática (`SelectAutomaticGear`) y eficiencia multi-motor (`ComputeMultiEngineCombinationFactor`).
  - `Types/ItemTypes.luau` y `Types/VehicleTypes.luau`: tipos `EngineSizeId`, `EngineVariantId`, `EngineRarityId`, `EngineEffectiveStats`, `EngineUnitRecord`, `EnginePieceConfig`, `FuelTankPieceConfig`, `EngineRuntimeState`, `PowertrainGearState`, `PowertrainTelemetrySnapshot`, `DrivingControlInput` y diagnósticos de lanzamiento (`EngineCount`, `DrivenWheelCount`, `FreeWheelCount`, `TotalFuelCapacity`, `EngineWarnings`).
  - `Config/GameConfig.luau`: sección congelada `GameConfig.Powertrain` (parámetros de RPM, histéresis de limitador, tabla de 4 marchas + reversa, rendimientos decrecientes `0.92`, frenado longitudinal, umbral seguro de reversa `ReverseEngageMaxForwardSpeed = 2.5` y política de combustible `ConsumeFuelByDefault = false` en dev; nota: en Fase 4.2 se eliminó por completo el freno de mano `Handbrake`).
  - `Building/BuildProtocol.luau`: acciones `SetDrivingInput`, `ListEngineInventory`, `GrantTestEngineUnit` y códigos `EngineUnitNotFound`, `EngineUnitNotOwned`, `EngineUnitAlreadyInUse`, `InvalidEngineConfig`, `NotSeatedDriver`, `DrivingInputRejected`.
- **Servicios autoritativos desacoplados (`ServerScriptService/Server`, 17 servicios en `Bootstrap.server.lua`)**:
  - `Services/EngineInventoryService.luau` (nuevo): inventario de unidades únicas por jugador (`ItemInstanceId`), kit inicial de desarrollo/pruebas, bloqueo de uso exclusivo por pieza (`AssignedBlueprintId` / `AssignedPieceInstanceId`), liberación en borrado/limpieza y reválida al cargar o duplicar blueprints sin duplicar unidades físicas.
  - `Services/VehiclePowertrainService.luau` (nuevo): orquestador único en `RunService.Heartbeat` por servidor que calcula curva de par por motor, combina múltiples motores con rendimientos decrecientes y tope técnico, gestiona transmisión automática de 4 velocidades + reversa con downshift en pendientes, aplica degradación temporal por `CurrentDurability / MaxDurability`, controla combustible (`IntegratedFuel` + `RegularFuelTank`, corte `OutOfFuel`), envía comandos de tracción y frenado a `VehicleWheelControllerService.SetVehicleDriveCommands` y publica atributos de telemetría en `VehicleRuntime.RootModel`.
  - `ServerStorage/ItemAssets/Engines/SmallEngine/Behaviors/EngineBehavior.luau`: aplica metadatos autoritativos y acento visual de rareza/variante sobre el modelo 3D base sin bucle `Heartbeat` por pieza.
  - `Security/BuildPayloadValidator.luau` y `Services/BuildService.luau`: validación estricta de `Config.Engine` y `Config.FuelTank`, rechazo de estadísticas inyectadas desde cliente (`FORBIDDEN_DIRECT_STATS_KEYS`) y validación de `SetDrivingInput` solo para el propietario sentado.
- **Cliente, HUD de conducción e inspectores (`StarterPlayerScripts/Client/Controllers`)**:
  - `EngineInspectorPanel.luau` (nuevo): inspector contextual en taller para consultar estadísticas efectivas (`EffectiveStats`), rareza, variante, cambiar unidad disponible del inventario o seleccionar subtipo de `RegularFuelTank` (`Regular`, `Diesel`, `Competicion`).
  - `VehicleDrivingController.luau` (nuevo): captura entradas PC (`W`, `S`, `A/D`, `Space`) y botones táctiles Mobile, sincroniza con el servidor y renderiza el HUD de conducción en vivo (velocidad en `studs/s`, RPM, barra de limitador, marcha `R/N/1..4`, torque, motores activos, ruedas motrices, combustible y avisos de `NoDrivenWheels` / `OutOfFuel`).

## Fase 3.4 — Propulsores Modulares, Nitro y Empuje Vectorial
- **Catálogo, tipos y configuración compartida (`ReplicatedStorage/Shared`)**:
  - `Catalog/BoosterCatalog.luau` (nuevo): resolución determinista `ResolveEffectiveStats(input)` separando `BalanceStatus = "SDD_Confirmed"` (`SmallBooster` base en SDD) de parámetros calibrados `Provisional_TBD` (`Medium` / `Large`, familias `StandardRocket` / `HighImpulse` / `ExtendedBurn`, 5 variantes `Balanced` / `HighThrust` / `EcoBurn` / `Lightweight` / `Overboost`, y 6 rarezas `Common`..`Mythic`), reutilizando el modelo base `SmallBooster` mediante atributos y escala/visuales reactivos.
  - `Types/ItemTypes.luau` y `Types/VehicleTypes.luau`: tipos `BoosterFamilyId`, `BoosterSizeId`, `BoosterVariantId`, `BoosterRarityId`, `EffectiveBoosterStats`, `BoosterUnitRecord`, `BoosterPieceConfig`, `BoosterLifecycleState`, `BoosterRuntimeState`, `BoosterTelemetrySnapshot` y diagnósticos en lanzamiento (`BoosterCount`, `FunctionalBoosterCount`, `TotalBoosterThrust`, `TotalNitroCapacity`, `BoosterWarnings`).
  - `Config/GameConfig.luau`: sección congelada `GameConfig.Boosters` (`DefaultLocalThrustAxis = (0,0,-1)`, `DefaultNozzleLocalOffset = (0,0,1.5)`, `MinThrustLimitRatio = 0.25`, `MaxCombinedBoosters = 12`, `MinimumOperationalDurabilityFraction = 0.05`, envolvente aerodinámica y tasas de consumo Nitro `NitroConsumptionTimeBaseSeconds = 1.0`).
  - `Building/BuildProtocol.luau`: acción `GetBoosterUnits`, campo `BoosterState` en respuestas y códigos `UnknownBoosterUnit`, `UnauthorizedBoosterUnit`, `DuplicateBoosterUnitInBlueprint`, `InvalidBoosterInventoryUnit`.
- **Servicios autoritativos desacoplados (`ServerScriptService/Server`, `19` servicios en `Bootstrap.server.lua`)**:
  - `Services/BoosterInventoryService.luau` (nuevo): inventario de unidades únicas por jugador (`ItemInstanceId`), `EnsureControlledWorkshopUnits`, bloqueo de asignación única en blueprint y liberación en borrado/limpieza.
  - `Services/VehicleBoosterService.luau` (nuevo): orquestador único en `RunService.Heartbeat` (`ApplyClientBoostInput`, `CutBoostForPlayer`, `GetBoosterState`, `GetBoosterSlotState`, `StepAll`) que gobierna encendido/apagado (`Idle`, `Igniting`, `Active`, `RampDown`, `Depleted`, `Disabled`, `Destroyed`), calcula empuje neto y por slot sobre `BoosterVectorForce` siguiendo el vector 3D orientado del bloque, aplica degradación temporal por durabilidad y consume Nitro desde el depósito común de `RocketFuel` manteniendo intacto el `Blueprint`.
  - `Services/VehiclePowertrainService.luau`: actualizado con embrague unidireccional cuando el vehículo supera `SpeedRegular` bajo empuje activo (`combinedWheelTorque = 0`) y manteniendo aislamiento estricto entre combustible `Normal` y `Nitro`.
  - `ServerStorage/ItemAssets/Boosters/SmallBooster/Behaviors/BoosterBehavior.luau`: inicializa `NozzleAttachment`, `FlameEmitter`, `SmokeEmitter`, `NozzleLight` y `ThrustSound` en el modelo runtime sin bucles `Heartbeat` / `Stepped` por pieza, reaccionando por cambios de atributos replicados (`ThrottleFraction`, `BoosterState`).
  - `Security/BuildPayloadValidator.luau` y `Services/BuildService.luau`: validación estricta de `Config.Booster` (`ThrustLimitRatio`, `ThrottleCurveMode`, `Enabled`) y vinculación segura de `InventoryInstanceId` en `PlacePiece` / `UpdatePieceConfig`.
- **Cliente, HUD de Nitro e inspector 3D (`StarterPlayerScripts/Client/Controllers`)**:
  - `BoosterInspectorPanel.luau` (nuevo): panel contextual para propulsores seleccionados en taller con consulta de estadísticas efectivas, cambio de unidad del inventario, ajuste de `ThrustLimitRatio` / `ThrottleCurveMode` / `Enabled` y renderizado de guía visual 3D de dirección de empuje en taller sin colisiones ni físicas.
  - `VehicleDrivingController.luau`: captura entrada de boost en PC (`LeftShift`) y botón táctil (`TouchBoostBtn`), muestra indicadores `BoostBadge`, `NitroLabel` y barra `NitroBarFill` leyendo telemetría `BS_*` del runtime activo.

## Actualización de arquitectura — Fase 4.1 (Daño Estructural y Durabilidad por Pieza)

- **Bootstrap del servidor (`ServerScriptService/Server/Bootstrap.server.lua`)**: inicializa `21` servicios en orden determinista (`Init` → `Start`), incorporando `VehicleDamageService` y `VehicleImpactService`.
- **Módulos compartidos (`ReplicatedStorage/Shared`)**:
  - `Config/DamageConfig.luau`: configuración centralizada e inmutable (`table.freeze`) para estados de salud (`Healthy` / `Damaged` / `Disabled`), umbrales cinemáticos de impacto, deduplicación por par/ráfaga, distribución de choque `1-hop`, perfiles por categoría (`CategoryProfiles`, todos marcados `BalanceStatus = "Provisional_TBD"`), telemetría acotada `DMG_*` y diagnóstico dev.
  - `Damage/DamageMath.luau`: utilidades puras y deterministas (`IsFiniteNumber`, `IsFiniteVector3`, `ComputeClosestPointOnBox`, `ResolveHealthState`, `ComputeEffectiveMass`, `EvaluateImpactKinematics`, `ComputePieceDamage`, `ComputeDistributionPlan`, `ComputeWeightedStructuralIntegrity`).
  - `Types/ItemTypes.luau` y `Types/VehicleTypes.luau`: agregan `"Seats"` a `ItemCategory`, `"PassengerSeat"` a `PartPhysicsRole`, campos opcionales `Stats.ImpactResistance` / `Stats.DamageMultiplier`, `PieceHealthState`, campos de salud en `RuntimePartState`, `PieceAdjacencyById` en `VehicleRuntime`, y tipos de contrato de daño (`DamageImpactContext`, `DamageImpactResult`, `VehicleHealthSummary`, `DebugImpactRecord`).
- **Orquestadores centralizados del servidor (`ServerScriptService/Server/Services`)**:
  - `VehicleAssemblyService.luau`: construye `PieceAdjacencyById` durante el ensamblaje, asigna rol `DriverSeat` vs `PassengerSeat` dentro de la categoría `Seats` (`ResolvePartPhysicsRole`) y expone `SetVehiclesCollideWithEachOther` (default `GameConfig.Runtime.VehiclesCollideWithEachOther = false`).
  - `VehicleDamageService.luau`: registra runtimes por `RuntimeId`, gestiona salud por pieza (`CurrentHealth`, `MaxHealth`, `HealthState`, `DamageReceivedTotal`, `ImpactCount`, `LastImpactAt`, `LastImpactRelativeSpeed`, `LastImpactMagnitude`), aplica impacto localizado (`ApplyImpact`, `ApplyDamage`) con transferencia de choque únicamente `1-hop`, y replica telemetría acotada (`DMG_*`) con intervalo mínimo (`MinReplicationIntervalSeconds = 0.10`) y flush inmediato ante transiciones de estado.
  - `VehicleImpactService.luau`: orquestador único por servidor (cero scripts por pieza). Conecta señales `.Touched` solo en partes físicas colisionables y mantiene un único `RunService.PreSimulation` en `O(vehículos activos)` para capturar snapshots de velocidad lineal/angular y centro de masa previos al solver (`PRE_STEP_VELOCITY_MAX_AGE_SECONDS = 0.08`, `MIN_SOLVER_IMPULSE_DELTA_V = 2.0`), desconectando `PreSimulation` cuando no quedan vehículos activos y limpiando el 100% de conexiones al destruir el runtime.
- **Límites y reglas de asiento actualizadas (`GameConfig.luau`, `BuildService.luau`, `VehicleLaunchPreparationService.luau`)**:
  - `GameConfig.Building.MaxPiecesPerVehicle = 500`.
  - `GameConfig.LaunchPrep.RequiredDriverSeatCount = 1`: `VehicleLaunchPreparationService` permite construir/lanzar con múltiples `PassengerSeat`, y bloquea con error `MultipleDriverSeats` si el ensamblaje primario conecta más de `1` `DriverSeat`.

## Actualización de arquitectura — Fase 4.2 (Fragmentación Estructural y Guardia de Asientos)

- **Bootstrap del servidor (`ServerScriptService/Server/Bootstrap.server.lua`)**: inicializa `23` servicios en orden controlado (`Init` → `Start`), incorporando `VehicleSeatService` y `VehicleDestructionService`.
- **Configuración y tipos compartidos (`ReplicatedStorage/Shared`)**:
  - `Config/DestructionConfig.luau`: configuración inmutable (`table.freeze`) aprobada el `2026-11-15`: `DebrisLifetimeSeconds = 20`, `MaxDebrisPiecesPerRuntime = 500`, `MaxDebrisPiecesServer = 1500` y `DebrisCollisionGroup = "VehicleDebris"`.
  - `Types/VehicleTypes.luau`: agrega estado temporal en `RuntimePartState` (`IsDetached`, `IsDestroyed`) y banderas en `VehicleRuntime` (`IsDestroyed`, `DriverSeatDestroyed`), nunca reflejadas en `VehicleBlueprint`.
- **Servicios autoritativos de destrucción y asientos (`ServerScriptService/Server/Services`)**:
  - `VehicleDestructionService.luau`: registrado tras `VehicleDamageService.ApplyImpact` (`ProcessImpact`). Corta joints externos sobre piezas a `0 HP`, calcula conectividad BFS sobre `PieceAdjacencyById` para aislar el subgrafo superviviente unido al `DriverSeat` (o la mayor isla superviviente como casco pasivo si `DriverSeat` falla), convierte subgrafos desconectados y piezas rotas en modelos `VehicleFragment` temporales marcados `VehicleDebris` con `CollisionGroup = "VehicleDebris"`, conserva `WeldConstraint`s internos, limpia expiraciones (`CleanupExpired` con único `RunService.Heartbeat` dinámico solo cuando existen fragmentos activos) e invalida/notifica al detectar pérdida de ruedas, motores, tanques, boosters o destrucción total (`IsDestroyed`).
  - `VehicleSeatService.luau`: registro autoritativo de `DriverSeat` y `PassengerSeat` (`RegisterRuntime`, `GetRuntimeForHumanoid`, `FindSafeExit`, `ExitHumanoid`, `ForceEjectSeatOccupant`, `DetachSeat`, `UnregisterRuntime`). Bloquea intentos no autorizados de salida (`Sit=false` / `Jump=true`) restaurando el asiento mientras no exista `DriverSeatDestroyed`/`ReturningToWorkshop`, limpia cooldown temporal al liberar el asiento sin dejar estados intermedios atrapados (`clearHumanoidSeatCooldown`), y gestiona la salida segura exclusivamente por `DetachSeat`, destrucción/retorno del runtime o acción explícita `ExitVehicleSeat`.
  - Integración en `VehicleRuntimeService`, `VehicleLifecycleService`, `VehicleWheelControllerService`, `VehiclePowertrainService` y `VehicleBoosterService`: ante separación o `DriverSeatDestroyed`, deshabilitan actuadores/fuerzas de piezas perdidas o cortan conducción en casco pasivo sin invalidar ni destruir prematuramente el `VehicleRuntime`.
- **Cliente, HUD y bloqueo de `Space` (`StarterPlayerScripts/Client/Controllers`)**:
  - `VehicleSeatController.luau`: captura `IsSeated()` y bloquea `Enum.PlayerActions.CharacterJump`, `Enum.KeyCode.Space` y `Enum.KeyCode.ButtonA` con prioridad `ContextActionPriority.High.Value + 1` mientras el jugador ocupa cualquier asiento vehicular.
  - `VehicleDrivingController.luau` y `VehicleManagement.client.luau`: eliminan completamente el control/indicador de freno de mano (`Handbrake`) y conservan exclusivamente el botón `"Salir del asiento"` (`ExitSeatBtn` -> `ExitVehicleSeat`) como salida voluntaria del asiento.
- **Plantilla permanente de parcela (`ServerStorage.BaseTemplate`) y política de limpieza**:
  - `ServerStorage.BaseTemplate` (`Model`, `PrimaryPart = PlotOrigin`, `WorldPivot = (0,0,0)`, **`25` descendientes**) se mantiene como recurso permanente y editable visualmente en Roblox Studio sin script de auto-regeneración en runtime (`Workspace.BaseTemplate_for_test_NO_DELETE_THIS` fue omitido explícitamente por confirmación del desarrollador).
  - Estructura verificada de `25` descendientes: `PlotOrigin (0,0,0)`, `Platform (0,0.5,0; 110x1x110)`, `PlayerSpawn (-30,4.5,8)`, `BuildZone (0,1.0,8; 40x1x40; ZoneId="BuildZone")`, `BuildZone_MARK (0,0.502,8; 40x1x40; ZoneId=nil)`, `LaunchPoint (0,1.5,-34; 40x1x30; ZoneId="LaunchPoint")`, `ShopZone (36,1.5,8; 12x1x14; ZoneId="ShopZone")`, `DeliveryZone (36,1.5,-28; 12x1x14; ZoneId="DeliveryZone")`, `StandZone (-26,1.5,8; 8x1x10; ZoneId="StandZone")`, `VehicleStand` (`PrimaryPart=StandOrigin`, `DisplayPlatform (-26,1.3,8; 6x0.6x8)`, `DisplayAnchor (-26,1.6,8)`, `InteractionPoint (-30,2.25,16)` con `StandPrompt` `"Abrir Elevador"`, `Decorations.StandConsoleBase (-30,1.5,16)`), `Decorations` (`CornerPost_FL/FR/BL/BR` en `(±52,2.5,±52)`), `Structures` (`BackBoundaryCurb (0,1.5,53)`) y carpeta `DynamicRuntime`.
  - **Regla de limpieza segura**: todas las pruebas y operaciones temporales deben registrar referencias explícitas de los objetos temporales creados y verificar su identidad antes de destruirlos, prohibiendo limpiezas por coincidencia parcial (`name:find("Temp")`).

## Actualización de arquitectura — Fase 4.2.1 (Hotfix del Taller y Sistema de 3 Tarjetas de Blueprint)

- **Bootstrap (`24` servicios autoritativos)**: incorpora `BlueprintPersistenceService` junto a `VehicleBlueprintService`, `BuildService`, `ConnectionService`, `EngineInventoryService` y `BoosterInventoryService`.
- **Modelo estricto de estado (`WorkshopDraft` vs `SavedBlueprint` 1..3 vs `VehicleRuntime`)**:
  - El taller del jugador trabaja siempre sobre un borrador independiente (`WorkshopDraft`) con contador `WorkshopEpoch` y rastreo de cambios sin guardar, separado de los `3` slots persistentes (`Slots "1".."3"`).
  - `"Vaciar taller"` (`ClearWorkshop`) borra el borrador activo, reinicia `ConnectionService.ClearPlayer`, limpia `EditableVehicle` (modelo vacío con `0 BasePart`s y `Revision = 0`), incrementa `WorkshopEpoch` y conserva intactos los `3` slots y los inventarios (`EngineInventoryService`, `BoosterInventoryService`).
- **Corrección de desincronización cliente-taller (piezas invisibles / guías fantasma / falso `BelowFloor`)**:
  - Ante limpiezas o cambios de slot (`WorkshopCleared`, `BlueprintLoaded`, `BlueprintReset`, `ReplacedWorkshop`), `BuildState`, `BuildPreviewController.InvalidateWorkshopCaches`, `BuildGridVisualizer.Destroy()`, `BuildPlacementController` y `BuildTransformController` invalidan sus cachés locales de `EditableVehicle` y aceptan reemplazos autoritativos en `Revision = 0`.
  - Cuando llega un reemplazo autoritativo sobre el mismo borrador sin cambio real de taller (`if switchedBlueprint or replacedWorkshop` en `BuildState.ApplyAuthoritativeBlueprint`), la sesión de transformación activa no se descarta por timeout.
  - La provisión idempotente de unidades controladas (`EnsureControlledWorkshopUnits`) vincula inventario sin duplicar motores o propulsores al guardar/cargar/vaciar.
- **UI de 3 tarjetas (`VehicleManagement.client.luau`, `BlueprintManagerController.luau`)**:
  - Se retiran por completo el botón heredado `"Recargar"` y `"QuickSaveBtn"`, reemplazándolos por `"Vaciar taller"` (`ClearWorkshop`) y tarjetas de `3` slots con acciones explícitas (`"Guardar vehículo del taller"`, `"Sobrescribir"`, `"Renombrar"`, `"Eliminar"`), manteniendo los paneles contextuales coordinados.
- **Límite único de `DriverSeat` en taller (confirmado según regla #10 de `AGENTS.md`)**:
  - `GameConfig.Blueprints.MaxDriverSeatsPerBlueprint = 1` se aplica directamente al colocar en `BuildService` (`TooManyDriverSeats`), en validación/importación (`VehicleBlueprintService`) y como defensa en profundidad en `VehicleLaunchPreparationService` (`MultipleDriverSeats` / `AmbiguousPrimaryAssembly`).

## Actualización de arquitectura — Fase 5.1 (Inventario Central Autorizado y Catálogo en Español)

- **Bootstrap (`26` servicios autoritativos) y persistencia compartida**:
  - `Bootstrap.server.lua` incorpora `InventoryPersistenceService` e `InventoryService` antes de `EngineInventoryService` y `BoosterInventoryService` dentro de `SERVICE_LOAD_ORDER`.
  - `Server/Security/DataStoreIoHelper.luau` centraliza bloqueos exclusivos por `UserId`, aislamiento en memoria para pruebas (`_useMemoryStoreForTests`) y respaldo automático en memoria únicamente cuando Studio tiene deshabilitado el acceso a APIs.
- **Inventario central autoritativo (`InventoryService.luau`, `InventoryPersistenceService.luau`)**:
  - Capacidad ilimitada administrada exclusivamente por el servidor con dos modalidades definidas en `ItemRegistry` / `ItemTypes`: piezas acumulables por cantidad (`InventoryKind = "Stackable"`: bloques, ruedas, asientos y tanques) y unidades individuales con `ItemInstanceId` propio (`InventoryKind = "UniqueUnit"`: motores `Engines` y propulsores `Boosters`).
  - `EngineInventoryService` y `BoosterInventoryService` delegan el almacenamiento y persistencia de sus unidades en `InventoryService`, manteniendo una única fuente de verdad (las provisiones sintéticas legacy quedan aisladas bajo el flag de prueba `AutoGrantLegacySuiteQuota`, desactivado en producción).
  - **Kit inicial configurable (`GameConfig.StartingInventory`)**: se entrega atómicamente **una sola vez** por jugador al inicializar su inventario (`StarterKitGranted = true`, `StarterKitVersion = 1`): `20 WoodBlock`, `10 WoodBeam`, `4 SmallWheel`, `1 DriverSeat`, `1 RegularFuelTank`, `1 SmallNitroTank`, `1 SmallEngine` (`Small · Balanced · StandardCombustion · Common`) y `1 SmallBooster` (`Small · Balanced · StandardRocket · Common`). Nunca se reentrega tras reconexión ni cuando falla la carga de `DataStoreService`.
- **Integración con construcción, 3 tarjetas y desvinculación selectiva (`BuildService`, `VehicleBlueprintService`)**:
  - `BuildService.ProcessRequest` valida existencias al colocar piezas (`InventoryService.ValidatePlacement`), auto-asigna una unidad propia disponible cuando se omite `InventoryInstanceId` en ítems únicos (regla A4) o rechaza con `InsufficientInventory`, y expone `GetInventory`, `SellInventoryItem` (venta atómica sin manipular dinero aún: `SellPrice = nil`, `SellValue = nil` TBD) y `UnlinkInventoryFromBlueprints`.
  - `VehicleBlueprintService` registra un `BlueprintUsageProvider` desacoplado sobre `InventoryService`: calcula la reserva acumulable como `MAX(Taller, Slot 1..3)` (sin sumar repeticiones entre slots) y rastrea referencias exactas de cada `InventoryInstanceId`; rechaza cargas que excedan el inventario disponible (`ValidateBlueprintForLoad`) y permite desvincular selectivamente una pieza o unidad en slots/taller seleccionados reconstruyendo conexiones sin eliminar el resto del diseño. Tanto `SellInventoryItem` como `UnlinkInventoryFromBlueprints` se bloquean (`InvalidPlayerState`) si el jugador tiene un vehículo activo fuera del taller.
- **Catálogo unificado y carpetas físicas en español (`ItemCatalog`, `ItemRegistry`, `PreviewAssetService`)**:
  - `ReplicatedStorage/Shared/Catalog/ItemCatalog.luau` centraliza nombres visibles, descripciones, categorías y carpetas en español (`DisplayName`, `Description`, `CategoryDisplayName`, `AssetFolder`).
  - `DriverSeat` pasa a categoría `"Seats"` (`"Asientos"`), y las carpetas físicas de `ServerStorage.ItemAssets` y `ReplicatedStorage.PreviewAssets` se reorganizan en español (`Bloques`, `Ruedas`, `Motores`, `Asientos`, `Tanques`, `Propulsores`) resueltas dinámicamente por `ItemRegistry.GetAssetFolder` y `ItemRegistry.ResolveModel`.
  - En cliente (`BuildController`, `VehicleManagement`, `BuildState`, `BlueprintManagerController`, `EngineInspectorPanel`, `BoosterInspectorPanel`), el catálogo muestra textos y disponibilidad `(disponibles/poseídos)`, agrega botón `"Inventario"` con panel dedicado (`InventoryPanel`), botones `"Vender"` / `"Desvincular"` y modal de confirmación, manteniendo el flujo existente de las 3 tarjetas de blueprints y sin solapar UI.

## Actualización de arquitectura — Fase 5.2 (Tienda, Pedidos, Cajas Especiales, Economía e Ingresos Offline)

- **Bootstrap (`34` servicios autoritativos) y contratos compartidos**:
  - `Bootstrap.server.lua` incorpora `EconomyPersistenceService` y `EconomyService` justo después de `InventoryService`, y cierra el orden de arranque con `OrderPersistenceService`, `ShopStockService`, `LootBoxService`, `DeliveryService`, `OfflineIncomeService` y `ShopService`.
  - `ReplicatedStorage/Shared/` agrega [ShopConfig.luau](file:///c:/Users/rataatrevida/Desktop/BuildEnginners/src/ReplicatedStorage/Shared/Config/ShopConfig.luau), [LootBoxConfig.luau](file:///c:/Users/rataatrevida/Desktop/BuildEnginners/src/ReplicatedStorage/Shared/Config/LootBoxConfig.luau) y [ShopProtocol.luau](file:///c:/Users/rataatrevida/Desktop/BuildEnginners/src/ReplicatedStorage/Shared/Building/ShopProtocol.luau) (`ShopOperationRequest` y `ShopSyncEvent`).
- **Economía, venta y stock compartido por servidor (`EconomyService`, `EconomyPersistenceService`, `ShopStockService`, `LootBoxService`)**:
  - `EconomyService` otorga `ShopConfig.Economy.StartingMoney` (`1,000` monedas) una sola vez por jugador (`StarterMoneyGranted = true`), ejecuta débitos/créditos atómicos con rollback y registra un `SellPayoutProvider` en `InventoryService` que paga `50%` redondeado hacia abajo en piezas normales y mantiene bloqueada la venta monetaria de unidades únicas sin precio individual.
  - `ShopStockService` administra cupos compartidos únicamente dentro de la instancia actual del servidor: ejecuta un restock inicial al arrancar (`1..3` por caja habilitada) y reemplaza estrictamente el stock cada `300 s` (sin acumular).
  - `LootBoxService` prevalida los pools de `LootBoxConfig` contra `EngineCatalog`, `BoosterCatalog` e `ItemRegistry` y ejecuta sorteos ponderados autoritativos (`RolledLootReward`) exclusivamente en servidor.
- **Pedidos independientes, entregas en `DeliveryZone` y utilerías visuales (`OrderPersistenceService`, `DeliveryService`, `PlotService`, `ServerStorage.Crates`)**:
  - `DeliveryService` coordina dos colas de pedidos independientes con timestamps absolutos persistentes (`NormalOrderWaitSeconds = 60` que desbloquea nuevas compras al alcanzar `Status = "Arrived"` y `SpecialOrderWaitSeconds = 900`), un bucle central sobre `RunService.Heartbeat` para completar llegadas e iniciar entregas sin reiniciar temporizadores al reconectar, cola justa compartida en `DeliveryZone` (`VisualCapacity = 6`) y sorteos persistidos idempotentes al abrir cajas especiales.
  - `PlotService` incorpora el contenedor aislado `ShopDeliveryContainer` por parcela (limpiado en `Release` sin interferir con `DynamicContainer`) donde `DeliveryService` monta el mostrador `ShopCounter` con `OpenShopPrompt` en `ShopZone`, la secuencia visual sin asientos de `DeliveryTruck` (`TruckCollisionGroup = "DeliveryProps"`) fuera de `BuildZone`, cajas físicas con `OpenCratePrompt` y el reveal desechable con `BillboardGui`.
- **Aceleración Robux, ingresos offline de motores y UI cliente (`OfflineIncomeService`, `ShopService`, `ShopController`, `ShopUI`)**:
  - `ShopService` conecta `MarketplaceService.ProcessReceipt` con idempotencia por `PurchaseId` tanto para `Pedir ahora` (`~5 s`) como para publicidad recompensada oficial (`AdService` + `Enum.ProductPurchaseChannel.AdReward`).
  - `OfflineIncomeService` acumula ganancias pasivas exclusivamente a partir de motores únicos poseídos en `InventoryService`, deduplicados por `ItemInstanceId` entre taller y los `3` slots.
  - En cliente, `ShopController` y `ShopUI.client.luau` renderizan `EconomyHudDock`, `ShopPanel` (`Componentes Normales`, `Cajas de Motores`, `Cajas de Propulsores`, `Mis Pedidos`) con cuenta regresiva de restock/pedidos y `OfflineIncomeModal` (`Recoger` y `Recoger ×5`), mientras `VehicleManagement.client.luau` refleja la política de venta del `50%`.
- **Aerodinámica Modular por Superficie (`AerodynamicsService`, Fase 5.3)**:
  - Orquestador único en servidor (`RunService.Heartbeat`, servicio `#35` en `Bootstrap.server.lua`) sin scripts por pieza ni clasificación global del vehículo ("auto", "avión", "cohete").
  - Configuración centralizada en `ReplicatedStorage/Shared/Config/AerodynamicsConfig.luau` (`BalanceStatus = "Provisional_TBD"`): constantes físicas globales (`AirDensity`, `DynamicPressureScale`, `MinAirspeedStudsPerSec`, topes por superficie y por vehículo) y perfiles de las 6 piezas (`AircraftWingLeft`, `AircraftWingRight`, `AircraftWing`, `AircraftTail`, `LargeGliderWing`, `SmallGliderWing`).
  - Cada superficie aerodinámica viva calcula su velocidad local 3D en su centro de presión ($\vec{v}_{\text{punto}} = \vec{v}_{\text{CoM}} + \vec{\omega} \times (\vec{x}_{\text{att}} - \vec{x}_{\text{CoM}})$), ángulo de ataque $\alpha$, pérdida aerodinámica (`StallAngleDeg`) con caída suave de $C_L$ y aumento de arrastre por estela desprendida, resistencia siempre opuesta al flujo y fuerza restauradora lateral/vertical en `AircraftTail` (`VerticalStabilizerArea`).
  - Las fuerzas se aplican en el mundo mediante `VectorForce` (`AeroVectorForce`, `ApplyAtCenterOfMass = false`, `RelativeTo = Enum.ActuatorRelativeTo.World`) sobre `AeroForceAttachment` en cada pieza, generando torques físicos reales alrededor del centro de masa según la posición y simetría de montaje.
  - Rendimiento al `100%` bajo daño parcial (`CurrentHealth > 0`) y desactivación inmediata con destrucción de `VectorForce` al llegar a `0 HP`, desprenderse en `VehicleDestructionService` o regresar al taller (`ReturnToWorkshop`).
  - Preparado arquitectónicamente para superficies de control futuras (`ControlRole = "Aileron" | "Elevator" | "Rudder"`, `SetControlInputs`) sin implementar aún controles de vuelo ni motores de avión.
