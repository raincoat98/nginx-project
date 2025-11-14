#!/bin/bash

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly NGINX_CONF="${SCRIPT_DIR}/nginx/default.prod.conf"
readonly PROD_COMPOSE="docker-compose.prod.yml"
readonly NETWORK_NAME="prod-network"

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Health check settings
readonly HEALTH_CHECK_TIMEOUT=60
readonly HEALTH_CHECK_INTERVAL=5
readonly MAX_HEALTH_ATTEMPTS=$((HEALTH_CHECK_TIMEOUT / HEALTH_CHECK_INTERVAL))

# Environment configuration functions
get_env_compose() {
    case "$1" in
        blue) echo "docker-compose.blue.yml" ;;
        green) echo "docker-compose.green.yml" ;;
        *) echo "" ;;
    esac
}

get_env_port() {
    case "$1" in
        blue) echo "5501" ;;
        green) echo "5502" ;;
        *) echo "" ;;
    esac
}

# Deployment options (can be overridden by environment variables)
AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
FRONTEND_REBUILD="${FRONTEND_REBUILD:-true}"

# ============================================================================
# Utility Functions
# ============================================================================

log() {
    local level=$1
    shift
    local color=$NC
    
    case $level in
        INFO) color=$GREEN ;;
        WARN) color=$YELLOW ;;
        ERROR) color=$RED ;;
    esac
    
    echo -e "${color}[$level] $*${NC}"
}

run_cmd() {
    local cmd=$1
    if ! eval "$cmd" 2>/dev/null; then
        log WARN "명령 실행 실패 (비중요): $cmd"
        return 1
    fi
    return 0
}

wait_for_container() {
    local container=$1
    local max_wait=${2:-10}
    local elapsed=0
    
    while [ $elapsed -lt $max_wait ]; do
        if docker ps --format '{{.Names}}' | grep -q "$container"; then
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    return 1
}

# ============================================================================
# Docker & Network Management
# ============================================================================

ensure_network() {
    if docker network inspect "$NETWORK_NAME" > /dev/null 2>&1; then
        log INFO "네트워크 '$NETWORK_NAME' 존재함"
    else
        log INFO "네트워크 '$NETWORK_NAME' 생성 중"
        docker network create "$NETWORK_NAME"
    fi
}

compose_cmd() {
    local file=$1
    shift
    cd "$SCRIPT_DIR" && docker-compose -f "$file" "$@"
}

# ============================================================================
# Environment Detection
# ============================================================================

get_active_environment() {
    local blue_running green_running
    blue_running=$(docker ps --format '{{.Names}}' | grep -c "backend-blue" || true)
    green_running=$(docker ps --format '{{.Names}}' | grep -c "backend-green" || true)
    
    if [ "$blue_running" -gt 0 ] && [ "$green_running" -gt 0 ]; then
        # Both running - check nginx config
        local primary_server
        primary_server=$(grep -E "^\s*server backend-(blue|green):5500" "$NGINX_CONF" | \
                        grep -v "backup" | head -1)
        
        if echo "$primary_server" | grep -q "backend-blue"; then
            echo "blue"
        else
            echo "green"
        fi
    elif [ "$blue_running" -gt 0 ]; then
        echo "blue"
    elif [ "$green_running" -gt 0 ]; then
        echo "green"
    else
        echo "none"
    fi
}

get_next_environment() {
    local current=$1
    if [ "$current" = "blue" ] || [ "$current" = "none" ]; then
        echo "green"
    else
        echo "blue"
    fi
}


# ============================================================================
# Health Check
# ============================================================================

health_check() {
    local port=$1
    local service=$2
    local attempt=0
    
    log INFO "$service 헬스체크 시작... (포트: $port)"
    
    while [ $attempt -lt $MAX_HEALTH_ATTEMPTS ]; do
        if curl -f -s "http://localhost:${port}/api/health" > /dev/null 2>&1; then
            log INFO "$service 헬스체크 성공!"
            return 0
        fi
        ((attempt++))
        log INFO "헬스체크 시도 ${attempt}/${MAX_HEALTH_ATTEMPTS}..."
        sleep $HEALTH_CHECK_INTERVAL
    done
    
    log ERROR "$service 헬스체크 실패!"
    return 1
}

health_check_nginx() {
    local url="http://localhost:5400/api/health"
    local max_attempts=6
    local attempt=0
    
    log INFO "Nginx를 통한 헬스체크 시작..."
    sleep 3
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -f -s "$url" > /dev/null 2>&1; then
            log INFO "Nginx를 통한 헬스체크 성공!"
            return 0
        fi
        ((attempt++))
        log INFO "Nginx 헬스체크 시도 ${attempt}/${max_attempts}..."
        sleep 3
    done
    
    log ERROR "Nginx를 통한 헬스체크 실패"
    return 1
}

# ============================================================================
# Nginx Configuration
# ============================================================================

generate_nginx_config() {
    local primary=$1
    local backup=$2
    
    cat << EOF
upstream backend_pool {
    server backend-${primary}:5500 max_fails=3 fail_timeout=30s;
    server backend-${backup}:5500 max_fails=3 fail_timeout=30s backup;
}

server {
    listen 80;
    server_name localhost;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://backend_pool/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        
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
}

update_nginx_config() {
    local new_env=$1
    local old_env=$2
    
    log INFO "Nginx 설정 업데이트 중... ($new_env 환경으로 전환)"
    
    generate_nginx_config "$new_env" "$old_env" > "$NGINX_CONF"
    
    if docker exec nginx-prod nginx -t 2>/dev/null; then
        log INFO "Nginx 설정 검증 성공"
        if docker exec nginx-prod nginx -s reload 2>/dev/null; then
            log INFO "Nginx 설정 리로드 완료"
        else
            log WARN "Nginx 리로드 실패, 컨테이너 재시작 중..."
            compose_cmd "$PROD_COMPOSE" restart nginx
            sleep 3
        fi
    else
        log ERROR "Nginx 설정 검증 실패, 컨테이너 재시작 중..."
        compose_cmd "$PROD_COMPOSE" restart nginx
        sleep 5
    fi
}

ensure_nginx_config() {
    if [ ! -f "$NGINX_CONF" ]; then
        log WARN "Nginx 설정 파일이 없어 기본값으로 생성 중..."
        generate_nginx_config "green" "blue" > "$NGINX_CONF"
    fi
}

ensure_nginx_running() {
    if ! docker ps --format '{{.Names}}' | grep -q "nginx-prod"; then
        log INFO "Nginx 컨테이너 시작 중..."
        compose_cmd "$PROD_COMPOSE" up -d
        wait_for_container "nginx-prod" 10
    fi
}

# ============================================================================
# Environment Management
# ============================================================================

cleanup_environment() {
    local env=$1
    local compose_file
    compose_file=$(get_env_compose "$env")
    
    log INFO "$env 환경 정리 중..."
    run_cmd "compose_cmd '$compose_file' down"
}

handle_dual_environments() {
    local current_env=$1
    
    if docker ps --format '{{.Names}}' | grep -q "backend-blue" && \
       docker ps --format '{{.Names}}' | grep -q "backend-green"; then
        local cleanup_env
        [ "$current_env" = "blue" ] && cleanup_env="green" || cleanup_env="blue"
        log WARN "두 환경이 모두 실행 중입니다. $cleanup_env 환경 정리 중..."
        cleanup_environment "$cleanup_env"
        sleep 2
    fi
}

deploy_new_environment() {
    local env=$1
    local compose_file
    compose_file=$(get_env_compose "$env")
    
    log INFO "기존 $env 컨테이너 중지 중..."
    run_cmd "compose_cmd '$compose_file' down"
    
    log INFO "$env 환경 빌드 및 시작 중..."
    compose_cmd "$compose_file" up -d --build
    
    ensure_nginx_running
    
    log INFO "컨테이너 시작 대기 중..."
    sleep 10
}

rebuild_frontend() {
    if [ "$FRONTEND_REBUILD" = "true" ]; then
        log INFO "프론트엔드 재빌드 중..."
        compose_cmd "$PROD_COMPOSE" build nginx
        compose_cmd "$PROD_COMPOSE" up -d nginx
        sleep 5
    fi
}

# ============================================================================
# Cleanup Strategy
# ============================================================================

handle_cleanup() {
    local old_env=$1
    local new_env=$2
    
    case "$AUTO_CLEANUP" in
        true)
            log INFO "자동 정리 활성화, $old_env 환경 제거 중..."
            cleanup_environment "$old_env"
            ;;
        false)
            read -p "$old_env 환경을 정리하시겠습니까? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cleanup_environment "$old_env"
            else
                log WARN "$old_env 환경은 백업으로 유지됩니다"
                log INFO "나중에 정리하려면: docker-compose -f $(get_env_compose "$old_env") down"
            fi
            ;;
        *)
            if [[ "$AUTO_CLEANUP" =~ ^[0-9]+$ ]]; then
                schedule_cleanup "$old_env" "$new_env" "$AUTO_CLEANUP"
            else
                log ERROR "잘못된 AUTO_CLEANUP 값: $AUTO_CLEANUP"
            fi
            ;;
    esac
}

schedule_cleanup() {
    local old_env=$1
    local new_env=$2
    local minutes=$3
    
    log INFO "$minutes분 후 자동 정리 예약됨"
    log WARN "롤백이 필요하면 실행하세요: ./rollback.sh"
    
    (
        sleep $((minutes * 60))
        if [ "$(get_active_environment)" = "$new_env" ]; then
            log INFO "[자동 정리] $old_env 환경 제거 중..."
            cleanup_environment "$old_env"
        else
            log WARN "[자동 정리] 환경이 변경되어 정리 취소됨"
        fi
    ) &
    
    log INFO "자동 정리 프로세스가 백그라운드에서 실행 중입니다. (PID: $!)"
}

# ============================================================================
# Main Deployment Flow
# ============================================================================

main() {
    log INFO "=== 블루-그린 배포 시작 ==="
    
    ensure_network
    
    local current_env
    current_env=$(get_active_environment)
    log INFO "현재 활성 환경: $current_env"
    
    handle_dual_environments "$current_env"
    
    current_env=$(get_active_environment)
    local old_env="${current_env:-none}"
    local new_env
    new_env=$(get_next_environment "${current_env:-none}")
    
    if [ -z "$new_env" ]; then
        log ERROR "새 환경을 결정할 수 없습니다"
        exit 1
    fi
    
    local new_port
    new_port=$(get_env_port "$new_env")
    
    if [ -z "$new_port" ]; then
        log ERROR "포트를 가져올 수 없습니다: $new_env"
        exit 1
    fi
    
    log INFO "$new_env 환경에 배포 중..."
    
    cd "$SCRIPT_DIR"
    
    ensure_nginx_config
    ensure_nginx_running
    rebuild_frontend
    deploy_new_environment "$new_env"
    
    if ! health_check "$new_port" "$new_env"; then
        log ERROR "배포 실패: 헬스체크 실패"
        log WARN "롤백: 이전 환경 유지"
        cleanup_environment "$new_env"
        exit 1
    fi
    
    if [ "${current_env:-none}" != "none" ]; then
        log INFO "트래픽을 ${new_env:-unknown}로 전환 중..."
        update_nginx_config "${new_env:-unknown}" "${old_env:-none}"
        sleep 3
    else
        update_nginx_config "${new_env:-unknown}" "${old_env:-none}"
        sleep 3
    fi
    
    ensure_nginx_running
    
    if health_check_nginx; then
        log INFO "배포 성공!"
        if [ "${old_env:-none}" != "none" ]; then
            log INFO "이전 ${old_env:-unknown} 환경 정리 중..."
            handle_cleanup "${old_env:-none}" "${new_env:-unknown}"
        fi
    else
        log ERROR "Nginx 헬스체크 실패"
        log WARN "새 ${new_env:-unknown} 환경은 포트 ${new_port:-unknown}에서 실행 중입니다"
        log INFO "직접 확인: curl http://localhost:${new_port:-unknown}/api/health"
        if [ "${current_env:-none}" != "none" ]; then
            log WARN "${old_env:-unknown} 환경은 롤백을 위해 유지됩니다"
        fi
    fi
    
    log INFO "=== 배포 완료: ${new_env:-unknown} 환경 활성화 ==="
}

main "$@"