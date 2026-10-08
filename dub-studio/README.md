# DUB Studio (prototipo operativo)

Núcleo para sincronizar un vídeo que es *parte* de un capítulo con un SRT completo, exportar intervenciones para revisión y **proteger** los tiempos y etiquetas al importar la traducción.

Requisito: Python 3.10+ y `ffmpeg`/`ffprobe` instalados y accesibles en PATH.

```bash
python dubstudio.py prepare --srt 'Apple My Love EP_4.srt' --video 'Parte 2.mp4' --chapter-start '00:20:00,000' --output trabajo/parte2
python dubstudio.py frames --session trabajo/parte2/session.json --output trabajo/parte2/frames --limit 15
# Completa trabajo/parte2/review.csv con personajes, confianza y evidencia.
python dubstudio.py apply --session trabajo/parte2/session.json --csv trabajo/parte2/review.csv --output trabajo/parte2/asignado.txt
# El traductor humano o futuro módulo IA produce traducido.txt (mismo formato DUB).
python dubstudio.py validate-translation --session trabajo/parte2/session.json --translated traducido.txt --output trabajo/parte2/final_es.txt
```

**Importante:** `--chapter-start` es el instante del capítulo al que corresponde el **primer fotograma del archivo**, no el primer subtítulo. No inferirlo del nombre del vídeo. La selección actual solo incluye bloques completamente contenidos en el clip; los bloques que cruzan cortes quedan pendientes.

El núcleo de consola no realiza reconocimiento audiovisual ni traducción IA. `frames` crea muestras para revisión, pero un fotograma por intervención no confirma hablantes. La aplicación visual descrita abajo incorpora un adaptador IA opcional con revisión humana y garantías adicionales.

## Aplicación visual local (fase 1)

El núcleo y sus comandos anteriores siguen disponibles, sin cambios. La nueva interfaz
usa únicamente la biblioteca estándar de Python; no requiere paquetes de aplicación.

1. Instala **Python 3.10 o posterior** y **FFmpeg** (incluido `ffprobe`) en tu ordenador.
   Comprueba `python --version`, `ffmpeg -version` y `ffprobe -version`.
2. En la carpeta `dub-studio`, ejecuta `python app.py --open-browser`, o usa `Iniciar.bat` en Windows / `./iniciar.sh` en macOS o Linux.
3. Abre en tu navegador la dirección que muestra la consola. Detén la aplicación con Ctrl+C.
   Solo escucha en la interfaz local; no es un servicio público.

Los datos se guardan en `~/.dubstudio` (SQLite y copias de vídeos). Puedes elegir otra
ubicación con `python app.py --data RUTA --port 8765`. Para trasladar el trabajo a otro
ordenador, copia esa carpeta completa con la aplicación detenida. Los vídeos originales
no se modifican. No incluyas esa carpeta en Git. Importar varias partes requiere espacio
para sus copias; límite de carga por archivo: 8 GB.

### Flujo

- Crea un capítulo con su **SRT completo**. El texto original, los tiempos y el orden quedan
  protegidos; las traducciones se almacenan por separado.
- Añade una o varias partes, indicando por separado el tiempo **del primer fotograma**
  en el capítulo. Comprueba el desfase con una intervención conocida. No hay detección
  automática de offset en esta fase. MP4 H.264/AAC es la opción más compatible; MOV/MKV
  pueden requerir convertir una copia conservando su duración. Los bloques que cruzan
  cortes se conservan en el SRT completo y quedan para revisión, sin análisis automático.
- Al seleccionar un diálogo, el reproductor busca una parte que lo contenga y se sitúa
  en `inicio original − desfase`. Los relojes muestran tiempo local y de capítulo, y el
  subtítulo sigue la reproducción, incluso con intervenciones simultáneas.
- Registra identidades **confirmadas** con apariencia, voz y evidencia. Se reutilizan solo
  en las partes del mismo capítulo. No crees un personaje por supuesto parecido.
- Revisa la lista (filtro `[REVISAR]`), selecciona personaje, documenta la evidencia y guarda.
  Los casos ambiguos o superpuestos pueden conservar sus etiquetas de revisión.
- Edita la traducción manualmente o pide un lote de hasta 20 traducciones pendientes.
  Revisa naturalidad, registro y duración antes de exportar.
- Exporta DUB original o español. La versión española exige traducción de todos los bloques;
  los personajes no confirmados conservan `[REVISAR]`. Cada exportación respeta
  `DUB (HH:MM:SS,mmm - HH:MM:SS,mmm) PERSONAJE` seguido del diálogo.

### IA audiovisual y traducción (opcional, requiere credencial)

La implementación incluye un adaptador Google Gemini con clips MP4 **con audio y vídeo**,
no inferencia de hablantes a partir de un fotograma. Antes de iniciar, configura una clave
válida en la variable de entorno `DUB_GEMINI_API_KEY`, sin incluirla en archivos del proyecto.
En el entorno cloud usa la configuración segura de secretos; nunca pegues la clave en chat.
El destino necesario es `generativelanguage.googleapis.com`. El modelo por defecto es
`gemini-2.5-flash`; puedes cambiarlo con `DUB_GEMINI_MODEL` por un modelo Gemini que acepte
vídeo/audio y salida JSON. Tu cuenta necesita acceso al modelo y cuota.

Cada clic en **Proponer hablante con IA** realiza una petición: envía exclusivamente el
clip de la intervención (máximo 30 segundos, reducido a 640 píxeles), el diálogo original
y el registro de identidades del capítulo. Las propuestas registran modelo, confianza,
observaciones y timestamps relativos al clip; la interfaz muestra su posición en el archivo
vídeo. El umbral 0,90 es conservador pero **no representa una precisión calibrada**. Identidades
ajenas, evidencia vacía o confianza baja producen `[REVISAR]`. Las propuestas **nunca asignan
por sí solas**: revisa el vídeo, usa la propuesta en el formulario y confirma manualmente.

La traducción envía diálogos y glosario, sin vídeo. Un resultado que altere id, tiempos,
orden o personaje se rechaza por completo antes de guardar. No se garantiza el ajuste de
cada frase a la duración; es una propuesta que necesita revisión de doblaje. Las operaciones
IA pueden generar costes; no hay llamadas en segundo plano ni análisis de capítulos completos.
La app guarda un historial de revisión y propuestas en la tabla `audit` de SQLite.

### Pruebas y límites de esta fase

```bash
python -m unittest discover -s tests -v
```

Las pruebas cubren el núcleo original, persistencia, registro por capítulo, abstención,
protección de metadatos, generación real de clips con FFmpeg y peticiones HTTP con carga,
exportación y rangos para reproducción. Los proveedores simulados prueban contratos y
seguridad de asignación; **no validan precisión de reconocimiento ni traducción real**.

También hay una prueba opcional de navegador: instala Playwright y su Chromium en tu
entorno de pruebas y ejecuta `python tests/browser_smoke.py`. Si ya hay Chromium del sistema,
puedes indicar su ruta con `DUB_TEST_CHROMIUM`. No se necesita Playwright para usar la app.

Pendiente para fases posteriores: precisión con vídeos etiquetados por humanos, detección
fiable de desfases, muestreo adaptativo/cambios de plano, firmas de voz e identidad con
referencias audiovisuales confirmadas, evaluación de sincronía labial y ajuste de traducción
a duración. La precisión audiovisual no se ha certificado. El registro actual guarda
las descripciones y evidencias textuales confirmadas, sin embeddings biométricos.
