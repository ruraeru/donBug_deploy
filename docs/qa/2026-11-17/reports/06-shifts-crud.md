# 06 shifts-crud QA 보고서

## 요약

- 대상: `GET/POST /stores/{id}/shifts`, `GET/PATCH/DELETE /stores/{id}/shifts/{shiftId}` (`ShiftController`, `ShiftService`, `OverlapChecker`, `ScheduleDeleter`)와 FE 호출부(`app_store.dart` `addShift`/`updateShift`/`deleteShift`, `shift_add_screen.dart`, `web_shift_dialog.dart`, `web_schedule_views.dart`).
- 실행한 케이스: 약 90건. 통과: 83건. 발견: 7건(치명 0, 높음 0, 중간 4, 낮음 3).
- 준비 데이터: 매장 12 `QA06 카페`(사장님 `a06-owner`), 매장 13 `QA06 다른매장`(`a06-owner2`). 매장 12 직원: `a06-staff1`=12, `a06-staff2`=13(나중에 퇴사), `a06-staff3`=14, `a06-staff4`=15(미승인). `a06-staff3` 은 매장 13 직원(16)이기도 하다.
- 아래 재현의 `$O` 등은 `$QA/qa-user a06-owner` 로 받은 토큰이다. `B=http://127.0.0.1:18080/api/v1`.
- 가정: 테스트 시각은 2026-11-17 23시(KST)다. 날짜 경계 영향을 피하려고 대부분 2026-12 이후 날짜를 썼다.

## 발견

### [중간] 같은 근무 생성 요청을 동시에 보내면 같은 직원에게 겹치는 근무가 여러 건 생긴다
- 재현:
  ```sh
  O=$($QA/qa-user a06-owner)
  for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code}\n" -X POST $B/stores/12/shifts \
    -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2027-02-02","startMin":540,"endMin":600,"staffIds":[14]}' & done; wait
  $QA/qa-sql "SELECT schedule_id FROM schedule WHERE mapping_id=14 AND work_date='2027-02-02'"
  ```
- 기대: 1건 201, 나머지 9건 409 `SHIFT_OVERLAP`. DB 에 1행.
- 실제: 201 이 8건, 409 가 2건. DB 에 같은 시간 근무 8행(id 423~430). 직원에게 "새 근무가 배정됐어요 2/2 09:00–10:00" 알림도 8건 생겼다. 같은 요청을 순서대로 두 번 보내면 두 번째는 정상적으로 409 다.
- 원인: `service/OverlapChecker.java:20-34` 가 조회로 겹침을 확인한 뒤 `service/ShiftService.java:126-127` 에서 저장한다. 직원 행 잠금이나 DB 유일 제약이 없어 동시에 들어온 요청이 모두 검사를 통과한다. PATCH(`ShiftService.java:173-176`)도 같은 구조다.
- 영향: 버튼 두 번 누르기나 네트워크 재시도로 중복 근무가 생긴다. 근무표·대시보드 근무 시간·예상 인건비가 부풀고, 출근은 한 근무에만 되므로 나머지는 미출근으로 남는다. 알림도 중복된다.

### [중간] 퇴사자의 지난 근무를 미래 날짜로 옮길 수 있고, 퇴사자에게 알림이 간다
- 재현:
  ```sh
  curl -s -X POST $B/stores/12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2026-11-10","startMin":540,"endMin":600,"staffIds":[13]}'      # id 124
  curl -s -X DELETE $B/stores/12/staff/13 -H "Authorization: Bearer $O"         # 204, 퇴사
  curl -s -X POST $B/stores/12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2026-12-12","startMin":540,"endMin":600,"staffIds":[13]}'      # 409 NOT_ACTIVE (정상)
  curl -s -X PATCH $B/stores/12/shifts/124 -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2026-12-20"}'
  curl -s $B/me/notifications -H "Authorization: Bearer $($QA/qa-user a06-staff2)"
  ```
- 기대: 퇴사자에게 새 근무를 만들 때처럼 409 `NOT_ACTIVE`. 퇴사자의 지난 근무는 기록 정정(같은 날짜 안의 수정)만 허용.
- 실제: 200. 근무 124 가 `"date":"2026-12-20"`, `"staffId":"13"` 이 된다. 퇴사한 `a06-staff2` 에게 "근무가 수정됐어요 12/20 09:20–10:00" 알림이 쌓인다. 퇴사자는 매장 근무 조회가 403 이라 그 근무를 볼 수도 없다.
- 원인: `service/ShiftService.java:158-160` 은 `staffId` 가 바뀔 때만 `activeStaff` 로 재직 여부를 본다. 담당자가 그대로면 날짜를 미래로 옮겨도 검사하지 않는다. 알림은 `ShiftService.java:202-203` 에서 재직 여부와 상관없이 보낸다.
- 영향: 퇴사 처리 때 지운 미래 근무가 다시 생길 수 있다. 근무표·인건비에 퇴사자 미래 근무가 잡히고, 아무도 출근할 수 없는 근무가 남는다. 모바일 수정 화면은 `staffId`·`date` 를 항상 보내므로 퇴사자 근무 날짜를 바꾸면 바로 이 경로를 탄다.

### [중간] `breakMin` 상한 검증이 없어 근무 시간이 음수가 된다
- 재현:
  ```sh
  curl -s -X POST $B/stores/12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2026-12-04","startMin":540,"endMin":600,"staffIds":[12],"breakMin":500}'
  ```
- 기대: 400. 휴게는 근무 길이보다 짧아야 한다.
- 실제: 201, `"breakMin":500`, `"scheduledMinutes":-440`. PATCH 의 `breakMin` 도 같다.
- 원인: `dto/ShiftCommandDto.java:27`·`:43` 은 `@Min(0)` 만 있다. `service/ShiftService.java:107-108`·`:185` 는 근무 길이와 비교하지 않는다. `entity/Schedule.java` `scheduledMinutes()` 는 음수를 그대로 돌려준다.
- 영향: FE 웹 근무 창(`web_shift_dialog.dart:138`)은 휴게를 0/30/60/90/120 중 고르게 하고 하한(`:90`)만 검사한다. 그래서 1시간 근무에 120분 휴게를 고르면 실제 UI 에서도 생긴다. 급여(`PayrollCalculator.java:77,94`)는 `max(0, …)` 로 막지만 다른 곳은 음수를 쓴다. FE 대시보드 월 통계(`web_dashboard_screen.dart:296`), 주간 근무 합계(`app_store.dart:104`), 대타 상세 "예상 수입"(`substitute_detail_screen.dart:108`), BE 자동 채우기의 주간 근무 분(`ShiftService.java:537`)이 줄거나 음수가 된다.

### [중간] 9999년 근무에 `repeatWeeks` 를 주면 500
- 재현:
  ```sh
  curl -s -X POST $B/stores/12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"9999-12-25","startMin":540,"endMin":600,"staffIds":[12],"repeatWeeks":2}'
  ```
- 기대: 400(날짜 범위 오류).
- 실제: 500 Spring 기본 오류 본문. 로그는 `Data truncation: Incorrect date value: '10000-01-01' for column 'work_date'` 이다. 트랜잭션은 롤백되어 DB 에는 남지 않는다. `{"date":"9999-12-31",…}` 단건 생성은 201 로 저장된다.
- 원인: `service/ShiftService.java:118` 의 `request.date().plusWeeks(w)` 가 MySQL `DATE` 최대값(9999-12-31)을 넘는다. 생성(`ShiftService.java:96-137`)에는 날짜 범위 검증이 없다.
- 영향: 사용자 영향은 작다(FE 는 오늘+180일까지만 고르게 한다). 하지만 API 가 500 을 내고, 아주 먼 날짜 근무(9999-12-31)가 `/me/state` 에 들어간다.

### [낮음] 근무 생성은 지난 날짜를 받는데, 수정은 지난 날짜로 옮기기를 막는다
- 재현:
  ```sh
  curl -s -X POST $B/stores/12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2020-01-01","startMin":540,"endMin":600,"staffIds":[12]}'     # 201
  curl -s -X PATCH $B/stores/12/shifts/6 -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2026-11-01"}'                                                  # 400 PAST_DATE
  ```
- 기대: 둘 중 한 규칙으로 통일. FE 모바일 추가 화면은 오늘 이후만 고르게 한다(`shift_add_screen.dart:60`).
- 실제: 생성은 201 이고, 직원에게 지난 근무인데도 "새 근무가 배정됐어요" 알림이 간다. 수정은 400 `PAST_DATE` 다.
- 원인: `service/ShiftService.java:161-164` 에만 지난 날짜 검사가 있다. `create`(`:96-137`)에는 없다.
- 영향: 지난 근무를 만들고 수동 출근 기록을 붙이는 정정 용도라면 수정 쪽 제한이 오히려 불편하다. 의도를 정해 맞출 필요가 있다.

### [낮음] 시간을 바꿔도 휴게가 다시 계산되지 않고, 근무 길이 상한이 없다
- 재현:
  ```sh
  curl -s -X POST $B/stores/12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2027-03-02","startMin":540,"endMin":600,"staffIds":[14]}'     # breakMin 0, id 622
  curl -s -X PATCH $B/stores/12/shifts/622 -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"startMin":540,"endMin":1200}'                                         # 11시간, breakMin 0
  curl -s -X POST $B/stores/12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2026-12-10","startMin":1380,"endMin":1379,"staffIds":[14]}'   # 23시간 59분 근무 201
  ```
- 기대: 휴게를 보내지 않고 시간을 바꾸면 법정 최소 휴게(8시간 이상 60분)를 적용하거나 400. 하루 근무 길이에도 상한.
- 실제: 11시간 근무가 `breakMin 0`, `scheduledMinutes 660` 으로 저장된다. 23시간 59분 근무도 생성된다.
- 원인: `service/ShiftService.java:185` 는 `breakMin` 이 왔을 때만 바꾼다. `requireValidTime`(`:465-469`)은 시작과 종료가 같은지만 본다. FE 모바일 수정 화면(`shift_add_screen.dart:111-117`)은 `breakMin` 을 보내지 않고, FE 로컬 `updateShift` 도 휴게를 유지해서 양쪽이 같은 결과다.
- 영향: 모바일에서 근무 시간을 늘리면 휴게 없는 장시간 근무가 남는다. 급여는 휴게만큼 많이 계산된다.

### [낮음] 잘못된 JSON·날짜·enum 은 공통 오류 형식이 아닌 Spring 기본 400 본문
- 재현: `-d '{"date":"2026-02-30",…}'`, `"kind":"vacation"`, `"startMin":"abc"`, 빈 본문, 깨진 JSON, `GET /shifts?from=2026-13-01`.
- 기대: `{code, message, details}`.
- 실제: `{"timestamp":…,"status":400,"error":"Bad Request","path":…}`.
- 원인: `controller/ApiExceptionHandler.java` 가 `HttpMessageNotReadableException`·`MethodArgumentTypeMismatchException` 을 처리하지 않는다. 23번(robustness) 영역과 겹친다.
- 영향: FE 는 `message` 가 없어 일반 오류 문구만 보여 준다. 정상 UI 로는 거의 생기지 않는다.

## 통과한 케이스
- 생성 정상(파트·kind·timeTbd 지정)이면 201 이고 `breakMin` 이 자동 계산된다(4시간 30분, 8시간 60분, 그 외 0).
- 같은 직원 시간이 겹치면 409 `SHIFT_OVERLAP` 이고, 끝과 시작이 맞닿으면 허용된다.
- 자정 넘김 근무(22:00–02:00) 뒤 다음 날 01:00 근무는 409, 02:00 근무는 허용된다.
- 23:59 길이 야간 근무 뒤 다음 날 근무는 409 다.
- `startMin == endMin` 은 400 `INVALID_TIME` 이다(생성·수정 모두).
- `endMin` 1440, `startMin` -1, 수정 `startMin` 1440 은 400 `VALIDATION_FAILED` 다.
- `date` 누락, 빈 `staffIds`, `repeatWeeks` 0, `breakMin` -5, `part` 51자는 모두 400 이다.
- `repeatWeeks` 53 은 400 `REPEAT_TOO_LONG` 이다.
- `staffIds` 에 `null`, 없는 id, 다른 매장 직원 id 를 넣으면 404 다.
- 미승인 직원은 409 `NOT_ACTIVE` 다(생성·수정 담당자 변경 모두).
- 퇴사자에게 새로 생성하거나 담당자를 바꾸면 409 `NOT_ACTIVE` 다.
- `staffIds` 를 문자열 `"12"` 로 보내도 처리된다.
- `staffIds` 에 같은 id 를 중복으로 넣으면 1건만 생성된다.
- 이모지·HTML·SQL 조각이 든 `part` 는 그대로 저장되고 그대로 응답된다.
- 시간 미정(TBD) 근무나 연차 근무는 실제 근무와 겹쳐도 생성된다(설계상 검사 대상 아님).
- TBD 를 확정(`timeTbd:false`)하거나 연차를 근무로 바꾸면 겹침이 검사되어 409 다.
- 반복 생성 중 3주차가 겹치면 409 이고, 전체가 롤백되며 1주차 알림도 남지 않는다.
- 같은 생성을 순서대로 두 번 보내면 두 번째는 409 다.
- 알바생·다른 매장 사장님의 생성·수정·삭제는 403 이고, 인증이 없으면 401 이다.
- 단건 조회는 사장님·재직 직원 200, 미승인·퇴사자·다른 매장 사장님 403, 없는 id 404 다.
- 다른 매장 경로로 이 매장 근무를 조회·수정하면 404 다.
- 다른 매장 경로로 삭제하면 204 지만 실제로 지워지지 않는다(멱등 규칙대로).
- 수정 시 자기 자신은 겹침 검사에서 제외된다.
- 자정 넘김으로 수정, 오늘 날짜로 이동은 200 이다.
- 어제나 지난달로 이동하면 400 `PAST_DATE` 다.
- 빈 PATCH 본문은 200 이고 변경이 없다.
- 출근 기록 있는 근무를 수정(빈 본문 포함)하거나 삭제하면 409 `ATTENDANCE_EXISTS` 다.
- 출근 기록 있는 근무와 겹치게 생성하면 409 다.
- 삭제는 204 이고, 두 번 삭제해도 204 다(멱등).
- 퇴사 처리 때 오늘 이후 근무(12/1, 12/2, 12/5)가 지워지고 지난 근무(11/10)는 남는다.
- 목록은 기본이 이번 달이다.
- 목록 `from > to` 는 400 `INVALID_RANGE`, 366일 초과는 400 `RANGE_TOO_LONG` 이다.
- 목록 `staffId` 필터와 `workOnly=true`(연차·TBD 제외)가 맞게 동작한다.
- 목록은 알바생 200, 다른 매장 사장님 403 이다.
- FE `addShift`/`updateShift`/`deleteShift` 가 보내는 본문 키(`date`, `startMin`, `endMin`, `part`, `staffIds`, `breakMin`, `repeatWeeks`, `kind`, `timeTbd`, `staffId`)를 BE 가 모두 받는다.
- 응답 키(`id`, `staffId`, `date`, `kind` camel, `isWork`, `scheduledMinutes`)가 FE `Shift` 와 맞다. 응답에 `work` 키가 하나 더 붙지만 FE 는 무시한다.

## 못 한 것
- 대타 요청이 걸린 근무의 수정·삭제 뒤 대타 상태 변화는 13번(substitute) 영역이라 코드만 확인했다(`ShiftService.java:189-193`, `ScheduleDeleter`). 요청으로 재현하지 않았다.
- 서로 다른 두 근무를 동시에 같은 칸으로 PATCH 하는 경우는 실행하지 않았다. 생성 동시성과 같은 원인(검사 후 저장, 잠금 없음)으로 보인다.
- `/me/state` 의 9999년·2020년 근무와 음수 `scheduledMinutes` 를 FE 가 파싱하는지는 20번 영역으로 넘겼다.
- 파트 이름이 매장 파트에 없는 값이어도 저장된다. FE 가 유동 근무용 이름을 쓰므로 의도된 동작으로 보고 버그로 적지 않았다.
- 알바(파트타이머)에게도 `timeTbd:true` 가 저장된다. FE 웹은 유동 직원만 TBD 로 만들지만 BE 는 막지 않는다. 의도가 불분명해 발견에 넣지 않았다.
