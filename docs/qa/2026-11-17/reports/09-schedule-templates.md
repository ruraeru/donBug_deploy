# 09 schedule-templates QA 보고서

## 요약

- 실행한 케이스: 52개 (저장 19, 적용 17, 삭제 8, 교체·겹침 3, 동시 요청 4, `/me/state` 노출 1)
- 통과: 44개
- 발견 7건: 치명 0, 높음 0, 중간 4, 낮음 3

테스트 데이터 (모두 a09 접두사):
- 사용자: `a09-ownerA`(매장 16 "QA09 매장A", 코드 `SMQX-4LA6`), `a09-ownerB`(매장 17 "QA09 매장B", 코드 `C9MQ-YW4X`).
- 알바: `a09-s1`/`s2`/`s3` 는 매장 16 직원 23/24/25(25 는 테스트 중 퇴사), `a09-sb1` 은 매장 17 직원 26.
- 기준 날짜: 2026-11-17(화).

공통 준비:
```sh
QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
B=http://127.0.0.1:18080/api/v1
OA=$($QA/qa-user a09-ownerA); S1=$($QA/qa-user a09-s1)
H=(-H "Authorization: Bearer $OA" -H 'Content-Type: application/json')
```

## 발견

### [중간] 같은 템플릿 적용을 두 번 겹쳐 보내면 한쪽이 500 (ObjectOptimisticLockingFailureException)
- 재현 (적용 버튼 더블클릭과 같은 상황):
  ```sh
  for i in 1 2; do curl -s -o /dev/null -w '%{http_code} ' -X POST $B/stores/16/schedule-templates/1/apply "${H[@]}" -d '{"month":"2027-02"}' & done; wait
  # → 204 500  (3번 반복해서 3번 모두 같은 결과. 8개를 동시에 보내면 204 1개, 500 7개)
  # 템플릿 적용과 PUT /schedules/2027-02/shifts 를 겹쳐 보내도 save 가 500
  ```
- 기대: 뒤에 온 요청은 앞 요청이 끝날 때까지 기다린 뒤 정상 처리(204). 아니면 409 같은 정돈된 오류.
- 실제: `500`. 로그: `ObjectOptimisticLockingFailureException: Unexpected row count (expected row count 1 but was 0) [delete from schedule where schedule_id=? and version=?]` at `MonthScheduleService.removeShifts(MonthScheduleService.java:721)` ← `applyTemplate(:364)`. 데이터는 롤백되어 중복 행은 없었다(DB 확인).
- 원인: `service/MonthScheduleService.java:351-352`
  - `access.requireOwner()` 가 Store 를 일반 SELECT 로 먼저 읽는다. 그 뒤에 `monthRepo.lockStore()`(FOR UPDATE)를 건다.
  - MySQL 은 `REPEATABLE-READ` 라서 첫 SELECT 시점에 스냅샷이 잡힌다. 락을 기다린 뒤 `findByStoreBetween`(:363)은 앞 트랜잭션이 이미 지운 근무를 옛 스냅샷으로 읽는다.
  - 그래서 그 근무를 다시 지우려다 0행이 삭제되어 실패한다.
  - 락을 첫 읽기보다 먼저 거는 다른 쓰기 경로(`saveShifts` 등)도 같은 구조인지 07·24번과 같이 볼 필요가 있다.
- 영향: 사장님이 적용 버튼을 두 번 누르거나 저장과 적용이 겹치면 "서버와 통신하지 못했어요" 류 오류가 보인다. 실제 반영은 됐는데도 그렇다.

### [중간] 다른 템플릿으로 다시 적용하면 이전 템플릿의 휴무·연차가 남는다. 그 날의 새 근무는 빠지고 연차는 누적된다
- 재현:
  ```sh
  # 1) 템플릿1(12월 기본): 월 s23·s24 근무, 수 s23 연차, 목 s24 휴무 … 를 2027-02 에 적용
  curl -s -X POST $B/stores/16/schedule-templates/1/apply "${H[@]}" -d '{"month":"2027-02"}'
  # 2) 12월 첫 주를 바꿔 템플릿 T-B 저장: 월 s23 근무, 목 s24 근무(720-1020), 금 s23 연차
  curl -s -X PUT $B/stores/16/schedules/2026-12/shifts "${H[@]}" -d '{"shifts":[
   {"staffId":23,"date":"2026-12-07","startMin":480,"endMin":720,"part":"오픈","breakMin":30,"kind":"work"},
   {"staffId":23,"date":"2026-12-11","startMin":480,"endMin":720,"part":"오픈","breakMin":0,"kind":"leave"},
   {"staffId":24,"date":"2026-12-10","startMin":720,"endMin":1020,"part":"미들","breakMin":30,"kind":"work"}]}'
  curl -s -X POST $B/stores/16/schedule-templates "${H[@]}" -d '{"name":"T-B","month":"2026-12"}'   # id 10
  # 3) T-B 를 2027-02 에 적용
  curl -s -X POST $B/stores/16/schedule-templates/10/apply "${H[@]}" -d '{"month":"2027-02"}'
  $QA/qa-sql "SELECT s.mapping_id,s.kind,GROUP_CONCAT(DAY(s.work_date)) FROM schedule s JOIN store_worker sw USING(mapping_id) WHERE sw.store_id=16 AND s.work_date BETWEEN '2027-02-01' AND '2027-02-28' GROUP BY 1,2"
  ```
- 기대: T-B 와 같은 결과. s23 은 월요일 근무와 첫 금요일(2/5) 연차, s24 는 목요일마다(2/4·11·18·25) 근무.
  - 엔드포인트 설명은 "기존 근무는 교체"다.
  - FE 데모 경로 `_clearFuture`(`donBug_FE/lib/data/app_store.dart:2164`)는 오늘 이후·출근 기록 없는 근무를 종류와 상관없이 모두 지우고 채운다.
- 실제 (204, DB):
  - `23 LEAVE 3,5`: 이전 템플릿의 2/3 연차가 남았고 2/5 연차가 더해졌다.
  - `24 OFF 4,11,18,25`: 이전 템플릿의 휴무가 남았다.
  - s24 의 WORK 는 0건이다. T-B 의 목요일 근무 4건이 전부 조용히 건너뛰어졌다.
- 원인: `service/MonthScheduleService.java:364-366`, `:374`
  - 교체할 때 `kind == WORK` 만 지운다.
  - 남은 OFF/LEAVE 가 있는 (직원, 날짜)는 `off` 집합에 들어간다. 템플릿 행이 근무여도 `continue` 로 건너뛴다.
  - 주석("연차·휴무는 두고")으로 보아 수동으로 넣은 연차를 지키려는 의도로 보인다. 하지만 이전 템플릿이 넣은 휴무·연차와 구분하지 못한다.
- 영향:
  - 템플릿을 바꿔 적용하면 새 템플릿의 근무가 응답 없이 빠진다. 근무표에 구멍이 생긴다.
  - 연차가 누적된다. 연차는 급여에 유급으로 들어가므로(`PayrollCalculator.java:73-77`) 예상 인건비·명세서가 늘어난다.

### [중간] 알바생 `/me/state` 에 매장 템플릿 전체가 내려간다 (작성 중 근무표 패턴 노출)
- 재현:
  ```sh
  curl -s $B/me/state -H "Authorization: Bearer $S1" | python3 -c "import json,sys;d=json.load(sys.stdin);print(len(d['templates']),[m['status'] for m in d['schedules']],[s for s in d['shifts'] if s['date']>='2026-12'],d['templates'][0]['shifts'][:2])"
  ```
- 기대: 템플릿은 사장님 전용 기능이다(저장·적용·삭제 모두 403 `사장님만 사용할 수 있어요`). 알바생에게는 내려가지 않아야 한다. 적어도 작성 중(draft) 달의 근무는 알바생에게 숨기는 정책(`StateService.java:145-148 visibleShifts`)과 맞아야 한다.
- 실제:
  - 12월·1월은 `draft` 라서 알바생의 `shifts` 는 비어 있다.
  - 그런데 `templates` 에는 7개가 모두 들어 있다. 그 안에 12월 첫 주 패턴(다른 직원 staffId·시간·파트, 연차·휴무 여부)이 그대로 있다.
  - 예: `{'dayIndex': 0, 'staffId': '23', 'startMin': 480, 'endMin': 720, 'part': '오픈', ...}`
- 원인: `service/StateService.java:167-168`. 템플릿 추가가 `isOwner` 조건 없이 모든 소속 매장에 대해 실행된다.
- 영향: 확정 전 근무표 내용과 다른 직원의 연차·휴무 일정이 알바생 앱 상태에 노출된다. FE 는 알바 화면에서 템플릿을 쓰지 않으므로 받을 이유가 없다.

### [중간] 템플릿 이름 101자 이상이면 500
- 재현:
  ```sh
  L101=$(python3 -c "print('가'*101)")
  curl -s -w '[%{http_code}]' -X POST $B/stores/16/schedule-templates "${H[@]}" -d "{\"name\":\"$L101\",\"month\":\"2026-12\"}"
  ```
- 기대: 400 `VALIDATION_FAILED` (`details.name`).
- 실제: `500 {"status":500,"error":"Internal Server Error"}`. 로그: `Data truncation: Data too long for column 'name' at row 1`. 100자는 200.
- 원인:
  - `dto/MonthScheduleCommandDto.java:73`: `TemplateCreateRequest.name` 에 `@NotBlank` 만 있고 `@Size(max = 100)` 이 없다.
  - 엔티티는 `entity/ScheduleTemplate.java` 의 `@Column(length = 100)` 이다.
- 영향: FE 템플릿 이름 입력칸(`web_schedule_screen.dart:174`)에 길이 제한이 없다. 긴 이름을 넣으면 의미 없는 오류만 보인다.

### [낮음] 지난 달에 템플릿을 적용하면 근무는 안 바뀌는데 월 메타가 "템플릿 적용"으로 바뀐다
- 재현:
  ```sh
  curl -s -w '[%{http_code}]' -X POST $B/stores/16/schedule-templates/1/apply "${H[@]}" -d '{"month":"2026-10"}'   # 204
  $QA/qa-sql "SELECT month,status,source,ai_comment FROM month_schedule WHERE store_id=16 AND month='2026-10'"
  # → 2026-10 DRAFT TEMPLATE 템플릿 "12월 기본"을 적용했어요.
  ```
- 기대: 대상 날짜가 없으니 400(지난 달) 또는 메타를 바꾸지 않아야 한다.
- 실제: 204. 근무가 없던 지난 달에 DRAFT/TEMPLATE 메타가 새로 생긴다. 이미 있던 지난 달 draft 면 source 와 aiComment 가 덮어써진다.
- 원인: `service/MonthScheduleService.java:360` 의 `targetDates` 가 비어도 `:381-386` 에서 메타를 무조건 저장한다.
- 영향: FE 는 이번 달~3개월 뒤만 고를 수 있어(`scheduleMonths`) 화면으로는 거의 안 생긴다. API 직접 호출·월 경계(자정 넘어 적용)에서 지난 달 근무표 출처 표시가 틀어진다.

### [낮음] 다른 매장·없는 템플릿 삭제도 204
- 재현:
  ```sh
  OB=$($QA/qa-user a09-ownerB)
  curl -s -w '[%{http_code}]' -X DELETE $B/stores/17/schedule-templates/2 -H "Authorization: Bearer $OB"   # 매장 16 템플릿 → 204
  curl -s -w '[%{http_code}]' -X DELETE $B/stores/16/schedule-templates/999999 -H "Authorization: Bearer $OA"  # 204
  ```
- 기대: apply 처럼 404 `템플릿을 찾을 수 없어요`. 멱등을 의도했다면 apply 와 어긋난다.
- 실제: 204. 실제로 지워지지는 않는다(템플릿 2 는 DB 에 남음, IDOR 아님). 매장 17 에 변경 신호만 생긴다.
- 원인: `service/MonthScheduleService.java:346`. `findByIdAndStoreId(...).ifPresent(delete)` 라서 없어도 성공으로 응답한다.
- 영향: 거의 없다. 다른 탭에서 이미 지운 템플릿을 지우면 오류 없이 넘어간다(오히려 무난). apply 와 응답만 다르다.

### [낮음] 같은 이름 템플릿, 근무 0개 템플릿 저장 허용
- 재현:
  ```sh
  curl -s -X POST $B/stores/16/schedule-templates "${H[@]}" -d '{"name":"12월 기본","month":"2026-12"}'   # 두 번 모두 200 (id 1, 2)
  curl -s -X POST $B/stores/16/schedule-templates "${H[@]}" -d '{"name":"빈달","month":"2027-05"}'         # 200, shifts: []
  ```
- 기대 (가정): 이름 중복은 409 또는 덮어쓰기. 첫 주에 근무가 없으면 저장을 막거나 안내해야 한다.
- 실제: 둘 다 200. 동시 8개 저장도 8개 모두 생성됐다. 근무 0개 템플릿은 적용하면 그 달 미래 근무를 전부 지우고 아무것도 넣지 않는다(교체 규칙).
- 원인: `service/MonthScheduleService.java:327-342` 에 중복·빈 패턴 검사가 없다. FE(`web_schedule_screen.dart:172-192`)도 검사하지 않는다.
- 영향: 목록에 같은 이름이 여러 개 생겨 구분하기 어렵다. 빈 템플릿을 실수로 적용하면 그 달 근무가 비워진다(되돌리기 없음). 의도된 동작일 수 있어 낮음으로 둔다.

## 통과한 케이스

저장 (`POST /schedule-templates`):
- 정상 저장: 앞뒤 공백 이름이 trim 된다. 그 달 첫 완전한 월~일 주(12/7~13)만 담긴다(12/2·12/14 제외). dayIndex 0=월.
- 저장 응답의 work·leave·off·timeTbd·breakMin·part 가 FE `TemplateShift` 모양과 맞는다. staffId·id·storeId 는 문자열, kind 는 `.name`.
- 공백만 있는 이름·이름 없음: 400 `VALIDATION_FAILED` (`템플릿 이름을 입력하세요.`).
- month 없음·`2026-13`·`2026-1`: 400.
- 100자 한글 이름: 200.
- 이모지·HTML·SQL 조각 이름: 그대로 저장되고 그대로 반환된다(이스케이프·실행 없음).
- name 이 숫자 123: 문자열 "123" 으로 저장된다.
- 아주 과거 달(1900-01): 빈 패턴으로 200.
- 권한: 알바생 403, 다른 매장 사장님 403, 인증 없음 401, 없는 매장 404.
- 퇴사한 직원(25) 근무는 퇴사 시 미래 근무가 지워져 이후 템플릿에 안 들어간다.

적용 (`POST /schedule-templates/{id}/apply`):
- 2027-01 에 적용: 월요일마다 s23·s24, 화·일요일 s25(TBD 포함), 연차는 첫 수요일(1/6)만, 휴무는 목요일마다. DB 와 `month_schedule`(TEMPLATE/DRAFT, aiComment) 확인.
- 같은 템플릿 재적용(순차): 행 수 변화 없음, 중복 없음.
- 확정된 달: 409 `ALREADY_CONFIRMED`, 근무 22건 그대로.
- 3개월 뒤(2027-02): 204. 4개월 뒤(2027-03): 400 `MONTH_TOO_FAR`.
- 다른 매장 템플릿을 자기 매장 경로로: 404.
- 남의 매장 경로: 403. 알바생: 403.
- 없는 템플릿·삭제된 템플릿: 404.
- month 누락: 400.
- 퇴사자가 든 템플릿 적용: 퇴사자 행은 건너뛰고 나머지만 들어간다.
- 출근 기록이 있는 오늘 근무(11/17 s23 600-900): 지우지 않는다. 템플릿의 같은 시간 근무는 겹침 검사(`saveRows`)로 건너뛴다. 중복 없음.
- 오늘보다 앞선 날짜는 손대지 않는다(11월 적용은 11/17 부터).
- 동시 적용 후 DB 중복 행 없음(500 은 위 발견 참고).

삭제 (`DELETE /schedule-templates/{id}`):
- 정상 삭제 204 후 `/me/state` 에서 빠진다. 두 번 삭제 204.
- 알바생 403, 다른 매장 사장님이 A 경로로 403, 인증 없음 401.
- B 경로로 A 템플릿 삭제: 지워지지 않는다(IDOR 없음).

## 못 한 것

- 매니저 직급 직원의 템플릿 권한: 서비스가 `requireOwner` 만 써서 사장님 전용임을 코드로 확인했다. 매니저 계정으로 실제 요청은 보내지 않았다.
- 다른 매장에 동시에 소속된 직원의 다른 매장 근무와 템플릿 근무의 겹침: `OverlapChecker` 가 처리할 것으로 보이지만 두 매장 소속 알바를 만들지 않았다.
- `/me/changes` 신호: 인터셉터가 `/stores/{id}/**` 비GET 성공을 일괄 처리해서 21번 영역에 맡겼다.
- 참고(다른 영역 몫이라 개수에 넣지 않음):
  - 깨진 JSON, 본문 없음, 문자열 templateId/storeId 의 400 응답이 `{code,message,details}` 가 아니라 Spring 기본 `{timestamp,status,error,path}` 이다(23번).
  - 직원 승인 400 메시지의 details 키가 요청 키 `wage` 가 아니라 `hourlyWage` 다(04번).
