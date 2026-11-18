# 10 ai-features QA 보고서

## 요약

- 실행한 케이스: 62개 (통과 55, 발견 7)
- 발견: 치명 0, 높음 0, 중간 2, 낮음 5
- 테스트 시각: 2026-11-17 23:00 ~ 2026-11-18 00:01 (KST). 오늘 = 11/17(화) 밤이라 "오늘이 대상 날짜에 포함" 경계가 그대로 드러났다.
- 데이터: 매장 A `에이텐카페`(id 26, 5인 이상, 기본 파트 오픈 8–12·미들 12–17·마감 17–22) 사장님 `a10-owner`, 알바 `a10-s1`(staff 53, 월·화·수 오픈 + 토 미들 고정), `a10-s2`(54, 월·화·목·금 마감 고정 + 수·토·일 가능 시간), `a10-s3`(55, 고정 없음, 월~금 12–22 가능), 매니저 `a10-mgr`(56, 평일 9–18 근무시간). 매장 B `비매장`(id 38) 사장님 `a10-ownerB`, 알바 `a10-bs1`. 무소속 `a10-out`. 시급은 모두 11,000원(B 는 10,320원).
- 외부 LLM 호출: preview 성공 5회(코드상 preview 는 LLM 을 부르지 않고, apply 뒤 백그라운드 브리핑이 부른다), apply 성공 4회 → 브리핑 시도 4회(각 최대 2번 호출).
- **QA 환경에는 `LLM_API_KEY` 가 없다**(`$QA/.env` 에 LLM 항목 없음, 컨테이너 `LLM_API_KEY=` 빈 값). 브리핑 4번 모두 1초 안에 `AI 브리핑 실패, 요약만 둔다: ApiException` 로 끝났다. 그래서 AI 성공 경로(`aiComment` 교체, 완료 신호)는 검증하지 못했다(아래 "못 한 것").
- AI 노무 도우미는 `ANTHROPIC_API_KEY` 가 없어 503 `AI_DISABLED` 경로만 검증했다.

## 발견

### [중간] AI 근무표 생성이 오늘 이미 끝난 시간대의 근무까지 만든다

- 재현 (오늘 23시 이후에 실행):
  ```sh
  OW=$($QA/qa-user a10-owner)
  # 매니저(56) 평일 9–18 근무시간, 알바(54) 화요일 마감(17–22) 고정이 있는 매장 26
  curl -s -X POST http://127.0.0.1:18080/api/v1/stores/26/schedules/generate/preview -H "Authorization: Bearer $OW" -H 'Content-Type: application/json' -d '{"month":"2026-11","weeklyHolidayPay":"allow","priority":"cost"}'
  # → shifts 에 {"staffId":"56","date":"2026-11-17","startMin":540,"endMin":1080}, {"staffId":"54","date":"2026-11-17","startMin":1020,"endMin":1320} 포함 (요청 시각 23:08)
  curl -s -X POST .../stores/26/schedules/generate/apply -H "Authorization: Bearer $OW" -H 'Content-Type: application/json' -d '{"planId":"<위 planId>"}'   # 204
  $QA/qa-sql "SELECT schedule_id,mapping_id,work_date,start_min,end_min FROM schedule WHERE mapping_id IN (54,56) AND work_date='2026-11-17'"
  # → 1174 (56, 540–1080), 1175 (54, 1020–1320) 이 23:09 에 새로 생김. 출근 기록 없음
  ```
- 기대: 대상 기간이 "오늘 이후"라면 이미 끝난(또는 시작한) 오늘 근무는 만들지 않거나, 최소한 내일부터 만든다. 오늘의 지난 근무(출근 기록 없는 것)를 지우고 다시 만드는 것도 피해야 한다.
- 실제: 오늘 날짜 전체가 대상이라 23:08 에 9–18, 17–22 근무가 새로 생겼다. 출근은 근무 종료 뒤 불가(FE `clockInBlock`, BE 출근 검증)라 이 근무는 영원히 출근 기록이 없다. 반대로 오늘 출근 안 찍고 끝난 기존 근무는 적용 때 지워지고 바뀐다.
- 원인: `donBug_BE/src/main/java/com/example/moneybug/service/MonthScheduleService.java:635` `targetDates` 가 `max(월초, 오늘)` 부터 날짜 단위로만 자르고 시각을 보지 않는다. `applyGenerated`(같은 파일 :580–589)의 삭제 범위·`insertable` 도 같은 날짜 기준이다. 월 근무표 자동 채우기·템플릿 적용도 같은 `targetDates` 를 쓴다.
- 영향: 사장님이 저녁에 이번 달을 생성하면 직원들 오늘 근무에 "결근" 근무가 생긴다. 대시보드·근태에 결근으로 보이고, FE `lib/data/payroll.dart:5` 의 주휴 개근 조건(끝난 본인 근무는 모두 출근 기록)에 걸려 앱 예상 급여에서 그 주 주휴수당이 빠질 수 있다. 미리보기 인건비에도 일하지 않을 시간이 들어간다.

### [중간] AI 브리핑 실패가 사용자에게도 운영 로그에도 원인 없이 사라진다

- 재현:
  ```sh
  # (LLM_API_KEY 없는 QA 환경) preview → apply
  curl -s -X POST .../stores/26/schedules/generate/apply ... -d '{"planId":"..."}'   # 204, 23:04:30
  $QA/dc logs --since 5m be | grep 브리핑
  # → 23:04:30.931 WARN ... AI 브리핑 실패, 요약만 둔다: ApiException   (4회 모두 같은 줄)
  $QA/qa-sql "SELECT source,ai_comment FROM month_schedule WHERE store_id=26 AND month='2026-12'"
  # → AI, 계산 요약만 (브리핑 없음)
  # 사장님/알바생 /me/changes?since=<apply 뒤 seq> 를 2분 30초(6회) 기다려도 changed:false
  ```
- 기대: 실패하면 (1) 운영자가 원인을 알 수 있게 로그에 상태(예: `AI 서버가 인증을 거절했어요(401)`, `연결하지 못했어요`)를 남기고, (2) FE 가 "AI 설명을 만들지 못했어요"처럼 알 수 있는 상태를 받는다.
- 실제: 로그에는 예외 클래스 이름 `ApiException` 만 남는다. `ScheduleAiService` 가 만든 메시지(401/403·연결 실패·JSON 아님 구분, 키·프롬프트 없음)는 버려진다. DB 에는 실패 표시가 없고 완료 신호도 없다. FE 생성 화면은 "AI 설명은 적용 뒤 잠시 후 근무표 상단에 붙어요."(`donBug_FE/lib/screens/web/web_schedule_generate.dart:390`)라고 안내하지만 끝내 안 붙고, 다시 시도할 방법은 생성 전체를 다시 하는 것뿐이다.
- 원인: `MonthScheduleService.java:525` `log.warn("AI 브리핑 실패, 요약만 둔다: {}", e.getClass().getSimpleName())` — `ApiException` 의 message 는 비밀이 아닌데도 남기지 않는다. 실패 상태를 `month_schedule` 에 기록하거나 `changeHub.bump` 하는 경로가 없다(:507–526).
- 영향: 운영에서 키 누락·만료·AI 서버 다운이 나도 "AI 근무표 생성이 설명을 안 붙인다"는 증상만 보이고 원인을 로그로 못 찾는다. 사장님은 설명이 오기를 계속 기다린다. 이번 QA 에서도 실패 원인(401 인지 연결 실패인지)을 확인할 수 없었다.

### [낮음] 미리보기에 출근 기록 있는 근무와 똑같은 근무가 한 번 더 들어간다 (적용 때 조용히 빠짐)

- 재현:
  ```sh
  OW=$($QA/qa-user a10-owner)
  # s1(53) 은 화요일 오픈(480–720) 고정. 오늘(11/17 화) 같은 시간 근무를 만들고 출근 기록을 남긴다
  curl -s -X POST .../stores/26/shifts -H "Authorization: Bearer $OW" -H 'Content-Type: application/json' -d '{"date":"2026-11-17","startMin":480,"endMin":720,"part":"오픈","staffIds":[53]}'   # id 1106
  curl -s -X POST .../stores/26/shifts/1106/attendance -H "Authorization: Bearer $OW" -H 'Content-Type: application/json' -d '{"clockIn":"2026-11-17T08:00:00","clockOut":"2026-11-17T12:00:00","reason":"qa"}'   # 201
  curl -s -X POST .../stores/26/schedules/generate/preview -H "Authorization: Bearer $OW" -H 'Content-Type: application/json' -d '{"month":"2026-11"}'
  # → replacing 1, shifts 32 개 중 {"staffId":"53","date":"2026-11-17","startMin":480,"endMin":720,"part":"오픈"} 포함
  # apply 뒤 DB: 11/17 의 53 근무는 1106 하나뿐 (새 근무는 overlap 검사로 건너뜀)
  ```
- 기대: 출근 기록 있는 근무는 적용해도 남으니, 그 직원·시간의 고정 근무는 미리보기에서 빠져야 한다.
- 실제: 미리보기 `shifts` 에 남아 FE 미리보기 표·직원별 시간(`minutesByStaff`)에 두 번 잡히고, 적용하면 `saveRows` 가 아무 말 없이 건너뛴다. 이번 경우 금액은 우연히 맞았다(출근 기록 근무는 금액에서 빠지고 중복분이 대신 들어감). 출근 기록 근무 시간이 고정 시간과 조금만 달라도(예: 8–11 출근) 금액·주휴 줄이 실제와 달라진다. `GapFiller` 에는 두 근무가 다 들어가 그 주 시간이 부풀려진다(주 40시간·6일 제한 판단).
- 원인: `MonthScheduleService.java:478` `compose` 가 `FixedShiftPlanner.fixedShifts` 결과를 `p.off()` 로만 거르고 `p.prior()`(출근 기록 있는 대상일 근무)와 겹치는지는 보지 않는다. 적용 때만 `MonthScheduleService.java:707` `saveRows` 의 `overlapChecker` 가 걸러 낸다.
- 영향: 미리보기의 근무·시간·인건비가 실제 적용 결과와 다르다(특히 이번 달을 월 중간에 다시 생성할 때).

### [낮음] 저장하지 않는 미리보기 요청도 매장 변경 신호를 낸다

- 재현:
  ```sh
  OW=$($QA/qa-user a10-owner)
  s0=$(curl -s http://127.0.0.1:18080/api/v1/me/changes -H "Authorization: Bearer $OW" | jq .seq)
  curl -s -X POST .../stores/26/schedules/generate/preview -H "Authorization: Bearer $OW" -H 'Content-Type: application/json' -d '{"month":"2026-12"}'   # 200, DB 쓰기 없음
  curl -s "http://127.0.0.1:18080/api/v1/me/changes?since=$s0" -H "Authorization: Bearer $OW"
  # → {"seq":...,"changed":true} 즉시
  ```
- 기대: DB 를 안 바꾸는 계산 요청은 신호를 내지 않는다.
- 실제: `changed:true`. 그 매장 사장님·모든 직원 앱·웹이 `/me/state` 를 다시 읽는다. AI 노무 도우미 질문(`POST /ai/labor-questions`)도 성공(2xx)하면 같은 이유로 신호를 낸다(코드 확인, QA 환경은 503 이라 실측 못 함).
- 원인: `donBug_BE/src/main/java/com/example/moneybug/config/StoreChangeInterceptor.java:30` 이 `/api/v1/stores/**` 의 GET 이 아닌 2xx 요청을 모두 변경으로 본다.
- 영향: 사장님이 미리보기를 여러 번 누르거나 AI 에 질문할 때마다 직원 전원 기기가 상태를 새로 받는다(불필요한 트래픽·편집 중 reload 시도).

### [낮음] 미리보기 뒤 퇴사한 직원의 근무가 적용 때 조용히 빠지고, 생긴 빈칸은 안내되지 않는다

- 재현:
  ```sh
  OW=$($QA/qa-user a10-owner)
  curl -s -X POST .../stores/26/schedules/generate/preview ... -d '{"month":"2027-01"}'   # s3(55) 근무 4개 포함
  curl -s -X DELETE .../stores/26/staff/55 -H "Authorization: Bearer $OW"                  # 200
  curl -s -X POST .../stores/26/schedules/generate/apply ... -d '{"planId":"<planId>"}'      # 204
  $QA/qa-sql "SELECT mapping_id,COUNT(*) FROM schedule WHERE mapping_id IN (53,54,55,56) AND work_date LIKE '2027-01%' GROUP BY mapping_id"
  # → 53:17, 54:27, 56:21 — 55 의 4개는 없음. month_schedule.ai_comment 의 "못 채운 칸"·인건비는 미리보기 그대로
  ```
- 기대: 계획이 오래돼 반영 못 한 근무가 있으면 409 로 다시 미리보기를 요구하거나, 응답·요약에 빠진 근무를 알린다.
- 실제: 204. 4칸이 비었는데 요약(인건비·못 채운 칸)은 미리보기 값 그대로 저장된다.
- 원인: `MonthScheduleService.java:692–701` `insert` 가 활성 직원이 아니면 건너뛰고, `applyGenerated`(:571–598)는 건너뛴 수를 쓰지 않는다. 요약(`plan.comment()`)은 미리보기 때 만든 것이다.
- 영향: 사장님은 근무표가 다 찬 줄 안다. 30분 TTL 안이라 드문 경우다.

### [낮음] 확정과 겹쳐 409 가 난 계획도 소모돼, 다시 누르면 "미리보기가 만료됐어요"(410)

- 재현:
  ```sh
  curl -s -X POST .../stores/26/schedules/generate/preview ... -d '{"month":"2026-12"}'      # planId P
  curl -s -X POST .../stores/26/schedules/2026-12/confirm -H "Authorization: Bearer $OW"      # 204
  curl -s -X POST .../stores/26/schedules/generate/apply ... -d '{"planId":"P"}'   # 409 ALREADY_CONFIRMED "그 사이 확정돼서 반영하지 않았어요"
  curl -s -X POST .../stores/26/schedules/generate/apply ... -d '{"planId":"P"}'   # 410 PLAN_EXPIRED
  ```
- 기대: 두 번째도 같은 이유(409 확정됨)를 알려 준다.
- 실제: 410 "미리보기가 만료됐어요. 다시 만들어 주세요". FE(`web_schedule_generate.dart:213`)는 410 이면 설정 화면으로 돌아가고, 다시 미리보기를 누르면 그제야 409 "이미 확정된 근무표예요".
- 원인: `MonthScheduleService.java:441` 이 `applyGenerated`(:445)의 검사 전에 `plans.remove` 로 계획을 지운다. 트랜잭션이 롤백돼도 인메모리 맵은 되돌아가지 않는다.
- 영향: 메시지가 엇갈려 사장님이 헷갈린다. 데이터는 안전하다(DB 롤백 확인: 12월 근무 수 그대로).

### [낮음] AI 노무 도우미 질문 길이: 웹은 제한이 없고, 1000자 초과·이모지는 영어 검증 메시지

- 재현:
  ```sh
  OW=$($QA/qa-user a10-owner)
  curl -s -X POST .../stores/26/ai/labor-questions -H "Authorization: Bearer $OW" -H 'Content-Type: application/json' -d "{\"question\":\"$(python3 -c 'print("가"*1001)')\"}"
  # → 400 {"code":"VALIDATION_FAILED","message":"요청 값이 올바르지 않아요","details":{"question":"size must be between 0 and 1000"}}
  curl -s ... -d "{\"question\":\"$(python3 -c 'print("😀"*1000)')\"}"   # 화면상 1000자인데 400 (UTF-16 2000자)
  ```
- 기대: 웹 입력칸도 1000자로 막고, 서버는 "질문은 1000자까지 쓸 수 있어요" 같은 한국어 메시지를 준다.
- 실제: 웹(`donBug_FE/lib/screens/web/web_ai_assistant_screen.dart:206` TextField)은 `maxLength` 가 없어 1001자 이상이 그대로 가고, 토스트는 "요청 값이 올바르지 않아요"뿐이다. 앱(`ai_labor_assistant_screen.dart:200`, `maxLength: 1000`)은 Flutter 가 글자(그래핌) 단위로 세서 이모지 500개+ 질문이 BE(`AiDto.java:19` `@Size(max = 1000)`, UTF-16 단위)에서 400 이 난다.
- 원인: 위 파일·줄. `@Size` 에 message 가 없다.
- 영향: 긴 질문을 붙여 넣은 사장님이 이유를 모른 채 실패한다.

## 통과한 케이스

권한·인증
- preview: 알바생 403, 매니저 403, 무소속 403, 다른 매장 사장님 403, 인증 없음 401, 없는 매장 404 `NOT_FOUND`
- apply: 알바생·매니저·무소속·다른 매장 사장님 403
- labor-questions: 알바생·매니저·무소속·다른 매장 사장님 403 (권한 검사가 `AI_DISABLED` 보다 먼저)

preview 입력 검증
- month 없음 → 400 `VALIDATION_FAILED`(month), `2026-13`·`202612`·숫자 2026 → 400 형식 오류
- 4개월 뒤(2027-03) → 400 `MONTH_TOO_FAR`, 지난 달(2026-10) → 400 `PAST_MONTH`
- 확정된 달 → 409 `ALREADY_CONFIRMED`
- 직원 0명(매장 B) → 400 `CANNOT_GENERATE` "직원·알바생을 먼저 등록하세요", 가입 대기만 있음 → 같은 400, 승인됐지만 고정 파트·근무시간·가능 시간 없음 → 400 "고정 파트·근무시간을 먼저 정하세요"
- weeklyHolidayPay·priority 생략 → minimize·fairness 기본값, 소문자 Dart `.name`(`allow`,`cost`) 받음

preview 계산
- 알바 고정 파트(요일·파트) 반영: s1 월·화·수 오픈 + 토 미들, s2 월·화·목·금 마감 요일 수가 12월 달력과 정확히 일치
- 매니저 요일별 근무시간(평일 9–18, 휴게 60분) 반영
- 알바 가능 시간(availHours) 반영: s3 는 월~금 12–22 안에서만, s2 는 수·토·일 가능 시간 안에서만 빈칸 충원. 아무도 가능하지 않은 목·금 오픈(8–12)·주말 마감 17칸을 `unfilled` 로 정확히 보고
- 휴무(OFF)·연차(LEAVE) 날은 그 직원 근무 안 넣음(12/7 s1 휴무, 12/8 s2 연차 → 그날 마감은 s3 가 채움)
- 인건비 손 계산 일치: 12월 기본급 4,405,500 + 주휴 683,100 = 5,088,600 (응답과 같음). 주휴는 주 15시간 이상·min(h,40)/40×8×시급·일요일이 그 달인 주만, 12/28 주(일요일 1/3) 제외 확인
- "주 15시간 → 0.5시간 줄이면 33,000원" 안내 줄 값 일치
- `replacing` = 오늘 이후 출근 기록 없는 WORK 수(12월 72, 11월 1 — 출근 기록 있는 1106 제외)
- preview 는 DB 를 쓰지 않음(미리보기 뒤 `month_schedule`·`schedule` 변화 없음)

apply
- 정상 적용 204: `month_schedule` source AI·status DRAFT·weekly_holiday_pay·priority 저장, ai_comment = 요약 줄, 근무 72개 생성
- `/me/state` 의 schedules 항목이 FE `MonthSchedule.fromJson` 모양(`status:"draft"`, `source:"ai"`, `weeklyHolidayPay`, `priority`, `aiComment`)과 일치
- 출근 기록 있는 근무(1106)는 지우지 않고 남김, 출근 기록 없는 기존 근무(1107)는 교체
- 같은 planId 두 번 → 두 번째 410 `PLAN_EXPIRED`
- 같은 planId 동시 10개 → 204 1개·410 9개, 근무 중복 없음
- 새 미리보기를 만들면 이전 planId 는 410 (매장당 1개 보관)
- planId 빈 값·공백·null·없음 → 400, 숫자·없는 값 → 410
- 미리보기 뒤 확정 → apply 409 `ALREADY_CONFIRMED`, DB 롤백(12월 근무 수 그대로)
- 미리보기 뒤 퇴사자 근무는 넣지 않음(위 낮음 발견의 안내 문제 제외)
- 연차·휴무는 적용 때 지우지 않음

백그라운드 job·변경 신호
- apply 직후 같은 매장 알바생 `/me/changes` 즉시 `changed:true`
- 다른 매장(B) 사장님은 store 26 apply 동안 25초 타임아웃 `changed:false` (신호 안 샘)
- AI 실패 시 아무 근무·요약도 바뀌지 않음(요약만 남음), 예외가 요청·서버를 깨지 않음
- 브리핑 job 은 커밋 뒤 실행(적용한 요약이 DB 에 있는 상태에서 실패 로그)

AI 노무 도우미
- 키 없음 → 503 `AI_DISABLED` "AI 도우미가 아직 설정되지 않았어요" (FE 는 message 토스트)
- question 없음·빈 문자열·공백·null → 400, 배열 → 400, 깨진 JSON → 400
- 숫자 123 → 문자열로 받아 503(키 없음) — 입력 검증 통과
- 한글 1000자 → 통과(503), 1001자 → 400
- 연속 25회 → 전부 503 (키가 없으면 횟수 제한 전에 끝나 제한 카운트도 쌓이지 않음)
- 응답 `{answer, createdAt}` 모양이 FE `ai_api.dart` 와 일치(코드 대조)

FE 계약
- FE `previewGenerate` 본문(`month`, `weeklyHolidayPay.name`, `priority.name`) ↔ BE `GenerateRequest` 일치
- FE `GeneratePreview.fromJson` 이 읽는 `planId, month, shifts[staffId,date,startMin,endMin,part,breakMin], lines, laborCost, unfilled[date,part,startMin,endMin,missing], replacing` 모두 응답에 있음, staffId 는 문자열
- FE 생성 화면 월 목록(이번 달 + 3달)이 BE `MONTH_TOO_FAR`(3달 뒤까지)와 일치
- FE 410 처리(미리보기 초기화) ↔ BE `PLAN_EXPIRED` 410

## 못 한 것

- **AI 브리핑 성공 경로**: QA 환경에 `LLM_API_KEY` 가 없어 `ai.ruraeru.xyz` 호출이 4번 모두 즉시 실패했다. 실패 원인(401/403 인지 연결 실패인지)은 로그에 클래스 이름만 남아 알 수 없었다(위 중간 발견). 브리핑 정상 저장, `aiComment` 교체 조건(그 사이 재생성·삭제 시 덮어쓰지 않기), 완료 신호(`changeHub.bump`), `#번호` → 이름 복원, 이상 응답(JSON 아님·`comment` 없음·긴 응답) 처리는 실측하지 못하고 코드만 읽었다. 규칙상 `ai.ruraeru.xyz` 에 직접 요청하지 않았다.
- AI 노무 도우미 성공·502 `AI_FAILED`·429 `AI_RATE_LIMIT`: `ANTHROPIC_API_KEY` 가 없어 키 검사에서 먼저 503 이 나므로 실측 불가. 코드상 제한은 사용자 기준 인메모리(재시작하면 초기화)이고 실패한 호출도 횟수에 든다.
- 계획 30분 만료: 남은 preview 1회를 자정 경계 테스트에 썼다(아래). 30분 넘긴 apply 는 하지 않았다(코드: `MonthScheduleService.java:440`).
- 서버 재시작 뒤 계획 소멸(인메모리)은 `restart` 금지라 못 봤다.
- 11/17 23:08 적용 요청 하나가 약 25초 걸렸다(`updatedAt` 23:09:02). 같은 시각 다른 에이전트의 동시 요청(매장 80 의 1062 중복 키 오류 다수)이 있어 DB 대기로 보이며, 재현되지 않아 발견으로 올리지 않았다.
