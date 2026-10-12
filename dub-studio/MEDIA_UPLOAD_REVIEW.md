# Revisión limitada: media y carga de vídeo

Base: `619386f1aca5da88250c9334b99a54a6ada88f80`.
Cambios de comportamiento exclusivamente en `Handler.media` y la rama
`/api/video` de `Handler.do_POST`. Sin cambio de esquema ni otras rutas.

## Reproducción

Desde `dub-studio`: `python -m unittest discover -s tests -v`.
Resultado local: 22 tests correctos, 11 nuevos métodos con subcasos.
`python -m unittest discover -s tests -p test_media_upload.py -v`
ejecuta solamente la nueva batería. No necesita red, credenciales ni FFmpeg:
usa SQLite y archivos reales en directorios temporales y simula metadata,
streams de entrada, escrituras parciales y triggers SQLite. La batería previa
incluye una petición HTTP real con carga y reproducción y FFmpeg real.

Para GET, fixture `/media/1` con archivo `0123456789` (10 bytes).
Para POST, petición autorizada:
`POST /api/video?chapter=1&name=new.mp4&offset=00:00:00,000`, cuerpo `abc`,
Host local y `X-DUB-Token` válido. Metadata simulada de 1000 ms.
Las respuestas indicadas son el contrato del parche.

| Petición / inyección reproducible | Respuesta esperada | Riesgo | Función |
|---|---|---|---|
| GET, `Range:` vacío o `bytes=-` | 416, JSON uniforme, `Content-Range: bytes */10` | Range vacío ignorado o error sin tamaño | `media` |
| GET, `bytes=8-2` | Mismo 416 | Respuesta de error distinta | `media` |
| GET, `bytes=10-` o `bytes=20-30` | Mismo 416 | Inicio fuera del archivo | `media` |
| GET, `bytes=-0`, `bytes=--1`, `bytes=-abc` | Mismo 416 | Sufijo nulo o inválido | `media` |
| GET, múltiples rangos o entero de 5000 dígitos | Mismo 416 | Parser no uniforme / excepción de conversión | `media` |
| GET, archivo vacío y `bytes=0-` | 416, `Content-Range: bytes */0` | Intervalo sin bytes | `media` |
| GET, `bytes=2-4`, `bytes=8-99`, `bytes=8-`, `bytes=-3`, `bytes=-99` | 206 y bytes exactos; extremo final recortado | Regresión de reproducción válida | `media` |
| GET sin Range, archivo normal o vacío | 200, longitud y cuerpo exactos | Regresión de descarga completa | `media` |
| POST sin Content-Length | 411, `Falta Content-Length` | Cabecera ausente confundida con vídeo vacío | `do_POST` |
| POST Content-Length `abc`, negativo, con signo, decimal, vacío o 5000 dígitos | 400, `Content-Length inválido` | Mensajes accidentales de `int()` o sintaxis permisiva | `do_POST` |
| POST Content-Length duplicado o junto a Transfer-Encoding | Mismo 400 | Framing ambiguo | `do_POST` |
| POST Content-Length 0 o 8 GB + 1 byte | 400, límite previo conservado | Carga vacía / excesiva | `do_POST` |
| POST Content-Length 4, cuerpo `abc`, EOF | 400, `Carga interrumpida` | Archivo parcial | `do_POST` |
| POST lectura lanza ConnectionResetError | 500 genérico | Interrupción del stream | `do_POST` |
| POST escritura lanza OSError tras escribir un byte | 500 genérico | Archivo parcial por fallo de disco | `do_POST` |
| POST write(abc) devuelve 1 | 500 genérico | Escritura corta aceptada | `do_POST` |
| POST write(abc) devuelve 3 pero guarda un byte | 500 genérico | Bytes recibidos distintos del tamaño en disco | `do_POST` |
| POST metadata cambia el archivo a un byte | 500 genérico | Cambio de tamaño durante validación | `do_POST` |
| POST trigger altera path, ignora INSERT o aborta INSERT | 500 genérico, rollback | Éxito con registro inconsistente o error SQL | `do_POST` |
| POST stream devuelve más bytes que read(n) pidió | 400 | Violación defensiva del contrato de lectura | `do_POST` |
| POST lecturas de un byte; EOF prematuro o metadata falla | 400 | Error tras varios avances de la carga | `do_POST` |
| POST válido, Content-Length 3, cuerpo `abc` | 200 con id; GET devuelve `abc`; registro coincide con capítulo, nombre, ruta, offset y duración | Consistencia del camino exitoso | Ambas |

Todos los errores de carga comprueban ausencia de archivos nuevos, igualdad de
las cinco tablas previas y conservación byte por byte del vídeo anterior.
Todos los 416 comprueban longitud de respuesta, cuerpo y cabeceras iguales.

## Hallazgos verificables en la base

- Range vacío se trata como ausencia de Range y devuelve 200. Sintaxis inválida
  devuelve JSON sin Content-Range; rango invertido, fuera de tamaño o sufijo cero
  devuelve 416 sin cuerpo ni Content-Length. Enteros demasiado largos pueden
  salir por el 400 general de do_GET. No se afirma que rangos invertidos se sirvan.
- Content-Length ausente y no numérico ya se rechazan con 400, pero por rutas
  y mensajes distintos. `+3` se acepta; cabeceras duplicadas y Transfer-Encoding
  no se validan explícitamente en esta ruta.
- EOF y OSError ya limpian el archivo y evitan registrar el vídeo. Son garantías
  existentes, ahora cubiertas; no se presentan como fallos nuevos.
- `write()` no se comprueba. Una escritura corta simulada permite 200 y registro
  de un archivo incompleto si metadata devuelve una duración válida.
- No se compara longitud recibida con tamaño final, tampoco tras metadata.
- `Store.add_video` usa una transacción para insertar, pero la ruta no verifica
  el registro resultante: un trigger que modifica path o ignora INSERT reproduce
  un 200 con registro incorrecto o ausente. Es una inyección determinista, no una
  afirmación de que esos triggers existan en producción.

## Parche mínimo propuesto e implementado

Unificar el 416, distinguir 411/400 para longitud, rechazar framing ambiguo,
comprobar bytes escritos y tamaño de archivo. Mantener la inserción y lectura
de verificación en una transacción dentro de la ruta antes del 200, incluyendo
una nueva comprobación de tamaño después de metadata. Se reproduce la lógica
de registro de add_video en esta ruta para poder verificar antes del commit,
sin modificar Store ni otras llamadas. Un fallo provoca rollback y la limpieza
existente del archivo. SQLite no tiene columna de tamaño: se compara la longitud
HTTP con el archivo y los campos reales del registro, sin inventar un campo.

## Límites concretos

Las pruebas no afirman atomicidad entre SQLite y el sistema de archivos ante una
caída del proceso o pérdida de energía, ni protección frente a modificaciones
externas posteriores al último chequeo. No se añade timeout para un cliente que
mantiene la conexión abierta sin enviar el resto del cuerpo. Un EOF y un reset
sí se prueban. Bytes enviados por encima de Content-Length en un socket normal
no pertenecen al cuerpo declarado y no se detectan leyendo más: hacerlo podría
bloquear. Los tests de escritura corta y triggers prueban defensas por inyección.
