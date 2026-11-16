#!/usr/bin/env bash
# 서브모듈(FE·BE)을 받아 오고 컨테이너를 다시 빌드해 올린다. Flutter 빌드는 Docker 안에서 한다.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo ".env 가 없어요. cp .env.example .env 후 값을 채우세요." >&2; exit 1; }
git submodule update --init --recursive
for d in donBug_FE/pubspec.yaml donBug_BE/gradlew; do
  [ -f "$d" ] || { echo "$d 가 없어요. 서브모듈을 받지 못했어요." >&2; exit 1; }
done
docker compose up -d --build
docker compose ps
