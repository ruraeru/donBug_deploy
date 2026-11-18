# 25 e2e-scenario QA 보고서

## 요약

- 시나리오: 사장님 `a25-owner`(김사장)가 매장 67 "돈벌래 카페 강남점"(코드 `MQV2-ZE39`)을 만들고 매니저 1명(`a25-mgr`)과 알바 8명(`a25-s1`~`a25-s8`)이 가입·승인한 뒤, 계약서·보건증 → 11·12월 근무표 작성·확정 → 지난 2주 출퇴근(사장님 수기 기록 API) + 오늘 QR 출근·자정 넘긴 퇴근 → 대타 3종(승인·직접 지정·거절) → 공지 → 급여 명세 → 퇴사·재신청까지 한 번에 돌렸다. 단계마다 사장님과 알바생 양쪽 `/me/state` 를 비교했다.
- FE `app_store.dart`·`api_client.dart`·`ai_api.dart`·`main.dart`·`web_pos_qr_screen.dart`·`mobile_boot.dart` 의 서버 호출 63곳(메서드·경로·본문)을 BE 컨트롤러·DTO 와 하나씩 맞춰 봤다. FE 가 부르는 경로는 전부 BE 에 있다. 대부분은 FE 가 보내는 본문 그대로 요청해서 확인했다(AI 근무표 preview·apply 는 10번 영역 몫이라 부르지 않았다).
- 실행한 케이스 92개 · 통과 86개 · 발견 6건 (치명 0 · 높음 1 · 중간 1 · 낮음 4)

## 발견

### [높음] 24:00 에 끝나는 근무(endMin 1440)를 단건 추가·수정하면 400, 다른 경로는 받아 준다
- 재현:
  ```sh
  T=$(qa-user a25-owner)
  # 1) 파트 끝을 24:00 으로 저장한다 (웹 설정 화면은 24:00 까지 고를 수 있다) → 200
  curl -X PUT  :18080/api/v1/stores/67/parts -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -d '{"parts":[...,{"id":208,"name":"마감","tone":"close","startMin":1020,"endMin":1440,"breakMin":30,"need":2}]}'
  # 2) 월 전체 저장(웹 편집기 초안 저장)에 endMin 1440 근무를 넣는다 → 200, DB end_min=1440 으로 저장됨 (shift 1797)
  curl -X PUT  :18080/api/v1/stores/67/schedules/2026-12/shifts ... '{"shifts":[...,{"staffId":138,"date":"2026-12-11","startMin":1200,"endMin":1440,"part":"마감","breakMin":30,"kind":"work","timeTbd":false}]}'
  # 3) 같은 근무를 앱·웹 대시보드의 단건 추가로 만든다 → 400
  curl -X POST :18080/api/v1/stores/67/shifts ... '{"date":"2026-12-10","startMin":1200,"endMin":1440,"part":"마감","staffIds":[138],"kind":"work","timeTbd":false}'
  # 4) 앱 근무 수정 화면이 보내는 모양(endMin 을 항상 같이 보낸다)으로 1797 을 수정 → 400
  curl -X PATCH :18080/api/v1/stores/67/shifts/1797 ... '{"staffId":138,"startMin":1200,"endMin":1440,"part":"마감","breakMin":30,"kind":"work","timeTbd":false}'
  ```
- 기대: 파트·월 저장이 24:00 을 받는다면 단건 추가·수정도 받는다. 아니면 모든 경로가 같은 규칙으로 막는다.
- 실제: 3)·4) 는 `400 {"code":"VALIDATION_FAILED","details":{"endMin":"must be less than or equal to 1439"}}`. 1)·2) 와 월 근무표 고정 근무 채우기는 1440 을 그대로 저장한다. 22:00→02:00(endMin 120)처럼 자정을 넘기는 근무는 단건 추가도 된다(201). 정확히 24:00 만 막힌다.
- 원인: `donBug_BE/.../dto/ShiftCommandDto.java:23`·`:41` 의 `@Max(1439)`. `StorePartDto.java:60`(`Item`)과 `MonthScheduleCommandDto.java:25`(`ShiftItem`)에는 이 제한이 없다. FE 는 24:00 을 정상 값으로 쓴다: `web_shift_dialog.dart:37`(시각 목록 360~1440), `:94`(1440 은 그대로 보냄), `web_settings_screen.dart:17`("파트 끝은 24:00 까지"), `shift_add_screen.dart:51`·`:114`·`:126`(파트의 endMin 을 그대로 보냄).
- 영향: 자정에 문을 닫는 매장(파트 끝 24:00)에서 사장님 앱 근무 추가 화면으로 마감 근무를 넣거나, 이미 있는 마감 근무를 앱에서 수정하면 "요청 값이 올바르지 않아요" 가 뜨고 화면에 잠깐 보인 근무가 reload 뒤 사라진다. 웹 대시보드 근무 창(초안 모드 아님)도 같다. 웹 편집기로는 저장돼서 경로마다 결과가 달라진다.

### [중간] 가입 신청이 404·409 이면 FE 가 결과를 읽지 못하고 "요청을 처리하지 못했어요" 만 띄운다
- 재현:
  ```sh
  curl -X POST :18080/api/v1/stores/join-requests -H "Authorization: Bearer $(qa-user a25-out)"  -d '{"code":"ZZZZ-ZZZZ"}'  # 404 {"result":"notFound","store":null}
  curl -X POST :18080/api/v1/stores/join-requests -H "Authorization: Bearer $(qa-user a25-s1)"   -d '{"code":"MQV2-ZE39"}'  # 409 {"result":"alreadyPending",...}
  curl -X POST :18080/api/v1/stores/join-requests -H "Authorization: Bearer $(qa-user a25-owner)" -d '{"code":"MQV2-ZE39"}' # 409 {"result":"alreadyMember",...}
  ```
- 기대: FE `requestJoinRemote` 가 `result` 를 읽어 화면이 갈린다(`store_code_screen.dart:52-62`: notFound → "매장 코드를 찾을 수 없어요", alreadyMember → 그 매장으로 들어감, alreadyPending → 대기 화면).
- 실제: 응답 본문에는 `result` 만 있고 `code`·`message` 가 없다. FE `ApiClient._call` 은 400 이상이면 무조건 `ApiException` 을 던지고(`api_client.dart:122`), message 가 없으니 기본 문구 "요청을 처리하지 못했어요" 가 된다(`api_client.dart:166-171`). `store_code_screen.dart:44-46` 의 catch 가 그 문구만 토스트로 띄우고 끝난다. switch 의 notFound·alreadyMember·alreadyPending 분기는 서버 모드에서 실행되지 않는다.
- 원인: `donBug_BE/.../controller/StoreController.java:89-94` 가 결과를 404/409 로 돌려준다(`api_design.md:342-350` 설계대로). 그런데 FE `app_store.dart:1637` 은 2xx 응답 본문만 읽는다. 어느 한쪽을 맞춰야 한다(BE 가 200 + result 로 주거나, FE 가 404/409 본문을 읽거나).
- 영향: 매장 코드를 잘못 넣은 알바생은 이유 모를 "요청을 처리하지 못했어요" 만 본다. 이미 신청한 매장 코드를 다시 넣으면 대기 화면 대신 오류가 뜬다. 이미 소속된 매장 코드를 넣어도 그 매장으로 들어가지 않는다.

### [낮음] 'sub' 알림의 refId 가 FE 는 대타 요청 id, BE 는 근무 id
- 재현: 사장님이 근무를 만들면(`POST /stores/67/shifts`, staffIds [138]) 알바생 `a25-s7` 의 `/me/state` notifications 에 `{"type":"sub","title":"새 근무가 배정됐어요","refId":"1636"}` 가 생긴다. 1636 은 근무(shift) id 다. "근무가 삭제됐어요"·"근무가 수정됐어요" 도 같다.
- 기대: FE 는 'sub' 알림의 refId 를 대타 요청 id 로 쓴다. 알림 센터가 `store.subById(n.refId)` 로 화면을 고른다(`notification_center_screen.dart:35`). FE 데모 코드도 근무 알림에는 refId 를 넣지 않는다(`app_store.dart:1232`·`:1267`·`:1300-1305`).
- 실제: BE 는 근무 알림의 refId 에 근무 id 를 넣는다(`ShiftService.java:131`·`:198`·`:201`).
- 원인: 위 줄. 근무 id 와 대타 요청 id 는 다른 테이블의 auto_increment 라서 숫자가 겹칠 수 있다.
- 영향: 지금은 대부분 `subById` 가 null 이라 탭해도 아무 일이 없다. 근무 id 와 같은 번호의 대타 요청이 그 사용자 상태에 있으면, "새 근무가 배정됐어요" 를 탭했을 때 상관없는 대타 화면이 열린다. 이 QA DB 에서는 번호가 겹치는 경우를 만들 수 없어 실제로 재현하지는 못했다.

### [낮음] 작성 중(draft)인 달에 근무를 넣어도 알바생에게 "새 근무가 배정됐어요" 알림이 간다
- 재현:
  ```sh
  POST /api/v1/stores/67/schedules {"month":"2027-01","prefillFixed":true}    # draft. 이때는 알림이 없다(unread 12→12)
  POST /api/v1/stores/67/shifts {"date":"2027-01-06","startMin":600,"endMin":900,"part":"미들","staffIds":[138],"kind":"work","timeTbd":false}
  GET  /api/v1/me/state  (a25-s7)
  ```
- 기대: 확정 전 근무는 알바생에게 숨기므로(`/me/state` shifts 에 2027-01 없음), 알림도 확정 때 한 번만 간다(고정 근무 채우기는 실제로 알림을 안 보낸다).
- 실제: unread 12→13. "새 근무가 배정됐어요 1/6 10:00–15:00" 가 오는데, 알바생 근무표에는 그 근무가 없다.
- 원인: `ShiftService.java:130` 이 달 상태를 보지 않고 `w == 0 && s.isWork()` 이면 보낸다. PATCH 쪽 알림(`:197-201`)도 같다.
- 영향: 알바생이 알림을 보고 근무표를 열어도 근무가 없어 헷갈린다. 사장님이 초안을 고치는 동안 알림이 여러 번 갈 수 있다.

### [낮음] 예전 확정 API `POST /schedule/confirm` 이 달 상태는 그대로 두고 "N월 근무표가 확정됐어요" 알림만 보낸다
- 재현: 2026-12 가 draft 일 때 `POST /api/v1/stores/67/schedule/confirm {"year":2026,"month":12}` → 204. 사장님 state 의 schedules 에서 2026-12 는 여전히 `draft`, 알바생 `a25-s1` shifts 에 12월이 없다. 그런데 알바생 9명 모두에게 "12월 근무표가 확정됐어요" 알림이 간다. 나중에 `POST /schedules/2026-12/confirm` 으로 진짜 확정하면 같은 알림이 한 번 더 간다.
- 기대: 확정 알림은 실제로 확정할 때 한 번만 간다.
- 원인: `ShiftService.java:418-433` 이 `MonthSchedule` 상태를 바꾸지 않는다. 이미 CONFIRMED 일 때만 건너뛴다.
- 영향: FE 에서 이 API 를 부르는 `AppStore.confirmSchedule`(`app_store.dart:1380-1388`)을 쓰는 화면은 지금 없다. 그래서 사용자 영향은 이 API 를 직접 부를 때만 생긴다. 남겨 둘 거면 `confirmMonth` 와 같은 동작으로 맞추고, 아니면 FE·BE 둘 다에서 지우는 편이 낫다.

### [낮음] BE 급여 API(`/payslips`·`/labor-cost`) 결과가 FE 가 화면에 보이는 계산과 다르다
- 재현: `GET /api/v1/stores/67/staff/132/payslips/2026-11` → `weeklyHoliday 83248`, `GET .../staff/133/payslips/2026-11` → `gross 341000`.
- 기대(FE `app_store.dart:543` `payslip()` 규칙):
  - 132(계약 주 25시간): 11/2주는 개근이라 25h → 51,600원. 11/9주는 11/13 결근이라 0원. 11/16주는 아직 안 끝나서 0원. 합계 51,600원.
  - 133: 11/10 부터 시급 11,000원(계약서로 생긴 시급 이력 `wages`). 11/2·4·6 은 10,320원으로 계산.
- 실제: BE 는 그 주 실제 근무 분만 보고(결근·계약 소정시간·주가 끝났는지 안 봄) 11/2주 46,096 + 11/9주 37,152 = 83,248원을 준다. 133 은 모든 날을 현재 시급 11,000원으로 계산한다.
- 원인: `PayrollCalculator.java:61`(`int wage = sw.getHourlyWage()` 한 값만 씀), `:123-140`(주휴에 결근·계약서·주 종료 조건 없음).
- 영향: FE 는 이 두 API 를 부르지 않고 `/me/state` 로 직접 계산한다. 그래서 지금 화면 숫자는 FE 계산 그대로다. 하지만 API 로 급여를 받는 쪽(정산 확정·PDF 등 "추후" 기능, 외부 연동)은 다른 금액을 받게 된다. 자세한 급여 검증은 18번 영역.

## FE ↔ BE 호출 전수 대조

FE 호출 위치 → BE 엔드포인트. "확인" = FE 본문 그대로 실제 요청해서 2xx 와 state 반영을 봤다.

| FE (파일:줄) | 요청 | 결과 |
|---|---|---|
| app_store 200/206 reload | GET /me/state[?storeId] | 확인. 퇴사한 매장 storeId → 403, FE 가 storeId 없이 다시 읽음 |
| app_store 249 createStoreRemote | POST /stores {name,address,isSmall,defaultDeduction} | 확인 (201, 기본 파트 3개) |
| app_store 1973 createStore(데모용, 서버 모드 화면은 안 씀) | PATCH /stores/{id} | 확인 (isSmall 을 보내면 sizeMode 가 over5/under5 로 바뀜) |
| app_store 1991 updateStore | PATCH /settings {isSmall?,noticeRequiredDefault?,substitutePush?} | 확인 |
| app_store 2025 updateStoreSettings | PATCH /settings {name,openMin..,sizeMode,defaultDeduction} | 확인 |
| app_store 2071 saveParts | PUT /parts {parts:[{id?,name,tone,startMin,endMin,breakMin,need}]} | 확인 (id 숫자·새 파트 id 없음). 응답·state 는 startMin 순으로 정렬됨 |
| app_store 1637 requestJoinRemote | POST /stores/join-requests {code} | 201 확인. 404/409 는 **발견 [중간]** |
| app_store 1666/1677 approve/reject | POST /staff/{id}/approve {wage,deduction?} · /reject | 확인. 두 번 승인 → 409 NOT_PENDING |
| app_store 1705 updateStaff | PATCH /staff/{id} (wage,deduction,weeklyHolidayAuto,premium,part,kind,fixedParts,workHours[],availHours[] null 섞임) | 확인 |
| app_store 1740 removeStaff | DELETE /staff/{id} | 확인 |
| app_store 1921 requestCertRenewal | POST /staff/{id}/cert-renewal-requests | 확인 (204, 알바생 알림) |
| app_store 1870 uploadHealthCertRemote | PUT /me/health-cert multipart(expiry, alertDays "30,7", photo) | 확인 (PNG 바이트 + .jpg 파일명도 받음) |
| app_store 1880 uploadSignatureRemote | POST /me/signatures multipart(image) | 확인 → signatureUrl |
| app_store 1897/1936 createContract(Remote) | PUT /staff/{id}/contract {start,end,wage,weeklyHours,workDays,duty,ownerSignatureUrl?} | 확인 (duty "" 허용, 시급 이력 생김) |
| app_store 1889/1953 signContract(Remote) | POST /staff/{id}/contract/sign {signatureUrl} | 확인. 두 번째 → 409 ALREADY_SIGNED |
| app_store 1911 staffCertPhotoUrl | GET /staff/{id}/health-cert/photo | 확인 (사장님 200, 다른 알바 403) |
| (state 의 서명 이미지) | GET /staff/{id}/contract/signature/{owner\|employee} | 확인 (사장님·본인 200, 다른 알바 403) |
| app_store 1143 saveSchedule | PUT /schedules/{month}/shifts {shifts:[{id?(int),staffId,date,startMin,endMin,part,breakMin,kind,timeTbd}]} | 확인 (int id → String 필드 받음, 기존 근무는 id 유지한 채 수정, 빠진 근무 삭제, 새 근무 추가, off·timeTbd 저장) |
| app_store 1240 addShift | POST /shifts {date,startMin,endMin,part,staffIds,breakMin?,repeatWeeks?,kind,timeTbd} | 확인. endMin 1440 은 **발견 [높음]** |
| app_store 1310 updateShift | PATCH /shifts/{id} | 확인 (TBD 해결). endMin 1440 은 **발견 [높음]** |
| app_store 1270 deleteShift | DELETE /shifts/{id} | 확인 (진행 중 대타 요청도 같이 사라짐) |
| app_store 1376 autoFill (부르는 화면 없음) | POST /schedule/auto-fill {weekMonday} | 경로·본문 맞음 (200 {"added":30}) |
| app_store 1387 confirmSchedule (부르는 화면 없음) | POST /schedule/confirm {year,month} | 경로·본문 맞음. 동작은 **발견 [낮음]** |
| app_store 1556/1558 applySchedulePlan (부르는 화면 없음) | POST /schedule-plans {from,to,needs,copyLastWeek} → /{planId}/apply {needs} | 경로·본문 맞음 |
| app_store 1596 applyTemplate | POST /schedule/template {needs,copyLastWeek} | 확인 |
| app_store 2173 createMonthSchedule | POST /schedules {month,prefillFixed} | 확인 |
| app_store 2188 autofillMonth | POST /schedules/{month}/autofill | 확정된 달 → 409 (FE 는 초안 모드에서는 로컬로 처리) |
| app_store 2207/2235 previewGenerate/applyGenerated | POST /schedules/generate/preview·apply | 경로·DTO 만 대조 (외부 LLM 호출은 10번 영역 몫) |
| app_store 2252 confirmMonth | POST /schedules/{month}/confirm | 확인. 시간 미정 있으면 409 TBD_REMAINING (FE 기대와 같음) |
| app_store 2271 deleteMonthSchedule | DELETE /schedules/{month} | 확인 |
| app_store 2286/2303/2319 템플릿 | POST /schedule-templates {name,month} · /{id}/apply {month} · DELETE | 확인 (이모지 이름, source=template·aiComment) |
| app_store 765 clockInRemote | POST /shifts/{id}/clock-in {qrToken} | 확인. 틀린 토큰 400 INVALID_QR, 남의 근무 403, 두 번째 출근은 같은 기록 200 |
| web_pos_qr_screen 70 | GET /stores/{id}/qr-token | 확인. 알바생 403 |
| app_store 792 clockOut | POST /attendance/clock-out | 아래 "자정 넘긴 퇴근" 참고 |
| app_store 805/827 editAttendance·saveAttendanceRemote | PATCH /attendance/{id} {clockIn,clockOut?,reason} | 확인 (지각 → 정상, 알바생에게 "근태 기록이 수정됐어요") |
| app_store 830/852 createAttendance | POST /shifts/{id}/attendance {clockIn,clockOut?,reason} | 확인 (지난 근무 30건) |
| app_store 882/901 대타 요청 | POST /shifts/{id}/substitute-requests {reason,notifyPeers} | 확인. 중복 409 ALREADY_REQUESTED |
| app_store 924/967 apply · 930/999 cancel · 936/1016 approve · 1029 reject · 1038 resend · 1054 assign {staffId} | POST /substitute-requests/{id}/... | 모두 확인 (겹치는 지원자 409 SHIFT_OVERLAP, 끝난 요청 409 INVALID_STATE, 알바생 approve 403) |
| app_store 1765/1783 공지 | POST /notices {title,body,category:"일반",required?} | 확인 (한글 category, 이모지·줄바꿈, 알바생 403) |
| app_store 1815/1826/1843 | POST /notices/{id}/read · /read-all · /{id}/remind | 확인 (remind {"sent":7}) |
| app_store 671/680 | POST /me/notifications/{id}/read · /read-all?storeId= | 확인 (남의 알림 403) |
| main.dart 67 | GET /me/changes?since= | 확인 ({seq,changed}) |
| ai_api 17 | POST /stores/{id}/ai/labor-questions {question} | 503 AI_DISABLED (키 없는 환경, 예상대로) |
| mobile_boot 103 · api_client 76/159 | POST /api/auth/kakao/token · /logout · /refresh | 경로·본문만 대조 (01번 영역 전용 계정이라 호출 안 함) |

BE 에는 있지만 FE 가 안 부르는 것: GET `/shifts`·`/shifts/{id}`·`/staff`·`/staff/{id}`·`/attendance`·`/attendance/{id}`·`/notices`·`/notices/{id}`·`/notices/{id}/read-status`·`/me/notifications`·`/me/today`·`/stores/{id}`·`/stores/{id}/code`·`/dashboard`·`/payslips`·`/labor-cost`·`/labor-cost/trend`·`/schedule/tbd-count`, PUT `/parts/needs`, GET `/api/v1/me`. FE 는 화면을 `/me/state` 하나로 그린다.

## 통과한 케이스
- 매장 만들기: FE 본문 201, 코드 `XXXX-XXXX`, 기본 파트 3개, 사장님 state role=employer·ownerStoreId
- 매장 설정: 영업시간·sizeMode auto·이름 변경, auto 일 때 재직 9명이면 isSmall=false
- 파트 저장: 기존 3개 수정 + 새 파트 추가(id 없음), need 반영
- 가입 신청: `MQV2-ZE39`·`mqv2ze39`·` MQV2ZE39 ` 모두 같은 매장으로 받음. 9명 신청 → 사장님에게 가입 알림 9건(refId=staff id)
- 승인 전 알바생 state: role employee, employeeStoreId 설정, 매장 code 빈 문자열(가림), 근무 0건
- 승인: 시급·공제 반영, 승인 알림 "…가입이 승인됐어요 / 시급 10,320원", 두 번 승인 409
- 알바생 state 에서 다른 직원 시급 0 으로 가림
- 직원 설정: manager + workHours, fixedParts 요일별, availHours(null 섞임), premium, 시급 변경 → wages 이력
- 계약서: 사장님 서명 업로드 → 작성 → 알바생 "서명 요청" 알림 → 알바생 서명 → signed=true, 사장님 "서명했어요" 알림
- 계약서 시급(11,000원)이 직원 시급과 이력(from=계약 시작일)에 반영됨
- 보건증: 등록 → certExpiry·certAlertDays·certHasPhoto·certDaysLeft, 사장님에게 "보건증을 갱신했어요" 알림, 본인·사장님 사진 200, 다른 알바 403
- 월 근무표 만들기 + 고정 근무 채우기: 오늘(11/17)부터만, 주말 영업시간으로 잘림, 12/25 공휴일은 주말 시간, 매니저는 "직원" 파트 9–18
- draft 인 달은 알바생 state 에 근무가 안 보임, 확정하면 보임 + "N월 근무표가 확정됐어요" 알림
- 시간 미정이 있으면 확정 409, 미정 해결(PATCH) 뒤 확정 204
- 월 전체 저장: 수정·삭제·추가·휴무·미정 섞어서 skipped=[]
- 지난 날짜 근무 생성(repeatWeeks 2) 17건 201
- 사장님 수기 출퇴근 30건: 지각 10분 → status late·lateMinutes 10, 연장 23:30 → overtimeMinutes 30, 휴게 차감 workedMinutes
- QR 출근: 사장님 토큰 → 알바생 출근 200, lateMinutes 계산, `/me/today` 의 todayShift·openAttendance, 양쪽 state attendance 반영
- 대타 1: 요청 → 동료 알림(notifyPeers) + 사장님 알림 → 지원 2명(첫 지원자가 accepted) → 승인 → 근무 담당자 변경·isSubstitute·originalStaffId → 요청자·대타자 알림
- 대타 2: notifyPeers=false 면 동료 알림 없음, 사장님 assign → 바로 approved·근무 변경
- 대타 3: 거절 → 요청자 "거절됐어요" 알림, 거절 뒤 resend 409
- `?mine=true`·`?available=true` 목록
- 수락자가 퇴사하면 요청이 open·acceptedId null 로 돌아감(FE 데모 로직과 같음), 사장님 assign 으로 해결
- 공지: 필독 기본값 적용, 읽음·두 번 읽음·모두 읽음, read-status 의 읽음/안 읽음 나눔, remind → 안 읽은 7명 알림, 알바생 state readBy 에 본인 것만
- 알림 읽음·모두 읽음 → unread-count 0
- 퇴사: status left·leftAt, 오늘 이후 근무 삭제, 퇴사자 state 에 매장·근무·공지 없음, 공지 API 403, 퇴사 알림. 재신청 → 새 pending 행 → 거절
- 템플릿 저장·적용(draft 달, source=template)·삭제, 달 삭제
- 급여 명세: 사장님 200, 본인 200, 다른 알바 403. labor-cost 합계 = 직원별 gross 합

## 못 한 것
- AI 근무표 생성(preview·apply): 외부 LLM 호출이라 10번 영역에만 허용. DTO·경로만 대조했다.
- 실제 카카오 로그인·refresh·logout: 01번 영역 전용. 경로·본문만 대조했다.
- 웹 화면 렌더링: 웹 컨테이너가 없어서 FE 가 `/me/state` 를 파싱하는지는 키 이름·값 모양을 `models.dart` 와 눈으로 맞춰 보는 데서 그쳤다(필드 단위 대조는 20번 영역).
- 사장님이 다른 매장 알바생이기도 한 경우, 한 사장님의 여러 매장 전환: 02·20번 영역 범위라 이 시나리오에서는 하지 않았다.
- BE 급여 계산은 FE 계산과 다른 점 하나만 짚었다. 가산·공제 전체 검증은 18번 영역.
