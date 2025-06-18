#!/bin/bash

# 기존 컨테이너와 네트워크 정리
docker-compose -f docker-compose.prod.yml down --remove-orphans

# 네트워크가 존재하는지 확인하고 생성
docker network inspect prod-network >/dev/null 2>&1 || docker network create prod-network

# 컨테이너 재시작
docker-compose -f docker-compose.prod.yml up -d --build