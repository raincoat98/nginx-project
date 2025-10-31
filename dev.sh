#!/usr/bin/env bash
set -euo pipefail

# 프로젝트 루트 기준 절대경로 계산
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"

# .env.development 파일이 있으면 로드 (frontend 폴더)
if [[ -f "$PROJECT_ROOT/frontend/.env.development" ]]; then
  set -a
  source "$PROJECT_ROOT/frontend/.env.development"
  set +a
fi

usage() {
  cat <<'USAGE'
사용법: ./dev.sh [명령]

명령:
  up        docker compose up -d --build (기본)
  down      docker compose down -v
  logs      docker compose logs -f
  ps        docker compose ps
  rebuild   이미지 재빌드 후 재기동 (pull 포함)
  clean     중지 후 로컬 이미지/볼륨 정리

예시:
  ./dev.sh
  ./dev.sh up
  ./dev.sh down
  ./dev.sh logs
USAGE
}

ensure_compose_file() {
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "docker-compose.yml 파일을 찾을 수 없습니다: $COMPOSE_FILE" >&2
    exit 1
  fi
}

print_endpoints() {
  local frontend_port="${VITE_PORT:-4501}"
  echo ""
  echo "로컬 엔드포인트:"
  echo "- Nginx:     http://localhost:8580"
  echo "- Frontend:  http://localhost:${frontend_port}"
  echo "- Backend:   http://localhost:4500"
  echo ""
}

cmd=${1:-up}

ensure_compose_file

# docker-compose 명령어에 사용할 env-file 옵션 설정
# frontend 폴더의 파일이 우선순위가 높음
ENV_FILE_OPTION=""
if [[ -f "$PROJECT_ROOT/frontend/.env.development" ]]; then
  ENV_FILE_OPTION="--env-file $PROJECT_ROOT/frontend/.env.development"
elif [[ -f "$PROJECT_ROOT/.env.development" ]]; then
  ENV_FILE_OPTION="--env-file $PROJECT_ROOT/.env.development"
fi

case "$cmd" in
  up)
    docker compose -f "$COMPOSE_FILE" $ENV_FILE_OPTION up -d --build
    print_endpoints
    ;;
  down)
    docker compose -f "$COMPOSE_FILE" $ENV_FILE_OPTION down -v
    ;;
  logs)
    docker compose -f "$COMPOSE_FILE" $ENV_FILE_OPTION logs -f
    ;;
  ps)
    docker compose -f "$COMPOSE_FILE" $ENV_FILE_OPTION ps
    ;;
  rebuild)
    docker compose -f "$COMPOSE_FILE" $ENV_FILE_OPTION pull --ignore-buildable || true
    docker compose -f "$COMPOSE_FILE" $ENV_FILE_OPTION build --no-cache
    docker compose -f "$COMPOSE_FILE" $ENV_FILE_OPTION up -d
    print_endpoints
    ;;
  clean)
    docker compose -f "$COMPOSE_FILE" down -v || true
    docker system prune -af --volumes
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "알 수 없는 명령: $cmd" >&2
    echo "" >&2
    usage
    exit 1
    ;;
esac


