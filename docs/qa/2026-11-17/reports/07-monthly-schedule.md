# 07 monthly-schedule QA 보고서

## 요약

- 대상: `POST /stores/{id}/schedules`, `PUT /schedules/{month}/shifts`, `POST /schedules/{month}/confirm`, `DELETE /schedules/{month}` 와 작성 중/확정 상태 전이. 코드는 `MonthScheduleService.java`, `ScheduleController.java`, FE `app_store.dart`(`saveSchedule`·`createMonthSchedule`·`confirmMonth`·`deleteMonthSchedule`), `web_schedule_screen.dart`.
- 테스트 데이터: 사장님 `a07-owner`, 매장 15 `QA07 카페`(코드 `EL8M-QZL9`), 알바 `a07-staff1`(staffId 20, 테스트 중 퇴사), `a07-staff2`(staffId 21, 재직), `a07-staff3`(staffId 22, 승인 대기). 다른 사장님은 `a07-owner2`. 서버 시각은 2026-11-17 23시 무렵(KST)이다.
- 실행한 케이스: 72개. 통과: 61개. 발견: 9건(치명 1, 높음 1, 중간 4, 낮음 3).

아래 재현에서 `$H=http://127.0.0.1:18080/api/v1`, `O=$(qa-user a07-owner)` 를 쓴다. 매장·직원 id 는 이 실행에서 받은 값이다(매장 15, 재직 직원 21, 퇴사 직원 20).

## 발견

### [치명] 지난달보다 오래된 달을 웹 편집기에서 저장하면 그 달 앞부분 근무가 지워진다

- 재현:
  ```sh
  curl -X POST $H/stores/15/schedules -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"month":"2026-09","prefillFixed":false}'
  curl -X PUT $H/stores/15/schedules/2026-09/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"shifts":[{"staffId":21,"date":"2026-09-05","startMin":540,"endMin":1080,"kind":"leave"},{"staffId":21,"date":"2026-09-10","startMin":540,"endMin":1080,"kind":"off"},{"staffId":21,"date":"2026-09-15","startMin":540,"endMin":1080},{"staffId":21,"date":"2026-09-29","startMin":540,"endMin":1080}]}'
  # FE saveSchedule 와 똑같이: /me/state 에서 이 매장의 2026-09 근무를 모아 PUT
  curl $H/me/state -H "Authorization: Bearer $O"   # shifts 에 2026-09 근무는 09-29 하나뿐
  curl -X PUT $H/stores/15/schedules/2026-09/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"shifts":[{"id":1050,"staffId":21,"date":"2026-09-29","startMin":540,"endMin":1080,"part":"","breakMin":60,"kind":"work","timeTbd":false}]}'
  qa-sql "SELECT schedule_id,work_date,kind FROM schedule WHERE mapping_id=21 AND work_date LIKE '2026-09%'"
  ```
- 기대: FE 가 받지 못한 근무는 지워지지 않는다. 또는 BE 가 `/me/state` 범위 밖 달의 통째 저장을 막는다.
- 실제: 200 `{"skipped":[]}`. 09-05 연차(LEAVE), 09-10 휴무, 09-15 근무가 DB 에서 지워지고 09-29 만 남았다.
- 원인: `/me/state` 는 근무를 `today.minusMonths(1).withDayOfMonth(1).with(MONDAY)` 부터만 내려준다(`StateService.java:124`, 오늘 기준 2026-09-28부터). 월 메타(`schedules`)는 기간 제한 없이 모두 내려준다. 웹 목록은 모든 메타를 보여 주고, 편집기는 메타만 있으면 열린다(`web_schedule_screen.dart:227`, 월 이동 `:136`). 편집 뒤 `saveSchedule` 은 로컬에 있는 그 달 근무만 보내고(`app_store.dart:1126`), BE 는 목록에 없는 그 달 근무 중 출근 기록이 없는 것을 모두 지운다(`MonthScheduleService.java:230-235`).
- 영향: 사장님이 두 달 이상 지난 근무표를 열어 한 칸만 고쳐 저장해도 그 달 앞부분 근무가 사라진다. 출근 기록이 있는 근무는 남지만, 연차·휴무·시간 미정·출근을 안 찍은 근무는 지워진다. 연차가 지워지면 확정 급여가 바뀐다. 사장님에게는 "저장했어요" 토스트만 뜬다.

### [높음] 연차·휴무·시간 미정 근무는 시각·휴게를 검사하지 않아 연차 급여가 부풀려진다

- 재현:
  ```sh
  curl -X PUT $H/stores/15/schedules/2026-11/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"shifts":[{"staffId":21,"date":"2026-11-02","startMin":0,"endMin":2880,"kind":"leave","breakMin":-10000}]}'
  curl "$H/stores/15/staff/21/payslips/2026-11" -H "Authorization: Bearer $O"
  ```
- 기대: 400. `kind=work` 일 때처럼 24시간을 넘는 근무와 음수 휴게를 막는다(`INVALID_TIME`·`INVALID_BREAK`).
- 실제: 200 으로 저장된다(DB `break_min=-10000`, 0:00부터 이틀 뒤 0:00). 급여 명세는 연차 한 건이 `"minutes":12880, "base":2215360, "weeklyHoliday":82560, "gross":2297920` 이다. 같은 연차를 10:00–18:00, 휴게 60으로 넣으면 `"minutes":420, "base":72240` 이다.
- 원인: 24시간·휴게 범위 검사가 `kind == WORK && !timeTbd` 일 때만 돈다(`MonthScheduleService.java:194`). 그런데 연차는 `scheduledMinutes() = endAbs - startMin - breakMin` 만큼 유급이다(`PayrollCalculator.java:74-77`). 그래서 음수 휴게나 48시간 연차가 그대로 급여가 된다. 요청 DTO `breakMin` 에도 범위 제한이 없다(`MonthScheduleCommandDto.java:32`).
- 영향: 입력 실수나 잘못된 클라이언트 값 하나로 그 달 기본급·주휴수당·세금이 크게 틀린다. 인건비 통계도 같이 틀린다.

### [중간] 퇴사자의 지난 근무를 퇴사일 뒤 날짜로 옮길 수 있다

- 재현: 퇴사 직원 20의 지난 근무(11-15, 출근 기록 없음, id 446)를 11-28로 옮긴다.
  ```sh
  curl -X DELETE $H/stores/15/staff/20 -H "Authorization: Bearer $O"     # left_at 2026-11-17
  curl -X PUT $H/stores/15/schedules/2026-11/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"shifts":[{"id":"170","staffId":20,"date":"2026-11-10","startMin":600,"endMin":1080},{"id":"446","staffId":20,"date":"2026-11-28","startMin":540,"endMin":1080}]}'
  ```
- 기대: 퇴사자 근무는 그대로 둘 때만 받는다. 날짜를 바꾸면 `STAFF_NOT_FOUND`(새 배정과 같은 400).
- 실제: 200. DB 에 `mapping_id=20, work_date=2026-11-28` 이 생기고 `/me/state` 에도 보인다. 같은 직원 20으로 새 근무를 넣으면 400 `STAFF_NOT_FOUND` 가 난다.
- 원인: `MonthScheduleService.java:184` 는 담당자 id 가 같기만 하면 퇴사자를 받는다. 날짜·시각이 바뀌는지는 보지 않는다.
- 영향: 퇴사자 근무가 앞으로의 근무표에 남는다. 그 칸은 실제로 비어 있는데 채워진 것처럼 보이고, 예상 인건비에도 들어간다. 대타·출근 흐름에서 퇴사자 근무가 섞인다.

### [중간] 확정된 근무표를 삭제해도 직원에게 알리지 않는다

- 재현:
  ```sh
  # 2026-12 확정(직원 21에게 12/3·12/4 근무, "12월 근무표가 확정됐어요" 알림 받음)
  curl -X DELETE $H/stores/15/schedules/2026-12 -H "Authorization: Bearer $O"    # 204
  qa-sql "SELECT notification_id,to_user_id,title FROM notification WHERE store_id=15 ORDER BY 1 DESC LIMIT 3"
  ```
- 기대: 확정 달에서 근무가 지워지면 해당 직원에게 "확정 근무표가 바뀌었어요" 알림이 간다. 같은 달을 `PUT .../shifts` 로 비우면 이 알림이 간다.
- 실제: 204. 근무와 메타는 지워지고 새 알림은 없다. 직원 화면에서는 확정 근무가 말없이 사라진다.
- 원인: `MonthScheduleService.java:318-323` `delete` 는 확정 여부를 보지 않고 `removeShifts` 만 부른다. `saveShifts` 는 확정 달의 삭제를 `ChangedDays` 로 알린다(`:244`).
- 영향: 알바생은 확정 알림을 받은 근무가 없어진 것을 모른다. 출근하러 왔다가 근무가 없을 수 있다. FE 삭제 확인 창도 "확정된 근무표예요"라고만 말한다(`web_schedule_screen.dart:198`).

### [중간] `part` 가 50자를 넘으면 500

- 재현:
  ```sh
  L=$(printf 'ㄱ%.0s' {1..51})
  curl -X PUT $H/stores/15/schedules/2026-12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d "{\"shifts\":[{\"staffId\":21,\"date\":\"2026-12-09\",\"startMin\":600,\"endMin\":700,\"part\":\"$L\"}]}"
  ```
- 기대: 400 `VALIDATION_FAILED`(`{code,message,details}`).
- 실제: 500 `{"timestamp":...,"status":500,"error":"Internal Server Error"}`. 로그는 `Data truncation: Data too long for column 'part'` 이다.
- 원인: `ShiftItem.part` 에 `@Size(max=50)` 가 없다(`MonthScheduleCommandDto.java:31`). 컬럼은 `@Column(length = 50)` 이다(`Schedule.java` `part`).
- 영향: 그 달 저장이 통째로 실패하고, FE 는 원인 없는 오류만 보여 준다. 파트 이름은 매장 설정에서 오므로 보통은 50자를 넘지 않는다.

### [중간] `shifts` 배열에 `null` 이 있으면 500 (NPE)

- 재현:
  ```sh
  curl -X PUT $H/stores/15/schedules/2026-12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"shifts":[null]}'
  ```
- 기대: 400.
- 실제: 500. 로그는 `NullPointerException: Cannot invoke "...ShiftItem.id()" because "it" is null at MonthScheduleService.saveShifts(MonthScheduleService.java:180)` 이다.
- 원인: `SaveShiftsRequest.shifts` 가 `@NotNull @Valid List<ShiftItem>` 이라 원소 null 을 막지 않는다(`List<@NotNull ShiftItem>` 아님). `MonthScheduleService.java:180` 에서 바로 역참조한다.
- 영향: FE 는 null 을 보내지 않는다. 잘못된 클라이언트 요청이 400 이 아니라 500 으로 기록된다.

### [낮음] 확정된 달을 바꾸지 않고 저장해도 `part` 가 없던 근무 때문에 "확정 근무표가 바뀌었어요" 알림이 간다

- 재현: 확정된 2026-12 에 `part` 없이 만든 근무 692(DB `part IS NULL`)가 있다. FE 처럼 `/me/state` 값을 그대로 다시 저장한다.
  ```sh
  curl -X PUT $H/stores/15/schedules/2026-12/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"shifts":[{"id":692,"staffId":21,"date":"2026-12-09","startMin":540,"endMin":600,"part":"","breakMin":0,"kind":"work","timeTbd":false}]}'
  ```
- 기대: 바뀐 것이 없으니 알림이 없다.
- 실제: 직원 21에게 "12월 확정 근무표가 바뀌었어요 / 12/9" 알림이 1건 생긴다(같은 저장을 한 번 더 하면 생기지 않는다).
- 원인: `/me/state` 는 null part 를 `""` 로 내려준다(`ScheduleDto.java:116`). 저장은 받은 `""` 를 그대로 넣는다(`MonthScheduleService.java:219`). 비교 서명 `signature` 는 `null` 과 `""` 를 다르게 본다(`:259`).
- 영향: `part` 없는 근무(예전 API·직접 호출로 생긴 근무)가 있는 확정 달에서 사장님이 다른 칸만 고쳐도, 상관없는 직원이 잘못된 변경 알림을 받는다.

### [낮음] 통째 저장에는 "3개월 뒤까지" 제한이 없어 안 보이는 근무가 생긴다

- 재현:
  ```sh
  curl -X PUT $H/stores/15/schedules/2030-01/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"shifts":[{"staffId":21,"date":"2030-01-02","startMin":540,"endMin":1080}]}'      # 200
  curl -X POST $H/stores/15/schedules -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"month":"2027-03"}'  # 400 MONTH_TOO_FAR
  ```
- 기대: `create` 처럼 400 `MONTH_TOO_FAR`.
- 실제: 200. 근무 639(2030-01-02)가 DB 에 생기고 `/me/state` 에는 나오지 않는다. 메타가 없어서 확정도 404 다.
- 원인: `create`(`MonthScheduleService.java:111`)·템플릿 적용(`:353`)·미리보기(`:405`)는 `writableMonth` 를 쓴다(주석 `:643` 이 바로 이 문제를 설명한다). 그런데 `saveShifts` 는 `parseMonth` 만 쓴다(`:152`).
- 영향: FE 로는 만들 수 없고 직접 호출해야 생긴다. 이렇게 생긴 근무는 화면에 안 보이지만 직원 겹침 검사·급여 계산에는 들어간다.

### [낮음] 확정된 달에 시간 미정 근무를 넣을 수 있다

- 재현: 확정된 2026-12 에 `{"staffId":21,"date":"2026-12-05","startMin":540,"endMin":1080,"timeTbd":true}` 를 넣어 `PUT .../2026-12/shifts` 를 보낸다.
- 기대: 확정은 "미정 없음"이 조건(`confirm` 은 409 `TBD_REMAINING`)이니 확정 달 저장도 미정을 막거나 상태를 작성 중으로 돌린다.
- 실제: 200. 상태는 `confirmed` 로 남고 미정 근무가 생긴다. 직원에게 변경 알림(12/5)이 간다.
- 원인: `saveShifts` 는 확정 여부를 알림에만 쓰고(`MonthScheduleService.java:169`) 미정 검사를 하지 않는다.
- 영향: 직원은 "확정" 근무표에서 시간이 정해지지 않은 근무를 본다. 확정 버튼은 이미 꺼져 있어 사장님은 다시 확인받는 흐름이 없다.

## 통과한 케이스

- create: 새 달 → 200 draft/manual. 같은 달 두 번 → 같은 id, updatedAt 갱신. prefillFixed 생략(=true) 두 번 → 고정 파트 근무 4건, 중복 없음. 이번 달은 오늘 이후 날짜만 채움.
- create: `2026-13`·`2026-1`·숫자 `123` → 400 형식 오류. month 없음 → 400. `2027-03`(3개월 넘음) → 400 `MONTH_TOO_FAR`. `2027-02` → 200.
- create: 확정된 달 → 상태 그대로 confirmed 로 돌려줌. 삭제한 달 다시 만들기 → 새 draft.
- save: 새 근무 2건(임시 문자열 id·id 없음) → 저장. breakMin 생략 시 자동(9h → 60분).
- save: 목록에서 뺀 근무 → 삭제(통째 저장 의미대로).
- save: 승인 대기 직원·다른 매장 직원·없는 staffId → 400 `STAFF_NOT_FOUND`.
- save: 다른 달 날짜 → 400 `DATE_OUT_OF_MONTH`.
- save: 경로 month `2026-13`·`abc`·`2026-1` → 400 `INVALID_MONTH`.
- save: shifts 없음 → 400. date null → 400 `shifts[0].date`. staffId `"abc"`·kind `"vacation"`·`2026-02-30` → 400.
- save: startMin -1·1440, endMin 2881 → 400 `INVALID_TIME`. 1439→2880(24h 초과) → 400.
- save: 휴게 101(근무 100분)·-5 → 400 `INVALID_BREAK`.
- save: 같은 직원 같은 날 겹침 → 400 `SHIFT_OVERLAP`. 야간(22–06)과 다음 날 05시 → 400. 맞닿은 근무(–11:40, 11:40–) → 200. endMin 1500 과 다음 날 00–02 → 400.
- save: 이웃 달 야간 근무(11/30 22–06)와 12/1 03시 → 400. 1/1 02시 근무가 있을 때 12/31 22–06 → 400.
- save: 이모지·HTML 파트명 → 그대로 저장.
- save: 출근 기록 있는 근무를 목록에서 빼면 `skipped`("삭제하지 않았어요"). 날짜·사람을 바꾸면 skipped. 휴무·시간 미정으로 바꾸면 skipped. 시각만 바꾸면 반영.
- save: 퇴사자의 지난 근무를 그대로 보내면 200. 퇴사자에게 새 근무를 주면 400. 퇴사자 근무를 재직자로 넘기면 200.
- save: 다른 매장 근무 id 를 보내면 그 근무는 건드리지 않고 새 근무로 만든다(다른 매장 근무 3 그대로).
- save: 확정 달에서 바뀐 것 없이 저장(part 있음)하면 알림이 없다. 시각을 바꾸면 그 직원에게 알림 1건(바뀐 날짜 본문).
- confirm: 메타 없음 → 404. month 형식 오류 → 400. 미정 남음 → 409 `TBD_REMAINING`. 정상 → 204, 재직 직원에게 "12월 근무표가 확정됐어요". 두 번째 confirm → 204, 알림을 다시 보내지 않음.
- delete: 출근 기록 있는 근무는 남기고 나머지와 메타를 지움. 없는 달 → 204. `2027-1` → 400.
- 권한: 알바생의 create·save·confirm·delete → 403. 다른 사장님 → 403. 인증 없음 → 401. 없는 매장 → 404.
- `/me/state`: `schedules` 의 id·storeId 는 문자열, status·source·weeklyHolidayPay·priority 는 Dart `.name`, `v` 는 4. 응답 `skipped[].id` 는 문자열이다(FE 는 개수만 쓴다).

## 못 한 것

- 저장·확정·삭제가 동시에 겹치는 경우: 24번(concurrency) 영역이다. 코드로 보면 `delete` 는 `saveShifts`·`confirm` 과 달리 `monthRepo.lockStore` 를 잡지 않는다(`MonthScheduleService.java:318`). 실행해서 확인하지는 않았다.
- autofill·generate·templates: 08·09·10번 영역이라 create 의 prefill 만 봤다.
- 웹 화면 직접 조작: 웹 컨테이너가 없다. FE 동작은 `app_store.dart` 의 요청 모양을 curl 로 흉내 냈다.
- 참고(별도 보고하지 않음):
  - 깨진 JSON·타입 오류는 Spring 기본 `{timestamp,status,error,path}` 형식으로 온다(23번 영역).
  - `"date":"2026-12-31T00:00"` 같은 시각 붙은 날짜도 받는다(Jackson 관대 파싱).
  - `startMin == endMin` 은 24시간 근무로 저장된다(설계상 end ≤ start = 야간).
  - 휴게 = 근무 길이(실근무 0분)도 받는다.
  - 테스트 중 직원 PATCH 한 번이 500 이었고, 다시 보내니 200 이었다. 같은 시각 로그에 다른 에이전트의 데드락이 있어 일시적인 것으로 보고 넘겼다.
- 데이터: 매장 15 의 테스트 데이터를 지우지 않고 그대로 두었다.
