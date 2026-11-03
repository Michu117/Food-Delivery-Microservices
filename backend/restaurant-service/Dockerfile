# Imagen de producción para Azure Container Apps
FROM node:20-slim
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=5002

# Dependencias primero (aprovecha la caché de capas)
COPY package*.json ./
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force

COPY . .
# Carpeta para imágenes subidas (almacenamiento efímero del contenedor)
RUN mkdir -p uploads && chown node:node uploads
USER node
EXPOSE 5002
CMD ["node", "src/server.js"]
