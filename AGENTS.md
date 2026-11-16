# Instrucciones para Antigravity / Claude / agentes

Lee `README.md` y todos los archivos `docs/` antes de implementar.

## Reglas obligatorias
1. No inventar estadísticas, fórmulas, precios, probabilidades ni mecánicas: buscar `TBD` y preguntar.
2. Separar estrictamente `Blueprint` persistente y `VehicleRuntime` temporal. **Nunca** persistir daño de un intento.
3. El servidor es autoritativo para inventario, compras, rarezas, validación de construcción, daño y recompensas.
4. Cliente usa edición optimista con ack/rollback, sin prometer 0 ms de red.
5. Servicios desacoplados; objetos registrados por `ItemId`; comportamiento opcional modular dentro del modelo.
6. No implementar todo a la vez. Trabajar por fases, pruebas y criterios de aceptación de `docs/09-MVP-TESTING.md`.
7. Evitar scripts de simulación por pieza; usar orquestador por vehículo.
8. No asumir que el stock es global: es compartido **por servidor**.
9. Para cada fase: enumerar archivos, contratos, pruebas y limitaciones.
10. Si surge conflicto entre documentos, pedir aclaración antes de alterar el diseño.

## Primer trabajo solicitado
Implementar exclusivamente la Fase 1 (bootstrap, estaciones, catálogo, registro de modelos), con pruebas de 10 jugadores y documentación para agregar nuevos objetos. No implementar todavía editor, físicas, tienda o misiones.
