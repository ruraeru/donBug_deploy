# 15 notifications QA 보고서

## 요약

- 실행한 케이스: 62
- 통과: 55
- 발견: 7 (치명 0 · 높음 0 · 중간 3 · 낮음 4)

테스트 데이터: 사장님 `a15-ownerA`(매장 A, id 33, 코드 `KTAE-PQ9N`)·`a15-ownerB`(매장 B, id 34, 코드 `F55H-XQ3J`), 알바 `a15-staff1`(A staff 69, 뒤에 퇴사)·`a15-staff2`(A staff 70)·`a15-staff3`(A 거절, B staff 72)·`a15-staff4`(A staff 129, B 재직)·`a15-pending`(A 대기 130)·`a15-rej`(A 거절 → 재신청 → 승인 → 퇴사), 무소속 `a15-outsider`.

아래 재현에서 `$B=http://127.0.0.1:18080/api/v1`, `$OA=$(qa-user a15-ownerA)` 처럼 토큰을 label 로 적는다.

## 발견

### [중간] 확정된 달 근무표를 삭제하면 직원에게 알림이 없다
- 재현:
  1. `POST $B/stores/33/schedules {"month":"2026-12"}` → `PUT $B/stores/33/schedules/2026-12/shifts` 로 staff 70 의 12/7 근무 포함 저장 → `POST $B/stores/33/schedules/2026-12/confirm` (직원 전원 "12월 근무표가 확정됐어요" 받음)
  2. `DELETE $B/stores/33/schedules/2026-12` (토큰 a15-ownerA) → 204
  3. `SELECT count(*) FROM schedule WHERE schedule_id=1055` → 0, 그 뒤 생긴 `notification` 행 0개
- 기대: 이미 확정 근무표를 받은 직원에게 근무가 사라졌다고 알린다. 같은 달을 `PUT .../shifts` 로 비우면 "12월 확정 근무표가 바뀌었어요", 근무 하나를 `DELETE /shifts/{id}` 하면 "근무가 삭제됐어요" 가 간다.
- 실제: 204, 근무는 지워지고 알림은 0건.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/service/MonthScheduleService.java:318-323` `delete()` 가 `removeShifts()`(`:715`) 만 부르고 확정 여부를 보지 않는다. `saveShifts` 의 `ChangedDays.notify`(`:248`, `:272`) 같은 처리가 없다.
- 영향: 확정 근무표를 받은 알바생이 지워진 근무에 그대로 출근할 수 있다(푸시가 없어 앱 알림 센터가 유일한 안내 경로).

### [중간] 퇴사·근무 삭제로 진행 중 대타가 정리될 때 관련자에게 알림이 없다
- 재현 A (후보가 퇴사):
  1. a15-staff2 근무 12/15(shift 1791), a15-rej 근무 12/16(shift 1792) 생성
  2. a15-staff2: `POST $B/stores/33/shifts/1791/substitute-requests {"reason":"S2요청","notifyPeers":false}` → request 52
  3. a15-rej: `POST .../shifts/1792/substitute-requests` → request 53, a15-rej: `POST .../substitute-requests/52/apply`(후보가 됨, a15-staff2 는 "거절생님이 대타를 수락했어요" 받음), a15-staff2: `POST .../substitute-requests/53/apply`
  4. a15-ownerA: `DELETE $B/stores/33/staff/183` → 204
  5. DB: request 52 는 `OPEN`, `taker_id NULL` 로 돌아감. request 53 은 행이 지워짐(퇴사자 앞으로 남은 근무 삭제 → `ScheduleDeleter` 가 대타 요청까지 삭제). 그 뒤 생긴 알림은 퇴사자 본인의 "퇴사 처리됐어요" 1건뿐.
- 재현 B (근무 삭제):
  1. a15-staff4: `POST .../substitute-requests/52/apply` → `accepted`
  2. a15-ownerA: `DELETE $B/stores/33/shifts/1791` → 204
  3. 요청 52 삭제됨. 알림은 a15-staff2 의 "근무가 삭제됐어요" 1건뿐이고, 후보였던 a15-staff4 에게는 없다.
- 기대: 요청자가 직접 취소할 때(`cancel`)처럼 요청자·지원자에게 "대타 요청이 취소됐어요 / 후보가 빠졌어요" 를 알린다.
- 실제: 위와 같이 요청자(a15-staff2)는 마지막으로 "수락했어요" 만 본 채 요청이 조용히 OPEN 으로 돌아가고, 지원자는 요청이 사라진 것을 모른다.
- 원인: `service/StaffService.java:164-176`(진행 중 대타를 CANCELLED/OPEN 으로 바꾸지만 알림 없음), `service/ScheduleDeleter.java:26-35`(근무 삭제 때 대타 요청·지원자를 지우지만 알림 없음). 비교: `service/SubstituteService.java:167-172` `cancel()` 은 지원자·사장님에게 알린다.
- 영향: 요청자는 대타가 정해진 줄 알고 결근할 수 있고, 후보였던 직원은 사라진 근무에 대비한다.

### [중간] 보건증 만료 알림(`certAlertDays`)을 보내는 곳이 없다
- 재현:
  1. a15-staff3: `PUT $B/me/health-cert` multipart `expiry=2026-11-24`, `alertDays=30,14,7,0`, `photo=@p.png` → 200, `certDaysLeft:7`
  2. 스케줄러가 한 번 더 돈 뒤(23:13:26, 자동 퇴근 처리로 확인) `GET $B/me/notifications` (a15-staff3), 매장 B 사장님(a15-ownerB) 목록 확인
- 기대: 만료 D-30/14/7/0 에 직원(그리고 사장님)에게 `cert` 알림. 앱 보건증 등록 화면(`donBug_FE/lib/screens/employee/health_cert_register_screen.dart:38`, `:91`)이 알림 시점을 고르게 하고, 웹 대시보드(`web_dashboard_screen.dart:99`)도 "N일 전 알림" 이라고 보여준다.
- 실제: 만료 7일 전인데 알림 0건. 사장님이 `cert-renewal-requests` 를 수동으로 누를 때만 생긴다.
- 원인: BE 전체의 `@Scheduled` 는 `service/AttendanceAutoClockOut.java:38` 하나뿐이다. `certAlertDays` 는 `service/DocumentService.java:55-63` 에서 저장만 한다. `donBug_BE/api_design.md:406` 에도 "발송 로직이 없으므로 서버 스케줄러가 필요" 라고 적혀 있으나 배포 레포 "아직 안 된 것" 목록에는 없다.
- 영향: 사용자가 고른 알림 시점에 아무 알림도 오지 않아, 만료된 보건증으로 일하게 될 수 있다(식품위생법 위반 위험).

### [낮음] `POST /schedule/confirm` 을 반복하면 "N월 근무표가 확정됐어요" 가 매번 다시 간다
- 재현: a15-ownerA: `POST $B/stores/33/schedule/confirm {"year":2027,"month":1}` 3번 → 3번 모두 204. a15-staff1·2·4 각각 "1월 근무표가 확정됐어요" 3건.
- 기대: 이미 확정했으면 다시 알리지 않는다(`/schedules/{month}/confirm` 은 멱등).
- 실제: 월 메타(`month_schedule`)가 없거나 DRAFT 이면 매번 재직 직원 전원에게 알림을 만든다. 이 엔드포인트는 메타를 CONFIRMED 로 바꾸지도 않는다.
- 원인: `service/ShiftService.java:420-432` 는 메타가 CONFIRMED 일 때만 중복을 막는다.
- 영향: FE 는 `confirmSchedule`(`app_store.dart:1381`)을 정의만 하고 화면에서 부르지 않아 지금은 직접 API 호출로만 생긴다. 예전 앱이나 다른 클라이언트가 부르면 중복 알림이 쌓인다.

### [낮음] `sub` 알림의 `refId` 가 근무 id 일 때와 대타 요청 id 일 때가 섞여 있다
- 재현: a15-ownerA: `POST $B/stores/33/shifts {"date":"2026-11-25","startMin":540,"endMin":780,"part":"오픈","staffIds":[69]}` → a15-staff1 알림 `type:"sub"`, "새 근무가 배정됐어요", `refId:"173"`(= shift id). 대타 알림은 `type:"sub"`, `refId:"7"`(= substitute request id).
- 기대: 같은 `type` 이면 `refId` 는 같은 종류 id(FE 는 `sub` 의 refId 를 대타 요청 id 로 읽는다).
- 실제: FE `screens/employee/notification_center_screen.dart:34-39` 가 `store.subById(n.refId)` 로 화면을 고른다. 근무 id 와 같은 번호의 대타 요청이 그 매장에 있으면 엉뚱한 대타 화면이 열린다. 이번 데이터는 shift id(173~)와 sub id(7~53)가 겹치지 않아 실제로 잘못 열리는 것까지는 재현하지 못했다. 근무 id 가 refId 로 오는 것은 재현했다.
- 원인: `service/ShiftService.java:131`, `:198`, `:201`, `:203` 이 `Notification.Type.SUB` 에 `s.getId()`(근무 id)를 넣는다. `service/AttendanceAutoClockOut.java:68`, `:73` 은 SUB 에 attendance id 를 넣는다.
- 영향: 서비스 초기처럼 id 가 작을 때 알림을 누르면 관계없는 대타 요청 화면이 열릴 수 있다.

### [낮음] 퇴근 미기록·자동 퇴근 알림이 사장님에게 `sub`(대타) 종류로 간다
- 재현: 매장 A 에 오늘 14:00–18:00(shift 1513, staff 70), 20:00–22:00(shift 1514, staff 129) 근무를 만들고 `POST $B/stores/33/shifts/{id}/attendance {"clockIn":"…","reason":"수동"}` 로 퇴근 없는 기록을 만든 뒤 스케줄러를 기다림. 23:13:26 스케줄러 실행 뒤 사장님(user 184)에게 `notification` 1364 "퇴근이 자동 처리됐어요"·1366 "퇴근 기록이 없어요" 가 모두 `type=SUB` 로 생김.
- 기대: 근태 알림이므로 FE 가 근태 화면으로 보내는 종류(`pay` 등)를 쓴다.
- 실제: `type:"sub"` 로 저장된다. FE 사장님 앱 `screens/employer/employer_parts.dart:380-381` 은 `sub` 를 누르면 `SubstituteApprovalScreen`(대타 승인), 웹 `web_dashboard_screen.dart:575-576` 은 `WebMenu.substitute` 로 보낸다.
- 원인: `service/AttendanceAutoClockOut.java:68`, `:73` `Notification.Type.SUB`.
- 영향: 사장님이 "퇴근 기록이 없어요" 를 누르면 대타 승인 화면이 열려 근태를 고치러 다시 찾아가야 한다.

### [낮음] 퇴사·가입 거절 알림은 앱에서 볼 수 없다
- 재현: a15-ownerA: `DELETE $B/stores/33/staff/69` → a15-staff1 `GET $B/me/state` 의 `stores:[]`, `session.employeeStoreId:""` 인데 `notifications` 에는 storeId 33 의 "QA15 매장A에서 퇴사 처리됐어요" 가 있다. 거절(a15-rej)도 같다.
- 기대: 당사자가 이 알림을 볼 수 있다.
- 실제: FE `myNotifications`(`donBug_FE/lib/data/app_store.dart:520-523`)는 `storeId == store.id`(지금 매장)인 것만 보여주는데, 그 매장은 상태에 더 이상 없다. 거절은 가입 대기 화면이 토스트로 대신 알리지만(`join_pending_screen.dart:36`) 퇴사는 아무 안내 없이 역할 선택으로 간다.
- 원인: BE 는 매장 소속이 끝난 뒤의 알림을 만들어 두고(`service/StaffService.java:112`, `:185`), FE 는 지금 매장 기준으로만 거른다. 둘 중 한쪽 계약을 맞춰야 한다.
- 영향: 퇴사 처리된 알바생이 이유를 모른 채 매장 화면이 사라진 것을 보게 된다.

## 통과한 케이스

- 목록: 본인 알림만, 최신순(`createdAt desc, id desc`), `storeId` 필터, 응답 모양이 FE `AppNotification.fromJson` 과 맞음(id·storeId·toPersonId·refId 문자열, type `sub/notice/cert/pay/join/contract`, body null → FE `?? ''`)
- unread-count: 전체·매장별, 다른 매장 storeId → 0
- read: 본인 204, 같은 것 두 번 204(멱등), 남의 알림 403 + DB `is_read` 그대로, 없는 id 404, 음수 404, 문자 id·int 범위 초과 400, GET 405, 인증 없음 401
- read-all: storeId 있으면 그 매장만(B 만 읽음 → A 22건 그대로), 없으면 전체, 남의 매장 storeId 는 아무것도 안 바꿈, 15개 동시 read-all·read 모두 204·오류 없음
- 가입 신청 → 사장님 `join` "OO님이 가입을 신청했어요"(refId = staff id), 중복 신청(409 alreadyPending)·사장님 자기 매장 신청(409 alreadyMember)은 알림 없음, 거절 뒤 재신청은 새 알림
- 승인 → 신청자 "OO 가입이 승인됐어요"(시급 표기), 거절 → "가입이 거절됐어요", 두 번째 승인·거절은 409 + 알림 없음
- 근무 생성 → "새 근무가 배정됐어요"(반복 생성은 첫 주만, FE 와 같음), 시간 미정·휴무 생성은 알림 없음, 시간 변경 → "근무가 수정됐어요", 같은 값 PATCH 는 알림 없음, 담당자 변경 → 이전 담당 "삭제"·새 담당 "배정", 연차로 바꾸기 → "삭제", 다시 근무로 → "배정", 삭제 → "근무가 삭제됐어요"
- 대타: 신청 → 사장님 + (notifyPeers·substitutePush 둘 다 켜졌을 때만) 요청자를 뺀 재직 직원, 가입 대기자 제외. notifyPeers=false·매장 substitutePush=false 이면 동료 알림 없음(재알림 포함)
- 대타 지원 → 요청자·사장님 "OO님이 대타를 수락했어요", 같은 사람 두 번 지원은 알림 1건
- 대타 취소 → 지원자 전원·사장님, 승인 → 요청자("…님이 근무해요")·후보("대타 근무가 확정됐어요"), 거절 → 요청자·후보, 직접 배정 → 승인과 같음, 이미 처리된 요청 재처리 409 + 알림 없음
- 공지 작성 → 재직 직원 전원("새 필독 공지"/"새 공지", refId = 공지 id), 가입 대기자·퇴사자 제외, 알바생 작성 403
- 공지 remind → 안 읽은 사람만(읽은 a15-staff2 제외, `sent:2`), 1시간 안 재요청 409, 일반 공지 409
- 보건증 갱신 요청 → 직원 `cert`(미등록 "보건증을 등록해 주세요"), 대기자 409, 다른 매장 사장님 403/404, 알바생 403
- 보건증 업로드 → 재직 중인 모든 매장 사장님에게만 "갱신했어요"(거절된 매장 A 사장님은 안 받음), 사진 없으면 400 + 알림 없음
- 계약서 작성 → 직원 "근로계약서 서명 요청"(refId = 계약서 id), 서명 → 사장님 "서명했어요", 두 번 서명 409 + 알림 없음
- 근태 수정(PATCH attendance) → 직원 `pay` "근태 기록이 수정됐어요"(사유가 body, 이모지 정상)
- 월 근무표 확정 → 재직 직원 전원, 같은 달 두 번 확정은 알림 1번, 확정 뒤 저장 → 바뀐 직원에게만 "12월 확정 근무표가 바뀌었어요"(바뀐 날짜 목록), 같은 내용 재저장은 알림 없음
- 퇴사 → 본인 "퇴사 처리됐어요", 그 뒤 공지는 받지 않음
- 자동 퇴근 스케줄러(23:13:26 실행): 종료 4시간 지난 attendance 119 → `actual_end` 18:00 + 사장님 "퇴근이 자동 처리됐어요"(SUB) + 직원 같은 문구(PAY). 종료 1~4시간 사이인 120 → 사장님 "퇴근 기록이 없어요" 1번, `missing_out_notified_at` 기록. 대상·문구는 맞고, 종류(SUB)만 위 [낮음] 발견. 같은 스케줄러 실행 뒤에도 만료 7일 전 보건증(23:12:05 등록) 알림은 생기지 않았다(위 [중간] 발견의 근거).
- 한 사람이 두 매장에 있을 때 매장별로 분리돼 쌓이고 `/me/state` 에는 전부 실림
- 제목 길이: 사람 이름 50자·매장 이름 100자가 최대라 `notification.title`(200자)을 넘을 문구 없음

## 못 한 것

- `sub` refId 충돌로 FE 가 잘못된 화면을 여는 것: 다른 에이전트 데이터를 건드리지 않고는 같은 번호의 근무 id·대타 요청 id 를 만들 수 없어 코드로만 확인했다.
- FE 화면 자체(알림 센터 렌더링)는 API 로만 테스트해서 보지 않았다.
- 테스트 중 `POST /schedules` 한 번이 500 이었다. BE 로그상 원인은 같은 시각 다른 에이전트 부하로 생긴 Hikari 커넥션 풀 고갈(`Connection is not available, request timed out after 30003ms`)이다. 다시 보내니 200 이어서 이 영역 버그로 보지 않았다.
