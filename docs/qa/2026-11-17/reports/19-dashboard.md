# 19 dashboard QA 보고서

## 요약

- 실행한 케이스: 46개, 통과: 41개
- 발견: 치명 0 · 높음 0 · 중간 0 · 낮음 5 (+ 자정 경계 1건은 아래 "자정" 항목 참고)
- 테스트 시각: 2026-11-17(화) 23:03 ~ 2026-11-18 00:0x KST. 오늘 23시대라 "끝난 근무 / 진행 중 / 대기 / 야간 근무" 를 실제 시각으로 확인할 수 있었다.
- 사용한 데이터: 사장님 `a19-owner`(user 237), 매장 36 `QA19 대시보드점`(코드 `Q3PD-2TZE`), 매장 37 `QA19 빈매장`(코드 `XNWX-ESPM`), 직원 `a19-staff1..6`(매장 36 staff 76~80, 매장 37 staff 169), 남의 사장님 `a19-other`.

### 먼저 알아둘 점 (범위 판단)

- FE 는 `GET /stores/{id}/dashboard` 를 **부르지 않는다**(`donBug_FE/lib` 전체에서 `dashboard` 경로 호출 없음). 앱 `employer_dashboard_screen.dart` 와 웹 `web_dashboard_screen.dart`·`web_today_strip.dart` 는 모두 `/me/state` 의 `shifts`·`attendance`·`subs`·`staff`·`persons`·`notifications`·`schedules` 로 즉석 계산한다. 그래서 두 가지를 같이 봤다.
  1. BE `/dashboard` 엔드포인트 자체(설계서 §4.11 `[제안]`)의 정확성·권한·입력 검증
  2. FE 대시보드가 쓰는 `/me/state` 값이 DB 와 맞는지, FE 계산 규칙을 그대로 적용했을 때 BE `/dashboard` 와 같은 답이 나오는지
- `/dashboard` 는 현재 소비자가 없으므로 그 엔드포인트만의 불일치는 `낮음` 으로 매겼다(FE 가 이 API 로 옮겨 가면 `중간` 이 된다).

## 발견

### [낮음] 웹 대시보드 "보건증 만료 임박" KPI 문구가 "· 일 전 알림" 으로 깨짐 (보건증 미등록 직원이 있으면 항상)

- 재현:
  ```sh
  B=http://127.0.0.1:18080/api/v1
  O=$(qa-user a19-owner); S6=$(qa-user a19-staff6 직원6)
  curl -s -XPOST $B/stores/join-requests -H "Authorization: Bearer $S6" -H 'Content-Type: application/json' -d '{"code":"XNWX-ESPM"}'
  curl -s -XPOST $B/stores/37/staff/169/approve -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"wage":11000}'
  curl -s "$B/me/state?storeId=37" -H "Authorization: Bearer $O"   # persons[직원6].certExpiry=null, certAlertDays=[]
  ```
  위 state 에 FE 규칙(`web_dashboard_screen.dart:20-24` `certAlerts`, `:93-99` KPI)을 적용하면 KPI 는 값 `미등록`, 캡션 `직원6님 · 일 전 알림`.
  알림 시점을 `0` 만 고른 직원(`PUT /me/health-cert -F alertDays=0`, 직원3 으로 재현: `certAlertDays:[0]`)이 가장 급한 경우에도 `d > 0` 필터로 빈 문자열이 되어 똑같이 깨진다.
- 기대: 미등록이면 "보건증 미등록" 같은 문구, 알림일이 없으면 "· …일 전 알림" 부분을 빼기.
- 실제: `직원6님 · 일 전 알림` (새로 승인된 직원은 보건증이 없으므로 매장 대부분이 처음에 이 상태).
- 원인: `donBug_FE/lib/screens/web/web_dashboard_screen.dart:99` 가 `certAlertDays.where((d) => d > 0).join('·')` 가 빈 문자열인 경우(미등록 → `[]`, 또는 `[0]`)를 처리하지 않는다. 미등록(`null`)은 `:22` 에서 `-1` 로 취급되어 정렬상 항상 맨 앞(`:24`, `-9999`)에 오므로 미등록자가 한 명이라도 있으면 늘 이 문구가 나온다.
- 영향: 사장님 웹 대시보드 첫 줄 KPI 문구가 어색하게 보임. 데이터 오류는 없음.

### [낮음] `/dashboard` 의 `certAlerts` 판정 기준이 FE 대시보드와 다름 (개인 알림일 최댓값 vs 고정 30일)

- 재현 (직원 보건증은 실제 API `PUT /me/health-cert` 로 등록):
  ```sh
  # 직원1: 만료 2026-12-17(D-30), alertDays=7 / 직원2: 2026-12-01(D-14), alertDays=7
  # 직원3: 2026-11-20(D-3), alertDays=0 / 직원4(SQL): 2026-12-18(D-31), alertDays=60
  curl -s -XPUT $B/me/health-cert -H "Authorization: Bearer $(qa-user a19-staff3)" -F expiry=2026-11-20 -F alertDays=0 -F photo=@p.png
  curl -s $B/stores/36/dashboard -H "Authorization: Bearer $(qa-user a19-owner)"
  ```
  (직원3 퇴사 처리 전 시점 기준)
- 기대: FE 웹 대시보드 `certAlerts`(`web_dashboard_screen.dart:20-24`)·앱 `_nearestCert`(`employer_dashboard_screen.dart:180-189`)와 같은 기준 = 만료 30일 이내 또는 미등록.
- 실제: BE `certAlerts` = `[{"staffId":"79","daysLeft":31}]` 만. FE 규칙으로는 직원3(D-3)·직원2(D-14)·직원1(D-30) 3명이고 직원4(D-31)는 아니다. 즉 **D-3 로 곧 만료되는 직원이 BE 에서는 빠지고**, D-31 인 직원이 들어간다. 정렬도 BE 는 직원 id 순(예: `date=2026-12-18` 에서 `76:-1, 77:-17, 79:0`), FE 는 급한 순.
- 원인: `donBug_BE/.../service/DashboardService.java:89-95` 가 임계값을 `max(certAlertDays)`(없으면 30)로 잡는다. 알림일을 `[0]` 이나 `[7]` 로 고른 직원은 만료 3일 전·29일 전에도 경고 대상이 아니다. 정렬 없음(`:84` 반복 순서 그대로).
- 영향: 지금은 FE 가 이 API 를 안 써서 화면 영향 없음. FE 가 집계 API 로 옮기면 곧 만료되는 보건증이 대시보드에서 사라진다.

### [낮음] `/dashboard` 의 `unsignedContracts` 가 숫자 배열 (다른 id 는 전부 문자열)

- 재현:
  ```sh
  O=$(qa-user a19-owner)
  C='{"start":"2026-11-01","end":"2027-04-30","wage":12000,"weeklyHours":20,"workDays":"월,수,금","duty":"홀"}'
  curl -s -XPUT $B/stores/36/staff/76/contract -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d "$C"
  curl -s $B/stores/36/dashboard -H "Authorization: Bearer $O" | grep -o '"unsignedContracts":[^]]*]\|"certAlerts":[^]]*]'
  ```
- 기대: FE 계약(모든 id 문자열) 대로 `"unsignedContracts":["76"]`.
- 실제: `"unsignedContracts":[76,77]` — 같은 응답의 `certAlerts[].staffId` 는 `"79"` 문자열.
- 원인: `donBug_BE/.../config/FeIdJsonModule.java` 의 `isIdName` 은 이름이 `id`·`*Id`·`*Ids` 인 속성만 문자열로 바꾼다. `DashboardDto.java:23` 의 `List<Integer> unsignedContracts` 는 이름이 맞지 않아 숫자로 나간다.
- 영향: 현재 소비자 없음. FE 가 쓰면 `List<String>` 캐스팅에서 타입 오류.

### [낮음] 시작이 지난 근무의 대타 요청이 `open` 으로 계속 남아 대시보드 "대타 승인 대기" 건수에 잡힘

- 재현 (실제 시각 사용):
  ```sh
  O=$(qa-user a19-owner); S4=$(qa-user a19-staff4)
  # 23:06 에 23:08 시작 근무 생성 → 대타 요청
  curl -s -XPOST $B/stores/36/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"date":"2026-11-17","startMin":1388,"endMin":1410,"part":"마감","staffIds":[79]}'   # id 1046
  curl -s -XPOST $B/stores/36/shifts/1046/substitute-requests -H "Authorization: Bearer $S4" -H 'Content-Type: application/json' -d '{"reason":"급한 일"}'   # id 22
  # 23:09 (근무 시작 뒤)
  curl -s $B/stores/36/dashboard -H "Authorization: Bearer $O"            # pendingSubstitutes 에 22 open 그대로
  curl -s -XPOST $B/stores/36/substitute-requests/22/approve -H "Authorization: Bearer $O"
  curl -s -XPOST $B/stores/36/substitute-requests/22/assign -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"staffId":77}'
  ```
- 기대: 근무가 시작되면 요청이 만료(또는 대시보드 대기 건수에서 제외).
- 실제: `pendingSubstitutes` 에 `('22','1046','open')` 이 남는다. `approve` → `409 NO_ACCEPTED_APPLICANT`, `assign` → `409 SHIFT_STARTED "이미 시작했거나 지난 근무는 대타 승인할 수 없어요"`. 사장님이 할 수 있는 건 `reject` 뿐(200). `/me/state` 의 `subs` 도 같고 FE `pendingSubs`(`app_store.dart:472-473`, `SubstituteRequest.pending` = `open|accepted`, `models.dart:709`)도 날짜를 보지 않아 웹 KPI "대타 승인 대기 N건"·앱 "대타 모집 N건"에 계속 잡힌다.
- 원인: `DashboardService.java:73-77` 와 `StateService` 의 subs 는 상태만 본다. 시작이 지난 open/accepted 요청을 닫는 스케줄러가 없다(`@Scheduled` 는 `AttendanceAutoClockOut` 하나뿐).
- 영향: 처리할 수 없는 요청이 대기 건수로 남아 사장님이 일일이 거절해야 한다. 앱 `_SubAlert`(`employer_dashboard_screen.dart:191-`)가 "인력 공백 주의" 카드를 지난 근무에 대해 계속 띄운다.

### [낮음] 웹 "직원 근무 현황" 주 이동은 끝이 없는데 `/me/state` 근무는 고정 범위만 있음 → 범위 밖 주는 근무가 있어도 전부 "휴무"

- 재현:
  ```sh
  O=$(qa-user a19-owner)
  for d in 2026-09-27 2026-09-28 2027-02-28 2027-03-01; do
    curl -s -XPOST $B/stores/36/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d "{\"date\":\"$d\",\"startMin\":540,\"endMin\":1080,\"staffIds\":[79]}"; done
  curl -s $B/me/state -H "Authorization: Bearer $O"               # 직원4(매니저) 근무: 2026-09-28, 2027-02-28 만 (09-27, 03-01 없음)
  curl -s "$B/stores/36/dashboard?date=2026-09-27" -H "Authorization: Bearer $O"   # todayShifts 에 1101 있음
  ```
- 기대: 주 이동 범위를 state 범위로 막거나, 범위 밖 주는 서버에서 받아 오기.
- 실제: state 범위는 `2026-09-28`(지난달 1일이 든 주의 월요일) ~ `2027-02-28`(3개월 뒤 말일). 웹 `_StaffWeekCard` 의 `‹ ›`(`web_dashboard_screen.dart:43,110-113,271`, `_week` 제한 없음)로 9/21 주나 3/1 주로 가면 매니저가 9/27·3/1 에 근무가 있어도 "휴무" 로 그리고 합계 0 시간으로 보인다.
- 원인: `donBug_BE/.../service/StateService.java:124-125` 범위 고정, FE `web_dashboard_screen.dart:110-113` 이 범위를 모름.
- 영향: 사장님이 지난 주를 거슬러 보면 근무 현황이 틀리게(비어) 보임.

### [정보] 자정 넘은 야간 근무는 다음 날 "오늘 근무"에 없음

- 23:03 에 만든 `123`(직원2, 11/17 22:00–02:00, 22:05 출근, 퇴근 전)으로 00:01 에 확인. 결과는 아래 "자정 확인" 절.

## 통과한 케이스

1. 데이터 없는 매장(37) `/dashboard` → 200, 모든 목록 빈 배열, 숫자 0
2. 가입 신청 5건 → `pendingJoinRequests` 5, 4명 승인 → 1, 마지막 1명 거절 → 0
3. 신청만 한 상태에서 `certAlerts` 비어 있음(재직자만 대상), 승인 직후 미등록 4명 `daysLeft:null`
4. `todayShifts` 는 실제 근무만: 시간 미정(126)·연차(127) 제외
5. `todayShifts` 시작 시각순 정렬(08:00 → 17:00 → 22:00 → 23:00 → 23:08)
6. 상태 계산: 끝난 근무 무출근 `absent`(122), 지각 퇴근 `late`·`lateMinutes 10`·`workedMinutes 260`(17:10–22:00 − 휴게 30), 출근 중 `working`·`lateMinutes 5`(123), 시작 전·진행 중 무출근 `waiting`(125, 1046)
7. 야간 근무(22:00–02:00)는 시작 날짜의 `todayShifts` 에 포함
8. 같은 날 같은 직원 근무 2개(122, 125) 둘 다 표시
9. 권한: 알바생 403, 미승인 신청자 403, 매니저 403, 퇴사자 403, 남의 사장님 403(`사장님만 사용할 수 있어요`), 다른 매장(37)에 매장 36 매니저 403
10. 인증 없음 401, 없는 매장 404 `NOT_FOUND`, `storeId=abc` 400, `POST /dashboard` 405
11. `date=` 빈 값 → 오늘, `date=9999-12-31`·`0001-01-01` 200 빈 목록, 중복 `date` 파라미터 → 첫 값
12. `date=` 미래(11-20, 11-21) → 그날 근무 `waiting`
13. `date=` 에 따라 `certAlerts.daysLeft` 가 그 날짜 기준으로 계산(12-18 에 D-0, 12-19 에 −1)
14. 보건증 만료 당일 `daysLeft 0`, 어제 만료 `−1` 포함
15. 퇴사 처리 뒤: 출근 기록 있는 오늘 근무(128)는 `todayShifts` 에 남고 `staff.status=left`, 퇴사자는 `certAlerts`·`unsignedContracts` 에서 빠짐, FE `activeStaff` 에서도 빠짐
16. `unsignedContracts`: 계약서 발송 전 `[]`, 발송 뒤 `[76,77]`, 77 서명 뒤 `[76]`, 77 에게 새 계약서 재발송 → 최신 계약 기준 다시 포함
17. `pendingSubstitutes`: open 2건 → 하나 지원(accepted) → `acceptedId`·`applicantIds` 반영, 거절(22) 뒤 목록에서 빠짐. `/me/state.subs` 와 같은 값
18. `unreadNotificationCount` 가 FE 규칙(`toPersonId==me && storeId==store`, `app_store.dart:520-533`)으로 state 에서 센 값과 같음(9). 매장 37 은 0(매장 섞임 없음). `read-all` 뒤 0
19. FE `shiftsOn(today)` 규칙을 `/me/state` 에 적용한 오늘 근무 목록 = BE `todayShifts` (퇴사 전·후 두 번 대조, 출근 상태도 같음)
20. `/me/state` 매장 36 근무 10건 = DB `schedule`(범위 내) 10건, 필드(id·직원·날짜·시작·끝·휴게·종류·미정) 전부 일치
21. `/me/state` `scheduledMinutes`(= endAbs − start − break)·`isWork`(work && !timeTbd) 전부 올바름
22. state 범위 경계: 2026-09-27 제외 / 09-28 포함, 2027-02-28 포함 / 03-01 제외 (BE 의도와 일치)
23. `/dashboard?date=` 는 state 범위 밖 날짜(09-27, 03-01)도 조회됨
24. 같은 요청 15개 동시 → 모두 200
25. 사장님 두 매장: `/me/state?storeId=37` 이 `ownerStoreId:"37"` 으로 전환, 매장 37 알림·근무에 매장 36 것이 섞이지 않음

## 자정 확인

(00:01 결과로 채움)

## 못 한 것

- FE 화면 렌더링 자체: 웹 컨테이너를 안 띄워서 `/me/state` 에 FE 규칙을 손으로 적용해 비교했다. "이번 달 예상 인건비"·"지난달 대비"(`laborTotal`)·"주휴수당 대상/합계"(`scheduleSummary`)는 FE 계산식만 읽고 근거 데이터(근무·출근)가 DB 와 같은 것까지만 확인했다. 금액 검증은 18번(payroll) 영역.
- 월 1일·월요일 실제 날짜 경계: 오늘이 11/17(화)이라 실제 "오늘"로는 못 했고 `date=` 파라미터(11-30/12-01 등)와 state 범위 계산(`StateService.java:124`, 월요일 보정)을 코드·요청으로만 확인.
- BE 컨테이너 시간대: `DashboardController.java:32` 의 `LocalDate.now()`, `StateService.java:122` 의 `LocalDateTime.now()` 는 `TimeUtil`(KST 고정)을 안 쓰고 JVM 기본 시간대를 쓴다. `be.Dockerfile`·`docker-compose.yml` 에 `TZ=Asia/Seoul` 이 있어 지금은 결과가 같다(실제로 `date` 없이 부른 값 = 2026-11-17). TZ 설정이 빠진 환경에서만 문제가 되므로 버그로 올리지 않았다.
- `/dashboard` 400 응답(잘못된 `date`, 문자열 `storeId`) 본문이 `{code,message}` 가 아닌 Spring 기본 `{timestamp,status,error,path}` 이다(`ApiExceptionHandler` 에 타입 변환 오류 처리 없음). 전 엔드포인트 공통이라 23번(robustness) 영역으로 넘긴다.
