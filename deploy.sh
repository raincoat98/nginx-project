#!/bin/bash

# 포트 4500을 사용 중인 프로세스 확인 및 정리
echo "포트 4500을 사용 중인 프로세스 정리 중..."
lsof -ti:4500 | xargs kill -9 2>/dev/null || true

# 기존 컨테이너 중지 및 삭제
docker-compose -f docker-compose.prod.yml down 

# 기존 네트워크 삭제
docker network rm prod-network 2>/dev/null || true

# 새로운 네트워크 생성
docker network create prod-network

# 컨테이너 재시작
docker-compose -f docker-compose.prod.yml up -d --build