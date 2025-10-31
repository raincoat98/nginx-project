# ✅ 공통 base
FROM node:20-slim AS base
WORKDIR /app

# 의존성 캐시 단계
COPY package*.json ./
# BuildKit 캐시를 활용하여 npm 캐시를 재사용하고, 재현 가능한 설치를 위해 npm ci 사용
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --omit=optional

# 앱 소스 복사
COPY . .

# ✅ 개발용
FROM base AS development
RUN apt-get update && apt-get install -y procps && rm -rf /var/lib/apt/lists/*
CMD ["npm", "run", "start:dev"]

# ✅ 빌드용
FROM base AS build
ENV NODE_ENV=production
RUN npm run build

# ✅ 배포용
FROM node:20-slim AS production
WORKDIR /app
ENV NODE_ENV=production

# 런타임에 필요한 산출물만 복사
COPY --from=build /app/dist ./dist
COPY --from=base /app/node_modules ./node_modules

EXPOSE 4500
CMD ["node", "dist/main"]