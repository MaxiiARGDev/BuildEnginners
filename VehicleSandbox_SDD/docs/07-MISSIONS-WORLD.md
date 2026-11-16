# 07 — Mundo y misiones

## Mundo
- Mapa extenso en una sola dirección principal, con obstáculos de tierra y aire.
- Distancia desde referencia de base hacia eje longitudinal del mapa; determinar orientación concreta al construir el mapa.
- No premiar movimiento lateral o marcha atrás como nuevo récord de avance.
- Obstáculos organizados por sectores para facilitar streaming y rendimiento.

## Misiones personales
Ejemplos confirmados: alcanzar distancia objetivo, comprar propulsor mejorado. Progreso individual, recompensas configurables.

## Misiones de servidor
- Stand para activar misión para jugadores activos del mismo servidor.
- Aparece una caja/objetivo de recolección en una posición del mapa.
- El primer jugador que la recoge válidamente obtiene la recompensa única y termina la misión para todos.
- Validar recogida y resolver ganador en servidor; evitar dos ganadores por simultaneidad.

## Misiones globales
- Se activan periódicamente cada 2 horas o manualmente por administrador.
- Ocurren en todos los servidores del juego.
- Recompensas y condiciones más exclusivas que misiones normales.
- Arquitectura futura: coordinación entre servidores, mensajes de activación y estado persistente con control de duplicados; no depender solo de mensajes efímeros.
- **Pendiente**: si recompensa global es única en todo el juego, por servidor o por jugador; y zona horaria/ancla del ciclo de 2 horas.

## MVP
Probar medición de distancia y una misión personal sencilla. Implementar misión de servidor y global después de validar la base técnica.
