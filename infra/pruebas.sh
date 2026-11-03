#!/usr/bin/env bash
# Pruebas de extremo a extremo de SkyDish en Azure.
# Crea datos de prueba (cliente, restaurante, repartidor, pedido y pago en modo
# prueba de Stripe) y verifica la configuración de red y seguridad.
#   ./pruebas.sh
source "$(dirname "$0")/common.sh"
set +e   # seguir aunque falle una prueba

GW="https://$(az containerapp show -g "$RG_APP" -n ca-gateway --query properties.configuration.ingress.fqdn -o tsv)"
WEB_URL="$(az storage account show -g "$RG_APP" -n "$ST_WEB" --query primaryEndpoints.web -o tsv)"
DRIVER_URL="$(az storage account show -g "$RG_APP" -n "$ST_DRIVER" --query primaryEndpoints.web -o tsv)"
ID="$(date +%s)"
PASS=0; FAIL=0; RESULTS=()

check() { # nombre condición(0=ok) detalle
  if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); RESULTS+=("✔|$1|$3"); printf '\033[1;32m  ✔ %s\033[0m %s\n' "$1" "$3"
  else FAIL=$((FAIL + 1)); RESULTS+=("✘|$1|$3"); printf '\033[1;31m  ✘ %s\033[0m %s\n' "$1" "$3"; fi
}

# Llama a la API: método ruta [json] [token]. Deja el cuerpo en $BODY y el código en $CODE.
api() {
  local args=(-s -m 120 -o /tmp/skydish-body -w "%{http_code}" -X "$1" "$GW$2")
  [ -n "${3:-}" ] && args+=(-H "Content-Type: application/json" -d "$3")
  [ -n "${4:-}" ] && args+=(-H "Authorization: Bearer $4")
  CODE="$(curl "${args[@]}")"
  BODY="$(cat /tmp/skydish-body 2>/dev/null)"
}

log "Despertando los servicios (la primera llamada puede tardar hasta 1 minuto)"
for p in health auth/health restaurant/ payment/ delivery/ order/api/orders; do
  curl -s -m 120 -o /dev/null "$GW/$p" &
done
wait
ok "Listo"

# ------------------------------------------------------------ Gateway y frontends
log "1. Gateway y frontends"
api GET /health;               check "Gateway /health"            "$([ "$CODE" = 200 ] && echo 0 || echo 1)" "HTTP $CODE"
c=$(curl -s -m 30 -o /dev/null -w "%{http_code}" "$WEB_URL");    check "Frontend clientes"  "$([ "$c" = 200 ] && echo 0 || echo 1)" "HTTP $c"
c=$(curl -s -m 30 -o /dev/null -w "%{http_code}" "$DRIVER_URL"); check "Frontend repartidores" "$([ "$c" = 200 ] && echo 0 || echo 1)" "HTTP $c"
c=$(curl -s -m 30 -o /dev/null -w "%{http_code}" "${WEB_URL%/}/customer/profile")
check "Rutas de React (SPA)" "$([ "$c" = 200 ] || [ "$c" = 404 ] && echo 0 || echo 1)" "HTTP $c (index.html como respaldo)"

# ------------------------------------------------------------ auth + Cosmos DB
log "2. Servicio auth (registro e inicio de sesión de cliente en Cosmos DB)"
EMAIL="cliente.prueba.$ID@skydish.test"
api POST /auth/api/auth/register/customer "{\"firstName\":\"Cliente\",\"lastName\":\"Prueba\",\"email\":\"$EMAIL\",\"phone\":\"099$ID\",\"password\":\"Prueba123!\",\"location\":\"Loja\"}"
check "Registrar cliente" "$([ "$CODE" = 201 ] && echo 0 || echo 1)" "HTTP $CODE"
api POST /auth/api/auth/login "{\"email\":\"$EMAIL\",\"password\":\"Prueba123!\"}"
CUSTOMER_TOKEN="$(echo "$BODY" | jq -r '.token // empty' 2>/dev/null)"
CUSTOMER_ID="$(echo "$BODY" | jq -r '.data.customer.id // .data.user.id // .user.id // .data.customer._id // empty' 2>/dev/null)"
check "Login de cliente (JWT)" "$([ -n "$CUSTOMER_TOKEN" ] && echo 0 || echo 1)" "HTTP $CODE"

# ------------------------------------------------------------ restaurant
log "3. Servicio restaurant"
# El registro exige foto de perfil (multipart/form-data); se usa una imagen PNG de 1x1
IMG=/tmp/skydish-prueba.png
echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" | base64 -d > "$IMG"
CODE="$(curl -s -m 120 -o /tmp/skydish-body -w "%{http_code}" -X POST "$GW/restaurant/api/restaurant/register" \
  -F "name=Restaurante Prueba $ID" -F "ownerName=Grupo 4" -F "location=Loja" -F "contactNumber=072$ID" \
  -F "email=rest.$ID@skydish.test" -F "password=Prueba123!" -F "profilePicture=@$IMG;type=image/png")"
check "Registrar restaurante (con foto)" "$([ "$CODE" = 201 ] && echo 0 || echo 1)" "HTTP $CODE"
api POST /restaurant/api/restaurant/login "{\"email\":\"rest.$ID@skydish.test\",\"password\":\"Prueba123!\"}"
REST_TOKEN="$(echo "$BODY" | jq -r '.token // empty' 2>/dev/null)"
check "Login de restaurante" "$([ -n "$REST_TOKEN" ] && echo 0 || echo 1)" "HTTP $CODE"
api GET /restaurant/api/restaurant/profile "" "$REST_TOKEN"
RESTAURANT_ID="$(echo "$BODY" | jq -r '._id // .restaurant._id // empty' 2>/dev/null)"
check "Perfil de restaurante" "$([ "$CODE" = 200 ] && echo 0 || echo 1)" "HTTP $CODE"
CODE="$(curl -s -m 120 -o /tmp/skydish-body -w "%{http_code}" -X POST "$GW/restaurant/api/food-items/create" \
  -H "Authorization: Bearer $REST_TOKEN" -F "name=Hamburguesa $ID" -F "description=Prueba" \
  -F "price=7.5" -F "category=Burgers" -F "image=@$IMG;type=image/png")"
FOOD_IMG="$(jq -r '.newFoodItem.image // empty' /tmp/skydish-body 2>/dev/null)"
check "Crear comida con imagen" "$([ "$CODE" = 201 ] && echo 0 || echo 1)" "HTTP $CODE"
c=$(curl -s -m 60 -o /dev/null -w "%{http_code}" "$GW/restaurant$FOOD_IMG")
check "Servir imagen subida" "$([ -n "$FOOD_IMG" ] && [ "$c" = 200 ] && echo 0 || echo 1)" "HTTP $c ${FOOD_IMG}"
api GET /restaurant/api/food-items/all
check "Catálogo público de comidas" "$([ "$CODE" = 200 ] && echo 0 || echo 1)" "HTTP $CODE"

# ------------------------------------------------------------ order (JWT compartido)
log "4. Servicio order (usa el JWT emitido por auth: secreto compartido en Key Vault)"
api GET /order/api/orders
check "Pedidos sin token → 401" "$([ "$CODE" = 401 ] && echo 0 || echo 1)" "HTTP $CODE"
api POST /order/api/orders "{\"customerId\":\"${CUSTOMER_ID:-cliente-$ID}\",\"restaurantId\":\"${RESTAURANT_ID:-rest-$ID}\",\"items\":[{\"foodId\":\"comida-$ID\",\"quantity\":2,\"price\":7.5}],\"deliveryAddress\":\"UNL, Loja\"}" "$CUSTOMER_TOKEN"
ORDER_ID="$(echo "$BODY" | jq -r '._id // .order._id // .data._id // empty' 2>/dev/null)"
check "Crear pedido con token de cliente" "$([ "$CODE" = 201 ] || [ "$CODE" = 200 ] && echo 0 || echo 1)" "HTTP $CODE"
api GET /order/api/orders "" "$CUSTOMER_TOKEN"
check "Listar pedidos con token" "$([ "$CODE" = 200 ] && echo 0 || echo 1)" "HTTP $CODE"

# ------------------------------------------------------------ delivery + Socket.IO
log "5. Servicio delivery (repartidores y Socket.IO por el gateway)"
api POST /delivery/api/auth/register "{\"name\":\"Repartidor Prueba\",\"email\":\"driver.$ID@skydish.test\",\"password\":\"Prueba123!\",\"phone\":\"098$ID\",\"vehicleType\":\"bike\",\"vehicleNumber\":\"PRB-$ID\"}"
check "Registrar repartidor" "$([ "$CODE" = 201 ] || [ "$CODE" = 200 ] && echo 0 || echo 1)" "HTTP $CODE"
api POST /delivery/api/auth/login "{\"email\":\"driver.$ID@skydish.test\",\"password\":\"Prueba123!\"}"
DRIVER_TOKEN="$(echo "$BODY" | jq -r '.token // empty' 2>/dev/null)"
check "Login de repartidor" "$([ -n "$DRIVER_TOKEN" ] && echo 0 || echo 1)" "HTTP $CODE"
SIO="$(curl -s -m 60 "$GW/delivery/socket.io/?EIO=4&transport=polling")"
check "Socket.IO (handshake)" "$([[ "$SIO" == 0\{* ]] && echo 0 || echo 1)" "${SIO:0:40}"

# ------------------------------------------------------------ payment + Stripe
log "6. Servicio payment (PaymentIntent en Stripe, modo prueba)"
api POST /payment/api/payment/process "{\"orderId\":\"${ORDER_ID:-pedido-$ID}\",\"userId\":\"${CUSTOMER_ID:-cliente-$ID}\",\"amount\":15,\"currency\":\"usd\",\"email\":\"$EMAIL\",\"phone\":\"+593990000000\"}"
SECRET="$(echo "$BODY" | jq -r '.clientSecret // empty' 2>/dev/null)"
check "Crear pago en Stripe" "$([[ "$SECRET" == pi_* ]] && echo 0 || echo 1)" "HTTP $CODE ${SECRET:+(PaymentIntent ${SECRET%%_secret*})}"
c=$(curl -s -m 60 -o /dev/null -w "%{http_code}" -X POST "$GW/payment/api/payment/webhook" -H "Content-Type: application/json" -d '{}')
check "Webhook rechaza firmas falsas" "$([ "$c" = 400 ] && echo 0 || echo 1)" "HTTP $c"

# ------------------------------------------------------------ red y seguridad
log "7. Red y seguridad"
INTERNAL_FQDN="$(az containerapp show -g "$RG_APP" -n ca-auth --query properties.configuration.ingress.fqdn -o tsv)"
c=$(curl -s -m 15 -o /dev/null -w "%{http_code}" "https://$INTERNAL_FQDN/health")
check "auth NO es accesible desde Internet" "$([ "$c" = 000 ] || [ "$c" = 403 ] || [ "$c" = 404 ] && echo 0 || echo 1)" "HTTP $c ($INTERNAL_FQDN)"
ext=$(az containerapp list -g "$RG_APP" --query "[?properties.configuration.ingress.external].name" -o tsv | tr '\n' ' ')
check "Solo ca-gateway tiene ingreso externo" "$([ "$(echo $ext)" = "ca-gateway" ] && echo 0 || echo 1)" "externas: $ext"
vnetf=$(az cosmosdb show -g "$RG_DATA" -n "$COSMOS" --query "isVirtualNetworkFilterEnabled" -o tsv)
rules=$(az cosmosdb show -g "$RG_DATA" -n "$COSMOS" --query "virtualNetworkRules[].id" -o tsv | grep -c "$SNET_ACA")
check "Cosmos DB solo acepta snet-aca" "$([ "$vnetf" = true ] && [ "$rules" -ge 1 ] && echo 0 || echo 1)" "filtro VNet=$vnetf, reglas snet-aca=$rules"
ver=$(az cosmosdb show -g "$RG_DATA" -n "$COSMOS" --query "apiProperties.serverVersion" -o tsv)
check "Cosmos DB versión ≥ 4.2" "$([ "$ver" != 3.6 ] && [ "$ver" != 3.2 ] && echo 0 || echo 1)" "versión $ver"
nh=$(az network route-table route show -g "$RG_NET" --route-table-name "$RT_DATA" -n block-internet --query nextHopType -o tsv)
check "rt-data: 0.0.0.0/0 → None" "$([ "$nh" = None ] && echo 0 || echo 1)" "$nh"
deny=$(az network nsg rule list -g "$RG_NET" --nsg-name "$NSG_ACA" --query "[?access=='Deny' && direction=='Outbound'] | length(@)" -o tsv)
check "nsg-aca deniega salida no listada" "$([ "${deny:-0}" -ge 1 ] && echo 0 || echo 1)" "reglas Deny de salida: $deny"
deleg=$(az network vnet subnet show -g "$RG_NET" --vnet-name "$VNET" -n "$SNET_ACA" --query "delegations[0].serviceName" -o tsv)
check "snet-aca delegada a Container Apps" "$([ "$deleg" = Microsoft.App/environments ] && echo 0 || echo 1)" "$deleg"
pol=$(az policy assignment list --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_APP" --query "length(@)" -o tsv)
check "Azure Policy asignadas en $RG_APP" "$([ "${pol:-0}" -ge 3 ] && echo 0 || echo 1)" "$pol asignaciones"

# ------------------------------------------------------------ resumen
echo
echo "====================================================================="
printf " Resultado: \033[1;32m%d correctas\033[0m, \033[1;31m%d fallidas\033[0m (de %d)\n" "$PASS" "$FAIL" $((PASS + FAIL))
echo "====================================================================="
for r in "${RESULTS[@]}"; do IFS='|' read -r s n d <<< "$r"; printf ' %s %-40s %s\n' "$s" "$n" "$d"; done
echo
[ "$FAIL" -gt 0 ] && echo " Copie las líneas con ✘ para revisarlas." || echo " Todo funciona correctamente."
rm -f /tmp/skydish-body /tmp/skydish-prueba.png
