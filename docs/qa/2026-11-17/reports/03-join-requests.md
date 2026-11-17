# 03 join-requests QA 보고서

## 요약

- 실행한 케이스: 82
- 통과: 76
- 발견: 4건 (치명 0 · 높음 2 · 중간 2 · 낮음 0)
- 테스트 데이터: 매장 A `4`(A03 카페, 코드 `KA6U-SJUD`, 사장님 `a03-owner`), 매장 B `5`(A03 빵집, 코드 `4SY6-2A6H`, 사장님 `a03-owner2`). 사용자 `a03-s1`~`a03-s4`, `a03-lone`, `a03-conc`, `a03-dup`, `a03-rej`.

공통 준비 (아래 재현에서 그대로 쓴다):

```sh
QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
B=http://127.0.0.1:18080/api/v1
OWNER=$($QA/qa-user a03-owner 김사장)
CODE=KA6U-SJUD   # a03-owner 의 매장 4 코드 (새로 만들면 POST /stores 응답의 code)
```

## 발견

### [높음] 같은 사용자가 가입 신청을 동시에 보내면 PENDING 행이 여러 개 생기고, 승인 뒤에도 앱이 가입 대기 화면으로 보낸다

- 재현:
  ```sh
  T=$($QA/qa-user a03-conc 동시)
  for i in $(seq 10); do curl -s -o /dev/null -w "%{http_code}\n" -X POST $B/stores/join-requests \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\"}" & done; wait
  $QA/qa-sql "SELECT mapping_id,status FROM store_worker WHERE worker_id=(SELECT user_id FROM users WHERE kakao_id='qa-a03-conc')"
  # 그중 마지막 행(예: 90)을 승인
  curl -s -X POST $B/stores/4/staff/90/approve -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' -d '{"wage":11000}'
  curl -s $B/me/state -H "Authorization: Bearer $T"   # staff 에 pending 83~89 + active 90
  ```
- 기대: PENDING 행 1개만 생긴다. 응답은 `201` 1번, 나머지는 `409 alreadyPending`. 사장님 알림도 1개만 생긴다.
- 실제: `201` 8번, `409` 2번이 왔다. `store_worker` 에 PENDING 행 8개(83~90)가 생겼고, 사장님 JOIN 알림도 8개 생겼다. 90 을 승인한 뒤 `/me/state` 에 `83..89 pending` 과 `90 active` 가 함께 들어 있다. `/me` 의 `memberships[0]` 도 pending 인 83 이다. 남은 83 을 승인하면 `409 ALREADY_ACTIVE` 가 오지만, 대기 행은 그대로 남는다.
- 원인: `donBug_BE/.../service/StoreService.java:338` 에서 `findByNormalizedCode` 가 먼저 일반 SELECT 를 한다. MySQL REPEATABLE READ 에서는 이 SELECT 가 트랜잭션의 스냅샷을 만든다. `:342` 의 `findByIdForUpdate` 가 매장 행을 잠가 신청을 차례로 처리하더라도, `:346`·`:350` 의 `existsByStoreIdAndWorkerIdAndStatus` 는 잠금 없는 일관된 읽기다. 그래서 먼저 끝난 신청이 넣은 PENDING 행이 보이지 않고, 잠금이 중복을 막지 못한다. `store_worker` 에는 `(store_id, worker_id, status)` 유니크 제약도 없다(`schema.sql:50-64`).
- 영향: FE `enterApp`(`donBug_FE/lib/screens/mobile_boot.dart:132-134`)은 `membership()` 의 `firstOrNull` 을 본다(`app_store.dart:305-311`). 이 함수가 pending 행 83 을 돌려주므로, 승인된 알바생이 앱을 열 때마다 "가입 신청 현황"(대기) 화면으로 간다. 사장님 직원 관리에는 같은 사람의 가입 신청이 7개 남는다. 네트워크 재시도나 두 기기에서 동시에 신청하면 생길 수 있다.

### [높음] 승인·거절이 동시에 오면 둘 다 성공한다: 같은 사람이 ACTIVE 2행이 되거나, 승인·거절 알림을 함께 받고, 데드락으로 500 이 난다

- 재현 1 (같은 행에 승인·거절 동시):
  ```sh
  T=$($QA/qa-user a03-x 엑스); curl -s -X POST $B/stores/join-requests -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\"}"
  ID=$($QA/qa-sql "SELECT mapping_id FROM store_worker WHERE worker_id=(SELECT user_id FROM users WHERE kakao_id='qa-a03-x')" | tail -1)
  for i in 1 2 3 4 5; do
    curl -s -o /dev/null -w "approve %{http_code}\n" -X POST $B/stores/4/staff/$ID/approve -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' -d '{"wage":11000}' &
    curl -s -o /dev/null -w "reject %{http_code}\n" -X POST $B/stores/4/staff/$ID/reject -H "Authorization: Bearer $OWNER" &
  done; wait
  $QA/qa-sql "SELECT title FROM notification WHERE ref_id=$ID AND store_id=4"
  ```
- 재현 2 (첫 번째 발견으로 PENDING 행이 여러 개 생긴 사용자 `a03-dup`, 행 97~104):
  ```sh
  for id in 97 98 99 100 101 102 103 104; do curl -s -o /dev/null -w "%{http_code}\n" -X POST $B/stores/4/staff/$id/approve \
    -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' -d '{"wage":11000}' & done; wait
  $QA/qa-sql "SELECT mapping_id,status FROM store_worker WHERE worker_id=(SELECT user_id FROM users WHERE kakao_id='qa-a03-dup')"
  ```
- 기대: 한 요청만 성공하고, 나머지는 `409 NOT_PENDING` 이나 `ALREADY_ACTIVE` 를 받는다. 한 사람은 매장에서 ACTIVE 행을 하나만 가진다.
- 실제:
  - 재현 1(`a03-conc` 의 행 90): 승인 `200` 3번과 거절 `204` 2번이 모두 성공했다. 최종 상태는 ACTIVE 다. 알바생은 "가입이 승인됐어요" 3개와 "가입이 거절됐어요" 2개를 함께 받았다.
  - 재현 2: 행 97 과 101 이 둘 다 `ACTIVE` 가 됐다(`200` 2번). 2건은 `500` 이 났다. BE 로그는 `CannotAcquireLockException: Deadlock found when trying to get lock` 이다. 이것은 `update store`, 즉 `syncSize` 에서 났다. 나머지는 `409 ALREADY_ACTIVE` 였다.
- 원인: `donBug_BE/.../service/StaffService.java:82`·`:107` 의 `access.staff()` 는 잠금 없이 행을 읽는다. `:83`·`:108` 은 그 값으로 상태를 확인하고 바꾼다. 그래서 확인과 변경 사이에 다른 요청이 끼어들 수 있다. `:87` 의 `staffRepoActive` 도 잠금 없는 exists 검사라 같은 경쟁이 난다. `:97` 의 `syncSize` 는 동시에 실행되면 매장 행 업데이트에서 데드락이 난다. 이 데드락 예외는 ApiException 형식으로 바뀌지 않아 500 이 된다.
- 영향:
  - 사장님이 웹과 앱에서 거의 동시에 누르거나 승인을 두 번 누르면, 알바생이 모순된 알림을 받는다.
  - 첫 번째 발견과 겹치면 한 사람이 같은 매장 직원 목록에 두 번 나온다. 이때 근무 배정, 급여, 사업장 규모(재직 인원 수) 계산이 틀어진다.

### [중간] 가입 신청 결과 404/409 를 FE 가 읽지 못한다: "매장 코드를 찾을 수 없어요"·대기 화면·매장 진입 분기가 동작하지 않는다

- 재현:
  ```sh
  T=$($QA/qa-user a03-s1 알바일)
  curl -s -w " [%{http_code}]\n" -X POST $B/stores/join-requests -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"code":"ZZZZ-ZZZZ"}'
  # {"result":"notFound","store":null} [404]
  curl -s -w " [%{http_code}]\n" -X POST $B/stores/join-requests -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\"}"   # 두 번 실행
  # {"result":"alreadyPending","store":{"id":"4","name":"A03 카페"}} [409]
  ```
- 기대: FE `requestJoinRemote`(`donBug_FE/lib/data/app_store.dart:1636-1652`)는 응답 본문의 `result` 로 결과를 가른다. `store_code_screen.dart:52-65` 의 분기는 이렇게 동작해야 한다.
  - `notFound`: "매장 코드를 찾을 수 없어요" 토스트.
  - `alreadyPending`: 가입 대기 화면.
  - `alreadyMember`: 그 매장으로 들어간다.
- 실제: BE 는 이 결과들을 `404`/`409` 로 보내고, 본문에는 `code`·`message` 가 없다. FE `ApiClient._call` 은 400 이상이면 바로 예외를 던진다(`api_client.dart:133`). `_error`(`:171-176`)는 이 경우 `ApiException(404, '404', '요청을 처리하지 못했어요')` 를 만든다. `store_code_screen.dart:44-46` 은 이 예외를 잡아 `'$e'`, 즉 "요청을 처리하지 못했어요" 토스트만 띄우고 끝낸다. 위 세 분기는 서버 모드에서 실행되지 않는다.
- 원인: `donBug_BE/.../controller/StoreController.java:89-93` 은 결과를 HTTP 상태 코드(201/404/409)로 나눈다. FE 는 2xx 본문의 `result` 를 기대한다. 계약이 다르다.
- 영향:
  - 코드를 잘못 넣은 알바생은 "요청을 처리하지 못했어요"라는 서버 오류 같은 문구를 본다.
  - 이미 신청한 알바생이 다시 입력하면 대기 화면으로 가지 못한다.
  - 사장님이 자기 매장 코드를 넣거나 이미 재직 중인 매장 코드를 넣어도 매장으로 들어가지 못하고 같은 오류 토스트만 본다.

### [중간] 거절된 뒤 가입 대기 화면에서 새로고침하면 "이 매장에 접근할 수 없어요" 가 뜨고 거절 안내가 나오지 않는다

- 재현:
  ```sh
  T=$($QA/qa-user a03-rej 거절이)
  curl -s -X POST $B/stores/join-requests -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\"}"
  ID=$($QA/qa-sql "SELECT mapping_id FROM store_worker WHERE worker_id=(SELECT user_id FROM users WHERE kakao_id='qa-a03-rej')" | tail -1)
  curl -s -w " [%{http_code}]\n" "$B/me/state?storeId=4" -H "Authorization: Bearer $T"      # 대기 중: 200
  curl -s -X POST $B/stores/4/staff/$ID/reject -H "Authorization: Bearer $OWNER"
  curl -s -w " [%{http_code}]\n" "$B/me/state?storeId=4" -H "Authorization: Bearer $T"
  # {"code":"FORBIDDEN","message":"이 매장에 접근할 수 없어요","details":null} [403]
  ```
- 기대: `JoinPendingScreen._refresh`(`donBug_FE/lib/screens/employee/join_pending_screen.dart:20-39`)는 `reload(storeId)` 뒤 내 staff 행이 `rejected` 이면 "가입이 거절됐어요. 사장님께 확인해 주세요" 를 보여 준다.
- 실제: `/me/state?storeId=4` 가 `403` 을 준다. 그래서 `reload` 가 예외를 던지고, 화면은 "이 매장에 접근할 수 없어요" 토스트만 띄운다. `storeId` 없이 읽어도 `/me/state` 의 `staff` 에는 REJECTED 행이 없다(빈 배열). 그래서 `rejected` 분기에는 어느 쪽으로도 갈 수 없다.
- 원인: `donBug_BE/.../service/StateService.java:79-80` 은 ACTIVE·PENDING 소속만 읽는다. 그래서 거절된 매장의 `storeId` 는 `:98` 에서 403 이 된다. FE 는 거절 상태를 상태 응답에서 읽으려 한다.
- 영향: 거절된 알바생이 대기 화면에서 이유를 모른 채 오류 문구만 본다. 알림 목록의 "가입이 거절됐어요" 를 따로 찾아야 알 수 있다.

## 통과한 케이스

- 정상 신청 → `201 {"result":"requested","store":{"id":"4","name":...}}`. DB 에 PENDING·최저임금 10320·첫 파트 "오픈"·매장 기본 공제(BUSINESS_TAX)·requested_at 이 저장되고, 사장님에게 JOIN 알림("알바일님이 가입을 신청했어요", ref_id=staffId)이 간다.
- 소문자·하이픈 없는 코드(`ka6usjud`) → requested
- 앞뒤 공백·중간 공백·하이픈 섞인 코드(`" ka6u - sjud "`) → requested
- 영숫자 사이에 이모지가 낀 코드 → 이모지를 무시하고 requested (대소문자·기호 무시 규칙과 일치)
- 순차 중복 신청 → `409 alreadyPending`
- 틀린 코드 / 앞 4자만 / 9자 / 한글 / 전각 문자 / 100,000자 코드 / 기호만(`----`) → `404 notFound` (500 없음)
- 빈 문자열·공백만·null·필드 없음 → `400 VALIDATION_FAILED`
- 숫자 타입 code(`12345678`) → `404 notFound`
- 배열 타입, 깨진 JSON, 빈 본문 → 400 (본문은 Spring 기본 형식. 23번 영역의 공통 문제라 따로 보고하지 않음)
- 알 수 없는 추가 필드(`storeId`) 무시
- 인증 없음 → 401
- 사장님이 자기 매장 코드로 신청 → `409 alreadyMember`, 행이 생기지 않음
- 승인된 뒤 재신청 → `409 alreadyMember`
- 승인 권한: 알바생 본인 403 / 다른 매장 사장님(경로는 매장 4) 403 / 다른 매장 사장님이 자기 매장 경로에 남의 staffId 404 / 사장님이 남의 매장 경로 403
- 승인 검증: 최저임금 미만(10319) 400 / wage 없음 400 / 문자열·거대 수 400 / 잘못된 deduction 400 / 없는 staffId 404 / 숫자 아닌 staffId 400
- 정상 승인 → `200`, status active, wage 반영, joinedAt 오늘, deduction 생략 시 매장 기본값(biz33), `insurance` 지정 반영, 알바생에게 "가입이 승인됐어요" 알림
- 두 번 승인 / 승인 후 거절 / 거절 후 승인 / 거절 두 번 / 퇴사 행 승인 → `409 NOT_PENDING`
- 거절 권한: 알바생 403, 다른 매장 사장님 403. 정상 거절 → `204`, REJECTED, 알바생에게 거절 알림
- 거절 뒤 재신청 → 새 PENDING 행 생성, 그 뒤 재신청 → alreadyPending
- 퇴사(DELETE) 뒤 `/me/state` 에서 매장이 빠짐. 재신청 → 새 PENDING 행. 재승인 → active
- 여러 매장 소속: A 재직 중 B 신청 → B pending. A 사장님은 B 행을 승인할 수 없음(404). B 사장님 승인 → 두 매장 모두 active. `/me/state?storeId=4|5` 로 매장 전환
- 사장님(B 소유)이 A 에 알바로 가입·승인 → `/me/state` 기본은 employer(B), `?storeId=4` 는 employee(A), `?storeId=5` 는 employer
- `/me/state?storeId=999`(소속 없음) → 403, `?storeId=abc` → 400
- 승인 전 알바생의 `/me/state`: 매장 정보(코드는 `""` 로 가림), 사장님 person, 자기 pending 행만 보임. 다른 직원·근무·공지·알림·근무표는 비어 있음. 이미 다른 직원이 있는 매장에서도 새지 않음
- 승인 전 알바생 접근: `/stores/4`, `/code`, `/staff`, 다른 직원 상세, `/notices`, `/shifts`, `/dashboard`, `/qr-token`, `/substitute-requests` → 모두 403. 자기 staff 상세(`/staff/19`)만 200
- 무소속 사용자: `/stores/4`, `/staff`, `/notices` → 403
- 사장님 `/me/state`: pending 신청이 보이고, 같은 사람의 rejected 행과 새 pending 행이 함께 와도 FE `pendingStaff`·`membership` 이 rejected 를 걸러 냄
- 거절 시 대기 중 알바생의 `/me/changes` 롱 폴링이 약 0.1초 안에 `changed:true` 로 깨어남 (PENDING 소속 매장 구독 확인)

## 못 한 것

- 실제 앱·웹 화면 조작: 웹 컨테이너가 없어 FE 동작은 코드(`store_code_screen.dart`, `join_pending_screen.dart`, `mobile_boot.dart`, `api_client.dart`)로 판단했다.
- 매장 코드 재발급: 해당 API 를 찾지 못했다. 그래서 "코드가 바뀐 뒤 옛 코드로 신청"은 테스트하지 않았다.
- 매니저(kind=manager)의 승인: BE 가 `requireOwner` 로 막는 것만 코드에서 확인했다. 매니저 직원을 만드는 흐름은 04번 영역이라 요청으로 확인하지 않았다.
- 동시성 원인 중 "REPEATABLE READ 스냅샷" 설명은 코드와 MySQL 동작으로 판단한 것이다. SQL 로그로 직접 확인하지는 않았다. 중복 행 생성 자체는 여러 번 재현했다.
- 테스트로 생긴 데이터(중복 PENDING·ACTIVE 행 등)는 매장 4 에 남겨 두었다. 지우기 권한은 쓰지 않았다.
