# 23 robustness QA 보고서

## 요약

- 실행한 케이스: 약 150개 (쓰기 엔드포인트 전반 + 일부 조회 파라미터)
- 통과: 약 125개
- 발견: 12건 — 치명 0 · 높음 1 · 중간 5 · 낮음 6
- 사용자: `a23-owner`(로버사장, 매장 31 `4PSJ-9AHC`), `a23-staff1`(로버알바, staff id 82)
- 공통 준비

```sh
QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
B=http://127.0.0.1:18080/api/v1
O=$($QA/qa-user a23-owner 로버사장); S=$($QA/qa-user a23-staff1 로버알바)
J=(-H 'Content-Type: application/json')
curl -s -XPOST $B/stores -H "Authorization: Bearer $O" "${J[@]}" -d '{"name":"a23 매장","address":"서울 a23"}'   # → id 31, code 4PSJ-9AHC
curl -s -XPOST $B/stores/join-requests -H "Authorization: Bearer $S" "${J[@]}" -d '{"code":"4PSJ-9AHC"}'
curl -s -XPOST $B/stores/31/staff/82/approve -H "Authorization: Bearer $O" "${J[@]}" -d '{"wage":10320}'
```

## 발견

### [높음] `POST /schedule-plans` 의 `needs` 상한이 없어 요청 하나가 몇 시간 동안 CPU 를 붙잡는다

- 재현:
  ```sh
  # 7일·need 10,000,000 → 24.7초 (1,000,000 → 2.4초, 선형)
  curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -XPOST $B/stores/31/schedule-plans \
    -H "Authorization: Bearer $O" "${J[@]}" \
    -d '{"from":"2026-12-01","to":"2026-12-07","needs":[10000000,0,0],"copyLastWeek":false}'
  ```
  (`needs:[2147483647]`, 366일은 서버를 멈출 수 있어서 보내지 않았다. 측정값으로 보면 수천 시간이 걸린다.)
- 기대: 필요 인원에 상한을 두고(예: 직원 수 또는 100) 넘으면 400.
- 실제: 200. 처리 시간이 `need × 일수` 에 비례한다. 1e7·7일 = 24.7초.
- 원인: `service/ShiftService.java:276` 은 null·음수만 막는다. `ShiftService.java:553` `for (long k = have; k < need; k++)` 는 `stopWhenEmpty=false`(`:295`) 라서 채울 사람이 없어도 `unfilled++` 하고 `need` 번 끝까지 돈다. 매번 `all` 스트림도 다시 돈다. `PUT /parts`·`PUT /parts/needs` 의 `need` 도 상한이 없다(`StoreService.java:195`). 저장된 need 는 `/schedule-plans/{id}/apply` 에서 그대로 쓰인다.
- 영향: 로그인한 사용자는 누구나 매장을 만들면 사장님이 된다. 그래서 요청 몇 개로 Tomcat 스레드와 CPU 코어를 무기한 묶을 수 있다(서비스 중단 가능). 웹에서 필요 인원 입력에 큰 수를 잘못 넣어도 화면이 멈춘 것처럼 보인다.

### [중간] 시급 상한이 없어 급여 계산이 int 오버플로로 음수가 된다

- 재현:
  ```sh
  curl -s -XPATCH $B/stores/31/staff/82 -H "Authorization: Bearer $O" "${J[@]}" -d '{"wage":2147483647}'
  curl -s -XPOST $B/stores/31/shifts -H "Authorization: Bearer $O" "${J[@]}" -d '{"date":"2026-12-01","startMin":600,"endMin":700,"staffIds":[82]}'
  curl -s "$B/stores/31/labor-cost?year=2026&month=12&projected=true" -H "Authorization: Bearer $O"
  curl -s "$B/stores/31/staff/82/payslips/2026-12?projected=true" -H "Authorization: Bearer $O"
  ```
- 기대: 비현실적인 시급은 400. 아니면 계산을 long 으로 한다.
- 실제: PATCH 200. 인건비는 `{"total":-1431655769}`, 명세서는 `"base":-1431655769,"deduction":-47244640,"net":-1384411129`.
- 원인: `dto/StaffCommandDto.java:18,23` 은 `@Min` 만 있고 `@Max` 가 없다. 계약서 `dto/ContractDto.java` `wage` 도 마찬가지다. `service/TimeUtil.java:72` `(int) Math.round(minutes * (double) hourlyWage / 60.0)` 가 long 을 int 로 자르면서 값이 넘친다. `PayrollCalculator.java:106` 이후 합계도 int 다.
- 영향: 시급에 0을 몇 개 더 넣는 오타(예: 1억)만으로 한 달 급여가 21억 원을 넘어 음수 급여·음수 공제가 나온다.

### [중간] 휴게 시간이 근무 길이보다 길어도 받아 근무 시간이 음수가 된다 (단건 근무·파트)

- 재현:
  ```sh
  curl -s -XPOST $B/stores/31/shifts -H "Authorization: Bearer $O" "${J[@]}" \
    -d '{"date":"2026-12-02","startMin":600,"endMin":700,"staffIds":[82],"breakMin":100000}'
  # → "breakMin":100000,"scheduledMinutes":-99900
  curl -s -XPATCH $B/stores/31/shifts/687 -H "Authorization: Bearer $O" "${J[@]}" -d '{"breakMin":5000}'
  # → "scheduledMinutes":-4900
  curl -s -XPUT $B/stores/31/parts -H "Authorization: Bearer $O" "${J[@]}" \
    -d '{"parts":[{"name":"a","startMin":0,"endMin":60,"breakMin":99999}]}'   # 200
  ```
- 기대: 월 저장(`PUT /schedules/{m}/shifts`)과 같이 `breakMin > 근무 길이` 면 400 `INVALID_BREAK`.
- 실제: 201/200. `/me/state` 근무에도 `breakMin:100000` 이 그대로 실린다. FE `models.dart:604` `scheduledMinutes = endAbs - startMin - breakMin` 이 음수가 되어 근무표 합계·대시보드 통계가 줄어든다. 급여는 `PayrollCalculator.java:90` 에서 0으로 막혀 그날 0원이 된다.
- 원인: `dto/ShiftCommandDto.java:27,43` 은 `@Min(0)` 만 있다. `ShiftService.create/update` 는 시작=종료만 검사한다(`ShiftService.java:465`). 파트는 `StoreService.java:195` 가 음수만 막는다. 월 저장은 `MonthScheduleService.java:197` 에서 막으므로 경로마다 다르게 동작한다.
- 영향: 사장님이 휴게를 잘못 넣으면 근무 시간·인건비 합계가 틀리게(음수로) 보인다.

### [중간] 목록 안의 null 원소로 500 (3곳)

- 재현:
  ```sh
  curl -s -XPUT $B/stores/31/schedules/2027-01/shifts -H "Authorization: Bearer $O" "${J[@]}" -d '{"shifts":[null]}'
  curl -s -XPUT $B/stores/31/parts -H "Authorization: Bearer $O" "${J[@]}" -d '{"parts":[null]}'
  curl -s -XPOST $B/stores/31/schedule-plans -H "Authorization: Bearer $O" "${J[@]}" \
    -d '{"from":"2026-12-01","to":"2026-12-02","needs":[1,1,1],"copyLastWeek":false,"excludeStaffIds":[null]}'
  ```
- 기대: 400 `{code,message}`.
- 실제: 셋 다 500 `{"timestamp":..,"status":500,"error":"Internal Server Error"}`.
- 원인:
  - `service/MonthScheduleService.java:180` `numericId(it.id())`: `it` 가 null 이라 NPE. `@Valid List<ShiftItem>` 는 null 원소를 거르지 않는다.
  - `service/StoreService.java:188` `it.name()` NPE (로그: `Cannot invoke "StorePartDto$Item.name()" because "it" is null`).
  - `service/ShiftService.java:280` `Set.copyOf(...)` 는 null 원소가 있으면 NPE.
- 영향: FE 는 이런 본문을 만들지 않는다. 다만 잘못된 클라이언트·스크립트가 보내면 500 이 나고 서버 오류 로그가 쌓인다.

### [중간] DB 컬럼 길이를 넘는 문자열·날짜로 500 (DTO 길이 검증 누락)

- 재현:
  ```sh
  P51=$(printf 'x%.0s' {1..51}); N101=$(python3 -c "print('가'*101)")
  # (a) 월 저장 part 51자 → schedule.part varchar(50)
  curl -s -XPUT $B/stores/31/schedules/2027-01/shifts -H "Authorization: Bearer $O" "${J[@]}" \
    -d "{\"shifts\":[{\"staffId\":82,\"date\":\"2027-01-08\",\"startMin\":600,\"endMin\":700,\"part\":\"$P51\"}]}"
  # (b) 템플릿 이름 101자 → schedule_template.name length 100
  curl -s -XPOST $B/stores/31/schedule-templates -H "Authorization: Bearer $O" "${J[@]}" -d "{\"name\":\"$N101\",\"month\":\"2027-01\"}"
  # (c) 근태 수정 사유 25,000자(75KB) → notification.body TEXT(64KB) 초과
  python3 -c "import json;print(json.dumps({'reason':'가'*25000}))" > big.json
  curl -s -XPATCH $B/stores/31/attendance/118 -H "Authorization: Bearer $O" "${J[@]}" --data-binary @big.json
  # (d) 대타 사유 25,000자 → substitute_request.reason TEXT 초과
  curl -s -XPOST $B/stores/31/shifts/691/substitute-requests -H "Authorization: Bearer $S" "${J[@]}" --data-binary @big.json
  # (e) 보건증 alertDays 2000개 → users.cert_alert_days varchar(50)
  curl -s -XPUT $B/me/health-cert -H "Authorization: Bearer $S" -F expiry=2027-01-01 \
    -F "alertDays=$(python3 -c "print(','.join(map(str,range(2000))))")" -F photo=@a.png
  # (f) 날짜 연도 10000 → MySQL DATE 범위 밖
  curl -s -XPOST $B/stores/31/shifts -H "Authorization: Bearer $O" "${J[@]}" -d '{"date":"+10000-01-01","startMin":600,"endMin":700,"staffIds":[82]}'
  ```
  (attendance 118 은 shift 690(0001-01-01)에 `POST /shifts/690/attendance` 로 만든 기록이다.)
- 기대: 400 `VALIDATION_FAILED` 또는 도메인 코드.
- 실제: 모두 500. 로그: `Data too long for column 'part'` / `'body'` 등, `Incorrect date value: '10000-01-01' for column 'work_date'`.
- 원인:
  - (a) `dto/MonthScheduleCommandDto.java:31` `String part` 에 `@Size(max=50)` 이 없다. 단건 근무 DTO 에는 있다.
  - (b) `MonthScheduleCommandDto.java:73` `name` 에 `@Size` 가 없다(`entity/ScheduleTemplate.java:27` length 100).
  - (c) `dto/AttendanceViewDto.java:69` `reason` 에 `@Size` 가 없다. 사유는 `AttendanceService.java:179` 에서 알림 본문(`Notification.body` TEXT)으로도 저장된다.
  - (d) `dto/SubstituteRequestDto.java:26-27` `reason` 에 `@Size` 가 없다.
  - (e) `service/DocumentService.java:55` 가 개수·길이를 검사하지 않는다.
  - (f) 날짜 범위 검사가 없다(`ShiftCommandDto.java:21`).
- 영향: (b)는 FE 템플릿 이름 입력에 maxLength 가 없어(`grep maxLength` 결과 없음) 실제 사용자가 긴 이름을 넣으면 "요청을 처리하지 못했어요"만 보고 원인을 모른다. 나머지는 비정상 입력에서만 나는 500 이다.

### [중간] 프레임워크 단계 오류와 인증 오류의 응답 형식이 FE `ApiClient` 계약 `{code,message}` 과 다르다

- 재현:
  ```sh
  curl -s -XPOST $B/stores -H "Authorization: Bearer $O" "${J[@]}" -d '{"name":'            # 깨진 JSON
  curl -s -XPOST $B/stores -H "Authorization: Bearer $O" "${J[@]}" -d '{"name":"x","address":"y","isSmall":"abc"}'  # 타입 오류
  curl -s -XPOST $B/stores -H "Authorization: Bearer $O" "${J[@]}" -d '{"name":"x","address":"y","defaultDeduction":"NOPE"}'  # enum
  curl -s $B/stores/abc -H "Authorization: Bearer $O"                                       # 숫자 아닌 path id
  curl -s -XPOST $B/stores -H "Authorization: Bearer $O" -H 'Content-Type: text/plain' -d x # 415
  curl -s -XDELETE $B/stores/31 -H "Authorization: Bearer $O"                               # 405
  curl -s "$B/stores/31/schedule/tbd-count" -H "Authorization: Bearer $O"                   # 필수 파라미터 누락
  curl -s -XPOST http://127.0.0.1:18080/api/auth/kakao/token "${J[@]}" -d '{"accessToken":"wrong"}'   # 401
  ```
- 기대: 모든 오류가 `{code, message, details}` (설계서 §1.5, `ApiExceptionHandler` 주석).
- 실제:
  - 처음 7개: Spring 기본 `{"timestamp":..,"status":400,"error":"Bad Request","path":..}` (415·405·404 도 같은 모양).
  - 인증 오류: `{"error":"Invalid Kakao access token"}` / `{"error":"Invalid refresh token"}`.
  - 500 도 전부 Spring 기본 형식이다.
- 원인: `controller/ApiExceptionHandler.java` 는 `ApiException`·`MaxUploadSizeExceededException`·`BindException` 만 처리한다. `HttpMessageNotReadableException`, `MethodArgumentTypeMismatchException`, `MissingServletRequestParameterException`, `HttpMediaTypeNotSupportedException`, `HttpRequestMethodNotSupportedException`, `DataIntegrityViolationException`, 그 밖의 `Exception` 처리기가 없다. `auth/AuthExceptionHandler.java:16` 은 `Map.of("error", ..)` 를 돌려준다.
- 영향: FE `api_client.dart` `_error` 는 JSON 파싱에 성공하지만 `code`·`message` 가 없다. 그래서 `code` 는 `"400"`, 메시지는 늘 "요청을 처리하지 못했어요"가 된다. 앱 테스트 계정 로그인에서 토큰이 틀리면 "테스트 로그인 실패: 요청을 처리하지 못했어요"로 보인다(`mobile_boot.dart:116`). 원인 안내가 사라지고, 화면에서 code 로 분기할 수 없다.

### [낮음] 검증 오류 `details` 가 영어 기본 메시지·Java 예외 문구·Java 필드명으로 나온다

- 재현:
  ```sh
  curl -s -XPOST $B/stores/31/staff/82/approve -H "Authorization: Bearer $O" "${J[@]}" -d '{"wage":null}'
  # details: {"hourlyWage":"must not be null"}   (FE 키는 wage)
  curl -s -XPOST $B/stores/31/notices -H "Authorization: Bearer $O" "${J[@]}" -d '{"title":null,"body":null}'
  # details: {"content":"must not be blank",...}  (FE 키는 body)
  curl -s -XPUT $B/me/health-cert -H "Authorization: Bearer $S" -F expiry=2027-02-30 -F alertDays=30 -F photo=@a.png
  # details.expiry: "Failed to convert property value of type 'java.lang.String' to required type 'java.time.LocalDate' ..."
  ```
- 기대: 한국어 메시지, FE 계약 키.
- 실제: 위와 같다. `message` 는 "요청 값이 올바르지 않아요"로 통일되어 있어 화면 영향은 작다.
- 원인: `ApiExceptionHandler.java:34` 가 `f.getField()`·`f.getDefaultMessage()` 를 그대로 쓴다. DTO 대부분이 `message=` 를 지정하지 않는다.
- 영향: FE 는 지금 `details` 를 읽지 않는다. 내부 클래스명이 응답에 노출된다.

### [낮음] `PUT /parts/needs` 의 배열 길이가 파트 수와 달라도 200

- 재현: `curl -s -XPUT $B/stores/31/parts/needs -H "Authorization: Bearer $O" "${J[@]}" -d '{"needs":[1]}'` (파트 3개). `[]`, 7개도 200.
- 기대: 길이가 다르면 400.
- 실제: 200. 앞에서부터 있는 만큼만 반영하고 나머지는 조용히 무시한다.
- 원인: `StoreService.applyNeeds` 가 길이를 비교하지 않는다.
- 영향: 클라이언트와 서버의 파트 순서·개수가 어긋나도 오류 없이 엉뚱한 파트에 인원이 들어갈 수 있다.

### [낮음] 단건 근무 생성은 매장에 없는 파트 이름도 받는다

- 재현: `curl -s -XPOST $B/stores/31/shifts -H "Authorization: Bearer $O" "${J[@]}" -d '{"date":"2026-12-04","startMin":600,"endMin":700,"staffIds":[82],"part":"<b>없는</b>"}'` → 201, `"part":"<b>없는</b>"`
- 기대: 직원 PATCH(`StaffService.validPart`, `StaffService.java:215`)처럼 `INVALID_PART`.
- 원인: `ShiftService.create`(`ShiftService.java:96~`)·`update`·월 저장이 파트 이름을 검사하지 않는다.
- 영향: 파트별 보기·필요 인원 계산에서 빠지는 근무가 생긴다. HTML 조각은 Flutter 가 문자열로 그리므로 XSS 는 아니다.

### [낮음] 제어문자(NUL 등)가 든 이름을 그대로 저장한다

- 재현: `curl -s -XPATCH $B/stores/31 -H "Authorization: Bearer $O" "${J[@]}" -d '{"name":"a\u0000b\u0007c"}'` → 200, `"name":"a\u0000b\u0007c"`
- 기대: 제어문자 거부 또는 제거.
- 영향: 화면·이미지 저장·CSV 에서 깨진 글자가 나올 수 있다. 이모지·SQL·HTML 조각(`😀<script>..'; DROP TABLE x;--`)은 그대로 저장되고 SQL 주입은 없었다(통과).

### [낮음] 숫자 필드 상한 없음 (주 소정시간·알림일·필요 인원)

- 재현:
  ```sh
  curl -s -XPUT $B/stores/31/staff/82/contract -H "Authorization: Bearer $O" "${J[@]}" \
    -d '{"start":"2026-01-01","end":"2027-01-01","wage":10320,"weeklyHours":100000,"workDays":"월"}'   # 200
  curl -s -XPUT $B/me/health-cert -H "Authorization: Bearer $S" -F expiry=2027-01-01 -F alertDays=99999 -F photo=@a.png  # 200
  curl -s -XPUT $B/stores/31/parts/needs -H "Authorization: Bearer $O" "${J[@]}" -d '{"needs":[100000,1,1]}'           # 200
  ```
- 원인: `ContractDto` `weeklyHours` 는 `@Min(1)` 만 있다. `DocumentService.java:57` 은 음수만 막는다. `StoreService.applyNeeds` 는 음수만 막는다.
- 영향: 주휴수당 계산은 `min(소정, 40h)` 라 금액은 안 틀린다. 계약서 표시값은 비현실적이 된다. 필요 인원은 위 [높음] 항목으로 이어진다.

### [낮음] 소수 시급을 조용히 버림

- 재현: `curl -s -XPOST $B/stores/31/staff/82/approve -H "Authorization: Bearer $O" "${J[@]}" -d '{"wage":10320.5}'` → 200, `"wage":10320`
- 기대: 400 또는 명시적 반올림 안내.
- 원인: Jackson 이 float 를 Integer 로 바꿀 때 소수를 버린다(`FAIL_ON_FLOAT_FOR_INT` 꺼짐).
- 영향: 미미하다. FE 는 정수만 보낸다.

## 통과한 케이스

- `POST /stores`: 빈 본문·본문 없음·배열·깨진 JSON·타입·enum 오류 → 400(형식은 위 발견). name/address 누락 → 400 VALIDATION_FAILED. 없는 매장 → 404 NOT_FOUND. 큰 path id(2^31 초과) → 400.
- `PATCH /stores/{id}`: 공백 이름 → 400 STORE_REQUIRED_FIELDS. 주소 256자 → 400. 이모지·HTML·SQL 조각은 그대로 저장되고 SQL 주입 없음.
- `PATCH /settings`: 음수·99999·종료<시작·종료=시작·주말 범위 밖 → 400 INVALID_HOURS. 이름 null 은 무시. 공백 이름 → 400. 잘못된 sizeMode → 400.
- `PUT /parts/needs`: null·음수 → 400 INVALID_NEED. needs 누락 → 400.
- `PUT /parts`: null → 400. 잘못된 tone → 400. 다른 매장 id → 404. 숫자 아닌 id 는 새 파트로 처리.
- `POST /join-requests`: 숫자 code·300자 code·SQL 조각 → 404 notFound. 소문자·하이픈 없는 코드는 정규화되어 alreadyMember 409.
- `POST /staff/{id}/approve`: wage null → 400. 21억 초과·문자열 → 400. 승인 뒤 재승인 → 409 NOT_PENDING.
- `PATCH /staff/{id}`: fixedParts 8칸·없는 파트 → 400 INVALID_FIXED_PARTS. null 칸은 빈 칸으로 처리. workHours 범위 밖 → 400. 타입 오류 → 400. part 51자 → 400. kind 오류 → 400. 빈 본문 → 200(변경 없음).
- `POST /shifts`: 2월 30일·`2026/12/01`·25시(1500분) → 400. staffIds 문자열 숫자 `"82"` 허용. 문자열·null·없는 직원 → 400/404. repeatWeeks 0 → 400. kind 오류 → 400.
- `PATCH /shifts/{id}`: 없는 id → 404. 숫자 아닌 id → 400. 거대한 startMin → 400. 없는 staffId → 404. date null 은 무시. 종료<시작은 야간 근무로 해석(의도).
- `DELETE /shifts/{id}`: 없는·음수 id → 204(멱등). 2^31 → 400.
- `POST /schedule/auto-fill`: null → 400. 화요일 → 400 INVALID_WEEK_MONDAY. 먼 미래·먼 과거 → 200(500 없음).
- `/schedule/template`: needs null·음수 → 400. `/schedule/tbd-count`: 13월 → 400 INVALID_MONTH. `/schedule/confirm`: 1999년 → 400.
- 월 근무표: month 형식 오류(`2026-13`, 숫자) → 400. 중복 생성 → 같은 행 반환. 형식 오류 month 로 save/confirm/delete/autofill → 400 INVALID_MONTH. 다른 달 날짜 → 400 DATE_OUT_OF_MONTH. 시각 범위 밖 → 400 INVALID_TIME. 음수 휴게 → 400 INVALID_BREAK. 없는 직원 → 400 STAFF_NOT_FOUND. 숫자 아닌·남의 id 는 새 근무로 처리.
- `/schedules/generate/apply`: 공백 planId → 400. 없는 planId → 410 PLAN_EXPIRED. `/schedule-plans/{id}/apply` 없는 id → 404.
- 템플릿: 공백 이름 → 400. 이모지·HTML 이름 저장. 없는 템플릿 apply → 404, delete → 204.
- 공지: 제목 201자 → 400. 본문 7만 자 → 400 NOTICE_TOO_LONG. null → 400. 없는 공지 read/remind → 404. 숫자 아닌 id → 400.
- 출퇴근: QR 없음·숫자·긴 문자열·본문 없음 → 400 INVALID_QR. 출근 없이 퇴근(본문 없음·깨진 본문) → 404.
- 근태 수정: 없는 기록 → 404. 2월 30일·25시 → 400. 사유 누락 → 400. 퇴근<출근 → 400 INVALID_CLOCK_RANGE. 24시간 초과 → 400. 미래 시각(UTC Z 포함) → 400 FUTURE_TIME. 이미 기록 있는 근무에 수동 기록 → 409. null 두 개는 변경 없음.
- 대타: 본문 없음·reason null·notifyPeers 타입 오류/null → 400. 없는 요청 apply → 404. assign staffId null → 400. 숫자 아닌 id → 400.
- 계약서: 종료<시작 → 400. 2월 30일 → 400. 없는 직원 → 404. 서명 빈값 → 400. 경로 조작 signatureUrl → 400 INVALID_SIGNATURE. 잘못된 who → 404.
- 보건증: 사진 없음 → 400 PHOTO_REQUIRED. 2월 30일·alertDays 문자 → 400. 음수 → 400. 지난 만료일 → 400 EXPIRY_IN_PAST. JSON·multipart 아님 → 415. 서명 업로드 파일 없음 → 400.
- 알림: 없는·숫자 아닌 id → 404/400. read-all 깨진 본문 → 204(본문 안 읽음). 음수 page·거대 size → 200.
- AI: 빈 질문·1001자 → 400. 정상 → 503 AI_DISABLED.
- `/me/state?storeId=abc` → 400, 없는 매장 → 403. `/me/changes?since=abc` → 400.
- `/api/auth/kakao/token`·`/refresh`·`/logout`: 깨진 JSON·빈 본문 → 400. null·누락 → 400 VALIDATION_FAILED. 틀린 토큰 → 401(형식은 위 발견).
- 인건비: month 13·0 → 400 INVALID_MONTH. trend months 0·-1·25 → 400. 명세서 month 형식 오류 → 400.

## 못 한 것

- `needs:[2147483647]`·366일 같은 실제 장시간 요청: 서버를 멈출 수 있어서 보내지 않았다(규칙 3·4). 1e6·1e7 측정값으로 선형임을 보였다.
- 10MB 넘는 JSON 본문·업로드 크기 경계: 16번(health-cert) 영역이라 확인하지 않았다.
- `POST /schedules/generate/preview`: 외부 LLM 호출이라 10번 에이전트 전용이다.
- 다른 에이전트의 동시성 테스트 로그(Deadlock, StaleState, Duplicate entry)가 BE 로그에 섞여 있었다. 내 500 은 요청 시각·스레드로 골라 원인을 확인했다.
- 테스트 중 `PUT /parts {"parts":[]}` 로 내 매장(31) 파트를 모두 지웠다가 다시 만들었다. 파트 id 는 96~98 에서 269~ 로 바뀌었다(내 데이터만).
