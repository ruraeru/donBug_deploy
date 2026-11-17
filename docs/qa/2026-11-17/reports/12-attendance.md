# 12 attendance QA 보고서

## 요약

- 실행한 케이스: 68개
- 통과: 59개
- 발견: 8건 (치명 0 · 높음 0 · 중간 5 · 낮음 3)
- 환경: 로컬 BE `http://127.0.0.1:18080`, 2026-11-17 23:02~23:10 KST
- 데이터:
  - 매장 18 `QA12 카페`(사장님 `a12-owner`, 코드 `6E8U-988T`): 알바 `a12-staff1`(staffId 27) · `a12-staff2`(28) · `a12-staff3`(162)
  - 매장 19 `QA12 다른매장`(사장님 `a12-owner2`, 코드 `RU7L-EQYY`): `a12-staff1`(29) · `a12-staff3`(163)
  - 외부인 `a12-outsider`
- 지난 날짜 근무는 `qa-sql` 의 `INSERT INTO schedule` 로 만들었다(part 이름 `QA12-*`, schedule_id 431~437, 638, 1157, 1158).

공통 준비(아래 재현에서 그대로 쓴다):
```sh
QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
B=http://127.0.0.1:18080/api/v1
O=$($QA/qa-user a12-owner); O2=$($QA/qa-user a12-owner2); S1=$($QA/qa-user a12-staff1); S3=$($QA/qa-user a12-staff3)
c(){ t=$1; m=$2; p=$3; shift 3; curl -s -w ' [%{http_code}]\n' -X $m "$B$p" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' "$@"; }
qr(){ curl -s $B/stores/$1/qr-token -H "Authorization: Bearer $2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'; }
```

## 발견

### [중간] 근무 중인 직원을 내보내면 그 직원은 퇴근할 수 없고, 다른 매장 출근도 막힌다
- 재현:
  ```sh
  # a12-staff3 를 매장 18에 승인한다(staffId 162). 지금 시각이 포함된 근무를 만든다(shift 954, 23:10–23:58).
  c $S3 POST /stores/18/shifts/954/clock-in -d "{\"qrToken\":\"$(qr 18 $O)\"}"   # 200 working
  c $O DELETE /stores/18/staff/162                                               # 204 퇴사
  c $S3 POST /stores/18/attendance/clock-out
  # → 403 {"code":"FORBIDDEN","message":"이 매장의 재직 직원만 사용할 수 있어요"}
  c $S3 GET /me/today            # → working:true, openAttendance id 66 (떠난 매장 기록)
  # a12-staff3 는 매장 19 에도 재직 중이다(staffId 163, shift 970, 23:15–23:59).
  c $S3 POST /stores/19/shifts/970/clock-in -d "{\"qrToken\":\"$(qr 19 $O2)\"}"
  # → 409 {"code":"ALREADY_CLOCKED_IN","message":"퇴근하지 않은 근무가 있어요. 먼저 퇴근해 주세요"}
  ```
- 기대: 퇴사 처리할 때 열린 출근 기록을 닫는다(지금 시각 또는 예정 종료). 또는 퇴사를 막고 안내한다. 최소한 떠난 매장의 열린 기록이 다른 매장 출근을 막지 않아야 한다.
- 실제: 열린 기록이 그대로 남는다. 직원은 퇴근할 수 없다(403). 자동 퇴근(예정 종료 + 4시간)이 닫을 때까지 다른 매장에서 출근할 수 없다(409).
- 원인:
  - `donBug_BE/.../service/StaffService.java:153` `remove()` 는 열린 출근 기록을 확인하지 않는다.
  - `AttendanceService.java:110` `clockOut()` 은 `requireActiveStaff` 라서 LEFT 직원을 막는다.
  - `AttendanceService.java:81` `clockIn()` 의 `findOpenByUser` 와 `AttendanceRepository.java:36-38` 은 재직 상태와 매장을 거르지 않는다.
- 영향: 사장님이 근무 중에 직원을 내보내면, 그 직원은 다른 매장에서 최대 "근무 종료 + 4시간" 동안 출근할 수 없다. 떠난 매장의 근무 시간은 사장님이 근태 수정(`PATCH`)으로 닫아야 한다. 이 수정은 동작하는 것을 확인했다(attendance 66).

### [중간] 웹 근태 입력 창의 "미출근 처리"가 지난 근무에 '근무 중' 기록을 만든다
- 재현:
  ```sh
  # shift 1157 = staff1(27), 2026-11-15 09:00–18:00, 출근 기록 없음(결근).
  # 웹 근태 입력 창에서 퇴근 칸을 건드리지 않고 저장하면 FE 는 clockOut 을 빼고 보낸다.
  c $O POST /stores/18/shifts/1157/attendance -d '{"clockIn":"2026-11-15T09:00:00.000","reason":"출근 태깅 누락"}'
  # → 201 status:"working", clockOut:null, workedMinutes:3729, dayPay:745800
  c $S1 GET /me/today                    # → todayShift = 11/15 근무, working:true
  c $S1 POST /stores/18/attendance/clock-out
  # → 409 CLOCK_OUT_EXPIRED
  c $S1 POST /stores/19/shifts/1375/clock-in -d "{\"qrToken\":\"$(qr 19 $O2)\"}"
  # → 409 ALREADY_CLOCKED_IN
  ```
  최대 5분 뒤 자동 퇴근 작업이 기록을 18:00 으로 닫는다. 이때 사장님이 쓴 사유를 덮어쓴다. attendance 58 에서 확인했다: `edit_reason` 이 "퇴근 누락"에서 "퇴근 미기록 자동 처리(예정 종료 시각)"로 바뀌었고, 사장님과 직원에게 "퇴근이 자동 처리됐어요" 알림이 갔다.
- 기대: 이미 끝난 근무에 수동 기록을 만들면 퇴근도 함께 받는다. 모바일 화면(`attendance_detail_screen.dart:59-61`)이 이렇게 동작한다. 아니면 BE 가 퇴근 없는 기록을 거절한다.
- 실제: BE 는 퇴근 없는 기록을 받는다. 그 결과:
  - 직원은 지난 근무에서 '근무 중'으로 보인다.
  - 일급은 745,800원으로 부풀려 보인다.
  - 직원은 다른 출근을 할 수 없다.
  - 직원은 그 근무를 퇴근 처리할 수 없다(409).
  - 그 뒤 자동 퇴근이 기록을 닫으면서 사장님이 쓴 사유가 사라진다.
- 원인:
  - FE `donBug_FE/lib/screens/web/web_dashboard_screen.dart:694`: 새 기록이면 `outMin = null`("근무 중")로 시작한다. 그대로 저장하면 727-735줄이 clockOut 을 빼고 보낸다.
  - BE `AttendanceService.java:184-210` `createManual()`: 근무가 이미 끝났는지 보지 않고 열린 기록을 만든다.
  - `AttendanceAutoClockOut.java:65`: `editReason` 을 무조건 덮어쓴다.
- 영향: 사장님이 웹에서 결근 직원의 미출근 처리를 하면 다음 일이 생긴다.
  - 기록이 잠시 '근무 중'으로 보인다.
  - 그 직원의 다음 출근이 막힌다.
  - 수정 사유가 자동 처리 문구로 바뀐다.

### [중간] 자정을 넘는 근무에서 '자정 이후 출근'을 입력하면 하루 전 시각으로 저장되어 0원 정상 근무가 된다
- 재현 (FE 화면이 만드는 본문을 그대로 보낸다):
  ```sh
  # shift 431 = 2026-11-10 22:00–02:00(+1). 실제로는 11-11 00:10 출근, 02:20 퇴근.
  # 사장님이 출근 칸에서 00:10 을 고르면 pickTime 이 10 을 돌려준다. FE 는 근무 날짜 + 10분을 보낸다.
  c $O PATCH /stores/18/attendance/42 -d '{"clockIn":"2026-11-10T00:10:00.000","clockOut":"2026-11-10T02:20:00.000","reason":"자정 넘어 출근"}'
  # → 200 status:"normal", lateMinutes:0, workedMinutes:0, dayPay:0
  # 올바른 값(11-11 00:10~02:20)을 보내면 status:"late", lateMinutes:130, workedMinutes:130, dayPay:26000
  ```
- 기대: 근무 시작보다 이른 자정 이후 시각은 다음 날로 본다. 아니면 BE 가 근무 시간대와 동떨어진 시각을 거절한다.
- 실제: 24시간 이른 시각으로 저장된다. 지각 130분은 '정상'으로 바뀌고 일급은 0원이 된다.
- 원인:
  - FE `screens/employer/attendance_detail_screen.dart:54-56`: 퇴근만 +1440 으로 보정하고, 출근 `day.add(_in)` 은 보정하지 않는다.
  - FE `screens/web/web_dashboard_screen.dart:726`: 같은 문제다.
  - `employer_parts.dart:269` `pickTime` 은 0~1439 만 돌려준다.
  - BE `AttendanceService.java:168-171` 은 시각이 근무 날짜 근처인지 검증하지 않는다(아래 발견 참고).
- 영향: 야간 근무(22:00–02:00 같은)에 늦게 온 직원의 근태를 고치면 그날 급여가 0원이 되고, 지각 기록도 사라진다.

### [중간] 근태 시각이 근무 날짜와 무관해도 저장된다 (미래 근무 기록, 엉뚱한 날짜, 서기 1년)
- 재현:
  ```sh
  # shift 435 = staff2, 2026-11-14 09:00–18:00(휴게 30)
  c $O POST /stores/18/shifts/435/attendance -d '{"clockIn":"2026-11-16T09:00:00","clockOut":"2026-11-17T08:00:00","reason":"날짜 다름"}'
  # → 201 lateMinutes:2880, overtimeMinutes:3720, workedMinutes:1350, dayPay:270000
  # shift 436 = staff1, 2026-11-25(미래) 09:00–18:00
  c $O POST /stores/18/shifts/436/attendance -d '{"clockIn":"2026-11-17T09:00:00","clockOut":"2026-11-17T18:00:00","reason":"미래 근무"}'
  # → 201 status:"normal". 이후 GET /attendance?date=2026-11-25 가 아직 오지 않은 근무를 "normal" 로 보여 준다.
  # → 출근 기록이 생겨 이 근무는 수정·삭제할 수 없다(ShiftService.java:149,219 ATTENDANCE_EXISTS).
  c $O PATCH /stores/18/attendance/43 -d '{"clockIn":"0001-01-01T09:00:00","clockOut":"0001-01-01T10:00:00","reason":"x"}'
  # → 200 저장된다.
  ```
- 기대: 출근 시각은 근무 시작 전후 일정 범위(예: 시작 −30분 ~ 종료) 안에 있어야 한다. 퇴근은 출근 뒤 24시간 안이어야 한다. 근무 날짜가 미래인 근무에는 기록을 만들 수 없어야 한다.
- 실제: 미래 시각과 24시간 초과만 막는다. 근무 날짜와의 관계는 보지 않는다.
- 원인: `AttendanceService.java:251-265` `requireOrder`·`requireNotFuture` 뿐이다. `createManual`(184-210)·`edit`(162-181)에 근무 시간대 검증이 없다.
- 영향: 사장님이 입력을 잘못하면 하루 일급이 수십만 원으로 부풀거나 0원이 된다. 그 값은 급여·인건비에 그대로 들어간다. 미래 근무는 잠겨서 지울 수 없다.

### [중간] 아주 긴 수정 사유를 보내면 500
- 재현:
  ```sh
  L=$(python3 -c 'print("가"*30000)')   # 90,000 바이트
  c $O PATCH /stores/18/attendance/43 -d "{\"reason\":\"$L\"}"
  # → 500 {"status":500,"error":"Internal Server Error"}
  ```
  BE 로그: `Data truncation: Data too long for column 'body'` (insert into notification). 1,001자 사유는 200 이다.
- 기대: 사유 길이를 제한하고 400 VALIDATION_FAILED 를 돌려준다.
- 실제: 500 이다. 응답 본문이 FE `ApiException` 모양(`code`·`message`)이 아니라서 FE 는 "요청을 처리하지 못했어요"만 보여 준다.
- 원인:
  - `dto/AttendanceViewDto.java:69` `reason` 에 `@Size` 가 없다.
  - `AttendanceService.java:178` 은 사유 전체를 알림 `body`(TEXT, 65,535 바이트)에 넣는다.
  - 수동 생성(`createManual`)은 알림을 만들지 않지만, `edit_reason` 도 TEXT 라서 같은 한계에 걸린다.
- 영향: 실사용에서 일어날 가능성은 낮다. 오류 처리 누락이다.

### [낮음] `Z` 가 붙은 시각을 KST 로 그대로 저장한다 (9시간 어긋남)
- 재현:
  ```sh
  c $O PATCH /stores/18/attendance/2 -d '{"clockIn":"2026-11-17T13:45:00Z","reason":"x"}'
  # → 200 clockIn:"2026-11-17T13:45:00" (UTC 13:45 = KST 22:45 이어야 함)
  c $O PATCH /stores/18/attendance/2 -d '{"clockIn":"2026-11-17T22:45:00+09:00","reason":"x"}'
  # → 400 (기본 Spring 오류 본문)
  ```
- 기대: 오프셋이 붙은 시각은 KST 로 바꿔 저장하거나, 일관되게 400 을 돌려준다.
- 실제: `Z` 는 조용히 버려진다. `+09:00` 은 400 이다.
- 원인: `EditRequest.clockIn/clockOut` 이 `LocalDateTime` 이다(`AttendanceViewDto.java:67-68`). Jackson 이 끝의 `Z` 를 무시한다.
- 영향: 지금 FE 는 로컬 `DateTime.toIso8601String()`(Z 없음)을 보내서 문제가 없다. 다른 클라이언트나 FE 가 UTC 를 보내면 9시간 틀어진다.

### [낮음] `GET /me/today` 응답 키가 설계와 다르고, `openAttendance` 에 퇴근한 기록도 들어간다
- 재현:
  ```sh
  S2=$($QA/qa-user a12-staff2)
  c $S2 GET /me/today   # (퇴근 완료 뒤)
  # → {"todayShift":{...},"working":false,"openAttendance":{"id":"2",...,"clockOut":"2026-11-17T23:03:04.03627",...}}
  ```
- 기대: 설계서 §4.6 은 `myTodayShift`, `isWorking`, `myOpenAttendance` 의미를 쓴다. `openAttendance` 라는 이름이면 clockOut 이 null 인 기록만 담아야 한다.
- 실제: 키 이름이 `working` 이다. 퇴근한 기록도 `openAttendance` 로 온다.
- 원인: `dto/MeDto.java:17-20`, `AttendanceService.java:236-237`(오늘 근무가 이미 끝났으면 그 근태를 넣는다).
- 영향: FE 는 지금 `/me/today` 를 부르지 않아서(`app_store.dart` 에 호출 없음) 화면 영향은 없다. 다른 클라이언트가 이 응답을 쓰면 오해할 수 있다.

### [낮음] 같은 퇴근 요청을 동시에 보내면 여러 건이 200 이다
- 재현: 매장 19 shift 22 출근 뒤 `POST /stores/19/attendance/clock-out` 을 10건 동시에 보냈다.
  - 결과: 200 6건, 404 4건.
  - DB: 기록 1행, 마지막 쓰기의 시각이 남았다.
- 기대: 첫 요청만 200, 나머지는 404.
- 실제: 낙관적 잠금이 없어서 여러 트랜잭션이 같은 열린 기록을 읽고 각각 덮어쓴다(`Attendance` 에 `@Version` 없음, `AttendanceService.java:111-118`).
- 영향: 행이 늘거나 데이터가 깨지지는 않는다. 퇴근 시각이 수 밀리초 바뀌는 정도다. 24번 영역과 겹친다.

## 통과한 케이스

- 출근 기록 없이 퇴근: 404 "퇴근할 출근 기록이 없어요"
- 두 번 퇴근: 두 번째는 404
- 퇴근 뒤 같은 근무 재출근: 409 ALREADY_CLOCKED_OUT
- 사장님·외부인의 퇴근: 403. 없는 매장: 404. 인증 없음: 401.
- 매장 18에서 출근한 직원이 매장 19 경로로 퇴근: 404, 기록 안 바뀜
- 퇴근 가능 시간(종료+4h) 지난 퇴근: 409 CLOCK_OUT_EXPIRED
- 열린 기록이 둘일 때 퇴근은 최근 출근 기록을 닫는다
- 지각 계산:
  - 22:30 시작, 23:02 출근: late 32
  - 22:45 시작 근무를 22:45 로 수정: late 0, normal
- 일찍 출근(08:30, 소정 09:00) + 이른 퇴근(17:30), 휴게 60: worked 450, dayPay 90,000(시급 12,000), normal
- 자정 넘김 22:00–02:00 근무, 22:05~02:20: late 5, worked 255, overtime 20, dayPay 51,000
- 조퇴(종료 전 퇴근) 자정 넘김 근무 22:30–02:00, 23:09 퇴근: worked 39, overtime 0, normal. 조퇴 상태는 FE·BE 모두 없다(설계 일치).
- 연장: 18:00–21:00 근무, 23:05 퇴근 → overtime 125
- PATCH 검증:
  - 사유 없음·공백·빈 본문 → 400 VALIDATION_FAILED
  - 퇴근<출근, 퇴근=출근, 출근만 보내서 기존 퇴근보다 늦어짐 → 400 INVALID_CLOCK_RANGE
  - 24시간 초과 → 400
  - 미래 시각 → 400 FUTURE_TIME
- PATCH 형식 오류(본문 없음, 깨진 JSON, `2026-11-17 22:45`, 숫자, 25:00): 400. Spring 기본 본문이고, FE 는 기본 문구를 보여 준다.
- PATCH 권한: 알바생·다른 매장 사장님 → 403. 다른 매장 경로로 남의 기록 → 404.
- PATCH FE 형식(밀리초 `.000`)과 한글·이모지 사유: 200
- PATCH 로 열린 기록의 출근만 수정: 퇴근 null 유지, working
- PATCH 에 `clockIn:null, clockOut:null`: 기존 값 유지, 사유만 바뀜
- PATCH 알림: 직원에게 PAY "근태 기록이 수정됐어요", body=사유, ref_id=근태 id
- 퇴사 직원 기록을 사장님이 PATCH 로 닫기: 200
- 수동 생성:
  - 정상 201(MANUAL, editReason 저장, 알림 없음)
  - 같은 근무 두 번 → 409 ATTENDANCE_EXISTS
  - 휴무(OFF)·시간 미정 → 409 NOT_WORK_SHIFT
  - clockIn 없음 → 400 CLOCK_IN_REQUIRED
  - 사유 없음 → 400
  - 알바생 → 403
  - 다른 매장 사장님 → 403
  - 다른 매장 경로 + 남의 shiftId → 404
  - 없는 근무 → 404
- GET 상세: 본인 200. 다른 알바생·다른 매장 사장님 403. 다른 매장 경로 404. 없는 id 404. 문자 id 400.
- GET 목록:
  - 알바생·다른 매장 사장님 → 403
  - date 없음·2월 30일·`20261117` → 400
  - 근무 없는 날 → 빈 목록
  - 상태 absent(지난 근무 기록 없음)·waiting(미래)·working·late·normal 판정이 설계와 맞음
  - 퇴사자 근무도 포함됨
- `/me/today`:
  - 출근 전에는 오늘 근무, 근무 중에는 열린 기록
  - 사장님·외부인은 빈 응답
  - 여러 매장 소속이면 매장 19 근무도 찾음
- 자동 퇴근: 종료+4h 지난 열린 기록을 예정 종료(18:00)로 닫음. 사장님(SUB)·직원(PAY)에게 알림.
- `/me/state` 의 attendance: 사장님은 매장 전체, 알바생은 자기 기록만. id·storeId·shiftId·staffId 가 문자열이고, 모든 attendance 의 shiftId 가 state.shifts 에 있음. FE `DateTime.parse` 가 읽는 마이크로초 형식.

## 못 한 것

- 실제 자정 이후 시점의 동작(예: 23:30 시작 근무에 00:05 출근):
  - 확인하려면 자정까지 기다려야 해서 하지 않았다.
  - 코드상 BE `/me/today`(`AttendanceService.java:223-228`)와 FE `myTodayShift`(`app_store.dart:378-381`)는 근무 날짜가 오늘인 것만 본다. 그래서 자정이 지나면 전날 시작한 미출근 야간 근무가 홈 화면에서 사라질 수 있다. 실제 요청으로 재현하지 않아서 발견으로 올리지 않았다.
- 결근(absent) 근무의 급여 반영과 인건비 합계: 18 payroll 영역이다.
- 출근(clock-in) QR 검증 자체: 11번 영역이다.
- 근태 변경이 `/me/changes` 신호를 내는지: 21번 영역이다.
