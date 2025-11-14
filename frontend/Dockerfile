# ✅ 공통 base
FROM node:20-slim AS base
WORKDIR /app

# 의존성 캐시 단계
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit

# 앱 소스 복사
COPY . .

# ✅ 개발용
FROM base AS development
ENV VITE_PORT=5401
CMD sh -c "npm run dev -- --host --port ${VITE_PORT:-5401}"

# ✅ 빌드용
FROM base AS build
ENV NODE_ENV=production
# .env.production 파일이 있으면 자동으로 로드됨
RUN npm run build

# ✅ 배포용 - Nginx로 정적 파일 서빙
FROM nginx:alpine AS production
COPY --from=build /app/dist /usr/share/nginx/html