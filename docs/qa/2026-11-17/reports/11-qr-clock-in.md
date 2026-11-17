# 11 qr-clock-in QA 보고서

## 요약

- 실행 케이스 61개, 통과 58개, 발견 3건 (치명 0 · 높음 0 · 중간 0 · 낮음 3)
- 테스트 시각: 2026-11-17 23:02~23:07 KST (서버 시각). 22:00~02:00 야간 근무를 만들어 자정 넘김 근무로 출근을 검증했다.
- 픽스처: 매장 A `id=20`(코드 `C36L-YK85`, 사장 `a11-ownerA`), 매장 B `id=21`(코드 `GGVV-8Z7R`, 사장 `a11-ownerB`).
  - 알바: `a11-staff1`(A=30, B=33), `a11-staff2`(A=31), `a11-staff3`(A=142, 테스트 중 퇴사), `a11-staff4`(A=143), `a11-staff5`(A=144), `a11-staffB`(B=32, A=161), `a11-pending`(A=145, 미승인), `a11-nobody`(무소속)
  - 근무: 31(staff1 오늘 22:00–02:00), 32(staff1 내일 10:00), 33(staff1 오늘 08:00–12:00, 끝남), 34(staff2 22:00–02:00), 35(B, staff1 22:00–02:00), 36(B, staffB), 40·42(OFF), 41(TBD), 626(staff4 지금+27분 시작), 627(staff5), 686(A, staffB)
- 공통 셸 정의(아래 재현에서 사용):
  ```sh
  QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
  B=http://127.0.0.1:18080/api/v1; H='Content-Type: application/json'
  tok(){ curl -s $B/stores/$1/qr-token -H "Authorization: Bearer $2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'; }
  ```

## 발견

### [낮음] 같은 사용자가 서로 다른 근무에 동시에 출근하면 열린 출근 기록이 2개 생긴다 (ALREADY_CLOCKED_IN 우회)

- 재현 (staffB 가 매장 A·B 둘 다 재직, 오늘 22:00–02:00 근무가 각각 686(A)·36(B)):
  ```sh
  SB=$($QA/qa-user a11-staffB); OA=$($QA/qa-user a11-ownerA); OB=$($QA/qa-user a11-ownerB)
  TA=$(tok 20 $OA); TB=$(tok 21 $OB)
  for i in 1 2 3 4 5; do
    curl -s -o /dev/null -w "A[%{http_code}]\n" -X POST $B/stores/20/shifts/686/clock-in -H "Authorization: Bearer $SB" -H "$H" -d "{\"qrToken\":\"$TA\"}" &
    curl -s -o /dev/null -w "B[%{http_code}]\n" -X POST $B/stores/21/shifts/36/clock-in  -H "Authorization: Bearer $SB" -H "$H" -d "{\"qrToken\":\"$TB\"}" &
  done; wait
  $QA/qa-sql "SELECT attendance_id,schedule_id,actual_start,actual_end FROM attendance WHERE schedule_id IN (686,36)"
  ```
- 기대: 한쪽만 200, 다른 쪽은 409 `ALREADY_CLOCKED_IN` (순차 요청에서는 실제로 이렇게 동작함, 케이스 S4).
- 실제: A·B 둘 다 200. DB 에 `actual_end IS NULL` 기록 2개(attendance 60·61, 시작 시각 3ms 차이).
- 원인: `donBug_BE/src/main/java/com/example/moneybug/service/AttendanceService.java:81` 의 `findOpenByUser` 확인과 `:95` 저장 사이에 잠금이 없다. unique 제약은 `attendance.schedule_id` 하나뿐이라(같은 근무 동시 출근만 막음, `AttendanceController.java:42-46` 재시도) 다른 근무끼리는 막을 장치가 없다.
- 영향: 두 기기로 거의 동시에 스캔하는 드문 경우에만 생긴다. 생기면 한 사람이 두 매장(같은 매장의 연속 근무 둘도 가능)에서 동시에 근무 중으로 기록되어 근무시간·급여가 이중으로 잡힌다. `/me/today` 는 둘 중 하나만 보여준다.

### [낮음] 다른 매장에 열린 출근이 있으면 "먼저 퇴근해 주세요" 만 나오고, 지금 매장 화면에는 퇴근 버튼이 없다

- 재현:
  ```sh
  S1=$($QA/qa-user a11-staff1); OA=$($QA/qa-user a11-ownerA); OB=$($QA/qa-user a11-ownerB)
  curl -s -X POST $B/stores/20/shifts/31/clock-in -H "Authorization: Bearer $S1" -H "$H" -d "{\"qrToken\":\"$(tok 20 $OA)\"}"   # 매장 A 출근 200
  curl -s -X POST $B/stores/21/shifts/35/clock-in -H "Authorization: Bearer $S1" -H "$H" -d "{\"qrToken\":\"$(tok 21 $OB)\"}"   # 매장 B
  curl -s "$B/me/state?storeId=21" -H "Authorization: Bearer $S1" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["session"]);print([(a["storeId"],a["staffId"],a["clockOut"]) for a in d["attendance"]])'
  ```
- 기대: 어느 매장에서 퇴근을 안 했는지 알려주거나, 지금 화면에서 퇴근할 수 있어야 한다.
- 실제: 409 `{"code":"ALREADY_CLOCKED_IN","message":"퇴근하지 않은 근무가 있어요. 먼저 퇴근해 주세요"}`. `/me/state?storeId=21` 의 `session.employeeStoreId=21` 인데 열린 기록은 `storeId=20, staffId=30` 이라 FE `myOpenAttendance` 가 null → 매장 B 홈에는 "퇴근" 버튼이 없다.
- 원인: BE `AttendanceService.java:81-83` 은 매장 구분 없이 막는데 메시지에 매장 이름이 없다. FE `donBug_FE/lib/data/app_store.dart:405-411` `myOpenAttendance` 는 현재 매장 `myStaff.id` 로만 찾는다. 퇴근 API(`AttendanceService.java:111`)도 매장 범위다.
- 영향: 두 매장에서 일하는 알바가 A 매장 퇴근을 잊으면, B 매장에서 QR 스캔이 계속 실패한다. 매장 전환(`store_switch_screen.dart`)으로 A 로 가야 한다는 걸 스스로 알아내야 한다. 퇴근을 잊으면 자동 퇴근(종료 4시간 뒤)까지 막힌다.
- 참고: 끝난 근무(33)에 출근을 시도해도, 열린 출근이 있으면 `SHIFT_ENDED` 대신 같은 `ALREADY_CLOCKED_IN` 이 나온다(확인 순서 `:81` → `:84`).

### [낮음] 출근 응답의 clockIn 정밀도가 첫 응답과 이후 응답에서 다르다

- 재현: 위 첫 출근 요청을 같은 토큰으로 두 번 보낸다.
- 기대: 같은 기록이면 같은 문자열.
- 실제: 첫 응답 `"clockIn":"2026-11-17T23:03:57.653577466"`(나노초 9자리), 두 번째(멱등) 응답과 `/me/state` 는 `"2026-11-17T23:03:57.653577"`(DB `datetime(6)` 마이크로초). 퇴근 응답 `clockOut` 도 같다(`23:05:48.088598128`).
- 원인: `AttendanceService.java:73,93,96` 이 `LocalDateTime.now()` 값을 저장 전 엔티티 그대로 직렬화한다. DB 는 마이크로초로 자른다.
- 영향: Dart `DateTime.parse` 는 둘 다 읽어서 화면 문제는 없다. FE `clockInRemote`(`app_store.dart:763-786`)가 응답으로 기록을 만들 때만 1μs 미만 차이. 문자열 비교를 하는 곳이 생기면 어긋난다.

## 통과한 케이스

qr-token (GET `/stores/{id}/qr-token`)
- T1 사장 A → 200 `{"token":"v1.20.<step>.<sig>","expiresAt":"...Z","periodSeconds":30}`. `expiresAt` = (step+1)×30 초, ISO-8601 Z → FE `DateTime.parse` 가능
- T2 사장 A 가 매장 B 토큰 요청 → 403
- T3 알바(staff1) → 403 (알바는 토큰을 받을 수 없음)
- T4 무소속 → 403
- T5 인증 없음 → 401
- T6 없는 매장 999999 → 404
- T7 매장 id `abc` → 400
- T8 깨진 JWT → 401
- T9 매장 id -1 → 404
- T10 매장 id 99999999999(int 초과) → 400
- T11 매장 B 의 알바가 매장 B 토큰 요청 → 403
- D3 퇴사자 → 403

clock-in 토큰 검증 (모두 400 `INVALID_QR`, DB 기록 0개 확인)
- C1 본문 없음 / C1b Content-Type 만 있고 본문 없음
- C2 `{}` / C3 `""` / C4 `null`
- C5 서명 한 글자 변조
- C6 매장 B 토큰을 매장 A 경로에
- C7 매장 A 토큰을 매장 B 경로에
- C9 step+1 로 바꾼 미래 토큰(같은 서명) / C9b 토큰 안 storeId 만 바꿈
- C10 `qrToken` 숫자 123
- C12 뒤에 공백 / C12b 100KB 문자열 / C12c 이모지·한글
- P14 남의 근무 + 잘못된 QR → 400 (QR 검증이 소유 확인보다 먼저라 근무 존재 여부가 새지 않음)
- E1 발급 step 시작 후 40초(직전 step) → 아직 유효(200)
- E2 발급 step 시작 후 62초 → 400 (유효 시간 30~60초 설계대로)

clock-in 권한·상태
- P1 사장이 자기 매장 근무 출근 → 403
- P2 staff2 가 staff1 근무 출근 → 403 "본인 근무만"
- P3 무소속 → 403
- P4 매장 B 알바가 매장 B 토큰으로 매장 A 경로 → 403
- P5 없는 근무 → 404 / P6 매장 B 근무를 매장 A 경로로 → 404 / P7 없는 매장 → 404
- P8·P10 OFF 근무 → 409 `NOT_WORK_SHIFT` / P9 시간 미정(TBD) → 409 `NOT_WORK_SHIFT`
- P11 내일 근무 → 409 `TOO_EARLY` / P12 끝난 근무 → 409 `SHIFT_ENDED`
- B1 시작 33분 전 → 409 `TOO_EARLY` / B2 시작 27분 전 → 200, `lateMinutes:0`
- B3 미승인(PENDING) 신청자 → 403 (미승인자에게는 근무 배정도 409 `NOT_ACTIVE`)
- D2 퇴사자 → 403 (퇴사 시 미래 근무 625 삭제됨)
- S1 정상 출근(자정 넘는 22:00–02:00 근무, 23:03) → 200, DB `check_method=QR`, `lateMinutes:63`, `/me/state` 반영
- S2 같은 토큰 재요청 / S3 새 토큰 재요청 → 200, 같은 id 24 (멱등)
- S4 매장 A 출근 중에 매장 B 출근(순차) → 409 `ALREADY_CLOCKED_IN`
- D1 퇴근 뒤 다시 출근 → 409 `ALREADY_CLOCKED_OUT`
- CC1 같은 근무에 15개 동시 출근 → 모두 200, DB 1행
- staff5 새 토큰 출근 → 200, `/me/today` `working:true`·`openAttendance` 일치
- 오류 응답 형식: `INVALID_QR` 등은 `{code,message,details}` (FE `qr_check_in_screen.dart:88` 이 `e.code == 'INVALID_QR'` 로 분기하는 것과 일치)

FE 대조
- 요청 `POST /stores/{storeId}/shifts/{shiftId}/clock-in` `{"qrToken": ...}` (`app_store.dart:765`) — BE 와 일치
- POS `GET /stores/{id}/qr-token` 응답에서 `token`·`expiresAt` 사용 (`web_pos_qr_screen.dart:70-75`) — BE 응답과 일치
- 데모용 로컬 출근(`_scan`, `_scanned`)은 `store.remote` 일 때 막혀 있음 (`web_pos_qr_screen.dart:208`)

## 못 한 것

- 깨진 JSON(C11), 배열·객체 `qrToken`(C10b·C10c), 문자열 본문(C11b), 숫자 아닌 shiftId(P13) → 400 이지만 본문이 Spring 기본 형식(`{"timestamp","status","error","path"}`)이라 `code` 가 없다. 모든 엔드포인트 공통이라 23번(robustness) 영역으로 넘긴다. form 본문(C12d) → 415.
- QR 60초 안 재사용·다른 사람에게 사진 공유, 위치 확인 없음: 배포 레포 CLAUDE.md "아직 안 된 것"에 있는 알려진 한계라 보고하지 않았다(토큰이 사용자에 묶이지 않는 것도 같은 문제).
- POS PC 시계가 서버보다 30초 넘게 늦으면, FE 가 `expiresAt`(서버 절대 시각)을 로컬 `DateTime.now()` 와 비교해 갱신(`web_pos_qr_screen.dart:55`)하므로 만료 토큰을 계속 보여줄 수 있다. Flutter 웹을 띄우지 않아 재현하지 못했다(코드 관찰만).
- 정확히 30분 전·종료 시각 경계(초 단위): 서버 시각을 조작할 수 없어 ±3분으로만 확인했다.
- 자동 퇴근(`AttendanceAutoClockOut`) 뒤 재출근: 4시간 대기가 필요해 하지 않았다(12번 attendance 영역).
- 사장님이 퇴근 없이 만든 수동 기록(MANUAL, clockOut null)과 QR 출근의 상호작용: 12번 영역.
