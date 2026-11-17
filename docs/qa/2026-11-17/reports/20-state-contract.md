# 20 state-contract QA 보고서

## 요약

- 실행한 케이스: 46 (상태 스냅샷 13종 × 실제 FE `fromJson` 파싱 + 주요 셸 렌더링 14종 + 경계값·권한·`storeId` 쿼리 19건)
- 통과: 41
- 발견: 5건 — 치명 0 · 높음 1 · 중간 1 · 낮음 3

검증 방법
- 로컬 BE 에 데이터를 실제로 만들었다. 매장 3개(64 `A20 카페 ☕`, 65 `A20 겸업가게`, 82 `A20 널가게`)에 다음을 넣었다.
  - 직원: 매니저·알바·정직원·연소자 / 대기·승인·거절·퇴사 상태
  - 근무: 근무·연차·휴무·시간 미정·자정 넘김
  - 출근: 수동 기록, QR 출근 후 근무 중, 과거 기록
  - 대타: open·accepted·approved·rejected·cancelled
  - 그 밖: 공지 3종(읽음 포함), 알림, 월 근무표(draft·confirmed), 템플릿 2개, 계약서(양쪽 서명·사장님만 서명), 보건증 사진
- 사용자 13명의 `/me/state` 를 저장했다. 사장님, 매니저, 알바 2명, 대기, 퇴사, 거절, 사장님+알바 겸업(`?storeId=` 64·65), 무소속, 두 번째 사장님·직원이다.
- 저장한 JSON 을 **실제 FE 코드**로 검사했다.
  - 스크래치 Flutter 패키지가 `donbug` 를 path 의존성으로 가져온다. FE 레포는 바꾸지 않았다.
  - 각 행을 `fromJson` 으로 파싱하고, `toJson` + `jsonEncode` 로 lazy cast 를 강제로 평가했다.
  - `AppState.fromJson` 전체 파싱과 시각 필드 `DateTime.parse` 를 확인했다.
  - 역할에 맞는 `EmployeeShell` / `EmployerShell` / `WebShell` 을 위젯 테스트로 렌더링했다.
- 필드 단위 대조용 파이썬 검사기도 함께 썼다. 키, null, id 문자열, enum `.name`, 날짜 형식, 참조 무결성을 본다.
  - 위치: `/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/cea240a3-8caa-4866-90f7-9548b0c17c99/scratchpad/a20/check.py`
  - 하네스: 같은 폴더의 `harness/test/*.dart`

## 발견

### [높음] 이번 달에 "작성 중" 근무표를 만들면 알바생 앱에서 그 달의 근무·출근 기록·대타가 모두 사라짐 (근무 중인 직원은 퇴근 버튼도 사라짐)

- 재현
  ```sh
  O=$(qa-user a20-owner); M=$(qa-user a20-mgr)
  # 1) 이번 달 오늘 근무를 만들고 (월 근무표 메타가 아직 없는 상태) 매니저가 QR 출근
  curl -X POST $B/stores/64/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2026-11-17","startMin":1380,"endMin":120,"part":"직원","staffIds":[105],"kind":"work","timeTbd":false}'   # → 520
  QT=$(curl -s $B/stores/64/qr-token -H "Authorization: Bearer $O" | jq -r .token)
  curl -X POST $B/stores/64/shifts/520/clock-in -H "Authorization: Bearer $M" -H 'Content-Type: application/json' -d "{\"qrToken\":\"$QT\"}"  # 200, working
  # 2) 사장님이 웹 "근무표 만들기 → 직접 만들기"로 이번 달 근무표를 만든다 (draft)
  curl -X POST $B/stores/64/schedules -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"month":"2026-11","prefillFixed":false}'
  # 3) 매니저 상태
  curl $B/me/state -H "Authorization: Bearer $M"   # shifts 에 11월 근무 0건, attendance 0건
  curl $B/me/today -H "Authorization: Bearer $M"   # todayShift 520, working:true, openAttendance 47
  ```
- 기대
  - 이미 직원에게 보이던(알림까지 간) 이번 달 근무, 진행 중인 출근 기록, 그 근무의 대타 요청은 계속 보여야 한다.
  - 최소한 출근 기록과 대타는 근무표 공개 여부와 무관하게 본인에게 보여야 한다.
- 실제
  - 사장님이 2026-11 draft 를 만든 순간부터 직원 `/me/state` 가 바뀐다.
    - `shifts` 에서 11월 전체가 빠진다.
    - `attendance` 가 0건이 된다. 근무 중인 attendance 47 도 빠진다.
    - 11월 근무에 걸린 `subs` 도 빠진다. 알바일의 open/accepted 대타 15 가 없어진다.
  - 같은 사용자의 `/me/today` 와 `GET /stores/64/shifts` 는 그 근무를 그대로 돌려준다. API 사이에서 결과가 다르다.
  - draft 달에 근무를 새로 넣어도 직원에게 "새 근무가 배정됐어요" 알림이 간다. 그런데 직원은 그 근무를 볼 수 없다.
    - 재현: 알림 1309 의 refId 1641. 이 근무는 직원 state 에 없다.
- 원인
  - `StateService.java:145-149`: 직원이면 DRAFT 메타가 있는 달의 근무를 통째로 뺀다.
  - `StateService.java:151-157`: 출근 기록을 거른 근무 목록으로만 모은다.
  - `StateService.java:161-164`: 대타도 거른 근무 목록으로만 모은다.
  - `MonthScheduleService.java:107-123` (`create`): 이미 근무가 있는 이번 달에도 바로 DRAFT 메타를 만든다.
  - `ShiftService.java:131`: draft 달에도 배정 알림을 보낸다.
- 영향
  - FE `AppStore.myOpenAttendance`(`app_store.dart:405`) 는 state 의 attendance 로 근무 중인지 판단한다. 그래서 근무 중인 직원의 홈에서 "근무 중" 카드와 퇴근 버튼이 사라진다.
  - 직원의 오늘 근무, 이번 달 근무표, 급여 예상(state 의 근무·출근으로 계산), 진행 중인 대타 요청이 사장님이 확정할 때까지 보이지 않는다.
  - 모바일 사장님 화면은 예전 API(즉시 저장)로 근무를 만든다. 그 뒤 웹에서 이번 달 근무표를 "직접 만들기" 하는 흐름에서 그대로 발생한다.

### [중간] 퇴사한 동료와 같은 시간의 지난 근무를 알바생이 열면 근무 상세 화면이 죽음 (state 참조 무결성 깨짐)

- 재현
  ```sh
  O=$(qa-user a20-owner); G=$(qa-user a20-gone)
  curl -X POST $B/stores/join-requests -H "Authorization: Bearer $G" -d '{"code":"AKXP-2SXT"}' -H 'Content-Type: application/json'   # staff 166
  curl -X POST $B/stores/64/staff/166/approve -H "Authorization: Bearer $O" -H 'Content-Type: application/json' -d '{"wage":11000}'
  curl -X POST $B/stores/64/shifts -H "Authorization: Bearer $O" -H 'Content-Type: application/json' \
    -d '{"date":"2026-10-20","startMin":600,"endMin":900,"part":"미들","staffIds":[106,166],"kind":"work","timeTbd":false}'  # 1124(알바일), 1125(gone)
  curl -X DELETE $B/stores/64/staff/166 -H "Authorization: Bearer $O"   # 204 퇴사 (지난 근무는 남음)
  curl $B/me/state -H "Authorization: Bearer $(qa-user a20-s1)"
  ```
  - 위 state 로 FE `ShiftDetailScreen(shiftId: '1124')` 를 렌더링했다(하네스 `screens_test.dart`). 결과는 다음과 같다.
    `Null check operator used on a null value` / `#0 ShiftDetailScreen.build (package:donbug/screens/employee/shift_detail_screen.dart:56:62)`
- 기대: 직원 state 에 근무(`shifts`)가 있으면 그 `staffId` 의 Staff 행도 있어야 한다(퇴사자는 status `left` 로). 아니면 그 근무를 빼야 한다.
- 실제
  - 알바일 state 의 `shifts` 에 staffId `166` 근무가 있다. 그런데 `staff` 에는 166 이 없다.
  - approved 대타 33 의 `requesterId` `166` 도 `staff` 에 없다.
  - 같은 state 로 `SubstituteDetailScreen('33')` 를 열면 `substitute_detail_screen.dart:80` 에서 같은 예외가 난다. 다만 알림·목록에서는 open 이 아닌 요청을 이 화면으로 보내지 않는다. 그래서 정상 경로로는 근무 상세만 확인됐다.
- 원인
  - `StateService.java:134-136`: 직원에게는 ACTIVE 가 아닌 다른 직원 행(퇴사·대기)을 주지 않는다.
  - `StateService.java:150`: 그 직원들의 근무는 그대로 넣는다.
  - FE `shift_detail_screen.dart:56` 는 `store.staffById(c.staffId)!` 로 같은 시간 근무자의 Staff 를 강제로 꺼낸다.
- 영향: 알바생이 근무표에서 퇴사한 동료와 겹치는 지난 근무를 누르면 화면이 오류로 바뀐다. 릴리스 빌드에서는 회색 화면이 된다. 퇴사가 있는 매장이면 지난달~이번 달 범위에서 흔히 생긴다.

### [낮음] 알바생에게 동료의 보건증 만료일·사진 유무·알림 설정이 내려감

- 재현: 위 데이터에서 `curl $B/me/state -H "Authorization: Bearer $(qa-user a20-s2)"` 를 실행한다. `persons` 의 알바일(401) 행이 `"certExpiry":"2026-12-01","certHasPhoto":true,"certAlertDays":[30,7,0]` 이다.
- 기대
  - 직원에게는 다른 직원의 시급·계약서·연락처를 주지 않는다(`StateService.java:138` 주석, `AppStateDto.Person` 주석). 보건증 정보도 본인과 사장님에게만 주는 것이 일관된다.
  - FE 알바생 화면은 `me` 의 보건증만 쓴다(`my_documents_screen.dart:35`).
- 실제: 같은 매장의 모든 사람의 보건증 만료일·사진 등록 여부·알림 일수가 그대로 나온다.
- 원인: `AppStateDto.java` `Person.from` 은 보는 사람과 관계없이 cert 필드를 채운다. `StateService.java:140` 이 직원 시점에서도 이 값을 그대로 넣는다.
- 영향: 개인 건강 서류 관련 정보가 동료에게 노출된다. 실제 화면에는 안 보이지만 응답에는 들어 있다.

### [낮음] "새 근무가 배정됐어요" 알림이 type `sub` 인데 refId 는 근무(shift) id

- 재현: 위 draft 재현의 3)에서 직원 알림 `{"type":"sub","title":"새 근무가 배정됐어요","refId":"1641"}` 를 본다. 1641 은 shift id 다.
- 기대: FE 계약에서 `type: sub` 의 refId 는 대타 요청 id 다. FE `notification_center_screen.dart:34-39` 는 `subById(n.refId)` 로 찾는다.
- 실제
  - shift id 가 들어간다. 지금은 같은 id 의 대타가 없어서 `null` → 이동 없음으로 끝난다.
  - shift 와 대타 요청의 id 는 서로 다른 테이블 순번이다. 그래서 같은 숫자가 생기면 엉뚱한 대타 요청 화면이 열린다. id 충돌 자체는 재현하지 않았다.
- 원인: `ShiftService.java:131`, `ShiftService.java:201` 의 `notifier.sendToStaff(store, sw, Notification.Type.SUB, "새 근무가 배정됐어요", ..., s.getId())`.
- 영향: 근무 배정 알림을 눌러도 근무로 가지 않는다. 드물게 다른 대타 요청이 열린다.

### [낮음] `/me/state?storeId=` 형식 오류 400 응답이 FE `ApiException` 모양(`code`·`message`)이 아님

- 재현: `curl "$B/me/state?storeId=abc" -H "Authorization: Bearer $(qa-user a20-owner)"` 를 실행한다. `1e3`, `64.0`, `9999999999999` 도 같다.
- 기대: `{"code":...,"message":...}`
- 실제: `400 {"timestamp":...,"status":400,"error":"Bad Request","path":"/api/v1/me/state"}` 이다(Spring 기본 응답).
- 원인: 타입 변환 실패(`MethodArgumentTypeMismatchException`)를 전역 예외 처리기가 잡지 않는다.
- 영향
  - FE `reload` 는 4xx 면 storeId 없이 다시 읽는다(`app_store.dart:202-207`). 그래서 동작에는 문제가 없다.
  - 다만 같은 응답 모양 문제가 다른 쿼리 파라미터에도 있을 수 있다(23 robustness 영역).

## 통과한 케이스

파싱·렌더링
- 13개 `/me/state` 스냅샷이 모두 실제 FE `AppState.fromJson` 으로 null 없이 파싱됐다. 행 단위 파싱 실패 0, lazy cast(`certAlertDays`, `monthlyTotals`, `applicantIds`, `readBy`) 실패 0.
  - 사장님, 매니저, 알바 2명, 대기, 퇴사, 거절, 겸업 기본·64·65, 무소속, 사장님2, 직원2
- 매장이 있는 9개 상태로 `EmployeeShell` / `EmployerShell` / `WebShell`(1440) 을 렌더링했다. 예외 0.

최상위·세션
- `v` 는 4 로 FE `AppState.version` 과 같다. `nextId` 는 int.
- `session` 의 네 id 는 매장이 없으면 `""` 이고 null 이 아니다. role 은 `employee`/`employer`.
- 겸업 사용자
  - 기본은 role `employer`, ownerStoreId 65, employeeStoreId 64 다.
  - `?storeId=64` 면 employee 로, `?storeId=65` 면 employer 로 바뀐다.
  - stores 에 두 매장이 한 번씩만 있다.

id·enum·날짜 형식
- 모든 `id`/`*Id`/`applicantIds` 는 숫자 문자열이다. `nextId` 만 숫자로 남는다(`FeIdJsonModule`).
- enum 은 모두 Dart `.name` 이다.
  - Deduction: biz33·insurance·none
  - StaffStatus: pending·active·left·rejected
  - StaffKind: manager·fulltime·partTimer·minor
  - ShiftKind: work·leave·off
  - SubStatus: 5종 모두 생성해 확인
  - ScheduleStatus: draft·confirmed
  - ScheduleSource: manual
  - SizeMode: auto·under5·over5
  - PartTone: open·middle·close
  - Notification type: sub·notice·cert·join·contract
  - 엔티티 enum 의 `EnumJson.camel` 매핑을 코드로도 대조했다.
- 날짜 형식
  - `yyyy-MM-dd`: joinedAt, leftAt, date, certExpiry, contract start/end, wages.from
  - `yyyy-MM`: month
  - ISO(소수 초 최대 9자리, 오프셋 없음): 그 밖의 시각 필드. Dart `DateTime.parse` 로 모두 파싱됐다.
  - 서버 TZ 는 Asia/Seoul 이라 로컬 시각과 일치한다.

null 처리
- `contract` null 과 객체 모두 정상. 양쪽 서명, 사장님만 서명을 확인했다.
- `workHours` null(알바)은 FE 기본 7칸으로 처리된다. `fixedParts`/`availHours` 는 7칸.
- 시간 미정·연차·휴무 근무의 `breakMin`·`part` 는 null 이 아니다. part 를 빼고 만든 근무는 `""` 로 나온다.
- 알림 `body` null 은 FE `?? ''` 로 처리된다. `refId`·`acceptedId`·`originalStaffId`·`remindedAt`·`scheduleConfirmedAt` 은 null 이 허용된다.

직원 시점 숨김
- 직원 시점에서 다른 직원은 `wage: 0`, `deduction: null`, `contract: null`, `wages: []` 로 숨겨진다. deduction null 은 FE 에서 biz33 fallback 이다.
- 대기 직원 state: 매장 1개(code `""`)와 본인 Staff 행만 있다. shifts·notices 는 비어 있다.
- 퇴사·거절 사용자: stores·staff 가 비어 있고 지난 알림만 남는다. 앱은 역할 선택 화면으로 간다.

경계값 입력
- 한글·이모지·HTML·따옴표·줄바꿈이 매장 이름·주소·공지·대타 사유·템플릿 이름에 그대로 왕복된다.
- 매장 만들기 주소 누락·null·`""` → 400 `VALIDATION_FAILED`(null 이 state 로 새지 않음). `PATCH /stores` 주소 `""` → 400.
- 근무 `part`/`kind`/`timeTbd`/`breakMin` null → 기본값(`""`/work/false/자동)으로 저장되고 state 에 null 이 없다.
- 직원 PATCH `fixedParts` 7칸 아님 → 400. 계약서 `workDays` null·`weeklyHours` 0 → 400.

`?storeId=` 처리
- `-1`·`0`·`99999999`·남의 매장 → 403 `FORBIDDEN`. FE 는 storeId 없이 다시 읽는다.
- 빈 값 → 기본 매장. 중복 파라미터는 첫 값을 쓴다.
- 퇴사·거절 사용자의 `?storeId=64` → 403.

인증·`GET /me`
- 인증 없음·변조 토큰 → 401.
- `GET /me` 는 FE 가 호출하지 않는다(`grep` 결과 `/me/state`, `/me/changes` 만 씀). 응답 모양(person·ownedStoreIds·memberships)은 정상이고 id 는 문자열이다.

## 못 한 것

- AI 생성 근무표(source `ai`, `weeklyHolidayPay: allow`, `priority: cost`): 외부 LLM 호출은 10번 에이전트 전용이라 만들지 않았다. enum 직렬화는 코드(`MonthSchedule.java:22-61`, `EnumJson.camel`)로만 확인했다.
- `type: pay` 알림: 근태 수정 경로로 만들 수 있지만 시간이 부족해 state 에서 확인하지 않았다. 같은 DTO 경로라 형식 위험은 낮다.
- 범위 밖(지난달 1일이 든 주 이전, 3개월 뒤 이후) 근무에 걸린 출근·대타가 빠지는 경계: `StateService.java:124-125` 로 코드만 봤다.
- 실제 앱 화면은 위젯 테스트 렌더링으로만 봤고 기기·브라우저에서는 보지 않았다. 셸 첫 화면만 렌더링했고 모든 하위 화면을 열어 보지는 않았다. 근무 상세·대타 상세·대타 현황만 따로 열었다.
- 참고: FE 레포에 `lib/length`(23:03 생성, 9바이트, untracked) 파일이 있다. 이 에이전트가 만든 것이 아니며 건드리지 않았다.
