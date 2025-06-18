# ✅ 공통 base
FROM node:20-slim AS base
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .

# ✅ 개발용
FROM base AS development
CMD ["npm", "run", "dev", "--", "--host", "--port", "4501"]

# ✅ 빌드용
FROM base AS build
RUN npm run build

# ✅ 배포용 - Nginx로 정적 파일 서빙
FROM nginx:alpine AS production
COPY --from=build /app/dist /usr/share/nginx/html