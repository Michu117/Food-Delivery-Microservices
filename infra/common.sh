#!/usr/bin/env bash
# Funciones y nombres compartidos por todos los scripts. No se ejecuta directamente.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$SCRIPT_DIR/config.env"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    ⚠ %s\033[0m\n' "$*"; }

if ! az account show >/dev/null 2>&1; then
  echo "No hay sesión de Azure. Ejecute 'az login' (en Cloud Shell ya está iniciada)." >&2
  exit 1
fi

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
# Sufijo estable para nombres que deben ser únicos en todo Azure
SUFFIX="$(printf '%s' "$SUBSCRIPTION_ID" | tr -d '-' | cut -c1-6)"

TAGS=("proyecto=$TAG_PROYECTO" "entorno=$TAG_ENTORNO" "owner=$TAG_OWNER")

# Grupos de recursos
RG_NET="rg-$PREFIX-net"
RG_APP="rg-$PREFIX-app"
RG_DATA="rg-$PREFIX-data"

# Red
VNET="vnet-$PREFIX-dev"
SNET_ACA="snet-aca"
SNET_DATA="snet-data"
NSG_ACA="nsg-aca"
NSG_DATA="nsg-data"
RT_ACA="rt-aca"
RT_DATA="rt-data"

# Datos y secretos
COSMOS="cosmos-$PREFIX-$SUFFIX"
COSMOS_DB="skydish"
KV="kv-$PREFIX-$SUFFIX"

# Aplicaciones
LOG="log-$PREFIX"
CAE="cae-$PREFIX"
IDENTITY="id-$PREFIX-apps"
# Frontends: sitios web estáticos en Storage (Static Web Apps no está en las regiones permitidas)
ST_WEB="st${PREFIX}web$SUFFIX"
ST_DRIVER="st${PREFIX}drv$SUFFIX"

# Microservicios: nombre|imagen|puerto
SERVICES=(
  "ca-auth|auth|5001"
  "ca-restaurant|restaurant|5002"
  "ca-delivery|delivery|5003"
  "ca-payment|payment|5004"
  "ca-order|order|5005"
)

snet_id() { az network vnet subnet show -g "$RG_NET" --vnet-name "$VNET" -n "$1" --query id -o tsv; }

# Reintenta un comando (útil mientras se propagan los permisos RBAC)
retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge 10 ]; then return 1; fi
    warn "Reintentando en 15 s (permisos en propagación)..."
    sleep 15
  done
}
