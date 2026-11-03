#!/usr/bin/env bash
# Paso 4: Log Analytics, entorno de Container Apps en la VNet, identidad administrada,
# 2 sitios web estáticos en Storage y las 6 Container Apps (5 microservicios + gateway).
#
# Requisito: las imágenes ya deben existir en ghcr.io (workflow "Imágenes de contenedores").
source "$(dirname "$0")/common.sh"

SNET_ACA_ID="$(snet_id "$SNET_ACA")"
KV_URI="$(az keyvault show -n "$KV" --query properties.vaultUri -o tsv)"
KV_URI="${KV_URI%/}"
KV_ID="$(az keyvault show -n "$KV" --query id -o tsv)"

# --------------------------------------------------------- Log Analytics
log "Creando Log Analytics con límite diario de 0,1 GB"
az monitor log-analytics workspace create -g "$RG_APP" -n "$LOG" -l "$LOCATION" \
  --retention-time 30 --quota 0.1 --tags "${TAGS[@]}" -o none
LOG_ID="$(az monitor log-analytics workspace show -g "$RG_APP" -n "$LOG" --query customerId -o tsv)"
LOG_KEY="$(az monitor log-analytics workspace get-shared-keys -g "$RG_APP" -n "$LOG" --query primarySharedKey -o tsv)"
ok "$LOG"

# ------------------------------------------------ Entorno de Container Apps
log "Creando entorno de Container Apps en snet-aca (tarda 5-10 minutos)"
if az containerapp env show -g "$RG_APP" -n "$CAE" >/dev/null 2>&1; then
  ok "$CAE ya existe"
else
  az containerapp env create -g "$RG_APP" -n "$CAE" -l "$LOCATION" \
    --enable-workload-profiles \
    --infrastructure-subnet-resource-id "$SNET_ACA_ID" \
    --logs-workspace-id "$LOG_ID" --logs-workspace-key "$LOG_KEY" \
    --tags "${TAGS[@]}" -o none
  ok "$CAE (perfil Consumption, ingreso externo solo para el gateway)"
fi

# ------------------------------------------------ Identidad administrada
log "Creando identidad administrada con acceso de lectura a Key Vault"
az identity create -g "$RG_APP" -n "$IDENTITY" -l "$LOCATION" --tags "${TAGS[@]}" -o none
ID_RES="$(az identity show -g "$RG_APP" -n "$IDENTITY" --query id -o tsv)"
ID_PRINCIPAL="$(az identity show -g "$RG_APP" -n "$IDENTITY" --query principalId -o tsv)"
retry az role assignment create --assignee-object-id "$ID_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope "$KV_ID" -o none
ok "$IDENTITY -> Key Vault Secrets User"
warn "Esperando 60 s a que se propague el permiso..."
sleep 60

# ------------------------------------------- Frontends (Storage static website)
# Static Web Apps no está disponible en las regiones permitidas por Azure for Students,
# así que cada frontend se publica como sitio web estático de una cuenta de Storage
# (Standard LRS: unos centavos al mes por pocos MB).
log "Creando cuentas de Storage para los dos frontends"
for st in "$ST_WEB" "$ST_DRIVER"; do
  az storage account show -g "$RG_APP" -n "$st" >/dev/null 2>&1 || \
    az storage account create -g "$RG_APP" -n "$st" -l "$LOCATION" \
      --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
      --allow-blob-public-access false --https-only true --tags "${TAGS[@]}" -o none
  key="$(az storage account keys list -g "$RG_APP" -n "$st" --query "[0].value" -o tsv)"
  # index.html también como página 404 para que funcionen las rutas de React
  az storage blob service-properties update --account-name "$st" --account-key "$key" \
    --static-website --index-document index.html --404-document index.html -o none
  ok "$st (sitio web estático habilitado)"
done
web_url() { az storage account show -g "$RG_APP" -n "$1" --query primaryEndpoints.web -o tsv | sed 's#/$##'; }
WEB_URL="$(web_url "$ST_WEB")"
DRIVER_URL="$(web_url "$ST_DRIVER")"
CORS_ORIGIN="$WEB_URL,$DRIVER_URL,http://localhost:3000"

# ------------------------------------------------------- Container Apps
REGISTRY_ARGS=()
if [ -n "$GHCR_USER" ] && [ -n "$GHCR_TOKEN" ]; then
  REGISTRY_ARGS=(--registry-server ghcr.io --registry-username "$GHCR_USER" --registry-password "$GHCR_TOKEN")
fi

kvref() { echo "$1=keyvaultref:$KV_URI/secrets/$1,identityref:$ID_RES"; }

deploy_app() { # nombre imagen puerto ingreso
  local name=$1 image=$2 port=$3 ingress=$4
  local img="ghcr.io/$GHCR_OWNER/skydish-$image:$IMAGE_TAG"
  local secrets=() envs=()

  if [ "$image" != "gateway" ]; then
    secrets=("$(kvref mongo-uri)" "$(kvref jwt-secret)")
    envs=("PORT=$port" "MONGO_URI=secretref:mongo-uri" "JWT_SECRET=secretref:jwt-secret"
          "JWT_EXPIRES_IN=1d" "CORS_ORIGIN=$CORS_ORIGIN")
  fi
  if [ "$image" = "payment" ]; then
    for s in stripe-secret-key stripe-webhook-secret twilio-account-sid twilio-auth-token twilio-phone-number resend-api-key; do
      secrets+=("$(kvref "$s")")
    done
    envs+=("STRIPE_SECRET_KEY=secretref:stripe-secret-key" "STRIPE_WEBHOOK_SECRET=secretref:stripe-webhook-secret"
           "TWILIO_ACCOUNT_SID=secretref:twilio-account-sid" "TWILIO_AUTH_TOKEN=secretref:twilio-auth-token"
           "TWILIO_PHONE_NUMBER=secretref:twilio-phone-number" "RESEND_API_KEY=secretref:resend-api-key")
  fi

  if az containerapp show -g "$RG_APP" -n "$name" >/dev/null 2>&1; then
    az containerapp update -g "$RG_APP" -n "$name" --image "$img" --revision-suffix "r$(date +%s)" -o none
    ok "$name actualizado"
    return
  fi

  local extra=()
  [ ${#secrets[@]} -gt 0 ] && extra+=(--secrets "${secrets[@]}")
  [ ${#envs[@]} -gt 0 ] && extra+=(--env-vars "${envs[@]}")

  az containerapp create -g "$RG_APP" -n "$name" --environment "$CAE" \
    --image "$img" "${REGISTRY_ARGS[@]}" \
    --ingress "$ingress" --target-port "$port" \
    --cpu 0.25 --memory 0.5Gi \
    --min-replicas 0 --max-replicas 1 \
    --user-assigned "$ID_RES" \
    "${extra[@]}" \
    --tags "${TAGS[@]}" -o none
  ok "$name ($ingress, puerto $port, escala 0-1)"
}

log "Desplegando microservicios con ingreso interno"
for svc in "${SERVICES[@]}"; do
  IFS='|' read -r name image port <<< "$svc"
  deploy_app "$name" "$image" "$port" internal
done

log "Desplegando el API Gateway con ingreso externo"
deploy_app ca-gateway gateway 80 external
GATEWAY_URL="https://$(az containerapp show -g "$RG_APP" -n ca-gateway --query properties.configuration.ingress.fqdn -o tsv)"

# SAS de escritura para que GitHub Actions suba los archivos (válido 6 meses)
EXPIRY="$(date -u -d '+180 days' '+%Y-%m-%dT%H:%MZ')"
sas() {
  local key
  key="$(az storage account keys list -g "$RG_APP" -n "$1" --query "[0].value" -o tsv)"
  az storage container generate-sas --account-name "$1" --account-key "$key" -n '$web' \
    --permissions acdlrw --expiry "$EXPIRY" --https-only -o tsv
}
WEB_SAS="$(sas "$ST_WEB")"
DRIVER_SAS="$(sas "$ST_DRIVER")"

cat <<EOF

=====================================================================
 Infraestructura lista
=====================================================================
 API Gateway:        $GATEWAY_URL   (prueba: $GATEWAY_URL/health)
 Frontend clientes:  $WEB_URL
 Frontend repartid.: $DRIVER_URL

 Configure en GitHub (Settings > Secrets and variables > Actions):
   Variable GATEWAY_URL            = $GATEWAY_URL
   Variable STORAGE_ACCOUNT_WEB    = $ST_WEB
   Variable STORAGE_ACCOUNT_DRIVER = $ST_DRIVER
   Variable STRIPE_PUBLISHABLE_KEY = pk_test_... (opcional)
   Secreto  AZURE_STORAGE_SAS_WEB    = (ver abajo)
   Secreto  AZURE_STORAGE_SAS_DRIVER = (ver abajo)
 Luego ejecute el workflow "Frontends (Azure Storage)".

 Webhook de Stripe (modo prueba): $GATEWAY_URL/payment/api/payment/webhook

 Tokens SAS (vencen el $EXPIRY; no los comparta):
   AZURE_STORAGE_SAS_WEB    = $WEB_SAS
   AZURE_STORAGE_SAS_DRIVER = $DRIVER_SAS
=====================================================================
EOF
