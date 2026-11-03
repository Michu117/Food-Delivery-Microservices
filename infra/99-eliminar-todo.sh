#!/usr/bin/env bash
# Elimina TODOS los recursos de SkyDish para dejar de consumir créditos.
# Las asignaciones de Azure Policy y los roles de cada grupo se borran con él.
source "$(dirname "$0")/common.sh"

read -r -p "Esto borrará $RG_APP, $RG_DATA y $RG_NET. Escriba 'eliminar' para continuar: " answer
[ "$answer" = "eliminar" ] || { echo "Cancelado."; exit 0; }

for rg in "$RG_APP" "$RG_DATA"; do
  az group delete -n "$rg" --yes -o none && ok "$rg eliminado"
done
# La red se elimina al final, cuando el entorno de Container Apps ya liberó la subred
az group delete -n "$RG_NET" --yes -o none && ok "$RG_NET eliminado"

# Key Vault queda 7 días en "eliminación temporal"; se purga para liberar el nombre
az keyvault purge -n "$KV" -l "$LOCATION" -o none 2>/dev/null && ok "Key Vault purgado" || true
log "Listo. No quedan recursos de SkyDish en la suscripción."
