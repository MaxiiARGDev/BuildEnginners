# 02 — Gameplay y estados

## Bucle principal
1. Jugador entra y recibe estación libre.
2. Compra/recibe piezas y las administra en inventario.
3. Construye un vehículo en la zona de edición (preview local, validación servidor).
4. Ajusta el vehículo completo con el stand: arriba/abajo/izquierda/derecha.
5. Presiona **Conducir**. Se congela una instantánea autorizada del blueprint.
6. El vehículo físico se centra en el punto de lanzamiento; inicia intento con durabilidad máxima en cada pieza.
7. Avanza, supera obstáculos, obtiene progreso por distancia y puede sufrir daños/desprendimientos.
8. Al morir, reiniciar o volver a base, se destruye runtime, se regresa al jugador y se reconstruye el diseño intacto.
9. Repite indefinidamente. Ningún daño modifica el inventario ni el blueprint.

## Máquina de estados propuesta
`Idle -> Editing -> PreparingLaunch -> Driving -> Returning -> Editing`.
- `PreparingLaunch` bloquea operaciones de edición mientras el servidor valida y ensambla.
- Reintentos idempotentes de `Return` y limpieza por desconexión.
- Si falla el lanzamiento, conservar blueprint e inventario, volver a Editing y mostrar error.

## Durabilidad confirmada
- `MaxDurability` en definición de cada objeto; `CurrentDurability` solo en runtime.
- Impactos descuentan durabilidad de piezas afectadas.
- Al llegar a cero: componente deja de funcionar, se rompe la conexión y la pieza puede desprenderse.
- Al terminar intento: limpiar escombros y runtime; reconstruir íntegramente.
- No hay reparación ni daño permanente por conducción.

## Combustible
Tanques y motores tienen capacidad y consumo. **Pendiente**: reglas exactas de recarga económica entre intentos. Propuesta MVP: combustible runtime se reinicia al valor inicial del diseño, sin costo adicional; no asumir que esto está aprobado.
