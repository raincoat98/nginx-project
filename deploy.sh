#!/bin/bash


# 기존 컨테이너 중지 및 삭제
docker-compose -f docker-compose.prod.yml down 

# 기존 네트워크 삭제
docker network rm prod-network 2>/dev/null || true

# 새로운 네트워크 생성
docker network create prod-network

# 컨테이너 재시작
docker-compose -f docker-compose.prod.yml up -d --build