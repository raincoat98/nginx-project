# ✅ 공통 base
FROM node:20-slim AS base
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .

# ✅ 개발용
FROM base AS development
CMD ["npm", "run", "start:dev"]

# ✅ 빌드용
FROM base AS build
RUN npm run build

# ✅ 배포용
FROM node:20-slim AS production
WORKDIR /app
COPY --from=build /app/dist ./dist
COPY --from=base /app/node_modules ./node_modules
CMD ["node", "dist/main"]