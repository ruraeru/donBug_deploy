# 13 substitute QA 보고서

## 요약

- 실행한 케이스: 88개 (생성 9, 목록 11, 지원 10, 재알림 4, 승인·거절·취소 상태 전이 20, 직접 배정 12, 퇴사·근무 변경·월 저장 연동 10, 지난·야간·비근무 근무 9, 동시 요청 3)
- 통과: 79
- 발견: 9건 — 치명 0, 높음 1, 중간 2, 낮음 6

테스트 환경: 매장 23 `a13 대타매장`(사장님 `a13-owner`), 알바 `a13-staff1`~`a13-staff5`(staff id 35·36·37·39·41), 가입 대기 `a13-staff6`(146), 비교용 매장 78(`a13-ownerB`, 알바 `a13-bstaff` = staff 147), 외부인 `a13-outsider`. 테스트 시각은 2026-11-17 23:0x KST.

아래 재현 코드는 다음 헬퍼를 쓴다.

```sh
QA=/private/tmp/claude-501/-Users-xodn-Documents-donBug-deploy/232e8796-4bb1-4626-bcda-32d8032ea90d/scratchpad/qa
B=http://127.0.0.1:18080/api/v1
req(){ local t=$1 m=$2 p=$3 b=${4:-}; if [ -n "$b" ]; then curl -s -w ' [%{http_code}]\n' -X $m "$B$p" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' -d "$b"; else curl -s -w ' [%{http_code}]\n' -X $m "$B$p" -H "Authorization: Bearer $t"; fi; }
O=$($QA/qa-user a13-owner); T3=$($QA/qa-user a13-staff3); T4=$($QA/qa-user a13-staff4)
```

## 발견

### [높음] 승인과 거절(또는 취소)이 동시에 오면 둘 다 성공하고, "거절됨"인데 근무는 대타에게 넘어간다

- 재현 (서로 다른 날짜로 3번 반복했고 3번 모두 재현됨):
  ```sh
  S=$(req $O POST /stores/23/shifts '{"date":"2026-12-01","startMin":600,"endMin":840,"staffIds":[39]}' | grep -o '"id":"[0-9]*"' | head -1 | tr -dc 0-9)
  R=$(req $T4 POST /stores/23/shifts/$S/substitute-requests '{"reason":"race"}' | grep -o '"id":"[0-9]*"' | head -1 | tr -dc 0-9)
  req $T3 POST /stores/23/substitute-requests/$R/apply
  curl -s -o /dev/null -w 'ap%{http_code} ' -X POST $B/stores/23/substitute-requests/$R/approve -H "Authorization: Bearer $O" &
  curl -s -o /dev/null -w 'rj%{http_code} ' -X POST $B/stores/23/substitute-requests/$R/reject  -H "Authorization: Bearer $O" & wait
  $QA/qa-sql "SELECT r.status, s.mapping_id, s.is_substitute+0 FROM substitute_request r JOIN schedule s ON s.schedule_id=r.schedule_id WHERE r.request_id=$R"
  ```
- 기대: 하나만 200, 다른 하나는 409 `INVALID_STATE`. 요청 상태와 근무 담당자가 서로 맞아야 한다.
- 실제: `rj200 ap200`이 3번 모두 나왔다. 최종 상태는 실행마다 다르다.
  - 요청 35·36·37: `APPROVED`. 그런데 요청자는 "대타 요청이 승인됐어요"와 "대타 요청이 거절됐어요"를 둘 다 받았다.
  - approve 5개와 reject 5개를 섞어 보낸 요청 32: 요청은 `REJECTED`인데 근무 1159는 `mapping_id=35`(대타자), `original_mapping_id=39`, `is_substitute=1`로 바뀌었다. 승인 1번, 거절 3번이 모두 200이었다. 요청자는 승인 알림 1개와 거절 알림 3개를, 대타자는 확정 알림 1개와 거절 알림 3개를 받았다.
- 원인: `SubstituteService.java:177-197`(approve/reject)와 `:158`(cancel)이 `requirePending` 으로 상태를 확인한 뒤 바꾼다(check-then-act). 그런데 `SubstituteRequestRepository.findByIdAndStore`에 행 잠금(`@Lock(PESSIMISTIC_WRITE)`)이 없고, `SubstituteRequest` 엔티티에 `@Version`도 없다. 그래서 두 트랜잭션이 모두 OPEN/ACCEPTED 를 읽고, 나중에 커밋한 쪽의 status 가 남는다. 근무 변경(`doApprove`의 `shift.setStoreWorker`)은 status 와 따로 남는다.
- 영향: 사장님이 두 기기에서 누르거나, 요청자가 취소하는 순간 사장님이 승인하는 경우에 생긴다. 그러면 요청은 "거절"·"취소"로 보이는데 근무표에는 대타자가 들어간다. 원래 근무자는 출근해야 한다고 믿고, 대타자도 확정 알림을 받는다. 그 결과 둘 다 오거나 둘 다 안 올 수 있고, 급여는 대타자에게 잡힌다.

### [중간] 월 근무표 저장(PUT)으로 근무의 담당자나 시간이 바뀌어도 진행 중 대타 요청이 남아 있어서, 새 담당자가 대타를 요청할 수 없다

- 재현:
  ```sh
  T2=$($QA/qa-user a13-staff2)
  req $T2 POST /stores/23/shifts/48/substitute-requests '{"reason":"월저장테스트"}'    # → 요청 21
  req $T4 POST /stores/23/substitute-requests/21/apply                                 # accepted
  # 월 저장으로 근무 48의 담당자를 36 → 35 로 바꿈 (그 달 근무 전체 전송)
  req $O PUT /stores/23/schedules/2026-11/shifts '{"shifts":[{"id":"48","staffId":35,"date":"2026-11-20","startMin":720,"endMin":960,"breakMin":30}, ...그 달 나머지 근무... ]}'
  $QA/qa-sql "SELECT status FROM substitute_request WHERE request_id=21"               # ACCEPTED 그대로
  req $($QA/qa-user a13-staff1) POST /stores/23/shifts/48/substitute-requests '{"reason":"내 근무인데"}'
  req $O POST /stores/23/substitute-requests/21/approve
  ```
- 기대: 단건 수정 `PATCH /shifts/{id}`(`ShiftService.java:188-193`)처럼 담당자·날짜·시간·종류가 바뀌면 진행 중 요청을 CANCELLED 로 바꾼다.
- 실제: PUT 은 `{"skipped":[]} 200`이다. 요청 21은 `ACCEPTED`로 남는다. 새 담당자(staff1)가 대타를 요청하면 `409 ALREADY_REQUESTED "이미 진행 중인 대타 요청이 있어요"`가 나온다. 사장님이 승인하면 `409 SHIFT_CHANGED`가 나온다. `/me/state`의 `subs`에도 요청 21이 `accepted`로 계속 나온다. 그래서 FE `pendingSubFor(48)`이 새 담당자의 근무에 "대타 요청 중"을 표시한다(`shift_detail_screen.dart:28`, `employee_parts.dart:123`, `web_schedule_views.dart:56`).
- 원인: `MonthScheduleService.java:179-248`(saveShifts)는 기존 근무의 담당자·날짜·시간·종류를 그대로 덮어쓰는데, 진행 중 대타 요청을 정리하지 않는다. 지울 때는 `ScheduleDeleter`로 정리하지만, 바뀐 근무는 정리하지 않는다. 같은 담당자의 시간만 바뀐 경우에도 요청이 남는다. 이때 지원자는 옛 시간으로 알림을 받고 지원한 상태가 된다.
- 영향: 웹 근무표 편집기(초안 저장 = 이 PUT)로 근무를 옮기면 대타 요청이 고아가 된다. 사장님이 직접 거절하기 전까지 새 담당자는 대타를 구할 수 없다. 화면에는 엉뚱한 "대타 요청 중" 표시가 남는다.

### [중간] 후보(acceptedId)가 퇴사하면 요청이 OPEN 으로 돌아가지만, 남은 지원자는 다시 후보가 될 수 없어서 요청이 막힌다

- 재현:
  ```sh
  T1=$($QA/qa-user a13-staff1); T2=$($QA/qa-user a13-staff2); T5=$($QA/qa-user a13-staff5)
  req $O POST /stores/23/shifts '{"date":"2026-11-22","startMin":600,"endMin":840,"staffIds":[35]}'   # → 근무 693
  req $T1 POST /stores/23/shifts/693/substitute-requests '{"reason":"퇴사테스트"}'                  # → 요청 18
  req $T5 POST /stores/23/substitute-requests/18/apply      # 후보 = 41
  req $T2 POST /stores/23/substitute-requests/18/apply      # applicantIds ["36","41"]
  req $O DELETE /stores/23/staff/41                         # 후보 퇴사
  req $T2 GET "/stores/23/substitute-requests?available=true"   # items: []
  req $T2 POST /stores/23/substitute-requests/18/apply          # 200, 아무것도 바뀌지 않음 (acceptedId null)
  req $O POST /stores/23/substitute-requests/18/approve         # 400 NO_ACCEPTED_APPLICANT
  ```
- 기대: 남은 지원자 중 첫 사람(staff2)이 후보가 되어 ACCEPTED 를 유지한다. 아니면 지원자를 모두 지워 다시 지원할 수 있게 한다.
- 실제: 요청은 `OPEN, taker NULL, applicantIds ["36"]`이 된다. staff2는 "이미 지원함"으로 처리된다. 그래서 `available` 목록에 안 나오고 apply 도 무시된다(`SubstituteService.java:132-135`). 사장님이 승인하면 400이 나온다. 요청자·지원자·사장님 누구에게도 알림이 없다.
- 원인: `StaffService.java:169-174`가 후보만 null 로 되돌리고, 남은 지원자 중에서 다음 후보를 고르지 않는다.
- 영향: 지원자가 있는데도 사장님 화면에는 "아직 수락한 사람이 없어요"가 보인다. 사장님이 직접 배정하지 않으면 대타가 성사되지 않는다. 지원했던 직원은 다시 수락할 방법이 없다.

### [낮음] 대타로 받은 근무에 다시 대타가 승인되면 원래 정규 근무자(originalStaffId)가 덮어써진다

- 재현: 근무 49(원래 staff3=37)를 요청 10으로 staff4(39)에게 배정한다. 이어서 staff4가 같은 근무로 요청 14를 만들고, 사장님이 `assign {"staffId":41}`을 보낸다. 그러면 `schedule 49: mapping_id=41, original_mapping_id=39`가 된다.
- 기대: `original_mapping_id`는 처음 정규 근무자 37로 남는다(필드 뜻이 "대타로 바뀐 근무의 원래 정규 근무자"다).
- 실제: 바로 앞 담당자 39로 바뀐다.
- 원인: `SubstituteService.java:259` `shift.setOriginalStoreWorker(shift.getStoreWorker())`를 조건 없이 실행한다.
- 영향: 지난주 복사(`ShiftService.java:483-486` `regularStaffId`, FE `app_store.dart:1453·1575`)가 다음 주 근무를 원래 정규 근무자가 아닌 중간 대타자에게 배정한다.

### [낮음] 지난(이미 시작한) 근무의 대타 요청도 재알림이 되고, 진행 중으로 계속 남는다

- 재현: 요청 27(근무 1060)이 accepted 상태일 때 `UPDATE schedule SET work_date='2026-11-16' WHERE schedule_id=1060`로 근무를 과거로 옮긴다. 그다음 `req $T4 POST /stores/23/substitute-requests/27/resend`를 보낸다.
- 기대: 지원·승인·배정처럼 `409 SHIFT_STARTED`. 지난 요청은 진행 중 목록에서 빠진다.
- 실제: resend 는 `200`이고, 동료 전원에게 "대타알바4님 대타를 다시 구해요"를 보낸다. 같은 시각에 apply·approve·assign 은 409다. `/me/state`의 `subs`에는 요청 27이 `accepted`로 계속 나온다. FE `pendingSubs`(`app_store.dart:472`)는 시간을 거르지 않는다. 그래서 사장님 대시보드·대타 메뉴 배지(`web_shell.dart:174`)에 지난 요청이 남고, 사장님이 거절해야만 사라진다. 서버 `GET ?status=pending`만 시작 시간으로 거른다(`SubstituteService.java:110`).
- 원인: `SubstituteService.java:200-213` resend 에 `assertNotStarted`가 없다. 시작이 지난 요청을 자동으로 마감하는 처리도 없다.
- 영향: 이미 끝난 근무에 대타를 구하는 알림이 간다. 사장님 화면의 "대타 대기" 수가 실제보다 많다.

### [낮음] 재알림을 이미 지원한 사람과 수락이 끝난(ACCEPTED) 요청에도 보낸다

- 재현: 요청 1이 accepted(지원자 37·39)일 때 요청자와 사장님이 각각 `resend`를 보낸다. 그러면 알림 307~314가 생긴다. 이미 지원한 staff3·staff4를 포함해 동료 4명에게 2번씩 "대타를 다시 구해요"가 간다.
- 기대: 지원자는 빼거나, OPEN 일 때만 재알림한다. 짧은 시간 안의 반복도 막는다.
- 실제: 위와 같고, 횟수 제한도 없다.
- 원인: `SubstituteService.java:208-211` `sendToActiveStaff(store, requesterId, ...)`가 요청자만 뺀다.
- 영향: 알림 스팸이 생긴다. 이미 수락한 직원이 "다시 구한다"는 알림을 받고 혼란스러워한다.

### [낮음] 근무 수정·삭제·퇴사로 대타 요청이 자동 취소·삭제돼도 지원자(후보)에게 알리지 않는다

- 재현:
  1. 요청 18에 staff2가 지원한 상태에서 `PATCH /stores/23/shifts/693 {"startMin":660}`를 보낸다. 요청은 `CANCELLED`가 된다. 알림은 요청자에게 간 "근무가 수정됐어요" 1건뿐이다.
  2. 요청 38(요청자 staff1, 후보 staff3)에서 `DELETE /stores/23/staff/35`를 보낸다. 요청과 지원자 행이 근무와 함께 삭제된다. 알림은 staff1의 퇴사 알림뿐이다.
- 기대: 요청자 본인의 취소(`cancel`)처럼 지원자·사장님에게 "대타 요청이 취소됐어요"를 보낸다.
- 실제: 지원자는 알림을 받지 못한다. 이전에 받은 "수락했어요" 알림의 refId 는 사라진 요청을 가리킨다.
- 원인: `ShiftService.java:188-193`, `ScheduleDeleter.java:26-35`, `StaffService.java:164-175`는 상태만 바꾸거나 행을 지우고, 알림을 보내지 않는다.
- 영향: 후보였던 직원은 대타 근무가 잡힌 줄 알고 기다릴 수 있다.

### [낮음] 사장님용 "수락" 알림 문구에 요청자 이름이 없다 (FE 와 문구 불일치)

- 재현: `req $T3 POST /stores/23/substitute-requests/1/apply`를 보내면 사장님 알림 252가 "대타알바3님이 대타를 수락했어요"로 나온다.
- 기대: FE 데모 로직(`app_store.dart:963-965`)처럼 "대타알바3님이 대타알바1님 대타를 수락했어요".
- 실제: 누구의 대타인지 문구에 없다.
- 원인: `SubstituteService.java:151-153`이 요청자용 제목을 사장님에게도 그대로 쓴다.
- 영향: 진행 중 대타가 여럿이면 사장님이 알림만 보고는 어느 요청인지 알 수 없다.

### [낮음] `available=true` 목록과 지원 대상 표시에 시간이 겹치는 요청이 포함된다

- 재현: staff2(36)는 11/20 12–16에 근무가 있다. staff1이 11/20 10–14 근무로 요청 1을 만든다. 그다음 `req $T2 GET "/stores/23/substitute-requests?available=true"`를 보내면 요청 1이 나온다. 이어서 `req $T2 POST /stores/23/substitute-requests/1/apply`를 보내면 `409 SHIFT_OVERLAP`이 나온다.
- 기대: 지원할 수 없는(겹치는) 요청은 "지원 가능"에서 빠지거나, 화면에서 미리 막는다.
- 실제: 목록에는 나오고, 누르면 실패한다. FE `subsAvailableToMe`(`app_store.dart:476-487`)도 겹침을 거르지 않는다. 사장님 직접 배정 후보(`web_substitute_screen.dart:115`)는 `overlappingShift`로 거른다.
- 원인: `SubstituteService.java:113-116`의 available 조건에 겹침 검사가 없다.
- 영향: 알바생이 지원을 눌러야 비로소 실패 토스트를 본다.

## 통과한 케이스

- 생성: 본문 없음 400 / reason 공백·누락 400 VALIDATION_FAILED / notifyPeers 타입 오류 400
- 생성: 남의 근무 403 / 사장님 403 / 없는 근무 404
- 생성: 정상 201(한글·이모지 사유, id 문자열, status `open`, notifiedAt=createdAt) / 같은 근무 중복 409 ALREADY_REQUESTED
- 생성: 거절 뒤 같은 근무 재요청 201 / 5000자 사유 201
- 생성: 이미 시작한 야간 근무 409 SHIFT_STARTED / 연차 근무 409 NOT_WORK_SHIFT / 시간 미정 근무 409 NOT_WORK_SHIFT / 다음 날로 넘어가는 미래 야간 근무 201
- 생성 알림: 사장님 "OO님이 휴무·대타를 신청했어요"(body `M/d HH:mm–HH:mm`). notifyPeers=true 면 요청자를 뺀 재직 직원 전원, notifyPeers=false 면 동료 알림 없음.
- 목록: 사장님 전체 / available(요청자 본인은 빈 목록, 지원한 사람·퇴사자는 제외) / mine / status=pending / status=open
- 목록: 잘못된 status 400 INVALID_STATUS / mine=abc 400 / 외부인 403 / 인증 없음 401 / 없는 매장 404
- 지원: 요청자 본인은 무시(200, 변화 없음) / 사장님 403 / 외부인 403 / 다른 매장 경로 403 / 없는 요청 404
- 지원: 겹치는 근무 409 SHIFT_OVERLAP(같은 날, 전날 밤부터 이어지는 야간 근무 포함)
- 지원: 첫 지원자가 후보 + accepted / 같은 사람 두 번은 무시 / 두 번째 지원자는 applicantIds 에만 추가
- 지원: 지난 근무 409 SHIFT_STARTED / 취소·승인된 요청 409 INVALID_STATE
- 지원 알림: 요청자와 사장님에게 감
- 재알림: 요청자 200·사장님 200(notifiedAt 갱신) / 다른 직원 403 / 끝난 요청 409
- 승인: 직원 403 / 요청자 403 / 후보 없음 400 NO_ACCEPTED_APPLICANT / 두 번째 승인 409
- 승인 성공 시 근무 mapping_id=후보, original=요청자, is_substitute=1. 요청자에게 "대타 요청이 승인됐어요 · OO님이 근무해요", 대타자에게 "대타 근무가 확정됐어요".
- 승인 후 reject·cancel·apply·resend·assign 모두 409 INVALID_STATE
- 승인 시점에 후보에게 겹치는 근무가 새로 생겼으면 409 SHIFT_OVERLAP / 담당자가 바뀐 근무 409 SHIFT_CHANGED / 지난 근무 409 SHIFT_STARTED
- 거절: 직원 403 / 사장님 200(요청자·후보에게 알림) / 두 번째 409
- 취소: 다른 직원 403 / 사장님 403 / 요청자 200(지원자·사장님에게 알림) / 두 번째 409 / 취소 뒤 지원 409
- 직접 배정: 본문 없음 400 / staffId 누락 400 / 문자열 staffId("39") 허용 / 요청자 본인 409 SELF_ASSIGN / 가입 대기 직원 409 NOT_ACTIVE
- 직접 배정: 다른 매장 직원 404 / 없는·음수 id 404 / 겹치는 직원 409(지원자 행이 롤백돼 남지 않음) / 직원이 호출 403 / 다른 매장 사장님이 자기 매장 경로로 호출 404 / 지난 근무 409
- 근무 PATCH: 휴게 시간만 바꾸면 요청 유지, 시작 시간을 바꾸면 요청 CANCELLED
- 퇴사: 요청자 퇴사 시 그 사람의 미래 근무와 요청 정리
- 동시 요청: 같은 사용자가 지원 10번을 동시에 보내도 지원자 행 1개, 알림 1쌍
- `/me/state`: subs 의 id·storeId·shiftId·requesterId·acceptedId·applicantIds 가 문자열 직원 id 이고 status 는 Dart `.name`. FE `SubstituteRequest.fromJson` 과 키가 일치한다.

## 못 한 것

- 출근 기록이 있는 미래 근무(시작 30분 전 출근)에 대한 지원: 승인 쪽 `assertNotStarted`는 출근 기록을 확인하지만, 지원(`apply`)은 시간만 본다. 코드로만 확인했고, 출근 기록을 SQL 로 만들어 재현하지는 않았다.
- 사장님이 자기 매장에 직원으로도 가입한 경우(사장님 겸 직원)의 대타: 03 영역의 가입 규칙에 달려 있어 만들지 않았다.
- 동시 요청 테스트 중 일부 500은 `CannotCreateTransactionException`(Hikari 풀 10개 소진, waiting=32)이었다. 같은 시각에 다른 에이전트들의 부하가 겹쳐서, 대타 코드 자체의 500 으로 판단하지 않았다. 그래서 동시 지원(서로 다른 3명)의 후보 결정은 깨끗하게 검증하지 못했다. 그래도 그때 지원자 행 중복은 없었다.
- 퇴사로 대타자가 맡던 근무(대타로 받은 미래 근무)가 원래 근무자에게 돌아가지 않고 통째로 삭제되는 점(`StaffService.java:178-182`)은 04 staff-management 영역 범위라 관찰만 했다. 근무 1159가 삭제되면서 대타 요청 21·32 기록도 함께 지워졌다.
