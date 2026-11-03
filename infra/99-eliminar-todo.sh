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
# Grupos y usuarios de Entra ID no pertenecen a los grupos de recursos: se borran aparte
for role in admins devs red datos lectura; do
  gid="$(az ad group list --display-name "grp-$PREFIX-$role" --query "[0].id" -o tsv)"
  [ -n "$gid" ] && az ad group delete --group "$gid" && ok "Grupo grp-$PREFIX-$role eliminado"
done
DOMAIN="$(az ad signed-in-user show --query userPrincipalName -o tsv | cut -d@ -f2)"
for role in admins devs red datos lectura; do
  upn="usr-$PREFIX-$role@$DOMAIN"
  az ad user show --id "$upn" >/dev/null 2>&1 && az ad user delete --id "$upn" && ok "Usuario $upn eliminado"
done
rm -f "$HOME/skydish-usuarios-demo.txt"

log "Listo. No quedan recursos de SkyDish en la suscripción."
