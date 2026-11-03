#!/usr/bin/env bash
# Paso 3: Cosmos DB para MongoDB (capa gratuita) y Key Vault con los secretos.
#
# Las claves externas se pueden pasar como variables de entorno para no escribirlas
# en pantalla, p. ej.:  STRIPE_SECRET_KEY=sk_test_... ./03-datos-y-secretos.sh
# Las que no se indiquen quedan como "no-configurado" (el servicio arranca igual).
source "$(dirname "$0")/common.sh"

SNET_ACA_ID="$(snet_id "$SNET_ACA")"

# ------------------------------------------------------------- Cosmos DB
# Cosmos DB puede no tener capacidad en una región ("high demand"). Se prueban las
# regiones permitidas en orden; el resto de recursos sigue en $LOCATION y la cuenta
# solo acepta conexiones desde snet-aca (los Service Endpoints de Cosmos DB
# funcionan aunque la cuenta esté en otra región).
DATA_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_DATA"
ALLOWED_LOCATIONS_ID="$(az policy definition list --query "[?policyType=='BuiltIn' && displayName=='Allowed locations'].name | [0]" -o tsv)"

set_data_locations() { # Actualiza la política de ubicaciones de rg-<prefijo>-data
  local json
  json="$(printf '"%s",' "$@")"
  az policy assignment create --name "solo-region-$RG_DATA" \
    --display-name "SkyDish: ubicaciones permitidas ($RG_DATA)" \
    --policy "$ALLOWED_LOCATIONS_ID" --scope "$DATA_SCOPE" \
    --params "{\"listOfAllowedLocations\": {\"value\": [${json%,}]}}" -o none
}

state="$(az cosmosdb show -g "$RG_DATA" -n "$COSMOS" --query provisioningState -o tsv 2>/dev/null || true)"
if [ "$state" = "Succeeded" ]; then
  ok "$COSMOS ya existe"
else
  if [ -n "$state" ]; then
    warn "Se encontró $COSMOS en estado '$state'; se elimina para reintentar"
    az cosmosdb delete -g "$RG_DATA" -n "$COSMOS" --yes -o none || true
  fi

  read -ra candidates <<< "$COSMOS_LOCATIONS"
  log "Permitiendo temporalmente en $RG_DATA las regiones: ${candidates[*]}"
  set_data_locations "${candidates[@]}"
  sleep 30   # propagación de la política

  COSMOS_REGION=""
  for region in "${candidates[@]}"; do
    log "Creando Cosmos DB para MongoDB (free tier) en $region (tarda 5-10 minutos)"
    if az cosmosdb create -g "$RG_DATA" -n "$COSMOS" \
        --kind MongoDB --server-version 4.2 \
        --enable-free-tier true \
        --default-consistency-level Session \
        --locations regionName="$region" failoverPriority=0 isZoneRedundant=False \
        --public-network-access Enabled \
        --enable-virtual-network true \
        --virtual-network-rules "$SNET_ACA_ID" \
        --tags "${TAGS[@]}" -o none --only-show-errors 2> cosmos-error.log; then
      COSMOS_REGION="$region"
      ok "$COSMOS creado en $region"
      break
    fi
    if grep -qi "free tier" cosmos-error.log; then
      cat cosmos-error.log >&2
      echo "Ya existe otra cuenta de Cosmos DB con free tier en la suscripción." >&2
      exit 1
    fi
    warn "Sin capacidad en $region; probando la siguiente región"
    az cosmosdb delete -g "$RG_DATA" -n "$COSMOS" --yes -o none 2>/dev/null || true
  done
  rm -f cosmos-error.log

  if [ -z "$COSMOS_REGION" ]; then
    echo "Ninguna región tuvo capacidad para Cosmos DB. Intente más tarde o solicite acceso: https://aka.ms/cosmosdbquota" >&2
    exit 1
  fi

  log "Restringiendo de nuevo $RG_DATA a la región usada ($COSMOS_REGION)"
  set_data_locations "$COSMOS_REGION"
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
