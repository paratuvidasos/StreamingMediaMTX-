# Puente de medios en vivo hacia n8n.
#
# Contenedor aparte a propósito: la imagen oficial de MediaMTX se construye
# FROM scratch y no tiene shell, ffmpeg ni curl, así que nada de esto podría
# vivir dentro de ella.
FROM alpine:3.20

RUN apk add --no-cache ffmpeg curl jq

COPY bridge.sh /usr/local/bin/bridge.sh
RUN chmod +x /usr/local/bin/bridge.sh

# Los fragmentos son efímeros: se generan, se envían y se borran.
VOLUME ["/chunks"]

ENTRYPOINT ["/usr/local/bin/bridge.sh"]
