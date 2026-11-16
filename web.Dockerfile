# Flutter 웹 빌드 결과(donBug_FE/build/web)를 Caddy 로 서빙. 빌드는 deploy.sh 가 로컬 SDK 로 먼저 한다.
FROM caddy:2.10-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY donBug_FE/build/web /srv
