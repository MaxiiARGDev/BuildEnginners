# 05 — Construcción, física y daño

## Editor
- Área de edición de cada estación (`BuildZone`), vista previa local, colocación, traslación, rotación, borrado, snap a conexiones, guías de alineación inteligentes y validación autoritativa del servidor.
- **Modos de posicionamiento y precisión (Fase 2.3.1)**:
  - **Modo Grid (`[F]`)**: paso configurable en `1`, `0.5`, `0.25` (predeterminado) y `0.1` studs, con histéresis (`0.08`) y cuadrícula contextual local proyectada sobre la cara objetivo (`BuildGridVisualizer` vía pool de `LineHandleAdornment`, 0 Parts).
  - **Modo Libre (`[F]`)**: posicionamiento continuo hasta `0.01` studs (`FreeFineStep = 0.01`), permitiendo centrar libremente vigas y bloques sin saltos rígidos ni omisión de límites, solapamientos o conexiones.
  - **Snap Inteligente (`[J]`) y Guías (`[H]`)**: alineación determinista por prioridad (`Conn_*` -> centro de cara -> centro de pieza -> bordes -> contacto de superficie -> ejes principales) con bloqueo por eje e histéresis (`0.10`); si `SmartSnap` está desactivado, las guías permanecen informativas sin forzar posición.
- **Gizmos 3D y políticas de rotación (`ItemRegistry.PlacementPolicy`)**:
  - Herramientas **Colocar**, **Mover (`[G]`)** (ejes X/Y/Z sin salto inicial) y **Rotar (`[V]`)** (anillos X/Y/Z con desenrollado angular continuo > 360° e incrementos `90°`, `45°`, `15°`, `1°`).
  - Los 8 ítems actuales del SDD conservan `Orthogonal90` por defecto; nuevas piezas pueden declarar `StepDegrees` o `Free` en `PlacementPolicy`.
  - Tras confirmar (`ConfirmTransform` / soltar gizmo / `Enter`), `BuildService` valida límites compuestos (`ComputePieceLocalAABB` + `ValidateBoundsMinMax`), política de rotación (`BuildSnapPolicy`) y solapamiento SAT OBB (`ConnectionMath.BoxesOverlap` sobre `PartBoxes`) de forma autoritativa sin destruir ni recrear toda la escena.
- **Construcción libre multi-ensamblaje y modo `FaceSnap` (Fase 2.4.2)**:
  - **Piezas desconectadas y ensamblajes independientes**: el taller admite colocar, mover con gizmos, rotar, eliminar (incluso piezas puente intermedias) y guardar/recargar piezas sueltas o múltiples ensamblajes separados sin rechazar por `DisconnectedPiece` ni `WouldDisconnectVehicle`. El grafo explícito (`Connections`) nunca une automáticamente piezas solo cercanas visualmente; cada pieza se clasifica dinámicamente en `PrimaryAssembly`, `SecondaryAssembly` o `LoosePiece`.
  - **Modo `FaceSnap` automático (`[K]`)**: botón `FaceSnap: ON/OFF [K]` en `PrecisionBar` que acopla caras opuestas (`dot <= -0.985`, `gap = 0`) sobre OBBs simples y sub-cajas compuestas (`PartBoxes`) en las 6 direcciones y cualquier rotación compatible, conservando la rotación elegida por el jugador, rechazando solapamientos o salidas de `BuildZone` / piso efectivo, estabilizado por histéresis (`FaceLockState`) y visualizado con bordes + normal + punto de contacto (`BuildFaceSnapVisualizer`).
  - **Orden estricto del pipeline de snaps**: `1. SmartSnap (Attachments Conn_*)` -> `2. FaceSnap (cara con cara OBB)` -> `3. Grid / 4. Free`, garantizando ausencia de doble snap contradictorio sobre una misma colocación.
- Stand desplaza vehículo completo (incluidas piezas sueltas y grupos secundarios) arriba/abajo/izquierda/derecha en modo edición; no altera offsets relativos de piezas.
- Servidor valida límites de zona, intersecciones, presupuesto de piezas, cantidad disponible y propiedad.

## Modelo de construcción
- Blueprint: lista de piezas con `InstanceId`, `ItemId`, transform local, `InventoryInstanceId` cuando corresponda, configuración y conexiones explícitas de articulaciones.
- Cada pieza tiene geometría y puntos de conexión declarados.
- Estructuras rígidas con `WeldConstraint`; ruedas con constraints articulados.
- Componentes funcionales se coordinan por controlador de vehículo, sin script Heartbeat por pieza.

## Lanzamiento
1. Servidor congela revisión de blueprint autorizada.
2. Genera runtime independiente centrado en `LaunchPoint`.
3. Inicializa durabilidad de todas las piezas a `MaxDurability` y estado temporal de combustible.
4. Construye uniones y articulaciones, habilita fuerzas y control.
5. Desancla solo lo necesario y habilita conducción.

## Daño
- No calcular daño únicamente por `Touched`.
- Estimar severidad de impacto a partir de velocidad relativa y contexto físico, con umbrales y debounce.
- Servidor mantiene `CurrentDurability` por `partInstanceId` en runtime.
- A 0 HP: deshabilitar comportamiento, quitar conexiones, identificar grupos desconectados mediante grafo de conectividad y permitir desprendimientos.
- Escombros temporales con cleanup automático.
- Evitar exploits derivados de NetworkOwnership y reportes falsos de colisiones; la metodología exacta de validación se ajustará mediante pruebas.

## Regreso
- Destruir runtime, detener simuladores y limpiar escombros.
- Reubicar personaje en estación y reconstituir representación de edición desde blueprint.
- Restaurar durabilidad completa sin gastar piezas ni dinero.
- El blueprint nunca recibe cambios de daño.

## Criterios de prueba
- Romper rueda no borra su entrada en blueprint.
- Romper un bloque central desconecta únicamente grupos sin ruta de conexión.
- Dos piezas conectadas por otra ruta permanecen unidas.
- Tras Return, posiciones, configuraciones, rarezas y durabilidad son idénticas a las anteriores al lanzamiento.
- Llamar Return dos veces no duplica vehículo ni inventario.

## Stand físico (Elevador de Construcción) y Preparación de Lanzamiento (Fase 2.4 / 2.4.1)
- **Modelo físico en Studio (`ServerStorage.BaseTemplate.VehicleStand`)**: construido físicamente mediante Roblox Studio MCP (no generado por scripts ni `.model.json`) con `StandOrigin` (`PrimaryPart`), `DisplayPlatform`, `DisplayAnchor`, `Decorations` e `InteractionPoint` con `StandPrompt` (`ObjectText = "Elevador de Construcción"`, `ActionText = "Abrir Elevador"`), manteniendo compatibilidad con `StandZone`.
- **Elevador directo sobre `EditableVehicle` (Fase 2.4.1)**: el stand funciona como elevador mecánico de taller dentro de `BuildZone` sobre `Plot_<NN>.DynamicRuntime.EditableVehicle`, sin clonar modelos duplicados `StandPreview` (`StandPreviewService` actúa como stub de compatibilidad).
  - **Límites dinámicos y no mutación del diseño**: mueve el ensamblaje en altura (`Y`, hasta `MaxHeightOffset = 16`) y lateral (`X`, `-10..+10`) dentro de `LiftBounds` dinámicos calculados según la envolvente actual del vehículo para evitar atravesar `Platform` o los límites de `BuildZone`, rechazando colisiones espaciales externas con `ElevatorBlocked`. Los `LocalCFrame` relativos guardados en `VehicleBlueprint` nunca se alteran al mover el elevador.
  - **Construcción bajo chasis y herramientas alineadas**: al elevar el vehículo queda accesible su parte inferior (`SmallEngine`, `SmallWheel`, etc.); `BuildGridVisualizer`, `BuildAlignmentGuides`, `BuildMoveGizmo`, `BuildRotationGizmo`, colocación en Grid / SmartSnap / Libre y edición respetan `EffectiveBuildZoneCFrame` y el piso físico efectivo (`FloorY`). Al guardar, el blueprint conserva presentación neutral `(0, 0)` y al recargar diseños con piezas inferiores el elevador calcula la altura mínima necesaria para apoyarlas limpiamente sobre `Platform` sin marcar cambios pendientes.
  - **Pulsación continua**: `StandController` soporta pasos puntuales y hold continuo tras `0.18 s` (`4.0` studs/s normal, `1.0` stud/s fino), aplicando previsualización local optimista y sincronizando al servidor de forma coalescida a un máximo de `10 Hz` (`ContinuousSyncIntervalSeconds = 0.10`) con rollback automático si el servidor rechaza el movimiento.
- **Validación de lanzamiento en `LaunchPoint`**: `VehicleLaunchPreparationService` evalúa de forma no destructiva únicamente el ensamblaje primario (`PrimaryAssembly`) dejando fuera piezas sueltas o grupos secundarios del taller (`WorkshopPieceCount` / `WorkshopPieceIds`):
  - Si hay exactamente 1 componente conexo con `DriverSeat`, se selecciona automáticamente como `PrimaryAssembly`. Si existen >= 2 grupos desconectados con `DriverSeat` y no se eligió uno vía `SelectPrimaryAssembly`, reporta `AmbiguousPrimaryAssembly` (`NeedsPrimarySelection = true`).
  - Verifica definiciones válidas del catálogo, ausencia de superposición OBB (`SpecsOverlap`), 1 `DriverSeat` funcional dentro de `PrimaryAssembly`, límites de volumen, despeje vertical (`0.05` studs sobre `Platform`) y ausencia de obstrucciones espaciales, clasificando fallos en `BuildError`, `ConfigError` y `LocationError` sin crear todavía `VehicleRuntime` y permaneciendo invariante respecto a los offsets temporales del elevador.
  - `ComputePieceLaunchWorldCFrames` transforma exclusivamente las piezas pertenecientes a `PrimaryAssembly`, excluyendo todo resto suelto del taller.

## `VehicleRuntime`, Ensamblaje Físico y Ciclo de Lanzamiento (Fase 3.1)
- **Separación estricta Taller vs Simulación**:
  - `ActiveBlueprint` permanece congelado e inmutable durante todo el ciclo de lanzamiento, conducción, desmontaje, reinicio y retorno al taller; el offset temporal del elevador (`BuildAssemblyOffset`) no desplaza al vehículo en `LaunchPoint`.
  - Piezas clasificadas como `SecondaryAssembly` o `LoosePiece` permanecen en el taller (`EditableVehicle`) y nunca entran al modelo `VehicleRuntime`.
- **Ensamblaje determinista en staging (`VehicleAssemblyService`)**:
  - Construye un modelo `VehicleRuntime` aislado en `ServerStorage._VehicleRuntimeStaging` clonando únicamente assets autorizados de `ServerStorage.ItemAssets`, limpiando scripts internos no autorizados y preservando `ItemId`, `PieceInstanceId` y `Config`.
  - Genera un `WeldConstraint` deduplicado en carpeta `Joints` por cada par único en `Blueprint.Connections` (complejidad `O(E)` sin enlaces cuadráticos `O(N^2)`), asigna `PartPhysicsRole` (`RigidStructure`, `DriverSeat`, `FutureWheel`, `FuturePropulsion`, `Decorative`), marca temporalmente las uniones de ruedas como `TemporaryWheelWeld = true` para articulación en Fase 3.2 y mantiene `DriverSeat` sin propulsión en Fase 3.1 (`MaxSpeed = 0`, `Torque = 0`, `TurnSpeed = 0`).
  - Registra `CollisionGroups`: `EditorGhost` no colisiona con nada; `EditableVehicle` no colisiona con `EditableVehicle`, `EditorGhost` ni `VehicleRuntime`; y `VehicleRuntime` colisiona con el mundo `Default` pero es configurable entre vehículos (`VehiclesCollideWithEachOther = false` por defecto).
- **Activación física, montaje y retorno (`VehicleRuntimeService`, `VehicleLifecycleService`, `VehicleLaunchService`)**:
  - Antes de desanclar el modelo ya publicado en `Plot_<NN>.DynamicRuntime`, pone en cero `AssemblyLinearVelocity` y `AssemblyAngularVelocity` de todos los `BasePart`s e inicializa `ItemRuntimeService.InitPart`.
  - Aplica `NetworkOwnership` al dueño únicamente en estado `Driving` tras confirmar que el `Humanoid` del propietario ocupa el `DriverSeat`, devolviendo ownership al servidor (`nil`) cuando pasa a `OnFootRuntime`.
  - Soporta `ExitVehicleSeat` (`Driving -> OnFootRuntime`, dejando el vehículo estacionado temporalmente hasta `AbandonedTimeoutSeconds = 300`), `ResetVehicle` (regeneración limpia desde el blueprint intacto en `LaunchPoint`) y `ReturnToWorkshop` (desmonte limpio de `SeatWeld`, destrucción total de `VehicleRuntime` y `ItemRuntimeService`, reposicionamiento en `PlayerSpawn` y reapertura del modo `Editing`).
  - **Alcance diferido a Fase 3.3+**: propulsión activa de motores/propulsores (consumiendo la interfaz de `VehicleWheelControllerService`), consumo de combustible y cálculo/aplicación de daño estructural.

## Sistema Híbrido de Ruedas, Suspensión y Dirección (Fase 3.2)
- **Precedencia híbrida estricta (`Defaults < Auto < Manual`)**:
  - `WheelAutoConfiguration` analiza las ruedas conectadas al `PrimaryAssembly` usando `DriverSeat` único cuando existe (con advertencia no bloqueante e heurística geométrica cuando falta o hay ambigüedad), agrupa ejes por posición longitudinal y clasifica rol longitudinal (`Front`, `Middle`, `Rear`, `SingleAxle`) y lateral (`Left`, `Center`, `Right`).
  - Por defecto, en configuraciones estándar (`>= 2` ejes), el eje delantero habilita dirección automática (`28°`, `180°/s`) y los demás permanecen rectos; todas las ruedas con eje horizontal habilitan suspensión calibrada automáticamente según la masa real suspendida medida (`AutoSpringOmega = 14`, relación de amortiguación `0.70` con tope `AutoSpringMaxDamping = 520` para estabilidad PGS).
  - Cualquier override manual almacenado en `Piece.Config.Wheel` sobrescribe exclusivamente ese campo; los campos omitidos revierten individualmente a `Auto` y `ResetToAuto = true` limpia `Piece.Config`.
- **Articulación modular sin `TemporaryWheelWeld` (`WheelMechanismBuilder`)**:
  - Cada rueda se vincula al chasis mediante `SuspensionCarrier` (`PrismaticConstraint` + `SpringConstraint` con precarga estática), `SteeringPivot` opcional (`HingeConstraint` en modo `Servo`, `SteeringServoMaxTorque = 150000`) y `AxleHinge` (`HingeConstraint` en modo `Motor`) normalizado siempre a `-VehicleRight` con independencia de rotación izquierda (`0°`) o derecha (`180°`), además de `NoCollisionConstraint`s preventivas contra la pieza soporte y partes cercanas del chasis.
  - Los núcleos virtuales internos (`Carrier_*`, `Pivot_*`) tienen `CanCollide = false` para no rozar terreno ni carrocería; las propiedades físicas del neumático (`Friction` escalada desde `Grip`, `Elasticity = 0.12`) se aplican en runtime al publicar.
- **Control centralizado por vehículo y contrato motriz Fase 3.3 (`VehicleWheelControllerService`)**:
  - Un único bucle `RunService.Heartbeat` actualiza todos los vehículos activos: transforma `DriverSeat.SteerFloat` (`-1` izquierda `+`, `+1` derecha `-`) con velocidad limitada por rueda (`SteeringSpeed`), centra a `0°` si el asiento queda vacío o deshabilitado y mantiene rodamiento pasivo (`PassiveRollingFrictionTorque = 0.45`, sin autopropulsión).
  - Contrato expuesto para motores y acelerador de Fase 3.3: `SetWheelDriveCommand`, `SetVehicleDriveCommands`, `ClearDriveCommands`, `GetVehicleWheels` y `GetWheelState` (reportando `ContactState` por raycast, `SuspensionLength`, `SteeringAngle`, `AngularVelocity` e integridad `IsFunctional`).

## Tren Motriz Modular, Curva de Par y Transmisión de Potencia (Fase 3.3)
- **Modelo físico y curva de par por RPM (`EngineCatalog` + `VehiclePowertrainService`)**:
  - Cada motor conectado al `PrimaryAssembly` opera entre `IdleRPM = 900`, banda óptima `PeakTorqueRPMMin = 2200 .. PeakTorqueRPMMax = 4400` y `MaxRPM = 6000` (escalado según variante/rareza).
  - La curva normalizada entrega `IdleTorqueFraction = 0.42` en ralentí, sube suavemente a `1.00` en la banda óptima, decae a `RedlineTorqueFraction = 0.72` al acercarse al corte y activa histéresis de limitador en `LimiterActivationFraction = 0.985` hasta caer bajo `LimiterReleaseFraction = 0.94`.
  - Respuesta progresiva del acelerador gobernada por `ThrottleSpoolUpRate` (`6.5 /s` base, escalado por `ResponseRate`) y `ThrottleSpoolDownRate = 9.0 /s`, más freno motor (`EngineBrakingTorqueFraction = 0.14`) al soltar el acelerador.
- **Caja automática de 4 velocidades + reversa y sensibilidad a pendiente/masa**:
  - Relaciones hacia adelante `{ 2.85, 1.90, 1.32, 1.00 }` y reversa `2.60` (`ReverseMaxSpeedFraction = 0.48`), con enfriamiento entre cambios (`GearShiftCooldownSeconds = 0.28`) y reducción automática de marcha cuando la pendiente longitudinal supera `SlopeDownshiftThresholdDeg = 10°`.
  - La velocidad lineal objetivo se suaviza según la relación potencia/masa real del ensamblaje (`TotalVehicleMass`, incluyendo el peso efectivo por tamaño/variante/rareza de cada motor), de modo que un chasis pesado acelera y sube pendientes con menor aceleración salvo que agregue más motores.
- **Combinación de múltiples motores y degradación temporal**:
  - Con $N$ motores funcionales ordenados por torque descendente, el motor $i$ aporta con factor de rendimientos decrecientes $0.92^{i-1}$ hasta el tope técnico `MaxCombinedTorqueCap = 65000`, y la velocidad punta combinada pondera la media con una bonificación logarítmica acotada (`MultiEngineSpeedBonusPerExtra = 0.04`, máx `+12%`).
  - Cada motor escala su salida en runtime según su salud temporal `HealthFactor = clamp(CurrentDurability / MaxDurability, 0, 1)`; a `0` durabilidad queda inoperativo en `VehicleRuntime` sin alterar jamás el `Blueprint`.
- **Distribución a ruedas motrices y controles longitudinales**:
  - El torque total de rueda (`TotalEngineTorque * ActiveGearRatio * DrivetrainEfficiency`) se reparte equitativamente entre las ruedas funcionales con `IsDriven = true`; las ruedas con `IsDriven = false` reciben `Torque = 0` y giran libremente. Si existen motores pero `0` ruedas motrices, se reporta `NoDrivenWheelsError = true` sin movimiento.
  - Estado longitudinal seguro: `S` aplica `Braking` mientras el vehículo avanza por encima de `ReverseEngageMaxForwardSpeed = 2.5 studs/s` y solo engrana `Reverse` desde reposo o baja velocidad (el freno de mano `Handbrake` / `Space` de Fase 3.3 fue eliminado definitivamente en Fase 4.2 para impedir expulsiones y bloquear el salto en asiento).

## Propulsores Modulares, Nitro y Empuje Vectorial (Fase 3.4)
- **Empuje vectorial PGS 3D (`VehicleBoosterService`)**:
  - Cada propulsor en `PrimaryAssembly` mantiene una única `BoosterVectorForce` (`VectorForce`) aplicada sobre su propio `PrimaryPart` en dirección de mundo siguiendo la orientación real de colocación (`-Z` local / `LookVector`). Según montaje y simetría respecto al centro de masa (`AssemblyCenterOfMass`), genera aceleración lineal hacia adelante, guiñada asimétrica si está desplazado lateralmente, desaceleración/empuje inverso en montaje frontal invertido o sustentación vertical si apunta hacia `+Y`.
  - Envolvente de velocidad escalada con `BaseEnvelopeSpeedStudsPerSec = 42.0`, `SpeedMultiplierRangeScale = 38.0` y `HighSpeedTaperFloor = 0.12` (`Provisional_TBD`), curvas configurables (`Instant`, `Smooth`, `Sustained`) y limitador de empuje por pieza (`ThrustLimitRatio = 0.25 .. 1.0`).
- **Aislamiento de Nitro y embrague unidireccional**:
  - La reserva `RocketFuel` suma únicamente depósitos integrados de propulsores funcionales (`SmallBooster = 24000`) y tanques `SmallNitroTank` (`28800`), sin consumir ni alterar el depósito de combustible normal (`SmallEngine` + `RegularFuelTank`). Al agotarse emite corte `OutOfNitro = true` / estado `"Depleted"` devolviendo todas las `BoosterVectorForce` a `Vector3.zero`.
  - Durante combustión activa por encima de la velocidad lineal máxima efectiva del motor, `VehiclePowertrainService` desacopla las ruedas motrices (`CombinedWheelTorque = 0`, embrague unidireccional) para evitar que la resistencia de transmisión frene el empuje de los propulsores.
- **Degradación temporal por durabilidad y montaje válido sin motor/ruedas motrices**:
  - Un vehículo con propulsores y `DriverSeat` pasa `VehicleLaunchPreparationService` sin requerir obligatoriamente motor o ruedas motrices.
  - La eficiencia de empuje en runtime escala según `CurrentDurability / MaxDurability` (`1.0` a `100%`, `0.85` a `50%`, caída lineal hasta `0.35` y corte completo por debajo de `MinimumOperationalDurabilityFraction = 0.05`) sin modificar el `Blueprint` persistido.

## Implementación actual — Fase 4.1 (Daño Estructural y Durabilidad por Pieza)

- **Alcance estricto de Fase 4.1 (detección + acumulación localizada de daño por pieza)**:
  - Cada pieza física del `VehicleRuntime` posee salud estructural temporal independiente (`CurrentHealth`, `MaxHealth`, `HealthState = "Healthy" | "Damaged" | "Disabled"`, `DamageReceivedTotal`, `ImpactCount`, `LastImpactAt`, `LastImpactRelativeSpeed`, `LastImpactMagnitude`).
  - Separación estricta `Blueprint` vs `VehicleRuntime`: **nunca** se persiste daño en el blueprint; `ReturnToWorkshop` y relanzamiento restauran `100.00%` de salud.
  - **Sin funciones de Fases 4.2 / 4.3**: en Fase 4.1 no hay separación ni destrucción física de joints/piezas (`IsDetached = false`, `DetachedParts = {}`, `WeldConstraint`s y `WheelConstraints` intactos) y el daño estructural de colisión no altera ni bloquea todavía el funcionamiento de motor, ruedas ni propulsores (`IsFunctional = true`, `DurabilityEfficiencyFactor = 1.0`, `CurrentDurability` preservado).
- **Pipeline físico de impactos (`VehicleImpactService` + `DamageMath`)**:
  - `VehicleImpactService` captura snapshots pre-solver en un único `RunService.PreSimulation` centralizado por servidor (`CurrLinearVel`/`PrevLinearVel`, `CurrAngularVel`/`PrevAngularVel`, `CurrCenterOfMass`/`PrevCenterOfMass`, `PRE_STEP_VELOCITY_MAX_AGE_SECONDS = 0.08`) para evitar leer velocidades ya rebotadas durante `.Touched`, validando además delta-v del solver (`MIN_SOLVER_IMPULSE_DELTA_V = 2.0`).
  - Filtros y deduplicación (`DamageConfig`, `Provisional_TBD`): umbral mínimo `MinImpactSpeedStudsPerSec = 14.0` / `MinNormalSpeedStudsPerSec = 12.0` (`NormalSpeedWeight = 1.0`, `TangentialSpeedWeight = 0.12`, `HighSpeedScrapeOverrideSpeed = 48.0`), ventana de estabilización inicial al desanclar (`LaunchSettlingGraceSeconds = 0.25`, `GraceOverrideNormalSpeed = 24.0`), masa efectiva (`ReferenceMass = 50.0`, `MassExponent = 0.35`, clamp `0.55..3.00`), curva (`DamageScale = 0.16`, `DamageExponent = 1.35`, techo `MaxSingleImpactRawDamage = 2500.0`, piso `MinDamageThreshold = 1.5`), cooldown `(pieza, objetivo) = 0.28 s`, ventana de ráfaga `0.12 s` con máximo `8` impactos procesados y cooldown vehículo-vehículo `0.20 s`.
- **Distribución localizada `1-hop`**:
  - Usando `VehicleRuntime.PieceAdjacencyById`, el impacto se concentra en la pieza golpeada (`PrimaryDirectShareWithNeighbors = 0.85`) y amortigua hasta `MaxAdjacentNeighbors = 6` vecinos directos (`MaxAdjacentTransferShare = 0.15`, `AdjacentDistanceAttenuation = 0.25`, `MaxAdjacentDistanceStuds = 10.0`, `MinDistributedPieceDamage = 0.40`, `MaxPropagationHops = 1`). Piezas a distancia `>= 2` hops reciben `0` daño.

## Implementación actual — Fase 4.2 (Fragmentación Estructural, Limpieza de Subsistemas y Guardia de Asientos)

- **Alcance estricto de Fase 4.2 (rotura física temporal + aislamiento por grafo)**:
  - Toda pieza física cuyo `CurrentHealth == 0` (`HealthState == "Disabled"`) pasa a `IsDestroyed = true`, `IsDetached = true` y rompe sus uniones externas con el vehículo sin modificar el `Blueprint` persistido ni los inventarios.
  - **BFS sobre `PieceAdjacencyById` (`VehicleDestructionService.ComputeComponents`)**: calcula los subgrafos conexos supervivientes en tiempo real. Si el `DriverSeat` sigue vivo, su componente permanece como vehículo activo; los demás subgrupos aislados se convierten en modelos físicos `VehicleFragment` en `CollisionGroup = "VehicleDebris"` (`Vehicles`/`Debris`/`EditableVehicle`/`EditorGhost` sin colisión entre sí), preservando sus `WeldConstraint`s internos. Si cae el `DriverSeat`, el mayor componente superviviente pasa a casco pasivo (`DriverSeatDestroyed = true`, conservando la integridad de piezas restantes hasta agotarse o regresar al taller); si no quedan piezas vivas, `runtime.IsDestroyed = true`.
- **Ciclo de vida de escombros (`DestructionConfig`)**:
  - `DebrisLifetimeSeconds = 20`: expiración determinista limpiada en servidor por `VehicleDestructionService.CleanupExpired` y purgada de inmediato al usar `ReturnToWorkshop` o limpiar runtimes.
  - Capacidad acotada a `MaxPiecesPerVehicle = 500`, `MaxDebrisPiecesPerRuntime = 500` escombros por vehículo y `MaxDebrisPiecesServer = 1500` por servidor con expulsión FIFO automática del fragmento más antiguo al superar el límite.
- **Limpieza física por tipo de pieza y guardia de asientos**:
  - **Ruedas (`VehicleWheelControllerService`)**: al romperse o separarse una rueda o su chasis soporte, se desactivan sus `HingeConstraint`s / objetivos de torque y dirección y se remueve su entrada activa del paso de conducción.
  - **Propulsores (`VehicleBoosterService`) y Motores/Tanques (`VehiclePowertrainService`)**: boosters, tanques Nitro, motores o tanques de combustible destruidos/desacoplados cortan sus `BoosterVectorForce` o aportación de torque/capacidad, actualizando al instante `BS_*` y `PT_*`.
  - **Asientos (`VehicleSeatService` + `VehicleSeatController`)**: `Space` queda bloqueado en conducción/pasajero sin freno de mano ni UI residual; salidas involuntarias (`Sit=false`, `Jump=true`) quedan revertidas autoritativamente por el servidor, y solo la destrucción del asiento (`DetachSeat`) o el botón `"Salir del asiento"` (`ExitSeatBtn` -> `ExitVehicleSeat`) expulsan al jugador al punto seguro preservando el salto normal (`Space`) una vez fuera del vehículo. Todo desprendimiento deja inmutables el `Blueprint` y los inventarios, y `ReturnToWorkshop` restaura el `100%` de HP y piezas.
- **Reservado para Fase 4.3**: degradación parcial/progresiva de rendimiento y consumo por daño intermedio (`> 0` HP) y efectos VFX/audio avanzados de impacto/humo/fuego.

## Implementación actual — Fase 5.3 (Sistema de Aerodinámica Modular)

- **Principio emergente por pieza (`AerodynamicsService` + `AerodynamicsConfig`)**:
  - Ningún vehículo se clasifica como auto, avión o cohete, ni se exige motor de avión para generar sustentación. Un auto con ruedas y `SmallEngine` más `LargeGliderWing`, un cohete con `SmallBooster` más alas o un vehículo híbrido completo generan sustentación, resistencia y momentos aerodinámicos únicamente por las piezas físicas conectadas.
  - En cada `RunService.Heartbeat`, cada superficie funcional calcula la velocidad puntual real en su centro de presión ($\vec{v}_{\text{punto}} = \vec{v}_{\text{CoM}} + \vec{\omega} \times (\vec{x}_{\text{att}} - \vec{x}_{\text{CoM}})$), proyecta el flujo relativo $\vec{u} = \vec{v}_{\text{viento}} - \vec{v}_{\text{punto}}$ en sus ejes locales (`ForwardAxisLocal = (0,0,-1)`, `LiftNormalAxisLocal = (0,1,0)`, `SpanAxisLocal = (1,0,0)`), obtiene el ángulo de ataque $\alpha$ y aplica:
    - **Sustentación**: $L = q \cdot S \cdot C_L(\alpha)$ perpendicular al flujo en el plano cuerda-normal, con crecimiento cuadrático respecto a la velocidad y caída suave post-pérdida cuando $|\alpha| > \text{StallAngleDeg}$.
    - **Resistencia**: $D = q \cdot S \cdot C_D(\alpha)$ estrictamente opuesta a la velocidad relativa ($-\hat{v}_{\text{rel}}$), sumando resistencia parásita, inducida ($k C_L^2$), form drag de área frontal proyectada (`\sin\alpha`) e incremento de estela en entrada en pérdida.
    - **Estabilidad pasiva de cola (`AircraftTail`)**: plano horizontal restaurador en cabeceo y deriva vertical (`VerticalStabilizerArea = 8.5`) restauradora en guiñada ante ángulo de derrape lateral $\beta$, más amortiguación rotacional (`PitchDampingFactor`, `YawDampingFactor`).
- **Aplicación en centro de presión y daño estructural**:
  - Cada superficie viva posee un `AeroVectorForce` (`ApplyAtCenterOfMass = false`, `RelativeTo = Enum.ActuatorRelativeTo.World`) sobre `AeroForceAttachment` en `CenterOfPressureLocalOffset`. Una sola ala lateral produce momento real de alabeo (roll), mientras dos alas simétricas (`AircraftWingLeft` + `AircraftWingRight`) equilibran el momento lateral y duplican la sustentación.
  - Mientras `CurrentHealth > 0`, la pieza conserva el `100%` de su capacidad aerodinámica (sin degradación progresiva). Al llegar a `0 HP`, destruirse o separarse en un `VehicleFragment` (`VehicleDestructionService`), o al ejecutar `ReturnToWorkshop`, su `AeroVectorForce` se pone a cero y se destruye inmediatamente.
