# 01 — Visión y alcance

## Producto
Sandbox multijugador de construcción modular de vehículos en Roblox Studio. Inspiración conceptual: Trailmakers y Approximately Up, pero con sistemas más sencillos y una progresión centrada en distancia, dinero, piezas y motores de rareza.

## Confirmado
- 10 jugadores por servidor; cada uno dispone de una estación exclusiva.
- Mapa largo y recto, obstáculos terrestres y aéreos; medición de distancia desde la base hacia delante.
- Construcción en estación, lanzamiento desde la misma zona, tienda, stand de posicionamiento del vehículo y zona de entrega.
- Inventario y economía en dinero.
- Motores y propulsores obtenibles en cajas con tamaños y rarezas.
- Stock limitado compartido entre los jugadores de un servidor, entrega mediante camión cada 15 minutos y opción de adelantar entrega pagando.
- Misiones personales, de servidor y globales.
- Daño individual y desprendimiento de piezas durante conducción; restauración completa al volver a base.
- Sistema modular, extensible y duplicable, con edición local y validación de servidor.

## No objetivos iniciales
- Simulación compleja de circuitos eléctricos, tuberías, flujo de combustible o cableado manual.
- Pérdida permanente de piezas por daño durante un intento.
- Implementación de todas las categorías y misiones antes de probar el vehículo básico.

## Principios
1. La definición del objeto es declarativa y está validada por servidor.
2. El blueprint es el diseño autorizado; runtime es desechable.
3. La respuesta visual del editor debe ser inmediata, aunque la validación de red no tenga latencia cero.
4. La física se concentra en controladores compartidos y constraints; evitar un bucle por pieza.
5. Toda mecánica nueva debe entrar mediante contratos estables, sin reescribir servicios centrales.
