#!/bin/bash

set -e

# BuildKit 활성화로 캐시 기반 빌드 가속
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

# 색상 출력
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 스크립트 디렉토리
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 환경 변수
NGINX_CONF="${SCRIPT_DIR}/nginx/default.prod.conf"
HEALTH_CHECK_URL="http://localhost:5400/api/health"
HEALTH_CHECK_TIMEOUT=60
HEALTH_CHECK_INTERVAL=5

# 자동 정리 옵션 (환경 변수로 제어 가능)
# AUTO_CLEANUP=true: 즉시 정리 (기본값)
# AUTO_CLEANUP=false: 수동 정리
# AUTO_CLEANUP=<숫자>: N분 후 자동 정리
AUTO_CLEANUP="${AUTO_CLEANUP:-true}"

# 현재 활성 환경 확인
get_active_environment() {
    if docker ps --format '{{.Names}}' | grep -q "backend-blue" && \
       docker ps --format '{{.Names}}' | grep -q "backend-green"; then
        # 둘 다 실행 중이면 Nginx 설정 확인 (primary 서버가 활성 환경)
        # backup이 아닌 첫 번째 server 라인이 활성 환경
        local primary_line=$(grep -E "^\s*server backend-(blue|green):5500" "$NGINX_CONF" | grep -v "backup" | head -1)
        if echo "$primary_line" | grep -q "backend-blue"; then
            echo "blue"
        elif echo "$primary_line" | grep -q "backend-green"; then
            echo "green"
        else
            # 기본값: green
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

# 헬스체크 수행
health_check() {
    local port=$1
    local service=$2
    local max_attempts=$((HEALTH_CHECK_TIMEOUT / HEALTH_CHECK_INTERVAL))
    local attempt=0

    echo -e "${YELLOW}${service} 헬스체크 시작... (포트: ${port})${NC}"
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -f -s "http://localhost:${port}/api/health" > /dev/null 2>&1; then
            echo -e "${GREEN}${service} 헬스체크 성공!${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
        echo -e "${YELLOW}헬스체크 시도 ${attempt}/${max_attempts}...${NC}"
        sleep $HEALTH_CHECK_INTERVAL
    done

    echo -e "${RED}${service} 헬스체크 실패!${NC}"
    return 1
}

# Nginx 설정 업데이트
update_nginx_config() {
    local active_env=$1
    local new_env=$2
    
    echo -e "${YELLOW}Nginx 설정 업데이트 중... (${new_env} 환경으로 전환)${NC}"
    
    if [ "$new_env" = "blue" ]; then
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

# 이전 환경 정리
cleanup_old_environment() {
    local old_env=$1
    
    echo -e "${YELLOW}이전 ${old_env} 환경 정리 중...${NC}"
    
    cd "$SCRIPT_DIR"
    if [ "$old_env" = "blue" ]; then
        docker-compose -f docker-compose.blue.yml down 2>/dev/null || true
    else
        docker-compose -f docker-compose.green.yml down 2>/dev/null || true
    fi
}

# 메인 배포 로직
main() {
    echo -e "${GREEN}=== 블루-그린 배포 시작 ===${NC}"
    
    # 프로덕션 네트워크 확인 및 생성
    if ! docker network inspect prod-network > /dev/null 2>&1; then
        echo -e "${YELLOW}프로덕션 네트워크 생성 중...${NC}"
        docker network create prod-network
    else
        echo -e "${GREEN}프로덕션 네트워크 확인됨${NC}"
    fi
    
    # 현재 활성 환경 확인
    current_env=$(get_active_environment)
    echo -e "${YELLOW}현재 활성 환경: ${current_env}${NC}"
    
    # 배포할 새 환경 결정
    if [ "$current_env" = "blue" ] || [ "$current_env" = "none" ]; then
        new_env="green"
        new_compose_file="docker-compose.green.yml"
        new_port="5502"
        old_env="blue"
    else
        new_env="blue"
        new_compose_file="docker-compose.blue.yml"
        new_port="5501"
        old_env="green"
    fi
    
    echo -e "${GREEN}새 버전을 ${new_env} 환경에 배포합니다.${NC}"
    
    # 작업 디렉토리 이동
    cd "$SCRIPT_DIR"
    
    # 프론트엔드 재빌드 옵션 (환경 변수로 제어, 기본값: true - 항상 재빌드)
    FRONTEND_REBUILD="${FRONTEND_REBUILD:-true}"
    
    # Nginx가 없으면 먼저 시작
    if ! docker ps --format '{{.Names}}' | grep -q "nginx-prod"; then
        echo -e "${YELLOW}Nginx 컨테이너 시작 중...${NC}"
        docker-compose -f docker-compose.prod.yml up -d --build
        sleep 5
    fi
    
    # 프론트엔드 재빌드 (기본적으로 항상 재빌드)
    if [ "$FRONTEND_REBUILD" = "true" ]; then
        echo -e "${YELLOW}프론트엔드 재빌드 중...${NC}"
        docker-compose -f docker-compose.prod.yml build nginx
        docker-compose -f docker-compose.prod.yml up -d nginx
        sleep 5
        echo -e "${GREEN}프론트엔드 재빌드 완료${NC}"
    fi
    
    # 새 환경 배포 (기존 컨테이너 제거 후 재빌드)
    echo -e "${YELLOW}${new_env} 환경 컨테이너 중지 중...${NC}"
    docker-compose -f "$new_compose_file" down 2>/dev/null || true
    
    echo -e "${YELLOW}${new_env} 환경 빌드 및 시작 중...${NC}"
    docker-compose -f "$new_compose_file" up -d --build
    
    # Nginx가 제거되었는지 확인하고 재시작
    if ! docker ps --format '{{.Names}}' | grep -q "nginx-prod"; then
        echo -e "${YELLOW}Nginx 컨테이너 재시작 중...${NC}"
        docker-compose -f docker-compose.prod.yml up -d
        sleep 5
    fi
    
    # 컨테이너 시작 대기
    echo -e "${YELLOW}컨테이너 시작 대기 중...${NC}"
    sleep 10
    
    # 헬스체크
    if ! health_check "$new_port" "${new_env}"; then
        echo -e "${RED}배포 실패: ${new_env} 환경 헬스체크 실패${NC}"
        echo -e "${YELLOW}롤백: 이전 환경 유지${NC}"
        docker-compose -f "$new_compose_file" down
        exit 1
    fi
    
    # Nginx 설정 업데이트 및 트래픽 전환
    if [ "$current_env" != "none" ]; then
        echo -e "${YELLOW}트래픽을 ${new_env} 환경으로 전환 중...${NC}"
        update_nginx_config "$current_env" "$new_env"
        sleep 3
    else
        # 최초 배포 시 Nginx 설정 업데이트
        update_nginx_config "none" "$new_env"
        sleep 3
    fi
    
    # Nginx가 실행 중인지 확인
    if ! docker ps --format '{{.Names}}' | grep -q "nginx-prod"; then
        echo -e "${RED}오류: Nginx 컨테이너가 실행되지 않습니다!${NC}"
        echo -e "${YELLOW}Nginx 재시작 중...${NC}"
        docker-compose -f docker-compose.prod.yml up -d
        sleep 10
    fi
    
    # 최종 헬스체크 (Nginx를 통한)
    echo -e "${YELLOW}최종 헬스체크 (Nginx를 통한)...${NC}"
    sleep 3
    
    local health_check_success=false
    local health_check_attempt=0
    local max_health_attempts=6
    while [ $health_check_attempt -lt $max_health_attempts ]; do
        if curl -f -s "$HEALTH_CHECK_URL" > /dev/null 2>&1; then
            echo -e "${GREEN}Nginx를 통한 헬스체크 성공!${NC}"
            health_check_success=true
            break
        fi
        health_check_attempt=$((health_check_attempt + 1))
        echo -e "${YELLOW}헬스체크 시도 ${health_check_attempt}/${max_health_attempts}...${NC}"
        sleep 3
    done
    
    if [ "$health_check_success" = "false" ]; then
        echo -e "${RED}경고: Nginx를 통한 헬스체크 실패${NC}"
        echo -e "${YELLOW}새 ${new_env} 환경은 포트 ${new_port}에서 정상 동작 중입니다.${NC}"
        echo -e "${YELLOW}직접 확인: curl http://localhost:${new_port}/api/health${NC}"
        echo -e "${YELLOW}이전 ${old_env} 환경은 롤백을 위해 유지됩니다.${NC}"
    fi
    
    # 이전 환경 정리 로직 (헬스체크 성공 시에만 정리)
    if [ "$current_env" != "none" ]; then
        if [ "$AUTO_CLEANUP" = "true" ]; then
            if [ "$health_check_success" = "true" ]; then
                # 헬스체크 성공 후 정리
                echo -e "${YELLOW}헬스체크 성공! 이전 ${old_env} 환경 정리 중...${NC}"
                cleanup_old_environment "$old_env"
            else
                echo -e "${YELLOW}헬스체크 실패로 인해 이전 ${old_env} 환경은 유지됩니다.${NC}"
                echo -e "${YELLOW}수동으로 정리하려면: docker-compose -f docker-compose.${old_env}.yml down${NC}"
            fi
        elif [ "$AUTO_CLEANUP" = "false" ]; then
            # 수동 정리
            read -p "이전 ${old_env} 환경을 정리하시겠습니까? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cleanup_old_environment "$old_env"
            else
                echo -e "${YELLOW}이전 ${old_env} 환경은 백업으로 유지됩니다.${NC}"
                echo -e "${YELLOW}나중에 정리하려면: docker-compose -f docker-compose.${old_env}.yml down${NC}"
            fi
        elif [[ "$AUTO_CLEANUP" =~ ^[0-9]+$ ]]; then
            # N분 후 자동 정리 (롤백 기간 확보)
            local cleanup_minutes=$AUTO_CLEANUP
            echo -e "${GREEN}배포 성공! ${cleanup_minutes}분 후 이전 ${old_env} 환경을 자동으로 정리합니다.${NC}"
            echo -e "${YELLOW}롤백이 필요하면 즉시 실행하세요: ./rollback.sh${NC}"
            (
                sleep $((cleanup_minutes * 60))
                if [ "$(get_active_environment)" = "$new_env" ]; then
                    echo -e "${YELLOW}[자동 정리] 이전 ${old_env} 환경 정리 중...${NC}"
                    cleanup_old_environment "$old_env"
                    echo -e "${GREEN}[자동 정리] 완료${NC}"
                else
                    echo -e "${YELLOW}[자동 정리] 환경이 변경되었으므로 정리 취소${NC}"
                fi
            ) &
            echo -e "${GREEN}자동 정리 프로세스가 백그라운드에서 실행 중입니다. (PID: $!)${NC}"
        else
            # 기본값: 수동 정리
            read -p "이전 ${old_env} 환경을 정리하시겠습니까? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cleanup_old_environment "$old_env"
            else
                echo -e "${YELLOW}이전 ${old_env} 환경은 백업으로 유지됩니다.${NC}"
                echo -e "${YELLOW}나중에 정리하려면: docker-compose -f docker-compose.${old_env}.yml down${NC}"
            fi
        fi
    fi
    
    echo -e "${GREEN}=== 배포 완료: ${new_env} 환경 활성화 ===${NC}"
}

main
