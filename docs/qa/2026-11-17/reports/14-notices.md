# 14 notices QA 보고서

## 요약
- 실행한 케이스: 76개 (작성 11, 작성 권한 6, 목록 7, 상세 6, 읽음·전체 읽음 11, 읽음 현황 4, 재알림 5, 길이·문자 경계 10, 가입 전 공지 5, 퇴사·재가입 3, `/me/state` 5, 동시 요청 3)
- 통과: 69개
- 발견: 7건. 치명 0, 높음 0, 중간 1, 낮음 6.
- 서버 오류(500): 공지 API 에서는 없었다. 로그에 보인 `Deadlock` 은 다른 에이전트의 `update store` 요청이다.

준비한 데이터 (모두 `a14-` 접두사)
- 매장 A `S=24` (사장 `a14-owner`, 코드 `2WRD-W6PP`): 재직 `a14-s1`(47)·`a14-s2`(48)·`a14-s4`(50), 퇴사 `a14-s3`(49), `a14-pend`(51 승인 → 퇴사, 140 재신청 대기)
- 매장 B `S2=25` (사장 `a14-owner2`): `a14-s4`(52, 두 매장 소속)
- 무소속 `a14-out`
- 아래 curl 에서 `$B=http://127.0.0.1:18080/api/v1`, `$OWNER=$(qa-user a14-owner)` 처럼 label 로 토큰을 받는다.

## 발견

### [중간] 재알림 1시간 제한을 FE 가 몰라서 성공 화면과 실패 토스트가 함께 뜬다
- 재현:
  ```sh
  N=$(curl -s -X POST $B/stores/24/notices -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' \
      -d '{"title":"필독","body":"x","required":true}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
  curl -s -X POST $B/stores/24/notices/$N/remind -H "Authorization: Bearer $OWNER"   # {"sent":3} 200
  curl -s -X POST $B/stores/24/notices/$N/remind -H "Authorization: Bearer $OWNER"   # 409
  ```
- 기대: 1시간 안에는 FE 가 재알림 버튼을 막거나, 서버 결과를 기다렸다가 알린다.
- 실제: 두 번째 요청은 `409 {"code":"REMIND_TOO_SOON","message":"방금 알렸어요. 1시간 뒤에 다시 알릴 수 있어요"}`. 그런데 FE 는 서버 응답 전에 결과를 정한다.
  - 앱 `notice_read_status_screen.dart:87-101`: "미확인자에게 리마인드" 버튼은 `unread` 가 있고 필독이면 늘 보인다. 누르면 `NoticeResultScreen(reminded)` 로 바로 넘어가 "아직 확인하지 않은 OO님께만 알림이 갔어요" 를 보여 준다.
  - 웹 `web_notice_screen.dart:31-34`: 토스트 "N명에게 다시 알렸어요" 를 바로 띄운다.
  - 그 뒤 `_remote` 가 409 를 받아 `remoteError` 토스트를 따로 띄운다(`app_store.dart:225-239`). 실제 알림은 가지 않는다.
- 원인: BE `NoticeService.java:139-141` 의 쿨다운을 FE `remindUnread`(`app_store.dart:1835-1844`)가 모른다. `remindedAt` 은 상태에 있지만 버튼 조건(`notice_read_status_screen.dart:87`, `web_notice_screen.dart:109`)에 쓰지 않는다.
- 영향: 사장님은 "알림이 갔다" 는 화면과 "1시간 뒤에" 오류를 함께 본다. 실제로 갔는지 알 수 없다.

### [낮음] 재알림을 동시에 보내면 쿨다운을 뚫고 알림이 중복된다
- 재현:
  ```sh
  for i in $(seq 1 10); do curl -s -X POST $B/stores/24/notices/$N/remind -H "Authorization: Bearer $OWNER" & done; wait
  qa-sql "SELECT to_user_id, count(*) FROM notification WHERE ref_id=$N AND title='필독 공지를 확인해 주세요' GROUP BY 1"
  ```
- 기대: 한 번만 `{"sent":3}`, 나머지는 409. 직원마다 알림 1개.
- 실제: 10개 중 3개가 `200 {"sent":3}`, 7개가 409. 직원 3명이 같은 재알림을 3개씩 받았다(공지 13, user 112·113·115 각 3건).
- 원인: `NoticeService.java:133-149` 가 `remindedAt` 을 읽고 검사한 뒤 쓰는데 잠금이 없다(`Notice` 에 `@Version`·비관적 잠금 없음). 동시 트랜잭션이 모두 `remindedAt == null` 을 본다.
- 영향: 웹 "다시 알리기" 버튼(`web_notice_screen.dart:110-111`)은 연타 방지가 없어 더블클릭만으로 직원이 같은 알림을 여러 개 받는다.

### [낮음] 웹 공지 작성 "올리기" 연타 시 공지·알림이 중복된다
- 재현:
  ```sh
  for i in 1 2; do curl -s -X POST $B/stores/24/notices -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' \
      -d '{"title":"이중클릭","body":"x","required":false}' & done; wait
  qa-sql "SELECT count(*) FROM notice WHERE store_id=24 AND title='이중클릭'"        # 2
  qa-sql "SELECT count(*) FROM notification WHERE store_id=24 AND body='이중클릭'"   # 6 (직원 3명 x 2)
  ```
- 기대: 한 번 클릭에 공지 1개.
- 실제: 공지 id 15·16 두 개, 알림 6개.
- 원인: 웹 `web_notice_screen.dart:243-254` 의 "올리기" 는 `await publishNoticeRemote` 동안 버튼을 막지 않는다. `WebButton`(`web_common.dart`)에도 진행 중 상태가 없다. 앱 화면은 `_sending` 으로 막는다(`employer_notice_screen.dart:39-40`). BE 에도 중복 방지가 없다.
- 영향: 응답이 느릴 때 두 번 누르면 같은 공지가 두 개 올라가고 직원이 알림을 두 번 받는다.

### [낮음] 필독 확인 비율의 분모에 "가입 전 공지" 대상이 아닌 직원이 들어간다
- 재현 (가입일보다 이른 공지가 필요해 DB 로 만듦):
  ```sh
  qa-sql "UPDATE notice SET created_at='2026-11-10 10:00:00' WHERE notice_id=2 AND store_id=24; UPDATE store_worker SET joined_at='2026-11-15' WHERE mapping_id IN (47,48,50)"
  curl -s $B/stores/24/notices/2 -H "Authorization: Bearer $OWNER"
  ```
- 기대: 화면마다 같은 읽음 수.
- 실제: BE 는 `"readBy":{"48":...},"unreadCount":0`. 재직 직원은 3명이다. FE 화면은 서로 다른 값을 보여 준다.
  - 앱 공지 목록(`employer_notice_screen.dart:201`): `targets - unreadStaffOf` = "읽음 3/3".
  - 앱 필독 확인 현황(`notice_read_status_screen.dart:20-24`): `read.length / activeStaff.length` = 1/3(33%). 미확인 목록은 0명이다.
  - 웹 공지 관리(`web_notice_screen.dart:41-43`): 비율 33%.
- 원인: `unreadStaffOf`·BE `unreadCount` 는 가입 전 공지를 뺀다(`NoticeService.java:157-158`, `app_store.dart:1829-1832`). 비율 계산은 재직 직원 전원을 분모로 쓴다.
- 영향: 대상 직원이 모두 읽어도 진행률이 100% 가 안 된다. 미확인 0명인데 33% 로 보여 사장님이 헷갈린다.

### [낮음] `read-status` 의 `read` 목록에 퇴사자가 남는다
- 재현:
  ```sh
  curl -s -X POST $B/stores/24/notices/1/read -H "Authorization: Bearer $(qa-user a14-pend)"   # 재직 중 읽음
  curl -s -X DELETE $B/stores/24/staff/51 -H "Authorization: Bearer $OWNER"                    # 퇴사
  curl -s $B/stores/24/notices/1/read-status -H "Authorization: Bearer $OWNER"
  ```
- 기대: `read`·`unread` 모두 재직 직원 기준(설계서 §4.8: "재직 직원 중 readBy 에 없는 사람이 unread").
- 실제: `read` 에 퇴사한 `staffId 51` 이 들어 있다. 재직 3명인데 `read` 3명 + `unread` 1명 = 4명.
- 원인: `NoticeService.java:125-128` 은 `read` 를 걸러내지 않는다. `unread` 만 `activeStaff` 로 거른다(`:190-193`). 목록·`/me/state` 의 `readBy` 도 퇴사자를 담는다(`:52-55`).
- 영향: 현재 FE 는 이 API 를 안 쓰고 `/me/state` 에서 재직 직원으로 다시 거른다. 그래서 화면 영향은 없다. API 를 직접 쓰는 쪽은 읽은 수를 크게 센다.

### [낮음] 작성 검증 오류 응답이 설계와 다르고 FE 가 읽을 수 없는 모양이 섞인다
- 재현:
  ```sh
  curl -s -X POST $B/stores/24/notices -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' -d '{"title":"  ","body":"x"}'
  curl -s -X POST $B/stores/24/notices -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' -d '{"title":"t"}'
  curl -s -X POST $B/stores/24/notices -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' -d '{"title":"t","body":"x","category":"기타"}'
  curl -s -X POST $B/stores/24/notices -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' -d '{"title":"t","body":"x","required":"yes"}'
  ```
- 기대: 설계서 §4.8 대로 `400 "제목과 내용을 입력해 주세요"`. 다른 오류도 `{code,message}` 모양.
- 실제:
  - 빈 제목·내용: `{"code":"VALIDATION_FAILED","message":"요청 값이 올바르지 않아요","details":{"content":"must not be blank"}}`. 필드 이름이 FE 키 `body` 가 아니라 `content` 다.
  - 잘못된 category·타입: Spring 기본 본문 `{"timestamp":...,"status":400,"error":"Bad Request","path":...}`. `code`·`message` 가 없다. BE 가 만든 문구 "알 수 없는 값이에요: '기타'" 는 로그에만 남는다.
- 원인: `NoticeDto.java:26-31` 의 `@NotBlank` 가 컨트롤러(`NoticeController.java:46` `@Valid`)에서 먼저 걸린다. 그래서 `NoticeService.java:84-86` 의 `NOTICE_REQUIRED_FIELDS` 는 실행되지 않는다. `HttpMessageNotReadableException` 은 공통 예외 처리기를 거치지 않는다.
- 영향: FE 는 앞에서 빈 값을 막아 화면 영향은 작다. API 쓰는 쪽은 오류 문구가 일정하지 않다.

### [낮음] 길이 제한이 trim 전·UTF-16 단위로 걸리고 FE 에는 제한이 없다
- 재현:
  ```sh
  # 제목: 앞뒤 공백 + '가' 199자 = 201자. trim 하면 199자인데 거부
  python3 -c "import json;print(json.dumps({'title':' '+'가'*199+' ','body':'x','required':False}))" > /tmp/t.json
  curl -s -X POST $B/stores/24/notices -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' -d @/tmp/t.json
  # 본문: 이모지 2600자(눈에 보이는 글자 2600개)인데 "5000자까지" 로 거부
  python3 -c "import json;print(json.dumps({'title':'e','body':'😀'*2600,'required':False}))" > /tmp/e.json
  curl -s -X POST $B/stores/24/notices -H "Authorization: Bearer $OWNER" -H 'Content-Type: application/json' -d @/tmp/e.json
  ```
- 기대: trim 뒤 길이로 판단. 글자 수 기준을 FE 입력칸과 맞춤.
- 실제: 첫 요청 `400 VALIDATION_FAILED "size must be between 0 and 200"`. 둘째 요청 `400 NOTICE_TOO_LONG "공지 내용은 5000자까지 쓸 수 있어요"`.
- 원인: `NoticeDto.java:27` `@Size(max=200)` 는 trim 전 값을 본다. `NoticeService.java:88` 은 `String.length()`(UTF-16)를 쓴다. 이모지 1개를 2자로 센다. FE 입력칸(`employer_notice_screen.dart`, `web_notice_screen.dart:208-210`)에는 `maxLength` 가 없다.
- 영향: 제목 201자 이상이면 사장님은 "요청 값이 올바르지 않아요" 만 보고 이유를 모른다. 본문 제한은 문구와 다르게 걸린다.

## 통과한 케이스
- 작성: 필독 지정, `required`·`category` 생략 시 매장 기본값(필독)·"일반", "노무"·"중요" 와 코드값 `IMPORTANT` 입력, 제목·본문 앞뒤 공백 trim.
- 작성 부수효과: 재직 직원(112·113·115)에게만 알림이 간다. 퇴사자(114)·대기자(116)는 받지 않는다. 문구는 "새 필독 공지"/"새 공지", body 는 제목, `ref_id` 는 공지 id.
- 작성 권한: 직원 403, 다른 매장 사장 403, 퇴사자 403, 인증 없음 401, 없는 매장 404, 숫자 아닌 storeId 400.
- 경계값: 제목 200자 통과·201자 400, 본문 5000자 통과·5001자 `NOTICE_TOO_LONG`, 본문 5000자 + 뒤 공백(trim 후 5000) 통과, 20만 자 400, 이모지 제목 100개 통과.
- 문자 처리: HTML·SQL 조각·제어문자(`\u0007`)를 그대로 저장하고 JSON 으로 안전하게 이스케이프한다.
- 깨진 JSON·빈 본문은 400 이고 500 은 없다.
- 목록: 사장님은 전원 `readBy`·`unreadCount` 를 받는다. 직원은 본인 `readBy` 만 받고 `unreadCount:null` 이다. 정렬은 최신순이고 `pinned` 는 늘 false 다.
- 목록 권한: 퇴사자·대기자·무소속·다른 매장 사장 403. 두 매장 소속 직원은 다른 매장 공지가 비어 있다(새지 않음).
- 상세: 직원 조회 정상. 다른 매장 경로로 이 매장 공지 id 를 주면 404. 무소속 403, 퇴사자 403, 없는 id 404, 숫자 아닌 id 400.
- 읽음: 첫 읽음 204, 두 번째도 204 멱등(DB 1행). 사장님·퇴사자·대기자 403, 다른 매장 경로 404, 없는 id 404.
- 전체 읽음: 직원 204(DB 공지 4개 반영), 반복 멱등, 사장님·무소속 403.
- 읽음 후 반영: 직원 `unreadNoticeCount`, 사장님 `unreadCount`, `readBy` 시각이 DB 와 일치한다.
- 읽음 현황: 사장님 정상. 직원·다른 매장 사장 403, 없는 id 404.
- 재알림: 필독 아님 409 `NOT_REQUIRED`, 직원·다른 매장 사장 403. 정상 재알림은 안 읽은 사람(115)에게만 1건. `remindedAt` 반영, 1시간 안 재요청 409.
- 가입 전 공지: 직원에게 `isRead:true` 이고 미확인 수에서 빠진다. 사장님 `unreadCount:0`, 재알림 `sent:0`, read-status `unread:[]`.
- 승인 당일 이전에 올라온 공지는 이후 승인된 직원에게 "안 읽음" 이다(날짜 기준). FE `_noticeBeforeJoin` 과 같은 규칙이다.
- 퇴사 후 재신청은 새 mapping(140)이 생긴다. 예전 읽음 기록은 옛 mapping 에 남는다.
- `/me/state`: `v:4`. 공지 키가 FE `Notice.fromJson` 과 일치하고 id·storeId 는 문자열, `readBy` 는 늘 맵이다(빈 맵 포함). 대기자는 매장은 받고 공지는 0개라 403 으로 깨지지 않는다. 퇴사자는 매장 0개, 두 매장 직원은 두 매장 공지를 합쳐 받는다.
- 동시 요청: 같은 공지 읽음 15개, 전체 읽음 5개를 동시에 보내도 `INSERT IGNORE` 로 중복 행이 없다.

## 못 한 것
- 직원이 실제로 사장님 화면을 쓰는지 UI 확인: 웹 컨테이너가 없다. FE 코드를 읽어서 판단했다.
- `pinned` 변경: API 가 없다(설계서에 "항상 false" 명시).
- 사장님이 자기 매장의 직원도 겸하는 경우: 가입 신청 영역(03)에서 막히는지 정해진다. 여기서는 만들지 않았다.
- 실제 1시간 경과 뒤 재알림: 기다리지 않았다. 코드(`NoticeService.java:139`)로만 확인했다.
- `/me/changes` 공지 신호: 21번 영역 범위라 보지 않았다.
