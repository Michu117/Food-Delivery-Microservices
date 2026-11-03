#!/usr/bin/env bash
# Pausa SkyDish: detiene las 6 Container Apps (5 microservicios + gateway).
# Con las apps detenidas no hay consumo de cómputo ni solicitudes.
# Cosmos DB (free tier), Key Vault, la red y las Static Web Apps (Free) se conservan
# con sus datos y no generan costo apreciable mientras tanto.
# Para reanudar: ./reanudar.sh
source "$(dirname "$0")/common.sh"

API="2024-03-01"
apps=(ca-gateway)
for svc in "${SERVICES[@]}"; do apps+=("${svc%%|*}"); done

log "Deteniendo Container Apps"
for name in "${apps[@]}"; do
  az rest --method post -o none \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_APP/providers/Microsoft.App/containerApps/$name/stop?api-version=$API" \
    && ok "$name detenida" || warn "$name: no se pudo detener (¿no existe?)"
done

log "SkyDish en pausa. El frontend sigue visible, pero la API no responde hasta ejecutar ./reanudar.sh"
