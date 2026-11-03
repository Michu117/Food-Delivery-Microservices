# Imagen de producción para Azure Container Apps
FROM node:20-slim
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=5003

# Dependencias primero (aprovecha la caché de capas)
COPY package*.json ./
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force

COPY . .

USER node
EXPOSE 5003
CMD ["node", "src/server.js"]
