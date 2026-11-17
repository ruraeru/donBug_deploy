# 전체 flow QA 기록 (2026-11-17)

에이전트 25개가 영역을 나눠 로컬 서버에 실제 요청을 보내고 FE·BE 코드와 대조했다. 발견은 170건이다(치명 4, 높음 15, 중간 62, 낮음 89). 여러 영역이 같은 문제를 따로 찾은 것을 묶으면 치명 3건, 높음 11건이다. 고친 것은 없다.

## 방법

- 대상: 로컬 docker compose 스택(BE + MySQL 8.4), `http://127.0.0.1:18080`. 운영 서버와 운영 DB 에는 요청하지 않았다.
- 버전: BE `651e15d`, FE `097d207` (둘 다 `develop`).
- 방식: curl 로 API flow 를 실행하고 FE(`models.dart`, `app_store.dart`, 화면 코드)·BE 코드와 대조했다. 웹(Flutter) 화면은 띄우지 않았으므로 화면 조작으로만 드러나는 문제는 범위 밖이다.
- 사용자: 로컬 DB 에 사용자를 넣고 로컬 `JWT_SECRET` 으로 토큰을 만들어 썼다. 카카오 로그인 자체는 dev·test 토큰 경로만 확인했다.
- 에이전트에게 준 지시는 [BRIEF.md](BRIEF.md), 영역별 보고서(재현 curl 포함)는 [reports/](reports/) 에 있다.
- 치명 3건의 원인 코드는 보고서를 받은 뒤 한 번 더 직접 확인했다. 나머지는 각 에이전트의 재현 결과다.

## 치명 (3)

### 1. 롱 폴링이 DB 커넥션 풀을 다 잡아 API 전체가 멈춘다

- 실제: `/me/changes` 연결 10개가 열려 있는 동안 다른 사용자의 `GET /me` 가 23.3초 걸렸다(평소 0.006초). 다른 부하가 겹친 시간에는 `Unable to acquire JDBC Connection` 500 이 났다.
- 원인: `controller/MeController.java:49-52` 가 리포지토리를 부른 뒤 `DeferredResult` 로 최대 25초 기다린다. `spring.jpa.open-in-view` 가 기본값 true 라서 그동안 커넥션을 들고 있다. Hikari 풀은 기본 10개이고 설정이 없다.
- 영향: 앱·웹 탭마다 롱 폴링을 하나씩 연다. 동시 접속이 10명을 넘으면 로그인·출근을 포함한 모든 API 가 지연되거나 500 이 난다.
- 고칠 방향: `spring.jpa.open-in-view=false` 로 두고, 롱 폴링의 매장 id 조회를 짧은 트랜잭션으로 분리한다.
- 보고서: [21](reports/21-changes-polling.md), [24](reports/24-concurrency.md)

### 2. 두 달 이상 지난 달을 웹 편집기에서 저장하면 그 달 앞부분 근무가 지워진다

- 실제: 9월 근무표를 열어 한 칸을 고쳐 저장하니 09-05 연차, 09-10 휴무, 09-15 근무가 DB 에서 지워지고 09-29 만 남았다. 응답은 200 `{"skipped":[]}`.
- 원인: `/me/state` 는 근무를 지난달 1일이 든 주의 월요일부터만 내려준다(`StateService.java:124`). 월 메타는 기간 제한 없이 내려가서 편집기가 열린다. 편집기는 로컬에 있는 그 달 근무만 보내고(`app_store.dart:1126`), BE 는 목록에 없는 근무 중 출근 기록이 없는 것을 지운다(`MonthScheduleService.java:230-235`).
- 영향: 연차·휴무·출근을 안 찍은 근무가 사라진다. 연차가 지워지면 확정 급여가 바뀐다. 사장님에게는 "저장했어요" 만 보인다.
- 보고서: [07](reports/07-monthly-schedule.md)

### 3. 퇴사·거절·대기 중인 사람의 보건증을 그 매장 사장님이 계속 볼 수 있다

- 실제: 퇴사·거절 뒤에 새로 올린 사진이 `GET /stores/{id}/staff/{staffId}/health-cert/photo` 에서 `200 image/png` 로 내려온다. 사장님 `/me/state` 의 `persons` 에도 새 만료일이 들어 있다. 승인 전 신청자의 사진도 받을 수 있다.
- 원인: `service/DocumentService.java:104-106` 이 사장님 여부와 직원 행 존재만 보고 직원 상태(ACTIVE)를 보지 않는다. `service/StateService.java:132-140` 도 모든 상태의 직원을 돌며 지금 보건증 정보를 넣는다.
- 영향: 보건증은 건강 관련 개인정보다. 매장을 떠난 사람의 새 보건증이 예전 사장님에게 계속 보이고, 본인은 이를 알 수도 막을 수도 없다.
- 보고서: [16](reports/16-health-cert.md)

## 높음 (11)

| # | 문제 | 원인 | 보고서 |
|---|---|---|---|
| 4 | 가입 신청을 동시에 보내면 PENDING 행이 여러 개 생긴다(10개 중 8개가 201). 그중 하나를 승인해도 앱이 가입 대기 화면으로 보낸다 | `StoreService.java:338` 의 일반 SELECT 가 스냅샷을 먼저 잡아 `:342` 의 `FOR UPDATE` 가 중복을 못 막는다. `store_worker` 에 유니크 제약이 없다 | [03](reports/03-join-requests.md), [24](reports/24-concurrency.md) |
| 5 | 가입 승인이 동시에 여러 번 통과해 같은 사람이 ACTIVE 8행이 된다. 승인과 거절이 둘 다 성공하기도 한다 | `StaffService.java:80-95` 에 잠금도 `@Version` 도 없다 | [03](reports/03-join-requests.md), [24](reports/24-concurrency.md) |
| 6 | 월 근무표 저장 두 개가 겹치면 겹친 근무가 여러 건 생긴다(같은 근무 7건) | `MonthScheduleService.java:149-151` 에서 `requireOwner` 가 `lockStore` 보다 먼저 스냅샷을 잡는다. `confirm`(`:303-306`), `applyTemplate`(`:350-352`)도 같은 순서다 | [24](reports/24-concurrency.md) |
| 7 | 고정 근무 채우기를 동시에 보내면 근무가 중복된다(124건/31일). 그 뒤 그 달 저장이 `400 SHIFT_OVERLAP` 으로 막힌다 | `MonthScheduleService.java:108-142` 의 `create`·`autofill`·`fill` 에 매장 잠금이 없다 | [08](reports/08-schedule-autofill.md), [24](reports/24-concurrency.md) |
| 8 | 대타 승인과 거절·취소가 동시에 오면 둘 다 성공한다. 요청은 "거절됨"인데 근무는 대타에게 넘어간다 | `SubstituteService.java:158`, `:177-197` 이 상태를 확인한 뒤 바꾸는데 행 잠금이 없다 | [13](reports/13-substitute.md) |
| 9 | 이번 달에 "작성 중" 근무표를 만들면 알바생 앱에서 그 달 근무·출근 기록·대타가 모두 사라진다. 근무 중인 직원은 퇴근 버튼도 사라진다 | `StateService.java:145-164` 가 DRAFT 달 근무를 통째로 빼고, 출근·대타도 그 목록으로만 모은다 | [20](reports/20-state-contract.md) |
| 10 | 연차·휴무·시간 미정 근무는 시각·휴게를 검사하지 않는다. `breakMin=-10000` 연차 한 건이 기본급 2,215,360원으로 계산됐다(정상 72,240원) | `MonthScheduleService.java:194` 가 `WORK` 일 때만 검사하고, `PayrollCalculator.java:74-77` 은 연차를 그 길이만큼 유급으로 친다 | [07](reports/07-monthly-schedule.md) |
| 11 | 계약서를 시작일을 앞당겨 다시 쓰면 옛 계약서의 시급이 이후 날짜에 계속 적용된다 | `DocumentService.java:155` 가 시급 단계를 추가만 한다(`StaffWageService.java:22-28`). 지우는 API 가 없다 | [17](reports/17-contract.md) |
| 12 | BE 급여 계산이 시급 이력을 무시해 지난 근무도 현재 시급으로 계산한다. 지금 FE 는 이 API 를 쓰지 않고 직접 계산해서 화면에는 아직 영향이 없다 | `PayrollCalculator.java:61` 이 `hourlyWage` 하나만 쓴다 | [04](reports/04-staff-management.md), [18](reports/18-payroll.md) |
| 13 | 파트 필요 인원 `need` 에 상한이 없다. `need=10000000` 이면 요청 하나가 3.5초 걸렸고 int 최댓값도 저장된다(약 750초로 추정, 실행하지 않음). `POST /schedule-plans` 본문의 `needs` 도 같다 | `StoreService.java:195`, `:323` 이 음수만 검사하고, `ShiftService.java:553` 루프가 후보가 없어도 `need` 번 돈다 | [05](reports/05-store-settings.md), [23](reports/23-robustness.md) |
| 14 | 24:00 에 끝나는 근무(`endMin` 1440)가 단건 추가·수정에서만 400 이다. 웹 편집기·파트 설정은 1440 을 받는다 | `ShiftCommandDto.java:23`, `:41` 의 `@Max(1439)` | [25](reports/25-e2e-scenario.md) |

## 중간 (62)

영역별 제목이다. 재현과 원인은 각 보고서에 있다.

**[01-auth.md](reports/01-auth.md)**

- 같은 refresh 토큰을 동시에 보내면 1개만 200, 나머지는 500
- 새 사용자의 첫 로그인이 동시에 들어오면 일부가 500 (Duplicate entry)
- 카카오 토큰 자리에 한글·이모지·개행·NUL 이 있으면 401 대신 500

**[03-join-requests.md](reports/03-join-requests.md)**

- 가입 신청 결과 404/409 를 FE 가 읽지 못한다: "매장 코드를 찾을 수 없어요"·대기 화면·매장 진입 분기가 동작하지 않는다
- 거절된 뒤 가입 대기 화면에서 새로고침하면 "이 매장에 접근할 수 없어요" 가 뜨고 거절 안내가 나오지 않는다

**[04-staff-management.md](reports/04-staff-management.md)**

- 같은 직원의 시급을 동시에 바꾸면 데드락 500이 나고 기준 행이 중복된다
- 시급 상한이 없어 급여 계산이 int 오버플로로 음수가 된다

**[05-store-settings.md](reports/05-store-settings.md)**

- 파트를 지워도 그 파트의 근무와 템플릿에 옛 파트 이름이 남음. 같은 이름 파트를 다시 만들면 옛 근무가 새 파트에 붙음 (FE 안내와 다름)
- 대소문자·전각 문자만 다른 파트 이름이 검증을 통과한 뒤 DB 에서 500
- `parts` 배열에 `null` 원소가 있으면 500 (NPE)

**[06-shifts-crud.md](reports/06-shifts-crud.md)**

- 같은 근무 생성 요청을 동시에 보내면 같은 직원에게 겹치는 근무가 여러 건 생긴다
- 퇴사자의 지난 근무를 미래 날짜로 옮길 수 있고, 퇴사자에게 알림이 간다
- `breakMin` 상한 검증이 없어 근무 시간이 음수가 된다
- 9999년 근무에 `repeatWeeks` 를 주면 500

**[07-monthly-schedule.md](reports/07-monthly-schedule.md)**

- 퇴사자의 지난 근무를 퇴사일 뒤 날짜로 옮길 수 있다
- 확정된 근무표를 삭제해도 직원에게 알리지 않는다
- `part` 가 50자를 넘으면 500
- `shifts` 배열에 `null` 이 있으면 500 (NPE)

**[08-schedule-autofill.md](reports/08-schedule-autofill.md)**

- 웹 편집기 "자동 채우기"는 FE 로컬 계산이라 BE 규칙과 다르다: 영업시간·공휴일 무시, 휴무일에도 넣음, 겹침 때문에 저장 실패
- 고정 근무 채우기·근무표 만들기가 3개월 제한을 지나쳐서, 화면에 안 보이는 근무를 만든다
- 연소자 근로 제한(22:00–06:00 금지, 하루 7시간)을 자동 배정이 보지 않는다
- 템플릿 "지난주 근무 복사"와 레거시 자동 배정은 직원에게 알리지 않고, 확정된 달에도 그대로 근무를 넣는다

**[09-schedule-templates.md](reports/09-schedule-templates.md)**

- 같은 템플릿 적용을 두 번 겹쳐 보내면 한쪽이 500 (ObjectOptimisticLockingFailureException)
- 다른 템플릿으로 다시 적용하면 이전 템플릿의 휴무·연차가 남는다. 그 날의 새 근무는 빠지고 연차는 누적된다
- 알바생 `/me/state` 에 매장 템플릿 전체가 내려간다 (작성 중 근무표 패턴 노출)
- 템플릿 이름 101자 이상이면 500

**[10-ai-features.md](reports/10-ai-features.md)**

- AI 근무표 생성이 오늘 이미 끝난 시간대의 근무까지 만든다
- AI 브리핑 실패가 사용자에게도 운영 로그에도 원인 없이 사라진다

**[12-attendance.md](reports/12-attendance.md)**

- 근무 중인 직원을 내보내면 그 직원은 퇴근할 수 없고, 다른 매장 출근도 막힌다
- 웹 근태 입력 창의 "미출근 처리"가 지난 근무에 '근무 중' 기록을 만든다
- 자정을 넘는 근무에서 '자정 이후 출근'을 입력하면 하루 전 시각으로 저장되어 0원 정상 근무가 된다
- 근태 시각이 근무 날짜와 무관해도 저장된다 (미래 근무 기록, 엉뚱한 날짜, 서기 1년)
- 아주 긴 수정 사유를 보내면 500

**[13-substitute.md](reports/13-substitute.md)**

- 월 근무표 저장(PUT)으로 근무의 담당자나 시간이 바뀌어도 진행 중 대타 요청이 남아 있어서, 새 담당자가 대타를 요청할 수 없다
- 후보(acceptedId)가 퇴사하면 요청이 OPEN 으로 돌아가지만, 남은 지원자는 다시 후보가 될 수 없어서 요청이 막힌다

**[14-notices.md](reports/14-notices.md)**

- 재알림 1시간 제한을 FE 가 몰라서 성공 화면과 실패 토스트가 함께 뜬다

**[15-notifications.md](reports/15-notifications.md)**

- 확정된 달 근무표를 삭제하면 직원에게 알림이 없다
- 퇴사·근무 삭제로 진행 중 대타가 정리될 때 관련자에게 알림이 없다
- 보건증 만료 알림(`certAlertDays`)을 보내는 곳이 없다

**[16-health-cert.md](reports/16-health-cert.md)**

- alertDays 에 빈 항목이 있으면 500
- alertDays 를 저장한 문자열이 50자를 넘으면 500, 업로드한 파일은 남는다
- 보건증 만료 알림(certAlertDays)이 실제로 발송되지 않는데, FE 는 "자동 발송·발송 완료" 라고 보여 준다

**[17-contract.md](reports/17-contract.md)**

- 서명 요청에 계약서 id 가 없어서, 직원이 본 적 없는 새 계약서에 서명된다
- 같은 서명 요청을 동시에 보내면 여러 번 성공하고 알림이 중복된다
- 존재하지 않는 서명 이미지 경로로도 서명·작성이 완료된다

**[18-payroll.md](reports/18-payroll.md)**

- BE 급여명세가 시급 이력을 무시하고 과거 달에도 지금 시급을 적용한다
- 주휴수당 규칙이 FE 와 다르다 (결근, 소정시간, 안 끝난 주, 퇴사자)
- BE 에 주 40시간 초과 연장 가산이 없다 (FE 는 계산함)
- 지금 재직 인원이 바뀌면 지난 달 가산수당이 소급해서 바뀐다 (BE·FE 공통)

**[20-state-contract.md](reports/20-state-contract.md)**

- 퇴사한 동료와 같은 시간의 지난 근무를 알바생이 열면 근무 상세 화면이 죽음 (state 참조 무결성 깨짐)

**[22-authz-matrix.md](reports/22-authz-matrix.md)**

- 작성 중(DRAFT) 달의 근무가 알바생에게 API 로 보인다. 그 근무로 대타 요청을 올려 동료에게 알림이 간다

**[23-robustness.md](reports/23-robustness.md)**

- 시급 상한이 없어 급여 계산이 int 오버플로로 음수가 된다
- 휴게 시간이 근무 길이보다 길어도 받아 근무 시간이 음수가 된다 (단건 근무·파트)
- 목록 안의 null 원소로 500 (3곳)
- DB 컬럼 길이를 넘는 문자열·날짜로 500 (DTO 길이 검증 누락)
- 프레임워크 단계 오류와 인증 오류의 응답 형식이 FE `ApiClient` 계약 `{code,message}` 과 다르다

**[24-concurrency.md](reports/24-concurrency.md)**

- 대타 요청 동시 생성 시 한 근무에 진행 중 요청이 여러 개 생긴다
- 대타 요청 취소와 사장님 승인이 겹치면 둘 다 성공하고 결과는 "승인"
- 가입 승인과 거절이 겹치면 둘 다 성공하고 신청자는 두 알림을 다 받는다
- 같은 달 확정을 동시에 보내면 확정 알림이 여러 번 간다 (멱등 처리가 동시 요청에서 깨진다)
- 동시 충돌을 409 대신 500 으로 돌려준다 (FE 는 "서버와 통신하지 못했어요 (500)"을 띄운다)

**[25-e2e-scenario.md](reports/25-e2e-scenario.md)**

- 가입 신청이 404·409 이면 FE 가 결과를 읽지 못하고 "요청을 처리하지 못했어요" 만 띄운다

## 낮음 (89)

메시지 문구, 사소한 FE/BE 불일치, 제어문자 저장, 남는 행 정리 같은 것들이다. 각 보고서의 `[낮음]` 항목을 본다.

## 영역별 집계

| 영역 | 케이스 | 치명 | 높음 | 중간 | 낮음 |
|---|---|---|---|---|---|
| [01 auth](reports/01-auth.md) | 128 | 0 | 0 | 3 | 5 |
| [02 store-onboarding](reports/02-store-onboarding.md) | 82 | 0 | 0 | 0 | 3 |
| [03 join-requests](reports/03-join-requests.md) | 82 | 0 | 2 | 2 | 0 |
| [04 staff-management](reports/04-staff-management.md) | 131 | 0 | 1 | 2 | 5 |
| [05 store-settings](reports/05-store-settings.md) | 78 | 0 | 1 | 3 | 3 |
| [06 shifts-crud](reports/06-shifts-crud.md) | 90 | 0 | 0 | 4 | 3 |
| [07 monthly-schedule](reports/07-monthly-schedule.md) | 72 | 1 | 1 | 4 | 3 |
| [08 schedule-autofill](reports/08-schedule-autofill.md) | 89 | 0 | 1 | 4 | 5 |
| [09 schedule-templates](reports/09-schedule-templates.md) | 52 | 0 | 0 | 4 | 3 |
| [10 ai-features](reports/10-ai-features.md) | 62 | 0 | 0 | 2 | 5 |
| [11 qr-clock-in](reports/11-qr-clock-in.md) | 61 | 0 | 0 | 0 | 3 |
| [12 attendance](reports/12-attendance.md) | 68 | 0 | 0 | 5 | 3 |
| [13 substitute](reports/13-substitute.md) | 88 | 0 | 1 | 2 | 6 |
| [14 notices](reports/14-notices.md) | 76 | 0 | 0 | 1 | 6 |
| [15 notifications](reports/15-notifications.md) | 62 | 0 | 0 | 3 | 4 |
| [16 health-cert](reports/16-health-cert.md) | 82 | 1 | 0 | 3 | 5 |
| [17 contract](reports/17-contract.md) | 82 | 0 | 1 | 3 | 3 |
| [18 payroll](reports/18-payroll.md) | 52 | 0 | 0 | 4 | 2 |
| [19 dashboard](reports/19-dashboard.md) | 46 | 0 | 0 | 0 | 5 |
| [20 state-contract](reports/20-state-contract.md) | 46 | 0 | 1 | 1 | 3 |
| [21 changes-polling](reports/21-changes-polling.md) | 26 | 1 | 0 | 0 | 3 |
| [22 authz-matrix](reports/22-authz-matrix.md) | 690 | 0 | 0 | 1 | 0 |
| [23 robustness](reports/23-robustness.md) | 150 | 0 | 1 | 5 | 6 |
| [24 concurrency](reports/24-concurrency.md) | 22 | 1 | 4 | 5 | 1 |
| [25 e2e-scenario](reports/25-e2e-scenario.md) | 92 | 0 | 1 | 1 | 4 |

권한 매트릭스(22)는 남의 매장 데이터를 읽거나 바꿀 수 있는 곳(IDOR)을 찾지 못했다. 발견은 DRAFT 달 근무가 알바생에게 보이는 것 1건이다.

## 보고서 속 경로

보고서의 `$QA/qa-user`, `$QA/qa-sql`, `$QA/dc` 는 QA 때 쓴 임시 스크립트다(사용자 생성 + 로컬 JWT 발급, 로컬 DB 조회, compose 래퍼). 레포에는 없다. 재현하려면 로컬에서 BE·DB 를 `DEV_LOGIN_ENABLED=true` 로 띄우고 같은 일을 하는 스크립트를 만들어야 한다.
