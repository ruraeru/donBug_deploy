# 08 schedule-autofill QA 보고서

## 요약

- 실행한 케이스: 89건. 통과 72건, 실패 17건. 실패는 아래 발견 10건으로 묶었다.
- 발견: 치명 0 · 높음 1 · 중간 4 · 낮음 5
- 테스트 날짜: 2026-11-17(화). 매장 22 `QA08 카페`(사장님 `a08-owner`, 알바 `a08-s1`~`s4`, 매니저 `a08-m1`, 정직원 `a08-f1`, 연소자 `a08-y1`), 매장 81 `QA08 타매장`(사장님 `a08-other`, 연소자 `a08-y2`).
- 재현에서 `T_xxx=$(qa-user a08-xxx)`, `B=http://127.0.0.1:18080/api/v1` 로 둔다. 매장 22 파트: 오픈 08–12, 미들 12–17, 마감 17–22. 직원 id: s1=38(오픈 월–금 고정), s2=40(마감 매일), s3=42(미들 월·수·금), s4=43(고정 없음), m1=44(매니저, 월·화·목·금 09–18), y1=46(연소자, 토 마감).
- FE 계산을 확인할 때는 FE `autoschedule.dart`·`models.dart` 를 scratchpad 에 복사했다(flutter import 만 바꿈). 그리고 실제 `/me/state` JSON 을 `AppState.fromJson` 으로 읽어 `dart run` 으로 돌렸다. 스크립트는 `/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/0be996b6-b382-431e-9a21-1f48ed02dedf/scratchpad/a08/fe/` 에 있다(`run.dart`, `body.dart`, `tpl.dart`).

FE 가 지금 실제로 쓰는 경로부터 적는다.
- 웹 근무표 편집기 "자동 채우기"는 항상 FE 로컬에서 계산한다. 편집기가 늘 초안 모드이기 때문이다. 결과는 `PUT /schedules/{month}/shifts` 로 저장된다.
- "직접 만들기"는 `POST /schedules`(prefillFixed) 를 부른다. 이 호출이 BE 의 고정 근무 채우기 로직을 쓴다.
- 모바일 사장님 템플릿 화면은 `POST /schedule/template` 을 쓴다.
- `/schedule/auto-fill`, `/schedule-plans`·`apply`, `/schedule/confirm` 은 FE `app_store.dart` 에 메서드는 있다. 하지만 화면에서 부르는 곳은 없다(레거시).
- `POST /schedules/{month}/autofill` 도 지금 FE 화면에서는 닿지 않는다. 호출 조건 `remote && !_draft` 가 웹 편집기에서는 늘 거짓이다.

## 발견

### [높음] 같은 달 고정 근무 채우기를 동시에 보내면 같은 근무가 여러 벌 생기고, 그 달 저장이 막힌다
- 재현 (매장 81, 연소자 y2 에 월요일 `야간` 22:00–02:00 고정):
  ```sh
  T=$(qa-user a08-other)
  curl -X PUT $B/stores/81/schedules/2027-01/shifts -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"shifts":[]}'
  for i in 1 2 3; do curl -s -o /dev/null -w "%{http_code} " -X POST $B/stores/81/schedules -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"month":"2027-01","prefillFixed":true}' & done; wait
  # → 200 200 200
  qa-sql "SELECT work_date, count(*) FROM schedule s JOIN store_worker w ON w.mapping_id=s.mapping_id WHERE w.store_id=81 AND work_date LIKE '2027-01%' GROUP BY work_date"
  # → 1/4, 1/11, 1/18, 1/25 각 3건 (같은 직원·같은 시간)
  ```
  `POST /stores/81/schedules/2026-12/autofill` 를 5개 동시에 보내도 같다. 응답은 204 5개이고, 월요일마다 같은 근무가 5건 생겼다.
- 기대: 고정 근무가 날짜마다 1건만 생긴다. 두 번째 요청은 "이미 있음"으로 건너뛴다.
- 실제: 요청 수만큼 같은 근무가 생긴다. 그 뒤 그 달 근무를 그대로 `PUT /schedules/2027-01/shifts` 하면 이렇게 실패한다:
  `400 {"code":"SHIFT_OVERLAP","message":"연소이님의 근무 시간이 겹쳐요 (1/4 22:00–02:00)"}`
  새 달(메타 없음)에 동시에 보내면 1건은 `500` 이다(`uk_month_schedule_store_month` 충돌).
- 원인: `MonthScheduleService.java:108-133` 의 `create`·`autofill` 에는 매장 잠금이 없다. `saveShifts` 는 `:151` 에서 `monthRepo.lockStore` 를 잡는다. `fill`(`:136-144`)은 기존 근무를 트랜잭션 시작 때 읽는다. `saveRows`(`:703-710`) 의 `overlapChecker.hasOverlap` 도 다른 트랜잭션이 아직 커밋하지 않은 근무를 보지 못한다.
- 영향: 사장님이 "직접 만들기"(초안이 이미 있는 달)를 두 번 누르거나, 네트워크 재시도가 일어나면 직원 근무가 2–3배로 생긴다. 예정 근무 기준 인건비·주휴 판정이 부풀고, 편집기 저장은 겹침 400 으로 막힌다. 사장님은 중복 근무를 손으로 하나씩 지워야 한다.

### [중간] 웹 편집기 "자동 채우기"는 FE 로컬 계산이라 BE 규칙과 다르다: 영업시간·공휴일 무시, 휴무일에도 넣음, 겹침 때문에 저장 실패
- 재현:
  1. 주말·공휴일 영업시간을 10:00–20:00 으로 둔다: `PATCH $B/stores/22/settings {"weekendOpenMin":600,"weekendCloseMin":1200}`
  2. 비어 있는 2027-01 을 비교한다.
     - FE 계산(`fe/run.dart 2027-01`): 1/1(신정, 금) `오픈 480-720 b30`, `마감 1020-1320 b30`. 1/2(토) `마감 1020-1320` 2건.
     - BE `POST $B/stores/22/schedules/2027-01/autofill` 결과: 1/1 `오픈 600-720 b0`, `마감 1020-1200 b0`. 1/2 `마감 1020-1200` 2건.
  3. 휴무·겹침:
     ```sh
     curl -X POST $B/stores/22/shifts -d '{"date":"2027-02-01","startMin":480,"endMin":720,"staffIds":[38],"kind":"off"}'   # s1 휴무
     curl -X POST $B/stores/22/shifts -d '{"date":"2027-02-01","startMin":600,"endMin":780,"staffIds":[42],"part":"기타"}' # s3 수동 근무
     ```
     FE 자동 채우기 결과: s1 은 휴무일인 2/1 에도 `오픈 480-720` 을 받는다. s3 는 수동 근무와 겹치는 `미들 720-1020` 을 받는다. FE `saveSchedule` 과 같은 본문(`fe/body.dart 2027-02` → `feb.json`)으로 저장해 본다:
     `PUT $B/stores/22/schedules/2027-02/shifts` → `400 {"code":"SHIFT_OVERLAP","message":"알바삼님의 근무 시간이 겹쳐요 (2/1 12:00–17:00)"}`
     같은 데이터에 BE autofill 을 돌리면 휴무·연차 날과 겹치는 근무를 건너뛰고 정상으로 끝난다.
- 기대: 화면 버튼과 서버 API 가 같은 규칙을 쓴다. 영업시간에 맞춰 자르고 휴게를 다시 계산한다. 휴무·연차 날과 겹치는 근무는 건너뛴다.
- 실제: 편집기는 늘 초안 모드다(`web_schedule_screen.dart:95` `setScheduleDraft(true)`). 그래서 `app_store.dart:2187` `if (remote && !_draft)` 가 거짓이 되어, BE autofill 대신 FE `autoschedule.dart` 로 계산한다.
- 원인: FE 쪽 규칙이 BE 와 다르다.
  - `autoschedule.dart:65` 는 알바 파트를 영업시간으로 자르지 않는다(BE `FixedShiftPlanner.java:89-99` 는 자른다).
  - `autoschedule.dart:85` 는 `leave` 만 건너뛴다(BE `MonthScheduleService.java:142` 는 `off` 도 건너뛴다).
  - FE 는 겹침 검사를 하지 않는다(BE `MonthScheduleService.java:706`).
- 영향: 공휴일·주말에 영업 전후 시간 근무가 생긴다. 휴무를 준 날에도 근무가 다시 생긴다. 알바에게 다른 수동 근무가 있으면 "자동 채우기 → 저장"이 겹침 오류로 실패한다. 사장님은 어느 근무가 자동으로 생긴 것인지 찾아서 지워야 한다.

### [중간] 고정 근무 채우기·근무표 만들기가 3개월 제한을 지나쳐서, 화면에 안 보이는 근무를 만든다
- 재현:
  ```sh
  curl -X POST $B/stores/22/schedules -d '{"month":"2027-06","prefillFixed":true}'   # 400 MONTH_TOO_FAR (정상)
  curl -X POST $B/stores/22/schedules/2027-06/autofill                              # 204, 86건 생성
  curl -X POST $B/stores/22/schedules/9999-12/autofill                              # 204, 90건 생성
  P=$(curl -X POST $B/stores/22/schedule-plans -d '{"from":"2027-09-01","to":"2027-09-07","needs":[1,1,1],"copyLastWeek":false}' | jq -r .planId)
  curl -X POST $B/stores/22/schedule-plans/$P/apply -d '{"needs":[1,1,1]}'           # {"added":21}
  ```
  `/me/state` 의 `shifts` 는 사장님·알바 모두 2027-02-28 까지만 있다. 2027-09 근무는 0건이다. 그런데 직원 알림에는 "9월 근무가 추가됐어요 · 7건 · 9/1~9/7" 이 생겼다.
- 기대: `POST /schedules` 처럼 `MONTH_TOO_FAR` 400 을 준다.
- 실제: 204 또는 200 이 오고 근무가 저장된다.
- 원인:
  - `MonthScheduleService.java:131` 의 `autofill` 은 `writableMonth` 대신 `parseMonth` 를 쓴다(`:646-652` 의 주석이 바로 이 문제를 막으려고 둔 검사다).
  - `ShiftService.java:268-317` 의 `planSchedule` 은 기간만 366일로 제한하고, 3개월 창은 보지 않는다.
- 영향: API 로만 닿는다. FE 편집기는 메타가 있는 달로만 이동한다. 그래도 직원은 볼 수 없는 근무에 대한 알림을 받는다. 그 달이 3개월 창에 들어오면 근무가 갑자기 나타난다. 그때 편집기에서 빈 목록을 저장하면 모두 지워지는 위험이 생긴다. 이것이 `writableMonth` 주석이 말하는 위험이다.

### [중간] 연소자 근로 제한(22:00–06:00 금지, 하루 7시간)을 자동 배정이 보지 않는다
- 재현 (매장 81: 영업 08:00–익일 02:00, 파트 `종일` 09–22(휴게 60), `야간` 22–02):
  ```sh
  curl -X PATCH $B/stores/81/staff/174 -d '{"kind":"minor","part":"야간","fixedParts":[["야간"],[],[],[],[],[],[]]}'   # 200, 막지 않음
  curl -X POST $B/stores/81/schedules/2026-11/autofill    # 204
  # → schedule 1409 2026-11-23 야간 1320-1560, 1410 2026-11-30 야간 1320-1560 (kind MINOR)
  curl -X POST $B/stores/81/schedule-plans -d '{"from":"2026-11-24","to":"2026-11-25","needs":[1,0],"copyLastWeek":false}'
  # → staffId 174(연소자) 에게 2026-11-24 종일 540-1320 (scheduledMinutes 720) 배정
  ```
- 기대: AI 생성 빈칸 채우기(`GapFiller.java:103`: 하루 420분 이하, 06:00–22:00)와 같은 기준을 쓴다. 연소자 야간·장시간 근무는 만들지 않거나 경고한다.
- 실제: 연소자에게 22:00–02:00 근무가 생긴다. 근무표 만들기는 연소자에게 하루 12시간 근무를 준다.
- 원인: 연소자 검사는 `GapFiller.java:27-28,103,110` 에만 있다. `FixedShiftPlanner.fixedShifts`(`:77-113`)는 `Person.minor` 를 쓰지 않는다. `ShiftService.fill`(`:528-575`)은 kind 를 `isFlex` 판정에만 쓴다. `ScheduleInsights` 에도 연소자 경고가 없다.
- 영향: 사장님이 연소자에게 야간 파트를 고정하거나 근무표 만들기를 쓰면, 법정 제한(근로기준법 제69·70조)을 넘는 근무가 아무 경고 없이 확정까지 간다.

### [중간] 템플릿 "지난주 근무 복사"와 레거시 자동 배정은 직원에게 알리지 않고, 확정된 달에도 그대로 근무를 넣는다
- 재현:
  ```sh
  curl -X POST $B/stores/22/schedules -d '{"month":"2026-11","prefillFixed":false}'
  curl -X POST $B/stores/22/schedules/2026-11/confirm        # 204, month_schedule 2026-11 CONFIRMED
  curl -X POST $B/stores/22/schedule/template -d '{"needs":[1,1,1],"copyLastWeek":true}'   # {"copied":3}
  # → 11/20 s4 미들, 11/21 s4 기타, 11/22 s3 마감 생성, notification 0건
  curl -X POST $B/stores/22/schedule/auto-fill -d '{"weekMonday":"2026-12-07"}'           # 2026-12 는 CONFIRMED, {"added":13}, notification 0건
  curl -X POST $B/stores/22/schedules/2026-12/autofill       # 409 ALREADY_CONFIRMED (새 API 는 막음)
  ```
- 기대: 확정된 달에 근무가 추가되면 그 직원에게 알린다(`saveShifts` 는 확정 달 변경을 알리고, `POST /shifts` 는 "새 근무가 배정됐어요" 를 보낸다). 아니면 새 autofill 처럼 409 를 준다.
- 실제: 근무가 추가되고, 알림은 0건이다.
- 원인: `ShiftService.java:368-412`(`applyTemplate`)와 `:236-261`(`autoFill`)에는 확정 여부 검사도 `notifier` 호출도 없다.
- 영향: 모바일 사장님 템플릿 화면(`schedule_template_screen.dart:25-27`)이 실제로 이 API 를 쓴다. 알바생은 확정된 근무표에 새 근무가 생긴 줄 모른다. 결근으로 처리될 수 있다.

### [낮음] 모바일 템플릿 복사 토스트 건수가 서버 결과와 다르다
- 재현: 위 데이터에 지난주 근무를 넣는다. 11/9 s4 오픈, 11/11 s4 연차, 11/11 s1 휴무, 11/13 s4 미들, 11/14 s4 기타, 11/15 대타 근무(원래 s3).
  - `POST /schedule/template {"copyLastWeek":true}` → 서버 `{"copied":3}`.
  - 같은 상태로 FE `applyTemplate` 로컬 계산을 돌린다(`fe/tpl.dart`) → "지난주 근무 6건을 복사했어요". 지난 날짜인 11/16, 연차, 휴무가 함께 세어진다.
- 기대: 토스트가 서버와 같은 수를 보여 준다.
- 실제: 토스트는 6건이라고 한다. reload 뒤 화면에는 3건만 남는다.
- 원인: `app_store.dart:1572-1590` 은 지난 날짜·연차·휴무·시간 미정을 거르지 않고, 겹침도 보지 않는다. BE `ShiftService.java:383`(`isWork` 만)·`:391`(지난 날 건너뜀)·`:406`(겹침)과 다르다.
- 영향: 사장님이 본 수와 실제 복사된 수가 다르다. 연차·휴무가 복사된 줄 알게 된다.

### [낮음] 레거시 `POST /schedule/confirm` 은 월 메타를 확정하지 않고, 부를 때마다 "확정" 알림을 다시 보낸다
- 재현: `POST /schedules {"month":"2026-12","prefillFixed":false}` 로 DRAFT 를 만든다. 그 뒤 `POST /schedule/confirm {"year":2026,"month":12}` 를 두 번 보낸다.
  - "12월 근무표가 확정됐어요" 알림이 7 → 14건으로 늘었다.
  - `month_schedule` 2026-12 는 계속 `DRAFT` 다.
  - `/schedules/2026-12/confirm` 뒤에야 중복 알림이 멈춘다.
- 기대: 월 메타를 CONFIRMED 로 바꾸거나 새 confirm 으로 위임한다. 중복 알림은 보내지 않는다.
- 실제: DRAFT 달이라 직원에게는 근무가 숨겨져 있다(`StateService.java:67-71`). 그런데 직원은 "확정됐어요" 알림을 받는다.
- 원인: `ShiftService.java:418-433`. 메타가 CONFIRMED 일 때만 중복을 막고, 상태는 바꾸지 않는다.
- 영향: FE 화면은 이 API 를 부르지 않는다(`app_store.dart:1381` `confirmSchedule` 호출처 없음). API 를 직접 쓸 때만 생긴다.

### [낮음] 레거시 `/schedule/auto-fill`·`/schedule-plans` 가 영업시간·공휴일·알바 가능 시간을 보지 않고, auto-fill 은 첫 빈칸에서 그 주 전체를 멈춘다
- 재현:
  - 주말 영업 10:00–20:00 인 매장 22 에 `POST /schedule/auto-fill {"weekMonday":"2026-11-16"}` 를 보낸다. 11/21(토)·11/22(일)에 `오픈 480-720` 4건이 생긴다. 고정 파트·가능 시간이 없는 s4·연소자 y1 도 평일에 배정된다.
  - `schedule-plans` 2027-03-01(삼일절)도 `오픈 480-720` 을 배정한다.
  - 매장 81: 11/23 에 연소자가 이미 야간 근무가 있다. `auto-fill {"weekMonday":"2026-11-23"}` 은 `{"added":0}` 이다. 11/24–29 의 `종일` 빈칸도 채우지 않는다.
- 기대: 새 고정 근무 로직(`FixedShiftPlanner`)처럼 영업시간에 맞춰 자른다. 빈칸을 못 채우면 다음 칸으로 넘어간다(FE `app_store.dart:1352` `if (free.isEmpty) break;` 는 그 칸만 건너뛴다).
- 원인: `ShiftService.java:528-575` 의 `fill` 은 store 영업시간·`Holidays`·`availHours` 를 쓰지 않는다. `stopWhenEmpty` 면 `break outer`(`:563` 부근)로 끝난다.
- 영향: FE 화면에서 부르지 않는 레거시라 낮음. API 를 직접 쓰는 클라이언트(예전 앱 버전)에서만 생긴다.

### [낮음] `tbd-count`·`/schedule/confirm` 에 year 10억 이상을 보내면 500
- 재현:
  - `GET $B/stores/22/schedule/tbd-count?year=1000000000&month=1` → `500`
  - `POST $B/stores/22/schedule/confirm {"year":1000000000,"month":1}` → `500`
  - 로그: `java.time.DateTimeException: Invalid value for Year (valid values -999999999 - 999999999): 1000000000`
- 기대: 400 `INVALID_MONTH`.
- 원인: `ShiftService.java:448` `LocalDate.of(year, month, 1)` 에서 예외가 난다. `countTbd` 는 month 만 검사한다. tbd-count 의 year 는 범위 검사가 없다(`year=-5`, `1999` 도 200).
- 영향: 사용자 영향은 거의 없다. 500 응답만 생긴다.

### [낮음] `copyLastWeek` 를 빼면 400 이고, 오류 본문이 FE `ApiException` 모양이 아니다
- 재현: `POST $B/stores/22/schedule/template {"needs":[1,1,1]}` 또는 `POST /schedule-plans` 에 `copyLastWeek` 없이 보낸다. 응답은 `400 {"timestamp":…,"status":400,"error":"Bad Request","path":…}` 이다. 로그는 `Cannot map null into type boolean (set DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES …)` 이다. `weekMonday:"2026-02-30"`, `tbd-count?year=abc` 도 같은 기본 본문이다(`code`·`message` 없음).
- 기대: `copyLastWeek` 는 선택값(기본 false)이다. 오류 본문은 `{"code","message"}` 모양이어야 한다.
- 원인: `ShiftCommandDto.java:54`, `SchedulePlanDto.java:17` 이 primitive `boolean` 이다. Jackson 3 는 기본으로 null → primitive 를 거부한다. 파싱 오류는 `ApiException` 핸들러를 거치지 않는다.
- 영향: FE 는 항상 `copyLastWeek` 를 보내서 지금은 문제가 없다. 오류 메시지가 사용자에게 "요청 실패" 같은 일반 문구로 보일 수 있다.

## 통과한 케이스
- 직원 0명(가입 대기만 있음): month autofill 204·0건, auto-fill `{"added":0}`, plans `shifts:[]`·`unfilled:42`, template `{"copied":0}`, tbd-count 0, confirm 204
- month autofill 기본: 알바 고정 파트(s1 10건, s2 14건, s3 6건, 연소자 토 2건), 매니저 요일별 시간(8건, 휴게 60), 고정 없는 알바·정직원은 0건, 합계 40건 정확
- month autofill 두 번째 호출: 추가 0건(멱등)
- 대상 날짜는 오늘(11/17)부터. 지난 달 `2026-10` 은 204·변화 없음
- month 형식 오류 `2026-13`, `abc`, `2026-1`, `2026-11-01`, 공백, `-999-01` → 400 INVALID_MONTH
- 권한: 알바 403, 매니저 403, 다른 매장 사장님 403, 토큰 없음 401, 없는 매장 404
- 공휴일(12/25, 1/1)·주말에 주말 영업시간으로 파트를 자르고 휴게를 다시 계산한다(BE). 영업시간 밖 매니저 근무는 뺀다
- 휴무(off)·연차(leave)인 날 고정 근무 건너뜀, 수동 근무와 겹치는 고정 근무 건너뜀(BE)
- 확정된 달 month autofill → 409 ALREADY_CONFIRMED
- 퇴사자는 month autofill 대상에서 빠짐(2/27 연소자 y1 퇴사 뒤 미생성)
- `POST /schedules` 3개월 넘는 달 → 400 MONTH_TOO_FAR
- auto-fill: 월요일 아님 400 INVALID_WEEK_MONDAY, weekMonday 누락 400 VALIDATION_FAILED, 지난 주 `{"added":0}`, 알바 403, 같은 주 두 번째 호출 0건, 파트 need 만큼만 채움, 유동 근무자(매니저·정직원) 제외
- plans: to<from 400 INVALID_RANGE, 367일 400 RANGE_TOO_LONG, need 음수·null 400 INVALID_NEED, needs 누락 400, weeklyMaxMin 0 400, 지난 기간만 → 빈 미리보기, 알바 403
- plans: weeklyMaxMin 600 이 지켜짐(직원별 420·540분), excludeStaffIds 제외
- plan apply: 다른 사장님 자기 매장 경로 404, 남의 매장 403, 없는 planId 404, needs 음수 400(plan 보존), 두 번째 apply 404, 미리보기 뒤 퇴사한 직원(s4) 근무는 건너뜀, 직원별 알림 1건
- template: needs 저장, 지난주 근무 복사 규칙(지난 날짜·연차·시간 미정 제외, 같은 직원·같은 파트 중복 건너뜀, 대타 근무는 원래 근무자로 복사) → 예상과 같은 3건, 두 번째 호출 0건
- template copyLastWeek=false 는 needs 만 저장
- confirm(레거시): year<2000·month 13·month 누락 400, 시간 미정 남으면 409 TBD_REMAINING(새 confirm 도 409), 새 confirm 뒤에는 레거시 confirm 이 알림을 다시 보내지 않음
- tbd-count: month 0·13 400, year 누락·문자 400, 정상 count, 알바 403
- `/me/state` 에 autofill 결과가 반영됨(3개월 안)

## 못 한 것
- 파트 이름을 바꾸거나 지울 때 직원 `fixedParts` 에 남은 옛 이름이 어떻게 되는지 보지 않았다. 지금 코드로는 조용히 건너뛴다. 이 동작은 05 store-settings 영역이라 보지 않았다.
- 2028년 이후 공휴일 미반영은 이미 아는 한계라 테스트하지 않았다.
- `/me/changes` 신호(자동 채우기 뒤 다른 기기 반영)는 21 영역에 맡겼다.
- plan 30분 만료는 기다리지 않았다. 서버 재시작 시 plan 이 사라지는 것은 메모리 저장 설계(주석에 명시)이므로 넘어갔다.
- 웹 화면을 실제로 띄우지 않았다. FE 동작은 FE 순수 함수(`autoschedule.dart`)와 `app_store.dart` 로직을 실제 `/me/state` 로 돌려서 확인했다. 실행 파일은 `/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/0be996b6-b382-431e-9a21-1f48ed02dedf/scratchpad/a08/fe/` 에 있다.
- 남긴 데이터: 매장 22·81 과 `a08-*` 사용자. 테스트용 SQL 로 매장 22 에 지난주 근무 7건을 넣었고, 1건(1519)은 kind 를 OFF 로 바꿨다. 매장 81 의 2026-12·2027-01 에 중복 근무가 남아 있다(재현 흔적).
