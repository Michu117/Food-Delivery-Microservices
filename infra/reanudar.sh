#!/usr/bin/env bash
# Reanuda SkyDish: vuelve a iniciar las 6 Container Apps detenidas con ./pausar.sh.
# Los datos de Cosmos DB y los secretos de Key Vault se mantienen intactos.
source "$(dirname "$0")/common.sh"

API="2024-03-01"
apps=()
for svc in "${SERVICES[@]}"; do apps+=("${svc%%|*}"); done
apps+=(ca-gateway)   # el gateway al final, cuando los servicios internos ya existen

log "Iniciando Container Apps"
for name in "${apps[@]}"; do
  az rest --method post -o none \
    --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_APP/providers/Microsoft.App/containerApps/$name/start?api-version=$API" \
    && ok "$name iniciada" || warn "$name: no se pudo iniciar (¿no existe?)"
done

GATEWAY_URL="https://$(az containerapp show -g "$RG_APP" -n ca-gateway --query properties.configuration.ingress.fqdn -o tsv)"
log "SkyDish activo. Prueba: $GATEWAY_URL/health (la primera respuesta puede tardar unos segundos)"
