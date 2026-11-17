# 04 staff-management QA 보고서

## 요약

- 실행한 케이스: 131
- 통과: 122
- 발견: 8건. 치명 0, 높음 1, 중간 2, 낮음 5

테스트 데이터:
- 매장 A(id 1, 사장 `a04-ownerA`)와 매장 B(id 2, 사장 `a04-ownerB`)
- 알바 `a04-staff1`~`a04-staff9`. staff1 은 A·B 두 매장에 소속
- A 의 StoreWorker id: staff1=1, staff2=2, staff3=3, staff4=4(퇴사 뒤 재신청 148), staff6~9=150~153
- 기준 시각: 2026-11-17 23시대(KST)

공통 변수:

```sh
QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
B=http://127.0.0.1:18080/api/v1
OA=$($QA/qa-user a04-ownerA)
```

## 발견

### [높음] 시급 변경 이력이 BE 급여 계산(payslip·labor-cost)에 반영되지 않음. 지난 근무도 새 시급으로 계산된다
- 재현:
  ```sh
  # staff2(id 2): 시급 10,320, 이력 없음. 11/10 근무와 출근 기록을 만든다
  curl -s -X POST $B/stores/1/shifts -H "Authorization: Bearer $OA" -H 'Content-Type: application/json' \
    -d '{"staffIds":[2],"date":"2026-11-10","startMin":540,"endMin":1080,"part":"오픈"}'          # → shift 43
  curl -s -X POST $B/stores/1/shifts/43/attendance -H "Authorization: Bearer $OA" -H 'Content-Type: application/json' \
    -d '{"clockIn":"2026-11-10T09:00:00","clockOut":"2026-11-10T18:00:00","reason":"QA"}'
  curl -s $B/stores/1/staff/2/payslips/2026-11 -H "Authorization: Bearer $OA"    # base 82560
  curl -s -X PATCH $B/stores/1/staff/2 -H "Authorization: Bearer $OA" -H 'Content-Type: application/json' -d '{"wage":20000}'
  #   → wages: [{"from":"2000-01-01","wage":10320},{"from":"2026-11-17","wage":20000}]
  curl -s $B/stores/1/staff/2/payslips/2026-11 -H "Authorization: Bearer $OA"    # base 160000
  curl -s "$B/stores/1/labor-cost?year=2026&month=11" -H "Authorization: Bearer $OA"
  ```
- 기대: 11/10 근무는 그날 시급 10,320원으로 계산된다. `base` 는 82,560이다. FE `lib/data/payroll.dart:3,139` 는 근무일마다 `wageOn(day)` 를 쓴다.
- 실제: 시급을 바꾼 뒤 `base` 가 160,000, `gross` 가 160,000이 된다. 지난 근무까지 새 시급 20,000원으로 다시 계산됐다. `labor-cost.total` 도 같은 값이다.
- 원인: `service/PayrollCalculator.java:61` 의 `int wage = sw.getHourlyWage();` 가 현재 시급 하나만 쓴다. 기본급·주휴·가산(`:106-108`)도 모두 이 값으로 계산한다. `StaffWageService.wageOn` 은 직원 DTO(`StaffDto.java:68`)와 월 근무표(`MonthScheduleService.java:536`)에서만 쓴다.
- 영향: 월 중간에 시급을 올리면 BE 급여 명세·인건비 API 가 그달 지난 근무까지 새 시급으로 계산한다. 내리면 덜 준다. 지금 FE 는 이 API 를 부르지 않고 직접 계산한다(`grep payslips donBug_FE/lib` 결과 없음). 그래서 앱 화면과 BE 값이 서로 다르다. 이 API 를 쓰는 순간 돈이 틀린다.

### [중간] 같은 직원의 시급을 동시에 바꾸면 데드락 500이 나고 기준 행이 중복된다
- 재현:
  ```sh
  for w in $(seq 11001 11010); do
    curl -s -o /dev/null -w '%{http_code}\n' -X PATCH $B/stores/1/staff/150 -H "Authorization: Bearer $OA" \
      -H 'Content-Type: application/json' -d "{\"wage\":$w}" &
  done; wait
  $QA/qa-sql "SELECT effective_from,wage FROM staff_wage WHERE mapping_id=150"
  ```
- 기대: 모두 200을 돌려주거나 409로 깔끔하게 거절한다. 이력에는 `2000-01-01` 기준 행이 하나만 있다.
- 실제: 10개 중 7개가 500을 돌려준다. 본문은 Spring 기본 `{"timestamp","status":500,...}` 이다. BE 로그에 `CannotAcquireLockException: Deadlock found when trying to get lock` 이 남는다(`update store_worker ...`). `staff_wage` 에 `2000-01-01 10320` 행이 2개 생긴다.
- 원인:
  - `service/StaffWageService.java:22-28` 가 이력이 비었는지 확인한 뒤 기준 행과 새 행을 INSERT 한다. `staff_wage.mapping_id` FK 때문에 이 INSERT 가 `store_worker` 행에 공유 락을 잡는다.
  - 이어서 `sw.setHourlyWage` 의 UPDATE 가 같은 행에 배타 락을 요청한다. 두 트랜잭션이 서로의 락을 기다리면 데드락이 난다.
  - "비었으면 기준 행 추가" 확인도 락 없이 하므로 기준 행이 중복된다.
  - `controller/ApiExceptionHandler.java` 에는 락 예외 처리가 없다.
- 영향: 사장님 두 명이 같은 매장을 열어 두었거나(PC·폰) 저장을 연타하면 일부 요청이 500으로 실패한다. FE 는 낙관적으로 먼저 반영하므로 화면과 서버 값이 어긋날 수 있다. 중복 기준 행은 계산에는 영향이 없지만 이력 목록(`wages`)에 같은 항목이 두 번 보인다.

### [중간] 시급 상한이 없어 급여 계산이 int 오버플로로 음수가 된다
- 재현:
  ```sh
  curl -s -X PATCH $B/stores/1/staff/3 -H "Authorization: Bearer $OA" -H 'Content-Type: application/json' -d '{"wage":2147483647}'   # 200
  for d in 23 24 25 26 27; do curl -s -X POST $B/stores/1/shifts -H "Authorization: Bearer $OA" -H 'Content-Type: application/json' \
    -d "{\"staffIds\":[3],\"date\":\"2026-11-$d\",\"startMin\":540,\"endMin\":1080,\"part\":\"오픈\"}"; done
  curl -s "$B/stores/1/staff/3/payslips/2026-11?projected=true" -H "Authorization: Bearer $OA"
  curl -s "$B/stores/1/labor-cost?year=2026&month=11&projected=true" -H "Authorization: Bearer $OA"
  ```
- 기대: 비현실적인 시급(예: 1,000,000원 초과)은 400으로 거절한다. 받더라도 급여가 음수가 되면 안 된다.
- 실제: PATCH 가 200을 돌려준다. 급여 명세는 `"minutes":2400,"base":-40,"weeklyHoliday":-8,"gross":-48,"net":-47` 이고, 인건비 `total` 은 -48이다. 소수 `{"wage":10500.7}` 도 200을 돌려주고 조용히 10500으로 잘린다.
- 원인:
  - `dto/StaffCommandDto.java:23` 에 `@Min` 만 있고 `@Max` 가 없다. `approve` 도 같다(`:18`).
  - `service/TimeUtil.java:72` 의 `(int) Math.round(minutes * (double) hourlyWage / 60.0)` 는 long 값을 int 로 잘라 값이 넘친다.
  - `PayrollCalculator.java:106-109` 도 int 로 합산한다.
- 영향: 시급 입력에서 0을 몇 개 더 치는 실수를 막지 못한다. 값이 아주 크면 급여·인건비가 음수나 엉뚱한 값으로 나온다. 정상 범위(수만 원)에서는 생기지 않는다.

### [낮음] 대기(PENDING)·거절(REJECTED) 신청자에게 DELETE 하면 '퇴사' 처리되고 퇴사 알림이 간다
- 재현:
  ```sh
  # staff4(id 4)는 가입 신청만 한 PENDING 상태
  curl -s -X DELETE $B/stores/1/staff/4 -H "Authorization: Bearer $OA"     # 204
  $QA/qa-sql "SELECT status,left_at,joined_at FROM store_worker WHERE mapping_id=4"   # LEFT 2026-11-17 NULL
  $QA/qa-sql "SELECT title FROM notification WHERE to_user_id=9"           # 'QA04 매장A에서 퇴사 처리됐어요'
  # 거절된 신청자: reject 뒤 DELETE
  curl -s -X POST $B/stores/1/staff/152/reject -H "Authorization: Bearer $OA"; curl -s -X DELETE $B/stores/1/staff/152 -H "Authorization: Bearer $OA"   # 204, LEFT
  ```
- 기대: PATCH·cert-renewal 처럼 재직자가 아니면 409 `NOT_ACTIVE` 를 돌려준다. 신청을 지우려면 reject 를 쓴다.
- 실제: 204를 돌려준다. 상태가 LEFT 가 되고 `leftAt` 이 오늘이 된다. 한 번도 일하지 않은 신청자에게 "퇴사 처리됐어요" 알림이 간다. 이 사람은 `?status=left` 퇴사자 목록에도 나온다.
- 원인: `service/StaffService.java:156-160` 은 LEFT 인지만 확인하고, PENDING·REJECTED 도 LEFT 로 바꾼다.
- 영향: FE 는 재직자 화면에서만 내보내기를 부르므로 화면으로는 재현되지 않는다. API 를 직접 부르면 퇴사 이력과 잘못된 알림이 생긴다.

### [낮음] 같은 직원을 동시에 내보내면 퇴사 알림이 중복된다
- 재현: 재직자 148번에게 `DELETE /stores/1/staff/148` 를 동시에 10개 보낸다. 모두 204를 돌려준다. 그 뒤 `SELECT title FROM notification WHERE to_user_id=9` 를 실행한다.
- 기대: 퇴사 알림이 1개 생긴다.
- 실제: "QA04 매장A에서 퇴사 처리됐어요" 가 2개(id 753, 754) 생긴다.
- 원인: `service/StaffService.java:156` 의 멱등 확인(`status == LEFT`)이 락 없이 읽는다. 동시에 들어온 요청 여럿이 모두 ACTIVE 를 보고 부수효과(근무 삭제·대타 정리·알림)를 반복한다.
- 영향: 알림 중복만 확인했다. 데이터 손상은 보지 못했다.

### [낮음] `part` 에 공백 문자열을 넣을 수 있다
- 재현: `curl -s -X PATCH $B/stores/1/staff/2 -H "Authorization: Bearer $OA" -H 'Content-Type: application/json' -d '{"part":"   "}'` 를 실행한다. 200을 돌려주고 `"part":"   "` 이 저장된다.
- 기대: 공백만 있는 값은 400을 돌려주거나 `""` 로 바꿔 저장한다.
- 원인: `service/StaffService.java:216` 의 `if (part.isBlank() || ...) return part;` 가 공백을 그대로 돌려준다.
- 영향: 직원 상세에 기본 파트가 빈칸으로 보인다. FE 선택 상자는 첫 파트로 대신 보여 주므로 화면과 저장값이 다르다.

### [낮음] 근무시간 검증 메시지가 원인과 다르다
- 재현: `PATCH /stores/1/staff/2` 에 `{"workHours":[{"startMin":-1,"endMin":100},null,null,null,null,null,null]}` 를 보낸다.
- 실제: 400 `INVALID_WORK_HOURS` "퇴근 시각은 출근 시각보다 늦어야 해요". 퇴근이 출근보다 늦은데도 이 메시지가 나온다. `startMin>1439` 이거나 길이가 24시간을 넘을 때도 같은 메시지다.
- 원인: `service/StaffService.java:245-247` 이 모든 조건을 한 메시지로 묶는다.
- 영향: 메시지만 틀린다. FE 시간 선택기로는 생기지 않는다.

### [낮음] 잘못된 enum·타입·깨진 JSON 에는 `{code,message}` 가 아닌 Spring 기본 오류 본문이 나간다
- 재현:
  - `PATCH /stores/1/staff/2` 에 `{"deduction":"bogus"}` 를 보낸다
  - `{"kind":"boss"}`, `{"wage":"abc"}`, `{"premium":"yes"}`, 깨진 JSON `{"wage":`, 빈 본문도 보낸다
  - `GET /stores/1/staff?status=bogus` 를 보낸다
- 실제: 400 `{"timestamp":...,"status":400,"error":"Bad Request","path":...}` 를 돌려준다. `code`·`message` 가 없다.
- 원인: `controller/ApiExceptionHandler.java` 가 `ApiException`·`MaxUploadSizeExceededException`·`BindException` 만 처리한다. `HttpMessageNotReadableException`·`MethodArgumentTypeMismatchException` 은 처리하지 않는다.
- 영향: FE `ApiClient`(`api_client.dart:174`)는 `code` 를 HTTP 상태값 "400" 으로, 메시지를 "요청을 처리하지 못했어요" 로 대신 보여 준다. 정상 FE 요청에서는 생기지 않는다. 23번 robustness 와 겹칠 수 있다.

## 통과한 케이스
- 목록: 사장님 기본값(재직과 대기), `?status=pending|left|active|ACTIVE` 필터
- 목록: 알바생은 `?status=pending` 을 보내도 재직자만 받는다
- 목록: 알바생에게 다른 직원의 시급(0)·공제(null)·연락처·kakaoId·계약서·시급 이력이 가려진다. 본인 정보는 그대로 보인다
- 목록: 미승인 신청자·다른 매장 사장님·다른 매장 알바생은 403, 인증 없음은 401, 없는 매장은 404, 숫자 아닌 storeId 는 400
- 상세: 사장님과 본인(재직·대기·퇴사)은 200. 같은 매장 다른 알바생·매니저·다른 매장 사장님은 403. 없는 직원과 다른 매장 직원 id 는 404
- PATCH wage: 최저임금 10,320원 경계는 통과하고 10,319원은 400 `VALIDATION_FAILED`
- PATCH wage: 같은 값을 다시 보내면 이력이 추가되지 않는다. 바꾸면 `2000-01-01` 기준 행과 오늘 행이 생긴다(FE `updateStaff` 와 같은 방식)
- PATCH wage: `null` 은 바꾸지 않는다. int 범위를 넘는 수와 문자열은 400
- PATCH deduction: `biz33`·`insurance`·`none`·`BUSINESS_TAX` 를 받고, 응답은 Dart `.name`
- PATCH weeklyHolidayAuto·premium 반영
- PATCH kind: `manager`·`MANAGER`·`fulltime`·`minor`·`partTimer` 를 받고, 알 수 없는 값은 400
- PATCH part: 매장 파트, `"직원"`, `""` 를 받는다. 매장에 없는 파트는 400 `INVALID_PART`, 51자는 400, `null` 은 바꾸지 않는다
- PATCH fixedParts: 7칸 정상, 같은 칸의 중복 제거, null 칸은 빈 칸으로 바꾼다
- PATCH fixedParts: 6칸·0칸·없는 파트·`"직원"`·null 원소·문자열 값은 400
- PATCH workHours·availHours: 7칸 정상, 모두 null, 자정을 넘는 근무(1320→1560, 1439→2879)를 받는다
- PATCH workHours·availHours: 역순·같은 시각·24시간 초과·6칸·0칸·누락 키·문자열 값은 400
- PATCH 권한: 본인 알바생·다른 알바생·매니저·다른 매장 사장님은 403, 다른 매장 직원 id 는 404
- PATCH 상태: 대기·퇴사 직원은 409 `NOT_ACTIVE`
- PATCH 본문의 모르는 필드(status·storeId·personId)는 무시한다
- cert-renewal: 미등록이면 "보건증을 등록해 주세요"
- cert-renewal: 만료일이 오늘이면 "보건증 만료 D-0", 어제면 "만료 지남", 미래면 "D-54" 알림이 해당 매장 store_id 로 간다
- cert-renewal 권한·상태: 두 번 보내면 2번 보낸다. 대기·퇴사 직원은 409. 알바·매니저·다른 매장 사장님은 403. 다른 매장 직원 id 와 없는 id 는 404
- DELETE 권한·멱등: 본인·다른 매장 사장님은 403, 다른 매장 직원 id 는 404, 두 번째 요청은 204
- DELETE 근무: 어제 근무(출근 기록 있음)와 오늘 근무(출근 기록 있음)는 남는다. 오늘 지난 근무(출근 없음)와 미래 근무(11/20, 11/21, 12/05)는 지워진다(FE `removeStaff` 와 같은 기준)
- DELETE 대타: 본인 요청은 근무와 함께 없어진다. 다른 사람 요청의 후보(taker)였으면 OPEN 으로 돌아가고 taker 는 null 이 된다. 지원자이기만 했으면 지원자 목록에서 빠지고 후보는 그대로 남는다
- DELETE 알림·목록: 본인에게 "퇴사 처리됐어요" 알림(JOIN)이 간다. 목록 기본값에서 빠지고 `?status=left` 에 `leftAt` 과 함께 나온다
- 퇴사자: 매장 A 의 근무·직원 목록 API 는 403. 본인 상세는 200
- 퇴사자 급여: 사장님·본인이 퇴사자 급여 명세를 볼 수 있다(남은 근무 450분). labor-cost 에 퇴사자가 포함된다
- 퇴사 뒤 `/me/state`(사장님): staff 에 `left` 직원, 남은 근무와 출근 기록, OPEN 으로 돌아간 대타가 그대로 있다
- 퇴사 뒤 `/me/state`(알바생): 다른 매장 B 가 session 이 되고 A 는 보이지 않는다
- 퇴사한 대기 신청 approve 는 409 `NOT_PENDING`. 퇴사 뒤 재신청하면 새 PENDING 행이 생긴다
- 사업장 규모 auto: 재직자가 5명이 되면 `isSmall=false`, 내보내서 4명이 되면 `true` 로 바로 바뀐다
- 매니저(kind=manager): 사장님 전용 기능(PATCH·DELETE·approve·cert-renewal·매장 코드·다른 직원 상세)은 403. FE 도 매니저 전용 권한을 기대하지 않는다(`StaffKind.manager` 는 색 표시에만 쓴다)
- FE 계약: `updateStaff`·`removeStaff`·`requestCertRenewal` 의 경로·메서드·본문 키(`wage`, `deduction`, `kind`, `fixedParts`, `workHours`·`availHours` 의 `{startMin,endMin}`|null)를 BE 가 그대로 받는다. 응답의 `Staff.fromJson` 필수 필드(`part`, `joinedAt`, `weeklyHolidayAuto`, `premium`)는 null 이 아니다

## 못 한 것
- 퇴사자가 든 주간 템플릿·확정된 월 근무표·AI 근무표에 퇴사가 미치는 영향: 07·08·09·10번 영역이라 확인하지 않았다.
- 퇴사로 사업장 규모가 바뀔 때 그달 가산수당이 소급해서 바뀌는지: 18번 payroll 영역이다.
- 대타가 승인되어 근무 주인이 바뀐 뒤 원래 주인이 퇴사하는 경우: `originalStaffId` 를 따로 확인하지 않았다(13번).
- FE 화면 실제 렌더링: 웹 컨테이너를 띄우지 않아 API·코드 대조만 했다.
- 가정: 시급 상한값은 정해진 기준이 없다. "급여가 음수가 되지 않는 범위" 를 기대값으로 삼았다.
