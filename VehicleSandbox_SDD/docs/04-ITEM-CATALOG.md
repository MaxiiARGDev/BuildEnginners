# 04 — Catálogo y estadísticas

## Categorías
- `Structures`: peso, durabilidad, precio.
- `Wheels`: equipación (`eq`, significado exacto TBD), agarre, peso, durabilidad, precio.
- `FuelTanks`: subtipo combustible normal o nitro; capacidad, tipo, peso, durabilidad, precio.
- `Utilities`: peso, durabilidad, restricciones de compra.
- `Engines`: velocidad, par, bonificación por conducción, tasa de desconexión (semántica TBD), combustible, consumo, peso, durabilidad, impulso/aumento de velocidad cuando aplique, precio.
- `Boosters`: bonificación por conducción, combustible cohete, combustible integrado, consumo, impulso, aumento de velocidad, peso, durabilidad.
- `Decorations`, `Other`: previstas, definición pendiente.
- `Seats`: categoría reconocida en `ItemRegistry` (`DriverSeat` con rol `DriverSeat` y límite de `1` por ensamblaje primario en lanzamiento; los demás ítems de categoría `Seats` reciben rol `PassengerSeat` en `VehicleAssemblyService`).

### Extensión de `Stats` y perfiles por categoría para Daño Estructural (Fase 4.1)
- Campos opcionales por definición en `ItemStats` (`ItemTypes.luau`, validados por `ItemRegistry.luau`):
  - `ImpactResistance: number?`: `nil` o número finito `> 0`.
  - `DamageMultiplier: number?`: `nil` o número finito `>= 0`.
- Cuando no están definidos en el ítem, `VehicleDamageService` / `DamageConfig.GetCategoryProfile(category)` usan los perfiles por categoría marcados `BalanceStatus = "Provisional_TBD"`:
  - `Structures`: `DefaultMaxHealth/DefaultDurability = 75`, `ImpactResistance = 1.00`, `DamageMultiplier = 1.00`
  - `Wheels`: `DefaultMaxHealth/DefaultDurability = 32`, `ImpactResistance = 1.15`, `DamageMultiplier = 0.90`
  - `Engines`: `DefaultMaxHealth/DefaultDurability = 110`, `ImpactResistance = 0.85`, `DamageMultiplier = 1.15`
  - `FuelTanks`: `DefaultMaxHealth/DefaultDurability = 100`, `ImpactResistance = 0.80`, `DamageMultiplier = 1.20`
  - `Boosters`: `DefaultMaxHealth/DefaultDurability = 130`, `ImpactResistance = 0.90`, `DamageMultiplier = 1.10`
  - `Seats`: `DefaultMaxHealth/DefaultDurability = 300`, `ImpactResistance = 1.25`, `DamageMultiplier = 0.80`
  - `Utilities`: `DefaultMaxHealth/DefaultDurability = 300`, `ImpactResistance = 1.25`, `DamageMultiplier = 0.80`
  - `Decorations`: `DefaultMaxHealth/DefaultDurability = 40`, `ImpactResistance = 0.65`, `DamageMultiplier = 1.25`
  - `Other` (fallback): `DefaultMaxHealth/DefaultDurability = 75`, `ImpactResistance = 1.00`, `DamageMultiplier = 1.00`

## Valores proporcionados por el diseñador
| ItemId sugerido | Categoría | Datos |
|---|---|---|
| WoodBeam | Structures | peso 1.8, durabilidad 70, precio 8 |
| WoodBlock | Structures | peso 5, durabilidad 75, precio 10 |
| SmallWheel | Wheels | peso 4, durabilidad 32, precio 25, eq 0.6, agarre 1.1 |
| RegularFuelTank | FuelTanks | tipo elegible Regular/Diesel/Competición al colocar; capacidad 1.5, peso 8, durabilidad 100, precio 175 |
| SmallNitroTank | FuelTanks | tipo RocketFuel, capacidad 28,800, peso 12, durabilidad 100, precio TBD |
| DriverSeat | Seats (`Utilities` en SDD inicial) | peso 8, durabilidad 300, máximo 1 compra por jugador; precio TBD |
| PassengerSeat | Utilities | peso 8, durabilidad 300, precio TBD |
| SmallEngine | Engines | velocidad 36 bloques/s con regular; torque 1400; bonificación +0.0025x; tasa de desconexión 21.88 monedas/hora; combustible normal; integrado 0.54; consumo máximo regular 0.18; peso 8; durabilidad 110; precio individual TBD |
| MediumEngine | Engines | velocidad 50 bloques/s con regular; torque 4200; bonificación +0.015x; tasa de desconexión 87.5 monedas/hora; combustible normal; integrado 0.9; consumo máximo regular 0.3; peso 14; durabilidad 150; precio individual TBD |
| SmallBooster | Boosters | bonificación +0.3x; RocketFuel; integrado 24,000; consumo en potenciación 12,000; impulso 12,000; aumento velocidad 1x; peso 12; durabilidad 130; precio individual TBD |

Los números se preservan como fueron especificados; las unidades y fórmulas de varios campos todavía requieren definición.

## Contrato de definición (ilustrativo)
```lua
return {
  Id = "WoodBeam",
  Category = "Structures",
  Model = "WoodBeam",
  Stats = { Weight = 1.8, MaxDurability = 70 },
  Price = 8,
  Behavior = nil,
}
```

## Regla de extensibilidad
Agregar modelo, definición, attachments/puntos de unión y opcionalmente módulo de comportamiento. El registro detecta conflictos de ID, atributos ausentes, modelos faltantes y estadísticas inválidas al iniciar. No modificar el servicio de construcción por cada pieza nueva.

### Contrato físico para categoría `Wheels` (Fase 3.2)
- Las ruedas conservan `Conn_*` (`Conn_Axle`, `Conn_AxleRight`) para colocación/snap y pueden declarar `WheelHub` (en `[0,0,0]`) más atributos en el modelo (`WheelRadius`, `WheelWidth`, `LocalSpinAxis`, `LocalSuspensionAxis`).
- Si no se declaran atributos, `WheelAutoConfigurationService` inspecciona automáticamente el cilindro/`PrimaryPart` en `ServerStorage.ItemAssets`.
- Para `SmallWheel`: cilindro real `[1, 2, 2]` (`WheelRadius = 1.0`, `WheelWidth = 1.0`, `LocalSpinAxis = "X"`, `LocalSuspensionAxis = "Y"`). El campo de diseño `eq = 0.6` permanece almacenado sin inventar fórmula (`TBD`).

### Sistema de Motores: Tamaños, Variantes y Rarezas (`EngineCatalog`, Fase 3.3)
- **Separación estricta entre valores confirmados del SDD y calibración provisional (`Provisional_TBD`)**:
  - **Confirmados en SDD (`BalanceSource = "SDD_Confirmed"`)**:
    - `SmallEngine` (`SizeId = "Small"`): `MaxSpeed = 36` bloques/s (con Regular), `Torque = 1400`, `DrivingBonus = +0.0025`, `DisconnectRate = 21.88` monedas/hora, `FuelType = "Normal"`, `IntegratedFuel = 0.54`, `MaxRegularConsumption = 0.18`, `Weight = 8`, `MaxDurability = 110`.
    - `MediumEngine` (`SizeId = "Medium"`): `MaxSpeed = 50` bloques/s (con Regular), `Torque = 4200`, `DrivingBonus = +0.015`, `DisconnectRate = 87.5` monedas/hora, `FuelType = "Normal"`, `IntegratedFuel = 0.90`, `MaxRegularConsumption = 0.30`, `Weight = 14`, `MaxDurability = 150`.
    - `RegularFuelTank`: `FuelCapacity = 1.5`, subtipos seleccionables `Regular`, `Diesel`, `Competicion`, `Weight = 8`, `MaxDurability = 100`, `Price = 175`.
    - Bonificaciones económicas observadas en capturas parciales de `SmallEngine` por rareza: `+0.0029x` (`Uncommon`), `+0.0034x` (`Rare`), `+0.0041x` (`Epic`), `+0.0051x` (`Legendary`), `+0.0065x` (`Mythic`).
  - **Provisionales de ingeniería (`BalanceSource = "Provisional_TBD"`, sujetos a ajuste de diseño)**:
    - Perfil base `Large`: `MaxSpeed = 62`, `Torque = 8400`, `Weight = 24`, `MaxDurability = 210`, `IntegratedFuel = 1.40`, `MaxRegularConsumption = 0.48`.
    - Multiplicadores por variante (`Standard`, `HighTorque`, `HighSpeed`, `Efficient`, `HeavyDuty`) y escalado mecánico por rareza (`Common` `1.00x` a `Mythic` `1.48x` en torque y `1.22x` en velocidad punta).
- **Reutilización del modelo 3D base**: todas las variantes y rarezas de una familia comparten el modelo físico de `ServerStorage.ItemAssets.Motores` y diferencian su identidad mediante atributos en el `Model`, acento visual de color/material en `EngineBehavior` y ficha técnica en `EngineInspectorPanel`.

### Sistema de Propulsores Modulares y Nitro (`BoosterCatalog` + `SmallNitroTank`, Fase 3.4)
- **Separación estricta entre valores confirmados del SDD y calibración provisional (`BalanceStatus = "Provisional_TBD"`)**:
  - **Confirmados en SDD (`SDD_Confirmed`)**:
    - `SmallBooster` (`BoosterSizeId = "Small"`, `BoosterFamilyId = "StandardRocket"`, `VariantId = "Balanced"`, `RarityId = "Common"`): `Thrust = 12000`, `IntegratedFuel = 24000`, `BoostConsumption = 12000`, `SpeedBoostMultiplier = 1` (`1x`), `DrivingBonus = +0.3`, `FuelType = "RocketFuel"`, `Weight = 12`, `MaxDurability = 130`, `Price = nil` (TBD).
    - `SmallNitroTank`: `Category = "FuelTanks"`, `FuelSubtype = "Nitro"`, `FuelType = "RocketFuel"`, `Capacity = 28800`, `Weight = 12`, `MaxDurability = 100`, `Price = nil` (TBD).
  - **Provisionales de ingeniería (`Provisional_TBD`, sujetos a balance final en Fase 3.5 / 5)**:
    - Tamaños adicionales compartiendo el modelo base: `Medium` (`Thrust = 24000`, `IntegratedFuel = 48000`, `BoostConsumption = 21600`, `Weight = 22`, `MaxDurability = 190`, `VisualScaleMultiplier = 1.15`) y `Large` (`Thrust = 42000`, `IntegratedFuel = 84000`, `BoostConsumption = 34000`, `Weight = 36`, `MaxDurability = 280`, `VisualScaleMultiplier = 1.30`).
    - Familias `HighImpulse` (`ThrustMultiplier = 1.18`, encendido rápido) y `ExtendedBurn` (`ConsumptionMultiplier = 0.78`, `IntegratedFuelMultiplier = 1.25`).
    - 5 variantes (`Balanced`, `HighThrust`, `EcoBurn`, `Lightweight`, `Overboost`) y 6 rarezas (`Common` a `Mythic`, con `Mythic` alcanzando `ThrustBonusRatio = +0.48`, `SpeedBoostBonus = +0.50`, `IntegratedFuelBonusRatio = +0.42`, `WeightDeltaRatio = -0.14`, `DurabilityBonusRatio = +0.50`).
- **Reutilización del modelo 3D y VFX reactivos**: todas las configuraciones de propulsor reutilizan `ServerStorage.ItemAssets.Propulsores.SmallBooster`; `BoosterBehavior` adjunta `NozzleAttachment` en `(0, 0, +1.5)` con `FlameEmitter`, `SmokeEmitter`, `NozzleLight` y `ThrustSound` gobernados únicamente por atributos del runtime.

### Catálogo unificado en español, carpetas físicas e inventario inicial (Fase 5.1)

| ItemId | DisplayName | Category | CategoryDisplayName | Carpeta física (`ItemAssets` / `PreviewAssets`) | Tipo de inventario (`InventoryKind`) | `StartingInventory` | Precio (`Price` / `SellPrice`) |
|---|---|---|---|---|---|---|---|
| `WoodBlock` | `Bloque de madera` | `Structures` | `Bloques` | `Bloques/WoodBlock` | `Stackable` | `20` | `10` / `nil` (TBD) |
| `WoodBeam` | `Viga de madera` | `Structures` | `Bloques` | `Bloques/WoodBeam` | `Stackable` | `10` | `8` / `nil` (TBD) |
| `SmallWheel` | `Rueda pequeña` | `Wheels` | `Ruedas` | `Ruedas/SmallWheel` | `Stackable` | `4` | `25` / `nil` (TBD) |
| `DriverSeat` | `Asiento del conductor` | `Seats` | `Asientos` | `Asientos/DriverSeat` | `Stackable` | `1` | `nil` (TBD) |
| `SmallEngine` | `Motor pequeño` | `Engines` | `Motores` | `Motores/SmallEngine` | `UniqueUnit` | `1` (`Small·Balanced·StandardCombustion·Common`) | `nil` (TBD) |
| `RegularFuelTank` | `Tanque de combustible` | `FuelTanks` | `Tanques` | `Tanques/RegularFuelTank` | `Stackable` | `1` | `175` / `nil` (TBD) |
| `SmallNitroTank` | `Tanque de nitro` | `FuelTanks` | `Tanques` | `Tanques/SmallNitroTank` | `Stackable` | `1` | `nil` (TBD) |
| `SmallBooster` | `Propulsor pequeño` | `Boosters` | `Propulsores` | `Propulsores/SmallBooster` | `UniqueUnit` | `1` (`Small·Balanced·StandardRocket·Common`) | `nil` (TBD) |

- Los valores marcados como `TBD` (`Price` en ítems no cotizados y `SellPrice` en todo el catálogo) permanecen en `nil` hasta la Fase 5.2 de economía y tienda.

### Precios confirmados, reglas de compra directa y venta (Fase 5.2)

- `ItemCatalog.luau` expone `DirectPurchasable`, `CanSellForMoney` (`SellPrice`), `GetPurchasableShopItems()` y `GetSellPrice(itemId)` (`math.floor(Price * 0.50)` para ítems normales), sin propagar límites de inventario/compra a la tienda (`MaxOwnedPerPlayer = nil`):

| ItemId / Caja | Compra directa (`DirectPurchasable`) | Precio compra (`Price`) | Precio venta (`SellPrice`) | Regla especial |
|---|---|---|---|---|
| `WoodBlock` (`Bloque de madera`) | Sí | `10` | `5` (`50%`) | Pedido normal (`60 s`) |
| `WoodBeam` (`Viga de madera`) | Sí | `8` | `4` (`50%`) | Pedido normal (`60 s`) |
| `SmallWheel` (`Rueda pequeña`) | Sí | `25` | `12` (`50%`) | Pedido normal (`60 s`) |
| `DriverSeat` (`Asiento del conductor`) | Sí | `100` | `50` (`50%`) | Compra/inventario ilimitados; límite de `1` por vehículo en construcción (`TooManyDriverSeats`) |
| `RegularFuelTank` (`Tanque de combustible`) | Sí | `175` | `87` (`50%`) | Pedido normal (`60 s`) |
| `SmallNitroTank` (`Tanque de nitro`) | Sí | `250` | `125` (`50%`) | Pedido normal (`60 s`) |
| `SmallEngine` (`Motor pequeño`) | No (`false`) | `nil` | `nil` (`CanSellForMoney = false`) | Se obtiene vía cajas especiales (`BasicEngineCrate`); venta monetaria bloqueada |
| `SmallBooster` (`Propulsor pequeño`) | No (`false`) | `nil` | `nil` (`CanSellForMoney = false`) | Se obtiene vía cajas especiales (`BasicBoosterCrate`); venta monetaria bloqueada |
| `BasicEngineCrate` (`Caja Básica de Motores`) | Caja especial | `80` | No vendible | Pedido especial (`900 s`), stock compartido servidor `1..3` |
| `BasicBoosterCrate` (`Caja Básica de Propulsores`) | Caja especial | `45,000` | No vendible | Pedido especial (`900 s`), stock compartido servidor `1..3` |
| `RoadEngineCrate` (`Caja de Motores de Carretera`) | Deshabilitada (`Enabled = false`) | `nil` | — | Oculta/deshabilitada hasta definir precio, tabla de recompensas y modelo |

### 4.4 Piezas Aerodinámicas Modulares (Fase 5.3 — `Category = "Aerodynamics"`, carpeta `Aerodinamica`, categoría visible `"Aerodinámica"`)

Todos los valores numéricos iniciales de precio, peso, salud (`MaxDurability`) y coeficientes aerodinámicos están centralizados en `ReplicatedStorage/Shared/Config/AerodynamicsConfig.luau` con `BalanceStatus = "Provisional_TBD"`:

| `ItemId` | Nombre en español | Subtipo (`SurfaceType` / `Side`) | Precio compra (`Price`) | Precio venta (`50%`) | Peso (`Weight`) | Salud (`MaxDurability`) | `WingArea` / `StallAngleDeg` |
|---|---|---|---|---|---|---|---|
| `AircraftWingLeft` | `Ala izquierda` | `Wing` (`Left`) | `140` | `70` | `4.5` | `85` | `16.0` / `18°` |
| `AircraftWingRight` | `Ala derecha` | `Wing` (`Right`) | `140` | `70` | `4.5` | `85` | `16.0` / `18°` |
| `AircraftWing` | `Ala de avión universal` | `UniversalWing` (`Universal`) | `160` | `80` | `5.0` | `95` | `18.0` / `19°` |
| `AircraftTail` | `Cola de avión` | `TailStabilizer` (`Center`) | `150` | `75` | `4.0` | `80` | `10.0` (horiz.) + `8.5` (vert.) / `16°` |
| `LargeGliderWing` | `Ala de planeador grande` | `GliderWing` (`Center`) | `260` | `130` | `6.5` | `105` | `38.0` / `15°` |
| `SmallGliderWing` | `Ala de planeador pequeña` | `GliderWing` (`Center`) | `130` | `65` | `3.5` | `75` | `19.0` / `16°` |

- Todas las piezas aerodinámicas son apilables (`IsUnique = false`), comprables en la tienda normal sin límite artificial de stock, con pedido de `60 s` que entrega una sola caja física por `ItemId` en `DeliveryZone` y compatibles con los 3 slots de blueprints, `SmartSnap`, `Grid`, `Free`, `FaceSnap` y pasos de rotación (`90°`, `45°`, `15°`, `1°`).
