#!/usr/bin/env bash
# Flutter 웹을 로컬 SDK 로 빌드한 뒤 컨테이너를 다시 올린다.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo ".env 가 없어요. cp .env.example .env 후 값을 채우세요." >&2; exit 1; }
# FE 저장소의 로컬 SDK(donBug_FE/flutter, gitignore 대상)가 있으면 그걸, 없으면 PATH 의 flutter 를 쓴다.
FLUTTER=flutter
[ -x donBug_FE/flutter/bin/flutter ] && FLUTTER="$PWD/donBug_FE/flutter/bin/flutter"
(cd donBug_FE && "$FLUTTER" build web --release)
docker compose up -d --build
docker compose ps
