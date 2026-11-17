# donBug deploy

돈벌래(사장님·알바생 매장 관리) 웹과 백엔드를 Docker 로 `https://donbug.ruraeru.xyz` 에 배포하는 레포.

| 구성 | 내용 |
|---|---|
| `donBug_FE` | Flutter 앱·웹 (submodule, github.com/ruraeru/donBug, 브랜치 `deploy`. 이 레포 `develop` 에서는 `develop`) |
| `donBug_BE` | Spring Boot 백엔드 (submodule, github.com/halo518/MoneyBug, 브랜치 `deploy`. 이 레포 `develop` 에서는 `develop`) |
| `web` (Caddy) | Flutter 웹 정적 파일 + `/api/*` 를 백엔드로 프록시. 호스트 포트 `3004` (HTTP) |
| `be` | Spring Boot (Java 17). 업로드 파일은 볼륨 `uploads` (`/data/uploads`) |
| `db` | MySQL 8.4 (볼륨 `db_data`) |

앞단 리버스 프록시가 `https://donbug.ruraeru.xyz` 를 `http://<서버>:3004` 로 넘긴다. HTTPS 인증서는 그 프록시가 맡는다.

## 처음 배포

1. 받기
   ```sh
   git clone --recurse-submodules https://github.com/ruraeru/donBug_deploy.git
   cd donBug_deploy
   ```
2. 설정: `cp .env.example .env` 후 값을 채운다. `.env` 는 커밋하지 않는다.
3. 배포: `./deploy.sh`
   - 서브모듈을 이 레포에 기록된 커밋으로 받고 `docker compose up -d --build` 한다.
   - Flutter 웹은 Docker 안에서 빌드한다. 서버에 Flutter SDK 가 필요 없다.
4. 카카오 콘솔에 Redirect URI `https://donbug.ruraeru.xyz/api/auth/kakao/callback` 을 등록한다.

## `.env`

| 변수 | 필수 | 설명 |
|---|---|---|
| `DOMAIN` | | 기본 `donbug.ruraeru.xyz`. 카카오 콜백·CORS·로그인 후 돌아갈 주소에 쓴다 |
| `WEB_PORT` | | 웹 컨테이너 호스트 포트. 기본 `3004` |
| `DB_PASSWORD`, `DB_ROOT_PASSWORD` | 필수 | 비어 있으면 compose 가 시작을 거부한다 |
| `JWT_SECRET` | 필수 | 32바이트 이상. `openssl rand -base64 48` |
| `KAKAO_REST_API_KEY`, `KAKAO_CLIENT_SECRET` | 로그인 | 카카오 로그인(웹·앱 모두 서버 OAuth) |
| `DEV_LOGIN_ENABLED` | | 운영은 `false`(기본). `true` 면 누구나 `test_token` 으로 로그인되니 켜지 말 것 |
| `SWAGGER_ENABLED` | | 기본 꺼짐. `true` 면 BE 의 Swagger UI·`/v3/api-docs` 가 열린다 (Caddy 는 `/api/*` 만 넘기므로 외부에서는 어차피 안 보임) |
| `TEST_LOGIN_TOKEN` | | 16자 이상 비밀값. 로그인 화면 로고를 길게 눌러 이 값을 넣으면 "테스트알바" 계정. 비우면 꺼짐. `openssl rand -hex 24` |
| `ANTHROPIC_API_KEY` | | AI 노무 도우미(Claude). 비우면 그 기능만 꺼짐 |
| `LLM_BASE_URL`, `LLM_MODEL`, `LLM_API_KEY` | | AI 근무표 생성(Ollama 호환). 기본 `https://ai.ruraeru.xyz`, `qwen3.5:9b` |

## 업데이트 (새 버전 배포)

브랜치는 세 레포 모두 고정이다. FE·BE: `develop`·`main`·`deploy`. 이 레포: `main`(submodule 이 FE·BE `deploy` 를 따라감, 운영)·`develop`(FE·BE `develop` 을 따라감, 테스트 배포). 기능 브랜치는 머지 뒤 지운다.

1. FE·BE 에서 기능 브랜치 → `develop` PR → 머지(merge commit).
2. 테스트 배포: 이 레포 `develop` 에서 포인터를 올린다.
   ```sh
   git checkout develop && git submodule update --remote donBug_FE donBug_BE
   git add donBug_FE donBug_BE && git commit -m "chore: bump FE/BE develop" && git push
   ```
   서버: `git checkout develop && git pull && git submodule sync && git submodule update --init && ./deploy.sh`
3. 운영 배포: FE·BE 에서 PR `develop → main` → `main → deploy` 머지 후, 이 레포 `main` 에서 같은 방식으로 포인터를 올린다.
   서버: `git checkout main && git pull && git submodule sync && git submodule update --init && ./deploy.sh`

`.gitmodules` 의 `branch` 는 두 브랜치가 다르다(`main`=`deploy`, `develop`=`develop`). 그래서 이 레포의 `develop` 을 `main` 에 머지하지 않는다. 설정·문서 변경은 `main` 에 커밋하고 `develop` 에 cherry-pick 한다. 서버에서 브랜치를 바꾼 뒤에는 `git submodule sync` 가 필요하다.

## 모바일 앱 (iPhone)

- iOS 빌드는 Mac + Xcode 가 필요하다. FE 레포에서:
  ```sh
  flutter pub get
  flutter run --release          # 서버 모드가 기본. 데모는 --dart-define=DEMO=true
  ```
  서버 주소 기본값은 `https://donbug.ruraeru.xyz` (`--dart-define=API_BASE=...` 로 바꿈).
- 무료 Apple ID 로 설치한 앱은 7일 뒤 만료된다. 팀원 배포(TestFlight·Ad Hoc)는 유료 개발자 계정이 필요하다. 무료로 나누려면 IPA 를 만들어 Sideloadly 로 각자 서명해 설치한다.
- 아이폰 Safari 로 웹에 들어가도 폭이 좁으면 모바일 앱 화면이 나온다(설치 없이 테스트 가능).
- 서버 데이터 형식(`/me/state` 의 `v`)이 바뀌면 예전 앱은 "앱을 업데이트해 주세요"를 띄운다. 앱을 다시 빌드한다.

## 운영 작업

명령은 서버의 `~/donBug_deploy` 에서 한다. DB 접속 시 문자셋을 꼭 지정한다(기본 latin1 이라 한글이 깨진다).

```sh
M='mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --default-character-set=utf8mb4 moneybug'
sudo docker compose exec -T db sh -c "$M"
```

- 로그: `sudo docker compose logs be --tail 80`
- 백업: `sudo docker compose exec db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" moneybug' > ~/moneybug-$(date +%F).sql`
- **DB 전부 초기화 (되돌릴 수 없음)**: `sudo docker compose down && sudo docker volume rm donbug_db_data donbug_uploads && ./deploy.sh`. 테이블은 서버가 처음 뜰 때 다시 만든다(`ddl-auto: update`).
- 근무표 테스트 직원 8명 넣기 (매장 코드를 바꿔서):
  ```sh
  (echo "SET @code='ABCD-EFGH';"; cat scripts/seed-test-staff.sql) | sudo docker compose exec -T db sh -c "$M"
  ```
  지우는 SQL 은 스크립트 맨 아래 주석에 있다.
- AI 서버 연결 확인: `sudo docker compose exec be sh -c 'curl -s https://ai.ruraeru.xyz/api/tags'`

## 문제 해결

| 증상 | 원인·확인 |
|---|---|
| 웹은 뜨는데 로그인 창이 흰 화면, `/api` 가 502 | 백엔드가 시작하지 못함. `docker compose logs be` 로 원인 확인 |
| Docker 빌드 `"/donBug_FE/build/web": not found` | 예전 Dockerfile. 지금은 Docker 안에서 빌드한다 |
| SQL 실행 시 `Illegal mix of collations` | 테이블은 `utf8mb4_unicode_ci`. 스크립트가 `SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci` 를 쓴다 |
| 근무표 저장이 되돌아감 | 브라우저 Network 탭에서 `PUT .../schedules/{월}/shifts` 응답 메시지를 확인 |
