# 22 authz-matrix QA 보고서

## 요약

- 실행한 케이스: 약 690개
  - 매장 A 엔드포인트 67개 × 외부 역할 6개(인증 없음·무소속·미승인 신청자·퇴사자·B 사장님·B 알바생) = 402
  - 같은 67개 × 내부 역할 2개(A 매니저·A 알바생) = 134
  - A 사장님 정상 동작 47
  - 교차 id(경로는 B 매장, 하위 자원 id 는 A 매장 것, 또는 그 반대) 36
  - `/me/*`·인증 없음 13
  - 사장님 겸 알바생(B 사장님이 A 에 재직) 9
  - 그 밖 상태·알림·서명·QR 개별 케이스 약 50
- 통과: 발견 1건에 걸린 케이스 4개를 뺀 전부.
- 발견: 치명 0, 높음 0, 중간 1, 낮음 0.

남의 매장 데이터를 읽거나 바꿀 수 있는 IDOR 은 찾지 못했다. 알바생·매니저·퇴사자·미승인자가 사장님 전용 기능을 쓸 수 있는 곳도 찾지 못했다. 이유는 아래와 같다.
- 모든 매장 하위 자원 조회가 `findByIdAndStore(id, storeId)`, `access.staff(storeId, staffId)` 같은 매장 범위 조회를 쓴다. 다른 매장 id 를 넣으면 404 가 난다.
- 본문에 든 직원 id·파트 id·근무 id 도 경로 매장 안에서만 찾는다.

### 테스트 환경 (모두 a22- 사용자)

| 역할 | label | user_id | staffId(mapping) |
|---|---|---|---|
| A 사장님 | a22-ownerA | 311 | - |
| A 매니저(kind=manager) | a22-mgrA | 314 | 91 |
| A 알바생 | a22-staffA | 318 | 92 |
| A 미승인 신청자 | a22-pendA | 319 | 93 (PENDING) |
| A 퇴사자 | a22-leftA | 320 | 94 (LEFT) |
| B 사장님 | a22-ownerB | 322 | (나중에 A 에도 재직: 168) |
| B 알바생 | a22-staffB | 323 | 95 |
| 무소속 | a22-none | 324 | - |

- 매장 A = 39 (`QSJZ-JAUW`), 매장 B = 40 (`8HFU-LUTV`)
- A 근무: 398(오늘, staffA, 출근 29), 399(11/25 staffA), 400(11/26 mgrA), 784(12/3 staffA, 2026-12 작성 중 달)
- B 근무: 401(오늘, 출근 30), 402
- 대타 요청: A 5, B 6
- 공지: A 11, B 12
- 템플릿: A 11, B 12
- 계약서: A 92 (직원 서명 완료), B 95
- 월 근무표: A·B 모두 2026-12 (작성 중)

아래 재현의 `$T_x` 는 `T_x=$($QA/qa-user a22-x)` 로 만든 토큰이다. `B=http://127.0.0.1:18080/api/v1` 이다.

## 발견

### [중간] 작성 중(DRAFT) 달의 근무가 알바생에게 API 로 보인다. 그 근무로 대타 요청을 올려 동료에게 알림이 간다

- 재현:
  ```sh
  # 사장님이 2026-12 를 작성 중으로 만들고 근무를 하나 넣는다
  curl -s -X POST $B/stores/39/schedules -H "Authorization: Bearer $T_ownerA" -H 'Content-Type: application/json' -d '{"month":"2026-12"}'
  curl -s -X PUT $B/stores/39/schedules/2026-12/shifts -H "Authorization: Bearer $T_ownerA" -H 'Content-Type: application/json' \
    -d '{"shifts":[{"id":"n1","staffId":92,"date":"2026-12-03","startMin":600,"endMin":900}]}'
  # 1) 상태에서는 숨겨진다 (정상)
  curl -s "$B/me/state" -H "Authorization: Bearer $T_staffA"        # shifts 에 2026-12 없음
  # 2) 목록·단건 API 로는 보인다
  curl -s "$B/stores/39/shifts?from=2026-12-01&to=2026-12-31" -H "Authorization: Bearer $T_staffA"   # 200, id 784 포함
  curl -s "$B/stores/39/shifts/784" -H "Authorization: Bearer $T_staffA"                              # 200
  # 3) 그 근무로 대타 요청을 올릴 수 있다
  curl -s -X POST $B/stores/39/shifts/784/substitute-requests -H "Authorization: Bearer $T_staffA" \
    -H 'Content-Type: application/json' -d '{"reason":"draft"}'                                        # 201, id 28
  # 4) 동료(매니저)에게 알림이 가고, 대타 목록에 보이고, 지원도 된다
  curl -s "$B/me/notifications" -H "Authorization: Bearer $T_mgrA"        # "알바A님이 대타를 구해요 | 12/3 10:00–15:00"
  curl -s "$B/stores/39/substitute-requests" -H "Authorization: Bearer $T_mgrA"   # 28 포함
  curl -s -X POST $B/stores/39/substitute-requests/28/apply -H "Authorization: Bearer $T_mgrA"   # 200, accepted
  curl -s "$B/me/state" -H "Authorization: Bearer $T_mgrA"                # subs 에는 28 이 없다
  ```
- 기대: 작성 중인 달의 근무는 사장님만 본다(`StateService.visibleShifts` 의 주석 "작성 중(DRAFT) 달의 근무는 사장님만 본다"). 그러니 알바생 API 에서도 숨기거나, 적어도 대타 요청·지원 대상이 되지 않아야 한다.
- 실제:
  - `GET /shifts`·`GET /shifts/{id}` 가 작성 중 근무를 200 으로 돌려준다.
  - `POST /shifts/784/substitute-requests` 가 201 이다.
  - 동료에게 "대타를 구해요 · 12/3 10:00–15:00" 알림이 가고, `GET /substitute-requests` 목록에 보이며, 지원(apply)도 200(accepted)이다.
  - 그런데 동료의 `/me/state` 에는 그 근무도 대타도 없다. 근무가 없어서 대타가 걸러진다.
- 원인:
  - `service/ShiftService.java:65` (`list`)·`:84` (`get`) 은 `requireOwnerOrStaff` 만 확인한다. `StateService.java:68`·`:146` 의 작성 중 달 필터를 쓰지 않는다.
  - `service/SubstituteService.java:50-62` (`create`)·`:89` (`list`)·`:126` (`apply`) 도 근무가 속한 달이 작성 중인지 확인하지 않는다.
- 영향:
  - 사장님이 아직 공개하지 않은 근무표 초안이 API 로 알바생에게 새어 나간다.
  - 초안 근무로 대타 요청이 생기고, 동료는 앱에서 열 수 없는 대타 알림을 받는다. FE 는 대타의 shiftId 로 근무를 찾는데 state 에 그 근무가 없다.
  - 사장님이 초안을 고치거나 지우면 이미 수락된 대타 요청이 엉킨다. 근무 삭제 때 요청은 취소되지만, 알림과 동료의 지원은 이미 남아 있다.
  - 지금 FE 화면은 `GET /shifts` 를 부르지 않는다. 그래서 1)·2) 는 API 를 직접 부를 때만 보인다. 하지만 3)·4) 는 shiftId 만 알면 된다(초안이 확정 전에 저장·다시 저장되면 id 가 바뀔 수 있음). 그리고 상태 화면과 서버 응답이 서로 다르다.

## 통과한 케이스

- 인증 없음(토큰 없음·형식이 깨진 토큰): `/stores/**` 67개와 `/me/**` 13개가 모두 401.
- 무소속·미승인 신청자·퇴사자·B 사장님·B 알바생이 매장 A 엔드포인트 67개를 부르면 모두 401/403. 예외는 아래 둘이다.
  - 미승인자 본인 직원 행 `GET /staff/93` 와 `GET /me/state?storeId=39` 는 200 이다. 본인 행과 매장 정보만 들어 있어 의도대로다.
  - `POST /schedule-plans` 는 권한 검사 전에 본문 파싱에서 400 이 난다. 아래 "못 한 것" 참고.
- 퇴사자는 본인 직원 행(`GET /staff/94`)만 200. 공지·근무·대타 등은 403. `/me/state` 에 매장 A 데이터가 없다(알림 2건만 남음).
- 미승인자 `/me/state`: 매장 A 정보(코드 빈 문자열), 본인 직원 행, 사장님 이름만 들어 있다. 근무·공지·대타·근무표·템플릿은 0건.
- 알바생·매니저가 사장님 전용 기능을 부르면 모두 403.
  - 대상: 매장 코드, 매장 PATCH·settings·parts·needs, 직원 승인·거절·수정·퇴사·보건증 요청, 대시보드, 근무 생성·수정·삭제, auto-fill, schedule/template, confirm, tbd-count, 월 근무표 생성·autofill·저장·확정·삭제, generate/preview·apply, 템플릿 생성·삭제·적용, qr-token, 근태 목록·수정·수동 생성, 대타 approve·reject·assign, 공지 작성·read-status·remind, 인건비·추이, AI 노무 도우미, 직원 보건증 사진, 계약서 작성.
- 매니저(kind=manager)에게 추가 권한이 없다. FE 도 매니저 전용 권한을 기대하지 않는다(FE 의 `manager` 는 색·유동 근무에만 쓰인다).
- 알바생·매니저가 남의 자료를 부르면 모두 403.
  - 남의 직원 상세, 급여명세, 근태 단건, 계약서 서명 이미지, 계약서 서명, 남의 근무 대타 요청, 남의 대타 요청 취소, resend.
- 알바생이 자기 자료를 부르면 200: 직원 행, 근태 단건, 급여명세, 계약서 직원 서명 이미지, 퇴근, 대타 요청·취소, 공지 읽음.
- 경로 storeId=40(B 사장님)에 A 매장 하위 자원 id 를 넣으면 모두 404 이고 A 데이터는 바뀌지 않는다(DB 로 확인).
  - 대상: 직원 92·93(조회·수정·퇴사·승인·거절·보건증 요청·급여·보건증 사진·서명·계약서), 근무 398·399, 근태 29, 대타 5, 공지 11, 템플릿 11 적용, plan apply.
- 같은 교차 조건에서 `DELETE /stores/40/shifts/400` 과 `DELETE /stores/40/schedule-templates/11` 은 204 를 돌려준다. 하지만 A 의 근무 400·템플릿 11 은 그대로 남는다(없는 자원 삭제를 멱등으로 처리, `ShiftService.java:214`, `MonthScheduleService.java:346`). 데이터 손상은 없다.
- 경로는 내 매장, 본문은 남의 매장 id:
  - `POST /stores/39/shifts staffIds:[95]` → 404.
  - `PATCH /stores/39/shifts/399 staffId:95` → 404.
  - `PATCH /stores/40/shifts/402 staffId:92` → 404.
  - `POST /stores/40/substitute-requests/6/assign staffId:92` → 404.
  - `PUT /stores/39/parts` 에 B 파트 id 123 → 404, 파트는 바뀌지 않는다.
  - `PUT /stores/39/schedules/2026-12/shifts` 에 B 근무 id 1052 → 새 근무로 취급하고 B 근무 1052 는 그대로다.
  - `PUT /stores/40/schedules/2026-12/shifts` 에 A 근무 id 784 + A 직원 92 → 400 STAFF_NOT_FOUND.
  - 같은 요청에 B 직원 95 → B 에 새 근무만 생기고 A 근무 784 는 그대로다.
- QR: B 매장 QR 로 A 근무 출근 → 400 INVALID_QR. 경로 40 + A 근무 398 → 404. 매니저 qr-token → 403.
- 알림: 남의 알림 읽음 처리(알바·다른 매장 사장님) → 403. `?storeId=40` 목록은 본인 알림만 보여 0건.
- 서명 파일: 남의 서명 경로, `..` 경로 탈출, 사장님이 직원 서명을 사장 서명으로 쓰기 → 모두 400 INVALID_SIGNATURE.
- `/me/state` 의 알바생·매니저 시점 노출 범위:
  - 다른 직원의 시급 0, 연락처·kakaoId null, 계약서 없음.
  - 출근 기록은 본인 것만, 매장 코드 빈 문자열.
  - 다른 매장 데이터 없음, 작성 중 달 근무 숨김.
- `/me/state?storeId=` 에 내 매장이 아닌 id → 403.
- 사장님 겸 알바생(B 사장님이 A 재직):
  - A 의 매장 코드·대시보드·qr-token·남의 직원 상세·급여·근태 → 403.
  - B 사장님 기능은 그대로 200.
  - `/me/state` 의 기본 역할은 employer(ownerStoreId 40). `?storeId=39` 면 employee.
  - 매장 A 직원 행은 남의 시급 0으로 가려진다.
- `/me/changes` 는 내 소유·재직·대기 매장만 기다린다(코드 확인, `MeController.java:45-53`).
- A 사장님 정상 경로 47개가 모두 2xx 이다. 예외는 의도된 4xx(본인 알바 아님 403, 보건증 사진 없음 404, 잘못된 planId 404/410, 미래 시각 수동 근태 400)뿐이다.

## 못 한 것

- `POST /schedules/generate/preview` 를 사장님 권한으로 성공시키기: 외부 LLM 을 부르므로 10번 에이전트에게 남겼다. 권한이 없는 역할(B 사장님·알바생)은 LLM 호출 전에 403 을 받는 것을 확인했다.
- `POST /ai/labor-questions` 를 사장님 권한으로 성공시키기: 10번 영역이다. 비사장님 403 만 확인했다.
- `PUT /me/health-cert`·`GET /me/health-cert/photo` 의 파일 관련 경우: 16번 영역이다. 직원 보건증 사진의 매장 범위만 확인했다(남의 매장 404, 알바생 403).
- 만료·변조·서명이 다른 JWT 와 삭제된 사용자 토큰: 01번 영역이다. 형식이 깨진 토큰 401 만 확인했다.
- 참고(권한 문제 아님, 23번 영역): `POST /schedule-plans` 에 `copyLastWeek` 를 빼면 `boolean` 원시 타입 null 로 400 이 난다. 이 400 은 `ApiException` 형식이 아니라 Spring 기본 오류 본문(`{"timestamp","status","error","path"}`)이다. 같은 기본 형식이 `PUT /parts` 의 잘못된 tone 값에서도 나온다. 권한 검사보다 앞에서 나서 무소속 사용자도 같은 400 을 받지만, 데이터 노출은 없다.
- 관찰(버그로 보지 않음):
  - 알바생 `/me/state` 에 그 매장의 이름 있는 주간 템플릿(직원 id·시간 패턴)이 들어간다.
  - 사장님은 퇴사자·미승인 신청자의 보건증 사진도 볼 수 있다(`DocumentService.java:104-106`, 상태 확인 없음).
  - 둘 다 정책 판단이 필요해 발견으로 올리지 않았다.
