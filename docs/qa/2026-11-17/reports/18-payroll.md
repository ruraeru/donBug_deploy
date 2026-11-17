# 18 payroll QA 보고서

## 요약

- 실행한 케이스: 52개 (계산 검증 21, 권한·입력 검증 31)
- 통과: 46개
- 발견: 6건 (치명 0, 높음 0, 중간 4, 낮음 2)

먼저 알아 둘 점: FE 는 BE 급여 API(`/payslips`, `/labor-cost`, `/labor-cost/trend`)를 부르지 않는다. `donBug_FE/lib` 에서 `payslips`·`labor-cost` 를 검색하면 결과가 0건이다. 앱과 웹의 급여 화면은 모두 `/me/state` 데이터로 `AppStore.payslip()`(`app_store.dart:543`)이 직접 계산한다. 그래서 아래의 BE 계산 오류는 지금 사용자 화면에는 나오지 않는다. 대신 API 를 쓰는 쪽(나중의 FE, 정산 확정, 외부 연동)이 FE 화면과 다른 금액을 받는다. 4번 발견은 FE 화면에도 영향이 있다.

테스트 데이터:
- 매장 A `35`: 사장님 `a18-owner`, `isSmall:false`(5인 이상 고정)
  - 직원 73 `a18-staff1`: 시급 12000, 가산 적용, 공제 없음
  - 직원 74 `a18-staff2`: 3.3%
  - 직원 75 `a18-staff3`: 4대보험, 주휴 끔
- 매장 B `79`: 사장님 `a18-owner2`, 규모 AUTO, 직원 154·156·158·159·160
- 기준 시각: 2026-11-17(화) 23시 KST. 과거 근무는 `POST /shifts`(과거 날짜 허용)로 만들었다. 출퇴근은 `POST /shifts/{id}/attendance`(수동 근태)로 만들었다.

공통 준비(아래 재현에서 `$B`, `$O` 사용):
```sh
QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
B=http://127.0.0.1:18080/api/v1; O=$($QA/qa-user a18-owner)
# 근무 생성: sh <store> <date> <startMin> <endMin> <break> <staffId>
# 근태 생성: POST $B/stores/<store>/shifts/<id>/attendance {"clockIn":..,"clockOut":..,"reason":"qa"}
```

## 발견

### [중간] BE 급여명세가 시급 이력을 무시하고 과거 달에도 지금 시급을 적용한다
- 재현:
  1. 직원 73(시급 12000)의 10월 근무·출근 기록을 만든다(위 데이터). `GET $B/stores/35/staff/73/payslips/2026-10` 의 결과는 `base 836000, weeklyHoliday 157600, premium 102000, gross 1095600` 이다.
  2. `PATCH $B/stores/35/staff/73 {"wage":13000}` 을 보낸다. 응답의 `wages` 는 `[{from:2000-01-01, wage:12000},{from:2026-11-17, wage:13000}]` 이다.
  3. 1번 요청을 다시 보낸다.
- 기대: 10월은 12000원이 적용된 기간이라 금액이 그대로여야 한다. FE `wageOn(day)`(`models.dart:488`)는 날짜별 이력으로 계산한다.
- 실제: `base 905667, weeklyHoliday 170733, premium 110500, gross 1186900` 이 나온다. 이미 끝난 10월 급여가 91,300원 늘었다. 같은 이유로 `/labor-cost?year=2026&month=10` 과 `/labor-cost/trend` 의 10월 값도 1,714,900원이 됐다.
- 원인: `PayrollCalculator.java:61` 의 `int wage = sw.getHourlyWage();` 가 현재 시급 하나만 쓴다. 이력(`StaffWageService`, `staff_wage` 테이블)은 있지만 계산에 쓰지 않는다. 주휴 금액은 일요일 시급, 기본급·가산은 근무일 시급을 써야 FE 와 같아진다.
- 영향: 시급을 바꾸면 지난 달 명세와 인건비 추이가 모두 소급해서 바뀐다. FE 화면(12000 기준)과 BE API(13000 기준) 금액이 다르다.

### [중간] 주휴수당 규칙이 FE 와 다르다 (결근, 소정시간, 안 끝난 주, 퇴사자)
FE(`app_store.dart:554-607`, `payroll.dart:142-158`)는 주휴수당을 아래 조건이 모두 맞을 때만 준다.
- 소정시간(계약서 주 소정시간, 없으면 그 주 예정 근무+연차) ≥ 15h
- 개근(끝난 근무에 출근 기록이 모두 있음)
- 계속근로(`leftAt` 이 그 주 일요일 이상)
- 확정 급여(`projected=false`)는 주가 끝났을 때만

BE(`PayrollCalculator.java:123-144`)는 실제 일한 분(대타 제외)이 900분 이상이면 위 조건 없이 준다. 아래 세 가지를 실제로 재현했다.

1. 결근이 있는 주에도 주휴를 준다.
   - 재현: 직원 73에게 10/12(출근만, 퇴근 없음), 10/13(출근 기록 없음 = 결근), 10/14~10/17(10~14시, 출퇴근)을 만든다. 그다음 `GET $B/stores/35/staff/73/payslips/2026-10` 을 보낸다.
   - 실제: 10/12~18 주에 실근무 960분이 잡히고 주휴 38,400원(시급 12000 기준)이 들어갔다. 10월 주휴 합계는 157,600원이다.
   - FE: 10/13 결근이라 그 주는 0원이다. 10/5 주도 실근무 1780분이 아니라 소정 1740분으로 계산한다. 그래서 FE 10월 주휴는 48,000 + 69,600 = 117,600원이다. 차이는 40,000원이다.
2. 아직 안 끝난 주에도 확정 급여에 주휴가 들어간다.
   - 재현: 11/16(월) 10-14시, 15-23시, 11/17(화) 8-13시의 출퇴근을 만든다(실근무 1020분). 그다음 `GET .../staff/73/payslips/2026-11?projected=false` 를 보낸다.
   - 실제: 11/16~22 주(일요일은 11/22, 아직 오지 않음)에 주휴 44,200원이 포함됐다. `weeklyHoliday 197600`.
   - FE: `over=false` 라 0원이다(`app_store.dart:604`).
3. 퇴사한 직원에게 퇴사 뒤 끝나는 주의 주휴를 준다.
   - 재현: 직원 74에게 11/16 8-16시, 11/17 6-14시 출퇴근을 만든다. 그다음 `DELETE $B/stores/35/staff/74` 를 보낸다(status LEFT, 11/17 퇴사). 이어서 `GET .../staff/74/payslips/2026-11` 를 보낸다.
   - 실제: `weeklyHoliday 38400` 이고, `/labor-cost?year=2026&month=11` 의 74번 값은 230,400원이다.
   - FE: `stays=false` 라 0원이다(`app_store.dart:603`).
- 원인: `PayrollCalculator.weeklyHoliday`(`:123-144`)가 개근·계약 소정시간·퇴사일·주 종료 여부를 보지 않는다. `Item` 에 결근 근무(출근 기록 없음)가 아예 들어가지 않아(`:85-96`) 결근을 판단할 정보도 없다.
- 영향: 같은 직원·같은 달인데 BE API 와 앱 화면의 급여가 다르다. BE 값을 기준으로 정산하면 결근한 주와 퇴사 뒤의 주휴를 과다 지급한다.

### [중간] BE 에 주 40시간 초과 연장 가산이 없다 (FE 는 계산함)
- 재현: 5인 이상 매장에서 가산을 켠 직원 73에게 11/2(월)~11/7(토) 매일 09-18시(휴게 60분, 실근무 480분)를 만들고 출퇴근을 기록한다. 주 합계는 2880분이다. 그다음 `GET $B/stores/35/staff/73/payslips/2026-11` 을 보낸다.
- 기대: FE `computePayslip`(`payroll.dart:171-187`)는 주 40h 초과분(2880 − 2400 − 일별 8h 초과 0 = 480분)에 0.5배를 더한다. 시급 12000 기준으로 48,000원이다.
- 실제: 이 주 가산수당은 0원이다. 11월 `premium` 은 다른 날의 야간·일 8h 초과분 32,500원뿐이다.
- 원인: `PayrollCalculator.premium`(`:147-161`)은 야간과 하루 480분 초과만 계산한다. 주 단위 연장 계산이 없다. 클래스 주석 6번(`:36`)도 FE 규칙과 다르다.
- 영향: 하루 8시간 이하로 주 6일 일하는 직원의 연장수당이 BE 에서 빠진다. FE 와 금액이 다르다.

### [중간] 지금 재직 인원이 바뀌면 지난 달 가산수당이 소급해서 바뀐다 (BE·FE 공통)
- 재현:
  1. `a18-owner2` 로 매장을 만든다(`isSmall` 생략, AUTO). 직원 5명을 가입시키고 승인한다. 매장 `isSmall:false` 가 된다.
  2. 직원 154에게 `{"premium":true}` 를 주고, 10/14 22:00~10/15 06:00(휴게 60) 근무와 출퇴근을 만든다.
  3. `GET $B/stores/79/staff/154/payslips/2026-10` 을 보낸다. `premium 42000, gross 126000` 이다.
  4. `DELETE $B/stores/79/staff/160` 으로 오늘 1명을 퇴사시킨다. 재직 인원은 4명이 된다.
  5. 3번 요청을 다시 보낸다.
- 기대: 10월은 5인 이상이던 달이라 10월 가산은 그대로 42,000원이어야 한다.
- 실제: `premium 0, gross 84000` 이 나온다. `/labor-cost` 10월 값도 84,000원으로 바뀌었다.
- 원인: BE `PayrollCalculator.java:148` `store.isUnderFive()` 는 지금 값이다. 승인·퇴사 때 `StoreService.syncSize`(`StoreService.java:169`, `StaffService.java:97,161`)가 갱신한다. FE 도 `app_store.dart:616` `!st.isSmall` 로 지금 값을 쓴다. 월별 규모 기록이 없다. FE CLAUDE.md 에는 노무 체크리스트의 근사로만 적혀 있고, 급여 소급은 알려진 한계 목록에 없다.
- 영향: 인원이 5명 경계를 넘나들 때마다 앱과 웹의 지난 달 급여 명세·인건비가 바뀐다. 이미 지급한 금액과 화면이 달라진다.

### [낮음] 저장된 정산(Payroll)이 있는 달은 세 API 가 서로 다른 인건비를 낸다
- 재현(자기 데이터에 SQL 로 행 하나를 넣고 확인 뒤 지웠다):
  1. `qa-sql "insert into payroll (mapping_id,payroll_month,total_work_time,gross_pay,deduction_amount,final_salary) values (74,'2026-09',0,0,3300,100000)"` 를 실행한다.
  2. `GET $B/stores/35/labor-cost?year=2026&month=9` 를 보낸다.
  3. `GET $B/stores/35/labor-cost/trend?months=3` 와 `GET $B/stores/35` 를 보낸다.
- 실제:
  - `/labor-cost` 는 `total 103300` 이다. 74번 하나만 나오고 저장 행이 없는 73번의 9월 근무 156,000원이 빠졌다.
  - `/trend` 의 2026-09 와 `monthlyTotals` 의 `2026-09` 는 0이다. `projected=true` 로 다시 계산하면 156,000원이다.
- 원인:
  - `PayrollService.java:58-65`: 행이 하나라도 있으면 저장 행만 쓴다. 저장 행이 없는 직원은 뺀다.
  - `storedGross`(`:106`)는 `gross_pay` 가 0이면 `final+deduction` 으로 대신 계산한다.
  - `PayrollRepository.sumGrossByMonthBefore` 와 `StoreService.java:392` 는 `sum(grossPay)` 만 쓴다.
- 영향: 지금은 `payroll` 테이블에 쓰는 코드가 하나도 없어 실제로는 드러나지 않는다. "정산 확정"을 만들 때 같은 달 인건비가 화면마다 다르게 나올 수 있다.

### [낮음] 잘못된 month·쿼리 값의 오류 응답에 `code` 가 없다 (Spring 기본 본문)
- 재현: `GET $B/stores/35/staff/73/payslips/2026-13`(`2026-1`, `abc`, `2026-10-01` 도 같음), `.../staff/abc/payslips/2026-10`, `/labor-cost?year=2026`(month 없음), `/labor-cost?year=2026&month=x`, `/labor-cost/trend?months=x`
- 실제: 400 `{"timestamp":..,"status":400,"error":"Bad Request","path":..}` 이 온다. `code`·`message` 가 없다. 같은 API 의 `month=13` 은 400 `INVALID_MONTH` 를 잘 준다. 반대로 `year=-5` 는 200 에 0원을 준다.
- 원인: `ApiExceptionHandler` 에 `MethodArgumentTypeMismatchException`·`MissingServletRequestParameterException` 처리가 없다. `laborCost` 는 연도 범위를 검사하지 않는다(`PayrollService.java:50-55`).
- 영향: FE `ApiClient`(`api_client.dart:174`)는 `code` 가 없으면 상태 코드와 기본 문구로 대신 보여 주므로 화면이 깨지지는 않는다. 오류 형식이 엔드포인트마다 다르다.

## 통과한 케이스
- 10월 명세(직원 73, 시급 12000)가 BE 규칙대로 손으로 계산한 값과 원 단위까지 맞음: minutes 4180, base 836000, 주휴 157600, 가산 102000, missingClockOut 1
- 지각 출근(10:20)은 10:20부터 셈(220분)
- 일찍 출근(09:30)은 소정 시작 10:00부터 셈(240분)
- 늦은 퇴근(15:00)은 실제 퇴근까지 셈(300분)
- 출근만 있고 퇴근 없는 지난 근무는 0원으로 빠지고 `missingClockOut` 1로 셈
- 출근 기록 없는 근무는 0원
- 야간 22-06(휴게 60)은 실근무 420분, 야간 분 420분으로 잘림. 가산 42,000원
- 휴게 없는 야간 480분은 가산 48,000원
- 하루 600분 근무는 480분 초과 120분에 0.5배(12,000원)
- 자정 넘는 10/31 22:00~11/1 06:00 근무는 근무일 기준으로 10월에 들어감
- 월 경계 주: 9/28~10/4 주의 9월 근무분은 9월 기본급(trend 9월 156,000원), 주휴 48,000원은 일요일(10/4)이 있는 10월에 들어감
- 10/26~11/1 주의 주휴 49,400원은 11월에 들어감(10월에는 없음)
- 연차(10/20)는 소정 240분 유급, 가산 대상 아님. 앞으로의 연차(11/20)는 `projected=true` 일 때만 들어가고 `planned:true`
- 예정 근무(11/18·19)는 `projected=true` 일 때만 들어감. 11월 예상 gross 1,353,300원이 손계산과 맞음
- 대타 근무(`is_substitute=1`)는 주휴 계산 분에서 빠짐(1020분 → 780분이 되어 주휴 0)
- 3.3% 공제: gross 288000 → 9504, 4대보험 9.4%: gross 240000 → 22560
- 주휴 끈 직원은 주휴 0
- FE `(gross*0.033).floor()`·`(gross*0.094).floor()` 와 BE 정수 계산이 0~3,000,000원 전 구간에서 같음(파이썬 double 로 확인)
- 5인 미만(AUTO 4명)이면 가산 0
- AUTO 매장에서 5명 승인하면 `is_under_5` 가 0으로 동기화됨
- `/labor-cost` 10월(지난 달, 저장 행 없음)은 직원 합계 1,714,900원
- `/labor-cost` 11월(projected false/true)과 12월(0원)
- `/labor-cost` byStaff 에 퇴사(LEFT) 직원은 포함, 대기(PENDING) 직원은 빠짐
- `/labor-cost/trend?months=3` 는 지난 달부터 거슬러 3개월(8·9·10월)
- 권한: 본인 명세 200
- 권한: 같은 매장 다른 알바생 403 `FORBIDDEN`
- 권한: 무소속 사용자 403
- 권한: 인증 없음 401
- 권한: 퇴사자 본인 명세 200
- 권한: 알바생·무소속의 `/labor-cost`·`/trend` 403
- 권한: 다른 매장 사장님이 남의 매장 경로로 요청하면 403
- 권한: 내 매장 경로에 남의 매장 직원 id 를 넣으면 404
- 없는 staff·store id 는 404 `NOT_FOUND`
- `/labor-cost` month=0·13 은 400 `INVALID_MONTH`
- `/labor-cost` year=1e9 는 400 `INVALID_MONTH`
- `/trend` months=0·25 는 400 `INVALID_MONTHS`
- month `0001-01`·`9999-12` 는 200, 0원(500 없음)
- `projected=yes` 는 true 로 해석

## 못 한 것
- FE `computePayslip` 실제 실행: `donBug_FE/flutter` SDK 가 이 환경에 없다(`flutter/bin/dart` 없음). FE 금액은 `app_store.dart:543-620`·`payroll.dart` 코드를 읽고 손으로 계산했다. 소스를 바꾸지 말라는 규칙 때문에 FE 테스트 파일도 추가하지 않았다.
- 휴일근로 가산: FE·BE 모두 문서에 "휴일가산 없음"으로 정한 근사라 버그로 보고하지 않았다(근로기준법상 5인 이상 휴일근로는 1.5배).
- 대타 승인 flow 로 만든 대타 근무: 시간을 줄이려고 SQL 로 `is_substitute` 만 바꿔 확인한 뒤 되돌렸다. 대타 수명은 13번 영역에서 다룬다.
- `/labor-cost` 9월 첫 요청 하나가 500 이었다. BE 로그를 보면 `HikariPool-1 - Connection is not available ... (total=10, active=10, idle=0, waiting=33)` 이다. 다른 에이전트의 동시 부하(롱 폴링 등)로 커넥션 풀이 고갈된 것으로 보인다. 바로 다시 보낸 요청은 정상(5ms)이었다. 급여 코드 문제가 아니라서 발견에 넣지 않았다. 21·24번 영역에서 확인할 일이다.
- 매장 B 의 직원 160 은 소급 테스트 때문에 퇴사 처리했다. 매장 A 의 직원 74 도 퇴사 처리했다.
