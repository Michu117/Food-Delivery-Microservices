# Despliegue de SkyDish en Azure for Students

Scripts de Azure CLI que crean la arquitectura de la propuesta del Grupo 4:
SaaS sobre PaaS, VNet `10.20.0.0/16` con `snet-aca` (/26) y `snet-data` (/27),
NSG, tablas de ruteo, Container Apps con escala a cero, Cosmos DB (free tier),
Key Vault, Static Web Apps (Free) y Azure Policy.

**Costo esperado: 0 a 5 USD al mes.** Todo escala a cero cuando no se usa.
Si quiere ver la creación recurso por recurso en el portal, siga
[`docs/guia-portal.md`](../docs/guia-portal.md).

| Script | Qué crea | Costo |
|---|---|---|
| `01-grupos-y-politicas.sh` | 3 grupos de recursos, Azure Policy, roles RBAC opcionales | 0 |
| `02-red.sh` | VNet, 2 subredes, 2 NSG, 2 tablas de ruteo | 0 |
| `03-datos-y-secretos.sh` | Cosmos DB para MongoDB (free tier), Key Vault y secretos | 0 (Key Vault, centavos) |
| `04-aplicaciones.sh` | Log Analytics, entorno ACA en la VNet, identidad, 2 Static Web Apps, 6 Container Apps | 0 dentro de la cuota gratuita |
| `05-actualizar-imagenes.sh` | Nueva revisión con la última imagen | 0 |
| `pausar.sh` / `reanudar.sh` | Detiene o inicia las 6 Container Apps | 0 |
| `99-eliminar-todo.sh` | Borra todo | — |

## Paso 0. Antes de empezar

1. Verifique sus regiones permitidas: **Portal → Policy → Assignments →
   "Allowed resource deployment regions" → Parameters**. Elija una y escríbala en
   `config.env` (`LOCATION`). Para `SWA_LOCATION` use `eastus2`, `centralus`,
   `westus2`, `westeurope` o `eastasia` (las únicas que admite Static Web Apps).
2. En el repositorio de GitHub, pestaña **Actions**, habilite los workflows.

## Paso 1. Publicar las imágenes (GitHub)

1. Actions → **Imágenes de contenedores (GHCR)** → *Run workflow*.
2. Al terminar, en su perfil de GitHub → **Packages** aparecen `skydish-auth`,
   `skydish-restaurant`, `skydish-order`, `skydish-payment`, `skydish-delivery` y
   `skydish-gateway`. Entre a cada uno → *Package settings* → **Change visibility → Public**.
   (Alternativa: dejarlos privados y llenar `GHCR_USER` y `GHCR_TOKEN` en `config.env`.)

## Paso 2. Crear la infraestructura (Azure Cloud Shell, Bash)

```bash
git clone https://github.com/Michu117/Food-Delivery-Microservices.git
cd Food-Delivery-Microservices && git checkout azure-deploy
cd infra
nano config.env            # revise LOCATION, SWA_LOCATION y GHCR_OWNER
chmod +x *.sh

./01-grupos-y-politicas.sh
./02-red.sh
# Claves externas opcionales (modo prueba). Las que omita quedan "no-configurado".
STRIPE_SECRET_KEY=sk_test_xxx ./03-datos-y-secretos.sh
./04-aplicaciones.sh
```

Al final, `04-aplicaciones.sh` imprime la URL del gateway, las URLs de los
frontends y los tokens de Static Web Apps.

## Paso 3. Publicar los frontends (GitHub)

En **Settings → Secrets and variables → Actions**:

| Tipo | Nombre | Valor |
|---|---|---|
| Variable | `GATEWAY_URL` | URL del gateway impresa por el paso 4 |
| Variable | `STRIPE_PUBLISHABLE_KEY` | `pk_test_...` (opcional) |
| Secreto | `AZURE_SWA_TOKEN_WEB` | token impreso por el paso 4 |
| Secreto | `AZURE_SWA_TOKEN_DRIVER` | token impreso por el paso 4 |

Luego Actions → **Frontends (Static Web Apps)** → *Run workflow*.

## Paso 4. Stripe (opcional, modo prueba)

1. En el panel de Stripe (modo prueba) cree un webhook hacia
   `https://<gateway>/payment/api/payment/webhook`.
2. Guarde su secreto y reinicie el servicio de pagos:

```bash
source common.sh
az keyvault secret set --vault-name "$KV" -n stripe-webhook-secret --value "whsec_xxx" -o none
./05-actualizar-imagenes.sh ca-payment
```

## Verificación

```bash
GW=https://<gateway>
curl $GW/health                 # ok
curl $GW/restaurant/            # Restaurant Service Running...
curl $GW/payment/               # Payment Service Running
```

La primera petición a cada servicio tarda unos segundos porque arranca desde cero réplicas.

## Rutas del gateway

| Prefijo público | Servicio interno | Puerto |
|---|---|---|
| `/auth/...` | `ca-auth` | 5001 |
| `/restaurant/...` | `ca-restaurant` | 5002 |
| `/delivery/...` (incluye Socket.IO en `/delivery/socket.io`) | `ca-delivery` | 5003 |
| `/payment/...` (incluye webhook de Stripe) | `ca-payment` | 5004 |
| `/order/...` | `ca-order` | 5005 |

## Problemas frecuentes

- **El entorno de Container Apps no termina de crearse con `STRICT_EGRESS=true`.**
  Quite la regla de denegación y vuelva a ejecutar el paso 4:
  `az network nsg rule delete -g rg-skydish-net --nsg-name nsg-aca -n Deny-All-Outbound`
- **`RequestDisallowedByPolicy`.** La región elegida no está permitida por Azure for Students.
- **Error de free tier en Cosmos DB.** Solo se permite una cuenta gratuita por suscripción.
- **Una app no arranca (`ImagePullBackOff`).** El paquete de ghcr.io sigue privado.
- **Las imágenes subidas por restaurantes desaparecen.** Se guardan en el disco del
  contenedor, que se reinicia; en una fase posterior se moverían a Blob Storage.
- **Logs:** `az containerapp logs show -g rg-skydish-app -n ca-auth --follow`

## Pausar y reanudar

```bash
./pausar.sh     # detiene las 6 Container Apps (la API deja de responder)
./reanudar.sh   # las vuelve a iniciar; datos y configuración se conservan
```

También se puede hacer desde el portal: cada Container App → *Overview* → **Stop** / **Start**.
Mientras está en pausa, Cosmos DB, Key Vault, la red y las Static Web Apps se mantienen
(capas gratuitas o sin costo), así que reanudar tarda menos de un minuto.

## Dejar de gastar créditos

Con escala a cero no hay cargos de cómputo sin tráfico. Para borrar todo al terminar
el semestre: `./99-eliminar-todo.sh`.
