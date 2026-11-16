# Guía para agregar nuevos objetos al catálogo

Esta guía describe el flujo estándar de la Fase 1 para incorporar una pieza nueva sin modificar `ItemRegistry`, `PlotService` ni futuros servicios de construcción.

## 1. Crear la definición en `ItemRegistry`

Crear un `ModuleScript` en:
`src/ReplicatedStorage/Shared/Catalog/Definitions/<Category>/<ItemId>.luau`

Categorías válidas:
- `Structures`
- `Wheels`
- `Engines`
- `Boosters`
- `FuelTanks`
- `Utilities`
- `Seats`
- `Decorations`
- `Other`

Ejemplo mínimo:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

local definition: ItemTypes.ItemDefinition = {
	Id = "MiNuevaPieza",
	DisplayName = "Mi Nueva Pieza",
	Category = "Structures",
	Model = "MiNuevaPieza",
	Price = 50, -- nil si el precio está TBD
	Stats = {
		Weight = 4,
		MaxDurability = 100,
	},
	Behavior = nil, -- Opcional: nombre del ModuleScript dentro de Behaviors/
	PlacementPolicy = { -- Opcional; por defecto Orthogonal90
		RotationMode = "Orthogonal90", -- "Orthogonal90" | "StepDegrees" | "Free"
		AllowedAngleStepsDeg = { 90 }, -- e.g. { 90, 45, 15, 1 } para StepDegrees/Free
		AllowFreePosition = true, -- permite colocación continua en modo Libre
		AllowFreeRotation = false,
	},
}

return definition
```

Reglas de validación automática:
- `Id` debe ser único en todo el catálogo.
- `Category` debe coincidir con el nombre de la carpeta padre.
- `Stats.Weight` y `Stats.MaxDurability` deben ser números finitos mayores a `0`.
- `Stats.ImpactResistance` (opcional) debe ser `nil` o número finito mayor a `0`.
- `Stats.DamageMultiplier` (opcional) y demás estadísticas numéricas opcionales (`Power`, `MaxSpeed`, etc.) deben ser `nil` o números finitos `>= 0`.
- En la categoría `Seats`, `DriverSeat` recibe el rol `DriverSeat` (máximo `1` por ensamblaje primario al lanzar; >1 dispara `MultipleDriverSeats`) y los demás ítems reciben rol `PassengerSeat`.
- Los campos marcados como `TBD` en el SDD deben permanecer en `nil` hasta confirmación de diseño.

## 2. Crear el modelo en `ServerStorage/ItemAssets` (Carpetas en español)

Desde la Fase 5.1, las carpetas físicas dentro de `ServerStorage/ItemAssets` (y su espejo visual generado por `PreviewAssetService` en `ReplicatedStorage/PreviewAssets`) utilizan nombres en español mapeados por `ItemRegistry`:
- `Structures` -> `Bloques`
- `Wheels` -> `Ruedas`
- `Engines` -> `Motores`
- `Seats` -> `Asientos`
- `FuelTanks` -> `Tanques`
- `Boosters` -> `Propulsores`
- (`Utilities` -> `Utilidades`, `Decorations` -> `Decoraciones`, `Other` -> `Otros`)

Crear el modelo en:
`src/ServerStorage/ItemAssets/<CarpetaEspañol>/<ModelName>/` (o como instancia/archivo `.model.json` / `.rbxmx` en Rojo o directamente en Studio). En la definición de catálogo (`ItemDefinition`), el campo opcional `AssetFolder` puede omitirse (se infiere desde `Category`) o declararse explícitamente igual a la carpeta española.

Requisitos obligatorios del modelo (validados por `ItemRegistry.ValidateAssets` en `Bootstrap`):
1. Nombre e identidad del `Model`:
   - El `Model.Name` debe coincidir exactamente con `definition.Model` (y estar dentro de su carpeta española correspondiente).
   - Atributos en el `Model`:
     - `ItemId` (`string`): debe coincidir exactamente con `definition.Id`.
     - `Category` (`string`): debe coincidir exactamente con el ID interno de categoría en `definition.Category` (`"Structures"`, `"Wheels"`, `"Engines"`, `"Seats"`, `"FuelTanks"`, `"Boosters"`, etc.).
2. `PrimaryPart` asignada: en modelos sincronizados por Rojo como carpetas, nombrar la parte principal física `Primary` para que `ItemRegistry.NormalizeAssets` la asigne como `PrimaryPart` automáticamente (para `DriverSeat`, `Primary` debe ser de clase `VehicleSeat`; para ruedas como `SmallWheel`, un `Part` cilíndrico con el eje longitudinal en local `X`).
3. Al menos un `Attachment` de conexión dentro del modelo cuyo nombre comience con `Conn_` (por ejemplo `Conn_Front`, `Conn_Bottom`, `Conn_Axle`, `Conn_AxleRight`), además de `WheelHub` en el centro `[0,0,0]` si es rueda.

### Reemplazar un modelo 3D existente sin modificar código (Fase 5.1)

Para actualizar la malla/geometría 3D de cualquiera de las `8` piezas actuales en `ServerStorage/ItemAssets/<CarpetaEspañol>/<NombreModelo>` **sin tocar ningún script**:
1. Conserva el nombre exacto del `Model` y su carpeta española padre (por ejemplo `ServerStorage/ItemAssets/Bloques/WoodBlock`, `Ruedas/SmallWheel`, `Motores/SmallEngine`, `Asientos/DriverSeat`, `Tanques/RegularFuelTank`, `Tanques/SmallNitroTank`, `Propulsores/SmallBooster`).
2. Mantén en el `Model` los atributos exactos `ItemId` y `Category` (código interno de categoría, e.g. `"Seats"` para `DriverSeat`).
3. Conserva o reasigna `Model.PrimaryPart` (o nombra `Primary` al `BasePart` principal). Si el ítem es `DriverSeat`, `Primary` debe seguir siendo un `VehicleSeat`; si agregas mallas visuales hijas (`MeshPart`/`Part`), suéldalas al `Primary` (o mantén su jerarquía dentro del `Model`, sin `Script`/`LocalScript` sueltos fuera de `Behaviors/`).
4. Conserva todos los `Attachment` `Conn_*` necesarios para encastre/snap y, en ruedas, el `Attachment` `WheelHub` y la orientación de giro sobre el eje local configurado (`SmallWheel`: eje local `X` y atributos opcionales `WheelRadius`/`WheelWidth`/`LocalSpinAxis`/`LocalSuspensionAxis`). En propulsores (`SmallBooster`), el vector de empuje sale hacia adelante (`-Z` local del `Primary` / tobera en `+Z`), y `BoosterBehavior` crea `NozzleAttachment` automáticamente en tiempo de ejecución.
5. Si el objeto usa lógica modular (`SmallEngine`, `SmallBooster`, `DriverSeat`), conserva su carpeta `Behaviors/` y el `ModuleScript` indicado en `definition.Behavior` (`EngineBehavior`, `BoosterBehavior`, `DriverSeatBehavior`). Al iniciar (`Bootstrap`), `PreviewAssetService` regenera automáticamente el espejo visual sanitizado en `ReplicatedStorage/PreviewAssets/<CarpetaEspañol>/<Model>` sin requerir edición de código cliente.

## 3. Comportamiento modular opcional (`Behaviors/`)

Si la pieza requiere lógica propia (por ejemplo motores, propulsores o asientos):
1. Definir `Behavior = "<NombreModulo>"` en la definición.
2. Crear `src/ServerStorage/ItemAssets/<CarpetaEspañol>/<ModelName>/Behaviors/<NombreModulo>.luau`:

```lua
--!strict
local MiBehavior = {}

function MiBehavior.Init(runtime, partState, model)
	-- Inicialización por pieza (sin bucles Heartbeat propios)
end

function MiBehavior.Destroy(runtime, partState, model)
	-- Limpieza al destruir o desmontar la pieza
end

return MiBehavior
```

`ItemRuntimeService` cargará y validará este módulo automáticamente al inicializar la pieza en runtime.

## 4. Interfaz de validación y pruebas

`ItemRegistry` expone métodos de validación puros que no mutan el catálogo global ni requieren crear `ModuleScript.Source` en tiempo de ejecución:
- `ItemRegistry.ValidateDefinition(def, expectedCategory?)`: valida una tabla de definición individual y devuelve `(boolean, string?)`.
- `ItemRegistry.LoadFromTables(definitions)`: valida una lista de tablas Luau (IDs únicos, categorías válidas, estadísticas finitas, campos requeridos).
- `ItemRegistry.LoadFromEntries(entries)`: valida entradas `{ Definition, ExpectedCategory?, SourceName? }` (usado internamente por `LoadFromFolder`).

## 5. Verificación

1. Ejecutar `rojo build -o VehicleSandbox.rbxl` para comprobar que el proyecto compila sin errores ni advertencias.
2. En Roblox Studio (o mediante la suite `Phase1Tests.RunAll()`), confirmar que `Bootstrap.server.lua` y `ItemRegistry.ValidateAssets` pasan sin errores.

## 6. Modelos editables de Tienda, Cajas Especiales y Reparto (`ServerStorage.Crates` — Fase 5.2)

Los modelos de tienda física, cajas y camión son independientes del código y viven bajo `src/ServerStorage/Crates/` (espejados en Studio en `ServerStorage.Crates`):

| Ruta en `ServerStorage.Crates` | Rol | Requisitos para reemplazo visual |
|---|---|---|
| `Normales/NormalDeliveryCrate` | Caja para pedidos normales (`60 s`) | Conservar nombre `NormalDeliveryCrate` y `PrimaryPart` (o parte llamada `Primary`). |
| `Especiales/Motores/BasicEngineCrate` | Caja especial de motores (`80` monedas) | Conservar nombre `BasicEngineCrate` y `Primary` (para nuevas cajas usar carpeta `AssetSubfolder` + `ModelName` de `LootBoxConfig.luau`). |
| `Especiales/Propulsores/BasicBoosterCrate` | Caja especial de propulsores (`45,000` monedas) | Conservar nombre `BasicBoosterCrate` y `Primary`. |
| `Reparto/DeliveryTruck` | Camión visual animado fuera de `BuildZone` | **Prohibido** incluir `Seat` o `VehicleSeat`; `DeliveryService` asigna automáticamente el grupo de colisión configurado en `ShopConfig.DeliveryZone.TruckCollisionGroup` (`DeliveryProps`). |
| `Reparto/ShopCounter` | Mostrador en `ShopZone` | Incluir parte o punto `PromptAnchor` (opcionalmente usando el `Primary`) donde se adjunta `OpenShopPrompt`. |
| `Efectos/OpenEffects` | Carpeta reservada para partículas/sonidos opcionales | Los emisores/sonidos dentro de `OpenEffects` son leídos sin requerir edición de scripts. |

### Agregar o habilitar una nueva Caja Especial (ej. `RoadEngineCrate`)
1. Crear su `Model` 3D dentro de `src/ServerStorage/Crates/Especiales/<Subcarpeta>/` con `Primary`.
2. Configurar su entrada en `ReplicatedStorage/Shared/Config/LootBoxConfig.luau` (`Price`, `Enabled = true`, `DisabledReason = nil`, `AssetSubfolder`, `ModelName`, `Restock`, `RarityWeights`, `SizeWeights`, `AllowedSizes`, `AllowedFamilies`, `AllowedVariants`).
3. Ejecutar `LootBoxConfig.ValidateBoxPool(boxId)` (o `Phase52Tests.RunAll()`) para comprobar que toda combinación elegible existe en `EngineCatalog`/`BoosterCatalog` e `ItemRegistry`.

## 9. Cómo agregar una nueva pieza aerodinámica (`Category = "Aerodynamics"`, Fase 5.3)

1. Registrar sus parámetros físicos y económicos (`Price`, `Weight`, `MaxDurability`, `Size`, `SurfaceType`, `Side`, `WingArea`, `LiftCoefficient`, `LiftSlopePerRad`, `ZeroLiftAngleDeg`, `BaseDragCoefficient`, `InducedDragFactor`, `FormDragCoefficient`, `StallAngleDeg`, `StallWidthDeg`, `PostStallLiftRetention`, `PostStallDragCoefficient`, `CenterOfPressureLocalOffset` y opcionalmente `VerticalStabilizerArea` / `ControlRole`) en `src/ReplicatedStorage/Shared/Config/AerodynamicsConfig.luau` y añadir su `ItemId` a `AerodynamicsConfig.OrderedItemIds`.
2. Crear su módulo de definición en `src/ReplicatedStorage/Shared/Catalog/Definitions/Aerodynamics/<ItemId>.luau` leyendo `AerodynamicsConfig.Items.<ItemId>` y exponiendo `AerodynamicSpecs`.
3. Crear su modelo 3D editable en `src/ServerStorage/ItemAssets/Aerodinamica/<ItemId>/` con `init.meta.json` (`PrimaryPart = "Primary"`) y `Primary.model.json` (orientación local estándar: frente en `-Z`, normal de sustentación en `+Y`, envergadura en `±X`).
4. `PreviewAssetService` clonará automáticamente el modelo hacia `ReplicatedStorage.PreviewAssets.Aerodinamica.<ItemId>` al iniciar el servidor, `AerodynamicsService` lo registrará al ensamblar cualquier vehículo y `ShopService` / `BuildController` lo mostrarán en la categoría `"Aerodinámica"`.
5. Ejecutar `Phase53Tests.RunAll()` y `Phase1Tests.RunCoreOnly()` para validar geometría, tienda, blueprints y física.

