# 06 — Economía, cajas, stock y entregas

## Economía
Moneda: dinero. Recompensas por distancia y misiones; bonificaciones de motores/propulsores según configuración. Fórmula exacta de ganancias, límites y tasas: TBD.

## Tienda
Categorías: piezas, motores, propulsores, combustibles, decoraciones y otros. Los objetos limitados sujetos a stock se compran con entrega diferida.

## Stock por servidor
- Cupos compartidos por los 10 jugadores del mismo servidor.
- Ejemplo: stock 2, compra de una unidad deja 1 para todos.
- Reabastecimiento con cantidad aleatoria entre 1 y 3 unidades en cada renovación.
- **Pendiente**: frecuencia de renovación de stock; no asumir que coincide con el camión de 15 minutos.
- Compra atómica en servidor, evitando doble venta concurrente.

## Entrega
- Camión llega cada 15 minutos y entrega pedidos pendientes en estaciones.
- Comprar registra pedido; no agrega inmediatamente al inventario.
- Posibilidad de adelantar entrega pagando (moneda o Robux TBD).
- Pedidos persistentes y reclamables tras desconexión; definir política si el servidor cierra.
- Evitar duplicaciones por reconexión, entrega repetida o fallo de guardado.

## Cajas de motores
- `BasicEngineCrate`: precio 80; contiene motores de tamaños pequeño, mediano y grande, con probabilidades configurables.
- Otras cajas como `RoadEngineCrate`: pendientes.
- `BasicBoosterCrate`: precio 45,000; propulsores pequeños, medianos y grandes, probabilidades configurables.
- Dos dimensiones de sorteo: variante/tamaño y rareza; la distribución puede variar por caja.
- Rarezas: Común, No común, Raro, Épico, Legendario, Mítico.
- Cada rareza aumenta bonificación económica; valores y tablas autoritativas por caja.
- Capturas de referencia muestran para algunos motores bonificaciones como +0.0029x, +0.0034x, +0.0041x, +0.0051x, +0.0065x y porcentajes parciales. **No tomar capturas parciales como una tabla completa ni inventar porcentajes faltantes**.
- Resolver resultado y descontar caja en servidor; inventario recibe instancia única con tipo, rareza y estadísticas derivadas verificables.

## Integridad
- Transacciones con ID único e idempotencia.
- No aceptar precio, cantidad, rareza ni resultado de caja desde cliente.
- Guardar pedidos y entrega en un estado coherente ante fallos.

## Preparación de Inventario de Motores y Unidades Únicas (Fase 3.3)
- **`EngineInventoryService` (fuente controlada en servidor)**:
  - Cada motor con variante/rareza se registra en servidor con un `ItemInstanceId` único (`OwnerUserId`, `ItemId`, `EngineFamilyId`, `EngineSizeId`, `VariantId`, `RarityId`, `EffectiveStats`, `AssignedBlueprintId`, `AssignedPieceInstanceId`).
  - Los precios de cajas no confirmados (`RoadEngineCrate`, precios individuales de motores y probabilidades de sorteo) permanecen estrictamente como `TBD` sin inventar economía ni abrir cajas todavía.
  - En modo desarrollo/pruebas (`GrantStarterTestKit = true`), el servidor otorga un kit controlado de unidades que cubre los 3 tamaños (`Small`, `Medium`, `Large`), las 6 rarezas (`Common` a `Mythic`) y las 5 variantes (`Standard`, `HighTorque`, `HighSpeed`, `Efficient`, `HeavyDuty`) para permitir probar todas las combinaciones sin alterar la futura tienda/cajas de Fase 5.
  - **Anti-duplicación estricta**: una unidad `ItemInstanceId` solo puede asignarse a una pieza de motor a la vez; al duplicar un blueprint (`DuplicateBlueprint`), si existen unidades equivalentes libres en el inventario del propietario se vinculan automáticamente y, si no, la copia cae limpiamente al perfil base sin clonar la misma unidad física.

## Implementación autoritativa — Fase 5.2 (Economía, Carrito, Stock Compartido, Pedidos, Cajas e Ingresos Offline)

### 1. Economía autoritativa (`ShopConfig.Economy`, `EconomyService`)
- **Saldo inicial único**: `StartingMoney = 1000` monedas entregado una sola vez por jugador (`StarterMoneyGranted = true`); nunca se repite al reconectar ni ante errores transitorios de `DataStoreService`.
- **Precios confirmados**: `DriverSeat = 100` (el límite de `1` `DriverSeat` aplica únicamente por vehículo en construcción/blueprint y no impide comprar ni almacenar múltiples unidades en inventario), `SmallNitroTank = 250`, manteniendo `WoodBlock = 10`, `WoodBeam = 8`, `SmallWheel = 25`, `RegularFuelTank = 175`. `SmallEngine` y `SmallBooster` tienen `DirectPurchasable = false` y se obtienen mediante cajas especiales.
- **Venta al `50%`**: al vender piezas normales en `InventoryService.SellInventoryItem`, `EconomyService` acredita `math.floor(Price * 0.50)` monedas tras superar el bloqueo de referencias `MAX(Taller, Slots 1..3)`. Las unidades únicas sin precio individual configurado (`SmallEngine`, `SmallBooster`) bloquean la venta monetaria (`CanSellForMoney = false`) hasta definir su valoración individual.

### 2. Carrito, dos colas independientes y entregas en `DeliveryZone` (`DeliveryService`)
- **Acceso físico y UI**: `ShopCounter` en `ShopZone` con `OpenShopPrompt` (`ActionText = "Abrir Tienda"`, `MaxActivationDistance = 12`) abre `ShopPanel`, manteniendo acceso consistente con el HUD sin solapamientos (`EconomyHudDock` en `X = 216`).
- **Pedidos normales (`NormalOrderWaitSeconds = 60`)**: el carrito permite explorar por categoría (`Bloques`, `Ruedas`, `Asientos`, `Tanques`), sumar líneas e incrementar el costo total antes de confirmar. Cada línea única de `ItemId` genera `1` `NormalDeliveryCrate` con su cantidad total. No se permite un segundo pedido normal mientras el anterior siga en tránsito (`NormalOrderInProgress`), desbloqueándose automáticamente cuando vence `ArriveAt` (`Status = "Arrived"`), incluso si quedan cajas sin abrir o si `DeliveryZone` está llena.
- **Pedidos especiales (`SpecialOrderWaitSeconds = 900` = 15 min)**: independientes del bloqueo normal (`BasicEngineCrate` y `BasicBoosterCrate`).
- **`DeliveryZone` compartida y persistente**: capacidad visual inicial simultánea `VisualCapacity = 6` (`3×2` pads) compartida equitativamente con una cola persistente FIFO cuando coexisten cajas normales y especiales pendientes de mostrarse; al abrir una caja, avanza inmediatamente la siguiente en cola. Todos los tiempos se calculan con timestamps absolutos persistentes (`ArriveAt`), conservando su progreso al desconectar y reponiendo cajas/animación al volver a asignar parcela.
- **Camión visual seguro (`DeliveryTruck`)**: opera fuera de `BuildZone` bajo el grupo de colisión `DeliveryProps`, sin `Seat` ni `VehicleSeat`, y no impide ni cancela jamás la entrega autoritativa si falla el apartado visual.
- **Apertura idempotente de cajas (`LootBoxService` + `DeliveryService`)**: al interactuar con `OpenCratePrompt`, las cajas especiales sortean y persisten `RolledReward` una sola vez en `OrderPersistenceService`, acreditan la unidad en `InventoryService` antes de revelar visualmente el modelo con `BillboardGui` (`nombre + rareza`) durante `CrateRevealLifetimeSeconds = 7.5` s y nunca eliminan la unidad del inventario al limpiar el objeto temporal.

### 3. Cajas especiales y stock compartido por servidor (`LootBoxConfig`, `ShopStockService`)
- **Cajas activas iniciales**: `BasicEngineCrate` (`80` monedas) y `BasicBoosterCrate` (`45,000` monedas). `RoadEngineCrate` permanece con `Enabled = false` hasta definir precio, recompensas y modelo.
- **Stock compartido por instancia de servidor**: `ShopStockService` sortea al arrancar `1..3` unidades enteras por cada caja habilitada; cada compra exitosa descuenta de forma síncrona antes de cualquier escritura asíncrona en DataStore para evitar sobreventas sobre la última unidad.
- **Reemplazo cada `300 s`**: cada `RestockIntervalSeconds = 300`, el servidor reemplaza el stock anterior por un nuevo sorteo `1..3` (nunca acumula/suma), sin sincronizar stock entre servidores distintos.
- **Probabilidades (`BalanceStatus = "PROVISIONAL_TBD"`)**: rarezas `Common = 55%`, `Uncommon = 25%`, `Rare = 12%`, `Epic = 5%`, `Legendary = 2.5%`, `Mythic = 0.5%`; tamaños `Small = 70%`, `Medium = 25%`, `Large = 5%`; familia y variante uniformes dentro de las entradas válidas de `EngineCatalog` / `BoosterCatalog` pre-validadas por `LootBoxConfig.ValidateBoxPool`.

### 4. Aceleración Robux e ingresos offline de motores (`OfflineIncomeService`, `ShopService`)
- **Aceleración `"Pedir ahora"`**: conectada a `MarketplaceService.ProcessReceipt` (`RushNormalOrderProductId = 0`, `RushSpecialOrderProductId = 0` hasta cargar IDs reales en Creator Hub) con reducción a `ArriveAt <= now + 5 s` (`RobuxSpeedupArrivalSeconds = 5`) e idempotencia por `PurchaseId`.
- **Ingresos pasivos offline (`PROVISIONAL_TBD`)**: acumulan monedas únicamente por motores únicos poseídos en `InventoryService` (deduplicados por `ItemInstanceId` entre taller y slots `1..3`), con tasas configurables `Small = 21.88/h`, `Medium = 87.50/h`, `Large = 175.00/h` multiplicadas por rareza (`1.00×` a `4.50×`), ignorando desconexiones `< 10 s` y con tope de `86,400 s`.
- **Reclamo normal (`×1`) y publicidad recompensada (`×5`)**: `OfflineIncomeModal` permite `Recoger` normal (`×1`) o `Recoger ×5` mediante la API oficial de Roblox `AdService` (`GetAdAvailabilityNowAsync` en cliente + `ShowRewardedVideoAdAsync` + `ProcessReceipt` con `Enum.ProductPurchaseChannel.AdReward` cuando `RewardedAdDevProductId > 0`); si no hay anuncio disponible o configurado, la opción `×5` permanece deshabilitada sin bloquear el reclamo normal.
