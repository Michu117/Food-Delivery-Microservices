#!/usr/bin/env bash
# Paso 1: grupos de recursos, Azure Policy y roles RBAC (todo sin costo).
source "$(dirname "$0")/common.sh"

log "Registrando proveedores de recursos (solo la primera vez tarda unos minutos)"
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.DocumentDB \
          Microsoft.KeyVault Microsoft.Network Microsoft.Storage Microsoft.ManagedIdentity \
          Microsoft.PolicyInsights Microsoft.CloudShell; do
  az provider register --namespace "$ns" --wait >/dev/null
done
ok "Proveedores registrados"

log "Creando grupos de recursos en $LOCATION"
for rg in "$RG_NET" "$RG_APP" "$RG_DATA"; do
  az group create -n "$rg" -l "$LOCATION" --tags "${TAGS[@]}" -o none
  ok "$rg"
done

policy_id() {
  az policy definition list --query "[?policyType=='BuiltIn' && displayName=='$1'].name | [0]" -o tsv
}

ALLOWED_LOCATIONS_ID="$(policy_id 'Allowed locations')"
NOT_ALLOWED_TYPES_ID="$(policy_id 'Not allowed resource types')"
INHERIT_TAG_ID="$(policy_id 'Inherit a tag from the resource group if missing')"

LOCATIONS_JSON="[\"$LOCATION\"]"

# Servicios costosos que se bloquean para proteger los créditos
BLOCKED_TYPES='[
  "Microsoft.Network/natGateways",
  "Microsoft.Network/azureFirewalls",
  "Microsoft.Network/applicationGateways",
  "Microsoft.Network/bastionHosts",
  "Microsoft.Compute/virtualMachines",
  "Microsoft.ContainerRegistry/registries"
]'

log "Asignando Azure Policy a cada grupo de recursos"
for rg in "$RG_NET" "$RG_APP" "$RG_DATA"; do
  scope="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$rg"

  az policy assignment create --name "solo-region-$rg" \
    --display-name "SkyDish: ubicaciones permitidas ($rg)" \
    --policy "$ALLOWED_LOCATIONS_ID" --scope "$scope" \
    --params "{\"listOfAllowedLocations\": {\"value\": $LOCATIONS_JSON}}" -o none

  az policy assignment create --name "bloquear-costosos-$rg" \
    --display-name "SkyDish: recursos costosos no permitidos ($rg)" \
    --policy "$NOT_ALLOWED_TYPES_ID" --scope "$scope" \
    --params "{\"listOfResourceTypesNotAllowed\": {\"value\": $BLOCKED_TYPES}}" -o none

  # Efecto Modify: copia la etiqueta "proyecto" del grupo a cada recurso.
  # Necesita una identidad administrada con el rol Tag Contributor.
  az policy assignment create --name "heredar-tag-$rg" \
    --display-name "SkyDish: heredar etiqueta proyecto ($rg)" \
    --policy "$INHERIT_TAG_ID" --scope "$scope" \
    --params '{"tagName": {"value": "proyecto"}}' \
    --mi-system-assigned --location "$LOCATION" \
    --identity-scope "$scope" --role "Tag Contributor" -o none

  ok "Políticas asignadas en $rg"
done

log "Asignando roles RBAC opcionales"
if [ -n "$TEACHER_UPN" ]; then
  az role assignment create --assignee "$TEACHER_UPN" --role "Reader" \
    --scope "/subscriptions/$SUBSCRIPTION_ID" -o none && ok "Reader: $TEACHER_UPN"
fi
for upn in $TEAM_UPNS; do
  az role assignment create --assignee "$upn" --role "Contributor" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_APP" -o none && ok "Contributor ($RG_APP): $upn"
done
if [ -n "$NETWORK_ADMIN_UPN" ]; then
  az role assignment create --assignee "$NETWORK_ADMIN_UPN" --role "Network Contributor" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG_NET" -o none && ok "Network Contributor: $NETWORK_ADMIN_UPN"
fi
[ -z "$TEACHER_UPN$TEAM_UPNS$NETWORK_ADMIN_UPN" ] && warn "Sin correos configurados: se omitieron los roles opcionales."

log "Listo. Siguiente paso: ./02-red.sh"
warn "Cree el presupuesto de 10 USD con alertas en el portal (Cost Management > Budgets), ver docs/guia-portal.md."
