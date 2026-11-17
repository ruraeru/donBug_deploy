# 24 concurrency QA 보고서

## 요약
- 실행한 케이스: 22개 (같은 요청 10~20개 동시 전송, 서로 다른 요청 2개 경합). 각 케이스는 응답 코드 분포와 DB 행 수·알림 수로 확인했다.
- 통과: 6개
- 발견: 11건 (치명 1, 높음 4, 중간 5, 낮음 1)

환경: 로컬 BE `http://127.0.0.1:18080`, MySQL 8.4 `transaction_isolation = REPEATABLE-READ`(`SELECT @@global.transaction_isolation` 로 확인). 매장 A = store 41(`2579-CY5F`), 매장 B = store 80(`5GRD-LFLM`). 둘 다 `a24-owner` 가 만들었다.

### 공통 원인 (발견 2·3·4·5·7·8·9)
여러 서비스가 "먼저 일반 SELECT 로 검사하고, 그다음 저장"한다. 일부는 `findByIdForUpdate`/`lockStore`(SELECT … FOR UPDATE)로 매장 행을 잠근다. 하지만 InnoDB REPEATABLE READ 에서는 트랜잭션의 **첫 일반 SELECT 가 스냅샷을 정한다**. 그런데 모든 경로가 잠금보다 먼저 일반 SELECT 를 한다(`StoreAccess.store()` → `findById`, `findByNormalizedCode` 등). 그래서 잠금을 기다렸다가 들어온 두 번째 트랜잭션도 그 뒤의 `exists…`/`find…` 검사에서 옛 스냅샷을 읽는다. 앞 트랜잭션이 커밋한 행이 보이지 않는다. 결과적으로 잠금은 순서만 정하고 중복은 막지 못한다. `StoreWorker`, `SubstituteRequest`, `MonthSchedule` 에는 `@Version` 이 없다. `store_worker (store, worker)` 와 `substitute_request (schedule, 진행 중)` 에는 유니크 제약도 없다. 그래서 DB 도 막아 주지 않는다.

## 발견

### [치명] 롱 폴링 `/me/changes` 연결 10개가 DB 커넥션 풀을 25초 동안 다 잡아서 모든 API 가 멈춘다
- 재현:
  ```sh
  J=$(qa-user a24-poll1); K=$(qa-user a24-poll2)
  SEQ=$(curl -s "$B/me/changes?since=-1" -H "Authorization: Bearer $J" | jq .seq)
  curl -s -o /dev/null -w "%{time_total}\n" $B/me -H "Authorization: Bearer $K"      # 0.006s
  for i in $(seq 10); do curl -s -o /dev/null "$B/me/changes?since=$SEQ" -H "Authorization: Bearer $J" & done
  sleep 2; curl -s -o /dev/null -w "%{http_code} %{time_total}\n" $B/me -H "Authorization: Bearer $K"; wait
  ```
- 기대: 롱 폴링은 대기 중에 DB 커넥션을 잡지 않는다. 다른 요청은 즉시 응답한다.
- 실제: 롱 폴링 10개가 열려 있는 동안 다른 사용자의 `GET /me` 가 **23.3초** 걸렸다(평소 0.006초). 롱 폴링 10개는 모두 25.3초 뒤 200 을 받았다. 다른 에이전트의 부하가 겹친 시간대에는 `Unable to acquire JDBC Connection`/`Could not open JPA EntityManager for transaction` 500 이 쏟아졌다. 예: 매장 A 대타 승인 20개가 전부 500(로그 26건).
- 원인: `controller/MeController.java:49-52` 가 트랜잭션 없이 리포지토리를 호출한다. `spring.jpa.open-in-view` 는 설정되지 않아 기본값 true 다(시작 로그 `spring.jpa.open-in-view is enabled by default` 경고). OSIV 는 이 요청의 EntityManager 를 열어 두고, Hibernate 는 첫 쿼리에서 얻은 커넥션을 `DeferredResult` 가 끝날 때까지(최대 25초, `StoreChangeHub.await`) 들고 있는다. Hikari 기본 풀은 10개이고 `application*.yml`·compose 어디에도 풀 크기 설정이 없다.
- 영향: 앱·웹 탭은 각각 롱 폴링을 하나씩 계속 연다(CLAUDE.md 9번). 동시 접속 사용자 10명만 넘어도 운영 서버의 모든 API 가 최대 30초 지연되거나 500 이 난다. 로그인·출근도 마찬가지다. 사실상 서비스 중단이다.

### [높음] 가입 신청 동시 전송 시 같은 사용자의 PENDING 행이 여러 개 생긴다 (`FOR UPDATE` 가 효과 없음)
- 재현:
  ```sh
  J=$(qa-user a24-joiner1)
  for i in $(seq 20); do curl -s -X POST $B/stores/join-requests -H "Authorization: Bearer $J" -H 'Content-Type: application/json' -d '{"code":"2579-CY5F"}' & done; wait
  qa-sql "select mapping_id,status from store_worker sw join users u on sw.worker_id=u.user_id where u.kakao_id='qa-a24-joiner1'"
  ```
- 기대: 1개 `requested`, 나머지 `alreadyPending`. PENDING 행 1개.
- 실제: 1회차 `requested` 9개 + `alreadyPending` 10개 + 빈 본문 409 1개. PENDING 행 9개(mapping 109~117). 2회차(`a24-joiner2`)도 `requested` 7개, PENDING 행 7개(121~127). 사장님에게 가입 신청 알림(JOIN)이 행 수만큼 갔다(사장님 JOIN 알림 16건).
- 원인: `service/StoreService.java:338` 의 `findByNormalizedCode`(일반 SELECT)가 스냅샷을 먼저 정한다. 그래서 `:342` 의 `findByIdForUpdate` 로 줄을 세워도 `:346-353` 의 `existsByStoreIdAndWorkerIdAndStatus` 가 앞 요청의 커밋을 못 본다. `entity/StoreWorker.java:124` 에 따라 (store, worker) 유니크 제약도 없다.
- 영향: 앱에서 "가입 신청" 버튼을 두 번 누르거나 네트워크 재시도가 나면 사장님 가입 대기 목록에 같은 사람이 여러 번 뜬다. 이 상태에서 발견 3이 이어지면 같은 사람이 여러 직원 행이 된다.

### [높음] 같은 사람의 가입 승인이 동시에 여러 번 통과한다: 재직 행 중복, 승인 알림 중복
- 재현:
  ```sh
  O=$(qa-user a24-owner)
  # (a) 같은 staffId 20번
  for i in $(seq 20); do curl -s -o /dev/null -w "%{http_code}\n" -X POST $B/stores/41/staff/121/approve -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"wage":10320}' & done | sort | uniq -c
  # (b) 발견 2로 생긴 같은 사람의 PENDING 행 9개를 동시에
  for id in $(seq 109 117); do curl -s -o /dev/null -w "%{http_code}\n" -X POST $B/stores/41/staff/$id/approve -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"wage":10320}' & done | sort | uniq -c
  ```
- 기대: (a) 200 1개 + 409 `NOT_PENDING`, 승인 알림 1건. (b) 200 1개 + 409 `ALREADY_ACTIVE`.
- 실제: (a) 200 8개, 409 12개. 신청자에게 "가입이 승인됐어요" 알림 **8건**. (b) 200 8개. 같은 사용자(personId 419)의 **ACTIVE 행이 8개**가 됐다. 사장님 `/me/state.staff` 에 같은 사람이 8번 나오고, 알바생 `/me.memberships` 에 store 41 이 8번 나온다. 그 뒤 대타 요청의 "대타를 구해요" 동료 알림도 같은 사람에게 8건 갔다.
- 원인: `service/StaffService.java:80-95` 는 `access.staff()`(일반 SELECT)로 상태를 읽고 `:87 staffRepoActive` 도 일반 SELECT 로 검사한다. 잠금도 `@Version`(`entity/StoreWorker.java`)도 없어서 마지막에 쓴 요청이 이긴다.
- 영향: 직원 목록·근무 배정·급여 화면에 같은 사람이 여러 번 나온다. 매장 규모 AUTO 모드에서는 `syncSize`(`StoreService.java:169-171`)가 ACTIVE 행 수를 센다. 그래서 다음 동기화 때 5인 미만 사업장이 5인 이상으로 바뀌어 가산수당 계산이 틀어질 수 있다(현재 store 41 은 ACTIVE 9행인데 `is_under_5=1` 로 남아 있어 이미 값이 어긋나 있다).

### [높음] 월 근무표 자동 채우기를 동시에 보내면 고정 근무가 중복으로 들어가고, 그 달을 다시 저장할 수 없게 된다
- 재현:
  ```sh
  O=$(qa-user a24-owner)   # 매장 B(80), 직원 167 고정 파트 매일 "오픈"
  curl -s -X POST $B/stores/80/schedules -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"month":"2027-01","prefillFixed":false}'
  for i in $(seq 10); do curl -s -o /dev/null -w "%{http_code}\n" -X POST $B/stores/80/schedules/2027-01/autofill -H "Authorization: Bearer $O" & done
  qa-sql "select count(*), count(distinct work_date) from schedule where mapping_id=167 and work_date between '2027-01-01' and '2027-01-31'"
  ```
- 기대: 31일에 한 번씩 31건.
- 실제: 10개 모두 204. 근무 **124건 / 31일**(하루에 같은 08:00–12:00 "오픈" 근무 4건). 사장님 `/me/state` 에도 124건이 나온다. FE 처럼 그 달 근무 전체를 `PUT /schedules/2027-01/shifts` 로 다시 보내면 `400 SHIFT_OVERLAP "스케줄알바님의 근무 시간이 겹쳐요 (1/1 08:00–12:00)"` 이 난다. 저장이 막힌다.
- 원인: `service/MonthScheduleService.java:126-132` `autofill` 과 `:136-142` `fill` 에는 `lockStore` 가 없다. 기존 근무를 일반 SELECT 로 읽어 "빠진 것만" 넣으므로 동시 요청은 서로의 삽입을 보지 못한다. `create`(`:108-123`)도 같은 `fill` 을 잠금 없이 부른다.
- 영향: 사장님이 "자동 채우기"를 웹과 앱에서 동시에 누르거나 두 번 누르면 근무가 겹쳐 생긴다. 그 뒤로는 편집기 저장이 계속 실패한다. 겹친 근무 하나하나를 손으로 지워야 하고, 확정하면 알바생에게 같은 근무가 여러 번 보인다.

### [높음] 월 근무표 저장(`PUT /schedules/{month}/shifts`) 두 개가 겹치면 새 근무가 겹친 채로 여러 번 생긴다 (`lockStore` 효과 없음)
- 재현: 매장 B 2026-12 의 근무 31건 전체에 새 근무 1건(`{"id":"tmp-new-1","staffId":167,"date":"2026-12-15","startMin":840,"endMin":960,"part":"미들"}`)을 더한 본문을 만든다. 이 본문을 동시에 10번 PUT 한다.
  ```sh
  for i in $(seq 10); do curl -s -o /dev/null -w "%{http_code}\n" -X PUT $B/stores/80/schedules/2026-12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d @put12.json & done
  qa-sql "select schedule_id,start_min,end_min from schedule where mapping_id=167 and work_date='2026-12-15'"
  ```
- 기대: 순서대로 처리된다. 매번 이전 저장의 새 근무는 목록에 없어서 지워지고 다시 생긴다. 최종 14:00–16:00 근무는 1건이다.
- 실제: 200 9개, 500 1개(`ObjectOptimisticLockingFailureException … delete from schedule where schedule_id=? and version=?`). 같은 직원의 14:00–16:00 근무가 **7건**(1367~1373) 생겼다. 서로 겹치는데도 겹침 검사(`:292` `SHIFT_OVERLAP`)를 통과했다.
- 원인: `MonthScheduleService.java:149-151`. `access.requireOwner`(`StoreAccess.java:23-25` `findById`, 일반 SELECT)가 스냅샷을 정한 **뒤에** `monthRepo.lockStore` 를 부른다. 그래서 잠금을 얻은 뒤 `:158 findByStoreBetween` 이 앞 저장의 결과를 못 본다. 주석 "같은 매장의 동시 저장·확정을 줄 세운다"의 의도가 실현되지 않는다. `applyTemplate`(`:350-352`)과 `confirm`(`:303-306`)도 같은 순서다.
- 영향: 사장님이 웹 두 탭이나 웹+앱에서 저장하거나 저장 버튼을 연타하면 겹친 근무가 생긴다. 그러면 발견 4처럼 다음 저장이 막힌다. 확정 뒤라면 알바생 근무표에도 겹친 근무가 보인다.

### [중간] 대타 요청 동시 생성 시 한 근무에 진행 중 요청이 여러 개 생긴다
- 재현:
  ```sh
  J2=$(qa-user a24-joiner2)   # shift 1051 = 직원 121(joiner2) 2026-11-20 10:00-12:00
  for i in $(seq 20); do curl -s -o /dev/null -w "%{http_code}\n" -X POST $B/stores/41/shifts/1051/substitute-requests -H "Authorization: Bearer $J2" -H 'Content-Type: application/json' -d '{"reason":"병원","notifyPeers":true}' & done | sort | uniq -c
  qa-sql "select request_id,status from substitute_request where schedule_id=1051"
  ```
- 기대: 201 1개 + 409 `ALREADY_REQUESTED` 19개.
- 실제: 201 4개, 409 16개. OPEN 요청 4건(23~26). 사장님 알림과 동료 알림도 요청마다 나갔다.
- 원인: `service/SubstituteService.java:66` 은 일반 SELECT 로 검사하고 `:72` 에서 저장한다. 잠금도, (schedule, 진행 중) 유니크 제약도 없다.
- 영향: 같은 근무에 대타 요청 카드가 여러 개 뜬다. 하나가 승인된 뒤에도 나머지는 OPEN 으로 남는다. 승인하면 `SHIFT_CHANGED` 409 가 나므로 사장님이 하나씩 거절해야 한다.

### [중간] 대타 요청 취소와 사장님 승인이 겹치면 둘 다 성공하고 결과는 "승인"
- 재현(3회 모두 재현): 매장 B 에서 직원 167(s1) 근무에 대타 요청, s2 가 지원한 뒤 동시에:
  ```sh
  curl -X POST $B/stores/80/substitute-requests/$RQ/approve -H "Authorization: Bearer $(qa-user a24-owner)" &
  curl -X POST $B/stores/80/substitute-requests/$RQ/cancel  -H "Authorization: Bearer $(qa-user a24-s1)" & wait
  ```
- 기대: 하나만 성공하고 다른 하나는 409 `INVALID_STATE`.
- 실제: 요청 41·42·43 모두 cancel 200 + approve 200. 최종 `status=APPROVED`, 근무 담당자가 s2(175)로 바뀌었다. 알림도 서로 모순된다. 요청 41 기준으로 s2·사장님은 "대타 요청을 취소했어요"를 받았고, s1 은 "대타 요청이 승인됐어요", s2 는 "대타 근무가 확정됐어요"를 받았다.
- 원인: `SubstituteService.java:158-166`(cancel)과 `:244-262`(doApprove)가 `find()`(`:277`, 일반 SELECT)로 읽은 상태로 `requirePending` 을 검사한다. `entity/SubstituteRequest.java` 에 `@Version` 이 없어서 늦게 커밋한 쪽이 status 를 덮어쓴다.
- 영향: 알바생은 취소 성공 응답을 받아 자기가 근무한다고 믿는다. 하지만 근무는 대타에게 넘어가 있다. 결근이나 중복 출근이 생기고 급여 귀속도 바뀐다.

### [중간] 가입 승인과 거절이 겹치면 둘 다 성공하고 신청자는 두 알림을 다 받는다
- 재현(3회 모두 재현): 매장 B 에 `a24-s4`~`s6` 가입 신청 뒤 각각 동시에:
  ```sh
  curl -X POST $B/stores/80/staff/$M/approve -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"wage":10320}' &
  curl -X POST $B/stores/80/staff/$M/reject  -H "Authorization: Bearer $O" & wait
  ```
- 기대: 하나는 409 `NOT_PENDING`.
- 실제: approve 200 + reject 204. 최종 REJECTED(180·181·182). 신청자 알림은 "가입이 거절됐어요"와 "가입이 승인됐어요" 둘 다 왔다.
- 원인: `StaffService.java:80-95`, `:105-113`. 발견 3과 같다(일반 SELECT 검사, `@Version` 없음).
- 영향: 사장님 화면은 승인 성공인데 실제로는 거절됐다. 신청자는 승인 알림을 받고도 매장에 들어가지 못한다.

### [중간] 같은 달 확정을 동시에 보내면 확정 알림이 여러 번 간다 (멱등 처리가 동시 요청에서 깨진다)
- 재현:
  ```sh
  for i in $(seq 10); do curl -s -o /dev/null -w "%{http_code}\n" -X POST $B/stores/80/schedules/2026-12/confirm -H "Authorization: Bearer $O" & done
  qa-sql "select count(*),title from notification where to_user_id=1181 group by title"
  ```
- 기대: 204, 알림 1건(`:308` 주석 "멱등: 알림을 또 보내지 않는다").
- 실제: 204 10개. 알바생에게 "12월 근무표가 확정됐어요" **10건**.
- 원인: `MonthScheduleService.java:303-308`. `access.requireOwner` 가 먼저 스냅샷을 정해서 `lockStore` 뒤의 `findByStoreIdAndMonth` 가 앞 요청의 CONFIRMED 를 못 본다(공통 원인).
- 영향: 확정 버튼을 연타하면 직원 전원에게 같은 알림이 여러 번 간다.

### [중간] 동시 충돌을 409 대신 500 으로 돌려준다 (FE 는 "서버와 통신하지 못했어요 (500)"을 띄운다)
여러 동시 상황에서 DB 예외가 처리되지 않은 채 Spring 기본 오류 본문(`{"timestamp","status":500,"error":"Internal Server Error","path"}`)으로 나간다. 데이터는 대부분 지켜졌지만 응답 모양이 `{code,message}` 계약과 다르다.
- (a) refresh 토큰 동시 사용: 같은 refresh 토큰(직접 넣은 `a24-refresh` 사용자 토큰)으로 `POST /api/auth/refresh` 15개 → 200 1, 401 9, **500 5**. 로그는 `ObjectOptimisticLockingFailureException: Unexpected row count … delete from refresh_token`. 원인은 `auth/AuthService.java:96-98`: 동시에 `findByTokenHash` 한 뒤 `delete(stored)` 에서 이미 지워진 행을 지우려다 실패한다. 새 토큰 발급은 1번뿐이라 회전 자체는 지켜진다. 하지만 FE `api_client.dart:164-165` 는 401·400 만 "갱신 실패"로 보고 500 은 예외를 던진다. 같은 브라우저의 웹 탭 두 개가 동시에 갱신하면 한쪽은 500 오류 화면을 본다.
- (b) 같은 사용자가 대타 지원 20번(`/substitute-requests/23/apply`) → 200 15, **500 5**. 원인은 `Duplicate entry '23-419' for key 'uk_substitute_applicant'`(`SubstituteService.java:132-145` 검사 후 삽입).
- (c) 다른 직원 둘(s2·s3)이 같은 요청에 동시에 지원 → 3번 중 3번 한쪽이 **500**. 원인은 `Deadlock found when trying to get lock`. 지원자 행 삽입(FK 로 요청 행 S 잠금) 뒤 `:147-148` 에서 요청 행을 갱신(X 잠금)하는 순서가 서로 교착한다. 지원자는 지원했는데 오류를 받는다.
- (d) 같은 대타 승인 20번(매장 B 요청 40) → 200 1, 409 15, **500 4**(`ObjectOptimisticLockingFailureException … update schedule`). `Schedule @Version` 이 중복 교체는 막았다.
- (e) `POST /schedules {"month":"2026-12"}` 10번 → 200 1, **500 9**(`Duplicate entry '80-2026-12' for key 'uk_month_schedule_store_month'`). 원인은 `MonthScheduleService.java:108-121` 이 잠금 없이 조회 후 저장하는 것이다. 근무는 롤백돼 중복되지 않았다.
- 공통 원인: `controller/ApiExceptionHandler.java:17-41` 에 `DataIntegrityViolationException`·`ObjectOptimisticLockingFailureException`·`CannotAcquireLockException` 처리기가 없다. 재시도도 없다.
- 영향: 사용자는 정상 처리됐거나 다시 하면 되는 상황에서 "서버와 통신하지 못했어요 (500)"을 본다. (c)는 지원 자체가 실패한다.

### [낮음] 퇴근 동시 요청이 여러 번 200 을 받고 응답마다 퇴근 시각이 다르다
- 재현: 출근 중인 `a24-joiner2` 가 `POST /stores/41/attendance/clock-out` 을 20번 동시에 보낸다.
- 기대: 200 1개 + 404.
- 실제: 200 6개(clockOut 23:06:00.2277 ~ .2397, 응답마다 다름), 404 14개. DB 에는 마지막 값 1건만 남았다.
- 원인: `service/AttendanceService.java:109-121`. `findOpenByUserAndStore`(일반 SELECT) 뒤 덮어쓴다. 잠금도 `@Version` 도 없다.
- 영향: 기록은 1건이라 급여 영향은 밀리초 단위다. 화면에 보인 퇴근 시각과 저장된 값이 조금 다를 수 있다.

## 통과한 케이스
- 매장 만들기 20개 동시(`a24-owner2`): 201 20개, 매장 20개, 코드 20개 모두 다르다. 500 없음. 1인 N매장은 의도된 정책이고, FE `store_create_screen.dart:46-54`·`web_create_store_screen.dart:51-58` 가 `_busy` 로 연타를 막는다.
- 같은 근무 출근 20개 동시(shift 785): 200 20개, attendance 1건(unique `schedule_id`). 500 없음.
- 서로 다른 근무 2개에 출근 10개씩 동시(785·786): 한 근무만 출근됐고 다른 쪽은 409 `ALREADY_CLOCKED_IN` 10개. 열린 출근 기록 1건.
- 대타 승인 20개 동시(매장 B 요청 40): 근무 담당자 교체 1번, 승인 알림 1건씩(500 4개는 발견 10-(d)).
- 월 근무표 확정과 저장 동시(2027-02): 확정 204, 저장 200, "2월 확정 근무표가 바뀌었어요" 알림 1건. 결과가 정상이었다(1회 시도).
- 중복 행이 있는 사용자(joiner1)의 `/me`·`/me/state`·`/stores/41`·`/me/today`·대타 목록: 500 없이 200(목록에 중복 노출은 발견 3).

## 못 한 것
- 월 근무표 삭제(`DELETE /schedules/{month}`)와 저장의 경합, 템플릿 적용(`applyTemplate`)과 저장의 경합: 시간 관계상 못 했다. 코드상 `delete`(`MonthScheduleService.java:318-323`)는 `lockStore` 가 없고, `applyTemplate` 은 같은 "스냅샷 뒤 잠금" 순서라 발견 5와 같은 결과가 예상된다(추측이라 발견에는 넣지 않았다).
- AI 근무표 `generate/apply` 경합: 외부 LLM 호출은 10번 에이전트만 쓰기로 해서 하지 않았다.
- 확정과 저장 경합은 1회만 시도했다. 타이밍에 따라 저장 쪽이 확정 전 스냅샷을 읽으면 "확정 근무표가 바뀌었어요" 알림이 빠질 수 있다. 코드상 가능하지만 재현하지 못했다.
- refresh 테스트용 토큰은 로그인 경로(01번 전용) 대신 `refresh_token` 테이블에 내 사용자(`qa-a24-refresh`)의 해시 행을 직접 넣어 만들었다.
- 매장 A 대타 승인 20개가 모두 500 이 된 1회차는 다른 에이전트의 롱 폴링 부하로 커넥션 풀이 고갈된 시점과 겹쳤다(발견 1의 증거). 승인 경합 자체는 매장 B 에서 다시 측정했다.
- 데드락 로그 중 `update store …` 가 포함된 건(23:03:56)은 다른 에이전트 요청과 시각이 섞여 출처를 확정하지 못했다. 그래서 보고하지 않았다. 가입 신청 2회차의 빈 본문 409 1건도 같은 이유로 원인을 확정하지 못했다.
