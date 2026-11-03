# API Gateway de SkyDish: único punto de entrada público (ingreso externo en ACA)
FROM nginx:1.27-alpine

# Nombres internos de las Container Apps (ingreso interno). Se pueden cambiar con variables de entorno.
ENV AUTH_HOST=ca-auth \
    RESTAURANT_HOST=ca-restaurant \
    ORDER_HOST=ca-order \
    DELIVERY_HOST=ca-delivery \
    PAYMENT_HOST=ca-payment

# La imagen oficial procesa /etc/nginx/templates/*.template con envsubst al iniciar
COPY default.conf.template /etc/nginx/templates/default.conf.template
EXPOSE 80
