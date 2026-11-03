#!/usr/bin/env bash
# Paso 3: Cosmos DB para MongoDB (capa gratuita) y Key Vault con los secretos.
#
# Las claves externas se pueden pasar como variables de entorno para no escribirlas
# en pantalla, p. ej.:  STRIPE_SECRET_KEY=sk_test_... ./03-datos-y-secretos.sh
# Las que no se indiquen quedan como "no-configurado" (el servicio arranca igual).
source "$(dirname "$0")/common.sh"

SNET_ACA_ID="$(snet_id "$SNET_ACA")"

# ------------------------------------------------------------- Cosmos DB
log "Creando Cosmos DB para MongoDB con free tier (tarda 5-10 minutos)"
if az cosmosdb show -g "$RG_DATA" -n "$COSMOS" >/dev/null 2>&1; then
  ok "$COSMOS ya existe"
else
  # Solo acepta conexiones desde snet-aca (Service Endpoint + regla de red)
  az cosmosdb create -g "$RG_DATA" -n "$COSMOS" \
    --kind MongoDB --server-version 4.2 \
    --enable-free-tier true \
    --default-consistency-level Session \
    --locations regionName="$LOCATION" failoverPriority=0 isZoneRedundant=False \
    --public-network-access Enabled \
    --enable-virtual-network true \
    --virtual-network-rules "$SNET_ACA_ID" \
    --tags "${TAGS[@]}" -o none \
  || { echo "Error al crear Cosmos DB. Si el mensaje menciona 'free tier', ya existe otra cuenta gratuita en la suscripción." >&2; exit 1; }
  ok "$COSMOS"
fi

log "Creando base de datos '$COSMOS_DB' con 1000 RU/s compartidas (dentro de la capa gratuita)"
az cosmosdb mongodb database create -g "$RG_DATA" -a "$COSMOS" -n "$COSMOS_DB" --throughput 1000 -o none 2>/dev/null \
  || ok "La base de datos ya existe"

CONN="$(az cosmosdb keys list -g "$RG_DATA" -n "$COSMOS" --type connection-strings \
  --query "connectionStrings[0].connectionString" -o tsv)"
# Se agrega el nombre de la base de datos antes de los parámetros
MONGO_URI="$(printf '%s' "$CONN" | sed "s#:10255/?#:10255/$COSMOS_DB?#")"

# ------------------------------------------------------------- Key Vault
log "Creando Key Vault (modelo de permisos RBAC)"
if az keyvault show -n "$KV" >/dev/null 2>&1; then
  ok "$KV ya existe"
else
  az keyvault create -g "$RG_APP" -n "$KV" -l "$LOCATION" \
    --enable-rbac-authorization true --retention-days 7 \
    --tags "${TAGS[@]}" -o none
  ok "$KV"
fi
KV_ID="$(az keyvault show -n "$KV" --query id -o tsv)"

log "Dando al usuario actual permiso para escribir secretos"
ME="$(az ad signed-in-user show --query id -o tsv)"
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role "Key Vault Secrets Officer" --scope "$KV_ID" -o none 2>/dev/null || true

set_secret() { az keyvault secret set --vault-name "$KV" -n "$1" --value "$2" -o none; }

log "Guardando secretos en Key Vault"
JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"
retry set_secret mongo-uri "$MONGO_URI"
set_secret jwt-secret "$JWT_SECRET"
set_secret stripe-secret-key     "${STRIPE_SECRET_KEY:-no-configurado}"
set_secret stripe-webhook-secret "${STRIPE_WEBHOOK_SECRET:-no-configurado}"
set_secret twilio-account-sid    "${TWILIO_ACCOUNT_SID:-no-configurado}"
set_secret twilio-auth-token     "${TWILIO_AUTH_TOKEN:-no-configurado}"
set_secret twilio-phone-number   "${TWILIO_PHONE_NUMBER:-no-configurado}"
set_secret resend-api-key        "${RESEND_API_KEY:-no-configurado}"
ok "8 secretos guardados (los vacíos quedaron como 'no-configurado')"

log "Listo. Siguiente paso: publicar las imágenes (GitHub Actions) y luego ./04-aplicaciones.sh"
