#!/usr/bin/env bash
# Crea una nueva revisión de cada Container App con la última imagen de ghcr.io.
# Úselo después de que el workflow "Imágenes de contenedores" termine.
#   ./05-actualizar-imagenes.sh            -> todas
#   ./05-actualizar-imagenes.sh ca-payment -> solo una
source "$(dirname "$0")/common.sh"

apps=("$@")
if [ ${#apps[@]} -eq 0 ]; then
  for svc in "${SERVICES[@]}"; do apps+=("${svc%%|*}"); done
  apps+=(ca-gateway)
fi

for name in "${apps[@]}"; do
  image="${name#ca-}"
  az containerapp update -g "$RG_APP" -n "$name" \
    --image "ghcr.io/$GHCR_OWNER/skydish-$image:$IMAGE_TAG" \
    --revision-suffix "r$(date +%s)" -o none
  ok "$name actualizado"
done
