#!/usr/bin/env bash
# Paso 4: Log Analytics, entorno de Container Apps en la VNet, identidad administrada,
# Static Web Apps y las 6 Container Apps (5 microservicios + gateway).
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

# ------------------------------------------------------- Static Web Apps
log "Creando Static Web Apps (plan Free) para los dos frontends"
for swa in "$SWA_WEB" "$SWA_DRIVER"; do
  az staticwebapp show -g "$RG_APP" -n "$swa" >/dev/null 2>&1 || \
    az staticwebapp create -g "$RG_APP" -n "$swa" -l "$SWA_LOCATION" --sku Free --tags "${TAGS[@]}" -o none
  ok "$swa"
done
WEB_HOST="$(az staticwebapp show -g "$RG_APP" -n "$SWA_WEB" --query defaultHostname -o tsv)"
DRIVER_HOST="$(az staticwebapp show -g "$RG_APP" -n "$SWA_DRIVER" --query defaultHostname -o tsv)"
CORS_ORIGIN="https://$WEB_HOST,https://$DRIVER_HOST,http://localhost:3000"

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

WEB_TOKEN="$(az staticwebapp secrets list -g "$RG_APP" -n "$SWA_WEB" --query properties.apiKey -o tsv)"
DRIVER_TOKEN="$(az staticwebapp secrets list -g "$RG_APP" -n "$SWA_DRIVER" --query properties.apiKey -o tsv)"

cat <<EOF

=====================================================================
 Infraestructura lista
=====================================================================
 API Gateway:        $GATEWAY_URL   (prueba: $GATEWAY_URL/health)
 Frontend clientes:  https://$WEB_HOST
 Frontend repartid.: https://$DRIVER_HOST

 Configure en GitHub (Settings > Secrets and variables > Actions):
   Variable GATEWAY_URL            = $GATEWAY_URL
   Variable STRIPE_PUBLISHABLE_KEY = pk_test_... (opcional)
   Secreto  AZURE_SWA_TOKEN_WEB    = (ver abajo)
   Secreto  AZURE_SWA_TOKEN_DRIVER = (ver abajo)
 Luego ejecute el workflow "Frontends (Static Web Apps)".

 Webhook de Stripe (modo prueba): $GATEWAY_URL/payment/api/payment/webhook

 Tokens de despliegue (no los comparta):
   AZURE_SWA_TOKEN_WEB    = $WEB_TOKEN
   AZURE_SWA_TOKEN_DRIVER = $DRIVER_TOKEN
=====================================================================
EOF
