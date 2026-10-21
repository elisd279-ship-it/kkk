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

**Windows 10/11 de 64 bits:** descomprime el ZIP y haz doble clic en **`Instalar.bat`**.
No necesitas `winget`, preparar Python o FFmpeg, editar el PATH ni ejecutar como administrador.
El instalador comprueba si ya tienes versiones compatibles y descarga las que falten.
Después crea accesos directos en el escritorio y el menú Inicio y abre la aplicación.
Las siguientes veces usa el acceso directo **DUB Studio** o `Iniciar.bat`.

La primera instalación requiere conexión a Internet y aproximadamente 1 GB libre para
las descargas, la instalación y los archivos temporales. Los vídeos requieren espacio adicional.
La aplicación y sus dependencias se guardan en `%LOCALAPPDATA%\DUBStudio`, sin modificar
el PATH permanente. Las actualizaciones conservan la aplicación anterior en una carpeta
`app-backup-*` y mantienen los proyectos en su ubicación original. Si falla, vuelve a
abrir `Instalar.bat`: reutiliza las descargas válidas y muestra el motivo del fallo. El registro
se encuentra en `%LOCALAPPDATA%\DUBStudio\install.log`.

Se utilizan **Python 3.14.8** de python.org y **FFmpeg 8.1.2 Essentials** de Gyan cuando
faltan dependencias. Las descargas se comprueban contra hashes SHA256 fijados en
`installer/dependencies.json`; el instalador de Python también necesita una firma válida
de Python Software Foundation. Nunca se ejecuta un archivo cuya verificación falle.
La licencia y los avisos de FFmpeg se conservan junto a sus binarios. La IA sigue siendo
opcional y necesita tu propia clave de Gemini; el instalador no la solicita ni la almacena.

**macOS / Linux, o ejecución manual:** instala Python 3.10+ y FFmpeg/ffprobe y ejecuta
`python3 app.py --open-browser` desde `dub-studio` (o `./iniciar.sh`). En macOS con Homebrew:
`brew install python ffmpeg`. En Ubuntu/Debian: `sudo apt install python3 ffmpeg`.
La automatización de instalación de esta versión es para Windows x64.

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

### Comprobación del instalador

`tests/installer_contract.ps1` comprueba caché, rechazo de descargas corruptas y firmas
inválidas, protección de datos y reinstalación con rutas que contienen espacios. Se puede
ejecutar con Windows PowerShell 5.1 o PowerShell 7, sin instalar Pester.

El workflow `.github/workflows/windows-installer.yml` usa una máquina Windows desechable
y ejecuta `tests/windows_install_smoke.ps1`: descarga e instala realmente las dependencias,
verifica las firmas, prueba la reinstalación sin descargas, ejecuta la suite de la aplicación
y comprueba los accesos directos y el arranque HTTP de la copia instalada. El parámetro
`-BundledOnly` fuerza dependencias privadas para esa prueba. No uses esta prueba de integración
como instalador normal; usa `Instalar.bat`.

Para mantener las versiones fijadas, contrasta las nuevas descargas con las publicaciones
del proveedor (Python: bundle `.sigstore` del mismo archivo; FFmpeg: `.zip.sha256`), actualiza
el manifiesto y ejecuta las pruebas. No sustituyas el hash esperado para eludir un fallo.

### Si Windows deniega el acceso a ffmpeg.exe

El instalador extrae FFmpeg directamente en su ubicación definitiva y lo comprueba allí:
no mueve ni elimina el ejecutable después de probarlo. Reintenta operaciones cuando hay
bloqueos transitorios de archivos. Si una instalación anterior está ocupada o incompleta,
instala una copia verificada en otra carpeta del mismo usuario, sin sobrescribirla.
Solo reutiliza las nuevas carpetas después de completar su extracción y comprobaciones.
Un fallo al limpiar temporales queda como aviso y no oculta el resultado de instalación.
Los temporales bloqueados o las instalaciones incompletas pueden conservarse en
`%LOCALAPPDATA%\DUBStudio`; no afectan a los proyectos.

Cierra otras ventanas de DUB Studio y ejecuta el `Instalar.bat` de la versión actualizada.
Si persiste, abre `%LOCALAPPDATA%\DUBStudio\install.log` y comparte sus últimas líneas:
incluyen la fase, ruta y excepción originales para distinguir un bloqueo transitorio
de una restricción permanente. El instalador respeta las restricciones de Windows.
