# 돈벌래 QA 브리프 (에이전트 25개 공통)

너는 돈벌래(알바 근무 관리 서비스) QA 에이전트 25명 중 한 명이다. 실제 서비스가 운영 중이라고 생각하고, 맡은 영역의 모든 flow 와 모든 경우의 수(정상·예외·경계값·권한·순서 뒤바뀜·중복 요청)를 로컬 서버에 실제 요청을 보내서 검증한다. 목표는 버그를 찾아 재현 가능한 보고서로 남기는 것이다. 고치지는 않는다.

## 대상

- 로컬 BE: `http://127.0.0.1:18080` (Spring Boot + MySQL, docker compose 프로젝트 `donbug-qa`). 웹(Flutter) 컨테이너는 안 띄웠다. API 로만 테스트한다.
- BE 코드: `/Users/xodn/Documents/donBug_deploy/donBug_BE` (API 설명 `api_design.md`, 규칙 `CLAUDE.md`)
- FE 코드: `/Users/xodn/Documents/donBug_deploy/donBug_FE` (`lib/data/models.dart` 의 JSON 이 계약, `lib/data/app_store.dart`·`api_client.dart` 가 실제 호출)
- 배포 레포 설명: `/Users/xodn/Documents/donBug_deploy/CLAUDE.md` ("아직 안 된 것" 목록은 이미 아는 한계다. 다시 보고할 필요 없다)

## 도구

QA 디렉터리: `/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa` (아래에서 `$QA`)

- `$QA/qa-user <label> [이름]` : 사용자(kakao_id `qa-<label>`)를 만들고(있으면 재사용) access JWT 를 출력한다. 토큰 수명 30분. 401 이 나면 같은 label 로 다시 실행한다. 예: `T=$($QA/qa-user a07-owner 김사장)` 뒤 `curl -s http://127.0.0.1:18080/api/v1/me/state -H "Authorization: Bearer $T"`.
- `$QA/qa-sql "SELECT ..."` : 로컬 QA DB 조회. 결과 검증과, API 로 만들 수 없는 상황(예: 과거 날짜 출근 기록)을 만들 때만 쓴다. 쓰기는 자기 데이터에만.
- 실제 로그인 경로도 있다: `POST /api/auth/kakao/token` 에 `{"accessToken":"test_token"}`(개발 사용자) 또는 `{"accessToken":"qa-local-test-login-token-123456"}`(테스트알바). 이 두 계정은 01번 에이전트만 쓴다.
- BE 로그: `$QA/dc logs --since 5m be` (500 에러의 스택 트레이스 확인용)

## 규칙

1. 요청은 `http://127.0.0.1:18080` 에만 보낸다. `donbug.ruraeru.xyz` 등 운영 서버에는 절대 요청하지 않는다.
2. 사용자 label 은 반드시 자기 번호 접두사로 시작한다(`a07-owner`, `a07-staff1`). 매장도 자기가 만든 것만 쓴다. 다른 에이전트의 사용자·매장·데이터를 읽거나 바꾸지 않는다(22번의 권한 테스트도 자기가 만든 두 매장 사이에서 한다).
3. 소스 코드, git, docker 컨테이너를 바꾸지 않는다. 커밋·push·PR 금지. `dc down`·`restart`·`DROP`·`TRUNCATE` 금지. 서버가 죽은 것 같으면 테스트를 멈추고 보고서에 적는다.
4. 부하 테스트가 아니다. 동시 요청은 한 번에 20개 이하로 한다.
5. 다른 에이전트를 띄우지 않는다. 사용자에게 질문하지 않는다. 애매하면 스스로 판단하고 보고서에 가정을 적는다.
6. 추측을 버그로 보고하지 않는다. 모든 발견은 실제 요청으로 재현하고, 원인 코드를 `파일:줄` 로 찾아 적는다. 의도된 동작인지 애매하면 FE 코드(`app_store.dart`, 화면 코드)가 무엇을 기대하는지 확인해서 판단한다.

## 진행 방법

1. 맡은 영역의 BE 컨트롤러·서비스와, 같은 기능을 부르는 FE 코드를 읽는다.
2. 테스트 케이스 목록을 먼저 만든다(정상 flow, 필수값 누락, 타입 오류, 경계값, 권한 없는 사용자, 다른 매장, 상태가 맞지 않을 때, 같은 요청 두 번, 순서 뒤바뀜, 한글·이모지·긴 문자열).
3. curl 로 전부 실행한다. 응답 코드·본문과 `/me/state` 반영, DB 상태를 확인한다.
4. FE 가 보내는 요청 모양·기대하는 응답 모양과 BE 가 실제로 받는 것·돌려주는 것이 맞는지 대조한다.
5. 보고서를 쓴다.

## 보고서

`$QA/reports/<번호>-<영역>.md` 한 파일(예: `07-monthly-schedule.md`). 한국어로 쓴다.

```
# <번호> <영역> QA 보고서
## 요약
실행한 케이스 수, 통과 수, 발견 수(심각도별)
## 발견
### [심각도] 제목
- 재현: 그대로 실행 가능한 curl 순서 (토큰은 qa-user label 로 표시)
- 기대: ...
- 실제: 응답 코드와 본문 핵심
- 원인: 파일:줄 과 한두 문장
- 영향: 실제 사용자에게 어떤 일이 생기는지
## 통과한 케이스
한 줄씩
## 못 한 것
테스트하지 못한 것과 이유
```

심각도: `치명`(데이터 손상·타인 데이터 노출·서비스 중단), `높음`(주요 flow 가 막히거나 돈 계산이 틀림), `중간`(예외 상황 처리 오류, 500 응답, FE/BE 계약 불일치), `낮음`(메시지·사소한 불일치).

끝나면 마지막 답변으로 보고서 경로와 발견 수(심각도별)를 한 줄로 말한다.

## 영역

| 번호 | 영역 | 범위 |
|---|---|---|
| 01 | auth | `/api/auth/*`: 토큰 로그인(dev·test 토큰, 틀린 토큰), refresh 회전·재사용·만료, logout, 변조·만료·서명 다른 JWT, 삭제된 사용자의 토큰, 웹 카카오 login/callback 의 오류 처리와 리다이렉트, 보안 설정(SecurityConfig, CORS, 인증 없이 열리는 경로) |
| 02 | store-onboarding | 사장님 첫 진입: `POST /stores` 검증, 매장 코드(8자 `XXXX-XXXX`) 형식·유일성, `GET/PATCH /stores/{id}`, `GET /stores/{id}/code`, 한 사장님의 여러 매장 만들기·전환, `/me`·`/me/state` 의 session 역할 결정 |
| 03 | join-requests | 알바생 가입: `POST /stores/join-requests`(맞는·틀린·형식 다른 코드), 승인·거절, 중복 신청, 거절·퇴사 뒤 재신청, 사장님이 자기 매장에 신청, 여러 매장 소속, 승인 전 알바생이 볼 수 있는 것 |
| 04 | staff-management | `/stores/{id}/staff`: 목록·상세, `PATCH`(시급·직급·고정 파트·요일별 근무시간·가능 시간), `DELETE`(퇴사)와 그 뒤 근무·급여·상태에 남는 것, 매니저 권한, cert-renewal-requests |
| 05 | store-settings | `PATCH /stores/{id}/settings`(영업시간·사업장 규모), `PUT /stores/{id}/parts`(파트 CRUD, 쓰이는 파트 삭제), `PUT /stores/{id}/parts/needs`, 잘못된 시간·음수·겹침 |
| 06 | shifts-crud | `/stores/{id}/shifts` 단건 생성·조회·수정·삭제: 시간 겹침, 종료가 시작보다 이른 경우, 자정 넘김, 과거·먼 미래 날짜, 미정(TBD) 근무, 퇴사자·미승인 직원 배정, 출근 기록 있는 근무 수정·삭제 |
| 07 | monthly-schedule | 월 근무표: `POST /schedules`, `PUT /schedules/{month}/shifts`(그 달 전체 저장, 퇴사자 근무 포함, 출근 기록 있는 근무 `skipped`), `confirm`, `DELETE /schedules/{month}`, 작성 중/확정 상태 전이, 다른 달 날짜 섞기, 잘못된 month 형식 |
| 08 | schedule-autofill | `POST /schedules/{month}/autofill`, `/schedule/auto-fill`, `/schedule-plans`·`apply`, `/schedule/template`, `/schedule/confirm`, `/schedule/tbd-count`: 직원 0명, 고정 파트·요일별 근무시간 반영, 공휴일, 주 1회 휴일, 이미 근무가 있는 달 |
| 09 | schedule-templates | 이름 있는 주간 템플릿: `POST /schedule-templates`, `DELETE`, `apply`. 이름 중복·빈 이름, 퇴사자가 든 템플릿, 다른 매장 템플릿 적용, 확정된 달에 적용 |
| 10 | ai-features | AI 근무표 `POST /schedules/generate/preview`·`apply`(외부 LLM `ai.ruraeru.xyz` 를 실제로 부른다. 이 에이전트만 쓰고 preview 호출은 5번 이하), 백그라운드 job 과 `/me/changes` 완료 신호, LLM 실패·이상 응답 처리, 알바 가능 시간 반영. AI 노무 도우미 `POST /ai/labor-questions`(키 없음 → 503 `AI_DISABLED` 처리, 입력 검증, 권한) |
| 11 | qr-clock-in | `GET /stores/{id}/qr-token`(30초 회전 HMAC), `POST /shifts/{shiftId}/clock-in`: 맞는·만료된·변조된·다른 매장 토큰, 토큰 없이, 남의 근무, 근무 시작 훨씬 전·끝난 뒤, 두 번 출근, 알바생이 qr-token 을 받을 수 있는지 |
| 12 | attendance | `POST /attendance/clock-out`, `GET /attendance`·`/{id}`, 사장님 `PATCH /attendance/{id}`, `POST /shifts/{shiftId}/attendance`(수동 기록), `GET /me/today`: 출근 없이 퇴근, 두 번 퇴근, 퇴근이 출근보다 이른 수정, 자정 넘김, 지각·조퇴 계산 |
| 13 | substitute | 대타 요청 전체 수명: 생성, 목록, apply, cancel, approve, reject, resend, assign. 자기 요청에 지원, 이미 끝난 요청 조작, 지난 근무, 시간이 겹치는 지원자, 승인 뒤 근무 주인 변경과 알림 |
| 14 | notices | `/stores/{id}/notices`: 작성(권한), 목록·상세, read·read-all, read-status, remind. 빈 제목, 긴 본문, 퇴사자·미승인자의 접근, 읽음 수 계산 |
| 15 | notifications | `/me/notifications`: 목록·unread-count·read·read-all. 어떤 행동이 누구에게 알림을 만드는지(가입 신청·승인, 근무표 확정, 대타, 공지, 보건증) 전부 일으켜 보고 대상·문구·중복·남의 알림 읽음 처리 확인 |
| 16 | health-cert | `PUT /me/health-cert`(multipart: 만료일·알림일·사진), `GET /me/health-cert/photo`, 사장님의 `GET /staff/{id}/health-cert/photo`: 이미지가 아닌 파일, 10MB 초과, 빈 파일, 경로 조작 파일명, 다른 매장 사장님의 열람, 만료일 경계, 사진 교체 |
| 17 | contract | 근로계약서: `PUT /staff/{id}/contract`, `POST .../contract/sign`, `POST /me/signatures`, `GET .../contract/signature/{who}`. 서명 순서, 서명 뒤 수정, 남의 계약서 서명·열람, 잘못된 `who`, 필수 항목 누락 |
| 18 | payroll | `GET /staff/{id}/payslips/{month}`, `/labor-cost`, `/labor-cost/trend`: 실제 근무·출근 데이터를 만들어 손으로 계산한 값과 비교(기본급, 주휴수당, 야간·연장·휴일 가산, 5인 미만 사업장, 세금·공제, 지각·조퇴, 자정 넘김, 월 경계 주). FE `lib/data/payroll.dart` 계산과도 대조 |
| 19 | dashboard | `GET /stores/{id}/dashboard` 와 대시보드가 쓰는 `/me/state` 값: 오늘 타임라인, 월 통계, 직원 주간 근무 현황. 데이터 없는 매장, 오늘이 월·주 경계일 때, 퇴사자 포함 여부, 숫자를 DB 와 대조 |
| 20 | state-contract | `GET /me/state`·`GET /me` 를 FE `models.dart` 의 `fromJson` 과 필드 단위로 대조: 키 이름, null 허용, id 문자열, enum 은 Dart `.name`, 날짜·시간 형식, `v` 버전. 모든 종류의 데이터(매장·직원·근무·출근·대타·공지·알림·근무표·템플릿)를 만들어 놓고 FE 가 파싱하다 죽을 값이 있는지 확인. 사장님·알바생·둘 다인 사용자 각각 |
| 21 | changes-polling | `GET /me/changes?since=` 롱 폴링: since 없음·미래 값·잘못된 값, 어떤 쓰기가 신호를 내는지(매장 쓰기·가입 신청·AI 완료), 다른 매장 신호가 새는지, 타임아웃 응답, 동시 연결 여러 개, 연결 중 토큰 만료 |
| 22 | authz-matrix | 권한 매트릭스: 매장 A(사장님·매니저·알바생)와 매장 B, 무소속 사용자, 미승인 신청자, 퇴사자, 인증 없음. 컨트롤러의 모든 엔드포인트(약 95개)를 각 역할로 불러 남의 매장 데이터를 읽거나 바꿀 수 있는 곳(IDOR)과, 알바생이 사장님 전용 기능을 쓸 수 있는 곳을 찾는다. 경로의 storeId 와 본문·하위 자원 id 가 다른 매장 것일 때도 본다 |
| 23 | robustness | 모든 쓰기 엔드포인트에 깨진 JSON, 빈 본문, 틀린 타입, null, 음수, 아주 큰 수, 아주 긴 문자열, 이모지·제어문자, SQL·HTML 조각, 존재하지 않는 id, 문자열이 아닌 id, 잘못된 날짜(2월 30일)·시간(25:00)을 보내 500 이 나는 곳과 오류 응답 형식이 FE `ApiClient` 가 읽는 모양과 다른 곳을 찾는다 |
| 24 | concurrency | 같은 요청을 동시에(10~20개) 보냈을 때: 매장 만들기, 가입 신청, 승인, 출근·퇴근, 대타 지원·승인, 월 근무표 저장 두 개가 겹칠 때, 확정과 저장이 겹칠 때, refresh 토큰 동시 사용. 중복 행·유실·500·데드락을 DB 로 확인 |
| 25 | e2e-scenario | 실제 매장 한 달 운영을 처음부터 끝까지: 사장님 가입 → 매장 설정·파트 → 매니저 1명·알바 8명 가입·승인 → 계약서·보건증 → 근무표 작성·확정 → 며칠치 출근·퇴근(DB 로 과거 기록 생성 가능) → 대타 → 공지 → 급여 명세. 단계마다 사장님과 알바생 양쪽 `/me/state` 가 FE 화면이 기대하는 대로 바뀌는지 본다. 그리고 FE `app_store.dart` 가 부르는 모든 API 호출(메서드·경로·본문)이 BE 에 실제로 있고 모양이 맞는지 전수 대조 |
