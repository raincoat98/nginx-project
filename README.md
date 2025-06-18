# Nginx 프로젝트

이 프로젝트는 프론트엔드, 백엔드, 그리고 Nginx를 포함한 전체 스택 웹 애플리케이션입니다.

## 프로젝트 구조

```
.
├── frontend/          # 프론트엔드 애플리케이션
├── backend/           # 백엔드 애플리케이션
├── nginx/            # Nginx 설정 파일
├── docker-compose.yml        # 개발 환경 Docker Compose 설정
└── docker-compose.prod.yml   # 프로덕션 환경 Docker Compose 설정
```

## 시작하기

### 필수 요구사항

- Docker
- Docker Compose

### 개발 환경 실행

1. 저장소를 클론합니다:

```bash
git clone [repository-url]
cd nginx-project
```

2. 개발 환경을 시작합니다:

```bash
docker-compose up
```

이 명령어는 다음 서비스들을 시작합니다:

- 프론트엔드 (포트: 4501)
- 백엔드 (포트: 4500)
- Nginx (포트: 8580)

### 프로덕션 환경 실행

프로덕션 환경을 시작하려면:

```bash
docker-compose -f docker-compose.prod.yml up
```

## 접근 방법

- 프론트엔드: http://localhost:4501
- 백엔드 API: http://localhost:4500
- Nginx 프록시: http://localhost:8580

## 기술 스택

- 프론트엔드: Node.js
- 백엔드: Node.js
- 웹 서버: Nginx
- 컨테이너화: Docker

## 라이선스

이 프로젝트는 MIT 라이선스 하에 배포됩니다.
