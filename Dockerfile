FROM node:22-bookworm-slim

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends curl wget ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json tsconfig.api.json ./
COPY src ./src

RUN npm run build:api

ENV NODE_ENV=production
ENV API_HOST=0.0.0.0
ENV API_PORT=3000

EXPOSE 3000

CMD ["node", "dist-api/server.js"]
