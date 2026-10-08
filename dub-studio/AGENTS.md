# DUB Studio — instrucciones permanentes para Codex

## Misión
Construir una aplicación local para asignar personajes por intervención de SRT mediante evidencia audiovisual y traducir luego los diálogos al español para doblaje.

## Reglas innegociables
- Los tiempos del SRT son inmutables, incluso entre vídeos consecutivos.
- NUNCA asumir que el rostro en plano es el hablante.
- Priorizar evidencia visual, labios sincronizados, continuidad de rostros, continuidad de voz, respuesta conversacional y por último contexto.
- Si no hay evidencia suficiente, asignar exactamente `[REVISAR]`. Para superposición ambigua usar `[REVISAR – VOCES SUPERPUESTAS]`.
- Texto original, puntuación, saltos de línea, barras, etc. intocables durante asignación.
- Conservar registro de personajes confirmado por episodio con descripciones visuales y evidencias; no identificar rostros solo por supuesto parecido.
- No asignar fuera del intervalo del vídeo.
- Formato exportado `DUB (HH:MM:SS,mmm - HH:MM:SS,mmm) PERSONAJE` seguido del diálogo exacto.
- Al traducir, cambiar solo el texto, jamás las etiquetas, tiempos, orden o personaje.
- Registrar para cada propuesta confianza, evidencia, vídeo y timestamp de fotograma o clip.
- Las propuestas de IA requieren revisión humana donde exista incertidumbre.
- No afirmar una identidad sin sustento; no inventar personajes.

## Próximos hitos
1. Mantener `dubstudio.py` y sus tests como núcleo determinista.
2. Detectar automáticamente el offset de cada clip cuando existan señales fiables; pedir al usuario fijarlo si no.
3. Añadir muestreo adaptativo: primeros/últimos fotogramas, cambios de plano y clips cortos de audio por intervención.
4. Integrar análisis multimodal mediante proveedor configurable, resultados JSON estructurados y límites de coste.
5. Diseñar registro de identidades confirmadas, voz y apariencia por capítulo (SQLite).
6. Interfaz Streamlit o web: vídeo y subtítulo sincronizados, foto/candidatos, corrección rápida y botón exportar.
7. Traducción asistida con glosario y validación estricta del resultado.
8. Tests end-to-end con archivos reales y casos sin evidencia, voces fuera de cuadro y superposiciones.

## Pruebas
Ejecutar: `python -m unittest discover -s tests -v`.

No se debe considerar completada la automatización audiovisual sin pruebas de precisión con datos etiquetados por humanos.
