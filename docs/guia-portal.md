# Guía paso a paso en el portal de Azure

Esta guía crea **lo mismo que los scripts de `infra/`**, pero a mano en
[portal.azure.com](https://portal.azure.com). Sirve para entender cada recurso y
tomar capturas como evidencia. Puede combinar ambos métodos: por ejemplo, crear la
red en el portal (pasos 1 a 4) y lo demás con `03` y `04`.

> Valores usados: región `canadacentral` (debe estar entre las permitidas en su suscripción),
> etiquetas `proyecto=skydish`, `entorno=dev`, `owner=grupo4` en **todos** los recursos.

## 1. Presupuesto y grupos de recursos

1. **Cost Management → Budgets → + Add**: nombre `bud-skydish`, monto **10 USD**,
   mensual. Alertas al **50 %, 80 % y 100 %** con su correo.
   📸 Captura: presupuesto creado.
2. **Resource groups → + Create** (tres veces): `rg-skydish-net`, `rg-skydish-app`,
   `rg-skydish-data`, con las etiquetas.

## 2. Azure Policy (por cada grupo de recursos)

**Policy → Assignments → Assign policy**, ámbito = el grupo de recursos:

| Definición integrada | Parámetro |
|---|---|
| Allowed locations | su región |
| Not allowed resource types | NAT gateways, Azure firewalls, Application gateways, Bastion hosts, Virtual machines, Container registries |
| Inherit a tag from the resource group if missing | `proyecto` (en *Remediation* marque crear identidad administrada) |

📸 Captura: lista de asignaciones.

## 3. Grupos de seguridad de red (en `rg-skydish-net`)

**Network security groups → + Create**: `nsg-aca` y `nsg-data`. Luego agregue reglas
en *Inbound/Outbound security rules*:

**nsg-aca**

| Prio. | Dirección | Origen | Destino | Puerto | Acción |
|---|---|---|---|---|---|
| 100 | Entrada | Service Tag `AzureLoadBalancer` | 10.20.1.0/26 | 30000-32767 | Allow |
| 100 | Salida | 10.20.1.0/26 | `MicrosoftContainerRegistry` | 443 | Allow |
| 110 | Salida | 10.20.1.0/26 | `AzureFrontDoor.FirstParty` | 443 | Allow |
| 120 | Salida | 10.20.1.0/26 | 10.20.1.0/26 | * | Allow |
| 130 | Salida | 10.20.1.0/26 | `AzureActiveDirectory` | 443 | Allow |
| 140 | Salida | 10.20.1.0/26 | `AzureMonitor` | 443 | Allow |
| 150 | Salida | 10.20.1.0/26 | `AzureCosmosDB` | 443, 10255 | Allow |
| 160 | Salida | 10.20.1.0/26 | `AzureKeyVault` | 443 | Allow |
| 170 | Salida | 10.20.1.0/26 | `Internet` | 443 | Allow |
| 4000 | Salida | Any | Any | * | **Deny** |

**nsg-data**

| Prio. | Dirección | Origen | Destino | Puerto | Acción |
|---|---|---|---|---|---|
| 100 | Entrada | 10.20.1.0/26 | 10.20.2.0/27 | 443, 10255 | Allow |
| 4000 | Entrada | `VirtualNetwork` | 10.20.2.0/27 | * | **Deny** |
| 4000 | Salida | 10.20.2.0/27 | `Internet` | * | **Deny** |

📸 Captura: reglas de cada NSG.

## 4. Tablas de ruteo y VNet (en `rg-skydish-net`)

1. **Route tables → + Create**: `rt-aca` y `rt-data`.
   - `rt-aca` → *Routes* → `default-internet`: 0.0.0.0/0, next hop **Internet**.
   - `rt-data` → *Routes* → `block-internet`: 0.0.0.0/0, next hop **None**.
2. **Virtual networks → + Create**: `vnet-skydish-dev`, espacio **10.20.0.0/16**.
   Borre la subred por defecto y cree:
   - `snet-aca` **10.20.1.0/26**: *Subnet delegation* = `Microsoft.App/environments`;
     *Service endpoints* = `Microsoft.AzureCosmosDB` y `Microsoft.KeyVault`;
     NSG = `nsg-aca`; Route table = `rt-aca`.
   - `snet-data` **10.20.2.0/27**: NSG = `nsg-data`; Route table = `rt-data`.

📸 Captura: subredes de la VNet y las rutas de cada tabla.

## 5. Cosmos DB (en `rg-skydish-data`)

**Azure Cosmos DB → + Create → Azure Cosmos DB for MongoDB → Request unit (RU) based**:

- Nombre `cosmos-skydish-<sufijo>`, versión **4.2**, **Apply Free Tier Discount: Apply**.
- *Networking*: **Selected networks** → agregue `vnet-skydish-dev / snet-aca`.
- Luego *Data Explorer* → **New Database** `skydish`, *Provision throughput* = 1000 RU/s (manual).
- *Connection strings*: copie la cadena primaria y agregue `/skydish` antes del `?`.

## 6. Key Vault (en `rg-skydish-app`)

**Key vaults → + Create**: `kv-skydish-<sufijo>`, *Permission model* = **Azure role-based access control**.

1. *Access control (IAM)* → asígnese **Key Vault Secrets Officer**.
2. *Secrets* → cree: `mongo-uri`, `jwt-secret` (texto aleatorio largo), `stripe-secret-key`,
   `stripe-webhook-secret`, `twilio-account-sid`, `twilio-auth-token`,
   `twilio-phone-number`, `resend-api-key` (use `no-configurado` si no los tiene).

## 7. Identidad, logs y entorno de Container Apps (en `rg-skydish-app`)

1. **Managed Identities → + Create**: `id-skydish-apps`. En el Key Vault → *IAM* →
   asígnele **Key Vault Secrets User**.
2. **Log Analytics workspaces → + Create**: `log-skydish`. Luego *Usage and estimated costs →
   Daily cap* = **0,1 GB**.
3. **Container Apps Environments → + Create**: `cae-skydish`,
   *Environment type* = **Workload profiles**; *Networking* → *Use your own virtual network* = Sí,
   `vnet-skydish-dev / snet-aca`, *Virtual IP* = **External**; *Monitoring* = `log-skydish`.

📸 Captura: entorno con la VNet asociada.

## 8. Container Apps

Cree cinco apps con **Container Apps → + Create**, imagen
`ghcr.io/michu117/skydish-<servicio>:latest`, CPU **0,25** y memoria **0,5 Gi**,
*Ingress* = **Limited to Container Apps Environment** (interno),
*Scale* = mínimo **0**, máximo **1**, identidad `id-skydish-apps`:

| App | Imagen | Puerto destino |
|---|---|---|
| `ca-auth` | skydish-auth | 5001 |
| `ca-restaurant` | skydish-restaurant | 5002 |
| `ca-delivery` | skydish-delivery | 5003 |
| `ca-payment` | skydish-payment | 5004 |
| `ca-order` | skydish-order | 5005 |

En *Secrets* agregue referencias a Key Vault (`mongo-uri`, `jwt-secret` y, en `ca-payment`,
los de Stripe, Twilio y Resend). En *Environment variables*: `PORT`, `MONGO_URI` →
secreto `mongo-uri`, `JWT_SECRET` → secreto `jwt-secret`, `JWT_EXPIRES_IN=1d` y
`CORS_ORIGIN` = URLs de los sitios web estáticos (paso 9) separadas por coma.

Por último cree `ca-gateway` (imagen `skydish-gateway`, puerto **80**,
*Ingress* = **Accepting traffic from anywhere**, escala 0 a 1). Su URL es la única pública.

📸 Captura: lista de Container Apps mostrando que solo el gateway tiene URL pública.

## 9. Frontends en Azure Storage (en `rg-skydish-app`)

Static Web Apps no está disponible en las regiones permitidas por Azure for Students,
así que cada frontend se publica como sitio web estático de una cuenta de Storage.

1. **Storage accounts → + Create** (dos veces): `stskydishweb<sufijo>` y `stskydishdrv<sufijo>`,
   rendimiento **Standard**, redundancia **LRS**.
2. En cada una: *Data management → Static website* → **Enabled**, *Index document* =
   `index.html`, *Error document path* = `index.html`. Copie el *Primary endpoint* (URL del frontend).
3. *Data storage → Containers → $web → Shared access tokens*: permisos Read, Add, Create,
   Write, Delete y List, vencimiento en 6 meses → **Generate SAS token**. Guárdelo en GitHub
   como `AZURE_STORAGE_SAS_WEB` / `AZURE_STORAGE_SAS_DRIVER`, y el nombre de cada cuenta como
   variable `STORAGE_ACCOUNT_WEB` / `STORAGE_ACCOUNT_DRIVER`.

Siga el paso 3 de [`infra/README.md`](../infra/README.md).

## Evidencias sugeridas para el informe

1. Presupuesto con alertas.
2. Asignaciones de Azure Policy.
3. Subredes de la VNet con NSG, tabla de ruteo, delegación y Service Endpoints.
4. Reglas de `nsg-aca` y `nsg-data`; rutas de `rt-aca` y `rt-data`.
5. Cosmos DB con *Free Tier* y red restringida a `snet-aca`.
6. Container Apps: solo `ca-gateway` con ingreso externo.
7. Frontend funcionando y `https://<gateway>/health` respondiendo `ok`.
8. *Cost analysis* mostrando el consumo real.
