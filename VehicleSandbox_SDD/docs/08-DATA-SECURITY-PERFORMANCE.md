# 08 — Persistencia, seguridad y rendimiento

## Datos persistentes por jugador (propuesta)
- `SchemaVersion`, `Money`, `Inventory` (instancias únicas), `Blueprints`, `ActiveBlueprintId`, `PendingDeliveries`, `MissionProgress`, `Unlocks`.
- NO persistir `CurrentDurability` del runtime ni restos de choque.
- `InventoryInstanceId` único para motores/propulsores con rareza.
- Migraciones versionadas; límite de tamaño de blueprint y compresión/serialización donde sea necesario.

## Estado efímero por servidor
- Asignación de estaciones, stock local, tiempo hasta próximo camión, misiones activas de servidor, runtime de vehículos.
- Determinar qué estado efímero debe recuperarse tras reinicio para evitar pérdidas de compras.

## Seguridad
- Validar ownership, distancia/área de edición, cantidades, ID de objeto, rate limits, transformaciones, precios y revisiones.
- No permitir remotes que alteren HP, dinero, resultados de cajas o inventario sin lógica de servidor.
- Control de operaciones concurrentes e idempotencia de compras, entregas y retorno.
- Los cambios del cliente son propuestas, no autoridad.

## Rendimiento
- Objetivo: respuesta visual de construcción inmediata; medir tiempo de ack real.
- Probar 10 jugadores con vehículos activos y cargas progresivas de piezas/constraints.
- Configurar límites de piezas, escombros y distancia de simulación tras perfilar; valores TBD.
- Usar StreamingEnabled para mapa extenso, pooling donde convenga y limpieza de efectos temporales.
- Evitar un `Heartbeat` por pieza y recalcular grafo solo al cambiar conectividad.

## Observabilidad
- Métricas: tiempo de colocación local/ack, tiempo de lanzamiento, piezas por vehículo, constraints, errores de validación, tiempo de retorno, colisiones, uso de memoria y latencia percibida.

## Implementación Fase 2.3 (Seguridad, Optimización y Benchmarks en Roblox Studio)
- **Seguridad activa en `BuildService`**: límite `TokenBucket` (`25` burst / `20` ops/s escritura; `10` burst / `10` ops/s lectura) antes de validaciones geométricas o asignación de `Blueprint`; validación estricta con `BuildPayloadValidator`; idempotencia FIFO acotada (`MaxCachedOpIdsPerPlayer = 256`); propiedad derivada exclusivamente de `PlotService`; índice espacial AABB (`SpatialCellSize = 4`), caché geométrica congelada por `ItemId` y grafo incremental de vecindad en `ConnectionService`.
- **Benchmarks E2E reales medidos en Roblox Studio (`ServerScriptService.Server.Benchmarks.BuildBenchmarks`, vehículos mixtos conectados de 25 a 200 piezas)**:

| Piezas | PlaceLast (ms) | PlaceAvg10 (ms) | ConnVal (ms) | SmartSnap (ms) | DelLeaf (ms) | DelNode (ms) | Snapshot (ms) | Modelos | Descendants | HeapDelta (KB) | TotalMem (MB) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 25 | 0.452 | 0.279 | 0.230 | 0.005 | 0.002 | 0.001 | 0.015 | 25 | 200 | 390.0 | 2313.48 |
| 50 | 0.261 | 0.439 | 0.358 | 0.013 | 0.006 | 0.002 | 0.064 | 50 | 400 | 1453.0 | 2316.28 |
| 100 | 0.400 | 0.544 | 0.033 | 0.109 | 0.004 | 0.002 | 0.166 | 100 | 800 | 4054.0 | 2323.28 |
| 200 | 0.776 | 0.530 | 0.008 | 0.280 | 0.004 | 0.006 | 0.086 | 200 | 2400 | -13879.0 | 2329.90 |

> Nota: `HeapDelta` negativo en `200` refleja recolección de basura automática de Luau ocurrida durante la ejecución; `ConnVal` se midió sobre un punto fijo de sonda (`(10, 2.5, 10)`), que pasa de espacio adyacente/libre a contacto/solapamiento según crece la estructura.
- **Extensiones de Fase 2.3.1 (Editor Avanzado, SAT OBB y Cero Asignaciones por Frame)**:
  - `BuildService` valida `TransformPiece` bajo el mismo `TokenBucket`, `BuildPayloadValidator` (chequeo de matriz ortonormal + ausencia de NaN/Inf + campos permitidos), `BuildSnapPolicy.ValidateRotationForItem`, colisión OBB exacta por Teorema del Eje Separador (`ConnectionMath.obbAxesOverlap`, ruta rápida AABB en piezas ortogonales a 90°) y verificación de conectividad estructural global tras mover (`WouldDisconnectVehicle`), preservando coordenadas continuas hasta `0.01` studs en modo Libre y actualizando `EditableVehicle` de forma incremental.
  - `BuildGridVisualizer`, `BuildAlignmentGuides`, `BuildMoveGizmo` y `BuildRotationGizmo` utilizan pools fijos de `HandleAdornment`s (`0` `Part`s por frame, con `AlwaysOnTop = false` en cámara para renderizado nativo de cliente) y `BuildAlignmentMath.ComputeAlignments` acota sus búsquedas por índice espacial (`AlignmentGuideRadius = 0.75`, < `5.0` ms por cuadro cerca de 25 piezas validado en `Phase1Tests [40]`).
- **Pruebas multicliente**: validadas en Roblox Studio con 1 cliente real en vivo (`Play`) + simulación automatizada en servidor para 10 jugadores simultáneos (`Phase1Tests`: 40/40 previas + 25 de `Phase24Tests`, total `65/65`). La sesión física Team Test con múltiples ventanas cliente simultáneas queda pendiente de verificación manual fuera del MCP de Studio.
- **Seguridad Fase 2.4 y 2.4.1 (Elevador de Construcción)**:
  - `BuildPayloadValidator` aplica validación estructural estricta de cargas y exime `ClientOpId` obligatorio únicamente en lecturas idempotentes (`GetBlueprint`, `ListBlueprints`, `ValidateLaunchPrep`), validando formato seguro si se envía.
  - `BuildService` reutiliza idempotencia por `ClientOpId`, cubeta `"Read"` en `TokenBucket` para lecturas/diagnósticos, `ExpectedBlueprintId` para descartar respuestas fuera de orden y verificación autoritativa de propiedad por `PlotId` antes de mutar blueprints o mover el elevador.
  - En `SetStandOffset`/`ResetStandOffset` (Fase 2.4.1), el servidor rechaza `NaN`/`Inf` y valores fuera de los `LiftBounds` dinámicos actuales, exige intersección física efectiva con `BuildZone` y ejecuta detección espacial de obstrucciones externas (`ElevatorBlocked`) mediante broadphase O(1) y comprobación OBB por pieza sin colisionar contra la `Platform` por apoyo exacto.
  - En cliente (`StandController`), el movimiento continuo al mantener botones pulsados (`ContinuousHoldDelaySeconds = 0.18`) coalesce envíos RPC a `<= 10 Hz` (`ContinuousSyncIntervalSeconds = 0.10`) con máximo 1 solicitud en vuelo y barrido final al soltar, evitando saturar el `TokenBucket` y revirtiendo en UI si el servidor rechaza.
- **Benchmarks Fase 2.4.2 observados en Studio Server (`BuildBenchmarks.RunAll({ 25, 50, 100, 200 })`)**:

| Piezas | PlaceLast (ms) | ConnVal (ms) | Snap (ms) | Save (ms) | LoadRebuild (ms) | StandOffset (ms) | LaunchPrep (ms) | Models | Descendants | TotalMem (MB) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 25 | 0.594 | 0.005 | 0.009 | 0.040 | 3.748 | 0.258 | 0.214 | 25 | 200 | 2624.04 |
| 50 | 0.385 | 0.004 | 0.007 | 0.131 | 7.824 | 0.454 | 0.750 | 50 | 400 | 2624.38 |
| 100 | 0.462 | 0.020 | 0.067 | 0.143 | 13.714 | 1.226 | 1.485 | 100 | 800 | 2625.82 |
| 200 | 0.709 | 0.005 | 0.214 | 0.494 | 42.126 | 2.321 | 6.821 | 200 | 2400 | 2641.21 |

- **Seguridad y rendimiento Fase 2.4.2 (`FaceSnap` + Multi-Ensamblaje)**:
  - `BuildPayloadValidator` valida estrictamente la acción `SelectPrimaryAssembly` (`GroupId` string no vacío acotado y `ExpectedBlueprintId` opcional), mientras `BuildService` persiste `Metadata.PrimaryAssemblyGroupId` tras verificar que la componente exista en `ConnectionService.AnalyzeBlueprintAssemblies`.
  - La validación autoritativa de límites (`BuildGrid.ValidateBoundsMinMax`) y solapamientos (`ConnectionMath.AnyOverlap`) evalúa sub-cajas compuestas (`PartBoxes`) cacheadas por `ItemId`, evitando rechazos por AABB global en modelos cóncavos sin asignación por cuadro en cliente.
  - `FaceSnapMath.ComputeFaceSnap` consulta únicamente vecinos dentro de `SpatialIndex:QueryAABB`, manteniendo un costo medio medido en Roblox Studio de `0.187 ms/llamada` cerca de `30` piezas (con pool fijo de `5` líneas + `1` esfera en `BuildFaceSnapVisualizer`, `0 BasePart`s temporales).

- **Seguridad y aislamiento Fase 3.1 (`VehicleRuntime` y ciclo de lanzamiento)**:
  - `BuildPayloadValidator` valida estrictamente `LaunchVehicle`, `ReturnToWorkshop`, `ResetVehicle`, `ExitVehicleSeat` y `GetRuntimeState`, rechazando campos de autoridad inyectados (`PlotId`, `OwnerUserId`, etc.) con `InvalidPayload` antes de alcanzar el servicio; `GetRuntimeState` utiliza cubeta `"Read"` en `TokenBucket` y las mutaciones consumen `"Write"`.
  - `VehicleLaunchService` exige propiedad verificada del plot (`PlotService.IsOwner`), exclusión mutua por jugador (`LaunchInProgress`) y cooldown (`LaunchCooldownSeconds = 0.75`); `BuildService` rechaza con `InvalidPlayerState` toda operación de edición, guardado/carga o elevador mientras `VehicleLifecycleService.CanEditBlueprint(player)` sea falso.
  - `VehicleAssemblyService` sanitiza scripts ejecutables (`LuaSourceContainer`) o constraints preexistentes al clonar modelos de `ItemAssets`; `VehicleLifecycleService` expulsa al instante a jugadores ajenos al propietario que intenten sentarse en un `DriverSeat`, y `VehicleRuntimeService` devuelve `NetworkOwnership` al servidor (`nil`) apenas el vehículo queda en `OnFootRuntime`.
  - **Benchmarks E2E Fase 3.1 observados en Studio Server (`BuildBenchmarks.RunAll({ 25, 50, 100, 200 })`)**:

| Piezas | PlaceLast (ms) | ConnVal (ms) | Snap (ms) | Save (ms) | LoadRebuild (ms) | LaunchPrep (ms) | RtLaunch (ms) | RtClean (ms) | RtJoints | Modelos | TotalMem (MB) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 25 | 0.306 | 0.003 | 0.005 | 0.039 | 4.944 | 0.250 | 6.651 | 1.605 | 36 | 25 | 2667.61 |
| 50 | 0.503 | 0.006 | 0.007 | 0.143 | 8.536 | 0.790 | 10.778 | 2.331 | 84 | 50 | 2668.25 |
| 100 | 0.432 | 0.023 | 0.071 | 0.579 | 16.411 | 2.215 | 21.511 | 4.777 | 179 | 100 | 2669.59 |
| 200 | 0.750 | 0.006 | 0.248 | 0.557 | 39.665 | 6.408 | 58.491 | 14.098 | 370 | 200 | 2680.03 |

  - **Benchmark concurrente multi-jugador Fase 3.1 (`BuildBenchmarks.MeasureMultiPlayerLaunch({ 1, 2, 5, 10 })`, 25 piezas/vehículo)**:

| Jugadores | Piezas/Veh | TotalLaunch (ms) | AvgPerPlayer (ms) | TotalClean (ms) | TotalMem (MB) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 25 | 5.885 | 5.885 | 1.376 | 2667.71 |
| 2 | 25 | 10.024 | 5.012 | 2.545 | 2667.90 |
| 5 | 25 | 26.804 | 5.361 | 7.135 | 2669.13 |
| 10 | 25 | 52.807 | 5.281 | 13.446 | 2673.45 |

## Seguridad y Rendimiento Fase 3.2 (Sistema Híbrido de Ruedas)
- **Validación autoritativa y saneamiento (`BuildPayloadValidator.ValidateWheelConfigTable`)**:
  - `UpdatePieceConfig` y `PlacePiece.Config` en piezas de categoría `Wheels` restringen las claves permitidas exclusivamente a `Config.Wheel`, validan cada campo numérico finito dentro de rangos congelados de `GameConfig.Wheels` (`MaxSteeringAngle` `0..45`, `SteeringSpeed` `30..360`, `SuspensionTravel` `0.1..2.0`, `SpringStiffness` `100..100000`, `SpringDamping` `10..10000`, `RideHeight` `-0.6..0.6`, multiplicadores `-1 | 1`), rechazan piezas no configurables (`PieceNotConfigurable`), valores fuera de rango (`InvalidConfigRange`), modificaciones fuera de modo `Editing` (`InvalidPlayerState`) y peticiones de no propietarios, preservando idempotencia FIFO por `ClientOpId` y límite de tasa `TokenBucket`.
  - Límite de entradas recursivas de `Config` fijado en `GameConfig.Building.MaxConfigEntries = 32` (`MaxConfigDepth = 2`) para admitir configuraciones completas de rueda sin abrir vectores de payload arbitrario.
- **Arquitectura sin bucles por pieza**: `VehicleWheelControllerService` procesa todos los vehículos y ruedas registrados desde un solo `RunService.Heartbeat`.
- **Benchmarks reales observados en Roblox Studio Server (`BuildBenchmarks`)**:
  - **Suite general `BuildBenchmarks.RunAll({ 25, 50, 100, 200 })`**:

| Piezas | PlaceLast (ms) | ConnVal (ms) | Snap (ms) | Save (ms) | LoadRebuild (ms) | LaunchPrep (ms) | RtLaunch (ms) | RtClean (ms) | RtJoints | Modelos | TotalMem (MB) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 25 | 0.321 | 0.003 | 0.005 | 0.090 | 5.867 | 0.284 | 5.215 | 1.148 | 36 | 25 | 2854.15 |
| 50 | 0.280 | 0.004 | 0.006 | 0.103 | 9.189 | 0.763 | 14.232 | 4.005 | 84 | 50 | 2855.58 |
| 100 | 0.713 | 0.021 | 0.118 | 0.267 | 21.222 | 3.029 | 25.058 | 7.851 | 179 | 100 | 2851.20 |
| 200 | 1.030 | 0.007 | 0.288 | 0.698 | 42.276 | 7.462 | 60.855 | 15.863 | 370 | 200 | 2861.34 |

  - **Escalado de ruedas articuladas (`BuildBenchmarks.MeasureWheelConfigurations({ 2, 4, 6, 8, 12 })`)**:

| Ruedas | Piezas Totales | Analyze (ms) | Launch (ms) | StepAvg 60f (ms) | WheelConstraints | RtJoints | Clean (ms) | TotalMem (MB) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | 6 | 0.015 | 2.077 | 0.0140 | 16 | 3 | 0.852 | 2870.05 |
| 4 | 7 | 0.021 | 2.976 | 0.0278 | 32 | 2 | 0.892 | 2870.24 |
| 6 | 10 | 0.029 | 5.091 | 0.0514 | 48 | 3 | 1.202 | 2870.53 |
| 8 | 13 | 0.039 | 6.348 | 0.0459 | 62 | 4 | 1.743 | 2870.84 |
| 12 | 19 | 0.083 | 8.302 | 0.0700 | 90 | 6 | 2.497 | 2871.36 |

  - **Concurrencia multi-jugador con 4 ruedas suspendidas/direccionales (`BuildBenchmarks.MeasureWheelConcurrentPlayers({ 1, 2, 5, 10 })`)**:

| Jugadores | Ruedas Totales | TotalLaunch (ms) | AvgPerPlayer (ms) | CentralStepAvg (ms) | TotalClean (ms) | TotalMem (MB) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 4 | 3.359 | 3.359 | 0.0268 | 0.882 | 2871.57 |
| 2 | 8 | 7.450 | 3.725 | 0.0583 | 2.085 | 2872.04 |
| 5 | 20 | 19.131 | 3.826 | 0.1867 | 5.232 | 2873.28 |
| 10 | 40 | 41.645 | 4.164 | 0.3768 | 10.348 | 2876.28 |

## Seguridad y Rendimiento Fase 3.3 (Motores Modulares y Tren Motriz)
- **Validación autoritativa y anti-falsificación (`BuildPayloadValidator` + `EngineInventoryService` + `VehiclePowertrainService`)**:
  - `BuildPayloadValidator.ValidateEngineConfigTable` y `ValidateFuelTankConfigTable` bloquean cualquier intento del cliente de enviar estadísticas crudas en `Config` (`FORBIDDEN_DIRECT_STATS_KEYS`: `Torque`, `MaxSpeed`, `EffectiveStats`, `DrivingBonus`, `Weight`, `MaxDurability`, etc. -> `InvalidEngineConfig`).
  - Cuando el cliente referencia un `ItemInstanceId` / `InventoryInstanceId`, el servidor resuelve `EngineSizeId`, `VariantId`, `RarityId` y `EffectiveStats` exclusivamente desde `EngineInventoryService`, rechazando unidades inexistentes (`EngineUnitNotFound`), de otro jugador (`EngineUnitNotOwned`) o ya asignadas a otra pieza (`EngineUnitAlreadyInUse`).
  - Los comandos de conducción (`SetDrivingInput` / `DrivingInputRemoteEvent`) se validan con `ValidateDrivingInput` (`Throttle`, `Brake`, `RawLongitudinal`, `Steer` finitos en `-1..1`; en Fase 4.2 se retiró el campo `Handbrake`) y `VehiclePowertrainService` exige que el emisor sea el propietario del `VehicleRuntime` y esté sentado en `DriverSeat` (`NotSeatedDriver`, `NotRuntimeOwner`).
- **Benchmarks reales de Tren Motriz medidos en Roblox Studio (`BuildBenchmarks.RunPowertrainBenchmarks()`)**:

| Métrica | Valor medido | Presupuesto / Meta |
| --- | ---: | ---: |
| Resolución determinista de variante + rareza (`EngineCatalog.ResolveEngineEffectiveStats`) | `3.105 µs` (`0.0031 ms`) | `< 0.05 ms` |
| Creación de contexto `Powertrain` + lanzamiento (1 motor, 4 ruedas) | `7.150 ms` | `< 25.0 ms` |
| Paso de simulación `StepAll` (`1` motor + `4` ruedas, promedio 120 pasos) | `0.1884 ms` | `< 0.50 ms` |
| Paso de simulación `StepAll` (`3` motores + `6` ruedas, promedio 120 pasos) | `0.2320 ms` | `< 0.75 ms` |
| Lanzamiento concurrente de `10` vehículos (`20` motores, `40` ruedas) | `76.991 ms` (`7.70 ms/veh`) | `< 150.0 ms` |
| Paso centralizado concurrente `10` vehículos (`Powertrain + Wheels`, 120 pasos) | `1.7887 ms` | `< 4.00 ms` |
| Total constraints físicas para `10` vehículos (`20` motores, `40` ruedas) | `410` (`41/veh`) | Lineal `O(W + E)` |
| Limpieza total de `10` vehículos (`ReturnToWorkshop`, `ActiveAfterClean = 0`) | `27.185 ms` | `< 50.0 ms` |
| Memoria total de Studio tras ciclo completo | `2480.79 MB` (`HeapDelta = +8977 KB`) | Sin fugas de runtime |

## Verificación de Seguridad y Rendimiento — Fase 4.1 (Daño Estructural y 500 Piezas)

### Garantías de seguridad e invariantes de servidor
- **Autoridad exclusiva del servidor**: toda detección física (`VehicleImpactService`), validación cinemática, cálculo y mutación de salud (`VehicleDamageService`) ocurre en el servidor. No existen `RemoteEvent`s de daño enviables por el cliente.
- **Anti-spoof / saneamiento numérico**: `DamageMath.IsFiniteNumber` y `DamageMath.IsFiniteVector3` rechazan `NaN`/`inf` y valores no positivos; velocidades relativas se acotan a `MaxTrackedRelativeSpeedStudsPerSec = 350.0` y cada impacto a `MaxSingleImpactRawDamage = 2500.0`.
- **Cero scripts por pieza**: un único orquestador `VehicleImpactService` y un único `VehicleDamageService` para todo el servidor. `RunService.PreSimulation` se conecta únicamente mientras hay al menos `1` runtime activo.
- **Telemetría acotada**: atributos `DMG_*` sincronizados con intervalo mínimo `MinReplicationIntervalSeconds = 0.10` (flush inmediato solo cuando cambia `HealthState`) y limpieza determinística (`0` conexiones `.Touched` y `0` registros retenidos al limpiar).

### Resultados reales de Benchmarks Fase 4.1 (`BuildBenchmarks.MeasurePhase41DamageBenchmarks`) en `Play -> Server`

| Piezas | Launch (ms) | TrackedConns | TrackedParts | ImpactEval (us) | ApplyDmg (us) | Summary (us) | Cleanup (ms) | HeapDelta (KB) | Mem (MB) | RemConns/Dmg/Imp |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `100` | `49.117` | `100` | `100` | `426.28` | `15.60` | `1.47` | `8.355` | `3025.0` | `2843.12` | `0/0/0` |
| `250` | `110.496` | `250` | `250` | `148.70` | `15.21` | `0.96` | `18.974` | `5520.0` | `2851.31` | `0/0/0` |
| `500` | `208.517` | `500` | `500` | `148.92` | `41.00` | `3.66` | `36.621` | `0.0` | `2930.72` | `0/0/0` |

- **Stress concurrente de `10` jugadores (`15` piezas/vehículo)**:
  - `LaunchTotal = 84.566 ms`
  - `100` impactos evaluados en `15.182 ms` (`151.82 us/impacto`)
  - `PeakConns = 150`
  - `CleanupTotal = 25.436 ms`
  - `Mem = 2936.99 MB`, `Remaining = 0/0/0/0` (cero fugas de conexiones ni entradas activas).

### Resultados reales de Benchmarks generales (`BuildBenchmarks.RunAll` hasta `500` piezas, `GameConfig.Building.MaxPiecesPerVehicle = 500`)

| Piezas | PlaceLast (ms) | ConnVal (ms) | Snap (ms) | Save (ms) | LoadRebuild (ms) | LaunchPrep (ms) | RtLaunch (ms) | RtClean (ms) | RtJoints | Models | TotalMem (MB) |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `25` | `0.308` | `0.006` | `0.005` | `1.309` | `5.791` | `0.265` | `8.921` | `1.905` | `36` | `25` | `2877.62` |
| `50` | `0.322` | `0.009` | `0.005` | `2.934` | `11.770` | `0.614` | `15.353` | `3.193` | `84` | `50` | `2878.80` |
| `100` | `0.511` | `0.072` | `0.078` | `9.028` | `23.566` | `3.490` | `30.372` | `6.570` | `179` | `100` | `2873.93` |
| `250` | `0.988` | `0.050` | `0.158` | `53.543` | `99.337` | `9.840` | `97.082` | `19.232` | `595` | `250` | `2890.84` |
| `500` | `2.033` | `0.112` | `0.291` | `161.357` | `231.785` | `29.245` | `225.225` | `40.740` | `1300` | `500` | `3004.53` |

## Verificación de Seguridad, Límites y Rendimiento — Fase 4.2 (Fragmentación Estructural y Guardia de Asientos)

### Invariantes autoritativos del servidor
- **Autoridad de destrucción y expulsión de asientos**: solo el servidor ejecuta el corte BFS de conectividad (`VehicleDestructionService`), spawnea `VehicleFragment` en `DestructionConfig.DebrisCollisionGroup = "VehicleDebris"`, gestiona expiración TTL (`DebrisLifetimeSeconds = 20`) y controla montaje/salida de asientos (`VehicleSeatService`). El cliente no puede expulsar ocupantes ni forzar abandono con `Space`/`Jump`: `VehicleSeatService` revierte salidas no autorizadas mientras el asiento no haya sido destruido (`DetachSeat`) ni solicitado explícitamente `"Salir del asiento"` (`ExitVehicleSeat`).
- **Topes estrictos de piezas y escombros (`DestructionConfig.luau`, `GameConfig.luau`)**: `MaxPiecesPerVehicle = 500`, `MaxDebrisPiecesPerRuntime = 500` y `MaxDebrisPiecesServer = 1500` con expulsión FIFO determinista al exceder cuota; la limpieza de escombros en `RunService.Heartbeat` solo mantiene conexión activa cuando `Fragments > 0` (`Connections = 0` en reposo y tras `ReturnToWorkshop`).
- **Aislamiento sin corrupción de persistencia**: ni `VehicleDestructionService` ni `VehicleSeatService` escriben en `VehicleBlueprint` o inventarios (`EngineInventoryService` / `BoosterInventoryService`).

### Benchmarks reales tras el cierre de Fase 4.2 (`Roblox Studio`, modo `Play -> Server`)
- **`BuildBenchmarks.MeasurePhase41DamageBenchmarks` (`Play -> Server`)**:
  - `100` piezas: `Launch = 43.94 ms`, `ApplyImpact = 0.90 µs`, `Cleanup = 9.42 ms`.
  - `250` piezas: `Launch = 95.06 ms`, `ApplyImpact = 2.61 µs`, `Cleanup = 28.22 ms`.
  - `500` piezas: `Launch = 230.66 ms`, `ApplyImpact = 1.13 µs`, `Cleanup = 67.43 ms`.
  - `10` jugadores concurrentes (`15` piezas/vehículo): `TotalLaunch = 105.15 ms`, `AvgImpact = 330.8 µs`, `TotalCleanup = 36.22 ms`, `0` residuales.
- **`BuildBenchmarks.RunBoosterBenchmarks()` (`Play -> Server`)**:
  - `BoosterVehicleLaunchMs = 13.21 ms`, `SingleVehicle2BoostersStepAvgMs = 0.102 ms`, `TenVehiclesConcurrentStepAvgMs = 1.08 ms` (`250` constraints), `ActiveRuntimesAfterCleanup = 0`, `LuaHeapDeltaKB = 0`.
- **`BuildBenchmarks.RunPowertrainBenchmarks()` (`Play -> Server`)**:
  - `SingleEngine4WheelsStepAvgMs = 0.258 ms`, `TenVehiclesConcurrentStepAvgMs = 2.18 ms` (`410` constraints), `ActiveRuntimesAfterCleanup = 0`, `LuaHeapDeltaKB = 0`.
- **`BuildBenchmarks.MeasureMultiPlayerLaunch()` (`25` piezas/vehículo, `Play -> Server`)**:
  - `1` jugador: `10.01 ms` | `2` jugadores: `20.77 ms` | `5` jugadores: `51.00 ms` | `10` jugadores: `109.82 ms` (`TotalCleanupMs = 2.60 ms .. 25.93 ms`).
- **Nota de entorno**: lugar guardado en Roblox Team Create (`placeId 76082808712440`, versión `219`); servidor local `rojo serve default.project.json` activo en `localhost:34872` sin conexión activa del plugin Rojo en Studio durante esta sesión Team Create.

## Seguridad, Persistencia y Validación — Fase 4.2.1 (3 Tarjetas y Migración v1 → v2)

- **Persistencia autoritativa en servidor (`BlueprintPersistenceService.luau`, `BlueprintSerializer.luau`)**:
  - `GameConfig.Blueprints` define `StorageSchemaVersion = 2`, `MaxSlots = 3`, `MaxSavedBlueprintsPerPlayer = 3`, `MaxNameLength = 32`, `MinNameLength = 1`, `DataStoreName = "BuildEngineers_PlayerBlueprints_v2"`, `LegacyDataStoreName = "BuildEngineers_PlayerBlueprints_v1"`, `MaxDriverSeatsPerBlueprint = 1` y `MaxLegacyOverflowEntries = 20`.
  - Cada jugador persiste sus slots `"1".."3"`, su `WorkshopDraft` opcional y `LegacyOverflow` con bloqueo exclusivo por `UserId` (`_ioLocksByUserId`) y propagación honesta de errores: ante fallo de lectura o escritura, el servidor retorna `PersistenceFailed` y revierte su estado en memoria sin confirmar guardados falsos.
  - **Migración no destructiva heredada**: al cargar datos legacy v1 (hasta `10` blueprints), los `3` diseños más recientes pasan a `Slots 1..3` y los diseños restantes se conservan íntegros en `LegacyOverflow`, recuperables bajo demanda mediante `RecoverLegacyBlueprint` sin eliminar diseños previos.
  - **Aislamiento de pruebas**: `_ResetForTests()` activa `_useMemoryStoreForTests = true` en `BlueprintPersistenceService` para que las suites automatizadas nunca lean ni ensucien `DataStoreService` real en Roblox Cloud, mientras `Bootstrap` en juego real utiliza `DataStoreService` directamente (con respaldo automático en memoria únicamente si Studio tiene deshabilitado el acceso a APIs).
- **Candados de protocolo y validación (`BuildPayloadValidator.luau`, `BuildService.luau`, `VehicleBlueprintService.luau`)**:
  - Validación estricta de solicitudes (`ClearWorkshop`, `SaveBlueprintSlot`, `OverwriteBlueprintSlot`, `LoadBlueprintSlot`, `RenameBlueprint`, `RenameBlueprintSlot`, `DeleteBlueprintSlot`, `ListBlueprintSlots`, `SaveAndClearWorkshop`, `RecoverLegacyBlueprint`) con bloqueo de concurrencia por jugador, idempotencia por `ClientOpId`, validación de `WorkshopEpoch`/`Revision`, confirmación de dos pasos (`ConfirmationStep = 2`) para sobrescrituras y confirmación nominal exacta (`ConfirmationName`) para eliminar tarjetas.
  - `RenameBlueprint` valida longitud/caracteres/filtro de texto tanto en tarjetas guardadas como sobre el borrador activo en taller; `ImportSerializedBlueprint` mapea excesos por encima de `MaxPiecesPerVehicle` (`500`) al código explícito `MaxPiecesReached`, y `BuildService` rechaza un segundo `DriverSeat` al colocar (`TooManyDriverSeats`).

## Seguridad, Persistencia y Validación — Fase 5.1 (Inventario Central)

- **Persistencia autoritativa de inventario y blueprints (`InventoryPersistenceService.luau`, `BlueprintPersistenceService.luau`, `DataStoreIoHelper.luau`)**:
  - `GameConfig.Inventory` define `DataStoreName = "BuildEngineers_PlayerInventory_v1"`, `StorageSchemaVersion = 1`, `StarterKitVersion = 1`, `UnlimitedCapacity = true` y `SellRatioTBD = true`.
  - `GameConfig.Blueprints` actualiza `StorageSchemaVersion = 3` y `DataStoreName = "BuildEngineers_PlayerBlueprints_v3"` manteniendo migración no destructiva desde `LegacyDataStoreName = "BuildEngineers_PlayerBlueprints_v1"`.
  - La persistencia almacena únicamente `ItemId` y metadatos estructurales de unidad (`FamilyId`, `SizeId`, `VariantId`, `RarityId`, `CreatedAt`, `SourceTag`): nunca persiste ni acepta estadísticas físicas, rarezas fabricadas o precios enviados por el cliente.
  - Ante error de carga/guardado de `DataStoreService`, los servicios retornan `PersistenceFailed`, evitan entregar un `StartingInventory` duplicado en reconexiones o fallos transitorios y revierten cambios en memoria mediante rollback seguro.
  - En pruebas automatizadas (`_ResetForTests()`), `_useMemoryStoreForTests = true` aísla los `DataStoreIoHelper` handles sin leer ni ensuciar Cloud; en Studio sin `"Studio access to APIs"` habilitado, utiliza respaldo automático en memoria.
- **Anti-duplicación, venta y desvinculación autoritativa (`InventoryService`, `BuildService`, `VehicleBlueprintService`, `BuildPayloadValidator`)**:
  - El servidor es la única autoridad sobre cantidades, unidades únicas, colocación, validación de blueprints guardados, venta y desvinculación. El cliente recibe resúmenes y vista previa, sin capacidad de forzar éxito ni evadir bloqueo.
  - Para piezas acumulables (`Stackable`), la cantidad bloqueada para venta equivale a `MAX(WorkshopReservedQuantity, referencia máxima en Slots 1..3)`, evitando bloqueos inflados cuando un mismo bloque aparece en varias tarjetas; para `UniqueUnit`, cada `ItemInstanceId` rastrea su presencia exacta en taller y en `BlockedSlotIndices`.
  - Intentar vender por encima de `SellableQuantity` falla con `SellBlockedByReferences` devolviendo `BlockedInWorkshop` y `BlockedSlotIndices`; intentar vender unidades no poseídas o manipular cantidades falla con `UnitNotOwned`, `InvalidQuantity` o `InvalidPayload`.
  - Mientras el jugador tiene un `VehicleRuntime` activo fuera del taller (`IsVehicleInActiveRuntime`), tanto `SellInventoryItem` como `UnlinkInventoryFromBlueprints` quedan bloqueados con `InvalidPlayerState`.
  - `UnlinkInventoryFromBlueprints` exige confirmación explícita (`Confirmed = true`; de lo contrario retorna `ConfirmationRequired` con `UnlinkPreview`), elimina únicamente la pieza/unidad indicada sin borrar los diseños afectados, recalcula conexiones, protege contra concurrencia con locks por `UserId` y valida persistencia antes de responder al cliente.

## Seguridad, Persistencia y Validación — Fase 5.2 (Economía, Pedidos, Stock, Robux y AdService)

- **Persistencia atómica y separación de almacenes (`EconomyPersistenceService`, `OrderPersistenceService`, `DataStoreIoHelper`)**:
  - `ShopConfig.Economy.DataStoreName = "BuildEngineers_PlayerEconomy_v1"` (`StorageSchemaVersion = 1`) almacena `Balance`, `StarterMoneyGranted`, `LastSeenAt`, `PendingOfflineCoins`, `PendingOfflineSeconds`, `PendingOfflineBreakdown` y `ProcessedIds` (ventana acotada a `MaxTrackedProcessedIds = 250` IDs para idempotencia de `ClientOpId`, `PurchaseId` y `TxId`). Guardar los datos offline en el mismo documento económico elimina duplicaciones parciales al reclamar.
  - `ShopConfig.Orders.DataStoreName = "BuildEngineers_PlayerOrders_v1"` (`StorageSchemaVersion = 1`) almacena `ActiveNormalOrder`, `SpecialOrders`, `DeliveryQueue`, `MaxedOneTimeItems` (`DriverSeat`) y `ProcessedOpIds`.
  - Ante error de carga o guardado de `DataStoreService`, ningún servicio entrega saldos o recompensas iniciales falsas: propagan `PersistenceFailed` y revierten cambios en memoria (rollback de monedas/cajas/stock). En pruebas automatizadas (`_useMemoryStoreForTests`), se aísla completamente de Roblox Cloud; en Studio sin acceso a APIs, `DataStoreIoHelper` recurre al respaldo en memoria.
- **Integridad de compras, sorteos y apertura de cajas (`ShopStockService`, `LootBoxService`, `DeliveryService`, `ShopService`)**:
  - `ShopService.ProcessRequest` aplica limitación de frecuencia por jugador con `TokenBucket` y locks de concurrencia por `UserId`, rechaza montos/rarezas/precios enviados por el cliente y valida cantidades/IDs estrictamente contra `ItemCatalog` y `LootBoxConfig`.
  - **Descuento síncrono anti-sobreventa**: `ShopStockService.TryReserveUnit` decrementa el contador en memoria síncronamente antes de cualquier `yield` hacia `DataStoreService`, garantizando que compras simultáneas sobre la última unidad no excedan el stock compartido del servidor. Si falla el débito o el guardado posterior del pedido, el servicio restaura la unidad reservada mediante `ShopStockService.ReleaseUnit(boxId)` y revierte el débito (`EconomyService.Credit`) si el pedido no pudo persistirse.
  - **Idempotencia de apertura y no duplicación**: cada caja almacena su estado (`Queued` / `Spawned` / `Opened`, `CreditedToInventory`) y en cajas especiales persiste `RolledReward` antes de acreditar en `InventoryService` (con `ForcedItemInstanceId` idempotente), evitando que reintentos de red o limpieza de utilerías temporales dupliquen o borren ítems.
- **Seguridad de `ProcessReceipt` y publicidad recompensada (`OfflineIncomeService`, `ShopService`)**:
  - `MarketplaceService.ProcessReceipt` se centraliza en `ShopService.ProcessMarketplaceReceipt`, verificando `EconomyService.HasProcessedReceipt` antes de acelerar pedidos (`Pedir ahora`) o liquidar reclamos `×5` (`ProductPurchaseChannel.AdReward`), devolviendo `NotProcessedYet` si falla la persistencia para preservar reintentos seguros de Roblox y `PurchaseGranted` únicamente tras persistir moneda e idempotencia.
  - La acumulación offline deduplica cada motor estrictamente por `ItemInstanceId` sin contar copias en `WorkshopDraft` ni en los `3` slots, y el cliente nunca puede validar ni multiplicar reclamos por su cuenta sin `AdService` + `ProcessReceipt`.
