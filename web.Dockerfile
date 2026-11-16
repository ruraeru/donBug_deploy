# 빌드 컨텍스트: 저장소 루트. Flutter 웹을 컨테이너 안에서 빌드하므로 서버에 Flutter SDK 가 필요 없다.
FROM debian:bookworm-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl unzip xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# FE 개발에 쓰는 SDK 와 같은 버전 (donBug_FE/flutter = 3.47.9, Dart 3.13.7)
ARG FLUTTER_VERSION=3.47.9
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter
ENV PATH=/opt/flutter/bin:$PATH
RUN flutter config --no-analytics && flutter precache --web
WORKDIR /app
COPY donBug_FE/pubspec.yaml donBug_FE/pubspec.lock ./
RUN flutter pub get
COPY donBug_FE/ ./
# USE_API=true: 서버 연동 모드 (카카오 로그인 + /api 호출). 같은 origin 이라 API_BASE 는 비워 둔다.
RUN flutter build web --release --dart-define=USE_API=true

FROM caddy:2.10-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/build/web /srv
