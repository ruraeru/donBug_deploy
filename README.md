# donBug deploy

돈벌래 웹(사장님 화면)과 백엔드를 Docker 로 `https://donbug.ruraeru.xyz` 에 배포한다.

- `donBug_FE`: Flutter 앱 (submodule, github.com/ruraeru/donBug)
- `donBug_BE`: Spring Boot 백엔드 (submodule, github.com/halo518/MoneyBug)
- `web`(Caddy): Flutter 웹 정적 파일 + `/api/*` 를 백엔드로 프록시. 호스트 포트 `3004`(HTTP)
- `be`: Spring Boot, `db`: MySQL 8.4 (볼륨 `db_data`)

## 배포

1. 앞단 리버스 프록시에서 `https://donbug.ruraeru.xyz` 를 `http://<이 서버>:3004` 로 넘긴다 (HTTPS 인증서는 프록시가 담당).
2. 받기:
   ```sh
   git clone --recurse-submodules https://github.com/ruraeru/donBug_deploy.git
   cd donBug_deploy
   ```
3. `cp .env.example .env` 후 값을 채운다. `JWT_SECRET` 은 `openssl rand -base64 48`. `.env` 는 커밋하지 않는다.
4. `./deploy.sh` — 서브모듈을 받고 `docker compose up -d --build`. Flutter 웹은 Docker 안에서 빌드한다(서버에 Flutter SDK 불필요).

## 업데이트

```sh
git pull
./deploy.sh
```

## 주의

- 운영에서는 `DEV_LOGIN_ENABLED=false`(기본값). `test_token` 개발 로그인 우회가 꺼진다.
- `JWT_SECRET`, `DB_PASSWORD`, `DB_ROOT_PASSWORD` 가 비어 있으면 compose 가 시작을 거부한다.
- 카카오 로그인을 쓰려면 카카오 콘솔에 Redirect URI `https://donbug.ruraeru.xyz/api/auth/kakao/callback` 을 등록한다.
