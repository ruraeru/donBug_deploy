# CLAUDE.md — donBug_Deploy

돈벌래 배포 레포. FE(Flutter, `donBug_FE`)와 BE(Spring Boot, `donBug_BE`)를 submodule 로 묶어 Docker 로 `https://donbug.ruraeru.xyz` 에 배포한다. 배포·운영 방법은 README.md. 각 하위 레포의 코드 규칙은 그 레포의 CLAUDE.md.

## 레포와 브랜치

| 레포 | 원격 | 작업 브랜치 | 배포 브랜치 |
|---|---|---|---|
| 이 레포 | github.com/ruraeru/donBug_deploy (공개) | `main` 에 직접 커밋·push | — |
| FE | github.com/ruraeru/donBug | 기능 브랜치 → `develop` PR → `main` PR | `deploy` |
| BE | github.com/halo518/MoneyBug (다른 계정, push·머지 권한 있음) | 기능 브랜치 → `main` PR | `deploy` |

- `.gitmodules` 는 두 submodule 모두 `branch = deploy`. 배포 = `deploy` 브랜치 갱신 → 이 레포에서 `git submodule update --remote` → 포인터 커밋·push → 서버 `git pull && ./deploy.sh`.
- PR 은 merge commit 으로 머지. 커밋·PR 끝에 Claude attribution 을 붙인다.
- 배포 서버는 이 작업 환경과 **다른 호스트**(`ruraeru@docker:~/donBug_deploy`). 이 환경에서는 docker 명령 권한이 없고 운영 DB 에도 접근할 수 없다. 서버 작업은 사용자가 직접 실행하도록 명령을 준다(파일이 필요하면 이 레포에 커밋·push 해서 `git pull` 로 받게 한다).
- 자동 모드 분류기가 사용자 명시 없이 하는 PR 생성·머지·push 를 막을 수 있다. 사용자가 "PR 올리고 머지한 다음 배포 레포 포인터 올려줘" 라고 하면 그대로 진행한다.

## 구성

- `docker-compose.yml`: `web`(Caddy, `${WEB_PORT:-3004}:80`), `be`(`be.Dockerfile`, 환경변수로 설정), `db`(mysql:8.4, 테이블 `utf8mb4_unicode_ci`). 볼륨 `db_data`, `uploads`.
- `Caddyfile`: `/api/*` → `be:8080`, 나머지는 Flutter 웹(`try_files {path} /index.html`).
- `web.Dockerfile`: flutter git 태그(3.47.9)를 clone 해 Docker 안에서 `flutter build web --release`. 서버 모드가 기본이라 플래그 없음.
- `be.Dockerfile`: temurin 17, `application-secret.sample.yml` 을 secret 파일로 복사, `bootJar -x test`.
- `scripts/seed-test-staff.sql`: 근무표 테스트 직원 8명(kakao_id `test-staff-*`). `SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci` 필수.

## 지금까지 한 일 (2026-11 기준)

1. **BE 를 FE 계약에 맞춤**: FE `models.dart` JSON 이 계약(BE 가 맞춘다). id 는 문자열(`FeIdJsonModule`), enum 은 Dart `.name`(`EnumJson`), DTO 키는 `@JsonProperty`. `GET /api/v1/me/state` 가 FE `AppState` 모양 그대로 돌려준다(현재 `v: 4`). CORS.
2. **배포**: 이 레포, Caddy + BE + MySQL, 포트 3004.
3. **FE↔BE 연결**: `ApiClient`(토큰·refresh), `AppStore` 는 액션 후 `_remote` → `/me/state` reload. 웹 `WebBoot`(카카오 리다이렉트 로그인 → 매장 만들기 → 대시보드).
4. **모바일 서버 모드**: 앱 카카오 로그인은 `flutter_web_auth_2` 로 서버 OAuth → `donbug://auth` 로 토큰. `MobileBoot`/`enterApp` 이 상태로 첫 화면 결정.
5. **데모 제거·실제 연동**: 서버 모드가 기본(`--dart-define=DEMO=true` 면 데모). QR 출근(30초 회전 HMAC 토큰, 웹 POS 표시 + 앱 카메라 스캔, 출근 시 필수), 보건증 사진·서명 이미지 업로드, AI 노무 도우미(Anthropic, `ANTHROPIC_API_KEY`).
6. **테스트 계정**: `TEST_LOGIN_TOKEN`(비밀, 16자+) → 로그인 화면 로고 길게 누르기(앱·웹). 운영에서 공개 우회 `test_token` 은 끔.
7. **웹 모바일 화면**: 폭 700 미만이면 웹에서도 모바일 앱 화면, 알바생은 웹에서 항상 모바일 화면. 사장님은 "모바일 화면 / PC 화면으로" 전환. 빈 곳 탭하면 키보드 내림.
8. **근무표 개편 (autoSchedule_FE 이식)**: 매장 설정(영업시간·사업장 규모·파트 CRUD), 직원 고정 파트·요일별 근무시간, 월 근무표(작성 중/확정·출처), 편집기 초안 모드(되돌리기·저장), 이름 있는 주간 템플릿, AI 근무표 생성(Ollama `ai.ruraeru.xyz` qwen, 백그라운드 job, 알바는 고정 파트·직원만 AI). 레퍼런스: github.com/ruraeru/autoSchedule_FE.
9. **실시간 반영**: `GET /api/v1/me/changes?since=` 롱 폴링(매장 쓰기 요청·가입 신청·AI 생성 완료가 신호), 60초 주기 확인, 탭 화면 당겨서 새로고침, 앱 버전이 다르면 업데이트 안내.
10. **대시보드 근무표**: 오늘 타임라인(TodayStrip) · 월 통계 · 직원 주간 근무 현황.

## 겪은 문제와 교훈

- **BE 가 시작 못 하면 `/api` 전체 502** (웹은 뜨고 로그인 창이 흰 화면). 단위 테스트는 컨텍스트를 안 띄워 못 잡는다. BE 변경 뒤에는 더미 DB 로 jar 를 띄워 `Started MoneyBugApplication` 을 확인한다:
  ```sh
  bash ./gradlew bootJar -x test -q && JWT_SECRET=0123456789012345678901234567890123456789 timeout 60 java -jar build/libs/MoneyBug-0.0.1-SNAPSHOT.jar --spring.config.additional-location=file:src/main/resources/application-secret.sample.yml --server.port=18099 --spring.datasource.url='jdbc:mysql://127.0.0.1:1/x' --spring.datasource.username=x --spring.datasource.password=x --spring.sql.init.mode=never --spring.jpa.hibernate.ddl-auto=none --spring.jpa.properties.hibernate.boot.allow_jdbc_metadata_access=false --spring.jpa.database-platform=org.hibernate.dialect.MySQLDialect --spring.datasource.hikari.initialization-fail-timeout=-1 2>&1 | grep -E "Started |APPLICATION FAILED|Caused by"
  ```
- Spring Boot 4: `RestClient.Builder` 빈이 없다(`RestClient.builder()` 직접). 생성자가 둘인 빈은 주 생성자에 `@Autowired`. Jackson 3 (`tools.jackson.*`). 롱 폴링(`DeferredResult`)은 보안에서 `DispatcherType.ASYNC` 허용 필요.
- 근무표 월 저장(`PUT /schedules/{month}/shifts`)은 그 달 근무 전체를 보낸다. 퇴사자의 지난 근무도 포함되므로 BE 가 받아야 한다. 출근 기록 있는 근무는 삭제·변경하지 않고 `skipped`.
- FE `reload` 는 늦게 온 응답·편집 중 응답을 버린다(초안 덮어쓰기 방지).
- `/me/state` 의 `v` 를 올리면 예전 앱은 상태를 못 읽는다(업데이트 안내만). FE `AppState.version` 과 BE `FE_STATE_VERSION` 을 같이 바꾼다.
- 매장 코드는 8자 `XXXX-XXXX`(앱 입력칸 8칸).
- mysql 클라이언트 기본 latin1 → 한글 깨짐. `--default-character-set=utf8mb4` + `COLLATE utf8mb4_unicode_ci`.
- 웹 http 클라이언트는 스트리밍을 버퍼링해서 SSE 대신 롱 폴링을 쓴다.

## 아직 안 된 것

- 휴대폰 푸시 알림(FCM/APNs) 없음.
- 웹 인건비 "PDF 내보내기"·"정산 확정"은 "추후 개발 예정".
- 앱 사장님 AI 노무 도우미 진입 경로 없음(웹은 됨).
- QR 은 60초 안 재사용 가능, 위치 확인 없음.
- 출근 기록 있는 근무 삭제 시도는 웹 근무 창에서 안내 없이 무시된다.
- 공휴일은 2026년만.
- FE `donBug_FE/CLAUDE.md` 는 아직 "프로토타입·백엔드 없음" 시절 설명이 남아 있다.
