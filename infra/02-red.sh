#!/usr/bin/env bash
# Paso 2: VNet, subredes, NSG y tablas de ruteo (todo sin costo).
source "$(dirname "$0")/common.sh"

# ---------------------------------------------------------------- NSG
log "Creando NSG"
az network nsg create -g "$RG_NET" -n "$NSG_ACA" -l "$LOCATION" --tags "${TAGS[@]}" -o none
az network nsg create -g "$RG_NET" -n "$NSG_DATA" -l "$LOCATION" --tags "${TAGS[@]}" -o none

rule() { # nsg nombre prioridad dirección acción protocolo origen destino "puertos"
  local ports
  read -ra ports <<< "$9"   # "443 10255" -> dos puertos (sin expandir '*')
  az network nsg rule create -g "$RG_NET" --nsg-name "$1" -n "$2" --priority "$3" \
    --direction "$4" --access "$5" --protocol "$6" \
    --source-address-prefixes "$7" --source-port-ranges '*' \
    --destination-address-prefixes "$8" --destination-port-ranges "${ports[@]}" -o none
}

# nsg-aca: dependencias documentadas para entornos con perfiles de carga de trabajo
rule "$NSG_ACA" Allow-LB-Probes        100 Inbound  Allow Tcp AzureLoadBalancer "$SNET_ACA_CIDR" 30000-32767
rule "$NSG_ACA" Allow-MCR              100 Outbound Allow Tcp "$SNET_ACA_CIDR" MicrosoftContainerRegistry 443
rule "$NSG_ACA" Allow-AFD-FirstParty   110 Outbound Allow Tcp "$SNET_ACA_CIDR" AzureFrontDoor.FirstParty 443
rule "$NSG_ACA" Allow-Intra-Subnet     120 Outbound Allow '*' "$SNET_ACA_CIDR" "$SNET_ACA_CIDR" '*'
rule "$NSG_ACA" Allow-EntraID          130 Outbound Allow Tcp "$SNET_ACA_CIDR" AzureActiveDirectory 443
rule "$NSG_ACA" Allow-AzureMonitor     140 Outbound Allow Tcp "$SNET_ACA_CIDR" AzureMonitor 443
rule "$NSG_ACA" Allow-CosmosDB         150 Outbound Allow Tcp "$SNET_ACA_CIDR" AzureCosmosDB "443 10255"
rule "$NSG_ACA" Allow-KeyVault         160 Outbound Allow Tcp "$SNET_ACA_CIDR" AzureKeyVault 443
rule "$NSG_ACA" Allow-Internet-HTTPS   170 Outbound Allow Tcp "$SNET_ACA_CIDR" Internet 443
if [ "$STRICT_EGRESS" = "true" ]; then
  rule "$NSG_ACA" Deny-All-Outbound   4000 Outbound Deny '*' '*' '*' '*'
fi
ok "$NSG_ACA"

# nsg-data: solo acepta tráfico desde la subred de aplicaciones
rule "$NSG_DATA" Allow-From-ACA        100 Inbound  Allow Tcp "$SNET_ACA_CIDR" "$SNET_DATA_CIDR" "443 10255"
rule "$NSG_DATA" Deny-VNet-Inbound    4000 Inbound  Deny '*' VirtualNetwork "$SNET_DATA_CIDR" '*'
rule "$NSG_DATA" Deny-Internet-Out    4000 Outbound Deny '*' "$SNET_DATA_CIDR" Internet '*'
ok "$NSG_DATA"

# ------------------------------------------------------- Tablas de ruteo
log "Creando tablas de ruteo"
az network route-table create -g "$RG_NET" -n "$RT_ACA" -l "$LOCATION" --tags "${TAGS[@]}" -o none
az network route-table route create -g "$RG_NET" --route-table-name "$RT_ACA" -n default-internet \
  --address-prefix 0.0.0.0/0 --next-hop-type Internet -o none
ok "$RT_ACA (0.0.0.0/0 -> Internet; en producción: VirtualAppliance 10.20.3.4)"

az network route-table create -g "$RG_NET" -n "$RT_DATA" -l "$LOCATION" --tags "${TAGS[@]}" -o none
az network route-table route create -g "$RG_NET" --route-table-name "$RT_DATA" -n block-internet \
  --address-prefix 0.0.0.0/0 --next-hop-type None -o none
ok "$RT_DATA (0.0.0.0/0 -> None)"

# ------------------------------------------------------- VNet y subredes
log "Creando VNet y subredes"
az network vnet create -g "$RG_NET" -n "$VNET" -l "$LOCATION" \
  --address-prefixes "$VNET_CIDR" --tags "${TAGS[@]}" -o none

az network vnet subnet create -g "$RG_NET" --vnet-name "$VNET" -n "$SNET_ACA" \
  --address-prefixes "$SNET_ACA_CIDR" \
  --delegations Microsoft.App/environments \
  --service-endpoints Microsoft.AzureCosmosDB Microsoft.KeyVault \
  --network-security-group "$NSG_ACA" --route-table "$RT_ACA" -o none
ok "$SNET_ACA $SNET_ACA_CIDR (delegada a Microsoft.App/environments)"

az network vnet subnet create -g "$RG_NET" --vnet-name "$VNET" -n "$SNET_DATA" \
  --address-prefixes "$SNET_DATA_CIDR" \
  --network-security-group "$NSG_DATA" --route-table "$RT_DATA" -o none
ok "$SNET_DATA $SNET_DATA_CIDR"

log "Listo. Siguiente paso: ./03-datos-y-secretos.sh"
