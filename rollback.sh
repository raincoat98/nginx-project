#!/bin/bash

set -e

# 스크립트 디렉토리
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 색상 출력
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Nginx 설정 파일
NGINX_CONF="${SCRIPT_DIR}/nginx/default.prod.conf"

# 현재 활성 환경 확인
get_active_environment() {
    if docker ps --format '{{.Names}}' | grep -q "backend-blue" && \
       docker ps --format '{{.Names}}' | grep -q "backend-green"; then
        if grep -q "server backend-blue:5500" "$NGINX_CONF" && \
           ! grep -q "#.*server backend-blue:5500" "$NGINX_CONF"; then
            echo "blue"
        else
            echo "green"
        fi
    elif docker ps --format '{{.Names}}' | grep -q "backend-blue"; then
        echo "blue"
    elif docker ps --format '{{.Names}}' | grep -q "backend-green"; then
        echo "green"
    else
        echo "none"
    fi
}

# Nginx 설정 업데이트
update_nginx_config() {
    local active_env=$1
    
    echo -e "${YELLOW}Nginx 설정 업데이트 중... (${active_env} 환경으로 롤백)${NC}"
    
    if [ "$active_env" = "blue" ]; then
        cat > "$NGINX_CONF" << 'EOF'
upstream backend_pool {
    server backend-blue:5500 max_fails=3 fail_timeout=30s;
    server backend-green:5500 max_fails=3 fail_timeout=30s backup;
}

server {
    listen 80;
    server_name localhost;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://backend_pool/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
        proxy_connect_timeout 5s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;
    }

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF
    else
        cat > "$NGINX_CONF" << 'EOF'
upstream backend_pool {
    server backend-green:5500 max_fails=3 fail_timeout=30s;
    server backend-blue:5500 max_fails=3 fail_timeout=30s backup;
}

server {
    listen 80;
    server_name localhost;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://backend_pool/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
        proxy_connect_timeout 5s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;
    }

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF
    fi
    
    # Nginx 설정 테스트 및 리로드
    echo -e "${YELLOW}Nginx 설정 검증 중...${NC}"
    if docker exec nginx-prod nginx -t 2>/dev/null; then
        echo -e "${GREEN}Nginx 설정 검증 성공${NC}"
        # 설정 리로드 시도
        if docker exec nginx-prod nginx -s reload 2>/dev/null; then
            echo -e "${GREEN}Nginx 설정 리로드 완료${NC}"
        else
            echo -e "${YELLOW}Nginx 리로드 실패, 컨테이너 재시작 중...${NC}"
            cd "$SCRIPT_DIR" && docker-compose -f docker-compose.prod.yml restart nginx
            sleep 3
        fi
    else
        echo -e "${RED}Nginx 설정 검증 실패, 컨테이너 재시작 중...${NC}"
        cd "$SCRIPT_DIR" && docker-compose -f docker-compose.prod.yml restart nginx
        sleep 5
    fi
}

# 메인 롤백 로직
main() {
    echo -e "${GREEN}=== 롤백 시작 ===${NC}"
    
    cd "$SCRIPT_DIR"
    
    # 현재 활성 환경 확인
    current_env=$(get_active_environment)
    echo -e "${YELLOW}현재 활성 환경: ${current_env}${NC}"
    
    if [ "$current_env" = "none" ]; then
        echo -e "${RED}롤백할 환경이 없습니다.${NC}"
        exit 1
    fi
    
    # 롤백할 환경 결정
    if [ "$current_env" = "blue" ]; then
        rollback_env="green"
    else
        rollback_env="blue"
    fi
    
    # 롤백 환경이 실행 중인지 확인
    if ! docker ps --format '{{.Names}}' | grep -q "backend-${rollback_env}"; then
        echo -e "${RED}롤백할 ${rollback_env} 환경이 실행되지 않습니다!${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}${rollback_env} 환경으로 롤백합니다...${NC}"
    
    # Nginx 설정 업데이트
    update_nginx_config "$rollback_env"
    
    sleep 3
    
    # 헬스체크
    if curl -f -s "http://localhost:5400/api/health" > /dev/null 2>&1; then
        echo -e "${GREEN}롤백 성공! ${rollback_env} 환경으로 전환되었습니다.${NC}"
    else
        echo -e "${YELLOW}롤백 완료되었지만 헬스체크에 실패했습니다. 수동으로 확인해주세요.${NC}"
    fi
    
    echo -e "${GREEN}=== 롤백 완료 ===${NC}"
}

main

