#!/usr/bin/env bash
# Paso 6 (IAM): grupos de seguridad de Entra ID con roles RBAC de mínimo privilegio.
# Los permisos se asignan a los GRUPOS; las personas solo se agregan o quitan de ellos.
#
# Configure los correos en config.env (sección "Grupos de acceso") y ejecute:
#   ./06-usuarios-y-grupos.sh
# Se puede ejecutar varias veces: no duplica grupos, roles ni miembros.
source "$(dirname "$0")/common.sh"

SUB_SCOPE="/subscriptions/$SUBSCRIPTION_ID"
rg_scope() { echo "$SUB_SCOPE/resourceGroups/$1"; }

# grupo|descripción|rol|ámbito|correos
GROUPS_DEF=(
  "grp-$PREFIX-admins|Administración completa de SkyDish|Owner|$(rg_scope "$RG_APP") $(rg_scope "$RG_NET") $(rg_scope "$RG_DATA")|$ADMINS_UPNS"
  "grp-$PREFIX-devs|Despliegue de aplicaciones|Contributor|$(rg_scope "$RG_APP")|$DEVS_UPNS"
  "grp-$PREFIX-red|Administración de la red virtual|Network Contributor|$(rg_scope "$RG_NET")|$RED_UPNS"
  "grp-$PREFIX-datos|Administración de la base de datos|Contributor|$(rg_scope "$RG_DATA")|$DATOS_UPNS"
  "grp-$PREFIX-lectura|Solo lectura (docente)|Reader|$SUB_SCOPE|$LECTURA_UPNS"
)

for def in "${GROUPS_DEF[@]}"; do
  IFS='|' read -r group desc role scopes members <<< "$def"
  log "$group  →  $role"

  # 1. Grupo de seguridad
  gid="$(az ad group list --display-name "$group" --query "[0].id" -o tsv)"
  if [ -z "$gid" ]; then
    gid="$(az ad group create --display-name "$group" --mail-nickname "$group" \
      --description "$desc" --query id -o tsv)"
    ok "Grupo creado"
  else
    ok "El grupo ya existe"
  fi

  # 2. Rol RBAC asignado al grupo (no a personas)
  for scope in $scopes; do
    retry az role assignment create --assignee-object-id "$gid" --assignee-principal-type Group \
      --role "$role" --scope "$scope" -o none
    ok "$role en ${scope##*/}"
  done

  # 3. Integrantes
  if [ -z "$members" ]; then
    warn "Sin integrantes configurados"
    continue
  fi
  for upn in $members; do
    uid="$(az ad user show --id "$upn" --query id -o tsv 2>/dev/null || true)"
    if [ -z "$uid" ]; then
      warn "$upn no existe en el directorio (revise el correo)"
      continue
    fi
    if [ "$(az ad group member check --group "$gid" --member-id "$uid" --query value -o tsv)" = "true" ]; then
      ok "$upn ya es integrante"
    else
      az ad group member add --group "$gid" --member-id "$uid" -o none && ok "$upn agregado"
    fi
  done
done

log "Resumen de asignaciones por grupo"
az role assignment list --all --query "[?principalType=='Group' && starts_with(principalName, 'grp-$PREFIX')].{grupo:principalName, rol:roleDefinitionName, ambito:scope}" -o table \
  | sed "s#$SUB_SCOPE/resourceGroups/##; s#$SUB_SCOPE#suscripción#"
