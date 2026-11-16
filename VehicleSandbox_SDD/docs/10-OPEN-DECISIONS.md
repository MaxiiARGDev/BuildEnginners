# 10 — Decisiones pendientes (no inventar)

## Mecánica
- ¿Vehículos pueden usar varias ruedas, motores, tanques y propulsores? Límites y fórmula de combinación.
- Significado de `eq` de neumáticos, `tasa de desconexión` de motores y unidades de combustible/impulso.
- Fórmula de velocidad, torque, agarre, combustible, bonos por conducción y ganancias por distancia.
- Combustible inicial y recarga entre intentos (propuesta: reset sin costo).
- Si al regresar se conserva el dinero ganado durante el intento y en qué condiciones.
- Cómo se define fin de intento: botón, muerte del personaje, destrucción de asiento, inmovilización, distancia máxima.
- Grid/snap, tamaño de estación, límites de bloques y colisiones permitidas.
- Cómo afectan al vehículo piezas conectadas por múltiples caminos.

## Economía
- Frecuencia del restock de tienda y catálogo exacto de objetos con stock limitado.
- Moneda o Robux para entrega exprés, precio y cumplimiento de compra.
- Política de pedidos al desconectarse o cambiar de servidor.
- Probabilidades exactas por caja, por tamaño y rareza; bonus final por rareza.
- Si se compra la caja o el motor y en qué momento se abre.

## Multijugador y mapa
- Si vehículos pueden interactuar o colisionar entre sí.
- Permisos de colaboración en base ajena (no confirmados).
- Reglas de spawn, obstáculos y streaming del mapa.
- Si misión global recompensa al primer jugador del universo o a varios.

## Técnica
- Herramienta de perfiles, librerías externas permitidas, convención de Rojo, compatibilidad móvil, guardado automático, límite de DataStore y políticas de migración.

Registrar cada decisión nueva con fecha y efecto en contratos antes de programarla.

## Registro de implementaciones con parámetros `Provisional_TBD`
- **2026-11-14 (Fase 3.4 — Propulsores Modulares y Nitro)**: se implementaron `BoosterCatalog.luau`, `BoosterInventoryService.luau` y `VehicleBoosterService.luau` preservando intactas las cifras confirmadas del SDD para `SmallBooster` y `SmallNitroTank`. Permanecen etiquetados explícitamente como `BalanceStatus = "Provisional_TBD"` para calibración posterior en Fases 3.5 / 5:
  - Perfiles `Medium` / `Large`, familias `HighImpulse` / `ExtendedBurn`, variantes (`HighThrust`, `EcoBurn`, `Lightweight`, `Overboost`) y multiplicadores de rareza (`Uncommon` a `Mythic`).
  - Constantes de simulación física y envolvente de velocidad en `GameConfig.Boosters` (`NitroConsumptionTimeBaseSeconds = 1.0`, `BaseEnvelopeSpeedStudsPerSec = 42.0`, `SpeedMultiplierRangeScale = 38.0`, `HighSpeedTaperFloor = 0.12`).
  - Precios individuales en tienda de `SmallBooster`, `SmallNitroTank`, `SmallEngine`, `MediumEngine` y tasas/probabilidades de cajas.
- **2026-11-14 (Fase 4.1 — Sistema de Daño Estructural y Durabilidad por Pieza)**: se implementaron `DamageConfig.luau`, `DamageMath.luau`, `VehicleDamageService.luau` y `VehicleImpactService.luau`, manteniendo explícitamente `BalanceStatus = "Provisional_TBD"` en:
  - Umbrales cinemáticos y curva de daño en `DamageConfig.Impact` (`MinImpactSpeedStudsPerSec = 14.0`, `MinNormalSpeedStudsPerSec = 12.0`, `DamageThresholdSpeedStudsPerSec = 14.0`, `MinDamageThreshold = 1.5`, `NormalSpeedWeight = 1.0`, `TangentialSpeedWeight = 0.12`, `HighSpeedScrapeOverrideSpeed = 48.0`, `ReferenceMass = 50.0`, `MassExponent = 0.35`, `MinMassFactor = 0.55`, `MaxMassFactor = 3.00`, `DamageScale = 0.16`, `DamageExponent = 1.35`, `MaxSingleImpactRawDamage = 2500.0`, `LaunchSettlingGraceSeconds = 0.25`, `GraceOverrideNormalSpeed = 24.0`, `MaxTrackedRelativeSpeedStudsPerSec = 350.0`, `MaxContactRayDistanceStuds = 6.0`).
  - Ventanas de deduplicación y parámetros de propagación `1-hop` en `DamageConfig.Deduplication` (`PieceOtherPairCooldownSeconds = 0.28`, `VehicleOtherBurstWindowSeconds = 0.12`, `MaxProcessedHitsPerBurst = 8`, `VehiclePairCooldownSeconds = 0.20`, `StaleEntryPruneSeconds = 10.0`) y `DamageConfig.Distribution` (`PrimaryDirectShareWithNeighbors = 0.85`, `MaxAdjacentTransferShare = 0.15`, `MaxAdjacentNeighbors = 6`, `AdjacentDistanceAttenuation = 0.25`, `MaxAdjacentDistanceStuds = 10.0`, `MinDistributedPieceDamage = 0.40`, `MaxPropagationHops = 1`).
  - Perfiles por categoría en `DamageConfig.CategoryProfiles` (`Structures`, `Wheels`, `Engines`, `FuelTanks`, `Boosters`, `Seats`, `Utilities`, `Decorations`, `Other`: `DefaultMaxHealth`, `DefaultDurability`, `ImpactResistance` y `DamageMultiplier`) hasta calibración final de balance y degradación visual/funcional en Fase 4.3.

## Decisiones aprobadas en Fase 4.2 (`2026-11-15`)
- **Tiempo de vida y límites de escombros (`DestructionConfig.luau` + `GameConfig.luau`)**: `DebrisLifetimeSeconds = 20`, `MaxPiecesPerVehicle = 500`, `MaxDebrisPiecesPerRuntime = 500` escombros por vehículo, `MaxDebrisPiecesServer = 1500` piezas/escombros en servidor con expulsión FIFO y grupo de colisión `VehicleDebris`.
- **Controles de conducción y asiento**: eliminado definitivamente el freno de mano (`Handbrake`) en todo el juego; bloqueado `Space` / salto mientras se ocupa un asiento vehicular (`VehicleSeatController` + guardia en servidor `VehicleSeatService`), manteniendo el botón existente `"Salir del asiento"` (`ExitVehicleSeat`) como única salida voluntaria.

## Decisiones confirmadas y registros `PROVISIONAL_TBD` — Fase 5.2 (`2026-11-16`)
- **Decisiones confirmadas por el desarrollador**:
  - `ShopConfig.Economy`: saldo inicial `StartingMoney = 1000` monedas entregado una sola vez; `DriverSeat = 100` (compra e inventario ilimitados, conservando la restricción de `1` por vehículo en taller/blueprint), `SmallNitroTank = 250`, resto de piezas normales sin cambio; venta de piezas normales al `50%` redondeado hacia abajo (`NormalSellRatio = 0.50`); motores/propulsores únicos sin venta monetaria hasta definir precio individual; `SmallEngine` y `SmallBooster` no se venden directamente (`DirectPurchasable = false`).
  - `LootBoxConfig.luau`: cajas activas `BasicEngineCrate = 80` y `BasicBoosterCrate = 45000`; `RoadEngineCrate` deshabilitada (`Enabled = false`) hasta definir precio, recompensas y modelo.
  - `ShopConfig.Orders` & `DeliveryZone`: pedidos normales cada `60 s` (desbloqueo al llegar `Status = "Arrived"`), cajas especiales cada `900 s`, restock compartido por instancia de servidor cada `300 s` con reemplazo absoluto `1..3` (sin sumar entre renovaciones ni sincronizar entre servidores), `VisualCapacity = 6` compartida con cola FIFO persistente y aceleración Robux `"Pedir ahora"` a `~5 s`.
- **Parámetros explícitamente marcados como `BalanceStatus = "PROVISIONAL_TBD"`** (pendientes de ajuste posterior sin alterar contratos):
  - Pesos de cajas en `LootBoxConfig.luau`: rarezas `Common = 55`, `Uncommon = 25`, `Rare = 12`, `Epic = 5`, `Legendary = 2.5`, `Mythic = 0.5`; tamaños `Small = 70`, `Medium = 25`, `Large = 5`.
  - Tasas de ingresos offline de motores en `ShopConfig.OfflineIncome`: `HourlyRatesBySize` (`Small = 21.88`, `Medium = 87.50`, `Large = 175.00` monedas/hora), `RarityMultipliers` (`Common = 1.00`, `Uncommon = 1.25`, `Rare = 1.60`, `Epic = 2.15`, `Legendary = 3.00`, `Mythic = 4.50`), `MinOfflineSeconds = 10`, `MaxAccumulationSeconds = 86400` y `RewardedAdMultiplier = 5`.
- **Placeholders pendientes de Creator Hub**: `RushNormalOrderProductId = 0`, `RushSpecialOrderProductId = 0` y `RewardedAdDevProductId = 0` en `ShopConfig.luau` (`RewardedAdPlacementId = nil`).

## Decisiones aplicadas y balance provisional — Fase 5.3 (Aerodinámica Modular)
- **Valores provisionales centralizados (`AerodynamicsConfig.luau`, `BalanceStatus = "Provisional_TBD"`)**:
  - Constantes globales (`AirDensity = 0.045`, `DynamicPressureScale = 1.0`, `MinAirspeedStudsPerSec = 1.5`, `MaxEffectiveAirspeedStudsPerSec = 420.0`, `MaxForcePerSurface = 45000.0`, `MaxTotalAerodynamicForce = 180000.0`).
  - Precios (`130`–`260` monedas), masas (`3.5`–`6.5`), salud (`75`–`105 HP`), áreas alares (`10.0`–`38.0`), coeficientes ($C_{L,\alpha}$, $C_{L,\max}$, $C_{D,0}$, $k$, `StallAngleDeg`, `PostStallLiftRetention`, `PostStallDragCoefficient`) y amortiguación de `AircraftTail` están marcados `Provisional_TBD` para ajuste de balance sin tocar la lógica física.
- **Reservado para etapas posteriores**:
  - Superficies de control activas (`Aileron`, `Elevator`, `Rudder`) conectadas a entradas de teclado/mando del jugador (`AerodynamicsService.SetControlInputs` y `ControlAuthorityDeg` ya preparados).
  - Motores de avión / hélices y `BasicAircraftEngineCrate`.
