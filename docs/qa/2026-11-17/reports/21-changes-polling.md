# 21 changes-polling QA 보고서

## 요약

- 실행한 케이스 26개, 통과 22개
- 발견 4건: 치명 1, 높음 0, 중간 0, 낮음 3
- 테스트 데이터: 사용자 `a21-ownerA`(매장 A id 42, 코드 `GXX2-JU7N`), `a21-ownerB`(매장 B id 43, 코드 `7QEY-FXY7`), `a21-staff1`(A 가입 → 승인 → 퇴사), `a21-staff2`(A 가입 → 거절), `a21-none`(무소속)
- 아래 curl 의 공통 변수: `B=http://127.0.0.1:18080`, `TA=$($QA/qa-user a21-ownerA)` 같은 식으로 label 마다 토큰을 받는다.

## 발견

### [치명] 기다리는 롱 폴링마다 DB 커넥션을 25초 동안 붙잡는다. 동시 접속 10명이면 API 전체가 멈춘다

- 재현 (bash):
  ```sh
  TA=$($QA/qa-user a21-ownerA); TN=$($QA/qa-user a21-none)
  curl -s -o /dev/null -w 'control %{time_total}\n' $B/api/v1/me -H "Authorization: Bearer $TN"   # 0.005s
  S=$(curl -s $B/api/v1/me/changes -H "Authorization: Bearer $TA" | python3 -c 'import json,sys;print(json.load(sys.stdin)["seq"])')
  for i in $(seq 10); do curl -s -o /dev/null "$B/api/v1/me/changes?since=$S" -H "Authorization: Bearer $TA" & done
  sleep 2
  curl -s -o /dev/null -w 'during %{time_total}\n' $B/api/v1/me -H "Authorization: Bearer $TN"     # 22~24s
  wait
  ```
- 기대: 롱 폴링은 기다리는 동안 DB 자원을 쓰지 않는다. 다른 요청(`GET /me` 등)은 바로 응답한다.
- 실제:
  - 대기 중인 롱 폴링 10개가 있으면 무관한 사용자의 `GET /api/v1/me` 가 22.7초·23.8초 걸렸다(두 번 재현). 대조군은 0.005초, 폴링이 끝난 직후 0.015초.
  - 20개(사장님 8 + 알바 8 + 다른 매장 4)를 열었을 때:
    - 그 사이 보낸 `PATCH /stores/42` 가 500 이었다.
    - 폴링 일부가 30초 뒤 500, 일부는 40초 안에 응답이 없었다.
    - 매장 쓰기 신호도 아무 폴링에도 가지 않았다(전부 `changed:false` 또는 실패).
  - BE 로그: `HikariPool-1 - Connection is not available, request timed out after 30001ms (total=10, active=10, idle=0, waiting=33)`.
- 원인:
  - `spring.jpa.open-in-view` 가 기본값(켜짐)이다. 기동 로그에 `spring.jpa.open-in-view is enabled by default` 경고가 나오고, `src/main/resources` 에 설정이 없다.
  - `MeController.java:49-52` 가 롱 폴링 전에 `storeRepository.findByEmployerId`·`storeWorkerRepository.findByWorkerIdAndStatusIn` 로 DB 를 읽는다.
  - OSIV 의 EntityManager 는 async 요청이 끝날 때까지(최대 `StoreChangeHub.TIMEOUT_MS` 25초, `StoreChangeHub.java:20`) 열려 있다. Spring 의 `HibernateJpaVendorAdapter` 기본 커넥션 처리 모드는 `DELAYED_ACQUISITION_AND_HOLD` 다. 그래서 처음 잡은 커넥션을 그동안 놓지 않는다.
  - Hikari 풀은 기본 10개다(설정 없음). 롱 폴링 10개면 풀이 바닥난다.
  - `MeChangesLongPollTest` 는 DB 없는 `@WebMvcTest` 라서 이 문제를 잡지 못한다.
  - 이 메커니즘의 Spring 내부 부분은 jar 를 열어 확인하지 못했다. 다만 증상은 두 번 실측으로 재현했다.
- 영향:
  - FE `main.dart:57-73` `_watchChanges` 는 로그인한 모든 앱·웹 탭에서 이 요청을 끊임없이 다시 연다.
  - 운영에서 앱·웹 화면을 켜 둔 사용자가 10명을 넘으면 모든 API 가 최대 30초 기다리다 500 을 낸다. 출근·근무표 저장·로그인 등이 전부 해당된다.
  - 이것은 서비스 중단이다. 사용자가 늘수록 항상 이 상태에 머문다.

### [낮음] 보건증 등록·갱신(`PUT /me/health-cert`)은 변경 신호를 보내지 않는다

- 재현:
  ```sh
  TA=$($QA/qa-user a21-ownerA); TS=$($QA/qa-user a21-staff1)   # staff1 은 매장 42 재직 중일 때
  S=$(curl -s $B/api/v1/me/changes -H "Authorization: Bearer $TA" | python3 -c 'import json,sys;print(json.load(sys.stdin)["seq"])')
  curl -s -w ' %{http_code} %{time_total}\n' "$B/api/v1/me/changes?since=$S" -H "Authorization: Bearer $TA" &
  sleep 1
  curl -s -X PUT $B/api/v1/me/health-cert -H "Authorization: Bearer $TS" -F expiry=2027-06-30 -F alertDays=30,7 -F photo=@x.png
  curl -s $B/api/v1/me/notifications/unread-count -H "Authorization: Bearer $TA"; wait
  ```
- 기대: 사장님에게 보건증 알림(`CERT`)이 생기고 직원 보건증 상태가 바뀌므로 사장님의 롱 폴링이 `changed:true` 로 바로 끝난다.
- 실제:
  - 보건증 등록은 200 이다. 사장님 안 읽은 알림은 1 에서 2 로 늘었다.
  - 그런데 사장님 폴링은 25.5초 뒤 `{"changed":false}` 로 끝났다.
- 원인:
  - `StoreChangeInterceptor.java:24` 는 `/api/v1/stores/**` 에만 붙는다.
  - `DocumentController.java:73` `PUT /me/health-cert` 는 그 밖 경로다.
  - `DocumentService.java:69` 가 재직 매장마다 사장님에게 알림을 보내지만 `changeHub.bump` 는 부르지 않는다. 가입 신청(`StoreController.java:88`)처럼 직접 bump 해야 한다.
- 영향: 사장님 화면의 보건증 상태·알림 배지가 바로 바뀌지 않는다. 60초 주기 확인 때까지 늦게 반영된다.

### [낮음] `seq` 가 전 서비스 공용 카운터라 무소속 사용자도 다른 매장의 쓰기 횟수를 볼 수 있다

- 재현:
  ```sh
  TN=$($QA/qa-user a21-none); TB=$($QA/qa-user a21-ownerB)
  curl -s $B/api/v1/me/changes -H "Authorization: Bearer $TN"         # seq ...074
  for i in 1 2 3; do curl -s -o /dev/null -X PATCH $B/api/v1/stores/43 -H "Authorization: Bearer $TB" -H 'Content-Type: application/json' -d "{\"address\":\"B $i\"}"; done
  curl -s $B/api/v1/me/changes -H "Authorization: Bearer $TN"         # seq ...077
  ```
- 기대: 내 매장과 관계없는 변경은 나에게 보이는 값에 드러나지 않는다.
- 실제: 매장이 없는 사용자의 `seq` 가 남의 매장 B 에서 쓰기를 3번 하자 정확히 3 늘었다.
- 원인: `StoreChangeHub.java:22,30,59` 는 하나의 전역 `AtomicLong` 을 모든 매장 bump 에 쓰고, 응답에 그 값을 그대로 준다.
- 영향:
  - 서비스 전체의 쓰기 활동량(사용량 추이)이 누구에게나 보인다.
  - 개별 매장 데이터는 노출되지 않는다. 신호 자체도 남의 매장으로 새지 않았다(아래 통과 케이스).

### [낮음] `since` 형식 오류의 400 응답이 `{code, message}` 모양이 아니다

- 재현:
  ```sh
  curl -s "$B/api/v1/me/changes?since=abc" -H "Authorization: Bearer $TA"
  curl -s "$B/api/v1/me/changes?since=99999999999999999999" -H "Authorization: Bearer $TA"
  ```
- 기대: 다른 오류처럼 `{"code":"VALIDATION_FAILED","message":...}`.
- 실제: 400 `{"timestamp":...,"status":400,"error":"Bad Request","path":"/api/v1/me/changes"}`. 이것은 Spring 기본 오류 본문이다.
- 원인: `ApiExceptionHandler.java:19-31` 에 `MethodArgumentTypeMismatchException` 처리가 없다. 이 문제는 이 엔드포인트만이 아니라 공통이다.
- 영향:
  - FE 는 서버가 준 `seq` 만 보내므로 실제로 이 경로를 타지 않는다.
  - FE `ApiClient._error` 는 `code` 를 못 읽어 일반 오류로 처리한다. 사용자 영향은 거의 없다.

## 통과한 케이스

- `since` 없음, 빈 값, `-5`: 즉시 `{"seq":N,"changed":false}` 200.
- `since=0`: 바뀐 적 있는 매장이 있으면 즉시 `changed:true`.
- `since` 가 미래 값(seq+1,000,000)이어도 매장 쓰기가 오면 `changed:true` 로 바로 끝난다. bump 는 since 와 무관하게 대기자를 깨운다.
- 인증 없음 → 401. 잘못된 토큰 → 401.
- 변경이 없으면 약 25.4~25.8초 뒤 `changed:false` 200(타임아웃 응답).
- 알바생 가입 신청(`POST /stores/join-requests`, 201 `requested`) → 매장 A 사장님 폴링이 1초 안에 `changed:true`. 매장 B 사장님 폴링은 25초 뒤 `changed:false`(새지 않음).
- `alreadyPending`(409)·`alreadyMember`(409)·`notFound`(404) 가입 시도는 사장님에게 신호를 보내지 않는다.
- 가입 대기(PENDING) 신청자는 승인되면 신호를 받는다(1.0초).
- 가입 대기 신청자는 거절되면 신호를 받는다(1.0초). 거절 뒤에는 그 매장 쓰기 신호를 더 받지 않는다.
- 승인 실패(본문 누락 400)는 신호를 보내지 않는다(4xx 무시).
- 퇴사 처리(`DELETE /staff/{id}`, 204) → 대기 중이던 해당 알바생 폴링이 `changed:true`.
- 매장 B 쓰기(`PATCH /stores/43`)는 매장 A 알바생 폴링에 가지 않는다.
- 다른 매장 사장님과 무소속 사용자가 매장 A 쓰기 엔드포인트 11개를 부르면 전부 403 또는 400 이다. 매장 A 폴링에는 신호가 오지 않았다. 남이 신호를 일으켜 남의 매장 클라이언트를 깨울 수 없다.
- 연결 중 토큰 만료: 3초짜리 JWT 로 폴링하다 6초 뒤 매장 쓰기 → 200 `changed:true` 로 정상 응답. ASYNC 디스패치를 허용한다. 만료된 토큰으로 새 폴링을 열면 401.
- 다음 경로의 신호는 코드로 확인했다:
  - AI 브리핑 완료는 `MonthScheduleService.java:522` 에서 저장된 경우에만 bump.
  - 자동 퇴근·퇴근 누락 알림은 `AttendanceAutoClockOut.java:71,76`.
  - 매장 경로 쓰기는 2xx 일 때만 bump(`StoreChangeInterceptor.java:30`).

## 못 한 것

- AI 근무표 생성 완료 신호의 실측: preview 호출은 10번 에이전트 전용이라 부르지 않았다. 코드만 확인했다.
- 자동 퇴근 신호의 실측: 스케줄러 주기와 과거 출근 기록이 필요하다. 남의 데이터에 영향을 줄 수 있어 코드만 확인했다.
- 클라이언트가 연결을 끊었을 때 `waiters` 에서 빠지는지: 서버 메모리를 볼 수 없다. 코드상 최대 25초(타임아웃 → `onCompletion`) 뒤 제거된다.
- bump 와 타임아웃이 동시에 일어날 때 신호를 놓치는 경합: 재현하지 못했다.
  - 코드상 `bump` 의 `incrementAndGet` 과 `lastChange.put` 사이(`StoreChangeHub.java:30`)에 타임아웃 응답이 그 seq 를 가져가면 다음 폴링에서 그 변경을 놓칠 수 있다.
  - 창이 마이크로초 단위이고 60초 주기 확인이 보완한다. 추측이라 발견에 넣지 않았다.
- 치명 건의 20개 동시 테스트는 다른 에이전트의 동시 요청과 겹쳤다. 로그의 `waiting=33` 에는 다른 에이전트 요청도 들어 있다. 10개 대조 실험은 그보다 조용할 때 두 번 했고, 결과가 같았다.
