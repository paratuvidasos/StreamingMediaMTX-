#!/bin/sh
# ============================================================================
# Puente de medios en vivo hacia n8n
#
# n8n NO puede consumir una transmisión: es un orquestador HTTP, no un
# transporte de medios. No existe un nodo que se conecte a WebRTC o RTSP, y
# aunque existiera, mandarle 30 fotogramas por segundo no tendría sentido.
#
# Lo que sí funciona, y es lo que hace este contenedor: convertir la clase en
# una sucesión de trozos pequeños que n8n sí sabe recibir. Un ffmpeg por
# transmisión activa lee el RTSP interno de MediaMTX y escribe fragmentos de
# audio de N segundos (16 kHz mono, que es lo que quiere Whisper y similares);
# opcionalmente saca también una imagen cada M segundos. Cada archivo cerrado
# se envía por multipart a un webhook de n8n y se borra.
#
# Así el workflow recibe la clase "desde el principio", en tiempo casi real,
# en piezas manejables: transcripción incremental, subtítulos, moderación,
# resúmenes parciales... sin que n8n toque nunca un flujo de vídeo.
# ============================================================================
set -eu

MEDIAMTX_API="${MEDIAMTX_API:-http://mediamtx:9997}"
MEDIAMTX_RTSP="${MEDIAMTX_RTSP:-rtsp://mediamtx:8554}"
N8N_WEBHOOK_URL="${N8N_WEBHOOK_URL:-}"
CHUNK_SECONDS="${CHUNK_SECONDS:-30}"
SNAPSHOT_SECONDS="${SNAPSHOT_SECONDS:-0}"   # 0 = sin imágenes, solo audio
POLL_SECONDS="${POLL_SECONDS:-10}"
WORKDIR=/chunks

if [ -z "$N8N_WEBHOOK_URL" ]; then
  echo "[bridge] Falta N8N_WEBHOOK_URL; el puente no tiene a dónde enviar. Saliendo."
  exit 1
fi

mkdir -p "$WORKDIR"
echo "[bridge] Arrancando. API=$MEDIAMTX_API  chunk=${CHUNK_SECONDS}s  snapshots=${SNAPSHOT_SECONDS}s"

# --- Lanza un ffmpeg dedicado a una transmisión ------------------------------
# Se queda pegado al RTSP hasta que la transmisión termina; entonces ffmpeg
# sale solo y el bucle principal lo da por acabado.
arrancar_ffmpeg() {
  ruta="$1"
  destino="$WORKDIR/$ruta"
  mkdir -p "$destino"

  set -- -hide_banner -loglevel warning -nostdin \
         -rtsp_transport tcp -i "$MEDIAMTX_RTSP/$ruta"

  # Audio: mono 16 kHz, troceado en segmentos de duración fija.
  set -- "$@" -vn -acodec libmp3lame -ab 64k -ar 16000 -ac 1 \
         -f segment -segment_time "$CHUNK_SECONDS" -reset_timestamps 1 \
         -strftime 1 "$destino/audio-%Y%m%d-%H%M%S.mp3"

  # Imágenes: una cada SNAPSHOT_SECONDS, solo si se pidieron.
  if [ "$SNAPSHOT_SECONDS" -gt 0 ]; then
    set -- "$@" -an -vf "fps=1/$SNAPSHOT_SECONDS" -q:v 4 \
           -strftime 1 "$destino/frame-%Y%m%d-%H%M%S.jpg"
  fi

  echo "[bridge] ▶ Capturando $ruta"
  ffmpeg "$@" >/dev/null 2>&1 &
  echo $!
}

# --- Envía a n8n los archivos ya cerrados ------------------------------------
# Dentro de cada carpeta se omite el último archivo de cada tipo: ese es el que
# ffmpeg tiene abierto ahora mismo. Como los nombres llevan la marca de tiempo
# (-strftime), el orden alfabético es el cronológico, así que basta con
# descartar la última línea de la lista ordenada.
enviar_un_archivo() {
  archivo="$1"
  ruta_stream="$2"
  case "$archivo" in
    *.mp3) tipo=audio ;;
    *)     tipo=frame ;;
  esac

  if curl -fsS --max-time 120 -X POST "$N8N_WEBHOOK_URL" \
      -H "X-SOS-Stream-Key: $ruta_stream" \
      -H "X-SOS-Chunk-Type: $tipo" \
      -F "streamKey=$ruta_stream" \
      -F "type=$tipo" \
      -F "file=@$archivo" >/dev/null 2>&1; then
    rm -f "$archivo"
  else
    # Se deja en disco y el siguiente ciclo reintenta: si n8n está caído un
    # rato, no se pierde ningún trozo de la clase.
    echo "[bridge] ⚠ No se pudo entregar $(basename "$archivo"); se reintentará."
  fi
}

enviar_pendientes() {
  for carpeta in "$WORKDIR"/*/; do
    [ -d "$carpeta" ] || continue
    ruta_stream=$(basename "$carpeta")

    for patron in 'audio-*.mp3' 'frame-*.jpg'; do
      # shellcheck disable=SC2086
      cerrados=$(ls -1 "$carpeta"$patron 2>/dev/null | sort | sed '$d')
      [ -n "$cerrados" ] || continue

      echo "$cerrados" | while read -r archivo; do
        [ -f "$archivo" ] || continue
        enviar_un_archivo "$archivo" "$ruta_stream"
      done
    done
  done
}

# --- Bucle principal ---------------------------------------------------------
activos=""

while true; do
  # Paths con publisher conectado, según la propia API de MediaMTX.
  nuevos=$(curl -fsS --max-time 5 "$MEDIAMTX_API/v3/paths/list" 2>/dev/null \
           | jq -r '.items[]? | select(.ready == true and .source != null) | .name' 2>/dev/null || true)

  for ruta in $nuevos; do
    case " $activos " in
      *" $ruta "*) ;;                                  # ya lo estamos capturando
      *) arrancar_ffmpeg "$ruta" >/dev/null
         activos="$activos $ruta" ;;
    esac
  done

  # Olvida las que ya no publican, para volver a engancharlas si reaparecen.
  restantes=""
  for ruta in $activos; do
    case " $nuevos " in
      *" $ruta "*) restantes="$restantes $ruta" ;;
      *) echo "[bridge] ■ Fin de $ruta" ;;
    esac
  done
  activos="$restantes"

  enviar_pendientes
  sleep "$POLL_SECONDS"
done
